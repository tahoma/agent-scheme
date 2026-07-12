;;; Portable SRFI 252 property-testing stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme complex)
        (scheme write)
        (stdlib testing)
        (stdlib generator)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing))

;; Number of failed SRFI 252 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed SRFI 252 check."
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
  "Record failure unless VALUE is true."
  (if (not value)
      (record-failure name #t value)))

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

(define (finish-property-testing-tests)
  "Report the SRFI 252 property-testing result."
  (if (= failures 0)
      (begin
        (display "SRFI 252 property-testing tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 252 property-testing test failure(s)")
        (newline)
        (error "SRFI 252 property-testing tests failed" failures))))

(check 'property-test-pass-counts
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "passing-properties" 5)
           (test-property integer? (list (exact-integer-generator)) 5)
           (test-end "passing-properties"))))
       '(5 0 0 0 0))

(check 'property-result-metadata
       (let ((properties '()))
         (with-null-runner
          (lambda (runner)
            (test-runner-on-test-end!
             runner
             (lambda (active)
               (set! properties
                     (cons (test-result-alist active) properties))))
            (test-begin "metadata" 3)
            (test-property
             (lambda (flag number)
               (and (boolean? flag) (integer? number)))
             (list (boolean-generator) (exact-integer-generator))
             3)
            (test-end "metadata")))
         (list
          (map (lambda (entry)
                 (cdr (assq 'property-test-iteration entry)))
               properties)
          (map (lambda (entry)
                 (cdr (assq 'property-test-iterations entry)))
               properties)
          (map (lambda (entry)
                 (length (cdr (assq 'property-test-arguments entry))))
               properties)))
       '((3 2 1) (3 3 3) (2 2 2)))

(check 'property-expect-fail-counts
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "expected-failures" 4)
           (test-property-expect-fail
            (lambda (value) (not (boolean? value)))
            (list (boolean-generator))
            4)
           (test-end "expected-failures"))))
       '(0 0 4 0 0))

(check 'property-skip-counts
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "skipped-properties" 4)
           (test-property-skip
            (lambda (value) value)
            (list (gmap (lambda (value)
                          (error "skipped generator should not run" value))
                        (boolean-generator)))
            4)
           (test-end "skipped-properties"))))
       '(0 0 0 0 4))

(check 'property-error-counts
       (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "error-properties" 3)
           (test-property-error
            (lambda (value) (error "expected property error" value))
            (list (integer-generator))
            3)
           (test-end "error-properties"))))
       '(3 0 0 0 0))

(check 'property-test-runner-is-srfi-64-runner
       (test-runner? (property-test-runner))
       #t)

(check 'pair-generator-of-uses-both-generators
       (let ((pairs (pair-generator-of (generator 'a 'b 'c)
                                       (generator 1 2 3))))
         (list (pairs) (pairs) (pairs)))
       '((a . 1) (b . 2) (c . 3)))

(check-true 'basic-generators-produce-expected-types
            (let ((bytes ((bytevector-generator)))
                  (char ((char-generator)))
                  (string ((string-generator)))
                  (symbol ((symbol-generator))))
              (and (bytevector? bytes)
                   (char? char)
                   (string? string)
                   (symbol? symbol))))

(check-true 'collection-generators-obey-explicit-bounds
            (let* ((lists (list-generator-of (circular-generator 'x) 4))
                   (vectors (vector-generator-of (circular-generator 'x) 4))
                   (empty-list (lists))
                   (sample-list (lists))
                   (empty-vector (vectors))
                   (sample-vector (vectors)))
              (and (null? empty-list)
                   (< (length sample-list) 4)
                   (= (vector-length empty-vector) 0)
                   (< (vector-length sample-vector) 4))))

(check 'procedure-generator-of-values
       (let ((procedures (procedure-generator-of (generator 'first 'second))))
         (list ((procedures)) ((procedures) 'ignored)))
       '(first second))

(check 'deterministic-random-source-replays-generated-numbers
       (let ((left
              (parameterize ((current-random-source (make-random-source)))
                (generator->list (gdrop (exact-number-generator) 30) 8)))
             (right
              (parameterize ((current-random-source (make-random-source)))
                (generator->list (gdrop (exact-number-generator) 30) 8))))
         (equal? left right))
       #t)

(check-true 'numeric-generators-produce-representative-values
            (let ((values (list ((exact-integer-generator))
                                ((exact-rational-generator))
                                ((exact-real-generator))
                                ((inexact-integer-generator))
                                ((inexact-real-generator))
                                ((complex-generator))
                                ((number-generator))
                                ((rational-generator))
                                ((real-generator)))))
              (and (integer? (list-ref values 0))
                   (rational? (list-ref values 1))
                   (real? (list-ref values 2))
                   (integer? (list-ref values 3))
                   (real? (list-ref values 4))
                   (complex? (list-ref values 5))
                   (number? (list-ref values 6))
                   (rational? (list-ref values 7))
                   (real? (list-ref values 8)))))

(finish-property-testing-tests)
