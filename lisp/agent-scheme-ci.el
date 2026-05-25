;;; agent-scheme-ci.el --- CI shard timing reports  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers for parsing Agent Scheme ERT shard logs and rendering the GitHub
;; Actions step summary used by the repository test workflow.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst agent-scheme-ci--result-line-regexp
  "^[[:space:]]+\\([[:alpha:]-]+\\)[[:space:]]+\\([0-9]+\\)/\\([0-9]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]+(\\([0-9.]+\\) sec)"
  "Regexp matching one ERT per-test result line.")

(defconst agent-scheme-ci--summary-line-regexp
  "^Ran \\([0-9]+\\) tests, \\([0-9]+\\) results as expected, \\([0-9]+\\) unexpected\\(?:, \\([0-9]+\\) skipped\\)? .*, \\([0-9.]+\\) sec)"
  "Regexp matching the final ERT batch summary line.")

(defconst agent-scheme-ci--surface-groups
  '((:name "Reader"
     :emacs ("agent-scheme-reader-test-")
     :portable ("agent-scheme-scheme-reader-test-"))
    (:name "Evaluator"
     :emacs ("agent-scheme-eval-test-")
     :portable ("agent-scheme-scheme-eval-test-"))
    (:name "Fixture/conformance"
     :emacs ("agent-scheme-fixture-test-"
             "agent-scheme-conformance-test-")
     :portable ("agent-scheme-scheme-fixture-test-"))
    (:name "Module boundary"
     :emacs ("agent-scheme-scheme-module-ownership-test-")
     :portable ("agent-scheme-scheme-module-boundary-test-")))
  "Comparable host/runtime validation surfaces shown in CI summaries.")

(defconst agent-scheme-ci-pr-summary-marker
  "<!-- agent-scheme-ci-timing-summary -->"
  "Hidden marker used to update the pull request timing comment.")

(defconst agent-scheme-ci--shard-order
  '(("Portable Chibi-backed ERT" . 0)
    ("Emacs core language/runtime" . 1)
    ("Emacs library/conformance" . 2)
    ("Emacs capabilities/policy" . 3)
    ("Emacs tools/docs/integration" . 4))
  "Preferred display order for CI shard summaries.")

(defun agent-scheme-ci--file-string (path)
  "Return the contents of PATH as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun agent-scheme-ci--metadata-value (contents key)
  "Return marker value for KEY in CONTENTS, or nil.
Markers use the shell-friendly shape KEY=value on their own line."
  (when (string-match
         (format "^%s=\\(.*\\)$" (regexp-quote key))
         contents)
    (match-string 1 contents)))

(defun agent-scheme-ci--number-or-zero (text)
  "Return TEXT parsed as a number, or 0 when TEXT is nil."
  (if text
      (string-to-number text)
    0))

(defun agent-scheme-ci--parse-test-line (line)
  "Parse LINE as one ERT test result plist, or nil."
  (when (string-match agent-scheme-ci--result-line-regexp line)
    (list :result (match-string 1 line)
          :index (string-to-number (match-string 2 line))
          :total (string-to-number (match-string 3 line))
          :name (match-string 4 line)
          :seconds (string-to-number (match-string 5 line)))))

(defun agent-scheme-ci--parse-summary-line (line)
  "Parse LINE as the final ERT summary plist, or nil."
  (when (string-match agent-scheme-ci--summary-line-regexp line)
    (list :ran (string-to-number (match-string 1 line))
          :expected (string-to-number (match-string 2 line))
          :unexpected (string-to-number (match-string 3 line))
          :skipped (agent-scheme-ci--number-or-zero (match-string 4 line))
          :ert-seconds (string-to-number (match-string 5 line)))))

(defun agent-scheme-ci-parse-log-file (path)
  "Parse an Agent Scheme CI shard log at PATH.
The returned plist includes shard metadata, ERT result counts, test
durations, and optional wall-clock seconds recorded by the workflow."
  (let* ((contents (agent-scheme-ci--file-string path))
         (tests nil)
         (summary nil))
    (dolist (line (split-string contents "\n"))
      (let ((test (agent-scheme-ci--parse-test-line line))
            (line-summary (agent-scheme-ci--parse-summary-line line)))
        (when test
          (push test tests))
        (when line-summary
          (setq summary line-summary))))
    (append
     (list :path path
           :name (or (agent-scheme-ci--metadata-value
                      contents "AGENT_SCHEME_CI_SHARD_NAME")
                     (file-name-base path))
           :selector (or (agent-scheme-ci--metadata-value
                          contents "AGENT_SCHEME_CI_SHARD_SELECTOR")
                         "unknown")
           :wall-seconds (let ((value (agent-scheme-ci--metadata-value
                                       contents
                                       "AGENT_SCHEME_CI_WALL_SECONDS")))
                           (when value
                             (string-to-number value)))
           :tests (nreverse tests))
     (or summary
         '(:ran 0 :expected 0 :unexpected 0 :skipped 0 :ert-seconds 0.0)))))

(defun agent-scheme-ci-shard-slowest-tests (shard limit)
  "Return up to LIMIT slowest tests from SHARD."
  (let* ((tests (copy-sequence (plist-get shard :tests)))
         (sorted (sort tests
                       (lambda (left right)
                         (> (plist-get left :seconds)
                            (plist-get right :seconds))))))
    (cl-subseq sorted 0 (min limit (length sorted)))))

(defun agent-scheme-ci--markdown-cell (value)
  "Return VALUE escaped for a simple Markdown table cell."
  (replace-regexp-in-string
   "|"
   "\\\\|"
   (replace-regexp-in-string "\n" " " (format "%s" value))
   t
   t))

(defun agent-scheme-ci--format-seconds (seconds)
  "Return SECONDS as a fixed-width duration cell."
  (if (numberp seconds)
      (format "%.3fs" seconds)
    "n/a"))

(defun agent-scheme-ci--format-slowest-tests (shard)
  "Return a Markdown fragment listing SHARD's slowest tests."
  (let ((tests (agent-scheme-ci-shard-slowest-tests shard 5)))
    (if tests
        (mapconcat
         (lambda (test)
           (format "`%s` %s"
                   (agent-scheme-ci--markdown-cell (plist-get test :name))
                   (agent-scheme-ci--format-seconds
                    (plist-get test :seconds))))
         tests
         "<br>")
      "n/a")))

(defun agent-scheme-ci--surface-stats (shards prefixes)
  "Return test count and duration for tests in SHARDS matching PREFIXES."
  (let ((count 0)
        (seconds 0.0))
    (dolist (shard shards)
      (dolist (test (plist-get shard :tests))
        (when (cl-some
               (lambda (prefix)
                 (string-prefix-p prefix (plist-get test :name)))
               prefixes)
          (cl-incf count)
          (cl-incf seconds (plist-get test :seconds)))))
    (list :count count :seconds seconds)))

(defun agent-scheme-ci--format-surface-stats (stats)
  "Return STATS as count and duration text."
  (format "%d / %s"
          (plist-get stats :count)
          (agent-scheme-ci--format-seconds (plist-get stats :seconds))))

(defun agent-scheme-ci--shard-sort-key (shard)
  "Return display sort key for SHARD."
  (or (cdr (assoc (plist-get shard :name) agent-scheme-ci--shard-order))
      99))

(defun agent-scheme-ci--sort-shards (shards)
  "Return SHARDS in stable report display order."
  (sort (copy-sequence shards)
        (lambda (left right)
          (< (agent-scheme-ci--shard-sort-key left)
             (agent-scheme-ci--shard-sort-key right)))))

(defun agent-scheme-ci-render-markdown-summary (shards)
  "Render SHARDS as a GitHub Actions Markdown summary."
  (let ((shards (agent-scheme-ci--sort-shards shards)))
    (concat
     "## Test Shard Timing\n\n"
     "| Shard | Selector | Ran | Expected | Unexpected | Skipped | ERT time | Wall time | Slowest tests |\n"
     "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n"
     (mapconcat
      (lambda (shard)
        (format "| %s | `%s` | %d | %d | %d | %d | %s | %s | %s |"
                (agent-scheme-ci--markdown-cell (plist-get shard :name))
                (agent-scheme-ci--markdown-cell (plist-get shard :selector))
                (plist-get shard :ran)
                (plist-get shard :expected)
                (plist-get shard :unexpected)
                (plist-get shard :skipped)
                (agent-scheme-ci--format-seconds
                 (plist-get shard :ert-seconds))
                (agent-scheme-ci--format-seconds
                 (plist-get shard :wall-seconds))
                (agent-scheme-ci--format-slowest-tests shard)))
      shards
      "\n")
     "\n\n"
     "## Paired Validation Surfaces\n\n"
     "Portable Chibi-backed rows are reported beside their Emacs-hosted counterparts where the suite already has paired coverage.\n\n"
     "| Surface | Emacs-hosted tests / ERT time | Portable Chibi-backed tests / ERT time |\n"
     "| --- | ---: | ---: |\n"
     (mapconcat
      (lambda (group)
        (let ((emacs (agent-scheme-ci--surface-stats
                      shards
                      (plist-get group :emacs)))
              (portable (agent-scheme-ci--surface-stats
                         shards
                         (plist-get group :portable))))
          (format "| %s | %s | %s |"
                  (agent-scheme-ci--markdown-cell (plist-get group :name))
                  (agent-scheme-ci--format-surface-stats emacs)
                  (agent-scheme-ci--format-surface-stats portable))))
      agent-scheme-ci--surface-groups
      "\n")
     "\n")))

(defun agent-scheme-ci--render-compact-shard-row (shard)
  "Render SHARD as one compact Markdown table row."
  (format "| %s | %d | %d | %d | %s | %s |"
          (agent-scheme-ci--markdown-cell (plist-get shard :name))
          (plist-get shard :ran)
          (plist-get shard :unexpected)
          (plist-get shard :skipped)
          (agent-scheme-ci--format-seconds
           (plist-get shard :ert-seconds))
          (agent-scheme-ci--format-seconds
           (plist-get shard :wall-seconds))))

(defun agent-scheme-ci-render-pr-markdown-summary (shards &optional run-url)
  "Render SHARDS as an updatable pull request Markdown comment.
When RUN-URL is non-nil, include a link to the workflow run that produced the
summary."
  (let ((shards (agent-scheme-ci--sort-shards shards)))
    (concat
     agent-scheme-ci-pr-summary-marker
     "\n\n"
     "## Test Shard Timing\n\n"
     (when (and run-url (not (string-empty-p run-url)))
       (format "Latest run: [GitHub Actions](%s).\n\n" run-url))
     "| Shard | Ran | Unexpected | Skipped | ERT time | Wall time |\n"
     "| --- | ---: | ---: | ---: | ---: | ---: |\n"
     (mapconcat #'agent-scheme-ci--render-compact-shard-row shards "\n")
     "\n\n"
     "<details>\n"
     "<summary>Slowest tests and paired validation surfaces</summary>\n\n"
     (agent-scheme-ci-render-markdown-summary shards)
     "\n</details>\n")))

(defun agent-scheme-ci-write-summary (log-files &optional output-file)
  "Render LOG-FILES to OUTPUT-FILE, or print to standard output.
When OUTPUT-FILE is non-nil, append the summary so it can be used directly with
the GITHUB_STEP_SUMMARY file."
  (let ((markdown (agent-scheme-ci-render-markdown-summary
                   (mapcar #'agent-scheme-ci-parse-log-file log-files))))
    (if (and output-file (not (string-empty-p output-file)))
        (with-temp-buffer
          (insert markdown)
          (insert "\n")
          (write-region (point-min) (point-max) output-file t 'silent))
      (princ markdown))))

(defun agent-scheme-ci-write-pr-summary
    (log-files output-file &optional run-url)
  "Render a pull request timing comment for LOG-FILES to OUTPUT-FILE.
RUN-URL, when non-nil, links the comment back to the producing workflow run."
  (with-temp-buffer
    (insert
     (agent-scheme-ci-render-pr-markdown-summary
      (mapcar #'agent-scheme-ci-parse-log-file log-files)
      run-url))
    (write-region (point-min) (point-max) output-file nil 'silent)))

(defun agent-scheme-ci--batch-log-files ()
  "Return log file arguments passed after the batch command separator."
  (cl-remove "--" command-line-args-left :test #'string=))

(defun agent-scheme-ci-summary-batch-main ()
  "Batch entry point that summarizes paths from `command-line-args-left'."
  (let ((log-files (agent-scheme-ci--batch-log-files)))
    (unless log-files
      (error "No CI log files supplied"))
    (agent-scheme-ci-write-summary
     log-files
     (or (getenv "AGENT_SCHEME_CI_SUMMARY_FILE")
         (getenv "GITHUB_STEP_SUMMARY")))))

(defun agent-scheme-ci-pr-summary-batch-main ()
  "Batch entry point that writes a pull request timing comment body."
  (let ((log-files (agent-scheme-ci--batch-log-files))
        (output-file (getenv "AGENT_SCHEME_CI_PR_SUMMARY_FILE")))
    (unless log-files
      (error "No CI log files supplied"))
    (unless (and output-file (not (string-empty-p output-file)))
      (error "AGENT_SCHEME_CI_PR_SUMMARY_FILE is required"))
    (agent-scheme-ci-write-pr-summary
     log-files
     output-file
     (getenv "AGENT_SCHEME_CI_RUN_URL"))))

(provide 'agent-scheme-ci)

;;; agent-scheme-ci.el ends here
