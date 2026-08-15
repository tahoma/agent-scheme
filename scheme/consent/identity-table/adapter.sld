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

      (define (consent-host-identity-hash value)
        "Return the host identity hash for VALUE."
        (eq?-hash value))

      (define (consent-host-identity=? left right)
        "Return whether LEFT and RIGHT have the same host identity."
        (eq? left right))))
   (gauche
    ;; Gauche's SRFI 69 `hash-by-identity' is deprecated and is not compatible
    ;; with its native eq-hash. Keep this irreducible adapter choice explicit.
    (import (only (gauche base) eq-hash))
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #t when the host supplies an identity hash operation."
        #t)

      (define (consent-host-identity-hash value)
        "Return the host identity hash for VALUE."
        (eq-hash value))

      (define (consent-host-identity=? left right)
        "Return whether LEFT and RIGHT have the same host identity."
        (eq? left right))))
   ((library (srfi 69))
    (import (only (srfi 69) hash-by-identity))
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #t when the host supplies an identity hash operation."
        #t)

      (define (consent-host-identity-hash value)
        "Return the host identity hash for VALUE."
        (hash-by-identity value))

      (define (consent-host-identity=? left right)
        "Return whether LEFT and RIGHT have the same host identity."
        (eq? left right))))
   (else
    (begin
      (define (consent-host-identity-fast-backend?)
        "Return #f when host identity hashing is unavailable."
        #f)

      (define (consent-host-identity-hash value)
        "Reject host hashing when the compatibility backend is active."
        (error "host identity hashing requires a fast backend" value))

      (define (consent-host-identity=? left right)
        "Return whether LEFT and RIGHT have the same host identity."
        (eq? left right))))))
