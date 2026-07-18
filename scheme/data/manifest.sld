;;; Portable data library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This load-light manifest records public, portable data structures that do
;;; not have a standard Scheme or SRFI library name.

(define-library (data manifest)
  (export data-library-manifest
          data-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe reusable portable data libraries.
    (define data-library-manifest
      '((manifest-entry
         (schema-version 1)
         (kind library)
         (name (data manifest))
         (owner data)
         (provider repo-source)
         (visibility public)
         (layer manifest)
         (source-kind source-library)
         (source (path "manifest.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (data-library-manifest
           data-library-manifest-ref))
         (dependencies
          ((library (scheme base))))
         (provenance ((origin repo)))
         (status implemented)
         (canonical #t))
        (manifest-entry
         (schema-version 1)
         (kind library)
         (name (data transient-map))
         (owner data)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "transient-map.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (make-transient-map
           transient-map?
           transient-map-contains?
           transient-map-ref
           transient-map-ref/default
           transient-map-set!
           transient-map-delete!
           transient-map-pending-count
           transient-map-persistent!
           transient-map-reset!))
         (dependencies
          ((library (scheme base))))
         (provenance
          ((origin repo)
           (storage mutable-open-addressed-overlay)
           (base persistent-map-adapter)
           (local-reference-documents
            ((path "reference/transient-map.md")
             (role specification)
             (source consent)))))
         (verification
          ((test-status
            (lookup staging deletion materialization reset collision-resize
                    portable-host-suite compiled-host-suite))))
         (status implemented)
         (canonical #t))
        (manifest-entry
         (schema-version 1)
         (kind library)
         (name (data mapping avl))
         (owner data)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "mapping/avl.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (avl-mapping
           avl-mapping-unfold
           alist->avl-mapping))
         (dependencies
          ((library (scheme base))
           (library (stdlib comparator))
           (library (stdlib mapping implementation))
           (library (data avl-tree))))
         (provenance
          ((origin repo)
           (mapping-interface srfi-146)
           (storage (data avl-tree))
           (local-reference-documents
            ((path "reference/avl-tree.md")
             (role specification)
             (source consent)))))
         (verification
          ((test-status
            (constructor-provider-preservation mixed-provider-operations
                                               portable-host-suite
                                               compiled-host-smoke))))
         (status implemented)
         (canonical #t))
        (manifest-entry
         (schema-version 1)
         (kind library)
         (name (data avl-tree))
         (owner data)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "avl-tree.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (make-avl-tree
           avl-tree?
           avl-tree-valid?
           avl-tree-ordering
           avl-tree-empty?
           avl-tree-size
           avl-tree-contains?
           avl-tree-ref
           avl-tree-ref/key
           avl-tree-ref/default
           avl-tree-adjoin
           avl-tree-set
           avl-tree-replace
           avl-tree-delete
           avl-tree-for-each
           avl-tree-fold
           avl-tree-fold/reverse
           avl-tree-min
           avl-tree-max
           avl-tree-key-predecessor
           avl-tree-key-successor
           avl-tree-split
           avl-tree-catenate
           avl-tree-map/monotone
           avl-tree->alist
           alist->avl-tree))
         (dependencies
          ((library (scheme base))))
         (provenance
          ((origin repo)
           (local-reference-documents
            ((path "reference/avl-tree.md")
             (role specification)
             (source consent)))))
         (verification
          ((test-status
            (import-resolution lookup stored-key-lookup insertion rotations
                               persistence invariant-checks portable-host-suite
                               compiled-host-smoke))))
         (status implemented)
         (canonical #t))))

    (define (data-library-manifest-ref name)
      "Return the canonical data-library entry for NAME, or #f."
      #((parameters
         (name (type list)
          (description "Library name to look up.")))
        (returns (type (or list boolean))
         (description "Matching manifest entry, or #f."))
        (effects pure))
      (let loop ((entries data-library-manifest))
        (cond
         ((null? entries) #f)
         ((equal? name (cadr (assq 'name (cdr (car entries)))))
          (car entries))
         (else (loop (cdr entries))))))))
