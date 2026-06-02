;;; agent-scheme-conformance-test.el --- R7RS conformance fixture tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Bootstrap tests for the R7RS-small conformance slice of the shared fixture
;; corpus. Pending cases are loaded and validated now; cases become executable
;; by changing their status to `implemented' once the runtime can evaluate them.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'agent-scheme-test-helper)

(defconst agent-scheme--conformance-categories
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

(defvar agent-scheme-conformance-evaluator nil
  "Function used to evaluate implemented R7RS conformance cases.

The function receives one Scheme source string and returns a plist:

  (:status value :value PRINTED-VALUE)
  (:status values :values (PRINTED-VALUE ...))
  (:status error :condition CONDITION)

PRINTED-VALUE strings should use Agent Scheme's stable writer.")

(defun agent-scheme--conformance-matrix-file ()
  "Return the R7RS conformance matrix file path."
  (expand-file-name "docs/r7rs-conformance.md" agent-scheme--test-root))

(defun agent-scheme--conformance-field (case field)
  "Return FIELD from conformance CASE."
  (agent-scheme-test-fixture-field case field))

(defun agent-scheme--conformance-suite-cases ()
  "Return R7RS conformance cases from the shared fixture corpus."
  (cl-remove-if-not
   (lambda (case)
     (eq (agent-scheme-test-fixture-field case 'kind) 'r7rs-conformance))
   (agent-scheme-test-fixture-cases)))

(defun agent-scheme--conformance-validate-case (case)
  "Validate one R7RS conformance CASE."
  (agent-scheme-test-fixture-validate-case case)
  (should (memq (agent-scheme--conformance-field case 'category)
                agent-scheme--conformance-categories)))

(defun agent-scheme--conformance-actual-matches-p (expect actual)
  "Return non-nil when ACTUAL satisfies EXPECT."
  (agent-scheme-test-fixture-actual-matches-p expect actual))

(defun agent-scheme--conformance-run-case (case)
  "Run one implemented R7RS conformance CASE."
  (if (and agent-scheme-conformance-evaluator
           (eq (agent-scheme--conformance-field case 'phase) 'eval))
      (let* ((source (agent-scheme--conformance-field case 'source))
             (expect (agent-scheme--conformance-field case 'expect))
             (actual (funcall agent-scheme-conformance-evaluator source)))
        (unless (agent-scheme--conformance-actual-matches-p expect actual)
          (ert-fail
           (format "Conformance case %S expected %S, got %S"
                   (agent-scheme--conformance-field case 'id)
                   expect
                   actual))))
    (agent-scheme-test-fixture-run-case case)))

(ert-deftest agent-scheme-conformance-test-fixture-suite-is-valid ()
  "Validate the R7RS conformance fixture slice."
  (let ((cases (agent-scheme--conformance-suite-cases))
        (categories nil))
    (agent-scheme-test-fixture-validate-suite
     (agent-scheme-test-fixture-suite))
    (should cases)
    (dolist (case cases)
      (agent-scheme--conformance-validate-case case)
      (cl-pushnew (agent-scheme--conformance-field case 'category)
                  categories))
    (dolist (category agent-scheme--conformance-categories)
      (should (memq category categories)))))

(ert-deftest agent-scheme-conformance-test-matrix-documents-fixtures ()
  "Ensure the visible matrix names every R7RS conformance fixture case."
  (let ((matrix (with-temp-buffer
                  (insert-file-contents
                   (agent-scheme--conformance-matrix-file))
                  (buffer-string))))
    (dolist (case (agent-scheme--conformance-suite-cases))
      (should
       (string-match-p
        (regexp-quote
         (symbol-name (agent-scheme--conformance-field case 'id)))
        matrix)))))

(ert-deftest agent-scheme-conformance-test-non-implemented-cases-are-discoverable ()
  "Confirm non-implemented cases are present without failing prematurely."
  (let ((not-yet-implemented
         (cl-remove-if
          (lambda (case)
            (eq (agent-scheme--conformance-field case 'status) 'implemented))
          (agent-scheme--conformance-suite-cases))))
    (should not-yet-implemented)
    (should
     (cl-some
      (lambda (case)
        (eq (agent-scheme--conformance-field case 'status) 'policy-gated))
      not-yet-implemented))))

(ert-deftest agent-scheme-conformance-test-expectation-comparison ()
  "Cover value, multiple-value, result, and error expectation comparison."
  (should
   (agent-scheme--conformance-actual-matches-p
    '(value "3")
    '(:status value :value "3")))
  (should
   (agent-scheme--conformance-actual-matches-p
    '(values ("1" "2"))
    '(:status values :values ("1" "2"))))
  (should
   (agent-scheme--conformance-actual-matches-p
    '(result "(evaluation-result (status ok) (value 3))")
    '(:status result :value "(evaluation-result (status ok) (value 3))")))
  (should
   (agent-scheme--conformance-actual-matches-p
    '(error)
    '(:status error :condition boom)))
  (should-not
   (agent-scheme--conformance-actual-matches-p
    '(value "3")
    '(:status value :value "4"))))

(ert-deftest agent-scheme-conformance-test-runner-invokes-evaluator ()
  "Confirm the fixture runner passes Scheme source to a custom evaluator."
  (let ((agent-scheme-conformance-evaluator
         (lambda (source)
           (should (equal source "(+ 1 2)"))
           '(:status value :value "3"))))
    (agent-scheme--conformance-run-case
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

(ert-deftest agent-scheme-conformance-test-implemented-cases-run ()
  "Run cases marked implemented through the registered fixture runner."
  (dolist (case (agent-scheme--conformance-suite-cases))
    (when (eq (agent-scheme--conformance-field case 'status) 'implemented)
      (agent-scheme--conformance-run-case case))))

;;; agent-scheme-conformance-test.el ends here
