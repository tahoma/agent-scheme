;;; consent-scheme-reader-test.el --- Portable reader tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable R7RS reader implementation.

;;; Code:

(require 'ert)

(defun consent--scheme-reader-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-reader-test-r7rs-suite ()
  "Run the portable R7RS reader tests with an external Scheme."
  (let ((runner (consent--scheme-reader-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *consent-r7rs-reader*")))
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
                   "tests/scheme/consent-reader-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; consent-scheme-reader-test.el ends here
