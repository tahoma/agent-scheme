;;; agent-scheme-scheme-fixture-test.el --- Portable fixture corpus tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridge for the portable shared fixture corpus runner.

;;; Code:

(require 'ert)

(defun agent-scheme--scheme-fixture-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "AGENT_SCHEME_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(ert-deftest agent-scheme-scheme-fixture-test-r7rs-suite ()
  "Run the portable shared fixture tests with an external Scheme."
  (let ((runner (agent-scheme--scheme-fixture-runner)))
    (skip-unless runner)
    (let ((output-buffer (generate-new-buffer " *agent-scheme-r7rs-fixtures*")))
      (unwind-protect
          (let* ((default-directory agent-scheme--test-root)
                 (status
                  (process-file
                   runner
                   nil
                   output-buffer
                   nil
                   "-A"
                   (agent-scheme--test-target-library-directory)
                   "tests/scheme/agent-scheme-fixture-test.scm")))
            (unless (equal status 0)
              (ert-fail
               (with-current-buffer output-buffer
                 (buffer-string)))))
        (kill-buffer output-buffer)))))

;;; agent-scheme-scheme-fixture-test.el ends here
