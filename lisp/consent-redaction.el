;;; consent-redaction.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Secrets, local-only context, and redaction decisions are represented as
;; Scheme-readable datums. This module is host-neutral policy plumbing: callers
;; at persistence, audit, provider, and skill boundaries decide when to apply
;; it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'consent-reader)
(require 'consent-runtime)

(defgroup consent-redaction nil
  "Secrets, local-only context, and redaction policy for Consent Scheme."
  :group 'consent)

(defcustom consent-redaction-replacement "[redacted]"
  "Replacement text used when a secret value is removed."
  :type 'string
  :group 'consent-redaction)

(defcustom consent-redaction-local-only-replacement "[local-only]"
  "Replacement text used when local-only context is withheld."
  :type 'string
  :group 'consent-redaction)

(defcustom consent-redaction-maximum-log-entries 200
  "Maximum number of recent redaction decisions kept in memory."
  :type 'integer
  :group 'consent-redaction)

(defconst consent-redaction-secret-prone-sources
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

(defconst consent-redaction-sensitive-field-patterns
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

(defconst consent-redaction-secret-value-patterns
  '("sk-[A-Za-z0-9_-]\\{8,\\}"
    "gh[pousr]_[A-Za-z0-9_]+"
    "xox[baprs]-[A-Za-z0-9-]\\{8,\\}"
    "AKIA[0-9A-Z]\\{12,\\}"
    "-----BEGIN [A-Z ]*PRIVATE KEY-----")
  "Regexps for common secret value spellings.")

(defvar consent--redaction-log nil
  "Most-recent-first list of Scheme-readable redaction records.")

(defun consent-redaction--symbol-name (value)
  "Return VALUE as a plain symbol name string, or nil."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun consent-redaction--symbol (name)
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

(defun consent-redaction--field (name value)
  "Return a Scheme-readable redaction field named NAME with VALUE."
  (list (consent-redaction--symbol name) value))

(defun consent-redaction--field-entry-value (field)
  "Return FIELD's value from a record field or dotted association."
  (let ((rest (cdr field)))
    (if (and (consp rest) (null (cdr rest)))
        (car rest)
      rest)))

(defun consent-redaction--source-value (source)
  "Return SOURCE normalized for a redaction record."
  (if-let ((name (consent-redaction--symbol-name source)))
      (consent-redaction--symbol name)
    "unknown"))

(defun consent-redaction--field-value (datum name)
  "Return field NAME from Scheme-readable DATUM, or nil."
  (when (consp datum)
    (let ((fields (consent-redaction--field-values datum))
          value)
      (dolist (field fields value)
        (when (equal (consent-redaction--symbol-name (car field))
                     name)
          (setq value
                (consent-redaction--field-entry-value field)))))))

(defun consent-redaction--field-values (datum)
  "Return field pairs from Scheme-readable DATUM."
  (when (consp datum)
    (let ((fields (if (and (consp (car datum))
                           (consent-redaction--symbol-name
                            (caar datum)))
                      datum
                    (cdr datum))))
      (when (consent--proper-list-p fields)
        (seq-filter
         (lambda (field)
           (and (consp field)
                (consent-redaction--symbol-name (car field))))
         fields)))))

(defun consent-redaction--record-head (datum)
  "Return DATUM's record head name, or nil."
  (and (consp datum)
       (not (and (consp (car datum))
                 (consent-redaction--symbol-name (caar datum))))
       (consent-redaction--symbol-name (car datum))))

(defun consent-redaction--redaction-record-p (datum)
  "Return non-nil when DATUM is already a redaction record."
  (member (consent-redaction--record-head datum)
          '("redaction" "redaction-log")))

(defun consent-redaction--truthy-p (value)
  "Return non-nil when VALUE is true in Consent Scheme data."
  (not (or (null value) (eq value consent-false))))

(defun consent-redaction--sensitive-name-p (name)
  "Return non-nil if NAME looks like a credential-bearing field."
  (when name
    (let ((case-fold-search t))
      (seq-some
       (lambda (pattern)
         (string-match-p pattern name))
       consent-redaction-sensitive-field-patterns))))

(defun consent-redaction--secret-string-p (text)
  "Return non-nil when TEXT contains a recognizable secret."
  (and (stringp text)
       (seq-some
        (lambda (pattern)
          (string-match-p pattern text))
        consent-redaction-secret-value-patterns)))

(defun consent-redaction--redact-string (text)
  "Return TEXT with recognizable secret substrings removed."
  (let ((redacted text)
        (changed nil))
    (dolist (pattern consent-redaction-secret-value-patterns)
      (when (string-match-p pattern redacted)
        (setq changed t)
        (setq redacted
              (replace-regexp-in-string
               pattern
               consent-redaction-replacement
               redacted t t))))
    (when changed
      (consent-redaction--remember
       (consent-redaction--make-record 'secret 'string "value"
                                            'local-only)))
    redacted))

(defun consent-redaction--source-name (datum)
  "Return the best source label for DATUM."
  (let* ((head (consent-redaction--record-head datum))
         (source-field (consent-redaction--field-value datum "source"))
         (source-name
          (cond
           ((consp source-field)
            (consent-redaction--symbol-name (car source-field)))
           (source-field
            (consent-redaction--symbol-name source-field))
           ((and head
                 (member (intern-soft head)
                         consent-redaction-secret-prone-sources))
            head)
           ((and (equal head "buffer")
                 (consent-redaction--truthy-p
                  (consent-redaction--field-value datum "private")))
            "private-buffer")
           (t nil))))
    source-name))

(defun consent-redaction--source-secret-prone-p (source-name)
  "Return non-nil if SOURCE-NAME is a secret-prone source."
  (and source-name
       (memq (intern-soft source-name)
             consent-redaction-secret-prone-sources)))

(defun consent-redaction--record-sensitive-field-name (datum)
  "Return the sensitive field name in DATUM, or nil."
  (or
   (let ((field (consent-redaction--field-value datum "field")))
     (and (consent-redaction--sensitive-name-p
           (consent-redaction--symbol-name field))
          (consent-redaction--symbol-name field)))
   (seq-some
    (lambda (field)
      (let ((name (consent-redaction--symbol-name (car field))))
        (and (consent-redaction--sensitive-name-p name) name)))
    (consent-redaction--field-values datum))))

(defun consent-redaction--record-secret-value-p (datum)
  "Return non-nil when any string field in DATUM looks secret."
  (seq-some
   (lambda (field)
     (consent-redaction--secret-string-p
      (consent-redaction--field-entry-value field)))
   (consent-redaction--field-values datum)))

(defun consent-redaction--self-secret-source-p (datum)
  "Return non-nil if DATUM itself describes a secret-prone source."
  (and (consp datum)
       (not (consent-redaction--redaction-record-p datum))
       (let* ((source-name (consent-redaction--source-name datum))
              (sensitive-field
               (consent-redaction--record-sensitive-field-name datum)))
         (or
          (and (equal source-name "auth-source")
               sensitive-field)
          (and (member source-name '("provider-credentials"
                                     "provider-credential"
                                     "private-buffer"))
               (or sensitive-field
                   (consent-redaction--record-secret-value-p datum)
                   (equal source-name "private-buffer")))
          (and (consent-redaction--source-secret-prone-p source-name)
               (or sensitive-field
                   (consent-redaction--record-secret-value-p datum)))))))

(defun consent-redaction--local-only-self-p (datum)
  "Return non-nil when DATUM itself is marked local-only."
  (or (equal (consent-redaction--record-head datum) "local-only")
      (and (consp datum)
           (consent-redaction--truthy-p
            (consent-redaction--field-value datum "local-only")))))

(defun consent-redaction-local-only-p (datum)
  "Return non-nil when DATUM contains local-only context."
  (cond
   ((consent-redaction--redaction-record-p datum)
    nil)
   ((consp datum)
    (or (consent-redaction--local-only-self-p datum)
        (consent-redaction-local-only-p (car datum))
        (consent-redaction-local-only-p (cdr datum))))
   ((vectorp datum)
    (seq-some #'consent-redaction-local-only-p (append datum nil)))
   (t nil)))

;;;###autoload
(defun consent-secret-source-p (datum)
  "Return non-nil when DATUM contains secret-prone source data."
  (cond
   ((consent-redaction--redaction-record-p datum)
    nil)
   ((stringp datum)
    (consent-redaction--secret-string-p datum))
   ((consp datum)
    (or (consent-redaction--self-secret-source-p datum)
        (consent-secret-source-p (car datum))
        (consent-secret-source-p (cdr datum))))
   ((vectorp datum)
    (seq-some #'consent-secret-source-p (append datum nil)))
   (t nil)))

(defun consent-redaction--make-record (kind source field policy)
  "Return a Scheme-readable redaction record."
  (list
   (consent-redaction--symbol "redaction")
   (consent-redaction--field "kind"
                                  (consent-redaction--symbol kind))
   (consent-redaction--field
    "source" (consent-redaction--source-value source))
   (consent-redaction--field
    "field" (if field (format "%s" field) "value"))
   (consent-redaction--field
    "replacement" consent-redaction-replacement)
   (consent-redaction--field
    "policy" (consent-redaction--symbol policy))))

(defun consent-redaction--make-local-only-record (reason)
  "Return a Scheme-readable local-only redaction record for REASON."
  (list
   (consent-redaction--symbol "redaction")
   (consent-redaction--field "kind"
                                  (consent-redaction--symbol
                                   "local-only"))
   (consent-redaction--field "source"
                                  (consent-redaction--symbol
                                   "local-only"))
   (consent-redaction--field "field" "datum")
   (consent-redaction--field
    "replacement" consent-redaction-local-only-replacement)
   (consent-redaction--field "policy"
                                  (consent-redaction--symbol
                                   "local-only"))
   (consent-redaction--field "reason" reason)))

(defun consent-redaction--remember (record)
  "Store redaction RECORD in the in-memory decision log."
  (push record consent--redaction-log)
  (when (and (integerp consent-redaction-maximum-log-entries)
             (> consent-redaction-maximum-log-entries 0))
    (let ((tail (nthcdr (1- consent-redaction-maximum-log-entries)
                        consent--redaction-log)))
      (when tail
        (setcdr tail nil))))
  record)

(defun consent-redaction--record-for-datum (datum)
  "Return a redaction record describing DATUM."
  (let* ((source-name (or (consent-redaction--source-name datum)
                          "unknown"))
         (field-name (or (consent-redaction--record-sensitive-field-name
                          datum)
                         (consent-redaction--symbol-name
                          (consent-redaction--field-value datum "field"))
                         "value"))
         (record (consent-redaction--make-record
                  'secret source-name field-name 'local-only)))
    (consent-redaction--remember record)))

;;;###autoload
(defun consent-redact (datum &optional _policy)
  "Return DATUM with secrets and local-only content redacted.
Redaction decisions are recorded in `consent-redaction-log' as
Scheme-readable records.  The optional _POLICY argument is accepted
for Scheme API compatibility; secret redactions remain local-only by
default."
  (cond
   ((consent-redaction--redaction-record-p datum)
    datum)
   ((stringp datum)
    (consent-redaction--redact-string datum))
   ((consent-redaction--self-secret-source-p datum)
    (consent-redaction--record-for-datum datum))
   ((consent-redaction--local-only-self-p datum)
    (let* ((reason (or (consent-redaction--field-value datum "reason")
                       "local-only context"))
           (record (consent-redaction--make-local-only-record reason)))
      (consent-redaction--remember record)
      (list
       (consent-redaction--symbol "local-only")
       (consent-redaction--field "reason" reason)
       (consent-redaction--field
        "datum" consent-redaction-local-only-replacement))))
   ((consp datum)
    (cons (consent-redact (car datum))
          (consent-redact (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'consent-redact (append datum nil))))
   (t datum)))

;;;###autoload
(defun consent-context-local-only! (datum reason)
  "Return DATUM wrapped as local-only context for REASON."
  (let ((record
         (list
          (consent-redaction--symbol "local-only")
          (consent-redaction--field "reason" reason)
          (consent-redaction--field "datum" datum))))
    (consent-redaction--remember
     (consent-redaction--make-local-only-record reason))
    record))

;;;###autoload
(defun consent-redaction-log (&optional _options)
  "Return recent redaction decisions as a Scheme-readable datum."
  (list
   (consent-redaction--symbol "redaction-log")
   (consent-redaction--field "records"
                                  consent--redaction-log)))

;;;###autoload
(defun consent-redaction-clear! ()
  "Clear the in-memory redaction decision log."
  (setq consent--redaction-log nil)
  consent-unspecified)

;;;###autoload
(defun consent-safe-for-provider-p (datum _provider &optional _policy)
  "Return non-nil when DATUM can be routed to _PROVIDER without redaction."
  (not (or (consent-secret-source-p datum)
           (consent-redaction-local-only-p datum))))

(defun consent-redaction--boolean (value)
  "Return Consent Scheme boolean for VALUE."
  (if value consent-true consent-false))

(defun consent-redaction--primitive-secret-source-p (arguments _context)
  "Primitive secret-source? over ARGUMENTS."
  (consent-redaction--boolean
   (consent-secret-source-p (car arguments))))

(defun consent-redaction--primitive-redact (arguments _context)
  "Primitive redact over ARGUMENTS."
  (consent-redact (car arguments) (cadr arguments)))

(defun consent-redaction--primitive-context-local-only (arguments _context)
  "Primitive context-local-only! over ARGUMENTS."
  (consent-context-local-only! (car arguments) (cadr arguments)))

(defun consent-redaction--primitive-redaction-log (arguments _context)
  "Primitive redaction-log over ARGUMENTS."
  (consent-redaction-log (car arguments)))

(defun consent-redaction--primitive-safe-for-provider-p (arguments _context)
  "Primitive safe-for-provider? over ARGUMENTS."
  (consent-redaction--boolean
   (consent-safe-for-provider-p (car arguments) (cadr arguments))))

(defconst consent-redaction--primitive-implementation-table
  `((primitive-secret-source?
     . ,#'consent-redaction--primitive-secret-source-p)
    (primitive-redact . ,#'consent-redaction--primitive-redact)
    (primitive-context-local-only!
     . ,#'consent-redaction--primitive-context-local-only)
    (primitive-redaction-log . ,#'consent-redaction--primitive-redaction-log)
    (primitive-safe-for-provider?
     . ,#'consent-redaction--primitive-safe-for-provider-p))
  "Provider-owned primitive implementations for `(agent redaction)'.")

;;;###autoload
(defun consent-redaction-primitive-implementation (primitive)
  "Return `(agent redaction)' implementation for PRIMITIVE."
  (consent--primitive-implementation-from-table
   primitive
   consent-redaction--primitive-implementation-table
   "`(agent redaction)'"))

(provide 'consent-redaction)

;;; consent-redaction.el ends here
