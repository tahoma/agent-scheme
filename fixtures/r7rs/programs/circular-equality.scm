;;; circular-equality.scm --- Circular equivalence conformance
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program keeps datum-label syntax independently readable and outside
;;; the enclosing structured fixture datum, where labels have suite-wide scope.

(let ((left '#0=(a b . #0#))
      (right '#1=(a b a b . #1#)))
  (equal? left right))
