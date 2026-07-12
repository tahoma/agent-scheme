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
