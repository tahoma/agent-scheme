;;; Portable transient-map tests with persistent AVL backing.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (data avl-tree)
        (data transient-map)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when THUNK raises a Scheme condition."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (integer-tree pairs)
  "Return an integer-keyed AVL tree containing PAIRS."
  (alist->avl-tree < pairs))

(define (avl-key-equivalent? ordering)
  "Return key equivalence derived from strict ORDERING."
  (lambda (left right)
    (and (not (ordering left right))
         (not (ordering right left)))))

(define (avl-transient tree hash . maybe-key-copy)
  "Return a transient map adapted to persistent AVL TREE."
  (apply make-transient-map
         tree
         hash
         (avl-key-equivalent? (avl-tree-ordering tree))
         avl-tree-ref
         avl-tree-set
         avl-tree-delete
         maybe-key-copy))

(define (alist-map-ref base key failure success)
  "Look up numeric KEY in persistent alist BASE."
  (let ((entry (assv key base)))
    (if entry (success (cdr entry)) (failure))))

(define (alist-map-set base key value)
  "Return persistent alist BASE with numeric KEY set to VALUE."
  (let loop ((rest base))
    (cond
     ((null? rest) (list (cons key value)))
     ((= key (caar rest)) (cons (cons key value) (cdr rest)))
     (else (cons (car rest) (loop (cdr rest)))))))

(define (alist-map-delete base key)
  "Return persistent alist BASE without numeric KEY."
  (let loop ((rest base))
    (cond
     ((null? rest) '())
     ((= key (caar rest)) (cdr rest))
     (else (cons (car rest) (loop (cdr rest)))))))

(define (alist-transient base hash)
  "Return a transient map adapted to persistent alist BASE."
  (make-transient-map base
                      hash
                      =
                      alist-map-ref
                      alist-map-set
                      alist-map-delete))

(define (map-matches-model? transient model limit)
  "Return whether TRANSIENT matches alist MODEL below LIMIT."
  (let loop ((key 0))
    (if (= key limit)
        #t
        (let ((entry (assv key model)))
          (and (eqv? (if entry (cdr entry) 'missing)
                     (transient-map-ref/default transient key 'missing))
               (eq? (if entry #t #f)
                    (transient-map-contains? transient key))
               (loop (+ key 1)))))))

(testing-registry-case
 'transient-map-construction-and-lookup '(portable data transient)
(let* ((root (integer-tree '((1 . one) (2 . two))))
       (transient (avl-transient root (lambda (value) value))))
  (test-assert 'transient-map-predicate (transient-map? transient))
  (test-equal 'transient-map-inherited-value
              'one
              (transient-map-ref transient 1))
  (test-assert 'transient-map-inherited-present
               (transient-map-contains? transient 2))
  (test-equal 'transient-map-missing-default
              'missing
              (transient-map-ref/default transient 3 'missing))
  (test-equal 'cached-lookups-are-not-pending
              0
              (transient-map-pending-count transient))))

(testing-registry-case
 'transient-map-stages-until-materialized '(portable data transient)
(let* ((root (integer-tree '((1 . one))))
       (transient (avl-transient root (lambda (value) value))))
  (transient-map-set! transient 2 'two)
  (transient-map-set! transient 1 'updated)
  (test-equal 'transient-map-staged-value
              'two
              (transient-map-ref transient 2))
  (test-assert 'persistent-root-remains-unchanged
               (not (avl-tree-contains? root 2)))
  (test-equal 'transient-map-pending-updates
              2
              (transient-map-pending-count transient))
  (let ((persistent (transient-map-persistent! transient)))
    (test-equal 'materialized-associations
                '((1 . updated) (2 . two))
                (avl-tree->alist persistent))
    (test-equal 'materialization-clears-pending
                0
                (transient-map-pending-count transient))
    (test-assert 'materialization-is-idempotent
                 (eq? persistent
                      (transient-map-persistent! transient))))))

(testing-registry-case
 'transient-map-delete-and-reset '(portable data transient)
(let* ((root (integer-tree '((1 . one) (2 . two))))
       (replacement (integer-tree '((9 . nine))))
       (transient (avl-transient root (lambda (value) value))))
  (transient-map-delete! transient 1)
  (test-assert 'staged-delete-hides-base
               (not (transient-map-contains? transient 1)))
  (test-equal 'materialized-delete
              '((2 . two))
              (avl-tree->alist (transient-map-persistent! transient)))
  (transient-map-set! transient 3 'three)
  (transient-map-reset! transient replacement)
  (test-equal 'reset-replaces-base-and-overlay
              '((9 . nine))
              (avl-tree->alist (transient-map-persistent! transient)))))

(testing-registry-case
 'transient-map-resizes-and-handles-collisions '(portable data transient)
(let ((transient
       (avl-transient (make-avl-tree <) (lambda (key) key))))
  ;; Zero and 127 collide in the initial table; the remaining entries force a
  ;; resize without turning the self-hosted test itself into a quadratic load.
  (transient-map-set! transient 0 0)
  (transient-map-set! transient 127 (* 127 127))
  (let loop ((key 1))
    (if (< key 200)
        (begin
          (if (not (= key 127))
              (transient-map-set! transient key (* key key)))
          (loop (+ key 1)))))
  (test-equal 'transient-map-resized-value
              (* 199 199)
              (transient-map-ref transient 199))
  (test-equal 'transient-map-resized-size
              200
              (avl-tree-size (transient-map-persistent! transient)))))

(testing-registry-case
 'transient-map-collision-state-transitions '(portable data transient)
(let* ((root '((1 . one) (2 . #f) (3 . three)))
       (transient (alist-transient root (lambda (key) 0))))
  (transient-map-delete! transient 1)
  (transient-map-set! transient 2 'two)
  (transient-map-delete! transient 2)
  (transient-map-set! transient 2 #f)
  (transient-map-delete! transient 4)
  (transient-map-set! transient 4 'four)
  (test-equal 'one-pending-entry-per-key
              3
              (transient-map-pending-count transient))
  (test-assert 'deleted-collision-does-not-hide-later-key
               (transient-map-contains? transient 3))
  (test-assert 'stored-false-remains-present
               (and (transient-map-contains? transient 2)
                    (not (transient-map-ref transient 2))))
  (let ((persistent (transient-map-persistent! transient)))
    (test-equal 'collision-transitions-materialize
                'missing
                (alist-map-ref persistent 1 (lambda () 'missing) values))
    (test-equal 'collision-set-materializes
                'four
                (alist-map-ref persistent 4 (lambda () 'missing) values)))))

(testing-registry-case
 'transient-map-generic-adapter-model-stress '(portable data transient stress)
(let ((transient
       (alist-transient '((120 . base))
                        (lambda (key) (modulo key 17))))
      (model '((120 . base))))
  (let loop ((key 0))
    (if (< key 90)
        (begin
          (transient-map-set! transient key (* key key))
          (set! model (alist-map-set model key (* key key)))
          (loop (+ key 1)))))
  (let loop ((key 0))
    (if (< key 120)
        (begin
          (if (= (modulo key 3) 0)
              (begin
                (transient-map-delete! transient key)
                (set! model (alist-map-delete model key)))
              (if (>= key 45)
                  (begin
                    (transient-map-set! transient key (- key))
                    (set! model (alist-map-set model key (- key))))))
          (loop (+ key 1)))))
  (test-assert 'generic-view-matches-model-before-materialization
               (map-matches-model? transient model 121))
  (test-equal 'generic-distinct-pending-keys
              120
              (transient-map-pending-count transient))
  (let ((persistent (transient-map-persistent! transient)))
    (test-assert 'generic-view-matches-model-after-materialization
                 (map-matches-model? transient model 121))
    (test-equal 'generic-materialized-count
                (length model)
                (length persistent)))))

(testing-registry-case
 'transient-map-key-copy-stabilizes-cache '(portable data transient)
(let* ((root (make-avl-tree string<?))
       (name (string-copy "stable"))
       (transient (avl-transient root string-length string-copy)))
  (transient-map-set! transient name 'value)
  (string-set! name 0 #\f)
  (test-equal 'transient-map-copied-key
              'value
              (transient-map-ref transient "stable"))))

(testing-registry-case
 'transient-map-handlers-and-contracts '(portable data transient)
(let ((transient (alist-transient '((1 . one)) (lambda (key) key))))
  (test-equal 'transient-map-failure-handler
              'missing
              (transient-map-ref transient 2 (lambda () 'missing)))
  (test-equal 'transient-map-success-handler
              '(found one)
              (transient-map-ref transient
                                 1
                                 (lambda () 'missing)
                                 (lambda (value) (list 'found value))))
  (test-assert 'transient-map-default-missing-raises
               (raises? (lambda () (transient-map-ref transient 2))))
  (test-assert 'transient-map-rejects-extra-handlers
               (raises?
                (lambda ()
                  (transient-map-ref transient 1 values values values))))
  (test-assert 'transient-map-rejects-inexact-hash
               (raises?
                (lambda ()
                  (transient-map-ref
                   (alist-transient '() (lambda (key) 1.5))
                   1))))
  (test-assert 'transient-map-rejects-bad-adapter
               (raises?
                (lambda ()
                  (make-transient-map '() values = 42 values values))))))

(testing-runner-main "Transient maps" (command-line))
