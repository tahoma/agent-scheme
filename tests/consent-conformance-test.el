;;; consent-conformance-test.el --- R7RS conformance fixture tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Bootstrap tests for the R7RS-small conformance slice of the shared fixture
;; corpus. Pending cases are loaded and validated now; cases become executable
;; by changing their status to `implemented' once the runtime can evaluate them.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'consent-test-helper)

(defconst consent--conformance-categories
  '(reader-syntax
    primitive-expressions
    derived-syntax
    syntax-rules
    libraries
    proper-tail-recursion
    multiple-values
    exceptions
    continuations
    equivalence
    core-data-types
    numeric-tower
    standard-libraries)
  "Required R7RS conformance fixture categories.")

(defvar consent-conformance-evaluator nil
  "Function used to evaluate implemented R7RS conformance cases.

The function receives one Scheme source string and returns a plist:

  (:status value :value PRINTED-VALUE)
  (:status values :values (PRINTED-VALUE ...))
  (:status error :condition CONDITION)

PRINTED-VALUE strings should use Consent Scheme's stable writer.")

(defun consent--conformance-matrix-file ()
  "Return the R7RS conformance matrix file path."
  (expand-file-name "docs/r7rs-conformance.md" consent--test-root))

(defun consent--conformance-field (case field)
  "Return FIELD from conformance CASE."
  (consent-test-fixture-field case field))

(defun consent--conformance-suite-cases ()
  "Return R7RS conformance cases from the shared fixture corpus."
  (cl-remove-if-not
   (lambda (case)
     (eq (consent-test-fixture-field case 'kind) 'r7rs-conformance))
   (consent-test-fixture-cases)))

(defun consent--conformance-validate-case (case)
  "Validate one R7RS conformance CASE."
  (consent-test-fixture-validate-case case)
  (should (memq (consent--conformance-field case 'category)
                consent--conformance-categories)))

(defun consent--conformance-actual-matches-p (expect actual)
  "Return non-nil when ACTUAL satisfies EXPECT."
  (consent-test-fixture-actual-matches-p expect actual))

(defun consent--conformance-run-case (case)
  "Run one implemented R7RS conformance CASE."
  (if (and consent-conformance-evaluator
           (eq (consent--conformance-field case 'phase) 'eval))
      (let* ((source (consent--conformance-field case 'source))
             (expect (consent--conformance-field case 'expect))
             (actual (funcall consent-conformance-evaluator source)))
        (unless (consent--conformance-actual-matches-p expect actual)
          (ert-fail
           (format "Conformance case %S expected %S, got %S"
                   (consent--conformance-field case 'id)
                   expect
                   actual))))
    (consent-test-fixture-run-case case)))

(ert-deftest consent-conformance-test-fixture-suite-is-valid ()
  "Validate the R7RS conformance fixture slice."
  (let ((cases (consent--conformance-suite-cases))
        (categories nil))
    (consent-test-fixture-validate-suite
     (consent-test-fixture-suite))
    (should cases)
    (dolist (case cases)
      (consent--conformance-validate-case case)
      (cl-pushnew (consent--conformance-field case 'category)
                  categories))
    (dolist (category consent--conformance-categories)
      (should (memq category categories)))))

(ert-deftest consent-conformance-test-matrix-documents-fixtures ()
  "Ensure the visible matrix names every R7RS conformance fixture case."
  (let ((matrix (with-temp-buffer
                  (insert-file-contents
                   (consent--conformance-matrix-file))
                  (buffer-string))))
    (dolist (case (consent--conformance-suite-cases))
      (should
       (string-match-p
        (regexp-quote
         (symbol-name (consent--conformance-field case 'id)))
        matrix)))))

(ert-deftest consent-conformance-test-non-implemented-cases-are-discoverable ()
  "Confirm non-implemented cases are present without failing prematurely."
  (let ((not-yet-implemented
         (cl-remove-if
          (lambda (case)
            (eq (consent--conformance-field case 'status) 'implemented))
          (consent--conformance-suite-cases))))
    (should not-yet-implemented)
    (should
     (cl-some
      (lambda (case)
        (eq (consent--conformance-field case 'status) 'policy-gated))
      not-yet-implemented))))

(ert-deftest consent-conformance-test-expectation-comparison ()
  "Cover value, multiple-value, result, and error expectation comparison."
  (should
   (consent--conformance-actual-matches-p
    '(value "3")
    '(:status value :value "3")))
  (should
   (consent--conformance-actual-matches-p
    '(values ("1" "2"))
    '(:status values :values ("1" "2"))))
  (should
   (consent--conformance-actual-matches-p
    '(result "(evaluation-result (status ok) (value 3))")
    '(:status result :value "(evaluation-result (status ok) (value 3))")))
  (should
   (consent--conformance-actual-matches-p
    '(error)
    '(:status error :condition boom)))
  (should-not
   (consent--conformance-actual-matches-p
    '(value "3")
    '(:status value :value "4"))))

(ert-deftest consent-conformance-test-runner-invokes-evaluator ()
  "Confirm the fixture runner passes Scheme source to a custom evaluator."
  (let ((consent-conformance-evaluator
         (lambda (source)
           (should (equal source "(+ 1 2)"))
           '(:status value :value "3"))))
    (consent--conformance-run-case
     '((id runner-demo)
       (kind r7rs-conformance)
       (phase eval)
       (category primitive-expressions)
       (section "4.1")
       (status implemented)
       (oracle shared)
       (options ())
       (source "(+ 1 2)")
       (expect (value "3"))
       (description "Synthetic conformance runner case.")))))

(ert-deftest consent-conformance-test-implemented-cases-run ()
  "Run cases marked implemented through the registered fixture runner."
  (dolist (case (consent--conformance-suite-cases))
    (when (eq (consent--conformance-field case 'status) 'implemented)
      (consent--conformance-run-case case))))

;;; consent-conformance-test.el ends here
