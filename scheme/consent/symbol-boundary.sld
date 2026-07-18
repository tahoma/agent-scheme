;;; Private borrowed-host bootstrap-symbol ABI for the portable runtime.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (consent symbol-boundary)
  (export consent-host-symbol?
          consent-host-symbol-name
          consent-host-symbol-eq?
          consent-host-symbol-eqv?
          consent-host-symbol-equal?
          consent-host-symbol-memq
          consent-host-symbol-assq
          consent-host-symbol-member
          consent-host-symbol-assoc)
  (import (rename (scheme base)
                  (eq? host-eq?)
                  (eqv? host-eqv?)
                  (equal? host-equal?)
                  (symbol? host-symbol?)
                  (symbol->string host-symbol->string))
          (consent symbol))
  (begin
    ;; Private evaluator metadata is still represented by host symbols while a
    ;; borrowed Scheme host bootstraps the runtime. This library is the only
    ;; portable boundary that compares those values with owned Consent symbols.
    ;; It is not a symbol-table provider, and a native Consent runtime does not
    ;; need it for calls between Consent-compiled libraries. User primitives do
    ;; not import these adapters and accept owned symbols only.
    (define (consent-host-symbol? value)
      "Return #t for owned symbols or private bootstrap symbols."
      #((parameters
         (value (type any) (description "Value to inspect.")))
        (returns (type boolean)
         (description "Whether VALUE is an owned or host symbol."))
        (effects pure))
      (or (consent-symbol? value) (host-symbol? value)))

    (define (consent-host-symbol-name value)
      "Return the name of an owned or private bootstrap symbol."
      #((parameters
         (value (type (or consent-symbol symbol))
          (description "Boundary value to inspect.")))
        (returns (type string) (description "Symbol name."))
        (effects allocation error))
      (cond
       ((consent-symbol? value) (consent-symbol-name value))
       ((host-symbol? value) (host-symbol->string value))
       (else (error "expected symbol" value))))

    (define (consent-host-symbol-eq? left right)
      "Compare identity with name fallback across the bootstrap boundary."
      #((parameters
         (left (type any) (description "First value to compare."))
         (right (type any) (description "Second value to compare.")))
        (returns (type boolean) (description "Whether values are identical."))
        (effects allocation))
      (or (host-eq? left right)
          (cond
           ((and (consent-symbol? left) (consent-symbol? right))
            (consent-symbol-equivalent? left right))
           ((and (consent-symbol? left) (host-symbol? right))
            (string=? (consent-symbol-name left)
                      (host-symbol->string right)))
           ((and (host-symbol? left) (consent-symbol? right))
            (string=? (host-symbol->string left)
                      (consent-symbol-name right)))
           (else #f))))

    (define (consent-host-symbol-eqv? left right)
      "Compare equivalence, including owned symbol names."
      #((parameters
         (left (type any) (description "First value to compare."))
         (right (type any) (description "Second value to compare.")))
        (returns (type boolean) (description "Whether values are equivalent."))
        (effects allocation))
      (if (or (consent-host-symbol? left)
              (consent-host-symbol? right))
          (and (consent-host-symbol? left)
               (consent-host-symbol? right)
               (consent-host-symbol-eq? left right))
          (host-eqv? left right)))

    (define (consent-host-symbol-equal? left right)
      "Compare compound values while honoring owned symbol equivalence."
      #((parameters
         (left (type any) (description "First value to compare."))
         (right (type any) (description "Second value to compare.")))
        (returns (type boolean) (description "Whether values are equal."))
        (effects allocation))
      (let compare ((left left) (right right) (seen '()))
        (cond
         ((consent-host-symbol-eqv? left right) #t)
         ((and (pair? left) (pair? right))
          (let ((prior
                 (let loop ((rest seen))
                   (and (pair? rest)
                        (or (and (host-eq? left (caar rest))
                                 (host-eq? right (cdar rest)))
                            (loop (cdr rest)))))))
            (or prior
                (let ((seen (cons (cons left right) seen)))
                  (and (compare (car left) (car right) seen)
                       (compare (cdr left) (cdr right) seen))))))
         ((and (vector? left) (vector? right))
          (and (= (vector-length left) (vector-length right))
               (let loop ((index 0))
                 (or (= index (vector-length left))
                     (and (compare (vector-ref left index)
                                   (vector-ref right index)
                                   seen)
                          (loop (+ index 1)))))))
         (else (host-equal? left right)))))

    (define (consent-host-symbol-memq value values)
      "Return VALUES' tail whose head is bootstrap-EQ? to VALUE."
      #((parameters
         (value (type any) (description "Value to locate."))
         (values (type list) (description "List to search.")))
        (returns (type (or list boolean))
         (description "Matching list tail, or #f."))
        (effects allocation))
      (let loop ((rest values))
        (cond
         ((null? rest) #f)
         ((consent-host-symbol-eq? value (car rest)) rest)
         (else (loop (cdr rest))))))

    (define (consent-host-symbol-assq key alist)
      "Return ALIST's entry whose key is bootstrap-EQ? to KEY."
      #((parameters
         (key (type any) (description "Association key to locate."))
         (alist (type list) (description "Association list to search.")))
        (returns (type (or pair boolean))
         (description "Matching association, or #f."))
        (effects allocation))
      (let loop ((rest alist))
        (cond
         ((null? rest) #f)
         ((consent-host-symbol-eq? key (caar rest)) (car rest))
         (else (loop (cdr rest))))))

    (define (consent-host-symbol-member value values . maybe-equal?)
      "Return VALUES' tail whose head equals VALUE."
      #((parameters
         (value (type any) (description "Value to locate."))
         (values (type list) (description "List to search."))
         (maybe-equal? (type list)
          (description "Optional singleton equality predicate list.")))
        (returns (type (or list boolean))
         (description "Matching list tail, or #f."))
        (effects allocation procedure-call))
      (let ((same? (if (null? maybe-equal?)
                       consent-host-symbol-equal?
                       (car maybe-equal?))))
        (let loop ((rest values))
          (cond
           ((null? rest) #f)
           ((same? value (car rest)) rest)
           (else (loop (cdr rest)))))))

    (define (consent-host-symbol-assoc key alist . maybe-equal?)
      "Return ALIST's entry whose key equals KEY."
      #((parameters
         (key (type any) (description "Association key to locate."))
         (alist (type list) (description "Association list to search."))
         (maybe-equal? (type list)
          (description "Optional singleton equality predicate list.")))
        (returns (type (or pair boolean))
         (description "Matching association, or #f."))
        (effects allocation procedure-call))
      (let ((same? (if (null? maybe-equal?)
                       consent-host-symbol-equal?
                       (car maybe-equal?))))
        (let loop ((rest alist))
          (cond
           ((null? rest) #f)
           ((same? key (caar rest)) (car rest))
           (else (loop (cdr rest)))))))))
