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
