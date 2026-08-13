;;; Adapted upstream SRFI 117 list-queue tests.
;; SPDX-License-Identifier: BSD-3-Clause
;; SPDX-FileCopyrightText: 2017 Alex Shinn
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Upstream: https://github.com/scheme-requests-for-implementation/srfi-117
;;; Revision: 544dfba159ced777bb2447e73dff67dfed30d76a
;;; Source: list-queues/list-queues-test.scm
;;; Local patches: use Consent's stdlib import and SRFI 64 implementation;
;;; install a fail-closed runner while preserving the upstream assertions.

(import (scheme base)
        (scheme process-context)
        (stdlib list-queue)
        (stdlib testing))

;; Fail-closed runner for the adapted upstream assertions.
(define upstream-runner (test-runner-simple))
(test-runner-current upstream-runner)

(test-begin "list-queues")

(test-begin "list-queues/simple")

(test-equal '(1 1 1) (list-queue-list (make-list-queue '(1 1 1))))

(let* ((x (list-queue 1 2 3))
       (x-list (list 1 2 3))
       (x-with-last (make-list-queue x-list (cddr x-list)))
       (y (list-queue 4 5))
       (z (list-queue-append x y))
       (z2 (list-queue-append! x (list-queue-copy y))))
  (test-equal '(1 2 3) (list-queue-list x-with-last))
  (test-equal 3 (list-queue-back x-with-last))
  (test-assert (list-queue? y))
  (test-equal '(1 2 3 4 5) (list-queue-list z))
  (test-equal '(1 2 3 4 5) (list-queue-list z2))
  (test-equal 1 (list-queue-front z))
  (test-equal 5 (list-queue-back z))
  (list-queue-remove-front! y)
  (test-equal '(5) (list-queue-list y))
  (list-queue-remove-back! y)
  (test-assert (list-queue-empty? y))
  (test-error (list-queue-remove-front! y))
  (test-error (list-queue-remove-back! y))
  (test-equal '(1 2 3 4 5) (list-queue-list z))
  (test-equal '(1 2 3 4 5) (list-queue-remove-all! z2))
  (test-assert (list-queue-empty? z2))
  (list-queue-remove-all! z)
  (list-queue-add-front! z 1)
  (list-queue-add-front! z 0)
  (list-queue-add-back! z 2)
  (list-queue-add-back! z 3)
  (test-equal '(0 1 2 3) (list-queue-list z)))

(test-end "list-queues/simple")

(test-begin "list-queues/whole")

(let* ((a (list-queue 1 2 3))
       (b (list-queue-copy a)))
  (test-equal '(1 2 3) (list-queue-list b))
  (list-queue-add-front! b 0)
  (test-equal '(1 2 3) (list-queue-list a))
  (test-equal 4 (length (list-queue-list b)))
  (let ((c (list-queue-concatenate (list a b))))
    (test-equal '(1 2 3 0 1 2 3) (list-queue-list c))))

(test-end "list-queues/whole")

(test-begin "list-queues/map")

(let* ((r (list-queue 1 2 3))
       (s (list-queue-map (lambda (value) (* value 10)) r))
       (sum 0))
  (test-equal '(10 20 30) (list-queue-list s))
  (list-queue-map! (lambda (value) (+ value 1)) r)
  (test-equal '(2 3 4) (list-queue-list r))
  (list-queue-for-each
   (lambda (value) (set! sum (+ sum value)))
   s)
  (test-equal 60 sum))

(test-end "list-queues/map")

(test-begin "list-queues/conversion")

(let ((queue (list-queue 5 6)))
  (list-queue-set-list! queue (list 1 2))
  (test-equal '(1 2) (list-queue-list queue)))

(let* ((first (list 1 2 3))
       (last (cddr first))
       (queue (make-list-queue first last)))
  (call-with-values
   (lambda () (list-queue-first-last queue))
   (lambda (actual-first actual-last)
     (test-assert (eq? first actual-first))
     (test-assert (eq? last actual-last))))
  (test-equal '(1 2 3) (list-queue-list queue))
  (list-queue-add-front! queue 0)
  (list-queue-add-back! queue 4)
  (test-equal '(0 1 2 3 4) (list-queue-list queue))
  (let ((shared (make-list-queue first last)))
    (test-equal '(1 2 3 4) (list-queue-list shared)))
  (let ((reset (list-queue 5 6)))
    (list-queue-set-list! reset first last)
    (test-equal '(1 2 3 4) (list-queue-list reset))))

(test-end "list-queues/conversion")

(test-begin "list-queues/unfold")

(let ((double (lambda (value) (* value 2)))
      (done? (lambda (value) (> value 3)))
      (add1 (lambda (value) (+ value 1))))
  (test-equal
   '(0 2 4 6)
   (list-queue-list (list-queue-unfold done? double add1 0)))
  (test-equal
   '(6 4 2 0)
   (list-queue-list (list-queue-unfold-right done? double add1 0)))
  (test-equal
   '(0 2 4 6 8)
   (list-queue-list
    (list-queue-unfold done? double add1 0 (list-queue 8))))
  (test-equal
   '(8 6 4 2 0)
   (list-queue-list
    (list-queue-unfold-right done? double add1 0 (list-queue 8)))))

(test-end "list-queues/unfold")
(test-end "list-queues")

(if (or (> (test-runner-fail-count upstream-runner) 0)
        (> (test-runner-xpass-count upstream-runner) 0))
    (error "SRFI 117 upstream tests failed"
           (test-runner-fail-count upstream-runner)
           (test-runner-xpass-count upstream-runner)))
