;;; consent-scheme-native-cli-daemon-adapter-test.el --- Native CLI adapter fixture bridge  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable native CLI and daemon adapter fixture validator.
;; The validator parses the checked-in adapter declaration and capability
;; manifest as data and exercises the mock noninteractive and stale-handle
;; denials without starting a real process, terminal, socket, or daemon.

;;; Code:

(require 'ert)

(defun consent--scheme-native-cli-daemon-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest consent-scheme-native-cli-daemon-adapter-test-r7rs-suite ()
  "Validate the native CLI and daemon adapter fixture with an external Scheme."
  (let ((runner (consent--scheme-native-cli-daemon-runner)))
    (skip-unless runner)
    (let ((output-buffer
           (generate-new-buffer " *consent-r7rs-native-cli-daemon*")))
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
                   "tests/scheme/consent-native-cli-daemon-adapter-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; consent-scheme-native-cli-daemon-adapter-test.el ends here
