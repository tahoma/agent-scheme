;;; agent-scheme-fixture-test.el --- Shared fixture corpus tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the shared Scheme-readable fixture corpus used by reader,
;; evaluator, portable Scheme, and conformance runners.

;;; Code:

(require 'ert)
(require 'agent-scheme-test-helper)

(ert-deftest agent-scheme-fixture-test-suite-is-canonical ()
  "Load the canonical fixture suite and validate fixture shape."
  (let ((suite (agent-scheme-test-fixture-suite)))
    (should (eq (car-safe suite) 'agent-scheme-fixture-suite))
    (should (agent-scheme-test-fixture-cases))
    (agent-scheme-test-fixture-validate-suite suite)))

(ert-deftest agent-scheme-fixture-test-validation-rejects-bad-shapes ()
  "Reject duplicate ids, missing fields, unsupported phases, and bad expects."
  (should-error
   (agent-scheme-test-fixture-validate-suite
    '(agent-scheme-fixture-suite
      (version 1)
      (cases
        ((id duplicate) (kind regression) (phase read)
         (category reader-syntax) (section "2") (status implemented)
         (oracle shared) (options ()) (source "1")
         (expect (value "1")) (description "first"))
        ((id duplicate) (kind regression) (phase read)
         (category reader-syntax) (section "2") (status implemented)
         (oracle shared) (options ()) (source "2")
         (expect (value "2")) (description "second")))))
   :type 'ert-test-failed)
  (should-error
   (agent-scheme-test-fixture-validate-case
    '((id missing-source) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (expect (value "1"))
      (description "missing source")))
   :type 'ert-test-failed)
  (should-error
   (agent-scheme-test-fixture-validate-case
    '((id bad-phase) (kind regression) (phase compile)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (source "1")
      (expect (value "1")) (description "bad phase")))
   :type 'ert-test-failed)
  (should-error
   (agent-scheme-test-fixture-validate-case
    '((id bad-expect) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (source "1")
      (expect (value 1)) (description "bad expect")))
   :type 'ert-test-failed)
  (should-error
   (agent-scheme-test-fixture-validate-case
    '((id bad-oracle-metadata) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (oracle-eligibility surprise)
      (oracle-reason agent-specific) (options ()) (source "1")
      (expect (value "1")) (description "bad oracle metadata")))
   :type 'ert-test-failed))

(ert-deftest agent-scheme-fixture-test-runs-reader-and-evaluator-phases ()
  "Run representative shared fixtures through their selected phase."
  (dolist (case-id '(reader-boolean-literals
                     reader-comments-read-all
                     reader-list-limit-error
                     primitive-procedure-call
                     eval-multiple-values-result))
    (agent-scheme-test-fixture-run-case
     (agent-scheme-test-fixture-case case-id))))

;;; agent-scheme-fixture-test.el ends here
