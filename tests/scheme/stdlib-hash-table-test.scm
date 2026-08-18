;;; Portable SRFI 125 hash-table stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (stdlib comparator)
        (except (stdlib hash-table) string-hash string-ci-hash)
        (only (stdlib hash-table implementation)
              hash-table-storage-entries
              hash-table-storage-mutation-version
              hash-table-storage-structural-version
              hash-table-entry-key
              hash-table-entry-next
              hash-table-entry-previous)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when THUNK raises an exception."
  (guard (condition (else #t))
    (thunk)
    #f))

(define (every? predicate values)
  "Return whether PREDICATE accepts every member of VALUES."
  (or (null? values)
      (and (predicate (car values))
           (every? predicate (cdr values)))))

;; Comparator for ordinary exact-integer keys.
(define integer-comparator
  (make-comparator integer? = < number-hash))

;; Separately allocated comparator with the same integer semantics.
(define alternate-integer-comparator
  (make-comparator integer? = < number-hash))

;; Comparator for symbol keys and values used throughout the examples.
(define symbol-comparator
  (make-comparator symbol? eq? #f symbol-hash))

;; Adversarial symbol comparator whose keys all occupy the same bucket.
(define collision-comparator
  (make-comparator symbol? eq? #f (lambda (key) 0)))

;; Coarse comparator used to test asymmetric cross-policy equivalence.
(define all-integers-equivalent-comparator
  (make-comparator integer? (lambda (left right) #t) #f
                   (lambda (key) 0)))

(define (sorted numbers)
  "Return NUMBERS sorted in ascending order."
  (let insert-all ((rest numbers) (result '()))
    (if (null? rest)
        result
        (let insert ((prefix '()) (tail result))
          (cond
           ((null? tail)
            (insert-all (cdr rest)
                        (append (reverse prefix) (list (car rest)))))
           ((< (car rest) (car tail))
            (insert-all
             (cdr rest)
             (append (reverse prefix) (cons (car rest) tail))))
           (else
            (insert (cons (car tail) prefix) (cdr tail))))))))

(testing-registry-case
 'hash-table/construction-and-access '(portable stdlib conformance)
 (test-equal
  'hash-table/construction-and-access
  '(#t 3 #t #f one missing 30)
  (let ((table (make-hash-table symbol-comparator 32)))
    (hash-table-set! table 'a 'one 'b 'two)
    (hash-table-intern! table 'c (lambda () 'three))
    (list (hash-table? table)
          (hash-table-size table)
          (hash-table-contains? table 'a)
          (hash-table-exists? table 'missing)
          (hash-table-ref table 'a)
          (hash-table-ref table 'missing (lambda () 'missing))
          (hash-table-ref table 'b (lambda () 'bad)
                          (lambda (value) (* 10 (string-length
                                                (symbol->string value)))))))))

(testing-registry-case
 'hash-table/constructors '(portable stdlib conformance)
 (test-equal
  'hash-table/constructors
  '((0 1 4 9) (one two three) (a b) #t #t)
  (let ((unfolded
         (hash-table-unfold
          (lambda (seed) (= seed 4))
          (lambda (seed) (values seed (* seed seed)))
          (lambda (seed) (+ seed 1))
          0
          integer-comparator))
        (from-alist
         (alist->hash-table
          '((a . one) (b . two) (a . ignored) (c . three))
          symbol-comparator))
        (literal (hash-table symbol-comparator 'a 1 'b 2)))
    (list (sorted (hash-table-values unfolded))
          (map (lambda (key) (hash-table-ref from-alist key))
               '(a b c))
          (hash-table-keys literal)
          (not (hash-table-mutable? literal))
          (raises? (lambda () (hash-table-set! literal 'c 3)))))))

(testing-registry-case
 'hash-table/collisions-and-growth '(portable stdlib conformance stress)
 (test-equal
  'hash-table/collisions-and-growth
  '(198 199 100 #t)
  (let ((table (make-hash-table collision-comparator 0)))
    (let fill ((index 0))
      (if (< index 200)
          (begin
            (hash-table-set!
             table
             (string->symbol (string-append "key-" (number->string index)))
             index)
            (fill (+ index 1)))))
    (let ((last (hash-table-ref table 'key-199)))
      (hash-table-delete! table 'key-0 'key-2 'absent)
      (hash-table-set! table 'key-100 'updated)
      (list (hash-table-size table)
            last
            (hash-table-ref table 'key-100
                            (lambda () 'missing)
                            (lambda (value)
                              (if (eq? value 'updated) 100 -1)))
            (not (hash-table-contains? table 'key-0)))))))

(testing-registry-case
 'hash-table/mutation-operations '(portable stdlib conformance)
 (test-equal
  'hash-table/mutation-operations
  '(1 20 8 (d 7) 2 0)
  (let ((table (make-hash-table symbol-comparator)))
    (hash-table-set! table 'a 1 'b 2 'c 3)
    (let ((deleted (hash-table-delete! table 'a 'missing)))
      (hash-table-update! table 'b (lambda (value) (* value 10)))
      (hash-table-update! table 'd (lambda (value) (+ value 1))
                          (lambda () 6))
      (hash-table-update!/default table 'c (lambda (value) (+ value 5)) 5)
      (let ((popped
             (call-with-values (lambda () (hash-table-pop! table)) list)))
        (let ((b-value (hash-table-ref table 'b))
              (c-value (hash-table-ref table 'c))
              (remaining (hash-table-size table)))
          (hash-table-clear! table)
          (list deleted
                b-value
                c-value
                popped
                remaining
                (hash-table-size table))))))))

(testing-registry-case
 'hash-table/whole-table-operations '(portable stdlib conformance)
 (test-equal
  'hash-table/whole-table-operations
  '(3 2 60 3 (10 20 30) ((a . 1) (b . 2) (c . 3)))
  (let ((table (make-hash-table symbol-comparator)))
    (hash-table-set! table 'a 1 'b 2 'c 3)
    (list
     (hash-table-count (lambda (key value) (positive? value)) table)
     (hash-table-find
      (lambda (key value) (and (eq? key 'b) value))
      table
      (lambda () 'missing))
     (hash-table-fold
      (lambda (key value total) (+ total (* 10 value))) 0 table)
     (length (hash-table-map->list cons table))
     (hash-table-values
      (hash-table-map (lambda (value) (* value 10))
                      symbol-comparator table))
     (hash-table->alist table)))))

(testing-registry-case
 'hash-table/entries-and-fresh-results '(portable stdlib conformance)
 (test-equal
  'hash-table/entries-and-fresh-results
  '(#t 1 2 #t)
  (let ((table (make-hash-table symbol-comparator)))
    (hash-table-set! table 'a 1 'b 2)
    (call-with-values
     (lambda () (hash-table-entries table))
     (lambda (keys values)
       (let ((pairs (map cons keys values)))
         (set-car! keys 'changed)
         (set-car! values 99)
         (list
          (every?
           (lambda (pair)
             (= (cdr pair) (hash-table-ref table (car pair))))
           pairs)
          (hash-table-ref table 'a)
          (hash-table-ref table 'b)
          (call-with-values
           (lambda () (hash-table-entries table))
           (lambda (next-keys next-values)
             (and (not (eq? keys next-keys))
                  (not (eq? values next-values))))))))))))

(testing-registry-case
 'hash-table/traversal-and-prune '(portable stdlib conformance)
 (test-equal
  'hash-table/traversal-and-prune
  '(6 6 (b))
  (let ((table (make-hash-table symbol-comparator))
        (for-each-total 0)
        (walk-total 0))
    (hash-table-set! table 'a 1 'b 2 'c 3)
    (hash-table-for-each
     (lambda (key value)
       (set! for-each-total (+ for-each-total value)))
     table)
    (hash-table-walk
     table
     (lambda (key value)
       (set! walk-total (+ walk-total value))))
    (hash-table-prune! (lambda (key value) (odd? value)) table)
    (list for-each-total walk-total (hash-table-keys table)))))

(testing-registry-case
 'hash-table/copy-and-map '(portable stdlib conformance)
 (test-equal
  'hash-table/copy-and-map
  '(#f #t 2 0 (2 3))
  (let ((table (make-hash-table symbol-comparator)))
    (hash-table-set! table 'a 1 'b 2)
    (let ((immutable (hash-table-copy table))
          (mutable (hash-table-copy table #t))
          (empty (hash-table-empty-copy table)))
      (hash-table-map! (lambda (key value) (+ value 1)) mutable)
      (list (hash-table-mutable? immutable)
            (hash-table-mutable? mutable)
            (hash-table-size immutable)
            (hash-table-size empty)
            (hash-table-values mutable))))))

(testing-registry-case
 'hash-table/set-operations '(portable stdlib conformance)
 (test-equal
  'hash-table/set-operations
  '((a b c) (b) (a) (a c))
  (let ((left (make-hash-table symbol-comparator))
        (right (make-hash-table symbol-comparator)))
    (hash-table-set! left 'a 1 'b 2)
    (hash-table-set! right 'b 20 'c 30)
    (let ((union (hash-table-copy left #t))
          (intersection (hash-table-copy left #t))
          (difference (hash-table-copy left #t))
          (xor (hash-table-copy left #t)))
      (hash-table-union! union right)
      (hash-table-intersection! intersection right)
      (hash-table-difference! difference right)
      (hash-table-xor! xor right)
      (list (hash-table-keys union)
            (hash-table-keys intersection)
            (hash-table-keys difference)
            (hash-table-keys xor))))))

(testing-registry-case
 'hash-table/comparator-contracts '(portable stdlib conformance error)
 (test-equal
  'hash-table/comparator-contracts
  '(#t #t #t #t #t)
  (let ((table (make-hash-table integer-comparator))
        (other (make-hash-table alternate-integer-comparator)))
    (hash-table-set! table 1 'one)
    (hash-table-set! other 1 'one)
    (list
     (raises? (lambda () (hash-table-set! table 'not-an-integer 1)))
     (hash-table=? symbol-comparator table other)
     (eq? table (hash-table-union! table other))
     (raises? (lambda ()
                (make-hash-table integer-comparator 'weak-keys)))
     (raises? (lambda ()
                (make-hash-table (lambda (left right) #f))))))))

(testing-registry-case
 'hash-table/error-contracts '(portable stdlib conformance error)
 (test-equal
  'hash-table/error-contracts
  '(#t #t #t #t #t)
  (let ((table (make-hash-table symbol-comparator))
        (unhashable
         (make-comparator integer? = < #f)))
    (list
     (raises? (lambda () (hash-table-pop! table)))
     (raises? (lambda () (hash-table symbol-comparator 'odd)))
     (raises? (lambda () (hash-table-set! table 'odd)))
     (raises?
      (lambda ()
        (hash-table-ref table 'missing
                        (lambda () 'missing)
                        (lambda (value) value)
                        'extra)))
     (raises? (lambda () (make-hash-table unhashable)))))))

(testing-registry-case
 'hash-table/different-key-comparators '(portable stdlib conformance)
 (test-equal
  'hash-table/different-key-comparators
  '(#f 0 1)
  (let ((exact (make-hash-table integer-comparator))
        (coarse (make-hash-table all-integers-equivalent-comparator))
        (symbols (make-hash-table symbol-comparator)))
    (hash-table-set! exact 1 'same)
    (hash-table-set! coarse 2 'same)
    (hash-table-set! symbols 'one 'same)
    (let ((intersection (hash-table-copy exact #t))
          (difference (hash-table-copy exact #t)))
      (hash-table-intersection! intersection symbols)
      (hash-table-difference! difference symbols)
      (list (hash-table=? symbol-comparator exact coarse)
            (hash-table-size intersection)
            (hash-table-size difference))))))

(testing-registry-case
 'hash-table/deprecated-hashes-and-reflection
 '(portable stdlib conformance deprecated)
 (test-equal
  'hash-table/deprecated-hashes-and-reflection
  '(#t #t #t #t #t)
  (let* ((legacy-hash (lambda (object) (hash object)))
         (table (make-hash-table eq? legacy-hash)))
    (list
     (eq? eq? (hash-table-equivalence-function table))
     (eq? legacy-hash (hash-table-hash-function table))
     (= (hash 'value) (hash 'value 97))
     (= (hash-by-identity table) (hash-by-identity table 97))
     (raises? (lambda () (hash 'value 97 193)))))))

(testing-registry-case
 'hash-table/callback-mutation-guards '(portable stdlib conformance error)
 (test-equal
  'hash-table/callback-mutation-guards
  '(#t #t #t #t #t #t #t #t #t)
  (let ((walk
         (lambda (walker)
           (let ((table (make-hash-table symbol-comparator)))
             (hash-table-set! table 'a 1 'b 2)
             (raises? (lambda () (walker table)))))))
    (list
     (walk
      (lambda (table)
        (hash-table-find
         (lambda (key value)
           (hash-table-set! table 'c 3)
           #f)
         table
         (lambda () #f))))
     (walk
      (lambda (table)
        (hash-table-count
         (lambda (key value)
           (hash-table-set! table 'c 3)
           #t)
         table)))
     (walk
      (lambda (table)
        (hash-table-map
         (lambda (value)
           (hash-table-set! table 'c 3)
           value)
         symbol-comparator
         table)))
     (walk
      (lambda (table)
        (hash-table-for-each
         (lambda (key value)
           (hash-table-set! table 'c 3))
         table)))
     (walk
      (lambda (table)
        (hash-table-map!
         (lambda (key value)
           (hash-table-set! table 'c 3)
           value)
         table)))
     (walk
      (lambda (table)
        (hash-table-map->list
         (lambda (key value)
           (hash-table-set! table 'c 3)
           value)
         table)))
     (walk
      (lambda (table)
        (hash-table-fold
         (lambda (key value total)
           (hash-table-set! table 'c 3)
           (+ total value))
         0
         table)))
     (walk
      (lambda (table)
        (hash-table-prune!
         (lambda (key value)
           (hash-table-set! table 'c 3)
           #f)
         table)))
     (let ((source (make-hash-table symbol-comparator))
           (other (make-hash-table symbol-comparator)))
       (hash-table-set! source 'a 1 'b 2)
       (hash-table-for-each
        (lambda (key value)
          (hash-table-set! other key value))
        source)
       (= 2 (hash-table-size other)))))))

(testing-registry-case
 'hash-table/immutable-mutator-guards '(portable stdlib conformance error)
 (test-equal
  'hash-table/immutable-mutator-guards
  '(#t #t #t #t #t #t #t #t #t #t #t #t #t #t)
  (let ((rejects?
         (lambda (mutator)
           (let ((table (hash-table symbol-comparator 'a 1))
                 (other (make-hash-table symbol-comparator)))
             (hash-table-set! other 'b 2)
             (raises? (lambda () (mutator table other)))))))
    (list
     (rejects? (lambda (table other) (hash-table-set! table 'b 2)))
     (rejects? (lambda (table other) (hash-table-delete! table 'a)))
     (rejects?
      (lambda (table other)
        (hash-table-intern! table 'b (lambda () 2))))
     (rejects?
      (lambda (table other)
        (hash-table-update! table 'a (lambda (value) (+ value 1)))))
     (rejects?
      (lambda (table other)
        (hash-table-update!/default
         table 'a (lambda (value) (+ value 1)) 0)))
     (rejects? (lambda (table other) (hash-table-pop! table)))
     (rejects? (lambda (table other) (hash-table-clear! table)))
     (rejects?
      (lambda (table other)
        (hash-table-map! (lambda (key value) value) table)))
     (rejects?
      (lambda (table other)
        (hash-table-prune! (lambda (key value) #f) table)))
     (rejects? (lambda (table other) (hash-table-union! table other)))
     (rejects? (lambda (table other) (hash-table-merge! table other)))
     (rejects?
      (lambda (table other) (hash-table-intersection! table other)))
     (rejects?
      (lambda (table other) (hash-table-difference! table other)))
     (rejects? (lambda (table other) (hash-table-xor! table other)))))))

(testing-registry-case
 'hash-table/shared-engine-order-and-revisions
 '(portable stdlib internal invariant)
 (test-equal
  'hash-table/shared-engine-order-and-revisions
  '((a b c) #t #t #t (a c b))
  (let ((table (make-hash-table symbol-comparator)))
    (let ((mutation0 (hash-table-storage-mutation-version table))
          (structural0 (hash-table-storage-structural-version table)))
      (hash-table-set! table 'a 1 'b 2 'c 3)
      (let ((structural1 (hash-table-storage-structural-version table)))
        (hash-table-set! table 'b 20)
        (let* ((entries (hash-table-storage-entries table))
               (linked?
                (and (eq? (hash-table-entry-next (car entries))
                          (cadr entries))
                     (eq? (hash-table-entry-previous (cadr entries))
                          (car entries)))))
          (hash-table-delete! table 'b)
          (hash-table-set! table 'b 200)
          (list
           (map hash-table-entry-key entries)
           (> (hash-table-storage-mutation-version table) mutation0)
           (= structural1
              (- (hash-table-storage-structural-version table) 2))
           linked?
           (hash-table-keys table))))))))

(testing-runner-main "SRFI 125 hash tables" (command-line))
