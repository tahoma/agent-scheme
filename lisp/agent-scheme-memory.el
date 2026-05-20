;;; agent-scheme-memory.el --- Inspectable scoped memory records  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent memory)' library stores canonical memory as Scheme-readable
;; datums.  Host-side indexes, buffers, and persistence files are rebuildable
;; views over those records; the records themselves remain the source of truth.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-audit)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)
(require 'agent-scheme-session)

(define-error 'agent-scheme-memory-error
  "Agent Scheme memory error"
  'agent-scheme-eval-error)

(defgroup agent-scheme-memory nil
  "Inspectable scoped memory for Agent Scheme."
  :group 'agent-scheme)

(defcustom agent-scheme-memory-directory
  (expand-file-name "agent-scheme/memory/" user-emacs-directory)
  "Private-local directory for Agent Scheme memory persistence."
  :type 'directory
  :group 'agent-scheme-memory)

(defcustom agent-scheme-memory-project-tracked-enabled nil
  "Non-nil means project memory may also use tracked project files.
The default is nil so public repositories do not capture private memory unless
the user or project opts in explicitly."
  :type 'boolean
  :group 'agent-scheme-memory)

(defcustom agent-scheme-memory-project-tracked-file ".agent-scheme/memory.scm"
  "Project-relative file used only when tracked project memory is enabled."
  :type 'string
  :group 'agent-scheme-memory)

(defvar agent-scheme--memory-instance-records nil
  "Canonical instance-scope memory records, newest first.")

(defvar agent-scheme--memory-project-records (make-hash-table :test #'equal)
  "Hash from project root to canonical project-scope memory records.")

(defvar agent-scheme--memory-next-id 0
  "Next memory record sequence number.")

(defvar agent-scheme--memory-current-session nil
  "Dynamically bound session object for `(agent memory)' session scope.")

(defvar-local agent-scheme--memory-buffer-scope nil
  "Memory scope represented by the current editable memory buffer.")

(defvar-local agent-scheme--memory-buffer-subject nil
  "Session id or project root represented by the current memory buffer.")

(define-derived-mode agent-scheme-memory-mode prog-mode "Agent Memory"
  "Major mode for editable Agent Scheme memory datum buffers.")

(defun agent-scheme--memory-symbol (name)
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

(defun agent-scheme--memory-field (name value)
  "Return a Scheme-readable memory field named NAME with VALUE."
  (list (agent-scheme--memory-symbol name) value))

(defun agent-scheme--memory-integer (value)
  "Return VALUE as an exact integer datum."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme--memory-integer-value (value description)
  "Return exact integer VALUE or signal an error naming DESCRIPTION."
  (cond
   ((and (agent-scheme-number-p value)
         (eq (agent-scheme-number-kind value) 'integer)
         (eq (agent-scheme-number-exactness value) 'exact))
    (agent-scheme-number-value value))
   ((integerp value)
    value)
   (t
    (signal 'agent-scheme-memory-error
            (list (format "%s must be an exact integer" description))))))

(defun agent-scheme--memory-datum-key (value)
  "Return VALUE normalized for use as a Scheme-readable key or tag."
  (cond
   ((or (agent-scheme-symbol-p value)
        (stringp value)
        (agent-scheme-number-p value))
    value)
   ((symbolp value)
    (agent-scheme--memory-symbol value))
   (t value)))

(defun agent-scheme--memory-scope (scope)
  "Return normalized memory SCOPE or signal an error."
  (let ((normalized
         (cond
          ((agent-scheme-symbol-p scope)
           (intern (agent-scheme-symbol-name scope)))
          ((symbolp scope)
           scope)
          ((stringp scope)
           (intern scope))
          (t nil))))
    (unless (memq normalized '(instance session project))
      (signal 'agent-scheme-memory-error
              (list (format "unknown memory scope: %S" scope))))
    normalized))

(defun agent-scheme--memory-name (value description)
  "Return VALUE as a stable name string for DESCRIPTION."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (signal 'agent-scheme-memory-error
            (list (format "%s must be a symbol or string" description))))))

(defun agent-scheme--memory-field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (agent-scheme-symbol-p (car field))
       (equal (agent-scheme-symbol-name (car field)) name)))

(defun agent-scheme--memory-record-field (record name)
  "Return field NAME from memory RECORD, or nil."
  (cadr
   (seq-find
    (lambda (field)
      (agent-scheme--memory-field-named-p field name))
    (cdr-safe record))))

(defun agent-scheme--memory-payload-field (datum name)
  "Return field NAME from payload DATUM, or nil."
  (let ((fields (if (and (consp datum)
                         (agent-scheme--memory-field-named-p
                          (list (car datum)) "memory"))
                    (cdr datum)
                  datum)))
    (when (listp fields)
      (cadr
       (seq-find
        (lambda (field)
          (agent-scheme--memory-field-named-p field name))
        fields)))))

(defun agent-scheme--memory-proper-list-or-empty (value description)
  "Return VALUE as a proper list, or signal an error naming DESCRIPTION."
  (if (null value)
      nil
    (agent-scheme--proper-list-elements value description)))

(defun agent-scheme--memory-next-sequence ()
  "Return the next memory sequence number."
  (cl-incf agent-scheme--memory-next-id))

(defun agent-scheme--memory-generated-id (sequence)
  "Return a generated memory id symbol for SEQUENCE."
  (agent-scheme--memory-symbol (format "m-%d" sequence)))

(defun agent-scheme--memory-make-record
    (scope key kind datum &optional existing)
  "Return a canonical memory record for SCOPE, KEY, KIND, and DATUM.
When EXISTING is non-nil, preserve its id and creation sequence."
  (let* ((sequence (agent-scheme--memory-next-sequence))
         (id (or (agent-scheme--memory-record-field existing "id")
                 key
                 (agent-scheme--memory-generated-id sequence)))
         (created-at (or (agent-scheme--memory-record-field existing
                                                            "created-at")
                         (agent-scheme--memory-integer sequence)))
         (tags (agent-scheme--memory-proper-list-or-empty
                (agent-scheme--memory-payload-field datum "tags")
                "memory tags"))
         (value (let ((field (agent-scheme--memory-payload-field datum
                                                                 "value")))
                  (if field field datum)))
         (source (or (agent-scheme--memory-payload-field datum "source")
                     nil))
         (confidence (or (agent-scheme--memory-payload-field datum
                                                             "confidence")
                         (agent-scheme--memory-symbol "unknown"))))
    (list
     (agent-scheme--memory-symbol "memory")
     (agent-scheme--memory-field "id" id)
     (agent-scheme--memory-field "scope" (agent-scheme--memory-symbol scope))
     (agent-scheme--memory-field "key" key)
     (agent-scheme--memory-field "kind" (agent-scheme--memory-symbol kind))
     (agent-scheme--memory-field "tags" tags)
     (agent-scheme--memory-field "value" value)
     (agent-scheme--memory-field "source" source)
     (agent-scheme--memory-field "confidence" confidence)
     (agent-scheme--memory-field "created-at" created-at)
     (agent-scheme--memory-field "updated-at"
                                 (agent-scheme--memory-integer sequence)))))

(defun agent-scheme--memory-current-project-root ()
  "Return the active project root, or `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((session agent-scheme--memory-current-session))
          (and (eq (agent-scheme-session-scope session) 'project)
               (agent-scheme-session-project-root session)))
        (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun agent-scheme--memory-project-key (&optional root)
  "Return canonical project key for ROOT or the current project."
  (file-name-as-directory
   (expand-file-name (or root (agent-scheme--memory-current-project-root)))))

(defun agent-scheme--memory-session-for-subject (subject)
  "Return session for SUBJECT or the dynamically active session."
  (cond
   ((agent-scheme-session-p subject)
    subject)
   (subject
    (agent-scheme-session--require subject))
   (agent-scheme--memory-current-session
    agent-scheme--memory-current-session)
   (t
    (signal 'agent-scheme-memory-error
            (list "session memory requires an active session")))))

(defun agent-scheme--memory-records (scope &optional subject)
  "Return records for SCOPE and optional SUBJECT."
  (pcase (agent-scheme--memory-scope scope)
    ('instance agent-scheme--memory-instance-records)
    ('session
     (agent-scheme-session-memory
      (agent-scheme--memory-session-for-subject subject)))
    ('project
     (gethash (agent-scheme--memory-project-key
               (and subject (file-directory-p subject) subject))
              agent-scheme--memory-project-records))))

(defun agent-scheme--memory-set-records! (scope records &optional subject)
  "Replace records for SCOPE and optional SUBJECT with RECORDS."
  (pcase (agent-scheme--memory-scope scope)
    ('instance
     (setq agent-scheme--memory-instance-records records))
    ('session
     (setf (agent-scheme-session-memory
            (agent-scheme--memory-session-for-subject subject))
           records))
    ('project
     (puthash (agent-scheme--memory-project-key
               (and subject (file-directory-p subject) subject))
              records
              agent-scheme--memory-project-records))))

(defun agent-scheme--memory-find-by-key (records key)
  "Return memory record with KEY from RECORDS."
  (seq-find
   (lambda (record)
     (equal (agent-scheme--memory-record-field record "key") key))
   records))

(defun agent-scheme--memory-replace-record (records record)
  "Return RECORDS with RECORD replacing any record with the same key."
  (cons record
        (seq-remove
         (lambda (candidate)
           (equal (agent-scheme--memory-record-field candidate "key")
                  (agent-scheme--memory-record-field record "key")))
         records)))

(defun agent-scheme--memory-audit (operation scope fields)
  "Record memory OPERATION for SCOPE with FIELDS."
  (agent-scheme-audit-record
   'agent-memory
   (append
    `((category . agent-memory)
      (operation . ,operation)
      (scope . ,scope)
      (decision . completed))
    fields)))

;;;###autoload
(defun agent-scheme-memory-put! (scope key datum &optional subject)
  "Store DATUM under KEY in SCOPE and return its memory record."
  (let* ((normalized-key (agent-scheme--memory-datum-key key))
         (normalized-scope (agent-scheme--memory-scope scope))
         (records (agent-scheme--memory-records normalized-scope subject))
         (existing (agent-scheme--memory-find-by-key records normalized-key))
         (redacted-datum (agent-scheme-redact datum 'memory))
         (record (agent-scheme--memory-make-record
                  normalized-scope
                  normalized-key
                  'datum
                  redacted-datum
                  existing)))
    (agent-scheme--memory-set-records!
     normalized-scope
     (agent-scheme--memory-replace-record records record)
     subject)
    (agent-scheme--memory-audit
     "memory-put!" normalized-scope
     `((key . ,normalized-key)
       (record . ,record)))
    record))

;;;###autoload
(defun agent-scheme-memory-ref (scope key &optional subject)
  "Return memory record from SCOPE by KEY, or nil."
  (agent-scheme--memory-find-by-key
   (agent-scheme--memory-records scope subject)
   (agent-scheme--memory-datum-key key)))

;;;###autoload
(defun agent-scheme-memory-delete! (scope key &optional subject)
  "Delete memory record by KEY from SCOPE and return the deleted record."
  (let* ((normalized-scope (agent-scheme--memory-scope scope))
         (normalized-key (agent-scheme--memory-datum-key key))
         (records (agent-scheme--memory-records normalized-scope subject))
         (record (agent-scheme--memory-find-by-key records normalized-key)))
    (when record
      (agent-scheme--memory-set-records!
       normalized-scope
       (seq-remove
        (lambda (candidate)
          (equal (agent-scheme--memory-record-field candidate "key")
                 normalized-key))
        records)
       subject)
      (agent-scheme--memory-audit
       "memory-delete!" normalized-scope `((key . ,normalized-key))))
    record))

;;;###autoload
(defun agent-scheme-memory-add! (scope kind datum &optional subject)
  "Add a generated memory record of KIND to SCOPE and return it."
  (let* ((normalized-scope (agent-scheme--memory-scope scope))
         (sequence (1+ agent-scheme--memory-next-id))
         (id (agent-scheme--memory-generated-id sequence))
         (redacted-datum (agent-scheme-redact datum 'memory))
         (record (agent-scheme--memory-make-record
                  normalized-scope id kind redacted-datum)))
    (agent-scheme--memory-set-records!
     normalized-scope
     (cons record (agent-scheme--memory-records normalized-scope subject))
     subject)
    (agent-scheme--memory-audit
     "memory-add!" normalized-scope
     `((kind . ,kind)
       (record . ,record)))
    record))

(defun agent-scheme--memory-query-match-p (record query)
  "Return non-nil when RECORD matches QUERY."
  (cond
   ((or (not query) (eq query agent-scheme-true))
    t)
   ((stringp query)
    (string-match-p
     (regexp-quote query)
     (agent-scheme-result->external record)))
   ((agent-scheme-symbol-p query)
    (or (equal query (agent-scheme--memory-record-field record "kind"))
        (equal query (agent-scheme--memory-record-field record "key"))
        (member query (agent-scheme--memory-record-field record "tags"))
        (string-match-p
         (regexp-quote (agent-scheme-symbol-name query))
         (agent-scheme-result->external record))))
   (t
    (equal query record))))

;;;###autoload
(defun agent-scheme-memory-find (scope query &optional subject)
  "Return memory records in SCOPE matching QUERY."
  (let ((normalized-query (agent-scheme--memory-datum-key query)))
    (seq-filter
     (lambda (record)
       (agent-scheme--memory-query-match-p record normalized-query))
     (agent-scheme--memory-records scope subject))))

;;;###autoload
(defun agent-scheme-memory-by-tag (scope tag &optional subject)
  "Return memory records in SCOPE tagged with TAG."
  (let ((normalized-tag (agent-scheme--memory-datum-key tag)))
    (seq-filter
     (lambda (record)
       (member normalized-tag (agent-scheme--memory-record-field record
                                                                 "tags")))
     (agent-scheme--memory-records scope subject))))

;;;###autoload
(defun agent-scheme-memory-recent (scope count &optional subject)
  "Return COUNT newest memory records in SCOPE."
  (let* ((n (max 0 (agent-scheme--memory-integer-value
                   count "memory-recent count")))
         (records (agent-scheme--memory-records scope subject)))
    (cl-subseq records 0 (min n (length records)))))

;;;###autoload
(defun agent-scheme-memory-yield (scope query context &optional subject)
  "Yield memory records from SCOPE matching QUERY through CONTEXT."
  (let ((records (agent-scheme-memory-find scope query subject)))
    (dolist (record records)
      (agent-scheme--record-event!
       context
       (list (agent-scheme--memory-symbol "yield") record)))
    (agent-scheme--memory-audit
     "memory-yield" (agent-scheme--memory-scope scope)
     `((query . ,query)
       (count . ,(length records))))
    records))

;;;###autoload
(defun agent-scheme-memory-clear! (&optional scope subject)
  "Clear memory SCOPE and SUBJECT, or all global memory when SCOPE is nil."
  (if scope
      (pcase (agent-scheme--memory-scope scope)
        ('instance
         (setq agent-scheme--memory-instance-records nil))
        ('session
         (setf (agent-scheme-session-memory
                (agent-scheme--memory-session-for-subject subject))
               nil))
        ('project
         (if subject
             (remhash (agent-scheme--memory-project-key subject)
                      agent-scheme--memory-project-records)
           (clrhash agent-scheme--memory-project-records))))
    (setq agent-scheme--memory-instance-records nil)
    (clrhash agent-scheme--memory-project-records)
    (setq agent-scheme--memory-next-id 0))
  agent-scheme-unspecified)

(defun agent-scheme--memory-storage-file (scope &optional subject)
  "Return private-local storage file for SCOPE and optional SUBJECT."
  (pcase (agent-scheme--memory-scope scope)
    ('instance
     (expand-file-name "instance.scm" agent-scheme-memory-directory))
    ('session
     (expand-file-name
      (concat (agent-scheme--memory-name subject "session id") ".scm")
      (expand-file-name "sessions/" agent-scheme-memory-directory)))
    ('project
     (let* ((root (agent-scheme--memory-project-key subject))
            (hash (secure-hash 'sha1 root)))
       (expand-file-name
        (concat hash ".scm")
        (expand-file-name "projects/" agent-scheme-memory-directory))))))

;;;###autoload
(defun agent-scheme-memory-storage-rules (scope &optional subject)
  "Return safe storage rules for SCOPE and optional SUBJECT."
  (let* ((normalized-scope (agent-scheme--memory-scope scope))
         (project-root (and (eq normalized-scope 'project)
                            (agent-scheme--memory-project-key subject)))
         (tracked-file (and project-root
                            (expand-file-name
                             agent-scheme-memory-project-tracked-file
                             project-root))))
    (append
     (list
      (agent-scheme--memory-symbol "memory-storage")
      (agent-scheme--memory-field "scope"
                                  (agent-scheme--memory-symbol
                                   normalized-scope))
      (agent-scheme--memory-field "mode"
                                  (agent-scheme--memory-symbol
                                   "private-local"))
      (agent-scheme--memory-field
       "private-file"
       (agent-scheme--memory-storage-file normalized-scope subject)))
     (when project-root
       (list
        (agent-scheme--memory-field "project-root" project-root)
        (agent-scheme--memory-field "tracked-file" tracked-file)
        (agent-scheme--memory-field
         "tracked-enabled"
         (if agent-scheme-memory-project-tracked-enabled
             agent-scheme-true
           agent-scheme-false))
        (agent-scheme--memory-field "public-repository-safe"
                                    agent-scheme-true))))))

;;;###autoload
(defun agent-scheme-memory-scope-datum (scope &optional subject)
  "Return SCOPE memory as an inspectable Scheme-readable datum."
  (let ((normalized-scope (agent-scheme--memory-scope scope)))
    (append
     (list
      (agent-scheme--memory-symbol "agent-memory")
      (agent-scheme--memory-field "scope"
                                  (agent-scheme--memory-symbol
                                   normalized-scope)))
     (pcase normalized-scope
       ('session
        (let ((session (agent-scheme--memory-session-for-subject subject)))
          (list
           (agent-scheme--memory-field
            "session"
            (agent-scheme--memory-symbol
             (agent-scheme-session-id session))))))
       ('project
        (list
         (agent-scheme--memory-field
          "storage"
          (agent-scheme-memory-storage-rules normalized-scope subject))))
       (_ nil))
     (list
      (agent-scheme--memory-field
       "records"
       (agent-scheme--memory-records normalized-scope subject))))))

(defun agent-scheme--memory-buffer-label (scope subject)
  "Return buffer label for SCOPE and SUBJECT."
  (pcase (agent-scheme--memory-scope scope)
    ('instance "instance")
    ('session
     (format "session: %s"
             (if subject
                 (agent-scheme--memory-name subject "session id")
               (agent-scheme-session-id
                (agent-scheme--memory-session-for-subject nil)))))
    ('project
     (format "project: %s"
             (or subject
                 (file-name-nondirectory
                  (directory-file-name
                   (agent-scheme--memory-project-key nil))))))))

;;;###autoload
(defun agent-scheme-memory-open (scope &optional subject)
  "Open editable memory buffer for SCOPE and optional SUBJECT."
  (interactive
   (list (intern
          (completing-read "Memory scope: "
                           '("instance" "session" "project")
                           nil t nil nil "instance"))
         nil))
  (let* ((label (agent-scheme--memory-buffer-label scope subject))
         (buffer (get-buffer-create
                  (format "*Agent Memory: %s*" label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (agent-scheme-result->external
          (agent-scheme-memory-scope-datum
           scope
           (pcase (agent-scheme--memory-scope scope)
             ('project
              (and subject (file-directory-p subject) subject))
             (_ subject)))))
        (insert "\n"))
      (goto-char (point-min))
      (agent-scheme-memory-mode)
      (setq-local agent-scheme--memory-buffer-scope
                  (agent-scheme--memory-scope scope))
      (setq-local agent-scheme--memory-buffer-subject subject))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun agent-scheme--memory-scope-datum-records (datum)
  "Return memory records field from scope DATUM."
  (or (agent-scheme--memory-record-field datum "records")
      (signal 'agent-scheme-memory-error
              (list "memory buffer datum must contain records"))))

;;;###autoload
(defun agent-scheme-memory-apply-buffer ()
  "Apply the current editable memory buffer back to its scoped store."
  (interactive)
  (let ((datum (agent-scheme-read (current-buffer)))
        (scope agent-scheme--memory-buffer-scope)
        (subject agent-scheme--memory-buffer-subject))
    (agent-scheme--memory-set-records!
     scope
     (agent-scheme--memory-scope-datum-records datum)
     subject)
    agent-scheme-unspecified))

;;;###autoload
(defun agent-scheme-memory-save! (scope &optional subject)
  "Persist SCOPE memory to its private-local storage file."
  (let ((file (agent-scheme--memory-storage-file scope subject)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert
       (agent-scheme-result->external
        (agent-scheme-memory-scope-datum scope subject)))
      (insert "\n"))
    file))

;;;###autoload
(defun agent-scheme-memory-load! (scope &optional subject)
  "Load SCOPE memory from its private-local storage file."
  (let ((file (agent-scheme--memory-storage-file scope subject)))
    (unless (file-readable-p file)
      (signal 'agent-scheme-memory-error
              (list (format "memory file is not readable: %s" file))))
    (let ((datum (agent-scheme-read
                  (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))))
      (agent-scheme--memory-set-records!
       scope
       (agent-scheme--memory-scope-datum-records datum)
       subject)
      (agent-scheme--memory-records scope subject))))

(defun agent-scheme--memory-primitive-put (arguments _context)
  "Primitive memory-put! over ARGUMENTS."
  (agent-scheme-memory-put! (car arguments) (cadr arguments) (caddr arguments)))

(defun agent-scheme--memory-primitive-ref (arguments _context)
  "Primitive memory-ref over ARGUMENTS."
  (or (agent-scheme-memory-ref (car arguments) (cadr arguments))
      agent-scheme-false))

(defun agent-scheme--memory-primitive-delete (arguments _context)
  "Primitive memory-delete! over ARGUMENTS."
  (or (agent-scheme-memory-delete! (car arguments) (cadr arguments))
      agent-scheme-false))

(defun agent-scheme--memory-primitive-add (arguments _context)
  "Primitive memory-add! over ARGUMENTS."
  (agent-scheme-memory-add! (car arguments) (cadr arguments) (caddr arguments)))

(defun agent-scheme--memory-primitive-find (arguments _context)
  "Primitive memory-find over ARGUMENTS."
  (agent-scheme-memory-find (car arguments) (cadr arguments)))

(defun agent-scheme--memory-primitive-by-tag (arguments _context)
  "Primitive memory-by-tag over ARGUMENTS."
  (agent-scheme-memory-by-tag (car arguments) (cadr arguments)))

(defun agent-scheme--memory-primitive-recent (arguments _context)
  "Primitive memory-recent over ARGUMENTS."
  (agent-scheme-memory-recent (car arguments) (cadr arguments)))

(defun agent-scheme--memory-primitive-yield (arguments context)
  "Primitive memory-yield over ARGUMENTS."
  (agent-scheme-memory-yield (car arguments) (cadr arguments) context))

;;;###autoload
(defun agent-scheme-memory-primitive-specs ()
  "Return primitive specs for the `(agent memory)' library."
  `(("memory-put!" ,#'agent-scheme--memory-primitive-put 3 3)
    ("memory-ref" ,#'agent-scheme--memory-primitive-ref 2 2)
    ("memory-delete!" ,#'agent-scheme--memory-primitive-delete 2 2)
    ("memory-add!" ,#'agent-scheme--memory-primitive-add 3 3)
    ("memory-find" ,#'agent-scheme--memory-primitive-find 2 2)
    ("memory-by-tag" ,#'agent-scheme--memory-primitive-by-tag 2 2)
    ("memory-recent" ,#'agent-scheme--memory-primitive-recent 2 2)
    ("memory-yield" ,#'agent-scheme--memory-primitive-yield 2 2)))

(provide 'agent-scheme-memory)

;;; agent-scheme-memory.el ends here
