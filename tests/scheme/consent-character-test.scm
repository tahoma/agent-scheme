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

;; Report whether this suite runs inside a compiled host subprocess.
(define compiled-host-run?
  (if (get-environment-variable "TESTING_RUNNER_HOST_RUN") #t #f))

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

(define (unicode-property-flags code)
  "Return alphabetic, uppercase, and lowercase query results for CODE."
  (list (consent-unicode-alphabetic? code)
        (consent-unicode-uppercase? code)
        (consent-unicode-lowercase? code)))

(define (unicode-simple-mappings code)
  "Return simple uppercase, lowercase, and fold query results for CODE."
  (list (consent-unicode-simple-uppercase code)
        (consent-unicode-simple-lowercase code)
        (consent-unicode-simple-foldcase code)))

(testing-registry-case
 'generated-unicode-data-contract '(portable runtime character unicode data)
(let ((version-field
       (assq 'unicode-version (consent-unicode-data-metadata))))
  (test-equal 'unicode-data-version
              '(17 0 0)
              (consent-unicode-data-version))
  (test-equal 'unicode-data-version-metadata
              '(unicode-version "17.0.0")
              version-field)
  (test-assert 'unicode-property-queries
               (and (consent-unicode-alphabetic? #x3bb)
                    (consent-unicode-uppercase? #x391)
                    (consent-unicode-lowercase? #x3b1)
                    (consent-unicode-whitespace? #x3000)
                    (not (consent-unicode-alphabetic? #x1f642))))
  (test-equal
   'unicode-property-range-edges
   '((#f #f #f) (#t #t #f) (#t #f #t) (#f #f #f))
   (map unicode-property-flags '(#x375 #x376 #x377 #x378)))
  (test-equal
   'unicode-property-bmp-page-boundary
   '((#t #f #t) (#t #t #f) (#t #f #t))
   (map unicode-property-flags '(#xff #x100 #x101)))
  (test-equal
   'unicode-property-supplementary-boundaries
   '((#f #f #f) (#t #t #f) (#t #t #f) (#t #f #t)
     (#t #f #t) (#f #f #f) (#f #f #f) (#t #t #f)
     (#t #f #t) (#f #f #f))
   (map unicode-property-flags
        '(#x103ff #x10400 #x10427 #x10428 #x1044f #x1049e
          #x1d3ff #x1d400 #x1d41a #x10ffff)))
  (test-equal
   'unicode-decimal-block-boundaries
   '(#f 0 9 #f #f 0 9 0 9 9 #f #f 0 9 #f #f 0 9 #f #f)
   (map consent-unicode-decimal-value
        '(#x1049f #x104a0 #x104a9 #x104aa
          #x1d7cd #x1d7ce #x1d7d7 #x1d7d8 #x1d7e1 #x1d7ff #x1d800
          #x1e94f #x1e950 #x1e959 #x1e95a
          #x1fbef #x1fbf0 #x1fbf9 #x1fbfa #x10ffff)))
  (test-equal 'unicode-simple-mapping-queries
              '(#x3b1 #x10400 #x10428)
              (list (consent-unicode-simple-lowercase #x391)
                    (consent-unicode-simple-uppercase #x10428)
                    (consent-unicode-simple-foldcase #x10400)))
  (test-equal
   'unicode-simple-mapping-bmp-page-boundary
   '((#x178 #xff #xff) (#x100 #x101 #x101) (#x100 #x101 #x101))
   (map unicode-simple-mappings '(#xff #x100 #x101)))
  (test-equal
   'unicode-simple-mapping-supplementary-boundaries
   '((#x103ff #x103ff #x103ff)
     (#x10400 #x10428 #x10428)
     (#x10427 #x1044f #x1044f)
     (#x10400 #x10428 #x10428)
     (#x10427 #x1044f #x1044f)
     (#x10450 #x10450 #x10450)
     (#x1d400 #x1d400 #x1d400)
     (#x378 #x378 #x378)
     (#x10ffff #x10ffff #x10ffff))
   (map unicode-simple-mappings
        '(#x103ff #x10400 #x10427 #x10428 #x1044f #x10450
          #x1d400 #x378 #x10ffff)))
  (test-equal 'unicode-full-mapping-queries
              '((#x53 #x53) (#x69 #x307) (#x73 #x73) (#xc0))
              (list (consent-unicode-full-uppercase #xdf)
                    (consent-unicode-full-lowercase #x130)
                    (consent-unicode-full-foldcase #x1e9e)
                    (consent-unicode-full-uppercase #xe0)))
  (test-equal
   'unicode-full-mapping-override-neighborhoods
   '(((#xde) (#x53 #x53) (#xc0))
     ((#x12f) (#x69 #x307) (#x131))
     ((#x1e9d) (#x73 #x73) (#x1e9f)))
   (list
    (map consent-unicode-full-uppercase '(#xde #xdf #xe0))
    (map consent-unicode-full-lowercase '(#x12f #x130 #x131))
    (map consent-unicode-full-foldcase '(#x1e9d #x1e9e #x1e9f))))
  (test-equal
   'unicode-full-mapping-identity-fallbacks
   '(((#x378) (#x10ffff))
     ((#x378) (#x10ffff))
     ((#x378) (#x10ffff)))
   (list
    (map consent-unicode-full-uppercase '(#x378 #x10ffff))
    (map consent-unicode-full-lowercase '(#x378 #x10ffff))
    (map consent-unicode-full-foldcase '(#x378 #x10ffff))))
  (let ((mapping (consent-unicode-full-uppercase #xdf)))
    (set-car! mapping 0)
    (test-equal 'unicode-full-mapping-query-is-fresh
                '(#x53 #x53)
                (consent-unicode-full-uppercase #xdf)))
  (let ((version (consent-unicode-data-version))
        (metadata (consent-unicode-data-metadata)))
    (set-car! version 0)
    (string-set! (cadr (assq 'unicode-version metadata)) 0 #\x)
    (test-equal 'unicode-version-query-is-fresh
                '(17 0 0)
                (consent-unicode-data-version))
    (test-equal 'unicode-metadata-strings-are-fresh
                '(unicode-version "17.0.0")
                (assq 'unicode-version
                      (consent-unicode-data-metadata))))))

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

;; These explicit owner/adapter calls exercise the borrowed-host ABI directly.
;; Compiled Scheme-visible character crossings stay covered by the cases above
;; and shared fixtures; nested native owner ABI remains tracked by #120.
(testing-registry-case
 'owned-character-native-boundary-roundtrip
 '(portable runtime character boundary unicode)
(if compiled-host-run?
    (test-assert
     'owned-character-native-boundary-roundtrip-not-applicable
     #t)
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
                       (vector->list (cadr roundtrip)))))))

(testing-runner-main "Consent owned characters" (command-line))
