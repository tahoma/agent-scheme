;;; Portable SRFI 64 testing stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib testing)
        (stdlib manifest))

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

(check 'approximate-and-passed-predicate
       (let ((runner
              (with-null-runner
               (lambda (runner)
                 (test-begin "approximate")
                 (test-approximate "near" 1.0 1.0001 0.001)
                 (test-end "approximate")))))
         (list (runner-counts runner)
               (test-passed? runner)
               (test-result-kind runner)))
       '((1 0 0 0 0) #t pass))

(check 'read-eval-string-uses-scheme-base
       (list (test-read-eval-string "(let ((x 20)) (+ x 22))")
             test-log-to-file)
       '(42 #f))

(check 'fresh-runner-initializes-auxiliary-value
       (list (test-runner-aux-value (test-runner-null))
             (test-runner-aux-value (test-runner-simple)))
       '(#f #f))

(check 'test-apply-selects-and-restores
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "apply")
           (test-apply
            runner
            (test-match-name "selected")
            (lambda ()
              (test-assert "ignored" #f)
              (test-assert "selected" #t)))
           (test-assert "after" #t)
           (test-end "apply"))))
       '(2 0 0 0 1))

(check 'group-cleanup-normal-and-error-exits
       (let ((events '()))
         (with-null-runner
          (lambda (runner)
            (test-group-with-cleanup
             "normal"
             (set! events (cons 'body events))
             (set! events (cons 'cleanup events)))
            (guard (condition
                    (else
                     (set! events (cons 'caught events))))
              (test-group-with-cleanup
               "error"
               (error "cleanup exercise")
               (set! events (cons 'error-cleanup events))))))
         (reverse events))
       '(body cleanup error-cleanup caught))

(check 'bad-count-and-end-name-callbacks
       (let ((events '()))
         (with-null-runner
          (lambda (runner)
            (test-runner-on-bad-count!
             runner
             (lambda (runner count expected)
               (set! events (cons (list 'count count expected) events))))
            (test-runner-on-bad-end-name!
             runner
             (lambda (runner begin end)
               (set! events (cons (list 'name begin end) events))))
            (test-begin "counted" 2)
            (test-assert "only" #t)
            (test-end "different")))
         (reverse events))
       '((name "different" "counted") (count 1 2)))

(check 'runner-factory-current-and-reset
       (let ((saved-factory (test-runner-factory))
             (saved-current (test-runner-current)))
         (dynamic-wind
             (lambda ()
               (test-runner-factory test-runner-null)
               (test-runner-current #f))
             (lambda ()
               (let ((runner (test-runner-create)))
                 (test-with-runner runner
                   (test-begin "state")
                   (test-assert #t)
                   (test-end "state"))
                 (let ((before (runner-counts runner)))
                   (test-runner-reset runner)
                   (list (test-runner? runner)
                         (eq? (test-runner-factory) test-runner-null)
                         before
                         (runner-counts runner)
                         (test-runner-group-stack runner)))))
             (lambda ()
               (test-runner-factory saved-factory)
               (test-runner-current saved-current))))
       '(#t #t (1 0 0 0 0) (0 0 0 0 0) ()))

(check 'result-property-mutation
       (let ((runner
              (with-null-runner
               (lambda (runner)
                 (test-assert "property" #t)))))
         (test-result-set! runner 'custom 41)
         (let ((set-value (test-result-ref runner 'custom)))
           (test-result-set! runner 'custom 42)
           (let ((replaced (test-result-ref runner 'custom)))
             (test-result-remove runner 'custom)
             (let ((removed (test-result-ref runner 'custom 'missing)))
               (test-result-set! runner 'again 'present)
               (test-result-clear runner)
               (list set-value replaced removed
                     (test-result-ref runner 'again 'cleared))))))
       '(41 42 missing cleared))

(check 'manifest-reports-upstream-meta-suite
       (let* ((entry (stdlib-manifest-ref '(stdlib testing)))
              (verification (assq 'verification (cdr entry)))
              (status (and verification
                           (assq 'test-status (cadr verification)))))
         (and status (memq 'upstream-meta-suite (cadr status)) #t))
       #t)

(finish-testing-tests)
