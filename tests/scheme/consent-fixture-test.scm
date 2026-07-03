;;; Portable shared fixture runner for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme, validates the canonical
;;; fixture corpus, and executes shared reader/evaluator cases without loading
;;; the Emacs host adapter.

(import (scheme base)
        (scheme char)
        (scheme file)
        (scheme process-context)
        (scheme read)
        (scheme write)
        (rename (consent reader)
                (consent-read raw-consent-read)
                (consent-read-all raw-consent-read-all))
        (rename (consent eval)
                (consent-eval raw-consent-eval)
                (consent-eval-source raw-consent-eval-source)
                (consent-eval-string raw-consent-eval-string)
                (consent-expand raw-consent-expand)
                (consent-expand-source raw-consent-expand-source)
                (consent-eval-result raw-consent-eval-result)
                (consent-eval-source-result raw-consent-eval-source-result)))

;; Count failed checks so the portable runner can report all fixture mismatches.
(define failures 0)

;; Unique marker for unset CI matrix defaults.
(define consent-test-option-unset
  (list 'unset))

;; Return #t when VALUE is the unset marker.
(define (consent-test-option-unset? value)
  (eq? value consent-test-option-unset))

;; Parse NAME's environment value as the CI source metadata default.
(define (consent-test-source-metadata-default name)
  (let ((value (get-environment-variable name)))
    (cond
     ((or (not value) (= (string-length value) 0))
      consent-test-option-unset)
     ((or (string-ci=? value "on")
          (string-ci=? value "true")
          (string-ci=? value "t")
          (string-ci=? value "yes")
          (string=? value "1"))
      #t)
     ((or (string-ci=? value "off")
          (string-ci=? value "false")
          (string-ci=? value "nil")
          (string-ci=? value "no")
          (string=? value "0"))
      #f)
     (else
      (error "CONSENT_TEST_SOURCE_METADATA must be on or off" value)))))

;; Parse NAME's environment value as the CI docstring retention default.
(define (consent-test-docstring-retention-default name)
  (let ((value (get-environment-variable name)))
    (cond
     ((or (not value) (= (string-length value) 0))
      consent-test-option-unset)
     ((string-ci=? value "full")
      'full)
     ((string-ci=? value "simple")
      'simple)
     ((or (string-ci=? value "none")
          (string-ci=? value "nil")
          (string-ci=? value "off")
          (string-ci=? value "false")
          (string=? value "0"))
      #f)
     (else
      (error "CONSENT_TEST_DOCSTRING_RETENTION must be full, simple, or none"
             value)))))

;; Return CI matrix defaults as evaluator options.
(define (consent-test-default-options)
  (let ((source-metadata
         (consent-test-source-metadata-default
          "CONSENT_TEST_SOURCE_METADATA"))
        (docstring-retention
         (consent-test-docstring-retention-default
          "CONSENT_TEST_DOCSTRING_RETENTION")))
    (append
     (if (consent-test-option-unset? source-metadata)
         '()
         (list (cons 'source-metadata source-metadata)))
     (if (consent-test-option-unset? docstring-retention)
         '()
         (list (cons 'docstring-retention docstring-retention))))))

;; Return OPTIONS with missing CI matrix defaults appended.
(define (consent-test-merge-options options)
  (let loop ((defaults (consent-test-default-options))
             (merged (if options options '())))
    (if (null? defaults)
        merged
        (let ((entry (car defaults)))
          (loop (cdr defaults)
                (if (assq (car entry) merged)
                    merged
                    (append merged (list entry))))))))

;; Return the optional environment argument from REST.
(define (consent-test-rest-environment rest)
  (if (null? rest) #f (car rest)))

;; Return the optional evaluator options argument from REST.
(define (consent-test-rest-options rest)
  (if (or (null? rest) (null? (cdr rest)))
      '()
      (cadr rest)))

;; Reader and evaluator wrappers apply CI matrix defaults.
(define (consent-read source . maybe-options)
  (raw-consent-read
   source
   (consent-test-merge-options
    (if (null? maybe-options) '() (car maybe-options)))))

;; Read every datum from SOURCE text under the CI matrix defaults.
(define (consent-read-all source . maybe-options)
  (raw-consent-read-all
   source
   (consent-test-merge-options
    (if (null? maybe-options) '() (car maybe-options)))))

;; Evaluate EXPRESSION under the CI matrix defaults.
(define (consent-eval expression . rest)
  (raw-consent-eval
   expression
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Evaluate SOURCE text under the CI matrix defaults.
(define (consent-eval-source source . rest)
  (raw-consent-eval-source
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Alias kept for tests that read by string name.
(define consent-eval-string
  consent-eval-source)

;; Expand EXPRESSION under the CI matrix defaults.
(define (consent-expand expression . rest)
  (raw-consent-expand
   expression
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Expand SOURCE text under the CI matrix defaults.
(define (consent-expand-source source . rest)
  (raw-consent-expand-source
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Evaluate EXPRESSION and return the full result record.
(define (consent-eval-result expression . rest)
  (raw-consent-eval-result
   expression
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Evaluate SOURCE text and return the full result record.
(define (consent-eval-source-result source . rest)
  (raw-consent-eval-source-result
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Fixture kinds identify whether a case is conformance, project-specific, or a
;; regression for a previously observed bug.
(define fixture-kinds '(r7rs-conformance agent-specific regression))

;; Fixture phases select the runner operation applied to each source string.
(define fixture-phases '(read read-all expand eval eval-result error))

;; Fixture statuses mirror the conformance matrix lifecycle.
(define fixture-statuses '(pending implemented policy-gated unavailable))

;; Fixture oracles indicate which host families should run a case.
(define fixture-oracles '(shared emacs-only portable-only))

;; Optional fixture oracle eligibility marks explain why reference
;; implementations should not run a case.
(define fixture-oracle-eligibilities '(policy-gated not-oracle-eligible))

;; Optional fixture oracle reasons give stable skip and policy categories.
(define fixture-oracle-reasons
  '(host-policy agent-specific resource-limit agent-result-record
    implementation-dependent unspecified))

;; Required fixture fields keep corpus shape stable across hosts.
(define fixture-required-fields
  '(id kind phase category section status oracle options source expect description))

;; Record one failed portable fixture check and keep running the rest of the
;; corpus so all malformed cases are visible in one run.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Assert VALUE is true after normalizing to canonical booleans.
(define (check-true name value)
  (check name (if value #t #f) #t))

;; Return the value for NAME in a fixture CASE alist.
(define (field case name)
  (let ((entry (assq name case)))
    (if entry (cadr entry) #f)))

;; Return whether CASE explicitly includes NAME.
(define (field-present? case name)
  (if (assq name case) #t #f))

;; Return #t when PREDICATE accepts every value in VALUES.
(define (all? predicate values)
  (cond
   ((null? values) #t)
   ((predicate (car values)) (all? predicate (cdr values)))
   (else #f)))

;; Load the canonical fixture corpus through the host Scheme reader.
(define (read-suite)
  (call-with-input-file "fixtures/r7rs/conformance-cases.scm" read))

;; Extract the case list from a shared fixture SUITE datum.
(define (suite-cases suite)
  (let ((cases-field (assq 'cases (cdr suite))))
    (if cases-field (cdr cases-field) '())))

;; Validate the shape of an EXPECT datum without evaluating it.
(define (expect-valid? expect)
  (cond
   ((and (pair? expect)
         (eq? (car expect) 'value)
         (pair? (cdr expect))
         (string? (cadr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect)
         (eq? (car expect) 'values)
         (pair? (cdr expect))
         (list? (cadr expect))
         (all? string? (cadr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect)
         (eq? (car expect) 'result)
         (pair? (cdr expect))
         (string? (cadr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect) (eq? (car expect) 'error))
    #t)
   (else #f)))

;; Validate one `(name value)' option entry before converting to an alist.
(define (option-entry-valid? entry)
  (and (list? entry)
       (= (length entry) 2)
       (symbol? (car entry))))

;; Validate optional oracle eligibility metadata when a case carries it.
(define (oracle-metadata-valid? case)
  (let ((eligibility-present? (field-present? case 'oracle-eligibility))
        (reason-present? (field-present? case 'oracle-reason)))
    (if (or eligibility-present? reason-present?)
        (and eligibility-present?
             reason-present?
             (memq (field case 'oracle-eligibility)
                   fixture-oracle-eligibilities)
             (memq (field case 'oracle-reason)
                   fixture-oracle-reasons))
        #t)))

;; Validate one fixture CASE against the shared corpus schema.
(define (case-valid? case)
  (and (all? (lambda (name) (field-present? case name))
             fixture-required-fields)
       (symbol? (field case 'id))
       (memq (field case 'kind) fixture-kinds)
       (memq (field case 'phase) fixture-phases)
       (string? (field case 'section))
       (memq (field case 'status) fixture-statuses)
       (memq (field case 'oracle) fixture-oracles)
       (list? (field case 'options))
       (all? option-entry-valid? (field case 'options))
       (string? (field case 'source))
       (> (string-length (field case 'source)) 0)
       (string? (field case 'description))
       (> (string-length (field case 'description)) 0)
       (oracle-metadata-valid? case)
       (expect-valid? (field case 'expect))))

;; Return #t when CASES do not repeat fixture ids.
(define (unique-ids? cases)
  (let loop ((rest cases) (seen '()))
    (cond
     ((null? rest) #t)
     ((memq (field (car rest) 'id) seen) #f)
     (else (loop (cdr rest) (cons (field (car rest) 'id) seen))))))

;; Convert fixture options from record syntax to the alist expected by portable
;; reader and evaluator APIs.
(define (fixture-options case)
  (map (lambda (entry)
         (cons (car entry) (cadr entry)))
       (field case 'options)))

;; Return whether EXPECT describes multiple values.
(define (values-expectation? expect)
  (and (pair? expect) (eq? (car expect) 'values)))

;; Evaluate SOURCE with OPTIONS and normalize the result for expectation checks.
;; Values expectations evaluate through the result API: a raw multiple-values
;; return cannot cross the call boundary as one datum when this runner is
;; itself hosted on the consent runtime (consent --host-run), while the result
;; record carries the values as data on every posture.
(define (eval-actual source options expect)
  (if (values-expectation? expect)
      (let* ((result (consent-eval-source-result source #f options))
             (values-field (assq 'values (cdr result)))
             (value-field (assq 'value (cdr result))))
        (cond
         (values-field
          (list 'values
                (map consent-result->external (cadr values-field))))
         (value-field
          (list 'value (consent-result->external (cadr value-field))))
         (else
          (list 'error result))))
      (list 'value
            (consent-value->external
             (consent-eval-source source #f options)))))

;; Run CASE through the selected phase and return a normalized actual record.
(define (actual case)
  (let ((phase (field case 'phase))
        (source (field case 'source))
        (options (fixture-options case))
        (expect (field case 'expect)))
    (guard (condition
            (else (list 'error condition)))
      (cond
       ((eq? phase 'read)
        (list 'value
              (consent-datum->external
               (consent-read source options))))
       ((eq? phase 'read-all)
        (list 'values
              (map consent-datum->external
                   (consent-read-all source options))))
       ((eq? phase 'expand)
        (list 'values
              (map consent-datum->external
                   (consent-expand-source source #f options))))
       ((eq? phase 'eval)
        (eval-actual source options expect))
       ((eq? phase 'eval-result)
        (list 'result
              (consent-result->external
               (consent-eval-source-result source #f options))))
       ((eq? phase 'error)
        (eval-actual source options expect))
       (else
        (list 'error phase))))))

;; Return #t when EXPECT matches ACTUAL-RESULT.
(define (matches? expect actual-result)
  (cond
   ((eq? (car expect) 'value)
    (and (eq? (car actual-result) 'value)
         (equal? (cadr actual-result) (cadr expect))))
   ((eq? (car expect) 'values)
    (and (eq? (car actual-result) 'values)
         (equal? (cadr actual-result) (cadr expect))))
   ((eq? (car expect) 'result)
    (and (eq? (car actual-result) 'result)
         (equal? (cadr actual-result) (cadr expect))))
   ((eq? (car expect) 'error)
    (eq? (car actual-result) 'error))
   (else #f)))

;; Execute one implemented fixture CASE and record a mismatch if its oracle
;; expectation is not satisfied.
(define (run-case case)
  (let ((expect (field case 'expect))
        (actual-result (actual case)))
    (if (not (matches? expect actual-result))
        (record-failure (field case 'id) expect actual-result))))

;; Canonical fixture suite loaded once for validation and execution.
(define suite
  (read-suite))

;; Shared fixture case list extracted from the canonical suite.
(define cases
  (suite-cases suite))

(check 'fixture-suite-tag (car suite) 'consent-fixture-suite)
(check-true 'fixture-suite-has-cases (pair? cases))
(check-true 'fixture-suite-ids-unique (unique-ids? cases))

(for-each
 (lambda (case)
   (check-true (field case 'id) (case-valid? case)))
 cases)

(for-each
 (lambda (case)
   (if (and (eq? (field case 'status) 'implemented)
            (eq? (field case 'oracle) 'shared))
       (run-case case)))
 cases)

(if (= failures 0)
    (begin
      (display "Scheme fixture tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme fixture test failure(s)")
      (newline)
      (error "Scheme fixture tests failed")))
