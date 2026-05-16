;;; agent-scheme-eval.el --- R7RS evaluator kernel  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small evaluator for Agent Scheme primitive expressions.  The evaluator
;; uses explicit lexical environments and a trampoline for tail calls; it never
;; delegates Scheme source to Emacs `eval'.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)

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

(defun agent-scheme--primitive- (arguments _context)
  "Primitive - over ARGUMENTS."
  (let ((numbers (agent-scheme--primitive-numbers arguments)))
    (agent-scheme--number-from-host
     (if (= (length numbers) 1)
         (- (car numbers))
       (apply #'- numbers)))))

(defun agent-scheme--primitive-compare (arguments predicate)
  "Return Scheme boolean for pairwise PREDICATE over ARGUMENTS."
  (let ((numbers (agent-scheme--primitive-numbers arguments))
        (ok t))
    (while (and ok (cdr numbers))
      (setq ok (funcall predicate (car numbers) (cadr numbers)))
      (setq numbers (cdr numbers)))
    (if ok agent-scheme-true agent-scheme-false)))

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

(defun agent-scheme--define-primitive
    (environment name function minimum-arity maximum-arity)
  "Register primitive NAME in ENVIRONMENT."
  (agent-scheme--environment-define
   environment
   name
   (agent-scheme--make-primitive-procedure
    name function minimum-arity maximum-arity)))

(defun agent-scheme-make-base-environment ()
  "Return a fresh environment with the evaluator kernel primitives."
  (let ((environment (agent-scheme-make-empty-environment)))
    (agent-scheme--define-primitive environment "+" #'agent-scheme--primitive+ 0 nil)
    (agent-scheme--define-primitive environment "*" #'agent-scheme--primitive* 0 nil)
    (agent-scheme--define-primitive environment "-" #'agent-scheme--primitive- 1 nil)
    (agent-scheme--define-primitive environment "=" #'agent-scheme--primitive= 2 nil)
    (agent-scheme--define-primitive environment "<" #'agent-scheme--primitive< 2 nil)
    (agent-scheme--define-primitive environment ">" #'agent-scheme--primitive> 2 nil)
    (agent-scheme--define-primitive environment "<=" #'agent-scheme--primitive<= 2 nil)
    (agent-scheme--define-primitive environment ">=" #'agent-scheme--primitive>= 2 nil)
    (agent-scheme--define-primitive environment "cons" #'agent-scheme--primitive-cons 2 2)
    (agent-scheme--define-primitive environment "car" #'agent-scheme--primitive-car 1 1)
    (agent-scheme--define-primitive environment "cdr" #'agent-scheme--primitive-cdr 1 1)
    (agent-scheme--define-primitive environment "list" #'agent-scheme--primitive-list 0 nil)
    (agent-scheme--define-primitive environment "null?" #'agent-scheme--primitive-null? 1 1)
    (agent-scheme--define-primitive environment "pair?" #'agent-scheme--primitive-pair? 1 1)
    (agent-scheme--define-primitive environment "not" #'agent-scheme--primitive-not 1 1)
    (agent-scheme--define-primitive environment "boolean?" #'agent-scheme--primitive-boolean? 1 1)
    (agent-scheme--define-primitive environment "number?" #'agent-scheme--primitive-number? 1 1)
    (agent-scheme--define-primitive environment "symbol?" #'agent-scheme--primitive-symbol? 1 1)
    (agent-scheme--define-primitive environment "procedure?" #'agent-scheme--primitive-procedure? 1 1)
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
