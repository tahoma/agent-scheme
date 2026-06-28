;;; consent-agent-prompt-test.el --- REPL agent-harness verb tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent prompt)' REPL harness evaluated
;; through the Emacs Consent interpreter.  The same Scheme source backs the
;; portable host shards (tests/scheme/consent-agent-prompt-test.scm), so these
;; expectations are the Emacs half of the cross-host parity check for the
;; `prompt'/`prompt-role'/`prompt-model' verbs, fail-closed dispatch without
;; session authority, budget threading, the result/receipt/audit surface, the
;; discovery helpers, and the ambient current harness.

;;; Code:

(require 'ert)
(require 'consent-eval)
(require 'consent-result)

(defun consent-agent-prompt-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(ert-deftest consent-agent-prompt-test-verified-finish-completes ()
  "A verified finish completes through the harness and is fully inspectable."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt) (agent runner) (agent task))
      (define harness (make-prompt-harness))
      (define result
        (prompt harness 'finish-the-goal
                '((provider ((finish done))) (verifier passed))))
      (list (prompt-result? result)
            (prompt-result-status result)
            (prompt-result-ok? result)
            (prompt-result-state result)
            (task-run? (prompt-result-run result))
            (task-stop? (prompt-result-receipt result))
            (agent-completion? (prompt-result-completion result))
            (pair? (prompt-result-transcript result))
            (prompt-result-agent-id result)
            (prompt-result-role result)
            (prompt-result-session result))")
    "(#t selected #t complete #t #t #t #t default planner project-main)")))

(ert-deftest consent-agent-prompt-test-audit-trail ()
  "A dispatched prompt records selection and model-route audit entries."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define result
        (prompt (make-prompt-harness) 'go
                '((provider ((finish done))) (verifier passed))))
      (map (lambda (entry) (cadr (assq 'kind (cdr entry))))
           (prompt-result-audit result))")
    "(agent-selected model-route)")))

(ert-deftest consent-agent-prompt-test-no-provider-pauses ()
  "With no provider the harness returns an inspectable blocked pause."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt) (agent task))
      (define result (prompt (make-prompt-harness) 'do-a-thing))
      (list (prompt-result-status result)
            (prompt-result-state result)
            (task-pause? (prompt-result-receipt result)))")
    "(selected blocked #t)")))

(ert-deftest consent-agent-prompt-test-fails-closed-without-authority ()
  "Without session authority the harness refuses to run and audits the denial."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define harness (make-prompt-harness '((authority #f))))
      (define result
        (prompt harness 'sensitive
                '((provider ((finish done))) (verifier passed))))
      (list (prompt-result-status result)
            (prompt-result-ok? result)
            (prompt-result-state result)
            (prompt-result-run result)
            (car (prompt-result-receipt result))
            (cadr (assq 'reason (cdr (prompt-result-receipt result))))
            (map (lambda (entry) (cadr (assq 'kind (cdr entry))))
                 (prompt-result-audit result)))")
    "(authority-missing #f failed-closed none prompt-error authority-missing (authority-denied))")))

(ert-deftest consent-agent-prompt-test-fails-closed-without-session ()
  "Without a current session the harness fails closed before dispatch."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define harness (make-prompt-harness '((session #f))))
      (define result (prompt harness 'orphan))
      (list (prompt-result-status result) (prompt-result-state result))")
    "(no-session failed-closed)")))

(ert-deftest consent-agent-prompt-test-prompt-role-forces-role ()
  "`prompt-role' selects the first agent matching the requested role."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'coder-1 '((role coder))))
      (register-agent registry (make-agent 'reviewer-1 '((role reviewer))))
      (define harness (make-prompt-harness (list (list 'registry registry))))
      (define result
        (prompt-role harness 'reviewer 'review-the-diff
                     '((provider ((finish done))) (verifier passed))))
      (list (prompt-result-agent-id result)
            (prompt-result-role result)
            (agent-selection-basis (prompt-result-selection result))
            (prompt-result-state result))")
    "(reviewer-1 reviewer role-match complete)")))

(ert-deftest consent-agent-prompt-test-prompt-model-forces-model ()
  "`prompt-model' selects the first agent matching the requested model."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'coder-1 '((role coder) (model portable-coder))))
      (define harness (make-prompt-harness (list (list 'registry registry))))
      (define result (prompt-model harness 'portable-coder 'build-it))
      (list (prompt-result-status result)
            (prompt-result-agent-id result)
            (prompt-result-model result)
            (agent-selection-basis (prompt-result-selection result))
            (agent-selection-field-value (prompt-result-selection result)
                                         'requested-model))")
    "(selected coder-1 portable-coder model-match portable-coder)")))

(ert-deftest consent-agent-prompt-test-policy-gating-pauses ()
  "Policy gating flows through the harness to a runner approval pause."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt) (agent task))
      (define ops '((file-write host-mutation file-system)))
      (define result
        (prompt (make-prompt-harness) 'edit-file
                (list (list 'provider '((code-action (file-write \"o\" p))))
                      (list 'operations ops)
                      (list 'policy '((file-write needs-approval))))))
      (list (prompt-result-status result)
            (prompt-result-state result)
            (task-pause? (prompt-result-receipt result)))")
    "(selected waiting-for-approval #t)")))

(ert-deftest consent-agent-prompt-test-budgets-reach-runner ()
  "The agent budget and per-call options both reach the task runner."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt) (agent task))
      (define registry (make-agent-registry))
      (register-agent registry
                      (make-agent 'budgeted
                                  '((role coder) (budget (budget (max-steps 3))))))
      (set-default-agent! registry 'budgeted)
      (define harness (make-prompt-harness (list (list 'registry registry))))
      (list (task-field-value (prompt-result-budget (prompt harness 'go))
                              'max-steps)
            (task-field-value
             (prompt-result-budget (prompt harness 'go '((max-steps 5))))
             'max-steps))")
    "(3 5)")))

(ert-deftest consent-agent-prompt-test-discovery-helpers ()
  "`agents', `roles', and `models' list the harness registry contents."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'coder-1 '((role coder) (model m1))))
      (register-agent registry (make-agent 'reviewer-1 '((role reviewer) (model m1))))
      (define harness (make-prompt-harness (list (list 'registry registry))))
      (list (map agent-id (agents harness))
            (roles harness)
            (models harness))")
    "((default coder-1 reviewer-1) (planner coder reviewer) (auto m1))")))

(ert-deftest consent-agent-prompt-test-ambient-harness ()
  "The ambient current harness backs the bare verb and discovery forms."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (reset-prompt-harness!)
      (define before (prompt-result-status (prompt 'ambient-goal)))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'coder-1 '((role coder))))
      (set-current-prompt-harness!
       (make-prompt-harness (list (list 'registry registry))))
      (list before
            (map agent-id (agents))
            (prompt-result-agent-id
             (prompt-role 'coder 'work
                          '((provider ((finish done))) (verifier passed)))))")
    "(selected (default coder-1) coder-1)")))

(ert-deftest consent-agent-prompt-test-deterministic ()
  "Identical prompts produce equal, replayable result records."
  (should
   (equal
    (consent-agent-prompt-test--external
     "(import (scheme base) (agent prompt))
      (define harness (make-prompt-harness))
      (equal? (prompt harness 'replay
                      '((provider ((finish done))) (verifier passed)))
              (prompt harness 'replay
                      '((provider ((finish done))) (verifier passed))))")
    "#t")))

(provide 'consent-agent-prompt-test)
;;; consent-agent-prompt-test.el ends here
