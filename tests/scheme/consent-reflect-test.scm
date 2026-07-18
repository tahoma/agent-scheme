;;; Portable reflection contract tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program exercises quick public `(agent reflect)' contracts under every
;;; portable R7RS host.  Full catalog traversal and dynamic catalog stress live
;;; in `consent-reflect-stress-test.scm' so host shards can parallelize them.

(import (scheme base)
        (scheme char)
        (scheme process-context)
        (scheme time)
        (scheme write)
        (rename (consent eval)
                (consent-eval-source raw-consent-eval-source))
        (only (consent reader)
              consent-datum->external
              consent-read)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Minimum check duration emitted as a fine-grained CI timing diagnostic.
(define consent-ci-check-minimum-milliseconds 10)

;; Unique marker for unset CI matrix defaults.
(define consent-test-option-unset (list 'unset))

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
     ((string-ci=? value "full") 'full)
     ((string-ci=? value "simple") 'simple)
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

;; Evaluate SOURCE text under the CI matrix defaults.
(define (consent-eval-source source . rest)
  (raw-consent-eval-source
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Return MILLISECONDS as three digits for fixed seconds output.
(define (milliseconds-fragment milliseconds)
  (let ((text (number->string milliseconds)))
    (cond
     ((< milliseconds 10) (string-append "00" text))
     ((< milliseconds 100) (string-append "0" text))
     (else text))))

;; Render MILLISECONDS as a fixed decimal seconds value.
(define (display-check-seconds milliseconds)
  (display (quotient milliseconds 1000))
  (display ".")
  (display (milliseconds-fragment (remainder milliseconds 1000))))

;; Emit one fine-grained timing line for CI diagnostics.
(define (record-check-timing name thunk)
  (let ((started (current-jiffy)))
    (let ((result (thunk)))
      (let ((milliseconds
             (quotient
              (+ (* (- (current-jiffy) started) 1000)
                 (quotient (jiffies-per-second) 2))
              (jiffies-per-second))))
        (if (>= milliseconds consent-ci-check-minimum-milliseconds)
            (begin
              (display "CONSENT_CI_CHECK_SECONDS=")
              (write name)
              (display " ")
              (display-check-seconds milliseconds)
              (newline))))
      result)))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check-value name actual expected)
  "Compare ACTUAL and EXPECTED through SRFI 64."
  (test-equal name expected actual))

;; Time one reflection check and then compare its value.
(define-syntax check
  (syntax-rules ()
    ((_ name actual expected)
     (record-check-timing
      name
      (lambda ()
        (check-value name actual expected))))))

;; Evaluate SOURCE and compare the stable external value representation.
(define (check-external name source expected)
  (check name
         (consent-value->external (consent-eval-source source))
         expected))

;; Evaluate SOURCE with OPTIONS and compare the stable external value.
(define (check-external/options name source options expected)
  (check name
         (consent-value->external
          (consent-eval-source source #f options))
         expected))

;; Render a readable expected datum shape as canonical external text.
(define (expected-datum-external . fragments)
  (consent-datum->external
   (consent-read (apply string-append fragments)
                 '((source-metadata . #f)))))

(testing-registry-case
 'reflect-manifest-input-contract '(portable core)
(check-external 'reflect-manifest-input-contract
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (source-has? sources id name)
                   (cond
                    ((null? sources) #f)
                    ((and (equal? (field (car sources) 'id) id)
                          (member name (field (car sources) 'libraries)))
                     #t)
                    (else (source-has? (cdr sources) id name))))
                 (remove-manifest! 'reflect-contract)
                 (define added
                   (add-manifest!
                    'reflect-contract
                    '(library-catalog
                      (manifest-entry
                       (schema-version 1)
                       (kind library)
                       (name (project contract))
                       (owner project)
                       (provider reflect-contract)
                       (visibility public)
                       (category project)
                       (status experimental)
                       (source-kind ad-hoc)
                       (realization manifest)
                       (exports (contract-run))
                       (documentation
                        ((summary \"Contract manifest library.\")))
                       (provenance ((origin ad-hoc)))
                       (canonical #t)))))
                 (define visible-before-remove
                   (source-has? (catalog-sources)
                                'reflect-contract
                                '(project contract)))
                 (define removed (remove-manifest! 'reflect-contract))
                 (list (field added 'kind)
                       (field added 'id)
                       visible-before-remove
                       removed
                       (source-has? (catalog-sources)
                                    'reflect-contract
                                    '(project contract)))"
                "(ad-hoc-manifest reflect-contract #t #t #f)"))

(testing-registry-case
 'reflect-documentation-contract '(portable core)
(check-external/options 'reflect-documentation-contract
                        "(import (scheme base) (agent reflect))
                         (define (needle-procedure x)
                           \"Return the needle value for discovery tests.\"
                           x)
                         (list (docstring 'needle-procedure)
                               (documentation-field
                                (documentation 'needle-procedure)
                                'documentation)
                               (docstring 'missing 'default))"
                        '((docstring-retention . full))
                        (expected-datum-external
                         "(\"Return the needle value for discovery tests.\"
                           \"Return the needle value for discovery tests.\"
                           default)")))

(testing-registry-case
 'reflect-helper-defaults '(portable core)
(check-external 'reflect-helper-defaults
                "(import (scheme base) (agent reflect))
                 (define present-false '(sample (present #f)))
                 (define missing '(sample))
                 (list (reflection-field present-false 'present 'default)
                       (reflection-field present-false \"present\" 'default)
                       (reflection-field missing 'present 'default)
                       (reflection-field #f 'present 'default)
                       (documentation-field (documentation '+) 'documentation)
                       (documentation-field
                        (documentation '+)
                        \"documentation\")
                       (documentation-field (documentation '+) 'missing 'default)
                       (docstring '+)
                       (docstring (documentation '+))
                       (docstring 'missing 'default))"
                (expected-datum-external
                 "(#f
                   #f
                   default
                   default
                   \"Return the sum of all numeric arguments, or 0 when called with no arguments.\"
                   \"Return the sum of all numeric arguments, or 0 when called with no arguments.\"
                   default
                   \"Return the sum of all numeric arguments, or 0 when called with no arguments.\"
                   \"Return the sum of all numeric arguments, or 0 when called with no arguments.\"
                   default)")))

(testing-runner-main "Consent Reflect portable tests" (command-line))
