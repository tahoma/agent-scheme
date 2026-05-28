;;; agent-scheme-scheme-eval-test.el --- Portable evaluator tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT bridge for the portable R7RS evaluator implementation.

;;; Code:

(require 'ert)

(defun agent-scheme--scheme-eval-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "AGENT_SCHEME_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest agent-scheme-scheme-eval-test-bootstrap-avoids-host-call/cc ()
  "Keep portable evaluator continuations explicit for bootstrapping."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name
      "scheme/agent-scheme/eval.sld"
      agent-scheme--test-target-root))
    (goto-char (point-min))
    (should-not
     (re-search-forward
      "^[[:space:]]*(\\(?:call-with-current-continuation\\|call/cc\\)\\_>"
      nil
      t))))

(ert-deftest agent-scheme-scheme-eval-test-r7rs-suite ()
  "Run the portable R7RS evaluator tests with an external Scheme."
  (let ((runner (agent-scheme--scheme-eval-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *agent-scheme-r7rs-eval*")))
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
                   "tests/scheme/agent-scheme-eval-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string))))
            (agent-scheme--test-emit-ci-check-timings output-buffer))
        (kill-buffer output-buffer)))))

;;; agent-scheme-scheme-eval-test.el ends here
