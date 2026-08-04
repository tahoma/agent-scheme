;;; Portable registered test-case selection and reporting.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (testing registry)
  (export testing-registry-case
          testing-registry-register!
          testing-registry-clear!
          testing-registry-cases
          testing-registry-case-name
          testing-registry-case-tags
          testing-registry-case-source-file
          testing-registry-case-source-line
          testing-registry-select-all
          testing-registry-select-name
          testing-registry-select-tag
          testing-registry-select-and
          testing-registry-select-or
          testing-registry-select-not
          testing-registry-clock
          testing-registry-diagnostic-hook
          testing-registry-run-registered
          testing-registry-rerun-failed
          testing-registry-report-failed?
          testing-registry-report-failed-names)
  (import (scheme base)
          (scheme write)
          (testing harness)
          (stdlib testing))
  (begin
    ;; Registered test case metadata and executable body.
    (define-record-type <testing-registry-case>
      (make-testing-registry-case name tags source-file source-line thunk)
      testing-registry-case?
      (name testing-registry-case-name)
      (tags testing-registry-case-tags)
      (source-file testing-registry-case-source-file)
      (source-line testing-registry-case-source-line)
      (thunk testing-registry-case-thunk))

    ;; Registered test cases in deterministic registration order.
    (define testing-registry-cases '())

    ;; Clock procedure returning a number, or false when timing is unavailable.
    (define testing-registry-clock (make-parameter (lambda () #f)))

    ;; Host hook returning diagnostic data for CASE and CONDITION.
    (define testing-registry-diagnostic-hook
      (make-parameter (lambda (case condition) case condition #f)))

    (define (testing-registry-clear!)
      "Remove all registered portable test cases."
      #((parameters)
        (returns (type unspecified) (description "Unspecified value."))
        (effects state-write))
      (set! testing-registry-cases '()))

    (define (testing-registry-register! name tags source-file source-line
      thunk)
      "Register a named test case and return its record."
      #((parameters
         (name (type object) (description "Unique test name."))
         (tags (type list) (description "Selection tags."))
         (source-file (type (or string boolean)) (description "Source file."))
         (source-line (type (or exact-integer boolean)) (description "Line."))
         (thunk (type procedure) (description "Zero-argument test body.")))
        (returns (type testing-registry-case) (description "Registered case."))
        (effects allocation state-write error))
      (if (not (procedure? thunk))
          (error "test case body must be a procedure" name))
      (let ((case (make-testing-registry-case
                   name tags source-file source-line thunk)))
        (set! testing-registry-cases
              (append
               (let loop ((rest testing-registry-cases))
                 (cond
                  ((null? rest) '())
                  ((testing-registry-key=?
                    name (testing-registry-case-name (car rest)))
                   (loop (cdr rest)))
                  (else (cons (car rest) (loop (cdr rest))))))
               (list case)))
        case))

    (define (testing-registry-key=? left right)
      "Return true when LEFT and RIGHT are equal test keys."
      (if (and (symbol? left) (symbol? right))
          (string=? (symbol->string left) (symbol->string right))
          (equal? left right)))

    (define (testing-registry-key-member? key keys)
      "Return true when KEY occurs in KEYS."
      (let loop ((rest keys))
        (and (pair? rest)
             (or (testing-registry-key=? key (car rest))
                 (loop (cdr rest))))))

    ;; Define and register a portable test case, optionally with source
    ;; metadata.
    (define-syntax testing-registry-case
      (syntax-rules (source)
        ((_ name tags (source source-file source-line) body ...)
         (testing-registry-register!
          name tags source-file source-line (lambda () body ...)))
        ((_ name tags body ...)
         (testing-registry-register!
          name tags #f #f (lambda () body ...)))))

    (define (testing-registry-select-all case)
      "Return true for every CASE."
      #((parameters (case (type testing-registry-case) (description "Case.")))
        (returns (type boolean) (description "Always true."))
        (effects pure))
      case
      #t)

    (define (testing-registry-select-name name)
      "Return a selector matching test case NAME."
      #((parameters (name (type object) (description "Test name.")))
        (returns (type procedure) (description "Case selector."))
        (effects allocation))
      (lambda (case)
        (testing-registry-key=? name (testing-registry-case-name case))))

    (define (testing-registry-select-tag tag)
      "Return a selector matching cases carrying TAG."
      #((parameters (tag (type object) (description "Selection tag.")))
        (returns (type procedure) (description "Case selector."))
        (effects allocation))
      (lambda (case)
        (testing-registry-key-member? tag (testing-registry-case-tags case))))

    (define (testing-registry-select-and . selectors)
      "Return a selector requiring every SELECTORS predicate."
      #((parameters (selectors (type list) (description "Selectors.")))
        (returns (type procedure) (description "Conjoined selector."))
        (effects allocation))
      (lambda (case)
        (let loop ((rest selectors))
          (or (null? rest)
              (and ((car rest) case) (loop (cdr rest)))))))

    (define (testing-registry-select-or . selectors)
      "Return a selector accepting any SELECTORS predicate."
      #((parameters (selectors (type list) (description "Selectors.")))
        (returns (type procedure) (description "Disjoined selector."))
        (effects allocation))
      (lambda (case)
        (let loop ((rest selectors))
          (and (pair? rest)
               (or ((car rest) case) (loop (cdr rest)))))))

    (define (testing-registry-select-not selector)
      "Return the complement of SELECTOR."
      #((parameters (selector (type procedure) (description "Selector.")))
        (returns (type procedure) (description "Complement selector."))
        (effects allocation))
      (lambda (case) (not (selector case))))

    (define (testing-registry-counts runner)
      "Return RUNNER's result counts."
      (list (test-runner-pass-count runner)
            (test-runner-fail-count runner)
            (test-runner-xfail-count runner)
            (test-runner-xpass-count runner)
            (test-runner-skip-count runner)))

    (define (testing-registry-count-delta before after)
      "Subtract result count list BEFORE from AFTER."
      (map - after before))

    (define (testing-registry-new-results current previous)
      "Return result alists added to CURRENT since PREVIOUS."
      (let loop ((rest current) (results '()))
        (if (eq? rest previous)
            (reverse results)
            (loop (cdr rest) (cons (car rest) results)))))

    (define (testing-registry-case-result
             case status duration counts assertions diagnostic)
      "Return a Scheme-readable result for CASE."
      (list 'testing-registry-case-result
            (list 'name (testing-registry-case-name case))
            (list 'tags (testing-registry-case-tags case))
            (list 'source-file (testing-registry-case-source-file case))
            (list 'source-line (testing-registry-case-source-line case))
            (list 'duration duration)
            (list 'status status)
            (list 'counts counts)
            (list 'assertions assertions)
            (list 'diagnostic diagnostic)))

    (define (testing-registry-run-case runner case results)
      "Run CASE with RUNNER and return its portable result record."
      (let ((before (testing-registry-counts runner))
            (results-before (results))
            (started ((testing-registry-clock)))
            (raised #f))
        (guard (condition
                (else
                 (set! raised condition)
                 (test-assert (testing-registry-case-name case) #f)))
          ((testing-registry-case-thunk case)))
        (let* ((finished ((testing-registry-clock)))
               (after (testing-registry-counts runner))
               (counts (testing-registry-count-delta before after))
               (failed? (or (> (cadr counts) 0) (> (list-ref counts 3) 0)))
               (duration (if (and (number? started) (number? finished))
                             (- finished started)
                             #f))
               (diagnostic
                (if failed?
                    ((testing-registry-diagnostic-hook)
                     case (or raised 'assertion-failed))
                    #f)))
          (testing-registry-case-result
           case
           (cond
            (failed? 'fail)
            ((and (= (car counts) 0) (> (list-ref counts 4) 0)) 'skip)
            ((and (= (car counts) 0) (> (list-ref counts 2) 0)) 'xfail)
            (else 'pass))
           duration
           counts
           (testing-registry-new-results (results) results-before)
           diagnostic))))

    (define (testing-registry-report-failed-names report)
      "Return failed test names from REPORT."
      #((parameters (report (type list) (description "Test report.")))
        (returns (type list) (description "Failed case names."))
        (effects allocation error))
      (let loop ((results (cadr (assq 'cases (cdr report)))) (names '()))
        (if (null? results)
            (reverse names)
            (let* ((result (car results))
                   (status (cadr (assq 'status (cdr result))))
                   (name (cadr (assq 'name (cdr result)))))
              (loop (cdr results)
                    (if (eq? status 'fail) (cons name names) names))))))

    (define (testing-registry-report-failed? report)
      "Return true when REPORT contains a failed case."
      #((parameters (report (type list) (description "Test report.")))
        (returns (type boolean) (description "True when a case failed."))
        (effects pure error))
      (pair? (testing-registry-report-failed-names report)))

    (define (testing-registry-run-registered suite selector)
      "Run registered cases selected by SELECTOR and return a report."
      #((parameters
         (suite (type object) (description "Suite name."))
         (selector (type procedure) (description "Case selector.")))
        (returns (type list) (description "Portable test report."))
        (effects state-read state-write port-io error))
      (let* ((runner (test-runner-simple))
             (results '())
             (assertion-results '())
             (simple-end (test-runner-on-test-end runner)))
        (test-runner-on-test-end!
         runner
         (lambda (runner)
           (set! assertion-results
                 (cons (test-result-alist runner) assertion-results))
           (simple-end runner)))
        (test-with-runner runner
          (test-begin suite)
          (for-each
           (lambda (case)
             (if (selector case)
                 (set! results
                       (cons
                        (testing-registry-run-case
                         runner case (lambda () assertion-results))
                        results))))
           testing-registry-cases)
          (test-end suite))
        (list 'testing-registry-report
              (list 'summary
                    (testing-harness-runner-summary suite runner))
              (list 'cases (reverse results)))))

    (define (testing-registry-rerun-failed suite report)
      "Rerun the cases that failed in REPORT."
      #((parameters
         (suite (type object) (description "Rerun suite name."))
         (report (type list) (description "Prior test report.")))
        (returns (type list) (description "Portable rerun report."))
        (effects state-read state-write port-io error))
      (let ((names (testing-registry-report-failed-names report)))
        (testing-registry-run-registered
         suite
         (lambda (case)
           (testing-registry-key-member?
            (testing-registry-case-name case) names)))))))
