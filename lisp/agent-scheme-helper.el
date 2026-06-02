;;; agent-scheme-helper.el --- Reusable helper artifacts  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent helper)' library keeps reusable Scheme helper source and
;; related artifacts as Scheme-readable datums.  Session and private project
;; helpers stay out of tracked files by default; tracked helper and skill
;; candidate writes route through policy.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-audit)
(require 'agent-scheme-memory)
(require 'agent-scheme-policy)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(declare-function agent-scheme--drain-state "agent-scheme-interpreter")
(declare-function agent-scheme--eval-sequence "agent-scheme-interpreter")

(define-error 'agent-scheme-helper-error
  "Agent Scheme helper error"
  'agent-scheme-eval-error)

(defgroup agent-scheme-helper nil
  "Reusable helper libraries and artifacts for Agent Scheme."
  :group 'agent-scheme)

(defcustom agent-scheme-helper-directory
  (expand-file-name "agent-scheme/helpers/" user-emacs-directory)
  "Private-local directory for Agent Scheme helper persistence."
  :type 'directory
  :group 'agent-scheme-helper)

(defcustom agent-scheme-helper-project-tracked-directory
  ".agent-scheme/helpers/"
  "Project-relative directory used only for approved tracked helper files."
  :type 'string
  :group 'agent-scheme-helper)

(defvar agent-scheme--helper-session-records (make-hash-table :test #'equal)
  "Hash from session id to session helper records, newest first.")

(defvar agent-scheme--helper-project-private-records
  (make-hash-table :test #'equal)
  "Hash from project root to private project helper records, newest first.")

(defvar agent-scheme--helper-project-tracked-records
  (make-hash-table :test #'equal)
  "Hash from project root to tracked project helper records, newest first.")

(defvar agent-scheme--helper-session-artifacts (make-hash-table :test #'equal)
  "Hash from session id to session artifact records, newest first.")

(defvar agent-scheme--helper-project-private-artifacts
  (make-hash-table :test #'equal)
  "Hash from project root to private project artifact records, newest first.")

(defvar agent-scheme--helper-project-tracked-artifacts
  (make-hash-table :test #'equal)
  "Hash from project root to tracked project artifact records, newest first.")

(defvar agent-scheme--helper-next-id 0
  "Next helper/artifact sequence number.")

(defconst agent-scheme-helper-scopes
  '(session project-private project-tracked)
  "Recognized helper storage scopes.")

(defun agent-scheme-helper--symbol (name)
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

(defun agent-scheme-helper--field (name value)
  "Return a Scheme-readable helper field named NAME with VALUE."
  (list (agent-scheme-helper--symbol name) value))

(defun agent-scheme-helper--integer (value)
  "Return VALUE as an exact integer datum."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme-helper--next-sequence ()
  "Return the next helper sequence number."
  (cl-incf agent-scheme--helper-next-id))

(defun agent-scheme-helper--field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (agent-scheme-symbol-p (car field))
       (equal (agent-scheme-symbol-name (car field)) name)))

(defun agent-scheme-helper-record-field (record name)
  "Return field NAME from helper or artifact RECORD."
  (cadr
   (seq-find
    (lambda (field)
      (agent-scheme-helper--field-named-p field name))
    (cdr-safe record))))

(defun agent-scheme-helper--record-kind-p (record kind)
  "Return non-nil when RECORD starts with KIND."
  (and (consp record)
       (agent-scheme-symbol-p (car record))
       (equal (agent-scheme-symbol-name (car record)) kind)))

(defun agent-scheme-helper--option-key (key)
  "Return KEY normalized to an Emacs Lisp keyword."
  (intern
   (concat
    ":"
    (cond
     ((keywordp key)
      (substring (symbol-name key) 1))
     ((agent-scheme-symbol-p key)
      (agent-scheme-symbol-name key))
     ((symbolp key)
      (symbol-name key))
     ((stringp key)
      key)
     (t
      (format "%S" key))))))

(defun agent-scheme-helper--options-plist (options)
  "Return Scheme OPTIONS or host plist as an Emacs Lisp plist."
  (cond
   ((null options)
    nil)
   ((and (listp options)
         (cl-loop for (key _value) on options by #'cddr
                  always (keywordp key)))
    options)
   (t
    (let (plist)
      (dolist (entry (agent-scheme--proper-list-elements
                      options "helper options")
                     plist)
        (let ((elements (agent-scheme--proper-list-elements-maybe entry)))
          (cond
           ((and elements (= (length elements) 2))
            (setq plist
                  (plist-put plist
                             (agent-scheme-helper--option-key (car elements))
                             (cadr elements))))
           ((consp entry)
            (setq plist
                  (plist-put plist
                             (agent-scheme-helper--option-key (car entry))
                             (cdr entry))))
           (t
            (signal 'agent-scheme-helper-error
                    (list "helper option entries must be pairs"))))))))))

(defun agent-scheme-helper--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (let ((plist (agent-scheme-helper--options-plist options)))
    (if (plist-member plist key)
        (plist-get plist key)
      default)))

(defun agent-scheme-helper--scope (scope)
  "Return normalized helper SCOPE or signal."
  (let ((normalized
         (cond
          ((agent-scheme-symbol-p scope)
           (intern (agent-scheme-symbol-name scope)))
          ((symbolp scope)
           scope)
          ((stringp scope)
           (intern scope))
          (t nil))))
    (when (eq normalized 'project)
      (setq normalized 'project-private))
    (unless (memq normalized agent-scheme-helper-scopes)
      (signal 'agent-scheme-helper-error
              (list (format "unknown helper scope: %S" scope))))
    normalized))

(defun agent-scheme-helper--default-scope (context)
  "Return default helper scope for CONTEXT."
  (if (and context (agent-scheme--eval-context-session-id context))
      'session
    'project-private))

(defun agent-scheme-helper--scope-option (options context)
  "Return helper scope from OPTIONS or CONTEXT default."
  (agent-scheme-helper--scope
   (agent-scheme-helper--option
    options :scope (agent-scheme-helper--default-scope context))))

(defun agent-scheme-helper--current-project-root ()
  "Return the active project root, or `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun agent-scheme-helper--session-id (context)
  "Return current session id from CONTEXT, or signal."
  (or (and context (agent-scheme--eval-context-session-id context))
      (signal 'agent-scheme-helper-error
              (list "session helper scope requires an active session"))))

(defun agent-scheme-helper--subject-key (scope context)
  "Return storage subject key for SCOPE and CONTEXT."
  (pcase scope
    ('session
     (agent-scheme-helper--session-id context))
    ((or 'project-private 'project-tracked)
     (agent-scheme-helper--current-project-root))))

(defun agent-scheme-helper--records-table (scope artifacts)
  "Return table for SCOPE.  When ARTIFACTS is non-nil, use artifact tables."
  (pcase scope
    ('session
     (if artifacts
         agent-scheme--helper-session-artifacts
       agent-scheme--helper-session-records))
    ('project-private
     (if artifacts
         agent-scheme--helper-project-private-artifacts
       agent-scheme--helper-project-private-records))
    ('project-tracked
     (if artifacts
         agent-scheme--helper-project-tracked-artifacts
       agent-scheme--helper-project-tracked-records))))

(defun agent-scheme-helper--records (scope subject &optional artifacts)
  "Return records for SCOPE and SUBJECT."
  (gethash subject (agent-scheme-helper--records-table scope artifacts)))

(defun agent-scheme-helper--set-records! (scope subject records &optional artifacts)
  "Store RECORDS for SCOPE and SUBJECT."
  (puthash subject records (agent-scheme-helper--records-table scope artifacts)))

(defun agent-scheme-helper--valid-library-part-p (part)
  "Return non-nil if PART is valid in an R7RS library name."
  (or (agent-scheme-symbol-p part)
      (symbolp part)
      (and (agent-scheme-number-p part)
           (eq (agent-scheme-number-kind part) 'integer)
           (eq (agent-scheme-number-exactness part) 'exact)
           (>= (agent-scheme-number-value part) 0))
      (and (integerp part) (>= part 0))))

(defun agent-scheme-helper--library-part (part)
  "Return PART normalized for a Scheme-readable library name."
  (cond
   ((agent-scheme-symbol-p part)
    part)
   ((symbolp part)
    (agent-scheme-helper--symbol part))
   ((agent-scheme-number-p part)
    part)
   ((integerp part)
    (agent-scheme-helper--integer part))
   (t part)))

(defun agent-scheme-helper--library-name (name)
  "Return validated helper library NAME."
  (let ((normalized (agent-scheme--strip-identifiers name)))
    (unless (and (consp normalized)
                 (agent-scheme--proper-list-elements-maybe normalized)
                 (cl-every #'agent-scheme-helper--valid-library-part-p
                           (agent-scheme--proper-list-elements
                            normalized "helper library name")))
      (signal 'agent-scheme-helper-error
              (list (format "invalid helper library name: %s"
                            (format "%S" name)))))
    (mapcar #'agent-scheme-helper--library-part
            (agent-scheme--proper-list-elements normalized
                                                "helper library name"))))

(defun agent-scheme-helper--forms (forms)
  "Return validated helper FORMS as a proper list."
  (agent-scheme--proper-list-elements forms "helper forms"))

(defun agent-scheme-helper--name-key (library-name)
  "Return stable string key for LIBRARY-NAME."
  (agent-scheme-datum->external
   (agent-scheme--strip-identifiers
    (agent-scheme-helper--library-name library-name))))

(defun agent-scheme-helper--safe-path-component (part)
  "Return PART as a safe relative path component."
  (let* ((raw
          (cond
           ((agent-scheme-symbol-p part)
            (agent-scheme-symbol-name part))
           ((symbolp part)
            (symbol-name part))
           ((agent-scheme-number-p part)
            (number-to-string (agent-scheme-number-value part)))
           ((integerp part)
            (number-to-string part))
           (t
            (format "%S" part))))
         (sanitized
          (replace-regexp-in-string "[^[:alnum:]._+-]" "_" raw)))
    (if (string-empty-p sanitized) "_" sanitized)))

(defun agent-scheme-helper--library-relative-file (library-name)
  "Return relative helper source file path for LIBRARY-NAME."
  (mapconcat
   #'identity
   (append
    (mapcar #'agent-scheme-helper--safe-path-component
            (agent-scheme--proper-list-elements
             (agent-scheme-helper--library-name library-name)
             "helper library name"))
    nil)
   "/"))

(defun agent-scheme-helper--private-helper-file (library-name subject)
  "Return private-local helper file for LIBRARY-NAME and project SUBJECT."
  (expand-file-name
   (concat (agent-scheme-helper--library-relative-file library-name) ".scm")
   (expand-file-name
    (concat "projects/" (secure-hash 'sha1 subject) "/")
    agent-scheme-helper-directory)))

(defun agent-scheme-helper--tracked-helper-file (library-name subject)
  "Return project-tracked helper file for LIBRARY-NAME and project SUBJECT."
  (expand-file-name
   (concat (agent-scheme-helper--library-relative-file library-name) ".scm")
   (expand-file-name agent-scheme-helper-project-tracked-directory subject)))

(defun agent-scheme-helper--storage-file (scope library-name subject)
  "Return storage file for SCOPE, LIBRARY-NAME, and SUBJECT, or nil."
  (pcase scope
    ('project-private
     (agent-scheme-helper--private-helper-file library-name subject))
    ('project-tracked
     (agent-scheme-helper--tracked-helper-file library-name subject))
    (_ nil)))

(defun agent-scheme-helper--record-source (scope subject)
  "Return source datum for SCOPE and SUBJECT."
  (pcase scope
    ('session
     (list (agent-scheme-helper--symbol "session")
           (agent-scheme-helper--symbol subject)))
    ((or 'project-private 'project-tracked)
     (list (agent-scheme-helper--symbol "project-root") subject))))

(defun agent-scheme-helper--make-helper-record
    (scope subject library-name forms &optional existing)
  "Return canonical helper record for SCOPE, SUBJECT, LIBRARY-NAME, and FORMS."
  (let* ((sequence (agent-scheme-helper--next-sequence))
         (created-at (or (agent-scheme-helper-record-field existing "created-at")
                         (agent-scheme-helper--integer sequence))))
    (list
     (agent-scheme-helper--symbol "agent-helper-library")
     (agent-scheme-helper--field "name" (copy-tree library-name))
     (agent-scheme-helper--field "scope" (agent-scheme-helper--symbol scope))
     (agent-scheme-helper--field "forms" (copy-tree forms))
     (agent-scheme-helper--field
      "source"
      (agent-scheme-helper--record-source scope subject))
     (agent-scheme-helper--field "created-at" created-at)
     (agent-scheme-helper--field "updated-at"
                                 (agent-scheme-helper--integer sequence)))))

(defun agent-scheme-helper--make-artifact-record
    (scope subject name datum &optional existing)
  "Return canonical artifact record for SCOPE, SUBJECT, NAME, and DATUM."
  (let* ((sequence (agent-scheme-helper--next-sequence))
         (created-at (or (agent-scheme-helper-record-field existing "created-at")
                         (agent-scheme-helper--integer sequence))))
    (list
     (agent-scheme-helper--symbol "agent-artifact")
     (agent-scheme-helper--field "name" (copy-tree name))
     (agent-scheme-helper--field "scope" (agent-scheme-helper--symbol scope))
     (agent-scheme-helper--field "value" (copy-tree datum))
     (agent-scheme-helper--field
      "source"
      (agent-scheme-helper--record-source scope subject))
     (agent-scheme-helper--field "created-at" created-at)
     (agent-scheme-helper--field "updated-at"
                                 (agent-scheme-helper--integer sequence)))))

(defun agent-scheme-helper--replace-record (records record key-field key)
  "Return RECORDS with RECORD replacing a record whose KEY-FIELD is KEY."
  (cons record
        (seq-remove
         (lambda (candidate)
           (equal (agent-scheme-helper-record-field candidate key-field)
                  key))
         records)))

(defun agent-scheme-helper--find-record (records key-field key)
  "Return record from RECORDS whose KEY-FIELD is KEY."
  (seq-find
   (lambda (record)
     (equal (agent-scheme-helper-record-field record key-field) key))
   records))

(defun agent-scheme-helper--write-record-file (record file)
  "Write Scheme-readable RECORD to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (agent-scheme-result->external record))
    (insert "\n"))
  file)

(defun agent-scheme-helper--read-record-file (file)
  "Read one Scheme-readable helper record from FILE."
  (agent-scheme-read
   (with-temp-buffer
     (insert-file-contents file)
     (buffer-string))))

(defun agent-scheme-helper--maybe-load-file-record
    (scope subject library-name)
  "Load helper record for SCOPE, SUBJECT, and LIBRARY-NAME from disk if present."
  (when-let ((file (agent-scheme-helper--storage-file
                    scope library-name subject)))
    (when (file-readable-p file)
      (let ((record (agent-scheme-helper--read-record-file file)))
        (unless (agent-scheme-helper--record-kind-p
                 record "agent-helper-library")
          (signal 'agent-scheme-helper-error
                  (list (format "helper file does not contain a helper record: %s"
                                file))))
        (agent-scheme-helper--set-records!
         scope
         subject
         (agent-scheme-helper--replace-record
          (agent-scheme-helper--records scope subject)
          record
          "name"
          library-name))
        record))))

(defun agent-scheme-helper--audit (operation scope fields)
  "Record helper OPERATION for SCOPE with FIELDS."
  (agent-scheme-audit-record
   'agent-helper
   (append
    `((category . agent-helper)
      (operation . ,operation)
      (scope . ,scope)
      (decision . completed))
    fields)))

(defun agent-scheme-helper--memory-scope (scope)
  "Return memory scope corresponding to helper SCOPE."
  (pcase scope
    ('session 'session)
    (_ 'project)))

(defun agent-scheme-helper--memory-subject (scope subject)
  "Return memory subject for helper SCOPE and SUBJECT."
  (pcase scope
    ('session subject)
    (_ subject)))

(defun agent-scheme-helper--record-memory! (scope subject library-name record)
  "Record helper RECORD in `(agent memory)'."
  (agent-scheme-memory-put!
   (agent-scheme-helper--memory-scope scope)
   (copy-tree library-name)
   (list
    (agent-scheme-helper--field "tags"
                                (list (agent-scheme-helper--symbol "helper")
                                      (agent-scheme-helper--symbol "library")))
    (agent-scheme-helper--field "value" (copy-tree record))
    (agent-scheme-helper--field
     "source"
     (agent-scheme-helper--record-source scope subject))
    (agent-scheme-helper--field "confidence"
                                (agent-scheme-helper--symbol "high")))
   (agent-scheme-helper--memory-subject scope subject)))

;;;###autoload
(defun agent-scheme-helper-save!
    (library-name forms &optional options context)
  "Save helper FORMS as LIBRARY-NAME and return the helper record.
OPTIONS may include `:scope'.  Session helpers require CONTEXT with
an active session id.  Project-tracked helpers require policy approval."
  (let* ((scope (agent-scheme-helper--scope-option options context))
         (subject (agent-scheme-helper--subject-key scope context))
         (name (agent-scheme-helper--library-name library-name))
         (helper-forms (agent-scheme-redact
                        (agent-scheme-helper--forms forms)
                        'helper-source))
         (records (agent-scheme-helper--records scope subject))
         (existing (agent-scheme-helper--find-record records "name" name))
         (file (agent-scheme-helper--storage-file scope name subject)))
    (when (eq scope 'project-tracked)
      (agent-scheme-policy-authorize-helper-tracked-write
       name file context))
    (let ((record (agent-scheme-helper--make-helper-record
                   scope subject name helper-forms existing)))
      (agent-scheme-helper--set-records!
       scope
       subject
       (agent-scheme-helper--replace-record records record "name" name))
      (when file
        (agent-scheme-helper--write-record-file record file))
      (agent-scheme-helper--record-memory! scope subject name record)
      (agent-scheme-helper--audit
       "agent-helper-save!" scope
       `((library . ,name)
         (record . ,record)
         (storage-file . ,file)))
      record)))

;;;###autoload
(defun agent-scheme-helper-ref (library-name &optional options context)
  "Return helper LIBRARY-NAME record, or nil when absent."
  (let* ((scope (agent-scheme-helper--scope-option options context))
         (subject (agent-scheme-helper--subject-key scope context))
         (name (agent-scheme-helper--library-name library-name))
         (records (agent-scheme-helper--records scope subject)))
    (or (agent-scheme-helper--find-record records "name" name)
        (agent-scheme-helper--maybe-load-file-record scope subject name))))

;;;###autoload
(defun agent-scheme-helper-list (scope &optional context)
  "Return helper records in SCOPE."
  (let* ((normalized-scope (agent-scheme-helper--scope scope))
         (subject (agent-scheme-helper--subject-key normalized-scope context)))
    (agent-scheme-helper--records normalized-scope subject)))

;;;###autoload
(defun agent-scheme-helper-artifact!
    (name datum &optional options context)
  "Save artifact NAME with DATUM and yield it when CONTEXT is active."
  (let* ((scope (agent-scheme-helper--scope-option options context))
         (subject (agent-scheme-helper--subject-key scope context))
         (records (agent-scheme-helper--records scope subject t))
         (existing (agent-scheme-helper--find-record records "name" name))
         (record (agent-scheme-helper--make-artifact-record
                  scope
                  subject
                  name
                  (agent-scheme-redact datum 'helper-artifact)
                  existing)))
    (agent-scheme-helper--set-records!
     scope
     subject
     (agent-scheme-helper--replace-record records record "name" name)
     t)
    (agent-scheme-memory-add!
     (agent-scheme-helper--memory-scope scope)
     'artifact
     (list
      (agent-scheme-helper--field "tags"
                                  (list (agent-scheme-helper--symbol "helper")
                                        (agent-scheme-helper--symbol "artifact")))
      (agent-scheme-helper--field "value" record)
      (agent-scheme-helper--field
       "source"
       (agent-scheme-helper--record-source scope subject)))
     (agent-scheme-helper--memory-subject scope subject))
    (when context
      (agent-scheme--record-event!
       context
       (list (agent-scheme-helper--symbol "yield") record)))
    (agent-scheme-helper--audit
     "agent-artifact" scope
     `((artifact . ,name)
       (record . ,record)))
    record))

(defun agent-scheme-helper--candidate-name (library-name options)
  "Return skill candidate name for LIBRARY-NAME using OPTIONS."
  (or (agent-scheme-helper--option options :name nil)
      (mapconcat
       #'identity
       (mapcar
        #'agent-scheme-helper--safe-path-component
        (agent-scheme--proper-list-elements library-name "helper library name"))
       "-")))

(defun agent-scheme-helper--candidate-resources (options)
  "Return resource fields for skill candidate OPTIONS."
  (let ((examples (agent-scheme-helper--option options :examples nil))
        (references (agent-scheme-helper--option options :references nil))
        (tests (agent-scheme-helper--option options :tests nil))
        (resources (agent-scheme-helper--option options :resources nil)))
    (append
     (when examples
       (list (agent-scheme-helper--field "examples" examples)))
     (when references
       (list (agent-scheme-helper--field "references" references)))
     (when tests
       (list (agent-scheme-helper--field "tests" tests)))
     (when resources
       (list (agent-scheme-helper--field "resources" resources))))))

;;;###autoload
(defun agent-scheme-helper-promote-to-skill
    (helper-or-library &optional options context)
  "Return a skill candidate datum for HELPER-OR-LIBRARY.
HELPER-OR-LIBRARY may be a helper record or a library name."
  (let* ((helper-record
          (if (agent-scheme-helper--record-kind-p
               helper-or-library "agent-helper-library")
              helper-or-library
            (or (agent-scheme-helper-ref helper-or-library options context)
                (signal 'agent-scheme-helper-error
                        (list "unknown helper library")))))
         (library-name (agent-scheme-helper-record-field helper-record "name"))
         (candidate
          (append
           (list
            (agent-scheme-helper--symbol "agent-skill-candidate")
            (agent-scheme-helper--field
             "name"
             (agent-scheme-helper--candidate-name library-name options))
            (agent-scheme-helper--field "status"
                                        (agent-scheme-helper--symbol
                                         "candidate"))
            (agent-scheme-helper--field "source-library"
                                        (copy-tree library-name))
            (agent-scheme-helper--field "helper-library"
                                        (copy-tree helper-record)))
           (agent-scheme-helper--candidate-resources options)
           (list
            (agent-scheme-helper--field
             "skill-scm"
             (list
              (agent-scheme-helper--symbol "skill")
              (agent-scheme-helper--field
               "name"
               (agent-scheme-helper--candidate-name library-name options))
              (agent-scheme-helper--field
               "helper-libraries"
               (list (copy-tree library-name)))))))))
    (agent-scheme-helper--audit
     "agent-helper-promote-to-skill"
     (agent-scheme-helper--scope
      (agent-scheme-helper-record-field helper-record "scope"))
     `((library . ,library-name)
       (candidate . ,candidate)))
    candidate))

;;;###autoload
(defun agent-scheme-helper-export-skill-candidate!
    (candidate export-directory &optional context)
  "Write CANDIDATE as `SKILL.scm' under EXPORT-DIRECTORY after approval."
  (unless (agent-scheme-helper--record-kind-p
           candidate "agent-skill-candidate")
    (signal 'agent-scheme-helper-error
            (list "skill candidate export expects an agent-skill-candidate datum")))
  (let* ((name (agent-scheme-helper-record-field candidate "name"))
         (target-directory
          (file-name-as-directory (expand-file-name export-directory)))
         (target-file (expand-file-name "SKILL.scm" target-directory)))
    (agent-scheme-policy-authorize-helper-skill-candidate-write
     name target-file context)
    (make-directory target-directory t)
    (agent-scheme-helper--write-record-file candidate target-file)
    (agent-scheme-helper--audit
     "agent-helper-export-skill-candidate!" 'project-private
     `((candidate . ,name)
       (export-path . ,target-file)))
    (list
     (agent-scheme-helper--symbol "skill-candidate-export")
     (agent-scheme-helper--field "name" name)
     (agent-scheme-helper--field "export-path" target-file)
     (agent-scheme-helper--field "decision"
                                 (agent-scheme-helper--symbol "written")))))

(defun agent-scheme-helper--load-record (library-name options context)
  "Load helper LIBRARY-NAME according to OPTIONS and CONTEXT."
  (or (agent-scheme-helper-ref library-name options context)
      (signal 'agent-scheme-helper-error
              (list "unknown helper library"))))

(defun agent-scheme-helper--eval-record-forms (record context)
  "Evaluate helper RECORD forms in CONTEXT's interaction environment."
  (let ((environment
         (and context
              (agent-scheme--eval-context-interaction-environment context))))
    (unless environment
      (signal 'agent-scheme-helper-error
              (list "helper load requires an active evaluation environment")))
    (agent-scheme--drain-state
     (agent-scheme--eval-sequence
      (agent-scheme-helper-record-field record "forms")
      environment
      context
      t
      t)
     context))
  record)

(defun agent-scheme-helper--primitive-artifact (arguments context)
  "Primitive agent-artifact over ARGUMENTS."
  (agent-scheme-helper-artifact! (car arguments) (cadr arguments) nil context))

(defun agent-scheme-helper--primitive-save (arguments context)
  "Primitive agent-helper-save! over ARGUMENTS."
  (agent-scheme-helper-save!
   (car arguments)
   (cadr arguments)
   (caddr arguments)
   context))

(defun agent-scheme-helper--primitive-load (arguments context)
  "Primitive agent-helper-load over ARGUMENTS."
  (agent-scheme-helper--eval-record-forms
   (agent-scheme-helper--load-record
    (car arguments)
    (cadr arguments)
    context)
   context))

(defun agent-scheme-helper--primitive-list (arguments context)
  "Primitive agent-helper-list over ARGUMENTS."
  (agent-scheme-helper-list (car arguments) context))

(defun agent-scheme-helper--primitive-ref (arguments context)
  "Primitive agent-helper-ref over ARGUMENTS."
  (or (agent-scheme-helper-ref
       (car arguments)
       (cadr arguments)
       context)
      agent-scheme-false))

(defun agent-scheme-helper--primitive-promote (arguments context)
  "Primitive agent-helper-promote-to-skill over ARGUMENTS."
  (agent-scheme-helper-promote-to-skill
   (car arguments)
   (cadr arguments)
   context))

;;;###autoload
(defun agent-scheme-helper-primitive-specs ()
  "Return primitive specs for the `(agent helper)' library."
  `(("agent-artifact" ,#'agent-scheme-helper--primitive-artifact 2 2)
    ("agent-helper-save!" ,#'agent-scheme-helper--primitive-save 2 3)
    ("agent-helper-load" ,#'agent-scheme-helper--primitive-load 1 2)
    ("agent-helper-list" ,#'agent-scheme-helper--primitive-list 1 1)
    ("agent-helper-ref" ,#'agent-scheme-helper--primitive-ref 1 2)
    ("agent-helper-promote-to-skill"
     ,#'agent-scheme-helper--primitive-promote 1 2)))

;;;###autoload
(defun agent-scheme-helper-clear! ()
  "Clear in-memory helper and artifact state."
  (clrhash agent-scheme--helper-session-records)
  (clrhash agent-scheme--helper-project-private-records)
  (clrhash agent-scheme--helper-project-tracked-records)
  (clrhash agent-scheme--helper-session-artifacts)
  (clrhash agent-scheme--helper-project-private-artifacts)
  (clrhash agent-scheme--helper-project-tracked-artifacts)
  (setq agent-scheme--helper-next-id 0)
  agent-scheme-unspecified)

(provide 'agent-scheme-helper)

;;; agent-scheme-helper.el ends here
