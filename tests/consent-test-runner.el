;;; consent-test-runner.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Project-local ERT runner for Consent Scheme bootstrap tests.

;;; Code:

(require 'ert)

(setq load-prefer-newer t)

(defvar consent--test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root for the Consent Scheme test runner.")

(defvar consent--test-target-root
  (let ((configured (getenv "CONSENT_TEST_TARGET_ROOT")))
    (file-name-as-directory
     (expand-file-name
      (if (and configured (> (length configured) 0))
          configured
        consent--test-root))))
  "Repository root whose portable Scheme implementation is under test.
This may differ from `consent--test-root' so a newer harness can run
against an older checkout or archive extracted elsewhere.")

(defun consent--test-target-file (relative-path)
  "Return RELATIVE-PATH under `consent--test-target-root'."
  (expand-file-name relative-path consent--test-target-root))

(defun consent--test-target-is-runner-root-p ()
  "Return non-nil when the harness and target roots are the same directory."
  (file-equal-p consent--test-root consent--test-target-root))

(defun consent--test-target-library-directory ()
  "Return the portable Scheme library directory for external Scheme commands."
  (if (consent--test-target-is-runner-root-p)
      "scheme"
    (consent--test-target-file "scheme")))

(defun consent--test-target-library-directory-absolute ()
  "Return the absolute portable Scheme library directory under the target\
 root."
  (consent--test-target-file "scheme"))

(defun consent--test-emit-ci-check-timings (buffer)
  "Print fine-grained CI timing lines captured in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^CONSENT_CI_CHECK_SECONDS=.*$" nil t)
        (princ (match-string 0))
        (princ "\n")))))

(defun consent--test-add-load-path (directory)
  "Add project-local DIRECTORY to `load-path' when it exists."
  (let ((path (expand-file-name directory consent--test-root)))
    (when (file-directory-p path)
      (add-to-list 'load-path path))))

(defun consent--test-files ()
  "Return project test files in deterministic load order."
  (sort
   (directory-files
    (expand-file-name "tests" consent--test-root)
    t
    "\\`consent-.*-test\\.el\\'")
   #'string<))

(defun consent--test-selector ()
  "Return the ERT selector requested by the environment, or t."
  (let ((raw-selector (getenv "CONSENT_TEST_SELECTOR")))
    (if (and raw-selector (> (length raw-selector) 0))
        (read raw-selector)
      t)))

(consent--test-add-load-path "lisp")
(consent--test-add-load-path "tests")

(require 'consent-test-options)

(dolist (test-file (consent--test-files))
  (load test-file nil t))

(consent-test-options-install-advice)

(ert-run-tests-batch-and-exit (consent--test-selector))

;;; consent-test-runner.el ends here
