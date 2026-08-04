;;; SRFI 194 random data generator stdlib support.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2020 Arvydas Silanskas
;; SPDX-FileCopyrightText: 2020 Bradley Lucier
;; SPDX-FileCopyrightText: 2020 Linas Vepštas
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib random-data-generators)' as a portable R7RS adaptation
;;; of the official SRFI 194 sample implementation:
;;; https://github.com/scheme-requests-for-implementation/srfi-194.
;;; Local patches wrap the source in Consent Scheme's stdlib namespace, replace
;;; SRFI 133 vector helpers with local portable loops, import the already
;;; shipped `(stdlib random-bits)' and `(stdlib generator)' dependencies, and
;;; expose `(srfi 194)' and `(srfi srfi-194)' as registry aliases.

(define-library (stdlib random-data-generators)
  (export clamp-real-number
          current-random-source
          with-random-source
          make-random-source-generator
          make-random-integer-generator
          make-random-u1-generator
          make-random-u8-generator
          make-random-s8-generator
          make-random-u16-generator
          make-random-s16-generator
          make-random-u32-generator
          make-random-s32-generator
          make-random-u64-generator
          make-random-s64-generator
          make-random-real-generator
          make-random-rectangular-generator
          make-random-polar-generator
          make-random-boolean-generator
          make-random-char-generator
          make-random-string-generator
          make-bernoulli-generator
          make-binomial-generator
          make-categorical-generator
          make-normal-generator
          make-exponential-generator
          make-geometric-generator
          make-poisson-generator
          make-zipf-generator
          make-sphere-generator
          make-ellipsoid-generator
          make-ball-generator
          gsampling)
  (import (scheme base)
          (scheme case-lambda)
          (scheme inexact)
          (scheme complex)
          (stdlib random-bits)
          (stdlib generator))
  (begin
    ;; Current random source used when constructing SRFI 194 generators.
    (define current-random-source (make-parameter default-random-source))

    (define (%random-data-unspecified)
      "Return the R7RS unspecified value."
      (if #f #f))

    (define (%random-data-exact-integer? value)
      "Return #t when VALUE is an exact integer."
      (and (integer? value) (exact? value)))

    (define (%random-data-exact-non-negative-integer? value)
      "Return #t when VALUE is an exact non-negative integer."
      (and (%random-data-exact-integer? value) (not (negative? value))))

    (define (%random-data-exact-positive-integer? value)
      "Return #t when VALUE is an exact positive integer."
      (and (%random-data-exact-integer? value) (positive? value)))

    (define (%random-data-finite-real? value)
      "Return #t when VALUE is a finite real number."
      (and (real? value) (finite? value)))

    (define (%random-data-positive-finite-real? value)
      "Return #t when VALUE is a positive finite real number."
      (and (%random-data-finite-real? value) (positive? value)))

    (define (%random-data-square value)
      "Return VALUE multiplied by itself."
      (* value value))

    (define (%random-data-log1p x)
      "Return `log(1 + X)' with better precision for small X."
      (let ((u (+ 1.0 x)))
        (cond
         ((= u 1.0) x)
         ((= u x) (log u))
         (else (* (log u) (/ x (- u 1.0)))))))

    (define (%random-data-vector-fold proc seed vector)
      "Fold PROC over VECTOR from left to right starting with SEED."
      (let loop ((index 0) (state seed))
        (if (= index (vector-length vector))
            state
            (loop (+ index 1)
                  (proc state (vector-ref vector index))))))

    (define (%random-data-vector-fold2 proc seed left right)
      "Fold PROC over LEFT and RIGHT from left to right starting with SEED."
      (let ((length (min (vector-length left) (vector-length right))))
        (let loop ((index 0) (state seed))
          (if (= index length)
            state
            (loop (+ index 1)
                  (proc state
                        (vector-ref left index)
                        (vector-ref right index)))))))

    (define (%random-data-vector-every pred vector)
      "Return #t when PRED is true for every element of VECTOR."
      (let loop ((index 0))
        (cond
         ((= index (vector-length vector)) #t)
         ((pred (vector-ref vector index)) (loop (+ index 1)))
         (else #f))))

    (define (%random-data-vector-map proc vector)
      "Map PROC over VECTOR and return a fresh vector."
      (let* ((length (vector-length vector))
             (result (make-vector length)))
        (do ((index 0 (+ index 1)))
            ((= index length) result)
          (vector-set! result index (proc (vector-ref vector index))))))

    (define (%random-data-vector-map2 proc left right)
      "Map PROC over LEFT and RIGHT and return a fresh vector."
      (let* ((length (min (vector-length left) (vector-length right)))
             (result (make-vector length)))
        (do ((index 0 (+ index 1)))
            ((= index length) result)
          (vector-set! result
                       index
                       (proc (vector-ref left index)
                             (vector-ref right index))))))

    (define (%random-data-remove-vector-index vector removed-index)
      "Return VECTOR without the element at REMOVED-INDEX."
      (let* ((old-length (vector-length vector))
             (new-vector (make-vector (- old-length 1))))
        (do ((source 0 (+ source 1))
             (target 0 (if (= source removed-index) target (+ target 1))))
            ((= source old-length) new-vector)
          (if (not (= source removed-index))
              (vector-set! new-vector target (vector-ref vector source))))))

    ;; Portable π value used by polar, normal, and Poisson generators.
    (define %random-data-pi (* 4 (atan 1.0)))

    (define (with-random-source random-source thunk)
      "Call THUNK with CURRENT-RANDOM-SOURCE temporarily bound to RANDOM-SOURC\
E."
      #((parameters
         (random-source (type random-source)
          (description
            "SRFI 27 random source used while constructing generators."))
         (thunk (type procedure)
          (description "Procedure called with no arguments.")))
        (returns (type any)
         (description "The value returned by THUNK."))
        (effects dynamic-state procedure-call))
      (if (not (random-source? random-source))
          (error "expected random source" random-source))
      (parameterize ((current-random-source random-source))
        (thunk)))

    (define (make-random-source-generator stream-index)
      "Return a generator of deterministic SRFI 27 random sources."
      #((parameters
         (stream-index (type exact-non-negative-integer)
          (description
            "Pseudo-random stream index used for generated sources.")))
        (returns (type procedure)
         (description "Generator producing fresh random sources."))
        (effects allocation state-write))
      (if (not (%random-data-exact-non-negative-integer? stream-index))
          (error "expected exact non-negative stream index" stream-index))
      (let ((substream 0))
        (lambda ()
          (let ((new-source (make-random-source)))
            (random-source-pseudo-randomize! new-source stream-index substream)
            (set! substream (+ substream 1))
            new-source))))

    (define (make-random-integer-generator lower-bound upper-bound)
      "Return a generator of exact integers in `[LOWER-BOUND, UPPER-BOUND)'."
      #((parameters
         (lower-bound (type exact-integer)
          (description "Inclusive lower bound."))
         (upper-bound (type exact-integer)
          (description "Exclusive upper bound.")))
        (returns (type procedure)
         (description "Generator thunk returning exact integers in range."))
        (effects allocation state-write))
      (if (not (%random-data-exact-integer? lower-bound))
          (error "expected exact integer lower bound" lower-bound))
      (if (not (%random-data-exact-integer? upper-bound))
          (error "expected exact integer upper bound" upper-bound))
      (if (not (< lower-bound upper-bound))
          (error "upper bound must be greater than lower bound"
                 lower-bound
                 upper-bound))
      (let ((random-integer-proc
             (random-source-make-integers (current-random-source)))
            (range (- upper-bound lower-bound)))
        (lambda ()
          (+ lower-bound (random-integer-proc range)))))

    (define (make-random-u1-generator)
      "Return a generator of unsigned 1-bit integers."
      #((parameters)
        (returns (type procedure)
         (description "Generator thunk returning 0 or 1."))
        (effects allocation state-write))
      (make-random-integer-generator 0 2))

    (define (make-random-u8-generator)
      "Return a generator of unsigned 8-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[0, 256)'."))
        (effects allocation state-write))
      (make-random-integer-generator 0 256))

    (define (make-random-s8-generator)
      "Return a generator of signed 8-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[-128, 128)'."))
        (effects allocation state-write))
      (make-random-integer-generator -128 128))

    (define (make-random-u16-generator)
      "Return a generator of unsigned 16-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[0, 65536)'."))
        (effects allocation state-write))
      (make-random-integer-generator 0 65536))

    (define (make-random-s16-generator)
      "Return a generator of signed 16-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[-32768, 32768)'."))
        (effects allocation state-write))
      (make-random-integer-generator -32768 32768))

    (define (make-random-u32-generator)
      "Return a generator of unsigned 32-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[0, 2^32)'."))
        (effects allocation state-write))
      (make-random-integer-generator 0 (expt 2 32)))

    (define (make-random-s32-generator)
      "Return a generator of signed 32-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[-2^31, 2^31)'."))
        (effects allocation state-write))
      (make-random-integer-generator (- (expt 2 31)) (expt 2 31)))

    (define (make-random-u64-generator)
      "Return a generator of unsigned 64-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[0, 2^64)'."))
        (effects allocation state-write))
      (make-random-integer-generator 0 (expt 2 64)))

    (define (make-random-s64-generator)
      "Return a generator of signed 64-bit integers."
      #((parameters)
        (returns (type procedure)
         (description
           "Generator thunk returning exact integers in `[-2^63, 2^63)'."))
        (effects allocation state-write))
      (make-random-integer-generator (- (expt 2 63)) (expt 2 63)))

    (define (clamp-real-number lower-bound upper-bound value)
      "Return VALUE clamped to the inclusive real interval."
      #((parameters
         (lower-bound (type real)
          (description "Inclusive lower bound."))
         (upper-bound (type real)
          (description "Inclusive upper bound."))
         (value (type real)
          (description "Value to clamp.")))
        (returns (type real)
         (description "VALUE, LOWER-BOUND, or UPPER-BOUND."))
        (effects none))
      (cond
       ((not (real? lower-bound))
        (error "expected real lower bound" lower-bound))
       ((not (real? upper-bound))
        (error "expected real upper bound" upper-bound))
       ((not (<= lower-bound upper-bound))
        (error "lower bound must be less than or equal to upper bound"
               lower-bound
               upper-bound))
       ((< value lower-bound) lower-bound)
       ((> value upper-bound) upper-bound)
       (else value)))

    (define (make-random-real-generator lower-bound upper-bound)
      "Return a generator of inexact reals between LOWER-BOUND and UPPER-BOUND\
."
      #((parameters
         (lower-bound (type real)
          (description "Inclusive lower bound."))
         (upper-bound (type real)
          (description "Inclusive upper bound.")))
        (returns (type procedure)
         (description "Generator thunk returning inexact real values."))
        (effects allocation state-write))
      (if (not (%random-data-finite-real? lower-bound))
          (error "expected finite real lower bound" lower-bound))
      (if (not (%random-data-finite-real? upper-bound))
          (error "expected finite real upper bound" upper-bound))
      (if (not (< lower-bound upper-bound))
          (error "lower bound must be less than upper bound"
                 lower-bound
                 upper-bound))
      (let ((random-real-proc
             (random-source-make-reals (current-random-source))))
        (lambda ()
          (let ((t (random-real-proc)))
            (+ (* t lower-bound)
               (* (- 1.0 t) upper-bound))))))

    (define (make-random-rectangular-generator real-lower-bound
                                               real-upper-bound
                                               imaginary-lower-bound
                                               imaginary-upper-bound)
      "Return a generator of complex numbers in a rectangular region."
      #((parameters
         (real-lower-bound (type real)
          (description "Inclusive lower bound for the real part."))
         (real-upper-bound (type real)
          (description "Inclusive upper bound for the real part."))
         (imaginary-lower-bound (type real)
          (description "Inclusive lower bound for the imaginary part."))
         (imaginary-upper-bound (type real)
          (description "Inclusive upper bound for the imaginary part.")))
        (returns (type procedure)
         (description "Generator thunk returning complex numbers."))
        (effects allocation state-write))
      (let ((real-generator
             (make-random-real-generator real-lower-bound real-upper-bound))
            (imaginary-generator
             (make-random-real-generator imaginary-lower-bound
                                         imaginary-upper-bound)))
        (lambda ()
          (make-rectangular (real-generator) (imaginary-generator)))))

    (define (make-random-polar-generator . args)
      "Return a generator of complex numbers in a polar sector."
      #((parameters
         (args (type list)
          (description "Two, three, four, or five polar-region arguments.")))
        (returns (type procedure)
         (description "Generator thunk returning complex numbers."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((magnitude-lower-bound magnitude-upper-bound)
         (make-random-polar-generator
          (make-rectangular 0.0 0.0)
          magnitude-lower-bound
          magnitude-upper-bound
          0.0
          (* 2 %random-data-pi)))
        ((origin magnitude-lower-bound magnitude-upper-bound)
         (make-random-polar-generator
          origin
          magnitude-lower-bound
          magnitude-upper-bound
          0.0
          (* 2 %random-data-pi)))
        ((magnitude-lower-bound
          magnitude-upper-bound
          angle-lower-bound
          angle-upper-bound)
         (make-random-polar-generator
          (make-rectangular 0.0 0.0)
          magnitude-lower-bound
          magnitude-upper-bound
          angle-lower-bound
          angle-upper-bound))
        ((origin
          magnitude-lower-bound
          magnitude-upper-bound
          angle-lower-bound
          angle-upper-bound)
         (if (not (complex? origin))
             (error "origin must be a complex number" origin))
         (if (not (and (real? magnitude-lower-bound)
                       (real? magnitude-upper-bound)
                       (real? angle-lower-bound)
                       (real? angle-upper-bound)))
             (error "magnitude and angle bounds must be real numbers"))
         (if (not (and (<= 0 magnitude-lower-bound)
                       (<= 0 magnitude-upper-bound)))
             (error "magnitude bounds must be non-negative"
                    magnitude-lower-bound
                    magnitude-upper-bound))
         (if (not (< magnitude-lower-bound magnitude-upper-bound))
             (error "magnitude lower bound must be less than upper bound"
                    magnitude-lower-bound
                    magnitude-upper-bound))
         (if (= angle-lower-bound angle-upper-bound)
             (error "angle bounds must not be equal"
                    angle-lower-bound
                    angle-upper-bound))
         (let* ((base (%random-data-square magnitude-lower-bound))
                (scale (- (%random-data-square magnitude-upper-bound) base))
                (radius-generator (make-random-real-generator 0.0 1.0))
                (angle-generator
                 (make-random-real-generator angle-lower-bound
                                             angle-upper-bound)))
           (lambda ()
             (let* ((radius
                     (sqrt (+ (* scale (radius-generator)) base)))
                    (angle (angle-generator)))
               (+ origin (make-polar radius angle)))))))
       args))

    (define (make-random-boolean-generator)
      "Return a generator of random booleans."
      #((parameters)
        (returns (type procedure)
         (description "Generator thunk returning `#f' or `#t'."))
        (effects allocation state-write))
      (let ((random-bit (make-random-u1-generator)))
        (lambda ()
          (zero? (random-bit)))))

    (define (make-random-char-generator string)
      "Return a generator of random characters from STRING."
      #((parameters
         (string (type string)
          (description
            "Non-empty source string; duplicate characters weight results.")))
        (returns (type procedure)
         (description "Generator thunk returning characters from STRING."))
        (effects allocation state-write))
      (if (not (string? string))
          (error "expected string" string))
      (if (= (string-length string) 0)
          (error "expected non-empty string" string))
      (let ((index-generator
             (make-random-integer-generator 0 (string-length string))))
        (lambda ()
          (string-ref string (index-generator)))))

    (define (make-random-string-generator k string)
      "Return a generator of random strings with characters from STRING."
      #((parameters
         (k (type exact-positive-integer)
          (description "Exclusive upper bound for generated string length."))
         (string (type string)
          (description "Non-empty source string for generated characters.")))
        (returns (type procedure)
         (description "Generator thunk returning strings."))
        (effects allocation state-write))
      (if (not (%random-data-exact-positive-integer? k))
          (error "expected exact positive string length bound" k))
      (let ((char-generator (make-random-char-generator string))
            (length-generator (make-random-integer-generator 0 k)))
        (lambda ()
          (generator->string char-generator (length-generator)))))

    (define (make-bernoulli-generator probability)
      "Return a generator of Bernoulli random variables."
      #((parameters
         (probability (type real)
          (description
            "Success probability in the closed interval `[0, 1]'.")))
        (returns (type procedure)
         (description
           "Generator thunk returning 1 for success or 0 for failure."))
        (effects allocation state-write))
      (if (not (real? probability))
          (error "expected real probability" probability))
      (if (not (<= 0 probability 1))
          (error "expected probability in [0, 1]" probability))
      (let ((random-real-proc
             (random-source-make-reals (current-random-source))))
        (lambda ()
          (if (<= (random-real-proc) probability) 1 0))))

    (define (make-categorical-generator weight-vector)
      "Return a generator of categorical indices weighted by WEIGHT-VECTOR."
      #((parameters
         (weight-vector (type vector)
          (description "Vector of non-negative weights with positive sum.")))
        (returns (type procedure)
         (description "Generator thunk returning an exact zero-based index."))
        (effects allocation state-write))
      (if (not (vector? weight-vector))
          (error "expected weight vector" weight-vector))
      (let ((weight-sum
             (%random-data-vector-fold
              (lambda (sum weight)
                (if (not (and (number? weight) (not (negative? weight))))
                    (error "expected non-negative numeric weight" weight))
                (+ sum weight))
              0
              weight-vector))
            (length (vector-length weight-vector)))
        (if (or (= length 0) (not (< 0 weight-sum)))
            (error "expected at least one positive categorical weight"
                   weight-vector))
        (let ((real-generator (make-random-real-generator 0 weight-sum)))
          (lambda ()
            (let ((roll (real-generator)))
              (let loop ((sum 0) (index 0))
                (let ((new-sum (+ sum (vector-ref weight-vector index))))
                  (if (or (< roll new-sum)
                          (= index (- length 1)))
                      index
                      (loop new-sum (+ index 1))))))))))

    (define (make-normal-generator . args)
      "Return a generator of normally distributed real numbers."
      #((parameters
         (args (type list)
          (description "Optional mean and positive deviation arguments.")))
        (returns (type procedure)
         (description "Generator thunk returning normal deviates."))
        (effects allocation state-write))
      (apply
       (case-lambda
        (() (make-normal-generator 0.0 1.0))
        ((mean) (make-normal-generator mean 1.0))
        ((mean deviation)
         (if (not (%random-data-finite-real? mean))
             (error "expected finite real mean" mean))
         (if (not (%random-data-positive-finite-real? deviation))
             (error "expected positive finite deviation" deviation))
         (let ((random-real-proc
                (random-source-make-reals (current-random-source)))
               (state #f))
           (lambda ()
             (if state
                 (let ((result state))
                   (set! state #f)
                   result)
                 (let* ((radius (sqrt (* -2 (log (random-real-proc)))))
                        (theta (* 2 %random-data-pi (random-real-proc)))
                        (cached (+ mean (* deviation radius (cos theta)))))
                   (set! state cached)
                   (+ mean (* deviation radius (sin theta)))))))))
       args))

    (define (make-exponential-generator mean)
      "Return a generator of exponentially distributed real numbers."
      #((parameters
         (mean (type positive-real)
          (description "Distribution mean.")))
        (returns (type procedure)
         (description "Generator thunk returning exponential deviates."))
        (effects allocation state-write))
      (if (not (%random-data-positive-finite-real? mean))
          (error "expected positive finite mean" mean))
      (let ((random-real-proc
             (random-source-make-reals (current-random-source))))
        (lambda ()
          (- (* mean (log (random-real-proc)))))))

    (define (make-geometric-generator probability)
      "Return a generator of geometric random variables."
      #((parameters
         (probability (type real)
          (description "Success probability in the interval `(0, 1]'.")))
        (returns (type procedure)
         (description "Generator thunk returning exact positive integers."))
        (effects allocation state-write))
      (if (not (and (real? probability)
                    (< 0 probability)
                    (<= probability 1)))
          (error "expected probability in (0, 1]" probability))
      (if (zero? (- probability 1.0))
          (lambda () 1)
          (let ((scale (/ (%random-data-log1p (- probability))))
                (random-real-proc
                 (random-source-make-reals (current-random-source))))
            (lambda ()
              (exact (ceiling (* scale (log (random-real-proc)))))))))

    (define (make-poisson-generator mean)
      "Return a generator of Poisson random variables."
      #((parameters
         (mean (type positive-real)
          (description "Distribution mean and variance.")))
        (returns (type procedure)
         (description
           "Generator thunk returning exact non-negative integers."))
        (effects allocation state-write))
      (if (not (%random-data-positive-finite-real? mean))
          (error "expected positive finite mean" mean))
      (let ((random-real-proc
             (random-source-make-reals (current-random-source))))
        (if (< mean 30)
            (%make-poisson-small random-real-proc mean)
            (%make-poisson-large random-real-proc mean))))

    (define (%make-poisson-small random-real-proc mean)
      "Return a small-mean Poisson generator using Knuth's method."
      (lambda ()
        (do ((exp-mean (exp (- mean)))
             (k 0 (+ k 1))
             (product 1.0 (* product (random-real-proc))))
            ((<= product exp-mean) (- k 1)))))

    (define (%make-poisson-large random-real-proc mean)
      "Return a large-mean Poisson generator using Atkinson rejection."
      (let* ((c (- 0.767 (/ 3.36 mean)))
             (beta (/ %random-data-pi (sqrt (* 3 mean))))
             (alpha (* beta mean))
             (k (- (log c) mean (log beta))))
        (define (loop)
          (let* ((u (random-real-proc))
                 (x (/ (- alpha (log (/ (- 1.0 u) u))) beta))
                 (n (exact (floor (+ x 0.5)))))
            (if (< n 0)
                (loop)
                (let* ((v (random-real-proc))
                       (y (- alpha (* beta x)))
                       (t (+ 1.0 (exp y)))
                       (lhs (+ y (log (/ v (* t t)))))
                       (rhs (+ k (* n (log mean)) (- (%log-factorial n)))))
                  (if (<= lhs rhs)
                      n
                      (loop))))))
        loop))

    ;; Mutable cache for log-factorial values used by the Poisson sampler.
    (define %random-data-log-factorial-table #f)

    (define (%make-log-factorial-table!)
      "Initialize the log-factorial cache."
      (let ((table (make-vector 256)))
        (vector-set! table 0 0)
        (do ((index 1 (+ index 1)))
            ((> index 255) (%random-data-unspecified))
          (vector-set! table
                       index
                       (+ (vector-ref table (- index 1))
                          (log (+ index 1)))))
        (set! %random-data-log-factorial-table table)))

    (define (%log-factorial n)
      "Return `log(n!)' for exact non-negative integer N."
      (if (not %random-data-log-factorial-table)
          (%make-log-factorial-table!))
      (cond
       ((<= n 1) 0)
       ((<= n 256)
        (vector-ref %random-data-log-factorial-table (- n 1)))
       (else
        (let ((x (+ n 1)))
          (+ (* (- x 0.5) (log x))
             (- x)
             (* 0.5 (log (* 2 %random-data-pi)))
             (/ 1.0 (* x 12.0)))))))

    (define (gsampling . generators)
      "Return a generator sampling uniformly from GENERATORS until exhausted."
      #((parameters
         (generators (type list)
          (description
            "Generator thunks to sample from. Exhausted generators are removed\
.")))
        (returns (type procedure)
         (description "Generator thunk returning sampled values or EOF."))
        (effects allocation state-write procedure-call))
      (let ((generator-vector (list->vector generators))
            (random-integer-proc
             (random-source-make-integers (current-random-source))))
        (define (pick)
          (let* ((index (random-integer-proc (vector-length generator-vector)))
                 (generator (vector-ref generator-vector index))
                 (value (generator)))
            (if (eof-object? value)
                (begin
                  (set! generator-vector
                        (%random-data-remove-vector-index generator-vector
                          index))
                  (if (= (vector-length generator-vector) 0)
                      (eof-object)
                      (pick)))
                value)))
        (lambda ()
          (if (= 0 (vector-length generator-vector))
              (eof-object)
              (pick)))))

    (define (%stirling-tail k)
      "Return the Stirling correction term for K."
      (let ((small-k-table
             '#(0.08106146679532726
                0.0413406959554093
                0.02767792568499834
                0.020790672103765093
                0.016644691189821193
                0.013876128823070748
                0.01189670994589177
                0.010411265261972096
                0.009255462182712733
                0.00833056343336287
                0.007573675487951841
                0.00694284010720953
                0.006408994188004207
                0.0059513701127588475
                0.005554733551962801
                0.0052076559196096404
                0.004901395948434738
                0.004629153749334028
                0.004385560249232324
                0.004166319691996922)))
        (if (< k 20)
            (vector-ref small-k-table k)
            (let* ((inexact-k+1 (inexact (+ k 1)))
                   (inexact-k+1^2 (%random-data-square inexact-k+1)))
              (/ (- (/ 1.0 12.0)
                    (/ (- (/ 1.0 360.0)
                          (/ (/ 1.0 1260.0) inexact-k+1^2))
                       inexact-k+1^2))
                 inexact-k+1)))))

    (define (make-binomial-generator n probability)
      "Return a generator of binomial random variables."
      #((parameters
         (n (type exact-positive-integer)
          (description "Number of Bernoulli trials."))
         (probability (type real)
          (description
            "Success probability in the closed interval `[0, 1]'.")))
        (returns (type procedure)
         (description "Generator thunk returning exact integers in `[0, n]'."))
        (effects allocation state-write))
      (if (not (and (real? probability)
                    (<= 0 probability 1)
                    (%random-data-exact-positive-integer? n)))
          (error "bad binomial parameters" n probability))
      (cond
       ((< 1/2 probability)
        (let ((complement (make-binomial-generator n (- 1 probability))))
          (lambda ()
            (- n (complement)))))
       ((zero? probability)
        (lambda () 0))
       ((< (* n probability) 10)
        (%binomial-geometric n probability))
       (else
        (%binomial-rejection n probability))))

    (define (%binomial-geometric n probability)
      "Return a binomial generator using geometric waiting times."
      (let ((geometric (make-geometric-generator probability)))
        (lambda ()
          (let loop ((successes -1)
                     (sum 0))
            (if (< n sum)
                successes
                (loop (+ successes 1)
                      (+ sum (geometric))))))))

    (define (%binomial-rejection n probability)
      "Return a binomial generator using the BTRS rejection method."
      (let* ((standard-deviation
              (inexact (sqrt (* n probability (- 1 probability)))))
             (b (+ 1.15 (* 2.53 standard-deviation)))
             (a (+ -0.0873 (* 0.0248 b) (* 0.01 probability)))
             (c (+ (* n probability) 0.5))
             (v-r (- 0.92 (/ 4.2 b)))
             (alpha (* (+ 2.83 (/ 5.1 b)) standard-deviation))
             (log-probability-ratio (log (/ probability (- 1 probability))))
             (m (exact (floor (* (+ n 1) probability))))
             (random-real-proc
              (random-source-make-reals (current-random-source))))
        (lambda ()
          (let loop ()
            (let* ((u (- (random-real-proc) 0.5))
                   (v (random-real-proc))
                   (us (- 0.5 (abs u)))
                   (k (exact
                       (floor
                        (+ (* (+ (* 2.0 (/ a us)) b) u) c)))))
              (cond
               ((or (< k 0) (< n k))
                (loop))
               ((and (<= 0.07 us) (<= v v-r))
                k)
               (else
                (let ((logged-v
                       (log (* v (/ alpha
                                    (+ (/ a (%random-data-square us)) b))))))
                  (if (<= logged-v
                          (+ (* (+ m 0.5)
                                (log (* (/ (+ m 1.0)
                                           (- n m -1.0)))))
                             (* (+ n 1.0)
                                (log (/ (- n m -1.0)
                                        (- n k -1.0))))
                             (* (+ k 0.5)
                                (log (* (/ (- n k -1.0)
                                           (+ k 1.0)))))
                             (* (- k m) log-probability-ratio)
                             (- (+ (%stirling-tail m)
                                   (%stirling-tail (- n m)))
                                (+ (%stirling-tail k)
                                   (%stirling-tail (- n k))))))
                      k
                      (loop))))))))))

    (define (%make-zipf-generator/zri n exponent deformation)
      "Return a Zipf generator using rejection-inversion."
      (let* ((one-minus-exponent (- 1 exponent))
             (reciprocal-one-minus-exponent (/ 1 one-minus-exponent)))
        (define (hat x)
          (expt (+ x deformation) (- exponent)))
        (define (big-h x)
          (/ (expt (+ deformation x) one-minus-exponent)
             one-minus-exponent))
        (define (big-h-inverse y)
          (- (expt (* y one-minus-exponent)
                   reciprocal-one-minus-exponent)
             deformation))
        (let* ((big-h-half (- (big-h 1.5) (hat 1)))
               (big-h-n (big-h (+ n 0.5)))
               (cut (- 1 (big-h-inverse (- (big-h 1.5) (hat 1)))))
               (distribution (make-random-real-generator big-h-half big-h-n)))
          (define (try)
            (let* ((u (distribution))
                   (x (big-h-inverse u))
                   (kflt (floor (+ x 0.5)))
                   (k (exact kflt)))
              (if (and (< 0 k)
                       (or (<= (- k x) cut)
                           (>= u (- (big-h (+ k 0.5)) (hat k)))))
                  k
                  #f)))
          (define (loop-until)
            (let ((k (try)))
              (if k k (loop-until))))
          loop-until)))

    (define (%make-zipf-generator/one n exponent deformation)
      "Return a Zipf generator specialized for exponents near one."
      (let ((one-minus-exponent (- 1 exponent)))
        (define (hat x)
          (let ((x+q (+ x deformation)))
            (/ (expt x+q one-minus-exponent) x+q)))
        (define (exn logarithm)
          (define (term n u lg)
            (* lg (+ 1 (/ (* one-minus-exponent u) n))))
          (term 2 (term 3 (term 4 1 logarithm) logarithm) logarithm))
        (define (lg y)
          (define yms (* y one-minus-exponent))
          (define (term n u result)
            (- (/ 1 n) (* u result)))
          (* y (term 1 yms (term 2 yms (term 3 yms (term 4 yms 0))))))
        (define (big-h x)
          (exn (log (+ deformation x))))
        (define (big-h-inverse y)
          (- (exp (lg y)) deformation))
        (let* ((big-h-half (- (big-h 1.5) (hat 1)))
               (big-h-n (big-h (+ n 0.5)))
               (cut (- 1 (big-h-inverse (- (big-h 1.5)
                                            (/ 1 (+ 1 deformation))))))
               (distribution (make-random-real-generator big-h-half big-h-n)))
          (define (try)
            (let* ((u (distribution))
                   (x (big-h-inverse u))
                   (kflt (floor (+ x 0.5)))
                   (k (exact kflt)))
              (if (and (< 0 k)
                       (or (<= (- k x) cut)
                           (>= u (- (big-h (+ k 0.5)) (hat k)))))
                  k
                  #f)))
          (define (loop-until)
            (let ((k (try)))
              (if k k (loop-until))))
          loop-until)))

    (define (make-zipf-generator . args)
      "Return a generator of generalized Zipf random variables."
      #((parameters
         (args (type list)
          (description "N with optional exponent S and deformation Q.")))
        (returns (type procedure)
         (description "Generator thunk returning exact integers in `[1, n]'."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((n) (make-zipf-generator n 1.0 0.0))
        ((n exponent) (make-zipf-generator n exponent 0.0))
        ((n exponent deformation)
         (if (not (%random-data-exact-positive-integer? n))
             (error "expected exact positive Zipf bound" n))
         (if (not (and (%random-data-finite-real? exponent)
                       (< -10 exponent)
                       (< exponent 100)))
             (error "expected finite Zipf exponent in (-10, 100)" exponent))
         (if (not (and (%random-data-finite-real? deformation)
                       (< -0.5 deformation)
                       (< deformation (expt 2 8))))
             (error "expected finite Zipf deformation in (-0.5, 2^8)"
                    deformation))
         (if (< 1e-5 (abs (- 1 exponent)))
             (%make-zipf-generator/zri n exponent deformation)
             (%make-zipf-generator/one n exponent deformation))))
       args))

    (define (make-sphere-generator n)
      "Return a generator of points on an N-sphere."
      #((parameters
         (n (type exact-positive-integer)
          (description
            "Sphere dimension; generated vectors have length N + 1.")))
        (returns (type procedure)
         (description "Generator thunk returning coordinate vectors."))
        (effects allocation state-write))
      (if (not (%random-data-exact-positive-integer? n))
          (error "expected exact positive sphere dimension" n))
      (%make-ellipsoid-generator* (make-vector (+ 1 n) 1.0)))

    (define (make-ellipsoid-generator axes)
      "Return a generator of points on the ellipsoid described by AXES."
      #((parameters
         (axes (type vector)
          (description "Vector of positive finite real axis lengths.")))
        (returns (type procedure)
         (description "Generator thunk returning coordinate vectors."))
        (effects allocation state-write))
      (let ((return-error
             (lambda ()
               (error "expected vector of positive finite real axes" axes))))
        (if (and (vector? axes)
                 (< 0 (vector-length axes))
                 (%random-data-vector-every real? axes))
            (let ((inexact-axes (%random-data-vector-map inexact axes)))
              (if (%random-data-vector-every %random-data-positive-finite-real?
                                             inexact-axes)
                  (%make-ellipsoid-generator* inexact-axes)
                  (return-error)))
            (return-error))))

    (define (%make-ellipsoid-generator* axes)
      "Return a generator over ellipsoid AXES."
      (let ((normal-generator (make-normal-generator))
            (uniform-generator (make-random-real-generator 0.0 1.0))
            (minimum-axis
             (%random-data-vector-fold min
                                       (vector-ref axes 0)
                                       axes)))
        (define (sphere)
          (let* ((point
                  (%random-data-vector-map
                   (lambda (axis)
                     axis
                     (normal-generator))
                   axes))
                 (norm-inverse
                  (/ (sqrt
                      (%random-data-vector-fold
                       (lambda (sum x)
                         (+ sum (%random-data-square x)))
                       0.0
                       point)))))
            (%random-data-vector-map
             (lambda (x) (* x norm-inverse))
             point)))
        (define (ellipsoid-distance ray)
          (sqrt
           (%random-data-vector-fold2
            (lambda (sum x axis)
              (+ sum (%random-data-square (/ x axis))))
            0.0
            ray
            axes)))
        (define (keep? point)
          (< (uniform-generator)
             (* minimum-axis (ellipsoid-distance point))))
        (define (sample)
          (let ((point (sphere)))
            (if (keep? point)
                point
                (sample))))
        (lambda ()
          (%random-data-vector-map2 * (sample) axes))))

    (define (make-ball-generator dimensions)
      "Return a generator of points inside a ball or ellipsoid."
      #((parameters
         (dimensions (type (or exact-positive-integer vector))
          (description
            "Exact positive dimension or vector of positive finite axes.")))
        (returns (type procedure)
         (description "Generator thunk returning coordinate vectors."))
        (effects allocation state-write))
      (let ((return-error
             (lambda ()
               (error
                 "expected exact positive dimension or positive finite axes"
                      dimensions))))
        (cond
         ((%random-data-exact-positive-integer? dimensions)
          (%make-ball-generator* (make-vector dimensions 1.0)))
         ((and (vector? dimensions)
               (< 0 (vector-length dimensions))
               (%random-data-vector-every real? dimensions))
          (let ((inexact-axes (%random-data-vector-map inexact dimensions)))
            (if (%random-data-vector-every %random-data-positive-finite-real?
                                           inexact-axes)
                (%make-ball-generator* inexact-axes)
                (return-error))))
         (else
          (return-error)))))

    (define (%make-ball-generator* axes)
      "Return a generator over the ellipsoid interior described by AXES."
      (let ((sphere-generator
             (make-sphere-generator (+ (vector-length axes) 1))))
        (lambda ()
          (%random-data-vector-map2 * (sphere-generator) axes))))))
