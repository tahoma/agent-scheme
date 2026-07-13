;;; Portable executable-script shebang test runner for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and verifies the portable
;;; `(cli script)' shebang-handling boundary: the narrow recognition rule, the
;;; line-preserving strip, and the end-to-end guarantee that a shebang-stripped
;;; script (including the `/bin/sh' polyglot) reads correctly while `#!'-tokens
;;; such as `#!fold-case' keep their reader meaning.

(import (scheme base)
        (scheme file)
        (scheme write)
        (only (consent interpreter) consent-value->external)
        (consent reader)
        (cli script)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Return #t when THUNK raises any portable Scheme condition.
(define (raises? thunk)
  (guard (condition (else #t))
    (thunk)
    #f))

;; Delete PATH when present, ignoring the absent-file condition.
(define (delete-if-present path)
  (guard (condition (else #f))
    (delete-file path)
    #t))

;; Write SOURCE to PATH, replacing any previous scratch file.
(define (write-scratch-file path source)
  (delete-if-present path)
  (call-with-output-file path
    (lambda (port)
      (display source port))))

;; The `/bin/sh' polyglot recommended in docs/executable-scripts.md.
(define sh-polyglot
  (string-append
   "#!/bin/sh\n"
   "#|\n"
   "exec consent-scheme --script \"$0\" \"$@\"\n"
   "|#\n"
   "(display \"hi\\n\")\n"))

;;;; Narrow recognition rule

(testing-registry-case
 'shebang-env-line '(portable core)
(test-equal 'shebang-env-line
             #t
             (cli-script-shebang-line? "#!/usr/bin/env consent-scheme --script")))
(testing-registry-case
 'shebang-absolute-path '(portable core)
(test-equal 'shebang-absolute-path
             #t
             (cli-script-shebang-line? "#!/bin/sh\n")))
(testing-registry-case
 'shebang-leading-space '(portable core)
(test-equal 'shebang-leading-space
             #t
             (cli-script-shebang-line? "#! /bin/sh\n")))
(testing-registry-case
 'shebang-leading-tab '(portable core)
(test-equal 'shebang-leading-tab
             #t
             (cli-script-shebang-line? "#!\tfoo\n")))
;; `#!'-tokens that are not shebangs keep their reader-token meaning.
(testing-registry-case
 'directive-fold-case-not-shebang '(portable core)
(test-equal 'directive-fold-case-not-shebang
             #f
             (cli-script-shebang-line? "#!fold-case\n(x)")))
(testing-registry-case
 'directive-r6rs-not-shebang '(portable core)
(test-equal 'directive-r6rs-not-shebang
             #f
             (cli-script-shebang-line? "#!r6rs")))
(testing-registry-case
 'bare-bang-not-shebang '(portable core)
(test-equal 'bare-bang-not-shebang
             #f
             (cli-script-shebang-line? "#!")))
;; A `#!' that is not the first two bytes is never a shebang.
(testing-registry-case
 'indented-hashbang-not-shebang '(portable core)
(test-equal 'indented-hashbang-not-shebang
             #f
             (cli-script-shebang-line? " #!/bin/sh")))
(testing-registry-case
 'plain-form-not-shebang '(portable core)
(test-equal 'plain-form-not-shebang
             #f
             (cli-script-shebang-line? "(display 1)\n")))

;;;; Line-preserving strip

;; The shebang text is consumed but its newline is kept, so the remaining
;; source starts with a blank first line and later datums keep their line.
(testing-registry-case
 'strip-keeps-terminator '(portable core)
(test-equal 'strip-keeps-terminator
             "\n(display 1)\n"
             (cli-script-strip-shebang "#!/bin/sh\n(display 1)\n")))
(testing-registry-case
 'strip-shebang-only '(portable core)
(test-equal 'strip-shebang-only
             ""
             (cli-script-strip-shebang "#!/bin/sh/no/newline")))
(testing-registry-case
 'strip-leaves-fold-case '(portable core)
(test-equal 'strip-leaves-fold-case
             "#!fold-case\n(x)"
             (cli-script-strip-shebang "#!fold-case\n(x)")))
(testing-registry-case
 'strip-leaves-plain-source '(portable core)
(test-equal 'strip-leaves-plain-source
             "(display 1)\n"
             (cli-script-strip-shebang "(display 1)\n")))

;;;; End-to-end reader behavior

;; The stripped polyglot reads to exactly the one program form; the `#| |#'
;; block comment that hides the `exec' line from Scheme is skipped by the reader.
(testing-registry-case
 'polyglot-reads-to-one-form '(portable core)
(test-equal 'polyglot-reads-to-one-form
             (list "(display \"hi\\n\")")
             (map consent-datum->external
            (consent-read-all (cli-script-strip-shebang sh-polyglot)))))
;; `#!fold-case' still folds through the reader after the (no-op) strip.
(testing-registry-case
 'fold-case-still-folds '(portable core)
(test-equal 'fold-case-still-folds
             "foo"
             (consent-datum->external
        (consent-read (cli-script-strip-shebang "#!fold-case\nFOO")))))
;; Without the strip a leading shebang is a reader error; the strip is what
;; keeps a valid executable script from being rejected.
(testing-registry-case
 'raw-shebang-would-error '(portable core)
(test-equal 'raw-shebang-would-error
             #t
             (raises? (lambda () (consent-read-all sh-polyglot)))))

;;;; End-to-end script command-line behavior

(define command-line-script-path
  "tests/scheme/scratch/consent-script-command-line-test.scm")

(testing-registry-case
 'consent-script-case-17 '(portable core)
(write-scratch-file
 command-line-script-path
 (string-append
  "#!/usr/bin/env consent-scheme\n"
  "(import (scheme base) (scheme process-context))\n"
  "(command-line)\n")))

(testing-registry-case
 'script-command-line-normalized '(portable core)
(test-equal 'script-command-line-normalized
             (consent-value->external
        (list command-line-script-path "alpha" "beta"))
             (consent-value->external
        (cli-script-run-file command-line-script-path
                             #f
                             (list (list 'script-arguments
                                         "alpha"
                                         "beta"))))))

;; The compiled self-host dispatcher must hide its own --host-run argument and
;; present the test file as the complete Scheme command line.
(testing-registry-case
 'host-run-command-line-normalized '(portable core)
(test-equal 'host-run-command-line-normalized
             (list command-line-script-path)
             (cdr (assq 'command-line
                  (cli-script-host-run-options
                   "." command-line-script-path)))))

(testing-registry-case
 'consent-script-case-20 '(portable core)
(delete-if-present command-line-script-path))

(testing-runner-main "Consent Script portable tests" (command-line))
