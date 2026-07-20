;;; Generated and differential tests for the owned numeric backend.
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

(define (integer backend value)
  "Import exact host integer VALUE through the owned decimal parser."
  (numeric backend 'integer-parse (number->string value) 10))

(define (integer-text backend value)
  "Render owned integer VALUE as decimal text."
  (numeric backend 'integer->string value 10))

(define (require-condition condition message detail)
  "Raise MESSAGE with DETAIL unless CONDITION is true."
  (if (not condition)
      (error message detail)))

(define (host-comparison left right)
  "Return -1, 0, or 1 according to the order of host numbers."
  (cond
   ((< left right) -1)
   ((> left right) 1)
   (else 0)))

(define (check-owned-integer backend label expected actual detail)
  "Require owned ACTUAL to equal exact host integer EXPECTED."
  (let ((expected-text (number->string expected))
        (actual-text (integer-text backend actual)))
    (require-condition
     (string=? expected-text actual-text)
     "generated owned integer result mismatch"
     (list label detail expected-text actual-text))))

(define (check-owned-rational backend label expected actual detail)
  "Require owned rational pair ACTUAL to equal exact host EXPECTED."
  (let ((expected-numerator (number->string (numerator expected)))
        (expected-denominator (number->string (denominator expected)))
        (actual-numerator (integer-text backend (car actual)))
        (actual-denominator (integer-text backend (cdr actual))))
    (require-condition
     (and (string=? expected-numerator actual-numerator)
          (string=? expected-denominator actual-denominator))
     "generated owned rational result mismatch"
     (list label
           detail
           (cons expected-numerator expected-denominator)
           (cons actual-numerator actual-denominator)))))

(define (make-word-generator seed)
  "Return a deterministic 31-bit Park-Miller word generator from SEED."
  (let ((state seed))
    (lambda ()
      (set! state (modulo (* state 48271) 2147483647))
      state)))

(define (generated-host-integer next index)
  "Build one signed multiword host integer using NEXT and INDEX."
  (let ((word-base 1073741824)
        (word-count (+ 2 (modulo index 7))))
    (let loop ((remaining word-count) (result 0))
      (if (= remaining 0)
          (let ((nonzero (if (= result 0) 1 result)))
            (if (even? index) nonzero (- nonzero)))
          (loop (- remaining 1)
                (+ (* result word-base)
                   (modulo (next) word-base)))))))

(define (host-floor-divmod dividend divisor)
  "Return host floor quotient and remainder for exact integer operands."
  (let ((quotient-value (quotient dividend divisor))
        (remainder-value (remainder dividend divisor)))
    (if (and (not (= remainder-value 0))
             (or (and (< dividend 0) (> divisor 0))
                 (and (> dividend 0) (< divisor 0))))
        (cons (- quotient-value 1)
              (+ remainder-value divisor))
        (cons quotient-value remainder-value))))

;; Racket carries the full alternate-profile oracle matrix. Other hosts run a
;; bounded default-profile slice while the fixed boundary suite continues to
;; exercise every profile everywhere, including compiled self-host products.
(define extended-generated-profiles?
  (let ((host (get-environment-variable "CONSENT_PORTABLE_HOST")))
    (and (not (get-environment-variable "TESTING_RUNNER_HOST_RUN"))
         host
         (string=? host "racket"))))

;; Limb widths selected for the generated differential layer.
(define generated-profile-widths
  (if extended-generated-profiles? '(14 30 62) '(30)))

;; Seeded repetitions per selected limb profile.
(define generated-case-count
  (if extended-generated-profiles? 16 2))

(define (check-selected-profiles procedure)
  "Run unary profile-checking PROCEDURE for selected generated widths."
  (let loop ((widths generated-profile-widths))
    (or (null? widths)
        (and (procedure (car widths))
             (loop (cdr widths))))))

(define (check-generated-exact-profile limb-bits seed)
  "Differential-test exact operations for LIMB-BITS using deterministic SEED."
  (let ((backend (consent-make-numeric-backend limb-bits))
        (next (make-word-generator seed)))
    (let loop ((index 0))
      (if (< index generated-case-count)
          (let* ((left (generated-host-integer next index))
                 (right (generated-host-integer next (+ index 37)))
                 (owned-left (integer backend left))
                 (owned-right (integer backend right))
                 (truncated
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
                   owned-right))
                 (expected-floor (host-floor-divmod left right))
                 (root-input (abs left))
                 (expected-root
                  (call-with-values
                   (lambda () (exact-integer-sqrt root-input))
                   cons))
                 (actual-root
                  (numeric
                   backend
                   'integer-square-root
                   (integer backend root-input)))
                 (power-exponent (modulo index 4)))
            (check-owned-integer
             backend
             'add
             (+ left right)
             (numeric backend 'integer-add owned-left owned-right)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'subtract
             (- left right)
             (numeric backend 'integer-subtract owned-left owned-right)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'multiply
             (* left right)
             (numeric backend 'integer-multiply owned-left owned-right)
             (list limb-bits seed index))
            (require-condition
             (= (numeric
                 backend
                 'integer-compare
                 owned-left
                 owned-right)
                (host-comparison left right))
             "generated integer comparison mismatch"
             (list limb-bits seed index left right))
            (check-owned-integer
             backend
             'truncate-quotient
             (quotient left right)
             (car truncated)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'truncate-remainder
             (remainder left right)
             (cdr truncated)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'floor-quotient
             (car expected-floor)
             (car floored)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'floor-remainder
             (cdr expected-floor)
             (cdr floored)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'gcd
             (gcd left right)
             (numeric backend 'integer-gcd owned-left owned-right)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'square-root
             (car expected-root)
             (car actual-root)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'square-root-remainder
             (cdr expected-root)
             (cdr actual-root)
             (list limb-bits seed index))
            (check-owned-integer
             backend
             'power
             (expt left power-exponent)
             (numeric
              backend
              'integer-power
              owned-left
              (integer backend power-exponent))
             (list limb-bits seed index power-exponent))
            (loop (+ index 1)))))
    #t))

(define (alternating-limb-host-value base maximum length)
  "Return LENGTH little-endian limbs alternating MAXIMUM and zero."
  (let loop ((index (- length 1)) (result 0))
    (if (< index 0)
        result
        (loop (- index 1)
              (+ (* result base)
                 (if (even? index) maximum 0))))))

(define (check-adversarial-exact-profile limb-bits)
  "Exercise carry, borrow, and divisor shapes for LIMB-BITS."
  (let* ((backend (consent-make-numeric-backend limb-bits))
         (base (expt 2 limb-bits))
         (maximum (- base 1)))
    (let loop ((length 2))
      (if (<= length 8)
          (let* ((power (expt base length))
                 (all-maximum (- power 1))
                 (alternating
                  (alternating-limb-host-value
                   base maximum length))
                 (near-power-divisor (- (expt base (- length 1)) 1))
                 (owned-power (integer backend power))
                 (owned-all-maximum (integer backend all-maximum))
                 (owned-alternating (integer backend alternating))
                 (owned-divisor (integer backend near-power-divisor))
                 (division
                  (numeric
                   backend
                   'integer-divmod-truncate
                   owned-all-maximum
                   owned-divisor)))
            (check-owned-integer
             backend
             'carry-chain
             power
             (numeric
              backend
              'integer-add
              owned-all-maximum
              (integer backend 1))
             (list limb-bits length))
            (check-owned-integer
             backend
             'borrow-chain
             all-maximum
             (numeric
              backend
              'integer-subtract
              owned-power
              (integer backend 1))
             (list limb-bits length))
            (check-owned-integer
             backend
             'alternating-square
             (* alternating alternating)
             (numeric
              backend
              'integer-multiply
              owned-alternating
              owned-alternating)
             (list limb-bits length))
            (check-owned-integer
             backend
             'near-power-quotient
             (quotient all-maximum near-power-divisor)
             (car division)
             (list limb-bits length))
            (check-owned-integer
             backend
             'near-power-remainder
             (remainder all-maximum near-power-divisor)
             (cdr division)
             (list limb-bits length))
            (loop (+ length 1)))))
    #t))

(define (check-generated-rational-profile limb-bits seed)
  "Differential-test rational operations for LIMB-BITS using SEED."
  (let ((backend (consent-make-numeric-backend limb-bits))
        (next (make-word-generator seed)))
    (let loop ((index 0))
      (if (< index generated-case-count)
          (let* ((left-numerator
                  (generated-host-integer next (+ index 3)))
                 (left-denominator
                  (+ (abs (generated-host-integer next (+ index 19))) 1))
                 (right-numerator
                  (generated-host-integer next (+ index 43)))
                 (right-denominator
                  (+ (abs (generated-host-integer next (+ index 71))) 1))
                 (host-left (/ left-numerator left-denominator))
                 (host-right (/ right-numerator right-denominator))
                 (owned-left
                  (numeric
                   backend
                   'rational-normalize
                   (integer backend left-numerator)
                   (integer backend left-denominator)))
                 (owned-right
                  (numeric
                   backend
                   'rational-normalize
                   (integer backend right-numerator)
                   (integer backend right-denominator)))
                 (detail (list limb-bits seed index)))
            (check-owned-rational
             backend 'normalize host-left owned-left detail)
            (check-owned-rational
             backend
             'add
             (+ host-left host-right)
             (numeric backend 'rational-add owned-left owned-right)
             detail)
            (check-owned-rational
             backend
             'subtract
             (- host-left host-right)
             (numeric backend 'rational-subtract owned-left owned-right)
             detail)
            (check-owned-rational
             backend
             'multiply
             (* host-left host-right)
             (numeric backend 'rational-multiply owned-left owned-right)
             detail)
            (check-owned-rational
             backend
             'divide
             (/ host-left host-right)
             (numeric backend 'rational-divide owned-left owned-right)
             detail)
            (require-condition
             (= (numeric
                 backend
                 'rational-compare
                 owned-left
                 owned-right)
                (host-comparison host-left host-right))
             "generated rational comparison mismatch"
             detail)
            (loop (+ index 1)))))
    #t))

(define (owned-dyadic backend signed-significand exponent)
  "Return an owned rational for SIGNED-SIGNIFICAND times 2^EXPONENT."
  (let ((significand (integer backend signed-significand))
        (one (integer backend 1)))
    (if (>= exponent 0)
        (numeric
         backend
         'rational-normalize
         (numeric backend 'integer-shift-left significand exponent)
         one)
        (numeric
         backend
         'rational-normalize
         significand
         (numeric backend 'integer-shift-left one (- exponent))))))

(define (owned-rational=? backend left right)
  "Report whether normalized owned rational pairs LEFT and RIGHT are equal."
  (and (= (numeric
           backend
           'integer-compare
           (car left)
           (car right))
          0)
       (= (numeric
           backend
           'integer-compare
           (cdr left)
           (cdr right))
          0)))

;; Canonical finite binary64 tuples at subnormal, normal, unit, and maximum
;; exponent boundaries. Each significand is the exact stored integer.
(define binary64-pattern-corpus
  '((smallest-subnormal 1 1 -1074)
    (largest-subnormal 1 4503599627370495 -1074)
    (minimum-normal 1 4503599627370496 -1074)
    (minimum-normal-next 1 4503599627370497 -1074)
    (one 1 4503599627370496 -52)
    (one-next 1 4503599627370497 -52)
    (two-predecessor 1 9007199254740991 -52)
    (maximum-finite 1 9007199254740991 971)
    (negative-smallest-subnormal -1 1 -1074)
    (negative-one-next -1 4503599627370497 -52)
    (negative-maximum-finite -1 9007199254740991 971)))

(define (check-binary64-value
         backend label sign significand exponent detail)
  "Check one exactly representable binary64 tuple and its host seam."
  (let* ((signed-significand
          (if (< sign 0) (- significand) significand))
         (exact-pair
          (owned-dyadic backend signed-significand exponent))
         (value
          (numeric backend 'binary64-from-rational exact-pair))
         (returned-pair
          (numeric backend 'binary64->rational value))
         (negated (numeric backend 'binary64-negate value))
         (double-negated (numeric backend 'binary64-negate negated))
         (host-value (numeric backend 'binary64->host value))
         (host-roundtrip
          (numeric backend 'binary64-import-host host-value)))
    (require-condition
     (numeric backend 'binary64? value)
     "binary64 constructor returned the wrong representation class"
     (list label detail))
    (require-condition
     (eq? (numeric backend 'binary64-class value) 'finite)
     "finite bit pattern changed class"
     (list label detail))
    (require-condition
     (eq? (numeric backend 'binary64-negative? value) (< sign 0))
     "binary64 sign predicate mismatch"
     (list label detail))
    (require-condition
     (owned-rational=? backend exact-pair returned-pair)
     "exactly representable bit pattern changed dyadic value"
     (list label detail))
    (require-condition
     (and (numeric backend 'binary64-equal? value double-negated)
          (eq? (numeric backend 'binary64-negative? negated)
               (> sign 0)))
     "binary64 negation did not reverse and restore the sign"
     (list label detail))
    (require-condition
     (numeric backend 'binary64-equal? value host-roundtrip)
     "binary64 host seam changed a finite bit pattern"
     (list label detail))
    value))

(define (check-binary64-pattern-profile limb-bits seed)
  "Exercise fixed and generated finite bit patterns for LIMB-BITS."
  (let ((backend (consent-make-numeric-backend limb-bits))
        (next (make-word-generator seed))
        (exponents '(-1074 -1023 -100 -53 -52 -1 0 511 971)))
    (for-each
     (lambda (entry)
       (check-binary64-value
        backend
        (car entry)
        (cadr entry)
        (caddr entry)
        (cadddr entry)
        (list limb-bits seed)))
     binary64-pattern-corpus)
    (let loop ((index 0))
      (if (< index generated-case-count)
          (let* ((sign (if (even? index) 1 -1))
                 (normal-significand
                  (+ 4503599627370496
                     (modulo (next) 1073741824)))
                 (normal-exponent
                  (list-ref exponents
                            (modulo index (length exponents))))
                 (subnormal-significand
                  (+ 1 (modulo (next) 2147483646))))
            (check-binary64-value
             backend
             'generated-normal
             sign
             normal-significand
             normal-exponent
             (list limb-bits seed index))
            (check-binary64-value
             backend
             'generated-subnormal
             sign
             subnormal-significand
             -1074
             (list limb-bits seed index))
            (loop (+ index 1)))))
    #t))

;; Finite operands selected to cross cancellation, subnormal, ordinary decimal,
;; and widely separated exponent paths without depending on NaN equality.
(define binary64-arithmetic-corpus
  '(("0.1" "0.2")
    ("1.5" "-0.25")
    ("5e-324" "2.0")
    ("2.2250738585072014e-308" "0.5")
    ("1e100" "-1e-100")
    ("9007199254740992.0" "1.0000000000000002")))

(define (host-binary operation left right)
  "Apply host binary64 OPERATION to finite LEFT and RIGHT."
  (case operation
    ((+) (+ left right))
    ((-) (- left right))
    ((*) (* left right))
    ((/) (/ left right))
    (else (error "unknown host binary operation" operation))))

(define (check-binary64-arithmetic-profile limb-bits)
  "Differential-test software binary64 arithmetic for LIMB-BITS."
  (let ((backend (consent-make-numeric-backend limb-bits)))
    (for-each
     (lambda (entry)
       (let* ((left
               (numeric backend 'binary64-parse (car entry)))
              (right
               (numeric backend 'binary64-parse (cadr entry)))
              (host-left
               (numeric backend 'binary64->host left))
              (host-right
               (numeric backend 'binary64->host right)))
         (for-each
          (lambda (operation)
            (let* ((actual
                    (numeric
                     backend
                     'binary64-binary
                     left
                     right
                     operation))
                   (expected
                    (numeric
                     backend
                     'binary64-import-host
                     (host-binary
                      operation host-left host-right))))
              (require-condition
               (numeric backend 'binary64-equal? expected actual)
               "software binary64 arithmetic differs from host IEEE result"
               (list limb-bits entry operation
                     (numeric backend 'binary64->string expected)
                     (numeric backend 'binary64->string actual)))))
          '(+ - * /))))
     binary64-arithmetic-corpus)
    #t))

(define (check-dispatch-operation-inventory)
  "Exercise backend dispatcher operations not central to boundary matrices."
  (let* ((backend consent-default-numeric-backend)
         (zero (numeric backend 'integer-zero))
         (small (numeric backend 'integer-from-small -42))
         ;; A self-hosted program cannot manufacture a native host bignum:
         ;; its `(expt 2 100)` result is already an owned Consent number.
         ;; Keep the large native import on direct hosts and exercise the same
         ;; dispatcher seam with a bounded native value under `--host-run`.
         (imported-host
          (if (get-environment-variable "TESTING_RUNNER_HOST_RUN")
              42
              (expt 2 100)))
         (imported
          (numeric backend 'integer-import-host imported-host))
         (large (integer backend (expt 2 100)))
         (one-third
          (numeric
           backend
           'rational-normalize
           (integer backend 1)
           (integer backend 3)))
         (one-fifth
          (numeric
           backend
           'rational-normalize
           (integer backend 1)
           (integer backend 5)))
         (difference
          (numeric backend 'rational-subtract one-third one-fifth))
         (negative
          (numeric backend 'binary64-parse "-3.5"))
         (positive
          (numeric backend 'binary64-negate negative)))
    (require-condition
     (and (numeric backend 'integer? zero)
          (numeric backend 'integer-zero? zero)
          (numeric backend 'integer? small)
          (numeric backend 'integer-negative? small)
          (numeric backend 'integer-even? small)
          (not (numeric backend 'integer-positive? small))
          (= (numeric backend 'integer->small small 42) -42)
          (not (numeric backend 'integer->small large 42))
          (string=? (integer-text backend imported)
                    (number->string imported-host)))
     "integer dispatcher operation inventory mismatch"
     'integer)
    (check-owned-rational backend 'rational-subtract 2/15 difference
                          'dispatcher)
    (require-condition
     (and (numeric backend 'binary64? negative)
          (numeric backend 'binary64-negative? negative)
          (not (numeric backend 'binary64-negative? positive))
          (string=?
           (numeric backend 'binary64->string positive)
           "3.5"))
     "binary64 dispatcher operation inventory mismatch"
     'binary64)
    #t))

(testing-registry-case
 'generated-exact-differential
 '(portable runtime numeric generated stress)
(test-assert
 'generated-exact-selected-profiles
 (check-selected-profiles
  (lambda (limb-bits)
    (check-generated-exact-profile
     limb-bits
     (+ 104729 (* limb-bits 1009)))))))

(testing-registry-case
 'adversarial-limb-shapes
 '(portable runtime numeric generated stress)
(test-assert
 'adversarial-selected-profiles
 (check-selected-profiles check-adversarial-exact-profile)))

(testing-registry-case
 'generated-rational-differential
 '(portable runtime numeric generated stress)
(test-assert
 'generated-rational-selected-profiles
 (check-selected-profiles
  (lambda (limb-bits)
    (check-generated-rational-profile
     limb-bits
     (+ 196613 (* limb-bits 1013)))))))

(testing-registry-case
 'binary64-bit-pattern-differential
 '(portable runtime numeric generated stress)
(test-assert
 'binary64-bit-patterns-selected-profiles
 (check-selected-profiles
  (lambda (limb-bits)
    (check-binary64-pattern-profile
     limb-bits
     (+ 32452843 (* limb-bits 1019)))))))

(testing-registry-case
 'binary64-arithmetic-differential
 '(portable runtime numeric generated stress)
(test-assert
 'binary64-arithmetic-selected-profiles
 (check-selected-profiles check-binary64-arithmetic-profile)))

(testing-registry-case
 'numeric-dispatch-operation-inventory
 '(portable runtime numeric)
(test-assert
 'numeric-dispatch-operation-inventory
 (check-dispatch-operation-inventory)))

(testing-runner-main
 "Consent generated numeric backend"
 (command-line))
