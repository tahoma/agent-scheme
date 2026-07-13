;;; Portable Consent Scheme minimal task runner control-loop tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent runner)' minimal control loop directly: it drives one user goal
;;; through observing/planning/acting and asserts the full outcome matrix --
;;; completion, blocked approval, user-input wait as blocked, waiting-for-host,
;;; waiting-for-model/provider-unavailable, missing/denied authority, failed
;;; action, cancellation, the D2 proposal quarantine (no effect), and the D3
;;; finish/verifier split -- plus the pause/stop receipt shapes.  It loads no
;;; Emacs host adapter; the same source backs the Emacs interpreter, so passing
;;; here is the portable half of the cross-host parity check.

(import (scheme base)
        (scheme write)
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

;; Canonical model-tool signatures generated from typed docstring metadata.
(define capability-signatures
  '((model-tool
     (name file-write)
     (parameters
      ((path (type string) (description "Destination path."))
       (content (type string) (description "Text to write."))))
     (effects (file-write))
     (gate (tool-gate (decision capability-request)
                      (effects (file-write)))))))

;; Read the stop reason carried by a run's receipt.
(define (stop-reason run)
  (task-field-value (task-run-receipt run) 'stop-reason))

;; Read the pause reason carried by a run's receipt.
(define (pause-reason run)
  (task-field-value (task-run-receipt run) 'pause-reason))

;; Read a usage counter from a run's budget ledger.
(define (used run field)
  (task-field-value (task-run-budget run) field))

;;;; Successful completion: a gated action then a verifier-stamped finish

(testing-registry-case
 'success-is-run '(portable agent)
(let ((run (run-task 'replace-helper
                     (list (list 'provider
                                 '((code-action (file-write "out.txt" payload))
                                   (finish done)))
                           (list 'operations ops)
                           (list 'verifier 'passed)))))
  (test-assert 'success-is-run (task-run? run))
  (test-equal 'success-state 'complete (task-run-state run))
  (test-assert 'success-receipt-is-stop (task-stop? (task-run-receipt run)))
  (test-equal 'success-stop-reason 'completed-goal (stop-reason run))
  (test-assert 'success-completion (agent-completion? (task-run-completion run)))
  (test-equal 'success-host-calls 1 (used run 'used-host-calls))
  (test-assert 'success-transcript (pair? (task-run-transcript run)))
  (test-assert 'success-final-task (agent-task? (task-run-task run)))))

;;;; D3: a proposed finish without a verifier pass does NOT complete

;; The model may PROPOSE finish (and may even self-assert a pass); only the
;; non-proposable verifier authorizes `complete'.  Here the verifier is
;; `insufficient', so the task blocks for evidence rather than completing.
(testing-registry-case
 'finish-unverified-state '(portable agent)
(let ((run (run-task 'answer-question
                     (list (list 'provider '((finish "FINAL ANSWER")))
                           (list 'verifier 'insufficient)))))
  (test-equal 'finish-unverified-state 'blocked (task-run-state run))
  (test-assert 'finish-unverified-pause (task-pause? (task-run-receipt run)))
  (test-equal 'finish-unverified-reason 'insufficient-evidence (pause-reason run))
  (test-equal 'finish-unverified-no-completion 'none (task-run-completion run))))

;; The same finish with a verifier pass DOES complete.
(testing-registry-case
 'finish-verified-state '(portable agent)
(let ((run (run-task 'answer-question
                     (list (list 'provider '((finish "FINAL ANSWER")))
                           (list 'verifier 'passed)))))
  (test-equal 'finish-verified-state 'complete (task-run-state run))
  (test-assert 'finish-verified-completion
             (agent-completion? (task-run-completion run)))))

;;;; Blocked approval: a gated host call awaiting approval

(testing-registry-case
 'approval-state '(portable agent)
(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write needs-approval)))))))
  (test-equal 'approval-state 'waiting-for-approval (task-run-state run))
  (test-assert 'approval-pause (task-pause? (task-run-receipt run)))
  (test-equal 'approval-reason 'approval-required (pause-reason run))))

;;;; User-input wait is represented as blocked, not a separate state

(testing-registry-case
 'user-input-state '(portable agent)
(let ((run (run-task 'summarize
                     (list (list 'provider '((code-action (read-file "x"))))
                           (list 'operations ops)
                           (list 'policy '((read-file needs-user-input)))))))
  (test-equal 'user-input-state 'blocked (task-run-state run))
  (test-assert 'user-input-pause (task-pause? (task-run-receipt run)))
  (test-equal 'user-input-reason 'waiting-for-user-input (pause-reason run))))

;;;; Waiting-for-host: a pending host effect

(testing-registry-case
 'host-state '(portable agent)
(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write host-pending)))))))
  (test-equal 'host-state 'waiting-for-host (task-run-state run))
  (test-equal 'host-reason 'host-effect-timeout (pause-reason run))))

;;;; Waiting-for-model / provider-unavailable

(testing-registry-case
 'model-state '(portable agent)
(let ((run (run-task 'plan-it
                     (list (list 'provider
                                 '((model-unavailable "endpoint did not respond")))))))
  (test-equal 'model-state 'waiting-for-model (task-run-state run))
  (test-assert 'model-pause (task-pause? (task-run-receipt run)))
  (test-equal 'model-reason 'model-provider-unavailable (pause-reason run))))

;;;; Missing or stale authority blocks for a new grant

(testing-registry-case
 'authority-state '(portable agent)
(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write authority-missing)))))))
  (test-equal 'authority-state 'blocked (task-run-state run))
  (test-equal 'authority-reason 'authority-unavailable (pause-reason run))))

(testing-registry-case
 'stale-state '(portable agent)
(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write stale)))))))
  (test-equal 'stale-state 'blocked (task-run-state run))
  (test-equal 'stale-reason 'authority-unavailable (pause-reason run))))

;;;; Denied authority stops as cancelled with approval-denied

(testing-registry-case
 'denied-state '(portable agent)
(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write denied)))))))
  (test-equal 'denied-state 'cancelled (task-run-state run))
  (test-assert 'denied-stop (task-stop? (task-run-receipt run)))
  (test-equal 'denied-reason 'approval-denied (stop-reason run))))

;;;; A failed approved effect stops as failed

(testing-registry-case
 'failed-state '(portable agent)
(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'effects '((file-write failed)))))))
  (test-equal 'failed-state 'failed (task-run-state run))
  (test-assert 'failed-stop (task-stop? (task-run-receipt run)))
  (test-equal 'failed-reason 'condition-failed (stop-reason run))))

;;;; Cancellation by a control directive

(testing-registry-case
 'cancel-state '(portable agent)
(let ((run (run-task 'anything
                     (list (list 'provider '((finish done)))
                           (list 'control '(cancel))))))
  (test-equal 'cancel-state 'cancelled (task-run-state run))
  (test-assert 'cancel-stop (task-stop? (task-run-receipt run)))
  (test-equal 'cancel-reason 'cancelled-by-user (stop-reason run))))

;;;; D2: a control-plane proposal is quarantined with no effect

(testing-registry-case
 'quarantine-state '(portable agent)
(let ((run (run-task 'escalate
                     (list (list 'provider
                                 '((code-action (grant-capability! token authority))))
                           (list 'operations ops)))))
  (test-equal 'quarantine-state 'failed (task-run-state run))
  (test-assert 'quarantine-stop (task-stop? (task-run-receipt run)))
  (test-equal 'quarantine-reason 'condition-failed (stop-reason run))
  (test-equal 'quarantine-no-effect 0 (used run 'used-host-calls))
  (test-equal 'quarantine-observed-tag
             'quarantine
             (car (task-field-value (task-run-receipt run) 'observed-state)))))

;;;; Signature admission failures produce typed capability-decision receipts

(define (capability-gate-reason run)
  (task-field-value
   (task-field-value (task-run-receipt run) 'capability-gate)
   'reason))

(testing-registry-case
 'hallucinated-tool-state '(portable agent)
(let ((run (run-task 'call-tool
                     (list (list 'provider
                                 '((code-action
                                    (imaginary-tool "notes.txt"))))
                           (list 'capability-signatures
                                 capability-signatures)))))
  (test-equal 'hallucinated-tool-state 'failed (task-run-state run))
  (test-equal 'hallucinated-tool-reason
             'hallucinated-tool
             (capability-gate-reason run))
  (test-equal 'hallucinated-tool-no-effect
             0
             (used run 'used-host-calls))))

(testing-registry-case
 'misapplied-tool-state '(portable agent)
(let ((run (run-task 'call-tool
                     (list (list 'provider
                                 '((code-action
                                    (file-write 42 "payload"))))
                           (list 'capability-signatures
                                 capability-signatures)))))
  (test-equal 'misapplied-tool-state 'failed (task-run-state run))
  (test-equal 'misapplied-tool-reason
             'misapplied-tool
             (capability-gate-reason run))
  (test-equal 'misapplied-tool-no-effect
             0
             (used run 'used-host-calls))))

(testing-registry-case
 'unauthorized-tool-state '(portable agent)
(let ((run (run-task 'call-tool
                     (list (list 'provider
                                 '((code-action
                                    (file-write "notes.txt" "payload"))))
                           (list 'capability-signatures
                                 capability-signatures)
                           (list 'policy '((file-write denied)))))))
  (test-equal 'unauthorized-tool-state 'cancelled (task-run-state run))
  (test-equal 'unauthorized-tool-reason
             'unauthorized-tool
             (capability-gate-reason run))
  (test-equal 'unauthorized-tool-no-effect
             0
             (used run 'used-host-calls))))

;;;; Runs are deterministic and replayable

(testing-registry-case
 'runner-deterministic '(portable agent)
(test-equal 'runner-deterministic
             (run-task 'replay
                 (list (list 'provider '((finish done))) (list 'verifier 'passed)))
             (run-task 'replay
                 (list (list 'provider '((finish done))) (list 'verifier 'passed)))))

(testing-runner-main "Consent Agent Runner portable tests" (command-line))
