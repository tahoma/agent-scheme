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
        (only (stdlib list) unfold))

;; Number of failed adapted SRFI checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed generator-library check."
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (check name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (check-generator-list name gen expected)
  "Compare the values yielded by GEN to EXPECTED."
  (check name (generator->list gen) expected))

(define (raises? thunk)
  "Return #t when THUNK raises an exception."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (finish-generator-tests)
  "Report the adapted SRFI 158 test result."
  (if (= failures 0)
      (begin
        (display "Adapted SRFI 158 generator tests passed")
        (newline))
      (begin
        (display failures)
        (display " adapted SRFI 158 generator test failure(s)")
        (newline)
        (error "adapted SRFI 158 generator tests failed" failures))))

(check-generator-list 'generator/empty
                      (generator)
                      '())

(check-generator-list 'generator/finite
                      (generator 1 2 3)
                      '(1 2 3))

(check 'generator/eof-idempotent
       (let ((gen (generator 'x)))
         (list (gen) (eof-object? (gen)) (eof-object? (gen))))
       '(x #t #t))

(check 'circular-generator/prefix
       (generator->list (circular-generator 1 2 3) 5)
       '(1 2 3 1 2))

(check-generator-list 'make-iota-generator/zero
                      (make-iota-generator 0)
                      '())

(check-generator-list 'make-iota-generator/count-start
                      (make-iota-generator 3 8)
                      '(8 9 10))

(check-generator-list 'make-iota-generator/count-start-step
                      (make-iota-generator 3 8 2)
                      '(8 10 12))

(check 'make-range-generator/unbounded-prefix
       (generator->list (make-range-generator 3) 4)
       '(3 4 5 6))

(check-generator-list 'make-range-generator/bounded
                      (make-range-generator 3 8)
                      '(3 4 5 6 7))

(check-generator-list 'make-range-generator/empty
                      (make-range-generator 3 3)
                      '())

(check-generator-list 'make-range-generator/bounded-step
                      (make-range-generator 3 8 2)
                      '(3 5 7))

(check-generator-list
 'make-coroutine-generator/simple-yields
 (make-coroutine-generator
  (lambda (yield)
    (let loop ((i 0))
      (when (< i 3)
        (yield i)
        (loop (+ i 1))))))
 '(0 1 2))

(check 'make-coroutine-generator/eof-idempotent
       (let ((gen (make-coroutine-generator
                   (lambda (yield)
                     (yield 'only)))))
         (list (gen) (eof-object? (gen)) (eof-object? (gen))))
       '(only #t #t))

(check 'make-coroutine-generator/no-yields
       (let ((gen (make-coroutine-generator
                   (lambda (yield)
                     yield
                     #t))))
         (list (eof-object? (gen)) (eof-object? (gen))))
       '(#t #t))

(check-generator-list 'list->generator
                      (list->generator '(1 2 3 4 5))
                      '(1 2 3 4 5))

(check-generator-list 'vector->generator
                      (vector->generator '#(1 2 3 4 5))
                      '(1 2 3 4 5))

(check-generator-list 'vector->generator/slice
                      (vector->generator '#(0 1 2 3 4 5) 2 5)
                      '(2 3 4))

(check-generator-list 'reverse-vector->generator
                      (reverse-vector->generator '#(1 2 3 4 5))
                      '(5 4 3 2 1))

(check-generator-list 'reverse-vector->generator/slice
                      (reverse-vector->generator '#(0 1 2 3 4 5) 1 5)
                      '(4 3 2 1))

(check-generator-list 'string->generator
                      (string->generator "abcde")
                      '(#\a #\b #\c #\d #\e))

(check-generator-list 'string->generator/slice
                      (string->generator "abcdef" 2 5)
                      '(#\c #\d #\e))

(check-generator-list 'bytevector->generator
                      (bytevector->generator (bytevector 10 20 30))
                      '(10 20 30))

(check-generator-list 'bytevector->generator/slice
                      (bytevector->generator (bytevector 0 10 20 30 40) 1 4)
                      '(10 20 30))

(check-generator-list
 'make-unfold-generator
 (make-unfold-generator
  (lambda (seed) (> seed 5))
  (lambda (seed) (* seed 2))
  (lambda (seed) (+ seed 1))
  0)
 '(0 2 4 6 8 10))

(check-generator-list 'gcons*
                      (gcons* 'a 'b (make-range-generator 0 2))
                      '(a b 0 1))

(check-generator-list 'gappend
                      (gappend (make-range-generator 0 3)
                               (make-range-generator 0 2))
                      '(0 1 2 0 1))

(check-generator-list
 'gcombine
 (gcombine
  (lambda args (values (apply + args) (apply + args)))
  10
  (generator 1 2 3)
  (generator 4 5 6 7))
 '(15 22 31))

(check-generator-list 'gfilter
                      (gfilter odd? (make-range-generator 1 11))
                      '(1 3 5 7 9))

(check-generator-list 'gremove
                      (gremove odd? (make-range-generator 1 11))
                      '(2 4 6 8 10))

(check 'gtake/source-remainder
       (let ((source (make-range-generator 1 5)))
         (list (generator->list (gtake source 3))
               (generator->list source)))
       '((1 2 3) (4)))

(check 'gtake/zero-does-not-consume
       (let ((source (make-range-generator 1 4)))
         (list (generator->list (gtake source 0))
               (generator->list source)))
       '(() (1 2 3)))

(check-generator-list 'gtake/padded
                      (gtake (make-range-generator 1 3) 3 0)
                      '(1 2 0))

(check-generator-list 'gdrop
                      (gdrop (make-range-generator 1 5) 2)
                      '(3 4))

(check-generator-list 'gdrop/past-end
                      (gdrop (generator 'a 'b) 5)
                      '())

(check-generator-list 'gtake-while
                      (gtake-while (lambda (value) (< value 3))
                                   (make-range-generator 1 5))
                      '(1 2))

(check 'gtake-while/consumes-failing-value
       (let ((source (make-range-generator 1 5)))
         (list (generator->list
                (gtake-while (lambda (value) (< value 3)) source))
               (generator->list source)))
       '((1 2) (4)))

(check-generator-list 'gdrop-while
                      (gdrop-while (lambda (value) (< value 3))
                                   (make-range-generator 1 5))
                      '(3 4))

(check-generator-list 'gdelete/custom-equal
                      (gdelete 1 (generator 0.0 1.0 0 1 2) =)
                      '(0.0 0 2))

(check-generator-list 'gdelete-neighbor-dups/custom-equal
                      (gdelete-neighbor-dups (generator 1 1 2 3 3 3) =)
                      '(1 2 3))

(check-generator-list 'gflatten
                      (gflatten (generator '(1 2 3) '(a b c)))
                      '(1 2 3 a b c))

(check-generator-list 'gflatten/skips-empty-lists
                      (gflatten (generator '() '(a b) '() '(c)))
                      '(a b c))

(check-generator-list 'ggroup
                      (ggroup (generator 1 2 3 4 5 6 7 8) 3)
                      '((1 2 3) (4 5 6) (7 8)))

(check-generator-list 'ggroup/empty
                      (ggroup (generator) 3)
                      '())

(check-generator-list 'ggroup/padded
                      (ggroup (generator 1 2 3 4 5 6 7 8) 3 0)
                      '((1 2 3) (4 5 6) (7 8 0)))

(check-generator-list 'gmerge
                      (gmerge < (generator 1 2 4 6)
                              (generator)
                              (generator 3 4 5))
                      '(1 2 3 4 4 5 6))

(check-generator-list 'gmap
                      (gmap * (generator 1 2 3)
                            (generator 6 7 8)
                            (generator 9 10 11 12))
                      '(54 140 264))

(check-generator-list
 'gstate-filter
 (gstate-filter
  (lambda (item state) (values (even? state) (+ 1 state)))
  0
  (generator 'a 'b 'c 'd 'e))
 '(a c e))

(check-generator-list 'gindex
                      (gindex (list->generator '(a b c d e f))
                              (list->generator '(0 2 4)))
                      '(a c e))

(check-generator-list 'gselect
                      (gselect (list->generator '(a b c d e f))
                               (list->generator '(#t #f #f #t #t #f)))
                      '(a d e))

(check 'error-cases
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
                                 (generator 1 1))))))
       '(#t #t #t #t #t #t #t))

(check 'generator->list/bounded
       (generator->list (generator 1 2 3 4 5) 3)
       '(1 2 3))

(check 'generator->reverse-list
       (generator->reverse-list (generator 1 2 3 4 5))
       '(5 4 3 2 1))

(check 'generator->vector
       (generator->vector (generator 1 2 3 4 5))
       #(1 2 3 4 5))

(check 'generator->vector/bounded
       (generator->vector (generator 1 2 3 4 5) 3)
       #(1 2 3))

(let ((vector-target (make-vector 5 0)))
  (check 'generator->vector!/count
         (generator->vector! vector-target 2 (generator 1 2 4))
         3)
  (check 'generator->vector!/target
         vector-target
         #(0 0 1 2 4)))

(check 'generator->vector!/does-not-overconsume
       (let ((source (generator 10 20 30))
             (target (vector 0 0)))
         (list (generator->vector! target 1 source)
               target
               (generator->list source)))
       (list 1 #(0 10) '(20 30)))

(check 'generator->string
       (generator->string (generator #\a #\b #\c))
       "abc")

(check 'generator-fold
       (generator-fold cons 'z (generator 'a 'b 'c 'd 'e))
       '(e d c b a . z))

(check 'generator-for-each
       (let ((n 0))
         (generator-for-each
          (lambda values (set! n (apply + values)))
          (generator 1)
          (generator 2)
          (generator 3))
         n)
       6)

(check 'generator-map->list
       (generator-map->list
        (lambda values (apply + values))
        (generator 1 4)
        (generator 2 5)
        (generator 3 6))
       '(6 15))

(check 'generator-find/match
       (generator-find (lambda (x) (> x 2))
                       (make-range-generator 1 5))
       3)

(check 'generator-find/no-match
       (generator-find (lambda (x) (> x 10))
                       (make-range-generator 1 5))
       #f)

(check 'generator-count
       (generator-count odd? (make-range-generator 1 5))
       2)

(check 'generator-any/source-remainder
       (let ((source (make-range-generator 2 5)))
         (list (generator-any odd? source)
               (generator->list source)))
       '(#t (4)))

(check 'generator-every/false-source-remainder
       (let ((source (make-range-generator 2 5)))
         (list (generator-every odd? source)
               (generator->list source)))
       '(#f (3 4)))

(check 'generator-every/last-true
       (let ((source (make-range-generator 2 5)))
         (list (generator-every
                (lambda (x) (and (> x 1) x))
                source)
               (generator->list source)))
       '(4 ()))

(check 'generator-unfold
       (generator-unfold
        (make-for-each-generator string-for-each "abc")
        unfold)
       '(#\a #\b #\c))

(check 'make-accumulator
       (let ((acc (make-accumulator * 1 -)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       -8)

(check 'count-accumulator
       (let ((acc (count-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       3)

(check 'count-accumulator/empty
       (let ((acc (count-accumulator)))
         (acc (eof-object)))
       0)

(check 'list-accumulator
       (let ((acc (list-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       '(1 2 4))

(check 'list-accumulator/empty
       (let ((acc (list-accumulator)))
         (acc (eof-object)))
       '())

(check 'reverse-list-accumulator
       (let ((acc (reverse-list-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       '(4 2 1))

(check 'vector-accumulator
       (let ((acc (vector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       #(1 2 4))

(check 'vector-accumulator/empty
       (let ((acc (vector-accumulator)))
         (acc (eof-object)))
       #())

(check 'reverse-vector-accumulator
       (let ((acc (reverse-vector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       #(4 2 1))

(check 'vector-accumulator!
       (let* ((target (vector 0 0 0 0 0))
              (acc (vector-accumulator! target 2)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       #(0 0 1 2 4))

(check 'string-accumulator
       (let ((acc (string-accumulator)))
         (acc #\a)
         (acc #\b)
         (acc #\c)
         (acc (eof-object)))
       "abc")

(check 'string-accumulator/empty
       (let ((acc (string-accumulator)))
         (acc (eof-object)))
       "")

(check 'bytevector-accumulator
       (let ((acc (bytevector-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       (bytevector 1 2 4))

(check 'bytevector-accumulator/empty
       (let ((acc (bytevector-accumulator)))
         (acc (eof-object)))
       (bytevector))

(check 'bytevector-accumulator!
       (let* ((target (bytevector 0 0 0 0 0))
              (acc (bytevector-accumulator! target 2)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       (bytevector 0 0 1 2 4))

(check 'sum-accumulator
       (let ((acc (sum-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       7)

(check 'sum-accumulator/empty
       (let ((acc (sum-accumulator)))
         (acc (eof-object)))
       0)

(check 'product-accumulator
       (let ((acc (product-accumulator)))
         (acc 1)
         (acc 2)
         (acc 4)
         (acc (eof-object)))
       8)

(check 'product-accumulator/empty
       (let ((acc (product-accumulator)))
         (acc (eof-object)))
       1)

(check 'accumulators/reject-post-finalization-writes
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
                    bytevector-acc bytevector-write sum product)))
       '(#t #t #t #t #t #t #t #t #t #t))

(finish-generator-tests)
