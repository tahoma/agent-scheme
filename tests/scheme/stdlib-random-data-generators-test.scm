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
        (stdlib random-data-generators)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (check-near name actual expected)
  "Compare ACTUAL and EXPECTED with a small inexact tolerance."
  (test-approximate name expected actual 0.000000001))

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

(testing-registry-case
 'current-random-source-is-parameter '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 77)
(test-assert 'current-random-source-is-parameter
             (random-source? (current-random-source))))

(testing-registry-case
 'with-random-source-replays-same-state '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 83)
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
  (test-equal 'with-random-source-replays-same-state
             (generator->list right-generator 12)
             (generator->list left-generator 12))))

(testing-registry-case
 'random-source-generator-replays-streams '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 101)
(let ((source-generator-a (make-random-source-generator 7))
      (source-generator-b (make-random-source-generator 7))
      (source-generator-c (make-random-source-generator 8)))
  (define (draw source-generator)
    (let ((rand (random-source-make-integers (source-generator))))
      (list (rand 1000) (rand 1000) (rand 1000))))
  (test-equal 'random-source-generator-replays-streams
             (list (draw source-generator-b) (draw source-generator-b))
             (list (draw source-generator-a) (draw source-generator-a)))
  (test-assert 'random-source-generator-stream-index-differs
             (not (equal? (draw source-generator-a)
                           (draw source-generator-c))))))

(testing-registry-case
 'clamp-real-number-low '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 117)
(test-equal 'clamp-real-number-low
             5.0
             (clamp-real-number 5.0 10.0 2.0)))

(testing-registry-case
 'clamp-real-number-high '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 124)
(test-equal 'clamp-real-number-high
             10.0
             (clamp-real-number 5.0 10.0 12.0)))

(testing-registry-case
 'clamp-real-number-middle '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 131)
(test-equal 'clamp-real-number-middle
             7.5
             (clamp-real-number 5.0 10.0 7.5)))

(testing-registry-case
 'random-integer-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 138)
(test-assert 'random-integer-generator-range
             (values-in-range?
             (generator->list (make-random-integer-generator -5 5) 100)
             -5
             5)))

(testing-registry-case
 'random-u1-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 147)
(test-assert 'random-u1-generator-range
             (values-in-range?
             (generator->list (make-random-u1-generator) 40)
             0
             2)))

(testing-registry-case
 'random-s8-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 156)
(test-assert 'random-s8-generator-range
             (values-in-range?
             (generator->list (make-random-s8-generator) 100)
             -128
             128)))

(testing-registry-case
 'random-real-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 165)
(test-assert 'random-real-generator-range
             (real-values-in-range?
             (generator->list (make-random-real-generator 1.0 5.0) 100)
             1.0
             5.0)))

(testing-registry-case
 'random-rectangular-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 174)
(let ((value ((make-random-rectangular-generator -2.0 3.0 -5.0 7.0))))
  (test-assert 'random-rectangular-generator-range
             (and (complex? value)
                   (>= (real-part value) -2.0)
                   (<= (real-part value) 3.0)
                   (>= (imag-part value) -5.0)
                   (<= (imag-part value) 7.0)))))

(testing-registry-case
 'random-polar-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 185)
(let ((value ((make-random-polar-generator 1.0 3.0))))
  (test-assert 'random-polar-generator-range
             (and (complex? value)
                   (>= (magnitude value) 1.0)
                   (<= (magnitude value) 3.0)))))

(testing-registry-case
 'random-boolean-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 194)
(let ((values (generator->list (make-random-boolean-generator) 100)))
  (test-assert 'random-boolean-generator-range
             (let loop ((rest values))
                (cond
                 ((null? rest) #t)
                 ((or (eq? (car rest) #t) (eq? (car rest) #f))
                  (loop (cdr rest)))
                 (else #f))))))

(testing-registry-case
 'random-char-generator-source '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 206)
(let ((char-generator (make-random-char-generator "abca")))
  (test-assert 'random-char-generator-source
             (let loop ((rest (generator->list char-generator 100)))
                (cond
                 ((null? rest) #t)
                 ((or (char=? (car rest) #\a)
                      (char=? (car rest) #\b)
                      (char=? (car rest) #\c))
                  (loop (cdr rest)))
                 (else #f))))))

(testing-registry-case
 'random-string-generator-source-and-length '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 220)
(let ((string-generator (make-random-string-generator 5 "abc")))
  (test-assert 'random-string-generator-source-and-length
             (let loop ((strings (generator->list string-generator 30)))
                (cond
                 ((null? strings) #t)
                 ((<= (string-length (car strings)) 4)
                  (loop (cdr strings)))
                 (else #f))))))

(testing-registry-case
 'bernoulli-zero '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 232)
(test-equal 'bernoulli-zero
             '(0 0 0 0 0 0 0 0)
             (generator->list (make-bernoulli-generator 0) 8)))

(testing-registry-case
 'bernoulli-one '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 239)
(test-equal 'bernoulli-one
             '(1 1 1 1 1 1 1 1)
             (generator->list (make-bernoulli-generator 1) 8)))

(testing-registry-case
 'categorical-zero-weights '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 246)
(test-equal 'categorical-zero-weights
             '(1 1 1 1 1 1 1 1 1 1 1 1)
             (generator->list (make-categorical-generator '#(0 3 0)) 12)))

(testing-registry-case
 'geometric-one '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 253)
(test-equal 'geometric-one
             '(1 1 1 1 1 1 1 1)
             (generator->list (make-geometric-generator 1) 8)))

(testing-registry-case
 'binomial-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 260)
(test-assert 'binomial-generator-range
             (values-in-range?
             (generator->list (make-binomial-generator 8 0.25) 100)
             0
             9)))

(testing-registry-case
 'normal-generator-real '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 269)
(test-assert 'normal-generator-real
             (real? ((make-normal-generator 2.0 0.5)))))

(testing-registry-case
 'exponential-generator-positive '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 275)
(test-assert 'exponential-generator-positive
             (< 0 ((make-exponential-generator 2.0)))))

(testing-registry-case
 'poisson-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 281)
(test-assert 'poisson-generator-range
             (values-in-range?
             (generator->list (make-poisson-generator 4.0) 100)
             0
             100)))

(testing-registry-case
 'zipf-generator-range '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 290)
(test-assert 'zipf-generator-range
             (values-in-range?
             (generator->list (make-zipf-generator 5) 100)
             1
             6)))

(testing-registry-case
 'sphere-generator-dimension '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 299)
(let ((point ((make-sphere-generator 2))))
  (test-equal 'sphere-generator-dimension
             3
             (vector-length point))
  (check-near 'sphere-generator-unit-norm
              (vector-sum-squares point)
              1.0)))

(testing-registry-case
 'ellipsoid-generator-dimension '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 310)
(let* ((axes '#(2.0 3.0 4.0))
       (point ((make-ellipsoid-generator axes))))
  (test-equal 'ellipsoid-generator-dimension
             3
             (vector-length point))
  (check-near 'ellipsoid-generator-surface
              (ellipsoid-sum point axes)
              1.0)))

(testing-registry-case
 'ball-generator-dimension '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 322)
(let ((point ((make-ball-generator 3))))
  (test-equal 'ball-generator-dimension
             3
             (vector-length point))
  (test-assert 'ball-generator-inside-unit-ball
             (<= (vector-sum-squares point) 1.0))))

(testing-registry-case
 'gsampling-single-generator '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 332)
(test-equal 'gsampling-single-generator
             '(a b #t #t)
             (let ((sample (gsampling (generator 'a 'b))))
         (list (sample) (sample) (eof-object? (sample)) (eof-object? (sample))))))

(testing-registry-case
 'invalid-range-raises '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 340)
(test-assert 'invalid-range-raises
             (raises? (lambda () (make-random-integer-generator 1 1)))))

(testing-registry-case
 'invalid-char-source-raises '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 346)
(test-assert 'invalid-char-source-raises
             (raises? (lambda () (make-random-char-generator "")))))

(testing-registry-case
 'invalid-categorical-weights-raises '(portable stdlib)
 ("stdlib-random-data-generators-test.scm" 352)
(test-assert 'invalid-categorical-weights-raises
             (raises? (lambda () (make-categorical-generator '#(0 0))))))

(testing-runner-main "Stdlib Random Data Generators portable tests" (command-line))
