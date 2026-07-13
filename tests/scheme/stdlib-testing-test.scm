;;; Portable SRFI 64 testing stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib testing)
        (stdlib manifest)
        (scheme process-context)
        (testing registry)
        (testing runner))

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

(testing-registry-case
 'basic-test-counts '(portable stdlib)
 ("stdlib-testing-test.scm" 28)
(test-equal 'basic-test-counts
             '(4 0 0 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "basic" 4)
           (test-assert "truth" #t)
           (test-eqv "eqv" 4 (+ 2 2))
           (test-eq "eq" 'same 'same)
           (test-equal "equal" '(a b) (list 'a 'b))
           (test-end "basic"))))))

(testing-registry-case
 'skip-and-expected-failure-counts '(portable stdlib)
 ("stdlib-testing-test.scm" 43)
(test-equal 'skip-and-expected-failure-counts
             '(1 0 1 1 1)
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
           (test-end "control"))))))

(testing-registry-case
 'test-error-passes-on-raised-condition '(portable stdlib)
 ("stdlib-testing-test.scm" 61)
(test-equal 'test-error-passes-on-raised-condition
             '(1 0 0 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "errors" 1)
           (test-error "raises" (error "expected failure"))
           (test-end "errors"))))))

(testing-registry-case
 'test-result-properties '(portable stdlib)
 ("stdlib-testing-test.scm" 73)
(test-equal 'test-result-properties
             '("named" (x y) (x y) pass)
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
                 (cdr (assq 'result-kind result)))))))

(testing-registry-case
 'group-paths '(portable stdlib)
 ("stdlib-testing-test.scm" 95)
(test-equal 'group-paths
             '((("outer" "inner") "leaf"))
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
         (reverse paths))))

(testing-registry-case
 'approximate-and-passed-predicate '(portable stdlib)
 ("stdlib-testing-test.scm" 115)
(test-equal 'approximate-and-passed-predicate
             '((1 0 0 0 0) #t pass)
             (let ((runner
              (with-null-runner
               (lambda (runner)
                 (test-begin "approximate")
                 (test-approximate "near" 1.0 1.0001 0.001)
                 (test-end "approximate")))))
         (list (runner-counts runner)
               (test-passed? runner)
               (test-result-kind runner)))))

(testing-registry-case
 'read-eval-string-uses-scheme-base '(portable stdlib)
 ("stdlib-testing-test.scm" 130)
(test-equal 'read-eval-string-uses-scheme-base
             '(42 #f)
             (list (test-read-eval-string "(let ((x 20)) (+ x 22))")
             test-log-to-file)))

(testing-registry-case
 'fresh-runner-initializes-auxiliary-value '(portable stdlib)
 ("stdlib-testing-test.scm" 138)
(test-equal 'fresh-runner-initializes-auxiliary-value
             '(#f #f)
             (list (test-runner-aux-value (test-runner-null))
             (test-runner-aux-value (test-runner-simple)))))

(testing-registry-case
 'test-apply-selects-and-restores '(portable stdlib)
 ("stdlib-testing-test.scm" 146)
(test-equal 'test-apply-selects-and-restores
             '(2 0 0 0 1)
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
           (test-end "apply"))))))

(testing-registry-case
 'group-cleanup-normal-and-error-exits '(portable stdlib)
 ("stdlib-testing-test.scm" 164)
(test-equal 'group-cleanup-normal-and-error-exits
             '(body cleanup error-cleanup caught)
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
         (reverse events))))

(testing-registry-case
 'bad-count-and-end-name-callbacks '(portable stdlib)
 ("stdlib-testing-test.scm" 185)
(test-equal 'bad-count-and-end-name-callbacks
             '((name "different" "counted") (count 1 2))
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
         (reverse events))))

(testing-registry-case
 'runner-factory-current-and-reset '(portable stdlib)
 ("stdlib-testing-test.scm" 206)
(test-equal 'runner-factory-current-and-reset
             '(#t #t (1 0 0 0 0) (0 0 0 0 0) ())
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
               (test-runner-current saved-current))))))

(testing-registry-case
 'result-property-mutation '(portable stdlib)
 ("stdlib-testing-test.scm" 234)
(test-equal 'result-property-mutation
             '(41 42 missing cleared)
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
                     (test-result-ref runner 'again 'cleared))))))))

(testing-registry-case
 'manifest-reports-upstream-meta-suite '(portable stdlib)
 ("stdlib-testing-test.scm" 254)
(test-equal 'manifest-reports-upstream-meta-suite
             #t
             (let* ((entry (stdlib-manifest-ref '(stdlib testing)))
              (verification (assq 'verification (cdr entry)))
              (status (and verification
                           (assq 'test-status (cadr verification)))))
         (and status (memq 'upstream-meta-suite (cadr status)) #t))))

(testing-runner-main "Stdlib Testing portable tests" (command-line))
