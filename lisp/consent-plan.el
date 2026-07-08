;;; consent-plan.el --- First-class planning records  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The source-loaded `(agent plan)' library owns canonical plan store helpers.
;; This host adapter keeps Emacs session/project scoping, audit emission,
;; buffers, memory summaries, and the primitive bridge.

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

(declare-function consent--source-library-call "consent-library")

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

(defvar consent--plan-fresh-store nil
  "Source-backed fresh-scope plan store.")

(defvar consent--plan-session-stores (make-hash-table :test #'equal)
  "Hash from session id to source-backed plan stores.")

(defvar consent--plan-project-stores (make-hash-table :test #'equal)
  "Hash from project root to source-backed plan stores.")

(defvar-local consent--plan-buffer-scope nil
  "Plan scope represented by the current editable plan buffer.")

(defvar-local consent--plan-buffer-subject nil
  "Session id or project root represented by the current plan buffer.")

(define-derived-mode consent-plan-mode prog-mode "Consent Plans"
  "Major mode for editable Consent Scheme plan datum buffers.")

(defun consent--plan-source-call (name &rest arguments)
  "Call source-backed plan procedure NAME with ARGUMENTS."
  (unless (fboundp 'consent--source-library-call)
    (require 'consent-library))
  (apply #'consent--source-library-call
         "(agent plan)" name arguments))

(defun consent--plan-source-make-store (&optional records)
  "Return a source-backed plan store, optionally initialized with RECORDS."
  (let ((store (consent--plan-source-call
                "consent-make-plan-store")))
    (when records
      (consent--plan-source-call
       "plan-store-replace-records!" store records))
    store))

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

(defun consent--plan-source-scope (scope)
  "Return SCOPE as a source-library scope symbol."
  (consent--plan-symbol (consent--plan-scope scope)))

(defun consent--plan-session-store (context subject)
  "Return source-backed plan store for session CONTEXT or SUBJECT."
  (let* ((session-id (consent--plan-context-session-id context subject))
         (store (gethash session-id consent--plan-session-stores)))
    (unless store
      (setq store (consent--plan-source-make-store))
      (puthash session-id store consent--plan-session-stores))
    store))

(defun consent--plan-project-store (subject)
  "Return source-backed plan store for project SUBJECT."
  (let* ((project-key
          (consent--plan-project-key
           (and subject (file-directory-p subject) subject)))
         (store (gethash project-key consent--plan-project-stores)))
    (unless store
      (setq store (consent--plan-source-make-store))
      (puthash project-key store consent--plan-project-stores))
    store))

(defun consent--plan-store (scope &optional context subject)
  "Return source-backed plan store for SCOPE in CONTEXT and SUBJECT."
  (pcase (consent--plan-scope scope)
    ('fresh
     (or consent--plan-fresh-store
         (setq consent--plan-fresh-store
               (consent--plan-source-make-store))))
    ('session
     (consent--plan-session-store context subject))
    ('project
     (consent--plan-project-store subject))))

(defun consent--plan-records (scope &optional context subject)
  "Return records for SCOPE in CONTEXT and optional SUBJECT."
  (let ((normalized-scope (consent--plan-scope scope)))
    (consent--plan-source-call
     "plan-store-list"
     (consent--plan-store normalized-scope context subject)
     (consent--plan-source-scope normalized-scope))))

(defun consent--plan-set-records! (scope records &optional context subject)
  "Replace records for SCOPE in CONTEXT and optional SUBJECT with RECORDS."
  (consent--plan-source-call
   "plan-store-replace-records!"
   (consent--plan-store scope context subject)
   records))

(defun consent--plan-datum-with-default-scope (datum scope)
  "Return DATUM with SCOPE supplied when DATUM omits a scope field."
  (let ((fields (consent--plan-payload-fields datum)))
    (if (consent--plan-payload-field fields "scope")
        datum
      (append fields
              (list
               (consent--plan-field "scope"
                                    (consent--plan-source-scope scope)))))))

(defun consent--plan-record-steps (record)
  "Return RECORD's step list."
  (or (consent--plan-field-value record "steps") nil))

(defun consent--plan-last-step (record)
  "Return the last step in RECORD, or nil."
  (car (last (consent--plan-record-steps record))))

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
  (not
   (eq (consent--plan-source-call "plan-memory-important?" datum)
       consent-false)))

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
  (let* ((scope (consent--plan-scope
                 (or (consent--plan-payload-field datum "scope")
                     (consent--plan-default-scope context))))
         (redacted-datum (consent-redact datum 'context-event))
         (scoped-datum
          (consent--plan-datum-with-default-scope redacted-datum scope))
         (record
          (consent--plan-source-call
           "plan-store-create!"
           (consent--plan-store scope context)
           scoped-datum)))
    (consent--plan-maybe-write-memory! redacted-datum record context)
    (consent--plan-audit "plan-create!" record `((record . ,record)))
    record))

(defun consent--plan-locate (id &optional context)
  "Return (SCOPE SUBJECT STORE RECORD) for plan ID in CONTEXT, or nil."
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
                   (store
                    (and (or (not (eq scope 'session)) subject)
                         (consent--plan-store scope context subject)))
                   (record
                    (and store
                         (consent--plan-source-call
                          "plan-store-ref" store normalized-id))))
              (when (and record (not (eq record consent-false)))
                (setq found (list scope subject store record))))
          (consent-plan-error nil))))
    found))

;;;###autoload
(defun consent-plan-ref (id &optional context)
  "Return plan ID in CONTEXT, or nil when unknown."
  (cadddr (consent--plan-locate id context)))

;;;###autoload
(defun consent-plan-list (scope &optional context subject)
  "Return known plans in SCOPE for CONTEXT and optional SUBJECT."
  (consent--plan-records scope context subject))

;;;###autoload
(defun consent-plan-step-add! (id step-datum &optional context)
  "Add STEP-DATUM to plan ID and return the updated plan."
  (let* ((located (or (consent--plan-locate id context)
                      (signal 'consent-plan-error
                              (list (format "unknown plan: %S" id)))))
         (store (caddr located))
         (updated
          (consent--plan-source-call
           "plan-store-step-add!"
           store
           (consent--plan-datum-key id "plan id")
           (consent-redact step-datum 'context-event)))
         (step (consent--plan-last-step updated)))
    (consent--plan-audit
     "plan-step-add!" updated
     `((step . ,(consent--plan-field-value step "id"))
       (record . ,updated)))
    updated))

;;;###autoload
(defun consent-plan-step-status! (id step-id status &optional context)
  "Set plan ID step STEP-ID to STATUS and return the updated plan."
  (let* ((located (or (consent--plan-locate id context)
                      (signal 'consent-plan-error
                              (list (format "unknown plan: %S" id)))))
         (store (caddr located))
         (normalized-step-id
          (consent--plan-datum-key step-id "plan step id"))
         (updated
          (consent--plan-source-call
           "plan-store-step-status!"
           store
           (consent--plan-datum-key id "plan id")
           normalized-step-id
           (consent--plan-symbol status))))
    (consent--plan-audit
     "plan-step-status!" updated
     `((step . ,normalized-step-id)
       (status . ,(intern (consent--plan-name status)))
       (record . ,updated)))
    updated))

;;;###autoload
(defun consent-plan-status! (id status &optional context)
  "Set plan ID to STATUS and return the updated plan."
  (let* ((located (or (consent--plan-locate id context)
                      (signal 'consent-plan-error
                              (list (format "unknown plan: %S" id)))))
         (store (caddr located))
         (updated
          (consent--plan-source-call
           "plan-store-status!"
           store
           (consent--plan-datum-key id "plan id")
           (consent--plan-symbol status)))
         (normalized-status
          (intern (consent--plan-name
                   (consent--plan-field-value updated "status")))))
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
         (setq consent--plan-fresh-store nil))
        ('session
         (if subject
             (remhash (consent--plan-name subject)
                      consent--plan-session-stores)
           (clrhash consent--plan-session-stores)))
        ('project
         (if subject
             (remhash (consent--plan-project-key subject)
                      consent--plan-project-stores)
           (clrhash consent--plan-project-stores))))
    (setq consent--plan-fresh-store nil)
    (clrhash consent--plan-session-stores)
    (clrhash consent--plan-project-stores))
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
                  (format "*Consent Plans: %s*" label))))
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
