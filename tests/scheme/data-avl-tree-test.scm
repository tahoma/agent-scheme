;;; Portable persistent AVL tree tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Exercises the public ordered-map and invariant-diagnostic contract for
;;; `(data avl-tree)` across direct and compiled R7RS hosts.

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (data avl-tree)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when THUNK raises a Scheme condition."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (tree-from-pairs pairs)
  "Return an integer-keyed AVL tree containing PAIRS."
  (let loop ((tree (make-avl-tree <)) (rest pairs))
    (if (null? rest)
        tree
        (loop (avl-tree-set tree (caar rest) (cdar rest))
              (cdr rest)))))

(define (tree-items tree)
  "Return TREE's associations in ascending key order."
  (avl-tree-fold/reverse
   (lambda (key value result)
     (cons (cons key value) result))
   '()
   tree))

(define (valid-tree? tree)
  "Return whether TREE satisfies all AVL invariants."
  (avl-tree-valid? tree))

(define (values-list thunk)
  "Return the values produced by THUNK as a list."
  (call-with-values thunk list))

(define (delete-sequence tree keys)
  "Delete KEYS from TREE and return validity history plus the final tree."
  (let loop ((tree tree) (keys keys) (validity '()))
    (if (null? keys)
        (list (reverse validity) tree)
        (let ((next (avl-tree-delete tree (car keys))))
          (loop next (cdr keys) (cons (valid-tree? next) validity))))))

(define (model-set model key value)
  "Return sorted integer MODEL with KEY associated to VALUE."
  (cond
   ((null? model) (list (cons key value)))
   ((< key (caar model)) (cons (cons key value) model))
   ((= key (caar model)) (cons (cons key value) (cdr model)))
   (else (cons (car model) (model-set (cdr model) key value)))))

(define (model-delete model key)
  "Return sorted integer MODEL without KEY."
  (cond
   ((null? model) '())
   ((< key (caar model)) model)
   ((= key (caar model)) (cdr model))
   (else (cons (car model) (model-delete (cdr model) key)))))

(define (run-operation-sequence operations)
  "Return consistency and final state for deterministic OPERATIONS."
  (let loop ((operations operations)
             (tree (make-avl-tree <))
             (model '())
             (consistent? #t))
    (if (null? operations)
        (list consistent? (tree-items tree) (avl-tree-size tree))
        (let* ((operation (car operations))
               (put? (eq? (list-ref operation 0) 'put))
               (key (list-ref operation 1))
               (next-tree
                (if put?
                    (avl-tree-set tree key (list-ref operation 2))
                    (avl-tree-delete tree key)))
               (next-model
                (if put?
                    (model-set model key (list-ref operation 2))
                    (model-delete model key))))
          (loop (cdr operations)
                next-tree
                next-model
                (and consistent?
                     (valid-tree? next-tree)
                     (equal? (tree-items next-tree) next-model)
                     (= (avl-tree-size next-tree)
                        (length next-model))))))))

(define (tree-has-numbered-values? tree count)
  "Return whether TREE maps every integer below COUNT to its square."
  (let loop ((key 0))
    (or (= key count)
        (and (= (avl-tree-ref/default tree key -1) (* key key))
             (loop (+ key 1))))))

(define (stress-insertions count)
  "Build COUNT permuted associations, checking every intermediate root."
  (let loop ((index 0)
             (tree (make-avl-tree <))
             (valid? #t))
    (if (= index count)
        (values tree valid?)
        (let* ((key (modulo (* index 73) count))
               (next (avl-tree-set tree key (* key key))))
          (loop (+ index 1)
                next
                (and valid?
                     (valid-tree? next)
                     (= (avl-tree-size next) (+ index 1))))))))

(define (stress-deletions tree count)
  "Delete every key from TREE in another permutation, checking roots."
  (let loop ((index 0) (tree tree) (valid? #t))
    (if (= index count)
        (values tree valid?)
        (let* ((key (modulo (* index 151) count))
               (next (avl-tree-delete tree key)))
          (loop (+ index 1)
                next
                (and valid?
                     (valid-tree? next)
                     (= (avl-tree-size next)
                        (- count index 1))))))))

(testing-registry-case
 'avl-empty-tree '(portable data)
(test-equal 'avl-empty-tree
            '(#t 0 () #t)
            (let ((tree (make-avl-tree <)))
              (list (avl-tree-empty? tree)
                    (avl-tree-size tree)
                    (tree-items tree)
                    (valid-tree? tree)))))

(testing-registry-case
 'avl-constructor-and-predicate '(portable data)
(test-equal 'avl-constructor-and-predicate
            '(#t #f #t #t #f #t)
            (let ((tree (make-avl-tree <)))
              (list (avl-tree? tree)
                    (avl-tree? '())
                    (eq? < (avl-tree-ordering tree))
                    (avl-tree-valid? tree)
                    (avl-tree-valid? '())
                    (raises? (lambda () (make-avl-tree 42)))))))

(testing-registry-case
 'avl-set-lookup-and-size '(portable data)
(test-equal 'avl-set-lookup-and-size
            '(three 99 #t #f 3 ((1 . one) (2 . #f) (3 . three)) #t)
            (let* ((tree0 (make-avl-tree <))
                   (tree1 (avl-tree-set tree0 3 'three))
                   (tree2 (avl-tree-set tree1 1 'one))
                   (tree3 (avl-tree-set tree2 2 #f)))
              (list (avl-tree-ref tree3 3)
                    (avl-tree-ref/default tree3 4 99)
                    (avl-tree-contains? tree3 2)
                    (avl-tree-ref tree3 2 (lambda () 'missing))
                    (avl-tree-size tree3)
                    (tree-items tree3)
                    (valid-tree? tree3)))))

(testing-registry-case
 'avl-ref-failure-and-success '(portable data)
(test-equal 'avl-ref-failure-and-success
            '(missing (found one) (1 one) missing-key #t)
            (let ((tree (avl-tree-set (make-avl-tree <) 1 'one)))
              (list
               (avl-tree-ref tree 2 (lambda () 'missing))
               (avl-tree-ref tree
                             1
                             (lambda () 'missing)
                             (lambda (value) (list 'found value)))
               (avl-tree-ref/key tree
                                 1.0
                                 (lambda () 'missing-key)
                                 list)
               (avl-tree-ref/key tree
                                 2
                                 (lambda () 'missing-key)
                                 list)
               (raises? (lambda () (avl-tree-ref tree 2)))))))

(testing-registry-case
 'avl-adjoin-replace-and-set '(portable data)
(test-equal 'avl-adjoin-replace-and-set
            '(((1 . first) (2 . second))
              ((1 . replaced) (2 . second))
              ((1 . set) (2 . second))
              ((1 . first) (2 . second)))
            (let* ((base (tree-from-pairs '((1 . first) (2 . second))))
                   (adjoined (avl-tree-adjoin base 1 'ignored))
                   (replaced (avl-tree-replace base 1 'replaced))
                   (missing (avl-tree-replace base 3 'ignored))
                   (set (avl-tree-set base 1 'set)))
              (list (tree-items adjoined)
                    (tree-items replaced)
                    (tree-items set)
                    (tree-items missing)))))

(testing-registry-case
 'avl-equivalent-keys-preserve-canonical-key '(portable data)
(test-equal 'avl-equivalent-keys-preserve-canonical-key
            '(((3 . first)) ((3 . replaced)) ((3 . set)) 1 #t)
            (let* ((ordering (lambda (left right)
                               (< (abs left) (abs right))))
                   (base (avl-tree-set (make-avl-tree ordering) 3 'first))
                   (adjoined (avl-tree-adjoin base -3 'ignored))
                   (replaced (avl-tree-replace base -3 'replaced))
                   (set (avl-tree-set base -3 'set)))
              (list (tree-items adjoined)
                    (tree-items replaced)
                    (tree-items set)
                    (avl-tree-size set)
                    (and (valid-tree? adjoined)
                         (valid-tree? replaced)
                         (valid-tree? set))))))

(testing-registry-case
 'avl-persistent-roots '(portable data)
(test-equal 'avl-persistent-roots
            '(() ((2 . two)) ((1 . one) (2 . two)) #t #t #t)
            (let* ((root0 (make-avl-tree <))
                   (root1 (avl-tree-set root0 2 'two))
                   (root2 (avl-tree-set root1 1 'one)))
              (list (tree-items root0)
                    (tree-items root1)
                    (tree-items root2)
                    (valid-tree? root0)
                    (valid-tree? root1)
                    (valid-tree? root2)))))

(testing-registry-case
 'avl-insertion-rotations '(portable data)
(test-equal 'avl-insertion-rotations
            '(((1 . one) (2 . two) (3 . three))
              ((1 . one) (2 . two) (3 . three))
              ((1 . one) (2 . two) (3 . three))
              ((1 . one) (2 . two) (3 . three))
              #t #t #t #t)
            (let ((left (tree-from-pairs '((3 . three) (2 . two) (1 . one))))
                  (right (tree-from-pairs '((1 . one) (2 . two) (3 . three))))
                  (left-right
                   (tree-from-pairs '((3 . three) (1 . one) (2 . two))))
                  (right-left
                   (tree-from-pairs '((1 . one) (3 . three) (2 . two)))))
              (list (tree-items left)
                    (tree-items right)
                    (tree-items left-right)
                    (tree-items right-left)
                    (valid-tree? left)
                    (valid-tree? right)
                    (valid-tree? left-right)
                    (valid-tree? right-left)))))

(testing-registry-case
 'avl-delete-cases-and-persistence '(portable data)
(test-equal 'avl-delete-cases-and-persistence
            '(((1 . one) (2 . two) (3 . three) (4 . four) (5 . five))
              ((1 . one) (2 . two) (4 . four) (5 . five))
              ((2 . two) (4 . four) (5 . five))
              ((2 . two) (5 . five))
              ((2 . two) (5 . five))
              #t #t #t #t)
            (let* ((base
                    (tree-from-pairs
                     '((3 . three) (1 . one) (5 . five)
                       (2 . two) (4 . four))))
                   (without-root (avl-tree-delete base 3))
                   (without-leaf (avl-tree-delete without-root 1))
                   (without-child (avl-tree-delete without-leaf 4))
                   (without-missing (avl-tree-delete without-child 99)))
              (list (tree-items base)
                    (tree-items without-root)
                    (tree-items without-leaf)
                    (tree-items without-child)
                    (tree-items without-missing)
                    (valid-tree? without-root)
                    (valid-tree? without-leaf)
                    (valid-tree? without-child)
                    (eq? without-child without-missing)))))

(testing-registry-case
 'avl-deletion-sequence-rebalances '(portable data)
(test-equal 'avl-deletion-sequence-rebalances
            '((#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t) () 0)
            (let* ((tree
                    (tree-from-pairs
                     '((1 . 1) (2 . 2) (3 . 3) (4 . 4) (5 . 5)
                       (6 . 6) (7 . 7) (8 . 8) (9 . 9) (10 . 10)
                       (11 . 11) (12 . 12) (13 . 13) (14 . 14) (15 . 15))))
                   (result
                    (delete-sequence
                     tree
                     '(8 1 15 4 12 2 14 6 10 3 5 7 9 11 13)))
                   (final (cadr result)))
              (list (car result)
                    (tree-items final)
                    (avl-tree-size final)))))

(testing-registry-case
 'avl-traversal-order '(portable data)
(test-equal 'avl-traversal-order
            '((1 2 3 4 5) (5 4 3 2 1) (1 2 3 4 5))
            (let ((tree
                   (tree-from-pairs
                    '((3 . three) (1 . one) (5 . five)
                      (2 . two) (4 . four))))
                  (visited '()))
              (avl-tree-for-each
               (lambda (key value) (set! visited (cons key visited)))
               tree)
              (list
               (reverse
                (avl-tree-fold
                 (lambda (key value keys) (cons key keys))
                 '()
                 tree))
               (reverse
                (avl-tree-fold/reverse
                 (lambda (key value keys) (cons key keys))
                 '()
                 tree))
               (reverse visited)))))

(testing-registry-case
 'avl-extrema-and-neighbors '(portable data)
(test-equal 'avl-extrema-and-neighbors
            '((1 one) (5 five) (2 two) (4 four) none none)
            (let ((tree
                   (tree-from-pairs
                    '((3 . three) (1 . one) (5 . five)
                      (2 . two) (4 . four)))))
              (list
               (values-list (lambda () (avl-tree-min tree)))
               (values-list (lambda () (avl-tree-max tree)))
               (values-list
                (lambda () (avl-tree-key-predecessor tree 3)))
               (values-list
                (lambda () (avl-tree-key-successor tree 3)))
               (avl-tree-key-predecessor tree 1 (lambda () 'none))
               (avl-tree-key-successor tree 5 (lambda () 'none))))))

(testing-registry-case
 'avl-empty-boundaries-and-contracts '(portable data)
(test-equal 'avl-empty-boundaries-and-contracts
            '(none none #t #t #t #t #t)
            (let ((empty (make-avl-tree <)))
              (list
               (avl-tree-min empty (lambda () 'none))
               (avl-tree-max empty (lambda () 'none))
               (raises? (lambda () (avl-tree-min empty)))
               (raises? (lambda () (avl-tree-max empty)))
               (raises? (lambda () (avl-tree-size 'not-a-tree)))
               (raises?
                (lambda ()
                  (avl-tree-ref empty 1 (lambda () #f) values values)))
               (raises?
                (lambda () (avl-tree-ref empty 1 'not-a-procedure)))))))

(testing-registry-case
 'avl-neighbors-of-absent-boundaries '(portable data)
(test-equal 'avl-neighbors-of-absent-boundaries
            '((3 three) (5 five) none none)
            (let ((tree
                   (tree-from-pairs
                    '((1 . one) (3 . three) (5 . five) (7 . seven)))))
              (list
               (values-list
                (lambda () (avl-tree-key-predecessor tree 4)))
               (values-list
                (lambda () (avl-tree-key-successor tree 4)))
               (avl-tree-key-predecessor tree 0 (lambda () 'none))
               (avl-tree-key-successor tree 8 (lambda () 'none))))))

(testing-registry-case
 'avl-split '(portable data)
(test-equal 'avl-split
            '(((1 . one) (2 . two))
              ((1 . one) (2 . two) (3 . three))
              ((3 . three))
              ((3 . three) (4 . four) (5 . five))
              ((4 . four) (5 . five))
              #t #t #t #t #t)
            (let ((tree
                   (tree-from-pairs
                    '((3 . three) (1 . one) (5 . five)
                      (2 . two) (4 . four)))))
              (call-with-values
               (lambda () (avl-tree-split tree 3))
               (lambda (less less-or-equal equal greater-or-equal greater)
                 (list (tree-items less)
                       (tree-items less-or-equal)
                       (tree-items equal)
                       (tree-items greater-or-equal)
                       (tree-items greater)
                       (valid-tree? less)
                       (valid-tree? less-or-equal)
                       (valid-tree? equal)
                       (valid-tree? greater-or-equal)
                       (valid-tree? greater)))))))

(testing-registry-case
 'avl-split-absent-boundary '(portable data)
(test-equal 'avl-split-absent-boundary
            '(((1 . one) (3 . three))
              ((1 . one) (3 . three))
              ()
              ((5 . five) (7 . seven))
              ((5 . five) (7 . seven))
              #t)
            (let ((tree
                   (tree-from-pairs
                    '((1 . one) (3 . three) (5 . five) (7 . seven)))))
              (call-with-values
               (lambda () (avl-tree-split tree 4))
               (lambda ranges
                 (append (map tree-items ranges)
                         (list
                          (let loop ((rest ranges))
                            (or (null? rest)
                                (and (valid-tree? (car rest))
                                     (loop (cdr rest))))))))))))

(testing-registry-case
 'avl-catenate-and-monotone-map '(portable data)
(test-equal 'avl-catenate-and-monotone-map
            '(((1 . one) (2 . two) (3 . three) (4 . four) (5 . five))
              ((2 . one) (4 . two) (6 . three) (8 . four) (10 . five))
              #t #t)
            (let* ((left (tree-from-pairs '((1 . one) (2 . two))))
                   (right (tree-from-pairs '((4 . four) (5 . five))))
                   (whole (avl-tree-catenate left 3 'three right))
                   (mapped
                    (avl-tree-map/monotone
                     (lambda (key value) (values (* key 2) value))
                     whole)))
              (list (tree-items whole)
                    (tree-items mapped)
                    (valid-tree? whole)
                    (valid-tree? mapped)))))

(testing-registry-case
 'avl-alist-conversion '(portable data)
(test-equal 'avl-alist-conversion
            '(((1 . one) (2 . two) (3 . THREE)) #t)
            (let ((tree
                   (alist->avl-tree
                    <
                    '((3 . three) (1 . one) (2 . two) (3 . THREE)))))
              (list (avl-tree->alist tree) (valid-tree? tree)))))

(testing-registry-case
 'avl-operation-sequence-matches-model '(portable data)
(test-equal 'avl-operation-sequence-matches-model
            '(#t
              ((3 . THREE) (4 . four) (5 . five) (6 . six)
               (7 . seven) (9 . nine))
              6)
            (run-operation-sequence
             '((put 5 five)
               (put 2 two)
               (put 8 eight)
               (put 1 one)
               (put 3 three)
               (put 7 seven)
               (put 9 nine)
               (put 3 THREE)
               (delete 2)
               (put 6 six)
               (delete 8)
               (delete 1)
               (delete 42)
               (put 4 four)))))

(testing-registry-case
 'avl-permuted-stress-preserves-every-root '(portable data stress)
(test-equal 'avl-permuted-stress-preserves-every-root
            '(#t #t #t 257 0 ())
            (call-with-values
             (lambda () (stress-insertions 257))
             (lambda (full insertions-valid?)
               (call-with-values
                (lambda () (stress-deletions full 257))
                (lambda (empty deletions-valid?)
                  (list insertions-valid?
                        deletions-valid?
                        (tree-has-numbered-values? full 257)
                        (avl-tree-size full)
                        (avl-tree-size empty)
                        (tree-items empty))))))))

(testing-runner-main "Data AVL tree" (command-line))
