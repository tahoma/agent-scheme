;;; Portable registered test-case selection and reporting.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (testing registry)
  (export consent-test-case
          consent-test-register!
          consent-test-registry-clear!
          consent-test-registry
          consent-test-case-name
          consent-test-case-tags
          consent-test-case-source-file
          consent-test-case-source-line
          consent-test-select-all
          consent-test-select-name
          consent-test-select-tag
          consent-test-select-and
          consent-test-select-or
          consent-test-select-not
          consent-test-clock
          consent-test-diagnostic-hook
          consent-test-run-registered
          consent-test-rerun-failed
          consent-test-report-failed-names)
  (import (scheme base)
          (scheme write)
          (testing harness)
          (stdlib testing))
  (begin
    ;; Registered test case metadata and executable body.
    (define-record-type <consent-test-case>
      (make-consent-test-case name tags source-file source-line thunk)
      consent-test-case?
      (name consent-test-case-name)
      (tags consent-test-case-tags)
      (source-file consent-test-case-source-file)
      (source-line consent-test-case-source-line)
      (thunk consent-test-case-thunk))

    ;; Registered test cases in deterministic registration order.
    (define consent-test-registry '())

    ;; Clock procedure returning a number, or false when timing is unavailable.
    (define consent-test-clock (make-parameter (lambda () #f)))

    ;; Host hook returning diagnostic data for CASE and CONDITION.
    (define consent-test-diagnostic-hook
      (make-parameter (lambda (case condition) case condition #f)))

    (define (consent-test-registry-clear!)
      "Remove all registered portable test cases."
      #((parameters)
        (returns (type unspecified) (description "Unspecified value."))
        (effects state-write))
      (set! consent-test-registry '()))

    (define (consent-test-register! name tags source-file source-line thunk)
      "Register a named test case and return its record."
      #((parameters
         (name (type object) (description "Unique test name."))
         (tags (type list) (description "Selection tags."))
         (source-file (type (or string boolean)) (description "Source file."))
         (source-line (type (or exact-integer boolean)) (description "Line."))
         (thunk (type procedure) (description "Zero-argument test body.")))
        (returns (type consent-test-case) (description "Registered case."))
        (effects allocation state-write error))
      (if (not (procedure? thunk))
          (error "test case body must be a procedure" name))
      (let ((case (make-consent-test-case
                   name tags source-file source-line thunk)))
        (set! consent-test-registry
              (append
               (let loop ((rest consent-test-registry))
                 (cond
                  ((null? rest) '())
                  ((consent-test-key=?
                    name (consent-test-case-name (car rest)))
                   (loop (cdr rest)))
                  (else (cons (car rest) (loop (cdr rest))))))
               (list case)))
        case))

    (define (consent-test-key=? left right)
      "Return true when LEFT and RIGHT are equal test keys."
      (if (and (symbol? left) (symbol? right))
          (string=? (symbol->string left) (symbol->string right))
          (equal? left right)))

    (define (consent-test-key-member? key keys)
      "Return true when KEY occurs in KEYS."
      (let loop ((rest keys))
        (and (pair? rest)
             (or (consent-test-key=? key (car rest))
                 (loop (cdr rest))))))

    ;; Define and register a portable test case with explicit source metadata.
    (define-syntax consent-test-case
      (syntax-rules ()
        ((_ name tags (source-file source-line) body ...)
         (consent-test-register!
          name tags source-file source-line (lambda () body ...)))))

    (define (consent-test-select-all case)
      "Return true for every CASE."
      #((parameters (case (type consent-test-case) (description "Case.")))
        (returns (type boolean) (description "Always true."))
        (effects pure))
      case
      #t)

    (define (consent-test-select-name name)
      "Return a selector matching test case NAME."
      #((parameters (name (type object) (description "Test name.")))
        (returns (type procedure) (description "Case selector."))
        (effects allocation))
      (lambda (case)
        (consent-test-key=? name (consent-test-case-name case))))

    (define (consent-test-select-tag tag)
      "Return a selector matching cases carrying TAG."
      #((parameters (tag (type object) (description "Selection tag.")))
        (returns (type procedure) (description "Case selector."))
        (effects allocation))
      (lambda (case)
        (consent-test-key-member? tag (consent-test-case-tags case))))

    (define (consent-test-select-and . selectors)
      "Return a selector requiring every SELECTORS predicate."
      #((parameters (selectors (type list) (description "Selectors.")))
        (returns (type procedure) (description "Conjoined selector."))
        (effects allocation))
      (lambda (case)
        (let loop ((rest selectors))
          (or (null? rest)
              (and ((car rest) case) (loop (cdr rest)))))))

    (define (consent-test-select-or . selectors)
      "Return a selector accepting any SELECTORS predicate."
      #((parameters (selectors (type list) (description "Selectors.")))
        (returns (type procedure) (description "Disjoined selector."))
        (effects allocation))
      (lambda (case)
        (let loop ((rest selectors))
          (and (pair? rest)
               (or ((car rest) case) (loop (cdr rest)))))))

    (define (consent-test-select-not selector)
      "Return the complement of SELECTOR."
      #((parameters (selector (type procedure) (description "Selector.")))
        (returns (type procedure) (description "Complement selector."))
        (effects allocation))
      (lambda (case) (not (selector case))))

    (define (consent-test-counts runner)
      "Return RUNNER's unexpected-result counts."
      (list (test-runner-fail-count runner)
            (test-runner-xpass-count runner)))

    (define (consent-test-case-result case status duration diagnostic)
      "Return a Scheme-readable result for CASE."
      (list 'consent-test-case-result
            (list 'name (consent-test-case-name case))
            (list 'tags (consent-test-case-tags case))
            (list 'source-file (consent-test-case-source-file case))
            (list 'source-line (consent-test-case-source-line case))
            (list 'duration duration)
            (list 'status status)
            (list 'diagnostic diagnostic)))

    (define (consent-test-run-case runner case)
      "Run CASE with RUNNER and return its portable result record."
      (let ((before (consent-test-counts runner))
            (started ((consent-test-clock)))
            (raised #f))
        (guard (condition
                (else
                 (set! raised condition)
                 (test-assert (consent-test-case-name case) #f)))
          ((consent-test-case-thunk case)))
        (let* ((finished ((consent-test-clock)))
               (after (consent-test-counts runner))
               (failed? (not (equal? before after)))
               (duration (if (and (number? started) (number? finished))
                             (- finished started)
                             #f))
               (diagnostic
                (if failed?
                    ((consent-test-diagnostic-hook) case raised)
                    #f)))
          (consent-test-case-result
           case (if failed? 'fail 'pass) duration diagnostic))))

    (define (consent-test-report-failed-names report)
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

    (define (consent-test-run-registered suite selector)
      "Run registered cases selected by SELECTOR and return a report."
      #((parameters
         (suite (type object) (description "Suite name."))
         (selector (type procedure) (description "Case selector.")))
        (returns (type list) (description "Portable test report."))
        (effects state-read state-write port-io error))
      (let ((runner (test-runner-simple)) (results '()))
        (test-with-runner runner
          (test-begin suite)
          (for-each
           (lambda (case)
             (if (selector case)
                 (set! results
                       (cons (consent-test-run-case runner case) results))))
           consent-test-registry)
          (test-end suite))
        (let ((report
               (list 'consent-test-report
                     (list 'summary
                           (consent-test-runner-summary suite runner))
                     (list 'cases (reverse results)))))
          (write report)
          (newline)
          (if (consent-test-runner-failed? runner)
              (error "Consent registered test suite failed" report)
              report))))

    (define (consent-test-rerun-failed suite report)
      "Rerun the cases that failed in REPORT."
      #((parameters
         (suite (type object) (description "Rerun suite name."))
         (report (type list) (description "Prior test report.")))
        (returns (type list) (description "Portable rerun report."))
        (effects state-read state-write port-io error))
      (let ((names (consent-test-report-failed-names report)))
        (consent-test-run-registered
         suite
         (lambda (case)
           (consent-test-key-member?
            (consent-test-case-name case) names)))))))
