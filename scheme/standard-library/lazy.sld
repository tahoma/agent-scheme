;;; Portable source for the R7RS `(scheme lazy)' library.
;;;
;;; This source is loaded by both evaluator bootstraps as ordinary checked-in
;;; Scheme library code.  It must stay host-neutral and rely only on
;;; `(scheme base)' bindings.

(define-library (scheme lazy)
  (export delay delay-force force make-promise promise?)
  (import (scheme base))
  (begin
    (define (%promise lazy? value)
      "Construct the internal promise record as portable mutable list data."
      (list 'agent-scheme-promise lazy? value))

    (define (promise? obj)
      "Return #t when OBJ is an Agent Scheme promise record."
      #((parameters . ((obj . "Value to inspect.")))
        (returns . "#t when OBJ has the portable promise record shape; otherwise #f.")
        (effects . (pure)))
      (and (pair? obj)
           (eq? (car obj) 'agent-scheme-promise)))

    (define (make-promise obj)
      "Return OBJ as a promise, preserving existing promises."
      #((parameters . ((obj . "Value or existing promise to wrap.")))
        (returns . "A promise record whose forced value is OBJ, or OBJ itself when it is already a promise.")
        (effects . (allocation)))
      (if (promise? obj)
          obj
          (%promise #t obj)))

    (define (force promise)
      "Return PROMISE's value, evaluating and memoizing delayed thunks once."
      #((parameters . ((promise . "Promise record or ordinary value to force.")))
        (returns . "PROMISE's memoized value, or PROMISE unchanged when it is not a promise.")
        (effects . (promise-evaluation mutation)))
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
