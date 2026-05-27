;;; agent-scheme-debugger.el --- Debugger condition records  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent debugger)' library represents runtime failures as
;; Scheme-readable condition records.  It keeps stack, environment, restart,
;; and event data inspectable without exposing raw host objects.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'subr-x)
(require 'agent-scheme-audit)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(defconst agent-scheme-debugger--maximum-frame-bindings 40
  "Maximum binding names included in one debugger environment frame.")

(defconst agent-scheme-debugger--buffer-name "*Agent Scheme Debugger*"
  "Name of the Agent Scheme debugger display buffer.")

(defvar agent-scheme-debugger-restart-action-function
  #'agent-scheme-debugger--default-restart-action
  "Function called to execute policy-gated debugger restarts.
The function receives the restart datum, condition datum, options datum, and
evaluation context.")

(defvar-local agent-scheme-debugger--condition nil
  "Debugger condition datum displayed in the current debugger buffer.")

(defvar-local agent-scheme-debugger--context nil
  "Evaluation context displayed in the current debugger buffer.")

(defvar-local agent-scheme-debugger--view nil
  "Debugger view datum displayed in the current debugger buffer.")

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

(defun agent-scheme-debugger--record-named-p (datum name)
  "Return non-nil when DATUM is a Scheme-readable record named NAME."
  (and (consp datum)
       (agent-scheme-symbol-p (car datum))
       (equal (agent-scheme-symbol-name (car datum)) name)))

(defun agent-scheme-debugger--symbol-name (datum)
  "Return DATUM's symbol name, or nil."
  (cond
   ((agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)))

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

(defun agent-scheme-debugger--documentation-datumize (value)
  "Return VALUE as a Scheme-readable documentation datum."
  (cond
   ((or (eq value agent-scheme-true)
        (eq value agent-scheme-false)
        (agent-scheme-symbol-p value)
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-bytevector-p value)
        (agent-scheme-record-p value)
        (agent-scheme-record-type-p value)
        (agent-scheme-handle-p value))
    value)
   ((eq value t)
    agent-scheme-true)
   ((null value)
    nil)
   ((symbolp value)
    (agent-scheme-debugger--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (agent-scheme--make-canonical-integer value))
   ((consp value)
    (cons (agent-scheme-debugger--documentation-datumize (car value))
          (agent-scheme-debugger--documentation-datumize (cdr value))))
   ((vectorp value)
    (vconcat
     (mapcar #'agent-scheme-debugger--documentation-datumize
             (append value nil))))
   (t
    (agent-scheme-value->external value))))

(defun agent-scheme-debugger--documentation-origin (documentation)
  "Return Scheme-readable origin data for DOCUMENTATION."
  (let ((origins
         (agent-scheme--documentation-metadata-origins documentation)))
    (cond
     ((null origins)
      (list (agent-scheme-debugger--symbol "signature")))
     ((equal origins '("implementation-procedure-string"))
      (list (agent-scheme-debugger--symbol "implementation-procedure")
            (agent-scheme-debugger--symbol "string")))
     ((equal origins '("primitive-manifest-string"))
      (list (agent-scheme-debugger--symbol "primitive-manifest")
            (agent-scheme-debugger--symbol "string")))
     (t
      (cons (agent-scheme-debugger--symbol "body-literal")
            (mapcar #'agent-scheme-debugger--symbol origins))))))

(defun agent-scheme-debugger--documentation-fields (documentation)
  "Return Scheme-readable field data for DOCUMENTATION."
  (mapcar
   (lambda (field)
     (list (agent-scheme-debugger--symbol (car field))
           (agent-scheme-debugger--documentation-datumize (cdr field))))
   (agent-scheme--documentation-metadata-fields documentation)))

(defun agent-scheme-debugger--documentation-metadata (documentation)
  "Return a procedure-value documentation metadata datum."
  (list
   (agent-scheme-debugger--symbol "documentation-metadata")
   (agent-scheme-debugger--field
    "subject" (list (agent-scheme-debugger--symbol "procedure")))
   (agent-scheme-debugger--field
    "kind" (agent-scheme-debugger--symbol "procedure"))
   (agent-scheme-debugger--field "library" agent-scheme-false)
   (agent-scheme-debugger--field "source" agent-scheme-false)
   (agent-scheme-debugger--field
    "origin" (agent-scheme-debugger--documentation-origin documentation))
   (agent-scheme-debugger--field
    "fields" (agent-scheme-debugger--documentation-fields documentation))))

(defun agent-scheme-debugger--procedure-documentation (value)
  "Return debugger documentation for compound procedure VALUE, or nil."
  (when (agent-scheme-procedure-p value)
    (let* ((documentation (agent-scheme-procedure-documentation value))
           (fields
            (and documentation
                 (agent-scheme--documentation-metadata-fields documentation))))
      (when (assoc "documentation" fields)
        (agent-scheme-redact
         (agent-scheme-debugger--documentation-metadata documentation)
         'debugger)))))

(defun agent-scheme-debugger--binding-record (name &optional cell)
  "Return a safe debugger binding record for NAME and optional CELL.
Debugger environment frames intentionally expose binding names rather than
binding values.  Values can contain closures, host handles, or large object
graphs that are unsuitable for the stable public result datum."
  (append
   (list
    (agent-scheme-debugger--symbol "binding")
    (agent-scheme-debugger--field
     "name" (agent-scheme-debugger--symbol name)))
   (when-let* ((value (and cell (agent-scheme--cell-value cell)))
               (documentation
                (agent-scheme-debugger--procedure-documentation value)))
     (list
      (agent-scheme-debugger--field
       "procedure-documentation" documentation)))))

(defun agent-scheme-debugger--binding-has-procedure-documentation-p (binding)
  "Return non-nil when BINDING carries debugger procedure documentation."
  (agent-scheme-debugger--field-value binding "procedure-documentation"))

(defun agent-scheme-debugger--binding-name< (left right)
  "Return non-nil when binding record LEFT sorts before RIGHT by name."
  (string<
   (or (agent-scheme-debugger--symbol-name
        (agent-scheme-debugger--field-value left "name"))
       "")
   (or (agent-scheme-debugger--symbol-name
        (agent-scheme-debugger--field-value right "name"))
       "")))

(defun agent-scheme-debugger--frame-bindings (environment)
  "Return safe current-frame bindings for ENVIRONMENT."
  (let (bindings)
    (when environment
      (maphash
       (lambda (name cell)
         (push (agent-scheme-debugger--binding-record name cell) bindings))
       (agent-scheme--environment-bindings environment)))
    (let* ((documented
            (sort
             (seq-filter
              #'agent-scheme-debugger--binding-has-procedure-documentation-p
              bindings)
             #'agent-scheme-debugger--binding-name<))
           (plain
            (sort
             (seq-remove
              #'agent-scheme-debugger--binding-has-procedure-documentation-p
              bindings)
             #'agent-scheme-debugger--binding-name<))
           (plain-limit
            (max 0
                 (- agent-scheme-debugger--maximum-frame-bindings
                    (length documented)))))
      (append documented (seq-take plain plain-limit)))))

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
   (agent-scheme-debugger--restart-record "retry" "retry" "debugger-recovery")
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

(defun agent-scheme-debugger--restart-records (condition)
  "Return restart records from CONDITION."
  (or (agent-scheme-debugger--field-value
       (agent-scheme-debugger--expect-condition condition "restart lookup")
       "restarts")
      nil))

(defun agent-scheme-debugger--restart-matches-id-p (restart id-name)
  "Return non-nil when RESTART has ID-NAME."
  (and (agent-scheme-debugger--record-named-p restart "restart")
       (equal (agent-scheme-debugger--id-name
               (agent-scheme-debugger--field-value restart "id"))
              id-name)))

(defun agent-scheme-debugger--restart-by-id (condition id)
  "Return restart ID from CONDITION or signal a debugger error."
  (let* ((id-name (agent-scheme-debugger--id-name id))
         (restart
          (seq-find
           (lambda (candidate)
             (agent-scheme-debugger--restart-matches-id-p candidate id-name))
           (agent-scheme-debugger--restart-records condition))))
    (or restart
        (signal 'agent-scheme-debugger-error
                (list (format "unknown debugger restart: %s" id-name))))))

(defun agent-scheme-debugger--restart-policy-category (restart)
  "Return RESTART's policy category as a host symbol."
  (intern
   (or (agent-scheme-debugger--symbol-name
        (agent-scheme-debugger--field-value restart "policy"))
       "debugger-recovery")))

(defun agent-scheme-debugger--restart-id-symbol (id)
  "Return ID as an Agent Scheme symbol datum."
  (agent-scheme-debugger--symbol (agent-scheme-debugger--id-name id)))

(defun agent-scheme-debugger--restart-result (id status options)
  "Return a Scheme-readable restart result datum."
  (list
   (agent-scheme-debugger--symbol "restart-result")
   (agent-scheme-debugger--field
    "id" (agent-scheme-debugger--restart-id-symbol id))
   (agent-scheme-debugger--field
    "status" (agent-scheme-debugger--symbol status))
   (agent-scheme-debugger--field "options" options)))

(defun agent-scheme-debugger--restart-event (id status &optional result)
  "Return a debugger restart event for ID with STATUS and optional RESULT."
  (append
   (list
    (agent-scheme-debugger--symbol "debugger-restart")
    (agent-scheme-debugger--field
     "id" (agent-scheme-debugger--restart-id-symbol id))
    (agent-scheme-debugger--field
     "status" (agent-scheme-debugger--symbol status)))
   (when result
     (list (agent-scheme-debugger--field "result" result)))))

(defun agent-scheme-debugger--record-restart-event!
    (context id status &optional result)
  "Record a debugger restart event in CONTEXT when available."
  (when (and context (agent-scheme--eval-context-p context))
    (agent-scheme--record-event!
     context
     (agent-scheme-debugger--restart-event id status result))))

(defun agent-scheme-debugger--restart-audit-fields (restart id options)
  "Return common audit fields for RESTART invocation."
  `((restart-id . ,(agent-scheme-debugger--restart-id-symbol id))
    (restart . ,restart)
    (options . ,options)))

(defun agent-scheme-debugger--default-restart-action
    (restart _condition _options _context)
  "Signal that RESTART has no concrete host action installed."
  (signal 'agent-scheme-debugger-error
          (list (format "no host action installed for debugger restart: %s"
                        (agent-scheme-debugger--id-name
                         (agent-scheme-debugger--field-value
                          restart "id"))))))

;;;###autoload
(defun agent-scheme-debugger-invoke-restart
    (condition restart-id options &optional context)
  "Invoke RESTART-ID from CONDITION with OPTIONS in optional CONTEXT.
`continue-with-warning' stays a direct portable restart path.  Other recovery
restarts are authorized through the policy category carried by their restart
datum before `agent-scheme-debugger-restart-action-function' is called."
  (let* ((condition-datum
          (agent-scheme-debugger--expect-condition
           condition "agent-scheme-debugger-invoke-restart"))
         (id-name (agent-scheme-debugger--id-name restart-id)))
    (cond
     ((equal id-name "continue-with-warning")
      (let ((result (agent-scheme-debugger--restart-result
                     id-name "continued" options)))
        (agent-scheme-debugger--record-restart-event!
         context id-name "continued" result)
        result))
     ((equal id-name "abort")
      (agent-scheme-debugger--record-restart-event!
       context id-name "aborted")
      (signal 'agent-scheme-debugger-error
              (list "debugger abort restart invoked")))
     (t
      (let* ((restart (agent-scheme-debugger--restart-by-id
                       condition-datum id-name))
             (category
              (agent-scheme-debugger--restart-policy-category restart))
             (fields
              (agent-scheme-debugger--restart-audit-fields
               restart id-name options)))
        (agent-scheme-policy-authorize
         category "debugger-restart" fields context 'debugger-restart)
        (condition-case error
            (let ((result
                   (funcall agent-scheme-debugger-restart-action-function
                            restart condition-datum options context)))
              (agent-scheme-debugger--record-restart-event!
               context id-name "completed" result)
              (agent-scheme-audit-record
               'debugger-restart
               (append
                `((category . ,category)
                  (operation . "debugger-restart")
                  (decision . completed))
                fields
                `((result . ,result))))
              result)
          (error
           (agent-scheme-debugger--record-restart-event!
            context id-name "failed")
           (agent-scheme-audit-record
            'debugger-restart
            (append
             `((category . ,category)
               (operation . "debugger-restart")
               (decision . failed)
               (reason . ,(error-message-string error)))
             fields))
           (signal (car error) (cdr error)))))))))

(defun agent-scheme-debugger--condition-summary (condition)
  "Return a compact Scheme-readable summary for CONDITION."
  (append
   (list
    (agent-scheme-debugger--symbol "condition-summary")
    (agent-scheme-debugger--field
     "type" (agent-scheme-debugger--field-value condition "type"))
    (agent-scheme-debugger--field
     "message" (agent-scheme-debugger--field-value condition "message"))
    (agent-scheme-debugger--field
     "phase" (agent-scheme-debugger--field-value condition "phase")))
   (when-let ((symbol (agent-scheme-debugger--field-value
                       condition "symbol")))
     (list (agent-scheme-debugger--field "symbol" symbol)))
   (when-let ((session (agent-scheme-debugger--field-value
                        condition "session")))
     (list (agent-scheme-debugger--field "session" session)))))

;;;###autoload
(defun agent-scheme-debugger-view-datum (condition &optional context)
  "Return an Emacs debugger view datum for CONDITION and optional CONTEXT."
  (let* ((condition-datum
          (agent-scheme-redact
           (agent-scheme-debugger--expect-condition
            condition "agent-scheme-debugger-view-datum")
           'debugger))
         (events
          (if (and context (agent-scheme--eval-context-p context))
              (mapcar
               (lambda (event)
                 (agent-scheme-redact event 'debugger))
               (agent-scheme--context-events context))
            nil)))
    (list
     (agent-scheme-debugger--symbol "debugger-view")
     (agent-scheme-debugger--field
      "summary" (agent-scheme-debugger--condition-summary condition-datum))
     (agent-scheme-debugger--field
      "stack" (agent-scheme-debugger--field-value condition-datum "stack"))
     (agent-scheme-debugger--field
      "environment"
      (agent-scheme-debugger--field-value condition-datum "environment"))
     (agent-scheme-debugger--field "events" events)
     (agent-scheme-debugger--field
      "restarts"
      (agent-scheme-debugger--field-value condition-datum "restarts")))))

(defun agent-scheme-debugger--insert-heading (heading)
  "Insert a debugger section HEADING."
  (insert heading "\n")
  (insert (make-string (length heading) ?-) "\n"))

(defun agent-scheme-debugger--view-field (view name)
  "Return field NAME from debugger VIEW."
  (agent-scheme-debugger--field-value view name))

(defun agent-scheme-debugger--insert-datum-lines (datum)
  "Insert DATUM as stable external Scheme text."
  (insert (agent-scheme-result->external datum) "\n\n"))

(defun agent-scheme-debugger--restart-label (restart)
  "Return a human-readable button label for RESTART."
  (format "%s  %s  policy: %s"
          (agent-scheme-debugger--id-name
           (agent-scheme-debugger--field-value restart "id"))
          (agent-scheme-debugger--id-name
           (agent-scheme-debugger--field-value restart "category"))
          (agent-scheme-debugger--id-name
           (agent-scheme-debugger--field-value restart "policy"))))

(defun agent-scheme-debugger--read-restart-options (restart)
  "Read option datums for RESTART using ordinary Emacs minibuffer prompts."
  (let ((category
         (agent-scheme-debugger--id-name
          (agent-scheme-debugger--field-value restart "category"))))
    (pcase category
      ("provide-value"
       (list (agent-scheme-debugger--field
              "value" (read-string "Debugger value: "))))
      ("define-binding"
       (list (agent-scheme-debugger--field
              "binding" (read-string "Binding name: "))
             (agent-scheme-debugger--field
              "value" (read-string "Binding value: "))))
      ("import-library"
       (list (agent-scheme-debugger--field
              "library" (read-string "Library name: "))))
      ("request-user-input"
       (list (agent-scheme-debugger--field
              "input" (read-string "Debugger input: "))))
      (_ nil))))

(defun agent-scheme-debugger--restart-button-action (button)
  "Invoke the debugger restart represented by BUTTON."
  (let* ((restart (button-get button 'agent-scheme-debugger-restart))
         (restart-id (button-get button 'agent-scheme-debugger-restart-id))
         (condition agent-scheme-debugger--condition)
         (context agent-scheme-debugger--context)
         (options (agent-scheme-debugger--read-restart-options restart))
         (result
          (agent-scheme-debugger-invoke-restart
           condition restart-id options context)))
    (message "Agent Scheme restart %s: %s"
             restart-id
             (agent-scheme-result->external result))
    result))

(defun agent-scheme-debugger--insert-restart-button (restart)
  "Insert an Emacs button for RESTART."
  (let ((id (agent-scheme-debugger--id-name
             (agent-scheme-debugger--field-value restart "id")))
        (start (point)))
    (insert-text-button
     (agent-scheme-debugger--restart-label restart)
     'action #'agent-scheme-debugger--restart-button-action
     'follow-link t
     'help-echo "Invoke Agent Scheme debugger restart"
     'agent-scheme-debugger-restart restart
     'agent-scheme-debugger-restart-id id)
    (add-text-properties
     start (point)
     (list 'agent-scheme-debugger-restart-id id
           'agent-scheme-debugger-restart restart))
    (insert "\n")))

(defun agent-scheme-debugger--render-buffer (condition context)
  "Render CONDITION and CONTEXT in the current debugger buffer."
  (let ((view (agent-scheme-debugger-view-datum condition context))
        (inhibit-read-only t))
    (setq agent-scheme-debugger--condition condition
          agent-scheme-debugger--context context
          agent-scheme-debugger--view view)
    (erase-buffer)
    (agent-scheme-debugger--insert-heading "Condition")
    (agent-scheme-debugger--insert-datum-lines
     (agent-scheme-debugger--view-field view "summary"))
    (agent-scheme-debugger--insert-heading "Stack Frames")
    (agent-scheme-debugger--insert-datum-lines
     (agent-scheme-debugger--view-field view "stack"))
    (agent-scheme-debugger--insert-heading "Environment")
    (agent-scheme-debugger--insert-datum-lines
     (agent-scheme-debugger--view-field view "environment"))
    (agent-scheme-debugger--insert-heading "Recent Events")
    (agent-scheme-debugger--insert-datum-lines
     (agent-scheme-debugger--view-field view "events"))
    (agent-scheme-debugger--insert-heading "Restart Choices")
    (dolist (restart (agent-scheme-debugger--view-field view "restarts"))
      (agent-scheme-debugger--insert-restart-button restart))
    (goto-char (point-min))))

(defvar agent-scheme-debugger-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'agent-scheme-debugger-activate-at-point)
    (define-key map (kbd "g") #'agent-scheme-debugger-refresh)
    map)
  "Keymap for `agent-scheme-debugger-mode'.")

;;;###autoload
(define-derived-mode agent-scheme-debugger-mode special-mode
  "Agent Scheme Debugger"
  "Major mode for Agent Scheme debugger buffers.")

;;;###autoload
(defun agent-scheme-debugger-refresh ()
  "Refresh the current Agent Scheme debugger buffer."
  (interactive)
  (unless agent-scheme-debugger--condition
    (user-error "No Agent Scheme debugger condition in this buffer"))
  (agent-scheme-debugger--render-buffer
   agent-scheme-debugger--condition
   agent-scheme-debugger--context))

;;;###autoload
(defun agent-scheme-debugger-activate-at-point ()
  "Invoke the restart button at point."
  (interactive)
  (if-let ((button (button-at (point))))
      (push-button (point))
    (user-error "No debugger restart at point")))

;;;###autoload
(defun agent-scheme-debugger-display (condition &optional context)
  "Display CONDITION and optional CONTEXT in an Emacs debugger buffer."
  (interactive
   (list (or (and (boundp 'agent-scheme-debugger--condition)
                  agent-scheme-debugger--condition)
             (user-error "No Agent Scheme debugger condition provided"))
         (and (boundp 'agent-scheme-debugger--context)
              agent-scheme-debugger--context)))
  (let ((buffer (get-buffer-create agent-scheme-debugger--buffer-name)))
    (with-current-buffer buffer
      (agent-scheme-debugger-mode)
      (agent-scheme-debugger--render-buffer condition context))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

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
    (arguments context)
  "Primitive restart-invoke! over ARGUMENTS."
  (let ((id (agent-scheme-debugger--id-name (car arguments)))
        (options (cadr arguments)))
    (cond
     ((equal id "continue-with-warning")
      (agent-scheme-debugger--restart-result id "continued" options))
     ((equal id "abort")
      (signal 'agent-scheme-debugger-error
              (list "debugger abort restart invoked")))
     (t
      (if-let ((condition (agent-scheme--eval-context-current-error context)))
          (agent-scheme-debugger-invoke-restart
           condition id options context)
        (signal 'agent-scheme-debugger-error
                (list (format "restart requires host debugger policy: %s"
                              id))))))))

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
