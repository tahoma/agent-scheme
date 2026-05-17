;;; agent-scheme-base-test.el --- R7RS base primitive tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the initial `(scheme base)' primitive registry, common
;; base-library procedures, higher-order helpers, and result encoding.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-eval)

(defun agent-scheme-base-test--external (source &optional options)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source nil options)))

(ert-deftest agent-scheme-base-test-registry-is-discoverable ()
  "Expose kernel and prelude binding metadata from Emacs."
  (let ((names (agent-scheme-base-primitive-names))
        (prelude-names (agent-scheme-base-prelude-binding-names))
        (specs (agent-scheme-base-primitive-specs))
        (binding-specs (agent-scheme-base-binding-specs)))
    (dolist (name '("+" "apply" "car" "vector-ref" "bytevector-u8-ref"))
      (should (member name names)))
    (dolist (name '("append" "cadr" "length" "map" "zero?"))
      (should-not (member name names))
      (should (member name prelude-names)))
    (dolist (name '("call-with-values" "call/cc" "dynamic-wind" "values"))
      (should (member name names)))
    (should
     (equal (plist-get
             (seq-find
              (lambda (spec)
                (equal (plist-get spec :name) "vector-ref"))
              specs)
             :minimum-arity)
            2))
    (should
     (eq (plist-get
          (seq-find
           (lambda (spec)
             (equal (plist-get spec :name) "vector-ref"))
           binding-specs)
          :source)
         'kernel))
    (should
     (eq (plist-get
          (seq-find
           (lambda (spec)
             (equal (plist-get spec :name) "append"))
           binding-specs)
          :source)
         'prelude))))

(ert-deftest agent-scheme-base-test-pairs-lists-and-equality ()
  "Evaluate common pair, list, association, and equality procedures."
  (should
   (equal (agent-scheme-base-test--external
           "(length (append '(1 2) '(3 4)))")
          "4"))
  (should
   (equal (agent-scheme-base-test--external "(cadr '(alpha beta gamma))")
          "beta"))
  (should
   (equal (agent-scheme-base-test--external
           "(define pair (list 1 2))
            (set-car! pair 9)
            pair")
          "(9 2)"))
  (should
   (equal (agent-scheme-base-test--external
           "(assoc 'b '((a . 1) (b . 2)))")
          "(b . 2)"))
  (should
   (equal (agent-scheme-base-test--external
           "(list (eq? 'a 'a) (eqv? 1 1) (equal? '(1 \"x\") '(1 \"x\")))")
          "(#t #t #t)")))

(ert-deftest agent-scheme-base-test-numbers-booleans-symbols-characters-strings ()
  "Evaluate scalar base-library procedures."
  (should
   (equal (agent-scheme-base-test--external
           "(list (/ 5 2) (abs -4) (modulo -13 4) (square 5))")
          "(2.5 4 3 25)"))
  (should
   (equal (agent-scheme-base-test--external
           "(list (boolean=? #t (not #f))
                  (integer? 4.0)
                  (exact-integer? 4)
                  (inexact? 4.0))")
          "(#t #t #t #t)"))
  (should
   (equal (agent-scheme-base-test--external
           "(string->symbol (symbol->string 'agent-scheme))")
          "agent-scheme"))
  (should
   (equal (agent-scheme-base-test--external
           "(list (char->integer #\\A)
                  (integer->char 66)
                  (string-ref (string #\\o #\\k) 1)
                  (string-append \"ag\" \"ent\"))")
          "(65 #\\B #\\k \"agent\")")))

(ert-deftest agent-scheme-base-test-vectors-bytevectors-and-higher-order-calls ()
  "Evaluate vector, bytevector, apply, map, and for-each procedures."
  (should
   (equal (agent-scheme-base-test--external
           "(define v (vector 'a 'b 'c))
            (vector-set! v 1 'changed)
            v")
          "#(a changed c)"))
  (should
   (equal (agent-scheme-base-test--external
           "(define b (bytevector 1 2 3))
            (bytevector-u8-set! b 1 9)
            b")
          "#u8(1 9 3)"))
  (should
   (equal (agent-scheme-base-test--external "(apply + 1 '(2 3 4))")
          "10"))
  (should
   (equal (agent-scheme-base-test--external
           "(map (lambda (x) (* x x)) '(2 3 4))")
          "(4 9 16)"))
  (should
   (equal (agent-scheme-base-test--external
           "(define total 0)
            (for-each (lambda (x) (set! total (+ total x))) '(1 2 3))
            total")
          "6")))

(ert-deftest agent-scheme-base-test-arity-type-errors-and-result-rendering ()
  "Cover primitive errors and stable Scheme-readable result records."
  (should-error (agent-scheme-eval-source "(car '())")
                :type 'agent-scheme-eval-error)
  (should-error (agent-scheme-eval-source "(+ 1 \"bad\")")
                :type 'agent-scheme-eval-error)
  (should-error (agent-scheme-eval-source "(map + '(1 2) 3)")
                :type 'agent-scheme-eval-error)
  (should
   (equal (agent-scheme-result->external
           (agent-scheme-eval-source-result "(+ 1 2)"))
          "(evaluation-result (status ok) (value 3) (events ()) (budget (steps-used 5) (host-calls 1)))"))
  (should
   (string-match-p
    (regexp-quote
     "(evaluation-result (status error) (error (condition agent-scheme-eval-error)")
    (agent-scheme-result->external
     (agent-scheme-eval-source-result "(car '())")))))

;;; agent-scheme-base-test.el ends here
