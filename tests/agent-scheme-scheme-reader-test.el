;;; agent-scheme-scheme-reader-test.el --- Portable reader tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT bridge for the portable R7RS reader implementation.

;;; Code:

(require 'ert)

(defun agent-scheme--scheme-reader-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "AGENT_SCHEME_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest agent-scheme-scheme-reader-test-r7rs-suite ()
  "Run the portable R7RS reader tests with an external Scheme."
  (let ((runner (agent-scheme--scheme-reader-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *agent-scheme-r7rs-reader*")))
      (unwind-protect
          (let ((status
                 (process-file
                  runner
                  nil
                  output-buffer
                  nil
                  "-A"
                  (expand-file-name "scheme" agent-scheme--test-root)
                  (expand-file-name
                   "tests/scheme/agent-scheme-reader-test.scm"
                   agent-scheme--test-root))))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; agent-scheme-scheme-reader-test.el ends here
