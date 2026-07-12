;;; Portable development library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This manifest records reusable, portable development facilities. Project
;;; test programs and fixtures remain outside the library catalog.

(define-library (development manifest)
  (export development-library-manifest
          development-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe reusable portable development libraries.
    (define development-library-manifest
      '((manifest-entry
         (schema-version 1)
         (kind library)
         (name (development manifest))
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
          (development-library-manifest
           development-library-manifest-ref))
         (dependencies
          ((library (scheme base))))
         (provenance ((origin repo)))
         (status implemented)
         (canonical #t))
        (manifest-entry
         (schema-version 1)
         (kind library)
         (name (development testing harness))
         (owner consent-core)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "testing/harness.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (consent-test-run
           consent-test-check
           consent-test-runner-summary
           consent-test-runner-failed?))
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
         (name (development testing registry))
         (owner consent-core)
         (provider repo-source)
         (visibility public)
         (layer library)
         (source-kind source-library)
         (source (path "testing/registry.sld"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports
          (consent-test-case
           consent-test-register!
           consent-test-registry-clear!
           consent-test-registry
           consent-test-case-name
           consent-test-case-tags
           consent-test-case-source-file
           consent-test-case-source-line
           consent-test-select-all
           consent-test-select-name
           consent-test-select-tag
           consent-test-select-and
           consent-test-select-or
           consent-test-select-not
           consent-test-clock
           consent-test-diagnostic-hook
           consent-test-run-registered
           consent-test-rerun-failed
           consent-test-report-failed-names))
         (dependencies
          ((library (scheme base))
           (library (scheme write))
           (library (development testing harness))
           (library (stdlib testing))))
         (provenance ((origin repo)))
         (status implemented)
         (canonical #t))))

    (define (development-library-manifest-ref library)
      "Return manifest metadata for LIBRARY, or false when absent."
      #((parameters
         (library (type list)
          (description "Development library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or false."))
        (effects pure))
      (let loop ((rest development-library-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cadr (assq 'name (cdr (car rest)))) library) (car rest))
         (else (loop (cdr rest))))))))
