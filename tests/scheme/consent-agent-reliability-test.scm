;;; Portable Consent Scheme agent reliability metric tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent reliability)' pass^k measurement library over the shared fixture in
;;; fixtures/agent/reliability.scm.  The fixture reseeds only model/user inputs
;;; while policy, budgets, and tool transitions stay fixed, then reports pass^k
;;; sliced by typed stop-receipt reason plus a two-tier policy ablation.

(import (scheme base)
        (scheme file)
        (scheme read)
        (scheme write)
        (agent reliability)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Shared fixture consumed by both portable and Emacs-hosted tests.
(define reliability-fixture
  (call-with-input-file "fixtures/agent/reliability.scm" read))

;; Return REASON's count from REPORT's slices.
(define (slice-count report reason)
  (let loop ((slices (reliability-field-value report 'slices)))
    (cond
     ((null? slices) #f)
     ((eq? (reliability-field-value (car slices) 'reason) reason)
      (reliability-field-value (car slices) 'count))
     (else (loop (cdr slices))))))

;; Baseline: one complete, one budget-exhausted, one policy-denied, and one
;; failed-verifier run.
(testing-registry-case
 'baseline-total '(portable agent)
(let ((report (measure-reliability reliability-fixture 2 '())))
  (test-equal 'baseline-total
             4
             (reliability-field-value report 'total))
  (test-equal 'baseline-passed
             1
             (reliability-field-value report 'passed))
  (test-equal 'baseline-pass-1
             1/4
             (reliability-field-value report 'pass^1))
  (test-equal 'baseline-pass-2
             0
             (reliability-field-value report 'pass^k))
  (test-equal 'baseline-complete-slice
             1
             (slice-count report 'complete))
  (test-equal 'baseline-budget-slice
             1
             (slice-count report 'budget-exhausted))
  (test-equal 'baseline-policy-slice
             1
             (slice-count report 'policy-denied))
  (test-equal 'baseline-verifier-slice
             1
             (slice-count report 'failed-verifier))
  (test-assert 'baseline-trials-recorded
             (= (length (reliability-field-value report 'trials)) 4))))

;; Disabling advisory policy lets the advisory-violation trial pass, but the
;; gate-denied trial remains denied.
(testing-registry-case
 'advisory-disabled-pass-1 '(portable agent)
(let ((report (measure-reliability
               reliability-fixture
               2
               '((advisory-policy disabled)))))
  (test-equal 'advisory-disabled-pass-1
             1/2
             (reliability-field-value report 'pass^1))
  (test-equal 'advisory-disabled-pass-2
             1/6
             (reliability-field-value report 'pass^k))
  (test-equal 'advisory-disabled-complete-slice
             2
             (slice-count report 'complete))
  (test-equal 'advisory-disabled-policy-slice
             1
             (slice-count report 'policy-denied))))

;; Attempting to disable the gate-enforced tier has no effect.
(testing-registry-case
 'gate-disabled-pass-1 '(portable agent)
(let ((report (measure-reliability
               reliability-fixture
               2
               '((gate-enforced-policy disabled)))))
  (test-equal 'gate-disabled-pass-1
             1/4
             (reliability-field-value report 'pass^1))
  (test-equal 'gate-disabled-policy-slice
             1
             (slice-count report 'policy-denied))))

;; The ablation report captures the pass^1 delta for advisory rules and the
;; zero delta for gate-enforced authority rules.
(testing-registry-case
 'ablation-advisory-delta '(portable agent)
(let ((ablation (measure-policy-ablation reliability-fixture)))
  (test-equal 'ablation-advisory-delta
             1/4
             (reliability-field-value ablation 'advisory-pass^1-delta))
  (test-equal 'ablation-gate-delta
             0
             (reliability-field-value ablation 'gate-pass^1-delta))
  (test-equal 'ablation-gate-unablatable
             #t
             (reliability-field-value ablation 'gate-enforced-unablatable))))

;; Reward compares canonical external forms instead of raw equal? so record
;; streams can be replayed by host implementations with different object
;; identity behavior.
(testing-registry-case
 'canonical-reward-mismatch '(portable agent)
(let ((mismatch
       (measure-reliability
        '(consent-agent-reliability-fixture
          (version 1)
          (goal "mismatch")
          (goal-final-state (record (status expected)))
          (operations ())
          (trials
           (((id trial-mismatch)
             (model-seed model-mismatch)
             (user-seed user-mismatch)
             (final-state (record (status actual)))
             (provider ((finish (record (status actual)))))))))
        1
        '())))
  (test-equal 'canonical-reward-mismatch
             0
             (reliability-field-value mismatch 'passed))
  (test-equal 'canonical-reward-failed-verifier
             1
             (slice-count mismatch 'failed-verifier))))

(testing-runner-main "Consent Agent Reliability portable tests" (command-line))
