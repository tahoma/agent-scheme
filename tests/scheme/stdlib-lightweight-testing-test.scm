;;; Portable SRFI 78 lightweight testing stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib eager-comprehensions)
        (stdlib lightweight-testing))

;; Number of failed SRFI 78 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed SRFI 78 library check."
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (verify name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (capture-output thunk)
  "Return the text THUNK writes to the current output port."
  (let ((port (open-output-string)))
    (parameterize ((current-output-port port))
      (thunk))
    (get-output-string port)))

(define (finish-lightweight-testing-tests)
  "Report the SRFI 78 lightweight-testing test result."
  (if (= failures 0)
      (begin
        (display "SRFI 78 lightweight-testing tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 78 lightweight-testing test failure(s)")
        (newline)
        (error "SRFI 78 lightweight-testing tests failed" failures))))

(check-set-mode! 'summary)
(check-reset!)
(check (+ 1 1) => 2)
(verify 'simple-check-passes
        (check-passed? 1)
        #t)

(check-reset!)
(check (+ 1 1) => 3)
(verify 'simple-check-fails
        (check-passed? 1)
        #f)

(check-reset!)
(check (vector 1) => (vector 1))
(verify 'default-equality-is-equal
        (check-passed? 1)
        #t)

(check-reset!)
(check (vector 1) (=> eq?) (vector 1))
(verify 'custom-equality-predicate
        (check-passed? 1)
        #f)

(check-reset!)
(check-ec (:range i 5) (< i 5) => #t (i))
(verify 'check-ec-passing-comprehension
        (check-passed? 1)
        #t)

(check-reset!)
(check-ec (:range i 5) (< i 3) => #t (i))
(verify 'check-ec-stops-on-first-failure
        (check-passed? 1)
        #f)

;; Count evaluations to prove `check-ec' exits when the first case fails.
(define check-ec-evaluations 0)
(check-reset!)
(check-ec (:range i 100)
          (begin
            (set! check-ec-evaluations (+ check-ec-evaluations 1))
            (< i 3))
          => #t
          (i))
(verify 'check-ec-stops-evaluating-after-first-failure
        check-ec-evaluations
        4)

(check-reset!)
(check-set-mode! 'off)
;; State flag used to prove off mode does not evaluate the check expression.
(define off-mode-evaluated? #f)
(check (begin
         (set! off-mode-evaluated? #t)
         off-mode-evaluated?)
       => #t)
(verify 'off-mode-skips-expression
        (list off-mode-evaluated? (check-passed? 0))
        '(#f #t))

(verify 'report-mode-success-output
        (capture-output
         (lambda ()
           (check-reset!)
           (check-set-mode! 'report)
           (check (+ 1 1) => 2)))
        "\n(+ 1 1) => 2 ; correct\n")

(verify 'report-failed-output
        (capture-output
         (lambda ()
           (check-reset!)
           (check-set-mode! 'report-failed)
           (check (+ 1 1) => 3)))
        "\n(+ 1 1) => 2 ; *** failed ***\n ; expected result: 3\n")

(verify 'summary-report-output
        (capture-output
         (lambda ()
           (check-reset!)
           (check-set-mode! 'summary)
           (check (+ 1 1) => 2)
           (check-report)))
        "\n; *** checks *** : 1 correct, 0 failed.\n")

(verify 'report-failed-summary-includes-first-failure
        (capture-output
         (lambda ()
           (check-reset!)
           (check-set-mode! 'report-failed)
           (check (+ 1 1) => 3)
           (check-report)))
        (string-append
         "\n(+ 1 1) => 2 ; *** failed ***\n"
         " ; expected result: 3\n"
         "\n; *** checks *** : 0 correct, 1 failed. First failed example:\n"
         "\n(+ 1 1) => 2 ; *** failed ***\n"
         " ; expected result: 3\n"))

(verify 'check-ec-failure-report-includes-bindings
        (capture-output
         (lambda ()
           (check-reset!)
           (check-set-mode! 'report-failed)
           (check-ec (:range i 5) (< i 3) => #t (i))))
        "\n(let ((i 3)) (< i 3)) => #f ; *** failed ***\n ; expected result: #t\n")

(finish-lightweight-testing-tests)
