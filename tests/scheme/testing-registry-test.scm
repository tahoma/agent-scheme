;;; Portable testing registry tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme cxr)
        (testing manifest)
        (testing harness)
        (testing registry)
        (stdlib testing))

(testing-registry-clear!)

(testing-registry-case 'alpha '(fast unit) ("registry-test.scm" 12)
  (test-equal "alpha value" 4 (+ 2 2)))

(testing-registry-case 'beta '(slow integration) ("registry-test.scm" 15)
  (test-assert "beta value" #t))

(testing-registry-case 'gamma '(fast integration) ("registry-test.scm" 18)
  (test-equal "gamma value" '(a b) (list 'a 'b)))

;; Deterministic clock values make per-case timing portable and testable.
(define ticks '(10 13 20 27))

(define (next-tick)
  "Return and consume the next deterministic clock tick."
  (let ((tick (car ticks)))
    (set! ticks (cdr ticks))
    tick))

;; Report from the selected registered cases.
(define report
  (parameterize
      ((testing-registry-clock next-tick))
    (testing-registry-run-registered
     "registered fast cases"
     (testing-registry-select-tag 'fast))))

;; Case-level records extracted from REPORT.
(define case-results (cadr (assq 'cases (cdr report))))

(testing-harness-run "Testing registry"
  (test-equal "registration order"
              '(alpha beta gamma)
              (map testing-registry-case-name testing-registry-cases))
  (test-equal "tag selection and durations"
              '((alpha 3 pass) (gamma 7 pass))
              (map
               (lambda (result)
                 (list (cadr (assq 'name (cdr result)))
                       (cadr (assq 'duration (cdr result)))
                       (cadr (assq 'status (cdr result)))))
               case-results))
  (test-equal "source metadata"
              '("registry-test.scm" 12)
              (list
               (cadr (assq 'source-file (cdr (car case-results))))
               (cadr (assq 'source-line (cdr (car case-results))))))
  (test-equal "name selector"
              '(beta)
              (map testing-registry-case-name
                   (let ((selector (testing-registry-select-name 'beta)))
                     (let loop ((rest testing-registry-cases))
                       (cond
                        ((null? rest) '())
                        ((selector (car rest))
                         (cons (car rest) (loop (cdr rest))))
                        (else (loop (cdr rest))))))))
  (let ((gamma (caddr testing-registry-cases))
        (integration? (testing-registry-select-tag 'integration))
        (slow? (testing-registry-select-tag 'slow)))
    (test-equal "selector primitives"
                '(#t #f #t)
                (list (integration? gamma)
                      (slow? gamma)
                      ((testing-registry-select-not slow?) gamma)))
    (test-assert "selector composition"
                 ((testing-registry-select-and
                   integration?
                   (testing-registry-select-not slow?))
                  gamma)))
  (test-equal
   "failed-name extraction"
   '(broken)
   (testing-registry-report-failed-names
    '(testing-registry-report
      (summary ignored)
      (cases
       ((testing-registry-case-result (name ok) (status pass))
        (testing-registry-case-result (name broken) (status fail)))))))
  (test-assert
   "registry is publicly manifested"
   (testing-library-manifest-ref '(testing registry))))

;; Diagnostic captured by the host hook for a raised registered case.
(define captured-diagnostic #f)

(testing-registry-case 'broken '(fast failure) ("registry-test.scm" 90)
  (error "expected registry failure"))

;; A batch failure remains inspectable by an embedding test or interactive host.
(define registered-failure-report
  (parameterize
      ((testing-registry-diagnostic-hook
        (lambda (case condition)
          (set! captured-diagnostic
                (list (testing-registry-case-name case)
                      (if condition 'condition 'missing-condition))))))
    (testing-registry-run-registered
     "registered diagnostic case"
     (testing-registry-select-name 'broken))))

(testing-harness-run "Testing registry diagnostics"
  (test-assert "registered failures remain inspectable"
               (testing-registry-report-failed? registered-failure-report))
  (test-equal "host diagnostic hook receives case and condition"
              '(broken condition)
              captured-diagnostic))
