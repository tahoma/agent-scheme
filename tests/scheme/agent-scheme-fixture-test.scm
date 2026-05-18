;;; Portable shared fixture runner for Agent Scheme.
;;;
;;; This program runs under an external R7RS Scheme, validates the canonical
;;; fixture corpus, and executes shared reader/evaluator cases without loading
;;; the Emacs host adapter.

(import (scheme base)
        (scheme file)
        (scheme read)
        (scheme write)
        (agent-scheme reader)
        (agent-scheme eval))

;; Count failed checks so the portable runner can report all fixture mismatches.
(define failures 0)

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

;; Decode the portable evaluator's `(values ...)' external wrapper when a case
;; expects multiple values.
(define (external-values external)
  (let ((datum (agent-scheme-read external)))
    (if (and (pair? datum) (eq? (car datum) 'values))
        (map agent-scheme-datum->external (cdr datum))
        #f)))

;; Evaluate SOURCE with OPTIONS and normalize the result for expectation checks.
(define (eval-actual source options expect)
  (let ((external
         (agent-scheme-value->external
          (agent-scheme-eval-source source #f options))))
    (if (values-expectation? expect)
        (let ((values (external-values external)))
          (if values
              (list 'values values)
              (list 'value external)))
        (list 'value external))))

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
              (agent-scheme-datum->external
               (agent-scheme-read source options))))
       ((eq? phase 'read-all)
        (list 'values
              (map agent-scheme-datum->external
                   (agent-scheme-read-all source options))))
       ((eq? phase 'expand)
        (list 'values
              (map agent-scheme-datum->external
                   (agent-scheme-expand-source source #f options))))
       ((eq? phase 'eval)
        (eval-actual source options expect))
       ((eq? phase 'eval-result)
        (list 'result
              (agent-scheme-result->external
               (agent-scheme-eval-source-result source #f options))))
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
(define suite (read-suite))

;; Shared fixture case list extracted from the canonical suite.
(define cases (suite-cases suite))

(check 'fixture-suite-tag (car suite) 'agent-scheme-fixture-suite)
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
