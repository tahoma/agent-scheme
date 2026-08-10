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
          consent-datum-heap-owner-set!
          consent-datum-heap-mutation-hook-set!
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
          consent-make-datum-object-map
          consent-datum-object-map-ref
          consent-datum-object-map-set!
          consent-datum-object-map-release!
          consent-datum-object-map-probe-count
          call-with-consent-datum-object-map
          consent-call-with-datum-construction
          consent-datum-same?
          consent-datum-make-internal-slots
          consent-datum-internal-slot-ref
          consent-datum-internal-slot-set!
          consent-datum-pair?
          consent-datum-cons
          consent-datum-car
          consent-datum-cdr
          consent-datum-set-car!
          consent-datum-set-cdr!
          consent-datum-list-copy
          consent-datum-string?
          consent-datum-string-from-host
          consent-datum-string->host
          consent-datum-make-string
          consent-datum-string-copy-range
          consent-datum-string-length
          consent-datum-string-ref-host
          consent-datum-string-set-host!
          consent-datum-vector?
          consent-datum-vector-from-host
          consent-datum-vector-from-host-elements
          consent-datum-vector->host
          consent-datum-make-vector
          consent-datum-vector-length
          consent-datum-vector-ref
          consent-datum-vector-set!
          consent-datum-bytevector?
          consent-datum-bytevector-from-host
          consent-datum-bytevector->host
          consent-datum-make-bytevector
          consent-datum-bytevector-length
          consent-datum-bytevector-u8-ref
          consent-datum-bytevector-u8-set!
          consent-datum-import
          consent-datum-export)
  (import (scheme base)
          (consent identity-map))
  (begin
    ;; Process-local heap identifiers distinguish otherwise equal ordinals.
    (define next-datum-heap-id 0)

    ;; A heap owns object-id allocation and the future mutation barrier.
    (define-record-type <consent-datum-heap>
      (make-datum-heap-record id generation owner next-id mutation-hook)
      consent-datum-heap?
      (id consent-datum-heap-id)
      (generation consent-datum-heap-generation)
      (owner consent-datum-heap-owner raw-set-datum-heap-owner!)
      (next-id datum-heap-next-id set-datum-heap-next-id!)
      (mutation-hook datum-heap-mutation-hook
                     set-datum-heap-mutation-hook!))

    ;; One opaque record is the semantic identity for every compound kind.
    ;; STORAGE is deliberately private: a borrowed host may accelerate access
    ;; with native containers, but host identity is never the language answer.
    (define-record-type <consent-datum-object>
      (make-datum-object-record heap heap-id id generation owner kind storage
                                mutable? revision traversal map-entry
                                source-metadata)
      consent-datum-object?
      (heap datum-object-heap)
      (heap-id consent-datum-object-heap-id)
      (id consent-datum-object-id)
      (generation consent-datum-object-generation)
      (owner consent-datum-object-owner raw-set-datum-object-owner!)
      (kind consent-datum-object-kind)
      (storage datum-object-storage raw-set-datum-object-storage!)
      (mutable? consent-datum-object-mutable?)
      (revision consent-datum-object-revision
                set-datum-object-revision!)
      (traversal consent-datum-object-traversal
                 raw-set-datum-object-traversal!)
      ;; Call-scoped graph maps use a distinct private intrusive header. This
      ;; must never alias public traversal metadata: nested runtime traversals
      ;; save and restore one another through this slot.
      (map-entry datum-object-map-entry raw-set-datum-object-map-entry!)
      ;; Provenance is opaque to this owner. One current metadata slot follows
      ;; the object's lifetime without retaining replacement history or a
      ;; process-global identity-table entry.
      (source-metadata consent-datum-object-source-metadata
                       raw-set-datum-object-source-metadata!))

    (define (default-mutation-hook heap object operation slot old new)
      "Permit one mutation when no branch-aware barrier is installed."
      #t)

    (define (consent-make-datum-heap)
      "Return a fresh portable compound datum heap."
      #((parameters)
        (returns (type datum-heap)
         (description "Fresh heap with its own object-id domain."))
        (effects allocation state-write))
      (let ((id next-datum-heap-id))
        (set! next-datum-heap-id (+ id 1))
        (make-datum-heap-record id 0 id 0 default-mutation-hook)))

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
      (raw-set-datum-heap-owner! heap owner)
      heap)

    (define (consent-datum-heap-mutation-hook-set! heap hook)
      "Install HEAP's narrow mutation HOOK and return HEAP."
      #((parameters
         (heap (type datum-heap) (description "Heap to configure."))
         (hook (type procedure)
          (description
           ("Procedure receiving heap, object, operation, slot, old,"
             "and new before each visible mutation."))))
        (returns (type datum-heap) (description "Updated HEAP."))
        (effects state-write error))
      (if (not (consent-datum-heap? heap))
          (error
           "consent-datum-heap-mutation-hook-set!: expected heap"
           heap))
      (if (not (procedure? hook))
          (error
           "consent-datum-heap-mutation-hook-set!: expected procedure"
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
      (raw-set-datum-object-source-metadata! object metadata)
      object)

    (define (allocate-datum-object heap kind storage mutable?)
      "Allocate one KIND object backed privately by STORAGE in HEAP."
      (if (not (consent-datum-heap? heap))
          (error "owned datum allocation expected heap" heap))
      (let ((id (datum-heap-next-id heap)))
        (set-datum-heap-next-id! heap (+ id 1))
        (make-datum-object-record
         heap
         (consent-datum-heap-id heap)
         id
         (consent-datum-heap-generation heap)
         (consent-datum-heap-owner heap)
         kind
         storage
         mutable?
         0
         #f
         #f
         #f)))

    ;; Construction scopes are one-shot capabilities for trusted runtime
    ;; producers such as the reader.  A shell is unpublished while its
    ;; traversal slot names the active token, so construction fills cannot be
    ;; confused with language-visible mutation.  Owned traversal maps use the
    ;; separate map-entry field and therefore remain independent.
    (define datum-construction-uninitialized
      (vector 'consent-datum-construction-uninitialized))

    ;; Construction accounting must not be a host vector: traversal metadata
    ;; is intentionally observable as an opaque value, and exposing the fill
    ;; bitmap would let a capability callback forge shell completeness.
    (define-record-type <datum-construction-marker>
      (make-datum-construction-marker token states remaining object next)
      datum-construction-marker?
      (token datum-construction-marker-token)
      (states datum-construction-marker-states)
      (remaining datum-construction-marker-remaining
                 set-datum-construction-marker-remaining!)
      (object datum-construction-marker-object)
      (next datum-construction-marker-next))

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
            (state 'new))
        (define (active?)
          (eq? state 'active))

        (define (check-active operation)
          (if (not (active?))
              (error operation "construction scope is not active")))

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
          ;; Allocate bytevectors in their final representation.  Their
          ;; one-byte fill bitmap distinguishes an unfilled slot from byte
          ;; zero without retaining and later copying a second payload.
          (let* ((bytevector? (eq? kind 'bytevector))
                 (object
                  (allocate-datum-object
                   heap
                   kind
                   (if bytevector?
                       (make-bytevector length 0)
                       (make-vector
                        length datum-construction-uninitialized))
                   #t))
                 ;; A slot state is zero before fill, one after fill, and two
                 ;; after its one permitted datum-label fixup.
                 (marker
                  (make-datum-construction-marker
                   token
                   (make-bytevector length 0)
                   length
                   object
                   objects)))
            (raw-set-datum-object-traversal! object marker)
            ;; Link through the opaque marker instead of allocating one host
            ;; cons cell per compound merely to close the construction scope.
            (set! objects marker)
            object))

        (define (construction-marker object)
          "Return OBJECT's marker for this scope, or #f when it has none."
          (and (consent-datum-object? object)
               (eq? (datum-object-heap object) heap)
               (let ((marker (consent-datum-object-traversal object)))
                 (and (datum-construction-marker? marker)
                      (eq? (datum-construction-marker-token marker) token)
                      marker))))

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
            (let* ((storage (datum-object-storage object))
                   (bytevector?
                    (eq? (consent-datum-object-kind object) 'bytevector))
                   (length
                    (if bytevector?
                        (bytevector-length storage)
                        (vector-length storage))))
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
              (if bytevector?
                  (bytevector-u8-set! storage index value)
                  (vector-set! storage index value))
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
          (raw-set-datum-object-traversal! object #f))

        (define (sanitize-abandoned! object)
          "Make an escaped abandoned shell a valid inert owned datum."
          (let ((kind (consent-datum-object-kind object))
                (storage (datum-object-storage object)))
            (if (not (eq? kind 'bytevector))
                (let ((replacement (if (eq? kind 'string) #\null #f)))
                  (let loop ((index 0))
                    (if (< index (vector-length storage))
                        (begin
                          (if (eq? (vector-ref storage index)
                                   datum-construction-uninitialized)
                              (vector-set! storage index replacement))
                          (loop (+ index 1)))))))
            (raw-set-datum-object-traversal! object #f)))

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
                          (set! state 'closed)
                          (error
                           "datum construction ended with unfilled slots"
                           object
                           remaining)))))
                    (begin
                      (sanitize-all!)
                      (set! state 'closed))))))

        ;; Treat the scope as one-shot.  A continuation that leaves during
        ;; construction closes it; re-entry then fails instead of reviving raw
        ;; fill authority after objects could have escaped.
        (dynamic-wind
         (lambda ()
           (if (not (eq? state 'new))
               (error
                "datum construction continuation cannot be re-entered"))
           (set! state 'active))
         (lambda ()
           (let ((result (procedure make-shell fill-slot! fixup-slot!)))
             (set! state 'complete)
             result))
         (lambda ()
           (close! (eq? state 'complete))))))

    (define (object-kind? value kind)
      "Report whether VALUE is an owned object of KIND."
      (and (consent-datum-object? value)
           (eq? (consent-datum-object-kind value) kind)))

    (define (consent-datum-same? left right)
      "Report whether LEFT and RIGHT denote the same owned object identity."
      #((parameters
         (left . "First candidate object.")
         (right . "Second candidate object."))
        (returns (type boolean)
         (description "Whether both candidates have one owned identity."))
        (effects pure))
      (and (consent-datum-object? left)
           (consent-datum-object? right)
           (= (consent-datum-object-heap-id left)
              (consent-datum-object-heap-id right))
           (= (consent-datum-object-id left)
              (consent-datum-object-id right))))

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
      (allocate-datum-object heap kind (list->vector values) #t))

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
      (let* ((storage (datum-object-storage object))
             (old (vector-ref storage index)))
        (mutate!
         heap object operation index old value
         (lambda () (vector-set! storage index value)))))

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

    (define (mutate! heap object operation slot old new setter)
      "Route one object mutation through HEAP before calling SETTER."
      (if (not (consent-datum-object-mutable? object))
          (error "attempt to mutate an immutable compound datum" object))
      ((datum-heap-mutation-hook heap)
       heap object operation slot old new)
      (setter)
      (set-datum-object-revision!
       object
       (+ 1 (consent-datum-object-revision object))))

    (define (consent-datum-pair? value)
      "Report whether VALUE is an owned pair."
      #((parameters (value . "Candidate value."))
        (returns (type boolean) (description "Whether VALUE is a pair."))
        (effects pure))
      (object-kind? value 'pair))

    (define (make-pair-placeholder heap mutable?)
      "Allocate an uninitialized pair used while importing cyclic graphs."
      (allocate-datum-object heap 'pair (vector #f #f) mutable?))

    (define (initialize-pair! pair head tail)
      "Initialize fresh PAIR without reporting construction as mutation."
      (vector-set! (datum-object-storage pair) 0 head)
      (vector-set! (datum-object-storage pair) 1 tail)
      pair)

    (define (consent-datum-cons heap head tail)
      "Return a fresh owned pair in HEAP with HEAD and TAIL."
      #((parameters
         (heap (type datum-heap) (description "Owning heap."))
         (head . "Initial car value.")
         (tail . "Initial cdr value."))
        (returns (type pair) (description "Fresh mutable owned pair."))
        (effects allocation error))
      (initialize-pair! (make-pair-placeholder heap #t) head tail))

    (define (consent-datum-car pair)
      "Return owned PAIR's car."
      #((parameters (pair (type pair) (description "Pair to inspect.")))
        (returns (type any) (description "Stored car value."))
        (effects error))
      (if (not (consent-datum-pair? pair))
          (error "consent-datum-car: expected owned pair" pair))
      (vector-ref (datum-object-storage pair) 0))

    (define (consent-datum-cdr pair)
      "Return owned PAIR's cdr."
      #((parameters (pair (type pair) (description "Pair to inspect.")))
        (returns (type any) (description "Stored cdr value."))
        (effects error))
      (if (not (consent-datum-pair? pair))
          (error "consent-datum-cdr: expected owned pair" pair))
      (vector-ref (datum-object-storage pair) 1))

    (define (pair-set! heap pair slot value operation)
      "Set PAIR's SLOT to VALUE through the mutation gateway."
      (check-object heap pair 'pair operation)
      (let* ((storage (datum-object-storage pair))
             (old (vector-ref storage slot)))
        (mutate!
         heap pair operation slot old value
         (lambda () (vector-set! storage slot value)))))

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
            (let ((fast-one (consent-datum-cdr fast)))
              (if (not (consent-datum-pair? fast-one))
                  #f
                  (let ((slow-one (consent-datum-cdr slow))
                        (fast-two (consent-datum-cdr fast-one)))
                    (if (not (consent-datum-pair? fast-two))
                        #f
                        (if (consent-datum-same? slow-one fast-two)
                            (let entry ((left value)
                                        (right slow-one)
                                        (mu 0))
                              (if (consent-datum-same? left right)
                                  (let period
                                      ((cursor (consent-datum-cdr left))
                                       (period-length 1))
                                    (if (consent-datum-same? cursor left)
                                        (cons mu period-length)
                                        (period
                                         (consent-datum-cdr cursor)
                                         (+ period-length 1))))
                                  (entry
                                   (consent-datum-cdr left)
                                   (consent-datum-cdr right)
                                   (+ mu 1))))
                            (detect slow-one fast-two)))))))))

    (define (copy-acyclic-pair-spine value heap)
      "Copy VALUE's acyclic pair spine into HEAP."
      (let scan ((cursor value) (reversed-cars '()) (count 0))
        (if (consent-datum-pair? cursor)
            (scan
             (consent-datum-cdr cursor)
             (cons (consent-datum-car cursor) reversed-cars)
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
                (vector-set! cars index (consent-datum-car cursor))
                (collect (consent-datum-cdr cursor) (+ index 1)))))
        ;; Allocate every identity before installing edges. These private
        ;; initializers do not emit mutation hooks or increment revisions.
        (let allocate ((index 0))
          (if (< index count)
              (begin
                (vector-set!
                 copies index (make-pair-placeholder heap #t))
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
       heap 'string (host-string->string-storage string) #t))

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
      (allocate-datum-object heap 'string (make-vector length fill) #t))

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
          (allocate-datum-object heap 'string copy #t))))

    (define (consent-datum-string-length string)
      "Return owned STRING's length."
      #((parameters
         (string (type string) (description "Owned string to measure.")))
        (returns (type exact-non-negative-integer)
         (description "Number of characters in STRING."))
        (effects error))
      (if (not (consent-datum-string? string))
          (error "consent-datum-string-length: expected owned string" string))
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
      (let* ((storage (datum-object-storage string))
             (old (vector-ref storage index)))
        (mutate!
         heap string 'string-set! index old character
         (lambda () (vector-set! storage index character)))))

    (define (consent-datum-vector? value)
      "Report whether VALUE is an owned vector."
      #((parameters (value . "Candidate value."))
        (returns (type boolean) (description "Whether VALUE is a vector."))
        (effects pure))
      (object-kind? value 'vector))

    (define (make-vector-placeholder heap length mutable?)
      "Allocate an uninitialized owned vector for cyclic graph import."
      (allocate-datum-object heap 'vector (make-vector length #f) mutable?))

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
        (allocate-datum-object heap 'vector storage #t)))

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
      (allocate-datum-object heap 'vector (make-vector length fill) #t))

    (define (consent-datum-vector-length vector)
      "Return owned VECTOR's length."
      #((parameters
         (vector (type vector) (description "Owned vector to measure.")))
        (returns (type exact-non-negative-integer)
         (description "Number of elements in VECTOR."))
        (effects error))
      (if (not (consent-datum-vector? vector))
          (error "consent-datum-vector-length: expected owned vector" vector))
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
      (let* ((storage (datum-object-storage vector))
             (old (vector-ref storage index)))
        (mutate!
         heap vector 'vector-set! index old value
         (lambda () (vector-set! storage index value)))))

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
       heap 'bytevector (copy-host-bytevector bytevector) #t))

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
       heap 'bytevector (make-bytevector length fill) #t))

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
      (let* ((storage (datum-object-storage bytevector))
             (old (bytevector-u8-ref storage index)))
        (mutate!
         heap bytevector 'bytevector-u8-set! index old byte
         (lambda () (bytevector-u8-set! storage index byte)))))

    ;; A call-scoped owned-object map is an intrusive traversal mark, the same
    ;; mature pattern used by collectors and graph algorithms. Every owned
    ;; object supplies one private map-entry header, so lookup and insertion
    ;; take one header probe regardless of its stable integer IDs. A unique
    ;; map token distinguishes nested traversals.
    ;;
    ;; MAP is #(token touched-entry active?). ENTRY is
    ;; #(token value older newer object next-touched). The intrusive touched
    ;; chain avoids two host cons cells per first insertion. The two header
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
      "Return OBJECT's value in MAP, or DEFAULT after one header probe."
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
      ;; Read the current header once. An absent insertion reuses that same
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
              (vector-set! map 1 created))))
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
                    (loop next))))
            (vector-set! map 1 #f)))
      map)

    (define (consent-datum-object-map-probe-count map object)
      "Return the fixed number of object-header probes used by MAP lookup."
      #((parameters
         (map (type datum-object-map) (description "Map to inspect."))
         (object (type compound-datum)
          (description "Owned object whose header is probed.")))
        (returns (type exact-positive-integer)
         (description "The fixed object-header probe count."))
        (effects state-read error))
      (check-active-datum-object-map
       "consent-datum-object-map-probe-count:" map object)
      ;; Exercise the same real header path as REF; this diagnostic must not
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

    (define (host-seen-ref seen value)
      "Return host VALUE's graph copy in mutable registry SEEN, or #f."
      (consent-identity-map-ref seen value #f))

    (define (host-seen-set! seen value copy)
      "Record host VALUE's graph COPY in mutable registry SEEN."
      (consent-identity-map-set! seen value copy))

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
                 (car (cddr rest))))
            (absent-token (vector 'consent-datum-import-absent))
            (host-seen #f)
            (owned-seen #f))
        (define (import-host-ref item)
          "Return ITEM's imported host copy, or the private absent token."
          (if host-seen
              (consent-identity-map-ref host-seen item absent-token)
              absent-token))
        (define (import-host-set! item copy)
          "Memoize host ITEM as COPY, allocating the map on first use."
          (if (not host-seen)
              (set! host-seen (consent-make-identity-map)))
          (host-seen-set! host-seen item copy))
        (define (import-owned-ref item)
          "Return ITEM's cross-heap copy, or the private absent token."
          (if owned-seen
              (consent-datum-object-map-ref
               owned-seen item absent-token)
              absent-token))
        (define (import-owned-set! item copy)
          "Memoize owned ITEM as COPY, allocating the map on first use."
          (if (not owned-seen)
              (set! owned-seen (consent-make-datum-object-map)))
          (consent-datum-object-map-set! owned-seen item copy))
        ;; Work entries are #(tag source destination slot).  Visit entries use
        ;; tag zero and write into a private host vector.  Finish entries use
        ;; tag one and call COPY-SOURCE only after all outgoing edges have
        ;; been initialized.  This is an explicit DFS stack, so graph depth
        ;; does not consume the Scheme implementation's control stack.
        (dynamic-wind
         (lambda () #t)
         (lambda ()
          (let ((root (vector #f))
                (work '()))
          (define (push-visit! source destination slot)
            "Schedule SOURCE for delivery into DESTINATION at SLOT."
            (set! work
                  (cons (vector 0 source destination slot) work)))
          (define (push-finish! source copy)
            "Schedule one post-edge source metadata copy."
            (set! work (cons (vector 1 source copy 0) work)))
          (define (deliver! destination slot result)
            "Store one imported RESULT in its already-allocated parent."
            (vector-set! destination slot result))
          (define (accept-host-reuse! source destination slot)
            "Try host SOURCE's reuse hook and memoize an accepted target."
            (let ((candidate (reuse source absent-token)))
              (if (eq? candidate absent-token)
                  #f
                  (begin
                    (import-host-set! source candidate)
                    (deliver! destination slot candidate)
                    #t))))
          (define (accept-owned-reuse! source destination slot)
            "Try owned SOURCE's reuse hook and memoize an accepted target."
            (let ((candidate (reuse source absent-token)))
              (if (eq? candidate absent-token)
                  #f
                  (begin
                    (import-owned-set! source candidate)
                    (deliver! destination slot candidate)
                    #t))))
          (define (push-owned-vector-edges! source copy length)
            "Schedule SOURCE vector edges in ascending observation order."
            (let ((storage (datum-object-storage copy)))
              (let loop ((index (- length 1)))
                (if (>= index 0)
                    (begin
                      (push-visit!
                       (consent-datum-vector-ref source index)
                       storage
                       index)
                      (loop (- index 1)))))))
          (define (push-host-vector-edges! source copy length)
            "Schedule host SOURCE vector edges in ascending order."
            (let ((storage (datum-object-storage copy)))
              (let loop ((index (- length 1)))
                (if (>= index 0)
                    (begin
                      (push-visit! (vector-ref source index) storage index)
                      (loop (- index 1)))))))
          (define (start-owned-copy! source destination slot)
            "Allocate and schedule one cross-heap owned compound copy."
            (case (consent-datum-object-kind source)
              ((pair)
               (let ((copy
                      (make-pair-placeholder
                       heap (consent-datum-object-mutable? source))))
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)
                 (push-visit!
                  (consent-datum-cdr source)
                  (datum-object-storage copy)
                  1)
                 (push-visit!
                  (consent-datum-car source)
                  (datum-object-storage copy)
                  0)))
              ((string)
               (let ((copy
                      (allocate-datum-object
                       heap
                       'string
                       (copy-string-storage (datum-object-storage source))
                       (consent-datum-object-mutable? source))))
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)))
              ((bytevector)
               (let ((copy
                      (allocate-datum-object
                       heap
                       'bytevector
                       (copy-host-bytevector (datum-object-storage source))
                       (consent-datum-object-mutable? source))))
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)))
              ((vector)
               (let* ((length (consent-datum-vector-length source))
                      (copy
                       (make-vector-placeholder
                        heap
                        length
                        (consent-datum-object-mutable? source))))
                 (import-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)
                 (push-owned-vector-edges! source copy length)))
              (else
               (error
                "consent-datum-import: unsupported owned kind"
                source))))
          (define (start-host-copy! source destination slot)
            "Allocate and schedule one host compound copy into HEAP."
            (cond
             ((pair? source)
              (let ((copy (make-pair-placeholder heap #t)))
                (import-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)
                (push-visit!
                 (cdr source) (datum-object-storage copy) 1)
                (push-visit!
                 (car source) (datum-object-storage copy) 0)))
             ((string? source)
              (let ((copy (consent-datum-string-from-host heap source)))
                (import-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)))
             ((bytevector? source)
              (let ((copy
                     (consent-datum-bytevector-from-host heap source)))
                (import-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)))
             ((vector? source)
              (let* ((length (vector-length source))
                     (copy (make-vector-placeholder heap length #t)))
                (import-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)
                (push-host-vector-edges! source copy length)))))
          (define (visit-owned! source destination slot)
            "Deliver one owned SOURCE or schedule its cross-heap copy."
            (if (eq? heap (datum-object-heap source))
                (deliver! destination slot source)
                (let ((prior (import-owned-ref source)))
                  (cond
                   ((not (eq? prior absent-token))
                    (deliver! destination slot prior))
                   ((accept-owned-reuse! source destination slot))
                   (else
                    (start-owned-copy! source destination slot))))))
          (define (visit-host! source destination slot)
            "Deliver one host SOURCE or schedule its compound copy."
            (if (or (pair? source)
                    (string? source)
                    (bytevector? source)
                    (vector? source))
                (let ((prior (import-host-ref source)))
                  (cond
                   ((not (eq? prior absent-token))
                    (deliver! destination slot prior))
                   ((accept-host-reuse! source destination slot))
                   (else
                    (start-host-copy! source destination slot))))
                (deliver! destination slot (leaf source))))
          (push-visit! value root 0)
          (let loop ()
            (if (null? work)
                (vector-ref root 0)
                (let ((job (car work)))
                  (set! work (cdr work))
                  (if (= (vector-ref job 0) 0)
                      (let ((source (vector-ref job 1))
                            (destination (vector-ref job 2))
                            (slot (vector-ref job 3)))
                        (if (consent-datum-object? source)
                            (visit-owned! source destination slot)
                            (visit-host! source destination slot)))
                      (copy-source
                       (vector-ref job 2) (vector-ref job 1)))
                  (loop))))))
         (lambda ()
           (if owned-seen
               (consent-datum-object-map-release! owned-seen))))))))

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
            (host-seen #f))
        (define (export-owned-ref item)
          "Return owned ITEM's host copy, or the private absent token."
          (if owned-seen
              (consent-datum-object-map-ref
               owned-seen item absent-token)
              absent-token))
        (define (export-owned-set! item copy)
          "Memoize owned ITEM as COPY, allocating the map on first use."
          (if (not owned-seen)
              (set! owned-seen (consent-make-datum-object-map)))
          (consent-datum-object-map-set! owned-seen item copy))
        (define (export-host-ref item)
          "Return host ITEM's graph copy, or the private absent token."
          (if host-seen
              (consent-identity-map-ref
               host-seen item absent-token)
              absent-token))
        (define (export-host-set! item copy)
          "Memoize host ITEM as COPY, allocating the map on first use."
          (if (not host-seen)
              (set! host-seen (consent-make-identity-map)))
          (consent-identity-map-set! host-seen item copy))
        ;; Visit jobs use #(0 source destination slot).  Non-negative slots
        ;; address vectors; -1 and -2 address a host pair's car and cdr.
        ;; Finish jobs use #(1 source copy 0).  The explicit stack preserves
        ;; recursive DFS callback order without consuming the control stack.
        (dynamic-wind
         (lambda () #t)
         (lambda ()
          (let ((root (vector #f))
                (work '()))
          (define (push-visit! source destination slot)
            "Schedule SOURCE for delivery into DESTINATION at SLOT."
            (set! work
                  (cons (vector 0 source destination slot) work)))
          (define (push-finish! source copy)
            "Schedule one post-edge source metadata copy."
            (set! work (cons (vector 1 source copy 0) work)))
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
                        (export-host-set! source candidate))
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
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)
                 (push-visit! (consent-datum-cdr source) copy -2)
                 (push-visit! (consent-datum-car source) copy -1)))
              ((string)
               (let ((copy (consent-datum-string->host source)))
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)))
              ((bytevector)
               (let ((copy (consent-datum-bytevector->host source)))
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)))
              ((vector)
               (let* ((length (consent-datum-vector-length source))
                      (copy (make-vector length #f)))
                 (export-owned-set! source copy)
                 (deliver! destination slot copy)
                 (push-finish! source copy)
                 (push-vector-edges! source copy length #t)))))
          (define (start-host-copy! source destination slot)
            "Allocate and schedule one private host compound copy."
            (cond
             ((pair? source)
              (let ((copy (cons #f #f)))
                (export-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)
                (push-visit! (cdr source) copy -2)
                (push-visit! (car source) copy -1)))
             ((string? source)
              (let ((copy (string-copy source)))
                (export-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)))
             ((bytevector? source)
              (let ((copy (bytevector-copy source)))
                (export-host-set! source copy)
                (deliver! destination slot copy)
                (push-finish! source copy)))
             ((vector? source)
              (let* ((length (vector-length source))
                     (copy (make-vector length #f)))
                (export-host-set! source copy)
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
                   ((accept-reuse! source destination slot))
                   (else
                    (start-host-copy! source destination slot)))))
             (else
              (deliver! destination slot (leaf source)))))
          (push-visit! value root 0)
          (let loop ()
            (if (null? work)
                (vector-ref root 0)
                (let ((job (car work)))
                  (set! work (cdr work))
                  (if (= (vector-ref job 0) 0)
                      (visit!
                       (vector-ref job 1)
                       (vector-ref job 2)
                       (vector-ref job 3))
                      (copy-source
                       (vector-ref job 2) (vector-ref job 1)))
                  (loop))))))
         (lambda ()
           (if owned-seen
               (consent-datum-object-map-release! owned-seen)))))
          (if (null? rest) value ((car rest) value))))))
