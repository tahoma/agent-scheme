;;; agent-scheme-scheme-documentation-test.el --- Scheme documentation checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Enforces the portable Scheme documentation rules documented in
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

(defun agent-scheme--scheme-documentation-top-level-procedure-p (file line)
  "Return non-nil when LINE is a top-level procedure definition in FILE."
  (let ((maximum-indent (if (string-suffix-p ".sld" file) 4 0)))
    (and (string-match "\\`\\([[:space:]]*\\)(define[[:space:]]+("
                       line)
         (<= (length (match-string 1 line)) maximum-indent))))

(defun agent-scheme--scheme-documentation-comment-line-p (line)
  "Return non-nil when LINE is a Scheme source comment."
  (string-match-p "\\`[[:space:]]*;;" line))

(defun agent-scheme--scheme-documentation-string-line-p (line)
  "Return non-nil when LINE is a standalone Scheme string literal."
  (string-match-p
   "\\`[[:space:]]*\"\\(?:[^\"\\]\\|\\\\.\\)*\"[[:space:]]*\\'"
   line))

(defun agent-scheme--scheme-documentation-definition-end-index
    (file lines index)
  "Return index after the top-level definition at INDEX in LINES."
  (let ((cursor (1+ index)))
    (while (and (< cursor (length lines))
                (not (agent-scheme--scheme-documentation-top-level-binding-p
                      file
                      (nth cursor lines))))
      (setq cursor (1+ cursor)))
    cursor))

(defun agent-scheme--scheme-documentation-procedure-docstring-p
    (file lines index)
  "Return non-nil when top-level procedure at INDEX carries a docstring."
  (and
   (agent-scheme--scheme-documentation-top-level-procedure-p
    file
    (nth index lines))
   (let ((cursor (1+ index))
         (end (agent-scheme--scheme-documentation-definition-end-index
               file
               lines
               index))
         found)
     (while (and (not found) (< cursor end))
       (when (agent-scheme--scheme-documentation-string-line-p
              (nth cursor lines))
         (setq found t))
       (setq cursor (1+ cursor)))
     found)))

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
               (unless (or (and previous
                                (agent-scheme--scheme-documentation-comment-line-p
                                 previous))
                           (agent-scheme--scheme-documentation-procedure-docstring-p
                            file
                            lines
                            index))
                 (push (format "%s:%d missing leading ;; comment or procedure docstring before %s"
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

(defconst agent-scheme--scheme-documentation-representative-docstrings
  '(("scheme/agent-scheme/base-prelude.scm"
     "length"
     "Return the number of pairs in LIST.")
    ("scheme/standard-library/lazy.sld"
     "force"
     "Return PROMISE's value, evaluating and memoizing delayed thunks once.")
    ("scheme/agent/diff.sld"
     "diff-render-unified"
     "Render DIFF to deterministic unified-diff text for humans.")
    ("scheme/agent/network.sld"
     "make-network-request"
     "Return a host-adapter request datum for one network operation.")
    ("scheme/agent/vcs.sld"
     "vcs-authorize-capability-request"
     "Return a fail-closed authorization decision for REQUEST.")
    ("scheme/agent/transcript.sld"
     "transcript-event->fixture-case"
     "Generate a shared fixture case from EVENT when replay permits it.")
    ("scheme/agent-scheme/memory.sld"
     "memory-put!"
     "Store DATUM under KEY in SCOPE and return its memory record.")
    ("scheme/agent-scheme/plan.sld"
     "plan-create!"
     "Create or replace a plan from DATUM and return its canonical record.")
    ("scheme/agent-scheme/session.sld"
     "session-create!"
     "Create a session in STORE for SCOPE using OPTIONS.")
    ("scheme/agent-scheme/job.sld"
     "job-start!"
     "Create a queued eval job in STORE for SESSION and FORM.")
    ("scheme/agent-scheme/redaction.sld"
     "redact"
     "Return DATUM with secret and local-only content redacted.")
    ("scheme/agent-scheme/result.sld"
     "ok-result-datum"
     "Build a successful evaluation-result datum for VALUE."))
  "Representative public Scheme bindings that should carry docstrings.")

(defun agent-scheme--scheme-documentation-docstring-present-p
    (relative-file name docstring)
  "Return non-nil when NAME in RELATIVE-FILE starts with DOCSTRING."
  (let ((file (expand-file-name relative-file agent-scheme--test-root))
        start
        end)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward
             (concat "^[[:space:]]*(define[[:space:]]+("
                     (regexp-quote name)
                     "\\(?:[[:space:]]\\|)\\)")
             nil
             t)
        (setq start (match-beginning 0))
        (forward-line 1)
        (while (and (not end) (not (eobp)))
          (when (agent-scheme--scheme-documentation-top-level-binding-p
                 file
                 (buffer-substring-no-properties
                  (line-beginning-position)
                  (line-end-position)))
            (setq end (line-beginning-position)))
          (unless end
            (forward-line 1)))
        (goto-char start)
        (search-forward (prin1-to-string docstring) end t)))))

(ert-deftest agent-scheme-scheme-documentation-test-runtime-docstrings ()
  "Ensure representative public Scheme bindings carry runtime docstrings."
  (let (missing)
    (dolist (entry agent-scheme--scheme-documentation-representative-docstrings)
      (unless (apply #'agent-scheme--scheme-documentation-docstring-present-p
                     entry)
        (push (format "%s missing docstring for %s"
                      (nth 0 entry)
                      (nth 1 entry))
              missing)))
    (when missing
      (ert-fail (mapconcat #'identity (nreverse missing) "\n")))))

;;; agent-scheme-scheme-documentation-test.el ends here
