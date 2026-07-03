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

(check 'constructors
       (let ((coroutine
              (make-coroutine-generator
               (lambda (yield)
                 (let loop ((i 0))
                   (when (< i 3)
                     (yield i)
                     (loop (+ i 1))))))))
         (list (generator->list (generator))
               (generator->list (generator 1 2 3))
               (generator->list (circular-generator 1 2 3) 5)
               (generator->list (make-iota-generator 3 8))
               (generator->list (make-iota-generator 3 8 2))
               (generator->list (make-range-generator 3) 4)
               (generator->list (make-range-generator 3 8))
               (generator->list (make-range-generator 3 8 2))
               (generator->list coroutine)
               (generator->list (list->generator '(1 2 3 4 5)))
               (generator->list (vector->generator '#(1 2 3 4 5)))
               (generator->list (reverse-vector->generator '#(1 2 3 4 5)))
               (generator->list (string->generator "abcde"))
               (generator->list (bytevector->generator (bytevector 10 20 30)))
               (generator->list
                (make-unfold-generator
                 (lambda (seed) (> seed 5))
                 (lambda (seed) (* seed 2))
                 (lambda (seed) (+ seed 1))
                 0))))
       '(() (1 2 3) (1 2 3 1 2) (8 9 10) (8 10 12)
         (3 4 5 6) (3 4 5 6 7) (3 5 7) (0 1 2)
         (1 2 3 4 5) (1 2 3 4 5) (5 4 3 2 1)
         (#\a #\b #\c #\d #\e) (10 20 30) (0 2 4 6 8 10)))

(check 'operators
       (list (generator->list
              (gcons* 'a 'b (make-range-generator 0 2)))
             (generator->list
              (gappend (make-range-generator 0 3)
                       (make-range-generator 0 2)))
             (generator->list
              (gcombine
               (lambda args (values (apply + args) (apply + args)))
               10
               (generator 1 2 3)
               (generator 4 5 6 7)))
             (generator->list
              (gfilter odd? (make-range-generator 1 11)))
             (generator->list
              (gremove odd? (make-range-generator 1 11)))
             (let ((source (make-range-generator 1 5)))
               (list (generator->list (gtake source 3))
                     (generator->list source)))
             (generator->list
              (gtake (make-range-generator 1 3) 3 0))
             (generator->list
              (gdrop (make-range-generator 1 5) 2))
             (generator->list
              (gtake-while (lambda (value) (< value 3))
                           (make-range-generator 1 5)))
             (generator->list
              (gdrop-while (lambda (value) (< value 3))
                           (make-range-generator 1 5)))
             (generator->list
              (gdelete 1 (generator 0.0 1.0 0 1 2) =))
             (generator->list
              (gdelete-neighbor-dups (generator 1 1 2 3 3 3) =))
             (generator->list
              (gflatten (generator '(1 2 3) '(a b c))))
             (generator->list
              (ggroup (generator 1 2 3 4 5 6 7 8) 3))
             (generator->list
              (ggroup (generator 1 2 3 4 5 6 7 8) 3 0))
             (generator->list
              (gmerge < (generator 1 2 4 6)
                      (generator)
                      (generator 3 4 5)))
             (generator->list
              (gmap * (generator 1 2 3)
                    (generator 6 7 8)
                    (generator 9 10 11 12)))
             (generator->list
              (gstate-filter
               (lambda (item state) (values (even? state) (+ 1 state)))
               0
               (generator 'a 'b 'c 'd 'e)))
             (generator->list
              (gindex (list->generator '(a b c d e f))
                      (list->generator '(0 2 4))))
             (generator->list
              (gselect (list->generator '(a b c d e f))
                       (list->generator '(#t #f #f #t #t #f)))))
       '((a b 0 1)
         (0 1 2 0 1)
         (15 22 31)
         (1 3 5 7 9)
         (2 4 6 8 10)
         ((1 2 3) (4))
         (1 2 0)
         (3 4)
         (1 2)
         (3 4)
         (0.0 0 2)
         (1 2 3)
         (1 2 3 a b c)
         ((1 2 3) (4 5 6) (7 8))
         ((1 2 3) (4 5 6) (7 8 0))
         (1 2 3 4 4 5 6)
         (54 140 264)
         (a c e)
         (a c e)
         (a d e)))

(check 'consumers
       (let ((vector-target (make-vector 5 0)))
         (list (generator->list (generator 1 2 3 4 5) 3)
               (generator->reverse-list (generator 1 2 3 4 5))
               (generator->vector (generator 1 2 3 4 5))
               (generator->vector (generator 1 2 3 4 5) 3)
               (generator->vector! vector-target 2 (generator 1 2 4))
               vector-target
               (generator->string (generator #\a #\b #\c))
               (generator-fold cons 'z (generator 'a 'b 'c 'd 'e))
               (let ((n 0))
                 (generator-for-each
                  (lambda values (set! n (apply + values)))
                  (generator 1)
                  (generator 2)
                  (generator 3))
                 n)
               (generator-map->list
                (lambda values (apply + values))
                (generator 1 4)
                (generator 2 5)
                (generator 3 6))
               (generator-find (lambda (x) (> x 2))
                               (make-range-generator 1 5))
               (generator-find (lambda (x) (> x 10))
                               (make-range-generator 1 5))
               (generator-count odd? (make-range-generator 1 5))
               (let ((source (make-range-generator 2 5)))
                 (list (generator-any odd? source)
                       (generator->list source)))
               (let ((source (make-range-generator 2 5)))
                 (list (generator-every odd? source)
                       (generator->list source)))
               (let ((source (make-range-generator 2 5)))
                 (list (generator-every
                        (lambda (x) (and (> x 1) x))
                        source)
                       (generator->list source)))
               (generator-unfold
                (make-for-each-generator string-for-each "abc")
                unfold)))
       '((1 2 3)
         (5 4 3 2 1)
         #(1 2 3 4 5)
         #(1 2 3)
         3
         #(0 0 1 2 4)
         "abc"
         (e d c b a . z)
         6
         (6 15)
         3
         #f
         2
         (#t (4))
         (#f (3 4))
         (4 ())
         (#\a #\b #\c)))

(check 'accumulators
       (list (let ((acc (make-accumulator * 1 -)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (count-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (list-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (reverse-list-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (vector-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (reverse-vector-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let* ((target (vector 0 0 0 0 0))
                    (acc (vector-accumulator! target 2)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (string-accumulator)))
               (acc #\a)
               (acc #\b)
               (acc #\c)
               (acc (eof-object)))
             (let ((acc (bytevector-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let* ((target (bytevector 0 0 0 0 0))
                    (acc (bytevector-accumulator! target 2)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
             (let ((acc (sum-accumulator)))
               (acc 1)
               (acc 2)
               (acc 4)
               (acc (eof-object)))
	             (let ((acc (product-accumulator)))
	               (acc 1)
	               (acc 2)
	               (acc 4)
	               (acc (eof-object))))
       (list -8
             3
             '(1 2 4)
             '(4 2 1)
             (vector 1 2 4)
             (vector 4 2 1)
             (vector 0 0 1 2 4)
             "abc"
             (bytevector 1 2 4)
             (bytevector 0 0 1 2 4)
             7
             8))

(finish-generator-tests)
