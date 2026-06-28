;;; Portable Consent Scheme REPL agent-harness verb tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent prompt)' REPL harness directly: the harness container, the `prompt',
;;; `prompt-role', and `prompt-model' verbs driving the minimal task runner in a
;;; harness session, fail-closed dispatch without session authority, budget
;;; threading, the Scheme-readable result/receipt/audit surface, the
;;; `agents'/`roles'/`models' discovery helpers, the ambient current harness, and
;;; determinism.  It loads no Emacs host adapter; the same source backs the Emacs
;;; interpreter, so passing here is the portable half of the parity check.

(import (scheme base)
        (scheme write)
        (agent prompt)
        (agent runner)
        (agent task))

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

;; Host-operation table shared by the gated-call scenarios.
(define ops
  '((file-write host-mutation file-system)
    (read-file host-observation file-system)))

;; Build a harness over a registry carrying a coder and a reviewer agent.
(define (make-staffed-harness . options)
  (let ((registry (make-agent-registry)))
    (register-agent registry
                    (make-agent 'coder-1
                                (list (list 'role 'coder)
                                      (list 'model 'portable-coder))))
    (register-agent registry
                    (make-agent 'reviewer-1
                                (list (list 'role 'reviewer)
                                      (list 'model 'portable-reviewer))))
    (make-prompt-harness (cons (list 'registry registry) options))))

;; Read the audit kinds carried by a result, in order.
(define (audit-kinds result)
  (map (lambda (entry) (cadr (assq 'kind (cdr entry))))
       (prompt-result-audit result)))

;;;; A verified finish completes through the harness and is fully inspectable

(let* ((harness (make-prompt-harness))
       (result (prompt harness 'finish-the-goal
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed)))))
  (check-true 'complete-is-result (prompt-result? result))
  (check 'complete-status (prompt-result-status result) 'selected)
  (check-true 'complete-ok (prompt-result-ok? result))
  (check 'complete-state (prompt-result-state result) 'complete)
  (check-true 'complete-run (task-run? (prompt-result-run result)))
  (check-true 'complete-receipt-stop
              (task-stop? (prompt-result-receipt result)))
  (check-true 'complete-completion
              (agent-completion? (prompt-result-completion result)))
  (check-true 'complete-transcript (pair? (prompt-result-transcript result)))
  (check-true 'complete-observations
              (pair? (prompt-result-observations result)))
  (check 'complete-default-agent (prompt-result-agent-id result) 'default)
  (check 'complete-role (prompt-result-role result) 'planner)
  (check 'complete-session (prompt-result-session result) 'project-main)
  (check 'complete-audit-kinds (audit-kinds result)
         '(agent-selected model-route)))

;;;; With no provider the harness still returns an inspectable pause

(let ((result (prompt (make-prompt-harness) 'do-a-thing)))
  (check 'no-provider-status (prompt-result-status result) 'selected)
  (check 'no-provider-state (prompt-result-state result) 'blocked)
  (check-true 'no-provider-pause
              (task-pause? (prompt-result-receipt result))))

;;;; Fail closed without session authority: no runner, an error receipt

(let* ((harness (make-prompt-harness (list (list 'authority #f))))
       (result (prompt harness 'sensitive
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed)))))
  (check 'closed-status (prompt-result-status result) 'authority-missing)
  (check-true 'closed-not-ok (not (prompt-result-ok? result)))
  (check 'closed-state (prompt-result-state result) 'failed-closed)
  (check 'closed-no-run (prompt-result-run result) 'none)
  (check 'closed-receipt-tag (car (prompt-result-receipt result)) 'prompt-error)
  (check 'closed-receipt-reason
         (cadr (assq 'reason (cdr (prompt-result-receipt result))))
         'authority-missing)
  (check 'closed-audit-kinds (audit-kinds result) '(authority-denied)))

;;;; Fail closed without a current session

(let* ((harness (make-prompt-harness (list (list 'session #f))))
       (result (prompt harness 'orphan)))
  (check 'no-session-status (prompt-result-status result) 'no-session)
  (check 'no-session-state (prompt-result-state result) 'failed-closed))

;;;; prompt-role forces an agent of a named role

(let* ((harness (make-staffed-harness))
       (result (prompt-role harness 'reviewer 'review-the-diff
                            (list (list 'provider '((finish done)))
                                  (list 'verifier 'passed)))))
  (check 'role-agent-id (prompt-result-agent-id result) 'reviewer-1)
  (check 'role-role (prompt-result-role result) 'reviewer)
  (check 'role-basis
         (agent-selection-basis (prompt-result-selection result))
         'role-match)
  (check 'role-state (prompt-result-state result) 'complete))

;;;; prompt-model forces an agent of a named model

(let* ((harness (make-staffed-harness))
       (result (prompt-model harness 'portable-coder 'build-it)))
  (check 'model-status (prompt-result-status result) 'selected)
  (check 'model-agent-id (prompt-result-agent-id result) 'coder-1)
  (check 'model-model (prompt-result-model result) 'portable-coder)
  (check 'model-basis
         (agent-selection-basis (prompt-result-selection result))
         'model-match)
  (check 'model-requested
         (agent-selection-field-value (prompt-result-selection result)
                                      'requested-model)
         'portable-coder))

;;;; Policy gating flows through the harness to a runner pause

(let* ((harness (make-staffed-harness))
       (result (prompt harness 'edit-file
                       (list (list 'provider
                                   '((code-action (file-write "o" p))))
                             (list 'operations ops)
                             (list 'policy '((file-write needs-approval)))))))
  (check 'gated-status (prompt-result-status result) 'selected)
  (check 'gated-state (prompt-result-state result) 'waiting-for-approval)
  (check-true 'gated-pause (task-pause? (prompt-result-receipt result))))

;;;; Budgets: the agent budget and per-call options both reach the runner

(let ((registry (make-agent-registry)))
  (register-agent registry
                  (make-agent 'budgeted
                              (list (list 'role 'coder)
                                    (list 'budget '(budget (max-steps 3))))))
  (set-default-agent! registry 'budgeted)
  (let* ((harness (make-prompt-harness (list (list 'registry registry))))
         (from-agent (prompt harness 'go))
         (from-option (prompt harness 'go (list (list 'max-steps 5)))))
    (check 'budget-from-agent
           (task-field-value (prompt-result-budget from-agent) 'max-steps)
           3)
    (check 'budget-option-overrides
           (task-field-value (prompt-result-budget from-option) 'max-steps)
           5)))

;;;; Discovery helpers list agents, distinct roles, and distinct models

(let ((harness (make-staffed-harness)))
  (check 'discover-agents (map agent-id (agents harness))
         '(default coder-1 reviewer-1))
  (check 'discover-roles (roles harness) '(planner coder reviewer))
  (check 'discover-models (models harness)
         '(auto portable-coder portable-reviewer)))

;;;; The ambient current harness backs the bare verb forms

(reset-prompt-harness!)
(let ((result (prompt 'ambient-goal)))
  (check 'ambient-status (prompt-result-status result) 'selected)
  (check 'ambient-state (prompt-result-state result) 'blocked))

(let ((custom (make-staffed-harness)))
  (set-current-prompt-harness! custom)
  (check 'ambient-installed (map agent-id (agents)) '(default coder-1 reviewer-1))
  (check 'ambient-role-id
         (prompt-result-agent-id
          (prompt-role 'coder 'work
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed))))
         'coder-1))
(reset-prompt-harness!)

;;;; Identical prompts are deterministic and replayable

(let ((harness (make-prompt-harness)))
  (check 'prompt-deterministic
         (prompt harness 'replay
                 (list (list 'provider '((finish done)))
                       (list 'verifier 'passed)))
         (prompt harness 'replay
                 (list (list 'provider '((finish done)))
                       (list 'verifier 'passed)))))

(if (> failures 0)
    (error "portable agent prompt tests failed" failures))
