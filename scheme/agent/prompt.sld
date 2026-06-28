;;; prompt.sld --- Portable Consent Scheme REPL agent-harness verbs.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This host-neutral library is the thin, discoverable surface that turns the
;;; REPL into an agent harness.  It composes the already-shipped substrate --
;;; the agent abstraction and deterministic automatic selection from
;;; `(agent registry)', the minimal task-runner control loop from
;;; `(agent runner)', and the session lifecycle stance from `(consent session)'
;;; -- into one-line verbs a user runs at the prompt:
;;;
;;;   `prompt'        dispatch the automatically chosen agent at a goal;
;;;   `prompt-role'   force an agent of a named role;
;;;   `prompt-model'  force an agent of a named model;
;;;   `agents'/`roles'/`models'  discovery helpers for the REPL.
;;;
;;; Each verb selects an agent, drives the task runner inside the harness's
;;; current default session, and returns one inspectable `prompt-result' record
;;; bundling the selection decision, the underlying `task-run', the terminal
;;; `task-stop'/`task-pause' receipt, and a Scheme-readable audit trail.  Model
;;; routing is recorded intent over the `(agent runner)' provider surface: the
;;; provider proposal steps are injected as data, so a stubbed or fake provider
;;; is enough for the first cut -- no streaming or remote transport is required.
;;;
;;; Consent invariants carried here:
;;;
;;; * Fail closed without authority.  A harness whose current session carries no
;;;   granted authority -- or no current session at all -- refuses to dispatch
;;;   and returns a `prompt-result' carrying a Scheme-readable `prompt-error'
;;;   receipt and an audit record, never touching the runner or any host effect.
;;; * Determinism (the D7 agent-layer stance).  Selection consults no
;;;   wall-clock, host randomness, or live provider, and the runner is
;;;   deterministic around policy and state given its injected inputs, so a
;;;   `prompt-result' is replayable and cross-host identical.
;;;
;;; The library is single-sourced like `(agent registry)' and `(agent runner)':
;;; the Emacs interpreter and the portable hosts load this same Scheme source,
;;; so the verbs behave identically in the Emacs REPL and the portable terminal
;;; REPL.  The ambient "current harness" is process-local mutable state managed
;;; through `current-prompt-harness'/`set-current-prompt-harness!' so a bare
;;; `(prompt "...")' resolves to a default harness while explicit harnesses keep
;;; the verbs testable and reentrant.

(define-library (agent prompt)
  (export ;; Registry construction and inspection surface, re-exported so the
          ;; REPL imports one library and `agents' (below) does not collide with
          ;; the registry primitive of the same name.
          make-agent
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
          agent-selection-considered
          make-prompt-authority
          prompt-authority?
          prompt-authority-field-value
          prompt-authority-authorized?
          make-prompt-harness
          prompt-harness?
          prompt-harness-registry
          prompt-harness-session
          prompt-harness-authority?
          prompt-harness-defaults
          prompt-harness-set-session!
          prompt-harness-set-authority!
          current-prompt-harness
          set-current-prompt-harness!
          reset-prompt-harness!
          prompt
          prompt-role
          prompt-model
          agents
          roles
          models
          prompt-result?
          prompt-result-field-value
          prompt-result-status
          prompt-result-ok?
          prompt-result-agent
          prompt-result-agent-id
          prompt-result-role
          prompt-result-model
          prompt-result-session
          prompt-result-selection
          prompt-result-run
          prompt-result-receipt
          prompt-result-state
          prompt-result-completion
          prompt-result-transcript
          prompt-result-observations
          prompt-result-budget
          prompt-result-audit)
  (import (scheme base)
          (agent runner)
          ;; The registry exports `agents', which this library re-purposes as a
          ;; harness-taking discovery verb; rename the registry primitive so both
          ;; names coexist in the body.
          (rename (agent registry)
                  (agents registry-agents)))
  (begin
    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT when KEY is absent.  Cells may be"
      "dotted pairs or two-element `(key value)' lists."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (record-field-value record field default)
      "Return FIELD's value from tagged-list RECORD, or DEFAULT when absent."
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if (and entry (pair? (cdr entry)))
            (cadr entry)
            default)))

    (define (tagged? datum tag)
      "Report whether DATUM is a tagged list whose head is TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (tail-option tail)
      "Return the leading options alist from a variadic TAIL, or the empty list."
      (if (pair? tail) (car tail) '()))

    (define (non-empty-list? value)
      "Return #t when VALUE is a non-empty proper or dotted list."
      (and (pair? value) #t))

    (define (authorized-source? source)
      "Return #t when SOURCE names an explicit prompt authority source."
      (or (eq? source 'grant)
          (eq? source 'preloaded-approval)
          (eq? source 'policy-file)
          (eq? source 'session)))

    (define (prompt-authority-authorized-from-options options source)
      "Resolve the authorized flag from OPTIONS and SOURCE."
      (let ((explicit (option-ref options 'authorized 'auto)))
        (cond
         ((eq? explicit #t) #t)
         ((eq? explicit #f) #f)
         ((not (eq? explicit 'auto)) (and explicit #t))
         ((non-empty-list? (option-ref options 'grants '())) #t)
         ((non-empty-list? (option-ref options 'approvals '())) #t)
         ((non-empty-list? (option-ref options 'policy '())) #t)
         ((authorized-source? source) #t)
         (else #f))))

    (define (prompt-authority-source-from-options options)
      "Resolve the authority source from OPTIONS."
      (option-ref
       options
       'source
       (cond
        ((non-empty-list? (option-ref options 'grants '())) 'grant)
        ((non-empty-list? (option-ref options 'approvals '()))
         'preloaded-approval)
        ((non-empty-list? (option-ref options 'policy '())) 'policy-file)
        (else 'none))))

    (define (make-prompt-authority options)
      "Return a Scheme-readable prompt authority bundle."
      #((parameters . ((options . "Association list with optional `origin', `source', `grants', `approvals', `policy', and `authorized' fields. Non-empty grants, approvals, or policy authorize the bundle unless `authorized' is explicitly #f.")))
        (returns . "A `prompt-authority' datum that a prompt harness can inspect.")
        (effects . (allocation)))
      (let* ((origin (option-ref options 'origin 'interactive))
             (source (prompt-authority-source-from-options options))
             (grants (option-ref options 'grants '()))
             (approvals (option-ref options 'approvals '()))
             (policy (option-ref options 'policy '()))
             (authorized
              (prompt-authority-authorized-from-options options source)))
        (list 'prompt-authority
              (list 'origin origin)
              (list 'source source)
              (list 'grants grants)
              (list 'approvals approvals)
              (list 'policy policy)
              (list 'authorized authorized))))

    (define (prompt-authority? datum)
      "Return #t when DATUM is a prompt-authority bundle."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a `prompt-authority'; otherwise #f.")
        (effects . (pure)))
      (tagged? datum 'prompt-authority))

    (define (prompt-authority-field-value authority field . maybe-default)
      "Return AUTHORITY's FIELD value, or DEFAULT (or #f) when absent."
      #((parameters . ((authority . "A `prompt-authority' datum.")
                       (field . "Symbol naming the authority field to read.")
                       (maybe-default . "Optional fallback value; defaults to #f.")))
        (returns . "The field value, or the fallback when FIELD is absent.")
        (effects . (pure)))
      (record-field-value authority field
                          (if (null? maybe-default) #f (car maybe-default))))

    (define (prompt-authority-authorized? authority)
      "Return #t when AUTHORITY carries explicit prompt authority."
      #((parameters . ((authority . "A `prompt-authority' datum.")))
        (returns . "#t when the bundle authorizes prompt dispatch; otherwise #f.")
        (effects . (pure)))
      (and (prompt-authority? authority)
           (prompt-authority-field-value authority 'authorized #f)
           #t))

    (define (normalize-authority authority)
      "Return AUTHORITY in the harness representation."
      (if (prompt-authority? authority)
          authority
          (and authority #t)))

    ;; Harness container: a registry to select from, the current default session
    ;; id the verbs dispatch into, authority for that session, and a defaults
    ;; alist of runner options (provider, policy, verifier, budgets, ...) merged
    ;; under per-call options. This is mutable host/session state, so it is a
    ;; record rather than a serializable datum; the agents, selections, and
    ;; results it produces remain tagged lists.
    (define-record-type <prompt-harness>
      (make-harness-record registry session authority defaults)
      prompt-harness?
      (registry harness-registry)
      (session harness-session set-harness-session!)
      (authority harness-authority set-harness-authority!)
      (defaults harness-defaults set-harness-defaults!))

    (define (make-prompt-harness . maybe-options)
      "Return a prompt harness over a registry, default session, and authority."
      #((parameters . ((maybe-options . "Optional association list overriding `registry' (an agent registry; defaults to a fresh `make-agent-registry'), `session' (the current default session id; defaults to `project-main'), `authority' (whether that session carries granted authority; defaults to #t), and any runner defaults (`provider', `policy', `effects', `verifier', `operations', `control', `max-steps', `max-pure-cost', `scope') merged beneath per-call options.")))
        (returns . "A `prompt-harness' the REPL verbs dispatch through.")
        (effects . (allocation))
        (see-also . (prompt current-prompt-harness make-agent-registry)))
      (let ((options (tail-option maybe-options)))
        (make-harness-record
         (option-ref options 'registry (make-agent-registry))
         (option-ref options 'session 'project-main)
         ;; Absent authority defaults to the interactive session posture; an
         ;; explicit `(authority #f)' or unauthorized bundle arms fail-closed.
         (normalize-authority (option-ref options 'authority #t))
         options)))

    (define (prompt-harness-registry harness)
      "Return HARNESS's agent registry."
      #((parameters . ((harness . "A `prompt-harness'.")))
        (returns . "The agent registry the harness selects agents from.")
        (effects . (state-read)))
      (harness-registry harness))

    (define (prompt-harness-session harness)
      "Return HARNESS's current default session id."
      #((parameters . ((harness . "A `prompt-harness'.")))
        (returns . "The current default session id symbol, or #f when none is set.")
        (effects . (state-read)))
      (harness-session harness))

    (define (prompt-harness-authority? harness)
      "Return #t when HARNESS's current session carries granted authority."
      #((parameters . ((harness . "A `prompt-harness'.")))
        (returns . "#t when the harness session is authorized to dispatch; otherwise #f.")
        (effects . (state-read)))
      (let ((authority (harness-authority harness)))
        (if (prompt-authority? authority)
            (prompt-authority-authorized? authority)
            (and authority #t))))

    (define (prompt-harness-defaults harness)
      "Return HARNESS's runner defaults alist."
      #((parameters . ((harness . "A `prompt-harness'.")))
        (returns . "The association list of runner defaults merged beneath per-call options.")
        (effects . (state-read)))
      (harness-defaults harness))

    (define (prompt-harness-set-session! harness session . maybe-authority)
      "Set HARNESS's current session, optionally updating its authority flag."
      #((parameters . ((harness . "A `prompt-harness' to mutate.")
                       (session . "The session id symbol to make current, or #f.")
                       (maybe-authority . "Optional new authority boolean for the session; left unchanged when omitted.")))
        (returns . "The updated session id.")
        (effects . (state-write)))
      (set-harness-session! harness session)
      (if (pair? maybe-authority)
          (set-harness-authority! harness
                                  (normalize-authority (car maybe-authority))))
      session)

    (define (prompt-harness-set-authority! harness authority)
      "Set whether HARNESS's current session carries granted authority."
      #((parameters . ((harness . "A `prompt-harness' to mutate.")
                       (authority . "Authority boolean for the current session.")))
        (returns . "The stored authority boolean.")
        (effects . (state-write)))
      (let ((value (normalize-authority authority)))
        (set-harness-authority! harness value)
        (prompt-harness-authority? harness)))

    ;; Process-local ambient harness so a bare `(prompt "...")' resolves to a
    ;; current default without threading a harness argument.  It is created
    ;; lazily on first use and may be replaced or cleared between REPL runs.
    (define ambient-harness #f)

    (define (current-prompt-harness)
      "Return the process-local current harness, creating a default one lazily."
      #((parameters . ())
        (returns . "The ambient `prompt-harness' bare verb forms dispatch through.")
        (effects . (state-read state-write allocation))
        (see-also . (set-current-prompt-harness! reset-prompt-harness!)))
      (if (not ambient-harness)
          (set! ambient-harness (make-prompt-harness)))
      ambient-harness)

    (define (set-current-prompt-harness! harness)
      "Install HARNESS as the process-local current harness."
      #((parameters . ((harness . "A `prompt-harness' to make ambient.")))
        (returns . "The installed harness.")
        (effects . (state-write)))
      (set! ambient-harness harness)
      harness)

    (define (reset-prompt-harness!)
      "Clear the process-local current harness so the next use rebuilds it."
      #((parameters . ())
        (returns . "Unspecified.")
        (effects . (state-write)))
      (set! ambient-harness #f))

    (define (harness-or-current maybe-harness)
      "Return the explicit harness from MAYBE-HARNESS, or the ambient harness."
      (if (and (pair? maybe-harness) (prompt-harness? (car maybe-harness)))
          (car maybe-harness)
          (current-prompt-harness)))

    (define (merged-option harness options key default)
      "Return KEY from per-call OPTIONS, then HARNESS defaults, then DEFAULT."
      (option-ref options key
                  (option-ref (harness-defaults harness) key default)))

    (define (budget-field budget name default)
      "Return NAME from a `(budget ...)' datum BUDGET, or DEFAULT otherwise."
      (if (and (pair? budget) (eq? (car budget) 'budget))
          (record-field-value budget name default)
          default))

    (define (resolve-budget harness agent options key budget-name default)
      "Resolve a runner budget from per-call OPTIONS, the agent budget, or DEFAULT."
      (let ((explicit (merged-option harness options key 'unset)))
        (if (eq? explicit 'unset)
            (budget-field (agent-budget agent) budget-name default)
            explicit)))

    (define (make-audit kind fields)
      "Return a Scheme-readable `prompt-audit' record of KIND carrying FIELDS."
      (cons 'prompt-audit (cons (list 'kind kind) fields)))

    (define (authority-audit-fields authority)
      "Return origin/source audit fields for AUTHORITY when available."
      (if (prompt-authority? authority)
          (list
           (list 'origin
                 (prompt-authority-field-value authority 'origin 'interactive))
           (list 'source
                 (prompt-authority-field-value authority 'source 'none)))
          '()))

    (define (authority-origin authority)
      "Return AUTHORITY's origin, defaulting to interactive."
      (if (prompt-authority? authority)
          (prompt-authority-field-value authority 'origin 'interactive)
          'interactive))

    (define (authority-source authority)
      "Return AUTHORITY's source, defaulting to none."
      (if (prompt-authority? authority)
          (prompt-authority-field-value authority 'source 'none)
          'none))

    (define (authority-denial-reason authority)
      "Return the denial reason for missing AUTHORITY."
      (if (eq? (authority-origin authority) 'noninteractive)
          'noninteractive-authority-unavailable
          'authority-missing))

    (define (authority-denial-message authority)
      "Return the denial message for missing AUTHORITY."
      (if (eq? (authority-origin authority) 'noninteractive)
          "noninteractive prompt requires preloaded authority; refusing to dispatch"
          "no granted session authority; refusing to dispatch"))

    (define (authority-granted-audit authority session)
      "Return an authority-granted audit entry for noninteractive AUTHORITY."
      (if (and (prompt-authority? authority)
               (eq? (authority-origin authority) 'noninteractive))
          (list
           (make-audit 'authority-granted
                       (append (list (list 'session session)
                                     (list 'operation 'prompt))
                               (authority-audit-fields authority))))
          '()))

    (define (selection-context goal session extra options)
      "Build the selection context alist from GOAL, SESSION, EXTRA, and OPTIONS."
      "EXTRA (the role/model forced by `prompt-role'/`prompt-model') is placed"
      "first so it wins over any same-named OPTIONS cell, because `select-agent'"
      "reads the first matching cell."
      (append extra
              (let ((agent (option-ref options 'agent 'unset)))
                (if (eq? agent 'unset) '() (list (list 'agent agent))))
              (list (list 'goal goal) (list 'session session))))

    (define (runner-options harness agent session options)
      "Assemble the `run-task' options for AGENT in SESSION under OPTIONS."
      (list (list 'session session)
            (list 'scope (merged-option harness options 'scope 'project))
            (list 'provider (merged-option harness options 'provider '()))
            (list 'policy (merged-option harness options 'policy '()))
            (list 'effects (merged-option harness options 'effects '()))
            (list 'verifier (merged-option harness options 'verifier 'insufficient))
            (list 'operations (merged-option harness options 'operations '()))
            (list 'control (merged-option harness options 'control '()))
            (list 'observation
                  (merged-option harness options 'observation
                                 '(observation (kind read-only)
                                               (value project-clean))))
            (list 'max-steps (resolve-budget harness agent options
                                             'max-steps 'max-steps 8))
            (list 'max-pure-cost (resolve-budget harness agent options
                                                 'max-pure-cost 'max-pure-cost
                                                 100000))
            (list 'id-prefix (merged-option harness options 'id-prefix 'prompt))))

    (define (make-prompt-result status agent selection session run receipt
                                state completion transcript observations
                                budget audit)
      "Return a Scheme-readable `prompt-result' bundling one dispatch outcome."
      (let ((role (if (agent? agent) (agent-role agent) 'none))
            (model (if (agent? agent) (agent-model agent) 'none))
            (agent-id-value (if (agent? agent) (agent-id agent) 'none)))
        (list 'prompt-result
              (list 'status status)
              (list 'agent (if agent agent 'none))
              (list 'agent-id agent-id-value)
              (list 'role role)
              (list 'model model)
              (list 'session session)
              (list 'selection selection)
              (list 'run run)
              (list 'receipt receipt)
              (list 'state state)
              (list 'completion completion)
              (list 'transcript transcript)
              (list 'observations observations)
              (list 'budget budget)
              (list 'audit audit))))

    (define (fail-closed status agent selection session reason message
                         . maybe-authority)
      "Build a fail-closed `prompt-result' with a `prompt-error' receipt."
      (let* ((authority (if (null? maybe-authority)
                            #f
                            (car maybe-authority)))
             (error-receipt (list 'prompt-error
                                 (list 'reason reason)
                                 (list 'session session)
                                 (list 'message message)))
             (audit (list (make-audit 'authority-denied
                                      (append
                                       (list (list 'session session)
                                             (list 'operation 'prompt)
                                             (list 'reason reason)
                                             (list 'message message))
                                       (authority-audit-fields authority))))))
        (make-prompt-result status agent selection session 'none error-receipt
                            'failed-closed 'none '() '() 'none audit)))

    (define (run-prompt harness goal extra options)
      "Select an agent for GOAL and dispatch it through the task runner."
      (let* ((session (option-ref options 'session
                                  (harness-session harness)))
             (context (selection-context goal session extra options))
             (selection (select-agent (harness-registry harness) context)))
        (cond
         ((not (prompt-harness-authority? harness))
          (fail-closed 'authority-missing
                       (agent-of selection) selection session
                       (authority-denial-reason (harness-authority harness))
                       (authority-denial-message (harness-authority harness))
                       (harness-authority harness)))
         ((not session)
          (fail-closed 'no-session
                       (agent-of selection) selection session
                       'no-session
                       "no current default session; refusing to dispatch"))
         ((eq? (agent-selection-status selection) 'no-agent)
          (fail-closed 'no-agent #f selection session
                       'no-agent
                       "no agent available for the requested dispatch"))
         (else
          (dispatch harness goal session selection options)))))

    (define (agent-of selection)
      "Return SELECTION's chosen agent datum, or #f when nothing was selected."
      (let ((agent (agent-selection-agent selection)))
        (if (agent? agent) agent #f)))

    (define (dispatch harness goal session selection options)
      "Run AGENT (from SELECTION) on GOAL and assemble the prompt-result."
      (let* ((agent (agent-of selection))
             (run (run-task goal (runner-options harness agent session options)))
             (authority (harness-authority harness))
             (audit (append
                     (authority-granted-audit authority session)
                     (list
                      (make-audit 'agent-selected
                                  (append
                                   (list (list 'session session)
                                         (list 'agent-id (agent-id agent))
                                         (list 'role (agent-role agent))
                                         (list 'model (agent-model agent))
                                         (list 'basis
                                               (agent-selection-basis
                                                selection)))
                                   (authority-audit-fields authority)))
                      (make-audit 'model-route
                                  (append
                                   (list (list 'session session)
                                         (list 'role (agent-role agent))
                                         (list 'model (agent-model agent))
                                         (list 'provider 'fake-local))
                                   (authority-audit-fields authority)))))))
        (make-prompt-result 'selected agent selection session run
                            (task-run-receipt run)
                            (task-run-state run)
                            (task-run-completion run)
                            (task-run-transcript run)
                            (task-run-observations run)
                            (task-run-budget run)
                            audit)))

    (define (prompt . args)
      "Prompt the automatically chosen agent at a goal in the current session."
      #((parameters . ((args . "Either `(goal)' / `(goal options)' using the ambient harness, or `(harness goal)' / `(harness goal options)' against an explicit harness.  GOAL is the goal string or datum; OPTIONS is an association list overriding the harness session and runner defaults.")))
        (returns . "A `prompt-result' record bundling the selection, the underlying `task-run', its terminal `task-stop'/`task-pause' receipt, and the audit trail; or a fail-closed `prompt-result' when the session lacks authority.")
        (effects . (state-read allocation))
        (see-also . (prompt-role prompt-model make-prompt-harness)))
      (if (prompt-harness? (car args))
          (run-prompt (car args) (cadr args) '() (tail-option (cddr args)))
          (run-prompt (current-prompt-harness) (car args) '()
                      (tail-option (cdr args)))))

    (define (prompt-role . args)
      "Prompt an agent of a named role at a goal in the current session."
      #((parameters . ((args . "Either `(role goal)' / `(role goal options)' using the ambient harness, or `(harness role goal)' / `(harness role goal options)' against an explicit harness.  ROLE is the forced agent role symbol; GOAL and OPTIONS are as for `prompt'.")))
        (returns . "A `prompt-result' record for the role-selected agent, or a fail-closed `prompt-result' when the session lacks authority.")
        (effects . (state-read allocation))
        (see-also . (prompt prompt-model)))
      (if (prompt-harness? (car args))
          (let ((more (cddr args)))
            (run-prompt (car args) (car more)
                        (list (list 'role (cadr args)))
                        (tail-option (cdr more))))
          (run-prompt (current-prompt-harness) (cadr args)
                      (list (list 'role (car args)))
                      (tail-option (cddr args)))))

    (define (prompt-model . args)
      "Prompt an agent of a named model at a goal in the current session."
      #((parameters . ((args . "Either `(model goal)' / `(model goal options)' using the ambient harness, or `(harness model goal)' / `(harness model goal options)' against an explicit harness.  MODEL is the forced model id symbol; GOAL and OPTIONS are as for `prompt'.")))
        (returns . "A `prompt-result' record for the model-routed agent, or a fail-closed `prompt-result' when the session lacks authority.")
        (effects . (state-read allocation))
        (see-also . (prompt prompt-role)))
      (if (prompt-harness? (car args))
          (let ((more (cddr args)))
            (run-prompt (car args) (car more)
                        (list (list 'model (cadr args)))
                        (tail-option (cdr more))))
          (run-prompt (current-prompt-harness) (cadr args)
                      (list (list 'model (car args)))
                      (tail-option (cddr args)))))

    (define (dedup values)
      "Return VALUES with later equal? duplicates removed, order preserved."
      (let loop ((rest values) (seen '()) (kept '()))
        (cond
         ((null? rest) (reverse kept))
         ((member (car rest) seen) (loop (cdr rest) seen kept))
         (else (loop (cdr rest)
                     (cons (car rest) seen)
                     (cons (car rest) kept))))))

    (define (agents . maybe-harness)
      "Return the registered agents discoverable through a harness."
      #((parameters . ((maybe-harness . "Optional explicit `prompt-harness'; defaults to the ambient harness.")))
        (returns . "A list of agent datums in registration order.")
        (effects . (state-read))
        (see-also . (roles models prompt)))
      (registry-agents (harness-registry (harness-or-current maybe-harness))))

    (define (roles . maybe-harness)
      "Return the distinct agent roles discoverable through a harness."
      #((parameters . ((maybe-harness . "Optional explicit `prompt-harness'; defaults to the ambient harness.")))
        (returns . "A list of distinct role symbols in registration order.")
        (effects . (state-read))
        (see-also . (agents models prompt-role)))
      (dedup (map agent-role (apply agents maybe-harness))))

    (define (models . maybe-harness)
      "Return the distinct agent models discoverable through a harness."
      #((parameters . ((maybe-harness . "Optional explicit `prompt-harness'; defaults to the ambient harness.")))
        (returns . "A list of distinct model specifications in registration order.")
        (effects . (state-read))
        (see-also . (agents roles prompt-model)))
      (dedup (map agent-model (apply agents maybe-harness))))

    (define (prompt-result? datum)
      "Return #t when DATUM is a prompt-result record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a `prompt-result'; otherwise #f.")
        (effects . (pure)))
      (tagged? datum 'prompt-result))

    (define (prompt-result-field-value result field . maybe-default)
      "Return RESULT's FIELD value, or DEFAULT (or #f) when absent."
      #((parameters . ((result . "A `prompt-result' record.")
                       (field . "Symbol naming the field to read.")
                       (maybe-default . "Optional fallback value; defaults to #f.")))
        (returns . "The field value, or the fallback when FIELD is absent.")
        (effects . (pure)))
      (record-field-value result field
                          (if (null? maybe-default) #f (car maybe-default))))

    (define (prompt-result-status result)
      "Return RESULT's dispatch status."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The status symbol: `selected', `authority-missing', `no-session', or `no-agent'.")
        (effects . (pure)))
      (record-field-value result 'status 'none))

    (define (prompt-result-ok? result)
      "Return #t when RESULT selected an agent and dispatched it."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "#t when the status is `selected'; otherwise #f (a fail-closed result).")
        (effects . (pure)))
      (eq? (record-field-value result 'status 'none) 'selected))

    (define (prompt-result-agent result)
      "Return RESULT's dispatched agent datum, or the symbol none."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The agent datum, or the symbol none when nothing was dispatched.")
        (effects . (pure)))
      (record-field-value result 'agent 'none))

    (define (prompt-result-agent-id result)
      "Return RESULT's dispatched agent id, or the symbol none."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The agent id symbol, or the symbol none.")
        (effects . (pure)))
      (record-field-value result 'agent-id 'none))

    (define (prompt-result-role result)
      "Return the role of RESULT's dispatched agent."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The agent role symbol, or the symbol none.")
        (effects . (pure)))
      (record-field-value result 'role 'none))

    (define (prompt-result-model result)
      "Return the model of RESULT's dispatched agent."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The agent model specification, or the symbol none.")
        (effects . (pure)))
      (record-field-value result 'model 'none))

    (define (prompt-result-session result)
      "Return the session id RESULT dispatched into."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The session id symbol, or #f.")
        (effects . (pure)))
      (record-field-value result 'session #f))

    (define (prompt-result-selection result)
      "Return RESULT's `agent-selection' decision record."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The `agent-selection' decision record that chose the agent.")
        (effects . (pure)))
      (record-field-value result 'selection 'none))

    (define (prompt-result-run result)
      "Return RESULT's underlying `task-run', or the symbol none."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The `task-run' record, or the symbol none for a fail-closed result.")
        (effects . (pure)))
      (record-field-value result 'run 'none))

    (define (prompt-result-receipt result)
      "Return RESULT's terminal receipt."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The `task-stop'/`task-pause' receipt, or a `prompt-error' for a fail-closed result.")
        (effects . (pure)))
      (record-field-value result 'receipt 'none))

    (define (prompt-result-state result)
      "Return the final task lifecycle state RESULT reached."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The final task state symbol, or `failed-closed' for a fail-closed result.")
        (effects . (pure)))
      (record-field-value result 'state 'none))

    (define (prompt-result-completion result)
      "Return RESULT's `agent-completion' datum, or the symbol none."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The `agent-completion' datum when the task completed; otherwise the symbol none.")
        (effects . (pure)))
      (record-field-value result 'completion 'none))

    (define (prompt-result-transcript result)
      "Return the transcript events RESULT emitted."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "A list of `transcript-event' datums (yield/progress/request/audit/provider events), in emission order.")
        (effects . (pure)))
      (record-field-value result 'transcript '()))

    (define (prompt-result-observations result)
      "Return the observations RESULT recorded."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "A list of `agent-observation' datums in execution order.")
        (effects . (pure)))
      (record-field-value result 'observations '()))

    (define (prompt-result-budget result)
      "Return RESULT's budget ledger datum, or the symbol none."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "The `task-budget' ledger datum, or the symbol none for a fail-closed result.")
        (effects . (pure)))
      (record-field-value result 'budget 'none))

    (define (prompt-result-audit result)
      "Return RESULT's Scheme-readable audit trail."
      #((parameters . ((result . "A `prompt-result' record.")))
        (returns . "A list of `prompt-audit' records describing selection, routing, and any authority denial.")
        (effects . (pure)))
      (record-field-value result 'audit '()))))
