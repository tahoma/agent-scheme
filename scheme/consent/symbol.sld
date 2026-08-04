;;; Portable owned symbols and persistent symbol-table roots.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (consent symbol)
  (export consent-symbol?
          consent-symbol-name
          consent-symbol-equivalent?
          consent-symbol=?
          consent-symbol-table?
          consent-make-symbol-table
          consent-symbol-table-from-root
          consent-symbol-table-root
          consent-symbol-table-root-set!
          consent-intern-symbol
          consent-default-symbol-table)
  (import (scheme base)
          (data avl-tree)
          (data transient-map))
  (begin
    ;; Owned symbol datum with an immutable private name string.
    (define-record-type <consent-symbol>
      (make-consent-symbol-record name)
      consent-symbol?
      (name raw-consent-symbol-name))

    ;; Mutable handle whose root is a persistent symbol mapping.
    (define-record-type <consent-symbol-table>
      (make-consent-symbol-table-record transient)
      consent-symbol-table?
      (transient consent-symbol-table-transient))

    (define (consent-symbol-name-hash name)
      "Return a bounded portable hash for symbol NAME."
      (let loop ((index 0) (hash 0))
        (if (= index (string-length name))
            hash
            (loop (+ index 1)
                  (modulo (+ (* hash 33)
                             (char->integer (string-ref name index)))
                          536870909)))))

    (define (make-consent-symbol-transient root)
      "Return a string-keyed transient map backed by AVL ROOT."
      (make-transient-map
       root
       consent-symbol-name-hash
       string=?
       avl-tree-ref
       avl-tree-set
       avl-tree-delete
       string-copy))

    (define (consent-symbol-name symbol)
      "Return a fresh string containing owned SYMBOL's immutable name."
      #((parameters
         (symbol (type consent-symbol) (description "Symbol to inspect.")))
        (returns (type string) (description "Symbol name."))
        (effects allocation error))
      (if (not (consent-symbol? symbol))
          (error "consent-symbol-name: expected owned symbol" symbol))
      (string-copy (raw-consent-symbol-name symbol)))

    (define (consent-symbol-equivalent? left right)
      "Return #t when LEFT and RIGHT are owned symbols with equal names."
      #((parameters
         (left (type any) (description "First candidate value."))
         (right (type any) (description "Second candidate value.")))
        (returns (type boolean) (description "Whether names are equal."))
        (effects pure))
      (and (consent-symbol? left)
           (consent-symbol? right)
           (or (eq? left right)
               (string=? (raw-consent-symbol-name left)
                         (raw-consent-symbol-name right)))))

    (define (consent-symbol=? first second . rest)
      "Return #t when every supplied owned symbol has the same name."
      #((parameters
         (first (type consent-symbol) (description "First symbol."))
         (second (type consent-symbol) (description "Second symbol."))
         (rest (type list) (description "Additional symbols.")))
        (returns (type boolean) (description "Whether names are equal."))
        (effects error))
      (if (not (consent-symbol? first))
          (error "consent-symbol=?: expected owned symbol" first))
      (let loop ((previous first) (symbols (cons second rest)))
        (cond
         ((null? symbols) #t)
         ((not (consent-symbol? (car symbols)))
          (error "consent-symbol=?: expected owned symbol" (car symbols)))
         ((consent-symbol-equivalent? previous (car symbols))
          (loop (car symbols) (cdr symbols)))
         (else #f))))

    (define (consent-make-symbol-table)
      "Return an empty owned-symbol table handle."
      #((parameters)
        (returns (type consent-symbol-table)
         (description "Empty table handle."))
        (effects allocation))
      (make-consent-symbol-table-record
       (make-consent-symbol-transient (make-avl-tree string<?))))

    (define (consent-symbol-table-from-root root)
      "Return a symbol-table handle initially pointing to persistent ROOT."
      #((parameters
         (root (type avl-tree) (description "Persistent symbol root.")))
        (returns (type consent-symbol-table)
         (description "Table handle sharing ROOT."))
        (effects allocation error))
      (if (not (avl-tree? root))
          (error "consent-symbol-table-from-root: expected AVL tree" root))
      (make-consent-symbol-table-record (make-consent-symbol-transient root)))

    (define (consent-symbol-table-root table)
      "Return TABLE's current persistent AVL root."
      #((parameters
         (table (type consent-symbol-table) (description "Table handle.")))
        (returns (type avl-tree) (description "Current persistent root."))
        (effects allocation state-write procedure-call error))
      (if (not (consent-symbol-table? table))
          (error "consent-symbol-table-root: expected table" table))
      (transient-map-persistent! (consent-symbol-table-transient table)))

    (define (consent-symbol-table-root-set! table root)
      "Install persistent ROOT in TABLE and return TABLE."
      #((parameters
         (table (type consent-symbol-table) (description "Table handle."))
         (root (type avl-tree) (description "Persistent root to install.")))
        (returns (type consent-symbol-table)
         (description "Updated TABLE handle."))
        (effects state-write error))
      (if (not (consent-symbol-table? table))
          (error "consent-symbol-table-root-set!: expected table" table))
      (if (not (avl-tree? root))
          (error "consent-symbol-table-root-set!: expected AVL tree" root))
      (transient-map-reset! (consent-symbol-table-transient table) root)
      table)

    (define (consent-intern-symbol table name)
      "Return TABLE's owned symbol for NAME, inserting it when absent."
      #((parameters
         (table (type consent-symbol-table) (description "Table handle."))
         (name (type string) (description "Symbol name.")))
        (returns (type consent-symbol) (description "Interned symbol."))
        (effects allocation state-write error procedure-call))
      (if (not (consent-symbol-table? table))
          (error "consent-intern-symbol: expected table" table))
      (if (not (string? name))
          (error "consent-intern-symbol: expected string" name))
      (let ((transient (consent-symbol-table-transient table)))
        (transient-map-ref
         transient
         name
         (lambda ()
           (let* ((owned-name (string-copy name))
                  (symbol (make-consent-symbol-record owned-name)))
             (transient-map-set! transient owned-name symbol)
             symbol)))))

    ;; Process-default table used when callers do not supply explicit
    ;; ownership.
    (define consent-default-symbol-table
      (consent-make-symbol-table))))
