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
(check 'unregistered-primitive
       (raises? (lambda () (agent-scheme-eval-source "(values 1 2)")))
       #t)

(let ((names (agent-scheme-base-primitive-names))
      (specs (agent-scheme-base-primitive-specs)))
  (check 'base-registry-names
         (and (memq '+ names)
              (memq 'apply names)
              (memq 'map names)
              (memq 'vector-ref names)
              (not (memq 'values names)))
         #t)
  (check 'base-registry-specs
         (cadr (assq 'minimum-arity
                     (find-primitive-spec 'vector-ref specs)))
         2))

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
                "(2.5 4 3 25 #t agent-scheme)")

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
