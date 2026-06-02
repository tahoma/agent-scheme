;;; consent-test-helper.el --- Shared Consent Scheme test helpers  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Helper functions shared by Consent Scheme ERT tests.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'consent-eval)
(require 'consent-reader)

(defconst consent-test-fixture-kinds
  '(r7rs-conformance agent-specific regression)
  "Allowed shared fixture kind values.")

(defconst consent-test-fixture-phases
  '(read read-all expand eval eval-result error)
  "Allowed shared fixture phase values.")

(defconst consent-test-fixture-statuses
  '(pending implemented policy-gated unavailable)
  "Allowed shared fixture status values.")

(defconst consent-test-fixture-oracles
  '(shared emacs-only portable-only)
  "Allowed shared fixture oracle posture values.")

(defconst consent-test-fixture-oracle-eligibilities
  '(policy-gated not-oracle-eligible)
  "Allowed explicit fixture oracle eligibility values.")

(defconst consent-test-fixture-oracle-reasons
  '(host-policy agent-specific resource-limit agent-result-record
    implementation-dependent unspecified)
  "Allowed explicit fixture oracle eligibility reason values.")

(defconst consent-test-fixture-required-fields
  '(id kind phase category section status oracle options source expect description)
  "Required fields for one shared fixture case.")

(defun consent-test-fixture-host-datum (datum)
  "Convert Consent Scheme fixture DATUM to the host shape used by ERT."
  (cond
   ((eq datum consent-true) t)
   ((eq datum consent-false) :scheme-false)
   ((null datum) nil)
   ((consent-symbol-p datum)
    (intern (consent-symbol-name datum)))
   ((consent-number-p datum)
    (or (consent-number-value datum)
        (consent-number-lexeme datum)))
   ((or (stringp datum) (characterp datum))
    datum)
   ((consent-character-p datum)
    (consent-character-code datum))
   ((consent-bytevector-p datum)
    (append (consent-bytevector-bytes datum) nil))
   ((consp datum)
    (cons (consent-test-fixture-host-datum (car datum))
          (consent-test-fixture-host-datum (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'consent-test-fixture-host-datum
                     (append datum nil))))
   (t
    (ert-fail (format "Unsupported fixture datum: %S" datum)))))

(defun consent-test-fixture-file ()
  "Return the canonical shared fixture corpus path."
  (expand-file-name
   "fixtures/r7rs/conformance-cases.scm"
   consent--test-root))

(defun consent-test-fixture-suite ()
  "Read and return the canonical shared fixture suite datum."
  (let* ((source (with-temp-buffer
                   (insert-file-contents (consent-test-fixture-file))
                   (buffer-string)))
         (suite (consent-test-fixture-host-datum
                 (consent-read source))))
    (unless (eq (car-safe suite) 'consent-fixture-suite)
      (ert-fail "Fixture corpus must start with consent-fixture-suite"))
    suite))

(defun consent-test-fixture-field (case field)
  "Return FIELD from fixture CASE."
  (cadr (assq field case)))

(defun consent-test-fixture-cases ()
  "Return all shared fixture cases."
  (let* ((suite (consent-test-fixture-suite))
         (cases-field (assq 'cases (cdr suite))))
    (unless cases-field
      (ert-fail "Fixture corpus must include a cases field"))
    (cdr cases-field)))

(defun consent-test-fixture-case (id)
  "Return the shared fixture case named ID."
  (or (cl-find-if
       (lambda (case)
         (eq (consent-test-fixture-field case 'id) id))
       (consent-test-fixture-cases))
      (ert-fail (format "Unknown fixture case %S" id))))

(defun consent-test-fixture-validate-expectation (case)
  "Validate CASE expectation syntax."
  (let ((case-id (consent-test-fixture-field case 'id))
        (expect (consent-test-fixture-field case 'expect)))
    (pcase expect
      (`(value ,value)
       (should (stringp value)))
      (`(values ,values)
       (should (and (listp values) (cl-every #'stringp values))))
      (`(result ,value)
       (should (stringp value)))
      (`(error . ,_)
       t)
      (_
       (ert-fail
        (format "Invalid expectation for fixture case %S: %S"
                case-id expect))))))

(defun consent-test-fixture-validate-case (case)
  "Validate one shared fixture CASE."
  (dolist (field consent-test-fixture-required-fields)
    (unless (assq field case)
      (ert-fail (format "Fixture case missing %S: %S" field case))))
  (let ((case-id (consent-test-fixture-field case 'id))
        (kind (consent-test-fixture-field case 'kind))
        (phase (consent-test-fixture-field case 'phase))
        (section (consent-test-fixture-field case 'section))
        (status (consent-test-fixture-field case 'status))
        (oracle (consent-test-fixture-field case 'oracle))
        (oracle-eligibility
         (consent-test-fixture-field case 'oracle-eligibility))
        (oracle-reason
         (consent-test-fixture-field case 'oracle-reason))
        (options (consent-test-fixture-field case 'options))
        (description (consent-test-fixture-field case 'description))
        (source (consent-test-fixture-field case 'source)))
    (should (symbolp case-id))
    (should (memq kind consent-test-fixture-kinds))
    (should (memq phase consent-test-fixture-phases))
    (should (stringp section))
    (should (memq status consent-test-fixture-statuses))
    (should (memq oracle consent-test-fixture-oracles))
    (should (listp options))
    (should (stringp description))
    (should (> (length description) 0))
    (should (stringp source))
    (should (> (length source) 0))
    (when (or oracle-eligibility oracle-reason)
      (should (memq oracle-eligibility
                    consent-test-fixture-oracle-eligibilities))
      (should (memq oracle-reason
                    consent-test-fixture-oracle-reasons)))
    (consent-test-fixture-validate-expectation case)))

(defun consent-test-fixture-validate-suite (suite)
  "Validate the shared fixture SUITE."
  (unless (eq (car-safe suite) 'consent-fixture-suite)
    (ert-fail "Fixture corpus must start with consent-fixture-suite"))
  (let ((cases-field (assq 'cases (cdr suite)))
        (ids nil))
    (unless cases-field
      (ert-fail "Fixture corpus must include a cases field"))
    (dolist (case (cdr cases-field))
      (consent-test-fixture-validate-case case)
      (let ((case-id (consent-test-fixture-field case 'id)))
        (when (memq case-id ids)
          (ert-fail (format "Duplicate fixture id: %S" case-id)))
        (push case-id ids)))))

(defun consent-test-fixture-options-plist (case)
  "Return CASE options as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (consent-test-fixture-field case 'options))
      (unless (and (listp entry)
                   (symbolp (car entry))
                   (= (length entry) 2))
        (ert-fail
         (format "Invalid options entry for fixture %S: %S"
                 (consent-test-fixture-field case 'id)
                 entry)))
      (setq plist
            (plist-put plist
                       (intern (concat ":" (symbol-name (car entry))))
                       (cadr entry))))
    plist))

(defun consent-test-fixture--eval-actual (value)
  "Return an expectation plist for evaluated VALUE."
  (if (consent--multiple-values-p value)
      (list :status 'values
            :values
            (mapcar #'consent-value->external
                    (consent--multiple-values-values value)))
    (list :status 'value
          :value (consent-value->external value))))

(defun consent-test-fixture-actual (case)
  "Run CASE and return a normalized actual result plist."
  (let ((phase (consent-test-fixture-field case 'phase))
        (source (consent-test-fixture-field case 'source))
        (options (consent-test-fixture-options-plist case)))
    (condition-case condition
        (pcase phase
          ('read
           (list :status 'value
                 :value
                 (consent-datum->external
                  (consent-read source options))))
          ('read-all
           (list :status 'values
                 :values
                 (mapcar #'consent-datum->external
                         (consent-read-all source options))))
          ('expand
           (list :status 'values
                 :values
                 (mapcar #'consent-datum->external
                         (consent-expand-source source nil options))))
          ('eval
           (consent-test-fixture--eval-actual
            (consent-eval-source source nil options)))
          ('eval-result
           (list :status 'result
                 :value
                 (consent-result->external
                  (consent-eval-source-result source nil options))))
          ('error
           (consent-test-fixture--eval-actual
            (consent-eval-source source nil options)))
          (_
           (ert-fail (format "Unsupported fixture phase: %S" phase))))
      (error
       (list :status 'error :condition condition)))))

(defun consent-test-fixture-actual-matches-p (expect actual)
  "Return non-nil when ACTUAL satisfies EXPECT."
  (pcase expect
    (`(value ,value)
     (and (eq (plist-get actual :status) 'value)
          (equal (plist-get actual :value) value)))
    (`(values ,values)
     (and (eq (plist-get actual :status) 'values)
          (equal (plist-get actual :values) values)))
    (`(result ,value)
     (and (eq (plist-get actual :status) 'result)
          (equal (plist-get actual :value) value)))
    (`(error . ,_)
     (eq (plist-get actual :status) 'error))
    (_ nil)))

(defun consent-test-fixture-run-case (case)
  "Run one implemented shared fixture CASE."
  (let ((expect (consent-test-fixture-field case 'expect))
        (actual (consent-test-fixture-actual case)))
    (unless (consent-test-fixture-actual-matches-p expect actual)
      (ert-fail
       (format "Fixture case %S expected %S, got %S"
               (consent-test-fixture-field case 'id)
               expect
               actual)))))

(provide 'consent-test-helper)

;;; consent-test-helper.el ends here
