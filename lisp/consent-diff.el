;;; consent-diff.el --- Canonical diff datums and rendering  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Host-neutral helpers for constructing and rendering Consent Scheme diff
;; datums.  Emacs adapter code can use these helpers to produce the same record
;; shape that `(agent diff)' exposes to Scheme programs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'consent-result)
(require 'consent-runtime)

(defun consent-diff--symbol (name)
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

(defun consent-diff--integer (value)
  "Return VALUE as an exact Consent Scheme integer datum."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent-diff--field (name &rest values)
  "Return a Scheme-readable diff field named NAME with VALUES."
  (cons (consent-diff--symbol name) values))

(defun consent-diff--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (equal (consent--symbol-name (car field)) name)))

(defun consent-diff--field-value (record name &optional default)
  "Return field NAME from RECORD, or DEFAULT when absent."
  (let ((entry
         (seq-find
          (lambda (field)
            (consent-diff--field-named-p field name))
          (cdr-safe record))))
    (if entry
        (cadr entry)
      default)))

(defun consent-diff-line (kind text)
  "Return one diff line datum for KIND and TEXT."
  (list (consent-diff--symbol "line")
        (consent-diff--symbol kind)
        (substring-no-properties text)))

(defun consent-diff-hunk
    (old-start old-count new-start new-count lines)
  "Return one diff hunk datum with old and new ranges and LINES."
  (list (consent-diff--symbol "hunk")
        (consent-diff--field
         "old-start" (consent-diff--integer old-start))
        (consent-diff--field
         "old-count" (consent-diff--integer old-count))
        (consent-diff--field
         "new-start" (consent-diff--integer new-start))
        (consent-diff--field
         "new-count" (consent-diff--integer new-count))
        (consent-diff--field "lines" lines)))

(defun consent-diff-make (source old-label new-label hunks)
  "Return a canonical diff datum from SOURCE labels and HUNKS."
  (list (consent-diff--symbol "diff")
        (consent-diff--field "source" (consent-diff--symbol source))
        (consent-diff--field "old-label" old-label)
        (consent-diff--field "new-label" new-label)
        (consent-diff--field
         "status"
         (consent-diff--symbol
          (if hunks "changed" "no-change")))
        (consent-diff--field "hunks" hunks)))

(defun consent-diff-no-change (source label)
  "Return an explicit no-change diff datum for SOURCE and LABEL."
  (consent-diff-make source label label nil))

(defun consent-diff-p (datum)
  "Return non-nil when DATUM is a canonical diff record."
  (and (consp datum)
       (equal (consent--symbol-name (car datum)) "diff")))

(defun consent-diff-changed-p (diff)
  "Return non-nil when DIFF has changed status."
  (equal
   (consent--symbol-name
    (consent-diff--field-value
     diff "status" (consent-diff--symbol "no-change")))
   "changed"))

(defun consent-diff--string-lines (text)
  "Return TEXT split into logical lines without newline terminators."
  (cond
   ((string-empty-p text)
    nil)
   ((string-suffix-p "\n" text)
    (butlast (split-string text "\n")))
   (t
    (split-string text "\n"))))

(defun consent-diff--common-prefix-length (left right)
  "Return the number of equal leading lines in LEFT and RIGHT."
  (let ((count 0))
    (while (and left right (equal (car left) (car right)))
      (cl-incf count)
      (setq left (cdr left))
      (setq right (cdr right)))
    count))

(defun consent-diff--common-suffix-length (left right prefix-length)
  "Return equal trailing line count after PREFIX-LENGTH has been removed."
  (let* ((left-length (length left))
         (right-length (length right))
         (maximum (- (min left-length right-length) prefix-length))
         (count 0))
    (while (and (< count maximum)
                (equal (nth (- left-length count 1) left)
                       (nth (- right-length count 1) right)))
      (cl-incf count))
    count))

(defun consent-diff--changed-lines (lines prefix suffix)
  "Return changed LINES after removing PREFIX and SUFFIX counts."
  (cl-subseq lines prefix (- (length lines) suffix)))

(defun consent-diff--line-records (old-lines new-lines)
  "Return hunk line records for OLD-LINES and NEW-LINES."
  (append
   (mapcar
    (lambda (line)
      (consent-diff-line 'remove line))
    old-lines)
   (mapcar
    (lambda (line)
      (consent-diff-line 'add line))
    new-lines)))

;;;###autoload
(defun consent-diff-from-strings
    (source old-label new-label old-text new-text &optional start-line)
  "Return one canonical diff from OLD-TEXT to NEW-TEXT.
SOURCE is a symbolic source tag.  OLD-LABEL and NEW-LABEL are rendered by
unified-diff views.  START-LINE defaults to 1 and offsets hunk line numbers."
  (if (equal old-text new-text)
      (consent-diff-no-change source old-label)
    (let* ((old-lines (consent-diff--string-lines old-text))
           (new-lines (consent-diff--string-lines new-text))
           (prefix (consent-diff--common-prefix-length
                    old-lines new-lines))
           (suffix (consent-diff--common-suffix-length
                    old-lines new-lines prefix))
           (old-changed (consent-diff--changed-lines
                         old-lines prefix suffix))
           (new-changed (consent-diff--changed-lines
                         new-lines prefix suffix))
           (hunk-start (+ (or start-line 1) prefix)))
      (consent-diff-make
       source
       old-label
       new-label
       (list
        (consent-diff-hunk
         hunk-start
         (length old-changed)
         hunk-start
         (length new-changed)
         (consent-diff--line-records old-changed new-changed)))))))

(defun consent-diff--integer-value (datum default)
  "Return DATUM's integer value, or DEFAULT when DATUM is absent."
  (cond
   ((consent-number-p datum)
    (consent-number-value datum))
   ((integerp datum)
    datum)
   (t default)))

(defun consent-diff--line-prefix (kind)
  "Return unified-diff prefix for line KIND."
  (pcase (consent--symbol-name kind)
    ("context" " ")
    ("remove" "-")
    ("add" "+")
    (_ " ")))

(defun consent-diff--render-line (line)
  "Return LINE rendered as unified-diff text."
  (format "%s%s\n"
          (consent-diff--line-prefix (cadr line))
          (caddr line)))

(defun consent-diff--render-hunk (hunk)
  "Return HUNK rendered as unified-diff text."
  (concat
   (format "@@ -%d,%d +%d,%d @@\n"
           (consent-diff--integer-value
            (consent-diff--field-value hunk "old-start") 1)
           (consent-diff--integer-value
            (consent-diff--field-value hunk "old-count") 0)
           (consent-diff--integer-value
            (consent-diff--field-value hunk "new-start") 1)
           (consent-diff--integer-value
            (consent-diff--field-value hunk "new-count") 0))
   (mapconcat #'consent-diff--render-line
              (consent-diff--field-value hunk "lines" nil)
              "")))

;;;###autoload
(defun consent-diff-render-unified (diff)
  "Return DIFF rendered as deterministic unified-diff text."
  (if (consent-diff-changed-p diff)
      (concat
       "--- "
       (consent-diff--field-value diff "old-label" "before")
       "\n+++ "
       (consent-diff--field-value diff "new-label" "after")
       "\n"
       (mapconcat #'consent-diff--render-hunk
                  (consent-diff--field-value diff "hunks" nil)
                  ""))
    ""))

;;;###autoload
(defun consent-diff-display (diff &optional buffer-name)
  "Display DIFF as a human-readable unified diff buffer.
Return the buffer used for display."
  (let ((buffer (get-buffer-create
                 (or buffer-name "*Consent Scheme Diff*"))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (consent-diff-render-unified diff))
        (diff-mode)
        (goto-char (point-min))))
    (display-buffer buffer)
    buffer))

(provide 'consent-diff)

;;; consent-diff.el ends here
