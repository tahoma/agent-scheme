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

(define (tree-insert/update tree key value)
  "Insert KEY/VALUE into TREE or update KEY's existing value."
  (call-with-values
   (lambda ()
     (tree-search integer-comparator
                  tree
                  key
                  (lambda (insert ignore)
                    (insert key value 'inserted))
                  (lambda (old-key old-value update remove)
                    (update old-key value 'updated))))
   (lambda (next status)
     (values next status))))

(define (tree-remove-key tree key)
  "Remove KEY from TREE when present."
  (call-with-values
   (lambda ()
     (tree-search integer-comparator
                  tree
                  key
                  (lambda (insert ignore)
                    (ignore 'missing))
                  (lambda (old-key old-value update remove)
                    (remove old-value))))
   (lambda (next status)
     (values next status))))

(define (insert-only tree key value)
  "Return TREE after inserting KEY/VALUE."
  (call-with-values
   (lambda () (tree-insert/update tree key value))
   (lambda (next status) next)))

(define (remove-only tree key)
  "Return TREE after removing KEY."
  (call-with-values
   (lambda () (tree-remove-key tree key))
   (lambda (next status) next)))

(define (tree-items tree)
  "Return TREE's key/value pairs in key order."
  (tree-fold/reverse
   (lambda (key value acc)
     (cons (cons key value) acc))
   '()
   tree))

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

(check 'successor-and-predecessor
       (list (tree-key-successor integer-comparator tree 2 (lambda () 'none))
             (tree-key-predecessor integer-comparator tree 3 (lambda () 'none))
             (tree-key-successor integer-comparator tree 4 (lambda () 'none))
             (tree-key-predecessor integer-comparator tree 1 (lambda () 'none)))
       '(3 2 none none))

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

(finish-rbtree-tests)
