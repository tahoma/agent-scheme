(import (scheme base)
        (scheme write)
        (agent-scheme eval))

(define failures 0)

(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (check-external name source expected)
  (check name
         (agent-scheme-value->external (agent-scheme-eval-source source))
         expected))

(define (check-external/options name source options expected)
  (check name
         (agent-scheme-value->external
          (agent-scheme-eval-source source #f options))
         expected))

(define (check-result-external name source expected)
  (check name
         (agent-scheme-result->external
          (agent-scheme-eval-source-result source))
         expected))

(define (find-primitive-spec name specs)
  (cond
   ((null? specs) #f)
   ((eq? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-primitive-spec name (cdr specs)))))

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

(check-external 'base-list-helpers
                "(list (length (append '(1 2) '(3 4)))
                       (cadr '(alpha beta gamma))
                       (equal? '(1 \"x\") '(1 \"x\")))"
                "(4 beta #t)")

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

(check-external 'standard-char-and-cxr-imports
                "(import (scheme base) (scheme char) (scheme cxr))
                 (list (char-upcase #\\a)
                       (cadr '(alpha beta gamma)))"
                "(#\\A beta)")

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
