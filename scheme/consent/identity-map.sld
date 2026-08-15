;;; Compatibility facade over fixed-policy host identity tables.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (consent identity-map)
  (export consent-identity-map-fast-backend?
          consent-make-identity-map
          consent-identity-map-adjoin!
          consent-identity-map-ref
          consent-identity-map-set!
          consent-identity-map-delete!
          consent-identity-map-clear!
          consent-identity-map-release!
          consent-identity-map-stats)
  (import (scheme base)
          (only (consent identity-table)
                consent-host-identity-fast-backend?
                consent-identity-table-clear!
                consent-identity-table-host-adjoin!
                consent-identity-table-host-delete!
                consent-identity-table-host-ref
                consent-identity-table-host-set!
                consent-identity-table-release!
                consent-identity-table-stats
                consent-make-identity-table))
  (begin
    ;; This ceiling is explicit even on hash-backed hosts. The no-hash path has
    ;; the identity table's smaller fixed compatibility envelope.
    ;; Separate chaining admits one association per bucket at the growth
    ;; threshold, covering the runtime's ten-million-node default envelope.
    (define identity-map-maximum-capacity 16777215)

    (define (consent-identity-map-fast-backend?)
      "Return whether new identity maps use host identity hashing."
      #((parameters)
        (returns (type boolean)
         (description "Whether new maps use hashed host identity."))
        (effects pure))
      (consent-host-identity-fast-backend?))

    (define (consent-make-identity-map . maybe-domain)
      "Return a mutable fixed-policy host identity map."
      #((parameters
         (maybe-domain (type list)
          (description "Zero or one symbolic ownership-domain label.")))
        (returns (type identity-map)
         (description "Fresh active host identity map."))
        (effects allocation error))
      (if (> (length maybe-domain) 1)
          (error "consent-make-identity-map: too many domains"
                 maybe-domain))
      (consent-make-identity-table
       4
       identity-map-maximum-capacity
       'allow-growth
       'host
       (if (null? maybe-domain) 'identity-map (car maybe-domain))))

    (define (consent-identity-map-ref map key default)
      "Return KEY's value in MAP, or DEFAULT when KEY is absent."
      #((parameters
         (map (type identity-map) (description "Map to inspect."))
         (key (type any) (description "Host identity key."))
         (default (type any) (description "Absent-key result.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects state-read error))
      (consent-identity-table-host-ref map key default))

    (define (consent-identity-map-adjoin! map key value)
      "Associate identity KEY only when absent and report insertion."
      #((parameters
         (map (type identity-map) (description "Map to update."))
         (key (type any) (description "Host identity key."))
         (value (type any) (description "Value retained for a new key.")))
        (returns (type boolean)
         (description "Whether a new association was inserted."))
        (effects allocation state-write error))
      (consent-identity-table-host-adjoin! map key value))

    (define (consent-identity-map-set! map key value)
      "Associate identity KEY with VALUE in MAP and return VALUE."
      #((parameters
         (map (type identity-map) (description "Map to update."))
         (key (type any) (description "Host identity key."))
         (value (type any) (description "Value to retain.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects allocation state-write error))
      (consent-identity-table-host-set! map key value))

    (define (consent-identity-map-delete! map key)
      "Delete identity KEY from MAP and report whether it was present."
      #((parameters
         (map (type identity-map) (description "Map to update."))
         (key (type any) (description "Host identity key.")))
        (returns (type boolean)
         (description "Whether an association was deleted."))
        (effects state-write error))
      (consent-identity-table-host-delete! map key))

    (define (consent-identity-map-clear! map)
      "Clear MAP while retaining its bucket capacity."
      #((parameters
         (map (type identity-map) (description "Map to clear.")))
        (returns (type identity-map)
         (description "The empty active MAP."))
        (effects state-write error))
      (consent-identity-table-clear! map))

    (define (consent-identity-map-release! map)
      "Clear MAP and end its lifetime."
      #((parameters
         (map (type identity-map) (description "Map to release.")))
        (returns (type identity-map)
         (description "The inactive released MAP."))
        (effects state-write error))
      (consent-identity-table-release! map))

    (define (consent-identity-map-stats map)
      "Return MAP's deterministic fixed-policy statistics."
      #((parameters
         (map (type identity-map) (description "Map to inspect.")))
        (returns (type list)
         (description "Stable map statistics."))
        (effects allocation state-read error))
      (consent-identity-table-stats map))))
