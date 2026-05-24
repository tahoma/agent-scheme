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

(ert-deftest agent-scheme-oracle-test-classifies-explicit-eligibility-metadata ()
  "Honor explicit restrictive oracle eligibility metadata."
  (let ((metadata-case
         '((id explicit-policy)
           (kind r7rs-conformance)
           (phase eval)
           (category standard-libraries)
           (section "6.13")
           (status implemented)
           (oracle shared)
           (oracle-eligibility policy-gated)
           (oracle-reason host-policy)
           (options ())
           (source "(+ 1 2)")
           (expect (value "3"))
           (description "Synthetic metadata case."))))
    (should (eq (agent-scheme-oracle-case-classification metadata-case)
                'policy-gated))))

(ert-deftest agent-scheme-oracle-test-skips-reference-mode-sensitive-program-case ()
  "Skip strict program-shape fixtures when references run file-REPL modes."
  (let ((case
         (cl-find-if
          (lambda (candidate)
            (eq (agent-scheme-oracle--field candidate 'id)
                'program-import-after-expression-error))
          (agent-scheme-oracle-fixture-cases))))
    (should case)
    (should (eq (agent-scheme-oracle--field case 'oracle-reason)
                'implementation-dependent))
    (should (eq (agent-scheme-oracle-case-classification case)
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

(ert-deftest agent-scheme-oracle-test-parses-output-after-diagnostic-lines ()
  "Parse oracle output when an implementation emits startup diagnostics."
  (should
   (equal (agent-scheme-oracle--parse-reference-output
           "*warning* cache unavailable\n(value 3)\n")
          '(:status value :value "3"))))

(ert-deftest agent-scheme-oracle-test-parses-guile-bytevector-output ()
  "Normalize Guile bytevector writer spelling before reading output."
  (should
   (equal (agent-scheme-oracle--parse-reference-output
           "(value #vu8(1 2 3))\n")
          '(:status value :value "#u8(1 2 3)"))))

(ert-deftest agent-scheme-oracle-test-filters-reports-by-status ()
  "Filter oracle reports to requested status names."
  (let ((reports
         (list
          (agent-scheme-oracle--make-report
           :case-id 'portable :results nil :status 'portable-agree)
          (agent-scheme-oracle--make-report
           :case-id 'mismatch :results nil :status 'agent-mismatch)
          (agent-scheme-oracle--make-report
           :case-id 'variant :results nil :status 'implementation-variant))))
    (should
     (equal
      (mapcar #'agent-scheme-oracle-report-case-id
              (agent-scheme-oracle-filter-reports
               reports
               '(agent-mismatch implementation-variant)))
      '(mismatch variant)))
    (should
     (equal
      (mapcar #'agent-scheme-oracle-report-case-id
              (agent-scheme-oracle-filter-reports reports nil))
      '(portable mismatch variant)))))

(ert-deftest agent-scheme-oracle-test-renders-summary ()
  "Render a Scheme-readable summary of oracle report statuses."
  (let ((reports
         (list
          (agent-scheme-oracle--make-report
           :case-id 'portable :results nil :status 'portable-agree)
          (agent-scheme-oracle--make-report
           :case-id 'mismatch :results nil :status 'agent-mismatch)
          (agent-scheme-oracle--make-report
           :case-id 'variant :results nil :status 'implementation-variant)
          (agent-scheme-oracle--make-report
           :case-id 'policy :results nil :status 'policy-gated))))
    (should
     (equal
      (agent-scheme-oracle-summary->external reports)
      "(oracle-summary (total 4) (portable-agree 1) (implementation-variant 1) (agent-mismatch 1) (unsupported-reference 0) (policy-gated 1) (not-oracle-eligible 0))"))))

(ert-deftest agent-scheme-oracle-test-parses-status-filter ()
  "Parse comma-separated status filters from batch environment text."
  (should
   (equal
    (agent-scheme-oracle-parse-status-filter
     "agent-mismatch, implementation-variant")
    '(agent-mismatch implementation-variant)))
  (should-not (agent-scheme-oracle-parse-status-filter nil))
  (should-not (agent-scheme-oracle-parse-status-filter "")))

(ert-deftest agent-scheme-oracle-test-normalizes-chibi-complex-nan-output ()
  "Treat Chibi's complex NaN sign spelling as equivalent report output."
  (let* ((case (agent-scheme-test-fixture-case 'numeric-polar-special-values))
         (reference
          (agent-scheme-oracle-reference
           :name 'chibi-spelling
           :command "mock"
           :evaluator
           (lambda (_case)
             '(:status value
               :value
               "(0+inf.0i +inf.0++nan.0i +nan.0++nan.0i +nan.0++nan.0i)"))))
         (report (agent-scheme-oracle-run-case case (list reference))))
    (should (eq (agent-scheme-oracle-report-status report) 'portable-agree))))

(ert-deftest agent-scheme-oracle-test-gauche-reference-uses-environment ()
  "Build the Gauche adapter from AGENT_SCHEME_GAUCHE when configured."
  (let ((process-environment
         (cons "AGENT_SCHEME_GAUCHE=/example/bin/gosh" process-environment))
        (agent-scheme-oracle-gauche-command nil))
    (let ((implementation (agent-scheme-oracle-gauche-reference)))
      (should (eq (agent-scheme-oracle-reference-name implementation)
                  'gauche))
      (should (equal (agent-scheme-oracle-reference-command implementation)
                     "/example/bin/gosh")))))

(ert-deftest agent-scheme-oracle-test-reference-carries-command-arguments ()
  "Keep adapter command arguments separate from the executable."
  (let ((implementation
         (agent-scheme-oracle-reference
          :name 'mock-r7rs
          :command "mock"
          :arguments '("--r7rs"))))
    (should (equal (agent-scheme-oracle-reference-arguments implementation)
                   '("--r7rs")))))

(ert-deftest agent-scheme-oracle-test-reference-can-transform-program-source ()
  "Allow adapters to wrap generated source before execution."
  (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
         (implementation
          (agent-scheme-oracle-reference
           :name 'wrapped-r7rs
           :command "mock"
           :program-filter (lambda (program)
                             (concat ";; wrapped\n" program))))
         (program
          (agent-scheme-oracle--program-for-reference implementation case)))
    (should (string-prefix-p ";; wrapped\n(import " program))))

(ert-deftest agent-scheme-oracle-test-guile-reference-uses-environment ()
  "Build the Guile adapter from AGENT_SCHEME_GUILE when configured."
  (let ((process-environment
         (cons "AGENT_SCHEME_GUILE=/example/bin/guile" process-environment))
        (agent-scheme-oracle-guile-command nil))
    (let ((implementation (agent-scheme-oracle-guile-reference)))
      (should (eq (agent-scheme-oracle-reference-name implementation)
                  'guile))
      (should (equal (agent-scheme-oracle-reference-command implementation)
                     "/example/bin/guile"))
      (should (equal (agent-scheme-oracle-reference-arguments implementation)
                     '("--no-auto-compile" "--r7rs"))))))

(ert-deftest agent-scheme-oracle-test-sagittarius-reference-uses-environment ()
  "Build the Sagittarius adapter from AGENT_SCHEME_SAGITTARIUS when configured."
  (let ((process-environment
         (cons "AGENT_SCHEME_SAGITTARIUS=/example/bin/sagittarius"
               process-environment))
        (agent-scheme-oracle-sagittarius-command nil))
    (let ((implementation (agent-scheme-oracle-sagittarius-reference)))
      (should (eq (agent-scheme-oracle-reference-name implementation)
                  'sagittarius))
      (should (equal (agent-scheme-oracle-reference-command implementation)
                     "/example/bin/sagittarius"))
      (should (equal (agent-scheme-oracle-reference-arguments implementation)
                     '("-r" "7"))))))

(ert-deftest agent-scheme-oracle-test-racket-reference-uses-environment ()
  "Build the Racket adapter from AGENT_SCHEME_RACKET when configured."
  (let ((process-environment
         (cons "AGENT_SCHEME_RACKET=/example/bin/racket"
               process-environment))
        (agent-scheme-oracle-racket-command nil))
    (let ((implementation (agent-scheme-oracle-racket-reference)))
      (should (eq (agent-scheme-oracle-reference-name implementation)
                  'racket))
      (should (equal (agent-scheme-oracle-reference-command implementation)
                     "/example/bin/racket"))
      (should (string-prefix-p
               "#lang r7rs\n"
               (funcall
                (agent-scheme-oracle-reference-program-filter implementation)
                "(import (scheme base))"))))))

(ert-deftest agent-scheme-oracle-test-chicken-reference-uses-environment ()
  "Build the CHICKEN adapter from AGENT_SCHEME_CHICKEN when configured."
  (let ((process-environment
         (cons "AGENT_SCHEME_CHICKEN=/example/bin/csi"
               process-environment))
        (agent-scheme-oracle-chicken-command nil))
    (let ((implementation (agent-scheme-oracle-chicken-reference)))
      (should (eq (agent-scheme-oracle-reference-name implementation)
                  'chicken))
      (should (equal (agent-scheme-oracle-reference-command implementation)
                     "/example/bin/csi"))
      (should (equal (agent-scheme-oracle-reference-arguments implementation)
                     '("-q" "-R" "r7rs" "-s"))))))

(ert-deftest agent-scheme-oracle-test-gambit-reference-uses-environment ()
  "Build the Gambit adapter from AGENT_SCHEME_GAMBIT when configured."
  (let ((process-environment
         (cons "AGENT_SCHEME_GAMBIT=/example/bin/gsi"
               process-environment))
        (agent-scheme-oracle-gambit-command nil)
        (agent-scheme-oracle-root-directory
         (file-name-as-directory (expand-file-name "repo" temporary-file-directory))))
    (let ((implementation (agent-scheme-oracle-gambit-reference)))
      (should (eq (agent-scheme-oracle-reference-name implementation)
                  'gambit))
      (should (equal (agent-scheme-oracle-reference-command implementation)
                     "/example/bin/gsi"))
      (should
       (equal
        (agent-scheme-oracle-reference-arguments implementation)
        (list
         (format "-:r7rs,search=%s"
                 (expand-file-name "scheme"
                                   agent-scheme-oracle-root-directory))))))))

(ert-deftest agent-scheme-oracle-test-gambit-compiler-uses-environment ()
  "Discover the future Gambit compiler path from AGENT_SCHEME_GAMBIT_COMPILER."
  (let ((process-environment
         (cons "AGENT_SCHEME_GAMBIT_COMPILER=/example/bin/gsc"
               process-environment))
        (agent-scheme-oracle-gambit-compiler-command nil))
    (should
     (equal (agent-scheme-oracle-gambit-compiler-executable)
            "/example/bin/gsc"))))

(ert-deftest agent-scheme-oracle-test-default-references-use-chibi-sagittarius ()
  "Use Chibi and Sagittarius as the default oracle reference set."
  (should
   (equal (mapcar #'agent-scheme-oracle-reference-name
                  (agent-scheme-oracle-default-references))
          '(chibi sagittarius))))

(ert-deftest agent-scheme-oracle-test-all-references-include-seven-candidates ()
  "Expose the full candidate set separately from defaults."
  (should
   (equal (mapcar #'agent-scheme-oracle-reference-name
                  (agent-scheme-oracle-all-references))
          '(chibi gauche guile sagittarius racket chicken gambit))))

(ert-deftest agent-scheme-oracle-test-parses-reference-filter ()
  "Parse comma-separated oracle reference names from batch environment text."
  (should
   (equal
    (agent-scheme-oracle-parse-reference-filter "racket, gambit")
    '(racket gambit)))
  (should-not (agent-scheme-oracle-parse-reference-filter nil))
  (should-error
   (agent-scheme-oracle-parse-reference-filter "unknown")
   :type 'error))

(ert-deftest agent-scheme-oracle-test-selects-references-by-name ()
  "Resolve selected reference adapters in requested order."
  (should
   (equal (mapcar #'agent-scheme-oracle-reference-name
                  (agent-scheme-oracle-selected-references
                   '(sagittarius guile)))
          '(sagittarius guile))))

(ert-deftest agent-scheme-oracle-test-chibi-runs-simple-fixture ()
  "Run one small pure fixture through Chibi when it is available."
  (let ((implementation (agent-scheme-oracle-chibi-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest agent-scheme-oracle-test-gauche-runs-simple-fixture ()
  "Run one small pure fixture through Gauche when it is available."
  (let ((implementation (agent-scheme-oracle-gauche-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest agent-scheme-oracle-test-guile-runs-simple-fixture ()
  "Run one small pure fixture through Guile when it is available."
  (let ((implementation (agent-scheme-oracle-guile-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest agent-scheme-oracle-test-sagittarius-runs-simple-fixture ()
  "Run one small pure fixture through Sagittarius when it is available."
  (let ((implementation (agent-scheme-oracle-sagittarius-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest agent-scheme-oracle-test-chicken-runs-simple-fixture ()
  "Run one small pure fixture through CHICKEN when R7RS mode is available."
  (let ((implementation (agent-scheme-oracle-chicken-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (skip-unless
     (agent-scheme-oracle--chicken-r7rs-available-p
      (agent-scheme-oracle-reference-command implementation)))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest agent-scheme-oracle-test-racket-runs-simple-fixture ()
  "Run one small pure fixture through Racket when R7RS mode is available."
  (let ((implementation (agent-scheme-oracle-racket-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (skip-unless
     (agent-scheme-oracle--racket-r7rs-available-p
      (agent-scheme-oracle-reference-command implementation)))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

(ert-deftest agent-scheme-oracle-test-gambit-runs-simple-fixture ()
  "Run one small pure fixture through Gambit when R7RS mode is available."
  (let ((implementation (agent-scheme-oracle-gambit-reference)))
    (skip-unless (agent-scheme-oracle-reference-command implementation))
    (skip-unless
     (agent-scheme-oracle--gambit-r7rs-available-p
      (agent-scheme-oracle-reference-command implementation)))
    (let* ((case (agent-scheme-test-fixture-case 'primitive-procedure-call))
           (result (agent-scheme-oracle-run-reference implementation case)))
      (should (equal result '(:status value :value "3"))))))

;;; agent-scheme-oracle-test.el ends here
