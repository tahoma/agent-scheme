;;; consent-ci-test.el -*- lexical-binding: t; -*-
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

(defun consent-ci-test--ordered-substrings-p (strings text)
  "Return non-nil when STRINGS appear in TEXT in order."
  (let ((start 0)
        found)
    (catch 'missing
      (dolist (string strings t)
        (setq found (string-match-p (regexp-quote string) text start))
        (unless found
          (throw 'missing nil))
        (setq start (+ found (length string)))))))

(defun consent-ci-test--make-logical-text (makefile)
  "Return MAKEFILE with physical continuation lines joined."
  (replace-regexp-in-string "\\\\\n[ \t]*" "" makefile))

(defun consent-ci-test--yaml-semantic-text (text)
  "Return TEXT without YAML folding syntax or formatting whitespace."
  (replace-regexp-in-string
   "[[:space:]]+" ""
   (replace-regexp-in-string ":[ \t]*>-?[0-9]*[ \t]*\n" ":" text)))

(defun consent-ci-test--yaml-contains-p (needle workflow)
  "Return non-nil when WORKFLOW semantically contains literal NEEDLE."
  (string-match-p
   (regexp-quote (consent-ci-test--yaml-semantic-text needle))
   (consent-ci-test--yaml-semantic-text workflow)))

(defun consent-ci-test--make-variable-datum (name makefile)
  "Read Scheme/ERT selector datum NAME from MAKEFILE text."
  (let ((regexp (format "^%s \\?= \\(.+\\)$" (regexp-quote name)))
        (logical (consent-ci-test--make-logical-text makefile)))
    (unless (string-match regexp logical)
      (error "Missing Make variable %s" name))
    (read (match-string 1 logical))))

(ert-deftest consent-ci-test-live-model-profile-shards-are-local-only ()
  "Keep quick-start live model profile shards explicit and opt-in."
  (let ((makefile (consent-ci-test--repo-file-string "Makefile")))
    (dolist (target '("test-live-model-small:"
                      "test-live-model-recommended:"
                      "test-live-model-large:"))
      (should (string-match-p (regexp-quote target) makefile)))
    (dolist (cases
             (list
              (concat "CONSENT_LIVE_MODEL_MATRIX_CASES='"
                      "$(CONSENT_LIVE_MODEL_SMALL_SET)'")
              (concat "CONSENT_LIVE_MODEL_MATRIX_CASES='"
                      "$(CONSENT_LIVE_MODEL_RECOMMENDED_SET)'")
              (concat "CONSENT_LIVE_MODEL_MATRIX_CASES='"
                      "$(CONSENT_LIVE_MODEL_LARGE_SET)'")))
      (should (string-match-p (regexp-quote cases) makefile)))))

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
                "CONSENT_CI_CHECK_SECONDS=source-library-docstring-\
reflection 6.800\n"
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

(ert-deftest consent-ci-test-parses-portable-runner-summary ()
  "Parse Scheme-native portable runner counts without an ERT wrapper."
  (let* ((log (consent-ci-test--write-log
               (concat
                "CONSENT_CI_PORTABLE_SUMMARY=50 49 1 2 12\n"
                "CONSENT_CI_PROGRAM_SECONDS=tests/scheme/slow-test.scm 9\n"
                "CONSENT_CI_SHARD_NAME=Portable R7RS\n"
                "CONSENT_CI_WALL_SECONDS=13\n")))
         (shard (consent-ci-parse-log-file log)))
    (unwind-protect
        (progn
          (should (= (plist-get shard :ran) 50))
          (should (= (plist-get shard :expected) 49))
          (should (= (plist-get shard :unexpected) 1))
          (should (= (plist-get shard :skipped) 2))
          (should (= (plist-get shard :ert-seconds) 12.0))
          (should
           (equal (plist-get shard :program-timings)
                  '((:path "tests/scheme/slow-test.scm" :seconds 9)))))
      (delete-file log))))

(ert-deftest consent-ci-test-combines-parallel-portable-runner-summaries ()
  "Combine counts while retaining the longest parallel subset duration."
  (let* ((log (consent-ci-test--write-log
               (concat
                "CONSENT_CI_PORTABLE_SUMMARY=1 1 0 0 64\n"
                "CONSENT_CI_PORTABLE_SUMMARY=50 49 1 2 70\n"
                "CONSENT_CI_SHARD_NAME=Portable R7RS\n"
                "CONSENT_CI_WALL_SECONDS=72\n")))
         (shard (consent-ci-parse-log-file log)))
    (unwind-protect
        (progn
          (should (= (plist-get shard :ran) 51))
          (should (= (plist-get shard :expected) 50))
          (should (= (plist-get shard :unexpected) 1))
          (should (= (plist-get shard :skipped) 2))
          (should (= (plist-get shard :ert-seconds) 70.0)))
      (delete-file log))))

(ert-deftest consent-ci-test-renders-summary-with-comparable-surfaces ()
  "Render shard rows and paired Emacs/portable validation surface rows."
  (let* ((emacs-log
          (consent-ci-test--write-log
           (concat
            "Running 2 tests (2026-05-25 13:00:00-0700, selector `x')\n"
            "   passed  1/2  consent-reader-test-booleans (0.040000 sec)\n"
            "   passed  2/2  consent-conformance-test-implemented-cases-run\
 (0.500000 sec)\n"
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
            "   passed  1/3  consent-scheme-reader-test-r7rs-suite (0.030000\
 sec)\n"
            "   passed  2/3  consent-scheme-eval-test-r7rs-suite (0.200000\
 sec)\n"
            "   passed  3/3  consent-scheme-fixture-test-r7rs-suite\
 (0.080000 sec)\n"
            "\n"
            "Ran 3 tests, 3 results as expected, 0 unexpected "
            "(2026-05-25 13:00:01-0700, 0.310000 sec)\n"
            "CONSENT_CI_CHECK_SECONDS=standard-inexact-transcendentals 0.700\n"
            "CONSENT_CI_PROGRAM_SECONDS=tests/scheme/consent-eval-test.scm 1\n"
            "CONSENT_CI_SHARD_NAME=Portable R7RS Chibi evaluator subset\n"
            "CONSENT_CI_SHARD_SELECTOR=\"consent-scheme-.*\"\n"
            "CONSENT_CI_WALL_SECONDS=1\n")))
         (markdown
          (consent-ci-render-markdown-summary
           (mapcar #'consent-ci-parse-log-file
                   (list portable-log emacs-log)))))
    (unwind-protect
        (progn
          (should (string-match-p "| Portable R7RS Chibi evaluator subset |"
            markdown))
          (should (string-match-p "| Emacs-hosted ERT |" markdown))
          (should (string-match-p "| Reader | 1 / 0\\.040s | 1 / 0\\.030s |"
                                  markdown))
          (should (string-match-p "| Evaluator | 0 / 0\\.000s | 1 / 0\\.200s |"
                                  markdown))
          (should (string-match-p
                   "| Fixture/conformance | 1 / 0\\.500s | 1 / 0\\.080s |"
                   markdown))
          (should (string-match-p "## Slow Portable Checks" markdown))
          (should (string-match-p "## Slow Portable Programs" markdown))
          (should (string-match-p
                   "`tests/scheme/consent-eval-test.scm` | 1\\.000s"
                   markdown))
          (should (string-match-p
                   "| Portable R7RS Chibi evaluator subset |\
 `standard-inexact-transcendentals` | 0\\.700s |"
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
                   "Latest run: \\[GitHub\
 Actions\\](https://github.example/run/1)"
                   markdown))
          (should (string-match-p
                   "| Emacs core language/runtime | 1 | 0 | 0 | 0\\.040s |\
 1\\.000s |"
                   markdown))
          (should (string-match-p
                   "<summary>Detailed shard timings and diagnostic\
 timings</summary>"
                   markdown))
          (should (string-match-p "`consent-reader-test-booleans` 0\\.040s"
                                  markdown)))
      (delete-file log))))

(ert-deftest consent-ci-test-pr-summary-renders-chibi-shard-timing ()
  "Render split Chibi shards by CI shard name above the fold."
  (let* ((portable-eval-shard '(:name "Portable R7RS Chibi evaluator subset"
                                      :selector "portable-eval"
                                      :ran 1
                                      :expected 1
                                      :unexpected 0
                                      :skipped 0
                                      :ert-seconds 94.0
                                      :wall-seconds 95.0
                                      :tests nil))
         (portable-rest-shard '(:name
           "Portable R7RS Chibi non-evaluator subset"
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
    (should (string-match-p
             "| Portable R7RS Chibi evaluator subset | 1 | 0 | 0 | 94\\.000s |\
 95\\.000s |"
             above-fold))
    (should (string-match-p
             "| Portable R7RS Chibi non-evaluator subset | 16 | 0 | 0 |\
 18\\.000s | 18\\.000s |"
             above-fold))
    (should (string-match-p
             "| Portable R7RS Gambit full suite | 1 | 0 | 0 | 14\\.000s |\
 14\\.000s |"
             above-fold))
    (should (string-match-p "## Shard Timing by Wall Time" above-fold))
    (should-not (string-match-p "## Portable Host Shard Timing" above-fold))
    (should-not (string-match-p "## Emacs Shard Timing" above-fold))
    (should-not (string-match-p "full suite (2 CI shards)" above-fold))))

(ert-deftest consent-ci-test-pr-summary-renders-shards-by-wall-time ()
  "Render visible pull request timing rows by wall time across every shard."
  (let* ((gambit-full-shard
          '(:name
            "Portable R7RS Gambit full suite / source metadata on / docstrings\
 full"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 14.0
            :wall-seconds 15.0
            :tests nil))
         (gambit-stripped-shard
          '(:name
            "Portable R7RS Gambit full suite / source metadata off /\
 docstrings none"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 11.0
            :wall-seconds 12.0
            :tests nil))
         (gauche-reflect-stress-shard
          '(:name
            "Portable R7RS Gauche reflection stress / source metadata on /\
 docstrings full"
            :selector "portable-gauche-reflect-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 330.0
            :wall-seconds 331.0
            :tests nil))
         (emacs-reflect-stress-shard
          '(:name
            "Emacs reflection dynamic manifest stress / source metadata on /\
 docstrings full"
            :selector "emacs-reflect-dynamic-manifest-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 230.0
            :wall-seconds 231.0
            :tests nil))
         (emacs-library-shard
          '(:name
            "Emacs library/conformance / source metadata on / docstrings full"
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
           (list gambit-full-shard
                 emacs-reflect-stress-shard
                 gambit-stripped-shard
                 emacs-library-shard
                 gauche-reflect-stress-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (cl-labels
        ((row-index
          (name)
          (let ((index (string-match-p
                        (regexp-quote (format "| %s |" name))
                        above-fold)))
            (unless index
              (ert-fail (format "Missing timing row for %s" name)))
            index)))
      (should (string-match-p "## Shard Timing by Wall Time" above-fold))
      (should-not (string-match-p "## Portable Host Shard Timing" above-fold))
      (should-not (string-match-p "## Emacs Shard Timing" above-fold))
      (let ((gauche-stress
             (row-index
              "Portable R7RS Gauche reflection stress / source metadata on /\
 docstrings full"))
            (emacs-stress
             (row-index
              "Emacs reflection dynamic manifest stress / source metadata on /\
 docstrings full"))
            (emacs-library
             (row-index
              "Emacs library/conformance / source metadata on / docstrings\
 full"))
            (gambit-full
             (row-index
              "Portable R7RS Gambit full suite / source metadata on /\
 docstrings full"))
            (gambit-stripped
             (row-index
              "Portable R7RS Gambit full suite / source metadata off /\
 docstrings none")))
        (should (< gauche-stress emacs-stress))
        (should (< emacs-stress emacs-library))
        (should (< emacs-library gambit-full))
        (should (< gambit-full gambit-stripped))))))

(ert-deftest consent-ci-test-pr-summary-renders-without-chibi-host ()
  "Render portable shard comparison cleanly when Chibi is absent."
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
         (portable-compiled-shard '(:name
           "Portable R7RS Racket-compiled Consent Scheme self-host corpus"
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
    (should (string-match-p "## Shard Timing by Wall Time" above-fold))
    (should (string-match-p
             "| Portable R7RS Gambit full suite | 1 | 0 | 0 | 14\\.000s |\
 14\\.000s |"
             above-fold))
    (should (string-match-p
             "| Portable R7RS Racket full suite | 1 | 0 | 0 | 12\\.000s |\
 13\\.000s |"
             above-fold))
    (should (string-match-p
             "| Portable R7RS Racket-compiled Consent Scheme self-host\
 corpus | 1 | 0 | 0 | 10\\.000s | 11\\.000s |"
             above-fold))
    (should-not (string-match-p "## Portable Host Shard Timing" above-fold))
    (should-not (string-match-p "## Emacs Shard Timing" above-fold))
    (should-not (string-match-p "Chibi is split" above-fold))
    (should-not (string-match-p "Portable R7RS Chibi" above-fold))))

(ert-deftest consent-ci-test-pr-summary-renders-option-variant-shard-rows ()
  "Render option-variant portable shards as individual CI shard rows."
  (let* ((portable-gambit-shard
          '(:name
            "Portable R7RS Gambit full suite / source metadata off /\
 docstrings none"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 11.0
            :wall-seconds 12.0
            :tests nil))
         (portable-racket-shard
          '(:name
            "Portable R7RS Racket full suite / source metadata on / docstrings\
 simple"
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
    (should (string-match-p
             "## Shard Timing by Wall Time"
             above-fold))
    (should (string-match-p
             "| Portable R7RS Gambit full suite / source metadata off /\
 docstrings none | 1 | 0 | 0 | 11\\.000s | 12\\.000s |"
             above-fold))
    (should (string-match-p
             "| Portable R7RS Racket full suite / source metadata on /\
 docstrings simple | 1 | 0 | 0 | 7\\.000s | 8\\.000s |"
             above-fold))
    (should-not (string-match-p "## Portable Host Shard Timing" above-fold))
    (should-not (string-match-p "## Emacs Shard Timing" above-fold))
    (should-not (string-match-p
                 "| Shard | Ran | Skipped | on/full |"
                 above-fold))
    (should-not
     (string-match-p "full suite, source metadata" above-fold))))

(ert-deftest consent-ci-test-pr-summary-renders-emacs-option-variant-rows ()
  "Render Emacs option variants as individual wall-time rows."
  (let* ((core-full-shard
          '(:name
            "Emacs core language/runtime / source metadata on / docstrings\
 full"
            :selector "core"
            :ran 73
            :expected 73
            :unexpected 0
            :skipped 0
            :ert-seconds 52.0
            :wall-seconds 53.0
            :tests nil))
         (core-none-shard
          '(:name
            "Emacs core language/runtime / source metadata off / docstrings\
 none"
            :selector "core"
            :ran 73
            :expected 73
            :unexpected 0
            :skipped 0
            :ert-seconds 49.0
            :wall-seconds 50.0
            :tests nil))
         (library-full-shard
          '(:name
            "Emacs library/conformance / source metadata on / docstrings full"
            :selector "library"
            :ran 94
            :expected 87
            :unexpected 0
            :skipped 7
            :ert-seconds 51.0
            :wall-seconds 52.0
            :tests nil))
         (stdlib-reference-full-shard
          '(:name
            "Emacs stdlib/reference corpus / source metadata on / docstrings\
 full"
            :selector "stdlib-reference"
            :ran 6
            :expected 6
            :unexpected 0
            :skipped 0
            :ert-seconds 108.0
            :wall-seconds 109.0
            :tests nil))
         (stdlib-reference-stress-full-shard
          '(:name
            "Emacs stdlib/reference stress / source metadata on / docstrings\
 full"
            :selector "stdlib-reference-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 80.0
            :wall-seconds 81.0
            :tests nil))
         (agent-control-full-shard
          '(:name "Emacs agent control / source metadata on / docstrings full"
            :selector "agent-control"
            :ran 40
            :expected 40
            :unexpected 0
            :skipped 0
            :ert-seconds 96.0
            :wall-seconds 97.0
            :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list agent-control-full-shard
                 stdlib-reference-stress-full-shard
                 stdlib-reference-full-shard
                 library-full-shard
                 core-none-shard
                 core-full-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (cl-labels
        ((row-index
          (name)
          (let ((index (string-match-p
                        (regexp-quote (format "| %s |" name))
                        above-fold)))
            (unless index
              (ert-fail (format "Missing timing row for %s" name)))
            index)))
      (should (string-match-p "## Shard Timing by Wall Time" above-fold))
      (should-not (string-match-p "## Portable Host Shard Timing" above-fold))
      (should-not (string-match-p "## Emacs Shard Timing" above-fold))
      (should-not (string-match-p
                   "| Shard | Ran | Skipped | on/full |"
                   above-fold))
      (let ((stdlib-reference
             (row-index
              "Emacs stdlib/reference corpus / source metadata on / docstrings\
 full"))
            (agent-control
             (row-index
              "Emacs agent control / source metadata on / docstrings full"))
            (stdlib-reference-stress
             (row-index
              "Emacs stdlib/reference stress / source metadata on / docstrings\
 full"))
            (core-full
             (row-index
              "Emacs core language/runtime / source metadata on / docstrings\
 full"))
            (library
             (row-index
              "Emacs library/conformance / source metadata on / docstrings\
 full"))
            (core-none
             (row-index
              "Emacs core language/runtime / source metadata off /\
 docstrings none")))
        (should (< stdlib-reference agent-control))
        (should (< agent-control stdlib-reference-stress))
        (should (< stdlib-reference-stress core-full))
        (should (< core-full library))
        (should (< library core-none))))))

(ert-deftest consent-ci-test-pr-summary-renders-portable-shards-by-ci-name ()
  "Render portable shard rows by actual CI shard name above the fold."
  (let* ((gambit-full-shard
          '(:name
            "Portable R7RS Gambit full suite / source metadata on / docstrings\
 full"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 14.0
            :wall-seconds 15.0
            :tests nil))
         (gambit-stripped-shard
          '(:name
            "Portable R7RS Gambit full suite / source metadata off /\
 docstrings none"
            :selector "portable-gambit"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 11.0
            :wall-seconds 12.0
            :tests nil))
         (gambit-reflect-stress-shard
          '(:name
            "Portable R7RS Gambit reflection stress / source metadata on /\
 docstrings full"
            :selector "portable-gambit-reflect-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 55.0
            :wall-seconds 56.0
            :tests nil))
         (gauche-reflect-stress-shard
          '(:name
            "Portable R7RS Gauche reflection stress / source metadata on /\
 docstrings full"
            :selector "portable-gauche-reflect-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 330.0
            :wall-seconds 331.0
            :tests nil))
         (emacs-reflect-stress-shard
          '(:name
            "Emacs reflection dynamic manifest stress / source metadata on /\
 docstrings full"
            :selector "emacs-reflect-dynamic-manifest-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 230.0
            :wall-seconds 231.0
            :tests nil))
         (markdown
          (consent-ci-render-pr-markdown-summary
           (list emacs-reflect-stress-shard
                 gauche-reflect-stress-shard
                 gambit-reflect-stress-shard
                 gambit-stripped-shard
                 gambit-full-shard)))
         (above-fold (car (split-string markdown "\n<details>" t))))
    (cl-labels
        ((row-index
          (name)
          (let ((index (string-match-p
                        (regexp-quote (format "| %s |" name))
                        above-fold)))
            (unless index
              (ert-fail (format "Missing timing row for %s" name)))
            index)))
      (should (string-match-p "## Shard Timing by Wall Time" above-fold))
      (should-not (string-match-p "## Portable Host Shard Timing" above-fold))
      (should-not (string-match-p "## Emacs Shard Timing" above-fold))
      (should-not (string-match-p
                   "| Shard | Ran | Skipped | on/full |"
                   above-fold))
      (let ((gauche-stress
             (row-index
              "Portable R7RS Gauche reflection stress / source metadata on /\
 docstrings full"))
            (emacs-stress
             (row-index
              "Emacs reflection dynamic manifest stress / source metadata on /\
 docstrings full"))
            (gambit-stress
             (row-index
              "Portable R7RS Gambit reflection stress / source metadata on /\
 docstrings full"))
            (gambit-full
             (row-index
              "Portable R7RS Gambit full suite / source metadata on /\
 docstrings full"))
            (gambit-stripped
             (row-index
              "Portable R7RS Gambit full suite / source metadata off /\
 docstrings none")))
        (should (< gauche-stress emacs-stress))
        (should (< emacs-stress gambit-stress))
        (should (< gambit-stress gambit-full))
        (should (< gambit-full gambit-stripped))))
    (should-not (string-match-p "| Host | Coverage |" above-fold))
    (should-not (string-match-p "| Gambit | full suite |" above-fold))))

(ert-deftest consent-ci-test-pr-summary-omits-empty-paired-surfaces ()
  "Avoid showing zero portable paired-surface rows for whole-suite hosts."
  (let* ((portable-gambit-shard
          '(:name
            "Portable R7RS Gambit full suite / source metadata on / docstrings\
 full"
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
          '(:name
            "Emacs core language/runtime / source metadata on / docstrings\
 full"
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

(ert-deftest consent-ci-test-default-ci-includes-chibi-host ()
  "Run the portable Chibi host suite in the default CI matrix."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml"))
        (makefile (consent-ci-test--repo-file-string "Makefile")))
    (should (string-match-p
             (concat "- host: chibi\n"
                     "[[:space:]]+host_name: Chibi\n"
                     "[[:space:]]+apt_package: chibi-scheme\n"
                     "[[:space:]]+make_target: test-portable-chibi")
             workflow))
    (should (string-match-p
             "chibi-scheme -m scheme.base -m scheme.write"
             workflow))
    ;; The required CI matrix uses the explicit host target; the trimmed local
    ;; default remains focused on its representative portable host.
    (should-not (string-match-p
                 "CONSENT_PORTABLE_TEST_SHARD_TARGETS\
 \\?=.*test-portable-chibi"
                 makefile))
    (should (string-match-p
             "CONSENT_PORTABLE_HOST=chibi"
             makefile))
    (should (string-match-p "^test-portable-chibi:" makefile))))

(ert-deftest consent-ci-test-portable-shards-bypass-ert ()
  "Run portable host shards through the direct host launcher, not ERT."
  (let ((makefile (consent-ci-test--repo-file-string "Makefile"))
        (launcher
         (consent-ci-test--repo-file-string "tools/run-portable-tests.sh"))
        (plan
         (consent-ci-test--repo-file-string
          "tests/scheme/test-plan.scm")))
    (dolist (host '("gambit" "racket" "guile" "gauche" "chibi"))
      (should
       (string-match-p
        (format "CONSENT_PORTABLE_HOST=%s" host)
        makefile)))
    (should-not (string-match-p "emacs\\|ert" launcher))
    (should (string-match-p "run-test-plan.scm" launcher))
    (should-not
     (file-exists-p
      (expand-file-name "tests/consent-scheme-host.el" consent--test-root)))
    (should (string-match-p "^test-live-model-portable:" makefile))
    (should (string-match-p
             "CONSENT_PORTABLE_GROUP=live-direct"
             makefile))
    (should (string-match-p
             "CONSENT_PORTABLE_GROUP=live-compiled"
             makefile))
    (should-not
     (file-exists-p
      (expand-file-name
       "tests/scheme/full-test-files.txt"
       consent--test-root)))
    (should (string-match-p "testing-runner-test.scm" plan))
    (should (string-match-p "consent-context-test.scm" plan))
    (should (string-match-p
             "(shard (name full) (selector (tag full)))"
             plan))))

(ert-deftest consent-ci-test-gambit-single-program-shards-isolate-gsi ()
  "Run seven one-program Gambit shards beside the failing aggregate suite."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml"))
        (launcher
         (consent-ci-test--repo-file-string "tools/run-portable-tests.sh")))
    (dolist
        (needle
         '("test-portable-gambit-single-program:"
           "CONSENT_PORTABLE_PROGRAM: ${{ matrix.case.program }}"
           "tests/scheme/consent-repl-test.scm"
           "tests/scheme/consent-eval-test.scm"
           "tests/scheme/stdlib-random-bits-test.scm"
           "tests/scheme/stdlib-property-testing-test.scm"
           "tests/scheme/data-avl-tree-test.scm"
           "tests/scheme/consent-transcript-test.scm"
           "tests/scheme/consent-symbol-test.scm"
           "tools/run-portable-tests.sh"
           "- test-portable-gambit-single-program"))
      (should (string-match-p (regexp-quote needle) workflow)))
    (dolist (needle '("CONSENT_PORTABLE_PROGRAM"
                      "single_program"
                      "CONSENT_CI_PORTABLE_SUMMARY=1 1 0 0"))
      (should (string-match-p (regexp-quote needle) launcher)))))

(ert-deftest consent-ci-test-large-programs-use-language-symbol-comparisons ()
  "Keep large programs from rebinding language comparison procedures."
  (dolist (file '("tests/scheme/consent-eval-test.scm"
                  "tests/scheme/consent-repl-test.scm"
                  "tests/scheme/consent-session-test.scm"))
    (let ((source (consent-ci-test--repo-file-string file)))
      (dolist (binding '("(eq? host-eq?)"
                         "(equal? host-equal?)"
                         "(memq host-memq)"
                         "(assq host-assq)"
                         "(define eq? consent-host-symbol-eq?)"
                         "(define equal? consent-host-symbol-equal?)"
                         "(define memq consent-host-symbol-memq)"
                         "(define assq consent-host-symbol-assq)"))
        (should-not
         (string-match-p
          (regexp-quote binding)
          source))))))

(ert-deftest consent-ci-test-interpreter-preserves-native-table-operations ()
  "Keep mixed symbol adapters explicit at interpreter data boundaries."
  (let ((source
         (consent-ci-test--repo-file-string
          "scheme/consent/interpreter.sld")))
    (dolist (binding '("(rename (scheme base)"
                       "(define memq consent-host-symbol-memq)"
                       "(define assq consent-host-symbol-assq)"))
      (should-not
       (string-match-p
        (regexp-quote binding)
        source)))
    (dolist (binding '("(import (scheme base)"
                       "(define host-memq memq)"
                       "(define host-assq assq)"))
      (should
       (string-match-p
        (regexp-quote binding)
        source)))))

(ert-deftest consent-ci-test-workflow-matrixes-host-option-variants ()
  "Deal out CI shards across host, syntax metadata, and docstring retention."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    ;; The trimmed extra-host / emacs-hosted / parity jobs still read their
    ;; syntax and docstring axes straight off the matrix context.
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_TEST_SOURCE_METADATA: ${{ matrix.source_metadata }}"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_TEST_DOCSTRING_RETENTION: ${{\
 matrix.docstring_retention }}"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_TEST_MAX_SOURCE_METADATA: ${{ matrix.source_metadata\
 == 'on' && '250000' || '' }}"
             workflow))
    ;; The canonical Gambit, compiled-build, and Emacs-core jobs carry a
    ;; per-combo metadata object instead of two literal axes (#481), so their
    ;; environment and artifact names index through `matrix.combo`.
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_TEST_SOURCE_METADATA: ${{ matrix.combo.source_metadata\
 }}"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_TEST_DOCSTRING_RETENTION: ${{\
 matrix.combo.docstring_retention }}"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_TEST_MAX_SOURCE_METADATA: ${{\
 matrix.combo.source_metadata == 'on' && '250000' || '' }}"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_CI_LOG_PREFIX: portable-gambit-direct"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "CONSENT_CI_LOG_SUFFIX: ${{ matrix.combo.source_metadata\
 }}-docstrings-${{ matrix.combo.docstring_retention }}"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "portable-${{ matrix.host.host }}-${{\
 matrix.source_metadata }}-docstrings-${{ matrix.docstring_retention }}"
             workflow))
    (should (string-match-p "host: compiled" workflow))
    (should (string-match-p "Compile Gambit self-host" workflow))
    (should (string-match-p
             "needs: build-gambit-self-host"
             workflow))
    (should (string-match-p "Compile Racket self-host" workflow))
    (should (string-match-p
             "needs: build-racket-self-host"
             workflow))
    ;; Emacs-core indexes its log through the combo too; the other Emacs shards
    ;; keep the bare matrix axes.
    (should (consent-ci-test--yaml-contains-p
             "emacs-${{ matrix.shard.shard }}-${{\
 matrix.combo.source_metadata }}-docstrings-${{\
 matrix.combo.docstring_retention }}.log"
             workflow))
    (should (consent-ci-test--yaml-contains-p
             "emacs-${{ matrix.shard.shard }}-${{ matrix.source_metadata\
 }}-docstrings-${{ matrix.docstring_retention }}.log"
             workflow))))

(ert-deftest consent-ci-test-workflow-splits-capabilities-policy-shard ()
  "Split the heavyweight Emacs capabilities/policy CI surface into shards."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (dolist (needle '("shard: emacs-agent-control"
                      "label: agent control"
                      "make_target: test-emacs-agent-control"
                      "summary_name: Emacs agent control"
                      "selector: (or \"consent-agent-prompt.*\""
                      "shard: emacs-agent-reliability"
                      "label: agent reliability"
                      "make_target: test-emacs-agent-reliability"
                      "summary_name: Emacs agent reliability"
                      "selector: (or \"consent-agent-reliability.*\"\
 \"consent-agent-runner.*\")"
                      "shard: emacs-capability-boundary"
                      "label: capability boundary"
                      "make_target: test-emacs-capability-boundary"
                      "summary_name: Emacs capability boundary"
                      "selector: (or \"consent-approval.*\"\
 \"consent-capability.*\""
                      "shard: emacs-agent-state"
                      "label: agent state"
                      "make_target: test-emacs-agent-state"
                      "summary_name: Emacs agent state"
                      "selector: (or \"consent-agent-io.*\"\
 \"consent-context.*\""))
      (should (consent-ci-test--yaml-contains-p needle workflow)))
    (should-not (string-match-p "make_target: test-emacs-capabilities"
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
    (should (consent-ci-test--yaml-contains-p
             "(github.event_name == 'schedule' || github.event_name ==\
 'workflow_dispatch') && fromJSON"
             workflow))
    ;; Per-push lane falls back to the canonical on/full combo.
    (should (consent-ci-test--yaml-contains-p
             "|| fromJSON('[\"on\"]')" workflow))
    (should (consent-ci-test--yaml-contains-p
             "|| fromJSON('[\"full\"]')" workflow))
    ;; One portable host (Gambit) and one Emacs shard (core) keep the full
    ;; syntax/docstring cross on the exhaustive lane in their own jobs.
    (should (string-match-p "^  test-portable-gambit:" workflow))
    (should (string-match-p "^  test-emacs-core:" workflow))
    ;; The trimmed jobs must not use job-level matrix predicates for the axis;
    ;; the trim belongs in the matrix expression itself.
    (should-not (string-match-p "if: \\${{ matrix.source_metadata" workflow))
    ;; #481: the de-feature cross on Gambit and Emacs-core is no longer run in
    ;; full on every push. Per push they run only the canonical on/full combo
    ;; plus a single fully-stripped off/none smoke leg; the exhaustive lane
    ;; expands back to the full 2×3 cross.
    (should (consent-ci-test--yaml-contains-p
             (concat "fromJSON('[{\"source_metadata\":\"on\","
                     "\"docstring_retention\":\"full\"}")
             workflow))
    (should (consent-ci-test--yaml-contains-p
             (concat
              "|| fromJSON('[{\"source_metadata\":\"on\","
              "\"docstring_retention\":\"full\"},{\"source_metadata\":"
              "\"off\",\"docstring_retention\":\"none\"}]')")
             workflow))
    ;; Compiled build jobs produce only the canonical on/full artifact per
    ;; push;
    ;; the exhaustive lane expands those build matrices before their consumers.
    (should (consent-ci-test--yaml-contains-p
             (concat "|| fromJSON('[{\"source_metadata\":\"on\","
                     "\"docstring_retention\":\"full\"}]')")
             workflow))
    ;; Exhaustive owned Unicode semantics run once on an independent host in
    ;; scheduled and manually dispatched full-metadata CI, never per push.
    (dolist (needle
             '("name: Verify exhaustive Unicode semantics"
               "CONSENT_UNICODE_SEMANTIC_HOST: gambit"
               "make check-unicode-semantics"
               "(github.event_name == 'schedule' || github.event_name ==\
 'workflow_dispatch') && matrix.combo.source_metadata == 'on' &&\
 matrix.combo.docstring_retention == 'full'"))
      (should (consent-ci-test--yaml-contains-p needle workflow)))))

(ert-deftest consent-ci-test-compiled-caches-exclude-product-binaries ()
  "Keep fallback compiled caches from restoring runnable product binaries."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (dolist (needle
             '("build/compile/gambit/src"
               "build/compile/gambit/incremental"
               "build/compile/racket/src"
               "build/compile/racket/collections"
               "gambit-build-v2-"
               "racket-build-v2-"))
      (should (string-match-p (regexp-quote needle) workflow)))
    (dolist (forbidden
             '("path: build/compile/gambit\n"
               "path: build/compile/racket\n"
               "gambit-build-v1-"
               "racket-build-v1-"))
      (should-not (string-match-p (regexp-quote forbidden) workflow)))))

(ert-deftest consent-ci-test-gauche-hosts-container-avoids-docker-hub ()
  "Pull the Gauche container base image from ECR Public, not Docker Hub."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (should (string-match-p
             "test-portable-gauche-hosts:"
             workflow))
    (should (string-match-p
             "max-parallel: 1"
             workflow))
    (should (string-match-p
             "test-portable-gauche-shards:"
             workflow))
    (should (string-match-p
             "max-parallel: 4"
             workflow))
    (should (string-match-p
             "container: public\\.ecr\\.aws/ubuntu/ubuntu:26\\.04"
             workflow))
    (should (string-match-p
             "test-portable-gauche-hosts"
             workflow))
    ;; The Docker Hub form (registry-1.docker.io) must no longer be requested.
    (should-not (string-match-p "container: ubuntu:26\\.04" workflow))))

(ert-deftest consent-ci-test-portable-outliers-use-first-class-plan-shards ()
  "Run long portable hosts as independently scheduled semantic plan shards."
  (let ((makefile (consent-ci-test--repo-file-string "Makefile"))
        (workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (dolist (needle '("test-portable-shard:"
                      "CONSENT_PORTABLE_HOST is required"
                      "CONSENT_PORTABLE_GROUP is required"))
      (should (string-match-p (regexp-quote needle) makefile)))
    (dolist (needle '("test-portable-gambit-self-host:"
                      "test-portable-racket-self-host:"
                      "test-portable-guile-shards:"
                      "test-portable-gauche-shards:"
                      "\"group\":\"compiled-random\""
                      "\"group\":\"compiled-property\""
                      "\"group\":\"compiled-library\""
                      "\"group\":\"compiled-runtime\""
                      "\"group\":\"compiled-agent\""
                      "\"group\":\"compiled-integration\""
                      "\"group\":\"integration\""
                      "\"group\":\"evaluator\""
                      "\"group\":\"random\""
                      "\"group\":\"property\""
                      "\"group\":\"library\""
                      "\"group\":\"agent\""
                      "\"group\":\"runtime\""
                      "\"aggregate\":true"
                      "Run exhaustive Gambit-compiled shard set"
                      "Run exhaustive Racket-compiled shard set"
                      "Run exhaustive Guile shard set"
                      "Run exhaustive Gauche shard set"
                      "make test-portable-shard"))
      (should (consent-ci-test--yaml-contains-p needle workflow)))
    ;; Scheduled-only jobs with job-level guards are rendered as abstract
    ;; skipped checks on pull requests because GitHub does not expand their
    ;; matrixes.  Keep exhaustive cases inside the concrete host matrixes.
    (dolist (job '("test-portable-compiled-cross"
                   "test-portable-guile-cross"
                   "test-portable-gauche-cross"))
      (should-not
       (string-match-p (format "^  %s:" (regexp-quote job)) workflow)))))

(ert-deftest consent-ci-test-make-test-trims-default-and-keeps-full ()
  "Trim the default make test shard set with a make test-full escape hatch."
  (let ((makefile
         (consent-ci-test--make-logical-text
          (consent-ci-test--repo-file-string "Makefile"))))
    ;; Trimmed default keeps the full Emacs shard set plus one portable host.
    (should (string-match-p
             "CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS\
 \\?=.*test-portable-racket"
             makefile))
    (should (string-match-p
             "CONSENT_TEST_SHARD_TARGETS\
 \\?=.*CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS"
             makefile))
    ;; Default no longer fans out across every portable host.
    (should-not (string-match-p
                 "CONSENT_TEST_SHARD_TARGETS\
 \\?=.*CONSENT_PORTABLE_TEST_SHARD_TARGETS"
                 makefile))
    (should-not (string-match-p
                 "CONSENT_TEST_SHARD_TARGETS\
 \\?=.*check-unicode-semantics"
                 makefile))
    ;; Exhaustive opt-in set and target remain available.
    (should (string-match-p
             "CONSENT_FULL_TEST_SHARD_TARGETS\
 \\?=.*CONSENT_PORTABLE_TEST_SHARD_TARGETS"
             makefile))
    (should (string-match-p
             "CONSENT_FULL_TEST_SHARD_TARGETS\
 \\?=.*check-unicode-semantics"
             makefile))
    (should (string-match-p "^test-full:" makefile))))

(ert-deftest consent-ci-test-emacs-shards-start-longest-first ()
  "Order Emacs shard starts by expected wall time."
  (let* ((makefile
          (consent-ci-test--make-logical-text
           (consent-ci-test--repo-file-string "Makefile")))
         (workflow (consent-ci-test--repo-file-string
                    ".github/workflows/test.yml"))
         (make-targets
          '("test-emacs-library-memory-refinement-performance"
            "test-emacs-reflect-documentation-stress"
            "test-emacs-agent-state"
            "test-emacs-integration"
            "test-emacs-library-memory-query-performance"
            "test-emacs-agent-reliability"
            "test-emacs-agent-control"
            "test-emacs-reflect"
            "test-emacs-core"
            "test-emacs-library-runtime"
            "test-emacs-tools"
            "test-emacs-library-stdlib-manifest"
            "test-emacs-library-stdlib-core"
            "test-emacs-capability-boundary"
            "test-emacs-conformance"
            "test-emacs-library-stdlib-property"
            "test-emacs-reflect-dynamic-manifest-stress"
            "test-emacs-reflect-catalog-stress"
            "test-emacs-reflect-binding-crosswalk-stress"))
         (workflow-shards
          '("shard: emacs-library-memory-refinement-performance"
            "shard: emacs-reflect-documentation-stress"
            "shard: emacs-agent-state"
            "shard: emacs-integration"
            "shard: emacs-library-memory-query-performance"
            "shard: emacs-agent-reliability"
            "shard: emacs-agent-control"
            "shard: emacs-reflect"
            "shard: emacs-library-runtime"
            "shard: emacs-tools"
            "shard: emacs-library-stdlib-manifest"
            "shard: emacs-library-stdlib-core"
            "shard: emacs-capability-boundary"
            "shard: emacs-conformance"
            "shard: emacs-library-stdlib-property"
            "shard: emacs-reflect-dynamic-manifest-stress"
            "shard: emacs-reflect-catalog-stress"
            "shard: emacs-reflect-binding-crosswalk-stress"
            "shard: emacs-native-build")))
    (should
     (string-match-p
      (regexp-quote
      (concat "CONSENT_EMACS_TEST_SHARD_TARGETS ?= "
               (mapconcat #'identity make-targets " ")))
      makefile))
    (should (consent-ci-test--ordered-substrings-p
             workflow-shards workflow))))

(ert-deftest consent-ci-test-emacs-library-shards-exactly-partition-aggregate
  ()
  "Keep seven disjoint library shards coverage-equivalent to the aggregate."
  (let* ((makefile (consent-ci-test--repo-file-string "Makefile"))
         (aggregate-selector
          (consent-ci-test--make-variable-datum
           "CONSENT_EMACS_LIBRARY_TEST_SELECTOR" makefile))
         (partition-selectors
          (mapcar
           (lambda (name)
             (consent-ci-test--make-variable-datum name makefile))
           '("CONSENT_EMACS_CONFORMANCE_TEST_SELECTOR"
             "CONSENT_EMACS_LIBRARY_RUNTIME_TEST_SELECTOR"
             "CONSENT_EMACS_LIBRARY_MEMORY_QUERY_PERFORMANCE_TEST_SELECTOR"
             "CONSENT_EMACS_LIBRARY_MEMORY_REFINEMENT_PERFORMANCE_TEST_SELECTOR"
             "CONSENT_EMACS_LIBRARY_STDLIB_CORE_TEST_SELECTOR"
             "CONSENT_EMACS_LIBRARY_STDLIB_PROPERTY_TEST_SELECTOR"
             "CONSENT_EMACS_LIBRARY_STDLIB_MANIFEST_TEST_SELECTOR")))
         (aggregate
          (mapcar #'ert-test-name (ert-select-tests aggregate-selector t)))
         (parts
          (mapcar
           (lambda (selector)
             (mapcar #'ert-test-name (ert-select-tests selector t)))
           partition-selectors))
         (flattened (apply #'append parts)))
    (should (= (length aggregate) 236))
    (should (= (length flattened)
               (length (delete-dups (copy-sequence flattened)))))
    (should (equal (sort aggregate #'string-lessp)
                   (sort flattened #'string-lessp)))))

(ert-deftest consent-ci-test-make-splits-capability-default-shards ()
  "Run capability and agent tests as parallel default Emacs shards."
  (let ((makefile (consent-ci-test--repo-file-string "Makefile")))
    (should-not (string-match-p
                 "CONSENT_EMACS_TEST_SHARD_TARGETS\
 \\?=.*test-emacs-capabilities"
                 makefile))
    (dolist (needle '("CONSENT_EMACS_AGENT_CONTROL_TEST_SELECTOR ?="
                      "CONSENT_EMACS_AGENT_RELIABILITY_TEST_SELECTOR ?="
                      "CONSENT_EMACS_CAPABILITY_BOUNDARY_TEST_SELECTOR ?="
                      "CONSENT_EMACS_AGENT_STATE_TEST_SELECTOR ?="
                      "^test-emacs-agent-control:"
                      "^test-emacs-agent-reliability:"
                      "^test-emacs-capability-boundary:"
                      "^test-emacs-agent-state:"))
      (should (string-match-p needle makefile)))))

(ert-deftest consent-ci-test-runs-srfi-180-only-through-portable-plans ()
  "Keep the complete JSON reference corpus out of ERT shards."
  (let ((makefile (consent-ci-test--repo-file-string "Makefile"))
        (workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml"))
        (plan (consent-ci-test--repo-file-string
               "tests/scheme/test-plan.scm")))
    (should-not (string-match-p "emacs-stdlib-reference" makefile))
    (should-not (string-match-p "emacs-stdlib-reference" workflow))
    (should (string-match-p "stdlib-json-reference-test.scm" plan))
    (should (string-match-p
             "(tags (full direct compiled stdlib reference stress slow))"
             plan))))

(ert-deftest consent-ci-test-prioritizes-compiled-self-host-builds ()
  "Build product self-hosts before their test consumers."
  (let ((workflow (consent-ci-test--repo-file-string
                   ".github/workflows/test.yml")))
    (dolist (needle '("build-gambit-self-host:"
                      "needs: build-gambit-self-host"
                      "name: gambit-self-host-${{ matrix.combo.source_metadata\
 }}"
                      "build-racket-self-host:"
                      "needs: build-racket-self-host"
                      "name: racket-self-host-${{ matrix.combo.source_metadata\
 }}"))
      (should (consent-ci-test--yaml-contains-p needle workflow)))
    (should (consent-ci-test--ordered-substrings-p
             '("Compile Gambit self-host" "Upload Gambit self-host")
             workflow))
    (should (consent-ci-test--ordered-substrings-p
             '("Compile Racket self-host" "Upload Racket self-host")
             workflow))))

(ert-deftest consent-ci-test-make-splits-reflection-behavior-shards ()
  "Run reflection contract and stress coverage as behavior-focused shards."
  (let ((makefile
         (consent-ci-test--make-logical-text
          (consent-ci-test--repo-file-string "Makefile"))))
    (should (string-match-p
             "CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS\
 \\?=.*test-portable-racket-reflect.*test-portable-racket-reflect-stress"
             makefile))
    (should (string-match-p
             (concat
              "CONSENT_PORTABLE_TEST_SHARD_TARGETS \\?="
              ".*test-portable-gambit-reflect"
              ".*test-portable-gambit-reflect-stress"
              ".*test-portable-racket-reflect"
              ".*test-portable-racket-reflect-stress"
              ".*test-portable-guile-reflect"
              ".*test-portable-guile-reflect-stress"
              ".*test-portable-gauche-reflect"
              ".*test-portable-gauche-reflect-stress")
             makefile))
    (dolist (needle
      (list "CONSENT_EMACS_REFLECT_TEST_SELECTOR \\?=.*consent-reflect"
                      "CONSENT_EMACS_REFLECT_CATALOG_STRESS_TEST_SELECTOR \\?="
                      (concat "CONSENT_EMACS_REFLECT_DOCUMENTATION_STRESS_"
                              "TEST_SELECTOR \\?=")
                      (concat "CONSENT_EMACS_REFLECT_BINDING_CROSSWALK_STRESS_"
                              "TEST_SELECTOR \\?=")
                      (concat "CONSENT_EMACS_REFLECT_DYNAMIC_MANIFEST_STRESS_"
                              "TEST_SELECTOR \\?=")
                      "CONSENT_EMACS_REFLECT_STRESS_TEST_SELECTOR \\?=.*stress"
                      "CONSENT_EMACS_INTEGRATION_TEST_SELECTOR\
 \\?=.*consent-native-cli-daemon.*consent-repl.*consent-vcs"
                      "^test-emacs-reflect:"
                      "^test-emacs-reflect-catalog-stress:"
                      "^test-emacs-reflect-documentation-stress:"
                      "^test-emacs-reflect-binding-crosswalk-stress:"
                      "^test-emacs-reflect-dynamic-manifest-stress:"
                      "^test-emacs-reflect-stress:"
                      "^test-portable-gambit-reflect:"
                      "^test-portable-gambit-reflect-stress:"
                      "^test-portable-racket-reflect:"
                      "^test-portable-racket-reflect-stress:"
                      "^test-portable-guile-reflect:"
                      "^test-portable-guile-reflect-stress:"
                      "^test-portable-gauche-reflect:"
                      "^test-portable-gauche-reflect-stress:"))
      (should (string-match-p needle makefile)))
    (should-not (string-match-p
                 "CONSENT_EMACS_INTEGRATION_TEST_SELECTOR\
 \\?=.*consent-reflect"
                 makefile))))

(ert-deftest consent-ci-test-workflow-splits-reflection-behavior-shards ()
  "Expose reflection contract and stress shards in the CI matrix."
  (let ((workflow (consent-ci-test--repo-file-string
    ".github/workflows/test.yml")))
    (dolist (needle '("shard: emacs-reflect"
                      "shard: emacs-reflect-catalog-stress"
                      "shard: emacs-reflect-documentation-stress"
                      "shard: emacs-reflect-binding-crosswalk-stress"
                      "shard: emacs-reflect-dynamic-manifest-stress"
                      "summary_name: Emacs reflection contract"
                      "summary_name: Emacs reflection catalog stress"
                      "summary_name: Emacs reflection documentation stress"
                      "summary_name: Emacs reflection binding crosswalk stress"
                      "summary_name: Emacs reflection dynamic manifest stress"
                      "CONSENT_CI_REFLECT_SHARD_SUMMARY_NAME: Portable R7RS\
 Gambit reflection contract"
                      "CONSENT_CI_REFLECT_STRESS_SHARD_SUMMARY_NAME:\
 Portable R7RS Gambit reflection stress"
                      "host: racket-reflect"
                      "host: racket-reflect-stress"
                      "host: guile-reflect"
                      "host: guile-reflect-stress"
                      "host: gauche-reflect"
                      "host: gauche-reflect-stress"
                      "summary_name: Portable R7RS Racket reflection contract"
                      "summary_name: Portable R7RS Racket reflection stress"
                      "summary_name: Portable R7RS Guile reflection contract"
                      "summary_name: Portable R7RS Guile reflection stress"
                      "summary_name: Portable R7RS Gauche reflection contract"
                      "summary_name: Portable R7RS Gauche reflection stress"))
      (should (consent-ci-test--yaml-contains-p needle workflow)))
    (should-not (string-match-p
                 "summary_name: Emacs\
 integration/REPL[^\n]*\n[^\n]*selector: '(or\
 \"consent-native-cli-daemon\\.\\*\" \"consent-reflect"
                 workflow))))

(ert-deftest consent-ci-test-pr-summary-uses-stable-shard-order ()
  "Render pull request timing rows in the intended shard display order."
  (let* ((agent-control-shard '(:name "Emacs agent control"
                                      :selector "agent-control"
                                      :ran 1
                                      :expected 1
                                      :unexpected 0
                                      :skipped 0
                                      :ert-seconds 1.0
                                      :wall-seconds 1.0
                                      :tests nil))
         (agent-reliability-shard '(:name "Emacs agent reliability"
                                          :selector "agent-reliability"
                                          :ran 1
                                          :expected 1
                                          :unexpected 0
                                          :skipped 0
                                          :ert-seconds 1.0
                                          :wall-seconds 1.0
                                          :tests nil))
         (capability-boundary-shard '(:name "Emacs capability boundary"
                                            :selector "capability-boundary"
                                            :ran 1
                                            :expected 1
                                            :unexpected 0
                                            :skipped 0
                                            :ert-seconds 1.0
                                            :wall-seconds 1.0
                                            :tests nil))
         (agent-state-shard '(:name "Emacs agent state"
                                    :selector "agent-state"
                                    :ran 1
                                    :expected 1
                                    :unexpected 0
                                    :skipped 0
                                    :ert-seconds 1.0
                                    :wall-seconds 1.0
                                    :tests nil))
         (tools-shard '(:name "Emacs tools/docs/integration"
                              :selector "tools"
                              :ran 1
                              :expected 1
                              :unexpected 0
                              :skipped 0
                              :ert-seconds 1.0
                              :wall-seconds 1.0
                              :tests nil))
         (portable-rest-shard '(:name
           "Portable R7RS Chibi non-evaluator subset"
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
         (portable-gambit-reflect-shard
          '(:name "Portable R7RS Gambit reflection contract"
            :selector "portable-gambit-reflect"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-gambit-reflect-stress-shard
          '(:name "Portable R7RS Gambit reflection stress"
            :selector "portable-gambit-reflect-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-gambit-native-shard
          '(:name
            "Portable R7RS Gambit-compiled Consent Scheme self-host corpus"
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
         (portable-racket-reflect-shard
          '(:name "Portable R7RS Racket reflection contract"
            :selector "portable-racket-reflect"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-racket-reflect-stress-shard
          '(:name "Portable R7RS Racket reflection stress"
            :selector "portable-racket-reflect-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-compiled-shard '(:name
           "Portable R7RS Racket-compiled Consent Scheme self-host corpus"
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
         (portable-guile-reflect-shard
          '(:name "Portable R7RS Guile reflection contract"
            :selector "portable-guile-reflect"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-guile-reflect-stress-shard
          '(:name "Portable R7RS Guile reflection stress"
            :selector "portable-guile-reflect-stress"
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
         (portable-gauche-reflect-shard
          '(:name "Portable R7RS Gauche reflection contract"
            :selector "portable-gauche-reflect"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (portable-gauche-reflect-stress-shard
          '(:name "Portable R7RS Gauche reflection stress"
            :selector "portable-gauche-reflect-stress"
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
         (reflect-contract-shard '(:name "Emacs reflection contract"
                                         :selector "reflect"
                                         :ran 1
                                         :expected 1
                                         :unexpected 0
                                         :skipped 0
                                         :ert-seconds 1.0
                                         :wall-seconds 1.0
                                         :tests nil))
         (reflect-catalog-stress-shard
          '(:name "Emacs reflection catalog stress"
            :selector "reflect-catalog-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (reflect-documentation-stress-shard
          '(:name "Emacs reflection documentation stress"
            :selector "reflect-documentation-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (reflect-binding-crosswalk-stress-shard
          '(:name "Emacs reflection binding crosswalk stress"
            :selector "reflect-binding-crosswalk-stress"
            :ran 1
            :expected 1
            :unexpected 0
            :skipped 0
            :ert-seconds 1.0
            :wall-seconds 1.0
            :tests nil))
         (reflect-dynamic-manifest-stress-shard
          '(:name "Emacs reflection dynamic manifest stress"
            :selector "reflect-dynamic-manifest-stress"
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
                 reflect-dynamic-manifest-stress-shard
                 reflect-binding-crosswalk-stress-shard
                 reflect-documentation-stress-shard
                 reflect-catalog-stress-shard
                 reflect-contract-shard
                 agent-state-shard
                 capability-boundary-shard
                 agent-reliability-shard
                 agent-control-shard
                 portable-gauche-reflect-stress-shard
                 portable-gauche-reflect-shard
                 portable-gauche-shard
                 portable-guile-reflect-stress-shard
                 portable-guile-reflect-shard
                 portable-guile-shard
                 portable-compiled-shard
                 portable-racket-reflect-stress-shard
                 portable-racket-reflect-shard
                 portable-racket-shard
                 portable-gambit-native-shard
                 portable-gambit-reflect-stress-shard
                 portable-gambit-reflect-shard
                 portable-gambit-shard
                 portable-rest-shard
                 portable-eval-shard)))
         (details (cadr (split-string
                         markdown
                         "<summary>Detailed shard timings and diagnostic\
 timings</summary>\n\n"
                         t))))
    (should details)
    (should
     (string-match-p
      "| Portable R7RS Chibi evaluator subset |.*\n| Portable R7RS Chibi\
 non-evaluator subset |.*\n| Portable R7RS Gambit full suite |.*\n| Portable\
 R7RS Gambit reflection contract |.*\n| Portable R7RS Gambit reflection\
 stress |.*\n| Portable R7RS Gambit-compiled Consent Scheme self-host corpus\
 |.*\n| Portable R7RS Racket full suite |.*\n| Portable R7RS Racket\
 reflection contract |.*\n| Portable R7RS Racket reflection stress |.*\n|\
 Portable R7RS Racket-compiled Consent Scheme self-host corpus |.*\n|\
 Portable R7RS Guile full suite |.*\n| Portable R7RS Guile reflection\
 contract |.*\n| Portable R7RS Guile reflection stress |.*\n| Portable R7RS\
 Gauche full suite |.*\n| Portable R7RS Gauche reflection contract |.*\n|\
 Portable R7RS Gauche reflection stress |.*\n| Emacs agent control |.*\n|\
 Emacs agent reliability |.*\n| Emacs capability boundary |.*\n|\
 Emacs agent state |.*\n| Emacs tools/docs/integration |.*\n| Emacs reflection\
 contract |.*\n| Emacs reflection catalog stress |.*\n| Emacs reflection\
 documentation stress |.*\n| Emacs reflection binding crosswalk stress\
 |.*\n| Emacs reflection dynamic manifest stress |"
      details))))

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
     "CONSENT_CI_SHARD_NAME=Portable R7RS Gambit full suite / source\
 metadata on / docstrings full\n"
     "CONSENT_CI_SHARD_SELECTOR=\
\"^consent-scheme-gambit-host-test-r7rs-suite$\"\n"
     "CONSENT_CI_WALL_SECONDS=10\n"))
   (consent-ci-test--write-log
    (concat
     "Running 2 tests (2026-06-06 13:00:00-0700, selector `x')\n"
     "   passed  1/2  consent-reader-test-a (0.040000 sec)\n"
     "   failed  2/2  consent-reader-test-b (0.500000 sec)\n"
     "\n"
     "Ran 2 tests, 1 results as expected, 1 unexpected "
     "(2026-06-06 13:00:01-0700, 0.540000 sec)\n"
     "CONSENT_CI_SHARD_NAME=Emacs core language/runtime / source metadata on /\
 docstrings full\n"
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
            ;; Shards sort into display order: portable Gambit before Emacs
            ;; core.
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
    (should (string-match-p
      "CONSENT_CI_RUN_RECORD_FILE=ci-logs/run-record.jsonl"
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
