;;; consent-ci.el --- CI timing and run records  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helpers for parsing Consent Scheme ERT shard logs and rendering the GitHub
;; Actions step summary used by the repository test workflow.  The same parsed
;; shard data also feeds a structured, append-only per-run record (#465) for
;; longitudinal analysis; see the "Structured per-run record" section below and
;; docs/ci-run-record.md.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst consent-ci--result-line-regexp
  "^[[:space:]]+\\([[:alpha:]-]+\\)[[:space:]]+\\([0-9]+\\)/\\([0-9]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]+(\\([0-9.]+\\) sec)"
  "Regexp matching one ERT per-test result line.")

(defconst consent-ci--summary-line-regexp
  "^Ran \\([0-9]+\\) tests, \\([0-9]+\\) results as expected, \\([0-9]+\\) unexpected\\(?:, \\([0-9]+\\) skipped\\)? .*, \\([0-9.]+\\) sec)"
  "Regexp matching the final ERT batch summary line.")

(defconst consent-ci--check-timing-regexp
  "^CONSENT_CI_CHECK_SECONDS=\\([^[:space:]]+\\)[[:space:]]+\\([+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][+-]?[0-9]+\\)?\\)$"
  "Regexp matching one portable Scheme fine-grained timing line.")

(defconst consent-ci--surface-groups
  '((:name "Reader"
     :emacs ("consent-reader-test-")
     :portable ("consent-scheme-reader-test-"))
    (:name "Evaluator"
     :emacs ("consent-eval-test-")
     :portable ("consent-scheme-eval-test-"))
    (:name "Fixture/conformance"
     :emacs ("consent-fixture-test-"
             "consent-conformance-test-")
     :portable ("consent-scheme-fixture-test-"))
    (:name "Module boundary"
     :emacs ("consent-scheme-module-ownership-test-")
     :portable ("consent-scheme-module-boundary-test-")))
  "Comparable host/runtime validation surfaces shown in CI summaries.")

(defconst consent-ci-pr-summary-marker
  "<!-- consent-ci-timing-summary -->"
  "Hidden marker used to update the pull request timing comment.")

(defconst consent-ci--shard-order
  '(("Portable R7RS Chibi full suite" . 0)
    ("Portable R7RS Chibi evaluator subset" . 1)
    ("Portable R7RS Chibi non-evaluator subset" . 2)
    ("Portable R7RS Gambit full suite" . 3)
    ("Portable R7RS Gambit reflection contract" . 4)
    ("Portable R7RS Gambit reflection stress" . 5)
    ("Portable R7RS Gambit-compiled Consent Scheme full suite" . 6)
    ("Portable R7RS Racket full suite" . 7)
    ("Portable R7RS Racket reflection contract" . 8)
    ("Portable R7RS Racket reflection stress" . 9)
    ("Portable R7RS Racket-compiled Consent Scheme full suite" . 10)
    ("Portable R7RS Guile full suite" . 11)
    ("Portable R7RS Guile reflection contract" . 12)
    ("Portable R7RS Guile reflection stress" . 13)
    ("Portable R7RS Gauche full suite" . 14)
    ("Portable R7RS Gauche reflection contract" . 15)
    ("Portable R7RS Gauche reflection stress" . 16)
    ("Portable Chibi-backed eval" . 17)
    ("Portable Chibi-backed rest" . 18)
    ("Portable Chibi-backed ERT" . 18)
    ("Portable Gambit-backed suite" . 19)
    ("Emacs core language/runtime" . 20)
    ("Emacs library/conformance" . 21)
    ("Emacs stdlib/reference corpus" . 22)
    ("Emacs stdlib/reference stress" . 23)
    ("Emacs agent control" . 24)
    ("Emacs agent reliability" . 25)
    ("Emacs capability boundary" . 26)
    ("Emacs agent state" . 27)
    ("Emacs capabilities/policy" . 28)
    ("Emacs tools/docs/integration" . 29)
    ("Emacs reflection contract" . 30)
    ("Emacs reflection catalog stress" . 31)
    ("Emacs reflection documentation stress" . 32)
    ("Emacs reflection binding crosswalk stress" . 33)
    ("Emacs reflection dynamic manifest stress" . 34)
    ("Emacs native-build/install-dist" . 35)
    ("Emacs integration/REPL" . 36))
  "Preferred display order for CI shard summaries.")

(defconst consent-ci--source-metadata-order
  '(("on" . 0)
    ("off" . 1))
  "Preferred display order for source metadata timing variants.")

(defconst consent-ci--docstring-retention-order
  '(("full" . 0)
    ("simple" . 1)
    ("none" . 2))
  "Preferred display order for docstring retention timing variants.")

(defun consent-ci--file-string (path)
  "Return the contents of PATH as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun consent-ci--metadata-value (contents key)
  "Return marker value for KEY in CONTENTS, or nil.
Markers use the shell-friendly shape KEY=value on their own line."
  (when (string-match
         (format "^%s=\\(.*\\)$" (regexp-quote key))
         contents)
    (match-string 1 contents)))

(defun consent-ci--number-or-zero (text)
  "Return TEXT parsed as a number, or 0 when TEXT is nil."
  (if text
      (string-to-number text)
    0))

(defun consent-ci--parse-test-line (line)
  "Parse LINE as one ERT test result plist, or nil."
  (when (string-match consent-ci--result-line-regexp line)
    (list :result (match-string 1 line)
          :index (string-to-number (match-string 2 line))
          :total (string-to-number (match-string 3 line))
          :name (match-string 4 line)
          :seconds (string-to-number (match-string 5 line)))))

(defun consent-ci--parse-summary-line (line)
  "Parse LINE as the final ERT summary plist, or nil."
  (when (string-match consent-ci--summary-line-regexp line)
    (list :ran (string-to-number (match-string 1 line))
          :expected (string-to-number (match-string 2 line))
          :unexpected (string-to-number (match-string 3 line))
          :skipped (consent-ci--number-or-zero (match-string 4 line))
          :ert-seconds (string-to-number (match-string 5 line)))))

(defun consent-ci--parse-check-timing-line (line)
  "Parse LINE as one portable Scheme check timing plist, or nil."
  (when (string-match consent-ci--check-timing-regexp line)
    (list :name (match-string 1 line)
          :seconds (string-to-number (match-string 2 line)))))

(defun consent-ci-parse-log-file (path)
  "Parse an Consent Scheme CI shard log at PATH.
The returned plist includes shard metadata, ERT result counts, test
durations, and optional wall-clock seconds recorded by the workflow."
  (let* ((contents (consent-ci--file-string path))
         (tests nil)
         (check-timings nil)
         (summary nil))
    (dolist (line (split-string contents "\n"))
      (let ((test (consent-ci--parse-test-line line))
            (line-summary (consent-ci--parse-summary-line line))
            (check-timing (consent-ci--parse-check-timing-line line)))
        (when test
          (push test tests))
        (when check-timing
          (push check-timing check-timings))
        (when line-summary
          (setq summary line-summary))))
    (append
     (list :path path
           :name (or (consent-ci--metadata-value
                      contents "CONSENT_CI_SHARD_NAME")
                     (file-name-base path))
           :selector (or (consent-ci--metadata-value
                         contents "CONSENT_CI_SHARD_SELECTOR")
                         "unknown")
           :wall-seconds (let ((value (consent-ci--metadata-value
                                       contents
                                       "CONSENT_CI_WALL_SECONDS")))
                           (when value
                             (string-to-number value)))
           :check-timings (nreverse check-timings)
           :tests (nreverse tests))
     (or summary
         '(:ran 0 :expected 0 :unexpected 0 :skipped 0 :ert-seconds 0.0)))))

(defun consent-ci-shard-slowest-tests (shard limit)
  "Return up to LIMIT slowest tests from SHARD."
  (let* ((tests (copy-sequence (plist-get shard :tests)))
         (sorted (sort tests
                       (lambda (left right)
                         (> (plist-get left :seconds)
                            (plist-get right :seconds))))))
    (cl-subseq sorted 0 (min limit (length sorted)))))

(defun consent-ci--markdown-cell (value)
  "Return VALUE escaped for a simple Markdown table cell."
  (replace-regexp-in-string
   "|"
   "\\\\|"
   (replace-regexp-in-string "\n" " " (format "%s" value))
   t
   t))

(defun consent-ci--format-seconds (seconds)
  "Return SECONDS as a fixed-width duration cell."
  (if (numberp seconds)
      (format "%.3fs" seconds)
    "n/a"))

(defun consent-ci--format-slowest-tests (shard)
  "Return a Markdown fragment listing SHARD's slowest tests."
  (let ((tests (consent-ci-shard-slowest-tests shard 5)))
    (if tests
        (mapconcat
         (lambda (test)
           (format "`%s` %s"
                   (consent-ci--markdown-cell (plist-get test :name))
                   (consent-ci--format-seconds
                    (plist-get test :seconds))))
         tests
         "<br>")
      "n/a")))

(defun consent-ci--surface-stats (shards prefixes)
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

(defun consent-ci--format-surface-stats (stats)
  "Return STATS as count and duration text."
  (format "%d / %s"
          (plist-get stats :count)
          (consent-ci--format-seconds (plist-get stats :seconds))))

(defun consent-ci--slowest-check-timings (shards limit)
  "Return up to LIMIT slowest fine-grained check timings from SHARDS."
  (let (rows)
    (dolist (shard shards)
      (dolist (timing (plist-get shard :check-timings))
        (push (list :shard (plist-get shard :name)
                    :name (plist-get timing :name)
                    :seconds (plist-get timing :seconds))
              rows)))
    (cl-subseq
     (sort rows
           (lambda (left right)
             (> (plist-get left :seconds)
                (plist-get right :seconds))))
     0
     (min limit (length rows)))))

(defun consent-ci--render-slow-check-timings (shards)
  "Return Markdown for fine-grained portable check timings in SHARDS."
  (let ((rows (consent-ci--slowest-check-timings shards 10)))
    (when rows
      (concat
       "\n\n"
       "## Slow Portable Checks\n\n"
       "Fine-grained portable Scheme timings are diagnostic details from runners that emit them; shard-level timing remains the primary CI signal.\n\n"
       "| Shard | Check | Seconds |\n"
       "| --- | --- | ---: |\n"
       (mapconcat
        (lambda (row)
          (format "| %s | `%s` | %s |"
                  (consent-ci--markdown-cell (plist-get row :shard))
                  (consent-ci--markdown-cell (plist-get row :name))
                  (consent-ci--format-seconds
                   (plist-get row :seconds))))
        rows
        "\n")
       "\n"))))

(defun consent-ci--split-option-variant-name (name)
  "Return plist for NAME split into base name and option variant fields."
  (if (string-match
       "\\`\\(.+\\) / source metadata \\([^ /]+\\) / docstrings \\([^ /]+\\)\\'"
       name)
      (list :base (match-string 1 name)
            :source-metadata (match-string 2 name)
            :docstrings (match-string 3 name))
    (list :base name)))

(defun consent-ci--shard-base-name (shard)
  "Return SHARD's name without option-variant suffixes."
  (plist-get
   (consent-ci--split-option-variant-name (plist-get shard :name))
   :base))

(defun consent-ci--option-variant (shard)
  "Return SHARD's source metadata/docstring variant as a cons, or nil."
  (let ((parts (consent-ci--split-option-variant-name
                (plist-get shard :name))))
    (when (plist-get parts :source-metadata)
      (cons (plist-get parts :source-metadata)
            (plist-get parts :docstrings)))))

(defun consent-ci--option-variant-sort-key (variant)
  "Return numeric display order for source metadata/docstring VARIANT."
  (+ (* 10 (or (cdr (assoc (car variant)
                           consent-ci--source-metadata-order))
               9))
     (or (cdr (assoc (cdr variant)
                     consent-ci--docstring-retention-order))
         9)))

(defun consent-ci--shard-sort-key (shard)
  "Return display sort key for SHARD."
  (or (cdr (assoc (consent-ci--shard-base-name shard)
                  consent-ci--shard-order))
      99))

(defun consent-ci--shard-less-p (left right)
  "Return non-nil when LEFT should display before RIGHT."
  (let ((left-key (consent-ci--shard-sort-key left))
        (right-key (consent-ci--shard-sort-key right))
        (left-variant (consent-ci--option-variant left))
        (right-variant (consent-ci--option-variant right)))
    (cond
     ((/= left-key right-key)
      (< left-key right-key))
     ((and left-variant right-variant)
      (< (consent-ci--option-variant-sort-key left-variant)
         (consent-ci--option-variant-sort-key right-variant)))
     (left-variant nil)
     (right-variant t)
     (t (string< (plist-get left :name) (plist-get right :name))))))

(defun consent-ci--sort-shards (shards)
  "Return SHARDS in stable report display order."
  (sort (copy-sequence shards) #'consent-ci--shard-less-p))

(defun consent-ci--shard-wall-seconds (shard)
  "Return SHARD's CI wall-clock seconds, sorting absent values last."
  (or (plist-get shard :wall-seconds) -1.0))

(defun consent-ci--shard-wall-time-greater-p (left right)
  "Return non-nil when LEFT should precede RIGHT by descending wall time."
  (let ((left-wall (consent-ci--shard-wall-seconds left))
        (right-wall (consent-ci--shard-wall-seconds right)))
    (if (/= left-wall right-wall)
        (> left-wall right-wall)
      (consent-ci--shard-less-p left right))))

(defun consent-ci--sort-shards-by-wall-time (shards)
  "Return SHARDS ordered by descending CI wall-clock time."
  (sort (copy-sequence shards) #'consent-ci--shard-wall-time-greater-p))

(defun consent-ci--sum-shard-field (shards field)
  "Return the numeric sum of FIELD across SHARDS."
  (let ((total 0))
    (dolist (shard shards total)
      (cl-incf total (or (plist-get shard field) 0)))))

(defun consent-ci--paired-surface-rows (shards)
  "Return paired validation surface rows for SHARDS."
  (mapcar
   (lambda (group)
     (let ((emacs (consent-ci--surface-stats
                   shards
                   (plist-get group :emacs)))
           (portable (consent-ci--surface-stats
                      shards
                      (plist-get group :portable))))
       (list :name (plist-get group :name)
             :emacs emacs
             :portable portable)))
   consent-ci--surface-groups))

(defun consent-ci--render-paired-validation-surfaces (shards)
  "Return Markdown for paired validation surfaces in SHARDS, or nil.
The table is omitted when portable surface timings are not available, which is
the case for whole-suite portable host shards."
  (let ((rows (consent-ci--paired-surface-rows shards)))
    (when (cl-some
           (lambda (row)
             (> (plist-get (plist-get row :portable) :count) 0))
           rows)
      (concat
       "## Paired Validation Surfaces\n\n"
       "Portable R7RS rows are reported beside their Emacs-hosted counterparts where the suite already has paired coverage.\n\n"
       "| Surface | Emacs-hosted tests / ERT time | Portable R7RS tests / ERT time |\n"
       "| --- | ---: | ---: |\n"
       (mapconcat
        (lambda (row)
          (format "| %s | %s | %s |"
                  (consent-ci--markdown-cell (plist-get row :name))
                  (consent-ci--format-surface-stats
                   (plist-get row :emacs))
                  (consent-ci--format-surface-stats
                   (plist-get row :portable))))
        rows
        "\n")
       "\n"))))

(defun consent-ci-render-markdown-summary (shards)
  "Render SHARDS as a GitHub Actions Markdown summary."
  (let ((shards (consent-ci--sort-shards shards)))
    (concat
     "## Test Shard Timing\n\n"
     "| Shard | Selector | Ran | Expected | Unexpected | Skipped | ERT time | Wall time | Slowest tests |\n"
     "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n"
     (mapconcat
      (lambda (shard)
        (format "| %s | `%s` | %d | %d | %d | %d | %s | %s | %s |"
                (consent-ci--markdown-cell (plist-get shard :name))
                (consent-ci--markdown-cell (plist-get shard :selector))
                (plist-get shard :ran)
                (plist-get shard :expected)
                (plist-get shard :unexpected)
                (plist-get shard :skipped)
                (consent-ci--format-seconds
                 (plist-get shard :ert-seconds))
                (consent-ci--format-seconds
                 (plist-get shard :wall-seconds))
                (consent-ci--format-slowest-tests shard)))
      shards
      "\n")
     "\n\n"
     (or (consent-ci--render-paired-validation-surfaces shards) "")
     (or (consent-ci--render-slow-check-timings shards) ""))))

(defun consent-ci--render-compact-shard-row (shard)
  "Render SHARD as one compact Markdown table row."
  (format "| %s | %d | %d | %d | %s | %s |"
          (consent-ci--markdown-cell (plist-get shard :name))
          (plist-get shard :ran)
          (plist-get shard :unexpected)
          (plist-get shard :skipped)
          (consent-ci--format-seconds
           (plist-get shard :ert-seconds))
          (consent-ci--format-seconds
           (plist-get shard :wall-seconds))))

(defun consent-ci--render-wall-time-summary (shards)
  "Return compact Markdown for SHARDS sorted by descending wall time."
  (when shards
    (concat
     "## Shard Timing by Wall Time\n\n"
     "Sorted by CI wall-clock time across all reported shards; "
     "detailed stable-order diagnostics remain below the fold.\n\n"
     "| Shard | Ran | Unexpected | Skipped | ERT time | Wall time |\n"
     "| --- | ---: | ---: | ---: | ---: | ---: |\n"
     (mapconcat #'consent-ci--render-compact-shard-row
                (consent-ci--sort-shards-by-wall-time shards)
                "\n")
     "\n\n")))

(defun consent-ci-render-pr-markdown-summary (shards &optional run-url)
  "Render SHARDS as an updatable pull request Markdown comment.
When RUN-URL is non-nil, include a link to the workflow run that produced the
summary."
  (let ((shards (consent-ci--sort-shards shards)))
    (concat
     consent-ci-pr-summary-marker
     "\n\n"
     (when (and run-url (not (string-empty-p run-url)))
       (format "Latest run: [GitHub Actions](%s).\n\n" run-url))
     (or (consent-ci--render-wall-time-summary shards) "")
     "<details>\n"
     "<summary>Detailed shard timings and diagnostic timings</summary>\n\n"
     (consent-ci-render-markdown-summary shards)
     "\n</details>\n")))

(defun consent-ci-write-summary (log-files &optional output-file)
  "Render LOG-FILES to OUTPUT-FILE, or print to standard output.
When OUTPUT-FILE is non-nil, append the summary so it can be used directly with
the GITHUB_STEP_SUMMARY file."
  (let ((markdown (consent-ci-render-markdown-summary
                   (mapcar #'consent-ci-parse-log-file log-files))))
    (if (and output-file (not (string-empty-p output-file)))
        (with-temp-buffer
          (insert markdown)
          (insert "\n")
          (write-region (point-min) (point-max) output-file t 'silent))
      (princ markdown))))

(defun consent-ci-write-pr-summary
    (log-files output-file &optional run-url)
  "Render a pull request timing comment for LOG-FILES to OUTPUT-FILE.
RUN-URL, when non-nil, links the comment back to the producing workflow run."
  (with-temp-buffer
    (insert
     (consent-ci-render-pr-markdown-summary
      (mapcar #'consent-ci-parse-log-file log-files)
      run-url))
    (write-region (point-min) (point-max) output-file nil 'silent)))

(defun consent-ci--batch-log-files ()
  "Return log file arguments passed after the batch command separator."
  (cl-remove "--" command-line-args-left :test #'string=))

(defun consent-ci-summary-batch-main ()
  "Batch entry point that summarizes paths from `command-line-args-left'."
  (let ((log-files (consent-ci--batch-log-files)))
    (unless log-files
      (error "No CI log files supplied"))
    (consent-ci-write-summary
     log-files
     (or (getenv "CONSENT_CI_SUMMARY_FILE")
         (getenv "GITHUB_STEP_SUMMARY")))))

(defun consent-ci-pr-summary-batch-main ()
  "Batch entry point that writes a pull request timing comment body."
  (let ((log-files (consent-ci--batch-log-files))
        (output-file (getenv "CONSENT_CI_PR_SUMMARY_FILE")))
    (unless log-files
      (error "No CI log files supplied"))
    (unless (and output-file (not (string-empty-p output-file)))
      (error "CONSENT_CI_PR_SUMMARY_FILE is required"))
    (consent-ci-write-pr-summary
     log-files
     output-file
     (getenv "CONSENT_CI_RUN_URL"))))

;;; Structured per-run record (#465)

;; Beyond the human-facing timing summary above, CI emits one machine-readable,
;; append-only record per run so longitudinal questions ("how did metric X drift
;; across the last N PRs") have a stable data source. The record is JSON Lines:
;; one self-describing object per line, tagged with `schema_version'. Schema
;; discipline: add fields freely, but never silently rename or repurpose one --
;; that is what breaks cross-run diffs. See docs/ci-run-record.md.

(defconst consent-ci-run-record-schema-version 1
  "Schema version for the structured per-run CI record.
Increment on any change to the record shape; never silently rename or
repurpose an existing field, since stable field names are what make the
record diffable across runs.")

(defun consent-ci--env-string (name)
  "Return environment variable NAME as a JSON string value, or nil when unset.
An unset or empty variable becomes nil so it serializes as JSON null rather
than an empty string."
  (let ((value (getenv name)))
    (when (and value (not (string-empty-p value)))
      value)))

(defun consent-ci--env-integer (name)
  "Return environment variable NAME parsed as an integer, or nil when unset."
  (let ((value (consent-ci--env-string name)))
    (when value
      (truncate (string-to-number value)))))

(defun consent-ci--env-boolean (name)
  "Return environment variable NAME as a JSON boolean, or nil when unset.
\"true\"/\"1\"/\"yes\" read as true; any other non-empty value reads as false."
  (let ((value (consent-ci--env-string name)))
    (when value
      (if (member (downcase value) '("true" "1" "yes"))
          t
        :json-false))))

(defun consent-ci--json-boolean (value)
  "Return non-nil VALUE as JSON true, nil as JSON false."
  (if value t :json-false))

(defun consent-ci--run-record-provenance ()
  "Return provenance sub-records gathered from the CI environment.
The workflow populates the GitHub-context and change-scope variables; any
unset variable serializes as JSON null."
  (list
   (cons "run"
         (list (cons "repository" (consent-ci--env-string "GITHUB_REPOSITORY"))
               (cons "event" (consent-ci--env-string "GITHUB_EVENT_NAME"))
               (cons "run_id" (consent-ci--env-string "GITHUB_RUN_ID"))
               (cons "run_attempt"
                     (consent-ci--env-integer "GITHUB_RUN_ATTEMPT"))
               (cons "run_url" (consent-ci--env-string "CONSENT_CI_RUN_URL"))
               (cons "actor" (consent-ci--env-string "GITHUB_ACTOR"))
               (cons "runner_os" (consent-ci--env-string "RUNNER_OS"))
               (cons "runner_arch" (consent-ci--env-string "RUNNER_ARCH"))))
   (cons "change"
         (list (cons "pr_number"
                     (consent-ci--env-integer "CONSENT_CI_PR_NUMBER"))
               (cons "base_ref" (consent-ci--env-string "CONSENT_CI_BASE_REF"))
               (cons "head_sha" (consent-ci--env-string "CONSENT_CI_HEAD_SHA"))
               (cons "base_sha" (consent-ci--env-string "CONSENT_CI_BASE_SHA"))
               (cons "changed_files"
                     (consent-ci--env-integer "CONSENT_CI_CHANGED_FILES"))
               (cons "insertions"
                     (consent-ci--env-integer "CONSENT_CI_INSERTIONS"))
               (cons "deletions"
                     (consent-ci--env-integer "CONSENT_CI_DELETIONS"))
               (cons "version_changed"
                     (consent-ci--env-boolean "CONSENT_CI_VERSION_CHANGED"))))
   (cons "parity"
         (list (cons "result"
                     (consent-ci--env-string "CONSENT_CI_PARITY_RESULT"))))))

(defun consent-ci--shard-record (shard)
  "Return SHARD as a JSON-ready alist for the per-run record.
`passed' is derived from the unexpected count; the source metadata and
docstring variant are split out of the shard name."
  (let ((variant (consent-ci--option-variant shard)))
    (list (cons "name" (consent-ci--shard-base-name shard))
          (cons "selector" (plist-get shard :selector))
          (cons "source_metadata" (car variant))
          (cons "docstrings" (cdr variant))
          (cons "ran" (plist-get shard :ran))
          (cons "expected" (plist-get shard :expected))
          (cons "unexpected" (plist-get shard :unexpected))
          (cons "skipped" (plist-get shard :skipped))
          (cons "ert_seconds" (plist-get shard :ert-seconds))
          (cons "wall_seconds" (plist-get shard :wall-seconds))
          (cons "passed"
                (consent-ci--json-boolean
                 (= (or (plist-get shard :unexpected) 0) 0))))))

(defun consent-ci--run-record-totals (shards)
  "Return aggregate totals across SHARDS as a JSON-ready alist."
  (let ((unexpected (consent-ci--sum-shard-field shards :unexpected)))
    (list (cons "shards" (length shards))
          (cons "ran" (consent-ci--sum-shard-field shards :ran))
          (cons "expected" (consent-ci--sum-shard-field shards :expected))
          (cons "unexpected" unexpected)
          (cons "skipped" (consent-ci--sum-shard-field shards :skipped))
          (cons "ert_seconds" (consent-ci--sum-shard-field shards :ert-seconds))
          (cons "wall_seconds"
                (consent-ci--sum-shard-field shards :wall-seconds))
          (cons "all_passed" (consent-ci--json-boolean (= unexpected 0))))))

(defun consent-ci-build-run-record (shards)
  "Return the structured per-run CI record for SHARDS as a JSON-ready alist.
Provenance fields come from the CI environment; per-shard outcomes and
totals come from the parsed shard logs.  Encode the result with
`consent-ci-render-run-record'."
  (let ((shards (consent-ci--sort-shards shards)))
    (append
     (list (cons "schema_version" consent-ci-run-record-schema-version)
           (cons "generated_at" (consent-ci--env-string "CONSENT_CI_TIMESTAMP")))
     (consent-ci--run-record-provenance)
     (list (cons "totals" (consent-ci--run-record-totals shards))
           (cons "shards"
                 (vconcat (mapcar #'consent-ci--shard-record shards)))))))

(defun consent-ci-render-run-record (shards)
  "Render SHARDS as a single-line JSON per-run CI record."
  (let ((json-encoding-pretty-print nil))
    (json-encode (consent-ci-build-run-record shards))))

(defun consent-ci-write-run-record (log-files output-file)
  "Append the per-run CI record for LOG-FILES as one JSON line to OUTPUT-FILE.
The file is JSON Lines, so appending keeps prior runs intact."
  (let ((line (consent-ci-render-run-record
               (mapcar #'consent-ci-parse-log-file log-files))))
    (with-temp-buffer
      (insert line)
      (insert "\n")
      (write-region (point-min) (point-max) output-file t 'silent))))

(defun consent-ci-run-record-batch-main ()
  "Batch entry point that writes the structured per-run CI record.
Reads shard log paths after the `--' separator and the destination from
the CONSENT_CI_RUN_RECORD_FILE environment variable."
  (let ((log-files (consent-ci--batch-log-files))
        (output-file (getenv "CONSENT_CI_RUN_RECORD_FILE")))
    (unless log-files
      (error "No CI log files supplied"))
    (unless (and output-file (not (string-empty-p output-file)))
      (error "CONSENT_CI_RUN_RECORD_FILE is required"))
    (consent-ci-write-run-record log-files output-file)))

(provide 'consent-ci)

;;; consent-ci.el ends here
