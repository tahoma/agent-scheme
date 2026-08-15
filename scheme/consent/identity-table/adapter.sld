;;; Host identity adapter for fixed-policy identity tables.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Consent's evaluator overlays this library with its primitive manifest.
;;; Direct R7RS hosts select the smallest available native identity adapter.

(define-library (consent identity-table adapter)
  (export consent-host-identity-fast-backend?
          consent-host-identity-hash
          consent-host-identity=?)
  (import (scheme base))
  (cond-expand
   (gambit
    (import (only (gambit) eq?-hash))
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #t when the host supplies an identity hash operation."
        #t)

      (define (consent-host-identity-raw-hash value)
        "Return Gambit's raw identity hash for VALUE."
        (eq?-hash value))))
   (gauche
    ;; Gauche's SRFI 69 `hash-by-identity' is deprecated and is not compatible
    ;; with its native eq-hash. Keep this irreducible adapter choice explicit.
    (import (only (gauche base) eq-hash))
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #t when the host supplies an identity hash operation."
        #t)

      (define (consent-host-identity-raw-hash value)
        "Return Gauche's raw identity hash for VALUE."
        (eq-hash value))))
   ((library (srfi 69))
    (import (only (srfi 69) hash-by-identity))
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #t when the host supplies an identity hash operation."
        #t)

      (define (consent-host-identity-raw-hash value)
        "Return SRFI 69's raw identity hash for VALUE."
        (hash-by-identity value))))
   (else
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #f when host identity hashing is unavailable."
        #f)

      (define (consent-host-identity-raw-hash value)
        "Reject host hashing when the compatibility backend is active."
        (error "host identity hashing requires a fast backend" value)))))

  (begin
    ;; Stable allocation serials are valid raw hashes but distribute poorly
    ;; across separated bursts in one long-lived table. Keep this normalization
    ;; in the existing hash adapter so evaluator hosts perform it before
    ;; converting the result into an owned number.
    (define host-identity-hash-modulus 16777213)

    ;; A prime multiplier disperses consecutive serials within the modulus.
    (define host-identity-hash-multiplier 104729)

    (define (consent-host-identity-hash value)
      "Return a stable, distributed host identity hash for VALUE."
      #((parameters
         (value (type any) (description "Value whose identity is hashed.")))
        (returns (type exact-nonnegative-integer)
         (description "Stable distributed host identity hash."))
        (effects pure error))
      (modulo
       (* (modulo
           (consent-host-identity-raw-hash value)
           host-identity-hash-modulus)
          host-identity-hash-multiplier)
       host-identity-hash-modulus))

    (define (consent-host-identity=? left right)
      "Return whether LEFT and RIGHT have the same host identity."
      #((parameters
         (left (type any) (description "First value to compare."))
         (right (type any) (description "Second value to compare.")))
        (returns (type boolean)
         (description "Whether LEFT and RIGHT have identical host identity."))
        (effects pure))
      (eq? left right))))
