;;; Bootstrap-safe growable vectors and bounded scratch arenas.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This private library owns callback-free temporary storage for runtime and
;;; graph algorithms. Exact capacity ceilings prevent integer wraparound from
;;; becoming an allocation request. Host allocation failures are normalized to
;;; Scheme errors before partially initialized storage is published.

(define-library (consent runtime-storage)
  (export consent-make-growable-vector
          consent-growable-vector?
          consent-growable-vector-active?
          consent-growable-vector-length
          consent-growable-vector-capacity
          consent-growable-vector-maximum-capacity
          consent-growable-vector-append!
          consent-growable-vector-ref
          consent-growable-vector-set!
          consent-growable-vector-reserve!
          consent-growable-vector-grow!
          consent-growable-vector-snapshot
          consent-growable-vector-reset!
          consent-growable-vector-release!
          consent-growable-vector-unused-slots-cleared?
          consent-growable-vector-stats
          consent-make-scratch-arena
          consent-scratch-arena?
          consent-scratch-arena-reserve!
          consent-scratch-arena-acquire!
          consent-scratch-owner?
          consent-scratch-owner-active?
          consent-scratch-owner-phase
          consent-scratch-owner-length
          consent-scratch-owner-capacity
          consent-scratch-owner-append!
          consent-scratch-owner-ref
          consent-scratch-owner-set!
          consent-scratch-owner-mark
          consent-scratch-owner-reset!
          consent-scratch-owner-release!
          consent-scratch-arena-unused-slots-cleared?
          consent-scratch-arena-stats)
  (import (scheme base))
  (begin

    ;; Shared terminal sentinel installed after growable storage release.
    (define growable-vector-empty-storage (vector))

    ;; Mutable bounded vector state and deterministic lifetime counters.
    (define-record-type <consent-growable-vector>
      (make-growable-vector-record
       length data maximum-capacity high-water growth-count copied-elements
       reset-count active?)
      consent-growable-vector?
      (length growable-vector-length set-growable-vector-length!)
      (data growable-vector-data set-growable-vector-data!)
      (maximum-capacity growable-vector-maximum-capacity)
      (high-water growable-vector-high-water set-growable-vector-high-water!)
      (growth-count
       growable-vector-growth-count
       set-growable-vector-growth-count!)
      (copied-elements
       growable-vector-copied-elements
       set-growable-vector-copied-elements!)
      (reset-count
       growable-vector-reset-count
       set-growable-vector-reset-count!)
      (active? growable-vector-active? set-growable-vector-active!))

    (define (exact-nonnegative-integer? value)
      "Return whether VALUE is an exact nonnegative integer."
      (and (integer? value) (exact? value) (>= value 0)))

    (define (check-capacity operation capacity)
      "Validate CAPACITY as an exact nonnegative integer for OPERATION."
      (if (not (exact-nonnegative-integer? capacity))
          (error
           (string-append operation ": expected exact nonnegative capacity")
           capacity)))

    (define (allocate-storage operation capacity)
      "Allocate CAPACITY cleared slots or fail with a normalized condition."
      (guard (condition
              (else
               (error
                (string-append operation ": storage allocation failed")
                capacity)))
        (make-vector capacity #f)))

    (define (check-growable-vector operation grow)
      "Validate active growable vector GROW for OPERATION."
      (if (not (consent-growable-vector? grow))
          (error
           (string-append operation ": expected growable vector") grow))
      (if (not (growable-vector-active? grow))
          (error
           (string-append operation ": growable vector is released") grow))
      grow)

    (define (check-growable-vector-index operation grow index)
      "Validate populated INDEX in active GROW for OPERATION."
      (check-growable-vector operation grow)
      (if (not (and (exact-nonnegative-integer? index)
                    (< index (growable-vector-length grow))))
          (error
           (string-append operation ": index outside populated prefix")
           index
           (growable-vector-length grow)))
      index)

    (define (check-requested-capacity operation grow requested)
      "Validate REQUESTED against GROW's exact maximum for OPERATION."
      (check-capacity operation requested)
      (if (> requested (growable-vector-maximum-capacity grow))
          (error
           (string-append operation ": maximum capacity exceeded")
           requested
           (growable-vector-maximum-capacity grow)))
      requested)

    (define (replace-growable-vector-capacity! operation grow requested)
      "Replace GROW's storage with REQUESTED slots and return GROW."
      (let* ((length (growable-vector-length grow))
             (old (growable-vector-data grow))
             (larger (allocate-storage operation requested)))
        (let copy ((index 0))
          (if (< index length)
              (begin
                (vector-set! larger index (vector-ref old index))
                (copy (+ index 1)))))
        (set-growable-vector-data! grow larger)
        (set-growable-vector-growth-count!
         grow (+ (growable-vector-growth-count grow) 1))
        (set-growable-vector-copied-elements!
         grow (+ (growable-vector-copied-elements grow) length))
        grow))

    (define (growable-vector-truncate! operation grow requested)
      "Clear GROW's suffix down to REQUESTED and count one reset."
      (check-growable-vector operation grow)
      (if (not (and (exact-nonnegative-integer? requested)
                    (<= requested (growable-vector-length grow))))
          (error
           (string-append operation ": invalid reset length")
           requested
           (growable-vector-length grow)))
      (let ((data (growable-vector-data grow)))
        (let clear ((index requested))
          (if (< index (growable-vector-length grow))
              (begin
                (vector-set! data index #f)
                (clear (+ index 1))))))
      (set-growable-vector-length! grow requested)
      (set-growable-vector-reset-count!
       grow (+ (growable-vector-reset-count grow) 1))
      grow)

    (define (consent-make-growable-vector
             initial-capacity maximum-capacity)
      "Return empty growable storage within the supplied capacity bounds."
      #((parameters
         (initial-capacity (type exact-non-negative-integer)
          (description "Initially reserved slots."))
         (maximum-capacity (type exact-non-negative-integer)
          (description "Largest permitted reserved capacity.")))
        (returns (type growable-vector)
         (description "Fresh active private growable storage."))
        (effects allocation error))
      (check-capacity
       "consent-make-growable-vector initial" initial-capacity)
      (check-capacity
       "consent-make-growable-vector maximum" maximum-capacity)
      (if (> initial-capacity maximum-capacity)
          (error
           "consent-make-growable-vector: initial capacity exceeds maximum"
           initial-capacity
           maximum-capacity))
      (make-growable-vector-record
       0
       (allocate-storage
        "consent-make-growable-vector" initial-capacity)
       maximum-capacity
       0
       0
       0
       0
       #t))

    (define (consent-growable-vector-active? grow)
      "Return whether GROW is an active growable vector."
      #((parameters
         (grow (type any) (description "Candidate object.")))
        (returns (type boolean)
         (description "Whether GROW is active and unreleased."))
        (effects pure))
      (and (consent-growable-vector? grow)
           (growable-vector-active? grow)))

    (define (consent-growable-vector-length grow)
      "Return GROW's populated-prefix length."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of populated elements."))
        (effects state-read error))
      (check-growable-vector "consent-growable-vector-length" grow)
      (growable-vector-length grow))

    (define (consent-growable-vector-capacity grow)
      "Return GROW's currently reserved capacity."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of reserved slots."))
        (effects state-read error))
      (check-growable-vector "consent-growable-vector-capacity" grow)
      (vector-length (growable-vector-data grow)))

    (define (consent-growable-vector-maximum-capacity grow)
      "Return GROW's configured maximum capacity."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Largest permitted reserved capacity."))
        (effects state-read error))
      (check-growable-vector
       "consent-growable-vector-maximum-capacity" grow)
      (growable-vector-maximum-capacity grow))

    (define (consent-growable-vector-reserve! grow requested)
      "Reserve exactly REQUESTED slots when GROW is currently smaller."
      #((parameters
         (grow (type growable-vector) (description "Storage to reserve."))
         (requested (type exact-non-negative-integer)
          (description "Minimum exact capacity to reserve.")))
        (returns (type growable-vector)
         (description "The supplied GROW."))
        (effects allocation state-write error))
      (check-growable-vector "consent-growable-vector-reserve!" grow)
      (check-requested-capacity
       "consent-growable-vector-reserve!" grow requested)
      (if (> requested (vector-length (growable-vector-data grow)))
          (replace-growable-vector-capacity!
           "consent-growable-vector-reserve!" grow requested))
      grow)

    (define (consent-growable-vector-grow! grow minimum-capacity)
      "Grow GROW geometrically to at least MINIMUM-CAPACITY."
      #((parameters
         (grow (type growable-vector) (description "Storage to grow."))
         (minimum-capacity (type exact-non-negative-integer)
          (description "Smallest acceptable resulting capacity.")))
        (returns (type growable-vector)
         (description "The supplied GROW."))
        (effects allocation state-write error))
      (check-growable-vector "consent-growable-vector-grow!" grow)
      (check-requested-capacity
       "consent-growable-vector-grow!" grow minimum-capacity)
      (let ((capacity (vector-length (growable-vector-data grow))))
        (if (> minimum-capacity capacity)
            (let* ((doubled (if (= capacity 0) 1 (* capacity 2)))
                   (candidate (max minimum-capacity doubled))
                   (bounded
                    (min candidate
                         (growable-vector-maximum-capacity grow))))
              (replace-growable-vector-capacity!
               "consent-growable-vector-grow!" grow bounded))))
      grow)

    (define (consent-growable-vector-append! grow value)
      "Append VALUE to GROW and return its populated-prefix index."
      #((parameters
         (grow (type growable-vector) (description "Storage to append."))
         (value (type any) (description "Value to retain.")))
        (returns (type exact-non-negative-integer)
         (description "Assigned zero-based index."))
        (effects allocation state-write error))
      (check-growable-vector "consent-growable-vector-append!" grow)
      (let ((index (growable-vector-length grow)))
        (if (= index (vector-length (growable-vector-data grow)))
            (consent-growable-vector-grow! grow (+ index 1)))
        (vector-set! (growable-vector-data grow) index value)
        (set-growable-vector-length! grow (+ index 1))
        (if (> (+ index 1) (growable-vector-high-water grow))
            (set-growable-vector-high-water! grow (+ index 1)))
        index))

    (define (consent-growable-vector-ref grow index)
      "Return populated GROW element at INDEX."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect."))
         (index (type exact-non-negative-integer)
          (description "Populated zero-based index.")))
        (returns (type any) (description "Stored value."))
        (effects state-read error))
      (check-growable-vector-index
       "consent-growable-vector-ref" grow index)
      (vector-ref (growable-vector-data grow) index))

    (define (consent-growable-vector-set! grow index value)
      "Replace populated GROW element at INDEX with VALUE."
      #((parameters
         (grow (type growable-vector) (description "Storage to mutate."))
         (index (type exact-non-negative-integer)
          (description "Populated zero-based index."))
         (value (type any) (description "Replacement value.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects state-write error))
      (check-growable-vector-index
       "consent-growable-vector-set!" grow index)
      (vector-set! (growable-vector-data grow) index value)
      value)

    (define (consent-growable-vector-snapshot grow)
      "Return a fresh fixed vector containing GROW's populated prefix."
      #((parameters
         (grow (type growable-vector) (description "Storage to snapshot.")))
        (returns (type vector)
         (description "Fresh populated-prefix copy."))
        (effects allocation state-read error))
      (check-growable-vector "consent-growable-vector-snapshot" grow)
      (let* ((length (growable-vector-length grow))
             (snapshot
              (allocate-storage
               "consent-growable-vector-snapshot" length)))
        (let copy ((index 0))
          (if (< index length)
              (begin
                (vector-set!
                 snapshot index
                 (vector-ref (growable-vector-data grow) index))
                (copy (+ index 1)))))
        snapshot))

    (define (consent-growable-vector-reset! grow)
      "Clear GROW's populated prefix while retaining reserved storage."
      #((parameters
         (grow (type growable-vector) (description "Storage to reset.")))
        (returns (type growable-vector)
         (description "The empty active GROW."))
        (effects state-write error))
      (growable-vector-truncate!
       "consent-growable-vector-reset!" grow 0))

    (define (consent-growable-vector-release! grow)
      "Clear and permanently release GROW's backing storage."
      #((parameters
         (grow (type growable-vector) (description "Storage to release.")))
        (returns (type growable-vector)
         (description "The inactive released GROW."))
        (effects state-write error))
      (if (not (consent-growable-vector? grow))
          (error
           "consent-growable-vector-release!: expected growable vector"
           grow))
      (if (growable-vector-active? grow)
          (begin
            (growable-vector-truncate!
             "consent-growable-vector-release!" grow 0)
            (set-growable-vector-data!
             grow growable-vector-empty-storage)
            (set-growable-vector-active! grow #f)))
      grow)

    (define (consent-growable-vector-unused-slots-cleared? grow)
      "Return whether every slot outside GROW's prefix contains false."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect.")))
        (returns (type boolean)
         (description "Whether unused storage retains no references."))
        (effects state-read error))
      (if (not (consent-growable-vector? grow))
          (error
           "unused-slots-cleared?: expected growable vector" grow))
      (let ((data (growable-vector-data grow)))
        (let loop ((index (growable-vector-length grow)))
          (or (= index (vector-length data))
              (and (eq? (vector-ref data index) #f)
                   (loop (+ index 1)))))))

    (define (consent-growable-vector-stats grow)
      "Return deterministic Scheme-readable allocation statistics for GROW."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect.")))
        (returns (type list)
         (description "Private growable-vector statistics datum."))
        (effects state-read error))
      (if (not (consent-growable-vector? grow))
          (error "consent-growable-vector-stats: expected vector" grow))
      (list
       'growable-vector-stats
       (list 'length (growable-vector-length grow))
       (list 'capacity (vector-length (growable-vector-data grow)))
       (list 'maximum-capacity
             (growable-vector-maximum-capacity grow))
       (list 'high-water (growable-vector-high-water grow))
       (list 'growths (growable-vector-growth-count grow))
       (list 'copied-elements (growable-vector-copied-elements grow))
       (list 'resets (growable-vector-reset-count grow))
       (list 'released (not (growable-vector-active? grow)))))

    ;; An arena owns one reusable growable vector. One active owner record is
    ;; the phase/call token. Releasing that token clears the populated prefix
    ;; before the arena can issue a fresh token, so escaped owners never become
    ;; valid again when the backing capacity is reused.
    (define-record-type <consent-scratch-arena>
      (make-scratch-arena-record
       storage growth-policy owner high-water acquisitions resets releases)
      consent-scratch-arena?
      (storage scratch-arena-storage)
      (growth-policy scratch-arena-growth-policy)
      (owner scratch-arena-owner set-scratch-arena-owner!)
      (high-water scratch-arena-high-water set-scratch-arena-high-water!)
      (acquisitions
       scratch-arena-acquisitions
       set-scratch-arena-acquisitions!)
      (resets scratch-arena-resets set-scratch-arena-resets!)
      (releases scratch-arena-releases set-scratch-arena-releases!))

    ;; One-use ownership token issued for a single arena phase.
    (define-record-type <consent-scratch-owner>
      (make-scratch-owner-record arena token phase active?)
      consent-scratch-owner?
      (arena scratch-owner-arena)
      (token scratch-owner-token)
      (phase scratch-owner-phase-value)
      (active? scratch-owner-active? set-scratch-owner-active!))

    ;; Marks carry a library-wide lifetime token, not an arena-local generation.
    ;; That prevents equal-capacity arenas acquired in the same ordinal lifetime
    ;; from accepting one another's marks.
    (define scratch-owner-next-token 0)

    (define (check-scratch-arena operation arena)
      "Validate scratch ARENA for OPERATION."
      (if (not (consent-scratch-arena? arena))
          (error (string-append operation ": expected scratch arena") arena))
      arena)

    (define (check-scratch-owner operation owner)
      "Validate active scratch OWNER for OPERATION."
      (if (not (consent-scratch-owner? owner))
          (error (string-append operation ": expected scratch owner") owner))
      (let ((arena (scratch-owner-arena owner)))
        (if (not (and (scratch-owner-active? owner)
                      (eq? (scratch-arena-owner arena) owner)))
            (error
             (string-append operation ": scratch owner is released") owner)))
      owner)

    (define (consent-make-scratch-arena
             initial-capacity maximum-capacity growth-policy)
      "Return an idle bounded scratch arena using GROWTH-POLICY."
      #((parameters
         (initial-capacity (type exact-non-negative-integer)
          (description "Capacity allocated before owner acquisition."))
         (maximum-capacity (type exact-non-negative-integer)
          (description "Largest permitted capacity."))
         (growth-policy (type symbol)
          (description "Either allow-growth or pre-reserved.")))
        (returns (type scratch-arena)
         (description "Fresh idle bounded scratch arena."))
        (effects allocation error))
      (if (not (memq growth-policy '(allow-growth pre-reserved)))
          (error
           "consent-make-scratch-arena: invalid growth policy"
           growth-policy))
      (make-scratch-arena-record
       (consent-make-growable-vector
        initial-capacity maximum-capacity)
       growth-policy
       #f
       0
       0
       0
       0))

    (define (consent-scratch-arena-reserve! arena requested)
      "Reserve REQUESTED arena slots while no owner is active."
      #((parameters
         (arena (type scratch-arena) (description "Idle arena to reserve."))
         (requested (type exact-non-negative-integer)
          (description "Minimum exact capacity.")))
        (returns (type scratch-arena)
         (description "The supplied ARENA."))
        (effects allocation state-write error))
      (check-scratch-arena "consent-scratch-arena-reserve!" arena)
      (if (scratch-arena-owner arena)
          (error
           "consent-scratch-arena-reserve!: arena has an active owner"
           arena))
      (consent-growable-vector-reserve!
       (scratch-arena-storage arena) requested)
      arena)

    (define (consent-scratch-arena-acquire! arena phase)
      "Acquire idle ARENA for symbolic PHASE and return its owner token."
      #((parameters
         (arena (type scratch-arena) (description "Idle arena to acquire."))
         (phase (type symbol) (description "Call or collector phase tag.")))
        (returns (type scratch-owner)
         (description "Fresh active owner token."))
        (effects allocation state-write error))
      (check-scratch-arena "consent-scratch-arena-acquire!" arena)
      (if (not (symbol? phase))
          (error
           "consent-scratch-arena-acquire!: expected symbolic phase" phase))
      (if (scratch-arena-owner arena)
          (error
           "consent-scratch-arena-acquire!: arena already owned" arena))
      (if (not (= (consent-growable-vector-length
                   (scratch-arena-storage arena))
                  0))
          (error
           "consent-scratch-arena-acquire!: arena storage is not empty"
           arena))
      (let* ((acquisition (+ (scratch-arena-acquisitions arena) 1))
             (token (+ scratch-owner-next-token 1))
             (owner
              (make-scratch-owner-record
               arena token phase #t)))
        (set! scratch-owner-next-token token)
        (set-scratch-arena-owner! arena owner)
        (set-scratch-arena-acquisitions! arena acquisition)
        owner))

    (define (consent-scratch-owner-active? owner)
      "Return whether OWNER still controls its arena lifetime."
      #((parameters
         (owner (type any) (description "Candidate owner token.")))
        (returns (type boolean)
         (description "Whether OWNER is the active arena owner."))
        (effects state-read))
      (and (consent-scratch-owner? owner)
           (scratch-owner-active? owner)
           (eq? (scratch-arena-owner (scratch-owner-arena owner)) owner)))

    (define (consent-scratch-owner-phase owner)
      "Return active OWNER's phase tag."
      #((parameters
         (owner (type scratch-owner) (description "Owner to inspect.")))
        (returns (type symbol) (description "Owner phase tag."))
        (effects state-read error))
      (check-scratch-owner "consent-scratch-owner-phase" owner)
      (scratch-owner-phase-value owner))

    (define (consent-scratch-owner-length owner)
      "Return active OWNER's logical scratch length."
      #((parameters
         (owner (type scratch-owner) (description "Owner to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of retained scratch elements."))
        (effects state-read error))
      (check-scratch-owner "consent-scratch-owner-length" owner)
      (consent-growable-vector-length
       (scratch-arena-storage (scratch-owner-arena owner))))

    (define (consent-scratch-owner-capacity owner)
      "Return active OWNER's reserved scratch capacity."
      #((parameters
         (owner (type scratch-owner) (description "Owner to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of reserved scratch slots."))
        (effects state-read error))
      (check-scratch-owner "consent-scratch-owner-capacity" owner)
      (consent-growable-vector-capacity
       (scratch-arena-storage (scratch-owner-arena owner))))

    (define (consent-scratch-owner-append! owner value)
      "Append VALUE within OWNER's phase and return its index."
      #((parameters
         (owner (type scratch-owner) (description "Active owner token."))
         (value (type any) (description "Scratch value to retain.")))
        (returns (type exact-non-negative-integer)
         (description "Assigned zero-based index."))
        (effects allocation state-write error))
      (check-scratch-owner "consent-scratch-owner-append!" owner)
      (let* ((arena (scratch-owner-arena owner))
             (storage (scratch-arena-storage arena))
             (length (consent-growable-vector-length storage))
             (capacity (consent-growable-vector-capacity storage)))
        (if (and (= length capacity)
                 (eq? (scratch-arena-growth-policy arena) 'pre-reserved))
            (error
             "consent-scratch-owner-append!: pre-reserved capacity exhausted"
             length
             capacity
             (scratch-owner-phase-value owner)))
        (let ((index (consent-growable-vector-append! storage value)))
          (let ((new-length (+ index 1)))
            (if (> new-length (scratch-arena-high-water arena))
                (set-scratch-arena-high-water! arena new-length)))
          index)))

    (define (consent-scratch-owner-ref owner index)
      "Return active OWNER's scratch element at INDEX."
      #((parameters
         (owner (type scratch-owner) (description "Active owner token."))
         (index (type exact-non-negative-integer)
          (description "Populated scratch index.")))
        (returns (type any) (description "Stored scratch value."))
        (effects state-read error))
      (check-scratch-owner "consent-scratch-owner-ref" owner)
      (consent-growable-vector-ref
       (scratch-arena-storage (scratch-owner-arena owner)) index))

    (define (consent-scratch-owner-set! owner index value)
      "Replace active OWNER's scratch element at INDEX with VALUE."
      #((parameters
         (owner (type scratch-owner) (description "Active owner token."))
         (index (type exact-non-negative-integer)
          (description "Populated scratch index."))
         (value (type any) (description "Replacement scratch value.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects state-write error))
      (check-scratch-owner "consent-scratch-owner-set!" owner)
      (consent-growable-vector-set!
       (scratch-arena-storage (scratch-owner-arena owner)) index value))

    (define (consent-scratch-owner-mark owner)
      "Return an ownership-stamped reset mark for active OWNER."
      #((parameters
         (owner (type scratch-owner) (description "Active owner token.")))
        (returns (type exact-non-negative-integer)
         (description "Opaque reset mark for this owner lifetime."))
        (effects state-read error))
      (check-scratch-owner "consent-scratch-owner-mark" owner)
      (let* ((arena (scratch-owner-arena owner))
             (radix
              (+ (growable-vector-maximum-capacity
                  (scratch-arena-storage arena))
                 1)))
        (+ (* (scratch-owner-token owner) radix)
           (consent-scratch-owner-length owner))))

    (define (consent-scratch-owner-reset! owner mark)
      "Clear active OWNER's scratch suffix back to MARK."
      #((parameters
         (owner (type scratch-owner) (description "Active owner token."))
         (mark (type exact-non-negative-integer)
          (description "Earlier logical length from this owner.")))
        (returns (type scratch-owner)
         (description "The supplied active OWNER."))
        (effects state-write error))
      (check-scratch-owner "consent-scratch-owner-reset!" owner)
      (let* ((arena (scratch-owner-arena owner))
             (radix
              (+ (growable-vector-maximum-capacity
                  (scratch-arena-storage arena))
                 1))
             (token
              (and (exact-nonnegative-integer? mark)
                   (quotient mark radix)))
             (length
              (and token (remainder mark radix))))
        (if (not (and token
                      (= token (scratch-owner-token owner))))
            (error
             "consent-scratch-owner-reset!: mark belongs to other lifetime"
             mark))
        (growable-vector-truncate!
         "consent-scratch-owner-reset!"
         (scratch-arena-storage arena)
         length)
        (set-scratch-arena-resets!
         arena (+ (scratch-arena-resets arena) 1)))
      owner)

    (define (consent-scratch-owner-release! owner)
      "Clear OWNER's scratch roots and permanently release its lifetime."
      #((parameters
         (owner (type scratch-owner) (description "Owner to release.")))
        (returns (type scratch-owner)
         (description "The inactive released OWNER."))
        (effects state-write error))
      (if (not (consent-scratch-owner? owner))
          (error
           "consent-scratch-owner-release!: expected scratch owner" owner))
      (if (scratch-owner-active? owner)
          (let ((arena (scratch-owner-arena owner)))
            (if (not (eq? (scratch-arena-owner arena) owner))
                (error
                 "consent-scratch-owner-release!: owner is not current"
                 owner))
            (consent-growable-vector-reset!
             (scratch-arena-storage arena))
            (set-scratch-owner-active! owner #f)
            (set-scratch-arena-owner! arena #f)
            (set-scratch-arena-releases!
             arena (+ (scratch-arena-releases arena) 1))))
      owner)

    (define (consent-scratch-arena-unused-slots-cleared? arena)
      "Return whether ARENA retains no values beyond its logical prefix."
      #((parameters
         (arena (type scratch-arena) (description "Arena to inspect.")))
        (returns (type boolean)
         (description "Whether unused scratch slots contain false."))
        (effects state-read error))
      (check-scratch-arena
       "consent-scratch-arena-unused-slots-cleared?" arena)
      (consent-growable-vector-unused-slots-cleared?
       (scratch-arena-storage arena)))

    (define (consent-scratch-arena-stats arena)
      "Return deterministic Scheme-readable lifetime statistics for ARENA."
      #((parameters
         (arena (type scratch-arena) (description "Arena to inspect.")))
        (returns (type list)
         (description "Private scratch-arena statistics datum."))
        (effects state-read error))
      (check-scratch-arena "consent-scratch-arena-stats" arena)
      (let* ((storage (scratch-arena-storage arena))
             (owner (scratch-arena-owner arena)))
        (list
         'scratch-arena-stats
         (list 'growth-policy (scratch-arena-growth-policy arena))
         (list 'active (if owner #t #f))
         (list 'phase
               (if owner (scratch-owner-phase-value owner) #f))
         (list 'length (growable-vector-length storage))
         (list 'capacity (vector-length (growable-vector-data storage)))
         (list 'maximum-capacity
               (growable-vector-maximum-capacity storage))
         (list 'high-water (scratch-arena-high-water arena))
         (list 'acquisitions (scratch-arena-acquisitions arena))
         (list 'resets (scratch-arena-resets arena))
         (list 'releases (scratch-arena-releases arena))
         (list 'storage-growths
               (growable-vector-growth-count storage))
         (list 'storage-copied-elements
               (growable-vector-copied-elements storage)))))))
