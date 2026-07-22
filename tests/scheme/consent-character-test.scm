;;; Portable owned-character and Unicode-profile tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This suite checks the owned-record contracts and adapters at their direct
;;; R7RS host boundaries.  The shared fixture corpus exhausts `(scheme char)'.

(import (scheme base)
        (scheme process-context)
        (consent character)
        (only (consent runtime)
              consent-host-datum->consent-datum)
        (only (consent library)
              consent-native-argument-value
              consent-runtime-datum->native-datum)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when THUNK raises a Scheme condition."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (all? predicate values)
  "Return #t when PREDICATE accepts every element of VALUES."
  (or (null? values)
      (and (predicate (car values))
           (all? predicate (cdr values)))))

(testing-registry-case
 'unicode-scalar-boundaries '(portable runtime character unicode)
(let ((valid '(0 #x7f #xd7ff #xe000 #x10ffff))
      (invalid '(-1 #xd800 #xdfff #x110000 1/2 1.0 scalar #f)))
  (test-assert 'scalar-boundary-valid
               (all? consent-scalar-value? valid))
  (test-assert 'scalar-boundary-invalid
               (all? (lambda (value)
                       (not (consent-scalar-value? value)))
                     invalid))
  (test-equal 'constructed-boundary-codes
              valid
              (map (lambda (code)
                     (consent-character-code
                      (consent-make-character code)))
                   valid))
  (test-assert 'invalid-boundary-construction
               (all? (lambda (value)
                       (raises? (lambda ()
                                  (consent-make-character value))))
                     invalid))))

(testing-registry-case
 'owned-character-identity-and-contracts '(portable runtime character)
(let ((left (consent-make-character #x3bb))
      (same (consent-make-character #x3bb))
      (different (consent-make-character #x3bc)))
  (test-assert 'owned-character-predicate (consent-character? left))
  (test-assert 'owned-character-equivalence
               (consent-character-equivalent? left same))
  (test-assert 'owned-character-inequivalence
               (not (consent-character-equivalent? left different)))
  (test-assert 'owned-character-equivalence-rejects-host-values
               (and (not (consent-character-equivalent? left "x"))
                    (not (consent-character-equivalent? "x" left))))
  (test-assert 'owned-character-code-contract
               (raises? (lambda () (consent-character-code "x"))))
  (test-assert 'host-character-ingress-contract
               (raises? (lambda ()
                          (consent-host-character->character #x3bb))))
  (test-assert 'host-character-egress-contract
               (raises? (lambda ()
                          (consent-character->host-character "x"))))))

(testing-registry-case
 'owned-character-host-adapters '(portable runtime character boundary unicode)
(let ((codes '(0 #x7f #x3bb #x20ac #x1f642 #x10ffff)))
  (test-equal
   'host-character-adapter-roundtrip
   codes
   (map (lambda (code)
          (char->integer
           (consent-character->host-character
            (consent-host-character->character (integer->char code)))))
        codes))))

(testing-registry-case
 'owned-character-native-boundary-roundtrip
 '(portable runtime character boundary unicode)
(let* ((codes '(0 #x7f #x3bb #x20ac #x1f642 #x10ffff))
       (owned (map consent-make-character codes))
       (runtime-datum (list owned (list->vector owned)))
       (native-argument
        (consent-native-argument-value runtime-datum #f))
       (native-result
        (consent-runtime-datum->native-datum runtime-datum))
       (roundtrip
        (consent-host-datum->consent-datum native-result)))
  (test-equal 'native-argument-character-codes
              codes
              (map char->integer (car native-argument)))
  (test-equal 'native-argument-vector-character-codes
              codes
              (map char->integer
                   (vector->list (cadr native-argument))))
  (test-equal 'native-result-character-codes
              codes
              (map char->integer (car native-result)))
  (test-equal 'native-roundtrip-character-codes
              codes
              (map consent-character-code (car roundtrip)))
  (test-equal 'native-roundtrip-vector-character-codes
              codes
              (map consent-character-code
                   (vector->list (cadr roundtrip))))))

(testing-runner-main "Consent owned characters" (command-line))
