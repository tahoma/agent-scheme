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
        (agent reliability))

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
(let ((report (measure-reliability reliability-fixture 2 '())))
  (check 'baseline-total
         (reliability-field-value report 'total)
         4)
  (check 'baseline-passed
         (reliability-field-value report 'passed)
         1)
  (check 'baseline-pass-1
         (reliability-field-value report 'pass^1)
         1/4)
  (check 'baseline-pass-2
         (reliability-field-value report 'pass^k)
         0)
  (check 'baseline-complete-slice
         (slice-count report 'complete)
         1)
  (check 'baseline-budget-slice
         (slice-count report 'budget-exhausted)
         1)
  (check 'baseline-policy-slice
         (slice-count report 'policy-denied)
         1)
  (check 'baseline-verifier-slice
         (slice-count report 'failed-verifier)
         1)
  (check-true 'baseline-trials-recorded
              (= (length (reliability-field-value report 'trials)) 4)))

;; Disabling advisory policy lets the advisory-violation trial pass, but the
;; gate-denied trial remains denied.
(let ((report (measure-reliability
               reliability-fixture
               2
               '((advisory-policy disabled)))))
  (check 'advisory-disabled-pass-1
         (reliability-field-value report 'pass^1)
         1/2)
  (check 'advisory-disabled-pass-2
         (reliability-field-value report 'pass^k)
         1/6)
  (check 'advisory-disabled-complete-slice
         (slice-count report 'complete)
         2)
  (check 'advisory-disabled-policy-slice
         (slice-count report 'policy-denied)
         1))

;; Attempting to disable the gate-enforced tier has no effect.
(let ((report (measure-reliability
               reliability-fixture
               2
               '((gate-enforced-policy disabled)))))
  (check 'gate-disabled-pass-1
         (reliability-field-value report 'pass^1)
         1/4)
  (check 'gate-disabled-policy-slice
         (slice-count report 'policy-denied)
         1))

;; The ablation report captures the pass^1 delta for advisory rules and the
;; zero delta for gate-enforced authority rules.
(let ((ablation (measure-policy-ablation reliability-fixture)))
  (check 'ablation-advisory-delta
         (reliability-field-value ablation 'advisory-pass^1-delta)
         1/4)
  (check 'ablation-gate-delta
         (reliability-field-value ablation 'gate-pass^1-delta)
         0)
  (check 'ablation-gate-unablatable
         (reliability-field-value ablation 'gate-enforced-unablatable)
         #t))

;; Reward compares canonical external forms instead of raw equal? so record
;; streams can be replayed by host implementations with different object
;; identity behavior.
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
  (check 'canonical-reward-mismatch
         (reliability-field-value mismatch 'passed)
         0)
  (check 'canonical-reward-failed-verifier
         (slice-count mismatch 'failed-verifier)
         1))

(if (> failures 0)
    (error "portable agent reliability tests failed" failures))
