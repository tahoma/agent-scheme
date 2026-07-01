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
        (prefix (consent interpreter) interpreter:))

;; Record one failed portable module-boundary check.
(define failures 0)

;; Record one failed portable module-boundary check and keep running.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Report whether THUNK raises a Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(check 'runtime-boundary
       (procedure? runtime:consent-make-empty-environment)
       #t)

(check 'base-boundary
       (if (memq '+ (base:consent-base-primitive-names)) #t #f)
       #t)

(check 'library-boundary
       (pair? (library:consent-standard-source-library-specs))
       #t)

(check 'macro-boundary
       (procedure? macro:consent-expand-source)
       #t)

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

(check 'approval-boundary-request-status
       (approval:approval-store-status approval-store portable-approval-id)
       'pending)

(check 'approval-boundary-pending
       (length (approval:approval-store-pending approval-store))
       1)

(approval:approval-store-resolve! approval-store portable-approval-id 'denied)

(check 'approval-boundary-resolved-status
       (approval:approval-store-status approval-store portable-approval-id)
       'denied)

(check 'approval-boundary-cancel-resolved-denied
       (raises?
        (lambda ()
          (approval:approval-store-cancel! approval-store portable-approval-id)))
       #t)

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

(check 'job-boundary-start-status
       (job:job-store-status job-store portable-job-id)
       'queued)

(job:job-store-mark-running! job-store portable-job-id)
(job:job-store-record-yield! job-store portable-job-id '(yield (phase ready)))

(check 'job-boundary-stream-yield
       (job:job-store-yields job-store portable-job-id '())
       '((yield (phase ready))))

(job:job-store-cancel! job-store portable-job-id)

(check 'job-boundary-cancel-requested
       (job:job-store-status job-store portable-job-id)
       'cancel-requested)

(job:job-store-finish-cancelled! job-store
                                  portable-job-id
                                  "job cancelled: j-1")

(check 'job-boundary-cancelled-status
       (job:job-store-status job-store portable-job-id)
       'cancelled)

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

(check 'memory-boundary-put-ref
       (memory:memory-record-id
        (memory:memory-store-ref memory-store 'instance 'portable-key))
       'portable-key)

(check 'memory-boundary-by-tag
       (length (memory:memory-store-by-tag memory-store 'instance 'portable))
       1)

(check 'memory-boundary-find
       (length (memory:memory-store-find memory-store
                                         'instance
                                         "portable memory"))
       1)

;; Store for exercising the portable helper/artifact boundary.
(define helper-store (helper:consent-make-helper-store))

;; Helper libraries and artifacts are canonical Scheme-readable datums.
(define portable-helper
  (helper:helper-store-save! helper-store
                             'session
                             '(agent helpers portable)
                             '((define (portable-helper x) (+ x 1)))
                             '(session portable-main)))

(check 'helper-boundary-save-ref
       (helper:helper-record-name
        (helper:helper-store-ref helper-store
                                 'session
                                 '(agent helpers portable)))
       '(agent helpers portable))

(check 'helper-boundary-list-is-scoped
       (length (helper:helper-store-list helper-store 'session))
       1)

;; Artifact record used for exercising portable helper artifact storage.
(define portable-artifact
  (helper:helper-store-artifact-save! helper-store
                                      'session
                                      'example
                                      '(example
                                        (source "(portable-helper 41)")
                                        (expect "42"))
                                      '(session portable-main)))

(check 'helper-boundary-artifact-record
       (car portable-artifact)
       'agent-artifact)

(check 'helper-boundary-skill-candidate
       (car (helper:helper-promote-to-skill
             portable-helper
             '((name "portable-helper")
               (examples ((example (source "(portable-helper 41)")
                                   (expect "42"))))
               (references ((r7rs "docs/r7rs-small-report.md")))
               (tests (((source "(portable-helper 41)") (expect "42")))))))
       'agent-skill-candidate)

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

(check 'plan-boundary-ref
       (plan:plan-record-id
        (plan:plan-store-ref plan-store 'boundary-plan))
       'boundary-plan)

(plan:plan-store-step-status! plan-store 'boundary-plan 'first 'done)

(check 'plan-boundary-step-status
       (plan:plan-step-status
        (car (plan:plan-record-steps
              (plan:plan-store-ref plan-store 'boundary-plan))))
       'done)

;; Context helpers preserve canonical Scheme-readable record shape.
(check 'context-boundary-request-record
       (car (context:make-request-context 'portable-req
                                          #f
                                          "portable request"))
       'request-context)

;; Portable redaction records never reveal the original secret.
(define portable-secret
  '((source env)
    (field "OPENAI_API_KEY")
    (value "sk-portablesecret1234567890")))

;; Redacted portable secret datum used for boundary checks.
(define redacted-secret
  (redaction:redact portable-secret 'remote-provider))

(check 'redaction-boundary-secret-source
       (redaction:secret-source? portable-secret)
       #t)

(check 'redaction-boundary-redact-record
       (car redacted-secret)
       'redaction)

(check 'redaction-boundary-provider-safe
       (redaction:safe-for-provider? portable-secret 'openai)
       #f)

(check 'redaction-boundary-local-only-provider-safe
       (redaction:safe-for-provider?
        (redaction:context-local-only!
         '((buffer "private-notes") (text "do not send"))
         "private buffer")
        'openai)
       #f)

;; Store for exercising the portable session lifecycle boundary.
(define session-store (session:consent-make-session-store))

;; Session datum created through the portable session module.
(define portable-session
  (session:session-store-create! session-store
                                 'named
                                 '((id portable-main))))

(check 'session-boundary-create-ref
       (session:session-datum-id
        (session:session-store-ref session-store 'portable-main))
       'portable-main)

(check 'session-boundary-snapshot
       (car (session:session-store-snapshot! session-store
                                       'portable-main
                                       '((id portable-snap))))
       'session-snapshot)

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

(check 'task-boundary-transition-allowed
       (task:task-transition-allowed? 'created 'observing)
       #t)

(check 'task-boundary-transition-rejected
       (task:task-transition-allowed? 'created 'complete)
       #f)

(check 'task-boundary-task-record
       (task:agent-task? portable-task)
       #t)

(check 'task-boundary-pause-record
       (task:task-pause? portable-pause)
       #t)

(check 'task-boundary-record-valid
       (task:task-record-valid? portable-task)
       #t)

(check 'task-boundary-invalid-transition-raises
       (raises?
        (lambda ()
          (task:validate-task-transition 'created 'complete)))
       #t)

(check 'interpreter-boundary
       (interpreter:consent-value->external
        (interpreter:consent-eval-source "(+ 1 2)"))
       "3")

(if (= failures 0)
    (begin
      (display "Scheme module-boundary tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme module-boundary test failure(s)")
      (newline)
      (error "Scheme module-boundary tests failed")))
