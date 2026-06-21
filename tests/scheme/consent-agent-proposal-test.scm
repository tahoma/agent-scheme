;;; Portable Consent Scheme model-proposal boundary tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent proposal)' library directly: classifying a model-proposed form as
;;; data into pure sub-forms (budget-charged), host calls (routed to a
;;; capability-request), and control-plane sub-forms (quarantined to a denied
;;; capability-decision).  It loads no Emacs host adapter; the same source backs
;;; the Emacs interpreter, so passing here is the portable half of the parity
;;; check for the proposal-datum boundary recorded as D2 in docs/control-loop.md.

(import (scheme base)
        (scheme write)
        (agent proposal))

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

;; Host-operation table shared by the gated-call checks below.
(define operations
  '((file-write host-mutation file-system)
    (read-file host-observation file-system)))

;;;; Control-plane vocabulary

(check-true 'control-plane-grant
            (proposal-control-plane-operation? 'grant-capability!))
(check-true 'control-plane-approval
            (proposal-control-plane-operation? 'approval-resolve!))
(check-true 'control-plane-rejects-pure
            (not (proposal-control-plane-operation? 'cons)))
(check-true 'control-plane-list-has-revoke
            (and (memq 'grant-revoke! proposal-control-plane-operations) #t))

;;;; A pure form is allowed and charges a deterministic bounded cost

(let ((analysis (analyze-code-action '(+ 1 2) '())))
  (check-true 'pure-is-analysis (code-action-analysis? analysis))
  (check 'pure-status (analysis-status analysis) 'allowed)
  (check 'pure-cost (analysis-pure-cost analysis) 4)
  (check 'pure-no-requests (analysis-capability-requests analysis) '())
  (check 'pure-no-decisions (analysis-quarantine-decisions analysis) '()))

;;;; A host call is routed to a capability-request, never executed

(let ((analysis (analyze-code-action '(file-write "out.txt" payload)
                                     (list (list 'operations operations)))))
  (check 'gated-status (analysis-status analysis) 'gated)
  (check 'gated-no-decisions (analysis-quarantine-decisions analysis) '())
  (let ((requests (analysis-capability-requests analysis)))
    (check 'gated-one-request (length requests) 1)
    (let ((request (car requests)))
      (check-true 'gated-request-predicate (capability-request? request))
      (check 'gated-request-source
             (proposal-field-value request 'source) 'proposal)
      (check 'gated-request-operation
             (proposal-field-value request 'operation) 'file-write)
      (check 'gated-request-effect
             (proposal-field-value request 'effect) 'host-mutation)
      (check 'gated-request-requires
             (proposal-field-value request 'requires) 'file-system)
      (check 'gated-request-form
             (proposal-field-value request 'form)
             '(file-write "out.txt" payload)))))

;; A host call nested inside otherwise pure structure is still discovered.
(let ((analysis (analyze-code-action
                 '(begin (display "x") (read-file "notes.txt"))
                 (list (list 'operations operations)))))
  (check 'nested-status (analysis-status analysis) 'gated)
  (check 'nested-one-request
         (length (analysis-capability-requests analysis)) 1)
  (check 'nested-operation
         (proposal-field-value
          (car (analysis-capability-requests analysis)) 'operation)
         'read-file))

;;;; Control-plane sub-forms are quarantined to a denied capability-decision

(let ((analysis (analyze-code-action
                 '(grant-capability! token authority)
                 (list (list 'operations operations)))))
  (check 'quarantine-status (analysis-status analysis) 'quarantined)
  (check 'quarantine-no-requests
         (analysis-capability-requests analysis) '())
  (let ((decisions (analysis-quarantine-decisions analysis)))
    (check 'quarantine-one-decision (length decisions) 1)
    (let ((decision (car decisions)))
      (check-true 'quarantine-decision-predicate
                  (capability-decision? decision))
      (check 'quarantine-decision-status
             (capability-decision-status decision) 'denied)
      (check 'quarantine-decision-operation
             (proposal-field-value decision 'operation) 'grant-capability!)
      (check 'quarantine-decision-reason
             (proposal-field-value decision 'reason)
             'proposal-quarantined-control-plane))))

;; Approval resolution from a proposal is also quarantined.
(let ((analysis (analyze-code-action
                 '(approval-resolve! store request-id approved) '())))
  (check 'approval-quarantine-status
         (analysis-status analysis) 'quarantined)
  (check 'approval-quarantine-decision
         (proposal-field-value
          (car (analysis-quarantine-decisions analysis)) 'operation)
         'approval-resolve!))

;; A quarantine trigger dominates even when a host call is also present.
(let ((analysis (analyze-code-action
                 '(begin (file-write "o" p) (grant-revoke! handle))
                 (list (list 'operations operations)))))
  (check 'quarantine-dominates-status
         (analysis-status analysis) 'quarantined)
  (check 'quarantine-dominates-has-decision
         (length (analysis-quarantine-decisions analysis)) 1))

;; Extra option-supplied quarantine triggers are honored.
(let ((analysis (analyze-code-action
                 '(custom-escalate now)
                 (list (list 'quarantine '(custom-escalate))))))
  (check 'extra-quarantine-status
         (analysis-status analysis) 'quarantined))

;;;; The pure-form budget bounds the walk

(let ((analysis (analyze-code-action
                 '(+ 1 (+ 2 (+ 3 4)))
                 (list (list 'max-pure-cost 3)))))
  (check 'budget-status (analysis-status analysis) 'budget-exhausted))

;;;; Analysis is deterministic and replayable

(check 'analysis-deterministic
       (analyze-code-action '(file-write "o" p)
                            (list (list 'operations operations)))
       (analyze-code-action '(file-write "o" p)
                            (list (list 'operations operations))))

(if (> failures 0)
    (error "portable agent proposal tests failed" failures))
