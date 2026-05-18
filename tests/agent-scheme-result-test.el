;;; agent-scheme-result-test.el --- Result rendering module tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for stable external result rendering without loading the
;; interpreter backend.

;;; Code:

(require 'ert)

(defun agent-scheme-result-test--emacs-command ()
  "Return the current Emacs executable for result module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest agent-scheme-result-test-loads-without-evaluator-module ()
  "Load result rendering without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *agent-scheme-result*")))
    (unwind-protect
        (let ((status
               (process-file
                (agent-scheme-result-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" agent-scheme--test-root)
                "--eval"
                "(progn
                   (require 'agent-scheme-result)
                   (when (featurep 'agent-scheme-eval)
                     (error \"result loaded evaluator\"))
                   (unless (equal
                            (agent-scheme-value->external
                             (agent-scheme-read \"(alpha beta)\"))
                            \"(alpha beta)\")
                     (kill-emacs 2))
                   (unless (equal
                            (agent-scheme-result->external
                             (list (agent-scheme--syntax-symbol \"status\")
                                   (agent-scheme--syntax-symbol \"ok\")))
                            \"(status ok)\")
                     (kill-emacs 3)))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; agent-scheme-result-test.el ends here
