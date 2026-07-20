;;; Portable owned numeric backend tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent numeric)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (numeric backend operation . arguments)
  "Apply numeric backend OPERATION to ARGUMENTS."
  (apply consent-numeric backend operation arguments))

(define (integer backend text)
  "Parse decimal owned integer TEXT under BACKEND."
  (numeric backend 'integer-parse text 10))

(define (integer-text backend value)
  "Render owned integer VALUE as decimal text."
  (numeric backend 'integer->string value 10))

(define (raises? thunk)
  "Report whether THUNK raises an exception."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (check-grid-result backend label expected actual left right)
  "Require owned ACTUAL to match host-small EXPECTED for a grid operation."
  (let ((actual-text (integer-text backend actual))
        (expected-text (number->string expected)))
    (if (not (string=? actual-text expected-text))
        (error "small integer grid mismatch"
               label left right expected-text actual-text))))

(define (check-small-integer-grid limb-bits)
  "Cross-check small exact operations under the LIMB-BITS profile."
  (let ((backend (consent-make-numeric-backend limb-bits)))
    (let left-loop ((left -20))
      (if (<= left 20)
          (let ((owned-left (integer backend (number->string left))))
            (let right-loop ((right -20))
              (if (<= right 20)
                  (let* ((owned-right
                          (integer backend (number->string right)))
                         (truncated-quotient
                          (and (not (= right 0))
                               (quotient left right)))
                         (truncated-remainder
                          (and (not (= right 0))
                               (remainder left right)))
                         (floor-quotient
                          (and
                           truncated-quotient
                           (if (and (not (= truncated-remainder 0))
                                    (or (and (< left 0) (> right 0))
                                        (and (> left 0) (< right 0))))
                               (- truncated-quotient 1)
                               truncated-quotient)))
                         (floor-remainder
                          (and floor-quotient
                               (- left (* floor-quotient right)))))
                    (check-grid-result
                     backend 'add (+ left right)
                     (numeric backend 'integer-add owned-left owned-right)
                     left right)
                    (check-grid-result
                     backend 'subtract (- left right)
                     (numeric backend 'integer-subtract owned-left owned-right)
                     left right)
                    (check-grid-result
                     backend 'multiply (* left right)
                     (numeric backend 'integer-multiply owned-left owned-right)
                     left right)
                    (if truncated-quotient
                        (let ((truncated
                               (numeric
                                backend
                                'integer-divmod-truncate
                                owned-left
                                owned-right))
                              (floored
                               (numeric
                                backend
                                'integer-divmod-floor
                                owned-left
                                owned-right)))
                          (check-grid-result
                           backend 'truncate-quotient truncated-quotient
                           (car truncated) left right)
                          (check-grid-result
                           backend 'truncate-remainder truncated-remainder
                           (cdr truncated) left right)
                          (check-grid-result
                           backend 'floor-quotient floor-quotient
                           (car floored) left right)
                          (check-grid-result
                           backend 'floor-remainder floor-remainder
                           (cdr floored) left right)))
                    (right-loop (+ right 1)))))
            (left-loop (+ left 1)))))
    #t))

(define (check-profile limb-bits)
  "Exercise exact arithmetic boundaries for LIMB-BITS."
  (let* ((backend (consent-make-numeric-backend limb-bits))
         (base-text
          (cond
           ((= limb-bits 14) "16384")
           ((= limb-bits 30) "1073741824")
           ((= limb-bits 62) "4611686018427387904")
           (else (error "unsupported test profile" limb-bits))))
         (base (integer backend base-text))
         (one (integer backend "1"))
         (base-minus-one (numeric backend 'integer-subtract base one))
         (base-plus-one (numeric backend 'integer-add base one))
         (base-squared (numeric backend 'integer-multiply base base))
         (base-squared-minus-one
          (numeric backend 'integer-subtract base-squared one))
         (division
          (numeric backend
                   'integer-divmod-truncate
                   base-squared-minus-one
                   base-plus-one))
         (corrected-division
          (numeric
           backend
           'integer-divmod-truncate
           (numeric
            backend
            'integer-add
            (numeric backend 'integer-add base-squared base)
            one)
           base-plus-one)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-width"))
     limb-bits
     (consent-numeric-backend-limb-bits backend))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-carry"))
     base-text
     (integer-text
      backend
      (numeric backend 'integer-add base-minus-one one)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-borrow"))
     (integer-text backend base-minus-one)
     (integer-text
      backend
      (numeric backend 'integer-subtract base one)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-square"))
     (cond
      ((= limb-bits 14) "268435456")
      ((= limb-bits 30) "1152921504606846976")
      (else "21267647932558653966460912964485513216"))
     (integer-text backend base-squared))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-base-plus-one"))
     (cond
      ((= limb-bits 14) "16385")
      ((= limb-bits 30) "1073741825")
      (else "4611686018427387905"))
     (integer-text backend base-plus-one))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-square-minus-one"))
     (cond
      ((= limb-bits 14) "268435455")
      ((= limb-bits 30) "1152921504606846975")
      (else "21267647932558653966460912964485513215"))
     (integer-text backend base-squared-minus-one))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-division"))
     (integer-text backend base-minus-one)
     (integer-text backend (car division)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits) "-remainder"))
     "0"
     (integer-text backend (cdr division)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-quotient-correction"))
     base-text
     (integer-text backend (car corrected-division)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-quotient-correction-remainder"))
     "1"
     (integer-text backend (cdr corrected-division)))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-negative-zero-normalization"))
     "0"
     (integer-text backend (integer backend "-0")))))

(testing-registry-case
 'parameterized-limb-boundaries '(portable runtime numeric)
(begin
  (check-profile 14)
  (check-profile 30)
  (check-profile 62)
  (test-assert
   'profile-rejects-zero-width
   (raises? (lambda () (consent-make-numeric-backend 0))))
  (test-assert
   'profile-rejects-inexact-width
   (raises? (lambda () (consent-make-numeric-backend 30.0))))))

(testing-registry-case
 'small-integer-operation-grid '(portable runtime numeric)
(begin
  (test-assert 'small-grid-14 (check-small-integer-grid 14))
  (test-assert 'small-grid-30 (check-small-integer-grid 30))
  (test-assert 'small-grid-62 (check-small-integer-grid 62))))

(testing-registry-case
 'owned-large-exact-arithmetic '(portable runtime numeric)
(let* ((backend consent-default-numeric-backend)
       (two (integer backend "2"))
       (power
        (numeric backend
                 'integer-power
                 two
                 (integer backend "256")))
       (root
        (numeric backend
                 'integer-square-root
                 (numeric backend 'integer-multiply power power)))
       (ratio
        (numeric backend
                 'rational-normalize
                 (numeric backend
                          'integer-multiply
                          (integer backend "21")
                          power)
                 (numeric backend
                          'integer-multiply
                          (integer backend "35")
                          power)))
       (truncate-negative
        (numeric backend
                 'integer-divmod-truncate
                 (integer backend "-7")
                 (integer backend "3")))
       (floor-negative
        (numeric backend
                 'integer-divmod-floor
                 (integer backend "-7")
                 (integer backend "3")))
       (rational-sum
        (numeric
         backend
         'rational-add
         (numeric backend
                  'rational-normalize
                  (integer backend "1")
                  (integer backend "6"))
         (numeric backend
                  'rational-normalize
                  (integer backend "1")
                  (integer backend "3"))))
       (rational-product
        (numeric
         backend
         'rational-multiply
         (numeric backend
                  'rational-normalize
                  (integer backend "21")
                  (integer backend "35"))
         (numeric backend
                  'rational-normalize
                  (integer backend "10")
                  (integer backend "9")))))
  (test-equal
   'two-to-256
   "115792089237316195423570985008687907853269984665640564039457584007913129639936"
   (integer-text backend power))
  (test-equal 'large-square-root
              (integer-text backend power)
              (integer-text backend (car root)))
  (test-equal 'large-square-root-remainder
              "0"
              (integer-text backend (cdr root)))
  (test-equal 'large-rational-numerator
              "3"
              (integer-text backend (car ratio)))
  (test-equal 'large-rational-denominator
              "5"
              (integer-text backend (cdr ratio)))
  (test-equal 'truncate-negative-quotient
              "-2"
              (integer-text backend (car truncate-negative)))
  (test-equal 'truncate-negative-remainder
              "-1"
              (integer-text backend (cdr truncate-negative)))
  (test-equal 'floor-negative-quotient
              "-3"
              (integer-text backend (car floor-negative)))
  (test-equal 'floor-negative-remainder
              "2"
              (integer-text backend (cdr floor-negative)))
  (test-equal 'rational-add-numerator
              "1"
              (integer-text backend (car rational-sum)))
  (test-equal 'rational-add-denominator
              "2"
              (integer-text backend (cdr rational-sum)))
  (test-equal 'rational-cross-cancel-numerator
              "2"
              (integer-text backend (car rational-product)))
  (test-equal 'rational-cross-cancel-denominator
              "3"
              (integer-text backend (cdr rational-product)))))

(testing-registry-case
 'owned-binary64-core '(portable runtime numeric)
(let* ((backend consent-default-numeric-backend)
       (one (integer backend "1"))
       (ten (integer backend "10"))
       (one-tenth
        (numeric backend 'rational-normalize one ten))
       (value
        (numeric backend 'binary64-from-rational one-tenth))
       (sum
        (numeric backend 'binary64-binary value value '+))
       (product
        (numeric backend 'binary64-binary value value '*))
       (quotient-value
        (numeric backend 'binary64-binary value value '/))
       (tiny
        (numeric backend
                 'binary64-from-rational
                 (numeric backend
                          'rational-normalize
                          one
                          (numeric backend
                                   'integer-shift-left
                                   one
                                   1074))))
       (two-to-53
        (numeric backend 'integer-shift-left one 53))
       (tie-even-down
        (numeric
         backend
         'binary64-from-rational
         (numeric
          backend
          'rational-normalize
          (numeric backend
                   'integer-add
                   two-to-53
                   one)
          two-to-53)))
       (tie-even-up
        (numeric
         backend
         'binary64-from-rational
         (numeric
          backend
          'rational-normalize
          (numeric
           backend
           'integer-add
           two-to-53
           (integer backend "3"))
          two-to-53)))
       (max-finite
        (numeric backend
                 'binary64-parse
                 "1.7976931348623157e308"))
       (min-normal
        (numeric backend
                 'binary64-parse
                 "2.2250738585072014e-308"))
       (overflow
        (numeric backend
                 'binary64-parse
                 "1.7976931348623159e308"))
       (imported
        (numeric backend 'binary64-import-host 0.1))
       (positive-infinity
        (numeric backend 'binary64-special 'infinity 1))
       (invalid-product
        (numeric
         backend
         'binary64-binary
         (numeric backend 'binary64-zero)
         positive-infinity
         '*)))
  (test-equal 'binary64-one-tenth "0.1"
              (numeric backend 'binary64->string value))
  (test-equal 'binary64-addition "0.2"
              (numeric backend 'binary64->string sum))
  (test-equal 'binary64-multiplication "0.010000000000000002"
              (numeric backend 'binary64->string product))
  (test-equal 'binary64-division "1.0"
              (numeric backend 'binary64->string quotient-value))
  (test-equal 'binary64-order
              -1
              (numeric backend 'binary64-compare value sum))
  (test-equal 'binary64-smallest-subnormal "5e-324"
              (numeric backend 'binary64->string tiny))
  (test-equal 'binary64-ties-even-down "1.0"
              (numeric backend 'binary64->string tie-even-down))
  (test-equal 'binary64-ties-even-up "1.0000000000000004"
              (numeric backend 'binary64->string tie-even-up))
  (test-equal 'binary64-max-finite "1.7976931348623157e+308"
              (numeric backend 'binary64->string max-finite))
  (test-equal 'binary64-min-normal "2.2250738585072014e-308"
              (numeric backend 'binary64->string min-normal))
  (test-equal 'binary64-decimal-overflow
              'infinity
              (numeric backend 'binary64-class overflow))
  (test-assert 'binary64-host-decode
               (numeric backend 'binary64-equal? value imported))
  (test-equal 'binary64-host-cache 0.1
              (numeric backend 'binary64->host imported))
  (test-equal 'binary64-invalid-product
              'nan
              (numeric backend 'binary64-class invalid-product))
  (test-equal 'binary64-overflow-class
              'infinity
              (numeric
               backend
               'binary64-class
               (numeric backend
                        'binary64-from-rational
                        (cons
                         (numeric backend
                                  'integer-shift-left
                                  one
                                  1024)
                         one))))))

(testing-runner-main "Consent owned numeric backend" (command-line))
