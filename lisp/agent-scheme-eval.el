;;; agent-scheme-eval.el --- Public R7RS evaluator entry points  -*- lexical-binding: t; -*-

;;; Commentary:

;; Public orchestration functions for Agent Scheme evaluation.  The interpreter
;; backend lives in `agent-scheme-interpreter'.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-base)
(require 'agent-scheme-library)
(require 'agent-scheme-macro)
(require 'agent-scheme-interpreter)

;;;###autoload
(defun agent-scheme-eval (expression &optional environment options)
  "Evaluate one Agent Scheme EXPRESSION datum.
ENVIRONMENT defaults to a fresh base environment.  OPTIONS is a
plist supporting `:max-steps', `:max-non-tail-steps',
`:max-value-nodes', and `:max-host-callbacks'."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--trampoline expression eval-environment context)))

;;;###autoload
(defun agent-scheme-eval-source (source &optional environment options)
  "Read and evaluate all datums in SOURCE.
ENVIRONMENT defaults to a fresh base environment.  The returned value
is the result of the last command or definition."
  (let* ((forms (agent-scheme-read-all source))
         (context (agent-scheme--new-eval-context options))
         (eval-environment (or environment
                               (agent-scheme-make-base-environment)))
         (sequence (agent-scheme--make-sequence forms t)))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--trampoline sequence eval-environment context)))

;;;###autoload
(defalias 'agent-scheme-eval-string #'agent-scheme-eval-source
  "Read and evaluate all datums in a source string.
This alias is kept for callers that describe string input
explicitly; it has the same calling convention as
`agent-scheme-eval-source'.")

;;;###autoload
(defun agent-scheme-eval-result (expression &optional environment options)
  "Evaluate EXPRESSION and return a Scheme-readable result datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (agent-scheme--ensure-base-syntax context eval-environment)
    (condition-case condition
        (agent-scheme--ok-result-datum
         (agent-scheme--trampoline expression eval-environment context)
         context)
      (error
       (agent-scheme--condition-result-datum condition context)))))

;;;###autoload
(defun agent-scheme-eval-source-result (source &optional environment options)
  "Read and evaluate SOURCE and return a Scheme-readable result datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (agent-scheme--ensure-base-syntax context eval-environment)
    (condition-case condition
        (let* ((forms (agent-scheme-read-all source))
               (sequence (agent-scheme--make-sequence forms t)))
          (agent-scheme--ok-result-datum
           (agent-scheme--trampoline sequence eval-environment context)
           context))
      (error
       (agent-scheme--condition-result-datum condition context)))))

(provide 'agent-scheme-eval)

;;; agent-scheme-eval.el ends here
