;;; AVL-backed constructors for SRFI 146 ordered mappings.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (data mapping avl)
  (export avl-mapping
          avl-mapping-unfold
          alist->avl-mapping)
  (import (scheme base)
          (stdlib comparator)
          (only (stdlib mapping implementation)
                alist->mapping-with-provider
                make-ordered-mapping-provider
                mapping-unfold-with-provider
                mapping-with-provider)
          (only (data avl-tree)
                make-avl-tree
                avl-tree-ref/key
                avl-tree-set
                avl-tree-delete
                avl-tree-for-each
                avl-tree-fold
                avl-tree-fold/reverse
                avl-tree-key-predecessor
                avl-tree-key-successor
                avl-tree-split))
  (begin
    (define (avl-empty comparator)
      "Return an empty AVL root for COMPARATOR."
      (make-avl-tree (comparator-ordering-predicate comparator)))

    (define (avl-search comparator root key failure success)
      "Search ROOT for KEY using Mapping continuation protocol."
      (avl-tree-ref/key
       root
       key
       (lambda ()
         (failure
          (lambda (new-key new-value result)
            (values (avl-tree-set root new-key new-value) result))
          (lambda (result) (values root result))))
       (lambda (stored-key stored-value)
         (success
          stored-key
          stored-value
          (lambda (new-key new-value result)
            (values
             (avl-tree-set (avl-tree-delete root stored-key)
                           new-key
                           new-value)
             result))
          (lambda (result)
            (values (avl-tree-delete root stored-key) result))))))

    (define (avl-generator root)
      "Return a generator of key/value lists from ROOT."
      (let ((remaining
             (avl-tree-fold/reverse
              (lambda (key value items)
                (cons (list key value) items))
              '()
              root)))
        (lambda ()
          (if (null? remaining)
              (eof-object)
              (let ((item (car remaining)))
                (set! remaining (cdr remaining))
                item)))))

    (define (avl-predecessor comparator root key failure)
      "Return ROOT's predecessor key, or invoke FAILURE."
      (call/cc
       (lambda (return)
         (call-with-values
          (lambda ()
            (avl-tree-key-predecessor
             root key (lambda () (return (failure)))))
          (lambda (stored-key stored-value) stored-key)))))

    (define (avl-successor comparator root key failure)
      "Return ROOT's successor key, or invoke FAILURE."
      (call/cc
       (lambda (return)
         (call-with-values
          (lambda ()
            (avl-tree-key-successor
             root key (lambda () (return (failure)))))
          (lambda (stored-key stored-value) stored-key)))))

    (define (avl-catenate comparator left key value right)
      "Return an AVL root containing LEFT, KEY/VALUE, and RIGHT."
      (let ((combined
             (avl-tree-fold
              (lambda (stored-key stored-value result)
                (avl-tree-set result stored-key stored-value))
              (avl-empty comparator)
              left)))
        (avl-tree-fold
         (lambda (stored-key stored-value result)
           (avl-tree-set result stored-key stored-value))
         (avl-tree-set combined key value)
         right)))

    (define (avl-map/monotone procedure comparator root)
      "Return an AVL root mapped by PROCEDURE and ordered by COMPARATOR."
      (avl-tree-fold
       (lambda (key value result)
         (let-values (((new-key new-value) (procedure key value)))
           (avl-tree-set result new-key new-value)))
       (avl-empty comparator)
       root))

    ;; Ordered Mapping provider backed by persistent AVL trees.
    (define avl-mapping-provider
      (make-ordered-mapping-provider
       'avl
       avl-empty
       avl-search
       avl-tree-for-each
       avl-tree-fold
       avl-tree-fold/reverse
       avl-generator
       avl-predecessor
       avl-successor
       (lambda (comparator root key)
         (avl-tree-split root key))
       avl-catenate
       avl-map/monotone))

    (define (avl-mapping comparator . arguments)
      "Return an AVL-backed Mapping initialized from ARGUMENTS."
      #((parameters
         (comparator (type comparator)
          (description "Comparator controlling the mapping keys."))
         (arguments (type list)
          (description "Alternating keys and values.")))
        (returns (type mapping)
         (description "AVL-backed ordered mapping."))
        (effects allocation error procedure-call))
      (apply mapping-with-provider
             avl-mapping-provider
             comparator
             arguments))

    (define (avl-mapping-unfold stop? mapper successor seed comparator)
      "Return an AVL-backed Mapping unfolded from SEED."
      #((parameters
         (stop? (type procedure) (description "Termination predicate."))
         (mapper (type procedure) (description "Key/value producer."))
         (successor (type procedure) (description "Seed successor."))
         (seed (type any) (description "Initial seed."))
         (comparator (type comparator)
          (description "Comparator controlling the mapping keys.")))
        (returns (type mapping)
         (description "AVL-backed ordered mapping."))
        (effects allocation error procedure-call))
      (mapping-unfold-with-provider avl-mapping-provider
                                    stop?
                                    mapper
                                    successor
                                    seed
                                    comparator))

    (define (alist->avl-mapping comparator alist)
      "Return an AVL-backed Mapping containing ALIST associations."
      #((parameters
         (comparator (type comparator)
          (description "Comparator controlling the mapping keys."))
         (alist (type list) (description "Associations to insert.")))
        (returns (type mapping)
         (description "AVL-backed ordered mapping."))
        (effects allocation error procedure-call))
      (alist->mapping-with-provider avl-mapping-provider comparator alist))))
