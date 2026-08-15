;;; Portable Consent Scheme inspectable memory records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral scoped memory records as Scheme-readable
;;; datums.  Persistence and UI buffers are adapter concerns.  Private runtime
;;; indexes are rebuildable caches; the canonical record stream remains the
;;; source of truth.  Store records are append-only immutable snapshots:
;;; mutating a returned field does not retarget cached lookup.  Install edited
;;; streams through memory-store-replace-records! so every cache is rebuilt.
;;; Text search renders the current record read-only; behavior after violating
;;; the immutable-record contract is otherwise intentionally unspecified.

(define-library (agent memory)
  (export consent-memory-scopes
          consent-memory-classes
          consent-make-memory-store
          consent-memory-store?
          memory-store-put!
          memory-store-ref
          memory-store-delete!
          memory-store-add!
          memory-store-access!
          memory-store-reflect!
          memory-store-select
          memory-store-find
          memory-store-by-tag
          memory-store-recent
          memory-store-records
          memory-store-replace-records!
          memory-storage-rules
          memory-scope-datum
          memory-scope-datum-records
          memory-record-id
          memory-record-field-value
          memory-record-class
          memory-selection?
          memory-selection-records
          memory-selection-candidates
          memory-selection-cutoff)
  (import (scheme base)
          (only (agent memory-key)
                memory-prepare-index-key
                call-with-memory-index-key-session
                memory-index-key-bounded-comparison?
                memory-index-key<?
                memory-index-key=?)
          (only (agent memory-query)
                memory-query-find
                memory-query-by-tag
                memory-query-recent
                memory-query-select)
          (only (data avl-tree)
                make-avl-tree
                avl-tree-ref
                avl-tree-ref/key
                avl-tree-set
                avl-tree-delete
                avl-tree-empty?
                avl-tree-size
                avl-tree-fold
                avl-tree-max
                avl-tree-key-predecessor)
          (only (consent identity-map)
                consent-identity-map-adjoin!
                consent-identity-map-fast-backend?
                consent-make-identity-map
                consent-identity-map-ref
                consent-identity-map-release!
                consent-identity-map-set!))
  (begin
    ;; Small memory stores dominate interactive agent work.  Keep at most this
    ;; many sorted associations inline, then upgrade permanently to the
    ;; persistent AVL representation.  The hard cap preserves logarithmic
    ;; asymptotics while avoiding generic tree machinery for tiny stores.
    (define memory-inline-index-limit 16)

    ;; Distinguishes a bounded inline index from its persistent AVL successor.
    (define memory-inline-index-marker (vector #f))

    (define (make-memory-index ordering)
      "Return an empty bounded-inline persistent index."
      (vector memory-inline-index-marker ordering '() 0))

    (define (memory-inline-index? index)
      "Return #t when INDEX still uses its bounded inline representation."
      (and (vector? index)
           (= (vector-length index) 4)
           (eq? (vector-ref index 0) memory-inline-index-marker)))

    (define (memory-inline-index-ordering index)
      "Return inline INDEX's strict key ordering."
      (vector-ref index 1))

    (define (memory-inline-index-entries index)
      "Return inline INDEX's ascending association list."
      (vector-ref index 2))

    (define (memory-inline-index-size index)
      "Return inline INDEX's association count."
      (vector-ref index 3))

    (define (memory-index-ref/key index key failure success)
      "Locate KEY in adaptive INDEX and call FAILURE or SUCCESS."
      (if (not (memory-inline-index? index))
          (avl-tree-ref/key index key failure success)
          (let ((ordering (memory-inline-index-ordering index)))
            (let loop ((rest (memory-inline-index-entries index)))
              (cond
               ((null? rest) (failure))
               ((ordering key (caar rest)) (failure))
               ((ordering (caar rest) key) (loop (cdr rest)))
               (else (success (caar rest) (cdar rest))))))))

    (define (memory-index-ref index key . handlers)
      "Return KEY's value from adaptive INDEX through optional handlers."
      (let ((failure
             (if (null? handlers)
                 (lambda () (error "memory index key not found" key))
                 (car handlers)))
            (success
             (if (or (null? handlers) (null? (cdr handlers)))
                 (lambda (value) value)
                 (cadr handlers))))
        (memory-index-ref/key index key failure
                              (lambda (stored-key value) (success value)))))

    (define (memory-inline-index-set index key value)
      "Return inline INDEX with KEY associated with VALUE."
      (let ((ordering (memory-inline-index-ordering index)))
        (let loop ((rest (memory-inline-index-entries index))
                   (reversed '()))
          (cond
           ((null? rest)
            (values
             (append (reverse reversed) (list (cons key value)))
             #t))
           ((ordering key (caar rest))
            (values
             (append (reverse reversed) (cons (cons key value) rest))
             #t))
           ((ordering (caar rest) key)
            (loop (cdr rest) (cons (car rest) reversed)))
           (else
            (values
             (append
              (reverse reversed)
              (cons (cons (caar rest) value) (cdr rest)))
             #f))))))

    (define (memory-inline-index->avl ordering entries)
      "Upgrade sorted inline ENTRIES to a persistent AVL index."
      (let loop ((tree (make-avl-tree ordering)) (rest entries))
        (if (null? rest)
            tree
            (loop
             (avl-tree-set tree (caar rest) (cdar rest))
             (cdr rest)))))

    (define (memory-index-set index key value)
      "Return adaptive INDEX with KEY associated with VALUE."
      (if (not (memory-inline-index? index))
          (avl-tree-set index key value)
          (call-with-values
              (lambda () (memory-inline-index-set index key value))
            (lambda (entries added?)
              (let ((size (+ (memory-inline-index-size index)
                             (if added? 1 0))))
                (if (> size memory-inline-index-limit)
                    (memory-inline-index->avl
                     (memory-inline-index-ordering index) entries)
                    (vector memory-inline-index-marker
                            (memory-inline-index-ordering index)
                            entries
                            size)))))))

    (define (memory-index-delete index key)
      "Return adaptive INDEX without KEY."
      (if (not (memory-inline-index? index))
          (avl-tree-delete index key)
          (let ((ordering (memory-inline-index-ordering index)))
            (let loop ((rest (memory-inline-index-entries index))
                       (reversed '()))
              (cond
               ((null? rest) index)
               ((ordering key (caar rest)) index)
               ((ordering (caar rest) key)
                (loop (cdr rest) (cons (car rest) reversed)))
               (else
                (vector
                 memory-inline-index-marker
                 ordering
                 (append (reverse reversed) (cdr rest))
                 (- (memory-inline-index-size index) 1))))))))

    (define (memory-index-empty? index)
      "Return #t when adaptive INDEX has no associations."
      (if (memory-inline-index? index)
          (= (memory-inline-index-size index) 0)
          (avl-tree-empty? index)))

    (define (memory-index-size index)
      "Return adaptive INDEX's association count."
      (if (memory-inline-index? index)
          (memory-inline-index-size index)
          (avl-tree-size index)))

    (define (memory-index-fold procedure nil index)
      "Fold PROCEDURE over adaptive INDEX in ascending order."
      (if (not (memory-inline-index? index))
          (avl-tree-fold procedure nil index)
          (let loop ((rest (memory-inline-index-entries index))
                     (result nil))
            (if (null? rest)
                result
                (loop (cdr rest)
                      (procedure (caar rest) (cdar rest) result))))))

    (define (memory-index-max index failure)
      "Return adaptive INDEX's maximum key and value, or call FAILURE."
      (if (not (memory-inline-index? index))
          (avl-tree-max index failure)
          (let loop ((rest (memory-inline-index-entries index))
                     (latest #f))
            (if (null? rest)
                (if latest
                    (values (car latest) (cdr latest))
                    (failure))
                (loop (cdr rest) (car rest))))))

    (define (memory-index-key-predecessor index key failure)
      "Return adaptive INDEX's association before KEY, or call FAILURE."
      (if (not (memory-inline-index? index))
          (avl-tree-key-predecessor index key failure)
          (let ((ordering (memory-inline-index-ordering index)))
            (let loop ((rest (memory-inline-index-entries index))
                       (previous #f))
              (cond
               ((null? rest)
                (if previous
                    (values (car previous) (cdr previous))
                    (failure)))
               ((ordering (caar rest) key)
                (loop (cdr rest) (car rest)))
               (else
                (if previous
                    (values (car previous) (cdr previous))
                    (failure))))))))

    (define (integer-datum sequence)
      "Return SEQUENCE as an exact integer datum."
      sequence)

    (define (integer-value value)
      "Validate and return VALUE for memory count arguments."
      (if (and (integer? value) (exact? value))
          value
          (error "memory count must be an exact integer" value)))

    ;; Public memory scopes mirror the Consent Scheme architecture document.
    (define consent-memory-scopes
      '(instance session project))

    ;; Public memory classes reconcile CoALA-style memory taxonomy with one
    ;; append-only record stream.
    (define consent-memory-classes
      '(working episodic semantic procedural))

    ;; Mutable portable memory store for host-neutral tests and interpreter
    ;; primitives.  One private immutable state vector holds canonical history,
    ;; event clocks, current live/key/order indexes, access maxima, and the
    ;; store-lifetime detached descriptor interner.  Replacing that root in one
    ;; record mutation keeps every projection atomic when validation rejects an
    ;; update.
    (define-record-type <consent-memory-store>
      (make-memory-store state)
      consent-memory-store?
      (state store-state set-store-state!))

    (define (make-memory-store-state
             records
             next-id
             next-ordinal
             ordered-index
             order-indexes
             access-index
             descriptor-index)
      "Return one private immutable root for STORE state."
      (vector records
              next-id
              next-ordinal
              ordered-index
              order-indexes
              access-index
              descriptor-index))

    (define (store-records store)
      "Return STORE's canonical record stream from its state root."
      (vector-ref (store-state store) 0))

    (define (store-next-id store)
      "Return STORE's next-id cache from its state root."
      (vector-ref (store-state store) 1))

    (define (store-ordered-index store)
      "Return STORE's ordered key index from its state root."
      (vector-ref (store-state store) 3))

    (define (store-next-ordinal store)
      "Return STORE's private append-event ordinal."
      (vector-ref (store-state store) 2))

    (define (store-order-indexes store)
      "Return STORE's current live per-scope order indexes."
      (vector-ref (store-state store) 4))

    (define (store-access-index store)
      "Return STORE's latest access sequence index."
      (vector-ref (store-state store) 5))

    (define (store-descriptor-index store)
      "Return STORE's lifetime detached descriptor interner."
      (vector-ref (store-state store) 6))

    ;; Sidecars are private, immutable append-time projections.  Native query
    ;; code never traverses the record's key, id, accessed, kind, or tags
    ;; fields, so bridge projection cannot change their equality classes.
    ;; Slots are live-key, id-key, access-target-key-or-#f, kind-key,
    ;; tag-key-vector, and event/security flags.  Text is rendered read-only by
    ;; the native query kernel only when a textual query actually needs it.
    (define memory-sidecar-access-flag 1)
;; Bit marking an append-time tombstone event.
(define memory-sidecar-tombstone-flag 2)
;; Bit marking source-classified restricted record content.
(define memory-sidecar-redaction-flag 4)

    (define (make-memory-key-sidecar
             kind redaction-sensitive? live-key id-key access-target-key
             kind-key tag-keys)
      "Return one detached append-time query sidecar."
      (vector
       live-key
       id-key
       access-target-key
       kind-key
       (list->vector tag-keys)
       (+ (if (eq? kind 'memory-access)
              memory-sidecar-access-flag
              0)
          (if (eq? kind 'memory-tombstone)
              memory-sidecar-tombstone-flag
              0)
          (if redaction-sensitive?
              memory-sidecar-redaction-flag
              0))))

(define (memory-key-sidecar-live-key sidecar)
  "Return SIDECAR's detached live-key descriptor."
      (vector-ref sidecar 0))

(define (memory-key-sidecar-id-key sidecar)
  "Return SIDECAR's detached id descriptor."
      (vector-ref sidecar 1))

(define (memory-key-sidecar-access-target-key sidecar)
  "Return SIDECAR's detached access-target descriptor."
      (vector-ref sidecar 2))

(define (memory-key-sidecar-kind-key sidecar)
  "Return SIDECAR's detached kind descriptor."
      (vector-ref sidecar 3))

(define (memory-key-sidecar-tag-keys sidecar)
  "Return SIDECAR's detached tag descriptor vector."
      (vector-ref sidecar 4))

(define (memory-key-sidecar-flags sidecar)
  "Return SIDECAR's immutable classification flags."
      (vector-ref sidecar 5))

    (define (memory-key-sidecar-access? sidecar)
      "Return #t when SIDECAR describes an access event."
      (= (modulo (memory-key-sidecar-flags sidecar) 2) 1))

    (define (memory-key-sidecar-tombstone? sidecar)
      "Return #t when SIDECAR describes a tombstone event."
      (>= (modulo (memory-key-sidecar-flags sidecar) 4) 2))

    (define (prepare-memory-tag-keys prepare scope tags)
      "Return detached descriptors for accepted TAGS."
      (if (not (finite-proper-list? tags))
          (error "memory record tags must be a finite proper list" tags))
      (map (lambda (tag) (prepare scope tag)) tags))

    (define (make-memory-key-sidecar/prepared
             prepare scope record live-key id-key access-target-key
             trusted-canonical?)
      "Build RECORD's complete sidecar with PREPARE."
      (let* ((selected
              (select-record-fields record '(kind tags local-only)))
             (kind (selected-field selected 'kind #f))
             (tags (selected-field selected 'tags '()))
             (redaction-sensitive?
              (if trusted-canonical?
                  (canonical-memory-record-redaction-sensitive? record)
                  (memory-record-redaction-sensitive? record))))
        (if (not (symbol? kind))
            (error "memory record kind must be a symbol" kind))
        (make-memory-key-sidecar
         kind
         redaction-sensitive?
         live-key
         id-key
         access-target-key
         (prepare scope kind)
         (prepare-memory-tag-keys prepare scope tags))))

    (define (memory-key-sidecar-with-keys
             sidecar live-key id-key access-target-key)
      "Return SIDECAR with only its canonical identity descriptors replaced."
      (vector
       live-key
       id-key
       access-target-key
       (memory-key-sidecar-kind-key sidecar)
       (memory-key-sidecar-tag-keys sidecar)
       (memory-key-sidecar-flags sidecar)))

    (define (replace-memory-store-state!
             store
             records
             next-id
             next-ordinal
             ordered-index
             order-indexes
             access-index
             descriptor-index)
      "Atomically publish STORE records and their derived caches."
      (set-store-state!
       store
       (make-memory-store-state
        records
        next-id
        next-ordinal
        ordered-index
        order-indexes
        access-index
        descriptor-index)))

    (define (memory-ordered-key scope key)
      "Return one detached durable ordered representation for SCOPE and KEY."
      (memory-prepare-index-key scope key))

    (define (make-memory-ordered-index)
      "Return an empty private common scope/key index."
      (make-memory-index memory-index-key<?))

    (define (make-memory-order-index)
      "Return an empty private sequence-ordered live index."
      (make-memory-index <))

    (define (make-memory-order-indexes)
      "Return empty live order indexes for the three public scopes."
      (vector (make-memory-order-index)
              (make-memory-order-index)
              (make-memory-order-index)))

    (define (memory-scope-position scope)
      "Return SCOPE's fixed order-index position."
      (cond
       ((eq? scope 'instance) 0)
       ((eq? scope 'session) 1)
       ((eq? scope 'project) 2)
       (else (error "unknown memory scope" scope))))

    (define (memory-order-index-ref indexes scope)
      "Return SCOPE's live order index from INDEXES."
      (vector-ref indexes (memory-scope-position scope)))

    (define (memory-order-indexes-set indexes scope index)
      "Return INDEXES with SCOPE replaced by INDEX."
      (let ((copy (vector-copy indexes)))
        (vector-set! copy (memory-scope-position scope) index)
        copy))

    (define (consent-make-memory-store)
      "Construct an empty memory store."
      #((parameters)
        (returns (type consent-memory-store)
         (description
          ("A mutable memory store with no records and the next"
            "generated id set to zero.")))
        (effects allocation))
      (make-memory-store
       (make-memory-store-state
        '()
        0
        0
        (make-memory-ordered-index)
        (make-memory-order-indexes)
        (make-memory-ordered-index)
        (make-memory-ordered-index))))

    (define (member-equal? value list)
      "Report whether VALUE appears in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (if (member-equal? scope consent-memory-scopes)
          scope
          (error "unknown memory scope" scope)))

    (define (next-sequence store)
      "Return STORE's next sequence without publishing partial state."
      (+ (store-next-id store) 1))

    (define (generated-id sequence)
      "Convert SEQUENCE into a generated memory id."
      (string->symbol
       (string-append "m-" (number->string sequence))))

    (define (field-value datum name)
      "Return field NAME from RECORD or payload DATUM, or #f."
      (let ((fields (if (and (pair? datum) (eq? (car datum) 'memory))
                        (cdr datum)
                        datum)))
        (if (not (finite-proper-list? fields))
            (error "memory fields must be a finite proper list" datum))
        (let loop ((rest fields))
          (cond
           ((null? rest) #f)
           ((and (pair? (car rest))
                 (eq? (caar rest) name))
            (cadr (car rest)))
           (else (loop (cdr rest)))))))

    (define (field-value/default datum name default)
      "Return field NAME from DATUM, or DEFAULT when NAME is absent."
      (let ((fields (if (and (pair? datum)
                             (symbol? (car datum))
                             (not (and (pair? (car datum))
                                       (symbol? (caar datum)))))
                        (cdr datum)
                        datum)))
        (if (not (finite-proper-list? fields))
            (error "memory fields must be a finite proper list" datum))
        (let loop ((rest fields))
          (cond
           ((null? rest) default)
           ((and (pair? (car rest))
                 (eq? (caar rest) name))
            (cadr (car rest)))
           (else (loop (cdr rest)))))))

    (define (select-finite-fields fields names)
      "Return the first values named by NAMES from finite FIELDS."
      (let loop ((rest fields) (selected '()))
        (if (null? rest)
            selected
            (let ((field (car rest)))
              (if (and (pair? field)
                       (memq (car field) names)
                       (not (assq (car field) selected)))
                  (loop
                   (cdr rest)
                   (cons (cons (car field) (cadr field)) selected))
                  (loop (cdr rest) selected))))))

    (define (selected-field selected name default)
      "Return NAME from SELECTED, or DEFAULT when absent or false."
      (let ((entry (assq name selected)))
        (if (and entry (cdr entry)) (cdr entry) default)))

    (define (select-record-fields record names)
      "Validate RECORD once and return the first fields named by NAMES."
      (let ((fields
             (if (and (pair? record) (eq? (car record) 'memory))
                 (cdr record)
                 record)))
        (if (not (finite-proper-list? fields))
            (error "memory fields must be a finite proper list" record))
        (select-finite-fields fields names)))

    (define (memory-record-field-value record name . maybe-default)
      "Return field NAME from RECORD, or DEFAULT when absent."
      #((parameters
         (record (type list)
          (description "Scheme-readable memory or memory-selection record."))
         (name (type symbol)
          (description "Field name to read."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . "The field value, or the fallback when NAME is absent.")
        (effects pure))
      (field-value/default record name
                           (if (null? maybe-default) #f (car maybe-default))))

    (define (normalize-memory-class memory-class)
      "Validate and return MEMORY-CLASS."
      (if (member-equal? memory-class consent-memory-classes)
          memory-class
          (error "unknown memory class" memory-class)))

    (define (default-memory-class kind)
      "Return the default memory class for KIND."
      (cond
       ((eq? kind 'memory-access) 'working)
       ((eq? kind 'memory-tombstone) 'working)
       (else 'semantic)))

    (define (memory-record-class record)
      "Return RECORD's memory-class field."
      #((parameters
         (record (type list)
          (description "Memory record datum.")))
        (returns (type symbol)
         (description "One of the public memory class symbols."))
        (effects pure error))
      (normalize-memory-class
       (field-value/default record 'memory-class
                            (default-memory-class
                             (field-value record 'kind)))))

    (define (memory-record-id record)
      "Return canonical id field from a memory RECORD."
      #((parameters
         (record (type list)
          (description "Memory record datum.")))
        (returns (type symbol)
         (description "The record id field."))
        (effects pure))
      (field-value record 'id))

    (define (memory-scope-datum-records datum)
      "Return the records field from an agent-memory scope DATUM."
      #((parameters
         (datum (type list)
          (description "Agent memory scope datum.")))
        (returns (type list)
         (description "The scope datum's memory records."))
        (effects pure error))
      (let ((records (field-value datum 'records)))
        (if records
            records
            (error "memory scope datum must contain records"))))

    (define (memory-record-key record)
      "Return RECORD's key field."
      (field-value record 'key))

    (define (memory-record-kind record)
      "Return RECORD's kind field."
      (field-value record 'kind))

    (define (memory-record-tags record)
      "Return RECORD's tag list, or the empty list when absent."
      (field-value/default record 'tags '()))

    (define (memory-record-tombstone? record)
      "Return #t when RECORD is a tombstone event."
      (eq? (memory-record-kind record) 'memory-tombstone))

    (define (memory-record-access? record)
      "Return #t when RECORD is a memory-access event."
      (eq? (memory-record-kind record) 'memory-access))

    (define (finite-proper-list? value)
      "Return #t when VALUE is a finite proper list."
      (let loop ((slow value) (fast value))
        (cond
         ((null? fast) #t)
         ((not (pair? fast)) #f)
         (else
          (let ((fast-one (cdr fast)))
            (cond
             ((null? fast-one) #t)
             ((not (pair? fast-one)) #f)
             (else
              (let ((slow-one (cdr slow))
                    (fast-two (cdr fast-one)))
                (and (not (eq? slow-one fast-two))
                     (loop slow-one fast-two))))))))))

    ;; Unique result selecting the general branching-graph traversal.
    (define memory-tagged-branch
      (vector 'memory-tagged-branch))

    ;; Unique result marking the end of a unary compound spine.
    (define memory-tagged-leaf
      (vector 'memory-tagged-leaf))

    ;; Return VALUE's only compound child or one of the tagged results above.
    (define-syntax memory-single-compound-child
      (syntax-rules ()
        ((_ value)
         (let ((current value))
           (cond
            ((pair? current)
             (let* ((left (car current))
                    (right (cdr current))
                    (left? (or (pair? left) (vector? left)))
                    (right? (or (pair? right) (vector? right))))
               (cond
                ((and left? right?) memory-tagged-branch)
                (left? left)
                (right? right)
                (else memory-tagged-leaf))))
            ((vector? current)
             (let find ((index 0) (child memory-tagged-leaf))
               (if (= index (vector-length current))
                   child
                   (let ((candidate (vector-ref current index)))
                     (if (or (pair? candidate) (vector? candidate))
                         (if (eq? child memory-tagged-leaf)
                             (find (+ index 1) candidate)
                             memory-tagged-branch)
                         (find (+ index 1) child))))))
            (else memory-tagged-leaf))))))

    (define (memory-values-contain-tagged? values tags irritant)
      "Return #t when VALUES contain a record headed by one of TAGS."
      (let ()
        (define (matching-record? value)
          (and (pair? value) (memq (car value) tags)))
        (define (unary-scan root)
          ;; Brent cycle detection keeps unary spines stack safe and constant
          ;; space. Branching graphs use the identity-table walk.
          (let loop
              ((value root) (checkpoint root) (power 1) (distance 0))
            (if (matching-record? value)
                #t
                (let ((next (memory-single-compound-child value)))
                  (cond
                   ((eq? next memory-tagged-branch) memory-tagged-branch)
                   ((eq? next memory-tagged-leaf) #f)
                   ((eq? next checkpoint) #f)
                   ((= (+ distance 1) power)
                    (loop next next (* power 2) 0))
                   (else
                    (loop next checkpoint power (+ distance 1))))))))
        (define (branching-scan)
          ;; Compatibility hosts admit only a fixed small branching graph, so
          ;; the fallback cannot become an unbounded quadratic identity alist.
          (let ((fast? (consent-identity-map-fast-backend?))
                (seen (consent-make-identity-map))
                (seen-count 0))
            (define (seen? value)
              (if (consent-identity-map-adjoin! seen value #t)
                  (begin
                    (set! seen-count (+ seen-count 1))
                    (if (and (not fast?) (> seen-count 64))
                        (error
                         "large memory record requires fast identity map"
                         irritant))
                    #f)
                  #t))
            (dynamic-wind
             (lambda () #t)
             (lambda ()
               (let walk ((pending values))
                 (if (null? pending)
                     #f
                     (let ((value (car pending))
                           (rest (cdr pending)))
                       (cond
                        ((matching-record? value) #t)
                        ((pair? value)
                         (if (seen? value)
                             (walk rest)
                             (walk
                              (cons (car value) (cons (cdr value) rest)))))
                        ((vector? value)
                         (if (seen? value)
                             (walk rest)
                             (let push
                                 ((index (- (vector-length value) 1))
                                  (next rest))
                               (if (< index 0)
                                   (walk next)
                                   (push
                                    (- index 1)
                                    (cons
                                     (vector-ref value index) next))))))
                        (else (walk rest)))))))
             (lambda () (consent-identity-map-release! seen)))))
        (let loop ((rest values))
          (if (null? rest)
              #f
              (let ((result (unary-scan (car rest))))
                (cond
                 ((eq? result memory-tagged-branch) (branching-scan))
                 (result #t)
                 (else (loop (cdr rest)))))))))

    (define (memory-record-contains-tagged? datum tag . additional-tags)
      "Return #t when DATUM contains a record headed by a requested tag."
      (memory-values-contain-tagged?
       (list datum) (cons tag additional-tags) datum))

    (define (canonical-memory-record-redaction-sensitive? record)
      "Classify freshly constructed canonical RECORD without wrapper scans."
      (let ((fields (cdr record)))
        (let collect ((rest fields) (values '()))
          (if (null? rest)
              (memory-values-contain-tagged?
               values '(local-only redaction) record)
              (let ((field (car rest)))
                (if (or (eq? (car field) 'local-only)
                        (eq? (car field) 'redaction))
                    #t
                    (collect (cdr rest) (cons (cadr field) values))))))))

    (define (memory-record-redaction-sensitive? record)
      "Return #t when accepted RECORD carries restricted content."
      (or
       (let ((local-only
              (field-value/default record 'local-only #f)))
         (and local-only #t))
       (memory-record-contains-tagged?
        record 'local-only 'redaction)))

    ;; A live entry is shared verbatim by the key and order indexes.  Slots are
    ;; record, canonical live key, lean sidecar, and private append ordinal.
    ;; Access maxima live separately by canonical id so duplicate ids share one
    ;; value without rewriting every live entry on each access event.
(define (make-memory-live-entry record live-key sidecar ordinal)
  "Return one current-live entry for RECORD at append ORDINAL."
      (vector record live-key sidecar ordinal))

(define (memory-live-entry-record entry)
  "Return live ENTRY's record."
  (vector-ref entry 0))
(define (memory-live-entry-key entry)
  "Return live ENTRY's canonical key."
  (vector-ref entry 1))
(define (memory-live-entry-sidecar entry)
  "Return live ENTRY's detached sidecar."
  (vector-ref entry 2))
(define (memory-live-entry-ordinal entry)
  "Return live ENTRY's append ordinal."
  (vector-ref entry 3))

(define (memory-live-entry-id-key entry)
  "Return live ENTRY's detached id descriptor."
      (memory-key-sidecar-id-key (memory-live-entry-sidecar entry)))

(define (memory-live-entry-scope entry)
  "Return live ENTRY's canonical scope name."
      (let ((scope
             (vector-ref (memory-live-entry-key entry) 0)))
        (cond
         ((string=? scope "instance") 'instance)
         ((string=? scope "session") 'session)
         ((string=? scope "project") 'project)
         (else (error "invalid prepared memory scope" scope)))))

    (define (memory-descriptor-index-intern index key)
      "Return canonical KEY and INDEX containing it as two values."
      (if (memory-index-key-bounded-comparison? key)
          (values key index)
          (memory-index-ref/key
           index
           key
           (lambda () (values key (memory-index-set index key key)))
           (lambda (stored-key value) (values stored-key index)))))

    (define (memory-descriptor-index-ref index key)
      "Return INDEX's canonical descriptor equal to KEY, or #f."
      (if (memory-index-key-bounded-comparison? key)
          key
          (memory-index-ref/key
           index key (lambda () #f) (lambda (stored-key value) stored-key))))

    (define (memory-order-index-remove indexes entry)
      "Return INDEXES without live ENTRY."
      (let* ((scope (memory-live-entry-scope entry))
             (index (memory-order-index-ref indexes scope)))
        (memory-order-indexes-set
         indexes
         scope
         (memory-index-delete index (memory-live-entry-ordinal entry)))))

    (define (memory-order-index-set indexes entry)
      "Return INDEXES containing live ENTRY at its private ordinal."
      (let* ((scope (memory-live-entry-scope entry))
             (index (memory-order-index-ref indexes scope)))
        (memory-order-indexes-set
         indexes
         scope
         (memory-index-set index (memory-live-entry-ordinal entry) entry))))

    (define (memory-prepared-state-from-records records)
      "Build every derived cache off-root from canonical RECORDS."
      (if (not (finite-proper-list? records))
          (error "memory records must be a finite proper list" records))
      (let ((scratch (consent-make-memory-store)))
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let loop ((rest (reverse records)))
             (if (null? rest)
                 (store-state scratch)
                 (begin
                   (append-existing-memory-record/prepared!
                    scratch (car rest) prepare)
                   (loop (cdr rest)))))))))

    (define (memory-record-sequence record)
      "Return RECORD's highest timestamp sequence, or zero when absent."
      (let* ((selected
              (select-record-fields record '(created-at updated-at)))
             (created-at (selected-field selected 'created-at 0))
             (updated-at (selected-field selected 'updated-at 0)))
        (max (integer-value created-at) (integer-value updated-at))))

    (define (memory-store-records store)
      "Return STORE's immutable canonical records, newest first."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect.")))
        (returns (type list)
         (description
          ("Canonical memory records in newest-first order.  Treat the"
            "returned records as immutable; field mutation does not"
            "retarget indexed lookup.  Use"
            "memory-store-replace-records! to install an edited stream.")))
        (effects state-read))
      (store-records store))

    (define (memory-store-replace-records! store records)
      "Replace STORE's records and rebuild its derived caches."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (records (type list)
          (description "Canonical memory records in newest-first order.")))
        (returns (type list)
         (description "The installed record list."))
        (effects state-write error))
      (let ((prepared-state
             (memory-prepared-state-from-records records)))
        (replace-memory-store-state!
         store
         records
         (vector-ref prepared-state 1)
         (vector-ref prepared-state 2)
         (vector-ref prepared-state 3)
         (vector-ref prepared-state 4)
         (vector-ref prepared-state 5)
         (vector-ref prepared-state 6))
        records))

    (define (missing-memory-ordered-index-record)
      "Return the absent-record marker for private index lookup."
      #f)

    (define (memory-store-entry/prepared store ordered-key)
      "Return STORE's private index entry for ORDERED-KEY, or #f."
      (memory-index-ref
       (store-ordered-index store)
       ordered-key
       missing-memory-ordered-index-record))

    (define (memory-store-ref/prepared store ordered-key)
      "Return STORE record for prepared ORDERED-KEY, or #f."
      (let ((entry (memory-store-entry/prepared store ordered-key)))
        (if entry (vector-ref entry 0) #f)))

    (define (memory-store-ref store scope key)
      "Return a memory record from STORE by SCOPE and KEY, or #f."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to search."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (key . "Memory key datum."))
        (returns (type (or list boolean))
         (description "The matching memory record datum, or #f."))
        (effects state-read error))
      (let ((normalized-scope (normalize-scope scope)))
        (memory-store-ref/prepared
         store (memory-ordered-key normalized-scope key))))

    (define (optional-record-fields selected names)
      "Return optional fields named by NAMES from SELECTED fields."
      (let loop ((rest names) (fields '()))
        (if (null? rest)
            (reverse fields)
            (let ((value (selected-field selected (car rest) #f)))
              (loop (cdr rest)
                    (if value
                        (cons (list (car rest) value) fields)
                        fields))))))

    (define (make-memory-record store scope key kind datum existing)
      "Build a canonical Scheme-readable memory record."
      (if (not (finite-proper-list? datum))
          (error "memory payload must be a finite proper list" datum))
      (let* ((datum-fields
              (if (and (pair? datum) (eq? (car datum) 'memory))
                  (cdr datum)
                  datum))
             (selected
              (select-finite-fields
               datum-fields
               '(tags value source confidence memory-class importance
                      cites supersedes receipt accessed local-only
                      disclosure)))
             (existing-fields
              (and existing
                   (if (and (pair? existing)
                            (eq? (car existing) 'memory))
                       (cdr existing)
                       existing)))
             (existing-selected
              (if existing-fields
                  (begin
                    (if (not (finite-proper-list? existing-fields))
                        (error
                         "memory fields must be a finite proper list"
                         existing))
                    (select-finite-fields
                     existing-fields '(id created-at)))
                  '()))
             (sequence (next-sequence store))
             (id (if existing
                     (selected-field existing-selected 'id #f)
                     key))
             (created-at
              (if existing
                  (selected-field existing-selected 'created-at #f)
                  (integer-datum sequence)))
             (tags (selected-field selected 'tags '()))
             (value (selected-field selected 'value datum))
             (source (selected-field selected 'source '()))
             (confidence (selected-field selected 'confidence 'unknown))
             (memory-class
              (normalize-memory-class
               (selected-field
                selected 'memory-class (default-memory-class kind))))
             (importance
              (selected-field selected 'importance (integer-datum 1))))
        (append
         (list 'memory
               (list 'id id)
               (list 'scope scope)
               (list 'key key)
               (list 'kind kind)
               (list 'memory-class memory-class)
               (list 'tags tags)
               (list 'value value)
               (list 'source source)
               (list 'confidence confidence)
               (list 'importance importance)
               (list 'created-at created-at)
               (list 'updated-at (integer-datum sequence)))
         (optional-record-fields
          selected
          '(cites supersedes receipt accessed local-only disclosure)))))

    (define (append-memory-record!
             store record ordered-key sidecar)
      "Append RECORD and atomically update current-live derived indexes."
      (let ((descriptor-index (store-descriptor-index store)))
        (define (intern key)
          (call-with-values
              (lambda ()
                (memory-descriptor-index-intern descriptor-index key))
            (lambda (canonical next-index)
              (set! descriptor-index next-index)
              canonical)))
        (define (intern-tag-vector tags)
          (let* ((length (vector-length tags))
                 (copy (make-vector length #f)))
            (let loop ((index 0))
              (if (= index length)
                  copy
                  (begin
                    (vector-set! copy index (intern (vector-ref tags index)))
                    (loop (+ index 1)))))))
        (define (intern-live-sidecar value live-key)
          (let* ((raw-id (memory-key-sidecar-id-key value))
                 (id-key
                  (if (memory-index-key=? live-key raw-id)
                      live-key
                      (intern raw-id)))
                 (kind-key (intern (memory-key-sidecar-kind-key value)))
                 (tag-keys
                  (intern-tag-vector
                   (memory-key-sidecar-tag-keys value))))
            (vector live-key
                    id-key
                    #f
                    kind-key
                    tag-keys
                    (memory-key-sidecar-flags value))))
        (let* ((ordinal (+ (store-next-ordinal store) 1))
               (sequence (memory-record-sequence record))
               (next-id (max (store-next-id store) sequence))
               (ordered-index (store-ordered-index store))
               (order-indexes (store-order-indexes store))
               (access-index (store-access-index store)))
          (cond
           ((memory-key-sidecar-access? sidecar)
            (let* ((target-key
                    (intern
                     (memory-key-sidecar-access-target-key sidecar)))
                   (previous-access
                    (memory-index-ref
                     access-index target-key (lambda () 0)))
                   (latest-access (max previous-access sequence))
                   (next-access-index
                    (memory-index-set access-index target-key latest-access)))
              (replace-memory-store-state!
               store
               (cons record (store-records store))
               next-id
               ordinal
               ordered-index
               order-indexes
               next-access-index
               descriptor-index)))
           (else
            (let* ((live-key
                    (intern
                     (if ordered-key
                         ordered-key
                         (memory-key-sidecar-live-key sidecar))))
                   (previous
                    (memory-index-ref ordered-index live-key (lambda () #f)))
                   (without-ordered
                    (if previous
                        (memory-index-delete ordered-index live-key)
                        ordered-index))
                   (without-orders
                    (if previous
                        (memory-order-index-remove order-indexes previous)
                        order-indexes)))
              (if (memory-key-sidecar-tombstone? sidecar)
                  (replace-memory-store-state!
                   store
                   (cons record (store-records store))
                   next-id
                   ordinal
                   without-ordered
                   without-orders
                   access-index
                   descriptor-index)
                  (let* ((canonical-sidecar
                          (intern-live-sidecar
                           (memory-key-sidecar-with-keys
                            sidecar
                            live-key
                            (memory-key-sidecar-id-key sidecar)
                            #f)
                           live-key))
                         (entry
                          (make-memory-live-entry
                           record
                           live-key
                           canonical-sidecar
                           ordinal)))
                    (replace-memory-store-state!
                     store
                     (cons record (store-records store))
                     next-id
                     ordinal
                     (memory-index-set without-ordered live-key entry)
                     (memory-order-index-set without-orders entry)
                     access-index
                     descriptor-index))))))
        record)))

    (define (append-existing-memory-record/prepared! store record prepare)
      "Replay RECORD into STORE using session-local PREPARE."
      (let* ((scope (normalize-scope (field-value record 'scope)))
             (raw-key (memory-record-key record))
             (raw-id (memory-record-id record))
             (live-key (prepare scope raw-key))
             (id-key
              (if (eq? raw-key raw-id)
                  live-key
                  (prepare scope raw-id)))
             (access-key
              (and (memory-record-access? record)
                   (prepare scope (field-value record 'accessed))))
             (sidecar
              (make-memory-key-sidecar/prepared
               prepare
               scope record live-key id-key access-key #f)))
        (append-memory-record!
         store record (and (not access-key) live-key) sidecar)))

    (define (append-existing-memory-record! store record)
      "Replay canonical RECORD into STORE's private derived indexes."
      (call-with-memory-index-key-session
       (lambda (prepare)
         (append-existing-memory-record/prepared! store record prepare))))

    (define (memory-store-put! store scope key datum)
      "Store DATUM under KEY in SCOPE and return its memory record."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (key . "Memory key datum.")
         (datum (type list)
          (description
            ("Memory payload or field list as Scheme-readable data."))))
        (returns (type list)
         (description "The stored memory record datum."))
        (effects state-write error))
      (let ((normalized-scope (normalize-scope scope)))
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let* ((ordered-key (prepare normalized-scope key))
                  (existing-entry
                   (memory-store-entry/prepared store ordered-key))
                  (existing
                   (and existing-entry (vector-ref existing-entry 0)))
                  (id-key
                   (if existing-entry
                       (memory-key-sidecar-id-key
                        (vector-ref existing-entry 2))
                       ordered-key))
                  (record
                   (make-memory-record
                    store normalized-scope key 'datum datum existing)))
             (append-memory-record!
              store
              record
              ordered-key
              (make-memory-key-sidecar/prepared
               prepare
               normalized-scope
               record
               ordered-key
               id-key
               #f
               #t)))))))

    (define (make-memory-tombstone store scope key record)
      "Build a tombstone event for RECORD."
      (make-memory-record
       store
       scope
       key
       'memory-tombstone
       (list (list 'memory-class 'working)
             (list 'value 'tombstone)
             (list 'source (list 'memory-delete key))
             (list 'confidence 'high)
             (list 'supersedes (list (memory-record-id record))))
       #f))

    (define (memory-store-delete! store scope key)
      "Delete memory KEY in SCOPE and return the deleted record, or #f."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (key . "Memory key datum."))
        (returns (type (or list boolean))
         (description
          ("The deleted memory record datum, or #f when no record"
            "matched.")))
        (effects state-write error))
      (let ((normalized-scope (normalize-scope scope)))
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let* ((ordered-key (prepare normalized-scope key))
                  (record
                   (memory-store-ref/prepared store ordered-key)))
             (if record
                 (let ((tombstone
                        (make-memory-tombstone
                         store normalized-scope key record)))
                   (append-memory-record!
                    store
                    tombstone
                    ordered-key
                    (make-memory-key-sidecar/prepared
                     prepare
                     normalized-scope
                     tombstone
                     ordered-key
                     ordered-key
                     #f
                     #t))))
             record)))))

    (define (memory-store-add! store scope kind datum)
      "Add DATUM as generated KIND memory in SCOPE and return the record."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (kind (type symbol)
          (description "Memory kind symbol."))
         (datum (type list)
          (description
            ("Memory payload or field list as Scheme-readable data."))))
        (returns (type list)
         (description "The generated memory record datum."))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (sequence (+ (store-next-id store) 1))
             (id (generated-id sequence))
             (record
              (make-memory-record
               store normalized-scope id kind datum #f)))
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let ((ordered-key (prepare normalized-scope id)))
             (append-memory-record!
              store
              record
              ordered-key
              (make-memory-key-sidecar/prepared
               prepare
               normalized-scope
               record
               ordered-key
               ordered-key
               #f
               #t)))))))

    (define (memory-order-index-newest index)
      "Return INDEX values in newest-first ordinal order."
      (memory-index-fold
       (lambda (ordinal entry newest) (cons entry newest))
       '()
       index))

    (define (memory-order-index-newest/limit index limit)
      "Return at most LIMIT newest values by the cheaper bounded traversal."
      (letrec
          ((predecessors
            (lambda (key remaining reversed)
              (if (<= remaining 0)
                  (reverse reversed)
                  (call-with-values
                      (lambda ()
                        (memory-index-key-predecessor
                         index key (lambda () (values #f #f))))
                    (lambda (previous-key entry)
                      (if previous-key
                          (predecessors
                           previous-key
                           (- remaining 1)
                           (cons entry reversed))
                          (reverse reversed))))))))
        (define (prefix values remaining reversed)
          (if (or (<= remaining 0) (null? values))
              (reverse reversed)
              (prefix
               (cdr values) (- remaining 1) (cons (car values) reversed))))
        (define (ceiling-log2-plus-one size)
          (let loop ((power 1) (height 0))
            (if (>= power (+ size 1))
                height
                (loop (* power 2) (+ height 1)))))
        (let* ((size (memory-index-size index))
               (height (ceiling-log2-plus-one size)))
          (cond
           ((<= limit 0) '())
           ((< (* limit height) size)
            (call-with-values
                (lambda ()
                  (memory-index-max index (lambda () (values #f #f))))
              (lambda (key entry)
                (if key
                    (cons entry (predecessors key (- limit 1) '()))
                    '()))))
           (else
            (prefix (memory-order-index-newest index) limit '()))))))

    (define (memory-scope-live-entries store scope . maybe-limit)
      "Return SCOPE's current live entries in newest-first order."
      (let ((index
             (memory-order-index-ref
              (store-order-indexes store) (normalize-scope scope))))
        (if (null? maybe-limit)
            (memory-order-index-newest index)
            (memory-order-index-newest/limit
             index (integer-value (car maybe-limit))))))

    (define (merge-memory-live-entries left right)
      "Merge newest-first live entry lists LEFT and RIGHT."
      (letrec
          ((prepend-reversed
            (lambda (reversed tail)
              (let loop ((rest reversed) (result tail))
                (if (null? rest)
                    result
                    (loop (cdr rest) (cons (car rest) result)))))))
        (let loop ((left-rest left) (right-rest right) (merged '()))
          (cond
           ((null? left-rest)
            (prepend-reversed merged right-rest))
           ((null? right-rest)
            (prepend-reversed merged left-rest))
           ((> (memory-live-entry-ordinal (car left-rest))
               (memory-live-entry-ordinal (car right-rest)))
            (loop (cdr left-rest)
                  right-rest
                  (cons (car left-rest) merged)))
           (else
            (loop left-rest
                  (cdr right-rest)
                  (cons (car right-rest) merged)))))))

    (define (memory-all-live-entries store)
      "Return every current live entry in newest-first stream order."
      (merge-memory-live-entries
       (memory-scope-live-entries store 'instance)
       (merge-memory-live-entries
        (memory-scope-live-entries store 'session)
        (memory-scope-live-entries store 'project))))

    (define (memory-live-snapshot store entries . maybe-access?)
      "Return aligned records and query projections for live ENTRIES."
      (let* ((include-access?
              (and (not (null? maybe-access?)) (car maybe-access?)))
             (refresh-security?
              (and (pair? maybe-access?)
                   (pair? (cdr maybe-access?))
                   (cadr maybe-access?)))
             (fast?
              (and include-access?
                   (consent-identity-map-fast-backend?)))
             (known-access
              (and fast? (consent-make-identity-map)))
             (access-empty?
              (or (not include-access?)
                  (memory-index-empty? (store-access-index store))))
             (absent (vector 'absent)))
        (define (selection-sidecar entry)
          (let* ((sidecar (memory-live-entry-sidecar entry))
                 (flags
                  (if (memory-record-redaction-sensitive?
                       (memory-live-entry-record entry))
                      memory-sidecar-redaction-flag
                      0)))
            (if (= flags (memory-key-sidecar-flags sidecar))
                sidecar
                (vector
                 (memory-key-sidecar-live-key sidecar)
                 (memory-key-sidecar-id-key sidecar)
                 #f
                 (memory-key-sidecar-kind-key sidecar)
                 (memory-key-sidecar-tag-keys sidecar)
                 flags))))
        (define (access-sequence entry)
          (if access-empty?
              0
              (let ((id-key (memory-live-entry-id-key entry)))
                (if fast?
                    (let ((known
                           (consent-identity-map-ref
                            known-access id-key absent)))
                      (if (eq? known absent)
                          (let ((sequence
                                 (memory-index-ref
                                  (store-access-index store)
                                  id-key
                                  (lambda () 0))))
                            (consent-identity-map-set!
                             known-access id-key sequence)
                            sequence)
                          known))
                    (if (memory-index-key-bounded-comparison? id-key)
                        (memory-index-ref
                         (store-access-index store)
                         id-key
                         (lambda () 0))
                        (error
                         (string-append
                          "unbounded access projection requires fast "
                          "identity map")
                         id-key))))))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (let loop ((rest entries) (records '()) (projections '()))
             (if (null? rest)
                 (vector (reverse records) (reverse projections))
                 (let ((entry (car rest)))
                   (loop
                    (cdr rest)
                    (cons (memory-live-entry-record entry) records)
                    (cons
                     (vector
                      (if refresh-security?
                          (selection-sidecar entry)
                          (memory-live-entry-sidecar entry))
                      (access-sequence entry))
                     projections))))))
         (lambda ()
           (if known-access
               (consent-identity-map-release! known-access))))))

    (define (memory-store-known-key store scope key)
      "Return STORE's canonical descriptor for SCOPE/KEY, or #f."
      (let ((prepared (memory-ordered-key scope key)))
        (if (memory-index-key-bounded-comparison? prepared)
            prepared
            (memory-descriptor-index-ref
             (store-descriptor-index store) prepared))))

    (define (memory-record-match-flags-in-scope
             records query)
      "Return QUERY equality flags aligned with live RECORDS."
      (map (lambda (record) (equal? query record)) records))

    (define (memory-find-projection store records scope query)
      "Prepare QUERY without exposing record identity fields to native code."
      (cond
       ((string? query)
        (vector (string-copy query) #f #f))
       ((symbol? query)
        (vector
         (string-copy (symbol->string query))
         (memory-store-known-key store scope query)
         #f))
       (else
        (vector
         #f
         #f
         (memory-record-match-flags-in-scope records query)))))

    (define (memory-query-terms query)
      "Return QUERY's relevance terms with legacy list expansion."
      (if (list? query) query (list query)))

    (define (memory-query-term-projection
             store prepare term bounded-only?)
      "Return detached text and per-scope identity projections for TERM."
      (let ((try-prepare
             (lambda (scope)
               (let ((prepared
                      (guard (condition (else #f))
                        (prepare scope term))))
                 (if (not prepared)
                     #f
                     (begin
                       (if (and bounded-only?
                                (not
                                 (memory-index-key-bounded-comparison?
                                  prepared)))
                           (error
                            (string-append
                             "unbounded memory query term requires fast "
                             "identity map")
                            term))
                       (memory-descriptor-index-ref
                        (store-descriptor-index store) prepared)))))))
        (vector
         (cond
          ((string? term) (string-copy term))
          ((symbol? term) (string-copy (symbol->string term)))
          (else #f))
         (list->vector
          (map try-prepare consent-memory-scopes)))))

    (define (memory-select-query-projection store query)
      "Return QUERY plus source-prepared relevance term projections."
      (let* ((fast? (consent-identity-map-fast-backend?))
             (known (and fast? (consent-make-identity-map)))
             (absent (vector 'absent)))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (call-with-memory-index-key-session
            (lambda (prepare)
              (define (projection term)
                (if fast?
                    (let ((cached
                           (consent-identity-map-ref known term absent)))
                      (if (eq? cached absent)
                          (let ((value
                                 (memory-query-term-projection
                                  store prepare term #f)))
                            (consent-identity-map-set! known term value)
                            value)
                          cached))
                    (memory-query-term-projection
                     store prepare term #t)))
              (vector
               query
               (list->vector
                (map projection (memory-query-terms query)))))))
         (lambda ()
           (if known (consent-identity-map-release! known))))))

    (define (memory-store-find store scope query)
      "Return SCOPE records matching QUERY."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (query . "Query datum matched against records."))
        (returns (type (list-of list))
         (description "List of matching memory record datums in SCOPE."))
        (effects state-read error))
      (let ((normalized-scope (normalize-scope scope)))
        (let* ((snapshot
                (memory-live-snapshot
                 store
                 (memory-scope-live-entries store normalized-scope)))
               (records (vector-ref snapshot 0)))
          (memory-query-find
           records
           (vector-ref snapshot 1)
           normalized-scope
           (memory-find-projection
            store records normalized-scope query)))))

    (define (memory-store-by-tag store scope tag)
      "Return SCOPE records tagged with TAG."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (tag . "Tag datum to match."))
        (returns (type (list-of list))
         (description "List of memory record datums whose tags include TAG."))
        (effects state-read error))
      (let* ((normalized-scope (normalize-scope scope))
             (tag-key
              (memory-store-known-key store normalized-scope tag)))
        (if (not tag-key)
            '()
            (let ((snapshot
                   (memory-live-snapshot
                    store
                    (memory-scope-live-entries store normalized-scope))))
              (memory-query-by-tag
               (vector-ref snapshot 0)
               (vector-ref snapshot 1)
               normalized-scope
               tag-key)))))

    (define (memory-store-recent store scope count)
      "Return COUNT newest memory records in SCOPE."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (count (type exact-integer)
          (description
           ("Exact nonnegative integer or Consent Scheme integer datum"
             "limiting result size."))))
        (returns (type (list-of list))
         (description "At most COUNT newest memory record datums in SCOPE."))
        (effects state-read error))
      (let* ((normalized-scope (normalize-scope scope))
             (limit (integer-value count))
             (snapshot
              (memory-live-snapshot
               store
               (memory-scope-live-entries
                store normalized-scope (max 0 limit)))))
        (memory-query-recent
         (vector-ref snapshot 0)
         (vector-ref snapshot 1)
         normalized-scope
         limit)))

    (define (memory-store-access! store memory-id scope context)
      "Append a logical-clock access event for MEMORY-ID."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (memory-id . "Memory record id that was selected or inspected.")
         (scope (type symbol)
          (description "Memory scope symbol."))
         (context .
           "Prompt, task, or retrieval context that accessed memory."))
        (returns (type list)
         (description "The appended `memory-access` event record."))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (sequence (+ (store-next-id store) 1))
             (record
              (make-memory-record
               store
               normalized-scope
               (generated-id sequence)
               'memory-access
               (list (list 'memory-class 'working)
                     (list 'tags '(memory-access))
                     (list 'value (list 'accessed memory-id))
                     (list 'source (list 'retrieval context))
                     (list 'confidence 'high)
                     (list 'accessed memory-id))
               #f)))
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let ((live-key
                  (prepare normalized-scope (memory-record-key record)))
                 (access-key (prepare normalized-scope memory-id)))
             (append-memory-record!
              store
              record
              #f
              (make-memory-key-sidecar/prepared
               prepare
               normalized-scope
               record
               live-key
               live-key
               access-key
               #t)))))))

    (define (memory-store-reflect! store scope kind datum cites receipt
      loop-id)
      "Append a gated reflection or synthesis datum with provenance."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (kind (type symbol)
          (description "Reflection or synthesis memory kind."))
         (datum (type list)
          (description "Model-authored reflection payload admitted as data."))
         (cites (type list)
          (description "Base memory ids this insight cites."))
         (receipt (type symbol)
          (description "Task receipt or stop reason that gated the write."))
         (loop-id . "Deterministic loop step id admitting the reflection."))
        (returns (type list)
         (description "The appended reflection memory record."))
        (effects state-write error))
      (if (not (finite-proper-list? datum))
          (error "memory payload must be a finite proper list" datum))
      (let* ((normalized-scope (normalize-scope scope))
             (sequence (+ (store-next-id store) 1))
             (record
              (make-memory-record
               store
               normalized-scope
               (generated-id sequence)
               kind
               (append
                (list (list 'memory-class 'semantic)
                      (list 'source (list 'deterministic-loop loop-id))
                      (list 'cites cites)
                      (list 'receipt receipt))
                datum)
               #f)))
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let ((ordered-key
                  (prepare normalized-scope (memory-record-key record))))
             (append-memory-record!
              store
              record
              ordered-key
              (make-memory-key-sidecar/prepared
               prepare
               normalized-scope
               record
               ordered-key
               ordered-key
               #f
               #t)))))))

    (define (memory-store-select store query policy context)
      "Return a deterministic memory-selection receipt for QUERY."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (query (type (or symbol string list))
          (description "Tag, keyword, or list of relevance terms."))
         (policy (type retrieval-policy)
          (description "Printable retrieval policy record."))
         (context (type retrieval-context)
          (description "Request scope, trust, and logical-clock context.")))
        (returns (type memory-selection)
         (description
          ("A replayable selection receipt with selected records,"
            "per-candidate scores, filter reasons, and the cutoff.")))
        (effects state-read error))
      (let* ((trust (field-value/default context 'trust 'local))
             (refresh-security?
              (or (eq? trust 'remote)
                  (eq? trust 'public)
                  (eq? trust 'lower-trust)))
             (snapshot
             (memory-live-snapshot
              store
              (memory-all-live-entries store)
              #t
              refresh-security?)))
        (memory-query-select
         (vector-ref snapshot 0)
         (vector-ref snapshot 1)
         (store-next-id store)
         (memory-select-query-projection store query)
         policy
         context)))

    (define (tagged-record? datum tag)
      "Return #t when DATUM is a tagged list with TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (memory-selection? datum)
      "Return #t when DATUM is a memory-selection receipt."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
           "#t when DATUM is tagged as a memory-selection receipt."))
        (effects pure))
      (tagged-record? datum 'memory-selection))

    (define (memory-selection-records selection)
      "Return selected records from memory-selection SELECTION."
      #((parameters
         (selection (type memory-selection)
          (description "Memory selection receipt.")))
        (returns (type list)
         (description "Selected memory records safe for the request context."))
        (effects pure))
      (field-value/default selection 'records '()))

    (define (memory-selection-candidates selection)
      "Return candidate receipts from memory-selection SELECTION."
      #((parameters
         (selection (type memory-selection)
          (description "Memory selection receipt.")))
        (returns (type list)
         (description "Per-candidate ranking or filtering receipts."))
        (effects pure))
      (field-value/default selection 'candidates '()))

    (define (memory-selection-cutoff selection)
      "Return cutoff from memory-selection SELECTION."
      #((parameters
         (selection (type memory-selection)
          (description "Memory selection receipt.")))
        (returns . "The policy cutoff datum used for selection.")
        (effects pure))
      (field-value/default selection 'cutoff 0))

    (define (memory-storage-rules scope private-file project-root tracked-file
                                  tracked-enabled)
      "Return safe public storage rules for SCOPE."
      #((parameters
         (scope (type symbol)
          (description "Memory scope symbol."))
         (private-file (type string)
          (description "Private-local persistence path."))
         (project-root (type (or string boolean))
          (description "Project root for project scope, or #f."))
         (tracked-file (type (or string boolean))
          (description "Tracked project memory file, or #f."))
         (tracked-enabled (type boolean)
          (description "Whether tracked project memory is enabled.")))
        (returns (type list)
         (description "Public memory-storage rule datum."))
        (effects pure error))
      (append
       (list 'memory-storage
             (list 'scope (normalize-scope scope))
             (list 'mode 'private-local)
             (list 'private-file private-file))
       (if project-root
           (list
            (list 'project-root project-root)
            (list 'tracked-file tracked-file)
            (list 'tracked-enabled tracked-enabled)
            (list 'public-repository-safe #t))
           '())))

    (define (memory-scope-datum scope subject storage records)
      "Return inspectable agent-memory SCOPE datum."
      #((parameters
         (scope (type symbol)
          (description "Memory scope symbol."))
         (subject (type (or symbol boolean))
          (description "Session id for session scope, or #f."))
         (storage (type (or list boolean))
          (description "Storage rules for project scope, or #f."))
         (records (type list)
          (description "Canonical memory records for SCOPE.")))
        (returns (type list)
         (description "Inspectable agent-memory scope datum."))
        (effects pure error))
      (let ((normalized-scope (normalize-scope scope)))
        (append
         (list 'agent-memory
               (list 'scope normalized-scope))
         (cond
          ((and (eq? normalized-scope 'session) subject)
           (list (list 'session subject)))
          ((and (eq? normalized-scope 'project) storage)
           (list (list 'storage storage)))
          (else '()))
         (list (list 'records records)))))))
