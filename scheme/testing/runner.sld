;;; Portable developer-facing test runner.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (testing runner)
  (export testing-runner-selector
          testing-runner-options
          testing-runner-last-report
          testing-runner-rerun-failed
          testing-runner-run
          testing-runner-plan-files
          testing-runner-plan-main
          testing-runner-main)
  (import (scheme base)
          (scheme file)
          (scheme process-context)
          (scheme read)
          (scheme time)
          (scheme write)
          (testing plan)
          (testing registry))
  (begin
    ;; Most recent in-process report, for REPL inspection and reruns.
    (define testing-runner-last-report #f)

    (define (testing-runner-read text)
      "Read one Scheme datum from TEXT."
      (let* ((port (open-input-string text))
             (datum (read port))
             (trailing (read port)))
        (if (eof-object? datum)
            (error "missing selector datum" text))
        (if (not (eof-object? trailing))
            (error "selector contains trailing data" text))
        datum))

    (define (testing-runner-string-contains? text fragment)
      "Return true when TEXT contains FRAGMENT."
      (let ((text-length (string-length text))
            (fragment-length (string-length fragment)))
        (let loop ((index 0))
          (and (<= (+ index fragment-length) text-length)
               (or (string=?
                    fragment (substring text index (+ index fragment-length)))
                   (loop (+ index 1)))))))

    (define (testing-runner-name-contains fragment)
      "Return a selector matching case names containing FRAGMENT."
      (lambda (case)
        (let ((name (testing-registry-case-name case)))
          (testing-runner-string-contains?
           (if (symbol? name) (symbol->string name) name)
           fragment))))

    (define (testing-runner-selector datum)
      "Compile selector DATUM into a registered-case predicate."
      #((parameters (datum (type object) (description "Selector datum.")))
        (returns (type procedure) (description "Case predicate."))
        (effects allocation error))
      (cond
       ((eq? datum #t) testing-registry-select-all)
       ((symbol? datum)
        (testing-registry-select-name datum))
       ((string? datum) (testing-runner-name-contains datum))
       ((and (pair? datum) (eq? (car datum) 'all) (null? (cdr datum)))
        testing-registry-select-all)
       ((and (pair? datum) (eq? (car datum) 'name)
             (pair? (cdr datum)) (null? (cddr datum)))
        (testing-registry-select-name (cadr datum)))
       ((and (pair? datum) (eq? (car datum) 'tag)
             (pair? (cdr datum)) (null? (cddr datum)))
        (testing-registry-select-tag (cadr datum)))
       ((and (pair? datum) (eq? (car datum) 'and))
        (apply testing-registry-select-and
               (map testing-runner-selector (cdr datum))))
       ((and (pair? datum) (eq? (car datum) 'or))
        (apply testing-registry-select-or
               (map testing-runner-selector (cdr datum))))
       ((and (pair? datum) (eq? (car datum) 'not)
             (pair? (cdr datum)) (null? (cddr datum)))
        (testing-registry-select-not
         (testing-runner-selector (cadr datum))))
       (else (error "invalid test selector" datum))))

    (define (testing-runner-options arguments)
      "Parse runner ARGUMENTS into a portable option alist."
      #((parameters (arguments (type list) (description "Argument strings.")))
        (returns (type list) (description "Runner options."))
        (effects allocation error))
      (let loop ((rest arguments)
                 (selector '(all))
                 (list? #f)
                 (help? #f)
                 (verbose? #f)
                 (report-file #f)
                 (rerun-file #f))
        (cond
         ((null? rest)
          (list (list 'selector selector)
                (list 'list? list?)
                (list 'help? help?)
                (list 'verbose? verbose?)
                (list 'report-file report-file)
                (list 'rerun-file rerun-file)))
         ((string=? (car rest) "--list")
          (loop (cdr rest) selector #t help? verbose? report-file rerun-file))
         ((or (string=? (car rest) "--help")
              (string=? (car rest) "-h"))
          (loop (cdr rest) selector list? #t verbose? report-file rerun-file))
         ((string=? (car rest) "--verbose")
          (loop (cdr rest) selector list? help? #t report-file rerun-file))
         ((or (string=? (car rest) "--select")
              (string=? (car rest) "--report")
              (string=? (car rest) "--rerun-failed"))
          (if (null? (cdr rest)) (error "missing test runner option value" (car rest)))
          (cond
           ((string=? (car rest) "--select")
            (loop (cddr rest) (testing-runner-read (cadr rest))
                  list? help? verbose? report-file rerun-file))
           ((string=? (car rest) "--report")
            (loop (cddr rest) selector list? help? verbose?
                  (cadr rest) rerun-file))
           (else
            (loop (cddr rest) selector list? help? verbose?
                  report-file (cadr rest)))))
         (else (error "unknown test runner option" (car rest))))))

    (define (testing-runner-option options name)
      "Return option NAME from OPTIONS."
      (let ((entry (assq name options))) (and entry (cadr entry))))

    (define (testing-runner-effective-arguments arguments)
      "Return explicit ARGUMENTS or the portable environment fallback."
      (if (pair? (cdr arguments))
          (cdr arguments)
          (let ((encoded
                 (get-environment-variable "TESTING_RUNNER_ARGUMENTS")))
            (if encoded
                (let ((decoded (testing-runner-read encoded)))
                  (if (not (list? decoded))
                      (error "TESTING_RUNNER_ARGUMENTS must contain a list"))
                  decoded)
                '()))))

    (define (testing-runner-clock)
      "Return elapsed seconds from the implementation jiffy clock."
      (/ (current-jiffy) (jiffies-per-second)))

    (define (testing-runner-diagnostic case condition)
      "Return portable diagnostic data for CASE and CONDITION."
      (let ((port (open-output-string)))
        (write condition port)
        (list 'condition
              (list 'case (testing-registry-case-name case))
              (list 'rendered (get-output-string port)))))

    (define (testing-runner-read-report path)
      "Read a prior test report from PATH."
      (call-with-input-file path
        (lambda (port)
          (let ((report (read port)))
            (if (eof-object? report) (error "empty test report" path))
            report))))

    (define (testing-runner-write-report path report)
      "Write REPORT to PATH when PATH is true."
      (if path
          (call-with-output-file path
            (lambda (port) (write report port) (newline port)))))

    (define (testing-runner-list selector)
      "Write registered cases accepted by SELECTOR."
      (let ((selected
             (let loop ((rest testing-registry-cases) (result '()))
               (cond
                ((null? rest) (reverse result))
                ((selector (car rest)) (loop (cdr rest) (cons (car rest) result)))
                (else (loop (cdr rest) result))))))
        (write
         (list 'testing-runner-list
               (list 'cases
                     (map
                      (lambda (case)
                        (list (testing-registry-case-name case)
                              (testing-registry-case-tags case)
                              (testing-registry-case-source-file case)
                              (testing-registry-case-source-line case)))
                      selected))))
        (newline)
        selected))

    (define (testing-runner-report report verbose?)
      "Write a concise REPORT, or the full report when VERBOSE? is true."
      (if verbose?
          (write report)
          (let* ((cases (cadr (assq 'cases (cdr report))))
                 (failed (testing-registry-report-failed-names report))
                 (summary (cadr (assq 'summary (cdr report)))))
            (write
             (list 'testing-runner-summary
                   (assq 'suite (cdr summary))
                   (list 'cases (length cases))
                   (list 'failed failed)))
            (for-each
             (lambda (case)
               (if (eq? (cadr (assq 'status (cdr case))) 'fail)
                   (begin (newline) (write case))))
             cases)))
      (newline))

    (define (testing-runner-help)
      "Write portable test runner usage."
      (display "options: --list --select DATUM --verbose --report FILE ")
      (display "--rerun-failed FILE --help")
      (newline)
      (display "selectors: (all), NAME, STRING, (name NAME), (tag TAG), ")
      (display "(and ...), (or ...), (not SELECTOR)")
      (newline))

    (define (testing-runner-rerun-failed suite)
      "Rerun failed cases from the most recent in-process report."
      #((parameters (suite (type object) (description "Rerun suite name.")))
        (returns (type list) (description "Rerun report."))
        (effects state-read state-write port-io error))
      (if (not testing-runner-last-report)
          (error "no prior test report is available"))
      (let ((report
             (parameterize
                 ((testing-registry-clock testing-runner-clock)
                  (testing-registry-diagnostic-hook testing-runner-diagnostic))
               (testing-registry-rerun-failed
                suite testing-runner-last-report))))
        (set! testing-runner-last-report report)
        (testing-runner-report report #f)
        report))

    (define (testing-runner-run suite options)
      "Run or list SUITE according to OPTIONS and return a result record."
      #((parameters
         (suite (type object) (description "Suite name."))
         (options (type list) (description "Parsed runner options.")))
        (returns (type list) (description "Runner result record."))
        (effects state-read state-write file-read file-write port-io error))
      (let* ((prior-file (testing-runner-option options 'rerun-file))
             (selector
              (if prior-file
                  (let ((failed
                         (testing-registry-report-failed-names
                          (testing-runner-read-report prior-file))))
                    (lambda (case)
                      (let loop ((names failed))
                        (and (pair? names)
                             (or (equal? (testing-registry-case-name case)
                                         (car names))
                                 (loop (cdr names)))))))
                  (testing-runner-selector
                   (testing-runner-option options 'selector)))))
        (cond
         ((testing-runner-option options 'help?)
          (testing-runner-help)
          (list 'testing-runner-result (list 'status 'helped)))
         ((testing-runner-option options 'list?)
          (list 'testing-runner-result
                (list 'status 'listed)
                (list 'cases (testing-runner-list selector))))
         (else
          (let ((report
                 (parameterize
                     ((testing-registry-clock testing-runner-clock)
                      (testing-registry-diagnostic-hook
                       testing-runner-diagnostic))
                   (testing-registry-run-registered suite selector))))
            (set! testing-runner-last-report report)
            (testing-runner-report
             report (testing-runner-option options 'verbose?))
            (testing-runner-write-report
             (testing-runner-option options 'report-file) report)
            (list 'testing-runner-result
                  (list 'status
                        (if (testing-registry-report-failed? report)
                            'failed
                            'passed))
                  (list 'report report)))))))

    (define (testing-runner-plan-files plan-path shard-name)
      "Return files selected from PLAN-PATH by SHARD-NAME."
      #((parameters
         (plan-path (type string) (description "Scheme test-plan path."))
         (shard-name (type symbol) (description "Named plan shard.")))
        (returns (type (list-of string)) (description "Selected files."))
        (effects file-read allocation error))
      (testing-plan-files (testing-plan-read plan-path) shard-name))

    (define (testing-runner-plan-option arguments option fallback)
      "Return OPTION's value from ARGUMENTS, or FALLBACK when absent."
      (let loop ((rest arguments))
        (cond
         ((null? rest) fallback)
         ((null? (cdr rest))
          (error "missing test plan runner option value" (car rest)))
         ((string=? (car rest) option) (cadr rest))
         ((or (string=? (car rest) "--plan")
              (string=? (car rest) "--shard"))
          (loop (cddr rest)))
         (else (error "unknown test plan runner option" (car rest))))))

    (define (testing-runner-plan-main arguments)
      "Resolve a Scheme test plan and write selected program paths."
      #((parameters
         (arguments (type list) (description "Command line including program.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects environment-read file-read port-io error))
      (guard (condition
              (else
               (write (list 'testing-runner-plan-error condition)
                      (current-error-port))
               (newline (current-error-port))
               (raise condition)))
        (let* ((environment-plan
                (get-environment-variable "TESTING_PLAN_FILE"))
               (environment-shard
                (get-environment-variable "TESTING_PLAN_SHARD"))
               (effective
                (if (and environment-plan environment-shard)
                    '()
                    (testing-runner-effective-arguments arguments)))
               (plan-path
                (if environment-plan
                    environment-plan
                    (testing-runner-plan-option effective "--plan" #f)))
               (shard-text
                (if environment-shard
                    environment-shard
                    (testing-runner-plan-option effective "--shard" #f))))
          (if (not plan-path) (error "missing test plan path"))
          (if (not shard-text) (error "missing test plan shard"))
          (for-each
           (lambda (path) (display path) (newline))
           (testing-runner-plan-files
            plan-path (string->symbol shard-text))))))

    (define (testing-runner-main suite arguments)
      "Run SUITE from command-line ARGUMENTS and complete with batch status."
      #((parameters
         (suite (type object) (description "Suite name."))
         (arguments (type list) (description "Command line including program.")))
        (returns (type unspecified)
         (description
          ("Does not return during ordinary process execution; returns"
            "zero inside a compiled host-run interaction.")))
        (effects process-exit state-read state-write file-read file-write port-io error))
      (let ((status
             (guard (condition
                     (else
                      (write (list 'testing-runner-error condition)
                             (current-error-port))
                      (newline (current-error-port))
                      2))
               (let* ((result
                       (testing-runner-run
                        suite
                        (testing-runner-options
                         (testing-runner-effective-arguments arguments))))
                      (result-status (cadr (assq 'status (cdr result)))))
                 (if (eq? result-status 'failed) 1 0)))))
        (if (get-environment-variable "TESTING_RUNNER_HOST_RUN")
            (if (= status 0)
                status
                (error "compiled host-run test program failed" status))
            (exit status))))))
