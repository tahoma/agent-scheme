;;; agent-scheme-scheme-gambit-test.el --- Gambit portable suite bridge  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT bridge for running the portable R7RS Scheme tests under Gambit.

;;; Code:

(require 'ert)

(defconst agent-scheme--scheme-gambit-test-files
  '("tests/scheme/agent-scheme-reader-test.scm"
    "tests/scheme/agent-scheme-fixture-test.scm"
    "tests/scheme/agent-scheme-module-boundary-test.scm"
    "tests/scheme/agent-scheme-transcript-test.scm"
    "tests/scheme/agent-scheme-eval-test.scm")
  "Portable Scheme test files exercised by the Gambit host shard.")

(defun agent-scheme--scheme-gambit-runner ()
  "Return the configured or discovered Gambit Scheme executable."
  (let ((configured (getenv "AGENT_SCHEME_GAMBIT")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "gsi")))))

(defun agent-scheme--scheme-gambit-r7rs-available-p (runner search-argument)
  "Return non-nil when RUNNER accepts Gambit R7RS SEARCH-ARGUMENT."
  (with-temp-buffer
    (condition-case nil
        (equal 0
               (process-file
                runner
                nil
                t
                nil
                search-argument
                "-e"
                "(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)"))
      (file-error nil))))

(ert-deftest agent-scheme-scheme-gambit-test-r7rs-suite ()
  "Run the portable R7RS tests with Gambit Scheme."
  (let ((runner (agent-scheme--scheme-gambit-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *agent-scheme-r7rs-gambit*")))
      (unwind-protect
          (let ((default-directory agent-scheme--test-root)
                (search-argument
                 (format
                  "-:r7rs,search=%s"
                  (agent-scheme--test-target-library-directory))))
            (unless (agent-scheme--scheme-gambit-r7rs-available-p
                     runner
                     search-argument)
              (ert-fail
               (format
                "%s does not support Gambit R7RS mode with %s"
                runner
                search-argument)))
            (dolist (test-file agent-scheme--scheme-gambit-test-files)
              (let ((status
                     (process-file
                      runner
                      nil
                      output-buffer
                      nil
                      search-argument
                      test-file)))
                (unless (equal status 0)
                  (ert-fail
                   (with-current-buffer output-buffer
                     (buffer-string))))))
            (agent-scheme--test-emit-ci-check-timings output-buffer))
        (kill-buffer output-buffer)))))

;;; agent-scheme-scheme-gambit-test.el ends here
