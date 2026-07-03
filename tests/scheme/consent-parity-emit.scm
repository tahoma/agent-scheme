;;; Portable parity actual emitter for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme, evaluates each implemented
;;; shared fixture case through the portable Consent Scheme reader and
;;; evaluator, and writes one normalized `(parity-actual ID RESULT)' datum per
;;; case to stdout. The Emacs-hosted parity bridge reads these records and
;;; compares them against the Emacs-hosted results so the in-repo dual core
;;; cannot diverge silently. The normalization mirrors the portable fixture
;;; runner (tests/scheme/consent-fixture-test.scm) so a parity record always
;;; matches that runner's own `expect' comparison.

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

;; Read one datum from SOURCE with CI matrix defaults applied so the emitted
;; records honor the same source-metadata and docstring-retention axes the
;; portable fixture runner and Emacs bridge use.
(define (consent-read source . maybe-options)
  (raw-consent-read
   source
   (consent-test-merge-options
    (if (null? maybe-options) '() (car maybe-options)))))

;; Read every datum from SOURCE with CI matrix defaults applied.
(define (consent-read-all source . maybe-options)
  (raw-consent-read-all
   source
   (consent-test-merge-options
    (if (null? maybe-options) '() (car maybe-options)))))

;; Evaluate SOURCE with CI matrix defaults applied.
(define (consent-eval-source source . rest)
  (raw-consent-eval-source
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Expand SOURCE with CI matrix defaults applied.
(define (consent-expand-source source . rest)
  (raw-consent-expand-source
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Evaluate SOURCE to a result record with CI matrix defaults applied.
(define (consent-eval-source-result source . rest)
  (raw-consent-eval-source-result
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Return the value for NAME in a fixture CASE alist.
(define (field case name)
  (let ((entry (assq name case)))
    (if entry (cadr entry) #f)))

;; Load the canonical fixture corpus through the host Scheme reader.
(define (read-suite)
  (call-with-input-file "fixtures/r7rs/conformance-cases.scm" read))

;; Extract the case list from a shared fixture SUITE datum.
(define (suite-cases suite)
  (let ((cases-field (assq 'cases (cdr suite))))
    (if cases-field (cdr cases-field) '())))

;; Convert fixture options from record syntax to the alist expected by portable
;; reader and evaluator APIs.
(define (fixture-options case)
  (map (lambda (entry)
         (cons (car entry) (cadr entry)))
       (field case 'options)))

;; Return whether EXPECT describes multiple values.
(define (values-expectation? expect)
  (and (pair? expect) (eq? (car expect) 'values)))

;; Decode the portable evaluator's `(values ...)' external wrapper when a case
;; expects multiple values.
(define (external-values external)
  (let ((datum (consent-read external)))
    (if (and (pair? datum) (eq? (car datum) 'values))
        (map consent-datum->external (cdr datum))
        #f)))

;; Evaluate SOURCE with OPTIONS and normalize the result for expectation checks.
(define (eval-actual source options expect)
  (let ((external
         (consent-value->external
          (consent-eval-source source #f options))))
    (if (values-expectation? expect)
        (let ((values (external-values external)))
          (if values
              (list 'values values)
              (list 'value external)))
        (list 'value external))))

;; Run CASE through the selected phase and return a normalized actual record.
;; The shape matches the portable fixture runner: `(value STR)', `(values
;; (STR ...))', `(result STR)', or `(error ...)'.
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

;; Reduce an actual record to the host-comparable parity payload. Error
;; conditions are coarsened to a bare `(error)' tag because the underlying
;; condition object is not portable across hosts; this matches the corpus
;; `(error)' expectation granularity.
(define (parity-payload actual-result)
  (cond
   ((eq? (car actual-result) 'value)
    (list 'value (cadr actual-result)))
   ((eq? (car actual-result) 'values)
    (list 'values (cadr actual-result)))
   ((eq? (car actual-result) 'result)
    (list 'result (cadr actual-result)))
   (else
    (list 'error))))

;; Emit one Scheme-readable parity record for CASE.
(define (emit-case case)
  (write (list 'parity-actual
               (field case 'id)
               (parity-payload (actual case))))
  (newline))

;; Canonical fixture suite loaded once for case extraction.
(define suite (read-suite))

;; Shared fixture case list extracted from the canonical suite.
(define cases (suite-cases suite))

(for-each
 (lambda (case)
   (if (and (eq? (field case 'status) 'implemented)
            (eq? (field case 'oracle) 'shared))
       (emit-case case)))
 cases)
