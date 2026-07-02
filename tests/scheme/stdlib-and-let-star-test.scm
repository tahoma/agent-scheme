;;; Adapted SRFI 2 and-let* test suite.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 1998 Oleg Kiselyov
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 2 `vland.scm` validation tests at
;;; https://okmij.org/ftp/Scheme/tests/vland.scm.  The original tests depend on
;;; implementation-specific `eval` and exception helpers; this file keeps the
;;; representative portable behavior checks in the full Consent Scheme host
;;; matrix.

(import (scheme base)
        (scheme write)
        (stdlib and-let-star))

;; Number of failed adapted SRFI checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed and-let* check."
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

(define (finish-and-let-star-tests)
  "Report the adapted SRFI 2 test result."
  (if (= failures 0)
      (begin
        (display "Adapted SRFI 2 and-let* tests passed")
        (newline))
      (begin
        (display failures)
        (display " adapted SRFI 2 and-let* test failure(s)")
        (newline)
        (error "adapted SRFI 2 and-let* tests failed" failures))))

(check 'no-claws-one-body (and-let* () 1) 1)
(check 'no-claws-multiple-body (and-let* () 1 2) 2)
(check 'no-claws-no-body (and-let* ()) #t)

(check 'one-bound-variable-false
       (let ((x #f)) (and-let* (x)))
       #f)
(check 'one-bound-variable-true
       (let ((x 1)) (and-let* (x)))
       1)
(check 'one-expression-claw
       (let ((x 1)) (and-let* (((+ x 1)))))
       2)
(check 'one-binding-claw-false (and-let* ((x #f))) #f)
(check 'one-binding-claw-true (and-let* ((x 1))) 1)

(check 'two-claws-short-circuit (and-let* ((#f) (x 1))) #f)
(check 'two-claws-expression-before-binding (and-let* ((2) (x 1))) 1)
(check 'two-claws-binding-before-expression (and-let* ((x 1) (2))) 2)
(check 'two-claws-binding-before-variable (and-let* ((x 1) x)) 1)
(check 'two-claws-binding-before-variable-expression
       (and-let* ((x 1) (x)))
       1)

(check 'bound-variable-body-false
       (let ((x #f)) (and-let* (x) x))
       #f)
(check 'bound-variable-body-true
       (let ((x "")) (and-let* (x) x))
       "")
(check 'expression-guard-body
       (let ((x 1)) (and-let* (((positive? x))) (+ x 1)))
       2)
(check 'expression-guard-no-body
       (let ((x 1)) (and-let* (((positive? x)))))
       #t)
(check 'expression-guard-false
       (let ((x 0)) (and-let* (((positive? x))) (+ x 1)))
       #f)
(check 'duplicate-bindings-are-sequential
       (let ((x 1))
         (and-let* (((positive? x))
                    (x (+ x 1))
                    (x (+ x 1)))
           (+ x 1)))
       4)

(check 'variable-guard-expression
       (let ((x 1)) (and-let* (x ((positive? x))) (+ x 1)))
       2)
(check 'variable-guard-false
       (let ((x #f)) (and-let* (x ((positive? x))) (+ x 1)))
       #f)
(check 'later-guard-prevents-body
       (let ((x 1))
         (and-let* (x (y (- x 1)) ((positive? y))) (/ x y)))
       #f)
(check 'all-guards-pass
       (let ((x 3))
         (and-let* (x (y (- x 1)) ((positive? y))) (/ x y)))
       (/ 3 2))

(finish-and-let-star-tests)
