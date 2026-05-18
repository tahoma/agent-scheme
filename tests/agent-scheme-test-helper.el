;;; agent-scheme-test-helper.el --- Shared Agent Scheme test helpers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helper functions shared by Agent Scheme ERT tests.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-reader)

(defconst agent-scheme-test-fixture-kinds
  '(r7rs-conformance agent-specific regression)
  "Allowed shared fixture kind values.")

(defconst agent-scheme-test-fixture-phases
  '(read read-all expand eval eval-result error)
  "Allowed shared fixture phase values.")

(defconst agent-scheme-test-fixture-statuses
  '(pending implemented policy-gated unavailable)
  "Allowed shared fixture status values.")

(defconst agent-scheme-test-fixture-oracles
  '(shared emacs-only portable-only)
  "Allowed shared fixture oracle posture values.")

(defconst agent-scheme-test-fixture-oracle-eligibilities
  '(policy-gated not-oracle-eligible)
  "Allowed explicit fixture oracle eligibility values.")

(defconst agent-scheme-test-fixture-oracle-reasons
  '(host-policy agent-specific resource-limit agent-result-record
    implementation-dependent unspecified)
  "Allowed explicit fixture oracle eligibility reason values.")

(defconst agent-scheme-test-fixture-required-fields
  '(id kind phase category section status oracle options source expect description)
  "Required fields for one shared fixture case.")

(defun agent-scheme-test-fixture-host-datum (datum)
  "Convert Agent Scheme fixture DATUM to the host shape used by ERT."
  (cond
   ((eq datum agent-scheme-true) t)
   ((eq datum agent-scheme-false) :scheme-false)
   ((null datum) nil)
   ((agent-scheme-symbol-p datum)
    (intern (agent-scheme-symbol-name datum)))
   ((agent-scheme-number-p datum)
    (or (agent-scheme-number-value datum)
        (agent-scheme-number-lexeme datum)))
   ((or (stringp datum) (characterp datum))
    datum)
   ((agent-scheme-character-p datum)
    (agent-scheme-character-code datum))
   ((agent-scheme-bytevector-p datum)
    (append (agent-scheme-bytevector-bytes datum) nil))
   ((consp datum)
    (cons (agent-scheme-test-fixture-host-datum (car datum))
          (agent-scheme-test-fixture-host-datum (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'agent-scheme-test-fixture-host-datum
                     (append datum nil))))
   (t
    (ert-fail (format "Unsupported fixture datum: %S" datum)))))

(defun agent-scheme-test-fixture-file ()
  "Return the canonical shared fixture corpus path."
  (expand-file-name
   "fixtures/r7rs/conformance-cases.scm"
   agent-scheme--test-root))

(defun agent-scheme-test-fixture-suite ()
  "Read and return the canonical shared fixture suite datum."
  (let* ((source (with-temp-buffer
                   (insert-file-contents (agent-scheme-test-fixture-file))
                   (buffer-string)))
         (suite (agent-scheme-test-fixture-host-datum
                 (agent-scheme-read source))))
    (unless (eq (car-safe suite) 'agent-scheme-fixture-suite)
      (ert-fail "Fixture corpus must start with agent-scheme-fixture-suite"))
    suite))

(defun agent-scheme-test-fixture-field (case field)
  "Return FIELD from fixture CASE."
  (cadr (assq field case)))

(defun agent-scheme-test-fixture-cases ()
  "Return all shared fixture cases."
  (let* ((suite (agent-scheme-test-fixture-suite))
         (cases-field (assq 'cases (cdr suite))))
    (unless cases-field
      (ert-fail "Fixture corpus must include a cases field"))
    (cdr cases-field)))

(defun agent-scheme-test-fixture-case (id)
  "Return the shared fixture case named ID."
  (or (cl-find-if
       (lambda (case)
         (eq (agent-scheme-test-fixture-field case 'id) id))
       (agent-scheme-test-fixture-cases))
      (ert-fail (format "Unknown fixture case %S" id))))

(defun agent-scheme-test-fixture-validate-expectation (case)
  "Validate CASE expectation syntax."
  (let ((case-id (agent-scheme-test-fixture-field case 'id))
        (expect (agent-scheme-test-fixture-field case 'expect)))
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

(defun agent-scheme-test-fixture-validate-case (case)
  "Validate one shared fixture CASE."
  (dolist (field agent-scheme-test-fixture-required-fields)
    (unless (assq field case)
      (ert-fail (format "Fixture case missing %S: %S" field case))))
  (let ((case-id (agent-scheme-test-fixture-field case 'id))
        (kind (agent-scheme-test-fixture-field case 'kind))
        (phase (agent-scheme-test-fixture-field case 'phase))
        (section (agent-scheme-test-fixture-field case 'section))
        (status (agent-scheme-test-fixture-field case 'status))
        (oracle (agent-scheme-test-fixture-field case 'oracle))
        (oracle-eligibility
         (agent-scheme-test-fixture-field case 'oracle-eligibility))
        (oracle-reason
         (agent-scheme-test-fixture-field case 'oracle-reason))
        (options (agent-scheme-test-fixture-field case 'options))
        (description (agent-scheme-test-fixture-field case 'description))
        (source (agent-scheme-test-fixture-field case 'source)))
    (should (symbolp case-id))
    (should (memq kind agent-scheme-test-fixture-kinds))
    (should (memq phase agent-scheme-test-fixture-phases))
    (should (stringp section))
    (should (memq status agent-scheme-test-fixture-statuses))
    (should (memq oracle agent-scheme-test-fixture-oracles))
    (should (listp options))
    (should (stringp description))
    (should (> (length description) 0))
    (should (stringp source))
    (should (> (length source) 0))
    (when (or oracle-eligibility oracle-reason)
      (should (memq oracle-eligibility
                    agent-scheme-test-fixture-oracle-eligibilities))
      (should (memq oracle-reason
                    agent-scheme-test-fixture-oracle-reasons)))
    (agent-scheme-test-fixture-validate-expectation case)))

(defun agent-scheme-test-fixture-validate-suite (suite)
  "Validate the shared fixture SUITE."
  (unless (eq (car-safe suite) 'agent-scheme-fixture-suite)
    (ert-fail "Fixture corpus must start with agent-scheme-fixture-suite"))
  (let ((cases-field (assq 'cases (cdr suite)))
        (ids nil))
    (unless cases-field
      (ert-fail "Fixture corpus must include a cases field"))
    (dolist (case (cdr cases-field))
      (agent-scheme-test-fixture-validate-case case)
      (let ((case-id (agent-scheme-test-fixture-field case 'id)))
        (when (memq case-id ids)
          (ert-fail (format "Duplicate fixture id: %S" case-id)))
        (push case-id ids)))))

(defun agent-scheme-test-fixture-options-plist (case)
  "Return CASE options as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (agent-scheme-test-fixture-field case 'options))
      (unless (and (listp entry)
                   (symbolp (car entry))
                   (= (length entry) 2))
        (ert-fail
         (format "Invalid options entry for fixture %S: %S"
                 (agent-scheme-test-fixture-field case 'id)
                 entry)))
      (setq plist
            (plist-put plist
                       (intern (concat ":" (symbol-name (car entry))))
                       (cadr entry))))
    plist))

(defun agent-scheme-test-fixture--eval-actual (value)
  "Return an expectation plist for evaluated VALUE."
  (if (agent-scheme--multiple-values-p value)
      (list :status 'values
            :values
            (mapcar #'agent-scheme-value->external
                    (agent-scheme--multiple-values-values value)))
    (list :status 'value
          :value (agent-scheme-value->external value))))

(defun agent-scheme-test-fixture-actual (case)
  "Run CASE and return a normalized actual result plist."
  (let ((phase (agent-scheme-test-fixture-field case 'phase))
        (source (agent-scheme-test-fixture-field case 'source))
        (options (agent-scheme-test-fixture-options-plist case)))
    (condition-case condition
        (pcase phase
          ('read
           (list :status 'value
                 :value
                 (agent-scheme-datum->external
                  (agent-scheme-read source options))))
          ('read-all
           (list :status 'values
                 :values
                 (mapcar #'agent-scheme-datum->external
                         (agent-scheme-read-all source options))))
          ('expand
           (list :status 'values
                 :values
                 (mapcar #'agent-scheme-datum->external
                         (agent-scheme-expand-source source nil options))))
          ('eval
           (agent-scheme-test-fixture--eval-actual
            (agent-scheme-eval-source source nil options)))
          ('eval-result
           (list :status 'result
                 :value
                 (agent-scheme-result->external
                  (agent-scheme-eval-source-result source nil options))))
          ('error
           (agent-scheme-test-fixture--eval-actual
            (agent-scheme-eval-source source nil options)))
          (_
           (ert-fail (format "Unsupported fixture phase: %S" phase))))
      (error
       (list :status 'error :condition condition)))))

(defun agent-scheme-test-fixture-actual-matches-p (expect actual)
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

(defun agent-scheme-test-fixture-run-case (case)
  "Run one implemented shared fixture CASE."
  (let ((expect (agent-scheme-test-fixture-field case 'expect))
        (actual (agent-scheme-test-fixture-actual case)))
    (unless (agent-scheme-test-fixture-actual-matches-p expect actual)
      (ert-fail
       (format "Fixture case %S expected %S, got %S"
               (agent-scheme-test-fixture-field case 'id)
               expect
               actual)))))

(provide 'agent-scheme-test-helper)

;;; agent-scheme-test-helper.el ends here
