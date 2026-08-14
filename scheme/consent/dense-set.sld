;;; Bootstrap-safe generation-stamped dense sets.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This private library owns callback-free membership and small-color marks
;;; over bounded dense integer identifiers.  Each slot stores one exact integer
;;; containing only an epoch and color, so stale epochs retain no marked value.

(define-library (consent dense-set)
  (export consent-make-dense-set
          consent-dense-set?
          consent-dense-set-active?
          consent-dense-set-domain
          consent-dense-set-empty?
          consent-dense-set-size
          consent-dense-set-capacity
          consent-dense-set-maximum-capacity
          consent-dense-set-maximum-generation
          consent-dense-set-color-count
          consent-dense-set-growth-policy
          consent-dense-set-generation
          consent-dense-set-reserve!
          consent-dense-set-member?
          consent-dense-set-color
          consent-dense-set-mark!
          consent-dense-set-unmark!
          consent-dense-set-clear!
          consent-dense-set-full-clear!
          consent-dense-set-release!
          consent-dense-set-integral-storage?
          consent-dense-set-stats)
  (import (scheme base)
          (only (consent growable-vector)
                consent-growable-vector-append!
                consent-growable-vector-capacity
                consent-growable-vector-fill!
                consent-growable-vector-grow!
                consent-growable-vector-release!
                consent-growable-vector-reserve!
                consent-growable-vector-unsafe-ref
                consent-growable-vector-unsafe-set!
                consent-make-growable-vector))
  (begin
    ;; One exact integer per identifier encodes the generation and color.
    ;; Zero is the physically clear value.  Current marks are positive.
    (define-record-type <consent-dense-set>
      (make-dense-set-record
       storage capacity maximum-capacity maximum-generation color-count
       growth-policy domain generation size high-water
       membership-tests color-reads mark-operations new-marks recolors
       duplicate-marks unmarks clears generation-advances physical-clears
       physical-clear-slots capacity-changes automatic-growths
       copied-elements releases release-clear-slots active?)
      consent-dense-set?
      (storage dense-set-storage)
      (capacity dense-set-capacity-value set-dense-set-capacity!)
      (maximum-capacity dense-set-maximum-capacity-value)
      (maximum-generation dense-set-maximum-generation-value)
      (color-count dense-set-color-count-value)
      (growth-policy dense-set-growth-policy-value)
      (domain dense-set-domain-value)
      (generation dense-set-generation-value set-dense-set-generation!)
      (size dense-set-size-value set-dense-set-size!)
      (high-water dense-set-high-water set-dense-set-high-water!)
      (membership-tests
       dense-set-membership-tests
       set-dense-set-membership-tests!)
      (color-reads dense-set-color-reads set-dense-set-color-reads!)
      (mark-operations
       dense-set-mark-operations
       set-dense-set-mark-operations!)
      (new-marks dense-set-new-marks set-dense-set-new-marks!)
      (recolors dense-set-recolors set-dense-set-recolors!)
      (duplicate-marks
       dense-set-duplicate-marks
       set-dense-set-duplicate-marks!)
      (unmarks dense-set-unmarks set-dense-set-unmarks!)
      (clears dense-set-clears set-dense-set-clears!)
      (generation-advances
       dense-set-generation-advances
       set-dense-set-generation-advances!)
      (physical-clears
       dense-set-physical-clears
       set-dense-set-physical-clears!)
      (physical-clear-slots
       dense-set-physical-clear-slots
       set-dense-set-physical-clear-slots!)
      (capacity-changes
       dense-set-capacity-changes
       set-dense-set-capacity-changes!)
      (automatic-growths
       dense-set-automatic-growths
       set-dense-set-automatic-growths!)
      (copied-elements
       dense-set-copied-elements
       set-dense-set-copied-elements!)
      (releases dense-set-releases set-dense-set-releases!)
      (release-clear-slots
       dense-set-release-clear-slots
       set-dense-set-release-clear-slots!)
      (active? dense-set-active? set-dense-set-active!))

    (define (exact-nonnegative-integer? value)
      "Return whether VALUE is an exact nonnegative integer."
      (and (integer? value) (exact? value) (>= value 0)))

    (define (exact-positive-integer? value)
      "Return whether VALUE is an exact positive integer."
      (and (exact-nonnegative-integer? value) (> value 0)))

    (define (check-capacity operation capacity)
      "Validate CAPACITY as an exact nonnegative integer."
      (if (not (exact-nonnegative-integer? capacity))
          (error
           (string-append operation
                          ": expected exact nonnegative capacity")
           capacity))
      capacity)

    (define (check-positive operation description value)
      "Validate positive exact VALUE for OPERATION and DESCRIPTION."
      (if (not (exact-positive-integer? value))
          (error
           (string-append operation ": expected positive " description)
           value))
      value)

    (define (check-growth-policy operation growth-policy)
      "Validate GROWTH-POLICY for OPERATION."
      (if (not (memq growth-policy '(allow-growth pre-reserved)))
          (error
           (string-append operation
                          ": expected allow-growth or pre-reserved")
           growth-policy))
      growth-policy)

    (define (check-dense-set operation dense)
      "Validate active dense set DENSE for OPERATION."
      (if (not (consent-dense-set? dense))
          (error (string-append operation ": expected dense set") dense))
      (if (not (dense-set-active? dense))
          (error (string-append operation ": dense set is released") dense))
      dense)

    (define (check-identifier operation dense identifier)
      "Validate IDENTIFIER within DENSE's configured identifier range."
      (check-dense-set operation dense)
      (if (not (and (exact-nonnegative-integer? identifier)
                    (< identifier
                       (dense-set-maximum-capacity-value dense))))
          (error
           (string-append operation ": identifier outside configured range")
           identifier
           (dense-set-maximum-capacity-value dense)))
      identifier)

    (define (check-color operation dense color)
      "Validate COLOR within DENSE's configured finite color range."
      (if (not (and (exact-nonnegative-integer? color)
                    (< color (dense-set-color-count-value dense))))
          (error
           (string-append operation ": color outside configured range")
           color
           (dense-set-color-count-value dense)))
      color)

    (define (make-slot-storage initial-capacity maximum-capacity)
      "Return growable storage with INITIAL-CAPACITY zero slots."
      (let ((storage
             (consent-make-growable-vector
              initial-capacity maximum-capacity)))
        (let fill ((index 0))
          (if (< index initial-capacity)
              (begin
                (consent-growable-vector-append! storage 0)
                (fill (+ index 1)))))
        storage))

    (define (slot-encode dense color)
      "Encode DENSE's current generation and COLOR as one positive integer."
      (+ 1
         color
         (* (dense-set-generation-value dense)
            (dense-set-color-count-value dense))))

    (define (slot-generation dense slot)
      "Return the generation encoded in positive SLOT for DENSE."
      (quotient (- slot 1) (dense-set-color-count-value dense)))

    (define (slot-color dense slot)
      "Return the finite color encoded in positive SLOT for DENSE."
      (remainder (- slot 1) (dense-set-color-count-value dense)))

    (define (slot-current? dense slot)
      "Return whether encoded SLOT belongs to DENSE's current generation."
      (and (> slot 0)
           (= (slot-generation dense slot)
              (dense-set-generation-value dense))))

    (define (dense-set-slot dense identifier)
      "Return IDENTIFIER's encoded slot, or zero beyond current capacity."
      (if (< identifier (dense-set-capacity-value dense))
          (consent-growable-vector-unsafe-ref
           (dense-set-storage dense) identifier)
          0))

    (define (populate-storage-to-capacity! dense old-capacity new-capacity)
      "Append clear slots from OLD-CAPACITY through NEW-CAPACITY."
      (let fill ((index old-capacity))
        (if (< index new-capacity)
            (begin
              (consent-growable-vector-append!
               (dense-set-storage dense) 0)
              (fill (+ index 1)))))
      (set-dense-set-capacity! dense new-capacity)
      dense)

    (define (note-capacity-change!
             dense old-capacity new-capacity automatic?)
      "Record DENSE capacity change from OLD-CAPACITY to NEW-CAPACITY."
      (set-dense-set-capacity-changes!
       dense (+ (dense-set-capacity-changes dense) 1))
      (if automatic?
          (set-dense-set-automatic-growths!
           dense (+ (dense-set-automatic-growths dense) 1)))
      (set-dense-set-copied-elements!
       dense (+ (dense-set-copied-elements dense) old-capacity))
      (populate-storage-to-capacity!
       dense old-capacity new-capacity))

    (define (ensure-identifier-capacity! operation dense identifier)
      "Grow DENSE when needed to address IDENTIFIER for OPERATION."
      (let ((capacity (dense-set-capacity-value dense)))
        (if (>= identifier capacity)
            (begin
              (if (eq? (dense-set-growth-policy-value dense) 'pre-reserved)
                  (error
                   (string-append operation
                                  ": pre-reserved capacity exhausted")
                   identifier
                   capacity))
              (consent-growable-vector-grow!
               (dense-set-storage dense) (+ identifier 1))
              (note-capacity-change!
               dense
               capacity
               (consent-growable-vector-capacity
                (dense-set-storage dense))
               #t))))
      dense)

    (define (physical-clear! dense)
      "Physically clear DENSE's allocated slots and record their count."
      (let ((capacity (dense-set-capacity-value dense)))
        (consent-growable-vector-fill!
         (dense-set-storage dense) 0 0 capacity)
        (set-dense-set-physical-clears!
         dense (+ (dense-set-physical-clears dense) 1))
        (set-dense-set-physical-clear-slots!
         dense (+ (dense-set-physical-clear-slots dense) capacity)))
      (set-dense-set-generation! dense 1)
      (set-dense-set-size! dense 0)
      dense)

    (define (consent-make-dense-set
             initial-capacity maximum-capacity maximum-generation
             color-count growth-policy domain)
      "Return an empty bounded generation-stamped dense set."
      #((parameters
         (initial-capacity (type exact-non-negative-integer)
          (description "Initially reserved identifier slots."))
         (maximum-capacity (type exact-non-negative-integer)
          (description "Exclusive upper identifier bound."))
         (maximum-generation (type exact-positive-integer)
          (description "Generation that forces the next clear to wrap."))
         (color-count (type exact-positive-integer)
          (description "Number of finite mark colors."))
         (growth-policy (type symbol)
          (description "Either allow-growth or pre-reserved."))
         (domain (type symbol)
          (description "Private ownership-domain label.")))
        (returns (type dense-set)
         (description "Fresh active private dense set."))
        (effects allocation error))
      (check-capacity "consent-make-dense-set initial" initial-capacity)
      (check-capacity "consent-make-dense-set maximum" maximum-capacity)
      (check-positive
       "consent-make-dense-set" "maximum generation" maximum-generation)
      (check-positive
       "consent-make-dense-set" "color count" color-count)
      (check-growth-policy "consent-make-dense-set" growth-policy)
      (if (not (symbol? domain))
          (error
           "consent-make-dense-set: expected symbolic ownership domain"
           domain))
      (if (> initial-capacity maximum-capacity)
          (error
           "consent-make-dense-set: initial capacity exceeds maximum"
           initial-capacity
           maximum-capacity))
      (make-dense-set-record
       (make-slot-storage initial-capacity maximum-capacity)
       initial-capacity
       maximum-capacity
       maximum-generation
       color-count
       growth-policy
       domain
       1
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
       0
       0
       0
       0
       0
       0
       0
       0
       #t))

    (define (consent-dense-set-active? dense)
      "Return whether DENSE is an active unreleased dense set."
      #((parameters
         (dense (type any) (description "Candidate object.")))
        (returns (type boolean)
         (description "Whether DENSE is active."))
        (effects pure))
      (and (consent-dense-set? dense) (dense-set-active? dense)))

    (define (consent-dense-set-domain dense)
      "Return active DENSE's immutable ownership-domain label."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type symbol) (description "Ownership-domain label."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-domain" dense)
      (dense-set-domain-value dense))

    (define (consent-dense-set-empty? dense)
      "Return whether active DENSE has no current marks."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type boolean)
         (description "Whether the current epoch is empty."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-empty?" dense)
      (= (dense-set-size-value dense) 0))

    (define (consent-dense-set-size dense)
      "Return active DENSE's current marked-identifier count."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Current distinct marked identifiers."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-size" dense)
      (dense-set-size-value dense))

    (define (consent-dense-set-capacity dense)
      "Return active DENSE's currently reserved identifier capacity."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Reserved identifier slots."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-capacity" dense)
      (dense-set-capacity-value dense))

    (define (consent-dense-set-maximum-capacity dense)
      "Return active DENSE's immutable maximum capacity."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Exclusive upper identifier bound."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-maximum-capacity" dense)
      (dense-set-maximum-capacity-value dense))

    (define (consent-dense-set-maximum-generation dense)
      "Return active DENSE's generation wrap boundary."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type exact-positive-integer)
         (description "Maximum current generation."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-maximum-generation" dense)
      (dense-set-maximum-generation-value dense))

    (define (consent-dense-set-color-count dense)
      "Return active DENSE's configured finite color count."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type exact-positive-integer)
         (description "Number of available mark colors."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-color-count" dense)
      (dense-set-color-count-value dense))

    (define (consent-dense-set-growth-policy dense)
      "Return active DENSE's immutable growth policy."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type symbol)
         (description "Either allow-growth or pre-reserved."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-growth-policy" dense)
      (dense-set-growth-policy-value dense))

    (define (consent-dense-set-generation dense)
      "Return active DENSE's current generation."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type exact-positive-integer)
         (description "Current bounded generation."))
        (effects state-read error))
      (check-dense-set "consent-dense-set-generation" dense)
      (dense-set-generation-value dense))

    (define (consent-dense-set-reserve! dense requested)
      "Reserve exactly REQUESTED slots when active DENSE is smaller."
      #((parameters
         (dense (type dense-set) (description "Dense set to reserve."))
         (requested (type exact-non-negative-integer)
          (description "Minimum exact capacity.")))
        (returns (type dense-set) (description "The supplied DENSE."))
        (effects allocation state-write error))
      (check-dense-set "consent-dense-set-reserve!" dense)
      (check-capacity "consent-dense-set-reserve!" requested)
      (if (> requested (dense-set-maximum-capacity-value dense))
          (error
           "consent-dense-set-reserve!: maximum capacity exceeded"
           requested
           (dense-set-maximum-capacity-value dense)))
      (let ((capacity (dense-set-capacity-value dense)))
        (if (> requested capacity)
            (begin
              (consent-growable-vector-reserve!
               (dense-set-storage dense) requested)
              (note-capacity-change!
               dense capacity requested #f))))
      dense)

    (define (consent-dense-set-member? dense identifier)
      "Return whether IDENTIFIER is marked in active DENSE's current epoch."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect."))
         (identifier (type exact-non-negative-integer)
          (description "Dense identifier to test.")))
        (returns (type boolean)
         (description "Whether IDENTIFIER is currently marked."))
        (effects state-read state-write error))
      (check-identifier "consent-dense-set-member?" dense identifier)
      (set-dense-set-membership-tests!
       dense (+ (dense-set-membership-tests dense) 1))
      (slot-current? dense (dense-set-slot dense identifier)))

    (define (consent-dense-set-color dense identifier)
      "Return IDENTIFIER's current color, or false when it is unmarked."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect."))
         (identifier (type exact-non-negative-integer)
          (description "Dense identifier to inspect.")))
        (returns (type (or exact-non-negative-integer boolean))
         (description "Current finite color, or false."))
        (effects state-read state-write error))
      (check-identifier "consent-dense-set-color" dense identifier)
      (set-dense-set-color-reads!
       dense (+ (dense-set-color-reads dense) 1))
      (let ((slot (dense-set-slot dense identifier)))
        (if (slot-current? dense slot)
            (slot-color dense slot)
            #f)))

    (define (consent-dense-set-mark! dense identifier . maybe-color)
      "Mark IDENTIFIER with an optional finite COLOR in active DENSE."
      #((parameters
         (dense (type dense-set) (description "Dense set to mutate."))
         (identifier (type exact-non-negative-integer)
          (description "Dense identifier to mark."))
         (maybe-color (type list)
          (description "Optional exact nonnegative color.")))
        (returns (type (or exact-non-negative-integer boolean))
         (description "Previous current color, or false when newly marked."))
        (effects allocation state-read state-write error))
      (check-identifier "consent-dense-set-mark!" dense identifier)
      (if (> (length maybe-color) 1)
          (error "consent-dense-set-mark!: too many colors"))
      (let ((color (if (null? maybe-color) 0 (car maybe-color))))
        (check-color "consent-dense-set-mark!" dense color)
        (ensure-identifier-capacity!
         "consent-dense-set-mark!" dense identifier)
        (let* ((slot (dense-set-slot dense identifier))
               (current? (slot-current? dense slot))
               (previous (and current? (slot-color dense slot))))
          (consent-growable-vector-unsafe-set!
           (dense-set-storage dense) identifier (slot-encode dense color))
          (set-dense-set-mark-operations!
           dense (+ (dense-set-mark-operations dense) 1))
          (cond
           ((not current?)
            (set-dense-set-size!
             dense (+ (dense-set-size-value dense) 1))
            (set-dense-set-new-marks!
             dense (+ (dense-set-new-marks dense) 1)))
           ((= previous color)
            (set-dense-set-duplicate-marks!
             dense (+ (dense-set-duplicate-marks dense) 1)))
           (else
            (set-dense-set-recolors!
             dense (+ (dense-set-recolors dense) 1))))
          (if (> (+ identifier 1) (dense-set-high-water dense))
              (set-dense-set-high-water! dense (+ identifier 1)))
          previous)))

    (define (consent-dense-set-unmark! dense identifier)
      "Unmark IDENTIFIER in active DENSE and return its prior color."
      #((parameters
         (dense (type dense-set) (description "Dense set to mutate."))
         (identifier (type exact-non-negative-integer)
          (description "Dense identifier to unmark.")))
        (returns (type (or exact-non-negative-integer boolean))
         (description "Previous current color, or false."))
        (effects state-read state-write error))
      (check-identifier "consent-dense-set-unmark!" dense identifier)
      (let ((slot (dense-set-slot dense identifier)))
        (if (slot-current? dense slot)
            (let ((previous (slot-color dense slot)))
              (consent-growable-vector-unsafe-set!
               (dense-set-storage dense) identifier 0)
              (set-dense-set-size!
               dense (- (dense-set-size-value dense) 1))
              (set-dense-set-unmarks!
               dense (+ (dense-set-unmarks dense) 1))
              previous)
            #f)))

    (define (consent-dense-set-clear! dense)
      "Logically clear DENSE, physically clearing only on generation wrap."
      #((parameters
         (dense (type dense-set) (description "Dense set to clear.")))
        (returns (type dense-set) (description "The empty supplied DENSE."))
        (effects state-write error))
      (check-dense-set "consent-dense-set-clear!" dense)
      (if (= (dense-set-generation-value dense)
             (dense-set-maximum-generation-value dense))
          (physical-clear! dense)
          (begin
            (set-dense-set-generation!
             dense (+ (dense-set-generation-value dense) 1))
            (set-dense-set-size! dense 0)
            (set-dense-set-generation-advances!
             dense (+ (dense-set-generation-advances dense) 1))))
      (set-dense-set-clears! dense (+ (dense-set-clears dense) 1))
      dense)

    (define (consent-dense-set-full-clear! dense)
      "Explicitly physically clear every reserved slot in active DENSE."
      #((parameters
         (dense (type dense-set) (description "Dense set to clear.")))
        (returns (type dense-set) (description "The empty supplied DENSE."))
        (effects state-write error))
      (check-dense-set "consent-dense-set-full-clear!" dense)
      (physical-clear! dense)
      (set-dense-set-clears! dense (+ (dense-set-clears dense) 1))
      dense)

    (define (consent-dense-set-release! dense)
      "Clear DENSE's scalar slots and permanently release its lifetime."
      #((parameters
         (dense (type dense-set) (description "Dense set to release.")))
        (returns (type dense-set)
         (description "The inactive released DENSE."))
        (effects state-write error))
      (if (not (consent-dense-set? dense))
          (error "consent-dense-set-release!: expected dense set" dense))
      (if (dense-set-active? dense)
          (let ((capacity (dense-set-capacity-value dense)))
            (consent-growable-vector-release! (dense-set-storage dense))
            (set-dense-set-release-clear-slots!
             dense (+ (dense-set-release-clear-slots dense) capacity))
            (set-dense-set-capacity! dense 0)
            (set-dense-set-size! dense 0)
            (set-dense-set-releases!
             dense (+ (dense-set-releases dense) 1))
            (set-dense-set-active! dense #f)))
      dense)

    (define (consent-dense-set-integral-storage? dense)
      "Return whether DENSE's backing slots contain only exact integers."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type boolean)
         (description "Whether no slot can retain a marked object."))
        (effects state-read error))
      (if (not (consent-dense-set? dense))
          (error
           "consent-dense-set-integral-storage?: expected dense set" dense))
      (if (not (dense-set-active? dense))
          #t
          (let ((storage (dense-set-storage dense))
                (capacity (dense-set-capacity-value dense)))
            (let loop ((index 0))
              (cond
               ((= index capacity) #t)
               ((exact-nonnegative-integer?
                 (consent-growable-vector-unsafe-ref storage index))
                (loop (+ index 1)))
               (else #f))))))

    (define (consent-dense-set-stats dense)
      "Return deterministic lifetime statistics for DENSE."
      #((parameters
         (dense (type dense-set) (description "Dense set to inspect.")))
        (returns (type list)
         (description "Private dense-set statistics datum."))
        (effects allocation state-read error))
      (if (not (consent-dense-set? dense))
          (error "consent-dense-set-stats: expected dense set" dense))
      (list
       'dense-set-stats
       (list 'domain (dense-set-domain-value dense))
       (list 'growth-policy (dense-set-growth-policy-value dense))
       (list 'active (dense-set-active? dense))
       (list 'size (dense-set-size-value dense))
       (list 'capacity (dense-set-capacity-value dense))
       (list 'maximum-capacity
             (dense-set-maximum-capacity-value dense))
       (list 'generation (dense-set-generation-value dense))
       (list 'maximum-generation
             (dense-set-maximum-generation-value dense))
       (list 'color-count (dense-set-color-count-value dense))
       (list 'high-water (dense-set-high-water dense))
       (list 'membership-tests (dense-set-membership-tests dense))
       (list 'color-reads (dense-set-color-reads dense))
       (list 'mark-operations (dense-set-mark-operations dense))
       (list 'new-marks (dense-set-new-marks dense))
       (list 'recolors (dense-set-recolors dense))
       (list 'duplicate-marks (dense-set-duplicate-marks dense))
       (list 'unmarks (dense-set-unmarks dense))
       (list 'clears (dense-set-clears dense))
       (list 'generation-advances
             (dense-set-generation-advances dense))
       (list 'physical-clears (dense-set-physical-clears dense))
       (list 'physical-clear-slots
             (dense-set-physical-clear-slots dense))
       (list 'capacity-changes (dense-set-capacity-changes dense))
       (list 'automatic-growths (dense-set-automatic-growths dense))
       (list 'copied-elements (dense-set-copied-elements dense))
       (list 'releases (dense-set-releases dense))
       (list 'release-clear-slots
             (dense-set-release-clear-slots dense))))))
