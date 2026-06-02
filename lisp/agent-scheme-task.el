;;; agent-scheme-task.el --- Task lifecycle records and transitions  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Agent Scheme tasks are canonical Scheme-readable datums.  This module owns
;; the public state vocabulary, allowed transition table, record constructors,
;; and validators used by the control loop and host adapters.  Live host
;; objects, provider clients, buffers, and process handles stay outside these
;; records.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)

(define-error 'agent-scheme-task-error
  "Agent Scheme task lifecycle error"
  'agent-scheme-eval-error)

(defconst agent-scheme-task-states
  '(created observing planning acting waiting-for-approval waiting-for-model
            waiting-for-host blocked cancelled failed complete)
  "Public Agent Scheme task lifecycle states.")

(defconst agent-scheme-task-pause-states
  '(waiting-for-approval waiting-for-model waiting-for-host blocked)
  "Task states that produce resumable pause receipts.")

(defconst agent-scheme-task-terminal-states
  '(cancelled failed complete)
  "Task states that produce terminal stop receipts.")

(defconst agent-scheme-task-allowed-transitions
  '((created observing cancelled)
    (observing planning waiting-for-host blocked failed cancelled)
    (planning acting waiting-for-model blocked failed cancelled)
    (acting observing waiting-for-approval waiting-for-host waiting-for-model
            blocked complete failed cancelled)
    (waiting-for-approval acting blocked cancelled)
    (waiting-for-model planning acting blocked failed cancelled)
    (waiting-for-host observing acting blocked failed cancelled)
    (blocked observing planning acting cancelled))
  "Allowed task lifecycle transitions keyed by source state.")

(defconst agent-scheme-task-pause-reasons
  '(approval-required waiting-for-user-input authority-unavailable
                      model-provider-unavailable host-effect-timeout
                      insufficient-evidence)
  "Recognized task pause receipt reason symbols.")

(defconst agent-scheme-task-stop-reasons
  '(completed-goal waiting-for-user-input approval-denied
                   authority-unavailable budget-exhausted
                   repeated-failed-action model-provider-unavailable
                   host-effect-timeout cancelled-by-user condition-failed
                   insufficient-evidence)
  "Recognized task stop receipt reason symbols.")

(defconst agent-scheme-task--required-fields
  '((agent-task . (id state goal session scope created-at updated-at
                      resumed-from parent children context memory rules skills
                      patterns plan current-step budget provider-routes
                      capability-environment transcript audit))
    (agent-step . (id task state goal plan-item attempt observations decision
                      action events result))
    (agent-action . (id task step kind library binding arguments requires
                        expected-outcome))
    (agent-observation . (id task source kind value redactions audit))
    (agent-decision . (id task step observed-state selected-action reason
                          policy-input model-input rules-input verifier-result))
    (task-pause . (task state observed-state intended-next-action
                        capability-gate model-route approval-status
                        verifier-result pause-reason))
    (task-stop . (task state observed-state intended-next-action
                       capability-gate model-route approval-status
                       verifier-result stop-reason))
    (task-wait . (task state wait-kind request started-at budget transcript
                      audit))
    (task-failure . (task state condition retry transcript audit))
    (agent-completion . (task status value stop transcript audit)))
  "Required fields for public task lifecycle record tags.")

(defun agent-scheme-task--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((keywordp name)
     (substring (symbol-name name) 1))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-task--name (value)
  "Return VALUE's stable symbolic name, or nil."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((keywordp value)
    (substring (symbol-name value) 1))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun agent-scheme-task--state (state)
  "Return STATE normalized as an Emacs Lisp symbol."
  (let ((normalized
         (and (agent-scheme-task--name state)
              (intern (agent-scheme-task--name state)))))
    (unless (memq normalized agent-scheme-task-states)
      (agent-scheme-task--signal
       'unknown-state
       `((state . ,state))))
    normalized))

(defun agent-scheme-task--integer (value)
  "Return integer VALUE as an Agent Scheme exact integer."
  (agent-scheme--make-canonical-integer value))

(defun agent-scheme-task--datum (value)
  "Return VALUE normalized as an Agent Scheme writable datum."
  (cond
   ((or (null value)
        (agent-scheme-symbol-p value)
        (agent-scheme-number-p value)
        (agent-scheme-character-p value)
        (agent-scheme-bytevector-p value)
        (stringp value)
        (eq value agent-scheme-true)
        (eq value agent-scheme-false))
    value)
   ((eq value t)
    agent-scheme-true)
   ((eq value :scheme-false)
    agent-scheme-false)
   ((integerp value)
    (agent-scheme-task--integer value))
   ((symbolp value)
    (agent-scheme-task--symbol value))
   ((consp value)
    (cons (agent-scheme-task--datum (car value))
          (agent-scheme-task--datum (cdr value))))
   ((vectorp value)
    (vconcat (mapcar #'agent-scheme-task--datum (append value nil))))
   (t
    (agent-scheme-task--signal
     'unsupported-host-object
     `((value . ,(format "%S" value)))))))

(defun agent-scheme-task--field (name value)
  "Return a Scheme-readable field named NAME with VALUE."
  (list (agent-scheme-task--symbol name)
        (agent-scheme-task--datum value)))

(defun agent-scheme-task--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (equal (agent-scheme-task--name (car field))
              (agent-scheme-task--name name))))

(defun agent-scheme-task--field-present-p (record name)
  "Return non-nil when RECORD has field NAME."
  (seq-some
   (lambda (field)
     (agent-scheme-task--field-named-p field name))
   (cdr-safe record)))

(defun agent-scheme-task-field-value (record name &optional default)
  "Return RECORD field NAME, or DEFAULT when absent."
  (let ((field
         (seq-find
          (lambda (candidate)
            (agent-scheme-task--field-named-p candidate name))
          (cdr-safe record))))
    (if field (cadr field) default)))

(defun agent-scheme-task--record-tag (record)
  "Return RECORD tag as an Emacs Lisp symbol, or nil."
  (and (consp record)
       (agent-scheme-task--name (car record))
       (intern (agent-scheme-task--name (car record)))))

(defun agent-scheme-task-record-p (datum tag)
  "Return non-nil when DATUM is a Scheme-readable task record tagged TAG."
  (and (consp datum)
       (equal (agent-scheme-task--name (car datum))
              (agent-scheme-task--name tag))))

(defun agent-scheme-task-state-p (state)
  "Return non-nil when STATE is a public task lifecycle state."
  (memq (and (agent-scheme-task--name state)
             (intern (agent-scheme-task--name state)))
        agent-scheme-task-states))

(defun agent-scheme-task--state-value (record field)
  "Return RECORD FIELD normalized as a task state."
  (agent-scheme-task--state
   (agent-scheme-task-field-value record field)))

(defun agent-scheme-task-transition-allowed-p (from to)
  "Return non-nil when task state FROM may transition to TO."
  (let ((from-state (and (agent-scheme-task-state-p from)
                         (intern (agent-scheme-task--name from))))
        (to-state (and (agent-scheme-task-state-p to)
                       (intern (agent-scheme-task--name to)))))
    (and from-state
         to-state
         (memq to-state
               (cdr (assq from-state
                          agent-scheme-task-allowed-transitions))))))

(defun agent-scheme-task-condition (kind &optional fields)
  "Return a Scheme-readable task condition datum for KIND and FIELDS."
  (cons
   (agent-scheme-task--symbol "task-condition")
   (cons
    (agent-scheme-task--field "kind" kind)
    (mapcar
     (lambda (field)
       (agent-scheme-task--field (car field) (cdr field)))
     fields))))

(defun agent-scheme-task--signal (kind &optional fields)
  "Signal `agent-scheme-task-error' with structured condition KIND and FIELDS."
  (signal 'agent-scheme-task-error
          (list (agent-scheme-task-condition kind fields))))

(defun agent-scheme-task-validate-transition (from to)
  "Validate state transition FROM to TO and return TO as a Scheme symbol."
  (let ((from-state (agent-scheme-task--state from))
        (to-state (agent-scheme-task--state to)))
    (unless (agent-scheme-task-transition-allowed-p from-state to-state)
      (agent-scheme-task--signal
       'invalid-transition
       `((from . ,from-state)
         (to . ,to-state))))
    (agent-scheme-task--symbol to-state)))

(defun agent-scheme-task--option-key-name (key)
  "Return KEY normalized for option lookup."
  (agent-scheme-task--name key))

(defun agent-scheme-task--option-entry-value (entry)
  "Return the option value encoded by ENTRY."
  (cond
   ((and (consp entry)
         (consp (cdr entry))
         (null (cddr entry)))
    (cadr entry))
   ((consp entry)
    (cdr entry))
   (t nil)))

(defun agent-scheme-task--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT.
OPTIONS may be an Emacs plist, an alist, or Scheme-style option pairs."
  (let ((key-name (agent-scheme-task--option-key-name key))
        (cursor options)
        found)
    (while (and cursor (not found))
      (let ((entry (car cursor)))
        (cond
         ((keywordp entry)
          (when (equal (agent-scheme-task--option-key-name entry) key-name)
            (setq found (list (cadr cursor))))
          (setq cursor (cddr cursor)))
         ((and (consp entry)
               (equal (agent-scheme-task--option-key-name (car entry))
                      key-name))
          (setq found (list (agent-scheme-task--option-entry-value entry)))
          (setq cursor (cdr cursor)))
         (t
          (setq cursor (cdr cursor))))))
    (if found (car found) default)))

(defun agent-scheme-task--timestamp ()
  "Return the current time as a public timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun agent-scheme-task--record (tag fields)
  "Return task lifecycle record TAG with FIELDS."
  (cons (agent-scheme-task--symbol tag) fields))

(defun agent-scheme-task-make-task (id goal session &optional options)
  "Return a canonical `agent-task' datum."
  (let ((created-at (agent-scheme-task--option
                     options :created-at (agent-scheme-task--timestamp)))
        (updated-at (agent-scheme-task--option options :updated-at nil)))
    (agent-scheme-task--record
     'agent-task
     (list
      (agent-scheme-task--field "id" id)
      (agent-scheme-task--field
       "state"
       (agent-scheme-task--option options :state 'created))
      (agent-scheme-task--field "goal" goal)
      (agent-scheme-task--field "session" session)
      (agent-scheme-task--field
       "scope"
       (agent-scheme-task--option options :scope 'project))
      (agent-scheme-task--field "created-at" created-at)
      (agent-scheme-task--field "updated-at" (or updated-at created-at))
      (agent-scheme-task--field
       "resumed-from"
       (agent-scheme-task--option options :resumed-from 'none))
      (agent-scheme-task--field
       "parent"
       (agent-scheme-task--option options :parent 'none))
      (agent-scheme-task--field
       "children"
       (agent-scheme-task--option options :children nil))
      (agent-scheme-task--field
       "context"
       (agent-scheme-task--option options :context nil))
      (agent-scheme-task--field
       "memory"
       (agent-scheme-task--option options :memory nil))
      (agent-scheme-task--field
       "rules"
       (agent-scheme-task--option options :rules nil))
      (agent-scheme-task--field
       "skills"
       (agent-scheme-task--option options :skills nil))
      (agent-scheme-task--field
       "patterns"
       (agent-scheme-task--option options :patterns nil))
      (agent-scheme-task--field
       "plan"
       (agent-scheme-task--option options :plan 'none))
      (agent-scheme-task--field
       "current-step"
       (agent-scheme-task--option options :current-step 'none))
      (agent-scheme-task--field
       "budget"
       (agent-scheme-task--option options :budget '(task-budget)))
      (agent-scheme-task--field
       "provider-routes"
       (agent-scheme-task--option options :provider-routes nil))
      (agent-scheme-task--field
       "capability-environment"
       (agent-scheme-task--option options :capability-environment 'none))
      (agent-scheme-task--field
       "transcript"
       (agent-scheme-task--option options :transcript 'none))
      (agent-scheme-task--field
       "audit"
       (agent-scheme-task--option options :audit 'none))))))

(defun agent-scheme-task-make-step (id task goal &optional options)
  "Return a canonical `agent-step' datum."
  (agent-scheme-task--record
   'agent-step
   (list
    (agent-scheme-task--field "id" id)
    (agent-scheme-task--field "task" task)
    (agent-scheme-task--field
     "state"
     (agent-scheme-task--option options :state 'created))
    (agent-scheme-task--field "goal" goal)
    (agent-scheme-task--field
     "plan-item"
     (agent-scheme-task--option options :plan-item 'none))
    (agent-scheme-task--field
     "attempt"
     (agent-scheme-task--option options :attempt 1))
    (agent-scheme-task--field
     "observations"
     (agent-scheme-task--option options :observations nil))
    (agent-scheme-task--field
     "decision"
     (agent-scheme-task--option options :decision 'none))
    (agent-scheme-task--field
     "action"
     (agent-scheme-task--option options :action 'none))
    (agent-scheme-task--field
     "events"
     (agent-scheme-task--option options :events nil))
    (agent-scheme-task--field
     "result"
     (agent-scheme-task--option options :result 'pending)))))

(defun agent-scheme-task-make-action (id task step kind &optional options)
  "Return a canonical `agent-action' datum."
  (agent-scheme-task--record
   'agent-action
   (list
    (agent-scheme-task--field "id" id)
    (agent-scheme-task--field "task" task)
    (agent-scheme-task--field "step" step)
    (agent-scheme-task--field "kind" kind)
    (agent-scheme-task--field
     "library"
     (agent-scheme-task--option options :library 'none))
    (agent-scheme-task--field
     "binding"
     (agent-scheme-task--option options :binding 'none))
    (agent-scheme-task--field
     "arguments"
     (agent-scheme-task--option options :arguments nil))
    (agent-scheme-task--field
     "requires"
     (agent-scheme-task--option options :requires nil))
    (agent-scheme-task--field
     "expected-outcome"
     (agent-scheme-task--option options :expected-outcome 'none)))))

(defun agent-scheme-task-make-observation
    (id task source kind value &optional options)
  "Return a canonical `agent-observation' datum."
  (agent-scheme-task--record
   'agent-observation
   (list
    (agent-scheme-task--field "id" id)
    (agent-scheme-task--field "task" task)
    (agent-scheme-task--field "source" source)
    (agent-scheme-task--field "kind" kind)
    (agent-scheme-task--field "value" value)
    (agent-scheme-task--field
     "redactions"
     (agent-scheme-task--option options :redactions nil))
    (agent-scheme-task--field
     "audit"
     (agent-scheme-task--option options :audit 'none)))))

(defun agent-scheme-task-make-decision
    (id task step observed-state selected-action reason &optional options)
  "Return a canonical `agent-decision' datum."
  (agent-scheme-task--record
   'agent-decision
   (list
    (agent-scheme-task--field "id" id)
    (agent-scheme-task--field "task" task)
    (agent-scheme-task--field "step" step)
    (agent-scheme-task--field "observed-state" observed-state)
    (agent-scheme-task--field "selected-action" selected-action)
    (agent-scheme-task--field "reason" reason)
    (agent-scheme-task--field
     "policy-input"
     (agent-scheme-task--option options :policy-input nil))
    (agent-scheme-task--field
     "model-input"
     (agent-scheme-task--option options :model-input nil))
    (agent-scheme-task--field
     "rules-input"
     (agent-scheme-task--option options :rules-input nil))
    (agent-scheme-task--field
     "verifier-result"
     (agent-scheme-task--option options :verifier-result 'not-run)))))

(defun agent-scheme-task-make-pause (task state reason &optional options)
  "Return a canonical `task-pause' receipt datum."
  (agent-scheme-task--record
   'task-pause
   (list
    (agent-scheme-task--field "task" task)
    (agent-scheme-task--field "state" state)
    (agent-scheme-task--field
     "observed-state"
     (agent-scheme-task--option options :observed-state 'none))
    (agent-scheme-task--field
     "intended-next-action"
     (agent-scheme-task--option options :intended-next-action 'none))
    (agent-scheme-task--field
     "capability-gate"
     (agent-scheme-task--option options :capability-gate 'none))
    (agent-scheme-task--field
     "model-route"
     (agent-scheme-task--option options :model-route 'none))
    (agent-scheme-task--field
     "approval-status"
     (agent-scheme-task--option options :approval-status 'none))
    (agent-scheme-task--field
     "verifier-result"
     (agent-scheme-task--option options :verifier-result 'not-run))
    (agent-scheme-task--field "pause-reason" reason))))

(defun agent-scheme-task-make-stop (task state reason &optional options)
  "Return a canonical `task-stop' receipt datum."
  (agent-scheme-task--record
   'task-stop
   (list
    (agent-scheme-task--field "task" task)
    (agent-scheme-task--field "state" state)
    (agent-scheme-task--field
     "observed-state"
     (agent-scheme-task--option options :observed-state 'none))
    (agent-scheme-task--field
     "intended-next-action"
     (agent-scheme-task--option options :intended-next-action 'none))
    (agent-scheme-task--field
     "capability-gate"
     (agent-scheme-task--option options :capability-gate 'none))
    (agent-scheme-task--field
     "model-route"
     (agent-scheme-task--option options :model-route 'none))
    (agent-scheme-task--field
     "approval-status"
     (agent-scheme-task--option options :approval-status 'none))
    (agent-scheme-task--field
     "verifier-result"
     (agent-scheme-task--option options :verifier-result 'not-run))
    (agent-scheme-task--field "stop-reason" reason))))

(defun agent-scheme-task--scheme-datum-p (value)
  "Return non-nil when VALUE is safe to expose as Scheme-readable data."
  (cond
   ((or (null value)
        (stringp value)
        (agent-scheme-symbol-p value)
        (agent-scheme-number-p value)
        (agent-scheme-character-p value)
        (agent-scheme-bytevector-p value)
        (eq value agent-scheme-true)
        (eq value agent-scheme-false))
    t)
   ((consp value)
    (and (agent-scheme-task--scheme-datum-p (car value))
         (agent-scheme-task--scheme-datum-p (cdr value))))
   ((vectorp value)
    (seq-every-p #'agent-scheme-task--scheme-datum-p value))
   (t nil)))

(defun agent-scheme-task--validate-required-fields (record tag)
  "Validate required fields for RECORD tagged TAG."
  (dolist (field (alist-get tag agent-scheme-task--required-fields))
    (unless (agent-scheme-task--field-present-p record field)
      (agent-scheme-task--signal
       'missing-field
       `((record . ,tag)
         (field . ,field))))))

(defun agent-scheme-task--validate-state-shape (record tag)
  "Validate state fields on RECORD tagged TAG."
  (pcase tag
    ((or 'agent-task 'agent-step)
     (agent-scheme-task--state-value record "state"))
    ('task-pause
     (let ((state (agent-scheme-task--state-value record "state")))
       (unless (memq state agent-scheme-task-pause-states)
         (agent-scheme-task--signal
          'invalid-pause-state
          `((state . ,state))))))
    ('task-stop
     (let ((state (agent-scheme-task--state-value record "state")))
       (unless (memq state agent-scheme-task-terminal-states)
         (agent-scheme-task--signal
          'invalid-stop-state
          `((state . ,state))))))
    ('task-wait
     (let ((state (agent-scheme-task--state-value record "state")))
       (unless (memq state
                     '(waiting-for-approval waiting-for-model
                                            waiting-for-host))
         (agent-scheme-task--signal
          'invalid-wait-state
          `((state . ,state))))))
    ('task-failure
     (let ((state (agent-scheme-task--state-value record "state")))
       (unless (eq state 'failed)
         (agent-scheme-task--signal
          'invalid-failure-state
          `((state . ,state))))))
    ('agent-completion
     (let ((status (agent-scheme-task--name
                    (agent-scheme-task-field-value record "status"))))
       (unless (equal status "complete")
         (agent-scheme-task--signal
          'invalid-completion-status
          `((status . ,status))))))))

(defun agent-scheme-task-validate-record (record)
  "Validate RECORD as a public task lifecycle datum and return RECORD."
  (let ((tag (agent-scheme-task--record-tag record)))
    (unless (alist-get tag agent-scheme-task--required-fields)
      (agent-scheme-task--signal
       'malformed-record
       `((record . ,record))))
    (agent-scheme-task--validate-required-fields record tag)
    (agent-scheme-task--validate-state-shape record tag)
    (unless (agent-scheme-task--scheme-datum-p record)
      (agent-scheme-task--signal
       'unsupported-host-object
       `((record . ,tag))))
    record))

(provide 'agent-scheme-task)

;;; agent-scheme-task.el ends here
