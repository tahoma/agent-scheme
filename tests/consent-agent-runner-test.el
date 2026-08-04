;;; consent-agent-runner-test.el -*- lexical-binding: t; -*-
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
(require 'seq)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-result)

(defconst consent-agent-runner-test--fixture-path
  "fixtures/agent/task-lifecycle.scm"
  "Repository-relative path to shared task lifecycle fixture records.")

(defun consent-agent-runner-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(defun consent-agent-runner-test--fixture ()
  "Return the parsed shared task lifecycle fixture datum."
  (let* ((path (expand-file-name
                consent-agent-runner-test--fixture-path
                consent--test-root))
         (forms (consent-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (car forms)))

(defun consent-agent-runner-test--symbol-name (value)
  "Return VALUE as a stable symbol name."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun consent-agent-runner-test--named-p (datum name)
  "Return non-nil when DATUM is a field or record named NAME."
  (and (consp datum)
       (equal (consent-agent-runner-test--symbol-name (car datum))
              name)))

(defun consent-agent-runner-test--field (datum name &optional default)
  "Return field NAME from DATUM, or DEFAULT when absent."
  (let* ((fields (if (consp (car-safe datum)) datum (cdr-safe datum)))
         (field
          (seq-find
           (lambda (candidate)
             (consent-agent-runner-test--named-p candidate name))
           fields)))
    (if field (cadr field) default)))

(defun consent-agent-runner-test--fixture-section (fixture name)
  "Return section NAME's list payload from FIXTURE."
  (cdr
   (seq-find
    (lambda (section)
      (consent-agent-runner-test--named-p section name))
    (cdr-safe fixture))))

(defun consent-agent-runner-test--scenario (id)
  "Return shared control-loop fixture scenario ID."
  (let* ((fixture (consent-agent-runner-test--fixture))
         (scenarios
          (consent-agent-runner-test--fixture-section
           fixture
           "control-loop-scenarios")))
    (or (seq-find
         (lambda (scenario)
           (equal (consent-agent-runner-test--symbol-name
                   (consent-agent-runner-test--field scenario "id"))
                  (symbol-name id)))
         scenarios)
        (ert-fail (format "Missing control-loop fixture %S" id)))))

(ert-deftest consent-agent-runner-test-consumes-control-loop-fixture ()
  "The minimal runner consumes a shared #287 control-loop fixture."
  (let* ((scenario
          (consent-agent-runner-test--scenario 'successful-completion))
         (runner (consent-agent-runner-test--field scenario "runner"))
         (expect (consent-agent-runner-test--field scenario "expect"))
         (budget (consent-agent-runner-test--field expect "budget"))
         (goal (consent-agent-runner-test--field runner "goal"))
         (options (consent-agent-runner-test--field runner "options"))
         (expected
          (consent-datum->external
           (list (consent-agent-runner-test--field expect "state")
                 (consent-agent-runner-test--field expect "receipt")
                 (consent-agent-runner-test--field expect "reason")
                 (consent-agent-runner-test--field budget
                   "used-host-calls")))))
    (should
     (equal
      (consent-agent-runner-test--external
       (format
        "(import (scheme base) (agent runner) (agent task))
         (define run
           (run-task (quote %s) (quote %s)))
         (define receipt (task-run-receipt run))
         (list (task-run-state run)
               (if (task-stop? receipt) 'task-stop 'task-pause)
               (or (task-field-value receipt 'stop-reason)
                   (task-field-value receipt 'pause-reason))
               (task-field-value (task-run-budget run) 'used-host-calls))"
        (consent-datum->external goal)
        (consent-datum->external options)))
      expected))))

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
  "A proposed finish without a verifier pass blocks instead of completing\
 (D3)."
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
  "Approval, user-input, host, missing, and denied authority pick the right\
 state."
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
                  (list (list 'provider '((model-unavailable \"no\
 response\"))))))
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
                              '((code-action (grant-capability! token\
 authority))))
                        (list 'operations ops))))
      (list (task-run-state run)
            (task-stop? (task-run-receipt run))
            (task-field-value (task-run-receipt run) 'stop-reason)
            (task-field-value (task-run-budget run) 'used-host-calls)
            (car (task-field-value (task-run-receipt run) 'observed-state)))")
    "(failed #t condition-failed 0 quarantine)")))

(defun consent-agent-runner-test--signature-outcome (form &optional policy)
  "Run FORM through the signature gate with optional POLICY."
  (consent-agent-runner-test--external
   (format
    "(import (scheme base) (agent runner) (agent task))
     (define signatures
       '((model-tool
          (name file-write)
          (parameters
           ((path (type string) (description \"Destination path.\"))
            (content (type string) (description \"Text to write.\"))))
          (effects (file-write))
          (gate (tool-gate (decision capability-request)
                           (effects (file-write)))))))
     (define run
       (run-task 'call-tool
                 (list (list 'provider (list (list 'code-action '%s)))
                       (list 'capability-signatures signatures)
                       (list 'policy '%s))))
     (define gate
       (task-field-value (task-run-receipt run) 'capability-gate))
     (list (task-run-state run)
           (task-field-value gate 'reason)
           (task-field-value (task-run-budget run) 'used-host-calls))"
    form
    (or policy '()))))

(ert-deftest consent-agent-runner-test-signature-admission-receipts ()
  "Hallucinated, misapplied, and unauthorized tool calls get typed receipts."
  (should
   (equal
    (consent-agent-runner-test--signature-outcome
     "(imaginary-tool \"notes.txt\")")
    "(failed hallucinated-tool 0)"))
  (should
   (equal
    (consent-agent-runner-test--signature-outcome
     "(file-write 42 \"payload\")")
    "(failed misapplied-tool 0)"))
  (should
   (equal
    (consent-agent-runner-test--signature-outcome
     "(file-write \"notes.txt\" \"payload\")"
     '((file-write denied)))
    "(cancelled unauthorized-tool 0)")))

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
