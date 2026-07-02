;;; SRFI 2 and-let* support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 1998 Oleg Kiselyov
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib and-let-star)` using the official SRFI 2 sample macro
;;; from https://okmij.org/ftp/Scheme/lib/myenv-chez.scm.  Local patches wrap
;;; the macro in an R7RS `define-library` form and expose `(srfi 2)` and
;;; `(srfi srfi-2)` as registry aliases.

(define-library (stdlib and-let-star)
  (export and-let*)
  (import (scheme base))
  (begin
    ;; SRFI 2 `and-let*` expands guarded sequential clauses into `and` and
    ;; `let` while preserving the no-body "return the last claw" behavior.
    (define-syntax and-let*
      (syntax-rules ()
        ((_ ()) #t)
        ((_ claws)
         (and-let* "search-last-claw" () claws))
        ((_ "search-last-claw" first-claws ((exp)))
         (and-let* first-claws exp))
        ((_ "search-last-claw" first-claws ((var exp)))
         (and-let* first-claws exp))
        ((_ "search-last-claw" first-claws (var))
         (and-let* first-claws var))
        ((_ "search-last-claw" (first-claw ...) (claw . rest))
         (and-let* "search-last-claw" (first-claw ... claw) rest))
        ((_ () . body)
         (begin . body))
        ((_ ((exp) . claws) . body)
         (and exp (and-let* claws . body)))
        ((_ ((var exp) . claws) . body)
         (let ((var exp))
           (and var (and-let* claws . body))))
        ((_ (var . claws) . body)
         (and var (and-let* claws . body)))))))
