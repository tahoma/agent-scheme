;;; Portable SRFI 146 ordered mapping stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 146 `srfi/146/test.sld` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-146.
;;; The original tests use SRFI 64; this file keeps the ordered-mapping
;;; assertions in a portable harness so direct Consent Scheme hosts can exercise
;;; the adapted `(stdlib mapping)' library broadly.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib mapping)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when THUNK raises any condition."
  (call/cc
   (lambda (return)
     (with-exception-handler
      (lambda (condition) (return #t))
      (lambda () (thunk) #f)))))

(define (sum numbers)
  "Return the arithmetic sum of NUMBERS."
  (let loop ((numbers numbers) (total 0))
    (if (null? numbers)
        total
        (loop (cdr numbers) (+ total (car numbers))))))

(define (values-list thunk)
  "Return all values produced by THUNK as a list."
  (call-with-values thunk list))

(define (mapping-values-list mappings)
  "Return the value lists for every mapping in MAPPINGS."
  (map mapping-values mappings))

;; Shared integer comparator for duplicate-key and model-oriented checks.
(define integer-comparator
  (make-comparator integer? = < number-hash))

;; Shared default comparator for upstream-style symbolic-key checks.
(define default-comparator
  (make-default-comparator))

(testing-registry-case
 'predicate-mapping '(portable stdlib)
(let ((mapping0 (mapping default-comparator))
      (mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'c 1 'd 2 'e 3))
      (mapping3 (mapping default-comparator 'd 1 'e 2 'f 3)))
  (test-assert 'predicate-mapping (mapping? (mapping default-comparator)))
  (test-assert 'predicate-non-mapping (not (mapping? (list 1 2 3))))
  (test-assert 'predicate-empty (mapping-empty? mapping0))
  (test-assert 'predicate-non-empty (not (mapping-empty? mapping1)))
  (test-assert 'predicate-contains (mapping-contains? mapping1 'b))
  (test-assert 'predicate-missing (not (mapping-contains? mapping1 'z)))
  (test-assert 'predicate-disjoint (mapping-disjoint? mapping1 mapping3))
  (test-assert 'predicate-not-disjoint (not (mapping-disjoint? mapping1 mapping2)))))

(testing-registry-case
 'ref-found '(portable stdlib)
(let ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3)))
  (test-equal 'ref-found 2 (mapping-ref mapping1 'b))
  (test-equal 'ref-missing-failure
             42
             (mapping-ref mapping1 'd (lambda () 42)))
  (test-assert 'ref-missing-raises
             (raises? (lambda () (mapping-ref mapping1 'd))))
  (test-equal 'ref-success
             4
             (mapping-ref mapping1 'b (lambda () #f) (lambda (value) (* value value))))
  (test-equal 'ref/default-found 3 (mapping-ref/default mapping1 'c 42))
  (test-equal 'ref/default-missing 42 (mapping-ref/default mapping1 'd 42))
  (test-equal 'key-comparator default-comparator (mapping-key-comparator mapping1))))

(testing-registry-case
 'adjoin-existing '(portable stdlib)
(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (mapping-set mapping1 'c 4 'd 4 'd 5))
       (mapping3 (mapping-update mapping1 'b (lambda (value) (* value value))))
       (mapping4 (mapping-update/default
                  mapping1 'd (lambda (value) (* value value)) 4))
       (mapping5 (mapping-adjoin mapping1 'c 4 'd 4 'd 5))
       (mapping0 (mapping default-comparator)))
  (test-equal 'adjoin-existing 3 (mapping-ref mapping5 'c))
  (test-equal 'adjoin-first-new-duplicate 4 (mapping-ref mapping5 'd))
  (test-equal 'adjoin!-alias
             '((a . 1) (b . 2) (c . 3) (d . 4))
             (mapping->alist (mapping-adjoin! mapping1 'c 4 'd 4)))
  (test-equal 'set-existing 4 (mapping-ref mapping2 'c))
  (test-equal 'set-latest-new-duplicate 5 (mapping-ref mapping2 'd))
  (test-equal 'set!-alias
             '((a . 1) (b . 2) (c . 4) (d . 4))
             (mapping->alist (mapping-set! mapping1 'c 4 'd 4)))
  (test-equal 'replace-missing
             #f
             (mapping-ref/default (mapping-replace mapping1 'd 4) 'd #f))
  (test-equal 'replace-present 6 (mapping-ref (mapping-replace mapping1 'c 6) 'c))
  (test-equal 'replace!-alias
             '((a . 1) (b . 2) (c . 6))
             (mapping->alist (mapping-replace! mapping1 'c 6)))
  (test-equal 'delete 42 (mapping-ref/default (mapping-delete mapping1 'b) 'b 42))
  (test-equal 'delete!-alias
             '((b . 2))
             (mapping->alist (mapping-delete! mapping1 'a 'c)))
  (test-equal 'delete-all
             42
             (mapping-ref/default (mapping-delete-all mapping1 '(a b)) 'b 42))
  (test-equal 'delete-all!-alias
             '((c . 3))
             (mapping->alist (mapping-delete-all! mapping1 '(a b))))
  (test-equal 'intern-present
             (list mapping1 2)
             (values-list
          (lambda ()
            (mapping-intern
             mapping1
             'b
             (lambda () (error "should not have been invoked"))))))
  (test-equal 'intern-missing
             '(42 42)
             (call-with-values
          (lambda () (mapping-intern mapping1 'd (lambda () 42)))
          (lambda (mapping value)
            (list value (mapping-ref mapping 'd)))))
  (test-equal 'intern!-alias
             '(42 42)
             (call-with-values
          (lambda () (mapping-intern! mapping1 'd (lambda () 42)))
          (lambda (mapping value)
            (list value (mapping-ref mapping 'd)))))
  (test-equal 'update 4 (mapping-ref mapping3 'b))
  (test-equal 'update-missing-with-failure
             16
             (mapping-ref (mapping-update mapping1 'd
                                      (lambda (value) (* value value))
                                      (lambda () 4))
                      'd))
  (test-equal 'update-missing-without-failure-raises
             #t
             (raises? (lambda () (mapping-update mapping1 'd (lambda (value) value)))))
  (test-equal 'update!-alias
             3
             (mapping-ref (mapping-update! mapping1 'b (lambda (value) (+ value 1)))
                      'b))
  (test-equal 'update/default 16 (mapping-ref mapping4 'd))
  (test-equal 'update!/default-alias
             16
             (mapping-ref (mapping-update!/default
                       mapping1 'd (lambda (value) (* value value)) 4)
                      'd))
  (test-equal 'pop-empty-with-failure
             'empty
             (mapping-pop mapping0 (lambda () 'empty)))
  (test-assert 'pop-empty-raises
             (raises? (lambda ()
                         (call-with-values
                          (lambda () (mapping-pop mapping0))
                          list))))
  (test-equal 'pop-non-empty
             '(2 a 1)
             (call-with-values
          (lambda () (mapping-pop mapping1))
          (lambda (mapping key value)
            (list (mapping-size mapping) key value))))
  (test-equal 'pop!-alias
             '(2 a 1)
             (call-with-values
          (lambda () (mapping-pop! mapping1))
          (lambda (mapping key value)
            (list (mapping-size mapping) key value))))
  (test-equal 'search-update-and-ignore
             '("success updated"
           "failure ignored"
           ((0 . "zero") (1 . "one") (2 . "two [seen]") (3 . "three")
            (4 . "four") (5 . "five")))
             (let ((m1 (mapping integer-comparator
                            1 "one"
                            3 "three"
                            0 "zero"
                            4 "four"
                            2 "two"
                            5 "five")))
           (define (failure/ignore insert ignore)
             (ignore "failure ignored"))
           (define (success/update key value update remove)
             (update key
                     (string-append value " [seen]")
                     "success updated"))
           (let*-values (((m2 v2)
                          (mapping-search m1 2
                                          failure/ignore
                                          success/update))
                         ((m3 v3)
                          (mapping-search m2 42
                                          failure/ignore
                                          success/update)))
             (list v2 v3 (mapping->alist m3)))))
  (test-equal 'search-insert-and-remove
             '((inserted ((a . 1) (b . 2) (c . 3) (d . 4)))
           (removed ((a . 1) (c . 3))))
             (let* ((inserted
                 (call-with-values
                  (lambda ()
                    (mapping-search! mapping1
                                     'd
                                     (lambda (insert ignore)
                                       (insert 4 'inserted))
                                     (lambda (key value update remove)
                                       (remove 'removed))))
                  (lambda (mapping status)
                    (list status (mapping->alist mapping)))))
                (removed
                 (call-with-values
                  (lambda ()
                    (mapping-search! mapping1
                                     'b
                                     (lambda (insert ignore)
                                       (ignore 'ignored))
                                     (lambda (key value update remove)
                                       (remove 'removed))))
                  (lambda (mapping status)
                    (list status (mapping->alist mapping))))))
           (list inserted removed)))))

(testing-registry-case
 'mapping-unfold '(portable stdlib)
(let ((unfolded
       (mapping-unfold (lambda (seed) (> seed 3))
                       (lambda (seed) (values seed (* seed seed)))
                       (lambda (seed) (+ seed 1))
                       1
                       integer-comparator))
      (ordered
       (mapping/ordered integer-comparator 3 'three 1 'one 2 'two))
      (unfolded/ordered
       (mapping-unfold/ordered (lambda (seed) (> seed 3))
                               (lambda (seed) (values seed (* seed seed)))
                               (lambda (seed) (+ seed 1))
                               1
                               integer-comparator)))
  (test-equal 'mapping-unfold '((1 . 1) (2 . 4) (3 . 9)) (mapping->alist unfolded))
  (test-equal 'mapping/ordered
             '((1 . one) (2 . two) (3 . three))
             (mapping->alist ordered))
  (test-equal 'mapping-unfold/ordered
             '((1 . 1) (2 . 4) (3 . 9))
             (mapping->alist unfolded/ordered))
  (test-assert 'constructor-odd-arguments-raises
             (raises? (lambda () (mapping integer-comparator 1))))))

(testing-registry-case
 'size-empty '(portable stdlib)
(let ((mapping0 (mapping default-comparator))
      (mapping1 (mapping default-comparator 'a 1 'b 2 'c 3)))
  (test-equal 'size-empty 0 (mapping-size mapping0))
  (test-equal 'size-non-empty 3 (mapping-size mapping1))
  (test-equal 'find-present
             '(b 2)
             (values-list
          (lambda ()
            (mapping-find (lambda (key value)
                            (and (eq? key 'b) (= value 2)))
                          mapping1
                          (lambda () (error "should not have been invoked"))))))
  (test-equal 'find-missing
             '(42)
             (values-list
          (lambda ()
            (mapping-find (lambda (key value) (eq? key 'd))
                          mapping1
                          (lambda () 42)))))
  (test-equal 'count 2 (mapping-count (lambda (key value) (>= value 2)) mapping1))
  (test-assert 'any-present
             (mapping-any? (lambda (key value) (= value 3)) mapping1))
  (test-assert 'any-missing
             (not (mapping-any? (lambda (key value) (= value 4)) mapping1)))
  (test-assert 'every-true
             (mapping-every? (lambda (key value) (<= value 3)) mapping1))
  (test-assert 'every-false
             (not (mapping-every? (lambda (key value) (<= value 2)) mapping1)))
  (test-equal 'keys '(a b c) (mapping-keys mapping1))
  (test-equal 'values '(1 2 3) (mapping-values mapping1))
  (test-equal 'entries
             '((a b c) (1 2 3))
             (call-with-values
          (lambda () (mapping-entries mapping1))
          (lambda (keys values)
            (list keys values))))))

(testing-registry-case
 'map '(portable stdlib)
(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (mapping-map (lambda (key value)
                                (values (symbol->string key) (* 10 value)))
                              default-comparator
                              mapping1)))
  (test-equal 'map 20 (mapping-ref mapping2 "b"))
  (test-equal 'for-each
             6
             (let ((counter 0))
           (mapping-for-each (lambda (key value)
                               (set! counter (+ counter value)))
                             mapping1)
           counter))
  (test-equal 'fold
             6
             (mapping-fold (lambda (key value total)
                         (+ value total))
                       0
                       mapping1))
  (test-equal 'map->list
             14
             (sum (mapping-map->list (lambda (key value) (* value value))
                                 mapping1)))
  (test-equal 'filter
             '((a . 1) (b . 2))
             (mapping->alist (mapping-filter (lambda (key value) (<= value 2))
                                         mapping1)))
  (test-equal 'filter!-alias
             '((a . 1) (b . 2))
             (mapping->alist (mapping-filter! (lambda (key value) (<= value 2))
                                          mapping1)))
  (test-equal 'remove
             '((c . 3))
             (mapping->alist (mapping-remove (lambda (key value) (<= value 2))
                                         mapping1)))
  (test-equal 'remove!-alias
             '((c . 3))
             (mapping->alist (mapping-remove! (lambda (key value) (<= value 2))
                                          mapping1)))
  (test-equal 'partition
             '(((b . 2)) ((a . 1) (c . 3)))
             (call-with-values
          (lambda () (mapping-partition (lambda (key value) (eq? key 'b))
                                        mapping1))
          (lambda (matching removed)
            (list (mapping->alist matching) (mapping->alist removed)))))
  (test-equal 'partition!-alias
             '(((b . 2)) ((a . 1) (c . 3)))
             (call-with-values
          (lambda () (mapping-partition! (lambda (key value) (eq? key 'b))
                                         mapping1))
          (lambda (matching removed)
            (list (mapping->alist matching) (mapping->alist removed)))))))

(testing-registry-case
 'copy-size '(portable stdlib)
(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (alist->mapping default-comparator
                                 '((a . 1) (b . 2) (c . 3))))
       (mapping3 (alist->mapping! (mapping-copy mapping1)
                                  '((d . 4) (c . 5)))))
  (test-equal 'copy-size 3 (mapping-size (mapping-copy mapping1)))
  (test-equal 'copy-comparator
             default-comparator
             (mapping-key-comparator (mapping-copy mapping1)))
  (test-equal 'mapping->alist '(b . 2) (assq 'b (mapping->alist mapping1)))
  (test-equal 'alist->mapping 2 (mapping-ref mapping2 'b))
  (test-equal 'alist->mapping!new 4 (mapping-ref mapping3 'd))
  (test-equal 'alist->mapping!existing 5 (mapping-ref mapping3 'c))
  (test-equal 'alist->mapping/ordered
             '((1 . one) (2 . two))
             (mapping->alist (alist->mapping/ordered integer-comparator
                                                 '((2 . two) (1 . one)))))
  (test-equal 'alist->mapping/ordered!
             '((1 . one) (2 . TWO))
             (mapping->alist
          (alist->mapping/ordered! (mapping integer-comparator 2 'two)
                                   '((1 . one) (2 . TWO)))))))

(testing-registry-case
 'mapping=?-equal '(portable stdlib)
(let ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping3 (mapping default-comparator 'a 1 'c 3))
      (mapping4 (mapping default-comparator 'a 1 'c 3 'd 4))
      (mapping5 (mapping default-comparator 'a 1 'b 2 'c 6))
      (mapping6 (mapping (make-comparator
                          (comparator-type-test-predicate default-comparator)
                          (comparator-equality-predicate default-comparator)
                          (comparator-ordering-predicate default-comparator)
                          (lambda (obj) 42))
                         'a 1 'b 2 'c 3)))
  (test-assert 'mapping=?-equal
             (mapping=? default-comparator mapping1 mapping2))
  (test-assert 'mapping=?-unequal
             (not (mapping=? default-comparator mapping1 mapping4)))
  (test-assert 'mapping=?-different-key-comparators
             (not (mapping=? default-comparator mapping1 mapping6)))
  (test-assert 'mapping<?-proper-subset
             (mapping<? default-comparator mapping3 mapping1))
  (test-assert 'mapping<?-improper-subset
             (not (mapping<? default-comparator mapping3 mapping1 mapping2)))
  (test-assert 'mapping<?-overlap-not-subset
             (not (mapping<? default-comparator
                          (mapping default-comparator 'a 1 'd 4)
                          mapping1)))
  (test-assert 'mapping>?-proper-superset
             (mapping>? default-comparator mapping2 mapping3))
  (test-assert 'mapping>?-improper-superset
             (not (mapping>? default-comparator mapping1 mapping2 mapping3)))
  (test-assert 'mapping>?-overlap-not-superset
             (not (mapping>? default-comparator
                          mapping1
                          (mapping default-comparator 'a 1 'd 4))))
  (test-assert 'mapping<=?-subset
             (mapping<=? default-comparator mapping3 mapping2 mapping1))
  (test-assert 'mapping<=?-non-matching-values
             (not (mapping<=? default-comparator mapping3 mapping5)))
  (test-assert 'mapping<=?-not-subset
             (not (mapping<=? default-comparator mapping2 mapping4)))
  (test-assert 'mapping>=?-superset
             (mapping>=? default-comparator mapping4 mapping3))
  (test-assert 'mapping>=?-not-superset
             (not (mapping>=? default-comparator mapping5 mapping3)))
  (test-assert 'mapping>=?-overlap-not-superset
             (not (mapping>=? default-comparator
                           mapping1
                           (mapping default-comparator 'a 1 'd 4))))))

(testing-registry-case
 'union-new '(portable stdlib)
(let ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'a 1 'b 2 'd 4))
      (mapping4 (mapping default-comparator 'a 1 'b 2 'c 4))
      (mapping5 (mapping default-comparator 'a 1 'c 3))
      (mapping6 (mapping default-comparator 'd 4 'e 5 'f 6)))
  (test-equal 'union-new
             4
             (mapping-ref (mapping-union mapping1 mapping2) 'd))
  (test-equal 'union-existing
             3
             (mapping-ref (mapping-union mapping1 mapping4) 'c))
  (test-equal 'union-three
             6
             (mapping-size (mapping-union mapping1 mapping2 mapping6)))
  (test-equal 'union!-alias
             6
             (mapping-size (mapping-union! mapping1 mapping2 mapping6)))
  (test-equal 'intersection-existing
             3
             (mapping-ref (mapping-intersection mapping1 mapping4) 'c))
  (test-equal 'intersection-removed
             42
             (mapping-ref/default (mapping-intersection mapping1 mapping5) 'b 42))
  (test-equal 'intersection!-alias
             '((a . 1) (c . 3))
             (mapping->alist (mapping-intersection! mapping1 mapping5)))
  (test-equal 'difference
             2
             (mapping-size (mapping-difference mapping2 mapping6)))
  (test-equal 'difference!-alias
             '((a . 1) (b . 2))
             (mapping->alist (mapping-difference! mapping2 mapping6)))
  (test-equal 'xor
             4
             (mapping-size (mapping-xor mapping2 mapping6)))
  (test-equal 'xor!-alias
             '((a . 1) (b . 2) (e . 5) (f . 6))
             (mapping->alist (mapping-xor! mapping2 mapping6)))))

(testing-registry-case
 'min-key '(portable stdlib)
(let ((mapping0 (mapping default-comparator))
      (mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'a 1 'b 2 'c 3 'd 4))
      (mapping3 (mapping default-comparator 'a 1 'b 2 'c 3 'd 4 'e 5))
      (mapping4 (mapping default-comparator
                         'a 1 'b 2 'c 3 'd 4 'e 5 'f 6))
      (mapping5 (mapping default-comparator 'f 6 'g 7 'h 8)))
  (test-equal 'min-key
             '(a a a a)
             (map mapping-min-key (list mapping1 mapping2 mapping3 mapping4)))
  (test-equal 'max-key
             '(c d e f)
             (map mapping-max-key (list mapping1 mapping2 mapping3 mapping4)))
  (test-equal 'min-value
             '(1 1 1 1)
             (map mapping-min-value (list mapping1 mapping2 mapping3 mapping4)))
  (test-equal 'max-value
             '(3 4 5 6)
             (map mapping-max-value (list mapping1 mapping2 mapping3 mapping4)))
  (test-assert 'min-key-empty-raises
             (raises? (lambda () (mapping-min-key mapping0))))
  (test-assert 'max-key-empty-raises
             (raises? (lambda () (mapping-max-key mapping0))))
  (test-assert 'min-value-empty-raises
             (raises? (lambda () (mapping-min-value mapping0))))
  (test-assert 'max-value-empty-raises
             (raises? (lambda () (mapping-max-value mapping0))))
  (test-equal 'key-predecessor
             '(c d d d)
             (map (lambda (mapping)
                (mapping-key-predecessor mapping 'e (lambda () #f)))
              (list mapping1 mapping2 mapping3 mapping4)))
  (test-equal 'key-successor
             '(#f #f e e)
             (map (lambda (mapping)
                (mapping-key-successor mapping 'd (lambda () #f)))
              (list mapping1 mapping2 mapping3 mapping4)))
  (test-equal 'key-predecessor-edge
             'none
             (mapping-key-predecessor mapping4 'a (lambda () 'none)))
  (test-equal 'key-successor-edge
             'none
             (mapping-key-successor mapping4 'f (lambda () 'none)))
  (test-equal 'range=present '(4) (mapping-values (mapping-range= mapping4 'd)))
  (test-equal 'range=absent '() (mapping-values (mapping-range= mapping4 'z)))
  (test-equal 'range< '(1 2 3) (mapping-values (mapping-range< mapping4 'd)))
  (test-equal 'range<= '(1 2 3 4) (mapping-values (mapping-range<= mapping4 'd)))
  (test-equal 'range> '(5 6) (mapping-values (mapping-range> mapping4 'd)))
  (test-equal 'range>= '(4 5 6) (mapping-values (mapping-range>= mapping4 'd)))
  (test-equal 'range=! '(4) (mapping-values (mapping-range=! mapping4 'd)))
  (test-equal 'range<! '(1 2 3) (mapping-values (mapping-range<! mapping4 'd)))
  (test-equal 'range<=! '(1 2 3 4) (mapping-values (mapping-range<=! mapping4 'd)))
  (test-equal 'range>! '(5 6) (mapping-values (mapping-range>! mapping4 'd)))
  (test-equal 'range>=! '(4 5 6) (mapping-values (mapping-range>=! mapping4 'd)))
  (test-equal 'split
             '((1 2 3) (1 2 3 4) (4) (4 5 6) (5 6))
             (call-with-values
          (lambda () (mapping-split mapping4 'd))
          (lambda mappings
            (mapping-values-list mappings))))
  (test-equal 'split-absent
             '((1 2 3 4 5 6) (1 2 3 4 5 6) () () ())
             (call-with-values
          (lambda () (mapping-split mapping4 'z))
          (lambda mappings
            (mapping-values-list mappings))))
  (test-equal 'catenate
             '((a . 1) (b . 2) (c . 3) (d . 4)
           (e . 5) (f . 6) (g . 7) (h . 8))
             (mapping->alist
          (mapping-catenate default-comparator mapping2 'e 5 mapping5)))
  (test-equal 'catenate!-alias
             '((a . 1) (b . 2) (c . 3) (d . 4)
           (e . 5) (f . 6) (g . 7) (h . 8))
             (mapping->alist
          (mapping-catenate! default-comparator mapping2 'e 5 mapping5)))
  (test-equal 'map/monotone
             '((1 . 1) (2 . 4) (3 . 9))
             (mapping->alist
          (mapping-map/monotone (lambda (key value)
                                  (values value (* value value)))
                                default-comparator
                                mapping1)))
  (test-equal 'map/monotone!-alias
             '((1 . 1) (2 . 4) (3 . 9))
             (mapping->alist
          (mapping-map/monotone! (lambda (key value)
                                   (values value (* value value)))
                                 default-comparator
                                 mapping1)))
  (test-equal 'fold/reverse
             '(1 2 3)
             (mapping-fold/reverse (lambda (key value values)
                                 (cons value values))
                               '()
                               mapping1))))

(testing-registry-case
 'mapping-comparator-predicate '(portable stdlib)
(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping3 (mapping default-comparator 'a 1 'b 2))
       (mapping4 (mapping default-comparator 'a 1 'b 2 'c 4))
       (mapping5 (mapping default-comparator 'a 1 'c 3))
       (mapping0 (mapping default-comparator
                          mapping1 "a"
                          mapping2 "b"
                          mapping3 "c"
                          mapping4 "d"
                          mapping5 "e"))
       (custom-mapping-comparator
        (make-mapping-comparator default-comparator)))
  (test-assert 'mapping-comparator-predicate
             (comparator? mapping-comparator))
  (test-assert 'make-mapping-comparator-predicate
             (comparator? custom-mapping-comparator))
  (test-equal 'mapping-keyed-mapping
             '("a" "a" "c" "d" "e")
             (list (mapping-ref mapping0 mapping1)
               (mapping-ref mapping0 mapping2)
               (mapping-ref mapping0 mapping3)
               (mapping-ref mapping0 mapping4)
               (mapping-ref mapping0 mapping5)))
  (test-assert 'comparator-equal
             (=? custom-mapping-comparator mapping1 mapping2))
  (test-assert 'comparator-unequal
             (not (=? custom-mapping-comparator mapping1 mapping4)))
  (test-assert 'comparator-less-subset
             (<? custom-mapping-comparator mapping3 mapping4))
  (test-assert 'comparator-less-value-order
             (<? custom-mapping-comparator mapping1 mapping4))
  (test-assert 'comparator-less-key-order
             (<? custom-mapping-comparator mapping1 mapping5))))

(testing-registry-case
 'constructor-preserves-earlier-duplicate '(portable stdlib)
(let* ((mapping1 (mapping integer-comparator 3 'three 1 'one 2 'two 2 'TWO))
       (mapping2 (mapping-set mapping1 4 'four 2 'TWO))
       (without-one (mapping-delete mapping2 1)))
  (test-equal 'constructor-preserves-earlier-duplicate
             '(#t 3 two)
             (list (mapping? mapping1)
               (mapping-size mapping1)
               (mapping-ref mapping1 2)))
  (test-equal 'alist-conversion-is-ordered
             '((1 . one) (2 . TWO) (3 . three) (4 . four))
             (mapping->alist mapping2))
  (test-equal 'keys-and-values-follow-key-order
             '((1 2 3 4) (one TWO three four))
             (call-with-values
          (lambda () (mapping-entries mapping2))
          (lambda (keys values)
            (list keys values))))
  (test-equal 'range-and-boundary-operations
             '(1 4 2 4 ((3 . three) (4 . four)))
             (list (mapping-min-key mapping2)
               (mapping-max-key mapping2)
               (mapping-key-predecessor mapping2 3 (lambda () 'none))
               (mapping-key-successor mapping2 3 (lambda () 'none))
               (mapping->alist (mapping-range>= mapping2 3))))
  (test-equal 'set-operations-and-delete
             '(missing ((2 . TWO) (4 . four)) ((1 . one) (3 . three)))
             (let ((overlap (mapping integer-comparator 2 'TWO 4 'four 9 'nine)))
           (list (mapping-ref/default without-one 1 'missing)
                 (mapping->alist (mapping-intersection mapping2 overlap))
                 (mapping->alist (mapping-difference mapping2 overlap)))))))

(testing-runner-main "Stdlib Mapping Conformance portable tests" (command-line))
