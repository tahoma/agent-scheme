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

(define (raises? thunk)
  "Return #t when THUNK raises an exception."
  (guard (condition
          (else #t))
    (thunk)
    #f))

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

(check 'constructors-and-copy
       (let* ((tree (list (cons 'a 'b) (list 'c)))
              (copy (tree-copy tree)))
         (list (xcons '(tail) 'head)
               (iota 5)
               (iota 4 10 2)
               (list-tabulate 4 (lambda (n) (* n n)))
               (cons* 'a 'b 'c)
               (equal? copy tree)
               (not (eq? copy tree))
               (not (eq? (car copy) (car tree)))
               (not (eq? (cadr copy) (cadr tree)))))
       '((head tail)
         (0 1 2 3 4)
         (10 12 14 16)
         (0 1 4 9)
         (a b . c)
         #t #t #t #t))

(check 'predicates-and-circular-lists
       (let ((two-cycle (circular-list 'a 'b))
             (one-cycle (circular-list 'solo)))
         (list (proper-list? '(a b c))
               (proper-list? '(a b . c))
               (proper-list? two-cycle)
               (dotted-list? '(a b . c))
               (dotted-list? two-cycle)
               (circular-list? two-cycle)
               (circular-list? '(a b c))
               (not-pair? 'atom)
               (null-list? '())
               (list= = '(1 2) '(1 2) '(1 2))
               (length+ '(a b c))
               (length+ two-cycle)
               (eq? (cddr two-cycle) two-cycle)
               (eq? (cdr one-cycle) one-cycle)))
       '(#t #f #f #t #f #t #f #t #t #t 3 #f #t #t))

(check 'selectors
       (let ((values '(one two three four five six seven eight nine ten)))
         (list (first values)
               (second values)
               (third values)
               (fourth values)
               (fifth values)
               (sixth values)
               (seventh values)
               (eighth values)
               (ninth values)
               (tenth values)))
       '(one two three four five six seven eight nine ten))

(check-values 'car+cdr
              (lambda () (car+cdr '(head tail rest)))
              '(head (tail rest)))

(check 'slices
       (let ((source (list 'a 'b 'c 'd)))
         (list (take source 2)
               (drop source 2)
               (take-right source 2)
               (drop-right source 2)
               (eq? (take-right source 2) (cddr source))
               (last source)
               (last-pair source)))
       '((a b) (c d) (c d) (a b) #t d (d)))

(check-values 'split-at
              (lambda () (split-at '(a b c d) 2))
              '((a b) (c d)))

(check 'destructive-slices
       (let* ((take-source (list 'a 'b 'c 'd))
              (take-result (take! take-source 2))
              (drop-source (list 'a 'b 'c 'd))
              (drop-result (drop-right! drop-source 2))
              (split-source (list 'a 'b 'c 'd))
              (split-tail (cddr split-source)))
         (call-with-values
          (lambda () (split-at! split-source 2))
          (lambda (split-prefix split-suffix)
            (list take-result
                  (eq? take-result take-source)
                  take-source
                  drop-result
                  (eq? drop-result drop-source)
                  drop-source
                  split-prefix
                  split-suffix
                  (eq? split-prefix split-source)
                  (eq? split-suffix split-tail)))))
       '((a b) #t (a b) (a b) #t (a b) (a b) (c d) #t #t))

(check 'append-and-reverse
       (let* ((append-left (list 'a 'b))
              (append-right (list 'c 'd))
              (append-result (append! append-left append-right))
              (concat-left (list 'p))
              (concat-right (list 'q 'r))
              (concat-result (concatenate! (list concat-left concat-right)))
              (reverse-source (list 'one 'two 'three))
              (reverse-result (reverse! reverse-source))
              (append-reverse-source (list 'x 'y))
              (append-reverse-result
               (append-reverse! append-reverse-source '(z))))
         (list append-result
               (eq? append-result append-left)
               (eq? (cddr append-result) append-right)
               (concatenate '((1 2) (3) (4 5)))
               concat-result
               (eq? concat-result concat-left)
               reverse-result
               (eq? (last-pair reverse-result) reverse-source)
               (append-reverse '(a b c) '(tail))
               append-reverse-result
               (eq? (cdr append-reverse-result) append-reverse-source)))
       '((a b c d) #t #t (1 2 3 4 5) (p q r) #t
         (three two one) #t (c b a tail) (y x z) #t))

(check 'zip-and-unzip
       (list (zip '(a b c) '(1 2 3) '(x y z))
             (unzip1 '((a 1) (b 2) (c 3)))
             (call-with-values
              (lambda () (unzip2 '((a 1) (b 2) (c 3))))
              list)
             (call-with-values
              (lambda () (unzip3 '((a 1 x) (b 2 y))))
              list)
             (call-with-values
              (lambda () (unzip4 '((a 1 x red) (b 2 y blue))))
              list)
             (call-with-values
              (lambda () (unzip5 '((a 1 x red left) (b 2 y blue right))))
              list))
       '(((a 1 x) (b 2 y) (c 3 z))
         (a b c)
         ((a b c) (1 2 3))
         ((a b) (1 2) (x y))
         ((a b) (1 2) (x y) (red blue))
         ((a b) (1 2) (x y) (red blue) (left right))))

(check 'folds-reduces-and-unfolds
       (list (fold + 0 '(1 2 3 4))
             (fold (lambda (left right acc)
                     (cons (+ left right) acc))
                   '()
                   '(1 2 3)
                   '(10 20 30))
             (fold-right cons '() '(a b c))
             (pair-fold (lambda (tail acc) (cons tail acc))
                        '()
                        '(a b c))
             (pair-fold-right (lambda (tail acc) (cons (car tail) acc))
                              '()
                              '(a b c))
             (reduce + 42 '())
             (reduce + 0 '(1 2 3 4))
             (reduce-right list 'unused '(a b c))
             (count even? '(1 2 3 4 5))
             (count < '(1 4 3) '(2 3 5))
             (unfold (lambda (n) (> n 3))
                     (lambda (n) n)
                     (lambda (n) (+ n 1))
                     0)
             (unfold (lambda (n) (= n 3))
                     (lambda (n) n)
                     (lambda (n) (+ n 1))
                     0
                     (lambda (n) (list 'stop n)))
             (unfold-right (lambda (n) (> n 3))
                           (lambda (n) n)
                           (lambda (n) (+ n 1))
                           0
                           '(done)))
       '(10 (33 22 11) (a b c)
            ((c) (b c) (a b c))
            (a b c)
            42
            10
            (a (b c))
            2
            2
            (0 1 2 3)
            (0 1 2 stop 3)
            (3 2 1 0 done)))

(check 'maps-and-filters
       (let* ((map-source (list 1 2 3))
              (map-result (map! (lambda (value) (* value 10))
                                map-source))
              (pair-tails '())
              (order-seen '()))
         (pair-for-each (lambda (tail)
                          (set! pair-tails (cons tail pair-tails)))
                        '(a b c))
         (list (append-map (lambda (x) (list x (- x))) '(1 2 3))
               (append-map! (lambda (x) (list x (* x x))) '(1 2 3))
               map-result
               (eq? map-result map-source)
               map-source
               (reverse pair-tails)
               (filter-map (lambda (x) (and (even? x) (* x x)))
                           '(1 2 3 4))
               (map-in-order (lambda (x)
                               (set! order-seen (cons x order-seen))
                               (* x 2))
                             '(1 2 3))
               (reverse order-seen)
               (filter even? '(1 2 3 4))
               (remove even? '(1 2 3 4))
               (filter! odd? '(1 2 3 4))
               (remove! odd? '(1 2 3 4))
               (call-with-values
                (lambda () (partition! even? '(1 2 3 4 5)))
                list)))
       '((1 -1 2 -2 3 -3)
         (1 1 2 4 3 9)
         (10 20 30)
         #t
         (10 20 30)
         ((a b c) (b c) (c))
         (4 16)
         (2 4 6)
         (1 2 3)
         (2 4)
         (1 3)
         (1 3)
         (2 4)
         ((2 4) (1 3 5))))

(check-values 'partition
              (lambda () (partition even? '(1 2 3 4 5)))
              '((2 4) (1 3 5)))

(check 'search
       (list (find even? '(1 3 4 6))
             (find-tail even? '(1 3 4 6))
             (take-while odd? '(1 3 4 5))
             (drop-while odd? '(1 3 4 5))
             (take-while! odd? (list 1 3 4 5))
             (call-with-values
              (lambda () (span odd? '(1 3 4 5)))
              list)
             (call-with-values
              (lambda () (break even? '(1 3 4 5)))
              list)
             (call-with-values
              (lambda () (span! odd? (list 1 3 4 5)))
              list)
             (call-with-values
              (lambda () (break! even? (list 1 3 4 5)))
              list)
             (any (lambda (value) (and (even? value) (* value 10)))
                  '(1 3 5 6))
             (every (lambda (value) (and (positive? value) value))
                    '(1 2 3))
             (list-index even? '(1 3 4 6))
             (find-tail (lambda (name) (string=? name "bee"))
                        '("ant" "bee")))
       '(4 (4 6) (1 3) (4 5) (1 3)
           ((1 3) (4 5))
           ((1 3) (4 5))
           ((1 3) (4 5))
           ((1 3) (4 5))
           60
           3
           2
           ("bee")))

(check 'delete-and-alist
       (let ((alist (alist-cons 'c 3 '((a . 1) (b . 2)))))
         (list (delete 2 '(1 2 3 2 4))
               (delete! 2 '(1 2 3 2 4))
               (delete 5 '(1 2 5 8)
                       (lambda (left right)
                         (= (modulo left 3) (modulo right 3))))
               (delete-duplicates '(a b a c b d))
               (delete-duplicates! '(a b a c b d))
               (alist-delete 'a alist)
               (alist-delete! 'a alist)
               (alist-copy alist)))
       '((1 3 4)
         (1 3 4)
         (1)
         (a b c d)
         (a b c d)
         ((c . 3) (b . 2))
         ((c . 3) (b . 2))
         ((c . 3) (a . 1) (b . 2))))

(check 'list-as-sets
       (list (lset<= = '(1 2) '(2 1 3))
             (lset= = '(1 2 2) '(2 1))
             (lset-adjoin = '(1 2) 2 3)
             (lset-union = '(1 2) '(2 3 4))
             (lset-intersection = '(1 2 3) '(2 3 4))
             (lset-difference = '(1 2 3 4) '(2 4))
             (lset-xor = '(1 2 3) '(2 3 4))
             (call-with-values
              (lambda () (lset-diff+intersection = '(1 2 3 4) '(2 4 6)))
              list)
             (lset-union! = '(1 2) '(2 3 4))
             (lset-intersection! = '(1 2 3) '(2 3 4))
             (lset-difference! = '(1 2 3 4) '(2 4))
             (lset-xor! = '(1 2 3) '(2 3 4))
             (call-with-values
              (lambda () (lset-diff+intersection! = '(1 2 3 4) '(2 4 6)))
              list)
             (lset-union =)
             (lset-intersection = '(1 2 3)))
       '(#t #t (3 1 2) (4 3 1 2) (2 3) (1 3) (4 1)
            ((1 3) (2 4))
            (4 3 1 2)
            (2 3)
            (1 3)
            (4 1)
            ((1 3) (2 4))
            ()
            (1 2 3)))

(check 'error-cases
       (list (raises? (lambda () (iota -1)))
             (raises? (lambda () (iota 3 0 1 2)))
             (raises? (lambda () (list-tabulate 3 'not-a-procedure)))
             (raises? (lambda () (take '(a b) -1)))
             (raises? (lambda () (drop '(a b) -1)))
             (raises? (lambda () (null-list? 'atom)))
             (raises? (lambda () (list= 'not-a-procedure '(1) '(1))))
             (raises? (lambda () (count 'not-a-procedure '(1))))
             (raises? (lambda ()
                        (unfold (lambda (x) x)
                                (lambda (x) x)
                                (lambda (x) x)
                                #t
                                (lambda (x) x)
                                (lambda (x) x)))))
       '(#t #t #t #t #t #t #t #t #t))

(finish-list-tests)
