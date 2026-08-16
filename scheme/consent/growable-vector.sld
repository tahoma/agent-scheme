;;; Bootstrap-safe bounded growable vectors.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This private library owns callback-free growable storage for bootstrap and
;;; runtime algorithms. Exact capacity ceilings prevent integer wraparound from
;;; becoming an allocation request. Allocation failures are normalized before
;;; partially initialized storage is published.

(define-library (consent growable-vector)
  (export consent-make-growable-vector
          consent-growable-vector?
          consent-growable-vector-active?
          consent-growable-vector-length
          consent-growable-vector-capacity
          consent-growable-vector-maximum-capacity
          consent-growable-vector-growth-factor
          consent-growable-vector-append!
          consent-growable-vector-ref
          consent-growable-vector-set!
          consent-growable-vector-unsafe-ref
          consent-growable-vector-unsafe-set!
          consent-growable-vector-copy!
          consent-growable-vector-fill!
          consent-growable-vector-reserve!
          consent-growable-vector-grow!
          consent-growable-vector-snapshot
          consent-growable-vector-truncate!
          consent-growable-vector-clear!
          consent-growable-vector-reset!
          consent-growable-vector-release!
          consent-growable-vector-unused-slots-cleared?
          consent-growable-vector-stats)
  (import (scheme base))
  (begin
    ;; Initial capacity zero is active but owns no backing vector.
    (define growable-vector-lazy-storage
      (list 'growable-vector-lazy-storage))

    ;; Cold counters allocate together on the first operation that can record
    ;; one. Capacity and active state remain derivable from DATA.
    (define growable-vector-high-water-index 0)
    ;; Automatic backing-vector growth count.
    (define growable-vector-growth-count-index 1)
    ;; Elements copied while replacing backing storage.
    (define growable-vector-copied-elements-index 2)
    ;; Logical reset count.
    (define growable-vector-reset-count-index 3)
    ;; Number of slots in the statistics sidecar.
    (define growable-vector-statistics-size 4)

    ;; Mutable bounded vector state with a lazy diagnostic sidecar.
    (define-record-type <consent-growable-vector>
      (make-growable-vector-record
       length data initial-capacity maximum-capacity growth-factor statistics)
      consent-growable-vector?
      (length growable-vector-length set-growable-vector-length!)
      (data growable-vector-data set-growable-vector-data!)
      (initial-capacity growable-vector-initial-capacity)
      (maximum-capacity growable-vector-maximum-capacity)
      (growth-factor growable-vector-growth-factor)
      (statistics
       growable-vector-statistics
       set-growable-vector-statistics!))

    (define (growable-vector-active? grow)
      "Return whether GROW's lifetime remains active."
      (not (eq? (growable-vector-data grow) #f)))

    (define (growable-vector-capacity-value grow)
      "Return GROW's allocated capacity, including zero when lazy."
      (let ((data (growable-vector-data grow)))
        (if (vector? data) (vector-length data) 0)))

    (define (growable-vector-statistic grow index)
      "Return GROW's cold statistic at INDEX, defaulting to zero."
      (let ((statistics (growable-vector-statistics grow)))
        (if statistics (vector-ref statistics index) 0)))

    (define (growable-vector-statistics-for-write! grow)
      "Return GROW's writable cold-statistics sidecar."
      (or (growable-vector-statistics grow)
          (let ((statistics
                 (make-vector growable-vector-statistics-size 0)))
            (set-growable-vector-statistics! grow statistics)
            statistics)))

    (define (growable-vector-note! grow index amount)
      "Add AMOUNT to GROW's cold statistic at INDEX."
      (let ((statistics (growable-vector-statistics-for-write! grow)))
        (vector-set!
         statistics index (+ (vector-ref statistics index) amount))))

    (define (growable-vector-note-high-water! grow length)
      "Raise GROW's historical high-water mark to LENGTH when needed."
      (let ((current
             (growable-vector-statistic
              grow growable-vector-high-water-index)))
        (if (> length current)
            (let ((statistics (growable-vector-statistics-for-write! grow)))
              (vector-set!
               statistics growable-vector-high-water-index length)))))

    (define (exact-nonnegative-integer? value)
      "Return whether VALUE is an exact nonnegative integer."
      (and (integer? value) (exact? value) (>= value 0)))

    (define (check-capacity operation capacity)
      "Validate CAPACITY as an exact nonnegative integer for OPERATION."
      (if (not (exact-nonnegative-integer? capacity))
          (error
           (string-append operation ": expected exact nonnegative capacity")
           capacity)))

    (define (check-growth-factor operation growth-factor)
      "Validate GROWTH-FACTOR as an exact real greater than one."
      (if (not (and (number? growth-factor)
                    (real? growth-factor)
                    (exact? growth-factor)
                    (> growth-factor 1)))
          (error
           (string-append operation
                          ": expected exact growth factor greater than one")
           growth-factor))
      growth-factor)

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

    (define (check-growable-vector-boundary operation grow index)
      "Validate populated-prefix boundary INDEX in active GROW."
      (check-growable-vector operation grow)
      (if (not (and (exact-nonnegative-integer? index)
                    (<= index (growable-vector-length grow))))
          (error
           (string-append operation ": boundary outside populated prefix")
           index
           (growable-vector-length grow)))
      index)

    (define (check-growable-vector-slice operation grow start end)
      "Validate populated START through END in active GROW."
      (check-growable-vector operation grow)
      (if (not (and (exact-nonnegative-integer? start)
                    (exact-nonnegative-integer? end)
                    (<= start end (growable-vector-length grow))))
          (error
           (string-append operation ": invalid populated-prefix slice")
           start
           end
           (growable-vector-length grow)))
      grow)

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
      ;; Publish a zeroed sidecar before allocating storage.  Its presence is
      ;; not observable, and doing this first leaves all reported state exact
      ;; if the backing allocation fails.
      (growable-vector-statistics-for-write! grow)
      (let* ((length (growable-vector-length grow))
             (old (growable-vector-data grow))
             (larger (allocate-storage operation requested)))
        (if (> length 0)
            (vector-copy! larger 0 old 0 length))
        (set-growable-vector-data! grow larger)
        (growable-vector-note!
         grow growable-vector-growth-count-index 1)
        (growable-vector-note!
         grow growable-vector-copied-elements-index length)
        grow))

    (define (growable-vector-truncate-internal! operation grow requested)
      "Clear GROW's suffix down to REQUESTED and count one reset."
      (check-growable-vector operation grow)
      (if (not (and (exact-nonnegative-integer? requested)
                    (<= requested (growable-vector-length grow))))
          (error
           (string-append operation ": invalid reset length")
           requested
           (growable-vector-length grow)))
      (growable-vector-statistics-for-write! grow)
      (let ((data (growable-vector-data grow)))
        (if (vector? data)
            (vector-fill!
             data #f requested (growable-vector-length grow))))
      (set-growable-vector-length! grow requested)
      (growable-vector-note! grow growable-vector-reset-count-index 1)
      grow)

    (define (consent-make-growable-vector
             initial-capacity maximum-capacity . maybe-growth-factor)
      "Return empty growable storage within the supplied capacity bounds."
      #((parameters
         (initial-capacity (type exact-non-negative-integer)
          (description "Initial capacity; zero keeps backing lazy."))
         (maximum-capacity (type exact-non-negative-integer)
          (description "Largest permitted reserved capacity."))
         (maybe-growth-factor (type list)
          (description "Optional immutable exact growth factor.")))
        (returns (type growable-vector)
         (description "Fresh active private growable storage."))
        (effects allocation error))
      (check-capacity
       "consent-make-growable-vector initial" initial-capacity)
      (check-capacity
       "consent-make-growable-vector maximum" maximum-capacity)
      (if (> (length maybe-growth-factor) 1)
          (error
           "consent-make-growable-vector: too many growth factors"))
      (if (> initial-capacity maximum-capacity)
          (error
           "consent-make-growable-vector: initial capacity exceeds maximum"
           initial-capacity
           maximum-capacity))
      (let ((growth-factor
             (if (null? maybe-growth-factor)
                 2
                 (car maybe-growth-factor))))
        (check-growth-factor
         "consent-make-growable-vector" growth-factor)
        (make-growable-vector-record
         0
         (if (= initial-capacity 0)
             growable-vector-lazy-storage
             (allocate-storage
              "consent-make-growable-vector" initial-capacity))
         initial-capacity
         maximum-capacity
         growth-factor
         #f)))

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
      (growable-vector-capacity-value grow))

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

    (define (consent-growable-vector-growth-factor grow)
      "Return GROW's immutable geometric growth factor."
      #((parameters
         (grow (type growable-vector) (description "Storage to inspect.")))
        (returns (type exact-real)
         (description "Configured capacity growth factor."))
        (effects state-read error))
      (check-growable-vector
       "consent-growable-vector-growth-factor" grow)
      (growable-vector-growth-factor grow))

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
      (if (> requested (growable-vector-capacity-value grow))
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
      (let ((capacity (growable-vector-capacity-value grow))
            (maximum (growable-vector-maximum-capacity grow))
            (growth-factor (growable-vector-growth-factor grow)))
        (if (> minimum-capacity capacity)
            (let* ((geometric
                    (if (= capacity 0)
                        1
                        (max (+ capacity 1)
                             (if (>= growth-factor
                                     (/ maximum capacity))
                                 maximum
                                 (floor
                                  (* capacity growth-factor))))))
                   (candidate (max minimum-capacity geometric))
                   (bounded (min candidate maximum)))
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
      (growable-vector-statistics-for-write! grow)
      (let ((index (growable-vector-length grow)))
        (if (= index (growable-vector-capacity-value grow))
            (consent-growable-vector-grow! grow (+ index 1)))
        (vector-set! (growable-vector-data grow) index value)
        (set-growable-vector-length! grow (+ index 1))
        (growable-vector-note-high-water! grow (+ index 1))
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

    (define (consent-growable-vector-unsafe-ref grow index)
      "Return trusted GROW storage at already-validated INDEX."
      #((parameters
         (grow (type growable-vector)
          (description "Trusted active storage."))
         (index (type exact-non-negative-integer)
          (description "Already-validated populated index.")))
        (returns (type any) (description "Stored value."))
        (effects state-read))
      (vector-ref (growable-vector-data grow) index))

    (define (consent-growable-vector-unsafe-set! grow index value)
      "Replace trusted GROW storage at already-validated INDEX."
      #((parameters
         (grow (type growable-vector)
          (description "Trusted active storage."))
         (index (type exact-non-negative-integer)
          (description "Already-validated populated index."))
         (value (type any) (description "Replacement value.")))
        (returns (type any) (description "The supplied VALUE."))
        (effects state-write))
      (vector-set! (growable-vector-data grow) index value)
      value)

    (define (consent-growable-vector-copy!
             destination at source start end)
      "Copy SOURCE slice into DESTINATION, extending it without gaps."
      #((parameters
         (destination (type growable-vector)
          (description "Storage receiving copied elements."))
         (at (type exact-non-negative-integer)
          (description "Destination populated-prefix boundary."))
         (source (type growable-vector)
          (description "Storage supplying copied elements."))
         (start (type exact-non-negative-integer)
          (description "Inclusive source index."))
         (end (type exact-non-negative-integer)
          (description "Exclusive source index.")))
        (returns (type growable-vector)
         (description "The supplied DESTINATION."))
        (effects allocation state-read state-write error))
      (check-growable-vector-boundary
       "consent-growable-vector-copy!" destination at)
      (check-growable-vector-slice
       "consent-growable-vector-copy!" source start end)
      (let* ((old-length (growable-vector-length destination))
             (count (- end start))
             (required (+ at count)))
        (check-requested-capacity
         "consent-growable-vector-copy!" destination required)
        (if (> required old-length)
            (growable-vector-statistics-for-write! destination))
        (consent-growable-vector-grow! destination required)
        (if (> count 0)
            (vector-copy!
             (growable-vector-data destination)
             at
             (growable-vector-data source)
             start
             end))
        (if (> required old-length)
            (begin
              (set-growable-vector-length! destination required)
              (growable-vector-note-high-water! destination required)))
        destination))

    (define (consent-growable-vector-fill! grow fill start end)
      "Fill populated GROW elements from START through END."
      #((parameters
         (grow (type growable-vector) (description "Storage to mutate."))
         (fill (type any) (description "Value to store."))
         (start (type exact-non-negative-integer)
          (description "Inclusive populated index."))
         (end (type exact-non-negative-integer)
          (description "Exclusive populated index.")))
        (returns (type growable-vector)
         (description "The supplied GROW."))
        (effects state-write error))
      (check-growable-vector-slice
       "consent-growable-vector-fill!" grow start end)
      (if (< start end)
          (vector-fill! (growable-vector-data grow) fill start end))
      grow)

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
        (if (> length 0)
            (vector-copy!
             snapshot 0 (growable-vector-data grow) 0 length))
        snapshot))

    (define (consent-growable-vector-truncate! grow requested)
      "Clear GROW's populated suffix down to REQUESTED."
      #((parameters
         (grow (type growable-vector) (description "Storage to truncate."))
         (requested (type exact-non-negative-integer)
          (description "New populated-prefix length.")))
        (returns (type growable-vector)
         (description "The truncated active GROW."))
        (effects state-write error))
      (growable-vector-truncate-internal!
       "consent-growable-vector-truncate!" grow requested))

    (define (consent-growable-vector-clear! grow)
      "Clear GROW and restore its immutable initial capacity."
      #((parameters
         (grow (type growable-vector) (description "Storage to clear.")))
        (returns (type growable-vector)
         (description "The empty active GROW."))
        (effects allocation state-write error))
      (check-growable-vector "consent-growable-vector-clear!" grow)
      (growable-vector-statistics-for-write! grow)
      (let ((replacement
             (if (= (growable-vector-initial-capacity grow) 0)
                 growable-vector-lazy-storage
                 (allocate-storage
                  "consent-growable-vector-clear!"
                  (growable-vector-initial-capacity grow)))))
        ;; Allocate before mutation so failure preserves GROW exactly.
        (set-growable-vector-data! grow replacement)
        (set-growable-vector-length! grow 0)
        (growable-vector-note! grow growable-vector-reset-count-index 1)
        grow))

    (define (consent-growable-vector-reset! grow)
      "Clear GROW's populated prefix while retaining reserved storage."
      #((parameters
         (grow (type growable-vector) (description "Storage to reset.")))
        (returns (type growable-vector)
         (description "The empty active GROW."))
        (effects state-write error))
      (growable-vector-truncate-internal!
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
            (growable-vector-truncate-internal!
             "consent-growable-vector-release!" grow 0)
            (set-growable-vector-data! grow #f)))
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
        (or (not (vector? data))
            (let loop ((index (growable-vector-length grow)))
              (or (= index (vector-length data))
                  (and (eq? (vector-ref data index) #f)
                       (loop (+ index 1))))))))

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
       (list 'capacity
             (if (growable-vector-active? grow)
                 (growable-vector-capacity-value grow)
                 0))
       (list 'maximum-capacity
             (growable-vector-maximum-capacity grow))
       (list 'growth-factor (growable-vector-growth-factor grow))
       (list 'high-water
             (growable-vector-statistic
              grow growable-vector-high-water-index))
       (list 'growths
             (growable-vector-statistic
              grow growable-vector-growth-count-index))
       (list 'copied-elements
             (growable-vector-statistic
              grow growable-vector-copied-elements-index))
       (list 'resets
             (growable-vector-statistic
              grow growable-vector-reset-count-index))
       (list 'released (not (growable-vector-active? grow)))))
))
