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
        (agent registry)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Return #t when calling THUNK raises any condition.
(define (raises? thunk)
  (call/cc
   (lambda (k)
     (with-exception-handler
      (lambda (condition) (k #t))
      (lambda () (thunk) #f)))))

;;;; Agent datum construction and accessors

(testing-registry-case
 'agent-predicate '(portable agent)
 ("consent-agent-registry-test.scm" 30)
(let ((agent (make-agent 'coder-1
                         (list (list 'name "Coder One")
                               (list 'role 'coder)
                               (list 'model 'portable-coder)
                               (list 'rules '(no-secrets))
                               (list 'skills '(edit-file))
                               (list 'budget '(budget (max-steps 8)))
                               (list 'description "Writes code.")))))
  (test-assert 'agent-predicate (agent? agent))
  (test-equal 'agent-id 'coder-1 (agent-id agent))
  (test-equal 'agent-name "Coder One" (agent-name agent))
  (test-equal 'agent-role 'coder (agent-role agent))
  (test-equal 'agent-model 'portable-coder (agent-model agent))
  (test-equal 'agent-rules '(no-secrets) (agent-rules agent))
  (test-equal 'agent-skills '(edit-file) (agent-skills agent))
  (test-equal 'agent-budget '(budget (max-steps 8)) (agent-budget agent))
  (test-equal 'agent-description "Writes code." (agent-description agent))
  (test-equal 'agent-field-value-generic 'coder (agent-field-value agent 'role))
  (test-equal 'agent-field-value-default
             'fallback
             (agent-field-value agent 'missing 'fallback))))

;; Minimal construction fills documented defaults.
(testing-registry-case
 'default-name '(portable agent)
 ("consent-agent-registry-test.scm" 56)
(let ((agent (make-agent 'minimal '())))
  (test-equal 'default-name "minimal" (agent-name agent))
  (test-equal 'default-role 'planner (agent-role agent))
  (test-equal 'default-model 'auto (agent-model agent))
  (test-equal 'default-rules '() (agent-rules agent))
  (test-equal 'default-skills '() (agent-skills agent))
  (test-equal 'default-budget 'default (agent-budget agent))
  (test-equal 'default-description "" (agent-description agent))))

(testing-registry-case
 'agent-predicate-rejects-non-agent '(portable agent)
 ("consent-agent-registry-test.scm" 68)
(test-assert 'agent-predicate-rejects-non-agent
             (not (agent? '(not-an-agent (id x))))))

;;;; Registry seeding, registration, listing, and reference

(testing-registry-case
 'registry-predicate '(portable agent)
 ("consent-agent-registry-test.scm" 76)
(let ((registry (make-agent-registry)))
  (test-assert 'registry-predicate (agent-registry? registry))
  (test-equal 'seeded-default-id 'default (default-agent-id registry))
  (test-equal 'seeded-default-role 'planner (agent-role (default-agent registry)))
  (test-equal 'seeded-agent-count 1 (length (agents registry)))
  (test-equal 'seeded-only-id '(default) (map agent-id (agents registry)))))

(testing-registry-case
 'registration-order '(portable agent)
 ("consent-agent-registry-test.scm" 86)
(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'reviewer-1 (list (list 'role 'reviewer))))
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'coder))))
  (test-equal 'registration-order
             '(default reviewer-1 coder-1)
             (map agent-id (agents registry)))
  (test-equal 'agent-ref-hit 'coder-1 (agent-id (agent-ref registry 'coder-1)))
  (test-equal 'agent-ref-miss #f (agent-ref registry 'absent))
  ;; Re-registering the same id replaces in place rather than duplicating.
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'summarizer))))
  (test-equal 'replace-keeps-count 3 (length (agents registry)))
  (test-equal 'replace-updates-role
             'summarizer
             (agent-role (agent-ref registry 'coder-1)))))

(testing-registry-case
 'register-rejects-non-agent '(portable agent)
 ("consent-agent-registry-test.scm" 104)
(test-assert 'register-rejects-non-agent
             (raises?
             (lambda ()
               (register-agent (make-agent-registry) '(not-an-agent))))))

;;;; Default agent surface

(testing-registry-case
 'set-default-returns-agent '(portable agent)
 ("consent-agent-registry-test.scm" 114)
(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'planner-2 (list (list 'role 'planner))))
  (let ((returned (set-default-agent! registry 'planner-2)))
    (test-equal 'set-default-returns-agent 'planner-2 (agent-id returned)))
  (test-equal 'default-id-updated 'planner-2 (default-agent-id registry))
  (test-equal 'default-agent-updated 'planner-2 (agent-id (default-agent registry)))
  (test-assert 'set-default-unknown-raises
             (raises? (lambda () (set-default-agent! registry 'ghost))))))

;;;; Deterministic, policy-visible automatic selection

(testing-registry-case
 'auto-is-selection '(portable agent)
 ("consent-agent-registry-test.scm" 128)
(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'coder))))
  (register-agent registry (make-agent 'reviewer-1 (list (list 'role 'reviewer))))

  ;; No configuration resolves to the default agent.
  (let ((selection (select-agent registry '())))
    (test-assert 'auto-is-selection (agent-selection? selection))
    (test-equal 'auto-status 'selected (agent-selection-status selection))
    (test-equal 'auto-basis 'default-agent (agent-selection-basis selection))
    (test-equal 'auto-agent-id 'default (agent-selection-agent-id selection))
    (test-equal 'auto-agent-datum
             'default
             (agent-id (agent-selection-agent selection)))
    (test-equal 'auto-considered
             '(default coder-1 reviewer-1)
             (agent-selection-considered selection))
    (test-assert 'auto-reason-present
             (string? (agent-selection-reason selection))))

  ;; A requested role selects the first matching agent.
  (let ((selection (select-agent registry
                                 (list (list 'role 'reviewer)
                                       (list 'goal "review the diff")
                                       (list 'session 'named-1)))))
    (test-equal 'role-basis 'role-match (agent-selection-basis selection))
    (test-equal 'role-agent-id 'reviewer-1 (agent-selection-agent-id selection))
    (test-equal 'role-records-requested-role
             'reviewer
             (agent-selection-field-value selection 'requested-role))
    (test-equal 'role-records-goal
             "review the diff"
             (agent-selection-field-value selection 'goal))
    (test-equal 'role-records-session
             'named-1
             (agent-selection-field-value selection 'session)))

  ;; A requested role with no match falls back to the default agent.
  (let ((selection (select-agent registry (list (list 'role 'unmatched)))))
    (test-equal 'role-fallback-basis 'default-agent (agent-selection-basis selection))
    (test-equal 'role-fallback-agent 'default (agent-selection-agent-id selection)))

  ;; An explicitly named agent wins over role matching.
  (let ((selection (select-agent registry
                                 (list (list 'agent 'coder-1)
                                       (list 'role 'reviewer)))))
    (test-equal 'explicit-basis 'explicit-agent (agent-selection-basis selection))
    (test-equal 'explicit-agent-id 'coder-1 (agent-selection-agent-id selection)))

  ;; An unknown explicit agent does not block role matching.
  (let ((selection (select-agent registry
                                 (list (list 'agent 'ghost)
                                       (list 'role 'coder)))))
    (test-equal 'explicit-miss-falls-to-role
             'role-match
             (agent-selection-basis selection))
    (test-equal 'explicit-miss-role-agent
             'coder-1
             (agent-selection-agent-id selection)))

  ;; The requested model is recorded for the downstream router.
  (let ((selection (select-agent registry
                                 (list (list 'model 'portable-coder)))))
    (test-equal 'records-requested-model
             'portable-coder
             (agent-selection-field-value selection 'requested-model)))

  ;; Selection is deterministic: identical inputs produce equal? records.
  (test-equal 'selection-deterministic
             (select-agent registry (list (list 'role 'coder)))
             (select-agent registry (list (list 'role 'coder))))))

;; An explicitly chosen default still reports the explicit basis.
(testing-registry-case
 'explicit-default-basis '(portable agent)
 ("consent-agent-registry-test.scm" 203)
(let ((registry (make-agent-registry)))
  (register-agent registry (make-agent 'coder-1 (list (list 'role 'coder))))
  (set-default-agent! registry 'coder-1)
  (let ((selection (select-agent registry '())))
    (test-equal 'explicit-default-basis
             'default-agent
             (agent-selection-basis selection))
    (test-equal 'explicit-default-agent
             'coder-1
             (agent-selection-agent-id selection)))))

;; A requested model selects the first matching agent, then falls back.
(testing-registry-case
 'model-match-basis '(portable agent)
 ("consent-agent-registry-test.scm" 218)
(let ((registry (make-agent-registry)))
  (register-agent registry
                  (make-agent 'cod (list (list 'role 'coder) (list 'model 'm1))))
  (let ((hit (select-agent registry (list (list 'model 'm1))))
        (miss (select-agent registry (list (list 'model 'nomatch)))))
    (test-equal 'model-match-basis 'model-match (agent-selection-basis hit))
    (test-equal 'model-match-agent 'cod (agent-selection-agent-id hit))
    (test-equal 'model-miss-basis 'default-agent (agent-selection-basis miss)))))

(testing-runner-main "Consent Agent Registry portable tests" (command-line))
