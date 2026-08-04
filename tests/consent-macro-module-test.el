;;; consent-macro-module-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the macro-expansion module boundary.  These checks keep
;; syntax environments and `syntax-rules' expansion loadable without the
;; interpreter backend.

;;; Code:

(require 'ert)

(defun consent-macro-module-test--emacs-command ()
  "Return the current Emacs executable for macro module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest consent-macro-module-test-loads-expander-without-evaluator ()
  "Load and use the macro expander without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *consent-macro*")))
    (unwind-protect
        (let ((status
               (process-file
                (consent-macro-module-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" consent--test-root)
                "--eval"
                "(progn
                   (require 'consent-reader)
                   (require 'consent-result)
                   (require 'consent-macro)
                   (when (featurep 'consent-eval)
                     (error \"macro loaded evaluator\"))
                   (let* ((value-environment
                           (consent-make-empty-environment))
                          (context (consent--new-eval-context nil))
                          (syntax-environment
                           (consent--eval-context-syntax-environment
                            context))
                          (transformer
                           (consent--parse-syntax-rules
                            (consent-read
                             \"(syntax-rules () ((_ value) value))\")
                            value-environment
                            syntax-environment)))
                     (consent--syntax-environment-define
                      syntax-environment \"identity\" transformer)
                     (let ((expanded
                            (consent--expand-expression
                             (consent-read \"(identity 42)\")
                             value-environment
                             context)))
                       (unless (equal (consent-value->external expanded)
                                      \"42\")
                         (kill-emacs 2)))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; consent-macro-module-test.el ends here
