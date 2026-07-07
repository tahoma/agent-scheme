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
    (define cli-library-manifest
      '(((library . (cli manifest))
         (visibility . public)
         (layer . manifest)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "manifest.sld")
         (implementation-library . (cli manifest))
         (exports . (cli-library-manifest cli-library-manifest-ref))
         (owner . cli)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (cli process-host))
         (visibility . host-adapter)
         (layer . host-adapter)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "process-host.sld")
         (implementation-library . (cli process-host))
         (exports . (cli-host-available? cli-host-run))
         (owner . cli)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme file)
                          (stdlib generator)
                          (cli process-host primitive))))
        ((library . (cli process-host primitive))
         (visibility . internal-runtime)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . cli-process-host)
         (exports . (primitive-cli-host-available? primitive-cli-host-run))
         (owner . cli)
         (provider . host-adapter)
         (dependencies . ()))))

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
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
