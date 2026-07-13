;;; Adapted upstream SRFI 252 property-testing tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2024 Antero Mejr <mail@antr.me>
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 252 `property-test-tests.scm` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-252.

(import (scheme base)
        (scheme complex)
        (scheme write)
        (stdlib list)
        (stdlib testing)
        (stdlib generator)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing)
        (scheme process-context)
        (testing registry)
        (testing runner))

;; Bounded property assertion count used by this adapted upstream fixture.
(define sample-count 6)

;; Upstream's explicit small run count for representative control forms.
(define explicit-upstream-count 10)

;; SRFI 252's default property assertion count.
(define default-count 100)

(define (runner-counts runner)
  "Return RUNNER pass, fail, xfail, xpass, and skip counts."
  (list (test-runner-pass-count runner)
        (test-runner-fail-count runner)
        (test-runner-xfail-count runner)
        (test-runner-xpass-count runner)
        (test-runner-skip-count runner)))

(define (three value)
  "Return 3 for VALUE."
  value
  3)

(define (wrong-three value)
  "Return VALUE instead of 3."
  value)

(define (three-property value)
  "Return #t when THREE returns 3 for VALUE."
  (= (three value) 3))

(define (wrong-three-property value)
  "Return #t when WRONG-THREE returns 3 for VALUE."
  (= (wrong-three value) 3))

(define (error-three-property value)
  "Raise an error for VALUE."
  (error "expected property error" value))

(define (bad-generator)
  "Return a generator that raises if it is forced."
  (gmap (lambda (value)
          (error "skipped generator should not run" value))
        (boolean-generator)))

;; Null runner that records the adapted upstream SRFI 252 checks.
(define adapted-runner (test-runner-null))

(testing-registry-case
 'stdlib-property-testing-upstream-case-1 '(portable stdlib)
(test-with-runner adapted-runner
  (test-begin "property-test-adapted-upstream")

  (test-property three-property (list (integer-generator)))
  (test-property three-property (list (real-generator)))
  (test-property three-property (list (integer-generator))
                 explicit-upstream-count)
  (test-property three-property (list (integer-generator)) sample-count)
  (test-property three-property (list (real-generator)) sample-count)
  (test-property (lambda (flag number)
                   (and (boolean? flag) (integer? number)))
                 (list (boolean-generator) (integer-generator))
                 sample-count)

  (test-property-expect-fail wrong-three-property (list (integer-generator)))
  (test-property-expect-fail
   wrong-three-property
   (list (integer-generator))
   explicit-upstream-count)
  (test-property-expect-fail
   wrong-three-property
   (list (integer-generator))
   sample-count)
  (test-property-skip three-property (list (bad-generator)))
  (test-property-skip
   three-property
   (list (bad-generator))
   explicit-upstream-count)
  (test-property-skip three-property (list (bad-generator)) sample-count)
  (test-property-error error-three-property (list (integer-generator)))
  (test-property-error
   error-three-property
   (list (integer-generator))
   explicit-upstream-count)
  (test-property-error
   error-three-property
   (list (integer-generator))
   sample-count)

  (test-property boolean? (list (boolean-generator)) sample-count)
  (test-property bytevector? (list (bytevector-generator)) sample-count)
  (test-property char? (list (char-generator)) sample-count)
  (test-property string? (list (string-generator)) sample-count)
  (test-property symbol? (list (symbol-generator)) sample-count)

  (cond-expand
   (exact-complex
    (test-property
     (lambda (value)
       (and (complex? value)
            (exact? (real-part value))
            (exact? (imag-part value))))
     (list (exact-complex-generator))
     sample-count))
   (else))

  (test-property
   (lambda (value) (and (integer? value) (exact? value)))
   (list (exact-integer-generator))
   sample-count)
  (test-property exact? (list (exact-number-generator)) sample-count)
  (test-property
   (lambda (value) (and (exact? value) (rational? value)))
   (list (exact-rational-generator))
   sample-count)
  (test-property
   (lambda (value) (and (exact? value) (real? value)))
   (list (exact-real-generator))
   sample-count)

  (cond-expand
   (exact-complex
    (test-property
     (lambda (value)
       (and (complex? value)
            (exact? (real-part value))
            (exact? (imag-part value))
            (integer? (real-part value))
            (integer? (imag-part value))))
     (list (exact-integer-complex-generator))
     sample-count))
   (else))

  (test-property
   (lambda (value)
     (and (complex? value)
          (inexact? (real-part value))
          (inexact? (imag-part value))))
   (list (inexact-complex-generator))
   sample-count)
  (test-property
   (lambda (value) (and (inexact? value) (integer? value)))
   (list (inexact-integer-generator))
   sample-count)
  (test-property inexact? (list (inexact-number-generator)) sample-count)
  (test-property
   (lambda (value) (and (inexact? value) (rational? value)))
   (list (inexact-rational-generator))
   sample-count)
  (test-property
   (lambda (value) (and (inexact? value) (real? value)))
   (list (inexact-real-generator))
   sample-count)

  (test-property complex? (list (complex-generator)) sample-count)
  (test-property integer? (list (integer-generator)) sample-count)
  (test-property number? (list (number-generator)) sample-count)
  (test-property rational? (list (rational-generator)) sample-count)
  (test-property real? (list (real-generator)) sample-count)

  (test-property
   (lambda (value)
     (and (list? value)
          (<= (length value) 7)
          (every integer? value)))
   (list (list-generator-of (integer-generator) 8))
   sample-count)
  (test-property
   (lambda (value)
     (and (pair? value)
          (integer? (car value))
          (boolean? (cdr value))))
   (list (pair-generator-of (integer-generator) (boolean-generator)))
   sample-count)
  (test-property
   (lambda (value)
     (and (procedure? value) (integer? (value))))
   (list (procedure-generator-of (integer-generator)))
   sample-count)
  (test-property
   (lambda (value)
     (and (vector? value)
          (<= (vector-length value) 7)
          (every integer? (vector->list value))))
   (list (vector-generator-of (integer-generator) 8))
   sample-count)

  (test-end "property-test-adapted-upstream")))

(testing-registry-case
 'adapted-upstream-records-passing-tests '(portable stdlib)
(test-assert 'adapted-upstream-records-passing-tests
             (> (test-runner-pass-count adapted-runner) 0)))

(testing-registry-case
 'adapted-upstream-control-counts '(portable stdlib)
(test-equal 'adapted-upstream-control-counts
             (list 0
             (+ default-count explicit-upstream-count sample-count)
             (+ default-count explicit-upstream-count sample-count))
             (list (test-runner-fail-count adapted-runner)
             (test-runner-xfail-count adapted-runner)
             (test-runner-skip-count adapted-runner))))

(testing-registry-case
 'adapted-upstream-error-tests-pass '(portable stdlib)
(test-equal 'adapted-upstream-error-tests-pass
             2
             (test-runner-pass-count
        (let ((runner (test-runner-null)))
          (test-with-runner runner
            (test-begin "property-error-type" 2)
            (test-property-error-type
             #t
             error-three-property
             (list (integer-generator))
             2)
            (test-end "property-error-type"))
          runner))))

(testing-registry-case
 'adapted-upstream-determinism '(portable stdlib)
(test-equal 'adapted-upstream-determinism
             #t
             (let ((left
              (parameterize ((current-random-source (make-random-source)))
                (generator->list (gdrop (exact-number-generator) 30) 8)))
             (right
              (parameterize ((current-random-source (make-random-source)))
                (generator->list (gdrop (exact-number-generator) 30) 8))))
         (equal? left right))))

(testing-registry-case
 'adapted-upstream-non-determinism '(portable stdlib)
(test-equal 'adapted-upstream-non-determinism
             #t
             (let ((left (gdrop (exact-number-generator) 30))
             (right (gdrop (exact-number-generator) 30)))
         (not (equal? (generator->list left 8)
                      (generator->list right 8))))))

(testing-runner-main "Stdlib Property Testing Upstream portable tests" (command-line))
