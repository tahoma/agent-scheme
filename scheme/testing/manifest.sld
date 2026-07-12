;;; Portable testing library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This manifest records reusable, portable testing facilities. Project
;;; test programs and fixtures remain outside the library catalog.

(define-library (testing manifest)
  (export testing-library-manifest
          testing-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe reusable portable testing libraries.
    (define testing-library-manifest
      '((manifest-entry
         (schema-version 1)
         (kind library)
         (name (testing manifest))
         (owner consent-core)
         (provider repo-source)
         (visibility public)
         (layer manifest)
         (source-kind source-library)
         (source (path "manifest.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (testing-library-manifest
           testing-library-manifest-ref))
         (dependencies
          ((library (scheme base))))
         (provenance ((origin repo)))
         (status implemented)
         (canonical #t))
        (manifest-entry
         (schema-version 1)
         (kind library)
         (name (testing harness))
         (owner consent-core)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "harness.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (testing-harness-run
           testing-harness-check
           testing-harness-runner-summary
           testing-harness-runner-failed?))
         (dependencies
          ((library (scheme base))
           (library (scheme write))
           (library (stdlib testing))
           (library (stdlib lightweight-testing))))
         (provenance ((origin repo)))
         (status implemented)
         (canonical #t))
        (manifest-entry
         (schema-version 1)
         (kind library)
         (name (testing registry))
         (owner consent-core)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "registry.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (testing-registry-case
           testing-registry-register!
           testing-registry-clear!
           testing-registry-cases
           testing-registry-case-name
           testing-registry-case-tags
           testing-registry-case-source-file
           testing-registry-case-source-line
           testing-registry-select-all
           testing-registry-select-name
           testing-registry-select-tag
           testing-registry-select-and
           testing-registry-select-or
           testing-registry-select-not
           testing-registry-clock
           testing-registry-diagnostic-hook
           testing-registry-run-registered
           testing-registry-rerun-failed
           testing-registry-report-failed-names))
         (dependencies
          ((library (scheme base))
           (library (scheme write))
           (library (testing harness))
           (library (stdlib testing))))
         (provenance ((origin repo)))
         (status implemented)
         (canonical #t))))

    (define (testing-library-manifest-ref library)
      "Return manifest metadata for LIBRARY, or false when absent."
      #((parameters
         (library (type list)
          (description "Testing library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or false."))
        (effects pure))
      (let loop ((rest testing-library-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cadr (assq 'name (cdr (car rest)))) library) (car rest))
         (else (loop (cdr rest))))))))
