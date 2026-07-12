;;; Portable Agent Task semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (agent task)
        (testing harness)
        (stdlib testing)
        (stdlib eager-comprehensions)
        (stdlib lightweight-testing))

(define (raises? thunk)
  "Return true when THUNK raises."
  (guard (condition (else #t)) (thunk) #f))

(consent-test-run "Agent Task portable semantics"
  (test-assert "created to observing"
               (task-transition-allowed? 'created 'observing))
  (test-assert "created to complete rejected"
               (not (task-transition-allowed? 'created 'complete)))
  (test-assert "invalid transition raises"
               (raises? (lambda ()
                          (validate-task-transition 'created 'complete))))
  (let* ((task
          (make-agent-task
           'task-1 "Ship task records." 'session-1
           '((plan . plan-1)
             (transcript . transcript-1)
             (budget . (task-budget (max-steps 10)))
             (audit . audit-1))))
         (pause
          (make-task-pause
           'task-1 'waiting-for-model 'model-provider-unavailable
           '((observed-state . (observation-set obs-1))
             (intended-next-action . action-1)
             (capability-gate . none)
             (model-route . (model-routing-decision (status selected)))
             (approval-status . none)
             (verifier-result . not-run)))))
    (test-assert "agent task record" (agent-task? task))
    (test-assert "task record valid" (task-record-valid? task))
    (test-assert "pause record" (task-pause? pause))
    (test-assert "pause record valid" (task-record-valid? pause))
    (test-equal "task id" 'task-1 (task-field-value task 'id #f))
    (test-equal "task starts created" 'created
                (task-field-value task 'state #f)))
  (test-assert "malformed record rejected"
               (not (task-record-valid? '(agent-task (id incomplete)))))
  (consent-test-check
   "lightweight eager state table" 1
   (check-ec (:list state task-states)
             (task-state? state)
             => #t
             (state))))
