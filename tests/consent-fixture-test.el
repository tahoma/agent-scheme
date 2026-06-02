;;; consent-fixture-test.el --- Shared fixture corpus tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for the shared Scheme-readable fixture corpus used by reader,
;; evaluator, portable Scheme, and conformance runners.

;;; Code:

(require 'ert)
(require 'consent-test-helper)

(ert-deftest consent-fixture-test-suite-is-canonical ()
  "Load the canonical fixture suite and validate fixture shape."
  (let ((suite (consent-test-fixture-suite)))
    (should (eq (car-safe suite) 'consent-fixture-suite))
    (should (consent-test-fixture-cases))
    (consent-test-fixture-validate-suite suite)))

(ert-deftest consent-fixture-test-validation-rejects-bad-shapes ()
  "Reject duplicate ids, missing fields, unsupported phases, and bad expects."
  (should-error
   (consent-test-fixture-validate-suite
    '(consent-fixture-suite
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
   (consent-test-fixture-validate-case
    '((id missing-source) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (expect (value "1"))
      (description "missing source")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id bad-phase) (kind regression) (phase compile)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (source "1")
      (expect (value "1")) (description "bad phase")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id bad-expect) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (source "1")
      (expect (value 1)) (description "bad expect")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id bad-oracle-metadata) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (oracle-eligibility surprise)
      (oracle-reason agent-specific) (options ()) (source "1")
      (expect (value "1")) (description "bad oracle metadata")))
   :type 'ert-test-failed))

(ert-deftest consent-fixture-test-runs-reader-and-evaluator-phases ()
  "Run representative shared fixtures through their selected phase."
  (dolist (case-id '(reader-boolean-literals
                     reader-comments-read-all
                     reader-list-limit-error
                     primitive-procedure-call
                     eval-multiple-values-result))
    (consent-test-fixture-run-case
     (consent-test-fixture-case case-id))))

;;; consent-fixture-test.el ends here
