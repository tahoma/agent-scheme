;;; Portable evaluator test runner for the Agent Scheme R7RS library.
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; evaluator library without loading the Emacs host adapter.

(import (scheme base)
        (scheme write)
        (agent-scheme eval))

;; Shared evaluator behavior runs through agent-scheme-fixture-test.scm. This
;; file keeps portable evaluator API and bootstrap invariants close to the R7RS
;; library.

(define failures 0)

;; Record one failed portable evaluator check and keep running the rest of the
;; suite so failures report together.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Evaluate SOURCE and compare the stable external value representation.
(define (check-external name source expected)
  (check name
         (agent-scheme-value->external (agent-scheme-eval-source source))
         expected))

;; Evaluate SOURCE with OPTIONS and compare the stable external value.
(define (check-external/options name source options expected)
  (check name
         (agent-scheme-value->external
          (agent-scheme-eval-source source #f options))
         expected))

;; Evaluate SOURCE as an evaluation-result datum and compare its external form.
(define (check-result-external name source expected)
  (check name
         (agent-scheme-result->external
          (agent-scheme-eval-source-result source))
         expected))

;; Find the primitive binding metadata record named NAME in SPECS.
(define (find-primitive-spec name specs)
  (cond
   ((null? specs) #f)
   ((eq? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-primitive-spec name (cdr specs)))))

;; Find the source-backed standard library metadata record named NAME in SPECS.
(define (find-source-library-spec name specs)
  (cond
   ((null? specs) #f)
   ((equal? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-source-library-spec name (cdr specs)))))

;; Return #t when THUNK raises any portable Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(check-external 'literal-number "42" "42")
(check 'literal-number-is-agent-owned
       (number? (agent-scheme-eval-source "42"))
       #f)
(check-external 'literal-string "\"ok\"" "\"ok\"")
(check-external 'quote-symbol "'alpha" "alpha")
(check-external 'quote-list "'(1 2 3)" "(1 2 3)")
(check 'empty-list-expression-error
       (raises? (lambda () (agent-scheme-eval-source "()")))
       #t)

(check-external 'definition-and-reference
                "(define answer 40)
                 (+ answer 2)"
                "42")
(check-external 'top-level-begin
                "(begin
                   (define answer 42)
                   answer)"
                "42")
(check-external 'operator-expression
                "((if #f + *) 3 4)"
                "12")
(check 'unknown-identifier
       (raises? (lambda () (agent-scheme-eval-source "missing")))
       #t)

(let ((names (agent-scheme-base-primitive-names))
      (prelude-names (agent-scheme-base-prelude-binding-names))
      (specs (agent-scheme-base-primitive-specs))
      (binding-specs (agent-scheme-base-binding-specs)))
  (check 'base-registry-names
         (if (and (memq '+ names)
                  (memq 'apply names)
                  (memq 'car names)
                  (memq 'vector-ref names)
                  (not (memq 'append names))
                  (not (memq 'cadr names))
                  (not (memq 'length names))
                  (not (memq 'map names))
                  (not (memq 'zero? names))
                  (memq 'append prelude-names)
                  (memq 'cadr prelude-names)
                  (memq 'length prelude-names)
                  (memq 'map prelude-names)
                  (memq 'zero? prelude-names)
                  (memq 'call-with-values names)
                  (memq 'call/cc names)
                  (memq 'dynamic-wind names)
                  (memq 'features names)
                  (memq 'make-parameter names)
                  (memq 'string->utf8 names)
                  (memq 'utf8->string names)
                  (memq 'values names))
             #t
             #f)
         #t)
  (check 'base-registry-specs
         (cadr (assq 'minimum-arity
                     (find-primitive-spec 'vector-ref specs)))
         2)
  (check 'base-kernel-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'vector-ref binding-specs)))
         'kernel)
  (check 'base-prelude-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'append binding-specs)))
         'prelude))

(let* ((source-specs (agent-scheme-standard-source-library-specs))
       (case-lambda-spec
        (find-source-library-spec '(scheme case-lambda) source-specs))
       (lazy-spec
        (find-source-library-spec '(scheme lazy) source-specs)))
  (check 'standard-source-library-case-lambda-exports
         (and case-lambda-spec
              (cadr (assq 'exports case-lambda-spec)))
         '(case-lambda))
  (check 'standard-source-library-lazy-exports
         (and lazy-spec
              (cadr (assq 'exports lazy-spec)))
         '(delay delay-force force make-promise promise?))
  (check 'standard-source-library-files
         (and case-lambda-spec
              lazy-spec
              (string? (cadr (assq 'source-file case-lambda-spec)))
              (string? (cadr (assq 'source-file lazy-spec))))
         #t))

(check-external 'base-list-helpers
                "(list (length (append '(1 2) '(3 4)))
                       (cadr '(alpha beta gamma))
                       (equal? '(1 \"x\") '(1 \"x\")))"
                "(4 beta #t)")

(check-external 'records-construct-predicate-access-and-mutate
                "(define-record-type <pare>
                   (kons x y)
                   pare?
                   (x kar set-kar!)
                   (y kdr))
                 (let ((p (kons 1 2)))
                   (set-kar! p 3)
                   (list (pare? p)
                         (pare? (cons 1 2))
                         (kar p)
                         (kdr p)))"
                "(#t #f 3 2)")

(check-external 'circular-equality-terminates
                "(let ((left '#1=(a b . #1#))
                       (right '#2=(a b a b . #2#)))
                   (list (eq? left (cddr left))
                         (equal? left right)))"
                "(#t #t)")

(check-external 'base-scalar-helpers
                "(list (/ 5 2)
                       (abs -4)
                       (modulo -13 4)
                       (square 5)
                       (boolean=? #t (not #f))
                       (string->symbol (symbol->string 'agent-scheme)))"
                "(5/2 4 3 25 #t agent-scheme)")

(check-external 'numeric-tower-exact-rationals
                "(list (/ 3 4 5)
                       (+ 1/2 1/3)
                       (numerator (/ 6 4))
                       (denominator (/ 6 4))
                       (number->string 42 16)
                       (string->number \"2a\" 16))"
                "(3/20 5/6 3 2 \"2a\" 42)")

(check-external 'numeric-tower-polar-special-values
                "(import (scheme complex))
                 (list (make-polar +inf.0 0)
                       (make-polar 1 +inf.0)
                       (make-polar +nan.0 0))"
                "(+inf.0+nan.0i +nan.0+nan.0i +nan.0+nan.0i)")

(check-external 'base-vector-and-bytevector-helpers
                "(define v (vector 'a 'b 'c))
                 (vector-set! v 1 'changed)
                 (define b (bytevector 1 2 3))
                 (bytevector-u8-set! b 1 9)
                 (list v b)"
                "(#(a changed c) #u8(1 9 3))")

(check-external 'base-higher-order-helpers
                "(define total 0)
                 (for-each (lambda (x) (set! total (+ total x))) '(1 2 3))
                 (list (apply + 1 '(2 3 4))
                       (map (lambda (x) (* x x)) '(2 3 4))
                       total)"
                "(10 (4 9 16) 6)")

(check-result-external 'multiple-values-result
                       "(values 1 2)"
                       "(evaluation-result (status values) (values (1 2)) (events ()) (budget (steps-used 5) (host-calls 1)))")

(check-external 'multiple-values-binding-forms
                "(let ((a 'a) (b 'b) (x 'x) (y 'y))
                   (let*-values (((a b) (values x y))
                                 ((x y) (values a b)))
                     (list a b x y)))"
                "(x y x y)")

(check-external 'call-with-values-consumer
                "(call-with-values (lambda () (values 4 5))
                                   (lambda (a b) (- b a)))"
                "1")

(check-external 'define-values-top-level
                "(define-values (root remainder)
                   (exact-integer-sqrt 10))
                 (define-values (head . tail)
                   (values 'a 'b 'c))
                 (define-values all
                   (values 1 2 3))
                 (list root remainder head tail all)"
                "(3 1 a (b c) (1 2 3))")

(check-external 'define-values-internal
                "((lambda ()
                    (define-values (left right)
                      (values 'l 'r))
                    (list left right)))"
                "(l r)")

(check-external 'base-features-parameters-and-utf8
                "(let ((available (features))
                       (setting (make-parameter 'outer)))
                   (let ((bytes (string->utf8 \"agent\")))
                     (list (pair? (memq 'r7rs available))
                           (pair? (memq 'agent-scheme available))
                           (setting)
                           (parameterize ((setting 'inner))
                             (setting))
                           (setting)
                           bytes
                           (utf8->string bytes)
                           (utf8->string bytes 1 4))))"
                "(#t #t outer inner outer #u8(97 103 101 110 116) \"agent\" \"gen\")")

(check-external 'call/cc-escape
                "(call/cc (lambda (escape) (+ 1 (escape 42))))"
                "42")

(check-external 'dynamic-wind-exit
                "(let ((path '()))
                   (define (add tag) (set! path (cons tag path)))
                   (call/cc
                    (lambda (escape)
                      (dynamic-wind
                       (lambda () (add 'before))
                       (lambda ()
                         (add 'during)
                         (escape 'done))
                       (lambda () (add 'after)))))
                   (reverse path))"
                "(before during after)")

(check-external 'call/cc-reenter-after-return
                "(let ((again #f))
                   (let ((value (call/cc
                                 (lambda (k)
                                   (set! again k)
                                   'first))))
                     (if (eq? value 'first)
                         (again 'second)
                         value)))"
                "second")

(check-external 'call/cc-repeated-invocation
                "(let ((again #f)
                       (seen '()))
                   (let ((value (call/cc
                                 (lambda (k)
                                   (set! again k)
                                   'start))))
                     (set! seen (cons value seen))
                     (if (< (length seen) 3)
                         (again (length seen))
                         (reverse seen))))"
                "(start 1 2)")

(check-external 'dynamic-wind-reentry
                "(let ((again #f)
                       (outside #f)
                       (path '()))
                   (define (add tag) (set! path (cons tag path)))
                   (call/cc
                    (lambda (escape)
                      (set! outside escape)
                      (dynamic-wind
                       (lambda () (add 'before-outer))
                       (lambda ()
                         (dynamic-wind
                          (lambda () (add 'before-inner))
                          (lambda ()
                            (call/cc
                             (lambda (k)
                               (set! again k)
                               'captured))
                            (add 'during-inner)
                            (outside 'escaped))
                          (lambda () (add 'after-inner))))
                       (lambda () (add 'after-outer)))))
                   (if again
                       (let ((resume again))
                         (set! again #f)
                         (resume 'resumed))
                       (reverse path)))"
                "(before-outer before-inner during-inner after-inner after-outer before-outer before-inner during-inner after-inner after-outer)")

(check-external 'call/cc-multiple-values
                "(let ((again #f))
                   (call-with-values
                    (lambda ()
                      (call/cc
                       (lambda (k)
                         (set! again k)
                         (values 1 2))))
                    (lambda (a b)
                      (if (= a 1)
                          (again 3 4)
                          (list a b)))))"
                "(3 4)")

(check-external 'let-values-continuation-multiple-values
                "(let ((again #f))
                   (let-values (((a b)
                                 (call/cc
                                  (lambda (k)
                                    (set! again k)
                                    (values 1 2)))))
                     (if (= a 1)
                         (again 3 4)
                         (list a b))))"
                "(3 4)")

(check-external 'let*-values-continuation-multiple-values
                "(let ((again #f))
                   (let*-values (((a b)
                                  (call/cc
                                   (lambda (k)
                                     (set! again k)
                                     (values 1 2))))
                                 ((c) (+ a b)))
                     (if (= a 1)
                         (again 3 4)
                         (list a b c))))"
                "(3 4 7)")

(check-external 'guard-raise
                "(guard (exn (else (list 'caught exn)))
                   (raise 'boom))"
                "(caught boom)")

(check-external 'raise-continuable
                "(with-exception-handler
                   (lambda (exn) 42)
                   (lambda ()
                     (+ (raise-continuable 'warning) 23)))"
                "65")

(check-external 'error-object
                "(guard (exn
                         ((error-object? exn)
                          (list (error-object-message exn)
                                (error-object-irritants exn))))
                   (error \"bad input\" 'alpha 7))"
                "(\"bad input\" (alpha 7))")

(check-external 'define-syntax-expands-ellipsis
                "(define x 0)
                 (define-syntax unless
                   (syntax-rules ()
                     ((unless test body ...)
                      (if test #f (begin body ...)))))
                 (unless #f
                   (set! x 41)
                   (+ x 1))"
                "42")

(check-external 'introduced-bindings-are-hygienic
                "(define-syntax my-or
                   (syntax-rules ()
                     ((my-or) #f)
                     ((my-or expr) expr)
                     ((my-or expr next ...)
                      (let ((temp expr))
                        (if temp temp (my-or next ...))))))
                 (let ((temp 99))
                   (my-or #f temp))"
                "99")

(check-external 'let-syntax-is-referentially-transparent
                "(let ((x 'outer))
                   (let-syntax ((m (syntax-rules ()
                                     ((m) x))))
                     (let ((x 'inner))
                       (m))))"
                "outer")

(check 'free-template-identifiers-do-not-capture-use-site
       (raises? (lambda ()
                  (agent-scheme-eval-source
                   "(define-syntax expose-x
                      (syntax-rules ()
                        ((expose-x) x)))
                    (let ((x 1))
                      (expose-x))")))
       #t)

(check-external 'letrec-syntax-allows-recursive-transformers
                "(letrec-syntax
                     ((my-or
                       (syntax-rules ()
                         ((my-or) #f)
                         ((my-or expr) expr)
                         ((my-or expr next ...)
                          (let ((temp expr))
                            (if temp temp (my-or next ...)))))))
                   (my-or #f #f 7))"
                "7")

(check-external 'named-let-expands-through-letrec
                "(let loop ((n 5) (acc 0))
                   (if (= n 0)
                       acc
                       (loop (- n 1) (+ acc 1))))"
                "5")

(check-external 'cond-arrow-respects-literal-binding
                "(list
                   (cond ((assv 'b '((a 1) (b 2))) => cadr)
                         (else #f))
                   (let ((=> #f))
                     (cond (#t => 'ok))))"
                "(2 ok)")

(check-external 'case-expands-from-base-syntax
                "(list
                   (case (car '(c d))
                     ((a e i o u) 'vowel)
                     ((c d) 'consonant)
                     (else 'other))
                   (case 'b
                     ((a) 'a)
                     ((b c) => (lambda (x) (list x 'hit)))
                     (else #f)))"
                "(consonant (b hit))")

(check-external 'do-expands-nested-ellipses
                "(do ((i 0 (+ i 1))
                      (acc 0 (+ acc i)))
                     ((= i 5) acc))"
                "10")

(check-external 'dotted-patterns-and-templates
                "(define-syntax rest-list
                   (syntax-rules ()
                     ((rest-list first . rest)
                      'rest)))
                 (define-syntax make-pair
                   (syntax-rules ()
                     ((make-pair left right)
                      '(left . right))))
                 (list (rest-list a b c)
                       (make-pair alpha beta))"
                "((b c) (alpha . beta))")

(check-external 'nested-ellipsis-template-expands
                "(define-syntax echo-groups
                   (syntax-rules ()
                     ((echo-groups ((head item ...) ...))
                      '((head item ...) ...))))
                 (echo-groups ((a 1 2) (b 3) (c)))"
                "((a 1 2) (b 3) (c))")

(check-external 'quasiquote-evaluates-unquotes
                "(list
                   (quasiquote (a (unquote (+ 1 2))
                                  (unquote-splicing (list 'b 'c))))
                   (quasiquote #(1 (unquote (+ 1 2))))
                   (quasiquote (outer
                                 (quasiquote
                                  (inner (unquote (+ 1 2))))
                                 (unquote (+ 2 3)))))"
                "((a 3 b c) #(1 3) (outer (quasiquote (inner (unquote (+ 1 2)))) 5))")

(check-external 'cond-expand-selects-base-feature
                "(list
                   (cond-expand (r7rs 'ok) (else 'missing))
                   (cond-expand
                    ((library (scheme base)) 'base)
                    (else 'missing)))"
                "(ok base)")

(check 'import-scheme-base-into-empty-environment
       (agent-scheme-value->external
        (agent-scheme-eval-source
         "(import (scheme base))
          (+ 1 2)"
         (agent-scheme-make-empty-environment)))
       "3")

(check-external 'define-library-import-export
                "(define-library (agent-scheme fixture math)
                   (export answer)
                   (import (scheme base))
                   (begin
                     (define answer 42)))
                 (import (agent-scheme fixture math))
                 answer"
                "42")

(check-external 'library-import-set-modifiers
                "(define-library (agent-scheme fixture modifiers)
                   (export add sub hidden)
                   (import (scheme base))
                   (begin
                     (define (add x y) (+ x y))
                     (define (sub x y) (- x y))
                     (define hidden 99)))
                 (import (only (agent-scheme fixture modifiers) add)
                         (except
                          (prefix (agent-scheme fixture modifiers) lib-)
                          lib-hidden)
                         (rename
                          (agent-scheme fixture modifiers)
                          (sub minus)))
                 (list (add 1 2)
                       (lib-add 3 4)
                       (lib-sub 10 6)
                       (minus 8 5))"
                "(3 7 4 3)")

(check-external 'library-export-rename
                "(define-library (agent-scheme fixture export-rename)
                   (export (rename internal external))
                   (import (scheme base))
                   (begin
                     (define internal 42)))
                 (import (agent-scheme fixture export-rename))
                 external"
                "42")

(check-external 'emacs-capability-import-empty
                "(import (emacs buffer))
                 'ok"
                "ok")

(check 'conflicting-library-imports
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(define-library (agent-scheme fixture left)
              (export value)
              (import (scheme base))
              (begin (define value 'left)))
            (define-library (agent-scheme fixture right)
              (export value)
              (import (scheme base))
              (begin (define value 'right)))
            (import (agent-scheme fixture left)
                    (agent-scheme fixture right))
            value")))
       #t)

(check-external 'exported-library-macro-keeps-scope
                "(define-library (agent-scheme fixture syntax)
                   (export choose)
                   (import (scheme base))
                   (begin
                     (define default 'library)
                     (define-syntax choose
                       (syntax-rules ()
                         ((choose) default)))))
                 (import (scheme base)
                         (agent-scheme fixture syntax))
                 (let ((default 'program))
                   (choose))"
                "library")

(check-external 'library-cond-expand-declaration
                "(define-library (agent-scheme fixture conditional)
                   (cond-expand
                     ((library (scheme base))
                      (export answer)
                      (import (scheme base))
                      (begin (define answer 42)))
                     (else
                      (export answer)
                      (begin (define answer 'missing)))))
                 (import (agent-scheme fixture conditional))
                 answer"
                "42")

(check 'include-declarations-are-policy-gated
       (raises?
       (lambda ()
         (agent-scheme-eval-source
          "(define-library (agent-scheme fixture include)
             (export answer)
             (import (scheme base))
             (include \"fixtures/r7rs/conformance-cases.scm\"))")))
       #t)

;; Include policy options grant this portable test runner access to fixture
;; files while preserving the evaluator's default-deny host policy cases.
(define include-policy-options
  '((include-directory . ".")
    (include-paths . ("fixtures/r7rs"))
    (file-paths . ("fixtures/r7rs"))))

(check-external/options 'include-reads-policy-allowed-body
                        "(define-library (agent-scheme fixture include-body)
                           (export answer)
                           (import (scheme base))
                           (include \"fixtures/r7rs/include-body.scm\"))
                         (import (agent-scheme fixture include-body))
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'include-ci-folds-policy-allowed-body
                        "(define-library (agent-scheme fixture include-ci-body)
                           (export mixedanswer)
                           (import (scheme base))
                           (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
                         (import (agent-scheme fixture include-ci-body))
                         mixedanswer"
                        include-policy-options
                        "42")

(check-external/options 'include-library-declarations-splice
                        "(define-library
                           (agent-scheme fixture included-declarations)
                           (include-library-declarations
                            \"fixtures/r7rs/include-library-declarations.scm\"))
                         (import
                          (agent-scheme fixture included-declarations))
                         answer"
                        include-policy-options
                        "42")

(check-external 'standard-case-lambda-import
                "(import (scheme base) (scheme case-lambda))
                 ((case-lambda
                    ((x) x)
                    ((x y) (+ x y)))
                  1 2)"
                "3")

(check-external 'standard-case-lambda-rest-import
                "(import (scheme base) (scheme case-lambda))
                 (list
                  ((case-lambda
                     ((x) x)
                     ((x y . rest) (list x y rest)))
                   1 2 3 4)
                  ((case-lambda
                     (all all))
                   'a 'b))"
                "((1 2 (3 4)) (a b))")

(check-external 'standard-char-and-cxr-imports
                "(import (scheme base) (scheme char) (scheme cxr))
                 (list (char-upcase #\\a)
                       (char-downcase #\\Z)
                       (char-foldcase #\\A)
                       (char-alphabetic? #\\A)
                       (char-numeric? #\\9)
                       (char-whitespace? #\\space)
                       (digit-value #\\9)
                       (char-ci=? #\\A #\\a)
                       (string-upcase \"Az\")
                       (string-ci<? \"abc\" \"BCD\")
                       (cadddr '(a b c d e)))"
                "(#\\A #\\z #\\a #t #t #t 9 #t \"AZ\" #t d)")

(check-external 'standard-inexact-transcendentals
                "(import (scheme inexact))
                 (list (sqrt 9)
                       (sin 0)
                       (cos 0)
                       (tan 0)
                       (exp 0)
                       (log 1))"
                "(3.0 0.0 1.0 0.0 1.0 0.0)")

(check-external 'standard-lazy-import-memoizes
                "(import (scheme base) (scheme lazy))
                 (let ((count 0))
                   (let ((promise
                          (delay
                            (begin
                              (set! count (+ count 1))
                              count))))
                     (list (force promise)
                           (force promise)
                           count)))"
                "(1 1 1)")

(check-external 'standard-write-import-string-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (display \"ok\" out)
                   (get-output-string out))"
                "\"ok\"")

(check-external 'standard-write-shared-output
                "(import (scheme base) (scheme write))
                 (let ((x (list 'a)))
                   (let ((out (open-output-string)))
                     (write-shared (list x x) out)
                     (get-output-string out)))"
                "\"(#0=(a) #0#)\"")

(check-external 'standard-write-circular-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (write '#1=(a . #1#) out)
                   (get-output-string out))"
                "\"#0=(a . #0#)\"")

(check-external 'standard-write-simple-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (write-simple '#(1 \"x\") out)
                   (get-output-string out))"
                "\"#(1 \\\"x\\\")\"")

(check-external 'standard-write-record-output
                "(import (scheme base) (scheme write))
                 (define-record-type <pare>
                   (kons x y)
                   pare?
                   (x kar)
                   (y kdr))
                 (let ((out (open-output-string)))
                   (write (kons 1 2) out)
                   (get-output-string out))"
                "\"#<record <pare>>\"")

(check-external 'standard-string-ports-read-and-write
                "(import (scheme base) (scheme read) (scheme write))
                 (let ((in (open-input-string \"(alpha 1) \"))
                       (out (open-output-string)))
                   (write (read in) out)
                   (write-char (read-char in) out)
                   (list (get-output-string out)
                         (eof-object? (read in))))"
                "(\"(alpha 1) \" #t)")

(check-external 'standard-string-port-read-write-round-trip
                "(import (scheme base) (scheme read) (scheme write))
                 (let ((out (open-output-string)))
                   (write '(a \"b\" #u8(1 2)) out)
                   (read (open-input-string (get-output-string out))))"
                "(a \"b\" #u8(1 2))")

(check-external 'standard-bytevector-ports-read-and-write
                "(import (scheme base))
                 (let ((in (open-input-bytevector #u8(1 2 3)))
                       (out (open-output-bytevector)))
                   (write-u8 (read-u8 in) out)
                   (write-bytevector (read-bytevector 4 in) out)
                   (list (eof-object? (read-u8 in))
                         (get-output-bytevector out)))"
                "(#t #u8(1 2 3))")

(check-external 'standard-eval-import-evaluates-scheme
                "(import (scheme base) (scheme eval))
                 (eval '(* 7 3) (environment '(scheme base)))"
                "21")

(check 'standard-eval-immutable-environment-rejects-definition
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme eval))
            (eval '(define foo 32) (environment '(scheme base)))")))
       #t)

(check 'standard-load-default-denied
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme load))
            (load \"fixtures/r7rs/include-body.scm\")")))
       #t)

(check-external/options 'standard-load-policy-allowed
                        "(import (scheme base) (scheme load))
                         (load \"fixtures/r7rs/include-body.scm\")
                         answer"
                        include-policy-options
                        "42")

(check 'standard-file-import-default-denied
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")))
       #t)

(check-external/options 'standard-file-import-policy-allowed
                        "(import (scheme base) (scheme file))
                         (file-exists?
                          \"fixtures/r7rs/conformance-cases.scm\")"
                        include-policy-options
                        "#t")

(check 'standard-host-libraries-import-and-default-deny
       (and
        (not
         (raises?
          (lambda ()
            (agent-scheme-eval-source
             "(import (scheme process-context) (scheme time) (scheme repl))
              'ok"))))
        (raises?
         (lambda ()
           (agent-scheme-eval-source
            "(import (scheme base) (scheme process-context))
             (command-line)")))
        (raises?
         (lambda ()
           (agent-scheme-eval-source
            "(import (scheme base) (scheme time))
             (current-second)")))
        (raises?
         (lambda ()
           (agent-scheme-eval-source
            "(import (scheme base) (scheme repl))
             (interaction-environment)"))))
       #t)

(check-external 'standard-r5rs-import
                "(import (scheme r5rs))
                 (list (+ 1 2)
                       (exact->inexact 3)
                       (inexact->exact 3.0))"
                "(3 3.0 3)")

(check 'imported-value-set-is-rejected
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (set! + 1)"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'imported-value-define-is-rejected
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (define + 1)"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'imported-syntax-define-is-rejected
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (define-syntax and
              (syntax-rules ()
                ((and) #t)))"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'duplicate-export-names-signal-error
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(define-library (agent-scheme fixture duplicate-export)
              (export value value)
              (import (scheme base))
              (begin (define value 1)))")))
       #t)

(check 'program-imports-precede-body
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            1
            (import (scheme cxr))
            'ok"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'expand-source-exposes-expanded-forms
       (agent-scheme-value->external
        (agent-scheme-expand-source
         "(define-syntax unless
            (syntax-rules ()
              ((unless test body ...)
               (if test #f (begin body ...)))))
          (unless #f 42)"))
       "((if #f #f (begin 42)))")

(check 'syntax-error-reports-source-form
       (let* ((result
               (agent-scheme-eval-source-result
                "(define-syntax bad-use
                   (syntax-rules ()
                     ((bad-use x)
                      (syntax-error \"bad macro\" x))))
                 (bad-use 123)"))
              (error-field (assq 'error (cdr result)))
              (message-field (assq 'message (cdr error-field))))
         (cadr message-field))
       "agent-scheme eval error: syntax-error while expanding (bad-use 123): \"bad macro\" 123")

(check 'result-rendering
       (agent-scheme-result->external
        (agent-scheme-eval-source-result "(+ 1 2)"))
       "(evaluation-result (status ok) (value 3) (events ()) (budget (steps-used 5) (host-calls 1)))")

(check-external 'closure
                "(define make-adder
                   (lambda (x)
                     (lambda (y) (+ x y))))
                 ((make-adder 4) 6)"
                "10")
(check-external 'internal-variable-definition
                "((lambda (x)
                    (define y 2)
                    (+ x y))
                  3)"
                "5")
(check-external 'internal-function-definition
                "((lambda (x)
                    (define (twice y) (+ y y))
                    (twice x))
                  5)"
                "10")
(check-external 'internal-definition-shadows-parent
                "((lambda ()
                    (define + (lambda (x y) x))
                    (+ 1 2)))"
                "1")

(let ((parent (agent-scheme-make-base-environment))
      (child #f))
  (set! child (agent-scheme-make-empty-environment parent))
  (check 'child-definition-shadows-parent
         (agent-scheme-value->external
          (agent-scheme-eval-source
           "(define + (lambda (x y) y))
            (+ 1 2)"
           child))
         "2")
  (check 'parent-primitive-remains-bound
         (agent-scheme-value->external
          (agent-scheme-eval-source "(+ 1 2)" parent))
         "3"))

(check-external 'set-mutates-local
                "((lambda (x)
                    (set! x (+ x 1))
                    x)
                  2)"
                "3")
(check-external 'set-mutates-captured
                "(define make-counter
                   (lambda ()
                     (define x 0)
                     (lambda ()
                       (set! x (+ x 1))
                       x)))
                 (define counter (make-counter))
                 (counter)
                 (counter)"
                "2")
(check 'set-unbound
       (raises? (lambda () (agent-scheme-eval-source "(set! missing 1)")))
       #t)

(check-external 'scheme-truthiness-false "(if #f 1 2)" "2")
(check-external 'scheme-truthiness-empty-list "(if '() 1 2)" "1")
(check-external 'if-without-alternate "(if #f 1)" "#<unspecified>")

(check-external 'variadic-formals "((lambda x x) 3 4 5)" "(3 4 5)")
(check-external 'dotted-formals
                "((lambda (x y . z) z) 3 4 5 6)"
                "(5 6)")
(check 'duplicate-formals
       (raises? (lambda ()
                  (agent-scheme-eval-source "((lambda (x x) x) 1 2)")))
       #t)
(check 'arity-error
       (raises? (lambda ()
                  (agent-scheme-eval-source "((lambda (x) x) 1 2)")))
       #t)

(check-external/options 'tail-recursive-loop
                        "(define (loop n acc)
                           (if (= n 0)
                               acc
                               (loop (- n 1) (+ acc 1))))
                         (loop 5000 0)"
                        '((max-steps . 100000)
                          (max-host-callbacks . 30000))
                        "5000")

(check 'step-budget
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(define (loop n) (loop n))
            (loop 0)"
           #f
           '((max-steps . 40)))))
       #t)
(check 'value-budget
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "'(1 2 3)"
           #f
           '((max-value-nodes . 2)))))
       #t)
(check 'host-callback-budget
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(+ 1 2)"
           #f
           '((max-host-callbacks . 0)))))
       #t)

(if (= failures 0)
    (begin
      (display "Scheme evaluator tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme evaluator test failure(s)")
      (newline)
      (error "Scheme evaluator tests failed")))
