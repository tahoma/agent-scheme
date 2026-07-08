;;; consent-helper.el --- Reusable helper artifacts  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The source-loaded `(agent helper)' library owns canonical helper, artifact,
;; and skill-candidate datums.  This host adapter keeps session/project
;; subject mapping, persistence, policy gates, helper evaluation, memory writes,
;; and tracked project file effects.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-memory)
(require 'consent-policy)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)

(declare-function consent--drain-state "consent-interpreter")
(declare-function consent--eval-sequence "consent-interpreter")
(declare-function consent--source-library-call "consent-library")

(define-error 'consent-helper-error
  "Consent Scheme helper error"
  'consent-eval-error)

(defgroup consent-helper nil
  "Reusable helper libraries and artifacts for Consent Scheme."
  :group 'consent)

(defcustom consent-helper-directory
  (expand-file-name "consent/helpers/" user-emacs-directory)
  "Private-local directory for Consent Scheme helper persistence."
  :type 'directory
  :group 'consent-helper)

(defcustom consent-helper-project-tracked-directory
  ".consent/helpers/"
  "Project-relative directory used only for approved tracked helper files."
  :type 'string
  :group 'consent-helper)

(defvar consent--helper-stores (make-hash-table :test #'equal)
  "Hash from (SCOPE . SUBJECT) to source-backed helper stores.")

(defconst consent-helper-scopes
  '(session project-private project-tracked)
  "Recognized helper storage scopes.")

(defun consent-helper--source-call (name &rest arguments)
  "Call source-backed helper procedure NAME with ARGUMENTS."
  (unless (fboundp 'consent--source-library-call)
    (require 'consent-library))
  (apply #'consent--source-library-call
         "(agent helper)" name arguments))

(defun consent-helper--source-scope (scope)
  "Return SCOPE as a source-library helper scope symbol."
  (consent-helper--symbol (consent-helper--scope scope)))

(defun consent-helper--symbol (name)
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

(defun consent-helper--field (name value)
  "Return a Scheme-readable helper field named NAME with VALUE."
  (list (consent-helper--symbol name) value))

(defun consent-helper--integer (value)
  "Return VALUE as an exact integer datum."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent-helper--field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (consent-symbol-p (car field))
       (equal (consent-symbol-name (car field)) name)))

(defun consent-helper-record-field (record name)
  "Return field NAME from helper or artifact RECORD."
  (cadr
   (seq-find
    (lambda (field)
      (consent-helper--field-named-p field name))
    (cdr-safe record))))

(defun consent-helper--record-kind-p (record kind)
  "Return non-nil when RECORD starts with KIND."
  (and (consp record)
       (consent-symbol-p (car record))
       (equal (consent-symbol-name (car record)) kind)))

(defun consent-helper--option-key (key)
  "Return KEY normalized to an Emacs Lisp keyword."
  (intern
   (concat
    ":"
    (cond
     ((keywordp key)
      (substring (symbol-name key) 1))
     ((consent-symbol-p key)
      (consent-symbol-name key))
     ((symbolp key)
      (symbol-name key))
     ((stringp key)
      key)
     (t
      (format "%S" key))))))

(defun consent-helper--options-plist (options)
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
      (dolist (entry (consent--proper-list-elements
                      options "helper options")
                     plist)
        (let ((elements (consent--proper-list-elements-maybe entry)))
          (cond
           ((and elements (= (length elements) 2))
            (setq plist
                  (plist-put plist
                             (consent-helper--option-key (car elements))
                             (cadr elements))))
           ((consp entry)
            (setq plist
                  (plist-put plist
                             (consent-helper--option-key (car entry))
                             (cdr entry))))
           (t
            (signal 'consent-helper-error
                    (list "helper option entries must be pairs"))))))))))

(defun consent-helper--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (let ((plist (consent-helper--options-plist options)))
    (if (plist-member plist key)
        (plist-get plist key)
      default)))

(defun consent-helper--scope (scope)
  "Return normalized helper SCOPE or signal."
  (let ((normalized
         (cond
          ((consent-symbol-p scope)
           (intern (consent-symbol-name scope)))
          ((symbolp scope)
           scope)
          ((stringp scope)
           (intern scope))
          (t nil))))
    (when (eq normalized 'project)
      (setq normalized 'project-private))
    (unless (memq normalized consent-helper-scopes)
      (signal 'consent-helper-error
              (list (format "unknown helper scope: %S" scope))))
    normalized))

(defun consent-helper--default-scope (context)
  "Return default helper scope for CONTEXT."
  (if (and context (consent--eval-context-session-id context))
      'session
    'project-private))

(defun consent-helper--scope-option (options context)
  "Return helper scope from OPTIONS or CONTEXT default."
  (consent-helper--scope
   (consent-helper--option
    options :scope (consent-helper--default-scope context))))

(defun consent-helper--current-project-root ()
  "Return the active project root, or `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun consent-helper--session-id (context)
  "Return current session id from CONTEXT, or signal."
  (or (and context (consent--eval-context-session-id context))
      (signal 'consent-helper-error
              (list "session helper scope requires an active session"))))

(defun consent-helper--subject-key (scope context)
  "Return storage subject key for SCOPE and CONTEXT."
  (pcase scope
    ('session
     (consent-helper--session-id context))
    ((or 'project-private 'project-tracked)
     (consent-helper--current-project-root))))

(defun consent-helper--store (scope subject)
  "Return source-backed helper store for SCOPE and SUBJECT."
  (let* ((key (cons (consent-helper--scope scope) subject))
         (store (gethash key consent--helper-stores)))
    (unless store
      (setq store
            (consent-helper--source-call
             "consent-make-helper-store"))
      (puthash key store consent--helper-stores))
    store))

(defun consent-helper--records (scope subject)
  "Return records for SCOPE and SUBJECT."
  (consent-helper--source-call
   "helper-store-helpers"
   (consent-helper--store scope subject)
   (consent-helper--source-scope scope)))

(defun consent-helper--valid-library-part-p (part)
  "Return non-nil if PART is valid in an R7RS library name."
  (or (consent-symbol-p part)
      (symbolp part)
      (and (consent-number-p part)
           (eq (consent-number-kind part) 'integer)
           (eq (consent-number-exactness part) 'exact)
           (>= (consent-number-value part) 0))
      (and (integerp part) (>= part 0))))

(defun consent-helper--library-part (part)
  "Return PART normalized for a Scheme-readable library name."
  (cond
   ((consent-symbol-p part)
    part)
   ((symbolp part)
    (consent-helper--symbol part))
   ((consent-number-p part)
    part)
   ((integerp part)
    (consent-helper--integer part))
   (t part)))

(defun consent-helper--library-name (name)
  "Return validated helper library NAME."
  (let ((normalized (consent--strip-identifiers name)))
    (unless (and (consp normalized)
                 (consent--proper-list-elements-maybe normalized)
                 (cl-every #'consent-helper--valid-library-part-p
                           (consent--proper-list-elements
                            normalized "helper library name")))
      (signal 'consent-helper-error
              (list (format "invalid helper library name: %s"
                            (format "%S" name)))))
    (mapcar #'consent-helper--library-part
            (consent--proper-list-elements normalized
                                                "helper library name"))))

(defun consent-helper--forms (forms)
  "Return validated helper FORMS as a proper list."
  (consent--proper-list-elements forms "helper forms"))

(defun consent-helper--name-key (library-name)
  "Return stable string key for LIBRARY-NAME."
  (consent-datum->external
   (consent--strip-identifiers
    (consent-helper--library-name library-name))))

(defun consent-helper--safe-path-component (part)
  "Return PART as a safe relative path component."
  (let* ((raw
          (cond
           ((consent-symbol-p part)
            (consent-symbol-name part))
           ((symbolp part)
            (symbol-name part))
           ((consent-number-p part)
            (number-to-string (consent-number-value part)))
           ((integerp part)
            (number-to-string part))
           (t
            (format "%S" part))))
         (sanitized
          (replace-regexp-in-string "[^[:alnum:]._+-]" "_" raw)))
    (if (string-empty-p sanitized) "_" sanitized)))

(defun consent-helper--library-relative-file (library-name)
  "Return relative helper source file path for LIBRARY-NAME."
  (mapconcat
   #'identity
   (append
    (mapcar #'consent-helper--safe-path-component
            (consent--proper-list-elements
             (consent-helper--library-name library-name)
             "helper library name"))
    nil)
   "/"))

(defun consent-helper--private-helper-file (library-name subject)
  "Return private-local helper file for LIBRARY-NAME and project SUBJECT."
  (expand-file-name
   (concat (consent-helper--library-relative-file library-name) ".scm")
   (expand-file-name
    (concat "projects/" (secure-hash 'sha1 subject) "/")
    consent-helper-directory)))

(defun consent-helper--tracked-helper-file (library-name subject)
  "Return project-tracked helper file for LIBRARY-NAME and project SUBJECT."
  (expand-file-name
   (concat (consent-helper--library-relative-file library-name) ".scm")
   (expand-file-name consent-helper-project-tracked-directory subject)))

(defun consent-helper--storage-file (scope library-name subject)
  "Return storage file for SCOPE, LIBRARY-NAME, and SUBJECT, or nil."
  (pcase scope
    ('project-private
     (consent-helper--private-helper-file library-name subject))
    ('project-tracked
     (consent-helper--tracked-helper-file library-name subject))
    (_ nil)))

(defun consent-helper--record-source (scope subject)
  "Return source datum for SCOPE and SUBJECT."
  (pcase scope
    ('session
     (list (consent-helper--symbol "session")
           (consent-helper--symbol subject)))
    ((or 'project-private 'project-tracked)
     (list (consent-helper--symbol "project-root") subject))))

(defun consent-helper--write-record-file (record file)
  "Write Scheme-readable RECORD to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (consent-result->external record))
    (insert "\n"))
  file)

(defun consent-helper--read-record-file (file)
  "Read one Scheme-readable helper record from FILE."
  (consent-read
   (with-temp-buffer
     (insert-file-contents file)
     (buffer-string))))

(defun consent-helper--maybe-load-file-record
    (scope subject library-name)
  "Load helper record for SCOPE, SUBJECT, and LIBRARY-NAME from disk if present."
  (when-let ((file (consent-helper--storage-file
                    scope library-name subject)))
    (when (file-readable-p file)
      (let ((record (consent-helper--read-record-file file)))
        (unless (consent-helper--record-kind-p
                 record "agent-helper-library")
          (signal 'consent-helper-error
                  (list (format "helper file does not contain a helper record: %s"
                                file))))
        (consent-helper--source-call
         "helper-store-record!"
         (consent-helper--store scope subject)
         record)
        record))))

(defun consent-helper--audit (operation scope fields)
  "Record helper OPERATION for SCOPE with FIELDS."
  (consent-audit-record
   'agent-helper
   (append
    `((category . agent-helper)
      (operation . ,operation)
      (scope . ,scope)
      (decision . completed))
    fields)))

(defun consent-helper--memory-scope (scope)
  "Return memory scope corresponding to helper SCOPE."
  (pcase scope
    ('session 'session)
    (_ 'project)))

(defun consent-helper--memory-subject (scope subject)
  "Return memory subject for helper SCOPE and SUBJECT."
  (pcase scope
    ('session subject)
    (_ subject)))

(defun consent-helper--record-memory! (scope subject library-name record)
  "Record helper RECORD in `(agent memory)'."
  (consent-memory-put!
   (consent-helper--memory-scope scope)
   (copy-tree library-name)
   (list
    (consent-helper--field "tags"
                                (list (consent-helper--symbol "helper")
                                      (consent-helper--symbol "library")))
    (consent-helper--field "value" (copy-tree record))
    (consent-helper--field
     "source"
     (consent-helper--record-source scope subject))
    (consent-helper--field "confidence"
                                (consent-helper--symbol "high")))
   (consent-helper--memory-subject scope subject)))

;;;###autoload
(defun consent-helper-save!
    (library-name forms &optional options context)
  "Save helper FORMS as LIBRARY-NAME and return the helper record.
OPTIONS may include `:scope'.  Session helpers require CONTEXT with
an active session id.  Project-tracked helpers require policy approval."
  (let* ((scope (consent-helper--scope-option options context))
         (subject (consent-helper--subject-key scope context))
         (name (consent-helper--library-name library-name))
         (helper-forms (consent-redact
                        (consent-helper--forms forms)
                        'helper-source))
         (file (consent-helper--storage-file scope name subject)))
    (when (eq scope 'project-tracked)
      (consent-policy-authorize-helper-tracked-write
       name file context))
    (let ((record
           (consent-helper--source-call
            "helper-store-save!"
            (consent-helper--store scope subject)
            (consent-helper--source-scope scope)
            name
            helper-forms
            (consent-helper--record-source scope subject))))
      (when file
        (consent-helper--write-record-file record file))
      (consent-helper--record-memory! scope subject name record)
      (consent-helper--audit
       "agent-helper-save!" scope
       `((library . ,name)
         (record . ,record)
         (storage-file . ,file)))
      record)))

;;;###autoload
(defun consent-helper-ref (library-name &optional options context)
  "Return helper LIBRARY-NAME record, or nil when absent."
  (let* ((scope (consent-helper--scope-option options context))
         (subject (consent-helper--subject-key scope context))
         (name (consent-helper--library-name library-name))
         (record
          (consent-helper--source-call
           "helper-store-ref"
           (consent-helper--store scope subject)
           (consent-helper--source-scope scope)
           name)))
    (or (unless (eq record consent-false) record)
        (consent-helper--maybe-load-file-record scope subject name))))

;;;###autoload
(defun consent-helper-list (scope &optional context)
  "Return helper records in SCOPE."
  (let* ((normalized-scope (consent-helper--scope scope))
         (subject (consent-helper--subject-key normalized-scope context)))
    (consent-helper--records normalized-scope subject)))

;;;###autoload
(defun consent-helper-artifact!
    (name datum &optional options context)
  "Save artifact NAME with DATUM and yield it when CONTEXT is active."
  (let* ((scope (consent-helper--scope-option options context))
         (subject (consent-helper--subject-key scope context))
         (record
          (consent-helper--source-call
           "helper-store-artifact-save!"
           (consent-helper--store scope subject)
           (consent-helper--source-scope scope)
           name
           (consent-redact datum 'helper-artifact)
           (consent-helper--record-source scope subject))))
    (consent-memory-add!
     (consent-helper--memory-scope scope)
     'artifact
     (list
      (consent-helper--field "tags"
                                  (list (consent-helper--symbol "helper")
                                        (consent-helper--symbol "artifact")))
      (consent-helper--field "value" record)
      (consent-helper--field
       "source"
       (consent-helper--record-source scope subject)))
     (consent-helper--memory-subject scope subject))
    (when context
      (consent--record-event!
       context
       (list (consent-helper--symbol "yield") record)))
    (consent-helper--audit
     "agent-artifact" scope
     `((artifact . ,name)
       (record . ,record)))
    record))

(defun consent-helper--source-options (options)
  "Return OPTIONS as a Scheme association list for source helpers."
  (let ((plist (consent-helper--options-plist options))
        alist)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (push
         (list (consent-helper--symbol
                (string-remove-prefix ":" (symbol-name key)))
               value)
         alist)))
    (nreverse alist)))

;;;###autoload
(defun consent-helper-promote-to-skill
    (helper-or-library &optional options context)
  "Return a skill candidate datum for HELPER-OR-LIBRARY.
HELPER-OR-LIBRARY may be a helper record or a library name."
  (let* ((helper-record
          (if (consent-helper--record-kind-p
               helper-or-library "agent-helper-library")
              helper-or-library
            (or (consent-helper-ref helper-or-library options context)
                (signal 'consent-helper-error
                        (list "unknown helper library")))))
         (library-name (consent-helper-record-field helper-record "name"))
         (candidate
          (consent-helper--source-call
           "helper-promote-to-skill"
           helper-record
           (consent-helper--source-options options))))
    (consent-helper--audit
     "agent-helper-promote-to-skill"
     (consent-helper--scope
      (consent-helper-record-field helper-record "scope"))
     `((library . ,library-name)
       (candidate . ,candidate)))
    candidate))

;;;###autoload
(defun consent-helper-export-skill-candidate!
    (candidate export-directory &optional context)
  "Write CANDIDATE as `SKILL.scm' under EXPORT-DIRECTORY after approval."
  (unless (consent-helper--record-kind-p
           candidate "agent-skill-candidate")
    (signal 'consent-helper-error
            (list "skill candidate export expects an agent-skill-candidate datum")))
  (let* ((name (consent-helper-record-field candidate "name"))
         (target-directory
          (file-name-as-directory (expand-file-name export-directory)))
         (target-file (expand-file-name "SKILL.scm" target-directory)))
    (consent-policy-authorize-helper-skill-candidate-write
     name target-file context)
    (make-directory target-directory t)
    (consent-helper--write-record-file candidate target-file)
    (consent-helper--audit
     "agent-helper-export-skill-candidate!" 'project-private
     `((candidate . ,name)
       (export-path . ,target-file)))
    (list
     (consent-helper--symbol "skill-candidate-export")
     (consent-helper--field "name" name)
     (consent-helper--field "export-path" target-file)
     (consent-helper--field "decision"
                                 (consent-helper--symbol "written")))))

(defun consent-helper--load-record (library-name options context)
  "Load helper LIBRARY-NAME according to OPTIONS and CONTEXT."
  (or (consent-helper-ref library-name options context)
      (signal 'consent-helper-error
              (list "unknown helper library"))))

(defun consent-helper--eval-record-forms (record context)
  "Evaluate helper RECORD forms in CONTEXT's interaction environment."
  (let ((environment
         (and context
              (consent--eval-context-interaction-environment context))))
    (unless environment
      (signal 'consent-helper-error
              (list "helper load requires an active evaluation environment")))
    (consent--drain-state
     (consent--eval-sequence
      (consent-helper-record-field record "forms")
      environment
      context
      t
      t)
     context))
  record)

(defun consent-helper--primitive-artifact (arguments context)
  "Primitive agent-artifact over ARGUMENTS."
  (consent-helper-artifact! (car arguments) (cadr arguments) nil context))

(defun consent-helper--primitive-save (arguments context)
  "Primitive agent-helper-save! over ARGUMENTS."
  (consent-helper-save!
   (car arguments)
   (cadr arguments)
   (caddr arguments)
   context))

(defun consent-helper--primitive-load (arguments context)
  "Primitive agent-helper-load over ARGUMENTS."
  (consent-helper--eval-record-forms
   (consent-helper--load-record
    (car arguments)
    (cadr arguments)
    context)
   context))

(defun consent-helper--primitive-list (arguments context)
  "Primitive agent-helper-list over ARGUMENTS."
  (consent-helper-list (car arguments) context))

(defun consent-helper--primitive-ref (arguments context)
  "Primitive agent-helper-ref over ARGUMENTS."
  (or (consent-helper-ref
       (car arguments)
       (cadr arguments)
       context)
      consent-false))

(defun consent-helper--primitive-promote (arguments context)
  "Primitive agent-helper-promote-to-skill over ARGUMENTS."
  (consent-helper-promote-to-skill
   (car arguments)
   (cadr arguments)
   context))

;;;###autoload
(defun consent-helper-primitive-specs ()
  "Return primitive specs for the `(agent helper)' library."
  `(("agent-artifact" ,#'consent-helper--primitive-artifact 2 2)
    ("agent-helper-save!" ,#'consent-helper--primitive-save 2 3)
    ("agent-helper-load" ,#'consent-helper--primitive-load 1 2)
    ("agent-helper-list" ,#'consent-helper--primitive-list 1 1)
    ("agent-helper-ref" ,#'consent-helper--primitive-ref 1 2)
    ("agent-helper-promote-to-skill"
     ,#'consent-helper--primitive-promote 1 2)))

;;;###autoload
(defun consent-helper-clear! ()
  "Clear in-memory helper and artifact state."
  (clrhash consent--helper-stores)
  consent-unspecified)

(provide 'consent-helper)

;;; consent-helper.el ends here
