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

(let ((run (run-task 'replace-helper
                     (list (list 'provider
                                 '((code-action (file-write "out.txt" payload))
                                   (finish done)))
                           (list 'operations ops)
                           (list 'verifier 'passed)))))
  (check-true 'success-is-run (task-run? run))
  (check 'success-state (task-run-state run) 'complete)
  (check-true 'success-receipt-is-stop (task-stop? (task-run-receipt run)))
  (check 'success-stop-reason (stop-reason run) 'completed-goal)
  (check-true 'success-completion (agent-completion? (task-run-completion run)))
  (check 'success-host-calls (used run 'used-host-calls) 1)
  (check-true 'success-transcript (pair? (task-run-transcript run)))
  (check-true 'success-final-task (agent-task? (task-run-task run))))

;;;; D3: a proposed finish without a verifier pass does NOT complete

;; The model may PROPOSE finish (and may even self-assert a pass); only the
;; non-proposable verifier authorizes `complete'.  Here the verifier is
;; `insufficient', so the task blocks for evidence rather than completing.
(let ((run (run-task 'answer-question
                     (list (list 'provider '((finish "FINAL ANSWER")))
                           (list 'verifier 'insufficient)))))
  (check 'finish-unverified-state (task-run-state run) 'blocked)
  (check-true 'finish-unverified-pause (task-pause? (task-run-receipt run)))
  (check 'finish-unverified-reason (pause-reason run) 'insufficient-evidence)
  (check 'finish-unverified-no-completion (task-run-completion run) 'none))

;; The same finish with a verifier pass DOES complete.
(let ((run (run-task 'answer-question
                     (list (list 'provider '((finish "FINAL ANSWER")))
                           (list 'verifier 'passed)))))
  (check 'finish-verified-state (task-run-state run) 'complete)
  (check-true 'finish-verified-completion
              (agent-completion? (task-run-completion run))))

;;;; Blocked approval: a gated host call awaiting approval

(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write needs-approval)))))))
  (check 'approval-state (task-run-state run) 'waiting-for-approval)
  (check-true 'approval-pause (task-pause? (task-run-receipt run)))
  (check 'approval-reason (pause-reason run) 'approval-required))

;;;; User-input wait is represented as blocked, not a separate state

(let ((run (run-task 'summarize
                     (list (list 'provider '((code-action (read-file "x"))))
                           (list 'operations ops)
                           (list 'policy '((read-file needs-user-input)))))))
  (check 'user-input-state (task-run-state run) 'blocked)
  (check-true 'user-input-pause (task-pause? (task-run-receipt run)))
  (check 'user-input-reason (pause-reason run) 'waiting-for-user-input))

;;;; Waiting-for-host: a pending host effect

(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write host-pending)))))))
  (check 'host-state (task-run-state run) 'waiting-for-host)
  (check 'host-reason (pause-reason run) 'host-effect-timeout))

;;;; Waiting-for-model / provider-unavailable

(let ((run (run-task 'plan-it
                     (list (list 'provider
                                 '((model-unavailable "endpoint did not respond")))))))
  (check 'model-state (task-run-state run) 'waiting-for-model)
  (check-true 'model-pause (task-pause? (task-run-receipt run)))
  (check 'model-reason (pause-reason run) 'model-provider-unavailable))

;;;; Missing or stale authority blocks for a new grant

(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write authority-missing)))))))
  (check 'authority-state (task-run-state run) 'blocked)
  (check 'authority-reason (pause-reason run) 'authority-unavailable))

(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write stale)))))))
  (check 'stale-state (task-run-state run) 'blocked)
  (check 'stale-reason (pause-reason run) 'authority-unavailable))

;;;; Denied authority stops as cancelled with approval-denied

(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'policy '((file-write denied)))))))
  (check 'denied-state (task-run-state run) 'cancelled)
  (check-true 'denied-stop (task-stop? (task-run-receipt run)))
  (check 'denied-reason (stop-reason run) 'approval-denied))

;;;; A failed approved effect stops as failed

(let ((run (run-task 'edit-file
                     (list (list 'provider '((code-action (file-write "o" p))))
                           (list 'operations ops)
                           (list 'effects '((file-write failed)))))))
  (check 'failed-state (task-run-state run) 'failed)
  (check-true 'failed-stop (task-stop? (task-run-receipt run)))
  (check 'failed-reason (stop-reason run) 'condition-failed))

;;;; Cancellation by a control directive

(let ((run (run-task 'anything
                     (list (list 'provider '((finish done)))
                           (list 'control '(cancel))))))
  (check 'cancel-state (task-run-state run) 'cancelled)
  (check-true 'cancel-stop (task-stop? (task-run-receipt run)))
  (check 'cancel-reason (stop-reason run) 'cancelled-by-user))

;;;; D2: a control-plane proposal is quarantined with no effect

(let ((run (run-task 'escalate
                     (list (list 'provider
                                 '((code-action (grant-capability! token authority))))
                           (list 'operations ops)))))
  (check 'quarantine-state (task-run-state run) 'failed)
  (check-true 'quarantine-stop (task-stop? (task-run-receipt run)))
  (check 'quarantine-reason (stop-reason run) 'condition-failed)
  (check 'quarantine-no-effect (used run 'used-host-calls) 0)
  (check 'quarantine-observed-tag
         (car (task-field-value (task-run-receipt run) 'observed-state))
         'quarantine))

;;;; Runs are deterministic and replayable

(check 'runner-deterministic
       (run-task 'replay
                 (list (list 'provider '((finish done))) (list 'verifier 'passed)))
       (run-task 'replay
                 (list (list 'provider '((finish done))) (list 'verifier 'passed))))

(if (> failures 0)
    (error "portable agent runner tests failed" failures))
