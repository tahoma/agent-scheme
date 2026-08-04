;;; test.sld --- Agent helper self-test library
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This host-neutral library provides lightweight self-tests for helper
;;; libraries and Consent Scheme skill manifests.  Test outcomes are ordinary
;;; Scheme-readable datums; source-string execution is delegated to the host
;;; primitive bridge so normal evaluator budgets and sandbox policy still
;;; apply.

(define-library (agent test)
  (export test-case
          test-error
          test-group
          test-run
          test-yield-failures
          skill-test
          skill-test-run)
  (import (scheme base)
          (scheme write)
          (agent io)
          (agent test primitive))
  (begin
    ;; Sentinel used to distinguish a missing field from a present #f value.
    (define missing-field (list 'missing-field))

    ;; Registry of named test groups evaluated in the current interaction.
    (define registered-tests '())

    ;; Registry of test results attached to skill names in this interaction.
    (define registered-skill-tests '())

    (define (test-field name . values)
      "Return a Scheme-readable field with NAME and VALUES."
      (cons name values))

    (define (datum-fields datum)
      "Return DATUM's record fields, accepting both records and bare alists."
      (cond
       ((and (pair? datum) (symbol? (car datum)))
        (cdr datum))
       ((list? datum)
        datum)
       (else '())))

    (define (field-values datum field)
      "Return values for FIELD from DATUM."
      (let loop ((fields (datum-fields datum)))
        (cond
         ((null? fields) '())
         ((and (pair? (car fields))
               (equal? (caar fields) field))
          (cdar fields))
         (else (loop (cdr fields))))))

    (define (field-value datum field default)
      "Return FIELD's first value from DATUM, or DEFAULT when absent."
      (let ((values (field-values datum field)))
        (if (null? values) default (car values))))

    (define (record-kind? datum kind)
      "Report whether DATUM starts with symbolic KIND."
      (and (pair? datum) (equal? (car datum) kind)))

    (define (datum->external datum)
      "Render DATUM using write syntax for source-test expected strings."
      (let ((port (open-output-string)))
        (write datum port)
        (get-output-string port)))

    (define (string-prefix? prefix text)
      "Report whether TEXT starts with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref text index))
                        (loop (+ index 1))))))))

    (define (string-contains? text needle)
      "Report whether TEXT contains NEEDLE."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (string-prefix? needle
                                   (substring text index text-length))
                   (loop (+ index 1)))))))

    (define (condition->datum condition)
      "Return CONDITION as a Scheme-readable error datum."
      (cond
       ((error-object? condition)
        (list 'error-object
              (test-field 'message (error-object-message condition))
              (test-field 'irritants
                          (error-object-irritants condition))))
       (else
        (list 'raised (test-field 'value condition)))))

    (define (make-test-result name kind status . fields)
      "Build one test result datum."
      (append
       (list 'agent-test-result
             (test-field 'name name)
             (test-field 'kind kind)
             (test-field 'status status))
       fields))

    (define (make-skipped-result name kind reason)
      "Build a skipped test result with a stable reason."
      (make-test-result name
                        kind
                        'skipped
                        (test-field 'reason reason)))

    (define (test-result? datum)
      "Return #t when DATUM is an individual test result."
      (record-kind? datum 'agent-test-result))

    (define (test-group? datum)
      "Return #t when DATUM is a test group result."
      (record-kind? datum 'agent-test-group))

    (define (test-status datum)
      "Return DATUM's test status, or skipped when it is not a test result."
      (field-value datum 'status 'skipped))

    (define (count-status tests status)
      "Return TESTS count whose status is STATUS."
      (let loop ((rest tests) (count 0))
        (cond
         ((null? rest) count)
         ((equal? (test-status (car rest)) status)
          (loop (cdr rest) (+ count 1)))
         (else
          (loop (cdr rest) count)))))

    (define (summary-field tests)
      "Build a summary field for TESTS."
      (test-field
       'summary
       (test-field 'total (length tests))
       (test-field 'pass (count-status tests 'pass))
       (test-field 'fail (count-status tests 'fail))
       (test-field 'error (count-status tests 'error))
       (test-field 'skipped (count-status tests 'skipped))
       (test-field 'budget-exhausted
                   (count-status tests 'budget-exhausted))))

    (define (group-status tests)
      "Return aggregate status for TESTS."
      (cond
       ((null? tests) 'skipped)
       ((or (> (count-status tests 'fail) 0)
            (> (count-status tests 'error) 0)
            (> (count-status tests 'budget-exhausted) 0))
        'fail)
       ((= (count-status tests 'skipped) (length tests))
        'skipped)
       (else 'pass)))

    (define (without-registration registry name)
      "Remove NAME from REGISTRY."
      (let loop ((rest registry) (result '()))
        (cond
         ((null? rest) (reverse result))
         ((equal? (caar rest) name)
          (loop (cdr rest) result))
         (else
          (loop (cdr rest) (cons (car rest) result))))))

    (define (register-test! name result)
      "Register RESULT under NAME and return RESULT."
      (set! registered-tests
            (cons (cons name result)
                  (without-registration registered-tests name)))
      result)

    (define (make-test-group name tests kind)
      "Build and register a test group."
      (let ((group
             (list 'agent-test-group
                   (test-field 'name name)
                   (test-field 'kind kind)
                   (test-field 'status (group-status tests))
                   (summary-field tests)
                   (test-field 'tests tests))))
        (register-test! name group)))

    (define (make-case-pass-result name expected actual)
      "Build a passing ordinary test-case result."
      (make-test-result name
                        'case
                        'pass
                        (test-field 'expected expected)
                        (test-field 'actual actual)))

    (define (make-case-fail-result name expected actual)
      "Build a failing ordinary test-case result."
      (make-test-result name
                        'case
                        'fail
                        (test-field 'expected expected)
                        (test-field 'actual actual)))

    (define (make-case-error-result name expected condition)
      "Build an error ordinary test-case result."
      (make-test-result name
                        'case
                        'error
                        (test-field 'expected expected)
                        (test-field 'error
                                    (condition->datum condition))))

    (define (make-expected-error-pass-result name condition)
      "Build a passing expected-error result."
      (make-test-result name
                        'expected-error
                        'pass
                        (test-field 'error
                                    (condition->datum condition))))

    (define (make-expected-error-fail-result name condition)
      "Build a failing expected-error result from a raised condition."
      (make-test-result name
                        'expected-error
                        'fail
                        (test-field 'error
                                    (condition->datum condition))))

    (define (make-expected-error-missing-result name)
      "Build a failing expected-error result when no error was raised."
      (make-test-result name
                        'expected-error
                        'fail
                        (test-field 'reason 'no-error)))

    ;; Evaluate EXPR and compare it with EXPECTED using equal?.
    (define-syntax test-case
      (syntax-rules ()
        ((_ case-name expression expected-expression)
         (let ((expected-value expected-expression))
           (guard (condition
                   (else
                    (make-case-error-result
                     case-name expected-value condition)))
             (let ((actual-value expression))
               (if (equal? actual-value expected-value)
                   (make-case-pass-result
                    case-name expected-value actual-value)
                   (make-case-fail-result
                    case-name expected-value actual-value))))))))

    ;; Evaluate EXPR and require a raised condition satisfying PREDICATE.
    (define-syntax test-error
      (syntax-rules ()
        ((_ error-name expression predicate-expression)
         (guard (condition
                 (else
                  (if (predicate-expression condition)
                      (make-expected-error-pass-result
                       error-name condition)
                      (make-expected-error-fail-result
                       error-name condition))))
           expression
           (make-expected-error-missing-result error-name)))))

    ;; Evaluate TESTS and register a named group.
    (define-syntax test-group
      (syntax-rules ()
        ((_ name tests ...)
         (make-test-group name (list tests ...) 'group))))

    (define (registered-test name)
      "Return the registered test named NAME, if any."
      (let ((entry (assoc name registered-tests)))
        (if entry (cdr entry) #f)))

    (define (test-run name-or-library)
      "Return a registered test group or result for NAME-OR-LIBRARY."
      #((parameters
         (name-or-library
          . ("Registered test name, test result, or test group datum.")))
        (returns (type (or agent-test-result agent-test-group))
         (description
          ("The matching test result/group, NAME-OR-LIBRARY unchanged"
            "when it is already a result, or a skipped run group.")))
        (effects state-read))
      (cond
       ((or (test-result? name-or-library)
            (test-group? name-or-library))
        name-or-library)
       ((registered-test name-or-library)
        (registered-test name-or-library))
       (else
        (make-test-group
         name-or-library
         (list
          (make-skipped-result name-or-library
                               'run
                               'not-registered))
         'run))))

    (define (result-failures result)
      "Return failures nested in RESULT."
      (cond
       ((test-result? result)
        (if (or (equal? (test-status result) 'pass)
                (equal? (test-status result) 'skipped))
            '()
            (list result)))
       ((test-group? result)
        (let loop ((tests (field-value result 'tests '()))
                   (failures '()))
          (if (null? tests)
              (reverse failures)
              (loop (cdr tests)
                    (append (reverse (result-failures (car tests)))
                            failures)))))
       (else '())))

    (define (test-yield-failures result)
      "Yield failed tests from RESULT as one structured Consent Scheme event."
      #((parameters
         (result (type (or symbol agent-test-result agent-test-group))
          (description
           ("Test result, test group, or registered test name to"
             "inspect."))))
        (returns (type (list-of agent-test-result))
         (description "List of failed nested test result datums."))
        (effects state-read agent-yield)
        (see-also test-run))
      (let ((run (test-run result)))
        (let ((failures (result-failures run)))
          (if (not (null? failures))
              (agent-yield
               (list 'agent-test-failures
                     (test-field 'name (field-value run 'name 'anonymous))
                     (test-field 'failures failures))))
          failures)))

    (define (expected-matches? actual expected)
      "Compare ACTUAL to EXPECTED, allowing EXPECTED to be external text."
      (cond
       ((equal? expected missing-field) #t)
       ((string? expected)
        (string=? (datum->external actual) expected))
       (else
        (equal? actual expected))))

    (define (evaluation-condition-type evaluation)
      "Return an evaluation-result's debugger condition type, if any."
      (let ((error-field (field-value evaluation 'error '())))
        (let ((condition (field-value error-field 'condition '())))
          (field-value condition 'type #f))))

    (define (budget-exhausted-evaluation? evaluation)
      "Return #t when EVALUATION reports budget exhaustion."
      (or (equal? (evaluation-condition-type evaluation) 'budget-exhausted)
          (string-contains? (datum->external evaluation)
                            "budget-exhausted")
          (let ((error-field (field-value evaluation 'error '())))
            (let ((message (field-value error-field 'message "")))
            (and (string? message)
                 (string-contains? message "budget"))))))

    (define (run-source-test skill-name test-datum)
      "Run one source-string test datum for SKILL-NAME."
      (let ((name (field-value test-datum 'name skill-name))
            (source (field-value test-datum 'source #f))
            (expected (field-value test-datum
                                   'expect
                                   (field-value test-datum
                                                'expected
                                                missing-field)))
            (options (field-value test-datum 'options '())))
        (if (not (string? source))
            (make-skipped-result name 'skill 'missing-source)
            (let ((evaluation
                   (agent-test-eval-source-result source options)))
              (let ((status (field-value evaluation 'status 'error))
                    (actual (field-value evaluation 'value missing-field)))
              (cond
               ((and (equal? status 'ok)
                     (expected-matches? actual expected))
                (make-test-result name
                                  'skill
                                  'pass
                                  (test-field 'source source)
                                  (test-field 'expected expected)
                                  (test-field 'actual actual)
                                  (test-field 'evaluation evaluation)))
               ((equal? status 'ok)
                (make-test-result name
                                  'skill
                                  'fail
                                  (test-field 'source source)
                                  (test-field 'expected expected)
                                  (test-field 'actual actual)
                                  (test-field 'evaluation evaluation)))
               ((budget-exhausted-evaluation? evaluation)
                (make-test-result name
                                  'skill
                                  'budget-exhausted
                                  (test-field 'source source)
                                  (test-field 'evaluation evaluation)))
               (else
                (make-test-result name
                                  'skill
                                  'error
                                  (test-field 'source source)
                                  (test-field 'evaluation evaluation)))))))))

    (define (srfi-64-status result)
      "Return the Agent Test status corresponding to SRFI 64 RESULT."
      (cond
       ((equal? result 'pass) 'pass)
       ((equal? result 'fail) 'fail)
       ((equal? result 'xpass) 'fail)
       ((equal? result 'xfail) 'skipped)
       ((equal? result 'skip) 'skipped)
       ((equal? result 'skipped) 'skipped)
       ((equal? result 'error) 'error)
       ((equal? result 'budget-exhausted) 'budget-exhausted)
       (else 'error)))

    (define (adapt-srfi-64-test test-datum)
      "Adapt one SRFI 64-style test event into an Agent Test result."
      (let ((name (field-value test-datum
                               'test-name
                               (field-value test-datum 'name 'srfi-64-test)))
            (result (field-value test-datum 'result 'error))
            (expected (field-value test-datum 'expected missing-field))
            (actual (field-value test-datum 'actual missing-field)))
        (make-test-result
         name
         'srfi-64
         (srfi-64-status result)
         (test-field 'srfi-64-result result)
         (test-field 'expected expected)
         (test-field 'actual actual))))

    (define (run-skill-test-datum skill-name test-datum)
      "Run TEST-DATUM as a skill-attached test."
      (cond
       ((or (test-result? test-datum)
            (test-group? test-datum))
        test-datum)
       ((record-kind? test-datum 'srfi-64)
        (adapt-srfi-64-test test-datum))
       ((or (not (equal? (field-value test-datum 'source missing-field)
                         missing-field))
            (not (equal? (field-value test-datum 'expect missing-field)
                         missing-field))
            (not (equal? (field-value test-datum 'expected missing-field)
                         missing-field)))
        (run-source-test skill-name test-datum))
       (else
        (make-skipped-result
         (field-value test-datum 'name skill-name)
         'skill
         'unsupported-test-datum))))

    (define (without-skill-tests skill-name)
      "Remove SKILL-NAME from the skill-test registry."
      (without-registration registered-skill-tests skill-name))

    (define (register-skill-test! skill-name result)
      "Register RESULT under SKILL-NAME and return RESULT."
      (let ((entry (assoc skill-name registered-skill-tests)))
        (set! registered-skill-tests
              (cons
               (cons skill-name
                     (append (if entry (cdr entry) '())
                             (list result)))
               (without-skill-tests skill-name))))
      result)

    (define (skill-test skill-name test-datum)
      "Run and register TEST-DATUM for SKILL-NAME."
      #((parameters
         (skill-name (type symbol)
          (description
            ("Skill name symbol or datum used as the registry key.")))
         (test-datum
          . ("Agent Test datum, SRFI 64 event, source test, or existing"
             "result.")))
        (returns (type agent-test-result)
         (description "The normalized test result registered for SKILL-NAME."))
        (effects state-write host-eval)
        (see-also skill-test-run))
      (register-skill-test!
       skill-name
       (run-skill-test-datum skill-name test-datum)))

    (define (skill-datum-tests skill-datum)
      "Return the tests declared directly in SKILL-DATUM."
      (field-value skill-datum 'tests '()))

    (define (skill-datum-name skill-datum)
      "Return a useful name for SKILL-DATUM."
      (field-value skill-datum
                   'name
                   (field-value skill-datum 'source-library 'skill)))

    (define (run-skill-datum skill-datum)
      "Run tests declared in a normalized skill datum."
      (let ((name (skill-datum-name skill-datum)))
        (make-test-group
         name
         (map (lambda (test-datum)
                (run-skill-test-datum name test-datum))
              (skill-datum-tests skill-datum))
         'skill)))

    (define (skill-test-run skill-name)
      "Run registered tests for SKILL-NAME, or tests declared by a skill datum\
."
      #((parameters
         (skill-name (type symbol)
          (description
           ("Skill name symbol, agent-skill datum, or"
             "agent-skill-candidate datum."))))
        (returns (type agent-test-group)
         (description
          ("An `agent-test-group` datum summarizing registered or"
            "declared skill tests.")))
        (effects state-read host-eval)
        (see-also skill-test test-yield-failures))
      (cond
       ((or (record-kind? skill-name 'agent-skill)
            (record-kind? skill-name 'agent-skill-candidate))
        (run-skill-datum skill-name))
       (else
        (let ((entry (assoc skill-name registered-skill-tests)))
          (make-test-group
           skill-name
           (if entry
               (cdr entry)
               (list
                (make-skipped-result skill-name
                                     'skill
                                     'not-registered)))
           'skill)))))))
