;;; Portable random distribution stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme inexact)
        (scheme write)
        (stdlib random-bits)
        (stdlib random-distributions)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (check-near name actual expected)
  "Compare inexact ACTUAL and EXPECTED with a small tolerance."
  (test-approximate name expected actual 0.000000000001))

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

(define (reference-permutation source n)
  "Return the Fisher-Yates permutation generated from SOURCE."
  (let ((rand (random-source-make-integers source)))
    (let ((result (make-vector n 0)))
      (do ((i 0 (+ i 1)))
          ((= i n))
        (vector-set! result i i))
      (do ((k n (- k 1)))
          ((= k 1) result)
        (let* ((i (- k 1))
               (j (rand k))
               (xi (vector-ref result i))
               (xj (vector-ref result j)))
          (vector-set! result i xj)
          (vector-set! result j xi))))))

(define (vector-value-count vector value)
  "Return how often VALUE appears in VECTOR."
  (let loop ((index 0) (count 0))
    (cond
     ((= index (vector-length vector))
      count)
     ((equal? (vector-ref vector index) value)
      (loop (+ index 1) (+ count 1)))
     (else
      (loop (+ index 1) count)))))

(define (permutation-vector? vector n)
  "Return #t when VECTOR contains each integer in [0, N) exactly once."
  (and (= (vector-length vector) n)
       (let loop ((value 0))
         (cond
          ((= value n) #t)
          ((= (vector-value-count vector value) 1)
           (loop (+ value 1)))
          (else #f)))))

(define (reference-exponential source unit mu)
  "Return the inverse-transform exponential result from SOURCE."
  (let ((rand (if unit
                  (random-source-make-reals source unit)
                  (random-source-make-reals source))))
    (- (* mu (log (rand))))))

(define (reference-make-normals source . unit)
  "Return the polar-method normal generator used as the test oracle."
  (let ((rand (apply random-source-make-reals source unit))
        (next #f))
    (lambda (mu sigma)
      (if next
          (let ((result next))
            (set! next #f)
            (+ mu (* sigma result)))
          (let loop ()
            (let* ((v1 (- (* 2 (rand)) 1))
                   (v2 (- (* 2 (rand)) 1))
                   (radius-squared (+ (* v1 v1) (* v2 v2))))
              (if (or (<= radius-squared 0)
                      (>= radius-squared 1))
                  (loop)
                  (let ((scale (sqrt (/ (* -2 (log radius-squared))
                                        radius-squared))))
                    (set! next (* scale v2))
                    (+ mu (* sigma scale v1))))))))))

(testing-registry-case
 'source-permutation-reference '(portable stdlib)
(let* ((state (random-source-state-ref (make-random-source)))
       (actual-source (source-at state))
       (expected-source (source-at state))
       (make-permutation (random-source-make-permutations actual-source))
       (actual (make-permutation 8))
       (expected (reference-permutation expected-source 8)))
  (test-equal 'source-permutation-reference expected actual)
  (test-assert 'source-permutation-has-each-image-once
             (permutation-vector? actual 8))))

(testing-registry-case
 'random-permutation-zero-length '(portable stdlib)
(test-equal 'random-permutation-zero-length
             0
             (vector-length (random-permutation 0))))

(testing-registry-case
 'random-permutation-has-each-image-once '(portable stdlib)
(test-assert 'random-permutation-has-each-image-once
             (permutation-vector? (random-permutation 11) 11)))

(testing-registry-case
 'source-exponential-reference '(portable stdlib)
(let* ((state (random-source-state-ref (make-random-source)))
       (actual-source (source-at state))
       (expected-source (source-at state))
       (make-exponential (random-source-make-exponentials actual-source))
       (actual (make-exponential 3.5))
       (expected (reference-exponential expected-source #f 3.5)))
  (check-near 'source-exponential-reference actual expected)))

(testing-registry-case
 'source-exponential-unit-reference '(portable stdlib)
(let* ((state (random-source-state-ref (make-random-source)))
       (actual-source (source-at state))
       (expected-source (source-at state))
       (make-exponential
        (random-source-make-exponentials actual-source 1/1024))
       (actual (make-exponential 0.75))
       (expected (reference-exponential expected-source 1/1024 0.75)))
  (check-near 'source-exponential-unit-reference actual expected)))

(testing-registry-case
 'random-exponential-positive '(portable stdlib)
(test-assert 'random-exponential-positive
             (< 0 (random-exponential 2.0))))

(testing-registry-case
 'random-exponential-rejects-non-positive-mean '(portable stdlib)
(test-assert 'random-exponential-rejects-non-positive-mean
             (raises? (lambda () (random-exponential 0)))))

(testing-registry-case
 'source-normal-first-reference '(portable stdlib)
(let* ((state (random-source-state-ref (make-random-source)))
       (actual-source (source-at state))
       (expected-source (source-at state))
       (make-normal (random-source-make-normals actual-source))
       (reference-normal (reference-make-normals expected-source))
       (actual-first (make-normal 5.0 2.0))
       (expected-first (reference-normal 5.0 2.0))
       (state-after-first (random-source-state-ref actual-source))
       (actual-second (make-normal 5.0 2.0))
       (expected-second (reference-normal 5.0 2.0))
       (state-after-second (random-source-state-ref actual-source)))
  (check-near 'source-normal-first-reference actual-first expected-first)
  (check-near 'source-normal-second-reference actual-second expected-second)
  (test-equal 'source-normal-second-result-uses-cache
             state-after-first
             state-after-second)))

(testing-registry-case
 'source-normal-first-result-real '(portable stdlib)
(let* ((state (random-source-state-ref (make-random-source)))
       (source (source-at state))
       (expected-source (source-at state))
       (make-normal (random-source-make-normals source))
       (reference-normal (reference-make-normals expected-source))
       (ignored-actual (make-normal 0.0 1.0))
       (ignored-expected (reference-normal 0.0 1.0))
       (expected-cached (reference-normal 0.0 1.0)))
  (test-assert 'source-normal-first-result-real (real? ignored-actual))
  (test-assert 'source-normal-reference-first-result-real
               (real? ignored-expected))
  (random-source-state-set! source state)
  (check-near 'source-normal-cache-survives-state-reset
              (make-normal 0.0 1.0)
              expected-cached)
  (test-equal 'source-normal-cache-does-not-advance-reset-source
             state
             (random-source-state-ref source))))

(testing-registry-case
 'random-normal-produces-real '(portable stdlib)
(test-assert 'random-normal-produces-real
             (real? (random-normal 0.0 1.0))))

(testing-registry-case
 'random-normal-rejects-negative-deviation '(portable stdlib)
(test-assert 'random-normal-rejects-negative-deviation
             (raises? (lambda () (random-normal 0.0 -1.0)))))

(testing-registry-case
 'random-permutation-rejects-negative-degree '(portable stdlib)
(test-assert 'random-permutation-rejects-negative-degree
             (raises? (lambda () (random-permutation -1)))))

(testing-runner-main "Stdlib Random Distributions portable tests"
  (command-line))
