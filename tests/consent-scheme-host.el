;;; consent-scheme-host.el --- Portable R7RS host bridge helpers  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helpers for running the same portable Scheme test files across R7RS hosts.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defconst consent--scheme-host-test-files
  '("tests/scheme/consent-reader-test.scm"
    "tests/scheme/consent-fixture-test.scm"
    "tests/scheme/consent-native-cli-daemon-adapter-test.scm"
    "tests/scheme/consent-native-cli-daemon-process-test.scm"
    "tests/scheme/consent-module-boundary-test.scm"
    "tests/scheme/consent-transcript-test.scm"
    "tests/scheme/consent-repl-test.scm"
    "tests/scheme/consent-repl-parity-test.scm"
    "tests/scheme/consent-session-test.scm"
    "tests/scheme/consent-agent-registry-test.scm"
    "tests/scheme/consent-agent-proposal-test.scm"
    "tests/scheme/consent-agent-runner-test.scm"
    "tests/scheme/consent-agent-reliability-test.scm"
    "tests/scheme/consent-agent-prompt-test.scm"
    "tests/scheme/consent-models-openai-test.scm"
    "tests/scheme/consent-script-test.scm"
    "tests/scheme/stdlib-list-test.scm"
    "tests/scheme/stdlib-comparator-test.scm"
    "tests/scheme/stdlib-rbtree-test.scm"
    "tests/scheme/stdlib-and-let-star-test.scm"
    "tests/scheme/stdlib-receive-test.scm"
    "tests/scheme/stdlib-assume-test.scm"
    "tests/scheme/stdlib-generator-test.scm"
    "tests/scheme/consent-eval-test.scm")
  "Portable Scheme test files exercised by full-suite host shards.")

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

(defun consent--scheme-host-run-suite (host display-name)
  "Run the full portable Scheme suite on HOST named DISPLAY-NAME."
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
          (let ((default-directory consent--test-root))
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
            (dolist (test-file consent--scheme-host-test-files)
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
                   (with-current-buffer output-buffer
                     (buffer-string))))))
            (consent--test-emit-ci-check-timings output-buffer))
        (when (and racket-collection-root
                   (file-directory-p racket-collection-root))
          (delete-directory racket-collection-root t))
        (kill-buffer output-buffer)))))

(provide 'consent-scheme-host)

;;; consent-scheme-host.el ends here
