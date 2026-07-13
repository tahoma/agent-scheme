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
        (cli script))

;; Count failed portable script checks so the suite can report them together.
(define failures 0)

;; Record one failed portable script check and keep running the rest so
;; failures report together.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

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

(check 'shebang-env-line
       (cli-script-shebang-line? "#!/usr/bin/env consent-scheme --script")
       #t)
(check 'shebang-absolute-path
       (cli-script-shebang-line? "#!/bin/sh\n")
       #t)
(check 'shebang-leading-space
       (cli-script-shebang-line? "#! /bin/sh\n")
       #t)
(check 'shebang-leading-tab
       (cli-script-shebang-line? "#!\tfoo\n")
       #t)
;; `#!'-tokens that are not shebangs keep their reader-token meaning.
(check 'directive-fold-case-not-shebang
       (cli-script-shebang-line? "#!fold-case\n(x)")
       #f)
(check 'directive-r6rs-not-shebang
       (cli-script-shebang-line? "#!r6rs")
       #f)
(check 'bare-bang-not-shebang
       (cli-script-shebang-line? "#!")
       #f)
;; A `#!' that is not the first two bytes is never a shebang.
(check 'indented-hashbang-not-shebang
       (cli-script-shebang-line? " #!/bin/sh")
       #f)
(check 'plain-form-not-shebang
       (cli-script-shebang-line? "(display 1)\n")
       #f)

;;;; Line-preserving strip

;; The shebang text is consumed but its newline is kept, so the remaining
;; source starts with a blank first line and later datums keep their line.
(check 'strip-keeps-terminator
       (cli-script-strip-shebang "#!/bin/sh\n(display 1)\n")
       "\n(display 1)\n")
(check 'strip-shebang-only
       (cli-script-strip-shebang "#!/bin/sh/no/newline")
       "")
(check 'strip-leaves-fold-case
       (cli-script-strip-shebang "#!fold-case\n(x)")
       "#!fold-case\n(x)")
(check 'strip-leaves-plain-source
       (cli-script-strip-shebang "(display 1)\n")
       "(display 1)\n")

;;;; End-to-end reader behavior

;; The stripped polyglot reads to exactly the one program form; the `#| |#'
;; block comment that hides the `exec' line from Scheme is skipped by the reader.
(check 'polyglot-reads-to-one-form
       (map consent-datum->external
            (consent-read-all (cli-script-strip-shebang sh-polyglot)))
       (list "(display \"hi\\n\")"))
;; `#!fold-case' still folds through the reader after the (no-op) strip.
(check 'fold-case-still-folds
       (consent-datum->external
        (consent-read (cli-script-strip-shebang "#!fold-case\nFOO")))
       "foo")
;; Without the strip a leading shebang is a reader error; the strip is what
;; keeps a valid executable script from being rejected.
(check 'raw-shebang-would-error
       (raises? (lambda () (consent-read-all sh-polyglot)))
       #t)

;;;; End-to-end script command-line behavior

(define command-line-script-path
  "tests/scheme/scratch/consent-script-command-line-test.scm")

(write-scratch-file
 command-line-script-path
 (string-append
  "#!/usr/bin/env consent-scheme\n"
  "(import (scheme base) (scheme process-context))\n"
  "(command-line)\n"))

(check 'script-command-line-normalized
       (consent-value->external
        (cli-script-run-file command-line-script-path
                             #f
                             (list (list 'script-arguments
                                         "alpha"
                                         "beta"))))
       (consent-value->external
        (list command-line-script-path "alpha" "beta")))

;; The compiled self-host dispatcher must hide its own --host-run argument and
;; present the test file as the complete Scheme command line.
(check 'host-run-command-line-normalized
       (cdr (assq 'command-line
                  (cli-script-host-run-options
                   "." command-line-script-path)))
       (list command-line-script-path))

(delete-if-present command-line-script-path)

(if (= failures 0)
    (begin
      (display "Scheme script tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme script test failure(s)")
      (newline)
      (error "Scheme script tests failed")))
