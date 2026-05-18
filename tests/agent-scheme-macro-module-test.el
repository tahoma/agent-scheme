;;; agent-scheme-macro-module-test.el --- Macro module boundary tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the macro-expansion module boundary.  These checks keep
;; syntax environments and `syntax-rules' expansion loadable without the
;; interpreter backend.

;;; Code:

(require 'ert)

(defun agent-scheme-macro-module-test--emacs-command ()
  "Return the current Emacs executable for macro module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest agent-scheme-macro-module-test-loads-expander-without-evaluator ()
  "Load and use the macro expander without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *agent-scheme-macro*")))
    (unwind-protect
        (let ((status
               (process-file
                (agent-scheme-macro-module-test--emacs-command)
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
                   (require 'agent-scheme-macro)
                   (when (featurep 'agent-scheme-eval)
                     (error \"macro loaded evaluator\"))
                   (let* ((value-environment
                           (agent-scheme-make-empty-environment))
                          (context (agent-scheme--new-eval-context nil))
                          (syntax-environment
                           (agent-scheme--eval-context-syntax-environment
                            context))
                          (transformer
                           (agent-scheme--parse-syntax-rules
                            (agent-scheme-read
                             \"(syntax-rules () ((_ value) value))\")
                            value-environment
                            syntax-environment)))
                     (agent-scheme--syntax-environment-define
                      syntax-environment \"identity\" transformer)
                     (let ((expanded
                            (agent-scheme--expand-expression
                             (agent-scheme-read \"(identity 42)\")
                             value-environment
                             context)))
                       (unless (equal (agent-scheme-value->external expanded)
                                      \"42\")
                         (kill-emacs 2)))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; agent-scheme-macro-module-test.el ends here
