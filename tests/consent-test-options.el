;;; consent-test-options.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helpers for applying CI matrix option defaults to evaluator-oriented tests.

;;; Code:

(require 'cl-lib)

(defconst consent-test-options-source-metadata-variable
  "CONSENT_TEST_SOURCE_METADATA"
  "Environment variable selecting the CI test source metadata default.")

(defconst consent-test-options-docstring-retention-variable
  "CONSENT_TEST_DOCSTRING_RETENTION"
  "Environment variable selecting the CI test docstring retention default.")

(defconst consent-test-options-max-source-metadata-variable
  "CONSENT_TEST_MAX_SOURCE_METADATA"
  "Environment variable selecting the CI test source metadata budget default.")

(defun consent-test-options--present-string (value)
  "Return non-nil when VALUE is a nonempty string."
  (and (stringp value)
       (> (length value) 0)))

(defun consent-test-options--downcase (value)
  "Return VALUE downcased, or nil when VALUE is blank."
  (when (consent-test-options--present-string value)
    (downcase value)))

(defun consent-test-options--source-metadata-value (raw)
  "Normalize RAW as a source metadata boolean option value."
  (pcase (consent-test-options--downcase raw)
    ((or 'nil "")
     :unset)
    ((or "on" "true" "t" "yes" "1")
     t)
    ((or "off" "false" "nil" "no" "0")
     nil)
    (other
     (error "%s must be on or off, got %S"
            consent-test-options-source-metadata-variable
            other))))

(defun consent-test-options--docstring-retention-value (raw)
  "Normalize RAW as a docstring retention option value."
  (pcase (consent-test-options--downcase raw)
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
            consent-test-options-docstring-retention-variable
            other))))

(defun consent-test-options--non-negative-integer-value (name raw)
  "Normalize RAW as an optional non-negative integer named NAME."
  (let ((value (consent-test-options--downcase raw)))
    (cond
     ((or (null value) (= (length value) 0))
      :unset)
     ((string-match-p "\\`[0-9]+\\'" value)
      (string-to-number value))
     (t
      (error "%s must be a non-negative integer, got %S" name raw)))))

(defun consent-test-options-default-plist ()
  "Return CI matrix evaluator option defaults as a plist."
  (let ((source-metadata
         (consent-test-options--source-metadata-value
          (getenv consent-test-options-source-metadata-variable)))
        (docstring-retention
         (consent-test-options--docstring-retention-value
          (getenv consent-test-options-docstring-retention-variable)))
        (max-source-metadata
         (consent-test-options--non-negative-integer-value
          consent-test-options-max-source-metadata-variable
          (getenv consent-test-options-max-source-metadata-variable)))
        options)
    (unless (eq source-metadata :unset)
      (setq options (plist-put options :source-metadata source-metadata)))
    (unless (eq docstring-retention :unset)
      (setq options
            (plist-put options :docstring-retention docstring-retention)))
    (unless (eq max-source-metadata :unset)
      (setq options
            (plist-put options :max-source-metadata max-source-metadata)))
    options))

(defun consent-test-options-merge-defaults (options)
  "Return OPTIONS with missing CI matrix defaults appended."
  (let ((merged (copy-sequence options))
        (defaults (consent-test-options-default-plist)))
    (while defaults
      (let ((key (pop defaults))
            (value (pop defaults)))
        (unless (plist-member merged key)
          (setq merged (plist-put merged key value)))))
    merged))

(defun consent-test-options-eval-args-with-defaults (args)
  "Return evaluator ARGS with CI matrix defaults merged into options."
  (let ((defaults (consent-test-options-default-plist)))
    (if (or (null defaults) (null args))
        args
      (let ((input (car args))
            (environment (if (cdr args) (cadr args) nil))
            (options (if (cddr args) (caddr args) nil))
            (rest (nthcdr 3 args)))
        (append
         (list input
               environment
               (consent-test-options-merge-defaults options))
         rest)))))

(defun consent-test-options-session-args-with-defaults (args)
  "Return session source evaluation ARGS with CI defaults merged."
  (let ((defaults (consent-test-options-default-plist)))
    (if (or (null defaults) (< (length args) 2))
        args
      (let ((id (car args))
            (source (cadr args))
            (options (if (cddr args) (caddr args) nil))
            (rest (nthcdr 3 args)))
        (append
         (list id
               source
               (consent-test-options-merge-defaults options))
         rest)))))

(defun consent-test-options-install-advice ()
  "Install test-only CI matrix option default advice."
  (dolist (function
           '(consent-eval
             consent-eval-source
             consent-eval-result
             consent-eval-source-result
             consent-expand
             consent-expand-source))
    (when (and (fboundp function)
               (not
                (advice-member-p
                 #'consent-test-options-eval-args-with-defaults
                 function)))
      (advice-add
       function
       :filter-args
       #'consent-test-options-eval-args-with-defaults)))
  (when (and (fboundp 'consent-session-eval-source)
             (not
              (advice-member-p
               #'consent-test-options-session-args-with-defaults
               'consent-session-eval-source)))
    (advice-add
     'consent-session-eval-source
     :filter-args
     #'consent-test-options-session-args-with-defaults)))

(provide 'consent-test-options)

;;; consent-test-options.el ends here
