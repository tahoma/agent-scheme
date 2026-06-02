;;; consent-plan.el --- First-class planning records  -*- lexical-binding: t; -*-
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
(require 'consent-audit)
(require 'consent-memory)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)
(require 'consent-session)

(define-error 'consent-plan-error
  "Consent Scheme plan error"
  'consent-eval-error)

(defconst consent-plan-scopes
  '(fresh session project)
  "Public Consent Scheme plan scopes.")

(defconst consent-plan-statuses
  '(pending active blocked done cancelled failed)
  "Public Consent Scheme plan statuses.")

(defconst consent-plan-step-statuses
  '(pending active blocked done skipped cancelled failed)
  "Public Consent Scheme plan step statuses.")

(defvar consent--plan-fresh-records nil
  "Canonical fresh-scope plan records, newest first.")

(defvar consent--plan-session-records (make-hash-table :test #'equal)
  "Hash from session id to canonical session-scope plan records.")

(defvar consent--plan-project-records (make-hash-table :test #'equal)
  "Hash from project root to canonical project-scope plan records.")

(defvar consent--plan-next-id 0
  "Next plan record sequence number.")

(defvar-local consent--plan-buffer-scope nil
  "Plan scope represented by the current editable plan buffer.")

(defvar-local consent--plan-buffer-subject nil
  "Session id or project root represented by the current plan buffer.")

(define-derived-mode consent-plan-mode prog-mode "Agent Plans"
  "Major mode for editable Consent Scheme plan datum buffers.")

(defun consent--plan-name (value)
  "Return VALUE's stable symbolic name, or nil."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((keywordp value)
    (substring (symbol-name value) 1))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun consent--plan-symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (or (consent--plan-name name)
       (format "%S" name))))

(defun consent--plan-field (name value)
  "Return a Scheme-readable plan field named NAME with VALUE."
  (list (consent--plan-symbol name) value))

(defun consent--plan-integer (value)
  "Return VALUE as an exact integer datum."
  (consent--make-canonical-integer value))

(defun consent--plan-field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (equal (consent--plan-name (car field))
              (consent--plan-name name))))

(defun consent--plan-field-value (record name &optional default)
  "Return RECORD field NAME, or DEFAULT when absent."
  (let ((field
         (seq-find
          (lambda (candidate)
            (consent--plan-field-named-p candidate name))
          (cdr-safe record))))
    (if field (cadr field) default)))

(defun consent--plan-payload-fields (datum)
  "Return plan payload fields from DATUM."
  (cond
   ((and (consp datum)
         (equal (consent--plan-name (car datum)) "plan"))
    (cdr datum))
   ((listp datum)
    datum)
   (t
    (signal 'consent-plan-error
            (list "plan datum must be a plan record or field list")))))

(defun consent--plan-payload-field (datum name &optional default)
  "Return field NAME from DATUM, or DEFAULT when absent."
  (let ((field
         (seq-find
          (lambda (candidate)
            (consent--plan-field-named-p candidate name))
          (consent--plan-payload-fields datum))))
    (if field (cadr field) default)))

(defun consent--plan-datum-key (value description)
  "Return VALUE normalized for use as an id key."
  (cond
   ((or (consent-symbol-p value)
        (stringp value)
        (consent-number-p value))
    value)
   ((symbolp value)
    (consent--plan-symbol value))
   (value value)
   (t
    (signal 'consent-plan-error
            (list (format "%s is required" description))))))

(defun consent--plan-scope (scope)
  "Return normalized plan SCOPE or signal an error."
  (let* ((name (consent--plan-name scope))
         (normalized (and name (intern name))))
    (unless (memq normalized consent-plan-scopes)
      (signal 'consent-plan-error
              (list (format "unknown plan scope: %S" scope))))
    normalized))

(defun consent--plan-default-scope (context)
  "Return default plan scope for CONTEXT."
  (if (and context (consent--eval-context-session-id context))
      'session
    'fresh))

(defun consent--plan-status (status allowed description)
  "Return STATUS as a normalized public plan status."
  (let* ((name (consent--plan-name status))
         (normalized (and name (intern name))))
    (unless (memq normalized allowed)
      (signal 'consent-plan-error
              (list (format "unknown %s: %S" description status))))
    normalized))

(defun consent--plan-next-sequence ()
  "Return the next plan sequence number."
  (cl-incf consent--plan-next-id))

(defun consent--plan-generated-id (prefix sequence)
  "Return a generated plan symbol with PREFIX and SEQUENCE."
  (consent--plan-symbol (format "%s-%d" prefix sequence)))

(defun consent--plan-current-project-root ()
  "Return the active project root, or `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun consent--plan-project-key (&optional root)
  "Return canonical project key for ROOT or the current project."
  (file-name-as-directory
   (expand-file-name (or root (consent--plan-current-project-root)))))

(defun consent--plan-context-session-id (context subject)
  "Return active session id for CONTEXT and optional SUBJECT."
  (or (and subject (consent--plan-name subject))
      (and context (consent--eval-context-session-id context))
      (signal 'consent-plan-error
              (list "session plans require an active session"))))

(defun consent--plan-subject-key (scope context subject)
  "Return storage subject for SCOPE in CONTEXT."
  (pcase (consent--plan-scope scope)
    ('fresh 'fresh)
    ('session (consent--plan-context-session-id context subject))
    ('project
     (consent--plan-project-key
      (and subject (file-directory-p subject) subject)))))

(defun consent--plan-records (scope &optional context subject)
  "Return records for SCOPE in CONTEXT and optional SUBJECT."
  (pcase (consent--plan-scope scope)
    ('fresh consent--plan-fresh-records)
    ('session
     (gethash (consent--plan-subject-key 'session context subject)
              consent--plan-session-records))
    ('project
     (gethash (consent--plan-subject-key 'project context subject)
              consent--plan-project-records))))

(defun consent--plan-set-records! (scope records &optional context subject)
  "Replace records for SCOPE in CONTEXT and optional SUBJECT with RECORDS."
  (pcase (consent--plan-scope scope)
    ('fresh
     (setq consent--plan-fresh-records records))
    ('session
     (puthash (consent--plan-subject-key 'session context subject)
              records
              consent--plan-session-records))
    ('project
     (puthash (consent--plan-subject-key 'project context subject)
              records
              consent--plan-project-records))))

(defun consent--plan-find-by-id (records id)
  "Return plan record with ID from RECORDS."
  (seq-find
   (lambda (record)
     (equal (consent--plan-field-value record "id") id))
   records))

(defun consent--plan-replace-record (records record)
  "Return RECORDS with RECORD replacing any plan with the same id."
  (cons record
        (seq-remove
         (lambda (candidate)
           (equal (consent--plan-field-value candidate "id")
                  (consent--plan-field-value record "id")))
         records)))

(defun consent--plan-step-id (step)
  "Return STEP's id field."
  (consent--plan-payload-field step "id"))

(defun consent--plan-normalize-step (step &optional generated-id)
  "Return STEP in canonical field order."
  (let* ((fields (consent--plan-payload-fields step))
         (id (consent--plan-datum-key
              (or (consent--plan-payload-field fields "id")
                  generated-id)
              "plan step id"))
         (status (consent--plan-status
                  (or (consent--plan-payload-field fields "status")
                      'pending)
                  consent-plan-step-statuses
                  "plan step status"))
         (extras
          (seq-remove
           (lambda (field)
             (or (consent--plan-field-named-p field "id")
                 (consent--plan-field-named-p field "status")))
           fields)))
    (append
     (list
      (consent--plan-field "id" id)
      (consent--plan-field "status"
                                (consent--plan-symbol status)))
     extras)))

(defun consent--plan-normalize-steps (steps)
  "Return STEPS as a canonical proper list of step datums."
  (mapcar #'consent--plan-normalize-step
          (consent--proper-list-elements
           (or steps nil)
           "plan steps")))

(defun consent--plan-make-record (datum context &optional existing)
  "Return a canonical plan record for DATUM in CONTEXT.
When EXISTING is non-nil, preserve its id and creation sequence."
  (let* ((sequence (consent--plan-next-sequence))
         (id (or (consent--plan-payload-field datum "id")
                 (consent--plan-field-value existing "id")
                 (consent--plan-generated-id "p" sequence)))
         (scope (consent--plan-scope
                 (or (consent--plan-payload-field datum "scope")
                     (consent--plan-field-value existing "scope")
                     (consent--plan-default-scope context))))
         (status (consent--plan-status
                  (or (consent--plan-payload-field datum "status")
                      (consent--plan-field-value existing "status")
                      'pending)
                  consent-plan-statuses
                  "plan status"))
         (goal (or (consent--plan-payload-field datum "goal")
                   (consent--plan-field-value existing "goal")
                   ""))
         (steps (consent--plan-normalize-steps
                 (or (consent--plan-payload-field datum "steps")
                     (consent--plan-field-value existing "steps")
                     nil)))
         (created-at (or (consent--plan-field-value existing
                                                         "created-at")
                         (consent--plan-integer sequence))))
    (list
     (consent--plan-symbol "plan")
     (consent--plan-field "id"
                               (consent--plan-datum-key id "plan id"))
     (consent--plan-field "scope" (consent--plan-symbol scope))
     (consent--plan-field "status" (consent--plan-symbol status))
     (consent--plan-field "goal" goal)
     (consent--plan-field "steps" steps)
     (consent--plan-field "created-at" created-at)
     (consent--plan-field "updated-at"
                               (consent--plan-integer sequence)))))

(defun consent--plan-audit (operation record &optional fields)
  "Record plan OPERATION for RECORD with FIELDS."
  (consent-audit-record
   'agent-plan
   (append
    `((category . agent-plan)
      (operation . ,operation)
      (plan . ,(consent--plan-field-value record "id"))
      (scope . ,(intern (consent--plan-name
                         (consent--plan-field-value record "scope"))))
      (decision . completed))
    fields)))

(defun consent--plan-memory-important-p (datum)
  "Return non-nil when DATUM requests memory summarization."
  (let ((memory (consent--plan-payload-field datum "memory")))
    (member (consent--plan-name memory)
            '("important" "persist" "summary"))))

(defun consent--plan-memory-scope (scope)
  "Return memory scope corresponding to plan SCOPE."
  (pcase scope
    ('fresh 'instance)
    (_ scope)))

(defun consent--plan-maybe-write-memory! (datum record context)
  "Persist an important plan DATUM summary for RECORD when requested."
  (when (consent--plan-memory-important-p datum)
    (let* ((scope (intern (consent--plan-name
                           (consent--plan-field-value record "scope"))))
           (subject
            (pcase scope
              ('session (consent--plan-subject-key 'session context nil))
              ('project (consent--plan-subject-key 'project context nil))
              (_ nil))))
      (consent-memory-put!
       (consent--plan-memory-scope scope)
       (consent--plan-field-value record "id")
       (list
        (consent--plan-field "tags"
                                  (list (consent--plan-symbol "plan")
                                        (consent--plan-symbol
                                         "important")))
        (consent--plan-field "value" record)
        (consent--plan-field "source"
                                  (list (consent--plan-symbol
                                         "agent-plan")))
        (consent--plan-field "confidence"
                                  (consent--plan-symbol "high")))
       subject))))

;;;###autoload
(defun consent-plan-create! (datum &optional context)
  "Create or replace a plan from DATUM and return its canonical record."
  (let* ((existing-id (consent--plan-payload-field datum "id"))
         (scope (consent--plan-scope
                 (or (consent--plan-payload-field datum "scope")
                     (consent--plan-default-scope context))))
         (records (consent--plan-records scope context))
         (existing (and existing-id
                        (consent--plan-find-by-id records existing-id)))
         (redacted-datum (consent-redact datum 'agent-event))
         (record (consent--plan-make-record redacted-datum
                                                 context
                                                 existing)))
    (consent--plan-set-records!
     scope
     (consent--plan-replace-record records record)
     context)
    (consent--plan-maybe-write-memory! redacted-datum record context)
    (consent--plan-audit "plan-create!" record `((record . ,record)))
    record))

(defun consent--plan-locate (id &optional context)
  "Return (SCOPE SUBJECT RECORD) for plan ID in CONTEXT, or nil."
  (let ((normalized-id (consent--plan-datum-key id "plan id"))
        found)
    (dolist (scope '(fresh session project))
      (unless found
        (condition-case nil
            (let* ((subject
                    (pcase scope
                      ('fresh 'fresh)
                      ('session
                       (and context
                            (consent--eval-context-session-id context)))
                      ('project
                       (consent--plan-subject-key 'project context nil))))
                   (records
                    (and (or (not (eq scope 'session)) subject)
                         (consent--plan-records scope context subject)))
                   (record
                    (and records
                         (consent--plan-find-by-id records
                                                        normalized-id))))
              (when record
                (setq found (list scope subject record))))
          (consent-plan-error nil))))
    found))

;;;###autoload
(defun consent-plan-ref (id &optional context)
  "Return plan ID in CONTEXT, or nil when unknown."
  (caddr (consent--plan-locate id context)))

;;;###autoload
(defun consent-plan-list (scope &optional context subject)
  "Return known plans in SCOPE for CONTEXT and optional SUBJECT."
  (consent--plan-records scope context subject))

(defun consent--plan-store-updated (located record context)
  "Replace LOCATED plan with RECORD in CONTEXT and return RECORD."
  (let ((scope (car located))
        (subject (cadr located)))
    (consent--plan-set-records!
     scope
     (consent--plan-replace-record
      (consent--plan-records scope context subject)
      record)
     context
     subject)
    record))

(defun consent--plan-replace-field (record name value)
  "Return RECORD with field NAME replaced by VALUE."
  (let ((replaced nil))
    (cons
     (car record)
     (mapcar
      (lambda (field)
        (if (consent--plan-field-named-p field name)
            (progn
              (setq replaced t)
              (consent--plan-field name value))
          field))
      (cdr record)))))

(defun consent--plan-touch (record)
  "Return RECORD with a refreshed updated-at sequence."
  (consent--plan-replace-field
   record
   "updated-at"
   (consent--plan-integer (consent--plan-next-sequence))))

;;;###autoload
(defun consent-plan-step-add! (id step-datum &optional context)
  "Add STEP-DATUM to plan ID and return the updated plan."
  (let* ((located (or (consent--plan-locate id context)
                      (signal 'consent-plan-error
                              (list (format "unknown plan: %S" id)))))
         (record (caddr located))
         (step (consent--plan-normalize-step
                (consent-redact step-datum 'agent-event)
                (consent--plan-generated-id
                 "step"
                 (1+ consent--plan-next-id))))
         (steps (consent--plan-field-value record "steps"))
         (updated
          (consent--plan-touch
           (consent--plan-replace-field
            record "steps" (append steps (list step))))))
    (consent--plan-store-updated located updated context)
    (consent--plan-audit
     "plan-step-add!" updated
     `((step . ,(consent--plan-step-id step))
       (record . ,updated)))
    updated))

;;;###autoload
(defun consent-plan-step-status! (id step-id status &optional context)
  "Set plan ID step STEP-ID to STATUS and return the updated plan."
  (let* ((located (or (consent--plan-locate id context)
                      (signal 'consent-plan-error
                              (list (format "unknown plan: %S" id)))))
         (record (caddr located))
         (normalized-step-id
          (consent--plan-datum-key step-id "plan step id"))
         (normalized-status
          (consent--plan-status status
                                     consent-plan-step-statuses
                                     "plan step status"))
         (found nil)
         (steps
          (mapcar
           (lambda (step)
             (if (equal (consent--plan-step-id step)
                        normalized-step-id)
                 (progn
                   (setq found t)
                   (consent--plan-normalize-step
                    (consent--plan-replace-field
                     step "status"
                     (consent--plan-symbol normalized-status))))
               step))
           (consent--plan-field-value record "steps"))))
    (unless found
      (signal 'consent-plan-error
              (list (format "unknown plan step: %S" step-id))))
    (let ((updated
           (consent--plan-touch
            (consent--plan-replace-field record "steps" steps))))
      (consent--plan-store-updated located updated context)
      (consent--plan-audit
       "plan-step-status!" updated
       `((step . ,normalized-step-id)
         (status . ,normalized-status)
         (record . ,updated)))
      updated)))

;;;###autoload
(defun consent-plan-status! (id status &optional context)
  "Set plan ID to STATUS and return the updated plan."
  (let* ((located (or (consent--plan-locate id context)
                      (signal 'consent-plan-error
                              (list (format "unknown plan: %S" id)))))
         (record (caddr located))
         (normalized-status
          (consent--plan-status status
                                     consent-plan-statuses
                                     "plan status"))
         (updated
          (consent--plan-touch
           (consent--plan-replace-field
            record "status" (consent--plan-symbol normalized-status)))))
    (consent--plan-store-updated located updated context)
    (consent--plan-audit
     "plan-status!" updated
     `((status . ,normalized-status)
       (record . ,updated)))
    updated))

;;;###autoload
(defun consent-plan-yield (id context)
  "Yield plan ID through CONTEXT and return the plan."
  (let ((record (or (consent-plan-ref id context)
                    (signal 'consent-plan-error
                            (list (format "unknown plan: %S" id))))))
    (consent--record-event!
     context
     (list (consent--plan-symbol "yield") record))
    (consent--plan-audit "plan-yield" record)
    record))

;;;###autoload
(defun consent-plan-clear! (&optional scope subject)
  "Clear plan SCOPE and SUBJECT, or all plan state when SCOPE is nil."
  (if scope
      (pcase (consent--plan-scope scope)
        ('fresh
         (setq consent--plan-fresh-records nil))
        ('session
         (if subject
             (remhash (consent--plan-name subject)
                      consent--plan-session-records)
           (clrhash consent--plan-session-records)))
        ('project
         (if subject
             (remhash (consent--plan-project-key subject)
                      consent--plan-project-records)
           (clrhash consent--plan-project-records))))
    (setq consent--plan-fresh-records nil)
    (clrhash consent--plan-session-records)
    (clrhash consent--plan-project-records)
    (setq consent--plan-next-id 0))
  consent-unspecified)

;;;###autoload
(defun consent-plan-scope-datum (scope &optional subject)
  "Return SCOPE plans as an inspectable Scheme-readable datum."
  (let ((normalized-scope (consent--plan-scope scope)))
    (append
     (list
      (consent--plan-symbol "agent-plans")
      (consent--plan-field "scope"
                                (consent--plan-symbol
                                 normalized-scope)))
     (pcase normalized-scope
       ('session
        (list
         (consent--plan-field
          "session" (consent--plan-symbol
                     (consent--plan-context-session-id nil subject)))))
       ('project
        (list
         (consent--plan-field "project-root"
                                   (consent--plan-project-key subject))))
       (_ nil))
     (list
      (consent--plan-field
       "plans"
       (consent--plan-records normalized-scope nil subject))))))

(defun consent--plan-buffer-label (scope subject)
  "Return buffer label for SCOPE and SUBJECT."
  (pcase (consent--plan-scope scope)
    ('fresh "fresh")
    ('session
     (format "session: %s"
             (consent--plan-context-session-id nil subject)))
    ('project
     (format "project%s"
             (if subject
                 (format ": %s"
                         (file-name-nondirectory
                          (directory-file-name
                           (consent--plan-project-key subject))))
               "")))))

;;;###autoload
(defun consent-plan-open (scope &optional subject)
  "Open editable plan buffer for SCOPE and optional SUBJECT."
  (interactive
   (list (intern
          (completing-read "Plan scope: "
                           '("fresh" "session" "project")
                           nil t nil nil "project"))
         nil))
  (let* ((label (consent--plan-buffer-label scope subject))
         (buffer (get-buffer-create
                  (format "*Agent Plans: %s*" label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (consent-result->external
          (consent-plan-scope-datum scope subject)))
        (insert "\n"))
      (goto-char (point-min))
      (consent-plan-mode)
      (setq-local consent--plan-buffer-scope
                  (consent--plan-scope scope))
      (setq-local consent--plan-buffer-subject subject))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun consent--plan-scope-datum-records (datum)
  "Return plans field from scope DATUM."
  (or (consent--plan-field-value datum "plans")
      (signal 'consent-plan-error
              (list "plan buffer datum must contain plans"))))

;;;###autoload
(defun consent-plan-apply-buffer ()
  "Apply the current editable plan buffer back to its scoped store."
  (interactive)
  (let ((datum (consent-read (current-buffer)))
        (scope consent--plan-buffer-scope)
        (subject consent--plan-buffer-subject))
    (consent--plan-set-records!
     scope
     (consent--plan-scope-datum-records datum)
     nil
     subject)
    consent-unspecified))

(defun consent--plan-primitive-create (arguments context)
  "Primitive plan-create! over ARGUMENTS."
  (consent-plan-create! (car arguments) context))

(defun consent--plan-primitive-ref (arguments context)
  "Primitive plan-ref over ARGUMENTS."
  (or (consent-plan-ref (car arguments) context)
      consent-false))

(defun consent--plan-primitive-list (arguments context)
  "Primitive plan-list over ARGUMENTS."
  (consent-plan-list (car arguments) context))

(defun consent--plan-primitive-step-add (arguments context)
  "Primitive plan-step-add! over ARGUMENTS."
  (consent-plan-step-add! (car arguments) (cadr arguments) context))

(defun consent--plan-primitive-step-status (arguments context)
  "Primitive plan-step-status! over ARGUMENTS."
  (consent-plan-step-status!
   (car arguments) (cadr arguments) (caddr arguments) context))

(defun consent--plan-primitive-status (arguments context)
  "Primitive plan-status! over ARGUMENTS."
  (consent-plan-status! (car arguments) (cadr arguments) context))

(defun consent--plan-primitive-yield (arguments context)
  "Primitive plan-yield over ARGUMENTS."
  (consent-plan-yield (car arguments) context))

;;;###autoload
(defun consent-plan-primitive-specs ()
  "Return primitive specs for the `(agent plan)' library."
  `(("plan-create!" ,#'consent--plan-primitive-create 1 1)
    ("plan-ref" ,#'consent--plan-primitive-ref 1 1)
    ("plan-list" ,#'consent--plan-primitive-list 1 1)
    ("plan-step-add!" ,#'consent--plan-primitive-step-add 2 2)
    ("plan-step-status!" ,#'consent--plan-primitive-step-status 3 3)
    ("plan-status!" ,#'consent--plan-primitive-status 2 2)
    ("plan-yield" ,#'consent--plan-primitive-yield 1 1)))

(provide 'consent-plan)

;;; consent-plan.el ends here
