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
          (scheme case-lambda))
  (begin
    ;; Return an unspecified value portably.
    (define unspecified (lambda ()
      (if #f #f)))

    ;; Return the first true value produced by PRED over LIST.
    (define any (lambda (pred list)
      (cond
       ((null? list) #f)
       ((null? (cdr list)) (pred (car list)))
       (else
        (let ((value (pred (car list))))
          (if value value (any pred (cdr list))))))))

    ;; Validate VALUE as a non-negative integer for NAME.
    (define check-non-negative-integer (lambda (name value)
      (if (and (integer? value) (not (negative? value)))
          value
          (error "expected non-negative integer" name value))))

    ;; Convert LIST of bytes to a bytevector.
    (define list->bytevector (lambda (bytes)
      (let ((bytevector (make-bytevector (length bytes) 0)))
        (let loop ((index 0) (rest bytes))
          (if (null? rest)
              bytevector
              (begin
                (bytevector-u8-set! bytevector index (car rest))
                (loop (+ index 1) (cdr rest))))))))

    ;; The simplest finite generator.
    (define generator (lambda args
      (lambda ()
        (if (null? args)
            (eof-object)
            (let ((next (car args)))
              (set! args (cdr args))
              next)))))

    ;; The simplest infinite generator over ARGS.
    (define circular-generator (lambda args
      (let ((base-args args))
        (lambda ()
          (when (null? args)
            (set! args base-args))
          (let ((next (car args)))
            (set! args (cdr args))
            next)))))

    ;; Build a finite arithmetic generator with COUNT values.
    (define make-iota-generator
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
                 result))))))

    ;; Build a finite or infinite arithmetic range generator.
    (define make-range-generator
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
               (eof-object))))))

    ;; Build a generator from a procedure that calls YIELD to emit values.
    (define make-coroutine-generator (lambda (proc)
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
                     (return (eof-object)))))))))))

    ;; Build a generator over LIST.
    (define list->generator (lambda (list)
      (lambda ()
        (if (null? list)
            (eof-object)
            (let ((next (car list)))
              (set! list (cdr list))
              next)))))

    ;; Build a generator over VECTOR from START inclusive to END exclusive.
    (define vector->generator
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
                 next))))))

    ;; Build a reverse generator over VECTOR from END exclusive to START.
    (define reverse-vector->generator
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
                 (vector-ref vector end)))))))

    ;; Build a generator over STRING from START inclusive to END exclusive.
    (define string->generator
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
                 next))))))

    ;; Build a generator over BYTEVECTOR from START inclusive to END exclusive.
    (define bytevector->generator
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
                 next))))))

    ;; Convert a collection's for-each procedure into a generator.
    (define make-for-each-generator (lambda (for-each obj)
      (make-coroutine-generator
       (lambda (yield)
         (for-each yield obj)))))

    ;; Build an unfold-style generator.
    (define make-unfold-generator (lambda (stop? mapper successor seed)
      (make-coroutine-generator
       (lambda (yield)
         (let loop ((state seed))
           (if (stop? state)
               (unspecified)
               (begin
                 (yield (mapper state))
                 (loop (successor state)))))))))

    ;; Prefix ITEM values before delegating to the final generator.
    (define gcons* (lambda args
      (lambda ()
        (cond
         ((null? args) (eof-object))
         ((null? (cdr args)) ((car args)))
         (else
          (let ((value (car args)))
            (set! args (cdr args))
            value))))))

    ;; Append generators, yielding from each until it is exhausted.
    (define gappend (lambda generators
      (lambda ()
        (let loop ()
          (if (null? generators)
              (eof-object)
              (let ((value ((car generators))))
                (if (eof-object? value)
                    (begin
                      (set! generators (cdr generators))
                      (loop))
                    value)))))))

    ;; Flatten lists produced by GEN into one stream of values.
    (define gflatten (lambda (gen)
      (let ((state '()))
        (lambda ()
          (when (null? state)
            (set! state (gen)))
          (if (eof-object? state)
              state
              (let ((obj (car state)))
                (set! state (cdr state))
                obj))))))

    ;; Group values from GEN into lists of K values.
    (define ggroup
      (case-lambda
        ((gen k)
         (simple-ggroup gen k))
        ((gen k padding)
         (padded-ggroup (simple-ggroup gen k) k padding))))

    ;; Group values without padding the final group.
    (define simple-ggroup (lambda (gen k)
      (lambda ()
        (let loop ((item (gen)) (result '()) (count (- k 1)))
          (cond
           ((eof-object? item)
            (if (null? result) item (reverse result)))
           ((= count 0)
            (reverse (cons item result)))
           (else
            (loop (gen) (cons item result) (- count 1))))))))

    ;; Pad short groups from GEN to length K.
    (define padded-ggroup (lambda (gen k padding)
      (lambda ()
        (let ((item (gen)))
          (if (eof-object? item)
              item
              (let ((len (length item)))
                (if (= len k)
                    item
                    (append item (make-list (- k len) padding)))))))))

    ;; Merge sorted generators using LESS-THAN.
    (define gmerge
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
                                merged)))))))))

    ;; Map PROC over one or more generators without consuming them eagerly.
    (define gmap
      (case-lambda
        ((proc)
         (error "wrong number of arguments for gmap" proc))
        ((proc gen)
         (lambda ()
           (let ((item (gen)))
             (if (eof-object? item) item (proc item)))))
        ((proc . generators)
         (lambda ()
           (let ((items (map (lambda (gen) (gen)) generators)))
             (if (any eof-object? items)
                 (eof-object)
                 (apply proc items)))))))

    ;; Map with state over one or more generators.
    (define gcombine (lambda (proc seed . generators)
      (lambda ()
        (let ((items (map (lambda (gen) (gen)) generators)))
          (if (any eof-object? items)
              (eof-object)
              (call-with-values
               (lambda () (apply proc (append items (list seed))))
               (lambda (value new-seed)
                 (set! seed new-seed)
                 value)))))))

    ;; Yield only values from GEN that satisfy PRED.
    (define gfilter (lambda (pred gen)
      (lambda ()
        (let loop ()
          (let ((next (gen)))
            (if (or (eof-object? next) (pred next))
                next
                (loop)))))))

    ;; Yield only values selected by PROC while threading state.
    (define gstate-filter (lambda (proc seed gen)
      (let ((state seed))
        (lambda ()
          (let loop ((item (gen)))
            (if (eof-object? item)
                item
                (call-with-values
                 (lambda () (proc item state))
                 (lambda (yes new-state)
                   (set! state new-state)
                   (if yes item (loop (gen)))))))))))

    ;; Yield only values from GEN that do not satisfy PRED.
    (define gremove (lambda (pred gen)
      (gfilter (lambda (value) (not (pred value))) gen)))

    ;; Take at most K values from GEN.
    (define gtake
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
                     (if (eof-object? value) padding value)))))))))

    ;; Drop K values from GEN before yielding.
    (define gdrop (lambda (gen k)
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
          (gen)))))

    ;; Yield values while PRED remains true.
    (define gtake-while (lambda (pred gen)
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
                  (eof-object)))))))))

    ;; Drop values while PRED remains true, then yield the rest.
    (define gdrop-while (lambda (pred gen)
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
                value))))))))

    ;; Delete values equal to ITEM from GEN.
    (define gdelete
      (case-lambda
        ((item gen)
         (gdelete item gen equal?))
        ((item gen equal)
         (lambda ()
           (let loop ((value (gen)))
             (cond
              ((eof-object? value) value)
              ((equal item value) (loop (gen)))
              (else value)))))))

    ;; Delete neighboring duplicate values from GEN.
    (define gdelete-neighbor-dups
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
                     value)))))))))

    ;; Select values from VALUE-GEN at strictly increasing indices.
    (define gindex (lambda (value-gen index-gen)
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
                      (loop (value-gen)))))))))))))

    ;; Select values whose paired truth generator value is true.
    (define gselect (lambda (value-gen truth-gen)
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
                 (else (loop (value-gen) (truth-gen))))))))))

    ;; Consume GEN into a list, optionally bounded by K.
    (define generator->list
      (case-lambda
        ((gen)
         (reverse (generator->reverse-list gen)))
        ((gen k)
         (generator->list (gtake gen k)))))

    ;; Consume GEN into a reverse-order list, optionally bounded by K.
    (define generator->reverse-list
      (case-lambda
        ((gen)
         (generator-fold cons '() gen))
        ((gen k)
         (generator->reverse-list (gtake gen k)))))

    ;; Consume GEN into a vector, optionally bounded by K.
    (define generator->vector
      (case-lambda
        ((gen)
         (list->vector (generator->list gen)))
        ((gen k)
         (list->vector (generator->list gen k)))))

    ;; Fill VECTOR with values from GEN starting at AT.
    (define generator->vector! (lambda (vector at gen)
      (let loop ((value (gen)) (count 0) (index at))
        (cond
         ((eof-object? value) count)
         ((>= index (vector-length vector)) count)
         (else
          (vector-set! vector index value)
          (loop (gen) (+ count 1) (+ index 1)))))))

    ;; Consume GEN into a string, optionally bounded by K.
    (define generator->string
      (case-lambda
        ((gen)
         (list->string (generator->list gen)))
        ((gen k)
         (list->string (generator->list gen k)))))

    ;; Fold over one or more generators.
    (define generator-fold (lambda (proc seed . generators)
      (let loop ((state seed))
        (let ((values (map (lambda (gen) (gen)) generators)))
          (if (any eof-object? values)
              state
              (loop (apply proc (append values (list state)))))))))

    ;; Apply PROC for side effects over one or more generators.
    (define generator-for-each (lambda (proc . generators)
      (let loop ()
        (let ((values (map (lambda (gen) (gen)) generators)))
          (if (any eof-object? values)
              (unspecified)
              (begin
                (apply proc values)
                (loop)))))))

    ;; Map PROC over one or more generators and return a list.
    (define generator-map->list (lambda (proc . generators)
      (let loop ((result '()))
        (let ((values (map (lambda (gen) (gen)) generators)))
          (if (any eof-object? values)
              (reverse result)
              (loop (cons (apply proc values) result)))))))

    ;; Return the first value from GEN satisfying PRED, or #f.
    (define generator-find (lambda (pred gen)
      (let loop ((value (gen)))
        (cond
         ((eof-object? value) #f)
         ((pred value) value)
         (else (loop (gen)))))))

    ;; Count values from GEN satisfying PRED.
    (define generator-count (lambda (pred gen)
      (generator-fold
       (lambda (value count)
         (if (pred value) (+ count 1) count))
       0
       gen)))

    ;; Return the first true PRED result over GEN, or #f.
    (define generator-any (lambda (pred gen)
      (let loop ((item (gen)))
        (cond
         ((eof-object? item) #f)
         ((pred item))
         (else (loop (gen)))))))

    ;; Return the last true PRED result over GEN, or the first false result.
    (define generator-every (lambda (pred gen)
      (let loop ((item (gen)) (last #t))
        (if (eof-object? item)
            last
            (let ((result (pred item)))
              (if result
                  (loop (gen) result)
                  #f))))))

    ;; Unfold values from GEN with an SRFI 1 style UNFOLD procedure.
    (define generator-unfold (lambda (gen unfold . args)
      (apply unfold eof-object? (lambda (value) value)
             (lambda (value) (gen)) (gen) args)))

    ;; Build an accumulator from a folding procedure and finalizer.
    (define make-accumulator (lambda (kons knil finalizer)
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
                    (unspecified))))))))

    ;; Count accumulated values.
    (define count-accumulator (lambda ()
      (make-accumulator
       (lambda (obj state)
         obj
         (+ state 1))
       0
       (lambda (state) state))))

    ;; Accumulate values into a list in arrival order.
    (define list-accumulator (lambda ()
      (make-accumulator cons '() reverse)))

    ;; Accumulate values into a list in reverse arrival order.
    (define reverse-list-accumulator (lambda ()
      (make-accumulator cons '() (lambda (state) state))))

    ;; Accumulate values into a vector in arrival order.
    (define vector-accumulator (lambda ()
      (make-accumulator
       cons
       '()
       (lambda (state) (list->vector (reverse state))))))

    ;; Accumulate values into a vector in reverse arrival order.
    (define reverse-vector-accumulator (lambda ()
      (make-accumulator cons '() list->vector)))

    ;; Accumulate values into VECTOR starting at AT.
    (define vector-accumulator! (lambda (vector at)
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
                    (unspecified))))))))

    ;; Accumulate characters into a string.
    (define string-accumulator (lambda ()
      (make-accumulator
       cons
       '()
       (lambda (state) (list->string (reverse state))))))

    ;; Accumulate bytes into a bytevector.
    (define bytevector-accumulator (lambda ()
      (make-accumulator
       cons
       '()
       (lambda (state) (list->bytevector (reverse state))))))

    ;; Accumulate bytes into BYTEVECTOR starting at AT.
    (define bytevector-accumulator! (lambda (bytevector at)
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
                    (unspecified))))))))

    ;; Accumulate numbers into a sum.
    (define sum-accumulator (lambda ()
      (make-accumulator + 0 (lambda (state) state))))

    ;; Accumulate numbers into a product.
    (define product-accumulator (lambda ()
      (make-accumulator * 1 (lambda (state) state))))))
