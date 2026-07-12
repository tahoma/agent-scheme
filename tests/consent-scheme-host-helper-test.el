;;; consent-scheme-host-helper-test.el --- Portable host bridge helper tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for the multi-host portable R7RS bridge used by CI host shards.

;;; Code:

(require 'ert)
(require 'consent-scheme-host)

(ert-deftest consent-portable-host-helper-test-builds-gauche-arguments ()
  "Build Gauche R7RS arguments with the target library path before the test file."
  (should
   (equal
    (consent--scheme-host-arguments
     'gauche
     "scheme"
     "tests/scheme/consent-reader-test.scm")
    '("-I" "scheme" "-r7" "tests/scheme/consent-reader-test.scm"))))

(ert-deftest consent-portable-host-helper-test-builds-guile-arguments ()
  "Build Guile R7RS arguments with auto-compilation disabled."
  (should
   (equal
    (consent--scheme-host-arguments
     'guile
     "scheme"
     "tests/scheme/consent-reader-test.scm")
    '("--no-auto-compile"
      "--r7rs"
      "-L"
      "scheme"
      "tests/scheme/consent-reader-test.scm"))))

(ert-deftest consent-portable-host-helper-test-builds-compiled-arguments ()
  "Build compiled Consent Scheme runner arguments for R7RS test files."
  (should
   (equal
    (consent--scheme-host-arguments
     'compiled
     "scheme"
     "tests/scheme/consent-reader-test.scm")
    '("--host-run" "tests/scheme/consent-reader-test.scm")))
  (should
   (equal
    (consent--scheme-host-probe-arguments 'compiled "scheme")
    '("--eval" "(+ 1 2)"))))

(ert-deftest consent-portable-host-helper-test-builds-gambit-native-arguments ()
  "Build Gambit-compiled runner arguments for R7RS test files."
  (should
   (equal
    (consent--scheme-host-arguments
     'gambit-native
     "scheme"
     "tests/scheme/consent-reader-test.scm")
    '("--host-run" "tests/scheme/consent-reader-test.scm")))
  (should
   (equal
    (consent--scheme-host-probe-arguments 'gambit-native "scheme")
    '("--eval" "(+ 1 2)"))))

(ert-deftest consent-portable-host-helper-test-maps-launcher-environments ()
  "Map each portable host to the thin launcher's command override."
  (should
   (equal
    (mapcar #'consent--scheme-host-command-environment-name
            '(gambit gambit-native racket gauche guile compiled chibi))
    '("CONSENT_GAMBIT"
      "CONSENT_GAMBIT_NATIVE"
      "CONSENT_RACKET"
      "CONSENT_GAUCHE"
      "CONSENT_GUILE"
      "CONSENT_COMPILED"
      "CONSENT_CHIBI"))))

(ert-deftest consent-portable-host-helper-test-expands-gambit-native-runner-path ()
  "Expand repository-relative configured Gambit-compiled runner paths."
  (let ((prior (getenv "CONSENT_GAMBIT_NATIVE"))
        (consent--test-root "/tmp/consent-root/"))
    (unwind-protect
        (progn
          (setenv
           "CONSENT_GAMBIT_NATIVE"
           "build/compile/gambit/bin/consent")
          (should
           (equal
            (consent--scheme-host-command 'gambit-native)
            "/tmp/consent-root/build/compile/gambit/bin/consent")))
      (setenv "CONSENT_GAMBIT_NATIVE" prior))))

(ert-deftest consent-portable-host-helper-test-expands-compiled-runner-path ()
  "Expand repository-relative configured compiled runner paths."
  (let ((prior (getenv "CONSENT_COMPILED"))
        (consent--test-root "/tmp/consent-root/"))
    (unwind-protect
        (progn
          (setenv
           "CONSENT_COMPILED"
           "build/compile/racket/bin/consent")
          (should
           (equal
            (consent--scheme-host-command 'compiled)
            "/tmp/consent-root/build/compile/racket/bin/consent")))
      (setenv "CONSENT_COMPILED" prior))))

(ert-deftest consent-portable-host-helper-test-builds-racket-collection ()
  "Generate Racket collection wrappers from portable `.sld' libraries."
  (let* ((source-root (make-temp-file "consent-racket-source-" t))
         (library-root (expand-file-name "scheme" source-root))
         (target-root (make-temp-file "consent-racket-target-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "consent" library-root) t)
          (with-temp-file
              (expand-file-name "consent/example.sld" library-root)
            (insert "(define-library (consent example)\n")
            (insert "  (export example)\n")
            (insert "  (import (scheme base))\n")
            (insert "  (begin (define example 'ok)))\n"))
          (make-directory (expand-file-name "agent" library-root) t)
          (with-temp-file
              (expand-file-name "agent/example.sld" library-root)
            (insert "(define-library (agent example)\n")
            (insert "  (export example)\n")
            (insert "  (import (scheme base))\n")
            (insert "  (begin (define example 'ok)))\n"))
          (let ((collection-root
                 (consent--scheme-host-racket-collection-root
                  library-root
                  target-root)))
            (should
             (equal
              (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "consent/example.rkt" collection-root))
                (buffer-string))
              (concat
               "#lang r7rs\n"
               "(define-library (consent example)\n"
               "  (export example)\n"
               "  (import (scheme base))\n"
               "  (begin (define example 'ok)))\n")))
            (should
             (file-exists-p
              (expand-file-name "agent/example.rkt" collection-root)))))
      (delete-directory source-root t)
      (delete-directory target-root t))))

(provide 'consent-scheme-host-helper-test)

;;; consent-scheme-host-helper-test.el ends here
