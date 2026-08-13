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
          consent-growable-vector-append!
          consent-growable-vector-ref
          consent-growable-vector-set!
          consent-growable-vector-reserve!
          consent-growable-vector-grow!
          consent-growable-vector-snapshot
          consent-growable-vector-truncate!
          consent-growable-vector-reset!
          consent-growable-vector-release!
          consent-growable-vector-unused-slots-cleared?
          consent-growable-vector-stats)
  (import (scheme base))
  (begin
    ;; Shared empty backing store installed by terminal release.
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

    (define (growable-vector-truncate-internal! operation grow requested)
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
))
