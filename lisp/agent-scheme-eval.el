;;; agent-scheme-eval.el --- R7RS evaluator kernel  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small evaluator for Agent Scheme primitive expressions.  The evaluator
;; uses explicit lexical environments and a trampoline for tail calls; it never
;; delegates Scheme source to Emacs `eval'.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)

(defconst agent-scheme--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Agent Scheme evaluator source.")

(defcustom agent-scheme-eval-maximum-steps 100000
  "Maximum evaluator steps allowed in one `agent-scheme-eval' run."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-eval-maximum-value-nodes 100000
  "Maximum returned or allocated value nodes allowed during evaluation."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-eval-maximum-host-callbacks 10000
  "Maximum registered primitive callbacks allowed during evaluation."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-base-prelude-file nil
  "Optional path to the portable `(scheme base)' prelude source file."
  :type '(choice (const :tag "Use bundled prelude" nil)
                 file)
  :group 'agent-scheme)

(defcustom agent-scheme-base-syntax-file nil
  "Optional path to the portable `(scheme base)' syntax prelude file."
  :type '(choice (const :tag "Use bundled syntax prelude" nil)
                 file)
  :group 'agent-scheme)

(define-error 'agent-scheme-eval-error
  "Agent Scheme evaluation error")

(define-error 'agent-scheme-budget-error
  "Agent Scheme evaluation budget exceeded"
  'agent-scheme-eval-error)

(cl-defstruct (agent-scheme-unspecified
               (:constructor agent-scheme--make-unspecified)
               (:copier nil))
  "Scheme unspecified value.")

(defconst agent-scheme-unspecified
  (agent-scheme--make-unspecified)
  "Canonical Agent Scheme unspecified value.")

(cl-defstruct (agent-scheme--undefined
               (:constructor agent-scheme--make-undefined)
               (:copier nil))
  "Internal marker for uninitialized definition locations.")

(defconst agent-scheme--undefined
  (agent-scheme--make-undefined)
  "Internal uninitialized binding marker.")

(cl-defstruct (agent-scheme--cell
               (:constructor agent-scheme--make-cell (value))
               (:copier nil))
  "Mutable location for one Scheme binding."
  value)

(cl-defstruct (agent-scheme--environment
               (:constructor agent-scheme--make-environment
                             (bindings parent))
               (:copier nil))
  "Explicit lexical environment frame."
  bindings parent)

(cl-defstruct (agent-scheme--syntax-environment
               (:constructor agent-scheme--make-syntax-environment
                             (bindings parent))
               (:copier nil))
  "Explicit syntactic environment frame."
  bindings parent)

(cl-defstruct (agent-scheme--syntax-context
               (:constructor agent-scheme--make-syntax-context
                             (id value-environment syntax-environment))
               (:copier nil))
  "Hygienic context attached to macro-introduced identifiers."
  id value-environment syntax-environment)

(cl-defstruct (agent-scheme--identifier
               (:constructor agent-scheme--make-identifier (name context))
               (:copier nil))
  "Macro-expanded identifier with hygienic context."
  name context)

(cl-defstruct (agent-scheme--formals
               (:constructor agent-scheme--make-formals
                             (required rest))
               (:copier nil))
  "Parsed lambda formal parameters."
  required rest)

(cl-defstruct (agent-scheme-procedure
               (:constructor agent-scheme--make-procedure
                             (formals body environment))
               (:copier nil))
  "Scheme procedure value."
  formals body environment)

(cl-defstruct (agent-scheme-primitive-procedure
               (:constructor agent-scheme--make-primitive-procedure
                             (name function minimum-arity maximum-arity))
               (:copier nil))
  "Registered primitive procedure value."
  name function minimum-arity maximum-arity)

(cl-defstruct (agent-scheme--string-output-port
               (:constructor agent-scheme--make-string-output-port
                             (contents))
               (:copier nil))
  "In-memory textual output port used by `(scheme write)'."
  contents)

(cl-defstruct (agent-scheme--sequence
               (:constructor agent-scheme--make-sequence
                             (forms allow-definitions))
               (:copier nil))
  "Internal sequence expression."
  forms allow-definitions)

(cl-defstruct (agent-scheme--bounce
               (:constructor agent-scheme--make-bounce
                             (expression environment &optional
                                         syntax-environment))
               (:copier nil))
  "Trampoline state for evaluating EXPRESSION in ENVIRONMENT."
  expression environment syntax-environment)

(cl-defstruct (agent-scheme--eval-context
               (:constructor agent-scheme--make-eval-context)
               (:copier nil))
  steps
  maximum-steps
  maximum-value-nodes
  host-callbacks
  maximum-host-callbacks
  syntax-environment
  libraries
  include-paths
  include-directory
  file-paths
  base-syntax-installed)

(cl-defstruct (agent-scheme--syntax-transformer
               (:constructor agent-scheme--make-syntax-transformer
                             (ellipsis literals rules value-environment
                                       syntax-environment))
               (:copier nil))
  "A parsed high-level `syntax-rules' transformer."
  ellipsis literals rules value-environment syntax-environment)

(cl-defstruct (agent-scheme--pattern-binding
               (:constructor agent-scheme--make-pattern-binding
                             (depth captures))
               (:copier nil))
  "Nested pattern-variable captures for one macro expansion."
  depth captures empty-prefixes)

(cl-defstruct (agent-scheme--syntax-scope
               (:constructor agent-scheme--make-syntax-scope
                             (forms syntax-environment))
               (:copier nil))
  "Body forms evaluated under a local syntactic environment."
  forms syntax-environment)

(cl-defstruct (agent-scheme--library-binding
               (:constructor agent-scheme--make-library-binding
                             (name kind object library-key))
               (:copier nil))
  "One exported or imported library binding."
  name kind object library-key)

(cl-defstruct (agent-scheme--library
               (:constructor agent-scheme--make-library
                             (name key exports value-environment
                                   syntax-environment))
               (:copier nil))
  "Loaded Scheme library with explicit environments and exports."
  name key exports value-environment syntax-environment)

(defconst agent-scheme--missing-cell (make-symbol "agent-scheme-missing-cell")
  "Sentinel used when looking up environment cells.")

(defun agent-scheme--eval-option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun agent-scheme--normalize-include-paths (paths directory)
  "Return policy PATHS expanded relative to DIRECTORY."
  (when paths
    (unless (listp paths)
      (agent-scheme--eval-error
       ":include-paths must be a list of file or directory paths"))
    (mapcar
     (lambda (path)
       (unless (stringp path)
         (agent-scheme--eval-error
          ":include-paths entries must be strings"))
       (expand-file-name path directory))
     paths)))

(defun agent-scheme--new-eval-context (options)
  "Return an evaluator context using OPTIONS."
  (let ((maximum-steps
         (cond
          ((plist-member options :max-steps)
           (plist-get options :max-steps))
          ((plist-member options :max-non-tail-steps)
           (plist-get options :max-non-tail-steps))
          (t agent-scheme-eval-maximum-steps)))
        (include-directory
         (file-name-as-directory
          (expand-file-name
           (agent-scheme--eval-option
            options :include-directory default-directory)))))
    (agent-scheme--make-eval-context
     :steps 0
     :maximum-steps maximum-steps
     :maximum-value-nodes
     (agent-scheme--eval-option options :max-value-nodes
                                agent-scheme-eval-maximum-value-nodes)
     :host-callbacks 0
     :maximum-host-callbacks
     (agent-scheme--eval-option options :max-host-callbacks
                                agent-scheme-eval-maximum-host-callbacks)
     :syntax-environment
     (agent-scheme--make-syntax-environment
      (make-hash-table :test #'equal) nil)
     :libraries (make-hash-table :test #'equal)
     :include-paths
     (agent-scheme--normalize-include-paths
      (agent-scheme--eval-option options :include-paths nil)
      include-directory)
     :include-directory include-directory
     :file-paths
     (agent-scheme--normalize-include-paths
      (agent-scheme--eval-option options :file-paths nil)
      include-directory)
     :base-syntax-installed nil)))

(defun agent-scheme--eval-error (message &rest args)
  "Signal an Agent Scheme evaluation error.
MESSAGE and ARGS are passed to `format'."
  (signal 'agent-scheme-eval-error (list (apply #'format message args))))

(defun agent-scheme--budget-error (message &rest args)
  "Signal an Agent Scheme budget error.
MESSAGE and ARGS are passed to `format'."
  (signal 'agent-scheme-budget-error (list (apply #'format message args))))

(defun agent-scheme--note-step (context)
  "Record one evaluator step in CONTEXT."
  (cl-incf (agent-scheme--eval-context-steps context))
  (when (> (agent-scheme--eval-context-steps context)
           (agent-scheme--eval-context-maximum-steps context))
    (agent-scheme--budget-error
     "evaluation step budget exceeded: %d"
     (agent-scheme--eval-context-maximum-steps context))))

(defun agent-scheme--note-host-callback (context primitive)
  "Record one host callback for PRIMITIVE in CONTEXT."
  (cl-incf (agent-scheme--eval-context-host-callbacks context))
  (when (> (agent-scheme--eval-context-host-callbacks context)
           (agent-scheme--eval-context-maximum-host-callbacks context))
    (agent-scheme--budget-error
     "host callback budget exceeded while calling %s"
     (agent-scheme-primitive-procedure-name primitive))))

(defun agent-scheme--value-node-count (value seen)
  "Return an approximate node count for VALUE.
SEEN prevents infinite recursion over cyclic host structures."
  (cond
   ((or (null value)
        (eq value agent-scheme-true)
        (eq value agent-scheme-false)
        (agent-scheme-unspecified-p value)
        (agent-scheme-symbol-p value)
        (agent-scheme--identifier-p value)
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-procedure-p value)
        (agent-scheme-primitive-procedure-p value)
        (agent-scheme--string-output-port-p value))
    1)
   ((stringp value)
    (1+ (length value)))
   ((agent-scheme-bytevector-p value)
    (1+ (length (agent-scheme-bytevector-bytes value))))
   ((consp value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (+ 1
         (agent-scheme--value-node-count (car value) seen)
         (agent-scheme--value-node-count (cdr value) seen))))
   ((vectorp value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (let ((count 1))
        (cl-loop for item across value
                 do (cl-incf count
                             (agent-scheme--value-node-count item seen)))
        count)))
   (t
    (agent-scheme--eval-error "unsupported Scheme value %S" value))))

(defun agent-scheme--check-value-budget (value context)
  "Signal if VALUE exceeds CONTEXT's value budget."
  (let ((count (agent-scheme--value-node-count
                value (make-hash-table :test #'eq))))
    (when (> count (agent-scheme--eval-context-maximum-value-nodes context))
      (agent-scheme--budget-error
       "value node budget exceeded: %d > %d"
       count
       (agent-scheme--eval-context-maximum-value-nodes context))))
  value)

(defun agent-scheme--identifier-datum-p (datum)
  "Return non-nil if DATUM is a Scheme identifier."
  (or (agent-scheme-symbol-p datum)
      (agent-scheme--identifier-p datum)))

(defun agent-scheme--symbol-name (datum)
  "Return DATUM's Scheme identifier name, or nil."
  (cond
   ((agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum))
   ((agent-scheme--identifier-p datum)
    (agent-scheme--identifier-name datum))
   (t nil)))

(defun agent-scheme--symbol-named-p (datum name)
  "Return non-nil if DATUM is a Scheme symbol named NAME."
  (equal (agent-scheme--symbol-name datum) name))

(defun agent-scheme--syntax-symbol (name)
  "Return Agent Scheme symbol datum for NAME."
  (agent-scheme--intern-symbol name))

(defun agent-scheme--identifier-key (identifier)
  "Return the lexical binding key for IDENTIFIER."
  (cond
   ((agent-scheme--identifier-p identifier)
    (let ((context (agent-scheme--identifier-context identifier)))
      (if context
          (list :syntax
                (agent-scheme--syntax-context-id context)
                (agent-scheme--identifier-name identifier))
        (agent-scheme--identifier-name identifier))))
   ((agent-scheme-symbol-p identifier)
    (agent-scheme-symbol-name identifier))
   ((stringp identifier)
    identifier)
   (t
    (agent-scheme--eval-error "expected identifier, got %S" identifier))))

(defun agent-scheme--identifier-display-name (identifier)
  "Return IDENTIFIER's user-facing name for diagnostics."
  (or (agent-scheme--symbol-name identifier)
      (if (stringp identifier) identifier (format "%S" identifier))))

(defun agent-scheme--proper-list-elements (datum description)
  "Return proper list DATUM as an Emacs Lisp list.
Signal an evaluation error naming DESCRIPTION when DATUM is not a
proper list."
  (let ((cursor datum)
        elements)
    (while (consp cursor)
      (push (car cursor) elements)
      (setq cursor (cdr cursor)))
    (when cursor
      (agent-scheme--eval-error "%s must be a proper list" description))
    (nreverse elements)))

(defun agent-scheme--expect-symbol-name (datum description)
  "Return DATUM's symbol name or signal an error naming DESCRIPTION."
  (or (agent-scheme--symbol-name datum)
      (agent-scheme--eval-error "%s must be an identifier" description)))

(defun agent-scheme--expect-identifier-key (datum description)
  "Return DATUM's lexical binding key or signal an error."
  (unless (agent-scheme--identifier-datum-p datum)
    (agent-scheme--eval-error "%s must be an identifier" description))
  (agent-scheme--identifier-key datum))

(defun agent-scheme-make-empty-environment (&optional parent)
  "Return a fresh empty lexical environment with optional PARENT."
  (agent-scheme--make-environment (make-hash-table :test #'equal) parent))

(defun agent-scheme--environment-cell (environment name)
  "Return cell for NAME in ENVIRONMENT, or nil if unbound."
  (let ((cursor environment)
        cell)
    (while (and cursor (not cell))
      (let ((candidate
             (gethash name
                      (agent-scheme--environment-bindings cursor)
                      agent-scheme--missing-cell)))
        (unless (eq candidate agent-scheme--missing-cell)
          (setq cell candidate)))
      (setq cursor (agent-scheme--environment-parent cursor)))
    cell))

(defun agent-scheme--environment-cell-for-identifier (environment identifier)
  "Return cell for IDENTIFIER in ENVIRONMENT, or nil if unbound."
  (cond
   ((agent-scheme--identifier-p identifier)
    (let ((context (agent-scheme--identifier-context identifier)))
      (if context
          (or (agent-scheme--environment-cell
               environment (agent-scheme--identifier-key identifier))
              (let ((definition-environment
                     (agent-scheme--syntax-context-value-environment context)))
                (and definition-environment
                     (agent-scheme--environment-cell
                      definition-environment
                      (agent-scheme--identifier-name identifier)))))
        (agent-scheme--environment-cell
         environment (agent-scheme--identifier-name identifier)))))
   ((agent-scheme-symbol-p identifier)
    (agent-scheme--environment-cell
     environment (agent-scheme-symbol-name identifier)))
   ((stringp identifier)
    (agent-scheme--environment-cell environment identifier))
   (t nil)))

(defun agent-scheme--environment-define (environment name value)
  "Define NAME as VALUE in ENVIRONMENT's current frame."
  (puthash name
           (agent-scheme--make-cell value)
           (agent-scheme--environment-bindings environment)))

(defun agent-scheme--environment-set-cell (environment name value)
  "Store VALUE in NAME's existing cell in ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell environment name)))
    (unless cell
      (agent-scheme--eval-error "unbound identifier in set!: %s" name))
    (setf (agent-scheme--cell-value cell) value)))

(defun agent-scheme--environment-ref (environment name)
  "Return NAME's value from ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell environment name)))
    (unless cell
      (agent-scheme--eval-error "unbound identifier: %s" name))
    (let ((value (agent-scheme--cell-value cell)))
      (when (agent-scheme--undefined-p value)
        (agent-scheme--eval-error
         "identifier referenced before definition is initialized: %s"
         name))
      value)))

(defun agent-scheme--environment-ref-identifier (environment identifier)
  "Return IDENTIFIER's value from ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell-for-identifier
               environment identifier)))
    (unless cell
      (agent-scheme--eval-error
       "unbound identifier: %s"
       (agent-scheme--identifier-display-name identifier)))
    (let ((value (agent-scheme--cell-value cell)))
      (when (agent-scheme--undefined-p value)
        (agent-scheme--eval-error
         "identifier referenced before definition is initialized: %s"
         (agent-scheme--identifier-display-name identifier)))
      value)))

(defun agent-scheme--environment-set-identifier
    (environment identifier value)
  "Store VALUE in IDENTIFIER's existing cell in ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell-for-identifier
               environment identifier)))
    (unless cell
      (agent-scheme--eval-error
       "unbound identifier in set!: %s"
       (agent-scheme--identifier-display-name identifier)))
    (setf (agent-scheme--cell-value cell) value)))

(defun agent-scheme--ensure-distinct-names (names description)
  "Signal if NAMES contains duplicates for DESCRIPTION."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (name names)
      (when (gethash name seen)
        (agent-scheme--eval-error
         "duplicate identifier in %s: %s" description name))
      (puthash name t seen))))

(defun agent-scheme--parse-formals (formals)
  "Parse Scheme FORMALS into an `agent-scheme--formals' value."
  (cond
   ((agent-scheme-symbol-p formals)
    (agent-scheme--make-formals nil (agent-scheme--identifier-key formals)))
   ((agent-scheme--identifier-p formals)
    (agent-scheme--make-formals nil (agent-scheme--identifier-key formals)))
   (t
    (let ((cursor formals)
          required
          rest)
      (while (consp cursor)
        (push (agent-scheme--expect-identifier-key
               (car cursor) "lambda formal")
              required)
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor))
       ((agent-scheme--identifier-datum-p cursor)
        (setq rest (agent-scheme--identifier-key cursor)))
       (t
        (agent-scheme--eval-error
         "lambda formals must be an identifier, a proper list, or a dotted list")))
      (setq required (nreverse required))
      (agent-scheme--ensure-distinct-names
       (if rest (append required (list rest)) required)
       "lambda formals")
      (agent-scheme--make-formals required rest)))))

(defun agent-scheme--self-evaluating-p (expression)
  "Return non-nil when EXPRESSION is a self-evaluating datum."
  (or (eq expression agent-scheme-true)
      (eq expression agent-scheme-false)
      (agent-scheme-number-p expression)
      (agent-scheme-character-p expression)
      (stringp expression)
      (vectorp expression)
      (agent-scheme-bytevector-p expression)))

(defun agent-scheme--true-value-p (value)
  "Return non-nil if VALUE counts as true in Scheme."
  (not (eq value agent-scheme-false)))

(defun agent-scheme--definition-form-p (form)
  "Return non-nil if FORM is a supported definition form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "define")))

(defun agent-scheme--begin-form-p (form)
  "Return non-nil if FORM is a begin form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "begin")))

(defun agent-scheme--make-lambda-expression (formals body)
  "Construct a lambda expression from FORMALS and BODY."
  (cons (agent-scheme--syntax-symbol "lambda")
        (cons formals body)))

(defun agent-scheme--parse-definition (form)
  "Parse supported DEFINE FORM.
Return a cons cell (NAME . INITIALIZER-EXPRESSION)."
  (let ((parts (agent-scheme--proper-list-elements form "define form")))
    (unless (>= (length parts) 3)
      (agent-scheme--eval-error "define requires a target and a value"))
    (let ((target (cadr parts))
          (body (cddr parts)))
      (cond
       ((agent-scheme-symbol-p target)
        (unless (= (length body) 1)
          (agent-scheme--eval-error
           "variable define requires exactly one expression"))
        (cons (agent-scheme--identifier-key target) (car body)))
       ((agent-scheme--identifier-p target)
        (unless (= (length body) 1)
          (agent-scheme--eval-error
           "variable define requires exactly one expression"))
        (cons (agent-scheme--identifier-key target) (car body)))
       ((consp target)
        (let ((name (agent-scheme--expect-identifier-key
                     (car target) "function define name")))
          (unless body
            (agent-scheme--eval-error "function define requires a body"))
          (cons name
                (agent-scheme--make-lambda-expression (cdr target) body))))
       (t
        (agent-scheme--eval-error
         "define target must be an identifier or function signature"))))))

(defun agent-scheme--split-body (body)
  "Split BODY into leading definitions and remaining expressions."
  (let ((cursor body)
        definitions)
    (while (and cursor (agent-scheme--definition-form-p (car cursor)))
      (push (car cursor) definitions)
      (setq cursor (cdr cursor)))
    (unless cursor
      (agent-scheme--eval-error "body must contain at least one expression"))
    (cons (nreverse definitions) cursor)))

(declare-function agent-scheme--eval-expression "agent-scheme-eval")
(declare-function agent-scheme--eval-sequence "agent-scheme-eval")

(defun agent-scheme--prepare-body-environment (body environment context)
  "Return (ENVIRONMENT . EXPRESSIONS) for lambda BODY.
Internal definitions are installed in fresh locations before their
initializers are evaluated."
  (let* ((split (agent-scheme--split-body body))
         (definitions (car split))
         (expressions (cdr split)))
    (if (null definitions)
        (cons environment expressions)
      (let ((body-environment (agent-scheme-make-empty-environment environment))
            parsed)
        (dolist (definition definitions)
          (let ((parsed-definition
                 (agent-scheme--parse-definition definition)))
            (push parsed-definition parsed)
            (unless (eq (gethash (car parsed-definition)
                                  (agent-scheme--environment-bindings
                                   body-environment)
                                  agent-scheme--missing-cell)
                        agent-scheme--missing-cell)
              (agent-scheme--eval-error
               "duplicate internal definition: %s"
               (car parsed-definition)))
            (agent-scheme--environment-define
             body-environment (car parsed-definition) agent-scheme--undefined)))
        (dolist (parsed-definition (nreverse parsed))
          (agent-scheme--environment-set-cell
           body-environment
           (car parsed-definition)
           (agent-scheme--eval-expression
            (cdr parsed-definition) body-environment context nil)))
        (cons body-environment expressions)))))

(defun agent-scheme--eval-definition (form environment context)
  "Evaluate top-level definition FORM in ENVIRONMENT."
  (let* ((parsed (agent-scheme--parse-definition form))
         (name (car parsed))
         (cell (gethash name
                        (agent-scheme--environment-bindings environment)
                        agent-scheme--missing-cell))
         (value (agent-scheme--eval-expression
                 (cdr parsed) environment context nil)))
    (if (not (eq cell agent-scheme--missing-cell))
        (setf (agent-scheme--cell-value cell) value)
      (agent-scheme--environment-define environment name value))
    agent-scheme-unspecified))

(defun agent-scheme--bind-formals (formals arguments closure-environment context)
  "Return a call environment for FORMALS bound to ARGUMENTS."
  (let* ((required (agent-scheme--formals-required formals))
         (rest (agent-scheme--formals-rest formals))
         (required-count (length required))
         (argument-count (length arguments)))
    (cond
     ((and (null rest) (/= argument-count required-count))
      (agent-scheme--eval-error
       "procedure expected %d arguments, got %d"
       required-count argument-count))
     ((and rest (< argument-count required-count))
      (agent-scheme--eval-error
       "procedure expected at least %d arguments, got %d"
       required-count argument-count)))
    (let ((environment (agent-scheme-make-empty-environment
                        closure-environment))
          (remaining arguments))
      (dolist (name required)
        (agent-scheme--environment-define environment name (car remaining))
        (setq remaining (cdr remaining)))
      (when rest
        (agent-scheme--environment-define
         environment rest (copy-sequence remaining))
        (agent-scheme--check-value-budget remaining context))
      environment)))

(defun agent-scheme--arity-match-p (primitive count)
  "Return non-nil if PRIMITIVE accepts COUNT arguments."
  (and (>= count
           (agent-scheme-primitive-procedure-minimum-arity primitive))
       (let ((maximum
              (agent-scheme-primitive-procedure-maximum-arity primitive)))
         (or (null maximum) (<= count maximum)))))

(defun agent-scheme--apply-procedure (procedure arguments context tailp)
  "Apply PROCEDURE to ARGUMENTS.
When TAILP is non-nil, return a bounce for Scheme procedure bodies."
  (cond
   ((agent-scheme-primitive-procedure-p procedure)
    (unless (agent-scheme--arity-match-p procedure (length arguments))
      (let ((maximum
             (agent-scheme-primitive-procedure-maximum-arity procedure)))
        (agent-scheme--eval-error
         "primitive %s expected %s arguments, got %d"
         (agent-scheme-primitive-procedure-name procedure)
         (if maximum
             (format "%d..%d"
                     (agent-scheme-primitive-procedure-minimum-arity procedure)
                     maximum)
           (format "at least %d"
                   (agent-scheme-primitive-procedure-minimum-arity
                    procedure)))
         (length arguments))))
    (agent-scheme--note-host-callback context procedure)
    (agent-scheme--check-value-budget
     (funcall (agent-scheme-primitive-procedure-function procedure)
              arguments context)
     context))
   ((agent-scheme-procedure-p procedure)
    (let* ((call-environment
            (agent-scheme--bind-formals
             (agent-scheme-procedure-formals procedure)
             arguments
             (agent-scheme-procedure-environment procedure)
             context))
           (body-state
            (agent-scheme--prepare-body-environment
             (agent-scheme-procedure-body procedure)
             call-environment
             context))
           (body-expression
            (agent-scheme--make-sequence (cdr body-state) nil)))
      (if tailp
          (agent-scheme--make-bounce
           body-expression
           (car body-state)
           (agent-scheme--eval-context-syntax-environment context))
        (agent-scheme--eval-sequence
         (cdr body-state) (car body-state) context nil nil))))
   (t
    (agent-scheme--eval-error
     "attempted to call non-procedure: %s"
     (agent-scheme-value->external procedure)))))

(defun agent-scheme--eval-if (parts environment context tailp)
  "Evaluate an if expression PARTS in ENVIRONMENT."
  (unless (memq (length parts) '(3 4))
    (agent-scheme--eval-error "if requires test, consequent, and optional alternate"))
  (let ((test-value
         (agent-scheme--eval-expression (cadr parts) environment context nil)))
    (cond
     ((agent-scheme--true-value-p test-value)
      (if tailp
          (agent-scheme--make-bounce
           (caddr parts)
           environment
           (agent-scheme--eval-context-syntax-environment context))
        (agent-scheme--eval-expression (caddr parts) environment context nil)))
     ((= (length parts) 4)
      (if tailp
          (agent-scheme--make-bounce
           (cadddr parts)
           environment
           (agent-scheme--eval-context-syntax-environment context))
        (agent-scheme--eval-expression (cadddr parts) environment context nil)))
     (t
      agent-scheme-unspecified))))

(defun agent-scheme--eval-set! (parts environment context)
  "Evaluate a set! expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 3)
    (agent-scheme--eval-error "set! requires an identifier and an expression"))
  (let ((target (cadr parts))
        (value (agent-scheme--eval-expression
                (caddr parts) environment context nil)))
    (unless (agent-scheme--identifier-datum-p target)
      (agent-scheme--eval-error "set! target must be an identifier"))
    (agent-scheme--environment-set-identifier environment target value)
    agent-scheme-unspecified))

(defun agent-scheme--tagged-list-p (datum tag)
  "Return non-nil if DATUM is a list whose first identifier names TAG."
  (and (consp datum)
       (agent-scheme--symbol-named-p (car datum) tag)))

(defun agent-scheme--single-argument-syntax (form description)
  "Return FORM's single operand or signal an error for DESCRIPTION."
  (let ((parts (agent-scheme--proper-list-elements form description)))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error "%s requires exactly one operand" description))
    (cadr parts)))

(defun agent-scheme--syntax-error-form-p (form)
  "Return non-nil if FORM is a syntax-error form."
  (agent-scheme--tagged-list-p form "syntax-error"))

(defun agent-scheme--syntax-error-message (form)
  "Return the user-facing message for syntax-error FORM."
  (let ((parts (agent-scheme--proper-list-elements form "syntax-error form")))
    (mapconcat #'agent-scheme-value->external (cdr parts) " ")))

(defun agent-scheme--raise-syntax-error (form &optional source-form)
  "Signal a syntax-error FORM, optionally attributed to SOURCE-FORM."
  (let ((message (agent-scheme--syntax-error-message form)))
    (if source-form
        (agent-scheme--eval-error
         "syntax-error while expanding %s: %s"
         (agent-scheme-value->external source-form)
         message)
      (agent-scheme--eval-error "syntax-error: %s" message))))

(defun agent-scheme--eval-quasiquote-list
    (template depth environment context)
  "Evaluate quasiquoted list TEMPLATE at nesting DEPTH."
  (let ((cursor template)
        output)
    (while (consp cursor)
      (let ((element (car cursor)))
        (if (and (= depth 1)
                 (agent-scheme--tagged-list-p element "unquote-splicing"))
            (let ((splice
                   (agent-scheme--eval-expression
                    (agent-scheme--single-argument-syntax
                     element "unquote-splicing")
                    environment
                    context
                    nil)))
              (dolist (splice-element
                       (agent-scheme--proper-list-elements
                        splice "unquote-splicing result"))
                (push splice-element output)))
          (push (agent-scheme--eval-quasiquote-template
                 element depth environment context)
                output)))
      (setq cursor (cdr cursor)))
    (append
     (nreverse output)
     (cond
      ((null cursor) nil)
      ((and (= depth 1)
            (agent-scheme--tagged-list-p cursor "unquote"))
       (agent-scheme--eval-expression
        (agent-scheme--single-argument-syntax cursor "unquote")
        environment
        context
        nil))
      (t
       (agent-scheme--eval-quasiquote-template
        cursor depth environment context))))))

(defun agent-scheme--eval-quasiquote-template
    (template depth environment context)
  "Evaluate quasiquote TEMPLATE at nesting DEPTH."
  (cond
   ((agent-scheme--tagged-list-p template "unquote")
    (let ((operand
           (agent-scheme--single-argument-syntax template "unquote")))
      (if (= depth 1)
          (agent-scheme--eval-expression operand environment context nil)
        (list (car template)
              (agent-scheme--eval-quasiquote-template
               operand (1- depth) environment context)))))
   ((agent-scheme--tagged-list-p template "unquote-splicing")
    (if (= depth 1)
        (agent-scheme--eval-error
         "unquote-splicing is only valid inside a quasiquoted list or vector")
      (let ((operand
             (agent-scheme--single-argument-syntax
              template "unquote-splicing")))
        (list (car template)
              (agent-scheme--eval-quasiquote-template
               operand (1- depth) environment context)))))
   ((agent-scheme--tagged-list-p template "quasiquote")
    (let ((operand
           (agent-scheme--single-argument-syntax template "quasiquote")))
      (list (car template)
            (agent-scheme--eval-quasiquote-template
             operand (1+ depth) environment context))))
   ((consp template)
    (agent-scheme--eval-quasiquote-list
     template depth environment context))
   ((vectorp template)
    (vconcat
     (agent-scheme--eval-quasiquote-list
      (append template nil) depth environment context)))
   (t template)))

(defun agent-scheme--eval-quasiquote (parts environment context)
  "Evaluate a quasiquote expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 2)
    (agent-scheme--eval-error "quasiquote requires exactly one template"))
  (agent-scheme--eval-quasiquote-template
   (cadr parts) 1 environment context))

(defun agent-scheme--parse-letrec-binding (binding description)
  "Return BINDING as (NAME . INITIALIZER) for DESCRIPTION."
  (let ((parts (agent-scheme--proper-list-elements binding description)))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "%s binding must contain an identifier and initializer"
       description))
    (cons (agent-scheme--expect-identifier-key
           (car parts) description)
          (cadr parts))))

(defun agent-scheme--eval-letrec
    (parts environment context tailp sequential)
  "Evaluate letrec or letrec* PARTS in ENVIRONMENT.
When SEQUENTIAL is non-nil, initializer values are installed after
each initializer."
  (unless (>= (length parts) 3)
    (agent-scheme--eval-error
     "%s requires bindings and a body"
     (if sequential "letrec*" "letrec")))
  (let* ((description (if sequential "letrec*" "letrec"))
         (bindings
          (mapcar
           (lambda (binding)
             (agent-scheme--parse-letrec-binding binding description))
           (agent-scheme--proper-list-elements
            (cadr parts) (format "%s binding list" description))))
         (names (mapcar #'car bindings))
         (local-environment
          (agent-scheme-make-empty-environment environment)))
    (agent-scheme--ensure-distinct-names names description)
    (dolist (name names)
      (agent-scheme--environment-define
       local-environment name agent-scheme--undefined))
    (if sequential
        (dolist (binding bindings)
          (agent-scheme--environment-set-cell
           local-environment
           (car binding)
           (agent-scheme--eval-expression
            (cdr binding) local-environment context nil)))
      (let (values)
        (dolist (binding bindings)
          (push
           (cons (car binding)
                 (agent-scheme--eval-expression
                  (cdr binding) local-environment context nil))
           values))
        (dolist (binding-value (nreverse values))
          (agent-scheme--environment-set-cell
           local-environment
           (car binding-value)
           (cdr binding-value)))))
    (agent-scheme--eval-sequence
     (cddr parts) local-environment context tailp t)))

(defun agent-scheme--make-empty-syntax-environment (&optional parent)
  "Return a fresh empty syntactic environment with optional PARENT."
  (agent-scheme--make-syntax-environment
   (make-hash-table :test #'equal) parent))

(defun agent-scheme--syntax-environment-ref (syntax-environment name)
  "Return syntactic binding NAME in SYNTAX-ENVIRONMENT, or nil."
  (let ((cursor syntax-environment)
        transformer)
    (while (and cursor (not transformer))
      (let ((candidate
             (gethash name
                      (agent-scheme--syntax-environment-bindings cursor)
                      agent-scheme--missing-cell)))
        (unless (eq candidate agent-scheme--missing-cell)
          (setq transformer candidate)))
      (setq cursor (agent-scheme--syntax-environment-parent cursor)))
    transformer))

(defun agent-scheme--syntax-environment-define
    (syntax-environment name transformer)
  "Bind syntactic NAME to TRANSFORMER in SYNTAX-ENVIRONMENT."
  (puthash name transformer
           (agent-scheme--syntax-environment-bindings syntax-environment)))

(defun agent-scheme--with-syntax-environment
    (context syntax-environment thunk)
  "Call THUNK with CONTEXT using SYNTAX-ENVIRONMENT."
  (let ((old-syntax-environment
         (agent-scheme--eval-context-syntax-environment context)))
    (unwind-protect
        (progn
          (setf (agent-scheme--eval-context-syntax-environment context)
                syntax-environment)
          (funcall thunk))
      (setf (agent-scheme--eval-context-syntax-environment context)
            old-syntax-environment))))

(defun agent-scheme--operator-shadowed-p (operator environment)
  "Return non-nil when OPERATOR is shadowed by a variable binding."
  (and (agent-scheme-symbol-p operator)
       (agent-scheme--environment-cell
        environment (agent-scheme-symbol-name operator))))

(defun agent-scheme--special-operator-active-p (operator environment)
  "Return non-nil if OPERATOR names an active core syntactic keyword."
  (and (agent-scheme--identifier-datum-p operator)
       (or (agent-scheme--identifier-p operator)
           (not (agent-scheme--operator-shadowed-p operator environment)))))

(defun agent-scheme--syntax-binding-for-operator
    (operator environment context)
  "Return macro transformer for OPERATOR in CONTEXT, or nil."
  (let ((name (agent-scheme--symbol-name operator)))
    (when (and name
               (not (agent-scheme--operator-shadowed-p operator environment)))
      (or
       (and (agent-scheme--identifier-p operator)
            (let* ((identifier-context
                    (agent-scheme--identifier-context operator))
                   (definition-syntax-environment
                    (and identifier-context
                         (agent-scheme--syntax-context-syntax-environment
                          identifier-context))))
              (and definition-syntax-environment
                   (agent-scheme--syntax-environment-ref
                    definition-syntax-environment name))))
       (agent-scheme--syntax-environment-ref
        (agent-scheme--eval-context-syntax-environment context)
        name)))))

(defun agent-scheme--ellipsis-identifier-p (datum ellipsis)
  "Return non-nil if DATUM is the active ELLIPSIS identifier."
  (and (agent-scheme--identifier-datum-p datum)
       (equal (agent-scheme--symbol-name datum) ellipsis)))

(defun agent-scheme--proper-list-elements-maybe (datum)
  "Return DATUM as a proper list of elements, or nil if improper."
  (let ((cursor datum)
        elements
        proper)
    (catch 'done
      (while t
        (cond
         ((null cursor)
          (setq proper t)
          (throw 'done nil))
         ((consp cursor)
          (push (car cursor) elements)
          (setq cursor (cdr cursor)))
         (t
          (throw 'done nil)))))
    (and proper (nreverse elements))))

(defun agent-scheme--syntax-rules-spec-p (form)
  "Return non-nil if FORM is a `syntax-rules' transformer spec."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "syntax-rules")))

(defun agent-scheme--parse-syntax-rule (rule)
  "Return RULE as a parsed (PATTERN . TEMPLATE) pair."
  (let ((parts (agent-scheme--proper-list-elements
                rule "syntax-rules rule")))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "syntax-rules rule must contain a pattern and a template"))
    (let ((pattern (car parts)))
      (unless (and (consp pattern)
                   (agent-scheme--identifier-datum-p (car pattern)))
        (agent-scheme--eval-error
         "syntax-rules pattern must be a list beginning with an identifier"))
      (cons pattern (cadr parts)))))

(defun agent-scheme--parse-syntax-rules
    (form value-environment syntax-environment)
  "Parse FORM as a high-level `syntax-rules' transformer."
  (unless (agent-scheme--syntax-rules-spec-p form)
    (agent-scheme--eval-error
     "transformer spec must be a syntax-rules form"))
  (let* ((parts (agent-scheme--proper-list-elements
                 form "syntax-rules form"))
         (tail (cdr parts))
         (ellipsis "...")
         literal-form
         rule-forms)
    (unless (>= (length tail) 2)
      (agent-scheme--eval-error
       "syntax-rules requires literals and at least one rule"))
    (if (and (agent-scheme--identifier-datum-p (car tail))
             (consp (cdr tail)))
        (progn
          (setq ellipsis
                (agent-scheme--expect-symbol-name
                 (car tail) "syntax-rules ellipsis"))
          (setq literal-form (cadr tail))
          (setq rule-forms (cddr tail)))
      (setq literal-form (car tail))
      (setq rule-forms (cdr tail)))
    (let ((literals
           (mapcar
            (lambda (literal)
              (unless (agent-scheme--identifier-datum-p literal)
                (agent-scheme--eval-error
                 "syntax-rules literal must be an identifier"))
              literal)
            (agent-scheme--proper-list-elements
             literal-form "syntax-rules literal list"))))
      (agent-scheme--make-syntax-transformer
       ellipsis
       literals
       (mapcar #'agent-scheme--parse-syntax-rule rule-forms)
       value-environment
       syntax-environment))))

(defun agent-scheme--syntax-literal-p (identifier literals)
  "Return non-nil if IDENTIFIER is one of LITERALS."
  (member (agent-scheme--symbol-name identifier)
          (mapcar #'agent-scheme--symbol-name literals)))

(defun agent-scheme--path-prefix-p (prefix path)
  "Return non-nil when PREFIX is an initial segment of PATH."
  (and (<= (length prefix) (length path))
       (cl-loop for left in prefix
                for right in path
                always (= left right))))

(defun agent-scheme--ensure-pattern-binding (bindings name depth)
  "Return pattern binding NAME in BINDINGS, creating it at DEPTH."
  (let ((entry (gethash name bindings)))
    (cond
     ((null entry)
      (setq entry
            (agent-scheme--make-pattern-binding
             depth
             (make-hash-table :test #'equal)))
      (puthash name entry bindings))
     ((and (> (hash-table-count
               (agent-scheme--pattern-binding-captures entry))
              0)
           (/= (agent-scheme--pattern-binding-depth entry) depth))
      (agent-scheme--eval-error
       "pattern variable used at inconsistent ellipsis depth: %s"
       name))
     ((< (agent-scheme--pattern-binding-depth entry) depth)
      (setf (agent-scheme--pattern-binding-depth entry) depth)))
    entry))

(defun agent-scheme--syntax-bind-pattern-variable
    (bindings name value path)
  "Bind pattern variable NAME to VALUE at nested ellipsis PATH."
  (let* ((depth (length path))
         (entry (agent-scheme--ensure-pattern-binding bindings name depth))
         (captures (agent-scheme--pattern-binding-captures entry)))
    (unless (eq (gethash path captures agent-scheme--missing-cell)
                agent-scheme--missing-cell)
      (agent-scheme--eval-error
       "duplicate pattern variable: %s" name))
    (puthash path value captures))
  t)

(defun agent-scheme--pattern-variable-names (pattern literals ellipsis)
  "Return pattern variable names contained in PATTERN."
  (cond
   ((agent-scheme--identifier-datum-p pattern)
    (let ((name (agent-scheme--symbol-name pattern)))
      (unless (or (equal name "_")
                  (equal name ellipsis)
                  (member name (mapcar #'agent-scheme--symbol-name
                                       literals)))
        (list name))))
   ((consp pattern)
    (let ((elements (agent-scheme--proper-list-elements-maybe pattern)))
      (when elements
        (apply #'append
               (mapcar
                (lambda (element)
                  (agent-scheme--pattern-variable-names
                   element literals ellipsis))
                elements)))))
   ((vectorp pattern)
    (apply #'append
           (mapcar
            (lambda (element)
              (agent-scheme--pattern-variable-names
               element literals ellipsis))
            (append pattern nil))))
   (t nil)))

(defun agent-scheme--bind-empty-repeated-pattern-variables
    (pattern literals ellipsis bindings path)
  "Record empty repeated matches for variables in PATTERN at PATH."
  (dolist (name (agent-scheme--pattern-variable-names
                 pattern literals ellipsis))
    (let ((entry
           (agent-scheme--ensure-pattern-binding
            bindings name (1+ (length path)))))
      (cl-pushnew path
                  (agent-scheme--pattern-binding-empty-prefixes entry)
                  :test #'equal))))

(defun agent-scheme--list-elements-tail (datum)
  "Return (ELEMENTS . TAIL) for possibly improper list DATUM."
  (let ((cursor datum)
        elements)
    (while (consp cursor)
      (push (car cursor) elements)
      (setq cursor (cdr cursor)))
    (cons (nreverse elements) cursor)))

(defun agent-scheme--identifier-syntax-binding-in
    (identifier syntax-environment)
  "Return syntactic binding for IDENTIFIER in SYNTAX-ENVIRONMENT."
  (let ((name (agent-scheme--symbol-name identifier)))
    (and name
         (or
          (and (agent-scheme--identifier-p identifier)
               (let* ((identifier-context
                       (agent-scheme--identifier-context identifier))
                      (definition-syntax-environment
                       (and identifier-context
                            (agent-scheme--syntax-context-syntax-environment
                             identifier-context))))
                 (and definition-syntax-environment
                      (agent-scheme--syntax-environment-ref
                       definition-syntax-environment name))))
          (and syntax-environment
               (agent-scheme--syntax-environment-ref
                syntax-environment name))))))

(defun agent-scheme--identifier-binding-token
    (identifier value-environment syntax-environment)
  "Return lexical binding token for IDENTIFIER."
  (let ((cell (and value-environment
                   (agent-scheme--environment-cell-for-identifier
                    value-environment identifier)))
        (syntax-binding
         (agent-scheme--identifier-syntax-binding-in
          identifier syntax-environment)))
    (cond
     (cell (cons 'value cell))
     (syntax-binding (cons 'syntax syntax-binding))
     (t nil))))

(defun agent-scheme--binding-tokens-equal-p (left right)
  "Return non-nil if lexical binding tokens LEFT and RIGHT are equal."
  (cond
   ((and (null left) (null right)) t)
   ((and left right
         (eq (car left) (car right))
         (eq (cdr left) (cdr right)))
    t)
   (t nil)))

(defun agent-scheme--literal-identifier-match-p
    (pattern input transformer use-environment use-syntax-environment)
  "Return non-nil if literal PATTERN matches INPUT."
  (and (agent-scheme--identifier-datum-p input)
       (equal (agent-scheme--symbol-name pattern)
              (agent-scheme--symbol-name input))
       (agent-scheme--binding-tokens-equal-p
        (agent-scheme--identifier-binding-token
         pattern
         (agent-scheme--syntax-transformer-value-environment transformer)
         (agent-scheme--syntax-transformer-syntax-environment transformer))
        (agent-scheme--identifier-binding-token
         input use-environment use-syntax-environment))))

(defun agent-scheme--find-ellipsis-index (patterns ellipsis)
  "Return index of the first ellipsis in PATTERNS, or nil."
  (let ((index 1)
        found)
    (while (and (null found) (< index (length patterns)))
      (when (agent-scheme--ellipsis-identifier-p (nth index patterns) ellipsis)
        (setq found index))
      (setq index (1+ index)))
    found))

(defun agent-scheme--match-pattern
    (pattern input transformer bindings path use-environment
             use-syntax-environment)
  "Return non-nil if PATTERN matches INPUT at nested ellipsis PATH."
  (let ((literals (agent-scheme--syntax-transformer-literals transformer))
        (ellipsis (agent-scheme--syntax-transformer-ellipsis transformer)))
    (cond
     ((agent-scheme--identifier-datum-p pattern)
      (let ((name (agent-scheme--symbol-name pattern)))
        (cond
         ((and (equal name "_")
               (not (agent-scheme--syntax-literal-p pattern literals)))
          t)
         ((agent-scheme--syntax-literal-p pattern literals)
          (agent-scheme--literal-identifier-match-p
           pattern input transformer use-environment use-syntax-environment))
         ((equal name ellipsis)
          (and (agent-scheme--identifier-datum-p input)
               (equal name (agent-scheme--symbol-name input))))
         (t
          (agent-scheme--syntax-bind-pattern-variable
           bindings name input path)))))
     ((consp pattern)
      (and (consp input)
           (let* ((pattern-list
                   (agent-scheme--list-elements-tail pattern))
                  (input-list
                   (agent-scheme--list-elements-tail input)))
             (agent-scheme--match-pattern-elements
              (car pattern-list)
              (cdr pattern-list)
              (car input-list)
              (cdr input-list)
              transformer
              bindings
              path
              use-environment
              use-syntax-environment))))
     ((vectorp pattern)
      (and (vectorp input)
           (agent-scheme--match-pattern-elements
            (append pattern nil)
            nil
            (append input nil)
            nil
            transformer
            bindings
            path
            use-environment
            use-syntax-environment)))
     (t
      (equal pattern input)))))

(defun agent-scheme--match-fixed-pattern-elements
    (patterns pattern-tail input-elements input-tail transformer bindings path
              use-environment use-syntax-environment)
  "Match fixed PATTERNS and PATTERN-TAIL against input pieces."
  (and (>= (length input-elements) (length patterns))
       (cl-loop for pattern in patterns
                for input in input-elements
                always
                (agent-scheme--match-pattern
                 pattern input transformer bindings path
                 use-environment use-syntax-environment))
       (let ((remaining
              (nthcdr (length patterns) input-elements)))
         (if pattern-tail
             (agent-scheme--match-pattern
              pattern-tail
              (append remaining input-tail)
              transformer
              bindings
              path
              use-environment
              use-syntax-environment)
           (and (null remaining) (null input-tail))))))

(defun agent-scheme--match-pattern-elements
    (patterns pattern-tail input-elements input-tail transformer bindings path
              use-environment use-syntax-environment)
  "Return non-nil if PATTERNS match INPUT-ELEMENTS."
  (let* ((ellipsis (agent-scheme--syntax-transformer-ellipsis transformer))
         (ellipsis-index
          (agent-scheme--find-ellipsis-index patterns ellipsis)))
    (if ellipsis-index
        (let* ((prefix-count (1- ellipsis-index))
               (suffix (nthcdr (1+ ellipsis-index) patterns))
               (suffix-count (length suffix))
               (repeat-pattern (nth (1- ellipsis-index) patterns))
               (repeat-count (- (length input-elements)
                                prefix-count
                                suffix-count)))
          (and (>= repeat-count 0)
               (cl-loop for pattern in (cl-subseq patterns 0 prefix-count)
                        for input in input-elements
                        always
                        (agent-scheme--match-pattern
                         pattern input transformer bindings path
                         use-environment use-syntax-environment))
               (progn
                 (when (= repeat-count 0)
                   (agent-scheme--bind-empty-repeated-pattern-variables
                    repeat-pattern
                    (agent-scheme--syntax-transformer-literals transformer)
                    ellipsis
                    bindings
                    path))
                 t)
               (cl-loop for input in (cl-subseq
                                      input-elements
                                      prefix-count
                                      (+ prefix-count repeat-count))
                        for index from 0
                        always
                        (agent-scheme--match-pattern
                         repeat-pattern input transformer bindings
                         (append path (list index))
                         use-environment use-syntax-environment))
               (cl-loop for pattern in suffix
                        for input in (if (> suffix-count 0)
                                         (last input-elements suffix-count)
                                       nil)
                        always
                        (agent-scheme--match-pattern
                         pattern input transformer bindings path
                         use-environment use-syntax-environment))
               (if pattern-tail
                   (agent-scheme--match-pattern
                    pattern-tail
                    input-tail
                    transformer
                    bindings
                    path
                    use-environment
                    use-syntax-environment)
                 (null input-tail))))
      (agent-scheme--match-fixed-pattern-elements
       patterns pattern-tail input-elements input-tail transformer bindings path
       use-environment use-syntax-environment))))

(defun agent-scheme--match-syntax-rule
    (rule form transformer bindings use-environment use-syntax-environment)
  "Return non-nil if RULE matches macro use FORM."
  (let* ((pattern-list (agent-scheme--list-elements-tail (car rule)))
         (input-list (agent-scheme--list-elements-tail form))
         (pattern-elements (car pattern-list))
         (input-elements (car input-list)))
    (and pattern-elements
         input-elements
         (null (cdr input-list))
         (agent-scheme--match-pattern-elements
          (cdr pattern-elements)
          (cdr pattern-list)
          (cdr input-elements)
          nil
          transformer
          bindings
          nil
          use-environment
          use-syntax-environment))))

(defun agent-scheme--template-pattern-variable-names
    (template bindings ellipsis)
  "Return pattern variable names referenced in TEMPLATE."
  (cond
   ((agent-scheme--identifier-datum-p template)
    (let ((name (agent-scheme--symbol-name template)))
      (and (not (equal name ellipsis))
           (gethash name bindings)
           (list name))))
   ((consp template)
    (let* ((pieces (agent-scheme--list-elements-tail template))
           (names
            (apply #'append
                   (mapcar
                    (lambda (element)
                      (agent-scheme--template-pattern-variable-names
                       element bindings ellipsis))
                    (car pieces)))))
      (if (cdr pieces)
          (append names
                  (agent-scheme--template-pattern-variable-names
                   (cdr pieces) bindings ellipsis))
        names)))
   ((vectorp template)
    (apply #'append
           (mapcar
            (lambda (element)
              (agent-scheme--template-pattern-variable-names
               element bindings ellipsis))
            (append template nil))))
   (t nil)))

(defun agent-scheme--pattern-binding-repeat-count-at (entry path)
  "Return repetition count for ENTRY one level below PATH, or nil."
  (when (> (agent-scheme--pattern-binding-depth entry) (length path))
    (let ((indices nil))
      (maphash
       (lambda (capture-path _value)
         (when (and (> (length capture-path) (length path))
                    (agent-scheme--path-prefix-p path capture-path))
           (cl-pushnew (nth (length path) capture-path)
                       indices)))
       (agent-scheme--pattern-binding-captures entry))
      (dolist (empty-prefix
               (agent-scheme--pattern-binding-empty-prefixes entry))
        (when (and (> (length empty-prefix) (length path))
                   (agent-scheme--path-prefix-p path empty-prefix))
          (cl-pushnew (nth (length path) empty-prefix) indices)))
      (cond
       (indices
        (1+ (apply #'max indices)))
       ((member path
                (agent-scheme--pattern-binding-empty-prefixes entry))
        0)
       (t nil)))))

(defun agent-scheme--template-repeat-count (template bindings ellipsis path)
  "Return the repetition count required by TEMPLATE at PATH."
  (let ((count nil))
    (dolist (name (agent-scheme--template-pattern-variable-names
                   template bindings ellipsis))
      (let* ((entry (gethash name bindings))
             (entry-count
              (and entry
                   (agent-scheme--pattern-binding-repeat-count-at
                    entry path))))
        (when entry-count
          (cond
           ((null count)
            (setq count entry-count))
           ((/= count entry-count)
            (agent-scheme--eval-error
             "template ellipsis variables have different lengths"))))))
    (or count
        (agent-scheme--eval-error
         "template ellipsis must contain a repeated pattern variable"))))

(defun agent-scheme--pattern-binding-value-at (entry name path)
  "Return captured value for NAME from ENTRY at PATH."
  (let* ((depth (agent-scheme--pattern-binding-depth entry))
         (capture-path
          (if (<= depth (length path))
              (cl-subseq path 0 depth)
            (agent-scheme--eval-error
             "repeated pattern variable used without enough ellipses: %s"
             name)))
         (value
          (gethash capture-path
                   (agent-scheme--pattern-binding-captures entry)
                   agent-scheme--missing-cell)))
    (if (eq value agent-scheme--missing-cell)
        (agent-scheme--eval-error
         "missing pattern variable capture: %s" name)
      value)))

(defun agent-scheme--expand-template
    (template bindings syntax-context ellipsis &optional path ellipsis-literal)
  "Expand TEMPLATE using BINDINGS and SYNTAX-CONTEXT."
  (setq path (or path nil))
  (cond
   ((agent-scheme--identifier-datum-p template)
    (let* ((name (agent-scheme--symbol-name template))
           (entry (and (not (equal name ellipsis))
                       (gethash name bindings))))
      (cond
       (entry
        (agent-scheme--pattern-binding-value-at entry name path))
       ((and (equal name ellipsis) (not ellipsis-literal))
        (agent-scheme--eval-error "misplaced ellipsis in template"))
       (t
        (agent-scheme--make-identifier name syntax-context)))))
   ((consp template)
    (let* ((pieces (agent-scheme--list-elements-tail template))
           (elements (car pieces))
           (tail (cdr pieces)))
      (if (and (not ellipsis-literal)
               (null tail)
               (= (length elements) 2)
               (agent-scheme--ellipsis-identifier-p (car elements) ellipsis))
          (agent-scheme--expand-template
           (cadr elements) bindings syntax-context ellipsis path t)
        (let ((cursor elements)
              output)
          (while cursor
            (let ((element (car cursor))
                  (next (cadr cursor)))
              (if (and next
                       (not ellipsis-literal)
                       (agent-scheme--ellipsis-identifier-p next ellipsis))
                  (let ((count (agent-scheme--template-repeat-count
                                element bindings ellipsis path))
                        expanded)
                    (dotimes (index count)
                      (push (agent-scheme--expand-template
                             element bindings syntax-context ellipsis
                             (append path (list index)))
                            expanded))
                    (dolist (expanded-element (nreverse expanded))
                      (push expanded-element output))
                    (setq cursor (cddr cursor)))
                (push (agent-scheme--expand-template
                       element bindings syntax-context ellipsis path
                       ellipsis-literal)
                      output)
                (setq cursor (cdr cursor)))))
          (append (nreverse output)
                  (and tail
                       (agent-scheme--expand-template
                        tail bindings syntax-context ellipsis path
                        ellipsis-literal)))))))
   ((vectorp template)
    (vconcat
     (agent-scheme--proper-list-elements
      (agent-scheme--expand-template
       (append template nil)
       bindings syntax-context ellipsis path ellipsis-literal)
      "syntax-rules vector template")))
   (t template)))

(defun agent-scheme--apply-syntax-transformer
    (transformer form environment context)
  "Apply TRANSFORMER to macro use FORM."
  (let ((matched nil)
        result
        (use-syntax-environment
         (agent-scheme--eval-context-syntax-environment context)))
    (dolist (rule (agent-scheme--syntax-transformer-rules transformer))
      (unless matched
        (let ((bindings (make-hash-table :test #'equal)))
          (when (agent-scheme--match-syntax-rule
                 rule form transformer bindings environment
                 use-syntax-environment)
            (setq matched t)
            (setq result
                  (agent-scheme--expand-template
                   (cdr rule)
                   bindings
                   (agent-scheme--make-syntax-context
                    (make-symbol "syntax")
                    (agent-scheme--syntax-transformer-value-environment
                     transformer)
                    (agent-scheme--syntax-transformer-syntax-environment
                     transformer))
                   (agent-scheme--syntax-transformer-ellipsis
                    transformer)))))))
    (unless matched
      (agent-scheme--eval-error
       "macro use does not match any syntax-rules pattern: %s"
       (agent-scheme-value->external form)))
    (when (agent-scheme--syntax-error-form-p result)
      (agent-scheme--raise-syntax-error result form))
    result))

(defun agent-scheme--syntax-definition-form-p (form)
  "Return non-nil if FORM is a `define-syntax' form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "define-syntax")))

(defun agent-scheme--eval-define-syntax
    (form environment context syntax-environment)
  "Install the syntax definition FORM in SYNTAX-ENVIRONMENT."
  (let ((parts (agent-scheme--proper-list-elements
                form "define-syntax form")))
    (unless (= (length parts) 3)
      (agent-scheme--eval-error
       "define-syntax requires a keyword and transformer spec"))
    (let ((keyword
           (agent-scheme--expect-symbol-name
            (cadr parts) "define-syntax keyword"))
          (transformer
           (agent-scheme--parse-syntax-rules
            (caddr parts)
            environment
            syntax-environment)))
      (agent-scheme--syntax-environment-define
       syntax-environment keyword transformer)
      agent-scheme-unspecified)))

(defun agent-scheme--parse-let-syntax-binding (binding)
  "Return BINDING as (KEYWORD . TRANSFORMER-SPEC)."
  (let ((parts (agent-scheme--proper-list-elements
                binding "syntax binding")))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "syntax binding must contain a keyword and transformer spec"))
    (cons (agent-scheme--expect-symbol-name
           (car parts) "syntax binding keyword")
          (cadr parts))))

(defun agent-scheme--make-local-syntax-scope
    (parts environment context recursive)
  "Return a local syntax scope from let-syntax PARTS.
When RECURSIVE is non-nil, transformer specs see the new bindings."
  (unless (>= (length parts) 3)
    (agent-scheme--eval-error
     "%s requires bindings and a body"
     (if recursive "letrec-syntax" "let-syntax")))
  (let* ((outer-syntax-environment
          (agent-scheme--eval-context-syntax-environment context))
         (local-syntax-environment
          (agent-scheme--make-empty-syntax-environment
           outer-syntax-environment))
         (bindings
          (mapcar #'agent-scheme--parse-let-syntax-binding
                  (agent-scheme--proper-list-elements
                   (cadr parts) "syntax binding list")))
         seen)
    (dolist (binding bindings)
      (let ((keyword (car binding)))
        (when (member keyword seen)
          (agent-scheme--eval-error
           "duplicate syntax binding: %s" keyword))
        (push keyword seen)))
    (dolist (binding bindings)
      (agent-scheme--syntax-environment-define
       local-syntax-environment
       (car binding)
       (agent-scheme--parse-syntax-rules
        (cdr binding)
        environment
        (if recursive
            local-syntax-environment
          outer-syntax-environment))))
    (agent-scheme--make-syntax-scope
     (cddr parts)
     local-syntax-environment)))

(defconst agent-scheme--scheme-base-library-key "(scheme base)"
  "Registry key for the required R7RS `(scheme base)' library.")

(defconst agent-scheme--empty-emacs-capability-library-keys
  '("(emacs buffer)"
    "(emacs buffer edit)"
    "(emacs command)"
    "(emacs project)"
    "(emacs window)")
  "Recognized Emacs capability libraries without bootstrap exports yet.")

(defconst agent-scheme--standard-library-keys
  '("(scheme case-lambda)"
    "(scheme char)"
    "(scheme cxr)"
    "(scheme file)"
    "(scheme lazy)"
    "(scheme write)")
  "Standard R7RS library keys with focused bootstrap support.")

(defconst agent-scheme--case-lambda-library-source
  "(define-library (scheme case-lambda)
     (export case-lambda)
     (import (scheme base))
     (begin
       (define-syntax case-lambda
         (syntax-rules ()
           ((case-lambda)
            (lambda args (car '())))
           ((case-lambda ((param ...) body ...) more ...)
            (lambda args
              (if (= (length args) (length '(param ...)))
                  (apply (lambda (param ...) body ...) args)
                  (apply (case-lambda more ...) args))))))))"
  "Portable bootstrap source for `(scheme case-lambda)'.")

(defconst agent-scheme--lazy-library-source
  "(define-library (scheme lazy)
     (export delay delay-force force make-promise promise?)
     (import (scheme base))
     (begin
       (define (%promise lazy? value)
         (list 'agent-scheme-promise lazy? value))
       (define (promise? obj)
         (and (pair? obj)
              (eq? (car obj) 'agent-scheme-promise)))
       (define (make-promise obj)
         (if (promise? obj)
             obj
             (%promise #t obj)))
       (define (force promise)
         (if (promise? promise)
             (if (cadr promise)
                 (car (cdr (cdr promise)))
                 (let ((value ((car (cdr (cdr promise))))))
                   (set-car! (cdr promise) #t)
                   (set-car! (cdr (cdr promise)) value)
                   value))
             promise))
       (define-syntax delay-force
         (syntax-rules ()
           ((delay-force expression)
            (%promise #f (lambda () expression)))))
       (define-syntax delay
         (syntax-rules ()
           ((delay expression)
            (delay-force expression))))))"
  "Portable bootstrap source for `(scheme lazy)'.")

(defun agent-scheme--nonnegative-exact-integer-datum-p (datum)
  "Return non-nil if DATUM is an exact non-negative integer datum."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-kind datum) 'integer)
       (eq (agent-scheme-number-exactness datum) 'exact)
       (>= (agent-scheme-number-value datum) 0)))

(defun agent-scheme--library-name-p (datum)
  "Return non-nil if DATUM is a valid R7RS library name datum."
  (and (consp datum)
       (let ((parts (agent-scheme--proper-list-elements-maybe datum)))
         (and parts
              (cl-every
               (lambda (part)
                 (or (agent-scheme-symbol-p part)
                     (agent-scheme--nonnegative-exact-integer-datum-p part)))
               parts)))))

(defun agent-scheme--library-name-key (name)
  "Return the registry key for library NAME."
  (unless (agent-scheme--library-name-p name)
    (agent-scheme--eval-error
     "invalid library name: %s" (agent-scheme-value->external name)))
  (agent-scheme-datum->external (agent-scheme--strip-identifiers name)))

(defun agent-scheme--current-environment-cell (environment name)
  "Return NAME's cell in ENVIRONMENT's current frame, or nil."
  (let ((cell (gethash name
                       (agent-scheme--environment-bindings environment)
                       agent-scheme--missing-cell)))
    (unless (eq cell agent-scheme--missing-cell)
      cell)))

(defun agent-scheme--current-syntax-binding (syntax-environment name)
  "Return NAME's binding in SYNTAX-ENVIRONMENT's current frame, or nil."
  (let ((binding (gethash
                  name
                  (agent-scheme--syntax-environment-bindings
                   syntax-environment)
                  agent-scheme--missing-cell)))
    (unless (eq binding agent-scheme--missing-cell)
      binding)))

(defun agent-scheme--form-named-p (form name)
  "Return non-nil when FORM is a list beginning with identifier NAME."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) name)))

(defun agent-scheme--import-form-p (form)
  "Return non-nil if FORM is an import declaration."
  (agent-scheme--form-named-p form "import"))

(defun agent-scheme--define-library-form-p (form)
  "Return non-nil if FORM is a define-library form."
  (agent-scheme--form-named-p form "define-library"))

(defun agent-scheme--library-binding-with-name (binding name)
  "Return BINDING renamed to local NAME."
  (agent-scheme--make-library-binding
   name
   (agent-scheme--library-binding-kind binding)
   (agent-scheme--library-binding-object binding)
   (agent-scheme--library-binding-library-key binding)))

(defun agent-scheme--same-library-binding-p (left right)
  "Return non-nil if LEFT and RIGHT identify the same imported binding."
  (and (agent-scheme--library-binding-p left)
       (agent-scheme--library-binding-p right)
       (eq (agent-scheme--library-binding-kind left)
           (agent-scheme--library-binding-kind right))
       (eq (agent-scheme--library-binding-object left)
           (agent-scheme--library-binding-object right))))

(defun agent-scheme--snapshot-library-bindings
    (value-environment syntax-environment library-key)
  "Return exported bindings from VALUE-ENVIRONMENT and SYNTAX-ENVIRONMENT."
  (let (exports)
    (maphash
     (lambda (name cell)
       (push (agent-scheme--make-library-binding
              name 'value cell library-key)
             exports))
     (agent-scheme--environment-bindings value-environment))
    (maphash
     (lambda (name transformer)
       (push (agent-scheme--make-library-binding
              name 'syntax transformer library-key)
             exports))
     (agent-scheme--syntax-environment-bindings syntax-environment))
    (nreverse exports)))

(defun agent-scheme--register-scheme-base-library
    (context environment)
  "Register the builtin `(scheme base)' library in CONTEXT."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash agent-scheme--scheme-base-library-key registry)
      (let* ((use-current-environment
              (agent-scheme--environment-cell environment "+"))
             (base-environment
              (if use-current-environment
                  environment
                (agent-scheme-make-base-environment)))
             (base-context
              (if use-current-environment
                  context
                (agent-scheme--new-eval-context nil))))
        (unless use-current-environment
          (agent-scheme--ensure-base-syntax
           base-context base-environment))
        (let* ((syntax-environment
                (agent-scheme--eval-context-syntax-environment
                 base-context))
               (exports
                (agent-scheme--snapshot-library-bindings
                 base-environment
                 syntax-environment
                 agent-scheme--scheme-base-library-key)))
          (puthash
           agent-scheme--scheme-base-library-key
           (agent-scheme--make-library
            (list (agent-scheme--syntax-symbol "scheme")
                  (agent-scheme--syntax-symbol "base"))
            agent-scheme--scheme-base-library-key
            exports
            base-environment
            syntax-environment)
           registry))))))

(defun agent-scheme--register-empty-emacs-capability-library
    (key context)
  "Register an empty Emacs capability library named by KEY."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash key registry)
      (let ((value-environment (agent-scheme-make-empty-environment))
            (syntax-environment
             (agent-scheme--make-empty-syntax-environment)))
        (puthash
         key
         (agent-scheme--make-library
          (agent-scheme-read key)
          key
          nil
          value-environment
          syntax-environment)
         registry)))))

(defun agent-scheme--register-source-library
    (source context environment)
  "Evaluate one define-library SOURCE into CONTEXT."
  (agent-scheme--eval-define-library
   (agent-scheme-read source)
   environment
   context))

(defun agent-scheme--find-library-export (name exports)
  "Return export named NAME from EXPORTS, or nil."
  (cl-find name exports
           :key #'agent-scheme--library-binding-name
           :test #'equal))

(defun agent-scheme--register-subset-library
    (key export-names context environment)
  "Register KEY as a subset of `(scheme base)' EXPORT-NAMES."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (agent-scheme--resolve-library
               (agent-scheme-read agent-scheme--scheme-base-library-key)
               context
               environment))
             (base-exports
              (agent-scheme--library-exports base-library))
             (exports
              (mapcar
               (lambda (name)
                 (or (agent-scheme--find-library-export
                      name base-exports)
                     (agent-scheme--eval-error
                      "standard library binding is not available: %s"
                      name)))
               export-names)))
        (puthash
         key
         (agent-scheme--make-library
          (agent-scheme-read key)
          key
          exports
          (agent-scheme--library-value-environment base-library)
          (agent-scheme--library-syntax-environment base-library))
         registry)))))

(defun agent-scheme--register-primitive-library
    (key primitive-specs context)
  "Register KEY with PRIMITIVE-SPECS.
Each spec has (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY)."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash key registry)
      (let ((value-environment (agent-scheme-make-empty-environment))
            (syntax-environment
             (agent-scheme--make-empty-syntax-environment)))
        (dolist (spec primitive-specs)
          (agent-scheme--define-primitive
           value-environment
           (nth 0 spec)
           (nth 1 spec)
           (nth 2 spec)
           (nth 3 spec)))
        (puthash
         key
         (agent-scheme--make-library
          (agent-scheme-read key)
          key
          (agent-scheme--snapshot-library-bindings
           value-environment syntax-environment key)
          value-environment
          syntax-environment)
         registry)))))

(defun agent-scheme--register-standard-library
    (key context environment)
  "Register focused standard library KEY in CONTEXT."
  (pcase key
    ("(scheme case-lambda)"
     (agent-scheme--register-source-library
      agent-scheme--case-lambda-library-source context environment))
    ("(scheme char)"
     (agent-scheme--register-primitive-library
      key
      `(("char-upcase" ,#'agent-scheme--primitive-char-upcase 1 1))
      context))
    ("(scheme cxr)"
     (agent-scheme--register-subset-library
      key '("caar" "cadr" "cdar" "cddr") context environment))
    ("(scheme file)"
     (agent-scheme--register-primitive-library
      key
      `(("file-exists?" ,#'agent-scheme--primitive-file-exists? 1 1))
      context))
    ("(scheme lazy)"
     (agent-scheme--register-source-library
      agent-scheme--lazy-library-source context environment))
    ("(scheme write)"
     (agent-scheme--register-primitive-library
      key
      `(("display" ,#'agent-scheme--primitive-display 1 2)
        ("write" ,#'agent-scheme--primitive-write 1 2)
        ("open-output-string"
         ,#'agent-scheme--primitive-open-output-string 0 0)
        ("get-output-string"
         ,#'agent-scheme--primitive-get-output-string 1 1))
      context))
    (_
     (agent-scheme--eval-error "unknown standard library: %s" key))))

(defun agent-scheme--library-available-p (name context environment)
  "Return non-nil if NAME can be imported."
  (let ((key (agent-scheme--library-name-key name)))
    (cond
     ((equal key agent-scheme--scheme-base-library-key)
      t)
     ((member key agent-scheme--standard-library-keys)
      t)
     ((member key agent-scheme--empty-emacs-capability-library-keys)
      t)
     (t
      (and (gethash key (agent-scheme--eval-context-libraries context))
           t)))))

(defun agent-scheme--resolve-library (name context environment)
  "Return library NAME from CONTEXT, registering builtins when needed."
  (let ((key (agent-scheme--library-name-key name)))
    (cond
     ((equal key agent-scheme--scheme-base-library-key)
      (agent-scheme--register-scheme-base-library context environment))
     ((member key agent-scheme--standard-library-keys)
      (agent-scheme--register-standard-library key context environment))
     ((member key agent-scheme--empty-emacs-capability-library-keys)
      (agent-scheme--register-empty-emacs-capability-library key context)))
    (or (gethash key (agent-scheme--eval-context-libraries context))
        (agent-scheme--eval-error "unknown library: %s" key))))

(defun agent-scheme--import-binding-local-name (binding)
  "Return BINDING's local import name."
  (agent-scheme--library-binding-name binding))

(defun agent-scheme--find-import-binding (name bindings)
  "Return import binding named NAME from BINDINGS, or nil."
  (cl-find name bindings
           :key #'agent-scheme--import-binding-local-name
           :test #'equal))

(defun agent-scheme--ensure-import-names-present
    (names bindings description)
  "Signal if any NAMES are absent from BINDINGS for DESCRIPTION."
  (dolist (name names)
    (unless (agent-scheme--find-import-binding name bindings)
      (agent-scheme--eval-error
       "%s import name not found: %s" description name))))

(defun agent-scheme--ensure-compatible-import-bindings (bindings)
  "Return BINDINGS after checking for duplicate incompatible names."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (binding bindings)
      (let* ((name (agent-scheme--library-binding-name binding))
             (previous (gethash name seen)))
        (cond
         ((null previous)
          (puthash name binding seen)
          (push binding result))
         ((agent-scheme--same-library-binding-p previous binding))
         (t
          (agent-scheme--eval-error
           "conflicting imports for identifier: %s" name)))))
    (nreverse result)))

(defun agent-scheme--import-modifier-identifiers (forms description)
  "Return FORMS as identifier name strings for DESCRIPTION."
  (mapcar
   (lambda (form)
     (agent-scheme--expect-symbol-name form description))
   forms))

(defun agent-scheme--resolve-import-set
    (import-set context environment)
  "Resolve IMPORT-SET to a list of library bindings."
  (cond
   ((agent-scheme--library-name-p import-set)
    (copy-sequence
     (agent-scheme--library-exports
      (agent-scheme--resolve-library import-set context environment))))
   ((consp import-set)
    (let* ((parts (agent-scheme--proper-list-elements
                   import-set "import set"))
           (operator (car parts)))
      (cond
       ((agent-scheme--symbol-named-p operator "only")
        (unless (>= (length parts) 2)
          (agent-scheme--eval-error "only import set requires an import set"))
        (let* ((bindings
                (agent-scheme--resolve-import-set
                 (cadr parts) context environment))
               (names
                (agent-scheme--import-modifier-identifiers
                 (cddr parts) "only")))
          (agent-scheme--ensure-import-names-present names bindings "only")
          (cl-remove-if-not
           (lambda (binding)
             (member (agent-scheme--library-binding-name binding)
                     names))
           bindings)))
       ((agent-scheme--symbol-named-p operator "except")
        (unless (>= (length parts) 2)
          (agent-scheme--eval-error
           "except import set requires an import set"))
        (let* ((bindings
                (agent-scheme--resolve-import-set
                 (cadr parts) context environment))
               (names
                (agent-scheme--import-modifier-identifiers
                 (cddr parts) "except")))
          (agent-scheme--ensure-import-names-present names bindings "except")
          (cl-remove-if
           (lambda (binding)
             (member (agent-scheme--library-binding-name binding)
                     names))
           bindings)))
       ((agent-scheme--symbol-named-p operator "prefix")
        (unless (= (length parts) 3)
          (agent-scheme--eval-error
           "prefix import set requires an import set and prefix"))
        (let ((prefix
               (agent-scheme--expect-symbol-name
                (caddr parts) "prefix identifier")))
          (mapcar
           (lambda (binding)
             (agent-scheme--library-binding-with-name
              binding
              (concat prefix
                      (agent-scheme--library-binding-name binding))))
           (agent-scheme--resolve-import-set
            (cadr parts) context environment))))
       ((agent-scheme--symbol-named-p operator "rename")
        (unless (>= (length parts) 2)
          (agent-scheme--eval-error
           "rename import set requires an import set"))
        (let* ((bindings
                (agent-scheme--resolve-import-set
                 (cadr parts) context environment))
               (renames
                (mapcar
                 (lambda (rename-form)
                   (let ((rename-parts
                          (agent-scheme--proper-list-elements
                           rename-form "rename pair")))
                     (unless (= (length rename-parts) 2)
                       (agent-scheme--eval-error
                        "rename pair requires old and new identifiers"))
                     (cons
                      (agent-scheme--expect-symbol-name
                       (car rename-parts) "rename old identifier")
                      (agent-scheme--expect-symbol-name
                       (cadr rename-parts) "rename new identifier"))))
                 (cddr parts)))
               (old-names (mapcar #'car renames)))
          (agent-scheme--ensure-import-names-present
           old-names bindings "rename")
          (mapcar
           (lambda (binding)
             (let ((rename
                    (assoc (agent-scheme--library-binding-name binding)
                           renames)))
               (if rename
                   (agent-scheme--library-binding-with-name
                    binding (cdr rename))
                 binding)))
           bindings)))
       (t
        (agent-scheme--eval-error
         "invalid import set: %s"
         (agent-scheme-value->external import-set))))))
   (t
    (agent-scheme--eval-error
     "invalid import set: %s"
     (agent-scheme-value->external import-set)))))

(defun agent-scheme--install-imported-binding
    (binding value-environment syntax-environment)
  "Install one imported BINDING into VALUE-ENVIRONMENT or SYNTAX-ENVIRONMENT."
  (let ((name (agent-scheme--library-binding-name binding))
        (kind (agent-scheme--library-binding-kind binding))
        (object (agent-scheme--library-binding-object binding))
        (library-key (agent-scheme--library-binding-library-key binding)))
    (pcase kind
      ('value
       (let ((existing
              (agent-scheme--current-environment-cell
               value-environment name)))
         (cond
          ((null existing)
           (puthash name object
                    (agent-scheme--environment-bindings value-environment)))
          ((equal library-key agent-scheme--scheme-base-library-key)
           (puthash name object
                    (agent-scheme--environment-bindings value-environment)))
          ((eq existing object))
          (t
           (agent-scheme--eval-error
            "conflicting import for identifier: %s" name)))))
      ('syntax
       (let ((existing
              (agent-scheme--current-syntax-binding
               syntax-environment name)))
         (cond
          ((or (null existing)
               (equal library-key agent-scheme--scheme-base-library-key))
           (puthash name object
                    (agent-scheme--syntax-environment-bindings
                     syntax-environment)))
          ((eq existing object))
          (t
           (agent-scheme--eval-error
            "conflicting syntax import for identifier: %s" name)))))
      (_
       (agent-scheme--eval-error
        "unsupported library binding kind: %S" kind)))))

(defun agent-scheme--install-import-set
    (import-set value-environment syntax-environment context)
  "Resolve and install IMPORT-SET."
  (dolist (binding
           (agent-scheme--ensure-compatible-import-bindings
            (agent-scheme--resolve-import-set
             import-set context value-environment)))
    (agent-scheme--install-imported-binding
     binding value-environment syntax-environment)))

(defun agent-scheme--eval-import (form environment context)
  "Evaluate top-level or library import declaration FORM."
  (let ((parts (agent-scheme--proper-list-elements
                form "import declaration")))
    (unless (>= (length parts) 2)
      (agent-scheme--eval-error
       "import requires at least one import set"))
    (dolist (import-set (cdr parts))
      (agent-scheme--install-import-set
       import-set
       environment
       (agent-scheme--eval-context-syntax-environment context)
       context))
    agent-scheme-unspecified))

(defun agent-scheme--export-specs (forms)
  "Return export specs parsed from FORMS as (INTERNAL . EXTERNAL)."
  (let (specs)
    (dolist (form forms)
      (cond
       ((agent-scheme--identifier-datum-p form)
        (let ((name (agent-scheme--expect-symbol-name
                     form "export identifier")))
          (push (cons name name) specs)))
       ((agent-scheme--form-named-p form "rename")
        (let ((parts (agent-scheme--proper-list-elements
                      form "export rename")))
          (unless (= (length parts) 3)
            (agent-scheme--eval-error
             "export rename requires internal and external identifiers"))
          (push
           (cons
            (agent-scheme--expect-symbol-name
             (cadr parts) "export internal identifier")
            (agent-scheme--expect-symbol-name
             (caddr parts) "export external identifier"))
           specs)))
       (t
        (agent-scheme--eval-error
         "invalid export spec: %s"
         (agent-scheme-value->external form)))))
    (nreverse specs)))

(defun agent-scheme--feature-requirement-satisfied-p
    (requirement context environment)
  "Return non-nil when cond-expand REQUIREMENT is satisfied."
  (cond
   ((agent-scheme--identifier-datum-p requirement)
    (equal (agent-scheme--symbol-name requirement) "r7rs"))
   ((consp requirement)
    (let* ((parts (agent-scheme--proper-list-elements
                   requirement "feature requirement"))
           (operator (car parts)))
      (cond
       ((agent-scheme--symbol-named-p operator "library")
        (unless (= (length parts) 2)
          (agent-scheme--eval-error
           "library feature requirement requires one library name"))
        (agent-scheme--library-available-p (cadr parts) context environment))
       ((agent-scheme--symbol-named-p operator "and")
        (cl-every
         (lambda (nested)
           (agent-scheme--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((agent-scheme--symbol-named-p operator "or")
        (cl-some
         (lambda (nested)
           (agent-scheme--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((agent-scheme--symbol-named-p operator "not")
        (unless (= (length parts) 2)
          (agent-scheme--eval-error
           "not feature requirement requires one nested requirement"))
        (not
         (agent-scheme--feature-requirement-satisfied-p
          (cadr parts) context environment)))
       (t nil))))
   (t nil)))

(defun agent-scheme--expand-library-cond-expand
    (clauses context environment)
  "Return library declarations selected from cond-expand CLAUSES."
  (let ((selected nil)
        declarations)
    (dolist (clause clauses)
      (unless selected
        (let ((parts (agent-scheme--proper-list-elements
                      clause "cond-expand clause")))
          (when parts
            (let ((requirement (car parts)))
              (when (or (agent-scheme--symbol-named-p requirement "else")
                        (agent-scheme--feature-requirement-satisfied-p
                         requirement context environment))
                (setq selected t)
                (setq declarations (cdr parts))))))))
    (unless selected
      (agent-scheme--eval-error "unfulfilled library cond-expand"))
    declarations))

(defun agent-scheme--expand-library-declaration
    (declaration context environment)
  "Return DECLARATION after expanding library-level cond-expand."
  (cond
   ((agent-scheme--form-named-p declaration "cond-expand")
    (apply
     #'append
     (mapcar
      (lambda (nested)
        (agent-scheme--expand-library-declaration
         nested context environment))
      (agent-scheme--expand-library-cond-expand
       (cdr (agent-scheme--proper-list-elements
             declaration "library cond-expand"))
       context
       environment))))
   ((agent-scheme--form-named-p declaration "include-library-declarations")
    (agent-scheme--expand-include-library-declarations
     declaration context environment))
   (t
    (list declaration))))

(defun agent-scheme--include-filenames (declaration)
  "Return validated string filenames from include DECLARATION."
  (let* ((parts (agent-scheme--proper-list-elements
                 declaration "include declaration"))
         (operator-name (agent-scheme--symbol-name (car parts))))
    (unless (cdr parts)
      (agent-scheme--eval-error
       "%s requires at least one filename" operator-name))
    (mapcar
     (lambda (filename)
       (unless (stringp filename)
         (agent-scheme--eval-error
          "%s filename must be a string literal" operator-name))
       filename)
     (cdr parts))))

(defun agent-scheme--file-truename-or-expanded (path)
  "Return PATH's truename when possible, otherwise its expanded name."
  (if (file-exists-p path)
      (file-truename path)
    (expand-file-name path)))

(defun agent-scheme--path-policy-allows-file-p (path allowed-paths)
  "Return non-nil if ALLOWED-PATHS allow reading PATH."
  (let ((canonical-path
         (agent-scheme--file-truename-or-expanded path)))
    (cl-some
     (lambda (allowed)
       (let ((canonical-allowed
              (agent-scheme--file-truename-or-expanded allowed)))
         (or (equal canonical-path canonical-allowed)
             (and (file-directory-p canonical-allowed)
                  (file-in-directory-p canonical-path
                                       canonical-allowed)))))
     allowed-paths)))

(defun agent-scheme--include-policy-allows-file-p (path context)
  "Return non-nil if CONTEXT policy allows reading PATH."
  (agent-scheme--path-policy-allows-file-p
   path
   (agent-scheme--eval-context-include-paths context)))

(defun agent-scheme--resolve-include-file (filename context)
  "Return policy-checked absolute include path for FILENAME."
  (let ((path
         (expand-file-name
          filename
          (agent-scheme--eval-context-include-directory context))))
    (unless (agent-scheme--eval-context-include-paths context)
      (agent-scheme--eval-error
       "include requires policy-gated host file access: %s" filename))
    (unless (agent-scheme--include-policy-allows-file-p path context)
      (agent-scheme--eval-error
       "include file is not allowed by policy: %s" filename))
    (unless (file-readable-p path)
      (agent-scheme--eval-error
       "include file is not readable: %s" filename))
    path))

(defun agent-scheme--with-include-directory (context directory thunk)
  "Call THUNK while CONTEXT resolves relative includes from DIRECTORY."
  (let ((previous-directory
         (agent-scheme--eval-context-include-directory context)))
    (unwind-protect
        (progn
          (setf (agent-scheme--eval-context-include-directory context)
                (file-name-as-directory directory))
          (funcall thunk))
      (setf (agent-scheme--eval-context-include-directory context)
            previous-directory))))

(defun agent-scheme--read-include-file-forms (filename context fold-case)
  "Read FILENAME into forms after include policy checks.
When FOLD-CASE is non-nil, read as if the file began with
`#!fold-case'.  The return value is (FORMS . DIRECTORY)."
  (let* ((path (agent-scheme--resolve-include-file filename context))
         (source
          (with-temp-buffer
            (insert-file-contents path)
            (buffer-string)))
         (forms
          (agent-scheme-read-all
           (if fold-case
               (concat "#!fold-case\n" source)
             source))))
    (cons forms (file-name-directory path))))

(defun agent-scheme--library-include-body-forms
    (declaration context fold-case)
  "Return body forms read by include DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (car (agent-scheme--read-include-file-forms
            filename context fold-case)))
    (agent-scheme--include-filenames declaration))))

(defun agent-scheme--expand-include-library-declarations
    (declaration context environment)
  "Return declarations spliced from include-library-declarations DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (let* ((read-result
              (agent-scheme--read-include-file-forms
               filename context nil))
             (forms (car read-result))
             (directory (cdr read-result)))
        (agent-scheme--with-include-directory
         context
         directory
         (lambda ()
           (apply
            #'append
            (mapcar
             (lambda (nested)
               (agent-scheme--expand-library-declaration
                nested context environment))
             forms))))))
    (agent-scheme--include-filenames declaration))))

(defun agent-scheme--library-export-binding
    (spec library-key value-environment syntax-environment)
  "Return the library binding described by export SPEC."
  (let* ((internal-name (car spec))
         (external-name (cdr spec))
         (cell
          (agent-scheme--environment-cell value-environment internal-name))
         (syntax-binding
          (agent-scheme--syntax-environment-ref
           syntax-environment internal-name)))
    (cond
     ((and cell syntax-binding)
      (agent-scheme--eval-error
       "export identifier has both value and syntax bindings: %s"
       internal-name))
     (cell
      (agent-scheme--make-library-binding
       external-name 'value cell library-key))
     (syntax-binding
      (agent-scheme--make-library-binding
       external-name 'syntax syntax-binding library-key))
     (t
      (agent-scheme--eval-error
       "exported identifier is not bound: %s" internal-name)))))

(defun agent-scheme--library-exports-from-specs
    (specs library-key value-environment syntax-environment)
  "Return export bindings for SPECS from library environments."
  (agent-scheme--ensure-compatible-import-bindings
   (mapcar
    (lambda (spec)
      (agent-scheme--library-export-binding
       spec library-key value-environment syntax-environment))
    specs)))

(defun agent-scheme--eval-library-begin
    (forms value-environment syntax-environment context)
  "Evaluate library body FORMS in explicit library environments."
  (agent-scheme--with-syntax-environment
   context
   syntax-environment
   (lambda ()
     (agent-scheme--trampoline
      (agent-scheme--make-sequence forms t)
      value-environment
      context))))

(defun agent-scheme--eval-define-library (form environment context)
  "Evaluate a top-level R7RS define-library FORM."
  (let* ((parts (agent-scheme--proper-list-elements
                 form "define-library form"))
         (name (cadr parts)))
    (unless (>= (length parts) 2)
      (agent-scheme--eval-error
       "define-library requires a library name"))
    (unless (agent-scheme--library-name-p name)
      (agent-scheme--eval-error
       "invalid library name: %s" (agent-scheme-value->external name)))
    (let* ((library-key (agent-scheme--library-name-key name))
           (value-environment (agent-scheme-make-empty-environment))
           (syntax-environment
            (agent-scheme--make-empty-syntax-environment))
           export-specs)
      (dolist (raw-declaration (cddr parts))
        (dolist (declaration
                 (agent-scheme--expand-library-declaration
                  raw-declaration context environment))
          (let* ((declaration-parts
                  (agent-scheme--proper-list-elements
                   declaration "library declaration"))
                 (operator (car declaration-parts)))
            (cond
             ((agent-scheme--symbol-named-p operator "export")
              (setq export-specs
                    (append export-specs
                            (agent-scheme--export-specs
                             (cdr declaration-parts)))))
             ((agent-scheme--symbol-named-p operator "import")
              (agent-scheme--with-syntax-environment
               context
               syntax-environment
               (lambda ()
                 (agent-scheme--eval-import
                  declaration value-environment context))))
             ((agent-scheme--symbol-named-p operator "begin")
              (agent-scheme--eval-library-begin
               (cdr declaration-parts)
               value-environment
               syntax-environment
               context))
             ((agent-scheme--symbol-named-p operator "include")
              (agent-scheme--eval-library-begin
               (agent-scheme--library-include-body-forms
                declaration context nil)
               value-environment
               syntax-environment
               context))
             ((agent-scheme--symbol-named-p operator "include-ci")
              (agent-scheme--eval-library-begin
               (agent-scheme--library-include-body-forms
                declaration context t)
               value-environment
               syntax-environment
               context))
             ((agent-scheme--symbol-named-p
               operator "include-library-declarations")
              (agent-scheme--eval-error
               "include-library-declarations must expand before evaluation"))
             (t
              (agent-scheme--eval-error
               "unsupported library declaration: %s"
               (agent-scheme-value->external declaration)))))))
      (puthash
       library-key
       (agent-scheme--make-library
        name
        library-key
        (agent-scheme--library-exports-from-specs
         export-specs library-key value-environment syntax-environment)
        value-environment
        syntax-environment)
       (agent-scheme--eval-context-libraries context))
      agent-scheme-unspecified)))

(defun agent-scheme--expand-expression (expression environment context)
  "Return one macro expansion step for EXPRESSION."
  (if (not (consp expression))
      expression
    (let* ((parts (agent-scheme--proper-list-elements
                   expression "expression"))
           (operator (car parts)))
      (cond
       ((and (agent-scheme--symbol-named-p operator "syntax-error")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--raise-syntax-error expression))
       ((and (agent-scheme--symbol-named-p operator "let-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--make-local-syntax-scope
         parts environment context nil))
       ((and (agent-scheme--symbol-named-p operator "letrec-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--make-local-syntax-scope
         parts environment context t))
       ((agent-scheme--syntax-binding-for-operator
         operator environment context)
        (agent-scheme--apply-syntax-transformer
         (agent-scheme--syntax-binding-for-operator
          operator environment context)
         expression
         environment
         context))
       (t expression)))))

(defun agent-scheme--eval-combination (expression environment context tailp)
  "Evaluate list EXPRESSION in ENVIRONMENT."
  (let ((parts (agent-scheme--proper-list-elements expression "expression")))
    (unless parts
      (agent-scheme--eval-error "empty list is not an expression"))
    (let ((operator (car parts)))
      (cond
       ((and (agent-scheme--symbol-named-p operator "quote")
             (agent-scheme--special-operator-active-p operator environment))
        (unless (= (length parts) 2)
          (agent-scheme--eval-error "quote requires exactly one datum"))
        (agent-scheme--check-value-budget (cadr parts) context))
       ((and (agent-scheme--symbol-named-p operator "quasiquote")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--check-value-budget
         (agent-scheme--eval-quasiquote parts environment context)
         context))
       ((and (agent-scheme--symbol-named-p operator "lambda")
             (agent-scheme--special-operator-active-p operator environment))
        (unless (>= (length parts) 3)
          (agent-scheme--eval-error "lambda requires formals and a body"))
        (agent-scheme--make-procedure
         (agent-scheme--parse-formals (cadr parts))
         (cddr parts)
         environment))
       ((and (agent-scheme--symbol-named-p operator "if")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-if parts environment context tailp))
       ((and (agent-scheme--symbol-named-p operator "set!")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-set! parts environment context))
       ((and (agent-scheme--symbol-named-p operator "letrec")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-letrec parts environment context tailp nil))
       ((and (agent-scheme--symbol-named-p operator "letrec*")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-letrec parts environment context tailp t))
       ((and (agent-scheme--symbol-named-p operator "define")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error "define is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "define-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "define-syntax is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "define-library")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "define-library is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "import")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "import is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "begin")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-sequence (cdr parts) environment context tailp nil))
       (t
        (let ((procedure
               (agent-scheme--eval-expression operator environment context nil))
              (arguments
               (mapcar
                (lambda (operand)
                  (agent-scheme--eval-expression operand environment context nil))
                (cdr parts))))
          (agent-scheme--apply-procedure procedure arguments context tailp)))))))

(defun agent-scheme--eval-expression (expression environment context tailp)
  "Evaluate EXPRESSION in ENVIRONMENT under CONTEXT.
When TAILP is non-nil, tail calls may return an
`agent-scheme--bounce'."
  (agent-scheme--note-step context)
  (cond
   ((agent-scheme--sequence-p expression)
    (agent-scheme--eval-sequence
     (agent-scheme--sequence-forms expression)
     environment
     context
     tailp
     (agent-scheme--sequence-allow-definitions expression)))
   ((agent-scheme--syntax-scope-p expression)
    (agent-scheme--with-syntax-environment
     context
     (agent-scheme--syntax-scope-syntax-environment expression)
     (lambda ()
       (agent-scheme--eval-sequence
        (agent-scheme--syntax-scope-forms expression)
        environment
        context
        tailp
        t))))
   ((agent-scheme--self-evaluating-p expression)
    (agent-scheme--check-value-budget expression context))
   ((agent-scheme--identifier-p expression)
    (agent-scheme--environment-ref-identifier environment expression))
   ((agent-scheme-symbol-p expression)
    (agent-scheme--environment-ref-identifier environment expression))
   ((null expression)
    (agent-scheme--eval-error "empty list is not an expression"))
   ((consp expression)
    (let ((expanded (agent-scheme--expand-expression
                     expression environment context)))
      (if (eq expanded expression)
          (agent-scheme--eval-combination expression environment context tailp)
        (agent-scheme--eval-expression expanded environment context tailp))))
   (t
    (agent-scheme--eval-error "unsupported expression datum: %S" expression))))

(defun agent-scheme--eval-sequence
    (forms environment context tailp allow-definitions)
  "Evaluate FORMS sequentially in ENVIRONMENT.
TAILP controls the final form.  ALLOW-DEFINITIONS permits
top-level definition forms within the sequence."
  (cond
   ((null forms)
    agent-scheme-unspecified)
   (t
    (let ((cursor forms)
          value)
      (while (cdr cursor)
        (let ((form (car cursor)))
          (cond
           ((agent-scheme--import-form-p form)
            (if allow-definitions
                (setq value
                      (agent-scheme--eval-import
                       form environment context))
              (agent-scheme--eval-error
               "import is only allowed at top level or in library bodies")))
           ((agent-scheme--define-library-form-p form)
            (if allow-definitions
                (setq value
                      (agent-scheme--eval-define-library
                       form environment context))
              (agent-scheme--eval-error
               "define-library is only allowed at top level")))
           ((agent-scheme--syntax-definition-form-p form)
            (if allow-definitions
                (setq value
                      (agent-scheme--eval-define-syntax
                       form
                       environment
                       context
                       (agent-scheme--eval-context-syntax-environment
                        context)))
              (agent-scheme--eval-error
               "define-syntax is only allowed before body expressions")))
           ((agent-scheme--definition-form-p form)
            (if allow-definitions
                (setq value
                      (agent-scheme--eval-definition
                       form environment context))
              (agent-scheme--eval-error
               "define is only allowed before body expressions")))
           ((and allow-definitions (agent-scheme--begin-form-p form))
            (setq value
                  (agent-scheme--eval-sequence
                   (cdr (agent-scheme--proper-list-elements form "begin form"))
                   environment context nil t)))
           (t
            (setq value
                  (agent-scheme--eval-expression
                   form environment context nil)))))
        (setq cursor (cdr cursor)))
      (let ((last-form (car cursor)))
        (cond
         ((agent-scheme--import-form-p last-form)
          (if allow-definitions
              (agent-scheme--eval-import last-form environment context)
            (agent-scheme--eval-error
             "import is only allowed at top level or in library bodies")))
         ((agent-scheme--define-library-form-p last-form)
          (if allow-definitions
              (agent-scheme--eval-define-library
               last-form environment context)
            (agent-scheme--eval-error
             "define-library is only allowed at top level")))
         ((agent-scheme--syntax-definition-form-p last-form)
          (if allow-definitions
              (agent-scheme--eval-define-syntax
               last-form
               environment
               context
               (agent-scheme--eval-context-syntax-environment context))
            (agent-scheme--eval-error
             "define-syntax is only allowed before body expressions")))
         ((agent-scheme--definition-form-p last-form)
          (if allow-definitions
              (agent-scheme--eval-definition last-form environment context)
            (agent-scheme--eval-error
             "define is only allowed before body expressions")))
         ((and allow-definitions (agent-scheme--begin-form-p last-form))
          (agent-scheme--eval-sequence
           (cdr (agent-scheme--proper-list-elements last-form "begin form"))
           environment context tailp t))
         (tailp
          (agent-scheme--make-bounce
           last-form
           environment
           (agent-scheme--eval-context-syntax-environment context)))
         (t
          (setq value
                (agent-scheme--eval-expression
                 last-form environment context nil)))))))))

(defun agent-scheme--trampoline (expression environment context)
  "Evaluate EXPRESSION in ENVIRONMENT using CONTEXT's trampoline."
  (let ((state
         (agent-scheme--make-bounce
          expression
          environment
          (agent-scheme--eval-context-syntax-environment context))))
    (while (agent-scheme--bounce-p state)
      (let ((syntax-environment
             (or (agent-scheme--bounce-syntax-environment state)
                 (agent-scheme--eval-context-syntax-environment context))))
        (setq state
              (agent-scheme--with-syntax-environment
               context
               syntax-environment
               (lambda ()
                 (agent-scheme--eval-expression
                  (agent-scheme--bounce-expression state)
                  (agent-scheme--bounce-environment state)
                  context
                  t))))))
    (agent-scheme--check-value-budget state context)))

(defun agent-scheme--number->host (datum)
  "Return DATUM as a host number or signal a Scheme error."
  (unless (agent-scheme-number-p datum)
    (agent-scheme--eval-error
     "expected number, got %s" (agent-scheme-value->external datum)))
  (pcase (agent-scheme-number-kind datum)
    ('integer (agent-scheme-number-value datum))
    ('decimal (agent-scheme-number-value datum))
    (_
     (agent-scheme--eval-error
      "unsupported numeric kind in evaluator kernel: %s"
      (agent-scheme-number-lexeme datum)))))

(defun agent-scheme--number-from-host (number)
  "Return an Agent Scheme number datum for host NUMBER."
  (cond
   ((integerp number)
    (agent-scheme--make-number
     (number-to-string number) 'exact 10 'integer number))
   ((floatp number)
    (agent-scheme--make-number
     (number-to-string number) 'inexact 10 'decimal number))
   (t
    (agent-scheme--eval-error "unsupported host number result: %S" number))))

(defun agent-scheme--scheme-boolean (value)
  "Return the canonical Scheme boolean for host truth VALUE."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme--number-exact-p (datum)
  "Return non-nil if DATUM is an exact number in the current numeric slice."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-exactness datum) 'exact)))

(defun agent-scheme--number-inexact-p (datum)
  "Return non-nil if DATUM is an inexact number."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-exactness datum) 'inexact)))

(defun agent-scheme--number-integer-p (datum)
  "Return non-nil if DATUM is integer-valued in the current numeric slice."
  (and (agent-scheme-number-p datum)
       (pcase (agent-scheme-number-kind datum)
         ('integer t)
         ('decimal
          (let ((value (agent-scheme-number-value datum)))
            (and (floatp value) (= value (ftruncate value)))))
         (_ nil))))

(defun agent-scheme--exact-integer->host (datum description)
  "Return DATUM's exact integer value or signal an error naming DESCRIPTION."
  (unless (and (agent-scheme-number-p datum)
               (eq (agent-scheme-number-kind datum) 'integer)
               (eq (agent-scheme-number-exactness datum) 'exact))
    (agent-scheme--eval-error
     "%s must be an exact integer, got %s"
     description
     (agent-scheme-value->external datum)))
  (agent-scheme-number-value datum))

(defun agent-scheme--expect-nonnegative-index
    (datum limit description &optional allow-end)
  "Return DATUM as a host index below LIMIT.
When ALLOW-END is non-nil, LIMIT itself is accepted."
  (let ((index (agent-scheme--exact-integer->host datum description)))
    (unless (and (<= 0 index)
                 (if allow-end (<= index limit) (< index limit)))
      (agent-scheme--eval-error
       "%s index out of range: %d" description index))
    index))

(defun agent-scheme--expect-byte (datum description)
  "Return DATUM as a byte or signal an error naming DESCRIPTION."
  (let ((byte (agent-scheme--exact-integer->host datum description)))
    (unless (<= 0 byte 255)
      (agent-scheme--eval-error "%s must be in byte range: %d" description byte))
    byte))

(defun agent-scheme--expect-string (datum description)
  "Return DATUM as a string or signal an error naming DESCRIPTION."
  (unless (stringp datum)
    (agent-scheme--eval-error
     "%s must be a string, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--expect-character (datum description)
  "Return DATUM's character code or signal an error naming DESCRIPTION."
  (unless (agent-scheme-character-p datum)
    (agent-scheme--eval-error
     "%s must be a character, got %s"
     description
     (agent-scheme-value->external datum)))
  (agent-scheme-character-code datum))

(defun agent-scheme--valid-scalar-value-p (code)
  "Return non-nil if CODE is a Unicode scalar value."
  (and (integerp code)
       (<= 0 code #x10ffff)
       (not (<= #xd800 code #xdfff))))

(defun agent-scheme--expect-vector (datum description)
  "Return DATUM as a vector or signal an error naming DESCRIPTION."
  (unless (vectorp datum)
    (agent-scheme--eval-error
     "%s must be a vector, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--expect-bytevector (datum description)
  "Return DATUM as a bytevector or signal an error naming DESCRIPTION."
  (unless (agent-scheme-bytevector-p datum)
    (agent-scheme--eval-error
     "%s must be a bytevector, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--expect-procedure (datum description)
  "Return DATUM as a procedure or signal an error naming DESCRIPTION."
  (unless (or (agent-scheme-procedure-p datum)
              (agent-scheme-primitive-procedure-p datum))
    (agent-scheme--eval-error
     "%s must be a procedure, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--optional-range (arguments offset length description)
  "Return (START . END) parsed from optional range ARGUMENTS.
OFFSET is the index in ARGUMENTS where START would appear.  LENGTH is
the maximum endpoint for DESCRIPTION."
  (let ((optional-count (- (length arguments) offset)))
    (unless (<= 0 optional-count 2)
      (agent-scheme--eval-error
       "%s expected at most start and end arguments" description))
    (let ((start (if (>= optional-count 1)
                     (agent-scheme--expect-nonnegative-index
                      (nth offset arguments) length description t)
                   0))
          (end (if (>= optional-count 2)
                   (agent-scheme--expect-nonnegative-index
                    (nth (1+ offset) arguments) length description t)
                 length)))
      (when (> start end)
        (agent-scheme--eval-error
         "%s start index exceeds end index" description))
      (cons start end))))

(defun agent-scheme--primitive-numbers (arguments)
  "Return ARGUMENTS converted to host numbers."
  (mapcar #'agent-scheme--number->host arguments))

(defun agent-scheme--primitive+ (arguments _context)
  "Primitive + over ARGUMENTS."
  (agent-scheme--number-from-host
   (apply #'+ (agent-scheme--primitive-numbers arguments))))

(defun agent-scheme--primitive* (arguments _context)
  "Primitive * over ARGUMENTS."
  (agent-scheme--number-from-host
   (apply #'* (agent-scheme--primitive-numbers arguments))))

(defun agent-scheme--scheme-divide (left right)
  "Return LEFT divided by RIGHT using the current numeric slice."
  (when (zerop right)
    (agent-scheme--eval-error "division by zero"))
  (if (and (integerp left)
           (integerp right)
           (zerop (% left right)))
      (/ left right)
    (/ (float left) right)))

(defun agent-scheme--primitive- (arguments _context)
  "Primitive - over ARGUMENTS."
  (let ((numbers (agent-scheme--primitive-numbers arguments)))
    (agent-scheme--number-from-host
     (if (= (length numbers) 1)
         (- (car numbers))
       (apply #'- numbers)))))

(defun agent-scheme--primitive/ (arguments _context)
  "Primitive / over ARGUMENTS."
  (let ((numbers (agent-scheme--primitive-numbers arguments)))
    (agent-scheme--number-from-host
     (if (= (length numbers) 1)
         (agent-scheme--scheme-divide 1 (car numbers))
       (let ((result (car numbers)))
         (dolist (number (cdr numbers))
           (setq result (agent-scheme--scheme-divide result number)))
         result)))))

(defun agent-scheme--primitive-compare (arguments predicate)
  "Return Scheme boolean for pairwise PREDICATE over ARGUMENTS."
  (let ((numbers (agent-scheme--primitive-numbers arguments))
        (ok t))
    (while (and ok (cdr numbers))
      (setq ok (funcall predicate (car numbers) (cadr numbers)))
      (setq numbers (cdr numbers)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive= (arguments _context)
  "Primitive numeric = over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'=))

(defun agent-scheme--primitive< (arguments _context)
  "Primitive numeric < over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'<))

(defun agent-scheme--primitive> (arguments _context)
  "Primitive numeric > over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'>))

(defun agent-scheme--primitive<= (arguments _context)
  "Primitive numeric <= over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'<=))

(defun agent-scheme--primitive>= (arguments _context)
  "Primitive numeric >= over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'>=))

(defun agent-scheme--primitive-abs (arguments _context)
  "Primitive abs over ARGUMENTS."
  (agent-scheme--number-from-host
   (abs (agent-scheme--number->host (car arguments)))))

(defun agent-scheme--primitive-min (arguments _context)
  "Primitive min over ARGUMENTS."
  (agent-scheme--number-from-host
   (apply #'min (agent-scheme--primitive-numbers arguments))))

(defun agent-scheme--primitive-max (arguments _context)
  "Primitive max over ARGUMENTS."
  (agent-scheme--number-from-host
   (apply #'max (agent-scheme--primitive-numbers arguments))))

(defun agent-scheme--primitive-square (arguments _context)
  "Primitive square over ARGUMENTS."
  (let ((number (agent-scheme--number->host (car arguments))))
    (agent-scheme--number-from-host (* number number))))

(defun agent-scheme--primitive-zero? (arguments _context)
  "Primitive zero? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (zerop (agent-scheme--number->host (car arguments)))))

(defun agent-scheme--primitive-positive? (arguments _context)
  "Primitive positive? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (> (agent-scheme--number->host (car arguments)) 0)))

(defun agent-scheme--primitive-negative? (arguments _context)
  "Primitive negative? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (< (agent-scheme--number->host (car arguments)) 0)))

(defun agent-scheme--primitive-odd? (arguments _context)
  "Primitive odd? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (cl-oddp (agent-scheme--exact-integer->host (car arguments) "odd?"))))

(defun agent-scheme--primitive-even? (arguments _context)
  "Primitive even? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (cl-evenp (agent-scheme--exact-integer->host (car arguments) "even?"))))

(defun agent-scheme--primitive-integer-quotient
    (arguments quotient-function description)
  "Return integer quotient over ARGUMENTS using QUOTIENT-FUNCTION."
  (let ((left (agent-scheme--exact-integer->host
               (car arguments) description))
        (right (agent-scheme--exact-integer->host
                (cadr arguments) description)))
    (when (zerop right)
      (agent-scheme--eval-error "%s division by zero" description))
    (agent-scheme--number-from-host
     (funcall quotient-function left right))))

(defun agent-scheme--primitive-quotient (arguments _context)
  "Primitive quotient over ARGUMENTS."
  (agent-scheme--primitive-integer-quotient
   arguments #'truncate "quotient"))

(defun agent-scheme--primitive-floor-quotient (arguments _context)
  "Primitive floor-quotient over ARGUMENTS."
  (agent-scheme--primitive-integer-quotient
   arguments #'floor "floor-quotient"))

(defun agent-scheme--primitive-truncate-quotient (arguments _context)
  "Primitive truncate-quotient over ARGUMENTS."
  (agent-scheme--primitive-integer-quotient
   arguments #'truncate "truncate-quotient"))

(defun agent-scheme--modulo-value (left right)
  "Return Scheme modulo for host integers LEFT and RIGHT."
  (let ((remainder (% left right)))
    (if (or (zerop remainder)
            (= (cl-signum remainder) (cl-signum right)))
        remainder
      (+ remainder right))))

(defun agent-scheme--primitive-remainder (arguments _context)
  "Primitive remainder over ARGUMENTS."
  (let ((left (agent-scheme--exact-integer->host
               (car arguments) "remainder"))
        (right (agent-scheme--exact-integer->host
                (cadr arguments) "remainder")))
    (when (zerop right)
      (agent-scheme--eval-error "remainder division by zero"))
    (agent-scheme--number-from-host (% left right))))

(defun agent-scheme--primitive-modulo (arguments _context)
  "Primitive modulo over ARGUMENTS."
  (let ((left (agent-scheme--exact-integer->host (car arguments) "modulo"))
        (right (agent-scheme--exact-integer->host (cadr arguments) "modulo")))
    (when (zerop right)
      (agent-scheme--eval-error "modulo division by zero"))
    (agent-scheme--number-from-host
     (agent-scheme--modulo-value left right))))

(defun agent-scheme--primitive-floor-remainder (arguments context)
  "Primitive floor-remainder over ARGUMENTS."
  (agent-scheme--primitive-modulo arguments context))

(defun agent-scheme--primitive-truncate-remainder (arguments context)
  "Primitive truncate-remainder over ARGUMENTS."
  (agent-scheme--primitive-remainder arguments context))

(defun agent-scheme--primitive-rounding (arguments function)
  "Apply unary numeric FUNCTION to ARGUMENTS."
  (agent-scheme--number-from-host
   (funcall function (agent-scheme--number->host (car arguments)))))

(defun agent-scheme--primitive-floor (arguments _context)
  "Primitive floor over ARGUMENTS."
  (agent-scheme--primitive-rounding arguments #'floor))

(defun agent-scheme--primitive-ceiling (arguments _context)
  "Primitive ceiling over ARGUMENTS."
  (agent-scheme--primitive-rounding arguments #'ceiling))

(defun agent-scheme--primitive-truncate (arguments _context)
  "Primitive truncate over ARGUMENTS."
  (agent-scheme--primitive-rounding arguments #'truncate))

(defun agent-scheme--primitive-round (arguments _context)
  "Primitive round over ARGUMENTS."
  (agent-scheme--primitive-rounding arguments #'round))

(defun agent-scheme--primitive-cons (arguments _context)
  "Primitive cons over ARGUMENTS."
  (cons (car arguments) (cadr arguments)))

(defun agent-scheme--primitive-car (arguments _context)
  "Primitive car over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "car expected pair, got %s" (agent-scheme-value->external pair)))
    (car pair)))

(defun agent-scheme--primitive-cdr (arguments _context)
  "Primitive cdr over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "cdr expected pair, got %s" (agent-scheme-value->external pair)))
    (cdr pair)))

(defun agent-scheme--primitive-list (arguments _context)
  "Primitive list over ARGUMENTS."
  (copy-sequence arguments))

(defun agent-scheme--primitive-null? (arguments _context)
  "Primitive null? over ARGUMENTS."
  (if (null (car arguments)) agent-scheme-true agent-scheme-false))

(defun agent-scheme--primitive-pair? (arguments _context)
  "Primitive pair? over ARGUMENTS."
  (if (consp (car arguments)) agent-scheme-true agent-scheme-false))

(defun agent-scheme--primitive-not (arguments _context)
  "Primitive not over ARGUMENTS."
  (if (eq (car arguments) agent-scheme-false)
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-boolean? (arguments _context)
  "Primitive boolean? over ARGUMENTS."
  (if (or (eq (car arguments) agent-scheme-true)
          (eq (car arguments) agent-scheme-false))
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-number? (arguments _context)
  "Primitive number? over ARGUMENTS."
  (if (agent-scheme-number-p (car arguments))
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-symbol? (arguments _context)
  "Primitive symbol? over ARGUMENTS."
  (if (agent-scheme-symbol-p (car arguments))
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-procedure? (arguments _context)
  "Primitive procedure? over ARGUMENTS."
  (let ((value (car arguments)))
    (if (or (agent-scheme-procedure-p value)
            (agent-scheme-primitive-procedure-p value))
        agent-scheme-true
      agent-scheme-false)))

(defun agent-scheme--proper-list-p (value)
  "Return non-nil when VALUE is a proper finite list."
  (let ((seen (make-hash-table :test #'eq))
        (cursor value)
        proper)
    (catch 'done
      (while t
        (cond
         ((null cursor)
          (setq proper t)
          (throw 'done nil))
         ((not (consp cursor))
          (setq proper nil)
          (throw 'done nil))
         ((gethash cursor seen)
          (setq proper nil)
          (throw 'done nil))
         (t
          (puthash cursor t seen)
          (setq cursor (cdr cursor))))))
    proper))

(defun agent-scheme--primitive-list? (arguments _context)
  "Primitive list? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--proper-list-p (car arguments))))

(defun agent-scheme--primitive-length (arguments _context)
  "Primitive length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length (agent-scheme--proper-list-elements (car arguments) "length"))))

(defun agent-scheme--primitive-append (arguments _context)
  "Primitive append over ARGUMENTS."
  (cond
   ((null arguments) nil)
   ((null (cdr arguments)) (car arguments))
   (t
    (let ((prefixes nil)
          (last-tail (car (last arguments))))
      (dolist (list (butlast arguments))
        (push (agent-scheme--proper-list-elements list "append argument")
              prefixes))
      (apply #'append (append (nreverse prefixes) (list last-tail)))))))

(defun agent-scheme--primitive-reverse (arguments _context)
  "Primitive reverse over ARGUMENTS."
  (reverse (agent-scheme--proper-list-elements (car arguments) "reverse")))

(defun agent-scheme--primitive-list-tail (arguments _context)
  "Primitive list-tail over ARGUMENTS."
  (let ((cursor (car arguments))
        (index (agent-scheme--exact-integer->host
                (cadr arguments) "list-tail")))
    (when (< index 0)
      (agent-scheme--eval-error "list-tail index must be non-negative"))
    (dotimes (_ index)
      (unless (consp cursor)
        (agent-scheme--eval-error "list-tail index exceeds list length"))
      (setq cursor (cdr cursor)))
    cursor))

(defun agent-scheme--primitive-list-ref (arguments _context)
  "Primitive list-ref over ARGUMENTS."
  (let ((tail (agent-scheme--primitive-list-tail arguments nil)))
    (unless (consp tail)
      (agent-scheme--eval-error "list-ref index exceeds list length"))
    (car tail)))

(defun agent-scheme--primitive-list-set! (arguments _context)
  "Primitive list-set! over ARGUMENTS."
  (let ((tail (agent-scheme--primitive-list-tail arguments nil)))
    (unless (consp tail)
      (agent-scheme--eval-error "list-set! index exceeds list length"))
    (setcar tail (caddr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-set-car! (arguments _context)
  "Primitive set-car! over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "set-car! expected pair, got %s"
       (agent-scheme-value->external pair)))
    (setcar pair (cadr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-set-cdr! (arguments _context)
  "Primitive set-cdr! over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "set-cdr! expected pair, got %s"
       (agent-scheme-value->external pair)))
    (setcdr pair (cadr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-make-list (arguments _context)
  "Primitive make-list over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-list"))
         (fill (if (cdr arguments) (cadr arguments) agent-scheme-unspecified)))
    (when (< length 0)
      (agent-scheme--eval-error "make-list length must be non-negative"))
    (make-list length fill)))

(defun agent-scheme--primitive-list-copy (arguments _context)
  "Primitive list-copy over ARGUMENTS."
  (let ((value (car arguments)))
    (if (agent-scheme--proper-list-p value)
        (copy-sequence value)
      value)))

(defun agent-scheme--eqv-p (left right)
  "Return non-nil if LEFT and RIGHT are eqv? under the current value model."
  (cond
   ((eq left right) t)
   ((and (agent-scheme-number-p left) (agent-scheme-number-p right))
    (and (eq (agent-scheme-number-kind left)
             (agent-scheme-number-kind right))
         (eq (agent-scheme-number-exactness left)
             (agent-scheme-number-exactness right))
         (equal (agent-scheme-number-value left)
                (agent-scheme-number-value right))))
   ((and (agent-scheme-character-p left) (agent-scheme-character-p right))
    (= (agent-scheme-character-code left)
       (agent-scheme-character-code right)))
   ((and (agent-scheme-symbol-p left) (agent-scheme-symbol-p right))
    (equal (agent-scheme-symbol-name left)
           (agent-scheme-symbol-name right)))
   (t nil)))

(defun agent-scheme--eq-p (left right)
  "Return non-nil if LEFT and RIGHT are eq? under the current value model."
  (or (eq left right)
      (and (or (agent-scheme-number-p left)
               (agent-scheme-character-p left)
               (agent-scheme-symbol-p left))
           (agent-scheme--eqv-p left right))))

(defun agent-scheme--equal-p (left right seen)
  "Return non-nil if LEFT and RIGHT are equal?.
SEEN tracks compound pairs already compared."
  (cond
   ((agent-scheme--eqv-p left right) t)
   ((and (stringp left) (stringp right))
    (equal left right))
   ((and (agent-scheme-bytevector-p left)
         (agent-scheme-bytevector-p right))
    (equal (agent-scheme-bytevector-bytes left)
           (agent-scheme-bytevector-bytes right)))
   ((and (consp left) (consp right))
    (let ((key (cons left right)))
      (or (gethash key seen)
          (progn
            (puthash key t seen)
            (and (agent-scheme--equal-p (car left) (car right) seen)
                 (agent-scheme--equal-p (cdr left) (cdr right) seen))))))
   ((and (vectorp left) (vectorp right)
         (= (length left) (length right)))
    (let ((index 0)
          (ok t))
      (while (and ok (< index (length left)))
        (setq ok (agent-scheme--equal-p
                  (aref left index) (aref right index) seen))
        (cl-incf index))
      ok))
   (t nil)))

(defun agent-scheme--primitive-eq? (arguments _context)
  "Primitive eq? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--eq-p (car arguments) (cadr arguments))))

(defun agent-scheme--primitive-eqv? (arguments _context)
  "Primitive eqv? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--eqv-p (car arguments) (cadr arguments))))

(defun agent-scheme--primitive-equal? (arguments _context)
  "Primitive equal? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--equal-p
    (car arguments) (cadr arguments) (make-hash-table :test #'equal))))

(defun agent-scheme--list-member (object list predicate description)
  "Return member sublist for OBJECT in LIST using PREDICATE.
DESCRIPTION names the primitive for errors."
  (let ((cursor list)
        found)
    (while (and (consp cursor) (not found))
      (if (funcall predicate object (car cursor))
          (setq found cursor)
        (setq cursor (cdr cursor))))
    (cond
     (found found)
     ((null cursor) agent-scheme-false)
     (t
      (agent-scheme--eval-error "%s expected a proper list" description)))))

(defun agent-scheme--primitive-memq (arguments _context)
  "Primitive memq over ARGUMENTS."
  (agent-scheme--list-member
   (car arguments) (cadr arguments) #'agent-scheme--eq-p "memq"))

(defun agent-scheme--primitive-memv (arguments _context)
  "Primitive memv over ARGUMENTS."
  (agent-scheme--list-member
   (car arguments) (cadr arguments) #'agent-scheme--eqv-p "memv"))

(defun agent-scheme--primitive-member (arguments _context)
  "Primitive member over ARGUMENTS."
  (agent-scheme--list-member
   (car arguments)
   (cadr arguments)
   (lambda (left right)
     (agent-scheme--equal-p left right (make-hash-table :test #'equal)))
   "member"))

(defun agent-scheme--alist-assoc (object alist predicate description)
  "Return association for OBJECT in ALIST using PREDICATE."
  (let ((cursor alist)
        found)
    (while (and (consp cursor) (not found))
      (let ((entry (car cursor)))
        (unless (consp entry)
          (agent-scheme--eval-error "%s expected pair entries" description))
        (if (funcall predicate object (car entry))
            (setq found entry)
          (setq cursor (cdr cursor)))))
    (cond
     (found found)
     ((null cursor) agent-scheme-false)
     (t
      (agent-scheme--eval-error "%s expected a proper alist" description)))))

(defun agent-scheme--primitive-assq (arguments _context)
  "Primitive assq over ARGUMENTS."
  (agent-scheme--alist-assoc
   (car arguments) (cadr arguments) #'agent-scheme--eq-p "assq"))

(defun agent-scheme--primitive-assv (arguments _context)
  "Primitive assv over ARGUMENTS."
  (agent-scheme--alist-assoc
   (car arguments) (cadr arguments) #'agent-scheme--eqv-p "assv"))

(defun agent-scheme--primitive-assoc (arguments _context)
  "Primitive assoc over ARGUMENTS."
  (agent-scheme--alist-assoc
   (car arguments)
   (cadr arguments)
   (lambda (left right)
     (agent-scheme--equal-p left right (make-hash-table :test #'equal)))
   "assoc"))

(defun agent-scheme--primitive-caar (arguments _context)
  "Primitive caar over ARGUMENTS."
  (agent-scheme--primitive-car
   (list (agent-scheme--primitive-car arguments nil)) nil))

(defun agent-scheme--primitive-cadr (arguments _context)
  "Primitive cadr over ARGUMENTS."
  (agent-scheme--primitive-car
   (list (agent-scheme--primitive-cdr arguments nil)) nil))

(defun agent-scheme--primitive-cdar (arguments _context)
  "Primitive cdar over ARGUMENTS."
  (agent-scheme--primitive-cdr
   (list (agent-scheme--primitive-car arguments nil)) nil))

(defun agent-scheme--primitive-cddr (arguments _context)
  "Primitive cddr over ARGUMENTS."
  (agent-scheme--primitive-cdr
   (list (agent-scheme--primitive-cdr arguments nil)) nil))

(defun agent-scheme--primitive-boolean=? (arguments _context)
  "Primitive boolean=? over ARGUMENTS."
  (let ((first (car arguments))
        (rest (cdr arguments))
        (ok t))
    (unless (or (eq first agent-scheme-true)
                (eq first agent-scheme-false))
      (agent-scheme--eval-error "boolean=? expected booleans"))
    (while (and ok rest)
      (let ((value (car rest)))
        (unless (or (eq value agent-scheme-true)
                    (eq value agent-scheme-false))
          (agent-scheme--eval-error "boolean=? expected booleans"))
        (setq ok (eq first value)))
      (setq rest (cdr rest)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-complex? (arguments _context)
  "Primitive complex? over ARGUMENTS."
  (agent-scheme--scheme-boolean (agent-scheme-number-p (car arguments))))

(defun agent-scheme--primitive-real? (arguments _context)
  "Primitive real? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme-number-p (car arguments))
        (not (eq (agent-scheme-number-kind (car arguments)) 'complex)))))

(defun agent-scheme--primitive-rational? (arguments _context)
  "Primitive rational? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme-number-p (car arguments))
        (memq (agent-scheme-number-kind (car arguments))
              '(integer rational decimal)))))

(defun agent-scheme--primitive-integer? (arguments _context)
  "Primitive integer? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-integer-p (car arguments))))

(defun agent-scheme--primitive-exact-integer? (arguments _context)
  "Primitive exact-integer? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme--number-integer-p (car arguments))
        (agent-scheme--number-exact-p (car arguments)))))

(defun agent-scheme--primitive-exact? (arguments _context)
  "Primitive exact? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-exact-p (car arguments))))

(defun agent-scheme--primitive-inexact? (arguments _context)
  "Primitive inexact? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-inexact-p (car arguments))))

(defun agent-scheme--primitive-number->string (arguments _context)
  "Primitive number->string over ARGUMENTS."
  (let ((number (car arguments)))
    (unless (agent-scheme-number-p number)
      (agent-scheme--eval-error "number->string expected a number"))
    (agent-scheme-number-lexeme number)))

(defun agent-scheme--primitive-string->number (arguments _context)
  "Primitive string->number over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string
                  (car arguments) "string->number"))
         (value (condition-case nil
                    (agent-scheme-read string)
                  (agent-scheme-reader-error nil))))
    (if (agent-scheme-number-p value)
        value
      agent-scheme-false)))

(defun agent-scheme--primitive-symbol->string (arguments _context)
  "Primitive symbol->string over ARGUMENTS."
  (unless (agent-scheme-symbol-p (car arguments))
    (agent-scheme--eval-error "symbol->string expected a symbol"))
  (copy-sequence (agent-scheme-symbol-name (car arguments))))

(defun agent-scheme--primitive-string->symbol (arguments _context)
  "Primitive string->symbol over ARGUMENTS."
  (agent-scheme--intern-symbol
   (agent-scheme--expect-string (car arguments) "string->symbol")))

(defun agent-scheme--primitive-symbol=? (arguments _context)
  "Primitive symbol=? over ARGUMENTS."
  (let ((first (car arguments))
        (rest (cdr arguments))
        (ok t))
    (unless (agent-scheme-symbol-p first)
      (agent-scheme--eval-error "symbol=? expected symbols"))
    (while (and ok rest)
      (let ((value (car rest)))
        (unless (agent-scheme-symbol-p value)
          (agent-scheme--eval-error "symbol=? expected symbols"))
        (setq ok (equal (agent-scheme-symbol-name first)
                        (agent-scheme-symbol-name value))))
      (setq rest (cdr rest)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-char? (arguments _context)
  "Primitive char? over ARGUMENTS."
  (agent-scheme--scheme-boolean (agent-scheme-character-p (car arguments))))

(defun agent-scheme--primitive-char->integer (arguments _context)
  "Primitive char->integer over ARGUMENTS."
  (agent-scheme--number-from-host
   (agent-scheme--expect-character (car arguments) "char->integer")))

(defun agent-scheme--primitive-integer->char (arguments _context)
  "Primitive integer->char over ARGUMENTS."
  (let ((code (agent-scheme--exact-integer->host
               (car arguments) "integer->char")))
    (unless (agent-scheme--valid-scalar-value-p code)
      (agent-scheme--eval-error "integer->char expected a scalar value"))
    (agent-scheme--make-character code)))

(defun agent-scheme--primitive-char-compare (arguments predicate description)
  "Return Scheme boolean for pairwise character PREDICATE over ARGUMENTS."
  (let ((codes (mapcar
                (lambda (argument)
                  (agent-scheme--expect-character argument description))
                arguments))
        (ok t))
    (while (and ok (cdr codes))
      (setq ok (funcall predicate (car codes) (cadr codes)))
      (setq codes (cdr codes)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-char=? (arguments _context)
  "Primitive char=? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'= "char=?"))

(defun agent-scheme--primitive-char<? (arguments _context)
  "Primitive char<? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'< "char<?"))

(defun agent-scheme--primitive-char>? (arguments _context)
  "Primitive char>? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'> "char>?"))

(defun agent-scheme--primitive-char<=? (arguments _context)
  "Primitive char<=? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'<= "char<=?"))

(defun agent-scheme--primitive-char>=? (arguments _context)
  "Primitive char>=? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'>= "char>=?"))

(defun agent-scheme--primitive-char-upcase (arguments _context)
  "Primitive char-upcase over ARGUMENTS."
  (let ((code (agent-scheme--expect-character
               (car arguments) "char-upcase")))
    (agent-scheme--make-character (upcase code))))

(defun agent-scheme--display-string (value)
  "Return a focused display representation for VALUE."
  (cond
   ((stringp value) value)
   ((agent-scheme-character-p value)
    (char-to-string (agent-scheme-character-code value)))
   (t
    (agent-scheme-value->external value))))

(defun agent-scheme--expect-string-output-port (value description)
  "Return VALUE as a string output port for DESCRIPTION."
  (unless (agent-scheme--string-output-port-p value)
    (agent-scheme--eval-error "%s expected an output string port" description))
  value)

(defun agent-scheme--write-to-output-port (value port displayp)
  "Write VALUE to PORT using display mode when DISPLAYP is non-nil."
  (setf (agent-scheme--string-output-port-contents port)
        (concat (agent-scheme--string-output-port-contents port)
                (if displayp
                    (agent-scheme--display-string value)
                  (agent-scheme-value->external value))))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-open-output-string (_arguments _context)
  "Primitive open-output-string."
  (agent-scheme--make-string-output-port ""))

(defun agent-scheme--primitive-get-output-string (arguments _context)
  "Primitive get-output-string over ARGUMENTS."
  (agent-scheme--string-output-port-contents
   (agent-scheme--expect-string-output-port
    (car arguments) "get-output-string")))

(defun agent-scheme--primitive-display (arguments _context)
  "Primitive display over ARGUMENTS."
  (if (cdr arguments)
      (agent-scheme--write-to-output-port
       (car arguments)
       (agent-scheme--expect-string-output-port
        (cadr arguments) "display")
       t)
    agent-scheme-unspecified))

(defun agent-scheme--primitive-write (arguments _context)
  "Primitive write over ARGUMENTS."
  (if (cdr arguments)
      (agent-scheme--write-to-output-port
       (car arguments)
       (agent-scheme--expect-string-output-port
        (cadr arguments) "write")
       nil)
    agent-scheme-unspecified))

(defun agent-scheme--resolve-file-policy-path (filename context description)
  "Return absolute path for FILENAME after CONTEXT file policy checks."
  (let ((path
         (expand-file-name
          filename
          (agent-scheme--eval-context-include-directory context))))
    (unless (agent-scheme--eval-context-file-paths context)
      (agent-scheme--eval-error
       "%s requires policy-gated host file access: %s"
       description filename))
    (unless (agent-scheme--path-policy-allows-file-p
             path
             (agent-scheme--eval-context-file-paths context))
      (agent-scheme--eval-error
       "%s file is not allowed by policy: %s" description filename))
    path))

(defun agent-scheme--primitive-file-exists? (arguments context)
  "Primitive file-exists? over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "file-exists?"))
         (path (agent-scheme--resolve-file-policy-path
                filename context "file-exists?")))
    (agent-scheme--scheme-boolean (file-exists-p path))))

(defun agent-scheme--primitive-string? (arguments _context)
  "Primitive string? over ARGUMENTS."
  (agent-scheme--scheme-boolean (stringp (car arguments))))

(defun agent-scheme--primitive-make-string (arguments _context)
  "Primitive make-string over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-string"))
         (fill (if (cdr arguments)
                   (agent-scheme--expect-character
                    (cadr arguments) "make-string fill")
                 0)))
    (when (< length 0)
      (agent-scheme--eval-error "make-string length must be non-negative"))
    (make-string length fill)))

(defun agent-scheme--primitive-string (arguments _context)
  "Primitive string over ARGUMENTS."
  (apply #'string
         (mapcar
          (lambda (argument)
            (agent-scheme--expect-character argument "string"))
          arguments)))

(defun agent-scheme--primitive-string-length (arguments _context)
  "Primitive string-length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length (agent-scheme--expect-string
            (car arguments) "string-length"))))

(defun agent-scheme--primitive-string-ref (arguments _context)
  "Primitive string-ref over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-ref"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length string) "string-ref")))
    (agent-scheme--make-character (aref string index))))

(defun agent-scheme--primitive-string-set! (arguments _context)
  "Primitive string-set! over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-set!"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length string) "string-set!"))
         (code (agent-scheme--expect-character
                (caddr arguments) "string-set! value")))
    (aset string index code)
    agent-scheme-unspecified))

(defun agent-scheme--primitive-substring (arguments _context)
  "Primitive substring over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "substring"))
         (start (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length string) "substring" t))
         (end (agent-scheme--expect-nonnegative-index
               (caddr arguments) (length string) "substring" t)))
    (when (> start end)
      (agent-scheme--eval-error "substring start exceeds end"))
    (substring string start end)))

(defun agent-scheme--primitive-string-append (arguments _context)
  "Primitive string-append over ARGUMENTS."
  (mapconcat
   #'identity
   (mapcar
    (lambda (argument)
      (agent-scheme--expect-string argument "string-append"))
    arguments)
   ""))

(defun agent-scheme--primitive-string->list (arguments _context)
  "Primitive string->list over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string->list"))
         (range (agent-scheme--optional-range
                 arguments 1 (length string) "string->list"))
         result)
    (cl-loop for index from (car range) below (cdr range)
             do (push (agent-scheme--make-character (aref string index))
                      result))
    (nreverse result)))

(defun agent-scheme--primitive-list->string (arguments _context)
  "Primitive list->string over ARGUMENTS."
  (apply #'string
         (mapcar
          (lambda (argument)
            (agent-scheme--expect-character argument "list->string"))
          (agent-scheme--proper-list-elements
           (car arguments) "list->string"))))

(defun agent-scheme--primitive-string->vector (arguments _context)
  "Primitive string->vector over ARGUMENTS."
  (vconcat (agent-scheme--primitive-string->list arguments nil)))

(defun agent-scheme--primitive-vector->string (arguments _context)
  "Primitive vector->string over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector->string"))
         (range (agent-scheme--optional-range
                 arguments 1 (length vector) "vector->string"))
         codes)
    (cl-loop for index from (car range) below (cdr range)
             do (push (agent-scheme--expect-character
                       (aref vector index) "vector->string")
                      codes))
    (apply #'string (nreverse codes))))

(defun agent-scheme--primitive-string-copy (arguments _context)
  "Primitive string-copy over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-copy"))
         (range (agent-scheme--optional-range
                 arguments 1 (length string) "string-copy")))
    (substring string (car range) (cdr range))))

(defun agent-scheme--primitive-string-copy! (arguments _context)
  "Primitive string-copy! over ARGUMENTS."
  (let* ((to (agent-scheme--expect-string (car arguments) "string-copy! target"))
         (at (agent-scheme--expect-nonnegative-index
              (cadr arguments) (length to) "string-copy!" t))
         (from (agent-scheme--expect-string
                (caddr arguments) "string-copy! source"))
         (range (agent-scheme--optional-range
                 arguments 3 (length from) "string-copy!"))
         (slice (substring from (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to))
      (agent-scheme--eval-error "string-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to (+ at index) (aref slice index)))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-string-fill! (arguments _context)
  "Primitive string-fill! over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-fill!"))
         (fill (agent-scheme--expect-character
                (cadr arguments) "string-fill! value"))
         (range (agent-scheme--optional-range
                 arguments 2 (length string) "string-fill!")))
    (cl-loop for index from (car range) below (cdr range)
             do (aset string index fill))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-string-compare (arguments predicate description)
  "Return Scheme boolean for pairwise string PREDICATE over ARGUMENTS."
  (let ((strings (mapcar
                  (lambda (argument)
                    (agent-scheme--expect-string argument description))
                  arguments))
        (ok t))
    (while (and ok (cdr strings))
      (setq ok (funcall predicate (car strings) (cadr strings)))
      (setq strings (cdr strings)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-string=? (arguments _context)
  "Primitive string=? over ARGUMENTS."
  (agent-scheme--primitive-string-compare arguments #'string= "string=?"))

(defun agent-scheme--primitive-string<? (arguments _context)
  "Primitive string<? over ARGUMENTS."
  (agent-scheme--primitive-string-compare arguments #'string< "string<?"))

(defun agent-scheme--primitive-string>? (arguments _context)
  "Primitive string>? over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   arguments (lambda (left right) (string< right left)) "string>?"))

(defun agent-scheme--primitive-string<=? (arguments _context)
  "Primitive string<=? over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   arguments (lambda (left right) (not (string< right left))) "string<=?"))

(defun agent-scheme--primitive-string>=? (arguments _context)
  "Primitive string>=? over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   arguments (lambda (left right) (not (string< left right))) "string>=?"))

(defun agent-scheme--map-over-lists (procedure lists context keep-results)
  "Map PROCEDURE over LISTS in CONTEXT.
When KEEP-RESULTS is non-nil, return the collected values."
  (let ((cursors lists)
        results
        done)
    (while (not done)
      (cond
       ((cl-some #'null cursors)
        (setq done t))
       ((cl-some (lambda (cursor) (not (consp cursor))) cursors)
        (agent-scheme--eval-error "map expected proper lists"))
       (t
        (let ((value (agent-scheme--apply-procedure
                      procedure
                      (mapcar #'car cursors)
                      context
                      nil)))
          (when keep-results
            (push value results)))
        (setq cursors (mapcar #'cdr cursors)))))
    (if keep-results
        (nreverse results)
      agent-scheme-unspecified)))

(defun agent-scheme--primitive-apply (arguments context)
  "Primitive apply over ARGUMENTS."
  (let* ((procedure (agent-scheme--expect-procedure
                     (car arguments) "apply procedure"))
         (fixed-arguments (butlast (cdr arguments)))
         (tail (car (last arguments)))
         (tail-arguments
          (agent-scheme--proper-list-elements tail "apply final argument")))
    (agent-scheme--apply-procedure
     procedure
     (append fixed-arguments tail-arguments)
     context
     nil)))

(defun agent-scheme--primitive-map (arguments context)
  "Primitive map over ARGUMENTS."
  (agent-scheme--map-over-lists
   (agent-scheme--expect-procedure (car arguments) "map procedure")
   (cdr arguments)
   context
   t))

(defun agent-scheme--primitive-for-each (arguments context)
  "Primitive for-each over ARGUMENTS."
  (agent-scheme--map-over-lists
   (agent-scheme--expect-procedure (car arguments) "for-each procedure")
   (cdr arguments)
   context
   nil))

(defun agent-scheme--primitive-string-map (arguments context)
  "Primitive string-map over ARGUMENTS."
  (let* ((procedure (agent-scheme--expect-procedure
                     (car arguments) "string-map procedure"))
         (strings (mapcar
                   (lambda (argument)
                     (agent-scheme--expect-string argument "string-map"))
                   (cdr arguments)))
         (length (apply #'min (mapcar #'length strings)))
         codes)
    (cl-loop for index from 0 below length
             do (let ((value
                       (agent-scheme--apply-procedure
                        procedure
                        (mapcar
                         (lambda (string)
                           (agent-scheme--make-character
                            (aref string index)))
                         strings)
                        context
                        nil)))
                  (push (agent-scheme--expect-character
                         value "string-map result")
                        codes)))
    (apply #'string (nreverse codes))))

(defun agent-scheme--primitive-string-for-each (arguments context)
  "Primitive string-for-each over ARGUMENTS."
  (let* ((procedure (agent-scheme--expect-procedure
                     (car arguments) "string-for-each procedure"))
         (strings (mapcar
                   (lambda (argument)
                     (agent-scheme--expect-string argument "string-for-each"))
                   (cdr arguments)))
         (length (apply #'min (mapcar #'length strings))))
    (cl-loop for index from 0 below length
             do (agent-scheme--apply-procedure
                 procedure
                 (mapcar
                  (lambda (string)
                    (agent-scheme--make-character (aref string index)))
                  strings)
                 context
                 nil)))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-vector? (arguments _context)
  "Primitive vector? over ARGUMENTS."
  (agent-scheme--scheme-boolean (vectorp (car arguments))))

(defun agent-scheme--primitive-make-vector (arguments _context)
  "Primitive make-vector over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-vector"))
         (fill (if (cdr arguments) (cadr arguments) agent-scheme-unspecified)))
    (when (< length 0)
      (agent-scheme--eval-error "make-vector length must be non-negative"))
    (make-vector length fill)))

(defun agent-scheme--primitive-vector (arguments _context)
  "Primitive vector over ARGUMENTS."
  (vconcat arguments))

(defun agent-scheme--primitive-vector-length (arguments _context)
  "Primitive vector-length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length (agent-scheme--expect-vector
            (car arguments) "vector-length"))))

(defun agent-scheme--primitive-vector-ref (arguments _context)
  "Primitive vector-ref over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-ref"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length vector) "vector-ref")))
    (aref vector index)))

(defun agent-scheme--primitive-vector-set! (arguments _context)
  "Primitive vector-set! over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-set!"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length vector) "vector-set!")))
    (aset vector index (caddr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-vector->list (arguments _context)
  "Primitive vector->list over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector->list"))
         (range (agent-scheme--optional-range
                 arguments 1 (length vector) "vector->list"))
         result)
    (cl-loop for index from (car range) below (cdr range)
             do (push (aref vector index) result))
    (nreverse result)))

(defun agent-scheme--primitive-list->vector (arguments _context)
  "Primitive list->vector over ARGUMENTS."
  (vconcat (agent-scheme--proper-list-elements
            (car arguments) "list->vector")))

(defun agent-scheme--primitive-vector-copy (arguments _context)
  "Primitive vector-copy over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-copy"))
         (range (agent-scheme--optional-range
                 arguments 1 (length vector) "vector-copy")))
    (cl-subseq vector (car range) (cdr range))))

(defun agent-scheme--primitive-vector-copy! (arguments _context)
  "Primitive vector-copy! over ARGUMENTS."
  (let* ((to (agent-scheme--expect-vector (car arguments) "vector-copy! target"))
         (at (agent-scheme--expect-nonnegative-index
              (cadr arguments) (length to) "vector-copy!" t))
         (from (agent-scheme--expect-vector
                (caddr arguments) "vector-copy! source"))
         (range (agent-scheme--optional-range
                 arguments 3 (length from) "vector-copy!"))
         (slice (cl-subseq from (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to))
      (agent-scheme--eval-error "vector-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to (+ at index) (aref slice index)))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-vector-append (arguments _context)
  "Primitive vector-append over ARGUMENTS."
  (apply #'vconcat
         (mapcar
          (lambda (argument)
            (agent-scheme--expect-vector argument "vector-append"))
          arguments)))

(defun agent-scheme--primitive-vector-fill! (arguments _context)
  "Primitive vector-fill! over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-fill!"))
         (fill (cadr arguments))
         (range (agent-scheme--optional-range
                 arguments 2 (length vector) "vector-fill!")))
    (cl-loop for index from (car range) below (cdr range)
             do (aset vector index fill))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-vector-map (arguments context)
  "Primitive vector-map over ARGUMENTS."
  (let* ((procedure (agent-scheme--expect-procedure
                     (car arguments) "vector-map procedure"))
         (vectors (mapcar
                   (lambda (argument)
                     (agent-scheme--expect-vector argument "vector-map"))
                   (cdr arguments)))
         (length (apply #'min (mapcar #'length vectors)))
         results)
    (cl-loop for index from 0 below length
             do (push
                 (agent-scheme--apply-procedure
                  procedure
                  (mapcar (lambda (vector) (aref vector index)) vectors)
                  context
                  nil)
                 results))
    (vconcat (nreverse results))))

(defun agent-scheme--primitive-vector-for-each (arguments context)
  "Primitive vector-for-each over ARGUMENTS."
  (agent-scheme--primitive-vector-map arguments context)
  agent-scheme-unspecified)

(defun agent-scheme--primitive-bytevector? (arguments _context)
  "Primitive bytevector? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme-bytevector-p (car arguments))))

(defun agent-scheme--primitive-make-bytevector (arguments _context)
  "Primitive make-bytevector over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-bytevector"))
         (fill (if (cdr arguments)
                   (agent-scheme--expect-byte
                    (cadr arguments) "make-bytevector fill")
                 0)))
    (when (< length 0)
      (agent-scheme--eval-error "make-bytevector length must be non-negative"))
    (agent-scheme--make-bytevector (make-vector length fill))))

(defun agent-scheme--primitive-bytevector (arguments _context)
  "Primitive bytevector over ARGUMENTS."
  (agent-scheme--make-bytevector
   (vconcat
    (mapcar
     (lambda (argument)
       (agent-scheme--expect-byte argument "bytevector"))
     arguments))))

(defun agent-scheme--primitive-bytevector-length (arguments _context)
  "Primitive bytevector-length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length
    (agent-scheme-bytevector-bytes
     (agent-scheme--expect-bytevector
      (car arguments) "bytevector-length")))))

(defun agent-scheme--primitive-bytevector-u8-ref (arguments _context)
  "Primitive bytevector-u8-ref over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "bytevector-u8-ref"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length bytes) "bytevector-u8-ref")))
    (agent-scheme--number-from-host (aref bytes index))))

(defun agent-scheme--primitive-bytevector-u8-set! (arguments _context)
  "Primitive bytevector-u8-set! over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "bytevector-u8-set!"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length bytes) "bytevector-u8-set!")))
    (aset bytes index
          (agent-scheme--expect-byte
           (caddr arguments) "bytevector-u8-set! value"))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-bytevector-copy (arguments _context)
  "Primitive bytevector-copy over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "bytevector-copy"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (range (agent-scheme--optional-range
                 arguments 1 (length bytes) "bytevector-copy")))
    (agent-scheme--make-bytevector
     (cl-subseq bytes (car range) (cdr range)))))

(defun agent-scheme--primitive-bytevector-copy! (arguments _context)
  "Primitive bytevector-copy! over ARGUMENTS."
  (let* ((to (agent-scheme--expect-bytevector
              (car arguments) "bytevector-copy! target"))
         (to-bytes (agent-scheme-bytevector-bytes to))
         (at (agent-scheme--expect-nonnegative-index
              (cadr arguments) (length to-bytes) "bytevector-copy!" t))
         (from (agent-scheme--expect-bytevector
                (caddr arguments) "bytevector-copy! source"))
         (from-bytes (agent-scheme-bytevector-bytes from))
         (range (agent-scheme--optional-range
                 arguments 3 (length from-bytes) "bytevector-copy!"))
         (slice (cl-subseq from-bytes (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to-bytes))
      (agent-scheme--eval-error "bytevector-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to-bytes (+ at index) (aref slice index)))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-bytevector-append (arguments _context)
  "Primitive bytevector-append over ARGUMENTS."
  (agent-scheme--make-bytevector
   (apply #'vconcat
          (mapcar
           (lambda (argument)
             (agent-scheme-bytevector-bytes
              (agent-scheme--expect-bytevector argument "bytevector-append")))
           arguments))))

(defconst agent-scheme--base-primitive-registry
  '(("*" agent-scheme--primitive* 0 nil)
    ("+" agent-scheme--primitive+ 0 nil)
    ("-" agent-scheme--primitive- 1 nil)
    ("/" agent-scheme--primitive/ 1 nil)
    ("<" agent-scheme--primitive< 2 nil)
    ("<=" agent-scheme--primitive<= 2 nil)
    ("=" agent-scheme--primitive= 2 nil)
    (">" agent-scheme--primitive> 2 nil)
    (">=" agent-scheme--primitive>= 2 nil)
    ("apply" agent-scheme--primitive-apply 2 nil)
    ("boolean=?" agent-scheme--primitive-boolean=? 2 nil)
    ("boolean?" agent-scheme--primitive-boolean? 1 1)
    ("bytevector" agent-scheme--primitive-bytevector 0 nil)
    ("bytevector-append" agent-scheme--primitive-bytevector-append 0 nil)
    ("bytevector-copy" agent-scheme--primitive-bytevector-copy 1 3)
    ("bytevector-copy!" agent-scheme--primitive-bytevector-copy! 3 5)
    ("bytevector-length" agent-scheme--primitive-bytevector-length 1 1)
    ("bytevector-u8-ref" agent-scheme--primitive-bytevector-u8-ref 2 2)
    ("bytevector-u8-set!" agent-scheme--primitive-bytevector-u8-set! 3 3)
    ("bytevector?" agent-scheme--primitive-bytevector? 1 1)
    ("car" agent-scheme--primitive-car 1 1)
    ("cdr" agent-scheme--primitive-cdr 1 1)
    ("ceiling" agent-scheme--primitive-ceiling 1 1)
    ("char->integer" agent-scheme--primitive-char->integer 1 1)
    ("char<=?" agent-scheme--primitive-char<=? 2 nil)
    ("char<?" agent-scheme--primitive-char<? 2 nil)
    ("char=?" agent-scheme--primitive-char=? 2 nil)
    ("char>=?" agent-scheme--primitive-char>=? 2 nil)
    ("char>?" agent-scheme--primitive-char>? 2 nil)
    ("char?" agent-scheme--primitive-char? 1 1)
    ("complex?" agent-scheme--primitive-complex? 1 1)
    ("cons" agent-scheme--primitive-cons 2 2)
    ("eq?" agent-scheme--primitive-eq? 2 2)
    ("equal?" agent-scheme--primitive-equal? 2 2)
    ("eqv?" agent-scheme--primitive-eqv? 2 2)
    ("exact-integer?" agent-scheme--primitive-exact-integer? 1 1)
    ("exact?" agent-scheme--primitive-exact? 1 1)
    ("floor" agent-scheme--primitive-floor 1 1)
    ("floor-quotient" agent-scheme--primitive-floor-quotient 2 2)
    ("floor-remainder" agent-scheme--primitive-floor-remainder 2 2)
    ("inexact?" agent-scheme--primitive-inexact? 1 1)
    ("integer->char" agent-scheme--primitive-integer->char 1 1)
    ("integer?" agent-scheme--primitive-integer? 1 1)
    ("list->string" agent-scheme--primitive-list->string 1 1)
    ("list->vector" agent-scheme--primitive-list->vector 1 1)
    ("list?" agent-scheme--primitive-list? 1 1)
    ("make-bytevector" agent-scheme--primitive-make-bytevector 1 2)
    ("make-string" agent-scheme--primitive-make-string 1 2)
    ("make-vector" agent-scheme--primitive-make-vector 1 2)
    ("modulo" agent-scheme--primitive-modulo 2 2)
    ("null?" agent-scheme--primitive-null? 1 1)
    ("number->string" agent-scheme--primitive-number->string 1 1)
    ("number?" agent-scheme--primitive-number? 1 1)
    ("pair?" agent-scheme--primitive-pair? 1 1)
    ("procedure?" agent-scheme--primitive-procedure? 1 1)
    ("quotient" agent-scheme--primitive-quotient 2 2)
    ("rational?" agent-scheme--primitive-rational? 1 1)
    ("real?" agent-scheme--primitive-real? 1 1)
    ("remainder" agent-scheme--primitive-remainder 2 2)
    ("round" agent-scheme--primitive-round 1 1)
    ("set-car!" agent-scheme--primitive-set-car! 2 2)
    ("set-cdr!" agent-scheme--primitive-set-cdr! 2 2)
    ("string" agent-scheme--primitive-string 0 nil)
    ("string->list" agent-scheme--primitive-string->list 1 3)
    ("string->number" agent-scheme--primitive-string->number 1 1)
    ("string->symbol" agent-scheme--primitive-string->symbol 1 1)
    ("string->vector" agent-scheme--primitive-string->vector 1 3)
    ("string-append" agent-scheme--primitive-string-append 0 nil)
    ("string-copy" agent-scheme--primitive-string-copy 1 3)
    ("string-copy!" agent-scheme--primitive-string-copy! 3 5)
    ("string-fill!" agent-scheme--primitive-string-fill! 2 4)
    ("string-for-each" agent-scheme--primitive-string-for-each 2 nil)
    ("string-length" agent-scheme--primitive-string-length 1 1)
    ("string-map" agent-scheme--primitive-string-map 2 nil)
    ("string-ref" agent-scheme--primitive-string-ref 2 2)
    ("string-set!" agent-scheme--primitive-string-set! 3 3)
    ("string<=?" agent-scheme--primitive-string<=? 2 nil)
    ("string<?" agent-scheme--primitive-string<? 2 nil)
    ("string=?" agent-scheme--primitive-string=? 2 nil)
    ("string>=?" agent-scheme--primitive-string>=? 2 nil)
    ("string>?" agent-scheme--primitive-string>? 2 nil)
    ("string?" agent-scheme--primitive-string? 1 1)
    ("substring" agent-scheme--primitive-substring 3 3)
    ("symbol->string" agent-scheme--primitive-symbol->string 1 1)
    ("symbol=?" agent-scheme--primitive-symbol=? 2 nil)
    ("symbol?" agent-scheme--primitive-symbol? 1 1)
    ("truncate" agent-scheme--primitive-truncate 1 1)
    ("truncate-quotient" agent-scheme--primitive-truncate-quotient 2 2)
    ("truncate-remainder" agent-scheme--primitive-truncate-remainder 2 2)
    ("vector" agent-scheme--primitive-vector 0 nil)
    ("vector->list" agent-scheme--primitive-vector->list 1 3)
    ("vector->string" agent-scheme--primitive-vector->string 1 3)
    ("vector-append" agent-scheme--primitive-vector-append 0 nil)
    ("vector-copy" agent-scheme--primitive-vector-copy 1 3)
    ("vector-copy!" agent-scheme--primitive-vector-copy! 3 5)
    ("vector-fill!" agent-scheme--primitive-vector-fill! 2 4)
    ("vector-for-each" agent-scheme--primitive-vector-for-each 2 nil)
    ("vector-length" agent-scheme--primitive-vector-length 1 1)
    ("vector-map" agent-scheme--primitive-vector-map 2 nil)
    ("vector-ref" agent-scheme--primitive-vector-ref 2 2)
    ("vector-set!" agent-scheme--primitive-vector-set! 3 3)
    ("vector?" agent-scheme--primitive-vector? 1 1))
  "Registry of implemented `(scheme base)' primitive procedures.
Each entry is (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY).")

(defun agent-scheme-base-primitive-names ()
  "Return implemented `(scheme base)' primitive procedure names."
  (mapcar #'car agent-scheme--base-primitive-registry))

(defun agent-scheme-base-primitive-specs ()
  "Return discoverable metadata for implemented `(scheme base)' primitives."
  (mapcar
   (lambda (entry)
     (list :name (nth 0 entry)
           :minimum-arity (nth 2 entry)
           :maximum-arity (nth 3 entry)
           :source 'kernel))
   agent-scheme--base-primitive-registry))

(defun agent-scheme--base-prelude-file ()
  "Return the portable `(scheme base)' prelude source file path."
  (or agent-scheme-base-prelude-file
      (expand-file-name
       "../scheme/agent-scheme/base-prelude.scm"
       agent-scheme--source-directory)))

(defun agent-scheme--base-prelude-source ()
  "Return the portable `(scheme base)' prelude source."
  (with-temp-buffer
    (insert-file-contents (agent-scheme--base-prelude-file))
    (buffer-string)))

(defun agent-scheme--base-prelude-forms ()
  "Return parsed portable prelude definition forms."
  (agent-scheme-read-all (agent-scheme--base-prelude-source)))

(defun agent-scheme--base-syntax-file ()
  "Return the portable `(scheme base)' syntax prelude source file path."
  (or agent-scheme-base-syntax-file
      (expand-file-name
       "../scheme/agent-scheme/base-syntax.scm"
       agent-scheme--source-directory)))

(defun agent-scheme--base-syntax-source ()
  "Return the portable `(scheme base)' syntax prelude source."
  (with-temp-buffer
    (insert-file-contents (agent-scheme--base-syntax-file))
    (buffer-string)))

(defun agent-scheme--base-syntax-forms ()
  "Return parsed portable base syntax definition forms."
  (agent-scheme-read-all (agent-scheme--base-syntax-source)))

(defun agent-scheme--formals-arity (formals)
  "Return (MINIMUM-ARITY . MAXIMUM-ARITY) for Scheme FORMALS."
  (cond
   ((agent-scheme-symbol-p formals)
    (cons 0 nil))
   (t
    (let ((cursor formals)
          (minimum 0))
      (while (consp cursor)
        (setq minimum (1+ minimum))
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor)
        (cons minimum minimum))
       ((agent-scheme-symbol-p cursor)
        (cons minimum nil))
       (t
        (agent-scheme--eval-error
         "prelude definition has invalid formals")))))))

(defun agent-scheme--prelude-definition-spec (form)
  "Return metadata for one portable prelude definition FORM."
  (let ((parts (agent-scheme--proper-list-elements
                form "prelude definition")))
    (unless (and (>= (length parts) 3)
                 (agent-scheme--symbol-named-p (car parts) "define"))
      (agent-scheme--eval-error "prelude form must be one definition"))
    (let ((target (cadr parts))
          arity)
      (cond
       ((agent-scheme-symbol-p target)
        (unless (= (length parts) 3)
          (agent-scheme--eval-error
           "prelude variable definition must have one initializer"))
        (let ((initializer (caddr parts)))
          (unless (and (consp initializer)
                       (agent-scheme--symbol-named-p
                        (car initializer) "lambda"))
            (agent-scheme--eval-error
             "prelude variable definition must initialize a lambda"))
          (setq arity (agent-scheme--formals-arity (cadr initializer)))
          (list :name (agent-scheme-symbol-name target)
                :minimum-arity (car arity)
                :maximum-arity (cdr arity)
                :source 'prelude)))
       ((consp target)
        (setq arity (agent-scheme--formals-arity (cdr target)))
        (list :name (agent-scheme--expect-symbol-name
                     (car target) "prelude function name")
              :minimum-arity (car arity)
              :maximum-arity (cdr arity)
              :source 'prelude))
       (t
        (agent-scheme--eval-error
         "prelude define target must be an identifier or function signature"))))))

(defun agent-scheme-base-prelude-binding-specs ()
  "Return discoverable metadata for portable prelude bindings."
  (mapcar #'agent-scheme--prelude-definition-spec
          (agent-scheme--base-prelude-forms)))

(defun agent-scheme-base-prelude-binding-names ()
  "Return names supplied by the portable `(scheme base)' prelude."
  (mapcar (lambda (spec) (plist-get spec :name))
          (agent-scheme-base-prelude-binding-specs)))

(defun agent-scheme-base-binding-specs ()
  "Return discoverable metadata for kernel and prelude base bindings."
  (append (agent-scheme-base-primitive-specs)
          (agent-scheme-base-prelude-binding-specs)))

(defun agent-scheme--define-primitive
    (environment name function minimum-arity maximum-arity)
  "Register primitive NAME in ENVIRONMENT."
  (agent-scheme--environment-define
   environment
   name
   (agent-scheme--make-primitive-procedure
    name function minimum-arity maximum-arity)))

(defun agent-scheme-make-base-environment ()
  "Return a fresh environment with kernel and prelude `(scheme base)' bindings."
  (let ((environment (agent-scheme-make-empty-environment)))
    (dolist (entry agent-scheme--base-primitive-registry)
      (agent-scheme--define-primitive
       environment
       (nth 0 entry)
       (nth 1 entry)
       (nth 2 entry)
       (nth 3 entry)))
    (agent-scheme--trampoline
     (agent-scheme--make-sequence (agent-scheme--base-prelude-forms) t)
     environment
     (agent-scheme--new-eval-context nil))
    environment))

(defun agent-scheme--ensure-base-syntax (context environment)
  "Install base derived syntax into CONTEXT once, capturing ENVIRONMENT."
  (unless (agent-scheme--eval-context-base-syntax-installed context)
    (dolist (form (agent-scheme--base-syntax-forms))
      (agent-scheme--eval-define-syntax
       form
       environment
       context
       (agent-scheme--eval-context-syntax-environment context)))
    (setf (agent-scheme--eval-context-base-syntax-installed context) t)))

(defun agent-scheme--expand-definition-form (form environment context)
  "Return macro-expanded variable definition FORM."
  (let* ((parts (agent-scheme--proper-list-elements form "define form"))
         (target (cadr parts)))
    (cond
     ((agent-scheme--identifier-datum-p target)
      (unless (= (length parts) 3)
        (agent-scheme--eval-error
         "define requires an identifier and an expression"))
      (list (car parts)
            target
            (agent-scheme--expand-expression-fully
             (caddr parts) environment context)))
     ((consp target)
      (append
       (list (car parts) target)
       (agent-scheme--expand-sequence-forms
        (cddr parts) environment context t)))
     (t
      (agent-scheme--eval-error
       "define target must be an identifier or function signature")))))

(defun agent-scheme--expand-core-combination (expression environment context)
  "Return EXPRESSION with macro expansion recursively applied."
  (let* ((parts (agent-scheme--proper-list-elements expression "expression"))
         (operator (car parts)))
    (cond
     ((or (and (agent-scheme--symbol-named-p operator "quote")
               (agent-scheme--special-operator-active-p operator environment))
          (and (agent-scheme--symbol-named-p operator "quasiquote")
               (agent-scheme--special-operator-active-p operator environment)))
      expression)
     ((and (agent-scheme--symbol-named-p operator "lambda")
           (agent-scheme--special-operator-active-p operator environment))
      (unless (>= (length parts) 3)
        (agent-scheme--eval-error "lambda requires formals and a body"))
      (append (list operator (cadr parts))
              (agent-scheme--expand-sequence-forms
               (cddr parts) environment context t)))
     ((and (agent-scheme--symbol-named-p operator "if")
           (agent-scheme--special-operator-active-p operator environment))
      (unless (memq (length parts) '(3 4))
        (agent-scheme--eval-error
         "if requires test, consequent, and optional alternate"))
      (append
       (list operator
             (agent-scheme--expand-expression-fully
              (cadr parts) environment context)
             (agent-scheme--expand-expression-fully
              (caddr parts) environment context))
       (and (= (length parts) 4)
            (list
             (agent-scheme--expand-expression-fully
              (cadddr parts) environment context)))))
     ((and (agent-scheme--symbol-named-p operator "set!")
           (agent-scheme--special-operator-active-p operator environment))
      (unless (= (length parts) 3)
        (agent-scheme--eval-error
         "set! requires an identifier and an expression"))
      (list operator
            (cadr parts)
            (agent-scheme--expand-expression-fully
             (caddr parts) environment context)))
     ((and (member (agent-scheme--symbol-name operator) '("letrec" "letrec*"))
           (agent-scheme--special-operator-active-p operator environment))
      (let ((bindings
             (mapcar
              (lambda (binding)
                (let ((binding-parts
                       (agent-scheme--proper-list-elements
                        binding "letrec binding")))
                  (unless (= (length binding-parts) 2)
                    (agent-scheme--eval-error
                     "letrec binding must contain an identifier and initializer"))
                  (list (car binding-parts)
                        (agent-scheme--expand-expression-fully
                         (cadr binding-parts) environment context))))
              (agent-scheme--proper-list-elements
               (cadr parts) "letrec binding list"))))
        (append (list operator bindings)
                (agent-scheme--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (agent-scheme--symbol-named-p operator "begin")
           (agent-scheme--special-operator-active-p operator environment))
      (cons operator
            (agent-scheme--expand-sequence-forms
             (cdr parts) environment context nil)))
     (t
      (mapcar
       (lambda (part)
         (agent-scheme--expand-expression-fully part environment context))
       parts)))))

(defun agent-scheme--expand-expression-fully (expression environment context)
  "Return EXPRESSION after recursive macro expansion."
  (let ((expanded (agent-scheme--expand-expression
                   expression environment context)))
    (cond
     ((not (eq expanded expression))
      (cond
       ((agent-scheme--syntax-scope-p expanded)
        (agent-scheme--with-syntax-environment
         context
         (agent-scheme--syntax-scope-syntax-environment expanded)
         (lambda ()
           (cons (agent-scheme--syntax-symbol "begin")
                 (agent-scheme--expand-sequence-forms
                  (agent-scheme--syntax-scope-forms expanded)
                  environment
                  context
                  t)))))
       (t
        (agent-scheme--expand-expression-fully expanded environment context))))
     ((consp expression)
      (agent-scheme--expand-core-combination expression environment context))
     (t expression))))

(defun agent-scheme--expand-sequence-forms
    (forms environment context allow-definitions)
  "Return FORMS after macro expansion under CONTEXT."
  (let (expanded-forms)
    (dolist (form forms)
      (cond
       ((and allow-definitions
             (agent-scheme--import-form-p form))
        (agent-scheme--eval-import form environment context))
       ((and allow-definitions
             (agent-scheme--define-library-form-p form))
        (agent-scheme--eval-define-library form environment context))
       ((and allow-definitions
             (agent-scheme--syntax-definition-form-p form))
        (agent-scheme--eval-define-syntax
         form
         environment
         context
         (agent-scheme--eval-context-syntax-environment context)))
       ((and allow-definitions
             (agent-scheme--definition-form-p form))
        (push (agent-scheme--expand-definition-form
               form environment context)
              expanded-forms))
       ((and allow-definitions
             (agent-scheme--begin-form-p form))
        (dolist (begin-form
                 (agent-scheme--expand-sequence-forms
                  (cdr (agent-scheme--proper-list-elements form "begin form"))
                  environment
                  context
                  t))
          (push begin-form expanded-forms)))
       (t
        (push (agent-scheme--expand-expression-fully
               form environment context)
              expanded-forms))))
    (nreverse expanded-forms)))

;;;###autoload
(defun agent-scheme-expand (expression &optional environment options)
  "Macro-expand one Agent Scheme EXPRESSION datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--expand-expression-fully
     expression eval-environment context)))

;;;###autoload
(defun agent-scheme-expand-source (source &optional environment options)
  "Read SOURCE and return its macro-expanded non-syntax forms."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--expand-sequence-forms
     (agent-scheme-read-all source)
     eval-environment
     context
     t)))

;;;###autoload
(defun agent-scheme-eval (expression &optional environment options)
  "Evaluate one Agent Scheme EXPRESSION datum.
ENVIRONMENT defaults to a fresh base environment.  OPTIONS is a
plist supporting `:max-steps', `:max-non-tail-steps',
`:max-value-nodes', and `:max-host-callbacks'."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--trampoline expression eval-environment context)))

;;;###autoload
(defun agent-scheme-eval-source (source &optional environment options)
  "Read and evaluate all datums in SOURCE.
ENVIRONMENT defaults to a fresh base environment.  The returned value
is the result of the last command or definition."
  (let* ((forms (agent-scheme-read-all source))
         (context (agent-scheme--new-eval-context options))
         (eval-environment (or environment
                               (agent-scheme-make-base-environment)))
         (sequence (agent-scheme--make-sequence forms t)))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--trampoline sequence eval-environment context)))

;;;###autoload
(defalias 'agent-scheme-eval-string #'agent-scheme-eval-source)

(defun agent-scheme--result-field (name &rest values)
  "Return a Scheme-readable result field named NAME with VALUES."
  (cons (agent-scheme--syntax-symbol name) values))

(defun agent-scheme--result-symbol (name)
  "Return a Scheme symbol for result NAME."
  (agent-scheme--syntax-symbol name))

(defun agent-scheme--value->result-datum (value &optional seen)
  "Return VALUE encoded as a Scheme-readable result datum.
Opaque runtime values are represented by tagged data rather than host
objects so result records can be rendered by `agent-scheme-datum->external'."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((or (null value)
          (eq value agent-scheme-true)
          (eq value agent-scheme-false)
          (agent-scheme-symbol-p value)
          (agent-scheme-character-p value)
          (agent-scheme-number-p value)
          (stringp value)
          (agent-scheme-bytevector-p value))
      value)
     ((agent-scheme--identifier-p value)
      (agent-scheme--syntax-symbol
       (agent-scheme--identifier-name value)))
     ((agent-scheme-unspecified-p value)
      (list (agent-scheme--result-symbol "unspecified")))
     ((agent-scheme-primitive-procedure-p value)
      (list (agent-scheme--result-symbol "procedure")
            (agent-scheme--result-field "kind"
                                        (agent-scheme--result-symbol "primitive"))
            (agent-scheme--result-field
             "name"
             (agent-scheme--syntax-symbol
              (agent-scheme-primitive-procedure-name value)))))
     ((agent-scheme-procedure-p value)
      (list (agent-scheme--result-symbol "procedure")
            (agent-scheme--result-field "kind"
                                        (agent-scheme--result-symbol "compound"))))
     ((consp value)
      (if (gethash value seen)
          (list (agent-scheme--result-symbol "cycle"))
        (puthash value t seen)
        (cons (agent-scheme--value->result-datum (car value) seen)
              (agent-scheme--value->result-datum (cdr value) seen))))
     ((vectorp value)
      (if (gethash value seen)
          (vector (agent-scheme--result-symbol "cycle"))
        (puthash value t seen)
        (vconcat
         (mapcar
          (lambda (item)
            (agent-scheme--value->result-datum item seen))
          (append value nil)))))
     (t
      (list (agent-scheme--result-symbol "host-object")
            (agent-scheme--result-field "printed" (format "%S" value)))))))

(defun agent-scheme--strip-identifiers (value &optional seen)
  "Return VALUE with hygienic identifiers converted to plain symbols."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((agent-scheme--identifier-p value)
      (agent-scheme--syntax-symbol (agent-scheme--identifier-name value)))
     ((consp value)
      (if (gethash value seen)
          value
        (puthash value t seen)
        (cons (agent-scheme--strip-identifiers (car value) seen)
              (agent-scheme--strip-identifiers (cdr value) seen))))
     ((vectorp value)
      (if (gethash value seen)
          value
        (puthash value t seen)
        (vconcat
         (mapcar
          (lambda (item)
            (agent-scheme--strip-identifiers item seen))
          (append value nil)))))
     (t value))))

(defun agent-scheme--budget-result-field (context)
  "Return the budget field for CONTEXT."
  (agent-scheme--result-field
   "budget"
   (agent-scheme--result-field
    "steps-used"
    (agent-scheme--number-from-host
     (agent-scheme--eval-context-steps context)))
   (agent-scheme--result-field
    "host-calls"
    (agent-scheme--number-from-host
     (agent-scheme--eval-context-host-callbacks context)))))

(defun agent-scheme--ok-result-datum (value context)
  "Return a stable Scheme-readable successful evaluation result."
  (list (agent-scheme--result-symbol "evaluation-result")
        (agent-scheme--result-field "status"
                                    (agent-scheme--result-symbol "ok"))
        (agent-scheme--result-field
         "value"
         (agent-scheme--value->result-datum value))
        (agent-scheme--result-field "events" nil)
        (agent-scheme--budget-result-field context)))

(defun agent-scheme--condition-result-datum (condition context)
  "Return a stable Scheme-readable error result for CONDITION."
  (let ((condition-name (symbol-name (car condition))))
    (list (agent-scheme--result-symbol "evaluation-result")
          (agent-scheme--result-field "status"
                                      (agent-scheme--result-symbol "error"))
          (agent-scheme--result-field
           "error"
           (agent-scheme--result-field
            "condition"
            (agent-scheme--syntax-symbol condition-name))
           (agent-scheme--result-field
            "message"
            (error-message-string condition)))
          (agent-scheme--result-field "events" nil)
          (agent-scheme--budget-result-field context))))

;;;###autoload
(defun agent-scheme-eval-result (expression &optional environment options)
  "Evaluate EXPRESSION and return a Scheme-readable result datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (condition-case condition
        (agent-scheme--ok-result-datum
         (agent-scheme--trampoline expression eval-environment context)
         context)
      (error
       (agent-scheme--condition-result-datum condition context)))))

;;;###autoload
(defun agent-scheme-eval-source-result (source &optional environment options)
  "Read and evaluate SOURCE and return a Scheme-readable result datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (condition-case condition
        (let* ((forms (agent-scheme-read-all source))
               (sequence (agent-scheme--make-sequence forms t)))
          (agent-scheme--ok-result-datum
           (agent-scheme--trampoline sequence eval-environment context)
           context))
      (error
       (agent-scheme--condition-result-datum condition context)))))

(defun agent-scheme-result->external (result)
  "Return RESULT as a stable Scheme-readable external representation."
  (agent-scheme-datum->external result))

(defun agent-scheme-value->external (value)
  "Return a stable external representation for evaluated VALUE."
  (cond
   ((agent-scheme-unspecified-p value)
    "#<unspecified>")
   ((agent-scheme-procedure-p value)
    "#<procedure>")
   ((agent-scheme-primitive-procedure-p value)
    (format "#<primitive %s>"
            (agent-scheme-primitive-procedure-name value)))
   (t
    (agent-scheme-datum->external
     (agent-scheme--strip-identifiers value)))))

(provide 'agent-scheme-eval)

;;; agent-scheme-eval.el ends here
