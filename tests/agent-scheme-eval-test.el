;;; agent-scheme-eval-test.el --- R7RS evaluator kernel tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for primitive expression evaluation, lexical environments,
;; procedures, mutation, tail recursion, and evaluator budgets.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)

(defun agent-scheme-eval-test--external (source &optional options)
  "Evaluate SOURCE and return the external representation of its value."
  (agent-scheme-value->external
   (agent-scheme-eval-source source nil options)))

(defun agent-scheme-eval-test--result-external (source &optional options)
  "Evaluate SOURCE and return the external representation of its result record."
  (agent-scheme-result->external
   (agent-scheme-eval-source-result source nil options)))

(ert-deftest agent-scheme-eval-test-literals-and-quote ()
  "Evaluate self-evaluating datums and quoted datums."
  (should (equal (agent-scheme-eval-test--external "42") "42"))
  (should (equal (agent-scheme-eval-test--external "#t") "#t"))
  (should (equal (agent-scheme-eval-test--external "\"ok\"") "\"ok\""))
  (should (equal (agent-scheme-eval-test--external "'alpha") "alpha"))
  (should (equal (agent-scheme-eval-test--external "'(1 2 3)") "(1 2 3)"))
  (should-error (agent-scheme-eval-source "()")
                :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-eval-test-variables-definitions-and-calls ()
  "Evaluate top-level definitions, variable references, and calls."
  (should
   (equal (agent-scheme-eval-test--external
           "(define answer 40)
            (+ answer 2)")
          "42"))
  (should
   (equal (agent-scheme-eval-test--external
           "(begin
              (define answer 42)
              answer)")
          "42"))
  (should
   (equal (agent-scheme-eval-test--external "((if #f + *) 3 4)")
          "12"))
  (should-error (agent-scheme-eval-source "missing")
                :type 'agent-scheme-eval-error)
  (should-error (agent-scheme-eval-source "(missing 1)")
                :type 'agent-scheme-eval-error)
  (should-error (agent-scheme-eval-source "(1 2)")
                :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-eval-test-definition-shadows-parent-frames ()
  "Define new names in the current frame without mutating parents."
  (let* ((parent (agent-scheme-make-base-environment))
         (child (agent-scheme-make-empty-environment parent)))
    (should
     (equal (agent-scheme-value->external
             (agent-scheme-eval-source
              "(define + (lambda (x y) y))
               (+ 1 2)"
              child))
            "2"))
    (should
     (equal (agent-scheme-value->external
             (agent-scheme-eval-source "(+ 1 2)" parent))
            "3"))))

(ert-deftest agent-scheme-eval-test-lexical-closures-and-internal-definitions ()
  "Evaluate closures with lexical scope and internal definitions."
  (should
   (equal (agent-scheme-eval-test--external
           "(define make-adder
              (lambda (x)
                (lambda (y) (+ x y))))
            ((make-adder 4) 6)")
          "10"))
  (should
   (equal (agent-scheme-eval-test--external
           "((lambda (x)
               (define y 2)
               (+ x y))
             3)")
          "5"))
  (should
   (equal (agent-scheme-eval-test--external
           "((lambda (x)
               (define (twice y) (+ y y))
               (twice x))
             5)")
          "10"))
  (should
   (equal (agent-scheme-eval-test--external
           "((lambda ()
               (define + (lambda (x y) x))
               (+ 1 2)))")
          "1")))

(ert-deftest agent-scheme-eval-test-set-mutates-lexical-locations ()
  "Evaluate set! against lexical and captured locations."
  (should
   (equal (agent-scheme-eval-test--external
           "((lambda (x)
               (set! x (+ x 1))
               x)
             2)")
          "3"))
  (should
   (equal (agent-scheme-eval-test--external
           "(define make-counter
              (lambda ()
                (define x 0)
                (lambda ()
                  (set! x (+ x 1))
                  x)))
            (define counter (make-counter))
            (counter)
            (counter)")
          "2"))
  (should-error (agent-scheme-eval-source "(set! missing 1)")
                :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-eval-test-if-uses-scheme-truthiness ()
  "Evaluate if with only #f as false."
  (should (equal (agent-scheme-eval-test--external "(if #f 1 2)") "2"))
  (should (equal (agent-scheme-eval-test--external "(if '() 1 2)") "1"))
  (should
   (equal (agent-scheme-eval-test--external "(if #f 1)")
          "#<unspecified>")))

(ert-deftest agent-scheme-eval-test-lambda-formals ()
  "Evaluate fixed, variadic, and dotted lambda formals."
  (should
   (equal (agent-scheme-eval-test--external "((lambda x x) 3 4 5)")
          "(3 4 5)"))
  (should
   (equal (agent-scheme-eval-test--external "((lambda (x y . z) z) 3 4 5 6)")
          "(5 6)"))
  (should-error (agent-scheme-eval-source "((lambda (x x) x) 1 2)")
                :type 'agent-scheme-eval-error)
  (should-error (agent-scheme-eval-source "((lambda (x) x) 1 2)")
                :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-eval-test-tail-recursive-loop-uses-trampoline ()
  "Run a tail-recursive loop beyond a shallow host recursion shape."
  (should
   (equal (agent-scheme-eval-test--external
           "(define (loop n acc)
              (if (= n 0)
                  acc
                (loop (- n 1) (+ acc 1))))
            (loop 5000 0)"
           '(:max-steps 100000
             :max-host-callbacks 30000))
          "5000")))

(ert-deftest agent-scheme-eval-test-budgets-fail-closed ()
  "Interrupt evaluations that exceed configured budgets."
  (should-error
   (agent-scheme-eval-source
    "(define (loop n) (loop n))
     (loop 0)"
    nil
    '(:max-steps 40))
   :type 'agent-scheme-budget-error)
  (should-error
   (agent-scheme-eval-source "'(1 2 3)" nil '(:max-value-nodes 2))
   :type 'agent-scheme-budget-error)
  (should-error
   (agent-scheme-eval-source "(+ 1 2)" nil '(:max-host-callbacks 0))
   :type 'agent-scheme-budget-error))

(ert-deftest agent-scheme-eval-test-multiple-values-and-binding-forms ()
  "Evaluate values, call-with-values, let-values, and let*-values."
  (should
   (string-match-p
    (regexp-quote
     "(evaluation-result (status values) (values (1 2))")
    (agent-scheme-eval-test--result-external "(values 1 2)")))
  (should
   (equal (agent-scheme-eval-test--external
           "(call-with-values (lambda () (values 4 5))
                              (lambda (a b) (- b a)))")
          "1"))
  (should
   (equal (agent-scheme-eval-test--external
           "(let-values (((a b) (values 1 2))
                         ((rest) (values '(x y))))
              (list a b rest))")
          "(1 2 (x y))"))
  (should
   (equal (agent-scheme-eval-test--external
           "(let ((a 'a) (b 'b) (x 'x) (y 'y))
              (let*-values (((a b) (values x y))
                            ((x y) (values a b)))
                (list a b x y)))")
          "(x y x y)")))

(ert-deftest agent-scheme-eval-test-continuations-and-dynamic-wind ()
  "Evaluate escape continuations and dynamic-wind exit thunks."
  (should
   (equal (agent-scheme-eval-test--external
           "(call/cc (lambda (escape) (+ 1 (escape 42))))")
          "42"))
  (should
   (equal (agent-scheme-eval-test--external
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
              (reverse path))")
          "(before during after)")))

(ert-deftest agent-scheme-eval-test-exceptions-and-guard ()
  "Evaluate R7RS exception handlers, guard, continuable raises, and error."
  (should
   (equal (agent-scheme-eval-test--external
           "(guard (exn (else (list 'caught exn)))
              (raise 'boom))")
          "(caught boom)"))
  (should
   (equal (agent-scheme-eval-test--external
           "(with-exception-handler
              (lambda (exn) 42)
              (lambda ()
                (+ (raise-continuable 'warning) 23)))")
          "65"))
  (should
   (equal (agent-scheme-eval-test--external
           "(guard (exn
                    ((error-object? exn)
                     (list (error-object-message exn)
                           (error-object-irritants exn))))
              (error \"bad input\" 'alpha 7))")
          "(\"bad input\" (alpha 7))")))

;;; agent-scheme-eval-test.el ends here
