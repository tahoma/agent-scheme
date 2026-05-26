;;; Public Agent Scheme task lifecycle records.
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

    ;; Return #t when VALUE is a member of VALUES using eq?.
    (define (member-eq? value values)
      (cond
       ((null? values) #f)
       ((eq? value (car values)) #t)
       (else (member-eq? value (cdr values)))))

    (define (task-state? state)
      "Return #t when STATE is part of the public task lifecycle vocabulary."
      (member-eq? state task-states))

    ;; Return KEY from OPTIONS, or DEFAULT if absent.  OPTIONS may contain
    ;; dotted alist cells or two-element Scheme option records.
    (define (option-ref options key default)
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    ;; Return a portable placeholder timestamp for host-neutral constructors.
    (define (portable-timestamp)
      "portable")

    (define (make-task-condition kind fields)
      "Return a Scheme-readable task condition datum."
      (cons 'task-condition
            (cons (list 'kind kind)
                  (map (lambda (field)
                         (list (car field) (cdr field)))
                       fields))))

    ;; Raise a task lifecycle error carrying a structured condition datum.
    (define (raise-task-error kind fields)
      (error "agent-scheme-task" (make-task-condition kind fields)))

    ;; Validate and return STATE.
    (define (normalize-state state)
      (if (task-state? state)
          state
          (raise-task-error 'unknown-state
                            (list (cons 'state state)))))

    (define (task-transition-allowed? from to)
      "Return #t when task state FROM may transition to TO."
      (let ((row (assq from task-allowed-transitions)))
        (if (and (task-state? from) (task-state? to) row)
            (member-eq? to (cdr row))
            #f)))

    (define (validate-task-transition from to)
      "Validate transition FROM to TO and return TO."
      (let ((from-state (normalize-state from))
            (to-state (normalize-state to)))
        (if (task-transition-allowed? from-state to-state)
            to-state
            (raise-task-error
             'invalid-transition
             (list (cons 'from from-state)
                   (cons 'to to-state))))))

    ;; Return #t when FIELD is a record field named NAME.
    (define (field-named? field name)
      (and (pair? field) (eq? (car field) name)))

    ;; Return #t when RECORD has a field named NAME.
    (define (field-present? record name)
      (let loop ((fields (cdr record)))
        (cond
         ((null? fields) #f)
         ((field-named? (car fields) name) #t)
         (else (loop (cdr fields))))))

    (define (task-field-value record name . maybe-default)
      "Return RECORD field NAME, or DEFAULT when absent."
      (let ((default (if (null? maybe-default) #f (car maybe-default))))
        (let loop ((fields (cdr record)))
          (cond
           ((null? fields) default)
           ((field-named? (car fields) name) (cadr (car fields)))
           (else (loop (cdr fields)))))))

    (define (task-record? datum tag)
      "Return #t when DATUM is a task lifecycle record tagged TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (agent-task? datum)
      "Return #t when DATUM is an agent-task record."
      (task-record? datum 'agent-task))

    (define (agent-step? datum)
      "Return #t when DATUM is an agent-step record."
      (task-record? datum 'agent-step))

    (define (agent-action? datum)
      "Return #t when DATUM is an agent-action record."
      (task-record? datum 'agent-action))

    (define (agent-observation? datum)
      "Return #t when DATUM is an agent-observation record."
      (task-record? datum 'agent-observation))

    (define (agent-decision? datum)
      "Return #t when DATUM is an agent-decision record."
      (task-record? datum 'agent-decision))

    (define (task-pause? datum)
      "Return #t when DATUM is a task-pause receipt."
      (task-record? datum 'task-pause))

    (define (task-stop? datum)
      "Return #t when DATUM is a task-stop receipt."
      (task-record? datum 'task-stop))

    (define (task-wait? datum)
      "Return #t when DATUM is a task-wait record."
      (task-record? datum 'task-wait))

    (define (task-failure? datum)
      "Return #t when DATUM is a task-failure record."
      (task-record? datum 'task-failure))

    (define (agent-completion? datum)
      "Return #t when DATUM is an agent-completion record."
      (task-record? datum 'agent-completion))

    ;; Return required field names for TAG, or #f.
    (define (required-fields tag)
      (let ((row (assq tag task-required-fields)))
        (if row (cdr row) #f)))

    ;; Validate that RECORD has every FIELD in FIELDS.
    (define (validate-required-fields record tag fields)
      (let loop ((rest fields))
        (if (not (null? rest))
            (begin
              (if (not (field-present? record (car rest)))
                  (raise-task-error
                   'missing-field
                   (list (cons 'record tag)
                         (cons 'field (car rest)))))
              (loop (cdr rest))))))

    ;; Validate state-specific invariants for RECORD tagged TAG.
    (define (validate-state-shape record tag)
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
      (guard (condition
              (else #f))
        (validate-task-record record)
        #t))

    (define (make-agent-task id goal session options)
      "Create a canonical agent-task datum."
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
      (list 'task-failure
            (list 'task task)
            (list 'state 'failed)
            (list 'condition condition)
            (list 'retry (option-ref options 'retry 'none))
            (list 'transcript (option-ref options 'transcript 'none))
            (list 'audit (option-ref options 'audit 'none))))

    (define (make-agent-completion task value stop options)
      "Create a canonical agent-completion record."
      (list 'agent-completion
            (list 'task task)
            (list 'status 'complete)
            (list 'value value)
            (list 'stop stop)
            (list 'transcript (option-ref options 'transcript 'none))
            (list 'audit (option-ref options 'audit 'none))))))
