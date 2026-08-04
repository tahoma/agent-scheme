;;; Portable Consent Scheme module-boundary test runner.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and verifies that the
;;; portable pass-boundary libraries expose their expected public surfaces.

(import (scheme base)
        (scheme write)
        (prefix (consent runtime) runtime:)
        (prefix (consent base) base:)
        (prefix (consent library) library:)
        (prefix (consent macro) macro:)
        (prefix (agent approval) approval:)
        (prefix (agent job) job:)
        (prefix (agent memory) memory:)
        (prefix (agent helper) helper:)
        (prefix (agent plan) plan:)
        (prefix (agent context) context:)
        (prefix (agent redaction) redaction:)
        (prefix (agent session) session:)
        (prefix (agent task) task:)
        (prefix (consent interpreter) interpreter:)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Report whether THUNK raises a Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(testing-registry-case
 'runtime-boundary '(portable core)
(test-equal 'runtime-boundary
             #t
             (procedure? runtime:consent-make-empty-environment)))

(testing-registry-case
 'base-boundary '(portable core)
(test-equal 'base-boundary
             #t
             (if (memq '+ (base:consent-base-primitive-names)) #t #f)))

(testing-registry-case
 'library-boundary '(portable core)
(test-equal 'library-boundary
             #t
             (pair? (library:consent-standard-source-library-specs))))

(testing-registry-case
 'data-library-boundary '(portable core)
(test-equal 'data-library-boundary
            #t
            (pair? (library:consent-data-source-library-specs))))

(testing-registry-case
 'macro-boundary '(portable core)
(test-equal 'macro-boundary
             #t
             (procedure? macro:consent-expand-source)))

;; Store for exercising the portable approval boundary.
(define approval-store (approval:consent-make-approval-store))

;; Approval records are canonical Scheme-readable datums.
(define portable-approval-id
  (approval:approval-store-request!
   approval-store
   '(approval-request
      (policy buffer-edit)
      (effect (buffer-replace! h-1 1 2 "x"))
      (reason "Replace text?"))))

(testing-registry-case
 'approval-boundary-request-status '(portable core)
(test-equal 'approval-boundary-request-status
             'pending
             (approval:approval-store-status approval-store
               portable-approval-id)))

(testing-registry-case
 'approval-boundary-pending '(portable core)
(test-equal 'approval-boundary-pending
             1
             (length (approval:approval-store-pending approval-store))))

(testing-registry-case
 'consent-module-boundary-case-7 '(portable core)
(approval:approval-store-resolve! approval-store portable-approval-id 'denied))

(testing-registry-case
 'approval-boundary-resolved-status '(portable core)
(test-equal 'approval-boundary-resolved-status
             'denied
             (approval:approval-store-status approval-store
               portable-approval-id)))

(testing-registry-case
 'approval-boundary-cancel-resolved-denied '(portable core)
(test-equal 'approval-boundary-cancel-resolved-denied
             #t
             (raises?
        (lambda ()
          (approval:approval-store-cancel! approval-store
            portable-approval-id)))))

;; Store for exercising the portable job boundary.
(define job-store (job:consent-make-job-store))

;; Job records are canonical Scheme-readable datums even when a host adapter
;; owns actual scheduling.
(define portable-job
  (job:job-store-start! job-store
                        'portable-main
                        '(begin (agent-yield '(phase ready)) 'done)
                        '((max-steps . 100))))

;; Id of the portable job record under test.
(define portable-job-id (job:job-datum-id portable-job))

(testing-registry-case
 'job-boundary-start-status '(portable core)
(test-equal 'job-boundary-start-status
             'queued
             (job:job-store-status job-store portable-job-id)))

(testing-registry-case
 'consent-module-boundary-case-11 '(portable core)
(job:job-store-mark-running! job-store portable-job-id))
(testing-registry-case
 'consent-module-boundary-case-12 '(portable core)
(job:job-store-record-yield! job-store portable-job-id '(yield (phase ready))))

(testing-registry-case
 'job-boundary-stream-yield '(portable core)
(test-equal 'job-boundary-stream-yield
             '((yield (phase ready)))
             (job:job-store-yields job-store portable-job-id '())))

(testing-registry-case
 'consent-module-boundary-case-14 '(portable core)
(job:job-store-cancel! job-store portable-job-id))

(testing-registry-case
 'job-boundary-cancel-requested '(portable core)
(test-equal 'job-boundary-cancel-requested
             'cancel-requested
             (job:job-store-status job-store portable-job-id)))

(testing-registry-case
 'consent-module-boundary-case-16 '(portable core)
(job:job-store-finish-cancelled! job-store
                                  portable-job-id
                                  "job cancelled: j-1"))

(testing-registry-case
 'job-boundary-cancelled-status '(portable core)
(test-equal 'job-boundary-cancelled-status
             'cancelled
             (job:job-store-status job-store portable-job-id)))

;; Store for exercising the portable memory boundary.
(define memory-store (memory:consent-make-memory-store))

;; Memory records are canonical Scheme-readable datums.
(define portable-memory
  (memory:memory-store-put! memory-store
                            'instance
                            'portable-key
                            '((tags (portable fact))
                              (value "portable memory")
                              (confidence high))))

(testing-registry-case
 'memory-boundary-put-ref '(portable core)
(test-equal 'memory-boundary-put-ref
             'portable-key
             (memory:memory-record-id
        (memory:memory-store-ref memory-store 'instance 'portable-key))))

(testing-registry-case
 'memory-boundary-by-tag '(portable core)
(test-equal 'memory-boundary-by-tag
             1
             (length (memory:memory-store-by-tag memory-store 'instance
               'portable))))

(testing-registry-case
 'memory-boundary-find '(portable core)
(test-equal 'memory-boundary-find
             1
             (length (memory:memory-store-find memory-store
                                         'instance
                                         "portable memory"))))

;; Store for exercising the portable helper/artifact boundary.
(define helper-store (helper:consent-make-helper-store))

;; Helper libraries and artifacts are canonical Scheme-readable datums.
(define portable-helper
  (helper:helper-store-save! helper-store
                             'session
                             '(agent helpers portable)
                             '((define (portable-helper x) (+ x 1)))
                             '(session portable-main)))

(testing-registry-case
 'helper-boundary-save-ref '(portable core)
(test-equal 'helper-boundary-save-ref
             '(agent helpers portable)
             (helper:helper-record-name
        (helper:helper-store-ref helper-store
                                 'session
                                 '(agent helpers portable)))))

(testing-registry-case
 'helper-boundary-list-is-scoped '(portable core)
(test-equal 'helper-boundary-list-is-scoped
             1
             (length (helper:helper-store-list helper-store 'session))))

;; Artifact record used for exercising portable helper artifact storage.
(define portable-artifact
  (helper:helper-store-artifact-save! helper-store
                                      'session
                                      'example
                                      '(example
                                        (source "(portable-helper 41)")
                                        (expect "42"))
                                      '(session portable-main)))

(testing-registry-case
 'helper-boundary-artifact-record '(portable core)
(test-equal 'helper-boundary-artifact-record
             'agent-artifact
             (car portable-artifact)))

(testing-registry-case
 'helper-boundary-skill-candidate '(portable core)
(test-equal 'helper-boundary-skill-candidate
             'agent-skill-candidate
             (car (helper:helper-promote-to-skill
             portable-helper
             '((name "portable-helper")
               (examples ((example (source "(portable-helper 41)")
                                   (expect "42"))))
               (references ((r7rs "docs/r7rs-small-report.md")))
               (tests (((source "(portable-helper 41)") (expect "42")))))))))

;; Store for exercising the portable plan boundary.
(define plan-store (plan:consent-make-plan-store))

;; Plan records are scoped, mutable Scheme-readable datums.
(define portable-plan
  (plan:plan-store-create!
   plan-store
   '(plan
      (id boundary-plan)
      (scope project)
      (goal "Exercise portable plan store.")
      (steps (((id first) (status pending)))))))

(testing-registry-case
 'plan-boundary-ref '(portable core)
(test-equal 'plan-boundary-ref
             'boundary-plan
             (plan:plan-record-id
        (plan:plan-store-ref plan-store 'boundary-plan))))

(testing-registry-case
 'consent-module-boundary-case-26 '(portable core)
(plan:plan-store-step-status! plan-store 'boundary-plan 'first 'done))

(testing-registry-case
 'plan-boundary-step-status '(portable core)
(test-equal 'plan-boundary-step-status
             'done
             (plan:plan-step-status
        (car (plan:plan-record-steps
              (plan:plan-store-ref plan-store 'boundary-plan))))))

;; Context helpers preserve canonical Scheme-readable record shape.
(testing-registry-case
 'context-boundary-request-record '(portable core)
(test-equal 'context-boundary-request-record
             'request-context
             (car (context:make-request-context 'portable-req
                                          #f
                                          "portable request"))))

;; Portable redaction records never reveal the original secret.
(define portable-secret
  '((source env)
    (field "OPENAI_API_KEY")
    (value "sk-portablesecret1234567890")))

;; Redacted portable secret datum used for boundary checks.
(define redacted-secret
  (redaction:redact portable-secret 'remote-provider))

(testing-registry-case
 'redaction-boundary-secret-source '(portable core)
(test-equal 'redaction-boundary-secret-source
             #t
             (redaction:secret-source? portable-secret)))

(testing-registry-case
 'redaction-boundary-redact-record '(portable core)
(test-equal 'redaction-boundary-redact-record
             'redaction
             (car redacted-secret)))

(testing-registry-case
 'redaction-boundary-provider-safe '(portable core)
(test-equal 'redaction-boundary-provider-safe
             #f
             (redaction:safe-for-provider? portable-secret 'openai)))

(testing-registry-case
 'redaction-boundary-local-only-provider-safe '(portable core)
(test-equal 'redaction-boundary-local-only-provider-safe
             #f
             (redaction:safe-for-provider?
        (redaction:context-local-only!
         '((buffer "private-notes") (text "do not send"))
         "private buffer")
        'openai)))

;; Store for exercising the portable session lifecycle boundary.
(define session-store (session:consent-make-session-store))

;; Session datum created through the portable session module.
(define portable-session
  (session:session-store-create! session-store
                                 'named
                                 '((id portable-main))))

(testing-registry-case
 'session-boundary-create-ref '(portable core)
(test-equal 'session-boundary-create-ref
             'portable-main
             (session:session-datum-id
        (session:session-store-ref session-store 'portable-main))))

(testing-registry-case
 'session-boundary-snapshot '(portable core)
(test-equal 'session-boundary-snapshot
             'session-snapshot
             (car (session:session-store-snapshot! session-store
                                       'portable-main
                                       '((id portable-snap))))))

;; Task lifecycle records are canonical datums with explicit transitions.
(define portable-task
  (task:make-agent-task 'portable-task
                        "Validate portable task lifecycle records."
                        'portable-main
                        '((plan . portable-plan)
                          (transcript . portable-transcript)
                          (budget . (task-budget (max-steps 100)))
                          (audit . portable-audit))))

;; Portable pause receipt under test.
(define portable-pause
  (task:make-task-pause
   'portable-task
   'waiting-for-host
   'host-effect-timeout
   '((observed-state . (observation-set obs-portable))
     (intended-next-action . action-portable)
     (capability-gate . none)
     (model-route . none)
     (approval-store-status . none)
     (verifier-result . not-run))))

(testing-registry-case
 'task-boundary-transition-allowed '(portable core)
(test-equal 'task-boundary-transition-allowed
             #t
             (task:task-transition-allowed? 'created 'observing)))

(testing-registry-case
 'task-boundary-transition-rejected '(portable core)
(test-equal 'task-boundary-transition-rejected
             #f
             (task:task-transition-allowed? 'created 'complete)))

(testing-registry-case
 'task-boundary-task-record '(portable core)
(test-equal 'task-boundary-task-record
             #t
             (task:agent-task? portable-task)))

(testing-registry-case
 'task-boundary-pause-record '(portable core)
(test-equal 'task-boundary-pause-record
             #t
             (task:task-pause? portable-pause)))

(testing-registry-case
 'task-boundary-record-valid '(portable core)
(test-equal 'task-boundary-record-valid
             #t
             (task:task-record-valid? portable-task)))

(testing-registry-case
 'task-boundary-invalid-transition-raises '(portable core)
(test-equal 'task-boundary-invalid-transition-raises
             #t
             (raises?
        (lambda ()
          (task:validate-task-transition 'created 'complete)))))

(testing-registry-case
 'interpreter-boundary '(portable core)
(test-equal 'interpreter-boundary
             "3"
             (interpreter:consent-value->external
        (interpreter:consent-eval-source "(+ 1 2)"))))

(testing-runner-main "Consent Module Boundary portable tests" (command-line))
