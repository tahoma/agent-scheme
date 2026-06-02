;;; consent-debugger.el --- Debugger condition records  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent debugger)' library represents runtime failures as
;; Scheme-readable condition records.  It keeps stack, environment, restart,
;; and event data inspectable without exposing raw host objects.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-policy)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)

(defconst consent-debugger--maximum-frame-bindings 40
  "Maximum binding names included in one debugger environment frame.")

(defconst consent-debugger--buffer-name "*Consent Scheme Debugger*"
  "Name of the Consent Scheme debugger display buffer.")

(defvar consent-debugger-restart-action-function
  #'consent-debugger--default-restart-action
  "Function called to execute policy-gated debugger restarts.
The function receives the restart datum, condition datum, options datum, and
evaluation context.")

(defvar-local consent-debugger--condition nil
  "Debugger condition datum displayed in the current debugger buffer.")

(defvar-local consent-debugger--context nil
  "Evaluation context displayed in the current debugger buffer.")

(defvar-local consent-debugger--view nil
  "Debugger view datum displayed in the current debugger buffer.")

(define-error 'consent-debugger-error
  "Consent Scheme debugger error"
  'consent-eval-error)

(defun consent-debugger--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-debugger--field (name &rest values)
  "Return a Scheme-readable debugger field named NAME with VALUES."
  (cons (consent-debugger--symbol name) values))

(defun consent-debugger--field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (consent-symbol-p (car field))
       (equal (consent-symbol-name (car field)) name)))

(defun consent-debugger--field-values (datum name)
  "Return values for field NAME from debugger DATUM."
  (cdr
   (seq-find
    (lambda (field)
      (consent-debugger--field-named-p field name))
    (cdr-safe datum))))

(defun consent-debugger--field-value (datum name)
  "Return first value for field NAME from debugger DATUM."
  (car (consent-debugger--field-values datum name)))

(defun consent-debugger--record-named-p (datum name)
  "Return non-nil when DATUM is a Scheme-readable record named NAME."
  (and (consp datum)
       (consent-symbol-p (car datum))
       (equal (consent-symbol-name (car datum)) name)))

(defun consent-debugger--symbol-name (datum)
  "Return DATUM's symbol name, or nil."
  (cond
   ((consent-symbol-p datum)
    (consent-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)))

(defun consent-debugger--host-condition-message (condition)
  "Return CONDITION's raw message when possible."
  (cond
   ((and (consp condition) (stringp (cadr condition)))
    (cadr condition))
   ((consp condition)
    (error-message-string condition))
   (t
    (consent-value->external condition))))

(defun consent-debugger--condition-type (condition message)
  "Return a debugger condition type for CONDITION with MESSAGE."
  (cond
   ((and (consp condition) (eq (car condition) 'consent-budget-error))
    'budget-exhausted)
   ((and (consp condition) (eq (car condition) 'consent-policy-error))
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

(defun consent-debugger--condition-symbol (message)
  "Return an unbound symbol mentioned by MESSAGE, or nil."
  (when (string-match
         "\\bunbound identifier\\(?: in set!\\)?: \\([^\"[:space:])]+\\)"
         message)
    (consent-debugger--symbol (match-string 1 message))))

(defun consent-debugger--safe-value (value)
  "Return a redacted printable representation of VALUE."
  (consent-redact (consent-value->external value) 'debugger))

(defun consent-debugger--documentation-datumize (value)
  "Return VALUE as a Scheme-readable documentation datum."
  (cond
   ((or (eq value consent-true)
        (eq value consent-false)
        (consent-symbol-p value)
        (consent-character-p value)
        (consent-number-p value)
        (consent-bytevector-p value)
        (consent-record-p value)
        (consent-record-type-p value)
        (consent-handle-p value))
    value)
   ((eq value t)
    consent-true)
   ((null value)
    nil)
   ((symbolp value)
    (consent-debugger--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (consent--make-canonical-integer value))
   ((consp value)
    (cons (consent-debugger--documentation-datumize (car value))
          (consent-debugger--documentation-datumize (cdr value))))
   ((vectorp value)
    (vconcat
     (mapcar #'consent-debugger--documentation-datumize
             (append value nil))))
   (t
    (consent-value->external value))))

(defun consent-debugger--documentation-origin (documentation)
  "Return Scheme-readable origin data for DOCUMENTATION."
  (let ((origins
         (consent--documentation-metadata-origins documentation)))
    (cond
     ((null origins)
      (list (consent-debugger--symbol "signature")))
     ((equal origins '("implementation-procedure-string"))
      (list (consent-debugger--symbol "implementation-procedure")
            (consent-debugger--symbol "string")))
     ((equal origins '("primitive-manifest-string"))
      (list (consent-debugger--symbol "primitive-manifest")
            (consent-debugger--symbol "string")))
     (t
      (cons (consent-debugger--symbol "body-literal")
            (mapcar #'consent-debugger--symbol origins))))))

(defun consent-debugger--documentation-fields (documentation)
  "Return Scheme-readable field data for DOCUMENTATION."
  (mapcar
   (lambda (field)
     (list (consent-debugger--symbol (car field))
           (consent-debugger--documentation-datumize (cdr field))))
   (consent--documentation-metadata-fields documentation)))

(defun consent-debugger--documentation-metadata (documentation)
  "Return a procedure-value documentation metadata datum."
  (list
   (consent-debugger--symbol "documentation-metadata")
   (consent-debugger--field
    "subject" (list (consent-debugger--symbol "procedure")))
   (consent-debugger--field
    "kind" (consent-debugger--symbol "procedure"))
   (consent-debugger--field "library" consent-false)
   (consent-debugger--field "source" consent-false)
   (consent-debugger--field
    "origin" (consent-debugger--documentation-origin documentation))
   (consent-debugger--field
    "fields" (consent-debugger--documentation-fields documentation))))

(defun consent-debugger--procedure-documentation (value)
  "Return debugger documentation for compound procedure VALUE, or nil."
  (when (consent-procedure-p value)
    (let* ((documentation (consent-procedure-documentation value))
           (fields
            (and documentation
                 (consent--documentation-metadata-fields documentation))))
      (when (assoc "documentation" fields)
        (consent-redact
         (consent-debugger--documentation-metadata documentation)
         'debugger)))))

(defun consent-debugger--binding-record (name &optional cell)
  "Return a safe debugger binding record for NAME and optional CELL.
Debugger environment frames intentionally expose binding names rather than
binding values.  Values can contain closures, host handles, or large object
graphs that are unsuitable for the stable public result datum."
  (append
   (list
    (consent-debugger--symbol "binding")
    (consent-debugger--field
     "name" (consent-debugger--symbol name)))
   (when-let* ((value (and cell (consent--cell-value cell)))
               (documentation
                (consent-debugger--procedure-documentation value)))
     (list
      (consent-debugger--field
       "procedure-documentation" documentation)))))

(defun consent-debugger--binding-has-procedure-documentation-p (binding)
  "Return non-nil when BINDING carries debugger procedure documentation."
  (consent-debugger--field-value binding "procedure-documentation"))

(defun consent-debugger--binding-name< (left right)
  "Return non-nil when binding record LEFT sorts before RIGHT by name."
  (string<
   (or (consent-debugger--symbol-name
        (consent-debugger--field-value left "name"))
       "")
   (or (consent-debugger--symbol-name
        (consent-debugger--field-value right "name"))
       "")))

(defun consent-debugger--frame-bindings (environment)
  "Return safe current-frame bindings for ENVIRONMENT."
  (let (bindings)
    (when environment
      (maphash
       (lambda (name cell)
         (push (consent-debugger--binding-record name cell) bindings))
       (consent--environment-bindings environment)))
    (let* ((documented
            (sort
             (seq-filter
              #'consent-debugger--binding-has-procedure-documentation-p
              bindings)
             #'consent-debugger--binding-name<))
           (plain
            (sort
             (seq-remove
              #'consent-debugger--binding-has-procedure-documentation-p
              bindings)
             #'consent-debugger--binding-name<))
           (plain-limit
            (max 0
                 (- consent-debugger--maximum-frame-bindings
                    (length documented)))))
      (append documented (seq-take plain plain-limit)))))

(defun consent-debugger--environment-frame (environment frame-id)
  "Return a safe debugger environment frame for ENVIRONMENT and FRAME-ID."
  (let* ((binding-count
          (if environment
              (hash-table-count
               (consent--environment-bindings environment))
            0))
         (truncated
          (> binding-count
             consent-debugger--maximum-frame-bindings)))
    (list
     (consent-debugger--field
      "frame" (consent-debugger--symbol frame-id))
     (consent-debugger--field
      "bindings" (consent-debugger--frame-bindings environment))
     (consent-debugger--field
      "truncated"
      (if truncated consent-true consent-false)))))

(defun consent-debugger--stack-frame (phase frame-id)
  "Return a debugger stack frame for PHASE and FRAME-ID."
  (list
   (consent-debugger--symbol "frame")
   (consent-debugger--field
    "id" (consent-debugger--symbol frame-id))
   (consent-debugger--field
    "phase" (consent-debugger--symbol phase))))

(defun consent-debugger--restart-record (id category policy)
  "Return a debugger restart record."
  (list
   (consent-debugger--symbol "restart")
   (consent-debugger--field
    "id" (consent-debugger--symbol id))
   (consent-debugger--field
    "category" (consent-debugger--symbol category))
   (consent-debugger--field
    "policy" (consent-debugger--symbol policy))
   (consent-debugger--field
    "status" (consent-debugger--symbol "available"))))

(defun consent-debugger-default-restarts ()
  "Return default debugger restart records."
  (list
   (consent-debugger--restart-record "abort" "abort" "pure-r7rs")
   (consent-debugger--restart-record "retry" "retry" "debugger-recovery")
   (consent-debugger--restart-record
    "provide-value" "provide-value" "debugger-recovery")
   (consent-debugger--restart-record
    "define-binding" "define-binding" "debugger-recovery")
   (consent-debugger--restart-record
    "import-library" "import-library" "debugger-recovery")
   (consent-debugger--restart-record
    "continue-with-warning" "continue-with-warning" "pure-r7rs")
   (consent-debugger--restart-record
    "request-user-input" "request-user-input" "approval-resolution")))

;;;###autoload
(defun consent-debugger-condition-datum
    (condition context &optional phase environment)
  "Return a Scheme-readable debugger condition for host CONDITION.
CONTEXT supplies session metadata and ENVIRONMENT supplies safe binding
inspection.  PHASE defaults to `evaluation'."
  (let* ((message (consent-debugger--host-condition-message condition))
         (type (consent-debugger--condition-type condition message))
         (frame-id "f-0")
         (phase-name (or phase 'evaluation))
         (environment-frame
          (consent-debugger--environment-frame
           (or environment
               (and context
                    (consent--eval-context-interaction-environment
                     context)))
           frame-id)))
    (append
     (list
      (consent-debugger--symbol "condition")
      (consent-debugger--field
       "type" (consent-debugger--symbol type))
      (consent-debugger--field "message" message)
      (consent-debugger--field
       "phase" (consent-debugger--symbol phase-name)))
     (when-let ((symbol (consent-debugger--condition-symbol message)))
       (list (consent-debugger--field "symbol" symbol)))
     (when-let ((session (and context
                              (consent--eval-context-session-id context))))
       (list
        (consent-debugger--field
         "session" (consent-debugger--symbol session))))
     (list
      (consent-debugger--field
       "stack"
       (list (consent-debugger--stack-frame phase-name frame-id)))
      (consent-debugger--field
       "environment"
       environment-frame)
      (consent-debugger--field
       "restarts" (consent-debugger-default-restarts))))))

;;;###autoload
(defun consent-debugger-exception-datum
    (exception context &optional phase environment)
  "Return a debugger condition for a Scheme-raised EXCEPTION value."
  (let ((condition
         (list 'consent-eval-error
               (format "raised exception: %s"
                       (consent-value->external exception)))))
    (append
     (consent-debugger-condition-datum
      condition context (or phase 'evaluation) environment)
     (list
      (consent-debugger--field
       "value" (consent-debugger--safe-value exception))))))

(defun consent-debugger--condition-datum-p (datum)
  "Return non-nil when DATUM is a debugger condition datum."
  (and (consp datum)
       (consent-symbol-p (car datum))
       (equal (consent-symbol-name (car datum)) "condition")))

(defun consent-debugger--expect-condition (datum operation)
  "Return DATUM or signal when OPERATION expected a debugger condition."
  (unless (consent-debugger--condition-datum-p datum)
    (signal 'consent-debugger-error
            (list (format "%s expected a debugger condition" operation))))
  datum)

(defun consent-debugger--id-name (id)
  "Return restart ID as a stable string."
  (cond
   ((consent-symbol-p id)
    (consent-symbol-name id))
   ((symbolp id)
    (symbol-name id))
   ((stringp id)
    id)
   (t
    (signal 'consent-debugger-error
            (list "restart id must be a symbol or string")))))

(defun consent-debugger--restart-records (condition)
  "Return restart records from CONDITION."
  (or (consent-debugger--field-value
       (consent-debugger--expect-condition condition "restart lookup")
       "restarts")
      nil))

(defun consent-debugger--restart-matches-id-p (restart id-name)
  "Return non-nil when RESTART has ID-NAME."
  (and (consent-debugger--record-named-p restart "restart")
       (equal (consent-debugger--id-name
               (consent-debugger--field-value restart "id"))
              id-name)))

(defun consent-debugger--restart-by-id (condition id)
  "Return restart ID from CONDITION or signal a debugger error."
  (let* ((id-name (consent-debugger--id-name id))
         (restart
          (seq-find
           (lambda (candidate)
             (consent-debugger--restart-matches-id-p candidate id-name))
           (consent-debugger--restart-records condition))))
    (or restart
        (signal 'consent-debugger-error
                (list (format "unknown debugger restart: %s" id-name))))))

(defun consent-debugger--restart-policy-category (restart)
  "Return RESTART's policy category as a host symbol."
  (intern
   (or (consent-debugger--symbol-name
        (consent-debugger--field-value restart "policy"))
       "debugger-recovery")))

(defun consent-debugger--restart-id-symbol (id)
  "Return ID as an Consent Scheme symbol datum."
  (consent-debugger--symbol (consent-debugger--id-name id)))

(defun consent-debugger--restart-result (id status options)
  "Return a Scheme-readable restart result datum."
  (list
   (consent-debugger--symbol "restart-result")
   (consent-debugger--field
    "id" (consent-debugger--restart-id-symbol id))
   (consent-debugger--field
    "status" (consent-debugger--symbol status))
   (consent-debugger--field "options" options)))

(defun consent-debugger--restart-event (id status &optional result)
  "Return a debugger restart event for ID with STATUS and optional RESULT."
  (append
   (list
    (consent-debugger--symbol "debugger-restart")
    (consent-debugger--field
     "id" (consent-debugger--restart-id-symbol id))
    (consent-debugger--field
     "status" (consent-debugger--symbol status)))
   (when result
     (list (consent-debugger--field "result" result)))))

(defun consent-debugger--record-restart-event!
    (context id status &optional result)
  "Record a debugger restart event in CONTEXT when available."
  (when (and context (consent--eval-context-p context))
    (consent--record-event!
     context
     (consent-debugger--restart-event id status result))))

(defun consent-debugger--restart-audit-fields (restart id options)
  "Return common audit fields for RESTART invocation."
  `((restart-id . ,(consent-debugger--restart-id-symbol id))
    (restart . ,restart)
    (options . ,options)))

(defun consent-debugger--default-restart-action
    (restart _condition _options _context)
  "Signal that RESTART has no concrete host action installed."
  (signal 'consent-debugger-error
          (list (format "no host action installed for debugger restart: %s"
                        (consent-debugger--id-name
                         (consent-debugger--field-value
                          restart "id"))))))

;;;###autoload
(defun consent-debugger-invoke-restart
    (condition restart-id options &optional context)
  "Invoke RESTART-ID from CONDITION with OPTIONS in optional CONTEXT.
`continue-with-warning' stays a direct portable restart path.  Other recovery
restarts are authorized through the policy category carried by their restart
datum before `consent-debugger-restart-action-function' is called."
  (let* ((condition-datum
          (consent-debugger--expect-condition
           condition "consent-debugger-invoke-restart"))
         (id-name (consent-debugger--id-name restart-id)))
    (cond
     ((equal id-name "continue-with-warning")
      (let ((result (consent-debugger--restart-result
                     id-name "continued" options)))
        (consent-debugger--record-restart-event!
         context id-name "continued" result)
        result))
     ((equal id-name "abort")
      (consent-debugger--record-restart-event!
       context id-name "aborted")
      (signal 'consent-debugger-error
              (list "debugger abort restart invoked")))
     (t
      (let* ((restart (consent-debugger--restart-by-id
                       condition-datum id-name))
             (category
              (consent-debugger--restart-policy-category restart))
             (fields
              (consent-debugger--restart-audit-fields
               restart id-name options)))
        (consent-policy-authorize
         category "debugger-restart" fields context 'debugger-restart)
        (condition-case error
            (let ((result
                   (funcall consent-debugger-restart-action-function
                            restart condition-datum options context)))
              (consent-debugger--record-restart-event!
               context id-name "completed" result)
              (consent-audit-record
               'debugger-restart
               (append
                `((category . ,category)
                  (operation . "debugger-restart")
                  (decision . completed))
                fields
                `((result . ,result))))
              result)
          (error
           (consent-debugger--record-restart-event!
            context id-name "failed")
           (consent-audit-record
            'debugger-restart
            (append
             `((category . ,category)
               (operation . "debugger-restart")
               (decision . failed)
               (reason . ,(error-message-string error)))
             fields))
           (signal (car error) (cdr error)))))))))

(defun consent-debugger--condition-summary (condition)
  "Return a compact Scheme-readable summary for CONDITION."
  (append
   (list
    (consent-debugger--symbol "condition-summary")
    (consent-debugger--field
     "type" (consent-debugger--field-value condition "type"))
    (consent-debugger--field
     "message" (consent-debugger--field-value condition "message"))
    (consent-debugger--field
     "phase" (consent-debugger--field-value condition "phase")))
   (when-let ((symbol (consent-debugger--field-value
                       condition "symbol")))
     (list (consent-debugger--field "symbol" symbol)))
   (when-let ((session (consent-debugger--field-value
                        condition "session")))
     (list (consent-debugger--field "session" session)))))

;;;###autoload
(defun consent-debugger-view-datum (condition &optional context)
  "Return an Emacs debugger view datum for CONDITION and optional CONTEXT."
  (let* ((condition-datum
          (consent-redact
           (consent-debugger--expect-condition
            condition "consent-debugger-view-datum")
           'debugger))
         (events
          (if (and context (consent--eval-context-p context))
              (mapcar
               (lambda (event)
                 (consent-redact event 'debugger))
               (consent--context-events context))
            nil)))
    (list
     (consent-debugger--symbol "debugger-view")
     (consent-debugger--field
      "summary" (consent-debugger--condition-summary condition-datum))
     (consent-debugger--field
      "stack" (consent-debugger--field-value condition-datum "stack"))
     (consent-debugger--field
      "environment"
      (consent-debugger--field-value condition-datum "environment"))
     (consent-debugger--field "events" events)
     (consent-debugger--field
      "restarts"
      (consent-debugger--field-value condition-datum "restarts")))))

(defun consent-debugger--insert-heading (heading)
  "Insert a debugger section HEADING."
  (insert heading "\n")
  (insert (make-string (length heading) ?-) "\n"))

(defun consent-debugger--view-field (view name)
  "Return field NAME from debugger VIEW."
  (consent-debugger--field-value view name))

(defun consent-debugger--insert-datum-lines (datum)
  "Insert DATUM as stable external Scheme text."
  (insert (consent-result->external datum) "\n\n"))

(defun consent-debugger--restart-label (restart)
  "Return a human-readable button label for RESTART."
  (format "%s  %s  policy: %s"
          (consent-debugger--id-name
           (consent-debugger--field-value restart "id"))
          (consent-debugger--id-name
           (consent-debugger--field-value restart "category"))
          (consent-debugger--id-name
           (consent-debugger--field-value restart "policy"))))

(defun consent-debugger--read-restart-options (restart)
  "Read option datums for RESTART using ordinary Emacs minibuffer prompts."
  (let ((category
         (consent-debugger--id-name
          (consent-debugger--field-value restart "category"))))
    (pcase category
      ("provide-value"
       (list (consent-debugger--field
              "value" (read-string "Debugger value: "))))
      ("define-binding"
       (list (consent-debugger--field
              "binding" (read-string "Binding name: "))
             (consent-debugger--field
              "value" (read-string "Binding value: "))))
      ("import-library"
       (list (consent-debugger--field
              "library" (read-string "Library name: "))))
      ("request-user-input"
       (list (consent-debugger--field
              "input" (read-string "Debugger input: "))))
      (_ nil))))

(defun consent-debugger--restart-button-action (button)
  "Invoke the debugger restart represented by BUTTON."
  (let* ((restart (button-get button 'consent-debugger-restart))
         (restart-id (button-get button 'consent-debugger-restart-id))
         (condition consent-debugger--condition)
         (context consent-debugger--context)
         (options (consent-debugger--read-restart-options restart))
         (result
          (consent-debugger-invoke-restart
           condition restart-id options context)))
    (message "Consent Scheme restart %s: %s"
             restart-id
             (consent-result->external result))
    result))

(defun consent-debugger--insert-restart-button (restart)
  "Insert an Emacs button for RESTART."
  (let ((id (consent-debugger--id-name
             (consent-debugger--field-value restart "id")))
        (start (point)))
    (insert-text-button
     (consent-debugger--restart-label restart)
     'action #'consent-debugger--restart-button-action
     'follow-link t
     'help-echo "Invoke Consent Scheme debugger restart"
     'consent-debugger-restart restart
     'consent-debugger-restart-id id)
    (add-text-properties
     start (point)
     (list 'consent-debugger-restart-id id
           'consent-debugger-restart restart))
    (insert "\n")))

(defun consent-debugger--render-buffer (condition context)
  "Render CONDITION and CONTEXT in the current debugger buffer."
  (let ((view (consent-debugger-view-datum condition context))
        (inhibit-read-only t))
    (setq consent-debugger--condition condition
          consent-debugger--context context
          consent-debugger--view view)
    (erase-buffer)
    (consent-debugger--insert-heading "Condition")
    (consent-debugger--insert-datum-lines
     (consent-debugger--view-field view "summary"))
    (consent-debugger--insert-heading "Stack Frames")
    (consent-debugger--insert-datum-lines
     (consent-debugger--view-field view "stack"))
    (consent-debugger--insert-heading "Environment")
    (consent-debugger--insert-datum-lines
     (consent-debugger--view-field view "environment"))
    (consent-debugger--insert-heading "Recent Events")
    (consent-debugger--insert-datum-lines
     (consent-debugger--view-field view "events"))
    (consent-debugger--insert-heading "Restart Choices")
    (dolist (restart (consent-debugger--view-field view "restarts"))
      (consent-debugger--insert-restart-button restart))
    (goto-char (point-min))))

(defvar consent-debugger-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'consent-debugger-activate-at-point)
    (define-key map (kbd "g") #'consent-debugger-refresh)
    map)
  "Keymap for `consent-debugger-mode'.")

;;;###autoload
(define-derived-mode consent-debugger-mode special-mode
  "Consent Scheme Debugger"
  "Major mode for Consent Scheme debugger buffers.")

;;;###autoload
(defun consent-debugger-refresh ()
  "Refresh the current Consent Scheme debugger buffer."
  (interactive)
  (unless consent-debugger--condition
    (user-error "No Consent Scheme debugger condition in this buffer"))
  (consent-debugger--render-buffer
   consent-debugger--condition
   consent-debugger--context))

;;;###autoload
(defun consent-debugger-activate-at-point ()
  "Invoke the restart button at point."
  (interactive)
  (if-let ((button (button-at (point))))
      (push-button (point))
    (user-error "No debugger restart at point")))

;;;###autoload
(defun consent-debugger-display (condition &optional context)
  "Display CONDITION and optional CONTEXT in an Emacs debugger buffer."
  (interactive
   (list (or (and (boundp 'consent-debugger--condition)
                  consent-debugger--condition)
             (user-error "No Consent Scheme debugger condition provided"))
         (and (boundp 'consent-debugger--context)
              consent-debugger--context)))
  (let ((buffer (get-buffer-create consent-debugger--buffer-name)))
    (with-current-buffer buffer
      (consent-debugger-mode)
      (consent-debugger--render-buffer condition context))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun consent-debugger--primitive-current-error (_arguments context)
  "Primitive current-error over CONTEXT."
  (or (consent--eval-context-current-error context)
      consent-false))

(defun consent-debugger--primitive-condition-stack (arguments _context)
  "Primitive condition-stack over ARGUMENTS."
  (consent-debugger--field-value
   (consent-debugger--expect-condition
    (car arguments) "condition-stack")
   "stack"))

(defun consent-debugger--primitive-condition-environment
    (arguments _context)
  "Primitive condition-environment over ARGUMENTS."
  (let* ((condition
          (consent-debugger--expect-condition
           (car arguments) "condition-environment"))
         (frames (consent-debugger--field-values condition "environment"))
         (frame-id (cadr arguments)))
    (if (or (null frame-id) (eq frame-id consent-false))
        frames
      (let ((name (consent-debugger--id-name frame-id)))
        (or
         (seq-find
          (lambda (frame)
            (equal
             (consent-debugger--field-value frame "frame")
             (consent-debugger--symbol name)))
          frames)
         consent-false)))))

(defun consent-debugger--primitive-condition-restarts
    (arguments _context)
  "Primitive condition-restarts over ARGUMENTS."
  (consent-debugger--field-value
   (consent-debugger--expect-condition
    (car arguments) "condition-restarts")
   "restarts"))

(defun consent-debugger--primitive-restart-invoke!
    (arguments context)
  "Primitive restart-invoke! over ARGUMENTS."
  (let ((id (consent-debugger--id-name (car arguments)))
        (options (cadr arguments)))
    (cond
     ((equal id "continue-with-warning")
      (consent-debugger--restart-result id "continued" options))
     ((equal id "abort")
      (signal 'consent-debugger-error
              (list "debugger abort restart invoked")))
     (t
      (if-let ((condition (consent--eval-context-current-error context)))
          (consent-debugger-invoke-restart
           condition id options context)
        (signal 'consent-debugger-error
                (list (format "restart requires host debugger policy: %s"
                              id))))))))

(defun consent-debugger--primitive-debugger-yield
    (arguments context)
  "Primitive debugger-yield over ARGUMENTS."
  (let* ((condition (consent-redact (car arguments) 'debugger))
         (event (list (consent-debugger--symbol "debugger")
                      condition)))
    (consent--record-event! context event)
    (consent-audit-record
     'agent-event
     `((category . agent-debugger)
       (operation . "debugger-yield")
       (decision . recorded)
       (record . ,event)))
    consent-unspecified))

;;;###autoload
(defun consent-debugger-primitive-specs ()
  "Return primitive specs for the `(agent debugger)' library."
  `(("current-error" ,#'consent-debugger--primitive-current-error 0 0)
    ("condition-stack" ,#'consent-debugger--primitive-condition-stack 1 1)
    ("condition-environment"
     ,#'consent-debugger--primitive-condition-environment 2 2)
    ("condition-restarts"
     ,#'consent-debugger--primitive-condition-restarts 1 1)
    ("restart-invoke!" ,#'consent-debugger--primitive-restart-invoke! 2 2)
    ("debugger-yield" ,#'consent-debugger--primitive-debugger-yield 1 1)))

(provide 'consent-debugger)

;;; consent-debugger.el ends here
