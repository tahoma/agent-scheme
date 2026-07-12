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
      '((manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib manifest))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "manifest.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (stdlib-manifest
          stdlib-manifest-ref))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib json))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "json.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "671857bac55c53e3190a24ec53b457321a1d8f12"))
        (realization portable-source)
        (aliases ((consent json) (srfi 180) (srfi srfi-180)))
        (exports
         (json-number-of-character-limit
          json-nesting-depth-limit
          json-null?
          json-error?
          json-error-reason
          json-fold
          json-generator
          json-read
          json-lines-read
          json-sequence-read
          json-accumulator
          json-write))
        (dependencies
         ((library (stdlib and-let-star))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-180")
          (local-reference-documents
           ((path "reference/srfi-180/srfi-180.html")
            (role specification)
            (source srfi)))
          (upstream-revision "671857bac55c53e3190a24ec53b457321a1d8f12")
          (upstream-license "MIT") (local-license "Apache-2.0") (vendored? #f)
          (local-patches ())))
        (verification
         ((test-status
           (import-resolution representative-read-write emacs-json-oracle
                              portable-host-suite imported-reference-corpus
                              json-lines json-text-sequences))))
        (status direct-portable-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (stdlib json read))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib json)))
        (source-version unknown)
        (realization alias)
        (target (stdlib json))
        (exports
         (json-number-of-character-limit
          json-nesting-depth-limit
          json-null?
          json-error?
          json-error-reason
          json-fold
          json-generator
          json-read
          json-lines-read
          json-sequence-read))
        (dependencies
         ((library (stdlib json))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (consent json read))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib json)))
        (source-version unknown)
        (realization alias)
        (target (stdlib json))
        (exports
         (json-number-of-character-limit
          json-nesting-depth-limit
          json-null?
          json-error?
          json-error-reason
          json-fold
          json-generator
          json-read
          json-lines-read
          json-sequence-read))
        (dependencies
         ((library (stdlib json))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (consent json))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib json)))
        (source-version unknown)
        (realization alias)
        (target (stdlib json))
        (dependencies
         ((library (stdlib json))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-180))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib json)))
        (source-version unknown)
        (realization alias)
        (target (stdlib json))
        (dependencies
         ((library (stdlib json))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 180))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib json)))
        (source-version unknown)
        (realization alias)
        (target (stdlib json))
        (dependencies
         ((library (stdlib json))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 0))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (source built-in-shim)
        (api-version (inherits (scheme base)))
        (source-version final)
        (realization shim)
        (target (scheme base))
        (aliases ((srfi srfi-0)))
        (exports
         (cond-expand))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-0/")
          (local-reference-documents
           ((path "reference/srfi-0/srfi-0.html")
            (role specification)
            (source srfi)))
          (upstream-license "MIT") (local-license "Apache-2.0")
          (vendored? #f)))
        (verification
         ((test-status
           (import-resolution representative-cond-expand-behavior
                              missing-export-diagnostic portable-host-suite))))
        (status built-in-shim)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-0))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (scheme base)))
        (source-version final)
        (realization alias)
        (target (scheme base))
        (exports
         (cond-expand))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 16))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (source built-in-shim)
        (api-version (inherits (scheme case-lambda)))
        (source-version unknown)
        (realization shim)
        (target (scheme case-lambda))
        (aliases ((srfi srfi-16) (srfi :16) (srfi :16 case-lambda)))
        (exports
         (case-lambda))
        (dependencies
         ((library (scheme case-lambda))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-16/")
          (upstream-license "MIT")
          (local-reference-documents
           ((path "reference/srfi-16/srfi-16.html")
            (role specification)
            (source srfi)))
          (local-license "Apache-2.0") (vendored? #f)))
        (verification
         ((test-status
           (import-resolution representative-case-lambda-behavior
                              missing-export-diagnostic portable-host-suite))))
        (status built-in-shim)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-16))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (scheme case-lambda)))
        (source-version unknown)
        (realization alias)
        (target (scheme case-lambda))
        (dependencies
         ((library (scheme case-lambda))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :16))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (scheme case-lambda)))
        (source-version unknown)
        (realization alias)
        (target (scheme case-lambda))
        (dependencies
         ((library (scheme case-lambda))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :16 case-lambda))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (scheme case-lambda)))
        (source-version unknown)
        (realization alias)
        (target (scheme case-lambda))
        (dependencies
         ((library (scheme case-lambda))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib srfi-reference))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "srfi-reference.sld"))
        (api-version (compat 0))
        (source-version final)
        (realization shim)
        (aliases ((srfi 261) (srfi srfi-261)))
        (exports ())
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-261/")
          (local-reference-documents
           ((path "reference/srfi-261/srfi-261.html")
            (role specification)
            (source srfi)))
          (upstream-license "MIT") (local-license "Apache-2.0")
          (vendored? #f) (local-patches ())))
        (verification
         ((test-status
           (import-resolution reference-aliases no-export-shim
                              portable-host-suite))))
        (status built-in-shim)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 261))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (source built-in-shim)
        (api-version (inherits (stdlib srfi-reference)))
        (source-version final)
        (realization shim)
        (target (stdlib srfi-reference))
        (aliases ((srfi srfi-261)))
        (dependencies
         ((library (stdlib srfi-reference))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-261/")
          (upstream-license "MIT") (local-license "Apache-2.0")
          (vendored? #f)))
        (verification
         ((test-status (import-resolution reference-aliases no-export-shim))))
        (status built-in-shim)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-261))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib srfi-reference)))
        (source-version final)
        (realization alias)
        (target (stdlib srfi-reference))
        (dependencies
         ((library (stdlib srfi-reference))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib srfi-libraries))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "srfi-libraries.sld"))
        (api-version (compat 0))
        (source-version final)
        (realization shim)
        (aliases ((srfi 97) (srfi srfi-97) (srfi :97) (srfi :97 srfi-libraries)))
        (exports ())
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-97/")
          (local-reference-documents
           ((path "reference/srfi-97/srfi-97.html")
            (role specification)
            (source srfi)))
          (upstream-license "MIT") (local-license "Apache-2.0")
          (vendored? #f) (local-patches ())))
        (verification
         ((test-status
           (import-resolution library-reference-aliases no-export-shim
                              portable-host-suite))))
        (status built-in-shim)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 97))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (source built-in-shim)
        (api-version (inherits (stdlib srfi-libraries)))
        (source-version final)
        (realization shim)
        (target (stdlib srfi-libraries))
        (aliases ((srfi srfi-97) (srfi :97) (srfi :97 srfi-libraries)))
        (dependencies
         ((library (stdlib srfi-libraries))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-97/")
          (upstream-license "MIT") (local-license "Apache-2.0")
          (vendored? #f)))
        (verification
         ((test-status (import-resolution library-reference-aliases no-export-shim))))
        (status built-in-shim)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-97))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib srfi-libraries)))
        (source-version final)
        (realization alias)
        (target (stdlib srfi-libraries))
        (dependencies
         ((library (stdlib srfi-libraries))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :97))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib srfi-libraries)))
        (source-version final)
        (realization alias)
        (target (stdlib srfi-libraries))
        (dependencies
         ((library (stdlib srfi-libraries))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :97 srfi-libraries))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib srfi-libraries)))
        (source-version final)
        (realization alias)
        (target (stdlib srfi-libraries))
        (dependencies
         ((library (stdlib srfi-libraries))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib and-let-star))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "and-let-star.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "myenv-chez.scm,v 1.7 2006/01/19 02:14:07"))
        (realization portable-source)
        (aliases ((srfi 2) (srfi srfi-2) (srfi :2) (srfi :2 and-let*)))
        (exports
         (and-let*))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://okmij.org/ftp/Scheme/lib/myenv-chez.scm")
          (local-reference-documents
           ((path "reference/srfi-2/srfi-2.html")
            (role specification)
            (source srfi)))
          (source-test-url "https://okmij.org/ftp/Scheme/tests/vland.scm")
          (upstream-revision "myenv-chez.scm,v 1.7 2006/01/19 02:14:07")
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((define-library-wrapper (library (stdlib and-let-star)))
            (registry-aliases
             (aliases (srfi 2) (srfi srfi-2)
                      (srfi :2) (srfi :2 and-let*)))
            (adapted-tests (file "tests/scheme/stdlib-and-let-star-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-and-let-star-behavior
                              missing-export-diagnostic adapted-upstream-tests
                              portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 2))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib and-let-star)))
        (source-version unknown)
        (realization alias)
        (target (stdlib and-let-star))
        (aliases ((srfi srfi-2) (srfi :2) (srfi :2 and-let*)))
        (dependencies
         ((library (stdlib and-let-star))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-2))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib and-let-star)))
        (source-version unknown)
        (realization alias)
        (target (stdlib and-let-star))
        (dependencies
         ((library (stdlib and-let-star))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :2))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib and-let-star)))
        (source-version unknown)
        (realization alias)
        (target (stdlib and-let-star))
        (dependencies
         ((library (stdlib and-let-star))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :2 and-let*))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib and-let-star)))
        (source-version unknown)
        (realization alias)
        (target (stdlib and-let-star))
        (dependencies
         ((library (stdlib and-let-star))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib list))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "list.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "d502ec3832de709f00f7ae5488a334a25da8a9f9"))
        (realization portable-source)
        (aliases
         ((scheme list) (srfi 1) (srfi srfi-1) (srfi :1) (srfi :1 lists)))
        (exports
         (xcons
          tree-copy
          list-tabulate
          cons*
          proper-list?
          circular-list?
          dotted-list?
          not-pair?
          null-list?
          list=
          circular-list
          length+
          iota
          first
          second
          third
          fourth
          fifth
          sixth
          seventh
          eighth
          ninth
          tenth
          car+cdr
          take
          drop
          take-right
          drop-right
          take!
          drop-right!
          split-at
          split-at!
          last
          last-pair
          append!
          concatenate
          concatenate!
          reverse!
          append-reverse
          append-reverse!
          zip
          unzip1
          unzip2
          unzip3
          unzip4
          unzip5
          count
          fold
          fold-right
          pair-fold
          pair-fold-right
          reduce
          reduce-right
          unfold
          unfold-right
          append-map
          append-map!
          map!
          pair-for-each
          filter-map
          map-in-order
          filter
          partition
          remove
          filter!
          partition!
          remove!
          find
          find-tail
          take-while
          drop-while
          take-while!
          span
          break
          span!
          break!
          any
          every
          list-index
          delete
          delete!
          delete-duplicates
          delete-duplicates!
          alist-cons
          alist-copy
          alist-delete
          alist-delete!
          lset<=
          lset=
          lset-adjoin
          lset-union
          lset-intersection
          lset-difference
          lset-xor
          lset-diff+intersection
          lset-union!
          lset-intersection!
          lset-difference!
          lset-xor!
          lset-diff+intersection!))
        (dependencies
         ((library (scheme base))
          (library (scheme cxr))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-1")
          (local-reference-documents
           ((path "reference/srfi-1/srfi-1.html")
            (role specification)
            (source srfi))
           ((path "reference/r7rs-large/2016-07-red-edition-report.md")
            (role docket-report)
            (source r7rs-large)))
          (upstream-source-file "srfi-1-reference.scm")
          (upstream-revision "d502ec3832de709f00f7ae5488a334a25da8a9f9")
          (upstream-source-blob "56a7175d0feeddb07609937f8c59bac8eadab0d8")
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((define-library-wrapper (library (stdlib list)))
            (registry-aliases
             (aliases (scheme list) (srfi 1) (srfi srfi-1)
                      (srfi :1) (srfi :1 lists)))
            (portable-optional-argument-helpers (source local))
            (adapted-tests (file "tests/scheme/stdlib-list-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-list-behavior alias-import
                              missing-export-diagnostic portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (scheme list))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib list)))
        (source-version unknown)
        (realization alias)
        (target (stdlib list))
        (dependencies
         ((library (stdlib list))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 1))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib list)))
        (source-version unknown)
        (realization alias)
        (target (stdlib list))
        (aliases ((srfi srfi-1) (srfi :1) (srfi :1 lists)))
        (dependencies
         ((library (stdlib list))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-1))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib list)))
        (source-version unknown)
        (realization alias)
        (target (stdlib list))
        (dependencies
         ((library (stdlib list))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :1))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib list)))
        (source-version unknown)
        (realization alias)
        (target (stdlib list))
        (dependencies
         ((library (stdlib list))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :1 lists))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib list)))
        (source-version unknown)
        (realization alias)
        (target (stdlib list))
        (dependencies
         ((library (stdlib list))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib generator))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "generator.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "ffd5bac4caf70167d0b57f701a6c43aa07701158"))
        (realization portable-source)
        (aliases ((scheme generator) (srfi 158) (srfi srfi-158)))
        (exports
         (generator
          circular-generator
          make-iota-generator
          make-range-generator
          make-coroutine-generator
          list->generator
          vector->generator
          reverse-vector->generator
          string->generator
          bytevector->generator
          make-for-each-generator
          make-unfold-generator
          gcons*
          gappend
          gcombine
          gfilter
          gremove
          gtake
          gdrop
          gtake-while
          gdrop-while
          gflatten
          ggroup
          gmerge
          gmap
          gstate-filter
          gdelete
          gdelete-neighbor-dups
          gindex
          gselect
          generator->list
          generator->reverse-list
          generator->vector
          generator->vector!
          generator->string
          generator-fold
          generator-map->list
          generator-for-each
          generator-find
          generator-count
          generator-any
          generator-every
          generator-unfold
          make-accumulator
          count-accumulator
          list-accumulator
          reverse-list-accumulator
          vector-accumulator
          reverse-vector-accumulator
          vector-accumulator!
          string-accumulator
          bytevector-accumulator
          bytevector-accumulator!
          sum-accumulator
          product-accumulator))
        (dependencies
         ((library (scheme base))
          (library (scheme case-lambda))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-158")
          (local-reference-documents
           ((path "reference/srfi-158/srfi-158.html")
            (role specification)
            (source srfi))
           ((path "reference/r7rs-large/2019-02-tangerine-edition-report.md")
            (role docket-report)
            (source r7rs-large)))
          (upstream-source-file "srfi-158-impl.scm")
          (upstream-revision "ffd5bac4caf70167d0b57f701a6c43aa07701158")
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((define-library-wrapper (library (stdlib generator)))
            (registry-aliases
             (aliases (scheme generator) (srfi 158) (srfi srfi-158)))
            (portable-optional-helpers (source local))
            (accumulator-finalization-guards (source local))
            (adapted-tests (file "tests/scheme/stdlib-generator-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-generator-behavior alias-import
                              missing-export-diagnostic adapted-upstream-tests
                              portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (scheme generator))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib generator)))
        (source-version unknown)
        (realization alias)
        (target (stdlib generator))
        (dependencies
         ((library (stdlib generator))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 158))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib generator)))
        (source-version unknown)
        (realization alias)
        (target (stdlib generator))
        (dependencies
         ((library (stdlib generator))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-158))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib generator)))
        (source-version unknown)
        (realization alias)
        (target (stdlib generator))
        (dependencies
         ((library (stdlib generator))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib testing))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "testing.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "2d6a9fc514050f75802ef0003cfbf4846602a3ee"))
        (realization portable-source)
        (aliases ((srfi 64) (srfi srfi-64) (srfi :64) (srfi :64 testing)))
        (exports
         (test-begin
          test-end
          test-assert
          test-eqv
          test-eq
          test-equal
          test-approximate
          test-error
          test-apply
          test-with-runner
          test-match-nth
          test-match-all
          test-match-any
          test-match-name
          test-skip
          test-expect-fail
          test-read-eval-string
          test-runner-group-path
          test-group
          test-group-with-cleanup
          test-result-ref
          test-result-set!
          test-result-clear
          test-result-remove
          test-result-kind
          test-passed?
          test-log-to-file
          test-runner?
          test-runner-reset
          test-runner-null
          test-runner-simple
          test-runner-current
          test-runner-factory
          test-runner-get
          test-runner-create
          test-runner-test-name
          test-runner-pass-count
          test-runner-pass-count!
          test-runner-fail-count
          test-runner-fail-count!
          test-runner-xpass-count
          test-runner-xpass-count!
          test-runner-xfail-count
          test-runner-xfail-count!
          test-runner-skip-count
          test-runner-skip-count!
          test-runner-group-stack
          test-runner-group-stack!
          test-runner-on-test-begin
          test-runner-on-test-begin!
          test-runner-on-test-end
          test-runner-on-test-end!
          test-runner-on-group-begin
          test-runner-on-group-begin!
          test-runner-on-group-end
          test-runner-on-group-end!
          test-runner-on-final
          test-runner-on-final!
          test-runner-on-bad-count
          test-runner-on-bad-count!
          test-runner-on-bad-end-name
          test-runner-on-bad-end-name!
          test-result-alist
          test-result-alist!
          test-runner-aux-value
          test-runner-aux-value!
          test-on-group-begin-simple
          test-on-group-end-simple
          test-on-bad-count-simple
          test-on-bad-end-name-simple
          test-on-test-end-simple
          test-on-final-simple))
        (dependencies
         ((library (scheme base))
          (library (scheme write))
          (library (scheme read))
          (library (scheme eval))
          (library (scheme file))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-64")
          (local-reference-documents
           ((path "reference/srfi-64/srfi-64.html")
            (role specification)
            (source srfi)))
          (upstream-source-files ("testing.scm" "srfi-64-test.scm"))
          (upstream-revision "2d6a9fc514050f75802ef0003cfbf4846602a3ee")
          (upstream-source-blobs
           (("testing.scm" . "caa8dd9e3361e1e1668376da19bfcd0ba1aa33be")
            ("srfi-64-test.scm" . "aab90d1130d50c1dee945ef209c3fc83841355bf")))
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((define-library-wrapper (library (stdlib testing)))
            (registry-aliases
             (aliases (srfi 64) (srfi srfi-64)
                      (srfi :64) (srfi :64 testing)))
            (removed-host-branches
             (hosts chicken gauche guile sisc kawa mzscheme))
            (default-log-file (from #t) (to #f))
            (eval-environment (to (scheme base)))
            (adapted-tests (file "tests/scheme/stdlib-testing-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-test-runner-behavior
                              alias-import missing-export-diagnostic
                              adapted-upstream-tests portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 64))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib testing)))
        (source-version unknown)
        (realization alias)
        (target (stdlib testing))
        (aliases ((srfi srfi-64) (srfi :64) (srfi :64 testing)))
        (dependencies
         ((library (stdlib testing))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-64))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib testing)))
        (source-version unknown)
        (realization alias)
        (target (stdlib testing))
        (dependencies
         ((library (stdlib testing))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :64))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib testing)))
        (source-version unknown)
        (realization alias)
        (target (stdlib testing))
        (dependencies
         ((library (stdlib testing))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :64 testing))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib testing)))
        (source-version unknown)
        (realization alias)
        (target (stdlib testing))
        (dependencies
         ((library (stdlib testing))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib random-bits))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "random-bits.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "a547c5508d648c61e73bebed2bcd2283fba5abaa"))
        (realization portable-source)
        (aliases ((srfi 27) (srfi srfi-27) (srfi :27) (srfi :27 random-bits)))
        (exports
         (random-integer
          random-real
          default-random-source
          make-random-source
          random-source?
          random-source-state-ref
          random-source-state-set!
          random-source-randomize!
          random-source-pseudo-randomize!
          random-source-make-integers
          random-source-make-reals))
        (dependencies
         ((library (scheme base))
          (library (scheme time))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-27")
          (local-reference-documents
           ((path "reference/srfi-27/srfi-27.html")
            (role specification)
            (source srfi)))
          (upstream-source-files
           ("reference/srfi-27-a.scm" "reference/mrg32k3a-a.scm"
            "reference/mrg32k3a.scm"))
          (upstream-revision "a547c5508d648c61e73bebed2bcd2283fba5abaa")
          (upstream-source-blobs
           (("reference/srfi-27-a.scm"
             . "34388f6bd9e1317b5e081112819687d30170fe3d")
            ("reference/mrg32k3a-a.scm"
             . "a5566f40f2a668dc9f47fafb794e610a2b79f9a8")
            ("reference/mrg32k3a.scm"
             . "184d695cedbcc76ae39001ae6841ffb01f9b6bb2")))
          (upstream-test-files ("reference/conftest.scm"))
          (upstream-test-blobs
           (("reference/conftest.scm"
             . "5ceaaf0d8af4af29e8270ac52c00a69f80525cb5")))
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((define-library-wrapper (library (stdlib random-bits)))
            (registry-aliases
             (aliases (srfi 27) (srfi srfi-27)
                      (srfi :27) (srfi :27 random-bits)))
            (time-source
             (from "Scheme 48 current-time")
             (to "(scheme time) current-jiffy"))
            (upstream-confidence-tests
             (file "fixtures/srfi-27/reference/conftest.scm"))
            (adapted-tests
             (file "tests/scheme/stdlib-random-bits-test.scm")
             (file "tests/scheme/stdlib-random-bits-upstream-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-random-source-behavior
                              alias-import missing-export-diagnostic
                              clock-grant-randomization adapted-upstream-tests
                              upstream-confidence-tests portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 27))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib random-bits)))
        (source-version unknown)
        (realization alias)
        (target (stdlib random-bits))
        (aliases ((srfi srfi-27) (srfi :27) (srfi :27 random-bits)))
        (dependencies
         ((library (stdlib random-bits))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-27))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib random-bits)))
        (source-version unknown)
        (realization alias)
        (target (stdlib random-bits))
        (dependencies
         ((library (stdlib random-bits))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :27))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib random-bits)))
        (source-version unknown)
        (realization alias)
        (target (stdlib random-bits))
        (dependencies
         ((library (stdlib random-bits))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :27 random-bits))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib random-bits)))
        (source-version unknown)
        (realization alias)
        (target (stdlib random-bits))
        (dependencies
         ((library (stdlib random-bits))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib random-distributions))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "random-distributions.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "a547c5508d648c61e73bebed2bcd2283fba5abaa"))
        (realization portable-source)
        (exports
         (random-source-make-permutations
          random-permutation
          random-source-make-exponentials
          random-exponential
          random-source-make-normals
          random-normal))
        (dependencies
         ((library (scheme base))
          (library (scheme inexact))
          (library (stdlib random-bits))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-27/srfi-27.html")
          (local-reference-documents
           ((path "reference/srfi-27/srfi-27.html")
            (role specification)
            (source srfi)))
          (upstream-source-section "Recommended Usage Patterns")
          (upstream-revision "a547c5508d648c61e73bebed2bcd2283fba5abaa")
          (upstream-reference
           "Knuth TAOCP Vol. II, 2nd ed., sections 3.4.1.C, 3.4.1.D, 3.4.2")
          (upstream-license "MIT") (local-license "MIT") (vendored? #f)
          (local-patches
           ((define-library-wrapper (library (stdlib random-distributions)))
            (stdlib-surface (aliases ()))
            (argument-validation (scope distribution-parameters))
            (zero-radius-rejection (scope polar-normal-method))
            (adapted-tests
             (file "tests/scheme/stdlib-random-distributions-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-distribution-behavior
            polar-cache-behavior parameter-validation
            portable-host-suite compiled-host-smoke))))
        (status srfi-27-example-implementation)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib receive))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "receive.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (aliases ((srfi 8) (srfi srfi-8) (srfi :8) (srfi :8 receive)))
        (exports
         (receive))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-8/")
          (upstream-license "MIT")
          (local-reference-documents
           ((path "reference/srfi-8/srfi-8.html")
            (role specification)
            (source srfi))
           ((path "reference/r7rs-large/2022-02-yellow-edition-report.txt")
            (role docket-report)
            (source r7rs-large)))
          (local-license "Apache-2.0") (vendored? #f)
          (local-patches
           ((define-library-wrapper (library (stdlib receive)))
            (registry-aliases
             (aliases (srfi 8) (srfi srfi-8)
                      (srfi :8) (srfi :8 receive)))
            (local-tests (file "tests/scheme/stdlib-receive-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-receive-behavior
                              missing-export-diagnostic portable-host-suite))))
        (status built-in-shim)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 8))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib receive)))
        (source-version unknown)
        (realization alias)
        (target (stdlib receive))
        (aliases ((srfi srfi-8) (srfi :8) (srfi :8 receive)))
        (dependencies
         ((library (stdlib receive))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-8))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib receive)))
        (source-version unknown)
        (realization alias)
        (target (stdlib receive))
        (dependencies
         ((library (stdlib receive))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :8))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib receive)))
        (source-version unknown)
        (realization alias)
        (target (stdlib receive))
        (dependencies
         ((library (stdlib receive))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi :8 receive))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib receive)))
        (source-version unknown)
        (realization alias)
        (target (stdlib receive))
        (dependencies
         ((library (stdlib receive))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib assume))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "assume.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (aliases ((srfi 145) (srfi srfi-145)))
        (exports
         (assume))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (upstream-source-url "https://srfi.schemers.org/srfi-145/")
          (upstream-license "MIT")
          (local-reference-documents
           ((path "reference/srfi-145/srfi-145.html")
            (role specification)
            (source srfi)))
          (local-license "Apache-2.0") (vendored? #f)
          (local-patches
           ((define-library-wrapper (library (stdlib assume)))
            (registry-aliases (aliases (srfi 145) (srfi srfi-145)))
            (local-tests (file "tests/scheme/stdlib-assume-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-assume-behavior
                              missing-export-diagnostic portable-host-suite))))
        (status built-in-shim)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 145))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib assume)))
        (source-version unknown)
        (realization alias)
        (target (stdlib assume))
        (dependencies
         ((library (stdlib assume))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-145))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib assume)))
        (source-version unknown)
        (realization alias)
        (target (stdlib assume))
        (dependencies
         ((library (stdlib assume))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib comparator))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "comparator.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "3ec333638e787d75a16de83fcf9645c998e4d976"))
        (realization portable-source)
        (aliases ((scheme comparator) (srfi 128) (srfi srfi-128)))
        (exports
         (comparator?
          comparator-ordered?
          comparator-hashable?
          make-comparator
          make-pair-comparator
          make-list-comparator
          make-vector-comparator
          make-eq-comparator
          make-eqv-comparator
          make-equal-comparator
          boolean-hash
          char-hash
          char-ci-hash
          string-hash
          string-ci-hash
          symbol-hash
          number-hash
          make-default-comparator
          default-hash
          comparator-register-default!
          comparator-type-test-predicate
          comparator-equality-predicate
          comparator-ordering-predicate
          comparator-hash-function
          comparator-test-type
          comparator-check-type
          comparator-hash
          hash-bound
          hash-salt
          =?
          <?
          >?
          <=?
          >=?
          comparator-if<=>))
        (dependencies
         ((library (scheme base))
          (library (scheme case-lambda))
          (library (scheme char))
          (library (scheme inexact))
          (library (scheme complex))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-128")
          (local-reference-documents
           ((path "reference/srfi-128/srfi-128.html")
            (role specification)
            (source srfi))
           ((path "reference/r7rs-large/2016-07-red-edition-report.md")
            (role docket-report)
            (source r7rs-large)))
          (upstream-revision "3ec333638e787d75a16de83fcf9645c998e4d976")
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((library-name (from (srfi 128)) (to (stdlib comparator)))
            (inlined-includes (files "srfi/128.body1.scm" "srfi/128.body2.scm"))
            (documentation-metadata (scope exported-procedures))
            (default-hash (source local-portable-implementation))
            (stateful-hasher (source upstream-style-case-lambda))
            (hash-helpers (source local-portable-procedures))))))
        (verification
         ((test-status
           (import-resolution representative-comparator-behavior alias-import
                              missing-export-diagnostic portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib rbtree))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "rbtree.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "28bd72ed4d8445d8a91f84d919630d0f3a7564fb"))
        (realization portable-source)
        (exports
         (make-tree
          tree-search
          tree-for-each
          tree-fold
          tree-fold/reverse
          tree-generator
          tree-key-predecessor
          tree-key-successor
          tree-map
          tree-catenate
          tree-split))
        (dependencies
         ((library (scheme base))
          (library (scheme case-lambda))
          (library (stdlib and-let-star))
          (library (stdlib receive))
          (library (stdlib generator))
          (library (stdlib comparator))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-146")
          (local-reference-documents
           ((path "reference/srfi-146/srfi-146.html")
            (role specification)
            (source srfi)))
          (upstream-source-path "nieper")
          (upstream-source-files ("nieper/rbtree.sld" "nieper/rbtree.scm"))
          (upstream-revision "28bd72ed4d8445d8a91f84d919630d0f3a7564fb")
          (upstream-source-blobs
           (("nieper/rbtree.sld" . "d74e8e469e990dcad0d6a02d8c9cc63943aa3cba")
            ("nieper/rbtree.scm" . "03b901e37b5c82333860301ac0bbf6ef96646f26")))
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((library-name (from (nieper rbtree)) (to (stdlib rbtree)))
            (inlined-include (file "nieper/rbtree.scm"))
            (adapted-imports (from (srfi 2) (srfi 8) (srfi 158) (srfi 128))
             (to (stdlib and-let-star) (stdlib receive)
              (stdlib generator) (stdlib comparator)))
            (matcher-hygiene (source local-portability-patch)
             (scope nested-tree-patterns black-height))
            (documentation-metadata (scope exported-procedures))
            (removed-unused-accessors (names key value))
            (internal-stdlib-helper (aliases ()))
            (adapted-tests (file "tests/scheme/stdlib-rbtree-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-tree-behavior mutation-sequences
                              missing-export-diagnostic helper-smoke
                              portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (stdlib mapping))
        (owner stdlib)
        (provider repo-source)
        (visibility public)
        (source-kind source-library)
        (source (path "mapping.sld"))
        (api-version (compat 0))
        (source-version (upstream-revision "28bd72ed4d8445d8a91f84d919630d0f3a7564fb"))
        (realization portable-source)
        (aliases ((scheme mapping) (srfi 146) (srfi srfi-146)))
        (exports
         (mapping
          mapping-unfold
          mapping/ordered
          mapping-unfold/ordered
          mapping?
          mapping-contains?
          mapping-empty?
          mapping-disjoint?
          mapping-ref
          mapping-ref/default
          mapping-key-comparator
          mapping-adjoin
          mapping-adjoin!
          mapping-set
          mapping-set!
          mapping-replace
          mapping-replace!
          mapping-delete
          mapping-delete!
          mapping-delete-all
          mapping-delete-all!
          mapping-intern
          mapping-intern!
          mapping-update
          mapping-update!
          mapping-update/default
          mapping-update!/default
          mapping-pop
          mapping-pop!
          mapping-search
          mapping-search!
          mapping-size
          mapping-find
          mapping-count
          mapping-any?
          mapping-every?
          mapping-keys
          mapping-values
          mapping-entries
          mapping-map
          mapping-map->list
          mapping-for-each
          mapping-fold
          mapping-filter
          mapping-filter!
          mapping-remove
          mapping-remove!
          mapping-partition
          mapping-partition!
          mapping-copy
          mapping->alist
          alist->mapping
          alist->mapping!
          alist->mapping/ordered
          alist->mapping/ordered!
          mapping=?
          mapping<?
          mapping>?
          mapping<=?
          mapping>=?
          mapping-union
          mapping-intersection
          mapping-difference
          mapping-xor
          mapping-union!
          mapping-intersection!
          mapping-difference!
          mapping-xor!
          make-mapping-comparator
          mapping-comparator
          mapping-min-key
          mapping-max-key
          mapping-min-value
          mapping-max-value
          mapping-key-predecessor
          mapping-key-successor
          mapping-range=
          mapping-range<
          mapping-range>
          mapping-range<=
          mapping-range>=
          mapping-range=!
          mapping-range<!
          mapping-range>!
          mapping-range<=!
          mapping-range>=!
          mapping-split
          mapping-catenate
          mapping-catenate!
          mapping-map/monotone
          mapping-map/monotone!
          mapping-fold/reverse
          comparator?))
        (dependencies
         ((library (scheme base))
          (library (scheme case-lambda))
          (library (stdlib list))
          (library (stdlib receive))
          (library (stdlib comparator))
          (library (stdlib assume))
          (library (stdlib rbtree))))
        (provenance
         ((origin repo)
          (upstream-source-url
           "https://github.com/scheme-requests-for-implementation/srfi-146")
          (local-reference-documents
           ((path "reference/srfi-146/srfi-146.html")
            (role specification)
            (source srfi))
           ((path "reference/r7rs-large/2019-02-tangerine-edition-report.md")
            (role docket-report)
            (source r7rs-large)))
          (upstream-source-files ("srfi/146.sld" "srfi/146.scm"))
          (upstream-source-test-file "srfi/146/test.sld")
          (upstream-revision "28bd72ed4d8445d8a91f84d919630d0f3a7564fb")
          (upstream-source-blobs
           (("srfi/146.sld" . "dbeb605b19232b8fbccb6fb8c94bd5ec1538a85e")
            ("srfi/146.scm" . "3e37da6667e55e14b7d7e93db8353530072819c9")
            ("srfi/146/test.sld" . "e1804c30ee1e3c5a1cfbf0fa60ed382f2326dfdf")))
          (upstream-license "MIT") (local-license "MIT") (vendored? #t)
          (local-patches
           ((library-name (from (srfi 146)) (to (stdlib mapping)))
            (inlined-include (file "srfi/146.scm"))
            (adapted-imports
             (from (srfi 1) (srfi 8) (srfi 128) (srfi 145) (nieper rbtree))
             (to (stdlib list) (stdlib receive) (stdlib comparator)
              (stdlib assume) (stdlib rbtree)))
            (registry-aliases
             (aliases (scheme mapping) (srfi 146) (srfi srfi-146)))
            (documentation-metadata (scope exported-procedures))
            (linear-update (strategy pure-functional))
            (hash-variant-out-of-scope (issue 624))
            (local-tests (file "tests/scheme/stdlib-mapping-test.scm"))
            (adapted-tests
             (file "tests/scheme/stdlib-mapping-conformance-test.scm"))))))
        (verification
         ((test-status
           (import-resolution representative-mapping-behavior alias-import
                              missing-export-diagnostic hash-alias-diagnostic
                              model-oracle adapted-upstream-tests
                              direct-host-conformance compiled-host-smoke
                              portable-host-suite))))
        (status vendored-adapted-implementation)
        (canonical #t))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (scheme mapping))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib mapping)))
        (source-version unknown)
        (realization alias)
        (target (stdlib mapping))
        (dependencies
         ((library (stdlib mapping))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 146))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib mapping)))
        (source-version unknown)
        (realization alias)
        (target (stdlib mapping))
        (dependencies
         ((library (stdlib mapping))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-146))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib mapping)))
        (source-version unknown)
        (realization alias)
        (target (stdlib mapping))
        (dependencies
         ((library (stdlib mapping))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (scheme comparator))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib comparator)))
        (source-version unknown)
        (realization alias)
        (target (stdlib comparator))
        (dependencies
         ((library (stdlib comparator))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi 128))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib comparator)))
        (source-version unknown)
        (realization alias)
        (target (stdlib comparator))
        (dependencies
         ((library (stdlib comparator))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))
       (manifest-index-entry
        (schema-version 1)
        (kind library-alias)
        (name (srfi srfi-128))
        (owner stdlib)
        (provider repo-source)
        (visibility alias)
        (source-kind alias)
        (api-version (inherits (stdlib comparator)))
        (source-version unknown)
        (realization alias)
        (target (stdlib comparator))
        (dependencies
         ((library (stdlib comparator))))
        (provenance ((origin repo)))
        (verification ((test-status (import-resolution))))
        (status alias)
        (canonical #f))))

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
         ((equal? (cadr (assq 'name (cdr (car rest)))) library) (car rest))
         (else (loop (cdr rest))))))))
