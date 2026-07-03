;;; SRFI 145 assume support for stdlib.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib assume)` as a portable SRFI 145 shim.  The public
;;; `(srfi 145)` and `(srfi srfi-145)` imports are registry aliases over this
;;; implementation.

(define-library (stdlib assume)
  (export assume)
  (import (scheme base))
  (begin
    ;; SRFI 145 `assume` returns the checked object on true assumptions and
    ;; reports false assumptions as invalid code paths.
    (define-syntax assume
      (syntax-rules ()
        ((_ obj message ...)
         (or obj
             (error "invalid assumption" 'obj message ...)))
        ((_ . _)
         (syntax-error "invalid assume syntax"))))))
