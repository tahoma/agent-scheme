;;; SRFI 252 property-testing stdlib support.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2024 Antero Mejr <mail@antr.me>
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib property-testing)' as a portable R7RS adaptation of the
;;; official SRFI 252 sample implementation:
;;; https://github.com/scheme-requests-for-implementation/srfi-252.
;;; Local patches wrap the source in Consent Scheme's stdlib namespace, import
;;; the already shipped `(stdlib list)', `(stdlib testing)', `(stdlib
;;; generator)', and `(stdlib random-data-generators)' dependencies, adapt the
;;; finite special-number list to SRFI 158 generators, repair the two-generator
;;; `pair-generator-of' case, record optional SRFI 143 and SRFI 144 numeric
;;; accelerators as manifest metadata, and expose `(srfi 252)' and
;;; `(srfi srfi-252)' as registry aliases.

(define-library (stdlib property-testing)
  (export test-property
          test-property-expect-fail
          test-property-skip
          test-property-error
          test-property-error-type
          property-test-runner
          boolean-generator
          bytevector-generator
          char-generator
          string-generator
          symbol-generator
          exact-complex-generator
          exact-integer-generator
          exact-number-generator
          exact-rational-generator
          exact-real-generator
          exact-integer-complex-generator
          inexact-complex-generator
          inexact-integer-generator
          inexact-number-generator
          inexact-rational-generator
          inexact-real-generator
          complex-generator
          integer-generator
          number-generator
          rational-generator
          real-generator
          list-generator-of
          pair-generator-of
          procedure-generator-of
          vector-generator-of)
  (import (scheme base)
          (scheme case-lambda)
          (scheme complex)
          (stdlib list)
          (stdlib testing)
          (stdlib generator)
          (stdlib random-data-generators))
  (begin
    ;; Number of property assertions to run by default.
    (define %property-testing-default-runs 100)

    ;; Value range for exact random generators.
    (define %property-testing-max-exact
      (expt 2 24))

    ;; Value range for exact random generators.
    (define %property-testing-min-exact
      (- (expt 2 24)))

    ;; Value range for inexact random generators.
    (define %property-testing-max-inexact
      (cond-expand
       (ieee-float 3.4e38)
       (else %property-testing-max-exact)))

    ;; Value range for inexact random generators.
    (define %property-testing-min-inexact
      (cond-expand
       (ieee-float -3.4e38)
       (else %property-testing-min-exact)))

    ;; Maximum size for random bytevector, list, string, symbol, and vector data.
    (define %property-testing-max-size 1001)

    ;; Maximum character supported by integer->char for this host.
    (define %property-testing-max-char
      (cond-expand
       (full-unicode #x10ffff)
       (else 128)))

    (define (%property-testing-inexact-complex real imaginary)
      "Return an inexact complex number from REAL and IMAGINARY."
      (make-rectangular real imaginary))

    ;; Finite prefix of special numeric edge cases tried before random values.
    (define %property-testing-special-number
      (append
       ;; Exact integers.
       '(0 1 -1)
       ;; Exact ratios.
       (cond-expand
        (ratios (list (/ 1 2) (/ -1 2)))
        (else '()))
       ;; Exact complex numbers.
       (cond-expand
        (exact-complex
         (list (make-rectangular 0 1)
               (make-rectangular 0 -1)
               (make-rectangular 1 1)
               (make-rectangular 1 -1)
               (make-rectangular -1 1)
               (make-rectangular -1 -1)))
        (else '()))
       ;; Exact complex ratios.
       (cond-expand
        ((and ratios exact-complex)
         (let ((half (/ 1 2))
               (minus-half (/ -1 2)))
           (list (make-rectangular half half)
                 (make-rectangular half minus-half)
                 (make-rectangular minus-half half)
                 (make-rectangular minus-half minus-half))))
        (else '()))
       ;; Inexact real numbers.
       '(0.0 -0.0 0.5 -0.5 1.0 -1.0)
       ;; Inexact complex numbers.
       (list
        (%property-testing-inexact-complex 0.0 1.0)
        (%property-testing-inexact-complex 0.0 -1.0)
        (%property-testing-inexact-complex -0.0 1.0)
        (%property-testing-inexact-complex -0.0 -1.0)
        (%property-testing-inexact-complex 0.5 0.5)
        (%property-testing-inexact-complex 0.5 -0.5)
        (%property-testing-inexact-complex -0.5 0.5)
        (%property-testing-inexact-complex -0.5 -0.5)
        (%property-testing-inexact-complex 1.0 1.0)
        (%property-testing-inexact-complex 1.0 -1.0)
        (%property-testing-inexact-complex -1.0 1.0)
        (%property-testing-inexact-complex -1.0 -1.0)
        (%property-testing-inexact-complex +inf.0 +inf.0)
        (%property-testing-inexact-complex +inf.0 -inf.0)
        (%property-testing-inexact-complex -inf.0 +inf.0)
        (%property-testing-inexact-complex -inf.0 -inf.0)
        (%property-testing-inexact-complex +nan.0 +nan.0))
       ;; Other inexact special numbers.
       '(+inf.0 -inf.0 +nan.0)))

    (define (%property-testing-special-number-generator pred)
      "Return a finite generator of special numbers accepted by PRED."
      (gfilter pred (list->generator %property-testing-special-number)))

    (define (%property-testing-run-count maybe-runs)
      "Return the optional property assertion count from MAYBE-RUNS."
      (if (null? maybe-runs)
          %property-testing-default-runs
          (car maybe-runs)))

    (define (%property-testing-generated-arguments generators)
      "Return one generated argument from each generator in GENERATORS."
      (map (lambda (generator) (generator)) generators))

    (define (%property-testing-record-arguments! runner arguments iteration runs)
      "Record property-test ARGUMENTS, ITERATION, and RUNS on RUNNER."
      (test-result-set! runner 'property-test-arguments arguments)
      (test-result-set! runner 'property-test-iteration iteration)
      (test-result-set! runner 'property-test-iterations runs))

    (define (boolean-generator)
      "Return a generator of booleans."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding #t, #f, then random booleans."))
        (effects allocation state-write))
      (gcons* #t #f (make-random-boolean-generator)))

    (define (bytevector-generator)
      "Return a generator of bytevectors."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding empty and random bytevectors."))
        (effects allocation state-write))
      (let ((byte-generator (make-random-u8-generator)))
        (gcons* (bytevector)
                (gmap (lambda (length)
                        (apply bytevector
                               (generator->list byte-generator length)))
                      (make-random-integer-generator
                       0
                       %property-testing-max-size)))))

    (define (char-generator)
      "Return a generator of characters."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding #\\null and random characters."))
        (effects allocation state-write))
      (gcons* #\null
              (gmap integer->char
                    (gfilter
                     (lambda (value)
                       (or (< value #xd800) (> value #xdfff)))
                     (make-random-integer-generator
                      0
                      %property-testing-max-char)))))

    (define (string-generator)
      "Return a generator of strings."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding empty and random strings."))
        (effects allocation state-write))
      (gcons*
       ""
       (gmap (lambda (length)
               (generator->string (gdrop (char-generator) 1) length))
             (make-random-integer-generator
              1
              %property-testing-max-size))))

    (define (symbol-generator)
      "Return a generator of symbols."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding symbols made from generated strings."))
        (effects allocation state-write))
      (gmap string->symbol (string-generator)))

    (define (exact-complex-generator)
      "Return a generator of exact complex numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding exact complex numbers."))
        (effects allocation state-write error))
      (cond-expand
       (exact-complex
        (gappend
         (%property-testing-special-number-generator
          (lambda (value)
            (and (complex? value)
                 (exact? (real-part value))
                 (exact? (imag-part value)))))
         (gmap make-rectangular
               (exact-real-generator)
               (exact-real-generator))))
       (else (error "exact complex is not supported"))))

    (define (exact-integer-generator)
      "Return a generator of exact integers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding exact integers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator
        (lambda (value) (and (exact? value) (integer? value))))
       (make-random-integer-generator
        %property-testing-min-exact
        %property-testing-max-exact)))

    (define (%property-testing-ratio-generator)
      "Return a generator of exact ratios when the host supports them."
      (gmap /
            (make-random-integer-generator
             %property-testing-min-exact
             %property-testing-max-exact)
            (gfilter
             (lambda (value) (not (zero? value)))
             (make-random-integer-generator
              %property-testing-min-exact
              %property-testing-max-exact))))

    (define (exact-number-generator)
      "Return a generator of exact numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding exact numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator exact?)
       (cond-expand
        ((and ratios exact-complex)
         (gsampling
          (gmap make-rectangular (exact-real-generator) (exact-real-generator))
          (%property-testing-ratio-generator)
          (make-random-integer-generator
           %property-testing-min-exact
           %property-testing-max-exact)))
        (ratios
         (gsampling
          (%property-testing-ratio-generator)
          (make-random-integer-generator
           %property-testing-min-exact
           %property-testing-max-exact)))
        (exact-complex
         (gsampling
          (gmap make-rectangular (exact-real-generator) (exact-real-generator))
          (make-random-integer-generator
           %property-testing-min-exact
           %property-testing-max-exact)))
        (else
         (make-random-integer-generator
          %property-testing-min-exact
          %property-testing-max-exact)))))

    (define (exact-rational-generator)
      "Return a generator of exact rational numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding exact rational numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator
        (lambda (value) (and (rational? value) (exact? value))))
       (cond-expand
        (ratios
         (gsampling
          (%property-testing-ratio-generator)
          (make-random-integer-generator
           %property-testing-min-exact
           %property-testing-max-exact)))
        (else
         (make-random-integer-generator
          %property-testing-min-exact
          %property-testing-max-exact)))))

    (define (exact-real-generator)
      "Return a generator of exact real numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding exact real numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator
        (lambda (value) (and (real? value) (exact? value))))
       (cond-expand
        (ratios
         (gsampling
          (%property-testing-ratio-generator)
          (make-random-integer-generator
           %property-testing-min-exact
           %property-testing-max-exact)))
        (else
         (make-random-integer-generator
          %property-testing-min-exact
          %property-testing-max-exact)))))

    (define (exact-integer-complex-generator)
      "Return a generator of exact integer complex numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding exact complex numbers with integer parts."))
        (effects allocation state-write error))
      (cond-expand
       (exact-complex
        (gappend
         (%property-testing-special-number-generator
          (lambda (value)
            (and (complex? value)
                 (exact? (real-part value))
                 (exact? (imag-part value))
                 (integer? (real-part value))
                 (integer? (imag-part value)))))
         (gmap make-rectangular
               (make-random-integer-generator
                %property-testing-min-exact
                %property-testing-max-exact)
               (make-random-integer-generator
                %property-testing-min-exact
                %property-testing-max-exact))))
       (else (error "exact complex is not supported"))))

    (define (inexact-complex-generator)
      "Return a generator of inexact complex numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding inexact complex numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator
        (lambda (value)
          (and (complex? value)
               (inexact? (real-part value))
               (inexact? (imag-part value)))))
       (make-random-rectangular-generator
        %property-testing-min-inexact
        %property-testing-max-inexact
        %property-testing-min-inexact
        %property-testing-max-inexact)))

    (define (inexact-integer-generator)
      "Return a generator of inexact integers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding inexact integers."))
        (effects allocation state-write))
      (gmap inexact (exact-integer-generator)))

    (define (inexact-number-generator)
      "Return a generator of inexact numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding inexact numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator inexact?)
       (gsampling
        (make-random-rectangular-generator
         %property-testing-min-inexact
         %property-testing-max-inexact
         %property-testing-min-inexact
         %property-testing-max-inexact)
        (make-random-real-generator
         %property-testing-min-inexact
         %property-testing-max-inexact))))

    (define (inexact-rational-generator)
      "Return a generator of inexact rational numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding inexact rational numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator
        (lambda (value) (and (rational? value) (inexact? value))))
       (make-random-real-generator
        %property-testing-min-inexact
        %property-testing-max-inexact)))

    (define (inexact-real-generator)
      "Return a generator of inexact real numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding inexact real numbers."))
        (effects allocation state-write))
      (gappend
       (%property-testing-special-number-generator
        (lambda (value) (and (real? value) (inexact? value))))
       (make-random-real-generator
        %property-testing-min-inexact
        %property-testing-max-inexact)))

    (define (complex-generator)
      "Return a generator of exact or inexact complex numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding complex numbers."))
        (effects allocation state-write))
      (cond-expand
       (exact-complex
        (gsampling (exact-complex-generator) (inexact-complex-generator)))
       (else (inexact-complex-generator))))

    (define (integer-generator)
      "Return a generator of exact or inexact integers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding integers."))
        (effects allocation state-write))
      (gsampling (exact-integer-generator) (inexact-integer-generator)))

    (define (number-generator)
      "Return a generator of exact or inexact numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding numbers."))
        (effects allocation state-write))
      (gsampling (exact-number-generator) (inexact-number-generator)))

    (define (rational-generator)
      "Return a generator of exact or inexact rational numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding rational numbers."))
        (effects allocation state-write))
      (gsampling (exact-rational-generator) (inexact-rational-generator)))

    (define (real-generator)
      "Return a generator of exact or inexact real numbers."
      #((parameters)
        (returns (type procedure)
         (description "Generator yielding real numbers."))
        (effects allocation state-write))
      (gsampling (exact-real-generator) (inexact-real-generator)))

    (define (list-generator-of subgenerator . maybe-max-length)
      "Return a generator of lists whose elements come from SUBGENERATOR."
      #((parameters
         (subgenerator (type procedure)
          (description "Generator supplying list elements."))
         (maybe-max-length (type list)
          (description "Zero or one exclusive maximum list length.")))
        (returns (type procedure)
         (description "Generator yielding lists."))
        (effects allocation state-write procedure-call))
      (let ((max-length (if (null? maybe-max-length)
                            %property-testing-max-size
                            (car maybe-max-length))))
        (gcons*
         '()
         (gmap (lambda (length)
                 (generator->list subgenerator length))
               (make-random-integer-generator 1 max-length)))))

    (define (pair-generator-of car-generator . maybe-cdr-generator)
      "Return a generator of pairs whose parts come from generators."
      #((parameters
         (car-generator (type procedure)
          (description "Generator supplying pair cars."))
         (maybe-cdr-generator (type list)
          (description "Zero or one generator supplying pair cdrs.")))
        (returns (type procedure)
         (description "Generator yielding pairs."))
        (effects allocation state-write procedure-call))
      (let ((cdr-generator (if (null? maybe-cdr-generator)
                               car-generator
                               (car maybe-cdr-generator))))
        (gmap cons car-generator cdr-generator)))

    (define (procedure-generator-of subgenerator)
      "Return a generator of procedures returning generated values."
      #((parameters
         (subgenerator (type procedure)
          (description "Generator supplying procedure return values.")))
        (returns (type procedure)
         (description "Generator yielding variadic procedures."))
        (effects allocation state-write procedure-call))
      (gmap (lambda (value)
              (lambda arguments
                arguments
                value))
            subgenerator))

    (define (vector-generator-of subgenerator . maybe-max-length)
      "Return a generator of vectors whose elements come from SUBGENERATOR."
      #((parameters
         (subgenerator (type procedure)
          (description "Generator supplying vector elements."))
         (maybe-max-length (type list)
          (description "Zero or one exclusive maximum vector length.")))
        (returns (type procedure)
         (description "Generator yielding vectors."))
        (effects allocation state-write procedure-call))
      (let ((max-length (if (null? maybe-max-length)
                            %property-testing-max-size
                            (car maybe-max-length))))
        (gcons*
         (vector)
         (gmap (lambda (length)
                 (generator->vector subgenerator length))
               (make-random-integer-generator 0 max-length)))))

    (define (property-test-runner)
      "Return an SRFI 64 runner suitable for property tests."
      #((parameters)
        (returns (type test-runner)
         (description "Fresh SRFI 64 simple test runner."))
        (effects allocation state-write))
      (test-runner-simple))

    (define (%property-testing-test property generators runs assertion)
      "Run ASSERTION over PROPERTY, GENERATORS, and RUNS generated cases."
      (for-each
       (lambda (index)
         (assertion
          (lambda ()
            (let* ((arguments
                    (%property-testing-generated-arguments generators))
                   (runner (test-runner-current)))
              (%property-testing-record-arguments!
               runner
               arguments
               (+ index 1)
               runs)
              (apply property arguments)))))
       (iota runs)))

    (define (%property-testing-assert property generators runs)
      "Assert PROPERTY over RUNS generated argument tuples."
      (%property-testing-test
       property
       generators
       runs
       (lambda (thunk)
         (test-assert (thunk)))))

    (define (%property-testing-assert-error error-type property generators runs)
      "Assert PROPERTY raises ERROR-TYPE over RUNS generated argument tuples."
      (%property-testing-test
       property
       generators
       runs
       (lambda (thunk)
         (test-error error-type (thunk)))))

    (define (test-property property generators . maybe-runs)
      "Assert PROPERTY for generated values from GENERATORS."
      #((parameters
         (property (type procedure)
          (description "Predicate applied to generated arguments."))
         (generators (type list)
          (description "Generators supplying property arguments."))
         (maybe-runs (type list)
          (description "Zero or one assertion count.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write allocation procedure-call error))
      (%property-testing-assert
       property
       generators
       (%property-testing-run-count maybe-runs)))

    (define (test-property-expect-fail property generators . maybe-runs)
      "Assert PROPERTY as an expected failure over generated values."
      #((parameters
         (property (type procedure)
          (description "Predicate applied to generated arguments."))
         (generators (type list)
          (description "Generators supplying property arguments."))
         (maybe-runs (type list)
          (description "Zero or one assertion count.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write allocation procedure-call error))
      (let ((runs (%property-testing-run-count maybe-runs)))
        (test-expect-fail runs)
        (%property-testing-assert property generators runs)))

    (define (test-property-skip property generators . maybe-runs)
      "Skip PROPERTY assertions over generated values."
      #((parameters
         (property (type procedure)
          (description "Predicate applied to generated arguments."))
         (generators (type list)
          (description "Generators supplying property arguments."))
         (maybe-runs (type list)
          (description "Zero or one assertion count.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write allocation procedure-call error))
      (let ((runs (%property-testing-run-count maybe-runs)))
        (test-skip runs)
        (%property-testing-assert property generators runs)))

    (define (test-property-error property generators . maybe-runs)
      "Assert PROPERTY raises an error over generated values."
      #((parameters
         (property (type procedure)
          (description "Procedure expected to raise an error."))
         (generators (type list)
          (description "Generators supplying property arguments."))
         (maybe-runs (type list)
          (description "Zero or one assertion count.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write allocation procedure-call error))
      (%property-testing-assert-error
       #t
       property
       generators
       (%property-testing-run-count maybe-runs)))

    (define (test-property-error-type error-type property generators . maybe-runs)
      "Assert PROPERTY raises ERROR-TYPE over generated values."
      #((parameters
         (error-type . "Expected SRFI 64 error type descriptor.")
         (property (type procedure)
          (description "Procedure expected to raise an error."))
         (generators (type list)
          (description "Generators supplying property arguments."))
         (maybe-runs (type list)
          (description "Zero or one assertion count.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write allocation procedure-call error))
      (%property-testing-assert-error
       error-type
       property
       generators
       (%property-testing-run-count maybe-runs)))))
