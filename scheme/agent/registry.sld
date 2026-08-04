;;; registry.sld --- Portable Consent Scheme agent abstraction and registry
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This host-neutral library owns the first-class agent abstraction: a named,
;;; inspectable bundle of role, model (or model-selection policy), optional
;;; rules, skills, and budget, represented as a Scheme-readable datum.  It adds
;;; an agent registry (register, list, reference, default) and deterministic,
;;; policy-visible automatic selection that records which agent was chosen and
;;; why as a Scheme-readable decision record.
;;;
;;; The registry is the entity `prompt` (the REPL harness verbs) dispatches to
;;; when a caller does not name a role or model explicitly.  Selection is
;;; deterministic over the registry contents and a goal/session context: it
;;; consults no wall-clock, no host randomness, and no model provider, so a
;;; selection record is reproducible and cross-host identical (the D7
;;; agent-layer
;;; determinism stance). The composed agent records its model-selection intent;
;;; routing that intent to a concrete provider happens later, at prompt/run
;;; time.

(define-library (agent registry)
  (export make-agent
          agent?
          agent-field-value
          agent-id
          agent-name
          agent-role
          agent-model
          agent-rules
          agent-skills
          agent-budget
          agent-description
          make-agent-registry
          agent-registry?
          register-agent
          agents
          agent-ref
          default-agent
          default-agent-id
          set-default-agent!
          select-agent
          agent-selection?
          agent-selection-field-value
          agent-selection-status
          agent-selection-agent
          agent-selection-agent-id
          agent-selection-basis
          agent-selection-reason
          agent-selection-considered)
  (import (scheme base)
          (only (stdlib list) alist-delete))
  (begin
    (define (plist-ref alist key default)
      "Return KEY's value from ALIST, or DEFAULT when absent.  Cells may be"
      "dotted pairs or two-element `(key value)` lists."
      (let ((cell (assq key alist)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (agent-field name value)
      "Return a Scheme-readable record field named NAME holding VALUE."
      (list name value))

    (define (record-field-value record field default)
      "Return FIELD's value from tagged-list RECORD, or DEFAULT when absent."
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if (and entry (pair? (cdr entry)))
            (cadr entry)
            default)))

    (define (tagged? datum tag)
      "Report whether DATUM is a tagged list whose head is TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (default-agent-name id)
      "Return a printable default name for an agent identified by ID."
      (if (symbol? id) (symbol->string id) "agent"))

    (define (make-agent id options)
      "Return a Scheme-readable agent datum bundling role, model, and metadata\
."
      #((parameters
         (id (type symbol)
          (description "Stable agent id symbol."))
         (options (type list)
          (description
           ("Association list overriding name, role, model (a model id"
             "symbol, the symbol auto for role routing, or a"
             "model-selection policy datum), rules, skills, budget, and"
             "description."))))
        (returns (type agent)
         (description
          ("A canonical `agent` datum suitable for a registry and for"
            "automatic selection.")))
        (effects pure)
        (see-also register-agent select-agent))
      (list 'agent
            (agent-field 'id id)
            (agent-field 'name
                         (plist-ref options 'name (default-agent-name id)))
            (agent-field 'role (plist-ref options 'role 'planner))
            (agent-field 'model (plist-ref options 'model 'auto))
            (agent-field 'rules (plist-ref options 'rules '()))
            (agent-field 'skills (plist-ref options 'skills '()))
            (agent-field 'budget (plist-ref options 'budget 'default))
            (agent-field 'description (plist-ref options 'description ""))))

    (define (agent? datum)
      "Return #t when DATUM is an agent datum."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description "#t when DATUM is tagged as an agent; otherwise #f."))
        (effects pure))
      (tagged? datum 'agent))

    (define (agent-field-value agent field . maybe-default)
      "Return AGENT's FIELD value, or DEFAULT (or #f) when absent."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read."))
         (field (type symbol)
          (description "Symbol naming the field."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . ("The field value, or the fallback when FIELD is absent."))
        (effects pure))
      (record-field-value agent
                          field
                          (if (null? maybe-default) #f (car maybe-default))))

    (define (agent-id agent)
      "Return AGENT's stable id symbol."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns . "The agent id, or #f when absent.")
        (effects pure))
      (record-field-value agent 'id #f))

    (define (agent-name agent)
      "Return AGENT's printable name."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns (type (or string boolean))
         (description "The agent name string, or #f when absent."))
        (effects pure))
      (record-field-value agent 'name #f))

    (define (agent-role agent)
      "Return AGENT's role symbol."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns (type (or symbol boolean))
         (description "The agent role symbol, or #f when absent."))
        (effects pure))
      (record-field-value agent 'role #f))

    (define (agent-model agent)
      "Return AGENT's model id, the symbol auto, or a model-selection policy."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns . "The agent model specification, or #f when absent.")
        (effects pure))
      (record-field-value agent 'model #f))

    (define (agent-rules agent)
      "Return AGENT's rules list."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns (type list)
         (description "The agent rules list, or the empty list when absent."))
        (effects pure))
      (record-field-value agent 'rules '()))

    (define (agent-skills agent)
      "Return AGENT's skills list."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns (type list)
         (description
           ("The agent skills list, or the empty list when absent.")))
        (effects pure))
      (record-field-value agent 'skills '()))

    (define (agent-budget agent)
      "Return AGENT's budget datum."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns (type (or symbol list))
         (description
           ("The agent budget datum, or the symbol default when absent.")))
        (effects pure))
      (record-field-value agent 'budget 'default))

    (define (agent-description agent)
      "Return AGENT's human-readable description."
      #((parameters
         (agent (type agent)
          (description "Agent datum to read.")))
        (returns (type string)
         (description
          ("The agent description string, or the empty string when"
            "absent.")))
        (effects pure))
      (record-field-value agent 'description ""))

    ;; Mutable registry container: a roster of agents in registration order
    ;; plus
    ;; the id of the default agent automatic selection resolves to.  The roster
    ;; is mutable host/session state, so it is a record rather than a
    ;; serializable
    ;; datum; the agents and selection records it holds remain tagged lists.
    (define-record-type <agent-registry>
      (make-registry-record agents default-id)
      agent-registry?
      (agents registry-agents set-registry-agents!)
      (default-id registry-default-id set-registry-default-id!))

    (define (built-in-default-agent)
      "Return the seeded general-purpose agent automatic selection falls back \
to."
      (make-agent 'default
                  (list (list 'name "default")
                        (list 'role 'planner)
                        (list 'model 'auto)
                        (list 'description
                              "Automatically chosen general-purpose agent."))))

    (define (make-agent-registry)
      "Return a fresh agent registry seeded with a default general-purpose age\
nt."
      #((parameters)
        (returns (type agent-registry)
         (description
          ("A mutable agent registry whose only agent is the seeded"
            "default, set as the default agent.")))
        (effects allocation)
        (see-also register-agent set-default-agent! select-agent))
      (let ((registry (make-registry-record '() #f)))
        (register-agent registry (built-in-default-agent))
        (set-registry-default-id! registry 'default)
        registry))

    (define (register-agent registry agent)
      "Register AGENT in REGISTRY, replacing any agent with the same id."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to mutate."))
         (agent (type agent)
          (description "Agent datum to register.")))
        (returns (type agent)
         (description "The registered AGENT datum."))
        (effects state-write error)
        (see-also agents agent-ref make-agent))
      (if (not (agent? agent))
          (error "register-agent requires an agent datum" agent))
      (let ((id (agent-id agent)))
        (set-registry-agents!
         registry
         (cons (cons id agent)
               (alist-delete id (registry-agents registry) eq?)))
        agent))

    (define (agents registry)
      "Return REGISTRY's agent datums in registration order."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to inspect.")))
        (returns (type (list-of agent))
         (description "A list of agent datums, oldest registration first."))
        (effects state-read))
      (map cdr (reverse (registry-agents registry))))

    (define (agent-ref registry id)
      "Return REGISTRY's agent datum named ID, or #f when unknown."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to inspect."))
         (id (type symbol)
          (description "Agent id symbol.")))
        (returns (type (or agent boolean))
         (description
          ("The agent datum for ID, or #f when no such agent is"
            "registered.")))
        (effects state-read))
      (let ((cell (assq id (registry-agents registry))))
        (if cell (cdr cell) #f)))

    (define (default-agent-id registry)
      "Return REGISTRY's default agent id, or #f when none is set."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to inspect.")))
        (returns (type (or symbol boolean))
         (description "The default agent id symbol, or #f."))
        (effects state-read))
      (registry-default-id registry))

    (define (default-agent registry)
      "Return REGISTRY's default agent datum, or #f when none is set."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to inspect.")))
        (returns (type (or agent boolean))
         (description
          ("The default agent datum, or #f when no default is set or"
            "it is missing.")))
        (effects state-read)
        (see-also set-default-agent!))
      (let ((id (registry-default-id registry)))
        (if id (agent-ref registry id) #f)))

    (define (set-default-agent! registry id)
      "Make the agent named ID REGISTRY's default agent and return it."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to mutate."))
         (id (type symbol)
          (description "Id of an already-registered agent to make default.")))
        (returns (type agent)
         (description "The agent datum now serving as the default agent."))
        (effects state-write error)
        (see-also default-agent register-agent))
      (let ((agent (agent-ref registry id)))
        (if (not agent)
            (error "set-default-agent! given unknown agent id" id))
        (set-registry-default-id! registry id)
        agent))

    (define (first-agent-with-role registry role)
      "Return REGISTRY's first agent whose role is ROLE, or #f."
      (let loop ((rest (agents registry)))
        (cond
         ((null? rest) #f)
         ((eq? (agent-role (car rest)) role) (car rest))
         (else (loop (cdr rest))))))

    (define (first-agent-with-model registry model)
      "Return REGISTRY's first agent whose model is MODEL, or #f.  A model"
      "specification can be a bare id symbol, the symbol `auto', or a richer"
      "model-selection policy, so MODEL is compared with `equal?', not `eq?'."
      (let loop ((rest (agents registry)))
        (cond
         ((null? rest) #f)
         ((equal? (agent-model (car rest)) model) (car rest))
         (else (loop (cdr rest))))))

    (define (first-registered-agent registry)
      "Return REGISTRY's first registered agent, or #f when it has none."
      (let ((all (agents registry)))
        (if (pair? all) (car all) #f)))

    (define (make-agent-selection status agent basis reason
                                  requested-role requested-model
                                  goal session considered)
      "Return a Scheme-readable automatic-selection decision record."
      (list 'agent-selection
            (agent-field 'status status)
            (agent-field 'agent (if agent agent 'none))
            (agent-field 'agent-id (if agent (agent-id agent) 'none))
            (agent-field 'basis basis)
            (agent-field 'reason reason)
            (agent-field 'requested-role requested-role)
            (agent-field 'requested-model requested-model)
            (agent-field 'goal goal)
            (agent-field 'session session)
            (agent-field 'considered considered)))

    (define (select-agent registry context)
      "Choose an agent for CONTEXT deterministically and explain the choice."
      #((parameters
         (registry (type agent-registry)
          (description "Agent registry to select from."))
         (context (type list)
          (description
           ("Association list goal/session context that may name an"
             "explicit agent, a requested role, or a requested model."))))
        (returns (type agent-selection)
         (description
          ("An `agent-selection` decision record naming the chosen"
            "agent (or none) and the policy-visible basis and reason"
            "for the choice.")))
        (effects state-read)
        (see-also default-agent set-default-agent! make-agent))
      (let ((requested-agent (plist-ref context 'agent #f))
            (requested-role (plist-ref context 'role #f))
            (requested-model (plist-ref context 'model #f))
            (goal (plist-ref context 'goal 'none))
            (session (plist-ref context 'session 'none))
            (considered (map agent-id (agents registry))))
        (let ((explicit (and requested-agent
                             (agent-ref registry requested-agent)))
              (role-match (and requested-role
                               (first-agent-with-role registry
                                                       requested-role)))
              (model-match (and requested-model
                                (first-agent-with-model registry
                                                        requested-model)))
              (fallback (default-agent registry)))
          (cond
           (explicit
            (make-agent-selection 'selected explicit 'explicit-agent
                                  "selected the explicitly named agent"
                                  requested-role requested-model
                                  goal session considered))
           (role-match
            (make-agent-selection 'selected role-match 'role-match
                                  "selected the first registered agent matchin\
g the requested role"
                                  requested-role requested-model
                                  goal session considered))
           (model-match
            (make-agent-selection 'selected model-match 'model-match
                                  "selected the first registered agent matchin\
g the requested model"
                                  requested-role requested-model
                                  goal session considered))
           (fallback
            (make-agent-selection 'selected fallback 'default-agent
                                  "no goal-specific configuration; resolved to \
the default agent"
                                  requested-role requested-model
                                  goal session considered))
           ;; Defensive fallbacks for a registry constructed without a default
           ;; agent.  `make-agent-registry' always seeds and sets a default, so
           ;; automatic selection normally resolves above; these keep selection
           ;; total and inspectable rather than erroring.
           ((first-registered-agent registry)
            (make-agent-selection 'selected
                                  (first-registered-agent registry)
                                  'first-agent
                                  "no default agent set; resolved to the first \
registered agent"
                                  requested-role requested-model
                                  goal session considered))
           (else
            (make-agent-selection 'no-agent #f 'none
                                  "no agents are registered"
                                  requested-role requested-model
                                  goal session considered))))))

    (define (agent-selection? datum)
      "Return #t when DATUM is an automatic-selection decision record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
          ("#t when DATUM is tagged as an agent-selection record;"
            "otherwise #f.")))
        (effects pure))
      (tagged? datum 'agent-selection))

    (define (agent-selection-field-value selection field . maybe-default)
      "Return SELECTION's FIELD value, or DEFAULT (or #f) when absent."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record."))
         (field (type symbol)
          (description "Symbol naming the field."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . ("The field value, or the fallback when FIELD is absent."))
        (effects pure))
      (record-field-value selection
                          field
                          (if (null? maybe-default) #f (car maybe-default))))

    (define (agent-selection-status selection)
      "Return SELECTION's status symbol (selected or no-agent)."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record.")))
        (returns (type (or symbol boolean))
         (description "The selection status symbol, or #f when absent."))
        (effects pure))
      (record-field-value selection 'status #f))

    (define (agent-selection-agent selection)
      "Return SELECTION's chosen agent datum, or the symbol none."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record.")))
        (returns (type (or agent symbol))
         (description
          ("The chosen agent datum, or the symbol none when nothing"
            "was selected.")))
        (effects pure))
      (record-field-value selection 'agent 'none))

    (define (agent-selection-agent-id selection)
      "Return SELECTION's chosen agent id, or the symbol none."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record.")))
        (returns (type symbol)
         (description
          ("The chosen agent id symbol, or the symbol none when"
            "nothing was selected.")))
        (effects pure))
      (record-field-value selection 'agent-id 'none))

    (define (agent-selection-basis selection)
      "Return the policy-visible basis SELECTION used to choose the agent."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record.")))
        (returns (type symbol)
         (description
          ("The basis symbol, such as explicit-agent, role-match,"
            "default-agent, sole-agent, or none.")))
        (effects pure))
      (record-field-value selection 'basis #f))

    (define (agent-selection-reason selection)
      "Return SELECTION's human-readable reason for the choice."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record.")))
        (returns (type (or string boolean))
         (description "The reason string, or #f when absent."))
        (effects pure))
      (record-field-value selection 'reason #f))

    (define (agent-selection-considered selection)
      "Return the candidate agent ids SELECTION considered."
      #((parameters
         (selection (type agent-selection)
          (description "Agent-selection decision record.")))
        (returns (type (list-of symbol))
         (description
          ("The list of candidate agent ids, or the empty list when"
            "absent.")))
        (effects pure))
      (record-field-value selection 'considered '()))))
