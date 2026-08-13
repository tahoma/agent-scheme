;;; SRFI 158 generator and accumulator library support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2015 Shiro Kawai, John Cowan, Thomas Gilray
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib generator)' as a portable R7RS adaptation of the
;;; official SRFI 158 sample implementation:
;;; https://github.com/scheme-requests-for-implementation/srfi-158.
;;; Local patches wrap the source in Consent Scheme's stdlib namespace, keep
;;; `(scheme generator)', `(srfi 158)', and `(srfi srfi-158)' as registry
;;; aliases, and tighten a few small portability edges while preserving SRFI
;;; behavior.

(define-library (stdlib generator)
  (export generator circular-generator make-iota-generator make-range-generator
          make-coroutine-generator list->generator vector->generator
          reverse-vector->generator string->generator bytevector->generator
          make-for-each-generator make-unfold-generator
          gcons* gappend gcombine gfilter gremove
          gtake gdrop gtake-while gdrop-while
          gflatten ggroup gmerge gmap gstate-filter
          gdelete gdelete-neighbor-dups gindex gselect
          generator->list generator->reverse-list
          generator->vector generator->vector! generator->string
          generator-fold generator-map->list generator-for-each generator-find
          generator-count generator-any generator-every generator-unfold
          make-accumulator count-accumulator list-accumulator
          reverse-list-accumulator vector-accumulator
          reverse-vector-accumulator vector-accumulator!
          string-accumulator bytevector-accumulator bytevector-accumulator!
          sum-accumulator product-accumulator)
  (import (scheme base)
          (scheme case-lambda)
          (stdlib flexvectors))
  (begin
    ;; Return an unspecified value portably.
    (define (unspecified)
      "Return an unspecified value portably."
      (if #f #f))

    ;; Return the first true value produced by PRED over LIST.
    (define (any pred list)
      "Return the first true value produced by PRED over LIST."
      (cond
       ((null? list) #f)
       ((null? (cdr list)) (pred (car list)))
       (else
        (let ((value (pred (car list))))
          (if value value (any pred (cdr list)))))))

    ;; Pull GENERATORS from left to right, stopping as soon as EOF appears.
    (define (generator-values-or-eof generators)
      "Return generated values from GENERATORS, or EOF if any is exhausted."
      (let loop ((rest generators) (values '()))
        (if (null? rest)
            (reverse values)
            (let ((value ((car rest))))
              (if (eof-object? value)
                  value
                  (loop (cdr rest) (cons value values)))))))

    ;; Validate VALUE as a non-negative integer for NAME.
    (define (check-non-negative-integer name value)
      "Validate VALUE as a non-negative integer for NAME."
      (if (and (integer? value) (not (negative? value)))
          value
          (error "expected non-negative integer" name value)))

    ;; Convert LIST of bytes to a bytevector.
    (define (list->bytevector bytes)
      "Convert LIST of bytes to a bytevector."
      (let ((bytevector (make-bytevector (length bytes) 0)))
        (let loop ((index 0) (rest bytes))
          (if (null? rest)
              bytevector
              (begin
                (bytevector-u8-set! bytevector index (car rest))
                (loop (+ index 1) (cdr rest)))))))

    ;; The simplest finite generator.
    (define (generator . args)
      "Return a finite generator over ARGS."
      #((parameters
         (args (type list)
          (description "Values to yield before EOF.")))
        (returns (type procedure)
         (description "A thunk yielding each value, then EOF."))
        (effects allocation state-write))
      (lambda ()
        (if (null? args)
            (eof-object)
            (let ((next (car args)))
              (set! args (cdr args))
              next))))

    ;; The simplest infinite generator over ARGS.
    (define (circular-generator . args)
      "Return an infinite generator cycling over ARGS."
      #((parameters
         (args (type list)
          (description "Values to repeat indefinitely.")))
        (returns (type procedure)
         (description "A thunk yielding the values cyclically."))
        (effects allocation state-write))
      (let ((base-args args))
        (lambda ()
          (when (null? args)
            (set! args base-args))
          (let ((next (car args)))
            (set! args (cdr args))
            next))))

    ;; Build a finite arithmetic generator with COUNT values.
    (define (make-iota-generator count . rest)
      "Return a generator over COUNT arithmetic values."
      #((parameters
         (count (type exact-integer)
          (description "Number of values to generate."))
         (rest (type list)
          (description "Optional start and step values.")))
        (returns (type procedure)
         (description "A finite arithmetic generator."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((count)
         (make-iota-generator count 0 1))
        ((count start)
         (make-iota-generator count start 1))
        ((count start step)
         (lambda ()
           (if (<= count 0)
               (eof-object)
               (let ((result start))
                 (set! count (- count 1))
                 (set! start (+ start step))
                 result)))))
       count
       rest))

    ;; Build a finite or infinite arithmetic range generator.
    (define (make-range-generator start . rest)
      "Return a generator over an arithmetic range."
      #((parameters
         (start (type number)
          (description "First generated value."))
         (rest (type list)
          (description "Optional end and step values.")))
        (returns (type procedure)
         (description "An arithmetic range generator."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((start)
         (lambda ()
           (let ((result start))
             (set! start (+ start 1))
             result)))
        ((start end)
         (make-range-generator start end 1))
        ((start end step)
         (lambda ()
           (if (< start end)
               (let ((result start))
                 (set! start (+ start step))
                 result)
               (eof-object)))))
       start
       rest))

    ;; Build a generator from a procedure that calls YIELD to emit values.
    (define (make-coroutine-generator proc)
      "Return a generator controlled by PROC and its yield callback."
      #((parameters
         (proc (type procedure)
          (description "Procedure called with a yield procedure.")))
        (returns (type procedure)
         (description "A generator thunk driven by PROC."))
        (effects procedure-call allocation state-write))
      (let ((return #f)
            (resume #f))
        (letrec
            ((yield
              (lambda (value)
                (call/cc
                 (lambda (next)
                   (set! resume next)
                   (return value))))))
          (lambda ()
            (call/cc
             (lambda (current-return)
               (set! return current-return)
               (if resume
                   (resume (unspecified))
                   (begin
                     (proc yield)
                     (set! resume
                           (lambda (ignored)
                             (return (eof-object))))
                     (return (eof-object))))))))))

    ;; Build a generator over LIST.
    (define (list->generator list)
      "Return a generator over LIST."
      #((parameters
         (list (type list)
          (description "Values to yield in order.")))
        (returns (type procedure)
         (description "A finite generator over LIST."))
        (effects allocation state-write))
      (lambda ()
        (if (null? list)
            (eof-object)
            (let ((next (car list)))
              (set! list (cdr list))
              next))))

    ;; Build a generator over VECTOR from START inclusive to END exclusive.
    (define (vector->generator vector . rest)
      "Return a generator over VECTOR."
      #((parameters
         (vector (type vector)
          (description "Vector to traverse from left to right."))
         (rest (type list)
          (description "Optional start and end bounds.")))
        (returns (type procedure)
         (description "A finite generator over VECTOR."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((vector)
         (vector->generator vector 0 (vector-length vector)))
        ((vector start)
         (vector->generator vector start (vector-length vector)))
        ((vector start end)
         (lambda ()
           (if (>= start end)
               (eof-object)
               (let ((next (vector-ref vector start)))
                 (set! start (+ start 1))
                 next)))))
       vector
       rest))

    ;; Build a reverse generator over VECTOR from END exclusive to START.
    (define (reverse-vector->generator vector . rest)
      "Return a reverse generator over VECTOR."
      #((parameters
         (vector (type vector)
          (description "Vector to traverse from right to left."))
         (rest (type list)
          (description "Optional start and end bounds.")))
        (returns (type procedure)
         (description "A finite reverse generator over VECTOR."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((vector)
         (reverse-vector->generator vector 0 (vector-length vector)))
        ((vector start)
         (reverse-vector->generator vector start (vector-length vector)))
        ((vector start end)
         (lambda ()
           (if (>= start end)
               (eof-object)
               (begin
                 (set! end (- end 1))
                 (vector-ref vector end))))))
       vector
       rest))

    ;; Build a generator over STRING from START inclusive to END exclusive.
    (define (string->generator string . rest)
      "Return a generator over STRING's characters."
      #((parameters
         (string (type string)
          (description "String to traverse from left to right."))
         (rest (type list)
          (description "Optional start and end bounds.")))
        (returns (type procedure)
         (description "A finite character generator."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((string)
         (string->generator string 0 (string-length string)))
        ((string start)
         (string->generator string start (string-length string)))
        ((string start end)
         (lambda ()
           (if (>= start end)
               (eof-object)
               (let ((next (string-ref string start)))
                 (set! start (+ start 1))
                 next)))))
       string
       rest))

    ;; Build a generator over BYTEVECTOR from START inclusive to END exclusive.
    (define (bytevector->generator bytevector . rest)
      "Return a generator over BYTEVECTOR's bytes."
      #((parameters
         (bytevector (type bytevector)
          (description "Bytevector to traverse from left to right."))
         (rest (type list)
          (description "Optional start and end bounds.")))
        (returns (type procedure)
         (description "A finite byte generator."))
        (effects allocation state-write))
      (apply
       (case-lambda
        ((bytevector)
         (bytevector->generator bytevector 0 (bytevector-length bytevector)))
        ((bytevector start)
         (bytevector->generator bytevector start
                                (bytevector-length bytevector)))
        ((bytevector start end)
         (lambda ()
           (if (>= start end)
               (eof-object)
               (let ((next (bytevector-u8-ref bytevector start)))
                 (set! start (+ start 1))
                 next)))))
       bytevector
       rest))

    ;; Convert a collection's for-each procedure into a generator.
    (define (make-for-each-generator for-each obj)
      "Return a generator backed by FOR-EACH over OBJ."
      #((parameters
         (for-each (type procedure)
          (description "Procedure that visits OBJ's values."))
         (obj (type any)
          (description "Collection argument passed to FOR-EACH.")))
        (returns (type procedure)
         (description "A generator yielding the visited values."))
        (effects procedure-call allocation state-write))
      (make-coroutine-generator
       (lambda (yield)
         (for-each yield obj))))

    ;; Build an unfold-style generator.
    (define (make-unfold-generator stop? mapper successor seed)
      "Return a generator by unfolding SEED."
      #((parameters
         (stop? (type procedure)
          (description "Predicate that stops generation."))
         (mapper (type procedure)
          (description "Procedure mapping state to a yielded value."))
         (successor (type procedure)
          (description "Procedure advancing state."))
         (seed (type any)
          (description "Initial unfold state.")))
        (returns (type procedure)
         (description "A generator over the unfolded values."))
        (effects procedure-call allocation state-write))
      (make-coroutine-generator
       (lambda (yield)
         (let loop ((state seed))
           (if (stop? state)
               (unspecified)
               (begin
                 (yield (mapper state))
                 (loop (successor state))))))))

    ;; Prefix ITEM values before delegating to the final generator.
    (define (gcons* . args)
      "Return a generator yielding ARGS before the final generator."
      #((parameters
         (args (type list)
          (description "Prefix values followed by a final generator.")))
        (returns (type procedure)
         (description "A generator yielding prefix values then delegating."))
        (effects allocation state-write procedure-call))
      (lambda ()
        (cond
         ((null? args) (eof-object))
         ((null? (cdr args)) ((car args)))
         (else
          (let ((value (car args)))
            (set! args (cdr args))
            value)))))

    ;; Append generators, yielding from each until it is exhausted.
    (define (gappend . generators)
      "Return a generator appending GENERATORS in order."
      #((parameters
         (generators (type list)
          (description "Generators to consume from left to right.")))
        (returns (type procedure)
         (description "A generator yielding every input stream in order."))
        (effects allocation state-write procedure-call))
      (lambda ()
        (let loop ()
          (if (null? generators)
              (eof-object)
              (let ((value ((car generators))))
                (if (eof-object? value)
                    (begin
                      (set! generators (cdr generators))
                      (loop))
                    value))))))

    ;; Flatten lists produced by GEN into one stream of values.
    (define (gflatten gen)
      "Return a generator flattening lists produced by GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator yielding lists or EOF.")))
        (returns (type procedure)
         (description "A generator yielding each list element."))
        (effects allocation state-write procedure-call))
      (let ((state '()))
        (lambda ()
          (let loop ()
            (cond
             ((eof-object? state) state)
             ((null? state)
              (set! state (gen))
              (loop))
             (else
              (let ((obj (car state)))
                (set! state (cdr state))
                obj)))))))

    ;; Group values from GEN into lists of K values.
    (define (ggroup gen k . rest)
      "Return a generator grouping values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator supplying values to group."))
         (k (type exact-integer)
          (description "Group size."))
         (rest (type list)
          (description "Optional padding value.")))
        (returns (type procedure)
         (description "A generator yielding lists of up to K values."))
        (effects allocation state-write procedure-call))
      (apply
       (case-lambda
        ((gen k)
         (simple-ggroup gen k))
        ((gen k padding)
         (padded-ggroup (simple-ggroup gen k) k padding)))
       gen
       k
       rest))

    ;; Group values without padding the final group.
    (define (simple-ggroup gen k)
      "Group values from GEN into unpadded groups of K values."
      (lambda ()
        (let loop ((item (gen)) (result '()) (count (- k 1)))
          (cond
           ((eof-object? item)
            (if (null? result) item (reverse result)))
           ((= count 0)
            (reverse (cons item result)))
           (else
            (loop (gen) (cons item result) (- count 1)))))))

    ;; Pad short groups from GEN to length K.
    (define (padded-ggroup gen k padding)
      "Pad short groups from GEN to length K."
      (lambda ()
        (let ((item (gen)))
          (if (eof-object? item)
              item
              (let ((len (length item)))
                (if (= len k)
                    item
                    (append item (make-list (- k len) padding))))))))

    ;; Merge sorted generators using LESS-THAN.
    (define (gmerge less-than . generators)
      "Return a generator merging sorted input generators."
      #((parameters
         (less-than (type procedure)
          (description "Ordering predicate for generated values."))
         (generators (type list)
          (description "Sorted input generators to merge.")))
        (returns (type procedure)
         (description "A generator yielding merged values in order."))
        (effects allocation state-write procedure-call error))
      (apply
       (case-lambda
        ((less-than)
         (error "wrong number of arguments for gmerge" less-than))
        ((less-than gen)
         gen)
        ((less-than gen-left gen-right)
         (let ((left (gen-left))
               (right (gen-right)))
           (lambda ()
             (cond
              ((and (eof-object? left) (eof-object? right))
               left)
              ((eof-object? left)
               (let ((obj right))
                 (set! right (gen-right))
                 obj))
              ((eof-object? right)
               (let ((obj left))
                 (set! left (gen-left))
                 obj))
              ((less-than right left)
               (let ((obj right))
                 (set! right (gen-right))
                 obj))
              (else
               (let ((obj left))
                 (set! left (gen-left))
                 obj))))))
        ((less-than . generators)
         (apply gmerge
                less-than
                (let loop ((rest generators) (merged '()))
                  (cond
                   ((null? rest) (reverse merged))
                   ((null? (cdr rest)) (reverse (cons (car rest) merged)))
                   (else
                    (loop (cddr rest)
                          (cons (gmerge less-than (car rest) (cadr rest))
                                merged))))))))
       less-than
       generators))

    ;; Map PROC over one or more generators without consuming them eagerly.
    (define (gmap proc . generators)
      "Return a generator mapping PROC over generators."
      #((parameters
         (proc (type procedure)
          (description "Mapping procedure applied to generated values."))
         (generators (type list)
          (description "Generators to consume in parallel.")))
        (returns (type procedure)
         (description "A generator yielding mapped values."))
        (effects allocation state-write procedure-call error))
      (apply
       (case-lambda
        ((proc)
         (error "wrong number of arguments for gmap" proc))
        ((proc gen)
         (lambda ()
           (let ((item (gen)))
             (if (eof-object? item) item (proc item)))))
        ((proc . generators)
         (lambda ()
           (let ((items (generator-values-or-eof generators)))
             (if (eof-object? items)
                 (eof-object)
                 (apply proc items))))))
       proc
       generators))

    ;; Map with state over one or more generators.
    (define (gcombine proc seed . generators)
      "Return a stateful generator combining GENERATORS with PROC."
      #((parameters
         (proc (type procedure)
          (description "Procedure returning a value and next state."))
         (seed (type any)
          (description "Initial state."))
         (generators (type list)
          (description "Input generators.")))
        (returns (type procedure)
         (description "A generator yielding combined values."))
        (effects allocation state-write procedure-call))
      (lambda ()
        (let ((items (generator-values-or-eof generators)))
          (if (eof-object? items)
              (eof-object)
              (call-with-values
               (lambda () (apply proc (append items (list seed))))
               (lambda (value new-seed)
                 (set! seed new-seed)
                 value))))))

    ;; Yield only values from GEN that satisfy PRED.
    (define (gfilter pred gen)
      "Return a generator keeping values that satisfy PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Input generator.")))
        (returns (type procedure)
         (description "A filtering generator."))
        (effects allocation state-write procedure-call))
      (lambda ()
        (let loop ()
          (let ((next (gen)))
            (if (or (eof-object? next) (pred next))
                next
                (loop))))))

    ;; Yield only values selected by PROC while threading state.
    (define (gstate-filter proc seed gen)
      "Return a generator filtering GEN with stateful PROC."
      #((parameters
         (proc (type procedure)
          (description "Procedure returning keep? and next state."))
         (seed (type any)
          (description "Initial state."))
         (gen (type procedure)
          (description "Input generator.")))
        (returns (type procedure)
         (description "A stateful filtering generator."))
        (effects allocation state-write procedure-call))
      (let ((state seed))
        (lambda ()
          (let loop ((item (gen)))
            (if (eof-object? item)
                item
                (call-with-values
                 (lambda () (proc item state))
                 (lambda (yes new-state)
                   (set! state new-state)
                   (if yes item (loop (gen))))))))))

    ;; Yield only values from GEN that do not satisfy PRED.
    (define (gremove pred gen)
      "Return a generator removing values that satisfy PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Input generator.")))
        (returns (type procedure)
         (description "A filtering generator."))
        (effects allocation state-write procedure-call))
      (gfilter (lambda (value) (not (pred value))) gen))

    ;; Take at most K values from GEN.
    (define (gtake gen k . rest)
      "Return a generator taking at most K values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Input generator."))
         (k (type exact-integer)
          (description "Maximum number of values to yield."))
         (rest (type list)
          (description "Optional padding value.")))
        (returns (type procedure)
         (description "A bounded generator."))
        (effects allocation state-write procedure-call error))
      (apply
       (case-lambda
        ((gen k)
         (check-non-negative-integer 'gtake k)
         (let ((remaining k)
               (done? #f))
           (lambda ()
             (cond
              ((or done? (<= remaining 0)) (eof-object))
              (else
               (let ((value (gen)))
                 (if (eof-object? value)
                     (begin
                       (set! done? #t)
                       value)
                     (begin
                       (set! remaining (- remaining 1))
                       value))))))))
        ((gen k padding)
         (check-non-negative-integer 'gtake k)
         (let ((remaining k))
           (lambda ()
             (if (<= remaining 0)
                 (eof-object)
                 (begin
                   (set! remaining (- remaining 1))
                   (let ((value (gen)))
                     (if (eof-object? value) padding value))))))))
       gen
       k
       rest))

    ;; Drop K values from GEN before yielding.
    (define (gdrop gen k)
      "Return a generator dropping K initial values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Input generator."))
         (k (type exact-integer)
          (description "Number of values to skip.")))
        (returns (type procedure)
         (description "A generator yielding values after the skipped prefix."))
        (effects allocation state-write procedure-call error))
      (check-non-negative-integer 'gdrop k)
      (let ((dropped? #f))
        (lambda ()
          (unless dropped?
            (let loop ()
              (when (> k 0)
                (set! k (- k 1))
                (gen)
                (loop)))
            (set! dropped? #t))
          (gen))))

    ;; Yield values while PRED remains true.
    (define (gtake-while pred gen)
      "Return a generator taking values while PRED remains true."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Input generator.")))
        (returns (type procedure)
         (description "A prefix generator."))
        (effects allocation state-write procedure-call))
      (let ((done? #f))
        (lambda ()
          (if done?
              (eof-object)
              (let ((next (gen)))
                (cond
                 ((eof-object? next) next)
                 ((pred next) next)
                 (else
                  (set! done? #t)
                  (eof-object))))))))

    ;; Drop values while PRED remains true, then yield the rest.
    (define (gdrop-while pred gen)
      "Return a generator dropping values while PRED remains true."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Input generator.")))
        (returns (type procedure)
         (description "A generator yielding the remaining suffix."))
        (effects allocation state-write procedure-call))
      (let ((found? #f))
        (lambda ()
          (let loop ()
            (let ((value (gen)))
              (cond
               (found? value)
               ((and (not (eof-object? value)) (pred value))
                (loop))
               (else
                (set! found? #t)
                value)))))))

    ;; Delete values equal to ITEM from GEN.
    (define (gdelete item gen . rest)
      "Return a generator deleting ITEM from GEN."
      #((parameters
         (item (type any)
          (description "Value to remove."))
         (gen (type procedure)
          (description "Input generator."))
         (rest (type list)
          (description "Optional equality predicate.")))
        (returns (type procedure)
         (description "A generator without matching values."))
        (effects allocation state-write procedure-call))
      (apply
       (case-lambda
        ((item gen)
         (gdelete item gen equal?))
        ((item gen equal)
         (lambda ()
           (let loop ((value (gen)))
             (cond
              ((eof-object? value) value)
              ((equal item value) (loop (gen)))
              (else value))))))
       item
       gen
       rest))

    ;; Delete neighboring duplicate values from GEN.
    (define (gdelete-neighbor-dups gen . rest)
      "Return a generator deleting adjacent duplicates from GEN."
      #((parameters
         (gen (type procedure)
          (description "Input generator."))
         (rest (type list)
          (description "Optional equality predicate.")))
        (returns (type procedure)
         (description "A generator with adjacent duplicates collapsed."))
        (effects allocation state-write procedure-call))
      (apply
       (case-lambda
        ((gen)
         (gdelete-neighbor-dups gen equal?))
        ((gen equal)
         (let ((first? #t)
               (previous #f))
           (lambda ()
             (if first?
                 (begin
                   (set! first? #f)
                   (set! previous (gen))
                   previous)
                 (let loop ((value (gen)))
                   (cond
                    ((eof-object? value) value)
                    ((equal previous value) (loop (gen)))
                    (else
                     (set! previous value)
                     value))))))))
       gen
       rest))

    ;; Select values from VALUE-GEN at strictly increasing indices.
    (define (gindex value-gen index-gen)
      "Return a generator selecting VALUE-GEN values by INDEX-GEN."
      #((parameters
         (value-gen (type procedure)
          (description "Generator supplying values to select."))
         (index-gen (type procedure)
          (description "Generator supplying selected indices.")))
        (returns (type procedure)
         (description "A generator yielding indexed values."))
        (effects allocation state-write procedure-call error))
      (let ((done? #f)
            (position 0)
            (previous-index -1))
        (lambda ()
          (if done?
              (eof-object)
              (let ((index (index-gen)))
                (cond
                 ((eof-object? index)
                  (set! done? #t)
                  (eof-object))
                 ((or (not (integer? index))
                      (negative? index)
                      (<= index previous-index))
                  (error "expected strictly increasing non-negative index"
                         index))
                 (else
                  (let loop ((value (value-gen)))
                    (cond
                     ((eof-object? value)
                      (set! done? #t)
                      value)
                     ((= position index)
                      (set! position (+ position 1))
                      (set! previous-index index)
                      value)
                    (else
                      (set! position (+ position 1))
                      (loop (value-gen))))))))))))

    ;; Select values whose paired truth generator value is true.
    (define (gselect value-gen truth-gen)
      "Return a generator selecting values paired with true values."
      #((parameters
         (value-gen (type procedure)
          (description "Generator supplying values to select."))
         (truth-gen (type procedure)
          (description "Generator supplying selection booleans.")))
        (returns (type procedure)
         (description "A generator yielding selected values."))
        (effects allocation state-write procedure-call))
      (let ((done? #f))
        (lambda ()
          (if done?
              (eof-object)
              (let loop ((value (value-gen)) (truth (truth-gen)))
                (cond
                 ((or (eof-object? value) (eof-object? truth))
                  (set! done? #t)
                  (eof-object))
                 (truth value)
                 (else (loop (value-gen) (truth-gen)))))))))

    ;; Consume GEN into a list, optionally bounded by K.
    (define (generator->list gen . rest)
      "Return a list containing all values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator to consume."))
         (rest (type list)
          (description "Optional maximum count.")))
        (returns (type list)
         (description "Generated values in order."))
        (effects allocation procedure-call))
      (apply
       (case-lambda
        ((gen)
         (reverse (generator->reverse-list gen)))
        ((gen k)
         (generator->list (gtake gen k))))
       gen
       rest))

    ;; Consume GEN into a reverse-order list, optionally bounded by K.
    (define (generator->reverse-list gen . rest)
      "Return a reverse-order list containing all values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator to consume."))
         (rest (type list)
          (description "Optional maximum count.")))
        (returns (type list)
         (description "Generated values in reverse order."))
        (effects allocation procedure-call))
      (apply
       (case-lambda
        ((gen)
         (generator-fold cons '() gen))
        ((gen k)
         (generator->reverse-list (gtake gen k))))
       gen
       rest))

    ;; Consume GEN into a vector, optionally bounded by K.
    (define (generator->vector gen . rest)
      "Return a vector containing all values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator to consume."))
         (rest (type list)
          (description "Optional maximum count.")))
        (returns (type vector)
         (description "Generated values in order."))
        (effects allocation procedure-call))
      (apply
       (case-lambda
        ((gen)
         (flexvector->vector (generator->flexvector gen)))
        ((gen k)
         (flexvector->vector (generator->flexvector (gtake gen k)))))
       gen
       rest))

    ;; Fill VECTOR with values from GEN starting at AT.
    (define (generator->vector! vector at gen)
      "Write values from GEN into VECTOR starting at AT."
      #((parameters
         (vector (type vector)
          (description "Vector to mutate."))
         (at (type exact-integer)
          (description "Starting index."))
         (gen (type procedure)
          (description "Generator to consume.")))
        (returns (type exact-integer)
         (description "Number of values written."))
        (effects state-write procedure-call))
      (let loop ((count 0) (index at))
        (cond
         ((>= index (vector-length vector)) count)
         (else
          (let ((value (gen)))
            (if (eof-object? value)
                count
                (begin
                  (vector-set! vector index value)
                  (loop (+ count 1) (+ index 1)))))))))

    ;; Consume GEN into a string, optionally bounded by K.
    (define (generator->string gen . rest)
      "Return a string containing characters from GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator yielding characters."))
         (rest (type list)
          (description "Optional maximum count.")))
        (returns (type string)
         (description "Generated characters in order."))
        (effects allocation procedure-call))
      (apply
       (case-lambda
        ((gen)
         (list->string (generator->list gen)))
        ((gen k)
         (list->string (generator->list gen k))))
       gen
       rest))

    ;; Fold over one or more generators.
    (define (generator-fold proc seed . generators)
      "Fold PROC over values from GENERATORS."
      #((parameters
         (proc (type procedure)
          (description "Folding procedure."))
         (seed (type any)
          (description "Initial fold state."))
         (generators (type list)
          (description "Generators to consume in parallel.")))
        (returns (type any)
         (description "Final fold state."))
        (effects procedure-call))
      (if (and (pair? generators) (null? (cdr generators)))
          (let ((gen (car generators)))
            (let loop ((state seed))
              (let ((value (gen)))
                (if (eof-object? value)
                    state
                    (loop (proc value state))))))
          (let loop ((state seed))
            (let ((values (generator-values-or-eof generators)))
              (if (eof-object? values)
                  state
                  (loop
                   (apply proc (append values (list state)))))))))

    ;; Apply PROC for side effects over one or more generators.
    (define (generator-for-each proc . generators)
      "Apply PROC to values from GENERATORS for side effects."
      #((parameters
         (proc (type procedure)
          (description "Procedure applied to generated values."))
         (generators (type list)
          (description "Generators to consume in parallel.")))
        (returns (type any)
         (description "Unspecified value."))
        (effects procedure-call))
      (if (and (pair? generators) (null? (cdr generators)))
          (let ((gen (car generators)))
            (let loop ()
              (let ((value (gen)))
                (if (eof-object? value)
                    (unspecified)
                    (begin
                      (proc value)
                      (loop))))))
          (let loop ()
            (let ((values (generator-values-or-eof generators)))
              (if (eof-object? values)
                  (unspecified)
                  (begin
                    (apply proc values)
                    (loop)))))))

    ;; Map PROC over one or more generators and return a list.
    (define (generator-map->list proc . generators)
      "Return a list by mapping PROC over GENERATORS."
      #((parameters
         (proc (type procedure)
          (description "Mapping procedure."))
         (generators (type list)
          (description "Generators to consume in parallel.")))
        (returns (type list)
         (description "Mapped values in order."))
        (effects allocation procedure-call))
      (if (and (pair? generators) (null? (cdr generators)))
          (let ((gen (car generators)))
            (let loop ((result '()))
              (let ((value (gen)))
                (if (eof-object? value)
                    (reverse result)
                    (loop (cons (proc value) result))))))
          (let loop ((result '()))
            (let ((values (generator-values-or-eof generators)))
              (if (eof-object? values)
                  (reverse result)
                  (loop (cons (apply proc values) result)))))))

    ;; Return the first value from GEN satisfying PRED, or #f.
    (define (generator-find pred gen)
      "Return the first generated value satisfying PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Generator to consume.")))
        (returns (type any)
         (description "Matching value, or #f."))
        (effects procedure-call))
      (let loop ((value (gen)))
        (cond
         ((eof-object? value) #f)
         ((pred value) value)
         (else (loop (gen))))))

    ;; Count values from GEN satisfying PRED.
    (define (generator-count pred gen)
      "Return the count of values from GEN satisfying PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Generator to consume.")))
        (returns (type exact-integer)
         (description "Number of matching values."))
        (effects procedure-call))
      (generator-fold
       (lambda (value count)
         (if (pred value) (+ count 1) count))
       0
       gen))

    ;; Return the first true PRED result over GEN, or #f.
    (define (generator-any pred gen)
      "Return the first true PRED result over GEN."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Generator to consume.")))
        (returns (type any)
         (description "First true predicate result, or #f."))
        (effects procedure-call))
      (let loop ((item (gen)))
        (cond
         ((eof-object? item) #f)
         ((pred item))
         (else (loop (gen))))))

    ;; Return the last true PRED result over GEN, or the first false result.
    (define (generator-every pred gen)
      "Return whether PRED succeeds for every value from GEN."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to generated values."))
         (gen (type procedure)
          (description "Generator to consume.")))
        (returns (type any)
         (description "Last true predicate result, or #f."))
        (effects procedure-call))
      (let loop ((item (gen)) (last #t))
        (if (eof-object? item)
            last
            (let ((result (pred item)))
              (if result
                  (loop (gen) result)
                  #f)))))

    ;; Unfold values from GEN with an SRFI 1 style UNFOLD procedure.
    (define (generator-unfold gen unfold . args)
      "Apply UNFOLD to values from GEN."
      #((parameters
         (gen (type procedure)
          (description "Generator to consume."))
         (unfold (type procedure)
          (description "SRFI 1 style unfold procedure."))
         (args (type list)
          (description "Additional arguments passed to UNFOLD.")))
        (returns (type any)
         (description "Result returned by UNFOLD."))
        (effects allocation procedure-call))
      (apply unfold eof-object? (lambda (value) value)
             (lambda (value) (gen)) (gen) args))

    ;; Build an accumulator from a folding procedure and finalizer.
    (define (make-accumulator kons knil finalizer)
      "Return an accumulator using KONS, KNIL, and FINALIZER."
      #((parameters
         (kons (type procedure)
          (description "Procedure incorporating each supplied value."))
         (knil (type any)
          (description "Initial accumulator state."))
         (finalizer (type procedure)
          (description "Procedure producing the final result.")))
        (returns (type procedure)
         (description "Accumulator procedure accepting values or EOF."))
        (effects allocation state-write procedure-call))
      (let ((state knil)
            (done? #f))
        (lambda (obj)
          (if (eof-object? obj)
              (begin
                (set! done? #t)
                (finalizer state))
              (if done?
                  (error "accumulator already finalized")
                  (begin
                    (set! state (kons obj state))
                    (unspecified)))))))

    ;; Count accumulated values.
    (define (count-accumulator)
      "Return an accumulator that counts supplied values."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a count at EOF."))
        (effects allocation state-write))
      (make-accumulator
       (lambda (obj state)
         obj
         (+ state 1))
       0
       (lambda (state) state)))

    ;; Accumulate values into a list in arrival order.
    (define (list-accumulator)
      "Return an accumulator that builds a list in arrival order."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a list at EOF."))
        (effects allocation state-write))
      (make-accumulator cons '() reverse))

    ;; Accumulate values into a list in reverse arrival order.
    (define (reverse-list-accumulator)
      "Return an accumulator that builds a reverse-order list."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a reverse-order list at EOF."))
        (effects allocation state-write))
      (make-accumulator cons '() (lambda (state) state)))

    ;; Accumulate values into a vector in arrival order.
    (define (vector-accumulator)
      "Return an accumulator that builds a vector in arrival order."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a vector at EOF."))
        (effects allocation state-write))
      (make-accumulator
       (lambda (obj state)
         (flexvector-add-back! state obj)
         state)
       (flexvector)
       flexvector->vector))

    ;; Accumulate values into a vector in reverse arrival order.
    (define (reverse-vector-accumulator)
      "Return an accumulator that builds a reverse-order vector."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a reverse-order vector at EOF."))
        (effects allocation state-write))
      (make-accumulator
       (lambda (obj state)
         (flexvector-add-back! state obj)
         state)
       (flexvector)
       (lambda (state)
         (flexvector->vector (flexvector-reverse-copy state)))))

    ;; Accumulate values into VECTOR starting at AT.
    (define (vector-accumulator! vector at)
      "Return an accumulator that writes into VECTOR starting at AT."
      #((parameters
         (vector (type vector)
          (description "Vector to mutate."))
         (at (type exact-integer)
          (description "Starting index.")))
        (returns (type procedure)
         (description "Accumulator returning VECTOR at EOF."))
        (effects allocation state-write error))
      (let ((done? #f))
        (lambda (obj)
          (if (eof-object? obj)
              (begin
                (set! done? #t)
                vector)
              (if done?
                  (error "accumulator already finalized")
                  (begin
                    (vector-set! vector at obj)
                    (set! at (+ at 1))
                    (unspecified)))))))

    ;; Accumulate characters into a string.
    (define (string-accumulator)
      "Return an accumulator that builds a string."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a string at EOF."))
        (effects allocation state-write))
      (make-accumulator
       cons
       '()
       (lambda (state) (list->string (reverse state)))))

    ;; Accumulate bytes into a bytevector.
    (define (bytevector-accumulator)
      "Return an accumulator that builds a bytevector."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a bytevector at EOF."))
        (effects allocation state-write))
      (make-accumulator
       cons
       '()
       (lambda (state) (list->bytevector (reverse state)))))

    ;; Accumulate bytes into BYTEVECTOR starting at AT.
    (define (bytevector-accumulator! bytevector at)
      "Return an accumulator that writes into BYTEVECTOR starting at AT."
      #((parameters
         (bytevector (type bytevector)
          (description "Bytevector to mutate."))
         (at (type exact-integer)
          (description "Starting index.")))
        (returns (type procedure)
         (description "Accumulator returning BYTEVECTOR at EOF."))
        (effects allocation state-write error))
      (let ((done? #f))
        (lambda (obj)
          (if (eof-object? obj)
              (begin
                (set! done? #t)
                bytevector)
              (if done?
                  (error "accumulator already finalized")
                  (begin
                    (bytevector-u8-set! bytevector at obj)
                    (set! at (+ at 1))
                    (unspecified)))))))

    ;; Accumulate numbers into a sum.
    (define (sum-accumulator)
      "Return an accumulator that sums supplied numbers."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a numeric sum at EOF."))
        (effects allocation state-write procedure-call))
      (make-accumulator + 0 (lambda (state) state)))

    ;; Accumulate numbers into a product.
    (define (product-accumulator)
      "Return an accumulator that multiplies supplied numbers."
      #((parameters)
        (returns (type procedure)
         (description "Accumulator returning a numeric product at EOF."))
        (effects allocation state-write procedure-call))
      (make-accumulator * 1 (lambda (state) state)))))
