;;; Adapted upstream SRFI 42 eager-comprehensions examples.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2003, 2007 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from examples.scm and extension.scm in the upstream SRFI 42
;;; repository, revision 6a4c4aeb4cb61c6514776144fdfc5fe0d738a548.

(import (scheme base)
        (scheme read)
        (scheme write)
        (stdlib eager-comprehensions))

;; Number of failed adapted upstream SRFI checks seen so far.
(define upstream-failures 0)

(define (upstream-equal? actual expected)
  "Return true when ACTUAL and EXPECTED match upstream SRFI 42 examples."
  (cond
   ((or (boolean? actual)
        (null? actual)
        (symbol? actual)
        (char? actual)
        (input-port? actual)
        (output-port? actual))
    (eqv? actual expected))
   ((string? actual)
    (and (string? expected) (string=? actual expected)))
   ((vector? actual)
    (and (vector? expected)
         (upstream-equal? (vector->list actual) (vector->list expected))))
   ((pair? actual)
    (and (pair? expected)
         (upstream-equal? (car actual) (car expected))
         (upstream-equal? (cdr actual) (cdr expected))))
   ((real? actual)
    (and (real? expected)
         (eqv? (exact? actual) (exact? expected))
         (if (exact? actual)
             (= actual expected)
             (< (abs (- actual expected)) (/ 1 (expt 10 6))))))
   (else
    (equal? actual expected))))

(define (record-upstream-failure name expected actual)
  "Record one failed adapted upstream SRFI 42 example."
  (set! upstream-failures (+ upstream-failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (upstream-check name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (upstream-equal? actual expected))
      (record-upstream-failure name expected actual)))

(define (finish-upstream-tests)
  "Report the adapted upstream SRFI 42 result."
  (if (= upstream-failures 0)
      (begin
        (display "Adapted upstream SRFI 42 examples passed")
        (newline))
      (begin
        (display upstream-failures)
        (display " adapted upstream SRFI 42 example failure(s)")
        (newline)
        (error "adapted upstream SRFI 42 examples failed" upstream-failures))))

(upstream-check 'do-ec-counts
                (list (let ((x 0))
                        (do-ec (:range i 10) (set! x (+ x 1)))
                        x)
                      (let ((x 0))
                        (do-ec (:range n 10)
                               (:range k n)
                               (set! x (+ x 1)))
                        x))
                '(10 45))

(upstream-check 'list-ec-basic-qualifiers
                (list (list-ec 1)
                      (list-ec (:range i 4) i)
                      (list-ec (:range n 3)
                               (:range k (+ n 1))
                               (list n k))
                      (list-ec (:range n 5)
                               (and (even? n) (> n 2))
                               (:range k (+ n 1))
                               (list n k))
                      (list-ec (:range n 5)
                               (or (even? n) (> n 3))
                               (:range k (+ n 1))
                               (list n k)))
                '((1)
                  (0 1 2 3)
                  ((0 0) (1 0) (1 1) (2 0) (2 1) (2 2))
                  ((4 0) (4 1) (4 2) (4 3) (4 4))
                  ((0 0) (2 0) (2 1) (2 2) (4 0) (4 1) (4 2) (4 3) (4 4))))

(upstream-check 'collector-boundaries
                (list (append-ec '(a b))
                      (append-ec (:range i 0) '(a b))
                      (string-ec #\a)
                      (string-ec (:range i 0) #\a)
                      (string-append-ec (:range i 2) "ab")
                      (vector-ec 1)
                      (vector-ec (:range i 0) i)
                      (vector-of-length-ec 2 (:range i 2) i)
                      (sum-ec 1)
                      (sum-ec (:range i 3) i)
                      (product-ec (:range i 1 4) i)
                      (min-ec 1)
                      (max-ec (:range i 2) i))
                (list '(a b) '() "a" "" "abab" (vector 1) (vector)
                      (vector 0 1) 1 3 6 1 1))

(upstream-check 'early-and-folding-comprehensions
                (list (first-ec #f 1)
                      (first-ec #f (:range i 0) i)
                      (last-ec #f 1)
                      (last-ec #f (:range i 2) i)
                      (any?-ec #f)
                      (any?-ec #t)
                      (any?-ec (:range i 2 2) (even? i))
                      (every?-ec (:range i 2 4) (even? i))
                      (let ((last-i -1))
                        (first-ec #f
                                  (:range i 10)
                                  (begin (set! last-i i))
                                  i)
                        last-i)
                      (fold3-ec 'infinity (:range i 0) i min min)
                      (let ((minus-1 (lambda (x) (- x 1)))
                            (sum-sqr (lambda (x result)
                                       (+ result (* x x)))))
                        (fold3-ec (error "wrong")
                                  (:range i 10)
                                  i
                                  minus-1
                                  sum-sqr)))
                '(1 #f 1 1 #f #t #f #f 0 infinity 284))

(upstream-check 'typed-generator-boundaries
                (list (list-ec (:list x '()) x)
                      (list-ec (:list x '(1) '(2) '(3)) x)
                      (list-ec (:string c "") c)
                      (list-ec (:string c "1" "2" "3") c)
                      (list-ec (:vector x (vector)) x)
                      (list-ec (:vector x (vector 1) (vector 2) (vector 3)) x)
                      (list-ec (:range x -2) x)
                      (list-ec (:range x 1 6 2) x)
                      (list-ec (:range x 6 1 -2) x)
                      (list-ec (:real-range x 0.0 3.0) x)
                      (list-ec (:real-range x 0 3.0) x)
                      (list-ec (:real-range x 0 3 1.0) x)
                      (string-ec (:char-range c #\a #\z) c)
                      (let ((input (open-input-string "0 1 2")))
                        (list-ec (:port x input read) x))
                      (let ((input (open-input-string "0 1 2")))
                        (list-ec (:port x input) x)))
                '(() (1 2 3) () (#\1 #\2 #\3) () (1 2 3) ()
                  (1 3 5) (6 4 2) (0.0 1.0 2.0) (0.0 1.0 2.0)
                  (0.0 1.0 2.0) "abcdefghijklmnopqrstuvwxyz"
                  (0 1 2) (0 1 2)))

(upstream-check 'special-generators
                (list (list-ec (:do ((i 0)) (< i 4) ((+ i 1))) i)
                      (list-ec
                       (:do (let ((x 'x)))
                            ((i 0))
                            (< i 4)
                            (let ((j (- 10 i))))
                            #t
                            ((+ i 1)))
                       j)
                      (list-ec (:let x 1) x)
                      (list-ec (:let x 1) (:let y (+ x 1)) y)
                      (list-ec (:let x 1) (:let x (+ x 1)) x)
                      (list-ec (:parallel (:range i 1 10)
                                          (:list x '(a b c)))
                               (list i x)))
                '((0 1 2 3) (10 9 8 7) (1) (2) (2)
                  ((1 a) (2 b) (3 c))))

(upstream-check 'while-until-stop-behavior
                (list (list-ec (:until (:list i '(1 2 3 4 5 6 7 8 9))
                                       (>= i 5))
                               i)
                      (list-ec (:until (:parallel (:range i 1 10)
                                                  (:list j '(1 2 3 4 5 6 7 8 9)))
                                       (>= i 5))
                               (list i j))
                      (let ((n 0))
                        (do-ec (:while (:parallel (:range i 1 10)
                                                  (:do ()
                                                       (begin
                                                         (set! n (+ n 1))
                                                         #t)
                                                       ()))
                                       (< i 5))
                               (if #f #f))
                        n)
                      (let ((n 0))
                        (do-ec (:until (:parallel (:range i 1 10)
                                                  (:do ()
                                                       (begin
                                                         (set! n (+ n 1))
                                                         #t)
                                                       ()))
                                       (>= i 5))
                               (if #f #f))
                        n))
                '((1 2 3 4 5) ((1 1) (2 2) (3 3) (4 4) (5 5)) 5 5))

(upstream-check 'dispatching-generator-boundaries
                (list (list-ec (: c '(a b)) c)
                      (list-ec (: c '(a b) '(c d)) c)
                      (list-ec (: c "ab") c)
                      (list-ec (: c "ab" "cd") c)
                      (list-ec (: c (vector 'a 'b)) c)
                      (list-ec (: c (vector 'a 'b) (vector 'c)) c)
                      (list-ec (: i 0) i)
                      (list-ec (: i 1) i)
                      (list-ec (: i 10) i)
                      (list-ec (: i 1 2 3) i)
                      (list-ec (: i 0.0 1.0 0.2) i)
                      (let ((input (open-input-string "0 1 2")))
                        (list-ec (: x input read) x)))
                '((a b) (a b c d) (#\a #\b) (#\a #\b #\c #\d)
                  (a b) (a b c) () (0) (0 1 2 3 4 5 6 7 8 9)
                  (1) (0.0 0.2 0.4 0.6 0.8) (0 1 2)))

(upstream-check 'index-variable-examples
                (list (list-ec (:list c (index i) '(a b)) (list c i))
                      (list-ec (:string c (index i) "a") (list c i))
                      (list-ec (:vector c (index i) (vector 'a)) (list c i))
                      (list-ec (:range i (index j) 0 -3 -1) (list i j))
                      (list-ec (:real-range i (index j) 0 1 0.2) (list i j))
                      (list-ec (:char-range c (index i) #\a #\c) (list c i))
                      (list-ec (: x (index i) '(a b c d)) (list x i))
                      (list-ec (:string c (index i) "a" "b") (cons c i)))
                '(((a 0) (b 1))
                  ((#\a 0))
                  ((a 0))
                  ((0 0) (-1 1) (-2 2))
                  ((0.0 0) (0.2 1) (0.4 2) (0.6 3) (0.8 4))
                  ((#\a 0) (#\b 1) (#\c 2))
                  ((a 0) (b 1) (c 2) (d 3))
                  ((#\a . 0) (#\b . 1))))

(upstream-check 'little-shop-examples
                (list (list-ec (:range x 5) (:range x x) x)
                      (list-ec (:list x '(2 "23" (4))) (: y x) y)
                      (list-ec (:parallel (:integers x)
                                          (:do ((i 10)) (< x i) ((- i 1))))
                               (list x i)))
                '((0 0 1 0 1 2 0 1 2 3)
                  (0 1 #\2 #\3 4)
                  ((0 10) (1 9) (2 8) (3 7) (4 6))))

(define (factorial n)
  "Return N factorial using an upstream SRFI 42 example."
  (product-ec (:range k 2 (+ n 1)) k))

(define (eratosthenes n)
  "Return primes below N using an upstream SRFI 42 example."
  (let ((prime? (make-string n #\1)))
    (do-ec (:range k 2 n)
           (if (char=? (string-ref prime? k) #\1))
           (:range i (* 2 k) n k)
           (string-set! prime? i #\0))
    (list-ec (:range k 2 n)
             (if (char=? (string-ref prime? k) #\1))
             k)))

(define (pythagoras n)
  "Return Pythagorean triples bounded by N using an upstream example."
  (list-ec
   (:let sqr-n (* n n))
   (:range a 1 (+ n 1))
   (:let sqr-a (* a a))
   (:range b a (+ n 1))
   (:let sqr-c (+ sqr-a (* b b)))
   (if (<= sqr-c sqr-n))
   (:range c b (+ n 1))
   (if (= (* c c) sqr-c))
   (list a b c)))

(define (qsort xs)
  "Return XS sorted with the stable upstream SRFI 42 quicksort example."
  (if (null? xs)
      '()
      (let ((pivot (car xs))
            (xrest (cdr xs)))
        (append
         (qsort (list-ec (:list x xrest) (if (< x pivot)) x))
         (list pivot)
         (qsort (list-ec (:list x xrest) (if (>= x pivot)) x))))))

(upstream-check 'less-artificial-examples
                (list (factorial 0)
                      (factorial 5)
                      (eratosthenes 50)
                      (pythagoras 15)
                      (qsort '(1 5 4 2 4 5 3 2 1 3)))
                '(1
                  120
                  (2 3 5 7 11 13 17 19 23 29 31 37 41 43 47)
                  ((3 4 5) (5 12 13) (6 8 10) (9 12 15))
                  (1 1 2 2 3 3 4 4 5 5)))

;; Extension dispatcher from the upstream extension examples.
(define (example-dispatch args)
  "Return the upstream extension-note generator for symbol arguments."
  (cond
   ((null? args)
    'example)
   ((and (= (length args) 1) (symbol? (car args)))
    (:generator-proc (:string (symbol->string (car args)))))
   (else
    #f)))

;; Application-specific dispatcher from the upstream extension examples.
(define (:my-dispatch args)
  "Return the upstream application-specific dispatch generator."
  (case (length args)
    ((0) 'example)
    ((1) (let ((a1 (car args)))
           (cond
            ((list? a1)
             (:generator-proc (:list a1)))
            ((string? a1)
             (:generator-proc (:string a1)))
            (else
             #f))))
    ((2) (let ((a1 (car args))
               (a2 (cadr args)))
           (cond
            ((and (list? a1) (list? a2))
             (:generator-proc (:list a1 a2)))
            (else
             #f))))
    (else
     (cond
      ((every?-ec (:list a args) (list? a))
       (:generator-proc (:list (apply append args))))
      (else
       #f)))))

;; Application-specific dispatching generator from the upstream examples.
(define-syntax :my
  (syntax-rules (index)
    ((:my cc var (index i) arg1 arg ...)
     (:dispatched cc var (index i) :my-dispatch arg1 arg ...))
    ((:my cc var arg1 arg ...)
     (:dispatched cc var :my-dispatch arg1 arg ...))))

;; Typed generator from the upstream extension examples.
(define-syntax :mygen
  (syntax-rules ()
    ((:mygen cc var arg)
     (:list cc var (reverse arg)))))

;; Application-specific list comprehension from the upstream examples.
(define-syntax new-list-ec
  (syntax-rules ()
    ((new-list-ec etc1 etc ...)
     (reverse (fold-ec '() etc1 etc ... cons)))))

;; Application-specific min comprehension from the upstream examples.
(define-syntax new-min-ec
  (syntax-rules ()
    ((new-min-ec etc1 etc ...)
     (fold3-ec (min) etc1 etc ... min min))))

;; Application-specific fold3 comprehension from the upstream examples.
(define-syntax new-fold3-ec
  (syntax-rules (nested)
    ((new-fold3-ec x0 (nested q1 ...) q etc1 etc2 etc3 etc ...)
     (new-fold3-ec x0 (nested q1 ... q) etc1 etc2 etc3 etc ...))
    ((new-fold3-ec x0 q1 q2 etc1 etc2 etc3 etc ...)
     (new-fold3-ec x0 (nested q1 q2) etc1 etc2 etc3 etc ...))
    ((new-fold3-ec x0 expression f1 f2)
     (new-fold3-ec x0 (nested) expression f1 f2))
    ((new-fold3-ec x0 qualifier expression f1 f2)
     (let ((upstream-fold3-result #f)
           (upstream-fold3-empty? #t))
       (do-ec qualifier
              (let ((upstream-fold3-value expression))
                (if upstream-fold3-empty?
                    (begin
                      (set! upstream-fold3-result
                            (f1 upstream-fold3-value))
                      (set! upstream-fold3-empty? #f))
                    (set! upstream-fold3-result
                          (f2 upstream-fold3-value
                              upstream-fold3-result)))))
       (if upstream-fold3-empty? x0 upstream-fold3-result)))))

(upstream-check 'extension-examples
                (let ((original-dispatch (:-dispatch-ref)))
                  (dynamic-wind
                    (lambda ()
                      (:-dispatch-set!
                       (dispatch-union original-dispatch example-dispatch)))
                    (lambda ()
                      (list (list-ec (: c 'abc) c)
                            (list-ec (:my x "abc") x)
                            (list-ec (:my x '(1) '(2) '(3)) x)
                            (list-ec (:my x (index i) "abc") (list x i))
                            (list-ec (:mygen x '(1 2 3)) x)
                            (new-list-ec (: i 5) i)
                            (new-min-ec (: i 5) i)
                            (let ((f1 (lambda (x) (list 'f1 x)))
                                  (f2 (lambda (x result)
                                        (list 'f2 x result))))
                              (new-fold3-ec (error "bad") (: i 5) i f1 f2))))
                    (lambda ()
                      (:-dispatch-set! original-dispatch))))
                '((#\a #\b #\c)
                  (#\a #\b #\c)
                  (1 2 3)
                  ((#\a 0) (#\b 1) (#\c 2))
                  (3 2 1)
                  (0 1 2 3 4)
                  0
                  (f2 4 (f2 3 (f2 2 (f2 1 (f1 0)))))))

(finish-upstream-tests)
