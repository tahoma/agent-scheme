;;; Portable SRFI 158 generator stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2015 Shiro Kawai, John Cowan, Thomas Gilray
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 158 `chicken-test.scm` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-158.

(import (scheme base)
        (scheme write)
        (stdlib generator)
        (only (stdlib list) unfold)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (check-generator-list name gen expected)
  "Compare the values yielded by GEN to EXPECTED."
  (test-equal name expected (generator->list gen)))

(define (raises? thunk)
  "Return #t when THUNK raises an exception."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(testing-registry-case
 'generator/empty '(portable stdlib)
(check-generator-list 'generator/empty
                      (generator)
                      '()))

(testing-registry-case
 'generator/finite '(portable stdlib)
(check-generator-list 'generator/finite
                      (generator 1 2 3)
                      '(1 2 3)))

(testing-registry-case
 'generator/eof-idempotent '(portable stdlib)
(test-equal 'generator/eof-idempotent
             '(x #t #t)
             (let ((gen (generator 'x)))
               (let* ((first (gen))
                      (done? (eof-object? (gen)))
                      (still-done? (eof-object? (gen))))
                 (list first done? still-done?)))))

(testing-registry-case
 'circular-generator/prefix '(portable stdlib)
(test-equal 'circular-generator/prefix
             '(1 2 3 1 2)
             (generator->list (circular-generator 1 2 3) 5)))

(testing-registry-case
 'make-iota-generator/zero '(portable stdlib)
(check-generator-list 'make-iota-generator/zero
                      (make-iota-generator 0)
                      '()))

(testing-registry-case
 'make-iota-generator/count-start '(portable stdlib)
(check-generator-list 'make-iota-generator/count-start
                      (make-iota-generator 3 8)
                      '(8 9 10)))

(testing-registry-case
 'make-iota-generator/count-start-step '(portable stdlib)
(check-generator-list 'make-iota-generator/count-start-step
                      (make-iota-generator 3 8 2)
                      '(8 10 12)))

(testing-registry-case
 'make-range-generator/unbounded-prefix '(portable stdlib)
(test-equal 'make-range-generator/unbounded-prefix
             '(3 4 5 6)
             (generator->list (make-range-generator 3) 4)))

(testing-registry-case
 'make-range-generator/bounded '(portable stdlib)
(check-generator-list 'make-range-generator/bounded
                      (make-range-generator 3 8)
                      '(3 4 5 6 7)))

(testing-registry-case
 'make-range-generator/empty '(portable stdlib)
(check-generator-list 'make-range-generator/empty
                      (make-range-generator 3 3)
                      '()))

(testing-registry-case
 'make-range-generator/bounded-step '(portable stdlib)
(check-generator-list 'make-range-generator/bounded-step
                      (make-range-generator 3 8 2)
                      '(3 5 7)))

(testing-registry-case
 'make-coroutine-generator/simple-yields '(portable stdlib)
(check-generator-list
 'make-coroutine-generator/simple-yields
 (make-coroutine-generator
  (lambda (yield)
    (let loop ((i 0))
      (when (< i 3)
        (yield i)
        (loop (+ i 1))))))
 '(0 1 2)))

(testing-registry-case
 'make-coroutine-generator/eof-idempotent '(portable stdlib)
(test-equal 'make-coroutine-generator/eof-idempotent
             '(only #t #t)
             (let ((gen (make-coroutine-generator
                   (lambda (yield)
                     (yield 'only)))))
               (let* ((first (gen))
                      (done? (eof-object? (gen)))
                      (still-done? (eof-object? (gen))))
                 (list first done? still-done?)))))

(testing-registry-case
 'make-coroutine-generator/no-yields '(portable stdlib)
(test-equal 'make-coroutine-generator/no-yields
             '(#t #t)
             (let ((gen (make-coroutine-generator
                   (lambda (yield)
                     yield
                     #t))))
         (list (eof-object? (gen)) (eof-object? (gen))))))

(testing-registry-case
 'list->generator '(portable stdlib)
(check-generator-list 'list->generator
                      (list->generator '(1 2 3 4 5))
                      '(1 2 3 4 5)))

(testing-registry-case
 'vector->generator '(portable stdlib)
(check-generator-list 'vector->generator
                      (vector->generator '#(1 2 3 4 5))
                      '(1 2 3 4 5)))

(testing-registry-case
 'vector->generator/slice '(portable stdlib)
(check-generator-list 'vector->generator/slice
                      (vector->generator '#(0 1 2 3 4 5) 2 5)
                      '(2 3 4)))

(testing-registry-case
 'reverse-vector->generator '(portable stdlib)
(check-generator-list 'reverse-vector->generator
                      (reverse-vector->generator '#(1 2 3 4 5))
                      '(5 4 3 2 1)))

(testing-registry-case
 'reverse-vector->generator/slice '(portable stdlib)
(check-generator-list 'reverse-vector->generator/slice
                      (reverse-vector->generator '#(0 1 2 3 4 5) 1 5)
                      '(4 3 2 1)))

(testing-registry-case
 'string->generator '(portable stdlib)
(check-generator-list 'string->generator
                      (string->generator "abcde")
                      '(#\a #\b #\c #\d #\e)))

(testing-registry-case
 'string->generator/slice '(portable stdlib)
(check-generator-list 'string->generator/slice
                      (string->generator "abcdef" 2 5)
                      '(#\c #\d #\e)))

(testing-registry-case
 'bytevector->generator '(portable stdlib)
(check-generator-list 'bytevector->generator
                      (bytevector->generator (bytevector 10 20 30))
                      '(10 20 30)))

(testing-registry-case
 'bytevector->generator/slice '(portable stdlib)
(check-generator-list 'bytevector->generator/slice
                      (bytevector->generator (bytevector 0 10 20 30 40) 1 4)
                      '(10 20 30)))

(testing-registry-case
 'make-unfold-generator '(portable stdlib)
(check-generator-list
 'make-unfold-generator
 (make-unfold-generator
  (lambda (seed) (> seed 5))
  (lambda (seed) (* seed 2))
  (lambda (seed) (+ seed 1))
  0)
 '(0 2 4 6 8 10)))

(testing-registry-case
 'gcons* '(portable stdlib)
(check-generator-list 'gcons*
                      (gcons* 'a 'b (make-range-generator 0 2))
                      '(a b 0 1)))

(testing-registry-case
 'gappend '(portable stdlib)
(check-generator-list 'gappend
                      (gappend (make-range-generator 0 3)
                               (make-range-generator 0 2))
                      '(0 1 2 0 1)))

(testing-registry-case
 'parallel-generators/pull-left-to-right '(portable stdlib)
(test-equal 'parallel-generators/pull-left-to-right
             '((1 3) (2 4) (left right left right))
             (let ((log '()))
         (define (note item)
           (set! log (cons item log)))
         (define (logging-generator name values)
           (let ((rest values))
             (lambda ()
               (note name)
               (if (null? rest)
                   (eof-object)
                   (let ((next (car rest)))
                     (set! rest (cdr rest))
                     next)))))
         (let ((mapped (gmap list
                             (logging-generator 'left '(1 2))
                             (logging-generator 'right '(3 4)))))
           (let* ((first (mapped))
                  (second (mapped)))
             (list first second (reverse log)))))))

(testing-registry-case
 'gcombine '(portable stdlib)
(check-generator-list
 'gcombine
 (gcombine
  (lambda args (values (apply + args) (apply + args)))
  10
  (generator 1 2 3)
  (generator 4 5 6 7))
 '(15 22 31)))

(testing-registry-case
 'gcombine/stops-before-pulling-later-generator '(portable stdlib)
(test-equal 'gcombine/stops-before-pulling-later-generator
             '(((1 10 seed)) (20))
             (let ((short (generator 1))
                   (long (generator 10 20)))
               (let* ((combined
                       (generator->list
                        (gcombine
                         (lambda (left right state)
                           (values (list left right state) state))
                         'seed
                         short
                         long)))
                      (remainder (generator->list long)))
                 (list combined remainder)))))

(testing-registry-case
 'gfilter '(portable stdlib)
(check-generator-list 'gfilter
                      (gfilter odd? (make-range-generator 1 11))
                      '(1 3 5 7 9)))

(testing-registry-case
 'gremove '(portable stdlib)
(check-generator-list 'gremove
                      (gremove odd? (make-range-generator 1 11))
                      '(2 4 6 8 10)))

(testing-registry-case
 'gtake/source-remainder '(portable stdlib)
(test-equal 'gtake/source-remainder
             '((1 2 3) (4))
             (let ((source (make-range-generator 1 5)))
               (let* ((taken (generator->list (gtake source 3)))
                      (remainder (generator->list source)))
                 (list taken remainder)))))

(testing-registry-case
 'gtake/zero-does-not-consume '(portable stdlib)
(test-equal 'gtake/zero-does-not-consume
             '(() (1 2 3))
             (let ((source (make-range-generator 1 4)))
               (let* ((taken (generator->list (gtake source 0)))
                      (remainder (generator->list source)))
                 (list taken remainder)))))

(testing-registry-case
 'gtake/padded '(portable stdlib)
(check-generator-list 'gtake/padded
                      (gtake (make-range-generator 1 3) 3 0)
                      '(1 2 0)))

(testing-registry-case
 'gdrop '(portable stdlib)
(check-generator-list 'gdrop
                      (gdrop (make-range-generator 1 5) 2)
                      '(3 4)))

(testing-registry-case
 'gdrop/past-end '(portable stdlib)
(check-generator-list 'gdrop/past-end
                      (gdrop (generator 'a 'b) 5)
                      '()))

(testing-registry-case
 'gtake-while '(portable stdlib)
(check-generator-list 'gtake-while
                      (gtake-while (lambda (value) (< value 3))
                                   (make-range-generator 1 5))
                      '(1 2)))

(testing-registry-case
 'gtake-while/consumes-failing-value '(portable stdlib)
(test-equal 'gtake-while/consumes-failing-value
             '((1 2) (4))
             (let ((source (make-range-generator 1 5)))
               (let* ((taken
                       (generator->list
                        (gtake-while (lambda (value) (< value 3)) source)))
                      (remainder (generator->list source)))
                 (list taken remainder)))))

(testing-registry-case
 'gdrop-while '(portable stdlib)
(check-generator-list 'gdrop-while
                      (gdrop-while (lambda (value) (< value 3))
                                   (make-range-generator 1 5))
                      '(3 4)))

(testing-registry-case
 'gdelete/custom-equal '(portable stdlib)
(check-generator-list 'gdelete/custom-equal
                      (gdelete 1 (generator 0.0 1.0 0 1 2) =)
                      '(0.0 0 2)))

(testing-registry-case
 'gdelete-neighbor-dups/custom-equal '(portable stdlib)
(check-generator-list 'gdelete-neighbor-dups/custom-equal
                      (gdelete-neighbor-dups (generator 1 1 2 3 3 3) =)
                      '(1 2 3)))

(testing-registry-case
 'gflatten '(portable stdlib)
(check-generator-list 'gflatten
                      (gflatten (generator '(1 2 3) '(a b c)))
                      '(1 2 3 a b c)))

(testing-registry-case
 'gflatten/skips-empty-lists '(portable stdlib)
(check-generator-list 'gflatten/skips-empty-lists
                      (gflatten (generator '() '(a b) '() '(c)))
                      '(a b c)))

(testing-registry-case
 'ggroup '(portable stdlib)
(check-generator-list 'ggroup
                      (ggroup (generator 1 2 3 4 5 6 7 8) 3)
                      '((1 2 3) (4 5 6) (7 8))))

(testing-registry-case
 'ggroup/empty '(portable stdlib)
(check-generator-list 'ggroup/empty
                      (ggroup (generator) 3)
                      '()))

(testing-registry-case
 'ggroup/padded '(portable stdlib)
(check-generator-list 'ggroup/padded
                      (ggroup (generator 1 2 3 4 5 6 7 8) 3 0)
                      '((1 2 3) (4 5 6) (7 8 0))))

(testing-registry-case
 'gmerge '(portable stdlib)
(check-generator-list 'gmerge
                      (gmerge < (generator 1 2 4 6)
                              (generator)
                              (generator 3 4 5))
                      '(1 2 3 4 4 5 6)))

(testing-registry-case
 'gmap '(portable stdlib)
(check-generator-list 'gmap
                      (gmap * (generator 1 2 3)
                            (generator 6 7 8)
                            (generator 9 10 11 12))
                      '(54 140 264)))

(testing-registry-case
 'gmap/stops-before-pulling-later-generator '(portable stdlib)
(test-equal 'gmap/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
                   (long (generator 'b 'c)))
               (let* ((mapped (generator->list (gmap list short long)))
                      (remainder (generator->list long)))
                 (list mapped remainder)))))

(testing-registry-case
 'gstate-filter '(portable stdlib)
(check-generator-list
 'gstate-filter
 (gstate-filter
  (lambda (item state) (values (even? state) (+ 1 state)))
  0
  (generator 'a 'b 'c 'd 'e))
 '(a c e)))

(testing-registry-case
 'gindex '(portable stdlib)
(check-generator-list 'gindex
                      (gindex (list->generator '(a b c d e f))
                              (list->generator '(0 2 4)))
                      '(a c e)))

(testing-registry-case
 'gselect '(portable stdlib)
(check-generator-list 'gselect
                      (gselect (list->generator '(a b c d e f))
                               (list->generator '(#t #f #f #t #t #f)))
                      '(a d e)))

(testing-registry-case
 'error-cases '(portable stdlib)
(test-equal 'error-cases
             '(#t #t #t #t #t #t #t)
             (list (raises? (lambda () (gtake (generator) -1)))
             (raises? (lambda () (gdrop (generator) -1)))
             (raises? (lambda () (gmerge <)))
             (raises? (lambda () (gmap values)))
             (raises? (lambda ()
                        ((gindex (generator 'a)
                                 (generator 'not-an-index)))))
             (raises? (lambda ()
                        ((gindex (generator 'a)
                                 (generator -1)))))
             (raises? (lambda ()
                        (generator->list
                         (gindex (generator 'a 'b)
                                 (generator 1 1))))))))

(testing-registry-case
 'generator->list/bounded '(portable stdlib)
(test-equal 'generator->list/bounded
             '(1 2 3)
             (generator->list (generator 1 2 3 4 5) 3)))

(testing-registry-case
 'generator->reverse-list '(portable stdlib)
(test-equal 'generator->reverse-list
             '(5 4 3 2 1)
             (generator->reverse-list (generator 1 2 3 4 5))))

(testing-registry-case
 'generator->vector '(portable stdlib)
(test-equal 'generator->vector
             #(1 2 3 4 5)
             (generator->vector (generator 1 2 3 4 5))))

(testing-registry-case
 'generator->vector/bounded '(portable stdlib)
(test-equal 'generator->vector/bounded
             #(1 2 3)
             (generator->vector (generator 1 2 3 4 5) 3)))

(testing-registry-case
 'generator->vector!/count '(portable stdlib)
(let ((vector-target (make-vector 5 0)))
  (test-equal 'generator->vector!/count
             3
             (generator->vector! vector-target 2 (generator 1 2 4)))
  (test-equal 'generator->vector!/target
             #(0 0 1 2 4)
             vector-target)))

(testing-registry-case
 'generator->vector!/does-not-overconsume '(portable stdlib)
(test-equal 'generator->vector!/does-not-overconsume
             (list 1 #(0 10) '(20 30))
             (let ((source (generator 10 20 30))
                   (target (vector 0 0)))
               (let* ((count (generator->vector! target 1 source))
                      (remainder (generator->list source)))
                 (list count target remainder)))))

(testing-registry-case
 'generator->string '(portable stdlib)
(test-equal 'generator->string
             "abc"
             (generator->string (generator #\a #\b #\c))))

(testing-registry-case
 'generator-fold '(portable stdlib)
(test-equal 'generator-fold
             '(e d c b a . z)
             (generator-fold cons 'z (generator 'a 'b 'c 'd 'e))))

(testing-registry-case
 'generator-fold/single-generator-pull-count
 '(portable stdlib performance)
(test-equal
 'generator-fold/single-generator-pull-count
 '(6 4)
 (let ((next 1) (pulls 0))
   (define (source)
     "Return three integers, counting the final EOF probe."
     (set! pulls (+ pulls 1))
     (if (> next 3)
         (eof-object)
         (let ((value next))
           (set! next (+ next 1))
           value)))
   (let ((sum (generator-fold + 0 source)))
     (list sum pulls)))))

(testing-registry-case
 'generator->list/bounded-pull-count
 '(portable stdlib performance)
(test-equal
 'generator->list/bounded-pull-count
 '((1 2) 2 3 3)
 (let ((next 1) (pulls 0))
   (define (source)
     "Return increasing integers while counting source pulls."
     (set! pulls (+ pulls 1))
     (let ((value next))
       (set! next (+ next 1))
       value))
   (let ((result (generator->list source 2)))
     (let ((pulls-after-result pulls))
       (let ((next-value (source)))
         (list result pulls-after-result next-value pulls)))))))

(testing-registry-case
 'generator-fold/large-range '(portable stdlib)
(test-equal 'generator-fold/large-range
             99990000
             (generator-fold + 0
                       (gmap (lambda (value) (* value 2))
                             (make-range-generator 0 10000)))))

(testing-registry-case
 'generator-fold/stops-before-pulling-later-generator '(portable stdlib)
(test-equal 'generator-fold/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
                   (long (generator 'b 'c)))
               (let* ((folded
                       (generator-fold
                        (lambda (left right state)
                          (cons (list left right) state))
                        '()
                        short
                        long))
                      (remainder (generator->list long)))
                 (list folded remainder)))))

(testing-registry-case
 'generator-for-each '(portable stdlib)
(test-equal 'generator-for-each
             6
             (let ((n 0))
         (generator-for-each
          (lambda values (set! n (apply + values)))
          (generator 1)
          (generator 2)
          (generator 3))
         n)))

(testing-registry-case
 'generator-for-each/single-generator-order
 '(portable stdlib performance)
(test-equal
 'generator-for-each/single-generator-order
 '((a b c) 4 1)
 (let ((items '(a b c))
       (pulls 0)
       (seen '()))
   (define (source)
     "Return the next item while counting the final EOF probe."
     (set! pulls (+ pulls 1))
     (if (null? items)
         (eof-object)
         (let ((value (car items)))
           (set! items (cdr items))
           value)))
   (let ((returned-count
          (call-with-values
           (lambda ()
             (generator-for-each
              (lambda (value)
                (set! seen (cons value seen))
                (eof-object))
              source))
           (lambda returned (length returned)))))
     (list (reverse seen) pulls returned-count)))))

(testing-registry-case
 'generator-for-each/stops-before-pulling-later-generator '(portable stdlib)
(test-equal 'generator-for-each/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
             (long (generator 'b 'c))
             (seen '()))
         (generator-for-each
          (lambda (left right)
            (set! seen (cons (list left right) seen)))
          short
          long)
         (list (reverse seen) (generator->list long)))))

(testing-registry-case
 'generator-for-each/multiple-generator-route '(portable stdlib)
(test-equal
 'generator-for-each/multiple-generator-route
 '((left right (proc a x) left right (proc b y) left) (z))
 (let ((left-items '(a b))
       (right-items '(x y z))
       (events '()))
   (define (left)
     "Return the next left item while recording each pull."
     (set! events (cons 'left events))
     (if (null? left-items)
         (eof-object)
         (let ((value (car left-items)))
           (set! left-items (cdr left-items))
           value)))
   (define (right)
     "Return the next right item while recording each pull."
     (set! events (cons 'right events))
     (if (null? right-items)
         (eof-object)
         (let ((value (car right-items)))
           (set! right-items (cdr right-items))
           value)))
   (generator-for-each
    (lambda (left-value right-value)
      (set! events
            (cons (list 'proc left-value right-value) events)))
    left
    right)
   (list (reverse events) right-items))))

(testing-registry-case
 'generator-map->list '(portable stdlib)
(test-equal 'generator-map->list
             '(6 15)
             (generator-map->list
        (lambda values (apply + values))
        (generator 1 4)
        (generator 2 5)
        (generator 3 6))))

(testing-registry-case
 'generator-map->list/single-generator-order
 '(portable stdlib performance)
(test-equal
 'generator-map->list/single-generator-order
 '((10 20 30) (1 2 3) 4)
 (let ((items '(1 2 3))
       (pulls 0)
       (seen '()))
   (define (source)
     "Return the next item while counting the final EOF probe."
     (set! pulls (+ pulls 1))
     (if (null? items)
         (eof-object)
         (let ((value (car items)))
           (set! items (cdr items))
           value)))
   (let ((result
          (generator-map->list
           (lambda (value)
             (set! seen (cons value seen))
             (* value 10))
           source)))
     (list result (reverse seen) pulls)))))

(testing-registry-case
 'generator-map->list/stops-before-pulling-later-generator '(portable stdlib)
(test-equal 'generator-map->list/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
                   (long (generator 'b 'c)))
               (let* ((mapped (generator-map->list list short long))
                      (remainder (generator->list long)))
                 (list mapped remainder)))))

(testing-registry-case
 'generator-map->list/multiple-generator-route '(portable stdlib)
(test-equal
 'generator-map->list/multiple-generator-route
 '(((a x) (b y))
   (left right map left right map left)
   (z))
 (let ((left-items '(a b))
       (right-items '(x y z))
       (events '()))
   (define (left)
     "Return the next left item while recording each pull."
     (set! events (cons 'left events))
     (if (null? left-items)
         (eof-object)
         (let ((value (car left-items)))
           (set! left-items (cdr left-items))
           value)))
   (define (right)
     "Return the next right item while recording each pull."
     (set! events (cons 'right events))
     (if (null? right-items)
         (eof-object)
         (let ((value (car right-items)))
           (set! right-items (cdr right-items))
           value)))
   (let ((result
          (generator-map->list
           (lambda (left-value right-value)
             (set! events (cons 'map events))
             (list left-value right-value))
           left
           right)))
     (list result (reverse events) right-items)))))

(testing-registry-case
 'generator-find/match '(portable stdlib)
(test-equal 'generator-find/match
             3
             (generator-find (lambda (x) (> x 2))
                       (make-range-generator 1 5))))

(testing-registry-case
 'generator-find/no-match '(portable stdlib)
(test-equal 'generator-find/no-match
             #f
             (generator-find (lambda (x) (> x 10))
                       (make-range-generator 1 5))))

(testing-registry-case
 'generator-count '(portable stdlib)
(test-equal 'generator-count
             2
             (generator-count odd? (make-range-generator 1 5))))

(testing-registry-case
 'generator-any/source-remainder '(portable stdlib)
(test-equal 'generator-any/source-remainder
             '(#t (4))
             (let ((source (make-range-generator 2 5)))
               (let* ((result (generator-any odd? source))
                      (remainder (generator->list source)))
                 (list result remainder)))))

(testing-registry-case
 'generator-every/false-source-remainder '(portable stdlib)
(test-equal 'generator-every/false-source-remainder
             '(#f (3 4))
             (let ((source (make-range-generator 2 5)))
               (let* ((result (generator-every odd? source))
                      (remainder (generator->list source)))
                 (list result remainder)))))

(testing-registry-case
 'generator-every/last-true '(portable stdlib)
(test-equal 'generator-every/last-true
             '(4 ())
             (let ((source (make-range-generator 2 5)))
               (let* ((result
                       (generator-every
                        (lambda (x) (and (> x 1) x))
                        source))
                      (remainder (generator->list source)))
                 (list result remainder)))))

(testing-registry-case
 'generator-unfold '(portable stdlib)
(test-equal 'generator-unfold
             '(#\a #\b #\c)
             (generator-unfold
        (make-for-each-generator string-for-each "abc")
        unfold)))

(testing-registry-case
 'make-accumulator '(portable stdlib)
(test-equal 'make-accumulator
             -8
             (let ((acc (make-accumulator * 1 -)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'count-accumulator '(portable stdlib)
(test-equal 'count-accumulator
             3
             (let ((acc (count-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'count-accumulator/empty '(portable stdlib)
(test-equal 'count-accumulator/empty
             0
             (let ((acc (count-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'list-accumulator '(portable stdlib)
(test-equal 'list-accumulator
             '(1 2 4)
             (let ((acc (list-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'list-accumulator/empty '(portable stdlib)
(test-equal 'list-accumulator/empty
             '()
             (let ((acc (list-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'reverse-list-accumulator '(portable stdlib)
(test-equal 'reverse-list-accumulator
             '(4 2 1)
             (let ((acc (reverse-list-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'vector-accumulator '(portable stdlib)
(test-equal 'vector-accumulator
             #(1 2 4)
             (let ((acc (vector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'vector-accumulator/empty '(portable stdlib)
(test-equal 'vector-accumulator/empty
             #()
             (let ((acc (vector-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'reverse-vector-accumulator '(portable stdlib)
(test-equal 'reverse-vector-accumulator
             #(4 2 1)
             (let ((acc (reverse-vector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'vector-accumulator! '(portable stdlib)
(test-equal 'vector-accumulator!
             #(0 0 1 2 4)
             (let* ((target (vector 0 0 0 0 0))
              (acc (vector-accumulator! target 2)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'string-accumulator '(portable stdlib)
(test-equal 'string-accumulator
             "abc"
             (let ((acc (string-accumulator)))
         (acc #\a)
         (acc #\b)
         (acc #\c)
         (acc (eof-object)))))

(testing-registry-case
 'string-accumulator/empty '(portable stdlib)
(test-equal 'string-accumulator/empty
             ""
             (let ((acc (string-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'bytevector-accumulator '(portable stdlib)
(test-equal 'bytevector-accumulator
             (bytevector 1 2 4)
             (let ((acc (bytevector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'bytevector-accumulator/empty '(portable stdlib)
(test-equal 'bytevector-accumulator/empty
             (bytevector)
             (let ((acc (bytevector-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'bytevector-accumulator! '(portable stdlib)
(test-equal 'bytevector-accumulator!
             (bytevector 0 0 1 2 4)
             (let* ((target (bytevector 0 0 0 0 0))
              (acc (bytevector-accumulator! target 2)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'sum-accumulator '(portable stdlib)
(test-equal 'sum-accumulator
             7
             (let ((acc (sum-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'sum-accumulator/empty '(portable stdlib)
(test-equal 'sum-accumulator/empty
             0
             (let ((acc (sum-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'product-accumulator '(portable stdlib)
(test-equal 'product-accumulator
             8
             (let ((acc (product-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'product-accumulator/empty '(portable stdlib)
(test-equal 'product-accumulator/empty
             1
             (let ((acc (product-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'accumulators/reject-post-finalization-writes '(portable stdlib)
(test-equal 'accumulators/reject-post-finalization-writes
             '(#t #t #t #t #t #t #t #t #t #t)
             (let ((generic (make-accumulator cons '() (lambda (state) state)))
             (count (count-accumulator))
             (list-acc (list-accumulator))
             (vector-acc (vector-accumulator))
             (vector-write (vector-accumulator! (vector 0) 0))
             (string-acc (string-accumulator))
             (bytevector-acc (bytevector-accumulator))
             (bytevector-write (bytevector-accumulator! (bytevector 0) 0))
             (sum (sum-accumulator))
             (product (product-accumulator)))
         (for-each
          (lambda (acc) (acc (eof-object)))
          (list generic count list-acc vector-acc vector-write string-acc
                bytevector-acc bytevector-write sum product))
         (map (lambda (acc)
                (raises? (lambda () (acc 'after-eof))))
              (list generic count list-acc vector-acc vector-write string-acc
                    bytevector-acc bytevector-write sum product)))))

(testing-registry-case
 'flexvector-backed-vector-collectors/long-input '(portable stdlib stress)
(test-equal
 'flexvector-backed-vector-collectors/long-input
 '(10000 0 9999 10000 0 9999 9999 0)
 (let ((generated (generator->vector (make-iota-generator 10000)))
       (forward (vector-accumulator))
       (backward (reverse-vector-accumulator)))
   (let loop ((index 0))
     (if (< index 10000)
         (begin
           (forward index)
           (backward index)
           (loop (+ index 1)))))
   (let ((forward-vector (forward (eof-object)))
         (backward-vector (backward (eof-object))))
     (list (vector-length generated)
           (vector-ref generated 0)
           (vector-ref generated 9999)
           (vector-length forward-vector)
           (vector-ref forward-vector 0)
           (vector-ref forward-vector 9999)
           (vector-ref backward-vector 0)
           (vector-ref backward-vector 9999))))))

(testing-runner-main "Stdlib Generator portable tests" (command-line))
