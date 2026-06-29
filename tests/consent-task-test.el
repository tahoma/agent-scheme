;;; consent-task-test.el --- Task lifecycle record tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for public task lifecycle datums, state transitions,
;; receipts, and fixture scenarios used by the control-loop follow-up work.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-reader)
(require 'consent-result)
(require 'consent-task)

(defconst consent-task-test--fixture-path
  "fixtures/agent/task-lifecycle.scm"
  "Repository-relative path to task lifecycle fixture records.")

(defun consent-task-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-task-test--field (datum name)
  "Return field NAME from Scheme-readable DATUM."
  (consent-task-field-value datum name))

(defun consent-task-test--fixture ()
  "Return the parsed task lifecycle fixture datum."
  (let* ((path (expand-file-name
                consent-task-test--fixture-path
                consent--test-root))
         (forms (consent-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (car forms)))

(defun consent-task-test--symbol-name (value)
  "Return VALUE as a stable symbol name."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun consent-task-test--named-p (datum name)
  "Return non-nil when DATUM is a record tagged NAME."
  (and (consp datum)
       (equal (consent-task-test--symbol-name (car datum)) name)))

(defun consent-task-test--section (record name)
  "Return RECORD section NAME."
  (seq-find
   (lambda (field)
     (consent-task-test--named-p field name))
   (if (consp (car-safe record))
       record
     (cdr-safe record))))

(defun consent-task-test--section-value (record name)
  "Return the first value from RECORD section NAME."
  (cadr (consent-task-test--section record name)))

(defun consent-task-test--datum-field (datum name &optional default)
  "Return field NAME from tagged DATUM, or DEFAULT when absent."
  (let* ((fields (if (consp (car-safe datum)) datum (cdr-safe datum)))
         (field
          (seq-find
           (lambda (candidate)
             (consent-task-test--named-p candidate name))
           fields)))
    (if field (cadr field) default)))

(defun consent-task-test--scenario-field (scenario name)
  "Return SCENARIO field NAME."
  (consent-task-test--section-value scenario name))

(defun consent-task-test--fixture-section (fixture name)
  "Return the list payload for FIXTURE section NAME."
  (cdr (consent-task-test--section fixture name)))

(defun consent-task-test--scenario-by-id (scenarios id)
  "Return scenario ID from SCENARIOS."
  (or (seq-find
       (lambda (scenario)
         (equal (consent-task-test--symbol-name
                 (consent-task-test--scenario-field scenario "id"))
                (symbol-name id)))
       scenarios)
      (ert-fail (format "Missing scenario %S" id))))

(defun consent-task-test--signal (kind &optional fields)
  "Signal a structured task fixture validation error KIND with FIELDS."
  (signal 'consent-task-error
          (list (consent-task-condition kind fields))))

(defun consent-task-test--symbol-in-p (value symbols)
  "Return non-nil when VALUE names a member of SYMBOLS."
  (member (consent-task-test--symbol-name value)
          (mapcar #'symbol-name symbols)))

(defun consent-task-test--event-before-p (events before after)
  "Return non-nil when BEFORE appears in EVENTS before AFTER."
  (let ((before-index (seq-position events before))
        (after-index (seq-position events after)))
    (and before-index after-index (< before-index after-index))))

(defun consent-task-test--validate-event-order (events)
  "Validate control-loop transcript event order EVENTS."
  (when (and events (not (eq (car events) 'agent-yield)))
    (consent-task-test--signal
     'inconsistent-event-order
     `((first-event . ,(car events)))))
  (when (consent-task-test--event-before-p events
                                           'capability-call
                                           'model-route)
    (consent-task-test--signal
     'inconsistent-event-order
     '((capability-call . before-model-route))))
  t)

(defun consent-task-test--validate-control-loop-scenario (scenario)
  "Validate one shared control-loop fixture SCENARIO."
  (let* ((id (consent-task-test--scenario-field scenario "id"))
         (status (consent-task-test--scenario-field scenario "status"))
         (runner (consent-task-test--scenario-field scenario "runner"))
         (expect (consent-task-test--scenario-field scenario "expect"))
         (records (consent-task-test--scenario-field scenario "records"))
         (receipt (consent-task-test--datum-field expect "receipt"))
         (state (consent-task-test--datum-field expect "state"))
         (reason (consent-task-test--datum-field expect "reason"))
         (event-order (consent-task-test--datum-field expect "event-order"))
         (budget (consent-task-test--datum-field expect "budget"))
         (policy-bypass
          (consent-task-test--datum-field expect "policy-bypass")))
    (should id)
    (should (consent-task-test--symbol-in-p
             status
             '(implemented pending policy-gated unavailable)))
    (should runner)
    (should expect)
    (should records)
    (should (consent-task-test--symbol-in-p state consent-task-states))
    (pcase (consent-task-test--symbol-name receipt)
      ("task-pause"
       (should (consent-task-test--symbol-in-p
                state consent-task-pause-states))
       (should (consent-task-test--symbol-in-p
                reason consent-task-pause-reasons)))
      ("task-stop"
       (should (consent-task-test--symbol-in-p
                state consent-task-terminal-states))
       (should (consent-task-test--symbol-in-p
                reason consent-task-stop-reasons)))
      (_
       (consent-task-test--signal
        'malformed-receipt-expectation
        `((scenario . ,(consent-task-test--symbol-name id))))))
    (when (equal (consent-task-test--symbol-name reason) "budget-exhausted")
      (unless budget
        (consent-task-test--signal
         'missing-budget-ledger
         `((scenario . ,(consent-task-test--symbol-name id))))))
    (when (equal (consent-task-test--symbol-name id) "user-input-wait")
      (should (equal (consent-task-test--symbol-name state) "blocked"))
      (should (equal (consent-task-test--symbol-name reason)
                     "waiting-for-user-input")))
    (when policy-bypass
      (unless (equal (consent-task-test--symbol-name policy-bypass) "denied")
        (consent-task-test--signal
         'policy-bypass-not-denied
         `((scenario . ,(consent-task-test--symbol-name id))))))
    (when event-order
      (consent-task-test--validate-event-order
       (mapcar (lambda (event)
                 (intern (consent-task-test--symbol-name event)))
               event-order)))
    (dolist (record records)
      (consent-task-validate-record record))
    t))

(defun consent-task-test--validate-invalid-control-loop-scenario (scenario)
  "Validate that malformed control-loop SCENARIO is rejected."
  (let ((kind (consent-task-test--scenario-field scenario "kind")))
    (pcase (consent-task-test--symbol-name kind)
      ("malformed-task-record"
       (consent-task-validate-record
        (consent-task-test--scenario-field scenario "datum")))
      ("invalid-state-transition"
       (let ((transition
              (consent-task-test--scenario-field scenario "transition")))
         (consent-task-validate-transition (car transition) (cadr transition))))
      ("malformed-pause-receipt"
       (consent-task-validate-record
        (consent-task-test--scenario-field scenario "datum")))
      ("malformed-stop-receipt"
       (consent-task-validate-record
        (consent-task-test--scenario-field scenario "datum")))
      ("inconsistent-event-order"
       (consent-task-test--validate-event-order
        (mapcar (lambda (event)
                  (intern (consent-task-test--symbol-name event)))
                (consent-task-test--scenario-field scenario "event-order"))))
      ("missing-budget-stop-receipt"
       (consent-task-test--validate-control-loop-scenario
        (consent-task-test--scenario-field scenario "scenario")))
      ("policy-bypass"
       (consent-task-test--validate-control-loop-scenario
        (consent-task-test--scenario-field scenario "scenario")))
      (_
       (ert-fail (format "Unknown invalid scenario kind %S" kind))))))

(ert-deftest consent-task-test-state-vocabulary-and-transitions ()
  "The public state vocabulary and transition table match the control loop."
  (should (equal consent-task-states
                 '(created observing planning acting
                           waiting-for-approval waiting-for-model
                           waiting-for-host blocked cancelled failed complete)))
  (dolist (state consent-task-states)
    (should (consent-task-state-p state)))
  (dolist (transition '((created observing)
                        (created cancelled)
                        (observing planning)
                        (observing waiting-for-host)
                        (planning acting)
                        (planning waiting-for-model)
                        (acting observing)
                        (acting waiting-for-approval)
                        (acting complete)
                        (waiting-for-approval acting)
                        (waiting-for-model planning)
                        (waiting-for-host observing)
                        (blocked acting)))
    (should
     (consent-task-transition-allowed-p
      (car transition)
      (cadr transition))))
  (dolist (transition '((created complete)
                        (complete acting)
                        (failed observing)
                        (cancelled blocked)
                        (waiting-for-approval complete)))
    (should-not
     (consent-task-transition-allowed-p
      (car transition)
      (cadr transition))))
  (should-error
   (consent-task-validate-transition 'created 'complete)
   :type 'consent-task-error)
  (should
   (string-match-p
    (regexp-quote
     "(task-condition (kind invalid-transition) (from created) (to complete))")
    (consent-task-test--external
     (cadr
      (should-error
       (consent-task-validate-transition 'created 'complete)
       :type 'consent-task-error))))))

(ert-deftest consent-task-test-constructs-and-validates-records ()
  "Task, step, action, observation, and decision records are canonical datums."
  (let* ((task (consent-task-make-task
                'task-17
                "Replace the old helper name and verify tests."
                'project-main
                '(:state acting
                  :scope project
                  :plan plan-17
                  :current-step step-2
                  :budget (task-budget (max-steps 120000))
                  :capability-environment env-task-17
                  :transcript transcript-task-17
                  :audit audit-task-17
                  :parent task-parent
                  :children (task-child))))
         (step (consent-task-make-step
                'step-2
                'task-17
                "Apply the approved edit."
                '(:state acting
                  :plan-item plan-item-2
                  :attempt 1
                  :observations (obs-10 obs-11)
                  :decision decision-2
                  :action action-2)))
         (action (consent-task-make-action
                  'action-2
                  'task-17
                  'step-2
                  'host-capability
                  '(:library (emacs buffer edit)
                    :binding buffer-replace!
                    :arguments ((handle buffer h-12) 120 140 "consent-read")
                    :requires ((policy buffer-edit))
                    :expected-outcome (observation-needed
                                       (kind diff)
                                       (source buffer)))))
         (observation (consent-task-make-observation
                       'obs-11
                       'task-17
                       '(agent io)
                       'progress
                       '(progress (phase test)
                                  (datum (command "make test")
                                         (status passed)))
                       '(:redactions ()
                         :audit audit-91)))
         (decision (consent-task-make-decision
                    'decision-2
                    'task-17
                    'step-2
                    '(obs-10 obs-11)
                    'action-2
                    "Plan item has approval and narrow edit grant."
                    '(:policy-input ((capability-decision dec-2))
                      :model-input ((model-routing-decision
                                     (role coder)
                                     (provider local-openai-compatible)))
                      :rules-input ((rule-set project-rules))
                      :verifier-result not-run))))
    (dolist (record (list task step action observation decision))
      (should (consent-task-validate-record record)))
    (should (consent-task-record-p task 'agent-task))
    (should (consent-task-record-p step 'agent-step))
    (should (consent-task-record-p action 'agent-action))
    (should (consent-task-record-p observation 'agent-observation))
    (should (consent-task-record-p decision 'agent-decision))
    (should (equal (consent-task-test--symbol-name
                    (consent-task-test--field task "plan"))
                   "plan-17"))
    (should
     (string-match-p
      (regexp-quote
       "(agent-task (id task-17) (state acting) (goal \"Replace")
      (consent-task-test--external task)))
    (should
     (string-match-p
      (regexp-quote "(children (task-child))")
      (consent-task-test--external task)))))

(ert-deftest consent-task-test-validates-pause-and-stop-receipts ()
  "Pause and stop receipts preserve resume and terminal evidence."
  (let* ((pause
          (consent-task-make-pause
           'task-17
           'waiting-for-approval
           'approval-required
           '(:observed-state (observation-set obs-17)
             :intended-next-action action-17
             :capability-gate (capability-decision
                               (id dec-17)
                               (status needs-approval))
             :model-route (model-routing-decision
                           (status selected)
                           (role approval-explainer))
             :approval-status pending
             :verifier-result not-run)))
         (stop
          (consent-task-make-stop
           'task-17
           'complete
           'completed-goal
           '(:observed-state (observation-set obs-31)
             :intended-next-action none
             :capability-gate none
             :model-route none
             :approval-status none
             :verifier-result (verifier-result
                               (status passed)
                               (evidence ((test make-test))))))))
    (should (consent-task-validate-record pause))
    (should (consent-task-validate-record stop))
    (should (consent-task-record-p pause 'task-pause))
    (should (consent-task-record-p stop 'task-stop))
    (should
     (string-match-p
      (regexp-quote "(pause-reason approval-required)")
      (consent-task-test--external pause)))
    (should
     (string-match-p
      (regexp-quote "(stop-reason completed-goal)")
      (consent-task-test--external stop)))
    (should-error
     (consent-task-validate-record
      (consent-task-make-pause
       'task-17
       'complete
       'approval-required
       '(:observed-state obs)))
     :type 'consent-task-error)
    (should-error
     (consent-task-validate-record
      '(task-stop (task task-17) (state complete)))
     :type 'consent-task-error)))

(ert-deftest consent-task-test-fixture-covers-required-scenarios ()
  "Shared task lifecycle fixtures cover the expected control-loop outcomes."
  (let* ((fixture (consent-task-test--fixture))
         (scenarios (cdr (consent-task-test--section fixture "scenarios"))))
    (should (consent-task-test--named-p
             fixture
             "consent-task-lifecycle-fixture"))
    (dolist (required '(normal-completion blocked-approval provider-wait
                                          host-wait cancellation
                                          budget-exhaustion failure
                                          pause-receipt stop-receipt))
      (should
       (seq-find
        (lambda (scenario)
          (equal (consent-task-test--symbol-name
                  (consent-task-test--scenario-field scenario "id"))
                 (symbol-name required)))
        scenarios)))
    (dolist (scenario scenarios)
      (let ((task (consent-task-test--scenario-field scenario "task"))
            (records (consent-task-test--scenario-field scenario "records")))
        (should (consent-task-validate-record task))
        (dolist (record records)
          (should (consent-task-validate-record record)))))))

(ert-deftest consent-task-test-control-loop-fixtures-cover-issue-287 ()
  "Control-loop fixtures cover runner outcomes and reusable expected records."
  (let* ((fixture (consent-task-test--fixture))
         (scenarios
          (consent-task-test--fixture-section fixture "control-loop-scenarios")))
    (dolist (required '(successful-completion user-input-wait approval-wait
                                              approval-denial
                                              authority-unavailable stale-handle
                                              provider-unavailable host-timeout
                                              budget-exhaustion
                                              repeated-action-failure
                                              cancellation
                                              resumed-task-completion
                                              policy-bypass-quarantine
                                              mid-code-action-budget-exhaustion))
      (consent-task-test--scenario-by-id scenarios required))
    (dolist (scenario scenarios)
      (consent-task-test--validate-control-loop-scenario scenario))))

(ert-deftest consent-task-test-control-loop-invalid-fixtures-are-rejected ()
  "Fixture validation rejects malformed records, ordering, budgets, and policy bypasses."
  (let* ((fixture (consent-task-test--fixture))
         (invalid-scenarios
          (consent-task-test--fixture-section
           fixture
           "invalid-control-loop-scenarios")))
    (should invalid-scenarios)
    (dolist (scenario invalid-scenarios)
      (should-error
       (consent-task-test--validate-invalid-control-loop-scenario scenario)
       :type 'consent-task-error))))

;;; consent-task-test.el ends here
