;;; Bootstrap-safe FIFO and deque worklists.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This private library layers a bounded circular worklist over Consent's
;;; growable-vector substrate. It invokes no element callbacks and clears every
;;; vacated slot before publishing the shorter logical sequence.

(define-library (consent worklist)
  (export consent-make-worklist
          consent-worklist?
          consent-worklist-active?
          consent-worklist-empty?
          consent-worklist-size
          consent-worklist-capacity
          consent-worklist-maximum-capacity
          consent-worklist-growth-policy
          consent-worklist-reserve!
          consent-worklist-push-front!
          consent-worklist-push-back!
          consent-worklist-front
          consent-worklist-back
          consent-worklist-pop-front!
          consent-worklist-pop-back!
          consent-worklist-snapshot
          consent-worklist-clear!
          consent-worklist-reset!
          consent-worklist-release!
          consent-worklist-work-units
          consent-worklist-unused-slots-cleared?
          consent-worklist-stats)
  (import (scheme base)
          (only (consent growable-vector)
                consent-make-growable-vector
                consent-growable-vector-append!
                consent-growable-vector-release!
                consent-growable-vector-unsafe-ref
                consent-growable-vector-unsafe-set!
                consent-growable-vector-unused-slots-cleared?))
  (begin
    ;; Mutable circular-buffer state plus deterministic operation counters.
    (define-record-type <consent-worklist>
      (make-worklist-record
       storage size front capacity initial-capacity maximum-capacity
       growth-policy
       high-water push-fronts push-backs pop-fronts pop-backs
       capacity-changes automatic-growths copied-elements clears resets
       active?)
      consent-worklist?
      (storage worklist-storage set-worklist-storage!)
      (size worklist-size set-worklist-size!)
      (front worklist-front-index set-worklist-front-index!)
      (capacity worklist-reserved-capacity set-worklist-reserved-capacity!)
      (initial-capacity worklist-initial-capacity)
      (maximum-capacity worklist-maximum-capacity)
      (growth-policy worklist-growth-policy)
      (high-water worklist-high-water set-worklist-high-water!)
      (push-fronts worklist-push-fronts set-worklist-push-fronts!)
      (push-backs worklist-push-backs set-worklist-push-backs!)
      (pop-fronts worklist-pop-fronts set-worklist-pop-fronts!)
      (pop-backs worklist-pop-backs set-worklist-pop-backs!)
      (capacity-changes
       worklist-capacity-changes
       set-worklist-capacity-changes!)
      (automatic-growths
       worklist-automatic-growths
       set-worklist-automatic-growths!)
      (copied-elements
       worklist-copied-elements
       set-worklist-copied-elements!)
      (clears worklist-clears set-worklist-clears!)
      (resets worklist-resets set-worklist-resets!)
      (active? worklist-active? set-worklist-active!))

    (define (exact-nonnegative-integer? value)
      "Return whether VALUE is an exact nonnegative integer."
      (and (integer? value) (exact? value) (>= value 0)))

    (define (check-capacity operation capacity)
      "Validate CAPACITY as an exact nonnegative integer."
      (if (not (exact-nonnegative-integer? capacity))
          (error
           (string-append operation
                          ": expected exact nonnegative capacity")
           capacity))
      capacity)

    (define (check-growth-policy operation growth-policy)
      "Validate GROWTH-POLICY for OPERATION."
      (if (not (memq growth-policy '(allow-growth pre-reserved)))
          (error
           (string-append operation
                          ": expected allow-growth or pre-reserved")
           growth-policy))
      growth-policy)

    (define (check-worklist operation worklist)
      "Validate active WORKLIST for OPERATION."
      (if (not (consent-worklist? worklist))
          (error
           (string-append operation ": expected worklist") worklist))
      (if (not (worklist-active? worklist))
          (error
           (string-append operation ": worklist is released") worklist))
      worklist)

    (define (check-nonempty operation worklist)
      "Validate active nonempty WORKLIST for OPERATION."
      (check-worklist operation worklist)
      (if (= (worklist-size worklist) 0)
          (error (string-append operation ": worklist is empty") worklist))
      worklist)

    (define (make-slot-storage capacity maximum-capacity)
      "Return growable storage with CAPACITY addressable cleared slots."
      (let ((storage
             (consent-make-growable-vector
              capacity maximum-capacity)))
        (let loop ((index 0))
          (if (< index capacity)
              (begin
                (consent-growable-vector-append! storage #f)
                (loop (+ index 1)))))
        storage))

    (define (worklist-capacity-value worklist)
      "Return WORKLIST's capacity, including zero after release."
      (if (worklist-active? worklist)
          (worklist-reserved-capacity worklist)
          0))

    (define (worklist-physical-index worklist offset)
      "Return physical index for logical OFFSET in WORKLIST."
      (let* ((capacity (worklist-capacity-value worklist))
             (candidate (+ (worklist-front-index worklist) offset)))
        (if (>= candidate capacity)
            (- candidate capacity)
            candidate)))

    (define (worklist-slot-ref worklist offset)
      "Return WORKLIST's value at logical OFFSET."
      (consent-growable-vector-unsafe-ref
       (worklist-storage worklist)
       (worklist-physical-index worklist offset)))

    (define (worklist-slot-set! worklist offset value)
      "Set WORKLIST's logical OFFSET to VALUE."
      (consent-growable-vector-unsafe-set!
       (worklist-storage worklist)
       (worklist-physical-index worklist offset)
       value))

    (define (replace-worklist-capacity!
             operation worklist requested automatic?)
      "Replace WORKLIST storage with REQUESTED slots in logical order."
      (let* ((size (worklist-size worklist))
             (old-storage (worklist-storage worklist))
             (new-storage
              (make-slot-storage
               requested (worklist-maximum-capacity worklist))))
        (let copy ((offset 0))
          (if (< offset size)
              (begin
                (consent-growable-vector-unsafe-set!
                 new-storage offset (worklist-slot-ref worklist offset))
                (copy (+ offset 1)))))
        (consent-growable-vector-release! old-storage)
        (set-worklist-storage! worklist new-storage)
        (set-worklist-reserved-capacity! worklist requested)
        (set-worklist-front-index! worklist 0)
        (set-worklist-capacity-changes!
         worklist (+ (worklist-capacity-changes worklist) 1))
        (if automatic?
            (set-worklist-automatic-growths!
             worklist (+ (worklist-automatic-growths worklist) 1)))
        (set-worklist-copied-elements!
         worklist (+ (worklist-copied-elements worklist) size))
        worklist))

    (define (next-worklist-capacity worklist)
      "Return WORKLIST's next bounded geometric capacity."
      (let ((capacity (worklist-capacity-value worklist))
            (maximum (worklist-maximum-capacity worklist)))
        (cond
         ((= capacity 0) (min 1 maximum))
         ((>= capacity (quotient maximum 2)) maximum)
         (else (* capacity 2)))))

    (define (ensure-worklist-room! operation worklist)
      "Ensure WORKLIST has room for one insertion."
      (let ((size (worklist-size worklist))
            (capacity (worklist-capacity-value worklist)))
        (if (= size capacity)
            (begin
              (if (eq? (worklist-growth-policy worklist) 'pre-reserved)
                  (error
                   (string-append operation
                                  ": pre-reserved capacity exhausted")
                   size
                   capacity))
              (if (= capacity (worklist-maximum-capacity worklist))
                  (error
                   (string-append operation
                                  ": maximum capacity exceeded")
                   capacity))
              (replace-worklist-capacity!
               operation worklist (next-worklist-capacity worklist) #t))))
      worklist)

    (define (note-worklist-size! worklist size)
      "Publish SIZE and update WORKLIST's historical high-water mark."
      (set-worklist-size! worklist size)
      (if (> size (worklist-high-water worklist))
          (set-worklist-high-water! worklist size))
      worklist)

    (define (reset-worklist-storage! worklist)
      "Clear WORKLIST's active slots while retaining capacity."
      (let ((size (worklist-size worklist)))
        (let clear ((offset 0))
          (if (< offset size)
              (begin
                (worklist-slot-set! worklist offset #f)
                (clear (+ offset 1))))))
      (set-worklist-size! worklist 0)
      (set-worklist-front-index! worklist 0)
      worklist)

    (define (consent-make-worklist
             initial-capacity maximum-capacity growth-policy)
      "Return an empty bounded worklist using GROWTH-POLICY."
      #((parameters
         (initial-capacity (type exact-non-negative-integer)
          (description "Initially reserved slots."))
         (maximum-capacity (type exact-non-negative-integer)
          (description "Largest permitted reserved capacity."))
         (growth-policy (type symbol)
          (description "Either allow-growth or pre-reserved.")))
        (returns (type worklist)
         (description "Fresh active private FIFO and deque storage."))
        (effects allocation error))
      (check-capacity "consent-make-worklist initial" initial-capacity)
      (check-capacity "consent-make-worklist maximum" maximum-capacity)
      (check-growth-policy "consent-make-worklist" growth-policy)
      (if (> initial-capacity maximum-capacity)
          (error
           "consent-make-worklist: initial capacity exceeds maximum"
           initial-capacity
           maximum-capacity))
      (make-worklist-record
       (make-slot-storage initial-capacity maximum-capacity)
       0
       0
       initial-capacity
       initial-capacity
       maximum-capacity
       growth-policy
       0
       0
       0
       0
       0
       0
       0
       0
       0
       0
       #t))

    (define (consent-worklist-active? worklist)
      "Return whether WORKLIST is active and unreleased."
      #((parameters
         (worklist (type any) (description "Candidate object.")))
        (returns (type boolean)
         (description "Whether WORKLIST is active."))
        (effects pure))
      (and (consent-worklist? worklist)
           (worklist-active? worklist)))

    (define (consent-worklist-empty? worklist)
      "Return whether active WORKLIST contains no values."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type boolean)
         (description "Whether WORKLIST is empty."))
        (effects state-read error))
      (check-worklist "consent-worklist-empty?" worklist)
      (= (worklist-size worklist) 0))

    (define (consent-worklist-size worklist)
      "Return active WORKLIST's logical size."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of retained values."))
        (effects state-read error))
      (check-worklist "consent-worklist-size" worklist)
      (worklist-size worklist))

    (define (consent-worklist-capacity worklist)
      "Return active WORKLIST's reserved slot count."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of reserved slots."))
        (effects state-read error))
      (check-worklist "consent-worklist-capacity" worklist)
      (worklist-capacity-value worklist))

    (define (consent-worklist-maximum-capacity worklist)
      "Return active WORKLIST's immutable maximum capacity."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Largest permitted capacity."))
        (effects state-read error))
      (check-worklist "consent-worklist-maximum-capacity" worklist)
      (worklist-maximum-capacity worklist))

    (define (consent-worklist-growth-policy worklist)
      "Return active WORKLIST's immutable growth policy."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type symbol)
         (description "Either allow-growth or pre-reserved."))
        (effects state-read error))
      (check-worklist "consent-worklist-growth-policy" worklist)
      (worklist-growth-policy worklist))

    (define (consent-worklist-reserve! worklist requested)
      "Reserve exactly REQUESTED slots when WORKLIST is smaller."
      #((parameters
         (worklist (type worklist) (description "Worklist to reserve."))
         (requested (type exact-non-negative-integer)
          (description "Minimum exact capacity.")))
        (returns (type worklist)
         (description "The supplied WORKLIST."))
        (effects allocation state-write error))
      (check-worklist "consent-worklist-reserve!" worklist)
      (check-capacity "consent-worklist-reserve!" requested)
      (if (> requested (worklist-maximum-capacity worklist))
          (error
           "consent-worklist-reserve!: maximum capacity exceeded"
           requested
           (worklist-maximum-capacity worklist)))
      (if (> requested (worklist-capacity-value worklist))
          (replace-worklist-capacity!
           "consent-worklist-reserve!" worklist requested #f))
      worklist)

    (define (consent-worklist-push-front! worklist value)
      "Push VALUE onto the front of WORKLIST."
      #((parameters
         (worklist (type worklist) (description "Worklist to mutate."))
         (value (type any) (description "Value to retain.")))
        (returns (type worklist)
         (description "The supplied WORKLIST."))
        (effects allocation state-write error))
      (check-worklist "consent-worklist-push-front!" worklist)
      (ensure-worklist-room! "consent-worklist-push-front!" worklist)
      (let* ((capacity (worklist-capacity-value worklist))
             (front
              (if (= (worklist-front-index worklist) 0)
                  (- capacity 1)
                  (- (worklist-front-index worklist) 1))))
        (set-worklist-front-index! worklist front)
        (consent-growable-vector-unsafe-set!
         (worklist-storage worklist) front value))
      (note-worklist-size! worklist (+ (worklist-size worklist) 1))
      (set-worklist-push-fronts!
       worklist (+ (worklist-push-fronts worklist) 1))
      worklist)

    (define (consent-worklist-push-back! worklist value)
      "Push VALUE onto the back of WORKLIST."
      #((parameters
         (worklist (type worklist) (description "Worklist to mutate."))
         (value (type any) (description "Value to retain.")))
        (returns (type worklist)
         (description "The supplied WORKLIST."))
        (effects allocation state-write error))
      (check-worklist "consent-worklist-push-back!" worklist)
      (ensure-worklist-room! "consent-worklist-push-back!" worklist)
      (worklist-slot-set! worklist (worklist-size worklist) value)
      (note-worklist-size! worklist (+ (worklist-size worklist) 1))
      (set-worklist-push-backs!
       worklist (+ (worklist-push-backs worklist) 1))
      worklist)

    (define (consent-worklist-front worklist)
      "Return active WORKLIST's front value without removing it."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type any) (description "Front retained value."))
        (effects state-read error))
      (check-nonempty "consent-worklist-front" worklist)
      (worklist-slot-ref worklist 0))

    (define (consent-worklist-back worklist)
      "Return active WORKLIST's back value without removing it."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type any) (description "Back retained value."))
        (effects state-read error))
      (check-nonempty "consent-worklist-back" worklist)
      (worklist-slot-ref worklist (- (worklist-size worklist) 1)))

    (define (consent-worklist-pop-front! worklist)
      "Remove and return active WORKLIST's front value."
      #((parameters
         (worklist (type worklist) (description "Worklist to mutate.")))
        (returns (type any) (description "Removed front value."))
        (effects state-read state-write error))
      (check-nonempty "consent-worklist-pop-front!" worklist)
      (let* ((capacity (worklist-capacity-value worklist))
             (front (worklist-front-index worklist))
             (value
              (consent-growable-vector-unsafe-ref
               (worklist-storage worklist) front))
             (new-size (- (worklist-size worklist) 1)))
        (consent-growable-vector-unsafe-set!
         (worklist-storage worklist) front #f)
        (set-worklist-size! worklist new-size)
        (set-worklist-front-index!
         worklist
         (if (= new-size 0)
             0
             (if (= (+ front 1) capacity) 0 (+ front 1))))
        (set-worklist-pop-fronts!
         worklist (+ (worklist-pop-fronts worklist) 1))
        value))

    (define (consent-worklist-pop-back! worklist)
      "Remove and return active WORKLIST's back value."
      #((parameters
         (worklist (type worklist) (description "Worklist to mutate.")))
        (returns (type any) (description "Removed back value."))
        (effects state-read state-write error))
      (check-nonempty "consent-worklist-pop-back!" worklist)
      (let* ((offset (- (worklist-size worklist) 1))
             (physical (worklist-physical-index worklist offset))
             (value
              (consent-growable-vector-unsafe-ref
               (worklist-storage worklist) physical))
             (new-size offset))
        (consent-growable-vector-unsafe-set!
         (worklist-storage worklist) physical #f)
        (set-worklist-size! worklist new-size)
        (if (= new-size 0)
            (set-worklist-front-index! worklist 0))
        (set-worklist-pop-backs!
         worklist (+ (worklist-pop-backs worklist) 1))
        value))

    (define (consent-worklist-snapshot worklist)
      "Return active WORKLIST's values in front-to-back order."
      #((parameters
         (worklist (type worklist) (description "Worklist to snapshot.")))
        (returns (type vector)
         (description "Fresh vector in logical order."))
        (effects allocation state-read error))
      (check-worklist "consent-worklist-snapshot" worklist)
      (let* ((size (worklist-size worklist))
             (snapshot (make-vector size #f)))
        (let copy ((offset 0))
          (if (< offset size)
              (begin
                (vector-set!
                 snapshot offset (worklist-slot-ref worklist offset))
                (copy (+ offset 1)))))
        snapshot))

    (define (consent-worklist-clear! worklist)
      "Empty WORKLIST and restore its initial capacity."
      #((parameters
         (worklist (type worklist) (description "Worklist to clear.")))
        (returns (type worklist)
         (description "The empty active WORKLIST."))
        (effects allocation state-write error))
      (check-worklist "consent-worklist-clear!" worklist)
      (let ((new-storage
             (make-slot-storage
              (worklist-initial-capacity worklist)
              (worklist-maximum-capacity worklist))))
        (consent-growable-vector-release! (worklist-storage worklist))
        (set-worklist-storage! worklist new-storage)
        (set-worklist-reserved-capacity!
         worklist (worklist-initial-capacity worklist)))
      (set-worklist-size! worklist 0)
      (set-worklist-front-index! worklist 0)
      (set-worklist-clears! worklist (+ (worklist-clears worklist) 1))
      worklist)

    (define (consent-worklist-reset! worklist)
      "Empty WORKLIST while retaining its current capacity."
      #((parameters
         (worklist (type worklist) (description "Worklist to reset.")))
        (returns (type worklist)
         (description "The empty active WORKLIST."))
        (effects state-write error))
      (check-worklist "consent-worklist-reset!" worklist)
      (reset-worklist-storage! worklist)
      (set-worklist-resets! worklist (+ (worklist-resets worklist) 1))
      worklist)

    (define (consent-worklist-release! worklist)
      "Clear WORKLIST roots and permanently release its storage."
      #((parameters
         (worklist (type worklist) (description "Worklist to release.")))
        (returns (type worklist)
         (description "The inactive released WORKLIST."))
        (effects state-write error))
      (if (not (consent-worklist? worklist))
          (error
           "consent-worklist-release!: expected worklist" worklist))
      (if (worklist-active? worklist)
          (begin
            (reset-worklist-storage! worklist)
            (consent-growable-vector-release!
             (worklist-storage worklist))
            (set-worklist-reserved-capacity! worklist 0)
            (set-worklist-active! worklist #f)))
      worklist)

    (define (consent-worklist-work-units worklist)
      "Return successful push and pop operations on WORKLIST."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Deterministic enqueue and dequeue count."))
        (effects state-read error))
      (check-worklist "consent-worklist-work-units" worklist)
      (+ (worklist-push-fronts worklist)
         (worklist-push-backs worklist)
         (worklist-pop-fronts worklist)
         (worklist-pop-backs worklist)))

    (define (consent-worklist-unused-slots-cleared? worklist)
      "Return whether WORKLIST retains no values outside its logical range."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type boolean)
         (description "Whether every unused slot contains false."))
        (effects state-read error))
      (if (not (consent-worklist? worklist))
          (error
           "consent-worklist-unused-slots-cleared?: expected worklist"
           worklist))
      (if (not (worklist-active? worklist))
          (consent-growable-vector-unused-slots-cleared?
           (worklist-storage worklist))
          (let ((capacity (worklist-capacity-value worklist))
                (size (worklist-size worklist)))
            (let loop ((offset size))
              (cond
               ((= offset capacity) #t)
               ((eqv? (worklist-slot-ref worklist offset) #f)
                (loop (+ offset 1)))
               (else #f))))))

    (define (consent-worklist-stats worklist)
      "Return Scheme-readable lifetime and work statistics for WORKLIST."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type list)
         (description "Private worklist statistics datum."))
        (effects allocation state-read error))
      (if (not (consent-worklist? worklist))
          (error "consent-worklist-stats: expected worklist" worklist))
      (let ((pushes
             (+ (worklist-push-fronts worklist)
                (worklist-push-backs worklist)))
            (pops
             (+ (worklist-pop-fronts worklist)
                (worklist-pop-backs worklist))))
        (list
         'worklist-stats
         (list 'growth-policy (worklist-growth-policy worklist))
         (list 'active (worklist-active? worklist))
         (list 'size (worklist-size worklist))
         (list 'capacity (worklist-capacity-value worklist))
         (list 'maximum-capacity (worklist-maximum-capacity worklist))
         (list 'high-water (worklist-high-water worklist))
         (list 'front-index (worklist-front-index worklist))
         (list 'push-fronts (worklist-push-fronts worklist))
         (list 'push-backs (worklist-push-backs worklist))
         (list 'pop-fronts (worklist-pop-fronts worklist))
         (list 'pop-backs (worklist-pop-backs worklist))
         (list 'pushes pushes)
         (list 'pops pops)
         (list 'work-units (+ pushes pops))
         (list 'capacity-changes
               (worklist-capacity-changes worklist))
         (list 'automatic-growths
               (worklist-automatic-growths worklist))
         (list 'copied-elements (worklist-copied-elements worklist))
         (list 'clears (worklist-clears worklist))
         (list 'resets (worklist-resets worklist)))))))
