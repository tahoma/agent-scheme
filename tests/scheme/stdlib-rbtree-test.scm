;;; Portable red-black tree stdlib helper tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Focused smoke coverage for the adapted SRFI 146 `nieper/rbtree` helper.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib rbtree)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Comparator shared by the tree-search tests.
(define integer-comparator
  (make-comparator integer? = < number-hash))

(define (tree-insert/update-with comparator tree key value)
  "Insert KEY/VALUE into TREE using COMPARATOR, or update an existing value."
  (call-with-values
   (lambda ()
     (tree-search comparator
                  tree
                  key
                  (lambda (insert ignore)
                    (insert key value 'inserted))
                  (lambda (old-key old-value update remove)
                    (update old-key value 'updated))))
   (lambda (next status)
     (values next status))))

(define (tree-insert/update tree key value)
  "Insert KEY/VALUE into TREE or update KEY's existing value."
  (tree-insert/update-with integer-comparator tree key value))

(define (tree-remove-key-with comparator tree key)
  "Remove KEY from TREE using COMPARATOR when present."
  (call-with-values
   (lambda ()
     (tree-search comparator
                  tree
                  key
                  (lambda (insert ignore)
                    (ignore 'missing))
                  (lambda (old-key old-value update remove)
                    (remove old-value))))
   (lambda (next status)
     (values next status))))

(define (tree-remove-key tree key)
  "Remove KEY from TREE when present."
  (tree-remove-key-with integer-comparator tree key))

(define (insert-only-with comparator tree key value)
  "Return TREE after inserting KEY/VALUE using COMPARATOR."
  (call-with-values
   (lambda () (tree-insert/update-with comparator tree key value))
   (lambda (next status) next)))

(define (insert-only tree key value)
  "Return TREE after inserting KEY/VALUE."
  (insert-only-with integer-comparator tree key value))

(define (remove-only tree key)
  "Return TREE after removing KEY."
  (call-with-values
   (lambda () (tree-remove-key tree key))
   (lambda (next status) next)))

(define (pairs->tree comparator pairs)
  "Return a tree containing PAIRS ordered by COMPARATOR."
  (let loop ((tree (make-tree)) (pairs pairs))
    (if (null? pairs)
        tree
        (let ((pair (car pairs)))
          (loop (insert-only-with comparator tree (car pair) (cdr pair))
                (cdr pairs))))))

(define (tree-items tree)
  "Return TREE's key/value pairs in key order."
  (tree-fold/reverse
   (lambda (key value acc)
     (cons (cons key value) acc))
   '()
   tree))

(define (model-insert/update key value model)
  "Return sorted integer MODEL with KEY inserted or updated to VALUE."
  (cond
   ((null? model)
    (list (cons key value)))
   ((< key (car (car model)))
    (cons (cons key value) model))
   ((= key (car (car model)))
    (cons (cons key value) (cdr model)))
   (else
    (cons (car model)
          (model-insert/update key value (cdr model))))))

(define (model-remove key model)
  "Return sorted integer MODEL without KEY."
  (cond
   ((null? model)
    '())
   ((< key (car (car model)))
    model)
   ((= key (car (car model)))
    (cdr model))
   (else
    (cons (car model) (model-remove key (cdr model))))))

(define (operation-key operation)
  "Return OPERATION's key field."
  (car (cdr operation)))

(define (operation-value operation)
  "Return OPERATION's value field."
  (car (cdr (cdr operation))))

(define (run-operation-sequence operations)
  "Return consistency, statuses, and final items for OPERATIONS."
  (let loop ((operations operations)
             (tree (make-tree))
             (model '())
             (consistent? #t)
             (statuses '()))
    (if (null? operations)
        (list consistent? (reverse statuses) (tree-items tree))
        (let ((operation (car operations)))
          (if (eq? (car operation) 'put)
              (call-with-values
               (lambda ()
                 (tree-insert/update tree
                                     (operation-key operation)
                                     (operation-value operation)))
               (lambda (next status)
                 (let ((next-model
                        (model-insert/update (operation-key operation)
                                             (operation-value operation)
                                             model)))
                   (loop (cdr operations)
                         next
                         next-model
                         (and consistent? (equal? (tree-items next) next-model))
                         (cons status statuses)))))
              (call-with-values
               (lambda () (tree-remove-key tree (operation-key operation)))
               (lambda (next status)
                 (let ((next-model
                        (model-remove (operation-key operation) model)))
                   (loop (cdr operations)
                         next
                         next-model
                         (and consistent? (equal? (tree-items next) next-model))
                         (cons status statuses))))))))))

(define (run-deletion-sequence keys)
  "Return consistency, removed values, and final items for removing KEYS."
  (let ((base '((1 . 1) (2 . 2) (3 . 3) (4 . 4) (5 . 5)
                (6 . 6) (7 . 7) (8 . 8) (9 . 9) (10 . 10)
                (11 . 11) (12 . 12) (13 . 13) (14 . 14) (15 . 15))))
    (let loop ((keys keys)
               (tree (pairs->tree integer-comparator base))
               (model base)
               (consistent? #t)
               (removed '()))
      (if (null? keys)
          (list consistent? (reverse removed) (tree-items tree))
          (call-with-values
           (lambda () (tree-remove-key tree (car keys)))
           (lambda (next status)
             (let ((next-model (model-remove (car keys) model)))
               (loop (cdr keys)
                     next
                     next-model
                     (and consistent? (equal? (tree-items next) next-model))
                     (cons status removed)))))))))

;; Shared populated tree used by the representative helper checks.
(define tree
  (insert-only
   (insert-only
    (insert-only
     (insert-only (make-tree) 3 'three)
     1
     'one)
    4
    'four)
   2
   'two))

(testing-registry-case
 'folds-in-key-order '(portable stdlib)
 ("stdlib-rbtree-test.scm" 195)
(test-equal 'folds-in-key-order
             '((1 . one) (2 . two) (3 . three) (4 . four))
             (tree-items tree)))

(testing-registry-case
 'inserts-report-status '(portable stdlib)
 ("stdlib-rbtree-test.scm" 202)
(test-equal 'inserts-report-status
             '(inserted ((1 . one) (2 . two) (3 . three) (4 . four) (5 . five)))
             (call-with-values
        (lambda () (tree-insert/update tree 5 'five))
        (lambda (next status)
          (list status (tree-items next))))))

(testing-registry-case
 'updates-existing-key '(portable stdlib)
 ("stdlib-rbtree-test.scm" 212)
(test-equal 'updates-existing-key
             '(updated ((1 . one) (2 . two) (3 . THREE) (4 . four)))
             (call-with-values
        (lambda () (tree-insert/update tree 3 'THREE))
        (lambda (next status)
          (list status (tree-items next))))))

(testing-registry-case
 'removes-existing-key '(portable stdlib)
 ("stdlib-rbtree-test.scm" 222)
(test-equal 'removes-existing-key
             '(two ((1 . one) (3 . three) (4 . four)))
             (call-with-values
        (lambda () (tree-remove-key tree 2))
        (lambda (next removed)
          (list removed (tree-items next))))))

(testing-registry-case
 'missing-remove-returns-failure-status '(portable stdlib)
 ("stdlib-rbtree-test.scm" 232)
(test-equal 'missing-remove-returns-failure-status
             '(missing ((1 . one) (2 . two) (3 . three) (4 . four)))
             (call-with-values
        (lambda () (tree-remove-key tree 9))
        (lambda (next status)
          (list status (tree-items next))))))

(testing-registry-case
 'empty-tree-behavior '(portable stdlib)
 ("stdlib-rbtree-test.scm" 242)
(test-equal 'empty-tree-behavior
             '(() seed seed #t none none (missing ()))
             (let ((empty (make-tree)))
         (list (tree-items empty)
               (tree-fold (lambda (key value acc) 'called) 'seed empty)
               (tree-fold/reverse (lambda (key value acc) 'called) 'seed empty)
               (let ((gen (tree-generator empty)))
                 (eof-object? (gen)))
               (tree-key-successor integer-comparator empty 1 (lambda () 'none))
               (tree-key-predecessor integer-comparator empty 1 (lambda () 'none))
               (call-with-values
                (lambda ()
                  (tree-search integer-comparator
                               empty
                               1
                               (lambda (insert ignore) (ignore 'missing))
                               (lambda (key value update remove) 'unexpected)))
                (lambda (next status)
                  (list status (tree-items next))))))))

(testing-registry-case
 'successor-and-predecessor '(portable stdlib)
 ("stdlib-rbtree-test.scm" 265)
(test-equal 'successor-and-predecessor
             '(3 2 none none)
             (list (tree-key-successor integer-comparator tree 2 (lambda () 'none))
             (tree-key-predecessor integer-comparator tree 3 (lambda () 'none))
             (tree-key-successor integer-comparator tree 4 (lambda () 'none))
             (tree-key-predecessor integer-comparator tree 1 (lambda () 'none)))))

(testing-registry-case
 'successor-and-predecessor-gaps '(portable stdlib)
 ("stdlib-rbtree-test.scm" 275)
(test-equal 'successor-and-predecessor-gaps
             '(3 3 1 5 none none)
             (let ((gap-tree
              (pairs->tree integer-comparator
                           '((1 . one) (3 . three) (5 . five)))))
         (list (tree-key-successor integer-comparator gap-tree 2 (lambda () 'none))
               (tree-key-predecessor integer-comparator gap-tree 4 (lambda () 'none))
               (tree-key-successor integer-comparator gap-tree 0 (lambda () 'none))
               (tree-key-predecessor integer-comparator gap-tree 6 (lambda () 'none))
               (tree-key-successor integer-comparator gap-tree 5 (lambda () 'none))
               (tree-key-predecessor integer-comparator gap-tree 1 (lambda () 'none))))))

(testing-registry-case
 'for-each-visits-in-key-order '(portable stdlib)
 ("stdlib-rbtree-test.scm" 290)
(test-equal 'for-each-visits-in-key-order
             '((1 one) (2 two) (3 three) (4 four))
             (let ((seen '()))
         (tree-for-each
          (lambda (key value)
            (set! seen (cons (list key value) seen)))
          tree)
         (reverse seen))))

(testing-registry-case
 'generator-yields-key-value-lists '(portable stdlib)
 ("stdlib-rbtree-test.scm" 302)
(test-equal 'generator-yields-key-value-lists
             '((1 one) (2 two) (3 three) (4 four) #t)
             (let ((gen (tree-generator tree)))
         (list (gen) (gen) (gen) (gen) (eof-object? (gen))))))

(testing-registry-case
 'map-transforms-values '(portable stdlib)
 ("stdlib-rbtree-test.scm" 310)
(test-equal 'map-transforms-values
             '((1 one 1) (2 two 2) (3 three 3) (4 four 4))
             (tree-items
        (tree-map
         (lambda (key value)
           (values key (list value key)))
         tree))))

(testing-registry-case
 'map-transforms-monotone-keys '(portable stdlib)
 ("stdlib-rbtree-test.scm" 321)
(test-equal 'map-transforms-monotone-keys
             '((11 . one) (12 . two) (13 . three) (14 . four))
             (tree-items
        (tree-map
         (lambda (key value)
           (values (+ key 10) value))
         tree))))

(testing-registry-case
 'catenate-joins-trees '(portable stdlib)
 ("stdlib-rbtree-test.scm" 332)
(test-equal 'catenate-joins-trees
             '((1 . one) (2 . two) (3 . three) (4 . four) (5 . five))
             (tree-items
        (tree-catenate
         (pairs->tree integer-comparator '((1 . one) (2 . two)))
         3
         'three
         (pairs->tree integer-comparator '((4 . four) (5 . five)))))))

(testing-registry-case
 'catenate-allows-empty-left-tree '(portable stdlib)
 ("stdlib-rbtree-test.scm" 344)
(test-equal 'catenate-allows-empty-left-tree
             '((1 . one) (2 . two) (3 . three))
             (tree-items
        (tree-catenate
         (make-tree)
         1
         'one
         (pairs->tree integer-comparator '((2 . two) (3 . three)))))))

(testing-registry-case
 'catenate-allows-empty-right-tree '(portable stdlib)
 ("stdlib-rbtree-test.scm" 356)
(test-equal 'catenate-allows-empty-right-tree
             '((1 . one) (2 . two) (3 . three))
             (tree-items
        (tree-catenate
         (pairs->tree integer-comparator '((1 . one) (2 . two)))
         3
         'three
         (make-tree)))))

(testing-registry-case
 'catenate-balances-unequal-heights '(portable stdlib)
 ("stdlib-rbtree-test.scm" 368)
(test-equal 'catenate-balances-unequal-heights
             '((1 . one) (2 . two) (3 . three) (4 . four) (5 . five)
         (6 . six) (7 . seven) (8 . eight) (9 . nine) (10 . ten))
             (tree-items
        (tree-catenate
         (pairs->tree integer-comparator '((1 . one) (2 . two)))
         3
         'three
         (pairs->tree integer-comparator
                      '((4 . four) (5 . five) (6 . six) (7 . seven)
                        (8 . eight) (9 . nine) (10 . ten)))))))

(testing-registry-case
 'split-partitions-tree '(portable stdlib)
 ("stdlib-rbtree-test.scm" 383)
(test-equal 'split-partitions-tree
             '(((1 . one) (2 . two))
         ((1 . one) (2 . two) (3 . three))
         ((3 . three))
         ((3 . three) (4 . four))
         ((4 . four)))
             (call-with-values
        (lambda () (tree-split integer-comparator tree 3))
        (lambda (less less/equal equal greater/equal greater)
          (list (tree-items less)
                (tree-items less/equal)
                (tree-items equal)
                (tree-items greater/equal)
                (tree-items greater))))))

(testing-registry-case
 'split-partitions-absent-boundary '(portable stdlib)
 ("stdlib-rbtree-test.scm" 401)
(test-equal 'split-partitions-absent-boundary
             '(((1 . one))
         ((1 . one))
         ()
         ((3 . three) (5 . five))
         ((3 . three) (5 . five)))
             (let ((gap-tree
              (pairs->tree integer-comparator
                           '((1 . one) (3 . three) (5 . five)))))
         (call-with-values
          (lambda () (tree-split integer-comparator gap-tree 2))
          (lambda (less less/equal equal greater/equal greater)
            (list (tree-items less)
                  (tree-items less/equal)
                  (tree-items equal)
                  (tree-items greater/equal)
                  (tree-items greater)))))))

(testing-registry-case
 'split-empty-tree '(portable stdlib)
 ("stdlib-rbtree-test.scm" 422)
(test-equal 'split-empty-tree
             '(() () () () ())
             (call-with-values
        (lambda () (tree-split integer-comparator (make-tree) 3))
        (lambda (less less/equal equal greater/equal greater)
          (list (tree-items less)
                (tree-items less/equal)
                (tree-items equal)
                (tree-items greater/equal)
                (tree-items greater))))))

(testing-registry-case
 'string-key-comparator '(portable stdlib)
 ("stdlib-rbtree-test.scm" 436)
(test-equal 'string-key-comparator
             '(updated
         (("alpha" . a) ("bravo" . b) ("charlie" . c))
         (("alpha" . a) ("bravo" . B) ("charlie" . c))
         "charlie"
         "alpha")
             (let* ((string-comparator
               (make-comparator string? string=? string<? string-hash))
              (string-tree
               (pairs->tree string-comparator
                            '(("bravo" . b)
                              ("alpha" . a)
                              ("charlie" . c)))))
         (call-with-values
          (lambda ()
            (tree-insert/update-with string-comparator string-tree "bravo" 'B))
          (lambda (next status)
            (list status
                  (tree-items string-tree)
                  (tree-items next)
                  (tree-key-successor string-comparator
                                      string-tree
                                      "bravo"
                                      (lambda () 'none))
                  (tree-key-predecessor string-comparator
                                        string-tree
                                        "bravo"
                                        (lambda () 'none))))))))

(testing-registry-case
 'operation-sequence-matches-sorted-model '(portable stdlib)
 ("stdlib-rbtree-test.scm" 468)
(test-equal 'operation-sequence-matches-sorted-model
             '(#t
         (inserted inserted inserted inserted inserted inserted inserted updated
                   two inserted eight one missing inserted)
         ((3 . three) (4 . four) (5 . FIVE) (6 . six)
          (7 . seven) (9 . nine)))
             (run-operation-sequence
        '((put 5 five)
          (put 2 two)
          (put 8 eight)
          (put 1 one)
          (put 3 three)
          (put 7 seven)
          (put 9 nine)
          (put 5 FIVE)
          (delete 2)
          (put 6 six)
          (delete 8)
          (delete 1)
          (delete 42)
          (put 4 four)))))

(testing-registry-case
 'deletion-sequence-rebalances-tree '(portable stdlib)
 ("stdlib-rbtree-test.scm" 493)
(test-equal 'deletion-sequence-rebalances-tree
             '(#t
         (8 1 15 4 12 2 14 6 10 3 5 7 9 11 13)
         ())
             (run-deletion-sequence '(8 1 15 4 12 2 14 6 10 3 5 7 9 11 13))))

(testing-runner-main "Stdlib Rbtree portable tests" (command-line))
