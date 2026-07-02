;;; Adapted SRFI 128 comparator test suite.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2015 John Cowan <cowan@ccil.org>
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 128 `comparators-test.scm` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-128.
;;; The original tests use the Chicken test egg; this file keeps the same
;;; behavioral assertions in a small portable harness so the full Consent Scheme
;;; host matrix can exercise the adapted `(stdlib comparator)' library.
;;; The restored upstream-style case-lambda hasher below proves SRFI 16 support
;;; through this same host matrix, including the compiled portable host path.

(import (scheme base)
        (scheme case-lambda)
        (scheme write)
        (stdlib comparator))

;; Number of failed adapted SRFI checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed comparator check."
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

(define (check-exact-nonnegative-integer name value)
  "Record NAME unless VALUE is an exact non-negative integer."
  (check-true name
              (and (exact-integer? value)
                   (not (negative? value)))))

(define (raises? thunk)
  "Return #t when calling THUNK raises any condition."
  (call/cc
   (lambda (return)
     (with-exception-handler
      (lambda (condition) (return #t))
      (lambda () (thunk) #f)))))

(define (vector-cdr vec)
  "Return a vector containing VEC's elements after the first."
  (let* ((len (vector-length vec))
         (result (make-vector (- len 1))))
    (let loop ((n 1))
      (cond
       ((= n len) result)
       (else
        (vector-set! result (- n 1) (vector-ref vec n))
        (loop (+ n 1)))))))

(define (make-upstream-case-lambda-hasher)
  "Return the upstream SRFI 128 sequence hasher shape."
  (let ((result (hash-salt)))
    (case-lambda
     (() result)
     ((n)
      (set! result (+ (modulo (* result 33) (hash-bound)) n))
      result))))

(define (finish-comparator-tests)
  "Report the adapted SRFI 128 test result."
  (if (= failures 0)
      (begin
        (display "Adapted SRFI 128 comparator tests passed")
        (newline))
      (begin
        (display failures)
        (display " adapted SRFI 128 comparator test failure(s)")
        (newline)
        (error "adapted SRFI 128 comparator tests failed" failures))))

(check 'vector-cdr-many (vector-cdr '#(1 2 3 4)) '#(2 3 4))
(check 'vector-cdr-one (vector-cdr '#(1)) '#())

(let* ((acc (make-upstream-case-lambda-hasher))
       (initial (hash-salt))
       (first (+ (modulo (* initial 33) (hash-bound)) 1))
       (second (+ (modulo (* first 33) (hash-bound)) 2)))
  (check 'upstream-case-lambda-hasher-initial (acc) initial)
  (check 'upstream-case-lambda-hasher-first (acc 1) first)
  (check 'upstream-case-lambda-hasher-after-first (acc) first)
  (check 'upstream-case-lambda-hasher-second (acc 2) second)
  (check-true 'upstream-case-lambda-hasher-wrong-arity
              (raises? (lambda () (acc 1 2)))))

(let* ((default-comparator (make-default-comparator))
       (real-comparator (make-comparator real? = < number-hash))
       (degenerate-comparator
        (make-comparator (lambda (x) #t) equal? #f #f))
       (boolean-comparator
        (make-comparator
         boolean?
         eq?
         (lambda (x y) (and (not x) y))
         boolean-hash))
       (bool-pair-comparator
        (make-pair-comparator boolean-comparator boolean-comparator))
       (num-list-comparator
        (make-list-comparator real-comparator list? null? car cdr))
       (num-vector-comparator
        (make-vector-comparator
         real-comparator vector? vector-length vector-ref))
       (vector-qua-list-comparator
        (make-list-comparator
         real-comparator
         vector?
         (lambda (vec) (= 0 (vector-length vec)))
         (lambda (vec) (vector-ref vec 0))
         vector-cdr))
       (list-qua-vector-comparator
        (make-vector-comparator default-comparator list? length list-ref))
       (eq-comparator (make-eq-comparator))
       (eqv-comparator (make-eqv-comparator))
       (equal-comparator (make-equal-comparator))
       (symbol-comparator
        (make-comparator
         symbol?
         eq?
         (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
         symbol-hash)))

  (check-true 'predicates-comparator
              (comparator? real-comparator))
  (check-false 'predicates-rejects-procedure
               (comparator? =))
  (check-true 'predicates-ordered
              (comparator-ordered? real-comparator))
  (check-true 'predicates-hashable
              (comparator-hashable? real-comparator))
  (check-false 'predicates-degenerate-not-ordered
               (comparator-ordered? degenerate-comparator))
  (check-false 'predicates-degenerate-not-hashable
               (comparator-hashable? degenerate-comparator))

  (check-true 'constructors-boolean-equal
              (=? boolean-comparator #t #t))
  (check-false 'constructors-boolean-not-equal
               (=? boolean-comparator #t #f))
  (check-true 'constructors-boolean-less
              (<? boolean-comparator #f #t))
  (check-false 'constructors-boolean-not-less-same
               (<? boolean-comparator #t #t))
  (check-false 'constructors-boolean-not-less-reversed
               (<? boolean-comparator #t #f))

  (check-true 'constructors-pair-type
              (comparator-test-type bool-pair-comparator '(#t . #f)))
  (check-false 'constructors-pair-rejects-number
               (comparator-test-type bool-pair-comparator 32))
  (check-false 'constructors-pair-rejects-car
               (comparator-test-type bool-pair-comparator '(32 . #f)))
  (check-false 'constructors-pair-rejects-cdr
               (comparator-test-type bool-pair-comparator '(#t . 32)))
  (check-false 'constructors-pair-rejects-both
               (comparator-test-type bool-pair-comparator '(32 . 34)))
  (check-true 'constructors-pair-equal
              (=? bool-pair-comparator '(#t . #t) '(#t . #t)))
  (check-false 'constructors-pair-not-equal-car
               (=? bool-pair-comparator '(#t . #t) '(#f . #t)))
  (check-false 'constructors-pair-not-equal-cdr
               (=? bool-pair-comparator '(#t . #t) '(#t . #f)))
  (check-true 'constructors-pair-less-car
              (<? bool-pair-comparator '(#f . #t) '(#t . #t)))
  (check-true 'constructors-pair-less-cdr
              (<? bool-pair-comparator '(#t . #f) '(#t . #t)))
  (check-false 'constructors-pair-not-less-same
               (<? bool-pair-comparator '(#t . #t) '(#t . #t)))
  (check-false 'constructors-pair-not-less-reversed-car
               (<? bool-pair-comparator '(#t . #t) '(#f . #t)))
  (check-false 'constructors-pair-not-less-reversed-cdr
               (<? bool-pair-comparator '(#f . #t) '(#f . #f)))

  (check-true 'constructors-vector-type
              (comparator-test-type num-vector-comparator '#(1 2 3)))
  (check-true 'constructors-vector-empty-type
              (comparator-test-type num-vector-comparator '#()))
  (check-false 'constructors-vector-rejects-number
               (comparator-test-type num-vector-comparator 1))
  (check-false 'constructors-vector-rejects-first
               (comparator-test-type num-vector-comparator '#(a 2 3)))
  (check-false 'constructors-vector-rejects-second
               (comparator-test-type num-vector-comparator '#(1 b 3)))
  (check-false 'constructors-vector-rejects-third
               (comparator-test-type num-vector-comparator '#(1 2 c)))
  (check-true 'constructors-vector-equal
              (=? num-vector-comparator '#(1 2 3) '#(1 2 3)))
  (check-false 'constructors-vector-not-equal-all
               (=? num-vector-comparator '#(1 2 3) '#(4 5 6)))
  (check-false 'constructors-vector-not-equal-tail
               (=? num-vector-comparator '#(1 2 3) '#(1 5 6)))
  (check-false 'constructors-vector-not-equal-last
               (=? num-vector-comparator '#(1 2 3) '#(1 2 6)))
  (check-true 'constructors-vector-less-shorter
              (<? num-vector-comparator '#(1 2) '#(1 2 3)))
  (check-true 'constructors-vector-less-first
              (<? num-vector-comparator '#(1 2 3) '#(2 3 4)))
  (check-true 'constructors-vector-less-second
              (<? num-vector-comparator '#(1 2 3) '#(1 3 4)))
  (check-true 'constructors-vector-less-third
              (<? num-vector-comparator '#(1 2 3) '#(1 2 4)))
  (check-true 'constructors-vector-length-precedes-elements
              (<? num-vector-comparator '#(3 4) '#(1 2 3)))
  (check-false 'constructors-vector-not-less-same
               (<? num-vector-comparator '#(1 2 3) '#(1 2 3)))
  (check-false 'constructors-vector-not-less-longer
               (<? num-vector-comparator '#(1 2 3) '#(1 2)))
  (check-false 'constructors-vector-not-less-first
               (<? num-vector-comparator '#(1 2 3) '#(0 2 3)))
  (check-false 'constructors-vector-not-less-second
               (<? num-vector-comparator '#(1 2 3) '#(1 1 3)))

  (check-false 'constructors-vector-as-list-uses-list-order
               (<? vector-qua-list-comparator '#(3 4) '#(1 2 3)))
  (check-true 'constructors-list-as-vector-uses-vector-order
              (<? list-qua-vector-comparator '(3 4) '(1 2 3)))

  (let ((bool-pair (cons #t #f))
        (bool-pair-2 (cons #t #f))
        (reverse-bool-pair (cons #f #t)))
    (check-true 'constructors-eq-true
                (=? eq-comparator #t #t))
    (check-false 'constructors-eq-false
                 (=? eq-comparator #f #t))
    (check-true 'constructors-eqv-same-pair
                (=? eqv-comparator bool-pair bool-pair))
    (check-false 'constructors-eqv-distinct-pairs
                 (=? eqv-comparator bool-pair bool-pair-2))
    (check-true 'constructors-equal-distinct-pairs
                (=? equal-comparator bool-pair bool-pair-2))
    (check-false 'constructors-equal-reversed-pair
                 (=? equal-comparator bool-pair reverse-bool-pair)))

  (check-exact-nonnegative-integer 'hash-boolean-false
                                   (boolean-hash #f))
  (check-exact-nonnegative-integer 'hash-boolean-true
                                   (boolean-hash #t))
  (check-exact-nonnegative-integer 'hash-char-lower
                                   (char-hash #\a))
  (check-exact-nonnegative-integer 'hash-char-other
                                   (char-hash #\b))
  (check-exact-nonnegative-integer 'hash-char-ci-lower
                                   (char-ci-hash #\a))
  (check-exact-nonnegative-integer 'hash-char-ci-other
                                   (char-ci-hash #\b))
  (check 'hash-char-ci-folds
         (char-ci-hash #\a)
         (char-ci-hash #\A))
  (check-exact-nonnegative-integer 'hash-string
                                   (string-hash "f"))
  (check-exact-nonnegative-integer 'hash-string-other
                                   (string-hash "g"))
  (check-exact-nonnegative-integer 'hash-string-ci
                                   (string-ci-hash "f"))
  (check-exact-nonnegative-integer 'hash-string-ci-other
                                   (string-ci-hash "g"))
  (check 'hash-string-ci-folds
         (string-ci-hash "f")
         (string-ci-hash "F"))
  (check-exact-nonnegative-integer 'hash-symbol
                                   (symbol-hash 'f))
  (check-exact-nonnegative-integer 'hash-symbol-other
                                   (symbol-hash 't))
  (check-exact-nonnegative-integer 'hash-number
                                   (number-hash 3))
  (check-exact-nonnegative-integer 'hash-number-negative
                                   (number-hash -3))
  (check-exact-nonnegative-integer 'hash-number-inexact-integer
                                   (number-hash 3.0))
  (check-exact-nonnegative-integer 'hash-number-inexact
                                   (number-hash 3.47))
  (check-exact-nonnegative-integer 'hash-default-null
                                   (default-hash '()))
  (check-exact-nonnegative-integer 'hash-default-list
                                   (default-hash '(a "b" #\c #(dee) 2.718)))
  (check-exact-nonnegative-integer 'hash-default-bytevector-empty
                                   (default-hash (bytevector)))
  (check-exact-nonnegative-integer 'hash-default-bytevector
                                   (default-hash (bytevector 8 6 3)))
  (check-exact-nonnegative-integer 'hash-default-vector-empty
                                   (default-hash '#()))
  (check-exact-nonnegative-integer 'hash-default-vector
                                   (default-hash '#(a "b" #\c #(dee) 2.718)))

  (check-true 'default-null-before-list
              (<? default-comparator '() '(a)))
  (check-false 'default-null-not-equal-list
               (=? default-comparator '() '(a)))
  (check-true 'default-boolean-equal
              (=? default-comparator #t #t))
  (check-false 'default-boolean-not-equal
               (=? default-comparator #t #f))
  (check-true 'default-boolean-less
              (<? default-comparator #f #t))
  (check-false 'default-boolean-not-less-same
               (<? default-comparator #t #t))
  (check-true 'default-char-equal
              (=? default-comparator #\a #\a))
  (check-true 'default-char-less
              (<? default-comparator #\a #\b))

  (check-true 'default-type-null
              (comparator-test-type default-comparator '()))
  (check-true 'default-type-boolean
              (comparator-test-type default-comparator #t))
  (check-true 'default-type-char
              (comparator-test-type default-comparator #\t))
  (check-true 'default-type-pair
              (comparator-test-type default-comparator '(a)))
  (check-true 'default-type-symbol
              (comparator-test-type default-comparator 'a))
  (check-true 'default-type-bytevector
              (comparator-test-type default-comparator (make-bytevector 10)))
  (check-true 'default-type-exact-number
              (comparator-test-type default-comparator 10))
  (check-true 'default-type-inexact-number
              (comparator-test-type default-comparator 10.0))
  (check-true 'default-type-string
              (comparator-test-type default-comparator "10.0"))
  (check-true 'default-type-vector
              (comparator-test-type default-comparator '#(10)))

  (check-true 'default-pair-equal
              (=? default-comparator '(#t . #t) '(#t . #t)))
  (check-false 'default-pair-not-equal-car
               (=? default-comparator '(#t . #t) '(#f . #t)))
  (check-false 'default-pair-not-equal-cdr
               (=? default-comparator '(#t . #t) '(#t . #f)))
  (check-true 'default-pair-less-car
              (<? default-comparator '(#f . #t) '(#t . #t)))
  (check-true 'default-pair-less-cdr
              (<? default-comparator '(#t . #f) '(#t . #t)))
  (check-false 'default-pair-not-less-same
               (<? default-comparator '(#t . #t) '(#t . #t)))
  (check-false 'default-pair-not-less-reversed-car
               (<? default-comparator '(#t . #t) '(#f . #t)))
  (check-false 'default-vector-not-less-reversed-cdr
               (<? default-comparator '#(#f #t) '#(#f #f)))

  (check-true 'default-vector-equal
              (=? default-comparator '#(#t #t) '#(#t #t)))
  (check-false 'default-vector-not-equal-first
               (=? default-comparator '#(#t #t) '#(#f #t)))
  (check-false 'default-vector-not-equal-second
               (=? default-comparator '#(#t #t) '#(#t #f)))
  (check-true 'default-vector-less-first
              (<? default-comparator '#(#f #t) '#(#t #t)))
  (check-true 'default-vector-less-second
              (<? default-comparator '#(#t #f) '#(#t #t)))
  (check-false 'default-vector-not-less-same
               (<? default-comparator '#(#t #t) '#(#t #t)))
  (check-false 'default-vector-not-less-reversed-first
               (<? default-comparator '#(#t #t) '#(#f #t)))
  (check-false 'default-vector-not-less-reversed-second
               (<? default-comparator '#(#f #t) '#(#f #f)))

  (check 'default-hash-boolean
         (comparator-hash default-comparator #t)
         (boolean-hash #t))
  (check 'default-hash-char
         (comparator-hash default-comparator #\t)
         (char-hash #\t))
  (check 'default-hash-string
         (comparator-hash default-comparator "t")
         (string-hash "t"))
  (check 'default-hash-symbol
         (comparator-hash default-comparator 't)
         (symbol-hash 't))
  (check 'default-hash-exact-number
         (comparator-hash default-comparator 10)
         (number-hash 10))
  (check 'default-hash-inexact-number
         (comparator-hash default-comparator 10.0)
         (number-hash 10.0))

  (comparator-register-default!
   (make-comparator
    procedure?
    (lambda (a b) #t)
    (lambda (a b) #f)
    (lambda (obj) 200)))
  (check-true 'default-registered-procedure-equal
              (=? default-comparator (lambda () #t) (lambda () #f)))
  (check-false 'default-registered-procedure-not-less
               (<? default-comparator (lambda () #t) (lambda () #f)))
  (check 'default-registered-procedure-hash
         (comparator-hash default-comparator (lambda () #t))
         200)

  (let* ((x1 0)
         (x2 0)
         (x3 0)
         (x4 0)
         (ttp (lambda (x) (set! x1 111) #t))
         (eqp (lambda (x y) (set! x2 222) #t))
         (orp (lambda (x y) (set! x3 333) #t))
         (hf (lambda (x) (set! x4 444) 0)))
    (let ((comp (make-comparator ttp eqp orp hf)))
      (check-true 'accessors-type-test-invokes-original
                  (and ((comparator-type-test-predicate comp) x1)
                       (= x1 111)))
      (check-true 'accessors-equality-invokes-original
                  (and ((comparator-equality-predicate comp) x1 x2)
                       (= x2 222)))
      (check-true 'accessors-ordering-invokes-original
                  (and ((comparator-ordering-predicate comp) x1 x3)
                       (= x3 333)))
      (check-true 'accessors-hash-invokes-original
                  (and (zero? ((comparator-hash-function comp) x1))
                       (= x4 444)))))

  (check-true 'invokers-real-exact
              (comparator-test-type real-comparator 3))
  (check-true 'invokers-real-inexact
              (comparator-test-type real-comparator 3.0))
  (check-false 'invokers-real-rejects-string
               (comparator-test-type real-comparator "3.0"))
  (check-true 'invokers-check-type-accepts
              (comparator-check-type boolean-comparator #t))
  (check-true 'invokers-check-type-rejects
              (raises?
               (lambda ()
                 (comparator-check-type boolean-comparator 't))))

  (check-true 'comparison-equal-chain
              (=? real-comparator 2 2.0 2))
  (check-true 'comparison-less-chain
              (<? real-comparator 2 3.0 4))
  (check-true 'comparison-greater-chain
              (>? real-comparator 4.0 3.0 2))
  (check-true 'comparison-less-equal-chain
              (<=? real-comparator 2.0 2 3.0))
  (check-true 'comparison-greater-equal-chain
              (>=? real-comparator 3 3.0 2))
  (check-false 'comparison-not-equal-chain
               (=? real-comparator 1 2 3))
  (check-false 'comparison-not-less-chain
               (<? real-comparator 3 1 2))
  (check-false 'comparison-not-greater-chain
               (>? real-comparator 1 2 3))
  (check-false 'comparison-not-less-equal-chain
               (<=? real-comparator 4 3 3))
  (check-false 'comparison-not-greater-equal-chain
               (>=? real-comparator 3 4 4.0))

  (check 'syntax-less
         (comparator-if<=> real-comparator 1 2 'less 'equal 'greater)
         'less)
  (check 'syntax-equal
         (comparator-if<=> real-comparator 1 1 'less 'equal 'greater)
         'equal)
  (check 'syntax-greater
         (comparator-if<=> real-comparator 2 1 'less 'equal 'greater)
         'greater)
  (check 'syntax-default-less
         (comparator-if<=> "1" "2" 'less 'equal 'greater)
         'less)
  (check 'syntax-default-equal
         (comparator-if<=> "1" "1" 'less 'equal 'greater)
         'equal)
  (check 'syntax-default-greater
         (comparator-if<=> "2" "1" 'less 'equal 'greater)
         'greater)

  (check-exact-nonnegative-integer 'bound-hash-bound
                                   (hash-bound))
  (check-exact-nonnegative-integer 'bound-hash-salt
                                   (hash-salt))
  (check-true 'bound-salt-less-than-bound
              (< (hash-salt) (hash-bound)))

  ;; Keep one use of the custom symbol comparator from the upstream setup.
  (check-true 'constructors-symbol-comparator-less
              (<? symbol-comparator 'alpha 'beta))
  (check-true 'constructors-list-comparator-equal
              (=? num-list-comparator '(1 2) '(1 2)))
  (check-true 'constructors-list-comparator-less
              (<? num-list-comparator '(1 2) '(1 3))))

(finish-comparator-tests)
