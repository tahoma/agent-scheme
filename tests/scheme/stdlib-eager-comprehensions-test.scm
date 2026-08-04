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
        (stdlib eager-comprehensions)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(testing-registry-case
 'do-ec-no-qualifier '(portable stdlib)
(test-equal 'do-ec-no-qualifier
             1
             (let ((x 0))
         (do-ec (set! x (+ x 1)))
         x)))

(testing-registry-case
 'list-ec-range '(portable stdlib)
(test-equal 'list-ec-range
             '(0 1 4 9 16)
             (list-ec (:range i 5) (* i i))))

(testing-registry-case
 'list-ec-nested-range '(portable stdlib)
(test-equal 'list-ec-nested-range
             '((1 0) (2 0) (2 1) (3 0) (3 1) (3 2))
             (list-ec (:range n 1 4) (:range i n) (list n i))))

(testing-registry-case
 'qualifiers-filter '(portable stdlib)
(test-equal 'qualifiers-filter
             '((0 0) (2 0) (2 1) (2 2) (4 0) (4 1) (4 2) (4 3) (4 4))
             (list-ec (:range n 5)
                (if (even? n))
                (:range k (+ n 1))
                (list n k))))

(testing-registry-case
 'qualifiers-not-and-or '(portable stdlib)
(test-equal 'qualifiers-not-and-or
             '(((1 0) (1 1) (3 0) (3 1) (3 2) (3 3))
         (4)
         (0 2 4))
             (list (list-ec (:range n 5)
                      (not (even? n))
                      (:range k (+ n 1))
                      (list n k))
             (list-ec (:range n 5)
                      (and (even? n) (> n 2))
                      n)
             (list-ec (:range n 5)
                      (or (even? n) (> n 3))
                      n))))

(testing-registry-case
 'qualifiers-begin-and-nested '(portable stdlib)
(test-equal 'qualifiers-begin-and-nested
             '(4 (0 0 1))
             (list (let ((x 0))
               (list-ec (:range n 4) (begin (set! x (+ x 1))) n)
               x)
             (list-ec (nested (:range n 3) (:range k n)) k))))

(testing-registry-case
 'collectors '(portable stdlib)
(test-equal 'collectors
             (list '(a b a b) "aa" "abab" (vector 0 1 2) 6 24 0 2)
             (list (append-ec (:range i 2) '(a b))
             (string-ec (:range i 2) #\a)
             (string-append-ec (:range i 2) "ab")
             (vector-ec (:range i 3) i)
             (sum-ec (:range i 4) i)
             (product-ec (:range i 1 5) i)
             (min-ec (:range i 2) i)
             (max-ec (:range i 3) i))))

(testing-registry-case
 'first-last-any-every '(portable stdlib)
(test-equal 'first-last-any-every
             '(#f 0 2 #t #f)
             (list (first-ec #f (:range i 0) i)
             (first-ec #f (:range i 3) i)
             (last-ec #f (:range i 3) i)
             (any?-ec (:range i 2 3) (even? i))
             (every?-ec (:range i 2 4) (even? i)))))

(testing-registry-case
 'folds '(portable stdlib)
(test-equal 'folds
             '(285 empty)
             (let ((sum-sqr (lambda (x result) (+ result (* x x)))))
         (list (fold-ec 0 (:range i 10) i sum-sqr)
               (fold3-ec 'empty (:range i 0) i min min)))))

(testing-registry-case
 'typed-generators '(portable stdlib)
(test-equal 'typed-generators
             '((1 2 3) (#\1 #\2) (1 2) (6 4 2) "abc")
             (list (list-ec (:list x '(1) '(2) '(3)) x)
             (list-ec (:string c "1" "2") c)
             (list-ec (:vector x (vector 1) (vector 2)) x)
             (list-ec (:range x 6 1 -2) x)
             (string-ec (:char-range c #\a #\c) c))))

(testing-registry-case
 'port-generator '(portable stdlib)
(test-equal 'port-generator
             '(0 1 2)
             (let ((input (open-input-string "0 1 2")))
         (list-ec (:port datum input) datum))))

(testing-registry-case
 'explicit-generators '(portable stdlib)
(test-equal 'explicit-generators
             '((0 1 2 3) (2) ((1 a) (2 b) (3 c)))
             (list (list-ec (:do ((i 0)) (< i 4) ((+ i 1))) i)
             (list-ec (:let x 1) (:let y (+ x 1)) y)
             (list-ec (:parallel (:range i 1 10) (:list x '(a b c)))
                      (list i x)))))

(testing-registry-case
 '-while-and--until '(portable stdlib)
(test-equal ':while-and-:until
             '((1 2 3 4) (1 2 3 4 5) 5 5)
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
               n))))

(testing-registry-case
 '-while-inner-binding-regressions '(portable stdlib)
(test-equal ':while-inner-binding-regressions
             '((1 2 3 4) (1 2 3 4 5) ((1 1) (2 2) (3 3) (4 4)))
             (list (list-ec (:while (:list i '(1 2 3 4 5 6 7 8 9))
                              (< i 5))
                      i)
             (list-ec (:while (:vector x (index i) '#(1 2 3 4 5))
                              (< x 10))
                      x)
             (list-ec (:while (:parallel (:range i 1 10)
                                         (:list j '(1 2 3 4 5 6 7 8 9)))
                              (< i 5))
                      (list i j)))))

(testing-registry-case
 'dispatching-generator '(portable stdlib)
(test-equal 'dispatching-generator
             '((a b c d)
         (#\a #\b #\c #\d)
         (a b c)
         (1 4 7)
         (#\a #\b #\c)
         ((a 0) (b 1) (c 2)))
             (list (list-ec (: c '(a b) '(c d)) c)
             (list-ec (: c "ab" "cd") c)
             (list-ec (: c (vector 'a 'b) (vector 'c)) c)
             (list-ec (: i 1 9 3) i)
             (list-ec (: c #\a #\c) c)
             (list-ec (: x (index i) '(a b c)) (list x i)))))

;; Example dispatcher from the SRFI extension notes.
(define (example-dispatch args)
  "Return the extension-note generator for symbol arguments."
  (cond
   ((null? args) 'example)
   ((and (= (length args) 1) (symbol? (car args)))
    (:generator-proc (:string (symbol->string (car args)))))
   (else #f)))

(testing-registry-case
 'dispatch-extension-hook '(portable stdlib)
(test-equal 'dispatch-extension-hook
             '(#\a #\b #\c)
             (let ((original-dispatch (:-dispatch-ref)))
         (dynamic-wind
           (lambda ()
             (:-dispatch-set! (dispatch-union original-dispatch
                                              example-dispatch)))
           (lambda ()
             (list-ec (: c 'abc) c))
           (lambda ()
             (:-dispatch-set! original-dispatch))))))

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

(testing-registry-case
 'extension-macros '(portable stdlib)
(test-equal 'extension-macros
             '((3 2 1) (0 1 2 3 4))
             (list (list-ec (:mygen x '(1 2 3)) x)
             (new-list-ec (: i 5) i))))

(testing-runner-main "Stdlib Eager Comprehensions portable tests"
  (command-line))
