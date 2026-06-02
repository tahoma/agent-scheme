;;; consent-memory.el --- Inspectable scoped memory records  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent memory)' library stores canonical memory as Scheme-readable
;; datums.  Host-side indexes, buffers, and persistence files are rebuildable
;; views over those records; the records themselves remain the source of truth.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)
(require 'consent-session)

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

(defvar consent--memory-instance-records nil
  "Canonical instance-scope memory records, newest first.")

(defvar consent--memory-project-records (make-hash-table :test #'equal)
  "Hash from project root to canonical project-scope memory records.")

(defvar consent--memory-next-id 0
  "Next memory record sequence number.")

(defvar consent--memory-current-session nil
  "Dynamically bound session object for `(agent memory)' session scope.")

(defvar-local consent--memory-buffer-scope nil
  "Memory scope represented by the current editable memory buffer.")

(defvar-local consent--memory-buffer-subject nil
  "Session id or project root represented by the current memory buffer.")

(define-derived-mode consent-memory-mode prog-mode "Agent Memory"
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

(defun consent--memory-field (name value)
  "Return a Scheme-readable memory field named NAME with VALUE."
  (list (consent--memory-symbol name) value))

(defun consent--memory-integer (value)
  "Return VALUE as an exact integer datum."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent--memory-integer-value (value description)
  "Return exact integer VALUE or signal an error naming DESCRIPTION."
  (cond
   ((and (consent-number-p value)
         (eq (consent-number-kind value) 'integer)
         (eq (consent-number-exactness value) 'exact))
    (consent-number-value value))
   ((integerp value)
    value)
   (t
    (signal 'consent-memory-error
            (list (format "%s must be an exact integer" description))))))

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

(defun consent--memory-field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (consent-symbol-p (car field))
       (equal (consent-symbol-name (car field)) name)))

(defun consent--memory-record-field (record name)
  "Return field NAME from memory RECORD, or nil."
  (cadr
   (seq-find
    (lambda (field)
      (consent--memory-field-named-p field name))
    (cdr-safe record))))

(defun consent--memory-payload-field (datum name)
  "Return field NAME from payload DATUM, or nil."
  (let ((fields (if (and (consp datum)
                         (consent--memory-field-named-p
                          (list (car datum)) "memory"))
                    (cdr datum)
                  datum)))
    (when (listp fields)
      (cadr
       (seq-find
        (lambda (field)
          (consent--memory-field-named-p field name))
        fields)))))

(defun consent--memory-proper-list-or-empty (value description)
  "Return VALUE as a proper list, or signal an error naming DESCRIPTION."
  (if (null value)
      nil
    (consent--proper-list-elements value description)))

(defun consent--memory-next-sequence ()
  "Return the next memory sequence number."
  (cl-incf consent--memory-next-id))

(defun consent--memory-generated-id (sequence)
  "Return a generated memory id symbol for SEQUENCE."
  (consent--memory-symbol (format "m-%d" sequence)))

(defun consent--memory-make-record
    (scope key kind datum &optional existing)
  "Return a canonical memory record for SCOPE, KEY, KIND, and DATUM.
When EXISTING is non-nil, preserve its id and creation sequence."
  (let* ((sequence (consent--memory-next-sequence))
         (id (or (consent--memory-record-field existing "id")
                 key
                 (consent--memory-generated-id sequence)))
         (created-at (or (consent--memory-record-field existing
                                                            "created-at")
                         (consent--memory-integer sequence)))
         (tags (consent--memory-proper-list-or-empty
                (consent--memory-payload-field datum "tags")
                "memory tags"))
         (value (let ((field (consent--memory-payload-field datum
                                                                 "value")))
                  (if field field datum)))
         (source (or (consent--memory-payload-field datum "source")
                     nil))
         (confidence (or (consent--memory-payload-field datum
                                                             "confidence")
                         (consent--memory-symbol "unknown"))))
    (list
     (consent--memory-symbol "memory")
     (consent--memory-field "id" id)
     (consent--memory-field "scope" (consent--memory-symbol scope))
     (consent--memory-field "key" key)
     (consent--memory-field "kind" (consent--memory-symbol kind))
     (consent--memory-field "tags" tags)
     (consent--memory-field "value" value)
     (consent--memory-field "source" source)
     (consent--memory-field "confidence" confidence)
     (consent--memory-field "created-at" created-at)
     (consent--memory-field "updated-at"
                                 (consent--memory-integer sequence)))))

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

(defun consent--memory-records (scope &optional subject)
  "Return records for SCOPE and optional SUBJECT."
  (pcase (consent--memory-scope scope)
    ('instance consent--memory-instance-records)
    ('session
     (consent-session-memory
      (consent--memory-session-for-subject subject)))
    ('project
     (gethash (consent--memory-project-key
               (and subject (file-directory-p subject) subject))
              consent--memory-project-records))))

(defun consent--memory-set-records! (scope records &optional subject)
  "Replace records for SCOPE and optional SUBJECT with RECORDS."
  (pcase (consent--memory-scope scope)
    ('instance
     (setq consent--memory-instance-records records))
    ('session
     (setf (consent-session-memory
            (consent--memory-session-for-subject subject))
           records))
    ('project
     (puthash (consent--memory-project-key
               (and subject (file-directory-p subject) subject))
              records
              consent--memory-project-records))))

(defun consent--memory-find-by-key (records key)
  "Return memory record with KEY from RECORDS."
  (seq-find
   (lambda (record)
     (equal (consent--memory-record-field record "key") key))
   records))

(defun consent--memory-replace-record (records record)
  "Return RECORDS with RECORD replacing any record with the same key."
  (cons record
        (seq-remove
         (lambda (candidate)
           (equal (consent--memory-record-field candidate "key")
                  (consent--memory-record-field record "key")))
         records)))

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
         (records (consent--memory-records normalized-scope subject))
         (existing (consent--memory-find-by-key records normalized-key))
         (redacted-datum (consent-redact datum 'memory))
         (record (consent--memory-make-record
                  normalized-scope
                  normalized-key
                  'datum
                  redacted-datum
                  existing)))
    (consent--memory-set-records!
     normalized-scope
     (consent--memory-replace-record records record)
     subject)
    (consent--memory-audit
     "memory-put!" normalized-scope
     `((key . ,normalized-key)
       (record . ,record)))
    record))

;;;###autoload
(defun consent-memory-ref (scope key &optional subject)
  "Return memory record from SCOPE by KEY, or nil."
  (consent--memory-find-by-key
   (consent--memory-records scope subject)
   (consent--memory-datum-key key)))

;;;###autoload
(defun consent-memory-delete! (scope key &optional subject)
  "Delete memory record by KEY from SCOPE and return the deleted record."
  (let* ((normalized-scope (consent--memory-scope scope))
         (normalized-key (consent--memory-datum-key key))
         (records (consent--memory-records normalized-scope subject))
         (record (consent--memory-find-by-key records normalized-key)))
    (when record
      (consent--memory-set-records!
       normalized-scope
       (seq-remove
        (lambda (candidate)
          (equal (consent--memory-record-field candidate "key")
                 normalized-key))
        records)
       subject)
      (consent--memory-audit
       "memory-delete!" normalized-scope `((key . ,normalized-key))))
    record))

;;;###autoload
(defun consent-memory-add! (scope kind datum &optional subject)
  "Add a generated memory record of KIND to SCOPE and return it."
  (let* ((normalized-scope (consent--memory-scope scope))
         (sequence (1+ consent--memory-next-id))
         (id (consent--memory-generated-id sequence))
         (redacted-datum (consent-redact datum 'memory))
         (record (consent--memory-make-record
                  normalized-scope id kind redacted-datum)))
    (consent--memory-set-records!
     normalized-scope
     (cons record (consent--memory-records normalized-scope subject))
     subject)
    (consent--memory-audit
     "memory-add!" normalized-scope
     `((kind . ,kind)
       (record . ,record)))
    record))

(defun consent--memory-query-match-p (record query)
  "Return non-nil when RECORD matches QUERY."
  (cond
   ((or (not query) (eq query consent-true))
    t)
   ((stringp query)
    (string-match-p
     (regexp-quote query)
     (consent-result->external record)))
   ((consent-symbol-p query)
    (or (equal query (consent--memory-record-field record "kind"))
        (equal query (consent--memory-record-field record "key"))
        (member query (consent--memory-record-field record "tags"))
        (string-match-p
         (regexp-quote (consent-symbol-name query))
         (consent-result->external record))))
   (t
    (equal query record))))

;;;###autoload
(defun consent-memory-find (scope query &optional subject)
  "Return memory records in SCOPE matching QUERY."
  (let ((normalized-query (consent--memory-datum-key query)))
    (seq-filter
     (lambda (record)
       (consent--memory-query-match-p record normalized-query))
     (consent--memory-records scope subject))))

;;;###autoload
(defun consent-memory-by-tag (scope tag &optional subject)
  "Return memory records in SCOPE tagged with TAG."
  (let ((normalized-tag (consent--memory-datum-key tag)))
    (seq-filter
     (lambda (record)
       (member normalized-tag (consent--memory-record-field record
                                                                 "tags")))
     (consent--memory-records scope subject))))

;;;###autoload
(defun consent-memory-recent (scope count &optional subject)
  "Return COUNT newest memory records in SCOPE."
  (let* ((n (max 0 (consent--memory-integer-value
                   count "memory-recent count")))
         (records (consent--memory-records scope subject)))
    (cl-subseq records 0 (min n (length records)))))

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
         (setq consent--memory-instance-records nil))
        ('session
         (setf (consent-session-memory
                (consent--memory-session-for-subject subject))
               nil))
        ('project
         (if subject
             (remhash (consent--memory-project-key subject)
                      consent--memory-project-records)
           (clrhash consent--memory-project-records))))
    (setq consent--memory-instance-records nil)
    (clrhash consent--memory-project-records)
    (setq consent--memory-next-id 0))
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
    (append
     (list
      (consent--memory-symbol "memory-storage")
      (consent--memory-field "scope"
                                  (consent--memory-symbol
                                   normalized-scope))
      (consent--memory-field "mode"
                                  (consent--memory-symbol
                                   "private-local"))
      (consent--memory-field
       "private-file"
       (consent--memory-storage-file normalized-scope subject)))
     (when project-root
       (list
        (consent--memory-field "project-root" project-root)
        (consent--memory-field "tracked-file" tracked-file)
        (consent--memory-field
         "tracked-enabled"
         (if consent-memory-project-tracked-enabled
             consent-true
           consent-false))
        (consent--memory-field "public-repository-safe"
                                    consent-true))))))

;;;###autoload
(defun consent-memory-scope-datum (scope &optional subject)
  "Return SCOPE memory as an inspectable Scheme-readable datum."
  (let ((normalized-scope (consent--memory-scope scope)))
    (append
     (list
      (consent--memory-symbol "agent-memory")
      (consent--memory-field "scope"
                                  (consent--memory-symbol
                                   normalized-scope)))
     (pcase normalized-scope
       ('session
        (let ((session (consent--memory-session-for-subject subject)))
          (list
           (consent--memory-field
            "session"
            (consent--memory-symbol
             (consent-session-id session))))))
       ('project
        (list
         (consent--memory-field
          "storage"
          (consent-memory-storage-rules normalized-scope subject))))
       (_ nil))
     (list
      (consent--memory-field
       "records"
       (consent--memory-records normalized-scope subject))))))

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
                  (format "*Agent Memory: %s*" label))))
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

(defun consent--memory-scope-datum-records (datum)
  "Return memory records field from scope DATUM."
  (or (consent--memory-record-field datum "records")
      (signal 'consent-memory-error
              (list "memory buffer datum must contain records"))))

;;;###autoload
(defun consent-memory-apply-buffer ()
  "Apply the current editable memory buffer back to its scoped store."
  (interactive)
  (let ((datum (consent-read (current-buffer)))
        (scope consent--memory-buffer-scope)
        (subject consent--memory-buffer-subject))
    (consent--memory-set-records!
     scope
     (consent--memory-scope-datum-records datum)
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
       (consent--memory-scope-datum-records datum)
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

(defun consent--memory-primitive-yield (arguments context)
  "Primitive memory-yield over ARGUMENTS."
  (consent-memory-yield (car arguments) (cadr arguments) context))

;;;###autoload
(defun consent-memory-primitive-specs ()
  "Return primitive specs for the `(agent memory)' library."
  `(("memory-put!" ,#'consent--memory-primitive-put 3 3)
    ("memory-ref" ,#'consent--memory-primitive-ref 2 2)
    ("memory-delete!" ,#'consent--memory-primitive-delete 2 2)
    ("memory-add!" ,#'consent--memory-primitive-add 3 3)
    ("memory-find" ,#'consent--memory-primitive-find 2 2)
    ("memory-by-tag" ,#'consent--memory-primitive-by-tag 2 2)
    ("memory-recent" ,#'consent--memory-primitive-recent 2 2)
    ("memory-yield" ,#'consent--memory-primitive-yield 2 2)))

(provide 'consent-memory)

;;; consent-memory.el ends here
