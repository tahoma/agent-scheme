;;; consent-agent-reliability-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent reliability)' pass^k
;; measurement library evaluated through the Emacs Consent interpreter.  The
;; same shared fixture backs the portable host shards
;; (tests/scheme/consent-agent-reliability-test.scm), so these expectations are
;; the Emacs half of the cross-host check for stop-receipt slicing, canonical
;; reward comparison, and two-tier policy ablation.

;;; Code:

(require 'ert)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-result)

(defconst consent-agent-reliability-test--fixture-path
  "fixtures/agent/reliability.scm"
  "Repository-relative path to shared agent reliability fixture records.")

(defun consent-agent-reliability-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source nil
                        '(:max-steps 1000000
                          :max-host-callbacks 100000))))

(defun consent-agent-reliability-test--fixture ()
  "Return the parsed shared agent reliability fixture datum."
  (let* ((path (expand-file-name
                consent-agent-reliability-test--fixture-path
                consent--test-root))
         (forms (consent-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (car forms)))

(defun consent-agent-reliability-test--fixture-external ()
  "Return the shared fixture as external Scheme source."
  (consent-datum->external
   (consent-agent-reliability-test--fixture)))

(ert-deftest consent-agent-reliability-test-slices-pass-k-by-reason ()
  "Baseline pass^k reports complete, budget, policy, and verifier slices."
  (should
   (equal
    (consent-agent-reliability-test--external
     (format
      "(import (scheme base) (agent reliability))
       (define fixture '%s)
       (define report (measure-reliability fixture 2 '()))
       (define (slice-count reason)
         (let loop ((slices (reliability-field-value report 'slices)))
           (cond
            ((null? slices) #f)
            ((eq? (reliability-field-value (car slices) 'reason) reason)
             (reliability-field-value (car slices) 'count))
            (else (loop (cdr slices))))))
       (list (reliability-field-value report 'total)
             (reliability-field-value report 'passed)
             (reliability-field-value report 'pass^1)
             (reliability-field-value report 'pass^k)
             (slice-count 'complete)
             (slice-count 'budget-exhausted)
             (slice-count 'policy-denied)
             (slice-count 'failed-verifier)
             (length (reliability-field-value report 'trials)))"
      (consent-agent-reliability-test--fixture-external)))
    "(4 1 1/4 0 1 1 1 1 4)")))

(ert-deftest consent-agent-reliability-test-policy-ablation ()
  "Advisory rules change pass^1; gate-enforced rules are un-ablatable."
  (should
   (equal
    (consent-agent-reliability-test--external
     (format
      "(import (scheme base) (agent reliability))
       (define fixture '%s)
       (define ablation (measure-policy-ablation fixture))
       (define advisory
         (reliability-field-value ablation 'advisory-disabled))
       (define gate
         (reliability-field-value ablation 'gate-disabled))
       (define (slice-count report reason)
         (let loop ((slices (reliability-field-value report 'slices)))
           (cond
            ((null? slices) #f)
            ((eq? (reliability-field-value (car slices) 'reason) reason)
             (reliability-field-value (car slices) 'count))
            (else (loop (cdr slices))))))
       (list (reliability-field-value advisory 'pass^1)
             (reliability-field-value advisory 'passed)
             (reliability-field-value gate 'pass^1)
             (slice-count gate 'policy-denied)
             (reliability-field-value ablation 'advisory-pass^1-delta)
             (reliability-field-value ablation 'gate-pass^1-delta)
             (reliability-field-value ablation 'gate-enforced-unablatable))"
      (consent-agent-reliability-test--fixture-external)))
    "(1/2 2 1/4 1 1/4 0 #t)")))

(ert-deftest consent-agent-reliability-test-reward-uses-serialized-datums ()
  "Final-state reward compares external serialization, not raw identity."
  (should
   (equal
    (consent-agent-reliability-test--external
     "(import (scheme base) (agent reliability))
      (define fixture
        '(consent-agent-reliability-fixture
          (version 1)
          (goal \"mismatch\")
          (goal-final-state (record (status expected)))
          (operations ())
          (trials
           (((id trial-mismatch)
             (model-seed model-mismatch)
             (user-seed user-mismatch)
             (final-state (record (status actual)))
             (provider ((finish (record (status actual))))))))))
      (define report (measure-reliability fixture 1 '()))
      (define (slice-count reason)
        (let loop ((slices (reliability-field-value report 'slices)))
          (cond
           ((null? slices) #f)
           ((eq? (reliability-field-value (car slices) 'reason) reason)
            (reliability-field-value (car slices) 'count))
           (else (loop (cdr slices))))))
      (list (reliability-field-value report 'passed)
            (slice-count 'failed-verifier))")
    "(0 1)")))

(provide 'consent-agent-reliability-test)
;;; consent-agent-reliability-test.el ends here
