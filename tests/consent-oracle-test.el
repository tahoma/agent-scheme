;;; consent-oracle-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for comparing pure shared fixtures against external R7RS reference
;; implementations.

;;; Code:

(require 'ert)
(require 'consent-oracle)
(require 'consent-test-helper)

(ert-deftest consent-oracle-test-classifies-eligibility ()
  "Classify fixtures that should and should not run against references."
  (let ((portable-case
         `((id primitive-procedure-call)
           (kind r7rs-conformance)
           (phase eval)
           (category primitive-expressions)
           (section "4.1")
           (status implemented)
           (oracle shared)
           (options ())
           (source (form ,(consent-read "(+ 1 2)")))
           (expect (value 3))
           (description "Portable primitive call.")))
        (policy-case
         `((id standard-library-file-exists-policy)
           (kind r7rs-conformance)
           (phase eval)
           (category standard-libraries)
           (section "6.14")
           (status policy-gated)
           (oracle shared)
           (options ())
           (source
             (forms
               ,(consent-read "(import (scheme file))")
               ,(consent-read "(file-exists? \"x\")")))
           (expect (value t))
           (description "Policy-gated file access.")))
        (agent-case
         `((id eval-multiple-values-result)
           (kind agent-specific)
           (phase eval-result)
           (category multiple-values)
           (section "6.10")
           (status implemented)
           (oracle shared)
           (options ())
           (source (form ,(consent-read "(values 1 2)")))
           (expect
             (result
               (evaluation-result (status values))))
           (description "Agent-specific result datum."))))
    (should (eq (consent-oracle-case-classification portable-case)
                'eligible))
    (should (eq (consent-oracle-case-classification policy-case)
                'policy-gated))
    (should (eq (consent-oracle-case-classification agent-case)
                'not-oracle-eligible))))

(ert-deftest consent-oracle-test-classifies-explicit-eligibility-metadata ()
  "Honor explicit restrictive oracle eligibility metadata."
  (let ((metadata-case
         `((id explicit-policy)
           (kind r7rs-conformance)
           (phase eval)
           (category standard-libraries)
           (section "6.13")
           (status implemented)
           (oracle shared)
           (oracle-eligibility policy-gated)
           (oracle-reason host-policy)
           (options ())
           (source (form ,(consent-read "(+ 1 2)")))
           (expect (value 3))
           (description "Synthetic metadata case."))))
    (should (eq (consent-oracle-case-classification metadata-case)
                'policy-gated))))

(ert-deftest consent-oracle-test-skips-reference-mode-sensitive-program-case ()
  "Skip strict program-shape fixtures when references run file-REPL modes."
  (let ((case
         (cl-find-if
          (lambda (candidate)
            (eq (consent-oracle--field candidate 'id)
                'program-import-after-expression-error))
          (consent-oracle-fixture-cases))))
    (should case)
    (should (eq (consent-oracle--field case 'oracle-reason)
                'implementation-dependent))
    (should (eq (consent-oracle-case-classification case)
                'not-oracle-eligible))))

(ert-deftest consent-oracle-test-reports-missing-reference ()
  "Missing optional reference implementations produce readable reports."
  (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
         (implementation
          (consent-oracle-reference
           :name 'missing-r7rs
           :command nil
           :evaluator nil))
         (report (consent-oracle-run-case case (list implementation))))
    (should (eq (consent-oracle-report-status report)
                'unsupported-reference))
    (should
     (string-match-p
      "(oracle-report (case primitive-procedure-call)"
      (consent-oracle-report->external report)))
    (should
     (string-match-p
      "(missing-r7rs unsupported-reference"
      (consent-oracle-report->external report)))))

(ert-deftest consent-oracle-test-classifies-agreement-and-mismatch ()
  "Classify agreement, implementation variation, and Consent Scheme mismatch."
  (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
         (agreeing
          (consent-oracle-reference
           :name 'agreeing
           :command "mock"
           :evaluator (lambda (_case) '(:status value :value "3"))))
         (different
          (consent-oracle-reference
           :name 'different
           :command "mock"
           :evaluator (lambda (_case) '(:status value :value "4")))))
    (should (eq (consent-oracle-report-status
                 (consent-oracle-run-case case (list agreeing)))
                'portable-agree))
    (should (eq (consent-oracle-report-status
                 (consent-oracle-run-case case (list different)))
                'agent-mismatch))
    (should (eq (consent-oracle-report-status
                 (consent-oracle-run-case case (list agreeing different)))
                'implementation-variant))))

(ert-deftest consent-oracle-test-renders-ineligible-report ()
  "Render policy and ineligible fixture classifications as reports."
  (let* ((case (consent-test-fixture-case
    'standard-library-file-exists-policy))
         (report (consent-oracle-run-case case nil)))
    (should (eq (consent-oracle-report-status report) 'policy-gated))
    (should
     (string-match-p
      "(status policy-gated)"
      (consent-oracle-report->external report)))))

(ert-deftest consent-oracle-test-parses-circular-reference-output ()
  "Parse circular reference output without recursing through host data."
  (should
   (equal (consent-oracle--parse-reference-output
           "(value #0=(a . #0#))")
          '(:status value :value "#0=(a . #0#)"))))

(ert-deftest consent-oracle-test-parses-output-after-diagnostic-lines ()
  "Parse oracle output when an implementation emits startup diagnostics."
  (should
   (equal (consent-oracle--parse-reference-output
           "*warning* cache unavailable\n(value 3)\n")
          '(:status value :value "3"))))

(ert-deftest consent-oracle-test-parses-guile-bytevector-output ()
  "Normalize Guile bytevector writer spelling before reading output."
  (should
   (equal (consent-oracle--parse-reference-output
           "(value #vu8(1 2 3))\n")
          '(:status value :value "#u8(1 2 3)"))))

(ert-deftest consent-oracle-test-filters-reports-by-status ()
  "Filter oracle reports to requested status names."
  (let ((reports
         (list
          (consent-oracle--make-report
           :case-id 'portable :results nil :status 'portable-agree)
          (consent-oracle--make-report
           :case-id 'mismatch :results nil :status 'agent-mismatch)
          (consent-oracle--make-report
           :case-id 'variant :results nil :status 'implementation-variant))))
    (should
     (equal
      (mapcar #'consent-oracle-report-case-id
              (consent-oracle-filter-reports
               reports
               '(agent-mismatch implementation-variant)))
      '(mismatch variant)))
    (should
     (equal
      (mapcar #'consent-oracle-report-case-id
              (consent-oracle-filter-reports reports nil))
      '(portable mismatch variant)))))

(ert-deftest consent-oracle-test-renders-summary ()
  "Render a Scheme-readable summary of oracle report statuses."
  (let ((reports
         (list
          (consent-oracle--make-report
           :case-id 'portable :results nil :status 'portable-agree)
          (consent-oracle--make-report
           :case-id 'mismatch :results nil :status 'agent-mismatch)
          (consent-oracle--make-report
           :case-id 'variant :results nil :status 'implementation-variant)
          (consent-oracle--make-report
           :case-id 'policy :results nil :status 'policy-gated))))
    (should
     (equal
      (consent-oracle-summary->external reports)
      "(oracle-summary (total 4) (portable-agree 1) (implementation-variant 1)\
 (agent-mismatch 1) (unsupported-reference 0) (policy-gated 1)\
 (not-oracle-eligible 0))"))))

(ert-deftest consent-oracle-test-parses-status-filter ()
  "Parse comma-separated status filters from batch environment text."
  (should
   (equal
    (consent-oracle-parse-status-filter
     "agent-mismatch, implementation-variant")
    '(agent-mismatch implementation-variant)))
  (should-not (consent-oracle-parse-status-filter nil))
  (should-not (consent-oracle-parse-status-filter "")))

(ert-deftest consent-oracle-test-normalizes-chibi-complex-nan-output ()
  "Treat Chibi's complex NaN sign spelling as equivalent report output."
  (let* ((case (consent-test-fixture-case 'numeric-polar-special-values))
         (reference
          (consent-oracle-reference
           :name 'chibi-spelling
           :command "mock"
           :evaluator
           (lambda (_case)
             '(:status value
               :value
               "(0+inf.0i +inf.0++nan.0i +nan.0++nan.0i +nan.0++nan.0i)"))))
         (report (consent-oracle-run-case case (list reference))))
    (should (eq (consent-oracle-report-status report) 'portable-agree))))

(ert-deftest consent-oracle-test-gauche-reference-uses-environment ()
  "Build the Gauche adapter from CONSENT_GAUCHE when configured."
  (let ((process-environment
         (cons "CONSENT_GAUCHE=/example/bin/gosh" process-environment))
        (consent-oracle-gauche-command nil))
    (let ((implementation (consent-oracle-gauche-reference)))
      (should (eq (consent-oracle-reference-name implementation)
                  'gauche))
      (should (equal (consent-oracle-reference-command implementation)
                     "/example/bin/gosh")))))

(ert-deftest consent-oracle-test-reference-carries-command-arguments ()
  "Keep adapter command arguments separate from the executable."
  (let ((implementation
         (consent-oracle-reference
          :name 'mock-r7rs
          :command "mock"
          :arguments '("--r7rs"))))
    (should (equal (consent-oracle-reference-arguments implementation)
                   '("--r7rs")))))

(ert-deftest consent-oracle-test-reference-can-transform-program-source ()
  "Allow adapters to wrap generated source before execution."
  (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
         (implementation
          (consent-oracle-reference
           :name 'wrapped-r7rs
           :command "mock"
           :program-filter (lambda (program)
                             (concat ";; wrapped\n" program))))
         (program
          (consent-oracle--program-for-reference implementation case)))
    (should (string-prefix-p ";; wrapped\n(import " program))))

(ert-deftest consent-oracle-test-guile-reference-uses-environment ()
  "Build the Guile adapter from CONSENT_GUILE when configured."
  (let ((process-environment
         (cons "CONSENT_GUILE=/example/bin/guile" process-environment))
        (consent-oracle-guile-command nil))
    (let ((implementation (consent-oracle-guile-reference)))
      (should (eq (consent-oracle-reference-name implementation)
                  'guile))
      (should (equal (consent-oracle-reference-command implementation)
                     "/example/bin/guile"))
      (should (equal (consent-oracle-reference-arguments implementation)
                     '("--no-auto-compile" "--r7rs"))))))

(ert-deftest consent-oracle-test-sagittarius-reference-uses-environment ()
  "Build the Sagittarius adapter from CONSENT_SAGITTARIUS when configured."
  (let ((process-environment
         (cons "CONSENT_SAGITTARIUS=/example/bin/sagittarius"
               process-environment))
        (consent-oracle-sagittarius-command nil))
    (let ((implementation (consent-oracle-sagittarius-reference)))
      (should (eq (consent-oracle-reference-name implementation)
                  'sagittarius))
      (should (equal (consent-oracle-reference-command implementation)
                     "/example/bin/sagittarius"))
      (should (equal (consent-oracle-reference-arguments implementation)
                     '("-r" "7"))))))

(ert-deftest consent-oracle-test-racket-reference-uses-environment ()
  "Build the Racket adapter from CONSENT_RACKET when configured."
  (let ((process-environment
         (cons "CONSENT_RACKET=/example/bin/racket"
               process-environment))
        (consent-oracle-racket-command nil))
    (let ((implementation (consent-oracle-racket-reference)))
      (should (eq (consent-oracle-reference-name implementation)
                  'racket))
      (should (equal (consent-oracle-reference-command implementation)
                     "/example/bin/racket"))
      (should (string-prefix-p
               "#lang r7rs\n"
               (funcall
                (consent-oracle-reference-program-filter implementation)
                "(import (scheme base))"))))))

(ert-deftest consent-oracle-test-chicken-reference-uses-environment ()
  "Build the CHICKEN adapter from CONSENT_CHICKEN when configured."
  (let ((process-environment
         (cons "CONSENT_CHICKEN=/example/bin/csi"
               process-environment))
        (consent-oracle-chicken-command nil))
    (let ((implementation (consent-oracle-chicken-reference)))
      (should (eq (consent-oracle-reference-name implementation)
                  'chicken))
      (should (equal (consent-oracle-reference-command implementation)
                     "/example/bin/csi"))
      (should (equal (consent-oracle-reference-arguments implementation)
                     '("-q" "-R" "r7rs" "-s"))))))

(ert-deftest consent-oracle-test-gambit-reference-uses-environment ()
  "Build the Gambit adapter from CONSENT_GAMBIT when configured."
  (let ((process-environment
         (cons "CONSENT_GAMBIT=/example/bin/gsi"
               process-environment))
        (consent-oracle-gambit-command nil)
        (consent-oracle-root-directory
         (file-name-as-directory (expand-file-name "repo"
           temporary-file-directory))))
    (let ((implementation (consent-oracle-gambit-reference)))
      (should (eq (consent-oracle-reference-name implementation)
                  'gambit))
      (should (equal (consent-oracle-reference-command implementation)
                     "/example/bin/gsi"))
      (should
       (equal
        (consent-oracle-reference-arguments implementation)
        (list
         (format "-:r7rs,search=%s"
                 (expand-file-name "scheme"
                                   consent-oracle-root-directory))))))))

(ert-deftest consent-oracle-test-gambit-compiler-uses-environment ()
  "Discover the Gambit compiler path from CONSENT_GAMBIT_COMPILER."
  (let ((process-environment
         (cons "CONSENT_GAMBIT_COMPILER=/example/bin/gsc"
               process-environment))
        (consent-oracle-gambit-compiler-command nil))
    (should
     (equal (consent-oracle-gambit-compiler-executable)
            "/example/bin/gsc"))))

(ert-deftest consent-oracle-test-default-references-use-chibi-sagittarius ()
  "Use Chibi and Sagittarius as the default oracle reference set."
  (should
   (equal (mapcar #'consent-oracle-reference-name
                  (consent-oracle-default-references))
          '(chibi sagittarius))))

(ert-deftest consent-oracle-test-all-references-include-seven-candidates ()
  "Expose the full candidate set separately from defaults."
  (should
   (equal (mapcar #'consent-oracle-reference-name
                  (consent-oracle-all-references))
          '(chibi gauche guile sagittarius racket chicken gambit))))

(ert-deftest consent-oracle-test-parses-reference-filter ()
  "Parse comma-separated oracle reference names from batch environment text."
  (should
   (equal
    (consent-oracle-parse-reference-filter "racket, gambit")
    '(racket gambit)))
  (should-not (consent-oracle-parse-reference-filter nil))
  (should-error
   (consent-oracle-parse-reference-filter "unknown")
   :type 'error))

(ert-deftest consent-oracle-test-selects-references-by-name ()
  "Resolve selected reference adapters in requested order."
  (should
   (equal (mapcar #'consent-oracle-reference-name
                  (consent-oracle-selected-references
                   '(sagittarius guile)))
          '(sagittarius guile))))

(ert-deftest consent-oracle-test-chibi-runs-simple-fixture ()
  "Run one small pure fixture through Chibi when it is available."
  (let ((implementation (consent-oracle-chibi-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest consent-oracle-test-gauche-runs-simple-fixture ()
  "Run one small pure fixture through Gauche when it is available."
  (let ((implementation (consent-oracle-gauche-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest consent-oracle-test-guile-runs-simple-fixture ()
  "Run one small pure fixture through Guile when it is available."
  (let ((implementation (consent-oracle-guile-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest consent-oracle-test-sagittarius-runs-simple-fixture ()
  "Run one small pure fixture through Sagittarius when it is available."
  (let ((implementation (consent-oracle-sagittarius-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest consent-oracle-test-chicken-runs-simple-fixture ()
  "Run one small pure fixture through CHICKEN when R7RS mode is available."
  (let ((implementation (consent-oracle-chicken-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (skip-unless
     (consent-oracle--chicken-r7rs-available-p
      (consent-oracle-reference-command implementation)))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest consent-oracle-test-racket-runs-simple-fixture ()
  "Run one small pure fixture through Racket when R7RS mode is available."
  (let ((implementation (consent-oracle-racket-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (skip-unless
     (consent-oracle--racket-r7rs-available-p
      (consent-oracle-reference-command implementation)))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest consent-oracle-test-gambit-runs-simple-fixture ()
  "Run one small pure fixture through Gambit when R7RS mode is available."
  (let ((implementation (consent-oracle-gambit-reference)))
    (skip-unless (consent-oracle-reference-command implementation))
    (skip-unless
     (consent-oracle--gambit-r7rs-available-p
      (consent-oracle-reference-command implementation)))
    (let* ((case (consent-test-fixture-case 'primitive-procedure-call))
           (result (consent-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

;;; consent-oracle-test.el ends here
