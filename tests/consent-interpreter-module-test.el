;;; consent-interpreter-module-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the interpreter backend boundary.  These checks keep the
;; trampoline backend loadable and usable without loading the public evaluator
;; orchestration module.

;;; Code:

(require 'ert)

(defun consent-interpreter-module-test--emacs-command ()
  "Return the current Emacs executable for interpreter subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest consent-interpreter-module-test-loads-backend-without-evaluator ()
  "Load and run the interpreter backend without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *consent-interpreter*")))
    (unwind-protect
        (let ((status
               (process-file
                (consent-interpreter-module-test--emacs-command)
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
                   (require 'consent-interpreter)
                   (when (featurep 'consent-eval)
                     (error \"interpreter loaded evaluator\"))
                   (let* ((environment (consent-make-base-environment))
                          (context (consent--new-eval-context nil))
                          (value
                           (consent--trampoline
                            (consent-read \"(+ 1 2)\")
                            environment
                            context)))
                     (unless (equal (consent-value->external value) \"3\")
                       (kill-emacs 2))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; consent-interpreter-module-test.el ends here
