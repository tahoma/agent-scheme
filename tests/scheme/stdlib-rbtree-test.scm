;;; Portable red-black tree stdlib helper tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Focused smoke coverage for the adapted SRFI 146 `nieper/rbtree` helper.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib rbtree))

;; Number of failed red-black tree helper checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed red-black tree check."
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

(define (finish-rbtree-tests)
  "Report the red-black tree helper test result."
  (if (= failures 0)
      (begin
        (display "Red-black tree helper tests passed")
        (newline))
      (begin
        (display failures)
        (display " red-black tree helper test failure(s)")
        (newline)
        (error "red-black tree helper tests failed" failures))))

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

(check 'folds-in-key-order
       (tree-items tree)
       '((1 . one) (2 . two) (3 . three) (4 . four)))

(check 'inserts-report-status
       (call-with-values
        (lambda () (tree-insert/update tree 5 'five))
        (lambda (next status)
          (list status (tree-items next))))
       '(inserted ((1 . one) (2 . two) (3 . three) (4 . four) (5 . five))))

(check 'updates-existing-key
       (call-with-values
        (lambda () (tree-insert/update tree 3 'THREE))
        (lambda (next status)
          (list status (tree-items next))))
       '(updated ((1 . one) (2 . two) (3 . THREE) (4 . four))))

(check 'removes-existing-key
       (call-with-values
        (lambda () (tree-remove-key tree 2))
        (lambda (next removed)
          (list removed (tree-items next))))
       '(two ((1 . one) (3 . three) (4 . four))))

(check 'missing-remove-returns-failure-status
       (call-with-values
        (lambda () (tree-remove-key tree 9))
        (lambda (next status)
          (list status (tree-items next))))
       '(missing ((1 . one) (2 . two) (3 . three) (4 . four))))

(check 'empty-tree-behavior
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
                  (list status (tree-items next))))))
       '(() seed seed #t none none (missing ())))

(check 'successor-and-predecessor
       (list (tree-key-successor integer-comparator tree 2 (lambda () 'none))
             (tree-key-predecessor integer-comparator tree 3 (lambda () 'none))
             (tree-key-successor integer-comparator tree 4 (lambda () 'none))
             (tree-key-predecessor integer-comparator tree 1 (lambda () 'none)))
       '(3 2 none none))

(check 'successor-and-predecessor-gaps
       (let ((gap-tree
              (pairs->tree integer-comparator
                           '((1 . one) (3 . three) (5 . five)))))
         (list (tree-key-successor integer-comparator gap-tree 2 (lambda () 'none))
               (tree-key-predecessor integer-comparator gap-tree 4 (lambda () 'none))
               (tree-key-successor integer-comparator gap-tree 0 (lambda () 'none))
               (tree-key-predecessor integer-comparator gap-tree 6 (lambda () 'none))
               (tree-key-successor integer-comparator gap-tree 5 (lambda () 'none))
               (tree-key-predecessor integer-comparator gap-tree 1 (lambda () 'none))))
       '(3 3 1 5 none none))

(check 'for-each-visits-in-key-order
       (let ((seen '()))
         (tree-for-each
          (lambda (key value)
            (set! seen (cons (list key value) seen)))
          tree)
         (reverse seen))
       '((1 one) (2 two) (3 three) (4 four)))

(check 'generator-yields-key-value-lists
       (let ((gen (tree-generator tree)))
         (list (gen) (gen) (gen) (gen) (eof-object? (gen))))
       '((1 one) (2 two) (3 three) (4 four) #t))

(check 'map-transforms-values
       (tree-items
        (tree-map
         (lambda (key value)
           (values key (list value key)))
         tree))
       '((1 one 1) (2 two 2) (3 three 3) (4 four 4)))

(check 'map-transforms-monotone-keys
       (tree-items
        (tree-map
         (lambda (key value)
           (values (+ key 10) value))
         tree))
       '((11 . one) (12 . two) (13 . three) (14 . four)))

(check 'catenate-joins-trees
       (tree-items
        (tree-catenate
         (pairs->tree integer-comparator '((1 . one) (2 . two)))
         3
         'three
         (pairs->tree integer-comparator '((4 . four) (5 . five)))))
       '((1 . one) (2 . two) (3 . three) (4 . four) (5 . five)))

(check 'catenate-allows-empty-left-tree
       (tree-items
        (tree-catenate
         (make-tree)
         1
         'one
         (pairs->tree integer-comparator '((2 . two) (3 . three)))))
       '((1 . one) (2 . two) (3 . three)))

(check 'catenate-allows-empty-right-tree
       (tree-items
        (tree-catenate
         (pairs->tree integer-comparator '((1 . one) (2 . two)))
         3
         'three
         (make-tree)))
       '((1 . one) (2 . two) (3 . three)))

(check 'catenate-balances-unequal-heights
       (tree-items
        (tree-catenate
         (pairs->tree integer-comparator '((1 . one) (2 . two)))
         3
         'three
         (pairs->tree integer-comparator
                      '((4 . four) (5 . five) (6 . six) (7 . seven)
                        (8 . eight) (9 . nine) (10 . ten)))))
       '((1 . one) (2 . two) (3 . three) (4 . four) (5 . five)
         (6 . six) (7 . seven) (8 . eight) (9 . nine) (10 . ten)))

(check 'split-partitions-tree
       (call-with-values
        (lambda () (tree-split integer-comparator tree 3))
        (lambda (less less/equal equal greater/equal greater)
          (list (tree-items less)
                (tree-items less/equal)
                (tree-items equal)
                (tree-items greater/equal)
                (tree-items greater))))
       '(((1 . one) (2 . two))
         ((1 . one) (2 . two) (3 . three))
         ((3 . three))
         ((3 . three) (4 . four))
         ((4 . four))))

(check 'split-partitions-absent-boundary
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
                  (tree-items greater)))))
       '(((1 . one))
         ((1 . one))
         ()
         ((3 . three) (5 . five))
         ((3 . three) (5 . five))))

(check 'split-empty-tree
       (call-with-values
        (lambda () (tree-split integer-comparator (make-tree) 3))
        (lambda (less less/equal equal greater/equal greater)
          (list (tree-items less)
                (tree-items less/equal)
                (tree-items equal)
                (tree-items greater/equal)
                (tree-items greater))))
       '(() () () () ()))

(check 'string-key-comparator
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
                                        (lambda () 'none))))))
       '(updated
         (("alpha" . a) ("bravo" . b) ("charlie" . c))
         (("alpha" . a) ("bravo" . B) ("charlie" . c))
         "charlie"
         "alpha"))

(check 'operation-sequence-matches-sorted-model
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
          (put 4 four)))
       '(#t
         (inserted inserted inserted inserted inserted inserted inserted updated
                   two inserted eight one missing inserted)
         ((3 . three) (4 . four) (5 . FIVE) (6 . six)
          (7 . seven) (9 . nine))))

(check 'deletion-sequence-rebalances-tree
       (run-deletion-sequence '(8 1 15 4 12 2 14 6 10 3 5 7 9 11 13))
       '(#t
         (8 1 15 4 12 2 14 6 10 3 5 7 9 11 13)
         ()))

(finish-rbtree-tests)
