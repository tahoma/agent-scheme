;;; agent-scheme-ci-test.el --- CI reporting tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for Agent Scheme CI shard timing summary helpers.

;;; Code:

(require 'ert)
(require 'agent-scheme-ci)

(defun agent-scheme-ci-test--write-log (contents)
  "Write CONTENTS to a temporary CI log and return its path."
  (let ((path (make-temp-file "agent-scheme-ci-log-" nil ".log")))
    (with-temp-file path
      (insert contents))
    path))

(defun agent-scheme-ci-test--repo-file-string (relative-path)
  "Return RELATIVE-PATH from the repository root as a string."
  (let ((root (if (boundp 'agent-scheme--test-root)
                  agent-scheme--test-root
                default-directory)))
    (with-temp-buffer
      (insert-file-contents (expand-file-name relative-path root))
      (buffer-string))))

(ert-deftest agent-scheme-ci-test-parses-result-counts-and-slowest-tests ()
  "Parse ERT shard output plus CI wall-clock metadata."
  (let* ((log (agent-scheme-ci-test--write-log
               (concat
                "Running 3 tests (2026-05-25 13:00:00-0700, selector `x')\n"
                "   passed  1/3  agent-scheme-reader-test-fast (0.010000 sec)\n"
                "   skipped 2/3  agent-scheme-reader-test-skip (0.020000 sec)\n"
                "   failed  3/3  agent-scheme-reader-test-slow (1.250000 sec)\n"
                "\n"
                "Ran 3 tests, 2 results as expected, 1 unexpected, 1 skipped "
                "(2026-05-25 13:00:02-0700, 1.280000 sec)\n"
                "AGENT_SCHEME_CI_CHECK_SECONDS=source-library-docstring-reflection 6.800\n"
                "AGENT_SCHEME_CI_SHARD_NAME=Emacs-hosted ERT\n"
                "AGENT_SCHEME_CI_SHARD_SELECTOR=(not \"agent-scheme-scheme-.*\")\n"
                "AGENT_SCHEME_CI_WALL_SECONDS=2\n")))
         (shard (agent-scheme-ci-parse-log-file log))
         (slowest (agent-scheme-ci-shard-slowest-tests shard 2))
         (check-timings (plist-get shard :check-timings)))
    (unwind-protect
        (progn
          (should (equal (plist-get shard :name) "Emacs-hosted ERT"))
          (should (equal (plist-get shard :selector)
                         "(not \"agent-scheme-scheme-.*\")"))
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
                         '("agent-scheme-reader-test-slow"
                           "agent-scheme-reader-test-skip"))))
      (delete-file log))))

(ert-deftest agent-scheme-ci-test-renders-summary-with-comparable-surfaces ()
  "Render shard rows and paired Emacs/portable validation surface rows."
  (let* ((emacs-log
          (agent-scheme-ci-test--write-log
           (concat
            "Running 2 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/2  agent-scheme-reader-test-booleans (0.040000 sec)\n"
            "   passed  2/2  agent-scheme-conformance-test-implemented-cases-run (0.500000 sec)\n"
            "\n"
            "Ran 2 tests, 2 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.540000 sec)\n"
            "AGENT_SCHEME_CI_SHARD_NAME=Emacs-hosted ERT\n"
            "AGENT_SCHEME_CI_SHARD_SELECTOR=(not \"agent-scheme-scheme-.*\")\n"
            "AGENT_SCHEME_CI_WALL_SECONDS=1\n")))
         (portable-log
          (agent-scheme-ci-test--write-log
           (concat
            "Running 3 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/3  agent-scheme-scheme-reader-test-r7rs-suite (0.030000 sec)\n"
            "   passed  2/3  agent-scheme-scheme-eval-test-r7rs-suite (0.200000 sec)\n"
            "   passed  3/3  agent-scheme-scheme-fixture-test-r7rs-suite (0.080000 sec)\n"
            "\n"
            "Ran 3 tests, 3 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.310000 sec)\n"
            "AGENT_SCHEME_CI_CHECK_SECONDS=standard-inexact-transcendentals 0.700\n"
            "AGENT_SCHEME_CI_SHARD_NAME=Portable R7RS Chibi evaluator subset\n"
            "AGENT_SCHEME_CI_SHARD_SELECTOR=\"agent-scheme-scheme-.*\"\n"
            "AGENT_SCHEME_CI_WALL_SECONDS=1\n")))
         (markdown
          (agent-scheme-ci-render-markdown-summary
           (mapcar #'agent-scheme-ci-parse-log-file
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

(ert-deftest agent-scheme-ci-test-renders-pr-summary-comment ()
  "Render a compact pull request timing comment with detailed summary content."
  (let* ((log
          (agent-scheme-ci-test--write-log
           (concat
            "Running 1 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/1  agent-scheme-reader-test-booleans (0.040000 sec)\n"
            "\n"
            "Ran 1 tests, 1 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.040000 sec)\n"
            "AGENT_SCHEME_CI_SHARD_NAME=Emacs core language/runtime\n"
            "AGENT_SCHEME_CI_SHARD_SELECTOR=\"agent-scheme-reader.*\"\n"
            "AGENT_SCHEME_CI_WALL_SECONDS=1\n")))
         (markdown
          (agent-scheme-ci-render-pr-markdown-summary
           (list (agent-scheme-ci-parse-log-file log))
           "https://github.example/run/1")))
    (unwind-protect
        (progn
          (should (string-match-p agent-scheme-ci-pr-summary-marker markdown))
          (should (string-match-p
                   "Latest run: \\[GitHub Actions\\](https://github.example/run/1)"
                   markdown))
          (should (string-match-p
                   "| Emacs core language/runtime | 1 | 0 | 0 | 0\\.040s | 1\\.000s |"
                   markdown))
          (should (string-match-p
                   "<summary>Detailed shard timings and diagnostic timings</summary>"
                   markdown))
          (should (string-match-p "`agent-scheme-reader-test-booleans` 0\\.040s"
                                  markdown)))
      (delete-file log))))

(ert-deftest agent-scheme-ci-test-pr-summary-aggregates-chibi-host-timing ()
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
          (agent-scheme-ci-render-pr-markdown-summary
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

(ert-deftest agent-scheme-ci-test-pr-summary-renders-without-chibi-host ()
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
         (portable-compiled-shard '(:name "Portable R7RS Compiled Agent Scheme full suite"
                                          :selector "portable-compiled"
                                          :ran 1
                                          :expected 1
                                          :unexpected 0
                                          :skipped 0
                                          :ert-seconds 10.0
                                          :wall-seconds 11.0
                                          :tests nil))
         (markdown
          (agent-scheme-ci-render-pr-markdown-summary
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
             "| Compiled Agent Scheme | full suite | 0 | 0 | 10\\.000s | 11\\.000s |"
             above-fold))
    (should-not (string-match-p "Chibi is split" above-fold))
    (should-not (string-match-p "| Chibi |" above-fold))))

(ert-deftest agent-scheme-ci-test-pr-summary-renders-option-variant-host-rows ()
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
          (agent-scheme-ci-render-pr-markdown-summary
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

(ert-deftest agent-scheme-ci-test-pr-summary-renders-emacs-option-matrix ()
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
          (agent-scheme-ci-render-pr-markdown-summary
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

(ert-deftest agent-scheme-ci-test-pr-summary-omits-empty-paired-surfaces ()
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
            :tests ((:name "agent-scheme-scheme-gambit-host-test-r7rs-suite"
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
            :tests ((:name "agent-scheme-reader-test-booleans"
                     :seconds 0.040))))
         (markdown
          (agent-scheme-ci-render-pr-markdown-summary
           (list emacs-shard portable-gambit-shard))))
    (should-not (string-match-p "## Paired Validation Surfaces" markdown))
    (should (string-match-p "## Test Shard Timing" markdown))))

(ert-deftest agent-scheme-ci-test-default-ci-omits-chibi-shards ()
  "Keep Chibi as an explicit optional target, not a default CI shard."
  (let ((workflow (agent-scheme-ci-test--repo-file-string
                   ".github/workflows/test.yml"))
        (makefile (agent-scheme-ci-test--repo-file-string "Makefile")))
    (should-not (string-match-p "name: portable R7RS / Chibi" workflow))
    (should-not (string-match-p "[[:space:]]+- test-portable\n" workflow))
    (should-not (string-match-p
                 "AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS \\?=.*test-portable-eval"
                 makefile))
    (should-not (string-match-p
                 "AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS \\?=.*test-portable-rest"
                 makefile))
    (should (string-match-p
             "AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS \\?=.*test-portable-eval"
             makefile))
    (should (string-match-p
             "AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS \\?=.*test-portable-rest"
             makefile))
    (should (string-match-p "^test-portable-chibi:" makefile))))

(ert-deftest agent-scheme-ci-test-workflow-matrixes-host-option-variants ()
  "Deal out CI shards across host, syntax metadata, and docstring retention."
  (let ((workflow (agent-scheme-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (should (string-match-p "source_metadata: \\[\"on\", \"off\"\\]" workflow))
    (should (string-match-p
             "docstring_retention: \\[\"full\", \"simple\", \"none\"\\]"
             workflow))
    (should (string-match-p
             "AGENT_SCHEME_TEST_SOURCE_METADATA: \\${{ matrix.source_metadata }}"
             workflow))
    (should (string-match-p
             "AGENT_SCHEME_TEST_DOCSTRING_RETENTION: \\${{ matrix.docstring_retention }}"
             workflow))
    (should (string-match-p
             "portable-gambit-\\${{ matrix.source_metadata }}-docstrings-\\${{ matrix.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p
             "portable-gambit-native-\\${{ matrix.source_metadata }}-docstrings-\\${{ matrix.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p
             "portable-\\${{ matrix.host.host }}-\\${{ matrix.source_metadata }}-docstrings-\\${{ matrix.docstring_retention }}\\.log"
             workflow))
    (should (string-match-p "host: compiled" workflow))
    (should (string-match-p "make test-portable-gambit-native" workflow))
    (should (string-match-p
             "Portable R7RS Gambit native Agent Scheme full suite"
             workflow))
    (should (string-match-p "make_target: test-portable-compiled" workflow))
    (should (string-match-p
             "Portable R7RS Compiled Agent Scheme full suite"
             workflow))
    (should (string-match-p
             "emacs-\\${{ matrix.shard.shard }}-\\${{ matrix.source_metadata }}-docstrings-\\${{ matrix.docstring_retention }}\\.log"
             workflow))))

(ert-deftest agent-scheme-ci-test-pr-summary-uses-stable-shard-order ()
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
          '(:name "Portable R7RS Gambit native Agent Scheme full suite"
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
         (portable-compiled-shard '(:name "Portable R7RS Compiled Agent Scheme full suite"
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
          (agent-scheme-ci-render-pr-markdown-summary
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
      "| Portable R7RS Chibi evaluator subset |.*\n| Portable R7RS Chibi non-evaluator subset |.*\n| Portable R7RS Gambit full suite |.*\n| Portable R7RS Gambit native Agent Scheme full suite |.*\n| Portable R7RS Racket full suite |.*\n| Portable R7RS Compiled Agent Scheme full suite |.*\n| Portable R7RS Guile full suite |.*\n| Portable R7RS Gauche full suite |.*\n| Emacs tools/docs/integration |"
      markdown))))

(provide 'agent-scheme-ci-test)

;;; agent-scheme-ci-test.el ends here
