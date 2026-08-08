;;; Portable owned-character and Unicode-profile tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This suite checks the owned-record contracts, generated Unicode table
;;; invariants, and adapters at their direct R7RS host boundaries. The shared
;;; fixture corpus exercises `(scheme char)' behavior through Consent.

(import (scheme base)
        (scheme process-context)
        (consent character)
        (consent unicode-data)
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

(define (range-table-sorted? table)
  "Return #t when flat inclusive ranges in TABLE are sorted and disjoint."
  (and (even? (vector-length table))
       (let loop ((index 0) (previous-upper #f))
         (if (= index (vector-length table))
             #t
             (let ((lower (vector-ref table index))
                   (upper (vector-ref table (+ index 1))))
               (and (<= lower upper)
                    (or (not previous-upper)
                        (< (+ previous-upper 1) lower))
                    (loop (+ index 2) upper)))))))

(define (flat-mapping-sorted? table)
  "Return #t when flat source/value TABLE has strictly increasing sources."
  (and (even? (vector-length table))
       (let loop ((index 0) (previous-source #f))
         (if (= index (vector-length table))
             #t
             (let ((source (vector-ref table index)))
               (and (or (not previous-source)
                        (< previous-source source))
                    (loop (+ index 2) source)))))))

(define (full-mapping-sorted? table)
  "Return #t when TABLE entries have sorted sources and mapped scalars."
  (let loop ((index 0) (previous-source #f))
    (if (= index (vector-length table))
        #t
        (let* ((entry (vector-ref table index))
               (source (vector-ref entry 0)))
          (and (> (vector-length entry) 1)
               (or (not previous-source) (< previous-source source))
               (all? consent-scalar-value? (cdr (vector->list entry)))
               (loop (+ index 1) source))))))

(testing-registry-case
 'generated-unicode-data-contract '(portable runtime character unicode data)
(let ((version-field (assq 'unicode-version consent-unicode-data-metadata)))
  (test-equal 'unicode-data-version '(17 0 0) consent-unicode-data-version)
  (test-equal 'unicode-data-version-metadata
              '(unicode-version "17.0.0")
              version-field)
  (test-assert 'unicode-property-range-shape
               (and (> (vector-length consent-unicode-alphabetic-ranges) 1000)
                    (range-table-sorted?
                     consent-unicode-alphabetic-ranges)
                    (range-table-sorted? consent-unicode-uppercase-ranges)
                    (range-table-sorted? consent-unicode-lowercase-ranges)
                    (range-table-sorted? consent-unicode-whitespace-ranges)))
  (test-assert 'unicode-flat-mapping-shape
               (and (flat-mapping-sorted? consent-unicode-decimal-values)
                    (flat-mapping-sorted?
                     consent-unicode-simple-uppercase-mappings)
                    (flat-mapping-sorted?
                     consent-unicode-simple-lowercase-mappings)
                    (flat-mapping-sorted?
                     consent-unicode-simple-foldcase-mappings)))
  (test-assert 'unicode-full-mapping-shape
               (and (full-mapping-sorted?
                     consent-unicode-full-uppercase-mappings)
                    (full-mapping-sorted?
                     consent-unicode-full-lowercase-mappings)
                    (full-mapping-sorted?
                     consent-unicode-full-foldcase-mappings)))))

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
