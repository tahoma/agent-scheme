;;; Self-hostable numeric storage and arithmetic for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library deliberately uses host exact arithmetic only for limb-sized
;;; working values, indexes, exponents, and values proved within the selected
;;; profile's B^2 - 1 accumulator bound. Language-visible exact values inside
;;; both that bound and the portable host fixnum bound use immediate host
;;; fixnums; larger values use sign-and-limb records. The public surface is a
;;; small backend dispatcher so alternate limb profiles exercise the same
;;; algorithms without putting a profile tag in every integer.

(define-library (consent numeric)
  (export consent-make-numeric-backend
          consent-default-numeric-backend
          consent-numeric-backend-limb-bits
          consent-numeric)
  (import (scheme base)
          (scheme char))
  (begin
    ;; A backend fixes the limb profile for all integers passed to it.
    (define-record-type <consent-numeric-backend>
      (make-numeric-backend
       limb-bits limb-base accumulator-limit fixnum-limit)
      consent-numeric-backend?
      (limb-bits consent-numeric-backend-limb-bits)
      (limb-base numeric-backend-limb-base)
      (accumulator-limit numeric-backend-accumulator-limit)
      (fixnum-limit numeric-backend-fixnum-limit))

    ;; Values inside a backend's proved direct bound are represented by host
    ;; fixnums. Only promoted values allocate this bignum record.
    (define-record-type <owned-bignum>
      (make-owned-bignum sign limbs)
      owned-bignum?
      (sign owned-bignum-sign)
      (limbs owned-bignum-limbs))

    ;; Owned binary64 values use an explicit class and an exact dyadic payload.
    ;; A finite nonzero value is SIGN * SIGNIFICAND * 2^EXPONENT.
    (define-record-type <owned-binary64>
      (make-owned-binary64 class sign significand exponent host-cache)
      owned-binary64?
      (class owned-binary64-class)
      (sign owned-binary64-sign)
      (significand owned-binary64-significand)
      (exponent owned-binary64-exponent)
      (host-cache owned-binary64-host-cache))

    (define (small-power base exponent)
      "Raise small exact BASE to nonnegative host integer EXPONENT."
      (let loop ((result 1) (remaining exponent))
        (if (= remaining 0)
            result
            (loop (* result base) (- remaining 1)))))

    ;; Racket and Gambit provide the narrowest observed positive fixnum bound
    ;; among the supported 64-bit hosts. A target with a wider proven fixnum
    ;; representation may specialize this constant together with its ABI.
    (define portable-positive-fixnum-limit 1152921504606846975)

    (define (consent-make-numeric-backend limb-bits)
      "Create an owned numeric backend using LIMB-BITS bits per limb."
      "Thirty bits is the common immediate 64-bit profile. Wider profiles use"
      "the same algorithms; a native target must provide exact double-width"
      "working arithmetic for the selected profile."
      #((parameters
         (limb-bits (type exact-positive-integer)
          (description "Positive limb width fixed for the backend.")))
        (returns (type numeric-backend)
         (description "A numeric backend with one fixed limb profile."))
        (effects error allocation))
      (if (not (and (integer? limb-bits)
                    (exact? limb-bits)
                    (> limb-bits 0)))
          (error "numeric limb width must be a positive exact integer"
                 limb-bits))
      (let* ((base (small-power 2 limb-bits))
             (maximum-limb (- base 1))
             ;; Derive B^2 - 1 without first constructing B^2, which is one
             ;; above the proven common fixnum floor for the 30-bit profile.
             (accumulator-limit
              (+ (* maximum-limb base) maximum-limb))
             (fixnum-limit
              (min accumulator-limit portable-positive-fixnum-limit)))
        (make-numeric-backend
         limb-bits base accumulator-limit fixnum-limit)))

    ;; The common 64-bit bootstrap profile.
    (define consent-default-numeric-backend
      (consent-make-numeric-backend 30))

    (define (vector-copy-prefix source length)
      "Copy the first LENGTH elements of SOURCE into a fresh vector."
      (let ((result (make-vector length 0)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (vector-set! result index (vector-ref source index))
                (loop (+ index 1)))
              result))))

    (define (normalize-limbs limbs)
      "Remove high zero limbs from LIMBS."
      (let loop ((length (vector-length limbs)))
        (if (and (> length 0)
                 (= (vector-ref limbs (- length 1)) 0))
            (loop (- length 1))
            (if (= length (vector-length limbs))
                limbs
                (vector-copy-prefix limbs length)))))

    (define (owned-fixnum? value)
      "Report whether VALUE is a directly represented owned integer."
      (and (integer? value) (exact? value)))

    (define (owned-integer? value)
      "Report whether VALUE is an owned fixnum or bignum."
      (or (owned-fixnum? value) (owned-bignum? value)))

    (define (integer-sign value)
      "Return the normalized sign of owned integer VALUE."
      (if (owned-fixnum? value)
          (cond ((< value 0) -1) ((> value 0) 1) (else 0))
          (owned-bignum-sign value)))

    (define (integer-limbs backend value)
      "Return owned VALUE's normalized limbs under BACKEND."
      (if (owned-fixnum? value)
          (let ((base (numeric-backend-limb-base backend)))
            (let loop ((remaining (abs value)) (digits '()))
              (if (= remaining 0)
                  (list->vector (reverse digits))
                  (loop (quotient remaining base)
                        (cons (modulo remaining base) digits)))))
          (owned-bignum-limbs value)))

    (define (integer-normalize backend sign limbs)
      "Demote normalized LIMBS to a fixnum or construct an owned bignum."
      (let* ((normalized (normalize-limbs limbs))
             (length (vector-length normalized)))
        (cond
         ((= length 0) 0)
         ((<= length 2)
          (let* ((base (numeric-backend-limb-base backend))
                 (magnitude
                  (+ (vector-ref normalized 0)
                     (if (= length 2)
                         (* (vector-ref normalized 1) base)
                         0))))
            (if (<= magnitude (numeric-backend-fixnum-limit backend))
                (if (< sign 0) (- magnitude) magnitude)
                (make-owned-bignum
                 (if (< sign 0) -1 1)
                 normalized))))
         (else
          (make-owned-bignum
           (if (< sign 0) -1 1)
           normalized)))))

    ;; Shared canonical owned integer constant.
    (define owned-zero 0)

    (define (integer-from-small backend value)
      "Import host integer VALUE, retaining it directly when profile-safe."
      (let ((limit (numeric-backend-fixnum-limit backend)))
        (if (<= (abs value) limit)
            value
            (let ((base (numeric-backend-limb-base backend))
                  (sign (if (< value 0) -1 1)))
              (let loop ((remaining (abs value)) (digits '()))
                (if (= remaining 0)
                    (integer-normalize
                     backend sign (list->vector (reverse digits)))
                    (loop (quotient remaining base)
                          (cons (modulo remaining base) digits))))))))

    (define (integer-zero? value)
      "Report whether owned integer VALUE is zero."
      (= (integer-sign value) 0))

    (define (integer-negative? value)
      "Report whether owned integer VALUE is negative."
      (< (integer-sign value) 0))

    (define (integer-positive? value)
      "Report whether owned integer VALUE is positive."
      (> (integer-sign value) 0))

    (define (integer-abs value)
      "Return the absolute value of owned integer VALUE."
      (cond
       ((owned-fixnum? value) (abs value))
       ((integer-negative? value)
        (make-owned-bignum 1 (owned-bignum-limbs value)))
       (else value)))

    (define (integer-negate value)
      "Return the additive inverse of owned integer VALUE."
      (if (owned-fixnum? value)
          (- value)
          (make-owned-bignum
           (- (owned-bignum-sign value))
           (owned-bignum-limbs value))))

    (define (magnitude-compare left right)
      "Compare normalized magnitude vectors LEFT and RIGHT."
      (let ((left-length (vector-length left))
            (right-length (vector-length right)))
        (cond
         ((< left-length right-length) -1)
         ((> left-length right-length) 1)
         (else
          (let loop ((index (- left-length 1)))
            (if (< index 0)
                0
                (let ((left-limb (vector-ref left index))
                      (right-limb (vector-ref right index)))
                  (cond
                   ((< left-limb right-limb) -1)
                   ((> left-limb right-limb) 1)
                   (else (loop (- index 1)))))))))))

    (define (integer-compare left right)
      "Return -1, 0, or 1 according to the order of owned integers."
      (let ((left-sign (integer-sign left))
            (right-sign (integer-sign right)))
        (cond
         ((< left-sign right-sign) -1)
         ((> left-sign right-sign) 1)
         ((= left-sign 0) 0)
         ((and (owned-fixnum? left) (owned-fixnum? right))
          (cond ((< left right) -1) ((> left right) 1) (else 0)))
         ((owned-fixnum? left) (- left-sign))
         ((owned-fixnum? right) right-sign)
         (else
          (* left-sign
             (magnitude-compare (owned-bignum-limbs left)
                                (owned-bignum-limbs right)))))))

    (define (magnitude-add backend left right)
      "Add magnitude vectors LEFT and RIGHT."
      (let* ((base (numeric-backend-limb-base backend))
             (left-length (vector-length left))
             (right-length (vector-length right))
             (length (max left-length right-length))
             (result (make-vector (+ length 1) 0)))
        (let loop ((index 0) (carry 0))
          (if (= index length)
              (begin
                (vector-set! result index carry)
                (normalize-limbs result))
              (let ((sum
                     (+ carry
                        (if (< index left-length)
                            (vector-ref left index)
                            0)
                        (if (< index right-length)
                            (vector-ref right index)
                            0))))
                (vector-set! result index (modulo sum base))
                (loop (+ index 1) (quotient sum base)))))))

    (define (magnitude-subtract backend left right)
      "Subtract magnitude RIGHT from LEFT, requiring LEFT >= RIGHT."
      (let* ((base (numeric-backend-limb-base backend))
             (length (vector-length left))
             (right-length (vector-length right))
             (result (make-vector length 0)))
        (let loop ((index 0) (borrow 0))
          (if (= index length)
              (normalize-limbs result)
              (let* ((raw
                      (- (vector-ref left index)
                         (if (< index right-length)
                             (vector-ref right index)
                             0)
                         borrow))
                     (negative? (< raw 0)))
                (vector-set! result index
                             (if negative? (+ raw base) raw))
                (loop (+ index 1) (if negative? 1 0)))))))

    (define (integer-add backend left right)
      "Add owned integers LEFT and RIGHT."
      (or
       (small-add-accelerator backend left right)
       (let ((left-sign (integer-sign left))
             (right-sign (integer-sign right))
             (left-limbs (integer-limbs backend left))
             (right-limbs (integer-limbs backend right)))
         (cond
          ((= left-sign 0) right)
          ((= right-sign 0) left)
          ((= left-sign right-sign)
           (integer-normalize
            backend
            left-sign
            (magnitude-add backend
                           left-limbs
                           right-limbs)))
          (else
           (let ((comparison
                  (magnitude-compare left-limbs right-limbs)))
             (cond
              ((= comparison 0) owned-zero)
              ((> comparison 0)
               (integer-normalize
                backend
                left-sign
                (magnitude-subtract backend
                                    left-limbs
                                    right-limbs)))
              (else
               (integer-normalize
                backend
                right-sign
                (magnitude-subtract backend
                                    right-limbs
                                    left-limbs))))))))))

    (define (integer-subtract backend left right)
      "Subtract owned integer RIGHT from LEFT."
      (integer-add backend left (integer-negate right)))

    (define (integer-multiply backend left right)
      "Multiply owned integers LEFT and RIGHT with schoolbook limbs."
      (or
       (small-multiply-accelerator backend left right)
       (if (or (integer-zero? left) (integer-zero? right))
           owned-zero
           (let* ((base (numeric-backend-limb-base backend))
                  (left-limbs (integer-limbs backend left))
                  (right-limbs (integer-limbs backend right))
                  (left-length (vector-length left-limbs))
                  (right-length (vector-length right-limbs))
                  (result (make-vector (+ left-length right-length) 0)))
             (let outer ((left-index 0))
               (if (< left-index left-length)
                   (begin
                     (let inner ((right-index 0) (carry 0))
                       (if (= right-index right-length)
                           (vector-set!
                            result
                            (+ left-index right-length)
                            carry)
                           (let* ((output-index (+ left-index right-index))
                                  (accumulator
                                   (+ (* (vector-ref left-limbs left-index)
                                         (vector-ref right-limbs right-index))
                                      (vector-ref result output-index)
                                      carry)))
                             (vector-set! result
                                          output-index
                                          (modulo accumulator base))
                             (inner (+ right-index 1)
                                    (quotient accumulator base)))))
                     (outer (+ left-index 1)))
                   (integer-normalize
                    backend
                    (* (integer-sign left)
                       (integer-sign right))
                    result)))))))

    (define (magnitude-multiply-small backend limbs factor)
      "Multiply magnitude LIMBS by small nonnegative FACTOR."
      (if (= factor 0)
          (vector)
          (let* ((base (numeric-backend-limb-base backend))
                 (length (vector-length limbs))
                 (result (make-vector (+ length 1) 0)))
            (let loop ((index 0) (carry 0))
              (if (= index length)
                  (begin
                    (vector-set! result index carry)
                    (normalize-limbs result))
                  (let ((accumulator
                         (+ (* (vector-ref limbs index) factor) carry)))
                    (vector-set! result index
                                 (modulo accumulator base))
                    (loop (+ index 1)
                          (quotient accumulator base))))))))

    (define (integer-multiply-small backend value factor)
      "Multiply owned integer VALUE by a small exact FACTOR."
      (cond
       ((or (integer-zero? value) (= factor 0)) owned-zero)
       ((< factor 0)
        (integer-negate
         (integer-multiply-small backend value (- factor))))
       (else
        (integer-normalize
         backend
         (integer-sign value)
         (magnitude-multiply-small backend
                                   (integer-limbs backend value)
                                   factor)))))

    (define (integer-add-small backend value addend)
      "Add small nonnegative ADDEND to nonnegative owned integer VALUE."
      (integer-add backend value (integer-from-small backend addend)))

    (define (magnitude-divide-small backend limbs divisor)
      "Divide magnitude LIMBS by positive small DIVISOR."
      (let* ((base (numeric-backend-limb-base backend))
             (length (vector-length limbs))
             (result (make-vector length 0)))
        (let loop ((index (- length 1)) (remainder 0))
          (if (< index 0)
              (cons (normalize-limbs result) remainder)
              (let* ((accumulator
                      (+ (* remainder base) (vector-ref limbs index)))
                     (digit (quotient accumulator divisor)))
                (vector-set! result index digit)
                (loop (- index 1)
                      (modulo accumulator divisor)))))))

    (define (integer-divide-small backend value divisor)
      "Divide owned integer VALUE by positive small DIVISOR."
      (let ((result
             (magnitude-divide-small backend
                                     (integer-limbs
                                      backend
                                      (integer-abs value))
                                     divisor)))
        (cons (integer-normalize
               backend (integer-sign value) (car result))
              (cdr result))))

    (define (small-bit-length value)
      "Return the number of significant bits in nonnegative small VALUE."
      (let loop ((remaining value) (bits 0))
        (if (= remaining 0)
            bits
            (loop (quotient remaining 2) (+ bits 1)))))

    (define (integer-bit-length backend value)
      "Return the magnitude bit length of owned integer VALUE."
      (let* ((limbs (integer-limbs backend value))
             (length (vector-length limbs)))
        (if (= length 0)
            0
            (+ (* (- length 1)
                  (consent-numeric-backend-limb-bits backend))
               (small-bit-length (vector-ref limbs (- length 1)))))))

    (define (integer-bit-ref backend value index)
      "Return bit INDEX from the magnitude of owned integer VALUE."
      (let* ((width (consent-numeric-backend-limb-bits backend))
             (limb-index (quotient index width))
             (bit-index (modulo index width))
             (limbs (integer-limbs backend value)))
        (if (>= limb-index (vector-length limbs))
            0
            (modulo
             (quotient (vector-ref limbs limb-index)
                       (small-power 2 bit-index))
             2))))

    (define (integer-shift-left backend value count)
      "Shift owned integer VALUE left by nonnegative bit COUNT."
      (if (or (integer-zero? value) (= count 0))
          value
          (let* ((width (consent-numeric-backend-limb-bits backend))
                 (whole (quotient count width))
                 (partial (modulo count width))
                 (source (integer-limbs backend value))
                 (scaled
                  (if (= partial 0)
                      source
                      (magnitude-multiply-small
                       backend source (small-power 2 partial))))
                 (result (make-vector (+ whole (vector-length scaled)) 0)))
            (let loop ((index 0))
              (if (= index (vector-length scaled))
                  (integer-normalize backend (integer-sign value) result)
                  (begin
                    (vector-set! result
                                 (+ whole index)
                                 (vector-ref scaled index))
                    (loop (+ index 1))))))))

    (define (integer-shift-right-truncate backend value count)
      "Shift nonnegative owned integer VALUE right by COUNT bits."
      (if (= count 0)
          value
          (let* ((width (consent-numeric-backend-limb-bits backend))
                 (base (numeric-backend-limb-base backend))
                 (whole (quotient count width))
                 (partial (modulo count width))
                 (source (integer-limbs backend value))
                 (source-length (vector-length source)))
            (if (>= whole source-length)
                owned-zero
                (let* ((length (- source-length whole))
                       (result (make-vector length 0))
                       (divisor (small-power 2 partial)))
                  (let loop ((source-index (- source-length 1))
                             (carry 0))
                    (if (< source-index whole)
                        (integer-normalize backend 1 result)
                        (let* ((accumulator
                                (+ (* carry base)
                                   (vector-ref source source-index)))
                               (target-index (- source-index whole)))
                          (vector-set!
                           result
                           target-index
                           (if (= partial 0)
                               accumulator
                               (quotient accumulator divisor)))
                          (loop
                           (- source-index 1)
                           (if (= partial 0)
                               0
                               (modulo accumulator divisor)))))))))))

    (define (integer-any-low-bit? backend value count)
      "Report whether VALUE has a set bit below bit index COUNT."
      (if (<= count 0)
          #f
          (let* ((width (consent-numeric-backend-limb-bits backend))
                 (whole (quotient count width))
                 (partial (modulo count width))
                 (limbs (integer-limbs backend value))
                 (length (vector-length limbs)))
            (let loop ((index 0))
              (cond
               ((and (< index whole) (< index length))
                (or (not (= (vector-ref limbs index) 0))
                    (loop (+ index 1))))
               ((and (> partial 0) (< whole length))
                (not (= (modulo (vector-ref limbs whole)
                                (small-power 2 partial))
                        0)))
               (else #f))))))

    (define (integer-round-shift-right backend value count)
      "Round nonnegative VALUE divided by 2^COUNT, ties to even."
      (if (<= count 0)
          (integer-shift-left backend value (- count))
          (let* ((quotient
                  (integer-shift-right-truncate backend value count))
                 (half? (= (integer-bit-ref backend value (- count 1)) 1))
                 (sticky?
                  (integer-any-low-bit? backend value (- count 1))))
            (if (and half?
                     (or sticky? (not (integer-even? quotient))))
                (integer-add backend
                             quotient
                             (integer-from-small backend 1))
                quotient))))

    (define (integer-set-bit! backend limbs index)
      "Set bit INDEX in mutable magnitude vector LIMBS."
      (let* ((width (consent-numeric-backend-limb-bits backend))
             (limb-index (quotient index width))
             (bit-index (modulo index width)))
        (vector-set! limbs
                     limb-index
                     (+ (vector-ref limbs limb-index)
                        (small-power 2 bit-index)))))

    (define (integer-divmod-positive backend dividend divisor)
      "Divide nonnegative owned integers using binary long division."
      (if (integer-zero? divisor)
          (error "owned integer division by zero"))
      (or
       (small-positive-divmod-accelerator backend dividend divisor)
       (if (< (integer-compare dividend divisor) 0)
           (cons owned-zero dividend)
           (let* ((bits (integer-bit-length backend dividend))
                  (width (consent-numeric-backend-limb-bits backend))
                  (quotient-limbs
                   (make-vector (quotient (+ bits (- width 1)) width) 0)))
             (let loop ((index (- bits 1)) (remainder owned-zero))
               (if (< index 0)
                   (cons
                    (integer-normalize backend 1 quotient-limbs)
                    remainder)
                   (let* ((doubled
                           (integer-multiply-small backend remainder 2))
                          (next
                           (if (= (integer-bit-ref backend dividend index) 0)
                               doubled
                               (integer-add-small backend doubled 1))))
                     (if (>= (integer-compare next divisor) 0)
                         (begin
                           (integer-set-bit! backend quotient-limbs index)
                           (loop (- index 1)
                                 (integer-subtract backend next divisor)))
                         (loop (- index 1) next)))))))))

    (define (integer-divmod-truncate backend dividend divisor)
      "Return truncating quotient and remainder for owned integers."
      (if (integer-zero? divisor)
          (error "owned integer division by zero"))
      (let* ((unsigned
              (integer-divmod-positive backend
                                       (integer-abs dividend)
                                       (integer-abs divisor)))
             (quotient
              (if (= (integer-sign dividend)
                     (integer-sign divisor))
                  (car unsigned)
                  (integer-negate (car unsigned))))
             (remainder
              (if (integer-negative? dividend)
                  (integer-negate (cdr unsigned))
                  (cdr unsigned))))
        (cons quotient remainder)))

    (define (integer-divmod-floor backend dividend divisor)
      "Return floor quotient and remainder for owned integers."
      (let* ((truncated
              (integer-divmod-truncate backend dividend divisor))
             (quotient (car truncated))
             (remainder (cdr truncated)))
        (if (or (integer-zero? remainder)
                (= (integer-sign dividend)
                   (integer-sign divisor)))
            truncated
            (cons (integer-subtract
                   backend quotient (integer-from-small backend 1))
                  (integer-add backend remainder divisor)))))

    (define (integer-gcd backend left right)
      "Return the nonnegative greatest common divisor of owned integers."
      (let loop ((a (integer-abs left)) (b (integer-abs right)))
        (if (integer-zero? b)
            a
            (loop b (cdr (integer-divmod-positive backend a b))))))

    (define (integer-even? value)
      "Report whether owned integer VALUE is even."
      (if (owned-fixnum? value)
          (= (modulo value 2) 0)
          (= (modulo (vector-ref (owned-bignum-limbs value) 0) 2) 0)))

    (define (integer-power backend base exponent)
      "Raise owned BASE to nonnegative owned integer EXPONENT."
      (if (integer-negative? exponent)
          (error "owned integer exponent must be nonnegative"))
      (let loop ((result (integer-from-small backend 1))
                 (factor base)
                 (power exponent))
        (if (integer-zero? power)
            result
            (let ((halved (integer-divide-small backend power 2)))
              (loop (if (= (cdr halved) 0)
                        result
                        (integer-multiply backend result factor))
                    (integer-multiply backend factor factor)
                    (car halved))))))

    (define (integer-square-root backend value)
      "Return root and remainder for nonnegative owned integer VALUE."
      (if (integer-negative? value)
          (error "owned integer square root expected nonnegative value"))
      (if (integer-zero? value)
          (cons owned-zero owned-zero)
          (let* ((bits (integer-bit-length backend value))
                 (one (integer-from-small backend 1))
                 (initial
                  (integer-shift-left backend one (quotient (+ bits 1) 2))))
            (let loop ((root initial))
              (let* ((division
                      (car (integer-divmod-positive backend value root)))
                     (next
                      (car
                       (integer-divide-small
                        backend
                        (integer-add backend root division)
                        2))))
                (if (>= (integer-compare next root) 0)
                    (cons root
                          (integer-subtract
                           backend
                           value
                           (integer-multiply backend root root)))
                    (loop next)))))))

    ;; Lowercase digits used by canonical radix rendering.
    (define digit-characters "0123456789abcdef")

    (define (numeric-digit-value character)
      "Return ASCII radix digit CHARACTER's value, or #f."
      (cond
       ((and (char>=? character #\0) (char<=? character #\9))
        (- (char->integer character) (char->integer #\0)))
       ((and (char>=? character #\a) (char<=? character #\f))
        (+ 10 (- (char->integer character) (char->integer #\a))))
       ((and (char>=? character #\A) (char<=? character #\F))
        (+ 10 (- (char->integer character) (char->integer #\A))))
       (else #f)))

    (define (supported-integer-radix? radix)
      "Report whether RADIX is one of the owned integer textual bases."
      (and (integer? radix)
           (exact? radix)
           (or (= radix 2)
               (= radix 8)
               (= radix 10)
               (= radix 16))))

    (define (integer-parse backend text radix)
      "Parse signed integer TEXT in RADIX without constructing a host bignum."
      (and
       (supported-integer-radix? radix)
       (let* ((length (string-length text))
              (negative?
               (and (> length 0) (char=? (string-ref text 0) #\-)))
              (signed?
               (and (> length 0)
                    (or negative? (char=? (string-ref text 0) #\+))))
              (start (if signed? 1 0)))
         (and (< start length)
              (let loop ((index start) (value owned-zero))
                (if (= index length)
                    (if negative? (integer-negate value) value)
                    (let ((digit
                           (numeric-digit-value (string-ref text index))))
                      (and digit
                           (< digit radix)
                           (loop
                            (+ index 1)
                            (integer-add-small
                             backend
                             (integer-multiply-small backend value radix)
                             digit))))))))))

    (define (integer->string backend value radix)
      "Render owned integer VALUE in RADIX."
      (if (not (supported-integer-radix? radix))
          (error "owned integer radix must be 2, 8, 10, or 16" radix))
      (let ((small
             (integer->small
              backend value (backend-small-accelerator-limit backend))))
        (if small
            (number->string small radix)
            (if (integer-zero? value)
                "0"
                (let loop ((remaining (integer-abs value))
                           (characters '()))
                  (if (integer-zero? remaining)
                      (let ((body (list->string characters)))
                        (if (integer-negative? value)
                            (string-append "-" body)
                            body))
                      (let ((division
                             (integer-divide-small
                              backend remaining radix)))
                        (loop
                         (car division)
                         (cons
                          (string-ref digit-characters (cdr division))
                          characters)))))))))

    (define (integer->small backend value maximum)
      "Convert owned VALUE to host integer when its magnitude is <= MAXIMUM."
      (if (owned-fixnum? value)
          (and (<= (abs value) maximum) value)
          (let* ((base (numeric-backend-limb-base backend))
                 (limbs (owned-bignum-limbs value))
                 (limit maximum))
            (let loop ((index (- (vector-length limbs) 1)) (result 0))
              (if (< index 0)
                  (if (integer-negative? value) (- result) result)
                  (let ((limb (vector-ref limbs index)))
                    (and (<= result (quotient (- limit limb) base))
                         (loop
                          (- index 1)
                          (+ (* result base) limb)))))))))

    (define (backend-small-accelerator-limit backend)
      "Return the profile-derived safe host accumulator maximum."
      (numeric-backend-accumulator-limit backend))

    (define (small-add-accelerator backend left right)
      "Add LEFT and RIGHT with checked profile-safe host fixnums, or return #f."
      (let* ((limit (backend-small-accelerator-limit backend))
             (left-small (integer->small backend left limit))
             (right-small (integer->small backend right limit)))
        (and left-small
             right-small
             (or (and (>= right-small 0)
                      (<= left-small (- limit right-small)))
                 (and (< right-small 0)
                      (>= left-small (- (- limit) right-small))))
             (integer-from-small backend (+ left-small right-small)))))

    (define (small-multiply-accelerator backend left right)
      "Multiply LEFT and RIGHT with checked profile-safe host fixnums."
      (let* ((limit (backend-small-accelerator-limit backend))
             (left-small (integer->small backend left limit))
             (right-small (integer->small backend right limit)))
        (and left-small
             right-small
             (or (= left-small 0)
                 (= right-small 0)
                 (<= (abs left-small)
                     (quotient limit (abs right-small))))
             (integer-from-small backend (* left-small right-small)))))

    (define (small-positive-divmod-accelerator backend dividend divisor)
      "Divide positive profile-safe host fixnums, or return #f."
      (let* ((limit (backend-small-accelerator-limit backend))
             (dividend-small (integer->small backend dividend limit))
             (divisor-small (integer->small backend divisor limit)))
        (and dividend-small
             divisor-small
             (cons
              (integer-from-small
               backend (quotient dividend-small divisor-small))
              (integer-from-small
               backend (modulo dividend-small divisor-small))))))

    (define (rational-normalize backend numerator denominator)
      "Normalize owned rational NUMERATOR and DENOMINATOR."
      (if (integer-zero? denominator)
          (error "owned rational denominator is zero"))
      (let* ((signed-numerator
              (if (integer-negative? denominator)
                  (integer-negate numerator)
                  numerator))
             (positive-denominator (integer-abs denominator)))
        (if (integer-zero? signed-numerator)
            (cons owned-zero (integer-from-small backend 1))
            (let ((divisor
                   (integer-gcd backend
                                (integer-abs signed-numerator)
                                positive-denominator)))
              (cons
               (car
                (integer-divmod-truncate
                 backend signed-numerator divisor))
               (car
                (integer-divmod-positive
                 backend positive-denominator divisor)))))))

    (define (rational-negate pair)
      "Negate normalized owned rational PAIR."
      (cons (integer-negate (car pair)) (cdr pair)))

    (define (rational-add backend left right)
      "Add normalized owned rational pairs LEFT and RIGHT."
      (let* ((left-numerator (car left))
             (left-denominator (cdr left))
             (right-numerator (car right))
             (right-denominator (cdr right))
             (common
              (integer-gcd backend left-denominator right-denominator))
             (left-scale
              (car
               (integer-divmod-positive
                backend right-denominator common)))
             (right-scale
              (car
               (integer-divmod-positive
                backend left-denominator common)))
             (numerator
              (integer-add
               backend
               (integer-multiply backend left-numerator left-scale)
               (integer-multiply backend right-numerator right-scale)))
             (denominator
              (integer-multiply backend left-denominator left-scale)))
        (rational-normalize backend numerator denominator)))

    (define (rational-subtract backend left right)
      "Subtract normalized owned rational pair RIGHT from LEFT."
      (rational-add backend left (rational-negate right)))

    (define (rational-multiply backend left right)
      "Multiply normalized owned rational pairs with cross cancellation."
      (let* ((left-numerator (car left))
             (left-denominator (cdr left))
             (right-numerator (car right))
             (right-denominator (cdr right))
             (first-gcd
              (integer-gcd backend
                           (integer-abs left-numerator)
                           right-denominator))
             (second-gcd
              (integer-gcd backend
                           (integer-abs right-numerator)
                           left-denominator))
             (reduced-left-numerator
              (car
               (integer-divmod-truncate
                backend left-numerator first-gcd)))
             (reduced-right-denominator
              (car
               (integer-divmod-positive
                backend right-denominator first-gcd)))
             (reduced-right-numerator
              (car
               (integer-divmod-truncate
                backend right-numerator second-gcd)))
             (reduced-left-denominator
              (car
               (integer-divmod-positive
                backend left-denominator second-gcd))))
        (rational-normalize
         backend
         (integer-multiply
          backend reduced-left-numerator reduced-right-numerator)
         (integer-multiply
          backend reduced-left-denominator reduced-right-denominator))))

    (define (rational-divide backend left right)
      "Divide normalized owned rational pair LEFT by RIGHT."
      (if (integer-zero? (car right))
          (error "owned rational division by zero"))
      (rational-multiply
       backend
       left
       (rational-normalize backend (cdr right) (car right))))

    (define (rational-compare backend left right)
      "Compare normalized owned rational pairs LEFT and RIGHT."
      (integer-compare
       (integer-multiply backend (car left) (cdr right))
       (integer-multiply backend (car right) (cdr left))))

    (define (rational-round backend pair mode)
      "Round normalized rational PAIR according to MODE."
      (let* ((numerator (car pair))
             (denominator (cdr pair))
             (truncated
              (integer-divmod-truncate backend numerator denominator))
             (quotient (car truncated))
             (remainder (cdr truncated)))
        (case mode
          ((truncate) quotient)
          ((floor)
           (if (and (integer-negative? numerator)
                    (not (integer-zero? remainder)))
               (integer-subtract
                backend quotient (integer-from-small backend 1))
               quotient))
          ((ceiling)
           (if (and (integer-positive? numerator)
                    (not (integer-zero? remainder)))
               (integer-add backend quotient (integer-from-small backend 1))
               quotient))
          ((round)
           (let* ((absolute-remainder (integer-abs remainder))
                  (twice
                   (integer-multiply-small
                    backend absolute-remainder 2))
                  (comparison
                   (integer-compare twice denominator)))
             (if (or (< comparison 0)
                     (and (= comparison 0) (integer-even? quotient)))
                 quotient
                 (integer-add
                  backend
                  quotient
                  (integer-from-small
                   backend
                   (if (integer-negative? numerator) -1 1))))))
          (else (error "unknown owned rational rounding mode" mode)))))

    (define (integer-power-small backend base exponent)
      "Raise small nonnegative BASE to host integer EXPONENT as owned integer."
      (integer-power backend
                     (integer-from-small backend base)
                     (integer-from-small backend exponent)))

    ;; The inexact implementation follows below.  Keeping it in this library
    ;; lets exact and inexact comparison share one owned rational substrate.

    (define (binary64-zero backend)
      "Return canonical positive binary64 zero."
      (make-owned-binary64
       'finite 1 (integer-from-small backend 0) 0 #f))

    (define (binary64-special backend class sign)
      "Construct a canonical binary64 infinity or NaN."
      (if (not (or (eq? class 'infinity) (eq? class 'nan)))
          (error "owned binary64 special class must be infinity or nan"
                 class))
      (if (not (or (= sign -1) (= sign 1)))
          (error "owned binary64 sign must be -1 or 1" sign))
      (make-owned-binary64 class
                           (if (eq? class 'nan) 1 sign)
                           (integer-from-small backend 0)
                           0
                           #f))

    (define (binary64-zero? value)
      "Report whether owned binary64 VALUE is finite zero."
      (and (eq? (owned-binary64-class value) 'finite)
           (integer-zero? (owned-binary64-significand value))))

    (define (binary64-negative? value)
      "Report whether owned binary64 VALUE is negative."
      (and (not (eq? (owned-binary64-class value) 'nan))
           (< (owned-binary64-sign value) 0)
           (not (binary64-zero? value))))

    (define (binary64-negate backend value)
      "Return owned binary64 VALUE with its sign reversed."
      (if (or (eq? (owned-binary64-class value) 'nan)
              (binary64-zero? value))
          value
          (make-owned-binary64
           (owned-binary64-class value)
           (- (owned-binary64-sign value))
           (owned-binary64-significand value)
           (owned-binary64-exponent value)
           #f)))

    (define (integer-compare-shifted backend left right shift)
      "Compare LEFT with RIGHT shifted left by signed host bit count SHIFT."
      (if (>= shift 0)
          (integer-compare left
                           (integer-shift-left backend right shift))
          (integer-compare
           (integer-shift-left backend left (- shift))
           right)))

    (define (rational-binary-exponent backend numerator denominator)
      "Return floor(log2(NUMERATOR / DENOMINATOR)) for positive operands."
      (let* ((guess
              (- (integer-bit-length backend numerator)
                 (integer-bit-length backend denominator)))
             (comparison
              (integer-compare-shifted
               backend numerator denominator guess)))
        (if (< comparison 0) (- guess 1) guess)))

    (define (round-positive-ratio backend numerator denominator)
      "Round positive owned ratio NUMERATOR/DENOMINATOR to nearest integer."
      (let* ((division
              (integer-divmod-positive backend numerator denominator))
             (quotient (car division))
             (remainder (cdr division))
             (comparison
              (integer-compare
               (integer-multiply-small backend remainder 2)
               denominator)))
        (if (or (> comparison 0)
                (and (= comparison 0)
                     (not (integer-even? quotient))))
            (integer-add backend quotient
                         (integer-from-small backend 1))
            quotient)))

    (define (round-scaled-ratio backend numerator denominator shift)
      "Round NUMERATOR/DENOMINATOR multiplied by 2^SHIFT."
      (if (>= shift 0)
          (round-positive-ratio
           backend
           (integer-shift-left backend numerator shift)
           denominator)
          (round-positive-ratio
           backend
           numerator
           (integer-shift-left backend denominator (- shift)))))

    (define (binary64-from-rational backend pair)
      "Round normalized owned rational PAIR into an owned binary64 value."
      (let ((numerator (car pair))
            (denominator (cdr pair)))
        (if (integer-zero? numerator)
            (binary64-zero backend)
            (let* ((sign (if (integer-negative? numerator) -1 1))
                   (absolute (integer-abs numerator))
                   (binary-exponent
                    (rational-binary-exponent
                     backend absolute denominator)))
              (cond
               ((> binary-exponent 1023)
                (binary64-special backend 'infinity sign))
               ((>= binary-exponent -1022)
                (let* ((significand
                        (round-scaled-ratio
                         backend
                         absolute
                         denominator
                         (- 52 binary-exponent)))
                       (two-to-53
                        (integer-shift-left
                         backend (integer-from-small backend 1) 53)))
                  (if (= (integer-compare significand two-to-53) 0)
                      (let ((adjusted-exponent (+ binary-exponent 1)))
                        (if (> adjusted-exponent 1023)
                            (binary64-special backend 'infinity sign)
                            (make-owned-binary64
                             'finite
                             sign
                             (car
                              (integer-divide-small
                               backend significand 2))
                             (- adjusted-exponent 52)
                             #f)))
                      (make-owned-binary64
                       'finite
                       sign
                       significand
                       (- binary-exponent 52)
                       #f))))
               (else
                (let ((significand
                       (round-scaled-ratio
                        backend absolute denominator 1074)))
                  (if (integer-zero? significand)
                      (binary64-zero backend)
                      (make-owned-binary64
                       'finite sign significand -1074 #f)))))))))

    (define (binary64-from-dyadic backend signed-significand exponent)
      "Round SIGNED-SIGNIFICAND * 2^EXPONENT into owned binary64."
      (if (integer-zero? signed-significand)
          (binary64-zero backend)
          (let* ((sign
                  (if (integer-negative? signed-significand) -1 1))
                 (absolute (integer-abs signed-significand))
                 (bits (integer-bit-length backend absolute))
                 (binary-exponent (+ (- bits 1) exponent)))
            (cond
             ((> binary-exponent 1023)
              (binary64-special backend 'infinity sign))
             ((>= binary-exponent -1022)
              (let* ((shift (- bits 53))
                     (significand
                      (integer-round-shift-right
                       backend absolute shift))
                     (stored-exponent (+ exponent shift))
                     (two-to-53
                      (integer-shift-left
                       backend (integer-from-small backend 1) 53)))
                (if (= (integer-compare significand two-to-53) 0)
                    (if (> (+ binary-exponent 1) 1023)
                        (binary64-special backend 'infinity sign)
                        (make-owned-binary64
                         'finite
                         sign
                         (integer-shift-right-truncate
                          backend significand 1)
                         (+ stored-exponent 1)
                         #f))
                    (make-owned-binary64
                     'finite sign significand stored-exponent #f))))
             (else
              (let* ((shift (- (+ exponent 1074)))
                     (significand
                      (integer-round-shift-right
                       backend absolute shift)))
                (if (integer-zero? significand)
                    (binary64-zero backend)
                    (make-owned-binary64
                     'finite sign significand -1074 #f))))))))

    (define (binary64-signed-significand value)
      "Return finite binary64 VALUE's signed owned significand."
      (if (< (owned-binary64-sign value) 0)
          (integer-negate (owned-binary64-significand value))
          (owned-binary64-significand value)))

    (define (binary64-finite-add backend left right)
      "Add finite owned binary64 values without rational expansion."
      (let* ((left-exponent (owned-binary64-exponent left))
             (right-exponent (owned-binary64-exponent right))
             (common-exponent (min left-exponent right-exponent))
             (left-significand
              (integer-shift-left
               backend
               (binary64-signed-significand left)
               (- left-exponent common-exponent)))
             (right-significand
              (integer-shift-left
               backend
               (binary64-signed-significand right)
               (- right-exponent common-exponent))))
        (binary64-from-dyadic
         backend
         (integer-add backend left-significand right-significand)
         common-exponent)))

    (define (binary64-finite-multiply backend left right)
      "Multiply finite owned binary64 values without rational expansion."
      (binary64-from-dyadic
       backend
       (integer-multiply
        backend
        (binary64-signed-significand left)
        (binary64-signed-significand right))
       (+ (owned-binary64-exponent left)
          (owned-binary64-exponent right))))

    (define (binary64-finite-divide backend left right)
      "Divide finite nonzero binary64 values with exact ratio rounding."
      (let* ((exponent
              (- (owned-binary64-exponent left)
                 (owned-binary64-exponent right)))
             (numerator (binary64-signed-significand left))
             (denominator (owned-binary64-significand right))
             (signed-numerator
              (if (< (owned-binary64-sign right) 0)
                  (integer-negate numerator)
                  numerator)))
        (binary64-from-rational
         backend
         (if (>= exponent 0)
             (cons (integer-shift-left
                    backend signed-numerator exponent)
                   denominator)
             (cons signed-numerator
                   (integer-shift-left
                    backend denominator (- exponent)))))))

    (define (binary64->rational backend value)
      "Return finite owned binary64 VALUE as an exact normalized rational."
      (if (not (eq? (owned-binary64-class value) 'finite))
          (error "special binary64 value has no exact rational"))
      ;; A binary64 significand has at most 53 bits. Reduce its dyadic ratio by
      ;; stripping powers of two from that small value instead of invoking the
      ;; general big-integer GCD against a denominator as large as 2^1074.
      (let reduce ((significand (owned-binary64-significand value))
                   (exponent (owned-binary64-exponent value)))
        (cond
         ((integer-zero? significand)
          (cons owned-zero (integer-from-small backend 1)))
         ((and (< exponent 0) (integer-even? significand))
          (reduce
           (car (integer-divide-small backend significand 2))
           (+ exponent 1)))
         (else
          (let ((signed
                 (if (< (owned-binary64-sign value) 0)
                     (integer-negate significand)
                     significand)))
            (if (>= exponent 0)
                (cons
                 (integer-shift-left backend signed exponent)
                 (integer-from-small backend 1))
                (cons
                 signed
                 (integer-shift-left
                  backend
                  (integer-from-small backend 1)
                  (- exponent)))))))))

    (define (binary64-equal? left right)
      "Report whether owned binary64 values have identical canonical tuples."
      (and (eq? (owned-binary64-class left)
                (owned-binary64-class right))
           (= (owned-binary64-sign left)
              (owned-binary64-sign right))
           (= (owned-binary64-exponent left)
              (owned-binary64-exponent right))
           (= (integer-compare
               (owned-binary64-significand left)
               (owned-binary64-significand right))
              0)))

    (define (binary64-binary backend left right operation)
      "Apply finite and special binary64 arithmetic OPERATION."
      (let ((left-class (owned-binary64-class left))
            (right-class (owned-binary64-class right)))
        (cond
         ((or (eq? left-class 'nan) (eq? right-class 'nan))
          (binary64-special backend 'nan 1))
         ((eq? operation '+)
          (cond
           ((and (eq? left-class 'infinity)
                 (eq? right-class 'infinity))
            (if (= (owned-binary64-sign left)
                   (owned-binary64-sign right))
                left
                (binary64-special backend 'nan 1)))
           ((eq? left-class 'infinity) left)
           ((eq? right-class 'infinity) right)
           (else
            (binary64-finite-add backend left right))))
         ((eq? operation '-)
          (binary64-binary
           backend left (binary64-negate backend right) '+))
         ((eq? operation '*)
          (let ((sign
                 (* (owned-binary64-sign left)
                    (owned-binary64-sign right))))
            (cond
             ((or (and (eq? left-class 'infinity)
                       (binary64-zero? right))
                  (and (eq? right-class 'infinity)
                       (binary64-zero? left)))
              (binary64-special backend 'nan 1))
             ((or (eq? left-class 'infinity)
                  (eq? right-class 'infinity))
              (binary64-special backend 'infinity sign))
             (else
              (binary64-finite-multiply backend left right)))))
         ((eq? operation '/)
          (let ((sign
                 (* (owned-binary64-sign left)
                    (owned-binary64-sign right))))
            (cond
             ((and (eq? left-class 'infinity)
                   (eq? right-class 'infinity))
              (binary64-special backend 'nan 1))
             ((eq? left-class 'infinity)
              (binary64-special backend 'infinity sign))
             ((eq? right-class 'infinity)
              (binary64-zero backend))
             ((binary64-zero? right)
              (if (binary64-zero? left)
                  (binary64-special backend 'nan 1)
                  (binary64-special backend 'infinity sign)))
             (else
              (binary64-finite-divide backend left right)))))
         (else
          (error "unknown owned binary64 operation" operation)))))

    (define (binary64-compare backend left right)
      "Compare owned binary64 values, returning #f when either is NaN."
      (let ((left-class (owned-binary64-class left))
            (right-class (owned-binary64-class right)))
        (cond
         ((or (eq? left-class 'nan) (eq? right-class 'nan)) #f)
         ((and (eq? left-class 'infinity)
               (eq? right-class 'infinity))
          (cond
           ((< (owned-binary64-sign left)
               (owned-binary64-sign right))
            -1)
           ((> (owned-binary64-sign left)
               (owned-binary64-sign right))
            1)
           (else 0)))
         ((eq? left-class 'infinity)
          (owned-binary64-sign left))
         ((eq? right-class 'infinity)
          (- (owned-binary64-sign right)))
         (else
          (cond
           ((and (binary64-zero? left) (binary64-zero? right)) 0)
           ((binary64-zero? left)
            (- (owned-binary64-sign right)))
           ((binary64-zero? right)
            (owned-binary64-sign left))
           ((< (owned-binary64-sign left)
               (owned-binary64-sign right))
            -1)
           ((> (owned-binary64-sign left)
               (owned-binary64-sign right))
            1)
           (else
            (let* ((left-significand
                    (owned-binary64-significand left))
                   (right-significand
                    (owned-binary64-significand right))
                   (left-top
                    (+ (integer-bit-length backend left-significand)
                       (owned-binary64-exponent left)))
                   (right-top
                    (+ (integer-bit-length backend right-significand)
                       (owned-binary64-exponent right)))
                   (magnitude-comparison
                    (cond
                     ((< left-top right-top) -1)
                     ((> left-top right-top) 1)
                     (else
                      (integer-compare-shifted
                       backend
                       left-significand
                       right-significand
                       (- (owned-binary64-exponent right)
                          (owned-binary64-exponent left)))))))
              (* (owned-binary64-sign left)
                 magnitude-comparison))))))))

    (define (decimal-power backend exponent)
      "Return owned 10^EXPONENT for nonnegative host EXPONENT."
      (integer-power-small backend 10 exponent))

    (define (rational-decimal-exponent backend numerator denominator)
      "Return floor(log10(NUMERATOR / DENOMINATOR)) for positive operands."
      (let* ((numerator-digits
              (string-length (integer->string backend numerator 10)))
             (denominator-digits
              (string-length (integer->string backend denominator 10)))
             (guess (- numerator-digits denominator-digits))
             (comparison
              (if (>= guess 0)
                  (integer-compare
                   numerator
                   (integer-multiply
                    backend denominator (decimal-power backend guess)))
                  (integer-compare
                   (integer-multiply
                    backend numerator (decimal-power backend (- guess)))
                   denominator))))
        (if (< comparison 0) (- guess 1) guess)))

    (define (round-decimal-significand
             backend numerator denominator digits exponent)
      "Round positive ratio to DIGITS decimal digits at EXPONENT."
      (let ((shift (- (- digits 1) exponent)))
        (if (>= shift 0)
            (round-positive-ratio
             backend
             (integer-multiply
              backend numerator (decimal-power backend shift))
             denominator)
            (round-positive-ratio
             backend
             numerator
             (integer-multiply
              backend denominator (decimal-power backend (- shift)))))))

    (define (left-pad-zero text length)
      "Pad TEXT on the left with zeroes to LENGTH."
      (if (>= (string-length text) length)
          text
          (left-pad-zero (string-append "0" text) length)))

    (define (trim-decimal-zeroes text)
      "Trim trailing zeroes while retaining at least one digit."
      (let loop ((length (string-length text)))
        (if (and (> length 1)
                 (char=? (string-ref text (- length 1)) #\0))
            (loop (- length 1))
            (substring text 0 length))))

    (define (format-decimal-candidate digits exponent)
      "Format significant decimal DIGITS with base-ten EXPONENT."
      (let* ((trimmed (trim-decimal-zeroes digits))
             (length (string-length trimmed)))
        (cond
         ((and (>= exponent -4) (< exponent length))
          (if (>= exponent 0)
              (let ((point (+ exponent 1)))
                (if (= point length)
                    (string-append trimmed ".0")
                    (string-append
                     (substring trimmed 0 point)
                     "."
                     (substring trimmed point length))))
              (string-append
               "0."
               (make-string (- (- exponent) 1) #\0)
               trimmed)))
         (else
          (string-append
           (substring trimmed 0 1)
           (if (= length 1)
               ""
               (string-append "." (substring trimmed 1 length)))
           "e"
           (if (>= exponent 0) "+" "")
           (number->string exponent))))))

    (define (decimal-text->rational backend text)
      "Parse finite decimal TEXT into an owned rational pair."
      (let* ((length (string-length text))
             (negative?
              (and (> length 0) (char=? (string-ref text 0) #\-)))
             (signed?
              (and (> length 0)
                   (or negative? (char=? (string-ref text 0) #\+))))
             (start (if signed? 1 0)))
        (let loop ((index start)
                   (digits '())
                   (fraction-digits 0)
                   (after-point? #f))
          (cond
           ((= index length)
            (and
             (pair? digits)
             (let ((integer
                    (integer-parse
                     backend
                     (list->string (reverse digits))
                     10)))
               (and integer
                    (rational-normalize
                     backend
                     (if negative? (integer-negate integer) integer)
                     (decimal-power backend fraction-digits))))))
           ((or (char=? (string-ref text index) #\e)
                (char=? (string-ref text index) #\E))
            (let* ((exponent-text
                    (substring text (+ index 1) length))
                   (exponent (string->number exponent-text)))
              (and (pair? digits)
                   exponent
                   (exact? exponent)
                   (integer? exponent)
                   (let* ((integer
                           (integer-parse
                            backend
                            (list->string (reverse digits))
                            10))
                          (scale (- exponent fraction-digits)))
                     (and integer
                          (if (>= scale 0)
                              (rational-normalize
                               backend
                               (integer-multiply
                                backend
                                (if negative?
                                    (integer-negate integer)
                                    integer)
                                (decimal-power backend scale))
                               (integer-from-small backend 1))
                              (rational-normalize
                               backend
                               (if negative?
                                   (integer-negate integer)
                                   integer)
                               (decimal-power backend (- scale)))))))))
           ((char=? (string-ref text index) #\.)
            (and (not after-point?)
                 (loop (+ index 1)
                       digits
                       fraction-digits
                       #t)))
           ((numeric-digit-value (string-ref text index))
            => (lambda (digit)
                 (and (< digit 10)
                      (loop (+ index 1)
                            (cons (string-ref text index) digits)
                            (if after-point?
                                (+ fraction-digits 1)
                                fraction-digits)
                            after-point?))))
           (else #f)))))

    (define (binary64-parse backend text)
      "Parse finite decimal TEXT into an owned binary64 value."
      (let ((pair (decimal-text->rational backend text)))
        (and pair (binary64-from-rational backend pair))))

    (define (binary64->string backend value)
      "Render owned binary64 VALUE to a shortest round-tripping decimal."
      (case (owned-binary64-class value)
        ((nan) "+nan.0")
        ((infinity)
         (if (< (owned-binary64-sign value) 0) "-inf.0" "+inf.0"))
        (else
         (if (binary64-zero? value)
             "0.0"
             (let* ((pair (binary64->rational backend value))
                    (negative? (integer-negative? (car pair)))
                    (numerator (integer-abs (car pair)))
                    (denominator (cdr pair))
                    (initial-exponent
                     (rational-decimal-exponent
                      backend numerator denominator)))
               (let loop ((digits 1) (exponent initial-exponent))
                 (if (> digits 17)
                     (error "binary64 shortest rendering failed" value)
                     (let* ((rounded
                             (round-decimal-significand
                              backend numerator denominator digits exponent))
                            (limit (decimal-power backend digits))
                            (carried?
                             (= (integer-compare rounded limit) 0))
                            (adjusted
                             (if carried?
                                 (car
                                  (integer-divide-small
                                   backend rounded 10))
                                 rounded))
                            (adjusted-exponent
                             (if carried? (+ exponent 1) exponent))
                            (body
                             (format-decimal-candidate
                              (left-pad-zero
                               (integer->string backend adjusted 10)
                               digits)
                              adjusted-exponent))
                            (candidate
                             (if negative?
                                 (string-append "-" body)
                                 body))
                            (parsed (binary64-parse backend candidate)))
                       (if (and parsed (binary64-equal? parsed value))
                           candidate
                           (loop (+ digits 1)
                                 adjusted-exponent))))))))))

    (define (binary64->host backend value)
      "Convert owned binary64 VALUE at the temporary host math seam."
      (case (owned-binary64-class value)
        ((nan) (/ 0.0 0.0))
        ((infinity)
         (/ (if (< (owned-binary64-sign value) 0) -1.0 1.0) 0.0))
        (else
         (or (owned-binary64-host-cache value)
             (let ((significand
                    (integer->small
                     backend
                     (owned-binary64-significand value)
                     9007199254740991)))
               (if (not significand)
                   (error
                    "owned binary64 significand exceeds 53-bit host seam"
                    value))
               (let ((magnitude
                      (* (inexact significand)
                         (expt 2.0 (owned-binary64-exponent value)))))
                 (if (< (owned-binary64-sign value) 0)
                     (- magnitude)
                     magnitude)))))))

    ;; Powers used only by the borrowed-host binary64 decoder. They are private
    ;; accelerator constants, not integer-limb or language-visible payloads.
    (define host-two-to-52 (expt 2.0 52))
    ;; Large finite scaling step for borrowed-host binary64 normalization.
    (define host-two-to-256 (expt 2.0 256))
    ;; Reciprocal scaling step for tiny borrowed-host binary64 values.
    (define host-two-to-minus-256 (/ 1.0 host-two-to-256))

    (define (host-finite->binary64 backend value)
      "Decode finite host binary64 VALUE into the owned semantic tuple."
      (if (= value 0.0)
          (make-owned-binary64
           'finite 1 (integer-from-small backend 0) 0 value)
          (let ((sign (if (< value 0.0) -1 1)))
            (let normalize ((scaled (abs value)) (exponent 0))
              (cond
               ((>= scaled host-two-to-256)
                (normalize (/ scaled host-two-to-256)
                           (+ exponent 256)))
               ((< scaled host-two-to-minus-256)
                (normalize (* scaled host-two-to-256)
                           (- exponent 256)))
               ((>= scaled 2.0)
                (normalize (/ scaled 2.0) (+ exponent 1)))
               ((< scaled 1.0)
                (normalize (* scaled 2.0) (- exponent 1)))
               ((>= exponent -1022)
                (make-owned-binary64
                 'finite
                 sign
                 (integer-import-host
                  backend
                  (exact (truncate (* scaled host-two-to-52))))
                 (- exponent 52)
                 value))
               (else
                (make-owned-binary64
                 'finite
                 sign
                 (integer-import-host
                  backend
                  (exact
                   (truncate
                    (* scaled (expt 2.0 (+ exponent 1074))))))
                 -1074
                 value)))))))

    (define (host->binary64 backend value)
      "Normalize a host inexact VALUE into owned binary64 storage."
      (cond
       ((not (= value value)) (binary64-special backend 'nan 1))
       ((= value (/ 1.0 0.0))
        (binary64-special backend 'infinity 1))
       ((= value (/ -1.0 0.0))
        (binary64-special backend 'infinity -1))
       (else
        (host-finite->binary64 backend value))))

    (define (integer-import-host backend value)
      "Import a host exact integer through a bounded or textual adapter."
      (if (<= (abs value) (backend-small-accelerator-limit backend))
          (integer-from-small backend value)
          (or (integer-parse backend (number->string value) 10)
              (error "cannot import host exact integer" value))))

    (define (consent-numeric backend operation . arguments)
      "Apply owned numeric OPERATION under BACKEND to ARGUMENTS."
      "This internal runtime interface centralizes exact limbs, rationals, and"
      "binary64 tuples. Unsupported operations raise an error."
      #((parameters
         (backend (type numeric-backend)
          (description "Fixed-profile backend that owns all operands."))
         (operation (type symbol)
          (description "Backend operation name."))
         (arguments (type list)
          (description "Operation-specific operand list.")))
        (returns (type any)
         (description "Operation-specific owned numeric result."))
        (effects error allocation))
      (if (not (consent-numeric-backend? backend))
          (error "consent-numeric expected a numeric backend" backend))
      (case operation
        ((integer?) (owned-integer? (car arguments)))
        ((integer-fixnum?) (owned-fixnum? (car arguments)))
        ((integer-zero) owned-zero)
        ((integer-from-small)
         (integer-from-small backend (car arguments)))
        ((integer-import-host)
         (integer-import-host backend (car arguments)))
        ((integer-parse)
         (integer-parse backend (car arguments) (cadr arguments)))
        ((integer->string)
         (integer->string backend (car arguments) (cadr arguments)))
        ((integer->small)
         (integer->small backend (car arguments) (cadr arguments)))
        ((integer-zero?) (integer-zero? (car arguments)))
        ((integer-negative?) (integer-negative? (car arguments)))
        ((integer-positive?) (integer-positive? (car arguments)))
        ((integer-even?) (integer-even? (car arguments)))
        ((integer-abs) (integer-abs (car arguments)))
        ((integer-negate) (integer-negate (car arguments)))
        ((integer-compare)
         (integer-compare (car arguments) (cadr arguments)))
        ((integer-add)
         (integer-add backend (car arguments) (cadr arguments)))
        ((integer-subtract)
         (integer-subtract backend (car arguments) (cadr arguments)))
        ((integer-multiply)
         (integer-multiply backend (car arguments) (cadr arguments)))
        ((integer-multiply-small)
         (integer-multiply-small backend
                                 (car arguments)
                                 (cadr arguments)))
        ((integer-shift-left)
         (integer-shift-left backend
                             (car arguments)
                             (cadr arguments)))
        ((integer-divmod-truncate)
         (integer-divmod-truncate backend
                                  (car arguments)
                                  (cadr arguments)))
        ((integer-divmod-floor)
         (integer-divmod-floor backend
                               (car arguments)
                               (cadr arguments)))
        ((integer-gcd)
         (integer-gcd backend (car arguments) (cadr arguments)))
        ((integer-power)
         (integer-power backend (car arguments) (cadr arguments)))
        ((integer-square-root)
         (integer-square-root backend (car arguments)))
        ((rational-normalize)
         (rational-normalize backend (car arguments) (cadr arguments)))
        ((rational-add)
         (rational-add backend (car arguments) (cadr arguments)))
        ((rational-subtract)
         (rational-subtract backend (car arguments) (cadr arguments)))
        ((rational-multiply)
         (rational-multiply backend (car arguments) (cadr arguments)))
        ((rational-divide)
         (rational-divide backend (car arguments) (cadr arguments)))
        ((rational-compare)
         (rational-compare backend (car arguments) (cadr arguments)))
        ((rational-round)
         (rational-round backend (car arguments) (cadr arguments)))
        ((binary64?) (owned-binary64? (car arguments)))
        ((binary64-zero) (binary64-zero backend))
        ((binary64-special)
         (binary64-special backend (car arguments) (cadr arguments)))
        ((binary64-class) (owned-binary64-class (car arguments)))
        ((binary64-sign) (owned-binary64-sign (car arguments)))
        ((binary64-zero?) (binary64-zero? (car arguments)))
        ((binary64-negative?) (binary64-negative? (car arguments)))
        ((binary64-equal?)
         (binary64-equal? (car arguments) (cadr arguments)))
        ((binary64-negate)
         (binary64-negate backend (car arguments)))
        ((binary64-from-rational)
         (binary64-from-rational backend (car arguments)))
        ((binary64->rational)
         (binary64->rational backend (car arguments)))
        ((binary64-binary)
         (binary64-binary backend
                          (car arguments)
                          (cadr arguments)
                          (car (cddr arguments))))
        ((binary64-compare)
         (binary64-compare backend (car arguments) (cadr arguments)))
        ((binary64-parse)
         (binary64-parse backend (car arguments)))
        ((binary64->string)
         (binary64->string backend (car arguments)))
        ((binary64->host)
         (binary64->host backend (car arguments)))
        ((binary64-import-host)
         (host->binary64 backend (car arguments)))
        (else
         (error "unknown consent numeric operation" operation))))))
