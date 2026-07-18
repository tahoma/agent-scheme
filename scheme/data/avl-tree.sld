;;; Public persistent AVL tree library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Nodes remain private while representation-neutral lookup and invariant
;;; diagnostics are available through the public API.

(define-library (data avl-tree)
  (export make-avl-tree
          avl-tree?
          avl-tree-valid?
          avl-tree-ordering
          avl-tree-empty?
          avl-tree-size
          avl-tree-contains?
          avl-tree-ref
          avl-tree-ref/key
          avl-tree-ref/default
          avl-tree-adjoin
          avl-tree-set
          avl-tree-replace
          avl-tree-delete
          avl-tree-for-each
          avl-tree-fold
          avl-tree-fold/reverse
          avl-tree-min
          avl-tree-max
          avl-tree-key-predecessor
          avl-tree-key-successor
          avl-tree-split
          avl-tree-catenate
          avl-tree-map/monotone
          avl-tree->alist
          alist->avl-tree)
  (import (scheme base))
  (begin
    ;; Immutable AVL node caching its subtree height.
    (define-record-type <avl-node>
      (make-avl-node key value left right height)
      avl-node?
      (key avl-node-key)
      (value avl-node-value)
      (left avl-node-left)
      (right avl-node-right)
      (height avl-node-height-value))

    ;; Persistent AVL tree carrying ordering, root, and cached size.
    (define-record-type <avl-tree>
      (make-avl-tree-record ordering root size)
      raw-avl-tree?
      (ordering raw-avl-tree-ordering)
      (root avl-tree-root)
      (size raw-avl-tree-size))

    (define (avl-tree? object)
      "Return #t when OBJECT is a persistent AVL tree."
      #((parameters
         (object (type any) (description "Candidate object.")))
        (returns (type boolean)
         (description "Whether OBJECT is an AVL tree."))
        (effects pure))
      (raw-avl-tree? object))

    (define (avl-tree-ordering tree)
      "Return TREE's strict key-ordering procedure."
      #((parameters
         (tree (type avl-tree) (description "Tree to inspect.")))
        (returns (type procedure)
         (description "Strict ordering procedure."))
        (effects error))
      (ensure-avl-tree tree 'avl-tree-ordering)
      (raw-avl-tree-ordering tree))

    (define (avl-tree-size tree)
      "Return the number of associations in TREE."
      #((parameters
         (tree (type avl-tree) (description "Tree to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of associations."))
        (effects error))
      (ensure-avl-tree tree 'avl-tree-size)
      (raw-avl-tree-size tree))

    (define (make-avl-tree ordering)
      "Return an empty persistent AVL tree ordered by ORDERING."
      #((parameters
         (ordering (type procedure)
          (description "Strict ordering predicate for keys.")))
        (returns (type avl-tree)
         (description "New empty persistent AVL tree."))
        (effects allocation error))
      (if (not (procedure? ordering))
          (error "make-avl-tree: expected ordering procedure" ordering))
      (make-avl-tree-record ordering #f 0))

    (define (avl-tree-empty? tree)
      "Return #t when TREE contains no associations."
      #((parameters
         (tree (type avl-tree)
          (description "Tree to inspect.")))
        (returns (type boolean)
         (description "Whether TREE is empty."))
        (effects error))
      (ensure-avl-tree tree 'avl-tree-empty?)
      (= (avl-tree-size tree) 0))

    (define (ensure-avl-tree tree who)
      "Return TREE or raise an error naming WHO when it is not an AVL tree."
      (if (not (avl-tree? tree))
          (error "expected AVL tree" who tree))
      tree)

    (define (node-height node)
      "Return NODE's cached height, treating the empty root as zero."
      (if node (avl-node-height-value node) 0))

    (define (node-with-children key value left right)
      "Return a node for KEY and VALUE above LEFT and RIGHT."
      (make-avl-node key
                     value
                     left
                     right
                     (+ 1 (max (node-height left) (node-height right)))))

    (define (node-balance node)
      "Return NODE's left height minus its right height."
      (- (node-height (avl-node-left node))
         (node-height (avl-node-right node))))

    (define (rotate-left node)
      "Return NODE after one persistent left rotation."
      (let* ((right (avl-node-right node))
             (new-left
              (node-with-children
               (avl-node-key node)
               (avl-node-value node)
               (avl-node-left node)
               (avl-node-left right))))
        (node-with-children
         (avl-node-key right)
         (avl-node-value right)
         new-left
         (avl-node-right right))))

    (define (rotate-right node)
      "Return NODE after one persistent right rotation."
      (let* ((left (avl-node-left node))
             (new-right
              (node-with-children
               (avl-node-key node)
               (avl-node-value node)
               (avl-node-right left)
               (avl-node-right node))))
        (node-with-children
         (avl-node-key left)
         (avl-node-value left)
         (avl-node-left left)
         new-right)))

    (define (rebalance node)
      "Return NODE or a persistently rotated balanced replacement."
      (let ((balance (node-balance node)))
        (cond
         ((> balance 1)
          (if (< (node-balance (avl-node-left node)) 0)
              (rotate-right
               (node-with-children
                (avl-node-key node)
                (avl-node-value node)
                (rotate-left (avl-node-left node))
                (avl-node-right node)))
              (rotate-right node)))
         ((< balance -1)
          (if (> (node-balance (avl-node-right node)) 0)
              (rotate-left
               (node-with-children
                (avl-node-key node)
                (avl-node-value node)
                (avl-node-left node)
                (rotate-right (avl-node-right node))))
              (rotate-left node)))
         (else node))))

    (define (node-update node key value ordering mode)
      "Return NODE updated for KEY, VALUE, and MODE plus its size delta."
      (if (not node)
          (if (eq? mode 'replace)
              (values node 0)
              (values (make-avl-node key value #f #f 1) 1))
          (let ((node-key (avl-node-key node)))
            (cond
             ((ordering key node-key)
              (call-with-values
                  (lambda ()
                    (node-update (avl-node-left node)
                                 key
                                 value
                                 ordering
                                 mode))
                (lambda (left delta)
                  (if (eq? left (avl-node-left node))
                      (values node delta)
                      (values
                       (rebalance
                        (node-with-children
                         node-key
                         (avl-node-value node)
                         left
                         (avl-node-right node)))
                       delta)))))
             ((ordering node-key key)
              (call-with-values
                  (lambda ()
                    (node-update (avl-node-right node)
                                 key
                                 value
                                 ordering
                                 mode))
                (lambda (right delta)
                  (if (eq? right (avl-node-right node))
                      (values node delta)
                      (values
                       (rebalance
                        (node-with-children
                         node-key
                         (avl-node-value node)
                         (avl-node-left node)
                         right))
                       delta)))))
             ((eq? mode 'adjoin)
              (values node 0))
             (else
              (values
               (node-with-children
                node-key
                value
                (avl-node-left node)
                (avl-node-right node))
               0))))))

    (define (tree-update tree key value mode)
      "Return TREE updated at KEY with VALUE according to MODE."
      (ensure-avl-tree tree mode)
      (call-with-values
          (lambda ()
            (node-update (avl-tree-root tree)
                         key
                         value
                         (avl-tree-ordering tree)
                         mode))
        (lambda (root delta)
          (if (eq? root (avl-tree-root tree))
              tree
              (make-avl-tree-record
               (avl-tree-ordering tree)
               root
               (+ (avl-tree-size tree) delta))))))

    (define (avl-tree-adjoin tree key value)
      "Return TREE with KEY associated to VALUE only when KEY is absent."
      #((parameters
         (tree (type avl-tree) (description "Tree to update."))
         (key (type any) (description "Key to adjoin."))
         (value (type any) (description "Value to store.")))
        (returns (type avl-tree)
         (description "Persistently updated tree."))
        (effects allocation error procedure-call))
      (tree-update tree key value 'adjoin))

    (define (avl-tree-set tree key value)
      "Return TREE with KEY associated to VALUE."
      #((parameters
         (tree (type avl-tree) (description "Tree to update."))
         (key (type any) (description "Key to set."))
         (value (type any) (description "Value to store.")))
        (returns (type avl-tree)
         (description "Persistently updated tree."))
        (effects allocation error procedure-call))
      (tree-update tree key value 'set))

    (define (avl-tree-replace tree key value)
      "Return TREE with present KEY associated to VALUE."
      #((parameters
         (tree (type avl-tree) (description "Tree to update."))
         (key (type any) (description "Key to replace when present."))
         (value (type any) (description "Replacement value.")))
        (returns (type avl-tree)
         (description "Persistently updated or unchanged tree."))
        (effects allocation error procedure-call))
      (tree-update tree key value 'replace))

    (define (node-remove-minimum node)
      "Return NODE without its minimum plus the minimum key and value."
      (if (not (avl-node-left node))
          (values (avl-node-right node)
                  (avl-node-key node)
                  (avl-node-value node))
          (call-with-values
              (lambda ()
                (node-remove-minimum (avl-node-left node)))
            (lambda (left key value)
              (values
               (rebalance
                (node-with-children
                 (avl-node-key node)
                 (avl-node-value node)
                 left
                 (avl-node-right node)))
               key
               value)))))

    (define (node-delete node key ordering)
      "Return NODE without KEY plus the resulting size delta."
      (if (not node)
          (values node 0)
          (let ((node-key (avl-node-key node)))
            (cond
             ((ordering key node-key)
              (call-with-values
                  (lambda ()
                    (node-delete (avl-node-left node) key ordering))
                (lambda (left delta)
                  (if (= delta 0)
                      (values node 0)
                      (values
                       (rebalance
                        (node-with-children
                         node-key
                         (avl-node-value node)
                         left
                         (avl-node-right node)))
                       delta)))))
             ((ordering node-key key)
              (call-with-values
                  (lambda ()
                    (node-delete (avl-node-right node) key ordering))
                (lambda (right delta)
                  (if (= delta 0)
                      (values node 0)
                      (values
                       (rebalance
                        (node-with-children
                         node-key
                         (avl-node-value node)
                         (avl-node-left node)
                         right))
                       delta)))))
             ((not (avl-node-left node))
              (values (avl-node-right node) -1))
             ((not (avl-node-right node))
              (values (avl-node-left node) -1))
             (else
              (call-with-values
                  (lambda ()
                    (node-remove-minimum (avl-node-right node)))
                (lambda (right successor-key successor-value)
                  (values
                   (rebalance
                    (node-with-children
                     successor-key
                     successor-value
                     (avl-node-left node)
                     right))
                   -1))))))))

    (define (avl-tree-delete tree key)
      "Return TREE without KEY."
      #((parameters
         (tree (type avl-tree) (description "Tree to update."))
         (key (type any) (description "Key to remove.")))
        (returns (type avl-tree)
         (description "Persistently updated or unchanged tree."))
        (effects allocation error procedure-call))
      (ensure-avl-tree tree 'avl-tree-delete)
      (call-with-values
          (lambda ()
            (node-delete (avl-tree-root tree)
                         key
                         (avl-tree-ordering tree)))
        (lambda (root delta)
          (if (= delta 0)
              tree
              (make-avl-tree-record
               (avl-tree-ordering tree)
               root
               (+ (avl-tree-size tree) delta))))))

    (define (find-node tree key)
      "Return TREE's node for KEY, or #f when absent."
      (ensure-avl-tree tree 'avl-tree-ref)
      (let ((ordering (avl-tree-ordering tree)))
        (let loop ((node (avl-tree-root tree)))
          (if (not node)
              #f
              (let ((node-key (avl-node-key node)))
                (cond
                 ((ordering key node-key)
                  (loop (avl-node-left node)))
                 ((ordering node-key key)
                  (loop (avl-node-right node)))
                 (else node)))))))

    (define (avl-tree-ref/key tree key failure success)
      "Return the stored key and value through SUCCESS, or invoke FAILURE."
      #((parameters
         (tree (type avl-tree) (description "Tree to search."))
         (key (type any) (description "Key to locate."))
         (failure (type procedure) (description "Absent-key thunk."))
         (success (type procedure) (description "Key/value receiver.")))
        (returns (type any) (description "Handler result."))
        (effects error procedure-call))
      (let ((node (find-node tree key)))
        (if node
            (success (avl-node-key node) (avl-node-value node))
            (failure))))

    (define (avl-tree-contains? tree key)
      "Return #t when TREE contains KEY."
      #((parameters
         (tree (type avl-tree) (description "Tree to search."))
         (key (type any) (description "Key to locate.")))
        (returns (type boolean)
         (description "Whether KEY is present."))
        (effects error procedure-call))
      (if (find-node tree key) #t #f))

    (define (avl-tree-ref tree key . handlers)
      "Return KEY's value in TREE using optional failure and success handlers."
      #((parameters
         (tree (type avl-tree) (description "Tree to search."))
         (key (type any) (description "Key to locate."))
         (handlers (type list)
          (description "Optional failure thunk and success procedure.")))
        (returns (type any) (description "Stored or handled value."))
        (effects error procedure-call))
      (let ((failure
             (if (null? handlers)
                 (lambda () (error "avl-tree-ref: key not found" key))
                 (car handlers)))
            (success
             (if (or (null? handlers) (null? (cdr handlers)))
                 (lambda (value) value)
                 (cadr handlers))))
        (if (> (length handlers) 2)
            (error "avl-tree-ref: too many handlers" handlers))
        (if (not (procedure? failure))
            (error "avl-tree-ref: expected failure procedure" failure))
        (if (not (procedure? success))
            (error "avl-tree-ref: expected success procedure" success))
        (let ((node (find-node tree key)))
          (if node
              (success (avl-node-value node))
              (failure)))))

    (define (avl-tree-ref/default tree key default)
      "Return KEY's value in TREE, or DEFAULT when absent."
      #((parameters
         (tree (type avl-tree) (description "Tree to search."))
         (key (type any) (description "Key to locate."))
         (default (type any) (description "Value returned when absent.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects error procedure-call))
      (avl-tree-ref tree key (lambda () default)))

    (define (avl-tree-fold procedure seed tree)
      "Fold PROCEDURE over TREE from the least key to the greatest."
      #((parameters
         (procedure (type procedure)
          (description "Procedure accepting key, value, and accumulator."))
         (seed (type any) (description "Initial accumulator."))
         (tree (type avl-tree) (description "Tree to traverse.")))
        (returns (type any) (description "Final accumulator."))
        (effects error procedure-call))
      (ensure-avl-tree tree 'avl-tree-fold)
      (let walk ((node (avl-tree-root tree)) (result seed))
        (if (not node)
            result
            (let ((after-left (walk (avl-node-left node) result)))
              (walk (avl-node-right node)
                    (procedure (avl-node-key node)
                               (avl-node-value node)
                               after-left))))))

    (define (avl-tree-fold/reverse procedure seed tree)
      "Fold PROCEDURE over TREE from the greatest key to the least."
      #((parameters
         (procedure (type procedure)
          (description "Procedure accepting key, value, and accumulator."))
         (seed (type any) (description "Initial accumulator."))
         (tree (type avl-tree) (description "Tree to traverse.")))
        (returns (type any) (description "Final accumulator."))
        (effects error procedure-call))
      (ensure-avl-tree tree 'avl-tree-fold/reverse)
      (let walk ((node (avl-tree-root tree)) (result seed))
        (if (not node)
            result
            (let ((after-right (walk (avl-node-right node) result)))
              (walk (avl-node-left node)
                    (procedure (avl-node-key node)
                               (avl-node-value node)
                               after-right))))))

    (define (avl-tree-for-each procedure tree)
      "Call PROCEDURE for every association in TREE in ascending order."
      #((parameters
         (procedure (type procedure)
          (description "Procedure accepting a key and value."))
         (tree (type avl-tree) (description "Tree to traverse.")))
        (returns (type any) (description "Unspecified value."))
        (effects error procedure-call))
      (if (not (procedure? procedure))
          (error "avl-tree-for-each: expected procedure" procedure))
      (avl-tree-fold
       (lambda (key value ignored)
         (procedure key value))
       #f
       tree)
      (values))

    (define (optional-failure arguments who key)
      "Return an optional failure thunk for ARGUMENTS, WHO, and KEY."
      (if (> (length arguments) 1)
          (error "too many failure procedures" who arguments))
      (let ((failure
             (if (null? arguments)
                 (lambda () (error "AVL tree has no matching entry" who key))
                 (car arguments))))
        (if (not (procedure? failure))
            (error "expected failure procedure" who failure))
        failure))

    (define (minimum-node node)
      "Return NODE's minimum node, or #f when NODE is empty."
      (if (and node (avl-node-left node))
          (minimum-node (avl-node-left node))
          node))

    (define (maximum-node node)
      "Return NODE's maximum node, or #f when NODE is empty."
      (if (and node (avl-node-right node))
          (maximum-node (avl-node-right node))
          node))

    (define (node-values-or-failure node failure)
      "Return NODE's key and value, or invoke FAILURE."
      (if node
          (values (avl-node-key node) (avl-node-value node))
          (failure)))

    (define (avl-tree-min tree . maybe-failure)
      "Return TREE's minimum key and value as two values."
      #((parameters
         (tree (type avl-tree) (description "Tree to inspect."))
         (maybe-failure (type list)
          (description "Optional failure thunk for an empty tree.")))
        (returns (type any) (description "Minimum key and value."))
        (effects error procedure-call))
      (ensure-avl-tree tree 'avl-tree-min)
      (node-values-or-failure
       (minimum-node (avl-tree-root tree))
       (optional-failure maybe-failure 'avl-tree-min #f)))

    (define (avl-tree-max tree . maybe-failure)
      "Return TREE's maximum key and value as two values."
      #((parameters
         (tree (type avl-tree) (description "Tree to inspect."))
         (maybe-failure (type list)
          (description "Optional failure thunk for an empty tree.")))
        (returns (type any) (description "Maximum key and value."))
        (effects error procedure-call))
      (ensure-avl-tree tree 'avl-tree-max)
      (node-values-or-failure
       (maximum-node (avl-tree-root tree))
       (optional-failure maybe-failure 'avl-tree-max #f)))

    (define (predecessor-node tree key)
      "Return TREE's greatest node below KEY, or #f."
      (let ((ordering (avl-tree-ordering tree)))
        (let loop ((node (avl-tree-root tree)) (candidate #f))
          (if (not node)
              candidate
              (let ((node-key (avl-node-key node)))
                (cond
                 ((ordering node-key key)
                  (loop (avl-node-right node) node))
                 ((ordering key node-key)
                  (loop (avl-node-left node) candidate))
                 (else
                  (or (maximum-node (avl-node-left node)) candidate))))))))

    (define (successor-node tree key)
      "Return TREE's least node above KEY, or #f."
      (let ((ordering (avl-tree-ordering tree)))
        (let loop ((node (avl-tree-root tree)) (candidate #f))
          (if (not node)
              candidate
              (let ((node-key (avl-node-key node)))
                (cond
                 ((ordering key node-key)
                  (loop (avl-node-left node) node))
                 ((ordering node-key key)
                  (loop (avl-node-right node) candidate))
                 (else
                  (or (minimum-node (avl-node-right node)) candidate))))))))

    (define (avl-tree-key-predecessor tree key . maybe-failure)
      "Return the predecessor of KEY in TREE as key and value."
      #((parameters
         (tree (type avl-tree) (description "Tree to search."))
         (key (type any) (description "Exclusive upper boundary."))
         (maybe-failure (type list)
          (description "Optional failure thunk.")))
        (returns (type any) (description "Predecessor key and value."))
        (effects error procedure-call))
      (ensure-avl-tree tree 'avl-tree-key-predecessor)
      (node-values-or-failure
       (predecessor-node tree key)
       (optional-failure
        maybe-failure
        'avl-tree-key-predecessor
        key)))

    (define (avl-tree-key-successor tree key . maybe-failure)
      "Return the successor of KEY in TREE as key and value."
      #((parameters
         (tree (type avl-tree) (description "Tree to search."))
         (key (type any) (description "Exclusive lower boundary."))
         (maybe-failure (type list)
          (description "Optional failure thunk.")))
        (returns (type any) (description "Successor key and value."))
        (effects error procedure-call))
      (ensure-avl-tree tree 'avl-tree-key-successor)
      (node-values-or-failure
       (successor-node tree key)
       (optional-failure maybe-failure 'avl-tree-key-successor key)))

    (define (empty-like tree)
      "Return an empty AVL tree using TREE's ordering procedure."
      (make-avl-tree (avl-tree-ordering tree)))

    (define (avl-tree-split tree boundary)
      "Split TREE around BOUNDARY and return five range trees."
      #((parameters
         (tree (type avl-tree) (description "Tree to split."))
         (boundary (type any) (description "Boundary key.")))
        (returns (type any)
         (description "Five trees for <, <=, =, >=, and > ranges."))
        (effects allocation error procedure-call))
      (ensure-avl-tree tree 'avl-tree-split)
      (let* ((ordering (avl-tree-ordering tree))
             (empty (empty-like tree))
             (ranges
              (avl-tree-fold
               (lambda (key value ranges)
                 (let ((less (list-ref ranges 0))
                       (less-or-equal (list-ref ranges 1))
                       (equal (list-ref ranges 2))
                       (greater-or-equal (list-ref ranges 3))
                       (greater (list-ref ranges 4)))
                   (cond
                    ((ordering key boundary)
                     (list (avl-tree-set less key value)
                           (avl-tree-set less-or-equal key value)
                           equal
                           greater-or-equal
                           greater))
                    ((ordering boundary key)
                     (list less
                           less-or-equal
                           equal
                           (avl-tree-set greater-or-equal key value)
                           (avl-tree-set greater key value)))
                    (else
                     (list less
                           (avl-tree-set less-or-equal key value)
                           (avl-tree-set equal key value)
                           (avl-tree-set greater-or-equal key value)
                           greater)))))
               (list empty empty empty empty empty)
               tree)))
        (values (list-ref ranges 0)
                (list-ref ranges 1)
                (list-ref ranges 2)
                (list-ref ranges 3)
                (list-ref ranges 4))))

    (define (avl-tree-catenate left key value right)
      "Return LEFT, KEY/VALUE, and RIGHT as one ordered AVL tree."
      #((parameters
         (left (type avl-tree) (description "Lower-key tree."))
         (key (type any) (description "Pivot key."))
         (value (type any) (description "Pivot value."))
         (right (type avl-tree) (description "Higher-key tree.")))
        (returns (type avl-tree) (description "Combined tree."))
        (effects allocation error procedure-call))
      (ensure-avl-tree left 'avl-tree-catenate)
      (ensure-avl-tree right 'avl-tree-catenate)
      (avl-tree-fold
       (lambda (right-key right-value result)
         (avl-tree-set result right-key right-value))
       (avl-tree-set left key value)
       right))

    (define (avl-tree-map/monotone procedure tree)
      "Return an AVL tree from monotone PROCEDURE over TREE."
      #((parameters
         (procedure (type procedure)
          (description "Procedure returning a new key and value."))
         (tree (type avl-tree) (description "Tree to transform.")))
        (returns (type avl-tree) (description "Transformed tree."))
        (effects allocation error procedure-call))
      (if (not (procedure? procedure))
          (error "avl-tree-map/monotone: expected procedure" procedure))
      (avl-tree-fold
       (lambda (key value result)
         (call-with-values
             (lambda () (procedure key value))
           (lambda (new-key new-value)
             (avl-tree-set result new-key new-value))))
       (empty-like tree)
       tree))

    (define (avl-tree->alist tree)
      "Return TREE's associations as an ascending alist."
      #((parameters
         (tree (type avl-tree) (description "Tree to convert.")))
        (returns (type list) (description "Ascending associations."))
        (effects allocation error procedure-call))
      (avl-tree-fold/reverse
       (lambda (key value result) (cons (cons key value) result))
       '()
       tree))

    (define (alist->avl-tree ordering alist)
      "Return an AVL tree ordered by ORDERING and populated from ALIST."
      #((parameters
         (ordering (type procedure)
          (description "Strict ordering predicate for keys."))
         (alist (type list) (description "Associations to insert.")))
        (returns (type avl-tree) (description "Populated tree."))
        (effects allocation error procedure-call))
      (if (not (list? alist))
          (error "alist->avl-tree: expected list" alist))
      (let loop ((tree (make-avl-tree ordering)) (rest alist))
        (if (null? rest)
            tree
            (loop (avl-tree-set tree (caar rest) (cdar rest))
                  (cdr rest)))))

    (define (node-valid? node ordering)
      "Return NODE's validity, height, count, extrema, and presence flag."
      (if (not node)
          (values #t 0 0 #f #f #f)
          (call-with-values
           (lambda ()
             (node-valid? (avl-node-left node) ordering))
           (lambda (left-valid? left-height left-count left-min left-max
                                left-present?)
             (call-with-values
              (lambda ()
                (node-valid? (avl-node-right node) ordering))
              (lambda (right-valid? right-height right-count right-min
                                    right-max right-present?)
                (let* ((key (avl-node-key node))
                       (height (+ 1 (max left-height right-height)))
                       (valid?
                        (and
                         left-valid?
                         right-valid?
                         (or (not left-present?) (ordering left-max key))
                         (or (not right-present?) (ordering key right-min))
                         (= (avl-node-height-value node) height)
                         (<= (abs (- left-height right-height)) 1))))
                  (values valid?
                          height
                          (+ 1 left-count right-count)
                          (if left-present? left-min key)
                          (if right-present? right-max key)
                          #t))))))))

    (define (avl-tree-valid? tree)
      "Return #t when TREE satisfies its ordering and AVL invariants."
      #((parameters
         (tree (type any) (description "Candidate tree to validate.")))
        (returns (type boolean)
         (description "Whether TREE satisfies every AVL invariant."))
        (effects procedure-call))
      (and
       (avl-tree? tree)
       (call-with-values
        (lambda ()
          (node-valid? (avl-tree-root tree)
                       (avl-tree-ordering tree)))
        (lambda (valid? height count minimum maximum present?)
          (and valid? (= count (avl-tree-size tree)))))))))
