;;; SRFI 8 receive support for stdlib.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib receive)` as a portable shim over R7RS
;;; `call-with-values` and lambda formals.  The public `(srfi 8)`,
;;; `(srfi srfi-8)`, `(srfi :8)`, and `(srfi :8 receive)` imports are registry
;;; aliases over this implementation.

(define-library (stdlib receive)
  (export receive)
  (import (scheme base))
  (begin
    ;; SRFI 8 `receive` is the direct binding form for multiple values.
    (define-syntax receive
      (syntax-rules ()
        ((_ formals expression body ...)
         (call-with-values (lambda () expression)
                           (lambda formals body ...)))))))
