;;; Bootstrap-safe fixed-policy identity tables.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Open addressing, lifecycle, accounting, and owned-object hashing are
;;; portable. Only host identity hashing and comparison are adapter operations.

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
          (consent identity-table adapter))
  (begin
    ;; Compatibility scans are constant-bounded independently of table limits.
    (define identity-table-compatibility-limit 64)

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
    ;; Index of open-addressing bucket probes.
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
          (description "Initially allocated bucket count."))
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
                   (consent-host-identity-fast-backend?))))
        (make-identity-table-record
         (allocate-slots
          "consent-make-identity-table" initial-capacity)
         initial-capacity
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
         (description "Whether host entries use open addressing."))
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
      "Return TABLE's allocated open-addressed bucket count."
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

    (define (entry-matches?
             table entry namespace heap-id object-id key)
      "Return whether ENTRY matches the supplied fixed identity."
      (if (not (eq? namespace (identity-table-entry-namespace entry)))
          #f
          (begin
            (counter-add! table counter-identity-tests 1)
            (if (eq? namespace 'owned)
                (and (= heap-id (identity-table-entry-heap-id entry))
                     (= object-id
                        (identity-table-entry-object-id entry)))
                (consent-host-identity=?
                 key (identity-table-entry-key entry))))))

    (define (find-open-slot
             table namespace heap-id object-id key hash)
      "Return matching entry or insertion bucket for one fixed identity."
      (let* ((slots (identity-table-slots table))
             (capacity (vector-length slots))
             (start (if (= capacity 0) 0 (modulo hash capacity))))
        (if (= capacity 0)
            (values #f #f)
            (let loop ((offset 0) (first-tombstone #f))
              (if (= offset capacity)
                  (values first-tombstone #f)
                  (let* ((index (modulo (+ start offset) capacity))
                         (entry (vector-ref slots index)))
                    (counter-add! table counter-probes 1)
                    (cond
                     ((not entry)
                      (values
                       (if first-tombstone first-tombstone index) #f))
                     ((eq? entry identity-table-tombstone)
                      (loop (+ offset 1)
                            (if first-tombstone
                                first-tombstone
                                index)))
                     ((entry-matches?
                       table entry namespace heap-id object-id key)
                      (values index entry))
                     (else (loop (+ offset 1) first-tombstone)))))))))

    (define (insert-existing! table slots entry)
      "Insert existing ENTRY into SLOTS during one private rehash."
      (let* ((capacity (vector-length slots))
             (start (modulo (identity-table-entry-hash entry) capacity)))
        (let loop ((offset 0))
          (let ((index (modulo (+ start offset) capacity)))
            (counter-add! table counter-probes 1)
            (if (not (vector-ref slots index))
                (vector-set! slots index entry)
                (loop (+ offset 1)))))))

    (define (rehash! table new-capacity)
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

    (define (reserve-open-capacity! operation table requested)
      "Reserve REQUESTED open buckets in TABLE for OPERATION."
      (let ((capacity (identity-table-capacity-value table))
            (maximum (identity-table-maximum-capacity-value table)))
        (if (> requested maximum)
            (error
             (string-append operation ": capacity exceeds maximum")
             requested
             maximum))
        (if (> requested capacity) (rehash! table requested)))
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
      (reserve-open-capacity!
       "consent-identity-table-reserve!" table requested))

    (define (next-capacity table required)
      "Return TABLE's geometric capacity for REQUIRED live entries."
      (let ((maximum (identity-table-maximum-capacity-value table)))
        (let loop ((candidate
                    (max 1 (identity-table-capacity-value table))))
          (if (or (>= candidate maximum)
                  (> (* candidate 2) (* required 3)))
              (min candidate maximum)
              (loop (min maximum (+ (* candidate 2) 1)))))))

    (define (ensure-insertion-capacity! operation table)
      "Prepare TABLE for one absent open-addressed insertion."
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
            (if (not (< 3 (* grown 2)))
                (error
                 (string-append operation ": storage limit reached")
                 (identity-table-domain-value table)
                 (identity-table-size-value table)
                 capacity
                 maximum)
                (reserve-open-capacity! operation table grown))))
         ((< (* (+ live tombstones 1) 3) (* capacity 2)) table)
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
                    (not (< (* required 3) (* grown 2))))
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
          (consent-host-identity-hash key)))

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
                (begin
                  (ensure-insertion-capacity! operation table)
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
                      (if (not next-index)
                          (error
                           (string-append operation
                                          ": no insertion bucket")
                           key))
                      (let ((prior
                             (vector-ref
                              (identity-table-slots table) next-index)))
                        (vector-set!
                         (identity-table-slots table)
                         next-index
                         (make-identity-table-entry
                          namespace heap-id object-id key value hash))
                        (if (eq? prior identity-table-tombstone)
                            (set-identity-table-tombstones!
                             table
                             (- (identity-table-tombstones table) 1)))
                        (set-identity-table-size!
                         table (+ (identity-table-size-value table) 1))
                        (counter-add! table counter-inserts 1)))))))))
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
              (if (consent-host-identity=?
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

    (define (compatibility-set! operation table key value)
      "Associate compatibility host KEY with VALUE in TABLE."
      (let ((found (compatibility-find table key)))
        (if found
            (begin
              (set-identity-table-entry-value! (car found) value)
              (counter-add! table counter-updates 1))
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
              (counter-add! table counter-inserts 1))))
      value)

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
              (if (consent-host-identity=?
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
      (check-active-table operation table)
      (check-namespace operation table 'host)
      (counter-add! table counter-lookups 1)
      (if (identity-table-fast-host? table)
          (open-ref operation table 'host #f #f key default)
          (compatibility-ref table key default)))

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
        (check-active-table operation table)
        (check-namespace operation table 'host)
        (counter-add! table counter-sets 1)
        (if (identity-table-fast-host? table)
            (open-set! operation table 'host #f #f key value)
            (compatibility-set! operation table key value))))

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
        (counter-add! table counter-deletes 1)
        (if (identity-table-fast-host? table)
            (open-delete! table 'host #f #f key)
            (compatibility-delete! table key))))

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
      "Clear every root from TABLE, recording RELEASE? accounting."
      (let ((capacity (identity-table-capacity-value table))
            (compatibility-count
             (identity-table-compatibility-count table)))
        (vector-fill! (identity-table-slots table) #f)
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
              (let ((entry (vector-ref slots index)))
                (bucket-loop
                 (+ index 1)
                 (if (identity-table-entry? entry)
                     (cons (entry->datum entry) entries)
                     entries)))))))

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
