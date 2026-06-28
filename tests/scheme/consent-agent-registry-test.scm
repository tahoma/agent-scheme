;;; Portable Consent Scheme agent abstraction and registry tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent registry)' library directly: the agent datum and its accessors, the
;;; registry surface (register, list, reference, default / set-default), and
;;; deterministic, policy-visible automatic selection with an inspectable
;;; decision record.  It loads no Emacs host adapter; the same source backs the
;;; Emacs interpreter, so passing here is the portable half of the parity check.

(import (scheme base)
        (scheme write)
        (agent registry))

;; Count failed checks so the portable runner can report every mismatch.
(define failures 0)

;; Record one failed check and keep running the rest of the portable test file.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal?.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Assert VALUE is true after normalizing to canonical booleans.
(define (check-true name value)
  (check name (if value #t #f) #t))

;; Return #t when calling THUNK raises any condition.
(define (raises? thunk)
  (call/cc
   (lambda (k)
     (with-exception-handler
      (lambda (condition) (k #t))
      (lambda () (thunk) #f)))))

;;;; Agent datum construction and accessors

(let ((agent (make-agent 'coder-1
                         (list (list 'name "Coder One")
                               (list 'role 'coder)
                               (list 'model 'portable-coder)
                               (list 'rules '(no-secrets))
                               (list 'skills '(edit-file))
                               (list 'budget '(budget (max-steps 8)))
                               (list 'description "Writes code.")))))
  (check-true 'agent-predicate (agent? agent))
  (check 'agent-id (agent-id agent) 'coder-1)
  (check 'agent-name (agent-name agent) "Coder One")
  (check 'agent-role (agent-role agent) 'coder)
  (check 'agent-model (agent-model agent) 'portable-coder)
  (check 'agent-rules (agent-rules agent) '(no-secrets))
  (check 'agent-skills (agent-skills agent) '(edit-file))
  (check 'agent-budget (agent-budget agent) '(budget (max-steps 8)))
  (check 'agent-description (agent-description agent) "Writes code.")
  (check 'agent-field-value-generic (agent-field-value agent 'role) 'coder)
  (check 'agent-field-value-default
         (agent-field-value agent 'missing 'fallback)
         'fallback))

;; Minimal construction fills documented defaults.
(let ((agent (make-agent 'minimal '())))
  (check 'default-name (agent-name agent) "minimal")
  (check 'default-role (agent-role agent) 'planner)
  (check 'default-model (agent-model agent) 'auto)
  (check 'default-rules (agent-rules agent) '())
  (check 'default-skills (agent-skills agent) '())
  (check 'default-budget (agent-budget agent) 'default)
  (check 'default-description (agent-description agent) ""))

(check-true 'agent-predicate-rejects-non-agent
            (not (agent? '(not-an-agent (id x)))))

;;;; Registry seeding, registration, listing, and reference

(let ((registry (make-agent-registry)))
  (check-true 'registry-predicate (agent-registry? registry))
  (check 'seeded-default-id (default-agent-id registry) 'default)
  (check 'seeded-default-role (agent-role (default-agent registry)) 'planner)
  (check 'seeded-agent-count (length (agents registry)) 1)
  (check 'seeded-only-id (map agent-id (agents registry)) '(default)))

(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'reviewer-1 (list (list 'role 'reviewer))))
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'coder))))
  (check 'registration-order
         (map agent-id (agents registry))
         '(default reviewer-1 coder-1))
  (check 'agent-ref-hit (agent-id (agent-ref registry 'coder-1)) 'coder-1)
  (check 'agent-ref-miss (agent-ref registry 'absent) #f)
  ;; Re-registering the same id replaces in place rather than duplicating.
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'summarizer))))
  (check 'replace-keeps-count (length (agents registry)) 3)
  (check 'replace-updates-role
         (agent-role (agent-ref registry 'coder-1))
         'summarizer))

(check-true 'register-rejects-non-agent
            (raises?
             (lambda ()
               (register-agent (make-agent-registry) '(not-an-agent)))))

;;;; Default agent surface

(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'planner-2 (list (list 'role 'planner))))
  (let ((returned (set-default-agent! registry 'planner-2)))
    (check 'set-default-returns-agent (agent-id returned) 'planner-2))
  (check 'default-id-updated (default-agent-id registry) 'planner-2)
  (check 'default-agent-updated (agent-id (default-agent registry)) 'planner-2)
  (check-true 'set-default-unknown-raises
              (raises? (lambda () (set-default-agent! registry 'ghost)))))

;;;; Deterministic, policy-visible automatic selection

(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'coder))))
  (register-agent registry (make-agent 'reviewer-1 (list (list 'role 'reviewer))))

  ;; No configuration resolves to the default agent.
  (let ((selection (select-agent registry '())))
    (check-true 'auto-is-selection (agent-selection? selection))
    (check 'auto-status (agent-selection-status selection) 'selected)
    (check 'auto-basis (agent-selection-basis selection) 'default-agent)
    (check 'auto-agent-id (agent-selection-agent-id selection) 'default)
    (check 'auto-agent-datum
           (agent-id (agent-selection-agent selection))
           'default)
    (check 'auto-considered
           (agent-selection-considered selection)
           '(default coder-1 reviewer-1))
    (check-true 'auto-reason-present
                (string? (agent-selection-reason selection))))

  ;; A requested role selects the first matching agent.
  (let ((selection (select-agent registry
                                 (list (list 'role 'reviewer)
                                       (list 'goal "review the diff")
                                       (list 'session 'named-1)))))
    (check 'role-basis (agent-selection-basis selection) 'role-match)
    (check 'role-agent-id (agent-selection-agent-id selection) 'reviewer-1)
    (check 'role-records-requested-role
           (agent-selection-field-value selection 'requested-role)
           'reviewer)
    (check 'role-records-goal
           (agent-selection-field-value selection 'goal)
           "review the diff")
    (check 'role-records-session
           (agent-selection-field-value selection 'session)
           'named-1))

  ;; A requested role with no match falls back to the default agent.
  (let ((selection (select-agent registry (list (list 'role 'unmatched)))))
    (check 'role-fallback-basis (agent-selection-basis selection) 'default-agent)
    (check 'role-fallback-agent (agent-selection-agent-id selection) 'default))

  ;; An explicitly named agent wins over role matching.
  (let ((selection (select-agent registry
                                 (list (list 'agent 'coder-1)
                                       (list 'role 'reviewer)))))
    (check 'explicit-basis (agent-selection-basis selection) 'explicit-agent)
    (check 'explicit-agent-id (agent-selection-agent-id selection) 'coder-1))

  ;; An unknown explicit agent does not block role matching.
  (let ((selection (select-agent registry
                                 (list (list 'agent 'ghost)
                                       (list 'role 'coder)))))
    (check 'explicit-miss-falls-to-role
           (agent-selection-basis selection)
           'role-match)
    (check 'explicit-miss-role-agent
           (agent-selection-agent-id selection)
           'coder-1))

  ;; The requested model is recorded for the downstream router.
  (let ((selection (select-agent registry
                                 (list (list 'model 'portable-coder)))))
    (check 'records-requested-model
           (agent-selection-field-value selection 'requested-model)
           'portable-coder))

  ;; Selection is deterministic: identical inputs produce equal? records.
  (check 'selection-deterministic
         (select-agent registry (list (list 'role 'coder)))
         (select-agent registry (list (list 'role 'coder)))))

;; An explicitly chosen default still reports the explicit basis.
(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'coder))))
  (set-default-agent! registry 'coder-1)
  (let ((selection (select-agent registry '())))
    (check 'explicit-default-basis
           (agent-selection-basis selection)
           'default-agent)
    (check 'explicit-default-agent
           (agent-selection-agent-id selection)
           'coder-1)))

;; A requested model selects the first matching agent, then falls back.
(let ((registry (make-agent-registry)))
  (register-agent registry
                  (make-agent 'cod (list (list 'role 'coder) (list 'model 'm1))))
  (let ((hit (select-agent registry (list (list 'model 'm1))))
        (miss (select-agent registry (list (list 'model 'nomatch)))))
    (check 'model-match-basis (agent-selection-basis hit) 'model-match)
    (check 'model-match-agent (agent-selection-agent-id hit) 'cod)
    (check 'model-miss-basis (agent-selection-basis miss) 'default-agent)))

(if (> failures 0)
    (error "portable agent registry tests failed" failures))
