;;; consent-audit.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Audit entries are stored first as Scheme-readable datums.  The in-memory
;; list and display buffer are host-side views over those datums.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)

(defgroup consent-audit nil
  "Audit log settings for Consent Scheme."
  :group 'consent)

(defcustom consent-audit-maximum-entries 200
  "Maximum number of recent audit entries kept in memory."
  :type 'integer
  :group 'consent-audit)

(defvar consent--audit-log nil
  "Most-recent-first list of Scheme-readable audit entry datums.")

(defconst consent--audit-buffer-name "*Consent Scheme Audit*"
  "Name of the Consent Scheme audit display buffer.")

(defun consent-audit--symbol (value)
  "Return VALUE as an Consent Scheme symbol datum."
  (consent--intern-symbol
   (cond
    ((keywordp value)
     (substring (symbol-name value) 1))
    ((symbolp value)
     (symbol-name value))
    ((consent-symbol-p value)
     (consent-symbol-name value))
    ((stringp value)
     value)
    (t
     (format "%S" value)))))

(defun consent-audit--integer (value)
  "Return VALUE as an exact Consent Scheme integer datum."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent-audit--datumize (value)
  "Return VALUE converted to a Scheme-readable datum."
  (cond
   ((or (eq value consent-true)
        (eq value consent-false)
        (consent-symbol-p value)
        (consent-character-p value)
        (consent-number-p value)
        (consent-bytevector-p value)
        (consent-record-p value)
        (consent-record-type-p value)
        (consent-handle-p value))
    value)
   ((eq value t)
    consent-true)
   ((null value)
    nil)
   ((symbolp value)
    (consent-audit--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (consent-audit--integer value))
   ((floatp value)
    ;; Keep timestamps and measurements printable without inventing inexact
    ;; numeric semantics outside the evaluator.
    (number-to-string value))
   ((vectorp value)
    (vconcat (mapcar #'consent-audit--datumize (append value nil))))
   ((consp value)
    (cons (consent-audit--datumize (car value))
          (consent-audit--datumize (cdr value))))
   (t
    (format "%S" value))))

(defun consent-audit--field (field)
  "Return FIELD as a Scheme-readable `(name value)' pair."
  (let ((name (if (consp field) (car field) field))
        (value (if (consp field) (cdr field) consent-true)))
    (list (consent-audit--symbol name)
          (consent-audit--datumize value))))

;;;###autoload
(defun consent-audit-entry-datum (event fields)
  "Return a Scheme-readable audit entry datum for EVENT and FIELDS."
  (append
   (list (consent-audit--symbol 'audit-entry)
         (list (consent-audit--symbol 'timestamp)
               (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
         (list (consent-audit--symbol 'event)
               (consent-audit--symbol event)))
   (mapcar #'consent-audit--field fields)))

(defun consent-audit--trim-log ()
  "Trim `consent--audit-log' to `consent-audit-maximum-entries'."
  (when (and (integerp consent-audit-maximum-entries)
             (> consent-audit-maximum-entries 0))
    (let ((tail (nthcdr (1- consent-audit-maximum-entries)
                        consent--audit-log)))
      (when tail
        (setcdr tail nil)))))

;;;###autoload
(defun consent-audit-record (event fields)
  "Record EVENT with FIELDS and return the Scheme-readable audit entry."
  (let ((entry (consent-redact
                (consent-audit-entry-datum event fields)
                'audit-log)))
    (push entry consent--audit-log)
    (consent-audit--trim-log)
    entry))

;;;###autoload
(defun consent-audit-recent-entries (&optional count)
  "Return recent audit entries, newest first.
When COUNT is non-nil, return at most COUNT entries."
  (if count
      (cl-subseq consent--audit-log
                 0
                 (min count (length consent--audit-log)))
    consent--audit-log))

;;;###autoload
(defun consent-audit-clear ()
  "Clear the in-memory Consent Scheme audit log."
  (interactive)
  (setq consent--audit-log nil)
  (when-let ((buffer (get-buffer consent--audit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))))

;;;###autoload
(defun consent-audit-rotate (keep)
  "Rotate the audit log, keeping the newest KEEP entries."
  (interactive "nKeep newest audit entries: ")
  (setq consent--audit-log
        (cl-subseq consent--audit-log
                   0
                   (min keep (length consent--audit-log)))))

;;;###autoload
(defun consent-audit-display ()
  "Display recent Consent Scheme audit entries in a special buffer."
  (interactive)
  (let ((buffer (get-buffer-create consent--audit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (entry consent--audit-log)
          (insert (consent-result->external entry) "\n\n"))
        (goto-char (point-min))
        (special-mode)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(provide 'consent-audit)

;;; consent-audit.el ends here
