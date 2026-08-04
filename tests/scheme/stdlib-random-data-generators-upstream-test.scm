;;; Adapted upstream SRFI 194 statistical tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2020 Arvydas Silanskas
;; SPDX-FileCopyrightText: 2020 Bradley Lucier
;; SPDX-FileCopyrightText: 2020 Linas Vepštas
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 194 test fixtures at
;;; https://github.com/scheme-requests-for-implementation/srfi-194.

(import (scheme base)
        (scheme cxr)
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

(define (check-near name actual expected tolerance)
  "Assert that ACTUAL is within TOLERANCE of EXPECTED."
  (test-approximate name expected actual tolerance))

(define (check-ratio-near name actual expected tolerance)
  "Record failure unless ACTUAL/EXPECTED is within TOLERANCE of 1."
  (if (= expected 0)
      (test-equal name expected actual)
      (check-near name (/ actual expected) 1.0 tolerance)))

(define (raises? thunk)
  "Return #t when THUNK raises an exception."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (with-seeded-random-source stream substream thunk)
  "Call THUNK while SRFI 194 generator constructors use a deterministic source\
."
  (let ((source (make-random-source)))
    (random-source-pseudo-randomize! source stream substream)
    (with-random-source source thunk)))

(define (generator->fixed-list generator count)
  "Return COUNT values from GENERATOR as a list."
  (let loop ((remaining count) (values '()))
    (if (= remaining 0)
        (reverse values)
        (loop (- remaining 1) (cons (generator) values)))))

(define (generator-count-if generator count predicate)
  "Count how many of COUNT values from GENERATOR satisfy PREDICATE."
  (let loop ((remaining count) (matches 0))
    (if (= remaining 0)
        matches
        (loop (- remaining 1)
              (if (predicate (generator)) (+ matches 1) matches)))))

(define (generator-mean generator count)
  "Return the arithmetic mean of COUNT values from GENERATOR."
  (let loop ((remaining count) (sum 0.0))
    (if (= remaining 0)
        (/ sum count)
        (loop (- remaining 1) (+ sum (generator))))))

(define (generator-mean-and-variance generator count)
  "Return mean and variance estimates for COUNT values from GENERATOR."
  (let loop ((remaining count) (sum 0.0) (sum-squares 0.0))
    (if (= remaining 0)
        (let ((mean (/ sum count)))
          (list mean (- (/ sum-squares count) (* mean mean))))
        (let ((value (generator)))
          (loop (- remaining 1)
                (+ sum value)
                (+ sum-squares (* value value)))))))

(define (values-in-range? values lower upper)
  "Return #t when VALUES are all in `[LOWER, UPPER)'."
  (let loop ((rest values))
    (cond
     ((null? rest) #t)
     ((and (>= (car rest) lower) (< (car rest) upper))
      (loop (cdr rest)))
     (else #f))))

(define (all-real-values-in-range? values lower upper)
  "Return #t when VALUES are all real numbers in `[LOWER, UPPER]'."
  (let loop ((rest values))
    (cond
     ((null? rest) #t)
     ((and (real? (car rest))
           (>= (car rest) lower)
           (<= (car rest) upper))
      (loop (cdr rest)))
     (else #f))))

(define (vector-sum vector)
  "Return the sum of VECTOR elements."
  (let loop ((index 0) (sum 0.0))
    (if (= index (vector-length vector))
        sum
        (loop (+ index 1) (+ sum (vector-ref vector index))))))

(define (vector-sum-squares vector)
  "Return the sum of squared VECTOR elements."
  (let loop ((index 0) (sum 0.0))
    (if (= index (vector-length vector))
        sum
        (let ((value (vector-ref vector index)))
          (loop (+ index 1) (+ sum (* value value)))))))

(define (ellipsoid-sum point axes)
  "Return the ellipsoid surface equation sum for POINT and AXES."
  (let loop ((index 0) (sum 0.0))
    (if (= index (vector-length axes))
        sum
        (let ((scaled (/ (vector-ref point index) (vector-ref axes index))))
          (loop (+ index 1) (+ sum (* scaled scaled)))))))

(define (vector-mean vectors dimension count)
  "Return the sample mean for DIMENSION over VECTORS."
  (let loop ((rest vectors) (sum 0.0))
    (if (null? rest)
        (/ sum count)
        (loop (cdr rest) (+ sum (vector-ref (car rest) dimension))))))

(define (categorical-counts generator categories samples)
  "Return a vector of category counts from GENERATOR."
  (let ((counts (make-vector categories 0)))
    (let loop ((remaining samples))
      (if (= remaining 0)
          counts
          (let ((index (generator)))
            (vector-set! counts index (+ 1 (vector-ref counts index)))
            (loop (- remaining 1)))))))

(define (zipf-expected-vector n exponent deformation)
  "Return exact expected Zipf probabilities for N, EXPONENT, and DEFORMATION."
  (let ((weights (make-vector n 0.0)))
    (let loop ((index 0) (sum 0.0))
      (if (= index n)
          (let ((expected (make-vector n 0.0)))
            (let normalize ((offset 0))
              (if (= offset n)
                  expected
                  (begin
                    (vector-set! expected offset (/ (vector-ref weights offset)
                      sum))
                    (normalize (+ offset 1))))))
          (let* ((rank (+ index 1))
                 (weight (expt (+ rank deformation) (- exponent))))
            (vector-set! weights index weight)
            (loop (+ index 1) (+ sum weight)))))))

(define (check-zipf-distribution name n exponent deformation samples tolerance)
  "Check a sampled Zipf distribution against expected probabilities."
  (with-seeded-random-source
   61
   0
   (lambda ()
     (let* ((counts
             (categorical-counts
              (let ((generator (make-zipf-generator n exponent deformation)))
                (lambda () (- (generator) 1)))
              n
              samples))
            (expected (zipf-expected-vector n exponent deformation)))
       (let loop ((index 0))
         (if (< index n)
             (let ((actual (/ (vector-ref counts index) samples)))
               (check-ratio-near
                (list name (+ index 1))
                actual
                (vector-ref expected index)
                tolerance)
               (loop (+ index 1)))))))))

;; Fixed-width integer generator cases: name, constructor, lower bound, upper
;; bound.
(define fixed-integer-cases
  (list
   (list 'u1 make-random-u1-generator 0 2)
   (list 'u8 make-random-u8-generator 0 256)
   (list 's8 make-random-s8-generator -128 128)
   (list 'u16 make-random-u16-generator 0 65536)
   (list 's16 make-random-s16-generator -32768 32768)
   (list 'u32 make-random-u32-generator 0 (expt 2 32))
   (list 's32 make-random-s32-generator (- (expt 2 31)) (expt 2 31))
   (list 'u64 make-random-u64-generator 0 (expt 2 64))
   (list 's64 make-random-s64-generator (- (expt 2 63)) (expt 2 63))))

(testing-registry-case
 'stdlib-random-data-generators-upstream-case-1 '(portable stdlib)
(let loop ((index 0) (cases fixed-integer-cases))
  (if (not (null? cases))
      (let ((case (car cases)))
        (with-seeded-random-source
         10
         index
         (lambda ()
           (test-assert (list 'fixed-integer-range (car case))
             (values-in-range?
             (generator->fixed-list ((cadr case)) 200)
             (caddr case)
             (cadddr case)))))
        (loop (+ index 1) (cdr cases))))))

(testing-registry-case
 'seeded-integer-replay '(portable stdlib)
(with-seeded-random-source
 11
 0
 (lambda ()
   (let ((left
          (generator->fixed-list (make-random-integer-generator -100 100) 16)))
     (with-seeded-random-source
      11
      0
      (lambda ()
        (test-equal 'seeded-integer-replay
             left
             (generator->fixed-list (make-random-integer-generator -100 100)
               16))))))))

(testing-registry-case
 'random-real-generator-broad-range '(portable stdlib)
(with-seeded-random-source
 12
 0
 (lambda ()
   (let ((values (generator->fixed-list (make-random-real-generator -2.5 7.5)
     400)))
     (test-assert 'random-real-generator-broad-range
             (all-real-values-in-range? values -2.5 7.5))
     (test-assert 'random-real-generator-hits-lower-half
             (not (= 0 (generator-count-if
                            (let ((rest values))
                              (lambda ()
                                (let ((value (car rest)))
                                  (set! rest (cdr rest))
                                  value)))
                            400
                            (lambda (value) (< value 2.5))))))))))

(testing-registry-case
 'bernoulli-statistical-frequency '(portable stdlib)
(with-seeded-random-source
 13
 0
 (lambda ()
   (let ((successes
          (generator-count-if (make-bernoulli-generator 0.7)
                              3000
                              (lambda (value) (= value 1)))))
     (check-ratio-near 'bernoulli-statistical-frequency successes 2100
       0.12)))))

(testing-registry-case
 'categorical-first-frequency '(portable stdlib)
(with-seeded-random-source
 14
 0
 (lambda ()
   (let ((counts (categorical-counts (make-categorical-generator '#(20 50 30))
                                     3
                                     5000)))
     (check-ratio-near 'categorical-first-frequency
                       (vector-ref counts 0)
                       1000
                       0.15)
     (check-ratio-near 'categorical-second-frequency
                       (vector-ref counts 1)
                       2500
                       0.12)
     (check-ratio-near 'categorical-third-frequency
                       (vector-ref counts 2)
                       1500
                       0.15)))))

(testing-registry-case
 'binomial-zero-frequency '(portable stdlib)
(with-seeded-random-source
 15
 0
 (lambda ()
   (let ((counts (categorical-counts (make-binomial-generator 10 0.25) 11
     8000)))
     (check-ratio-near 'binomial-zero-frequency (vector-ref counts 0) 450.508
       0.30)
     (check-ratio-near 'binomial-two-frequency (vector-ref counts 2) 2252.541
       0.20)
     (check-ratio-near 'binomial-five-frequency (vector-ref counts 5) 467.011
       0.30)))))

(testing-registry-case
 'normal-mean '(portable stdlib)
(with-seeded-random-source
 16
 0
 (lambda ()
   (let ((summary (generator-mean-and-variance (make-normal-generator 2.0 0.5)
                                               6000)))
     (check-near 'normal-mean (car summary) 2.0 0.05)
     (check-near 'normal-variance (cadr summary) 0.25 0.05)))))

(testing-registry-case
 'exponential-mean '(portable stdlib)
(with-seeded-random-source
 17
 0
 (lambda ()
   (check-near 'exponential-mean
               (generator-mean (make-exponential-generator 1.5) 6000)
               1.5
               0.08))))

(testing-registry-case
 'geometric-mean '(portable stdlib)
(with-seeded-random-source
 18
 0
 (lambda ()
   (check-near 'geometric-mean
               (generator-mean (make-geometric-generator 0.4) 10000)
               2.5
               0.12))))

(testing-registry-case
 'poisson-small-mean '(portable stdlib)
(with-seeded-random-source
 19
 0
 (lambda ()
   (let ((small-summary (generator-mean-and-variance (make-poisson-generator
     4.0)
                                                     8000))
         (large-summary (generator-mean-and-variance (make-poisson-generator
           40.0)
                                                     8000)))
     (check-near 'poisson-small-mean (car small-summary) 4.0 0.15)
     (check-near 'poisson-small-variance (cadr small-summary) 4.0 0.35)
     (check-near 'poisson-large-mean (car large-summary) 40.0 0.5)
     (check-near 'poisson-large-variance (cadr large-summary) 40.0 1.5)))))

(testing-registry-case
 'stdlib-random-data-generators-upstream-case-11 '(portable stdlib)
(check-zipf-distribution 'zipf-harmonic 8 1.0 0.0 8000 0.25))
(testing-registry-case
 'stdlib-random-data-generators-upstream-case-12 '(portable stdlib)
(check-zipf-distribution 'zipf-hurwicz 8 1.2 0.5 8000 0.25))
(testing-registry-case
 'stdlib-random-data-generators-upstream-case-13 '(portable stdlib)
(check-zipf-distribution 'zipf-flat-ish 8 0.1 0.0 8000 0.25))

(testing-registry-case
 'sphere-point-on-surface '(portable stdlib)
(with-seeded-random-source
 20
 0
 (lambda ()
   (let ((sphere-points (generator->fixed-list (make-sphere-generator 3) 600)))
     (for-each
      (lambda (point)
        (check-near 'sphere-point-on-surface (vector-sum-squares point) 1.0
          0.000000001))
      sphere-points)
     (check-near 'sphere-first-coordinate-mean
                 (vector-mean sphere-points 0 600)
                 0.0
                 0.08)
     (check-near 'sphere-second-coordinate-mean
                 (vector-mean sphere-points 1 600)
                 0.0
                 0.08)))))

(testing-registry-case
 'ellipsoid-point-on-surface '(portable stdlib)
(with-seeded-random-source
 21
 0
 (lambda ()
   (let* ((axes '#(2.0 5.0 7.0))
          (points (generator->fixed-list (make-ellipsoid-generator axes) 500)))
     (for-each
      (lambda (point)
        (check-near 'ellipsoid-point-on-surface (ellipsoid-sum point axes) 1.0
          0.000000001))
      points)
     (check-near 'ellipsoid-first-coordinate-mean
                 (vector-mean points 0 500)
                 0.0
                 0.5)))))

(testing-registry-case
 'ball-point-inside-ellipsoid '(portable stdlib)
(with-seeded-random-source
 22
 0
 (lambda ()
   (let* ((axes '#(2.0 5.0 7.0))
          (points (generator->fixed-list (make-ball-generator axes) 500)))
     (for-each
      (lambda (point)
        (test-assert 'ball-point-inside-ellipsoid
             (<= (ellipsoid-sum point axes) 1.0)))
      points)
     (test-assert 'ball-reaches-inner-radius
             (< 0
                    (generator-count-if
                     (let ((rest points))
                       (lambda ()
                         (let ((value (car rest)))
                           (set! rest (cdr rest))
                           value)))
                     500
                     (lambda (point) (< (ellipsoid-sum point axes) 0.25)))))
     (test-assert 'ball-reaches-outer-radius
             (< 0
                    (generator-count-if
                     (let ((rest points))
                       (lambda ()
                         (let ((value (car rest)))
                           (set! rest (cdr rest))
                           value)))
                     500
                     (lambda (point) (> (ellipsoid-sum point axes)
                       0.75)))))))))

(testing-registry-case
 'gsampling-empty '(portable stdlib)
(test-equal 'gsampling-empty
             #t
             (eof-object? ((gsampling)))))

(testing-registry-case
 'gsampling-mixed-finite-generators '(portable stdlib)
(test-assert 'gsampling-mixed-finite-generators
             (let ((sample (gsampling (generator 'a) (generator) (generator 'b
               'c))))
              (let* ((values (generator->fixed-list sample 4))
                     (draws (list (car values) (cadr values) (caddr values))))
                (and (member 'a draws)
                     (member 'b draws)
                     (member 'c draws)
                     (eof-object? (cadddr values)))))))

(testing-registry-case
 'stdlib-random-data-generators-upstream-case-19 '(portable stdlib)
(for-each
 (lambda (case)
   (test-assert (car case) (raises? (cadr case))))
 (list
  (list 'invalid-with-random-source
        (lambda () (with-random-source 'not-a-source (lambda () #t))))
  (list 'invalid-random-source-generator
        (lambda () (make-random-source-generator -1)))
  (list 'invalid-integer-lower
        (lambda () (make-random-integer-generator 0.0 1)))
  (list 'invalid-integer-empty-range
        (lambda () (make-random-integer-generator 1 1)))
  (list 'invalid-clamp-real-bounds
        (lambda () (clamp-real-number 2.0 1.0 1.5)))
  (list 'invalid-random-real-range
        (lambda () (make-random-real-generator 1.0 1.0)))
  (list 'invalid-rectangular-range
        (lambda () (make-random-rectangular-generator 1.0 0.0 0.0 1.0)))
  (list 'invalid-polar-origin
        (lambda () (make-random-polar-generator 'origin 0.0 1.0)))
  (list 'invalid-polar-magnitude
        (lambda () (make-random-polar-generator -1.0 1.0)))
  (list 'invalid-polar-angle
        (lambda () (make-random-polar-generator 0.0 1.0 2.0 2.0)))
  (list 'invalid-char-source
        (lambda () (make-random-char-generator "")))
  (list 'invalid-string-length
        (lambda () (make-random-string-generator 0 "abc")))
  (list 'invalid-string-source
        (lambda () (make-random-string-generator 4 "")))
  (list 'invalid-bernoulli-low
        (lambda () (make-bernoulli-generator -0.1)))
  (list 'invalid-bernoulli-high
        (lambda () (make-bernoulli-generator 1.1)))
  (list 'invalid-categorical-empty
        (lambda () (make-categorical-generator '#())))
  (list 'invalid-categorical-zero
        (lambda () (make-categorical-generator '#(0 0))))
  (list 'invalid-categorical-negative
        (lambda () (make-categorical-generator '#(1 -1))))
  (list 'invalid-normal-deviation
        (lambda () (make-normal-generator 0.0 0.0)))
  (list 'invalid-exponential-mean
        (lambda () (make-exponential-generator 0.0)))
  (list 'invalid-geometric-low
        (lambda () (make-geometric-generator 0.0)))
  (list 'invalid-geometric-high
        (lambda () (make-geometric-generator 1.1)))
  (list 'invalid-poisson-mean
        (lambda () (make-poisson-generator 0.0)))
  (list 'invalid-binomial-count
        (lambda () (make-binomial-generator 0 0.5)))
  (list 'invalid-binomial-probability
        (lambda () (make-binomial-generator 5 1.1)))
  (list 'invalid-zipf-count
        (lambda () (make-zipf-generator 0)))
  (list 'invalid-zipf-exponent
        (lambda () (make-zipf-generator 5 -10.0)))
  (list 'invalid-zipf-deformation
        (lambda () (make-zipf-generator 5 1.0 -0.5)))
  (list 'invalid-sphere-dimension
        (lambda () (make-sphere-generator 0)))
  (list 'invalid-ellipsoid-axes
        (lambda () (make-ellipsoid-generator '#(1.0 0.0))))
  (list 'invalid-ball-dimension
        (lambda () (make-ball-generator 0)))
  (list 'invalid-ball-axes
        (lambda () (make-ball-generator '#(1.0 -1.0)))))))

(testing-runner-main "Stdlib Random Data Generators Upstream portable tests"
  (command-line))
