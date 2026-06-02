;;; consent-eval.el --- Public R7RS evaluator entry points  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Public orchestration functions for Consent Scheme evaluation.  The interpreter
;; backend lives in `consent-interpreter'.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-audit)
(require 'consent-policy)
(require 'consent-base)
(require 'consent-approval)
(require 'consent-memory)
(require 'consent-library)
(require 'consent-macro)
(require 'consent-interpreter)
(require 'consent-session)

(defun consent--eval-context-library-keys (context)
  "Return sorted library keys imported or registered in CONTEXT."
  (let (keys)
    (maphash
     (lambda (key _library)
       (push key keys))
     (consent--eval-context-libraries context))
    (sort keys #'string<)))

(defun consent--audit-evaluation-success
    (input-form value context)
  "Record a successful evaluation of INPUT-FORM producing VALUE."
  (consent-audit-record
   'evaluation
   `((category . pure-r7rs)
     (operation . "evaluate")
     (input-form . ,input-form)
     (imported-libraries . ,(consent--eval-context-library-keys context))
     (decision . allowed)
     (result . ,(consent-value->external value)))))

(defun consent--audit-evaluation-error
    (input-form condition context)
  "Record a failed evaluation of INPUT-FORM with CONDITION."
  (consent-audit-record
   'evaluation
   `((category . pure-r7rs)
     (operation . "evaluate")
     (input-form . ,input-form)
     (imported-libraries . ,(consent--eval-context-library-keys context))
     (decision . error)
     (error . ,(error-message-string condition)))))

(defun consent--resignal (condition)
  "Signal CONDITION again after audit handling."
  (signal (car condition) (cdr condition)))

;;;###autoload
(defun consent-eval (expression &optional environment options)
  "Evaluate one Consent Scheme EXPRESSION datum.
ENVIRONMENT defaults to a fresh base environment.  OPTIONS is a
plist supporting `:max-steps', `:max-non-tail-steps',
`:max-value-nodes', `:max-host-callbacks', `:max-events',
and `:max-event-nodes'."
  (let ((context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment)))
        (input-form (consent-value->external expression)))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (consent--ensure-base-syntax context eval-environment)
          (let ((value
                 (consent--trampoline
                  expression eval-environment context)))
            (consent-capability-expire-after-eval! context)
            (consent--audit-evaluation-success
             input-form value context)
            value))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--resignal condition)))))

;;;###autoload
(defun consent-eval-source (source &optional environment options)
  "Read and evaluate all datums in SOURCE.
ENVIRONMENT defaults to a fresh base environment.  The returned value
is the result of the last command or definition."
  (let* ((context (consent--new-eval-context options))
         (eval-environment (or environment
                               (consent-make-base-environment)))
         (input-form source))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (let* ((forms (consent-read-all source options))
                 (sequence (consent--make-sequence forms t)))
            (consent--ensure-base-syntax context eval-environment)
            (let ((value
                   (consent--trampoline
                    sequence eval-environment context)))
              (consent-capability-expire-after-eval! context)
              (consent--audit-evaluation-success
               input-form value context)
              value)))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--resignal condition)))))

;;;###autoload
(defalias 'consent-eval-string #'consent-eval-source
  "Read and evaluate all datums in a source string.
This alias is kept for callers that describe string input
explicitly; it has the same calling convention as
`consent-eval-source'.")

;;;###autoload
(defun consent-session-eval-source (id source &optional options)
  "Evaluate SOURCE inside persistent session ID.
OPTIONS may override the session context budgets for this evaluation.  The
session preserves definitions, imports, macros, transcript entries, recent
agent events, and handle references across calls."
  (let* ((session (consent-session--require id))
         (context (consent-session-context session))
         (environment (consent-session-environment session))
         (input-form source)
         (base-syntax-installed
          (consent--eval-context-base-syntax-installed context)))
    (when options
      (when (plist-member options :max-steps)
        (setf (consent--eval-context-maximum-steps context)
              (plist-get options :max-steps)))
      (when (plist-member options :max-non-tail-steps)
        (setf (consent--eval-context-maximum-steps context)
              (plist-get options :max-non-tail-steps)))
      (when (plist-member options :max-value-nodes)
        (setf (consent--eval-context-maximum-value-nodes context)
              (plist-get options :max-value-nodes)))
      (when (plist-member options :max-host-callbacks)
        (setf (consent--eval-context-maximum-host-callbacks context)
              (plist-get options :max-host-callbacks)))
      (consent--apply-current-context-options! context options))
    (consent-session--prepare-eval! session)
    (let ((start-count (consent-session--audit-start-count)))
      (consent-session--record-eval-start! session source)
      (condition-case condition
          (progn
            (consent-policy-authorize
             'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
            (let ((consent--memory-current-session session)
                  (consent--approval-current-session
                   (consent-session-id session)))
              (let* ((forms (consent-read-all source options))
                     (sequence (consent--make-sequence forms t)))
                (consent--ensure-base-syntax context environment)
                (unless base-syntax-installed
                  (setf (consent-session-baseline-syntax session)
                        (consent-session--syntax-current-names
                         (consent--eval-context-syntax-environment
                          context))))
                (let ((value
                       (consent--trampoline
                        sequence environment context)))
                  (consent-capability-expire-after-eval! context)
                  (consent-session--sync-capability-grants! session)
                  (consent--audit-evaluation-success
                   input-form value context)
                  (consent-session--record-eval-success!
                   session source value start-count)))))
        (error
         (consent-capability-expire-after-eval! context)
         (consent-session--sync-capability-grants! session)
         (consent--audit-evaluation-error input-form condition context)
         (consent-session--record-eval-error!
          session source condition start-count)
         (consent--resignal condition))))))

;;;###autoload
(defalias 'consent-session-eval-string #'consent-session-eval-source
  "Read and evaluate SOURCE inside a persistent Consent Scheme session.")

;;;###autoload
(defun consent-eval-result (expression &optional environment options)
  "Evaluate EXPRESSION and return a Scheme-readable result datum."
  (let ((context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment)))
        (input-form (consent-value->external expression)))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (consent--ensure-base-syntax context eval-environment)
          (let ((value
                 (consent--trampoline
                  expression eval-environment context)))
            (consent-capability-expire-after-eval! context)
            (consent--audit-evaluation-success
             input-form value context)
            (consent--ok-result-datum value context)))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--condition-result-datum condition context)))))

;;;###autoload
(defun consent-eval-source-result (source &optional environment options)
  "Read and evaluate SOURCE and return a Scheme-readable result datum."
  (let ((context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment)))
        (input-form source))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (let* ((forms (consent-read-all source options))
                 (sequence (consent--make-sequence forms t)))
            (consent--ensure-base-syntax context eval-environment)
            (let ((value
                   (consent--trampoline
                    sequence eval-environment context)))
              (consent-capability-expire-after-eval! context)
              (consent--audit-evaluation-success
               input-form value context)
              (consent--ok-result-datum value context))))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--condition-result-datum condition context)))))

(provide 'consent-eval)

;;; consent-eval.el ends here
