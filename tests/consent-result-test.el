;;; consent-result-test.el --- Result rendering module tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for stable external result rendering without loading the
;; interpreter backend.

;;; Code:

(require 'ert)

(defun consent-result-test--emacs-command ()
  "Return the current Emacs executable for result module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest consent-result-test-loads-without-evaluator-module ()
  "Load result rendering without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *consent-result*")))
    (unwind-protect
        (let ((status
               (process-file
                (consent-result-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" consent--test-root)
                "--eval"
                "(progn
                   (require 'consent-result)
                   (when (featurep 'consent-eval)
                     (error \"result loaded evaluator\"))
                   (unless (equal
                            (consent-value->external
                             (consent-read \"(alpha beta)\"))
                            \"(alpha beta)\")
                     (kill-emacs 2))
                   (unless (equal
                            (consent-result->external
                             (list (consent--syntax-symbol \"status\")
                                   (consent--syntax-symbol \"ok\")))
                            \"(status ok)\")
                     (kill-emacs 3)))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; consent-result-test.el ends here
