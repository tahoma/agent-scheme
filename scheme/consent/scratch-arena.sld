;;; Bootstrap-safe bounded scratch arenas.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This private library layers phase-owned scratch lifetimes and stamped marks
;;; over bounded growable vectors. It keeps collector policy, ownership, reset,
;;; and continuation safety separate from the underlying storage mechanism.

(define-library (consent scratch-arena)
  (export consent-make-scratch-arena
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
  (import (scheme base)
          (only (consent growable-vector)
                consent-growable-vector-append!
                consent-growable-vector-capacity
                consent-growable-vector-length
                consent-growable-vector-maximum-capacity
                consent-growable-vector-ref
                consent-growable-vector-reserve!
                consent-growable-vector-reset!
                consent-growable-vector-set!
                consent-growable-vector-stats
                consent-growable-vector-truncate!
                consent-growable-vector-unused-slots-cleared?
                consent-make-growable-vector))
  (begin
    (define (exact-nonnegative-integer? value)
      "Return whether VALUE is an exact nonnegative integer."
      (and (integer? value) (exact? value) (>= value 0)))

    (define (growable-vector-stats-ref storage name)
      "Return NAME from STORAGE's private statistics datum."
      (let ((field (assq name (cdr (consent-growable-vector-stats storage)))))
        (if field
            (cadr field)
            (error "scratch arena: missing growable-vector statistic" name))))

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
              (+ (consent-growable-vector-maximum-capacity
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
              (+ (consent-growable-vector-maximum-capacity
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
        (consent-growable-vector-truncate!
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
         (list 'length (consent-growable-vector-length storage))
         (list 'capacity (consent-growable-vector-capacity storage))
         (list 'maximum-capacity
               (consent-growable-vector-maximum-capacity storage))
         (list 'high-water (scratch-arena-high-water arena))
         (list 'acquisitions (scratch-arena-acquisitions arena))
         (list 'resets (scratch-arena-resets arena))
         (list 'releases (scratch-arena-releases arena))
         (list 'storage-growths
               (growable-vector-stats-ref storage 'growths))
         (list 'storage-copied-elements
               (growable-vector-stats-ref storage 'copied-elements)))))
))
