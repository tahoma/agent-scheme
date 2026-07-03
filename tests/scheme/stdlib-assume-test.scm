;;; Portable SRFI 145 assume stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib assume))

;; Number of failed SRFI 145 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed assume check."
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

(define (check-true name value)
  "Record NAME unless VALUE is true."
  (check name (if value #t #f) #t))

(define (raises? thunk)
  "Return #t when calling THUNK raises any condition."
  (call/cc
   (lambda (return)
     (with-exception-handler
      (lambda (condition) (return #t))
      (lambda () (thunk) #f)))))

(define (finish-assume-tests)
  "Report the SRFI 145 test result."
  (if (= failures 0)
      (begin
        (display "SRFI 145 assume tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 145 assume test failure(s)")
        (newline)
        (error "SRFI 145 assume tests failed" failures))))

(check 'truthy-object (assume '(a b) "list is true") '(a b))
(check 'false-is-the-only-false-value (assume 0 "zero is true") 0)

(check 'message-expressions-are-lazy-on-success
       (let ((events '()))
         (define (record tag value)
           (set! events (cons tag events))
           value)
         (let ((value
                (assume (record 'assumption 'ok)
                        (record 'message 'unreached))))
           (list value events)))
       '(ok (assumption)))

(check-true 'false-assumption-raises
            (raises? (lambda () (assume #f "invalid path" 'payload))))

(finish-assume-tests)
