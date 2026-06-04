;;; consent-scheme-native-cli-daemon-process-test.el --- Chibi process lane bridge  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Optional Chibi bridge for the portable native CLI and daemon process-boundary
;; lane.  The full-suite host shards run
;; tests/scheme/consent-native-cli-daemon-process-test.scm through the shared
;; file list in consent-scheme-host.el; this bridge runs the same program under
;; Chibi, the original non-Emacs path, and skips when Chibi is unavailable.

;;; Code:

(require 'ert)

(defun consent--scheme-native-cli-daemon-process-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-native-cli-daemon-process-test-r7rs-suite ()
  "Run the native CLI and daemon process-boundary lane under Chibi Scheme."
  (let ((runner (consent--scheme-native-cli-daemon-process-runner)))
    (skip-unless runner)
    (let ((output-buffer
           (generate-new-buffer " *consent-r7rs-native-cli-daemon-process*")))
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
                   "tests/scheme/consent-native-cli-daemon-process-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; consent-scheme-native-cli-daemon-process-test.el ends here
