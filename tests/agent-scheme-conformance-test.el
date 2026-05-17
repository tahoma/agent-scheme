;;; agent-scheme-conformance-test.el --- R7RS conformance fixture tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Bootstrap tests for the R7RS-small conformance fixture suite. Pending cases
;; are loaded and validated now; cases become executable by changing their
;; status to `implemented' once the runtime can evaluate them.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-reader)

(defconst agent-scheme--conformance-statuses
  '(pending implemented policy-gated unavailable)
  "Allowed R7RS conformance fixture statuses.")

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
    core-data-types
    standard-libraries)
  "Required R7RS conformance fixture categories.")

(defvar agent-scheme-conformance-evaluator nil
  "Function used to evaluate implemented R7RS conformance cases.

The function receives one Scheme source string and returns a plist:

  (:status value :value PRINTED-VALUE)
  (:status values :values (PRINTED-VALUE ...))
  (:status error :condition CONDITION)

PRINTED-VALUE strings should use Agent Scheme's stable writer.")

(defun agent-scheme--conformance-reader-evaluator (source)
  "Read SOURCE as one datum and return a conformance result plist."
  (condition-case condition
      (let ((datums (agent-scheme-read-all source)))
        (if (= (length datums) 1)
            (list :status 'value
                  :value (agent-scheme-datum->external (car datums)))
          (list :status 'values
                :values (mapcar #'agent-scheme-datum->external datums))))
    (agent-scheme-reader-error
     (list :status 'error :condition condition))))

(defun agent-scheme--conformance-eval-evaluator (source)
  "Evaluate SOURCE and return a conformance result plist."
  (condition-case condition
      (let ((value (agent-scheme-eval-source source)))
        (if (agent-scheme--multiple-values-p value)
            (list :status 'values
                  :values
                  (mapcar #'agent-scheme-value->external
                          (agent-scheme--multiple-values-values value)))
          (list :status 'value
                :value (agent-scheme-value->external value))))
    (agent-scheme-eval-error
     (list :status 'error :condition condition))))

(defun agent-scheme--conformance-host-datum (datum)
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
    (cons (agent-scheme--conformance-host-datum (car datum))
          (agent-scheme--conformance-host-datum (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'agent-scheme--conformance-host-datum
                     (append datum nil))))
   (t
    (ert-fail (format "Unsupported fixture datum: %S" datum)))))

(defun agent-scheme--conformance-fixture-file ()
  "Return the R7RS conformance fixture file path."
  (expand-file-name
   "fixtures/r7rs/conformance-cases.scm"
   agent-scheme--test-root))

(defun agent-scheme--conformance-matrix-file ()
  "Return the R7RS conformance matrix file path."
  (expand-file-name "docs/r7rs-conformance.md" agent-scheme--test-root))

(defun agent-scheme--conformance-read-suite ()
  "Read and return the R7RS conformance suite datum."
  (let* ((source (with-temp-buffer
                   (insert-file-contents (agent-scheme--conformance-fixture-file))
                   (buffer-string)))
         (suite (agent-scheme--conformance-host-datum
                 (agent-scheme-read source))))
    (unless (eq (car-safe suite) 'r7rs-conformance-suite)
      (ert-fail "Conformance fixture must start with r7rs-conformance-suite"))
    suite))

(defun agent-scheme--conformance-suite-cases ()
  "Return conformance fixture cases."
  (let* ((suite (agent-scheme--conformance-read-suite))
         (cases-field (assq 'cases (cdr suite))))
    (unless cases-field
      (ert-fail "Conformance fixture must include a cases field"))
    (cdr cases-field)))

(defun agent-scheme--conformance-field (case field)
  "Return FIELD from CASE."
  (cadr (assq field case)))

(defun agent-scheme--conformance-validate-expectation (case)
  "Validate CASE expectation syntax."
  (let ((case-id (agent-scheme--conformance-field case 'id))
        (expect (agent-scheme--conformance-field case 'expect)))
    (pcase expect
      (`(value ,value)
       (should (stringp value)))
      (`(values ,values)
       (should (and (listp values) (cl-every #'stringp values))))
      (`(error . ,_)
       t)
      (_
       (ert-fail
        (format "Invalid expectation for conformance case %S: %S"
                case-id expect))))))

(defun agent-scheme--conformance-validate-case (case)
  "Validate one conformance CASE."
  (let ((case-id (agent-scheme--conformance-field case 'id))
        (category (agent-scheme--conformance-field case 'category))
        (section (agent-scheme--conformance-field case 'section))
        (status (agent-scheme--conformance-field case 'status))
        (description (agent-scheme--conformance-field case 'description))
        (source (agent-scheme--conformance-field case 'source)))
    (should (symbolp case-id))
    (should (memq category agent-scheme--conformance-categories))
    (should (stringp section))
    (should (memq status agent-scheme--conformance-statuses))
    (should (stringp description))
    (should (> (length description) 0))
    (should (stringp source))
    (should (> (length source) 0))
    (agent-scheme--conformance-validate-expectation case)))

(defun agent-scheme--conformance-actual-matches-p (expect actual)
  "Return non-nil when ACTUAL satisfies EXPECT.
ACTUAL is the plist returned by `agent-scheme-conformance-evaluator'."
  (pcase expect
    (`(value ,value)
     (and (eq (plist-get actual :status) 'value)
          (equal (plist-get actual :value) value)))
    (`(values ,values)
     (and (eq (plist-get actual :status) 'values)
          (equal (plist-get actual :values) values)))
    (`(error . ,_)
     (eq (plist-get actual :status) 'error))
    (_ nil)))

(defun agent-scheme--conformance-run-case (case)
  "Run one implemented conformance CASE."
  (let* ((category (agent-scheme--conformance-field case 'category))
         (evaluator
          (cond
           ((eq category 'reader-syntax)
            #'agent-scheme--conformance-reader-evaluator)
           (agent-scheme-conformance-evaluator)
           (t
            #'agent-scheme--conformance-eval-evaluator))))
    (unless (functionp evaluator)
      (ert-fail
       (format "No Agent Scheme evaluator is registered for implemented case %S"
               (agent-scheme--conformance-field case 'id))))
    (let* ((source (agent-scheme--conformance-field case 'source))
           (expect (agent-scheme--conformance-field case 'expect))
           (actual (funcall evaluator source)))
      (unless (agent-scheme--conformance-actual-matches-p expect actual)
        (ert-fail
         (format "Conformance case %S expected %S, got %S"
                 (agent-scheme--conformance-field case 'id)
                 expect
                 actual))))))

(ert-deftest agent-scheme-conformance-test-fixture-suite-is-valid ()
  "Validate the R7RS conformance fixture suite shape."
  (let ((cases (agent-scheme--conformance-suite-cases))
        (ids nil)
        (categories nil))
    (should cases)
    (dolist (case cases)
      (agent-scheme--conformance-validate-case case)
      (let ((case-id (agent-scheme--conformance-field case 'id)))
        (should-not (memq case-id ids))
        (push case-id ids))
      (cl-pushnew (agent-scheme--conformance-field case 'category)
                  categories))
    (dolist (category agent-scheme--conformance-categories)
      (should (memq category categories)))))

(ert-deftest agent-scheme-conformance-test-matrix-documents-fixtures ()
  "Ensure the visible matrix names every fixture case."
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

(ert-deftest agent-scheme-conformance-test-pending-cases-are-discoverable ()
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
        (eq (agent-scheme--conformance-field case 'status) 'pending))
      not-yet-implemented))))

(ert-deftest agent-scheme-conformance-test-expectation-comparison ()
  "Cover value, multiple-value, and error expectation comparison."
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
    '(error)
    '(:status error :condition boom)))
  (should-not
   (agent-scheme--conformance-actual-matches-p
    '(value "3")
    '(:status value :value "4"))))

(ert-deftest agent-scheme-conformance-test-runner-invokes-evaluator ()
  "Confirm the fixture runner passes Scheme source to an evaluator."
  (let ((agent-scheme-conformance-evaluator
         (lambda (source)
           (should (equal source "(+ 1 2)"))
           '(:status value :value "3"))))
    (agent-scheme--conformance-run-case
     '((id runner-demo)
       (source "(+ 1 2)")
       (expect (value "3"))))))

(ert-deftest agent-scheme-conformance-test-implemented-cases-run ()
  "Run cases marked implemented through the registered evaluator."
  (dolist (case (agent-scheme--conformance-suite-cases))
    (when (eq (agent-scheme--conformance-field case 'status) 'implemented)
      (agent-scheme--conformance-run-case case))))

;;; agent-scheme-conformance-test.el ends here
