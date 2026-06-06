;;; consent-scheme-repl-parity-test.el --- Portable REPL parity bridge  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable half of the shared cross-host REPL parity
;; conformance suite (tests/scheme/consent-repl-parity-test.scm), run with an
;; external R7RS Scheme.  The Emacs half lives in consent-repl-parity-test.el;
;; the full-suite host shards run the portable half through
;; `consent--scheme-host-test-files'.

;;; Code:

(require 'ert)

(defun consent--scheme-repl-parity-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-repl-parity-test-r7rs-suite ()
  "Drive the shared REPL parity corpus against the portable REPL with an external Scheme."
  (let ((runner (consent--scheme-repl-parity-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *consent-r7rs-repl-parity*")))
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
                   "tests/scheme/consent-repl-parity-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; consent-scheme-repl-parity-test.el ends here
