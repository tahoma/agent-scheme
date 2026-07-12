;;; Adapted upstream SRFI 27 random-bits confidence tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2002 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib random-bits))

;; Number of failed adapted upstream confidence checks seen so far.
(define failures 0)

;; Initial default source state, restored after this file mutates it.
(define saved-default-random-source-state
  (random-source-state-ref default-random-source))

(define (record-failure name detail)
  "Record one failed adapted SRFI 27 confidence check."
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": ")
  (write detail)
  (newline))

(define (check-true name value)
  "Record failure unless VALUE is true."
  (if (not value)
      (record-failure name value)))

(define (check-equal name actual expected)
  "Record failure unless ACTUAL equals EXPECTED."
  (if (not (equal? actual expected))
      (record-failure name (list 'expected expected 'actual actual))))

(define (my-random-integer n)
  "Return a random integer below N and check the upstream range assertion."
  (let ((x (random-integer n)))
    (if (<= 0 x (- n 1))
        x
        (begin
          (record-failure 'random-integer-range (list n x))
          x))))

(define (my-random-real)
  "Return a random real and check the upstream open-interval assertion."
  (let ((x (random-real)))
    (if (< 0 x 1)
        x
        (begin
          (record-failure 'random-real-range x)
          x))))

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
      (check-equal 'state-get-set-first y1 x1))
    (random-source-state-set! default-random-source state2)
    (let ((y2 (my-random-integer (expt 2 32))))
      (check-equal 'state-get-set-second y2 x2)))

  ;; Randomize the source.
  (let* ((state1 (random-source-state-ref default-random-source))
         (x1 (my-random-integer (expt 2 32))))
    (random-source-state-set! default-random-source state1)
    (random-source-randomize! default-random-source)
    (let ((y1 (my-random-integer (expt 2 32))))
      (check-true 'random-source-randomize-changed-stream (not (= x1 y1)))))

  ;; Pseudo-randomize the source.
  (let* ((state1 (random-source-state-ref default-random-source))
         (x1 (my-random-integer (expt 2 32))))
    (random-source-state-set! default-random-source state1)
    (random-source-pseudo-randomize! default-random-source 0 1)
    (let ((y1 (my-random-integer (expt 2 32))))
      (check-true 'pseudo-randomize-substream-changed-stream (not (= x1 y1))))
    (random-source-state-set! default-random-source state1)
    (random-source-pseudo-randomize! default-random-source 1 0)
    (let ((y1 (my-random-integer (expt 2 32))))
      (check-true 'pseudo-randomize-stream-changed-stream (not (= x1 y1))))))

(define (check-mrg32k3a-state)
  "Run the deterministic MRG32k3a state checks from upstream `check-mrg32k3a'."
  (let* ((s (make-random-source))
         (state1 (random-source-state-ref s))
         (rand (random-source-make-reals s)))
    (random-source-state-set! s '(lecuyer-mrg32k3a 1 0 0 1 0 0))
    (do ((k 0 (+ k 1)))
        ((= k 16)
         (check-equal 'mrg32k3a-a16-initial-state
                      (random-source-state-ref s)
                      state1))
      (rand)))
  (let ((s (make-random-source)))
    (random-source-pseudo-randomize! s 1 2)
    (check-equal
     'mrg32k3a-pseudo-randomize-1-2-state
     (random-source-state-ref s)
     '(lecuyer-mrg32k3a
       1250826159
       3004357423
       431373563
       3322526864
       623307378
       2983662421))))

(define (finish-upstream-random-bits-tests)
  "Report the adapted upstream SRFI 27 confidence result."
  (random-source-state-set! default-random-source saved-default-random-source-state)
  (if (= failures 0)
      (begin
        (display "Adapted upstream SRFI 27 confidence tests passed")
        (newline))
      (begin
        (display failures)
        (display " adapted upstream SRFI 27 confidence test failure(s)")
        (newline)
        (error "adapted upstream SRFI 27 confidence tests failed" failures))))

(check-basics-1)
(check-mrg32k3a-state)
(finish-upstream-random-bits-tests)
