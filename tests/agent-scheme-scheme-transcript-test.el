;;; agent-scheme-scheme-transcript-test.el --- Portable transcript bridge  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT bridge for the portable `(agent transcript)' source library.

;;; Code:

(require 'ert)

(defun agent-scheme--scheme-transcript-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "AGENT_SCHEME_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest agent-scheme-scheme-transcript-test-r7rs-suite ()
  "Run the portable R7RS transcript tests."
  (let ((runner (agent-scheme--scheme-transcript-runner)))
    (skip-unless runner)
    (let ((output-buffer
           (generate-new-buffer " *agent-scheme-r7rs-transcript*")))
      (unwind-protect
          (let* ((default-directory agent-scheme--test-root)
                 (status
                  (process-file
                   runner
                   nil
                   output-buffer
                   nil
                   "-A"
                   (agent-scheme--test-target-library-directory)
                   "tests/scheme/agent-scheme-transcript-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; agent-scheme-scheme-transcript-test.el ends here
