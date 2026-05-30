;;; agent-scheme-scheme-host.el --- Portable R7RS host bridge helpers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers for running the same portable Scheme test files across R7RS hosts.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defconst agent-scheme--scheme-host-test-files
  '("tests/scheme/agent-scheme-reader-test.scm"
    "tests/scheme/agent-scheme-fixture-test.scm"
    "tests/scheme/agent-scheme-module-boundary-test.scm"
    "tests/scheme/agent-scheme-transcript-test.scm"
    "tests/scheme/agent-scheme-eval-test.scm")
  "Portable Scheme test files exercised by full-suite host shards.")

(defun agent-scheme--scheme-host-normalize-command (command)
  "Return COMMAND with repository-relative executable paths expanded."
  (if (and (string-match-p "/" command)
           (not (file-name-absolute-p command)))
      (expand-file-name
       command
       (if (boundp 'agent-scheme--test-root)
           agent-scheme--test-root
         default-directory))
    command))

(defun agent-scheme--scheme-host-configured-command (env-name executable)
  "Return ENV-NAME's command or discovered EXECUTABLE."
  (let ((configured (getenv env-name)))
    (cond
     ((and configured (> (length configured) 0))
      (agent-scheme--scheme-host-normalize-command configured))
     (t
      (executable-find executable)))))

(defun agent-scheme--scheme-host-command (host)
  "Return the configured or discovered command for HOST."
  (pcase host
    ('gambit
     (agent-scheme--scheme-host-configured-command "AGENT_SCHEME_GAMBIT" "gsi"))
    ('gambit-native
     (or (agent-scheme--scheme-host-configured-command
          "AGENT_SCHEME_GAMBIT_NATIVE"
          "agent-scheme")
         (let ((runner
                (expand-file-name
                 "build/compile/gambit/bin/agent-scheme"
                 agent-scheme--test-root)))
           (and (file-executable-p runner) runner))))
    ('racket
     (agent-scheme--scheme-host-configured-command "AGENT_SCHEME_RACKET" "racket"))
    ('gauche
     (agent-scheme--scheme-host-configured-command "AGENT_SCHEME_GAUCHE" "gosh"))
    ('guile
     (agent-scheme--scheme-host-configured-command "AGENT_SCHEME_GUILE" "guile"))
    ('compiled
     (or (agent-scheme--scheme-host-configured-command
          "AGENT_SCHEME_COMPILED"
          "agent-scheme")
         (let ((runner
                (expand-file-name
                 "build/compile/racket/bin/agent-scheme"
                 agent-scheme--test-root)))
           (and (file-executable-p runner) runner))))
    (_
     (error "Unknown portable Scheme host: %S" host))))

(defun agent-scheme--scheme-host-racket-collection-root
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

(defun agent-scheme--scheme-host-arguments
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
     (list "--script" test-file))
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
     (list "--script" test-file))
    (_
     (error "Unknown portable Scheme host: %S" host))))

(defun agent-scheme--scheme-host-probe-arguments
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
    (_
     (error "Unknown portable Scheme host: %S" host))))

(defun agent-scheme--scheme-host-r7rs-available-p
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
                (agent-scheme--scheme-host-probe-arguments
                 host
                 library-directory
                 racket-collection-root)))
      (file-error nil))))

(defun agent-scheme--scheme-host-run-suite (host display-name)
  "Run the full portable Scheme suite on HOST named DISPLAY-NAME."
  (let ((runner (agent-scheme--scheme-host-command host)))
    (unless runner
      (ert-skip (format "%s is not available" display-name)))
    (let* ((library-directory
            (agent-scheme--test-target-library-directory))
           (library-directory-absolute
            (agent-scheme--test-target-library-directory-absolute))
           (racket-collection-root
            (when (eq host 'racket)
              (make-temp-file "agent-scheme-racket-collections-" t)))
           (output-buffer
            (generate-new-buffer
             (format " *agent-scheme-r7rs-%s*" display-name))))
      (unwind-protect
          (let ((default-directory agent-scheme--test-root))
            (when (eq host 'racket)
              (agent-scheme--scheme-host-racket-collection-root
               library-directory-absolute
               racket-collection-root))
            (unless (agent-scheme--scheme-host-r7rs-available-p
                     host
                     runner
                     library-directory
                     racket-collection-root)
              (ert-skip
               (format
                "%s does not support %s R7RS mode"
                runner
                display-name)))
            (dolist (test-file agent-scheme--scheme-host-test-files)
              (let ((status
                     (apply
                      #'process-file
                      runner
                      nil
                      output-buffer
                      nil
                      (agent-scheme--scheme-host-arguments
                       host
                       library-directory
                       test-file
                       racket-collection-root))))
                (unless (equal status 0)
                  (ert-fail
                   (with-current-buffer output-buffer
                     (buffer-string))))))
            (agent-scheme--test-emit-ci-check-timings output-buffer))
        (when (and racket-collection-root
                   (file-directory-p racket-collection-root))
          (delete-directory racket-collection-root t))
        (kill-buffer output-buffer)))))

(provide 'agent-scheme-scheme-host)

;;; agent-scheme-scheme-host.el ends here
