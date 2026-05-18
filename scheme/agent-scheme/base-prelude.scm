;;; Portable derived bindings for the initial `(scheme base)' environment.
;;;
;;; This file is loaded as ordinary Scheme source by both evaluator
;;; implementations after the kernel primitives are installed.  Keep
;;; definitions small and self-contained: metadata extraction expects each
;;; top-level form to be one `define'.

;; Implement R7RS boolean negation, where every value except #f is true.
(define (not obj)
  (if obj #f #t))

;; Collect all arguments into the list used by the R7RS base library.
(define (list . items)
  items)

;; Provide the standard composed car/car selector for pairs.
(define (caar pair)
  (car (car pair)))

;; Provide the standard composed car/cdr selector for pairs.
(define (cadr pair)
  (car (cdr pair)))

;; Provide the standard composed cdr/car selector for pairs.
(define (cdar pair)
  (cdr (car pair)))

;; Provide the standard composed cdr/cdr selector for pairs.
(define (cddr pair)
  (cdr (cdr pair)))

;; Count elements in a proper list and reject dotted tails through primitives.
(define (length list)
  ;; R7RS requires a proper list; reaching a non-pair tail forces an error
  ;; through a primitive operation instead of silently accepting dotted input.
  (define (loop cursor count)
    (if (null? cursor)
        count
        (if (pair? cursor)
            (loop (cdr cursor) (+ count 1))
            (car cursor))))
  (loop list 0))

;; Append lists while reusing the final argument as the result tail.
(define (append . lists)
  ;; The final argument is reused as the tail, matching Scheme's variadic
  ;; `append' behavior for both proper and improper final lists.
  (define (append-two left right)
    (if (null? left)
        right
        (cons (car left)
              (append-two (cdr left) right))))
  (if (null? lists)
      '()
      (if (null? (cdr lists))
          (car lists)
          (append-two (car lists)
                      (apply append (cdr lists))))))

;; Return a freshly reversed proper list, relying on pair primitives for
;; validation.
(define (reverse list)
  (define (loop cursor result)
    (if (null? cursor)
        result
        (if (pair? cursor)
            (loop (cdr cursor) (cons (car cursor) result))
            (car cursor))))
  (loop list '()))

;; Return the kth tail of LIST using the base arithmetic and pair primitives.
(define (list-tail list k)
  (if (< k 0)
      (car k)
      (if (= k 0)
          list
          (list-tail (cdr list) (- k 1)))))

;; Return the element at index K through the shared list-tail helper.
(define (list-ref list k)
  (car (list-tail list k)))

;; Mutate the pair at index K after list-tail locates the target cell.
(define (list-set! list k obj)
  (set-car! (list-tail list k) obj))

;; Build a list of length K, using the evaluator unspecified value as the
;; default fill.
(define (make-list k . fill)
  ;; `(if #f #f)' produces the implementation's unspecified value when no fill
  ;; argument is supplied.
  (define (loop remaining value)
    (if (= remaining 0)
        '()
        (cons value (loop (- remaining 1) value))))
  (if (< k 0)
      (car k)
      (loop k (if (null? fill) (if #f #f) (car fill)))))

;; Copy the pair spine of OBJ while preserving any non-pair tail.
(define (list-copy obj)
  (if (pair? obj)
      (cons (car obj) (list-copy (cdr obj)))
      obj))

;; Search LIST with eq? and return the matching tail or #f.
(define (memq obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eq? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  (loop list))

;; Search LIST with eqv? and return the matching tail or #f.
(define (memv obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eqv? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  (loop list))

;; Search LIST with equal? and return the matching tail or #f.
(define (member obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (equal? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  (loop list))

;; Search an association list with eq? against each entry key.
(define (assq obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eq? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  (loop alist))

;; Search an association list with eqv? against each entry key.
(define (assv obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eqv? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  (loop alist))

;; Search an association list with equal? against each entry key.
(define (assoc obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (equal? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  (loop alist))

;; Report whether NUMBER is numerically equal to zero.
(define (zero? number)
  (= number 0))

;; Derived numeric predicate implemented through the kernel greater-than
;; primitive.
(define (positive? number)
  (> number 0))

;; Derived numeric predicate implemented through the kernel less-than
;; primitive.
(define (negative? number)
  (< number 0))

;; Return the nonnegative magnitude of NUMBER through derived sign testing.
(define (abs number)
  (if (negative? number)
      (- number)
      number))

;; Multiply NUMBER by itself without adding a separate kernel primitive.
(define (square number)
  (* number number))

;; Classify integers by the remainder produced from division by two.
(define (even? number)
  (zero? (remainder number 2)))

;; Classify integers as the complement of the derived even? predicate.
(define (odd? number)
  (not (even? number)))

;; Fold a nonempty numeric argument list to its least value.
(define (min first . rest)
  (define (loop best remaining)
    (if (null? remaining)
        best
        (loop (if (< (car remaining) best)
                  (car remaining)
                  best)
              (cdr remaining))))
  (loop first rest))

;; Fold a nonempty numeric argument list to its greatest value.
(define (max first . rest)
  (define (loop best remaining)
    (if (null? remaining)
        best
        (loop (if (> (car remaining) best)
                  (car remaining)
                  best)
              (cdr remaining))))
  (loop first rest))

;; Apply PROC across one or more lists and collect results until the shortest
;; input ends.
(define (map proc first-list . rest-lists)
  ;; R7RS `map' and `for-each' stop at the shortest input list.
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
        '()
        (cons (apply proc (cars lists))
              (loop (cdrs lists)))))
  (loop (cons first-list rest-lists)))

;; Apply PROC for effects across one or more lists until the shortest input
;; ends.
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
  (loop (cons first-list rest-lists)))
