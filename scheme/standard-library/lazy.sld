;;; Portable source for the R7RS `(scheme lazy)' library.
;;;
;;; This source is loaded by both evaluator bootstraps as ordinary checked-in
;;; Scheme library code.  It must stay host-neutral and rely only on
;;; `(scheme base)' bindings.

(define-library (scheme lazy)
  (export delay delay-force force make-promise promise?)
  (import (scheme base))
  (begin
    ;; Construct the internal promise record as portable mutable list data.
    (define (%promise lazy? value)
      (list 'agent-scheme-promise lazy? value))

    (define (promise? obj)
      "Return #t when OBJ is an Agent Scheme promise record."
      (and (pair? obj)
           (eq? (car obj) 'agent-scheme-promise)))

    (define (make-promise obj)
      "Return OBJ as a promise, preserving existing promises."
      (if (promise? obj)
          obj
          (%promise #t obj)))

    (define (force promise)
      "Return PROMISE's value, evaluating and memoizing delayed thunks once."
      (if (promise? promise)
          (if (cadr promise)
              (car (cdr (cdr promise)))
              (let ((value ((car (cdr (cdr promise))))))
                (set-car! (cdr promise) #t)
                (set-car! (cdr (cdr promise)) value)
                value))
          promise))

    ;; Delay EXPRESSION as a thunk-producing promise.
    (define-syntax delay-force
      (syntax-rules ()
        ((delay-force expression)
         (%promise #f (lambda () expression)))))

    ;; Delay EXPRESSION through the shared delayed-force representation.
    (define-syntax delay
      (syntax-rules ()
        ((delay expression)
         (delay-force expression))))))
