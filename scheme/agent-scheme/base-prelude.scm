;;; Portable derived bindings for the initial `(scheme base)' environment.
;;;
;;; This file is loaded as ordinary Scheme source by both evaluator
;;; implementations after the kernel primitives are installed.  Keep
;;; definitions small and self-contained: metadata extraction expects each
;;; top-level form to be one `define'.

;; Direct boolean and selector helpers are intentionally terse; their R7RS names
;; and one-expression bodies fully state their contracts.
(define (not obj)
  (if obj #f #t))

(define (list . items)
  items)

(define (caar pair)
  (car (car pair)))

(define (cadr pair)
  (car (cdr pair)))

(define (cdar pair)
  (cdr (car pair)))

(define (cddr pair)
  (cdr (cdr pair)))

;; List traversal helpers document where this prelude relies on primitive
;; errors to enforce proper-list and index contracts.
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

(define (reverse list)
  (define (loop cursor result)
    (if (null? cursor)
        result
        (if (pair? cursor)
            (loop (cdr cursor) (cons (car cursor) result))
            (car cursor))))
  (loop list '()))

(define (list-tail list k)
  (if (< k 0)
      (car k)
      (if (= k 0)
          list
          (list-tail (cdr list) (- k 1)))))

(define (list-ref list k)
  (car (list-tail list k)))

(define (list-set! list k obj)
  (set-car! (list-tail list k) obj))

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

(define (list-copy obj)
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
  (loop list))

(define (memv obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eqv? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  (loop list))

(define (member obj list)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (equal? obj (car cursor))
            cursor
            (loop (cdr cursor)))))
  (loop list))

(define (assq obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eq? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  (loop alist))

(define (assv obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (eqv? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  (loop alist))

(define (assoc obj alist)
  (define (loop cursor)
    (if (null? cursor)
        #f
        (if (equal? obj (caar cursor))
            (car cursor)
            (loop (cdr cursor)))))
  (loop alist))

;; Numeric helpers are derived from kernel arithmetic primitives so metadata can
;; distinguish small Scheme definitions from primitive callbacks.
(define (zero? number)
  (= number 0))

(define (positive? number)
  (> number 0))

(define (negative? number)
  (< number 0))

(define (abs number)
  (if (negative? number)
      (- number)
      number))

(define (square number)
  (* number number))

(define (even? number)
  (zero? (remainder number 2)))

(define (odd? number)
  (not (even? number)))

(define (min first . rest)
  (define (loop best remaining)
    (if (null? remaining)
        best
        (loop (if (< (car remaining) best)
                  (car remaining)
                  best)
              (cdr remaining))))
  (loop first rest))

(define (max first . rest)
  (define (loop best remaining)
    (if (null? remaining)
        best
        (loop (if (> (car remaining) best)
                  (car remaining)
                  best)
              (cdr remaining))))
  (loop first rest))

;; Higher-order sequence helpers share traversal logic and intentionally stop at
;; the shortest list, matching the local R7RS-small reference.
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
