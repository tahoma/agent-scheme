;;; Portable owned numeric backend tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme cxr)
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

(define (integer=? backend left right)
  "Report whether owned integers LEFT and RIGHT are equal."
  (= (numeric backend 'integer-compare left right) 0))

(define (low-bits-mask bit-count)
  "Return an exact host integer whose low BIT-COUNT bits are one."
  (let loop ((mask 0) (remaining bit-count))
    (if (= remaining 0)
        mask
        (loop (+ (* mask 2) 1) (- remaining 1)))))

(define (require-condition condition message detail)
  "Raise MESSAGE with DETAIL unless CONDITION is true."
  (if (not condition)
      (error message detail)))

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
         (fixnum-magnitude-bits (min (* limb-bits 2) 60))
         (fixnum-limit-host
          (low-bits-mask fixnum-magnitude-bits))
         (fixnum-limit-text (number->string fixnum-limit-host))
         (fixnum-limit (integer backend fixnum-limit-text))
         (fixnum-overflow
          (numeric backend 'integer-add fixnum-limit one))
         (negative-fixnum-limit
          (numeric backend 'integer-negate fixnum-limit))
         (negative-fixnum-overflow
          (numeric backend 'integer-negate fixnum-overflow))
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
      (string-append "profile-" (number->string limb-bits)
                     "-positive-fixnum-limit"))
     fixnum-limit-host
     (consent-numeric-backend-positive-fixnum-limit backend))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-positive-fixnum-boundary"))
     #t
     (numeric backend 'integer-fixnum? fixnum-limit))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-negative-fixnum-boundary"))
     #t
     (numeric backend 'integer-fixnum? negative-fixnum-limit))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-positive-promotion"))
     #f
     (numeric backend 'integer-fixnum? fixnum-overflow))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-negative-promotion"))
     #f
     (numeric backend 'integer-fixnum? negative-fixnum-overflow))
    (test-equal
     (string->symbol
      (string-append "profile-" (number->string limb-bits)
                     "-demotion-after-subtract"))
     #t
     (numeric
      backend
      'integer-fixnum?
      (numeric backend 'integer-subtract fixnum-overflow one)))
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

(define (check-divmod-case backend dividend-text divisor-text)
  "Check both division conventions for the owned decimal operands."
  (let* ((dividend (integer backend dividend-text))
         (divisor (integer backend divisor-text))
         (absolute-divisor (numeric backend 'integer-abs divisor))
         (truncated
          (numeric
           backend 'integer-divmod-truncate dividend divisor))
         (floored
          (numeric backend 'integer-divmod-floor dividend divisor)))
    (define (check-result label result remainder-follows)
      (let* ((quotient-value (car result))
             (remainder-value (cdr result))
             (reconstructed
              (numeric
               backend
               'integer-add
               (numeric
                backend 'integer-multiply quotient-value divisor)
               remainder-value))
             (absolute-remainder
              (numeric backend 'integer-abs remainder-value)))
        (require-condition
         (integer=? backend reconstructed dividend)
         "division reconstruction failed"
         (list label dividend-text divisor-text))
        (require-condition
         (< (numeric
             backend 'integer-compare absolute-remainder absolute-divisor)
            0)
         "division remainder escaped divisor bound"
         (list label dividend-text divisor-text))
        (require-condition
         (or (numeric backend 'integer-zero? remainder-value)
             (eq?
              (numeric backend 'integer-negative? remainder-value)
              (numeric backend 'integer-negative? remainder-follows)))
         "division remainder has the wrong sign"
         (list label dividend-text divisor-text))))
    (check-result 'truncate truncated dividend)
    (check-result 'floor floored divisor)
    #t))

(define (check-radix-roundtrip backend value radix)
  "Require VALUE to survive rendering and parsing in RADIX."
  (let* ((text (numeric backend 'integer->string value radix))
         (parsed (numeric backend 'integer-parse text radix)))
    (require-condition
     (and parsed (integer=? backend value parsed))
     "owned integer radix round trip failed"
     (list radix text))))

(define (check-exact-stress-profile limb-bits)
  "Stress multi-limb exact algorithms under LIMB-BITS."
  (let* ((backend (consent-make-numeric-backend limb-bits))
         (one (integer backend "1"))
         (high
          (numeric
           backend 'integer-shift-left one (+ (* limb-bits 5) 7)))
         (middle
          (numeric
           backend 'integer-shift-left one (+ (* limb-bits 2) 3)))
         (dividend
          (numeric
           backend
           'integer-add
           high
           (numeric
            backend
            'integer-add
            (numeric backend 'integer-multiply-small middle 12345)
            (integer backend "6789"))))
         (divisor
          (numeric
           backend
           'integer-add
           (numeric
            backend 'integer-shift-left one (+ (* limb-bits 2) 1))
           (integer backend "54321")))
         (dividend-text (integer-text backend dividend))
         (divisor-text (integer-text backend divisor))
         (negative-dividend-text
          (string-append "-" dividend-text))
         (negative-divisor-text
          (string-append "-" divisor-text))
         (common
          (numeric backend 'integer-add high one))
         (gcd-left
          (numeric backend 'integer-multiply-small common 65536))
         (gcd-right
          (numeric backend 'integer-multiply-small common 65537))
         (root-candidate
          (numeric
           backend
           'integer-add
           high
           (numeric backend 'integer-add middle (integer backend "17"))))
         (radicand
          (numeric
           backend
           'integer-add
           (numeric
            backend 'integer-multiply root-candidate root-candidate)
           root-candidate))
         (root-result
          (numeric backend 'integer-square-root radicand))
         (next-root-bound
          (numeric
           backend
           'integer-add
           (numeric backend 'integer-multiply-small (car root-result) 2)
           one))
         (negative-value (numeric backend 'integer-negate dividend)))
    (check-divmod-case backend dividend-text divisor-text)
    (check-divmod-case backend negative-dividend-text divisor-text)
    (check-divmod-case backend dividend-text negative-divisor-text)
    (check-divmod-case
     backend negative-dividend-text negative-divisor-text)
    (require-condition
     (integer=? backend
                (numeric backend 'integer-gcd gcd-left gcd-right)
                common)
     "multi-limb GCD lost the common factor"
     limb-bits)
    (require-condition
     (integer=? backend (car root-result) root-candidate)
     "multi-limb square root selected the wrong root"
     limb-bits)
    (require-condition
     (integer=? backend
                (numeric
                 backend
                 'integer-add
                 (numeric
                  backend
                  'integer-multiply
                  (car root-result)
                  (car root-result))
                 (cdr root-result))
                radicand)
     "square-root result does not reconstruct the radicand"
     limb-bits)
    (require-condition
     (< (numeric
         backend 'integer-compare (cdr root-result) next-root-bound)
        0)
     "square-root remainder permits a larger root"
     limb-bits)
    (for-each
     (lambda (radix)
       (check-radix-roundtrip backend dividend radix)
       (check-radix-roundtrip backend negative-value radix))
     '(2 8 10 16))
    (require-condition
     (not (numeric backend 'integer-parse "deadbeeg" 16))
     "radix parser accepted a digit outside the radix"
     limb-bits)
    (require-condition
     (not (numeric backend 'integer-parse "0" 1))
     "integer parser accepted an unsupported radix"
     limb-bits)
    (require-condition
     (raises?
      (lambda ()
        (numeric backend 'integer->string dividend 17)))
     "integer renderer accepted an unsupported radix"
     limb-bits)
    (require-condition
     (raises?
      (lambda ()
        (numeric
         backend 'integer-divmod-truncate dividend (integer backend "0"))))
     "owned integer division by zero did not raise"
     limb-bits)
    (require-condition
     (raises?
      (lambda ()
        (numeric backend 'integer-square-root negative-value)))
     "owned integer square root accepted a negative radicand"
     limb-bits)
    (require-condition
     (raises?
      (lambda ()
        (numeric
         backend 'integer-power dividend (integer backend "-1"))))
     "owned integer power accepted a negative exponent"
     limb-bits)
    #t))

(define (exact-profile-signature limb-bits)
  "Return canonical exact results that must not depend on limb width."
  (let* ((backend (consent-make-numeric-backend limb-bits))
         (left
          (integer
           backend
           "115792089237316195423570985008687907853269984665640564039457584007913129639936"))
         (right
          (integer backend "123456789012345678901234567890123456789"))
         (divisor
          (integer backend "98765432109876543210987654321"))
         (division
          (numeric backend 'integer-divmod-truncate left divisor))
         (ratio
          (numeric
           backend
           'rational-normalize
           (numeric backend 'integer-multiply-small left 21)
           (numeric backend 'integer-multiply-small left 35))))
    (list
     (integer-text backend
                   (numeric backend 'integer-add left right))
     (integer-text backend
                   (numeric backend 'integer-multiply right divisor))
     (integer-text backend (car division))
     (integer-text backend (cdr division))
     (numeric backend 'integer->string left 2)
     (numeric backend 'integer->string left 16)
     (integer-text backend (car ratio))
     (integer-text backend (cdr ratio)))))

(define (check-rational-stress-profile limb-bits)
  "Stress rational normalization and rounding under LIMB-BITS."
  (let* ((backend (consent-make-numeric-backend limb-bits))
         (one (integer backend "1"))
         (factor
          (numeric
           backend
           'integer-add
           (numeric
            backend 'integer-shift-left one (+ (* limb-bits 4) 5))
           (integer backend "37")))
         (other-factor
          (numeric
           backend
           'integer-add
           (numeric
            backend 'integer-shift-left one (+ (* limb-bits 3) 2))
           (integer backend "39")))
         (left
          (numeric
           backend
           'rational-normalize
           (numeric backend 'integer-multiply-small factor 3)
           (numeric backend 'integer-multiply-small other-factor 5)))
         (right
          (numeric
           backend
           'rational-normalize
           (numeric backend 'integer-multiply-small other-factor 7)
           (numeric backend 'integer-multiply-small factor 11)))
         (product (numeric backend 'rational-multiply left right))
         (three-factor
          (numeric backend 'integer-multiply-small factor 3))
         (six-factor
          (numeric backend 'integer-multiply-small factor 6))
         (sum
          (numeric
           backend
           'rational-add
           (numeric backend 'rational-normalize one three-factor)
           (numeric backend 'rational-normalize one six-factor)))
         (two-factor
          (numeric backend 'integer-multiply-small factor 2))
         (less
          (numeric
           backend
           'rational-normalize
           (numeric backend 'integer-subtract factor one)
           factor))
         (more
          (numeric
           backend
           'rational-normalize
           factor
           (numeric backend 'integer-add factor one))))
    (require-condition
     (and (string=? (integer-text backend (car product)) "21")
          (string=? (integer-text backend (cdr product)) "55"))
     "rational cross-cancellation produced a noncanonical result"
     limb-bits)
    (require-condition
     (and (integer=? backend (car sum) one)
          (integer=? backend (cdr sum) two-factor))
     "rational addition failed to exploit a large common denominator"
     limb-bits)
    (require-condition
     (= (numeric backend 'rational-compare less more) -1)
     "close large rationals compared in the wrong order"
     limb-bits)
    (for-each
     (lambda (entry)
       (let* ((numerator (integer backend (car entry)))
              (denominator (integer backend (cadr entry)))
              (mode (caddr entry))
              (expected (cadddr entry))
              (pair
               (numeric
                backend 'rational-normalize numerator denominator)))
         (require-condition
          (string=?
           (integer-text
            backend
            (numeric backend 'rational-round pair mode))
           expected)
          "rational rounding matrix mismatch"
          (list limb-bits entry))))
     '(("7" "3" truncate "2")
       ("7" "3" floor "2")
       ("7" "3" ceiling "3")
       ("5" "2" round "2")
       ("7" "2" round "4")
       ("-7" "3" truncate "-2")
       ("-7" "3" floor "-3")
       ("-7" "3" ceiling "-2")
       ("-5" "2" round "-2")
       ("-7" "2" round "-4")))
    (let ((zero
           (numeric
            backend
            'rational-normalize
            (integer backend "0")
            (numeric backend 'integer-negate factor)))
          (negative-denominator
           (numeric
            backend
            'rational-normalize
            (integer backend "9")
            (integer backend "-12"))))
      (require-condition
       (and (string=? (integer-text backend (car zero)) "0")
            (string=? (integer-text backend (cdr zero)) "1"))
       "rational zero was not normalized to 0/1"
       limb-bits)
      (require-condition
       (and
        (string=? (integer-text backend (car negative-denominator)) "-3")
        (string=? (integer-text backend (cdr negative-denominator)) "4"))
       "negative denominator was not normalized"
       limb-bits))
    (require-condition
     (raises?
      (lambda ()
        (numeric
         backend
         'rational-divide
         left
         (numeric
          backend
          'rational-normalize
          (integer backend "0")
          one))))
     "rational division by zero did not raise"
     limb-bits)
    (require-condition
     (raises?
      (lambda ()
        (numeric
         backend
         'rational-normalize
         one
         (integer backend "0"))))
     "zero rational denominator did not raise"
     limb-bits)
    #t))

;; Decimal inputs and canonical outputs spanning binary64 representation edges.
(define binary64-roundtrip-corpus
  '(("0" "0.0")
    ("-0" "0.0")
    ("0.1" "0.1")
    ("9007199254740991" "9007199254740991.0")
    ("9007199254740992" "9007199254740992.0")
    ("9007199254740993" "9007199254740992.0")
    ("5e-324" "5e-324")
    ("2.225073858507201e-308" "2.225073858507201e-308")
    ("2.2250738585072014e-308" "2.2250738585072014e-308")
    ("1.7976931348623157e308" "1.7976931348623157e+308")
    ("1.7976931348623158e308" "1.7976931348623157e+308")))

(define (check-binary64-profile limb-bits)
  "Stress binary64 conversion and special arithmetic under LIMB-BITS."
  (let* ((backend (consent-make-numeric-backend limb-bits))
         (one-integer (integer backend "1"))
         (zero (numeric backend 'binary64-zero))
         (one (numeric backend 'binary64-parse "1.0"))
         (negative-one (numeric backend 'binary64-parse "-1.0"))
         (half (numeric backend 'binary64-parse "0.5"))
         (positive-infinity
          (numeric backend 'binary64-special 'infinity 1))
         (negative-infinity
          (numeric backend 'binary64-special 'infinity -1))
         (nan (numeric backend 'binary64-special 'nan 1))
         (two-to-1075
          (numeric backend 'integer-shift-left one-integer 1075))
         (two-to-1076
          (numeric backend 'integer-shift-left one-integer 1076))
         (half-subnormal
          (numeric
           backend
           'binary64-from-rational
           (numeric
            backend 'rational-normalize one-integer two-to-1075)))
         (above-half-subnormal
          (numeric
           backend
           'binary64-from-rational
           (numeric
            backend
            'rational-normalize
            (integer backend "3")
            two-to-1076)))
         (normal-midpoint
          (numeric
           backend
           'binary64-from-rational
           (numeric
            backend
            'rational-normalize
            (integer backend "9007199254740991")
            two-to-1075)))
         (half-ulp
          (numeric backend 'binary64-parse "1.1102230246251565e-16"))
         (three-half-ulps
          (numeric backend 'binary64-parse "3.3306690738754696e-16"))
         (tie-add-down
          (numeric backend 'binary64-binary one half-ulp '+))
         (tie-add-up
          (numeric backend 'binary64-binary one three-half-ulps '+))
         (smallest
          (numeric backend 'binary64-parse "5e-324"))
         (signature '()))
    (for-each
     (lambda (entry)
       (let* ((parsed
               (numeric backend 'binary64-parse (car entry)))
              (rendered
               (and parsed (numeric backend 'binary64->string parsed)))
              (reparsed
               (and rendered
                    (numeric backend 'binary64-parse rendered)))
              (exact-pair
               (and parsed
                    (numeric backend 'binary64->rational parsed)))
              (exact-roundtrip
               (and exact-pair
                    (numeric
                     backend 'binary64-from-rational exact-pair)))
              (host-value
               (and parsed (numeric backend 'binary64->host parsed)))
              (expected-host (string->number (cadr entry))))
         (require-condition
          (and parsed (string=? rendered (cadr entry)))
          "binary64 canonical rendering mismatch"
          (list limb-bits entry rendered))
         (require-condition
          (and reparsed
               (numeric backend 'binary64-equal? parsed reparsed))
          "binary64 decimal round trip changed the value"
          (list limb-bits entry))
         (require-condition
         (and exact-roundtrip
               (numeric
                backend 'binary64-equal? parsed exact-roundtrip))
          "binary64 exact dyadic round trip changed the value"
          (list limb-bits entry))
         (require-condition
          (and expected-host (= host-value expected-host))
          "binary64 direct host reconstruction changed the value"
          (list limb-bits entry host-value))
         (set! signature (cons rendered signature))))
     binary64-roundtrip-corpus)
    (for-each
     (lambda (text)
       (require-condition
        (not (numeric backend 'binary64-parse text))
        "binary64 parser accepted malformed decimal text"
        (list limb-bits text)))
     '("" "+" "-" "." "+." "e3" "1e" "1e3.0" "1..0" "1e2e3"))
    (require-condition
     (and (numeric backend 'binary64-zero? half-subnormal)
          (string=?
           (numeric backend 'binary64->string above-half-subnormal)
           "5e-324"))
     "binary64 subnormal halfway rounding is not ties-to-even"
     limb-bits)
    (require-condition
     (string=?
      (numeric backend 'binary64->string normal-midpoint)
      "2.2250738585072014e-308")
     "binary64 normal/subnormal midpoint rounded the wrong way"
     limb-bits)
    (require-condition
     (and
      (string=? (numeric backend 'binary64->string tie-add-down) "1.0")
      (string=?
       (numeric backend 'binary64->string tie-add-up)
       "1.0000000000000004"))
     "binary64 addition did not round halfway cases to even"
     limb-bits)
    (require-condition
     (eq?
      (numeric
       backend
       'binary64-class
       (numeric
        backend
        'binary64-binary
        positive-infinity
        negative-infinity
        '+))
      'nan)
     "opposite infinities did not produce NaN"
     limb-bits)
    (require-condition
     (eq?
      (numeric
       backend
       'binary64-class
       (numeric backend 'binary64-binary zero zero '/))
      'nan)
     "zero divided by zero did not produce NaN"
     limb-bits)
    (let ((negative-product
           (numeric
            backend
            'binary64-binary
            positive-infinity
            negative-one
            '*))
          (negative-quotient
           (numeric
            backend 'binary64-binary negative-one zero '/))
          (finite-over-infinity
           (numeric
            backend 'binary64-binary one positive-infinity '/))
          (underflow
           (numeric backend 'binary64-binary smallest half '*))
          (cancellation
           (numeric backend 'binary64-binary one negative-one '+)))
      (require-condition
       (and
        (eq? (numeric backend 'binary64-class negative-product)
             'infinity)
        (= (numeric backend 'binary64-sign negative-product) -1)
        (eq? (numeric backend 'binary64-class negative-quotient)
             'infinity)
        (= (numeric backend 'binary64-sign negative-quotient) -1))
       "binary64 special arithmetic lost its result sign"
       limb-bits)
      (require-condition
       (and
        (numeric backend 'binary64-zero? finite-over-infinity)
        (numeric backend 'binary64-zero? underflow)
        (numeric backend 'binary64-zero? cancellation)
        (= (numeric backend 'binary64-sign cancellation) 1))
       "binary64 zero normalization failed"
       limb-bits))
    (require-condition
     (eq? (numeric backend 'binary64-compare nan one) #f)
     "binary64 NaN participated in ordering"
     limb-bits)
    (require-condition
     (and
      (raises?
       (lambda ()
         (numeric backend 'binary64-special 'finite 1)))
      (raises?
       (lambda ()
         (numeric backend 'binary64-special 'infinity 0))))
     "binary64 special constructor accepted a noncanonical tuple"
     limb-bits)
    (reverse signature)))

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
 'multi-limb-exact-invariants '(portable runtime numeric stress)
(let ((signature-14 (exact-profile-signature 14))
      (signature-30 (exact-profile-signature 30))
      (signature-62 (exact-profile-signature 62)))
  (test-assert
   'multi-limb-invariants-14
   (check-exact-stress-profile 14))
  (test-assert
   'multi-limb-invariants-30
   (check-exact-stress-profile 30))
  (test-assert
   'multi-limb-invariants-62
   (check-exact-stress-profile 62))
  (test-equal
   'exact-results-independent-of-30-bit-profile
   signature-14
   signature-30)
  (test-equal
   'exact-results-independent-of-62-bit-profile
   signature-14
   signature-62)))

(testing-registry-case
 'rational-normalization-and-rounding-stress
 '(portable runtime numeric stress)
(begin
  (test-assert
   'rational-invariants-14
   (check-rational-stress-profile 14))
  (test-assert
   'rational-invariants-30
   (check-rational-stress-profile 30))
  (test-assert
   'rational-invariants-62
   (check-rational-stress-profile 62))))

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

(testing-registry-case
 'binary64-boundary-matrix '(portable runtime numeric stress)
(let ((signature-14 (check-binary64-profile 14))
      (signature-30 (check-binary64-profile 30))
      (signature-62 (check-binary64-profile 62)))
  (test-equal
   'binary64-results-independent-of-30-bit-profile
   signature-14
   signature-30)
  (test-equal
   'binary64-results-independent-of-62-bit-profile
   signature-14
   signature-62)))

(testing-runner-main "Consent owned numeric backend" (command-line))
