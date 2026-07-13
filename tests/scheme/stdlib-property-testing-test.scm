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
        (stdlib property-testing)
        (scheme process-context)
        (testing registry)
        (testing runner))

(define (all? predicate values)
  "Return #t when PREDICATE accepts every item in VALUES."
  (cond
   ((null? values) #t)
   ((predicate (car values)) (all? predicate (cdr values)))
   (else #f)))

(define (generated-sample generator count)
  "Return COUNT values from GENERATOR."
  (generator->list generator count))

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
 'property-test-pass-counts '(portable stdlib)
(test-equal 'property-test-pass-counts
             '(5 0 0 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "passing-properties" 5)
           (test-property integer? (list (exact-integer-generator)) 5)
           (test-end "passing-properties"))))))

(testing-registry-case
 'property-result-metadata '(portable stdlib)
(test-equal 'property-result-metadata
             '((3 2 1) (3 3 3) (2 2 2))
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
               properties)))))

(testing-registry-case
 'property-expect-fail-counts '(portable stdlib)
(test-equal 'property-expect-fail-counts
             '(0 0 4 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "expected-failures" 4)
           (test-property-expect-fail
            (lambda (value) (not (boolean? value)))
            (list (boolean-generator))
            4)
           (test-end "expected-failures"))))))

(testing-registry-case
 'property-skip-counts '(portable stdlib)
(test-equal 'property-skip-counts
             '(0 0 0 0 4)
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
           (test-end "skipped-properties"))))))

(testing-registry-case
 'property-error-counts '(portable stdlib)
(test-equal 'property-error-counts
             '(3 0 0 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "error-properties" 3)
           (test-property-error
            (lambda (value) (error "expected property error" value))
            (list (integer-generator))
            3)
           (test-end "error-properties"))))))

(testing-registry-case
 'property-test-failure-counts '(portable stdlib)
(test-equal 'property-test-failure-counts
             '(0 3 0 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "failing-properties" 3)
           (test-property
            (lambda (value)
              value
              #f)
            (list (boolean-generator))
            3)
           (test-end "failing-properties"))))))

(testing-registry-case
 'property-expect-fail-xpass-counts '(portable stdlib)
(test-equal 'property-expect-fail-xpass-counts
             '(0 0 0 2 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "unexpected-passes" 2)
           (test-property-expect-fail boolean? (list (boolean-generator)) 2)
           (test-end "unexpected-passes"))))))

(testing-registry-case
 'property-error-missing-error-counts '(portable stdlib)
(test-equal 'property-error-missing-error-counts
             '(0 2 0 0 0)
             (runner-counts
        (with-null-runner
         (lambda (runner)
           (test-begin "missing-errors" 2)
           (test-property-error
            (lambda (value) value)
            (list (boolean-generator))
            2)
           (test-end "missing-errors"))))))

(testing-registry-case
 'property-error-type-records-expected-error '(portable stdlib)
(test-equal 'property-error-type-records-expected-error
             '(expected-error-kind expected-error-kind)
             (let ((properties '()))
         (with-null-runner
          (lambda (runner)
            (test-runner-on-test-end!
             runner
             (lambda (active)
               (set! properties
                     (cons (test-result-alist active) properties))))
            (test-begin "typed-errors" 2)
            (test-property-error-type
             'expected-error-kind
             (lambda (value) (error "expected typed property error" value))
             (list (integer-generator))
             2)
            (test-end "typed-errors")))
         (map (lambda (entry)
                (cdr (assq 'expected-error entry)))
              properties))))

(testing-registry-case
 'property-test-runner-is-srfi-64-runner '(portable stdlib)
(test-equal 'property-test-runner-is-srfi-64-runner
             #t
             (test-runner? (property-test-runner))))

(testing-registry-case
 'pair-generator-of-uses-both-generators '(portable stdlib)
(test-equal 'pair-generator-of-uses-both-generators
             '((a . 1) (b . 2) (c . 3))
             (let ((pairs (pair-generator-of (generator 'a 'b 'c)
                                       (generator 1 2 3))))
         (list (pairs) (pairs) (pairs)))))

(testing-registry-case
 'basic-generators-produce-expected-types '(portable stdlib)
(test-assert 'basic-generators-produce-expected-types
             (let ((bytes ((bytevector-generator)))
                  (char ((char-generator)))
                  (string ((string-generator)))
                  (symbol ((symbol-generator))))
              (and (bytevector? bytes)
                   (char? char)
                   (string? string)
                   (symbol? symbol)))))

(testing-registry-case
 'collection-generators-obey-explicit-bounds '(portable stdlib)
(test-assert 'collection-generators-obey-explicit-bounds
             (let* ((lists (list-generator-of (circular-generator 'x) 4))
                   (vectors (vector-generator-of (circular-generator 'x) 4))
                   (list-samples (generated-sample lists 12))
                   (vector-samples (generated-sample vectors 12)))
              (and (null? (car list-samples))
                   (all? (lambda (sample) (< (length sample) 4))
                         list-samples)
                   (= (vector-length (car vector-samples)) 0)
                   (all? (lambda (sample) (< (vector-length sample) 4))
                         vector-samples)))))

(testing-registry-case
 'procedure-generator-of-values '(portable stdlib)
(test-equal 'procedure-generator-of-values
             '(first second)
             (let ((procedures (procedure-generator-of (generator 'first 'second))))
         (list ((procedures)) ((procedures) 'ignored)))))

(testing-registry-case
 'deterministic-random-source-replays-generated-numbers '(portable stdlib)
(test-equal 'deterministic-random-source-replays-generated-numbers
             #t
             (let ((left
              (parameterize ((current-random-source (make-random-source)))
                (generated-sample (gdrop (exact-number-generator) 30) 8)))
             (right
              (parameterize ((current-random-source (make-random-source)))
                (generated-sample (gdrop (exact-number-generator) 30) 8))))
         (equal? left right))))

(testing-registry-case
 'independent-random-generators-diverge-after-special-prefix '(portable stdlib)
(test-equal 'independent-random-generators-diverge-after-special-prefix
             #t
             (let ((left (gdrop (exact-number-generator) 30))
             (right (gdrop (exact-number-generator) 30)))
         (not (equal? (generated-sample left 8)
                      (generated-sample right 8))))))

(testing-registry-case
 'exact-integer-generator-special-prefix '(portable stdlib)
(test-equal 'exact-integer-generator-special-prefix
             '(0 1 -1)
             (generated-sample (exact-integer-generator) 3)))

(testing-registry-case
 'char-generator-skips-surrogate-code-points '(portable stdlib)
(test-assert 'char-generator-skips-surrogate-code-points
             (all? (lambda (char)
                    (let ((scalar (char->integer char)))
                      (or (< scalar #xd800) (> scalar #xdfff))))
                  (generated-sample (char-generator) 64))))

(testing-registry-case
 'basic-generators-obey-size-bounds '(portable stdlib)
(test-assert 'basic-generators-obey-size-bounds
             (let ((bytevectors (generated-sample (bytevector-generator) 16))
                  (strings (generated-sample (string-generator) 16))
                  (symbols (generated-sample (symbol-generator) 16)))
              (and (all? (lambda (value) (<= (bytevector-length value) 1001))
                         bytevectors)
                   (all? (lambda (value) (<= (string-length value) 1001))
                         strings)
                   (all? (lambda (value)
                           (<= (string-length (symbol->string value)) 1001))
                         symbols)))))

(testing-registry-case
 'numeric-generators-produce-representative-values '(portable stdlib)
(test-assert 'numeric-generators-produce-representative-values
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
                   (real? (list-ref values 8))))))

(testing-runner-main "Stdlib Property Testing portable tests" (command-line))
