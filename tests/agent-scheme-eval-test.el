;;; agent-scheme-eval-test.el --- R7RS evaluator kernel tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the Emacs Lisp evaluator kernel. Shared external evaluator
;; behavior runs through the canonical fixture corpus; these tests keep
;; host-side environment mutation, closure identity, continuation machinery,
;; budgets, and library internals close to the implementation.

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
  "Evaluate values, call-with-values, define-values, and binding forms."
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
          "(x y x y)"))
  (should
   (equal (agent-scheme-eval-test--external
           "(define-values (root remainder)
              (exact-integer-sqrt 17))
            (define-values (head . tail)
              (values 'a 'b 'c))
            (define-values all
              (values 8 13))
            (list root remainder (cons head tail) all)")
          "(4 1 (a b c) (8 13))"))
  (should
   (equal (agent-scheme-eval-test--external
           "((lambda ()
               (define-values (left right)
                 (values 8 13))
               (list left right)))")
          "(8 13)")))

(ert-deftest agent-scheme-eval-test-continuations-and-dynamic-wind ()
  "Evaluate re-enterable continuations and dynamic-wind transitions."
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
          "(before during after)"))
  (should
   (equal (agent-scheme-eval-test--external
           "(let ((again #f))
              (let ((value (call/cc
                            (lambda (k)
                              (set! again k)
                              'first))))
                (if (eq? value 'first)
                    (again 'second)
                  value)))")
          "second"))
  (should
   (equal (agent-scheme-eval-test--external
           "(let ((again #f)
                  (seen '()))
              (let ((value (call/cc
                            (lambda (k)
                              (set! again k)
                              'start))))
                (set! seen (cons value seen))
                (if (< (length seen) 3)
                    (again (length seen))
                  (reverse seen))))")
          "(start 1 2)"))
  (should
   (equal (agent-scheme-eval-test--external
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
                (reverse path)))")
          "(before-outer before-inner during-inner after-inner after-outer before-outer before-inner during-inner after-inner after-outer)"))
  (should
   (equal (agent-scheme-eval-test--external
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
                   (list a b)))))")
          "(3 4)"))
  (should
   (equal (agent-scheme-eval-test--external
           "(let ((again #f))
              (let-values (((a b)
                            (call/cc
                             (lambda (k)
                               (set! again k)
                               (values 1 2)))))
                (if (= a 1)
                    (again 3 4)
                  (list a b))))")
          "(3 4)"))
  (should
   (equal (agent-scheme-eval-test--external
           "(let ((again #f))
              (let*-values (((a b)
                             (call/cc
                              (lambda (k)
                                (set! again k)
                                (values 1 2))))
                            ((c) (+ a b)))
                (if (= a 1)
                    (again 3 4)
                  (list a b c))))")
          "(3 4 7)")))

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

(defun agent-scheme-eval-test--fresh-context ()
  "Return a cons of a fresh evaluation context and base environment."
  (let ((context (agent-scheme--new-eval-context nil))
        (environment (agent-scheme-make-base-environment)))
    (setf (agent-scheme--eval-context-interaction-environment context)
          environment)
    (agent-scheme--ensure-base-syntax context environment)
    (cons context environment)))

(defun agent-scheme-eval-test--run-on (source context environment)
  "Evaluate SOURCE through the CPS trampoline on CONTEXT and ENVIRONMENT."
  (agent-scheme--trampoline
   (agent-scheme--make-sequence (agent-scheme-read-all source nil) t)
   environment
   context))

(ert-deftest agent-scheme-eval-test-exception-handler-unwind-safe ()
  "A handler that re-raises non-continuably restores handler state.
Whether the exception machinery runs through the CPS trampoline or the
direct (non-`/k') primitive, an Emacs Lisp `signal' escaping the invoked
handler must leave `exception-handlers' and `current-error' at their
pre-evaluation baseline.  Regression for the CPS path that previously
restored that state only inside its success continuation."
  ;; CPS path: the inner handler re-raises non-continuably; the outer
  ;; handler returns, which signals "non-continuable exception handler
  ;; returned" before any success continuation can pop the installed
  ;; frames.
  (let* ((cell (agent-scheme-eval-test--fresh-context))
         (context (car cell))
         (environment (cdr cell))
         (baseline-handlers
          (agent-scheme--eval-context-exception-handlers context))
         (baseline-error
          (agent-scheme--eval-context-current-error context)))
    (should-error
     (agent-scheme-eval-test--run-on
      "(with-exception-handler
         (lambda (outer) 'outer-returned)
         (lambda ()
           (with-exception-handler
            (lambda (inner) (raise 'from-inner))
            (lambda () (raise 'original)))))"
      context environment)
     :type 'agent-scheme-eval-error)
    (should (equal (agent-scheme--eval-context-exception-handlers context)
                   baseline-handlers))
    (should (eq (agent-scheme--eval-context-current-error context)
                baseline-error)))
  ;; Direct path: enter through the non-`/k' `with-exception-handler'
  ;; primitive with the same nested scenario built as procedures.
  (let* ((cell (agent-scheme-eval-test--fresh-context))
         (context (car cell))
         (environment (cdr cell))
         (handler
          (agent-scheme-eval-test--run-on
           "(lambda (outer) 'outer-returned)" context environment))
         (thunk
          (agent-scheme-eval-test--run-on
           "(lambda ()
              (with-exception-handler
               (lambda (inner) (raise 'from-inner))
               (lambda () (raise 'original))))"
           context environment))
         (baseline-handlers
          (agent-scheme--eval-context-exception-handlers context))
         (baseline-error
          (agent-scheme--eval-context-current-error context)))
    (should-error
     (agent-scheme--primitive-with-exception-handler
      (list handler thunk) context)
     :type 'agent-scheme-eval-error)
    (should (equal (agent-scheme--eval-context-exception-handlers context)
                   baseline-handlers))
    (should (eq (agent-scheme--eval-context-current-error context)
                baseline-error))))

(ert-deftest agent-scheme-eval-test-current-error-restored-after-escape ()
  "Escaping a handler resets `current-error' to its capture-time value.
A continuation escape (`guard' or `call/cc') reinstates the dynamic state
snapshotted with the continuation, so `current-error' must not leak the
handled condition past the escape -- the continuation-escape companion to
the CPS handler-stack unwind-safety guarantee.  A live, non-escaping
handler must still observe the condition so the debugger inspection path
keeps working."
  ;; A guard escape clears the handled condition afterward.
  (should
   (equal (agent-scheme-eval-test--external
           "(import (scheme base) (agent debugger))
            (guard (exn (else 'caught)) (raise 'boom))
            (current-error)")
          "#f"))
  ;; A call/cc escape out of a handler clears it too.
  (should
   (equal (agent-scheme-eval-test--external
           "(import (scheme base) (agent debugger))
            (call/cc
             (lambda (k)
               (with-exception-handler
                (lambda (condition) (k 'escaped))
                (lambda () (raise 'boom)))))
            (current-error)")
          "#f"))
  ;; A non-escaping handler still observes the live condition.
  (should
   (equal (agent-scheme-eval-test--external
           "(import (scheme base) (agent debugger))
            (with-exception-handler
             (lambda (condition)
               (if (current-error) 'sees-condition 'blank))
             (lambda () (raise-continuable 'boom)))")
          "sees-condition")))

(ert-deftest agent-scheme-eval-test-dynamic-wind-after-runs-on-raise ()
  "A `dynamic-wind' after thunk runs when a raise unwinds to an outer guard.
Companion to the call/cc-escape dynamic-wind coverage: an exception escape
must run pending after thunks while unwinding to the handler."
  (should
   (equal (agent-scheme-eval-test--external
           "(let ((log '()))
              (define (add tag) (set! log (cons tag log)))
              (guard (exn (else (add 'caught) (reverse log)))
                (dynamic-wind
                 (lambda () (add 'before))
                 (lambda () (add 'during) (raise 'x))
                 (lambda () (add 'after)))))")
          "(before during after caught)")))

;;; agent-scheme-eval-test.el ends here
