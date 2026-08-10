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
                (consent-eval-source-result raw-consent-eval-source-result))
        (consent symbol)
        (only (consent symbol-boundary) consent-host-symbol-eq?)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Unique marker for unset CI matrix defaults.
(define consent-test-option-unset (list 'unset))

;; Return #t inside a compiled self-host test program.
(define compiled-host-run?
  (if (get-environment-variable "TESTING_RUNNER_HOST_RUN") #t #f))

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

;; Parse NAME's environment value as the CI source metadata budget default.
(define (consent-test-max-source-metadata-default name)
  (let ((value (get-environment-variable name)))
    (cond
     ((or (not value) (= (string-length value) 0))
      consent-test-option-unset)
     ((let ((parsed (string->number value)))
        (and parsed
             (exact? parsed)
             (integer? parsed)
             (>= parsed 0)))
      (string->number value))
     (else
      (error "CONSENT_TEST_MAX_SOURCE_METADATA must be a non-negative integer"
             value)))))

;; Return CI matrix defaults as evaluator options.
(define (consent-test-default-options)
  (let ((source-metadata
         (consent-test-source-metadata-default
          "CONSENT_TEST_SOURCE_METADATA"))
        (docstring-retention
         (consent-test-docstring-retention-default
          "CONSENT_TEST_DOCSTRING_RETENTION"))
        (max-source-metadata
         (consent-test-max-source-metadata-default
          "CONSENT_TEST_MAX_SOURCE_METADATA")))
    (append
     (if (consent-test-option-unset? source-metadata)
         '()
         (list (cons 'source-metadata source-metadata)))
     (if (consent-test-option-unset? docstring-retention)
         '()
         (list (cons 'docstring-retention docstring-retention)))
     (if (consent-test-option-unset? max-source-metadata)
         '()
         (list (cons 'max-source-metadata max-source-metadata))))))

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
(define consent-eval-string consent-eval-source)

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
(define fixture-phases '(read read-all expand eval eval-result error write))

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
  '(id kind phase category section status oracle options source expect
    description))

;; Return #t when VALUE is an owned symbol named NAME.
(define (fixture-symbol=? value name)
  (cond
   ((symbol? value) (eq? value name))
   ((consent-symbol? value)
    (consent-host-symbol-eq? value name))
   (else #f)))

;; Return #t when VALUE is a fixture control symbol in either host posture.
(define (fixture-symbol? value)
  (or (symbol? value) (consent-symbol? value)))

;; Return the entry named NAME in fixture ALIST.
(define (fixture-entry alist name)
  (let loop ((rest alist))
    (cond
     ((null? rest) #f)
     ((fixture-symbol=? (caar rest) name) (car rest))
     (else (loop (cdr rest))))))

;; Return the value for NAME in a fixture CASE alist.
(define (field case name)
  (let ((entry (fixture-entry case name)))
    (if entry (cadr entry) #f)))

;; Return whether CASE explicitly includes NAME.
(define (field-present? case name)
  (if (fixture-entry case name) #t #f))

;; Return #t when PREDICATE accepts every value in VALUES.
(define (all? predicate values)
  (cond
   ((null? values) #t)
   ((predicate (car values)) (all? predicate (cdr values)))
   (else #f)))

;; Read all text from PORT without applying the host Scheme reader.
(define (fixture-port-text port)
  (let loop ((parts '()))
    (let ((part (read-string 4096 port)))
      (if (eof-object? part)
          (apply string-append (reverse parts))
          (loop (cons part parts))))))

;; Load the canonical fixture corpus through the active Consent reader.
;; Self-hosted `read` already owns the schema in this context; crossing the
;; native reader boundary would retain a mirror of the entire corpus graph.
(define (read-suite)
  (call-with-input-file
   "fixtures/r7rs/conformance-cases.scm"
   (lambda (port)
     (if compiled-host-run?
         (read port)
         (consent-read (fixture-port-text port))))))

;; Extract the case list from a shared fixture SUITE datum.
(define (suite-cases suite)
  (let ((cases-field (fixture-entry (cdr suite) 'cases)))
    (if cases-field (cdr cases-field) '())))

;; Validate the shape of an EXPECT datum without evaluating it.
(define (expect-valid? expect phase)
  (cond
   ((and (pair? expect)
         (fixture-symbol=? (car expect) 'value)
         (pair? (cdr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect)
         (fixture-symbol=? (car expect) 'values))
    #t)
   ((and (pair? expect)
         (fixture-symbol=? (car expect) 'result)
         (pair? (cdr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect)
         (fixture-symbol=? (car expect) 'serialized-value)
         (pair? (cdr expect))
         (string? (cadr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect)
         (fixture-symbol=? (car expect) 'external-text)
         (eq? phase 'write)
         (pair? (cdr expect))
         (string? (cadr expect))
         (null? (cddr expect)))
    #t)
   ((and (pair? expect)
         (fixture-symbol=? (car expect) 'condition)
         (pair? (cdr expect)))
    #t)
   (else #f)))

;; Return a fixture control symbol suitable for the active host posture.
(define (fixture-host-symbol symbol)
  (if (symbol? symbol)
      symbol
      (string->symbol (consent-symbol-name symbol))))

;; Return SOURCE's variant as a fixture control symbol.
(define (source-variant source)
  (if (and (pair? source) (fixture-symbol? (car source)))
      (fixture-host-symbol (car source))
      #f))

;; Return #t when TEXT contains NEEDLE.
(define (fixture-string-contains? text needle)
  (let ((text-length (string-length text))
        (needle-length (string-length needle)))
    (let loop ((index 0))
      (cond
       ((> (+ index needle-length) text-length) #f)
       ((string=?
         (substring text index (+ index needle-length))
         needle)
        #t)
       (else (loop (+ index 1)))))))

;; Return #t when PATH names an allowed file-backed fixture program.
(define (source-file-path-valid? path)
  (and (string? path)
       (> (string-length path) 13)
       (string=? (substring path 0 9) "programs/")
       (not (fixture-string-contains? path ".."))
       (not (fixture-string-contains? path "\\"))
       (let ((length (string-length path)))
         (string=? (substring path (- length 4) length) ".scm"))
       (file-exists?
        (string-append "fixtures/r7rs/" path))))

;; Return #t when SOURCE is licensed for PHASE.
(define (source-valid? source phase)
  (let ((variant (source-variant source)))
    (cond
     ((eq? variant 'text)
      (and (= (length source) 2)
           (string? (cadr source))
           (> (string-length (cadr source)) 0)
           (memq phase '(read read-all))))
     ((eq? variant 'form)
      (and (= (length source) 2)
           (not (memq phase '(read read-all)))))
     ((eq? variant 'forms)
      (and (pair? (cdr source))
           (not (memq phase '(read read-all write)))))
     ((eq? variant 'file)
      (and (= (length source) 2)
           (not (memq phase '(read read-all write)))
           (source-file-path-valid? (cadr source))))
     (else #f))))

;; Validate one `(name value)' option entry before converting to an alist.
(define (option-entry-valid? entry)
  (and (list? entry)
       (= (length entry) 2)
       (fixture-symbol? (car entry))))

;; Validate optional oracle eligibility metadata when a case carries it.
(define (oracle-metadata-valid? case)
  (let ((eligibility-present? (field-present? case 'oracle-eligibility))
        (reason-present? (field-present? case 'oracle-reason)))
    (if (or eligibility-present? reason-present?)
        (and eligibility-present?
             reason-present?
             (memq (fixture-host-symbol
                    (field case 'oracle-eligibility))
                   fixture-oracle-eligibilities)
             (memq (fixture-host-symbol
                    (field case 'oracle-reason))
                   fixture-oracle-reasons))
        #t)))

;; Validate one fixture CASE against the shared corpus schema.
(define (case-valid? case)
  (let ((phase
         (and (fixture-symbol? (field case 'phase))
              (fixture-host-symbol (field case 'phase)))))
    (and (all? (lambda (name) (field-present? case name))
               fixture-required-fields)
       (fixture-symbol? (field case 'id))
       (memq (fixture-host-symbol (field case 'kind)) fixture-kinds)
       (memq phase fixture-phases)
       (string? (field case 'section))
       (memq (fixture-host-symbol (field case 'status)) fixture-statuses)
       (memq (fixture-host-symbol (field case 'oracle)) fixture-oracles)
       (list? (field case 'options))
       (all? option-entry-valid? (field case 'options))
       (source-valid? (field case 'source) phase)
       (string? (field case 'description))
       (> (string-length (field case 'description)) 0)
       (oracle-metadata-valid? case)
       (expect-valid? (field case 'expect) phase))))

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
         (cons (fixture-host-symbol (car entry))
               (cadr entry)))
       (field case 'options)))

;; Return whether EXPECT describes multiple values.
(define (values-expectation? expect)
  (and (pair? expect)
       (fixture-symbol=? (car expect) 'values)))

;; Return all text from a validated file-backed fixture PATH.
(define (fixture-source-file-text path)
  (if (not (source-file-path-valid? path))
      (error "invalid fixture source file path" path))
  (call-with-input-file
   (string-append "fixtures/r7rs/" path)
   fixture-port-text))

;; Materialize CASE source text only at the execution boundary.
(define (fixture-source-text case)
  (let* ((source (field case 'source))
         (variant (source-variant source)))
    (cond
     ((eq? variant 'text) (cadr source))
     ((eq? variant 'form)
      (string-append
       (consent-datum->external (cadr source))
       "\n"))
     ((eq? variant 'forms)
      (let loop ((forms (cdr source)) (parts '()))
        (if (null? forms)
            (apply string-append (reverse parts))
            (loop
             (cdr forms)
             (cons
              (string-append
               (consent-datum->external (car forms))
               "\n")
              parts)))))
     ((eq? variant 'file)
      (fixture-source-file-text (cadr source)))
     (else
      (error "unsupported fixture source" source)))))

;; Evaluate SOURCE with OPTIONS and normalize the result for expectation
;; checks.
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
          (cons 'values (cadr values-field)))
         (value-field
          (list 'value (cadr value-field)))
         (else
          (list 'error result))))
      (list 'value
            (consent-eval-source source #f options))))

;; Run CASE through the selected phase and return a normalized actual record.
(define (actual case)
  (let ((phase (fixture-host-symbol (field case 'phase)))
        (source (fixture-source-text case))
        (options (fixture-options case))
        (expect (field case 'expect)))
    (guard (condition
            (else (list 'error condition)))
      (cond
       ((eq? phase 'read)
        (list 'value (consent-read source options)))
       ((eq? phase 'read-all)
        (cons 'values (consent-read-all source options)))
       ((eq? phase 'expand)
        (cons 'values
              (consent-expand-source source #f options)))
       ((eq? phase 'eval)
        (eval-actual source options expect))
       ((eq? phase 'eval-result)
        (list 'result
              (consent-eval-source-result source #f options)))
       ((eq? phase 'error)
        (eval-actual source options expect))
       ((eq? phase 'write)
        (list 'external-text
              (consent-datum->external
               (cadr (field case 'source)))))
       (else
        (list 'error phase))))))

;; Return #t when EXPECT matches ACTUAL-RESULT.
(define (matches? expect actual-result)
  (cond
   ((fixture-symbol=? (car expect) 'value)
    (and (eq? (car actual-result) 'value)
         (string=?
          (consent-datum->external (cadr actual-result))
          (consent-datum->external (cadr expect)))))
   ((fixture-symbol=? (car expect) 'values)
    (and (eq? (car actual-result) 'values)
         (= (length (cdr actual-result))
            (length (cdr expect)))
         (all?
          (lambda (pair)
            (string=?
             (consent-datum->external (car pair))
             (consent-datum->external (cdr pair))))
          (map cons (cdr actual-result) (cdr expect)))))
   ((fixture-symbol=? (car expect) 'result)
    (and (eq? (car actual-result) 'result)
         (string=?
          (consent-result->external (cadr actual-result))
          (consent-result->external (cadr expect)))))
   ((fixture-symbol=? (car expect) 'serialized-value)
    (and (eq? (car actual-result) 'value)
         (string=?
          (consent-datum->external (cadr actual-result))
          (cadr expect))))
   ((fixture-symbol=? (car expect) 'external-text)
    (and (eq? (car actual-result) 'external-text)
         (string=? (cadr actual-result) (cadr expect))))
   ((fixture-symbol=? (car expect) 'condition)
    (eq? (car actual-result) 'error))
   (else #f)))

;; Execute one implemented fixture CASE and record a mismatch if its oracle
;; expectation is not satisfied.
(define (run-case case)
  (let ((expect (field case 'expect))
        (actual-result (actual case)))
    (let ((matched? (matches? expect actual-result)))
      (if (not matched?)
          (begin
            (display "fixture mismatch ")
            (display
             (if (symbol? (field case 'id))
                 (symbol->string (field case 'id))
                 (consent-symbol-name (field case 'id))))
            (display ": expected ")
            (display (consent-datum->external expect))
            (display ", actual ")
            (write actual-result)
            (newline)))
      (test-assert (field case 'id) matched?))))

;; Canonical fixture suite loaded once for validation and execution.
(define suite (read-suite))

;; Shared fixture case list extracted from the canonical suite.
(define cases (suite-cases suite))

(testing-registry-case
 'fixture-suite-tag '(portable core)
(test-assert
 'fixture-suite-tag
 (fixture-symbol=? (car suite) 'consent-fixture-suite)))
(testing-registry-case
 'fixture-suite-version '(portable core)
(test-equal
 'fixture-suite-version
 "2"
 (consent-datum->external
  (field (cdr suite) 'version))))
(testing-registry-case
 'fixture-suite-has-cases '(portable core)
(test-assert 'fixture-suite-has-cases (pair? cases)))
(testing-registry-case
 'fixture-suite-ids-unique '(portable core)
(test-assert 'fixture-suite-ids-unique (unique-ids? cases)))

(testing-registry-case
 'consent-fixture-case-4 '(portable core)
(for-each
 (lambda (case)
   (test-assert (field case 'id) (case-valid? case)))
 cases))

(testing-registry-case
 'consent-fixture-case-5 '(portable core)
(for-each
 (lambda (case)
   (if (and (fixture-symbol=? (field case 'status) 'implemented)
            (fixture-symbol=? (field case 'oracle) 'shared))
       (run-case case)))
 cases))

(testing-runner-main "Consent Fixture portable tests" (command-line))
