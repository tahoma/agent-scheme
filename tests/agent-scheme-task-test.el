;;; agent-scheme-task-test.el --- Task lifecycle record tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for public task lifecycle datums, state transitions,
;; receipts, and fixture scenarios used by the control-loop follow-up work.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-reader)
(require 'agent-scheme-result)
(require 'agent-scheme-task)

(defconst agent-scheme-task-test--fixture-path
  "fixtures/agent/task-lifecycle.scm"
  "Repository-relative path to task lifecycle fixture records.")

(defun agent-scheme-task-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-task-test--field (datum name)
  "Return field NAME from Scheme-readable DATUM."
  (agent-scheme-task-field-value datum name))

(defun agent-scheme-task-test--fixture ()
  "Return the parsed task lifecycle fixture datum."
  (let* ((path (expand-file-name
                agent-scheme-task-test--fixture-path
                agent-scheme--test-root))
         (forms (agent-scheme-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (car forms)))

(defun agent-scheme-task-test--symbol-name (value)
  "Return VALUE as a stable symbol name."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun agent-scheme-task-test--named-p (datum name)
  "Return non-nil when DATUM is a record tagged NAME."
  (and (consp datum)
       (equal (agent-scheme-task-test--symbol-name (car datum)) name)))

(defun agent-scheme-task-test--section (record name)
  "Return RECORD section NAME."
  (seq-find
   (lambda (field)
     (agent-scheme-task-test--named-p field name))
   (if (consp (car-safe record))
       record
     (cdr-safe record))))

(defun agent-scheme-task-test--section-value (record name)
  "Return the first value from RECORD section NAME."
  (cadr (agent-scheme-task-test--section record name)))

(defun agent-scheme-task-test--scenario-field (scenario name)
  "Return SCENARIO field NAME."
  (agent-scheme-task-test--section-value scenario name))

(ert-deftest agent-scheme-task-test-state-vocabulary-and-transitions ()
  "The public state vocabulary and transition table match the control loop."
  (should (equal agent-scheme-task-states
                 '(created observing planning acting
                           waiting-for-approval waiting-for-model
                           waiting-for-host blocked cancelled failed complete)))
  (dolist (state agent-scheme-task-states)
    (should (agent-scheme-task-state-p state)))
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
     (agent-scheme-task-transition-allowed-p
      (car transition)
      (cadr transition))))
  (dolist (transition '((created complete)
                        (complete acting)
                        (failed observing)
                        (cancelled blocked)
                        (waiting-for-approval complete)))
    (should-not
     (agent-scheme-task-transition-allowed-p
      (car transition)
      (cadr transition))))
  (should-error
   (agent-scheme-task-validate-transition 'created 'complete)
   :type 'agent-scheme-task-error)
  (should
   (string-match-p
    (regexp-quote
     "(task-condition (kind invalid-transition) (from created) (to complete))")
    (agent-scheme-task-test--external
     (cadr
      (should-error
       (agent-scheme-task-validate-transition 'created 'complete)
       :type 'agent-scheme-task-error))))))

(ert-deftest agent-scheme-task-test-constructs-and-validates-records ()
  "Task, step, action, observation, and decision records are canonical datums."
  (let* ((task (agent-scheme-task-make-task
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
         (step (agent-scheme-task-make-step
                'step-2
                'task-17
                "Apply the approved edit."
                '(:state acting
                  :plan-item plan-item-2
                  :attempt 1
                  :observations (obs-10 obs-11)
                  :decision decision-2
                  :action action-2)))
         (action (agent-scheme-task-make-action
                  'action-2
                  'task-17
                  'step-2
                  'host-capability
                  '(:library (emacs buffer edit)
                    :binding buffer-replace!
                    :arguments ((handle buffer h-12) 120 140 "agent-scheme-read")
                    :requires ((policy buffer-edit))
                    :expected-outcome (observation-needed
                                       (kind diff)
                                       (source buffer)))))
         (observation (agent-scheme-task-make-observation
                       'obs-11
                       'task-17
                       '(agent io)
                       'progress
                       '(progress (phase test)
                                  (datum (command "make test")
                                         (status passed)))
                       '(:redactions ()
                         :audit audit-91)))
         (decision (agent-scheme-task-make-decision
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
      (should (agent-scheme-task-validate-record record)))
    (should (agent-scheme-task-record-p task 'agent-task))
    (should (agent-scheme-task-record-p step 'agent-step))
    (should (agent-scheme-task-record-p action 'agent-action))
    (should (agent-scheme-task-record-p observation 'agent-observation))
    (should (agent-scheme-task-record-p decision 'agent-decision))
    (should (equal (agent-scheme-task-test--symbol-name
                    (agent-scheme-task-test--field task "plan"))
                   "plan-17"))
    (should
     (string-match-p
      (regexp-quote
       "(agent-task (id task-17) (state acting) (goal \"Replace")
      (agent-scheme-task-test--external task)))
    (should
     (string-match-p
      (regexp-quote "(children (task-child))")
      (agent-scheme-task-test--external task)))))

(ert-deftest agent-scheme-task-test-validates-pause-and-stop-receipts ()
  "Pause and stop receipts preserve resume and terminal evidence."
  (let* ((pause
          (agent-scheme-task-make-pause
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
          (agent-scheme-task-make-stop
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
    (should (agent-scheme-task-validate-record pause))
    (should (agent-scheme-task-validate-record stop))
    (should (agent-scheme-task-record-p pause 'task-pause))
    (should (agent-scheme-task-record-p stop 'task-stop))
    (should
     (string-match-p
      (regexp-quote "(pause-reason approval-required)")
      (agent-scheme-task-test--external pause)))
    (should
     (string-match-p
      (regexp-quote "(stop-reason completed-goal)")
      (agent-scheme-task-test--external stop)))
    (should-error
     (agent-scheme-task-validate-record
      (agent-scheme-task-make-pause
       'task-17
       'complete
       'approval-required
       '(:observed-state obs)))
     :type 'agent-scheme-task-error)
    (should-error
     (agent-scheme-task-validate-record
      '(task-stop (task task-17) (state complete)))
     :type 'agent-scheme-task-error)))

(ert-deftest agent-scheme-task-test-fixture-covers-required-scenarios ()
  "Shared task lifecycle fixtures cover the expected control-loop outcomes."
  (let* ((fixture (agent-scheme-task-test--fixture))
         (scenarios (cdr (agent-scheme-task-test--section fixture "scenarios"))))
    (should (agent-scheme-task-test--named-p
             fixture
             "agent-scheme-task-lifecycle-fixture"))
    (dolist (required '(normal-completion blocked-approval provider-wait
                                          host-wait cancellation
                                          budget-exhaustion failure
                                          pause-receipt stop-receipt))
      (should
       (seq-find
        (lambda (scenario)
          (equal (agent-scheme-task-test--symbol-name
                  (agent-scheme-task-test--scenario-field scenario "id"))
                 (symbol-name required)))
        scenarios)))
    (dolist (scenario scenarios)
      (let ((task (agent-scheme-task-test--scenario-field scenario "task"))
            (records (agent-scheme-task-test--scenario-field scenario "records")))
        (should (agent-scheme-task-validate-record task))
        (dolist (record records)
          (should (agent-scheme-task-validate-record record)))))))

;;; agent-scheme-task-test.el ends here
