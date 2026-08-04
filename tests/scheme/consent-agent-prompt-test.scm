;;; Portable Consent Scheme REPL agent-harness verb tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent prompt)' REPL harness directly: the harness container, the
;;; `prompt',
;;; `prompt-role', and `prompt-model' verbs driving the minimal task runner in
;;; a
;;; harness session, fail-closed dispatch without session authority, budget
;;; threading, the Scheme-readable result/receipt/audit surface, the
;;; `agents'/`roles'/`models' discovery helpers, the ambient current harness,
;;; and
;;; determinism. It loads no Emacs host adapter; the same source backs the
;;; Emacs
;;; interpreter, so passing here is the portable half of the parity check.

(import (scheme base)
        (scheme write)
        (agent prompt)
        (agent runner)
        (agent task)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

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

(testing-registry-case
 'complete-is-result '(portable agent)
(let* ((harness (make-prompt-harness))
       (result (prompt harness 'finish-the-goal
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed)))))
  (test-assert 'complete-is-result (prompt-result? result))
  (test-equal 'complete-status 'selected (prompt-result-status result))
  (test-assert 'complete-ok (prompt-result-ok? result))
  (test-equal 'complete-state 'complete (prompt-result-state result))
  (test-assert 'complete-run (task-run? (prompt-result-run result)))
  (test-assert 'complete-receipt-stop
             (task-stop? (prompt-result-receipt result)))
  (test-assert 'complete-completion
             (agent-completion? (prompt-result-completion result)))
  (test-assert 'complete-transcript (pair? (prompt-result-transcript result)))
  (test-assert 'complete-observations
             (pair? (prompt-result-observations result)))
  (test-equal 'complete-default-agent 'default (prompt-result-agent-id result))
  (test-equal 'complete-role 'planner (prompt-result-role result))
  (test-equal 'complete-session 'project-main (prompt-result-session result))
  (test-equal 'complete-audit-kinds
             '(agent-selected model-route)
             (audit-kinds result))))

;;;; With no provider the harness still returns an inspectable pause

(testing-registry-case
 'no-provider-status '(portable agent)
(let ((result (prompt (make-prompt-harness) 'do-a-thing)))
  (test-equal 'no-provider-status 'selected (prompt-result-status result))
  (test-equal 'no-provider-state 'blocked (prompt-result-state result))
  (test-assert 'no-provider-pause
             (task-pause? (prompt-result-receipt result)))))

;;;; Fail closed without session authority: no runner, an error receipt

(testing-registry-case
 'closed-status '(portable agent)
(let* ((harness (make-prompt-harness (list (list 'authority #f))))
       (result (prompt harness 'sensitive
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed)))))
  (test-equal 'closed-status 'authority-missing (prompt-result-status result))
  (test-assert 'closed-not-ok (not (prompt-result-ok? result)))
  (test-equal 'closed-state 'failed-closed (prompt-result-state result))
  (test-equal 'closed-no-run 'none (prompt-result-run result))
  (test-equal 'closed-receipt-tag 'prompt-error (car (prompt-result-receipt
    result)))
  (test-equal 'closed-receipt-reason
             'authority-missing
             (cadr (assq 'reason (cdr (prompt-result-receipt result)))))
  (test-equal 'closed-audit-kinds '(authority-denied) (audit-kinds result))))

;;;; Non-interactive prompt authority is explicit data, not ambient approval

(testing-registry-case
 'noninteractive-authority-record '(portable agent)
(let* ((authority
        (make-prompt-authority
         '((origin noninteractive)
           (source grant)
           (grants ((capability-grant
                     (id script-prompt)
                     (domain provider)
                     (operations complete)
                     (expires never)))))))
       (harness (make-prompt-harness (list (list 'authority authority))))
       (result (prompt harness 'script-goal
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed))))
       (audit (prompt-result-audit result))
       (authority-audit (car audit)))
  (test-assert 'noninteractive-authority-record
             (prompt-authority? authority))
  (test-equal 'noninteractive-authority-status
             'selected
             (prompt-result-status result))
  (test-equal 'noninteractive-authority-state
             'complete
             (prompt-result-state result))
  (test-equal 'noninteractive-authority-audit-kinds
             '(authority-granted agent-selected model-route)
             (audit-kinds result))
  (test-equal 'noninteractive-authority-audit-origin
             'noninteractive
             (cadr (assq 'origin (cdr authority-audit))))
  (test-equal 'noninteractive-authority-audit-source
             'grant
             (cadr (assq 'source (cdr authority-audit))))))

(testing-registry-case
 'noninteractive-authority-denied-status '(portable agent)
(let* ((authority
        (make-prompt-authority '((origin noninteractive))))
       (harness (make-prompt-harness (list (list 'authority authority))))
       (result (prompt harness 'script-goal
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed))))
       (audit (prompt-result-audit result))
       (authority-audit (car audit)))
  (test-equal 'noninteractive-authority-denied-status
             'authority-missing
             (prompt-result-status result))
  (test-equal 'noninteractive-authority-denied-reason
             'noninteractive-authority-unavailable
             (cadr (assq 'reason (cdr (prompt-result-receipt result)))))
  (test-equal 'noninteractive-authority-denied-audit-kinds
             '(authority-denied)
             (audit-kinds result))
  (test-equal 'noninteractive-authority-denied-origin
             'noninteractive
             (cadr (assq 'origin (cdr authority-audit))))
  (test-equal 'noninteractive-authority-denied-source
             'none
             (cadr (assq 'source (cdr authority-audit))))))

;;;; Fail closed without a current session

(testing-registry-case
 'no-session-status '(portable agent)
(let* ((harness (make-prompt-harness (list (list 'session #f))))
       (result (prompt harness 'orphan)))
  (test-equal 'no-session-status 'no-session (prompt-result-status result))
  (test-equal 'no-session-state 'failed-closed (prompt-result-state result))))

;;;; prompt-role forces an agent of a named role

(testing-registry-case
 'role-agent-id '(portable agent)
(let* ((harness (make-staffed-harness))
       (result (prompt-role harness 'reviewer 'review-the-diff
                            (list (list 'provider '((finish done)))
                                  (list 'verifier 'passed)))))
  (test-equal 'role-agent-id 'reviewer-1 (prompt-result-agent-id result))
  (test-equal 'role-role 'reviewer (prompt-result-role result))
  (test-equal 'role-basis
             'role-match
             (agent-selection-basis (prompt-result-selection result)))
  (test-equal 'role-state 'complete (prompt-result-state result))))

;;;; prompt-model forces an agent of a named model

(testing-registry-case
 'model-status '(portable agent)
(let* ((harness (make-staffed-harness))
       (result (prompt-model harness 'portable-coder 'build-it)))
  (test-equal 'model-status 'selected (prompt-result-status result))
  (test-equal 'model-agent-id 'coder-1 (prompt-result-agent-id result))
  (test-equal 'model-model 'portable-coder (prompt-result-model result))
  (test-equal 'model-basis
             'model-match
             (agent-selection-basis (prompt-result-selection result)))
  (test-equal 'model-requested
             'portable-coder
             (agent-selection-field-value (prompt-result-selection result)
                                      'requested-model))))

;;;; Policy gating flows through the harness to a runner pause

(testing-registry-case
 'gated-status '(portable agent)
(let* ((harness (make-staffed-harness))
       (result (prompt harness 'edit-file
                       (list (list 'provider
                                   '((code-action (file-write "o" p))))
                             (list 'operations ops)
                             (list 'policy '((file-write needs-approval)))))))
  (test-equal 'gated-status 'selected (prompt-result-status result))
  (test-equal 'gated-state 'waiting-for-approval (prompt-result-state result))
  (test-assert 'gated-pause (task-pause? (prompt-result-receipt result)))))

;;;; Budgets: the agent budget and per-call options both reach the runner

(testing-registry-case
 'budget-from-agent '(portable agent)
(let ((registry (make-agent-registry)))
  (register-agent registry
                  (make-agent 'budgeted
                              (list (list 'role 'coder)
                                    (list 'budget '(budget (max-steps 3))))))
  (set-default-agent! registry 'budgeted)
  (let* ((harness (make-prompt-harness (list (list 'registry registry))))
         (from-agent (prompt harness 'go))
         (from-option (prompt harness 'go (list (list 'max-steps 5)))))
    (test-equal 'budget-from-agent
             3
             (task-field-value (prompt-result-budget from-agent) 'max-steps))
    (test-equal 'budget-option-overrides
             5
             (task-field-value (prompt-result-budget from-option)
               'max-steps)))))

;;;; Discovery helpers list agents, distinct roles, and distinct models

(testing-registry-case
 'discover-agents '(portable agent)
(let ((harness (make-staffed-harness)))
  (test-equal 'discover-agents
             '(default coder-1 reviewer-1)
             (map agent-id (agents harness)))
  (test-equal 'discover-roles '(planner coder reviewer) (roles harness))
  (test-equal 'discover-models
             '(auto portable-coder portable-reviewer)
             (models harness))))

;;;; The ambient current harness backs the bare verb forms

(testing-registry-case
 'consent-agent-prompt-case-12 '(portable agent)
(reset-prompt-harness!))
(testing-registry-case
 'ambient-status '(portable agent)
(let ((result (prompt 'ambient-goal)))
  (test-equal 'ambient-status 'selected (prompt-result-status result))
  (test-equal 'ambient-state 'blocked (prompt-result-state result))))

(testing-registry-case
 'ambient-installed '(portable agent)
(let ((custom (make-staffed-harness)))
  (set-current-prompt-harness! custom)
  (test-equal 'ambient-installed '(default coder-1 reviewer-1) (map agent-id
    (agents)))
  (test-equal 'ambient-role-id
             'coder-1
             (prompt-result-agent-id
          (prompt-role 'coder 'work
                       (list (list 'provider '((finish done)))
                             (list 'verifier 'passed)))))))
(testing-registry-case
 'consent-agent-prompt-case-15 '(portable agent)
(reset-prompt-harness!))

;;;; Identical prompts are deterministic and replayable

(testing-registry-case
 'prompt-deterministic '(portable agent)
(let ((harness (make-prompt-harness)))
  (test-equal 'prompt-deterministic
             (prompt harness 'replay
                 (list (list 'provider '((finish done)))
                       (list 'verifier 'passed)))
             (prompt harness 'replay
                 (list (list 'provider '((finish done)))
                       (list 'verifier 'passed))))))

(testing-runner-main "Consent Agent Prompt portable tests" (command-line))
