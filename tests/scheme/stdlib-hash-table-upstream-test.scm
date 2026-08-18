;;; Adapted upstream SRFI 125 hash-table tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2015 William D Clinger <will@ccs.neu.edu>
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from `tables-test.sps` at upstream revision
;;; d80d0e954480983b3e60c40041f3d0bec366e0ba.  The original test file is MIT.

(import (scheme base)
        (scheme process-context)
        (stdlib comparator)
        (except (stdlib hash-table) string-hash string-ci-hash)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Upstream numeric comparator adapted to Consent's SRFI 128 surface.
(define number-comparator
  (make-comparator number? = < number-hash))

;; Upstream identity comparator used by destructive set-operation cases.
(define eq-comparator (make-eq-comparator))

;; Upstream value comparator used by table-equality cases.
(define default-comparator (make-default-comparator))

(testing-registry-case
 'hash-table-upstream/construction '(portable stdlib upstream)
 (let ((table (hash-table number-comparator 1 1 4 2 9 3 16 4)))
   (test-equal 'hash-table-upstream/construction-values
               '(1 2 3 4)
               (map (lambda (key) (hash-table-ref table key))
                    '(1 4 9 16)))
   (test-assert 'hash-table-upstream/construction-immutable
                (not (hash-table-mutable? table)))))

(testing-registry-case
 'hash-table-upstream/update-and-pop '(portable stdlib upstream)
 (let ((table
        (alist->hash-table
         '((0 . 0) (1 . 1) (4 . 2) (9 . 3) (16 . 4))
         number-comparator)))
   (hash-table-update! table 16 -)
   (hash-table-update!/default table 25 - 5)
   (test-equal 'hash-table-upstream/update-values
               '(0 1 2 3 -4 -5)
               (map (lambda (key) (hash-table-ref table key))
                    '(0 1 4 9 16 25)))
   (let ((size (hash-table-size table)))
     (call-with-values
      (lambda () (hash-table-pop! table))
      (lambda (key value)
        (test-assert 'hash-table-upstream/pop-removes
                     (and (= (- size 1) (hash-table-size table))
                          (not (hash-table-contains? table key)))))))))

(testing-registry-case
 'hash-table-upstream/whole-table '(portable stdlib upstream)
 (let ((table
        (hash-table-copy
         (hash-table number-comparator 1 1 4 2 9 3 16 4)
         #t)))
   (test-equal 'hash-table-upstream/find
               '(9 3)
               (hash-table-find
                (lambda (key value)
                  (and (= key 9) (list key value)))
                table
                (lambda () 'missing)))
   (test-equal 'hash-table-upstream/fold
               10
               (hash-table-fold
                (lambda (key value total) (+ value total)) 0 table))
   (test-equal 'hash-table-upstream/deprecated-fold-order
               10
               (hash-table-fold
                table (lambda (key value total) (+ value total)) 0))))

(testing-registry-case
 'hash-table-upstream/set-operations '(portable stdlib upstream)
 (let ((left (make-hash-table eq-comparator))
       (right (make-hash-table eq-comparator)))
   (hash-table-set! left 'foo 1 'bar 2)
   (hash-table-set! right 'bar 20 'baz 3)
   (let ((union (hash-table-copy left #t))
         (intersection (hash-table-copy left #t))
         (difference (hash-table-copy left #t))
         (xor (hash-table-copy left #t)))
     (hash-table-union! union right)
     (hash-table-intersection! intersection right)
     (hash-table-difference! difference right)
     (hash-table-xor! xor right)
     (test-equal 'hash-table-upstream/set-sizes
                 '(3 1 1 2)
                 (map hash-table-size
                      (list union intersection difference xor)))
     (test-equal 'hash-table-upstream/union-left-value
                 2
                 (hash-table-ref union 'bar)))))

(testing-registry-case
 'hash-table-upstream/copy-and-equality '(portable stdlib upstream)
 (let ((table (make-hash-table eq-comparator)))
   (hash-table-set! table 'foo 13 'bar 14 'baz 18)
   (let ((copy (hash-table-copy table #t))
         (empty (hash-table-empty-copy table)))
     (test-assert 'hash-table-upstream/copy-equal
                  (hash-table=? default-comparator table copy))
     (test-equal 'hash-table-upstream/empty-copy-size
                 0
                 (hash-table-size empty))
     (test-assert 'hash-table-upstream/empty-copy-mutable
                  (hash-table-mutable? empty)))))

(testing-runner-main "Adapted upstream SRFI 125 tests" (command-line))
