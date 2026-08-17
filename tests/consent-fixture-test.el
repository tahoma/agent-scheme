;;; consent-fixture-test.el -*- lexical-binding: t; -*-
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

(ert-deftest consent-fixture-test-preserves-migrated-inventory ()
  "Pin the case, phase, and typed-expectation inventory."
  (let* ((cases (consent-test-fixture-cases))
         (phases
          (mapcar
           (lambda (case)
             (consent-test-fixture-field case 'phase))
           cases))
         (expectation-types
          (mapcar
           (lambda (case)
             (car (consent-test-fixture-field case 'expect)))
           cases)))
    (should (= (length cases) 170))
    (should (= (cl-count 'eval phases) 140))
    (should (= (cl-count 'eval-result phases) 1))
    (should (= (cl-count 'read phases) 28))
    (should (= (cl-count 'read-all phases) 1))
    (should (= (cl-count 'value expectation-types) 130))
    (should (= (cl-count 'serialized-value expectation-types) 1))
    (should (= (cl-count 'values expectation-types) 2))
    (should (= (cl-count 'condition expectation-types) 36))
    (should (= (cl-count 'result expectation-types) 1))))

(ert-deftest consent-fixture-test-validation-rejects-bad-shapes ()
  "Reject duplicate ids, missing fields, unsupported phases, and bad expects."
  (should-error
   (consent-test-fixture-validate-suite
    '(consent-fixture-suite
      (version 2)
      (cases
        ((id duplicate) (kind regression) (phase read)
         (category reader-syntax) (section "2") (status implemented)
         (oracle shared) (options ()) (source (text "1"))
         (expect (value 1)) (description "first"))
        ((id duplicate) (kind regression) (phase read)
         (category reader-syntax) (section "2") (status implemented)
         (oracle shared) (options ()) (source (text "2"))
         (expect (value 2)) (description "second")))))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id missing-source) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (expect (value 1))
      (description "missing source")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id bad-phase) (kind regression) (phase compile)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (source (form (+ 1 2)))
      (expect (value 3)) (description "bad phase")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id bad-expect) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (options ()) (source (text "1"))
      (expect (external-text 1)) (description "bad expect")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id bad-oracle-metadata) (kind regression) (phase read)
      (category reader-syntax) (section "2") (status implemented)
      (oracle shared) (oracle-eligibility surprise)
      (oracle-reason agent-specific) (options ())
      (source (text "1"))
      (expect (value 1)) (description "bad oracle metadata")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id opaque-program) (kind regression) (phase eval)
      (category evaluator) (section "test") (status implemented)
      (oracle shared) (options ())
      (source (text "(+ 1 2)"))
      (expect (value 3)) (description "opaque program")))
   :type 'ert-test-failed)
  (should-error
   (consent-test-fixture-validate-case
    '((id escaping-file) (kind regression) (phase eval)
      (category evaluator) (section "test") (status implemented)
      (oracle shared) (options ())
      (source (file "../outside.scm"))
      (expect (value 3)) (description "escaping file")))
   :type 'ert-test-failed))

(ert-deftest consent-fixture-test-retains-typed-structured-datums ()
  "Load host-reader-incompatible values without erasing their types."
  (let* ((case
          (consent-test-fixture-case 'reader-bytevector-literal))
         (expect (consent-test-fixture-field case 'expect)))
    (should (eq (car expect) 'value))
    (should (consent-bytevector-p (cadr expect)))))

(ert-deftest consent-fixture-test-materializes-structured-source ()
  "Materialize forms and exact writer data only at named boundaries."
  (should
   (equal
    (consent-test-fixture-source-text
     (list
      (list
       'source
       (list 'form (consent-read "(+ 1 2)")))))
    "(+ 1 2)\n"))
  (should
   (equal
    (consent-test-fixture-source-text
     (list
      (list
       'source
       (list
        'forms
        (consent-read "(define x 1)")
        (consent-read "(+ x 2)")))))
    "(define x 1)\n(+ x 2)\n"))
  (should
   (consent-test-fixture-actual-matches-p
    '(external-text "#(1 \"x\")")
    (consent-test-fixture-actual
     (list
      '(phase write)
      '(options ())
      (list
       'source
       (list 'form (consent-read "#(1 \"x\")"))))))))

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
