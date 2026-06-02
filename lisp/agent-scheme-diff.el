;;; agent-scheme-diff.el --- Canonical diff datums and rendering  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Host-neutral helpers for constructing and rendering Agent Scheme diff
;; datums.  Emacs adapter code can use these helpers to produce the same record
;; shape that `(agent diff)' exposes to Scheme programs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(defun agent-scheme-diff--symbol (name)
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

(defun agent-scheme-diff--integer (value)
  "Return VALUE as an exact Agent Scheme integer datum."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme-diff--field (name &rest values)
  "Return a Scheme-readable diff field named NAME with VALUES."
  (cons (agent-scheme-diff--symbol name) values))

(defun agent-scheme-diff--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (equal (agent-scheme--symbol-name (car field)) name)))

(defun agent-scheme-diff--field-value (record name &optional default)
  "Return field NAME from RECORD, or DEFAULT when absent."
  (let ((entry
         (seq-find
          (lambda (field)
            (agent-scheme-diff--field-named-p field name))
          (cdr-safe record))))
    (if entry
        (cadr entry)
      default)))

(defun agent-scheme-diff-line (kind text)
  "Return one diff line datum for KIND and TEXT."
  (list (agent-scheme-diff--symbol "line")
        (agent-scheme-diff--symbol kind)
        (substring-no-properties text)))

(defun agent-scheme-diff-hunk
    (old-start old-count new-start new-count lines)
  "Return one diff hunk datum with old and new ranges and LINES."
  (list (agent-scheme-diff--symbol "hunk")
        (agent-scheme-diff--field
         "old-start" (agent-scheme-diff--integer old-start))
        (agent-scheme-diff--field
         "old-count" (agent-scheme-diff--integer old-count))
        (agent-scheme-diff--field
         "new-start" (agent-scheme-diff--integer new-start))
        (agent-scheme-diff--field
         "new-count" (agent-scheme-diff--integer new-count))
        (agent-scheme-diff--field "lines" lines)))

(defun agent-scheme-diff-make (source old-label new-label hunks)
  "Return a canonical diff datum from SOURCE labels and HUNKS."
  (list (agent-scheme-diff--symbol "diff")
        (agent-scheme-diff--field "source" (agent-scheme-diff--symbol source))
        (agent-scheme-diff--field "old-label" old-label)
        (agent-scheme-diff--field "new-label" new-label)
        (agent-scheme-diff--field
         "status"
         (agent-scheme-diff--symbol
          (if hunks "changed" "no-change")))
        (agent-scheme-diff--field "hunks" hunks)))

(defun agent-scheme-diff-no-change (source label)
  "Return an explicit no-change diff datum for SOURCE and LABEL."
  (agent-scheme-diff-make source label label nil))

(defun agent-scheme-diff-p (datum)
  "Return non-nil when DATUM is a canonical diff record."
  (and (consp datum)
       (equal (agent-scheme--symbol-name (car datum)) "diff")))

(defun agent-scheme-diff-changed-p (diff)
  "Return non-nil when DIFF has changed status."
  (equal
   (agent-scheme--symbol-name
    (agent-scheme-diff--field-value
     diff "status" (agent-scheme-diff--symbol "no-change")))
   "changed"))

(defun agent-scheme-diff--string-lines (text)
  "Return TEXT split into logical lines without newline terminators."
  (cond
   ((string-empty-p text)
    nil)
   ((string-suffix-p "\n" text)
    (butlast (split-string text "\n")))
   (t
    (split-string text "\n"))))

(defun agent-scheme-diff--common-prefix-length (left right)
  "Return the number of equal leading lines in LEFT and RIGHT."
  (let ((count 0))
    (while (and left right (equal (car left) (car right)))
      (cl-incf count)
      (setq left (cdr left))
      (setq right (cdr right)))
    count))

(defun agent-scheme-diff--common-suffix-length (left right prefix-length)
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

(defun agent-scheme-diff--changed-lines (lines prefix suffix)
  "Return changed LINES after removing PREFIX and SUFFIX counts."
  (cl-subseq lines prefix (- (length lines) suffix)))

(defun agent-scheme-diff--line-records (old-lines new-lines)
  "Return hunk line records for OLD-LINES and NEW-LINES."
  (append
   (mapcar
    (lambda (line)
      (agent-scheme-diff-line 'remove line))
    old-lines)
   (mapcar
    (lambda (line)
      (agent-scheme-diff-line 'add line))
    new-lines)))

;;;###autoload
(defun agent-scheme-diff-from-strings
    (source old-label new-label old-text new-text &optional start-line)
  "Return one canonical diff from OLD-TEXT to NEW-TEXT.
SOURCE is a symbolic source tag.  OLD-LABEL and NEW-LABEL are rendered by
unified-diff views.  START-LINE defaults to 1 and offsets hunk line numbers."
  (if (equal old-text new-text)
      (agent-scheme-diff-no-change source old-label)
    (let* ((old-lines (agent-scheme-diff--string-lines old-text))
           (new-lines (agent-scheme-diff--string-lines new-text))
           (prefix (agent-scheme-diff--common-prefix-length
                    old-lines new-lines))
           (suffix (agent-scheme-diff--common-suffix-length
                    old-lines new-lines prefix))
           (old-changed (agent-scheme-diff--changed-lines
                         old-lines prefix suffix))
           (new-changed (agent-scheme-diff--changed-lines
                         new-lines prefix suffix))
           (hunk-start (+ (or start-line 1) prefix)))
      (agent-scheme-diff-make
       source
       old-label
       new-label
       (list
        (agent-scheme-diff-hunk
         hunk-start
         (length old-changed)
         hunk-start
         (length new-changed)
         (agent-scheme-diff--line-records old-changed new-changed)))))))

(defun agent-scheme-diff--integer-value (datum default)
  "Return DATUM's integer value, or DEFAULT when DATUM is absent."
  (cond
   ((agent-scheme-number-p datum)
    (agent-scheme-number-value datum))
   ((integerp datum)
    datum)
   (t default)))

(defun agent-scheme-diff--line-prefix (kind)
  "Return unified-diff prefix for line KIND."
  (pcase (agent-scheme--symbol-name kind)
    ("context" " ")
    ("remove" "-")
    ("add" "+")
    (_ " ")))

(defun agent-scheme-diff--render-line (line)
  "Return LINE rendered as unified-diff text."
  (format "%s%s\n"
          (agent-scheme-diff--line-prefix (cadr line))
          (caddr line)))

(defun agent-scheme-diff--render-hunk (hunk)
  "Return HUNK rendered as unified-diff text."
  (concat
   (format "@@ -%d,%d +%d,%d @@\n"
           (agent-scheme-diff--integer-value
            (agent-scheme-diff--field-value hunk "old-start") 1)
           (agent-scheme-diff--integer-value
            (agent-scheme-diff--field-value hunk "old-count") 0)
           (agent-scheme-diff--integer-value
            (agent-scheme-diff--field-value hunk "new-start") 1)
           (agent-scheme-diff--integer-value
            (agent-scheme-diff--field-value hunk "new-count") 0))
   (mapconcat #'agent-scheme-diff--render-line
              (agent-scheme-diff--field-value hunk "lines" nil)
              "")))

;;;###autoload
(defun agent-scheme-diff-render-unified (diff)
  "Return DIFF rendered as deterministic unified-diff text."
  (if (agent-scheme-diff-changed-p diff)
      (concat
       "--- "
       (agent-scheme-diff--field-value diff "old-label" "before")
       "\n+++ "
       (agent-scheme-diff--field-value diff "new-label" "after")
       "\n"
       (mapconcat #'agent-scheme-diff--render-hunk
                  (agent-scheme-diff--field-value diff "hunks" nil)
                  ""))
    ""))

;;;###autoload
(defun agent-scheme-diff-display (diff &optional buffer-name)
  "Display DIFF as a human-readable unified diff buffer.
Return the buffer used for display."
  (let ((buffer (get-buffer-create
                 (or buffer-name "*Agent Scheme Diff*"))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-scheme-diff-render-unified diff))
        (diff-mode)
        (goto-char (point-min))))
    (display-buffer buffer)
    buffer))

(provide 'agent-scheme-diff)

;;; agent-scheme-diff.el ends here
