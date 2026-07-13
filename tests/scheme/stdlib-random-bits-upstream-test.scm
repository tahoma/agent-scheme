;;; Adapted upstream SRFI 27 random-bits confidence tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2002 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (stdlib random-bits)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Initial default source state, restored after this file mutates it.
(define saved-default-random-source-state
  (random-source-state-ref default-random-source))

(define (my-random-integer n)
  "Return a random integer below N and check the upstream range assertion."
  (let ((x (random-integer n)))
    (test-assert 'random-integer-range (<= 0 x (- n 1)))
    x))

(define (my-random-real)
  "Return a random real and check the upstream open-interval assertion."
  (let ((x (random-real)))
    (test-assert 'random-real-range (< 0 x 1))
    x))

(define (check-basics-1)
  "Run the upstream `check-basics-1' confidence checks."
  ;; Generate increasingly large numbers.
  (do ((k 0 (+ k 1))
       (n 1 (* n 2)))
      ((> k 1024))
    (my-random-integer n))

  ;; Generate a small batch of reals.
  (do ((k 0 (+ k 1))
       (x (my-random-real) (+ x (my-random-real))))
      ((= k 1000)
       x))

  ;; Get and set the state.
  (let* ((state1 (random-source-state-ref default-random-source))
         (x1 (my-random-integer (expt 2 32)))
         (state2 (random-source-state-ref default-random-source))
         (x2 (my-random-integer (expt 2 32))))
    (random-source-state-set! default-random-source state1)
    (let ((y1 (my-random-integer (expt 2 32))))
      (test-equal 'state-get-set-first x1 y1))
    (random-source-state-set! default-random-source state2)
    (let ((y2 (my-random-integer (expt 2 32))))
      (test-equal 'state-get-set-second x2 y2)))

  ;; Randomize the source.
  (let* ((state1 (random-source-state-ref default-random-source))
         (x1 (my-random-integer (expt 2 32))))
    (random-source-state-set! default-random-source state1)
    (random-source-randomize! default-random-source)
    (let ((y1 (my-random-integer (expt 2 32))))
      (test-assert 'random-source-randomize-changed-stream (not (= x1 y1)))))

  ;; Pseudo-randomize the source.
  (let* ((state1 (random-source-state-ref default-random-source))
         (x1 (my-random-integer (expt 2 32))))
    (random-source-state-set! default-random-source state1)
    (random-source-pseudo-randomize! default-random-source 0 1)
    (let ((y1 (my-random-integer (expt 2 32))))
      (test-assert 'pseudo-randomize-substream-changed-stream (not (= x1 y1))))
    (random-source-state-set! default-random-source state1)
    (random-source-pseudo-randomize! default-random-source 1 0)
    (let ((y1 (my-random-integer (expt 2 32))))
      (test-assert 'pseudo-randomize-stream-changed-stream (not (= x1 y1))))))

(define (check-mrg32k3a-state)
  "Run the deterministic MRG32k3a state checks from upstream `check-mrg32k3a'."
  (let* ((s (make-random-source))
         (state1 (random-source-state-ref s))
         (rand (random-source-make-reals s)))
    (random-source-state-set! s '(lecuyer-mrg32k3a 1 0 0 1 0 0))
    (do ((k 0 (+ k 1)))
        ((= k 16)
         (test-equal 'mrg32k3a-a16-initial-state
                     state1
                     (random-source-state-ref s)))
      (rand)))
  (let ((s (make-random-source)))
    (random-source-pseudo-randomize! s 1 2)
    (test-equal
     'mrg32k3a-pseudo-randomize-1-2-state
     '(lecuyer-mrg32k3a
       1250826159
       3004357423
       431373563
       3322526864
       623307378
       2983662421)
     (random-source-state-ref s))))

(testing-registry-case
 'random-bits-upstream-basics '(portable stdlib upstream)
 ("stdlib-random-bits-upstream-test.scm" 101)
 (dynamic-wind
  (lambda () #t)
  check-basics-1
  (lambda ()
    (random-source-state-set!
     default-random-source saved-default-random-source-state))))

(testing-registry-case
 'random-bits-upstream-mrg32k3a '(portable stdlib upstream)
 ("stdlib-random-bits-upstream-test.scm" 111)
 (check-mrg32k3a-state))

(testing-runner-main "SRFI 27 upstream confidence tests" (command-line))
