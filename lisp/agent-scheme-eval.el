;;; agent-scheme-eval.el --- Public R7RS evaluator entry points  -*- lexical-binding: t; -*-

;;; Commentary:

;; Public orchestration functions for Agent Scheme evaluation.  The interpreter
;; backend lives in `agent-scheme-interpreter'.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-audit)
(require 'agent-scheme-policy)
(require 'agent-scheme-base)
(require 'agent-scheme-library)
(require 'agent-scheme-macro)
(require 'agent-scheme-interpreter)

(defun agent-scheme--eval-context-library-keys (context)
  "Return sorted library keys imported or registered in CONTEXT."
  (let (keys)
    (maphash
     (lambda (key _library)
       (push key keys))
     (agent-scheme--eval-context-libraries context))
    (sort keys #'string<)))

(defun agent-scheme--audit-evaluation-success
    (input-form value context)
  "Record a successful evaluation of INPUT-FORM producing VALUE."
  (agent-scheme-audit-record
   'evaluation
   `((category . pure-r7rs)
     (operation . "evaluate")
     (input-form . ,input-form)
     (imported-libraries . ,(agent-scheme--eval-context-library-keys context))
     (decision . allowed)
     (result . ,(agent-scheme-value->external value)))))

(defun agent-scheme--audit-evaluation-error
    (input-form condition context)
  "Record a failed evaluation of INPUT-FORM with CONDITION."
  (agent-scheme-audit-record
   'evaluation
   `((category . pure-r7rs)
     (operation . "evaluate")
     (input-form . ,input-form)
     (imported-libraries . ,(agent-scheme--eval-context-library-keys context))
     (decision . error)
     (error . ,(error-message-string condition)))))

(defun agent-scheme--resignal (condition)
  "Signal CONDITION again after audit handling."
  (signal (car condition) (cdr condition)))

;;;###autoload
(defun agent-scheme-eval (expression &optional environment options)
  "Evaluate one Agent Scheme EXPRESSION datum.
ENVIRONMENT defaults to a fresh base environment.  OPTIONS is a
plist supporting `:max-steps', `:max-non-tail-steps',
`:max-value-nodes', `:max-host-callbacks', `:max-events',
and `:max-event-nodes'."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment)))
        (input-form (agent-scheme-value->external expression)))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (agent-scheme-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (agent-scheme--ensure-base-syntax context eval-environment)
          (let ((value
                 (agent-scheme--trampoline
                  expression eval-environment context)))
            (agent-scheme--audit-evaluation-success
             input-form value context)
            value))
      (error
       (agent-scheme--audit-evaluation-error input-form condition context)
       (agent-scheme--resignal condition)))))

;;;###autoload
(defun agent-scheme-eval-source (source &optional environment options)
  "Read and evaluate all datums in SOURCE.
ENVIRONMENT defaults to a fresh base environment.  The returned value
is the result of the last command or definition."
  (let* ((context (agent-scheme--new-eval-context options))
         (eval-environment (or environment
                               (agent-scheme-make-base-environment)))
         (input-form source))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (agent-scheme-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (let* ((forms (agent-scheme-read-all source))
                 (sequence (agent-scheme--make-sequence forms t)))
            (agent-scheme--ensure-base-syntax context eval-environment)
            (let ((value
                   (agent-scheme--trampoline
                    sequence eval-environment context)))
              (agent-scheme--audit-evaluation-success
               input-form value context)
              value)))
      (error
       (agent-scheme--audit-evaluation-error input-form condition context)
       (agent-scheme--resignal condition)))))

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
                              (agent-scheme-make-base-environment)))
        (input-form (agent-scheme-value->external expression)))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (agent-scheme-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (agent-scheme--ensure-base-syntax context eval-environment)
          (let ((value
                 (agent-scheme--trampoline
                  expression eval-environment context)))
            (agent-scheme--audit-evaluation-success
             input-form value context)
            (agent-scheme--ok-result-datum value context)))
      (error
       (agent-scheme--audit-evaluation-error input-form condition context)
       (agent-scheme--condition-result-datum condition context)))))

;;;###autoload
(defun agent-scheme-eval-source-result (source &optional environment options)
  "Read and evaluate SOURCE and return a Scheme-readable result datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment)))
        (input-form source))
    (setf (agent-scheme--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (agent-scheme-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (let* ((forms (agent-scheme-read-all source))
                 (sequence (agent-scheme--make-sequence forms t)))
            (agent-scheme--ensure-base-syntax context eval-environment)
            (let ((value
                   (agent-scheme--trampoline
                    sequence eval-environment context)))
              (agent-scheme--audit-evaluation-success
               input-form value context)
              (agent-scheme--ok-result-datum value context))))
      (error
       (agent-scheme--audit-evaluation-error input-form condition context)
       (agent-scheme--condition-result-datum condition context)))))

(provide 'agent-scheme-eval)

;;; agent-scheme-eval.el ends here
