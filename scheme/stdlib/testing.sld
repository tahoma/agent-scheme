;;; SRFI 64 testing support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2005, 2006, 2007, 2012, 2013 Per Bothner
;; SPDX-FileCopyrightText: 2005 Alex Shinn
;; SPDX-FileCopyrightText: 2012 Álvaro Castro-Castilla
;; SPDX-FileCopyrightText: 2014 Mark H Weaver
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib testing)' as a portable R7RS adaptation of the official
;;; SRFI 64 reference implementation:
;;; https://github.com/scheme-requests-for-implementation/srfi-64.
;;; Local patches wrap the source in Consent Scheme's stdlib namespace, remove
;;; implementation-specific module branches, keep log-file output disabled by
;;; default so file effects remain policy-gated, and expose `(srfi 64)',
;;; `(srfi srfi-64)', `(srfi :64)', and `(srfi :64 testing)' as registry
;;; aliases.

(define-library (stdlib testing)
  (export test-begin
          test-end
          test-assert
          test-eqv
          test-eq
          test-equal
          test-approximate
          test-error
          test-apply
          test-with-runner
          test-match-nth
          test-match-all
          test-match-any
          test-match-name
          test-skip
          test-expect-fail
          test-read-eval-string
          test-runner-group-path
          test-group
          test-group-with-cleanup
          test-result-ref
          test-result-set!
          test-result-clear
          test-result-remove
          test-result-kind
          test-passed?
          test-log-to-file
          test-runner?
          test-runner-reset
          test-runner-null
          test-runner-simple
          test-runner-current
          test-runner-factory
          test-runner-get
          test-runner-create
          test-runner-test-name
          test-runner-pass-count
          test-runner-pass-count!
          test-runner-fail-count
          test-runner-fail-count!
          test-runner-xpass-count
          test-runner-xpass-count!
          test-runner-xfail-count
          test-runner-xfail-count!
          test-runner-skip-count
          test-runner-skip-count!
          test-runner-group-stack
          test-runner-group-stack!
          test-runner-on-test-begin
          test-runner-on-test-begin!
          test-runner-on-test-end
          test-runner-on-test-end!
          test-runner-on-group-begin
          test-runner-on-group-begin!
          test-runner-on-group-end
          test-runner-on-group-end!
          test-runner-on-final
          test-runner-on-final!
          test-runner-on-bad-count
          test-runner-on-bad-count!
          test-runner-on-bad-end-name
          test-runner-on-bad-end-name!
          test-result-alist
          test-result-alist!
          test-runner-aux-value
          test-runner-aux-value!
          test-on-group-begin-simple
          test-on-group-end-simple
          test-on-bad-count-simple
          test-on-bad-end-name-simple
          test-on-test-end-simple
          test-on-final-simple)
  ;; Gambit expands imported syntax-rules templates in the client library
  ;; environment and requires every helper identifier referenced by those
  ;; templates to be exported. Keep that host accommodation out of the manifest
  ;; and other R7RS hosts.
  (cond-expand
   (gambit
    (export %test-begin
            %test-end
            %test-ensure-runner
            %test-result-name!
            %test-result-clear!
            %test-should-execute
            %test-evaluate-with-catch
            %test-comp1body
            %test-comp2body
            %test-comp2
            %test-approximate=
            %test-error
            %test-result-actual-value!
            %test-result-expected-value!
            %test-result-actual-error!
            %test-result-expected-error!
            %test-on-test-begin
            %test-on-test-end
            %test-report-result
            %test-match-nth
            %test-match-all
            %test-match-any
            %test-as-specifier
            %test-runner-skip-list
            %test-runner-skip-list!
            %test-runner-fail-list
            %test-runner-fail-list!))
   (else))
  (import (scheme base)
          (scheme write)
          (scheme read)
          (scheme eval)
          (scheme file))
  (begin
    ;; Test-runner state mirrors SRFI 64's reference runner fields.
    (define-record-type <test-runner>
      (%make-test-runner)
      test-runner?
      (pass-count test-runner-pass-count test-runner-pass-count!)
      (fail-count test-runner-fail-count test-runner-fail-count!)
      (xpass-count test-runner-xpass-count test-runner-xpass-count!)
      (xfail-count test-runner-xfail-count test-runner-xfail-count!)
      (skip-count test-runner-skip-count test-runner-skip-count!)
      (skip-list %test-runner-skip-list %test-runner-skip-list!)
      (fail-list %test-runner-fail-list %test-runner-fail-list!)
      (run-list %test-runner-run-list %test-runner-run-list!)
      (skip-save %test-runner-skip-save %test-runner-skip-save!)
      (fail-save %test-runner-fail-save %test-runner-fail-save!)
      (group-stack test-runner-group-stack test-runner-group-stack!)
      (on-test-begin test-runner-on-test-begin test-runner-on-test-begin!)
      (on-test-end test-runner-on-test-end test-runner-on-test-end!)
      (on-group-begin test-runner-on-group-begin
                      test-runner-on-group-begin!)
      (on-group-end test-runner-on-group-end test-runner-on-group-end!)
      (on-final test-runner-on-final test-runner-on-final!)
      (on-bad-count test-runner-on-bad-count test-runner-on-bad-count!)
      (on-bad-end-name test-runner-on-bad-end-name
                       test-runner-on-bad-end-name!)
      (total-count %test-runner-total-count %test-runner-total-count!)
      (count-list %test-runner-count-list %test-runner-count-list!)
      (result-alist test-result-alist test-result-alist!)
      (aux-value test-runner-aux-value test-runner-aux-value!))

    ;; Default log-file generation is disabled to avoid implicit host writes.
    (define test-log-to-file #f)

    ;; Current test runner parameter.
    (define test-runner-current (make-parameter #f))

    ;; Current test runner factory parameter.
    (define test-runner-factory (make-parameter #f))

    ;; Result keys are created at run time so macro expansions do not capture
    ;; them as hygienic identifiers.
    (define (%test-symbol name)
      "Return the symbol named NAME for internal result keys."
      (string->symbol name))

    ;; Result property key for the current test name.
    (define %test-name-key (%test-symbol "test-name"))
    ;; Result property key for optional source file metadata.
    (define %source-file-key (%test-symbol "source-file"))
    ;; Result property key for optional source line metadata.
    (define %source-line-key (%test-symbol "source-line"))
    ;; Result property key for optional source form metadata.
    (define %source-form-key (%test-symbol "source-form"))
    ;; Result property key for the SRFI 64 result kind.
    (define %result-kind-key (%test-symbol "result-kind"))
    ;; Result property key for assertion actual values.
    (define %actual-value-key (%test-symbol "actual-value"))
    ;; Result property key for assertion expected values.
    (define %expected-value-key (%test-symbol "expected-value"))
    ;; Result property key for captured actual error conditions.
    (define %actual-error-key (%test-symbol "actual-error"))
    ;; Result property key for expected error descriptors.
    (define %expected-error-key (%test-symbol "expected-error"))

    (define (%test-unspecified)
      "Return the R7RS unspecified value."
      (if #f #f))

    (define (%test-null-callback runner)
      "Ignore RUNNER and return an unspecified value."
      runner
      (%test-unspecified))

    (define (test-runner-reset runner)
      "Reset RUNNER's counters, stacks, filters, and result properties."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to reset.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write))
      (test-result-alist! runner '())
      (test-runner-pass-count! runner 0)
      (test-runner-fail-count! runner 0)
      (test-runner-xpass-count! runner 0)
      (test-runner-xfail-count! runner 0)
      (test-runner-skip-count! runner 0)
      (%test-runner-total-count! runner 0)
      (%test-runner-count-list! runner '())
      (%test-runner-run-list! runner #t)
      (%test-runner-skip-list! runner '())
      (%test-runner-fail-list! runner '())
      (%test-runner-skip-save! runner '())
      (%test-runner-fail-save! runner '())
      (test-runner-group-stack! runner '())
      (test-runner-aux-value! runner #f))

    (define (test-runner-group-path runner)
      "Return RUNNER's active group path from outermost to innermost."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to inspect.")))
        (returns (type list)
         (description "Active group names, outermost first."))
        (effects state-read))
      (reverse (test-runner-group-stack runner)))

    (define (test-runner-null)
      "Return a test runner whose callbacks perform no reporting."
      #((parameters)
        (returns (type test-runner)
         (description "Fresh null test runner."))
        (effects allocation state-write))
      (let ((runner (%make-test-runner)))
        (test-runner-reset runner)
        (test-runner-on-group-begin!
         runner
         (lambda (runner name count) runner name count (%test-unspecified)))
        (test-runner-on-group-end! runner %test-null-callback)
        (test-runner-on-final! runner %test-null-callback)
        (test-runner-on-test-begin! runner %test-null-callback)
        (test-runner-on-test-end! runner %test-null-callback)
        (test-runner-on-bad-count!
         runner
         (lambda (runner count expected)
           runner count expected (%test-unspecified)))
        (test-runner-on-bad-end-name!
         runner
         (lambda (runner begin end) runner begin end (%test-unspecified)))
        runner))

    (define (test-runner-simple)
      "Return a simple reporting test runner."
      #((parameters)
        (returns (type test-runner)
         (description "Fresh simple test runner."))
        (effects allocation state-write))
      (let ((runner (%make-test-runner)))
        (test-runner-reset runner)
        (test-runner-on-group-begin! runner test-on-group-begin-simple)
        (test-runner-on-group-end! runner test-on-group-end-simple)
        (test-runner-on-final! runner test-on-final-simple)
        (test-runner-on-test-begin! runner %test-null-callback)
        (test-runner-on-test-end! runner test-on-test-end-simple)
        (test-runner-on-bad-count! runner test-on-bad-count-simple)
        (test-runner-on-bad-end-name! runner test-on-bad-end-name-simple)
        runner))

    (test-runner-factory test-runner-simple)

    (define (test-runner-get)
      "Return the current test runner, or signal if no runner is active."
      #((parameters)
        (returns (type test-runner)
         (description "Current test runner."))
        (effects state-read error))
      (let ((runner (test-runner-current)))
        (if (not runner)
            (error "test-runner not initialized - test-begin missing?"))
        runner))

    (define (test-runner-create)
      "Return a fresh runner from the current test runner factory."
      #((parameters)
        (returns (type test-runner)
         (description "Fresh test runner."))
        (effects allocation state-read state-write))
      ((test-runner-factory)))

    (define (test-runner-test-name runner)
      "Return RUNNER's current test name or the empty string."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to inspect.")))
        (returns (type string)
         (description "Current test name."))
        (effects state-read))
      (test-result-ref runner %test-name-key ""))

    (define (%test-any-specifier-matches specifiers runner)
      "Return #t when any SPECIFIERS match RUNNER."
      (let loop ((rest specifiers))
        (cond
         ((null? rest) #f)
         ((%test-specifier-matches (car rest) runner) #t)
         (else (loop (cdr rest))))))

    (define (%test-specifier-matches specifier runner)
      "Return #t when SPECIFIER matches RUNNER."
      (specifier runner))

    (define (%test-should-execute runner)
      "Return RUNNER's execution status for the next test."
      (let ((run-list (%test-runner-run-list runner)))
        (cond
         ((or (not (or (eqv? run-list #t)
                       (%test-any-specifier-matches run-list runner)))
              (%test-any-specifier-matches
               (%test-runner-skip-list runner)
               runner))
          (test-result-set! runner %result-kind-key 'skip)
          #f)
         ((%test-any-specifier-matches
           (%test-runner-fail-list runner)
           runner)
          (test-result-set! runner %result-kind-key 'xfail)
          'xfail)
         (else #t))))

    (define (%test-begin suite-name count)
      "Enter test group SUITE-NAME with optional expected COUNT."
      (if (not (test-runner-current))
          (let ((runner (test-runner-create)))
            (test-runner-current runner)
            (test-runner-on-final!
             runner
             (let ((old-final (test-runner-on-final runner)))
               (lambda (runner)
                 (old-final runner)
                 (test-runner-current #f))))))
      (let ((runner (test-runner-current)))
        ((test-runner-on-group-begin runner) runner suite-name count)
        (%test-runner-skip-save!
         runner
         (cons (%test-runner-skip-list runner)
               (%test-runner-skip-save runner)))
        (%test-runner-fail-save!
         runner
         (cons (%test-runner-fail-list runner)
               (%test-runner-fail-save runner)))
        (%test-runner-count-list!
         runner
         (cons (cons (%test-runner-total-count runner) count)
               (%test-runner-count-list runner)))
        (test-runner-group-stack!
         runner
         (cons suite-name (test-runner-group-stack runner)))))

    ;; Begin a SRFI 64 test group.
    (define-syntax test-begin
      (syntax-rules ()
        ((_ suite-name)
         (%test-begin suite-name #f))
        ((_ suite-name count)
         (%test-begin suite-name count))))

    (define (%test-format-line runner)
      "Return source-location prefix text for RUNNER when available."
      (let* ((line-info (test-result-alist runner))
             (source-file (assq %source-file-key line-info))
             (source-line (assq %source-line-key line-info))
             (file (if source-file (cdr source-file) "")))
        (if source-line
            (string-append file ":"
                           (number->string (cdr source-line))
                           ": ")
            "")))

    (define (%test-end suite-name)
      "Leave the current test group, checking optional SUITE-NAME."
      (let* ((runner (test-runner-get))
             (groups (test-runner-group-stack runner))
             (line (%test-format-line runner)))
        (if (null? groups)
            (error (string-append line "test-end not in a group")))
        (if (and suite-name (not (equal? suite-name (car groups))))
            ((test-runner-on-bad-end-name runner) runner suite-name
                                                    (car groups)))
        (let* ((count-list (%test-runner-count-list runner))
               (expected-count (cdar count-list))
               (saved-count (caar count-list))
               (group-count (- (%test-runner-total-count runner)
                               saved-count)))
          (if (and expected-count (not (= expected-count group-count)))
              ((test-runner-on-bad-count runner) runner group-count
                                                   expected-count))
          ((test-runner-on-group-end runner) runner)
          (test-runner-group-stack!
           runner
           (cdr (test-runner-group-stack runner)))
          (%test-runner-skip-list!
           runner
           (car (%test-runner-skip-save runner)))
          (%test-runner-skip-save!
           runner
           (cdr (%test-runner-skip-save runner)))
          (%test-runner-fail-list!
           runner
           (car (%test-runner-fail-save runner)))
          (%test-runner-fail-save!
           runner
           (cdr (%test-runner-fail-save runner)))
          (%test-runner-count-list!
           runner
           (cdr count-list))
          (if (null? (test-runner-group-stack runner))
              ((test-runner-on-final runner) runner)))))

    ;; End the current SRFI 64 test group.
    (define-syntax test-end
      (syntax-rules ()
        ((test-end)
         (%test-end #f))
        ((test-end suite-name)
         (%test-end suite-name))))

    (define (%test-ensure-runner)
      "Ensure a current runner exists and returns it."
      (if (not (test-runner-current))
          (let ((runner (test-runner-create)))
            (test-runner-current runner)
            (test-runner-on-final!
             runner
             (let ((old-final (test-runner-on-final runner)))
               (lambda (runner)
                 (old-final runner)
                 (test-runner-current #f))))))
      (test-runner-current))

    ;; Run BODY as a named SRFI 64 test group.
    (define-syntax test-group
      (syntax-rules ()
        ((_ suite-name body ...)
         (let ((runner (%test-ensure-runner)))
           (%test-result-name! runner suite-name)
           (if (%test-should-execute runner)
               (dynamic-wind
                   (lambda () (test-begin suite-name))
                   (lambda () body ...)
                   (lambda () (test-end suite-name))))))))

    ;; Run BODY as a group and always evaluate the final cleanup form.
    (define-syntax test-group-with-cleanup
      (syntax-rules ()
        ((_ suite-name form cleanup-form)
         (test-group suite-name
           (dynamic-wind
               (lambda () #f)
               (lambda () form)
               (lambda () cleanup-form))))
        ((_ suite-name cleanup-form)
         (test-group-with-cleanup suite-name #f cleanup-form))
        ((_ suite-name form1 form2 form3 rest ...)
         (test-group-with-cleanup suite-name
           (begin form1 form2)
           form3
           rest ...))))

    (define (test-result-ref runner name . maybe-default)
      "Return RUNNER result property NAME or an optional default."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to inspect."))
         (name (type symbol)
          (description "Result property name."))
         (maybe-default (type list)
          (description "Zero or one fallback value.")))
        (returns (type any)
         (description "Property value or fallback."))
        (effects state-read))
      (let ((entry (assq name (test-result-alist runner))))
        (if entry
            (cdr entry)
            (if (null? maybe-default) #f (car maybe-default)))))

    (define (%test-result-name! runner name)
      "Replace RUNNER's result properties with test NAME."
      (test-result-alist! runner (list (cons %test-name-key name))))

    (define (%test-result-clear! runner)
      "Remove every result property from RUNNER."
      (test-result-alist! runner '()))

    (define (test-result-set! runner name value)
      "Set RUNNER result property NAME to VALUE."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to mutate."))
         (name (type symbol)
          (description "Result property name."))
         (value . "Result property value."))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write allocation))
      (let ((alist (test-result-alist runner)))
        (let loop ((rest alist) (kept '()))
          (cond
           ((null? rest)
            (test-result-alist! runner (cons (cons name value) alist)))
           ((eq? (caar rest) name)
            (test-result-alist!
             runner
             (append (reverse kept) (cons (cons name value) (cdr rest)))))
           (else
            (loop (cdr rest) (cons (car rest) kept)))))))

    (define (test-result-clear runner)
      "Remove every result property from RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to mutate.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write))
      (test-result-alist! runner '()))

    (define (test-result-remove runner name)
      "Remove result property NAME from RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Test runner to mutate."))
         (name (type symbol)
          (description "Result property name.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write allocation))
      (let loop ((rest (test-result-alist runner)) (kept '()))
        (cond
         ((null? rest)
          (test-result-alist! runner (reverse kept)))
         ((eq? (caar rest) name)
          (test-result-alist! runner (append (reverse kept) (cdr rest))))
         (else
          (loop (cdr rest) (cons (car rest) kept))))))

    (define (test-result-kind . maybe-runner)
      "Return the current or selected runner's last result kind."
      #((parameters
         (maybe-runner (type list)
          (description "Zero or one runner to inspect.")))
        (returns (type (or symbol boolean))
         (description "Last result kind, or #f when unavailable."))
        (effects state-read))
      (let ((runner (if (null? maybe-runner)
                        (test-runner-current)
                        (car maybe-runner))))
        (and runner (test-result-ref runner %result-kind-key))))

    (define (test-passed? . maybe-runner)
      "Return #t when the last result passed or unexpectedly passed."
      #((parameters
         (maybe-runner (type list)
          (description "Zero or one runner to inspect.")))
        (returns (type boolean)
         (description "#t for `pass` and `xpass` result kinds."))
        (effects state-read error))
      (let ((runner (if (null? maybe-runner)
                        (test-runner-get)
                        (car maybe-runner))))
        (if (memq (test-result-ref runner %result-kind-key) '(pass xpass))
            #t
            #f)))

    (define (%test-result-actual-value! runner value)
      "Set RUNNER's actual-value result property."
      (test-result-set! runner %actual-value-key value))

    (define (%test-result-expected-value! runner value)
      "Set RUNNER's expected-value result property."
      (test-result-set! runner %expected-value-key value))

    (define (%test-result-actual-error! runner value)
      "Set RUNNER's actual-error result property."
      (test-result-set! runner %actual-error-key value))

    (define (%test-result-expected-error! runner value)
      "Set RUNNER's expected-error result property."
      (test-result-set! runner %expected-error-key value))

    (define (%test-report-result)
      "Increment the current runner counters and call its test-end callback."
      (let* ((runner (test-runner-get))
             (kind (test-result-kind runner)))
        (case kind
          ((pass)
           (test-runner-pass-count!
            runner
            (+ 1 (test-runner-pass-count runner))))
          ((fail)
           (test-runner-fail-count!
            runner
            (+ 1 (test-runner-fail-count runner))))
          ((xpass)
           (test-runner-xpass-count!
            runner
            (+ 1 (test-runner-xpass-count runner))))
          ((xfail)
           (test-runner-xfail-count!
            runner
            (+ 1 (test-runner-xfail-count runner))))
          (else
           (test-runner-skip-count!
            runner
            (+ 1 (test-runner-skip-count runner)))))
        (%test-runner-total-count!
         runner
         (+ 1 (%test-runner-total-count runner)))
        ((test-runner-on-test-end runner) runner)))

    (define (%test-on-test-begin runner)
      "Call RUNNER's begin callback and return #t unless the test is skipped."
      (%test-should-execute runner)
      ((test-runner-on-test-begin runner) runner)
      (not (eq? 'skip (test-result-ref runner %result-kind-key))))

    (define (%test-on-test-end runner result)
      "Record RESULT as RUNNER's SRFI 64 result kind."
      (test-result-set!
       runner
       %result-kind-key
       (if (eq? (test-result-ref runner %result-kind-key) 'xfail)
           (if result 'xpass 'xfail)
           (if result 'pass 'fail))))

    ;; Evaluate EXPR, converting raised conditions to #f.
    (define-syntax %test-evaluate-with-catch
      (syntax-rules ()
        ((_ runner expr)
         (guard (condition
                 (else
                  (%test-result-actual-error! runner condition)
                  #f))
           expr))))

    ;; Shared body for one-expression assertions.
    (define-syntax %test-comp1body
      (syntax-rules ()
        ((_ runner expr)
         (let ()
           (if (%test-on-test-begin runner)
               (let ((result (%test-evaluate-with-catch runner expr)))
                 (%test-result-actual-value! runner result)
                 (%test-on-test-end runner result)))
           (%test-report-result)))))

    ;; Shared body for expected/actual comparison assertions.
    (define-syntax %test-comp2body
      (syntax-rules ()
        ((_ runner comparator expected expr)
         (let ()
           (if (%test-on-test-begin runner)
               (let ((expected-value expected))
                 (%test-result-expected-value! runner expected-value)
                 (let ((actual-value
                        (%test-evaluate-with-catch runner expr)))
                   (%test-result-actual-value! runner actual-value)
                   (%test-on-test-end
                    runner
                    (comparator expected-value actual-value)))))
           (%test-report-result)))))

    ;; Assert that an expression returns a true value.
    (define-syntax test-assert
      (syntax-rules ()
        ((_ name expr)
         (let* ((runner (test-runner-get))
                (test-name name))
           (%test-result-name! runner test-name)
           (%test-comp1body runner expr)))
        ((_ expr)
         (let ((runner (test-runner-get)))
           (%test-result-clear! runner)
           (%test-comp1body runner expr)))))

    ;; Helper for two-operand comparison assertions.
    (define-syntax %test-comp2
      (syntax-rules ()
        ((_ comparator name expected expr)
         (let* ((runner (test-runner-get))
                (test-name name))
           (%test-result-name! runner test-name)
           (%test-comp2body runner comparator expected expr)))
        ((_ comparator expected expr)
         (let ((runner (test-runner-get)))
           (%test-result-clear! runner)
           (%test-comp2body runner comparator expected expr)))))

    ;; Assert `eqv?` equality.
    (define-syntax test-eqv
      (syntax-rules ()
        ((_ rest ...)
         (%test-comp2 eqv? rest ...))))

    ;; Assert `eq?` equality.
    (define-syntax test-eq
      (syntax-rules ()
        ((_ rest ...)
         (%test-comp2 eq? rest ...))))

    ;; Assert `equal?` equality.
    (define-syntax test-equal
      (syntax-rules ()
        ((_ rest ...)
         (%test-comp2 equal? rest ...))))

    (define (%test-approximate= error)
      "Return a comparator for numeric values within ERROR."
      (lambda (expected actual)
        (and (number? actual)
             (number? expected)
             (>= actual (- expected error))
             (<= actual (+ expected error)))))

    ;; Assert approximate numeric equality.
    (define-syntax test-approximate
      (syntax-rules ()
        ((_ name expected expr error)
         (%test-comp2 (%test-approximate= error) name expected expr))
        ((_ expected expr error)
         (%test-comp2 (%test-approximate= error) expected expr))))

    ;; Shared body for assertions that expect an error.
    (define-syntax %test-error
      (syntax-rules ()
        ((_ runner error-type expr)
         (let ()
           (if (%test-on-test-begin runner)
               (let ((expected-error error-type))
                 (%test-result-expected-error! runner expected-error)
                 (%test-on-test-end
                  runner
                  (guard (condition
                          (else
                           (%test-result-actual-error! runner condition)
                           #t))
                    (%test-result-actual-value! runner expr)
                    #f))))
           (%test-report-result)))))

    ;; Assert that an expression raises an error.
    (define-syntax test-error
      (syntax-rules ()
        ((_ name error-type expr)
         (let* ((runner (test-runner-get))
                (test-name name))
           (%test-result-name! runner test-name)
           (%test-error runner error-type expr)))
        ((_ error-type expr)
         (let ((runner (test-runner-get)))
           (%test-result-clear! runner)
           (%test-error runner error-type expr)))
        ((_ expr)
         (let ((runner (test-runner-get)))
           (%test-result-clear! runner)
           (%test-error runner #t expr)))))

    ;; Run BODY with RUNNER as the current runner, restoring the prior runner.
    (define-syntax test-with-runner
      (syntax-rules ()
        ((_ runner body ...)
         (let ((saved-runner (test-runner-current)))
           (dynamic-wind
               (lambda () (test-runner-current runner))
               (lambda () body ...)
               (lambda () (test-runner-current saved-runner)))))))

    (define (test-apply first . rest)
      "Run selected tests by applying SRFI 64 specifiers to a thunk."
      #((parameters
         (first . "Runner, specifier, or thunk.")
         (rest (type list)
          (description "Remaining specifiers and the thunk to run.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write allocation))
      (if (test-runner? first)
          (test-with-runner first (apply test-apply rest))
          (let ((runner (test-runner-current)))
            (if runner
                (let ((run-list (%test-runner-run-list runner)))
                  (cond
                   ((null? rest)
                    (%test-runner-run-list! runner (reverse run-list))
                    (first))
                   (else
                    (%test-runner-run-list!
                     runner
                     (if (eq? run-list #t)
                         (list first)
                         (cons first run-list)))
                    (apply test-apply rest)
                    (%test-runner-run-list! runner run-list))))
                (let ((runner (test-runner-create)))
                  (test-with-runner runner (apply test-apply first rest))
                  ((test-runner-on-final runner) runner))))))

    (define (%test-match-nth n count)
      "Return a stateful specifier matching COUNT tests beginning at N."
      (let ((index 0))
        (lambda (runner)
          runner
          (set! index (+ index 1))
          (and (>= index n) (< index (+ n count))))))

    ;; Return a stateful specifier matching the nth next test.
    (define-syntax test-match-nth
      (syntax-rules ()
        ((_ n)
         (test-match-nth n 1))
        ((_ n count)
         (%test-match-nth n count))))

    (define (%test-match-all . predicates)
      "Return a specifier matching only when every PREDICATES item matches."
      (lambda (runner)
        ;; Stateful specifiers such as `test-match-nth` must observe every test,
        ;; even when an earlier predicate already determines the conjunction.
        (let loop ((rest predicates) (matched? #t))
          (if (null? rest)
              matched?
              (let ((current? ((car rest) runner)))
                (loop (cdr rest) (and current? matched?)))))))

    ;; Return a specifier matching only when every input specifier matches.
    (define-syntax test-match-all
      (syntax-rules ()
        ((_ predicate ...)
         (%test-match-all (%test-as-specifier predicate) ...))))

    (define (%test-match-any . predicates)
      "Return a specifier matching when any PREDICATES item matches."
      (lambda (runner)
        ;; Evaluate every stateful specifier so disjunction order cannot change
        ;; which later tests a `test-match-nth` predicate observes.
        (let loop ((rest predicates) (matched? #f))
          (if (null? rest)
              matched?
              (let ((current? ((car rest) runner)))
                (loop (cdr rest) (or current? matched?)))))))

    ;; Return a specifier matching when any input specifier matches.
    (define-syntax test-match-any
      (syntax-rules ()
        ((_ predicate ...)
         (%test-match-any (%test-as-specifier predicate) ...))))

    (define (%test-as-specifier specifier)
      "Coerce SPECIFIER to a SRFI 64 specifier procedure."
      (cond
       ((procedure? specifier) specifier)
       ((integer? specifier) (test-match-nth 1 specifier))
       ((string? specifier) (test-match-name specifier))
       (else (error "not a valid test specifier"))))

    ;; Add skip specifiers to the current runner.
    (define-syntax test-skip
      (syntax-rules ()
        ((_ predicate ...)
         (let ((runner (test-runner-get)))
           (%test-runner-skip-list!
            runner
            (cons (test-match-all (%test-as-specifier predicate) ...)
                  (%test-runner-skip-list runner)))))))

    ;; Add expected-failure specifiers to the current runner.
    (define-syntax test-expect-fail
      (syntax-rules ()
        ((_ predicate ...)
         (let ((runner (test-runner-get)))
           (%test-runner-fail-list!
            runner
            (cons (test-match-all (%test-as-specifier predicate) ...)
                  (%test-runner-fail-list runner)))))))

    (define (test-match-name name)
      "Return a specifier matching tests named NAME."
      #((parameters
         (name (type string)
          (description "Test name to match.")))
        (returns (type procedure)
         (description "Specifier predicate."))
        (effects allocation state-read))
      (lambda (runner)
        (equal? name (test-runner-test-name runner))))

    (define (test-read-eval-string string)
      "Read and evaluate one expression from STRING in `(scheme base)`."
      #((parameters
         (string (type string)
          (description "Source text containing exactly one expression.")))
        (returns (type any)
         (description "Evaluation result."))
        (effects state-read evaluation error))
      (let* ((port (open-input-string string))
             (form (read port)))
        (if (eof-object? (read-char port))
            (cond-expand
             ;; Gambit's R7RS `(scheme eval)` exports one-argument `eval` but
             ;; not `environment`; its default evaluation environment is the
             ;; imported R7RS base environment used by this library.
             (gambit (eval form))
             (else (eval form (environment '(scheme base)))))
            (error "not at eof"))))

    (define (test-on-group-begin-simple runner suite-name count)
      "Print a simple group-begin notice for RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Active test runner."))
         (suite-name . "Group name.")
         (count (type (or integer boolean))
          (description "Expected count or #f.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write file-write))
      count
      (if (null? (test-runner-group-stack runner))
          (begin
            (display "%%%% Starting test ")
            (display suite-name)
            (if test-log-to-file
                (let* ((log-name
                        (if (string? test-log-to-file)
                            test-log-to-file
                            (string-append suite-name ".log")))
                       (log-file (open-output-file log-name)))
                  (display "%%%% Starting test " log-file)
                  (display suite-name log-file)
                  (newline log-file)
                  (test-runner-aux-value! runner log-file)
                  (display "  (Writing full log to \"")
                  (display log-name)
                  (display "\")")))
            (newline)))
      (let ((log (test-runner-aux-value runner)))
        (if (output-port? log)
            (begin
              (display "Group begin: " log)
              (display suite-name log)
              (newline log)))))

    (define (test-on-group-end-simple runner)
      "Print a simple group-end notice for RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Active test runner.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write))
      (let ((log (test-runner-aux-value runner)))
        (if (output-port? log)
            (begin
              (display "Group end: " log)
              (display (car (test-runner-group-stack runner)) log)
              (newline log)))))

    (define (%test-on-bad-count-write count expected-count port)
      "Write bad-count diagnostic to PORT."
      (display "*** Total number of tests was " port)
      (display count port)
      (display " but should be " port)
      (display expected-count port)
      (display ". ***" port)
      (newline port)
      (display "*** Discrepancy indicates testsuite error or exceptions. ***"
               port)
      (newline port))

    (define (test-on-bad-count-simple runner count expected-count)
      "Print a simple bad-count notice for RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Active test runner."))
         (count (type integer)
          (description "Observed test count."))
         (expected-count (type integer)
          (description "Expected test count.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write))
      runner
      (%test-on-bad-count-write count expected-count (current-output-port))
      (let ((log (test-runner-aux-value runner)))
        (if (output-port? log)
            (%test-on-bad-count-write count expected-count log))))

    (define (test-on-bad-end-name-simple runner begin-name end-name)
      "Signal a simple bad-end-name error for RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Active test runner."))
         (begin-name . "Name supplied to `test-end`.")
         (end-name . "Current group name." ))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read error))
      (error (string-append (%test-format-line runner)
                            "test-end "
                            begin-name
                            " does not match test-begin "
                            end-name)))

    (define (%test-final-report1 value label port)
      "Write one nonzero final-report VALUE with LABEL to PORT."
      (if (> value 0)
          (begin
            (display label port)
            (display value port)
            (newline port))))

    (define (%test-final-report-simple runner port)
      "Write RUNNER final counts to PORT."
      (%test-final-report1 (test-runner-pass-count runner)
                           "# of expected passes      "
                           port)
      (%test-final-report1 (test-runner-xfail-count runner)
                           "# of expected failures    "
                           port)
      (%test-final-report1 (test-runner-xpass-count runner)
                           "# of unexpected successes "
                           port)
      (%test-final-report1 (test-runner-fail-count runner)
                           "# of unexpected failures  "
                           port)
      (%test-final-report1 (test-runner-skip-count runner)
                           "# of skipped tests        "
                           port))

    (define (test-on-final-simple runner)
      "Print a simple final report for RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Active test runner.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write))
      (%test-final-report-simple runner (current-output-port))
      (let ((log (test-runner-aux-value runner)))
        (if (output-port? log)
            (%test-final-report-simple runner log))))

    (define (%test-write-result1 pair port)
      "Write result PAIR to PORT."
      (display "  " port)
      (display (car pair) port)
      (display ": " port)
      (write (cdr pair) port)
      (newline port))

    (define (test-on-test-end-simple runner)
      "Print a simple failed-test report for RUNNER."
      #((parameters
         (runner (type test-runner)
          (description "Active test runner.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read state-write))
      (let ((kind (test-result-ref runner %result-kind-key))
            (log (test-runner-aux-value runner)))
        (if (memq kind '(fail xpass))
            (let* ((results (test-result-alist runner))
                   (source-file (assq %source-file-key results))
                   (source-line (assq %source-line-key results))
                   (test-name (assq %test-name-key results)))
              (if (or source-file source-line)
                  (begin
                    (if source-file (display (cdr source-file)))
                    (display ":")
                    (if source-line (display (cdr source-line)))
                    (display ": ")))
              (display (if (eq? kind 'xpass) "XPASS" "FAIL"))
              (if test-name
                  (begin
                    (display " ")
                    (display (cdr test-name))))
              (newline)))
        (if (output-port? log)
            (begin
              (display "Test end:" log)
              (newline log)
              (let loop ((rest (test-result-alist runner)))
                (if (pair? rest)
                    (let ((pair (car rest)))
                      (if (not (memq (car pair)
                                     (list %test-name-key
                                           %source-file-key
                                           %source-line-key
                                           %source-form-key)))
                          (%test-write-result1 pair log))
                      (loop (cdr rest)))))))))))
