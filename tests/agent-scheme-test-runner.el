;;; agent-scheme-test-runner.el --- Batch ERT runner  -*- lexical-binding: t; -*-

;;; Commentary:

;; Project-local ERT runner for Agent Scheme bootstrap tests.

;;; Code:

(require 'ert)

(defvar agent-scheme--test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root for the Agent Scheme test runner.")

(defun agent-scheme--test-add-load-path (directory)
  "Add project-local DIRECTORY to `load-path' when it exists."
  (let ((path (expand-file-name directory agent-scheme--test-root)))
    (when (file-directory-p path)
      (add-to-list 'load-path path))))

(defun agent-scheme--test-files ()
  "Return project test files in deterministic load order."
  (sort
   (directory-files
    (expand-file-name "tests" agent-scheme--test-root)
    t
    "\\`agent-scheme-.*-test\\.el\\'")
   #'string<))

(defun agent-scheme--test-selector ()
  "Return the ERT selector requested by the environment, or t."
  (let ((raw-selector (getenv "AGENT_SCHEME_TEST_SELECTOR")))
    (if (and raw-selector (> (length raw-selector) 0))
        (read raw-selector)
      t)))

(agent-scheme--test-add-load-path "lisp")
(agent-scheme--test-add-load-path "tests")

(dolist (test-file (agent-scheme--test-files))
  (load test-file nil t))

(ert-run-tests-batch-and-exit (agent-scheme--test-selector))

;;; agent-scheme-test-runner.el ends here
