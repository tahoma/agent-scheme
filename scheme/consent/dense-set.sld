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
  (import (scheme base))
  (begin
    ;; One exact integer per identifier encodes the generation and color.
    ;; Zero is the physically clear value.  Current marks are positive.
    (define dense-set-lazy-storage (list 'dense-set-lazy-storage))

    ;; Cold counters allocate together on the first counted operation.
    (define dense-set-high-water-index 0)
    ;; Membership-test count.
    (define dense-set-membership-tests-index 1)
    ;; Color-read count.
    (define dense-set-color-reads-index 2)
    ;; Mark-operation count.
    (define dense-set-mark-operations-index 3)
    ;; Newly marked identifier count.
    (define dense-set-new-marks-index 4)
    ;; Existing-mark recolor count.
    (define dense-set-recolors-index 5)
    ;; Duplicate mark count.
    (define dense-set-duplicate-marks-index 6)
    ;; Successful unmark count.
    (define dense-set-unmarks-index 7)
    ;; Logical clear count.
    (define dense-set-clears-index 8)
    ;; Generation-advance count.
    (define dense-set-generation-advances-index 9)
    ;; Physical clear count.
    (define dense-set-physical-clears-index 10)
    ;; Slots written during physical clears.
    (define dense-set-physical-clear-slots-index 11)
    ;; Explicit and automatic capacity-change count.
    (define dense-set-capacity-changes-index 12)
    ;; Automatic capacity-growth count.
    (define dense-set-automatic-growths-index 13)
    ;; Scalars copied while replacing backing storage.
    (define dense-set-copied-elements-index 14)
    ;; Release count.
    (define dense-set-releases-index 15)
    ;; Slots cleared during releases.
    (define dense-set-release-clear-slots-index 16)
    ;; Number of slots in the statistics sidecar.
    (define dense-set-statistics-size 17)

    ;; Compact integral storage plus one lazy diagnostic sidecar.
    (define-record-type <consent-dense-set>
      (make-dense-set-record
       storage initial-capacity maximum-capacity maximum-generation
       color-count growth-policy domain generation size statistics)
      consent-dense-set?
      (storage dense-set-storage set-dense-set-storage!)
      (initial-capacity dense-set-initial-capacity-value)
      (maximum-capacity dense-set-maximum-capacity-value)
      (maximum-generation dense-set-maximum-generation-value)
      (color-count dense-set-color-count-value)
      (growth-policy dense-set-growth-policy-value)
      (domain dense-set-domain-value)
      (generation dense-set-generation-value set-dense-set-generation!)
      (size dense-set-size-value set-dense-set-size!)
      (statistics dense-set-statistics set-dense-set-statistics!))

    (define (dense-set-active? dense)
      "Return whether DENSE has not been released."
      (not (eq? (dense-set-storage dense) #f)))

    (define (dense-set-capacity-value dense)
      "Return DENSE's allocated capacity, including zero when lazy."
      (let ((storage (dense-set-storage dense)))
        (if (vector? storage) (vector-length storage) 0)))

    (define (dense-set-statistic dense index)
      "Return DENSE's cold statistic at INDEX, defaulting to zero."
      (let ((statistics (dense-set-statistics dense)))
        (if statistics (vector-ref statistics index) 0)))

    (define (dense-set-statistics-for-write! dense)
      "Return DENSE's writable cold-statistics sidecar."
      (or (dense-set-statistics dense)
          (let ((statistics (make-vector dense-set-statistics-size 0)))
            (set-dense-set-statistics! dense statistics)
            statistics)))

    (define (note-dense-set! dense index amount)
      "Add AMOUNT to DENSE's cold statistic at INDEX."
      (let ((statistics (dense-set-statistics-for-write! dense)))
        (vector-set!
         statistics index (+ (vector-ref statistics index) amount))))

    (define (note-dense-set-high-water! dense value)
      "Raise DENSE's historical high-water mark to VALUE when needed."
      (let ((current
             (dense-set-statistic dense dense-set-high-water-index)))
        (if (> value current)
            (vector-set!
             (dense-set-statistics-for-write! dense)
             dense-set-high-water-index
             value))))

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

    (define (allocate-slot-storage operation capacity)
      "Return CAPACITY zero slots or fail with a normalized condition."
      (guard (condition
              (else
               (error
                (string-append operation ": storage allocation failed")
                capacity)))
        (make-vector capacity 0)))

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
          (vector-ref (dense-set-storage dense) identifier)
          0))

    (define (replace-dense-set-capacity!
             operation dense new-capacity automatic?)
      "Replace DENSE's backing with NEW-CAPACITY scalar slots."
      (dense-set-statistics-for-write! dense)
      (let* ((old-storage (dense-set-storage dense))
             (old-capacity (dense-set-capacity-value dense))
             (new-storage
              (allocate-slot-storage operation new-capacity)))
        (if (> old-capacity 0)
            (vector-copy!
             new-storage 0 old-storage 0 old-capacity))
        (if (vector? old-storage)
            (vector-fill! old-storage 0))
        (set-dense-set-storage! dense new-storage)
        (note-dense-set! dense dense-set-capacity-changes-index 1)
        (if automatic?
            (note-dense-set!
             dense dense-set-automatic-growths-index 1))
        (note-dense-set!
         dense dense-set-copied-elements-index old-capacity))
      dense)

    (define (next-dense-set-capacity dense minimum-capacity)
      "Return DENSE's next bounded capacity covering MINIMUM-CAPACITY."
      (let ((capacity (dense-set-capacity-value dense))
            (maximum (dense-set-maximum-capacity-value dense)))
        (min
         maximum
         (max minimum-capacity
              (if (= capacity 0)
                  (max 1 (dense-set-initial-capacity-value dense))
                  (if (>= capacity (quotient maximum 2))
                      maximum
                      (* capacity 2)))))))

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
              (replace-dense-set-capacity!
               operation
               dense
               (next-dense-set-capacity dense (+ identifier 1))
               #t))))
      dense)

    (define (physical-clear! dense)
      "Physically clear DENSE's allocated slots and record their count."
      (let ((capacity (dense-set-capacity-value dense)))
        (dense-set-statistics-for-write! dense)
        (if (> capacity 0)
            (vector-fill! (dense-set-storage dense) 0))
        (note-dense-set! dense dense-set-physical-clears-index 1)
        (note-dense-set!
         dense dense-set-physical-clear-slots-index capacity))
      (set-dense-set-generation! dense 1)
      (set-dense-set-size! dense 0)
      dense)

    (define (consent-make-dense-set
             initial-capacity maximum-capacity maximum-generation
             color-count growth-policy domain)
      "Return an empty bounded generation-stamped dense set."
      #((parameters
         (initial-capacity (type exact-non-negative-integer)
          (description "First-allocation floor or eager capacity."))
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
       (if (eq? growth-policy 'pre-reserved)
           (allocate-slot-storage
            "consent-make-dense-set" initial-capacity)
           dense-set-lazy-storage)
       initial-capacity
       maximum-capacity
       maximum-generation
       color-count
       growth-policy
       domain
       1
       0
       #f))

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
      "Reserve at least REQUESTED slots when active DENSE is smaller."
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
            (replace-dense-set-capacity!
             "consent-dense-set-reserve!"
             dense
             (if (= capacity 0)
                 (max requested
                      (dense-set-initial-capacity-value dense))
                 requested)
             #f)))
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
      (note-dense-set! dense dense-set-membership-tests-index 1)
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
      (note-dense-set! dense dense-set-color-reads-index 1)
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
        (dense-set-statistics-for-write! dense)
        (ensure-identifier-capacity!
         "consent-dense-set-mark!" dense identifier)
        (let* ((slot (dense-set-slot dense identifier))
               (current? (slot-current? dense slot))
               (previous (and current? (slot-color dense slot))))
          (vector-set!
           (dense-set-storage dense) identifier (slot-encode dense color))
          (note-dense-set! dense dense-set-mark-operations-index 1)
          (cond
           ((not current?)
            (set-dense-set-size!
             dense (+ (dense-set-size-value dense) 1))
            (note-dense-set! dense dense-set-new-marks-index 1))
           ((= previous color)
            (note-dense-set! dense dense-set-duplicate-marks-index 1))
           (else
            (note-dense-set! dense dense-set-recolors-index 1)))
          (note-dense-set-high-water! dense (+ identifier 1))
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
              (dense-set-statistics-for-write! dense)
              (vector-set! (dense-set-storage dense) identifier 0)
              (set-dense-set-size!
               dense (- (dense-set-size-value dense) 1))
              (note-dense-set! dense dense-set-unmarks-index 1)
              previous)
            #f)))

    (define (consent-dense-set-clear! dense)
      "Logically clear DENSE, physically clearing only on generation wrap."
      #((parameters
         (dense (type dense-set) (description "Dense set to clear.")))
        (returns (type dense-set) (description "The empty supplied DENSE."))
        (effects state-write error))
      (check-dense-set "consent-dense-set-clear!" dense)
      (dense-set-statistics-for-write! dense)
      (if (= (dense-set-generation-value dense)
             (dense-set-maximum-generation-value dense))
          (physical-clear! dense)
          (begin
            (set-dense-set-generation!
             dense (+ (dense-set-generation-value dense) 1))
            (set-dense-set-size! dense 0)
            (note-dense-set!
             dense dense-set-generation-advances-index 1)))
      (note-dense-set! dense dense-set-clears-index 1)
      dense)

    (define (consent-dense-set-full-clear! dense)
      "Explicitly physically clear every reserved slot in active DENSE."
      #((parameters
         (dense (type dense-set) (description "Dense set to clear.")))
        (returns (type dense-set) (description "The empty supplied DENSE."))
        (effects state-write error))
      (check-dense-set "consent-dense-set-full-clear!" dense)
      (physical-clear! dense)
      (note-dense-set! dense dense-set-clears-index 1)
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
            (dense-set-statistics-for-write! dense)
            (if (> capacity 0)
                (vector-fill! (dense-set-storage dense) 0))
            (note-dense-set!
             dense dense-set-release-clear-slots-index capacity)
            (set-dense-set-size! dense 0)
            (note-dense-set! dense dense-set-releases-index 1)
            (set-dense-set-storage! dense #f)))
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
                 (vector-ref storage index))
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
       (list 'high-water
             (dense-set-statistic dense dense-set-high-water-index))
       (list 'membership-tests
             (dense-set-statistic
              dense dense-set-membership-tests-index))
       (list 'color-reads
             (dense-set-statistic dense dense-set-color-reads-index))
       (list 'mark-operations
             (dense-set-statistic
              dense dense-set-mark-operations-index))
       (list 'new-marks
             (dense-set-statistic dense dense-set-new-marks-index))
       (list 'recolors
             (dense-set-statistic dense dense-set-recolors-index))
       (list 'duplicate-marks
             (dense-set-statistic
              dense dense-set-duplicate-marks-index))
       (list 'unmarks
             (dense-set-statistic dense dense-set-unmarks-index))
       (list 'clears
             (dense-set-statistic dense dense-set-clears-index))
       (list 'generation-advances
             (dense-set-statistic
              dense dense-set-generation-advances-index))
       (list 'physical-clears
             (dense-set-statistic
              dense dense-set-physical-clears-index))
       (list 'physical-clear-slots
             (dense-set-statistic
              dense dense-set-physical-clear-slots-index))
       (list 'capacity-changes
             (dense-set-statistic
              dense dense-set-capacity-changes-index))
       (list 'automatic-growths
             (dense-set-statistic
              dense dense-set-automatic-growths-index))
       (list 'copied-elements
             (dense-set-statistic
              dense dense-set-copied-elements-index))
       (list 'releases
             (dense-set-statistic dense dense-set-releases-index))
       (list 'release-clear-slots
             (dense-set-statistic
              dense dense-set-release-clear-slots-index))))))
