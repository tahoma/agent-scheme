;;; Portable SRFI 1 list stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 1998 Olin Shivers
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from representative SRFI 1 examples and the portable reference
;;; implementation at
;;; https://github.com/scheme-requests-for-implementation/srfi-1.

(import (scheme base)
        (scheme write)
        (stdlib list))

;; Number of failed adapted SRFI checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed list-library check."
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

(define (check-values name thunk expected)
  "Compare values returned by THUNK to EXPECTED."
  (check name (call-with-values thunk list) expected))

(define (finish-list-tests)
  "Report the adapted SRFI 1 test result."
  (if (= failures 0)
      (begin
        (display "Adapted SRFI 1 list tests passed")
        (newline))
      (begin
        (display failures)
        (display " adapted SRFI 1 list test failure(s)")
        (newline)
        (error "adapted SRFI 1 list tests failed" failures))))

(check 'constructors
       (list (iota 5)
             (iota 4 10 2)
             (make-list 3 'x)
             (list-tabulate 4 (lambda (n) (* n n)))
             (cons* 'a 'b 'c))
       '((0 1 2 3 4)
         (10 12 14 16)
         (x x x)
         (0 1 4 9)
         (a b . c)))

(check 'predicates
       (list (proper-list? '(a b c))
             (dotted-list? '(a b . c))
             (not-pair? 'atom)
             (null-list? '())
             (list= = '(1 2) '(1 2) '(1 2)))
       '(#t #t #t #t #t))

(check-values 'car+cdr
              (lambda () (car+cdr '(head tail rest)))
              '(head (tail rest)))

(check 'slices
       (list (take '(a b c d) 2)
             (drop '(a b c d) 2)
             (take-right '(a b c d) 2)
             (drop-right '(a b c d) 2)
             (last '(a b c))
             (last-pair '(a b c)))
       '((a b) (c d) (c d) (a b) c (c)))

(check-values 'split-at
              (lambda () (split-at '(a b c d) 2))
              '((a b) (c d)))

(check 'folds-and-maps
       (list (fold + 0 '(1 2 3 4))
             (fold-right cons '() '(a b c))
             (count even? '(1 2 3 4 5))
             (map + '(1 2 3) '(10 20 30))
             (append-map (lambda (x) (list x (- x))) '(1 2 3))
             (filter-map (lambda (x) (and (even? x) (* x x)))
                         '(1 2 3 4)))
       '(10 (a b c) 2 (11 22 33) (1 -1 2 -2 3 -3) (4 16)))

(check-values 'partition
              (lambda () (partition even? '(1 2 3 4 5)))
              '((2 4) (1 3 5)))

(check 'search
       (list (find even? '(1 3 4 6))
             (find-tail even? '(1 3 4 6))
             (any even? '(1 3 5 6))
             (every positive? '(1 2 3))
             (list-index even? '(1 3 4 6))
             (find-tail (lambda (name) (string=? name "bee"))
                        '("ant" "bee")))
       '(4 (4 6) #t #t 2 ("bee")))

(check 'alist
       (let ((alist (alist-cons 'c 3 '((a . 1) (b . 2)))))
         (list (assoc 'b alist)
               (alist-delete 'a alist)
               (alist-copy alist)))
       '((b . 2) ((c . 3) (b . 2)) ((c . 3) (a . 1) (b . 2))))

(check 'list-as-sets
       (list (lset<= = '(1 2) '(2 1 3))
             (lset= = '(1 2 2) '(2 1))
             (lset-adjoin = '(1 2) 2 3)
             (lset-union = '(1 2) '(2 3 4))
             (lset-intersection = '(1 2 3) '(2 3 4))
             (lset-difference = '(1 2 3 4) '(2 4))
             (lset-xor = '(1 2 3) '(2 3 4)))
       '(#t #t (3 1 2) (4 3 1 2) (2 3) (1 3) (4 1)))

(finish-list-tests)
