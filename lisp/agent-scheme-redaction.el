;;; agent-scheme-redaction.el --- Secrets and redaction policy  -*- lexical-binding: t; -*-

;;; Commentary:

;; Secrets, local-only context, and redaction decisions are represented as
;; Scheme-readable datums.  This module is host-neutral policy plumbing: callers
;; at persistence, audit, provider, and skill boundaries decide when to apply it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)

(defgroup agent-scheme-redaction nil
  "Secrets, local-only context, and redaction policy for Agent Scheme."
  :group 'agent-scheme)

(defcustom agent-scheme-redaction-replacement "[redacted]"
  "Replacement text used when a secret value is removed."
  :type 'string
  :group 'agent-scheme-redaction)

(defcustom agent-scheme-redaction-local-only-replacement "[local-only]"
  "Replacement text used when local-only context is withheld."
  :type 'string
  :group 'agent-scheme-redaction)

(defcustom agent-scheme-redaction-maximum-log-entries 200
  "Maximum number of recent redaction decisions kept in memory."
  :type 'integer
  :group 'agent-scheme-redaction)

(defconst agent-scheme-redaction-secret-prone-sources
  '(env
    environment
    auth-source
    local-config
    provider-credentials
    provider-credential
    private-buffer
    shell-output
    process-output
    vcs-remote
    transcript
    memory
    audit-log
    skill-resource)
  "Source labels that often carry secrets or private context.")

(defconst agent-scheme-redaction-sensitive-field-patterns
  '("api[_-]?key"
    "auth"
    "authorization"
    "bearer"
    "credential"
    "login"
    "oauth"
    "passphrase"
    "password"
    "private[_-]?key"
    "secret"
    "session[_-]?cookie"
    "token")
  "Case-insensitive regexps for names that identify sensitive fields.")

(defconst agent-scheme-redaction-secret-value-patterns
  '("sk-[A-Za-z0-9_-]\\{8,\\}"
    "gh[pousr]_[A-Za-z0-9_]+"
    "xox[baprs]-[A-Za-z0-9-]\\{8,\\}"
    "AKIA[0-9A-Z]\\{12,\\}"
    "-----BEGIN [A-Z ]*PRIVATE KEY-----")
  "Regexps for common secret value spellings.")

(defvar agent-scheme--redaction-log nil
  "Most-recent-first list of Scheme-readable redaction records.")

(defun agent-scheme-redaction--symbol-name (value)
  "Return VALUE as a plain symbol name string, or nil."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun agent-scheme-redaction--symbol (name)
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

(defun agent-scheme-redaction--field (name value)
  "Return a Scheme-readable redaction field named NAME with VALUE."
  (list (agent-scheme-redaction--symbol name) value))

(defun agent-scheme-redaction--field-entry-value (field)
  "Return FIELD's value from a record field or dotted association."
  (let ((rest (cdr field)))
    (if (and (consp rest) (null (cdr rest)))
        (car rest)
      rest)))

(defun agent-scheme-redaction--source-value (source)
  "Return SOURCE normalized for a redaction record."
  (if-let ((name (agent-scheme-redaction--symbol-name source)))
      (agent-scheme-redaction--symbol name)
    "unknown"))

(defun agent-scheme-redaction--field-value (datum name)
  "Return field NAME from Scheme-readable DATUM, or nil."
  (when (consp datum)
    (let ((fields (agent-scheme-redaction--field-values datum))
          value)
      (dolist (field fields value)
        (when (equal (agent-scheme-redaction--symbol-name (car field))
                     name)
          (setq value
                (agent-scheme-redaction--field-entry-value field)))))))

(defun agent-scheme-redaction--field-values (datum)
  "Return field pairs from Scheme-readable DATUM."
  (when (consp datum)
    (let ((fields (if (and (consp (car datum))
                           (agent-scheme-redaction--symbol-name
                            (caar datum)))
                      datum
                    (cdr datum))))
      (seq-filter
       (lambda (field)
         (and (consp field)
              (agent-scheme-redaction--symbol-name (car field))))
       fields))))

(defun agent-scheme-redaction--record-head (datum)
  "Return DATUM's record head name, or nil."
  (and (consp datum)
       (not (and (consp (car datum))
                 (agent-scheme-redaction--symbol-name (caar datum))))
       (agent-scheme-redaction--symbol-name (car datum))))

(defun agent-scheme-redaction--redaction-record-p (datum)
  "Return non-nil when DATUM is already a redaction record."
  (member (agent-scheme-redaction--record-head datum)
          '("redaction" "redaction-log")))

(defun agent-scheme-redaction--truthy-p (value)
  "Return non-nil when VALUE is true in Agent Scheme data."
  (not (or (null value) (eq value agent-scheme-false))))

(defun agent-scheme-redaction--sensitive-name-p (name)
  "Return non-nil if NAME looks like a credential-bearing field."
  (when name
    (let ((case-fold-search t))
      (seq-some
       (lambda (pattern)
         (string-match-p pattern name))
       agent-scheme-redaction-sensitive-field-patterns))))

(defun agent-scheme-redaction--secret-string-p (text)
  "Return non-nil when TEXT contains a recognizable secret."
  (and (stringp text)
       (seq-some
        (lambda (pattern)
          (string-match-p pattern text))
        agent-scheme-redaction-secret-value-patterns)))

(defun agent-scheme-redaction--redact-string (text)
  "Return TEXT with recognizable secret substrings removed."
  (let ((redacted text)
        (changed nil))
    (dolist (pattern agent-scheme-redaction-secret-value-patterns)
      (when (string-match-p pattern redacted)
        (setq changed t)
        (setq redacted
              (replace-regexp-in-string
               pattern
               agent-scheme-redaction-replacement
               redacted t t))))
    (when changed
      (agent-scheme-redaction--remember
       (agent-scheme-redaction--make-record 'secret 'string "value"
                                            'local-only)))
    redacted))

(defun agent-scheme-redaction--source-name (datum)
  "Return the best source label for DATUM."
  (let* ((head (agent-scheme-redaction--record-head datum))
         (source-field (agent-scheme-redaction--field-value datum "source"))
         (source-name
          (cond
           ((consp source-field)
            (agent-scheme-redaction--symbol-name (car source-field)))
           (source-field
            (agent-scheme-redaction--symbol-name source-field))
           ((and head
                 (member (intern-soft head)
                         agent-scheme-redaction-secret-prone-sources))
            head)
           ((and (equal head "buffer")
                 (agent-scheme-redaction--truthy-p
                  (agent-scheme-redaction--field-value datum "private")))
            "private-buffer")
           (t nil))))
    source-name))

(defun agent-scheme-redaction--source-secret-prone-p (source-name)
  "Return non-nil if SOURCE-NAME is a secret-prone source."
  (and source-name
       (memq (intern-soft source-name)
             agent-scheme-redaction-secret-prone-sources)))

(defun agent-scheme-redaction--record-sensitive-field-name (datum)
  "Return the sensitive field name in DATUM, or nil."
  (or
   (let ((field (agent-scheme-redaction--field-value datum "field")))
     (and (agent-scheme-redaction--sensitive-name-p
           (agent-scheme-redaction--symbol-name field))
          (agent-scheme-redaction--symbol-name field)))
   (seq-some
    (lambda (field)
      (let ((name (agent-scheme-redaction--symbol-name (car field))))
        (and (agent-scheme-redaction--sensitive-name-p name) name)))
    (agent-scheme-redaction--field-values datum))))

(defun agent-scheme-redaction--record-secret-value-p (datum)
  "Return non-nil when any string field in DATUM looks secret."
  (seq-some
   (lambda (field)
     (agent-scheme-redaction--secret-string-p
      (agent-scheme-redaction--field-entry-value field)))
   (agent-scheme-redaction--field-values datum)))

(defun agent-scheme-redaction--self-secret-source-p (datum)
  "Return non-nil if DATUM itself describes a secret-prone source."
  (and (consp datum)
       (not (agent-scheme-redaction--redaction-record-p datum))
       (let* ((source-name (agent-scheme-redaction--source-name datum))
              (sensitive-field
               (agent-scheme-redaction--record-sensitive-field-name datum)))
         (or
          (and (equal source-name "auth-source")
               sensitive-field)
          (and (member source-name '("provider-credentials"
                                     "provider-credential"
                                     "private-buffer"))
               (or sensitive-field
                   (agent-scheme-redaction--record-secret-value-p datum)
                   (equal source-name "private-buffer")))
          (and (agent-scheme-redaction--source-secret-prone-p source-name)
               (or sensitive-field
                   (agent-scheme-redaction--record-secret-value-p datum)))))))

(defun agent-scheme-redaction--local-only-self-p (datum)
  "Return non-nil when DATUM itself is marked local-only."
  (or (equal (agent-scheme-redaction--record-head datum) "local-only")
      (and (consp datum)
           (agent-scheme-redaction--truthy-p
            (agent-scheme-redaction--field-value datum "local-only")))))

(defun agent-scheme-redaction-local-only-p (datum)
  "Return non-nil when DATUM contains local-only context."
  (cond
   ((agent-scheme-redaction--redaction-record-p datum)
    nil)
   ((consp datum)
    (or (agent-scheme-redaction--local-only-self-p datum)
        (agent-scheme-redaction-local-only-p (car datum))
        (agent-scheme-redaction-local-only-p (cdr datum))))
   ((vectorp datum)
    (seq-some #'agent-scheme-redaction-local-only-p (append datum nil)))
   (t nil)))

;;;###autoload
(defun agent-scheme-secret-source-p (datum)
  "Return non-nil when DATUM contains secret-prone source data."
  (cond
   ((agent-scheme-redaction--redaction-record-p datum)
    nil)
   ((stringp datum)
    (agent-scheme-redaction--secret-string-p datum))
   ((consp datum)
    (or (agent-scheme-redaction--self-secret-source-p datum)
        (agent-scheme-secret-source-p (car datum))
        (agent-scheme-secret-source-p (cdr datum))))
   ((vectorp datum)
    (seq-some #'agent-scheme-secret-source-p (append datum nil)))
   (t nil)))

(defun agent-scheme-redaction--make-record (kind source field policy)
  "Return a Scheme-readable redaction record."
  (list
   (agent-scheme-redaction--symbol "redaction")
   (agent-scheme-redaction--field "kind"
                                  (agent-scheme-redaction--symbol kind))
   (agent-scheme-redaction--field
    "source" (agent-scheme-redaction--source-value source))
   (agent-scheme-redaction--field
    "field" (if field (format "%s" field) "value"))
   (agent-scheme-redaction--field
    "replacement" agent-scheme-redaction-replacement)
   (agent-scheme-redaction--field
    "policy" (agent-scheme-redaction--symbol policy))))

(defun agent-scheme-redaction--make-local-only-record (reason)
  "Return a Scheme-readable local-only redaction record for REASON."
  (list
   (agent-scheme-redaction--symbol "redaction")
   (agent-scheme-redaction--field "kind"
                                  (agent-scheme-redaction--symbol
                                   "local-only"))
   (agent-scheme-redaction--field "source"
                                  (agent-scheme-redaction--symbol
                                   "local-only"))
   (agent-scheme-redaction--field "field" "datum")
   (agent-scheme-redaction--field
    "replacement" agent-scheme-redaction-local-only-replacement)
   (agent-scheme-redaction--field "policy"
                                  (agent-scheme-redaction--symbol
                                   "local-only"))
   (agent-scheme-redaction--field "reason" reason)))

(defun agent-scheme-redaction--remember (record)
  "Store redaction RECORD in the in-memory decision log."
  (push record agent-scheme--redaction-log)
  (when (and (integerp agent-scheme-redaction-maximum-log-entries)
             (> agent-scheme-redaction-maximum-log-entries 0))
    (let ((tail (nthcdr (1- agent-scheme-redaction-maximum-log-entries)
                        agent-scheme--redaction-log)))
      (when tail
        (setcdr tail nil))))
  record)

(defun agent-scheme-redaction--record-for-datum (datum)
  "Return a redaction record describing DATUM."
  (let* ((source-name (or (agent-scheme-redaction--source-name datum)
                          "unknown"))
         (field-name (or (agent-scheme-redaction--record-sensitive-field-name
                          datum)
                         (agent-scheme-redaction--symbol-name
                          (agent-scheme-redaction--field-value datum "field"))
                         "value"))
         (record (agent-scheme-redaction--make-record
                  'secret source-name field-name 'local-only)))
    (agent-scheme-redaction--remember record)))

;;;###autoload
(defun agent-scheme-redact (datum &optional _policy)
  "Return DATUM with secrets and local-only content redacted.
Redaction decisions are recorded in `agent-scheme-redaction-log' as
Scheme-readable records.  The optional _POLICY argument is accepted
for Scheme API compatibility; secret redactions remain local-only by
default."
  (cond
   ((agent-scheme-redaction--redaction-record-p datum)
    datum)
   ((stringp datum)
    (agent-scheme-redaction--redact-string datum))
   ((agent-scheme-redaction--self-secret-source-p datum)
    (agent-scheme-redaction--record-for-datum datum))
   ((agent-scheme-redaction--local-only-self-p datum)
    (let* ((reason (or (agent-scheme-redaction--field-value datum "reason")
                       "local-only context"))
           (record (agent-scheme-redaction--make-local-only-record reason)))
      (agent-scheme-redaction--remember record)
      (list
       (agent-scheme-redaction--symbol "local-only")
       (agent-scheme-redaction--field "reason" reason)
       (agent-scheme-redaction--field
        "datum" agent-scheme-redaction-local-only-replacement))))
   ((consp datum)
    (cons (agent-scheme-redact (car datum))
          (agent-scheme-redact (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'agent-scheme-redact (append datum nil))))
   (t datum)))

;;;###autoload
(defun agent-scheme-context-local-only! (datum reason)
  "Return DATUM wrapped as local-only context for REASON."
  (let ((record
         (list
          (agent-scheme-redaction--symbol "local-only")
          (agent-scheme-redaction--field "reason" reason)
          (agent-scheme-redaction--field "datum" datum))))
    (agent-scheme-redaction--remember
     (agent-scheme-redaction--make-local-only-record reason))
    record))

;;;###autoload
(defun agent-scheme-redaction-log (&optional _options)
  "Return recent redaction decisions as a Scheme-readable datum."
  (list
   (agent-scheme-redaction--symbol "redaction-log")
   (agent-scheme-redaction--field "records"
                                  agent-scheme--redaction-log)))

;;;###autoload
(defun agent-scheme-redaction-clear! ()
  "Clear the in-memory redaction decision log."
  (setq agent-scheme--redaction-log nil)
  agent-scheme-unspecified)

;;;###autoload
(defun agent-scheme-safe-for-provider-p (datum _provider &optional _policy)
  "Return non-nil when DATUM can be routed to _PROVIDER without redaction."
  (not (or (agent-scheme-secret-source-p datum)
           (agent-scheme-redaction-local-only-p datum))))

(defun agent-scheme-redaction--boolean (value)
  "Return Agent Scheme boolean for VALUE."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme-redaction--primitive-secret-source-p (arguments _context)
  "Primitive secret-source? over ARGUMENTS."
  (agent-scheme-redaction--boolean
   (agent-scheme-secret-source-p (car arguments))))

(defun agent-scheme-redaction--primitive-redact (arguments _context)
  "Primitive redact over ARGUMENTS."
  (agent-scheme-redact (car arguments) (cadr arguments)))

(defun agent-scheme-redaction--primitive-context-local-only (arguments _context)
  "Primitive context-local-only! over ARGUMENTS."
  (agent-scheme-context-local-only! (car arguments) (cadr arguments)))

(defun agent-scheme-redaction--primitive-redaction-log (arguments _context)
  "Primitive redaction-log over ARGUMENTS."
  (agent-scheme-redaction-log (car arguments)))

(defun agent-scheme-redaction--primitive-safe-for-provider-p (arguments _context)
  "Primitive safe-for-provider? over ARGUMENTS."
  (agent-scheme-redaction--boolean
   (agent-scheme-safe-for-provider-p (car arguments) (cadr arguments))))

;;;###autoload
(defun agent-scheme-redaction-primitive-specs ()
  "Return primitive specs for the `(agent redaction)' library."
  `(("secret-source?" ,#'agent-scheme-redaction--primitive-secret-source-p 1 1)
    ("redact" ,#'agent-scheme-redaction--primitive-redact 2 2)
    ("context-local-only!" ,#'agent-scheme-redaction--primitive-context-local-only 2 2)
    ("redaction-log" ,#'agent-scheme-redaction--primitive-redaction-log 0 1)
    ("safe-for-provider?" ,#'agent-scheme-redaction--primitive-safe-for-provider-p 2 2)))

(provide 'agent-scheme-redaction)

;;; agent-scheme-redaction.el ends here
