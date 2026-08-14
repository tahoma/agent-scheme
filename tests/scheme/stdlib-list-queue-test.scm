;;; Portable SRFI 117 list-queue stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (stdlib list-queue)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return true when THUNK raises an exception."
  (guard (condition (else #t))
    (thunk)
    #f))

(define (queue-endpoints queue)
  "Return QUEUE's first and final pairs in a list."
  (call-with-values
   (lambda () (list-queue-first-last queue))
   list))

(testing-registry-case
 'list-queue/construction-and-access '(portable stdlib conformance)
 (test-equal
  'list-queue/construction-and-access
  '(#t #f #t front back (front middle back))
  (let ((empty (list-queue))
        (queue (list-queue 'front 'middle 'back)))
    (list (list-queue? queue)
          (list-queue? '(front middle back))
          (list-queue-empty? empty)
          (list-queue-front queue)
          (list-queue-back queue)
          (list-queue-list queue)))))

(testing-registry-case
 'list-queue/shared-list-identity '(portable stdlib conformance identity)
 (test-equal
  'list-queue/shared-list-identity
  '(#t #t #t (a b c) #t #t)
  (let* ((source (list 'a 'b))
         (source-last (cdr source))
         (queue (make-list-queue source source-last))
         (endpoints (queue-endpoints queue)))
    (list-queue-add-back! queue 'c)
    (let ((removed (list-queue-remove-all! queue)))
      (list (eq? source (car endpoints))
            (eq? source-last (cadr endpoints))
            (eq? source removed)
            source
            (list-queue-empty? queue)
            (equal? removed '(a b c)))))))

(testing-registry-case
 'list-queue/front-and-back-mutation '(portable stdlib conformance)
 (test-equal
  'list-queue/front-and-back-mutation
  '((a b c d) a d (b c) b c)
  (let ((queue (list-queue 'b 'c)))
    (list-queue-add-front! queue 'a)
    (list-queue-add-back! queue 'd)
    (let ((before (list-copy (list-queue-list queue))))
      (let ((front (list-queue-remove-front! queue)))
        (let ((back (list-queue-remove-back! queue)))
          (list before
                front
                back
                (list-queue-list queue)
                (list-queue-front queue)
                (list-queue-back queue))))))))

(testing-registry-case
 'list-queue/singleton-removal '(portable stdlib conformance)
 (test-equal
  'list-queue/singleton-removal
  '(only #t () ())
  (let ((queue (list-queue 'only)))
    (let ((element (list-queue-remove-back! queue)))
      (let ((endpoints (queue-endpoints queue)))
        (list element
              (list-queue-empty? queue)
              (car endpoints)
              (cadr endpoints)))))))

(testing-registry-case
 'list-queue/empty-and-constructor-errors '(portable stdlib conformance)
 (let ((empty (list-queue)))
   (test-assert
    'list-queue/empty-front-error
    (raises? (lambda () (list-queue-front empty))))
   (test-assert
    'list-queue/empty-back-error
    (raises? (lambda () (list-queue-back empty))))
   (test-assert
    'list-queue/empty-remove-front-error
    (raises? (lambda () (list-queue-remove-front! empty))))
   (test-assert
    'list-queue/empty-remove-back-error
    (raises? (lambda () (list-queue-remove-back! empty))))
   (test-assert
    'list-queue/improper-list-error
    (raises? (lambda () (make-list-queue '(a . b)))))
   (test-assert
    'list-queue/inconsistent-explicit-last-error
    (raises? (lambda () (make-list-queue '(a) '()))))))

(testing-registry-case
 'list-queue/set-list-and-copy '(portable stdlib conformance identity)
 (test-equal
  'list-queue/set-list-and-copy
  '((one changed three) (one two three) #t #t)
  (let* ((source (list 'one 'two 'three))
         (queue (list-queue 'old))
         (last (cddr source)))
    (list-queue-set-list! queue source last)
    (let ((copy (list-queue-copy queue)))
      (set-car! (cdr source) 'changed)
      (list (list-queue-list queue)
            (list-queue-list copy)
            (eq? source (list-queue-list queue))
            (not (eq? source (list-queue-list copy))))))))

(testing-registry-case
 'list-queue/nondestructive-append '(portable stdlib conformance identity)
 (test-equal
  'list-queue/nondestructive-append
  '((a b c d) (changed b) (c changed) (a b c d) #t)
  (let* ((left (list-queue 'a 'b))
         (right (list-queue 'c 'd))
         (result (list-queue-append left right)))
    (set-car! (list-queue-list left) 'changed)
    (set-car! (cdr (list-queue-list right)) 'changed)
    (list (list-queue-list result)
          (list-queue-list left)
          (list-queue-list right)
          (list-queue-list
           (list-queue-concatenate
            (list (list-queue 'a 'b) (list-queue 'c 'd))))
          (list-queue-empty? (list-queue-append))))))

(testing-registry-case
 'list-queue/destructive-append-boundaries
 '(portable stdlib conformance identity)
 (test-equal
  'list-queue/destructive-append-boundaries
  '((a b c d e) e #t #t)
  (let* ((first (list-queue))
         (middle (list-queue 'a 'b))
         (empty (list-queue))
         (last (list-queue 'c 'd))
         (result (list-queue-append! first middle empty last)))
    (list-queue-add-back! result 'e)
    (list (list-queue-list result)
          (list-queue-back result)
          (eq? result first)
          (eq? middle (list-queue-append! middle))))))

(testing-registry-case
 'list-queue/unfold-order-and-callbacks '(portable stdlib conformance)
 (test-equal
  'list-queue/unfold-order-and-callbacks
  '((0 2 4 6 tail)
    (tail 6 4 2 0)
    ((map 0) (next 0) (map 1) (next 1)
     (map 2) (next 2) (map 3) (next 3)))
  (let ((events '()))
    (define (stop? value) (> value 3))
    (define (mapper value)
      (set! events (cons (list 'map value) events))
      (* value 2))
    (define (successor value)
      (set! events (cons (list 'next value) events))
      (+ value 1))
    (let ((left
           (list-queue-unfold
            stop? mapper successor 0 (list-queue 'tail))))
      (set! events '())
      (let ((right
             (list-queue-unfold-right
              stop? mapper successor 0 (list-queue 'tail))))
        (list (list-queue-list left)
              (list-queue-list right)
              (reverse events)))))))

(testing-registry-case
 'list-queue/mapping-and-traversal '(portable stdlib conformance identity)
 (test-equal
  'list-queue/mapping-and-traversal
  '((1 2 3) (10 20 30) (2 3 4) (2 3 4) 9)
  (let* ((source-list (list 1 2 3))
         (source (make-list-queue source-list))
         (mapped (list-queue-map (lambda (value) (* value 10)) source))
         (sum 0))
    (list-queue-map! (lambda (value) (+ value 1)) source)
    (list-queue-for-each
     (lambda (value) (set! sum (+ sum value)))
     source)
    (list '(1 2 3)
          (list-queue-list mapped)
          (list-queue-list source)
          source-list
          sum))))

(testing-registry-case
 'list-queue/linear-fifo-stress '(portable stdlib stress)
 (test-equal
  'list-queue/linear-fifo-stress
  '(5000 0 4999 #t)
  (let ((queue (list-queue)))
    (let fill ((index 0))
      (if (< index 5000)
          (begin
            (list-queue-add-back! queue index)
            (fill (+ index 1)))))
    (let ((first (list-queue-front queue))
          (last (list-queue-back queue)))
      (let drain ((count 0))
        (if (list-queue-empty? queue)
            (list count first last #t)
            (begin
              (list-queue-remove-front! queue)
              (drain (+ count 1)))))))))

(testing-runner-main "SRFI 117 list queues" (command-line))
