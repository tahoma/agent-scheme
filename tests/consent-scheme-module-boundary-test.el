;;; consent-scheme-module-boundary-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Host-independent module-boundary check for the portable runtime.  The
;; portable module-boundary test file itself runs through the Scheme-native
;; test plan; the out-of-repository load
;; check below spawns Chibi directly because it must run from a working
;; directory outside the repository tree.

;;; Code:

(require 'ert)

(defun consent--scheme-module-boundary-runner ()
  "Return the configured or discovered Chibi Scheme executable."
  (let ((configured (getenv "CONSENT_CHIBI")))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find "chibi-scheme")))))

(defun consent--scheme-module-boundary-target-version-components ()
  "Return the portable runtime version components from the target root."
  (with-temp-buffer
    (insert-file-contents
     (consent--test-target-file "scheme/consent/version.sld"))
    (goto-char (point-min))
    (unless (re-search-forward
             (concat "'(consent-version[[:space:]]+\\([0-9]+\\)"
                     "[[:space:]]+\\([0-9]+\\)"
                     "[[:space:]]+\\([0-9]+\\))")
             nil
             t)
      (error "Could not read target Consent Scheme version datum"))
    (format "'(%s %s %s)"
            (match-string 1)
            (match-string 2)
            (match-string 3))))

(ert-deftest
  consent-scheme-module-boundary-test-runtime-version-loads-outside-repo ()
  "Load portable runtime version data from a non-repository working directory."
  (let ((runner (consent--scheme-module-boundary-runner)))
    (skip-unless runner)
    (let ((output-buffer
           (generate-new-buffer " *consent-r7rs-runtime-version*"))
          (program-file
           (make-temp-file "consent-runtime-version-" nil ".scm"))
          (default-directory temporary-file-directory))
      (unwind-protect
          (progn
            (with-temp-file program-file
              (insert "(import (scheme base)\n")
              (insert "        (consent runtime))\n")
              (insert "(unless (equal? (consent-version-components)\n")
              (insert "                ")
              (insert
               (consent--scheme-module-boundary-target-version-components))
              (insert ")\n")
              (insert "  (error \"unexpected Consent Scheme version\"))\n"))
            (let ((status
                   (process-file
                    runner
                    nil
                    output-buffer
                    nil
                    "-A"
                    (consent--test-target-library-directory-absolute)
                    program-file)))
              (unless (equal status 0)
                (ert-fail
                 (with-current-buffer output-buffer
                   (buffer-string))))))
        (when (file-exists-p program-file)
          (delete-file program-file))
        (kill-buffer output-buffer)))))

;;; consent-scheme-module-boundary-test.el ends here
