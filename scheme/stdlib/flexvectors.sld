;;; SRFI 214 flexvector support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2020-2021 Adam Nelson
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the official SRFI 214 sample implementation at
;;; https://github.com/scheme-requests-for-implementation/srfi-214.
;;; The public record wraps Consent's private bounded growable storage so the
;;; primitive capacity, reset, release, and allocation-policy surface remains
;;; outside the SRFI contract.

(define-library (stdlib flexvectors)
  (export
   make-flexvector
   flexvector
   flexvector-unfold
   flexvector-unfold-right
   flexvector-copy
   flexvector-reverse-copy
   flexvector-append
   flexvector-concatenate
   flexvector-append-subvectors
   flexvector?
   flexvector-empty?
   flexvector=?
   flexvector-ref
   flexvector-front
   flexvector-back
   flexvector-length
   flexvector-add!
   flexvector-add-front!
   flexvector-add-back!
   flexvector-add-all!
   flexvector-append!
   flexvector-remove!
   flexvector-remove-front!
   flexvector-remove-back!
   flexvector-remove-range!
   flexvector-clear!
   flexvector-set!
   flexvector-swap!
   flexvector-fill!
   flexvector-reverse!
   flexvector-copy!
   flexvector-reverse-copy!
   flexvector-fold
   flexvector-fold-right
   flexvector-map
   flexvector-map/index
   flexvector-map!
   flexvector-map/index!
   flexvector-append-map
   flexvector-append-map/index
   flexvector-filter
   flexvector-filter/index
   flexvector-filter!
   flexvector-filter/index!
   flexvector-for-each
   flexvector-for-each/index
   flexvector-count
   flexvector-cumulate
   flexvector-index
   flexvector-index-right
   flexvector-skip
   flexvector-skip-right
   flexvector-binary-search
   flexvector-any
   flexvector-every
   flexvector-partition
   flexvector->vector
   vector->flexvector
   flexvector->list
   reverse-flexvector->list
   list->flexvector
   reverse-list->flexvector
   flexvector->string
   string->flexvector
   flexvector->generator
   generator->flexvector)
  (import (scheme base)
          (scheme case-lambda)
          (scheme cxr)
          (consent growable-vector))
  (begin
    ;; This is a logical ceiling only. The primitive allocates storage lazily.
    (define flexvector-maximum-capacity 9007199254740991)

    ;; Public flexvectors wrap private growable storage without exposing it.
    (define-record-type <flexvector>
      (make-flexvector-record storage)
      flexvector-record?
      (storage flexvector-storage))

    (define (flexvector? value)
      "Return whether VALUE is a flexvector."
      #((parameters
         (value (type any)
          (description "Candidate object to inspect.")))
        (returns (type boolean)
         (description "Whether VALUE is a flexvector.")))
      (flexvector-record? value))

    (define (unspecified)
      "Return an unspecified value portably."
      (if #f #f))

    (define (flexvector-exact-integer? value)
      "Return whether VALUE is an exact integer."
      (and (integer? value) (exact? value)))

    (define (check-flexvector operation value)
      "Validate VALUE as a flexvector for OPERATION."
      (if (not (flexvector? value))
          (error (string-append operation ": expected flexvector") value))
      value)

    (define (check-size operation size)
      "Validate SIZE as an exact nonnegative integer for OPERATION."
      (if (not (and (flexvector-exact-integer? size) (>= size 0)))
          (error
           (string-append operation
                          ": expected exact nonnegative integer")
           size))
      size)

    (define (check-index operation fv index allow-end?)
      "Validate INDEX against FV for OPERATION."
      (check-flexvector operation fv)
      (let ((length (flexvector-length fv)))
        (if (not (and (flexvector-exact-integer? index)
                      (>= index 0)
                      (if allow-end?
                          (<= index length)
                          (< index length))))
            (error
             (string-append operation ": index outside flexvector")
             index
             length)))
      index)

    (define (clamp-index operation index length)
      "Clamp exact integer INDEX into the inclusive LENGTH boundary."
      (if (not (flexvector-exact-integer? index))
          (error (string-append operation ": expected exact index") index))
      (max 0 (min index length)))

    (define (normalize-slice operation length start end)
      "Return clamped START and END for a sequence of LENGTH."
      (let ((actual-start (clamp-index operation start length))
            (actual-end (clamp-index operation end length)))
        (if (> actual-start actual-end)
            (error (string-append operation ": end precedes start")
                   start
                   end))
        (cons actual-start actual-end)))

    (define (new-flexvector-storage initial-capacity)
      "Return storage reserving INITIAL-CAPACITY with a four-slot clear floor."
      (let ((storage
             (consent-make-growable-vector
              4
              flexvector-maximum-capacity
              3/2)))
        (consent-growable-vector-reserve! storage initial-capacity)
        storage))

    (define (new-flexvector initial-capacity)
      "Return an empty flexvector with INITIAL-CAPACITY reserved slots."
      (make-flexvector-record
       (new-flexvector-storage initial-capacity)))

    (define (storage-length fv)
      "Return FV's private populated-prefix length."
      (consent-growable-vector-length (flexvector-storage fv)))

    (define (reserve-length! fv length)
      "Reserve enough storage for FV to reach LENGTH."
      (consent-growable-vector-grow! (flexvector-storage fv) length)
      fv)

    (define (append-one! fv value)
      "Append VALUE to FV and return FV."
      (consent-growable-vector-append! (flexvector-storage fv) value)
      fv)

    (define (shortest-length operation fvs)
      "Return the shortest length in nonempty FV list FVS."
      (if (null? fvs)
          (error (string-append operation ": expected flexvector")))
      (let loop ((rest fvs) (result #f))
        (if (null? rest)
            result
            (begin
              (check-flexvector operation (car rest))
              (let ((length (flexvector-length (car rest))))
                (loop (cdr rest)
                      (if result (min result length) length)))))))

    (define (parallel-values fvs index)
      "Return values at INDEX from FVS in order."
      (map (lambda (fv) (flexvector-ref fv index)) fvs))

    (define (make-flexvector size . maybe-fill)
      "Return a new flexvector of SIZE, optionally filled from MAYBE-FILL."
      #((parameters
         (size (type exact-integer)
          (description "Requested logical length."))
         (maybe-fill (type list)
          (description "Zero or one initial element value.")))
        (returns (type flexvector)
         (description "A fresh flexvector of SIZE elements.")))
      (check-size "make-flexvector" size)
      (if (> (length maybe-fill) 1)
          (error "make-flexvector: too many fill values"))
      (let ((fv (new-flexvector (max 4 size)))
            (fill (if (null? maybe-fill) #f (car maybe-fill))))
        (let loop ((index 0))
          (if (< index size)
              (begin
                (append-one! fv fill)
                (loop (+ index 1)))))
        fv))

    (define (flexvector . values)
      "Return a flexvector containing VALUES."
      #((parameters
         (values (type list)
          (description "Elements for the new flexvector.")))
        (returns (type flexvector)
         (description "A fresh flexvector containing VALUES.")))
      (list->flexvector values))

    (define (flexvector-length fv)
      "Return the number of elements in FV."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to inspect.")))
        (returns (type exact-integer)
         (description "Number of populated elements in FV.")))
      (check-flexvector "flexvector-length" fv)
      (storage-length fv))

    (define (flexvector-empty? fv)
      "Return whether FV contains no elements."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to inspect.")))
        (returns (type boolean)
         (description "Whether FV has zero elements.")))
      (= (flexvector-length fv) 0))

    (define (flexvector-ref fv index)
      "Return FV's element at INDEX."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to inspect."))
         (index (type exact-integer)
          (description "Zero-based element position.")))
        (returns (type object)
         (description "Element stored at INDEX.")))
      (check-index "flexvector-ref" fv index #f)
      (consent-growable-vector-ref (flexvector-storage fv) index))

    (define (flexvector-set! fv index value)
      "Set FV at INDEX, appending at its length; return old or unspecified."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (index (type exact-integer)
          (description "Existing position or FV's current length."))
         (value (type object)
          (description "Replacement or appended element.")))
        (returns (type object)
         (description "Previous element, or unspecified when appending.")))
      (check-index "flexvector-set!" fv index #t)
      (if (= index (flexvector-length fv))
          (begin
            (append-one! fv value)
            (unspecified))
          (let ((previous (flexvector-ref fv index)))
            (consent-growable-vector-set!
             (flexvector-storage fv) index value)
            previous)))

    (define (flexvector-front fv)
      "Return FV's first element."
      #((parameters
         (fv (type flexvector)
          (description "Nonempty flexvector to inspect.")))
        (returns (type object)
         (description "First element of FV.")))
      (flexvector-ref fv 0))

    (define (flexvector-back fv)
      "Return FV's last element."
      #((parameters
         (fv (type flexvector)
          (description "Nonempty flexvector to inspect.")))
        (returns (type object)
         (description "Last element of FV.")))
      (flexvector-ref fv (- (flexvector-length fv) 1)))

    (define (flexvector-add-all! fv index values)
      "Insert list VALUES into FV at INDEX and return FV."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (index (type exact-integer)
          (description "Position before which VALUES are inserted."))
         (values (type list)
          (description "Proper list of elements to insert.")))
        (returns (type flexvector)
         (description "The mutated FV.")))
      (check-index "flexvector-add-all!" fv index #t)
      (if (not (list? values))
          (error "flexvector-add-all!: expected proper list" values))
      (let* ((size (flexvector-length fv))
             (count (length values))
             (new-length (+ size count)))
        (if (> count 0)
            (if (= index size)
                (begin
                  (reserve-length! fv new-length)
                  (for-each (lambda (value) (append-one! fv value))
                            values))
                (begin
                  (reserve-length! fv new-length)
                  (let extend ((rest values))
                    (if (pair? rest)
                        (begin
                          (append-one! fv #f)
                          (extend (cdr rest)))))
                  (consent-growable-vector-copy!
                   (flexvector-storage fv)
                   (+ index count)
                   (flexvector-storage fv)
                   index
                   size)
                  (let insert ((target index) (rest values))
                    (if (pair? rest)
                        (begin
                          (consent-growable-vector-set!
                           (flexvector-storage fv) target (car rest))
                          (insert (+ target 1) (cdr rest))))))))
        fv))

    (define (insert-one! operation fv index value)
      "Insert VALUE into FV at INDEX without constructing a value list."
      (check-index operation fv index #t)
      (let ((size (flexvector-length fv)))
        (if (= index size)
            (append-one! fv value)
            (begin
              (append-one! fv #f)
              (consent-growable-vector-copy!
               (flexvector-storage fv)
               (+ index 1)
               (flexvector-storage fv)
               index
               size)
              (consent-growable-vector-set!
               (flexvector-storage fv) index value))))
      fv)

    (define (flexvector-add! fv index . values)
      "Insert VALUES at INDEX, specializing the one-value body path."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (index (type exact-integer)
          (description "Position before which VALUES are inserted."))
         (values (type list)
          (description "Zero or more elements to insert.")))
        (returns (type flexvector)
         (description "The mutated FV.")))
      (cond
       ((null? values)
        (check-index "flexvector-add!" fv index #t)
        fv)
       ((null? (cdr values))
        (insert-one! "flexvector-add!" fv index (car values)))
       (else
        (flexvector-add-all! fv index values))))

    (define (flexvector-add-front! fv . values)
      "Insert VALUES at the front, specializing the one-value body path."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (values (type list)
          (description "Zero or more elements to prepend.")))
        (returns (type flexvector)
         (description "The mutated FV.")))
      (cond
       ((null? values)
        (check-flexvector "flexvector-add-front!" fv)
        fv)
       ((null? (cdr values))
        (insert-one!
         "flexvector-add-front!" fv 0 (car values)))
       (else
        (flexvector-add-all! fv 0 values))))

    (define (flexvector-add-back! fv . values)
      "Append VALUES, specializing the one-value body path."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (values (type list)
          (description "Zero or more elements to append.")))
        (returns (type flexvector)
         (description "The mutated FV.")))
      (check-flexvector "flexvector-add-back!" fv)
      (cond
       ((null? values)
        fv)
       ((null? (cdr values))
        (append-one! fv (car values)))
       (else
        (reserve-length!
         fv (+ (flexvector-length fv) (length values)))
        (for-each (lambda (value) (append-one! fv value)) values)
        fv)))

    (define (flexvector-remove-range! fv start . maybe-end)
      "Remove FV's clamped slice; END defaults to its length."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (start (type exact-integer)
          (description "Clamped inclusive slice start."))
         (maybe-end (type list)
          (description "Zero or one clamped exclusive slice end.")))
        (returns (type flexvector)
         (description "FV after removing the selected slice.")))
      (check-flexvector "flexvector-remove-range!" fv)
      (if (> (length maybe-end) 1)
          (error "flexvector-remove-range!: too many end arguments"))
      (let* ((size (flexvector-length fv))
             (end (if (null? maybe-end) size (car maybe-end)))
             (slice
              (normalize-slice
               "flexvector-remove-range!" size start end))
             (actual-start (car slice))
             (actual-end (cdr slice))
             (count (- actual-end actual-start)))
        (if (> count 0)
            (consent-growable-vector-copy!
             (flexvector-storage fv)
             actual-start
             (flexvector-storage fv)
             actual-end
             size))
        (consent-growable-vector-truncate!
         (flexvector-storage fv) (- size count))
        fv))

    (define (flexvector-remove! fv index)
      "Remove and return FV's element at INDEX."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (index (type exact-integer)
          (description "Zero-based position to remove.")))
        (returns (type object)
         (description "Element removed from INDEX.")))
      (check-index "flexvector-remove!" fv index #f)
      (let ((value (flexvector-ref fv index)))
        (flexvector-remove-range! fv index (+ index 1))
        value))

    (define (flexvector-remove-front! fv)
      "Remove and return FV's first element."
      #((parameters
         (fv (type flexvector)
          (description "Nonempty flexvector to mutate.")))
        (returns (type object)
         (description "Element removed from the front.")))
      (flexvector-remove! fv 0))

    (define (flexvector-remove-back! fv)
      "Remove and return FV's last element."
      #((parameters
         (fv (type flexvector)
          (description "Nonempty flexvector to mutate.")))
        (returns (type object)
         (description "Element removed from the back.")))
      (flexvector-remove! fv (- (flexvector-length fv) 1)))

    (define (flexvector-clear! fv)
      "Remove every element and release FV's high-water storage."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to clear.")))
        (returns (type flexvector)
         (description "The empty FV with baseline capacity.")))
      (check-flexvector "flexvector-clear!" fv)
      (consent-growable-vector-clear! (flexvector-storage fv))
      fv)

    (define (flexvector-copy! to at from . maybe-bounds)
      "Copy a FROM slice into TO at AT, extending TO when required."
      #((parameters
         (to (type flexvector)
          (description "Destination flexvector to mutate."))
         (at (type exact-integer)
          (description "Destination start position."))
         (from (type flexvector)
          (description "Source flexvector to copy."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type flexvector)
         (description "The mutated destination TO.")))
      (check-index "flexvector-copy!" to at #t)
      (check-flexvector "flexvector-copy!" from)
      (let* ((from-length (flexvector-length from))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  from-length
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector-copy!: too many bounds"))
        (let* ((slice
                (normalize-slice "flexvector-copy!" from-length start end))
               (actual-start (car slice))
               (actual-end (cdr slice)))
          (consent-growable-vector-copy!
           (flexvector-storage to)
           at
           (flexvector-storage from)
           actual-start
           actual-end)
          to)))

    (define (flexvector-reverse-copy! to at from . maybe-bounds)
      "Reverse-copy a FROM slice into TO at AT and return TO."
      #((parameters
         (to (type flexvector)
          (description "Destination flexvector to mutate."))
         (at (type exact-integer)
          (description "Destination start position."))
         (from (type flexvector)
          (description "Source flexvector to reverse-copy."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type flexvector)
         (description "The mutated destination TO.")))
      (check-index "flexvector-reverse-copy!" to at #t)
      (check-flexvector "flexvector-reverse-copy!" from)
      (let* ((from-length (flexvector-length from))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  from-length
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector-reverse-copy!: too many bounds"))
        (let* ((slice
                (normalize-slice
                 "flexvector-reverse-copy!" from-length start end))
               (actual-start (car slice))
               (actual-end (cdr slice))
               (count (- actual-end actual-start)))
          (consent-growable-vector-copy!
           (flexvector-storage to)
           at
           (flexvector-storage from)
           actual-start
           actual-end)
          (flexvector-reverse! to at (+ at count))
          to)))

    (define (flexvector-append! fv . fvs)
      "Append FVS to FV and return FV."
      #((parameters
         (fv (type flexvector)
          (description "Destination flexvector to mutate."))
         (fvs (type list)
          (description "Zero or more source flexvectors.")))
        (returns (type flexvector)
         (description "The mutated destination FV.")))
      (check-flexvector "flexvector-append!" fv)
      (for-each
       (lambda (other)
         (flexvector-copy! fv (flexvector-length fv) other))
       fvs)
      fv)

    (define (flexvector-swap! fv left right)
      "Swap FV elements at LEFT and RIGHT and return FV."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (left (type exact-integer)
          (description "First zero-based element position."))
         (right (type exact-integer)
          (description "Second zero-based element position.")))
        (returns (type flexvector)
         (description "FV after exchanging the two elements.")))
      (check-index "flexvector-swap!" fv left #f)
      (check-index "flexvector-swap!" fv right #f)
      (let ((value (flexvector-ref fv left)))
        (flexvector-set! fv left (flexvector-ref fv right))
        (flexvector-set! fv right value)
        fv))

    (define (flexvector-fill! fv fill . maybe-bounds)
      "Fill a clamped FV slice with FILL and return FV."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (fill (type object)
          (description "Value stored throughout the selected slice."))
         (maybe-bounds (type list)
          (description "Optional clamped slice start and end.")))
        (returns (type flexvector)
         (description "The filled FV.")))
      (check-flexvector "flexvector-fill!" fv)
      (let* ((size (flexvector-length fv))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  size
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector-fill!: too many bounds"))
        (let ((slice
               (normalize-slice "flexvector-fill!" size start end)))
          (consent-growable-vector-fill!
           (flexvector-storage fv) fill (car slice) (cdr slice))))
      fv)

    (define (flexvector-reverse! fv . maybe-bounds)
      "Reverse a clamped FV slice in place and return FV."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector to mutate."))
         (maybe-bounds (type list)
          (description "Optional clamped slice start and end.")))
        (returns (type flexvector)
         (description "FV with the selected slice reversed.")))
      (check-flexvector "flexvector-reverse!" fv)
      (let* ((size (flexvector-length fv))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  size
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector-reverse!: too many bounds"))
        (let* ((slice
                (normalize-slice "flexvector-reverse!" size start end))
               (actual-end (cdr slice)))
          (let loop ((left (car slice)) (right (- actual-end 1)))
            (if (< left right)
                (begin
                  (flexvector-swap! fv left right)
                  (loop (+ left 1) (- right 1)))))))
      fv)

    (define (flexvector->vector fv . maybe-bounds)
      "Return a fixed vector copied from a clamped FV slice."
      #((parameters
         (fv (type flexvector)
          (description "Source flexvector."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type vector)
         (description "Fresh vector containing the selected elements.")))
      (check-flexvector "flexvector->vector" fv)
      (let* ((size (flexvector-length fv))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  size
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector->vector: too many bounds"))
        (let* ((slice
                (normalize-slice "flexvector->vector" size start end))
               (actual-start (car slice))
               (actual-end (cdr slice))
               (result (make-vector (- actual-end actual-start))))
          (let copy ((source actual-start) (target 0))
            (if (< source actual-end)
                (begin
                  (vector-set! result target (flexvector-ref fv source))
                  (copy (+ source 1) (+ target 1)))))
          result)))

    (define (vector->flexvector vector . maybe-bounds)
      "Return a flexvector copied from a clamped VECTOR slice."
      #((parameters
         (vector (type vector)
          (description "Source vector."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type flexvector)
         (description "Fresh flexvector containing the selected elements.")))
      (if (not (vector? vector))
          (error "vector->flexvector: expected vector" vector))
      (let* ((size (vector-length vector))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  size
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "vector->flexvector: too many bounds"))
        (let* ((slice
                (normalize-slice "vector->flexvector" size start end))
               (actual-start (car slice))
               (actual-end (cdr slice))
               (result
                (new-flexvector
                 (max 4 (- actual-end actual-start)))))
          (let copy ((index actual-start))
            (if (< index actual-end)
                (begin
                  (append-one! result (vector-ref vector index))
                  (copy (+ index 1)))))
          result)))

    (define (list->flexvector values)
      "Return a flexvector containing proper list VALUES."
      #((parameters
         (values (type list)
          (description "Proper list of source elements.")))
        (returns (type flexvector)
         (description "Fresh flexvector containing VALUES.")))
      (if (not (list? values))
          (error "list->flexvector: expected proper list" values))
      (let ((result (new-flexvector (max 4 (length values)))))
        (for-each (lambda (value) (append-one! result value)) values)
        result))

    (define (reverse-list->flexvector values)
      "Return a flexvector containing VALUES in reverse order."
      #((parameters
         (values (type list)
          (description "Proper list of source elements.")))
        (returns (type flexvector)
         (description "Fresh flexvector containing reversed VALUES.")))
      (list->flexvector (reverse values)))

    (define (flexvector->list fv . maybe-bounds)
      "Return a list copied from a clamped FV slice."
      #((parameters
         (fv (type flexvector)
          (description "Source flexvector."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type list)
         (description "Fresh list containing the selected elements.")))
      (vector->list (apply flexvector->vector fv maybe-bounds)))

    (define (reverse-flexvector->list fv . maybe-bounds)
      "Return a reverse-order list copied from a clamped FV slice."
      #((parameters
         (fv (type flexvector)
          (description "Source flexvector."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type list)
         (description "Fresh list containing the elements in reverse.")))
      (reverse (apply flexvector->list fv maybe-bounds)))

    (define (string->flexvector string . maybe-bounds)
      "Return a flexvector copied from a clamped STRING slice."
      #((parameters
         (string (type string)
          (description "Source string."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type flexvector)
         (description "Fresh flexvector containing selected characters.")))
      (if (not (string? string))
          (error "string->flexvector: expected string" string))
      (apply vector->flexvector (string->vector string) maybe-bounds))

    (define (flexvector->string fv . maybe-bounds)
      "Return a string copied from a clamped FV slice."
      #((parameters
         (fv (type flexvector)
          (description "Source flexvector of characters."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type string)
         (description "Fresh string containing the selected characters.")))
      (vector->string (apply flexvector->vector fv maybe-bounds)))

    (define (flexvector-copy fv . maybe-bounds)
      "Return a flexvector copied from a clamped FV slice."
      #((parameters
         (fv (type flexvector)
          (description "Source flexvector."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type flexvector)
         (description "Fresh flexvector containing the selected elements.")))
      (check-flexvector "flexvector-copy" fv)
      (let* ((size (flexvector-length fv))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  size
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector-copy: too many bounds"))
        (let* ((slice
                (normalize-slice "flexvector-copy" size start end))
               (actual-start (car slice))
               (actual-end (cdr slice))
               (result
                (new-flexvector
                 (max 4 (- actual-end actual-start)))))
          (consent-growable-vector-copy!
           (flexvector-storage result)
           0
           (flexvector-storage fv)
           actual-start
           actual-end)
          result)))

    (define (flexvector-reverse-copy fv . maybe-bounds)
      "Return a reversed copy of a clamped FV slice."
      #((parameters
         (fv (type flexvector)
          (description "Source flexvector."))
         (maybe-bounds (type list)
          (description "Optional clamped source start and end.")))
        (returns (type flexvector)
         (description "Fresh reversed copy of the selected elements.")))
      (let ((result (apply flexvector-copy fv maybe-bounds)))
        (flexvector-reverse! result)
        result))

    (define (flexvector-append . fvs)
      "Return a new flexvector containing every element of FVS."
      #((parameters
         (fvs (type list)
          (description "Zero or more source flexvectors.")))
        (returns (type flexvector)
         (description "Fresh concatenation of FVS.")))
      (let ((result (flexvector)))
        (apply flexvector-append! result fvs)))

    (define (flexvector-concatenate fvs)
      "Return the concatenation of proper flexvector list FVS."
      #((parameters
         (fvs (type list)
          (description "Proper list of source flexvectors.")))
        (returns (type flexvector)
         (description "Fresh concatenation of FVS.")))
      (if (not (list? fvs))
          (error "flexvector-concatenate: expected proper list" fvs))
      (apply flexvector-append fvs))

    (define (flexvector-append-subvectors . specifications)
      "Append FV START END groups from SPECIFICATIONS into a new flexvector."
      #((parameters
         (specifications (type list)
          (description "Repeated flexvector, start, and end triples.")))
        (returns (type flexvector)
         (description "Fresh concatenation of the specified slices.")))
      (let ((result (flexvector)))
        (let loop ((rest specifications))
          (cond
           ((null? rest) result)
           ((or (null? (cdr rest))
                (null? (cddr rest)))
            (error
             "flexvector-append-subvectors: incomplete slice" rest))
           (else
            (flexvector-copy!
             result
             (flexvector-length result)
             (car rest)
             (cadr rest)
             (caddr rest))
            (loop (cdddr rest)))))))

    (define (flexvector-unfold predicate mapper successor . seeds)
      "Unfold SEEDS left-to-right into a new flexvector."
      #((parameters
         (predicate (type procedure)
          (description "Procedure deciding when unfolding stops."))
         (mapper (type procedure)
          (description "Procedure mapping current seeds to an element."))
         (successor (type procedure)
          (description "Procedure producing the next seed values."))
         (seeds (type list)
          (description "Initial values passed to each procedure.")))
        (returns (type flexvector)
         (description "Fresh flexvector of mapped values.")))
      (let ((result (flexvector)))
        (let loop ((current seeds))
          (if (apply predicate current)
              result
              (begin
                (flexvector-add-back!
                 result (apply mapper current))
                (call-with-values
                 (lambda () (apply successor current))
                 (lambda next
                   (loop next))))))))

    (define (flexvector-unfold-right predicate mapper successor . seeds)
      "Unfold SEEDS into a new flexvector in reverse order."
      #((parameters
         (predicate (type procedure)
          (description "Procedure deciding when unfolding stops."))
         (mapper (type procedure)
          (description "Procedure mapping current seeds to an element."))
         (successor (type procedure)
          (description "Procedure producing the next seed values."))
         (seeds (type list)
          (description "Initial values passed to each procedure.")))
        (returns (type flexvector)
         (description "Fresh reverse-order flexvector of mapped values.")))
      (let ((result
             (apply flexvector-unfold
                    predicate mapper successor seeds)))
        (flexvector-reverse! result)
        result))

    (define (flexvector=? element=? . fvs)
      "Return whether FVS have equal lengths and pairwise equal elements."
      #((parameters
         (element=? (type procedure)
          (description "Binary predicate comparing parallel elements."))
         (fvs (type list)
          (description "Flexvectors to compare in order.")))
        (returns (type boolean)
         (description "Whether every adjacent pair is element-wise equal.")))
      (let compare ((rest fvs))
        (or (null? rest)
            (null? (cdr rest))
            (let ((left (car rest)) (right (cadr rest)))
              (check-flexvector "flexvector=?" left)
              (check-flexvector "flexvector=?" right)
              (and (= (flexvector-length left)
                      (flexvector-length right))
                   (let loop ((index 0))
                     (or (= index (flexvector-length left))
                         (and
                          (element=?
                           (flexvector-ref left index)
                           (flexvector-ref right index))
                          (loop (+ index 1)))))
                   (compare (cdr rest)))))))

    (define (flexvector-for-each/index proc . fvs)
      "Call PROC left-to-right with each index and parallel FVS elements."
      #((parameters
         (proc (type procedure)
          (description "Procedure called with an index and elements."))
         (fvs (type list)
          (description "Nonempty list of flexvectors to traverse.")))
        (returns (type unspecified)
         (description "An unspecified value.")))
      (let ((length
             (shortest-length "flexvector-for-each/index" fvs)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (apply proc index (parallel-values fvs index))
                (loop (+ index 1))))))
      (unspecified))

    (define (flexvector-for-each proc . fvs)
      "Call PROC left-to-right with parallel elements from FVS."
      #((parameters
         (proc (type procedure)
          (description "Procedure called with parallel elements."))
         (fvs (type list)
          (description "Nonempty list of flexvectors to traverse.")))
        (returns (type unspecified)
         (description "An unspecified value.")))
      (apply
       flexvector-for-each/index
       (lambda (index . values)
         index
         (apply proc values))
       fvs))

    (define (flexvector-fold kons knil fv . fvs)
      "Fold KONS left-to-right over FV and FVS starting from KNIL."
      #((parameters
         (kons (type procedure)
          (description "Procedure combining state with parallel elements."))
         (knil (type object)
          (description "Initial fold state."))
         (fv (type flexvector)
          (description "First flexvector to traverse."))
         (fvs (type list)
          (description "Additional flexvectors traversed in parallel.")))
        (returns (type object)
         (description "Final fold state.")))
      (let* ((all (cons fv fvs))
             (length (shortest-length "flexvector-fold" all)))
        (let loop ((index 0) (result knil))
          (if (= index length)
              result
              (loop
               (+ index 1)
               (apply kons result (parallel-values all index)))))))

    (define (flexvector-fold-right kons knil fv . fvs)
      "Fold KONS right-to-left over FV and FVS starting from KNIL."
      #((parameters
         (kons (type procedure)
          (description "Procedure combining state with parallel elements."))
         (knil (type object)
          (description "Initial fold state."))
         (fv (type flexvector)
          (description "First flexvector to traverse."))
         (fvs (type list)
          (description "Additional flexvectors traversed in parallel.")))
        (returns (type object)
         (description "Final fold state.")))
      (let* ((all (cons fv fvs))
             (length (shortest-length "flexvector-fold-right" all)))
        (let loop ((index (- length 1)) (result knil))
          (if (< index 0)
              result
              (loop
               (- index 1)
               (apply kons result (parallel-values all index)))))))

    (define (flexvector-map/index proc fv . fvs)
      "Return PROC mapped over indexes and parallel FV/FVS elements."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping an index and parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type flexvector)
         (description "Fresh flexvector of mapped values.")))
      (let ((result (flexvector)))
        (apply
         flexvector-for-each/index
         (lambda (index . values)
           (flexvector-add-back!
            result (apply proc index values)))
         (cons fv fvs))
        result))

    (define (flexvector-map proc fv . fvs)
      "Return PROC mapped over parallel FV/FVS elements."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type flexvector)
         (description "Fresh flexvector of mapped values.")))
      (apply
       flexvector-map/index
       (lambda (index . values)
         index
         (apply proc values))
       fv
       fvs))

    (define (flexvector-map/index! proc fv . fvs)
      "Replace FV with PROC mapped over indexes and parallel elements."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping an index and parallel elements."))
         (fv (type flexvector)
          (description "Destination and first source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type flexvector)
         (description "The mutated destination FV.")))
      (let* ((all (cons fv fvs))
             (length (shortest-length "flexvector-map/index!" all)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (flexvector-set!
                 fv index
                 (apply proc index (parallel-values all index)))
                (loop (+ index 1)))))
        fv))

    (define (flexvector-map! proc fv . fvs)
      "Replace FV with PROC mapped over parallel elements."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping parallel elements."))
         (fv (type flexvector)
          (description "Destination and first source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type flexvector)
         (description "The mutated destination FV.")))
      (apply
       flexvector-map/index!
       (lambda (index . values)
         index
         (apply proc values))
       fv
       fvs))

    (define (flexvector-append-map/index proc fv . fvs)
      "Append flexvectors returned by indexed PROC over FV/FVS."
      #((parameters
         (proc (type procedure)
          (description "Maps indexes and elements to flexvectors."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type flexvector)
         (description "Fresh concatenation of mapped flexvectors.")))
      (let ((result (flexvector)))
        (apply
         flexvector-for-each/index
         (lambda (index . values)
           (let ((mapped (apply proc index values)))
             (check-flexvector "flexvector-append-map/index" mapped)
             (flexvector-append! result mapped)))
         (cons fv fvs))
        result))

    (define (flexvector-append-map proc fv . fvs)
      "Append flexvectors returned by PROC over FV/FVS."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping parallel elements to flexvectors."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type flexvector)
         (description "Fresh concatenation of mapped flexvectors.")))
      (apply
       flexvector-append-map/index
       (lambda (index . values)
         index
         (apply proc values))
       fv
       fvs))

    (define (flexvector-filter/index predicate fv)
      "Return FV elements accepted by indexed PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with each index and element."))
         (fv (type flexvector)
          (description "Source flexvector.")))
        (returns (type flexvector)
         (description "Fresh flexvector of accepted elements.")))
      (let ((result (flexvector)))
        (flexvector-for-each/index
         (lambda (index value)
           (if (predicate index value)
               (flexvector-add-back! result value)))
         fv)
        result))

    (define (flexvector-filter predicate fv)
      "Return FV elements accepted by PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with each element."))
         (fv (type flexvector)
          (description "Source flexvector.")))
        (returns (type flexvector)
         (description "Fresh flexvector of accepted elements.")))
      (flexvector-filter/index
       (lambda (index value)
         index
         (predicate value))
       fv))

    (define (flexvector-filter/index! predicate fv)
      "Retain indexed FV elements accepted by PREDICATE and return FV."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with each index and element."))
         (fv (type flexvector)
          (description "Flexvector to filter in place.")))
        (returns (type flexvector)
         (description "FV containing only accepted elements.")))
      (let ((length (flexvector-length fv)))
        (let loop ((source 0) (target 0))
          (if (= source length)
              (begin
                (consent-growable-vector-truncate!
                 (flexvector-storage fv) target)
                fv)
              (let ((value (flexvector-ref fv source)))
                (if (predicate source value)
                    (begin
                      (if (not (= source target))
                          (consent-growable-vector-set!
                           (flexvector-storage fv) target value))
                      (loop (+ source 1) (+ target 1)))
                    (loop (+ source 1) target)))))))

    (define (flexvector-filter! predicate fv)
      "Retain FV elements accepted by PREDICATE and return FV."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with each element."))
         (fv (type flexvector)
          (description "Flexvector to filter in place.")))
        (returns (type flexvector)
         (description "FV containing only accepted elements.")))
      (flexvector-filter/index!
       (lambda (index value)
         index
         (predicate value))
       fv))

    (define (flexvector-count predicate fv . fvs)
      "Count parallel FV/FVS elements accepted by PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type exact-integer)
         (description "Number of positions accepted by PREDICATE.")))
      (apply
       flexvector-fold
       (lambda (count . values)
         (+ count (if (apply predicate values) 1 0)))
       0
       fv
       fvs))

    (define (flexvector-cumulate proc knil fv)
      "Return successive PROC accumulations over FV starting from KNIL."
      #((parameters
         (proc (type procedure)
          (description "Procedure combining state with each element."))
         (knil (type object)
          (description "Initial accumulation state."))
         (fv (type flexvector)
          (description "Source flexvector.")))
        (returns (type flexvector)
         (description "Fresh flexvector of successive states.")))
      (let ((result (flexvector)))
        (flexvector-fold
         (lambda (state value)
           (let ((next (proc state value)))
             (flexvector-add-back! result next)
             next))
         knil
         fv)
        result))

    (define (flexvector-index predicate fv . fvs)
      "Return the first index whose parallel FV/FVS values satisfy PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type (or exact-integer boolean))
         (description "First matching index, or #f.")))
      (let* ((all (cons fv fvs))
             (length (shortest-length "flexvector-index" all)))
        (let loop ((index 0))
          (and (< index length)
               (if (apply predicate (parallel-values all index))
                   index
                   (loop (+ index 1)))))))

    (define (flexvector-index-right predicate fv . fvs)
      "Return the last index whose parallel FV/FVS values satisfy PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional equal-length source flexvectors.")))
        (returns (type (or exact-integer boolean))
         (description "Last matching index, or #f.")))
      (let* ((all (cons fv fvs))
             (length (flexvector-length fv)))
        (for-each
         (lambda (other)
           (check-flexvector "flexvector-index-right" other)
           (if (not (= length (flexvector-length other)))
               (error
                "flexvector-index-right: unequal flexvector lengths")))
         fvs)
        (let loop ((index (- length 1)))
          (and (>= index 0)
               (if (apply predicate (parallel-values all index))
                   index
                   (loop (- index 1)))))))

    (define (flexvector-skip predicate fv . fvs)
      "Return the first index whose parallel values fail PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type (or exact-integer boolean))
         (description "First failing index, or #f.")))
      (apply
       flexvector-index
       (lambda values (not (apply predicate values)))
       fv
       fvs))

    (define (flexvector-skip-right predicate fv . fvs)
      "Return the last index whose parallel values fail PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Predicate called with parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional equal-length source flexvectors.")))
        (returns (type (or exact-integer boolean))
         (description "Last failing index, or #f.")))
      (apply
       flexvector-index-right
       (lambda values (not (apply predicate values)))
       fv
       fvs))

    (define (flexvector-binary-search fv value compare . maybe-bounds)
      "Return VALUE's index in sorted FV according to COMPARE, or false."
      #((parameters
         (fv (type flexvector)
          (description "Sorted flexvector to search."))
         (value (type object)
          (description "Target value."))
         (compare (type procedure)
          (description "Three-way comparator for VALUE and an element."))
         (maybe-bounds (type list)
          (description "Optional clamped search start and end.")))
        (returns (type (or exact-integer boolean))
         (description "A matching index, or #f.")))
      (check-flexvector "flexvector-binary-search" fv)
      (let* ((size (flexvector-length fv))
             (start (if (null? maybe-bounds) 0 (car maybe-bounds)))
             (end
              (if (or (null? maybe-bounds)
                      (null? (cdr maybe-bounds)))
                  size
                  (cadr maybe-bounds))))
        (if (> (length maybe-bounds) 2)
            (error "flexvector-binary-search: too many bounds"))
        (let* ((slice
                (normalize-slice
                 "flexvector-binary-search" size start end))
               (initial-left (car slice))
               (initial-right (- (cdr slice) 1)))
          (let loop ((left initial-left) (right initial-right))
            (and (<= left right)
                 (let* ((middle (quotient (+ left right) 2))
                        (order
                         (compare value (flexvector-ref fv middle))))
                   (cond
                    ((< order 0) (loop left (- middle 1)))
                    ((> order 0) (loop (+ middle 1) right))
                    (else middle))))))))

    (define (flexvector-any predicate fv . fvs)
      "Return the first true PREDICATE result over parallel FV/FVS values."
      #((parameters
         (predicate (type procedure)
          (description "Procedure applied to parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type object)
         (description "First true result, or #f.")))
      (let* ((all (cons fv fvs))
             (length (shortest-length "flexvector-any" all)))
        (let loop ((index 0))
          (and (< index length)
               (let ((result
                      (apply predicate (parallel-values all index))))
                 (if result result (loop (+ index 1))))))))

    (define (flexvector-every predicate fv . fvs)
      "Return the last PREDICATE result if every parallel value is true."
      #((parameters
         (predicate (type procedure)
          (description "Procedure applied to parallel elements."))
         (fv (type flexvector)
          (description "First source flexvector."))
         (fvs (type list)
          (description "Additional source flexvectors.")))
        (returns (type object)
         (description "Last true result, #t for empty input, or #f.")))
      (let* ((all (cons fv fvs))
             (length (shortest-length "flexvector-every" all)))
        (if (= length 0)
            #t
            (let loop ((index 0))
              (let ((result
                     (apply predicate (parallel-values all index))))
                (if (= index (- length 1))
                    result
                    (and result (loop (+ index 1)))))))))

    (define (flexvector-partition predicate fv)
      "Return accepted and rejected FV elements as two flexvectors."
      #((parameters
         (predicate (type procedure)
          (description "Predicate classifying each element."))
         (fv (type flexvector)
          (description "Source flexvector.")))
        (returns (type (values flexvector flexvector))
         (description "Fresh accepted and rejected flexvectors.")))
      (let ((accepted (flexvector)) (rejected (flexvector)))
        (flexvector-for-each
         (lambda (value)
           (flexvector-add-back!
            (if (predicate value) accepted rejected) value))
         fv)
        (values accepted rejected)))

    (define (flexvector->generator fv)
      "Return a generator that traverses FV in index order."
      #((parameters
         (fv (type flexvector)
          (description "Flexvector traversed by the generator.")))
        (returns (type procedure)
         (description "Stateful generator yielding FV's elements.")))
      (check-flexvector "flexvector->generator" fv)
      (let ((index 0))
        (lambda ()
          (if (< index (flexvector-length fv))
              (let ((value (flexvector-ref fv index)))
                (set! index (+ index 1))
                value)
              (eof-object)))))

    (define (generator->flexvector generator)
      "Consume GENERATOR into a new flexvector."
      #((parameters
         (generator (type procedure)
          (description "Generator consumed through its EOF result.")))
        (returns (type flexvector)
         (description "Fresh flexvector of generated values.")))
      (let ((result (flexvector)))
        (let loop ((value (generator)))
          (if (eof-object? value)
              result
              (begin
                (flexvector-add-back! result value)
                (loop (generator)))))))
))
