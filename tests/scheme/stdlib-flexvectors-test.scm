;;; Portable SRFI 214 flexvector stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2020-2021 Adam Nelson
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (stdlib flexvectors)
        (consent growable-vector)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return true when THUNK raises an exception."
  (guard (condition (else #t))
    (thunk)
    #f))

(define (iota-flexvector count)
  "Return a flexvector containing integers below COUNT."
  (flexvector-unfold
   (lambda (index) (= index count))
   (lambda (index) index)
   (lambda (index) (+ index 1))
   0))

(testing-registry-case
 'flexvectors/construction-and-conversion '(portable stdlib)
 (test-equal
  'flexvectors/construction-and-conversion
  '(#t #t 4 #(fill fill fill) (a b c) (c b a) "abc")
  (let ((empty (flexvector))
        (filled (make-flexvector 3 'fill))
        (values (flexvector 'a 'b 'c)))
    (list (flexvector? empty)
          (flexvector-empty? empty)
          (flexvector-length (flexvector 1 2 3 4))
          (flexvector->vector filled)
          (flexvector->list values)
          (reverse-flexvector->list values)
          (flexvector->string (string->flexvector "abc"))))))

(testing-registry-case
 'flexvectors/conversion-slices-and-lists '(portable stdlib conformance)
 (test-equal
  'flexvectors/conversion-slices-and-lists
  '(#(a b c) #(c b a) #(a b c) #(a b c d) (b c) (c b)
    "ell" #(#\e #\l #\l))
  (let ((values (flexvector 'a 'b 'c 'd)))
    (list
     (flexvector->vector (list->flexvector '(a b c)))
     (flexvector->vector (reverse-list->flexvector '(a b c)))
     (flexvector->vector
      (vector->flexvector '#(x a b c y) 1 4))
     (flexvector->vector values -5 99)
     (flexvector->list values 1 3)
     (reverse-flexvector->list values 1 3)
     (flexvector->string (string->flexvector "hello" 1 4))
     (flexvector->vector (string->flexvector "hello" 1 4))))))

(testing-registry-case
 'flexvectors/allocation-independence-and-empty-identities
 '(portable stdlib conformance)
 (test-equal
  'flexvectors/allocation-independence-and-empty-identities
  '((changed b c) (a copy-change c) (a b c) #(input-change b c)
    #(a b output-change) #t #t #t #t)
  (let* ((source (flexvector 'a 'b 'c))
         (copy (flexvector-copy source))
         (input-vector (vector 'a 'b 'c))
         (from-vector (vector->flexvector input-vector))
         (output-vector (flexvector->vector source)))
    (flexvector-set! source 0 'changed)
    (flexvector-set! copy 1 'copy-change)
    (vector-set! input-vector 0 'input-change)
    (vector-set! output-vector 2 'output-change)
    (list
     (flexvector->list source)
     (flexvector->list copy)
     (flexvector->list from-vector)
     input-vector
     output-vector
     (flexvector-empty? (flexvector-append))
     (flexvector-empty? (flexvector-concatenate '()))
     (flexvector-empty? (flexvector-append-subvectors))
     (flexvector=? equal? source source source)))))

(testing-registry-case
 'flexvectors/set-at-end-and-remove-tail '(portable stdlib conformance)
 (test-equal
  'flexvectors/set-at-end-and-remove-tail
  '(#(a b c d) #t #(a b))
  (let ((values (flexvector 'a 'b 'c)))
    (flexvector-set! values (flexvector-length values) 'd)
    (let* ((after-set (flexvector->vector values))
           (remove-result (flexvector-remove-range! values 2)))
      (list after-set
            (eq? values remove-result)
            (flexvector->vector values))))))

(testing-registry-case
 'flexvectors/mutator-return-contracts '(portable stdlib conformance)
 (test-equal
  'flexvectors/mutator-return-contracts
  '(#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t)
  (let ((add (flexvector 1))
        (front (flexvector 1))
        (back (flexvector 1))
        (all (flexvector 1))
        (append (flexvector 1))
        (remove-range (flexvector 1 2))
        (clear (flexvector 1))
        (swap (flexvector 1 2))
        (fill (flexvector 1))
        (reverse (flexvector 1 2))
        (copy (flexvector 1))
        (reverse-copy (flexvector 1))
        (map (flexvector 1))
        (map/index (flexvector 1))
        (filter (flexvector 1))
        (filter/index (flexvector 1)))
    (list
     (eq? add (flexvector-add! add 1 2))
     (eq? front (flexvector-add-front! front 0))
     (eq? back (flexvector-add-back! back 2))
     (eq? all (flexvector-add-all! all 1 '(2 3)))
     (eq? append (flexvector-append! append (flexvector 2)))
     (eq? remove-range (flexvector-remove-range! remove-range 1))
     (eq? clear (flexvector-clear! clear))
     (eq? swap (flexvector-swap! swap 0 1))
     (eq? fill (flexvector-fill! fill 2))
     (eq? reverse (flexvector-reverse! reverse))
     (eq? copy (flexvector-copy! copy 1 (flexvector 2)))
     (eq? reverse-copy
          (flexvector-reverse-copy! reverse-copy 1 (flexvector 2)))
     (eq? map (flexvector-map! (lambda (value) (+ value 1)) map))
     (eq? map/index
          (flexvector-map/index!
           (lambda (index value) (+ index value))
           map/index))
     (eq? filter (flexvector-filter! odd? filter))
     (eq? filter/index
          (flexvector-filter/index!
           (lambda (index value) (= index 0))
           filter/index))))))

(testing-registry-case
 'flexvectors/value-returns-and-self-aliasing '(portable stdlib conformance)
 (test-equal
  'flexvectors/value-returns-and-self-aliasing
  '(b a b b #t #(a b a b))
  (let ((set-values (flexvector 'a 'b 'c))
        (front-values (flexvector 'a 'b))
        (back-values (flexvector 'a 'b))
        (remove-values (flexvector 'a 'b 'c))
        (alias (flexvector 'a 'b)))
    (let ((set-result (flexvector-set! set-values 1 'changed))
          (front-result (flexvector-remove-front! front-values))
          (back-result (flexvector-remove-back! back-values))
          (remove-result (flexvector-remove! remove-values 1)))
      (let ((append-result (flexvector-append! alias alias)))
        (list set-result
              front-result
              back-result
              remove-result
              (eq? alias append-result)
              (flexvector->vector alias)))))))

(testing-registry-case
 'flexvectors/multiple-seed-unfold '(portable stdlib conformance)
 (test-equal
  'flexvectors/multiple-seed-unfold
  '(#(11 22 33) #(33 22 11))
  (let ((stop? (lambda (left right) (> left 3)))
        (map-seeds (lambda (left right) (+ left right)))
        (next-seeds
         (lambda (left right)
           (values (+ left 1) (+ right 10)))))
    (list
     (flexvector->vector
      (flexvector-unfold stop? map-seeds next-seeds 1 10))
     (flexvector->vector
      (flexvector-unfold-right stop? map-seeds next-seeds 1 10))))))

(testing-registry-case
 'flexvectors/private-storage-boundary '(portable stdlib storage)
 (test-assert
  'flexvectors/private-storage-boundary
  (let ((storage (consent-make-growable-vector 0 8)))
    (and (consent-growable-vector? storage)
         (not (flexvector? storage))
         (not (consent-growable-vector? (flexvector)))))))

(testing-registry-case
 'flexvectors/destructive-editing '(portable stdlib)
 (test-equal
  'flexvectors/destructive-editing
  '(front-1 front-2 x y head a c tail-1 tail-2)
  (let ((values (flexvector 'a 'b 'c)))
    (flexvector-add-front! values 'head)
    (flexvector-add-front! values 'front-1 'front-2)
    (flexvector-add-all! values 2 '(x y))
    (flexvector-remove! values 6)
    (flexvector-add-back! values 'tail-1 'tail-2)
    (flexvector->list values))))

(testing-registry-case
 'flexvectors/overlapping-copy '(portable stdlib)
 (test-equal
  'flexvectors/overlapping-copy
  '(#(0 0 1 2 3) #(0 1 2 3 3) #(3 2 1 0 3) #(3 x x 0 3))
  (let ((values (flexvector 0 1 2 3 4)))
    (flexvector-copy! values 1 values 0 4)
    (let ((right (flexvector->vector values)))
      (flexvector-copy! values 0 values 1 5)
      (let ((left (flexvector->vector values)))
        (flexvector-reverse-copy! values 0 values 0 4)
        (let ((reversed (flexvector->vector values)))
          (flexvector-fill! values 'x 1 3)
          (list right left reversed (flexvector->vector values))))))))

(testing-registry-case
 'flexvectors/parallel-operations '(portable stdlib)
 (test-equal
  'flexvectors/parallel-operations
  '(#(11 22 33) 2 #t #f)
  (let ((left (flexvector 1 2 3))
        (right (flexvector 10 20 30 40)))
    (list
     (flexvector->vector (flexvector-map + left right))
     (flexvector-index (lambda (x y) (= (+ x y) 33)) left right)
     (flexvector-any (lambda (x y) (= (+ x y) 22)) left right)
     (flexvector-every (lambda (x y) (< (+ x y) 30)) left right)))))

(testing-registry-case
 'flexvectors/parallel-order-and-short-circuit
 '(portable stdlib conformance)
 (test-equal
  'flexvectors/parallel-order-and-short-circuit
  '((22 11) (11 22) #(11 23) 2 (11 22)
    hit (1 2) #f (1 2 3) last #f #t)
  (let ((left (flexvector 1 2 3))
        (right (flexvector 10 20))
        (visited '())
        (any-seen '())
        (every-seen '()))
    (let* ((folded
            (flexvector-fold
             (lambda (state x y) (cons (+ x y) state))
             '()
             left
             right))
           (folded-right
            (flexvector-fold-right
             (lambda (state x y) (cons (+ x y) state))
             '()
             left
             right))
           (mapped
            (flexvector->vector
             (flexvector-map/index
              (lambda (index x y) (+ index x y))
              left
              right)))
           (counted (flexvector-count < left right))
           (visited-result
            (begin
              (flexvector-for-each
               (lambda (x y)
                 (set! visited (cons (+ x y) visited)))
               left
               right)
              (reverse visited)))
           (any-result
            (flexvector-any
             (lambda (value)
               (set! any-seen (cons value any-seen))
               (and (= value 2) 'hit))
             left))
           (any-order (reverse any-seen))
           (every-result
            (flexvector-every
             (lambda (value)
               (set! every-seen (cons value every-seen))
               (and (< value 3) 'keep))
             left))
           (every-order (reverse every-seen)))
      (list
       folded
       folded-right
       mapped
       counted
       visited-result
       any-result
       any-order
       every-result
       every-order
       (flexvector-every
        (lambda (value) (if (= value 3) 'last 'keep))
        left)
       (flexvector-any values (flexvector))
       (flexvector-every values (flexvector)))))))

(testing-registry-case
 'flexvectors/search-and-partition '(portable stdlib)
 (test-equal
  'flexvectors/search-and-partition
  '(3 #(0 2 4 6 8) #(1 3 5 7 9))
  (let ((values (iota-flexvector 10)))
    (call-with-values
     (lambda ()
       (flexvector-partition even? values))
     (lambda (accepted rejected)
       (list
        (flexvector-binary-search values 3
                                  (lambda (left right) (- left right)))
        (flexvector->vector accepted)
        (flexvector->vector rejected)))))))

(testing-registry-case
 'flexvectors/bounds-errors '(portable stdlib)
 (test-assert
  'flexvectors/bounds-errors
  (let ((values (flexvector 'only)))
    (and (raises? (lambda () (flexvector-ref values 1)))
         (raises? (lambda () (flexvector-set! values -1 'bad)))
         (raises? (lambda () (flexvector-add! values 2 'bad)))
         (raises? (lambda () (flexvector-copy values 1 0)))))))

(testing-registry-case
 'flexvectors/empty-operation-errors '(portable stdlib conformance)
 (let ((empty (flexvector)))
   (test-assert
    'flexvectors/empty-front-error
    (raises? (lambda () (flexvector-front empty))))
   (test-assert
    'flexvectors/empty-back-error
    (raises? (lambda () (flexvector-back empty))))
   (test-assert
    'flexvectors/empty-remove-front-error
    (raises? (lambda () (flexvector-remove-front! empty))))
   (test-assert
    'flexvectors/empty-remove-back-error
    (raises? (lambda () (flexvector-remove-back! empty))))))

(testing-registry-case
 'flexvectors/range-and-callback-errors '(portable stdlib conformance)
 (let ((values (flexvector 1 2 3)))
   (test-assert
    'flexvectors/negative-size-error
    (raises? (lambda () (make-flexvector -1))))
   (test-assert
    'flexvectors/too-many-fill-values-error
    (raises? (lambda () (make-flexvector 1 'a 'b))))
   (test-assert
    'flexvectors/set-past-end-error
    (raises? (lambda () (flexvector-set! values 4 'bad))))
   (test-assert
    'flexvectors/inexact-index-error
    (raises? (lambda () (flexvector-ref values 1.0))))
   (test-assert
    'flexvectors/remove-reversed-range-error
    (raises? (lambda () (flexvector-remove-range! values 2 1))))
   (test-assert
    'flexvectors/copy-reversed-range-error
    (raises? (lambda () (flexvector-copy values 2 1))))
   (test-assert
    'flexvectors/vector-conversion-reversed-range-error
    (raises? (lambda () (flexvector->vector values 2 1))))
   (test-assert
    'flexvectors/string-conversion-reversed-range-error
    (raises?
     (lambda ()
       (string->flexvector "abc" 2 1))))
   (test-assert
    'flexvectors/improper-list-error
    (raises? (lambda () (list->flexvector '(1 . 2)))))
   (test-assert
    'flexvectors/improper-add-all-list-error
    (raises?
     (lambda () (flexvector-add-all! values 1 '(a . b)))))
   (test-assert
    'flexvectors/improper-concatenation-list-error
    (raises?
     (lambda ()
       (flexvector-concatenate (cons values values)))))
   (test-assert
    'flexvectors/incomplete-subvector-error
    (raises?
     (lambda () (flexvector-append-subvectors values 0))))
   (test-assert
    'flexvectors/append-map-result-error
    (raises?
     (lambda ()
       (flexvector-append-map (lambda (value) value) values))))
   (test-assert
    'flexvectors/too-many-remove-bounds-error
    (raises?
     (lambda () (flexvector-remove-range! values 0 1 2))))
   (test-assert
    'flexvectors/index-right-length-error
    (raises?
     (lambda ()
       (flexvector-index-right = values (flexvector 1 2)))))
   (test-assert
    'flexvectors/skip-right-length-error
    (raises?
     (lambda ()
       (flexvector-skip-right = values (flexvector 1 2)))))))

(testing-registry-case
 'flexvectors/long-input '(portable stdlib stress)
 (test-equal
  'flexvectors/long-input
  '(10000 0 9999 5000 9999)
  (let ((values (iota-flexvector 10000)))
    (flexvector-remove-range! values 2500 7500)
    (list 10000
          (flexvector-front values)
          (flexvector-back values)
          (flexvector-length values)
          (flexvector-ref values 4999)))))

(testing-runner-main "SRFI 214 flexvectors" (command-line))
