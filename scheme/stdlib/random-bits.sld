;;; SRFI 27 random-bits stdlib support.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2002 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib random-bits)' as a portable R7RS adaptation of the
;;; official SRFI 27 MRG32k3a reference implementation:
;;; https://github.com/scheme-requests-for-implementation/srfi-27.
;;; Local patches wrap the source in Consent Scheme's stdlib namespace, use
;;; R7RS records and `(scheme time)' for the clock seed, and expose `(srfi
;;; 27)',
;;; `(srfi srfi-27)', `(srfi :27)', and `(srfi :27 random-bits)' as registry
;;; aliases.

(define-library (stdlib random-bits)
  (export random-integer
          random-real
          default-random-source
          make-random-source
          random-source?
          random-source-state-ref
          random-source-state-set!
          random-source-randomize!
          random-source-pseudo-randomize!
          random-source-make-integers
          random-source-make-reals)
  (import (scheme base)
          (scheme time))
  (begin
    ;; Random sources store mutable generator closures around private state.
    (define-record-type <random-source>
      (%make-random-source-record state-ref state-set! randomize!
                                  pseudo-randomize! make-integers make-reals)
      random-source?
      (state-ref %random-source-state-ref)
      (state-set! %random-source-state-set!)
      (randomize! %random-source-randomize!)
      (pseudo-randomize! %random-source-pseudo-randomize!)
      (make-integers %random-source-make-integers)
      (make-reals %random-source-make-reals))

    (define (%random-bits-unspecified)
      "Return the R7RS unspecified value."
      (if #f #f))

    (define (%random-bits-exact-integer? value)
      "Return #t when VALUE is an exact integer."
      (and (integer? value) (exact? value)))

    (define (mrg32k3a-copy-state state)
      "Return a fresh mutable vector copy of packed STATE."
      (list->vector (vector->list state)))

    ;; Modulus of component 1.
    (define mrg32k3a-m1 4294967087)

    ;; Modulus of component 2.
    (define mrg32k3a-m2 4294944443)

    ;; Initial state, elements 0 3 6 9 12 15 of A^16 in the SRFI reference.
    (define mrg32k3a-initial-state
      '#(1062452522
         2961816100
         342112271
         2854655037
         3321940838
         3542344109))

    ;; Precomputed A^(2^127), A^(2^76), and A^16 jump matrices.
    (define mrg32k3a-generators
      '(#(1230515664 986791581 1988835001
          3580155704 1230515664 226153695
          949770784 3580155704 2427906178
          2093834863 32183930 2824425944
          1022607788 1464411153 32183930
          1610723613 277697599 1464411153)
        #(69195019 3528743235 3672091415
          1871391091 69195019 3672831523
          4127413238 1871391091 82758667
          3708466080 4292754251 3859662829
          3889917532 1511326704 4292754251
          1610795712 3759209742 1511326704)
        #(1062452522 340793741 2955879160
          2961816100 1062452522 387300998
          342112271 2961816100 736416029
          2854655037 1817134745 3493477402
          3321940838 818368950 1817134745
          3542344109 3790774567 818368950)))

    (define (mrg32k3a-random-m1 state)
      "Advance STATE once and return an integer modulo the first modulus."
      (let ((x11 (vector-ref state 0))
            (x12 (vector-ref state 1))
            (x13 (vector-ref state 2))
            (x21 (vector-ref state 3))
            (x22 (vector-ref state 4))
            (x23 (vector-ref state 5)))
        (let ((x10 (modulo (- (* 1403580 x12) (* 810728 x13)) mrg32k3a-m1))
              (x20 (modulo (- (* 527612 x21) (* 1370589 x23)) mrg32k3a-m2)))
          (vector-set! state 0 x10)
          (vector-set! state 1 x11)
          (vector-set! state 2 x12)
          (vector-set! state 3 x20)
          (vector-set! state 4 x21)
          (vector-set! state 5 x22)
          (modulo (- x10 x20) mrg32k3a-m1))))

    (define (mrg32k3a-pack-state unpacked-state)
      "Return the packed form of UNPACKED-STATE."
      unpacked-state)

    (define (mrg32k3a-unpack-state state)
      "Return the unpacked form of STATE."
      state)

    (define (mrg32k3a-random-range)
      "Return the largest range accepted by the core generator."
      mrg32k3a-m1)

    (define (mrg32k3a-random-integer state range)
      "Advance STATE and return a uniform integer in [0, RANGE)."
      (let* ((q (quotient mrg32k3a-m1 range))
             (qn (* q range)))
        (let loop ((x (mrg32k3a-random-m1 state)))
          (if (< x qn)
              (quotient x q)
              (loop (mrg32k3a-random-m1 state))))))

    (define (mrg32k3a-random-real state)
      "Advance STATE and return a real number in (0, 1)."
      (* 0.0000000002328306549295728 (+ 1.0 (mrg32k3a-random-m1 state))))

    (define (mrg32k3a-state-ref packed-state)
      "Return the external SRFI 27 state representation for PACKED-STATE."
      (cons 'lecuyer-mrg32k3a
            (vector->list (mrg32k3a-unpack-state packed-state))))

    (define (mrg32k3a-state-set external-state)
      "Validate EXTERNAL-STATE and return a packed MRG32k3a state."
      (letrec ((check-value
                (lambda (value modulus)
                  (if (and (%random-bits-exact-integer? value)
                           (<= 0 value)
                           (< value modulus))
                      #t
                      (error "illegal random source state value" value)))))
        (if (and (list? external-state)
                 (= (length external-state) 7)
                 (eq? (car external-state) 'lecuyer-mrg32k3a))
            (let ((state-values (cdr external-state)))
              (check-value (list-ref state-values 0) mrg32k3a-m1)
              (check-value (list-ref state-values 1) mrg32k3a-m1)
              (check-value (list-ref state-values 2) mrg32k3a-m1)
              (check-value (list-ref state-values 3) mrg32k3a-m2)
              (check-value (list-ref state-values 4) mrg32k3a-m2)
              (check-value (list-ref state-values 5) mrg32k3a-m2)
              (if (or (zero? (+ (list-ref state-values 0)
                                (list-ref state-values 1)
                                (list-ref state-values 2)))
                      (zero? (+ (list-ref state-values 3)
                                (list-ref state-values 4)
                                (list-ref state-values 5))))
                  (error "illegal degenerate random source state"
                    external-state))
              (mrg32k3a-pack-state (list->vector state-values)))
            (error "malformed random source state" external-state))))

    (define (mrg32k3a-linear-combination a0 a1 a2 b0 b1 b2 modulus word-square)
      "Return A dot B modulo MODULUS using 16-bit splits."
      (let ((word-size 65536)
            (a0h (quotient a0 65536))
            (a0l (modulo a0 65536))
            (a1h (quotient a1 65536))
            (a1l (modulo a1 65536))
            (a2h (quotient a2 65536))
            (a2l (modulo a2 65536))
            (b0h (quotient b0 65536))
            (b0l (modulo b0 65536))
            (b1h (quotient b1 65536))
            (b1l (modulo b1 65536))
            (b2h (quotient b2 65536))
            (b2l (modulo b2 65536)))
        (modulo
         (+ (* (+ (* a0h b0h) (* a1h b1h) (* a2h b2h)) word-square)
            (* (+ (* a0h b0l)
                  (* a0l b0h)
                  (* a1h b1l)
                  (* a1l b1h)
                  (* a2h b2l)
                  (* a2l b2h))
               word-size)
            (* a0l b0l)
            (* a1l b1l)
            (* a2l b2l))
         modulus)))

    (define (mrg32k3a-matrix-product left right)
      "Return LEFT times RIGHT in the paired MRG32k3a matrix rings."
      (letrec
          ((entry
            (lambda (i0 i1 i2 j0 j1 j2 modulus word-square)
              (mrg32k3a-linear-combination
               (vector-ref left i0)
               (vector-ref left i1)
               (vector-ref left i2)
               (vector-ref right j0)
               (vector-ref right j1)
               (vector-ref right j2)
               modulus
               word-square))))
        (vector
         (entry 0 1 2 0 3 6 mrg32k3a-m1 209)
         (entry 0 1 2 1 4 7 mrg32k3a-m1 209)
         (entry 0 1 2 2 5 8 mrg32k3a-m1 209)
         (entry 3 4 5 0 3 6 mrg32k3a-m1 209)
         (entry 3 4 5 1 4 7 mrg32k3a-m1 209)
         (entry 3 4 5 2 5 8 mrg32k3a-m1 209)
         (entry 6 7 8 0 3 6 mrg32k3a-m1 209)
         (entry 6 7 8 1 4 7 mrg32k3a-m1 209)
         (entry 6 7 8 2 5 8 mrg32k3a-m1 209)
         (entry 9 10 11 9 12 15 mrg32k3a-m2 22853)
         (entry 9 10 11 10 13 16 mrg32k3a-m2 22853)
         (entry 9 10 11 11 14 17 mrg32k3a-m2 22853)
         (entry 12 13 14 9 12 15 mrg32k3a-m2 22853)
         (entry 12 13 14 10 13 16 mrg32k3a-m2 22853)
         (entry 12 13 14 11 14 17 mrg32k3a-m2 22853)
         (entry 15 16 17 9 12 15 mrg32k3a-m2 22853)
         (entry 15 16 17 10 13 16 mrg32k3a-m2 22853)
         (entry 15 16 17 11 14 17 mrg32k3a-m2 22853))))

    (define (mrg32k3a-matrix-apply matrix state)
      "Apply MATRIX to six-word STATE and return a fresh state vector."
      (letrec
          ((entry
            (lambda (i0 i1 i2 j0 j1 j2 modulus word-square)
              (mrg32k3a-linear-combination
               (vector-ref matrix i0)
               (vector-ref matrix i1)
               (vector-ref matrix i2)
               (vector-ref state j0)
               (vector-ref state j1)
               (vector-ref state j2)
               modulus
               word-square))))
        (vector
         (entry 0 1 2 0 1 2 mrg32k3a-m1 209)
         (entry 3 4 5 0 1 2 mrg32k3a-m1 209)
         (entry 6 7 8 0 1 2 mrg32k3a-m1 209)
         (entry 9 10 11 3 4 5 mrg32k3a-m2 22853)
         (entry 12 13 14 3 4 5 mrg32k3a-m2 22853)
         (entry 15 16 17 3 4 5 mrg32k3a-m2 22853))))

    (define (mrg32k3a-matrix-power-apply matrix exponent state)
      "Apply MATRIX^EXPONENT to STATE."
      (let loop ((base matrix) (remaining exponent) (current state))
        (cond
         ((zero? remaining)
          current)
         ((odd? remaining)
          (loop (if (= remaining 1)
                    base
                    (mrg32k3a-matrix-product base base))
                (quotient remaining 2)
                (mrg32k3a-matrix-apply base current)))
         (else
          (loop (mrg32k3a-matrix-product base base)
                (quotient remaining 2)
                current)))))

    (define (mrg32k3a-pseudo-randomize-state i j)
      "Return the packed state for stream I and substream J."
      (if (not (and (%random-bits-exact-integer? i)
                    (<= 0 i)
                    (%random-bits-exact-integer? j)
                    (<= 0 j)))
          (error "i and j must be exact non-negative integers" i j))
      (let* ((state '#(1 0 0 1 0 0))
             (substream-state
              (mrg32k3a-matrix-power-apply
               (list-ref mrg32k3a-generators 1)
               (modulo j (expt 2 28))
               state))
             (stream-state
              (mrg32k3a-matrix-power-apply
               (list-ref mrg32k3a-generators 0)
               (modulo i (expt 2 28))
               substream-state)))
        (mrg32k3a-pack-state
         (mrg32k3a-matrix-apply
          (list-ref mrg32k3a-generators 2)
          stream-state))))

    (define (mrg32k3a-randomize-state state)
      "Return STATE randomized by a policy-gated clock seed."
      (let* ((word-size 65536)
             (clock-seed (current-jiffy))
             (seed (modulo clock-seed word-size)))
        (letrec ((random-word
                  (lambda ()
                    (let ((value (modulo seed word-size)))
                      (set! seed (+ (* 30903 value) (quotient seed word-size)))
                      value)))
                 (random-modulo
                  (lambda (modulus)
                    (modulo (+ (* (random-word) word-size) (random-word))
                            modulus))))
          (let ((unpacked (mrg32k3a-unpack-state state)))
            (mrg32k3a-pack-state
             (vector
              (+ 1
                 (modulo (+ (vector-ref unpacked 0)
                            (random-modulo (- mrg32k3a-m1 1)))
                         (- mrg32k3a-m1 1)))
              (modulo (+ (vector-ref unpacked 1)
                         (random-modulo mrg32k3a-m1))
                      mrg32k3a-m1)
              (modulo (+ (vector-ref unpacked 2)
                         (random-modulo mrg32k3a-m1))
                      mrg32k3a-m1)
              (+ 1
                 (modulo (+ (vector-ref unpacked 3)
                            (random-modulo (- mrg32k3a-m2 1)))
                         (- mrg32k3a-m2 1)))
              (modulo (+ (vector-ref unpacked 4)
                         (random-modulo mrg32k3a-m2))
                      mrg32k3a-m2)
              (modulo (+ (vector-ref unpacked 5)
                         (random-modulo mrg32k3a-m2))
                      mrg32k3a-m2)))))))

    ;; Largest core generator range.
    (define mrg32k3a-m-max
      (mrg32k3a-random-range))

    (define (mrg32k3a-random-power state k)
      "Return a random integer below m-max^K using STATE."
      (if (= k 1)
          (mrg32k3a-random-integer state mrg32k3a-m-max)
          (+ (* (mrg32k3a-random-power state (- k 1)) mrg32k3a-m-max)
             (mrg32k3a-random-integer state mrg32k3a-m-max))))

    (define (mrg32k3a-random-large state n)
      "Return a random integer in [0, N) when N is larger than m-max."
      (let find-power ((k 2)
                       (mk (* mrg32k3a-m-max mrg32k3a-m-max)))
        (if (>= mk n)
            (let* ((mk-by-n (quotient mk n))
                   (accept (* mk-by-n n)))
              (let loop ((value (mrg32k3a-random-power state k)))
                (if (< value accept)
                    (quotient value mk-by-n)
                    (loop (mrg32k3a-random-power state k)))))
            (find-power (+ k 1) (* mk mrg32k3a-m-max)))))

    (define (mrg32k3a-random-real-mp state unit)
      "Return a multiple-precision real from STATE at precision UNIT."
      (let find-precision ((k 1)
                           (remaining (- (/ 1 unit) 1)))
        (if (<= remaining 1)
            (/ (inexact (+ (mrg32k3a-random-power state k) 1))
               (inexact (+ (expt mrg32k3a-m-max k) 1)))
            (find-precision (+ k 1) (/ remaining mrg32k3a-m1)))))

    (define (make-random-source)
      "Return a new deterministic SRFI 27 random source."
      #((parameters)
        (returns (type random-source)
         (description "Fresh MRG32k3a random source at the default state."))
        (effects allocation state-write))
      (let ((state (mrg32k3a-pack-state
                    (mrg32k3a-copy-state mrg32k3a-initial-state))))
        (%make-random-source-record
         (lambda ()
           (mrg32k3a-state-ref state))
         (lambda (new-state)
           (set! state (mrg32k3a-state-set new-state))
           (%random-bits-unspecified))
         (lambda ()
           (set! state (mrg32k3a-randomize-state state))
           (%random-bits-unspecified))
         (lambda (i j)
           (set! state (mrg32k3a-pseudo-randomize-state i j))
           (%random-bits-unspecified))
         (lambda ()
           (lambda (n)
             (cond
              ((not (and (%random-bits-exact-integer? n) (< 0 n)))
               (error "range must be exact positive integer" n))
              ((<= n mrg32k3a-m-max)
               (mrg32k3a-random-integer state n))
              (else
               (mrg32k3a-random-large state n)))))
         (lambda unit
           (cond
            ((null? unit)
             (lambda ()
               (mrg32k3a-random-real state)))
            ((null? (cdr unit))
             (let ((requested-unit (car unit)))
               (cond
                ((not (and (real? requested-unit)
                           (< 0 requested-unit)
                           (< requested-unit 1)))
                 (error "unit must be real in (0,1)" requested-unit))
                ((<= (- (/ 1 requested-unit) 1) mrg32k3a-m1)
                 (lambda ()
                   (mrg32k3a-random-real state)))
                (else
                 (lambda ()
                   (mrg32k3a-random-real-mp state requested-unit))))))
            (else
             (error "illegal random real unit arguments" unit)))))))

    (define (random-source-state-ref source)
      "Return SOURCE's external SRFI 27 state datum."
      #((parameters
         (source (type random-source)
          (description "Random source whose state should be copied.")))
        (returns (type list)
         (description "A `(lecuyer-mrg32k3a ...)' state list."))
        (effects state-read))
      ((%random-source-state-ref source)))

    (define (random-source-state-set! source state)
      "Replace SOURCE's state with external SRFI 27 STATE."
      #((parameters
         (source (type random-source)
          (description "Random source whose state should be replaced."))
         (state (type list)
          (description "External `(lecuyer-mrg32k3a ...)' state list.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write))
      ((%random-source-state-set! source) state))

    (define (random-source-randomize! source)
      "Randomize SOURCE using a policy-gated clock seed."
      #((parameters
         (source (type random-source)
          (description "Random source to randomize.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects host-time state-write))
      ((%random-source-randomize! source)))

    (define (random-source-pseudo-randomize! source i j)
      "Set SOURCE to deterministic stream I and substream J."
      #((parameters
         (source (type random-source)
          (description "Random source to reposition."))
         (i (type exact-non-negative-integer)
          (description "Stream index."))
         (j (type exact-non-negative-integer)
          (description "Substream index.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write))
      ((%random-source-pseudo-randomize! source) i j))

    (define (random-source-make-integers source)
      "Return a generator of random integers from SOURCE."
      #((parameters
         (source (type random-source)
          (description "Random source backing the generated procedure.")))
        (returns (type procedure)
         (description
           "Procedure accepting a positive exact range and returning an intege\
r in that range."))
        (effects allocation state-write))
      ((%random-source-make-integers source)))

    (define (random-source-make-reals source . unit)
      "Return a generator of random real numbers from SOURCE."
      #((parameters
         (source (type random-source)
          (description "Random source backing the generated procedure."))
         (unit (type real)
          (description
            "Optional precision unit in the open interval `(0, 1)'.")))
        (returns (type procedure)
         (description
           "Procedure of no arguments returning a real number in `(0, 1)'."))
        (effects allocation state-write))
      (apply (%random-source-make-reals source) unit))

    ;; Shared default source used by random-integer and random-real.
    (define default-random-source
      (make-random-source))

    ;; Cached integer generator over the shared default source.
    (define %default-random-integer
      (random-source-make-integers default-random-source))

    ;; Cached real generator over the shared default source.
    (define %default-random-real
      (random-source-make-reals default-random-source))

    (define (random-integer n)
      "Return a random integer in [0, N) from the default source."
      #((parameters
         (n (type exact-positive-integer)
          (description "Exclusive upper bound.")))
        (returns (type exact-non-negative-integer)
         (description "Random integer less than N."))
        (effects state-write))
      (%default-random-integer n))

    (define (random-real)
      "Return a random real number in (0, 1) from the default source."
      #((parameters)
        (returns (type real)
         (description "Random real number in the open interval `(0, 1)'."))
        (effects state-write))
      (%default-random-real))))
