;;; agent-scheme-test-options.el --- CI matrix test option helpers  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helpers for applying CI matrix option defaults to evaluator-oriented tests.

;;; Code:

(require 'cl-lib)

(defconst agent-scheme-test-options-source-metadata-variable
  "AGENT_SCHEME_TEST_SOURCE_METADATA"
  "Environment variable selecting the CI test source metadata default.")

(defconst agent-scheme-test-options-docstring-retention-variable
  "AGENT_SCHEME_TEST_DOCSTRING_RETENTION"
  "Environment variable selecting the CI test docstring retention default.")

(defun agent-scheme-test-options--present-string (value)
  "Return non-nil when VALUE is a nonempty string."
  (and (stringp value)
       (> (length value) 0)))

(defun agent-scheme-test-options--downcase (value)
  "Return VALUE downcased, or nil when VALUE is blank."
  (when (agent-scheme-test-options--present-string value)
    (downcase value)))

(defun agent-scheme-test-options--source-metadata-value (raw)
  "Normalize RAW as a source metadata boolean option value."
  (pcase (agent-scheme-test-options--downcase raw)
    ((or 'nil "")
     :unset)
    ((or "on" "true" "t" "yes" "1")
     t)
    ((or "off" "false" "nil" "no" "0")
     nil)
    (other
     (error "%s must be on or off, got %S"
            agent-scheme-test-options-source-metadata-variable
            other))))

(defun agent-scheme-test-options--docstring-retention-value (raw)
  "Normalize RAW as a docstring retention option value."
  (pcase (agent-scheme-test-options--downcase raw)
    ((or 'nil "")
     :unset)
    ("full"
     'full)
    ("simple"
     'simple)
    ((or "none" "nil" "off" "false" "0")
     nil)
    (other
     (error "%s must be full, simple, or none, got %S"
            agent-scheme-test-options-docstring-retention-variable
            other))))

(defun agent-scheme-test-options-default-plist ()
  "Return CI matrix evaluator option defaults as a plist."
  (let ((source-metadata
         (agent-scheme-test-options--source-metadata-value
          (getenv agent-scheme-test-options-source-metadata-variable)))
        (docstring-retention
         (agent-scheme-test-options--docstring-retention-value
          (getenv agent-scheme-test-options-docstring-retention-variable)))
        options)
    (unless (eq source-metadata :unset)
      (setq options (plist-put options :source-metadata source-metadata)))
    (unless (eq docstring-retention :unset)
      (setq options
            (plist-put options :docstring-retention docstring-retention)))
    options))

(defun agent-scheme-test-options-merge-defaults (options)
  "Return OPTIONS with missing CI matrix defaults appended."
  (let ((merged (copy-sequence options))
        (defaults (agent-scheme-test-options-default-plist)))
    (while defaults
      (let ((key (pop defaults))
            (value (pop defaults)))
        (unless (plist-member merged key)
          (setq merged (plist-put merged key value)))))
    merged))

(defun agent-scheme-test-options-eval-args-with-defaults (args)
  "Return evaluator ARGS with CI matrix defaults merged into options."
  (let ((defaults (agent-scheme-test-options-default-plist)))
    (if (or (null defaults) (null args))
        args
      (let ((input (car args))
            (environment (if (cdr args) (cadr args) nil))
            (options (if (cddr args) (caddr args) nil))
            (rest (nthcdr 3 args)))
        (append
         (list input
               environment
               (agent-scheme-test-options-merge-defaults options))
         rest)))))

(defun agent-scheme-test-options-session-args-with-defaults (args)
  "Return session source evaluation ARGS with CI defaults merged."
  (let ((defaults (agent-scheme-test-options-default-plist)))
    (if (or (null defaults) (< (length args) 2))
        args
      (let ((id (car args))
            (source (cadr args))
            (options (if (cddr args) (caddr args) nil))
            (rest (nthcdr 3 args)))
        (append
         (list id
               source
               (agent-scheme-test-options-merge-defaults options))
         rest)))))

(defun agent-scheme-test-options-install-advice ()
  "Install test-only CI matrix option default advice."
  (dolist (function
           '(agent-scheme-eval
             agent-scheme-eval-source
             agent-scheme-eval-result
             agent-scheme-eval-source-result
             agent-scheme-expand
             agent-scheme-expand-source))
    (when (and (fboundp function)
               (not
                (advice-member-p
                 #'agent-scheme-test-options-eval-args-with-defaults
                 function)))
      (advice-add
       function
       :filter-args
       #'agent-scheme-test-options-eval-args-with-defaults)))
  (when (and (fboundp 'agent-scheme-session-eval-source)
             (not
              (advice-member-p
               #'agent-scheme-test-options-session-args-with-defaults
               'agent-scheme-session-eval-source)))
    (advice-add
     'agent-scheme-session-eval-source
     :filter-args
     #'agent-scheme-test-options-session-args-with-defaults)))

(provide 'agent-scheme-test-options)

;;; agent-scheme-test-options.el ends here
