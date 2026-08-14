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

(define (queue-invariant? queue)
  "Return whether QUEUE's exposed endpoints describe one proper list."
  (call-with-values
   (lambda () (list-queue-first-last queue))
   (lambda (first last)
     (if (null? first)
         (null? last)
         (and
          (pair? first)
          (pair? last)
          (let loop ((rest first))
            (cond
             ((eq? rest last) (null? (cdr rest)))
             ((pair? (cdr rest)) (loop (cdr rest)))
             (else #f))))))))

;; The exhaustive model check covers every short trace over this alphabet.
(define model-operations
  '((add-front front)
    (add-back back)
    (remove-front)
    (remove-back)
    (remove-all)))

(define (apply-model-operation! queue model operation)
  "Apply OPERATION to QUEUE and return success followed by the new MODEL."
  (case (car operation)
    ((add-front)
     (list-queue-add-front! queue (cadr operation))
     (cons #t (cons (cadr operation) model)))
    ((add-back)
     (list-queue-add-back! queue (cadr operation))
     (cons #t (append model (list (cadr operation)))))
    ((remove-front)
     (if (null? model)
         (cons
          (raises? (lambda () (list-queue-remove-front! queue)))
          model)
         (cons
          (equal? (list-queue-remove-front! queue) (car model))
          (cdr model))))
    ((remove-back)
     (if (null? model)
         (cons
          (raises? (lambda () (list-queue-remove-back! queue)))
          model)
         (let ((reversed (reverse model)))
           (cons
            (equal? (list-queue-remove-back! queue) (car reversed))
            (reverse (cdr reversed))))))
    ((remove-all)
     (cons (equal? (list-queue-remove-all! queue) model) '()))))

(define (operation-traces depth)
  "Return every MODEL-OPERATIONS trace of length DEPTH."
  (if (= depth 0)
      '(())
      (let ((tails (operation-traces (- depth 1))))
        (apply
         append
         (map
          (lambda (operation)
            (map
             (lambda (tail) (cons operation tail))
             tails))
          model-operations)))))

(define (run-model-trace trace)
  "Check one mutation TRACE against a simple immutable-list model."
  (let ((queue (list-queue)))
    (let loop ((remaining trace) (model '()))
      (if (null? remaining)
          #t
          (let* ((operation (car remaining))
                 (result
                  (apply-model-operation! queue model operation))
                 (operation-ok? (car result))
                 (next-model (cdr result)))
            (if (and operation-ok?
                     (equal? (list-queue-list queue) next-model)
                     (queue-invariant? queue))
                (loop (cdr remaining) next-model)
                (error
                 "list queue diverged from model"
                 trace
                 operation
                 next-model
                 (list-queue-list queue))))))))

(testing-registry-case
 'list-queue/construction-and-access '(portable stdlib conformance)
 (test-equal
  'list-queue/construction-and-access
  '(#t #f #t #t front back (front middle back))
  (let ((empty (list-queue))
        (queue (list-queue 'front 'middle 'back)))
    (list (list-queue? queue)
          (list-queue? '(front middle back))
          (list-queue-empty? empty)
          (list-queue-empty? (make-list-queue '() '()))
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
 'list-queue/computed-endpoints-and-empty-reset
 '(portable stdlib conformance identity)
 (let* ((source (list 'a 'b 'c))
        (queue (make-list-queue source))
        (endpoints (queue-endpoints queue)))
   (test-assert
    'list-queue/computed-endpoint-identity
    (and (eq? source (car endpoints))
         (eq? (cddr source) (cadr endpoints))
         (queue-invariant? queue)))
   (list-queue-set-list! queue '())
   (test-equal
    'list-queue/empty-reset-endpoints
    '(#t () ())
    (let ((empty-endpoints (queue-endpoints queue)))
      (list (queue-invariant? queue)
            (car empty-endpoints)
            (cadr empty-endpoints))))
   (list-queue-add-back! queue 'reused)
   (let ((reused-state
          (list (list-queue-front queue)
                (list-queue-back queue)
                (list-queue-list queue)
                (queue-invariant? queue))))
     (list-queue-set-list! queue '() '())
     (test-equal
      'list-queue/reuse-after-empty-reset
      '(reused reused (reused) #t #t)
      (append
       reused-state
       (list (and (list-queue-empty? queue)
                  (queue-invariant? queue))))))))

(testing-registry-case
 'list-queue/endpoint-transition-identity
 '(portable stdlib conformance identity)
 (test-equal
  'list-queue/endpoint-transition-identity
  '(a #t #t c #t #t b #t () ())
  (let* ((source (list 'a 'b 'c))
         (source-second (cdr source))
         (source-last (cddr source))
         (queue (make-list-queue source)))
    (let ((front (list-queue-remove-front! queue)))
      (let ((after-front (queue-endpoints queue)))
        (let ((back (list-queue-remove-back! queue)))
          (let ((after-back (queue-endpoints queue)))
            (let ((last (list-queue-remove-front! queue)))
              (let ((empty-endpoints (queue-endpoints queue)))
                (list front
                      (eq? source-second (car after-front))
                      (eq? source-last (cadr after-front))
                      back
                      (eq? source-second (car after-back))
                      (eq? source-second (cadr after-back))
                      last
                      (queue-invariant? queue)
                      (car empty-endpoints)
                      (cadr empty-endpoints)))))))))))

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
 'list-queue/singleton-front-removal '(portable stdlib conformance)
 (test-equal
  'list-queue/singleton-front-removal
  '(only #t () () #t (again))
  (let ((queue (list-queue 'only)))
    (let ((element (list-queue-remove-front! queue)))
      (let ((empty? (list-queue-empty? queue))
            (endpoints (queue-endpoints queue)))
        (list-queue-add-front! queue 'again)
        (list element
              empty?
              (car endpoints)
              (cadr endpoints)
              (queue-invariant? queue)
              (list-queue-list queue)))))))

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
    (raises? (lambda () (make-list-queue '(a) '()))))
   (test-assert
    'list-queue/set-improper-list-error
    (raises?
     (lambda () (list-queue-set-list! empty '(a . b)))))
   (test-assert
    'list-queue/set-inconsistent-explicit-last-error
    (raises?
     (lambda () (list-queue-set-list! empty '(a) '()))))
   (test-equal
    'list-queue/set-list-validation-is-atomic
    '(() #t)
    (list (list-queue-list empty) (queue-invariant? empty)))))

(testing-registry-case
 'list-queue/non-queue-errors '(portable stdlib conformance)
 (let ((not-a-queue '(a b)))
   (for-each
    (lambda (named-thunk)
      (test-assert
       (car named-thunk)
       (raises? (cdr named-thunk))))
    (list
     (cons 'list-queue/non-queue-empty?
           (lambda () (list-queue-empty? not-a-queue)))
     (cons 'list-queue/non-queue-front
           (lambda () (list-queue-front not-a-queue)))
     (cons 'list-queue/non-queue-back
           (lambda () (list-queue-back not-a-queue)))
     (cons 'list-queue/non-queue-list
           (lambda () (list-queue-list not-a-queue)))
     (cons 'list-queue/non-queue-first-last
           (lambda () (list-queue-first-last not-a-queue)))
     (cons 'list-queue/non-queue-add-front
           (lambda () (list-queue-add-front! not-a-queue 'x)))
     (cons 'list-queue/non-queue-add-back
           (lambda () (list-queue-add-back! not-a-queue 'x)))
     (cons 'list-queue/non-queue-remove-front
           (lambda () (list-queue-remove-front! not-a-queue)))
     (cons 'list-queue/non-queue-remove-back
           (lambda () (list-queue-remove-back! not-a-queue)))
     (cons 'list-queue/non-queue-remove-all
           (lambda () (list-queue-remove-all! not-a-queue)))
     (cons 'list-queue/non-queue-set-list
           (lambda () (list-queue-set-list! not-a-queue '(x))))
     (cons 'list-queue/non-queue-copy
           (lambda () (list-queue-copy not-a-queue)))
     (cons 'list-queue/non-queue-append
           (lambda () (list-queue-append not-a-queue)))
     (cons 'list-queue/non-queue-append-first
           (lambda () (list-queue-append! not-a-queue)))
     (cons 'list-queue/non-queue-append-later
           (lambda ()
             (list-queue-append! (list-queue) not-a-queue)))
     (cons 'list-queue/non-queue-concatenate
           (lambda ()
             (list-queue-concatenate (list not-a-queue))))
     (cons 'list-queue/non-queue-map
           (lambda () (list-queue-map values not-a-queue)))
     (cons 'list-queue/non-queue-map!
           (lambda () (list-queue-map! values not-a-queue)))
     (cons 'list-queue/non-queue-for-each
           (lambda () (list-queue-for-each values not-a-queue)))
     (cons 'list-queue/non-queue-unfold
           (lambda ()
             (list-queue-unfold
              null? values values '() not-a-queue)))
     (cons 'list-queue/non-queue-unfold-right
           (lambda ()
             (list-queue-unfold-right
              null? values values '() not-a-queue)))))))

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
  '((a b c d) (changed b) (c changed) (a b c d) #t #t)
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
          (list-queue-empty? (list-queue-append))
          (list-queue-empty? (list-queue-concatenate '()))))))

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
 'list-queue/destructive-append-identity
 '(portable stdlib conformance identity)
 (test-equal
  'list-queue/destructive-append-identity
  '(#t #t #t (a b c d e) e)
  (let* ((left-list (list 'a 'b))
         (right-list (list 'c 'd))
         (left (make-list-queue left-list (cdr left-list)))
         (right (make-list-queue right-list (cdr right-list)))
         (result (list-queue-append! left right)))
    (list-queue-add-back! result 'e)
    (let ((endpoints (queue-endpoints result)))
      (list (eq? result left)
            (eq? left-list (car endpoints))
            (eq? right-list (cddr (car endpoints)))
            (list-queue-list result)
            (car (cadr endpoints)))))))

(testing-registry-case
 'list-queue/destructive-append-validation
 '(portable stdlib conformance)
 (test-equal
  'list-queue/destructive-append-validation
  '((a) #t (a) #t)
  (let ((first (list-queue 'a)))
    (let ((raised?
           (raises?
            (lambda ()
              (list-queue-append!
               first
               (list-queue 'b)
               '(not a queue))))))
      (let ((fresh (list-queue-append!)))
        (list (list-queue-list first)
              raised?
              (list-queue-list first)
              (and (list-queue? fresh)
                   (list-queue-empty? fresh))))))))

(testing-registry-case
 'list-queue/unfold-order-and-callbacks '(portable stdlib conformance)
 (test-equal
  'list-queue/unfold-order-and-callbacks
  '((0 2 4 6 tail)
    (tail 6 4 2 0)
    ((stop 0) (map 0) (next 0)
     (stop 1) (map 1) (next 1)
     (stop 2) (map 2) (next 2)
     (stop 3) (map 3) (next 3)
     (stop 4))
    ((stop 0) (map 0) (next 0)
     (stop 1) (map 1) (next 1)
     (stop 2) (map 2) (next 2)
     (stop 3) (map 3) (next 3)
     (stop 4)))
  (let ((events '()))
    (define (stop? value)
      (set! events (cons (list 'stop value) events))
      (> value 3))
    (define (mapper value)
      (set! events (cons (list 'map value) events))
      (* value 2))
    (define (successor value)
      (set! events (cons (list 'next value) events))
      (+ value 1))
    (let ((left
           (list-queue-unfold
            stop? mapper successor 0 (list-queue 'tail))))
      (let ((left-events (reverse events)))
        (set! events '())
        (let ((right
               (list-queue-unfold-right
                stop? mapper successor 0 (list-queue 'tail))))
          (list (list-queue-list left)
                (list-queue-list right)
                left-events
                (reverse events))))))))

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
 'list-queue/mutating-callback-order
 '(portable stdlib conformance identity)
 (test-equal
  'list-queue/mutating-callback-order
  '((map 1) (map 2) (map 3)
    (each 2) (each 4) (each 6)
    (2 4 6) #t #t)
  (let* ((source-list (list 1 2 3))
         (last-pair (cddr source-list))
         (queue (make-list-queue source-list last-pair))
         (events '()))
    (list-queue-map!
     (lambda (value)
       (set! events (cons (list 'map value) events))
       (* value 2))
     queue)
    (list-queue-for-each
     (lambda (value)
       (set! events (cons (list 'each value) events)))
     queue)
    (append
     (reverse events)
     (list (list-queue-list queue)
           (eq? source-list (list-queue-list queue))
           (eq? last-pair (cadr (queue-endpoints queue))))))))

(testing-registry-case
 'list-queue/empty-callback-boundaries '(portable stdlib conformance)
 (test-equal
  'list-queue/empty-callback-boundaries
  '(() () () #t #t 0)
  (let ((calls 0)
        (empty (list-queue)))
    (define (called value)
      (set! calls (+ calls 1))
      value)
    (let ((mapped (list-queue-map called empty)))
      (list-queue-map! called empty)
      (list-queue-for-each called empty)
      (let ((left
             (list-queue-unfold
              null? called called '() empty))
            (right
             (list-queue-unfold-right
              null? called called '() empty)))
        (list (list-queue-list mapped)
              (list-queue-list left)
              (list-queue-list right)
              (eq? left empty)
              (eq? right empty)
              calls))))))

(testing-registry-case
 'list-queue/exhaustive-short-mutation-traces
 '(portable stdlib conformance invariant)
 (test-equal
  'list-queue/exhaustive-short-mutation-traces
  '(625 #t)
  (let loop ((traces (operation-traces 4)) (count 0))
    (if (null? traces)
        (list count #t)
        (begin
          (run-model-trace (car traces))
          (loop (cdr traces) (+ count 1)))))))

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
