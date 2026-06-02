;;; consent-scheme-fixture-test.el --- Portable fixture corpus tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable shared fixture corpus runner.

;;; Code:

(require 'ert)

(defun consent--scheme-fixture-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-fixture-test-r7rs-suite ()
  "Run the portable shared fixture tests with an external Scheme."
  (let ((runner (consent--scheme-fixture-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *consent-r7rs-fixtures*")))
      (unwind-protect
          (let* ((default-directory consent--test-root)
                 (status
                  (process-file
                   runner
                   nil
                   output-buffer
                   nil
                   "-A"
                   (consent--test-target-library-directory)
                   "tests/scheme/consent-fixture-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; consent-scheme-fixture-test.el ends here
