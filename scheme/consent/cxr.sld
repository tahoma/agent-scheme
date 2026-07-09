;;; Portable source for the R7RS `(scheme cxr)' library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; These accessors are pure compositions of `(scheme base)' `car' and `cdr'.
;;; Keeping them as source keeps the host primitive interface minimal.

(define-library (scheme cxr)
  (export caaar caadr cadar caddr cdaar cdadr cddar cdddr
          caaaar caaadr caadar caaddr cadaar cadadr caddar cadddr
          cdaaar cdaadr cdadar cdaddr cddaar cddadr cdddar cddddr)
  (import (scheme base))
  (begin
    (define (caaar pair)
      "Return the car of the car of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (car (car pair))))

    (define (caadr pair)
      "Return the car of the car of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (car (cdr pair))))

    (define (cadar pair)
      "Return the car of the cdr of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (cdr (car pair))))

    (define (caddr pair)
      "Return the car of the cdr of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (cdr (cdr pair))))

    (define (cdaar pair)
      "Return the cdr of the car of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (car (car pair))))

    (define (cdadr pair)
      "Return the cdr of the car of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (car (cdr pair))))

    (define (cddar pair)
      "Return the cdr of the cdr of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (cdr (car pair))))

    (define (cdddr pair)
      "Return the cdr of the cdr of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (cdr (cdr pair))))

    (define (caaaar pair)
      "Return the car of the car of the car of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (car (car (car pair)))))

    (define (caaadr pair)
      "Return the car of the car of the car of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (car (car (cdr pair)))))

    (define (caadar pair)
      "Return the car of the car of the cdr of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (car (cdr (car pair)))))

    (define (caaddr pair)
      "Return the car of the car of the cdr of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (car (cdr (cdr pair)))))

    (define (cadaar pair)
      "Return the car of the cdr of the car of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (cdr (car (car pair)))))

    (define (cadadr pair)
      "Return the car of the cdr of the car of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (cdr (car (cdr pair)))))

    (define (caddar pair)
      "Return the car of the cdr of the cdr of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (cdr (cdr (car pair)))))

    (define (cadddr pair)
      "Return the car of the cdr of the cdr of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (car (cdr (cdr (cdr pair)))))

    (define (cdaaar pair)
      "Return the cdr of the car of the car of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (car (car (car pair)))))

    (define (cdaadr pair)
      "Return the cdr of the car of the car of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (car (car (cdr pair)))))

    (define (cdadar pair)
      "Return the cdr of the car of the cdr of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (car (cdr (car pair)))))

    (define (cdaddr pair)
      "Return the cdr of the car of the cdr of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (car (cdr (cdr pair)))))

    (define (cddaar pair)
      "Return the cdr of the cdr of the car of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (cdr (car (car pair)))))

    (define (cddadr pair)
      "Return the cdr of the cdr of the car of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (cdr (car (cdr pair)))))

    (define (cdddar pair)
      "Return the cdr of the cdr of the cdr of the car of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (cdr (cdr (car pair)))))

    (define (cddddr pair)
      "Return the cdr of the cdr of the cdr of the cdr of PAIR."
      #((parameters
         (pair (type pair)
          (description "Pair to traverse.")))
        (returns (type any)
         (description "The selected component."))
        (effects pure))
      (cdr (cdr (cdr (cdr pair)))))))
