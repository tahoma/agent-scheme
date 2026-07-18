;;; Portable owned-symbol and symbol-table tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent symbol)
        (data avl-tree)
        (testing registry)
        (testing runner)
        (stdlib testing))

(testing-registry-case
 'owned-symbol-records '(portable runtime symbol)
(let ((symbol (consent-intern-symbol
               (consent-make-symbol-table)
               "portable")))
  (test-assert 'owned-symbol-predicate (consent-symbol? symbol))
  (test-assert 'host-symbol-rejected (not (consent-symbol? 'portable)))
  (test-equal 'immutable-symbol-name "portable" (consent-symbol-name symbol))))

(testing-registry-case
 'repeated-interning '(portable runtime symbol)
(let* ((table (consent-make-symbol-table))
       (first (consent-intern-symbol table "same"))
       (second (consent-intern-symbol table "same")))
  (test-assert 'repeated-interning (eq? first second))
  (test-equal 'single-root-entry
              1
              (avl-tree-size (consent-symbol-table-root table)))))

(testing-registry-case
 'shared-root-branches '(portable runtime symbol)
(let* ((origin (consent-make-symbol-table))
       (inherited (consent-intern-symbol origin "inherited"))
       (root (consent-symbol-table-root origin))
       (left (consent-symbol-table-from-root root))
       (right (consent-symbol-table-from-root root))
       (left-inherited (consent-intern-symbol left "inherited"))
       (right-inherited (consent-intern-symbol right "inherited"))
       (left-only (consent-intern-symbol left "left-only")))
  (test-assert 'root-is-public-avl-tree (avl-tree? root))
  (test-assert 'inherited-record-is-shared
               (and (eq? inherited left-inherited)
                    (eq? inherited right-inherited)))
  (test-assert 'branch-local-insertion
               (and (avl-tree-contains?
                     (consent-symbol-table-root left)
                     "left-only")
                    (not (avl-tree-contains?
                          (consent-symbol-table-root right)
                          "left-only"))))
  (test-assert 'left-only-is-owned (consent-symbol? left-only))))

(testing-registry-case
 'isolated-root-name-equivalence '(portable runtime symbol)
(let* ((left-table (consent-make-symbol-table))
       (right-table (consent-make-symbol-table))
       (left (consent-intern-symbol left-table "transported"))
       (right (consent-intern-symbol right-table "transported")))
  (test-assert 'isolated-records-are-distinct (not (eq? left right)))
  (test-assert 'same-name-equivalence
               (consent-symbol-equivalent? left right))
  (test-assert 'variadic-name-equality
               (consent-symbol=? left right left))))

(testing-registry-case
 'root-installation-is-handle-local '(portable runtime symbol)
(let* ((base (consent-make-symbol-table))
       (root (consent-symbol-table-root base))
       (source (consent-symbol-table-from-root root))
       (sibling (consent-symbol-table-from-root root)))
  (consent-intern-symbol source "installed")
  (consent-symbol-table-root-set!
   base
   (consent-symbol-table-root source))
  (test-assert 'installed-root-visible
               (avl-tree-contains?
                (consent-symbol-table-root base)
                "installed"))
  (test-assert 'sibling-root-unchanged
               (not (avl-tree-contains?
                     (consent-symbol-table-root sibling)
                     "installed")))))

(testing-registry-case
 'process-default-table '(portable runtime symbol)
(let ((first (consent-intern-symbol consent-default-symbol-table
                                    "process-default"))
      (second (consent-intern-symbol consent-default-symbol-table
                                     "process-default")))
  (test-assert 'process-default-table (eq? first second))))

(testing-runner-main "Consent owned symbols" (command-line))
