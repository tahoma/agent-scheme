;;; agent-scheme-scheme-documentation-test.el --- Scheme documentation checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Enforces the portable Scheme source-comment rules documented in
;; docs/development.md.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defun agent-scheme--scheme-documentation-files ()
  "Return portable Scheme source and fixture files that carry source comments."
  (cl-loop for directory in '("scheme" "tests/scheme" "fixtures/r7rs")
           append
           (directory-files-recursively
            (expand-file-name directory agent-scheme--test-root)
            "\\.s\\(?:cm\\|ld\\)\\'")))

(defun agent-scheme--scheme-documentation-top-level-binding-p (file line)
  "Return non-nil when LINE is a top-level binding form in FILE."
  (let ((maximum-indent (if (string-suffix-p ".sld" file) 4 0)))
    (and (string-match
          "\\`\\([[:space:]]*\\)(define\\(?:-record-type\\|-syntax\\)?\\_>"
          line)
         (<= (length (match-string 1 line)) maximum-indent)
         (not (string-match "\\`[[:space:]]*(define-library\\_>" line)))))

(defun agent-scheme--scheme-documentation-comment-line-p (line)
  "Return non-nil when LINE is a Scheme source comment."
  (string-match-p "\\`[[:space:]]*;;" line))

(defun agent-scheme--scheme-documentation-previous-content-line (lines index)
  "Return the previous nonblank line before INDEX in LINES."
  (let ((cursor (1- index))
        previous)
    (while (and (not previous) (>= cursor 0))
      (let ((line (nth cursor lines)))
        (unless (string-match-p "\\`[[:space:]]*\\'" line)
          (setq previous line)))
      (setq cursor (1- cursor)))
    previous))

(defun agent-scheme--scheme-documentation-file-errors (file)
  "Return documentation-rule errors for portable Scheme FILE."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file agent-scheme--test-root))
         errors)
    (unless (and lines
                 (agent-scheme--scheme-documentation-comment-line-p
                  (car lines))
                 (string-prefix-p ";;;" (car lines)))
      (push (format "%s:1 missing ;;; source responsibility header"
                    relative-file)
            errors))
    (cl-loop for line in lines
             for index from 0
             when (agent-scheme--scheme-documentation-top-level-binding-p
                   file line)
             do
             (let ((previous
                    (agent-scheme--scheme-documentation-previous-content-line
                     lines index)))
               (unless (and previous
                            (agent-scheme--scheme-documentation-comment-line-p
                             previous))
                 (push (format "%s:%d missing leading ;; comment before %s"
                               relative-file
                               (1+ index)
                               (string-trim line))
                       errors))))
    (nreverse errors)))

(ert-deftest agent-scheme-scheme-documentation-test-source-comments ()
  "Ensure portable Scheme files follow the documented source-comment standard."
  (let ((errors
         (cl-loop for file in (agent-scheme--scheme-documentation-files)
                  append
                  (agent-scheme--scheme-documentation-file-errors file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

;;; agent-scheme-scheme-documentation-test.el ends here
