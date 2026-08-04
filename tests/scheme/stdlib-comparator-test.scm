;;; Adapted SRFI 128 comparator test suite.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2015 John Cowan <cowan@ccil.org>
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 128 `comparators-test.scm` tests at
;;; https://github.com/scheme-requests-for-implementation/srfi-128.
;;; The original tests use the Chicken test egg; this file keeps the same
;;; behavioral assertions in a small portable harness so the full Consent
;;; Scheme
;;; host matrix can exercise the adapted `(stdlib comparator)' library.
;;; The restored upstream-style case-lambda hasher below proves SRFI 16 support
;;; through this same host matrix, including the compiled portable host path.

(import (scheme base)
        (scheme case-lambda)
        (scheme write)
        (stdlib comparator)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (check-exact-nonnegative-integer name value)
  "Record NAME unless VALUE is an exact non-negative integer."
  (test-assert name
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

(testing-registry-case
 'vector-cdr-many '(portable stdlib)
(test-equal 'vector-cdr-many '#(2 3 4) (vector-cdr '#(1 2 3 4))))
(testing-registry-case
 'vector-cdr-one '(portable stdlib)
(test-equal 'vector-cdr-one '#() (vector-cdr '#(1))))

(testing-registry-case
 'upstream-case-lambda-hasher-initial '(portable stdlib)
(let* ((acc (make-upstream-case-lambda-hasher))
       (initial (hash-salt))
       (first (+ (modulo (* initial 33) (hash-bound)) 1))
       (second (+ (modulo (* first 33) (hash-bound)) 2)))
  (test-equal 'upstream-case-lambda-hasher-initial initial (acc))
  (test-equal 'upstream-case-lambda-hasher-first first (acc 1))
  (test-equal 'upstream-case-lambda-hasher-after-first first (acc))
  (test-equal 'upstream-case-lambda-hasher-second second (acc 2))
  (test-assert 'upstream-case-lambda-hasher-wrong-arity
             (raises? (lambda () (acc 1 2))))))

(testing-registry-case
 'predicates-comparator '(portable stdlib)
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

  (test-assert 'predicates-comparator
             (comparator? real-comparator))
  (test-assert 'predicates-rejects-procedure
             (not (comparator? =)))
  (test-assert 'predicates-ordered
             (comparator-ordered? real-comparator))
  (test-assert 'predicates-hashable
             (comparator-hashable? real-comparator))
  (test-assert 'predicates-degenerate-not-ordered
             (not (comparator-ordered? degenerate-comparator)))
  (test-assert 'predicates-degenerate-not-hashable
             (not (comparator-hashable? degenerate-comparator)))

  (test-assert 'constructors-boolean-equal
             (=? boolean-comparator #t #t))
  (test-assert 'constructors-boolean-not-equal
             (not (=? boolean-comparator #t #f)))
  (test-assert 'constructors-boolean-less
             (<? boolean-comparator #f #t))
  (test-assert 'constructors-boolean-not-less-same
             (not (<? boolean-comparator #t #t)))
  (test-assert 'constructors-boolean-not-less-reversed
             (not (<? boolean-comparator #t #f)))

  (test-assert 'constructors-pair-type
             (comparator-test-type bool-pair-comparator '(#t . #f)))
  (test-assert 'constructors-pair-rejects-number
             (not (comparator-test-type bool-pair-comparator 32)))
  (test-assert 'constructors-pair-rejects-car
             (not (comparator-test-type bool-pair-comparator '(32 . #f))))
  (test-assert 'constructors-pair-rejects-cdr
             (not (comparator-test-type bool-pair-comparator '(#t . 32))))
  (test-assert 'constructors-pair-rejects-both
             (not (comparator-test-type bool-pair-comparator '(32 . 34))))
  (test-assert 'constructors-pair-equal
             (=? bool-pair-comparator '(#t . #t) '(#t . #t)))
  (test-assert 'constructors-pair-not-equal-car
             (not (=? bool-pair-comparator '(#t . #t) '(#f . #t))))
  (test-assert 'constructors-pair-not-equal-cdr
             (not (=? bool-pair-comparator '(#t . #t) '(#t . #f))))
  (test-assert 'constructors-pair-less-car
             (<? bool-pair-comparator '(#f . #t) '(#t . #t)))
  (test-assert 'constructors-pair-less-cdr
             (<? bool-pair-comparator '(#t . #f) '(#t . #t)))
  (test-assert 'constructors-pair-not-less-same
             (not (<? bool-pair-comparator '(#t . #t) '(#t . #t))))
  (test-assert 'constructors-pair-not-less-reversed-car
             (not (<? bool-pair-comparator '(#t . #t) '(#f . #t))))
  (test-assert 'constructors-pair-not-less-reversed-cdr
             (not (<? bool-pair-comparator '(#f . #t) '(#f . #f))))

  (test-assert 'constructors-vector-type
             (comparator-test-type num-vector-comparator '#(1 2 3)))
  (test-assert 'constructors-vector-empty-type
             (comparator-test-type num-vector-comparator '#()))
  (test-assert 'constructors-vector-rejects-number
             (not (comparator-test-type num-vector-comparator 1)))
  (test-assert 'constructors-vector-rejects-first
             (not (comparator-test-type num-vector-comparator '#(a 2 3))))
  (test-assert 'constructors-vector-rejects-second
             (not (comparator-test-type num-vector-comparator '#(1 b 3))))
  (test-assert 'constructors-vector-rejects-third
             (not (comparator-test-type num-vector-comparator '#(1 2 c))))
  (test-assert 'constructors-vector-equal
             (=? num-vector-comparator '#(1 2 3) '#(1 2 3)))
  (test-assert 'constructors-vector-not-equal-all
             (not (=? num-vector-comparator '#(1 2 3) '#(4 5 6))))
  (test-assert 'constructors-vector-not-equal-tail
             (not (=? num-vector-comparator '#(1 2 3) '#(1 5 6))))
  (test-assert 'constructors-vector-not-equal-last
             (not (=? num-vector-comparator '#(1 2 3) '#(1 2 6))))
  (test-assert 'constructors-vector-less-shorter
             (<? num-vector-comparator '#(1 2) '#(1 2 3)))
  (test-assert 'constructors-vector-less-first
             (<? num-vector-comparator '#(1 2 3) '#(2 3 4)))
  (test-assert 'constructors-vector-less-second
             (<? num-vector-comparator '#(1 2 3) '#(1 3 4)))
  (test-assert 'constructors-vector-less-third
             (<? num-vector-comparator '#(1 2 3) '#(1 2 4)))
  (test-assert 'constructors-vector-length-precedes-elements
             (<? num-vector-comparator '#(3 4) '#(1 2 3)))
  (test-assert 'constructors-vector-not-less-same
             (not (<? num-vector-comparator '#(1 2 3) '#(1 2 3))))
  (test-assert 'constructors-vector-not-less-longer
             (not (<? num-vector-comparator '#(1 2 3) '#(1 2))))
  (test-assert 'constructors-vector-not-less-first
             (not (<? num-vector-comparator '#(1 2 3) '#(0 2 3))))
  (test-assert 'constructors-vector-not-less-second
             (not (<? num-vector-comparator '#(1 2 3) '#(1 1 3))))

  (test-assert 'constructors-vector-as-list-uses-list-order
             (not (<? vector-qua-list-comparator '#(3 4) '#(1 2 3))))
  (test-assert 'constructors-list-as-vector-uses-vector-order
             (<? list-qua-vector-comparator '(3 4) '(1 2 3)))

  (let ((bool-pair (cons #t #f))
        (bool-pair-2 (cons #t #f))
        (reverse-bool-pair (cons #f #t)))
    (test-assert 'constructors-eq-true
             (=? eq-comparator #t #t))
    (test-assert 'constructors-eq-false
             (not (=? eq-comparator #f #t)))
    (test-assert 'constructors-eqv-same-pair
             (=? eqv-comparator bool-pair bool-pair))
    (test-assert 'constructors-eqv-distinct-pairs
             (not (=? eqv-comparator bool-pair bool-pair-2)))
    (test-assert 'constructors-equal-distinct-pairs
             (=? equal-comparator bool-pair bool-pair-2))
    (test-assert 'constructors-equal-reversed-pair
             (not (=? equal-comparator bool-pair reverse-bool-pair))))

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
  (test-equal 'hash-char-ci-folds
             (char-ci-hash #\A)
             (char-ci-hash #\a))
  (check-exact-nonnegative-integer 'hash-string
                                   (string-hash "f"))
  (check-exact-nonnegative-integer 'hash-string-other
                                   (string-hash "g"))
  (check-exact-nonnegative-integer 'hash-string-ci
                                   (string-ci-hash "f"))
  (check-exact-nonnegative-integer 'hash-string-ci-other
                                   (string-ci-hash "g"))
  (test-equal 'hash-string-ci-folds
             (string-ci-hash "F")
             (string-ci-hash "f"))
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

  (test-assert 'default-null-before-list
             (<? default-comparator '() '(a)))
  (test-assert 'default-null-not-equal-list
             (not (=? default-comparator '() '(a))))
  (test-assert 'default-boolean-equal
             (=? default-comparator #t #t))
  (test-assert 'default-boolean-not-equal
             (not (=? default-comparator #t #f)))
  (test-assert 'default-boolean-less
             (<? default-comparator #f #t))
  (test-assert 'default-boolean-not-less-same
             (not (<? default-comparator #t #t)))
  (test-assert 'default-char-equal
             (=? default-comparator #\a #\a))
  (test-assert 'default-char-less
             (<? default-comparator #\a #\b))

  (test-assert 'default-type-null
             (comparator-test-type default-comparator '()))
  (test-assert 'default-type-boolean
             (comparator-test-type default-comparator #t))
  (test-assert 'default-type-char
             (comparator-test-type default-comparator #\t))
  (test-assert 'default-type-pair
             (comparator-test-type default-comparator '(a)))
  (test-assert 'default-type-symbol
             (comparator-test-type default-comparator 'a))
  (test-assert 'default-type-bytevector
             (comparator-test-type default-comparator (make-bytevector 10)))
  (test-assert 'default-type-exact-number
             (comparator-test-type default-comparator 10))
  (test-assert 'default-type-inexact-number
             (comparator-test-type default-comparator 10.0))
  (test-assert 'default-type-string
             (comparator-test-type default-comparator "10.0"))
  (test-assert 'default-type-vector
             (comparator-test-type default-comparator '#(10)))

  (test-assert 'default-pair-equal
             (=? default-comparator '(#t . #t) '(#t . #t)))
  (test-assert 'default-pair-not-equal-car
             (not (=? default-comparator '(#t . #t) '(#f . #t))))
  (test-assert 'default-pair-not-equal-cdr
             (not (=? default-comparator '(#t . #t) '(#t . #f))))
  (test-assert 'default-pair-less-car
             (<? default-comparator '(#f . #t) '(#t . #t)))
  (test-assert 'default-pair-less-cdr
             (<? default-comparator '(#t . #f) '(#t . #t)))
  (test-assert 'default-pair-not-less-same
             (not (<? default-comparator '(#t . #t) '(#t . #t))))
  (test-assert 'default-pair-not-less-reversed-car
             (not (<? default-comparator '(#t . #t) '(#f . #t))))
  (test-assert 'default-vector-not-less-reversed-cdr
             (not (<? default-comparator '#(#f #t) '#(#f #f))))

  (test-assert 'default-vector-equal
             (=? default-comparator '#(#t #t) '#(#t #t)))
  (test-assert 'default-vector-not-equal-first
             (not (=? default-comparator '#(#t #t) '#(#f #t))))
  (test-assert 'default-vector-not-equal-second
             (not (=? default-comparator '#(#t #t) '#(#t #f))))
  (test-assert 'default-vector-less-first
             (<? default-comparator '#(#f #t) '#(#t #t)))
  (test-assert 'default-vector-less-second
             (<? default-comparator '#(#t #f) '#(#t #t)))
  (test-assert 'default-vector-not-less-same
             (not (<? default-comparator '#(#t #t) '#(#t #t))))
  (test-assert 'default-vector-not-less-reversed-first
             (not (<? default-comparator '#(#t #t) '#(#f #t))))
  (test-assert 'default-vector-not-less-reversed-second
             (not (<? default-comparator '#(#f #t) '#(#f #f))))

  (test-equal 'default-hash-boolean
             (boolean-hash #t)
             (comparator-hash default-comparator #t))
  (test-equal 'default-hash-char
             (char-hash #\t)
             (comparator-hash default-comparator #\t))
  (test-equal 'default-hash-string
             (string-hash "t")
             (comparator-hash default-comparator "t"))
  (test-equal 'default-hash-symbol
             (symbol-hash 't)
             (comparator-hash default-comparator 't))
  (test-equal 'default-hash-exact-number
             (number-hash 10)
             (comparator-hash default-comparator 10))
  (test-equal 'default-hash-inexact-number
             (number-hash 10.0)
             (comparator-hash default-comparator 10.0))

  (comparator-register-default!
   (make-comparator
    procedure?
    (lambda (a b) #t)
    (lambda (a b) #f)
    (lambda (obj) 200)))
  (test-assert 'default-registered-procedure-equal
             (=? default-comparator (lambda () #t) (lambda () #f)))
  (test-assert 'default-registered-procedure-not-less
             (not (<? default-comparator (lambda () #t) (lambda () #f))))
  (test-equal 'default-registered-procedure-hash
             200
             (comparator-hash default-comparator (lambda () #t)))

  (let* ((x1 0)
         (x2 0)
         (x3 0)
         (x4 0)
         (ttp (lambda (x) (set! x1 111) #t))
         (eqp (lambda (x y) (set! x2 222) #t))
         (orp (lambda (x y) (set! x3 333) #t))
         (hf (lambda (x) (set! x4 444) 0)))
    (let ((comp (make-comparator ttp eqp orp hf)))
      (test-assert 'accessors-type-test-invokes-original
             (and ((comparator-type-test-predicate comp) x1)
                       (= x1 111)))
      (test-assert 'accessors-equality-invokes-original
             (and ((comparator-equality-predicate comp) x1 x2)
                       (= x2 222)))
      (test-assert 'accessors-ordering-invokes-original
             (and ((comparator-ordering-predicate comp) x1 x3)
                       (= x3 333)))
      (test-assert 'accessors-hash-invokes-original
             (and (zero? ((comparator-hash-function comp) x1))
                       (= x4 444)))))

  (test-assert 'invokers-real-exact
             (comparator-test-type real-comparator 3))
  (test-assert 'invokers-real-inexact
             (comparator-test-type real-comparator 3.0))
  (test-assert 'invokers-real-rejects-string
             (not (comparator-test-type real-comparator "3.0")))
  (test-assert 'invokers-check-type-accepts
             (comparator-check-type boolean-comparator #t))
  (test-assert 'invokers-check-type-rejects
             (raises?
               (lambda ()
                 (comparator-check-type boolean-comparator 't))))

  (test-assert 'comparison-equal-chain
             (=? real-comparator 2 2.0 2))
  (test-assert 'comparison-less-chain
             (<? real-comparator 2 3.0 4))
  (test-assert 'comparison-greater-chain
             (>? real-comparator 4.0 3.0 2))
  (test-assert 'comparison-less-equal-chain
             (<=? real-comparator 2.0 2 3.0))
  (test-assert 'comparison-greater-equal-chain
             (>=? real-comparator 3 3.0 2))
  (test-assert 'comparison-not-equal-chain
             (not (=? real-comparator 1 2 3)))
  (test-assert 'comparison-not-less-chain
             (not (<? real-comparator 3 1 2)))
  (test-assert 'comparison-not-greater-chain
             (not (>? real-comparator 1 2 3)))
  (test-assert 'comparison-not-less-equal-chain
             (not (<=? real-comparator 4 3 3)))
  (test-assert 'comparison-not-greater-equal-chain
             (not (>=? real-comparator 3 4 4.0)))

  (test-equal 'syntax-less
             'less
             (comparator-if<=> real-comparator 1 2 'less 'equal 'greater))
  (test-equal 'syntax-equal
             'equal
             (comparator-if<=> real-comparator 1 1 'less 'equal 'greater))
  (test-equal 'syntax-greater
             'greater
             (comparator-if<=> real-comparator 2 1 'less 'equal 'greater))
  (test-equal 'syntax-default-less
             'less
             (comparator-if<=> "1" "2" 'less 'equal 'greater))
  (test-equal 'syntax-default-equal
             'equal
             (comparator-if<=> "1" "1" 'less 'equal 'greater))
  (test-equal 'syntax-default-greater
             'greater
             (comparator-if<=> "2" "1" 'less 'equal 'greater))

  (check-exact-nonnegative-integer 'bound-hash-bound
                                   (hash-bound))
  (check-exact-nonnegative-integer 'bound-hash-salt
                                   (hash-salt))
  (test-assert 'bound-salt-less-than-bound
             (< (hash-salt) (hash-bound)))

  ;; Keep one use of the custom symbol comparator from the upstream setup.
  (test-assert 'constructors-symbol-comparator-less
             (<? symbol-comparator 'alpha 'beta))
  (test-assert 'constructors-list-comparator-equal
             (=? num-list-comparator '(1 2) '(1 2)))
  (test-assert 'constructors-list-comparator-less
             (<? num-list-comparator '(1 2) '(1 3)))))

(testing-runner-main "Stdlib Comparator portable tests" (command-line))
