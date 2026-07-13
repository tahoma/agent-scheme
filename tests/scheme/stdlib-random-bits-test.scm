;;; Portable SRFI 27 random-bits stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib random-bits)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (draw-integers source ranges)
  "Return random integers drawn from SOURCE for each range in RANGES."
  (let ((rand (random-source-make-integers source)))
    (let loop ((rest ranges) (values '()))
      (if (null? rest)
          (reverse values)
          (loop (cdr rest) (cons (rand (car rest)) values))))))

;; First fresh random source under test.
(define source-a (make-random-source))

;; Second fresh random source under test.
(define source-b (make-random-source))

;; Integer ranges used for deterministic stream checks.
(define ranges '(2 3 5 17 97 1000000))

(testing-registry-case
 'random-source-predicate-true '(portable stdlib)
(test-equal 'random-source-predicate-true
             #t
             (random-source? source-a)))

(testing-registry-case
 'random-source-predicate-false '(portable stdlib)
(test-equal 'random-source-predicate-false
             #f
             (random-source? '(not a source))))

(testing-registry-case
 'fresh-sources-share-deterministic-stream '(portable stdlib)
(test-equal 'fresh-sources-share-deterministic-stream
             (draw-integers source-b ranges)
             (draw-integers source-a ranges)))

(testing-registry-case
 'state-ref-set-replays-stream '(portable stdlib)
(let* ((source (make-random-source))
       (state (random-source-state-ref source))
       (first (draw-integers source ranges)))
  (random-source-state-set! source state)
  (test-equal 'state-ref-set-replays-stream
             first
             (draw-integers source ranges))
  (test-equal 'state-external-representation
             'lecuyer-mrg32k3a
             (car state))))

(testing-registry-case
 'pseudo-randomize-is-deterministic '(portable stdlib)
(let ((left (make-random-source))
      (right (make-random-source)))
  (random-source-pseudo-randomize! left 7 11)
  (random-source-pseudo-randomize! right 7 11)
  (test-equal 'pseudo-randomize-is-deterministic
             (draw-integers right ranges)
             (draw-integers left ranges))))

(testing-registry-case
 'random-real-is-in-range '(portable stdlib)
(let* ((source (make-random-source))
       (rand-real (random-source-make-reals source))
       (value (rand-real)))
  (test-assert 'random-real-is-in-range
             (and (real? value) (< 0 value) (< value 1)))))

(testing-registry-case
 'random-real-with-unit-is-in-range '(portable stdlib)
(let* ((source (make-random-source))
       (rand-real (random-source-make-reals source 1/1024))
       (value (rand-real)))
  (test-assert 'random-real-with-unit-is-in-range
             (and (real? value) (< 0 value) (< value 1)))))

(testing-registry-case
 'default-random-source-is-source '(portable stdlib)
(test-equal 'default-random-source-is-source
             #t
             (random-source? default-random-source)))

(testing-registry-case
 'random-integer-default-range '(portable stdlib)
(test-assert 'random-integer-default-range
             (let ((value (random-integer 37)))
              (and (integer? value) (<= 0 value) (< value 37)))))

(testing-registry-case
 'random-real-default-range '(portable stdlib)
(test-assert 'random-real-default-range
             (let ((value (random-real)))
              (and (real? value) (< 0 value) (< value 1)))))

(testing-runner-main "Stdlib Random Bits portable tests" (command-line))
