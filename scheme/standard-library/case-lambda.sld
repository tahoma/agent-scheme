;;; Portable source for the R7RS `(scheme case-lambda)' library.
;;;
;;; This source is loaded by both evaluator bootstraps as ordinary checked-in
;;; Scheme library code.  It must stay host-neutral and rely only on
;;; `(scheme base)' bindings.

(define-library (scheme case-lambda)
  (export case-lambda)
  (import (scheme base))
  (begin
    (define (%case-lambda-matches? formals count)
      "Report whether FORMALS can receive COUNT arguments."
      (if (symbol? formals)
          #t
          (let loop ((cursor formals) (required 0))
            (cond
             ((null? cursor) (= count required))
             ((pair? cursor) (loop (cdr cursor) (+ required 1)))
             (else (>= count required))))))

    ;; Dispatch to the first clause whose formal parameter list matches the
    ;; number of supplied arguments.
    (define-syntax case-lambda
      (syntax-rules ()
        ((case-lambda)
         (lambda args (car '())))
        ((case-lambda (formals body ...) more ...)
         (lambda args
           (if (%case-lambda-matches? 'formals (length args))
               (apply (lambda formals body ...) args)
               (apply (case-lambda more ...) args))))))))
