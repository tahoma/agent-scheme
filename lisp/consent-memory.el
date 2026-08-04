;;; consent-memory.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The source-loaded `(agent memory)' library owns canonical memory store
;; helpers.  This host adapter keeps Emacs session/project scoping, audit
;; emission, buffers, persistence files, and the legacy public memory verbs.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)
(require 'consent-session)

(declare-function consent--source-library-call "consent-library")

(define-error 'consent-memory-error
  "Consent Scheme memory error"
  'consent-eval-error)

(defgroup consent-memory nil
  "Inspectable scoped memory for Consent Scheme."
  :group 'consent)

(defcustom consent-memory-directory
  (expand-file-name "consent/memory/" user-emacs-directory)
  "Private-local directory for Consent Scheme memory persistence."
  :type 'directory
  :group 'consent-memory)

(defcustom consent-memory-project-tracked-enabled nil
  "Non-nil means project memory may also use tracked project files.
The default is nil so public repositories do not capture private memory unless
the user or project opts in explicitly."
  :type 'boolean
  :group 'consent-memory)

(defcustom consent-memory-project-tracked-file ".consent/memory.scm"
  "Project-relative file used only when tracked project memory is enabled."
  :type 'string
  :group 'consent-memory)

(defvar consent--memory-instance-store nil
  "Source-backed memory store for instance-scope records.")

(defvar consent--memory-project-stores (make-hash-table :test #'equal)
  "Hash from project root to source-backed project memory stores.")

(defvar consent--memory-session-stores (make-hash-table :test #'equal)
  "Hash from session id to source-backed session memory stores.")

(defvar consent--memory-current-session nil
  "Dynamically bound session object for `(agent memory)' session scope.")

(defvar-local consent--memory-buffer-scope nil
  "Memory scope represented by the current editable memory buffer.")

(defvar-local consent--memory-buffer-subject nil
  "Session id or project root represented by the current memory buffer.")

(define-derived-mode consent-memory-mode prog-mode "Consent Memory"
  "Major mode for editable Consent Scheme memory datum buffers.")

(defun consent--memory-symbol (name)
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

(defun consent--memory-datum-key (value)
  "Return VALUE normalized for use as a Scheme-readable key or tag."
  (cond
   ((or (consent-symbol-p value)
        (stringp value)
        (consent-number-p value))
    value)
   ((symbolp value)
    (consent--memory-symbol value))
   (t value)))

(defun consent--memory-scope (scope)
  "Return normalized memory SCOPE or signal an error."
  (let ((normalized
         (cond
          ((consent-symbol-p scope)
           (intern (consent-symbol-name scope)))
          ((symbolp scope)
           scope)
          ((stringp scope)
           (intern scope))
          (t nil))))
    (unless (memq normalized '(instance session project))
      (signal 'consent-memory-error
              (list (format "unknown memory scope: %S" scope))))
    normalized))

(defun consent--memory-name (value description)
  "Return VALUE as a stable name string for DESCRIPTION."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (signal 'consent-memory-error
            (list (format "%s must be a symbol or string" description))))))

(defun consent--memory-source-call (name &rest arguments)
  "Call source-backed memory procedure NAME with ARGUMENTS."
  (apply #'consent--source-library-call
         "(agent memory)" name arguments))

(defun consent--memory-source-make-store (&optional records)
  "Return a source-backed memory store, optionally initialized with RECORDS."
  (let ((store (consent--memory-source-call
                "consent-make-memory-store")))
    (when records
      (consent--memory-source-call
       "memory-store-replace-records!" store records))
    store))

(defun consent--memory-source-scope (scope)
  "Return SCOPE as a source-library scope symbol."
  (consent--memory-symbol (consent--memory-scope scope)))

(defun consent--memory-current-project-root ()
  "Return the active project root, or `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((session consent--memory-current-session))
          (and (eq (consent-session-scope session) 'project)
               (consent-session-project-root session)))
        (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun consent--memory-project-key (&optional root)
  "Return canonical project key for ROOT or the current project."
  (file-name-as-directory
   (expand-file-name (or root (consent--memory-current-project-root)))))

(defun consent--memory-session-for-subject (subject)
  "Return session for SUBJECT or the dynamically active session."
  (cond
   ((consent-session-p subject)
    subject)
   (subject
    (consent-session--require subject))
   (consent--memory-current-session
    consent--memory-current-session)
   (t
    (signal 'consent-memory-error
            (list "session memory requires an active session")))))

(defun consent--memory-session-store (subject)
  "Return source-backed memory store for session SUBJECT."
  (let* ((session (consent--memory-session-for-subject subject))
         (session-id (consent-session-id session))
         (store (gethash session-id consent--memory-session-stores)))
    (unless store
      (setq store
            (consent--memory-source-make-store
             (consent-session-memory session)))
      (puthash session-id store consent--memory-session-stores))
    store))

(defun consent--memory-project-store (subject)
  "Return source-backed memory store for project SUBJECT."
  (let* ((project-key
          (consent--memory-project-key
           (and subject (file-directory-p subject) subject)))
         (store (gethash project-key consent--memory-project-stores)))
    (unless store
      (setq store (consent--memory-source-make-store))
      (puthash project-key store consent--memory-project-stores))
    store))

(defun consent--memory-store (scope &optional subject)
  "Return source-backed memory store for SCOPE and optional SUBJECT."
  (pcase (consent--memory-scope scope)
    ('instance
     (or consent--memory-instance-store
         (setq consent--memory-instance-store
               (consent--memory-source-make-store))))
    ('session
     (consent--memory-session-store subject))
    ('project
     (consent--memory-project-store subject))))

(defun consent--memory-store-call
    (procedure scope subject &rest arguments)
  "Call source-backed memory store PROCEDURE for SCOPE and SUBJECT."
  (apply #'consent--memory-source-call
         procedure
         (consent--memory-store scope subject)
         (consent--memory-source-scope scope)
         arguments))

(defun consent--memory-records (scope &optional subject)
  "Return records for SCOPE and optional SUBJECT."
  (consent--memory-source-call
   "memory-store-records"
   (consent--memory-store scope subject)))

(defun consent--memory-sync-session-view! (scope store subject)
  "Update derived session memory view when SCOPE uses STORE."
  (when (eq (consent--memory-scope scope) 'session)
    (setf (consent-session-memory
           (consent--memory-session-for-subject subject))
          (copy-tree
           (consent--memory-source-call
            "memory-store-records" store)))))

(defun consent--memory-set-records! (scope records &optional subject)
  "Replace records for SCOPE and optional SUBJECT with RECORDS."
  (let ((store (consent--memory-store scope subject)))
    (prog1
        (consent--memory-source-call
         "memory-store-replace-records!" store records)
      (consent--memory-sync-session-view! scope store subject))))

(defun consent--memory-audit (operation scope fields)
  "Record memory OPERATION for SCOPE with FIELDS."
  (consent-audit-record
   'agent-memory
   (append
    `((category . agent-memory)
      (operation . ,operation)
      (scope . ,scope)
      (decision . completed))
    fields)))

;;;###autoload
(defun consent-memory-put! (scope key datum &optional subject)
  "Store DATUM under KEY in SCOPE and return its memory record."
  (let* ((normalized-key (consent--memory-datum-key key))
         (normalized-scope (consent--memory-scope scope))
         (store (consent--memory-store normalized-scope subject))
         (redacted-datum (consent-redact datum 'memory))
         (record
          (consent--memory-source-call
           "memory-store-put!"
           store
           (consent--memory-source-scope normalized-scope)
           normalized-key
           redacted-datum)))
    (consent--memory-sync-session-view! normalized-scope store subject)
    (consent--memory-audit
     "memory-put!" normalized-scope
     `((key . ,normalized-key)
       (record . ,record)))
    record))

;;;###autoload
(defun consent-memory-ref (scope key &optional subject)
  "Return memory record from SCOPE by KEY, or nil."
  (let ((record (consent--memory-store-call
                 "memory-store-ref" scope subject
                 (consent--memory-datum-key key))))
    (unless (eq record consent-false)
      record)))

;;;###autoload
(defun consent-memory-delete! (scope key &optional subject)
  "Delete memory record by KEY from SCOPE and return the deleted record."
  (let* ((normalized-scope (consent--memory-scope scope))
         (normalized-key (consent--memory-datum-key key))
         (store (consent--memory-store normalized-scope subject))
         (record
          (consent--memory-source-call
           "memory-store-delete!"
           store
           (consent--memory-source-scope normalized-scope)
           normalized-key)))
    (unless (eq record consent-false)
      (consent--memory-sync-session-view! normalized-scope store subject)
      (consent--memory-audit
       "memory-delete!" normalized-scope `((key . ,normalized-key))))
    (unless (eq record consent-false)
      record)))

;;;###autoload
(defun consent-memory-add! (scope kind datum &optional subject)
  "Add a generated memory record of KIND to SCOPE and return it."
  (let* ((normalized-scope (consent--memory-scope scope))
         (store (consent--memory-store normalized-scope subject))
         (redacted-datum (consent-redact datum 'memory))
         (record
          (consent--memory-source-call
           "memory-store-add!"
           store
           (consent--memory-source-scope normalized-scope)
           (consent--memory-datum-key kind)
           redacted-datum)))
    (consent--memory-sync-session-view! normalized-scope store subject)
    (consent--memory-audit
     "memory-add!" normalized-scope
     `((kind . ,kind)
       (record . ,record)))
    record))

;;;###autoload
(defun consent-memory-find (scope query &optional subject)
  "Return memory records in SCOPE matching QUERY."
  (consent--memory-store-call
   "memory-store-find" scope subject
   (consent--memory-datum-key query)))

;;;###autoload
(defun consent-memory-by-tag (scope tag &optional subject)
  "Return memory records in SCOPE tagged with TAG."
  (consent--memory-store-call
   "memory-store-by-tag" scope subject
   (consent--memory-datum-key tag)))

;;;###autoload
(defun consent-memory-recent (scope count &optional subject)
  "Return COUNT newest memory records in SCOPE."
  (consent--memory-store-call
   "memory-store-recent" scope subject count))

;;;###autoload
(defun consent-memory-access! (scope memory-id context &optional subject)
  "Append a logical memory access event for MEMORY-ID in SCOPE."
  (let* ((normalized-scope (consent--memory-scope scope))
         (store (consent--memory-store normalized-scope subject))
         (record
          (consent--memory-source-call
           "memory-store-access!"
           store
           memory-id
           (consent--memory-source-scope normalized-scope)
           context)))
    (consent--memory-sync-session-view! normalized-scope store subject)
    (consent--memory-audit
     "memory-access!" normalized-scope
     `((memory-id . ,memory-id)
       (context . ,context)
       (record . ,record)))
    record))

;;;###autoload
(defun consent-memory-reflect!
    (scope kind datum cites receipt loop-id &optional subject)
  "Append a gated reflection or synthesis DATUM in SCOPE."
  (let* ((normalized-scope (consent--memory-scope scope))
         (store (consent--memory-store normalized-scope subject))
         (record
          (consent--memory-source-call
           "memory-store-reflect!"
           store
           (consent--memory-source-scope normalized-scope)
           (consent--memory-datum-key kind)
           datum
           cites
           (consent--memory-datum-key receipt)
           loop-id)))
    (consent--memory-sync-session-view! normalized-scope store subject)
    (consent--memory-audit
     "memory-reflect!" normalized-scope
     `((kind . ,kind)
       (cites . ,cites)
       (receipt . ,receipt)
       (loop-id . ,loop-id)
       (record . ,record)))
    record))

;;;###autoload
(defun consent-memory-select (scope query policy context &optional subject)
  "Return a replayable memory-selection receipt for QUERY in SCOPE."
  (consent--memory-source-call
   "memory-store-select"
   (consent--memory-store scope subject)
   query
   policy
   context))

;;;###autoload
(defun consent-memory-yield (scope query context &optional subject)
  "Yield memory records from SCOPE matching QUERY through CONTEXT."
  (let ((records (consent-memory-find scope query subject)))
    (dolist (record records)
      (consent--record-event!
       context
       (list (consent--memory-symbol "yield") record)))
    (consent--memory-audit
     "memory-yield" (consent--memory-scope scope)
     `((query . ,query)
       (count . ,(length records))))
    records))

;;;###autoload
(defun consent-memory-clear! (&optional scope subject)
  "Clear memory SCOPE and SUBJECT, or all global memory when SCOPE is nil."
  (if scope
      (pcase (consent--memory-scope scope)
        ('instance
         (setq consent--memory-instance-store nil))
        ('session
         (remhash (consent-session-id
                   (consent--memory-session-for-subject subject))
                  consent--memory-session-stores)
         (setf (consent-session-memory
                (consent--memory-session-for-subject subject))
               nil))
        ('project
         (if subject
             (remhash (consent--memory-project-key subject)
                      consent--memory-project-stores)
           (clrhash consent--memory-project-stores))))
    (setq consent--memory-instance-store nil)
    (clrhash consent--memory-project-stores)
    (clrhash consent--memory-session-stores))
  consent-unspecified)

(defun consent--memory-storage-file (scope &optional subject)
  "Return private-local storage file for SCOPE and optional SUBJECT."
  (pcase (consent--memory-scope scope)
    ('instance
     (expand-file-name "instance.scm" consent-memory-directory))
    ('session
     (expand-file-name
      (concat (consent--memory-name subject "session id") ".scm")
      (expand-file-name "sessions/" consent-memory-directory)))
    ('project
     (let* ((root (consent--memory-project-key subject))
            (hash (secure-hash 'sha1 root)))
       (expand-file-name
        (concat hash ".scm")
        (expand-file-name "projects/" consent-memory-directory))))))

;;;###autoload
(defun consent-memory-storage-rules (scope &optional subject)
  "Return safe storage rules for SCOPE and optional SUBJECT."
  (let* ((normalized-scope (consent--memory-scope scope))
         (project-root (and (eq normalized-scope 'project)
                            (consent--memory-project-key subject)))
         (tracked-file (and project-root
                            (expand-file-name
                             consent-memory-project-tracked-file
                             project-root))))
    (consent--memory-source-call
     "memory-storage-rules"
     (consent--memory-source-scope normalized-scope)
     (consent--memory-storage-file normalized-scope subject)
     (or project-root consent-false)
     (or tracked-file consent-false)
     (if consent-memory-project-tracked-enabled
         consent-true
       consent-false))))

;;;###autoload
(defun consent-memory-scope-datum (scope &optional subject)
  "Return SCOPE memory as an inspectable Scheme-readable datum."
  (let* ((normalized-scope (consent--memory-scope scope))
         (session
          (and (eq normalized-scope 'session)
               (consent--memory-session-for-subject subject)))
         (storage
          (and (eq normalized-scope 'project)
               (consent-memory-storage-rules normalized-scope subject))))
    (consent--memory-source-call
     "memory-scope-datum"
     (consent--memory-source-scope normalized-scope)
     (if session
         (consent--memory-symbol (consent-session-id session))
       consent-false)
     (or storage consent-false)
     (consent--memory-records normalized-scope subject))))

(defun consent--memory-buffer-label (scope subject)
  "Return buffer label for SCOPE and SUBJECT."
  (pcase (consent--memory-scope scope)
    ('instance "instance")
    ('session
     (format "session: %s"
             (if subject
                 (consent--memory-name subject "session id")
               (consent-session-id
                (consent--memory-session-for-subject nil)))))
    ('project
     (format "project: %s"
             (or subject
                 (file-name-nondirectory
                  (directory-file-name
                   (consent--memory-project-key nil))))))))

;;;###autoload
(defun consent-memory-open (scope &optional subject)
  "Open editable memory buffer for SCOPE and optional SUBJECT."
  (interactive
   (list (intern
          (completing-read "Memory scope: "
                           '("instance" "session" "project")
                           nil t nil nil "instance"))
         nil))
  (let* ((label (consent--memory-buffer-label scope subject))
         (buffer (get-buffer-create
                  (format "*Consent Memory: %s*" label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (consent-result->external
          (consent-memory-scope-datum
           scope
           (pcase (consent--memory-scope scope)
             ('project
              (and subject (file-directory-p subject) subject))
             (_ subject)))))
        (insert "\n"))
      (goto-char (point-min))
      (consent-memory-mode)
      (setq-local consent--memory-buffer-scope
                  (consent--memory-scope scope))
      (setq-local consent--memory-buffer-subject subject))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-memory-apply-buffer ()
  "Apply the current editable memory buffer back to its scoped store."
  (interactive)
  (let ((datum (consent-read (current-buffer)))
        (scope consent--memory-buffer-scope)
        (subject consent--memory-buffer-subject))
    (consent--memory-set-records!
     scope
     (consent--memory-source-call
      "memory-scope-datum-records" datum)
     subject)
    consent-unspecified))

;;;###autoload
(defun consent-memory-save! (scope &optional subject)
  "Persist SCOPE memory to its private-local storage file."
  (let ((file (consent--memory-storage-file scope subject)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert
       (consent-result->external
        (consent-memory-scope-datum scope subject)))
      (insert "\n"))
    file))

;;;###autoload
(defun consent-memory-load! (scope &optional subject)
  "Load SCOPE memory from its private-local storage file."
  (let ((file (consent--memory-storage-file scope subject)))
    (unless (file-readable-p file)
      (signal 'consent-memory-error
              (list (format "memory file is not readable: %s" file))))
    (let ((datum (consent-read
                  (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))))
      (consent--memory-set-records!
       scope
       (consent--memory-source-call
        "memory-scope-datum-records" datum)
       subject)
      (consent--memory-records scope subject))))

(defun consent--memory-primitive-put (arguments _context)
  "Primitive memory-put! over ARGUMENTS."
  (consent-memory-put! (car arguments) (cadr arguments) (caddr arguments)))

(defun consent--memory-primitive-ref (arguments _context)
  "Primitive memory-ref over ARGUMENTS."
  (or (consent-memory-ref (car arguments) (cadr arguments))
      consent-false))

(defun consent--memory-primitive-delete (arguments _context)
  "Primitive memory-delete! over ARGUMENTS."
  (or (consent-memory-delete! (car arguments) (cadr arguments))
      consent-false))

(defun consent--memory-primitive-add (arguments _context)
  "Primitive memory-add! over ARGUMENTS."
  (consent-memory-add! (car arguments) (cadr arguments) (caddr arguments)))

(defun consent--memory-primitive-find (arguments _context)
  "Primitive memory-find over ARGUMENTS."
  (consent-memory-find (car arguments) (cadr arguments)))

(defun consent--memory-primitive-by-tag (arguments _context)
  "Primitive memory-by-tag over ARGUMENTS."
  (consent-memory-by-tag (car arguments) (cadr arguments)))

(defun consent--memory-primitive-recent (arguments _context)
  "Primitive memory-recent over ARGUMENTS."
  (consent-memory-recent (car arguments) (cadr arguments)))

(defun consent--memory-primitive-access (arguments _context)
  "Primitive memory-access! over ARGUMENTS."
  (consent-memory-access! (car arguments) (cadr arguments) (caddr arguments)))

(defun consent--memory-primitive-reflect (arguments _context)
  "Primitive memory-reflect! over ARGUMENTS."
  (consent-memory-reflect! (car arguments)
                           (cadr arguments)
                           (caddr arguments)
                           (cadddr arguments)
                           (nth 4 arguments)
                           (nth 5 arguments)))

(defun consent--memory-primitive-select (arguments _context)
  "Primitive memory-select over ARGUMENTS."
  (consent-memory-select (car arguments)
                         (cadr arguments)
                         (caddr arguments)
                         (cadddr arguments)))

(defun consent--memory-primitive-yield (arguments context)
  "Primitive memory-yield over ARGUMENTS."
  (consent-memory-yield (car arguments) (cadr arguments) context))

(defconst consent-memory--primitive-implementation-table
  `((primitive-memory-put! . ,#'consent--memory-primitive-put)
    (primitive-memory-ref . ,#'consent--memory-primitive-ref)
    (primitive-memory-delete! . ,#'consent--memory-primitive-delete)
    (primitive-memory-add! . ,#'consent--memory-primitive-add)
    (primitive-memory-find . ,#'consent--memory-primitive-find)
    (primitive-memory-by-tag . ,#'consent--memory-primitive-by-tag)
    (primitive-memory-recent . ,#'consent--memory-primitive-recent)
    (primitive-memory-access! . ,#'consent--memory-primitive-access)
    (primitive-memory-reflect! . ,#'consent--memory-primitive-reflect)
    (primitive-memory-select . ,#'consent--memory-primitive-select)
    (primitive-memory-yield . ,#'consent--memory-primitive-yield))
  "Provider-owned primitive implementations for `(agent memory)'.")

(defun consent-memory-primitive-implementation (primitive)
  "Return `(agent memory)' implementation for PRIMITIVE."
  (consent--primitive-implementation-from-table
   primitive
   consent-memory--primitive-implementation-table
   "`(agent memory)'"))

(provide 'consent-memory)

;;; consent-memory.el ends here
