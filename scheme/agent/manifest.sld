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
      '((manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent manifest))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer manifest)
        (source-kind source-library)
        (source (path "manifest.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports (agent-library-manifest agent-library-manifest-ref))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent io))
        (owner agent)
        (provider host-adapter)
        (visibility public)
        (layer api)
        (source-kind primitive-library)
        (source (implementation-id agent-io))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports (agent-yield agent-log agent-progress agent-warn agent-request))
        (dependencies ())
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent approval))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "approval.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (agent approval primitive))
        (exports
         (consent-approval-statuses consent-make-approval-store consent-approval-store?
                           approval-store-request! approval-store-status approval-store-ref
                           approval-store-records approval-store-resolve! approval-store-cancel!
                           approval-store-pending approval-request! approval-status approval-cancel!
                           approval-yield-pending approval-resolve!))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent approval primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-approval))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports (approval-request! approval-status approval-cancel! approval-yield-pending approval-resolve!))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent debugger))
        (owner agent)
        (provider host-adapter)
        (visibility public)
        (layer api)
        (source-kind primitive-library)
        (source (implementation-id agent-debugger))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (current-error condition-stack condition-environment condition-restarts restart-invoke!
                           debugger-yield))
        (dependencies ())
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent helper))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "helper.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (agent helper primitive))
        (exports
         (consent-helper-scopes consent-make-helper-store consent-helper-store? helper-store-save!
                           helper-store-ref helper-store-list helper-store-helpers helper-store-record!
                           helper-record-name helper-record-forms helper-store-artifact-save!
                           helper-promote-to-skill agent-artifact agent-helper-save! agent-helper-load
                           agent-helper-list agent-helper-ref agent-helper-promote-to-skill))
        (dependencies ((library (scheme base)) (library (stdlib list))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent helper primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-helper))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (agent-artifact agent-helper-save! agent-helper-load agent-helper-list agent-helper-ref
                           agent-helper-promote-to-skill))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent job))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "job.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (agent job primitive))
        (exports
         (consent-job-states consent-make-job-store consent-job-store? job-store-start! job-store-ref
                           job-store-list job-store-cancel! job-store-interrupt! job-store-yields
                           job-store-status job-store-mark-running! job-store-record-yield!
                           job-store-complete! job-store-fail! job-store-finish-cancelled! job-datum-id
                           job-start! job-ref job-list job-cancel! job-interrupt! job-yields job-status))
        (dependencies ((library (scheme base)) (library (stdlib list))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent job primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-job))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports (job-start! job-ref job-list job-cancel! job-interrupt! job-yields job-status))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent test))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "test.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports (test-case test-error test-group test-run test-yield-failures skill-test skill-test-run))
        (dependencies
         ((library (scheme base)) (library (scheme write)) (library (agent io))
                                (library (agent test primitive))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent test primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-test))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports (agent-test-eval-source-result))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent diagnostics))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "diagnostics.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (diagnostics-field diagnostics-field-value make-diagnostic-range diagnostic-range?
                           diagnostic-range-start diagnostic-range-end make-diagnostic diagnostic?
                           diagnostic-severity diagnostic-message diagnostic-source diagnostic-file
                           diagnostic-buffer diagnostic-range diagnostic-metadata make-diagnostics-snapshot
                           diagnostics-snapshot? diagnostics-snapshot-status diagnostics-snapshot-diagnostics
                           make-diagnostics-capability-request diagnostics-capability-request?
                           diagnostics-capability-request-operation make-diagnostics-capability-result
                           make-diagnostics-outcome diagnostics-outcome? diagnostics-outcome-status
                           diagnostic-known-severity? diagnostics-read-only-operation? diagnostics-yield))
        (dependencies ((library (scheme base)) (library (agent io))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent diff))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "diff.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (make-diff make-diff-hunk diff-line no-change-diff proposed-edit-diff diff? diff-changed?
                           diff-source diff-hunks diff-render-unified diff-yield))
        (dependencies
         ((library (scheme base)) (library (scheme cxr))
                                (library (stdlib generator)) (library (agent io))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent vcs))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "vcs.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (vcs-field vcs-field-value make-vcs-repository make-vcs-branch make-vcs-remote
                           make-vcs-commit-summary make-vcs-status vcs-status? vcs-status-branch
                           vcs-status-entries make-vcs-status-entry vcs-status-entry? vcs-status-entry-kind
                           vcs-status-entry-path vcs-status-entry-index-status
                           vcs-status-entry-worktree-status vcs-status-entry-conflict?
                           make-vcs-operation-state make-vcs-conflict-state make-vcs-diff-summary
                           make-vcs-diff-file vcs-diff-summary-files make-vcs-capability-request
                           vcs-capability-request? vcs-capability-request-id vcs-capability-request-operation
                           make-vcs-capability-result make-vcs-capability-grant make-vcs-approval-decision
                           make-vcs-capability-decision vcs-capability-decision?
                           vcs-capability-decision-status vcs-authorize-capability-request
                           make-vcs-capability-audit vcs-capability-audit? make-vcs-outcome
                           vcs-outcome-status vcs-known-outcome? vcs-read-only-operation?
                           vcs-mutating-operation? vcs-remote-operation? vcs-operation-required-authority
                           parse-git-status-porcelain-v2-z parse-git-raw-diff-z))
        (dependencies ((library (scheme base)) (library (stdlib generator))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent network))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "network.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (network-field network-field-value make-network-request network-request? network-request-id
                           network-request-operation make-network-grant make-network-approval-decision
                           make-network-capability-decision network-capability-decision?
                           network-capability-decision-status network-authorize-request make-network-response
                           make-network-stream-handle make-network-port-capability make-network-audit
                           network-audit?))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent task))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "task.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (task-states task-pause-states task-terminal-states task-allowed-transitions task-pause-reasons
                           task-stop-reasons task-state? task-transition-allowed? validate-task-transition
                           make-task-condition task-field-value task-record? agent-task? agent-step?
                           agent-action? agent-observation? agent-decision? task-pause? task-stop? task-wait?
                           task-failure? agent-completion? task-record-valid? validate-task-record
                           make-agent-task make-agent-step make-agent-action make-agent-observation
                           make-agent-decision make-task-pause make-task-stop make-task-wait
                           make-task-failure make-agent-completion))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent memory))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "memory.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (agent memory primitive))
        (exports
         (consent-memory-scopes consent-memory-classes consent-make-memory-store consent-memory-store?
                           memory-store-put! memory-store-ref memory-store-delete! memory-store-add!
                           memory-store-access! memory-store-reflect! memory-store-select memory-store-find
                           memory-store-by-tag memory-store-recent memory-store-records
                           memory-store-replace-records! memory-storage-rules memory-scope-datum
                           memory-scope-datum-records memory-record-id memory-record-field-value
                           memory-record-class memory-selection? memory-selection-records
                           memory-selection-candidates memory-selection-cutoff memory-put! memory-ref
                           memory-delete! memory-add! memory-find memory-by-tag memory-recent memory-access!
                           memory-reflect! memory-select memory-yield))
        (dependencies ((library (scheme base)) (library (stdlib list)) (library (scheme write))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent memory primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-memory))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (memory-put! memory-ref memory-delete! memory-add! memory-find memory-by-tag memory-recent
                           memory-access! memory-reflect! memory-select memory-yield))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent plan))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "plan.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (agent plan primitive))
        (exports
         (consent-plan-scopes consent-plan-statuses consent-plan-step-statuses consent-make-plan-store
                           consent-plan-store? plan-store-create! plan-store-ref plan-store-list
                           plan-store-replace-records! plan-store-step-add! plan-store-step-status!
                           plan-store-status! plan-record-id plan-record-scope plan-record-steps plan-step-id
                           plan-step-status plan-memory-important? plan-create! plan-ref plan-list
                           plan-step-add! plan-step-status! plan-status! plan-yield))
        (dependencies ((library (scheme base)) (library (stdlib list))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent plan primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-plan))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports (plan-create! plan-ref plan-list plan-step-add! plan-step-status! plan-status! plan-yield))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent models))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "models.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (model-provider-register! model-providers model-route model-tool-spec model-complete
                           model-provider-diagnostics))
        (dependencies ((library (scheme base)) (library (agent reflect)) (library (agent models primitive))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent models primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-models))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (primitive-model-provider-register! primitive-model-providers primitive-model-route
                           primitive-model-complete primitive-model-provider-diagnostics))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent models openai))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer provider)
        (source-kind source-library)
        (source (path "models/openai.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (model-openai-request-json model-openai-parse-response
                           model-openai-compatible-http-completion-result
                           model-openai-compatible-http-complete))
        (dependencies
         ((library (scheme base)) (library (scheme write)) (library (agent redaction))
                                (library (cli process-host)) (library (stdlib generator))
                                (library (stdlib json))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent context))
        (owner agent)
        (provider host-adapter)
        (visibility public)
        (layer api)
        (source-kind primitive-library)
        (source (implementation-id agent-context))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (current-request current-focus current-region-context current-buffer-context current-project-context
                           current-conversation-summary context-yield))
        (dependencies ())
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent reflect))
        (owner agent)
        (provider host-adapter)
        (visibility public)
        (layer api)
        (source-kind primitive-library)
        (source (implementation-id agent-reflect))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports
         (consent-version current-capabilities current-policy current-budget budget-remaining
                           budget-exhausted? budget-yield current-imports library-bindings libraries
                           library-info library-search catalog-sources catalog-diagnostics add-manifest!
                           remove-manifest! add-manifest-root! remove-manifest-root! refresh-library-catalog!
                           library-documentation binding-libraries documented-bindings apropos
                           reflection-field documentation-field docstring current-session-info recent-yields
                           recent-errors recent-policy-decisions capability-info documentation consent-doc
                           consent-describe macroexpand macroexpand-1 macroexpand-library macro-binding-info
                           syntax-source macroexpand-yield))
        (dependencies ())
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent redaction))
        (owner agent)
        (provider host-adapter)
        (visibility public)
        (layer api)
        (source-kind primitive-library)
        (source (implementation-id agent-redaction))
        (api-version (compat 0))
        (source-version runtime)
        (realization host-primitive)
        (exports (secret-source? redact context-local-only! redaction-log safe-for-provider?))
        (dependencies ())
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent session))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "session.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (primitive-overlay-library (agent session primitive))
        (exports
         (consent-session-scopes consent-session-states consent-session-restored-fields
                           consent-session-revalidated-fields consent-session-never-restored-fields
                           consent-make-session-store consent-session-store? session-store-create!
                           session-store-ref session-store-list session-store-set-fields!
                           session-store-suspend! session-store-resume! session-store-snapshot!
                           session-store-fork! session-store-retire! session-create! session-ref session-list
                           session-suspend! session-resume! session-snapshot! session-fork! session-retire!
                           session-handles session-datum-id consent-make-session-manager
                           consent-session-manager? session-manager-store
                           session-manager-set-context-factory! session-manager-context-factory
                           session-manager-reset! session-manager-context-ref session-manager-current-id
                           session-manager-create! session-manager-seed! session-manager-switch!
                           session-manager-current session-manager-list session-manager-close! create-session
                           switch-session set-default-session! current-session list-sessions close-session))
        (dependencies ((library (scheme base)) (library (stdlib list))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind primitive-library)
        (name (agent session primitive))
        (owner agent)
        (provider host-adapter)
        (visibility internal-agent-primitive)
        (layer primitive)
        (source-kind primitive-library)
        (source (implementation-id agent-session))
        (api-version internal)
        (source-version runtime)
        (realization host-primitive)
        (exports
         (session-create! session-ref session-list session-handles session-suspend! session-resume!
                           session-snapshot! session-fork! session-retire! create-session switch-session
                           set-default-session! current-session list-sessions close-session))
        (dependencies ())
        (provenance ((origin repo)))
        (status internal)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent registry))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "registry.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (make-agent agent? agent-field-value agent-id agent-name agent-role agent-model agent-rules
                           agent-skills agent-budget agent-description make-agent-registry agent-registry?
                           register-agent agents agent-ref default-agent default-agent-id set-default-agent!
                           select-agent agent-selection? agent-selection-field-value agent-selection-status
                           agent-selection-agent agent-selection-agent-id agent-selection-basis
                           agent-selection-reason agent-selection-considered))
        (dependencies ((library (scheme base)) (library (stdlib list))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent proposal))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "proposal.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (proposal-control-plane-operations proposal-control-plane-operation? analyze-code-action
                           code-action-analysis? proposal-field-value analysis-status analysis-pure-cost
                           analysis-capability-requests analysis-quarantine-decisions
                           analysis-failure-decisions capability-request? capability-decision?
                           capability-decision-status))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent runner))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "runner.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (run-task task-run? task-run-field-value task-run-task task-run-state task-run-receipt
                           task-run-completion task-run-steps task-run-observations task-run-transcript
                           task-run-budget))
        (dependencies
         ((library (scheme base)) (library (agent task)) (library (agent transcript))
                                (library (agent proposal))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent reliability))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "reliability.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (pass-k reliability-field-value reliability-stop-reason reliability-trial-passed?
                           measure-reliability measure-policy-ablation))
        (dependencies
         ((library (scheme base)) (library (stdlib list)) (library (scheme write)) (library (agent runner))
                                (library (agent task))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent prompt))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "prompt.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (make-agent agent? agent-field-value agent-id agent-name agent-role agent-model agent-rules
                           agent-skills agent-budget agent-description make-agent-registry agent-registry?
                           register-agent agent-ref default-agent default-agent-id set-default-agent!
                           select-agent agent-selection? agent-selection-field-value agent-selection-status
                           agent-selection-agent agent-selection-agent-id agent-selection-basis
                           agent-selection-reason agent-selection-considered make-prompt-authority
                           prompt-authority? prompt-authority-field-value prompt-authority-authorized?
                           make-prompt-harness prompt-harness? prompt-harness-registry prompt-harness-session
                           prompt-harness-authority? prompt-harness-defaults prompt-harness-set-session!
                           prompt-harness-set-authority! current-prompt-harness set-current-prompt-harness!
                           reset-prompt-harness! prompt prompt-role prompt-model agents roles models
                           prompt-result? prompt-result-field-value prompt-result-status prompt-result-ok?
                           prompt-result-agent prompt-result-agent-id prompt-result-role prompt-result-model
                           prompt-result-session prompt-result-selection prompt-result-run
                           prompt-result-receipt prompt-result-state prompt-result-completion
                           prompt-result-transcript prompt-result-observations prompt-result-budget
                           prompt-result-audit))
        (dependencies
         ((library (scheme base)) (library (scheme case-lambda)) (library (stdlib list))
                                (library (agent runner)) (library (agent registry)) (library (agent task))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent generated-source))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "generated-source.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (generated-source-diagnostic generated-source-record-field-value generated-source-candidate
                           generated-source-candidate? generated-source-candidate-status
                           generated-source-candidate-source generated-source-candidate-original
                           generated-source-candidate-forms generated-source-candidate-diagnostics
                           generated-source-attempt? generated-source-run generated-source-run?
                           generated-source-run-status generated-source-run-attempts
                           generated-source-run-candidate generated-source-run-diagnostics
                           generated-source-run-repair-prompts generated-source-repair-prompt
                           generated-source-apply))
        (dependencies ((library (scheme base)) (library (scheme read))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))
       (manifest-entry
        (schema-version 1)
        (kind library)
        (name (agent transcript))
        (owner agent)
        (provider repo-source)
        (visibility public)
        (layer api)
        (source-kind source-library)
        (source (path "transcript.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports
         (transcript-event-kinds transcript-replay-modes transcript-export-formats
                           transcript-retention-default make-transcript-event transcript-event?
                           transcript-field-value transcript-event-replay-mode transcript-replayable?
                           transcript-recorded-observation? transcript-event->fixture-case
                           transcript-event-summary transcript-raw-view transcript-summary-view
                           transcript-rotate transcript-export))
        (dependencies ((library (scheme base)) (library (stdlib list))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))))

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
         ((equal? (cadr (assq 'name (cdr (car rest)))) library) (car rest))
         (else (loop (cdr rest))))))))
