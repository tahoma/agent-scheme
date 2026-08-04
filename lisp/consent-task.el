;;; consent-task.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Consent Scheme tasks are canonical Scheme-readable datums.  This module owns
;; the public state vocabulary, allowed transition table, record constructors,
;; and validators used by the control loop and host adapters.  Live host
;; objects, provider clients, buffers, and process handles stay outside these
;; records.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'consent-reader)
(require 'consent-runtime)

(define-error 'consent-task-error
  "Consent Scheme task lifecycle error"
  'consent-eval-error)

(defconst consent-task-states
  '(created observing planning acting waiting-for-approval waiting-for-model
            waiting-for-host blocked cancelled failed complete)
  "Public Consent Scheme task lifecycle states.")

(defconst consent-task-pause-states
  '(waiting-for-approval waiting-for-model waiting-for-host blocked)
  "Task states that produce resumable pause receipts.")

(defconst consent-task-terminal-states
  '(cancelled failed complete)
  "Task states that produce terminal stop receipts.")

(defconst consent-task-allowed-transitions
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

(defconst consent-task-pause-reasons
  '(approval-required waiting-for-user-input authority-unavailable
                      model-provider-unavailable host-effect-timeout
                      insufficient-evidence)
  "Recognized task pause receipt reason symbols.")

(defconst consent-task-stop-reasons
  '(completed-goal waiting-for-user-input approval-denied
                   authority-unavailable budget-exhausted
                   repeated-failed-action model-provider-unavailable
                   host-effect-timeout cancelled-by-user condition-failed
                   insufficient-evidence)
  "Recognized task stop receipt reason symbols.")

(defconst consent-task--required-fields
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
                          policy-input model-input rules-input
                            verifier-result))
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

(defun consent-task--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((keywordp name)
     (substring (symbol-name name) 1))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-task--name (value)
  "Return VALUE's stable symbolic name, or nil."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((keywordp value)
    (substring (symbol-name value) 1))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun consent-task--state (state)
  "Return STATE normalized as an Emacs Lisp symbol."
  (let ((normalized
         (and (consent-task--name state)
              (intern (consent-task--name state)))))
    (unless (memq normalized consent-task-states)
      (consent-task--signal
       'unknown-state
       `((state . ,state))))
    normalized))

(defun consent-task--integer (value)
  "Return integer VALUE as an Consent Scheme exact integer."
  (consent--make-canonical-integer value))

(defun consent-task--datum (value)
  "Return VALUE normalized as an Consent Scheme writable datum."
  (cond
   ((or (null value)
        (consent-symbol-p value)
        (consent-number-p value)
        (consent-character-p value)
        (consent-bytevector-p value)
        (stringp value)
        (eq value consent-true)
        (eq value consent-false))
    value)
   ((eq value t)
    consent-true)
   ((eq value :scheme-false)
    consent-false)
   ((integerp value)
    (consent-task--integer value))
   ((symbolp value)
    (consent-task--symbol value))
   ((consp value)
    (cons (consent-task--datum (car value))
          (consent-task--datum (cdr value))))
   ((vectorp value)
    (vconcat (mapcar #'consent-task--datum (append value nil))))
   (t
    (consent-task--signal
     'unsupported-host-object
     `((value . ,(format "%S" value)))))))

(defun consent-task--field (name value)
  "Return a Scheme-readable field named NAME with VALUE."
  (list (consent-task--symbol name)
        (consent-task--datum value)))

(defun consent-task--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (equal (consent-task--name (car field))
              (consent-task--name name))))

(defun consent-task--field-present-p (record name)
  "Return non-nil when RECORD has field NAME."
  (seq-some
   (lambda (field)
     (consent-task--field-named-p field name))
   (cdr-safe record)))

(defun consent-task-field-value (record name &optional default)
  "Return RECORD field NAME, or DEFAULT when absent."
  (let ((field
         (seq-find
          (lambda (candidate)
            (consent-task--field-named-p candidate name))
          (cdr-safe record))))
    (if field (cadr field) default)))

(defun consent-task--record-tag (record)
  "Return RECORD tag as an Emacs Lisp symbol, or nil."
  (and (consp record)
       (consent-task--name (car record))
       (intern (consent-task--name (car record)))))

(defun consent-task-record-p (datum tag)
  "Return non-nil when DATUM is a Scheme-readable task record tagged TAG."
  (and (consp datum)
       (equal (consent-task--name (car datum))
              (consent-task--name tag))))

(defun consent-task-state-p (state)
  "Return non-nil when STATE is a public task lifecycle state."
  (memq (and (consent-task--name state)
             (intern (consent-task--name state)))
        consent-task-states))

(defun consent-task--state-value (record field)
  "Return RECORD FIELD normalized as a task state."
  (consent-task--state
   (consent-task-field-value record field)))

(defun consent-task-transition-allowed-p (from to)
  "Return non-nil when task state FROM may transition to TO."
  (let ((from-state (and (consent-task-state-p from)
                         (intern (consent-task--name from))))
        (to-state (and (consent-task-state-p to)
                       (intern (consent-task--name to)))))
    (and from-state
         to-state
         (memq to-state
               (cdr (assq from-state
                          consent-task-allowed-transitions))))))

(defun consent-task-condition (kind &optional fields)
  "Return a Scheme-readable task condition datum for KIND and FIELDS."
  (cons
   (consent-task--symbol "task-condition")
   (cons
    (consent-task--field "kind" kind)
    (mapcar
     (lambda (field)
       (consent-task--field (car field) (cdr field)))
     fields))))

(defun consent-task--signal (kind &optional fields)
  "Signal `consent-task-error' with structured condition KIND and FIELDS."
  (signal 'consent-task-error
          (list (consent-task-condition kind fields))))

(defun consent-task-validate-transition (from to)
  "Validate state transition FROM to TO and return TO as a Scheme symbol."
  (let ((from-state (consent-task--state from))
        (to-state (consent-task--state to)))
    (unless (consent-task-transition-allowed-p from-state to-state)
      (consent-task--signal
       'invalid-transition
       `((from . ,from-state)
         (to . ,to-state))))
    (consent-task--symbol to-state)))

(defun consent-task--option-key-name (key)
  "Return KEY normalized for option lookup."
  (consent-task--name key))

(defun consent-task--option-entry-value (entry)
  "Return the option value encoded by ENTRY."
  (cond
   ((and (consp entry)
         (consp (cdr entry))
         (null (cddr entry)))
    (cadr entry))
   ((consp entry)
    (cdr entry))
   (t nil)))

(defun consent-task--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT.
OPTIONS may be an Emacs plist, an alist, or Scheme-style option pairs."
  (let ((key-name (consent-task--option-key-name key))
        (cursor options)
        found)
    (while (and cursor (not found))
      (let ((entry (car cursor)))
        (cond
         ((keywordp entry)
          (when (equal (consent-task--option-key-name entry) key-name)
            (setq found (list (cadr cursor))))
          (setq cursor (cddr cursor)))
         ((and (consp entry)
               (equal (consent-task--option-key-name (car entry))
                      key-name))
          (setq found (list (consent-task--option-entry-value entry)))
          (setq cursor (cdr cursor)))
         (t
          (setq cursor (cdr cursor))))))
    (if found (car found) default)))

(defun consent-task--timestamp ()
  "Return the current time as a public timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun consent-task--record (tag fields)
  "Return task lifecycle record TAG with FIELDS."
  (cons (consent-task--symbol tag) fields))

(defun consent-task-make-task (id goal session &optional options)
  "Return a canonical `agent-task' datum."
  (let ((created-at (consent-task--option
                     options :created-at (consent-task--timestamp)))
        (updated-at (consent-task--option options :updated-at nil)))
    (consent-task--record
     'agent-task
     (list
      (consent-task--field "id" id)
      (consent-task--field
       "state"
       (consent-task--option options :state 'created))
      (consent-task--field "goal" goal)
      (consent-task--field "session" session)
      (consent-task--field
       "scope"
       (consent-task--option options :scope 'project))
      (consent-task--field "created-at" created-at)
      (consent-task--field "updated-at" (or updated-at created-at))
      (consent-task--field
       "resumed-from"
       (consent-task--option options :resumed-from 'none))
      (consent-task--field
       "parent"
       (consent-task--option options :parent 'none))
      (consent-task--field
       "children"
       (consent-task--option options :children nil))
      (consent-task--field
       "context"
       (consent-task--option options :context nil))
      (consent-task--field
       "memory"
       (consent-task--option options :memory nil))
      (consent-task--field
       "rules"
       (consent-task--option options :rules nil))
      (consent-task--field
       "skills"
       (consent-task--option options :skills nil))
      (consent-task--field
       "patterns"
       (consent-task--option options :patterns nil))
      (consent-task--field
       "plan"
       (consent-task--option options :plan 'none))
      (consent-task--field
       "current-step"
       (consent-task--option options :current-step 'none))
      (consent-task--field
       "budget"
       (consent-task--option options :budget '(task-budget)))
      (consent-task--field
       "provider-routes"
       (consent-task--option options :provider-routes nil))
      (consent-task--field
       "capability-environment"
       (consent-task--option options :capability-environment 'none))
      (consent-task--field
       "transcript"
       (consent-task--option options :transcript 'none))
      (consent-task--field
       "audit"
       (consent-task--option options :audit 'none))))))

(defun consent-task-make-step (id task goal &optional options)
  "Return a canonical `agent-step' datum."
  (consent-task--record
   'agent-step
   (list
    (consent-task--field "id" id)
    (consent-task--field "task" task)
    (consent-task--field
     "state"
     (consent-task--option options :state 'created))
    (consent-task--field "goal" goal)
    (consent-task--field
     "plan-item"
     (consent-task--option options :plan-item 'none))
    (consent-task--field
     "attempt"
     (consent-task--option options :attempt 1))
    (consent-task--field
     "observations"
     (consent-task--option options :observations nil))
    (consent-task--field
     "decision"
     (consent-task--option options :decision 'none))
    (consent-task--field
     "action"
     (consent-task--option options :action 'none))
    (consent-task--field
     "events"
     (consent-task--option options :events nil))
    (consent-task--field
     "result"
     (consent-task--option options :result 'pending)))))

(defun consent-task-make-action (id task step kind &optional options)
  "Return a canonical `agent-action' datum."
  (consent-task--record
   'agent-action
   (list
    (consent-task--field "id" id)
    (consent-task--field "task" task)
    (consent-task--field "step" step)
    (consent-task--field "kind" kind)
    (consent-task--field
     "library"
     (consent-task--option options :library 'none))
    (consent-task--field
     "binding"
     (consent-task--option options :binding 'none))
    (consent-task--field
     "arguments"
     (consent-task--option options :arguments nil))
    (consent-task--field
     "requires"
     (consent-task--option options :requires nil))
    (consent-task--field
     "expected-outcome"
     (consent-task--option options :expected-outcome 'none)))))

(defun consent-task-make-observation
    (id task source kind value &optional options)
  "Return a canonical `agent-observation' datum."
  (consent-task--record
   'agent-observation
   (list
    (consent-task--field "id" id)
    (consent-task--field "task" task)
    (consent-task--field "source" source)
    (consent-task--field "kind" kind)
    (consent-task--field "value" value)
    (consent-task--field
     "redactions"
     (consent-task--option options :redactions nil))
    (consent-task--field
     "audit"
     (consent-task--option options :audit 'none)))))

(defun consent-task-make-decision
    (id task step observed-state selected-action reason &optional options)
  "Return a canonical `agent-decision' datum."
  (consent-task--record
   'agent-decision
   (list
    (consent-task--field "id" id)
    (consent-task--field "task" task)
    (consent-task--field "step" step)
    (consent-task--field "observed-state" observed-state)
    (consent-task--field "selected-action" selected-action)
    (consent-task--field "reason" reason)
    (consent-task--field
     "policy-input"
     (consent-task--option options :policy-input nil))
    (consent-task--field
     "model-input"
     (consent-task--option options :model-input nil))
    (consent-task--field
     "rules-input"
     (consent-task--option options :rules-input nil))
    (consent-task--field
     "verifier-result"
     (consent-task--option options :verifier-result 'not-run)))))

(defun consent-task-make-pause (task state reason &optional options)
  "Return a canonical `task-pause' receipt datum."
  (consent-task--record
   'task-pause
   (list
    (consent-task--field "task" task)
    (consent-task--field "state" state)
    (consent-task--field
     "observed-state"
     (consent-task--option options :observed-state 'none))
    (consent-task--field
     "intended-next-action"
     (consent-task--option options :intended-next-action 'none))
    (consent-task--field
     "capability-gate"
     (consent-task--option options :capability-gate 'none))
    (consent-task--field
     "model-route"
     (consent-task--option options :model-route 'none))
    (consent-task--field
     "approval-status"
     (consent-task--option options :approval-status 'none))
    (consent-task--field
     "verifier-result"
     (consent-task--option options :verifier-result 'not-run))
    (consent-task--field "pause-reason" reason))))

(defun consent-task-make-stop (task state reason &optional options)
  "Return a canonical `task-stop' receipt datum."
  (consent-task--record
   'task-stop
   (list
    (consent-task--field "task" task)
    (consent-task--field "state" state)
    (consent-task--field
     "observed-state"
     (consent-task--option options :observed-state 'none))
    (consent-task--field
     "intended-next-action"
     (consent-task--option options :intended-next-action 'none))
    (consent-task--field
     "capability-gate"
     (consent-task--option options :capability-gate 'none))
    (consent-task--field
     "model-route"
     (consent-task--option options :model-route 'none))
    (consent-task--field
     "approval-status"
     (consent-task--option options :approval-status 'none))
    (consent-task--field
     "verifier-result"
     (consent-task--option options :verifier-result 'not-run))
    (consent-task--field "stop-reason" reason))))

(defun consent-task--scheme-datum-p (value)
  "Return non-nil when VALUE is safe to expose as Scheme-readable data."
  (cond
   ((or (null value)
        (stringp value)
        (consent-symbol-p value)
        (consent-number-p value)
        (consent-character-p value)
        (consent-bytevector-p value)
        (eq value consent-true)
        (eq value consent-false))
    t)
   ((consp value)
    (and (consent-task--scheme-datum-p (car value))
         (consent-task--scheme-datum-p (cdr value))))
   ((vectorp value)
    (seq-every-p #'consent-task--scheme-datum-p value))
   (t nil)))

(defun consent-task--validate-required-fields (record tag)
  "Validate required fields for RECORD tagged TAG."
  (dolist (field (alist-get tag consent-task--required-fields))
    (unless (consent-task--field-present-p record field)
      (consent-task--signal
       'missing-field
       `((record . ,tag)
         (field . ,field))))))

(defun consent-task--validate-state-shape (record tag)
  "Validate state fields on RECORD tagged TAG."
  (pcase tag
    ((or 'agent-task 'agent-step)
     (consent-task--state-value record "state"))
    ('task-pause
     (let ((state (consent-task--state-value record "state")))
       (unless (memq state consent-task-pause-states)
         (consent-task--signal
          'invalid-pause-state
          `((state . ,state))))))
    ('task-stop
     (let ((state (consent-task--state-value record "state")))
       (unless (memq state consent-task-terminal-states)
         (consent-task--signal
          'invalid-stop-state
          `((state . ,state))))))
    ('task-wait
     (let ((state (consent-task--state-value record "state")))
       (unless (memq state
                     '(waiting-for-approval waiting-for-model
                                            waiting-for-host))
         (consent-task--signal
          'invalid-wait-state
          `((state . ,state))))))
    ('task-failure
     (let ((state (consent-task--state-value record "state")))
       (unless (eq state 'failed)
         (consent-task--signal
          'invalid-failure-state
          `((state . ,state))))))
    ('agent-completion
     (let ((status (consent-task--name
                    (consent-task-field-value record "status"))))
       (unless (equal status "complete")
         (consent-task--signal
          'invalid-completion-status
          `((status . ,status))))))))

(defun consent-task-validate-record (record)
  "Validate RECORD as a public task lifecycle datum and return RECORD."
  (let ((tag (consent-task--record-tag record)))
    (unless (alist-get tag consent-task--required-fields)
      (consent-task--signal
       'malformed-record
       `((record . ,record))))
    (consent-task--validate-required-fields record tag)
    (consent-task--validate-state-shape record tag)
    (unless (consent-task--scheme-datum-p record)
      (consent-task--signal
       'unsupported-host-object
       `((record . ,tag))))
    record))

(provide 'consent-task)

;;; consent-task.el ends here
