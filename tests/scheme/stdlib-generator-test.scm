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
 ("stdlib-generator-test.scm" 29)
(check-generator-list 'generator/empty
                      (generator)
                      '()))

(testing-registry-case
 'generator/finite '(portable stdlib)
 ("stdlib-generator-test.scm" 36)
(check-generator-list 'generator/finite
                      (generator 1 2 3)
                      '(1 2 3)))

(testing-registry-case
 'generator/eof-idempotent '(portable stdlib)
 ("stdlib-generator-test.scm" 43)
(test-equal 'generator/eof-idempotent
             '(x #t #t)
             (let ((gen (generator 'x)))
         (list (gen) (eof-object? (gen)) (eof-object? (gen))))))

(testing-registry-case
 'circular-generator/prefix '(portable stdlib)
 ("stdlib-generator-test.scm" 51)
(test-equal 'circular-generator/prefix
             '(1 2 3 1 2)
             (generator->list (circular-generator 1 2 3) 5)))

(testing-registry-case
 'make-iota-generator/zero '(portable stdlib)
 ("stdlib-generator-test.scm" 58)
(check-generator-list 'make-iota-generator/zero
                      (make-iota-generator 0)
                      '()))

(testing-registry-case
 'make-iota-generator/count-start '(portable stdlib)
 ("stdlib-generator-test.scm" 65)
(check-generator-list 'make-iota-generator/count-start
                      (make-iota-generator 3 8)
                      '(8 9 10)))

(testing-registry-case
 'make-iota-generator/count-start-step '(portable stdlib)
 ("stdlib-generator-test.scm" 72)
(check-generator-list 'make-iota-generator/count-start-step
                      (make-iota-generator 3 8 2)
                      '(8 10 12)))

(testing-registry-case
 'make-range-generator/unbounded-prefix '(portable stdlib)
 ("stdlib-generator-test.scm" 79)
(test-equal 'make-range-generator/unbounded-prefix
             '(3 4 5 6)
             (generator->list (make-range-generator 3) 4)))

(testing-registry-case
 'make-range-generator/bounded '(portable stdlib)
 ("stdlib-generator-test.scm" 86)
(check-generator-list 'make-range-generator/bounded
                      (make-range-generator 3 8)
                      '(3 4 5 6 7)))

(testing-registry-case
 'make-range-generator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 93)
(check-generator-list 'make-range-generator/empty
                      (make-range-generator 3 3)
                      '()))

(testing-registry-case
 'make-range-generator/bounded-step '(portable stdlib)
 ("stdlib-generator-test.scm" 100)
(check-generator-list 'make-range-generator/bounded-step
                      (make-range-generator 3 8 2)
                      '(3 5 7)))

(testing-registry-case
 'make-coroutine-generator/simple-yields '(portable stdlib)
 ("stdlib-generator-test.scm" 107)
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
 ("stdlib-generator-test.scm" 120)
(test-equal 'make-coroutine-generator/eof-idempotent
             '(only #t #t)
             (let ((gen (make-coroutine-generator
                   (lambda (yield)
                     (yield 'only)))))
         (list (gen) (eof-object? (gen)) (eof-object? (gen))))))

(testing-registry-case
 'make-coroutine-generator/no-yields '(portable stdlib)
 ("stdlib-generator-test.scm" 130)
(test-equal 'make-coroutine-generator/no-yields
             '(#t #t)
             (let ((gen (make-coroutine-generator
                   (lambda (yield)
                     yield
                     #t))))
         (list (eof-object? (gen)) (eof-object? (gen))))))

(testing-registry-case
 'list->generator '(portable stdlib)
 ("stdlib-generator-test.scm" 141)
(check-generator-list 'list->generator
                      (list->generator '(1 2 3 4 5))
                      '(1 2 3 4 5)))

(testing-registry-case
 'vector->generator '(portable stdlib)
 ("stdlib-generator-test.scm" 148)
(check-generator-list 'vector->generator
                      (vector->generator '#(1 2 3 4 5))
                      '(1 2 3 4 5)))

(testing-registry-case
 'vector->generator/slice '(portable stdlib)
 ("stdlib-generator-test.scm" 155)
(check-generator-list 'vector->generator/slice
                      (vector->generator '#(0 1 2 3 4 5) 2 5)
                      '(2 3 4)))

(testing-registry-case
 'reverse-vector->generator '(portable stdlib)
 ("stdlib-generator-test.scm" 162)
(check-generator-list 'reverse-vector->generator
                      (reverse-vector->generator '#(1 2 3 4 5))
                      '(5 4 3 2 1)))

(testing-registry-case
 'reverse-vector->generator/slice '(portable stdlib)
 ("stdlib-generator-test.scm" 169)
(check-generator-list 'reverse-vector->generator/slice
                      (reverse-vector->generator '#(0 1 2 3 4 5) 1 5)
                      '(4 3 2 1)))

(testing-registry-case
 'string->generator '(portable stdlib)
 ("stdlib-generator-test.scm" 176)
(check-generator-list 'string->generator
                      (string->generator "abcde")
                      '(#\a #\b #\c #\d #\e)))

(testing-registry-case
 'string->generator/slice '(portable stdlib)
 ("stdlib-generator-test.scm" 183)
(check-generator-list 'string->generator/slice
                      (string->generator "abcdef" 2 5)
                      '(#\c #\d #\e)))

(testing-registry-case
 'bytevector->generator '(portable stdlib)
 ("stdlib-generator-test.scm" 190)
(check-generator-list 'bytevector->generator
                      (bytevector->generator (bytevector 10 20 30))
                      '(10 20 30)))

(testing-registry-case
 'bytevector->generator/slice '(portable stdlib)
 ("stdlib-generator-test.scm" 197)
(check-generator-list 'bytevector->generator/slice
                      (bytevector->generator (bytevector 0 10 20 30 40) 1 4)
                      '(10 20 30)))

(testing-registry-case
 'make-unfold-generator '(portable stdlib)
 ("stdlib-generator-test.scm" 204)
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
 ("stdlib-generator-test.scm" 216)
(check-generator-list 'gcons*
                      (gcons* 'a 'b (make-range-generator 0 2))
                      '(a b 0 1)))

(testing-registry-case
 'gappend '(portable stdlib)
 ("stdlib-generator-test.scm" 223)
(check-generator-list 'gappend
                      (gappend (make-range-generator 0 3)
                               (make-range-generator 0 2))
                      '(0 1 2 0 1)))

(testing-registry-case
 'parallel-generators/pull-left-to-right '(portable stdlib)
 ("stdlib-generator-test.scm" 231)
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
           (list (mapped) (mapped) (reverse log))))))

(testing-registry-case
 'gcombine '(portable stdlib)
 ("stdlib-generator-test.scm" 253)
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
 ("stdlib-generator-test.scm" 265)
(test-equal 'gcombine/stops-before-pulling-later-generator
             '(((1 10 seed)) (20))
             (let ((short (generator 1))
             (long (generator 10 20)))
         (list (generator->list
                (gcombine
                 (lambda (left right state)
                   (values (list left right state) state))
                 'seed
                 short
                 long))
               (generator->list long)))))

(testing-registry-case
 'gfilter '(portable stdlib)
 ("stdlib-generator-test.scm" 281)
(check-generator-list 'gfilter
                      (gfilter odd? (make-range-generator 1 11))
                      '(1 3 5 7 9)))

(testing-registry-case
 'gremove '(portable stdlib)
 ("stdlib-generator-test.scm" 288)
(check-generator-list 'gremove
                      (gremove odd? (make-range-generator 1 11))
                      '(2 4 6 8 10)))

(testing-registry-case
 'gtake/source-remainder '(portable stdlib)
 ("stdlib-generator-test.scm" 295)
(test-equal 'gtake/source-remainder
             '((1 2 3) (4))
             (let ((source (make-range-generator 1 5)))
         (list (generator->list (gtake source 3))
               (generator->list source)))))

(testing-registry-case
 'gtake/zero-does-not-consume '(portable stdlib)
 ("stdlib-generator-test.scm" 304)
(test-equal 'gtake/zero-does-not-consume
             '(() (1 2 3))
             (let ((source (make-range-generator 1 4)))
         (list (generator->list (gtake source 0))
               (generator->list source)))))

(testing-registry-case
 'gtake/padded '(portable stdlib)
 ("stdlib-generator-test.scm" 313)
(check-generator-list 'gtake/padded
                      (gtake (make-range-generator 1 3) 3 0)
                      '(1 2 0)))

(testing-registry-case
 'gdrop '(portable stdlib)
 ("stdlib-generator-test.scm" 320)
(check-generator-list 'gdrop
                      (gdrop (make-range-generator 1 5) 2)
                      '(3 4)))

(testing-registry-case
 'gdrop/past-end '(portable stdlib)
 ("stdlib-generator-test.scm" 327)
(check-generator-list 'gdrop/past-end
                      (gdrop (generator 'a 'b) 5)
                      '()))

(testing-registry-case
 'gtake-while '(portable stdlib)
 ("stdlib-generator-test.scm" 334)
(check-generator-list 'gtake-while
                      (gtake-while (lambda (value) (< value 3))
                                   (make-range-generator 1 5))
                      '(1 2)))

(testing-registry-case
 'gtake-while/consumes-failing-value '(portable stdlib)
 ("stdlib-generator-test.scm" 342)
(test-equal 'gtake-while/consumes-failing-value
             '((1 2) (4))
             (let ((source (make-range-generator 1 5)))
         (list (generator->list
                (gtake-while (lambda (value) (< value 3)) source))
               (generator->list source)))))

(testing-registry-case
 'gdrop-while '(portable stdlib)
 ("stdlib-generator-test.scm" 352)
(check-generator-list 'gdrop-while
                      (gdrop-while (lambda (value) (< value 3))
                                   (make-range-generator 1 5))
                      '(3 4)))

(testing-registry-case
 'gdelete/custom-equal '(portable stdlib)
 ("stdlib-generator-test.scm" 360)
(check-generator-list 'gdelete/custom-equal
                      (gdelete 1 (generator 0.0 1.0 0 1 2) =)
                      '(0.0 0 2)))

(testing-registry-case
 'gdelete-neighbor-dups/custom-equal '(portable stdlib)
 ("stdlib-generator-test.scm" 367)
(check-generator-list 'gdelete-neighbor-dups/custom-equal
                      (gdelete-neighbor-dups (generator 1 1 2 3 3 3) =)
                      '(1 2 3)))

(testing-registry-case
 'gflatten '(portable stdlib)
 ("stdlib-generator-test.scm" 374)
(check-generator-list 'gflatten
                      (gflatten (generator '(1 2 3) '(a b c)))
                      '(1 2 3 a b c)))

(testing-registry-case
 'gflatten/skips-empty-lists '(portable stdlib)
 ("stdlib-generator-test.scm" 381)
(check-generator-list 'gflatten/skips-empty-lists
                      (gflatten (generator '() '(a b) '() '(c)))
                      '(a b c)))

(testing-registry-case
 'ggroup '(portable stdlib)
 ("stdlib-generator-test.scm" 388)
(check-generator-list 'ggroup
                      (ggroup (generator 1 2 3 4 5 6 7 8) 3)
                      '((1 2 3) (4 5 6) (7 8))))

(testing-registry-case
 'ggroup/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 395)
(check-generator-list 'ggroup/empty
                      (ggroup (generator) 3)
                      '()))

(testing-registry-case
 'ggroup/padded '(portable stdlib)
 ("stdlib-generator-test.scm" 402)
(check-generator-list 'ggroup/padded
                      (ggroup (generator 1 2 3 4 5 6 7 8) 3 0)
                      '((1 2 3) (4 5 6) (7 8 0))))

(testing-registry-case
 'gmerge '(portable stdlib)
 ("stdlib-generator-test.scm" 409)
(check-generator-list 'gmerge
                      (gmerge < (generator 1 2 4 6)
                              (generator)
                              (generator 3 4 5))
                      '(1 2 3 4 4 5 6)))

(testing-registry-case
 'gmap '(portable stdlib)
 ("stdlib-generator-test.scm" 418)
(check-generator-list 'gmap
                      (gmap * (generator 1 2 3)
                            (generator 6 7 8)
                            (generator 9 10 11 12))
                      '(54 140 264)))

(testing-registry-case
 'gmap/stops-before-pulling-later-generator '(portable stdlib)
 ("stdlib-generator-test.scm" 427)
(test-equal 'gmap/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
             (long (generator 'b 'c)))
         (list (generator->list (gmap list short long))
               (generator->list long)))))

(testing-registry-case
 'gstate-filter '(portable stdlib)
 ("stdlib-generator-test.scm" 437)
(check-generator-list
 'gstate-filter
 (gstate-filter
  (lambda (item state) (values (even? state) (+ 1 state)))
  0
  (generator 'a 'b 'c 'd 'e))
 '(a c e)))

(testing-registry-case
 'gindex '(portable stdlib)
 ("stdlib-generator-test.scm" 448)
(check-generator-list 'gindex
                      (gindex (list->generator '(a b c d e f))
                              (list->generator '(0 2 4)))
                      '(a c e)))

(testing-registry-case
 'gselect '(portable stdlib)
 ("stdlib-generator-test.scm" 456)
(check-generator-list 'gselect
                      (gselect (list->generator '(a b c d e f))
                               (list->generator '(#t #f #f #t #t #f)))
                      '(a d e)))

(testing-registry-case
 'error-cases '(portable stdlib)
 ("stdlib-generator-test.scm" 464)
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
 ("stdlib-generator-test.scm" 484)
(test-equal 'generator->list/bounded
             '(1 2 3)
             (generator->list (generator 1 2 3 4 5) 3)))

(testing-registry-case
 'generator->reverse-list '(portable stdlib)
 ("stdlib-generator-test.scm" 491)
(test-equal 'generator->reverse-list
             '(5 4 3 2 1)
             (generator->reverse-list (generator 1 2 3 4 5))))

(testing-registry-case
 'generator->vector '(portable stdlib)
 ("stdlib-generator-test.scm" 498)
(test-equal 'generator->vector
             #(1 2 3 4 5)
             (generator->vector (generator 1 2 3 4 5))))

(testing-registry-case
 'generator->vector/bounded '(portable stdlib)
 ("stdlib-generator-test.scm" 505)
(test-equal 'generator->vector/bounded
             #(1 2 3)
             (generator->vector (generator 1 2 3 4 5) 3)))

(testing-registry-case
 'generator->vector!/count '(portable stdlib)
 ("stdlib-generator-test.scm" 512)
(let ((vector-target (make-vector 5 0)))
  (test-equal 'generator->vector!/count
             3
             (generator->vector! vector-target 2 (generator 1 2 4)))
  (test-equal 'generator->vector!/target
             #(0 0 1 2 4)
             vector-target)))

(testing-registry-case
 'generator->vector!/does-not-overconsume '(portable stdlib)
 ("stdlib-generator-test.scm" 523)
(test-equal 'generator->vector!/does-not-overconsume
             (list 1 #(0 10) '(20 30))
             (let ((source (generator 10 20 30))
             (target (vector 0 0)))
         (list (generator->vector! target 1 source)
               target
               (generator->list source)))))

(testing-registry-case
 'generator->string '(portable stdlib)
 ("stdlib-generator-test.scm" 534)
(test-equal 'generator->string
             "abc"
             (generator->string (generator #\a #\b #\c))))

(testing-registry-case
 'generator-fold '(portable stdlib)
 ("stdlib-generator-test.scm" 541)
(test-equal 'generator-fold
             '(e d c b a . z)
             (generator-fold cons 'z (generator 'a 'b 'c 'd 'e))))

(testing-registry-case
 'generator-fold/large-range '(portable stdlib)
 ("stdlib-generator-test.scm" 548)
(test-equal 'generator-fold/large-range
             99990000
             (generator-fold + 0
                       (gmap (lambda (value) (* value 2))
                             (make-range-generator 0 10000)))))

(testing-registry-case
 'generator-fold/stops-before-pulling-later-generator '(portable stdlib)
 ("stdlib-generator-test.scm" 557)
(test-equal 'generator-fold/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
             (long (generator 'b 'c)))
         (list (generator-fold
                (lambda (left right state)
                  (cons (list left right) state))
                '()
                short
                long)
               (generator->list long)))))

(testing-registry-case
 'generator-for-each '(portable stdlib)
 ("stdlib-generator-test.scm" 572)
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
 'generator-for-each/stops-before-pulling-later-generator '(portable stdlib)
 ("stdlib-generator-test.scm" 585)
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
 'generator-map->list '(portable stdlib)
 ("stdlib-generator-test.scm" 600)
(test-equal 'generator-map->list
             '(6 15)
             (generator-map->list
        (lambda values (apply + values))
        (generator 1 4)
        (generator 2 5)
        (generator 3 6))))

(testing-registry-case
 'generator-map->list/stops-before-pulling-later-generator '(portable stdlib)
 ("stdlib-generator-test.scm" 611)
(test-equal 'generator-map->list/stops-before-pulling-later-generator
             '(((a b)) (c))
             (let ((short (generator 'a))
             (long (generator 'b 'c)))
         (list (generator-map->list list short long)
               (generator->list long)))))

(testing-registry-case
 'generator-find/match '(portable stdlib)
 ("stdlib-generator-test.scm" 621)
(test-equal 'generator-find/match
             3
             (generator-find (lambda (x) (> x 2))
                       (make-range-generator 1 5))))

(testing-registry-case
 'generator-find/no-match '(portable stdlib)
 ("stdlib-generator-test.scm" 629)
(test-equal 'generator-find/no-match
             #f
             (generator-find (lambda (x) (> x 10))
                       (make-range-generator 1 5))))

(testing-registry-case
 'generator-count '(portable stdlib)
 ("stdlib-generator-test.scm" 637)
(test-equal 'generator-count
             2
             (generator-count odd? (make-range-generator 1 5))))

(testing-registry-case
 'generator-any/source-remainder '(portable stdlib)
 ("stdlib-generator-test.scm" 644)
(test-equal 'generator-any/source-remainder
             '(#t (4))
             (let ((source (make-range-generator 2 5)))
         (list (generator-any odd? source)
               (generator->list source)))))

(testing-registry-case
 'generator-every/false-source-remainder '(portable stdlib)
 ("stdlib-generator-test.scm" 653)
(test-equal 'generator-every/false-source-remainder
             '(#f (3 4))
             (let ((source (make-range-generator 2 5)))
         (list (generator-every odd? source)
               (generator->list source)))))

(testing-registry-case
 'generator-every/last-true '(portable stdlib)
 ("stdlib-generator-test.scm" 662)
(test-equal 'generator-every/last-true
             '(4 ())
             (let ((source (make-range-generator 2 5)))
         (list (generator-every
                (lambda (x) (and (> x 1) x))
                source)
               (generator->list source)))))

(testing-registry-case
 'generator-unfold '(portable stdlib)
 ("stdlib-generator-test.scm" 673)
(test-equal 'generator-unfold
             '(#\a #\b #\c)
             (generator-unfold
        (make-for-each-generator string-for-each "abc")
        unfold)))

(testing-registry-case
 'make-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 682)
(test-equal 'make-accumulator
             -8
             (let ((acc (make-accumulator * 1 -)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'count-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 693)
(test-equal 'count-accumulator
             3
             (let ((acc (count-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'count-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 704)
(test-equal 'count-accumulator/empty
             0
             (let ((acc (count-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'list-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 712)
(test-equal 'list-accumulator
             '(1 2 4)
             (let ((acc (list-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'list-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 723)
(test-equal 'list-accumulator/empty
             '()
             (let ((acc (list-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'reverse-list-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 731)
(test-equal 'reverse-list-accumulator
             '(4 2 1)
             (let ((acc (reverse-list-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'vector-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 742)
(test-equal 'vector-accumulator
             #(1 2 4)
             (let ((acc (vector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'vector-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 753)
(test-equal 'vector-accumulator/empty
             #()
             (let ((acc (vector-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'reverse-vector-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 761)
(test-equal 'reverse-vector-accumulator
             #(4 2 1)
             (let ((acc (reverse-vector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'vector-accumulator! '(portable stdlib)
 ("stdlib-generator-test.scm" 772)
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
 ("stdlib-generator-test.scm" 784)
(test-equal 'string-accumulator
             "abc"
             (let ((acc (string-accumulator)))
         (acc #\a)
         (acc #\b)
         (acc #\c)
         (acc (eof-object)))))

(testing-registry-case
 'string-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 795)
(test-equal 'string-accumulator/empty
             ""
             (let ((acc (string-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'bytevector-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 803)
(test-equal 'bytevector-accumulator
             (bytevector 1 2 4)
             (let ((acc (bytevector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'bytevector-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 814)
(test-equal 'bytevector-accumulator/empty
             (bytevector)
             (let ((acc (bytevector-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'bytevector-accumulator! '(portable stdlib)
 ("stdlib-generator-test.scm" 822)
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
 ("stdlib-generator-test.scm" 834)
(test-equal 'sum-accumulator
             7
             (let ((acc (sum-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'sum-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 845)
(test-equal 'sum-accumulator/empty
             0
             (let ((acc (sum-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'product-accumulator '(portable stdlib)
 ("stdlib-generator-test.scm" 853)
(test-equal 'product-accumulator
             8
             (let ((acc (product-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))))

(testing-registry-case
 'product-accumulator/empty '(portable stdlib)
 ("stdlib-generator-test.scm" 864)
(test-equal 'product-accumulator/empty
             1
             (let ((acc (product-accumulator)))
         (acc (eof-object)))))

(testing-registry-case
 'accumulators/reject-post-finalization-writes '(portable stdlib)
 ("stdlib-generator-test.scm" 872)
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

(testing-runner-main "Stdlib Generator portable tests" (command-line))
