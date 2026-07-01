;;; R7RS-large comparator library, adapted from SRFI 128 for stdlib-plus.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2015 John Cowan <cowan@ccil.org>
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(scheme comparator)` using the official SRFI 128 sample at
;;; https://github.com/scheme-requests-for-implementation/srfi-128.
;;; Local patches inline the upstream body files for Consent Scheme's
;;; source-library loader, document the exported procedures with Consent Scheme
;;; metadata, use a local portable `default-hash`, and keep `(srfi 128)` and
;;; `(srfi srfi-128)` as registry aliases.

(define-library (scheme comparator)
  (export comparator? comparator-ordered? comparator-hashable?
          make-comparator
          make-pair-comparator make-list-comparator make-vector-comparator
          make-eq-comparator make-eqv-comparator make-equal-comparator
          boolean-hash char-hash char-ci-hash
          string-hash string-ci-hash symbol-hash number-hash
          make-default-comparator default-hash comparator-register-default!
          comparator-type-test-predicate comparator-equality-predicate
          comparator-ordering-predicate comparator-hash-function
          comparator-test-type comparator-check-type comparator-hash
          hash-bound hash-salt
          =? <? >? <=? >=?
          comparator-if<=>)
  (import (scheme base)
          (scheme case-lambda)
          (scheme char)
          (scheme inexact)
          (scheme complex))
  (begin
    ;; Branch on a comparator result, using a default comparator when the
    ;; comparator operand is omitted.
    (define-syntax comparator-if<=>
      (syntax-rules ()
        ((comparator-if<=> a b less equal greater)
         (comparator-if<=> (make-default-comparator)
                           a b less equal greater))
        ((comparator-if<=> comparator a b less equal greater)
         (cond
          ((=? comparator a b) equal)
          ((<? comparator a b) less)
          (else greater)))))

    ;; SRFI 128 hash functions in this implementation share one fixed bound.
    (define-syntax hash-bound
      (syntax-rules ()
        ((hash-bound) comparator-hash-bound)))

    ;; SRFI 128 exposes the current hash salt as syntax.
    (define-syntax hash-salt
      (syntax-rules ()
        ((hash-salt) (comparator-hash-salt))))

    ;; Upper bound used by portable hash helpers.
    (define comparator-hash-bound 33554432)

    ;; Parameter holding the deterministic portable hash salt.
    (define comparator-hash-salt (make-parameter 16064047))

    ;; Internal comparator record. Public predicates and accessors are
    ;; documented wrappers so exported procedures carry runtime metadata.
    (define-record-type <comparator>
      (make-raw-comparator type-test equality ordering hash ordering? hash?)
      raw-comparator?
      (type-test raw-comparator-type-test-predicate)
      (equality raw-comparator-equality-predicate)
      (ordering raw-comparator-ordering-predicate)
      (hash raw-comparator-hash-function)
      (ordering? raw-comparator-ordered?)
      (hash? raw-comparator-hashable?))

    (define (comparator? obj)
      "Return #t when OBJ is a SRFI 128 comparator."
      #((parameters
         (obj (type any)
          (description "Candidate object to test.")))
        (returns (type boolean)
         (description "Whether OBJ is a comparator."))
        (effects pure))
      (raw-comparator? obj))

    (define (comparator-ordered? comparator)
      "Return #t when COMPARATOR has an ordering predicate."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to inspect.")))
        (returns (type boolean)
         (description "Whether COMPARATOR supports ordering."))
        (effects pure))
      (raw-comparator-ordered? comparator))

    (define (comparator-hashable? comparator)
      "Return #t when COMPARATOR has a hash function."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to inspect.")))
        (returns (type boolean)
         (description "Whether COMPARATOR supports hashing."))
        (effects pure))
      (raw-comparator-hashable? comparator))

    (define (unsupported-ordering x y)
      "Signal an error for a comparator without ordering support."
      (error "ordering not supported" x y))

    (define (unsupported-hash x)
      "Signal an error for a comparator without hashing support."
      (error "hashing not supported" x))

    (define (make-comparator type-test equality ordering hash)
      "Return a comparator from type, equality, ordering, and hash procedures."
      #((parameters
         (type-test (type (or procedure boolean))
          (description
           ("Predicate accepting values handled by the comparator, or #t"
            "for an unrestricted comparator.")))
         (equality (type procedure)
          (description "Two-argument comparator equality predicate."))
         (ordering (type (or procedure boolean))
          (description
           ("Two-argument ordering predicate, or #f when ordering is"
            "unsupported.")))
         (hash (type (or procedure boolean))
          (description
           ("One-argument hash function, or #f when hashing is"
            "unsupported."))))
        (returns (type comparator)
         (description "A SRFI 128 comparator bundling those procedures."))
        (effects pure))
      (make-raw-comparator
       (if (eq? type-test #t) (lambda (x) #t) type-test)
       equality
       (if ordering ordering unsupported-ordering)
       (if hash hash unsupported-hash)
       (if ordering #t #f)
       (if hash #t #f)))

    (define (comparator-type-test-predicate comparator)
      "Return COMPARATOR's type-test predicate."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to inspect.")))
        (returns (type procedure)
         (description "The comparator's one-argument type predicate."))
        (effects pure))
      (raw-comparator-type-test-predicate comparator))

    (define (comparator-equality-predicate comparator)
      "Return COMPARATOR's equality predicate."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to inspect.")))
        (returns (type procedure)
         (description "The comparator's two-argument equality predicate."))
        (effects pure))
      (raw-comparator-equality-predicate comparator))

    (define (comparator-ordering-predicate comparator)
      "Return COMPARATOR's ordering predicate."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to inspect.")))
        (returns (type procedure)
         (description "The comparator's two-argument ordering predicate."))
        (effects pure))
      (raw-comparator-ordering-predicate comparator))

    (define (comparator-hash-function comparator)
      "Return COMPARATOR's hash function."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to inspect.")))
        (returns (type procedure)
         (description "The comparator's one-argument hash function."))
        (effects pure))
      (raw-comparator-hash-function comparator))

    (define (comparator-test-type comparator obj)
      "Apply COMPARATOR's type predicate to OBJ."
      #((parameters
         (comparator (type comparator)
          (description "Comparator whose type predicate is invoked."))
         (obj (type any)
          (description "Candidate object to test.")))
        (returns (type boolean)
         (description "Whether OBJ satisfies COMPARATOR's type predicate."))
        (effects pure))
      ((comparator-type-test-predicate comparator) obj))

    (define (comparator-check-type comparator obj)
      "Return #t when OBJ satisfies COMPARATOR, else signal an error."
      #((parameters
         (comparator (type comparator)
          (description "Comparator whose type predicate is invoked."))
         (obj (type any)
          (description "Candidate object to validate.")))
        (returns (type boolean)
         (description "#t when OBJ satisfies COMPARATOR."))
        (effects error))
      (if (comparator-test-type comparator obj)
          #t
          (error "comparator type check failed" comparator obj)))

    (define (comparator-hash comparator obj)
      "Hash OBJ with COMPARATOR's hash function."
      #((parameters
         (comparator (type comparator)
          (description "Comparator whose hash function is invoked."))
         (obj (type any)
          (description "Object to hash.")))
        (returns (type exact-non-negative-integer)
         (description "Hash value for OBJ under COMPARATOR."))
        (effects error))
      ((comparator-hash-function comparator) obj))

    (define (binary=? comparator a b)
      "Return whether A and B are equal under COMPARATOR."
      ((comparator-equality-predicate comparator) a b))

    (define (binary<? comparator a b)
      "Return whether A precedes B under COMPARATOR."
      ((comparator-ordering-predicate comparator) a b))

    (define (binary>? comparator a b)
      "Return whether A follows B under COMPARATOR."
      (binary<? comparator b a))

    (define (binary<=? comparator a b)
      "Return whether A does not follow B under COMPARATOR."
      (not (binary>? comparator a b)))

    (define (binary>=? comparator a b)
      "Return whether A does not precede B under COMPARATOR."
      (not (binary<? comparator a b)))

    (define (=? comparator a b . objs)
      "Return #t when each adjacent object is equal under COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to apply."))
         (a (type any)
          (description "First object."))
         (b (type any)
          (description "Second object."))
         (objs (type list)
          (description "Additional objects to compare in order.")))
        (returns (type boolean)
         (description "Whether every adjacent object compares equal."))
        (effects error))
      (let loop ((a a) (b b) (objs objs))
        (and (binary=? comparator a b)
             (if (null? objs) #t (loop b (car objs) (cdr objs))))))

    (define (<? comparator a b . objs)
      "Return #t when objects are strictly increasing under COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to apply."))
         (a (type any)
          (description "First object."))
         (b (type any)
          (description "Second object."))
         (objs (type list)
          (description "Additional objects to compare in order.")))
        (returns (type boolean)
         (description "Whether every adjacent object is ordered upward."))
        (effects error))
      (let loop ((a a) (b b) (objs objs))
        (and (binary<? comparator a b)
             (if (null? objs) #t (loop b (car objs) (cdr objs))))))

    (define (>? comparator a b . objs)
      "Return #t when objects are strictly decreasing under COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to apply."))
         (a (type any)
          (description "First object."))
         (b (type any)
          (description "Second object."))
         (objs (type list)
          (description "Additional objects to compare in order.")))
        (returns (type boolean)
         (description "Whether every adjacent object is ordered downward."))
        (effects error))
      (let loop ((a a) (b b) (objs objs))
        (and (binary>? comparator a b)
             (if (null? objs) #t (loop b (car objs) (cdr objs))))))

    (define (<=? comparator a b . objs)
      "Return #t when objects are nondecreasing under COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to apply."))
         (a (type any)
          (description "First object."))
         (b (type any)
          (description "Second object."))
         (objs (type list)
          (description "Additional objects to compare in order.")))
        (returns (type boolean)
         (description "Whether every adjacent object is nondecreasing."))
        (effects error))
      (let loop ((a a) (b b) (objs objs))
        (and (binary<=? comparator a b)
             (if (null? objs) #t (loop b (car objs) (cdr objs))))))

    (define (>=? comparator a b . objs)
      "Return #t when objects are nonincreasing under COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to apply."))
         (a (type any)
          (description "First object."))
         (b (type any)
          (description "Second object."))
         (objs (type list)
          (description "Additional objects to compare in order.")))
        (returns (type boolean)
         (description "Whether every adjacent object is nonincreasing."))
        (effects error))
      (let loop ((a a) (b b) (objs objs))
        (and (binary>=? comparator a b)
             (if (null? objs) #t (loop b (car objs) (cdr objs))))))

    (define (boolean<? a b)
      "Return #t exactly when A is #f and B is #t."
      (and (not a) b))

    (define (bounded-hash value)
      "Return VALUE reduced into the portable SRFI 128 hash bound."
      (modulo value (hash-bound)))

    (define (boolean-hash obj)
      "Return a hash value for boolean OBJ."
      #((parameters
         (obj (type boolean)
          (description "Boolean object to hash.")))
        (returns (type exact-non-negative-integer)
         (description "Hash value for OBJ."))
        (effects pure))
      (if obj (hash-salt) 0))

    (define (char-hash obj)
      "Return a hash value for character OBJ."
      #((parameters
         (obj (type char)
          (description "Character object to hash.")))
        (returns (type exact-non-negative-integer)
         (description "Hash value for OBJ."))
        (effects pure))
      (bounded-hash (* (hash-salt) (char->integer obj))))

    (define (char-ci-hash obj)
      "Return a case-insensitive hash value for character OBJ."
      #((parameters
         (obj (type char)
          (description "Character object to hash case-insensitively.")))
        (returns (type exact-non-negative-integer)
         (description "Case-insensitive hash value for OBJ."))
        (effects pure))
      (bounded-hash (* (hash-salt) (char->integer (char-foldcase obj)))))

    (define (number-hash obj)
      "Return a hash value for number OBJ."
      #((parameters
         (obj (type number)
          (description "Number object to hash.")))
        (returns (type exact-non-negative-integer)
         (description "Hash value for OBJ."))
        (effects pure))
      (bounded-hash
       (cond
        ((not (real? obj))
         (+ (number-hash (real-part obj))
            (number-hash (imag-part obj))))
        ((nan? obj) (hash-salt))
        ((and (infinite? obj) (positive? obj)) (* 2 (hash-salt)))
        ((infinite? obj) (* 3 (hash-salt)))
        (else (abs (exact (round obj)))))))

    (define (complex<? a b)
      "Order complex numbers lexicographically by real then imaginary part."
      (if (= (real-part a) (real-part b))
          (< (imag-part a) (imag-part b))
          (< (real-part a) (real-part b))))

    (define (make-hasher)
      "Return a stateful sequence hasher procedure."
      (let ((result (hash-salt)))
        (case-lambda
         (() result)
         ((n)
          (set! result (bounded-hash (+ (* result 33) n)))
          result))))

    (define (string-hash obj)
      "Return a hash value for string OBJ."
      #((parameters
         (obj (type string)
          (description "String object to hash.")))
        (returns (type exact-non-negative-integer)
         (description "Hash value for OBJ."))
        (effects pure))
      (let ((acc (make-hasher))
            (len (string-length obj)))
        (let loop ((n 0))
          (cond
           ((= n len) (acc))
           (else
            (acc (char->integer (string-ref obj n)))
            (loop (+ n 1)))))))

    (define (string-ci-hash obj)
      "Return a case-insensitive hash value for string OBJ."
      #((parameters
         (obj (type string)
          (description "String object to hash case-insensitively.")))
        (returns (type exact-non-negative-integer)
         (description "Case-insensitive hash value for OBJ."))
        (effects pure))
      (string-hash (string-foldcase obj)))

    (define (symbol<? a b)
      "Order symbols by their implementation string spelling."
      (string<? (symbol->string a) (symbol->string b)))

    (define (symbol-hash obj)
      "Return a hash value for symbol OBJ."
      #((parameters
         (obj (type symbol)
          (description "Symbol object to hash.")))
        (returns (type exact-non-negative-integer)
         (description "Hash value for OBJ."))
        (effects pure))
      (string-hash (symbol->string obj)))

    (define (make-eq-comparator)
      "Return an equality-only comparator using eq?."
      #((parameters)
        (returns (type comparator)
         (description "A comparator whose equality predicate is eq?."))
        (effects pure))
      (make-comparator #t eq? #f default-hash))

    (define (make-eqv-comparator)
      "Return an equality-only comparator using eqv?."
      #((parameters)
        (returns (type comparator)
         (description "A comparator whose equality predicate is eqv?."))
        (effects pure))
      (make-comparator #t eqv? #f default-hash))

    (define (make-equal-comparator)
      "Return an equality-only comparator using equal?."
      #((parameters)
        (returns (type comparator)
         (description "A comparator whose equality predicate is equal?."))
        (effects pure))
      (make-comparator #t equal? #f default-hash))

    (define (make-pair-type-test car-comparator cdr-comparator)
      "Return a pair type predicate over CAR-COMPARATOR and CDR-COMPARATOR."
      (lambda (obj)
        (and (pair? obj)
             (comparator-test-type car-comparator (car obj))
             (comparator-test-type cdr-comparator (cdr obj)))))

    (define (make-pair=? car-comparator cdr-comparator)
      "Return pair equality over CAR-COMPARATOR and CDR-COMPARATOR."
      (lambda (a b)
        (and ((comparator-equality-predicate car-comparator) (car a) (car b))
             ((comparator-equality-predicate cdr-comparator) (cdr a) (cdr b)))))

    (define (make-pair<? car-comparator cdr-comparator)
      "Return lexicographic pair ordering over two component comparators."
      (lambda (a b)
        (if (=? car-comparator (car a) (car b))
            (<? cdr-comparator (cdr a) (cdr b))
            (<? car-comparator (car a) (car b)))))

    (define (make-pair-hash car-comparator cdr-comparator)
      "Return pair hashing over CAR-COMPARATOR and CDR-COMPARATOR."
      (lambda (obj)
        (let ((acc (make-hasher)))
          (acc (comparator-hash car-comparator (car obj)))
          (acc (comparator-hash cdr-comparator (cdr obj)))
          (acc))))

    (define (make-pair-comparator car-comparator cdr-comparator)
      "Return a comparator for pairs using component comparators."
      #((parameters
         (car-comparator (type comparator)
          (description "Comparator used for pair cars."))
         (cdr-comparator (type comparator)
          (description "Comparator used for pair cdrs.")))
        (returns (type comparator)
         (description "A comparator over pairs."))
        (effects pure))
      (make-comparator
       (make-pair-type-test car-comparator cdr-comparator)
       (make-pair=? car-comparator cdr-comparator)
       (make-pair<? car-comparator cdr-comparator)
       (make-pair-hash car-comparator cdr-comparator)))

    (define (make-list-type-test element-comparator type-test empty? head tail)
      "Return a list-like type predicate over ELEMENT-COMPARATOR."
      (lambda (obj)
        (and
         (type-test obj)
         (let ((elem-type-test
                (comparator-type-test-predicate element-comparator)))
           (let loop ((obj obj))
             (cond
              ((empty? obj) #t)
              ((not (elem-type-test (head obj))) #f)
              (else (loop (tail obj)))))))))

    (define (make-list=? element-comparator type-test empty? head tail)
      "Return list-like equality over ELEMENT-COMPARATOR."
      (lambda (a b)
        (let ((elem=? (comparator-equality-predicate element-comparator)))
          (let loop ((a a) (b b))
            (cond
             ((and (empty? a) (empty? b)) #t)
             ((empty? a) #f)
             ((empty? b) #f)
             ((elem=? (head a) (head b)) (loop (tail a) (tail b)))
             (else #f))))))

    (define (make-list<? element-comparator type-test empty? head tail)
      "Return lexicographic list-like ordering over ELEMENT-COMPARATOR."
      (lambda (a b)
        (let ((elem=? (comparator-equality-predicate element-comparator))
              (elem<? (comparator-ordering-predicate element-comparator)))
          (let loop ((a a) (b b))
            (cond
             ((and (empty? a) (empty? b)) #f)
             ((empty? a) #t)
             ((empty? b) #f)
             ((elem=? (head a) (head b)) (loop (tail a) (tail b)))
             ((elem<? (head a) (head b)) #t)
             (else #f))))))

    (define (make-list-hash element-comparator type-test empty? head tail)
      "Return list-like hashing over ELEMENT-COMPARATOR."
      (lambda (obj)
        (let ((elem-hash (comparator-hash-function element-comparator))
              (acc (make-hasher)))
          (let loop ((obj obj))
            (cond
             ((empty? obj) (acc))
             (else
              (acc (elem-hash (head obj)))
              (loop (tail obj))))))))

    (define (make-list-comparator element-comparator type-test empty? head tail)
      "Return a comparator for list-like sequences."
      #((parameters
         (element-comparator (type comparator)
          (description "Comparator used for sequence elements."))
         (type-test (type procedure)
          (description "Predicate accepting the sequence type."))
         (empty? (type procedure)
          (description "Predicate identifying empty sequences."))
         (head (type procedure)
          (description "Procedure returning the first element."))
         (tail (type procedure)
          (description "Procedure returning the remaining sequence.")))
        (returns (type comparator)
         (description "A comparator over list-like sequences."))
        (effects pure))
      (make-comparator
       (make-list-type-test element-comparator type-test empty? head tail)
       (make-list=? element-comparator type-test empty? head tail)
       (make-list<? element-comparator type-test empty? head tail)
       (make-list-hash element-comparator type-test empty? head tail)))

    (define (make-vector-type-test element-comparator type-test length ref)
      "Return a vector-like type predicate over ELEMENT-COMPARATOR."
      (lambda (obj)
        (and
         (type-test obj)
         (let ((elem-type-test
                (comparator-type-test-predicate element-comparator))
               (len (length obj)))
           (let loop ((n 0))
             (cond
              ((= n len) #t)
              ((not (elem-type-test (ref obj n))) #f)
              (else (loop (+ n 1)))))))))

    (define (make-vector=? element-comparator type-test length ref)
      "Return vector-like equality over ELEMENT-COMPARATOR."
      (lambda (a b)
        (and
         (= (length a) (length b))
         (let ((elem=? (comparator-equality-predicate element-comparator))
               (len (length b)))
           (let loop ((n 0))
             (cond
              ((= n len) #t)
              ((elem=? (ref a n) (ref b n)) (loop (+ n 1)))
              (else #f)))))))

    (define (make-vector<? element-comparator type-test length ref)
      "Return lexicographic vector-like ordering over ELEMENT-COMPARATOR."
      (lambda (a b)
        (cond
         ((< (length a) (length b)) #t)
         ((> (length a) (length b)) #f)
         (else
          (let ((elem=? (comparator-equality-predicate element-comparator))
                (elem<? (comparator-ordering-predicate element-comparator))
                (len (length a)))
            (let loop ((n 0))
              (cond
               ((= n len) #f)
               ((elem=? (ref a n) (ref b n)) (loop (+ n 1)))
               ((elem<? (ref a n) (ref b n)) #t)
               (else #f))))))))

    (define (make-vector-hash element-comparator type-test length ref)
      "Return vector-like hashing over ELEMENT-COMPARATOR."
      (lambda (obj)
        (let ((elem-hash (comparator-hash-function element-comparator))
              (acc (make-hasher))
              (len (length obj)))
          (let loop ((n 0))
            (cond
             ((= n len) (acc))
             (else
              (acc (elem-hash (ref obj n)))
              (loop (+ n 1))))))))

    (define (make-vector-comparator element-comparator type-test length ref)
      "Return a comparator for vector-like sequences."
      #((parameters
         (element-comparator (type comparator)
          (description "Comparator used for sequence elements."))
         (type-test (type procedure)
          (description "Predicate accepting the sequence type."))
         (length (type procedure)
          (description "Procedure returning the sequence length."))
         (ref (type procedure)
          (description "Procedure returning the element at an index.")))
        (returns (type comparator)
         (description "A comparator over vector-like sequences."))
        (effects pure))
      (make-comparator
       (make-vector-type-test element-comparator type-test length ref)
       (make-vector=? element-comparator type-test length ref)
       (make-vector<? element-comparator type-test length ref)
       (make-vector-hash element-comparator type-test length ref)))

    ;; Fallback comparator used for otherwise unknown values.
    (define unknown-object-comparator
      (make-comparator
       (lambda (obj) #t)
       (lambda (a b) #t)
       (lambda (a b) #f)
       (lambda (obj) 0)))

    ;; First type ordinal reserved for registered default comparators.
    (define first-comparator-index 9)

    ;; Default-comparator extension registry, newest comparator first.
    (define default-comparator-registry (list unknown-object-comparator))

    (define (comparator-register-default! comparator)
      "Register COMPARATOR as an extension for default comparators."
      #((parameters
         (comparator (type comparator)
          (description "Comparator to add to the default-comparator registry.")))
        (returns . ("An unspecified value after updating the registry."))
        (effects state-write))
      (set! default-comparator-registry
            (cons comparator default-comparator-registry)))

    (define (registered-index obj)
      "Return the default-comparator registry index for OBJ."
      (let loop ((index first-comparator-index)
                 (registry default-comparator-registry))
        (cond
         ((null? registry) index)
         ((comparator-test-type (car registry) obj) index)
         (else (loop (+ index 1) (cdr registry))))))

    (define (registered-comparator index)
      "Return registered comparator at default-comparator INDEX."
      (list-ref default-comparator-registry
                (- index first-comparator-index)))

    (define (object-type obj)
      "Return the default comparator type ordinal for OBJ."
      (cond
       ((null? obj) 0)
       ((pair? obj) 1)
       ((boolean? obj) 2)
       ((char? obj) 3)
       ((string? obj) 4)
       ((symbol? obj) 5)
       ((number? obj) 6)
       ((vector? obj) 7)
       ((bytevector? obj) 8)
       (else (registered-index obj))))

    (define (byte-comparator)
      "Return a comparator for bytevector element values."
      (make-comparator exact-integer? = < number-hash))

    (define (dispatch-equality type a b)
      "Dispatch default equality for same-type objects A and B."
      (case type
        ((0) #t)
        ((1)
         ((make-pair=? (make-default-comparator) (make-default-comparator))
          a b))
        ((2) (boolean=? a b))
        ((3) (char=? a b))
        ((4) (string=? a b))
        ((5) (symbol=? a b))
        ((6) (= a b))
        ((7)
         ((make-vector=? (make-default-comparator)
                         vector? vector-length vector-ref)
          a b))
        ((8)
         ((make-vector=? (byte-comparator)
                         bytevector? bytevector-length bytevector-u8-ref)
          a b))
        (else (binary=? (registered-comparator type) a b))))

    (define (dispatch-ordering type a b)
      "Dispatch default ordering for same-type objects A and B."
      (case type
        ((0) #f)
        ((1)
         ((make-pair<? (make-default-comparator) (make-default-comparator))
          a b))
        ((2) (boolean<? a b))
        ((3) (char<? a b))
        ((4) (string<? a b))
        ((5) (symbol<? a b))
        ((6) (complex<? a b))
        ((7)
         ((make-vector<? (make-default-comparator) vector? vector-length vector-ref)
          a b))
        ((8)
         ((make-vector<? (byte-comparator)
                         bytevector? bytevector-length bytevector-u8-ref)
          a b))
        (else (binary<? (registered-comparator type) a b))))

    (define (default-hash obj)
      "Return the default comparator hash for OBJ."
      #((parameters
         (obj (type any)
          (description "Object to hash with the default hash function.")))
        (returns (type exact-non-negative-integer)
         (description "Default hash value for OBJ."))
        (effects error))
      (case (object-type obj)
        ((0) ((make-hasher)))
        ((1)
         ((make-pair-hash (make-default-comparator) (make-default-comparator))
          obj))
        ((2) (boolean-hash obj))
        ((3) (char-hash obj))
        ((4) (string-hash obj))
        ((5) (symbol-hash obj))
        ((6) (number-hash obj))
        ((7)
         ((make-vector-hash (make-default-comparator)
                            vector? vector-length vector-ref)
          obj))
        ((8)
         ((make-vector-hash (byte-comparator)
                            bytevector? bytevector-length bytevector-u8-ref)
          obj))
        (else (comparator-hash (registered-comparator (object-type obj)) obj))))

    (define (default-ordering a b)
      "Return whether A precedes B under the default comparator."
      (let ((a-type (object-type a))
            (b-type (object-type b)))
        (cond
         ((< a-type b-type) #t)
         ((> a-type b-type) #f)
         (else (dispatch-ordering a-type a b)))))

    (define (default-equality a b)
      "Return whether A and B are equal under the default comparator."
      (let ((a-type (object-type a))
            (b-type (object-type b)))
        (if (= a-type b-type)
            (dispatch-equality a-type a b)
            #f)))

    (define (make-default-comparator)
      "Return the implementation default comparator."
      #((parameters)
        (returns (type comparator)
         (description "A comparator accepting ordinary Scheme values."))
        (effects state-read))
      (make-comparator
       (lambda (obj) #t)
       default-equality
       default-ordering
       default-hash))))
