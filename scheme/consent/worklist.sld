;;; Bootstrap-safe FIFO and deque worklists.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This private library owns bounded circular storage directly. It invokes no
;;; element callbacks and clears every vacated slot before publishing the
;;; shorter logical sequence.

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
  (import (scheme base))
  (begin
    ;; ALLOW-GROWTH worklists start without backing storage.  This unique
    ;; sentinel distinguishes an active lazy worklist from a released one.
    (define worklist-lazy-storage (list 'worklist-lazy-storage))

    ;; Cold counters allocate together on the first successful mutation.
    (define worklist-high-water-index 0)
    ;; Successful front insertion count.
    (define worklist-push-fronts-index 1)
    ;; Successful back insertion count.
    (define worklist-push-backs-index 2)
    ;; Successful front removal count.
    (define worklist-pop-fronts-index 3)
    ;; Successful back removal count.
    (define worklist-pop-backs-index 4)
    ;; Explicit and automatic capacity-change count.
    (define worklist-capacity-changes-index 5)
    ;; Automatic capacity-growth count.
    (define worklist-automatic-growths-index 6)
    ;; Elements copied while replacing backing storage.
    (define worklist-copied-elements-index 7)
    ;; Logical clear count.
    (define worklist-clears-index 8)
    ;; Logical reset count.
    (define worklist-resets-index 9)
    ;; Number of slots in the statistics sidecar.
    (define worklist-statistics-size 10)

    ;; Mutable circular-buffer state plus one lazy diagnostic sidecar.
    (define-record-type <consent-worklist>
      (make-worklist-record
       storage size front initial-capacity maximum-capacity growth-policy
       statistics)
      consent-worklist?
      (storage worklist-storage set-worklist-storage!)
      (size worklist-size set-worklist-size!)
      (front worklist-front-index set-worklist-front-index!)
      (initial-capacity worklist-initial-capacity)
      (maximum-capacity worklist-maximum-capacity)
      (growth-policy worklist-growth-policy)
      (statistics worklist-statistics set-worklist-statistics!))

    (define (worklist-active? worklist)
      "Return whether WORKLIST has not been released."
      (not (eq? (worklist-storage worklist) #f)))

    (define (worklist-statistic worklist index)
      "Return WORKLIST's cold statistic at INDEX, defaulting to zero."
      (let ((statistics (worklist-statistics worklist)))
        (if statistics (vector-ref statistics index) 0)))

    (define (worklist-statistics-for-write! worklist)
      "Return WORKLIST's writable cold-statistics sidecar."
      (or (worklist-statistics worklist)
          (let ((statistics (make-vector worklist-statistics-size 0)))
            (set-worklist-statistics! worklist statistics)
            statistics)))

    (define (note-worklist! worklist index amount)
      "Add AMOUNT to WORKLIST's cold statistic at INDEX."
      (let ((statistics (worklist-statistics-for-write! worklist)))
        (vector-set!
         statistics index (+ (vector-ref statistics index) amount))))

    (define (note-worklist-high-water! worklist size)
      "Raise WORKLIST's historical high-water mark to SIZE when needed."
      (let ((high-water
             (worklist-statistic worklist worklist-high-water-index)))
        (if (> size high-water)
            (vector-set!
             (worklist-statistics-for-write! worklist)
             worklist-high-water-index
             size))))

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

    (define (allocate-slot-storage operation capacity)
      "Return CAPACITY cleared slots or fail with a normalized condition."
      (guard (condition
              (else
               (error
                (string-append operation ": storage allocation failed")
                capacity)))
        (make-vector capacity #f)))

    (define (worklist-capacity-value worklist)
      "Return WORKLIST's capacity, including zero after release."
      (let ((storage (worklist-storage worklist)))
        (if (vector? storage) (vector-length storage) 0)))

    (define (worklist-physical-index worklist offset)
      "Return physical index for logical OFFSET in WORKLIST."
      (let* ((capacity (worklist-capacity-value worklist))
             (candidate (+ (worklist-front-index worklist) offset)))
        (if (>= candidate capacity)
            (- candidate capacity)
            candidate)))

    (define (worklist-slot-ref worklist offset)
      "Return WORKLIST's value at logical OFFSET."
      (vector-ref
       (worklist-storage worklist)
       (worklist-physical-index worklist offset)))

    (define (worklist-slot-set! worklist offset value)
      "Set WORKLIST's logical OFFSET to VALUE."
      (vector-set!
       (worklist-storage worklist)
       (worklist-physical-index worklist offset)
       value))

    (define (replace-worklist-capacity!
             operation worklist requested automatic?)
      "Replace WORKLIST storage with REQUESTED slots in logical order."
      ;; Sidecar publication is observationally neutral and makes every later
      ;; counter update allocation-free.
      (worklist-statistics-for-write! worklist)
      (let* ((size (worklist-size worklist))
             (old-storage (worklist-storage worklist))
             (new-storage
              (allocate-slot-storage operation requested)))
        (let copy ((offset 0))
          (if (< offset size)
              (begin
                (vector-set!
                 new-storage offset (worklist-slot-ref worklist offset))
                (copy (+ offset 1)))))
        (if (vector? old-storage)
            (vector-fill! old-storage #f))
        (set-worklist-storage! worklist new-storage)
        (set-worklist-front-index! worklist 0)
        (note-worklist! worklist worklist-capacity-changes-index 1)
        (if automatic?
            (note-worklist!
             worklist worklist-automatic-growths-index 1))
        (note-worklist! worklist worklist-copied-elements-index size)
        worklist))

    (define (next-worklist-capacity worklist)
      "Return WORKLIST's next bounded geometric capacity."
      (let ((capacity (worklist-capacity-value worklist))
            (maximum (worklist-maximum-capacity worklist)))
        (cond
         ((= capacity 0)
          (min maximum (max 1 (worklist-initial-capacity worklist))))
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
      (note-worklist-high-water! worklist size)
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
          (description "First-allocation floor or eager capacity."))
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
       (if (eq? growth-policy 'pre-reserved)
           (allocate-slot-storage
            "consent-make-worklist" initial-capacity)
           worklist-lazy-storage)
       0
       0
       initial-capacity
       maximum-capacity
       growth-policy
       #f))

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
      "Reserve at least REQUESTED slots when WORKLIST is smaller."
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
           "consent-worklist-reserve!"
           worklist
           (if (= (worklist-capacity-value worklist) 0)
               (max requested (worklist-initial-capacity worklist))
               requested)
           #f))
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
      (worklist-statistics-for-write! worklist)
      (ensure-worklist-room! "consent-worklist-push-front!" worklist)
      (let* ((capacity (worklist-capacity-value worklist))
             (front
              (if (= (worklist-front-index worklist) 0)
                  (- capacity 1)
                  (- (worklist-front-index worklist) 1))))
        (set-worklist-front-index! worklist front)
        (vector-set! (worklist-storage worklist) front value))
      (note-worklist-size! worklist (+ (worklist-size worklist) 1))
      (note-worklist! worklist worklist-push-fronts-index 1)
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
      (worklist-statistics-for-write! worklist)
      (ensure-worklist-room! "consent-worklist-push-back!" worklist)
      (worklist-slot-set! worklist (worklist-size worklist) value)
      (note-worklist-size! worklist (+ (worklist-size worklist) 1))
      (note-worklist! worklist worklist-push-backs-index 1)
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
             (value (vector-ref (worklist-storage worklist) front))
             (new-size (- (worklist-size worklist) 1)))
        (worklist-statistics-for-write! worklist)
        (vector-set! (worklist-storage worklist) front #f)
        (set-worklist-size! worklist new-size)
        (set-worklist-front-index!
         worklist
         (if (= new-size 0)
             0
             (if (= (+ front 1) capacity) 0 (+ front 1))))
        (note-worklist! worklist worklist-pop-fronts-index 1)
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
             (value (vector-ref (worklist-storage worklist) physical))
             (new-size offset))
        (worklist-statistics-for-write! worklist)
        (vector-set! (worklist-storage worklist) physical #f)
        (set-worklist-size! worklist new-size)
        (if (= new-size 0)
            (set-worklist-front-index! worklist 0))
        (note-worklist! worklist worklist-pop-backs-index 1)
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
      (worklist-statistics-for-write! worklist)
      (let* ((old-storage (worklist-storage worklist))
             (new-storage
              (if (eq? (worklist-growth-policy worklist) 'pre-reserved)
                  (allocate-slot-storage
                   "consent-worklist-clear!"
                   (worklist-initial-capacity worklist))
                  worklist-lazy-storage)))
        (if (vector? old-storage)
            (vector-fill! old-storage #f))
        (set-worklist-storage! worklist new-storage))
      (set-worklist-size! worklist 0)
      (set-worklist-front-index! worklist 0)
      (note-worklist! worklist worklist-clears-index 1)
      worklist)

    (define (consent-worklist-reset! worklist)
      "Empty WORKLIST while retaining its current capacity."
      #((parameters
         (worklist (type worklist) (description "Worklist to reset.")))
        (returns (type worklist)
         (description "The empty active WORKLIST."))
        (effects state-write error))
      (check-worklist "consent-worklist-reset!" worklist)
      (worklist-statistics-for-write! worklist)
      (reset-worklist-storage! worklist)
      (note-worklist! worklist worklist-resets-index 1)
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
            (set-worklist-storage! worklist #f)))
      worklist)

    (define (consent-worklist-work-units worklist)
      "Return successful push and pop operations on WORKLIST."
      #((parameters
         (worklist (type worklist) (description "Worklist to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Deterministic enqueue and dequeue count."))
        (effects state-read error))
      (check-worklist "consent-worklist-work-units" worklist)
      (+ (worklist-statistic worklist worklist-push-fronts-index)
         (worklist-statistic worklist worklist-push-backs-index)
         (worklist-statistic worklist worklist-pop-fronts-index)
         (worklist-statistic worklist worklist-pop-backs-index)))

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
          #t
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
             (+ (worklist-statistic
                 worklist worklist-push-fronts-index)
                (worklist-statistic
                 worklist worklist-push-backs-index)))
            (pops
             (+ (worklist-statistic
                 worklist worklist-pop-fronts-index)
                (worklist-statistic
                 worklist worklist-pop-backs-index))))
        (list
         'worklist-stats
         (list 'growth-policy (worklist-growth-policy worklist))
         (list 'active (worklist-active? worklist))
         (list 'size (worklist-size worklist))
         (list 'capacity (worklist-capacity-value worklist))
         (list 'maximum-capacity (worklist-maximum-capacity worklist))
         (list 'high-water
               (worklist-statistic
                worklist worklist-high-water-index))
         (list 'front-index (worklist-front-index worklist))
         (list 'push-fronts
               (worklist-statistic
                worklist worklist-push-fronts-index))
         (list 'push-backs
               (worklist-statistic
                worklist worklist-push-backs-index))
         (list 'pop-fronts
               (worklist-statistic
                worklist worklist-pop-fronts-index))
         (list 'pop-backs
               (worklist-statistic
                worklist worklist-pop-backs-index))
         (list 'pushes pushes)
         (list 'pops pops)
         (list 'work-units (+ pushes pops))
         (list 'capacity-changes
               (worklist-statistic
                worklist worklist-capacity-changes-index))
         (list 'automatic-growths
               (worklist-statistic
                worklist worklist-automatic-growths-index))
         (list 'copied-elements
               (worklist-statistic
                worklist worklist-copied-elements-index))
         (list 'clears
               (worklist-statistic worklist worklist-clears-index))
         (list 'resets
               (worklist-statistic worklist worklist-resets-index)))))))
