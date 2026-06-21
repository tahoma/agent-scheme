;;; consent-agent-runner-test.el --- Minimal task runner control-loop tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent runner)' minimal control loop
;; evaluated through the Emacs Consent interpreter.  The same Scheme source
;; backs the portable host shards (tests/scheme/consent-agent-runner-test.scm),
;; so these expectations are the Emacs half of the cross-host parity check for
;; the outcome matrix, the D2 proposal quarantine (no effect), and the D3
;; finish/verifier completion split.

;;; Code:

(require 'ert)
(require 'consent-eval)
(require 'consent-result)

(defun consent-agent-runner-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(ert-deftest consent-agent-runner-test-successful-completion ()
  "A gated action then a verifier-stamped finish completes the task."
  (should
   (equal
    (consent-agent-runner-test--external
     "(import (scheme base) (agent runner) (agent task))
      (define ops '((file-write host-mutation file-system)))
      (define run
        (run-task 'replace-helper
                  (list (list 'provider
                              '((code-action (file-write \"out.txt\" payload))
                                (finish done)))
                        (list 'operations ops)
                        (list 'verifier 'passed))))
      (list (task-run-state run)
            (task-stop? (task-run-receipt run))
            (task-field-value (task-run-receipt run) 'stop-reason)
            (agent-completion? (task-run-completion run))
            (task-field-value (task-run-budget run) 'used-host-calls))")
    "(complete #t completed-goal #t 1)")))

(ert-deftest consent-agent-runner-test-finish-needs-verifier ()
  "A proposed finish without a verifier pass blocks instead of completing (D3)."
  (should
   (equal
    (consent-agent-runner-test--external
     "(import (scheme base) (agent runner) (agent task))
      (define unverified
        (run-task 'answer
                  (list (list 'provider '((finish \"FINAL ANSWER\")))
                        (list 'verifier 'insufficient))))
      (define verified
        (run-task 'answer
                  (list (list 'provider '((finish \"FINAL ANSWER\")))
                        (list 'verifier 'passed))))
      (list (task-run-state unverified)
            (task-pause? (task-run-receipt unverified))
            (task-field-value (task-run-receipt unverified) 'pause-reason)
            (task-run-completion unverified)
            (task-run-state verified))")
    "(blocked #t insufficient-evidence none complete)")))

(defun consent-agent-runner-test--capability-outcome (policy operation)
  "Run one gated OPERATION under POLICY and return (state reason).
Each scenario is its own evaluation so a single `consent-eval-source' call
stays within the interpreter's host-callback budget."
  (consent-agent-runner-test--external
   (format
    "(import (scheme base) (agent runner) (agent task))
     (define ops '((file-write host-mutation file-system)
                   (read-file host-observation file-system)))
     (define run
       (run-task 'edit
                 (list (list 'provider (list (list 'code-action '%s)))
                       (list 'operations ops)
                       (list 'policy '%s))))
     (list (task-run-state run)
           (or (task-field-value (task-run-receipt run) 'pause-reason)
               (task-field-value (task-run-receipt run) 'stop-reason)))"
    operation policy)))

(ert-deftest consent-agent-runner-test-capability-outcomes ()
  "Approval, user-input, host, missing, and denied authority pick the right state."
  (should (equal (consent-agent-runner-test--capability-outcome
                  "((file-write needs-approval))" "(file-write \"o\" p)")
                 "(waiting-for-approval approval-required)"))
  (should (equal (consent-agent-runner-test--capability-outcome
                  "((read-file needs-user-input))" "(read-file \"x\")")
                 "(blocked waiting-for-user-input)"))
  (should (equal (consent-agent-runner-test--capability-outcome
                  "((file-write host-pending))" "(file-write \"o\" p)")
                 "(waiting-for-host host-effect-timeout)"))
  (should (equal (consent-agent-runner-test--capability-outcome
                  "((file-write authority-missing))" "(file-write \"o\" p)")
                 "(blocked authority-unavailable)"))
  (should (equal (consent-agent-runner-test--capability-outcome
                  "((file-write denied))" "(file-write \"o\" p)")
                 "(cancelled approval-denied)")))

(ert-deftest consent-agent-runner-test-provider-unavailable ()
  "An unavailable provider pauses as waiting-for-model."
  (should
   (equal
    (consent-agent-runner-test--external
     "(import (scheme base) (agent runner) (agent task))
      (define run
        (run-task 'plan
                  (list (list 'provider '((model-unavailable \"no response\"))))))
      (list (task-run-state run)
            (task-pause? (task-run-receipt run))
            (task-field-value (task-run-receipt run) 'pause-reason))")
    "(waiting-for-model #t model-provider-unavailable)")))

(ert-deftest consent-agent-runner-test-failed-and-cancelled ()
  "A failed effect fails; a cancel directive cancels."
  (should
   (equal
    (consent-agent-runner-test--external
     "(import (scheme base) (agent runner) (agent task))
      (define ops '((file-write host-mutation file-system)))
      (define failed
        (run-task 'edit
                  (list (list 'provider '((code-action (file-write \"o\" p))))
                        (list 'operations ops)
                        (list 'effects '((file-write failed))))))
      (define cancelled
        (run-task 'edit
                  (list (list 'provider '((finish done)))
                        (list 'control '(cancel)))))
      (list (task-run-state failed)
            (task-field-value (task-run-receipt failed) 'stop-reason)
            (task-run-state cancelled)
            (task-field-value (task-run-receipt cancelled) 'stop-reason))")
    "(failed condition-failed cancelled cancelled-by-user)")))

(ert-deftest consent-agent-runner-test-quarantine-performs-no-effect ()
  "A control-plane proposal is quarantined and performs no host effect (D2)."
  (should
   (equal
    (consent-agent-runner-test--external
     "(import (scheme base) (agent runner) (agent task))
      (define ops '((file-write host-mutation file-system)))
      (define run
        (run-task 'escalate
                  (list (list 'provider
                              '((code-action (grant-capability! token authority))))
                        (list 'operations ops))))
      (list (task-run-state run)
            (task-stop? (task-run-receipt run))
            (task-field-value (task-run-receipt run) 'stop-reason)
            (task-field-value (task-run-budget run) 'used-host-calls)
            (car (task-field-value (task-run-receipt run) 'observed-state)))")
    "(failed #t condition-failed 0 quarantine)")))

(ert-deftest consent-agent-runner-test-runs-are-deterministic ()
  "Identical inputs produce equal, replayable task-run records."
  (should
   (equal
    (consent-agent-runner-test--external
     "(import (scheme base) (agent runner))
      (equal? (run-task 'replay
                        (list (list 'provider '((finish done)))
                              (list 'verifier 'passed)))
              (run-task 'replay
                        (list (list 'provider '((finish done)))
                              (list 'verifier 'passed))))")
    "#t")))

(provide 'consent-agent-runner-test)
;;; consent-agent-runner-test.el ends here
