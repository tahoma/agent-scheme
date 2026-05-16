;;; agent-scheme-smoke-test.el --- Smoke tests for the test harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests prove that ERT discovery and runner setup are wired into
;; the repository-local harness.

;;; Code:

(require 'ert)

(ert-deftest agent-scheme-smoke-test-harness-runs ()
  "Confirm the batch runner can discover and execute an ERT test."
  (should (bound-and-true-p agent-scheme--test-root))
  (should (file-directory-p agent-scheme--test-root))
  (should (member (expand-file-name "tests" agent-scheme--test-root) load-path)))

;;; agent-scheme-smoke-test.el ends here
