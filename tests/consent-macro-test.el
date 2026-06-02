;;; consent-macro-test.el --- R7RS syntax-rules tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for high-level hygienic `syntax-rules' macro expansion.

;;; Code:

(require 'ert)
(require 'consent-eval)

(defun consent-macro-test--external (source &optional options)
  "Evaluate SOURCE and return the stable external value representation."
  (consent-value->external
   (consent-eval-source source nil options)))

(ert-deftest consent-macro-test-syntax-source-reports-reader-metadata ()
  "Return reader source metadata by default with an explicit opt-out."
  (let* ((default-datum (consent-read "\n  (twice 21)\n"))
         (disabled-datum (consent-read "\n  (twice 21)\n"
                                            '(:source-metadata nil)))
         (source (consent-syntax-source default-datum)))
    (should
     (equal
      (consent-value->external source)
      "(source (origin source) (source-id #f) (line 2) (column 3) (offset 3) (span 10) (phase read))"))
    (should
     (equal
      (consent-value->external
       (consent-syntax-source disabled-datum))
      "#f"))))

(ert-deftest consent-macro-test-define-syntax-expands-ellipsis ()
  "Expand a top-level syntax-rules macro with a repeated body template."
  (should
   (equal
    (consent-macro-test--external
     "(define x 0)
      (define-syntax unless
        (syntax-rules ()
          ((unless test body ...)
           (if test #f (begin body ...)))))
      (unless #f
        (set! x 41)
        (+ x 1))")
    "42")))

(ert-deftest consent-macro-test-introduced-bindings-are-hygienic ()
  "Keep introduced macro temporaries from capturing use-site identifiers."
  (should
   (equal
    (consent-macro-test--external
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

(ert-deftest consent-macro-test-let-syntax-is-referentially-transparent ()
  "Resolve free template identifiers in the transformer definition scope."
  (should
   (equal
    (consent-macro-test--external
     "(let ((x 'outer))
        (let-syntax ((m (syntax-rules ()
                          ((m) x))))
          (let ((x 'inner))
            (m))))")
    "outer")))

(ert-deftest consent-macro-test-free-template-identifiers-do-not-capture-use-site ()
  "Reject use-site capture for free identifiers introduced by a transformer."
  (should-error
   (consent-eval-source
    "(define-syntax expose-x
       (syntax-rules ()
         ((expose-x) x)))
     (let ((x 1))
       (expose-x))")
   :type 'consent-eval-error))

(ert-deftest consent-macro-test-letrec-syntax-allows-recursive-transformers ()
  "Let local transformers expand into locally bound syntax keywords."
  (should
   (equal
    (consent-macro-test--external
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

(ert-deftest consent-macro-test-named-let-expands-through-letrec ()
  "Expand named let through the base syntax layer."
  (should
   (equal
    (consent-macro-test--external
     "(let loop ((n 5) (acc 0))
        (if (= n 0)
            acc
          (loop (- n 1) (+ acc 1))))")
    "5")))

(ert-deftest consent-macro-test-cond-arrow-respects-literal-binding ()
  "Treat `=>' as syntax only when the use-site binding matches."
  (should
   (equal
    (consent-macro-test--external
     "(list
        (cond ((assv 'b '((a 1) (b 2))) => cadr)
              (else #f))
        (let ((=> #f))
          (cond (#t => 'ok))))")
    "(2 ok)")))

(ert-deftest consent-macro-test-case-expands-from-base-syntax ()
  "Expand R7RS case clauses through the base syntax prelude."
  (should
   (equal
    (consent-macro-test--external
     "(list
        (case (car '(c d))
          ((a e i o u) 'vowel)
          ((c d) 'consonant)
          (else 'other))
        (case 'b
          ((a) 'a)
          ((b c) => (lambda (x) (list x 'hit)))
          (else #f)))")
    "(consonant (b hit))")))

(ert-deftest consent-macro-test-do-expands-nested-ellipses ()
  "Expand R7RS do through nested ellipses in the shared syntax prelude."
  (should
   (equal
    (consent-macro-test--external
     "(do ((i 0 (+ i 1))
           (acc 0 (+ acc i)))
          ((= i 5) acc))")
    "10")))

(ert-deftest consent-macro-test-dotted-patterns-and-templates ()
  "Match improper syntax-rules patterns and produce improper templates."
  (should
   (equal
    (consent-macro-test--external
     "(define-syntax rest-list
        (syntax-rules ()
          ((rest-list first . rest)
           'rest)))
      (define-syntax make-pair
        (syntax-rules ()
          ((make-pair left right)
           '(left . right))))
      (list (rest-list a b c)
            (make-pair alpha beta))")
    "((b c) (alpha . beta))")))

(ert-deftest consent-macro-test-nested-ellipsis-template-expands ()
  "Distribute nested ellipsis matches through nested templates."
  (should
   (equal
    (consent-macro-test--external
     "(define-syntax echo-groups
        (syntax-rules ()
          ((echo-groups ((head item ...) ...))
           '((head item ...) ...))))
      (echo-groups ((a 1 2) (b 3) (c)))")
    "((a 1 2) (b 3) (c))")))

(ert-deftest consent-macro-test-quasiquote-evaluates-unquotes ()
  "Evaluate quasiquote templates, including splicing and vectors."
  (should
   (equal
    (consent-macro-test--external
     "(list
        (quasiquote (a (unquote (+ 1 2))
                       (unquote-splicing (list 'b 'c))))
        (quasiquote #(1 (unquote (+ 1 2))))
        (quasiquote (outer
                      (quasiquote (inner (unquote (+ 1 2))))
                      (unquote (+ 2 3)))))")
    "((a 3 b c) #(1 3) (outer (quasiquote (inner (unquote (+ 1 2)))) 5))")))

(ert-deftest consent-macro-test-cond-expand-selects-base-feature ()
  "Expand recognized cond-expand feature clauses from the syntax prelude."
  (should
   (equal
    (consent-macro-test--external
     "(list
        (cond-expand (r7rs 'ok) (else 'missing))
        (cond-expand ((library (scheme base)) 'base) (else 'missing)))")
    "(ok base)")))

(ert-deftest consent-macro-test-expand-source-exposes-expanded-forms ()
  "Expose a source-level macro expansion phase before evaluation."
  (should
   (equal
    (consent-value->external
     (consent-expand-source
      "(define-syntax unless
         (syntax-rules ()
           ((unless test body ...)
            (if test #f (begin body ...)))))
       (unless #f 42)"))
    "((if #f #f (begin 42)))")))

(ert-deftest consent-macro-test-syntax-error-reports-source-form ()
  "Include the original macro use in expansion-time syntax errors."
  (let* ((condition
          (should-error
           (consent-eval-source
            "(define-syntax bad-use
               (syntax-rules ()
                 ((bad-use x)
                  (syntax-error \"bad macro\" x))))
             (bad-use 123)")
           :type 'consent-eval-error))
         (message (cadr condition)))
    (should (string-match-p "while expanding (bad-use 123)" message))
    (should (string-match-p "bad macro" message))))

(ert-deftest consent-macro-test-macroexpand-1-returns-readable-step-datum ()
  "Expose one-step macro expansion as a Scheme-readable introspection record."
  (let ((external
         (consent-macro-test--external
          "(import (scheme base) (agent reflect))
           (define-syntax my-unless
             (syntax-rules ()
               ((my-unless test body ...)
                (if test #f (begin body ...)))))
           (macroexpand-1 '(my-unless #f 42))"
          '(:source-metadata t))))
    (should (string-match-p (regexp-quote "(macro-expansion") external))
    (should (string-match-p (regexp-quote "(status ok)") external))
    (should (string-match-p (regexp-quote "(mode one-step)") external))
    (should (string-match-p
             (regexp-quote "(original (my-unless #f 42))")
             external))
    (should (string-match-p
             (regexp-quote "(expanded (if #f #f (begin 42)))")
             external))
    (should (string-match-p
             (regexp-quote "(step (index 1) (macro my-unless)")
             external))
    (should (string-match-p
             (regexp-quote "(source (origin source)")
             external))))

(ert-deftest consent-macro-test-macroexpand-does-not-evaluate-expanded-form ()
  "Inspecting a macro expansion must not run effects in the expanded form."
  (should
   (equal
    (consent-macro-test--external
     "(import (scheme base) (agent reflect))
      (define touched #f)
      (define-syntax run!
        (syntax-rules ()
          ((run!) (begin (set! touched #t) 99))))
      (let ((expansion (macroexpand '(run!))))
        (list (cadr (assq 'expanded (cdr expansion)))
              touched))")
    "((begin (set! touched #t) 99) #f)")))

(ert-deftest consent-macro-test-macroexpand-expands-local-syntax-scope ()
  "Full macro expansion preserves let-syntax bindings while expanding."
  (should
   (equal
    (consent-macro-test--external
     "(import (scheme base) (agent reflect))
      (let ((expansion
             (macroexpand
              '(let-syntax
                   ((twice
                     (syntax-rules ()
                       ((twice value) (+ value value)))))
                 (twice 21)))))
        (list (cadr (assq 'expanded (cdr expansion)))
              (cadr (assq 'macros (cdr expansion)))))")
    "((begin (+ 21 21)) (let-syntax))")))

(ert-deftest consent-macro-test-macroexpand-reports-budget-errors ()
  "Expansion budgets stop runaway or oversized macro expansion attempts."
  (let ((external
         (consent-macro-test--external
          "(import (scheme base) (agent reflect))
           (macroexpand
            '(let loop ((n 1)) (loop n))
            '((max-steps 1)))")))
    (should (string-match-p (regexp-quote "(macro-expansion") external))
    (should (string-match-p (regexp-quote "(status error)") external))
    (should (string-match-p (regexp-quote "(type budget-exhausted)")
                            external))
    (should (string-match-p (regexp-quote "(phase macro-expansion)")
                            external))))

(ert-deftest consent-macro-test-macro-binding-info-and-source-metadata ()
  "Expose macro binding metadata, default source metadata, and opt-out."
  (should
   (equal
    (consent-macro-test--external
     "(import (scheme base) (agent reflect))
      (define-syntax twice
        (syntax-rules ()
          ((twice value) (+ value value))))
      (list (macro-binding-info 'twice)
            (macro-binding-info 'missing)
            (let ((source (syntax-source '(twice 21))))
              (list (cadr (assq 'origin (cdr source)))
                    (cadr (assq 'phase (cdr source)))))
            (syntax-source (list 'twice 21))
            (equal? '(twice 21) (list 'twice 21)))"
     '(:source-metadata t))
    "((macro-binding (identifier twice) (status bound) (kind syntax-rules) (library #f)) #f (source read) #f #t)"))
  (should
   (equal
    (consent-macro-test--external
     "(import (scheme base) (agent reflect))
      (define-syntax twice
        (syntax-rules ()
          ((twice value) (+ value value))))
      (list (macro-binding-info 'twice)
            (macro-binding-info 'missing)
            (syntax-source '(twice 21))
            (syntax-source (list 'twice 21))
            (equal? '(twice 21) (list 'twice 21)))"
     '(:source-metadata nil))
    "((macro-binding (identifier twice) (status bound) (kind syntax-rules) (library #f)) #f #f #f #t)")))

(ert-deftest consent-macro-test-macroexpand-library-lists-syntax-exports ()
  "Inspect library macro exports without evaluating a macro use."
  (let ((external
         (consent-macro-test--external
          "(import (scheme base) (agent reflect))
           (macroexpand-library '(scheme base))")))
    (should (string-match-p (regexp-quote "(macro-library") external))
    (should (string-match-p (regexp-quote "(library (scheme base))")
                            external))
    (should (string-match-p (regexp-quote "(macro cond (kind syntax-rules))")
                            external))
    (should (string-match-p (regexp-quote "(macro let (kind syntax-rules))")
                            external))))

(ert-deftest consent-macro-test-macroexpand-yield-records-expansion-event ()
  "Yield macro expansion records into the evaluation event stream."
  (let ((external
         (consent-result->external
          (consent-eval-source-result
           "(import (scheme base) (agent reflect))
            (define-syntax my-unless
              (syntax-rules ()
                ((my-unless test body ...)
                 (if test #f (begin body ...)))))
            (macroexpand-yield '(my-unless #f 42) '())"))))
    (should (string-match-p (regexp-quote "(status ok)") external))
    (should (string-match-p (regexp-quote "(value (macro-expansion")
                            external))
    (should (string-match-p (regexp-quote "(events ((macroexpand")
                            external))
    (should (string-match-p (regexp-quote "(expanded (if #f #f (begin 42)))")
                            external))))

;;; consent-macro-test.el ends here
