;;; Portable SRFI 64 testing stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib testing))

;; Number of failed SRFI 64 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed SRFI 64 check."
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

(define (runner-counts runner)
  "Return RUNNER pass, fail, xfail, xpass, and skip counts."
  (list (test-runner-pass-count runner)
        (test-runner-fail-count runner)
        (test-runner-xfail-count runner)
        (test-runner-xpass-count runner)
        (test-runner-skip-count runner)))

(define (with-null-runner thunk)
  "Call THUNK with a fresh null SRFI 64 runner."
  (let ((runner (test-runner-null)))
    (test-with-runner runner
      (thunk runner))
    runner))

(define (finish-testing-tests)
  "Report the SRFI 64 testing result."
  (if (= failures 0)
      (begin
        (display "SRFI 64 testing tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 64 testing test failure(s)")
        (newline)
        (error "SRFI 64 testing tests failed" failures))))

(check 'basic-test-counts
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "basic" 4)
           (test-assert "truth" #t)
           (test-eqv "eqv" 4 (+ 2 2))
           (test-eq "eq" 'same 'same)
           (test-equal "equal" '(a b) (list 'a 'b))
           (test-end "basic"))))
       '(4 0 0 0 0))

(check 'skip-and-expected-failure-counts
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "control")
           (test-skip "skip-me")
           (test-assert "run-me" #t)
           (test-assert "skip-me" #f)
           (test-expect-fail "known-bad")
           (test-assert "known-bad" #f)
           (test-expect-fail "surprise")
           (test-assert "surprise" #t)
           (test-end "control"))))
       '(1 0 1 1 1))

(check 'test-error-passes-on-raised-condition
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "errors" 1)
           (test-error "raises" (error "expected failure"))
           (test-end "errors"))))
       '(1 0 0 0 0))

(check 'test-result-properties
       (let ((properties '()))
         (with-null-runner
          (lambda (runner)
            (test-runner-on-test-end!
             runner
             (lambda (active)
               (set! properties (cons (test-result-alist active)
                                      properties))))
            (test-begin "properties")
            (test-equal "named" '(x y) (list 'x 'y))
            (test-end "properties")))
         (let ((result (car properties)))
           (list (cdr (assq 'test-name result))
                 (cdr (assq 'expected-value result))
                 (cdr (assq 'actual-value result))
                 (cdr (assq 'result-kind result)))))
       '("named" (x y) (x y) pass))

(check 'group-paths
       (let ((paths '()))
         (with-null-runner
          (lambda (runner)
            (test-runner-on-test-end!
             runner
             (lambda (active)
               (set! paths
                     (cons (list (test-runner-group-path active)
                                 (test-runner-test-name active))
                           paths))))
            (test-group "outer"
              (test-group "inner"
                (test-assert "leaf" #t)))))
         (reverse paths))
       '((("outer" "inner") "leaf")))

(finish-testing-tests)
