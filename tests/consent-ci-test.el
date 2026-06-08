;;; consent-ci-test.el --- CI reporting tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for Consent Scheme CI shard timing summary helpers.

;;; Code:

(require 'ert)
(require 'consent-ci)

(defun consent-ci-test--write-log (contents)
  "Write CONTENTS to a temporary CI log and return its path."
  (let ((path (make-temp-file "consent-ci-log-" nil ".log")))
    (with-temp-file path
      (insert contents))
    path))

(defun consent-ci-test--repo-file-string (relative-path)
  "Return RELATIVE-PATH from the repository root as a string."
  (let ((root (if (boundp 'consent--test-root)
                  consent--test-root
                default-directory)))
    (with-temp-buffer
      (insert-file-contents (expand-file-name relative-path root))
      (buffer-string))))

(ert-deftest consent-ci-test-parses-result-counts-and-slowest-tests ()
  "Parse ERT shard output plus CI wall-clock metadata."
  (let* ((log (consent-ci-test--write-log
               (concat
                "Running 3 tests (2026-05-25 13:00:00-0700, selector `x')\n"
                "   passed  1/3  consent-reader-test-fast (0.010000 sec)\n"
                "   skipped 2/3  consent-reader-test-skip (0.020000 sec)\n"
                "   failed  3/3  consent-reader-test-slow (1.250000 sec)\n"
                "\n"
                "Ran 3 tests, 2 results as expected, 1 unexpected, 1 skipped "
                "(2026-05-25 13:00:02-0700, 1.280000 sec)\n"
                "CONSENT_CI_CHECK_SECONDS=source-library-docstring-reflection 6.800\n"
                "CONSENT_CI_SHARD_NAME=Emacs-hosted ERT\n"
                "CONSENT_CI_SHARD_SELECTOR=(not \"consent-scheme-.*\")\n"
                "CONSENT_CI_WALL_SECONDS=2\n")))
         (shard (consent-ci-parse-log-file log))
         (slowest (consent-ci-shard-slowest-tests shard 2))
         (check-timings (plist-get shard :check-timings)))
    (unwind-protect
        (progn
          (should (equal (plist-get shard :name) "Emacs-hosted ERT"))
          (should (equal (plist-get shard :selector)
                         "(not \"consent-scheme-.*\")"))
          (should (= (plist-get shard :ran) 3))
          (should (= (plist-get shard :expected) 2))
          (should (= (plist-get shard :unexpected) 1))
          (should (= (plist-get shard :skipped) 1))
          (should (= (plist-get shard :ert-seconds) 1.28))
          (should (= (plist-get shard :wall-seconds) 2.0))
          (should (= (length check-timings) 1))
          (should (equal (plist-get (car check-timings) :name)
                         "source-library-docstring-reflection"))
          (should (= (plist-get (car check-timings) :seconds) 6.8))
          (should (equal (mapcar (lambda (test) (plist-get test :name))
                                 slowest)
                         '("consent-reader-test-slow"
                           "consent-reader-test-skip"))))
      (delete-file log))))

(ert-deftest consent-ci-test-renders-summary-with-comparable-surfaces ()
  "Render shard rows and paired Emacs/portable validation surface rows."
  (let* ((emacs-log
          (consent-ci-test--write-log
           (concat
            "Running 2 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/2  consent-reader-test-booleans (0.040000 sec)\n"
            "   passed  2/2  consent-conformance-test-implemented-cases-run (0.500000 sec)\n"
            "\n"
            "Ran 2 tests, 2 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.540000 sec)\n"
            "CONSENT_CI_SHARD_NAME=Emacs-hosted ERT\n"
            "CONSENT_CI_SHARD_SELECTOR=(not \"consent-scheme-.*\")\n"
            "CONSENT_CI_WALL_SECONDS=1\n")))
         (portable-log
          (consent-ci-test--write-log
           (concat
            "Running 3 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/3  consent-scheme-reader-test-r7rs-suite (0.030000 sec)\n"
            "   passed  2/3  consent-scheme-eval-test-r7rs-suite (0.200000 sec)\n"
            "   passed  3/3  consent-scheme-fixture-test-r7rs-suite (0.080000 sec)\n"
            "\n"
            "Ran 3 tests, 3 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.310000 sec)\n"
            "CONSENT_CI_CHECK_SECONDS=standard-inexact-transcendentals 0.700\n"
            "CONSENT_CI_SHARD_NAME=Portable R7RS Chibi evaluator subset\n"
            "CONSENT_CI_SHARD_SELECTOR=\"consent-scheme-.*\"\n"
            "CONSENT_CI_WALL_SECONDS=1\n")))
         (markdown
          (consent-ci-render-markdown-summary
           (mapcar #'consent-ci-parse-log-file
                   (list portable-log emacs-log)))))
    (unwind-protect
        (progn
          (should (string-match-p "| Portable R7RS Chibi evaluator subset |" markdown))
          (should (string-match-p "| Emacs-hosted ERT |" markdown))
          (should (string-match-p "| Reader | 1 / 0\\.040s | 1 / 0\\.030s |"
                                  markdown))
          (should (string-match-p "| Evaluator | 0 / 0\\.000s | 1 / 0\\.200s |"
                                  markdown))
          (should (string-match-p
                   "| Fixture/conformance | 1 / 0\\.500s | 1 / 0\\.080s |"
                   markdown))
          (should (string-match-p "## Slow Portable Checks" markdown))
          (should (string-match-p
                   "| Portable R7RS Chibi evaluator subset | `standard-inexact-transcendentals` | 0\\.700s |"
                   markdown)))
      (delete-file emacs-log)
      (delete-file portable-log))))

(ert-deftest consent-ci-test-renders-pr-summary-comment ()
  "Render a compact pull request timing comment with detailed summary content."
  (let* ((log
          (consent-ci-test--write-log
           (concat
            "Running 1 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/1  consent-reader-test-booleans (0.040000 sec)\n"
            "\n"
            "Ran 1 tests, 1 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.040000 sec)\n"
            "CONSENT_CI_SHARD_NAME=Emacs core language/runtime\n"
            "CONSENT_CI_SHARD_SELECTOR=\"consent-reader.*\"\n"
            "CONSENT_CI_WALL_SECONDS=1\n")))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list (consent-ci-parse-log-file log))
           "https://github.example/run/1")))
    (unwind-protect
        (progn
          (should (string-match-p consent-ci-pr-summary-marker markdown))
          (should (string-match-p
                   "Latest run: \\[GitHub Actions\\](https://github.example/run/1)"
                   markdown))
          (should (string-match-p
                   "| Emacs core language/runtime | 1 | 0 | 0 | 0\\.040s | 1\\.000s |"
                   markdown))
          (should (string-match-p
                   "<summary>Detailed shard timings and diagnostic timings</summary>"
                   markdown))
          (should (string-match-p "`consent-reader-test-booleans` 0\\.040s"
                                  markdown)))
      (delete-file log))))

(ert-deftest consent-ci-test-pr-summary-aggregates-chibi-host-timing ()
  "Aggregate split Chibi shards in the top-level portable host comparison."
  (let* ((portable-eval-shard '(:name "Portable R7RS Chibi evaluator subset"
                                      :selector "portable-eval"
                                      :ran 1
                                      :expected 1
                                      :unexpected 0
                                      :skipped 0
                                      :ert-seconds 94.0
                                      :wall-seconds 95.0
                                      :tests nil))
         (portable-rest-shard '(:name "Portable R7RS Chibi non-evaluator subset"
                                      :selector "portable-rest"
                                      :ran 16
                                      :expected 16
                                      :unexpected 0
                                      :skipped 0
                                      :ert-seconds 18.0
                                      :wall-seconds 18.0
                                      :tests nil))
         (portable-gambit-shard '(:name "Portable R7RS Gambit full suite"
                                        :selector "portable-gambit"
                                        :ran 1
                                        :expected 1
                                        :unexpected 0
                                        :skipped 0
                                        :ert-seconds 14.0
                                        :wall-seconds 14.0
                                        :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list portable-gambit-shard
                 portable-rest-shard
                 portable-eval-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (should (string-match-p "## Portable Host Timing" above-fold))
    (should (string-match-p
             "| Chibi | full suite (2 CI shards) | 0 | 0 | 112\\.000s | 113\\.000s |"
             above-fold))
    (should (string-match-p
             "| Gambit | full suite | 0 | 0 | 14\\.000s | 14\\.000s |"
             above-fold))
    (should-not
     (string-match-p "Portable R7RS Chibi evaluator subset" above-fold))
    (should
     (string-match-p "Portable R7RS Chibi evaluator subset" markdown))))

(ert-deftest consent-ci-test-pr-summary-renders-without-chibi-host ()
  "Render portable host comparison cleanly when Chibi is absent."
  (let* ((portable-gambit-shard '(:name "Portable R7RS Gambit full suite"
                                        :selector "portable-gambit"
                                        :ran 1
                                        :expected 1
                                        :unexpected 0
                                        :skipped 0
                                        :ert-seconds 14.0
                                        :wall-seconds 14.0
                                        :tests nil))
         (portable-racket-shard '(:name "Portable R7RS Racket full suite"
                                        :selector "portable-racket"
                                        :ran 1
                                        :expected 1
                                        :unexpected 0
                                        :skipped 0
                                        :ert-seconds 12.0
                                        :wall-seconds 13.0
                                        :tests nil))
         (portable-compiled-shard '(:name "Portable R7RS Compiled Consent Scheme full suite"
                                          :selector "portable-compiled"
                                          :ran 1
                                          :expected 1
                                          :unexpected 0
                                          :skipped 0
                                          :ert-seconds 10.0
                                          :wall-seconds 11.0
                                          :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list portable-compiled-shard
                 portable-racket-shard
                 portable-gambit-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (should (string-match-p "## Portable Host Timing" above-fold))
    (should (string-match-p
             "| Gambit | full suite | 0 | 0 | 14\\.000s | 14\\.000s |"
             above-fold))
    (should (string-match-p
             "| Racket | full suite | 0 | 0 | 12\\.000s | 13\\.000s |"
             above-fold))
    (should (string-match-p
             "| Compiled Consent Scheme | full suite | 0 | 0 | 10\\.000s | 11\\.000s |"
             above-fold))
    (should-not (string-match-p "Chibi is split" above-fold))
    (should-not (string-match-p "| Chibi |" above-fold))))

(ert-deftest consent-ci-test-pr-summary-renders-option-variant-host-rows ()
  "Pivot option-matrix portable shards so host comparisons are scannable."
  (let* ((portable-gambit-shard
          '(:name "Portable R7RS Gambit full suite / source metadata off / docstrings none"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 11.0
            :wall-seconds 12.0
            :tests nil))
         (portable-racket-shard
          '(:name "Portable R7RS Racket full suite / source metadata on / docstrings simple"
            :selector "portable-racket"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 7.0
            :wall-seconds 8.0
            :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list portable-racket-shard portable-gambit-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (should (string-match-p "## Portable Host Timing" above-fold))
    (should (string-match-p
             "| Syntax metadata | Docstrings | Gambit | Racket |"
             above-fold))
    (should (string-match-p
             "| on | simple | n/a | 7\\.000s (8\\.000s wall) |"
             above-fold))
    (should (string-match-p
             "| off | none | 11\\.000s (12\\.000s wall) | n/a |"
             above-fold))
    (should-not
     (string-match-p "full suite, source metadata" above-fold))))

(ert-deftest consent-ci-test-pr-summary-renders-emacs-option-matrix ()
  "Pivot Emacs option-matrix shards by logical shard."
  (let* ((core-full-shard
          '(:name "Emacs core language/runtime / source metadata on / docstrings full"
            :selector "core"
            :ran 73
            :expected 73
            :unexpected 0
            :skipped 0
            :ert-seconds 52.0
            :wall-seconds 53.0
            :tests nil))
         (core-none-shard
          '(:name "Emacs core language/runtime / source metadata off / docstrings none"
            :selector "core"
            :ran 73
            :expected 73
            :unexpected 0
            :skipped 0
            :ert-seconds 49.0
            :wall-seconds 50.0
            :tests nil))
         (library-full-shard
          '(:name "Emacs library/conformance / source metadata on / docstrings full"
            :selector "library"
            :ran 94
            :expected 87
            :unexpected 0
            :skipped 7
            :ert-seconds 51.0
            :wall-seconds 52.0
            :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list library-full-shard core-none-shard core-full-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (should (string-match-p "## Emacs Shard Timing" above-fold))
    (should (string-match-p
             "| Shard | Ran | Skipped | on/full | on/simple | on/none | off/full | off/simple | off/none |"
             above-fold))
    (should (string-match-p
             "| Emacs core language/runtime | 73 | 0 | 52\\.000s (53\\.000s wall) | n/a | n/a | n/a | n/a | 49\\.000s (50\\.000s wall) |"
             above-fold))
    (should (string-match-p
             "| Emacs library/conformance | 94 | 7 | 51\\.000s (52\\.000s wall) | n/a | n/a | n/a | n/a | n/a |"
             above-fold))
    (should-not
     (string-match-p "Emacs core language/runtime / source metadata" above-fold))))

(ert-deftest consent-ci-test-pr-summary-omits-empty-paired-surfaces ()
  "Avoid showing zero portable paired-surface rows for whole-suite hosts."
  (let* ((portable-gambit-shard
          '(:name "Portable R7RS Gambit full suite / source metadata on / docstrings full"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 14.0
            :wall-seconds 15.0
            :tests ((:name "consent-scheme-gambit-host-test-r7rs-suite"
                     :seconds 14.0))))
         (emacs-shard
          '(:name "Emacs core language/runtime / source metadata on / docstrings full"
            :selector "core"
            :ran 73
            :expected 73
            :unexpected 0
            :skipped 0
            :ert-seconds 52.0
            :wall-seconds 53.0
            :tests ((:name "consent-reader-test-booleans"
                     :seconds 0.040))))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list emacs-shard portable-gambit-shard))))
    (should-not (string-match-p "## Paired Validation Surfaces" markdown))
    (should (string-match-p "## Test Shard Timing" markdown))))

(ert-deftest consent-ci-test-default-ci-omits-chibi-shards ()
  "Keep Chibi as an explicit optional target, not a default CI shard."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml"))
        (makefile (consent-ci-test--repo-file-string "Makefile")))
    (should-not (string-match-p "name: portable R7RS / Chibi" workflow))
    (should-not (string-match-p "[[:space:]]+- test-portable\n" workflow))
    ;; Chibi runs the same aggregate host suite as its peers but stays out of
    ;; the default/CI portable shard set, reachable only through its own target.
    (should-not (string-match-p
                 "CONSENT_PORTABLE_TEST_SHARD_TARGETS \\?=.*test-portable-chibi"
                 makefile))
    (should (string-match-p
             "CONSENT_PORTABLE_CHIBI_TEST_SELECTOR \\?="
             makefile))
    (should (string-match-p "^test-portable-chibi:" makefile))))

(ert-deftest consent-ci-test-workflow-matrixes-host-option-variants ()
  "Deal out CI shards across host, syntax metadata, and docstring retention."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    ;; The trimmed extra-host / emacs-hosted / parity jobs still read their
    ;; syntax and docstring axes straight off the matrix context.
    (should (string-match-p
             "CONSENT_TEST_SOURCE_METADATA: \\${{ matrix.source_metadata }}"
             workflow))
    (should (string-match-p
             "CONSENT_TEST_DOCSTRING_RETENTION: \\${{ matrix.docstring_retention }}"
             workflow))
    ;; The canonical Gambit and Emacs-core jobs carry a per-combo `native`/
    ;; metadata object instead of two literal axes (#481), so their env and
    ;; artifact names index through `matrix.combo`.
    (should (string-match-p
             "CONSENT_TEST_SOURCE_METADATA: \\${{ matrix.combo.source_metadata }}"
             workflow))
    (should (string-match-p
             "CONSENT_TEST_DOCSTRING_RETENTION: \\${{ matrix.combo.docstring_retention }}"
             workflow))
    (should (string-match-p
             "portable-gambit-\\${{ matrix.combo.source_metadata }}-docstrings-\\${{ matrix.combo.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p
             "portable-gambit-native-\\${{ matrix.combo.source_metadata }}-docstrings-\\${{ matrix.combo.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p
             "portable-\\${{ matrix.host.host }}-\\${{ matrix.source_metadata }}-docstrings-\\${{ matrix.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p "host: compiled" workflow))
    (should (string-match-p "make test-portable-gambit-native" workflow))
    (should (string-match-p
             "Portable R7RS Gambit native Consent Scheme full suite"
             workflow))
    (should (string-match-p "make_target: test-portable-compiled" workflow))
    (should (string-match-p
             "Portable R7RS Compiled Consent Scheme full suite"
             workflow))
    ;; Emacs-core indexes its log through the combo too; the other Emacs shards
    ;; keep the bare matrix axes.
    (should (string-match-p
             "emacs-\\${{ matrix.shard.shard }}-\\${{ matrix.combo.source_metadata }}-docstrings-\\${{ matrix.combo.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p
             "emacs-\\${{ matrix.shard.shard }}-\\${{ matrix.source_metadata }}-docstrings-\\${{ matrix.docstring_retention }}\\.log"
             workflow))))

(ert-deftest consent-ci-test-trims-per-push-matrix-and-keeps-full-lane ()
  "Trim the per-push CI matrix while keeping a scheduled exhaustive lane."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    ;; Exhaustive lane triggers are present.
    (should (string-match-p "^  schedule:" workflow))
    (should (string-match-p "cron:" workflow))
    (should (string-match-p "^  workflow_dispatch:" workflow))
    ;; The trimmed jobs drive their syntax/docstring axes from the event name,
    ;; so schedule / workflow_dispatch expand back to the full cross-product.
    ;; job-level `if:` cannot read the matrix context, so the trim lives in the
    ;; matrix axis expression instead.
    (should (string-match-p
             "(github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && fromJSON"
             workflow))
    ;; Per-push lane falls back to the canonical on/full combo.
    (should (string-match-p "|| fromJSON('\\[\"on\"\\]')" workflow))
    (should (string-match-p "|| fromJSON('\\[\"full\"\\]')" workflow))
    ;; One portable host (Gambit) and one Emacs shard (core) keep the full
    ;; syntax/docstring cross on the exhaustive lane in their own jobs.
    (should (string-match-p "^  test-portable-gambit:" workflow))
    (should (string-match-p "^  test-emacs-core:" workflow))
    ;; The trimmed jobs must not statically pin the full axis.
    (should-not (string-match-p "matrix.source_metadata == 'on'" workflow))
    ;; #481: the de-feature cross on Gambit and Emacs-core is no longer run in
    ;; full on every push. Per push they run only the canonical on/full combo
    ;; plus a single fully-stripped off/none smoke leg; the exhaustive lane
    ;; expands back to the full 2×3 cross.
    (should (string-match-p
             "fromJSON('\\[{\"source_metadata\":\"on\",\"docstring_retention\":\"full\"}"
             workflow))
    (should (string-match-p
             "|| fromJSON('\\[{\"source_metadata\":\"on\",\"docstring_retention\":\"full\"},{\"source_metadata\":\"off\",\"docstring_retention\":\"none\"}\\]')"
             workflow))
    ;; The recompile-bound Gambit native shard runs on/full only per push: its
    ;; combo carries a `native` flag that gates the native step, false on the
    ;; off/none smoke leg.
    (should (string-match-p
             "|| fromJSON('\\[{\"source_metadata\":\"on\",\"docstring_retention\":\"full\",\"native\":true},{\"source_metadata\":\"off\",\"docstring_retention\":\"none\",\"native\":false}\\]')"
             workflow))
    (should (string-match-p
             "if: \\${{ matrix.combo.native }}"
             workflow))))

(ert-deftest consent-ci-test-extra-hosts-base-image-avoids-docker-hub ()
  "Pull the container base image from the rate-limit-free ECR Public mirror."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (should (string-match-p
             "container: public\\.ecr\\.aws/ubuntu/ubuntu:26\\.04"
             workflow))
    ;; The Docker Hub form (registry-1.docker.io) must no longer be requested.
    (should-not (string-match-p "container: ubuntu:26\\.04" workflow))))

(ert-deftest consent-ci-test-make-test-trims-default-and-keeps-full ()
  "Trim the default make test shard set with a make test-full escape hatch."
  (let ((makefile (consent-ci-test--repo-file-string "Makefile")))
    ;; Trimmed default keeps the full Emacs shard set plus one portable host.
    (should (string-match-p
             "CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS \\?=.*test-portable-racket"
             makefile))
    (should (string-match-p
             "CONSENT_TEST_SHARD_TARGETS \\?=.*CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS"
             makefile))
    ;; Default no longer fans out across every portable host.
    (should-not (string-match-p
                 "CONSENT_TEST_SHARD_TARGETS \\?=.*CONSENT_PORTABLE_TEST_SHARD_TARGETS"
                 makefile))
    ;; Exhaustive opt-in set and target remain available.
    (should (string-match-p
             "CONSENT_FULL_TEST_SHARD_TARGETS \\?=.*CONSENT_PORTABLE_TEST_SHARD_TARGETS"
             makefile))
    (should (string-match-p "^test-full:" makefile))))

(ert-deftest consent-ci-test-pr-summary-uses-stable-shard-order ()
  "Render pull request timing rows in the intended shard display order."
  (let* ((tools-shard '(:name "Emacs tools/docs/integration"
                              :selector "tools"
                              :ran 1
                              :expected 1
                              :unexpected 0
                              :skipped 0
                              :ert-seconds 1.0
                              :wall-seconds 1.0
                              :tests nil))
         (portable-rest-shard '(:name "Portable R7RS Chibi non-evaluator subset"
                                      :selector "portable-rest"
                                      :ran 1
                                      :expected 1
                                      :unexpected 0
                                      :skipped 0
                                      :ert-seconds 1.0
                                      :wall-seconds 1.0
                                      :tests nil))
         (portable-gambit-shard '(:name "Portable R7RS Gambit full suite"
                                        :selector "portable-gambit"
                                        :ran 1
                                        :expected 1
                                        :unexpected 0
                                        :skipped 0
                                        :ert-seconds 1.0
                                        :wall-seconds 1.0
                                        :tests nil))
         (portable-gambit-native-shard
          '(:name "Portable R7RS Gambit native Consent Scheme full suite"
            :selector "portable-gambit-native"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-racket-shard '(:name "Portable R7RS Racket full suite"
                                        :selector "portable-racket"
                                        :ran 1
                                        :expected 1
                                        :unexpected 0
                                        :skipped 0
                                        :ert-seconds 1.0
                                        :wall-seconds 1.0
                                        :tests nil))
         (portable-compiled-shard '(:name "Portable R7RS Compiled Consent Scheme full suite"
                                          :selector "portable-compiled"
                                          :ran 1
                                          :expected 1
                                          :unexpected 0
                                          :skipped 0
                                          :ert-seconds 1.0
                                          :wall-seconds 1.0
                                          :tests nil))
         (portable-guile-shard '(:name "Portable R7RS Guile full suite"
                                       :selector "portable-guile"
                                       :ran 1
                                       :expected 1
                                       :unexpected 0
                                       :skipped 0
                                       :ert-seconds 1.0
                                       :wall-seconds 1.0
                                       :tests nil))
         (portable-gauche-shard '(:name "Portable R7RS Gauche full suite"
                                        :selector "portable-gauche"
                                        :ran 1
                                        :expected 1
                                        :unexpected 0
                                        :skipped 0
                                        :ert-seconds 1.0
                                        :wall-seconds 1.0
                                        :tests nil))
         (portable-eval-shard '(:name "Portable R7RS Chibi evaluator subset"
                                      :selector "portable-eval"
                                      :ran 1
                                      :expected 1
                                      :unexpected 0
                                      :skipped 0
                                      :ert-seconds 1.0
                                      :wall-seconds 1.0
                                      :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list tools-shard
                 portable-gauche-shard
                 portable-guile-shard
                 portable-compiled-shard
                 portable-racket-shard
                 portable-gambit-native-shard
                 portable-gambit-shard
                 portable-rest-shard
                 portable-eval-shard))))
    (should
     (string-match-p
      "| Portable R7RS Chibi evaluator subset |.*\n| Portable R7RS Chibi non-evaluator subset |.*\n| Portable R7RS Gambit full suite |.*\n| Portable R7RS Gambit native Consent Scheme full suite |.*\n| Portable R7RS Racket full suite |.*\n| Portable R7RS Compiled Consent Scheme full suite |.*\n| Portable R7RS Guile full suite |.*\n| Portable R7RS Gauche full suite |.*\n| Emacs tools/docs/integration |"
      markdown))))

;;; Structured per-run record (#465)

(defmacro consent-ci-test--with-env (bindings &rest body)
  "Evaluate BODY with BINDINGS applied to a private `process-environment'.
BINDINGS is a list of (NAME . VALUE) pairs; a nil VALUE unsets NAME so the
emitter sees it as absent."
  (declare (indent 1))
  `(let ((process-environment (copy-sequence process-environment)))
     (dolist (binding ,bindings)
       (setenv (car binding) (cdr binding)))
     ,@body))

(defun consent-ci-test--sample-record-logs ()
  "Return two sample shard log paths: one passing portable, one failing Emacs."
  (list
   (consent-ci-test--write-log
    (concat
     "Running 1 tests (2026-06-06 13:00:00-0700, selector `y')\n"
     "   passed  1/1  consent-scheme-fixture-test-r7rs-suite (0.080000 sec)\n"
     "\n"
     "Ran 1 tests, 1 results as expected, 0 unexpected "
     "(2026-06-06 13:00:01-0700, 0.080000 sec)\n"
     "CONSENT_CI_SHARD_NAME=Portable R7RS Gambit full suite / source metadata on / docstrings full\n"
     "CONSENT_CI_SHARD_SELECTOR=\"^consent-scheme-gambit-host-test-r7rs-suite$\"\n"
     "CONSENT_CI_WALL_SECONDS=10\n"))
   (consent-ci-test--write-log
    (concat
     "Running 2 tests (2026-06-06 13:00:00-0700, selector `x')\n"
     "   passed  1/2  consent-reader-test-a (0.040000 sec)\n"
     "   failed  2/2  consent-reader-test-b (0.500000 sec)\n"
     "\n"
     "Ran 2 tests, 1 results as expected, 1 unexpected "
     "(2026-06-06 13:00:01-0700, 0.540000 sec)\n"
     "CONSENT_CI_SHARD_NAME=Emacs core language/runtime / source metadata on / docstrings full\n"
     "CONSENT_CI_SHARD_SELECTOR=(or \"consent-reader.*\")\n"
     "CONSENT_CI_WALL_SECONDS=3\n"))))

(ert-deftest consent-ci-test-run-record-shape ()
  "Build a per-run record with provenance, derived outcomes, and totals."
  (let ((logs (consent-ci-test--sample-record-logs)))
    (unwind-protect
        (consent-ci-test--with-env
            '(("GITHUB_REPOSITORY" . "tahoma/consent")
              ("GITHUB_EVENT_NAME" . "pull_request")
              ("GITHUB_RUN_ID" . "123")
              ("GITHUB_RUN_ATTEMPT" . "2")
              ("CONSENT_CI_RUN_URL" . "https://example/runs/123")
              ("GITHUB_ACTOR" . "tahoma")
              ("RUNNER_OS" . "Linux")
              ("RUNNER_ARCH" . "X64")
              ("CONSENT_CI_PR_NUMBER" . "465")
              ("CONSENT_CI_BASE_REF" . "main")
              ("CONSENT_CI_HEAD_SHA" . "abc123")
              ("CONSENT_CI_BASE_SHA" . "def456")
              ("CONSENT_CI_CHANGED_FILES" . "5")
              ("CONSENT_CI_INSERTIONS" . "200")
              ("CONSENT_CI_DELETIONS" . "10")
              ("CONSENT_CI_VERSION_CHANGED" . "true")
              ("CONSENT_CI_PARITY_RESULT" . "success")
              ("CONSENT_CI_TIMESTAMP" . "2026-06-06T20:00:00Z"))
          (let* ((json (consent-ci-render-run-record
                        (mapcar #'consent-ci-parse-log-file logs)))
                 (record (json-parse-string json :object-type 'alist))
                 (run (alist-get 'run record))
                 (change (alist-get 'change record))
                 (totals (alist-get 'totals record))
                 (shards (alist-get 'shards record)))
            ;; The record is a single line of JSON (JSON Lines).
            (should-not (string-match-p "\n" json))
            (should (= (alist-get 'schema_version record)
                       consent-ci-run-record-schema-version))
            (should (equal (alist-get 'generated_at record)
                           "2026-06-06T20:00:00Z"))
            ;; Provenance comes straight from the environment, typed.
            (should (equal (alist-get 'repository run) "tahoma/consent"))
            (should (= (alist-get 'run_attempt run) 2))
            (should (= (alist-get 'pr_number change) 465))
            (should (= (alist-get 'changed_files change) 5))
            (should (eq (alist-get 'version_changed change) t))
            (should (equal (alist-get 'result (alist-get 'parity record))
                           "success"))
            ;; Totals aggregate the shard counts; all_passed tracks unexpected.
            (should (= (alist-get 'shards totals) 2))
            (should (= (alist-get 'ran totals) 3))
            (should (= (alist-get 'unexpected totals) 1))
            (should (eq (alist-get 'all_passed totals) :false))
            ;; Shards sort into display order: portable Gambit before Emacs core.
            (should (= (length shards) 2))
            (let ((gambit (aref shards 0))
                  (emacs (aref shards 1)))
              (should (equal (alist-get 'name gambit)
                             "Portable R7RS Gambit full suite"))
              (should (equal (alist-get 'source_metadata gambit) "on"))
              (should (equal (alist-get 'docstrings gambit) "full"))
              (should (eq (alist-get 'passed gambit) t))
              (should (equal (alist-get 'name emacs)
                             "Emacs core language/runtime"))
              (should (eq (alist-get 'passed emacs) :false)))))
      (mapc #'delete-file logs))))

(ert-deftest consent-ci-test-run-record-absent-env-is-null ()
  "Unset provenance variables serialize as JSON null, not empty strings."
  (let ((logs (consent-ci-test--sample-record-logs)))
    (unwind-protect
        (consent-ci-test--with-env
            '(("GITHUB_REPOSITORY" . nil)
              ("GITHUB_EVENT_NAME" . nil)
              ("GITHUB_RUN_ID" . nil)
              ("GITHUB_RUN_ATTEMPT" . nil)
              ("CONSENT_CI_RUN_URL" . nil)
              ("GITHUB_ACTOR" . nil)
              ("RUNNER_OS" . nil)
              ("RUNNER_ARCH" . nil)
              ("CONSENT_CI_PR_NUMBER" . nil)
              ("CONSENT_CI_BASE_REF" . nil)
              ("CONSENT_CI_HEAD_SHA" . nil)
              ("CONSENT_CI_BASE_SHA" . nil)
              ("CONSENT_CI_CHANGED_FILES" . nil)
              ("CONSENT_CI_INSERTIONS" . nil)
              ("CONSENT_CI_DELETIONS" . nil)
              ("CONSENT_CI_VERSION_CHANGED" . nil)
              ("CONSENT_CI_PARITY_RESULT" . nil)
              ("CONSENT_CI_TIMESTAMP" . nil))
          (let* ((json (consent-ci-render-run-record
                        (mapcar #'consent-ci-parse-log-file logs)))
                 (record (json-parse-string json :object-type 'alist
                                            :null-object :null))
                 (change (alist-get 'change record)))
            (should (eq (alist-get 'repository (alist-get 'run record)) :null))
            (should (eq (alist-get 'pr_number change) :null))
            (should (eq (alist-get 'version_changed change) :null))
            (should (eq (alist-get 'result (alist-get 'parity record)) :null))
            ;; Shard outcomes are still present even without provenance.
            (should (= (alist-get 'ran (alist-get 'totals record)) 3))))
      (mapc #'delete-file logs))))

(ert-deftest consent-ci-test-run-record-appends-jsonl ()
  "Writing the record twice yields two independent JSON Lines entries."
  (let ((logs (consent-ci-test--sample-record-logs))
        (out (make-temp-file "consent-ci-run-record-" nil ".jsonl")))
    (unwind-protect
        (progn
          (consent-ci-write-run-record logs out)
          (consent-ci-write-run-record logs out)
          (let ((lines (with-temp-buffer
                         (insert-file-contents out)
                         (split-string (buffer-string) "\n" t))))
            (should (= (length lines) 2))
            (dolist (line lines)
              (let ((record (json-parse-string line :object-type 'alist)))
                (should (= (alist-get 'schema_version record)
                           consent-ci-run-record-schema-version))))))
      (mapc #'delete-file logs)
      (delete-file out))))

(ert-deftest consent-ci-test-workflow-emits-and-uploads-run-record ()
  "The summary job emits the per-run record and uploads it as an artifact."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    ;; The emitter runs over the downloaded shard logs in the summary job.
    (should (string-match-p "name: Emit per-run CI record" workflow))
    (should (string-match-p "consent-ci-run-record-batch-main" workflow))
    (should (string-match-p "CONSENT_CI_RUN_RECORD_FILE=ci-logs/run-record.jsonl"
                            workflow))
    ;; The parity gate outcome is threaded in from the job graph.
    (should (string-match-p
             "CONSENT_CI_PARITY_RESULT: \\${{ needs.test-parity.result }}"
             workflow))
    ;; The record lands as a retained artifact (the current durable sink).
    (should (string-match-p "name: Upload per-run CI record" workflow))
    (should (string-match-p "name: ci-run-record" workflow))
    (should (string-match-p "retention-days: 90" workflow))))

(provide 'consent-ci-test)

;;; consent-ci-test.el ends here
