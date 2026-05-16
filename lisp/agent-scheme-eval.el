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

(cl-defstruct (agent-scheme--sequence
               (:constructor agent-scheme--make-sequence
                             (forms allow-definitions))
               (:copier nil))
  "Internal sequence expression."
  forms allow-definitions)

(cl-defstruct (agent-scheme--bounce
               (:constructor agent-scheme--make-bounce
                             (expression environment))
               (:copier nil))
  "Trampoline state for evaluating EXPRESSION in ENVIRONMENT."
  expression environment)

(cl-defstruct (agent-scheme--eval-context
               (:constructor agent-scheme--make-eval-context)
               (:copier nil))
  steps
  maximum-steps
  maximum-value-nodes
  host-callbacks
  maximum-host-callbacks)

(defconst agent-scheme--missing-cell (make-symbol "agent-scheme-missing-cell")
  "Sentinel used when looking up environment cells.")

(defun agent-scheme--eval-option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun agent-scheme--new-eval-context (options)
  "Return an evaluator context using OPTIONS."
  (let ((maximum-steps
         (cond
          ((plist-member options :max-steps)
           (plist-get options :max-steps))
          ((plist-member options :max-non-tail-steps)
           (plist-get options :max-non-tail-steps))
          (t agent-scheme-eval-maximum-steps))))
    (agent-scheme--make-eval-context
     :steps 0
     :maximum-steps maximum-steps
     :maximum-value-nodes
     (agent-scheme--eval-option options :max-value-nodes
                                agent-scheme-eval-maximum-value-nodes)
     :host-callbacks 0
     :maximum-host-callbacks
     (agent-scheme--eval-option options :max-host-callbacks
                                agent-scheme-eval-maximum-host-callbacks))))

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
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-procedure-p value)
        (agent-scheme-primitive-procedure-p value))
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

(defun agent-scheme--symbol-name (datum)
  "Return DATUM's Scheme symbol name, or nil."
  (and (agent-scheme-symbol-p datum)
       (agent-scheme-symbol-name datum)))

(defun agent-scheme--symbol-named-p (datum name)
  "Return non-nil if DATUM is a Scheme symbol named NAME."
  (equal (agent-scheme--symbol-name datum) name))

(defun agent-scheme--syntax-symbol (name)
  "Return Agent Scheme symbol datum for NAME."
  (agent-scheme--intern-symbol name))

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
    (agent-scheme--make-formals nil (agent-scheme-symbol-name formals)))
   (t
    (let ((cursor formals)
          required
          rest)
      (while (consp cursor)
        (push (agent-scheme--expect-symbol-name
               (car cursor) "lambda formal")
              required)
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor))
       ((agent-scheme-symbol-p cursor)
        (setq rest (agent-scheme-symbol-name cursor)))
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
        (cons (agent-scheme-symbol-name target) (car body)))
       ((consp target)
        (let ((name (agent-scheme--expect-symbol-name
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
          (agent-scheme--make-bounce body-expression (car body-state))
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
          (agent-scheme--make-bounce (caddr parts) environment)
        (agent-scheme--eval-expression (caddr parts) environment context nil)))
     ((= (length parts) 4)
      (if tailp
          (agent-scheme--make-bounce (cadddr parts) environment)
        (agent-scheme--eval-expression (cadddr parts) environment context nil)))
     (t
      agent-scheme-unspecified))))

(defun agent-scheme--eval-set! (parts environment context)
  "Evaluate a set! expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 3)
    (agent-scheme--eval-error "set! requires an identifier and an expression"))
  (let ((name (agent-scheme--expect-symbol-name
               (cadr parts) "set! target"))
        (value (agent-scheme--eval-expression
                (caddr parts) environment context nil)))
    (agent-scheme--environment-set-cell environment name value)
    agent-scheme-unspecified))

(defun agent-scheme--eval-combination (expression environment context tailp)
  "Evaluate list EXPRESSION in ENVIRONMENT."
  (let ((parts (agent-scheme--proper-list-elements expression "expression")))
    (unless parts
      (agent-scheme--eval-error "empty list is not an expression"))
    (let ((operator (car parts)))
      (cond
       ((agent-scheme--symbol-named-p operator "quote")
        (unless (= (length parts) 2)
          (agent-scheme--eval-error "quote requires exactly one datum"))
        (agent-scheme--check-value-budget (cadr parts) context))
       ((agent-scheme--symbol-named-p operator "lambda")
        (unless (>= (length parts) 3)
          (agent-scheme--eval-error "lambda requires formals and a body"))
        (agent-scheme--make-procedure
         (agent-scheme--parse-formals (cadr parts))
         (cddr parts)
         environment))
       ((agent-scheme--symbol-named-p operator "if")
        (agent-scheme--eval-if parts environment context tailp))
       ((agent-scheme--symbol-named-p operator "set!")
        (agent-scheme--eval-set! parts environment context))
       ((agent-scheme--symbol-named-p operator "define")
        (agent-scheme--eval-error "define is not valid in expression position"))
       ((agent-scheme--symbol-named-p operator "begin")
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
   ((agent-scheme--self-evaluating-p expression)
    (agent-scheme--check-value-budget expression context))
   ((agent-scheme-symbol-p expression)
    (agent-scheme--environment-ref
     environment (agent-scheme-symbol-name expression)))
   ((null expression)
    (agent-scheme--eval-error "empty list is not an expression"))
   ((consp expression)
    (agent-scheme--eval-combination expression environment context tailp))
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
          (agent-scheme--make-bounce last-form environment))
         (t
          (setq value
                (agent-scheme--eval-expression
                 last-form environment context nil)))))))))

(defun agent-scheme--trampoline (expression environment context)
  "Evaluate EXPRESSION in ENVIRONMENT using CONTEXT's trampoline."
  (let ((state (agent-scheme--make-bounce expression environment)))
    (while (agent-scheme--bounce-p state)
      (setq state
            (agent-scheme--eval-expression
             (agent-scheme--bounce-expression state)
             (agent-scheme--bounce-environment state)
             context
             t)))
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

;;;###autoload
(defun agent-scheme-eval (expression &optional environment options)
  "Evaluate one Agent Scheme EXPRESSION datum.
ENVIRONMENT defaults to a fresh base environment.  OPTIONS is a
plist supporting `:max-steps', `:max-non-tail-steps',
`:max-value-nodes', and `:max-host-callbacks'."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
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
    (agent-scheme-datum->external value))))

(provide 'agent-scheme-eval)

;;; agent-scheme-eval.el ends here
