;;; Portable SRFI 194 random data generator stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2020 Arvydas Silanskas
;; SPDX-FileCopyrightText: 2020 Bradley Lucier
;; SPDX-FileCopyrightText: 2020 Linas Vepštas
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 194 `srfi-194-test.scm` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-194.

(import (scheme base)
        (scheme inexact)
        (scheme complex)
        (scheme write)
        (stdlib random-bits)
        (stdlib generator)
        (stdlib random-data-generators))

;; Number of failed SRFI 194 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed random-data-generator check."
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

(define (check-true name value)
  "Record failure unless VALUE is true."
  (if (not value)
      (record-failure name #t value)))

(define (check-near name actual expected)
  "Compare ACTUAL and EXPECTED with a small inexact tolerance."
  (if (not (< (abs (- actual expected)) 0.000000001))
      (record-failure name expected actual)))

(define (raises? thunk)
  "Return #t when THUNK raises an exception."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (source-at state)
  "Return a fresh random source positioned at STATE."
  (let ((source (make-random-source)))
    (random-source-state-set! source state)
    source))

(define (values-in-range? values lower upper)
  "Return #t when VALUES are all in `[LOWER, UPPER)'."
  (let loop ((rest values))
    (cond
     ((null? rest) #t)
     ((and (>= (car rest) lower) (< (car rest) upper))
      (loop (cdr rest)))
     (else #f))))

(define (real-values-in-range? values lower upper)
  "Return #t when VALUES are all real numbers in `[LOWER, UPPER]'."
  (let loop ((rest values))
    (cond
     ((null? rest) #t)
     ((and (real? (car rest))
           (>= (car rest) lower)
           (<= (car rest) upper))
      (loop (cdr rest)))
     (else #f))))

(define (vector-sum-squares vector)
  "Return the sum of squared VECTOR elements."
  (let loop ((index 0) (sum 0.0))
    (if (= index (vector-length vector))
        sum
        (loop (+ index 1)
              (+ sum (* (vector-ref vector index)
                        (vector-ref vector index)))))))

(define (ellipsoid-sum point axes)
  "Return the ellipsoid surface equation sum for POINT and AXES."
  (let loop ((index 0) (sum 0.0))
    (if (= index (vector-length axes))
        sum
        (let ((scaled (/ (vector-ref point index) (vector-ref axes index))))
          (loop (+ index 1) (+ sum (* scaled scaled)))))))

(define (finish-random-data-generator-tests)
  "Report the SRFI 194 random-data-generator test result."
  (if (= failures 0)
      (begin
        (display "SRFI 194 random data generator tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 194 random data generator test failure(s)")
        (newline)
        (error "SRFI 194 random data generator tests failed" failures))))

(check-true 'current-random-source-is-parameter
            (random-source? (current-random-source)))

(let* ((state (random-source-state-ref (make-random-source)))
       (left-source (source-at state))
       (right-source (source-at state))
       (left-generator
        (with-random-source
         left-source
         (lambda () (make-random-integer-generator 10 20))))
       (right-generator
        (with-random-source
         right-source
         (lambda () (make-random-integer-generator 10 20)))))
  (check 'with-random-source-replays-same-state
         (generator->list left-generator 12)
         (generator->list right-generator 12)))

(let ((source-generator-a (make-random-source-generator 7))
      (source-generator-b (make-random-source-generator 7))
      (source-generator-c (make-random-source-generator 8)))
  (define (draw source-generator)
    (let ((rand (random-source-make-integers (source-generator))))
      (list (rand 1000) (rand 1000) (rand 1000))))
  (check 'random-source-generator-replays-streams
         (list (draw source-generator-a) (draw source-generator-a))
         (list (draw source-generator-b) (draw source-generator-b)))
  (check-true 'random-source-generator-stream-index-differs
              (not (equal? (draw source-generator-a)
                           (draw source-generator-c)))))

(check 'clamp-real-number-low
       (clamp-real-number 5.0 10.0 2.0)
       5.0)

(check 'clamp-real-number-high
       (clamp-real-number 5.0 10.0 12.0)
       10.0)

(check 'clamp-real-number-middle
       (clamp-real-number 5.0 10.0 7.5)
       7.5)

(check-true 'random-integer-generator-range
            (values-in-range?
             (generator->list (make-random-integer-generator -5 5) 100)
             -5
             5))

(check-true 'random-u1-generator-range
            (values-in-range?
             (generator->list (make-random-u1-generator) 40)
             0
             2))

(check-true 'random-s8-generator-range
            (values-in-range?
             (generator->list (make-random-s8-generator) 100)
             -128
             128))

(check-true 'random-real-generator-range
            (real-values-in-range?
             (generator->list (make-random-real-generator 1.0 5.0) 100)
             1.0
             5.0))

(let ((value ((make-random-rectangular-generator -2.0 3.0 -5.0 7.0))))
  (check-true 'random-rectangular-generator-range
              (and (complex? value)
                   (>= (real-part value) -2.0)
                   (<= (real-part value) 3.0)
                   (>= (imag-part value) -5.0)
                   (<= (imag-part value) 7.0))))

(let ((value ((make-random-polar-generator 1.0 3.0))))
  (check-true 'random-polar-generator-range
              (and (complex? value)
                   (>= (magnitude value) 1.0)
                   (<= (magnitude value) 3.0))))

(let ((values (generator->list (make-random-boolean-generator) 100)))
  (check-true 'random-boolean-generator-range
              (let loop ((rest values))
                (cond
                 ((null? rest) #t)
                 ((or (eq? (car rest) #t) (eq? (car rest) #f))
                  (loop (cdr rest)))
                 (else #f)))))

(let ((char-generator (make-random-char-generator "abca")))
  (check-true 'random-char-generator-source
              (let loop ((rest (generator->list char-generator 100)))
                (cond
                 ((null? rest) #t)
                 ((or (char=? (car rest) #\a)
                      (char=? (car rest) #\b)
                      (char=? (car rest) #\c))
                  (loop (cdr rest)))
                 (else #f)))))

(let ((string-generator (make-random-string-generator 5 "abc")))
  (check-true 'random-string-generator-source-and-length
              (let loop ((strings (generator->list string-generator 30)))
                (cond
                 ((null? strings) #t)
                 ((<= (string-length (car strings)) 4)
                  (loop (cdr strings)))
                 (else #f)))))

(check 'bernoulli-zero
       (generator->list (make-bernoulli-generator 0) 8)
       '(0 0 0 0 0 0 0 0))

(check 'bernoulli-one
       (generator->list (make-bernoulli-generator 1) 8)
       '(1 1 1 1 1 1 1 1))

(check 'categorical-zero-weights
       (generator->list (make-categorical-generator '#(0 3 0)) 12)
       '(1 1 1 1 1 1 1 1 1 1 1 1))

(check 'geometric-one
       (generator->list (make-geometric-generator 1) 8)
       '(1 1 1 1 1 1 1 1))

(check-true 'binomial-generator-range
            (values-in-range?
             (generator->list (make-binomial-generator 8 0.25) 100)
             0
             9))

(check-true 'normal-generator-real
            (real? ((make-normal-generator 2.0 0.5))))

(check-true 'exponential-generator-positive
            (< 0 ((make-exponential-generator 2.0))))

(check-true 'poisson-generator-range
            (values-in-range?
             (generator->list (make-poisson-generator 4.0) 100)
             0
             100))

(check-true 'zipf-generator-range
            (values-in-range?
             (generator->list (make-zipf-generator 5) 100)
             1
             6))

(let ((point ((make-sphere-generator 2))))
  (check 'sphere-generator-dimension
         (vector-length point)
         3)
  (check-near 'sphere-generator-unit-norm
              (vector-sum-squares point)
              1.0))

(let* ((axes '#(2.0 3.0 4.0))
       (point ((make-ellipsoid-generator axes))))
  (check 'ellipsoid-generator-dimension
         (vector-length point)
         3)
  (check-near 'ellipsoid-generator-surface
              (ellipsoid-sum point axes)
              1.0))

(let ((point ((make-ball-generator 3))))
  (check 'ball-generator-dimension
         (vector-length point)
         3)
  (check-true 'ball-generator-inside-unit-ball
              (<= (vector-sum-squares point) 1.0)))

(check 'gsampling-single-generator
       (let ((sample (gsampling (generator 'a 'b))))
         (list (sample) (sample) (eof-object? (sample)) (eof-object? (sample))))
       '(a b #t #t))

(check-true 'invalid-range-raises
            (raises? (lambda () (make-random-integer-generator 1 1))))

(check-true 'invalid-char-source-raises
            (raises? (lambda () (make-random-char-generator ""))))

(check-true 'invalid-categorical-weights-raises
            (raises? (lambda () (make-categorical-generator '#(0 0)))))

(finish-random-data-generator-tests)
