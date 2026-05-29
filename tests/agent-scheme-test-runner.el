;;; agent-scheme-test-runner.el --- Batch ERT runner  -*- lexical-binding: t; -*-

;;; Commentary:

;; Project-local ERT runner for Agent Scheme bootstrap tests.

;;; Code:

(require 'ert)

(setq load-prefer-newer t)

(defvar agent-scheme--test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root for the Agent Scheme test runner.")

(defvar agent-scheme--test-target-root
  (let ((configured (getenv "AGENT_SCHEME_TEST_TARGET_ROOT")))
    (file-name-as-directory
     (expand-file-name
      (if (and configured (> (length configured) 0))
          configured
        agent-scheme--test-root))))
  "Repository root whose portable Scheme implementation is under test.
This may differ from `agent-scheme--test-root' so a newer harness can run
against an older checkout or archive extracted elsewhere.")

(defun agent-scheme--test-target-file (relative-path)
  "Return RELATIVE-PATH under `agent-scheme--test-target-root'."
  (expand-file-name relative-path agent-scheme--test-target-root))

(defun agent-scheme--test-target-is-runner-root-p ()
  "Return non-nil when the harness and target roots are the same directory."
  (file-equal-p agent-scheme--test-root agent-scheme--test-target-root))

(defun agent-scheme--test-target-library-directory ()
  "Return the portable Scheme library directory for external Scheme commands."
  (if (agent-scheme--test-target-is-runner-root-p)
      "scheme"
    (agent-scheme--test-target-file "scheme")))

(defun agent-scheme--test-target-library-directory-absolute ()
  "Return the absolute portable Scheme library directory under the target root."
  (agent-scheme--test-target-file "scheme"))

(defun agent-scheme--test-emit-ci-check-timings (buffer)
  "Print fine-grained CI timing lines captured in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^AGENT_SCHEME_CI_CHECK_SECONDS=.*$" nil t)
        (princ (match-string 0))
        (princ "\n")))))

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

(require 'agent-scheme-test-options)

(dolist (test-file (agent-scheme--test-files))
  (load test-file nil t))

(agent-scheme-test-options-install-advice)

(ert-run-tests-batch-and-exit (agent-scheme--test-selector))

;;; agent-scheme-test-runner.el ends here
