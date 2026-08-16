;;; Portable Consent Scheme compound datum heap.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Scheme-visible pairs, strings, vectors, and bytevectors are opaque owned
;;; objects.  Their host containers are private storage accelerators behind
;;; this library.  All observable mutation crosses one hookable gateway so a
;;; later branch-local heap can attach copy-on-write and write barriers.

(define-library (consent datum)
  (export consent-datum-heap?
          consent-make-datum-heap
          consent-default-datum-heap
          consent-datum-heap-id
          consent-datum-heap-generation
          consent-datum-heap-owner
          consent-datum-heap-frozen?
          consent-datum-heap-owner-set!
          consent-datum-heap-mutation-hook-set!
          consent-datum-heap-freeze!
          consent-datum-object?
          consent-datum-object-kind
          consent-datum-object-heap-id
          consent-datum-object-id
          consent-datum-object-generation
          consent-datum-object-owner
          consent-datum-object-revision
          consent-datum-object-mutable?
          consent-datum-object-traversal
          consent-datum-object-traversal-set!
          consent-datum-object-source-metadata
          consent-datum-object-source-metadata-set!
          consent-datum-object-shareable?
          consent-make-datum-object-map
          consent-datum-object-map-ref
          consent-datum-object-map-set!
          consent-datum-object-map-release!
          consent-datum-object-map-probe-count
          call-with-consent-datum-object-map
          consent-datum-residency-tracking-start!
          consent-datum-residency-tracking-finish!
          consent-datum-residency-tracking-statistic
          consent-datum-residency-tracking-release!
          consent-datum-residency-tracking-report
          consent-call-with-datum-construction
          consent-datum-same?
          consent-datum-make-internal-slots
          consent-datum-internal-slot-ref
          consent-datum-internal-slot-set!
          consent-datum-pair?
          consent-datum-cons
          consent-datum-car
          consent-datum-car-trusted
          consent-datum-cdr
          consent-datum-cdr-trusted
          consent-datum-set-car!
          consent-datum-set-cdr!
          consent-datum-list-copy
          consent-datum-string?
          consent-datum-string-from-host
          consent-datum-string->host
          consent-datum-make-string
          consent-datum-string-copy-range
          consent-datum-string-length
          consent-datum-string-length-trusted
          consent-datum-string-ref-host
          consent-datum-string-ref-host-trusted
          consent-datum-string-set-host!
          consent-datum-vector?
          consent-datum-vector-from-host
          consent-datum-vector-from-host-elements
          consent-datum-vector->host
          consent-datum-make-vector
          consent-datum-vector-length
          consent-datum-vector-length-trusted
          consent-datum-vector-ref
          consent-datum-vector-ref-trusted
          consent-datum-vector-set!
          consent-datum-vector-set-trusted!
          consent-datum-bytevector?
          consent-datum-bytevector-from-host
          consent-datum-bytevector->host
          consent-datum-make-bytevector
          consent-datum-bytevector-length
          consent-datum-bytevector-u8-ref
          consent-datum-bytevector-u8-set!
          consent-datum-import
          consent-datum-import-with-node-count
          consent-datum-export)
  (import (scheme base)
          (only (consent dense-set)
                consent-dense-set-mark!
                consent-dense-set-member?
                consent-dense-set-release!
                consent-make-dense-set)
          (consent identity-map))
  (begin
    ;; Process-local heap identifiers distinguish otherwise equal ordinals.
    (define next-datum-heap-id 0)

    ;; Residency tracking is an opt-in portable observation scope. Ordinary
    ;; execution pays only one false branch per tracked ownership event; the
    ;; counters and their result datum allocate only while a benchmark or test
    ;; explicitly installs a tracker.
    (define datum-residency-category-names
      '#(owned-pair
         owned-string
         owned-vector
         owned-bytevector
         owned-internal
         construction-marker
         construction-index-slot
         revision-sidecar-page
         traversal-sidecar-page
         map-sidecar-page
         source-sidecar-page
         phase-map-page
         graph-map-entry
         import-result-shell
         import-host-memo-entry
         import-owned-memo-entry
         import-work-entry
         export-result-shell
         export-host-memo-entry
         export-owned-memo-entry
         export-work-entry))

    ;; Owned pair category index.
    (define datum-residency-owned-pair 0)
    ;; Owned string category index.
    (define datum-residency-owned-string 1)
    ;; Owned vector category index.
    (define datum-residency-owned-vector 2)
    ;; Owned bytevector category index.
    (define datum-residency-owned-bytevector 3)
    ;; Private internal object category index.
    (define datum-residency-owned-internal 4)
    ;; Construction marker category index.
    (define datum-residency-construction-marker 5)
    ;; Construction marker index-slot category index.
    (define datum-residency-construction-index-slot 6)
    ;; Revision sidecar-page category index.
    (define datum-residency-revision-sidecar-page 7)
    ;; Traversal sidecar-page category index.
    (define datum-residency-traversal-sidecar-page 8)
    ;; Intrusive-map sidecar-page category index.
    (define datum-residency-map-sidecar-page 9)
    ;; Source-metadata sidecar-page category index.
    (define datum-residency-source-sidecar-page 10)
    ;; Phase-local map-page category index.
    (define datum-residency-phase-map-page 11)
    ;; Intrusive graph-map entry category index.
    (define datum-residency-graph-map-entry 12)
    ;; Import result-shell category index.
    (define datum-residency-import-result-shell 13)
    ;; Import host-memo entry category index.
    (define datum-residency-import-host-memo-entry 14)
    ;; Import owned-memo entry category index.
    (define datum-residency-import-owned-memo-entry 15)
    ;; Import work-entry category index.
    (define datum-residency-import-work-entry 16)
    ;; Export result-shell category index.
    (define datum-residency-export-result-shell 17)
    ;; Export host-memo entry category index.
    (define datum-residency-export-host-memo-entry 18)
    ;; Export owned-memo entry category index.
    (define datum-residency-export-owned-memo-entry 19)
    ;; Export work-entry category index.
    (define datum-residency-export-work-entry 20)

    ;; One category counter is #(allocations releases live high-water).
    ;; Allocation counter slot.
    (define datum-residency-allocations 0)
    ;; Release counter slot.
    (define datum-residency-releases 1)
    ;; Current live-owner counter slot.
    (define datum-residency-live 2)
    ;; High-water owner counter slot.
    (define datum-residency-high-water 3)

    ;; A tracker is #(marker active? category-counters token outer).
    (define datum-residency-tracker-marker
      (vector 'consent-datum-residency-tracker))
    ;; Dynamically active tracker, or #f outside an observation scope.
    (define current-datum-residency-tracker #f)
    ;; Next scalar token safe to pass through the evaluator boundary.
    (define next-datum-residency-tracker-token 0)
    ;; Finished trackers retained until their caller explicitly releases them.
    (define completed-datum-residency-trackers '())

    (define (make-datum-residency-tracker token outer)
      "Return one active lazily populated residency tracker."
      (vector
       datum-residency-tracker-marker
       #t
       (make-vector (vector-length datum-residency-category-names) #f)
       token
       outer))

    (define (datum-residency-counter-for-write! tracker category)
      "Return TRACKER's writable counter vector for CATEGORY."
      (let* ((categories (vector-ref tracker 2))
             (counter (vector-ref categories category)))
        (or counter
            (let ((created (make-vector 4 0)))
              (vector-set! categories category created)
              created))))

    (define (datum-residency-open! category amount)
      "Record AMOUNT newly live units in the current CATEGORY."
      (let ((tracker current-datum-residency-tracker))
        (if tracker
            (let* ((counter
                    (datum-residency-counter-for-write! tracker category))
                   (live (+ (vector-ref counter datum-residency-live) amount)))
              (vector-set!
               counter
               datum-residency-allocations
               (+ (vector-ref counter datum-residency-allocations) amount))
              (vector-set! counter datum-residency-live live)
              (if (> live (vector-ref counter datum-residency-high-water))
                  (vector-set!
                   counter datum-residency-high-water live))))))

    (define (datum-residency-close! category amount)
      "Record release of AMOUNT live units in the current CATEGORY."
      (let ((tracker current-datum-residency-tracker))
        (if tracker
            (let* ((counter
                    (datum-residency-counter-for-write! tracker category))
                   (live (- (vector-ref counter datum-residency-live) amount)))
              (if (< live 0)
                  (error
                   "datum residency release exceeds live units"
                   (vector-ref datum-residency-category-names category)
                   amount
                   (vector-ref counter datum-residency-live)))
              (vector-set!
               counter
               datum-residency-releases
               (+ (vector-ref counter datum-residency-releases) amount))
              (vector-set! counter datum-residency-live live)))))

    (define (datum-residency-statistics tracker)
      "Return deterministic Scheme-readable residency statistics."
      (let ((counters (vector-ref tracker 2)))
        (let loop ((index 0) (result '()))
          (if (= index (vector-length datum-residency-category-names))
              (cons
               'datum-residency-stats
               (cons
                (list 'active (vector-ref tracker 1))
                (reverse result)))
              (let ((counter (vector-ref counters index)))
                (loop
                 (+ index 1)
                 (cons
                  (list
                   (vector-ref datum-residency-category-names index)
                   (list 'allocations
                         (if counter
                             (vector-ref
                              counter datum-residency-allocations)
                             0))
                   (list 'releases
                         (if counter
                             (vector-ref counter datum-residency-releases)
                             0))
                   (list 'live
                         (if counter
                             (vector-ref counter datum-residency-live)
                             0))
                   (list 'high-water
                         (if counter
                             (vector-ref counter datum-residency-high-water)
                             0)))
                  result)))))))

    (define (completed-datum-residency-tracker-ref token)
      "Return completed TOKEN's tracker, or #f when it is not retained."
      (let loop ((rest completed-datum-residency-trackers))
        (cond
         ((null? rest) #f)
         ((= token (caar rest)) (cdar rest))
         (else (loop (cdr rest))))))

    (define (consent-datum-residency-tracking-start!)
      "Start a nested portable datum-residency census and return its token."
      #((parameters)
        (returns (type exact-non-negative-integer)
         (description "Scalar token naming the new active census."))
        (effects allocation state-read state-write))
      (let* ((token next-datum-residency-tracker-token)
             (tracker
              (make-datum-residency-tracker
               token current-datum-residency-tracker)))
        (set! next-datum-residency-tracker-token (+ token 1))
        (set! current-datum-residency-tracker tracker)
        token))

    (define (consent-datum-residency-tracking-finish! token)
      "Finish the active datum-residency TOKEN and return TOKEN."
      #((parameters
         (token (type exact-non-negative-integer)
          (description "Token returned by the matching start operation.")))
        (returns (type exact-non-negative-integer)
         (description "TOKEN, now naming a completed retained census."))
        (effects allocation state-read state-write error))
      (let ((tracker current-datum-residency-tracker))
        (if (not (and tracker
                      (integer? token)
                      (exact? token)
                      (>= token 0)
                      (= token (vector-ref tracker 3))))
            (error
             "consent-datum-residency-tracking-finish!: expected active token"
             token))
        (set! current-datum-residency-tracker (vector-ref tracker 4))
        (vector-set! tracker 1 #f)
        (vector-set! tracker 4 #f)
        (set! completed-datum-residency-trackers
              (cons
               (cons token tracker)
               completed-datum-residency-trackers))
        token))

    (define (consent-datum-residency-tracking-statistic
             token category field)
      "Return one scalar FIELD counter for completed TOKEN and CATEGORY."
      #((parameters
         (token (type exact-non-negative-integer)
          (description "Completed retained census token."))
         (category (type exact-non-negative-integer)
          (description "Zero-based residency category index."))
         (field (type exact-non-negative-integer)
          (description "Counter index from allocation through high water.")))
        (returns (type exact-non-negative-integer)
         (description "The selected counter, or zero when unpopulated."))
        (effects state-read error))
      (let ((tracker
             (and (integer? token)
                  (exact? token)
                  (>= token 0)
                  (completed-datum-residency-tracker-ref token))))
        (if (not tracker)
            (error
             "datum residency statistic expected completed token"
             token))
        (if (not (and (integer? category)
                      (exact? category)
                      (<= 0 category)
                      (< category
                         (vector-length datum-residency-category-names))))
            (error "datum residency category index out of range" category))
        (if (not (and (integer? field)
                      (exact? field)
                      (<= 0 field)
                      (< field 4)))
            (error "datum residency field index out of range" field))
        (let ((counter (vector-ref (vector-ref tracker 2) category)))
          (if counter (vector-ref counter field) 0))))

    (define (consent-datum-residency-tracking-report token)
      "Return completed retained TOKEN's Scheme-readable statistics."
      #((parameters
         (token (type exact-non-negative-integer)
          (description "Completed retained census token.")))
        (returns (type list)
         (description "Per-category allocation and lifetime counters."))
        (effects allocation state-read error))
      (let ((tracker
             (and (integer? token)
                  (exact? token)
                  (>= token 0)
                  (completed-datum-residency-tracker-ref token))))
        (if (not tracker)
            (error "datum residency report expected completed token" token))
        (datum-residency-statistics tracker)))

    (define (consent-datum-residency-tracking-release! token)
      "Release the completed datum-residency TOKEN and its retained counters."
      #((parameters
         (token (type exact-non-negative-integer)
          (description "Completed retained census token.")))
        (returns (type boolean)
         (description "#t after the matching retained census is released."))
        (effects state-read state-write error))
      (let loop ((rest completed-datum-residency-trackers) (kept '()))
        (cond
         ((null? rest)
          (error "datum residency release expected completed token" token))
         ((and (integer? token)
               (exact? token)
               (>= token 0)
               (= token (caar rest)))
          (let ((tracker (cdar rest)))
            (vector-fill! (vector-ref tracker 2) #f)
            (vector-set! tracker 2 (vector)))
          (set! completed-datum-residency-trackers
                (append (reverse kept) (cdr rest)))
          #t)
         (else (loop (cdr rest) (cons (car rest) kept))))))

    ;; A heap owns object-id allocation, cold ordinal sidecars, and the future
    ;; mutation barrier.  Object headers retain only the heap reference and
    ;; ordinal needed to derive heap-level identity and ownership metadata.
    (define-record-type <consent-datum-heap>
      (make-datum-heap-record
       id generation owner next-id mutation-hook frozen? image-members
       revision-sidecar traversal-sidecar map-sidecar source-sidecar
       construction-count)
      consent-datum-heap?
      (id consent-datum-heap-id)
      (generation consent-datum-heap-generation)
      (owner consent-datum-heap-owner raw-set-datum-heap-owner!)
      (next-id datum-heap-next-id set-datum-heap-next-id!)
      (mutation-hook datum-heap-mutation-hook
                     set-datum-heap-mutation-hook!)
      (frozen? consent-datum-heap-frozen? set-datum-heap-frozen!)
      (image-members datum-heap-image-members
                     set-datum-heap-image-members!)
      (revision-sidecar datum-heap-revision-sidecar
                        set-datum-heap-revision-sidecar!)
      (traversal-sidecar datum-heap-traversal-sidecar
                         set-datum-heap-traversal-sidecar!)
      (map-sidecar datum-heap-map-sidecar set-datum-heap-map-sidecar!)
      (source-sidecar datum-heap-source-sidecar
                      set-datum-heap-source-sidecar!)
      (construction-count datum-heap-construction-count
                          set-datum-heap-construction-count!))

    ;; Sidecars are absent until a cold property is first written.  Their
    ;; direct ordinal indexing preserves O(1) access without placing an empty
    ;; slot in every ordinary object.
    (define-record-type <consent-datum-sidecar>
      (make-datum-sidecar-record storage count residency-category)
      datum-sidecar?
      (storage datum-sidecar-storage set-datum-sidecar-storage!)
      (count datum-sidecar-count set-datum-sidecar-count!)
      (residency-category datum-sidecar-residency-category))

    ;; Two-level pages keep a late cold property from allocating one empty
    ;; slot for every earlier object in the heap. Division by this fixed power
    ;; of two is exact on every supported portable host.  Slot zero records
    ;; the number of live entries so each page remains one allocation.
    (define datum-sidecar-page-size 256)

    ;; Pairs keep their two semantic fields inline.  The other public kinds
    ;; retain one private indexed payload appropriate to their operation
    ;; contract.  Private runtime slots carry their kind because their kinds
    ;; are open-ended; public compound kinds are derived from record type.
    (define-record-type <consent-datum-pair>
      (make-datum-pair-record heap id head tail)
      datum-pair-record?
      (heap datum-pair-heap)
      (id datum-pair-id)
      (head datum-pair-head raw-set-datum-pair-head!)
      (tail datum-pair-tail raw-set-datum-pair-tail!))

    ;; Strings keep one private character vector behind checked accessors.
    (define-record-type <consent-datum-string>
      (make-datum-string-record heap id storage)
      datum-string-record?
      (heap datum-string-heap)
      (id datum-string-id)
      (storage datum-string-storage))

    ;; Vectors keep one private language-value vector behind checked accessors.
    (define-record-type <consent-datum-vector>
      (make-datum-vector-record heap id storage)
      datum-vector-record?
      (heap datum-vector-heap)
      (id datum-vector-id)
      (storage datum-vector-storage))

    ;; Bytevectors keep one private host bytevector behind checked accessors.
    (define-record-type <consent-datum-bytevector>
      (make-datum-bytevector-record heap id storage)
      datum-bytevector-record?
      (heap datum-bytevector-heap)
      (id datum-bytevector-id)
      (storage datum-bytevector-storage))

    ;; Open-ended private runtime slots retain an explicit internal kind.
    (define-record-type <consent-datum-internal>
      (make-datum-internal-record heap id kind storage revision)
      datum-internal-record?
      (heap datum-internal-heap)
      (id datum-internal-id)
      (kind datum-internal-kind)
      (storage datum-internal-storage)
      ;; Private runtime objects are allocation-heavy and short-lived. Keeping
      ;; their hot revision with the record lets host collection reclaim it;
      ;; a heap ordinal sidecar would retain pages after those objects die.
      (revision datum-internal-revision set-datum-internal-revision!))

    (define (consent-datum-object? value)
      "Report whether VALUE is any owned compound or private slot object."
      #((parameters (value . "Candidate value."))
        (returns (type boolean)
         (description "Whether VALUE has Consent-owned datum identity."))
        (effects pure))
      (or (datum-pair-record? value)
          (datum-string-record? value)
          (datum-vector-record? value)
          (datum-bytevector-record? value)
          (datum-internal-record? value)))

    (define (datum-object-heap object)
      "Return owned OBJECT's allocating heap."
      (cond
       ((datum-pair-record? object) (datum-pair-heap object))
       ((datum-string-record? object) (datum-string-heap object))
       ((datum-vector-record? object) (datum-vector-heap object))
       ((datum-bytevector-record? object) (datum-bytevector-heap object))
       ((datum-internal-record? object) (datum-internal-heap object))
       (else (error "datum-object-heap: expected owned object" object))))

    (define (consent-datum-object-id object)
      "Return owned OBJECT's stable heap-local ordinal."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to identify.")))
        (returns (type exact-non-negative-integer)
         (description "Stable heap-local object ordinal."))
        (effects error))
      (cond
       ((datum-pair-record? object) (datum-pair-id object))
       ((datum-string-record? object) (datum-string-id object))
       ((datum-vector-record? object) (datum-vector-id object))
       ((datum-bytevector-record? object) (datum-bytevector-id object))
       ((datum-internal-record? object) (datum-internal-id object))
       (else
        (error "consent-datum-object-id: expected owned object" object))))

    (define (consent-datum-object-kind object)
      "Return owned OBJECT's kind."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to classify.")))
        (returns (type symbol) (description "Owned representation kind."))
        (effects error))
      (cond
       ((datum-pair-record? object) 'pair)
       ((datum-string-record? object) 'string)
       ((datum-vector-record? object) 'vector)
       ((datum-bytevector-record? object) 'bytevector)
       ((datum-internal-record? object) (datum-internal-kind object))
       (else
        (error "consent-datum-object-kind: expected owned object" object))))

    (define (datum-object-storage object)
      "Return non-pair owned OBJECT's private indexed payload."
      (cond
       ((datum-string-record? object) (datum-string-storage object))
       ((datum-vector-record? object) (datum-vector-storage object))
       ((datum-bytevector-record? object) (datum-bytevector-storage object))
       ((datum-internal-record? object) (datum-internal-storage object))
       (else
        (error "datum-object-storage: pair payload is inline" object))))

    (define (consent-datum-object-heap-id object)
      "Return owned OBJECT's allocating heap identifier."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to identify.")))
        (returns (type exact-non-negative-integer)
         (description "Process-local allocating heap identifier."))
        (effects error))
      (consent-datum-heap-id (datum-object-heap object)))

    (define (consent-datum-object-generation object)
      "Return owned OBJECT's heap generation."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Current owning-heap generation."))
        (effects error))
      (consent-datum-heap-generation (datum-object-heap object)))

    (define (consent-datum-object-owner object)
      "Return owned OBJECT's heap-level owner metadata."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to inspect.")))
        (returns . "Current opaque heap owner metadata.")
        (effects error))
      (consent-datum-heap-owner (datum-object-heap object)))

    (define (make-datum-sidecar residency-category)
      "Return one lazily grown ordinal sidecar."
      (make-datum-sidecar-record (vector) 0 residency-category))

    (define (datum-sidecar-ref sidecar ordinal default)
      "Return SIDECAR's ORDINAL value or DEFAULT when absent."
      (if sidecar
          (let* ((page-index (quotient ordinal datum-sidecar-page-size))
                 (offset (modulo ordinal datum-sidecar-page-size))
                 (pages (datum-sidecar-storage sidecar)))
            (if (< page-index (vector-length pages))
                (let ((page (vector-ref pages page-index)))
                  (if page
                      (let ((value (vector-ref page (+ offset 1))))
                        (if value value default))
                      default))
                default))
          default))

    (define (datum-sidecar-next-capacity current required)
      "Return geometric sidecar capacity covering REQUIRED slots."
      (let loop ((capacity (if (= current 0) 8 current)))
        (if (>= capacity required)
            capacity
            (loop (* capacity 2)))))

    (define (datum-sidecar-set! sidecar ordinal value)
      "Set SIDECAR at ORDINAL to VALUE through a lazily allocated page."
      (let* ((page-index (quotient ordinal datum-sidecar-page-size))
             (offset (modulo ordinal datum-sidecar-page-size))
             (pages (datum-sidecar-storage sidecar))
             (length (vector-length pages)))
        (if (and value (>= page-index length))
            (let* ((required (+ page-index 1))
                   (capacity
                    (datum-sidecar-next-capacity length required))
                   (larger (make-vector capacity #f)))
              (vector-copy! larger 0 pages)
              (set-datum-sidecar-storage! sidecar larger)))
        (let ((current-pages (datum-sidecar-storage sidecar)))
          (if (< page-index (vector-length current-pages))
              (let ((page (vector-ref current-pages page-index)))
                (if (and value (not page))
                    (begin
                      (set! page
                            (make-vector (+ datum-sidecar-page-size 1) #f))
                      (vector-set! page 0 0)
                      (vector-set! current-pages page-index page)
                      (datum-residency-open!
                       (datum-sidecar-residency-category sidecar) 1)))
                (if page
                    (let* ((slot (+ offset 1))
                           (old (vector-ref page slot)))
                      (cond
                       ((and old (not value))
                        (set-datum-sidecar-count!
                         sidecar (- (datum-sidecar-count sidecar) 1))
                        (vector-set! page 0 (- (vector-ref page 0) 1)))
                       ((and (not old) value)
                        (set-datum-sidecar-count!
                         sidecar (+ (datum-sidecar-count sidecar) 1))
                        (vector-set! page 0 (+ (vector-ref page 0) 1))))
                      (vector-set! page slot value)
                      (if (= (vector-ref page 0) 0)
                          (begin
                            (vector-set! current-pages page-index #f)
                            (datum-residency-close!
                             (datum-sidecar-residency-category sidecar)
                             1))))))))))

    (define (datum-sidecar-release! sidecar)
      "Clear SIDECAR's roots and abandon all of its allocated pages."
      (let ((pages (datum-sidecar-storage sidecar)))
        (let loop ((index 0))
          (if (< index (vector-length pages))
              (begin
                (let ((page (vector-ref pages index)))
                  (if page
                      (begin
                        (vector-fill! page #f)
                        (datum-residency-close!
                         (datum-sidecar-residency-category sidecar) 1))))
                (loop (+ index 1)))))
        (vector-fill! pages #f)
        (set-datum-sidecar-storage! sidecar (vector))
        (set-datum-sidecar-count! sidecar 0))
      sidecar)

    (define (heap-sidecar-set!
             heap current install! category object value)
      "Set OBJECT's VALUE in a lazily installed HEAP sidecar."
      (let ((sidecar (current heap)))
        (if (and (not sidecar) value)
            (begin
              (set! sidecar (make-datum-sidecar category))
              (install! heap sidecar)))
        (if sidecar
            (begin
              (datum-sidecar-set!
               sidecar (consent-datum-object-id object) value)
              (if (= (datum-sidecar-count sidecar) 0)
                  (install! heap #f))))))

    (define (consent-datum-object-revision object)
      "Return owned OBJECT's mutation revision."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Visible mutation count, initially zero."))
        (effects state-read error))
      (let ((heap (datum-object-heap object)))
        (if (datum-internal-record? object)
            (datum-internal-revision object)
            (datum-sidecar-ref
             (datum-heap-revision-sidecar heap)
             (consent-datum-object-id object)
             0))))

    (define (set-datum-object-revision! object revision)
      "Set owned OBJECT's mutation REVISION."
      (if (datum-internal-record? object)
          (set-datum-internal-revision! object revision)
          (heap-sidecar-set!
           (datum-object-heap object)
           datum-heap-revision-sidecar
           set-datum-heap-revision-sidecar!
           datum-residency-revision-sidecar-page
           object
           revision)))

    (define (consent-datum-object-mutable? object)
      "Report whether owned OBJECT permits visible slot mutation."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to inspect.")))
        (returns (type boolean)
         (description "Whether OBJECT's heap is still mutable."))
        (effects state-read error))
      (not (consent-datum-heap-frozen? (datum-object-heap object))))

    (define (consent-datum-object-traversal object)
      "Return owned OBJECT's optional traversal metadata."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to inspect.")))
        (returns . "Opaque traversal metadata, or #f when absent.")
        (effects state-read error))
      (let ((heap (datum-object-heap object)))
        (datum-sidecar-ref
         (datum-heap-traversal-sidecar heap)
         (consent-datum-object-id object)
         #f)))

    (define (raw-set-datum-object-traversal! object metadata)
      "Set owned OBJECT's optional traversal METADATA sidecar."
      (heap-sidecar-set!
       (datum-object-heap object)
       datum-heap-traversal-sidecar
       set-datum-heap-traversal-sidecar!
       datum-residency-traversal-sidecar-page
       object
       metadata))

    (define (datum-object-map-entry object)
      "Return owned OBJECT's current intrusive-map entry."
      (let ((heap (datum-object-heap object)))
        (datum-sidecar-ref
         (datum-heap-map-sidecar heap)
         (consent-datum-object-id object)
         #f)))

    (define (raw-set-datum-object-map-entry! object entry)
      "Set owned OBJECT's intrusive-map ENTRY sidecar."
      (heap-sidecar-set!
       (datum-object-heap object)
       datum-heap-map-sidecar
       set-datum-heap-map-sidecar!
       datum-residency-map-sidecar-page
       object
       entry))

    (define (consent-datum-object-source-metadata object)
      "Return owned OBJECT's optional source provenance."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to inspect.")))
        (returns . "Opaque source provenance, or #f when absent.")
        (effects state-read error))
      (let ((heap (datum-object-heap object)))
        (datum-sidecar-ref
         (datum-heap-source-sidecar heap)
         (consent-datum-object-id object)
         #f)))

    (define (raw-set-datum-object-source-metadata! object metadata)
      "Set owned OBJECT's optional source METADATA sidecar."
      (heap-sidecar-set!
       (datum-object-heap object)
       datum-heap-source-sidecar
       set-datum-heap-source-sidecar!
       datum-residency-source-sidecar-page
       object
       metadata))

    (define (consent-make-datum-heap)
      "Return a fresh portable compound datum heap."
      #((parameters)
        (returns (type datum-heap)
         (description "Fresh heap with its own object-id domain."))
        (effects allocation state-write))
      (let ((id next-datum-heap-id))
        (set! next-datum-heap-id (+ id 1))
        ;; A false hook is the explicit no-observer state. Procedure identity
        ;; is not a portable discriminator for recognizing a no-op default.
        (make-datum-heap-record
         id 0 id 0 #f #f #f #f #f #f #f 0)))

    ;; Context-free internal callers use this root heap. Evaluation contexts
    ;; allocate their own heap instead of sharing it.
    (define consent-default-datum-heap (consent-make-datum-heap))

    (define (consent-datum-heap-owner-set! heap owner)
      "Set future branch OWNER metadata on HEAP and return HEAP."
      #((parameters
         (heap (type datum-heap) (description "Heap to annotate."))
         (owner . "Opaque branch or delta owner metadata."))
        (returns (type datum-heap) (description "Updated HEAP."))
        (effects state-write error))
      (if (not (consent-datum-heap? heap))
          (error "consent-datum-heap-owner-set!: expected heap" heap))
      (if (consent-datum-heap-frozen? heap)
          (error "consent-datum-heap-owner-set!: heap is frozen" heap))
      (raw-set-datum-heap-owner! heap owner)
      heap)

    (define (consent-datum-heap-mutation-hook-set! heap hook)
      "Install HEAP's narrow mutation HOOK and return HEAP."
      #((parameters
         (heap (type datum-heap) (description "Heap to configure."))
         (hook (type (or procedure boolean))
          (description
           ("Procedure receiving heap, object, operation, slot, old,"
             "and new before each visible mutation, or #f to clear it."))))
        (returns (type datum-heap) (description "Updated HEAP."))
        (effects state-write error))
      (if (not (consent-datum-heap? heap))
          (error
           "consent-datum-heap-mutation-hook-set!: expected heap"
           heap))
      (if (consent-datum-heap-frozen? heap)
          (error
           "consent-datum-heap-mutation-hook-set!: heap is frozen"
           heap))
      (if (and hook (not (procedure? hook)))
          (error
           "consent-datum-heap-mutation-hook-set!: expected procedure or #f"
           hook))
      (set-datum-heap-mutation-hook! heap hook)
      heap)

    (define (consent-datum-object-traversal-set! object metadata)
      "Set private traversal METADATA on owned OBJECT and return OBJECT."
      #((parameters
         (object (type compound-datum)
          (description "Owned object to annotate."))
         (metadata . "Opaque writer, collector, or checkpoint metadata."))
        (returns (type compound-datum) (description "Updated OBJECT."))
        (effects state-write error))
      (if (not (consent-datum-object? object))
          (error
           "consent-datum-object-traversal-set!: expected owned object"
           object))
      (raw-set-datum-object-traversal! object metadata)
      object)

    (define (consent-datum-object-source-metadata-set! object metadata)
      "Replace owned OBJECT's current source METADATA and return OBJECT."
      #((parameters
         (object (type compound-datum)
          (description "Owned object whose provenance is updated."))
         (metadata
          . "Opaque current source metadata, or #f when absent."))
        (returns (type compound-datum)
         (description "The original OBJECT."))
        (effects state-write error))
      (if (not (consent-datum-object? object))
          (error
           "consent-datum-object-source-metadata-set!: expected owned object"
           object))
      (if (consent-datum-heap-frozen? (datum-object-heap object))
          (error
           "consent-datum-object-source-metadata-set!: heap is frozen"
           object))
      (raw-set-datum-object-source-metadata! object metadata)
      object)

    (define (allocate-datum-id heap)
      "Reserve and return one stable object ordinal in mutable HEAP."
      (if (not (consent-datum-heap? heap))
          (error "owned datum allocation expected heap" heap))
      (if (consent-datum-heap-frozen? heap)
          (error "owned datum allocation expected mutable heap" heap))
      (let ((id (datum-heap-next-id heap)))
        (set-datum-heap-next-id! heap (+ id 1))
        id))

    (define (allocate-datum-pair heap head tail)
      "Allocate one inline owned pair in HEAP."
      (let ((pair
             (make-datum-pair-record
              heap (allocate-datum-id heap) head tail)))
        (datum-residency-open! datum-residency-owned-pair 1)
        pair))

    (define (allocate-datum-object heap kind storage)
      "Allocate one KIND object backed privately by STORAGE in HEAP."
      (let* ((id (allocate-datum-id heap))
             (object
              (case kind
                ((string) (make-datum-string-record heap id storage))
                ((vector) (make-datum-vector-record heap id storage))
                ((bytevector)
                 (make-datum-bytevector-record heap id storage))
                (else
                 (make-datum-internal-record heap id kind storage 0)))))
        (datum-residency-open!
         (case kind
           ((string) datum-residency-owned-string)
           ((vector) datum-residency-owned-vector)
           ((bytevector) datum-residency-owned-bytevector)
           (else datum-residency-owned-internal))
         1)
        object))

    ;; Construction scopes are one-shot capabilities for trusted runtime
    ;; producers such as the reader. A scope-local ordinal sidecar names each
    ;; unpublished shell's active token, so construction fills cannot be
    ;; confused with language-visible mutation or retained heap metadata.
    (define datum-construction-uninitialized
      (vector 'consent-datum-construction-uninitialized))

    ;; Construction marker contents must not be a host vector: exposing the
    ;; fill bitmap as ordinary traversal metadata would let a capability
    ;; callback forge shell completeness.
    (define-record-type <datum-construction-marker>
      (make-datum-construction-marker token states remaining object next)
      datum-construction-marker?
      (token datum-construction-marker-token)
      (states datum-construction-marker-states)
      (remaining datum-construction-marker-remaining
                 set-datum-construction-marker-remaining!)
      (object datum-construction-marker-object)
      (next datum-construction-marker-next))

    (define (datum-object-slot-count object)
      "Return owned OBJECT's construction-visible slot count."
      (case (consent-datum-object-kind object)
        ((pair) 2)
        ((bytevector)
         (bytevector-length (datum-object-storage object)))
        (else (vector-length (datum-object-storage object)))))

    (define (raw-datum-object-slot-ref object index)
      "Return owned OBJECT's raw construction slot at INDEX."
      (case (consent-datum-object-kind object)
        ((pair)
         (if (= index 0)
             (datum-pair-head object)
             (datum-pair-tail object)))
        ((bytevector)
         (bytevector-u8-ref (datum-object-storage object) index))
        (else (vector-ref (datum-object-storage object) index))))

    (define (raw-datum-object-slot-set! object index value)
      "Set owned OBJECT's raw construction slot at INDEX."
      (case (consent-datum-object-kind object)
        ((pair)
         (if (= index 0)
             (raw-set-datum-pair-head! object value)
             (raw-set-datum-pair-tail! object value)))
        ((bytevector)
         (bytevector-u8-set! (datum-object-storage object) index value))
        (else (vector-set! (datum-object-storage object) index value))))

    (define (consent-call-with-datum-construction heap procedure)
      "Call PROCEDURE with scoped owned-compound construction capabilities."
      "PROCEDURE receives MAKE-SHELL, FILL-SLOT!, and FIXUP-SLOT!.  The first"
      "accepts `pair', `string', `vector', or `bytevector' plus exact length;"
      "pairs require length two.  FILL-SLOT! initializes one slot exactly"
      "once. FIXUP-SLOT! may replace that slot exactly once for datum-label"
      "resolution. Normal return verifies and seals every"
      "shell without invoking HEAP's mutation hook or advancing revisions."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (procedure (type procedure)
           (description
           ("Procedure receiving private make-shell, fill-slot, and"
             "label-fixup capabilities."))))
        (returns (type any)
         (description "The callback result after every shell is sealed."))
        (effects allocation state-write error))
      (if (not (consent-datum-heap? heap))
          (error
           "consent-call-with-datum-construction: expected heap"
           heap))
      (if (not (procedure? procedure))
          (error
           "consent-call-with-datum-construction: expected procedure"
           procedure))
      (let ((token (vector 'consent-datum-construction-token))
            (objects #f)
            (first-id (datum-heap-next-id heap))
            (markers (vector))
            (state 'new))
        (define (active?)
          (eq? state 'active))

        (define (check-active operation)
          (if (not (active?))
              (error operation "construction scope is not active")))

        (define (construction-marker-set! object marker)
          "Associate OBJECT's scope-local ordinal with MARKER."
          (let* ((offset
                  (- (consent-datum-object-id object) first-id))
                 (length (vector-length markers)))
            (if (>= offset length)
                (let* ((required (+ offset 1))
                       (capacity
                        (datum-sidecar-next-capacity length required))
                       (larger (make-vector capacity #f)))
                  (datum-residency-open!
                   datum-residency-construction-index-slot capacity)
                  (vector-copy! larger 0 markers)
                  (if (> length 0)
                      (begin
                        (vector-fill! markers #f)
                        (datum-residency-close!
                         datum-residency-construction-index-slot length)))
                  (set! markers larger)))
            (vector-set! markers offset marker)))

        (define (release-construction-index!)
          "Clear and release the scope-local marker index."
          (let ((length (vector-length markers)))
            (if (> length 0)
                (begin
                  (vector-fill! markers #f)
                  (datum-residency-close!
                   datum-residency-construction-index-slot length)))
            (set! markers (vector))))

        (define (make-shell kind length)
          (check-active "datum construction make-shell:")
          (if (not (and (integer? length) (exact? length) (>= length 0)))
              (error
               "datum construction make-shell: expected exact length"
               length))
          (if (and (eq? kind 'pair) (not (= length 2)))
              (error
               "datum construction make-shell: pair length must be two"
               length))
          (if (not (or (eq? kind 'pair)
                       (eq? kind 'string)
                       (eq? kind 'vector)
                       (eq? kind 'bytevector)))
              (error
               "datum construction make-shell: unsupported kind"
               kind))
          ;; Pairs allocate one inline record. Bytevectors allocate their final
          ;; payload immediately; other indexed kinds allocate one payload.
          (let* ((bytevector? (eq? kind 'bytevector))
                 (object
                  (if (eq? kind 'pair)
                      (allocate-datum-pair
                       heap
                       datum-construction-uninitialized
                       datum-construction-uninitialized)
                      (allocate-datum-object
                       heap
                       kind
                       (if bytevector?
                           (make-bytevector length 0)
                           (make-vector
                            length datum-construction-uninitialized)))))
                 ;; A slot state is zero before fill, one after fill, and two
                 ;; after its one permitted datum-label fixup.
                 (marker
                  (make-datum-construction-marker
                   token
                   (make-bytevector length 0)
                   length
                   object
                   objects)))
            (construction-marker-set! object marker)
            (datum-residency-open! datum-residency-construction-marker 1)
            ;; Link through the opaque marker instead of allocating one host
            ;; cons cell per compound merely to close the construction scope.
            (set! objects marker)
            object))

        (define (construction-marker object)
          "Return OBJECT's marker for this scope, or #f when it has none."
          (and (consent-datum-object? object)
               (eq? (datum-object-heap object) heap)
               (let ((offset
                      (- (consent-datum-object-id object) first-id)))
                 (and (>= offset 0)
                      (< offset (vector-length markers))
                      (let ((marker (vector-ref markers offset)))
                        (and (datum-construction-marker? marker)
                             (eq? (datum-construction-marker-token marker)
                                  token)
                             marker))))))

        (define (store-slot! operation expected-state next-state
                             object index value)
          "Store one construction slot under the requested state transition."
          (check-active operation)
          (let ((marker (construction-marker object)))
            (if (not marker)
                (error
                 operation
                 "shell is outside scope"
                 object))
            (let ((length (datum-object-slot-count object)))
              (if (not (and (integer? index)
                            (exact? index)
                            (>= index 0)
                            (< index length)))
                  (error
                   operation
                   "index out of range"
                   index))
              (let* ((states (datum-construction-marker-states marker))
                     (state (bytevector-u8-ref states index)))
                (if (not (= state expected-state))
                   (error
                    operation
                    (if (= expected-state 0)
                        "slot was already filled"
                        "slot was not eligible for one fixup")
                    object
                    index)))
              (case (consent-datum-object-kind object)
                ((string)
                 (if (not (char? value))
                     (error
                      operation
                      "expected host character"
                      value)))
                ((bytevector)
                 (if (not (and (integer? value)
                               (exact? value)
                               (<= 0 value)
                               (<= value 255)))
                     (error
                      operation
                      "expected byte"
                      value))))
              (raw-datum-object-slot-set! object index value)
              (bytevector-u8-set!
               (datum-construction-marker-states marker) index next-state)
              (if (= expected-state 0)
                  (set-datum-construction-marker-remaining!
                   marker
                   (- (datum-construction-marker-remaining marker) 1)))
              object)))

        (define (fill-slot! object index value)
          "Initialize one previously unfilled construction slot."
          (store-slot!
           "datum construction fill-slot!:"
           0 1 object index value))

        (define (fixup-slot! object index value)
          "Replace one filled slot exactly once during datum-label fixup."
          (store-slot!
           "datum construction fixup-slot!:"
           1 2 object index value))

        (define (shell-complete? object)
          "Report whether every slot in construction shell OBJECT was filled."
          (let ((marker (construction-marker object)))
            (and marker
                 (= (datum-construction-marker-remaining marker) 0))))

        (define (seal! object)
          "Seal one completed shell without a visible mutation event."
          (construction-marker-set! object #f)
          (datum-residency-close! datum-residency-construction-marker 1))

        (define (sanitize-abandoned! object)
          "Make an escaped abandoned shell a valid inert owned datum."
          (let ((kind (consent-datum-object-kind object)))
            (if (not (eq? kind 'bytevector))
                (let ((replacement (if (eq? kind 'string) #\null #f)))
                  (let loop ((index 0))
                    (if (< index (datum-object-slot-count object))
                        (begin
                          (if (eq? (raw-datum-object-slot-ref object index)
                                   datum-construction-uninitialized)
                              (raw-datum-object-slot-set!
                               object index replacement))
                          (loop (+ index 1)))))))
            (construction-marker-set! object #f))
          (datum-residency-close! datum-residency-construction-marker 1))

        (define (sanitize-all!)
          "Sanitize and close every shell after an abandoned construction."
          (let loop ((rest objects))
            (if rest
                (begin
                  (sanitize-abandoned!
                   (datum-construction-marker-object rest))
                  (loop (datum-construction-marker-next rest))))))

        (define (close! completed?)
          "Seal completed shells or invalidate an abandoned scope."
          (if (or (active?) (eq? state 'complete))
              (begin
                ;; Fill capabilities become unusable before any verification
                ;; can raise, including through an escaped continuation.
                (set! state 'closing)
                (if completed?
                    (let verify ((rest objects))
                      (cond
                       ((not rest)
                        (let seal ((rest objects))
                          (if rest
                              (begin
                                (seal!
                                 (datum-construction-marker-object rest))
                                (seal
                                 (datum-construction-marker-next rest)))))
                        (set! objects #f)
                        (release-construction-index!)
                        (set! state 'closed))
                       ((shell-complete?
                         (datum-construction-marker-object rest))
                        (verify (datum-construction-marker-next rest)))
                       (else
                        (let* ((object
                                (datum-construction-marker-object rest))
                               (marker (construction-marker object))
                               (remaining
                                (if marker
                                    (datum-construction-marker-remaining
                                     marker)
                                    'invalid-marker)))
                          (sanitize-all!)
                          (set! objects #f)
                          (release-construction-index!)
                          (set! state 'closed)
                          (error
                           "datum construction ended with unfilled slots"
                           object
                           remaining)))))
                    (begin
                      (sanitize-all!)
                      (set! objects #f)
                      (release-construction-index!)
                      (set! state 'closed))))))

        ;; Treat the scope as one-shot.  A continuation that leaves during
        ;; construction closes it; re-entry then fails instead of reviving raw
        ;; fill authority after objects could have escaped.
        (dynamic-wind
         (lambda ()
           (if (not (eq? state 'new))
               (error
                "datum construction continuation cannot be re-entered"))
           (set! state 'active)
           (set-datum-heap-construction-count!
            heap (+ (datum-heap-construction-count heap) 1)))
         (lambda ()
           (let ((result (procedure make-shell fill-slot! fixup-slot!)))
             (set! state 'complete)
             result))
         (lambda ()
           (set-datum-heap-construction-count!
            heap (- (datum-heap-construction-count heap) 1))
           (close! (eq? state 'complete))))))

    (define (object-kind? value kind)
      "Report whether VALUE is an owned object of KIND."
      (case kind
        ((pair) (datum-pair-record? value))
        ((string) (datum-string-record? value))
        ((vector) (datum-vector-record? value))
        ((bytevector) (datum-bytevector-record? value))
        (else
         (and (datum-internal-record? value)
              (eq? (datum-internal-kind value) kind)))))

    (define (consent-datum-same? left right)
      "Report whether LEFT and RIGHT denote the same owned object identity."
      #((parameters
         (left . "First candidate object.")
         (right . "Second candidate object."))
        (returns (type boolean)
         (description "Whether both candidates have one owned identity."))
        (effects pure))
      (cond
       ((datum-pair-record? left)
        (and (datum-pair-record? right)
             (= (consent-datum-heap-id (datum-pair-heap left))
                (consent-datum-heap-id (datum-pair-heap right)))
             (= (datum-pair-id left) (datum-pair-id right))))
       ((datum-string-record? left)
        (and (datum-string-record? right)
             (= (consent-datum-heap-id (datum-string-heap left))
                (consent-datum-heap-id (datum-string-heap right)))
             (= (datum-string-id left) (datum-string-id right))))
       ((datum-vector-record? left)
        (and (datum-vector-record? right)
             (= (consent-datum-heap-id (datum-vector-heap left))
                (consent-datum-heap-id (datum-vector-heap right)))
             (= (datum-vector-id left) (datum-vector-id right))))
       ((datum-bytevector-record? left)
        (and (datum-bytevector-record? right)
             (= (consent-datum-heap-id (datum-bytevector-heap left))
                (consent-datum-heap-id (datum-bytevector-heap right)))
             (= (datum-bytevector-id left) (datum-bytevector-id right))))
       ((datum-internal-record? left)
        (and (datum-internal-record? right)
             (= (consent-datum-heap-id (datum-internal-heap left))
                (consent-datum-heap-id (datum-internal-heap right)))
             (= (datum-internal-id left) (datum-internal-id right))))
       (else #f)))

    (define (consent-datum-make-internal-slots heap kind values)
      "Allocate private KIND slots initialized from host list VALUES."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (kind (type symbol)
          (description "Private runtime state kind."))
         (values (type list)
          (description "Initial slot values in private host-list form.")))
        (returns (type compound-datum)
         (description "Fresh private slot object."))
        (effects allocation error))
      (if (not (symbol? kind))
          (error
           "consent-datum-make-internal-slots: expected host kind symbol"
           kind))
      (allocate-datum-object heap kind (list->vector values)))

    (define (consent-datum-internal-slot-ref object index)
      "Return private runtime OBJECT's slot at INDEX."
      #((parameters
         (object (type compound-datum)
          (description "Private runtime slot object."))
         (index (type exact-non-negative-integer)
          (description "Zero-based slot index.")))
        (returns . "Stored slot value.")
        (effects error))
      (if (not (consent-datum-object? object))
          (error
           "consent-datum-internal-slot-ref: expected owned object"
           object))
      (vector-ref (datum-object-storage object) index))

    (define (consent-datum-internal-slot-set!
             heap object operation index value)
      "Set private runtime OBJECT's INDEX through HEAP as OPERATION."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (object (type compound-datum)
          (description "Private runtime slot object."))
         (operation (type symbol)
          (description "Mutation observer operation tag."))
         (index (type exact-non-negative-integer)
          (description "Zero-based slot index."))
         (value . "Replacement slot value."))
        (returns . "The unspecified value.")
        (effects state-write error))
      (if (not (consent-datum-object? object))
          (error
           "consent-datum-internal-slot-set!: expected owned object"
           object))
      (if (not (eq? heap (datum-object-heap object)))
          (error
           "consent-datum-internal-slot-set!: object belongs to other heap"
           object))
      (vector-storage-set! heap object operation index value))

    (define (check-object heap object kind description)
      "Validate HEAP, OBJECT, and KIND for DESCRIPTION."
      (if (not (consent-datum-heap? heap))
          (error (string-append description ": expected heap") heap))
      (if (not (object-kind? object kind))
          (error (string-append description ": unexpected datum kind")
                 object))
      (if (not (eq? heap (datum-object-heap object)))
          (error (string-append description ": object belongs to other heap")
                 object))
      object)

    (define (prepare-mutation! heap object operation slot old new)
      "Validate and observe one mutation before private storage changes."
      (if (not (consent-datum-object-mutable? object))
          (error "attempt to mutate an immutable compound datum" object))
      (let ((hook (datum-heap-mutation-hook heap)))
        (if hook
            (hook heap object operation slot old new))))

    (define (complete-mutation! object)
      "Advance OBJECT's revision after one private storage mutation."
      ;; Re-read after the hook and write so a reentrant mutation cannot have
      ;; its revision overwritten by an outer operation's stale snapshot.
      (set-datum-object-revision!
       object
       (+ 1 (consent-datum-object-revision object))))

    (define (vector-storage-set! heap object operation index value)
      "Set validated vector-backed OBJECT storage through HEAP."
      (let* ((storage (datum-object-storage object))
             (old (vector-ref storage index)))
        (prepare-mutation! heap object operation index old value)
        (vector-set! storage index value)
        (complete-mutation! object)))

    (define (bytevector-storage-set! heap object operation index value)
      "Set validated bytevector-backed OBJECT storage through HEAP."
      (let* ((storage (datum-object-storage object))
             (old (bytevector-u8-ref storage index)))
        (prepare-mutation! heap object operation index old value)
        (bytevector-u8-set! storage index value)
        (complete-mutation! object)))

    (define (consent-datum-pair? value)
      "Report whether VALUE is an owned pair."
      #((parameters (value . "Candidate value."))
        (returns (type boolean) (description "Whether VALUE is a pair."))
        (effects pure))
      (object-kind? value 'pair))

    (define (make-pair-placeholder heap)
      "Allocate an uninitialized pair used while importing cyclic graphs."
      (allocate-datum-pair heap #f #f))

    (define (initialize-pair! pair head tail)
      "Initialize fresh PAIR without reporting construction as mutation."
      (raw-set-datum-pair-head! pair head)
      (raw-set-datum-pair-tail! pair tail)
      pair)

    (define (consent-datum-cons heap head tail)
      "Return a fresh owned pair in HEAP with HEAD and TAIL."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (head . "Initial car value.")
         (tail . "Initial cdr value."))
        (returns (type pair) (description "Fresh mutable owned pair."))
        (effects allocation error))
      (initialize-pair! (make-pair-placeholder heap) head tail))

    (define (consent-datum-car pair)
      "Return owned PAIR's car."
      #((parameters (pair (type pair) (description "Pair to inspect.")))
        (returns (type any) (description "Stored car value."))
        (effects error))
      (if (not (consent-datum-pair? pair))
          (error "consent-datum-car: expected owned pair" pair))
      (consent-datum-car-trusted pair))

    (define (consent-datum-car-trusted pair)
      "Return proven owned PAIR's car without repeating kind validation."
      #((parameters
         (pair (type pair)
          (description "Owned pair already validated by the caller.")))
        (returns (type any) (description "Stored car value."))
        (effects error))
      (datum-pair-head pair))

    (define (consent-datum-cdr pair)
      "Return owned PAIR's cdr."
      #((parameters (pair (type pair) (description "Pair to inspect.")))
        (returns (type any) (description "Stored cdr value."))
        (effects error))
      (if (not (consent-datum-pair? pair))
          (error "consent-datum-cdr: expected owned pair" pair))
      (consent-datum-cdr-trusted pair))

    (define (consent-datum-cdr-trusted pair)
      "Return proven owned PAIR's cdr without repeating kind validation."
      #((parameters
         (pair (type pair)
          (description "Owned pair already validated by the caller.")))
        (returns (type any) (description "Stored cdr value."))
        (effects error))
      (datum-pair-tail pair))

    (define (pair-set! heap pair slot value operation)
      "Set PAIR's SLOT to VALUE through the mutation gateway."
      (check-object heap pair 'pair operation)
      (let ((old
             (if (= slot 0)
                 (datum-pair-head pair)
                 (datum-pair-tail pair))))
        (prepare-mutation! heap pair operation slot old value)
        (if (= slot 0)
            (raw-set-datum-pair-head! pair value)
            (raw-set-datum-pair-tail! pair value))
        (complete-mutation! pair)))

    (define (consent-datum-set-car! heap pair value)
      "Set owned PAIR's car to VALUE through HEAP."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (pair (type pair) (description "Pair to mutate."))
         (value . "Replacement car value."))
        (returns . "The unspecified value.")
        (effects state-write error))
      (pair-set! heap pair 0 value 'set-car!))

    (define (consent-datum-set-cdr! heap pair value)
      "Set owned PAIR's cdr to VALUE through HEAP."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (pair (type pair) (description "Pair to mutate."))
         (value . "Replacement cdr value."))
        (returns . "The unspecified value.")
        (effects state-write error))
      (pair-set! heap pair 1 value 'set-cdr!))

    (define (owned-list-cycle-shape value)
      "Return VALUE's Floyd-derived (mu . lambda), or false."
      (if (not (consent-datum-pair? value))
          #f
          (let detect ((slow value) (fast value))
            (let ((fast-one (consent-datum-cdr-trusted fast)))
              (if (not (consent-datum-pair? fast-one))
                  #f
                  (let ((slow-one (consent-datum-cdr-trusted slow))
                        (fast-two
                         (consent-datum-cdr-trusted fast-one)))
                    (if (not (consent-datum-pair? fast-two))
                        #f
                        (if (consent-datum-same? slow-one fast-two)
                            (let entry ((left value)
                                        (right slow-one)
                                        (mu 0))
                              (if (consent-datum-same? left right)
                                  (let period
                                      ((cursor
                                        (consent-datum-cdr-trusted left))
                                       (period-length 1))
                                    (if (consent-datum-same? cursor left)
                                        (cons mu period-length)
                                        (period
                                         (consent-datum-cdr-trusted cursor)
                                         (+ period-length 1))))
                                  (entry
                                   (consent-datum-cdr-trusted left)
                                   (consent-datum-cdr-trusted right)
                                   (+ mu 1))))
                            (detect slow-one fast-two)))))))))

    (define (copy-acyclic-pair-spine value heap)
      "Copy VALUE's acyclic pair spine into HEAP."
      (let scan ((cursor value) (reversed-cars '()) (count 0))
        (if (consent-datum-pair? cursor)
            (scan
             (consent-datum-cdr-trusted cursor)
             (cons (consent-datum-car-trusted cursor) reversed-cars)
             (+ count 1))
            (let rebuild ((cars reversed-cars) (tail cursor))
              (if (null? cars)
                  (cons tail count)
                  (rebuild
                   (cdr cars)
                   (consent-datum-cons heap (car cars) tail)))))))

    (define (copy-cyclic-pair-spine value heap shape)
      "Copy VALUE's cyclic pair spine into HEAP from Floyd SHAPE."
      (let* ((mu (car shape))
             (period-length (cdr shape))
             (count (+ mu period-length))
             (cars (make-vector count #f))
             (copies (make-vector count #f)))
        (let collect ((cursor value) (index 0))
          (if (< index count)
              (begin
                (vector-set!
                 cars index (consent-datum-car-trusted cursor))
                (collect
                 (consent-datum-cdr-trusted cursor) (+ index 1)))))
        ;; Allocate every identity before installing edges. These private
        ;; initializers do not emit mutation hooks or increment revisions.
        (let allocate ((index 0))
          (if (< index count)
              (begin
                (vector-set!
                 copies index (make-pair-placeholder heap))
                (allocate (+ index 1)))))
        (let initialize ((index 0))
          (if (< index count)
              (begin
                (initialize-pair!
                 (vector-ref copies index)
                 (vector-ref cars index)
                 (vector-ref
                  copies
                  (if (= index (- count 1)) mu (+ index 1))))
                (initialize (+ index 1)))))
        (cons (vector-ref copies 0) count)))

    (define (consent-datum-list-copy heap value)
      "Return VALUE's shallow copied pair spine and allocation count."
      #((parameters
         (heap (type datum-heap) (description "Destination heap."))
         (value (type any)
          (description "Value whose cdr-linked spine is copied when present.")))
        (returns (type pair)
         (description
          "Private result pair containing copy and pair count."))
        (effects allocation error))
      (if (not (consent-datum-heap? heap))
          (error "consent-datum-list-copy: expected heap" heap))
      (let ((shape (owned-list-cycle-shape value)))
        (if shape
            (copy-cyclic-pair-spine value heap shape)
            (copy-acyclic-pair-spine value heap))))

    (define (consent-datum-string? value)
      "Report whether VALUE is an owned string."
      #((parameters (value . "Candidate value."))
        (returns (type boolean) (description "Whether VALUE is a string."))
        (effects pure))
      (object-kind? value 'string))

    (define (host-string->string-storage string)
      "Copy host STRING into indexed character-vector storage."
      ;; R7RS permits host strings to use a variable-width representation.
      ;; Converting once keeps every owned string ref and mutation on the
      ;; constant-time indexed vector path instead of repeatedly indexing the
      ;; borrowed host representation.
      (list->vector (string->list string)))

    (define (string-storage->host storage)
      "Copy indexed character-vector STORAGE into one host string."
      (list->string (vector->list storage)))

    (define (copy-string-storage storage)
      "Return a fresh indexed copy of owned string STORAGE."
      (vector-copy storage))

    (define (consent-datum-string-from-host heap string)
      "Copy host STRING into a fresh owned string in HEAP."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (string (type string) (description "Host string to copy.")))
        (returns (type string) (description "Fresh owned string."))
        (effects allocation error))
      (if (not (string? string))
          (error "consent-datum-string-from-host: expected host string"
                 string))
      (allocate-datum-object
       heap 'string (host-string->string-storage string)))

    (define (consent-datum-string->host string)
      "Return a fresh host adapter copy of owned STRING."
      #((parameters
         (string (type string) (description "Owned string to project.")))
        (returns (type string) (description "Fresh host string copy."))
        (effects allocation error))
      (if (not (consent-datum-string? string))
          (error "consent-datum-string->host: expected owned string" string))
      (string-storage->host (datum-object-storage string)))

    (define (consent-datum-make-string heap length fill)
      "Return a fresh owned string of LENGTH filled with host character FILL."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (length (type exact-non-negative-integer)
          (description "Requested string length."))
         (fill (type character) (description "Host adapter fill character.")))
        (returns (type string) (description "Fresh owned string."))
        (effects allocation error))
      (allocate-datum-object heap 'string (make-vector length fill)))

    (define (consent-datum-string-copy-range heap string start end)
      "Copy owned STRING's half-open range into a fresh string in HEAP."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (string (type string) (description "Owned source string."))
         (start (type exact-non-negative-integer)
          (description "Inclusive source index."))
         (end (type exact-non-negative-integer)
          (description "Exclusive source index.")))
        (returns (type string) (description "Fresh mutable owned string."))
        (effects allocation error))
      (check-object heap string 'string "consent-datum-string-copy-range")
      (if (not (and (integer? start)
                    (exact? start)
                    (integer? end)
                    (exact? end)))
          (error
           "consent-datum-string-copy-range: expected exact indexes"
           start
           end))
      (let* ((source (datum-object-storage string))
             (source-length (vector-length source)))
        (if (not (and (<= 0 start) (<= start end) (<= end source-length)))
            (error
             "consent-datum-string-copy-range: invalid range"
             start
             end))
        (let* ((length (- end start))
               (copy (make-vector length)))
          (let loop ((source-index start) (copy-index 0))
            (if (< source-index end)
                (begin
                  (vector-set!
                   copy copy-index (vector-ref source source-index))
                  (loop (+ source-index 1) (+ copy-index 1)))))
          (allocate-datum-object heap 'string copy))))

    (define (consent-datum-string-length string)
      "Return owned STRING's length."
      #((parameters
         (string (type string) (description "Owned string to measure.")))
        (returns (type exact-non-negative-integer)
         (description "Number of characters in STRING."))
        (effects error))
      (if (not (consent-datum-string? string))
          (error "consent-datum-string-length: expected owned string" string))
      (consent-datum-string-length-trusted string))

    (define (consent-datum-string-length-trusted string)
      "Return already-validated owned STRING's length."
      #((parameters
         (string (type string)
          (description "Owned string already validated by the caller.")))
        (returns (type exact-non-negative-integer)
         (description "Number of characters in STRING."))
        (effects error))
      (vector-length (datum-object-storage string)))

    (define (consent-datum-string-ref-host string index)
      "Return owned STRING's host character at INDEX."
      #((parameters
         (string (type string) (description "Owned string to inspect."))
         (index (type exact-non-negative-integer)
          (description "Zero-based character index.")))
        (returns (type character) (description "Character at INDEX."))
        (effects error))
      (if (not (consent-datum-string? string))
          (error "consent-datum-string-ref-host: expected owned string"
                 string))
      (consent-datum-string-ref-host-trusted string index))

    (define (consent-datum-string-ref-host-trusted string index)
      "Return already-validated owned STRING's host character at INDEX."
      #((parameters
         (string (type string)
          (description "Owned string already validated by the caller."))
         (index (type exact-non-negative-integer)
          (description "Zero-based character index.")))
        (returns (type character) (description "Character at INDEX."))
        (effects error))
      (vector-ref (datum-object-storage string) index))

    (define (consent-datum-string-set-host! heap string index character)
      "Set owned STRING at INDEX to host CHARACTER through HEAP."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (string (type string) (description "Owned string to mutate."))
         (index (type exact-non-negative-integer)
          (description "Zero-based character index."))
         (character (type character)
          (description "Replacement host character.")))
        (returns . "The unspecified value.")
        (effects state-write error))
      (check-object heap string 'string "string-set!")
      (vector-storage-set! heap string 'string-set! index character))

    (define (consent-datum-vector? value)
      "Report whether VALUE is an owned vector."
      #((parameters (value . "Candidate value."))
        (returns (type boolean) (description "Whether VALUE is a vector."))
        (effects pure))
      (object-kind? value 'vector))

    (define (make-vector-placeholder heap length)
      "Allocate an uninitialized owned vector for cyclic graph import."
      (allocate-datum-object heap 'vector (make-vector length #f)))

    (define (initialize-vector-slot! vector index value)
      "Initialize fresh VECTOR's INDEX without reporting a mutation."
      (vector-set! (datum-object-storage vector) index value))

    (define (consent-datum-vector-from-host-elements heap elements)
      "Copy flat host ELEMENTS into one fresh owned vector in HEAP."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (elements (type vector)
          (description
           ("Flat host vector of scalars, opaque leaves, or compounds"
             "already owned by HEAP."))))
        (returns (type vector)
         (description "Fresh zero-revision owned vector."))
        (effects allocation error))
      (if (not (consent-datum-heap? heap))
          (error
           "consent-datum-vector-from-host-elements: expected heap"
           heap))
      (if (not (vector? elements))
          (error
           "consent-datum-vector-from-host-elements: expected host vector"
           elements))
      (let* ((length (vector-length elements))
             (storage (make-vector length #f)))
        (let loop ((index 0))
          (if (< index length)
              (let ((value (vector-ref elements index)))
                (cond
                 ((consent-datum-object? value)
                  (if (not (= (consent-datum-object-heap-id value)
                              (consent-datum-heap-id heap)))
                      (error
                       "host element belongs to a different datum heap"
                       value)))
                 ((or (pair? value)
                      (vector? value)
                      (string? value)
                      (bytevector? value))
                  (error
                   "host compound requires consent-datum-import"
                   value)))
                (vector-set! storage index value)
                (loop (+ index 1)))))
        (allocate-datum-object heap 'vector storage)))

    (define (consent-datum-vector-from-host heap vector)
      "Import host VECTOR and nested compounds into HEAP."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (vector (type vector) (description "Host vector to import.")))
        (returns (type vector) (description "Owned graph root."))
        (effects allocation error))
      (if (not (vector? vector))
          (error "consent-datum-vector-from-host: expected host vector"
                 vector))
      (consent-datum-import heap vector))

    (define (consent-datum-vector->host vector)
      "Export owned VECTOR and nested compounds to a fresh host graph."
      #((parameters
         (vector (type vector) (description "Owned vector to project.")))
        (returns (type vector) (description "Fresh host graph root."))
        (effects allocation error))
      (if (not (consent-datum-vector? vector))
          (error "consent-datum-vector->host: expected owned vector" vector))
      (consent-datum-export vector))

    (define (consent-datum-make-vector heap length fill)
      "Return a fresh owned vector of LENGTH initialized to FILL."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (length (type exact-non-negative-integer)
          (description "Requested vector length."))
         (fill . "Initial element value."))
        (returns (type vector) (description "Fresh owned vector."))
        (effects allocation error))
      (allocate-datum-object heap 'vector (make-vector length fill)))

    (define (consent-datum-vector-length vector)
      "Return owned VECTOR's length."
      #((parameters
         (vector (type vector) (description "Owned vector to measure.")))
        (returns (type exact-non-negative-integer)
         (description "Number of elements in VECTOR."))
        (effects error))
      (if (not (consent-datum-vector? vector))
          (error "consent-datum-vector-length: expected owned vector" vector))
      (consent-datum-vector-length-trusted vector))

    (define (consent-datum-vector-length-trusted vector)
      "Return already-validated owned VECTOR's length."
      #((parameters
         (vector (type vector)
          (description "Owned vector already validated by the caller.")))
        (returns (type exact-non-negative-integer)
         (description "Number of elements in VECTOR."))
        (effects error))
      (vector-length (datum-object-storage vector)))

    (define (consent-datum-vector-ref vector index)
      "Return owned VECTOR's element at INDEX."
      #((parameters
         (vector (type vector) (description "Owned vector to inspect."))
         (index (type exact-non-negative-integer)
          (description "Zero-based element index.")))
        (returns (type any) (description "Stored element."))
        (effects error))
      (if (not (consent-datum-vector? vector))
          (error "consent-datum-vector-ref: expected owned vector" vector))
      (consent-datum-vector-ref-trusted vector index))

    (define (consent-datum-vector-ref-trusted vector index)
      "Return already-validated owned VECTOR's element at INDEX."
      #((parameters
         (vector (type vector)
          (description "Owned vector already validated by the caller."))
         (index (type exact-non-negative-integer)
          (description "Zero-based element index.")))
        (returns (type any) (description "Stored element."))
        (effects error))
      (vector-ref (datum-object-storage vector) index))

    (define (consent-datum-vector-set! heap vector index value)
      "Set owned VECTOR at INDEX to VALUE through HEAP."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (vector (type vector) (description "Owned vector to mutate."))
         (index (type exact-non-negative-integer)
          (description "Zero-based element index."))
         (value . "Replacement element."))
        (returns . "The unspecified value.")
        (effects state-write error))
      (check-object heap vector 'vector "vector-set!")
      (vector-storage-set! heap vector 'vector-set! index value))

    (define (consent-datum-vector-set-trusted! heap vector index value)
      "Set already-validated owned VECTOR at INDEX through HEAP."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (vector (type vector)
          (description "Owned vector already validated by the caller."))
         (index (type exact-non-negative-integer)
          (description "Zero-based element index."))
         (value . "Replacement element."))
        (returns . "The unspecified value.")
        (effects state-write error))
      ;; Kind validation belongs to the trusted caller, but heap identity is
      ;; still an ownership boundary and must fail closed here.
      (if (not (eq? heap (datum-object-heap vector)))
          (error
           "consent-datum-vector-set-trusted!: object belongs to other heap"
           vector))
      (vector-storage-set! heap vector 'vector-set! index value))

    (define (consent-datum-bytevector? value)
      "Report whether VALUE is an owned bytevector."
      #((parameters (value . "Candidate value."))
        (returns (type boolean)
         (description "Whether VALUE is a bytevector."))
        (effects pure))
      (object-kind? value 'bytevector))

    (define (copy-host-bytevector bytevector)
      "Return a fresh host bytevector copy of BYTEVECTOR."
      (let* ((length (bytevector-length bytevector))
             (copy (make-bytevector length 0)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (bytevector-u8-set!
                 copy index (bytevector-u8-ref bytevector index))
                (loop (+ index 1)))))
        copy))

    (define (consent-datum-bytevector-from-host heap bytevector)
      "Copy host BYTEVECTOR into a fresh owned bytevector in HEAP."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (bytevector (type bytevector)
          (description "Host bytevector to copy.")))
        (returns (type bytevector) (description "Fresh owned bytevector."))
        (effects allocation error))
      (if (not (bytevector? bytevector))
          (error
           "consent-datum-bytevector-from-host: expected host bytevector"
           bytevector))
      (allocate-datum-object
       heap 'bytevector (copy-host-bytevector bytevector)))

    (define (consent-datum-bytevector->host bytevector)
      "Return a fresh host adapter copy of owned BYTEVECTOR."
      #((parameters
         (bytevector (type bytevector)
          (description "Owned bytevector to project.")))
        (returns (type bytevector) (description "Fresh host bytevector."))
        (effects allocation error))
      (if (not (consent-datum-bytevector? bytevector))
          (error
           "consent-datum-bytevector->host: expected owned bytevector"
           bytevector))
      (copy-host-bytevector (datum-object-storage bytevector)))

    (define (consent-datum-make-bytevector heap length fill)
      "Return a fresh owned bytevector of LENGTH initialized to FILL."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (length (type exact-non-negative-integer)
          (description "Requested bytevector length."))
         (fill (type exact-integer) (description "Initial byte value.")))
        (returns (type bytevector) (description "Fresh owned bytevector."))
        (effects allocation error))
      (allocate-datum-object
       heap 'bytevector (make-bytevector length fill)))

    (define (consent-datum-bytevector-length bytevector)
      "Return owned BYTEVECTOR's length."
      #((parameters
         (bytevector (type bytevector)
          (description "Owned bytevector to measure.")))
        (returns (type exact-non-negative-integer)
         (description "Number of bytes in BYTEVECTOR."))
        (effects error))
      (if (not (consent-datum-bytevector? bytevector))
          (error
           "consent-datum-bytevector-length: expected owned bytevector"
           bytevector))
      (bytevector-length (datum-object-storage bytevector)))

    (define (consent-datum-bytevector-u8-ref bytevector index)
      "Return owned BYTEVECTOR's byte at INDEX."
      #((parameters
         (bytevector (type bytevector)
          (description "Owned bytevector to inspect."))
         (index (type exact-non-negative-integer)
          (description "Zero-based byte index.")))
        (returns (type exact-integer) (description "Byte at INDEX."))
        (effects error))
      (if (not (consent-datum-bytevector? bytevector))
          (error
           "consent-datum-bytevector-u8-ref: expected owned bytevector"
           bytevector))
      (bytevector-u8-ref (datum-object-storage bytevector) index))

    (define (consent-datum-bytevector-u8-set! heap bytevector index byte)
      "Set owned BYTEVECTOR at INDEX to BYTE through HEAP."
      #((parameters
         (heap (type datum-heap) (description "Active heap."))
         (bytevector (type bytevector)
          (description "Owned bytevector to mutate."))
         (index (type exact-non-negative-integer)
          (description "Zero-based byte index."))
         (byte (type exact-integer) (description "Replacement byte.")))
        (returns . "The unspecified value.")
        (effects state-write error))
      (check-object heap bytevector 'bytevector "bytevector-u8-set!")
      (bytevector-storage-set!
       heap bytevector 'bytevector-u8-set! index byte))

    ;; A call-scoped owned-object map is an intrusive traversal mark, the same
    ;; mature pattern used by collectors and graph algorithms. Every lookup
    ;; and insertion takes one ordinal-sidecar probe. A unique map token
    ;; distinguishes nested traversals.
    ;;
    ;; MAP is #(token touched-entry active?). ENTRY is
    ;; #(token value older newer object next-touched). The intrusive touched
    ;; chain avoids two host cons cells per first insertion. The two entry
    ;; links make explicit out-of-order release constant-time too; ordinary
    ;; dynamic nesting simply pops the current header and restores the outer
    ;; entry.
    (define (consent-make-datum-object-map)
      "Return an active call-scoped map keyed by owned datum identity."
      #((parameters)
        (returns (type datum-object-map)
         (description "A fresh active owned-object identity map."))
        (effects allocation))
      (vector (vector 'consent-datum-object-map-token) #f #t))

    (define (check-active-datum-object-map operation map object)
      "Validate active MAP and owned OBJECT for OPERATION."
      (if (not (and (vector? map)
                    (= (vector-length map) 3)
                    (vector-ref map 2)))
          (error operation "expected active datum-object map" map))
      (if (not (consent-datum-object? object))
          (error operation "expected owned datum object" object)))

    (define (datum-object-map-current-entry map object)
      "Return OBJECT's entry for MAP, or #f when another scope is current."
      (let ((entry (datum-object-map-entry object)))
        (and entry
             (eq? (vector-ref entry 0) (vector-ref map 0))
             entry)))

    (define (consent-datum-object-map-ref map object default)
      "Return OBJECT's value in MAP, or DEFAULT after one sidecar probe."
      #((parameters
         (map (type datum-object-map) (description "Map to inspect."))
         (object (type compound-datum)
          (description "Owned object used as the identity key."))
         (default (type any)
          (description "Fallback value when OBJECT is absent.")))
        (returns (type any)
         (description "The associated value or DEFAULT."))
        (effects state-read error))
      (check-active-datum-object-map
       "consent-datum-object-map-ref:" map object)
      (let ((entry (datum-object-map-current-entry map object)))
        (if entry (vector-ref entry 1) default)))

    (define (consent-datum-object-map-set! map object value)
      "Associate owned OBJECT with VALUE in MAP and return VALUE."
      #((parameters
         (map (type datum-object-map) (description "Map to update."))
         (object (type compound-datum)
          (description "Owned object used as the identity key."))
         (value (type any) (description "Value to associate.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects state-write error))
      (check-active-datum-object-map
       "consent-datum-object-map-set!:" map object)
      ;; Read the current sidecar slot once. An absent insertion reuses that
      ;; value as OLDER instead of probing OBJECT a second time.
      (let* ((header (datum-object-map-entry object))
             (entry
              (and header
                   (eq? (vector-ref header 0) (vector-ref map 0))
                   header)))
        (if entry
            (vector-set! entry 1 value)
            (let ((created
                   (vector (vector-ref map 0)
                           value
                           header
                           #f
                           object
                           (vector-ref map 1))))
              (if header (vector-set! header 3 created))
              (raw-set-datum-object-map-entry! object created)
              (vector-set! map 1 created)
              (datum-residency-open!
               datum-residency-graph-map-entry 1))))
      value)

    (define (datum-object-map-entry-unlink! object entry)
      "Unlink ENTRY from OBJECT's intrusive map stack in constant time."
      (let ((older (vector-ref entry 2))
            (newer (vector-ref entry 3)))
        (if newer
            (vector-set! newer 2 older)
            (raw-set-datum-object-map-entry! object older))
        (if older (vector-set! older 3 newer))
        (vector-set! entry 2 #f)
        (vector-set! entry 3 #f)))

    (define (consent-datum-object-map-release! map)
      "Release MAP, restoring every outer intrusive entry, and return MAP."
      #((parameters
         (map (type datum-object-map) (description "Map to release.")))
        (returns (type datum-object-map)
         (description "The inactive released MAP."))
        (effects state-write error))
      (if (not (and (vector? map) (= (vector-length map) 3)))
          (error
           "consent-datum-object-map-release!: expected datum-object map"
           map))
      (if (vector-ref map 2)
          (begin
            (vector-set! map 2 #f)
            (let loop ((touched (vector-ref map 1)))
              (if touched
                  (let ((next (vector-ref touched 5)))
                    (datum-object-map-entry-unlink!
                     (vector-ref touched 4) touched)
                    (vector-set! touched 4 #f)
                    (vector-set! touched 5 #f)
                    (datum-residency-close!
                     datum-residency-graph-map-entry 1)
                    (loop next))))
            (vector-set! map 1 #f)))
      map)

    (define (consent-datum-object-map-probe-count map object)
      "Return the fixed number of ordinal-sidecar probes used by MAP lookup."
      #((parameters
         (map (type datum-object-map) (description "Map to inspect."))
         (object (type compound-datum)
          (description "Owned object whose sidecar slot is probed.")))
        (returns (type exact-positive-integer)
         (description "The fixed ordinal-sidecar probe count."))
        (effects state-read error))
      (check-active-datum-object-map
       "consent-datum-object-map-probe-count:" map object)
      ;; Exercise the same real sidecar path as REF; this diagnostic must not
      ;; merely report the documented constant without probing the object.
      (datum-object-map-entry object)
      1)

    (define (call-with-consent-datum-object-map procedure)
      "Call PROCEDURE with a fresh map and release it on every exit path."
      #((parameters
         (procedure (type procedure)
          (description "Callback receiving the fresh active map.")))
        (returns (type any)
         (description "The callback result."))
        (effects allocation state-write error))
      (if (not (procedure? procedure))
          (error
           "call-with-consent-datum-object-map: expected procedure"
           procedure))
      (let ((map (consent-make-datum-object-map)))
        (dynamic-wind
         (lambda ()
           (if (not (vector-ref map 2))
               (error "datum-object map continuation cannot be re-entered")))
         (lambda () (procedure map))
         (lambda () (consent-datum-object-map-release! map)))))

    ;; Import and export own their memo tables for exactly one dynamic phase.
    ;; Their common case visits one source heap, so a phase-local ordinal
    ;; sidecar can store memo values directly without allocating an intrusive
    ;; entry and a heap-sidecar slot for every object. A foreign-heap overflow
    ;; map preserves exact hybrid-graph behavior without penalizing that common
    ;; ownership shape. MAP is
    ;; #(false-token heap sidecar overflow category size active?).
    (define (make-datum-phase-map category)
      "Return an empty phase-owned map for import or export memoization."
      (vector
       (vector 'consent-datum-phase-map-false)
       #f
       #f
       #f
       category
       0
       #t))

    (define (datum-phase-map-ref map object default)
      "Return OBJECT's phase-local value in MAP, or DEFAULT."
      (if (eq? (vector-ref map 1) (datum-object-heap object))
          (let ((value
                 (datum-sidecar-ref
                  (vector-ref map 2)
                  (consent-datum-object-id object)
                  #f)))
            (cond
             ((not value) default)
             ((eq? value (vector-ref map 0)) #f)
             (else value)))
          (let ((overflow (vector-ref map 3)))
            (if overflow
                (consent-datum-object-map-ref overflow object default)
                default))))

    (define (datum-phase-map-set! map object value)
      "Associate OBJECT with VALUE in phase-owned MAP."
      (if (not (vector-ref map 1))
          (begin
            (vector-set! map 1 (datum-object-heap object))
            (vector-set!
             map 2 (make-datum-sidecar datum-residency-phase-map-page))))
      (if (eq? (vector-ref map 1) (datum-object-heap object))
          (let* ((sidecar (vector-ref map 2))
                 (ordinal (consent-datum-object-id object))
                 (prior (datum-sidecar-ref sidecar ordinal #f)))
            (datum-sidecar-set!
             sidecar ordinal (if value value (vector-ref map 0)))
            (if (not prior)
                (begin
                  (vector-set! map 5 (+ (vector-ref map 5) 1))
                  (datum-residency-open! (vector-ref map 4) 1))))
          (let ((overflow (vector-ref map 3)))
            (if (not overflow)
                (begin
                  (set! overflow (consent-make-datum-object-map))
                  (vector-set! map 3 overflow)))
            (let ((missing (vector 'datum-phase-map-missing)))
              (if (eq? (consent-datum-object-map-ref
                        overflow object missing)
                       missing)
                  (begin
                    (vector-set! map 5 (+ (vector-ref map 5) 1))
                    (datum-residency-open! (vector-ref map 4) 1)))
              (consent-datum-object-map-set! overflow object value))))
      value)

    (define (datum-phase-map-release! map)
      "Clear every root held by phase-owned MAP and make it inactive."
      (if (vector-ref map 6)
          (begin
            (vector-set! map 6 #f)
            (let ((sidecar (vector-ref map 2))
                  (overflow (vector-ref map 3)))
              (if sidecar (datum-sidecar-release! sidecar))
              (if overflow
                  (consent-datum-object-map-release! overflow)))
            (datum-residency-close! (vector-ref map 4) (vector-ref map 5))
            (vector-set! map 1 #f)
            (vector-set! map 2 #f)
            (vector-set! map 3 #f)
            (vector-set! map 5 0)))
      map)

    (define (consent-datum-object-shareable? object)
      "Report whether OBJECT belongs to a certified frozen runtime image."
      #((parameters
         (object (type any)
          (description "Candidate read-only runtime-image object.")))
        (returns (type boolean)
         (description
          ("Whether OBJECT was validated as part of its frozen heap's"
            "shareable graph.")))
        (effects state-read state-write))
      (and
       (consent-datum-object? object)
       (let* ((heap (datum-object-heap object))
              (members (datum-heap-image-members heap)))
         (and (consent-datum-heap-frozen? heap)
              members
              (consent-dense-set-member?
               members (consent-datum-object-id object))))))

    (define (consent-datum-heap-freeze! heap roots)
      "Freeze HEAP after validating shareable runtime-image ROOTS."
      "Reachable pairs, strings, vectors, and bytevectors allocated in HEAP"
      "are certified by stable ordinal. Already-certified frozen objects may"
      "be referenced. Mutable foreign owned objects and raw host compounds"
      "are rejected. A frozen heap cannot allocate or visibly mutate values;"
      "an import into another heap reuses certified objects read-only."
      #((parameters
         (heap (type datum-heap)
          (description "Mutable heap to certify and freeze."))
         (roots (type list)
          (description "Proper list of runtime-image graph roots.")))
        (returns (type datum-heap)
         (description "The certified frozen HEAP."))
        (effects allocation state-read state-write error))
      (if (not (consent-datum-heap? heap))
          (error "consent-datum-heap-freeze!: expected heap" heap))
      (if (not (list? roots))
          (error "consent-datum-heap-freeze!: expected root list" roots))
      (if (> (datum-heap-construction-count heap) 0)
          (error
           "consent-datum-heap-freeze!: construction scope is active"
           heap))
      (if (consent-datum-heap-frozen? heap)
          heap
          (let* ((limit (datum-heap-next-id heap))
                 (members
                  (consent-make-dense-set
                   limit limit 1 1 'pre-reserved 'datum-runtime-image)))
            (guard
             (condition
              (else
               (consent-dense-set-release! members)
               (raise condition)))
             (let loop ((work roots))
               (if (pair? work)
                   (let ((value (car work))
                         (rest (cdr work)))
                     (cond
                      ((consent-datum-object? value)
                       (let ((owner (datum-object-heap value)))
                         (cond
                          ((eq? owner heap)
                           (let ((prior
                                  (consent-dense-set-mark!
                                   members
                                   (consent-datum-object-id value))))
                             (if prior
                                 (loop rest)
                                 (case (consent-datum-object-kind value)
                                   ((pair)
                                    (loop
                                     (cons
                                      (consent-datum-car-trusted value)
                                      (cons
                                       (consent-datum-cdr-trusted value)
                                       rest))))
                                   ((vector)
                                    (let push
                                        ((index
                                          (-
                                           (consent-datum-vector-length-trusted
                                            value)
                                           1))
                                         (next rest))
                                      (if (< index 0)
                                          (loop next)
                                          (push
                                           (- index 1)
                                           (cons
                                            (consent-datum-vector-ref-trusted
                                             value index)
                                            next)))))
                                   ((string bytevector) (loop rest))
                                   (else
                                    (error
                                     "runtime image contains private datum"
                                     value))))))
                          ((consent-datum-object-shareable? value)
                           (loop rest))
                          (else
                           (error
                            "runtime image contains mutable foreign datum"
                            value)))))
                      ((or (pair? value)
                           (string? value)
                           (vector? value)
                           (bytevector? value))
                       (error
                        "runtime image contains raw host compound"
                        value))
                      (else (loop rest))))))
             (set-datum-heap-image-members! heap members)
             (set-datum-heap-frozen! heap #t)
             heap))))

    (define (host-seen-ref seen value)
      "Return host VALUE's graph copy in mutable registry SEEN, or #f."
      (consent-identity-map-ref seen value #f))

    (define (host-seen-set! seen value copy)
      "Record host VALUE's graph COPY in mutable registry SEEN."
      (consent-identity-map-set! seen value copy))

    ;; The identity adapter's plain-R7RS fallback is a linear association
    ;; list.  Compatibility calls may still process small foreign graphs, but
    ;; an exact fixed ceiling prevents lookup work from becoming quadratic.
    (define datum-host-identity-compatibility-limit 64)

    (define (datum-import-graph
             heap value leaf copy-source reuse leaf-valid?)
      "Import and optionally count one compound graph iteratively."
      (let ((counted? (and leaf-valid? #t))
            (absent-token (vector 'consent-datum-import-absent))
            (count-only-token
             (and leaf-valid?
                  (vector 'consent-datum-import-count-only)))
            (host-seen #f)
            (host-fast? (consent-identity-map-fast-backend?))
            (host-count 0)
            (owned-seen #f)
            (node-count 0)
            (invalid-leaf? #f)
            (first-invalid-leaf #f)
            (work '()))
        (define (note-nodes! count)
          "Add COUNT nodes when this import is counting."
          (if counted? (set! node-count (+ node-count count))))
        (define (note-leaf! item)
          "Count ITEM and retain the first leaf rejected by LEAF-VALID?."
          (if counted?
              (begin
                (set! node-count (+ node-count 1))
                (if (and (not invalid-leaf?)
                         (not (leaf-valid? item)))
                    (begin
                      (set! invalid-leaf? #t)
                      (set! first-invalid-leaf item))))))
        (define (import-host-ref item)
          "Return ITEM's imported host copy, or the private absent token."
          (if host-seen
              (consent-identity-map-ref host-seen item absent-token)
              absent-token))
        (define (import-host-insert! item copy)
          "Memoize known-absent host ITEM as COPY."
          (if (not host-seen)
              (set! host-seen (consent-make-identity-map)))
          (if (and (not host-fast?)
                   (>= host-count
                       datum-host-identity-compatibility-limit))
              (error
               "consent-datum-import: foreign graph requires fast \
identity maps"
               item))
          (host-seen-set! host-seen item copy)
          (set! host-count (+ host-count 1))
          (datum-residency-open!
           datum-residency-import-host-memo-entry 1))
        (define (import-host-update! item copy)
          "Replace already-reserved host ITEM with COPY."
          (host-seen-set! host-seen item copy))
        (define (reserve-import-host! item)
          "Reserve one distinct host ITEM before callback or allocation."
          (import-host-insert!
           item (vector 'consent-datum-import-reserved)))
        (define (import-owned-ref item)
          "Return ITEM's cross-heap copy, or the private absent token."
          (if owned-seen
              (datum-phase-map-ref owned-seen item absent-token)
              absent-token))
        (define (import-owned-set! item copy)
          "Memoize owned ITEM as COPY, allocating the map on first use."
          (if (not owned-seen)
              (set! owned-seen
                    (make-datum-phase-map
                     datum-residency-import-owned-memo-entry)))
          (datum-phase-map-set! owned-seen item copy))
        ;; Work entries are #(tag source destination slot). Tags zero and three
        ;; copy with counting enabled or disabled. Tag one finishes source
        ;; metadata after outgoing edges. Tag two counts an already-owned
        ;; subtree without rewriting it. The explicit DFS stack keeps graph
        ;; depth off the Scheme implementation's control stack.
        (dynamic-wind
         (lambda () #t)
         (lambda ()
          (let ((root (vector #f)))
          (define (push-copy-visit! source destination slot count-source?)
            "Schedule SOURCE for copying, optionally counting its subtree."
            (set! work
                  (cons
                   (vector
                    (if count-source? 0 3) source destination slot)
                   work))
            (datum-residency-open!
             datum-residency-import-work-entry 1))
          (define (push-finish! source copy)
            "Schedule one post-edge source metadata copy."
            (set! work (cons (vector 1 source copy 0) work))
            (datum-residency-open!
             datum-residency-import-work-entry 1))
          (define (push-count-visit! source)
            "Schedule SOURCE for counting without copying or callbacks."
            (set! work (cons (vector 2 source #f 0) work))
            (datum-residency-open!
             datum-residency-import-work-entry 1))
          (define (deliver! destination slot result)
            "Store one imported RESULT in its already-allocated parent."
            (if (datum-pair-record? destination)
                (if (= slot 0)
                    (raw-set-datum-pair-head! destination result)
                    (raw-set-datum-pair-tail! destination result))
                (vector-set! destination slot result)))
          (define (accept-host-reuse! source destination slot)
            "Try host SOURCE's reuse hook and memoize an accepted target."
            (if counted?
                #f
             (let ((candidate (reuse source absent-token)))
               (if (eq? candidate absent-token)
                   #f
                   (begin
                     (import-host-update! source candidate)
                     (deliver! destination slot candidate)
                     #t)))))
          (define (accept-owned-reuse! source destination slot)
            "Try owned SOURCE's reuse hook and memoize an accepted target."
            (if counted?
                #f
             (let ((candidate (reuse source absent-token)))
               (if (eq? candidate absent-token)
                   #f
                   (begin
                     (import-owned-set! source candidate)
                     (deliver! destination slot candidate)
                     #t)))))
          (define (push-owned-vector-edges!
                   source copy length count-source?)
            "Schedule SOURCE vector edges in ascending observation order."
            (let ((storage (datum-object-storage copy)))
              (let loop ((index (- length 1)))
                (if (>= index 0)
                    (begin
                      (push-copy-visit!
                       (consent-datum-vector-ref-trusted source index)
                       storage
                       index
                       count-source?)
                      (loop (- index 1)))))))
          (define (push-host-vector-edges!
                   source copy length count-source?)
            "Schedule host SOURCE vector edges in ascending order."
            (let ((storage (datum-object-storage copy)))
              (let loop ((index (- length 1)))
                (if (>= index 0)
                    (begin
                      (push-copy-visit!
                       (vector-ref source index)
                       storage
                       index
                       count-source?)
                      (loop (- index 1)))))))
          (define (start-owned-copy!
                   source destination slot count-source?)
            "Allocate and schedule one cross-heap owned compound copy."
            (case (consent-datum-object-kind source)
              ((pair)
               (let ((copy (make-pair-placeholder heap)))
                 (datum-residency-open!
                  datum-residency-import-result-shell 1)
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (if count-source? (note-nodes! 1))
                 (push-finish! source copy)
                 (push-copy-visit!
                  (consent-datum-cdr-trusted source)
                  copy
                  1
                  count-source?)
                 (push-copy-visit!
                  (consent-datum-car-trusted source)
                  copy
                  0
                  count-source?)))
              ((string)
               (let ((copy
                      (allocate-datum-object
                       heap
                       'string
                       (copy-string-storage
                        (datum-object-storage source)))))
                 (datum-residency-open!
                  datum-residency-import-result-shell 1)
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (if count-source?
                     (note-nodes!
                      (+ 1 (vector-length (datum-object-storage source)))))
                 (push-finish! source copy)))
              ((bytevector)
               (let ((copy
                      (allocate-datum-object
                       heap
                       'bytevector
                       (copy-host-bytevector
                        (datum-object-storage source)))))
                 (datum-residency-open!
                  datum-residency-import-result-shell 1)
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (if count-source?
                     (note-nodes!
                      (+ 1
                         (bytevector-length
                          (datum-object-storage source)))))
                 (push-finish! source copy)))
              ((vector)
               (let* ((length
                       (consent-datum-vector-length-trusted source))
                      (copy (make-vector-placeholder heap length)))
                 (datum-residency-open!
                  datum-residency-import-result-shell 1)
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (if count-source? (note-nodes! 1))
                 (push-finish! source copy)
                 (push-owned-vector-edges!
                  source copy length count-source?)))
              (else
               (error
                "consent-datum-import: unsupported owned kind"
                source))))
          (define (start-host-copy!
                   source destination slot count-source?)
            "Allocate and schedule one host compound copy into HEAP."
            (cond
             ((pair? source)
              (let ((copy (make-pair-placeholder heap)))
                (datum-residency-open!
                 datum-residency-import-result-shell 1)
                (import-host-update! source copy)
                (deliver! destination slot copy)
                (if count-source? (note-nodes! 1))
                (push-finish! source copy)
                (push-copy-visit!
                 (cdr source)
                 copy
                 1
                 count-source?)
                (push-copy-visit!
                 (car source)
                 copy
                 0
                 count-source?)))
             ((string? source)
              (let ((copy (consent-datum-string-from-host heap source)))
                (datum-residency-open!
                 datum-residency-import-result-shell 1)
                (import-host-update! source copy)
                (deliver! destination slot copy)
                (if count-source?
                    (note-nodes! (+ 1 (string-length source))))
                (push-finish! source copy)))
             ((bytevector? source)
              (let ((copy
                     (consent-datum-bytevector-from-host heap source)))
                (datum-residency-open!
                 datum-residency-import-result-shell 1)
                (import-host-update! source copy)
                (deliver! destination slot copy)
                (if count-source?
                    (note-nodes! (+ 1 (bytevector-length source))))
                (push-finish! source copy)))
             ((vector? source)
              (let* ((length (vector-length source))
                    (copy (make-vector-placeholder heap length)))
                (datum-residency-open!
                 datum-residency-import-result-shell 1)
                (import-host-update! source copy)
                (deliver! destination slot copy)
                (if count-source? (note-nodes! 1))
                (push-finish! source copy)
                (push-host-vector-edges!
                 source copy length count-source?)))))
          (define (visit-owned!
                   source destination slot count-source?)
            "Deliver one owned SOURCE or schedule its cross-heap copy."
            (if (or (eq? heap (datum-object-heap source))
                    (consent-datum-object-shareable? source))
                (begin
                  (deliver! destination slot source)
                  (if (and counted? count-source?)
                      (push-count-visit! source)))
                (let ((prior (import-owned-ref source)))
                  (cond
                   ((and counted? (eq? prior count-only-token))
                    (start-owned-copy! source destination slot #f))
                   ((not (eq? prior absent-token))
                    (deliver! destination slot prior))
                   ((accept-owned-reuse! source destination slot))
                   (else
                    (start-owned-copy!
                     source destination slot count-source?))))))
          (define (visit-host!
                   source destination slot count-source?)
            "Deliver one host SOURCE or schedule its compound copy."
            (if (or (pair? source)
                    (string? source)
                    (bytevector? source)
                    (vector? source))
                (let ((prior (import-host-ref source)))
                  (cond
                   ((and counted? (eq? prior count-only-token))
                    (start-host-copy! source destination slot #f))
                   ((not (eq? prior absent-token))
                    (deliver! destination slot prior))
                   (else
                    (reserve-import-host! source)
                    (if (not
                         (accept-host-reuse!
                          source destination slot))
                        (start-host-copy!
                         source destination slot count-source?)))))
                (begin
                  (if count-source? (note-leaf! source))
                  (deliver!
                   destination slot
                   (if counted? source (leaf source))))))
          (define (count-owned! source)
            "Count an unseen owned SOURCE without copying it."
            (if (eq? (import-owned-ref source) absent-token)
                (begin
                  (import-owned-set! source count-only-token)
                  (case (consent-datum-object-kind source)
                    ((pair)
                     (note-nodes! 1)
                     (push-count-visit!
                      (consent-datum-cdr-trusted source))
                     (push-count-visit!
                      (consent-datum-car-trusted source)))
                    ((string)
                     (note-nodes!
                      (+ 1 (vector-length (datum-object-storage source)))))
                    ((bytevector)
                     (note-nodes!
                      (+ 1
                         (bytevector-length
                          (datum-object-storage source)))))
                    ((vector)
                     (note-nodes! 1)
                     (let ((length
                            (consent-datum-vector-length-trusted source)))
                       (let loop ((index (- length 1)))
                         (if (>= index 0)
                             (begin
                               (push-count-visit!
                                (consent-datum-vector-ref-trusted
                                 source index))
                               (loop (- index 1)))))))
                    (else
                     (error
                      "consent-datum-import: unsupported owned kind"
                      source))))))
          (define (count-host-compound! source)
            "Count an unseen host compound SOURCE without copying it."
            (if (eq? (import-host-ref source) absent-token)
                (begin
                  (import-host-insert! source count-only-token)
                  (cond
                   ((pair? source)
                    (note-nodes! 1)
                    (push-count-visit! (cdr source))
                    (push-count-visit! (car source)))
                   ((string? source)
                    (note-nodes! (+ 1 (string-length source))))
                   ((bytevector? source)
                    (note-nodes! (+ 1 (bytevector-length source))))
                   ((vector? source)
                    (note-nodes! 1)
                    (let loop ((index (- (vector-length source) 1)))
                      (if (>= index 0)
                          (begin
                            (push-count-visit!
                             (vector-ref source index))
                            (loop (- index 1))))))))))
          (define (visit-count-only! source)
            "Count SOURCE's reachable nodes without copying its graph."
            (cond
             ((consent-datum-object? source) (count-owned! source))
             ((or (pair? source)
                  (string? source)
                  (bytevector? source)
                  (vector? source))
              (count-host-compound! source))
             (else (note-leaf! source))))
          ;; Ordinary imports seed the no-count tag and therefore never enter
          ;; the counting branches below. Counted imports propagate tag zero
          ;; until a previously count-only subtree needs copying via tag three.
          (push-copy-visit! value root 0 counted?)
          (let loop ()
            (if (null? work)
                (if counted?
                    (values
                     (vector-ref root 0)
                     node-count
                     invalid-leaf?
                     first-invalid-leaf)
                    (vector-ref root 0))
                (let ((job (car work)))
                  (set! work (cdr work))
                  (datum-residency-close!
                   datum-residency-import-work-entry 1)
                  (case (vector-ref job 0)
                    ((0 3)
                     (let ((source (vector-ref job 1))
                           (destination (vector-ref job 2))
                           (slot (vector-ref job 3))
                           (count-source? (= (vector-ref job 0) 0)))
                       (if (consent-datum-object? source)
                           (visit-owned!
                            source destination slot count-source?)
                           (visit-host!
                            source destination slot count-source?))))
                    ((1)
                     (copy-source
                      (vector-ref job 2) (vector-ref job 1)))
                    (else (visit-count-only! (vector-ref job 1))))
                  (loop))))))
         (lambda ()
           (let ((pending (length work)))
             (set! work '())
             (datum-residency-close!
              datum-residency-import-work-entry pending))
           (if host-seen
               (begin
                 (consent-identity-map-release! host-seen)
                 (datum-residency-close!
                  datum-residency-import-host-memo-entry host-count)))
           (if owned-seen
               (datum-phase-map-release! owned-seen))))))

    (define (consent-datum-import heap value . rest)
      "Import host compound VALUE into HEAP, preserving sharing and cycles."
      #((parameters
         (heap (type datum-heap) (description "Destination heap."))
         (value . "Host or already-owned graph root." )
         (rest (type list)
          (description
           ("Optional leaf converter, source-copy callback, and compound"
             "reuse callback.  The reuse callback receives the source and"
             "a private absent token, and returns a target or that token."))))
        (returns . "Owned graph root with converted leaves.")
        (effects allocation error))
      (cond
       ((and (consent-datum-object? value)
             (eq? heap (datum-object-heap value)))
        value)
       ((not (or (consent-datum-object? value)
                 (pair? value)
                 (string? value)
                 (bytevector? value)
                 (vector? value)))
        (if (null? rest) value ((car rest) value)))
       (else
        (let ((leaf (if (null? rest) (lambda (item) item) (car rest)))
              (copy-source
               (if (or (null? rest) (null? (cdr rest)))
                   (lambda (target source) target)
                   (cadr rest)))
              (reuse
               (if (or (null? rest)
                       (null? (cdr rest))
                       (null? (cddr rest)))
                   (lambda (source absent) absent)
                   (car (cddr rest)))))
          (datum-import-graph
           heap value leaf copy-source reuse #f)))))

    (define (consent-datum-import-with-node-count
             heap value leaf-valid? copy-source!)
      "Import VALUE while counting its exact unique reachable datum nodes."
      #((parameters
         (heap (type datum-heap) (description "Destination heap."))
         (value . "Host or already-owned graph root." )
         (leaf-valid? (type procedure)
          (description "Non-raising predicate for atomic leaves."))
         (copy-source! (type procedure)
          (description
           ("Callback receiving each fresh target and its source after"
             "the target's outgoing edges have been initialized."))))
        (returns
         . ("Four values: the owned root, exact node count, whether an"
            "invalid leaf was seen, and the first invalid leaf."))
        (effects allocation state-read state-write error))
      (if (not (procedure? leaf-valid?))
          (error
           "consent-datum-import-with-node-count: expected leaf predicate"
           leaf-valid?))
      (if (not (procedure? copy-source!))
          (error
           "consent-datum-import-with-node-count: expected source callback"
           copy-source!))
      (if (or (consent-datum-object? value)
              (pair? value)
              (string? value)
              (bytevector? value)
              (vector? value))
          (datum-import-graph
           heap value #f copy-source! #f leaf-valid?)
          (let ((valid? (leaf-valid? value)))
            (values value 1 (not valid?) (if valid? #f value)))))

    (define (consent-datum-export value . rest)
      "Export owned compound VALUE as a host graph, preserving topology."
      #((parameters
         (value . "Owned or host graph root." )
         (rest (type list)
          (description
           ("Optional leaf converter, source-copy callback, and compound"
             "reuse callback.  The reuse callback receives the source and"
             "a private absent token, and returns a target or that token."))))
        (returns . "Fresh host graph root with converted leaves.")
        (effects allocation error))
      (if (and (consent-datum-object? value)
               (case (consent-datum-object-kind value)
                 ((pair string bytevector vector) #t)
                 (else #f)))
          (let ((leaf (if (null? rest) (lambda (item) item) (car rest)))
            (copy-source
             (if (or (null? rest) (null? (cdr rest)))
                 (lambda (target source) target)
                 (cadr rest)))
            (reuse
             (if (or (null? rest)
                     (null? (cdr rest))
                     (null? (cddr rest)))
                 (lambda (source absent) absent)
                 (car (cddr rest))))
            (absent-token (vector 'consent-datum-export-absent))
            (owned-seen #f)
            (host-seen #f)
            (host-fast? (consent-identity-map-fast-backend?))
            (host-count 0)
            (work '()))
        (define (export-owned-ref item)
          "Return owned ITEM's host copy, or the private absent token."
          (if owned-seen
              (datum-phase-map-ref owned-seen item absent-token)
              absent-token))
        (define (export-owned-set! item copy)
          "Memoize owned ITEM as COPY, allocating the map on first use."
          (if (not owned-seen)
              (set! owned-seen
                    (make-datum-phase-map
                     datum-residency-export-owned-memo-entry)))
          (datum-phase-map-set! owned-seen item copy))
        (define (export-host-ref item)
          "Return host ITEM's graph copy, or the private absent token."
          (if host-seen
              (consent-identity-map-ref
               host-seen item absent-token)
              absent-token))
        (define (export-host-insert! item copy)
          "Memoize known-absent host ITEM as COPY."
          (if (not host-seen)
              (set! host-seen (consent-make-identity-map)))
          (if (and (not host-fast?)
                   (>= host-count
                       datum-host-identity-compatibility-limit))
              (error
               "consent-datum-export: foreign graph requires fast \
identity maps"
               item))
          (consent-identity-map-set! host-seen item copy)
          (set! host-count (+ host-count 1))
          (datum-residency-open!
           datum-residency-export-host-memo-entry 1))
        (define (export-host-update! item copy)
          "Replace already-reserved host ITEM with COPY."
          (consent-identity-map-set! host-seen item copy))
        (define (reserve-export-host! item)
          "Reserve one distinct host ITEM before callback or allocation."
          (export-host-insert!
           item (vector 'consent-datum-export-reserved)))
        ;; Visit jobs use #(0 source destination slot).  Non-negative slots
        ;; address vectors; -1 and -2 address a host pair's car and cdr.
        ;; Finish jobs use #(1 source copy 0).  The explicit stack preserves
        ;; recursive DFS callback order without consuming the control stack.
        (dynamic-wind
         (lambda () #t)
         (lambda ()
          (let ((root (vector #f)))
          (define (push-visit! source destination slot)
            "Schedule SOURCE for delivery into DESTINATION at SLOT."
            (set! work
                  (cons (vector 0 source destination slot) work))
            (datum-residency-open!
             datum-residency-export-work-entry 1))
          (define (push-finish! source copy)
            "Schedule one post-edge source metadata copy."
            (set! work (cons (vector 1 source copy 0) work))
            (datum-residency-open!
             datum-residency-export-work-entry 1))
          (define (deliver! destination slot result)
            "Store exported RESULT into a root, vector, or pair slot."
            (cond
             ((>= slot 0) (vector-set! destination slot result))
             ((= slot -1) (set-car! destination result))
             (else (set-cdr! destination result))))
          (define (accept-reuse! source destination slot)
            "Try SOURCE's reuse hook and memoize an accepted host target."
            (let ((candidate (reuse source absent-token)))
              (if (eq? candidate absent-token)
                  #f
                  (begin
                    (if (consent-datum-object? source)
                        (export-owned-set! source candidate)
                        (export-host-update! source candidate))
                    (deliver! destination slot candidate)
                    #t))))
          (define (push-vector-edges! source copy length owned?)
            "Schedule SOURCE vector edges in ascending order."
            (let loop ((index (- length 1)))
              (if (>= index 0)
                  (begin
                    (push-visit!
                     (if owned?
                         (consent-datum-vector-ref source index)
                         (vector-ref source index))
                     copy
                     index)
                    (loop (- index 1))))))
          (define (start-owned-copy! source destination slot)
            "Allocate and schedule one owned compound host copy."
            (case (consent-datum-object-kind source)
              ((pair)
               (let ((copy (cons #f #f)))
                 (datum-residency-open!
                  datum-residency-export-result-shell 1)
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)
                 (push-visit!
                  (consent-datum-cdr-trusted source) copy -2)
                 (push-visit!
                  (consent-datum-car-trusted source) copy -1)))
              ((string)
               (let ((copy (consent-datum-string->host source)))
                 (datum-residency-open!
                  datum-residency-export-result-shell 1)
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)))
              ((bytevector)
               (let ((copy (consent-datum-bytevector->host source)))
                 (datum-residency-open!
                  datum-residency-export-result-shell 1)
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)))
              ((vector)
               (let* ((length (consent-datum-vector-length source))
                      (copy (make-vector length #f)))
                 (datum-residency-open!
                  datum-residency-export-result-shell 1)
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)
                 (push-vector-edges! source copy length #t)))))
          (define (start-host-copy! source destination slot)
            "Allocate and schedule one private host compound copy."
            (cond
             ((pair? source)
              (let ((copy (cons #f #f)))
                (datum-residency-open!
                 datum-residency-export-result-shell 1)
                (export-host-update! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)
                (push-visit! (cdr source) copy -2)
                (push-visit! (car source) copy -1)))
             ((string? source)
              (let ((copy (string-copy source)))
                (datum-residency-open!
                 datum-residency-export-result-shell 1)
                (export-host-update! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)))
             ((bytevector? source)
              (let ((copy (bytevector-copy source)))
                (datum-residency-open!
                 datum-residency-export-result-shell 1)
                (export-host-update! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)))
             ((vector? source)
              (let* ((length (vector-length source))
                    (copy (make-vector length #f)))
                (datum-residency-open!
                 datum-residency-export-result-shell 1)
                (export-host-update! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)
                (push-vector-edges! source copy length #f)))))
          (define (owned-export-compound? source)
            "Return whether SOURCE is an exportable owned compound."
            (and (consent-datum-object? source)
                 (case (consent-datum-object-kind source)
                   ((pair string bytevector vector) #t)
                   (else #f))))
          (define (host-export-compound? source)
            "Return whether SOURCE is a private host compound."
            (or (pair? source)
                (string? source)
                (bytevector? source)
                (vector? source)))
          (define (visit! source destination slot)
            "Deliver SOURCE or schedule its hybrid graph copy."
            (cond
             ((owned-export-compound? source)
              (let ((prior (export-owned-ref source)))
                (cond
                 ((not (eq? prior absent-token))
                  (deliver! destination slot prior))
                 ((accept-reuse! source destination slot))
                 (else
                  (start-owned-copy! source destination slot)))))
             ((host-export-compound? source)
              (let ((prior (export-host-ref source)))
                  (cond
                   ((not (eq? prior absent-token))
                    (deliver! destination slot prior))
                   (else
                    (reserve-export-host! source)
                    (if (not (accept-reuse! source destination slot))
                        (start-host-copy! source destination slot))))))
             (else
              (deliver! destination slot (leaf source)))))
          (push-visit! value root 0)
          (let loop ()
            (if (null? work)
                (vector-ref root 0)
                (let ((job (car work)))
                  (set! work (cdr work))
                  (datum-residency-close!
                   datum-residency-export-work-entry 1)
                  (if (= (vector-ref job 0) 0)
                      (visit!
                       (vector-ref job 1)
                       (vector-ref job 2)
                       (vector-ref job 3))
                      (copy-source
                       (vector-ref job 2) (vector-ref job 1)))
                  (loop))))))
         (lambda ()
           (let ((pending (length work)))
             (set! work '())
             (datum-residency-close!
              datum-residency-export-work-entry pending))
           (if host-seen
               (begin
                 (consent-identity-map-release! host-seen)
                 (datum-residency-close!
                  datum-residency-export-host-memo-entry host-count)))
           (if owned-seen
               (datum-phase-map-release! owned-seen)))))
          (if (null? rest) value ((car rest) value))))))
