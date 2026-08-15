;;; Bootstrap-safe fixed-policy identity tables.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Storage, lifecycle, accounting, and owned-object hashing are portable.
;;; Only host identity hashing and comparison are adapter operations.

(define-library (consent identity-table)
  (export consent-make-identity-table
          consent-identity-table?
          consent-identity-table-active?
          consent-identity-table-fast-host-backend?
          consent-identity-table-domain
          consent-identity-table-key-policy
          consent-identity-table-size
          consent-identity-table-capacity
          consent-identity-table-maximum-capacity
          consent-identity-table-reserve!
          consent-identity-table-host-contains?
          consent-identity-table-host-adjoin!
          consent-identity-table-host-ref
          consent-identity-table-host-set!
          consent-identity-table-host-delete!
          consent-identity-table-owned-contains?
          consent-identity-table-owned-ref
          consent-identity-table-owned-set!
          consent-identity-table-owned-delete!
          consent-identity-table-clear!
          consent-identity-table-release!
          consent-identity-table-entries
          consent-identity-table-stats
          consent-host-identity-fast-backend?
          consent-host-identity-hash
          consent-host-identity=?)
  (import (scheme base)
          (consent identity-table adapter)
          (only (consent identity-policy)
                consent-identity-compatibility-limit))
  (begin
    ;; Compatibility scans are constant-bounded independently of table limits.
    (define identity-table-compatibility-limit
      consent-identity-compatibility-limit)

    ;; Empty slots contain #f. Deleted slots contain this private singleton.
    (define identity-table-tombstone
      (vector 'consent-identity-table-tombstone))

    ;; Counter vector indexes keep the storage record compact.
    (define counter-lookups 0)
    ;; Index of explicit membership-query operations.
    (define counter-contains 1)
    ;; Index of requested association mutations.
    (define counter-sets 2)
    ;; Index of newly inserted associations.
    (define counter-inserts 3)
    ;; Index of updated existing associations.
    (define counter-updates 4)
    ;; Index of requested deletions.
    (define counter-deletes 5)
    ;; Index of successful deletions.
    (define counter-delete-hits 6)
    ;; Index of lookup and deletion misses.
    (define counter-misses 7)
    ;; Index of fixed hash computations.
    (define counter-hashes 8)
    ;; Index of inspected open buckets or host-chain nodes.
    (define counter-probes 9)
    ;; Index of fixed identity comparisons.
    (define counter-identity-tests 10)
    ;; Index of bounded compatibility-list steps.
    (define counter-compatibility-scans 11)
    ;; Index of published bucket-capacity changes.
    (define counter-capacity-changes 12)
    ;; Index of entries copied during rebuilds.
    (define counter-rehashed-entries 13)
    ;; Index of reusable clear operations.
    (define counter-clears 14)
    ;; Index of slots processed by reusable clears.
    (define counter-clear-slots 15)
    ;; Index of terminal release operations.
    (define counter-releases 16)
    ;; Index of slots processed by terminal release.
    (define counter-release-clear-slots 17)
    ;; Index of entry snapshots.
    (define counter-snapshots 18)
    ;; Number of counters allocated for each table.
    (define identity-table-counter-count 19)

    ;; Keep the adapter-provided host hash unchanged for bucket reduction.
    (define-syntax fixed-host-identity-hash
      (syntax-rules ()
        ((_ key)
         (consent-host-identity-hash key))))

    ;; Record one hash-backed host operation with one counter-vector lookup.
    (define-syntax record-open-host-operation!
      (syntax-rules ()
        ((_ counters operation-counter probes identity-tests)
         (begin
           (vector-set!
            counters
            operation-counter
            (+ (vector-ref counters operation-counter) 1))
           (vector-set!
            counters
            counter-hashes
            (+ (vector-ref counters counter-hashes) 1))
           (vector-set!
            counters
            counter-probes
            (+ (vector-ref counters counter-probes) probes))
           (vector-set!
            counters
            counter-identity-tests
            (+ (vector-ref counters counter-identity-tests)
               identity-tests))))))

    ;; One live association with fixed namespace and identity fields.
    (define-record-type <identity-table-entry>
      (make-identity-table-entry
       namespace heap-id object-id key value hash)
      identity-table-entry?
      (namespace identity-table-entry-namespace)
      (heap-id identity-table-entry-heap-id)
      (object-id identity-table-entry-object-id)
      (key identity-table-entry-key set-identity-table-entry-key!)
      (value identity-table-entry-value
             set-identity-table-entry-value!)
      (hash identity-table-entry-hash))

    ;; Host-only tables use one compact linked node per association. Chaining
    ;; avoids interpreting open-address offset arithmetic and general entry
    ;; accessors on the dominant host-key path.
    (define (make-host-chain-entry next hash key value)
      "Return one private host bucket node."
      (vector next hash key value))

    ;; Read one node's next link.
    (define-syntax host-chain-entry-next
      (syntax-rules () ((_ entry) (vector-ref entry 0))))

    ;; Replace one node's next link.
    (define-syntax set-host-chain-entry-next!
      (syntax-rules ()
        ((_ entry value) (vector-set! entry 0 value))))

    ;; Read one node's complete host hash.
    (define-syntax host-chain-entry-hash
      (syntax-rules () ((_ entry) (vector-ref entry 1))))

    ;; Read one node's retained host key.
    (define-syntax host-chain-entry-key
      (syntax-rules () ((_ entry) (vector-ref entry 2))))

    ;; Read one node's retained value.
    (define-syntax host-chain-entry-value
      (syntax-rules () ((_ entry) (vector-ref entry 3))))

    ;; Replace one node's retained value.
    (define-syntax set-host-chain-entry-value!
      (syntax-rules ()
        ((_ entry value) (vector-set! entry 3 value))))

    ;; Mutable table state with immutable construction policies.
    (define-record-type <consent-identity-table>
      (make-identity-table-record
       slots capacity initial-capacity maximum-capacity growth-policy
       key-policy domain fast-host? size tombstones compatibility
       compatibility-count counters active?)
      consent-identity-table?
      (slots identity-table-slots set-identity-table-slots!)
      (capacity identity-table-capacity-value
                set-identity-table-capacity!)
      (initial-capacity identity-table-initial-capacity)
      (maximum-capacity identity-table-maximum-capacity-value)
      (growth-policy identity-table-growth-policy)
      (key-policy identity-table-key-policy-value)
      (domain identity-table-domain-value)
      (fast-host? identity-table-fast-host?)
      (size identity-table-size-value set-identity-table-size!)
      (tombstones identity-table-tombstones
                  set-identity-table-tombstones!)
      (compatibility identity-table-compatibility
                     set-identity-table-compatibility!)
      (compatibility-count identity-table-compatibility-count
                           set-identity-table-compatibility-count!)
      (counters identity-table-counters)
      (active? identity-table-active? set-identity-table-active!))

    (define (exact-nonnegative-integer? value)
      "Return whether VALUE is an exact nonnegative integer."
      (and (integer? value) (exact? value) (>= value 0)))

    (define (check-capacity operation value)
      "Validate exact nonnegative capacity VALUE for OPERATION."
      (if (not (exact-nonnegative-integer? value))
          (error
           (string-append operation
                          ": expected exact nonnegative capacity")
           value))
      value)

    (define (check-key-policy operation policy)
      "Validate fixed identity key POLICY for OPERATION."
      (if (not (memq policy '(owned host mixed)))
          (error
           (string-append operation
                          ": expected owned, host, or mixed key policy")
           policy))
      policy)

    (define (check-growth-policy operation policy)
      "Validate table growth POLICY for OPERATION."
      (if (not (memq policy '(allow-growth pre-reserved)))
          (error
           (string-append operation
                          ": expected allow-growth or pre-reserved")
           policy))
      policy)

    (define (check-host-policy operation policy)
      "Validate immutable host-backend POLICY for OPERATION."
      (if (not (memq policy '(automatic compatibility)))
          (error
           (string-append operation
                          ": expected automatic or compatibility")
           policy))
      policy)

    (define (check-owned-id operation description value)
      "Validate owned identity VALUE for OPERATION and DESCRIPTION."
      (if (not (exact-nonnegative-integer? value))
          (error
           (string-append operation
                          ": expected exact nonnegative "
                          description)
           value))
      value)

    (define (check-active-table operation table)
      "Validate active identity TABLE for OPERATION."
      (if (not (consent-identity-table? table))
          (error
           (string-append operation ": expected identity table") table))
      (if (not (identity-table-active? table))
          (error
           (string-append operation ": identity table is released") table))
      table)

    (define (check-namespace operation table namespace)
      "Validate NAMESPACE against TABLE's immutable key policy."
      (let ((policy (identity-table-key-policy-value table)))
        (if (not (or (eq? policy 'mixed) (eq? policy namespace)))
            (error
             (string-append operation ": key namespace is not enabled")
             namespace
             policy))))

    (define (check-active-namespace operation table namespace)
      "Validate active TABLE and its fixed identity NAMESPACE."
      (if (not (consent-identity-table? table))
          (error
           (string-append operation ": expected identity table") table))
      (if (not (identity-table-active? table))
          (error
           (string-append operation ": identity table is released") table))
      (let ((policy (identity-table-key-policy-value table)))
        (if (not (or (eq? policy 'mixed) (eq? policy namespace)))
            (error
             (string-append operation ": key namespace is not enabled")
             namespace
             policy))))

    (define (counter-add! table index amount)
      "Add AMOUNT to TABLE counter INDEX."
      (let ((counters (identity-table-counters table)))
        (vector-set!
         counters index (+ (vector-ref counters index) amount))))

    (define (allocate-slots operation capacity)
      "Allocate CAPACITY empty slots with stable OPERATION failure."
      (guard (condition
              (else
               (error
                (string-append operation ": storage allocation failed")
                capacity)))
        (make-vector capacity #f)))

    (define (consent-make-identity-table
             initial-capacity maximum-capacity growth-policy key-policy
             domain . maybe-host-policy)
      "Return a fixed-policy mutable identity table."
      #((parameters
         (initial-capacity (type exact-nonnegative-integer)
          (description "Initial or first growable bucket count."))
         (maximum-capacity (type exact-nonnegative-integer)
          (description "Inclusive bucket and association ceiling."))
         (growth-policy (type symbol)
          (description "Either allow-growth or pre-reserved."))
         (key-policy (type symbol)
          (description "Enabled owned, host, or mixed key namespaces."))
         (domain (type symbol)
          (description "Private ownership-domain label."))
         (maybe-host-policy (type list)
          (description
           "Optional automatic or forced compatibility host policy.")))
        (returns (type identity-table)
         (description "Fresh active table with no retained keys."))
        (effects allocation error))
      (check-capacity
       "consent-make-identity-table" initial-capacity)
      (check-capacity
       "consent-make-identity-table" maximum-capacity)
      (if (> initial-capacity maximum-capacity)
          (error
           "consent-make-identity-table: initial capacity exceeds maximum"
           initial-capacity
           maximum-capacity))
      (check-growth-policy
       "consent-make-identity-table" growth-policy)
      (check-key-policy "consent-make-identity-table" key-policy)
      (if (not (symbol? domain))
          (error
           "consent-make-identity-table: expected symbolic domain" domain))
      (if (> (length maybe-host-policy) 1)
          (error
           "consent-make-identity-table: too many host policies"
           maybe-host-policy))
      (let* ((host-policy
              (if (null? maybe-host-policy)
                  'automatic
                  (car maybe-host-policy)))
             (checked-host-policy
             (check-host-policy
               "consent-make-identity-table" host-policy))
             (fast-host?
              (and (eq? checked-host-policy 'automatic)
                   (consent-host-identity-fast-backend?)))
             (allocate-initial?
              (and (eq? growth-policy 'pre-reserved)
                   (not
                    (and (eq? key-policy 'host)
                         (not fast-host?)))))
             (allocated-capacity
              (if allocate-initial? initial-capacity 0)))
        (make-identity-table-record
         (allocate-slots
          "consent-make-identity-table" allocated-capacity)
         allocated-capacity
         initial-capacity
         maximum-capacity
         growth-policy
         key-policy
         domain
         fast-host?
         0
         0
         '()
         0
         (make-vector identity-table-counter-count 0)
         #t)))

    (define (consent-identity-table-active? table)
      "Return whether TABLE is an active identity table."
      #((parameters
         (table (type any) (description "Potential identity table.")))
        (returns (type boolean)
         (description "Whether TABLE accepts operations."))
        (effects pure))
      (and (consent-identity-table? table)
           (identity-table-active? table)))

    (define (consent-identity-table-fast-host-backend? table)
      "Return whether TABLE uses hashed host identity."
      #((parameters
         (table (type identity-table)
          (description "Table whose host backend is inspected.")))
        (returns (type boolean)
         (description "Whether host entries use identity hashing."))
        (effects state-read error))
      (check-active-table
       "consent-identity-table-fast-host-backend?" table)
      (identity-table-fast-host? table))

    (define (consent-identity-table-domain table)
      "Return TABLE's immutable ownership domain."
      #((parameters
         (table (type identity-table)
          (description "Table whose domain is inspected.")))
        (returns (type symbol) (description "Ownership-domain label."))
        (effects state-read error))
      (check-active-table "consent-identity-table-domain" table)
      (identity-table-domain-value table))

    (define (consent-identity-table-key-policy table)
      "Return TABLE's owned, host, or mixed key policy."
      #((parameters
         (table (type identity-table)
          (description "Table whose key policy is inspected.")))
        (returns (type symbol) (description "Fixed key policy."))
        (effects state-read error))
      (check-active-table "consent-identity-table-key-policy" table)
      (identity-table-key-policy-value table))

    (define (consent-identity-table-size table)
      "Return TABLE's live association count."
      #((parameters
         (table (type identity-table)
          (description "Table whose size is inspected.")))
        (returns (type exact-nonnegative-integer)
         (description "Live association count."))
        (effects state-read error))
      (check-active-table "consent-identity-table-size" table)
      (identity-table-size-value table))

    (define (consent-identity-table-capacity table)
      "Return TABLE's allocated bucket count."
      #((parameters
         (table (type identity-table)
          (description "Table whose capacity is inspected.")))
        (returns (type exact-nonnegative-integer)
         (description "Allocated bucket count."))
        (effects state-read error))
      (check-active-table "consent-identity-table-capacity" table)
      (identity-table-capacity-value table))

    (define (consent-identity-table-maximum-capacity table)
      "Return TABLE's immutable storage ceiling."
      #((parameters
         (table (type identity-table)
          (description "Table whose limit is inspected.")))
        (returns (type exact-nonnegative-integer)
         (description "Maximum bucket and association count."))
        (effects state-read error))
      (check-active-table
       "consent-identity-table-maximum-capacity" table)
      (identity-table-maximum-capacity-value table))

    (define (open-entry-count table)
      "Return TABLE's live open-addressed entry count."
      (- (identity-table-size-value table)
         (identity-table-compatibility-count table)))

    (define (identity-table-chained-host? table)
      "Return whether TABLE uses host-only bucket chains."
      (and (identity-table-fast-host? table)
           (eq? (identity-table-key-policy-value table) 'host)))

    (define (host-key-identity=? left right)
      "Return whether LEFT and RIGHT have the same outer-host identity."
      ;; Consent deliberately gives numbers, characters, and symbols language
      ;; equivalence semantics for `eq?'. Other host values retain raw identity,
      ;; so their dominant graph-table path needs no comparison adapter call.
      (if (or (number? left)
              (char? left)
              (symbol? left))
          (consent-host-identity=? left right)
          (eq? left right)))

    (define (entry-matches? entry namespace heap-id object-id key)
      "Return whether ENTRY matches the supplied fixed identity."
      (if (eq? namespace 'owned)
          (and (= heap-id (identity-table-entry-heap-id entry))
               (= object-id
                  (identity-table-entry-object-id entry)))
          (host-key-identity=?
           key (identity-table-entry-key entry))))

    (define (finish-open-search table probes identity-tests index entry)
      "Record one completed open-address search and return its result."
      (counter-add! table counter-probes probes)
      (counter-add! table counter-identity-tests identity-tests)
      (values index entry))

    (define (find-open-slot
             table namespace heap-id object-id key hash)
      "Return matching entry or insertion bucket for one fixed identity."
      (let* ((slots (identity-table-slots table))
             (capacity (vector-length slots))
             (start (if (= capacity 0) 0 (modulo hash capacity))))
        (if (= capacity 0)
            (values #f #f)
            (let loop
                ((offset 0)
                 (first-tombstone #f)
                 (probes 0)
                 (identity-tests 0))
              (if (= offset capacity)
                  (finish-open-search
                   table probes identity-tests first-tombstone #f)
                  (let* ((index (modulo (+ start offset) capacity))
                         (entry (vector-ref slots index)))
                    (cond
                     ((not entry)
                      (finish-open-search
                       table
                       (+ probes 1)
                       identity-tests
                       (if first-tombstone first-tombstone index)
                       #f))
                     ((eq? entry identity-table-tombstone)
                      (loop
                       (+ offset 1)
                       (if first-tombstone first-tombstone index)
                       (+ probes 1)
                       identity-tests))
                     ((not
                       (eq? namespace
                            (identity-table-entry-namespace entry)))
                      (loop
                       (+ offset 1)
                       first-tombstone
                       (+ probes 1)
                       identity-tests))
                     ((not (= hash (identity-table-entry-hash entry)))
                      (loop
                       (+ offset 1)
                       first-tombstone
                       (+ probes 1)
                       identity-tests))
                     ((entry-matches?
                       entry namespace heap-id object-id key)
                      (finish-open-search
                       table (+ probes 1) (+ identity-tests 1) index entry))
                     (else
                      (loop
                       (+ offset 1)
                       first-tombstone
                       (+ probes 1)
                       (+ identity-tests 1))))))))))

    (define (insert-existing! table slots entry)
      "Insert existing ENTRY into SLOTS during one private rehash."
      (let* ((capacity (vector-length slots))
             (start (modulo (identity-table-entry-hash entry) capacity)))
        (let loop ((offset 0) (probes 1))
          (let ((index (modulo (+ start offset) capacity)))
            (if (not (vector-ref slots index))
                (begin
                  (vector-set! slots index entry)
                  (counter-add! table counter-probes probes))
                (loop (+ offset 1) (+ probes 1)))))))

    (define (rehash-open! table new-capacity)
      "Rehash TABLE into NEW-CAPACITY without publishing partial storage."
      (let* ((old-slots (identity-table-slots table))
             (old-capacity (vector-length old-slots))
             (new-slots
              (allocate-slots
               "consent-identity-table" new-capacity)))
        (let loop ((index 0) (copied 0))
          (if (= index old-capacity)
              (begin
                (set-identity-table-slots! table new-slots)
                (set-identity-table-capacity! table new-capacity)
                (set-identity-table-tombstones! table 0)
                (if (not (= old-capacity new-capacity))
                    (counter-add! table counter-capacity-changes 1))
                (counter-add!
                 table counter-rehashed-entries copied)
                table)
              (let ((entry (vector-ref old-slots index)))
                (if (identity-table-entry? entry)
                    (begin
                      (insert-existing! table new-slots entry)
                      (loop (+ index 1) (+ copied 1)))
                    (loop (+ index 1) copied)))))))

    (define (rehash-chained-host! table new-capacity)
      "Relink host-only TABLE into chained NEW-CAPACITY storage."
      (let* ((old-slots (identity-table-slots table))
             (old-capacity (vector-length old-slots))
             (new-slots
              (allocate-slots
               "consent-identity-table" new-capacity)))
        (let bucket-loop ((index 0) (copied 0))
          (if (= index old-capacity)
              (begin
                (set-identity-table-slots! table new-slots)
                (set-identity-table-capacity! table new-capacity)
                (set-identity-table-tombstones! table 0)
                (if (not (= old-capacity new-capacity))
                    (counter-add! table counter-capacity-changes 1))
                (counter-add!
                 table counter-rehashed-entries copied)
                table)
              (let entry-loop
                  ((entry (vector-ref old-slots index))
                   (next-copied copied))
                (if (not entry)
                    (bucket-loop (+ index 1) next-copied)
                    (let* ((next (host-chain-entry-next entry))
                           (hash (host-chain-entry-hash entry))
                           (next-index (modulo hash new-capacity)))
                      ;; Allocation is complete before relinking begins. The
                      ;; remaining fixed vector and arithmetic operations
                      ;; cannot call user code or allocate table nodes.
                      (set-host-chain-entry-next!
                       entry (vector-ref new-slots next-index))
                      (vector-set! new-slots next-index entry)
                      (counter-add! table counter-probes 1)
                      (entry-loop
                       next
                       (+ next-copied 1)))))))))

    (define (rehash! table new-capacity)
      "Rebuild TABLE into NEW-CAPACITY under its fixed representation."
      (if (identity-table-chained-host? table)
          (rehash-chained-host! table new-capacity)
          (rehash-open! table new-capacity)))

    (define (reserve-hash-capacity! operation table requested)
      "Reserve REQUESTED hash buckets in TABLE for OPERATION."
      (let* ((capacity (identity-table-capacity-value table))
             (maximum (identity-table-maximum-capacity-value table))
             (target
              (if (= capacity 0)
                  (max requested
                       (identity-table-initial-capacity table))
                  requested)))
        (if (> target maximum)
            (error
             (string-append operation ": capacity exceeds maximum")
             target
             maximum))
        (if (and (> target capacity)
                 (not
                  (and (eq? (identity-table-key-policy-value table) 'host)
                       (not (identity-table-fast-host? table)))))
            (rehash! table target)))
      table)

    (define (consent-identity-table-reserve! table requested)
      "Reserve at least REQUESTED buckets in TABLE and return TABLE."
      #((parameters
         (table (type identity-table)
          (description "Table whose buckets are reserved."))
         (requested (type exact-nonnegative-integer)
          (description "Requested bucket count.")))
        (returns (type identity-table)
         (description "The original TABLE."))
        (effects allocation state-write error))
      (check-active-table "consent-identity-table-reserve!" table)
      (check-capacity "consent-identity-table-reserve!" requested)
      (reserve-hash-capacity!
       "consent-identity-table-reserve!" table requested))

    (define (capacity-admits? table capacity required)
      "Return whether CAPACITY admits REQUIRED entries for TABLE."
      (if (identity-table-chained-host? table)
          (<= required capacity)
          (< (* required 3) (* capacity 2))))

    (define (next-capacity table required)
      "Return TABLE's geometric capacity for REQUIRED live entries."
      (let ((maximum (identity-table-maximum-capacity-value table)))
        (let loop ((candidate
                    (max 1
                         (identity-table-initial-capacity table)
                         (identity-table-capacity-value table))))
          (if (or (>= candidate maximum)
                  (capacity-admits? table candidate required))
              (min candidate maximum)
              (loop (min maximum (+ (* candidate 2) 1)))))))

    (define (ensure-insertion-capacity! operation table)
      "Prepare TABLE for one absent hash-backed insertion."
      (let* ((capacity (identity-table-capacity-value table))
             (live (open-entry-count table))
             (tombstones (identity-table-tombstones table))
             (maximum (identity-table-maximum-capacity-value table))
             (required (+ live 1)))
        (if (>= (identity-table-size-value table) maximum)
            (error
             (string-append operation ": storage limit reached")
             (identity-table-domain-value table)
             (identity-table-size-value table)
             capacity
             maximum))
        (cond
         ((= capacity 0)
          (if (eq? (identity-table-growth-policy table) 'pre-reserved)
              (error
               (string-append operation
                              ": pre-reserved capacity exhausted")
               capacity))
          (let ((grown (next-capacity table 1)))
            (if (not (capacity-admits? table grown 1))
                (error
                 (string-append operation ": storage limit reached")
                 (identity-table-domain-value table)
                 (identity-table-size-value table)
                 capacity
                 maximum)
                (reserve-hash-capacity! operation table grown))))
         ((if (identity-table-chained-host? table)
              (<= required capacity)
              (< (* (+ live tombstones 1) 3) (* capacity 2)))
          table)
         ((and (> tombstones 0)
               (< (* required 3) (* capacity 2)))
          (rehash! table capacity))
         ((eq? (identity-table-growth-policy table) 'pre-reserved)
          (error
           (string-append operation ": pre-reserved capacity exhausted")
           capacity))
         (else
          (let ((grown (next-capacity table required)))
            (if (or (<= grown capacity)
                    (not (capacity-admits? table grown required)))
                (error
                 (string-append operation ": storage limit reached")
                 (identity-table-domain-value table)
                 (identity-table-size-value table)
                 capacity
                 maximum)
                (rehash! table grown))))))
      table)

    (define (identity-hash table namespace heap-id object-id key)
      "Return the fixed hash for one owned or host identity."
      (counter-add! table counter-hashes 1)
      (if (eq? namespace 'owned)
          (+ (* heap-id 65599) object-id)
          (fixed-host-identity-hash key)))

    ;; Mixed tables share open storage between disjoint namespaces. Host-only
    ;; fast tables use the chained specialization below.
    (define (open-host-ref table key default)
      "Return one open-addressed host association from TABLE."
      (let* ((counters (identity-table-counters table))
             (hash (fixed-host-identity-hash key))
             (slots (identity-table-slots table))
             (capacity (vector-length slots))
             (start (if (= capacity 0) 0 (modulo hash capacity)))
             (probes 0)
             (identity-tests 0)
             (entry
              (if (= capacity 0)
                  #f
                  (let loop ((offset 0))
                    (if (= offset capacity)
                        #f
                        (let* ((index
                                (modulo (+ start offset) capacity))
                               (candidate (vector-ref slots index)))
                          (set! probes (+ probes 1))
                          (cond
                           ((not candidate) #f)
                           ((eq? candidate identity-table-tombstone)
                            (loop (+ offset 1)))
                           ((not
                             (eq?
                              'host
                              (identity-table-entry-namespace
                               candidate)))
                            (loop (+ offset 1)))
                           ((not
                             (= hash
                                (identity-table-entry-hash candidate)))
                            (loop (+ offset 1)))
                           (else
                            (set! identity-tests
                                  (+ identity-tests 1))
                            (if (host-key-identity=?
                                 key
                                 (identity-table-entry-key candidate))
                                candidate
                                (loop (+ offset 1)))))))))))
        (record-open-host-operation!
         counters counter-lookups probes identity-tests)
        (if entry
            (identity-table-entry-value entry)
            (begin
              (vector-set!
               counters
               counter-misses
               (+ (vector-ref counters counter-misses) 1))
              default))))

    (define (open-host-set! operation table key value adjoin?)
      "Set host KEY, or only adjoin it when ADJOIN? is true."
      (let* ((counters (identity-table-counters table))
             (hash (fixed-host-identity-hash key))
             (slots (identity-table-slots table))
             (capacity (vector-length slots))
             (start (if (= capacity 0) 0 (modulo hash capacity)))
             (probes 0)
             (identity-tests 0)
             (index #f)
             (entry #f))
        (if (> capacity 0)
            (let loop ((offset 0) (first-tombstone #f))
              (if (= offset capacity)
                  (set! index first-tombstone)
                  (let* ((candidate-index
                          (modulo (+ start offset) capacity))
                         (candidate
                          (vector-ref slots candidate-index)))
                    (set! probes (+ probes 1))
                    (cond
                     ((not candidate)
                      (set! index
                            (if first-tombstone
                                first-tombstone
                                candidate-index)))
                     ((eq? candidate identity-table-tombstone)
                      (loop
                       (+ offset 1)
                       (if first-tombstone
                           first-tombstone
                           candidate-index)))
                     ((not
                       (eq?
                        'host
                        (identity-table-entry-namespace candidate)))
                      (loop (+ offset 1) first-tombstone))
                     ((not
                       (= hash (identity-table-entry-hash candidate)))
                      (loop (+ offset 1) first-tombstone))
                     (else
                      (set! identity-tests (+ identity-tests 1))
                      (if (host-key-identity=?
                           key (identity-table-entry-key candidate))
                          (begin
                            (set! index candidate-index)
                            (set! entry candidate))
                          (loop (+ offset 1) first-tombstone))))))))
        (record-open-host-operation!
         counters counter-sets probes identity-tests)
        (if entry
            (if (not adjoin?)
                (begin
                  (set-identity-table-entry-value! entry value)
                  (counter-add! table counter-updates 1)))
            (if (and index
                     (= (identity-table-tombstones table) 0)
                     (< (* (+ (identity-table-size-value table) 1) 3)
                        (* capacity 2)))
                (install-open-entry!
                 operation table index 'host #f #f key value hash)
                (let ((prior-slots slots))
                  (ensure-insertion-capacity! operation table)
                  (if (eq? prior-slots (identity-table-slots table))
                      (install-open-entry!
                       operation table index 'host #f #f key value hash)
                      (call-with-values
                          (lambda ()
                            (find-open-slot
                             table 'host #f #f key hash))
                        (lambda (next-index unexpected)
                          (if unexpected
                              (error
                               (string-append operation
                                              ": duplicate after rehash")
                               key))
                          (install-open-entry!
                           operation table next-index 'host #f #f key value
                           hash)))))))
        (if adjoin? (not entry) value)))

    (define (chain-host-ref table key default)
      "Return one host-only chained association from TABLE."
      (let* ((counters (identity-table-counters table))
             (hash (fixed-host-identity-hash key))
             (slots (identity-table-slots table))
             (capacity (vector-length slots))
             (entry
              (if (= capacity 0)
                  #f
                  (vector-ref slots (modulo hash capacity)))))
        (let loop
            ((cursor entry)
             (probes (if (= capacity 0) 0 1))
             (identity-tests 0))
          (cond
           ((not cursor)
            (record-open-host-operation!
             counters counter-lookups probes identity-tests)
            (vector-set!
             counters
             counter-misses
             (+ (vector-ref counters counter-misses) 1))
            default)
           ((not (= hash (host-chain-entry-hash cursor)))
            (loop
             (host-chain-entry-next cursor)
             (+ probes 1)
             identity-tests))
           ((host-key-identity=? key (host-chain-entry-key cursor))
            (record-open-host-operation!
             counters counter-lookups probes (+ identity-tests 1))
            (host-chain-entry-value cursor))
           (else
            (loop
             (host-chain-entry-next cursor)
             (+ probes 1)
             (+ identity-tests 1)))))))

    (define (chain-host-set! operation table key value adjoin?)
      "Set chained host KEY, or only adjoin it when ADJOIN? is true."
      (let* ((counters (identity-table-counters table))
             (hash (fixed-host-identity-hash key))
             (slots (identity-table-slots table))
             (capacity (vector-length slots))
             (size (identity-table-size-value table))
             (entry
              (if (= capacity 0)
                  #f
                  (vector-ref slots (modulo hash capacity)))))
        (let loop
            ((cursor entry)
             (probes (if (= capacity 0) 0 1))
             (identity-tests 0))
          (cond
           ((not cursor)
            (record-open-host-operation!
             counters counter-sets probes identity-tests)
            (let* ((next-slots
                    (if (and (> capacity 0)
                             (<= (+ size 1) capacity))
                        slots
                        (begin
                          (ensure-insertion-capacity! operation table)
                          (identity-table-slots table))))
                   (index
                    (modulo hash (vector-length next-slots)))
                   (next-entry
                    (make-host-chain-entry
                     (vector-ref next-slots index) hash key value)))
              (vector-set! next-slots index next-entry)
              (set-identity-table-size!
               table (+ size 1))
              (counter-add! table counter-inserts 1))
            (if adjoin? #t value))
           ((not (= hash (host-chain-entry-hash cursor)))
            (loop
             (host-chain-entry-next cursor)
             (+ probes 1)
             identity-tests))
           ((host-key-identity=? key (host-chain-entry-key cursor))
            (record-open-host-operation!
             counters counter-sets probes (+ identity-tests 1))
            (if (not adjoin?)
                (begin
                  (set-host-chain-entry-value! cursor value)
                  (counter-add! table counter-updates 1)))
            (if adjoin? #f value))
           (else
            (loop
             (host-chain-entry-next cursor)
             (+ probes 1)
             (+ identity-tests 1)))))))

    (define (chain-host-delete! table key)
      "Delete one host-only chained association from TABLE."
      (let* ((counters (identity-table-counters table))
             (hash (fixed-host-identity-hash key))
             (slots (identity-table-slots table))
             (capacity (vector-length slots))
             (index (if (= capacity 0) #f (modulo hash capacity)))
             (entry (if index (vector-ref slots index) #f)))
        (let loop
            ((cursor entry)
             (previous #f)
             (probes (if (= capacity 0) 0 1))
             (identity-tests 0))
          (cond
           ((not cursor)
            (record-open-host-operation!
             counters counter-deletes probes identity-tests)
            (counter-add! table counter-misses 1)
            #f)
           ((not (= hash (host-chain-entry-hash cursor)))
            (loop
             (host-chain-entry-next cursor)
             cursor
             (+ probes 1)
             identity-tests))
           ((host-key-identity=? key (host-chain-entry-key cursor))
            (record-open-host-operation!
             counters counter-deletes probes (+ identity-tests 1))
            (if previous
                (set-host-chain-entry-next!
                 previous (host-chain-entry-next cursor))
                (vector-set!
                 slots index (host-chain-entry-next cursor)))
            (set-identity-table-size!
             table (- (identity-table-size-value table) 1))
            (counter-add! table counter-delete-hits 1)
            #t)
           (else
            (loop
             (host-chain-entry-next cursor)
             cursor
             (+ probes 1)
             (+ identity-tests 1)))))))

    (define (open-ref
             operation table namespace heap-id object-id key default)
      "Return one open-addressed association for OPERATION."
      (let ((hash
             (identity-hash table namespace heap-id object-id key)))
        (call-with-values
            (lambda ()
              (find-open-slot
               table namespace heap-id object-id key hash))
          (lambda (index entry)
            (if entry
                (identity-table-entry-value entry)
                (begin
                  (counter-add! table counter-misses 1)
                  default))))))

    (define (install-open-entry!
             operation table index namespace heap-id object-id key value hash)
      "Install one known-absent open-addressed association."
      (if (not index)
          (error
           (string-append operation ": no insertion bucket")
           key))
      (let ((prior
             (vector-ref (identity-table-slots table) index)))
        (vector-set!
         (identity-table-slots table)
         index
         (make-identity-table-entry
          namespace heap-id object-id key value hash))
        (if (eq? prior identity-table-tombstone)
            (set-identity-table-tombstones!
             table
             (- (identity-table-tombstones table) 1)))
        (set-identity-table-size!
         table (+ (identity-table-size-value table) 1))
        (counter-add! table counter-inserts 1)))

    (define (open-set!
             operation table namespace heap-id object-id key value)
      "Associate one open-addressed fixed identity with VALUE."
      (let ((hash
             (identity-hash table namespace heap-id object-id key)))
        (call-with-values
            (lambda ()
              (find-open-slot
               table namespace heap-id object-id key hash))
          (lambda (index entry)
            (if entry
                (begin
                  ;; Owned IDs select their association independently of the
                  ;; retained object. Replace that explicit root on update so
                  ;; the prior object does not outlive its declared scope.
                  (if (eq? namespace 'owned)
                      (set-identity-table-entry-key! entry key))
                  (set-identity-table-entry-value! entry value)
                  (counter-add! table counter-updates 1))
                (let ((prior-slots (identity-table-slots table)))
                  (ensure-insertion-capacity! operation table)
                  (if (eq? prior-slots (identity-table-slots table))
                      (install-open-entry!
                       operation table index namespace heap-id object-id
                       key value hash)
                      (call-with-values
                          (lambda ()
                            (find-open-slot
                             table namespace heap-id object-id key hash))
                        (lambda (next-index unexpected)
                          (if unexpected
                              (error
                               (string-append operation
                                              ": duplicate after rehash")
                               key))
                          (install-open-entry!
                           operation table next-index namespace heap-id
                           object-id key value hash)))))))))
      value)

    (define (open-delete!
             table namespace heap-id object-id key)
      "Delete one open-addressed fixed identity from TABLE."
      (let ((hash
             (identity-hash table namespace heap-id object-id key)))
        (call-with-values
            (lambda ()
              (find-open-slot
               table namespace heap-id object-id key hash))
          (lambda (index entry)
            (if entry
                (begin
                  (vector-set!
                   (identity-table-slots table)
                   index identity-table-tombstone)
                  (set-identity-table-size!
                   table (- (identity-table-size-value table) 1))
                  (set-identity-table-tombstones!
                   table (+ (identity-table-tombstones table) 1))
                  (counter-add! table counter-delete-hits 1)
                  #t)
                (begin
                  (counter-add! table counter-misses 1)
                  #f))))))

    (define (compatibility-find table key)
      "Return the compatibility-list tail whose entry matches KEY."
      (let loop ((rest (identity-table-compatibility table)))
        (if (null? rest)
            #f
            (let ((entry (car rest)))
              (counter-add! table counter-compatibility-scans 1)
              (counter-add! table counter-identity-tests 1)
              (if (host-key-identity=?
                   key (identity-table-entry-key entry))
                  rest
                  (loop (cdr rest)))))))

    (define (compatibility-ref table key default)
      "Return compatibility association for KEY, or DEFAULT."
      (let ((found (compatibility-find table key)))
        (if found
            (identity-table-entry-value (car found))
            (begin
              (counter-add! table counter-misses 1)
              default))))

    (define (compatibility-set! operation table key value adjoin?)
      "Set compatibility KEY, or only adjoin it when ADJOIN? is true."
      (let ((found (compatibility-find table key)))
        (if found
            (if (not adjoin?)
                (begin
                  (set-identity-table-entry-value! (car found) value)
                  (counter-add! table counter-updates 1)))
            (begin
              (if (>= (identity-table-size-value table)
                      (identity-table-maximum-capacity-value table))
                  (error
                   (string-append operation ": storage limit reached")
                   (identity-table-domain-value table)
                   (identity-table-size-value table)
                   (identity-table-capacity-value table)
                   (identity-table-maximum-capacity-value table)))
              (if (>= (identity-table-compatibility-count table)
                      identity-table-compatibility-limit)
                  (error
                   (string-append
                    operation
                    ": compatibility limit requires fast backend")
                   identity-table-compatibility-limit))
              (set-identity-table-compatibility!
               table
               (cons
                (make-identity-table-entry
                 'host #f #f key value 0)
                (identity-table-compatibility table)))
              (set-identity-table-compatibility-count!
               table (+ (identity-table-compatibility-count table) 1))
              (set-identity-table-size!
               table (+ (identity-table-size-value table) 1))
              (counter-add! table counter-inserts 1)))
        (if adjoin? (not found) value)))

    (define (compatibility-delete! table key)
      "Delete compatibility host KEY from TABLE."
      (let loop ((rest (identity-table-compatibility table))
                 (previous #f))
        (if (null? rest)
            (begin
              (counter-add! table counter-misses 1)
              #f)
            (let ((entry (car rest)))
              (counter-add! table counter-compatibility-scans 1)
              (counter-add! table counter-identity-tests 1)
              (if (host-key-identity=?
                   key (identity-table-entry-key entry))
                  (begin
                    (if previous
                        (set-cdr! previous (cdr rest))
                        (set-identity-table-compatibility!
                         table (cdr rest)))
                    (set-identity-table-compatibility-count!
                     table
                     (- (identity-table-compatibility-count table) 1))
                    (set-identity-table-size!
                     table (- (identity-table-size-value table) 1))
                    (counter-add! table counter-delete-hits 1)
                    #t)
                  (loop (cdr rest) rest))))))

    (define (host-ref operation table key default)
      "Return host KEY's value from TABLE for OPERATION."
      (check-active-namespace operation table 'host)
      (if (identity-table-chained-host? table)
          (chain-host-ref table key default)
          (if (identity-table-fast-host? table)
              (open-host-ref table key default)
              (begin
                (counter-add! table counter-lookups 1)
                (compatibility-ref table key default)))))

    (define (consent-identity-table-host-ref table key default)
      "Return host identity KEY's value, or DEFAULT."
      #((parameters
         (table (type identity-table) (description "Table to inspect."))
         (key (type any) (description "Host identity key."))
         (default (type any) (description "Absent-key result.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects state-read error))
      (host-ref "consent-identity-table-host-ref" table key default))

    (define (consent-identity-table-host-contains? table key)
      "Return whether TABLE contains host identity KEY."
      #((parameters
         (table (type identity-table) (description "Table to inspect."))
         (key (type any) (description "Host identity key.")))
        (returns (type boolean)
         (description "Whether KEY has an association."))
        (effects allocation state-read error))
      (check-active-table
       "consent-identity-table-host-contains?" table)
      (counter-add! table counter-contains 1)
      (let ((absent (vector 'identity-table-absent)))
        (not (eq?
              (host-ref
               "consent-identity-table-host-contains?"
               table key absent)
              absent))))

    (define (consent-identity-table-host-set! table key value)
      "Associate host identity KEY with VALUE and return VALUE."
      #((parameters
         (table (type identity-table) (description "Table to update."))
         (key (type any) (description "Host identity key."))
         (value (type any) (description "Value to retain.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects allocation state-write error))
      (let ((operation "consent-identity-table-host-set!"))
        (check-active-namespace operation table 'host)
        (if (identity-table-chained-host? table)
            (chain-host-set! operation table key value #f)
            (if (identity-table-fast-host? table)
                (open-host-set! operation table key value #f)
                (begin
                  (counter-add! table counter-sets 1)
                  (compatibility-set! operation table key value #f))))))

    (define (consent-identity-table-host-adjoin! table key value)
      "Associate host identity KEY only when absent and report insertion."
      #((parameters
         (table (type identity-table) (description "Table to update."))
         (key (type any) (description "Host identity key."))
         (value (type any) (description "Value retained for a new key.")))
        (returns (type boolean)
         (description "Whether a new association was inserted."))
        (effects allocation state-write error))
      (let ((operation "consent-identity-table-host-adjoin!"))
        (check-active-namespace operation table 'host)
        (if (identity-table-chained-host? table)
            (chain-host-set! operation table key value #t)
            (if (identity-table-fast-host? table)
                (open-host-set! operation table key value #t)
                (begin
                  (counter-add! table counter-sets 1)
                  (compatibility-set! operation table key value #t))))))

    (define (consent-identity-table-host-delete! table key)
      "Delete host identity KEY and return whether it was present."
      #((parameters
         (table (type identity-table) (description "Table to update."))
         (key (type any) (description "Host identity key.")))
        (returns (type boolean)
         (description "Whether an association was deleted."))
        (effects state-write error))
      (let ((operation "consent-identity-table-host-delete!"))
        (check-active-table operation table)
        (check-namespace operation table 'host)
        (if (identity-table-chained-host? table)
            (chain-host-delete! table key)
            (if (identity-table-fast-host? table)
                (begin
                  (counter-add! table counter-deletes 1)
                  (open-delete! table 'host #f #f key))
                (begin
                  (counter-add! table counter-deletes 1)
                  (compatibility-delete! table key))))))

    (define (owned-ref operation table heap-id object-id default)
      "Return owned identity value from TABLE for OPERATION."
      (check-active-table operation table)
      (check-namespace operation table 'owned)
      (check-owned-id operation "heap id" heap-id)
      (check-owned-id operation "object id" object-id)
      (counter-add! table counter-lookups 1)
      (open-ref operation table 'owned heap-id object-id #f default))

    (define (consent-identity-table-owned-ref
             table heap-id object-id default)
      "Return owned identity value, or DEFAULT."
      #((parameters
         (table (type identity-table) (description "Table to inspect."))
         (heap-id (type exact-nonnegative-integer)
          (description "Stable owned heap identifier."))
         (object-id (type exact-nonnegative-integer)
          (description "Stable heap-local object identifier."))
         (default (type any) (description "Absent-key result.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects state-read error))
      (owned-ref
       "consent-identity-table-owned-ref"
       table heap-id object-id default))

    (define (consent-identity-table-owned-contains?
             table heap-id object-id)
      "Return whether TABLE contains one owned identity."
      #((parameters
         (table (type identity-table) (description "Table to inspect."))
         (heap-id (type exact-nonnegative-integer)
          (description "Stable owned heap identifier."))
         (object-id (type exact-nonnegative-integer)
          (description "Stable heap-local object identifier.")))
        (returns (type boolean)
         (description "Whether the owned identity is present."))
        (effects allocation state-read error))
      (check-active-table
       "consent-identity-table-owned-contains?" table)
      (counter-add! table counter-contains 1)
      (let ((absent (vector 'identity-table-absent)))
        (not
         (eq?
          (owned-ref
           "consent-identity-table-owned-contains?"
           table heap-id object-id absent)
          absent))))

    (define (consent-identity-table-owned-set!
             table heap-id object-id object value)
      "Associate one stable owned identity with OBJECT and VALUE."
      #((parameters
         (table (type identity-table) (description "Table to update."))
         (heap-id (type exact-nonnegative-integer)
          (description "Stable owned heap identifier."))
         (object-id (type exact-nonnegative-integer)
          (description "Stable heap-local object identifier."))
         (object (type any)
          (description "Owned object retained as the explicit root."))
         (value (type any) (description "Value to retain.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects allocation state-write error))
      (let ((operation "consent-identity-table-owned-set!"))
        (check-active-table operation table)
        (check-namespace operation table 'owned)
        (check-owned-id operation "heap id" heap-id)
        (check-owned-id operation "object id" object-id)
        (counter-add! table counter-sets 1)
        (open-set!
         operation table 'owned heap-id object-id object value)))

    (define (consent-identity-table-owned-delete!
             table heap-id object-id)
      "Delete one owned identity and return whether it was present."
      #((parameters
         (table (type identity-table) (description "Table to update."))
         (heap-id (type exact-nonnegative-integer)
          (description "Stable owned heap identifier."))
         (object-id (type exact-nonnegative-integer)
          (description "Stable heap-local object identifier.")))
        (returns (type boolean)
         (description "Whether an association was deleted."))
        (effects state-write error))
      (let ((operation "consent-identity-table-owned-delete!"))
        (check-active-table operation table)
        (check-namespace operation table 'owned)
        (check-owned-id operation "heap id" heap-id)
        (check-owned-id operation "object id" object-id)
        (counter-add! table counter-deletes 1)
        (open-delete! table 'owned heap-id object-id #f)))

    (define (clear-storage! table release?)
      "Clear every table-owned root, recording RELEASE? accounting."
      (let ((capacity (identity-table-capacity-value table))
            (compatibility-count
             (identity-table-compatibility-count table)))
        ;; Reusable clear retains the private vector, so it must overwrite each
        ;; root. Terminal release instead replaces the table's sole reference
        ;; to that encapsulated vector immediately after this helper returns.
        ;; Scanning the discarded vector first would add O(capacity) work
        ;; without shortening any externally observable root lifetime.
        (if (not release?)
            (vector-fill! (identity-table-slots table) #f))
        (set-identity-table-compatibility! table '())
        (set-identity-table-compatibility-count! table 0)
        (set-identity-table-size! table 0)
        (set-identity-table-tombstones! table 0)
        (if release?
            (begin
              (counter-add! table counter-releases 1)
              (counter-add!
               table counter-release-clear-slots
               (+ capacity compatibility-count)))
            (begin
              (counter-add! table counter-clears 1)
              (counter-add!
               table counter-clear-slots
               (+ capacity compatibility-count)))))
      table)

    (define (consent-identity-table-clear! table)
      "Clear TABLE's associations while retaining bucket capacity."
      #((parameters
         (table (type identity-table) (description "Table to clear.")))
        (returns (type identity-table)
         (description "The empty active TABLE."))
        (effects state-write error))
      (check-active-table "consent-identity-table-clear!" table)
      (clear-storage! table #f))

    (define (consent-identity-table-release! table)
      "Clear TABLE, drop its buckets, and end its lifetime."
      #((parameters
         (table (type identity-table) (description "Table to release.")))
        (returns (type identity-table)
         (description "The inactive released TABLE."))
        (effects state-write error))
      (if (not (consent-identity-table? table))
          (error
           "consent-identity-table-release!: expected identity table"
           table))
      (if (identity-table-active? table)
          (begin
            (clear-storage! table #t)
            (set-identity-table-slots! table (vector))
            (set-identity-table-capacity! table 0)
            (set-identity-table-active! table #f)))
      table)

    (define (entry->datum entry)
      "Return one Scheme-readable private ENTRY snapshot."
      (if (eq? (identity-table-entry-namespace entry) 'owned)
          (list 'owned
                (identity-table-entry-heap-id entry)
                (identity-table-entry-object-id entry)
                (identity-table-entry-key entry)
                (identity-table-entry-value entry))
          (list 'host
                (identity-table-entry-key entry)
                (identity-table-entry-value entry))))

    (define (consent-identity-table-entries table)
      "Return TABLE entries in unspecified implementation order."
      #((parameters
         (table (type identity-table) (description "Table to snapshot.")))
        (returns (type list)
         (description "Owned and host association records."))
        (effects allocation state-read error))
      (check-active-table "consent-identity-table-entries" table)
      (counter-add! table counter-snapshots 1)
      (let ((slots (identity-table-slots table)))
        (let bucket-loop ((index 0) (entries '()))
          (if (= index (vector-length slots))
              (let compatibility-loop
                  ((rest (identity-table-compatibility table))
                   (result entries))
                (if (null? rest)
                    (reverse result)
                    (compatibility-loop
                     (cdr rest)
                     (cons (entry->datum (car rest)) result))))
              (if (identity-table-chained-host? table)
                  (let entry-loop
                      ((entry (vector-ref slots index))
                       (result entries))
                    (if (not entry)
                        (bucket-loop (+ index 1) result)
                        (entry-loop
                         (host-chain-entry-next entry)
                         (cons
                          (list
                           'host
                           (host-chain-entry-key entry)
                           (host-chain-entry-value entry))
                          result))))
                  (let ((entry (vector-ref slots index)))
                    (bucket-loop
                     (+ index 1)
                     (if (identity-table-entry? entry)
                         (cons (entry->datum entry) entries)
                         entries))))))))

    (define (counter-ref table index)
      "Return TABLE counter INDEX."
      (vector-ref (identity-table-counters table) index))

    (define (consent-identity-table-stats table)
      "Return deterministic Scheme-readable TABLE statistics."
      #((parameters
         (table (type identity-table)
          (description "Active or released table to inspect.")))
        (returns (type list)
         (description "Stable identity-table statistics."))
        (effects allocation state-read error))
      (if (not (consent-identity-table? table))
          (error
           "consent-identity-table-stats: expected identity table" table))
      (list
       'identity-table
       (list 'domain (identity-table-domain-value table))
       (list 'key-policy (identity-table-key-policy-value table))
       (list 'host-backend
             (if (identity-table-fast-host? table)
                 'fast-hash
                 'compatibility))
       (list 'active? (identity-table-active? table))
       (list 'size (identity-table-size-value table))
       (list 'capacity (identity-table-capacity-value table))
       (list 'initial-capacity
             (identity-table-initial-capacity table))
       (list 'maximum-capacity
             (identity-table-maximum-capacity-value table))
       (list 'growth-policy (identity-table-growth-policy table))
       (list 'tombstones (identity-table-tombstones table))
       (list 'compatibility-count
             (identity-table-compatibility-count table))
       (list 'compatibility-limit identity-table-compatibility-limit)
       (list 'lookups (counter-ref table counter-lookups))
       (list 'contains (counter-ref table counter-contains))
       (list 'sets (counter-ref table counter-sets))
       (list 'inserts (counter-ref table counter-inserts))
       (list 'updates (counter-ref table counter-updates))
       (list 'deletes (counter-ref table counter-deletes))
       (list 'delete-hits (counter-ref table counter-delete-hits))
       (list 'misses (counter-ref table counter-misses))
       (list 'hashes (counter-ref table counter-hashes))
       (list 'probe-steps (counter-ref table counter-probes))
       (list 'identity-tests
             (counter-ref table counter-identity-tests))
       (list 'compatibility-scan-steps
             (counter-ref table counter-compatibility-scans))
       (list 'capacity-changes
             (counter-ref table counter-capacity-changes))
       (list 'rehashed-entries
             (counter-ref table counter-rehashed-entries))
       (list 'clears (counter-ref table counter-clears))
       (list 'clear-slots (counter-ref table counter-clear-slots))
       (list 'releases (counter-ref table counter-releases))
       (list 'release-clear-slots
             (counter-ref table counter-release-clear-slots))
       (list 'snapshots (counter-ref table counter-snapshots))))))
