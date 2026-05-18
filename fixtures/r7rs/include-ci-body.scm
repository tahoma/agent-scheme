;;; Case-folded include fixture for Agent Scheme library include-ci tests.
;;;
;;; This file intentionally uses mixed case so include-ci can exercise folding.

;; Define the mixed-case value that include-ci folds before evaluation.
(define MixedAnswer (+ 40 2))
