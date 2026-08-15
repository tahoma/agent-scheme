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
          (consent identity-map)
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

    ;; Unique result for graphs that require the general cycle-aware path.
    (define symbol-boundary-comparison-unknown
      (vector 'symbol-boundary-comparison-unknown))

    (define (symbol-boundary-atomic-equal? left right)
      "Classify equality of atomic LEFT and RIGHT, or return unknown."
      (cond
       ((consent-host-symbol-eqv? left right) #t)
       ((or (pair? left)
            (pair? right)
            (vector? left)
            (vector? right))
        symbol-boundary-comparison-unknown)
       (else (host-equal? left right))))

    (define (unary-pair-equal? left right)
      "Compare one unary pair graph, or return the general-path marker."
      ;; Bootstrap results are commonly long proper lists. Brent checkpoints
      ;; let those lists and equal-period cycles avoid an identity table while
      ;; preserving constant auxiliary space. Branching and unequal-period
      ;; cycles retain the general congruence-closure path below.
      (let loop ((first left)
                 (second right)
                 (checkpoint-first left)
                 (checkpoint-second right)
                 (power 1)
                 (distance 0))
        (cond
         ((host-eq? first second) #t)
         ((and (pair? first) (pair? second))
          (let* ((first-car (car first))
                 (first-cdr (cdr first))
                 (second-car (car second))
                 (second-cdr (cdr second))
                 (first-car? (pair? first-car))
                 (first-cdr? (pair? first-cdr))
                 (second-car? (pair? second-car))
                 (second-cdr? (pair? second-cdr)))
            (cond
             ((or (not (host-eq? first-car? second-car?))
                  (not (host-eq? first-cdr? second-cdr?)))
              #f)
             ((and first-car? first-cdr?)
              symbol-boundary-comparison-unknown)
             ((not (or first-car? first-cdr?))
              (and
               (consent-host-symbol-equal? first-car second-car)
               (consent-host-symbol-equal? first-cdr second-cdr)))
             (else
              (let ((leaf-equal?
                     (if first-car?
                         (consent-host-symbol-equal?
                          first-cdr second-cdr)
                         (consent-host-symbol-equal?
                          first-car second-car)))
                    (next-first
                     (if first-car? first-car first-cdr))
                    (next-second
                     (if second-car? second-car second-cdr)))
                (cond
                 ((not leaf-equal?) #f)
                 ((and
                   (host-eq? next-first left)
                   (host-eq? next-second right))
                  #t)
                 ((or
                   (host-eq? next-first left)
                   (host-eq? next-second right))
                  symbol-boundary-comparison-unknown)
                 ((and
                   (host-eq? next-first checkpoint-first)
                   (host-eq? next-second checkpoint-second))
                  #t)
                 ((or
                   (host-eq? next-first checkpoint-first)
                   (host-eq? next-second checkpoint-second))
                  symbol-boundary-comparison-unknown)
                 ((= (+ distance 1) power)
                  (loop
                   next-first next-second
                   next-first next-second
                   (* power 2) 0))
                 (else
                  (loop
                   next-first next-second
                   checkpoint-first checkpoint-second
                   power (+ distance 1)))))))))
         ((or (pair? first) (pair? second)) #f)
         (else (symbol-boundary-atomic-equal? first second)))))

    (define (compound-symbol-equal? left right)
      "Compare arbitrary LEFT and RIGHT graphs with owned symbol semantics."
      ;; Union-find records compound congruence classes. Each successful union
      ;; schedules that constructor's edges once, so equal cycles with different
      ;; periods do not produce a product traversal.
      (let ((absent (vector 'symbol-equal-absent))
            (nodes #f)
            (pending (list (cons left right))))
        (define (value-node value)
          "Return VALUE's existing or fresh union-find node."
          (if (not nodes)
              (set! nodes
                    (consent-make-identity-map 'symbol-boundary-equal)))
          (let ((known (consent-identity-map-ref nodes value absent)))
            (if (host-eq? known absent)
                (let ((node (vector #f 0)))
                  (vector-set! node 0 node)
                  (consent-identity-map-set! nodes value node)
                  node)
                known)))
        (define (node-root node)
          "Return NODE's root with iterative path compression."
          (let climb ((cursor node))
            (let ((parent (vector-ref cursor 0)))
              (if (host-eq? cursor parent)
                  (begin
                    (let compress ((path node))
                      (let ((next (vector-ref path 0)))
                        (if (not (host-eq? path cursor))
                            (begin
                              (vector-set! path 0 cursor)
                              (compress next)))))
                    cursor)
                  (climb parent)))))
        (define (seen-or-mark! first second)
          "Report one congruence class, or union two compound classes."
          (let* ((first-root (node-root (value-node first)))
                 (second-root (node-root (value-node second))))
            (if (host-eq? first-root second-root)
                #t
                (let ((first-rank (vector-ref first-root 1))
                      (second-rank (vector-ref second-root 1)))
                  (cond
                   ((< first-rank second-rank)
                    (vector-set! first-root 0 second-root))
                   ((> first-rank second-rank)
                    (vector-set! second-root 0 first-root))
                   (else
                    (vector-set! second-root 0 first-root)
                    (vector-set! first-root 1 (+ first-rank 1))))
                  #f))))
        (define (push! first second)
          (set! pending (cons (cons first second) pending)))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (let loop ()
             (if (null? pending)
                 #t
                 (let* ((comparison (car pending))
                        (first (car comparison))
                        (second (cdr comparison)))
                   (set! pending (cdr pending))
                   (cond
                    ((consent-host-symbol-eqv? first second) (loop))
                    ((and (pair? first) (pair? second))
                     (if (not (seen-or-mark! first second))
                         (begin
                           (push! (cdr first) (cdr second))
                           (push! (car first) (car second))))
                     (loop))
                    ((or (pair? first) (pair? second)) #f)
                    ((and (vector? first) (vector? second))
                     (let ((length (vector-length first)))
                       (if (not (= length (vector-length second)))
                           #f
                           (begin
                             (if (not (seen-or-mark! first second))
                                 (let push-slots ((index (- length 1)))
                                   (if (>= index 0)
                                       (begin
                                         (push!
                                          (vector-ref first index)
                                          (vector-ref second index))
                                         (push-slots (- index 1))))))
                             (loop)))))
                    ((or (vector? first) (vector? second)) #f)
                    ((host-equal? first second) (loop))
                    (else #f))))))
         (lambda ()
           (if nodes (consent-identity-map-release! nodes))))))

    (define (consent-host-symbol-equal? left right)
      "Compare compound values while honoring owned symbol equivalence."
      #((parameters
         (left (type any) (description "First value to compare."))
         (right (type any) (description "Second value to compare.")))
        (returns (type boolean) (description "Whether values are equal."))
        (effects allocation))
      (let ((short-result (unary-pair-equal? left right)))
        (if (host-eq?
             short-result symbol-boundary-comparison-unknown)
            (compound-symbol-equal? left right)
            short-result)))

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
