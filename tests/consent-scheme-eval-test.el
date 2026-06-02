;;; consent-scheme-eval-test.el --- Portable evaluator tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable R7RS evaluator implementation.

;;; Code:

(require 'ert)

(defun consent--scheme-eval-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-eval-test-bootstrap-avoids-host-call/cc ()
  "Keep portable evaluator continuations explicit for bootstrapping."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name
      "scheme/consent/eval.sld"
      consent--test-target-root))
    (goto-char (point-min))
    (should-not
     (re-search-forward
      "^[[:space:]]*(\\(?:call-with-current-continuation\\|call/cc\\)\\_>"
      nil
      t))))

(ert-deftest consent-scheme-eval-test-r7rs-suite ()
  "Run the portable R7RS evaluator tests with an external Scheme."
  (let ((runner (consent--scheme-eval-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *consent-r7rs-eval*")))
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
                   "tests/scheme/consent-eval-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string))))
            (consent--test-emit-ci-check-timings output-buffer))
        (kill-buffer output-buffer)))))

;;; consent-scheme-eval-test.el ends here
