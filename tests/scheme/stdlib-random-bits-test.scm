;;; Portable SRFI 27 random-bits stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib random-bits))

;; Number of failed SRFI 27 checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed SRFI 27 check."
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

(define (draw-integers source ranges)
  "Return random integers drawn from SOURCE for each range in RANGES."
  (let ((rand (random-source-make-integers source)))
    (let loop ((rest ranges) (values '()))
      (if (null? rest)
          (reverse values)
          (loop (cdr rest) (cons (rand (car rest)) values))))))

(define (finish-random-bits-tests)
  "Report the SRFI 27 random-bits result."
  (if (= failures 0)
      (begin
        (display "SRFI 27 random-bits tests passed")
        (newline))
      (begin
        (display failures)
        (display " SRFI 27 random-bits test failure(s)")
        (newline)
        (error "SRFI 27 random-bits tests failed" failures))))

;; First fresh random source under test.
(define source-a (make-random-source))

;; Second fresh random source under test.
(define source-b (make-random-source))

;; Integer ranges used for deterministic stream checks.
(define ranges '(2 3 5 17 97 1000000))

(check 'random-source-predicate-true
       (random-source? source-a)
       #t)

(check 'random-source-predicate-false
       (random-source? '(not a source))
       #f)

(check 'fresh-sources-share-deterministic-stream
       (draw-integers source-a ranges)
       (draw-integers source-b ranges))

(let* ((source (make-random-source))
       (state (random-source-state-ref source))
       (first (draw-integers source ranges)))
  (random-source-state-set! source state)
  (check 'state-ref-set-replays-stream
         (draw-integers source ranges)
         first)
  (check 'state-external-representation
         (car state)
         'lecuyer-mrg32k3a))

(let ((left (make-random-source))
      (right (make-random-source)))
  (random-source-pseudo-randomize! left 7 11)
  (random-source-pseudo-randomize! right 7 11)
  (check 'pseudo-randomize-is-deterministic
         (draw-integers left ranges)
         (draw-integers right ranges)))

(let* ((source (make-random-source))
       (rand-real (random-source-make-reals source))
       (value (rand-real)))
  (check-true 'random-real-is-in-range
              (and (real? value) (< 0 value) (< value 1))))

(let* ((source (make-random-source))
       (rand-real (random-source-make-reals source 1/1024))
       (value (rand-real)))
  (check-true 'random-real-with-unit-is-in-range
              (and (real? value) (< 0 value) (< value 1))))

(check 'default-random-source-is-source
       (random-source? default-random-source)
       #t)

(check-true 'random-integer-default-range
            (let ((value (random-integer 37)))
              (and (integer? value) (<= 0 value) (< value 37))))

(check-true 'random-real-default-range
            (let ((value (random-real)))
              (and (real? value) (< 0 value) (< value 1))))

(finish-random-bits-tests)
