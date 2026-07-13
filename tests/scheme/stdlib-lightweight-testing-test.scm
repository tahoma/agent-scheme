;;; Portable SRFI 78 lightweight testing stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (stdlib eager-comprehensions)
        (stdlib lightweight-testing)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (capture-output thunk)
  "Return the text THUNK writes to the current output port."
  (let ((port (open-output-string)))
    (parameterize ((current-output-port port))
      (thunk))
    (get-output-string port)))

(define (run-checks thunk expected-count)
  "Run SRFI 78 checks in THUNK and report whether EXPECTED-COUNT passed."
  (check-reset!)
  (check-set-mode! 'summary)
  (thunk)
  (check-passed? expected-count))

(testing-registry-case
 'simple-check-passes '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 28)
 (test-assert 'simple-check-passes
              (run-checks (lambda () (check (+ 1 1) => 2)) 1)))

(testing-registry-case
 'simple-check-fails '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 34)
 (test-assert 'simple-check-fails
              (not (run-checks (lambda () (check (+ 1 1) => 3)) 1))))

(testing-registry-case
 'default-equality-is-equal '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 40)
 (test-assert 'default-equality-is-equal
              (run-checks
               (lambda () (check (vector 1) => (vector 1))) 1)))

(testing-registry-case
 'custom-equality-predicate '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 47)
 (test-assert 'custom-equality-predicate
              (not (run-checks
                    (lambda () (check (vector 1) (=> eq?) (vector 1))) 1))))

(testing-registry-case
 'check-ec-passing-comprehension '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 54)
 (test-assert 'check-ec-passing-comprehension
              (run-checks
               (lambda () (check-ec (:range i 5) (< i 5) => #t (i))) 1)))

(testing-registry-case
 'check-ec-stops-on-first-failure '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 61)
 (test-assert 'check-ec-stops-on-first-failure
              (not (run-checks
                    (lambda ()
                      (check-ec (:range i 5) (< i 3) => #t (i))) 1))))

(testing-registry-case
 'check-ec-stops-evaluating-after-first-failure '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 69)
 (let ((evaluations 0))
   (run-checks
    (lambda ()
      (check-ec (:range i 100)
                (begin
                  (set! evaluations (+ evaluations 1))
                  (< i 3))
                => #t
                (i)))
    1)
   (test-equal 'check-ec-stops-evaluating-after-first-failure 4 evaluations)))

(testing-registry-case
 'off-mode-skips-expression '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 84)
 (let ((evaluated? #f))
   (check-reset!)
   (check-set-mode! 'off)
   (check (begin (set! evaluated? #t) evaluated?) => #t)
   (test-equal 'off-mode-skips-expression '(#f #t)
               (list evaluated? (check-passed? 0)))))

(testing-registry-case
 'report-mode-success-output '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 94)
 (test-equal 'report-mode-success-output
             "\n(+ 1 1) => 2 ; correct\n"
             (capture-output
              (lambda ()
                (check-reset!)
                (check-set-mode! 'report)
                (check (+ 1 1) => 2)))))

(testing-registry-case
 'report-failed-output '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 105)
 (test-equal 'report-failed-output
             "\n(+ 1 1) => 2 ; *** failed ***\n ; expected result: 3\n"
             (capture-output
              (lambda ()
                (check-reset!)
                (check-set-mode! 'report-failed)
                (check (+ 1 1) => 3)))))

(testing-registry-case
 'summary-report-output '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 116)
 (test-equal 'summary-report-output
             "\n; *** checks *** : 1 correct, 0 failed.\n"
             (capture-output
              (lambda ()
                (check-reset!)
                (check-set-mode! 'summary)
                (check (+ 1 1) => 2)
                (check-report)))))

(testing-registry-case
 'report-failed-summary-includes-first-failure '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 128)
 (test-equal
  'report-failed-summary-includes-first-failure
  (string-append
   "\n(+ 1 1) => 2 ; *** failed ***\n"
   " ; expected result: 3\n"
   "\n; *** checks *** : 0 correct, 1 failed. First failed example:\n"
   "\n(+ 1 1) => 2 ; *** failed ***\n"
   " ; expected result: 3\n")
  (capture-output
   (lambda ()
     (check-reset!)
     (check-set-mode! 'report-failed)
     (check (+ 1 1) => 3)
     (check-report)))))

(testing-registry-case
 'check-ec-failure-report-includes-bindings '(portable stdlib testing)
 ("stdlib-lightweight-testing-test.scm" 146)
 (test-equal
  'check-ec-failure-report-includes-bindings
  "\n(let ((i 3)) (< i 3)) => #f ; *** failed ***\n ; expected result: #t\n"
  (capture-output
   (lambda ()
     (check-reset!)
     (check-set-mode! 'report-failed)
     (check-ec (:range i 5) (< i 3) => #t (i))))))

(testing-runner-main "SRFI 78 lightweight testing" (command-line))
