;;; Lean fixed-policy host identity maps.
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
          (only (consent identity-policy)
                consent-identity-compatibility-limit
                consent-identity-map-maximum-capacity)
          (only (consent identity-table adapter)
                consent-host-identity-fast-backend?
                consent-host-identity-hash
                consent-host-identity=?))
  (begin
    ;; Four buckets keep small maps compact. Chaining grows when associations
    ;; would outnumber buckets, so every growth relinks at most N live nodes.
    (define identity-map-initial-capacity 4)

    ;; A map is #(marker buckets compatibility size domain fast? active?).
    (define identity-map-marker (vector 'consent-identity-map))

    ;; One chained association is #(next hash key value).
    (define (make-identity-map-entry next hash key value)
      "Return one private host identity-map entry."
      (vector next hash key value))

    (define (check-identity-map operation map active?)
      "Validate MAP for OPERATION, requiring ACTIVE? when true."
      (if (not (and (vector? map)
                    (= (vector-length map) 7)
                    (eq? (vector-ref map 0) identity-map-marker)))
          (error operation "expected identity map" map))
      (if (and active? (not (vector-ref map 6)))
          (error operation "identity map is released" map))
      map)

    (define (identity-map-buckets map)
      "Return MAP's hash buckets."
      (vector-ref map 1))

    (define (identity-map-size map)
      "Return MAP's live association count."
      (vector-ref map 3))

    (define (set-identity-map-size! map size)
      "Set MAP's live association count to SIZE."
      (vector-set! map 3 size))

    (define (identity-map-fast? map)
      "Return whether MAP uses host identity hashing."
      (vector-ref map 5))

    (define (identity-map-key=? left right)
      "Return whether LEFT and RIGHT have the same outer-host identity."
      ;; Consent gives these atomic categories language-level `eq?' semantics
      ;; that may differ from outer-host identity. Compound graph keys retain
      ;; raw identity under portable `eq?' and avoid an adapter callback.
      (if (or (number? left)
              (char? left)
              (symbol? left))
          (consent-host-identity=? left right)
          (eq? left right)))

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
      (let ((domain
             (if (null? maybe-domain) 'identity-map (car maybe-domain))))
        (if (not (symbol? domain))
            (error "consent-make-identity-map: expected symbolic domain"
                   domain))
        (vector identity-map-marker
                (vector)
                '()
                0
                domain
                (consent-host-identity-fast-backend?)
                #t)))

    (define (identity-map-find-entry map key hash)
      "Return MAP's hash-chain entry for KEY and HASH, or #f."
      (let* ((buckets (identity-map-buckets map))
             (capacity (vector-length buckets)))
        (if (= capacity 0)
            #f
            (let loop ((entry (vector-ref buckets (modulo hash capacity))))
              (cond
               ((not entry) #f)
               ((and (= hash (vector-ref entry 1))
                     (identity-map-key=? key (vector-ref entry 2)))
                entry)
               (else (loop (vector-ref entry 0))))))))

    (define (identity-map-rehash! map capacity)
      "Relink MAP's entries into CAPACITY fresh buckets."
      (let ((old (identity-map-buckets map))
            (fresh (make-vector capacity #f)))
        (let bucket-loop ((index 0))
          (if (< index (vector-length old))
              (let entry-loop ((entry (vector-ref old index)))
                (if entry
                    (let* ((next (vector-ref entry 0))
                           (target
                            (modulo (vector-ref entry 1) capacity)))
                      (vector-set! entry 0 (vector-ref fresh target))
                      (vector-set! fresh target entry)
                      (entry-loop next))
                    (bucket-loop (+ index 1))))))
        (vector-set! map 1 fresh)))

    (define (identity-map-ensure-insertion-capacity! map)
      "Ensure MAP can retain one additional hash association."
      (let* ((buckets (identity-map-buckets map))
             (capacity (vector-length buckets))
             (size (identity-map-size map)))
        (if (>= size consent-identity-map-maximum-capacity)
            (error "consent-identity-map-set!: storage limit reached"
                   (vector-ref map 4)
                   size
                   capacity
                   consent-identity-map-maximum-capacity))
        (cond
         ((= capacity 0)
          (identity-map-rehash! map identity-map-initial-capacity))
         ((>= size capacity)
          (identity-map-rehash!
           map
           (min consent-identity-map-maximum-capacity
                (+ (* capacity 2) 1)))))))

    (define (identity-map-compatibility-find map key)
      "Return MAP's compatibility-list tail for KEY, or #f."
      (let loop ((rest (vector-ref map 2)))
        (cond
         ((null? rest) #f)
         ((identity-map-key=? key (car (car rest))) rest)
         (else (loop (cdr rest))))))

    (define (identity-map-hash-ref map key default)
      "Return hash-backed KEY from MAP, or DEFAULT."
      (let* ((hash (consent-host-identity-hash key))
             (entry (identity-map-find-entry map key hash)))
        (if entry (vector-ref entry 3) default)))

    (define (identity-map-compatibility-ref map key default)
      "Return compatibility KEY from MAP, or DEFAULT."
      (let ((found (identity-map-compatibility-find map key)))
        (if found (cdr (car found)) default)))

    (define (consent-identity-map-ref map key default)
      "Return KEY's value in MAP, or DEFAULT when KEY is absent."
      #((parameters
         (map (type identity-map) (description "Map to inspect."))
         (key (type any) (description "Host identity key."))
         (default (type any) (description "Absent-key result.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects state-read error))
      (check-identity-map "consent-identity-map-ref:" map #t)
      (if (identity-map-fast? map)
          (identity-map-hash-ref map key default)
          (identity-map-compatibility-ref map key default)))

    (define (identity-map-hash-set! map key value adjoin?)
      "Set hash-backed KEY in MAP unless ADJOIN? finds it present."
      (let* ((hash (consent-host-identity-hash key))
             (entry (identity-map-find-entry map key hash)))
        (if entry
            (begin
              (if (not adjoin?) (vector-set! entry 3 value))
              (if adjoin? #f value))
            (begin
              (identity-map-ensure-insertion-capacity! map)
              (let* ((buckets (identity-map-buckets map))
                     (index (modulo hash (vector-length buckets))))
                (vector-set!
                 buckets
                 index
                 (make-identity-map-entry
                  (vector-ref buckets index) hash key value))
                (set-identity-map-size! map (+ (identity-map-size map) 1))
                (if adjoin? #t value))))))

    (define (identity-map-compatibility-set! map key value adjoin?)
      "Set compatibility KEY in MAP unless ADJOIN? finds it present."
      (let ((found (identity-map-compatibility-find map key)))
        (if found
            (begin
              (if (not adjoin?) (set-cdr! (car found) value))
              (if adjoin? #f value))
            (begin
              (if (>= (identity-map-size map)
                      consent-identity-compatibility-limit)
                  (error
                   "consent-identity-map-set!: compatibility limit "
                   "requires fast backend"
                   consent-identity-compatibility-limit))
              (vector-set! map 2
                           (cons (cons key value) (vector-ref map 2)))
              (set-identity-map-size! map (+ (identity-map-size map) 1))
              (if adjoin? #t value)))))

    (define (identity-map-set! map key value adjoin?)
      "Set identity KEY in MAP according to ADJOIN?."
      (if (identity-map-fast? map)
          (identity-map-hash-set! map key value adjoin?)
          (identity-map-compatibility-set! map key value adjoin?)))

    (define (consent-identity-map-adjoin! map key value)
      "Associate identity KEY only when absent and report insertion."
      #((parameters
         (map (type identity-map) (description "Map to update."))
         (key (type any) (description "Host identity key."))
         (value (type any) (description "Value retained for a new key.")))
        (returns (type boolean)
         (description "Whether a new association was inserted."))
        (effects allocation state-write error))
      (check-identity-map "consent-identity-map-adjoin!:" map #t)
      (identity-map-set! map key value #t))

    (define (consent-identity-map-set! map key value)
      "Associate identity KEY with VALUE in MAP and return VALUE."
      #((parameters
         (map (type identity-map) (description "Map to update."))
         (key (type any) (description "Host identity key."))
         (value (type any) (description "Value to retain.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects allocation state-write error))
      (check-identity-map "consent-identity-map-set!:" map #t)
      (identity-map-set! map key value #f))

    (define (identity-map-hash-delete! map key)
      "Delete hash-backed KEY from MAP and report whether it was present."
      (let* ((hash (consent-host-identity-hash key))
             (buckets (identity-map-buckets map))
             (capacity (vector-length buckets)))
        (if (= capacity 0)
            #f
            (let ((index (modulo hash capacity)))
              (let loop ((entry (vector-ref buckets index)) (previous #f))
                (cond
                 ((not entry) #f)
                 ((and (= hash (vector-ref entry 1))
                       (identity-map-key=? key (vector-ref entry 2)))
                  (if previous
                      (vector-set! previous 0 (vector-ref entry 0))
                      (vector-set! buckets index (vector-ref entry 0)))
                  (vector-set! entry 0 #f)
                  (vector-set! entry 2 #f)
                  (vector-set! entry 3 #f)
                  (set-identity-map-size! map (- (identity-map-size map) 1))
                  #t)
                 (else (loop (vector-ref entry 0) entry))))))))

    (define (identity-map-compatibility-delete! map key)
      "Delete compatibility KEY from MAP and report whether it was present."
      (let loop ((rest (vector-ref map 2)) (previous #f))
        (cond
         ((null? rest) #f)
         ((identity-map-key=? key (car (car rest)))
          (if previous
              (set-cdr! previous (cdr rest))
              (vector-set! map 2 (cdr rest)))
          (set-identity-map-size! map (- (identity-map-size map) 1))
          #t)
         (else (loop (cdr rest) rest)))))

    (define (consent-identity-map-delete! map key)
      "Delete identity KEY from MAP and report whether it was present."
      #((parameters
         (map (type identity-map) (description "Map to update."))
         (key (type any) (description "Host identity key.")))
        (returns (type boolean)
         (description "Whether an association was deleted."))
        (effects state-write error))
      (check-identity-map "consent-identity-map-delete!:" map #t)
      (if (identity-map-fast? map)
          (identity-map-hash-delete! map key)
          (identity-map-compatibility-delete! map key)))

    (define (identity-map-clear-storage! map retain-capacity?)
      "Clear MAP, retaining buckets only when RETAIN-CAPACITY? is true."
      (let ((buckets (identity-map-buckets map)))
        (if retain-capacity?
            (let loop ((index 0))
              (if (< index (vector-length buckets))
                  (begin
                    (vector-set! buckets index #f)
                    (loop (+ index 1)))))
            (vector-set! map 1 (vector))))
      (vector-set! map 2 '())
      (set-identity-map-size! map 0)
      map)

    (define (consent-identity-map-clear! map)
      "Clear MAP while retaining its bucket capacity."
      #((parameters
         (map (type identity-map) (description "Map to clear.")))
        (returns (type identity-map)
         (description "The empty active MAP."))
        (effects state-write error))
      (check-identity-map "consent-identity-map-clear!:" map #t)
      (identity-map-clear-storage! map #t))

    (define (consent-identity-map-release! map)
      "Clear MAP and end its lifetime."
      #((parameters
         (map (type identity-map) (description "Map to release.")))
        (returns (type identity-map)
         (description "The inactive released MAP."))
        (effects state-write error))
      (check-identity-map "consent-identity-map-release!:" map #f)
      (if (vector-ref map 6)
          (begin
            (identity-map-clear-storage! map #f)
            (vector-set! map 6 #f)))
      map)

    (define (consent-identity-map-stats map)
      "Return MAP's deterministic fixed-policy structural statistics."
      #((parameters
         (map (type identity-map) (description "Map to inspect.")))
        (returns (type list)
         (description "Stable structural map statistics."))
        (effects allocation state-read error))
      (check-identity-map "consent-identity-map-stats:" map #f)
      (list
       'identity-map
       (list 'domain (vector-ref map 4))
       (list 'key-policy 'host)
       (list 'host-backend
             (if (identity-map-fast? map) 'fast-hash 'compatibility))
       (list 'active? (vector-ref map 6))
       (list 'size (identity-map-size map))
       (list 'capacity (vector-length (identity-map-buckets map)))
       (list 'initial-capacity identity-map-initial-capacity)
       (list 'maximum-capacity consent-identity-map-maximum-capacity)
       (list 'growth-policy 'allow-growth)
       (list 'compatibility-count
             (if (identity-map-fast? map) 0 (identity-map-size map)))
       (list 'compatibility-limit
             consent-identity-compatibility-limit)))))
