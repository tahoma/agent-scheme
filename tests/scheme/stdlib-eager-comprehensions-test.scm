;;; Portable SRFI 42 eager comprehensions stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2003, 2007 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 42 examples at
;;; <https://github.com/scheme-requests-for-implementation/srfi-42>,
;;; revision 6a4c4aeb4cb61c6514776144fdfc5fe0d738a548, examples.scm
;;; and extension examples at the same revision. The file keeps the compact
;;; host-neutral behavior checks in the full portable host matrix.

(import (scheme base)
        (scheme write)
        (stdlib eager-comprehensions))

;; Number of failed adapted SRFI checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed eager-comprehension check."
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

(define (finish-eager-comprehension-tests)
  "Report the adapted SRFI 42 test result."
  (if (= failures 0)
      (begin
        (display "Adapted SRFI 42 eager-comprehension tests passed")
        (newline))
      (begin
        (display failures)
        (display " adapted SRFI 42 eager-comprehension test failure(s)")
        (newline)
        (error "adapted SRFI 42 eager-comprehension tests failed" failures))))

(check 'do-ec-no-qualifier
       (let ((x 0))
         (do-ec (set! x (+ x 1)))
         x)
       1)

(check 'list-ec-range
       (list-ec (:range i 5) (* i i))
       '(0 1 4 9 16))

(check 'list-ec-nested-range
       (list-ec (:range n 1 4) (:range i n) (list n i))
       '((1 0) (2 0) (2 1) (3 0) (3 1) (3 2)))

(check 'qualifiers-filter
       (list-ec (:range n 5)
                (if (even? n))
                (:range k (+ n 1))
                (list n k))
       '((0 0) (2 0) (2 1) (2 2) (4 0) (4 1) (4 2) (4 3) (4 4)))

(check 'qualifiers-not-and-or
       (list (list-ec (:range n 5)
                      (not (even? n))
                      (:range k (+ n 1))
                      (list n k))
             (list-ec (:range n 5)
                      (and (even? n) (> n 2))
                      n)
             (list-ec (:range n 5)
                      (or (even? n) (> n 3))
                      n))
       '(((1 0) (1 1) (3 0) (3 1) (3 2) (3 3))
         (4)
         (0 2 4)))

(check 'qualifiers-begin-and-nested
       (list (let ((x 0))
               (list-ec (:range n 4) (begin (set! x (+ x 1))) n)
               x)
             (list-ec (nested (:range n 3) (:range k n)) k))
       '(4 (0 0 1)))

(check 'collectors
       (list (append-ec (:range i 2) '(a b))
             (string-ec (:range i 2) #\a)
             (string-append-ec (:range i 2) "ab")
             (vector-ec (:range i 3) i)
             (sum-ec (:range i 4) i)
             (product-ec (:range i 1 5) i)
             (min-ec (:range i 2) i)
             (max-ec (:range i 3) i))
       (list '(a b a b) "aa" "abab" (vector 0 1 2) 6 24 0 2))

(check 'first-last-any-every
       (list (first-ec #f (:range i 0) i)
             (first-ec #f (:range i 3) i)
             (last-ec #f (:range i 3) i)
             (any?-ec (:range i 2 3) (even? i))
             (every?-ec (:range i 2 4) (even? i)))
       '(#f 0 2 #t #f))

(check 'folds
       (let ((sum-sqr (lambda (x result) (+ result (* x x)))))
         (list (fold-ec 0 (:range i 10) i sum-sqr)
               (fold3-ec 'empty (:range i 0) i min min)))
       '(285 empty))

(check 'typed-generators
       (list (list-ec (:list x '(1) '(2) '(3)) x)
             (list-ec (:string c "1" "2") c)
             (list-ec (:vector x (vector 1) (vector 2)) x)
             (list-ec (:range x 6 1 -2) x)
             (string-ec (:char-range c #\a #\c) c))
       '((1 2 3) (#\1 #\2) (1 2) (6 4 2) "abc"))

(check 'port-generator
       (let ((input (open-input-string "0 1 2")))
         (list-ec (:port datum input) datum))
       '(0 1 2))

(check 'explicit-generators
       (list (list-ec (:do ((i 0)) (< i 4) ((+ i 1))) i)
             (list-ec (:let x 1) (:let y (+ x 1)) y)
             (list-ec (:parallel (:range i 1 10) (:list x '(a b c)))
                      (list i x)))
       '((0 1 2 3) (2) ((1 a) (2 b) (3 c))))

(check ':while-and-:until
       (list (list-ec (:while (:range i 1 10) (< i 5)) i)
             (list-ec (:until (:range i 1 10) (>= i 5)) i)
             (let ((n 0))
               (do-ec (:while (:range i 1 10)
                              (begin (set! n (+ n 1)) (< i 5)))
                      (if #f #f))
               n)
             (let ((n 0))
               (do-ec (:until (:range i 1 10)
                              (begin (set! n (+ n 1)) (>= i 5)))
                      (if #f #f))
               n))
       '((1 2 3 4) (1 2 3 4 5) 5 5))

(check ':while-inner-binding-regressions
       (list (list-ec (:while (:list i '(1 2 3 4 5 6 7 8 9))
                              (< i 5))
                      i)
             (list-ec (:while (:vector x (index i) '#(1 2 3 4 5))
                              (< x 10))
                      x)
             (list-ec (:while (:parallel (:range i 1 10)
                                         (:list j '(1 2 3 4 5 6 7 8 9)))
                              (< i 5))
                      (list i j)))
       '((1 2 3 4) (1 2 3 4 5) ((1 1) (2 2) (3 3) (4 4))))

(check 'dispatching-generator
       (list (list-ec (: c '(a b) '(c d)) c)
             (list-ec (: c "ab" "cd") c)
             (list-ec (: c (vector 'a 'b) (vector 'c)) c)
             (list-ec (: i 1 9 3) i)
             (list-ec (: c #\a #\c) c)
             (list-ec (: x (index i) '(a b c)) (list x i)))
       '((a b c d)
         (#\a #\b #\c #\d)
         (a b c)
         (1 4 7)
         (#\a #\b #\c)
         ((a 0) (b 1) (c 2))))

;; Example dispatcher from the SRFI extension notes.
(define (example-dispatch args)
  "Return the extension-note generator for symbol arguments."
  (cond
   ((null? args) 'example)
   ((and (= (length args) 1) (symbol? (car args)))
    (:generator-proc (:string (symbol->string (car args)))))
   (else #f)))

(check 'dispatch-extension-hook
       (let ((original-dispatch (:-dispatch-ref)))
         (dynamic-wind
           (lambda ()
             (:-dispatch-set! (dispatch-union original-dispatch
                                              example-dispatch)))
           (lambda ()
             (list-ec (: c 'abc) c))
           (lambda ()
             (:-dispatch-set! original-dispatch))))
       '(#\a #\b #\c))

;; Example typed generator from the SRFI extension notes.
(define-syntax :mygen
  (syntax-rules ()
    ((:mygen cc var arg)
     (:list cc var (reverse arg)))))

;; Example comprehension from the SRFI extension notes.
(define-syntax new-list-ec
  (syntax-rules ()
    ((new-list-ec etc1 etc ...)
     (reverse (fold-ec '() etc1 etc ... cons)))))

(check 'extension-macros
       (list (list-ec (:mygen x '(1 2 3)) x)
             (new-list-ec (: i 5) i))
       '((3 2 1) (0 1 2 3 4)))

(finish-eager-comprehension-tests)
