;;; consent-agent-proposal-test.el --- Model-proposal boundary tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent proposal)' contract evaluated
;; through the Emacs Consent interpreter.  The same Scheme source backs the
;; portable host shards (tests/scheme/consent-agent-proposal-test.scm), so these
;; expectations are the Emacs half of the cross-host parity check for the
;; proposal-datum boundary (D2): model output is read and walked as data, host
;; calls become capability requests, and control-plane sub-forms are quarantined
;; to a denied capability-decision rather than executed as authority.

;;; Code:

(require 'ert)
(require 'consent-eval)
(require 'consent-result)

(defun consent-agent-proposal-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(ert-deftest consent-agent-proposal-test-control-plane-vocabulary ()
  "The control-plane predicate flags grant and approval verbs, not pure calls."
  (should
   (equal
    (consent-agent-proposal-test--external
     "(import (scheme base) (agent proposal))
      (list (proposal-control-plane-operation? 'grant-capability!)
            (proposal-control-plane-operation? 'approval-resolve!)
            (proposal-control-plane-operation? 'cons))")
    "(#t #t #f)")))

(ert-deftest consent-agent-proposal-test-pure-form-is-allowed ()
  "A pure form is allowed and charges a deterministic bounded cost."
  (should
   (equal
    (consent-agent-proposal-test--external
     "(import (scheme base) (agent proposal))
      (define a (analyze-code-action '(+ 1 2) '()))
      (list (code-action-analysis? a)
            (analysis-status a)
            (analysis-pure-cost a)
            (analysis-capability-requests a)
            (analysis-quarantine-decisions a))")
    "(#t allowed 4 () ())")))

(ert-deftest consent-agent-proposal-test-host-call-is-gated ()
  "A host call becomes a capability-request carrying its effect and authority."
  (should
   (equal
    (consent-agent-proposal-test--external
     "(import (scheme base) (agent proposal))
      (define ops '((file-write host-mutation file-system)))
      (define a
        (analyze-code-action '(file-write \"out.txt\" payload)
                             (list (list 'operations ops))))
      (define r (car (analysis-capability-requests a)))
      (list (analysis-status a)
            (length (analysis-capability-requests a))
            (capability-request? r)
            (proposal-field-value r 'source)
            (proposal-field-value r 'operation)
            (proposal-field-value r 'effect)
            (proposal-field-value r 'requires)
            (proposal-field-value r 'form))")
    "(gated 1 #t proposal file-write host-mutation file-system (file-write \"out.txt\" payload))")))

(ert-deftest consent-agent-proposal-test-control-plane-is-quarantined ()
  "A grant-minting sub-form is denied as data, never routed to an effect."
  (should
   (equal
    (consent-agent-proposal-test--external
     "(import (scheme base) (agent proposal))
      (define a (analyze-code-action '(grant-capability! token authority) '()))
      (define d (car (analysis-quarantine-decisions a)))
      (list (analysis-status a)
            (capability-decision? d)
            (capability-decision-status d)
            (proposal-field-value d 'operation)
            (proposal-field-value d 'reason)
            (analysis-capability-requests a))")
    "(quarantined #t denied grant-capability! proposal-quarantined-control-plane ())")))

(ert-deftest consent-agent-proposal-test-budget-bounds-the-walk ()
  "A small pure-cost budget stops the walk with a budget-exhausted status."
  (should
   (equal
    (consent-agent-proposal-test--external
     "(import (scheme base) (agent proposal))
      (analysis-status
       (analyze-code-action '(+ 1 (+ 2 (+ 3 4)))
                            (list (list 'max-pure-cost 3))))")
    "budget-exhausted")))

(ert-deftest consent-agent-proposal-test-analysis-is-deterministic ()
  "Identical inputs produce equal, replayable analysis records."
  (should
   (equal
    (consent-agent-proposal-test--external
     "(import (scheme base) (agent proposal))
      (define ops '((file-write host-mutation file-system)))
      (equal? (analyze-code-action '(file-write \"o\" p)
                                   (list (list 'operations ops)))
              (analyze-code-action '(file-write \"o\" p)
                                   (list (list 'operations ops))))")
    "#t")))

(provide 'consent-agent-proposal-test)
;;; consent-agent-proposal-test.el ends here
