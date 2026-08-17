;;; conformance-cases.scm --- Shared Consent Scheme conformance cases
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Version 2 uses structured source and expected datums by default.
;;; Exact lexical inputs remain text; substantial programs use files.

(consent-fixture-suite
  (version 2)
  (cases
    ((id reader-boolean-literals)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Boolean literals read as canonical booleans.")

     (source
       (text "#t"))
     (expect
       (value
         #t))
)
    ((id reader-long-boolean-literal)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Long boolean literals read as canonical booleans.")

     (source
       (text "#false"))
     (expect
       (value
         #f))
)
    ((id reader-bytevector-literal)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.9")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Bytevector literals read as bytevector datums.")

     (source
       (text "#u8(0 127 255)"))
     (expect
       (value
         #u8(0 127 255)))
)
    ((id reader-bytevector-byte-range-error)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.9")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Bytevector literal elements outside the byte range signal reader \
errors.")

     (source
       (text "#u8(256)"))
     (expect
       (condition
         (category read-error)))
)
    ((id reader-character-literal)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Character literals read as character datums.")

     (source
       (text "#\\space"))
     (expect
       (value
         #\space))
)
    ((id reader-character-unicode-scalar)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Hex character literals preserve Unicode scalar identity and canonical \
external writing.")

     (source
       (text "#\\x3bb"))
     (expect
       (value
         #\λ))
)
    ((id reader-character-supplementary-scalar)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Supplementary-plane character literals preserve scalar identity and \
printable external writing.")

     (source
       (text "#\\x1f642"))
     (expect
       (value
         #\🙂))
)
    ((id reader-character-invalid-surrogate)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Character literals reject surrogate code points outside the Unicode \
scalar range.")

     (source
       (text "#\\xd800"))
     (expect
       (condition
         (category read-error)))
)
    ((id reader-character-invalid-surrogate-end)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Character literals reject the upper endpoint of the surrogate range.")

     (source
       (text "#\\xdfff"))
     (expect
       (condition
         (category read-error)))
)
    ((id reader-character-invalid-out-of-range)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Character literals reject values above the Unicode scalar range.")

     (source
       (text "#\\x110000"))
     (expect
       (condition
         (category read-error)))
)
    ((id reader-character-malformed-hex)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
        "Malformed hexadecimal character names signal reader errors.")

     (source
       (text "#\\xzz"))
     (expect
       (condition
         (category read-error)))
)
    ((id reader-character-folded-name)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Consent's fold-case reader mode applies to its canonical character \
names.")

     (source
       (text "#!fold-case #\\Space"))
     (expect
       (value
         #\space))
)
    ((id reader-symbol-case-directive)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Case-folding directives affect subsequent symbols.")

     (source
       (text "#!fold-case Consent-Scheme"))
     (expect
       (value
         consent-scheme))
)
    ((id reader-no-fold-case-directive)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The no-fold-case directive restores the default identifier case \
behavior.")

     (source
       (text "#!fold-case #!no-fold-case Consent-Scheme"))
     (expect
       (value
         Consent-Scheme))
)
    ((id reader-string-line-continuation)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "String line continuations elide the escaped newline and intraline \
whitespace.")

     (source
       (text "\"a\\\n  b\""))
     (expect
       (value
         "ab"))
)
    ((id reader-number-radix-prefix)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.2.5")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Radix-prefixed numeric tokens read as numeric datums.")

     (source
       (text "#x2a"))
     (expect
       (value
         42))
)
    ((id reader-dotted-list)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Dotted lists read as proper pair chains with a final tail.")

     (source
       (text "(alpha beta . gamma)"))
     (expect
       (value
         (alpha beta . gamma)))
)
    ((id reader-vector-literal)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "6.8")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Vector literals read as vector datums.")

     (source
       (text "#(1 alpha \"ok\")"))
     (expect
       (value
         #(1 alpha "ok")))
)
    ((id reader-abbreviation-forms)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "4.1.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Reader abbreviations expand to their list forms.")

     (source
       (text "`(,alpha ,@beta)"))
     (expect
       (value
         (quasiquote ((unquote alpha) (unquote-splicing beta)))))
)
    ((id reader-comments-and-datum-comments)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Line, block, datum comments, and directives are intertoken space.")

     (source
       (text
         "; skip\n#| block #| nested |# done |# #;discard #!fold-case FOO"))
     (expect
       (value
         foo))
)
    ((id reader-escaped-identifier)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.1")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Chibi Scheme tests/r7rs-tests.scm and Gauche tests/symcase.scm")
       (source-url

          "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests\
.scm\
") (source-url
       "https://github.com/shirok/Gauche/blob/master/tests/symcase.scm")
       (license "BSD-style") (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (license-url "https://github.com/shirok/Gauche/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
       "Vertical-bar identifiers preserve escaped delimiter characters.")

     (source
       (text "|consent\\x2d;scheme|"))
     (expect
       (value
         consent-scheme))
)
    ((id reader-numeric-exactness-before-radix)
     (kind r7rs-conformance)
     (phase read)
     (category numeric-tower)
     (section "7.1.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "An exactness prefix may precede a numeric radix prefix.")

     (source
       (text "#e#x2a"))
     (expect
       (value
         42))
)
    ((id reader-numeric-radix-before-exactness)
     (kind r7rs-conformance)
     (phase read)
     (category numeric-tower)
     (section "7.1.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A numeric radix prefix may precede an exactness prefix.")

     (source
       (text "#x#e2a"))
     (expect
       (value
         42))
)
    ((id reader-numeric-duplicate-prefix-error)
     (kind r7rs-conformance)
     (phase read)
     (category numeric-tower)
     (section "7.1.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Conflicting exactness prefixes are rejected as malformed numeric \
syntax.")

     (source
       (text "#e#i1"))
     (expect
       (condition
         (category read-error)))
)
    ((id reader-numeric-like-peculiar-identifier)
     (kind r7rs-conformance)
     (phase read)
     (category numeric-tower)
     (section "7.1.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "A dot-led peculiar identifier is not misclassified as a malformed \
decimal.")

     (source
       (text ".e1"))
     (expect
       (value
         .e1))
)
    ((id reader-numeric-nondecimal-rectangular)
     (kind r7rs-conformance)
     (phase read)
     (category numeric-tower)
     (section "7.1.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Nondecimal rectangular literals parse each component in the prefixed \
radix.")

     (source
       (text "#xE-1i"))
     (expect
       (value
         14-1i))
)
    ((id primitive-procedure-call)
     (kind r7rs-conformance)
     (phase eval)
     (category primitive-expressions)
     (section "4.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Primitive procedure calls evaluate operator and operands.")

     (source
       (form
         (+ 1 2)))
     (expect
       (value
         3))
)
    ((id numeric-exact-rational-arithmetic)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Exact rational arithmetic remains exact and reduced.")

     (source
       (form
         (list (/ 3 4 5) (+ 1/2 1/3) (* 2/3 9/4))))
     (expect
       (value
         (3/20 5/6 3/2)))
)
    ((id numeric-exactness-conversions)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Exact and inexact conversions are explicit and printable.")

     (source
       (form
         (list (exact? 3/2) (inexact? 1.5) (exact (inexact 42))
               (number->string (inexact 3/2)))))
     (expect
       (value
         (#t #t 42 "1.5")))
)
    ((id numeric-radix-string-conversions)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Number string conversion honors supported R7RS radix arguments.")

     (source
       (form
         (list (number->string 42 16) (string->number "2a" 16)
               (string->number "101" 2))))
     (expect
       (value
         ("2a" 42 5)))
)
    ((id numeric-rationalize-tolerance)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "rationalize returns a simplest rational within the requested \
tolerance.")

     (source
       (form
         (list (rationalize 3/10 1/10) (rationalize 1/3 1/100))))
     (expect
       (value
         (1/3 1/3)))
)
    ((id numeric-exact-integer-sqrt-large)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Chibi Scheme tests/r7rs-tests.scm exact-integer-sqrt coverage")
       (source-url

          "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests\
.scm\
") (license "BSD-style") (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
       "exact-integer-sqrt handles a large exact power with zero remainder.")

     (source
       (form
         (call-with-values (lambda () (exact-integer-sqrt (expt 2 60)))
           list)))
     (expect
       (value
         (1073741824 0)))
)
    ((id numeric-complex-rectangular-arithmetic)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Rectangular complex literals participate in arithmetic.")

     (source
       (form
         (+ 1+2i 3/4-1/2i)))
     (expect
       (value
         7/4+3/2i))
)
    ((id numeric-inexact-special-values)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Inexact infinities and NaNs are recognized by the inexact library.")

     (source
       (forms
         (import (scheme inexact))
         (list (real? +inf.0) (rational? +inf.0) (infinite? +inf.0) (nan?
                                                                     +nan.0) (=
              +nan.0 +nan.0))))
     (expect
       (value
         (#t #f #t #t #f)))
)
    ((id numeric-polar-special-values)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Polar complex operations preserve canonical infinity and NaN \
components.")

     (source
       (forms
         (import (scheme complex))
         (list 0+inf.0i (make-polar +inf.0 0) (make-polar 1 +inf.0)
               (make-polar +nan.0 0))))
     (expect
       (value
         (0+inf.0i +inf.0+nan.0i +nan.0+nan.0i +nan.0+nan.0i)))
)
    ((id numeric-exact-integer-growth)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Exact integer arithmetic grows well beyond a machine word without \
coercion.")

     (source
       (form
         (list (expt 2 256) (+ (expt 2 256) 1))))
     (expect
       (value
         (#x10000000000000000000000000000000000000000000000000000000000000000
            ;; readability-allow: contiguous-datum -- Exact integer is atomic.
            #x10000000000000000000000000000000000000000000000000000000000000001)))
)
    ((id numeric-rational-reduction-growth)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Rational reduction removes a common factor larger than a machine word\
.")

     (source
       (form
         (/ (* 21 (expt 2 200)) (* 35 (expt 2 200)))))
     (expect
       (value
         3/5))
)
    ((id numeric-exactness-conversion-boundary)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Exact and inexact conversion crosses integers, rationals, and decimal\
s \
canonically.")

     (source
       (form
         (list (exact 1.5) (inexact 3/2) (exact (inexact 1/8))
               (number->string (inexact 3/2)))))
     (expect
       (value
         (3/2 1.5 1/8 "1.5")))
)
    ((id numeric-mixed-exact-inexact-ordering)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.5")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Mixed comparisons retain distinctions beyond binary64 precision.")

     (source
       (form
         (let* ((base (expt 2 100)) (rounded (inexact base)) (next (+ base
                                                                      1)))
            (list (= next rounded) (> next rounded) (= base

              rounded)))))
     (expect
       (value
         (#f #t #t)))
)
    ((id numeric-inexact-edge-arithmetic)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Infinity and NaN arithmetic and complex classification normalize \
across hosts.")

     (source
       (forms
         (import (scheme inexact))
         (list (+ +inf.0 -inf.0) (* +inf.0 -1.0) (/ +inf.0 +inf.0) (finite?
                                                                    1.0+2.0i)
            (nan? 1.0+nan.0i))))
     (expect
       (value
         (+nan.0 -inf.0 +nan.0 #t #t)))
)
    ((id numeric-binary64-rounding-boundaries)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Exact conversion and arithmetic round binary64 boundary cases to \
nearest, ties to even.")

     (source
       (form
         (list (number->string (inexact (/ 1 (expt 2 1075))))
               (number->string (inexact (/ 3 (expt 2 1076)))) (number->string
                                                               (inexact (/ (-
              (expt 2 53) 1) (expt 2 1075)))) (number->string

              (inexact 9007199254740993)) (number->string (+ 1.0

              (inexact (/ 1 (expt 2 53))))) (number->string (+

              1.0 (inexact (/ 3 (expt 2 53))))))))
     (expect
       (value
         ("0.0" "5e-324" "2.2250738585072014e-308" "9007199254740992.0"
          "1.0" "1.0000000000000004")))
)
    ((id numeric-complex-division)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Rectangular complex division preserves exact reduced components.")

     (source
       (form
         (/ 1+2i 3-4i)))
     (expect
       (value
         -1/5+2/5i))
)
    ((id numeric-complex-operation-matrix)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Exact rectangular complex arithmetic preserves reduced components \
across every basic operation.")

     (source
       (forms
         (import (scheme complex))
         (let ((left 3+4i) (right -2+5i)) (list (+ left right) (- left
                                                                  right) (*
              left right) (/ left right) (real-part left) (imag-part

              left) (= left (make-rectangular 3 4))))))
     (expect
       (value
         (1+9i 5-1i -26+7i 14/29-23/29i 3 4 #t)))
)
    ((id numeric-complex-polar-geometry)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Polar construction, magnitude, and angle agree within a cross-libm \
tolerance.")

     (source
       (forms
         (import (scheme complex) (scheme inexact))
         (let* ((epsilon 1e-12) (pi (* 4.0 (atan 1.0))) (value (make-polar
                                                                2.0 (/ pi
              6.0)))) (list (< (abs (- (real-part value)

              1.7320508075688772)) epsilon) (< (abs (- (imag-part value)

              1.0)) epsilon) (< (abs (- (magnitude value) 2.0))

              epsilon) (< (abs (- (angle 1.0+1.0i) (/ pi 4.0)))

              epsilon)))))
     (expect
       (value
         (#t #t #t #t)))
)
    ((id numeric-transcendental-accuracy-matrix)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Temporary transcendental accelerators satisfy representative \
identities within a cross-libm tolerance.")

     (source
       (forms
         (import (scheme inexact))
         (let* ((epsilon 1e-12) (pi (* 4.0 (atan 1.0)))) (list (< (abs (-
                                                                        (sin (/
              pi 6.0)) 0.5)) epsilon) (< (abs (- (cos (/ pi 3.0)) 0.5))

              epsilon) (< (abs (- (tan (/ pi 4.0)) 1.0)) epsilon) (< (abs

              (- (exp (log 2.0)) 2.0)) epsilon) (< (abs (- (asin

              0.5) (/ pi 6.0))) epsilon) (< (abs (- (acos 0.5)

              (/ pi 3.0))) epsilon) (< (abs (- (atan

              1.0) (/ pi 4.0))) epsilon) (< (abs (- (*

              (sqrt 2.0) (sqrt 2.0)) 2.0))

              epsilon)))))
     (expect
       (value
         (#t #t #t #t #t #t #t #t)))
)
    ((id numeric-transcendental-domain-boundaries)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Square root, logarithm, and two-argument arctangent honor principal \
domain boundaries.")

     (source
       (forms
         (import (scheme complex) (scheme inexact))
         (let* ((epsilon 1e-12) (pi (* 4.0 (atan 1.0))) (root (sqrt -1.0))
                (log-zero (log 0.0))) (list (< (abs (real-part root)) epsilon)
              (< (abs (-

              (imag-part root) 1.0)) epsilon) (infinite? log-zero) (< log-zero

              0.0) (< (abs (- (atan 0.0 -1.0) pi)) epsilon)))))
     (expect
       (value
         (#t #t #t #t #t)))
)
    ((id numeric-compiled-hot-path-smoke)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "A bounded fixnum and parsed-binary64 loop keeps compiled numeric and \
dispatch hot paths under test.")

     (source
       (form
         (let loop ((remaining 1000) (sum 0.0)) (if (= remaining 0) (= sum
                                                                       250.0)
              (loop (- remaining 1) (+ sum 0.25))))))
     (expect
       (value
         #t))
)
    ((id numeric-canonical-rendering)
     (kind r7rs-conformance)
     (phase eval)
     (category numeric-tower)
     (section "6.2.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Numeric rendering is canonical for large radix, rational, zero, \
special, and complex values.")

     (source
       (form
         (list (number->string (- (expt 2 128) 1) 16) (number->string (/ (*
                                                                          3
              (expt 2 200)) (* 5 (expt 2 200)))) (number->string 0.0)

            (number->string +inf.0) (number->string 1/2+3/4i))))
     (expect
       (value
         ("ffffffffffffffffffffffffffffffff" "3/5" "0.0" "+inf.0"
          "1/2+3/4i")))
)
    ((id derived-let-expression)
     (kind r7rs-conformance)
     (phase eval)
     (category derived-syntax)
     (section "4.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Derived binding syntax evaluates lexical bindings.")

     (source
       (form
         (let ((x 1) (y 2)) (+ x y))))
     (expect
       (value
         3))
)
    ((id derived-cond-arrow-literal-binding)
     (kind r7rs-conformance)
     (phase eval)
     (category derived-syntax)
     (section "4.2.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The cond => syntax respects lexical literal binding.")

     (source
       (form
         (list (cond ((assv (quote b) (quote ((a 1) (b 2)))) => cadr) (else
                                                                       #f))
            (let ((=> #f)) (cond (#t => (quote ok)))))))
     (expect
       (value
         (2 ok)))
)
    ((id derived-case-expression)
     (kind r7rs-conformance)
     (phase eval)
     (category derived-syntax)
     (section "4.2.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The case syntax dispatches by eqv? over datum clauses.")

     (source
       (form
         (case (car (quote (c d))) ((a e i o u) (quote vowel)) ((c d) (quote

              consonant)) (else (quote other)))))
     (expect
       (value
         consonant))
)
    ((id derived-do-expression)
     (kind r7rs-conformance)
     (phase eval)
     (category derived-syntax)
     (section "4.2.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The do syntax expands through nested ellipses.")

     (source
       (form
         (do ((i 0 (+ i 1)) (acc 0 (+ acc i))) ((= i 5) acc))))
     (expect
       (value
         10))
)
    ((id derived-quasiquote-expression)
     (kind r7rs-conformance)
     (phase eval)
     (category derived-syntax)
     (section "4.2.8")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Quasiquote evaluates unquote and unquote-splicing at the active depth\
.")

     (source
       (form
         (quasiquote (a (unquote (+ 1 2)) (unquote-splicing (list (quote b)
                                                                  (quote
              c)))))))
     (expect
       (value
         (a 3 b c)))
)
    ((id syntax-rules-unless)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A syntax-rules macro expands hygienically with ellipses.")

     (source
       (form
         (begin (define-syntax unless (syntax-rules () ((unless test body
                                                                ...) (if test
              #f (begin body ...))))) (unless #f 42))))
     (expect
       (value
         42))
)
    ((id syntax-rules-let-syntax-hygiene)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "A local syntax-rules macro resolves free template identifiers in its \
definition scope.")

     (source
       (form
         (let ((x (quote outer))) (let-syntax ((m (syntax-rules () ((m)
                                                                    x)))) (let
              ((x (quote inner))) (m))))))
     (expect
       (value
         outer))
)
    ((id syntax-rules-letrec-recursive-or)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3.1")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Chibi Scheme tests/r7rs-tests.scm letrec-syntax coverage") (source-url

          "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests\
.scm\
") (license "BSD-style") (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
       "letrec-syntax supports recursively expanded syntax-rules macros \
without capturing local temporaries.")

     (source
       (form
         (letrec-syntax ((choose (syntax-rules () ((choose) #f) ((choose
                                                                  expr) expr)
              ((choose expr rest ...) (let ((temp expr)) (if temp

              temp (choose rest ...))))))) (let ((temp (quote

              program))) (choose #f temp (quote unreached))))))
     (expect
       (value
         program))
)
    ((id syntax-rules-dotted-pattern-template)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description "syntax-rules supports improper patterns and templates.")

     (source
       (form
         (begin (define-syntax rest-list (syntax-rules () ((rest-list first
                                                                      . rest)
              (quote rest)))) (define-syntax make-pair (syntax-rules

              () ((make-pair left right) (quote (left . right))))) (list

              (rest-list a b c) (make-pair alpha beta)))))
     (expect
       (value
         ((b c) (alpha . beta))))
)
    ((id syntax-rules-nested-ellipsis)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "syntax-rules distributes nested ellipsis captures through templates.")

     (source
       (form
         (begin (define-syntax echo-groups (syntax-rules () ((echo-groups
                                                              ((head item ...)
              ...)) (quote ((head item ...) ...)))))
                (echo-groups ((a 1 2) (b 3) (c))))))
     (expect
       (value
         ((a 1 2) (b 3) (c))))
)
    ((id syntax-rules-custom-ellipsis)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "syntax-rules accepts a custom ellipsis identifier.")

     (source
       (form
         (begin (define-syntax collect (syntax-rules ::: () ((collect item
                                                                      :::)
              (list item :::)))) (collect 1 2 3))))
     (expect
       (value
         (1 2 3)))
)
    ((id syntax-rules-malformed-template-ellipsis)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "A repeated pattern variable used without a matching template ellipsis \
signals an expansion error.")

     (source
       (form
         (begin (define-syntax bad (syntax-rules () ((bad x ...) x))) (bad 1

              2))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id syntax-rules-syntax-error)
     (kind r7rs-conformance)
     (phase eval)
     (category syntax-rules)
     (section "4.3.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A syntax-error template signals an expansion-time error.")

     (source
       (form
         (begin (define-syntax bad-use (syntax-rules () ((bad-use x)
                                                         (syntax-error
              "bad macro" x)))) (bad-use 123))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id cond-expand-r7rs-feature)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "4.2.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "cond-expand selects statically recognized base features.")

     (source
       (form
         (cond-expand (r7rs (quote ok)) (else (quote missing)))))
     (expect
       (value
         ok))
)
    ((id library-cond-expand-library-feature)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5.6.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Library cond-expand declarations select available imported libraries.")

     (source
       (forms
         (define-library (consent fixture conditional) (cond-expand
                                                        ((library (scheme
              base)) (export answer) (import (scheme base))
                                                         (begin (define answer
              42))) (else (export answer) (begin (define

              answer (quote missing))))))
         (import (consent fixture conditional))
         answer))
     (expect
       (value
         42))
)
    ((id library-import-export)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A defined library exports a binding imported by a program.")

     (source
       (forms
         (define-library (consent fixture math) (export answer) (import
                                                                 (scheme base))
            (begin (define answer 42)))
         (import (consent fixture math))
         answer))
     (expect
       (value
         42))
)
    ((id library-exported-macro-scope)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Exported library macros resolve free template identifiers in the \
library scope.")

     (source
       (forms
         (define-library (consent fixture syntax) (export choose) (import
                                                                   (scheme
              base)) (begin (define default (quote library))

              (define-syntax choose (syntax-rules () ((choose) default)))))
         (import (scheme base) (consent fixture syntax))
         (let ((default (quote program))) (choose))))
     (expect
       (value
         library))
)
    ((id library-import-modifiers-composed)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5.2")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Chibi Scheme tests/lib-tests.scm and Racket R7RS import tests")
       (source-url
       "https://github.com/ashinn/chibi-scheme/blob/master/tests/lib-tests.scm\
") (source-url
       "https://github.com/lexi-lambda/racket-r7rs/tree/master/r7rs-test/tests\
") (license
       "Chibi BSD-style; Racket R7RS license file not present in repository")
       (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
       "Program imports compose only, rename, and prefix modifiers without \
local-name conflicts.")

     (source
       (forms
         (define-library (consent fixture mined imports) (export add
                                                                 subtract)
            (import (scheme base)) (begin (define (add x y) (+ x y))

              (define (subtract x y) (- x y))))
         (import (only (consent fixture mined imports) add) (prefix (rename
                                                                     (consent
              fixture mined imports) (subtract minus)) lib-))
         (list (add 1 2) (lib-add 3 4) (lib-minus 10 6))))
     (expect
       (value
         (3 7 4)))
)
    ((id library-imported-binding-immutable)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Imported bindings cannot be mutated by set!.")

     (source
       (forms
         (import (scheme base))
         (set! + 1)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id library-duplicate-export-error)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5.6.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Duplicate external export names are rejected.")

     (source
       (form
         (define-library (consent fixture duplicate-export) (export value
                                                                    value)
            (import (scheme base)) (begin (define value 1)))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id program-import-after-expression-error)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "5.1")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description "Program import declarations must precede body expressions.")

     (source
       (forms
         (import (scheme base))
         1
         (import (scheme cxr))
         (quote ok)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id library-include-policy-denied)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "4.1.7")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description

        "Library include declarations are denied unless host file policy allow\
s \
the path.")

     (source
       (form
         (define-library (consent fixture conformance include) (export
                                                                answer) (import
              (scheme base)) (include

              "fixtures/r7rs/include-body.scm"))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id library-include-ci-policy-denied)
     (kind r7rs-conformance)
     (phase eval)
     (category libraries)
     (section "4.1.7")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "Library include-ci declarations are denied unless host file policy \
allows the path.")

     (source
       (form
         (define-library (consent fixture conformance include-ci) (export
                                                                   mixedanswer)
            (import (scheme base)) (include-ci

              "fixtures/r7rs/include-ci-body.scm"))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id proper-tail-recursion-loop)
     (kind r7rs-conformance)
     (phase eval)
     (category proper-tail-recursion)
     (section "3.5")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A tail-recursive loop runs in constant continuation space.")

     (source
       (form
         (let loop ((n 1000) (acc 0)) (if (= n 0) acc (loop (- n 1) (+ acc
                                                                       1))))))
     (expect
       (value
         1000))
)
    ((id multiple-values-direct)
     (kind r7rs-conformance)
     (phase eval)
     (category multiple-values)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A program can return multiple values.")

     (source
       (form
         (values 1 2)))
     (expect
       (values
         1
         2))
)
    ((id multiple-values-call-with-values)
     (kind r7rs-conformance)
     (phase eval)
     (category multiple-values)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description "call-with-values passes producer values to a consumer.")

     (source
       (form
         (call-with-values (lambda () (values 1 2)) list)))
     (expect
       (value
         (1 2)))
)
    ((id multiple-values-let-values)
     (kind r7rs-conformance)
     (phase eval)
     (category multiple-values)
     (section "4.2.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "let-values and let*-values bind producer results to lexical variables\
.")

     (source
       (form
         (let ((a (quote a)) (b (quote b)) (x (quote x)) (y (quote y)))
           (let*-values (((a b) (values x y)) ((x y) (values a b))) (list a b x

              y)))))
     (expect
       (value
         (x y x y)))
)
    ((id multiple-values-define-values)
     (kind r7rs-conformance)
     (phase eval)
     (category multiple-values)
     (section "5.3.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "define-values creates multiple definitions from one producer.")

     (source
       (forms
         (define-values (root remainder) (exact-integer-sqrt 17))
         (define-values rest (values (quote a) (quote b)))
         (list root remainder rest)))
     (expect
       (value
         (4 1 (a b))))
)
    ((id exceptions-guard-raise)
     (kind r7rs-conformance)
     (phase eval)
     (category exceptions)
     (section "6.11")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "guard catches a raised object and evaluates the matching clause.")

     (source
       (form
         (guard (exn (else (quote caught))) (raise (quote boom)))))
     (expect
       (value
         caught))
)
    ((id exceptions-error-object-accessors)
     (kind r7rs-conformance)
     (phase eval)
     (category exceptions)
     (section "6.11")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Gauche tests/error.scm and Chibi Scheme tests/r7rs-tests.scm")
       (source-url
       "https://github.com/shirok/Gauche/blob/master/tests/error.scm")
       (source-url

          "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests\
.scm\
") (license "BSD-style") (license-url
       "https://github.com/shirok/Gauche/blob/master/COPYING") (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
        "guard can inspect R7RS error object messages and irritants.")

     (source
       (form
         (guard (exn ((error-object? exn) (list (error-object-message exn)
                                                (error-object-irritants exn))))
            (error "bad input" (quote alpha) 7))))
     (expect
       (value
         ("bad input" (alpha 7))))
)
    ((id exceptions-guard-primitive-error)
     (kind r7rs-conformance)
     (phase eval)
     (category exceptions)
     (section "6.11")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "guard catches the condition a primitive raises for an invalid \
argument.")

     (source
       (form
         (guard (exn (else (quote caught))) (car 5))))
     (expect
       (value
         caught))
)
    ((id exceptions-guard-primitive-error-object)
     (kind r7rs-conformance)
     (phase eval)
     (category exceptions)
     (section "6.11")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description

        "the condition a primitive raises satisfies error-object? inside guard\
.")

     (source
       (form
         (guard (exn ((error-object? exn) (quote error-object)) (else (quote
                                                                       other)))
            (vector-ref (vector 1) 5))))
     (expect
       (value
         error-object))
)
    ((id exceptions-raise-continuable)
     (kind r7rs-conformance)
     (phase eval)
     (category exceptions)
     (section "6.11")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "raise-continuable returns the handler's value to the raise site.")

     (source
       (form
         (with-exception-handler (lambda (exn) 42) (lambda () (+

              (raise-continuable (quote warning)) 23)))))
     (expect
       (value
         65))
)
    ((id exceptions-dynamic-wind-unwind)
     (kind r7rs-conformance)
     (phase eval)
     (category exceptions)
     (section "6.11")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "dynamic-wind after thunks run while guard handles a raised exception.")

     (source
       (form
         (let ((path (quote ()))) (guard (exn (else (reverse path)))
                                         (dynamic-wind (lambda () (set! path
              (cons (quote before) path)))
                                             (lambda () (set! path (cons (quote
              during) path)) (raise (quote

              boom))) (lambda () (set! path (cons (quote after)

              path))))))))
     (expect
       (value
         (before during after)))
)
    ((id continuations-escape)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description "call/cc captures an escape continuation.")

     (source
       (form
         (call/cc (lambda (escape) (+ 1 (escape 42))))))
     (expect
       (value
         42))
)
    ((id continuations-higher-order-escape)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Gauche tests/continuation.scm and Chibi Scheme tests/r7rs-tests.scm")
       (source-url
       "https://github.com/shirok/Gauche/blob/master/tests/continuation.scm")
       (source-url

          "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests\
.scm\
") (license "BSD-style") (license-url
       "https://github.com/shirok/Gauche/blob/master/COPYING") (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
       "A continuation captured inside a higher-order traversal can escape to \
the surrounding expression.")

     (source
       (form
         (call/cc (lambda (return) (for-each (lambda (x) (if (= x 3) (return
                                                                      x) #f))
              (quote (1 2 3 4))) #f))))
     (expect
       (value
         3))
)
    ((id continuations-dynamic-wind-exit)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "dynamic-wind runs its after thunk when an escape continuation exits \
its extent.")

     (source
       (form
         (let ((path (quote ()))) (define (add tag) (set! path (cons tag
                                                                     path)))
            (call/cc (lambda (escape) (dynamic-wind (lambda () (add

              (quote before))) (lambda () (add (quote during)) (escape

              (quote done))) (lambda () (add (quote after))))))
                                                                     (reverse
              path))))
     (expect
       (value
         (before during after)))
)
    ((id continuations-reenter-after-return)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "A continuation stored by call/cc can be invoked after its original \
call returns.")

     (source
       (form
         (let ((again #f)) (let ((value (call/cc (lambda (k) (set! again k)
                                                         (quote first))))) (if
              (eq? value (quote first)) (again (quote

              second)) value)))))
     (expect
       (value
         second))
)
    ((id continuations-repeated-invocation)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description "A captured continuation can be invoked repeatedly.")

     (source
       (form
         (let ((again #f) (seen (quote ()))) (let ((value (call/cc (lambda
                                                                       (k)
              (set! again k) (quote start))))) (set! seen (cons value

              seen)) (if (< (length seen) 3) (again (length seen))

              (reverse seen))))))
     (expect
       (value
         (start 1 2)))
)
    ((id continuations-dynamic-wind-reentry)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "dynamic-wind runs before thunks when a captured continuation re-enter\
s \
completed extents.")

     (source
       (form
         (let ((again #f) (outside #f) (path (quote ()))) (define (add tag)
                                                            (set! path (cons
              tag path))) (call/cc (lambda (escape) (set!

              outside escape) (dynamic-wind (lambda () (add (quote

              before-outer))) (lambda () (dynamic-wind (lambda ()

              (add (quote before-inner))) (lambda ()

              (call/cc (lambda (k) (set! again k) (quote

              captured))) (add (quote during-inner))

              (outside (quote escaped))) (lambda ()

              (add (quote after-inner)))))

              (lambda () (add (quote after-outer)))))) (if again

              (let ((resume again)) (set! again #f) (resume

              (quote resumed))) (reverse path)))))
     (expect
       (value
         (before-outer before-inner during-inner after-inner after-outer
                       before-outer before-inner during-inner after-inner
            after-outer)))
)
    ((id continuations-multiple-values)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Continuations deliver multiple values to call-with-values consumers.")

     (source
       (form
         (let ((again #f)) (call-with-values (lambda () (call/cc (lambda (k)
                                                                   (set! again
              k) (values 1 2)))) (lambda (a b) (if (= a 1) (again 3

              4) (list a b)))))))
     (expect
       (value
         (3 4)))
)
    ((id continuations-let-values-multiple-values)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Continuations deliver multiple values to let-values binding \
continuations.")

     (source
       (form
         (let ((again #f)) (let-values (((a b) (call/cc (lambda (k) (set!
                                                                     again k)
              (values 1 2))))) (if (= a 1) (again 3 4) (list a b))))))
     (expect
       (value
         (3 4)))
)
    ((id continuations-let*-values-multiple-values)
     (kind r7rs-conformance)
     (phase eval)
     (category continuations)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Continuations deliver multiple values to let*-values binding \
continuations.")

     (source
       (form
         (let ((again #f)) (let*-values (((a b) (call/cc (lambda (k) (set!
                                                                      again k)
              (values 1 2)))) ((c) (+ a b))) (if (= a 1) (again 3

              4) (list a b c))))))
     (expect
       (value
         (3 4 7)))
)
    ((id core-data-vector-ref)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.8")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Vector literals and vector-ref expose indexed values.")

     (source
       (form
         (vector-ref (quote #(a b c)) 1)))
     (expect
       (value
         b))
)
    ((id core-data-owned-pair-shared-mutation)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Mutating one pair alias changes the single shared referent.")

     (source
       (form
         (let* ((pair (cons (quote before) (quote tail)))
                (aliases (list pair pair)))
           (set-car! (car aliases) (quote after))
           (list (eq? (car aliases) (cadr aliases))
                 (car (cadr aliases))))))
     (expect
       (value
         (#t after)))
)
    ((id core-data-owned-vector-shared-mutation)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.8")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Mutating one vector alias changes the single shared referent.")

     (source
       (form
         (let* ((vector (vector (quote before)))
                (aliases (list vector vector)))
           (vector-set! (car aliases) 0 (quote after))
           (list (eq? (car aliases) (cadr aliases))
                 (vector-ref (cadr aliases) 0)))))
     (expect
       (value
         (#t after)))
)
    ((id core-data-owned-string-shared-mutation)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "String mutation is visible through every alias of the string.")

     (source
       (form
         (let* ((string (string-copy "heap"))
                (aliases (list string string)))
           (string-set! (car aliases) 0 #\s)
           (list (string-ref (car aliases) 0)
                 (string-ref (cadr aliases) 0)
                 (cadr aliases)))))
     (expect
       (value
         (#\s #\s "seap")))
)
    ((id core-data-owned-bytevector-shared-mutation)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.9")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Bytevector mutation is visible through every alias of the value.")

     (source
       (form
         (let* ((bytes (bytevector 1 2 3))
                (aliases (list bytes bytes)))
           (bytevector-u8-set! (car aliases) 1 9)
           (list (bytevector-u8-ref (car aliases) 1)
                 (bytevector-u8-ref (cadr aliases) 1)))))
     (expect
       (value
         (9 9)))
)
    ((id core-data-owned-pair-cycle-mutation-equality)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Pair mutation preserves identity and equal? terminates on cycles.")

     (source
       (form
         (let ((left (cons (quote before) (quote ())))
               (right (cons (quote before) (quote ()))))
           (set-cdr! left left)
           (set-cdr! right right)
           (set-car! left (quote after))
           (set-car! right (quote after))
           (equal? left right))))
     (expect
       (value
         #t))
)
    ((id core-data-owned-vector-cycle-mutation-equality)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Vector mutation preserves identity and equal? terminates on cycles.")

     (source
       (form
         (let ((left (vector (quote before) #f))
               (right (vector (quote before) #f)))
           (vector-set! left 1 left)
           (vector-set! right 1 right)
           (vector-set! left 0 (quote after))
           (vector-set! right 0 (quote after))
           (equal? left right))))
     (expect
       (value
         #t))
)
    ((id core-equivalence-owned-value-categories)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.1")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Owned scalar and compound identities do not vary by host.")

     (source
       (form
         (let* ((pair (list (quote value)))
                (other-pair (list (quote value)))
                (string (string-copy "value"))
                (other-string (string-copy "value"))
                (vector-value (vector (quote value)))
                (other-vector (vector (quote value)))
                (bytes (bytevector 1 2 3))
                (other-bytes (bytevector 1 2 3)))
           (list
            (eq? #t #t)
            (not (eq? #t #f))
            (eqv? (quote ()) (quote ()))
            (eq? (quote owned) (string->symbol "owned"))
            (eqv? 17 17)
            (eq? #\x #\x)
            (eq? pair pair)
            (not (eqv? pair other-pair))
            (equal? pair other-pair)
            (eq? string string)
            (not (eqv? string other-string))
            (equal? string other-string)
            (eq? vector-value vector-value)
            (not (eqv? vector-value other-vector))
            (equal? vector-value other-vector)
            (eq? bytes bytes)
            (not (eqv? bytes other-bytes))
            (equal? bytes other-bytes)))))
     (expect
       (value
         (#t #t #t #t #t #t #t #t #t
          #t #t #t #t #t #t #t #t #t)))
)
    ((id core-equivalence-opaque-location-tags)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.1")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Records, procedures, and ports preserve explicit location identity.")

     (source
       (forms
         (define-record-type <equivalence-box>
           (make-equivalence-box value)
           equivalence-box?
           (value equivalence-box-value))
         (let* ((record (make-equivalence-box 1))
                (same-record record)
                (other-record (make-equivalence-box 1))
                (procedure (lambda (value) value))
                (same-procedure procedure)
                (other-procedure (lambda (value) value))
                (port (open-input-string "value"))
                (same-port port)
                (other-port (open-input-string "value")))
           (list
            (eq? record same-record)
            (not (eqv? record other-record))
            (not (equal? record other-record))
            (eq? procedure same-procedure)
            (not (eqv? procedure other-procedure))
            (not (equal? procedure other-procedure))
            (eq? car car)
            (eq? port same-port)
            (not (eqv? port other-port))
            (equal? port same-port)))))
     (expect
       (value
         (#t #t #t #t #t #t #t #t #t #t)))
)
    ((id core-equivalence-membership-and-association)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Membership and association procedures use their named predicates.")

     (source
       (form
         (let* ((same (list (quote value)))
                (equal (list (quote value)))
                (items (list equal same))
                (alist (list (cons equal (quote structural))
                             (cons same (quote identity)))))
           (list
            (eq? (memq same items) (cdr items))
            (eq? (memv same items) (cdr items))
            (eq? (member same items) items)
            (eq? (assq same alist) (cadr alist))
            (eq? (assv same alist) (cadr alist))
            (eq? (assoc same alist) (car alist))))))
     (expect
       (value
         (#t #t #t #t #t #t)))
)
    ((id reader-datum-label-cycle)
     (kind r7rs-conformance)
     (phase read)
     (category reader-syntax)
     (section "2.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description "Datum labels read circular structure.")

     (source
       (text "#1=(a . #1#)"))
     (expect
       (serialized-value "#0=(a . #0#)"))
)
    ((id core-data-record-type)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "5.5")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "define-record-type creates constructors, predicates, accessors, and \
mutators.")

     (source
       (forms
         (define-record-type <pare> (kons x y) pare? (x kar set-kar!) (y
                                                                       kdr))
         (let ((p (kons 1 2))) (set-kar! p 3) (list (pare? p) (pare? (cons 1
                                                                           2))
              (kar p) (kdr p)))))
     (expect
       (value
         (#t #f 3 2)))
)
    ((id core-data-circular-equal)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.1")
     (status implemented)
     (oracle shared)
     (options ())
     (description
        "equal? terminates on circular data and compares unfoldings.")

     (source
       (file "programs/circular-equality.scm"))
     (expect
       (value
         #t))
)
    ((id core-data-owned-symbol-identity)
     (kind r7rs-conformance)
     (phase eval)
     (category equivalence)
     (section "6.5")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Reader, string conversion, and macro-introduced symbols share portabl\
e \
identity.")

     (source
       (form
         (let* ((quoted (quote portable)) (converted (string->symbol
                                                      "portable"))) (list
              (symbol? quoted) (symbol=? quoted converted)
                                                                          (eq?
              quoted converted) (eqv? quoted converted) (equal? quoted

              converted) (let-syntax ((introduce (syntax-rules () ((_)

              (quote portable))))) (eq? (introduce)

              converted))))))
     (expect
       (value
         (#t #t #t #t #t #t)))
)
    ((id core-data-eof-object)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description "EOF objects satisfy eof-object?.")

     (source
       (form
         (eof-object? (eof-object))))
     (expect
       (value
         #t))
)
    ((id standard-library-case-lambda)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The case-lambda library dispatches procedures by arity.")

     (source
       (forms
         (import (scheme base) (scheme case-lambda))
         ((case-lambda ((x) x) ((x y) (+ x y))) 1 2)))
     (expect
       (value
         3))
)
    ((id standard-library-case-lambda-rest)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "4.2.9")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The case-lambda library supports variadic and dotted clause formals.")

     (source
       (forms
         (import (scheme base) (scheme case-lambda))
         (list ((case-lambda ((x) x) ((x y . rest) (list x y rest))) 1 2 3)
               ((case-lambda (all all)) (quote a) (quote b)))))
     (expect
       (value
         ((1 2 (3)) (a b))))
)
    ((id standard-library-char-upcase)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The char library provides character case operations.")

     (source
       (forms
         (import (scheme base) (scheme char))
         (char-upcase #\a)))
     (expect
       (value
         #\A))
)
    ((id standard-library-char-foldcase)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The char library provides predicates, digit values, and \
case-insensitive comparisons.")

     (source
       (forms
         (import (scheme base) (scheme char))
         (list (char-foldcase #\A) (char-alphabetic? #\A) (char-numeric?
                                                           #\9)
            (char-whitespace? #\space) (digit-value #\9) (char-ci=? #\A

              #\a) (string-upcase "Az"))))
     (expect
       (value
         (#\a #t #t #t 9 #t "AZ")))
)
    ((id core-data-character-scalar-model)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Character construction, conversion, equivalence, and ordering use \
Unicode scalar values.")

     (source
       (forms
         (import (scheme base))
         (let ((maximum (integer->char 1114111)) (lambda-character
                                                  (integer->char 955))) (list
              (char? maximum) (char->integer maximum)

              (eqv? lambda-character (integer->char 955)) (char<? #\A

              lambda-character) (string<? "A" (string

              lambda-character))))))
     (expect
       (value
         (#t 1114111 #t #t #t)))
)
    ((id core-data-character-invalid-surrogate)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "integer->char rejects surrogate code points outside the owned scalar \
range.")

     (source
       (forms
         (import (scheme base))
         (integer->char 55296)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id core-data-character-invalid-scalar-matrix)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Owned character construction rejects negative, surrogate, \
out-of-range, non-integer, and inexact values.")

     (source
       (forms
         (import (scheme base))
         (define (raises? thunk) (guard (condition (else #t)) (thunk) #f))
         (let loop ((values (list -1 55296 57343 1114112 1/2 1.0 "1" #f)))
           (or (null? values) (and (raises? (lambda () (integer->char (car

              values)))) (loop (cdr values)))))))
     (expect
       (value
         #t))
)
    ((id core-data-character-string-port-boundaries)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Owned BMP, supplementary, and maximum characters cross string, vector\
, \
and textual-port boundaries without host identity leaks.")

     (source
       (forms
         (import (scheme base))
         (let* ((codes (quote (0 955 8364 128578 1114111))) (characters (map

              integer->char codes)) (text (list->string characters)) (copy

              (string-copy text)) (vector (string->vector text)) (in

              (open-input-string text)) (out

              (open-output-string)) (peeked (peek-char in))

              (read-back (read-char in))) (string-set! copy 1

              (integer->char 8364)) (write-char

              (integer->char 128578) out) (list

              (char->integer (string-ref text

              3)) (map char->integer

              (string->list text)) (map

              char->integer

              (vector->list vector))

              (map char->integer (string->list

              (vector->string vector)))

              (map char->integer (string->list

              copy)) (char->integer

              peeked) (char->integer

              read-back) (map

              char->integer

              (string->list

              (get-output-string

              out)))))))
     (expect
       (value
         (128578 (0 955 8364 128578 1114111) (0 955 8364 128578 1114111) (0
                                                                          955
              8364 128578 1114111) (0 8364 8364 128578 1114111) 0 0

            (128578))))
)
    ((id core-data-character-comparison-matrix)
     (kind r7rs-conformance)
     (phase eval)
     (category core-data-types)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Base character and string comparisons cover true, false, equality, an\
d \
variadic scalar-order cases.")

     (source
       (forms
         (import (scheme base))
         (list (char=? #\A (integer->char 65) #\A) (char=? #\A #\B) (char<?
                                                                     #\A #\B
              #\C) (char<? #\A #\A) (char>? #\C #\B #\A) (char>? #\C

              #\C) (char<=? #\A #\A #\B) (char<=? #\B #\A) (char>=? #\C

              #\C #\B #\A) (char>=? #\A #\B) (string=? "A" "A"

              "A") (string=? "A" "B") (string<? "A" "B"

              "C") (string<? "A" "A") (string>? "C" "B"

              "A") (string>? "C" "C") (string<=?

              "A" "A" "B") (string<=? "B" "A")

            (string>=? "C" "C" "B" "A")

            (string>=? "A" "B"))))
     (expect
       (value
         (#t #f #t #f #t #f #t #f #t #f #t #f #t #f #t #f #t #f #t #f)))
)
    ((id standard-library-char-owned-unicode-profile)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The Unicode 17 profile classifies representative Greek letters, \
decimal digits, and whitespace without host tables.")

     (source
       (forms
         (import (scheme base) (scheme char))
         (list (char-alphabetic? (integer->char 955)) (char-lower-case?
                                                       (integer->char 955))
            (char-upper-case? (integer->char 923))
                                                       (char-numeric?
              (integer->char 1636)) (digit-value

              (integer->char 1636)) (digit-value (integer->char 2790))

            (char-whitespace? (integer->char 12288)) (char-alphabetic?

              (integer->char 3750)))))
     (expect
       (value
         (#t #t #t #t 4 0 #t #f)))
)
    ((id standard-library-char-owned-classification-tables)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Representative BMP page boundaries, supplementary cased ranges, \
uncased alphabetics, and unassigned exclusions follow generated tables.")

     (source
       (file "programs/character-classification-tables.scm"))
     (expect
       (value
         (#t #t #t #t)))
)
    ((id standard-library-char-owned-digit-whitespace-tables)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Decimal digits across BMP and supplementary scripts plus Unicode \
whitespace and excluded neighbors follow the generated tables.")

     (source
       (file "programs/character-digit-whitespace-tables.scm"))
     (expect
       (value
         (#t #t #t #t)))
)
    ((id standard-library-char-owned-case-mappings)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Simple character and full string case mappings follow the documented \
Unicode 17 profile.")

     (source
       (forms
         (import (scheme base) (scheme char))
         (list (char->integer (char-upcase (integer->char 962)))
               (char->integer (char-foldcase (integer->char 962))) (map

              char->integer (string->list (string-upcase (string

              (integer->char 223))))) (map char->integer (string->list

              (string-downcase (string (integer->char 304))))) (map

              char->integer (string->list (string-foldcase

              (string (integer->char 7838))))))))
     (expect
       (value
         (931 963 (83 83) (105 775) (115 115))))
)
    ((id standard-library-char-owned-case-tables)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason implementation-dependent)
     (options ())
     (description
       "Representative simple BMP and supplementary mappings, full \
expansions, and maximum-scalar identity follow generated case data.")

     (source
       (file "programs/character-case-tables.scm"))
     (expect
       (value
         (#t #t (223 963 304 223 66600) (83 83) (105 775)
             (115 115 115 115 105 775) (70 70 73) (102 102 105)
             (921 776 769) (8364 128578 1114111))))
)
    ((id standard-library-char-comparison-matrix)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.6")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "Every character-ci and string-ci export covers true, false, variadic, \
expansion, prefix, and non-normalizing behavior.")

     (source
       (forms
         (import (scheme base) (scheme char))
         (let ((sharp-s (string (integer->char 223))) (capital-sharp-s
                                                       (string (integer->char
              7838))) (precomposed (string

              (integer->char 233))) (decomposed (string #\e (integer->char

              769)))) (list (char-ci=? #\A #\a #\A) (char-ci=? #\A

              #\B) (char-ci<? #\A #\b #\C) (char-ci<? #\A #\a)

              (char-ci>? #\C #\b #\A) (char-ci>? #\C #\C)

              (char-ci<=? #\A #\a #\B) (char-ci<=? #\B #\A)

              (char-ci>=? #\C #\c #\B #\a) (char-ci>=? #\A

              #\B) (string-ci=? sharp-s "SS"

              capital-sharp-s) (string-ci=? "A" "B")

              (string-ci<? "A" "b" "C") (string-ci<?

              "A" "a") (string-ci>? "C" "b" "A")

              (string-ci>? "C" "c") (string-ci<=? "A"

              "a" "B") (string-ci<=? "B" "A")

              (string-ci>=? "C" "c" "B" "a")

              (string-ci>=? "A" "B")

              (string-ci=? precomposed

              decomposed)))))
     (expect
       (value
         (#t #f #t #f #t #f #t #f #t #f #t #f #t #f #t #f #t #f #t #f #f)))
)
    ((id standard-library-cxr-cadr)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The cxr library provides composed list accessors.")

     (source
       (forms
         (import (scheme base) (scheme cxr))
         (cadr (quote (a b c)))))
     (expect
       (value
         b))
)
    ((id standard-library-cxr-cadddr)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.4")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The cxr library provides three- and four-level composed accessors.")

     (source
       (forms
         (import (scheme base) (scheme cxr))
         (cadddr (quote (a b c d e)))))
     (expect
       (value
         d))
)
    ((id standard-library-lazy-force)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (options ())
     (description "The lazy library forces delayed expressions once.")

     (source
       (forms
         (import (scheme base) (scheme lazy))
         (force (delay (+ 1 2)))))
     (expect
       (value
         3))
)
    ((id standard-library-write-display)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The write library can render values to an output string port.")

     (source
       (forms
         (import (scheme base) (scheme write))
         (let ((out (open-output-string))) (display "ok" out)
              (get-output-string out))))
     (expect
       (value
         "ok"))
)
    ((id standard-library-write-shared)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description "write-shared labels shared pair structure.")

     (source
       (forms
         (import (scheme base) (scheme write))
         (let ((x (list (quote a)))) (let ((out (open-output-string)))
                                       (write-shared (list x x) out)
              (get-output-string out)))))
     (expect
       (value
         "(#0=(a) #0#)"))
)
    ((id standard-library-write-shared-after-alias-mutation)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "write-shared preserves aliases after mutation through one local path.")

     (source
       (forms
         (import (scheme base) (scheme write))
         (let* ((shared (list (quote before)))
                (left (vector shared))
                (right (vector shared))
                (out (open-output-string)))
           (set-car! (vector-ref left 0) (quote after))
           (write-shared (list left right) out)
           (list (eq? (vector-ref left 0) (vector-ref right 0))
                 (equal? left right)
                 (get-output-string out)))))
     (expect
       (value
         (#t #t "(#(#0=(after)) #(#0#))")))
)
    ((id standard-library-write-owned-cycles-after-mutation)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "write labels mutated pair and vector cycles by owned identity.")

     (source
       (forms
         (import (scheme base) (scheme write))
         (let ((pair (cons (quote before) (quote ())))
               (vector (vector (quote before) #f))
               (pair-out (open-output-string))
               (vector-out (open-output-string)))
           (set-cdr! pair pair)
           (set-car! pair (quote after))
           (vector-set! vector 1 vector)
           (vector-set! vector 0 (quote after))
           (write pair pair-out)
           (write vector vector-out)
           (list (get-output-string pair-out)
                 (get-output-string vector-out)))))
     (expect
       (value
         ("#0=(after . #0#)" "#0=#(after #0#)")))
)
    ((id standard-library-write-simple)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description
        "write-simple renders acyclic datums without sharing labels.")

     (source
       (forms
         (import (scheme base) (scheme write))
         (let ((out (open-output-string))) (write-simple (quote #(1 "x"))
                                                         out)
            (get-output-string out))))
     (expect
       (value
         "#(1 \"x\")"))
)
    ((id standard-library-write-circular)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description "write labels circular pair structure.")

     (source
       (file "programs/write-circular.scm"))
     (expect
       (value
         "#0=(a . #0#)"))
)
    ((id standard-library-read-string-port)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The read library reads Consent Scheme datums from input string ports.")

     (source
       (forms
         (import (scheme base) (scheme read) (scheme write))
         (let ((in (open-input-string "(alpha 1) ")) (out
                                                      (open-output-string)))
            (write (read in) out) (write-char

              (read-char in) out) (list (get-output-string out)

              (eof-object? (read in))))))
     (expect
       (value
         ("(alpha 1) " #t)))
)
    ((id standard-library-read-write-roundtrip)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (provenance (inspired-by
       "Chibi Scheme tests/r7rs-tests.scm and Gauche tests/io.scm") (source-url

          "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests\
.scm\
") (source-url
       "https://github.com/shirok/Gauche/blob/master/tests/io.scm") (license
       "BSD-style") (license-url
       "https://github.com/ashinn/chibi-scheme/blob/master/COPYING")
       (license-url "https://github.com/shirok/Gauche/blob/master/COPYING")
       (review-note
       "Consent Scheme-owned rewrite; no third-party test text copied."))
     (description
       "A datum written to an output string port can be read back from an \
input string port.")

     (source
       (forms
         (import (scheme base) (scheme read) (scheme write))
         (let ((out (open-output-string))) (write (quote (alpha "beta" 3))
                                                  out) (read (open-input-string
              (get-output-string out))))))
     (expect
       (value
         (alpha "beta" 3)))
)
    ((id standard-library-owned-symbol-roundtrip)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.5")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "Writing and reading an escaped symbol preserves its portable identity\
.")

     (source
       (forms
         (import (scheme base) (scheme read) (scheme write))
         (let* ((symbol (string->symbol "K. Harper, M.D.")) (out

              (open-output-string))) (write symbol out) (let ((read-back (read

              (open-input-string (get-output-string out))))) (list

              (get-output-string out) (symbol? read-back) (eq?

              symbol read-back))))))
     (expect
       (value
         ("|K. Harper, M.D.|" #t #t)))
)
    ((id standard-library-bytevector-ports)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "In-memory bytevector ports read and write binary bytes without host \
access.")

     (source
       (forms
         (import (scheme base))
         (let ((in (open-input-bytevector #u8(1 2 3))) (out

              (open-output-bytevector))) (write-u8 (read-u8 in) out)
                                                        (write-bytevector
              (read-bytevector 4 in) out) (list (eof-object?

              (read-u8 in)) (get-output-bytevector out)))))
     (expect
       (value
         (#t #u8(1 2 3))))
)
    ((id standard-library-read-bytevector-partial)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "read-bytevector! writes a partial binary read into the requested \
bytevector range.")

     (source
       (forms
         (import (scheme base))
         (let ((target (bytevector 9 9 9 9)) (in (open-input-bytevector
                                                  #u8(1 2)))) (list
              (read-bytevector! target in 1 4) target

              (eof-object? (read-bytevector! target in))))))
     (expect
       (value
         (2 #u8(9 1 2 9) #t)))
)
    ((id standard-library-write-string-range-newline)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13.3")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "write-string range arguments and newline write to explicit string \
output ports.")

     (source
       (forms
         (import (scheme base))
         (let ((out (open-output-string))) (write-string "agent" out 1 4)
              (newline out) (get-output-string out))))
     (expect
       (value
         "gen\n"))
)
    ((id standard-library-base-features-utf8)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.14")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The base library exposes feature discovery and UTF-8 bytevector \
conversions.")

     (source
       (forms
         (import (scheme base))
         (let ((bytes (string->utf8 "agent"))) (list (pair? (memq (quote
                                                                   r7rs)
              (features))) bytes (utf8->string bytes 1 4)))))
     (expect
       (value
         (#t #u8(97 103 101 110 116) "gen")))
)
    ((id standard-library-base-utf8-unicode-scalars)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description

        "UTF-8 conversion round-trips every one- through four-byte boundary an\
d \
both sides of the surrogate gap.")

     (source
       (forms
         (import (scheme base))
         (let* ((codes (quote (0 127 128 2047 2048 55295 57344 65535 65536
                                 1114111))) (text (list->string (map
              integer->char codes))) (bytes

              (string->utf8 text))) (list bytes (map char->integer

              (string->list (utf8->string bytes)))))))
     (expect
       (value
         (#u8(0 127 194 128 223 191 224 160 128 237 159 191 238 128 128 239
                191 191 240 144 128 128 244 143 191 191) (0 127 128 2047 2048
              55295 57344
                                                            65535 65536
              1114111))))
)
    ((id standard-library-base-utf8-range-slices)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 range arguments handle multibyte character boundaries and empty \
string and bytevector slices.")

     (source
       (forms
         (import (scheme base))
         (let* ((text (list->string (map integer->char (quote (65 955 8364
                                                                  128578
              90))))) (bytes (string->utf8 text)) (middle (string->utf8

              text 1 4))) (list middle (map char->integer

              (string->list (utf8->string bytes 1 10)))

              (utf8->string bytes 3 3) (string->utf8 text 2 2)))))
     (expect
       (value
         (#u8(206 187 226 130 172 240 159 153 130) (955 8364 128578) ""
             #u8())))
)
    ((id standard-library-base-utf8-rejects-split-range-start)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects a range that starts inside a multibyte \
sequence.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(65 206 187 226 130 172 240 159 153 130 90) 2 10)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-split-range-end)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects a range that ends inside a multibyte sequence.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(65 206 187 226 130 172 240 159 153 130 90) 1 2)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-stray-continuation)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects a continuation byte without a leading byte.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-truncated-two-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a truncated two-byte sequence.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(194))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-truncated-three-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a truncated three-byte sequence.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(224 160))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-truncated-four-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a truncated four-byte sequence.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(240 144 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-bad-two-byte-continuation)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a malformed two-byte continuation.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(194 32))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-bad-three-byte-continuation)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
        "UTF-8 decoding rejects a malformed three-byte continuation.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(225 128 32))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-bad-four-byte-continuation)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a malformed four-byte continuation.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(241 128 128 32))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-overlong-three-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a three-byte overlong encoding.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(224 128 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-overlong-four-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects a four-byte overlong encoding.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(240 128 128 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-surrogate-end)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects the upper endpoint of the surrogate range.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(237 191 191))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-above-maximum)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects an encoding above U+10FFFF.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(244 144 128 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-high-leading-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects leading bytes above the four-byte range.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(245 128 128 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-invalid-leading-byte)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects a byte that cannot begin any sequence.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(255))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-overlong)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "UTF-8 decoding rejects overlong encodings instead of accepting host \
replacement behavior.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(192 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-base-utf8-rejects-surrogate)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.7")
     (status implemented)
     (oracle shared)
     (options ())
     (description "UTF-8 decoding rejects encoded surrogate code points.")

     (source
       (forms
         (import (scheme base))
         (utf8->string #u8(237 160 128))))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-current-output-port)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.13")
     (status policy-gated)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "Current output ports expose default textual output only after \
host/session policy exists.")

     (source
       (forms
         (import (scheme base))
         (output-port? (current-output-port))))
     (expect
       (value
         #t))
)
    ((id standard-library-eval-environment)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.12")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The eval library evaluates Scheme expressions in explicit library \
environments.")

     (source
       (forms
         (import (scheme base) (scheme eval))
         (eval (quote (* 7 3)) (environment (quote (scheme base))))))
     (expect
       (value
         21))
)
    ((id standard-library-inexact-transcendentals)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.2")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The inexact library exports representative real-valued transcendental \
procedures.")

     (source
       (forms
         (import (scheme inexact))
         (list (sqrt 9) (sin 0) (cos 0) (tan 0) (exp 0) (log 1))))
     (expect
       (value
         (3.0 0.0 1.0 0.0 1.0 0.0)))
)
    ((id standard-library-load-policy-denied)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.14")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "The load library denies host file loading unless policy allows it.")

     (source
       (forms
         (import (scheme base) (scheme load))
         (load "fixtures/r7rs/include-body.scm")))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-file-exists-policy)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.14")
     (status policy-gated)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "The file library is available only through host file policy.")

     (source
       (forms
         (import (scheme base) (scheme file))
         (file-exists? "fixtures/r7rs/conformance-cases.scm")))
     (expect
       (value
         #t))
)
    ((id standard-library-process-context-policy-denied)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.14")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "The process-context library imports but denies process access unless \
policy allows it.")

     (source
       (forms
         (import (scheme base) (scheme process-context))
         (command-line)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-time-policy-denied)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.14")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "The time library imports but denies host time access unless policy \
allows it.")

     (source
       (forms
         (import (scheme base) (scheme time))
         (current-second)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-time-clock-grant)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.14")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ((capability-grants ((capability-grant (id fixture-clock-grant)
       (domain clock) (operations read) (scope (clock system)) (expires
       never))))))
     (description
       "The time library returns R7RS-shaped clock values when a clock grant \
authorizes host observation.")

     (source
       (forms
         (import (scheme base) (scheme time))
         (list (real? (current-second)) (exact-integer? (current-jiffy))
               (exact-integer? (jiffies-per-second)) (> (jiffies-per-second)
              0))))
     (expect
       (value
         (#t #t #t #t)))
)
    ((id standard-library-repl-policy-denied)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.12")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ())
     (description
       "The repl library imports but denies interaction-environment unless \
session policy allows it.")

     (source
       (forms
         (import (scheme base) (scheme repl))
         (interaction-environment)))
     (expect
       (condition
         (category evaluation-error)))
)
    ((id standard-library-repl-interaction-environment)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.12")
     (status implemented)
     (oracle shared)
     (oracle-eligibility policy-gated)
     (oracle-reason host-policy)
     (options ((session-id repl-main)))
     (description
       "The repl library returns a mutable interaction environment inside an \
authorized session context.")

     (source
       (forms
         (import (scheme base) (scheme eval) (scheme repl))
         (eval (quote (define repl-value 42)) (interaction-environment))
         repl-value))
     (expect
       (value
         42))
)
    ((id standard-library-r5rs-aliases)
     (kind r7rs-conformance)
     (phase eval)
     (category standard-libraries)
     (section "6.12")
     (status implemented)
     (oracle shared)
     (options ())
     (description
       "The r5rs compatibility library imports practical base bindings and \
exactness aliases.")

     (source
       (forms
         (import (scheme r5rs))
         (list (+ 1 2) (exact->inexact 3) (inexact->exact 3.0))))
     (expect
       (value
         (3 3.0 3)))
)
    ((id reader-comments-read-all)
     (kind agent-specific)
     (phase read-all)
     (category reader-syntax)
     (section "2.2")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason agent-specific)
     (options ())
     (description "The shared reader corpus can compare multiple read datums.")

     (source
       (text "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))
     (expect
       (values
         1
         2))
)
    ((id reader-list-limit-error)
     (kind agent-specific)
     (phase read)
     (category reader-syntax)
     (section "3.3")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason resource-limit)
     (options ((max-list-length 2)))
     (description

        "The shared reader corpus can pass options and compare expected errors\
.")

     (source
       (text "(1 2 3)"))
     (expect
       (condition
         (category read-error)))
)
    ((id eval-multiple-values-result)
     (kind agent-specific)
     (phase eval-result)
     (category multiple-values)
     (section "6.10")
     (status implemented)
     (oracle shared)
     (oracle-eligibility not-oracle-eligible)
     (oracle-reason agent-result-record)
     (options ())
     (description "The shared evaluator corpus can compare result datums.")

     (source
       (form
         (values 1 2)))
     (expect
       (result
         (evaluation-result (status values) (values (1 2)) (events ())
                            (budget (steps-used 5) (host-calls 1)))))
)
  ))
