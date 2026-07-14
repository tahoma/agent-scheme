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
        (stdlib eager-comprehensions)
        (stdlib lightweight-testing)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

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
  "Return upstream SRFI 78's Fibonacci value using bounded linear work."
  (let loop ((remaining n) (previous 0) (current 1))
    (if (= remaining 0)
        previous
        (loop (- remaining 1) current (+ previous current)))))

(testing-registry-case
 'simple-test-pass '(portable stdlib)
(test-equal 'simple-test-pass
             #t
             (upstream-example-passes?
                  (lambda ()
                    (check (+ 1 1) => 2)))))

(testing-registry-case
 'simple-test-fail '(portable stdlib)
(test-equal 'simple-test-fail
             #t
             (upstream-example-fails?
                  (lambda ()
                    (check (+ 1 1) => 3)))))

(testing-registry-case
 'default-vector-equality '(portable stdlib)
(test-equal 'default-vector-equality
             #t
             (upstream-example-passes?
                  (lambda ()
                    (check (vector 1) => (vector 1))))))

(testing-registry-case
 'custom-vector-equality '(portable stdlib)
(test-equal 'custom-vector-equality
             #t
             (upstream-example-fails?
                  (lambda ()
                    (check (vector 1) (=> eq?) (vector 1))))))

(testing-registry-case
 'check-ec-no-qualifier '(portable stdlib)
(test-equal 'check-ec-no-qualifier
             #t
             (upstream-example-passes?
                  (lambda ()
                    (check-ec (+ 1 1) => 2)))))

(testing-registry-case
 'check-ec-range-argument-reporting '(portable stdlib)
(test-equal 'check-ec-range-argument-reporting
             #t
             (upstream-example-passes?
                  (lambda ()
                    (check-ec (: x 10) (+ x 1) => (+ x 1) (x))))))

(testing-registry-case
 'check-ec-distributive-law '(portable stdlib)
(test-equal 'check-ec-distributive-law
             #t
             (upstream-example-passes?
                  (lambda ()
                    (check-ec (: x 10)
                              (: y 10)
                              (: z 10)
                              (* x (+ y z))
                              => (+ (* x y) (* x z))
                              (x y z))))))

(testing-registry-case
 'fib-simple-examples '(portable stdlib)
(test-equal 'fib-simple-examples
             #t
             (begin
                   (check-reset!)
                   (check-set-mode! 'summary)
                   (check (fib 1) => 1)
                   (check (fib 2) => 1)
                   (check-passed? 2))))

(testing-registry-case
 'fib-parametric-example '(portable stdlib)
(test-equal 'fib-parametric-example
             #t
             (upstream-example-passes?
                  (lambda ()
                    (check-ec (: n 1 31)
                              (even? (fib n))
                              => (= (modulo n 3) 0)
                              (n))))))

(testing-registry-case
 'check-report-example '(portable stdlib)
(test-equal 'check-report-example
             "\n; *** checks *** : 2 correct, 0 failed.\n"
             (capture-upstream-output
                  (lambda ()
                    (check-reset!)
                    (check-set-mode! 'summary)
                    (check (+ 1 1) => 2)
                    (check (fib 1) => 1)
                    (check-report)))))

(testing-runner-main "Stdlib Lightweight Testing Upstream portable tests" (command-line))
