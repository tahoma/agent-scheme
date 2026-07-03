;;; Case-folded include fixture for Consent Scheme library include-ci tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This file intentionally uses mixed case so include-ci can exercise folding.

;; Define the mixed-case value that include-ci folds before evaluation.
(define MixedAnswer
  (+ 40 2))
