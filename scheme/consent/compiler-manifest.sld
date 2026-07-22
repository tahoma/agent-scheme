;;; Canonical compiler image manifests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (consent compiler-manifest)
  (export consent-compiler-images consent-compiler-image-ref)
  (import (scheme base))
  (begin
    ;; Compiler images declare product roots once. Collection manifests own
    ;; source paths and dependency edges; `(consent compiler-plan)' resolves
    ;; these roots into the ordered module graph consumed by every backend.
    (define consent-compiler-images
      '((compiler-image
         (schema-version 1)
         (name consent-runtime)
         ;; Borrowed R7RS compiler hosts realize these namespaces themselves.
         ;; A future native image omits or narrows this declaration so its plan
         ;; selects Consent-owned standard-library and primitive realizations.
         (external-library-prefixes (scheme srfi))
         (roots
          ((data avl-tree)
           (data transient-map)
           (agent task)
           (agent transcript)
           (agent models openai)
           (agent registry)
           (agent proposal)
           (agent runner)
           (agent prompt)
           (agent generated-source)
           (agent approval)
           (agent context)
           (agent helper)
           (agent job)
           (agent memory)
           (agent plan)
           (agent redaction)
           (agent session)
           (stdlib and-let-star)
           (stdlib list)
           (stdlib generator)
           (stdlib comparator)
           (stdlib receive)
           (stdlib assume)
           (stdlib rbtree)
           (stdlib mapping)
           (stdlib json)
           (data mapping avl)
           (consent character)
           (consent symbol)
           (consent symbol-boundary)
           (consent base)
           (consent eval)
           (consent interpreter)
           (consent library)
           (consent macro)
           (consent numeric)
           (consent reader)
           (consent result)
           (consent runtime)
           (consent version)
           (cli process-host)
           (cli native-cli)
           (cli repl-chrome)
           (cli repl-shell)
           (cli script)))
         ;; Borrowed-host images register this root subset as compiled
         ;; realizations of the same portable source libraries. The compiler
         ;; plan validates that each name is reachable and resolves its source
         ;; unit; backends must not maintain parallel implementation or
         ;; registration inventories. In particular, `(consent character)' and
         ;; `(consent symbol)' are semantic value owners, never adapters over
         ;; host values. They are registered in borrowed-host images so
         ;; interpreted imports share the compiled core's character and symbol
         ;; record types and its single symbol table. The transient overlay
         ;; remains an ordinary compiled dependency; interpreted imports can
         ;; evaluate it from source because its private records never cross the
         ;; core interface. These wrappers are bootstrap ABI only; a native
         ;; Consent image links callers and callees directly.
         (native-libraries
          ((data avl-tree)
           (agent task)
           (agent transcript)
           (agent models openai)
           (agent registry)
           (agent proposal)
           (agent runner)
           (agent prompt)
           (agent generated-source)
           (agent approval)
           (agent context)
           (agent helper)
           (agent job)
           (agent memory)
           (agent plan)
           (agent redaction)
           (agent session)
           (consent character)
           (consent symbol)
           (consent symbol-boundary)
           (consent base)
           (consent eval)
           (consent interpreter)
           (consent library)
           (consent macro)
           (consent numeric)
           (consent reader)
           (consent runtime)
           (consent version)
           (cli native-cli)
           (cli process-host)
           (cli repl-chrome)
           (cli repl-shell)
           (cli script)))
         (generated-units
          ((compiler-unit
            (name (consent embedded-source))
            (source "consent/embedded-source.sld")
            (dependencies ((consent runtime)))))))))

    (define (consent-compiler-image-ref name)
      "Return the canonical compiler-image manifest named NAME, or #f."
      #((parameters
         (name (type symbol) (description "Compiler image name.")))
        (returns (type (or list boolean))
         (description "Matching compiler-image manifest, or #f."))
        (effects pure))
      (let loop ((rest consent-compiler-images))
        (cond
         ((null? rest) #f)
         ((eq? (cadr (assq 'name (cdr (car rest)))) name) (car rest))
         (else (loop (cdr rest))))))))
