;;; Portable SRFI 145 assume stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib assume)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when calling THUNK raises any condition."
  (call/cc
   (lambda (return)
     (with-exception-handler
      (lambda (condition) (return #t))
      (lambda () (thunk) #f)))))

(testing-registry-case
 'truthy-object '(portable stdlib)
 ("stdlib-assume-test.scm" 21)
(test-equal 'truthy-object '(a b) (assume '(a b) "list is true")))
(testing-registry-case
 'false-is-the-only-false-value '(portable stdlib)
 ("stdlib-assume-test.scm" 25)
(test-equal 'false-is-the-only-false-value 0 (assume 0 "zero is true")))

(testing-registry-case
 'message-expressions-are-lazy-on-success '(portable stdlib)
 ("stdlib-assume-test.scm" 30)
(test-equal 'message-expressions-are-lazy-on-success
             '(ok (assumption))
             (let ((events '()))
         (define (record tag value)
           (set! events (cons tag events))
           value)
         (let ((value
                (assume (record 'assumption 'ok)
                        (record 'message 'unreached))))
           (list value events)))))

(testing-registry-case
 'false-assumption-raises '(portable stdlib)
 ("stdlib-assume-test.scm" 44)
(test-assert 'false-assumption-raises
             (raises? (lambda () (assume #f "invalid path" 'payload)))))

(testing-runner-main "Stdlib Assume portable tests" (command-line))
