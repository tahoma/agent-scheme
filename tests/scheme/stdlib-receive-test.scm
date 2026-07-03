;;; Portable SRFI 8 receive stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib receive))

;; Number of failed SRFI 8 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed receive check."
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (check name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (finish-receive-tests)
  "Report the SRFI 8 test result."
  (if (= failures 0)
      (begin
        (display "SRFI 8 receive tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 8 receive test failure(s)")
        (newline)
        (error "SRFI 8 receive tests failed" failures))))

(check 'fixed-formals
       (receive (x y) (values 2 5)
         (+ x y))
       7)

(check 'rest-formals
       (receive all (values 'a 'b 'c)
         all)
       '(a b c))

(check 'dotted-formals
       (receive (head . tail) (values 'first 'second 'third)
         (list head tail))
       '(first (second third)))

(check 'body-sequence
       (receive (x y) (values 3 4)
         (define sum
           (+ x y))
         (* sum y))
       28)

(finish-receive-tests)
