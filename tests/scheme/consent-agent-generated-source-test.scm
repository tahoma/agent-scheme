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
        (agent generated-source)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

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

(testing-registry-case
 'plain-candidate-record '(portable agent)
(let ((candidate
       (generated-source-candidate "(define answer 42)\nanswer\n")))
  (test-assert 'plain-candidate-record
             (generated-source-candidate? candidate))
  (test-equal 'plain-candidate-status
             'ready
             (generated-source-candidate-status candidate))
  (test-equal 'plain-candidate-kind 'plain (field candidate 'kind))
  (test-equal 'plain-candidate-source
             "(define answer 42)\nanswer\n"
             (generated-source-candidate-source candidate))
  (test-equal 'plain-candidate-forms
             2
             (length (generated-source-candidate-forms candidate)))))

(testing-registry-case
 'fenced-candidate-status '(portable agent)
(let ((candidate
       (generated-source-candidate
        "```scheme\n(define answer 42)\nanswer\n```\n")))
  (test-equal 'fenced-candidate-status
             'ready
             (generated-source-candidate-status candidate))
  (test-equal 'fenced-candidate-kind 'markdown-fence (field candidate 'kind))
  (test-equal 'fenced-candidate-source
             "(define answer 42)\nanswer\n"
             (generated-source-candidate-source candidate))))

(testing-registry-case
 'prose-candidate-status '(portable agent)
(let ((candidate
       (generated-source-candidate
        "Here is the code:\n```scheme\n(define answer 42)\n```\n")))
  (test-equal 'prose-candidate-status
             'rejected
             (generated-source-candidate-status candidate))
  (test-equal 'prose-candidate-diagnostic
             'mixed-markdown-output
             (first-diagnostic-reason candidate))))

(testing-registry-case
 'multiple-fence-status '(portable agent)
(let ((candidate
       (generated-source-candidate
        "```scheme\n(define a 1)\n```\n```scheme\n(define b 2)\n```\n")))
  (test-equal 'multiple-fence-status
             'rejected
             (generated-source-candidate-status candidate))
  (test-equal 'multiple-fence-diagnostic
             'ambiguous-markdown-fences
             (first-diagnostic-reason candidate))))

(testing-registry-case
 'plain-prose-status '(portable agent)
(let ((candidate
       (generated-source-candidate "This is explanatory prose.")))
  (test-equal 'plain-prose-status
             'rejected
             (generated-source-candidate-status candidate))
  (test-equal 'plain-prose-diagnostic
             'prose-output
             (first-diagnostic-reason candidate))))

(testing-registry-case
 'reader-error-status '(portable agent)
(let ((candidate
       (generated-source-candidate "(define (broken x)\n")))
  (test-equal 'reader-error-status
             'read-error
             (generated-source-candidate-status candidate))
  (test-equal 'reader-error-diagnostic
             'read
             (field (car (generated-source-candidate-diagnostics candidate))
                'stage))))

;;;; Sandbox evaluation and contracts

(testing-registry-case
 'sandbox-success-status '(portable agent)
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
  (test-equal 'sandbox-success-status
             'accepted
             (generated-source-run-status loop))
  (test-equal 'sandbox-success-candidate
             'ready
             (generated-source-candidate-status
          (generated-source-run-candidate loop)))
  (test-equal 'sandbox-success-stdout
             "sandbox output\n"
             (field (field attempt 'evaluation) 'stdout))
  (test-equal 'sandbox-success-diagnostics
             '()
             (generated-source-run-diagnostics loop))))

(testing-registry-case
 'unbound-status '(portable agent)
(let* ((loop
        (generated-source-run
         "(missing-helper 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (unbound-evaluation 'missing-helper))))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (test-equal 'unbound-status
             'rejected
             (generated-source-run-status loop))
  (test-equal 'unbound-diagnostic-reason
             'unbound-variable
             (field diagnostic 'reason))
  (test-equal 'unbound-missing-binding
             'missing-helper
             (field diagnostic 'binding))))

(testing-registry-case
 'contract-status '(portable agent)
(let* ((loop
        (generated-source-run
         "(define other 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (ok-evaluation '(other))))
               (list 'required-bindings '(deriv)))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (test-equal 'contract-status
             'rejected
             (generated-source-run-status loop))
  (test-equal 'contract-diagnostic-reason
             'missing-binding
             (field diagnostic 'reason))
  (test-equal 'contract-diagnostic-binding
             'deriv
             (field diagnostic 'binding))))

(testing-registry-case
 'improper-evaluation-result-rejected '(portable agent)
(let* ((loop
        (generated-source-run
         "(define deriv 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       '(evaluation-result
                         (status ok)
                         . malformed-tail))))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (test-equal 'improper-evaluation-result-status
              'rejected
              (generated-source-run-status loop))
  (test-equal 'improper-evaluation-result-reason
              'invalid-evaluation-result
              (field diagnostic 'reason))))

(testing-registry-case
 'import-contract-status '(portable agent)
(let* ((loop
        (generated-source-run
         "(define deriv 1)\n"
         (list (cons 'evaluate
                     (lambda (candidate)
                       (ok-evaluation '(deriv))))
               (list 'required-imports '((scheme base))))))
       (diagnostic (car (generated-source-run-diagnostics loop))))
  (test-equal 'import-contract-status
             'rejected
             (generated-source-run-status loop))
  (test-equal 'import-contract-diagnostic-reason
             'missing-import
             (field diagnostic 'reason))
  (test-equal 'import-contract-diagnostic-import
             '(scheme base)
             (field diagnostic 'import))))

;;;; Bounded repair retries

(testing-registry-case
 'repair-status '(portable agent)
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
    (test-equal 'repair-status 'accepted (generated-source-run-status loop))
    (test-equal 'repair-attempt-count 2 (length attempts))
    (test-equal 'repair-prompt-count
             1
             (length (generated-source-run-repair-prompts loop)))
    (test-assert 'repair-prompt-includes-diagnostic
             (contains?
                 (field (car repair-inputs) 'diagnostic-reasons)
                 'unbound-variable)))))

;;;; Explicit apply gating

(testing-registry-case
 'rejected-apply-status '(portable agent)
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
    (test-equal 'rejected-apply-status 'rejected (field application 'status))
    (test-equal 'rejected-apply-not-called '() applied))))

(testing-registry-case
 'accepted-apply-status '(portable agent)
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
    (test-equal 'accepted-apply-status 'applied (field application 'status))
    (test-equal 'accepted-apply-result 'applied (field application 'result))
    (test-equal 'accepted-apply-called 1 (length applied)))))

(testing-runner-main "Consent Agent Generated Source portable tests"
  (command-line))
