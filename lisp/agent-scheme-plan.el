;;; agent-scheme-plan.el --- First-class planning records  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent plan)' library stores agent plans as inspectable Scheme-readable
;; datums.  Host-side buffers and memory summaries are views over those records;
;; the records themselves remain the editable planning source of truth.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-audit)
(require 'agent-scheme-memory)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)
(require 'agent-scheme-session)

(define-error 'agent-scheme-plan-error
  "Agent Scheme plan error"
  'agent-scheme-eval-error)

(defconst agent-scheme-plan-scopes
  '(fresh session project)
  "Public Agent Scheme plan scopes.")

(defconst agent-scheme-plan-statuses
  '(pending active blocked done cancelled failed)
  "Public Agent Scheme plan statuses.")

(defconst agent-scheme-plan-step-statuses
  '(pending active blocked done skipped cancelled failed)
  "Public Agent Scheme plan step statuses.")

(defvar agent-scheme--plan-fresh-records nil
  "Canonical fresh-scope plan records, newest first.")

(defvar agent-scheme--plan-session-records (make-hash-table :test #'equal)
  "Hash from session id to canonical session-scope plan records.")

(defvar agent-scheme--plan-project-records (make-hash-table :test #'equal)
  "Hash from project root to canonical project-scope plan records.")

(defvar agent-scheme--plan-next-id 0
  "Next plan record sequence number.")

(defvar-local agent-scheme--plan-buffer-scope nil
  "Plan scope represented by the current editable plan buffer.")

(defvar-local agent-scheme--plan-buffer-subject nil
  "Session id or project root represented by the current plan buffer.")

(define-derived-mode agent-scheme-plan-mode prog-mode "Agent Plans"
  "Major mode for editable Agent Scheme plan datum buffers.")

(defun agent-scheme--plan-name (value)
  "Return VALUE's stable symbolic name, or nil."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((keywordp value)
    (substring (symbol-name value) 1))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun agent-scheme--plan-symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (or (agent-scheme--plan-name name)
       (format "%S" name))))

(defun agent-scheme--plan-field (name value)
  "Return a Scheme-readable plan field named NAME with VALUE."
  (list (agent-scheme--plan-symbol name) value))

(defun agent-scheme--plan-integer (value)
  "Return VALUE as an exact integer datum."
  (agent-scheme--make-canonical-integer value))

(defun agent-scheme--plan-field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (equal (agent-scheme--plan-name (car field))
              (agent-scheme--plan-name name))))

(defun agent-scheme--plan-field-value (record name &optional default)
  "Return RECORD field NAME, or DEFAULT when absent."
  (let ((field
         (seq-find
          (lambda (candidate)
            (agent-scheme--plan-field-named-p candidate name))
          (cdr-safe record))))
    (if field (cadr field) default)))

(defun agent-scheme--plan-payload-fields (datum)
  "Return plan payload fields from DATUM."
  (cond
   ((and (consp datum)
         (equal (agent-scheme--plan-name (car datum)) "plan"))
    (cdr datum))
   ((listp datum)
    datum)
   (t
    (signal 'agent-scheme-plan-error
            (list "plan datum must be a plan record or field list")))))

(defun agent-scheme--plan-payload-field (datum name &optional default)
  "Return field NAME from DATUM, or DEFAULT when absent."
  (let ((field
         (seq-find
          (lambda (candidate)
            (agent-scheme--plan-field-named-p candidate name))
          (agent-scheme--plan-payload-fields datum))))
    (if field (cadr field) default)))

(defun agent-scheme--plan-datum-key (value description)
  "Return VALUE normalized for use as an id key."
  (cond
   ((or (agent-scheme-symbol-p value)
        (stringp value)
        (agent-scheme-number-p value))
    value)
   ((symbolp value)
    (agent-scheme--plan-symbol value))
   (value value)
   (t
    (signal 'agent-scheme-plan-error
            (list (format "%s is required" description))))))

(defun agent-scheme--plan-scope (scope)
  "Return normalized plan SCOPE or signal an error."
  (let* ((name (agent-scheme--plan-name scope))
         (normalized (and name (intern name))))
    (unless (memq normalized agent-scheme-plan-scopes)
      (signal 'agent-scheme-plan-error
              (list (format "unknown plan scope: %S" scope))))
    normalized))

(defun agent-scheme--plan-default-scope (context)
  "Return default plan scope for CONTEXT."
  (if (and context (agent-scheme--eval-context-session-id context))
      'session
    'fresh))

(defun agent-scheme--plan-status (status allowed description)
  "Return STATUS as a normalized public plan status."
  (let* ((name (agent-scheme--plan-name status))
         (normalized (and name (intern name))))
    (unless (memq normalized allowed)
      (signal 'agent-scheme-plan-error
              (list (format "unknown %s: %S" description status))))
    normalized))

(defun agent-scheme--plan-next-sequence ()
  "Return the next plan sequence number."
  (cl-incf agent-scheme--plan-next-id))

(defun agent-scheme--plan-generated-id (prefix sequence)
  "Return a generated plan symbol with PREFIX and SEQUENCE."
  (agent-scheme--plan-symbol (format "%s-%d" prefix sequence)))

(defun agent-scheme--plan-current-project-root ()
  "Return the active project root, or `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun agent-scheme--plan-project-key (&optional root)
  "Return canonical project key for ROOT or the current project."
  (file-name-as-directory
   (expand-file-name (or root (agent-scheme--plan-current-project-root)))))

(defun agent-scheme--plan-context-session-id (context subject)
  "Return active session id for CONTEXT and optional SUBJECT."
  (or (and subject (agent-scheme--plan-name subject))
      (and context (agent-scheme--eval-context-session-id context))
      (signal 'agent-scheme-plan-error
              (list "session plans require an active session"))))

(defun agent-scheme--plan-subject-key (scope context subject)
  "Return storage subject for SCOPE in CONTEXT."
  (pcase (agent-scheme--plan-scope scope)
    ('fresh 'fresh)
    ('session (agent-scheme--plan-context-session-id context subject))
    ('project
     (agent-scheme--plan-project-key
      (and subject (file-directory-p subject) subject)))))

(defun agent-scheme--plan-records (scope &optional context subject)
  "Return records for SCOPE in CONTEXT and optional SUBJECT."
  (pcase (agent-scheme--plan-scope scope)
    ('fresh agent-scheme--plan-fresh-records)
    ('session
     (gethash (agent-scheme--plan-subject-key 'session context subject)
              agent-scheme--plan-session-records))
    ('project
     (gethash (agent-scheme--plan-subject-key 'project context subject)
              agent-scheme--plan-project-records))))

(defun agent-scheme--plan-set-records! (scope records &optional context subject)
  "Replace records for SCOPE in CONTEXT and optional SUBJECT with RECORDS."
  (pcase (agent-scheme--plan-scope scope)
    ('fresh
     (setq agent-scheme--plan-fresh-records records))
    ('session
     (puthash (agent-scheme--plan-subject-key 'session context subject)
              records
              agent-scheme--plan-session-records))
    ('project
     (puthash (agent-scheme--plan-subject-key 'project context subject)
              records
              agent-scheme--plan-project-records))))

(defun agent-scheme--plan-find-by-id (records id)
  "Return plan record with ID from RECORDS."
  (seq-find
   (lambda (record)
     (equal (agent-scheme--plan-field-value record "id") id))
   records))

(defun agent-scheme--plan-replace-record (records record)
  "Return RECORDS with RECORD replacing any plan with the same id."
  (cons record
        (seq-remove
         (lambda (candidate)
           (equal (agent-scheme--plan-field-value candidate "id")
                  (agent-scheme--plan-field-value record "id")))
         records)))

(defun agent-scheme--plan-step-id (step)
  "Return STEP's id field."
  (agent-scheme--plan-payload-field step "id"))

(defun agent-scheme--plan-normalize-step (step &optional generated-id)
  "Return STEP in canonical field order."
  (let* ((fields (agent-scheme--plan-payload-fields step))
         (id (agent-scheme--plan-datum-key
              (or (agent-scheme--plan-payload-field fields "id")
                  generated-id)
              "plan step id"))
         (status (agent-scheme--plan-status
                  (or (agent-scheme--plan-payload-field fields "status")
                      'pending)
                  agent-scheme-plan-step-statuses
                  "plan step status"))
         (extras
          (seq-remove
           (lambda (field)
             (or (agent-scheme--plan-field-named-p field "id")
                 (agent-scheme--plan-field-named-p field "status")))
           fields)))
    (append
     (list
      (agent-scheme--plan-field "id" id)
      (agent-scheme--plan-field "status"
                                (agent-scheme--plan-symbol status)))
     extras)))

(defun agent-scheme--plan-normalize-steps (steps)
  "Return STEPS as a canonical proper list of step datums."
  (mapcar #'agent-scheme--plan-normalize-step
          (agent-scheme--proper-list-elements
           (or steps nil)
           "plan steps")))

(defun agent-scheme--plan-make-record (datum context &optional existing)
  "Return a canonical plan record for DATUM in CONTEXT.
When EXISTING is non-nil, preserve its id and creation sequence."
  (let* ((sequence (agent-scheme--plan-next-sequence))
         (id (or (agent-scheme--plan-payload-field datum "id")
                 (agent-scheme--plan-field-value existing "id")
                 (agent-scheme--plan-generated-id "p" sequence)))
         (scope (agent-scheme--plan-scope
                 (or (agent-scheme--plan-payload-field datum "scope")
                     (agent-scheme--plan-field-value existing "scope")
                     (agent-scheme--plan-default-scope context))))
         (status (agent-scheme--plan-status
                  (or (agent-scheme--plan-payload-field datum "status")
                      (agent-scheme--plan-field-value existing "status")
                      'pending)
                  agent-scheme-plan-statuses
                  "plan status"))
         (goal (or (agent-scheme--plan-payload-field datum "goal")
                   (agent-scheme--plan-field-value existing "goal")
                   ""))
         (steps (agent-scheme--plan-normalize-steps
                 (or (agent-scheme--plan-payload-field datum "steps")
                     (agent-scheme--plan-field-value existing "steps")
                     nil)))
         (created-at (or (agent-scheme--plan-field-value existing
                                                         "created-at")
                         (agent-scheme--plan-integer sequence))))
    (list
     (agent-scheme--plan-symbol "plan")
     (agent-scheme--plan-field "id"
                               (agent-scheme--plan-datum-key id "plan id"))
     (agent-scheme--plan-field "scope" (agent-scheme--plan-symbol scope))
     (agent-scheme--plan-field "status" (agent-scheme--plan-symbol status))
     (agent-scheme--plan-field "goal" goal)
     (agent-scheme--plan-field "steps" steps)
     (agent-scheme--plan-field "created-at" created-at)
     (agent-scheme--plan-field "updated-at"
                               (agent-scheme--plan-integer sequence)))))

(defun agent-scheme--plan-audit (operation record &optional fields)
  "Record plan OPERATION for RECORD with FIELDS."
  (agent-scheme-audit-record
   'agent-plan
   (append
    `((category . agent-plan)
      (operation . ,operation)
      (plan . ,(agent-scheme--plan-field-value record "id"))
      (scope . ,(intern (agent-scheme--plan-name
                         (agent-scheme--plan-field-value record "scope"))))
      (decision . completed))
    fields)))

(defun agent-scheme--plan-memory-important-p (datum)
  "Return non-nil when DATUM requests memory summarization."
  (let ((memory (agent-scheme--plan-payload-field datum "memory")))
    (member (agent-scheme--plan-name memory)
            '("important" "persist" "summary"))))

(defun agent-scheme--plan-memory-scope (scope)
  "Return memory scope corresponding to plan SCOPE."
  (pcase scope
    ('fresh 'instance)
    (_ scope)))

(defun agent-scheme--plan-maybe-write-memory! (datum record context)
  "Persist an important plan DATUM summary for RECORD when requested."
  (when (agent-scheme--plan-memory-important-p datum)
    (let* ((scope (intern (agent-scheme--plan-name
                           (agent-scheme--plan-field-value record "scope"))))
           (subject
            (pcase scope
              ('session (agent-scheme--plan-subject-key 'session context nil))
              ('project (agent-scheme--plan-subject-key 'project context nil))
              (_ nil))))
      (agent-scheme-memory-put!
       (agent-scheme--plan-memory-scope scope)
       (agent-scheme--plan-field-value record "id")
       (list
        (agent-scheme--plan-field "tags"
                                  (list (agent-scheme--plan-symbol "plan")
                                        (agent-scheme--plan-symbol
                                         "important")))
        (agent-scheme--plan-field "value" record)
        (agent-scheme--plan-field "source"
                                  (list (agent-scheme--plan-symbol
                                         "agent-plan")))
        (agent-scheme--plan-field "confidence"
                                  (agent-scheme--plan-symbol "high")))
       subject))))

;;;###autoload
(defun agent-scheme-plan-create! (datum &optional context)
  "Create or replace a plan from DATUM and return its canonical record."
  (let* ((existing-id (agent-scheme--plan-payload-field datum "id"))
         (scope (agent-scheme--plan-scope
                 (or (agent-scheme--plan-payload-field datum "scope")
                     (agent-scheme--plan-default-scope context))))
         (records (agent-scheme--plan-records scope context))
         (existing (and existing-id
                        (agent-scheme--plan-find-by-id records existing-id)))
         (redacted-datum (agent-scheme-redact datum 'agent-event))
         (record (agent-scheme--plan-make-record redacted-datum
                                                 context
                                                 existing)))
    (agent-scheme--plan-set-records!
     scope
     (agent-scheme--plan-replace-record records record)
     context)
    (agent-scheme--plan-maybe-write-memory! redacted-datum record context)
    (agent-scheme--plan-audit "plan-create!" record `((record . ,record)))
    record))

(defun agent-scheme--plan-locate (id &optional context)
  "Return (SCOPE SUBJECT RECORD) for plan ID in CONTEXT, or nil."
  (let ((normalized-id (agent-scheme--plan-datum-key id "plan id"))
        found)
    (dolist (scope '(fresh session project))
      (unless found
        (condition-case nil
            (let* ((subject
                    (pcase scope
                      ('fresh 'fresh)
                      ('session
                       (and context
                            (agent-scheme--eval-context-session-id context)))
                      ('project
                       (agent-scheme--plan-subject-key 'project context nil))))
                   (records
                    (and (or (not (eq scope 'session)) subject)
                         (agent-scheme--plan-records scope context subject)))
                   (record
                    (and records
                         (agent-scheme--plan-find-by-id records
                                                        normalized-id))))
              (when record
                (setq found (list scope subject record))))
          (agent-scheme-plan-error nil))))
    found))

;;;###autoload
(defun agent-scheme-plan-ref (id &optional context)
  "Return plan ID in CONTEXT, or nil when unknown."
  (caddr (agent-scheme--plan-locate id context)))

;;;###autoload
(defun agent-scheme-plan-list (scope &optional context subject)
  "Return known plans in SCOPE for CONTEXT and optional SUBJECT."
  (agent-scheme--plan-records scope context subject))

(defun agent-scheme--plan-store-updated (located record context)
  "Replace LOCATED plan with RECORD in CONTEXT and return RECORD."
  (let ((scope (car located))
        (subject (cadr located)))
    (agent-scheme--plan-set-records!
     scope
     (agent-scheme--plan-replace-record
      (agent-scheme--plan-records scope context subject)
      record)
     context
     subject)
    record))

(defun agent-scheme--plan-replace-field (record name value)
  "Return RECORD with field NAME replaced by VALUE."
  (let ((replaced nil))
    (cons
     (car record)
     (mapcar
      (lambda (field)
        (if (agent-scheme--plan-field-named-p field name)
            (progn
              (setq replaced t)
              (agent-scheme--plan-field name value))
          field))
      (cdr record)))))

(defun agent-scheme--plan-touch (record)
  "Return RECORD with a refreshed updated-at sequence."
  (agent-scheme--plan-replace-field
   record
   "updated-at"
   (agent-scheme--plan-integer (agent-scheme--plan-next-sequence))))

;;;###autoload
(defun agent-scheme-plan-step-add! (id step-datum &optional context)
  "Add STEP-DATUM to plan ID and return the updated plan."
  (let* ((located (or (agent-scheme--plan-locate id context)
                      (signal 'agent-scheme-plan-error
                              (list (format "unknown plan: %S" id)))))
         (record (caddr located))
         (step (agent-scheme--plan-normalize-step
                (agent-scheme-redact step-datum 'agent-event)
                (agent-scheme--plan-generated-id
                 "step"
                 (1+ agent-scheme--plan-next-id))))
         (steps (agent-scheme--plan-field-value record "steps"))
         (updated
          (agent-scheme--plan-touch
           (agent-scheme--plan-replace-field
            record "steps" (append steps (list step))))))
    (agent-scheme--plan-store-updated located updated context)
    (agent-scheme--plan-audit
     "plan-step-add!" updated
     `((step . ,(agent-scheme--plan-step-id step))
       (record . ,updated)))
    updated))

;;;###autoload
(defun agent-scheme-plan-step-status! (id step-id status &optional context)
  "Set plan ID step STEP-ID to STATUS and return the updated plan."
  (let* ((located (or (agent-scheme--plan-locate id context)
                      (signal 'agent-scheme-plan-error
                              (list (format "unknown plan: %S" id)))))
         (record (caddr located))
         (normalized-step-id
          (agent-scheme--plan-datum-key step-id "plan step id"))
         (normalized-status
          (agent-scheme--plan-status status
                                     agent-scheme-plan-step-statuses
                                     "plan step status"))
         (found nil)
         (steps
          (mapcar
           (lambda (step)
             (if (equal (agent-scheme--plan-step-id step)
                        normalized-step-id)
                 (progn
                   (setq found t)
                   (agent-scheme--plan-normalize-step
                    (agent-scheme--plan-replace-field
                     step "status"
                     (agent-scheme--plan-symbol normalized-status))))
               step))
           (agent-scheme--plan-field-value record "steps"))))
    (unless found
      (signal 'agent-scheme-plan-error
              (list (format "unknown plan step: %S" step-id))))
    (let ((updated
           (agent-scheme--plan-touch
            (agent-scheme--plan-replace-field record "steps" steps))))
      (agent-scheme--plan-store-updated located updated context)
      (agent-scheme--plan-audit
       "plan-step-status!" updated
       `((step . ,normalized-step-id)
         (status . ,normalized-status)
         (record . ,updated)))
      updated)))

;;;###autoload
(defun agent-scheme-plan-status! (id status &optional context)
  "Set plan ID to STATUS and return the updated plan."
  (let* ((located (or (agent-scheme--plan-locate id context)
                      (signal 'agent-scheme-plan-error
                              (list (format "unknown plan: %S" id)))))
         (record (caddr located))
         (normalized-status
          (agent-scheme--plan-status status
                                     agent-scheme-plan-statuses
                                     "plan status"))
         (updated
          (agent-scheme--plan-touch
           (agent-scheme--plan-replace-field
            record "status" (agent-scheme--plan-symbol normalized-status)))))
    (agent-scheme--plan-store-updated located updated context)
    (agent-scheme--plan-audit
     "plan-status!" updated
     `((status . ,normalized-status)
       (record . ,updated)))
    updated))

;;;###autoload
(defun agent-scheme-plan-yield (id context)
  "Yield plan ID through CONTEXT and return the plan."
  (let ((record (or (agent-scheme-plan-ref id context)
                    (signal 'agent-scheme-plan-error
                            (list (format "unknown plan: %S" id))))))
    (agent-scheme--record-event!
     context
     (list (agent-scheme--plan-symbol "yield") record))
    (agent-scheme--plan-audit "plan-yield" record)
    record))

;;;###autoload
(defun agent-scheme-plan-clear! (&optional scope subject)
  "Clear plan SCOPE and SUBJECT, or all plan state when SCOPE is nil."
  (if scope
      (pcase (agent-scheme--plan-scope scope)
        ('fresh
         (setq agent-scheme--plan-fresh-records nil))
        ('session
         (if subject
             (remhash (agent-scheme--plan-name subject)
                      agent-scheme--plan-session-records)
           (clrhash agent-scheme--plan-session-records)))
        ('project
         (if subject
             (remhash (agent-scheme--plan-project-key subject)
                      agent-scheme--plan-project-records)
           (clrhash agent-scheme--plan-project-records))))
    (setq agent-scheme--plan-fresh-records nil)
    (clrhash agent-scheme--plan-session-records)
    (clrhash agent-scheme--plan-project-records)
    (setq agent-scheme--plan-next-id 0))
  agent-scheme-unspecified)

;;;###autoload
(defun agent-scheme-plan-scope-datum (scope &optional subject)
  "Return SCOPE plans as an inspectable Scheme-readable datum."
  (let ((normalized-scope (agent-scheme--plan-scope scope)))
    (append
     (list
      (agent-scheme--plan-symbol "agent-plans")
      (agent-scheme--plan-field "scope"
                                (agent-scheme--plan-symbol
                                 normalized-scope)))
     (pcase normalized-scope
       ('session
        (list
         (agent-scheme--plan-field
          "session" (agent-scheme--plan-symbol
                     (agent-scheme--plan-context-session-id nil subject)))))
       ('project
        (list
         (agent-scheme--plan-field "project-root"
                                   (agent-scheme--plan-project-key subject))))
       (_ nil))
     (list
      (agent-scheme--plan-field
       "plans"
       (agent-scheme--plan-records normalized-scope nil subject))))))

(defun agent-scheme--plan-buffer-label (scope subject)
  "Return buffer label for SCOPE and SUBJECT."
  (pcase (agent-scheme--plan-scope scope)
    ('fresh "fresh")
    ('session
     (format "session: %s"
             (agent-scheme--plan-context-session-id nil subject)))
    ('project
     (format "project%s"
             (if subject
                 (format ": %s"
                         (file-name-nondirectory
                          (directory-file-name
                           (agent-scheme--plan-project-key subject))))
               "")))))

;;;###autoload
(defun agent-scheme-plan-open (scope &optional subject)
  "Open editable plan buffer for SCOPE and optional SUBJECT."
  (interactive
   (list (intern
          (completing-read "Plan scope: "
                           '("fresh" "session" "project")
                           nil t nil nil "project"))
         nil))
  (let* ((label (agent-scheme--plan-buffer-label scope subject))
         (buffer (get-buffer-create
                  (format "*Agent Plans: %s*" label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (agent-scheme-result->external
          (agent-scheme-plan-scope-datum scope subject)))
        (insert "\n"))
      (goto-char (point-min))
      (agent-scheme-plan-mode)
      (setq-local agent-scheme--plan-buffer-scope
                  (agent-scheme--plan-scope scope))
      (setq-local agent-scheme--plan-buffer-subject subject))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun agent-scheme--plan-scope-datum-records (datum)
  "Return plans field from scope DATUM."
  (or (agent-scheme--plan-field-value datum "plans")
      (signal 'agent-scheme-plan-error
              (list "plan buffer datum must contain plans"))))

;;;###autoload
(defun agent-scheme-plan-apply-buffer ()
  "Apply the current editable plan buffer back to its scoped store."
  (interactive)
  (let ((datum (agent-scheme-read (current-buffer)))
        (scope agent-scheme--plan-buffer-scope)
        (subject agent-scheme--plan-buffer-subject))
    (agent-scheme--plan-set-records!
     scope
     (agent-scheme--plan-scope-datum-records datum)
     nil
     subject)
    agent-scheme-unspecified))

(defun agent-scheme--plan-primitive-create (arguments context)
  "Primitive plan-create! over ARGUMENTS."
  (agent-scheme-plan-create! (car arguments) context))

(defun agent-scheme--plan-primitive-ref (arguments context)
  "Primitive plan-ref over ARGUMENTS."
  (or (agent-scheme-plan-ref (car arguments) context)
      agent-scheme-false))

(defun agent-scheme--plan-primitive-list (arguments context)
  "Primitive plan-list over ARGUMENTS."
  (agent-scheme-plan-list (car arguments) context))

(defun agent-scheme--plan-primitive-step-add (arguments context)
  "Primitive plan-step-add! over ARGUMENTS."
  (agent-scheme-plan-step-add! (car arguments) (cadr arguments) context))

(defun agent-scheme--plan-primitive-step-status (arguments context)
  "Primitive plan-step-status! over ARGUMENTS."
  (agent-scheme-plan-step-status!
   (car arguments) (cadr arguments) (caddr arguments) context))

(defun agent-scheme--plan-primitive-status (arguments context)
  "Primitive plan-status! over ARGUMENTS."
  (agent-scheme-plan-status! (car arguments) (cadr arguments) context))

(defun agent-scheme--plan-primitive-yield (arguments context)
  "Primitive plan-yield over ARGUMENTS."
  (agent-scheme-plan-yield (car arguments) context))

;;;###autoload
(defun agent-scheme-plan-primitive-specs ()
  "Return primitive specs for the `(agent plan)' library."
  `(("plan-create!" ,#'agent-scheme--plan-primitive-create 1 1)
    ("plan-ref" ,#'agent-scheme--plan-primitive-ref 1 1)
    ("plan-list" ,#'agent-scheme--plan-primitive-list 1 1)
    ("plan-step-add!" ,#'agent-scheme--plan-primitive-step-add 2 2)
    ("plan-step-status!" ,#'agent-scheme--plan-primitive-step-status 3 3)
    ("plan-status!" ,#'agent-scheme--plan-primitive-status 2 2)
    ("plan-yield" ,#'agent-scheme--plan-primitive-yield 1 1)))

(provide 'agent-scheme-plan)

;;; agent-scheme-plan.el ends here
