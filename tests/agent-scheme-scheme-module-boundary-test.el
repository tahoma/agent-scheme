;;; agent-scheme-scheme-module-boundary-test.el --- Portable module boundary tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT bridge for portable R7RS pass-boundary libraries.

;;; Code:

(require 'ert)

(defun agent-scheme--scheme-module-boundary-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "AGENT_SCHEME_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest agent-scheme-scheme-module-boundary-test-r7rs-suite ()
  "Run the portable R7RS module-boundary tests."
  (let ((runner (agent-scheme--scheme-module-boundary-runner)))
    (skip-unless runner)
    (let ((output-buffer
           (generate-new-buffer " *agent-scheme-r7rs-module-boundary*")))
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
                   "tests/scheme/agent-scheme-module-boundary-test.scm"
                   agent-scheme--test-root))))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; agent-scheme-scheme-module-boundary-test.el ends here
