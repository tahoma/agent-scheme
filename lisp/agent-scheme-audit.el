;;; agent-scheme-audit.el --- Scheme-readable audit log UX  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Audit entries are stored first as Scheme-readable datums.  The in-memory
;; list and display buffer are host-side views over those datums.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)

(defgroup agent-scheme-audit nil
  "Audit log settings for Agent Scheme."
  :group 'agent-scheme)

(defcustom agent-scheme-audit-maximum-entries 200
  "Maximum number of recent audit entries kept in memory."
  :type 'integer
  :group 'agent-scheme-audit)

(defvar agent-scheme--audit-log nil
  "Most-recent-first list of Scheme-readable audit entry datums.")

(defconst agent-scheme--audit-buffer-name "*Agent Scheme Audit*"
  "Name of the Agent Scheme audit display buffer.")

(defun agent-scheme-audit--symbol (value)
  "Return VALUE as an Agent Scheme symbol datum."
  (agent-scheme--intern-symbol
   (cond
    ((keywordp value)
     (substring (symbol-name value) 1))
    ((symbolp value)
     (symbol-name value))
    ((agent-scheme-symbol-p value)
     (agent-scheme-symbol-name value))
    ((stringp value)
     value)
    (t
     (format "%S" value)))))

(defun agent-scheme-audit--integer (value)
  "Return VALUE as an exact Agent Scheme integer datum."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme-audit--datumize (value)
  "Return VALUE converted to a Scheme-readable datum."
  (cond
   ((or (eq value agent-scheme-true)
        (eq value agent-scheme-false)
        (agent-scheme-symbol-p value)
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-bytevector-p value)
        (agent-scheme-record-p value)
        (agent-scheme-record-type-p value)
        (agent-scheme-handle-p value))
    value)
   ((eq value t)
    agent-scheme-true)
   ((null value)
    nil)
   ((symbolp value)
    (agent-scheme-audit--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (agent-scheme-audit--integer value))
   ((floatp value)
    ;; Keep timestamps and measurements printable without inventing inexact
    ;; numeric semantics outside the evaluator.
    (number-to-string value))
   ((vectorp value)
    (vconcat (mapcar #'agent-scheme-audit--datumize (append value nil))))
   ((consp value)
    (cons (agent-scheme-audit--datumize (car value))
          (agent-scheme-audit--datumize (cdr value))))
   (t
    (format "%S" value))))

(defun agent-scheme-audit--field (field)
  "Return FIELD as a Scheme-readable `(name value)' pair."
  (let ((name (if (consp field) (car field) field))
        (value (if (consp field) (cdr field) agent-scheme-true)))
    (list (agent-scheme-audit--symbol name)
          (agent-scheme-audit--datumize value))))

;;;###autoload
(defun agent-scheme-audit-entry-datum (event fields)
  "Return a Scheme-readable audit entry datum for EVENT and FIELDS."
  (append
   (list (agent-scheme-audit--symbol 'audit-entry)
         (list (agent-scheme-audit--symbol 'timestamp)
               (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
         (list (agent-scheme-audit--symbol 'event)
               (agent-scheme-audit--symbol event)))
   (mapcar #'agent-scheme-audit--field fields)))

(defun agent-scheme-audit--trim-log ()
  "Trim `agent-scheme--audit-log' to `agent-scheme-audit-maximum-entries'."
  (when (and (integerp agent-scheme-audit-maximum-entries)
             (> agent-scheme-audit-maximum-entries 0))
    (let ((tail (nthcdr (1- agent-scheme-audit-maximum-entries)
                        agent-scheme--audit-log)))
      (when tail
        (setcdr tail nil)))))

;;;###autoload
(defun agent-scheme-audit-record (event fields)
  "Record EVENT with FIELDS and return the Scheme-readable audit entry."
  (let ((entry (agent-scheme-redact
                (agent-scheme-audit-entry-datum event fields)
                'audit-log)))
    (push entry agent-scheme--audit-log)
    (agent-scheme-audit--trim-log)
    entry))

;;;###autoload
(defun agent-scheme-audit-recent-entries (&optional count)
  "Return recent audit entries, newest first.
When COUNT is non-nil, return at most COUNT entries."
  (if count
      (cl-subseq agent-scheme--audit-log
                 0
                 (min count (length agent-scheme--audit-log)))
    agent-scheme--audit-log))

;;;###autoload
(defun agent-scheme-audit-clear ()
  "Clear the in-memory Agent Scheme audit log."
  (interactive)
  (setq agent-scheme--audit-log nil)
  (when-let ((buffer (get-buffer agent-scheme--audit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))))

;;;###autoload
(defun agent-scheme-audit-rotate (keep)
  "Rotate the audit log, keeping the newest KEEP entries."
  (interactive "nKeep newest audit entries: ")
  (setq agent-scheme--audit-log
        (cl-subseq agent-scheme--audit-log
                   0
                   (min keep (length agent-scheme--audit-log)))))

;;;###autoload
(defun agent-scheme-audit-display ()
  "Display recent Agent Scheme audit entries in a special buffer."
  (interactive)
  (let ((buffer (get-buffer-create agent-scheme--audit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (entry agent-scheme--audit-log)
          (insert (agent-scheme-result->external entry) "\n\n"))
        (goto-char (point-min))
        (special-mode)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(provide 'agent-scheme-audit)

;;; agent-scheme-audit.el ends here
