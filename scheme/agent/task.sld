;;; Public Consent Scheme task lifecycle records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral `(agent task)' record vocabulary:
;;; task, step, action, observation, decision, pause, stop, wait, failure, and
;;; completion datums.  Hosts and providers are referenced by printable ids and
;;; records; raw host objects never enter this surface.

(define-library (agent task)
  (export task-states
          task-pause-states
          task-terminal-states
          task-allowed-transitions
          task-pause-reasons
          task-stop-reasons
          task-state?
          task-transition-allowed?
          validate-task-transition
          make-task-condition
          task-field-value
          task-record?
          agent-task?
          agent-step?
          agent-action?
          agent-observation?
          agent-decision?
          task-pause?
          task-stop?
          task-wait?
          task-failure?
          agent-completion?
          task-record-valid?
          validate-task-record
          make-agent-task
          make-agent-step
          make-agent-action
          make-agent-observation
          make-agent-decision
          make-task-pause
          make-task-stop
          make-task-wait
          make-task-failure
          make-agent-completion)
  (import (scheme base))
  (begin
    ;; Public task states are symbols so tasks can be persisted and replayed as
    ;; ordinary Scheme data.
    (define task-states
      '(created observing planning acting waiting-for-approval
                waiting-for-model waiting-for-host blocked cancelled failed
                complete))

    ;; Pause states are resumable states that should carry a `task-pause'
    ;; receipt rather than a terminal receipt.
    (define task-pause-states
      '(waiting-for-approval waiting-for-model waiting-for-host blocked))

    ;; Terminal states are immutable stop receipt states.
    (define task-terminal-states
      '(cancelled failed complete))

    ;; Allowed transitions are intentionally narrow and match the control-loop
    ;; architecture table.
    (define task-allowed-transitions
      '((created observing cancelled)
        (observing planning waiting-for-host blocked failed cancelled)
        (planning acting waiting-for-model blocked failed cancelled)
        (acting observing waiting-for-approval waiting-for-host
                waiting-for-model blocked complete failed cancelled)
        (waiting-for-approval acting blocked cancelled)
        (waiting-for-model planning acting blocked failed cancelled)
        (waiting-for-host observing acting blocked failed cancelled)
        (blocked observing planning acting cancelled)))

    ;; Pause reasons explain why a resumable task cannot proceed now.
    (define task-pause-reasons
      '(approval-required waiting-for-user-input authority-unavailable
                          model-provider-unavailable host-effect-timeout
                          insufficient-evidence))

    ;; Stop reasons explain why a terminal task performed no further work.
    (define task-stop-reasons
      '(completed-goal waiting-for-user-input approval-denied
                       authority-unavailable budget-exhausted
                       repeated-failed-action model-provider-unavailable
                       host-effect-timeout cancelled-by-user condition-failed
                       insufficient-evidence))

    ;; Required fields keep record validation stable across host adapters and
    ;; persistence readers.
    (define task-required-fields
      '((agent-task id state goal session scope created-at updated-at
                    resumed-from parent children context memory rules skills
                    patterns plan current-step budget provider-routes
                    capability-environment transcript audit)
        (agent-step id task state goal plan-item attempt observations decision
                    action events result)
        (agent-action id task step kind library binding arguments requires
                      expected-outcome)
        (agent-observation id task source kind value redactions audit)
        (agent-decision id task step observed-state selected-action reason
                        policy-input model-input rules-input verifier-result)
        (task-pause task state observed-state intended-next-action
                    capability-gate model-route approval-status
                    verifier-result pause-reason)
        (task-stop task state observed-state intended-next-action
                   capability-gate model-route approval-status
                   verifier-result stop-reason)
        (task-wait task state wait-kind request started-at budget transcript
                   audit)
        (task-failure task state condition retry transcript audit)
        (agent-completion task status value stop transcript audit)))

    (define (member-eq? value values)
      "Return #t when VALUE is a member of VALUES using eq?."
      (cond
       ((null? values) #f)
       ((eq? value (car values)) #t)
       (else (member-eq? value (cdr values)))))

    (define (task-state? state)
      "Return #t when STATE is part of the public task lifecycle vocabulary."
      #((parameters
         (state
          (type any)
          (description
           ("Symbol to check against the task lifecycle vocabulary."))))
        (returns
         (type any)
         (description "#t when STATE is a public task state; otherwise #f."))
        (effects pure))
      (member-eq? state task-states))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT if absent.  OPTIONS may contain"
      "dotted alist cells or two-element Scheme option records."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (portable-timestamp)
      "Return a portable placeholder timestamp for host-neutral constructors."
      "portable")

    (define (make-task-condition kind fields)
      "Return a Scheme-readable task condition datum."
      #((parameters
         (kind
          (type any)
          (description "Condition kind symbol."))
         (fields
          (type any)
          (description "Association list of condition fields.")))
        (returns
         (type any)
         (description
          ("A `task-condition` datum suitable for an error irritant.")))
        (effects pure))
      (cons 'task-condition
            (cons (list 'kind kind)
                  (map (lambda (field)
                         (list (car field) (cdr field)))
                       fields))))

    (define (raise-task-error kind fields)
      "Raise a task lifecycle error carrying a structured condition datum."
      (error "consent-task" (make-task-condition kind fields)))

    (define (normalize-state state)
      "Validate and return STATE."
      (if (task-state? state)
          state
          (raise-task-error 'unknown-state
                            (list (cons 'state state)))))

    (define (task-transition-allowed? from to)
      "Return #t when task state FROM may transition to TO."
      #((parameters
         (from
          (type any)
          (description "Current task state symbol."))
         (to
          (type any)
          (description "Proposed next task state symbol.")))
        (returns
         (type any)
         (description
          ("#t when the transition is part of the public lifecycle"
           "table; otherwise #f.")))
        (effects pure))
      (let ((row (assq from task-allowed-transitions)))
        (if (and (task-state? from) (task-state? to) row)
            (member-eq? to (cdr row))
            #f)))

    (define (validate-task-transition from to)
      "Validate transition FROM to TO and return TO."
      #((parameters
         (from
          (type any)
          (description "Current task state symbol."))
         (to
          (type any)
          (description "Proposed next task state symbol.")))
        (returns
         (type any)
         (description "TO when the transition is valid."))
        (effects error)
        (see-also task-transition-allowed?))
      (let ((from-state (normalize-state from))
            (to-state (normalize-state to)))
        (if (task-transition-allowed? from-state to-state)
            to-state
            (raise-task-error
             'invalid-transition
             (list (cons 'from from-state)
                   (cons 'to to-state))))))

    (define (field-named? field name)
      "Return #t when FIELD is a record field named NAME."
      (and (pair? field) (eq? (car field) name)))

    (define (field-present? record name)
      "Return #t when RECORD has a field named NAME."
      (let loop ((fields (cdr record)))
        (cond
         ((null? fields) #f)
         ((field-named? (car fields) name) #t)
         (else (loop (cdr fields))))))

    (define (task-field-value record name . maybe-default)
      "Return RECORD field NAME, or DEFAULT when absent."
      #((parameters
         (record
          (type any)
          (description "Task lifecycle record represented as a tagged list."))
         (name
          (type any)
          (description "Symbol naming the field to read."))
         (maybe-default
          (type any)
          (description "Optional fallback value; defaults to #f.")))
        (returns
         (type any)
         (description "The field value, or DEFAULT when NAME is absent."))
        (effects pure))
      (let ((default (if (null? maybe-default) #f (car maybe-default))))
        (let loop ((fields (cdr record)))
          (cond
           ((null? fields) default)
           ((field-named? (car fields) name) (cadr (car fields)))
           (else (loop (cdr fields)))))))

    (define (task-record? datum tag)
      "Return #t when DATUM is a task lifecycle record tagged TAG."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect."))
         (tag
          (type any)
          (description "Expected task record tag symbol.")))
        (returns
         (type any)
         (description "#t when DATUM is a pair tagged by TAG; otherwise #f."))
        (effects pure))
      (and (pair? datum) (eq? (car datum) tag)))

    (define (agent-task? datum)
      "Return #t when DATUM is an agent-task record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as an agent-task; otherwise #f.")))
        (effects pure))
      (task-record? datum 'agent-task))

    (define (agent-step? datum)
      "Return #t when DATUM is an agent-step record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as an agent-step; otherwise #f.")))
        (effects pure))
      (task-record? datum 'agent-step))

    (define (agent-action? datum)
      "Return #t when DATUM is an agent-action record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as an agent-action; otherwise #f.")))
        (effects pure))
      (task-record? datum 'agent-action))

    (define (agent-observation? datum)
      "Return #t when DATUM is an agent-observation record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as an agent-observation; otherwise"
           "#f.")))
        (effects pure))
      (task-record? datum 'agent-observation))

    (define (agent-decision? datum)
      "Return #t when DATUM is an agent-decision record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as an agent-decision; otherwise"
           "#f.")))
        (effects pure))
      (task-record? datum 'agent-decision))

    (define (task-pause? datum)
      "Return #t when DATUM is a task-pause receipt."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a task-pause receipt; otherwise"
           "#f.")))
        (effects pure))
      (task-record? datum 'task-pause))

    (define (task-stop? datum)
      "Return #t when DATUM is a task-stop receipt."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a task-stop receipt; otherwise"
           "#f.")))
        (effects pure))
      (task-record? datum 'task-stop))

    (define (task-wait? datum)
      "Return #t when DATUM is a task-wait record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a task-wait record; otherwise"
           "#f.")))
        (effects pure))
      (task-record? datum 'task-wait))

    (define (task-failure? datum)
      "Return #t when DATUM is a task-failure record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a task-failure record;"
           "otherwise #f.")))
        (effects pure))
      (task-record? datum 'task-failure))

    (define (agent-completion? datum)
      "Return #t when DATUM is an agent-completion record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as an agent-completion record;"
           "otherwise #f.")))
        (effects pure))
      (task-record? datum 'agent-completion))

    (define (required-fields tag)
      "Return required field names for TAG, or #f."
      (let ((row (assq tag task-required-fields)))
        (if row (cdr row) #f)))

    (define (validate-required-fields record tag fields)
      "Validate that RECORD has every FIELD in FIELDS."
      (let loop ((rest fields))
        (if (not (null? rest))
            (begin
              (if (not (field-present? record (car rest)))
                  (raise-task-error
                   'missing-field
                   (list (cons 'record tag)
                         (cons 'field (car rest)))))
              (loop (cdr rest))))))

    (define (validate-state-shape record tag)
      "Validate state-specific invariants for RECORD tagged TAG."
      (cond
       ((or (eq? tag 'agent-task) (eq? tag 'agent-step))
        (normalize-state (task-field-value record 'state)))
       ((eq? tag 'task-pause)
        (let ((state (normalize-state (task-field-value record 'state))))
          (if (not (member-eq? state task-pause-states))
              (raise-task-error
               'invalid-pause-state
               (list (cons 'state state))))))
       ((eq? tag 'task-stop)
        (let ((state (normalize-state (task-field-value record 'state))))
          (if (not (member-eq? state task-terminal-states))
              (raise-task-error
               'invalid-stop-state
               (list (cons 'state state))))))
       ((eq? tag 'task-wait)
        (let ((state (normalize-state (task-field-value record 'state))))
          (if (not (member-eq? state
                               '(waiting-for-approval waiting-for-model
                                                      waiting-for-host)))
              (raise-task-error
               'invalid-wait-state
               (list (cons 'state state))))))
       ((eq? tag 'task-failure)
        (let ((state (normalize-state (task-field-value record 'state))))
          (if (not (eq? state 'failed))
              (raise-task-error
               'invalid-failure-state
               (list (cons 'state state))))))
       ((eq? tag 'agent-completion)
        (if (not (eq? (task-field-value record 'status) 'complete))
            (raise-task-error
             'invalid-completion-status
             (list (cons 'status (task-field-value record 'status))))))))

    (define (validate-task-record record)
      "Validate RECORD as a public task lifecycle datum and return RECORD."
      #((parameters
         (record
          (type any)
          (description "Task lifecycle datum to validate.")))
        (returns
         (type any)
         (description
          ("RECORD unchanged when it satisfies required fields and"
           "state invariants.")))
        (effects error)
        (see-also task-record-valid?))
      (if (not (pair? record))
          (raise-task-error 'malformed-record (list (cons 'record record))))
      (let ((tag (car record)))
        (let ((fields (required-fields tag)))
          (if (not fields)
              (raise-task-error 'malformed-record
                                (list (cons 'record record))))
          (validate-required-fields record tag fields)
          (validate-state-shape record tag)
          record)))

    (define (task-record-valid? record)
      "Return #t when RECORD validates as a public task lifecycle datum."
      #((parameters
         (record
          (type any)
          (description "Task lifecycle datum to validate.")))
        (returns
         (type any)
         (description "#t when RECORD passes validation; otherwise #f."))
        (effects pure)
        (see-also validate-task-record))
      (guard (condition
              (else #f))
        (validate-task-record record)
        #t))

    (define (make-agent-task id goal session options)
      "Create a canonical agent-task datum."
      #((parameters
         (id
          (type any)
          (description "Stable task id."))
         (goal
          (type any)
          (description "User or agent goal datum."))
         (session
          (type any)
          (description "Session id or session metadata for the task."))
         (options
          (type any)
          (description
           ("Association list overriding task fields such as state,"
            "scope, context, memory, plan, budget, provider routes,"
            "transcript, and audit."))))
        (returns
         (type any)
         (description "A canonical `agent-task` datum."))
        (effects pure)
        (see-also validate-task-record make-agent-step))
      (let ((created-at (option-ref options 'created-at
                                    (portable-timestamp))))
        (let ((updated-at (option-ref options 'updated-at created-at)))
          (list 'agent-task
                (list 'id id)
                (list 'state (option-ref options 'state 'created))
                (list 'goal goal)
                (list 'session session)
                (list 'scope (option-ref options 'scope 'project))
                (list 'created-at created-at)
                (list 'updated-at updated-at)
                (list 'resumed-from (option-ref options 'resumed-from 'none))
                (list 'parent (option-ref options 'parent 'none))
                (list 'children (option-ref options 'children '()))
                (list 'context (option-ref options 'context '()))
                (list 'memory (option-ref options 'memory '()))
                (list 'rules (option-ref options 'rules '()))
                (list 'skills (option-ref options 'skills '()))
                (list 'patterns (option-ref options 'patterns '()))
                (list 'plan (option-ref options 'plan 'none))
                (list 'current-step (option-ref options 'current-step 'none))
                (list 'budget (option-ref options 'budget '(task-budget)))
                (list 'provider-routes
                      (option-ref options 'provider-routes '()))
                (list 'capability-environment
                      (option-ref options 'capability-environment 'none))
                (list 'transcript (option-ref options 'transcript 'none))
                (list 'audit (option-ref options 'audit 'none))))))

    (define (make-agent-step id task goal options)
      "Create a canonical agent-step datum."
      #((parameters
         (id
          (type any)
          (description "Stable step id."))
         (task
          (type any)
          (description "Parent task id or task datum."))
         (goal
          (type any)
          (description "Step-level goal datum."))
         (options
          (type any)
          (description
           ("Association list overriding step fields such as state,"
            "plan item, attempt, observations, decision, action,"
            "events, and result."))))
        (returns
         (type any)
         (description "A canonical `agent-step` datum."))
        (effects pure))
      (list 'agent-step
            (list 'id id)
            (list 'task task)
            (list 'state (option-ref options 'state 'created))
            (list 'goal goal)
            (list 'plan-item (option-ref options 'plan-item 'none))
            (list 'attempt (option-ref options 'attempt 1))
            (list 'observations (option-ref options 'observations '()))
            (list 'decision (option-ref options 'decision 'none))
            (list 'action (option-ref options 'action 'none))
            (list 'events (option-ref options 'events '()))
            (list 'result (option-ref options 'result 'pending))))

    (define (make-agent-action id task step kind options)
      "Create a canonical agent-action datum."
      #((parameters
         (id
          (type any)
          (description "Stable action id."))
         (task
          (type any)
          (description "Parent task id or task datum."))
         (step
          (type any)
          (description "Parent step id or step datum."))
         (kind
          (type any)
          (description "Action kind symbol."))
         (options
          (type any)
          (description
           ("Association list overriding library, binding, arguments,"
            "required capabilities, and expected outcome."))))
        (returns
         (type any)
         (description "A canonical `agent-action` datum."))
        (effects pure))
      (list 'agent-action
            (list 'id id)
            (list 'task task)
            (list 'step step)
            (list 'kind kind)
            (list 'library (option-ref options 'library 'none))
            (list 'binding (option-ref options 'binding 'none))
            (list 'arguments (option-ref options 'arguments '()))
            (list 'requires (option-ref options 'requires '()))
            (list 'expected-outcome
                  (option-ref options 'expected-outcome 'none))))

    (define (make-agent-observation id task source kind value options)
      "Create a canonical agent-observation datum."
      #((parameters
         (id
          (type any)
          (description "Stable observation id."))
         (task
          (type any)
          (description "Parent task id or task datum."))
         (source
          (type any)
          (description "Observation source datum."))
         (kind
          (type any)
          (description "Observation kind symbol."))
         (value
          (type any)
          (description "Observed value as Scheme-readable data."))
         (options
          (type any)
          (description
           ("Association list overriding redactions and audit metadata."))))
        (returns
         (type any)
         (description "A canonical `agent-observation` datum."))
        (effects pure))
      (list 'agent-observation
            (list 'id id)
            (list 'task task)
            (list 'source source)
            (list 'kind kind)
            (list 'value value)
            (list 'redactions (option-ref options 'redactions '()))
            (list 'audit (option-ref options 'audit 'none))))

    (define (make-agent-decision id task step observed-state
                                 selected-action reason options)
      "Create a canonical agent-decision datum."
      #((parameters
         (id
          (type any)
          (description "Stable decision id."))
         (task
          (type any)
          (description "Parent task id or task datum."))
         (step
          (type any)
          (description "Parent step id or step datum."))
         (observed-state
          (type any)
          (description "State summary considered by the decision."))
         (selected-action
          (type any)
          (description "Selected action id, action datum, or none."))
         (reason
          (type any)
          (description
           ("Human-readable or Scheme-readable reason for the decision.")))
         (options
          (type any)
          (description
           ("Association list overriding policy, model, rules, and"
            "verifier inputs."))))
        (returns
         (type any)
         (description "A canonical `agent-decision` datum."))
        (effects pure))
      (list 'agent-decision
            (list 'id id)
            (list 'task task)
            (list 'step step)
            (list 'observed-state observed-state)
            (list 'selected-action selected-action)
            (list 'reason reason)
            (list 'policy-input (option-ref options 'policy-input '()))
            (list 'model-input (option-ref options 'model-input '()))
            (list 'rules-input (option-ref options 'rules-input '()))
            (list 'verifier-result
                  (option-ref options 'verifier-result 'not-run))))

    (define (make-task-pause task state reason options)
      "Create a canonical task-pause receipt."
      #((parameters
         (task
          (type any)
          (description "Task id or task datum being paused."))
         (state
          (type any)
          (description "Resumable pause state."))
         (reason
          (type any)
          (description "Pause reason symbol from the public vocabulary."))
         (options
          (type any)
          (description
           ("Association list describing observed state, intended"
            "action, gates, routing, approvals, and verifier result."))))
        (returns
         (type any)
         (description "A canonical `task-pause` receipt datum."))
        (effects pure))
      (list 'task-pause
            (list 'task task)
            (list 'state state)
            (list 'observed-state
                  (option-ref options 'observed-state 'none))
            (list 'intended-next-action
                  (option-ref options 'intended-next-action 'none))
            (list 'capability-gate
                  (option-ref options 'capability-gate 'none))
            (list 'model-route (option-ref options 'model-route 'none))
            (list 'approval-status
                  (option-ref options 'approval-status 'none))
            (list 'verifier-result
                  (option-ref options 'verifier-result 'not-run))
            (list 'pause-reason reason)))

    (define (make-task-stop task state reason options)
      "Create a canonical task-stop receipt."
      #((parameters
         (task
          (type any)
          (description "Task id or task datum being stopped."))
         (state
          (type any)
          (description "Terminal stop state."))
         (reason
          (type any)
          (description "Stop reason symbol from the public vocabulary."))
         (options
          (type any)
          (description
           ("Association list describing observed state, intended"
            "action, gates, routing, approvals, and verifier result."))))
        (returns
         (type any)
         (description "A canonical `task-stop` receipt datum."))
        (effects pure))
      (list 'task-stop
            (list 'task task)
            (list 'state state)
            (list 'observed-state
                  (option-ref options 'observed-state 'none))
            (list 'intended-next-action
                  (option-ref options 'intended-next-action 'none))
            (list 'capability-gate
                  (option-ref options 'capability-gate 'none))
            (list 'model-route (option-ref options 'model-route 'none))
            (list 'approval-status
                  (option-ref options 'approval-status 'none))
            (list 'verifier-result
                  (option-ref options 'verifier-result 'not-run))
            (list 'stop-reason reason)))

    (define (make-task-wait task state kind request options)
      "Create a canonical task-wait record."
      #((parameters
         (task
          (type any)
          (description "Task id or task datum that is waiting."))
         (state
          (type any)
          (description "Waiting state symbol."))
         (kind
          (type any)
          (description "Wait kind symbol, such as approval, model, or host."))
         (request
          (type any)
          (description "Scheme-readable wait request datum."))
         (options
          (type any)
          (description
           ("Association list overriding started-at, budget,"
            "transcript, and audit fields."))))
        (returns
         (type any)
         (description "A canonical `task-wait` datum."))
        (effects pure))
      (list 'task-wait
            (list 'task task)
            (list 'state state)
            (list 'wait-kind kind)
            (list 'request request)
            (list 'started-at
                  (option-ref options 'started-at (portable-timestamp)))
            (list 'budget (option-ref options 'budget 'none))
            (list 'transcript (option-ref options 'transcript 'none))
            (list 'audit (option-ref options 'audit 'none))))

    (define (make-task-failure task condition options)
      "Create a canonical task-failure record."
      #((parameters
         (task
          (type any)
          (description "Task id or task datum that failed."))
         (condition
          (type any)
          (description "Condition datum explaining the failure."))
         (options
          (type any)
          (description
           ("Association list overriding retry, transcript, and audit"
            "fields."))))
        (returns
         (type any)
         (description "A canonical `task-failure` datum."))
        (effects pure))
      (list 'task-failure
            (list 'task task)
            (list 'state 'failed)
            (list 'condition condition)
            (list 'retry (option-ref options 'retry 'none))
            (list 'transcript (option-ref options 'transcript 'none))
            (list 'audit (option-ref options 'audit 'none))))

    (define (make-agent-completion task value stop options)
      "Create a canonical agent-completion record."
      #((parameters
         (task
          (type any)
          (description "Task id or task datum being completed."))
         (value
          (type any)
          (description "Completion value as Scheme-readable data."))
         (stop
          (type any)
          (description "Task-stop receipt or stop metadata."))
         (options
          (type any)
          (description
           ("Association list overriding transcript and audit fields."))))
        (returns
         (type any)
         (description "A canonical `agent-completion` datum."))
        (effects pure))
      (list 'agent-completion
            (list 'task task)
            (list 'status 'complete)
            (list 'value value)
            (list 'stop stop)
            (list 'transcript (option-ref options 'transcript 'none))
            (list 'audit (option-ref options 'audit 'none))))))
