;;; Portable SRFI 146 ordered mapping stdlib smoke tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Compact all-host checks for `(stdlib mapping)'. The broader
;;; upstream-derived
;;; conformance suite lives in `stdlib-mapping-conformance-test.scm' and runs
;;; on
;;; direct R7RS hosts; this file stays small enough for compiled host runners.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib mapping)
        (data mapping avl)
        (only (stdlib mapping implementation)
              mapping-provider=?
              mapping-storage-provider
              red-black-mapping-provider)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (mapping-values-list mappings)
  "Return the value lists for every mapping in MAPPINGS."
  (map mapping-values mappings))

(define (model-set-entry model key value)
  "Return sorted alist MODEL with KEY associated to VALUE."
  (cond
   ((null? model)
    (list (cons key value)))
   ((= key (caar model))
    (cons (cons key value) (cdr model)))
   ((< key (caar model))
    (cons (cons key value) model))
   (else
    (cons (car model) (model-set-entry (cdr model) key value)))))

(define (model-set-pairs model pairs)
  "Return sorted alist MODEL after setting every association in PAIRS."
  (if (null? pairs)
      model
      (model-set-pairs
       (model-set-entry model (caar pairs) (cdar pairs))
       (cdr pairs))))

(define (model-adjoin-entry model key value)
  "Return sorted alist MODEL with missing KEY associated to VALUE."
  (cond
   ((null? model)
    (list (cons key value)))
   ((= key (caar model))
    model)
   ((< key (caar model))
    (cons (cons key value) model))
   (else
    (cons (car model) (model-adjoin-entry (cdr model) key value)))))

(define (model-adjoin-pairs model pairs)
  "Return sorted alist MODEL after adjoining every association in PAIRS."
  (if (null? pairs)
      model
      (model-adjoin-pairs
       (model-adjoin-entry model (caar pairs) (cdar pairs))
       (cdr pairs))))

(define (model-delete-key model key)
  "Return sorted alist MODEL without KEY."
  (cond
   ((null? model) '())
   ((= key (caar model)) (cdr model))
   (else (cons (car model) (model-delete-key (cdr model) key)))))

(define (model-delete-keys model keys)
  "Return sorted alist MODEL without every key in KEYS."
  (if (null? keys)
      model
      (model-delete-keys (model-delete-key model (car keys)) (cdr keys))))

(define (model-contains-key? model key)
  "Return #t when sorted alist MODEL contains KEY."
  (cond
   ((null? model) #f)
   ((= key (caar model)) #t)
   ((< key (caar model)) #f)
   (else (model-contains-key? (cdr model) key))))

(define (model-union model1 model2)
  "Return sorted alist union of MODEL1 and MODEL2, preferring MODEL1 values."
  (if (null? model2)
      model1
      (model-union
       (model-adjoin-entry model1 (caar model2) (cdar model2))
       (cdr model2))))

(define (model-intersection model1 model2)
  "Return sorted alist entries from MODEL1 whose keys occur in MODEL2."
  (cond
   ((null? model1) '())
   ((model-contains-key? model2 (caar model1))
    (cons (car model1) (model-intersection (cdr model1) model2)))
   (else
    (model-intersection (cdr model1) model2))))

(define (model-difference model1 model2)
  "Return sorted alist entries from MODEL1 whose keys do not occur in MODEL2."
  (cond
   ((null? model1) '())
   ((model-contains-key? model2 (caar model1))
    (model-difference (cdr model1) model2))
   (else
    (cons (car model1) (model-difference (cdr model1) model2)))))

(define (model-range>= model boundary)
  "Return sorted alist entries from MODEL whose keys are at or above BOUNDARY.\
"
  (cond
   ((null? model) '())
   ((>= (caar model) boundary) model)
   (else (model-range>= (cdr model) boundary))))

;; Comparator used for integer-keyed fixtures and numeric value comparisons.
(define integer-comparator
  (make-comparator integer? = < number-hash))

;; Comparator used for symbolic-key fixtures.
(define default-comparator
  (make-default-comparator))

(define (red-black-backed? mapping)
  "Return #t when MAPPING retains the standard red-black provider."
  (mapping-provider=? (mapping-storage-provider mapping)
                      red-black-mapping-provider))

(define (same-provider? left right)
  "Return #t when LEFT and RIGHT use the same Mapping provider."
  (mapping-provider=? (mapping-storage-provider left)
                      (mapping-storage-provider right)))

;; Empty symbolic-key mapping fixture.
(define empty-symbols
  (mapping default-comparator))

;; Ordered symbolic-key mapping fixture built from shuffled constructor input.
(define symbols
  (mapping default-comparator 'b 2 'a 1 'c 3))

;; AVL-backed peer of SYMBOLS for provider-neutral behavior checks.
(define avl-symbols
  (avl-mapping default-comparator 'b 2 'a 1 'c 3))

(testing-registry-case
 'predicate-mapping '(portable stdlib)
(test-assert 'predicate-mapping (mapping? symbols)))
(testing-registry-case
 'predicate-empty '(portable stdlib)
(test-assert 'predicate-empty (mapping-empty? empty-symbols)))
(testing-registry-case
 'predicate-non-empty '(portable stdlib)
(test-assert 'predicate-non-empty (not (mapping-empty? symbols))))
(testing-registry-case
 'constructor-orders-keys '(portable stdlib)
(test-equal 'constructor-orders-keys
             '((a . 1) (b . 2) (c . 3))
             (mapping->alist symbols)))
(testing-registry-case
 'avl-constructor-is-standard-mapping '(portable data stdlib)
(test-assert 'avl-constructor-is-standard-mapping
             (and (mapping? avl-symbols)
                  (not (red-black-backed? avl-symbols))
                  (same-provider? avl-symbols
                                  (mapping-set avl-symbols 'd 4))
                  (equal? '((a . 1) (b . 2) (c . 3))
                          (mapping->alist avl-symbols)))))
(testing-registry-case
 'mapping-ref '(portable stdlib)
(test-equal 'mapping-ref 2 (mapping-ref symbols 'b)))
(testing-registry-case
 'mapping-ref/default-missing '(portable stdlib)
(test-equal 'mapping-ref/default-missing
             42
             (mapping-ref/default symbols 'missing 42)))

;; Mapping fixture that exercises repeated keys in `mapping-set'.
(define set-duplicates
  (mapping-set symbols 'b 20 'b 21 'd 4))

;; Mapping fixture that exercises repeated keys in `mapping-adjoin'.
(define adjoin-duplicates
  (mapping-adjoin symbols 'b 20 'd 4 'd 5))

(testing-registry-case
 'mapping-set-last-duplicate-wins '(portable stdlib)
(test-equal 'mapping-set-last-duplicate-wins
             '((a . 1) (b . 21) (c . 3) (d . 4))
             (mapping->alist set-duplicates)))
(testing-registry-case
 'mapping-adjoin-keeps-existing-and-first-new '(portable stdlib)
(test-equal 'mapping-adjoin-keeps-existing-and-first-new
             '((a . 1) (b . 2) (c . 3) (d . 4))
             (mapping->alist adjoin-duplicates)))

;; Integer-keyed mapping fixture used for set and range operations.
(define numbers
  (mapping integer-comparator
           3 'three
           1 'one
           4 'four
           2 'two))

(testing-registry-case
 'mapping-union-prefers-left '(portable stdlib)
(test-equal 'mapping-union-prefers-left
             '((1 . one) (2 . two) (3 . three) (4 . four) (5 . five))
             (mapping->alist
        (mapping-union numbers (mapping integer-comparator 2 'dos 5 'five)))))
(testing-registry-case
 'mapping-intersection-keeps-common-left-values '(portable stdlib)
(test-equal 'mapping-intersection-keeps-common-left-values
             '((2 . two) (4 . four))
             (mapping->alist
        (mapping-intersection
         numbers
         (mapping integer-comparator 2 'dos 4 'cuatro 6 'six)))))
(testing-registry-case
 'mapping-difference-removes-common '(portable stdlib)
(test-equal 'mapping-difference-removes-common
             '((1 . one) (3 . three) (4 . four))
             (mapping->alist
        (mapping-difference numbers (mapping integer-comparator 2 'dos)))))
(testing-registry-case
 'mapping-range>= '(portable stdlib)
(test-equal 'mapping-range>=
             '((3 . three) (4 . four))
             (mapping->alist (mapping-range>= numbers 3))))

(testing-registry-case
 'mapping-split '(portable stdlib)
(test-equal 'mapping-split
             '((one two) (one two three) (three) (three four) (four))
             (call-with-values
        (lambda () (mapping-split numbers 3))
        (lambda mappings
          (mapping-values-list mappings)))))

;; Mapping produced by a finite unfold over ascending integer keys.
(define unfolded
  (mapping-unfold (lambda (seed) (> seed 3))
                  (lambda (seed) (values seed (* seed seed)))
                  (lambda (seed) (+ seed 1))
                  1
                  integer-comparator))

(testing-registry-case
 'mapping-unfold '(portable stdlib)
(test-equal 'mapping-unfold
             '((1 . 1) (2 . 4) (3 . 9))
             (mapping->alist unfolded)))

;; Proper subset mapping for ordered comparison checks.
(define subset-left
  (mapping integer-comparator 1 10 2 20))

;; Proper superset mapping for ordered comparison checks.
(define subset-right
  (mapping integer-comparator 1 10 2 20 3 30))

;; Mapping that overlaps but is not a subset of `overlap-right'.
(define overlap-left
  (mapping integer-comparator 1 10 2 20))

;; Mapping that overlaps but is not a superset of `overlap-left'.
(define overlap-right
  (mapping integer-comparator 2 20 3 30))

(testing-registry-case
 'mapping<=?-proper-subset '(portable stdlib)
(test-assert 'mapping<=?-proper-subset
             (mapping<=? integer-comparator subset-left subset-right)))
(testing-registry-case
 'mapping<?-proper-subset '(portable stdlib)
(test-assert 'mapping<?-proper-subset
             (mapping<? integer-comparator subset-left subset-right)))
(testing-registry-case
 'mapping>=?-proper-superset '(portable stdlib)
(test-assert 'mapping>=?-proper-superset
             (mapping>=? integer-comparator subset-right subset-left)))
(testing-registry-case
 'mapping>?-proper-superset '(portable stdlib)
(test-assert 'mapping>?-proper-superset
             (mapping>? integer-comparator subset-right subset-left)))
(testing-registry-case
 'mapping<?-overlap-not-subset '(portable stdlib)
(test-assert 'mapping<?-overlap-not-subset
             (not (mapping<? integer-comparator overlap-left overlap-right))))
(testing-registry-case
 'mapping>?-overlap-not-superset '(portable stdlib)
(test-assert 'mapping>?-overlap-not-superset
             (not (mapping>? integer-comparator overlap-left overlap-right))))
(testing-registry-case
 'mapping>=?-overlap-not-superset '(portable stdlib)
(test-assert 'mapping>=?-overlap-not-superset
             (not (mapping>=? integer-comparator overlap-left overlap-right))))

;; Model fixture for deterministic operation-sequence checks.
(define model-base
  '((1 . one) (2 . two) (3 . three)))

;; Mapping fixture corresponding to `model-base'.
(define mapping-base
  (alist->mapping integer-comparator model-base))

;; Expected model after a set operation with insertion, replacement, and front
;; insertion.
(define model-after-set
  (model-set-pairs model-base '((4 . four) (2 . TWO) (0 . zero))))

;; Mapping after the same set operation used for `model-after-set'.
(define mapping-after-set
  (mapping-set mapping-base 4 'four 2 'TWO 0 'zero))

;; Expected model after deleting present, absent, and front keys.
(define model-after-delete
  (model-delete-keys model-after-set '(3 99 0)))

;; Mapping after the same delete sequence used for `model-after-delete'.
(define mapping-after-delete
  (mapping-delete mapping-after-set 3 99 0))

;; Expected model after adjoining an existing key and duplicate new key.
(define model-after-adjoin
  (model-adjoin-pairs model-after-delete '((2 . dos) (5 . five) (5 . FIVE))))

;; Mapping after the same adjoin sequence used for `model-after-adjoin'.
(define mapping-after-adjoin
  (mapping-adjoin mapping-after-delete 2 'dos 5 'five 5 'FIVE))

;; Secondary model fixture for set-algebra oracle checks.
(define model-other
  '((2 . dos) (4 . cuatro) (6 . six)))

;; Secondary mapping fixture corresponding to `model-other'.
(define mapping-other
  (alist->mapping integer-comparator model-other))

(testing-registry-case
 'model-set-sequence '(portable stdlib)
(test-equal 'model-set-sequence
             model-after-set
             (mapping->alist mapping-after-set)))
(testing-registry-case
 'model-delete-sequence '(portable stdlib)
(test-equal 'model-delete-sequence
             model-after-delete
             (mapping->alist mapping-after-delete)))
(testing-registry-case
 'model-adjoin-sequence '(portable stdlib)
(test-equal 'model-adjoin-sequence
             model-after-adjoin
             (mapping->alist mapping-after-adjoin)))
(testing-registry-case
 'model-union-left-biased '(portable stdlib)
(test-equal 'model-union-left-biased
             (model-union model-after-adjoin model-other)
             (mapping->alist (mapping-union mapping-after-adjoin
               mapping-other))))
(testing-registry-case
 'model-intersection-left-values '(portable stdlib)
(test-equal 'model-intersection-left-values
             (model-intersection model-after-adjoin model-other)
             (mapping->alist (mapping-intersection mapping-after-adjoin
               mapping-other))))
(testing-registry-case
 'model-difference '(portable stdlib)
(test-equal 'model-difference
             (model-difference model-after-adjoin model-other)
             (mapping->alist (mapping-difference mapping-after-adjoin
               mapping-other))))
(testing-registry-case
 'model-range>= '(portable stdlib)
(test-equal 'model-range>=
             (model-range>= model-after-adjoin 4)
             (mapping->alist (mapping-range>= mapping-after-adjoin 4))))

(testing-registry-case
 'default-provider-preserved '(portable stdlib)
(let-values (((partition-in partition-out)
              (mapping-partition (lambda (key value) (< key 3)) numbers))
             ((split< split<= split= split>= split>)
              (mapping-split numbers 3)))
  (test-assert
   'default-provider-preserved
   (let loop
       ((mappings
         (list numbers
               (mapping-set numbers 5 'five)
               (mapping-delete numbers 1)
               (mapping-copy numbers)
               (mapping-filter (lambda (key value) (< key 4)) numbers)
               partition-in
               partition-out
               (mapping-range>= numbers 3)
               split<
               split<=
               split=
               split>=
               split>
               (mapping-catenate integer-comparator
                                  (mapping integer-comparator 1 'one)
                                  2
                                  'two
                                  (mapping integer-comparator 3 'three))
               (mapping-union numbers (mapping integer-comparator 5 'five))
               (mapping-map/monotone
                (lambda (key value) (values (+ key 10) value))
                integer-comparator
                numbers))))
     (or (null? mappings)
         (and (red-black-backed? (car mappings))
              (loop (cdr mappings))))))))

(testing-runner-main "Stdlib Mapping portable tests" (command-line))
