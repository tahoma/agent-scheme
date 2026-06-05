;;; consent-compile-portable-test.el --- Portable executable compile tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the top-level `make compile' host-compiled portable
;; runtime packaging path.

;;; Code:

(require 'ert)

(defun consent-compile-portable-test--command (env-name fallback)
  "Return ENV-NAME's configured command or FALLBACK from PATH."
  (let ((configured (getenv env-name)))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find fallback)))))

(defun consent-compile-portable-test--run-make (&rest arguments)
  "Run make with ARGUMENTS from the repository root.
Return a plist containing :status and :output."
  (let ((buffer (generate-new-buffer " *consent-make-compile-test*")))
    (unwind-protect
        (let ((status
               (let ((default-directory consent--test-root))
                 (apply #'process-file "make" nil buffer nil arguments))))
          (list :status status
                :output
                (with-current-buffer buffer
                  (buffer-string))))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--version-string ()
  "Return the canonical target runtime version as a dotted string."
  (with-temp-buffer
    (insert-file-contents
     (consent--test-target-file "scheme/consent/version.sld"))
    (goto-char (point-min))
    (unless
        (re-search-forward
         "'(consent-version[[:space:]]+\\([0-9]+\\)[[:space:]]+\\([0-9]+\\)[[:space:]]+\\([0-9]+\\))"
         nil
         t)
      (error "Could not read target Consent Scheme version datum"))
    (format "%s.%s.%s"
            (match-string 1)
            (match-string 2)
            (match-string 3))))

(defun consent-compile-portable-test--run-executable
    (program &rest arguments)
  "Run compiled PROGRAM with ARGUMENTS.
Return a plist containing :status and :output."
  (let ((buffer (generate-new-buffer " *consent-compiled-runner-test*")))
    (unwind-protect
        (let ((status
               (let ((default-directory consent--test-root))
                 (apply #'process-file program nil buffer nil arguments))))
          (list :status status
                :output
                (with-current-buffer buffer
                  (buffer-string))))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--run-repl (program input)
  "Run compiled PROGRAM's `--repl' with INPUT fed on standard input.
Return a plist with :status and :output, where :output is the program-output
stream (stdout) only; the interaction record stream (stderr) is discarded so the
assertion covers stream separation as well as the command."
  (let ((in-file (make-temp-file "consent-repl-input-"))
        (err-file (make-temp-file "consent-repl-stderr-"))
        (buffer (generate-new-buffer " *consent-compiled-repl-test*")))
    (unwind-protect
        (progn
          (with-temp-file in-file (insert input))
          (let ((status
                 (let ((default-directory consent--test-root))
                   (process-file program in-file (list buffer err-file) nil
                                 "--repl"))))
            (list :status status
                  :output
                  (with-current-buffer buffer
                    (buffer-string)))))
      (ignore-errors (delete-file in-file))
      (ignore-errors (delete-file err-file))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--status (result)
  "Return RESULT's process status."
  (plist-get result :status))

(defun consent-compile-portable-test--output (result)
  "Return RESULT's captured process output."
  (plist-get result :output))

(ert-deftest consent-compile-portable-test-rejects-unknown-host ()
  "Reject unknown compile hosts with an actionable setup message."
  (let* ((build-dir
          (make-temp-file "consent-compile-unknown-host-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           "CONSENT_COMPILE_HOST=bogus"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (consent-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "CONSENT_COMPILE_HOST must be one of: racket, gambit"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest consent-compile-portable-test-racket-builds-runner ()
  "Build a Racket-hosted portable executable and run smoke commands."
  (let ((racket
         (consent-compile-portable-test--command
          "CONSENT_RACKET" "racket"))
        (raco
         (consent-compile-portable-test--command
          "CONSENT_RACO" "raco")))
    (unless (and racket raco)
      (ert-skip "Racket and raco are not available"))
    (let* ((build-dir
            (make-temp-file "consent-compile-racket-" t))
           (result
            (consent-compile-portable-test--run-make
             "-s"
             (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
             "CONSENT_COMPILE_HOST=racket"
             (format "CONSENT_RACKET=%s" racket)
             (format "CONSENT_RACO=%s" raco)
             "compile"))
           (host-root (expand-file-name "racket" build-dir))
           (runner (expand-file-name "bin/consent" host-root))
           (manifest (expand-file-name "manifest.scm" host-root))
           (smoke-log (expand-file-name "logs/smoke.log" host-root))
           (version-string
            (consent-compile-portable-test--version-string)))
      (unwind-protect
          (progn
            (should
             (equal (consent-compile-portable-test--status result) 0))
            (should (file-executable-p runner))
            (should (file-exists-p manifest))
            (should (file-exists-p smoke-log))
            (should
             (string-match-p
              "(compile-host racket)"
              (with-temp-buffer
                (insert-file-contents manifest)
                (buffer-string))))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               runner "--version")
              (list :status 0
                    :output (format "Consent Scheme %s\n" version-string))))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               runner "--eval" "(+ 1 2)")
              '(:status 0 :output "3\n")))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               runner "--script" "tests/scheme/consent-reader-test.scm")
              '(:status 0 :output "Scheme reader tests passed\n")))
            (should
             (equal
              (consent-compile-portable-test--run-repl
               runner
               (concat "(import (scheme base) (scheme write))\n"
                       "(display \"ok\")(newline)\n"
                       "(exit)\n"))
              '(:status 0 :output "ok\n"))))
        (when (file-directory-p build-dir)
          (delete-directory build-dir t))))))

(ert-deftest consent-compile-portable-test-racket-missing-tools-fail ()
  "Fail explicit Racket compile requests with setup guidance."
  (let* ((build-dir
          (make-temp-file "consent-compile-missing-racket-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           "CONSENT_COMPILE_HOST=racket"
           "CONSENT_RACKET=/no/such/racket"
           "CONSENT_RACO=/no/such/raco"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (consent-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "Racket compile prerequisites are missing"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest consent-compile-portable-test-gambit-missing-tools-fail ()
  "Fail explicit Gambit compile requests with setup guidance."
  (let* ((build-dir
          (make-temp-file "consent-compile-missing-gambit-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           "CONSENT_COMPILE_HOST=gambit"
           "CONSENT_GAMBIT=/no/such/gsi"
           "CONSENT_GAMBIT_COMPILER=/no/such/gsc"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (consent-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "Gambit compile prerequisites are missing"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest consent-compile-portable-test-gambit-builds-runner ()
  "Build a Gambit-hosted portable executable and run smoke commands."
  (let ((gsi
         (consent-compile-portable-test--command
          "CONSENT_GAMBIT" "gsi"))
        (gsc
         (consent-compile-portable-test--command
          "CONSENT_GAMBIT_COMPILER" "gsc")))
    (unless (and gsi gsc)
      (ert-skip "Gambit gsi and gsc are not available"))
    (let* ((build-dir
            (make-temp-file "consent-compile-gambit-" t))
           (result
            (consent-compile-portable-test--run-make
             "-s"
             (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
             "CONSENT_COMPILE_HOST=gambit"
             (format "CONSENT_GAMBIT=%s" gsi)
             (format "CONSENT_GAMBIT_COMPILER=%s" gsc)
             "compile"))
           (host-root (expand-file-name "gambit" build-dir))
           (runner (expand-file-name "bin/consent" host-root))
           (manifest (expand-file-name "manifest.scm" host-root))
           (smoke-log (expand-file-name "logs/smoke.log" host-root))
           (version-string
            (consent-compile-portable-test--version-string)))
      (unwind-protect
          (progn
            (should
             (equal (consent-compile-portable-test--status result) 0))
            (should (file-executable-p runner))
            (should (file-exists-p manifest))
            (should (file-exists-p smoke-log))
            (should
             (file-directory-p
              (expand-file-name "src" host-root)))
            (should
             (string-match-p
              "(compile-host gambit)"
              (with-temp-buffer
                (insert-file-contents manifest)
                (buffer-string))))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               runner "--version")
              (list :status 0
                    :output (format "Consent Scheme %s\n" version-string))))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               runner "--eval" "(+ 1 2)")
              '(:status 0 :output "3\n")))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               runner "--script" "tests/scheme/consent-reader-test.scm")
              '(:status 0 :output "Scheme reader tests passed\n")))
            (should
             (equal
              (consent-compile-portable-test--run-repl
               runner
               (concat "(import (scheme base) (scheme write))\n"
                       "(display \"ok\")(newline)\n"
                       "(exit)\n"))
              '(:status 0 :output "ok\n"))))
        (when (file-directory-p build-dir)
          (delete-directory build-dir t))))))

(provide 'consent-compile-portable-test)

;;; consent-compile-portable-test.el ends here
