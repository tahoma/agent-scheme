;;; lint-elisp-docstrings.el --- Source docstring width lint  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Batchable lint for checked-in Emacs Lisp docstrings.  The byte compiler also
;; checks docstring width, but generated forms such as `cl-defstruct'
;; constructor docstrings differ across Emacs releases.  This scanner reads
;; source forms and checks only literal docstrings that are present in the
;; checked-in files.

;;; Code:

(require 'bytecomp)

(defconst consent-lint-elisp-docstrings-default-max-column 80
  "Default maximum byte-compiler docstring width for checked-in Elisp.")

(defun consent-lint-elisp-docstrings--positive-integer-env (name default)
  "Return positive integer environment variable NAME, or DEFAULT."
  (let ((raw (getenv name)))
    (if (and raw (> (length raw) 0))
        (let ((value (string-to-number raw)))
          (unless (and (string-match-p "\\`[0-9]+\\'" raw) (> value 0))
            (error "%s must be a positive integer" name))
          value)
      default)))

(defun consent-lint-elisp-docstrings--root ()
  "Return repository root for batch linting."
  (file-name-as-directory
   (expand-file-name
    (or (getenv "CONSENT_LINT_ROOT")
        default-directory))))

(defun consent-lint-elisp-docstrings-source-files (root)
  "Return checked-in Emacs Lisp implementation files under ROOT."
  (directory-files (expand-file-name "lisp" root) t "\\.el\\'"))

(defun consent-lint-elisp-docstrings--skip-space ()
  "Move point past whitespace and comments in the current buffer."
  (forward-comment (point-max)))

(defun consent-lint-elisp-docstrings--docstring-index (form)
  "Return FORM's literal docstring element index, or nil."
  (let ((index (and (consp form)
                    (symbolp (car form))
                    (get (car form) 'doc-string-elt))))
    (and (integerp index)
         (< index (length form))
         (stringp (nth index form))
         index)))

(defun consent-lint-elisp-docstrings--element-position (start index)
  "Return source position for element INDEX in form at START."
  (save-excursion
    (goto-char start)
    (down-list 1)
    (dotimes (_ index)
      (consent-lint-elisp-docstrings--skip-space)
      (forward-sexp 1))
    (consent-lint-elisp-docstrings--skip-space)
    (point)))

(defun consent-lint-elisp-docstrings--wide-docstring-p
    (docstring max-column)
  "Return non-nil when DOCSTRING exceeds MAX-COLUMN."
  (if (fboundp 'byte-compile--wide-docstring-p)
      (byte-compile--wide-docstring-p docstring max-column)
    (catch 'wide
      (dolist (line (split-string docstring "\n"))
        (when (> (string-width line) max-column)
          (throw 'wide t)))
      nil)))

(defun consent-lint-elisp-docstrings-file-violations
    (file root max-column)
  "Return docstring-width violations in FILE under ROOT."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (let (violations)
      (condition-case nil
          (while (progn
                   (consent-lint-elisp-docstrings--skip-space)
                   (not (eobp)))
            (let* ((start (point))
                   (form (read (current-buffer)))
                   (index
                    (consent-lint-elisp-docstrings--docstring-index form))
                   (docstring (and index (nth index form))))
              (when (and docstring
                         (consent-lint-elisp-docstrings--wide-docstring-p
                          docstring max-column))
                (let ((position
                       (consent-lint-elisp-docstrings--element-position
                        start index)))
                  (push (format "%s:%d docstring wider than %d characters"
                                (file-relative-name file root)
                                (line-number-at-pos position)
                                max-column)
                        violations)))))
        (end-of-file nil))
      (nreverse violations))))

(defun consent-lint-elisp-docstrings-violations
    (&optional root max-column)
  "Return all checked-in Emacs Lisp docstring width violations.
ROOT defaults to `default-directory'.  MAX-COLUMN defaults to
`consent-lint-elisp-docstrings-default-max-column'."
  (let* ((root (file-name-as-directory
                (expand-file-name (or root default-directory))))
         (max-column
          (or max-column consent-lint-elisp-docstrings-default-max-column))
         (violations nil))
    (dolist (file (consent-lint-elisp-docstrings-source-files root))
      (setq violations
            (append violations
                    (consent-lint-elisp-docstrings-file-violations
                     file root max-column))))
    violations))

;;;###autoload
(defun consent-lint-elisp-docstrings-batch-main ()
  "Batch entry point for checked-in Emacs Lisp docstring width lint."
  (let* ((root (consent-lint-elisp-docstrings--root))
         (max-column
          (consent-lint-elisp-docstrings--positive-integer-env
           "CONSENT_ELISP_DOCSTRING_MAX_COLUMN"
           consent-lint-elisp-docstrings-default-max-column))
         (violations
          (consent-lint-elisp-docstrings-violations root max-column)))
    (if violations
        (progn
          (dolist (violation violations)
            (princ violation)
            (princ "\n"))
          (princ
           (format "lint-elisp-docstrings: found docstrings wider than %d characters.\n"
                   max-column)
           #'external-debugging-output)
          (kill-emacs 1))
      (princ
       (format "lint-elisp-docstrings: checked-in Elisp docstrings fit within %d characters.\n"
               max-column)))))

(provide 'consent-lint-elisp-docstrings)

;;; lint-elisp-docstrings.el ends here
