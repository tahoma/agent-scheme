;;; Portable generated-source loop tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; These tests exercise the host-neutral `(agent generated-source)' library:
;;; deterministic candidate normalization, reader diagnostics, sandbox
;;; evaluation-result analysis, caller contracts, bounded repair retries, and
;;; explicit live-session application gating.  Model calls and live evaluation
;;; are represented by injected procedures so this file stays portable across
;;; direct R7RS hosts and the self-hosted Consent runner.

(import (scheme base)
        (scheme write)
        (agent generated-source))

;; Count failed checks so the portable runner can report every mismatch.
(define failures 0)

;; Record one failed check and keep running the rest of the portable test file.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal?.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Assert VALUE is true after normalizing to canonical booleans.
(define (check-true name value)
  (check name (if value #t #f) #t))

;; Return FIELD's value from RECORD, or #f when absent.
(define (field record field)
  (generated-source-record-field-value record field #f))

;; Return the first diagnostic reason from RECORD.
(define (first-diagnostic-reason record)
  (let ((diagnostics (field record 'diagnostics)))
    (if (pair? diagnostics)
        (field (car diagnostics) 'reason)
        #f)))

;; Return a successful evaluation-result carrying BINDINGS.
(define (ok-evaluation bindings)
  (list 'evaluation-result
        (list 'status 'ok)
        (list 'value 'sandbox-ok)
        (list 'stdout "sandbox output\n")
        (list 'bindings bindings)
        (list 'events '())
        (list 'budget (list 'steps-used 7) (list 'host-calls 0))))

;; Return an evaluation-result for an unbound variable named SYMBOL.
(define (unbound-evaluation symbol)
  (list 'evaluation-result
        (list 'status 'error)
        (list 'error
              (list 'condition
                    (list 'condition
                          (list 'type 'unbound-variable)
                          (list 'symbol symbol)
                          (list 'message "unbound identifier")))
              (list 'host-condition 'error)
              (list 'message
                    "consent eval error: unbound identifier: missing-helper"))
        (list 'events '())
        (list 'budget (list 'steps-used 2) (list 'host-calls 0))))

;; Return #t when LIST contains VALUE under equal?.
(define (contains? list value)
  (cond
   ((null? list) #f)
   ((equal? (car list) value) #t)
   (else (contains? (cdr list) value))))

;;;; Candidate normalization

(let ((candidate
       (generated-source-candidate "(define answer 42)\nanswer\n")))
  (check-true 'plain-candidate-record
              (generated-source-candidate? candidate))
  (check 'plain-candidate-status
         (generated-source-candidate-status candidate)
         'ready)
  (check 'plain-candidate-kind (field candidate 'kind) 'plain)
  (check 'plain-candidate-source
         (generated-source-candidate-source candidate)
         "(define answer 42)\nanswer\n")
  (check 'plain-candidate-forms
         (length (generated-source-candidate-forms candidate))
         2))

(let ((candidate
       (generated-source-candidate
        "```scheme\n(define answer 42)\nanswer\n```\n")))
  (check 'fenced-candidate-status
         (generated-source-candidate-status candidate)
         'ready)
  (check 'fenced-candidate-kind (field candidate 'kind) 'markdown-fence)
  (check 'fenced-candidate-source
         (generated-source-candidate-source candidate)
         "(define answer 42)\nanswer\n"))

(let ((candidate
       (generated-source-candidate
        "Here is the code:\n```scheme\n(define answer 42)\n```\n")))
  (check 'prose-candidate-status
         (generated-source-candidate-status candidate)
         'rejected)
  (check 'prose-candidate-diagnostic
         (first-diagnostic-reason candidate)
         'mixed-markdown-output))

(let ((candidate
       (generated-source-candidate
        "```scheme\n(define a 1)\n```\n```scheme\n(define b 2)\n```\n")))
  (check 'multiple-fence-status
         (generated-source-candidate-status candidate)
         'rejected)
  (check 'multiple-fence-diagnostic
         (first-diagnostic-reason candidate)
         'ambiguous-markdown-fences))

(let ((candidate
       (generated-source-candidate "This is explanatory prose.")))
  (check 'plain-prose-status
         (generated-source-candidate-status candidate)
         'rejected)
  (check 'plain-prose-diagnostic
         (first-diagnostic-reason candidate)
         'prose-output))

(let ((candidate
       (generated-source-candidate "(define (broken x)\n")))
  (check 'reader-error-status
         (generated-source-candidate-status candidate)
         'read-error)
  (check 'reader-error-diagnostic
         (field (car (generated-source-candidate-diagnostics candidate))
                'stage)
         'read))

;;;; Sandbox evaluation and contracts

(let* ((loop
        (generated-source-run
         "(define deriv 1)\n(define differentiator-tests 'ok)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (ok-evaluation '(deriv differentiator-tests))))
               (list 'required-bindings '(deriv differentiator-tests))
               (cons 'post-check
                     (lambda (candidate evaluation)
                       (and (generated-source-candidate? candidate)
                            (equal? (field evaluation 'value)
                                    'sandbox-ok)))))))
       (attempt (car (generated-source-run-attempts loop))))
  (check 'sandbox-success-status
         (generated-source-run-status loop)
         'accepted)
  (check 'sandbox-success-candidate
         (generated-source-candidate-status
          (generated-source-run-candidate loop))
         'ready)
  (check 'sandbox-success-stdout
         (field (field attempt 'evaluation) 'stdout)
         "sandbox output\n")
  (check 'sandbox-success-diagnostics
         (generated-source-run-diagnostics loop)
         '()))

(let* ((loop
        (generated-source-run
         "(missing-helper 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (unbound-evaluation 'missing-helper))))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (check 'unbound-status
         (generated-source-run-status loop)
         'rejected)
  (check 'unbound-diagnostic-reason
         (field diagnostic 'reason)
         'unbound-variable)
  (check 'unbound-missing-binding
         (field diagnostic 'binding)
         'missing-helper))

(let* ((loop
        (generated-source-run
         "(define other 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (ok-evaluation '(other))))
               (list 'required-bindings '(deriv)))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (check 'contract-status
         (generated-source-run-status loop)
         'rejected)
  (check 'contract-diagnostic-reason
         (field diagnostic 'reason)
         'missing-binding)
  (check 'contract-diagnostic-binding
         (field diagnostic 'binding)
         'deriv))

(let* ((loop
        (generated-source-run
         "(define deriv 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (ok-evaluation '(deriv))))
               (list 'required-imports '((scheme base))))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (check 'import-contract-status
         (generated-source-run-status loop)
         'rejected)
  (check 'import-contract-diagnostic-reason
         (field diagnostic 'reason)
         'missing-import)
  (check 'import-contract-diagnostic-import
         (field diagnostic 'import)
         '(scheme base)))

;;;; Bounded repair retries

(let ((repair-inputs '()))
  (let* ((loop
          (generated-source-run
           "(missing-helper 1)\n"
           (list (cons 'evaluate
                       (lambda (candidate)
                         (if (contains?
                              (generated-source-candidate-forms candidate)
                              '(define deriv 1))
                             (ok-evaluation '(deriv))
                             (unbound-evaluation 'missing-helper))))
                 (list 'required-bindings '(deriv))
                 (list 'max-retries 1)
                 (cons 'repair
                       (lambda (attempt repair-prompt)
                         (set! repair-inputs
                               (cons repair-prompt repair-inputs))
                         "(define deriv 1)\n")))))
         (attempts (generated-source-run-attempts loop)))
    (check 'repair-status (generated-source-run-status loop) 'accepted)
    (check 'repair-attempt-count (length attempts) 2)
    (check 'repair-prompt-count
           (length (generated-source-run-repair-prompts loop))
           1)
    (check-true 'repair-prompt-includes-diagnostic
                (contains?
                 (field (car repair-inputs) 'diagnostic-reasons)
                 'unbound-variable))))

;;;; Explicit apply gating

(let ((applied '()))
  (let* ((rejected
          (generated-source-run
           "This is prose."
           (list (cons 'evaluate
                       (lambda (candidate)
                         (ok-evaluation '(deriv)))))))
         (application
          (generated-source-apply
           rejected
           (lambda (candidate)
             (set! applied (cons candidate applied))
             'applied))))
    (check 'rejected-apply-status (field application 'status) 'rejected)
    (check 'rejected-apply-not-called applied '())))

(let ((applied '()))
  (let* ((accepted
          (generated-source-run
           "(define deriv 1)\n"
           (list (cons 'evaluate
                       (lambda (candidate)
                         (ok-evaluation '(deriv))))
                 (list 'required-bindings '(deriv)))))
         (application
          (generated-source-apply
           accepted
           (lambda (candidate)
             (set! applied (cons candidate applied))
             'applied))))
    (check 'accepted-apply-status (field application 'status) 'applied)
    (check 'accepted-apply-result (field application 'result) 'applied)
    (check 'accepted-apply-called (length applied) 1)))

(if (> failures 0)
    (begin
      (display failures)
      (display " generated-source checks failed")
      (newline)
      (error "portable generated-source tests failed" failures)))
