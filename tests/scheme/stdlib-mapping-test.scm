;;; Portable SRFI 146 ordered mapping stdlib smoke tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Compact all-host checks for `(stdlib mapping)'. The broader upstream-derived
;;; conformance suite lives in `stdlib-mapping-conformance-test.scm' and runs on
;;; direct R7RS hosts; this file stays small enough for compiled host runners.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib mapping))

;; Number of failed ordered mapping smoke checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed ordered mapping smoke check."
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

(define (check-true name value)
  "Record NAME unless VALUE is true."
  (check name (if value #t #f) #t))

(define (check-false name value)
  "Record NAME unless VALUE is false."
  (check name (if value #t #f) #f))

(define (mapping-values-list mappings)
  "Return the value lists for every mapping in MAPPINGS."
  (map mapping-values mappings))

(define (finish-mapping-smoke-tests)
  "Report the ordered mapping smoke test result."
  (if (= failures 0)
      (begin
        (display "Ordered mapping smoke tests passed")
        (newline))
      (begin
        (display failures)
        (display " ordered mapping smoke test failure(s)")
        (newline)
        (error "ordered mapping smoke tests failed" failures))))

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
  "Return sorted alist entries from MODEL whose keys are at or above BOUNDARY."
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

;; Empty symbolic-key mapping fixture.
(define empty-symbols
  (mapping default-comparator))

;; Ordered symbolic-key mapping fixture built from shuffled constructor input.
(define symbols
  (mapping default-comparator 'b 2 'a 1 'c 3))

(check-true 'predicate-mapping (mapping? symbols))
(check-true 'predicate-empty (mapping-empty? empty-symbols))
(check-false 'predicate-non-empty (mapping-empty? symbols))
(check 'constructor-orders-keys
       (mapping->alist symbols)
       '((a . 1) (b . 2) (c . 3)))
(check 'mapping-ref (mapping-ref symbols 'b) 2)
(check 'mapping-ref/default-missing
       (mapping-ref/default symbols 'missing 42)
       42)

;; Mapping fixture that exercises repeated keys in `mapping-set'.
(define set-duplicates
  (mapping-set symbols 'b 20 'b 21 'd 4))

;; Mapping fixture that exercises repeated keys in `mapping-adjoin'.
(define adjoin-duplicates
  (mapping-adjoin symbols 'b 20 'd 4 'd 5))

(check 'mapping-set-last-duplicate-wins
       (mapping->alist set-duplicates)
       '((a . 1) (b . 21) (c . 3) (d . 4)))
(check 'mapping-adjoin-keeps-existing-and-first-new
       (mapping->alist adjoin-duplicates)
       '((a . 1) (b . 2) (c . 3) (d . 4)))

;; Integer-keyed mapping fixture used for set and range operations.
(define numbers
  (mapping integer-comparator
           3 'three
           1 'one
           4 'four
           2 'two))

(check 'mapping-union-prefers-left
       (mapping->alist
        (mapping-union numbers (mapping integer-comparator 2 'dos 5 'five)))
       '((1 . one) (2 . two) (3 . three) (4 . four) (5 . five)))
(check 'mapping-intersection-keeps-common-left-values
       (mapping->alist
        (mapping-intersection
         numbers
         (mapping integer-comparator 2 'dos 4 'cuatro 6 'six)))
       '((2 . two) (4 . four)))
(check 'mapping-difference-removes-common
       (mapping->alist
        (mapping-difference numbers (mapping integer-comparator 2 'dos)))
       '((1 . one) (3 . three) (4 . four)))
(check 'mapping-range>=
       (mapping->alist (mapping-range>= numbers 3))
       '((3 . three) (4 . four)))

(check 'mapping-split
       (call-with-values
        (lambda () (mapping-split numbers 3))
        (lambda mappings
          (mapping-values-list mappings)))
       '((one two) (one two three) (three) (three four) (four)))

;; Mapping produced by a finite unfold over ascending integer keys.
(define unfolded
  (mapping-unfold (lambda (seed) (> seed 3))
                  (lambda (seed) (values seed (* seed seed)))
                  (lambda (seed) (+ seed 1))
                  1
                  integer-comparator))

(check 'mapping-unfold
       (mapping->alist unfolded)
       '((1 . 1) (2 . 4) (3 . 9)))

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

(check-true 'mapping<=?-proper-subset
            (mapping<=? integer-comparator subset-left subset-right))
(check-true 'mapping<?-proper-subset
            (mapping<? integer-comparator subset-left subset-right))
(check-true 'mapping>=?-proper-superset
            (mapping>=? integer-comparator subset-right subset-left))
(check-true 'mapping>?-proper-superset
            (mapping>? integer-comparator subset-right subset-left))
(check-false 'mapping<?-overlap-not-subset
             (mapping<? integer-comparator overlap-left overlap-right))
(check-false 'mapping>?-overlap-not-superset
             (mapping>? integer-comparator overlap-left overlap-right))
(check-false 'mapping>=?-overlap-not-superset
             (mapping>=? integer-comparator overlap-left overlap-right))

;; Model fixture for deterministic operation-sequence checks.
(define model-base
  '((1 . one) (2 . two) (3 . three)))

;; Mapping fixture corresponding to `model-base'.
(define mapping-base
  (alist->mapping integer-comparator model-base))

;; Expected model after a set operation with insertion, replacement, and front insertion.
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

(check 'model-set-sequence
       (mapping->alist mapping-after-set)
       model-after-set)
(check 'model-delete-sequence
       (mapping->alist mapping-after-delete)
       model-after-delete)
(check 'model-adjoin-sequence
       (mapping->alist mapping-after-adjoin)
       model-after-adjoin)
(check 'model-union-left-biased
       (mapping->alist (mapping-union mapping-after-adjoin mapping-other))
       (model-union model-after-adjoin model-other))
(check 'model-intersection-left-values
       (mapping->alist (mapping-intersection mapping-after-adjoin mapping-other))
       (model-intersection model-after-adjoin model-other))
(check 'model-difference
       (mapping->alist (mapping-difference mapping-after-adjoin mapping-other))
       (model-difference model-after-adjoin model-other))
(check 'model-range>=
       (mapping->alist (mapping-range>= mapping-after-adjoin 4))
       (model-range>= model-after-adjoin 4))

(finish-mapping-smoke-tests)
