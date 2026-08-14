;;; Portable Consent Scheme core library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This load-light manifest records the public and internal library surface
;;; owned by the core Consent Scheme runtime. It is metadata, not authority to
;;; import or execute the named libraries.

(define-library (consent manifest)
  (export consent-library-manifest consent-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe core runtime libraries and primitive overlays.
    (define consent-library-manifest
      '((manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent manifest))
        (owner consent-core)
        (provider repo-source)
        (visibility public-consent)
        (layer manifest)
        (source-kind source-library)
        (source (path "manifest.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-library-manifest
          consent-library-manifest-ref))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent growable-vector))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "growable-vector.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-make-growable-vector
          consent-growable-vector?
          consent-growable-vector-active?
          consent-growable-vector-length
          consent-growable-vector-capacity
          consent-growable-vector-maximum-capacity
          consent-growable-vector-growth-factor
          consent-growable-vector-append!
          consent-growable-vector-ref
          consent-growable-vector-set!
          consent-growable-vector-unsafe-ref
          consent-growable-vector-unsafe-set!
          consent-growable-vector-copy!
          consent-growable-vector-fill!
          consent-growable-vector-reserve!
          consent-growable-vector-grow!
          consent-growable-vector-snapshot
          consent-growable-vector-truncate!
          consent-growable-vector-clear!
          consent-growable-vector-reset!
          consent-growable-vector-release!
          consent-growable-vector-unused-slots-cleared?
          consent-growable-vector-stats))
        (dependencies ((library (scheme base))))
        (provenance
         ((origin repo)
          (allocation-policy bounded-callback-free)
          (growth-policy
           (default-factor 2)
           (factor per-object-immutable))
          (bulk-operations
           (copy overlap-safe)
           (fill populated-prefix))
          (memory-lifecycle
           (clear reset-to-initial-capacity)
           (reset retain-capacity)
           (release terminal))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent dense-set))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "dense-set.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-make-dense-set
          consent-dense-set?
          consent-dense-set-active?
          consent-dense-set-domain
          consent-dense-set-empty?
          consent-dense-set-size
          consent-dense-set-capacity
          consent-dense-set-maximum-capacity
          consent-dense-set-maximum-generation
          consent-dense-set-color-count
          consent-dense-set-growth-policy
          consent-dense-set-generation
          consent-dense-set-reserve!
          consent-dense-set-member?
          consent-dense-set-color
          consent-dense-set-mark!
          consent-dense-set-unmark!
          consent-dense-set-clear!
          consent-dense-set-full-clear!
          consent-dense-set-release!
          consent-dense-set-integral-storage?
          consent-dense-set-stats))
        (dependencies
         ((library (scheme base))
          (library (consent growable-vector))))
        (provenance
         ((origin repo)
          (representation generation-and-color-exact-integer)
          (allocation-policy bounded-callback-free)
          (growth-policies (allow-growth pre-reserved))
          (clear-policy generation-advance-with-explicit-wrap)
          (memory-lifecycle scalar-stamps-only)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent scratch-arena))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "scratch-arena.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-make-scratch-arena
          consent-scratch-arena?
          consent-scratch-arena-reserve!
          consent-scratch-arena-acquire!
          consent-scratch-owner?
          consent-scratch-owner-active?
          consent-scratch-owner-phase
          consent-scratch-owner-length
          consent-scratch-owner-capacity
          consent-scratch-owner-append!
          consent-scratch-owner-ref
          consent-scratch-owner-set!
          consent-scratch-owner-mark
          consent-scratch-owner-reset!
          consent-scratch-owner-release!
          consent-scratch-arena-unused-slots-cleared?
          consent-scratch-arena-stats))
        (dependencies
         ((library (scheme base))
          (library (consent growable-vector))))
        (provenance
         ((origin repo)
          (allocation-policy bounded-callback-free)
          (ownership phase-scoped)))
       (status internal)
       (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent worklist))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "worklist.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-make-worklist
          consent-worklist?
          consent-worklist-active?
          consent-worklist-empty?
          consent-worklist-size
          consent-worklist-capacity
          consent-worklist-maximum-capacity
          consent-worklist-growth-policy
          consent-worklist-reserve!
          consent-worklist-push-front!
          consent-worklist-push-back!
          consent-worklist-front
          consent-worklist-back
          consent-worklist-pop-front!
          consent-worklist-pop-back!
          consent-worklist-snapshot
          consent-worklist-clear!
          consent-worklist-reset!
          consent-worklist-release!
          consent-worklist-work-units
          consent-worklist-unused-slots-cleared?
          consent-worklist-stats))
        (dependencies
         ((library (scheme base))
          (library (consent growable-vector))))
        (provenance
         ((origin repo)
          (representation bounded-ring-buffer)
          (allocation-policy bounded-callback-free)
          (growth-policies (allow-growth pre-reserved))
          (work-accounting successful-pushes-and-pops)
          (memory-lifecycle
           (clear reset-to-initial-capacity)
           (reset retain-capacity)
           (release terminal))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (consent identity-map primitive))
        (owner consent-core)
        (provider host-adapter)
        (visibility internal-runtime)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id consent-identity-map))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (consent-identity-map-fast-backend?
          consent-make-identity-map
          consent-identity-map-ref
          consent-identity-map-set!))
        (primitive-exports
         ((name consent-identity-map-fast-backend?)
          (primitive primitive-consent-identity-map-fast-backend?)
          (arity 0 0)
          (effects (pure))
          (capabilities ()))
         ((name consent-make-identity-map)
          (primitive primitive-consent-make-identity-map)
          (arity 0 0)
          (effects (allocation))
          (capabilities ()))
         ((name consent-identity-map-ref)
          (primitive primitive-consent-identity-map-ref)
          (arity 3 3)
          (effects (state-read))
          (capabilities ()))
         ((name consent-identity-map-set!)
          (primitive primitive-consent-identity-map-set!)
          (arity 3 3)
          (effects (state-write))
          (capabilities ())))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (boundary host-identity-hash)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent compiler-manifest))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer compiler-front-end)
        (source-kind source-library)
        (source (path "compiler-manifest.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-compiler-images consent-compiler-image-ref))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
       (status internal)
       (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent identity-map))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "identity-map.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (consent identity-map primitive))
        (exports
         (consent-identity-map-fast-backend?
          consent-make-identity-map
          consent-identity-map-ref
          consent-identity-map-set!))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (gambit-accelerator native-identity-table)
          (optional-accelerator (library (srfi 69)))
          (fallback identity-alist)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent datum))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "datum.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-datum-heap?
          consent-make-datum-heap
          consent-default-datum-heap
          consent-datum-heap-id
          consent-datum-heap-generation
          consent-datum-heap-owner
          consent-datum-heap-owner-set!
          consent-datum-heap-mutation-hook-set!
          consent-datum-object?
          consent-datum-object-kind
          consent-datum-object-heap-id
          consent-datum-object-id
          consent-datum-object-generation
          consent-datum-object-owner
          consent-datum-object-revision
          consent-datum-object-mutable?
          consent-datum-object-traversal
          consent-datum-object-traversal-set!
          consent-datum-object-source-metadata
          consent-datum-object-source-metadata-set!
          consent-make-datum-object-map
          consent-datum-object-map-ref
          consent-datum-object-map-set!
          consent-datum-object-map-release!
          consent-datum-object-map-probe-count
          call-with-consent-datum-object-map
          consent-call-with-datum-construction
          consent-datum-same?
          consent-datum-pair?
          consent-datum-cons
          consent-datum-car
          consent-datum-cdr
          consent-datum-set-car!
          consent-datum-set-cdr!
          consent-datum-list-copy
          consent-datum-string?
          consent-datum-string-from-host
          consent-datum-string->host
          consent-datum-make-string
          consent-datum-string-copy-range
          consent-datum-string-length
          consent-datum-string-ref-host
          consent-datum-string-set-host!
          consent-datum-vector?
          consent-datum-vector-from-host
          consent-datum-vector-from-host-elements
          consent-datum-vector->host
          consent-datum-make-vector
          consent-datum-vector-length
          consent-datum-vector-ref
          consent-datum-vector-set!
          consent-datum-bytevector?
          consent-datum-bytevector-from-host
          consent-datum-bytevector->host
          consent-datum-make-bytevector
          consent-datum-bytevector-length
          consent-datum-bytevector-u8-ref
          consent-datum-bytevector-u8-set!
          consent-datum-import
          consent-datum-export))
        (dependencies
         ((library (scheme base))
          (library (consent identity-map))))
        (provenance
         ((origin repo)
          (identity heap-id-and-object-id)
          (representation owned-opaque-compound-records)
          (boundary private-host-container-accelerators)
          (future-branch-isolation issue-721)))
        (verification
         ((test-status
           (identity aliasing mutation cycles shared-writer native-bridge
                     portable-host-suite compiled-host-suite))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent numeric))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "numeric.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-make-numeric-backend
          consent-default-numeric-backend
          consent-numeric-backend-limb-bits
          consent-numeric-backend-positive-fixnum-limit
          consent-numeric))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (verification
         ((test-status
           (exact-limbs rational-arithmetic binary64-core
                        default-profile alternate-profile))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent compiler-plan))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer compiler-front-end)
        (source-kind source-library)
        (source (path "compiler-plan.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-compiler-plan
          consent-compiler-plan-roots
          consent-compiler-plan-units
          consent-compiler-plan-native-libraries
          consent-compiler-unit-name
          consent-compiler-unit-source
          consent-compiler-unit-dependencies))
        (dependencies
         ((library (scheme base))
          (library (consent compiler-manifest))
          (library (consent manifest))
          (library (stdlib manifest))
          (library (data manifest))
          (library (agent manifest))
          (library (cli manifest))))
        (provenance ((origin repo)))
        (verification
         ((test-status
           (manifest-derived dependency-ordered backend-shared))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (scheme base))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind base-snapshot)
        (source (implementation-source base-environment-snapshot))
        (api-version (compat 0))
        (source-version runtime)
        (realization runtime-snapshot)
        (exports
         (*
          +
          -
          /
          <
          <=
          =
          >
          >=
          apply
          binary-port?
          boolean=?
          boolean?
          bytevector
          bytevector-append
          bytevector-copy
          bytevector-copy!
          bytevector-length
          bytevector-u8-ref
          bytevector-u8-set!
          bytevector?
          call-with-current-continuation
          call-with-port
          call-with-values
          call/cc
          car
          cdr
          ceiling
          char->integer
          char<=?
          char<?
          char=?
          char>=?
          char>?
          char-ready?
          char?
          close-input-port
          close-output-port
          close-port
          complex?
          cons
          dynamic-wind
          eq?
          equal?
          eqv?
          eof-object
          eof-object?
          error
          error-object-irritants
          error-object-message
          error-object?
          current-error-port
          current-input-port
          current-output-port
          denominator
          exact
          exact-integer-sqrt
          exact-integer?
          exact?
          expt
          features
          file-error?
          flush-output-port
          floor
          floor/
          floor-quotient
          floor-remainder
          gcd
          get-output-bytevector
          get-output-string
          inexact
          inexact?
          input-port-open?
          input-port?
          integer->char
          integer?
          lcm
          list->string
          list->vector
          list?
          make-bytevector
          make-parameter
          make-string
          make-vector
          modulo
          newline
          null?
          number->string
          number?
          open-input-bytevector
          open-input-string
          open-output-bytevector
          open-output-string
          output-port-open?
          output-port?
          numerator
          pair?
          peek-char
          peek-u8
          port?
          procedure?
          quotient
          raise
          raise-continuable
          rational?
          rationalize
          read-bytevector
          read-bytevector!
          read-char
          read-error?
          read-line
          read-string
          read-u8
          real?
          remainder
          round
          set-car!
          set-cdr!
          string
          string->list
          string->number
          string->symbol
          string->utf8
          string->vector
          string-append
          string-copy
          string-copy!
          string-fill!
          string-length
          string-ref
          string-set!
          string<=?
          string<?
          string=?
          string>=?
          string>?
          string?
          substring
          symbol->string
          symbol=?
          symbol?
          textual-port?
          truncate
          truncate/
          truncate-quotient
          truncate-remainder
          u8-ready?
          utf8->string
          vector
          vector->list
          vector->string
          vector-append
          vector-copy
          vector-copy!
          vector-fill!
          vector-length
          vector-ref
          vector-set!
          vector?
          values
          with-exception-handler
          write-bytevector
          write-char
          write-string
          write-u8
          not
          list
          caar
          cadr
          cdar
          cddr
          length
          append
          reverse
          list-tail
          list-ref
          list-set!
          make-list
          list-copy
          memq
          memv
          member
          assq
          assv
          assoc
          zero?
          positive?
          negative?
          abs
          square
          even?
          odd?
          min
          max
          map
          for-each
          string-map
          string-for-each
          vector-map
          vector-for-each
          cond
          case
          and
          or
          when
          unless
          let
          let*
          do
          parameterize
          cond-expand
          guard
          guard-aux))
        (dependencies ())
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (scheme case-lambda))
        (owner r7rs-small)
        (provider repo-source)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind source-library)
        (source (path "case-lambda.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (case-lambda))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (scheme char))
        (owner r7rs-small)
        (provider repo-source)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind source-library)
        (source (path "char.sld"))
        (api-version (compat 0))
        (source-version (unicode 17 0 0))
        (realization portable-source)
        (exports
         (char-alphabetic?
          char-ci<=?
          char-ci<?
          char-ci=?
          char-ci>=?
          char-ci>?
          char-downcase
          char-foldcase
          char-lower-case?
          char-numeric?
          char-upcase
          char-upper-case?
          char-whitespace?
          digit-value
          string-ci<=?
          string-ci<?
          string-ci=?
          string-ci>=?
          string-ci>?
          string-downcase
          string-foldcase
          string-upcase))
        (dependencies
         ((library (scheme base))
          (library (consent unicode-data))))
        (provenance
         ((origin repo)
          (generated-from unicode-character-database)
          (upstream-license Unicode-3.0)
          (semantics consent-owned-unicode-profile)))
        (verification
         ((test-status
          (generated-data classification boundary-cases simple-case
                          full-case compiled-host-suite))))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme complex))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-complex))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (angle
          imag-part
          magnitude
          make-polar
          make-rectangular
          real-part))
        (primitive-exports
         ((name angle)
          (primitive primitive-angle)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name imag-part)
          (primitive primitive-imag-part)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name magnitude)
          (primitive primitive-magnitude)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name make-polar)
          (primitive primitive-make-polar)
          (arity 2 2)
          (effects (pure))
          (capabilities ()))
         ((name make-rectangular)
          (primitive primitive-make-rectangular)
          (arity 2 2)
          (effects (pure))
          (capabilities ()))
         ((name real-part)
          (primitive primitive-real-part)
          (arity 1 1)
          (effects (pure))
          (capabilities ())))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (scheme cxr))
        (owner r7rs-small)
        (provider repo-source)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind source-library)
        (source (path "cxr.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (caaar
          caadr
          cadar
          caddr
          cdaar
          cdadr
          cddar
          cdddr
          caaaar
          caaadr
          caadar
          caaddr
          cadaar
          cadadr
          caddar
          cadddr
          cdaaar
          cdaadr
          cdadar
          cdaddr
          cddaar
          cddadr
          cdddar
          cddddr))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme eval))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-eval))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (environment
          eval))
        (primitive-exports
         ((name environment)
          (primitive primitive-environment)
          (arity 1 #f)
          (effects (evaluation))
          (capabilities ()))
         ((name eval)
          (primitive primitive-eval)
          (arity 2 2)
          (effects (evaluation))
          (capabilities ())))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme file))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-file))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (call-with-input-file
          call-with-output-file
          delete-file
          file-exists?
          open-binary-input-file
          open-binary-output-file
          open-input-file
          open-output-file
          with-input-from-file
          with-output-to-file))
        (primitive-exports
         ((name call-with-input-file)
          (primitive primitive-call-with-input-file)
          (arity 2 2)
          (effects (host-file))
          (capabilities (file-system)))
         ((name call-with-output-file)
          (primitive primitive-call-with-output-file)
          (arity 2 2)
          (effects (host-file))
          (capabilities (file-system)))
         ((name delete-file)
          (primitive primitive-delete-file)
          (arity 1 1)
          (effects (host-file))
          (capabilities (file-system)))
         ((name file-exists?)
          (primitive primitive-file-exists?)
          (arity 1 1)
          (effects (host-file))
          (capabilities (file-system)))
         ((name open-binary-input-file)
          (primitive primitive-open-binary-input-file)
          (arity 1 1)
          (effects (host-file))
          (capabilities (file-system)))
         ((name open-binary-output-file)
          (primitive primitive-open-binary-output-file)
          (arity 1 1)
          (effects (host-file))
          (capabilities (file-system)))
         ((name open-input-file)
          (primitive primitive-open-input-file)
          (arity 1 1)
          (effects (host-file))
          (capabilities (file-system)))
         ((name open-output-file)
          (primitive primitive-open-output-file)
          (arity 1 1)
          (effects (host-file))
          (capabilities (file-system)))
         ((name with-input-from-file)
          (primitive primitive-with-input-from-file)
          (arity 2 2)
          (effects (host-file))
          (capabilities (file-system)))
         ((name with-output-to-file)
          (primitive primitive-with-output-to-file)
          (arity 2 2)
          (effects (host-file))
          (capabilities (file-system))))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme inexact))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-inexact))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (acos
          asin
          atan
          cos
          exp
          finite?
          infinite?
          log
          nan?
          sin
          sqrt
          tan))
        (primitive-exports
         ((name acos)
          (primitive primitive-acos)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name asin)
          (primitive primitive-asin)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name atan)
          (primitive primitive-atan)
          (arity 1 2)
          (effects (pure))
          (capabilities ()))
         ((name cos)
          (primitive primitive-cos)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name exp)
          (primitive primitive-exp)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name finite?)
          (primitive primitive-finite?)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name infinite?)
          (primitive primitive-infinite?)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name log)
          (primitive primitive-log)
          (arity 1 2)
          (effects (pure))
          (capabilities ()))
         ((name nan?)
          (primitive primitive-nan?)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name sin)
          (primitive primitive-sin)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name sqrt)
          (primitive primitive-sqrt)
          (arity 1 1)
          (effects (pure))
          (capabilities ()))
         ((name tan)
          (primitive primitive-tan)
          (arity 1 1)
          (effects (pure))
          (capabilities ())))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (scheme lazy))
        (owner r7rs-small)
        (provider repo-source)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind source-library)
        (source (path "lazy.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (delay
          delay-force
          force
          make-promise
          promise?))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme load))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-load))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (load))
        (primitive-exports
         ((name load)
          (primitive primitive-load)
          (arity 1 2)
          (effects (host-file))
          (capabilities (file-system))))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme process-context))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-process-context))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (command-line
          emergency-exit
          exit
          get-environment-variable
          get-environment-variables))
        (primitive-exports
         ((name command-line)
          (primitive primitive-command-line)
          (arity 0 0)
          (effects (host-process))
          (capabilities (process-environment)))
         ((name emergency-exit)
          (primitive primitive-emergency-exit)
          (arity 0 #f)
          (effects (host-process))
          (capabilities (process-environment)))
         ((name exit)
          (primitive primitive-exit)
          (arity 0 #f)
          (effects (host-process))
          (capabilities (process-environment)))
         ((name get-environment-variable)
          (primitive primitive-get-environment-variable)
          (arity 1 1)
          (effects (host-process))
          (capabilities (process-environment)))
         ((name get-environment-variables)
          (primitive primitive-get-environment-variables)
          (arity 0 0)
          (effects (host-process))
          (capabilities (process-environment))))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme read))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-read))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (read))
        (primitive-exports
         ((name read)
          (primitive primitive-read)
          (arity 0 1)
          (effects (state-read))
          (capabilities ())))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme repl))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-repl))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (interaction-environment))
        (primitive-exports
         ((name interaction-environment)
          (primitive primitive-interaction-environment)
          (arity 0 0)
          (effects (host-repl))
          (capabilities (repl))))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (scheme r5rs))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind derived)
        (source (implementation-id scheme-r5rs))
        (api-version (compat 0))
        (source-version runtime)
        (realization derived)
        (exports
         (guard-aux
          guard
          cond-expand
          parameterize
          do
          let*
          let
          unless
          when
          or
          and
          case
          cond
          vector-for-each
          vector-map
          string-for-each
          string-map
          for-each
          map
          max
          min
          odd?
          even?
          square
          abs
          negative?
          positive?
          zero?
          assoc
          assv
          assq
          member
          memv
          memq
          list-copy
          make-list
          list-set!
          list-ref
          list-tail
          reverse
          append
          length
          cddr
          cdar
          cadr
          caar
          list
          not
          write-u8
          write-string
          write-char
          write-bytevector
          with-exception-handler
          values
          vector?
          vector-set!
          vector-ref
          vector-length
          vector-fill!
          vector-copy!
          vector-copy
          vector-append
          vector->string
          vector->list
          vector
          utf8->string
          u8-ready?
          truncate-remainder
          truncate-quotient
          truncate/
          truncate
          textual-port?
          symbol?
          symbol=?
          symbol->string
          substring
          string?
          string>?
          string>=?
          string=?
          string<?
          string<=?
          string-set!
          string-ref
          string-length
          string-fill!
          string-copy!
          string-copy
          string-append
          string->vector
          string->utf8
          string->symbol
          string->number
          string->list
          string
          set-cdr!
          set-car!
          round
          remainder
          real?
          read-u8
          read-string
          read-line
          read-error?
          read-char
          read-bytevector!
          read-bytevector
          rationalize
          rational?
          raise-continuable
          raise
          quotient
          procedure?
          port?
          peek-u8
          peek-char
          pair?
          numerator
          output-port?
          output-port-open?
          open-output-string
          open-output-bytevector
          open-input-string
          open-input-bytevector
          number?
          number->string
          null?
          newline
          modulo
          make-vector
          make-string
          make-parameter
          make-bytevector
          list?
          list->vector
          list->string
          lcm
          integer?
          integer->char
          input-port?
          input-port-open?
          inexact?
          inexact
          get-output-string
          get-output-bytevector
          gcd
          floor-remainder
          floor-quotient
          floor/
          floor
          flush-output-port
          file-error?
          features
          expt
          exact?
          exact-integer?
          exact-integer-sqrt
          exact
          denominator
          current-output-port
          current-input-port
          current-error-port
          error-object?
          error-object-message
          error-object-irritants
          error
          eof-object?
          eof-object
          eqv?
          equal?
          eq?
          dynamic-wind
          cons
          complex?
          close-port
          close-output-port
          close-input-port
          char?
          char-ready?
          char>?
          char>=?
          char=?
          char<?
          char<=?
          char->integer
          ceiling
          cdr
          car
          call/cc
          call-with-values
          call-with-port
          call-with-current-continuation
          bytevector?
          bytevector-u8-set!
          bytevector-u8-ref
          bytevector-length
          bytevector-copy!
          bytevector-copy
          bytevector-append
          bytevector
          boolean?
          boolean=?
          binary-port?
          apply
          >=
          >
          =
          <=
          <
          /
          -
          +
          *
          exact->inexact
          inexact->exact))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme time))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-time))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (current-jiffy
          current-second
          jiffies-per-second))
        (primitive-exports
         ((name current-jiffy)
          (primitive primitive-current-jiffy)
          (arity 0 0)
          (effects (host-time))
          (capabilities (clock)))
         ((name current-second)
          (primitive primitive-current-second)
          (arity 0 0)
          (effects (host-time))
          (capabilities (clock)))
         ((name jiffies-per-second)
          (primitive primitive-jiffies-per-second)
          (arity 0 0)
          (effects (host-time))
          (capabilities (clock))))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (scheme write))
        (owner r7rs-small)
        (provider consent-core)
        (visibility public)
        (layer standard)
        (category standard)
        (source-kind primitive-library)
        (source (implementation-id scheme-write))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (display
          write
          write-shared
          write-simple))
        (primitive-exports
         ((name display)
          (primitive primitive-display)
          (arity 1 2)
          (effects (state-write))
          (capabilities ()))
         ((name write)
          (primitive primitive-write)
          (arity 1 2)
          (effects (state-write))
          (capabilities ()))
         ((name write-shared)
          (primitive primitive-write-shared)
          (arity 1 2)
          (effects (state-write))
          (capabilities ()))
         ((name write-simple)
          (primitive primitive-write-simple)
          (arity 1 2)
          (effects (state-write))
          (capabilities ())))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent capability))
        (owner consent-core)
        (provider repo-source)
        (visibility public-consent)
        (layer api)
        (source-kind source-library)
        (source (path "capability.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (grant-capability!
          current-grants
          grant-ref
          grant-attenuate
          grant-revoke!
          handle-ref
          handle-live?
          handle-kind
          handle-revalidate
          handle-release!
          call-with-capability-grant
          with-capability-grant))
        (dependencies
         ((library (scheme base))
          (library (consent capability primitive))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (consent capability primitive))
        (owner consent-core)
        (provider host-adapter)
        (visibility internal-runtime)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id consent-capability))
        (implementation-resolver
         (module consent-capability)
         (procedure consent-capability-primitive-implementation))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (grant-capability!
          current-grants
          grant-ref
          grant-attenuate
          grant-revoke!
          call-with-capability-grant
          handle-ref
          handle-live?
          handle-kind
          handle-revalidate
          handle-release!))
        (primitive-exports
         ((name grant-capability!)
          (primitive primitive-grant-capability!)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name current-grants)
          (primitive primitive-current-grants)
          (arity 0 0)
          (effects (capability))
          (capabilities ()))
         ((name grant-ref)
          (primitive primitive-grant-ref)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name grant-attenuate)
          (primitive primitive-grant-attenuate)
          (arity 2 2)
          (effects (capability))
          (capabilities ()))
         ((name grant-revoke!)
          (primitive primitive-grant-revoke!)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name call-with-capability-grant)
          (primitive primitive-call-with-capability-grant)
          (arity 2 2)
          (effects (capability))
          (capabilities ()))
         ((name handle-ref)
          (primitive primitive-handle-ref)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name handle-live?)
          (primitive primitive-handle-live?)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name handle-kind)
          (primitive primitive-handle-kind)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name handle-revalidate)
          (primitive primitive-handle-revalidate)
          (arity 1 1)
          (effects (capability))
          (capabilities ()))
         ((name handle-release!)
          (primitive primitive-handle-release!)
          (arity 1 1)
          (effects (capability))
          (capabilities ())))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
       (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent unicode-data))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "unicode-data.sld"))
        (api-version internal)
        (source-version (unicode 17 0 0))
        (realization shared-immutable-data)
        (exports
         (consent-unicode-data-version
          consent-unicode-data-metadata
          consent-unicode-alphabetic?
          consent-unicode-uppercase?
          consent-unicode-lowercase?
          consent-unicode-whitespace?
          consent-unicode-decimal-value
          consent-unicode-simple-uppercase
          consent-unicode-simple-lowercase
          consent-unicode-simple-foldcase
          consent-unicode-full-uppercase
          consent-unicode-full-lowercase
          consent-unicode-full-foldcase))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo-generated)
          (generated #t)
          (upstream-source-url
           "https://www.unicode.org/Public/17.0.0/ucd/")
          (upstream-license Unicode-3.0)
          (generator (path "tools/generate-unicode-data.el"))))
        (verification
         ((test-status
          (input-hashes deterministic-regeneration generator-unit
                        mutation-isolation portable-host-suite
                        compiled-host-suite))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent character))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "character.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-character?
          consent-character-code
          consent-character-equivalent?
          consent-scalar-value?
          consent-make-character
          consent-host-character->character
          consent-character->host-character))
        (dependencies
         ((library (scheme base))))
        (provenance
         ((origin repo)
          (representation owned-unicode-scalar-record)
          (boundary host-character-source-and-string-adapter)))
        (verification
         ((test-status
           (scalar-range host-boundary reader-writer portable-host-suite
                         compiled-host-suite))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent symbol))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "symbol.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-symbol?
          consent-symbol-name
          consent-symbol-equivalent?
          consent-symbol=?
          consent-symbol-table?
          consent-make-symbol-table
          consent-symbol-table-from-root
          consent-symbol-table-root
          consent-symbol-table-root-set!
          consent-intern-symbol
          consent-default-symbol-table))
        (dependencies
         ((library (scheme base))
          (library (data avl-tree))
          (library (data transient-map))))
        (provenance
         ((origin repo)
          (identity owned-portable-symbol)
          (storage transient-map-over-persistent-avl-root)))
        (verification
         ((test-status
           (interning shared-root-branches isolated-root-equivalence
                      root-installation portable-host-suite
                      compiled-host-suite))))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent symbol-boundary))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "symbol-boundary.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-host-symbol?
          consent-host-symbol-name
          consent-host-symbol-eq?
          consent-host-symbol-eqv?
          consent-host-symbol-equal?
          consent-host-symbol-memq
          consent-host-symbol-assq
          consent-host-symbol-member
          consent-host-symbol-assoc))
        (dependencies
         ((library (scheme base))
          (library (consent identity-map))
          (library (consent symbol))))
        (provenance
         ((origin repo)
          (boundary private-bootstrap-symbols)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent reader))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "reader.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (consent reader primitive))
        (exports
         (consent-read
          consent-read-datum
          consent-read-all
          consent-reader-source?
          consent-make-reader-source
          consent-reader-source-location-probe-count
          consent-read-from-string-at
          consent-read-datum-from-string-at
          consent-read-recover
          consent-read-recover-from-string-at
          consent-resync-to-next-form
          consent-recovery-result?
          consent-recovery-result-datums
          consent-recovery-result-diagnostics
          consent-recovery-result-spans
          consent-recovery-result-status
          consent-recovery-step?
          consent-recovery-step-status
          consent-recovery-step-datum
          consent-recovery-step-diagnostic
          consent-recovery-step-span
          consent-recovery-step-next
          consent-recovery-step-pending
          consent-read-eof
          consent-read-eof?
          consent-source-metadata-count
          consent-datum-source-metadata
          consent-source-metadata->record
          consent-datum-source
          consent-datum-source-set!
          consent-copy-datum-source!
          consent-validate-datum
          consent-datum->external
          consent-datum->external-bounded
          consent-number?
          consent-number-lexeme
          consent-number-exactness
          consent-number-radix
          consent-number-kind
          consent-number-value
          consent-number-owned-value
          consent-number-representation-snapshot
          consent-number-representation-snapshot-outer
          consent-outer-representation-kind
          consent-make-canonical-integer
          consent-make-canonical-decimal
          consent-make-canonical-rational
          consent-make-canonical-infnan
          consent-make-canonical-complex
          consent-number-zero?
          consent-number-negative?
          consent-number-abs
          consent-number->external
          consent-integer->radix-string
          consent-character?
          consent-character-code
          consent-make-character
          consent-make-record-type
          consent-record-type?
          consent-record-type-name
          consent-record-type-fields
          consent-make-record
          consent-record?
          consent-record-type
          consent-record-fields))
        (dependencies
         ((library (scheme base))
          (library (scheme char))
          (library (scheme inexact))
          (library (scheme write))
          (library (consent character))
          (library (consent datum))
          (library (consent identity-map))
          (library (consent numeric))
          (library (consent growable-vector))
          (library (consent symbol))
          (library (consent symbol-boundary))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (consent reader primitive))
        (owner consent-core)
        (provider host-adapter)
        (visibility internal-runtime)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id consent-reader))
        (implementation-resolver
         (module consent-base)
         (procedure consent-standard-primitive-implementation))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (consent-number-representation-snapshot-outer
          consent-outer-representation-kind))
        (primitive-exports
         ((name consent-number-representation-snapshot-outer)
          (primitive primitive-consent-number-representation-snapshot-outer)
          (arity 1 1)
          (effects (allocation))
          (capabilities ()))
         ((name consent-outer-representation-kind)
          (primitive primitive-consent-outer-representation-kind)
          (arity 2 2)
          (effects (pure))
          (capabilities ())))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent runtime))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "runtime.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-default-maximum-steps
          consent-default-maximum-value-nodes
          consent-default-maximum-source-metadata
          consent-default-maximum-host-callbacks
          consent-version-components
          consent-version
          consent-set-library-search-directories!
          consent-library-search-directory-list
          consent-set-library-system-directories!
          consent-library-system-directory-list
          consent-set-library-user-directories!
          consent-library-user-directory-list
          consent-register-embedded-source!
          consent-embedded-source-ref
          consent-register-native-library!
          consent-native-library-ref
          consent-native-library-documentation-ref
          consent-install-native-applier!
          consent-native-applier-ref
          consent-host-datum->consent-datum
          consent-make-empty-environment
          consent-unspecified
          consent-unspecified?
          make-undefined
          undefined?
          undefined
          make-cell
          cell?
          cell-value
          context-cell-set!
          make-environment
          environment?
          environment-frame
          set-environment-frame!
          environment-parent
          environment-imported-names
          set-environment-imported-names!
          environment-datum-heap
          context-use-environment-datum-heap!
          make-syntax-environment
          syntax-environment?
          syntax-environment-frame
          set-syntax-environment-frame!
          syntax-environment-parent
          syntax-environment-imported-names
          set-syntax-environment-imported-names!
          make-syntax-context
          syntax-context?
          syntax-context-id
          syntax-context-value-environment
          syntax-context-syntax-environment
          make-identifier
          identifier?
          identifier-name
          identifier-context
          make-formals
          formals?
          formals-required
          formals-rest
          make-documentation-metadata
          documentation-metadata?
          documentation-metadata-fields
          documentation-metadata-origins
          documentation-metadata-from-body
          documentation-body-result
          make-procedure
          consent-procedure?
          procedure-formals
          procedure-body
          procedure-environment
          procedure-syntax-environment
          procedure-documentation
          make-primitive-procedure
          consent-primitive-procedure?
          primitive-procedure-name
          primitive-procedure-function
          primitive-procedure-minimum-arity
          primitive-procedure-maximum-arity
          primitive-procedure-documentation
          set-primitive-procedure-documentation!
          make-consent-parameter
          consent-parameter?
          parameter-value
          set-parameter-value!
          parameter-converter
          make-multiple-values
          multiple-values?
          multiple-values-values
          make-continuation
          continuation?
          continuation-procedure
          continuation-dynamic-winds
          continuation-exception-handlers
          continuation-current-error
          make-dynamic-wind-frame
          dynamic-wind-frame?
          dynamic-wind-frame-before
          dynamic-wind-frame-after
          make-consent-error-object
          consent-error-object?
          consent-error-object-message
          consent-error-object-irritants
          make-consent-eof-object
          consent-eof-object?
          consent-eof-object
          make-consent-port
          consent-port?
          consent-port-medium
          consent-port-input?
          consent-port-output?
          consent-port-textual?
          consent-port-binary?
          consent-port-open?
          set-consent-port-open?!
          consent-port-source
          set-consent-port-source!
          consent-port-position
          set-consent-port-position!
          consent-port-contents
          set-consent-port-contents!
          consent-port-backing-domain
          consent-port-operations
          consent-port-grant
          consent-port-limits
          consent-port-handle
          consent-port-status
          set-consent-port-status!
          consent-port-path
          consent-port-counters
          set-consent-port-counters!
          make-environment-specifier
          environment-specifier?
          environment-specifier-environment
          environment-specifier-syntax-environment
          environment-specifier-immutable?
          make-string-output-port
          string-output-port?
          string-output-port-contents
          set-string-output-port-contents!
          make-sequence
          sequence?
          sequence-forms
          sequence-allow-definitions
          make-bounce
          bounce?
          bounce-expression
          bounce-environment
          bounce-syntax-environment
          bounce-continuation
          make-eval-context
          eval-context?
          context-steps
          set-context-steps!
          context-maximum-steps
          context-maximum-value-nodes
          context-maximum-source-metadata
          context-value-nodes
          set-context-value-nodes!
          context-interned-symbols
          set-context-interned-symbols!
          context-maximum-interned-symbols
          set-context-maximum-interned-symbols!
          context-symbol-table
          set-context-symbol-table!
          context-datum-heap
          set-context-datum-heap!
          context-host-callbacks
          set-context-host-callbacks!
          context-maximum-host-callbacks
          context-event-count
          set-context-event-count!
          context-maximum-events
          context-maximum-event-nodes
          set-context-maximum-steps!
          set-context-maximum-value-nodes!
          set-context-maximum-source-metadata!
          set-context-maximum-host-callbacks!
          set-context-maximum-events!
          context-output-bytes
          set-context-output-bytes!
          context-maximum-output-bytes
          set-context-maximum-output-bytes!
          context-maximum-wall-time-ms
          set-context-maximum-wall-time-ms!
          context-wall-clock
          set-context-wall-clock!
          context-wall-start
          set-context-wall-start!
          context-exhaustion-reason
          set-context-exhaustion-reason!
          context-syntax-environment
          set-context-syntax-environment!
          context-libraries
          set-context-libraries!
          context-native-binding-cache
          set-context-native-binding-cache!
          context-source-copy-count
          context-source-copy-set-fresh!
          context-source-copy-set!
          context-source-copy-source-ref
          context-copy-datum-source!
          context-include-paths
          context-include-directory
          set-context-include-directory!
          context-file-paths
          context-internal-libraries-allowed?
          context-docstring-retention
          context-boundary-contract-checking
          context-policy-actions
          context-policy-confirmation-function
          context-capability-grants
          set-context-capability-grants!
          context-active-capability-grants
          set-context-active-capability-grants!
          context-audit-events
          set-context-audit-events!
          context-current-input-port
          set-context-current-input-port!
          context-current-output-port
          set-context-current-output-port!
          context-current-error-port
          set-context-current-error-port!
          context-current-error
          set-context-current-error!
          context-session-id
          context-request-id
          context-request
          context-focus
          context-region-context
          context-buffer-context
          context-project-context
          context-conversation-summary
          context-command-line
          context-interaction-environment
          set-context-interaction-environment!
          context-base-syntax-installed
          set-context-base-syntax-installed!
          context-next-syntax-id
          set-context-next-syntax-id!
          context-exception-handlers
          set-context-exception-handlers!
          context-dynamic-winds
          set-context-dynamic-winds!
          make-syntax-transformer
          syntax-transformer?
          syntax-transformer-ellipsis
          syntax-transformer-literals
          syntax-transformer-rules
          syntax-transformer-value-environment
          syntax-transformer-syntax-environment
          make-pattern-binding
          pattern-binding?
          pattern-binding-depth
          set-pattern-binding-depth!
          pattern-binding-captures
          set-pattern-binding-captures!
          pattern-binding-empty-prefixes
          set-pattern-binding-empty-prefixes!
          make-syntax-scope
          syntax-scope?
          syntax-scope-forms
          syntax-scope-syntax-environment
          make-library-binding
          library-binding?
          library-binding-name
          library-binding-kind
          library-binding-object
          library-binding-library-key
          make-library
          library?
          library-name
          library-key
          library-exports
          library-value-environment
          library-syntax-environment
          option-ref
          eval-error
          budget-error
          normalize-include-directory
          path-absolute?
          path-join
          path-normalize
          normalize-include-paths
          context-reader-options
          authorize-file-capability
          file-authorization-path
          audit-file-capability-result!
          authorize-code-loading
          audit-code-loading-result!
          process-capability-effect
          process-capability-policy-category
          process-capability-request
          process-capability-handle
          process-port-capability-handle
          authorize-process-capability
          authorize-process-environment-capability
          audit-process-capability-result!
          network-capability-effect
          network-capability-request
          network-capability-handle
          network-port-capability-handle
          authorize-network-capability
          audit-network-capability-result!
          authorize-clock-capability
          audit-clock-capability-result!
          new-eval-context
          record-audit-event!
          record-context-event!
          note-step!
          note-host-callback!
          note-interned-symbol!
          note-value-allocation!
          value-node-count
          charge-value-allocation!
          charge-string-allocation!
          charge-bytevector-allocation!
          charge-vector-allocation!
          charge-list-allocation!
          charge-literal!
          check-value-budget
          note-output!
          check-wall-time!
          budget-spec-ref
          budget-spec-dimensions
          budget-ceiling-snapshot
          budget-tighten!
          budget-restore!
          values-list
          single-value
          identity-continuation
          continue
          continuation-value
          proper-list-elements
          second
          third
          fourth
          expect-symbol
          identifier-datum?
          identifier-datum-name
          identifier-key
          identifier-named?
          expect-identifier-key
          frame-cell
          environment-cell
          environment-cell-imported?
          current-environment-imported?
          environment-define!
          environment-set!
          environment-define-or-set!
          environment-ref
          environment-cell-for-identifier
          environment-ref-identifier
          environment-set-identifier!
          ensure-distinct-names
          parse-formals))
        (dependencies
         ((library (scheme base))
          (library (consent character))
          (library (consent datum))
          (library (consent identity-map))
          (library (consent reader))
          (library (consent symbol))
          (library (consent symbol-boundary))
          (library (consent version))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent base))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "base.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (scheme-base-library-key
          consent-install-base-backend!
          base-primitive-registry
          base-prelude-forms
          base-syntax-forms
          consent-base-prelude-load-paths
          consent-base-syntax-load-paths
          read-port-string
          read-all-datums
          resolve-source-text
          resolve-source-entry
          define-primitive!
          ensure-base-syntax!
          consent-make-base-environment
          consent-base-primitive-names
          consent-base-primitive-specs
          consent-base-prelude-binding-names
          consent-base-prelude-binding-specs
          consent-base-binding-specs
          consent-primitive-manifest-binding-specs))
        (dependencies
         ((library (scheme base))
          (library (scheme char))
          (library (scheme inexact))
          (library (scheme write))
          (library (consent reader))
          (library (consent symbol-boundary))
          (library (consent runtime))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent library))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "library.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-standard-source-library-specs
          consent-stdlib-source-library-specs
          consent-data-source-library-specs
          consent-runtime-source-files
          consent-library-catalog-entries
          consent-library-catalog-entry
          consent-library-catalog-search
          consent-library-catalog-runtime-source-files
          consent-library-catalog-sources
          consent-library-catalog-diagnostics
          consent-library-catalog-add-manifest!
          consent-library-catalog-remove-manifest!
          consent-library-catalog-add-root!
          consent-library-catalog-remove-root!
          consent-library-catalog-refresh!
          consent-library-resolve-record
          consent-library-load-record
          consent-library-solve-dependencies
          consent-library-paths
          consent-library-conflicts
          consent-library-snapshot
          consent-srfi-library-name
          consent-srfi-library-aliases
          consent-vendored-srfi-entry
          consent-vendored-srfi-record
          consent-install-library-backend!
          consent-native-argument-value
          consent-runtime-datum->native-datum
          consent-call-native-library
          consent-apply-callable
          import-form?
          define-library-form?
          eval-import
          eval-define-library
          resolve-library
          library-available?
          library-name-key
          library-registry-ref
          library-registry-set!
          export-specs
          ensure-compatible-import-bindings
          path-policy-allows-file?
          path-directory
          read-file-string
          with-include-directory
          form-named?))
        (dependencies
         ((library (scheme base))
          (library (scheme char))
          (library (scheme file))
          (library (consent character))
          (library (consent datum))
          (library (consent identity-map))
          (library (consent reader))
          (library (consent symbol))
          (library (consent symbol-boundary))
          (library (consent runtime))
          (library (consent base))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent macro))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "macro.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-expand
          consent-expand-source
          consent-macroexpand
          consent-macroexpand-1
          consent-macroexpand-library
          consent-macro-binding-info
          consent-syntax-source
          definition-form?
          define-values-form?
          begin-form?
          make-lambda-expression
          parse-definition
          parse-define-values
          formals-names
          define-values-bound-names
          record-definition-form?
          body-definition-form?
          tagged-list?
          single-argument-syntax
          syntax-error-form?
          syntax-error-message
          raise-syntax-error
          make-empty-syntax-environment
          syntax-environment-ref
          syntax-environment-define!
          with-syntax-environment
          special-operator-active?
          syntax-binding-for-operator
          proper-list-elements/maybe
          append-tail
          syntax-definition-form?
          eval-define-syntax
          make-local-syntax-scope
          expand-expression
          expand-expression/fully
          expand-sequence-forms))
        (dependencies
         ((library (scheme base))
          (library (consent reader))
          (library (consent symbol))
          (library (consent symbol-boundary))
          (library (consent runtime))
          (library (consent base))
          (library (consent library))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent result))
        (owner consent-core)
        (provider repo-source)
        (visibility public-consent)
        (layer api)
        (source-kind source-library)
        (source (path "result.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (result-field
          value->result-datum
          strip-identifiers
          budget-result-field
          ok-result-datum
          debugger-condition-datum
          debugger-exception-datum
          debugger-field-values
          debugger-field-value
          debugger-expect-condition
          debugger-restart-id-name
          debugger-default-restarts
          condition-result-datum
          budget-exhausted-condition?
          consent-result->external
          consent-value->external))
        (dependencies
         ((library (scheme base))
          (library (consent datum))
          (library (consent identity-map))
          (library (consent reader))
          (library (consent symbol))
          (library (consent symbol-boundary))
          (library (consent runtime))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent interpreter))
        (owner consent-core)
        (provider repo-source)
        (visibility internal-runtime)
        (layer runtime)
        (source-kind source-library)
        (source (path "interpreter.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-eval
          consent-eval-source
          consent-eval-string
          consent-expand
          consent-expand-source
          consent-eval-result
          consent-eval-source-result
          consent-make-interaction-context
          consent-interaction-context?
          consent-interaction-context-session-id
          consent-interaction-program-output
          consent-interaction-eval-form
          consent-interaction-program-input-port
          consent-interaction-seed-program-input!
          consent-interaction-program-input-remainder
          consent-repl-session-manager
          consent-repl-seed-initial-session!
          consent-session-manager-current-context
          consent-program-input-from-string
          consent-program-input-from-bytevector
          consent-make-empty-environment
          consent-make-base-environment
          consent-base-primitive-names
          consent-base-primitive-specs
          consent-base-prelude-binding-names
          consent-base-prelude-binding-specs
          consent-base-binding-specs
          consent-standard-source-library-specs
          consent-stdlib-source-library-specs
          consent-data-source-library-specs
          consent-primitive-manifest-binding-specs
          consent-result->external
          consent-value->external
          consent-unspecified
          consent-unspecified?
          consent-procedure?
          consent-primitive-procedure?))
        (dependencies
         ((library (scheme base))
          (library (scheme char))
          (library (scheme file))
          (library (scheme inexact))
          (library (scheme process-context))
          (library (scheme read))
          (library (scheme write))
          (library (consent character))
          (library (consent datum))
          (library (consent identity-map))
          (library (consent numeric))
          (library (consent reader))
          (library (consent symbol))
          (library (consent symbol-boundary))
          (library (consent runtime))
          (library (consent result))
          (library (consent base))
          (library (consent library))
          (library (consent macro))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent eval))
        (owner consent-core)
        (provider repo-source)
        (visibility public-consent)
        (layer api)
        (source-kind facade)
        (source (path "eval.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization shim)
        (exports
         (consent-eval
          consent-eval-source
          consent-eval-string
          consent-expand
          consent-expand-source
          consent-eval-result
          consent-eval-source-result
          consent-make-interaction-context
          consent-interaction-context?
          consent-interaction-context-session-id
          consent-interaction-program-output
          consent-interaction-eval-form
          consent-interaction-program-input-port
          consent-interaction-seed-program-input!
          consent-interaction-program-input-remainder
          consent-repl-session-manager
          consent-repl-seed-initial-session!
          consent-session-manager-current-context
          consent-program-input-from-string
          consent-program-input-from-bytevector
          consent-make-empty-environment
          consent-make-base-environment
          consent-base-primitive-names
          consent-base-primitive-specs
          consent-base-prelude-binding-names
          consent-base-prelude-binding-specs
          consent-base-binding-specs
          consent-standard-source-library-specs
          consent-stdlib-source-library-specs
          consent-data-source-library-specs
          consent-primitive-manifest-binding-specs
          consent-result->external
          consent-value->external
          consent-unspecified
          consent-unspecified?
          consent-procedure?
          consent-primitive-procedure?))
        (dependencies
         ((library (consent interpreter))))
        (provenance ((origin repo)))
        (status documented-unavailable-on-some-hosts)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (consent version))
        (owner consent-core)
        (provider repo-source)
        (visibility public-consent)
        (layer api)
        (source-kind source-library)
        (source (path "version.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (consent-version-datum))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))))

    (define (consent-library-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "Consent core or standard library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest consent-library-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cadr (assq 'name (cdr (car rest)))) library) (car rest))
         (else (loop (cdr rest))))))))
