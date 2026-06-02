;;; consent-ci.el --- CI shard timing reports  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helpers for parsing Consent Scheme ERT shard logs and rendering the GitHub
;; Actions step summary used by the repository test workflow.

;;; Code:

(require 'cl-lib)
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
    ("Portable R7RS Gambit native Consent Scheme full suite" . 4)
    ("Portable R7RS Racket full suite" . 5)
    ("Portable R7RS Compiled Consent Scheme full suite" . 6)
    ("Portable R7RS Guile full suite" . 7)
    ("Portable R7RS Gauche full suite" . 8)
    ("Portable Chibi-backed eval" . 10)
    ("Portable Chibi-backed rest" . 11)
    ("Portable Chibi-backed ERT" . 11)
    ("Portable Gambit-backed suite" . 12)
    ("Emacs core language/runtime" . 20)
    ("Emacs library/conformance" . 21)
    ("Emacs capabilities/policy" . 22)
    ("Emacs tools/docs/integration" . 23))
  "Preferred display order for CI shard summaries.")

(defconst consent-ci--portable-host-order
  '(("Chibi" . 0)
    ("Gambit" . 1)
    ("Gambit native Consent Scheme" . 2)
    ("Racket" . 3)
    ("Compiled Consent Scheme" . 4)
    ("Guile" . 5)
    ("Gauche" . 6))
  "Preferred display order for portable host timing summaries.")

(defconst consent-ci--source-metadata-order
  '(("on" . 0)
    ("off" . 1))
  "Preferred display order for source metadata timing variants.")

(defconst consent-ci--docstring-retention-order
  '(("full" . 0)
    ("simple" . 1)
    ("none" . 2))
  "Preferred display order for docstring retention timing variants.")

(defconst consent-ci--option-variants
  '(("on" . "full")
    ("on" . "simple")
    ("on" . "none")
    ("off" . "full")
    ("off" . "simple")
    ("off" . "none"))
  "Canonical source metadata/docstring timing variant order.")

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

(defun consent-ci--option-variant-label (variant)
  "Return compact display label for source metadata/docstring VARIANT."
  (format "%s/%s" (car variant) (cdr variant)))

(defun consent-ci--render-timing-cell (row &optional omit-skipped)
  "Return compact timing text for ROW.
OMIT-SKIPPED suppresses skipped-count annotations for tables that already show
skipped totals separately."
  (if row
      (let (notes)
        (when (> (or (plist-get row :unexpected) 0) 0)
          (push (format "%d unexpected" (plist-get row :unexpected)) notes))
        (when (and (not omit-skipped)
                   (> (or (plist-get row :skipped) 0) 0))
          (push (format "%d skipped" (plist-get row :skipped)) notes))
        (concat
         (format "%s (%s wall)"
                 (consent-ci--format-seconds
                  (plist-get row :ert-seconds))
                 (consent-ci--format-seconds
                  (plist-get row :wall-seconds)))
         (when notes
           (concat "; " (mapconcat #'identity (nreverse notes) "; ")))))
    "n/a"))

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

(defun consent-ci--find-shard-named (shards names)
  "Return the first shard in SHARDS whose name appears in NAMES."
  (cl-find-if
   (lambda (shard)
     (member (plist-get shard :name) names))
   shards))

(defun consent-ci--sum-shard-field (shards field)
  "Return the numeric sum of FIELD across SHARDS."
  (let ((total 0))
    (dolist (shard shards total)
      (cl-incf total (or (plist-get shard field) 0)))))

(defun consent-ci--chibi-portable-host-row (shards)
  "Return an aggregate Chibi portable host row from split SHARDS."
  (let ((eval-shard
         (consent-ci--find-shard-named
          shards
          '("Portable R7RS Chibi evaluator subset"
            "Portable Chibi-backed eval")))
        (rest-shard
         (consent-ci--find-shard-named
          shards
          '("Portable R7RS Chibi non-evaluator subset"
            "Portable Chibi-backed rest"
            "Portable Chibi-backed ERT"))))
    (when (and eval-shard rest-shard)
      (let ((chibi-shards (list eval-shard rest-shard)))
        (list :host "Chibi"
              :coverage "full suite (2 CI shards)"
              :unexpected (consent-ci--sum-shard-field
                           chibi-shards :unexpected)
              :skipped (consent-ci--sum-shard-field
                        chibi-shards :skipped)
              :ert-seconds (consent-ci--sum-shard-field
                            chibi-shards :ert-seconds)
              :wall-seconds (consent-ci--sum-shard-field
                             chibi-shards :wall-seconds))))))

(defun consent-ci--portable-full-suite-host (shard)
  "Return the portable host name for full-suite SHARD, or nil."
  (let ((name (plist-get shard :name)))
    (cond
     ((string-match
       "\\`Portable R7RS \\(.+\\) full suite\\(?: / .*\\)?\\'"
       name)
      (match-string 1 name))
     ((string= name "Portable Gambit-backed suite")
      "Gambit")
     (t nil))))

(defun consent-ci--portable-full-suite-coverage (shard)
  "Return compact coverage text for portable full-suite SHARD."
  (let ((name (plist-get shard :name)))
    (if (string-match
         "\\`Portable R7RS .+ full suite\\(?: / \\(.*\\)\\)?\\'"
         name)
        (if-let ((variant (match-string 1 name)))
            (concat "full suite, " (string-replace " / " ", " variant))
          "full suite")
      "full suite")))

(defun consent-ci--portable-host-row (shard)
  "Return a compact portable host timing row for SHARD, or nil."
  (let ((host (consent-ci--portable-full-suite-host shard)))
    (when host
      (let ((variant (consent-ci--option-variant shard)))
        (list :host host
              :coverage (consent-ci--portable-full-suite-coverage shard)
              :source-metadata (car variant)
              :docstrings (cdr variant)
              :unexpected (plist-get shard :unexpected)
              :skipped (plist-get shard :skipped)
              :ert-seconds (plist-get shard :ert-seconds)
              :wall-seconds (plist-get shard :wall-seconds))))))

(defun consent-ci--portable-host-row-sort-key (row)
  "Return display sort key for portable host ROW."
  (or (cdr (assoc (plist-get row :host)
                  consent-ci--portable-host-order))
      99))

(defun consent-ci--portable-host-row-less-p (left right)
  "Return non-nil when LEFT should display before RIGHT."
  (let ((left-host (consent-ci--portable-host-row-sort-key left))
        (right-host (consent-ci--portable-host-row-sort-key right))
        (left-variant (cons (plist-get left :source-metadata)
                            (plist-get left :docstrings)))
        (right-variant (cons (plist-get right :source-metadata)
                             (plist-get right :docstrings))))
    (cond
     ((/= left-host right-host)
      (< left-host right-host))
     ((and (car left-variant) (car right-variant))
      (< (consent-ci--option-variant-sort-key left-variant)
         (consent-ci--option-variant-sort-key right-variant)))
     ((car left-variant) nil)
     ((car right-variant) t)
     (t (string< (plist-get left :coverage)
                 (plist-get right :coverage))))))

(defun consent-ci--portable-host-rows (shards)
  "Return comparable portable host timing rows for SHARDS."
  (let ((chibi-row (consent-ci--chibi-portable-host-row shards))
        rows)
    (when chibi-row
      (push chibi-row rows))
    (dolist (shard shards)
      (let ((row (consent-ci--portable-host-row shard)))
        (when (and row
                   (not (and chibi-row
                             (string= (plist-get row :host) "Chibi"))))
          (push row rows))))
    (sort rows #'consent-ci--portable-host-row-less-p)))

(defun consent-ci--render-portable-host-row (row)
  "Render portable host timing ROW as one Markdown table row."
  (format "| %s | %s | %d | %d | %s | %s |"
          (consent-ci--markdown-cell (plist-get row :host))
          (consent-ci--markdown-cell (plist-get row :coverage))
          (plist-get row :unexpected)
          (plist-get row :skipped)
          (consent-ci--format-seconds
           (plist-get row :ert-seconds))
          (consent-ci--format-seconds
           (plist-get row :wall-seconds))))

(defun consent-ci--portable-variant-row-p (row)
  "Return non-nil when ROW is one source metadata/docstring timing variant."
  (and (plist-get row :source-metadata)
       (plist-get row :docstrings)))

(defun consent-ci--sorted-portable-hosts (rows)
  "Return unique portable host names from ROWS in display order."
  (let (hosts)
    (dolist (row rows)
      (let ((host (plist-get row :host)))
        (unless (member host hosts)
          (push host hosts))))
    (sort hosts
          (lambda (left right)
            (< (or (cdr (assoc left consent-ci--portable-host-order)) 99)
               (or (cdr (assoc right consent-ci--portable-host-order)) 99))))))

(defun consent-ci--find-portable-variant-row (rows host variant)
  "Return ROWS entry for HOST and source metadata/docstring VARIANT."
  (cl-find-if
   (lambda (row)
     (and (string= (plist-get row :host) host)
          (string= (plist-get row :source-metadata) (car variant))
          (string= (plist-get row :docstrings) (cdr variant))))
   rows))

(defun consent-ci--render-portable-host-matrix (rows)
  "Return Markdown matrix for portable host timing variant ROWS."
  (let ((hosts (consent-ci--sorted-portable-hosts rows)))
    (concat
     "Host cells show ERT time with CI wall-clock time in parentheses.\n\n"
     "| Syntax metadata | Docstrings | "
     (mapconcat #'consent-ci--markdown-cell hosts " | ")
     " |\n"
     "| --- | --- | "
     (mapconcat (lambda (_host) "---:") hosts " | ")
     " |\n"
     (mapconcat
      (lambda (variant)
        (concat
         "| "
         (consent-ci--markdown-cell (car variant))
         " | "
         (consent-ci--markdown-cell (cdr variant))
         " | "
         (mapconcat
          (lambda (host)
            (consent-ci--render-timing-cell
             (consent-ci--find-portable-variant-row rows host variant)))
          hosts
          " | ")
         " |"))
      consent-ci--option-variants
      "\n")
     "\n\n")))

(defun consent-ci--render-portable-host-table (rows &optional chibi-present)
  "Return Markdown table for non-matrix portable host timing ROWS.
CHIBI-PRESENT adds a note explaining aggregate Chibi rows."
  (concat
   (when chibi-present
     "Chibi is split across CI shards; this table aggregates those shards for host-to-host timing comparison.\n\n")
   "| Host | Coverage | Unexpected | Skipped | ERT time | Wall time |\n"
   "| --- | --- | ---: | ---: | ---: | ---: |\n"
   (mapconcat #'consent-ci--render-portable-host-row rows "\n")
   "\n\n"))

(defun consent-ci--render-portable-host-summary (shards)
  "Return a top-level portable host timing comparison for SHARDS."
  (let ((rows (consent-ci--portable-host-rows shards)))
    (when rows
      (let* ((variant-rows (cl-remove-if-not
                            #'consent-ci--portable-variant-row-p
                            rows))
             (plain-rows (cl-remove-if
                          #'consent-ci--portable-variant-row-p
                          rows))
             (chibi-present
              (cl-some
               (lambda (row)
                 (string= (plist-get row :host) "Chibi"))
               plain-rows)))
        (concat
         "## Portable Host Timing\n\n"
         (when variant-rows
           (consent-ci--render-portable-host-matrix variant-rows))
         (when plain-rows
           (consent-ci--render-portable-host-table
            plain-rows
            chibi-present)))))))

(defun consent-ci--emacs-shard-p (shard)
  "Return non-nil when SHARD is an Emacs-hosted timing shard."
  (string-prefix-p "Emacs " (plist-get shard :name)))

(defun consent-ci--variant-shard-p (shard)
  "Return non-nil when SHARD has source metadata/docstring variant metadata."
  (not (null (consent-ci--option-variant shard))))

(defun consent-ci--unique-emacs-base-names (shards)
  "Return unique Emacs logical shard names from SHARDS in display order."
  (let (names)
    (dolist (shard (consent-ci--sort-shards shards))
      (let ((name (consent-ci--shard-base-name shard)))
        (unless (member name names)
          (push name names))))
    (nreverse names)))

(defun consent-ci--find-emacs-variant-shard (shards base-name variant)
  "Return Emacs SHARDS entry matching BASE-NAME and option VARIANT."
  (cl-find-if
   (lambda (shard)
     (let ((shard-variant (consent-ci--option-variant shard)))
       (and (string= (consent-ci--shard-base-name shard) base-name)
            shard-variant
            (string= (car shard-variant) (car variant))
            (string= (cdr shard-variant) (cdr variant)))))
   shards))

(defun consent-ci--field-range-text (shards field)
  "Return compact FIELD value text for SHARDS."
  (let* ((values (sort (delete-dups
                        (mapcar (lambda (shard)
                                  (or (plist-get shard field) 0))
                                shards))
                       #'<))
         (first (car values))
         (last (car (last values))))
    (if (= first last)
        (format "%d" first)
      (format "%d-%d" first last))))

(defun consent-ci--render-emacs-variant-row (base-name shards)
  "Return one Emacs timing matrix row for BASE-NAME across SHARDS."
  (let ((base-shards
         (cl-remove-if-not
          (lambda (shard)
            (string= (consent-ci--shard-base-name shard) base-name))
          shards)))
    (concat
     "| "
     (consent-ci--markdown-cell base-name)
     " | "
     (consent-ci--field-range-text base-shards :ran)
     " | "
     (consent-ci--field-range-text base-shards :skipped)
     " | "
     (mapconcat
      (lambda (variant)
        (consent-ci--render-timing-cell
         (consent-ci--find-emacs-variant-shard
          base-shards
          base-name
          variant)
         t))
      consent-ci--option-variants
      " | ")
     " |")))

(defun consent-ci--render-emacs-variant-summary (shards)
  "Return pivoted Markdown for Emacs option-matrix timing SHARDS."
  (concat
   "Option columns use `source metadata/docstrings`; cells show ERT time with CI wall-clock time in parentheses.\n\n"
   "| Shard | Ran | Skipped | "
   (mapconcat #'consent-ci--option-variant-label
              consent-ci--option-variants
              " | ")
   " |\n"
   "| --- | ---: | ---: | "
   (mapconcat (lambda (_variant) "---:") consent-ci--option-variants " | ")
   " |\n"
   (mapconcat
    (lambda (base-name)
      (consent-ci--render-emacs-variant-row base-name shards))
    (consent-ci--unique-emacs-base-names shards)
    "\n")
   "\n\n"))

(defun consent-ci--render-emacs-plain-summary (shards)
  "Return compact Markdown for non-matrix Emacs-hosted timing SHARDS."
  (concat
   "| Shard | Ran | Unexpected | Skipped | ERT time | Wall time |\n"
   "| --- | ---: | ---: | ---: | ---: | ---: |\n"
   (mapconcat #'consent-ci--render-compact-shard-row
              shards
              "\n")
   "\n\n"))

(defun consent-ci--render-compact-emacs-summary (shards)
  "Return compact Markdown for Emacs-hosted timing SHARDS."
  (let* ((emacs-shards (cl-remove-if-not
                        #'consent-ci--emacs-shard-p
                        (consent-ci--sort-shards shards)))
         (variant-shards (cl-remove-if-not
                          #'consent-ci--variant-shard-p
                          emacs-shards))
         (plain-shards (cl-remove-if
                        #'consent-ci--variant-shard-p
                        emacs-shards)))
    (when emacs-shards
      (concat
       "## Emacs Shard Timing\n\n"
       (when variant-shards
         (consent-ci--render-emacs-variant-summary variant-shards))
       (when plain-shards
         (consent-ci--render-emacs-plain-summary plain-shards))))))

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
     (or (consent-ci--render-portable-host-summary shards) "")
     (or (consent-ci--render-compact-emacs-summary shards) "")
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

(provide 'consent-ci)

;;; consent-ci.el ends here
