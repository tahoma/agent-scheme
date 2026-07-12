;;; Adapted upstream SRFI 78 lightweight-testing examples.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2005-2006 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the official SRFI 78 examples at
;;; <https://srfi.schemers.org/srfi-78/examples.scm>, source snapshot
;;; SHA-256 8058de61b647dca9431852b091fe0e439ea8297f12f5dcd5c257294cee405fc9.
;;; The upstream file is an executable example script with intentional failures,
;;; not a pass/fail unit suite. This file preserves the examples as targeted
;;; checks and avoids implementation-dependent fixnum/inexact-width failures.

(import (scheme base)
        (scheme write)
        (srfi 42)
        (srfi 78))

;; Number of failed adapted upstream SRFI 78 examples seen so far.
(define upstream-failures 0)

(define (record-upstream-failure name expected actual)
  "Record one failed adapted upstream SRFI 78 example."
  (set! upstream-failures (+ upstream-failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (upstream-verify name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (equal? actual expected))
      (record-upstream-failure name expected actual)))

(define (capture-upstream-output thunk)
  "Return the text THUNK writes to the current output port."
  (let ((port (open-output-string)))
    (parameterize ((current-output-port port))
      (thunk))
    (get-output-string port)))

(define (upstream-example-passes? thunk)
  "Return true when one upstream example THUNK records a passing check."
  (check-reset!)
  (check-set-mode! 'summary)
  (thunk)
  (check-passed? 1))

(define (upstream-example-fails? thunk)
  "Return true when one upstream example THUNK records a failed check."
  (check-reset!)
  (check-set-mode! 'summary)
  (thunk)
  (not (check-passed? 1)))

(define (fib n)
  "Return upstream SRFI 78's small Fibonacci example."
  (if (<= n 2)
      1
      (+ (fib (- n 1)) (fib (- n 2)))))

(define (finish-upstream-tests)
  "Report the adapted upstream SRFI 78 examples result."
  (if (= upstream-failures 0)
      (begin
        (display "Adapted upstream SRFI 78 examples passed")
        (newline))
      (begin
        (display upstream-failures)
        (display " adapted upstream SRFI 78 example failure(s)")
        (newline)
        (error "adapted upstream SRFI 78 examples failed" upstream-failures))))

(upstream-verify 'simple-test-pass
                 (upstream-example-passes?
                  (lambda ()
                    (check (+ 1 1) => 2)))
                 #t)

(upstream-verify 'simple-test-fail
                 (upstream-example-fails?
                  (lambda ()
                    (check (+ 1 1) => 3)))
                 #t)

(upstream-verify 'default-vector-equality
                 (upstream-example-passes?
                  (lambda ()
                    (check (vector 1) => (vector 1))))
                 #t)

(upstream-verify 'custom-vector-equality
                 (upstream-example-fails?
                  (lambda ()
                    (check (vector 1) (=> eq?) (vector 1))))
                 #t)

(upstream-verify 'check-ec-no-qualifier
                 (upstream-example-passes?
                  (lambda ()
                    (check-ec (+ 1 1) => 2)))
                 #t)

(upstream-verify 'check-ec-range-argument-reporting
                 (upstream-example-passes?
                  (lambda ()
                    (check-ec (: x 10) (+ x 1) => (+ x 1) (x))))
                 #t)

(upstream-verify 'check-ec-distributive-law
                 (upstream-example-passes?
                  (lambda ()
                    (check-ec (: x 10)
                              (: y 10)
                              (: z 10)
                              (* x (+ y z))
                              => (+ (* x y) (* x z))
                              (x y z))))
                 #t)

(upstream-verify 'fib-simple-examples
                 (begin
                   (check-reset!)
                   (check-set-mode! 'summary)
                   (check (fib 1) => 1)
                   (check (fib 2) => 1)
                   (check-passed? 2))
                 #t)

(upstream-verify 'fib-parametric-example
                 (upstream-example-passes?
                  (lambda ()
                    (check-ec (: n 1 31)
                              (even? (fib n))
                              => (= (modulo n 3) 0)
                              (n))))
                 #t)

(upstream-verify 'check-report-example
                 (capture-upstream-output
                  (lambda ()
                    (check-reset!)
                    (check-set-mode! 'summary)
                    (check (+ 1 1) => 2)
                    (check (fib 1) => 1)
                    (check-report)))
                 "\n; *** checks *** : 2 correct, 0 failed.\n")

(finish-upstream-tests)
