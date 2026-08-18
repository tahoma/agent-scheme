;;; Provider-neutral mutable hash-table storage.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This internal library owns the shared storage model for the mutable hash
;;; table family.  Public SRFI and R7RS-large libraries remain separate
;;; facades because their constructors, introspection, traversal results, and
;;; mutation contracts differ.  Entries also form a stable insertion-order
;;; chain so SRFI 250 can add cursors without replacing the SRFI 125 storage
;;; representation.

(define-library (stdlib hash-table implementation)
  (export make-hash-table-policy
          hash-table-policy?
          hash-table-policy-type-test
          hash-table-policy-equivalence
          hash-table-policy-hash
          hash-table-policy-token
          hash-table-policy-comparator
          make-hash-table-storage
          hash-table-storage?
          hash-table-storage-policy
          hash-table-storage-mutable?
          hash-table-storage-size
          hash-table-storage-capacity
          hash-table-storage-mutation-version
          hash-table-storage-structural-version
          hash-table-storage-compatible?
          hash-table-storage-ref-entry
          hash-table-storage-set!
          hash-table-storage-delete!
          hash-table-storage-clear!
          hash-table-storage-reserve!
          hash-table-storage-copy
          hash-table-storage-entries
          hash-table-storage-first-entry
          hash-table-storage-last-entry
          hash-table-entry?
          hash-table-entry-key
          hash-table-entry-value
          hash-table-entry-set-value!
          hash-table-entry-next
          hash-table-entry-previous)
  (import (scheme base))
  (begin
    ;; A policy keeps key semantics independent from every public API facade.
    (define-record-type <hash-table-policy>
      (%make-hash-table-policy type-test equivalence hash token comparator)
      hash-table-policy?
      (type-test hash-table-policy-type-test)
      (equivalence hash-table-policy-equivalence)
      (hash hash-table-policy-hash)
      (token hash-table-policy-token)
      (comparator hash-table-policy-comparator))

    (define (make-hash-table-policy
             type-test equivalence hash token comparator)
      "Return a hash-table key policy from the supplied procedures."
      #((parameters
         (type-test (type procedure) (description "Key type predicate."))
         (equivalence (type procedure) (description "Key equivalence."))
         (hash (type procedure) (description "Key hash procedure."))
         (token (type any) (description "Compatibility identity token."))
         (comparator (type any) (description "Source comparator or #f.")))
        (returns (type hash-table-policy)
         (description "Reusable hash-table key policy."))
        (effects allocation error))
      (if (and (procedure? type-test)
               (procedure? equivalence)
               (procedure? hash))
          (%make-hash-table-policy
           type-test equivalence hash token comparator)
          (error "hash-table policy requires procedures"
                 type-test equivalence hash)))

    ;; Entries participate in an intrusive bucket chain and in a doubly linked
    ;; order chain.  A false owner marks a removed entry, avoiding a separate
    ;; liveness field in every association.
    (define-record-type <hash-table-entry>
      (%make-hash-table-entry
       owner key value hash previous next bucket-next)
      hash-table-entry?
      (owner hash-table-entry-owner %set-hash-table-entry-owner!)
      (key hash-table-entry-key)
      (value hash-table-entry-value %set-hash-table-entry-value!)
      (hash hash-table-entry-hash)
      (previous hash-table-entry-previous
                %set-hash-table-entry-previous!)
      (next hash-table-entry-next %set-hash-table-entry-next!)
      (bucket-next hash-table-entry-bucket-next
                   %set-hash-table-entry-bucket-next!))

    ;; Structural and value-sensitive revisions serve different later APIs.
    (define-record-type <hash-table-storage>
      (%make-hash-table-storage
       policy buckets size mutable? mutation structural first last)
      hash-table-storage?
      (policy hash-table-storage-policy)
      (buckets hash-table-storage-buckets %set-hash-table-storage-buckets!)
      (size hash-table-storage-size %set-hash-table-storage-size!)
      (mutable? hash-table-storage-mutable? %set-hash-table-storage-mutable?!)
      (mutation hash-table-storage-mutation-version
                %set-hash-table-storage-mutation-version!)
      (structural hash-table-storage-structural-version
                  %set-hash-table-storage-structural-version!)
      (first hash-table-storage-first-entry
             %set-hash-table-storage-first-entry!)
      (last hash-table-storage-last-entry
            %set-hash-table-storage-last-entry!))

    ;; Smallest bucket vector allocated by the portable provider.
    (define minimum-bucket-count 8)

    (define (capacity->bucket-count capacity)
      "Return a power-of-two bucket count suitable for CAPACITY entries."
      ;; Automatic growth permits three live entries per four buckets.  Round
      ;; 4 * CAPACITY / 3 upward so an explicit capacity request receives the
      ;; same guarantee without reserving twice as many buckets.
      (let ((target
             (max minimum-bucket-count
                  (quotient (+ (* 4 capacity) 2) 3))))
        (let loop ((count minimum-bucket-count))
          (if (>= count target) count (loop (* 2 count))))))

    (define (make-hash-table-storage policy capacity mutable?)
      "Return empty hash-table storage using POLICY and CAPACITY."
      #((parameters
         (policy (type hash-table-policy) (description "Key policy."))
         (capacity (type exact-non-negative-integer)
          (description "Requested association capacity."))
         (mutable? (type boolean) (description "Whether mutations work.")))
        (returns (type hash-table-storage)
         (description "Empty shared hash-table storage."))
        (effects allocation error))
      (if (not (hash-table-policy? policy))
          (error "invalid hash-table policy" policy))
      (if (not (and (exact-integer? capacity) (>= capacity 0)))
          (error "invalid hash-table capacity" capacity))
      (%make-hash-table-storage
       policy
       (make-vector (capacity->bucket-count capacity) #f)
       0
       (if mutable? #t #f)
       0
       0
       #f
       #f))

    (define (hash-table-storage-capacity storage)
      "Return the current association capacity of STORAGE."
      #((parameters
         (storage (type hash-table-storage) (description "Storage.")))
        (returns (type exact-positive-integer)
         (description "Capacity before the next automatic resize."))
        (effects error))
      (quotient
       (* 3 (vector-length (hash-table-storage-buckets storage))) 4))

    (define (hash-table-storage-compatible? left right)
      "Return whether LEFT and RIGHT use the same key policy identity."
      #((parameters
         (left (type hash-table-storage) (description "First storage."))
         (right (type hash-table-storage) (description "Second storage.")))
        (returns (type boolean) (description "Whether policies agree."))
        (effects error))
      (eq? (hash-table-policy-token (hash-table-storage-policy left))
           (hash-table-policy-token (hash-table-storage-policy right))))

    (define (check-mutable storage operation)
      "Signal an error unless STORAGE is mutable."
      (if (not (hash-table-storage-mutable? storage))
          (error "immutable hash table" operation storage)))

    (define (checked-key-hash storage key)
      "Return KEY's checked hash under STORAGE's policy."
      (let* ((policy (hash-table-storage-policy storage))
             (type-test (hash-table-policy-type-test policy)))
        (if (not (type-test key))
            (error "key rejected by hash-table comparator" key))
        (let ((hash ((hash-table-policy-hash policy) key)))
          (if (and (exact-integer? hash) (>= hash 0))
              hash
              (error "hash function returned invalid hash" hash key)))))

    (define (hash-index buckets hash)
      "Return HASH's index into BUCKETS."
      (modulo hash (vector-length buckets)))

    (define (find-entry-in-bucket policy entry key hash)
      "Return KEY's entry in BUCKET, or #f."
      (let ((equivalence (hash-table-policy-equivalence policy)))
        (let loop ((entry entry))
          (cond
           ((not entry) #f)
           ((and (= hash (hash-table-entry-hash entry))
                 (equivalence key (hash-table-entry-key entry)))
            entry)
           (else (loop (hash-table-entry-bucket-next entry)))))))

    (define (hash-table-storage-ref-entry storage key)
      "Return STORAGE's entry for KEY, or #f when absent."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (key (type any) (description "Key to look up.")))
        (returns (type (or hash-table-entry boolean))
         (description "Matching entry, or #f."))
        (effects error procedure-call))
      (let* ((hash (checked-key-hash storage key))
             (buckets (hash-table-storage-buckets storage))
             (bucket (vector-ref buckets (hash-index buckets hash))))
        (find-entry-in-bucket
         (hash-table-storage-policy storage) bucket key hash)))

    (define (increment-mutation! storage structural?)
      "Advance STORAGE's mutation revisions."
      (%set-hash-table-storage-mutation-version!
       storage
       (+ 1 (hash-table-storage-mutation-version storage)))
      (if structural?
          (%set-hash-table-storage-structural-version!
           storage
           (+ 1 (hash-table-storage-structural-version storage)))))

    (define (append-entry! storage entry)
      "Append ENTRY to STORAGE's insertion-order chain."
      (let ((last (hash-table-storage-last-entry storage)))
        (if last
            (begin
              (%set-hash-table-entry-next! last entry)
              (%set-hash-table-entry-previous! entry last))
            (%set-hash-table-storage-first-entry! storage entry))
        (%set-hash-table-storage-last-entry! storage entry)))

    (define (unlink-entry! storage entry)
      "Remove ENTRY from STORAGE's insertion-order chain."
      (let ((previous (hash-table-entry-previous entry))
            (next (hash-table-entry-next entry)))
        (if previous
            (%set-hash-table-entry-next! previous next)
            (%set-hash-table-storage-first-entry! storage next))
        (if next
            (%set-hash-table-entry-previous! next previous)
            (%set-hash-table-storage-last-entry! storage previous))
        (%set-hash-table-entry-previous! entry #f)
        (%set-hash-table-entry-next! entry #f)
        (%set-hash-table-entry-owner! entry #f)))

    (define (delete-entry-from-bucket! policy buckets index key hash)
      "Unlink and return KEY's entry from BUCKETS, or return #f."
      (let ((equivalence (hash-table-policy-equivalence policy)))
        (let loop ((entry (vector-ref buckets index)) (previous #f))
          (cond
           ((not entry) #f)
           ((and (= hash (hash-table-entry-hash entry))
                 (equivalence key (hash-table-entry-key entry)))
            (let ((next (hash-table-entry-bucket-next entry)))
              (if previous
                  (%set-hash-table-entry-bucket-next! previous next)
                  (vector-set! buckets index next))
              (%set-hash-table-entry-bucket-next! entry #f)
              entry))
           (else
            (loop (hash-table-entry-bucket-next entry) entry))))))

    (define (rehash! storage bucket-count)
      "Replace STORAGE's buckets with BUCKET-COUNT buckets."
      (let ((buckets (make-vector bucket-count #f)))
        (let loop ((entry (hash-table-storage-first-entry storage)))
          (if entry
              (let ((next (hash-table-entry-next entry))
                    (index
                     (hash-index buckets (hash-table-entry-hash entry))))
                (%set-hash-table-entry-bucket-next!
                 entry (vector-ref buckets index))
                (vector-set! buckets index entry)
                (loop next))))
        (%set-hash-table-storage-buckets! storage buckets)))

    (define (hash-table-storage-reserve! storage capacity)
      "Ensure STORAGE can hold CAPACITY associations without growing."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (capacity (type exact-non-negative-integer)
          (description "Requested capacity.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error))
      (check-mutable storage 'hash-table-storage-reserve!)
      (if (not (and (exact-integer? capacity) (>= capacity 0)))
          (error "invalid hash-table capacity" capacity))
      (let ((bucket-count (capacity->bucket-count capacity)))
        (if (> bucket-count
               (vector-length (hash-table-storage-buckets storage)))
            (rehash! storage bucket-count))))

    (define (maybe-grow! storage)
      "Grow STORAGE before an insertion would exceed its load limit."
      (let ((buckets (hash-table-storage-buckets storage)))
        (if (> (* 4 (+ 1 (hash-table-storage-size storage)))
               (* 3 (vector-length buckets)))
            (rehash! storage (* 2 (vector-length buckets))))))

    (define (hash-table-storage-set! storage key value)
      "Associate KEY with VALUE in STORAGE and return its entry."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (key (type any) (description "Association key."))
         (value (type any) (description "Association value.")))
        (returns (type hash-table-entry)
         (description "Inserted or updated entry."))
        (effects mutation allocation error procedure-call))
      (check-mutable storage 'hash-table-storage-set!)
      (let* ((hash (checked-key-hash storage key))
             (buckets (hash-table-storage-buckets storage))
             (index (hash-index buckets hash))
             (entry
              (find-entry-in-bucket
               (hash-table-storage-policy storage)
               (vector-ref buckets index)
               key
               hash)))
        (if entry
            (begin
              (%set-hash-table-entry-value! entry value)
              (increment-mutation! storage #f)
              entry)
            (begin
              (maybe-grow! storage)
              (let* ((buckets (hash-table-storage-buckets storage))
                     (index (hash-index buckets hash))
                     (entry
                      (%make-hash-table-entry
                       storage key value hash #f #f
                       (vector-ref buckets index))))
                (vector-set! buckets index entry)
                (append-entry! storage entry)
                (%set-hash-table-storage-size!
                 storage (+ 1 (hash-table-storage-size storage)))
                (increment-mutation! storage #t)
                entry)))))

    (define (hash-table-entry-set-value! entry value)
      "Set active ENTRY's VALUE without changing insertion order."
      #((parameters
         (entry (type hash-table-entry) (description "Entry to update."))
         (value (type any) (description "Replacement value.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation error))
      (if (not (hash-table-entry-owner entry))
          (error "inactive hash-table entry" entry))
      (let ((storage (hash-table-entry-owner entry)))
        (check-mutable storage 'hash-table-entry-set-value!)
        (%set-hash-table-entry-value! entry value)
        (increment-mutation! storage #f)))

    (define (hash-table-storage-delete! storage key)
      "Delete KEY from STORAGE and return whether it was present."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (key (type any) (description "Key to delete.")))
        (returns (type boolean) (description "Whether KEY was present."))
        (effects mutation allocation error procedure-call))
      (check-mutable storage 'hash-table-storage-delete!)
      (let* ((hash (checked-key-hash storage key))
             (buckets (hash-table-storage-buckets storage))
             (index (hash-index buckets hash))
             (entry
              (delete-entry-from-bucket!
               (hash-table-storage-policy storage)
               buckets
               index
               key
               hash)))
        (if (not entry)
            #f
            (begin
              (unlink-entry! storage entry)
              (%set-hash-table-storage-size!
               storage (- (hash-table-storage-size storage) 1))
              (increment-mutation! storage #t)
              #t))))

    (define (hash-table-storage-clear! storage)
      "Delete every association from STORAGE."
      #((parameters
         (storage (type hash-table-storage) (description "Storage.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error))
      (check-mutable storage 'hash-table-storage-clear!)
      (if (> (hash-table-storage-size storage) 0)
          (begin
            (let loop ((entry (hash-table-storage-first-entry storage)))
              (if entry
                  (let ((next (hash-table-entry-next entry)))
                    (%set-hash-table-entry-previous! entry #f)
                    (%set-hash-table-entry-next! entry #f)
                    (%set-hash-table-entry-bucket-next! entry #f)
                    (%set-hash-table-entry-owner! entry #f)
                    (loop next))))
            (%set-hash-table-storage-buckets!
             storage (make-vector minimum-bucket-count #f))
            (%set-hash-table-storage-size! storage 0)
            (%set-hash-table-storage-first-entry! storage #f)
            (%set-hash-table-storage-last-entry! storage #f)
            (increment-mutation! storage #t))))

    (define (hash-table-storage-entries storage)
      "Return a fresh insertion-order list of STORAGE's active entries."
      #((parameters
         (storage (type hash-table-storage) (description "Storage.")))
        (returns (type list) (description "Fresh entry list."))
        (effects allocation error))
      (let loop ((entry (hash-table-storage-first-entry storage))
                 (head '())
                 (tail #f))
        (if (not entry)
            head
            (let ((cell (list entry)))
              (if tail (set-cdr! tail cell))
              (loop (hash-table-entry-next entry)
                    (if tail head cell)
                    cell)))))

    (define (hash-table-storage-copy storage mutable?)
      "Return a copy of STORAGE whose mutability is MUTABLE?."
      #((parameters
         (storage (type hash-table-storage) (description "Storage."))
         (mutable? (type boolean) (description "Copy mutability.")))
        (returns (type hash-table-storage) (description "Storage copy."))
        (effects allocation error procedure-call))
      (let ((copy
             (make-hash-table-storage
              (hash-table-storage-policy storage)
              (hash-table-storage-size storage)
              #t)))
        (let loop ((entry (hash-table-storage-first-entry storage)))
          (if entry
              (begin
                (hash-table-storage-set!
                 copy
                 (hash-table-entry-key entry)
                 (hash-table-entry-value entry))
                (loop (hash-table-entry-next entry)))))
        (if (not mutable?)
            (%set-hash-table-storage-mutable?! copy #f))
        copy))))
