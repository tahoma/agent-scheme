;;; SRFI 146 red-black tree helper for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib rbtree)` as a portable R7RS adaptation of the
;;; `nieper/rbtree` helper used by the official SRFI 146 ordered mapping source:
;;; https://github.com/scheme-requests-for-implementation/srfi-146/tree/master/nieper.
;;; Local patches rename the internal helper library, inline the upstream
;;; implementation for Consent Scheme's source-library loader, adapt imports to
;;; local stdlib libraries, and document exported procedures with Consent Scheme
;;; metadata. This library is stdlib substrate for `(scheme mapping)` /
;;; `(srfi 146)`, not part of the R7RS-small conformance surface.

(define-library (stdlib rbtree)
  (export make-tree tree-search tree-for-each tree-fold tree-fold/reverse
          tree-generator tree-key-predecessor tree-key-successor
          tree-map tree-catenate tree-split)
  (import (scheme base)
          (scheme case-lambda)
          (stdlib and-let-star)
          (stdlib receive)
          (stdlib generator)
          (stdlib comparator))
  (begin
    ;; Tree items keep keys and values as a two-slot vector.
    (define (make-item key value)
      "Return an internal tree item for KEY and VALUE."
      (vector key value))

    (define (item-key item)
      "Return ITEM's key."
      (vector-ref item 0))

    (define (item-value item)
      "Return ITEM's value."
      (vector-ref item 1))

    ;; Red-black tree nodes are vectors tagged with their color.
    (define (node color left item right)
      "Return an internal tree node."
      (vector color left item right))

    (define (color node)
      "Return NODE's color tag."
      (vector-ref node 0))

    (define (left node)
      "Return NODE's left child."
      (vector-ref node 1))

    (define (item node)
      "Return NODE's key/value item, or #f for an empty sentinel."
      (vector-ref node 2))

    (define (right node)
      "Return NODE's right child."
      (vector-ref node 3))

    (define (red left item right)
      "Return a red node."
      (node 'red left item right))

    (define (black . args)
      "Return an empty or populated black node."
      (apply
       (case-lambda
        (() (black #f #f #f))
        ((left item right) (node 'black left item right)))
       args))

    (define (white . args)
      "Return an empty or populated white deletion sentinel."
      (apply
       (case-lambda
        (() (white #f #f #f))
        ((left item right) (node 'white left item right)))
       args))

    (define (red? node)
      "Return #t when NODE is red."
      (eq? (color node) 'red))

    (define (black? node)
      "Return #t when NODE is black."
      (eq? (color node) 'black))

    (define (white? node)
      "Return #t when NODE is white."
      (eq? (color node) 'white))

    ;; Pattern matcher for the internal node shapes used by the balancing code.
    (define-syntax tree-match
      (syntax-rules ()
        ((tree-match tree (pattern . expression*) ...)
         (compile-patterns (expression* ...) tree () (pattern ...)))))

    ;; Compile a sequence of tree patterns into guarded clauses.
    (define-syntax compile-patterns
      (syntax-rules ()
        ((compile-patterns (expression* ...) tree (clauses ...) ())
         (call-with-current-continuation
          (lambda (return)
            (or (and-let* clauses
                  (call-with-values
                   (lambda () . expression*)
                   return))
                ...
                (error "tree does not match any pattern" tree)))))
        ((compile-patterns e tree clauses* (pattern . pattern*))
         (compile-pattern tree pattern
                          (add-pattern e tree clauses* pattern*)))))

    ;; Append one compiled pattern's clauses to the current matcher.
    (define-syntax add-pattern
      (syntax-rules ()
        ((add-pattern e tree (clauses ...) pattern* new-clauses)
         (compile-patterns e tree (clauses ... new-clauses) pattern*))))

    ;; Compile one tree pattern into `and-let*` clauses.
    (define-syntax compile-pattern
      (syntax-rules (_ and red? black? white? ? node red black white)
        ((compile-pattern tree (red? x) (k ...))
         (k ... (((red? tree)) (x tree))))
        ((compile-pattern tree (black? x) (k ...))
         (k ... (((black? tree)) (x tree))))
        ((compile-pattern tree (white? x) (k ...))
         (k ... (((white? tree)) (x tree))))
        ((compile-pattern tree (black) (k ...))
         (k ... (((black? tree)) ((not (item tree))))))
        ((compile-pattern tree (white) (k ...))
         (k ... (((white? tree)) ((not (item tree))))))
        ((compile-pattern tree (and pt ...) k*)
         (compile-subpatterns () ((t pt) ...)
                              (compile-and-pattern tree t k*)))
        ((compile-pattern tree (node pc pa px pb) k*)
         (compile-subpatterns () ((c pc) (a pa) (x px) (b pb))
                              (compile-node-pattern tree c a x b k*)))
        ((compile-pattern tree (red pa px pb) k*)
         (compile-subpatterns () ((a pa) (x px) (b pb))
                              (compile-color-pattern red? tree a x b k*)))
        ((compile-pattern tree (black pa px pb) k*)
         (compile-subpatterns () ((a pa) (x px) (b pb))
                              (compile-color-pattern black? tree a x b k*)))
        ((compile-pattern tree (white pa px pb) k*)
         (compile-subpatterns () ((a pa) (x px) (b pb))
                              (compile-color-pattern white? tree a x b k*)))
        ((compile-pattern tree _ (k ...))
         (k ... ()))
        ((compile-pattern tree x (k ...))
         (k ... ((x tree))))))

    ;; Add a binding that exposes the whole tree to an `and` subpattern.
    (define-syntax compile-and-pattern
      (syntax-rules ()
        ((compile-and-pattern tree t (k ...) clauses)
         (k ... ((t tree) . clauses)))))

    ;; Compile a node subpattern after proving the tree is populated.
    (define-syntax compile-node-pattern
      (syntax-rules ()
        ((compile-node-pattern tree c a x b (k ...) clauses)
         (k ... (((item tree))
                 (c (color tree))
                 (a (left tree))
                 (x (item tree))
                 (b (right tree)) . clauses)))))

    ;; Compile a color-specific node subpattern.
    (define-syntax compile-color-pattern
      (syntax-rules ()
        ((compile-color-pattern pred? tree a x b (k ...) clauses)
         (k ... (((item tree))
                 ((pred? tree))
                 (a (left tree))
                 (x (item tree))
                 (b (right tree)) . clauses)))))

    ;; Compile nested tree subpatterns left to right.
    (define-syntax compile-subpatterns
      (syntax-rules ()
        ((compile-subpatterns clauses () (k ...))
         (k ... clauses))
        ((compile-subpatterns clauses ((tree pattern) . rest) k*)
         (compile-pattern tree pattern (add-subpattern clauses rest k*)))))

    ;; Accumulate clauses produced by one nested subpattern.
    (define-syntax add-subpattern
      (syntax-rules ()
        ((add-subpattern (clause ...) rest k* clauses)
         (compile-subpatterns (clause ... . clauses) rest k*))))

    ;; Convert a red root back to the public black-root invariant.
    (define (blacken tree)
      "Return TREE with a red root changed to black."
      (tree-match tree
        ((red a x b)
         (black a x b))
        (t t)))

    ;; Temporarily redden a black tree before search/edit operations.
    (define (redden tree)
      "Return TREE with a black root changed to red when safe."
      (tree-match tree
        ((black (black? a) x (black? b))
         (red a x b))
        (t t)))

    ;; Resolve a white deletion sentinel back to black.
    (define (white->black tree)
      "Return TREE with a white root changed to black."
      (tree-match tree
        ((white)
         (black))
        ((white a x b)
         (black a x b))))

    (define (make-tree)
      "Return an empty red-black tree."
      #((parameters)
        (returns (type red-black-tree)
         (description "An empty red-black tree."))
        (effects allocation))
      (black))

    (define (tree-fold proc seed tree)
      "Fold PROC over TREE from lowest key to highest key."
      #((parameters
         (proc (type procedure)
          (description
           "Procedure called as (proc key value accumulator)."))
         (seed (type any)
          (description "Initial accumulator value."))
         (tree (type red-black-tree)
          (description "Tree to fold.")))
        (returns (type any)
         (description "Final accumulator value."))
        (effects procedure-call))
      (let loop ((acc seed) (tree tree))
        (tree-match tree
          ((black)
           acc)
          ((node _ a x b)
           (let* ((acc (loop acc a))
                  (acc (proc (item-key x) (item-value x) acc))
                  (acc (loop acc b)))
             acc)))))

    (define (tree-fold/reverse proc seed tree)
      "Fold PROC over TREE from highest key to lowest key."
      #((parameters
         (proc (type procedure)
          (description
           "Procedure called as (proc key value accumulator)."))
         (seed (type any)
          (description "Initial accumulator value."))
         (tree (type red-black-tree)
          (description "Tree to fold.")))
        (returns (type any)
         (description "Final accumulator value."))
        (effects procedure-call))
      (let loop ((acc seed) (tree tree))
        (tree-match tree
          ((black)
           acc)
          ((node _ a x b)
           (let* ((acc (loop acc b))
                  (acc (proc (item-key x) (item-value x) acc))
                  (acc (loop acc a)))
             acc)))))

    (define (tree-for-each proc tree)
      "Call PROC on each key/value pair in TREE by ascending key."
      #((parameters
         (proc (type procedure)
          (description "Procedure called as (proc key value)."))
         (tree (type red-black-tree)
          (description "Tree to traverse.")))
        (returns (type any)
         (description "Unspecified value."))
        (effects procedure-call))
      (tree-fold (lambda (key value acc)
                   (proc key value))
                 #f
                 tree))

    ;; Identity operation used when no rebalancing is required.
    (define (identity obj)
      "Return OBJ."
      obj)

    (define (tree-generator tree)
      "Return a generator over TREE's key/value lists."
      #((parameters
         (tree (type red-black-tree)
          (description "Tree to traverse.")))
        (returns (type procedure)
         (description
          "A generator yielding two-element key/value lists in key order."))
        (effects allocation state-write procedure-call))
      (make-coroutine-generator
       (lambda (yield)
         (tree-for-each (lambda item (yield item)) tree))))

    (define (tree-search comparator tree obj failure success)
      "Search TREE for OBJ and return an edited tree plus callback result."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to order keys."))
         (tree (type red-black-tree)
          (description "Tree to search."))
         (obj (type any)
          (description "Search key."))
         (failure (type procedure)
          (description
           ("Procedure called when OBJ is absent; it receives insert and"
            "ignore continuations.")))
         (success (type procedure)
          (description
           ("Procedure called when OBJ is present; it receives key, value,"
            "update, and remove continuations."))))
        (returns (type any)
         (description "Two values: the edited tree and callback result."))
        (effects allocation procedure-call))
      (receive (tree ret op)
          (let search ((tree (redden tree)))
            (tree-match tree
              ((black)
               (failure
                (lambda (new-key new-value ret)
                  (values (red (black) (make-item new-key new-value) (black))
                          ret
                          balance))
                (lambda (ret)
                  (values (black) ret identity))))
              ((and t (node c a x b))
               (let ((key (item-key x)))
                 (comparator-if<=> comparator obj key
                   (receive (a ret op) (search a)
                     (values (op (node c a x b)) ret op))
                   (success
                    key
                    (item-value x)
                    (lambda (new-key new-value ret)
                      (values (node c a (make-item new-key new-value) b)
                              ret
                              identity))
                    (lambda (ret)
                      (values
                       (tree-match t
                         ((red (black) x (black))
                          (black))
                         ((black (red a x b) _ (black))
                          (black a x b))
                         ((black (black) _ (black))
                          (white))
                         (_
                          (receive (x b) (min+delete b)
                            (rotate (node c a x b)))))
                       ret
                       rotate)))
                   (receive (b ret op) (search b)
                     (values (op (node c a x b)) ret op)))))))
        (values (blacken tree) ret)))

    (define (tree-key-successor comparator tree obj failure)
      "Return the least key in TREE greater than OBJ, or call FAILURE."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to order keys."))
         (tree (type red-black-tree)
          (description "Tree to search."))
         (obj (type any)
          (description "Key whose successor is requested."))
         (failure (type procedure)
          (description "Zero-argument procedure called when no successor exists.")))
        (returns (type any)
         (description "Successor key or FAILURE's result."))
        (effects procedure-call))
      (let loop ((return failure) (tree tree))
        (tree-match tree
          ((black)
           (return))
          ((node _ a x b)
           (let ((key (item-key x)))
             (comparator-if<=> comparator key obj
                               (loop return b)
                               (loop return b)
                               (loop (lambda () key) a)))))))

    (define (tree-key-predecessor comparator tree obj failure)
      "Return the greatest key in TREE less than OBJ, or call FAILURE."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to order keys."))
         (tree (type red-black-tree)
          (description "Tree to search."))
         (obj (type any)
          (description "Key whose predecessor is requested."))
         (failure (type procedure)
          (description "Zero-argument procedure called when no predecessor exists.")))
        (returns (type any)
         (description "Predecessor key or FAILURE's result."))
        (effects procedure-call))
      (let loop ((return failure) (tree tree))
        (tree-match tree
          ((black)
           (return))
          ((node _ a x b)
           (let ((key (item-key x)))
             (comparator-if<=> comparator key obj
                               (loop (lambda () key) b)
                               (loop return a)
                               (loop return a)))))))

    (define (tree-map proc tree)
      "Return a tree containing PROC-transformed key/value pairs from TREE."
      #((parameters
         (proc (type procedure)
          (description "Procedure called as (proc key value), returning two values."))
         (tree (type red-black-tree)
          (description "Tree to transform.")))
        (returns (type red-black-tree)
         (description "A tree with transformed items in the same shape."))
        (effects allocation procedure-call))
      (let loop ((tree tree))
        (tree-match tree
          ((black)
           (black))
          ((node c a x b)
           (receive (key value)
               (proc (item-key x) (item-value x))
             (node c (loop a) (make-item key value) (loop b)))))))

    (define (tree-catenate tree1 pivot-key pivot-value tree2)
      "Return TREE1, PIVOT-KEY/PIVOT-VALUE, and TREE2 as one tree."
      #((parameters
         (tree1 (type red-black-tree)
          (description "Tree whose keys precede PIVOT-KEY."))
         (pivot-key (type any)
          (description "Key joining the two trees."))
         (pivot-value (type any)
          (description "Value for PIVOT-KEY."))
         (tree2 (type red-black-tree)
          (description "Tree whose keys follow PIVOT-KEY.")))
        (returns (type red-black-tree)
         (description "A balanced catenation of the two trees and pivot."))
        (effects allocation))
      (let ((pivot (make-item pivot-key pivot-value))
            (height1 (black-height tree1))
            (height2 (black-height tree2)))
        (cond
         ((= height1 height2)
          (black tree1 pivot tree2))
         ((< height1 height2)
          (blacken
           (let loop ((tree tree2) (depth (- height2 height1)))
             (if (zero? depth)
                 (balance (red tree1 pivot tree))
                 (balance
                  (node (color tree)
                        (loop (left tree) (- depth 1))
                        (item tree)
                        (right tree)))))))
         (else
          (blacken
           (let loop ((tree tree1) (depth (- height1 height2)))
             (if (zero? depth)
                 (balance (red tree pivot tree2))
                 (balance
                  (node (color tree)
                        (left tree)
                        (item tree)
                        (loop (right tree) (- depth 1)))))))))))

    (define (tree-split comparator tree obj)
      "Split TREE around OBJ and return five boundary trees."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to order keys."))
         (tree (type red-black-tree)
          (description "Tree to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type any)
         (description
          ("Five values: keys below OBJ, keys at or below OBJ, an equal-key"
           "singleton or empty tree, keys at or above OBJ, and keys above OBJ.")))
        (effects allocation procedure-call))
      (let loop ((tree1 (black))
                 (tree2 (black))
                 (pivot1 #f)
                 (pivot2 #f)
                 (tree tree))
        (tree-match tree
          ((black)
           (let ((tree1 (catenate-left tree1 pivot1 (black)))
                 (tree2 (catenate-right (black) pivot2 tree2)))
             (values tree1 tree1 (black) tree2 tree2)))
          ((node _ a x b)
           (comparator-if<=> comparator obj (item-key x)
                             (loop tree1
                                   (catenate-right (blacken b) pivot2 tree2)
                                   pivot1
                                   x
                                   (blacken a))
                             (let* ((tree1
                                     (catenate-left tree1 pivot1 (blacken a)))
                                    (tree1+
                                     (catenate-left tree1 x (black)))
                                    (tree2
                                     (catenate-right (blacken b) pivot2 tree2))
                                    (tree2+
                                     (catenate-right (black) x tree2)))
                               (values tree1
                                       tree1+
                                       (black (black) x (black))
                                       tree2+
                                       tree2))
                             (loop (catenate-left tree1 pivot1 (blacken a))
                                   tree2
                                   x
                                   pivot2
                                   (blacken b)))))))

    ;; Catenate TREE1 and TREE2 using ITEM when ITEM is present.
    (define (catenate-left tree1 item tree2)
      "Return TREE1 catenated to ITEM and TREE2, or TREE2 when ITEM is absent."
      (if item
          (tree-catenate tree1 (item-key item) (item-value item) tree2)
          tree2))

    ;; Catenate TREE1 and TREE2 using ITEM when ITEM is present.
    (define (catenate-right tree1 item tree2)
      "Return TREE1 catenated to ITEM and TREE2, or TREE1 when ITEM is absent."
      (if item
          (tree-catenate tree1 (item-key item) (item-value item) tree2)
          tree1))

    ;; Black height is measured on the right spine, as in the upstream helper.
    (define (black-height tree)
      "Return TREE's black height."
      (let loop ((tree tree))
        (tree-match tree
          ((black)
           0)
          ((node red a x b)
           (loop b))
          ((node black a x b)
           (+ 1 (loop b))))))

    ;; Return the left descendant at DEPTH plus its parent.
    (define (left-tree tree depth)
      "Return TREE's left descendant at DEPTH and that descendant's parent."
      (let loop ((parent #f) (tree tree) (depth depth))
        (if (zero? depth)
            (values parent tree)
            (loop tree (left tree) (- depth 1)))))

    ;; Return the right descendant at DEPTH plus its parent.
    (define (right-tree tree depth)
      "Return TREE's right descendant at DEPTH and that descendant's parent."
      (let loop ((parent #f) (tree tree) (depth depth))
        (if (zero? depth)
            (values parent tree)
            (loop tree (right tree) (- depth 1)))))

    ;; Delete and return the minimum item in TREE.
    (define (min+delete tree)
      "Return TREE's minimum item and TREE without that item."
      (tree-match tree
        ((red (black) x (black))
         (values x (black)))
        ((black (black) x (black))
         (values x (white)))
        ((black (black) x (red a y b))
         (values x (black a y b)))
        ((node c a x b)
         (receive (v a) (min+delete a)
           (values v (rotate (node c a x b)))))))

    ;; Restore red-black invariants around TREE after insertion or catenation.
    (define (balance tree)
      "Return TREE with local red-black imbalance repaired."
      (tree-match tree
        ((black (red (red a x b) y c) z d)
         (red (black a x b) y (black c z d)))
        ((black (red a x (red b y c)) z d)
         (red (black a x b) y (black c z d)))
        ((black a x (red (red b y c) z d))
         (red (black a x b) y (black c z d)))
        ((black a x (red b y (red c z d)))
         (red (black a x b) y (black c z d)))
        ((white (red a x (red b y c)) z d)
         (black (black a x b) y (black c z d)))
        ((white a x (red (red b y c) z d))
         (black (black a x b) y (black c z d)))
        (t t)))

    ;; Rotate TREE after deletion to resolve white sentinels.
    (define (rotate tree)
      "Return TREE with deletion-time imbalance repaired."
      (tree-match tree
        ((red (white? a+x+b) y (black c z d))
         (balance (black (red (white->black a+x+b) y c) z d)))
        ((red (black a x b) y (white? c+z+d))
         (balance (black a x (red b y (white->black c+z+d)))))
        ((black (white? a+x+b) y (black c z d))
         (balance (white (red (white->black a+x+b) y c) z d)))
        ((black (black a x b) y (white? c+z+d))
         (balance (white a x (red b y (white->black c+z+d)))))
        ((black (white? a+w+b) x (red (black c y d) z e))
         (black (balance (black (red (white->black a+w+b) x c) y d)) z e))
        ((black (red a w (black b x c)) y (white? d+z+e))
         (black a w (balance (black b x (red c y (white->black d+z+e))))))
        (t t)))))
