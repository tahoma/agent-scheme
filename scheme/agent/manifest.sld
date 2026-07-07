;;; Portable Agent library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This load-light manifest records the public Agent library surface and the
;;; internal primitive backing libraries used by source-backed facades. It is
;;; metadata for discovery and policy, not authority to import a library.

(define-library (agent manifest)
  (export agent-library-manifest agent-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe Agent-facing libraries and primitive overlays.
    (define agent-library-manifest
      '(((library . (agent manifest))
         (visibility . public)
         (layer . manifest)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "manifest.sld")
         (implementation-library . (agent manifest))
         (exports . (agent-library-manifest agent-library-manifest-ref))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (agent io))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-io)
         (exports . (agent-yield agent-log agent-progress agent-warn
                     agent-request))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent approval))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "approval.sld")
         (implementation-library . (agent approval))
         (primitive-overlay-library . (agent approval primitive))
         (exports . (consent-approval-statuses
                     consent-make-approval-store
                     consent-approval-store? approval-store-request!
                     approval-store-status approval-store-ref
                     approval-store-resolve! approval-store-cancel!
                     approval-store-pending approval-request!
                     approval-status approval-cancel!
                     approval-yield-pending approval-resolve!))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (agent approval primitive))
         (visibility . internal-agent-model)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-approval)
         (exports . (approval-request! approval-status approval-cancel!
                     approval-yield-pending approval-resolve!))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent debugger))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-debugger)
         (exports . (current-error condition-stack condition-environment
                     condition-restarts restart-invoke! debugger-yield))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent helper))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-helper)
         (exports . (agent-artifact agent-helper-save! agent-helper-load
                     agent-helper-list agent-helper-ref
                     agent-helper-promote-to-skill))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent job))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-job)
         (exports . (job-start! job-ref job-list job-cancel!
                     job-interrupt! job-yields job-status))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent test))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "test.sld")
         (implementation-library . (agent test))
         (exports . (test-case test-error test-group test-run
                     test-yield-failures skill-test skill-test-run))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme write) (agent io)
                          (agent test primitive))))
        ((library . (agent test primitive))
         (visibility . internal-agent-model)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-test)
         (exports . (agent-test-eval-source-result))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent diagnostics))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "diagnostics.sld")
         (implementation-library . (agent diagnostics))
         (exports . (diagnostics-field diagnostics-field-value
                     make-diagnostic-range diagnostic-range?
                     diagnostic-range-start diagnostic-range-end
                     make-diagnostic diagnostic? diagnostic-severity
                     diagnostic-message diagnostic-source diagnostic-file
                     diagnostic-buffer diagnostic-range diagnostic-metadata
                     make-diagnostics-snapshot diagnostics-snapshot?
                     diagnostics-snapshot-status
                     diagnostics-snapshot-diagnostics
                     make-diagnostics-capability-request
                     diagnostics-capability-request?
                     diagnostics-capability-request-operation
                     make-diagnostics-capability-result
                     make-diagnostics-outcome diagnostics-outcome?
                     diagnostics-outcome-status diagnostic-known-severity?
                     diagnostics-read-only-operation? diagnostics-yield))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (agent io))))
        ((library . (agent diff))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "diff.sld")
         (implementation-library . (agent diff))
         (exports . (make-diff make-diff-hunk diff-line no-change-diff
                     proposed-edit-diff diff? diff-changed? diff-source
                     diff-hunks diff-render-unified diff-yield))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme cxr) (stdlib generator)
                          (agent io))))
        ((library . (agent vcs))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "vcs.sld")
         (implementation-library . (agent vcs))
         (exports . (vcs-field vcs-field-value make-vcs-repository
                     make-vcs-branch make-vcs-remote make-vcs-commit-summary
                     make-vcs-status vcs-status? vcs-status-branch
                     vcs-status-entries make-vcs-status-entry
                     vcs-status-entry? vcs-status-entry-kind
                     vcs-status-entry-path vcs-status-entry-index-status
                     vcs-status-entry-worktree-status
                     vcs-status-entry-conflict? make-vcs-operation-state
                     make-vcs-conflict-state make-vcs-diff-summary
                     make-vcs-diff-file vcs-diff-summary-files
                     make-vcs-capability-request vcs-capability-request?
                     vcs-capability-request-id
                     vcs-capability-request-operation
                     make-vcs-capability-result make-vcs-capability-grant
                     make-vcs-approval-decision make-vcs-capability-decision
                     vcs-capability-decision? vcs-capability-decision-status
                     vcs-authorize-capability-request
                     make-vcs-capability-audit vcs-capability-audit?
                     make-vcs-outcome vcs-outcome-status vcs-known-outcome?
                     vcs-read-only-operation? vcs-mutating-operation?
                     vcs-remote-operation? vcs-operation-required-authority
                     parse-git-status-porcelain-v2-z parse-git-raw-diff-z))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (stdlib generator))))
        ((library . (agent network))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "network.sld")
         (implementation-library . (agent network))
         (exports . (network-field network-field-value make-network-request
                     network-request? network-request-id
                     network-request-operation make-network-grant
                     make-network-approval-decision
                     make-network-capability-decision
                     network-capability-decision?
                     network-capability-decision-status
                     network-authorize-request make-network-response
                     make-network-stream-handle make-network-port-capability
                     make-network-audit network-audit?))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (agent task))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "task.sld")
         (implementation-library . (agent task))
         (exports . (task-states task-pause-states task-terminal-states
                     task-allowed-transitions task-pause-reasons
                     task-stop-reasons task-state? task-transition-allowed?
                     validate-task-transition make-task-condition
                     task-field-value task-record? agent-task? agent-step?
                     agent-action? agent-observation? agent-decision?
                     task-pause? task-stop? task-wait? task-failure?
                     agent-completion? task-record-valid?
                     validate-task-record make-agent-task make-agent-step
                     make-agent-action make-agent-observation
                     make-agent-decision make-task-pause make-task-stop
                     make-task-wait make-task-failure make-agent-completion))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (agent memory))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "memory.sld")
         (implementation-library . (agent memory))
         (primitive-overlay-library . (agent memory primitive))
         (exports . (consent-memory-scopes consent-memory-classes
                     consent-make-memory-store consent-memory-store?
                     memory-store-put! memory-store-ref memory-store-delete!
                     memory-store-add! memory-store-access!
                     memory-store-reflect! memory-store-select
                     memory-store-find memory-store-by-tag
                     memory-store-recent memory-store-records
                     memory-store-replace-records! memory-storage-rules
                     memory-scope-datum memory-scope-datum-records
                     memory-record-id memory-record-field-value
                     memory-record-class memory-selection?
                     memory-selection-records memory-selection-candidates
                     memory-selection-cutoff memory-put! memory-ref
                     memory-delete! memory-add! memory-find memory-by-tag
                     memory-recent memory-access! memory-reflect!
                     memory-select memory-yield))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (stdlib list) (scheme write))))
        ((library . (agent memory primitive))
         (visibility . internal-agent-model)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-memory)
         (exports . (memory-put! memory-ref memory-delete! memory-add!
                     memory-find memory-by-tag memory-recent
                     memory-access! memory-reflect! memory-select
                     memory-yield))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent plan))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-plan)
         (exports . (plan-create! plan-ref plan-list plan-step-add!
                     plan-step-status! plan-status! plan-yield))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent models))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "models.sld")
         (implementation-library . (agent models))
         (exports . (model-provider-register! model-providers model-route
                     model-tool-spec model-complete
                     model-provider-diagnostics))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (agent reflect)
                          (agent models primitive))))
        ((library . (agent models primitive))
         (visibility . internal-agent-model)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-models)
         (exports . (primitive-model-provider-register!
                     primitive-model-providers primitive-model-route
                     primitive-model-complete
                     primitive-model-provider-diagnostics))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent models openai))
         (visibility . public)
         (layer . provider)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "models/openai.sld")
         (implementation-library . (agent models openai))
         (exports . (model-openai-request-json model-openai-parse-response
                     model-openai-compatible-http-completion-result
                     model-openai-compatible-http-complete))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme write)
                          (agent redaction) (cli process-host)
                          (stdlib generator) (stdlib json))))
        ((library . (agent context))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-context)
         (exports . (current-request current-focus current-region-context
                     current-buffer-context current-project-context
                     current-conversation-summary context-yield))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent reflect))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-reflect)
         (exports . (consent-version current-capabilities current-policy
                     current-budget budget-remaining budget-exhausted?
                     budget-yield current-imports library-bindings libraries
                     library-info library-search catalog-sources
                     catalog-diagnostics add-manifest! remove-manifest!
                     add-manifest-root! remove-manifest-root!
                     refresh-library-catalog! library-documentation
                     binding-libraries documented-bindings apropos
                     reflection-field documentation-field docstring
                     current-session-info recent-yields recent-errors
                     recent-policy-decisions capability-info documentation
                     consent-doc consent-describe macroexpand macroexpand-1
                     macroexpand-library macro-binding-info syntax-source
                     macroexpand-yield))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent redaction))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-redaction)
         (exports . (secret-source? redact context-local-only!
                     redaction-log safe-for-provider?))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent session))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "session.sld")
         (implementation-library . (agent session))
         (primitive-overlay-library . (agent session primitive))
         (exports . (consent-session-scopes consent-session-states
                     consent-session-restored-fields
                     consent-session-revalidated-fields
                     consent-session-never-restored-fields
                     consent-make-session-store consent-session-store?
                     session-store-create! session-store-ref
                     session-store-list session-store-set-fields!
                     session-store-suspend! session-store-resume!
                     session-store-snapshot! session-store-fork!
                     session-store-retire! session-create! session-ref
                     session-list session-suspend! session-resume!
                     session-snapshot! session-fork! session-retire!
                     session-handles session-datum-id
                     consent-make-session-manager consent-session-manager?
                     session-manager-store
                     session-manager-set-context-factory!
                     session-manager-context-factory session-manager-reset!
                     session-manager-context-ref session-manager-current-id
                     session-manager-create! session-manager-seed!
                     session-manager-switch! session-manager-current
                     session-manager-list session-manager-close!
                     create-session switch-session set-default-session!
                     current-session list-sessions close-session))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (stdlib list))))
        ((library . (agent session primitive))
         (visibility . internal-agent-model)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . agent-session)
         (exports . (session-create! session-ref session-list
                     session-handles session-suspend! session-resume!
                     session-snapshot! session-fork! session-retire!
                     create-session switch-session set-default-session!
                     current-session list-sessions close-session))
         (owner . agent)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (agent registry))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "registry.sld")
         (implementation-library . (agent registry))
         (exports . (make-agent agent? agent-field-value agent-id agent-name
                     agent-role agent-model agent-rules agent-skills
                     agent-budget agent-description make-agent-registry
                     agent-registry? register-agent agents agent-ref
                     default-agent default-agent-id set-default-agent!
                     select-agent agent-selection?
                     agent-selection-field-value agent-selection-status
                     agent-selection-agent agent-selection-agent-id
                     agent-selection-basis agent-selection-reason
                     agent-selection-considered))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (stdlib list))))
        ((library . (agent proposal))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "proposal.sld")
         (implementation-library . (agent proposal))
         (exports . (proposal-control-plane-operations
                     proposal-control-plane-operation? analyze-code-action
                     code-action-analysis? proposal-field-value
                     analysis-status analysis-pure-cost
                     analysis-capability-requests
                     analysis-quarantine-decisions
                     analysis-failure-decisions capability-request?
                     capability-decision? capability-decision-status))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (agent runner))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "runner.sld")
         (implementation-library . (agent runner))
         (exports . (run-task task-run? task-run-field-value task-run-task
                     task-run-state task-run-receipt task-run-completion
                     task-run-steps task-run-observations
                     task-run-transcript task-run-budget))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (agent task)
                          (agent transcript) (agent proposal))))
        ((library . (agent reliability))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "reliability.sld")
         (implementation-library . (agent reliability))
         (exports . (pass-k reliability-field-value reliability-stop-reason
                     reliability-trial-passed? measure-reliability
                     measure-policy-ablation))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (stdlib list) (scheme write)
                          (agent runner) (agent task))))
        ((library . (agent prompt))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "prompt.sld")
         (implementation-library . (agent prompt))
         (exports . (make-agent agent? agent-field-value agent-id agent-name
                     agent-role agent-model agent-rules agent-skills
                     agent-budget agent-description make-agent-registry
                     agent-registry? register-agent agent-ref default-agent
                     default-agent-id set-default-agent! select-agent
                     agent-selection? agent-selection-field-value
                     agent-selection-status agent-selection-agent
                     agent-selection-agent-id agent-selection-basis
                     agent-selection-reason agent-selection-considered
                     make-prompt-authority prompt-authority?
                     prompt-authority-field-value
                     prompt-authority-authorized? make-prompt-harness
                     prompt-harness? prompt-harness-registry
                     prompt-harness-session prompt-harness-authority?
                     prompt-harness-defaults prompt-harness-set-session!
                     prompt-harness-set-authority! current-prompt-harness
                     set-current-prompt-harness! reset-prompt-harness!
                     prompt prompt-role prompt-model agents roles models
                     prompt-result? prompt-result-field-value
                     prompt-result-status prompt-result-ok?
                     prompt-result-agent prompt-result-agent-id
                     prompt-result-role prompt-result-model
                     prompt-result-session prompt-result-selection
                     prompt-result-run prompt-result-receipt
                     prompt-result-state prompt-result-completion
                     prompt-result-transcript prompt-result-observations
                     prompt-result-budget prompt-result-audit))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme case-lambda)
                          (stdlib list) (agent runner)
                          (agent registry) (agent task))))
        ((library . (agent generated-source))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "generated-source.sld")
         (implementation-library . (agent generated-source))
         (exports . (generated-source-diagnostic
                     generated-source-record-field-value
                     generated-source-candidate generated-source-candidate?
                     generated-source-candidate-status
                     generated-source-candidate-source
                     generated-source-candidate-original
                     generated-source-candidate-forms
                     generated-source-candidate-diagnostics
                     generated-source-attempt? generated-source-run
                     generated-source-run? generated-source-run-status
                     generated-source-run-attempts
                     generated-source-run-candidate
                     generated-source-run-diagnostics
                     generated-source-run-repair-prompts
                     generated-source-repair-prompt generated-source-apply))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme read))))
        ((library . (agent transcript))
         (visibility . public)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "transcript.sld")
         (implementation-library . (agent transcript))
         (exports . (transcript-event-kinds transcript-replay-modes
                     transcript-export-formats transcript-retention-default
                     make-transcript-event transcript-event?
                     transcript-field-value transcript-event-replay-mode
                     transcript-replayable? transcript-recorded-observation?
                     transcript-event->fixture-case transcript-event-summary
                     transcript-raw-view transcript-summary-view
                     transcript-rotate transcript-export))
         (owner . agent)
         (provider . repo-source)
         (dependencies . ((scheme base) (stdlib list))))))

    (define (agent-library-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "Agent library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest agent-library-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
