;;; Adapted SRFI 2 and-let* test suite.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 1998 Oleg Kiselyov
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the upstream SRFI 2 `vland.scm` validation tests at
;;; https://okmij.org/ftp/Scheme/tests/vland.scm.  The original tests depend on
;;; implementation-specific `eval` and exception helpers; this file keeps the
;;; representative portable behavior checks in the full Consent Scheme host
;;; matrix.

(import (scheme base)
        (scheme write)
        (stdlib and-let-star)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(testing-registry-case
 'no-claws-one-body '(portable stdlib)
(test-equal 'no-claws-one-body 1 (and-let* () 1)))
(testing-registry-case
 'no-claws-multiple-body '(portable stdlib)
(test-equal 'no-claws-multiple-body 2 (and-let* () 1 2)))
(testing-registry-case
 'no-claws-no-body '(portable stdlib)
(test-equal 'no-claws-no-body #t (and-let* ())))

(testing-registry-case
 'one-bound-variable-false '(portable stdlib)
(test-equal 'one-bound-variable-false
             #f
             (let ((x #f)) (and-let* (x)))))
(testing-registry-case
 'one-bound-variable-true '(portable stdlib)
(test-equal 'one-bound-variable-true
             1
             (let ((x 1)) (and-let* (x)))))
(testing-registry-case
 'one-expression-claw '(portable stdlib)
(test-equal 'one-expression-claw
             2
             (let ((x 1)) (and-let* (((+ x 1)))))))
(testing-registry-case
 'one-binding-claw-false '(portable stdlib)
(test-equal 'one-binding-claw-false #f (and-let* ((x #f)))))
(testing-registry-case
 'one-binding-claw-true '(portable stdlib)
(test-equal 'one-binding-claw-true 1 (and-let* ((x 1)))))

(testing-registry-case
 'two-claws-short-circuit '(portable stdlib)
(test-equal 'two-claws-short-circuit #f (and-let* ((#f) (x 1)))))
(testing-registry-case
 'two-claws-expression-before-binding '(portable stdlib)
(test-equal 'two-claws-expression-before-binding 1 (and-let* ((2) (x 1)))))
(testing-registry-case
 'two-claws-binding-before-expression '(portable stdlib)
(test-equal 'two-claws-binding-before-expression 2 (and-let* ((x 1) (2)))))
(testing-registry-case
 'two-claws-binding-before-variable '(portable stdlib)
(test-equal 'two-claws-binding-before-variable 1 (and-let* ((x 1) x))))
(testing-registry-case
 'two-claws-binding-before-variable-expression '(portable stdlib)
(test-equal 'two-claws-binding-before-variable-expression
             1
             (and-let* ((x 1) (x)))))

(testing-registry-case
 'bound-variable-body-false '(portable stdlib)
(test-equal 'bound-variable-body-false
             #f
             (let ((x #f)) (and-let* (x) x))))
(testing-registry-case
 'bound-variable-body-true '(portable stdlib)
(test-equal 'bound-variable-body-true
             ""
             (let ((x "")) (and-let* (x) x))))
(testing-registry-case
 'expression-guard-body '(portable stdlib)
(test-equal 'expression-guard-body
             2
             (let ((x 1)) (and-let* (((positive? x))) (+ x 1)))))
(testing-registry-case
 'expression-guard-no-body '(portable stdlib)
(test-equal 'expression-guard-no-body
             #t
             (let ((x 1)) (and-let* (((positive? x)))))))
(testing-registry-case
 'expression-guard-false '(portable stdlib)
(test-equal 'expression-guard-false
             #f
             (let ((x 0)) (and-let* (((positive? x))) (+ x 1)))))
(testing-registry-case
 'duplicate-bindings-are-sequential '(portable stdlib)
(test-equal 'duplicate-bindings-are-sequential
             4
             (let ((x 1))
         (and-let* (((positive? x))
                    (x (+ x 1))
                    (x (+ x 1)))
           (+ x 1)))))

(testing-registry-case
 'variable-guard-expression '(portable stdlib)
(test-equal 'variable-guard-expression
             2
             (let ((x 1)) (and-let* (x ((positive? x))) (+ x 1)))))
(testing-registry-case
 'variable-guard-false '(portable stdlib)
(test-equal 'variable-guard-false
             #f
             (let ((x #f)) (and-let* (x ((positive? x))) (+ x 1)))))
(testing-registry-case
 'later-guard-prevents-body '(portable stdlib)
(test-equal 'later-guard-prevents-body
             #f
             (let ((x 1))
         (and-let* (x (y (- x 1)) ((positive? y))) (/ x y)))))
(testing-registry-case
 'all-guards-pass '(portable stdlib)
(test-equal 'all-guards-pass
             (/ 3 2)
             (let ((x 3))
         (and-let* (x (y (- x 1)) ((positive? y))) (/ x y)))))

(testing-runner-main "Stdlib And Let Star portable tests" (command-line))
