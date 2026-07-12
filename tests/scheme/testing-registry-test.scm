;;; Portable testing registry tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme cxr)
        (testing manifest)
        (testing harness)
        (testing registry)
        (stdlib testing))

(consent-test-registry-clear!)

(consent-test-case 'alpha '(fast unit) ("registry-test.scm" 12)
  (test-equal "alpha value" 4 (+ 2 2)))

(consent-test-case 'beta '(slow integration) ("registry-test.scm" 15)
  (test-assert "beta value" #t))

(consent-test-case 'gamma '(fast integration) ("registry-test.scm" 18)
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
      ((consent-test-clock next-tick))
    (consent-test-run-registered
     "registered fast cases"
     (consent-test-select-tag 'fast))))

;; Case-level records extracted from REPORT.
(define case-results (cadr (assq 'cases (cdr report))))

(consent-test-run "Testing registry"
  (test-equal "registration order"
              '(alpha beta gamma)
              (map consent-test-case-name consent-test-registry))
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
              (map consent-test-case-name
                   (let ((selector (consent-test-select-name 'beta)))
                     (let loop ((rest consent-test-registry))
                       (cond
                        ((null? rest) '())
                        ((selector (car rest))
                         (cons (car rest) (loop (cdr rest))))
                        (else (loop (cdr rest))))))))
  (let ((gamma (caddr consent-test-registry))
        (integration? (consent-test-select-tag 'integration))
        (slow? (consent-test-select-tag 'slow)))
    (test-equal "selector primitives"
                '(#t #f #t)
                (list (integration? gamma)
                      (slow? gamma)
                      ((consent-test-select-not slow?) gamma)))
    (test-assert "selector composition"
                 ((consent-test-select-and
                   integration?
                   (consent-test-select-not slow?))
                  gamma)))
  (test-equal
   "failed-name extraction"
   '(broken)
   (consent-test-report-failed-names
    '(consent-test-report
      (summary ignored)
      (cases
       ((consent-test-case-result (name ok) (status pass))
        (consent-test-case-result (name broken) (status fail)))))))
  (test-assert
   "registry is publicly manifested"
   (testing-library-manifest-ref '(testing registry))))

;; Diagnostic captured by the host hook for a raised registered case.
(define captured-diagnostic #f)

(consent-test-case 'broken '(fast failure) ("registry-test.scm" 90)
  (error "expected registry failure"))

;; A batch failure remains catchable by an embedding test or interactive host.
(define registered-failure-raised?
  (guard (condition (else #t))
    (parameterize
        ((consent-test-diagnostic-hook
          (lambda (case condition)
            (set! captured-diagnostic
                  (list (consent-test-case-name case)
                        (if condition 'condition 'missing-condition))))))
      (consent-test-run-registered
       "registered diagnostic case"
       (consent-test-select-name 'broken)))
    #f))

(consent-test-run "Testing registry diagnostics"
  (test-assert "registered failures signal batch failure"
               registered-failure-raised?)
  (test-equal "host diagnostic hook receives case and condition"
              '(broken condition)
              captured-diagnostic))
