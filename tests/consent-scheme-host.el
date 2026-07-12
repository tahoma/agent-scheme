;;; consent-scheme-host.el --- Portable R7RS host bridge helpers  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helpers for running the same portable Scheme test files across R7RS hosts.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defun consent--scheme-host-normalize-command (command)
  "Return COMMAND with repository-relative executable paths expanded."
  (if (and (string-match-p "/" command)
           (not (file-name-absolute-p command)))
      (expand-file-name
       command
       (if (boundp 'consent--test-root)
           consent--test-root
         default-directory))
    command))

(defun consent--scheme-host-configured-command (env-name executable)
  "Return ENV-NAME's command or discovered EXECUTABLE."
  (let ((configured (getenv env-name)))
    (cond
     ((and configured (> (length configured) 0))
      (consent--scheme-host-normalize-command configured))
     (t
      (executable-find executable)))))

(defun consent--scheme-host-command (host)
  "Return the configured or discovered command for HOST."
  (pcase host
    ('gambit
     (consent--scheme-host-configured-command "CONSENT_GAMBIT" "gsi"))
    ('gambit-native
     ;; The gambit-native shard runs the white-box suites on the shipped
     ;; product binary: --host-run binds internal imports such as (consent
     ;; interpreter) to the binary's own compiled modules under the
     ;; internal-libraries grant, scoped to the working tree.
     (or (consent--scheme-host-configured-command
          "CONSENT_GAMBIT_NATIVE"
          "consent")
         (let ((runner
                (expand-file-name
                 "build/compile/gambit/bin/consent"
                 consent--test-root)))
           (and (file-executable-p runner) runner))))
    ('racket
     (consent--scheme-host-configured-command "CONSENT_RACKET" "racket"))
    ('gauche
     (consent--scheme-host-configured-command "CONSENT_GAUCHE" "gosh"))
    ('guile
     (consent--scheme-host-configured-command "CONSENT_GUILE" "guile"))
    ('compiled
     ;; See gambit-native: the white-box suites run on the shipped product
     ;; binary through --host-run.
     (or (consent--scheme-host-configured-command
          "CONSENT_COMPILED"
          "consent")
         (let ((runner
                (expand-file-name
                 "build/compile/racket/bin/consent"
                 consent--test-root)))
           (and (file-executable-p runner) runner))))
    ('chibi
     (consent--scheme-host-configured-command "CONSENT_CHIBI" "chibi-scheme"))
    (_
     (error "Unknown portable Scheme host: %S" host))))

(defun consent--scheme-host-command-environment-name (host)
  "Return the launcher command environment variable for HOST."
  (pcase host
    ('gambit "CONSENT_GAMBIT")
    ('gambit-native "CONSENT_GAMBIT_NATIVE")
    ('racket "CONSENT_RACKET")
    ('gauche "CONSENT_GAUCHE")
    ('guile "CONSENT_GUILE")
    ('compiled "CONSENT_COMPILED")
    ('chibi "CONSENT_CHIBI")
    (_ (error "Unknown portable Scheme host: %S" host))))

(defun consent--scheme-host-racket-collection-root
    (library-root collection-root)
  "Generate Racket R7RS collection wrappers for LIBRARY-ROOT.
Return COLLECTION-ROOT, which mirrors every `.sld' as a `#lang r7rs' module."
  (dolist (source (directory-files-recursively library-root "\\.sld\\'"))
    (let* ((relative (file-relative-name source library-root))
           (target
            (expand-file-name
             (concat (file-name-sans-extension relative) ".rkt")
             collection-root)))
      (make-directory (file-name-directory target) t)
      (with-temp-buffer
        (insert "#lang r7rs\n")
        (insert-file-contents source)
        (write-region (point-min) (point-max) target nil 'silent))))
  collection-root)

(defun consent--scheme-host-arguments
    (host library-directory test-file &optional racket-collection-root)
  "Return HOST arguments for LIBRARY-DIRECTORY and TEST-FILE.
RACKET-COLLECTION-ROOT is required when HOST is `racket'."
  (pcase host
    ('gambit
     (list
      (format "-:r7rs,search=%s" library-directory)
      test-file))
    ('gambit-native
     (ignore library-directory racket-collection-root)
     (list "--host-run" test-file))
    ('racket
     (unless racket-collection-root
       (error "Racket collection root is required"))
     (list "-S" racket-collection-root "-I" "r7rs" "-f" test-file))
    ('gauche
     (list "-I" library-directory "-r7" test-file))
    ('guile
     (list "--no-auto-compile" "--r7rs" "-L" library-directory test-file))
    ('compiled
     (ignore library-directory racket-collection-root)
     (list "--host-run" test-file))
    ('chibi
     (ignore racket-collection-root)
     (list "-A" library-directory test-file))
    (_
     (error "Unknown portable Scheme host: %S" host))))

(defun consent--scheme-host-probe-arguments
    (host library-directory &optional racket-collection-root)
  "Return HOST probe arguments for LIBRARY-DIRECTORY.
RACKET-COLLECTION-ROOT is accepted for API symmetry with test arguments."
  (pcase host
    ('gambit
     (list
      (format "-:r7rs,search=%s" library-directory)
      "-e"
      "(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)"))
    ('gambit-native
     (ignore library-directory racket-collection-root)
     (list "--eval" "(+ 1 2)"))
    ('racket
     (ignore racket-collection-root)
     (list
      "-I"
      "r7rs"
      "-e"
      "(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)"))
    ('gauche
     (list
      "-I"
      library-directory
      "-r7"
      "-e"
      "(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)"))
    ('guile
     (list
      "--no-auto-compile"
      "--r7rs"
      "-L"
      library-directory
      "-c"
      "(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)"))
    ('compiled
     (ignore library-directory racket-collection-root)
     (list "--eval" "(+ 1 2)"))
    ('chibi
     (ignore racket-collection-root)
     (list
      "-A"
      library-directory
      "-e"
      "(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)"))
    (_
     (error "Unknown portable Scheme host: %S" host))))

(defun consent--scheme-host-r7rs-available-p
    (host runner library-directory &optional racket-collection-root)
  "Return non-nil when RUNNER accepts HOST's R7RS arguments."
  (with-temp-buffer
    (condition-case nil
        (equal 0
               (apply
                #'process-file
                runner
                nil
                t
                nil
                (consent--scheme-host-probe-arguments
                 host
                 library-directory
                 racket-collection-root)))
      (file-error nil))))

(defun consent--scheme-host-run-files (host display-name test-files)
  "Run portable Scheme TEST-FILES on HOST named DISPLAY-NAME."
  (let ((runner (consent--scheme-host-command host)))
    (unless runner
      (ert-skip (format "%s is not available" display-name)))
    (let* ((library-directory
            (consent--test-target-library-directory))
           (library-directory-absolute
            (consent--test-target-library-directory-absolute))
           (racket-collection-root
            (when (eq host 'racket)
              (make-temp-file "consent-racket-collections-" t)))
           (output-buffer
            (generate-new-buffer
             (format " *consent-r7rs-%s*" display-name))))
      (unwind-protect
          (let ((default-directory consent--test-root)
                (process-environment
                 (cons
                  (format "CONSENT_LIBRARY_PATH=%s"
                          library-directory-absolute)
                  process-environment)))
            (when (eq host 'racket)
              (consent--scheme-host-racket-collection-root
               library-directory-absolute
               racket-collection-root))
            (unless (consent--scheme-host-r7rs-available-p
                     host
                     runner
                     library-directory
                     racket-collection-root)
              (ert-skip
               (format
                "%s does not support %s R7RS mode"
                runner
                display-name)))
            (dolist (test-file test-files)
              (let ((status
                     (apply
                      #'process-file
                      runner
                      nil
                      output-buffer
                      nil
                      (consent--scheme-host-arguments
                       host
                       library-directory
                       test-file
                       racket-collection-root))))
                (unless (equal status 0)
                  (ert-fail
                   (format "Portable Scheme test file %s failed on %s:\n%s"
                           test-file
                           display-name
                           (with-current-buffer output-buffer
                             (buffer-string)))))))
            (consent--test-emit-ci-check-timings output-buffer))
        (when (and racket-collection-root
                   (file-directory-p racket-collection-root))
          (delete-directory racket-collection-root t))
        (kill-buffer output-buffer)))))

(defun consent--scheme-host-run-plan (host display-name shard)
  "Run portable Scheme plan SHARD on HOST named DISPLAY-NAME."
  (let ((runner (consent--scheme-host-command host)))
    (unless runner
      (ert-skip (format "%s is not available" display-name)))
    (let ((launcher
           (expand-file-name
            "tools/run-portable-tests.sh"
            consent--test-root))
          (output-buffer
           (generate-new-buffer
            (format " *consent-r7rs-%s*" display-name))))
      (unwind-protect
          (let* ((default-directory consent--test-root)
                 (runner-setting
                  (format "%s=%s"
                          (consent--scheme-host-command-environment-name host)
                          runner))
                 (process-environment
                  (append
                   (list
                    (format "CONSENT_PORTABLE_HOST=%s" host)
                    (format "CONSENT_PORTABLE_GROUP=%s" shard)
                    (format "CONSENT_TEST_TARGET_ROOT=%s"
                            consent--test-target-root)
                    runner-setting)
                   process-environment)))
            (let ((status
                   (process-file launcher nil output-buffer nil)))
              (unless (equal status 0)
                (ert-fail
                 (format "Portable Scheme plan %s failed on %s:\n%s"
                         shard
                         display-name
                         (with-current-buffer output-buffer
                           (buffer-string))))))
            (consent--test-emit-ci-check-timings output-buffer))
        (kill-buffer output-buffer)))))

(defun consent--scheme-host-run-suite (host display-name)
  "Run the full portable Scheme suite on HOST named DISPLAY-NAME."
  (consent--scheme-host-run-plan
   host display-name (if (memq host '(compiled gambit-native))
                         'compiled
                       'full)))

(defun consent--scheme-host-run-reflect-suite (host display-name)
  "Run the portable reflection contract suite on HOST named DISPLAY-NAME."
  (consent--scheme-host-run-plan host display-name 'reflect))

(defun consent--scheme-host-run-reflect-stress-suite (host display-name)
  "Run the portable reflection stress suite on HOST named DISPLAY-NAME."
  (consent--scheme-host-run-plan host display-name 'reflect-stress))

(defun consent--scheme-host-live-plan-shard (host)
  "Return the live model plan shard appropriate for HOST."
  (if (memq host '(compiled gambit-native))
      'live-compiled
    'live-direct))

(provide 'consent-scheme-host)

;;; consent-scheme-host.el ends here
