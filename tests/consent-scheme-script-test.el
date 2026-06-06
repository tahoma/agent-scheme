;;; consent-scheme-script-test.el --- Portable executable-script tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable `(cli script)' shebang-handling library.

;;; Code:

(require 'ert)

(defun consent--scheme-script-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-script-test-r7rs-suite ()
  "Run the portable R7RS executable-script tests with an external Scheme."
  (let ((runner (consent--scheme-script-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *consent-r7rs-script*")))
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
                   "tests/scheme/consent-script-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; consent-scheme-script-test.el ends here
