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

(defun agent-scheme--scheme-documentation-source-files ()
  "Return portable Scheme source files in the runtime/library tree."
  (directory-files-recursively
   (expand-file-name "scheme" agent-scheme--test-root)
   "\\.s\\(?:cm\\|ld\\)\\'"))

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

(defun agent-scheme--scheme-documentation-procedure-definition-line-p (line)
  "Return non-nil when LINE starts a procedure definition."
  (string-match-p "\\`[[:space:]]*(define[[:space:]]+(" line))

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

(defun agent-scheme--scheme-documentation-procedure-leading-comment-errors
    (file)
  "Return errors for procedure definitions in FILE prefixed by comments."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file agent-scheme--test-root))
         errors)
    (cl-loop for line in lines
             for index from 0
             when (and (> index 0)
                       (agent-scheme--scheme-documentation-procedure-definition-line-p
                        line)
                       (agent-scheme--scheme-documentation-comment-line-p
                        (nth (1- index) lines)))
             do
             (push (format "%s:%d use a procedure docstring instead of a leading ;; comment before %s"
                           relative-file
                           index
                           (string-trim line))
                   errors))
    (nreverse errors)))

(defun agent-scheme--scheme-documentation-docstring-before-definition-errors
    (file)
  "Return errors for body docstrings that precede internal definitions."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file agent-scheme--test-root))
         errors)
    (cl-loop for line in lines
             for next-line in (cdr lines)
             for index from 0
             when (and (agent-scheme--scheme-documentation-string-line-p line)
                       (agent-scheme--scheme-documentation-procedure-definition-line-p
                        next-line))
             do
             (push (format "%s:%d move procedure docstring after leading internal definitions before %s"
                           relative-file
                           (1+ index)
                           (string-trim next-line))
                   errors))
    (nreverse errors)))

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

(ert-deftest agent-scheme-scheme-documentation-test-procedure-leading-comments ()
  "Ensure Scheme procedure comments are represented as body docstrings."
  (let ((errors
         (cl-loop for file in (agent-scheme--scheme-documentation-source-files)
                  append
                  (agent-scheme--scheme-documentation-procedure-leading-comment-errors
                   file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(ert-deftest agent-scheme-scheme-documentation-test-body-docstrings-follow-definitions ()
  "Ensure body docstrings do not break leading internal definition blocks."
  (let ((errors
         (cl-loop for file in (agent-scheme--scheme-documentation-source-files)
                  append
                  (agent-scheme--scheme-documentation-docstring-before-definition-errors
                   file))))
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

(defconst agent-scheme--scheme-documentation-rich-docstring-files
  '("scheme/standard-library/lazy.sld"
    "scheme/agent/diagnostics.sld"
    "scheme/agent/diff.sld"
    "scheme/agent/network.sld"
    "scheme/agent/task.sld"
    "scheme/agent/test.sld"
    "scheme/agent/transcript.sld"
    "scheme/agent/vcs.sld"
    "scheme/agent-scheme/approval.sld"
    "scheme/agent-scheme/context.sld"
    "scheme/agent-scheme/helper.sld"
    "scheme/agent-scheme/job.sld"
    "scheme/agent-scheme/memory.sld"
    "scheme/agent-scheme/plan.sld"
    "scheme/agent-scheme/redaction.sld"
    "scheme/agent-scheme/result.sld"
    "scheme/agent-scheme/session.sld")
  "Public Scheme files whose exported procedures must carry rich metadata.")

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

(defun agent-scheme--scheme-documentation-export-form (text)
  "Return the first export form text from Scheme library TEXT."
  (when (string-match "(export\\_>" text)
    (let ((cursor (match-beginning 0))
          (depth 0)
          (in-string nil)
          (escaped nil)
          end)
      (while (and (< cursor (length text)) (not end))
        (let ((char (aref text cursor)))
          (cond
           (escaped
            (setq escaped nil))
           ((and in-string (= char ?\\))
            (setq escaped t))
           ((= char ?\")
            (setq in-string (not in-string)))
           (in-string)
           ((= char ?\()
            (setq depth (1+ depth)))
           ((= char ?\))
            (setq depth (1- depth))
            (when (= depth 0)
              (setq end (1+ cursor))))))
        (setq cursor (1+ cursor)))
      (when end
        (substring text (match-beginning 0) end)))))

(defun agent-scheme--scheme-documentation-exported-symbols (text)
  "Return symbols exported by a Scheme library TEXT."
  (let ((form (agent-scheme--scheme-documentation-export-form text))
        symbols)
    (when form
      (with-temp-buffer
        (insert form)
        (goto-char (point-min))
        (while (re-search-forward "[^[:space:]()]+" nil t)
          (let ((token (match-string 0)))
            (unless (member token '("export" "rename"))
              (push token symbols))))))
    symbols))

(defun agent-scheme--scheme-documentation-procedure-name (file line)
  "Return top-level procedure name in LINE from FILE, or nil."
  (when (agent-scheme--scheme-documentation-top-level-procedure-p file line)
    (when (string-match
           "\\`[[:space:]]*(define[[:space:]]+(\\([^[:space:]()]+\\)"
           line)
      (match-string 1 line))))

(defun agent-scheme--scheme-documentation-rich-vector-p (definition-text)
  "Return non-nil when DEFINITION-TEXT has rich procedure metadata."
  (and (string-match-p (regexp-quote "#((") definition-text)
       (string-match-p (regexp-quote "(parameters .") definition-text)
       (string-match-p (regexp-quote "(returns .") definition-text)))

(defun agent-scheme--scheme-documentation-public-rich-errors (file)
  "Return rich-docstring errors for exported procedures in FILE."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (exports (agent-scheme--scheme-documentation-exported-symbols text))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file agent-scheme--test-root))
         errors)
    (cl-loop for line in lines
             for index from 0
             for name = (agent-scheme--scheme-documentation-procedure-name
                         file
                         line)
             when (and name (member name exports))
             do
             (let* ((end (agent-scheme--scheme-documentation-definition-end-index
                          file
                          lines
                          index))
                    (definition-text
                      (mapconcat #'identity
                                 (cl-subseq lines index end)
                                 "\n")))
               (unless (agent-scheme--scheme-documentation-rich-vector-p
                        definition-text)
                 (push (format "%s:%d exported procedure %s missing rich metadata vector with parameters and returns"
                               relative-file
                               (1+ index)
                               name)
                       errors))))
    (nreverse errors)))

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

(ert-deftest agent-scheme-scheme-documentation-test-public-rich-docstrings ()
  "Ensure exported Scheme procedures carry rich parameter and return metadata."
  (let ((errors
         (cl-loop for relative-file
                  in agent-scheme--scheme-documentation-rich-docstring-files
                  for file = (expand-file-name relative-file
                                               agent-scheme--test-root)
                  append
                  (agent-scheme--scheme-documentation-public-rich-errors file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

;;; agent-scheme-scheme-documentation-test.el ends here
