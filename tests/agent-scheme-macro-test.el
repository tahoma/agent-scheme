;;; agent-scheme-macro-test.el --- R7RS syntax-rules tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for high-level hygienic `syntax-rules' macro expansion.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)

(defun agent-scheme-macro-test--external (source &optional options)
  "Evaluate SOURCE and return the stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source nil options)))

(ert-deftest agent-scheme-macro-test-define-syntax-expands-ellipsis ()
  "Expand a top-level syntax-rules macro with a repeated body template."
  (should
   (equal
    (agent-scheme-macro-test--external
     "(define x 0)
      (define-syntax unless
        (syntax-rules ()
          ((unless test body ...)
           (if test #f (begin body ...)))))
      (unless #f
        (set! x 41)
        (+ x 1))")
    "42")))

(ert-deftest agent-scheme-macro-test-introduced-bindings-are-hygienic ()
  "Keep introduced macro temporaries from capturing use-site identifiers."
  (should
   (equal
    (agent-scheme-macro-test--external
     "(define-syntax my-or
        (syntax-rules ()
          ((my-or) #f)
          ((my-or expr) expr)
          ((my-or expr next ...)
           (let ((temp expr))
             (if temp temp (my-or next ...))))))
      (let ((temp 99))
        (my-or #f temp))")
    "99")))

(ert-deftest agent-scheme-macro-test-let-syntax-is-referentially-transparent ()
  "Resolve free template identifiers in the transformer definition scope."
  (should
   (equal
    (agent-scheme-macro-test--external
     "(let ((x 'outer))
        (let-syntax ((m (syntax-rules ()
                          ((m) x))))
          (let ((x 'inner))
            (m))))")
    "outer")))

(ert-deftest agent-scheme-macro-test-free-template-identifiers-do-not-capture-use-site ()
  "Reject use-site capture for free identifiers introduced by a transformer."
  (should-error
   (agent-scheme-eval-source
    "(define-syntax expose-x
       (syntax-rules ()
         ((expose-x) x)))
     (let ((x 1))
       (expose-x))")
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-macro-test-letrec-syntax-allows-recursive-transformers ()
  "Let local transformers expand into locally bound syntax keywords."
  (should
   (equal
    (agent-scheme-macro-test--external
     "(letrec-syntax
          ((my-or
            (syntax-rules ()
              ((my-or) #f)
              ((my-or expr) expr)
              ((my-or expr next ...)
               (let ((temp expr))
                 (if temp temp (my-or next ...)))))))
        (my-or #f #f 7))")
    "7")))

(ert-deftest agent-scheme-macro-test-named-let-expands-through-letrec ()
  "Expand named let through the base syntax layer."
  (should
   (equal
    (agent-scheme-macro-test--external
     "(let loop ((n 5) (acc 0))
        (if (= n 0)
            acc
          (loop (- n 1) (+ acc 1))))")
    "5")))

;;; agent-scheme-macro-test.el ends here
