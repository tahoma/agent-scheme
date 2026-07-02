;;; Portable evaluator test runner for the Consent Scheme R7RS library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; evaluator library without loading the Emacs host adapter.

(import (scheme base)
        (scheme char)
        (scheme file)
        (scheme process-context)
        (scheme time)
        (scheme write)
        (rename (consent eval)
                (consent-eval raw-consent-eval)
                (consent-eval-source raw-consent-eval-source)
                (consent-eval-string raw-consent-eval-string)
                (consent-expand raw-consent-expand)
                (consent-expand-source raw-consent-expand-source)
                (consent-eval-result raw-consent-eval-result)
                (consent-eval-source-result raw-consent-eval-source-result))
        (only (consent macro)
              consent-syntax-source)
        (only (consent reader)
              consent-datum->external
              consent-make-canonical-integer
              consent-read)
        (only (consent version)
              consent-version-datum)
        (only (consent runtime)
              audit-process-capability-result!
              audit-network-capability-result!
              authorize-process-capability
              authorize-network-capability
              consent-version
              consent-version-components
              consent-procedure?
              context-audit-events
              documentation-metadata?
              documentation-metadata-fields
              network-capability-handle
              network-port-capability-handle
              new-eval-context
              process-capability-handle
              process-port-capability-handle
              procedure-body))

;; Shared evaluator behavior runs through consent-fixture-test.scm. This
;; file keeps portable evaluator API and bootstrap invariants close to the R7RS
;; library.

(define failures 0)

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

;; Evaluator wrappers apply CI matrix defaults while preserving explicit tests.
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

;; Emit one fine-grained timing line for CI diagnostics without changing the
;; shard-level timing table into a per-check report.
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

;; Record one failed portable evaluator check and keep running the rest of the
;; suite so failures report together.
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
(define (check-value name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Time one evaluator check and then compare its value.
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

;; Return a procedure's stored body expressions as stable external strings.
(define (procedure-body-external procedure)
  (if (consent-procedure? procedure)
      (map consent-value->external (procedure-body procedure))
      #f))

;; Evaluate SOURCE as an evaluation-result datum and compare its external form.
(define (check-result-external name source expected)
  (check name
         (consent-result->external
          (consent-eval-source-result source))
         expected))

;; Render the canonical datum's external form from its components so the
;; expectation tracks (consent version) instead of a hardcoded literal.
(define (consent-test--expected-version-external)
  (let loop ((components (cdr consent-version-datum))
             (acc "(consent-version"))
    (if (null? components)
        (string-append acc ")")
        (loop (cdr components)
              (string-append acc " " (number->string (car components)))))))

(check 'runtime-version-components
       (consent-version-components)
       (cdr consent-version-datum))

(check 'runtime-version-datum
       (consent-result->external (consent-version))
       (consent-test--expected-version-external))

(check 'reader-source-metadata-default-enabled
       (consent-datum->external
        (consent-syntax-source
         (consent-read "\n  (twice 21)\n")))
       "(source (origin source) (source-id #f) (line 2) (column 3) (offset 3) (span 10) (phase read))")

(check 'reader-source-metadata-explicit-disabled
       (consent-datum->external
        (consent-syntax-source
         (consent-read "\n  (twice 21)\n"
                            '((source-metadata . #f)))))
       "#f")

(check 'reader-source-metadata-explicit-enabled
       (consent-datum->external
        (consent-syntax-source
         (consent-read "\n  (twice 21)\n"
                            '((source-metadata . #t)))))
       "(source (origin source) (source-id #f) (line 2) (column 3) (offset 3) (span 10) (phase read))")

(check-external/options 'simple-string-docstring-reflection
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field datum name)
                   (let ((entry (assq name (field datum 'fields))))
                     (if entry (cadr entry) #f)))
                 (define (doc-string datum)
                   (metadata-field datum 'documentation))
                 (define (arguments datum)
                   (metadata-field datum 'arguments))
                 (define (documented x)
                   \"Return X plus one.\"
                   (+ x 1))
                 (list (documented 4)
                       (field (documentation 'documented) 'subject)
                       (arguments (documentation 'documented))
                       (doc-string (documentation 'documented))
                       (field (documentation documented) 'subject)
                       (arguments (documentation documented))
                       (doc-string (documentation documented)))"
                '((docstring-retention . full))
                "(5 (binding documented) (x) \"Return X plus one.\" (procedure) (x) \"Return X plus one.\")")

(check-external/options 'documentation-arguments-metadata
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field subject name)
                   (let ((datum (documentation subject)))
                     (if datum
                         (let ((entry (assq name (field datum 'fields))))
                           (if entry (cadr entry) #f))
                       #f)))
                 (define (proper first second)
                   (+ first second))
                 (define (dotted head . tail)
                   tail)
                 (define variadic
                   (lambda all
                     all))
                 (define (empty)
                   0)
                 (list (metadata-field 'proper 'arguments)
                       (metadata-field 'dotted 'arguments)
                       (metadata-field 'variadic 'arguments)
                       (metadata-field 'empty 'arguments)
                       (map symbol? (metadata-field 'proper 'arguments))
                       (symbol? (metadata-field 'variadic 'arguments)))"
                '((docstring-retention . full))
                "((first second) (head . tail) all () (#t #t) #t)")

(check-external 'primitive-manifest-docstring-reflection
                "(import (scheme base) (scheme time) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field subject name)
                   (let ((datum (documentation subject)))
                     (if datum
                         (let ((entry (assq name (field datum 'fields))))
                           (if entry (cadr entry) #f))
                       #f)))
                 (list (field (documentation '+) 'subject)
                       (field (documentation '+) 'library)
                       (field (documentation '+) 'source)
                       (field (documentation '+) 'origin)
                       (metadata-field '+ 'documentation)
                       (field (documentation +) 'subject)
                       (metadata-field + 'documentation)
                       (field (documentation 'current-second) 'library)
                       (field (documentation 'current-second) 'source)
                       (field (documentation 'current-second) 'origin)
                       (metadata-field 'current-second 'documentation))"
                "((binding +) (scheme base) kernel (primitive-manifest metadata) \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (procedure) \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (scheme time) host-capability (primitive-manifest string) \"Return the current time as a real number of seconds since the Unix epoch, subject to the clock capability policy.\")")

(check-external 'primitive-manifest-rich-metadata-reflection
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field subject name)
                   (let ((datum (documentation subject)))
                     (if datum
                         (let ((entry (assq name (field datum 'fields))))
                           (if entry (cadr entry) #f))
                       #f)))
                 (define (descriptor-type descriptor)
                   (cadr (assq 'type descriptor)))
                 (define (parameter-type subject name)
                   (descriptor-type
                    (cdr (assq name (metadata-field subject 'parameters)))))
                 (define (return-type subject)
                   (descriptor-type (metadata-field subject 'returns)))
                 (list (parameter-type '+ 'numbers)
                       (return-type '+)
                       (metadata-field '+ 'effects)
                       (parameter-type 'vector-ref 'k)
                       (return-type 'floor/)
                       (parameter-type 'read-char 'port)
                       (return-type 'read-char)
                       (parameter-type 'bytevector-u8-set! 'byte)
                       (return-type 'bytevector-u8-set!)
                       (metadata-field 'bytevector-u8-set! 'effects))"
                "((list-of number) number (pure) exact-non-negative-integer (values integer integer) textual-input-port (or char eof-object) byte unspecified (mutation))")

(check-external/options 'docstring-edge-cases
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field datum name)
                   (let ((entry (and datum (assq name (field datum 'fields)))))
                     (if entry (cadr entry) #f)))
                 (define (doc-string datum)
                   (metadata-field datum 'documentation))
                 (define (arguments datum)
                   (metadata-field datum 'arguments))
                 (define (multiline x)
                   \"First line.\"
                   \"Second line.\"
                   x)
                 (define (with-internal x)
                   (define local 2)
                   \"Use the local definition.\"
                   (+ x local))
                 (define (final-string)
                   \"result\")
                 (define (no-doc x)
                   x)
                 (list (doc-string (documentation 'multiline))
                       (arguments (documentation 'multiline))
                       (with-internal 3)
                       (doc-string (documentation 'with-internal))
                       (arguments (documentation 'with-internal))
                       (final-string)
                       (doc-string (documentation 'final-string))
                       (arguments (documentation 'final-string))
                       (doc-string (documentation 'no-doc))
                       (arguments (documentation 'no-doc))
                       (doc-string (documentation 'missing)))"
                '((docstring-retention . full))
                "(\"First line. Second line.\" (x) 5 \"Use the local definition.\" (x) \"result\" #f () #f (x) #f)")

(check-external/options 'rich-documentation-metadata
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-fields name)
                   (let ((datum (documentation name)))
                     (if datum
                         (field datum 'fields)
                       #f)))
                 (define (metadata-field name field-name)
                   (let ((fields (metadata-fields name)))
                     (if fields
                         (let ((entry (assq field-name fields)))
                           (if entry (cadr entry) #f))
                       #f)))
                 (define (rich config)
                   \"Create an Consent Scheme session from CONFIG.\"
                   \"The session is represented as a datum.\"
                   #((summary . \"Open an Consent Scheme session.\")
                     (parameters . ((config . \"Session configuration datum.\")))
                     (returns . \"A session record.\")
                     (effects . (pure))
                     (examples . (((source . \"(rich cfg)\")
                                   (result . (session cfg)))))
                     (see-also . (current-context session-snapshot))
                     (since . (consent-version 0 15 4))
                     (deprecated . #f)
                     (stability . experimental)
                     (authority-review . \"local only\"))
                   (list 'session config))
                 (define (merged x)
                   \"Line one.\"
                   #((documentation . \"Line two.\")
                     (examples . (((source . \"first\"))))
                     (see-also . (alpha))
                     (parameters . ((x . \"Input value.\"))))
                   #((documentation . \"Line three.\")
                     (examples . (((source . \"second\"))))
                     (see-also . (beta))
                     (custom-field . ((tag . kept))))
                   x)
                 (define (duplicate-scalar x)
                   \"Valid documentation.\"
                   #((returns . \"First result.\"))
                   #((returns . \"Duplicate result.\")
                     (summary . \"Ignored with malformed literal.\"))
                   x)
                 (define (duplicate-parameter x)
                   #((parameters . ((x . \"First parameter.\")
                                    (x . \"Duplicate parameter.\")))
                     (returns . \"Ignored with malformed literal.\"))
                   x)
                 (define (malformed-vector x)
                   #((summary . \"Malformed record.\") broken)
                   x)
                 (define (unknown-parameter x)
                   #((parameters . ((y . \"Not bound by the procedure.\")))
                     (returns . \"Ignored with malformed literal.\"))
                   x)
                 (define (rest-parameter head . tail)
                   #((parameters . ((head . \"Required argument.\")
                                    (tail . \"Rest arguments.\"))))
                   tail)
                 (define (final-rich)
                   #((returns . \"ordinary result\")))
                 (list (rich 'cfg)
                       (metadata-field 'rich 'documentation)
                       (metadata-field 'rich 'arguments)
                       (metadata-field 'rich 'summary)
                       (metadata-field 'rich 'parameters)
                       (metadata-field 'rich 'returns)
                       (metadata-field 'rich 'effects)
                       (metadata-field 'rich 'examples)
                       (metadata-field 'rich 'see-also)
                       (metadata-field 'rich 'since)
                       (metadata-field 'rich 'deprecated)
                       (metadata-field 'rich 'stability)
                       (metadata-field 'rich 'authority-review)
                       (metadata-field 'merged 'documentation)
                       (metadata-field 'merged 'arguments)
                       (metadata-field 'merged 'examples)
                       (metadata-field 'merged 'see-also)
                       (metadata-field 'merged 'custom-field)
                       (metadata-field 'duplicate-scalar 'documentation)
                       (metadata-field 'duplicate-scalar 'returns)
                       (metadata-field 'duplicate-scalar 'summary)
                       (metadata-fields 'duplicate-parameter)
                       (metadata-fields 'malformed-vector)
                       (metadata-fields 'unknown-parameter)
                       (metadata-field 'rest-parameter 'parameters)
                       (final-rich)
                       (metadata-fields 'final-rich))"
                '((docstring-retention . full))
                "((session cfg) \"Create an Consent Scheme session from CONFIG. The session is represented as a datum.\" (config) \"Open an Consent Scheme session.\" ((config (type any) (description \"Session configuration datum.\"))) ((type any) (description \"A session record.\")) (pure) (((source . \"(rich cfg)\") (result session cfg))) (current-context session-snapshot) (consent-version 0 15 4) #f experimental \"local only\" \"Line one. Line two. Line three.\" (x) (((source . \"first\")) ((source . \"second\"))) (alpha beta) ((tag . kept)) \"Valid documentation.\" ((type any) (description \"First result.\")) #f ((arguments (x))) ((arguments (x))) ((arguments (x))) ((head (type any) (description \"Required argument.\")) (tail (type any) (description \"Rest arguments.\"))) #((returns . \"ordinary result\")) ((arguments ())))")

(check-external/options 'typed-rich-documentation-metadata
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field name field-name)
                   (let ((datum (documentation name)))
                     (if datum
                         (let ((entry (assq field-name (field datum 'fields))))
                           (if entry (cadr entry) #f))
                       #f)))
                 (define (typed config)
                   \"Create a session from CONFIG.\"
                   #((parameters
                      . ((config
                          (type session-config)
                          (description (\"Session configuration\"
                                        \"datum.\")))))
                     (returns
                      . ((type session-record)
                         (description \"A session record.\")))
                     (effects . (pure)))
                   (list 'session config))
                 (define (legacy-shorthand x)
                   #((parameters . ((x . \"Input value.\")))
                     (returns . \"Output value.\"))
                   x)
                 (define (fragment-shorthand y)
                   #((parameters . ((y . (\"Fragment\"
                                          \"input.\"))))
                     (returns . (\"Fragment\"
                                 \"output.\")))
                   y)
                 (define (missing-type x)
                   #((parameters
                      . ((x (description (\"Wrapped\"
                                          \"input.\")))))
                     (returns
                      . ((description (\"Wrapped\"
                                       \"output.\")))))
                   x)
                 (define (multi-values)
                   #((parameters . ())
                     (returns
                      . ((type (values string any))
                         (description (\"String result\"
                                       \"and opaque payload.\")))))
                   (values \"ok\" 1))
                 (list (metadata-field 'typed 'documentation)
                       (metadata-field 'typed 'parameters)
                       (metadata-field 'typed 'returns)
                       (metadata-field 'typed 'effects)
                       (metadata-field 'legacy-shorthand 'parameters)
                       (metadata-field 'legacy-shorthand 'returns)
                       (metadata-field 'fragment-shorthand 'parameters)
                       (metadata-field 'fragment-shorthand 'returns)
                       (metadata-field 'missing-type 'parameters)
                       (metadata-field 'missing-type 'returns)
                       (metadata-field 'multi-values 'parameters)
                       (metadata-field 'multi-values 'returns))"
                '((docstring-retention . full))
                "(\"Create a session from CONFIG.\" ((config (type session-config) (description \"Session configuration datum.\"))) ((type session-record) (description \"A session record.\")) (pure) ((x (type any) (description \"Input value.\"))) ((type any) (description \"Output value.\")) ((y (type any) (description \"Fragment input.\"))) ((type any) (description \"Fragment output.\")) ((x (type any) (description \"Wrapped input.\"))) ((type any) (description \"Wrapped output.\")) () ((type (values string any)) (description \"String result and opaque payload.\")))")

(check-external/options 'docstring-retention-simple
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (metadata-field subject name)
                   (let ((datum (documentation subject)))
                     (if datum
                         (let ((entry (assq name (field datum 'fields))))
                           (if entry (cadr entry) #f))
                       #f)))
                 (define (documented x)
                   \"Return X plus one.\"
                   #((summary . \"Increment.\")
                     (returns . \"A number.\"))
                   (+ x 1))
                 (list (documented 4)
                       (metadata-field 'documented 'documentation)
                       (metadata-field 'documented 'arguments)
                       (metadata-field 'documented 'summary)
                       (metadata-field 'documented 'returns)
                       (if (documentation '+) 'primitive-kept 'primitive-missing))"
                '((docstring-retention . simple))
                "(5 \"Return X plus one.\" (x) #f #f primitive-kept)")

(check-external/options 'docstring-retention-none
                "(import (scheme base) (agent reflect))
                 (define (documented x)
                   \"Return X plus one.\"
                   #((summary . \"Increment.\")
                     (returns . \"A number.\"))
                   (+ x 1))
                 (list (documented 4)
                       (documentation 'documented)
                       (documentation documented)
                       (if (documentation '+) 'primitive-kept 'primitive-missing))"
                '((docstring-retention . #f))
                "(5 #f #f primitive-kept)")

(check 'docstring-retention-strips-body
       (procedure-body-external
        (consent-eval-source
         "(define (documented x)
            \"Return X plus one.\"
            #((returns . \"A number.\"))
            (+ x 1))
          documented"))
       '("(+ x 1)"))

(check 'docstring-retention-none-strips-body
       (procedure-body-external
        (consent-eval-source
         "(define (documented x)
            \"Return X plus one.\"
            #((returns . \"A number.\"))
            (+ x 1))
          documented"
         #f
         '((docstring-retention . #f))))
       '("(+ x 1)"))

(check 'docstring-retention-none-keeps-final-string-body
       (procedure-body-external
        (consent-eval-source
         "(define (final-string)
            \"result\")
          final-string"
         #f
         '((docstring-retention . #f))))
       '("\"result\""))

(check-external/options 'source-library-docstring-reflection
                "(import (scheme base)
                         (scheme lazy)
                         (agent reflect)
                         (agent diff)
                         (agent network)
                         (agent vcs)
                         (agent transcript))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (doc-string name)
                   (let ((datum (documentation name)))
                     (if datum
                         (cadr (assq 'documentation (field datum 'fields)))
                       #f)))
                 (define (metadata-field name field-name)
                   (let ((datum (documentation name)))
                     (if datum
                         (let ((entry (assq field-name (field datum 'fields))))
                           (if entry (cadr entry) #f))
                       #f)))
                 (list (doc-string 'length)
                       (doc-string 'force)
                       (doc-string 'diff-render-unified)
                       (doc-string 'make-network-request)
                       (doc-string 'vcs-authorize-capability-request)
                       (doc-string 'transcript-event->fixture-case)
                       (metadata-field 'force 'parameters)
                       (metadata-field 'force 'returns)
                       (metadata-field 'diff-render-unified 'parameters)
                       (metadata-field 'diff-render-unified 'returns)
                       (metadata-field 'make-network-request 'parameters)
                       (metadata-field 'make-network-request 'returns))"
                '((docstring-retention . full))
                "(\"Return the number of pairs in LIST.\" \"Return PROMISE's value, evaluating and memoizing delayed thunks once.\" \"Render DIFF to deterministic unified-diff text for humans.\" \"Return a host-adapter request datum for one network operation.\" \"Return a fail-closed authorization decision for REQUEST.\" \"Generate a shared fixture case from EVENT when replay permits it.\" ((promise (type any) (description \"Promise record or ordinary value to force.\"))) ((type any) (description \"PROMISE's memoized value, or PROMISE unchanged when it is not a promise.\")) ((diff (type diff) (description \"Canonical diff datum.\"))) ((type string) (description \"Unified-diff text, or the empty string when DIFF has no changes.\")) ((id (type (or symbol string)) (description \"Stable request id assigned by the caller or host adapter.\")) (operation (type symbol) (description \"Network operation symbol such as request or stream.\")) (resource (type list) (description \"Association list describing scheme, host, port, method, headers, payload, response, redirect, timeout, and stream limits.\"))) ((type network-capability-request) (description \"A `network-capability-request` datum ready for policy evaluation.\")))")

;; Report whether TEXT starts with PREFIX.
(define (string-prefix? prefix text)
  (let ((prefix-length (string-length prefix))
        (text-length (string-length text)))
    (and (<= prefix-length text-length)
         (let loop ((index 0))
           (or (= index prefix-length)
               (and (char=? (string-ref prefix index)
                            (string-ref text index))
                    (loop (+ index 1))))))))

;; Report whether TEXT contains NEEDLE.
(define (string-contains? text needle)
  (let ((text-length (string-length text))
        (needle-length (string-length needle)))
    (let loop ((index 0))
      (and (<= (+ index needle-length) text-length)
           (or (string-prefix? needle (substring text index text-length))
               (loop (+ index 1)))))))

;; Evaluate SOURCE as a result datum and require each substring.
(define (check-result-contains name source needles . maybe-options)
  (record-check-timing
   name
   (lambda ()
     (let ((actual
            (consent-result->external
             (consent-eval-source-result
              source
              #f
              (if (null? maybe-options) '() (car maybe-options))))))
       (let loop ((rest needles))
         (if (not (null? rest))
             (begin
               (if (not (string-contains? actual (car rest)))
                   (record-failure name (car rest) actual))
               (loop (cdr rest)))))))))

;; Replace PATH with CONTENTS using the host Scheme runtime.
(define (write-host-test-file path contents)
  (if (file-exists? path)
      (delete-file path))
  (call-with-output-file path
    (lambda (port)
      (display contents port))))

;; Replace PATH with binary BYTES using the host Scheme runtime.
(define (write-host-binary-file path bytes)
  (if (file-exists? path)
      (delete-file path))
  (let ((port (open-binary-output-file path)))
    (for-each (lambda (byte) (write-u8 byte port)) bytes)
    (close-port port)))

;; Return PATH contents as a list of byte values using the host runtime.
(define (read-host-binary-file path)
  (let ((port (open-binary-input-file path)))
    (let loop ((bytes '()))
      (let ((byte (read-u8 port)))
        (if (eof-object? byte)
            (begin
              (close-port port)
              (reverse bytes))
            (loop (cons byte bytes)))))))

;; Return FIELD from a Scheme-readable result or audit datum.
(define (field-value datum field)
  (let ((entry (assq field (cdr datum))))
    (if entry (cadr entry) #f)))

;; Return the first audit/event datum whose event field is EVENT.
(define (find-event events event)
  (cond
   ((null? events) #f)
   ((equal? (field-value (car events) 'event) event) (car events))
   (else (find-event (cdr events) event))))

;; Return the first audit/event datum whose event and field match.
(define (find-event-with-field events event field value)
  (cond
   ((null? events) #f)
   ((and (equal? (field-value (car events) 'event) event)
         (equal? (field-value (car events) field) value))
    (car events))
   (else (find-event-with-field (cdr events) event field value))))

;; Find the primitive binding metadata record named NAME in SPECS.
(define (find-primitive-spec name specs)
  (cond
   ((null? specs) #f)
   ((eq? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-primitive-spec name (cdr specs)))))

;; Find manifest metadata by LIBRARY and NAME in SPECS.
(define (find-manifest-spec library name specs)
  (cond
   ((null? specs) #f)
   ((and (equal? (cadr (assq 'library (car specs))) library)
         (eq? (cadr (assq 'name (car specs))) name))
    (car specs))
   (else (find-manifest-spec library name (cdr specs)))))

;; Find the source-backed standard library metadata record named NAME in SPECS.
(define (find-source-library-spec name specs)
  (cond
   ((null? specs) #f)
   ((equal? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-source-library-spec name (cdr specs)))))

;; Return #t when SPEC carries public manifest documentation metadata.
(define (manifest-spec-documented? spec)
  (let ((entry (assq 'documentation spec)))
    (if (and entry
             (documentation-metadata? (cadr entry)))
        (let ((field
               (assq 'documentation
                     (documentation-metadata-fields (cadr entry)))))
          (if (and field
                   (string? (cdr field))
                   (> (string-length (cdr field)) 0))
              #t
              #f))
        #f)))

;; Return #t when THUNK raises any portable Scheme condition.
(define (raises? thunk)
  (call/cc
   (lambda (return)
     (with-exception-handler
      (lambda (condition)
        (return #t))
      (lambda ()
        (thunk)
        #f)))))

(check-external 'literal-number "42" "42")
;; Agent ownership means evaluated numbers share the canonical constructors'
;; representation class (see the reader suite's integer-is-agent-owned): the
;; invariant is agreement with a canonical integer, not the surrounding
;; Scheme's own number? answer, which legitimately differs when this file runs
;; on the Consent runtime itself via --host-run.
(check 'literal-number-is-agent-owned
       (number? (consent-eval-source "42"))
       (number? (consent-make-canonical-integer 42)))
(check-external 'literal-string "\"ok\"" "\"ok\"")
(check-external 'quote-symbol "'alpha" "alpha")
(check-external 'quote-list "'(1 2 3)" "(1 2 3)")
(check 'empty-list-expression-error
       (raises? (lambda () (consent-eval-source "()")))
       #t)

(check-external 'definition-and-reference
                "(define answer 40)
                 (+ answer 2)"
                "42")
(check-external 'top-level-begin
                "(begin
                   (define answer 42)
                   answer)"
                "42")
(check-external 'operator-expression
                "((if #f + *) 3 4)"
                "12")
(check 'unknown-identifier
       (raises? (lambda () (consent-eval-source "missing")))
       #t)

(let ((names (consent-base-primitive-names))
      (prelude-names (consent-base-prelude-binding-names))
      (specs (consent-base-primitive-specs))
      (binding-specs (consent-base-binding-specs)))
  (check 'base-registry-names
         (if (and (memq '+ names)
                  (memq 'apply names)
                  (memq 'car names)
                  (memq 'vector-ref names)
                  (not (memq 'append names))
                  (not (memq 'cadr names))
                  (not (memq 'length names))
                  (not (memq 'map names))
                  (not (memq 'string-map names))
                  (not (memq 'string-for-each names))
                  (not (memq 'vector-map names))
                  (not (memq 'vector-for-each names))
                  (not (memq 'zero? names))
                  (memq 'append prelude-names)
                  (memq 'cadr prelude-names)
                  (memq 'length prelude-names)
                  (memq 'map prelude-names)
                  (memq 'string-map prelude-names)
                  (memq 'string-for-each prelude-names)
                  (memq 'vector-map prelude-names)
                  (memq 'vector-for-each prelude-names)
                  (memq 'zero? prelude-names)
                  (memq 'call-with-values names)
                  (memq 'call/cc names)
                  (memq 'dynamic-wind names)
                  (memq 'features names)
                  (memq 'make-parameter names)
                  (memq 'string->utf8 names)
                  (memq 'utf8->string names)
                  (memq 'values names))
             #t
             #f)
         #t)
  (check 'base-registry-specs
         (cadr (assq 'minimum-arity
                     (find-primitive-spec 'vector-ref specs)))
         2)
  (check 'base-kernel-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'vector-ref binding-specs)))
         'kernel)
  (check 'base-prelude-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'append binding-specs)))
         'prelude)
  (check 'base-prelude-string-map-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'string-map binding-specs)))
         'prelude)
  (check 'base-prelude-vector-for-each-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'vector-for-each binding-specs)))
         'prelude))

(let* ((manifest-specs (consent-primitive-manifest-binding-specs))
       (vector-ref
        (find-manifest-spec '(scheme base) 'vector-ref manifest-specs))
       (vector-set
        (find-manifest-spec '(scheme base) 'vector-set! manifest-specs))
       (delete-file
        (find-manifest-spec '(scheme file) 'delete-file manifest-specs))
       (open-input-file
        (find-manifest-spec '(scheme file) 'open-input-file manifest-specs))
       (current-second
        (find-manifest-spec '(scheme time) 'current-second manifest-specs)))
  (check 'primitive-manifest-vector-ref
         (and vector-ref
              (cadr (assq 'minimum-arity vector-ref))
              (cadr (assq 'maximum-arity vector-ref))
              (cadr (assq 'source vector-ref))
              (cadr (assq 'effect vector-ref))
              (eq? (cadr (assq 'backend-effect-path vector-ref))
                   'direct-runtime)
              (cadr (assq 'policy vector-ref))
              (memq 'vector (cadr (assq 'test-categories vector-ref)))
              #t)
         #t)
  (check 'primitive-manifest-vector-set-effect
         (and vector-set
              (list (cadr (assq 'effect vector-set))
                    (cadr (assq 'backend-effect-path vector-set))))
         '(mutation runtime-mutation))
  (check 'primitive-manifest-file-effect
         (and delete-file
              (list (cadr (assq 'source delete-file))
                    (cadr (assq 'effect delete-file))
                    (cadr (assq 'required-capability delete-file))
                    (cadr (assq 'backend-effect-path delete-file))
                    (cadr (assq 'policy-category delete-file))
                    (cadr (assq 'policy delete-file))))
         '(host-capability host-file file-system
           shared-capability-request standard-host-effect deny))
  (check 'primitive-manifest-file-stub-effect
         (and open-input-file
              (list (cadr (assq 'minimum-arity open-input-file))
                    (cadr (assq 'effect open-input-file))
                    (cadr (assq 'backend-effect-path open-input-file))
                    (cadr (assq 'policy open-input-file))))
         '(1 host-file shared-capability-request deny))
  (check 'primitive-manifest-time-effect
         (and current-second
              (list (cadr (assq 'effect current-second))
                    (cadr (assq 'required-capability current-second))
                    (cadr (assq 'backend-effect-path current-second))
                    (cadr (assq 'policy-category current-second))
                    (cadr (assq 'policy current-second))))
         '(host-time clock shared-capability-request
           standard-host-effect grant))
  (let loop ((rest manifest-specs))
    (if (not (null? rest))
        (begin
          (check 'primitive-manifest-public-docs
                 (manifest-spec-documented? (car rest))
                 #t)
          (loop (cdr rest)))))
  (let ((read-char
         (find-manifest-spec '(scheme base) 'read-char manifest-specs)))
    (check 'primitive-manifest-port-runtime-path
           (and read-char
                (list (cadr (assq 'effect read-char))
                      (cadr (assq 'backend-effect-path read-char))))
           '(port-io runtime-port-check)))
  (let loop ((rest (consent-base-primitive-specs)))
    (if (not (null? rest))
        (let* ((spec (car rest))
               (manifest-spec
                (find-manifest-spec
                 '(scheme base)
                 (cadr (assq 'name spec))
                 manifest-specs)))
          (check 'primitive-manifest-base-alignment
                 (and manifest-spec
                      (equal? (cadr (assq 'minimum-arity manifest-spec))
                              (cadr (assq 'minimum-arity spec)))
                      (equal? (cadr (assq 'maximum-arity manifest-spec))
                              (cadr (assq 'maximum-arity spec)))
                      (eq? (cadr (assq 'source manifest-spec))
                           (cadr (assq 'source spec)))
                      (eq? (cadr (assq 'effect manifest-spec))
                           (cadr (assq 'effect spec))))
                 #t)
          (loop (cdr rest))))))

(let* ((source-specs (consent-standard-source-library-specs))
       (case-lambda-spec
        (find-source-library-spec '(scheme case-lambda) source-specs))
       (lazy-spec
        (find-source-library-spec '(scheme lazy) source-specs)))
  (check 'standard-source-library-case-lambda-exports
         (and case-lambda-spec
              (cadr (assq 'exports case-lambda-spec)))
         '(case-lambda))
  (check 'standard-source-library-lazy-exports
         (and lazy-spec
              (cadr (assq 'exports lazy-spec)))
         '(delay delay-force force make-promise promise?))
  (check 'standard-source-library-files
         (and case-lambda-spec
              lazy-spec
              (string? (cadr (assq 'source-file case-lambda-spec)))
              (string? (cadr (assq 'source-file lazy-spec))))
         #t)
  (check 'standard-source-library-case-lambda-file
         (and case-lambda-spec
              (cadr (assq 'source-file case-lambda-spec)))
         "scheme/consent/case-lambda.sld")
  (check 'standard-source-library-lazy-file
         (and lazy-spec
              (cadr (assq 'source-file lazy-spec)))
         "scheme/consent/lazy.sld"))

(let* ((source-specs (consent-stdlib-source-library-specs))
       (manifest-spec
        (find-source-library-spec '(stdlib manifest) source-specs))
       (comparator-spec
        (find-source-library-spec '(stdlib comparator) source-specs))
       (json-spec
        (find-source-library-spec '(stdlib json) source-specs)))
  (check 'stdlib-source-library-files
         (and manifest-spec
              comparator-spec
              json-spec
              (string? (cadr (assq 'source-file manifest-spec)))
              (string? (cadr (assq 'source-file comparator-spec)))
              (string? (cadr (assq 'source-file json-spec))))
         #t)
  (check 'stdlib-source-library-manifest-file
         (and manifest-spec
              (cadr (assq 'source-file manifest-spec)))
         "scheme/stdlib/manifest.sld")
  (check 'stdlib-source-library-comparator-file
         (and comparator-spec
              (cadr (assq 'source-file comparator-spec)))
         "scheme/stdlib/comparator.sld")
  (check 'stdlib-source-library-json-file
         (and json-spec
              (cadr (assq 'source-file json-spec)))
         "scheme/stdlib/json.sld"))

(check-external 'srfi-16-case-lambda-alias-import
                "(import (scheme base) (srfi 16))
                 (define describe
                   (case-lambda
                     (() 'zero)
                     ((x) (list 'one x))
                     ((x . rest) (list 'many x rest))))
                 (list (describe) (describe 'a) (describe 'a 'b 'c))"
                "(zero (one a) (many a (b c)))")

(check-external 'srfi-16-portable-alias-import
                "(import (scheme base) (srfi srfi-16))
                 ((case-lambda
                    ((x y) (+ x y)))
                  2 5)"
                "7")

(check-external 'stdlib-srfi-16-manifest
                "(import (scheme base) (stdlib manifest))
                 (let ((entry (stdlib-manifest-ref '(srfi 16)))
                       (portable-alias
                        (stdlib-manifest-ref '(srfi srfi-16))))
                   (list (cdr (assq 'status entry))
                         (cdr (assq 'source entry))
                         (cdr (assq 'target entry))
                         (cdr (assq 'implementation-library entry))
                         (cdr (assq 'import-aliases entry))
                         (cdr (assq 'dependencies entry))
                         (cdr (assq 'target portable-alias))))"
                "(built-in-shim built-in-shim (scheme case-lambda) (scheme case-lambda) ((srfi 16) (srfi srfi-16)) ((scheme case-lambda)) (scheme case-lambda))")

(check-external 'srfi-180-json-read
                "(import (scheme base) (srfi 180))
                 (let* ((datum
                         (json-read
                          (open-input-string
                           \"{\\\"name\\\":\\\"Ada\\\",\\\"scores\\\":[1,true,null],\\\"nested\\\":{\\\"ok\\\":false}}\")))
                        (scores (cdr (assq 'scores datum)))
                        (nested (cdr (assq 'nested datum))))
                   (list (cdr (assq 'name datum))
                         (vector-ref scores 0)
                         (vector-ref scores 1)
                         (json-null? (vector-ref scores 2))
                         (cdr (assq 'ok nested))))"
                "(\"Ada\" 1 #t #t #f)")

(check-external 'srfi-180-json-write-round-trip
                "(import (scheme base) (srfi 180))
                 (let ((out (open-output-string)))
                   (json-write
                    '((name . \"Ada\")
                      (scores . #(1 #t null))
                      (empty . ()))
                    out)
                   (let* ((datum
                           (json-read
                            (open-input-string (get-output-string out))))
                          (scores (cdr (assq 'scores datum))))
                     (list (cdr (assq 'name datum))
                           (vector-ref scores 0)
                           (vector-ref scores 1)
                           (json-null? (vector-ref scores 2))
                           (cdr (assq 'empty datum)))))"
                "(\"Ada\" 1 #t #t ())")

(check-external 'srfi-180-json-write-nested-object-fields
                "(import (scheme base) (srfi 180))
                 (define (ref object name)
                   (cdr (assq name object)))
                 (let ((out (open-output-string)))
                   (json-write
                    '((outer
                       (first . \"one\")
                       (second
                        (third . 3)
                        (fourth . #t))
                       (array . #(((name . \"nested\") (enabled . #f))
                                  null))))
                    out)
                   (let* ((datum
                           (json-read
                            (open-input-string (get-output-string out))))
                          (outer (ref datum 'outer))
                          (second (ref outer 'second))
                          (array (ref outer 'array))
                          (nested (vector-ref array 0)))
                     (list (ref outer 'first)
                           (ref second 'third)
                           (ref second 'fourth)
                           (ref nested 'name)
                           (ref nested 'enabled)
                           (json-null? (vector-ref array 1)))))"
                "(\"one\" 3 #t \"nested\" #f #t)")

(check-external 'srfi-180-json-error
                "(import (scheme base) (srfi 180))
                 (guard (condition
                         ((json-error? condition) #t)
                         (else 'wrong-condition))
                   (json-read (open-input-string \"{\\\"bad\\\":[1,]}\"))
                   'no-error)"
                "#t")

(check-external 'srfi-180-json-write-rejects-non-json-number
                "(import (scheme base) (srfi 180))
                 (guard (condition
                         ((json-error? condition) #t)
                         (else 'wrong-condition))
                   (json-write '((half . 1/2)) (open-output-string))
                   'no-error)"
                "#t")

(check-external 'srfi-180-json-read-character-limit
                "(import (scheme base) (srfi 180))
                 (guard (condition
                         ((json-error? condition) #t)
                         (else 'wrong-condition))
                   (parameterize ((json-number-of-character-limit 4))
                     (json-read (open-input-string \"[1,2,3]\")))
                   'no-error)"
                "#t")

(check-external 'srfi-180-alias-import
                "(import (scheme base) (srfi srfi-180))
                 (json-null? (json-read (open-input-string \"null\")))"
                "#t")

(check-external 'consent-json-import
                "(import (scheme base) (consent json))
                 (json-null? (json-read (open-input-string \"null\")))"
                "#t")

(check-external 'stdlib-json-import
                "(import (scheme base) (stdlib json))
                 (json-null? (json-read (open-input-string \"null\")))"
                "#t")

(check-external 'stdlib-json-read-subset-import
                "(import (scheme base) (stdlib json read))
                 (json-null? (json-read (open-input-string \"null\")))"
                "#t")

(check-external 'stdlib-json-manifest
                "(import (scheme base) (stdlib manifest))
                 (let ((entry (stdlib-manifest-ref '(stdlib json))))
                   (list (cdr (assq 'status entry))
                         (cdr (assq 'implementation-library entry))
                         (cdr (assq 'upstream-license entry))
                         (cdr (assq 'import-aliases entry))))"
                "(direct-portable-implementation (stdlib json) \"MIT\" ((stdlib json) (consent json) (srfi 180) (srfi srfi-180)))")

(check-external 'srfi-128-comparator-behavior
                "(import (scheme base) (stdlib comparator))
                 (let* ((number-comparator (make-comparator real? = < number-hash))
                        (list-comparator
                         (make-list-comparator
                          number-comparator list? null? car cdr))
                        (vector-comparator
                         (make-vector-comparator
                          number-comparator vector? vector-length vector-ref)))
                   (list (comparator? number-comparator)
                         (comparator-ordered? number-comparator)
                         (comparator-hashable? number-comparator)
                         (comparator-test-type number-comparator 3)
                         (=? number-comparator 3 3 3)
                         (<? number-comparator 1 2 3)
                         (>? number-comparator 3 2 1)
                         (<=? number-comparator 1 1 2)
                         (>=? number-comparator 3 3 2)
                         (comparator-if<=>
                          number-comparator 1 2 'less 'same 'greater)
                         (=? list-comparator '(1 2) '(1 2))
                         (<? list-comparator '(1 2) '(1 3))
                         (=? vector-comparator '#(1 2) '#(1 2))
                         (<? vector-comparator '#(1 2) '#(1 2 0))
                         (exact-integer?
                          (comparator-hash number-comparator 42))
                         (< (hash-salt) (hash-bound))))"
                "(#t #t #t #t #t #t #t #t #t less #t #t #t #t #t #t)")

(check-external 'srfi-128-alias-import
                "(import (scheme base) (srfi 128))
                 (let ((string-comparator
                        (make-comparator string? string=? string<? string-hash)))
                   (list (<? string-comparator \"ant\" \"bee\")
                         (=? string-comparator \"same\" \"same\")))"
                "(#t #t)")

(check-external 'srfi-128-portable-alias-import
                "(import (scheme base) (srfi srfi-128))
                 (let ((string-comparator
                        (make-comparator string? string=? string<? string-hash)))
                   (list (<? string-comparator \"ant\" \"bee\")
                         (=? string-comparator \"same\" \"same\")))"
                "(#t #t)")

(check-external 'stdlib-comparator-manifest
                "(import (scheme base) (stdlib manifest))
                 (let ((entry (stdlib-manifest-ref '(stdlib comparator)))
                       (scheme-alias
                        (stdlib-manifest-ref '(scheme comparator)))
                       (alias (stdlib-manifest-ref '(srfi 128)))
                       (portable-alias
                        (stdlib-manifest-ref '(srfi srfi-128))))
                   (list (cdr (assq 'status entry))
                         (cdr (assq 'implementation-library entry))
                         (cdr (assq 'upstream-license entry))
                         (cdr (assq 'local-license entry))
                         (cdr (assq 'import-aliases entry))
                         (cdr (assq 'dependencies entry))
                         (cdr (assq 'target scheme-alias))
                         (cdr (assq 'target alias))
                         (cdr (assq 'target portable-alias))))"
                "(vendored-adapted-implementation (stdlib comparator) \"MIT\" \"MIT\" ((stdlib comparator) (scheme comparator) (srfi 128) (srfi srfi-128)) ((scheme base) (scheme char) (scheme inexact) (scheme complex)) (stdlib comparator) (stdlib comparator) (stdlib comparator))")

(check-external 'base-list-helpers
                "(list (length (append '(1 2) '(3 4)))
                       (cadr '(alpha beta gamma))
                       (equal? '(1 \"x\") '(1 \"x\")))"
                "(4 beta #t)")

(check-external 'records-construct-predicate-access-and-mutate
                "(define-record-type <pare>
                   (kons x y)
                   pare?
                   (x kar set-kar!)
                   (y kdr))
                 (let ((p (kons 1 2)))
                   (set-kar! p 3)
                   (list (pare? p)
                         (pare? (cons 1 2))
                         (kar p)
                         (kdr p)))"
                "(#t #f 3 2)")

(check-external 'circular-equality-terminates
                "(let ((left '#1=(a b . #1#))
                       (right '#2=(a b a b . #2#)))
                   (list (eq? left (cddr left))
                         (equal? left right)))"
                "(#t #t)")

(check-external 'base-scalar-helpers
                "(list (/ 5 2)
                       (abs -4)
                       (modulo -13 4)
                       (square 5)
                       (boolean=? #t (not #f))
                       (string->symbol (symbol->string 'consent)))"
                "(5/2 4 3 25 #t consent)")

(check-external 'numeric-tower-exact-rationals
                "(list (/ 3 4 5)
                       (+ 1/2 1/3)
                       (numerator (/ 6 4))
                       (denominator (/ 6 4))
                       (number->string 42 16)
                       (string->number \"2a\" 16))"
                "(3/20 5/6 3 2 \"2a\" 42)")

(check-external 'numeric-tower-polar-special-values
                "(import (scheme complex))
                 (list (make-polar +inf.0 0)
                       (make-polar 1 +inf.0)
                       (make-polar +nan.0 0))"
                "(+inf.0+nan.0i +nan.0+nan.0i +nan.0+nan.0i)")

(check-external 'base-vector-and-bytevector-helpers
                "(define v (vector 'a 'b 'c))
                 (vector-set! v 1 'changed)
                 (define b (bytevector 1 2 3))
                 (bytevector-u8-set! b 1 9)
                 (list v b)"
                "(#(a changed c) #u8(1 9 3))")

(check-external 'base-derived-string-vector-iteration
                "(let ((chars '())
                       (indexes (make-list 3)))
                   (string-for-each
                    (lambda (c) (set! chars (cons c chars)))
                    \"abc\")
                   (vector-for-each
                    (lambda (index)
                      (list-set! indexes index (* index index)))
                    '#(0 1 2))
                   (list
                    (string-map
                     (lambda (c) c)
                     \"HAL\")
                    chars
                    (vector-map + '#(1 2 3) '#(4 5 6 7))
                    indexes))"
                "(\"HAL\" (#\\c #\\b #\\a) #(5 7 9) (0 1 4))")

(check-external 'base-higher-order-helpers
                "(define total 0)
                 (for-each (lambda (x) (set! total (+ total x))) '(1 2 3))
                 (list (apply + 1 '(2 3 4))
                       (map (lambda (x) (* x x)) '(2 3 4))
                       total)"
                "(10 (4 9 16) 6)")

(check-external 'sequence-length-primitives-return-agent-numbers
                "(list
                   (string-length \"abc\")
                   (vector-length '#(a b c d))
                   (bytevector-length #u8(1 2 3 4 5)))"
                "(3 4 5)")

(check-result-external 'multiple-values-result
                       "(values 1 2)"
                       "(evaluation-result (status values) (values (1 2)) (events ()) (budget (steps-used 5) (host-calls 1)))")

(check-result-contains 'debugger-unbound-variable-result
                       "missing"
                       '("(status error)"
                         "(condition (type unbound-variable)"
                         "(symbol missing)"
                         "(phase evaluation)"
                         "(stack ((frame (id f-0)"
                         "(environment ((frame f-0)"
                         "(restarts ((restart (id abort)"))

(check-result-contains 'debugger-private-procedure-docstring-result
                       "(define (private-helper x)
                          \"Explain the private helper for debugger inspection.\"
                          x)
                        missing"
                       '("(binding (name private-helper) (procedure-documentation"
                         "(subject (procedure))"
                         "(origin (body-literal string))"
                         "(documentation \"Explain the private helper for debugger inspection.\")")
                       '((docstring-retention . full)))

(check-result-contains 'debugger-current-error-restarts
                       "(import (scheme base) (agent debugger))
                        (with-exception-handler
                         (lambda (condition)
                           (condition-restarts (current-error)))
                         (lambda ()
                           (raise-continuable 'boom)))"
                       '("(status ok)"
                         "(restart (id abort)"
                         "(restart (id continue-with-warning)"))

(check-result-contains 'debugger-yield-event
                       "(import (scheme base) (agent debugger))
                        (debugger-yield
                         '(condition
                           (type synthetic)
                           (message \"example\")))
                        'done"
                       '("(status ok)"
                         "(value done)"
                         "(events ((debugger (condition (type synthetic) (message \"example\")))))"))

(check-external 'multiple-values-binding-forms
                "(let ((a 'a) (b 'b) (x 'x) (y 'y))
                   (let*-values (((a b) (values x y))
                                 ((x y) (values a b)))
                     (list a b x y)))"
                "(x y x y)")

(check-external 'call-with-values-consumer
                "(call-with-values (lambda () (values 4 5))
                                   (lambda (a b) (- b a)))"
                "1")

(check-external 'define-values-top-level
                "(define-values (root remainder)
                   (exact-integer-sqrt 10))
                 (define-values (head . tail)
                   (values 'a 'b 'c))
                 (define-values all
                   (values 1 2 3))
                 (list root remainder head tail all)"
                "(3 1 a (b c) (1 2 3))")

(check-external 'define-values-internal
                "((lambda ()
                    (define-values (left right)
                      (values 'l 'r))
                    (list left right)))"
                "(l r)")

(check-external 'base-features-parameters-and-utf8
                "(let ((available (features))
                       (setting (make-parameter 'outer)))
                   (let ((bytes (string->utf8 \"agent\")))
                     (list (pair? (memq 'r7rs available))
                           (pair? (memq 'consent available))
                           (setting)
                           (parameterize ((setting 'inner))
                             (setting))
                           (setting)
                           bytes
                           (utf8->string bytes)
                           (utf8->string bytes 1 4))))"
                "(#t #t outer inner outer #u8(97 103 101 110 116) \"agent\" \"gen\")")

(check-external 'call/cc-escape
                "(call/cc (lambda (escape) (+ 1 (escape 42))))"
                "42")

(check-external 'dynamic-wind-exit
                "(let ((path '()))
                   (define (add tag) (set! path (cons tag path)))
                   (call/cc
                    (lambda (escape)
                      (dynamic-wind
                       (lambda () (add 'before))
                       (lambda ()
                         (add 'during)
                         (escape 'done))
                       (lambda () (add 'after)))))
                   (reverse path))"
                "(before during after)")

(check-external 'call/cc-reenter-after-return
                "(let ((again #f))
                   (let ((value (call/cc
                                 (lambda (k)
                                   (set! again k)
                                   'first))))
                     (if (eq? value 'first)
                         (again 'second)
                         value)))"
                "second")

(check-external 'call/cc-repeated-invocation
                "(let ((again #f)
                       (seen '()))
                   (let ((value (call/cc
                                 (lambda (k)
                                   (set! again k)
                                   'start))))
                     (set! seen (cons value seen))
                     (if (< (length seen) 3)
                         (again (length seen))
                         (reverse seen))))"
                "(start 1 2)")

(check-external 'dynamic-wind-reentry
                "(let ((again #f)
                       (outside #f)
                       (path '()))
                   (define (add tag) (set! path (cons tag path)))
                   (call/cc
                    (lambda (escape)
                      (set! outside escape)
                      (dynamic-wind
                       (lambda () (add 'before-outer))
                       (lambda ()
                         (dynamic-wind
                          (lambda () (add 'before-inner))
                          (lambda ()
                            (call/cc
                             (lambda (k)
                               (set! again k)
                               'captured))
                            (add 'during-inner)
                            (outside 'escaped))
                          (lambda () (add 'after-inner))))
                       (lambda () (add 'after-outer)))))
                   (if again
                       (let ((resume again))
                         (set! again #f)
                         (resume 'resumed))
                       (reverse path)))"
                "(before-outer before-inner during-inner after-inner after-outer before-outer before-inner during-inner after-inner after-outer)")

(check-external 'call/cc-multiple-values
                "(let ((again #f))
                   (call-with-values
                    (lambda ()
                      (call/cc
                       (lambda (k)
                         (set! again k)
                         (values 1 2))))
                    (lambda (a b)
                      (if (= a 1)
                          (again 3 4)
                          (list a b)))))"
                "(3 4)")

(check-external 'let-values-continuation-multiple-values
                "(let ((again #f))
                   (let-values (((a b)
                                 (call/cc
                                  (lambda (k)
                                    (set! again k)
                                    (values 1 2)))))
                     (if (= a 1)
                         (again 3 4)
                         (list a b))))"
                "(3 4)")

(check-external 'let*-values-continuation-multiple-values
                "(let ((again #f))
                   (let*-values (((a b)
                                  (call/cc
                                   (lambda (k)
                                     (set! again k)
                                     (values 1 2))))
                                 ((c) (+ a b)))
                     (if (= a 1)
                         (again 3 4)
                         (list a b c))))"
                "(3 4 7)")

(check-external 'guard-raise
                "(guard (exn (else (list 'caught exn)))
                   (raise 'boom))"
                "(caught boom)")

(check-external 'raise-continuable
                "(with-exception-handler
                   (lambda (exn) 42)
                   (lambda ()
                     (+ (raise-continuable 'warning) 23)))"
                "65")

(check-external 'error-object
                "(guard (exn
                         ((error-object? exn)
                          (list (error-object-message exn)
                                (error-object-irritants exn))))
                   (error \"bad input\" 'alpha 7))"
                "(\"bad input\" (alpha 7))")

(check-external 'define-syntax-expands-ellipsis
                "(define x 0)
                 (define-syntax unless
                   (syntax-rules ()
                     ((unless test body ...)
                      (if test #f (begin body ...)))))
                 (unless #f
                   (set! x 41)
                   (+ x 1))"
                "42")

(check-external 'introduced-bindings-are-hygienic
                "(define-syntax my-or
                   (syntax-rules ()
                     ((my-or) #f)
                     ((my-or expr) expr)
                     ((my-or expr next ...)
                      (let ((temp expr))
                        (if temp temp (my-or next ...))))))
                 (let ((temp 99))
                   (my-or #f temp))"
                "99")

(check-external 'let-syntax-is-referentially-transparent
                "(let ((x 'outer))
                   (let-syntax ((m (syntax-rules ()
                                     ((m) x))))
                     (let ((x 'inner))
                       (m))))"
                "outer")

(check 'free-template-identifiers-do-not-capture-use-site
       (raises? (lambda ()
                  (consent-eval-source
                   "(define-syntax expose-x
                      (syntax-rules ()
                        ((expose-x) x)))
                    (let ((x 1))
                      (expose-x))")))
       #t)

(check-external 'letrec-syntax-allows-recursive-transformers
                "(letrec-syntax
                     ((my-or
                       (syntax-rules ()
                         ((my-or) #f)
                         ((my-or expr) expr)
                         ((my-or expr next ...)
                          (let ((temp expr))
                            (if temp temp (my-or next ...)))))))
                   (my-or #f #f 7))"
                "7")

(check-external 'named-let-expands-through-letrec
                "(let loop ((n 5) (acc 0))
                   (if (= n 0)
                       acc
                       (loop (- n 1) (+ acc 1))))"
                "5")

;; A `let' with an empty binding list must expand: the bindings pattern
;; ((name val) ...) has to match the empty list of bindings.  Regression for a
;; syntax-rules matcher that rejected pair patterns against () outright.
(check-external 'let-empty-bindings
                "(let () 5)"
                "5")

(check-external 'let-empty-bindings-with-body-definitions
                "(let () (define x 6) (* x 7))"
                "42")

;; Character literals for delimiter and reserved characters: the reader must
;; take the character after #\\ literally even when it is ( ) [ ] or |, and
;; char->integer must yield a usable Consent number, not a raw host integer.
(check-external 'char-literal-open-paren    "(char->integer #\\()" "40")
(check-external 'char-literal-close-paren   "(char->integer #\\))" "41")
(check-external 'char-literal-open-bracket  "(char->integer #\\[)" "91")
(check-external 'char-literal-close-bracket "(char->integer #\\])" "93")
(check-external 'char-literal-pipe          "(char->integer #\\|)" "124")
(check-external 'char-literal-named-space   "(char->integer #\\space)" "32")
(check-external 'char-literal-hex-scalar    "(char->integer #\\x41)" "65")
(check-external 'char->integer-yields-number "(+ 1 (char->integer #\\a))" "98")

(check-external 'cond-arrow-respects-literal-binding
                "(list
                   (cond ((assv 'b '((a 1) (b 2))) => cadr)
                         (else #f))
                   (let ((=> #f))
                     (cond (#t => 'ok))))"
                "(2 ok)")

(check-external 'case-expands-from-base-syntax
                "(list
                   (case (car '(c d))
                     ((a e i o u) 'vowel)
                     ((c d) 'consonant)
                     (else 'other))
                   (case 'b
                     ((a) 'a)
                     ((b c) => (lambda (x) (list x 'hit)))
                     (else #f)))"
                "(consonant (b hit))")

(check-external 'do-expands-nested-ellipses
                "(do ((i 0 (+ i 1))
                      (acc 0 (+ acc i)))
                     ((= i 5) acc))"
                "10")

(check-external 'dotted-patterns-and-templates
                "(define-syntax rest-list
                   (syntax-rules ()
                     ((rest-list first . rest)
                      'rest)))
                 (define-syntax make-pair
                   (syntax-rules ()
                     ((make-pair left right)
                      '(left . right))))
                 (list (rest-list a b c)
                       (make-pair alpha beta))"
                "((b c) (alpha . beta))")

(check-external 'nested-ellipsis-template-expands
                "(define-syntax echo-groups
                   (syntax-rules ()
                     ((echo-groups ((head item ...) ...))
                      '((head item ...) ...))))
                 (echo-groups ((a 1 2) (b 3) (c)))"
                "((a 1 2) (b 3) (c))")

(check-external 'quasiquote-evaluates-unquotes
                "(list
                   (quasiquote (a (unquote (+ 1 2))
                                  (unquote-splicing (list 'b 'c))))
                   (quasiquote #(1 (unquote (+ 1 2))))
                   (quasiquote (outer
                                 (quasiquote
                                  (inner (unquote (+ 1 2))))
                                 (unquote (+ 2 3)))))"
                "((a 3 b c) #(1 3) (outer (quasiquote (inner (unquote (+ 1 2)))) 5))")

(check-external 'cond-expand-selects-base-feature
                "(list
                   (cond-expand (r7rs 'ok) (else 'missing))
                   (cond-expand
                    ((library (scheme base)) 'base)
                    (else 'missing)))"
                "(ok base)")

(check-result-contains 'macroexpand-one-step-record
                       "(import (scheme base) (agent reflect))
                        (define-syntax my-unless
                          (syntax-rules ()
                            ((my-unless test body ...)
                             (if test #f (begin body ...)))))
                        (macroexpand-1 '(my-unless #f 42))"
                       '("(macro-expansion"
                         "(status ok)"
                         "(mode one-step)"
                         "(original (my-unless #f 42))"
                         "(expanded (if #f #f (begin 42)))"
                         "(step (index 1) (macro my-unless)"
                         "(source (origin source)")
                       '((source-metadata . #t)))

(check-external 'macroexpand-does-not-evaluate-expanded-form
                "(import (scheme base) (agent reflect))
                 (define touched #f)
                 (define-syntax run!
                   (syntax-rules ()
                     ((run!) (begin (set! touched #t) 99))))
                 (let ((expansion (macroexpand '(run!))))
                   (list (cadr (assq 'expanded (cdr expansion)))
                        touched))"
                "((begin (set! touched #t) 99) #f)")

(check-result-contains 'macroexpand-budget-errors
                       "(import (scheme base) (agent reflect))
                        (macroexpand
                         '(let loop ((n 1)) (loop n))
                         '((max-steps 1)))"
                       '("(macro-expansion"
                         "(status error)"
                         "(type budget-exhausted)"
                         "(phase macro-expansion)"))

;;;; Comprehensive evaluation budgets (#51)
;;
;; The single inspectable budget ledger and its explicit exhaustion reason
;; ("stop receipt"), the new output-byte and wall-time dimensions, and the
;; current-budget / budget-remaining / budget-exhausted? / budget-yield /
;; with-budget procedures.  Folded into this file so the cases share its one
;; runtime load rather than paying a separate per-file host-process load.

;; The ledger reports every enforced and reserved dimension plus the reason.
(check-result-contains 'budget-ledger-shape
                       "(import (scheme base) (agent reflect)) (current-budget)"
                       '("(steps-used " "(max-steps 100000)"
                         "(host-calls " "(max-host-calls 10000)"
                         "(events-used " "(max-events 1000)"
                         "(max-event-nodes 100000)"
                         "(value-nodes-used " "(max-value-nodes 10000000)"
                         "(interned-symbols-used "
                         "(max-interned-symbols 1000000)"
                         "(output-bytes-used " "(max-output-bytes 10485760)"
                         "(max-wall-time-ms #f)" "(reason #f)"))

;; A string->symbol flood halts on the interned-symbols dimension rather than
;; growing the intern table without limit; with a generous step budget the
;; interned-symbol budget is the binding constraint and is named in the receipt.
(check-result-contains 'budget-interned-symbol-flood-reason
                       "(import (scheme base))
                        (let loop ((i 0))
                          (string->symbol (number->string i))
                          (loop (+ i 1)))"
                       '("(type budget-exhausted)"
                         "(reason interned-symbols)")
                       '((max-interned-symbols . 100)
                         (max-steps . 1000000)))

;; Step exhaustion halts with a budget-exhausted reason of `steps'.
(check-result-contains 'budget-step-exhaustion-reason
                       "(import (scheme base))
                        (let loop ((i 0)) (loop (+ i 1)))"
                       '("(type budget-exhausted)" "(reason steps)")
                       '((max-steps . 200)))

;; A tail-recursive loop consumes the step budget without growing host stack;
;; reaching a stop receipt at all proves the trampoline stayed iterative.
(check-result-contains 'budget-tail-loop-bounded-by-steps
                       "(import (scheme base)) (let loop () (loop))"
                       '("(type budget-exhausted)")
                       '((max-steps . 1000)))

;; Host-callback exhaustion names the `host-callbacks' dimension.
(check-result-contains 'budget-host-callback-exhaustion-reason
                       "(import (scheme base))
                        (let loop ((i 0)) (loop (+ i 1)))"
                       '("(reason host-callbacks)")
                       '((max-host-callbacks . 10)))

;; Printed-output exhaustion names the `output-bytes' dimension.
(check-result-contains 'budget-output-exhaustion-reason
                       "(import (scheme base) (scheme write))
                        (let ((port (open-output-string)))
                          (let loop ((i 0))
                            (write-string \"xxxxx\" port) (loop (+ i 1))))"
                       '("(reason output-bytes)")
                       '((max-output-bytes . 32)))

;; Yielded-event exhaustion names the `events' dimension.
(check-result-contains 'budget-yield-exhaustion-reason
                       "(import (scheme base) (agent io))
                        (let loop ((i 0)) (agent-yield i) (loop (+ i 1)))"
                       '("(reason events)")
                       '((max-events . 4)))

;; Wall-time exhaustion uses an injected deterministic clock that advances
;; 100 milliseconds per reading and names the `wall-time' dimension.
(define budget-wall-clock-tick 0)
(define (budget-stub-wall-clock)
  (set! budget-wall-clock-tick (+ budget-wall-clock-tick 100))
  budget-wall-clock-tick)
(check-result-contains 'budget-wall-time-exhaustion-reason
                       "(import (scheme base))
                        (let loop ((i 0)) (loop (+ i 1)))"
                       '("(reason wall-time)")
                       (list (cons 'max-wall-time-ms 250)
                             (cons 'wall-clock budget-stub-wall-clock)))

;; with-budget tightens for its dynamic extent, halting on the step budget.
(check-result-contains 'budget-with-budget-tightens-steps
                       "(import (scheme base) (agent reflect))
                        (with-budget '(budget (steps 50))
                          (let loop ((i 0)) (loop (+ i 1))))"
                       '("(reason steps)"))

;; After a normally completing with-budget the outer ceiling is restored.
(check-result-contains 'budget-with-budget-restores-ceiling
                       "(import (scheme base) (agent reflect))
                        (with-budget '(budget (steps 50)) (+ 1 2))
                        (current-budget)"
                       '("(max-steps 100000)"))

;; budget-remaining reports headroom per enforced dimension and no reason.
(check-result-contains 'budget-remaining-headroom
                       "(import (scheme base) (agent reflect))
                        (budget-remaining)"
                       '("(budget-remaining " "(steps "
                         "(interned-symbols " "(output-bytes "
                         "(reason #f)")
                       '((max-steps . 1000)))

;; budget-exhausted? classifies condition and evaluation-result error datums.
(check-external 'budget-exhausted-true
                "(import (scheme base) (agent reflect))
                 (budget-exhausted? '(condition (type budget-exhausted)))"
                "#t")
(check-external 'budget-exhausted-false
                "(import (scheme base) (agent reflect))
                 (budget-exhausted? '(condition (type evaluation-error)))"
                "#f")
(check-external 'budget-exhausted-result-datum
                "(import (scheme base) (agent reflect))
                 (budget-exhausted?
                   '(evaluation-result (status error)
                      (error (condition (condition (type budget-exhausted))))))"
                "#t")

;; budget-yield emits the current ledger as an observable yield event.
(check-result-contains 'budget-yield-emits-ledger
                       "(import (scheme base) (agent reflect))
                        (budget-yield)
                        (recent-yields)"
                       '("(yield (budget "))

(check-external 'macroexpand-expands-local-syntax-scope
                "(import (scheme base) (agent reflect))
                 (let ((expansion
                        (macroexpand
                         '(let-syntax
                              ((twice
                                (syntax-rules ()
                                  ((twice value) (+ value value)))))
                            (twice 21)))))
                   (list (cadr (assq 'expanded (cdr expansion)))
                         (cadr (assq 'macros (cdr expansion)))))"
                "((begin (+ 21 21)) (let-syntax))")

(check-external/options 'macro-binding-info-and-syntax-source
                "(import (scheme base) (agent reflect))
                 (define-syntax twice
                   (syntax-rules ()
                     ((twice value) (+ value value))))
                 (list (macro-binding-info 'twice)
                       (macro-binding-info 'missing)
                       (let ((source (syntax-source '(twice 21))))
                         (list (cadr (assq 'origin (cdr source)))
                               (cadr (assq 'phase (cdr source)))))
                       (syntax-source (list 'twice 21))
                       (equal? '(twice 21) (list 'twice 21)))"
                '((source-metadata . #t))
                "((macro-binding (identifier twice) (status bound) (kind syntax-rules) (library #f)) #f (source read) #f #t)")

(check-external/options 'macro-binding-info-and-syntax-source-opt-out
                "(import (scheme base) (agent reflect))
                 (define-syntax twice
                   (syntax-rules ()
                     ((twice value) (+ value value))))
                 (list (macro-binding-info 'twice)
                       (macro-binding-info 'missing)
                       (syntax-source '(twice 21))
                       (syntax-source (list 'twice 21))
                       (equal? '(twice 21) (list 'twice 21)))"
                '((source-metadata . #f))
                "((macro-binding (identifier twice) (status bound) (kind syntax-rules) (library #f)) #f #f #f #t)")

(check 'import-scheme-base-into-empty-environment
       (consent-value->external
        (consent-eval-source
         "(import (scheme base))
          (+ 1 2)"
         (consent-make-empty-environment)))
       "3")

(check-external 'define-library-import-export
                "(define-library (consent fixture math)
                   (export answer)
                   (import (scheme base))
                   (begin
                     (define answer 42)))
                 (import (consent fixture math))
                 answer"
                "42")

(check-external 'library-import-set-modifiers
                "(define-library (consent fixture modifiers)
                   (export add sub hidden)
                   (import (scheme base))
                   (begin
                     (define (add x y) (+ x y))
                     (define (sub x y) (- x y))
                     (define hidden 99)))
                 (import (only (consent fixture modifiers) add)
                         (except
                          (prefix (consent fixture modifiers) lib-)
                          lib-hidden)
                         (rename
                          (consent fixture modifiers)
                          (sub minus)))
                 (list (add 1 2)
                       (lib-add 3 4)
                       (lib-sub 10 6)
                       (minus 8 5))"
                "(3 7 4 3)")

(check-external 'library-export-rename
                "(define-library (consent fixture export-rename)
                   (export (rename internal external))
                   (import (scheme base))
                   (begin
                     (define internal 42)))
                 (import (consent fixture export-rename))
                 external"
                "42")

(check-external 'emacs-capability-import-empty
                "(import (emacs buffer)
                         (emacs diff)
                         (emacs frame)
                         (emacs process))
                 'ok"
                "ok")

(check 'conflicting-library-imports
       (raises?
        (lambda ()
          (consent-eval-source
           "(define-library (consent fixture left)
              (export value)
              (import (scheme base))
              (begin (define value 'left)))
            (define-library (consent fixture right)
              (export value)
              (import (scheme base))
              (begin (define value 'right)))
            (import (consent fixture left)
                    (consent fixture right))
            value")))
       #t)

(check-external 'exported-library-macro-keeps-scope
                "(define-library (consent fixture syntax)
                   (export choose)
                   (import (scheme base))
                   (begin
                     (define default 'library)
                     (define-syntax choose
                       (syntax-rules ()
                         ((choose) default)))))
                 (import (scheme base)
                         (consent fixture syntax))
                 (let ((default 'program))
                   (choose))"
                "library")

(check-external 'library-cond-expand-declaration
                "(define-library (consent fixture conditional)
                   (cond-expand
                     ((library (scheme base))
                      (export answer)
                      (import (scheme base))
                      (begin (define answer 42)))
                     (else
                      (export answer)
                      (begin (define answer 'missing)))))
                 (import (consent fixture conditional))
                 answer"
                "42")

(check 'include-declarations-are-policy-gated
       (raises?
       (lambda ()
         (consent-eval-source
          "(define-library (consent fixture include)
             (export answer)
             (import (scheme base))
             (include \"fixtures/r7rs/conformance-cases.scm\"))")))
       #t)

;; Include policy options grant this portable test runner access to fixture
;; files while preserving the evaluator's default-deny host policy cases.
(define include-policy-options
  '((include-directory . ".")
    (include-paths . ("fixtures/r7rs"))
    (file-paths . ("fixtures/r7rs"))))

;; First-class file grants are the portable capability vocabulary for the same
;; fixture reads that legacy path allow-lists covered while bootstrapping.
(define file-grant-options
  '((include-directory . ".")
    (capability-grants
     (capability-grant
      (id portable-file-grant)
      (domain file)
      (operations metadata read include include-ci load library-source)
      (scope (project-root ".")
             (paths ("fixtures/r7rs"))
             (remote denied)
             (symlinks resolve-within-root))
      (expires never)))))

;; Host-side temporary file path used for portable delete-file coverage.
(define delete-test-path "tests/scheme/scratch/consent-delete-capability.scm")

;; Host-side temporary paths used for portable file port capability coverage.
(define port-test-input-path "tests/scheme/scratch/consent-port-input.scm")
;; Host-side temporary file path used for portable open-output-file coverage.
(define port-test-output-path "tests/scheme/scratch/consent-port-output.scm")
;; Host-side temporary file path used for portable call-with-output-file coverage.
(define port-test-call-output-path "tests/scheme/scratch/consent-port-call-output.scm")
;; Host-side temporary file path used for portable with-output-to-file coverage.
(define port-test-with-output-path "tests/scheme/scratch/consent-port-with-output.scm")
;; Host-side temporary file path used for portable close-limit coverage.
(define port-test-close-output-path "tests/scheme/scratch/consent-port-close-output.scm")
;; Host-side temporary input file path used for portable binary port coverage.
(define port-test-binary-input-path "tests/scheme/scratch/consent-port-input.bin")
;; Host-side temporary output file path used for portable binary port coverage.
(define port-test-binary-output-path "tests/scheme/scratch/consent-port-output.bin")

;; First-class file grant that allows the portable evaluator to delete only
;; the host-side temporary file above, plus metadata checks after deletion.
(define delete-file-grant-options
  '((include-directory . "tests/scheme/scratch")
    (capability-grants
     (capability-grant
      (id portable-delete-grant)
      (domain file)
      (operations metadata delete)
      (scope (file-root "tests/scheme/scratch")
             (paths ("consent-delete-capability.scm"))
             (remote denied)
             (symlinks resolve-within-root))
      (expires never)))))

;; A session id marks portable evaluation as an authorized REPL-style
;; interaction context without exposing any host adapter state.
(define repl-session-options
  '((session-id . portable-repl)))

;; Session context alone is not enough when policy denies standard host effects.
(define repl-session-denied-options
  '((session-id . portable-repl-denied)
    (policy-actions
     (standard-host-effect . deny))))

;; Clock grants authorize policy-gated `(scheme time)` host observations.
(define clock-grant-options
  '((capability-grants
     (capability-grant
      (id portable-clock-grant)
      (domain clock)
      (operations read)
      (scope (clock system))
      (expires never)))))

;; First-class process grants are host-neutral request/decision vocabulary.
;; Host adapters decide whether to connect the authorization to a real child
;; process; the portable runtime owns the datum shape and grant matching.
(define process-grant-options
  '((policy-actions
     (command-process . allow)
     (emacs-read-only . allow))
    (capability-grants
     (capability-grant
      (id portable-process-grant)
      (domain process)
      (operations spawn observe output input terminate)
      (scope (command "portable-process")
             (working-directory "/tmp")
             (environment ("OPENAI_API_KEY")))
      (expires never)))))

;; Process grant without policy allow action proves policy still gates spawns.
(define process-grant-without-policy-options
  '((capability-grants
     (capability-grant
      (id portable-process-grant)
      (domain process)
      (operations spawn)
      (scope (command "portable-process"))
      (expires never)))))

;; Process request resource with secrets exercises redaction in audit events.
(define portable-process-resource
  '((command "portable-process")
    (arguments ("--token=sk-portable-process1234567890"))
    (cwd "/tmp")
    (environment (("OPENAI_API_KEY" "sk-portable-env1234567890")))))

;; Process request resource that reaches policy without secret-bearing fields.
(define portable-process-policy-resource
  '((command "portable-process")
    (arguments ())
    (cwd "/tmp")))

;; Process request resource whose command intentionally misses grant scope.
(define portable-process-command-mismatch-resource
  '((command "other-process")
    (arguments ())
    (cwd "/tmp")))

;; First-class network grants are host-neutral request/decision vocabulary.
;; Host adapters decide whether to connect the authorization to real transport;
;; the portable runtime owns the datum shape, grant matching, and audit records.
(define network-grant-options
  '((policy-actions
     (network-access . allow))
    (capability-grants
     (capability-grant
      (id portable-network-grant)
      (domain network)
      (operations request stream)
      (scope (schemes ("https"))
             (hosts ("api.example.test"))
             (ports (443))
             (methods (GET POST))
             (header-classes (metadata))
             (payload-classes (public redacted))
             (max-response-bytes 64)
             (max-redirects 0)
             (max-timeout-ms 1000)
             (stream-lifetime-ms 5000))
      (expires never)))))

;; Network grant without policy allow action proves policy still gates egress.
(define network-grant-without-policy-options
  '((capability-grants
     (capability-grant
      (id portable-network-grant)
      (domain network)
      (operations request)
      (scope (schemes ("https"))
             (hosts ("api.example.test"))
             (ports (443))
             (methods (GET))
             (header-classes (metadata))
             (payload-classes (public))
             (max-response-bytes 64))
      (expires never)))))

;; Network request resource with secrets exercises redaction in audit events.
(define portable-network-resource
  '((url "https://api.example.test/v1")
    (scheme "https")
    (host "api.example.test")
    (port 443)
    (method POST)
    (headers (("X-Trace" "ok")))
    (header-classes (metadata))
    (payload "token sk-portable-network1234567890")
    (payload-class public)
    (response-size 64)
    (redirects 0)
    (timeout-ms 50)))

;; Network request resource whose host intentionally misses grant scope.
(define portable-network-host-mismatch-resource
  '((url "https://other.example.test/v1")
    (scheme "https")
    (host "other.example.test")
    (port 443)
    (method POST)
    (header-classes (metadata))
    (payload-class public)
    (response-size 64)
    (redirects 0)))

;; First-class file grants for host-backed file port reads and creations.
(define file-port-grant-options
  '((include-directory . "tests/scheme/scratch")
    (capability-grants
     (capability-grant
      (id portable-port-grant)
      (domain file)
      (operations read create)
      (scope (file-root "tests/scheme/scratch")
             (paths ("consent-port-input.scm"
                     "consent-port-output.scm"
                     "consent-port-call-output.scm"
                     "consent-port-with-output.scm"
                     "consent-port-input.bin"
                     "consent-port-output.bin"))
             (remote denied)
             (symlinks portable-unresolved))
      (expires never)))))

(check-external/options 'include-reads-policy-allowed-body
                        "(define-library (consent fixture include-body)
                           (export answer)
                           (import (scheme base))
                           (include \"fixtures/r7rs/include-body.scm\"))
                         (import (consent fixture include-body))
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'include-ci-folds-policy-allowed-body
                        "(define-library (consent fixture include-ci-body)
                           (export mixedanswer)
                           (import (scheme base))
                           (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
                         (import (consent fixture include-ci-body))
                         mixedanswer"
                        include-policy-options
                        "42")

(check-external/options 'include-library-declarations-splice
                        "(define-library
                           (consent fixture included-declarations)
                           (include-library-declarations
                            \"fixtures/r7rs/include-library-declarations.scm\"))
                         (import
                          (consent fixture included-declarations))
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'include-file-grant-allowed-body
                        "(define-library (consent fixture include-body)
                           (export answer)
                           (import (scheme base))
                           (include \"fixtures/r7rs/include-body.scm\"))
                         (import (consent fixture include-body))
                         answer"
                        file-grant-options
                        "42")

(check-external/options 'include-ci-file-grant-allowed-body
                        "(define-library (consent fixture include-ci-body)
                           (export mixedanswer)
                           (import (scheme base))
                           (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
                         (import (consent fixture include-ci-body))
                         mixedanswer"
                        file-grant-options
                        "42")

(check-external 'standard-case-lambda-import
                "(import (scheme base) (scheme case-lambda))
                 ((case-lambda
                    ((x) x)
                    ((x y) (+ x y)))
                  1 2)"
                "3")

(check-external 'standard-case-lambda-rest-import
                "(import (scheme base) (scheme case-lambda))
                 (list
                  ((case-lambda
                     ((x) x)
                     ((x y . rest) (list x y rest)))
                   1 2 3 4)
                  ((case-lambda
                     (all all))
                   'a 'b))"
                "((1 2 (3 4)) (a b))")

(check-external 'standard-char-and-cxr-imports
                "(import (scheme base) (scheme char) (scheme cxr))
                 (list (char-upcase #\\a)
                       (char-downcase #\\Z)
                       (char-foldcase #\\A)
                       (char-alphabetic? #\\A)
                       (char-numeric? #\\9)
                       (char-whitespace? #\\space)
                       (digit-value #\\9)
                       (char-ci=? #\\A #\\a)
                       (string-upcase \"Az\")
                       (string-ci<? \"abc\" \"BCD\")
                       (cadddr '(a b c d e)))"
                "(#\\A #\\z #\\a #t #t #t 9 #t \"AZ\" #t d)")

(check-external 'standard-inexact-transcendentals
                "(import (scheme inexact))
                 (list (sqrt 9)
                       (sin 0)
                       (cos 0)
                       (tan 0)
                       (exp 0)
                       (log 1))"
                "(3.0 0.0 1.0 0.0 1.0 0.0)")

(check-external 'standard-lazy-import-memoizes
                "(import (scheme base) (scheme lazy))
                 (let ((count 0))
                   (let ((promise
                          (delay
                            (begin
                              (set! count (+ count 1))
                              count))))
                     (list (force promise)
                           (force promise)
                           count)))"
                "(1 1 1)")

(check-external 'standard-write-import-string-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (display \"ok\" out)
                   (get-output-string out))"
                "\"ok\"")

(check-external 'standard-write-shared-output
                "(import (scheme base) (scheme write))
                 (let ((x (list 'a)))
                   (let ((out (open-output-string)))
                     (write-shared (list x x) out)
                     (get-output-string out)))"
                "\"(#0=(a) #0#)\"")

(check-external 'standard-write-circular-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (write '#1=(a . #1#) out)
                   (get-output-string out))"
                "\"#0=(a . #0#)\"")

(check-external 'standard-write-simple-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (write-simple '#(1 \"x\") out)
                   (get-output-string out))"
                "\"#(1 \\\"x\\\")\"")

(check-external 'standard-write-record-output
                "(import (scheme base) (scheme write))
                 (define-record-type <pare>
                   (kons x y)
                   pare?
                   (x kar)
                   (y kdr))
                 (let ((out (open-output-string)))
                   (write (kons 1 2) out)
                   (get-output-string out))"
                "\"#<record <pare>>\"")

(check-external 'standard-string-ports-read-and-write
                "(import (scheme base) (scheme read) (scheme write))
                 (let ((in (open-input-string \"(alpha 1) \"))
                       (out (open-output-string)))
                   (write (read in) out)
                   (write-char (read-char in) out)
                   (list (get-output-string out)
                         (eof-object? (read in))))"
                "(\"(alpha 1) \" #t)")

(check-external 'standard-string-port-read-write-round-trip
                "(import (scheme base) (scheme read) (scheme write))
                 (let ((out (open-output-string)))
                   (write '(a \"b\" #u8(1 2)) out)
                   (read (open-input-string (get-output-string out))))"
                "(a \"b\" #u8(1 2))")

(check-external 'standard-bytevector-ports-read-and-write
                "(import (scheme base))
                 (let ((in (open-input-bytevector #u8(1 2 3)))
                       (out (open-output-bytevector)))
                   (write-u8 (read-u8 in) out)
                   (write-bytevector (read-bytevector 4 in) out)
                   (list (eof-object? (read-u8 in))
                         (get-output-bytevector out)))"
                "(#t #u8(1 2 3))")

(check-external 'standard-eval-import-evaluates-scheme
                "(import (scheme base) (scheme eval))
                 (eval '(* 7 3) (environment '(scheme base)))"
                "21")

(check 'standard-eval-immutable-environment-rejects-definition
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme eval))
            (eval '(define foo 32) (environment '(scheme base)))")))
       #t)

(check-external/options 'standard-repl-interaction-environment-mutates-session
                        "(import (scheme base) (scheme eval) (scheme repl))
                         (eval '(define portable-repl-value 42)
                               (interaction-environment))
                         portable-repl-value"
                        repl-session-options
                        "42")

(check 'standard-repl-interaction-environment-policy-denied
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme repl))
            (interaction-environment)"
           #f
           repl-session-denied-options)))
       #t)

(check 'standard-load-default-denied
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme load))
            (load \"fixtures/r7rs/include-body.scm\")")))
       #t)

(check-external/options 'standard-load-policy-allowed
                        "(import (scheme base) (scheme load))
                         (load \"fixtures/r7rs/include-body.scm\")
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'standard-load-file-grant-allowed
                        "(import (scheme base) (scheme load))
                         (load \"fixtures/r7rs/include-body.scm\")
                         answer"
                        file-grant-options
                        "42")

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (scheme load))
          (load \"fixtures/r7rs/include-body.scm\")
          answer"
         #f
         file-grant-options))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'domain 'code-loading))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'code-loading))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'code-loading)))
  (check 'standard-load-audits-code-loading-request
         (and request
              decision
              audit
              (equal? (field-value request 'operation) 'load)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value audit 'result) '(ok evaluated))
              #t)
         #t))

(check 'standard-file-import-default-denied
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")))
       #t)

(let* ((result
       (consent-eval-source-result
         "(import (scheme base) (scheme file))
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"))
       (events (field-value result 'events))
       (event (find-event events 'policy-decision)))
  (check 'standard-file-default-denial-audits
         (and event
              (equal? (field-value event 'event) 'policy-decision)
              (equal? (field-value event 'category) 'standard-host-effect)
              (equal? (field-value event 'operation) "file-exists?")
              (equal? (field-value event 'decision) 'denied)
              (equal? (field-value event 'filename)
                      "fixtures/r7rs/conformance-cases.scm")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (scheme time))
          (current-second)"))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'domain 'clock))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'clock))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'clock)))
  (check 'standard-time-default-denial-audits-clock-request
         (and (equal? (field-value result 'status) 'error)
              request
              decision
              audit
              (equal? (field-value request 'operation) 'current-second)
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value audit 'result)
                      '(error "no active clock grant covers request"))
              #t)
         #t))

(check-external/options 'standard-time-clock-grant-allowed
                        "(import (scheme base) (scheme time))
                         (list (real? (current-second))
                               (exact-integer? (current-jiffy))
                               (exact-integer? (jiffies-per-second))
                               (> (jiffies-per-second) 0))"
                        clock-grant-options
                        "(#t #t #t #t)")

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (scheme time))
          (current-jiffy)"
         #f
         clock-grant-options))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'domain 'clock))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'clock))
       (policy (find-event-with-field
                events 'policy-decision 'domain 'clock))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'clock)))
  (check 'standard-time-clock-grant-audits-request-decision-result
         (and (equal? (field-value result 'status) 'ok)
              request
              decision
              policy
              audit
              (equal? (field-value request 'operation) 'current-jiffy)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-clock-grant)
              (equal? (field-value policy 'decision) 'allowed)
              (equal? (car (field-value audit 'result)) 'ok)
              #t)
         #t))

(check-external/options 'standard-file-import-policy-allowed
                        "(import (scheme base) (scheme file))
                         (file-exists?
                          \"fixtures/r7rs/conformance-cases.scm\")"
                        include-policy-options
                        "#t")

(check-external/options 'standard-file-import-file-grant-allowed
                        "(import (scheme base) (scheme file))
                         (file-exists?
                          \"fixtures/r7rs/conformance-cases.scm\")"
                        file-grant-options
                        "#t")

(write-host-test-file delete-test-path "(define old 1)")

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (scheme file))
          (delete-file \"consent-delete-capability.scm\")
          (file-exists? \"consent-delete-capability.scm\")"
         #f
         delete-file-grant-options))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'operation 'delete))
       (decision (find-event-with-field
                  events 'capability-decision 'grant 'portable-delete-grant))
       (audit (find-event-with-field
               events 'capability-audit 'operation 'delete)))
  (check 'standard-delete-file-grant-allowed
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-value->external (field-value result 'value))
               "#f")
              (not (file-exists? delete-test-path))
              request
              decision
              audit
              (equal? (field-value request 'domain) 'file)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value audit 'result) '(ok deleted))
              #t)
         #t))

(let* ((context (new-eval-context process-grant-options))
       (authorization
        (authorize-process-capability
         '(portable process)
         "process-start!"
         context
         'spawn
         portable-process-resource
         '("portable-process")))
       (_audit
        (audit-process-capability-result!
         context
         authorization
         '(handle process-job h-portable-1)
         #f))
       (events (context-audit-events context))
       (request (find-event-with-field
                 events 'capability-request 'domain 'process))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'process))
       (policy (find-event-with-field
                events 'policy-decision 'category 'command-process))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'process))
       (external (consent-result->external (list 'events events))))
  (check 'portable-process-capability-authorizes-and-audits
         (and request
              decision
              policy
              audit
              (equal? (field-value request 'operation) 'spawn)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-process-grant)
              (equal? (field-value policy 'decision) 'allowed)
              (equal? (field-value audit 'result)
                      '(ok (handle process-job h-portable-1)))
              (not (string-contains? external "sk-portable-process"))
              (not (string-contains? external "sk-portable-env"))
              #t)
         #t))

(let* ((context (new-eval-context process-grant-without-policy-options))
       (raised
        (raises?
         (lambda ()
           (authorize-process-capability
            '(portable process)
            "process-start!"
            context
            'spawn
            portable-process-policy-resource
            '("portable-process")))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'process))
       (policy (find-event-with-field
                events 'policy-decision 'category 'command-process)))
  (check 'portable-process-capability-denies-without-policy
         (and raised
              decision
              policy
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value policy 'decision) 'denied)
              #t)
         #t))

(let* ((context (new-eval-context process-grant-options))
       (raised
        (raises?
         (lambda ()
           (authorize-process-capability
            '(portable process)
            "process-start!"
            context
            'spawn
            portable-process-command-mismatch-resource
            '("portable-process")))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'process)))
  (check 'portable-process-capability-denies-command-mismatch
         (and raised
              decision
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value decision 'grant) 'none)
              #t)
         #t))

(check-external 'portable-handle-lifecycle-primitives
                "(import (scheme base) (consent capability))
                 (define process-handle
                   '(handle
                     (id h-portable-1)
                     (kind process-job)
                     (domain process)
                     (status live)))
                 (define port-handle
                   '(port-capability
                     (id p-portable-1)
                     (kind textual-input)
                     (backing process)
                     (operations read close)
                     (grant portable-process-grant)
                     (limits)
                     (path h-portable-1)
                     (status open)))
                 (list (handle-live? process-handle)
                       (handle-kind process-handle)
                       (handle-ref process-handle)
                       (handle-revalidate port-handle)
                       (handle-release! process-handle)
                       (handle-ref 'missing))"
                "(#t process-job (handle (id h-portable-1) (kind process-job) (domain process) (status live)) (port-capability (id p-portable-1) (kind textual-input) (backing process) (operations read close) (grant portable-process-grant) (limits) (path h-portable-1) (status open)) (handle (id h-portable-1) (kind process-job) (domain process) (status released)) #f)")

(check 'portable-process-capability-handle-datums
       (list
        (process-capability-handle
         'h-portable-1
         '((command "portable-process") (arguments ("--safe")))
         'portable-process-grant
         'live)
        (process-port-capability-handle
         'p-portable-1
         'textual-input
         'h-portable-1
         '(read close)
         'portable-process-grant
         '()
         'open))
       '((handle
          (id h-portable-1)
          (kind process-job)
          (domain process)
          (command "portable-process")
          (arguments ("--safe"))
          (grant portable-process-grant)
          (status live))
         (port-capability
          (id p-portable-1)
          (kind textual-input)
          (backing process)
          (operations read close)
          (grant portable-process-grant)
          (limits)
          (path h-portable-1)
          (status open))))

(let* ((context (new-eval-context network-grant-options))
       (authorization
        (authorize-network-capability
         '(portable network)
         "network-http-request"
         context
         'request
         portable-network-resource))
       (_audit
        (audit-network-capability-result!
         context
         authorization
         '(network-response (status 200) (body "ok"))
         #f))
       (events (context-audit-events context))
       (request (find-event-with-field
                 events 'capability-request 'domain 'network))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'network))
       (policy (find-event-with-field
                events 'policy-decision 'category 'network-access))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'network))
       (audit-result (and audit (field-value audit 'result)))
       (external (consent-result->external (list 'events events))))
  (check 'portable-network-capability-authorizes-and-audits
         (and request
              decision
              policy
              audit
              audit-result
              (equal? (field-value request 'operation) 'request)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-network-grant)
              (equal? (field-value policy 'decision) 'allowed)
              (equal? (car audit-result) 'ok)
              (equal? (field-value (cadr audit-result) 'body) "ok")
              (string-contains? external "(status 200)")
              (not (string-contains? external "sk-portable-network"))
              #t)
         #t))

(let* ((context (new-eval-context network-grant-without-policy-options))
       (raised
        (raises?
         (lambda ()
           (authorize-network-capability
            '(portable network)
            "network-http-request"
            context
            'request
            '((url "https://api.example.test/v1")
              (scheme "https")
              (host "api.example.test")
              (port 443)
              (method GET)
              (header-classes (metadata))
              (payload-class public)
              (response-size 64)
              (redirects 0))))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'network))
       (policy (find-event-with-field
                events 'policy-decision 'category 'network-access)))
  (check 'portable-network-capability-denies-without-policy
         (and raised
              decision
              policy
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value policy 'decision) 'denied)
              #t)
         #t))

(let* ((context (new-eval-context network-grant-options))
       (raised
        (raises?
         (lambda ()
           (authorize-network-capability
            '(portable network)
            "network-http-request"
            context
            'request
            portable-network-host-mismatch-resource))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'network)))
  (check 'portable-network-capability-denies-host-mismatch
         (and raised
              decision
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value decision 'grant) 'portable-network-grant)
              #t)
         #t))

(check 'portable-network-capability-handle-datums
       (list
        (network-capability-handle
         'h-network-1
         'req-network
         "https://api.example.test/events"
         'portable-network-grant
         'live)
        (network-port-capability-handle
         'p-network-1
         'textual-input
         'h-network-1
         '(read close)
         'portable-network-grant
         '((reads 2))
         'open))
       '((handle
          (id h-network-1)
          (kind network-stream)
          (domain network)
          (request req-network)
          (url "https://api.example.test/events")
          (grant portable-network-grant)
          (status live))
         (port-capability
          (id p-network-1)
          (kind textual-input)
          (backing network)
          (operations read close)
          (grant portable-network-grant)
          (limits (reads 2))
          (path h-network-1)
          (status open))))

(write-host-test-file port-test-input-path "abc")
(if (file-exists? port-test-output-path)
    (delete-file port-test-output-path))
(if (file-exists? port-test-call-output-path)
    (delete-file port-test-call-output-path))
(if (file-exists? port-test-with-output-path)
    (delete-file port-test-with-output-path))
(if (file-exists? port-test-close-output-path)
    (delete-file port-test-close-output-path))
(write-host-binary-file port-test-binary-input-path '(1 2 3 4 255))
(if (file-exists? port-test-binary-output-path)
    (delete-file port-test-binary-output-path))

(check-external/options 'standard-open-input-file-port-grant-allowed
                        "(import (scheme base) (scheme file))
                         (let ((port (open-input-file
                                      \"consent-port-input.scm\")))
                           (list (input-port? port)
                                 (textual-port? port)
                                 (read-string 2 port)
                                 (read-string 2 port)
                                 (eof-object? (read-char port))))"
                        file-port-grant-options
                        "(#t #t \"ab\" \"c\" #t)")

(check-external/options 'standard-open-output-file-port-grant-allowed
                        "(import (scheme base) (scheme file))
                         (let ((port (open-output-file
                                      \"consent-port-output.scm\")))
                           (write-string \"created\" port)
                           (close-port port)
                           (output-port-open? port))"
                        file-port-grant-options
                        "#f")

(check 'standard-open-output-file-writes-host-file
       (call-with-input-file port-test-output-path
         (lambda (port) (read-string 7 port)))
       "created")

(check-external/options 'standard-file-port-wrappers-use-capabilities
                        "(import (scheme base) (scheme file))
                         (list
                          (call-with-input-file
                           \"consent-port-input.scm\"
                           (lambda (port) (read-string 3 port)))
                          (with-input-from-file
                           \"consent-port-input.scm\"
                           (lambda () (read-string 3)))
                          (begin
                            (call-with-output-file
                             \"consent-port-call-output.scm\"
                             (lambda (port) (write-string \"call\" port)))
                            'call-done)
                          (begin
                            (with-output-to-file
                             \"consent-port-with-output.scm\"
                             (lambda () (write-string \"with\")))
                            'with-done))"
                        file-port-grant-options
                        "(\"abc\" \"abc\" call-done with-done)")

(check 'standard-call-output-file-writes-host-file
       (call-with-input-file port-test-call-output-path
         (lambda (port) (read-string 4 port)))
       "call")

(check 'standard-with-output-file-writes-host-file
       (call-with-input-file port-test-with-output-path
         (lambda (port) (read-string 4 port)))
       "with")

(check 'standard-current-output-port-default-denied
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base))
            (current-output-port)")))
       #t)

(check 'standard-file-port-close-invalidates-handle
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme file))
            (let ((port (open-input-file
                         \"consent-port-input.scm\")))
              (close-port port)
              (read-char port))"
           #f
           file-port-grant-options)))
       #t)

(check 'standard-file-port-revoked-grant-is-stale
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme file) (consent capability))
            (grant-capability!
             '(capability-grant
               (id portable-revoked-port-grant)
               (domain file)
               (operations read)
               (scope (file-root \"tests/scheme/scratch\")
                      (paths (\"consent-port-input.scm\"))
                      (remote denied)
                      (symlinks portable-unresolved))
               (expires never)))
            (let ((port (open-input-file
                         \"consent-port-input.scm\")))
              (grant-revoke! 'portable-revoked-port-grant)
              (read-char port))"
           #f
           '((include-directory . "tests/scheme/scratch")))))
       #t)

(check 'standard-file-port-read-limit-is-enforced
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme file) (consent capability))
            (grant-capability!
             '(capability-grant
               (id portable-limited-port-grant)
               (domain file)
               (operations read)
               (scope (file-root \"tests/scheme/scratch\")
                      (paths (\"consent-port-input.scm\"))
                      (remote denied)
                      (symlinks portable-unresolved))
               (limits (reads 1))
               (expires never)))
            (let ((port (open-input-file
                         \"consent-port-input.scm\")))
              (read-char port)
              (read-char port))"
           #f
           '((include-directory . "tests/scheme/scratch")))))
       #t)

(check-external/options 'standard-file-port-close-limit-allows-close
                        "(import (scheme base) (scheme file)
                                 (consent capability))
                         (grant-capability!
                          '(capability-grant
                            (id portable-close-limited-port-grant)
                            (domain file)
                            (operations create)
                            (scope (file-root \"tests/scheme/scratch\")
                                   (paths
                                    (\"consent-port-close-output.scm\"))
                                   (remote denied)
                                   (symlinks portable-unresolved))
                            (limits (closes 1))
                            (expires never)))
                         (let ((port (open-output-file
                                      \"consent-port-close-output.scm\")))
                           (write-string \"x\" port)
                           (close-port port)
                           (output-port-open? port))"
                        '((include-directory . "tests/scheme/scratch"))
                        "#f")

(check 'standard-file-port-close-limit-writes-host-file
       (call-with-input-file port-test-close-output-path
         (lambda (port) (read-string 1 port)))
       "x")

(check-external/options 'standard-open-binary-file-port-grant-allowed
                        "(import (scheme base) (scheme file))
                         (let ((in (open-binary-input-file
                                    \"consent-port-input.bin\"))
                               (out (open-binary-output-file
                                     \"consent-port-output.bin\")))
                           (write-u8 (read-u8 in) out)
                           (write-bytevector (read-bytevector 4 in) out)
                           (close-port out)
                           (list (binary-port? in)
                                 (eof-object? (read-u8 in))
                                 (output-port-open? out)))"
                        file-port-grant-options
                        "(#t #t #f)")

(check 'standard-open-binary-output-file-writes-host-file
       (read-host-binary-file port-test-binary-output-path)
       '(1 2 3 4 255))

(check 'standard-file-grant-denies-path-traversal
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"fixtures/r7rs/../../AGENTS.md\")"
           #f
           file-grant-options)))
       #t)

(check 'standard-file-grant-denies-url-paths
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"https://example.invalid/source.scm\")"
           #f
           file-grant-options)))
       #t)

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (scheme file))
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
         #f
         file-grant-options))
       (events (field-value result 'events))
       (request (find-event events 'capability-request))
       (decision (find-event events 'capability-decision))
       (handle (find-event-with-field
                events 'capability-handle 'domain 'file))
       (audit (find-event events 'capability-audit)))
  (check 'standard-file-grant-audits-request-decision-result
         (and request
              decision
              handle
              audit
              (equal? (field-value request 'domain) 'file)
              (equal? (field-value request 'operation) 'metadata)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-file-grant)
              (equal? (field-value handle 'kind) 'file)
              (equal? (field-value handle 'grant) 'portable-file-grant)
              (equal? (field-value handle 'status) 'live)
              (equal? (field-value audit 'result) '(ok #t))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (scheme file) (consent capability))
          (grant-revoke! 'portable-file-grant)
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
         #f
         file-grant-options))
       (events (field-value result 'events))
       (revocation (find-event events 'capability-revocation))
       (decision (find-event-with-field
                  events 'capability-decision 'status 'denied)))
  (check 'standard-file-grant-revocation-audits
         (and (equal? (field-value result 'status) 'error)
              revocation
              decision
              (equal? (field-value revocation 'target)
                      '(grant portable-file-grant))
              (equal? (field-value revocation 'status) 'revoked)
              (equal? (field-value decision 'grant) 'portable-file-grant)
              #t)
         #t))

(let* ((result
       (consent-eval-source-result
         "(import (scheme base) (scheme file))
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
         #f
         include-policy-options))
       (events (field-value result 'events))
       (event (find-event events 'policy-decision)))
  (check 'standard-file-policy-allowed-audits
         (and event
              (equal? (field-value event 'event) 'policy-decision)
              (equal? (field-value event 'category) 'standard-host-effect)
              (equal? (field-value event 'operation) "file-exists?")
              (equal? (field-value event 'decision) 'allowed)
              (equal? (field-value event 'filename)
                      "fixtures/r7rs/conformance-cases.scm")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent io))
          (agent-yield '(first 1))
          (agent-yield '(second 2))
          42"))
       (events (field-value result 'events)))
  (check 'agent-io-yields-are-ordered-result-events
         (and (equal? (field-value result 'status) 'ok)
              (string=? (consent-value->external
                         (field-value result 'value))
                        "42")
              (string=? (consent-result->external
                         (list 'events events))
                        "(events ((yield (first 1)) (yield (second 2))))")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent io))
          (agent-log 'info \"starting\" '(scope test))
          (agent-progress 'reader '(parsed 2))
          (agent-warn \"careful\" '(kind stale-handle))
          (agent-request '(approval (policy buffer-edit)))
          'done"))
       (events (field-value result 'events)))
  (check 'agent-io-core-events-render-in-result
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-result->external (list 'events events))
               (string-append
                "(events ((log (level info) (message \"starting\") "
                "(fields ((scope test)))) "
                "(progress (phase reader) (datum (parsed 2))) "
                "(warn (message \"careful\") "
                "(fields ((kind stale-handle)))) "
                "(request (approval (policy buffer-edit)))))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent io))
          (agent-yield '(first))
          (agent-yield '(second))
          'unreachable"
         #f
         '((max-events . 1))))
       (events (field-value result 'events))
       (error-field (assq 'error (cdr result))))
  (check 'agent-io-event-count-limit-fails-closed
         (and (equal? (field-value result 'status) 'error)
              (string=? (consent-result->external
                         (list 'events events))
                        "(events ((yield (first))))")
              (string=? (field-value error-field 'message)
                        "consent budget error: event count budget exceeded")
              #t)
         #t))

;; Interpreted guard converts host conditions from primitives into
;; catchable raises, but budget enforcement must stay uncatchable.
(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent io))
          (guard (condition (#t 'swallowed))
            (agent-yield '(first))
            (agent-yield '(second))
            'unreachable)"
         #f
         '((max-events . 1))))
       (error-field (assq 'error (cdr result))))
  (check 'agent-io-event-count-limit-uncatchable-by-guard
         (and (equal? (field-value result 'status) 'error)
              (string=? (field-value error-field 'message)
                        "consent budget error: event count budget exceeded")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent io))
          (agent-yield '(too many nodes))"
         #f
         '((max-event-nodes . 2))))
       (events (field-value result 'events))
       (error-field (assq 'error (cdr result))))
  (check 'agent-io-event-node-limit-fails-closed
         (and (equal? (field-value result 'status) 'error)
              (null? events)
              (string=? (field-value error-field 'message)
                        "consent budget error: event node budget exceeded")
         #t)
         #t))

(let ((external
       (consent-value->external
        (consent-eval-source
         "(import (scheme base) (agent io) (agent reflect))
          (agent-yield '(first 1))
          (list (capability-info 'file-exists?)
                (current-budget)
                (current-imports)
                (recent-yields))"
         #f
         '((max-steps . 777)
           (max-host-callbacks . 66)
           (max-events . 4)
           (max-event-nodes . 44))))))
  (check 'agent-reflect-capability-budget-imports-and-yields
         (and (string-contains? external "(host-capability")
              (string-contains? external "(library (scheme file))")
              (string-contains? external "(name file-exists?)")
              (string-contains? external "(max-steps 777)")
              (string-contains? external "(max-host-calls 66)")
              (string-contains? external "(max-events 4)")
              (string-contains? external "(max-event-nodes 44)")
              (string-contains? external "(agent reflect)")
              (string-contains? external "(yield (first 1))")
              #t)
         #t))

(let ((external
       (consent-value->external
        (consent-eval-source
         "(import (scheme base) (agent io) (agent reflect))
          (agent-yield '((source env)
                         (field \"OPENAI_API_KEY\")
                         (value \"sk-portablereflect1234567890\")))
          (recent-yields)"))))
  (check 'agent-reflect-recent-yields-redacts-secrets
         (and (string-contains? external "(redaction (kind secret)")
              (not (string-contains? external "sk-portablereflect"))
              #t)
         #t))

(check 'agent-diff-proposed-edit-renders
       (consent-eval-source
        "(import (agent diff))
         (diff-render-unified
          (proposed-edit-diff
           '(proposed-edit
             (source buffer)
             (old-label \"before.scm\")
             (new-label \"after.scm\")
             (start 2)
             (end 2)
             (before \"old\")
             (after \"new\"))))")
       "--- before.scm\n+++ after.scm\n@@ -2,1 +2,1 @@\n-old\n+new\n")

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent diff))
          (diff-yield (no-change-diff 'buffer \"scratch\"))
          'ok"))
       (events (field-value result 'events)))
  (check 'agent-diff-yield-records-event
         (and (equal? (field-value result 'status) 'ok)
              (string=? (consent-result->external
                         (list 'events events))
                        (string-append
                         "(events ((yield (diff (source buffer) "
                         "(old-label \"scratch\") "
                         "(new-label \"scratch\") "
                         "(status no-change) (hunks ())))))"))
              #t)
         #t))

(check-external 'agent-vcs-status-parser
                "(import (scheme base) (agent vcs))
                 (define nul (string #\\null))
                 (define status
                   (parse-git-status-porcelain-v2-z
                    (string-append
                     \"# branch.oid abc123\" nul
                     \"# branch.head main\" nul
                     \"# branch.upstream origin/main\" nul
                     \"# branch.ab +2 -1\" nul
                     \"1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb src/main.scm\" nul
                     \"? scratch.scm\" nul)))
                 (define branch (vcs-status-branch status))
                 (define entries (vcs-status-entries status))
                 (list
                  (vcs-field-value branch 'head #f)
                  (vcs-field-value branch 'ahead 0)
                  (vcs-field-value branch 'behind 0)
                  (vcs-field-value (car entries) 'kind #f)
                  (vcs-field-value (car entries) 'path #f)
                  (vcs-field-value (cadr entries) 'kind #f))"
                "(\"main\" 2 1 modified \"src/main.scm\" untracked)")

(check-external 'agent-vcs-raw-diff-parser
                "(import (scheme base) (agent vcs))
                 (define nul (string #\\null))
                 (define diff
                   (parse-git-raw-diff-z
                    (string-append
                     \":100644 100644 abcdef1 1234567 M\" nul
                     \"src/main.scm\" nul)))
                 (let ((file (car (vcs-diff-summary-files diff))))
                   (list
                    (vcs-field-value file 'status #f)
                    (vcs-field-value file 'path #f)
                    (vcs-field-value file 'old-object #f)
                    (vcs-field-value file 'new-object #f)))"
                "(modified \"src/main.scm\" \"abcdef1\" \"1234567\")")

(check-external 'agent-vcs-local-mutation-authorization
                "(import (scheme base) (agent vcs))
                 (define request
                   (make-vcs-capability-request
                    'req-stage
                    'stage
                    'repository-mutation
                    '((repository \"/repo\") (paths (\"src/main.scm\")))))
                 (define denied
                   (vcs-authorize-capability-request request '() '()))
                 (define grant
                   (make-vcs-capability-grant
                    'grant-local
                    'repository-mutation
                    '(stage commit)
                    \"/repo\"
                    #f))
                 (define allowed
                   (vcs-authorize-capability-request request (list grant) '()))
                 (define result
                   (make-vcs-capability-result
                    'req-stage
                    'ok
                    (make-vcs-outcome 'ok \"Staged selected paths.\")))
                 (define audit
                   (make-vcs-capability-audit request allowed result))
                 (list
                  (vcs-mutating-operation? 'stage)
                  (vcs-remote-operation? 'stage)
                  (vcs-operation-required-authority 'stage)
                  (vcs-capability-request? request)
                  (vcs-field-value request 'required-authority #f)
                  (vcs-capability-decision-status denied)
                  (vcs-field-value denied 'reason #f)
                  (vcs-capability-decision-status allowed)
                  (vcs-field-value allowed 'grant #f)
                  (vcs-field-value audit 'event #f)
                  (vcs-field-value audit 'decision #f)
                  (vcs-field-value audit 'result #f)
                  (vcs-field-value audit 'outcome #f))"
                "(#t #f repository-mutation #t repository-mutation denied \"missing VCS mutation grant or approval\" approved grant-local vcs-capability-audit approved ok ok)")

(check-external 'agent-vcs-remote-mutation-authorization
                "(import (scheme base) (agent vcs))
                 (define request
                   (make-vcs-capability-request
                    'req-push
                    'push
                    'remote-mutation
                    '((repository \"/repo\") (remote \"origin\") (branch \"main\"))))
                 (define local-grant
                   (make-vcs-capability-grant
                    'grant-local
                    'repository-mutation
                    '(stage commit)
                    \"/repo\"
                    #f))
                 (define denied
                   (vcs-authorize-capability-request request (list local-grant) '()))
                 (define approval
                   (make-vcs-approval-decision
                    'approve-push
                    'req-push
                    'approved
                    \"User approved push.\"))
                 (define allowed
                   (vcs-authorize-capability-request request '() (list approval)))
                 (define result
                   (make-vcs-capability-result
                    'req-push
                    'error
                    (make-vcs-outcome
                     'remote-authentication-failed
                     \"Remote rejected credentials.\")))
                 (define audit
                   (make-vcs-capability-audit request allowed result))
                 (list
                  (vcs-remote-operation? 'push)
                  (vcs-operation-required-authority 'push)
                  (vcs-capability-decision-status denied)
                  (vcs-capability-decision-status allowed)
                  (vcs-field-value allowed 'approval #f)
                  (vcs-field-value request 'remote? #f)
                  (vcs-field-value audit 'remote? #f)
                  (vcs-field-value audit 'outcome #f)
                  (vcs-known-outcome? 'remote-authentication-failed)
                  (vcs-known-outcome? 'remote-unavailable))"
                "(#t remote-mutation denied approved approve-push #t #t remote-authentication-failed #t #t)")

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent approval))
          (define id
            (approval-request!
             '(approval-request
                (policy buffer-edit)
                (effect (buffer-replace! h-1 1 2 \"x\"))
                (reason \"Replace text?\"))))
          (list id (approval-status id))"))
       (value (field-value result 'value)))
  (check 'agent-approval-request-status
         (and (equal? (field-value result 'status) 'ok)
              (string=? (consent-value->external value)
                        "(a-1 pending)")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent approval))
          (approval-request!
           '(approval-request
              (policy buffer-edit)
              (effect (buffer-delete! h-1 1 2))
              (reason \"Delete text?\")))
          (approval-yield-pending)
          'done"))
       (events (field-value result 'events)))
  (check 'agent-approval-yield-pending
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-result->external (list 'events events))
               (string-append
                "(events ((yield (approval-request (id a-1) "
                "(policy buffer-edit) "
                "(effect (buffer-replace! h-1 1 2 \"x\")) "
                "(reason \"Replace text?\") "
                "(status pending))) "
                "(yield (approval-request (id a-2) "
                "(policy buffer-edit) "
                "(effect (buffer-delete! h-1 1 2)) "
                "(reason \"Delete text?\") "
                "(status pending)))))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent approval))
          (define id
            (approval-request!
             '(approval-request
                (policy buffer-edit)
                (effect (buffer-insert! h-1 1 \"x\"))
                (reason \"Insert text?\"))))
          (approval-resolve! id 'approved)"))
       (error-field (assq 'error (cdr result))))
  (check 'agent-approval-self-approval-denied
         (and (equal? (field-value result 'status) 'error)
              (string=? (field-value error-field 'message)
                        "consent eval error: approval resolution is host-side only")
         #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent redaction))
          (let ((secret '((source env)
                          (field \"OPENAI_API_KEY\")
                          (value \"sk-portableagent1234567890\"))))
            (list (secret-source? secret)
                  (redact secret 'remote-provider)
                  (safe-for-provider? secret 'openai)))"))
       (value (field-value result 'value)))
  (check 'agent-redaction-secret-source-redact-provider
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-value->external value)
               (string-append
                "(#t (redaction (kind secret) (source env) "
                "(field \"OPENAI_API_KEY\") "
                "(replacement \"[redacted]\") "
                "(policy local-only)) #f)"))
              #t)
         #t))

(check-external
 'agent-source-libraries-import-through-portable-registry
 "(import (scheme base)
          (agent diagnostics)
          (agent task)
          (agent models))
  (list (diagnostic-severity
         (make-diagnostic 'warning \"careful\" 'scheme \"source.scm\"
                          #f #f '()))
        (task-state? 'planning)
        (if (pair? (model-providers)) 'providers-ok 'providers-bad))"
 "(warning #t providers-ok)")

(check-external
 'agent-models-register-and-route
 "(import (scheme base) (agent models))
  (model-provider-register!
   '(model-provider
     (id portable-local)
     (kind local)
     (transport openai-compatible-http)
     (endpoint \"http://127.0.0.1:11434/v1\")
     (models
      (((id portable-coder)
        (roles (scheme-scripter code))
        (privacy local))))))
  (model-route 'scheme-scripter '())"
 "(model-routing-decision (status selected) (role scheme-scripter) (provider portable-local) (model portable-coder) (kind local) (transport openai-compatible-http) (endpoint \"http://127.0.0.1:11434/v1\"))")

(check-external/options
 'agent-models-tool-spec-from-docstring-metadata
 "(import (scheme base) (agent models))
  (define (field datum name)
    (let loop ((fields (cdr datum)))
      (cond
       ((null? fields) #f)
       ((eq? (car (car fields)) name) (cadr (car fields)))
       (else (loop (cdr fields))))))
  (define (local-echo text)
    \"Echo TEXT through a pure local helper.\"
    #((parameters
       (text (type string)
        (description \"Text to echo.\")))
      (returns (type string)
       (description \"The echoed text.\"))
      (effects pure))
    text)
  (let ((tool (model-tool-spec 'local-echo)))
    (list (field tool 'name)
          (field tool 'parameters)
          (field tool 'returns)
          (field tool 'effects)
          (field tool 'schema)
          (field tool 'example)
          (field tool 'gate)))"
 '((docstring-retention . full))
 "(local-echo ((text (type string) (description \"Text to echo.\"))) ((type string) (description \"The echoed text.\")) (pure) (openai-tool (type function) (function (name \"local-echo\") (description \"Echo TEXT through a pure local helper.\") (parameters ((type \"object\") (properties ((text ((type \"string\") (description \"Text to echo.\"))))) (required (\"text\")))))) (tool-call (name local-echo) (arguments ((text \"<string>\")))) (tool-gate (decision pure-under-budget) (effects (pure))))")

(check-external/options
 'agent-models-tool-spec-any-schema-default
 "(import (scheme base) (agent models))
  (define (field datum name)
    (let loop ((fields (cdr datum)))
      (cond
       ((null? fields) #f)
       ((eq? (car (car fields)) name) (cadr (car fields)))
       (else (loop (cdr fields))))))
  (define (local-inspect value)
    \"Inspect VALUE locally.\"
    #((parameters (value (type any)))
      (returns (type any))
      (effects pure))
    value)
  (field (model-tool-spec 'local-inspect) 'schema)"
 '((docstring-retention . full))
 "(openai-tool (type function) (function (name \"local-inspect\") (description \"Inspect VALUE locally.\") (parameters ((type \"object\") (properties ((value ((description \"Any Scheme-readable value.\"))))) (required (\"value\"))))))")

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (consent capability))
          (grant-capability!
           '(capability-grant
              (id portable-grant)
              (library (emacs buffer edit))
              (effect buffer-replace!)
              (scope (range 1 2))
              (expires after-eval)))
          (list (grant-ref 'portable-grant)
                (current-grants))"))
       (value (field-value result 'value)))
  (check 'consent-capability-grant-datums
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-value->external value)
               (string-append
                "((capability-grant (id portable-grant) "
                "(library (emacs buffer edit)) "
                "(effect buffer-replace!) (scope (range 1 2)) "
                "(expires after-eval) (status active)) "
                "((capability-grant (id portable-grant) "
                "(library (emacs buffer edit)) "
                "(effect buffer-replace!) (scope (range 1 2)) "
                "(expires after-eval) (status active))))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (consent capability))
          (grant-capability!
           '(capability-grant
              (id portable-parent-grant)
              (library (emacs buffer edit))
              (effect buffer-replace!)
              (scope (range 1 9))
              (expires never)))
          (define child
            (grant-attenuate
             'portable-parent-grant
             '((id portable-child-grant)
               (scope (range 2 4))
               (expires after-eval))))
          (grant-revoke! 'portable-parent-grant)
          (with-capability-grant child
            (grant-ref 'portable-child-grant))"))
       (value (field-value result 'value)))
  (check 'consent-capability-attenuate-revoke-with-grant
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-value->external value)
               (string-append
                "(capability-grant (library (emacs buffer edit)) "
                "(effect buffer-replace!) (scope (range 2 4)) "
                "(expires after-eval) (id portable-child-grant) "
                "(parent portable-parent-grant) (status active))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent memory))
          (memory-put! 'instance
                       'portable-alpha
                       '((tags (portable fact))
                         (value \"portable alpha\")
                         (confidence high)))
          (memory-add! 'project
                       'fact
                       '((tags (project portable))
                         (value \"project portable\")))
          (list (memory-ref 'instance 'portable-alpha)
                (memory-by-tag 'project 'project)
                (memory-find 'instance \"portable alpha\"))"))
       (value (field-value result 'value)))
  (check 'agent-memory-crud-search-tags
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-value->external value)
               (string-append
                "((memory (id portable-alpha) (scope instance) "
                "(key portable-alpha) (kind datum) "
                "(tags (portable fact)) (value \"portable alpha\") "
                "(source ()) (confidence high) (created-at 1) "
                "(updated-at 1)) "
                "((memory (id m-2) (scope project) (key m-2) "
                "(kind fact) (tags (project portable)) "
                "(value \"project portable\") (source ()) "
                "(confidence unknown) (created-at 2) (updated-at 2))) "
                "((memory (id portable-alpha) (scope instance) "
                "(key portable-alpha) (kind datum) "
                "(tags (portable fact)) (value \"portable alpha\") "
                "(source ()) (confidence high) (created-at 1) "
                "(updated-at 1))))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent memory))
          (memory-put! 'instance
                       'portable-yield
                       '((tags (portable))
                         (value \"yield portable\")))
          (memory-yield 'instance \"yield portable\")
          'done"))
       (events (field-value result 'events)))
  (check 'agent-memory-yield-emits-agent-event
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-result->external (list 'events events))
               (string-append
                "(events ((yield (memory (id portable-yield) "
                "(scope instance) (key portable-yield) "
                "(kind datum) (tags (portable)) "
                "(value \"yield portable\") (source ()) "
                "(confidence unknown) (created-at 3) "
                "(updated-at 3)))))"))
         #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent helper))
          (agent-helper-save!
           '(agent helpers portable)
           '((define (portable-helper x) (+ x 1)))
           '((scope project-private)))
          (agent-helper-load '(agent helpers portable)
                             '((scope project-private)))
          (list (portable-helper 41)
                (agent-helper-list 'project-private))"))
       (value (field-value result 'value)))
  (check 'agent-helper-save-list-load
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (consent-value->external value)
               "(42 ((agent-helper-library")
              (string-contains?
               (consent-value->external value)
               "(name (agent helpers portable))")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent helper))
          (agent-artifact
           'example
           '(example (source \"(portable-helper 41)\") (expect \"42\")))
          (agent-helper-save!
           '(agent helpers candidate)
           '((define (portable-candidate) 'ok))
           '((scope project-private)))
          (agent-helper-promote-to-skill
           '(agent helpers candidate)
           '((scope project-private)
             (name \"portable-candidate\")
             (examples ((example (source \"(portable-candidate)\")
                                 (expect \"ok\"))))
             (references ((r7rs \"docs/r7rs-small-report.md\")))
             (tests (((source \"(portable-candidate)\")
                      (expect \"ok\"))))))"))
       (events (field-value result 'events))
       (value (field-value result 'value)))
  (check 'agent-helper-artifact-and-skill-candidate
         (and (equal? (field-value result 'status) 'ok)
              (equal? (car value) 'agent-skill-candidate)
              (string-contains?
               (consent-value->external value)
               "(name \"portable-candidate\")")
              (string-contains?
               (consent-result->external (list 'events events))
               "(yield (agent-artifact")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent test))
          (define run
            (test-group 'portable-arithmetic
              (test-case 'passes (+ 1 1) 2)
              (test-case 'fails (+ 1 1) 3)
              (test-error 'expected-error (error \"boom\") error-object?)))
          (test-run 'portable-arithmetic)"))
       (value (field-value result 'value)))
  (check 'agent-test-group-results
         (and (equal? (field-value result 'status) 'ok)
              (equal? (car value) 'agent-test-group)
              (string-contains?
               (consent-value->external value)
               "(summary (total 3) (pass 2) (fail 1) (error 0) (skipped 0) (budget-exhausted 0))")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent test) (agent io))
          (define run
            (test-group 'portable-yield
              (test-case 'bad (+ 1 1) 3)))
          (test-yield-failures run)
          'done"))
       (events (field-value result 'events)))
  (check 'agent-test-yield-failures
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (consent-result->external (list 'events events))
               "(yield (agent-test-failures")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent test))
          (skill-test
           'portable-skill
           '((name source-pass)
             (source \"(import (scheme base)) (+ 20 22)\")
             (expect \"42\")))
          (skill-test
           'portable-skill
           '(srfi-64 (test-name srfi-pass) (result pass)))
          (skill-test-run 'portable-skill)"))
       (value (field-value result 'value)))
  (check 'agent-test-skill-and-srfi64
         (and (equal? (field-value result 'status) 'ok)
              (equal? (car value) 'agent-test-group)
              (string-contains?
               (consent-value->external value)
               "(kind skill)")
              (string-contains?
               (consent-value->external value)
               "(summary (total 2) (pass 2) (fail 0) (error 0) (skipped 0) (budget-exhausted 0))")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent test))
          (skill-test
           'portable-budget
           '((name budgeted-loop)
             (source \"(define (loop) (loop)) (loop)\")
             (expect ok)
             (options ((max-steps 20)))))
          (skill-test-run 'portable-budget)"))
       (value (field-value result 'value)))
  (check 'agent-test-budget-exhaustion-status
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (consent-value->external value)
               "(status budget-exhausted)")
              (string-contains?
               (consent-value->external value)
               "(summary (total 1) (pass 0) (fail 0) (error 0) (skipped 0) (budget-exhausted 1))")
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent plan))
          (plan-create!
           '(plan
              (id portable-plan)
              (scope project)
              (goal \"Expose portable planning data\")
              (steps (((id first) (status pending))))))
          (plan-step-add!
           'portable-plan
           '((id second) (status pending) (goal \"Check portability\")))
          (plan-step-status! 'portable-plan 'first 'done)
          (plan-status! 'portable-plan 'active)
          (plan-ref 'portable-plan)"))
       (value (field-value result 'value)))
  (check 'agent-plan-crud-step-status
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (consent-value->external value)
               (string-append
                "(plan (id portable-plan) (scope project) "
                "(status active) "
                "(goal \"Expose portable planning data\") "
                "(steps (((id first) (status done)) "
                "((id second) (status pending) "
                "(goal \"Check portability\")))) "
                "(created-at 1) (updated-at 4))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent plan))
          (plan-create!
           '(plan
              (id portable-yield)
              (scope project)
              (goal \"Yield portable plan\")
              (steps ())))
          (plan-yield 'portable-yield)
          'done"))
       (events (field-value result 'events)))
  (check 'agent-plan-yield-emits-agent-event
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (consent-result->external (list 'events events))
               (string-append
                "(yield (plan (id portable-yield) "
                "(scope project) (status pending) "
                "(goal \"Yield portable plan\") (steps ()) "
                "(created-at 5) (updated-at 5)))"))
              #t)
         #t))

(let* ((result
        (consent-eval-source-result
         "(import (scheme base) (agent context))
          (context-yield 'request)
          (list (current-request)
                (current-conversation-summary)
                (current-focus)
                (current-buffer-context))"
         #f
         '((request-id . portable-req)
           (request . "portable context request")
           (conversation-summary . "portable conversation summary"))))
       (events (field-value result 'events))
       (value (field-value result 'value)))
  (check 'agent-context-portable-request-summary-focus-and-yield
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (consent-value->external value)
               "(request-context (request-id portable-req) (request \"portable context request\"))")
              (string-contains?
               (consent-value->external value)
               "(conversation-summary (summary \"portable conversation summary\"))")
              (string-contains?
               (consent-value->external value)
               "(focus-context")
              (string-contains?
               (consent-result->external (list 'events events))
               "(yield (request-context")
              #t)
         #t))

(check 'standard-host-libraries-import-and-default-deny
       (and
        (not
         (raises?
          (lambda ()
            (consent-eval-source
             "(import (scheme process-context) (scheme time) (scheme repl))
              'ok"))))
        (raises?
         (lambda ()
           (consent-eval-source
            "(import (scheme base) (scheme process-context))
             (command-line)")))
        (raises?
         (lambda ()
           (consent-eval-source
            "(import (scheme base) (scheme time))
             (current-second)")))
        (raises?
         (lambda ()
           (consent-eval-source
            "(import (scheme base) (scheme repl))
             (interaction-environment)"))))
       #t)

;; Environment reads are denied by default and supplied only under an explicit
;; process-environment capability grant. An unset variable read under the grant
;; returns #f (no denial), which makes the allow path deterministic.
(check 'process-environment-read-denied-by-default
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme process-context))
            (get-environment-variable \"CONSENT_UNSET_ENV_PROBE\")")))
       #t)

(check-external/options 'process-environment-read-allowed-under-grant
                        "(import (scheme base) (scheme process-context))
                         (get-environment-variable \"CONSENT_UNSET_ENV_PROBE\")"
                        '((capability-grants
                           (capability-grant
                            (id host-environment)
                            (domain process-environment)
                            (operations read)
                            (expires never))))
                        "#f")

;; Self-hosting: the runtime's own internal libraries ((consent ...)/(cli ...))
;; are denied to imported programs by default (fail-closed), and become
;; available only under an explicit internal-libraries-allowed grant -- the
;; capability that lets the compiled runtime act as a full Scheme host runner.
(check 'internal-library-import-denied-by-default
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (consent reader)) 'ok")))
       #t)

;; Under the grant the runtime loads and interprets one of its own internal
;; libraries from source and the imported binding is usable -- the metacircular
;; self-hosting mechanism (resolve -> register-source-library! -> bind). A tiny
;; library keeps this cheap on every portable host; the heavy proof that a full
;; library (the reader) self-hosts lives in the compiled `--host-run' path, where
;; the native interpreter loads it quickly rather than being re-interpreted.
(check-external/options 'internal-library-self-hosts-from-source
                        "(import (consent version))
                         (length consent-version-datum)"
                        '((internal-libraries-allowed . #t))
                        "4")

;; Agent model libraries with public primitive counterparts still need to
;; self-host under the internal-libraries grant so runtime internals can import
;; their portable store helpers.
(check-external/options 'internal-agent-model-library-self-hosts-from-source
                        "(import (agent approval))
                         (consent-approval-store?
                          (consent-make-approval-store))"
                        '((internal-libraries-allowed . #t))
                        "#t")

;; The grant only exposes libraries that actually exist as runtime source; it
;; does not turn every (consent ...) name into a phantom library.
(check 'internal-library-grant-unknown-still-denied
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (consent no-such-internal-library)) 'ok"
           #f
           '((internal-libraries-allowed . #t)))))
       #t)

(check-external 'standard-r5rs-import
                "(import (scheme r5rs))
                 (list (+ 1 2)
                       (exact->inexact 3)
                       (inexact->exact 3.0))"
                "(3 3.0 3)")

(check 'imported-value-set-is-rejected
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base))
            (set! + 1)"
           (consent-make-empty-environment))))
       #t)

(check 'imported-value-define-is-rejected
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base))
            (define + 1)"
           (consent-make-empty-environment))))
       #t)

(check 'imported-syntax-define-is-rejected
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base))
            (define-syntax and
              (syntax-rules ()
                ((and) #t)))"
           (consent-make-empty-environment))))
       #t)

(check 'duplicate-export-names-signal-error
       (raises?
        (lambda ()
          (consent-eval-source
           "(define-library (consent fixture duplicate-export)
              (export value value)
              (import (scheme base))
              (begin (define value 1)))")))
       #t)

(check 'program-imports-precede-body
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base))
            1
            (import (scheme cxr))
            'ok"
           (consent-make-empty-environment))))
       #t)

(check 'expand-source-exposes-expanded-forms
       (consent-value->external
        (consent-expand-source
         "(define-syntax unless
            (syntax-rules ()
              ((unless test body ...)
               (if test #f (begin body ...)))))
          (unless #f 42)"))
       "((if #f #f (begin 42)))")

(check 'syntax-error-reports-source-form
       (let* ((result
               (consent-eval-source-result
                "(define-syntax bad-use
                   (syntax-rules ()
                     ((bad-use x)
                      (syntax-error \"bad macro\" x))))
                 (bad-use 123)"))
              (error-field (assq 'error (cdr result)))
              (message-field (assq 'message (cdr error-field))))
         (cadr message-field))
       "consent eval error: syntax-error while expanding (bad-use 123): \"bad macro\" 123")

(check 'result-rendering
       (consent-result->external
        (consent-eval-source-result "(+ 1 2)"))
       "(evaluation-result (status ok) (value 3) (events ()) (budget (steps-used 5) (host-calls 1)))")

(check-external 'closure
                "(define make-adder
                   (lambda (x)
                     (lambda (y) (+ x y))))
                 ((make-adder 4) 6)"
                "10")
(check-external 'internal-variable-definition
                "((lambda (x)
                    (define y 2)
                    (+ x y))
                  3)"
                "5")
(check-external 'internal-function-definition
                "((lambda (x)
                    (define (twice y) (+ y y))
                    (twice x))
                  5)"
                "10")
(check-external 'internal-definition-shadows-parent
                "((lambda ()
                    (define + (lambda (x y) x))
                    (+ 1 2)))"
                "1")

(let ((parent (consent-make-base-environment))
      (child #f))
  (set! child (consent-make-empty-environment parent))
  (check 'child-definition-shadows-parent
         (consent-value->external
          (consent-eval-source
           "(define + (lambda (x y) y))
            (+ 1 2)"
           child))
         "2")
  (check 'parent-primitive-remains-bound
         (consent-value->external
          (consent-eval-source "(+ 1 2)" parent))
         "3"))

(check-external 'set-mutates-local
                "((lambda (x)
                    (set! x (+ x 1))
                    x)
                  2)"
                "3")
(check-external 'set-mutates-captured
                "(define make-counter
                   (lambda ()
                     (define x 0)
                     (lambda ()
                       (set! x (+ x 1))
                       x)))
                 (define counter (make-counter))
                 (counter)
                 (counter)"
                "2")
(check 'set-unbound
       (raises? (lambda () (consent-eval-source "(set! missing 1)")))
       #t)

(check-external 'scheme-truthiness-false "(if #f 1 2)" "2")
(check-external 'scheme-truthiness-empty-list "(if '() 1 2)" "1")
(check-external 'if-without-alternate "(if #f 1)" "#<unspecified>")

(check-external 'variadic-formals "((lambda x x) 3 4 5)" "(3 4 5)")
(check-external 'dotted-formals
                "((lambda (x y . z) z) 3 4 5 6)"
                "(5 6)")
(check 'duplicate-formals
       (raises? (lambda ()
                  (consent-eval-source "((lambda (x x) x) 1 2)")))
       #t)
(check 'arity-error
       (raises? (lambda ()
                  (consent-eval-source "((lambda (x) x) 1 2)")))
       #t)

(check-external/options 'tail-recursive-loop
                        "(define (loop n acc)
                           (if (= n 0)
                               acc
                               (loop (- n 1) (+ acc 1))))
                         (loop 5000 0)"
                        '((max-steps . 100000)
                          (max-host-callbacks . 30000))
                        "5000")

(check 'step-budget
       (raises?
        (lambda ()
          (consent-eval-source
           "(define (loop n) (loop n))
            (loop 0)"
           #f
           '((max-steps . 40)))))
       #t)
(check 'value-budget
       (raises?
        (lambda ()
          (consent-eval-source
           "'(1 2 3)"
           #f
           '((max-value-nodes . 2)))))
       #t)
(check 'host-callback-budget
       (raises?
        (lambda ()
          (consent-eval-source
           "(+ 1 2)"
           #f
           '((max-host-callbacks . 0)))))
       #t)

;; Program-input stream (docs/repl-interaction-contract.md, "Stream
;; Separation"): a non-interactive evaluation connects `(current-input-port)' to
;; the buffered process input only under an active `port'/`read' grant whose
;; scope is backed by `stdin'.  Without the grant -- or with no program input
;; offered at all -- the read fails closed exactly as an unconnected current
;; input port does.  Parity twin of the Emacs
;; `consent-eval-test-program-input-stream'.
(define program-input-grant
  '(capability-grant (id program-input) (domain port)
                     (operations read close) (scope (backing stdin))
                     (expires never)))
(check-external/options 'program-input-granted-read-line
                        "(read-line)"
                        (list (cons 'program-input-reader
                                    (consent-program-input-from-string
                                     "alpha\nbeta\n"))
                              (list 'capability-grants program-input-grant))
                        "\"alpha\"")
(check-external/options 'program-input-granted-sequence
                        "(list (read-line) (read-line) (read-char)
                               (eof-object? (read-line)))"
                        (list (cons 'program-input-reader
                                    (consent-program-input-from-string "a\nb\nc"))
                              (list 'capability-grants program-input-grant))
                        "(\"a\" \"b\" #\\c #t)")
(check 'program-input-ungranted-denies
       (raises?
        (lambda ()
          (consent-eval-source
           "(read-line)"
           #f
           (list (cons 'program-input-reader
                       (consent-program-input-from-string "alpha\n"))))))
       #t)
(check 'program-input-no-content-denies
       (raises?
        (lambda ()
          (consent-eval-source
           "(read-line)"
           #f
           (list (list 'capability-grants program-input-grant)))))
       #t)

;; Streaming program input: a host `program-input-reader' thunk yields the next
;; chunk on demand (or #f at end of stream), so a read pulls only as much input
;; as it needs and an unbounded stream never drains up front.  Parity twin of
;; the Emacs `consent-eval-test-program-input-streaming'.
(define (program-input-list-reader chunks)
  "Return a reader thunk yielding each of CHUNKS once, then #f at end of stream."
  (lambda ()
    (if (null? chunks)
        #f
        (let ((chunk (car chunks)))
          (set! chunks (cdr chunks))
          chunk))))

;; Counts reader pulls so a check can assert a read consumed only what it needed.
(define program-input-stream-pulls 0)
(define (program-input-counting-reader chunks)
  "Like `program-input-list-reader' but counts pulls in `program-input-stream-pulls'."
  (let ((inner (program-input-list-reader chunks)))
    (lambda ()
      (set! program-input-stream-pulls (+ program-input-stream-pulls 1))
      (inner))))

(set! program-input-stream-pulls 0)
(check-external/options 'program-input-stream-read-line
                        "(read-line)"
                        (list (cons 'program-input-reader
                                    (program-input-counting-reader
                                     '("a\n" "b\n" "c\n")))
                              (list 'capability-grants program-input-grant))
                        "\"a\"")
;; Reading one line pulled exactly one chunk -- the stream was not drained.
(check 'program-input-stream-incremental program-input-stream-pulls 1)
;; An unbounded reader would hang here if the port drained eagerly; reading a
;; bounded number of lines completes because refills stop at each newline.
(check-external/options 'program-input-stream-unbounded
                        "(list (read-line) (read-line) (read-line))"
                        (list (cons 'program-input-reader (lambda () "x\n"))
                              (list 'capability-grants program-input-grant))
                        "(\"x\" \"x\" \"x\")")
;; A datum split across chunks is assembled by refilling until the recovery
;; reader sees a complete form.
(check-external/options 'program-input-stream-datum
                        "(import (scheme read)) (read)"
                        (list (cons 'program-input-reader
                                    (program-input-list-reader
                                     '("(1 2" " 3 " "4)")))
                              (list 'capability-grants program-input-grant))
                        "(1 2 3 4)")

;; Program output / error streams (docs/repl-interaction-contract.md): a granted
;; writer receives each write flushed through immediately (write-through, not
;; buffered to end of program), an ungranted one fails closed, and an unbounded
;; write loop stays bounded by the host-callback budget.  Parity twin of the Emacs
;; program-output/error tests.
(define program-output-grant
  '(capability-grant (id program-output) (domain port)
                     (operations write flush close) (scope (backing stdout))
                     (expires never)))

;; Stderr-backed grant for the program-error stream tests.
(define program-error-grant
  '(capability-grant (id program-error) (domain port)
                     (operations write flush close) (scope (backing stderr))
                     (expires never)))

;; Evaluate SOURCE with a capturing writer under GRANT bound to OPTION-KEY,
;; returning (captured-text . flush-count) so a check can assert write-through.
(define (run-with-output-writer source option-key grant)
  (let ((flushes 0) (text ""))
    (consent-eval-source-result
     source #f
     (list (cons option-key
                 (lambda (chunk)
                   (set! flushes (+ flushes 1))
                   (set! text (string-append text chunk))))
           (list 'capability-grants grant)))
    (cons text flushes)))

(let ((captured (run-with-output-writer
                 "(import (scheme write)) (display \"hi\") (newline)"
                 'program-output-writer program-output-grant)))
  (check 'program-output-granted-text (car captured) "hi\n")
  ;; display and newline flush separately: write-through, not buffer-to-EOF.
  (check 'program-output-granted-flushes (cdr captured) 2))

(check 'program-output-ungranted-denies
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme write)) (display \"x\")"
           #f
           (list (cons 'program-output-writer (lambda (chunk) chunk))))))
       #t)

(check 'program-output-budget-bounded
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base) (scheme write))
            (let loop ((i 0)) (if (< i 50) (begin (display \"y\") (loop (+ i 1)))))"
           #f
           (list (cons 'program-output-writer (lambda (chunk) chunk))
                 (cons 'max-host-callbacks 5)
                 (list 'capability-grants program-output-grant)))))
       #t)

(let ((captured (run-with-output-writer
                 "(write-string \"e!\" (current-error-port))"
                 'program-error-writer program-error-grant)))
  (check 'program-error-granted-text (car captured) "e!"))

(check 'current-error-port-ungranted-denies
       (raises?
        (lambda () (consent-eval-source "(current-error-port)" #f '())))
       #t)

;; Binary program input (#528): the byte peer of the textual program-input
;; stream.  A `program-input-byte-reader' plus an active `port'/`read' grant
;; scoped to `stdin' connects `(current-input-port)' to a `stdio'-backed binary
;; input port that refills *bytes* on demand for `read-u8'/`peek-u8'/
;; `read-bytevector'; without the grant -- or with no byte reader offered -- the
;; read fails closed exactly as an unconnected current input port does.  Parity
;; twin of the Emacs `consent-eval-test-program-binary-input-stream'.
(check-external/options 'program-binary-input-read-u8
                        "(list (read-u8 (current-input-port))
                               (read-u8 (current-input-port))
                               (eof-object? (read-u8 (current-input-port))))"
                        (list (cons 'program-input-byte-reader
                                    (consent-program-input-from-bytevector
                                     (bytevector 104 105)))
                              (list 'capability-grants program-input-grant))
                        "(104 105 #t)")
;; peek-u8 does not advance the cursor; read-u8 then returns the peeked byte.
(check-external/options 'program-binary-input-peek-u8
                        "(let ((port (current-input-port)))
                           (list (peek-u8 port) (read-u8 port) (read-u8 port)))"
                        (list (cons 'program-input-byte-reader
                                    (consent-program-input-from-bytevector
                                     (bytevector 7 8)))
                              (list 'capability-grants program-input-grant))
                        "(7 7 8)")
;; read-bytevector pulls up to its count across the buffered bytes.
(check-external/options 'program-binary-input-read-bytevector
                        "(read-bytevector 3 (current-input-port))"
                        (list (cons 'program-input-byte-reader
                                    (consent-program-input-from-bytevector
                                     (bytevector 1 2 3 4)))
                              (list 'capability-grants program-input-grant))
                        "#u8(1 2 3)")
(check 'program-binary-input-ungranted-denies
       (raises?
        (lambda ()
          (consent-eval-source
           "(read-u8 (current-input-port))"
           #f
           (list (cons 'program-input-byte-reader
                       (consent-program-input-from-bytevector
                        (bytevector 9)))))))
       #t)
(check 'program-binary-input-no-reader-denies
       (raises?
        (lambda ()
          (consent-eval-source
           "(read-u8 (current-input-port))"
           #f
           (list (list 'capability-grants program-input-grant)))))
       #t)

;; Streaming binary program input: a host `program-input-byte-reader' thunk
;; yields the next bytevector chunk on demand (or #f at end of stream), so a read
;; pulls only as many bytes as it needs and an unbounded byte stream never drains
;; up front.  Parity twin of the Emacs
;; `consent-eval-test-program-binary-input-streaming'.
(define (program-input-byte-list-reader chunks)
  "Return a reader thunk yielding each of CHUNKS once, then #f at end of stream."
  (lambda ()
    (if (null? chunks)
        #f
        (let ((chunk (car chunks)))
          (set! chunks (cdr chunks))
          chunk))))

;; Counts byte-reader pulls so a check can assert a read consumed only what it needed.
(define program-input-byte-pulls 0)
(define (program-input-byte-counting-reader chunks)
  "Like `program-input-byte-list-reader' but counts pulls in `program-input-byte-pulls'."
  (let ((inner (program-input-byte-list-reader chunks)))
    (lambda ()
      (set! program-input-byte-pulls (+ program-input-byte-pulls 1))
      (inner))))

(set! program-input-byte-pulls 0)
(check-external/options 'program-binary-input-stream-read-u8
                        "(read-u8 (current-input-port))"
                        (list (cons 'program-input-byte-reader
                                    (program-input-byte-counting-reader
                                     (list (bytevector 10)
                                           (bytevector 20)
                                           (bytevector 30))))
                              (list 'capability-grants program-input-grant))
                        "10")
;; Reading one byte pulled exactly one chunk -- the stream was not drained.
(check 'program-binary-input-stream-incremental program-input-byte-pulls 1)
;; An unbounded byte reader would hang here if the port drained eagerly; reading
;; a bounded number of bytes completes because refills stop once a byte is buffered.
(check-external/options 'program-binary-input-stream-unbounded
                        "(let ((port (current-input-port)))
                           (list (read-u8 port) (read-u8 port) (read-u8 port)))"
                        (list (cons 'program-input-byte-reader
                                    (lambda () (bytevector 120)))
                              (list 'capability-grants program-input-grant))
                        "(120 120 120)")
;; A read-bytevector spanning multiple chunks refills until count bytes buffer.
(check-external/options 'program-binary-input-stream-read-bytevector
                        "(read-bytevector 4 (current-input-port))"
                        (list (cons 'program-input-byte-reader
                                    (program-input-byte-list-reader
                                     (list (bytevector 1 2)
                                           (bytevector 3)
                                           (bytevector 4 5))))
                              (list 'capability-grants program-input-grant))
                        "#u8(1 2 3 4)")

;; Binary program output / error (#528): a granted byte writer receives each
;; write flushed through immediately (write-through, not buffered to end of
;; program), an ungranted one fails closed, and an unbounded write loop stays
;; bounded by the host-callback budget.  Parity twin of the Emacs binary
;; program-output/error tests.

;; Evaluate SOURCE with a capturing byte writer under GRANT bound to OPTION-KEY,
;; returning (captured-bytes . flush-count) so a check can assert write-through.
(define (run-with-byte-writer source option-key grant)
  (let ((flushes 0) (bytes '()))
    (consent-eval-source-result
     source #f
     (list (cons option-key
                 (lambda (chunk)
                   (set! flushes (+ flushes 1))
                   (set! bytes (append bytes chunk))))
           (list 'capability-grants grant)))
    (cons bytes flushes)))

(let ((captured (run-with-byte-writer
                 "(let ((port (current-output-port)))
                    (write-u8 104 port)
                    (write-bytevector #u8(105 33) port))"
                 'program-output-byte-writer program-output-grant)))
  (check 'program-binary-output-granted-bytes (car captured) '(104 105 33))
  ;; write-u8 and write-bytevector flush separately: write-through, not buffer.
  (check 'program-binary-output-granted-flushes (cdr captured) 2))

(check 'program-binary-output-ungranted-denies
       (raises?
        (lambda ()
          (consent-eval-source
           "(write-u8 120 (current-output-port))"
           #f
           (list (cons 'program-output-byte-writer (lambda (chunk) chunk))))))
       #t)

(check 'program-binary-output-budget-bounded
       (raises?
        (lambda ()
          (consent-eval-source
           "(let loop ((i 0))
              (if (< i 50)
                  (begin (write-u8 121 (current-output-port)) (loop (+ i 1)))))"
           #f
           (list (cons 'program-output-byte-writer (lambda (chunk) chunk))
                 (cons 'max-host-callbacks 5)
                 (list 'capability-grants program-output-grant)))))
       #t)

(let ((captured (run-with-byte-writer
                 "(write-u8 33 (current-error-port))"
                 'program-error-byte-writer program-error-grant)))
  (check 'program-binary-error-granted-bytes (car captured) '(33)))

;; Keep this import-error regression at the end: Racket's R7RS host preserves
;; enough handler state after this rejected import to perturb later checks.
(check 'consent-json-read-subset-excludes-write
       (raises?
        (lambda ()
          (consent-eval-source
           "(import (scheme base)
                    (only (consent json read) json-write))
            json-write")))
       #t)

(if (= failures 0)
    (begin
      (display "Scheme evaluator tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme evaluator test failure(s)")
      (newline)
      (error "Scheme evaluator tests failed")))
