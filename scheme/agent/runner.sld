;;; Public Consent Scheme minimal task runner control loop.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral minimal control loop that turns one user
;;; goal into a running task: it creates an `(agent task)' record, walks it
;;; deterministically through `observing', `planning', and `acting', routes a
;;; (fake but shape-correct) model provider request, reads model proposals
;;; through the `(agent proposal)' boundary, gates host effects through a
;;; policy
;;; decision, and stops or pauses with an inspectable `task-stop'/`task-pause'
;;; receipt. The loop is deterministic around policy and state transitions even
;;; though model output is nondeterministic: all nondeterministic inputs
;;; (provider responses, policy decisions, the verifier verdict, control
;;; directives) are injected as data so a run is replayable and cross-host
;;; identical.
;;;
;;; Two consent invariants are load-bearing here.  D2 (the proposal-datum
;;; boundary, owned by `(agent proposal)'): a model's emitted form is read and
;;; walked as data, never `eval'd as authority, and a control-plane sub-form is
;;; quarantined with no effect.  D3 (completion authority): a model may PROPOSE
;;; `finish', but only a deterministic, non-proposable verifier authorizes the
;;; `acting -> complete' transition; a self-asserted pass never reaches
;;; `complete'.  Both are documented in docs/control-loop.md.
;;;
;;; The library is host-neutral and single-sourced like `(agent registry)': the
;;; Emacs interpreter and the portable hosts load this same Scheme source. It
;;; is
;;; deliberately small -- one observation, one plan, a bounded acting loop,
;;; fake
;;; providers, and no persistence, scheduling, parallelism, streaming UI, or
;;; provider matrix.  Those expansions are tracked as follow-up issues in
;;; docs/control-loop.md.

(define-library (agent runner)
  (export run-task
          task-run?
          task-run-field-value
          task-run-task
          task-run-state
          task-run-receipt
          task-run-completion
          task-run-steps
          task-run-observations
          task-run-transcript
          task-run-budget)
  (import (scheme base)
          (agent task)
          (agent transcript)
          (agent proposal))
  (begin
    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT when KEY is absent.  OPTIONS entrie\
s"
      "may be dotted alist cells or two-element option records."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (field-named? field name)
      "Return #t when FIELD is a record field named NAME."
      (and (pair? field) (eq? (car field) name)))

    (define (record-field-value record name default)
      "Return RECORD field NAME, or DEFAULT when the field is absent."
      (let loop ((fields (cdr record)))
        (cond
         ((null? fields) default)
         ((field-named? (car fields) name) (cadr (car fields)))
         (else (loop (cdr fields))))))

    (define (prefix-string prefix)
      "Return PREFIX as a string for deterministic id construction."
      (cond
       ((string? prefix) prefix)
       ((symbol? prefix) (symbol->string prefix))
       (else "task")))

    (define (make-id prefix tag index)
      "Return a deterministic id symbol from PREFIX, TAG, and INDEX."
      (string->symbol
       (string-append prefix "-" tag "-" (number->string index))))

    (define (spec-arg spec index)
      "Return element INDEX of proposal SPEC, or #f when SPEC is shorter."
      (let loop ((rest spec) (n index))
        (cond
         ((null? rest) #f)
         ((= n 0) (car rest))
         (else (loop (cdr rest) (- n 1))))))

    (define (any-failed? requests effect-status)
      "Return #t when any REQUEST's operation maps to a failed EFFECT-STATUS."
      (cond
       ((null? requests) #f)
       ((eq? (effect-status (request-operation (car requests))) 'failed) #t)
       (else (any-failed? (cdr requests) effect-status))))

    (define (request-operation request)
      "Return the operation symbol named by a capability-request datum."
      (proposal-field-value request 'operation))

    (define (run-task goal options)
      "Run the minimal control loop for GOAL and return a task-run record."
      #((parameters
         (goal . "The user goal datum the task pursues.")
         (options (type list)
          (description
           ("Association list of injected, deterministic inputs:"
             "`session', `scope', `observation' (the read-only"
             "observation value), `provider' (a list of proposal step"
             "specs, each `(finish VALUE)', `(code-action FORM)', or"
             "`(model-unavailable REASON)'), `policy' (alist of"
             "`(operation status)' capability decisions plus a"
             "`default', status one of"
             "`approved', `needs-approval', `needs-user-input',"
             "`host-pending', `authority-missing', `stale', or"
             "`denied'),"
             "`verifier' (`passed' or `insufficient', the non-proposable"
             "completion verdict), `effects' (alist of `(operation"
             "ok\|failed)' performed-effect outcomes), `control' (list of"
             "directives such as `cancel'), `operations' (the `(agent"
             "proposal)' host-operation table), `capability-signatures'"
             "(model-tool capability signatures),"
             "`max-steps'/`max-pure-cost' budgets, and `id-prefix')."))))
        (returns (type task-run)
         (description
          ("A `task-run' record bundling the final `agent-task', the"
            "final state, the `task-stop'/`task-pause' receipt, an"
            "`agent-completion' (or `none'), the recorded"
            "step/observation/decision lists, the transcript events,"
            "and the budget ledger.")))
        (effects allocation))
      (let* ((session (option-ref options 'session 'project-main))
             (scope (option-ref options 'scope 'project))
             (id-prefix (prefix-string (option-ref options 'id-prefix 'task)))
             (task-id (make-id id-prefix "task" 1))
             (transcript-id (make-id id-prefix "transcript" 1))
             (observation-value
              (option-ref options 'observation
                          '(observation (kind read-only)
                                        (value project-clean))))
             (provider-steps (option-ref options 'provider '()))
             (policy (option-ref options 'policy '()))
             (effects (option-ref options 'effects '()))
             (control (option-ref options 'control '()))
             (operations (option-ref options 'operations '()))
             (capability-signatures
              (option-ref options 'capability-signatures
                          (option-ref options 'signatures '())))
             (verifier-verdict (option-ref options 'verifier 'insufficient))
             (max-steps (option-ref options 'max-steps 8))
             (max-pure-cost (option-ref options 'max-pure-cost 100000)))
        (let ((state 'created)
              (plan 'none)
              (current-step 'none)
              (completion 'none)
              (steps '())
              (observations '())
              (decisions '())
              (events '())
              (used-steps 0)
              (used-host-calls 0)
              (used-pure-cost 0)
              (event-counter 0)
              (step-counter 0)
              (obs-counter 0)
              (dec-counter 0)
              (plan-counter 0))
          (define (advance! next)
            "Validate and apply the FROM->NEXT lifecycle transition."
            (set! state (validate-task-transition state next))
            state)
          (define (emit! kind fields)
            "Append a transcript event of KIND carrying FIELDS."
            (set! event-counter (+ event-counter 1))
            (set! events
                  (cons (make-transcript-event
                         kind
                         (cons (list 'id (make-id id-prefix "ev"
                           event-counter))
                               (cons (list 'session session) fields)))
                        events)))
          (define (record-observation! source kind value)
            "Append an agent-observation for SOURCE, KIND, and VALUE."
            (set! obs-counter (+ obs-counter 1))
            (set! observations
                  (cons (make-agent-observation
                         (make-id id-prefix "obs" obs-counter)
                         task-id source kind value '())
                        observations)))
          (define (record-step! step-id attempt selected-action)
            "Append an agent-step and the agent-decision that selected ACTION.\
"
            (set! steps
                  (cons (make-agent-step step-id task-id goal
                                         (list (list 'state 'acting)
                                               (list 'attempt attempt)))
                        steps))
            (set! dec-counter (+ dec-counter 1))
            (set! decisions
                  (cons (make-agent-decision
                         (make-id id-prefix "dec" dec-counter)
                         task-id step-id 'observed selected-action
                         "selected from the model provider proposal"
                         '())
                        decisions)))
          (define (policy-status operation)
            "Return the capability decision status for OPERATION."
            (option-ref policy operation
                        (option-ref policy 'default 'approved)))
          (define (effect-status operation)
            "Return the performed-effect outcome for OPERATION."
            (option-ref effects operation
                        (option-ref effects 'default 'ok)))
          (define (cancel-requested?)
            "Return #t when a control directive cancels the run."
            (and (memq 'cancel control) #t))
          (define (governing-decision requests)
            "Return (STATUS . REQUEST) for the first non-approved request."
            (let loop ((rest requests))
              (cond
               ((null? rest) (cons 'approved #f))
               (else
                (let ((status (policy-status
                               (request-operation (car rest)))))
                  (if (eq? status 'approved)
                      (loop (cdr rest))
                      (cons status (car rest))))))))
          (define (policy-denial-decision request)
            "Return a denied capability-decision for unauthorized REQUEST."
            (list 'capability-decision
                  (list 'id (make-id id-prefix "policy-denial" 1))
                  (list 'request request)
                  (list 'status 'denied)
                  (list 'operation (request-operation request))
                  (list 'reason 'unauthorized-tool)))
          (define (finish-stop final-state reason receipt-options)
            "Advance to terminal FINAL-STATE and build a task-stop receipt."
            (advance! final-state)
            (make-task-stop task-id final-state reason receipt-options))
          (define (finish-pause final-state reason receipt-options)
            "Advance to resumable FINAL-STATE and build a task-pause receipt."
            (advance! final-state)
            (make-task-pause task-id final-state reason receipt-options))
          (define (build-plan!)
            "Create and record the task plan, returning the plan datum."
            (set! plan-counter (+ plan-counter 1))
            (let ((plan-id (make-id id-prefix "plan" plan-counter)))
              (set! plan
                    (list 'agent-plan
                          (list 'id plan-id)
                          (list 'goal goal)
                          (list 'status 'active)
                          (list 'steps
                                (list (list 'plan-step
                                            (list 'id (make-id id-prefix
                                                                "plan-step"
                                                                plan-counter))
                                            (list 'description
                                                  "advance the goal")
                                            (list 'status 'pending))))))
              plan))
          (define (perform-effects requests rest)
            "Perform approved REQUESTS as fake effects, then continue the loop\
."
            (if (any-failed? requests effect-status)
                (finish-stop 'failed 'condition-failed
                             (list (list 'observed-state 'action-failed)))
                (begin
                  (for-each
                   (lambda (request)
                     (set! used-host-calls (+ used-host-calls 1))
                     (emit! 'capability-call
                            (list (list 'operation
                                        (request-operation request))
                                  (list 'status 'performed)))
                     (record-observation! (request-operation request)
                                          'effect-result
                                          (list 'performed
                                                (request-operation request))))
                   requests)
                  (continue-loop rest))))
          (define (resolve-requests requests rest)
            "Route REQUESTS through policy and dispatch on the governing statu\
s."
            (let* ((decision (governing-decision requests))
                   (status (car decision))
                   (request (cdr decision)))
              (cond
               ((eq? status 'needs-approval)
                (emit! 'approval-request
                       (list (list 'operation (request-operation request))))
                (finish-pause 'waiting-for-approval 'approval-required
                              (list (list 'capability-gate request)
                                    (list 'approval-status
                                          '(approval (status pending))))))
               ((eq? status 'needs-user-input)
                (emit! 'agent-request
                       (list (list 'operation (request-operation request))))
                (finish-pause 'blocked 'waiting-for-user-input
                              (list (list 'capability-gate request)
                                    (list 'observed-state
                              'awaiting-user-input))))
               ((eq? status 'host-pending)
                (finish-pause 'waiting-for-host 'host-effect-timeout
                              (list (list 'capability-gate request)
                                    (list 'observed-state
                              'host-effect-pending))))
               ((or (eq? status 'authority-missing) (eq? status 'stale))
                (finish-pause 'blocked 'authority-unavailable
                              (list (list 'capability-gate request)
                                    (list 'observed-state status))))
               ((eq? status 'denied)
                (let ((decision (policy-denial-decision request)))
                  (finish-stop 'cancelled 'approval-denied
                               (list (list 'capability-gate decision)
                                     (list 'observed-state 'denied)
                                     (list 'intended-next-action
                                           (request-operation request))
                                   (list 'approval-status
                                         '(approval (status denied)))))))
               (else (perform-effects requests rest)))))
          (define (act-code-action form rest)
            "Analyze FORM at the proposal boundary and act on the verdict."
            (let ((analysis
                   (analyze-code-action
                    form
                    (list (list 'operations operations)
                          (list 'capability-signatures capability-signatures)
                          (list 'max-pure-cost max-pure-cost)
                          (list 'id-prefix id-prefix)))))
              (set! used-pure-cost
                    (+ used-pure-cost (analysis-pure-cost analysis)))
              (cond
               ((eq? (analysis-status analysis) 'quarantined)
                (finish-stop 'failed 'condition-failed
                             (list (list 'observed-state
                                         (list 'quarantine
                                               (analysis-quarantine-decisions
                                                analysis))))))
               ((eq? (analysis-status analysis) 'budget-exhausted)
                (finish-stop 'failed 'budget-exhausted
                             (list (list 'observed-state
                                         'proposal-budget-exhausted))))
               ((eq? (analysis-status analysis) 'rejected)
                (let ((failures (analysis-failure-decisions analysis)))
                  (finish-stop 'failed 'condition-failed
                               (list (list 'observed-state
                                           (list 'admission-failure failures))
                                     (list 'capability-gate
                                           (if (null? failures)
                                               'none
                                               (car failures)))
                                     (list 'intended-next-action
                                           (if (null? failures)
                                               'none
                                               (proposal-field-value
                                                (car failures)
                                                'operation)))))))
               (else
                (resolve-requests (analysis-capability-requests analysis)
                                  rest)))))
          (define (act-finish value)
            "Apply the non-proposable verifier to a proposed finish."
            (let ((verifier-result (list 'verifier-result
                                         (list 'status verifier-verdict))))
              (if (eq? verifier-verdict 'passed)
                  (let ((stop (finish-stop 'complete 'completed-goal
                                           (list (list 'verifier-result
                                                       verifier-result)
                                                 (list 'observed-state
                                                       'goal-verified)))))
                    (set! completion
                          (make-agent-completion
                           task-id value stop
                           (list (list 'transcript transcript-id))))
                    stop)
                  (finish-pause 'blocked 'insufficient-evidence
                                (list (list 'verifier-result verifier-result)
                                      (list 'observed-state
                              'goal-unverified))))))
          (define (dispatch spec rest)
            "Dispatch the acting step on proposal SPEC."
            (cond
             ((eq? (car spec) 'model-unavailable)
              (finish-pause 'waiting-for-model 'model-provider-unavailable
                            (list (list 'observed-state 'provider-error)
                                  (list 'model-route
                                        (list 'model-provider-error
                                              (list 'status 'unavailable)
                                              (list 'reason
                                                    (spec-arg spec 1)))))))
             ((eq? (car spec) 'finish) (act-finish (spec-arg spec 1)))
             ((eq? (car spec) 'code-action)
              (act-code-action (spec-arg spec 1) rest))
             (else
              (finish-stop 'failed 'condition-failed
                           (list (list 'observed-state
                                       (list 'unknown-proposal (car
                              spec))))))))
          (define (drive provider-rest attempt)
            "Run one bounded acting iteration over PROVIDER-REST."
            (cond
             ((cancel-requested?)
              (finish-stop 'cancelled 'cancelled-by-user
                           (list (list 'observed-state 'cancelled))))
             ((>= used-steps max-steps)
              (finish-stop 'failed 'budget-exhausted
                           (list (list 'observed-state
                             'step-budget-exhausted))))
             ((null? provider-rest)
              (finish-pause 'blocked 'insufficient-evidence
                            (list (list 'observed-state 'no-proposal))))
             (else
              (advance! 'acting)
              (set! used-steps (+ used-steps 1))
              (set! step-counter (+ step-counter 1))
              (let ((step-id (make-id id-prefix "step" step-counter))
                    (spec (car provider-rest)))
                (set! current-step step-id)
                (emit! 'model-route
                       (list (list 'role 'planner)
                             (list 'provider 'fake-local)
                             (list 'kind (car spec))))
                (record-step! step-id attempt (car spec))
                (dispatch spec (cdr provider-rest))))))
          (define (continue-loop provider-rest)
            "Return to observing/planning, then drive the next acting step."
            (advance! 'observing)
            (record-observation! 'runner 'progress '(observation (kind step)))
            (advance! 'planning)
            (build-plan!)
            (drive provider-rest (+ used-steps 1)))
          ;; Create the task and emit the opening yield.
          (set! state 'created)
          (emit! 'agent-yield (list (list 'value goal)))
          ;; Observe: one read-only observation through the policy path.
          (advance! 'observing)
          (record-observation! 'runner 'read-only observation-value)
          (emit! 'agent-progress (list (list 'phase 'observing)))
          ;; Plan: produce the task plan.
          (advance! 'planning)
          (build-plan!)
          (emit! 'agent-progress (list (list 'phase 'planning)))
          ;; Act: drive the bounded loop and capture the receipt.
          (let ((receipt (drive provider-steps 1)))
            (let ((final-task
                   (make-agent-task
                    task-id goal session
                    (list (list 'state state)
                          (list 'scope scope)
                          (list 'plan plan)
                          (list 'current-step current-step)
                          (list 'transcript transcript-id)))))
              (list 'task-run
                    (list 'task final-task)
                    (list 'state state)
                    (list 'receipt receipt)
                    (list 'completion completion)
                    (list 'steps (reverse steps))
                    (list 'observations (reverse observations))
                    (list 'decisions (reverse decisions))
                    (list 'transcript (reverse events))
                    (list 'budget
                          (list 'task-budget
                                (list 'max-steps max-steps)
                                (list 'used-steps used-steps)
                                (list 'used-host-calls used-host-calls)
                                (list 'used-pure-cost used-pure-cost)))))))))

    (define (task-run? datum)
      "Return #t when DATUM is a task-run record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
           ("#t when DATUM is tagged as a `task-run'; otherwise #f.")))
        (effects pure))
      (and (pair? datum) (eq? (car datum) 'task-run)))

    (define (task-run-field-value record name . maybe-default)
      "Return RECORD field NAME, or DEFAULT when the field is absent."
      #((parameters
         (record (type task-run)
          (description "A `task-run' record."))
         (name (type symbol)
          (description "Symbol naming the field to read."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . "The field value, or DEFAULT when NAME is absent.")
        (effects pure))
      (record-field-value record name
                          (if (null? maybe-default) #f (car maybe-default))))

    (define (task-run-task run)
      "Return the final agent-task datum from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type agent-task)
         (description "The final `agent-task' datum."))
        (effects pure))
      (record-field-value run 'task 'none))

    (define (task-run-state run)
      "Return the final lifecycle state from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type symbol)
         (description "The final task state symbol."))
        (effects pure))
      (record-field-value run 'state 'none))

    (define (task-run-receipt run)
      "Return the terminal task-stop or task-pause receipt from a task-run."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type (or task-stop task-pause))
         (description "The `task-stop' or `task-pause' receipt datum."))
        (effects pure))
      (record-field-value run 'receipt 'none))

    (define (task-run-completion run)
      "Return the agent-completion datum, or `none', from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type (or agent-completion symbol))
         (description
          ("The `agent-completion' datum when the task completed;"
            "otherwise `none'.")))
        (effects pure))
      (record-field-value run 'completion 'none))

    (define (task-run-steps run)
      "Return the recorded agent-step list from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type (list-of agent-step))
         (description "A list of `agent-step' datums in execution order."))
        (effects pure))
      (record-field-value run 'steps '()))

    (define (task-run-observations run)
      "Return the recorded agent-observation list from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type (list-of agent-observation))
         (description
           ("A list of `agent-observation' datums in execution order.")))
        (effects pure))
      (record-field-value run 'observations '()))

    (define (task-run-transcript run)
      "Return the transcript event list from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type (list-of transcript-event))
         (description
           ("A list of `transcript-event' datums in emission order.")))
        (effects pure))
      (record-field-value run 'transcript '()))

    (define (task-run-budget run)
      "Return the budget ledger datum from a task-run record."
      #((parameters
         (run (type task-run)
          (description "A `task-run' record.")))
        (returns (type task-budget)
         (description
          ("The `task-budget' ledger datum recording step, host-call,"
            "and pure-cost usage.")))
        (effects pure))
      (record-field-value run 'budget 'none))))
