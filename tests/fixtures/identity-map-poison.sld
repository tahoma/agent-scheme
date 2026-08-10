;;; Test-only poison identity-map backend.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; The canonical owned reader must run while this backend is poisoned. Tests
;;; then disable the poison to exercise the correctness-only plain R7RS alist
;;; fallback used by private legacy syntax.

(define-library (consent identity-map)
  (export consent-identity-map-fast-backend?
          consent-make-identity-map
          consent-identity-map-ref
          consent-identity-map-set!
          consent-test-identity-map-operation-count
          consent-test-identity-map-poison-set!)
  (import (scheme base))
  (begin
    (define poison? #t)
    (define operation-count 0)

    (define (consent-test-identity-map-operation-count)
      "Return the number of host identity-map operations attempted."
      operation-count)

    (define (consent-test-identity-map-poison-set! value)
      "Set whether every host identity-map operation raises an error."
      (set! poison? (if value #t #f)))

    (define (charge! operation)
      "Count OPERATION and reject it while the poison gate is active."
      (set! operation-count (+ operation-count 1))
      (if poison?
          (error "owned reader touched poisoned host identity map" operation)))

    (define (consent-identity-map-fast-backend?)
      "Return #f for this forced plain-R7RS fallback backend."
      #f)

    (define (consent-make-identity-map)
      "Return a mutable identity alist after passing the poison gate."
      (charge! 'make)
      (vector 'consent-identity-map '()))

    (define (consent-identity-map-ref map key default)
      "Return identity KEY's value in MAP, or DEFAULT."
      (charge! 'ref)
      (let loop ((rest (vector-ref map 1)))
        (cond
         ((null? rest) default)
         ((eq? key (caar rest)) (cdar rest))
         (else (loop (cdr rest))))))

    (define (consent-identity-map-set! map key value)
      "Associate identity KEY with VALUE in MAP and return VALUE."
      (charge! 'set!)
      (let loop ((rest (vector-ref map 1)))
        (cond
         ((null? rest)
          (vector-set! map 1 (cons (cons key value) (vector-ref map 1))))
         ((eq? key (caar rest))
          (set-cdr! (car rest) value))
         (else (loop (cdr rest)))))
      value)))
