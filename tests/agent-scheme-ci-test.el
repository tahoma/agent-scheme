;;; agent-scheme-ci-test.el --- CI reporting tests  -*- lexical-binding: t; -*-

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
                "AGENT_SCHEME_CI_SHARD_NAME=Emacs-hosted ERT\n"
                "AGENT_SCHEME_CI_SHARD_SELECTOR=(not \"agent-scheme-scheme-.*\")\n"
                "AGENT_SCHEME_CI_WALL_SECONDS=2\n")))
         (shard (agent-scheme-ci-parse-log-file log))
         (slowest (agent-scheme-ci-shard-slowest-tests shard 2)))
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
            "AGENT_SCHEME_CI_SHARD_NAME=Portable Chibi-backed ERT\n"
            "AGENT_SCHEME_CI_SHARD_SELECTOR=\"agent-scheme-scheme-.*\"\n"
            "AGENT_SCHEME_CI_WALL_SECONDS=1\n")))
         (markdown
          (agent-scheme-ci-render-markdown-summary
           (mapcar #'agent-scheme-ci-parse-log-file
                   (list portable-log emacs-log)))))
    (unwind-protect
        (progn
          (should (string-match-p "| Portable Chibi-backed ERT |" markdown))
          (should (string-match-p "| Emacs-hosted ERT |" markdown))
          (should (string-match-p "| Reader | 1 / 0\\.040s | 1 / 0\\.030s |"
                                  markdown))
          (should (string-match-p "| Evaluator | 0 / 0\\.000s | 1 / 0\\.200s |"
                                  markdown))
          (should (string-match-p
                   "| Fixture/conformance | 1 / 0\\.500s | 1 / 0\\.080s |"
                   markdown)))
      (delete-file emacs-log)
      (delete-file portable-log))))

(provide 'agent-scheme-ci-test)

;;; agent-scheme-ci-test.el ends here
