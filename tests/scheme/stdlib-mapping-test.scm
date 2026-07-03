;;; Portable SRFI 146 ordered mapping stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 146 `srfi/146/test.sld` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-146.
;;; The original tests use SRFI 64; this file keeps the ordered-mapping
;;; assertions in a small portable harness so every Consent Scheme host can
;;; exercise the adapted `(stdlib mapping)' library.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib mapping))

;; Number of failed ordered mapping checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed ordered mapping check."
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

(define (finish-mapping-tests)
  "Report the ordered mapping test result."
  (if (= failures 0)
      (begin
        (display "Ordered mapping tests passed")
        (newline))
      (begin
        (display failures)
        (display " ordered mapping test failure(s)")
        (newline)
        (error "ordered mapping tests failed" failures))))

;; Shared integer comparator for duplicate-key and model-oriented checks.
(define integer-comparator
  (make-comparator integer? = < number-hash))

;; Shared default comparator for upstream-style symbolic-key checks.
(define default-comparator
  (make-default-comparator))

(let ((mapping0 (mapping default-comparator))
      (mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'c 1 'd 2 'e 3))
      (mapping3 (mapping default-comparator 'd 1 'e 2 'f 3)))
  (check-true 'predicate-mapping (mapping? (mapping default-comparator)))
  (check-false 'predicate-non-mapping (mapping? (list 1 2 3)))
  (check-true 'predicate-empty (mapping-empty? mapping0))
  (check-false 'predicate-non-empty (mapping-empty? mapping1))
  (check-true 'predicate-contains (mapping-contains? mapping1 'b))
  (check-false 'predicate-missing (mapping-contains? mapping1 'z))
  (check-true 'predicate-disjoint (mapping-disjoint? mapping1 mapping3))
  (check-false 'predicate-not-disjoint (mapping-disjoint? mapping1 mapping2)))

(let ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3)))
  (check 'ref-found (mapping-ref mapping1 'b) 2)
  (check 'ref-missing-failure
         (mapping-ref mapping1 'd (lambda () 42))
         42)
  (check-true 'ref-missing-raises
              (raises? (lambda () (mapping-ref mapping1 'd))))
  (check 'ref-success
         (mapping-ref mapping1 'b (lambda () #f) (lambda (value) (* value value)))
         4)
  (check 'ref/default-found (mapping-ref/default mapping1 'c 42) 3)
  (check 'ref/default-missing (mapping-ref/default mapping1 'd 42) 42)
  (check 'key-comparator (mapping-key-comparator mapping1) default-comparator))

(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (mapping-set mapping1 'c 4 'd 4 'd 5))
       (mapping3 (mapping-update mapping1 'b (lambda (value) (* value value))))
       (mapping4 (mapping-update/default
                  mapping1 'd (lambda (value) (* value value)) 4))
       (mapping5 (mapping-adjoin mapping1 'c 4 'd 4 'd 5))
       (mapping0 (mapping default-comparator)))
  (check 'adjoin-existing (mapping-ref mapping5 'c) 3)
  (check 'adjoin-first-new-duplicate (mapping-ref mapping5 'd) 4)
  (check 'adjoin!-alias
         (mapping->alist (mapping-adjoin! mapping1 'c 4 'd 4))
         '((a . 1) (b . 2) (c . 3) (d . 4)))
  (check 'set-existing (mapping-ref mapping2 'c) 4)
  (check 'set-latest-new-duplicate (mapping-ref mapping2 'd) 5)
  (check 'set!-alias
         (mapping->alist (mapping-set! mapping1 'c 4 'd 4))
         '((a . 1) (b . 2) (c . 4) (d . 4)))
  (check 'replace-missing
         (mapping-ref/default (mapping-replace mapping1 'd 4) 'd #f)
         #f)
  (check 'replace-present (mapping-ref (mapping-replace mapping1 'c 6) 'c) 6)
  (check 'replace!-alias
         (mapping->alist (mapping-replace! mapping1 'c 6))
         '((a . 1) (b . 2) (c . 6)))
  (check 'delete (mapping-ref/default (mapping-delete mapping1 'b) 'b 42) 42)
  (check 'delete!-alias
         (mapping->alist (mapping-delete! mapping1 'a 'c))
         '((b . 2)))
  (check 'delete-all
         (mapping-ref/default (mapping-delete-all mapping1 '(a b)) 'b 42)
         42)
  (check 'delete-all!-alias
         (mapping->alist (mapping-delete-all! mapping1 '(a b)))
         '((c . 3)))
  (check 'intern-present
         (values-list
          (lambda ()
            (mapping-intern
             mapping1
             'b
             (lambda () (error "should not have been invoked")))))
         (list mapping1 2))
  (check 'intern-missing
         (call-with-values
          (lambda () (mapping-intern mapping1 'd (lambda () 42)))
          (lambda (mapping value)
            (list value (mapping-ref mapping 'd))))
         '(42 42))
  (check 'intern!-alias
         (call-with-values
          (lambda () (mapping-intern! mapping1 'd (lambda () 42)))
          (lambda (mapping value)
            (list value (mapping-ref mapping 'd))))
         '(42 42))
  (check 'update (mapping-ref mapping3 'b) 4)
  (check 'update-missing-with-failure
         (mapping-ref (mapping-update mapping1 'd
                                      (lambda (value) (* value value))
                                      (lambda () 4))
                      'd)
         16)
  (check 'update-missing-without-failure-raises
         (raises? (lambda () (mapping-update mapping1 'd (lambda (value) value))))
         #t)
  (check 'update!-alias
         (mapping-ref (mapping-update! mapping1 'b (lambda (value) (+ value 1)))
                      'b)
         3)
  (check 'update/default (mapping-ref mapping4 'd) 16)
  (check 'update!/default-alias
         (mapping-ref (mapping-update!/default
                       mapping1 'd (lambda (value) (* value value)) 4)
                      'd)
         16)
  (check 'pop-empty-with-failure
         (mapping-pop mapping0 (lambda () 'empty))
         'empty)
  (check-true 'pop-empty-raises
              (raises? (lambda ()
                         (call-with-values
                          (lambda () (mapping-pop mapping0))
                          list))))
  (check 'pop-non-empty
         (call-with-values
          (lambda () (mapping-pop mapping1))
          (lambda (mapping key value)
            (list (mapping-size mapping) key value)))
         '(2 a 1))
  (check 'pop!-alias
         (call-with-values
          (lambda () (mapping-pop! mapping1))
          (lambda (mapping key value)
            (list (mapping-size mapping) key value)))
         '(2 a 1))
  (check 'search-update-and-ignore
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
             (list v2 v3 (mapping->alist m3))))
         '("success updated"
           "failure ignored"
           ((0 . "zero") (1 . "one") (2 . "two [seen]") (3 . "three")
            (4 . "four") (5 . "five"))))
  (check 'search-insert-and-remove
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
           (list inserted removed))
         '((inserted ((a . 1) (b . 2) (c . 3) (d . 4)))
           (removed ((a . 1) (c . 3))))))

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
  (check 'mapping-unfold (mapping->alist unfolded) '((1 . 1) (2 . 4) (3 . 9)))
  (check 'mapping/ordered (mapping->alist ordered)
         '((1 . one) (2 . two) (3 . three)))
  (check 'mapping-unfold/ordered
         (mapping->alist unfolded/ordered)
         '((1 . 1) (2 . 4) (3 . 9)))
  (check-true 'constructor-odd-arguments-raises
              (raises? (lambda () (mapping integer-comparator 1)))))

(let ((mapping0 (mapping default-comparator))
      (mapping1 (mapping default-comparator 'a 1 'b 2 'c 3)))
  (check 'size-empty (mapping-size mapping0) 0)
  (check 'size-non-empty (mapping-size mapping1) 3)
  (check 'find-present
         (values-list
          (lambda ()
            (mapping-find (lambda (key value)
                            (and (eq? key 'b) (= value 2)))
                          mapping1
                          (lambda () (error "should not have been invoked")))))
         '(b 2))
  (check 'find-missing
         (values-list
          (lambda ()
            (mapping-find (lambda (key value) (eq? key 'd))
                          mapping1
                          (lambda () 42))))
         '(42))
  (check 'count (mapping-count (lambda (key value) (>= value 2)) mapping1) 2)
  (check-true 'any-present
              (mapping-any? (lambda (key value) (= value 3)) mapping1))
  (check-false 'any-missing
               (mapping-any? (lambda (key value) (= value 4)) mapping1))
  (check-true 'every-true
              (mapping-every? (lambda (key value) (<= value 3)) mapping1))
  (check-false 'every-false
               (mapping-every? (lambda (key value) (<= value 2)) mapping1))
  (check 'keys (mapping-keys mapping1) '(a b c))
  (check 'values (mapping-values mapping1) '(1 2 3))
  (check 'entries
         (call-with-values
          (lambda () (mapping-entries mapping1))
          (lambda (keys values)
            (list keys values)))
         '((a b c) (1 2 3))))

(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (mapping-map (lambda (key value)
                                (values (symbol->string key) (* 10 value)))
                              default-comparator
                              mapping1)))
  (check 'map (mapping-ref mapping2 "b") 20)
  (check 'for-each
         (let ((counter 0))
           (mapping-for-each (lambda (key value)
                               (set! counter (+ counter value)))
                             mapping1)
           counter)
         6)
  (check 'fold
         (mapping-fold (lambda (key value total)
                         (+ value total))
                       0
                       mapping1)
         6)
  (check 'map->list
         (sum (mapping-map->list (lambda (key value) (* value value))
                                 mapping1))
         14)
  (check 'filter
         (mapping->alist (mapping-filter (lambda (key value) (<= value 2))
                                         mapping1))
         '((a . 1) (b . 2)))
  (check 'filter!-alias
         (mapping->alist (mapping-filter! (lambda (key value) (<= value 2))
                                          mapping1))
         '((a . 1) (b . 2)))
  (check 'remove
         (mapping->alist (mapping-remove (lambda (key value) (<= value 2))
                                         mapping1))
         '((c . 3)))
  (check 'remove!-alias
         (mapping->alist (mapping-remove! (lambda (key value) (<= value 2))
                                          mapping1))
         '((c . 3)))
  (check 'partition
         (call-with-values
          (lambda () (mapping-partition (lambda (key value) (eq? key 'b))
                                        mapping1))
          (lambda (matching removed)
            (list (mapping->alist matching) (mapping->alist removed))))
         '(((b . 2)) ((a . 1) (c . 3))))
  (check 'partition!-alias
         (call-with-values
          (lambda () (mapping-partition! (lambda (key value) (eq? key 'b))
                                         mapping1))
          (lambda (matching removed)
            (list (mapping->alist matching) (mapping->alist removed))))
         '(((b . 2)) ((a . 1) (c . 3)))))

(let* ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
       (mapping2 (alist->mapping default-comparator
                                 '((a . 1) (b . 2) (c . 3))))
       (mapping3 (alist->mapping! (mapping-copy mapping1)
                                  '((d . 4) (c . 5)))))
  (check 'copy-size (mapping-size (mapping-copy mapping1)) 3)
  (check 'copy-comparator
         (mapping-key-comparator (mapping-copy mapping1))
         default-comparator)
  (check 'mapping->alist (assq 'b (mapping->alist mapping1)) '(b . 2))
  (check 'alist->mapping (mapping-ref mapping2 'b) 2)
  (check 'alist->mapping!new (mapping-ref mapping3 'd) 4)
  (check 'alist->mapping!existing (mapping-ref mapping3 'c) 5)
  (check 'alist->mapping/ordered
         (mapping->alist (alist->mapping/ordered integer-comparator
                                                 '((2 . two) (1 . one))))
         '((1 . one) (2 . two)))
  (check 'alist->mapping/ordered!
         (mapping->alist
          (alist->mapping/ordered! (mapping integer-comparator 2 'two)
                                   '((1 . one) (2 . TWO))))
         '((1 . one) (2 . TWO))))

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
  (check-true 'mapping=?-equal
              (mapping=? default-comparator mapping1 mapping2))
  (check-false 'mapping=?-unequal
               (mapping=? default-comparator mapping1 mapping4))
  (check-false 'mapping=?-different-key-comparators
               (mapping=? default-comparator mapping1 mapping6))
  (check-true 'mapping<?-proper-subset
              (mapping<? default-comparator mapping3 mapping1))
  (check-false 'mapping<?-improper-subset
               (mapping<? default-comparator mapping3 mapping1 mapping2))
  (check-false 'mapping<?-overlap-not-subset
               (mapping<? default-comparator
                          (mapping default-comparator 'a 1 'd 4)
                          mapping1))
  (check-true 'mapping>?-proper-superset
              (mapping>? default-comparator mapping2 mapping3))
  (check-false 'mapping>?-improper-superset
               (mapping>? default-comparator mapping1 mapping2 mapping3))
  (check-false 'mapping>?-overlap-not-superset
               (mapping>? default-comparator
                          mapping1
                          (mapping default-comparator 'a 1 'd 4)))
  (check-true 'mapping<=?-subset
              (mapping<=? default-comparator mapping3 mapping2 mapping1))
  (check-false 'mapping<=?-non-matching-values
               (mapping<=? default-comparator mapping3 mapping5))
  (check-false 'mapping<=?-not-subset
               (mapping<=? default-comparator mapping2 mapping4))
  (check-true 'mapping>=?-superset
              (mapping>=? default-comparator mapping4 mapping3))
  (check-false 'mapping>=?-not-superset
               (mapping>=? default-comparator mapping5 mapping3))
  (check-false 'mapping>=?-overlap-not-superset
               (mapping>=? default-comparator
                           mapping1
                           (mapping default-comparator 'a 1 'd 4))))

(let ((mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'a 1 'b 2 'd 4))
      (mapping4 (mapping default-comparator 'a 1 'b 2 'c 4))
      (mapping5 (mapping default-comparator 'a 1 'c 3))
      (mapping6 (mapping default-comparator 'd 4 'e 5 'f 6)))
  (check 'union-new
         (mapping-ref (mapping-union mapping1 mapping2) 'd)
         4)
  (check 'union-existing
         (mapping-ref (mapping-union mapping1 mapping4) 'c)
         3)
  (check 'union-three
         (mapping-size (mapping-union mapping1 mapping2 mapping6))
         6)
  (check 'union!-alias
         (mapping-size (mapping-union! mapping1 mapping2 mapping6))
         6)
  (check 'intersection-existing
         (mapping-ref (mapping-intersection mapping1 mapping4) 'c)
         3)
  (check 'intersection-removed
         (mapping-ref/default (mapping-intersection mapping1 mapping5) 'b 42)
         42)
  (check 'intersection!-alias
         (mapping->alist (mapping-intersection! mapping1 mapping5))
         '((a . 1) (c . 3)))
  (check 'difference
         (mapping-size (mapping-difference mapping2 mapping6))
         2)
  (check 'difference!-alias
         (mapping->alist (mapping-difference! mapping2 mapping6))
         '((a . 1) (b . 2)))
  (check 'xor
         (mapping-size (mapping-xor mapping2 mapping6))
         4)
  (check 'xor!-alias
         (mapping->alist (mapping-xor! mapping2 mapping6))
         '((a . 1) (b . 2) (e . 5) (f . 6))))

(let ((mapping0 (mapping default-comparator))
      (mapping1 (mapping default-comparator 'a 1 'b 2 'c 3))
      (mapping2 (mapping default-comparator 'a 1 'b 2 'c 3 'd 4))
      (mapping3 (mapping default-comparator 'a 1 'b 2 'c 3 'd 4 'e 5))
      (mapping4 (mapping default-comparator
                         'a 1 'b 2 'c 3 'd 4 'e 5 'f 6))
      (mapping5 (mapping default-comparator 'f 6 'g 7 'h 8)))
  (check 'min-key (map mapping-min-key (list mapping1 mapping2 mapping3 mapping4))
         '(a a a a))
  (check 'max-key (map mapping-max-key (list mapping1 mapping2 mapping3 mapping4))
         '(c d e f))
  (check 'min-value
         (map mapping-min-value (list mapping1 mapping2 mapping3 mapping4))
         '(1 1 1 1))
  (check 'max-value
         (map mapping-max-value (list mapping1 mapping2 mapping3 mapping4))
         '(3 4 5 6))
  (check-true 'min-key-empty-raises
              (raises? (lambda () (mapping-min-key mapping0))))
  (check-true 'max-key-empty-raises
              (raises? (lambda () (mapping-max-key mapping0))))
  (check-true 'min-value-empty-raises
              (raises? (lambda () (mapping-min-value mapping0))))
  (check-true 'max-value-empty-raises
              (raises? (lambda () (mapping-max-value mapping0))))
  (check 'key-predecessor
         (map (lambda (mapping)
                (mapping-key-predecessor mapping 'e (lambda () #f)))
              (list mapping1 mapping2 mapping3 mapping4))
         '(c d d d))
  (check 'key-successor
         (map (lambda (mapping)
                (mapping-key-successor mapping 'd (lambda () #f)))
              (list mapping1 mapping2 mapping3 mapping4))
         '(#f #f e e))
  (check 'key-predecessor-edge
         (mapping-key-predecessor mapping4 'a (lambda () 'none))
         'none)
  (check 'key-successor-edge
         (mapping-key-successor mapping4 'f (lambda () 'none))
         'none)
  (check 'range=present (mapping-values (mapping-range= mapping4 'd)) '(4))
  (check 'range=absent (mapping-values (mapping-range= mapping4 'z)) '())
  (check 'range< (mapping-values (mapping-range< mapping4 'd)) '(1 2 3))
  (check 'range<= (mapping-values (mapping-range<= mapping4 'd)) '(1 2 3 4))
  (check 'range> (mapping-values (mapping-range> mapping4 'd)) '(5 6))
  (check 'range>= (mapping-values (mapping-range>= mapping4 'd)) '(4 5 6))
  (check 'range=! (mapping-values (mapping-range=! mapping4 'd)) '(4))
  (check 'range<! (mapping-values (mapping-range<! mapping4 'd)) '(1 2 3))
  (check 'range<=! (mapping-values (mapping-range<=! mapping4 'd)) '(1 2 3 4))
  (check 'range>! (mapping-values (mapping-range>! mapping4 'd)) '(5 6))
  (check 'range>=! (mapping-values (mapping-range>=! mapping4 'd)) '(4 5 6))
  (check 'split
         (call-with-values
          (lambda () (mapping-split mapping4 'd))
          (lambda mappings
            (mapping-values-list mappings)))
         '((1 2 3) (1 2 3 4) (4) (4 5 6) (5 6)))
  (check 'split-absent
         (call-with-values
          (lambda () (mapping-split mapping4 'z))
          (lambda mappings
            (mapping-values-list mappings)))
         '((1 2 3 4 5 6) (1 2 3 4 5 6) () () ()))
  (check 'catenate
         (mapping->alist
          (mapping-catenate default-comparator mapping2 'e 5 mapping5))
         '((a . 1) (b . 2) (c . 3) (d . 4)
           (e . 5) (f . 6) (g . 7) (h . 8)))
  (check 'catenate!-alias
         (mapping->alist
          (mapping-catenate! default-comparator mapping2 'e 5 mapping5))
         '((a . 1) (b . 2) (c . 3) (d . 4)
           (e . 5) (f . 6) (g . 7) (h . 8)))
  (check 'map/monotone
         (mapping->alist
          (mapping-map/monotone (lambda (key value)
                                  (values value (* value value)))
                                default-comparator
                                mapping1))
         '((1 . 1) (2 . 4) (3 . 9)))
  (check 'map/monotone!-alias
         (mapping->alist
          (mapping-map/monotone! (lambda (key value)
                                   (values value (* value value)))
                                 default-comparator
                                 mapping1))
         '((1 . 1) (2 . 4) (3 . 9)))
  (check 'fold/reverse
         (mapping-fold/reverse (lambda (key value values)
                                 (cons value values))
                               '()
                               mapping1)
         '(1 2 3)))

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
  (check-true 'mapping-comparator-predicate
              (comparator? mapping-comparator))
  (check-true 'make-mapping-comparator-predicate
              (comparator? custom-mapping-comparator))
  (check 'mapping-keyed-mapping
         (list (mapping-ref mapping0 mapping1)
               (mapping-ref mapping0 mapping2)
               (mapping-ref mapping0 mapping3)
               (mapping-ref mapping0 mapping4)
               (mapping-ref mapping0 mapping5))
         '("a" "a" "c" "d" "e"))
  (check-true 'comparator-equal
              (=? custom-mapping-comparator mapping1 mapping2))
  (check-false 'comparator-unequal
               (=? custom-mapping-comparator mapping1 mapping4))
  (check-true 'comparator-less-subset
              (<? custom-mapping-comparator mapping3 mapping4))
  (check-true 'comparator-less-value-order
              (<? custom-mapping-comparator mapping1 mapping4))
  (check-true 'comparator-less-key-order
              (<? custom-mapping-comparator mapping1 mapping5)))

(let* ((mapping1 (mapping integer-comparator 3 'three 1 'one 2 'two 2 'TWO))
       (mapping2 (mapping-set mapping1 4 'four 2 'TWO))
       (without-one (mapping-delete mapping2 1)))
  (check 'constructor-preserves-earlier-duplicate
         (list (mapping? mapping1)
               (mapping-size mapping1)
               (mapping-ref mapping1 2))
         '(#t 3 two))
  (check 'alist-conversion-is-ordered
         (mapping->alist mapping2)
         '((1 . one) (2 . TWO) (3 . three) (4 . four)))
  (check 'keys-and-values-follow-key-order
         (call-with-values
          (lambda () (mapping-entries mapping2))
          (lambda (keys values)
            (list keys values)))
         '((1 2 3 4) (one TWO three four)))
  (check 'range-and-boundary-operations
         (list (mapping-min-key mapping2)
               (mapping-max-key mapping2)
               (mapping-key-predecessor mapping2 3 (lambda () 'none))
               (mapping-key-successor mapping2 3 (lambda () 'none))
               (mapping->alist (mapping-range>= mapping2 3)))
         '(1 4 2 4 ((3 . three) (4 . four))))
  (check 'set-operations-and-delete
         (let ((overlap (mapping integer-comparator 2 'TWO 4 'four 9 'nine)))
           (list (mapping-ref/default without-one 1 'missing)
                 (mapping->alist (mapping-intersection mapping2 overlap))
                 (mapping->alist (mapping-difference mapping2 overlap))))
         '(missing ((2 . TWO) (4 . four)) ((1 . one) (3 . three)))))

(finish-mapping-tests)
