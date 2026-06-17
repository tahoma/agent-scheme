;;; Portable derived bindings for the initial `(scheme base)' environment.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This file is loaded as ordinary Scheme source by both evaluator
;;; implementations after the kernel primitives are installed.  Keep
;;; definitions small and self-contained: metadata extraction expects each
;;; top-level form to be one `define'.

(define (not obj)
  "Return #t when OBJ is #f, otherwise return #f."
  (if obj #f #t))

(define (list . items)
  "Return a newly allocated list containing ITEMS."
  items)

(define (caar pair)
  "Return the car of the car of PAIR."
  (car (car pair)))

(define (cadr pair)
  "Return the car of the cdr of PAIR."
  (car (cdr pair)))

(define (cdar pair)
  "Return the cdr of the car of PAIR."
  (cdr (car pair)))

(define (cddr pair)
  "Return the cdr of the cdr of PAIR."
  (cdr (cdr pair)))

(define (length list)
  (define (loop cursor count)
    "R7RS requires a proper list; reaching a non-pair tail forces an error"
    "through a primitive operation instead of silently accepting dotted input."
    (if (null? cursor)
        count
        (if (pair? cursor)
            (loop (cdr cursor) (+ count 1))
            (car cursor))))
  "Return the number of pairs in LIST."
  (loop list 0))

(define (append . lists)
  (define (append-two left right)
    "The final argument is reused as the tail, matching Scheme's variadic"
    "`append' behavior for both proper and improper final lists."
    (if (null? left)
        right
        (cons (car left)
              (append-two (cdr left) right))))
  "Return LISTS appended in order, reusing the final argument as tail."
  (if (null? lists)
      '()
      (if (null? (cdr lists))
          (car lists)
          (append-two (car lists)
                      (apply append (cdr lists))))))

(define (reverse list)
  (define (loop cursor result)
    (if (null? cursor)
        result
        (if (pair? cursor)
            (loop (cdr cursor) (cons (car cursor) result))
            (car cursor))))
  "Return a newly allocated list containing LIST's elements in reverse order."
  (loop list '()))

(define (list-tail list k)
  "Return the sublist of LIST reached after K cdr operations."
  (if (< k 0)
      (car k)
      (if (= k 0)
          list
          (list-tail (cdr list) (- k 1)))))

(define (list-ref list k)
  "Return the element of LIST at zero-based index K."
  (car (list-tail list k)))

(define (list-set! list k obj)
  "Store OBJ in LIST at zero-based index K."
  (set-car! (list-tail list k) obj))

(define (make-list k . fill)
  (define (loop remaining value)
    "`(if #f #f)' produces the implementation's unspecified value when no fill"
    "argument is supplied."
    (if (= remaining 0)
        '()
        (cons value (loop (- remaining 1) value))))
  "Return a newly allocated list of K elements, optionally filled with FILL."
  (if (< k 0)
      (car k)
      (loop k (if (null? fill) (if #f #f) (car fill)))))

(define (list-copy obj)
  "Return a copy of OBJ's pair spine, preserving any final non-pair tail."
  (if (pair? obj)
      (cons (car obj) (list-copy (cdr obj)))
      obj))

(define (memq obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eq? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  "Return the first tail of LIST whose car is eq? to OBJ, or #f."
  (loop list))

(define (memv obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eqv? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  "Return the first tail of LIST whose car is eqv? to OBJ, or #f."
  (loop list))

(define (member obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (equal? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  "Return the first tail of LIST whose car is equal? to OBJ, or #f."
  (loop list))

(define (assq obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eq? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  "Return the first entry in ALIST whose key is eq? to OBJ, or #f."
  (loop alist))

(define (assv obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eqv? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  "Return the first entry in ALIST whose key is eqv? to OBJ, or #f."
  (loop alist))

(define (assoc obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (equal? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  "Return the first entry in ALIST whose key is equal? to OBJ, or #f."
  (loop alist))

(define (zero? number)
  "Return #t when NUMBER is numerically equal to zero."
  (= number 0))

(define (positive? number)
  "Return #t when NUMBER is greater than zero."
  (> number 0))

(define (negative? number)
  "Return #t when NUMBER is less than zero."
  (< number 0))

(define (abs number)
  "Return the nonnegative magnitude of NUMBER."
  (if (negative? number)
      (- number)
      number))

(define (square number)
  "Return NUMBER multiplied by itself."
  (* number number))

(define (even? number)
  "Return #t when NUMBER is evenly divisible by two."
  (zero? (remainder number 2)))

(define (odd? number)
  "Return #t when NUMBER is not evenly divisible by two."
  (not (even? number)))

(define (min first . rest)
  (define (loop best remaining)
    (if (null? remaining)
        best
        (loop (if (< (car remaining) best)
                  (car remaining)
                  best)
              (cdr remaining))))
  "Return the least numeric argument."
  (loop first rest))

(define (max first . rest)
  (define (loop best remaining)
    (if (null? remaining)
        best
        (loop (if (> (car remaining) best)
                  (car remaining)
                  best)
              (cdr remaining))))
  "Return the greatest numeric argument."
  (loop first rest))

(define (map proc first-list . rest-lists)
  (define (any-null? lists)
    "R7RS `map' and `for-each' stop at the shortest input list."
    (if (null? lists)
        #f
        (if (null? (car lists))
            #t
            (any-null? (cdr lists)))))
  (define (cars lists)
    (if (null? lists)
        '()
        (cons (car (car lists))
              (cars (cdr lists)))))
  (define (cdrs lists)
    (if (null? lists)
        '()
        (cons (cdr (car lists))
              (cdrs (cdr lists)))))
  (define (loop lists)
    (if (any-null? lists)
        '()
        (cons (apply proc (cars lists))
              (loop (cdrs lists)))))
  "Apply PROC to elements from each input list and return the result list."
  (loop (cons first-list rest-lists)))

(define (for-each proc first-list . rest-lists)
  (define (any-null? lists)
    (if (null? lists)
        #f
        (if (null? (car lists))
            #t
            (any-null? (cdr lists)))))
  (define (cars lists)
    (if (null? lists)
        '()
        (cons (car (car lists))
              (cars (cdr lists)))))
  (define (cdrs lists)
    (if (null? lists)
        '()
        (cons (cdr (car lists))
              (cdrs (cdr lists)))))
  (define (loop lists)
    (if (any-null? lists)
        (if #f #f)
        (begin
          (apply proc (cars lists))
          (loop (cdrs lists)))))
  "Apply PROC to elements from each input list for side effects."
  (loop (cons first-list rest-lists)))

(define (string-map proc first-string . rest-strings)
  "Apply PROC to characters from each string and return a fresh string."
  (list->string
   (apply map
          proc
          (map string->list (cons first-string rest-strings)))))

(define (string-for-each proc first-string . rest-strings)
  "Apply PROC to characters from each string for side effects."
  (apply for-each
         proc
         (map string->list (cons first-string rest-strings))))

(define (vector-map proc first-vector . rest-vectors)
  "Apply PROC to elements from each vector and return a fresh vector."
  (list->vector
   (apply map
          proc
          (map vector->list (cons first-vector rest-vectors)))))

(define (vector-for-each proc first-vector . rest-vectors)
  "Apply PROC to elements from each vector for side effects."
  (apply for-each
         proc
         (map vector->list (cons first-vector rest-vectors))))
