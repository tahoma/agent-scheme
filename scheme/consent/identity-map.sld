;;; Private portable identity-map adapter.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Gambit uses its native identity table; other configured hosts use SRFI 69
;;; identity hashing. A plain R7RS host without either accelerator retains
;;; reference semantics through an identity association list. The fallback is
;;; compatibility-only: code on an ultra-critical path must bypass this adapter
;;; with owned-object state or require the hash-backed backend rather than infer
;;; a performance guarantee from the shared interface.

(define-library (consent identity-map)
  (export consent-identity-map-fast-backend?
          consent-make-identity-map
          consent-identity-map-ref
          consent-identity-map-set!)
  (import (scheme base))
  (cond-expand
   (gambit
    (import (only (gambit)
                  make-table
                  string->keyword
                  table-ref
                  table-set!))
    (begin
      ;; Under Gambit's R7RS front end `test:' is an identifier rather than a
      ;; keyword literal.  Build the native table option once without routing
      ;; every identity operation through SRFI 69's Scheme hash callback.
      (define consent-identity-table-test-keyword
        (string->keyword "test"))

      (define (consent-identity-map-fast-backend?)
        "Return #t when identity maps use Gambit's native table adapter."
        #t)

      (define (consent-make-identity-map)
        "Return a mutable map keyed by object identity."
        (make-table consent-identity-table-test-keyword eq?))

      (define (consent-identity-map-ref map key default)
        "Return KEY's value in MAP, or DEFAULT when KEY is absent."
        (table-ref map key default))

      (define (consent-identity-map-set! map key value)
        "Associate identity KEY with VALUE in MAP and return VALUE."
        (table-set! map key value)
        value)))
   ((library (srfi 69))
    (import (only (srfi 69)
                  hash-by-identity
                  hash-table-ref/default
                  hash-table-set!
                  make-hash-table))
    (begin
      (define (consent-identity-map-fast-backend?)
        "Return #t when identity maps use the host hash-table adapter."
        #t)

      (define (consent-make-identity-map)
        "Return a mutable map keyed by object identity."
        (make-hash-table eq? hash-by-identity))

      (define (consent-identity-map-ref map key default)
        "Return KEY's value in MAP, or DEFAULT when KEY is absent."
        (hash-table-ref/default map key default))

      (define (consent-identity-map-set! map key value)
        "Associate identity KEY with VALUE in MAP and return VALUE."
        (hash-table-set! map key value)
        value)))
   (else
    (begin
      (define (consent-identity-map-fast-backend?)
        "Return #f for the compatibility-only identity-alist adapter."
        "Compatibility maps reserve slot zero for a tag and slot one for the"
        "identity association list."
        #f)

      (define (consent-make-identity-map)
        "Return a mutable compatibility map keyed by object identity."
        (vector 'consent-identity-map '()))

      (define (consent-identity-map-ref map key default)
        "Return KEY's value in MAP, or DEFAULT when KEY is absent."
        (let loop ((rest (vector-ref map 1)))
          (cond
           ((null? rest) default)
           ((eq? key (car (car rest))) (cdr (car rest)))
           (else (loop (cdr rest))))))

      (define (consent-identity-map-set! map key value)
        "Associate identity KEY with VALUE in MAP and return VALUE."
        (let loop ((rest (vector-ref map 1)))
          (cond
           ((null? rest)
            (vector-set!
             map 1 (cons (cons key value) (vector-ref map 1))))
           ((eq? key (car (car rest)))
            (set-cdr! (car rest) value))
           (else (loop (cdr rest)))))
        value)))))
