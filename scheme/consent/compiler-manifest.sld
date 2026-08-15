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
           (agent models openai-codec)
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
           (agent memory-query)
           (agent memory)
           (agent plan)
           (agent redaction-kernel)
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
           (consent datum)
           (consent identity-map)
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
         ;; Borrowed-host images register this fail-closed root subset as
         ;; compiled realizations of the same portable source libraries. The
         ;; compiler plan validates that each name is reachable and resolves
         ;; its source unit; backends must not maintain parallel implementation
         ;; or registration inventories. The Consent core entries preserve one
         ;; directly linked bootstrap ABI, including its character, compound
         ;; datum, numeric, reader, runtime, and symbol record owners. Their
         ;; boundary rejects before conversion would allocate an unclassified
         ;; borrowed mirror or callback shim rather than assuming that every
         ;; core export may borrow one. The agent entries have audited,
         ;; call-scoped boundaries whose exact procedure and constant
         ;; inventories are validated before registration.
         ;;
         ;; Every other project root remains compiled and linked, but is not
         ;; registered for interpreted imports. Its canonical source library is
         ;; resolved instead. This includes any library whose exports can retain
         ;; compounds in a closure, record, parameter, or module state. That
         ;; routing prevents borrowed-host containers from becoming a durable
         ;; second heap while #120 supplies native lowering over Consent-owned
         ;; base primitives. The OpenAI codec, memory-query kernel, and
         ;; redaction scanner are stateless call-scoped transforms with no
         ;; callback invocation or durable storage surface. Memory-key remains
         ;; a compiled dependency inside memory-query, while the persistent
         ;; memory facade realizes that same source directly. The transient
         ;; overlay, identity table, and lean identity-map specialization
         ;; likewise remain ordinary compiled dependencies because their
         ;; private records never cross the core interface.
         (native-libraries
          ((agent task)
           (agent transcript)
           (agent models openai-codec)
           (agent context)
           (agent memory-query)
           (agent redaction-kernel)
           (consent character)
           (consent datum)
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
           (consent version)))
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
