;;; agent-scheme-oracle-test.el --- Reference oracle runner tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for comparing pure shared fixtures against external R7RS reference
;; implementations.

;;; Code:

(require 'ert)
(require 'agent-scheme-oracle)
(require 'agent-scheme-test-helper)

(ert-deftest agent-scheme-oracle-test-classifies-eligibility ()
  "Classify fixtures that should and should not run against references."
  (let ((portable-case
         '((id primitive-procedure-call)
           (kind r7rs-conformance)
           (phase eval)
           (category primitive-expressions)
           (section "4.1")
           (status implemented)
           (oracle shared)
           (options ())
           (source "(+ 1 2)")
           (expect (value "3"))
           (description "Portable primitive call.")))
        (policy-case
         '((id standard-library-file-exists-policy)
           (kind r7rs-conformance)
           (phase eval)
           (category standard-libraries)
           (section "6.14")
           (status policy-gated)
           (oracle shared)
           (options ())
           (source "(import (scheme file)) (file-exists? \"x\")")
           (expect (value "#t"))
           (description "Policy-gated file access.")))
        (agent-case
         '((id eval-multiple-values-result)
           (kind agent-specific)
           (phase eval-result)
           (category multiple-values)
           (section "6.10")
           (status implemented)
           (oracle shared)
           (options ())
           (source "(values 1 2)")
           (expect (result "(evaluation-result (status values))"))
           (description "Agent-specific result datum."))))
    (should (eq (agent-scheme-oracle-case-classification portable-case)
                'eligible))
    (should (eq (agent-scheme-oracle-case-classification policy-case)
                'policy-gated))
    (should (eq (agent-scheme-oracle-case-classification agent-case)
                'not-oracle-eligible))))

(ert-deftest agent-scheme-oracle-test-reports-missing-reference ()
  "Missing optional reference implementations produce readable reports."
  (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
         (implementation
          (agent-scheme-oracle-reference
           :name 'missing-r7rs
           :command nil
           :evaluator nil))
         (report (agent-scheme-oracle-run-case case (list implementation))))
    (should (eq (agent-scheme-oracle-report-status report)
                'unsupported-reference))
    (should
     (string-match-p
      "(oracle-report (case primitive-procedure-call)"
      (agent-scheme-oracle-report->external report)))
    (should
     (string-match-p
      "(missing-r7rs unsupported-reference"
      (agent-scheme-oracle-report->external report)))))

(ert-deftest agent-scheme-oracle-test-classifies-agreement-and-mismatch ()
  "Classify agreement, implementation variation, and Agent Scheme mismatch."
  (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
         (agreeing
          (agent-scheme-oracle-reference
           :name 'agreeing
           :command "mock"
           :evaluator (lambda (_case) '(:status value :value "3"))))
         (different
          (agent-scheme-oracle-reference
           :name 'different
           :command "mock"
           :evaluator (lambda (_case) '(:status value :value "4")))))
    (should (eq (agent-scheme-oracle-report-status
                 (agent-scheme-oracle-run-case case (list agreeing)))
                'portable-agree))
    (should (eq (agent-scheme-oracle-report-status
                 (agent-scheme-oracle-run-case case (list different)))
                'agent-mismatch))
    (should (eq (agent-scheme-oracle-report-status
                 (agent-scheme-oracle-run-case case (list agreeing different)))
                'implementation-variant))))

(ert-deftest agent-scheme-oracle-test-renders-ineligible-report ()
  "Render policy and ineligible fixture classifications as reports."
  (let* ((case (agent-scheme-test-fixture-case 'standard-library-file-exists-policy))
         (report (agent-scheme-oracle-run-case case nil)))
    (should (eq (agent-scheme-oracle-report-status report) 'policy-gated))
    (should
     (string-match-p
      "(status policy-gated)"
      (agent-scheme-oracle-report->external report)))))

(ert-deftest agent-scheme-oracle-test-parses-circular-reference-output ()
  "Parse circular reference output without recursing through host data."
  (should
   (equal (agent-scheme-oracle--parse-reference-output
           "(value #0=(a . #0#))")
          '(:status value :value "#0=(a . #0#)"))))

(ert-deftest agent-scheme-oracle-test-chibi-runs-simple-fixture ()
  "Run one small pure fixture through Chibi when it is available."
  (let ((implementation (agent-scheme-oracle-chibi-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

;;; agent-scheme-oracle-test.el ends here
