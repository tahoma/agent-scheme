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
        (exports
         (cli-library-manifest
          cli-library-manifest-ref))
        (dependencies
         ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (cli native-cli))
        (owner cli)
        (provider repo-source)
        (visibility internal-runtime)
        (layer cli)
        (source-kind source-library)
        (source (path "native-cli.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (cli-native-cli-execute
          cli-native-cli-parse-arguments
          cli-native-cli-main))
        (dependencies
         ((library (scheme base))
          (library (scheme write))
          (library (scheme read))
          (library (scheme file))
          (library (scheme process-context))
          (library (cli process-host))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (cli repl-chrome))
        (owner cli)
        (provider repo-source)
        (visibility internal-runtime)
        (layer cli)
        (source-kind source-library)
        (source (path "repl-chrome.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (cli-repl-chrome-lookup
          cli-repl-chrome-names
          cli-repl-chrome-default-name
          cli-repl-chrome-input-echoed?
          cli-repl-chrome-output-ordinal
          cli-repl-chrome-output-formatter
          cli-repl-chrome-paint
          cli-repl-chrome-color?))
        (dependencies
         ((library (scheme base))
          (library (scheme write))
          (library (consent reader))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (cli repl-shell))
        (owner cli)
        (provider repo-source)
        (visibility internal-runtime)
        (layer cli)
        (source-kind source-library)
        (source (path "repl-shell.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (cli-repl-drive
          cli-repl-records-from-string
          cli-repl-records-from-datum-stream
          cli-repl-submissions-from-records
          cli-repl-replay-input
          cli-repl-replay-records
          cli-repl-replay-report
          cli-repl-run
          cli-repl-parse-options
          cli-repl-rendered-from-string
          cli-repl-capture-from-string
          cli-repl-replay-main
          cli-repl-main))
        (dependencies
         ((library (scheme base))
          (library (scheme case-lambda))
          (library (scheme write))
          (library (scheme read))
          (library (scheme file))
          (library (scheme process-context))
          (library (consent eval))
          (library (consent reader))
          (library (consent result))
          (library (stdlib generator))
          (library (stdlib receive))
          (library (consent library))
          (library (cli repl-chrome))))
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (cli script))
        (owner cli)
        (provider repo-source)
        (visibility internal-runtime)
        (layer cli)
        (source-kind source-library)
        (source (path "script.sld"))
        (api-version internal)
        (source-version unknown)
        (realization portable-source)
        (exports
         (cli-script-shebang-line?
          cli-script-strip-shebang
          cli-script-source-from-file
          cli-script-run-file
          cli-script-host-run-options
          cli-script-host-run-file))
        (dependencies
         ((library (scheme base))
          (library (scheme case-lambda))
          (library (scheme file))
          (library (consent eval))
          (library (consent reader))
          (library (stdlib generator))))
        (provenance ((origin repo)))
        (status internal)
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
        (exports
         (cli-host-available?
          cli-host-run))
        (dependencies
         ((library (scheme base))
          (library (scheme file))
          (library (stdlib generator))
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
        (exports
         (primitive-cli-host-available?
          primitive-cli-host-run))
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
