;;; Portable CLI library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This load-light manifest records the CLI-facing host adapter libraries.
;;; It keeps process-spawn primitive backing discoverable as metadata without
;;; making that primitive backing an ordinary user import.

(define-library (cli manifest)
  (export cli-library-manifest cli-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe CLI-facing libraries and primitive overlays.
    (define cli-library-manifest
      '((manifest-entry
        (schema-version 1)
        (kind library)
        (name (cli manifest))
        (owner cli)
        (provider repo-source)
        (visibility public)
        (layer manifest)
        (source-kind source-library)
        (source (path "manifest.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports (cli-library-manifest cli-library-manifest-ref))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (cli process-host))
        (owner cli)
        (provider repo-source)
        (visibility host-adapter)
        (layer host-adapter)
        (source-kind source-library)
        (source (path "process-host.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports (cli-host-available? cli-host-run))
        (dependencies
         ((library (scheme base)) (library (scheme file)) (library (stdlib generator))
                                (library (cli process-host primitive))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (cli process-host primitive))
        (owner cli)
        (provider host-adapter)
        (visibility internal-runtime)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id cli-process-host))
        (implementation-resolver
         (module consent-capability)
         (procedure consent-cli-process-host-primitive-implementation))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports (primitive-cli-host-available? primitive-cli-host-run))
        (primitive-exports
         ((name primitive-cli-host-available?)
          (primitive primitive-cli-host-available?)
          (arity 0 0)
          (effects (host-process))
          (capabilities (process-execution)))
         ((name primitive-cli-host-run)
          (primitive primitive-cli-host-run)
          (arity 6 6)
          (effects (host-process))
          (capabilities (process-execution))))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))))

    (define (cli-library-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "CLI library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest cli-library-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cadr (assq 'name (cdr (car rest)))) library) (car rest))
         (else (loop (cdr rest))))))))
