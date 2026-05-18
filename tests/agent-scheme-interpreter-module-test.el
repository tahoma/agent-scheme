;;; agent-scheme-interpreter-module-test.el --- Interpreter module tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the interpreter backend boundary.  These checks keep the
;; trampoline backend loadable and usable without loading the public evaluator
;; orchestration module.

;;; Code:

(require 'ert)

(defun agent-scheme-interpreter-module-test--emacs-command ()
  "Return the current Emacs executable for interpreter subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest agent-scheme-interpreter-module-test-loads-backend-without-evaluator ()
  "Load and run the interpreter backend without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *agent-scheme-interpreter*")))
    (unwind-protect
        (let ((status
               (process-file
                (agent-scheme-interpreter-module-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" agent-scheme--test-root)
                "--eval"
                "(progn
                   (require 'agent-scheme-reader)
                   (require 'agent-scheme-result)
                   (require 'agent-scheme-interpreter)
                   (when (featurep 'agent-scheme-eval)
                     (error \"interpreter loaded evaluator\"))
                   (let* ((environment (agent-scheme-make-base-environment))
                          (context (agent-scheme--new-eval-context nil))
                          (value
                           (agent-scheme--trampoline
                            (agent-scheme-read \"(+ 1 2)\")
                            environment
                            context)))
                     (unless (equal (agent-scheme-value->external value) \"3\")
                       (kill-emacs 2))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; agent-scheme-interpreter-module-test.el ends here
