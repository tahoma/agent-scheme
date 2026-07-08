;;; Portable derived syntax for the initial `(scheme base)' syntactic environment.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; These macros are evaluated into a fresh syntax environment after the base
;;; value prelude is available.  Definitions should stay expressible in
;;; `syntax-rules' so the bootstrap macro expander remains the only expansion
;;; mechanism required here.

;; Mirrors the R7RS derived-expression definition, including the `=>' receiver
;; clauses that pass the tested value to a procedure.
(define-syntax cond
  (syntax-rules (else =>)
    ((cond (else result1 result2 ...))
     (begin result1 result2 ...))
    ((cond (test => result))
     (let ((temp test))
       (if temp (result temp))))
    ((cond (test => result) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           (result temp)
           (cond clause1 clause2 ...))))
    ((cond (test)) test)
    ((cond (test) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           temp
           (cond clause1 clause2 ...))))
    ((cond (test result1 result2 ...))
     (if test (begin result1 result2 ...)))
    ((cond (test result1 result2 ...)
           clause1 clause2 ...)
     (if test
         (begin result1 result2 ...)
         (cond clause1 clause2 ...)))))

;; Uses `memv' against quoted datum lists as in R7RS, while `=>' receiver
;; clauses receive the selected key value.
(define-syntax case
  (syntax-rules (else =>)
    ((case (key ...)
       clauses ...)
     (let ((atom-key (key ...)))
       (case atom-key clauses ...)))
    ((case key
       (else => result))
     (result key))
    ((case key
       (else result1 result2 ...))
     (begin result1 result2 ...))
    ((case key
       ((atoms ...) => result))
     (if (memv key '(atoms ...))
         (result key)))
    ((case key
       ((atoms ...) result1 result2 ...))
     (if (memv key '(atoms ...))
         (begin result1 result2 ...)))
    ((case key
       ((atoms ...) => result)
       clause clauses ...)
     (if (memv key '(atoms ...))
         (result key)
         (case key clause clauses ...)))
    ((case key
       ((atoms ...) result1 result2 ...)
       clause clauses ...)
     (if (memv key '(atoms ...))
         (begin result1 result2 ...)
         (case key clause clauses ...)))))

;; Expand short-circuit conjunction and preserve the final true value.
(define-syntax and
  (syntax-rules ()
    ((and) #t)
    ((and test) test)
    ((and test1 test2 ...)
     (if test1 (and test2 ...) #f))))

;; Expand short-circuit disjunction while evaluating each test at most once.
(define-syntax or
  (syntax-rules ()
    ((or) #f)
    ((or test) test)
    ((or test1 test2 ...)
     (let ((temp test1))
       (if temp temp (or test2 ...))))))

;; Expand conditional sequencing for true tests through if and begin.
(define-syntax when
  (syntax-rules ()
    ((when test result1 result2 ...)
     (if test
         (begin result1 result2 ...)))))

;; Expand conditional sequencing for false tests through if and begin.
(define-syntax unless
  (syntax-rules ()
    ((unless test result1 result2 ...)
     (if (not test)
         (begin result1 result2 ...)))))

;; Named `let' lowers through `letrec' so the tag is bound recursively before
;; the initial call is evaluated.
(define-syntax let
  (syntax-rules ()
    ((let ((name val) ...) body1 body2 ...)
     ((lambda (name ...) body1 body2 ...)
      val ...))
    ((let tag ((name val) ...) body1 body2 ...)
     ((letrec ((tag (lambda (name ...)
                      body1 body2 ...)))
        tag)
      val ...))))

;; Expands to nested `let' forms so each initializer sees earlier bindings
;; without adding another evaluator special form.
(define-syntax let*
  (syntax-rules ()
    ((let* () body1 body2 ...)
     (let () body1 body2 ...))
    ((let* ((name1 val1) (name2 val2) ...)
       body1 body2 ...)
     (let ((name1 val1))
       (let* ((name2 val2) ...)
         body1 body2 ...)))))

;; The `"step"' literal is a private marker used only inside this macro's
;; recursive expansion to choose each variable's optional step expression.
(define-syntax do
  (syntax-rules ()
    ((do ((var init step ...) ...)
         (test expr ...)
         command ...)
     (letrec
       ((loop
         (lambda (var ...)
           (if test
               (begin
                 (if #f #f)
                 expr ...)
               (begin
                 command
                 ...
                 (loop (do "step" var step ...)
                       ...))))))
       (loop init ...)))
    ((do "step" x)
     x)
    ((do "step" x y)
     y)))

;; Parameter binding lowers through `dynamic-wind' so captured continuations
;; restore and re-enter parameter values through the same wind protocol.
(define-syntax parameterize
  (syntax-rules ()
    ((parameterize () body1 body2 ...)
     (begin body1 body2 ...))
    ((parameterize ((param value) binding ...)
       body1 body2 ...)
     (let ((parameter param)
           (active-value value))
       (let ((swap-value #f))
         (dynamic-wind
          (lambda ()
            (set! swap-value (parameter))
            (parameter active-value)
            (set! active-value swap-value))
          (lambda ()
            (parameterize (binding ...)
              body1 body2 ...))
          (lambda ()
            (set! swap-value (parameter))
            (parameter active-value)
            (set! active-value swap-value))))))))

;; Runtime feature checks are intentionally tiny during bootstrap: `r7rs',
;; `consent', and `(library (scheme base))' are known, while other features
;; fall through.
(define-syntax cond-expand
  (syntax-rules (and or not else r7rs consent library scheme base)
    ((cond-expand)
     (syntax-error "Unfulfilled cond-expand"))
    ((cond-expand (else body ...))
     (begin body ...))
    ((cond-expand ((and) body ...) more-clauses ...)
     (begin body ...))
    ((cond-expand ((and req1 req2 ...) body ...) more-clauses ...)
     (cond-expand
       (req1
        (cond-expand
          ((and req2 ...) body ...)
          more-clauses ...))
       (else
        (cond-expand more-clauses ...))))
    ((cond-expand ((or) body ...) more-clauses ...)
     (cond-expand more-clauses ...))
    ((cond-expand ((or req1 req2 ...) body ...) more-clauses ...)
     (cond-expand
       (req1
        (begin body ...))
       (else
        (cond-expand
          ((or req2 ...) body ...)
          more-clauses ...))))
    ((cond-expand ((not req) body ...) more-clauses ...)
     (cond-expand
       (req
        (cond-expand more-clauses ...))
       (else body ...)))
    ((cond-expand (r7rs body ...) more-clauses ...)
     (begin body ...))
    ((cond-expand (consent body ...) more-clauses ...)
     (begin body ...))
    ((cond-expand ((library (scheme base)) body ...) more-clauses ...)
     (begin body ...))
    ((cond-expand ((library (name ...)) body ...) more-clauses ...)
     (cond-expand more-clauses ...))
    ((cond-expand (feature-id body ...) more-clauses ...)
     (cond-expand more-clauses ...))))

;; `guard' captures both the normal return path and handler re-raise path so
;; continuable exceptions preserve R7RS control behavior.
(define-syntax guard
  (syntax-rules ()
    ((guard (var clause ...) e1 e2 ...)
     ((call/cc
       (lambda (guard-k)
         (with-exception-handler
          (lambda (condition)
            ((call/cc
              (lambda (handler-k)
                (guard-k
                 (lambda ()
                   (let ((var condition))
                     (guard-aux
                      (handler-k
                       (lambda ()
                         (raise-continuable condition)))
                      clause ...))))))))
          (lambda ()
            (call-with-values
             (lambda () e1 e2 ...)
             (lambda args
               (guard-k
                (lambda ()
                  (apply values args)))))))))))))

;; Private helper macro for `guard'; `reraise' is an expression, not an exposed
;; binding, and `else' / `=>' keep their ordinary guard-clause roles.
(define-syntax guard-aux
  (syntax-rules (else =>)
    ((guard-aux reraise (else result1 result2 ...))
     (begin result1 result2 ...))
    ((guard-aux reraise (test => result))
     (let ((temp test))
       (if temp
           (result temp)
           reraise)))
    ((guard-aux reraise (test => result) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           (result temp)
           (guard-aux reraise clause1 clause2 ...))))
    ((guard-aux reraise (test))
     (or test reraise))
    ((guard-aux reraise (test) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           temp
           (guard-aux reraise clause1 clause2 ...))))
    ((guard-aux reraise (test result1 result2 ...))
     (if test
         (begin result1 result2 ...)
         reraise))
    ((guard-aux reraise (test result1 result2 ...) clause1 clause2 ...)
     (if test
         (begin result1 result2 ...)
         (guard-aux reraise clause1 clause2 ...)))))
