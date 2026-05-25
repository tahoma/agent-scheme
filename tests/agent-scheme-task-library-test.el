;;; agent-scheme-task-library-test.el --- Agent task library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that Scheme programs can import `(agent task)' and use the public
;; portable lifecycle record helpers through the evaluator.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)

(ert-deftest agent-scheme-task-library-test-imports-and-builds-records ()
  "The `(agent task)' library exposes portable constructors and validators."
  (let ((external
         (agent-scheme-result->external
          (agent-scheme-eval-source
           "(import (scheme base) (agent task))
            (let ((task (make-agent-task
                         'task-1
                         \"Ship task lifecycle records.\"
                         'session-1
                         '((plan . plan-1)
                           (transcript . transcript-1)
                           (budget . (task-budget (max-steps 10)))
                           (audit . audit-1)))))
              (let ((pause (make-task-pause
                            'task-1
                            'waiting-for-model
                            'model-provider-unavailable
                            '((observed-state . (observation-set obs-1))
                              (intended-next-action . action-1)
                              (capability-gate . none)
                              (model-route . (model-routing-decision
                                              (status selected)))
                              (approval-status . none)
                              (verifier-result . not-run)))))
                (list (task-transition-allowed? 'created 'observing)
                      (task-transition-allowed? 'created 'complete)
                      (agent-task? task)
                      (task-pause? pause)
                      (task-record-valid? task)
                      (task-record-valid? pause))))"))))
    (should (equal external "(#t #f #t #t #t #t)"))))

(ert-deftest agent-scheme-task-library-test-signals-invalid-transition ()
  "Portable transition validation raises a Scheme condition on bad edges."
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (agent task))
     (validate-task-transition 'created 'complete)")
   :type 'agent-scheme-eval-error))

;;; agent-scheme-task-library-test.el ends here
