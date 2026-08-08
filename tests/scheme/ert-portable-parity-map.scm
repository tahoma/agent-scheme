;;; ERT-to-portable semantic test ownership map.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;; This is project test data, not a runtime library. Paired surfaces name the
;; canonical portable programs for an ERT implementation/bootstrap surface.
;; Mixed surfaces additionally partition every ERT case into an exact portable
;; case or an Emacs-only boundary.

(ert-portable-parity-map
 (version 1)
 (surfaces
  ((surface
    (ert-file "tests/consent-base-module-test.el")
    (ownership dual-host-module-boundary)
    (portable-files ("tests/scheme/consent-module-boundary-test.scm")))
   (surface
    (ert-file "tests/consent-capability-environment-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-ci-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason ci-workflow-and-log-tooling))
   (surface
    (ert-file "tests/consent-compile-elisp-docstring-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason emacs-lisp-source-policy))
   (surface
    (ert-file "tests/consent-compile-portable-test.el")
    (ownership build-host-adapter)
    (portable-files ())
    (boundary-reason external-compiler-packaging))
   (surface
    (ert-file "tests/consent-compile-test.el")
    (ownership emacs-host-adapter)
    (portable-files ())
    (boundary-reason emacs-compilation-buffer-and-process-policy))
   (surface
    (ert-file "tests/consent-control-loop-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-docstring-metadata-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-feature-reflection-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-helper-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-host-adapter-fixture-test.el")
    (ownership emacs-host-adapter)
    (portable-files ())
    (boundary-reason emacs-capability-manifest-contract))
   (surface
    (ert-file "tests/consent-interpreter-module-test.el")
    (ownership dual-host-module-boundary)
    (portable-files ("tests/scheme/consent-module-boundary-test.scm")))
   (surface
    (ert-file "tests/consent-library-module-test.el")
    (ownership dual-host-module-boundary)
    (portable-files ("tests/scheme/consent-module-boundary-test.scm")))
   (surface
    (ert-file "tests/consent-macro-module-test.el")
    (ownership dual-host-module-boundary)
    (portable-files ("tests/scheme/consent-module-boundary-test.scm")))
   (surface
    (ert-file "tests/consent-native-cli-daemon-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-oracle-test.el")
    (ownership build-host-adapter)
    (portable-files ("tests/scheme/consent-fixture-test.scm"))
    (boundary-reason external-reference-process-orchestration))
   (surface
    (ert-file "tests/consent-policy-test.el")
    (ownership emacs-host-adapter)
    (portable-files ("tests/scheme/consent-eval-test.scm"))
    (boundary-reason emacs-policy-audit-and-persistence))
   (surface
    (ert-file "tests/consent-repl-agent-quickstart-doc-test.el")
    (ownership documentation-and-emacs-adapter)
    (portable-files
     ("tests/scheme/consent-eval-test.scm"
      "tests/scheme/consent-models-openai-test.scm"))
    (boundary-reason documentation-contract-and-emacs-fake-transport))
   (surface
    (ert-file "tests/consent-repl-comint-test.el")
    (ownership emacs-host-adapter)
    (portable-files ("tests/scheme/consent-repl-test.scm"))
    (boundary-reason emacs-comint-buffer-ui))
   (surface
    (ert-file "tests/consent-repl-stream-test.el")
    (ownership dual-host)
    (portable-files ("tests/scheme/consent-repl-test.scm")))
   (surface
    (ert-file "tests/consent-scheme-documentation-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason checked-in-source-documentation-policy))
   (surface
    (ert-file "tests/consent-scheme-eval-test.el")
    (ownership repository-policy)
    (portable-files ("tests/scheme/consent-eval-test.scm"))
    (boundary-reason portable-bootstrap-source-constraint))
   (surface
    (ert-file "tests/consent-scheme-module-boundary-test.el")
    (ownership build-host-adapter)
    (portable-files ("tests/scheme/consent-module-boundary-test.scm"))
    (boundary-reason out-of-tree-chibi-process-check))
   (surface
   (ert-file "tests/consent-scheme-module-ownership-test.el")
    (ownership repository-policy)
    (portable-files ("tests/scheme/consent-module-boundary-test.scm"))
    (boundary-reason checked-in-module-source-policy))
   (surface
    (ert-file "tests/consent-scheme-numeric-test.el")
    (ownership repository-policy)
    (portable-files
     ("tests/scheme/consent-numeric-generated-test.scm"
      "tests/scheme/consent-fixture-test.scm"))
    (boundary-reason checked-in-performance-sensitive-source-policy))
   (surface
    (ert-file "tests/consent-skill-test.el")
    (ownership emacs-host-adapter)
    (portable-files ("tests/scheme/consent-eval-test.scm"))
    (boundary-reason emacs-filesystem-policy-and-audit))
   (surface
    (ert-file "tests/consent-smoke-test.el")
    (ownership ert-runner-smoke)
    (portable-files
     ("tests/scheme/testing-harness-test.scm"
      "tests/scheme/testing-runner-test.scm"))
    (boundary-reason emacs-test-runner-discovery))
   (surface
    (ert-file "tests/consent-test-case-parity-audit-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason ert-to-portable-map-enforcement))
   (surface
   (ert-file "tests/consent-test-options-test.el")
    (ownership emacs-host-adapter)
    (portable-files ())
    (boundary-reason emacs-evaluator-option-injection))
   (surface
    (ert-file "tests/consent-unicode-data-generator-test.el")
    (ownership generator-tooling)
    (portable-files ("tests/scheme/consent-character-test.scm"))
    (boundary-reason pinned-input-and-generation-host-tooling))
   (surface
    (ert-file "tests/consent-vcs-doc-test.el")
    (ownership repository-policy)
    (portable-files ())
    (boundary-reason documentation-contract))
   (surface
    (ert-file "tests/consent-agent-io-test.el")
    (ownership dual-core)
    (portable-files ("tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-agent-prompt-test.el")
    (ownership portable-peer)
    (portable-files ("tests/scheme/consent-agent-prompt-test.scm")))
   (surface
    (ert-file "tests/consent-agent-proposal-test.el")
    (ownership portable-peer)
    (portable-files ("tests/scheme/consent-agent-proposal-test.scm")))
   (surface
    (ert-file "tests/consent-agent-registry-test.el")
    (ownership portable-peer)
    (portable-files ("tests/scheme/consent-agent-registry-test.scm")))
   (surface
    (ert-file "tests/consent-agent-reliability-test.el")
    (ownership portable-peer)
    (portable-files ("tests/scheme/consent-agent-reliability-test.scm")))
   (surface
    (ert-file "tests/consent-agent-runner-test.el")
    (ownership portable-peer)
    (portable-files ("tests/scheme/consent-agent-runner-test.scm")))
   (surface
    (ert-file "tests/consent-approval-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-module-boundary-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-approval-test-emacs-adapter-has-no-pure-store-twin
       "tests/scheme/consent-module-boundary-test.scm"
       approval-boundary-request-status)
      (consent-approval-test-request-status-and-audit
       "tests/scheme/consent-eval-test.scm" agent-approval-request-status)
      (consent-approval-test-yield-pending-records
       "tests/scheme/consent-eval-test.scm" agent-approval-yield-pending)
      (consent-approval-test-host-decisions-update-status-and-audit
       "tests/scheme/consent-module-boundary-test.scm"
       approval-boundary-resolved-status)
      (consent-approval-test-scheme-self-approval-denied-by-default
       "tests/scheme/consent-eval-test.scm"
       agent-approval-self-approval-denied)))
    (emacs-only-cases
     ((consent-approval-test-session-approval-access-is-scoped
       emacs-session-adapter)
      (consent-approval-test-policy-confirmation-creates-record
       emacs-policy-confirmation)
      (consent-approval-test-native-buffer-renders-records
       emacs-buffer-ui))))
   (surface
    (ert-file "tests/consent-base-test.el")
    (ownership dual-core)
    (portable-files
     ("tests/scheme/consent-eval-test.scm"
      "tests/scheme/consent-fixture-test.scm")))
   (surface
    (ert-file "tests/consent-budget-test.el")
    (ownership dual-core)
    (portable-files ("tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-capability-test.el")
    (ownership dual-core-and-emacs-adapter)
    (portable-files ("tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-conformance-test.el")
    (ownership shared-corpus)
    (portable-files ("tests/scheme/consent-fixture-test.scm")))
   (surface
    (ert-file "tests/consent-context-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-context-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-context-test-request-and-conversation-options
       "tests/scheme/consent-eval-test.scm"
       agent-context-portable-request-summary-focus-and-yield)
      (consent-context-test-missing-context_returns-false
       "tests/scheme/consent-eval-test.scm"
       agent-context-missing-defaults)))
    (emacs-only-cases
     ((consent-context-test-buffer-region-and-project-context
       live-buffer-project-adapter)
      (consent-context-test-policy-denies-buffer-context
       emacs-policy-adapter)
      (consent-context-test-private-buffer-is-local-only
       emacs-buffer-privacy)
      (consent-context-test-context-yield-and-memory-record
       emacs-memory-audit-adapter))))
   (surface
    (ert-file "tests/consent-debugger-test.el")
    (ownership dual-core)
    (portable-files ("tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-diagnostics-test.el")
    (ownership mixed-exact)
    (portable-files ("tests/scheme/consent-diagnostics-test.scm"))
    (portable-cases
     ((consent-diagnostics-test-agent-diagnostics-constructs-records
       "tests/scheme/consent-diagnostics-test.scm"
       diagnostics-records)
      (consent-diagnostics-test-agent-diagnostics-yields-events
       "tests/scheme/consent-diagnostics-test.scm"
       diagnostics-yield)
      (consent-diagnostics-test-request-result-datums-are-host-neutral
       "tests/scheme/consent-diagnostics-test.scm"
       diagnostics-capability-records)))
    (emacs-only-cases
     ((consent-diagnostics-test-emacs-diagnostics-imports-bindings
       emacs-capability-manifest)
      (consent-diagnostics-test-buffer-diagnostics-normalizes-backend-data
       live-buffer-adapter)
      (consent-diagnostics-test-diagnostic-at-selects-position
       live-buffer-adapter)
      (consent-diagnostics-test-project-diagnostics-unavailable
       emacs-project-adapter)
      (consent-diagnostics-test-diagnostics-yield-audits-events
       emacs-audit-adapter))))
   (surface
    (ert-file "tests/consent-diff-test.el")
    (ownership mixed-exact)
    (portable-files ("tests/scheme/consent-diff-test.scm"))
    (portable-cases
     ((consent-diff-test-agent-diff-constructs-and-renders
       "tests/scheme/consent-diff-test.scm"
       diff-render)
      (consent-diff-test-agent-diff-no-change
       "tests/scheme/consent-diff-test.scm"
       diff-no-change)
      (consent-diff-test-agent-diff-yields-events
       "tests/scheme/consent-diff-test.scm"
       diff-yield)))
    (emacs-only-cases
     ((consent-diff-test-emacs-diff-imports-export-bindings
       emacs-capability-manifest)
      (consent-diff-test-buffer-diff-compares-disk-and-buffer
       live-buffer-file-adapter))))
   (surface
    (ert-file "tests/consent-eval-test.el")
    (ownership dual-core)
    (portable-files
     ("tests/scheme/consent-eval-test.scm"
      "tests/scheme/consent-fixture-test.scm")))
   (surface
    (ert-file "tests/consent-fixture-test.el")
    (ownership shared-corpus)
    (portable-files ("tests/scheme/consent-fixture-test.scm")))
   (surface
    (ert-file "tests/consent-helper-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-module-boundary-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-helper-test-emacs-adapter-has-no-pure-store-twin
       "tests/scheme/consent-module-boundary-test.scm"
       helper-boundary-save-ref)
      (consent-helper-test-session-save-list-load-and-isolation
       "tests/scheme/consent-eval-test.scm" agent-helper-save-list-load)
      (consent-helper-test-artifacts-memory-and-skill-candidate
       "tests/scheme/consent-eval-test.scm"
       agent-helper-artifact-and-skill-candidate)))
    (emacs-only-cases
     ((consent-helper-test-project-private-storage-stays-untracked
       emacs-private-persistence)
      (consent-helper-test-tracked-helper-write-requires-approval
       emacs-policy-filesystem-adapter)
      (consent-helper-test-skill-candidate-export-requires-approval
       emacs-policy-filesystem-adapter))))
   (surface
    (ert-file "tests/consent-job-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-module-boundary-test.scm"
      "tests/scheme/consent-native-cli-daemon-process-test.scm"))
    (portable-cases ())
    (emacs-only-cases
     ((consent-job-test-start-streams-yields-and-completes
       emacs-process-adapter)
      (consent-job-test-locks-session-while-running
       emacs-process-session-adapter)
      (consent-job-test-interrupt-records-failed-job
       emacs-process-adapter)
      (consent-job-test-scheme-primitives-start-and-inspect-job
       emacs-process-primitive-adapter))))
   (surface
    (ert-file "tests/consent-library-test.el")
    (ownership bootstrap-and-portable-shelf)
    (portable-files
     ("tests/scheme/consent-manifest-smoke-test.scm"
      "tests/scheme/stdlib-testing-test.scm"
      "tests/scheme/stdlib-json-reference-test.scm")))
   (surface
    (ert-file "tests/consent-macro-test.el")
    (ownership dual-core)
    (portable-files
     ("tests/scheme/consent-eval-test.scm"
      "tests/scheme/consent-fixture-test.scm")))
   (surface
    (ert-file "tests/consent-memory-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-agent-memory-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-memory-test-emacs-adapter-has-no-pure-store-twin
       "tests/scheme/consent-agent-memory-test.scm"
       live-projection-record-stream-count)
      (consent-memory-test-crud-search-tags-and-scope-isolation
       "tests/scheme/consent-eval-test.scm" agent-memory-crud-search-tags)
      (consent-memory-test-session-scope-uses-current-session
       "tests/scheme/consent-agent-memory-test.scm"
       same-key-session-live-record)
      (consent-memory-test-add-recent-and-yield-integration
       "tests/scheme/consent-eval-test.scm"
       agent-memory-yield-emits-context-event)
      (consent-memory-test-reflection-and-selection-primitives
       "tests/scheme/consent-eval-test.scm"
       agent-memory-reflection-selection-primitives)))
    (emacs-only-cases
     ((consent-memory-test-buffers-and-private-local-persistence
       emacs-buffer-persistence-adapter))))
   (surface
    (ert-file "tests/consent-models-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-models-openai-test.scm"
      "tests/scheme/consent-models-live-test.scm"
      "tests/scheme/consent-models-compiled-live-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-models-test-local-complete-through-transport
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-retry-status)
      (consent-models-test-tool-spec-derived-and-routed
       "tests/scheme/consent-eval-test.scm"
       agent-models-tool-spec-from-docstring-metadata)
      (consent-models-test-tool-spec-any-schema-default
       "tests/scheme/consent-eval-test.scm"
       agent-models-tool-spec-any-schema-default)
      (consent-models-test-openai-response-tool-calls
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-parse-tool-id)
      (consent-models-test-openai-request-includes-tools
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-request-tool-count)
      (consent-models-test-complete-uses-source-openai-transport
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-retry-value)
      (consent-models-test-source-transport-retries-through-process-host
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-retry-count)
      (consent-models-test-source-error-preserves-structured-detail
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-http-error-status)
      (consent-models-test-openai-http-error-keeps-status-and-body-excerpt
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-http-error-code)
      (consent-models-test-openai-http-error-honors-detail-budget-override
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-detail-budget-tail)
      (consent-models-test-openai-decode-failure-keeps-body-excerpt
       "tests/scheme/consent-models-openai-test.scm"
       model-openai-decode-error-phase)
      (consent-models-test-live-local-openai-compatible-completion
       "tests/scheme/consent-models-live-test.scm" live-tool-call-source)
      (consent-models-test-live-local-openai-compatible-tool-call
       "tests/scheme/consent-models-live-test.scm" live-tool-call-source)
      (consent-models-test-live-local-quick-start-model-matrix
       "tests/scheme/consent-models-compiled-live-test.scm"
       local-echo)
      (consent-models-test-routing-falls-back-past-unavailable
       "tests/scheme/consent-eval-test.scm"
       agent-models-route-skips-unavailable)
      (consent-models-test-remote-local-only-denied-before-transport
       "tests/scheme/consent-eval-test.scm"
       agent-models-remote-local-only-denied)
      (consent-models-test-diagnostics-redact-credentials
       "tests/scheme/consent-eval-test.scm"
       agent-models-diagnostics-redact-credentials)))
    (emacs-only-cases
     ((consent-models-test-live-matrix-cases-come-from-environment
       emacs-live-test-orchestration)
      (consent-models-test-live-planner-matrix-uses-quick-start-prompt
       emacs-live-test-orchestration)
      (consent-models-test-no-native-emacs-openai-transport-surface
       emacs-bootstrap-ownership)
      (consent-models-test-source-transport-budget-covers-large-planner-response
       emacs-host-callback-accounting))))
   (surface
    (ert-file "tests/consent-native-cli-daemon-mock-test.el")
    (ownership shared-contract)
    (portable-files
     ("tests/scheme/consent-native-cli-daemon-adapter-test.scm"
      "tests/scheme/consent-native-cli-daemon-process-test.scm")))
   (surface
    (ert-file "tests/consent-native-cli-daemon-process-test.el")
    (ownership shared-contract)
    (portable-files
     ("tests/scheme/consent-native-cli-daemon-process-test.scm")))
   (surface
    (ert-file "tests/consent-network-test.el")
    (ownership mixed-exact)
    (portable-files ("tests/scheme/consent-network-test.scm"))
    (portable-cases
     ((consent-network-test-request-decision-and-audit-datums
       "tests/scheme/consent-network-test.scm"
       network-request-decision-audit)
      (consent-network-test-grant-scope-denials
       "tests/scheme/consent-network-test.scm"
       network-grant-denials)
      (consent-network-test-stream-handle-datum
       "tests/scheme/consent-network-test.scm"
       network-handles)))
    (emacs-only-cases ()))
   (surface
    (ert-file "tests/consent-parity-test.el")
    (ownership parity-gate)
    (portable-files
     ("tests/scheme/consent-fixture-test.scm"
      "tests/scheme/consent-parity-emit.scm")))
   (surface
    (ert-file "tests/consent-plan-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-plan-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-plan-test-emacs-adapter-has-no-pure-store-twin
       "tests/scheme/consent-plan-test.scm" plan-domain)
      (consent-plan-test-crud-step-status-and-scope
       "tests/scheme/consent-plan-test.scm" plan-lifecycle)
      (consent-plan-test-yield-memory-and-buffer
       "tests/scheme/consent-eval-test.scm"
       agent-plan-yield-emits-context-event)))
    (emacs-only-cases
     ((consent-plan-test-session-scope-is-isolated
       emacs-session-adapter))))
   (surface
    (ert-file "tests/consent-reader-test.el")
    (ownership dual-core)
    (portable-files
     ("tests/scheme/consent-reader-test.scm"
      "tests/scheme/consent-fixture-test.scm")))
   (surface
    (ert-file "tests/consent-redaction-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-redaction-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-redaction-test-env-like-secret-redacts-as-record
       "tests/scheme/consent-redaction-test.scm" redaction-secrets)
      (consent-redaction-test-scheme-redaction-primitives
       "tests/scheme/consent-eval-test.scm"
       agent-redaction-secret-source-redact-provider)
      (consent-redaction-test-dotted-list-datums-remain-walkable
       "tests/scheme/consent-redaction-test.scm" redaction-local-context)
      (consent-redaction-test-auth-source-and-local-only-context
       "tests/scheme/consent-redaction-test.scm" redaction-local-context)))
    (emacs-only-cases
     ((consent-redaction-test-memory-and-audit-redact-secrets
       emacs-memory-audit-adapter)
      (consent-redaction-test-session-transcripts-redact-secrets
       emacs-session-persistence-adapter)
      (consent-redaction-test-skill-resource-disclosure-redacts
       emacs-skill-adapter))))
   (surface
    (ert-file "tests/consent-reflect-test.el")
    (ownership dual-core)
    (portable-files
     ("tests/scheme/consent-reflect-test.scm"
      "tests/scheme/consent-reflect-stress-test.scm"
      "tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-repl-parity-test.el")
    (ownership shared-corpus)
    (portable-files ("tests/scheme/consent-repl-parity-test.scm")))
   (surface
    (ert-file "tests/consent-repl-test.el")
    (ownership dual-host)
    (portable-files ("tests/scheme/consent-repl-test.scm")))
   (surface
    (ert-file "tests/consent-result-test.el")
    (ownership dual-core)
    (portable-files ("tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-runtime-test.el")
    (ownership dual-core)
    (portable-files ("tests/scheme/consent-eval-test.scm")))
   (surface
    (ert-file "tests/consent-script-test.el")
    (ownership dual-host)
    (portable-files ("tests/scheme/consent-script-test.scm")))
   (surface
    (ert-file "tests/consent-session-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-session-test.scm"
      "tests/scheme/consent-session-store-test.scm"))
    (portable-cases
     ((consent-session-test-create-list-ref-and-scheme-primitives
       "tests/scheme/consent-session-test.scm" create-returns-session-record)
      (consent-session-test-source-library-legacy-session-verbs
       "tests/scheme/consent-session-store-test.scm"
       session-store-lifecycle)
      (consent-session-test-emacs-adapter-has-no-pure-store-twin
       "tests/scheme/consent-session-store-test.scm"
       session-store-lifecycle)
      (consent-session-test-suspend-resume-snapshot-fork-and-audit
       "tests/scheme/consent-session-store-test.scm"
       session-store-lifecycle)))
    (emacs-only-cases
     ((consent-session-test-stale-handle-cleanup-and-retirement
       emacs-handle-lifecycle)
      (consent-session-test-scheme-verbs-policy-shared-pointer-and-audit
       emacs-policy-session-adapter)
      (consent-session-test-session-handles-primitive
       emacs-handle-adapter))))
   (surface
    (ert-file "tests/consent-task-library-test.el")
    (ownership portable-peer)
    (portable-files ("tests/scheme/consent-task-test.scm")))
   (surface
    (ert-file "tests/consent-task-test.el")
    (ownership shared-corpus)
    (portable-files ("tests/scheme/consent-task-test.scm")))
   (surface
    (ert-file "tests/consent-test-test.el")
    (ownership mixed-exact)
    (portable-files ("tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-test-test-case-group-and-error-results
       "tests/scheme/consent-eval-test.scm" agent-test-group-results)
      (consent-test-test-yield-failures-emits-context-event
       "tests/scheme/consent-eval-test.scm" agent-test-yield-failures)
      (consent-test-test-skill-tests-and-srfi64-adaptation
       "tests/scheme/consent-eval-test.scm" agent-test-skill-and-srfi64)
      (consent-test-test-source-budget-exhaustion-is-a-test-status
       "tests/scheme/consent-eval-test.scm"
       agent-test-budget-exhaustion-status)))
    (emacs-only-cases ()))
   (surface
    (ert-file "tests/consent-transcript-test.el")
    (ownership mixed-exact)
    (portable-files ("tests/scheme/consent-transcript-test.scm"))
    (portable-cases
     ((consent-transcript-test-event-shape-classification-and-fixture
       "tests/scheme/consent-transcript-test.scm" pure-event-fixture)
      (consent-transcript-test-agent-library-loads
       "tests/scheme/consent-transcript-test.scm" pure-event-mode)))
    (emacs-only-cases
     ((consent-transcript-test-redacts-before-persistence
       emacs-persistence-adapter)
      (consent-transcript-test-session-evaluations-append-events
       emacs-session-adapter))))
   (surface
    (ert-file "tests/consent-vcs-test.el")
    (ownership mixed-exact)
    (portable-files
     ("tests/scheme/consent-vcs-test.scm"
      "tests/scheme/consent-eval-test.scm"))
    (portable-cases
     ((consent-vcs-test-status-parser-covers-clean-state
       "tests/scheme/consent-vcs-test.scm" vcs-status-clean)
      (consent-vcs-test-status-parser-covers-worktree-states
       "tests/scheme/consent-vcs-test.scm" vcs-status-parser)
      (consent-vcs-test-status-parser-covers-detached-and-conflict
       "tests/scheme/consent-vcs-test.scm" vcs-status-detached-conflict)
      (consent-vcs-test-raw-diff-parser-covers-file-summaries
       "tests/scheme/consent-vcs-test.scm" vcs-diff-parser)
      (consent-vcs-test-request-result-and-outcome-datums
       "tests/scheme/consent-vcs-test.scm" vcs-request-result)
      (consent-vcs-test-local-mutation-requires-policy-grant
       "tests/scheme/consent-vcs-test.scm" vcs-authority)
      (consent-vcs-test-remote-mutation-uses-separate-authority
       "tests/scheme/consent-vcs-test.scm" vcs-authority)))
    (emacs-only-cases
     ((consent-vcs-test-emacs-vcs-imports-read-only-bindings
       emacs-capability-manifest)
      (consent-vcs-test-emacs-vcs-mutation-imports-separate-bindings
       emacs-capability-manifest)
      (consent-vcs-test-emacs-vcs-stage-denies-without-vcs-authority
       emacs-vcs-adapter)
      (consent-vcs-test-emacs-vcs-stage-denies-by-host-policy
       emacs-policy-adapter)
      (consent-vcs-test-emacs-vcs-stage-with-grant-mutates-index
       live-git-index-adapter)
      (consent-vcs-test-emacs-vcs-commit-branch-and-switch-with-grant
       live-git-repository-adapter)
      (consent-vcs-test-emacs-vcs-push-intent-is-authorized-without-live-remote
       emacs-remote-intent-adapter)
     ;; readability-allow: external-identifier -- Parity key stays intact.
     (consent-vcs-test-emacs-vcs-fetch-and-pull-intents-authorized-without-live-remote
       emacs-remote-intent-adapter)
      (consent-vcs-test-emacs-vcs-push-redacts-credentialed-remote-input
       emacs-redaction-adapter)
      (consent-vcs-test-emacs-vcs-maps-git-status-diff-and-log
       live-git-observation-adapter)
      (consent-vcs-test-emacs-vcs-no-vc-is-explicit
       emacs-vc-adapter)
      (consent-vcs-test-emacs-vcs-yields-and-audits
       emacs-audit-adapter)))))))
