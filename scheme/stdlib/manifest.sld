;;; Portable stdlib support manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library records optional stdlib support as Scheme-readable data.
;;; It is source-loaded by each bootstrap so vendored, shimmed, or owned
;;; SRFI/R7RS-large implementations stay visible to tools without querying host
;;; state.

(define-library (stdlib manifest)
  (export stdlib-manifest stdlib-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe optional libraries owned or surfaced locally.
    (define stdlib-manifest
      '(((library . (stdlib manifest))
         (visibility . public)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "manifest.sld")
         (implementation-library . (stdlib manifest))
         (exports . (stdlib-manifest stdlib-manifest-ref))
         (dependencies . ((scheme base))))
        ((library . (srfi manifest))
         (visibility . alias)
         (status . alias)
         (target . (stdlib manifest))
         (import-aliases . ((srfi manifest)))
         (dependencies . ((stdlib manifest)))
         (test-status . (import-resolution)))
        ((library . (stdlib json))
         (visibility . public)
         (status . direct-portable-implementation)
         (source-kind . source-library)
         (source-file . "json.sld")
         (upstream-source-url . "https://github.com/scheme-requests-for-implementation/srfi-180")
         (upstream-revision . "671857bac55c53e3190a24ec53b457321a1d8f12")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (local-patches . ())
         (implementation-library . (stdlib json))
         (exports . (json-number-of-character-limit json-nesting-depth-limit
                     json-null? json-error? json-error-reason json-fold
                     json-generator json-read json-lines-read
                     json-sequence-read json-accumulator json-write))
         (import-aliases . ((stdlib json) (consent json)
                            (srfi 180) (srfi srfi-180)))
         (dependencies . ((stdlib and-let-star)))
        (test-status . (import-resolution representative-read-write
                         emacs-json-oracle portable-host-suite
                         imported-reference-corpus json-lines
                         json-text-sequences)))
        ((library . (stdlib json read))
         (visibility . alias)
         (status . alias)
         (target . (stdlib json))
         (exports . (json-number-of-character-limit
                     json-nesting-depth-limit
                     json-null?
                     json-error?
                     json-error-reason
                     json-fold
                     json-generator
                     json-read
                     json-lines-read
                     json-sequence-read))
         (import-aliases . ((stdlib json read)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (consent json read))
         (visibility . alias)
         (status . alias)
         (target . (stdlib json))
         (exports . (json-number-of-character-limit
                     json-nesting-depth-limit
                     json-null?
                     json-error?
                     json-error-reason
                     json-fold
                     json-generator
                     json-read
                     json-lines-read
                     json-sequence-read))
         (import-aliases . ((consent json read)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (consent json))
         (visibility . alias)
         (status . alias)
         (target . (stdlib json))
         (import-aliases . ((consent json)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-180))
         (visibility . alias)
         (status . alias)
         (target . (stdlib json))
         (import-aliases . ((srfi srfi-180)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (srfi 180))
         (visibility . alias)
         (status . alias)
         (target . (stdlib json))
         (import-aliases . ((srfi 180)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (srfi 16))
         (visibility . alias)
         (status . built-in-shim)
         (source . built-in-shim)
         (upstream-source-url . "https://srfi.schemers.org/srfi-16/")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (target . (scheme case-lambda))
         (implementation-library . (scheme case-lambda))
         (exports . (case-lambda))
         (import-aliases . ((srfi 16) (srfi srfi-16)))
         (dependencies . ((scheme case-lambda)))
         (test-status . (import-resolution representative-case-lambda-behavior
                         missing-export-diagnostic portable-host-suite)))
        ((library . (srfi srfi-16))
         (visibility . alias)
         (status . alias)
         (target . (scheme case-lambda))
         (import-aliases . ((srfi srfi-16)))
         (dependencies . ((scheme case-lambda)))
         (test-status . (import-resolution)))
        ((library . (stdlib and-let-star))
         (visibility . public)
         (status . vendored-adapted-implementation)
         (source-kind . source-library)
         (source-file . "and-let-star.sld")
         (upstream-source-url . "https://okmij.org/ftp/Scheme/lib/myenv-chez.scm")
         (source-test-url . "https://okmij.org/ftp/Scheme/tests/vland.scm")
         (upstream-revision . "myenv-chez.scm,v 1.7 2006/01/19 02:14:07")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((define-library-wrapper
                            (library . (stdlib and-let-star)))
                           (registry-aliases
                            (aliases (srfi 2) (srfi srfi-2)))
                           (adapted-tests
                            (file . "tests/scheme/stdlib-and-let-star-test.scm"))))
         (implementation-library . (stdlib and-let-star))
         (exports . (and-let*))
         (import-aliases . ((stdlib and-let-star) (srfi 2) (srfi srfi-2)))
         (dependencies . ((scheme base)))
         (test-status . (import-resolution representative-and-let-star-behavior
                         missing-export-diagnostic adapted-upstream-tests
                         portable-host-suite)))
        ((library . (srfi 2))
         (visibility . alias)
         (status . alias)
         (target . (stdlib and-let-star))
         (import-aliases . ((srfi 2)))
         (dependencies . ((stdlib and-let-star)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-2))
         (visibility . alias)
         (status . alias)
         (target . (stdlib and-let-star))
         (import-aliases . ((srfi srfi-2)))
         (dependencies . ((stdlib and-let-star)))
         (test-status . (import-resolution)))
        ((library . (stdlib list))
         (visibility . public)
         (status . vendored-adapted-implementation)
         (source-kind . source-library)
         (source-file . "list.sld")
         (upstream-source-url . "https://github.com/scheme-requests-for-implementation/srfi-1")
         (upstream-source-file . "srfi-1-reference.scm")
         (upstream-revision . "d502ec3832de709f00f7ae5488a334a25da8a9f9")
         (upstream-source-blob . "56a7175d0feeddb07609937f8c59bac8eadab0d8")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((define-library-wrapper
                            (library . (stdlib list)))
                           (registry-aliases
                            (aliases (scheme list) (srfi 1) (srfi srfi-1)))
                           (portable-optional-argument-helpers
                            (source local))
                           (adapted-tests
                            (file . "tests/scheme/stdlib-list-test.scm"))))
         (implementation-library . (stdlib list))
         (exports . (xcons tree-copy list-tabulate cons* proper-list?
                     circular-list? dotted-list? not-pair? null-list? list=
                     circular-list length+ iota first second third fourth
                     fifth sixth seventh eighth ninth tenth car+cdr take
                     drop take-right drop-right take! drop-right! split-at
                     split-at! last last-pair append! concatenate
                     concatenate! reverse! append-reverse append-reverse!
                     zip unzip1 unzip2 unzip3 unzip4 unzip5 count fold
                     fold-right pair-fold pair-fold-right reduce
                     reduce-right unfold unfold-right append-map append-map!
                     map! pair-for-each filter-map map-in-order filter
                     partition remove filter! partition! remove! find
                     find-tail take-while drop-while take-while! span break
                     span! break! any every list-index delete delete!
                     delete-duplicates delete-duplicates! alist-cons
                     alist-copy alist-delete alist-delete! lset<= lset=
                     lset-adjoin lset-union lset-intersection
                     lset-difference lset-xor lset-diff+intersection
                     lset-union! lset-intersection! lset-difference!
                     lset-xor! lset-diff+intersection!))
         (import-aliases . ((stdlib list) (scheme list)
                            (srfi 1) (srfi srfi-1)))
         (dependencies . ((scheme base) (scheme cxr)))
         (test-status . (import-resolution representative-list-behavior
                         alias-import missing-export-diagnostic
                         portable-host-suite)))
        ((library . (scheme list))
         (visibility . alias)
         (status . alias)
         (target . (stdlib list))
         (import-aliases . ((scheme list)))
         (dependencies . ((stdlib list)))
         (test-status . (import-resolution)))
        ((library . (srfi 1))
         (visibility . alias)
         (status . alias)
         (target . (stdlib list))
         (import-aliases . ((srfi 1)))
         (dependencies . ((stdlib list)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-1))
         (visibility . alias)
         (status . alias)
         (target . (stdlib list))
         (import-aliases . ((srfi srfi-1)))
         (dependencies . ((stdlib list)))
         (test-status . (import-resolution)))
        ((library . (stdlib generator))
         (visibility . public)
         (status . vendored-adapted-implementation)
         (source-kind . source-library)
         (source-file . "generator.sld")
         (upstream-source-url . "https://github.com/scheme-requests-for-implementation/srfi-158")
         (upstream-source-file . "srfi-158-impl.scm")
         (upstream-revision . "ffd5bac4caf70167d0b57f701a6c43aa07701158")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((define-library-wrapper
                            (library . (stdlib generator)))
                           (registry-aliases
                            (aliases (scheme generator)
                                     (srfi 158)
                                     (srfi srfi-158)))
                           (portable-optional-helpers
                            (source local))
                           (accumulator-finalization-guards
                            (source local))
                           (adapted-tests
                            (file . "tests/scheme/stdlib-generator-test.scm"))))
         (implementation-library . (stdlib generator))
         (exports . (generator circular-generator make-iota-generator
                     make-range-generator make-coroutine-generator
                     list->generator vector->generator
                     reverse-vector->generator string->generator
                     bytevector->generator make-for-each-generator
                     make-unfold-generator gcons* gappend gcombine gfilter
                     gremove gtake gdrop gtake-while gdrop-while gflatten
                     ggroup gmerge gmap gstate-filter gdelete
                     gdelete-neighbor-dups gindex gselect generator->list
                     generator->reverse-list generator->vector
                     generator->vector! generator->string generator-fold
                     generator-map->list generator-for-each generator-find
                     generator-count generator-any generator-every
                     generator-unfold make-accumulator count-accumulator
                     list-accumulator reverse-list-accumulator
                     vector-accumulator reverse-vector-accumulator
                     vector-accumulator! string-accumulator
                     bytevector-accumulator bytevector-accumulator!
                     sum-accumulator product-accumulator))
         (import-aliases . ((stdlib generator) (scheme generator)
                            (srfi 158) (srfi srfi-158)))
         (dependencies . ((scheme base) (scheme case-lambda)))
         (test-status . (import-resolution representative-generator-behavior
                         alias-import missing-export-diagnostic
                         adapted-upstream-tests portable-host-suite)))
        ((library . (scheme generator))
         (visibility . alias)
         (status . alias)
         (target . (stdlib generator))
         (import-aliases . ((scheme generator)))
         (dependencies . ((stdlib generator)))
         (test-status . (import-resolution)))
        ((library . (srfi 158))
         (visibility . alias)
         (status . alias)
         (target . (stdlib generator))
         (import-aliases . ((srfi 158)))
         (dependencies . ((stdlib generator)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-158))
         (visibility . alias)
         (status . alias)
         (target . (stdlib generator))
         (import-aliases . ((srfi srfi-158)))
         (dependencies . ((stdlib generator)))
         (test-status . (import-resolution)))
        ((library . (stdlib receive))
         (visibility . public)
         (status . built-in-shim)
         (source-kind . source-library)
         (source-file . "receive.sld")
         (source . built-in-shim)
         (upstream-source-url . "https://srfi.schemers.org/srfi-8/")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (local-patches . ((define-library-wrapper
                            (library . (stdlib receive)))
                           (registry-aliases
                            (aliases (srfi 8) (srfi srfi-8)))
                           (local-tests
                            (file . "tests/scheme/stdlib-receive-test.scm"))))
         (implementation-library . (stdlib receive))
         (exports . (receive))
         (import-aliases . ((stdlib receive) (srfi 8) (srfi srfi-8)))
         (dependencies . ((scheme base)))
         (test-status . (import-resolution representative-receive-behavior
                         missing-export-diagnostic portable-host-suite)))
        ((library . (srfi 8))
         (visibility . alias)
         (status . alias)
         (target . (stdlib receive))
         (import-aliases . ((srfi 8)))
         (dependencies . ((stdlib receive)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-8))
         (visibility . alias)
         (status . alias)
         (target . (stdlib receive))
         (import-aliases . ((srfi srfi-8)))
         (dependencies . ((stdlib receive)))
         (test-status . (import-resolution)))
        ((library . (stdlib assume))
         (visibility . public)
         (status . built-in-shim)
         (source-kind . source-library)
         (source-file . "assume.sld")
         (source . built-in-shim)
         (upstream-source-url . "https://srfi.schemers.org/srfi-145/")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (local-patches . ((define-library-wrapper
                            (library . (stdlib assume)))
                           (registry-aliases
                            (aliases (srfi 145) (srfi srfi-145)))
                           (local-tests
                            (file . "tests/scheme/stdlib-assume-test.scm"))))
         (implementation-library . (stdlib assume))
         (exports . (assume))
         (import-aliases . ((stdlib assume) (srfi 145) (srfi srfi-145)))
         (dependencies . ((scheme base)))
         (test-status . (import-resolution representative-assume-behavior
                         missing-export-diagnostic portable-host-suite)))
        ((library . (srfi 145))
         (visibility . alias)
         (status . alias)
         (target . (stdlib assume))
         (import-aliases . ((srfi 145)))
         (dependencies . ((stdlib assume)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-145))
         (visibility . alias)
         (status . alias)
         (target . (stdlib assume))
         (import-aliases . ((srfi srfi-145)))
         (dependencies . ((stdlib assume)))
         (test-status . (import-resolution)))
        ((library . (stdlib comparator))
         (visibility . public)
         (status . vendored-adapted-implementation)
         (source-kind . source-library)
         (source-file . "comparator.sld")
         (upstream-source-url . "https://github.com/scheme-requests-for-implementation/srfi-128")
         (upstream-revision . "3ec333638e787d75a16de83fcf9645c998e4d976")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((library-name
                            (from . (srfi 128))
                            (to . (stdlib comparator)))
                           (inlined-includes
                            (files "srfi/128.body1.scm" "srfi/128.body2.scm"))
                           (documentation-metadata
                            (scope exported-procedures))
                           (default-hash
                            (source local-portable-implementation))
                           (stateful-hasher
                            (source upstream-style-case-lambda))
                           (hash-helpers
                            (source local-portable-procedures))))
         (implementation-library . (stdlib comparator))
         (exports . (comparator? comparator-ordered? comparator-hashable?
                     make-comparator make-pair-comparator
                     make-list-comparator make-vector-comparator
                     make-eq-comparator make-eqv-comparator
                     make-equal-comparator boolean-hash char-hash
                     char-ci-hash string-hash string-ci-hash symbol-hash
                     number-hash make-default-comparator default-hash
                     comparator-register-default!
                     comparator-type-test-predicate
                     comparator-equality-predicate
                     comparator-ordering-predicate comparator-hash-function
                     comparator-test-type comparator-check-type
                     comparator-hash hash-bound hash-salt =? <? >? <=? >=?
                     comparator-if<=>))
         (import-aliases . ((stdlib comparator) (scheme comparator)
                            (srfi 128) (srfi srfi-128)))
         (dependencies . ((scheme base) (scheme case-lambda) (scheme char)
                          (scheme inexact) (scheme complex)))
         (test-status . (import-resolution representative-comparator-behavior
                         alias-import missing-export-diagnostic
                         portable-host-suite)))
        ((library . (stdlib rbtree))
         (visibility . public)
         (status . vendored-adapted-implementation)
         (source-kind . source-library)
         (source-file . "rbtree.sld")
         (upstream-source-url . "https://github.com/scheme-requests-for-implementation/srfi-146")
         (upstream-source-path . "nieper")
         (upstream-source-files . ("nieper/rbtree.sld" "nieper/rbtree.scm"))
         (upstream-revision . "28bd72ed4d8445d8a91f84d919630d0f3a7564fb")
         (upstream-source-blobs
          . (("nieper/rbtree.sld" . "d74e8e469e990dcad0d6a02d8c9cc63943aa3cba")
             ("nieper/rbtree.scm" . "03b901e37b5c82333860301ac0bbf6ef96646f26")))
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((library-name
                            (from . (nieper rbtree))
                            (to . (stdlib rbtree)))
                           (inlined-include
                            (file . "nieper/rbtree.scm"))
                           (adapted-imports
                            (from (srfi 2) (srfi 8) (srfi 158) (srfi 128))
                            (to (stdlib and-let-star)
                                (stdlib receive)
                                (stdlib generator)
                                (stdlib comparator)))
                           (matcher-hygiene
                            (source local-portability-patch)
                            (scope nested-tree-patterns black-height))
                           (documentation-metadata
                            (scope exported-procedures))
                           (removed-unused-accessors
                            (names key value))
                           (internal-stdlib-helper
                            (aliases . ()))
                           (adapted-tests
                            (file . "tests/scheme/stdlib-rbtree-test.scm"))))
         (implementation-library . (stdlib rbtree))
         (exports . (make-tree tree-search tree-for-each tree-fold
                     tree-fold/reverse tree-generator tree-key-predecessor
                     tree-key-successor tree-map tree-catenate tree-split))
         (import-aliases . ((stdlib rbtree)))
         (dependencies . ((scheme base) (scheme case-lambda)
                          (stdlib and-let-star) (stdlib receive)
                          (stdlib generator) (stdlib comparator)))
         (test-status . (import-resolution representative-tree-behavior
                         mutation-sequences missing-export-diagnostic
                         helper-smoke portable-host-suite)))
        ((library . (stdlib mapping))
         (visibility . public)
         (status . vendored-adapted-implementation)
         (source-kind . source-library)
         (source-file . "mapping.sld")
         (upstream-source-url . "https://github.com/scheme-requests-for-implementation/srfi-146")
         (upstream-source-files . ("srfi/146.sld" "srfi/146.scm"))
         (upstream-source-test-file . "srfi/146/test.sld")
         (upstream-revision . "28bd72ed4d8445d8a91f84d919630d0f3a7564fb")
         (upstream-source-blobs
          . (("srfi/146.sld" . "dbeb605b19232b8fbccb6fb8c94bd5ec1538a85e")
             ("srfi/146.scm" . "3e37da6667e55e14b7d7e93db8353530072819c9")
             ("srfi/146/test.sld" . "e1804c30ee1e3c5a1cfbf0fa60ed382f2326dfdf")))
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((library-name
                            (from . (srfi 146))
                            (to . (stdlib mapping)))
                           (inlined-include
                            (file . "srfi/146.scm"))
                           (adapted-imports
                            (from (srfi 1) (srfi 8) (srfi 128)
                                  (srfi 145) (nieper rbtree))
                            (to (stdlib list)
                                (stdlib receive)
                                (stdlib comparator)
                                (stdlib assume)
                                (stdlib rbtree)))
                           (registry-aliases
                            (aliases (scheme mapping)
                                     (srfi 146)
                                     (srfi srfi-146)))
                           (documentation-metadata
                            (scope exported-procedures))
                           (linear-update
                            (strategy pure-functional))
                           (hash-variant-out-of-scope
                            (issue . 624))
                           (local-tests
                            (file . "tests/scheme/stdlib-mapping-test.scm"))
                           (adapted-tests
                            (file . "tests/scheme/stdlib-mapping-conformance-test.scm"))))
         (implementation-library . (stdlib mapping))
         (exports . (mapping mapping-unfold mapping/ordered
                     mapping-unfold/ordered mapping? mapping-contains?
                     mapping-empty? mapping-disjoint? mapping-ref
                     mapping-ref/default mapping-key-comparator
                     mapping-adjoin mapping-adjoin! mapping-set mapping-set!
                     mapping-replace mapping-replace! mapping-delete
                     mapping-delete! mapping-delete-all mapping-delete-all!
                     mapping-intern mapping-intern! mapping-update
                     mapping-update! mapping-update/default
                     mapping-update!/default mapping-pop mapping-pop!
                     mapping-search mapping-search! mapping-size
                     mapping-find mapping-count mapping-any? mapping-every?
                     mapping-keys mapping-values mapping-entries mapping-map
                     mapping-map->list mapping-for-each mapping-fold
                     mapping-filter mapping-filter! mapping-remove
                     mapping-remove! mapping-partition mapping-partition!
                     mapping-copy mapping->alist alist->mapping
                     alist->mapping! alist->mapping/ordered
                     alist->mapping/ordered! mapping=? mapping<? mapping>?
                     mapping<=? mapping>=? mapping-union
                     mapping-intersection mapping-difference mapping-xor
                     mapping-union! mapping-intersection!
                     mapping-difference! mapping-xor!
                     make-mapping-comparator mapping-comparator
                     mapping-min-key mapping-max-key mapping-min-value
                     mapping-max-value mapping-key-predecessor
                     mapping-key-successor mapping-range= mapping-range<
                     mapping-range> mapping-range<= mapping-range>=
                     mapping-range=! mapping-range<! mapping-range>!
                     mapping-range<=! mapping-range>=! mapping-split
                     mapping-catenate mapping-catenate! mapping-map/monotone
                     mapping-map/monotone! mapping-fold/reverse comparator?))
         (import-aliases . ((stdlib mapping) (scheme mapping)
                            (srfi 146) (srfi srfi-146)))
         (dependencies . ((scheme base) (scheme case-lambda)
                          (stdlib list) (stdlib receive)
                          (stdlib comparator) (stdlib assume)
                          (stdlib rbtree)))
         (test-status . (import-resolution representative-mapping-behavior
                         alias-import missing-export-diagnostic
                         hash-alias-diagnostic model-oracle
                         adapted-upstream-tests direct-host-conformance
                         compiled-host-smoke portable-host-suite)))
        ((library . (scheme mapping))
         (visibility . alias)
         (status . alias)
         (target . (stdlib mapping))
         (import-aliases . ((scheme mapping)))
         (dependencies . ((stdlib mapping)))
         (test-status . (import-resolution)))
        ((library . (srfi 146))
         (visibility . alias)
         (status . alias)
         (target . (stdlib mapping))
         (import-aliases . ((srfi 146)))
         (dependencies . ((stdlib mapping)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-146))
         (visibility . alias)
         (status . alias)
         (target . (stdlib mapping))
         (import-aliases . ((srfi srfi-146)))
         (dependencies . ((stdlib mapping)))
         (test-status . (import-resolution)))
        ((library . (scheme comparator))
         (visibility . alias)
         (status . alias)
         (target . (stdlib comparator))
         (import-aliases . ((scheme comparator)))
         (dependencies . ((stdlib comparator)))
         (test-status . (import-resolution)))
        ((library . (srfi 128))
         (visibility . alias)
         (status . alias)
         (target . (stdlib comparator))
         (import-aliases . ((srfi 128)))
         (dependencies . ((stdlib comparator)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-128))
         (visibility . alias)
         (status . alias)
         (target . (stdlib comparator))
         (import-aliases . ((srfi srfi-128)))
         (dependencies . ((stdlib comparator)))
         (test-status . (import-resolution)))))

    (define (stdlib-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "Stdlib library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest stdlib-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
