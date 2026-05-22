;;; agent-scheme-debugger.el --- Debugger condition records  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent debugger)' library represents runtime failures as
;; Scheme-readable condition records.  It keeps stack, environment, restart,
;; and event data inspectable without exposing raw host objects.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(defconst agent-scheme-debugger--maximum-frame-bindings 40
  "Maximum binding names included in one debugger environment frame.")

(define-error 'agent-scheme-debugger-error
  "Agent Scheme debugger error"
  'agent-scheme-eval-error)

(defun agent-scheme-debugger--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-debugger--field (name &rest values)
  "Return a Scheme-readable debugger field named NAME with VALUES."
  (cons (agent-scheme-debugger--symbol name) values))

(defun agent-scheme-debugger--field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (agent-scheme-symbol-p (car field))
       (equal (agent-scheme-symbol-name (car field)) name)))

(defun agent-scheme-debugger--field-values (datum name)
  "Return values for field NAME from debugger DATUM."
  (cdr
   (seq-find
    (lambda (field)
      (agent-scheme-debugger--field-named-p field name))
    (cdr-safe datum))))

(defun agent-scheme-debugger--field-value (datum name)
  "Return first value for field NAME from debugger DATUM."
  (car (agent-scheme-debugger--field-values datum name)))

(defun agent-scheme-debugger--host-condition-message (condition)
  "Return CONDITION's raw message when possible."
  (cond
   ((and (consp condition) (stringp (cadr condition)))
    (cadr condition))
   ((consp condition)
    (error-message-string condition))
   (t
    (agent-scheme-value->external condition))))

(defun agent-scheme-debugger--condition-type (condition message)
  "Return a debugger condition type for CONDITION with MESSAGE."
  (cond
   ((and (consp condition) (eq (car condition) 'agent-scheme-budget-error))
    'budget-exhausted)
   ((and (consp condition) (eq (car condition) 'agent-scheme-policy-error))
    'policy-denial)
   ((string-match-p "\\bunbound identifier\\b" message)
    'unbound-variable)
   ((or (string-match-p "\\barity\\b" message)
        (string-match-p "expected .*arguments" message))
    'arity-error)
   ((string-match-p "syntax-error while expanding" message)
    'macro-expansion)
   ((or (string-match-p "\\bexpected\\b" message)
        (string-match-p "\\bmust be\\b" message))
    'type-error)
   (t
    'evaluation-error)))

(defun agent-scheme-debugger--condition-symbol (message)
  "Return an unbound symbol mentioned by MESSAGE, or nil."
  (when (string-match
         "\\bunbound identifier\\(?: in set!\\)?: \\([^\"[:space:])]+\\)"
         message)
    (agent-scheme-debugger--symbol (match-string 1 message))))

(defun agent-scheme-debugger--safe-value (value)
  "Return a redacted printable representation of VALUE."
  (agent-scheme-redact (agent-scheme-value->external value) 'debugger))

(defun agent-scheme-debugger--binding-record (name)
  "Return a safe debugger binding record for NAME.
Debugger environment frames intentionally expose binding names rather than
binding values.  Values can contain closures, host handles, or large object
graphs that are unsuitable for the stable public result datum."
  (list
   (agent-scheme-debugger--symbol "binding")
   (agent-scheme-debugger--field
    "name" (agent-scheme-debugger--symbol name))))

(defun agent-scheme-debugger--frame-bindings (environment)
  "Return safe current-frame bindings for ENVIRONMENT."
  (let (names)
    (when environment
      (maphash
       (lambda (name _cell)
         (push name names))
       (agent-scheme--environment-bindings environment)))
    (mapcar
     #'agent-scheme-debugger--binding-record
     (seq-take (sort names #'string<)
               agent-scheme-debugger--maximum-frame-bindings))))

(defun agent-scheme-debugger--environment-frame (environment frame-id)
  "Return a safe debugger environment frame for ENVIRONMENT and FRAME-ID."
  (let* ((binding-count
          (if environment
              (hash-table-count
               (agent-scheme--environment-bindings environment))
            0))
         (truncated
          (> binding-count
             agent-scheme-debugger--maximum-frame-bindings)))
    (list
     (agent-scheme-debugger--field
      "frame" (agent-scheme-debugger--symbol frame-id))
     (agent-scheme-debugger--field
      "bindings" (agent-scheme-debugger--frame-bindings environment))
     (agent-scheme-debugger--field
      "truncated"
      (if truncated agent-scheme-true agent-scheme-false)))))

(defun agent-scheme-debugger--stack-frame (phase frame-id)
  "Return a debugger stack frame for PHASE and FRAME-ID."
  (list
   (agent-scheme-debugger--symbol "frame")
   (agent-scheme-debugger--field
    "id" (agent-scheme-debugger--symbol frame-id))
   (agent-scheme-debugger--field
    "phase" (agent-scheme-debugger--symbol phase))))

(defun agent-scheme-debugger--restart-record (id category policy)
  "Return a debugger restart record."
  (list
   (agent-scheme-debugger--symbol "restart")
   (agent-scheme-debugger--field
    "id" (agent-scheme-debugger--symbol id))
   (agent-scheme-debugger--field
    "category" (agent-scheme-debugger--symbol category))
   (agent-scheme-debugger--field
    "policy" (agent-scheme-debugger--symbol policy))
   (agent-scheme-debugger--field
    "status" (agent-scheme-debugger--symbol "available"))))

(defun agent-scheme-debugger-default-restarts ()
  "Return default debugger restart records."
  (list
   (agent-scheme-debugger--restart-record "abort" "abort" "pure-r7rs")
   (agent-scheme-debugger--restart-record "retry" "retry" "pure-r7rs")
   (agent-scheme-debugger--restart-record
    "provide-value" "provide-value" "debugger-recovery")
   (agent-scheme-debugger--restart-record
    "define-binding" "define-binding" "debugger-recovery")
   (agent-scheme-debugger--restart-record
    "import-library" "import-library" "debugger-recovery")
   (agent-scheme-debugger--restart-record
    "continue-with-warning" "continue-with-warning" "pure-r7rs")
   (agent-scheme-debugger--restart-record
    "request-user-input" "request-user-input" "approval-resolution")))

;;;###autoload
(defun agent-scheme-debugger-condition-datum
    (condition context &optional phase environment)
  "Return a Scheme-readable debugger condition for host CONDITION.
CONTEXT supplies session metadata and ENVIRONMENT supplies safe binding
inspection.  PHASE defaults to `evaluation'."
  (let* ((message (agent-scheme-debugger--host-condition-message condition))
         (type (agent-scheme-debugger--condition-type condition message))
         (frame-id "f-0")
         (phase-name (or phase 'evaluation))
         (environment-frame
          (agent-scheme-debugger--environment-frame
           (or environment
               (and context
                    (agent-scheme--eval-context-interaction-environment
                     context)))
           frame-id)))
    (append
     (list
      (agent-scheme-debugger--symbol "condition")
      (agent-scheme-debugger--field
       "type" (agent-scheme-debugger--symbol type))
      (agent-scheme-debugger--field "message" message)
      (agent-scheme-debugger--field
       "phase" (agent-scheme-debugger--symbol phase-name)))
     (when-let ((symbol (agent-scheme-debugger--condition-symbol message)))
       (list (agent-scheme-debugger--field "symbol" symbol)))
     (when-let ((session (and context
                              (agent-scheme--eval-context-session-id context))))
       (list
        (agent-scheme-debugger--field
         "session" (agent-scheme-debugger--symbol session))))
     (list
      (agent-scheme-debugger--field
       "stack"
       (list (agent-scheme-debugger--stack-frame phase-name frame-id)))
      (agent-scheme-debugger--field
       "environment"
       environment-frame)
      (agent-scheme-debugger--field
       "restarts" (agent-scheme-debugger-default-restarts))))))

;;;###autoload
(defun agent-scheme-debugger-exception-datum
    (exception context &optional phase environment)
  "Return a debugger condition for a Scheme-raised EXCEPTION value."
  (let ((condition
         (list 'agent-scheme-eval-error
               (format "raised exception: %s"
                       (agent-scheme-value->external exception)))))
    (append
     (agent-scheme-debugger-condition-datum
      condition context (or phase 'evaluation) environment)
     (list
      (agent-scheme-debugger--field
       "value" (agent-scheme-debugger--safe-value exception))))))

(defun agent-scheme-debugger--condition-datum-p (datum)
  "Return non-nil when DATUM is a debugger condition datum."
  (and (consp datum)
       (agent-scheme-symbol-p (car datum))
       (equal (agent-scheme-symbol-name (car datum)) "condition")))

(defun agent-scheme-debugger--expect-condition (datum operation)
  "Return DATUM or signal when OPERATION expected a debugger condition."
  (unless (agent-scheme-debugger--condition-datum-p datum)
    (signal 'agent-scheme-debugger-error
            (list (format "%s expected a debugger condition" operation))))
  datum)

(defun agent-scheme-debugger--id-name (id)
  "Return restart ID as a stable string."
  (cond
   ((agent-scheme-symbol-p id)
    (agent-scheme-symbol-name id))
   ((symbolp id)
    (symbol-name id))
   ((stringp id)
    id)
   (t
    (signal 'agent-scheme-debugger-error
            (list "restart id must be a symbol or string")))))

(defun agent-scheme-debugger--primitive-current-error (_arguments context)
  "Primitive current-error over CONTEXT."
  (or (agent-scheme--eval-context-current-error context)
      agent-scheme-false))

(defun agent-scheme-debugger--primitive-condition-stack (arguments _context)
  "Primitive condition-stack over ARGUMENTS."
  (agent-scheme-debugger--field-value
   (agent-scheme-debugger--expect-condition
    (car arguments) "condition-stack")
   "stack"))

(defun agent-scheme-debugger--primitive-condition-environment
    (arguments _context)
  "Primitive condition-environment over ARGUMENTS."
  (let* ((condition
          (agent-scheme-debugger--expect-condition
           (car arguments) "condition-environment"))
         (frames (agent-scheme-debugger--field-values condition "environment"))
         (frame-id (cadr arguments)))
    (if (or (null frame-id) (eq frame-id agent-scheme-false))
        frames
      (let ((name (agent-scheme-debugger--id-name frame-id)))
        (or
         (seq-find
          (lambda (frame)
            (equal
             (agent-scheme-debugger--field-value frame "frame")
             (agent-scheme-debugger--symbol name)))
          frames)
         agent-scheme-false)))))

(defun agent-scheme-debugger--primitive-condition-restarts
    (arguments _context)
  "Primitive condition-restarts over ARGUMENTS."
  (agent-scheme-debugger--field-value
   (agent-scheme-debugger--expect-condition
    (car arguments) "condition-restarts")
   "restarts"))

(defun agent-scheme-debugger--primitive-restart-invoke!
    (arguments _context)
  "Primitive restart-invoke! over ARGUMENTS."
  (let ((id (agent-scheme-debugger--id-name (car arguments)))
        (options (cadr arguments)))
    (cond
     ((equal id "continue-with-warning")
      (list
       (agent-scheme-debugger--symbol "restart-result")
       (agent-scheme-debugger--field
        "id" (agent-scheme-debugger--symbol id))
       (agent-scheme-debugger--field
        "status" (agent-scheme-debugger--symbol "continued"))
       (agent-scheme-debugger--field "options" options)))
     ((equal id "abort")
      (signal 'agent-scheme-debugger-error
              (list "debugger abort restart invoked")))
     (t
      (signal 'agent-scheme-debugger-error
              (list (format "restart requires host debugger policy: %s"
                            id)))))))

(defun agent-scheme-debugger--primitive-debugger-yield
    (arguments context)
  "Primitive debugger-yield over ARGUMENTS."
  (let* ((condition (agent-scheme-redact (car arguments) 'debugger))
         (event (list (agent-scheme-debugger--symbol "debugger")
                      condition)))
    (agent-scheme--record-event! context event)
    (agent-scheme-audit-record
     'agent-event
     `((category . agent-debugger)
       (operation . "debugger-yield")
       (decision . recorded)
       (record . ,event)))
    agent-scheme-unspecified))

;;;###autoload
(defun agent-scheme-debugger-primitive-specs ()
  "Return primitive specs for the `(agent debugger)' library."
  `(("current-error" ,#'agent-scheme-debugger--primitive-current-error 0 0)
    ("condition-stack" ,#'agent-scheme-debugger--primitive-condition-stack 1 1)
    ("condition-environment"
     ,#'agent-scheme-debugger--primitive-condition-environment 2 2)
    ("condition-restarts"
     ,#'agent-scheme-debugger--primitive-condition-restarts 1 1)
    ("restart-invoke!" ,#'agent-scheme-debugger--primitive-restart-invoke! 2 2)
    ("debugger-yield" ,#'agent-scheme-debugger--primitive-debugger-yield 1 1)))

(provide 'agent-scheme-debugger)

;;; agent-scheme-debugger.el ends here
