;;; Public Consent Scheme agent reliability measurements.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library measures deterministic agent-loop reruns from Scheme-readable
;;; fixtures.  Each trial reseeds only the model/user channel through injected
;;; runner options while policy, budgets, and tool transitions stay fixed.  The
;;; resulting stop receipts are reduced into pass^k and stop-cause slices, and
;;; a two-tier ablation shows advisory rules can be toggled while gate-enforced
;;; authority denials remain in force by construction.

(define-library (agent reliability)
  (export pass-k
          reliability-field-value
          reliability-stop-reason
          reliability-trial-passed?
          measure-reliability
          measure-policy-ablation)
  (import (scheme base)
          (scheme write)
          (agent runner)
          (agent task))
  (begin
    ;; Stop-reason buckets keep reports stable even when task receipts use more
    ;; specific lifecycle vocabulary internally.
    (define reliability-reasons
      '(complete budget-exhausted policy-denied failed-verifier))

    (define (field-named? field name)
      "Return #t when FIELD is a record field named NAME."
      (and (pair? field) (eq? (car field) name)))

    (define (field-value datum name default)
      "Return field NAME from DATUM, or DEFAULT when absent."
      (let loop ((fields (if (pair? datum) (cdr datum) '())))
        (cond
         ((null? fields) default)
         ((field-named? (car fields) name)
          (let ((values (cdr (car fields))))
            (if (null? values) default (car values))))
         (else (loop (cdr fields))))))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT if absent."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (disabled? options key)
      "Return #t when OPTIONS disables policy tier KEY."
      (eq? (option-ref options key 'enabled) 'disabled))

    (define (datum->external-string datum)
      "Render DATUM with portable write syntax for reward comparison."
      (let ((port (open-output-string)))
        (write datum port)
        (get-output-string port)))

    (define (choose-final-state expected trial)
      "Return TRIAL final state, falling back to EXPECTED."
      (field-value trial 'final-state expected))

    (define (trial-provider trial final-state)
      "Return TRIAL provider steps, defaulting to a finish of FINAL-STATE."
      (field-value trial 'provider
                   (list (list 'finish final-state))))

    (define (trial-policy trial)
      "Return the effective policy alist for TRIAL.
Gate-enforced policy is intentionally always included; callers may request a
gate ablation, but authority-denying rules are not removed."
      (append (field-value trial 'gate-policy '())
              (field-value trial 'policy '())))

    (define (advisory-enabled? options)
      "Return #t when advisory rules are active under OPTIONS."
      (not (disabled? options 'advisory-policy)))

    (define (external-final-state-matches? expected final-state)
      "Compare EXPECTED and FINAL-STATE by canonical external form."
      (string=? (datum->external-string expected)
                (datum->external-string final-state)))

    (define (trial-verifier expected trial options)
      "Return the deterministic verifier verdict for TRIAL."
      (let ((explicit (field-value trial 'verifier #f)))
        (cond
         (explicit explicit)
         ((and (external-final-state-matches?
                expected
                (choose-final-state expected trial))
               (not (and (advisory-enabled? options)
                         (field-value trial 'advisory-violated #f))))
          'passed)
         (else 'insufficient))))

    (define (trial-run-options fixture trial options)
      "Return runner options for one deterministic TRIAL."
      (let ((expected (field-value fixture 'goal-final-state '())))
        (let ((final-state (choose-final-state expected trial)))
          (append
           (list (list 'provider (trial-provider trial final-state))
                 (list 'verifier (trial-verifier expected trial options))
                 (list 'policy (trial-policy trial))
                 (list 'operations (field-value fixture 'operations '()))
                 (list 'id-prefix (field-value trial 'id 'trial)))
           (if (field-value trial 'max-steps #f)
               (list (list 'max-steps (field-value trial 'max-steps #f)))
               '())))))

    (define (receipt-raw-reason receipt)
      "Return the raw stop or pause reason from RECEIPT."
      (or (task-field-value receipt 'stop-reason #f)
          (task-field-value receipt 'pause-reason #f)
          'failed-verifier))

    (define (normalize-reason reason)
      "Map lifecycle REASON into a reliability stop-cause bucket."
      (cond
       ((eq? reason 'completed-goal) 'complete)
       ((eq? reason 'budget-exhausted) 'budget-exhausted)
       ((or (eq? reason 'approval-denied)
            (eq? reason 'authority-unavailable)
            (eq? reason 'unauthorized-tool)
            (eq? reason 'policy-denied))
        'policy-denied)
       (else 'failed-verifier)))

    (define (completion-value run)
      "Return RUN's completion value, or `none'."
      (let ((completion (task-run-completion run)))
        (if (agent-completion? completion)
            (task-field-value completion 'value 'none)
            'none)))

    (define (trial-result fixture trial options)
      "Run TRIAL through the deterministic runner and return a result datum."
      (let* ((expected (field-value fixture 'goal-final-state '()))
             (run (run-task (field-value fixture 'goal 'reliability)
                            (trial-run-options fixture trial options)))
             (receipt (task-run-receipt run))
             (reason (normalize-reason (receipt-raw-reason receipt)))
             (value (completion-value run))
             (matched? (external-final-state-matches? expected value))
             (passed? (and (eq? reason 'complete) matched?)))
        (list 'reliability-trial-result
              (list 'id (field-value trial 'id 'trial))
              (list 'model-seed (field-value trial 'model-seed 'none))
              (list 'user-seed (field-value trial 'user-seed 'none))
              (list 'stop-reason reason)
              (list 'raw-reason (receipt-raw-reason receipt))
              (list 'passed passed?)
              (list 'final-state-external (datum->external-string value))
              (list 'expected-final-state-external
                    (datum->external-string expected))
              (list 'receipt receipt))))

    (define (count-if predicate items)
      "Return the number of ITEMS satisfying PREDICATE."
      (let loop ((rest items) (count 0))
        (cond
         ((null? rest) count)
         ((predicate (car rest)) (loop (cdr rest) (+ count 1)))
         (else (loop (cdr rest) count)))))

    (define (count-reason results reason)
      "Return how many RESULTS stopped with normalized REASON."
      (count-if
       (lambda (result)
         (eq? (field-value result 'stop-reason 'failed-verifier) reason))
       results))

    (define (combination-count n k)
      "Return C(N,K) using exact integer arithmetic."
      (cond
       ((< k 0) 0)
       ((< n k) 0)
       ((or (= k 0) (= k n)) 1)
       (else
        (let ((limit (if (> k (- n k)) (- n k) k)))
          (let loop ((i 1) (num 1) (den 1))
            (if (> i limit)
                (/ num den)
                (loop (+ i 1)
                      (* num (+ (- n limit) i))
                      (* den i))))))))

    (define (slice-result results total k reason)
      "Return a reliability slice for REASON."
      (let ((count (count-reason results reason)))
        (list 'reliability-slice
              (list 'reason reason)
              (list 'count count)
              (list 'cause^k (pass-k count total k)))))

    (define (passed-count results)
      "Return how many RESULTS passed."
      (count-if
       (lambda (result)
         (field-value result 'passed #f))
       results))

    (define (pass-k passed total k)
      "Return pass^k = C(PASSED,K) / C(TOTAL,K)."
      #((parameters
         (passed (type exact-integer)
          (description "Number of successful reruns."))
         (total (type exact-integer)
          (description "Total deterministic reruns."))
         (k (type exact-integer)
          (description "Reliability exponent.")))
        (returns (type rational)
         (description "Exact pass^k value, or 0 when no k-subset exists."))
        (effects pure))
      (let ((denominator (combination-count total k)))
        (if (= denominator 0)
            0
            (/ (combination-count passed k) denominator))))

    (define (reliability-field-value datum name . maybe-default)
      "Return field NAME from a reliability datum, or DEFAULT when absent."
      #((parameters
         (datum (type list)
          (description "Reliability report, slice, or trial-result datum."))
         (name (type symbol)
          (description "Symbol naming the field to read."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . "The field value, or DEFAULT when NAME is absent.")
        (effects pure))
      (field-value datum
                   name
                   (if (null? maybe-default) #f (car maybe-default))))

    (define (reliability-stop-reason receipt)
      "Return RECEIPT's normalized reliability stop-cause bucket."
      #((parameters
         (receipt (type (or task-stop task-pause))
          (description "Task stop or pause receipt to classify.")))
        (returns (type symbol)
         (description
          ("One of `complete', `budget-exhausted', `policy-denied',"
            "or `failed-verifier'.")))
        (effects pure))
      (normalize-reason (receipt-raw-reason receipt)))

    (define (reliability-trial-passed? result)
      "Return #t when RESULT is a passed reliability trial result."
      #((parameters
         (result (type reliability-trial-result)
          (description "Trial result returned by `measure-reliability'.")))
        (returns (type boolean)
         (description "#t when the trial completed and matched the final state."))
        (effects pure))
      (field-value result 'passed #f))

    (define (measure-reliability fixture k options)
      "Run FIXTURE's deterministic trials and return pass^k measurements."
      #((parameters
         (fixture (type consent-agent-reliability-fixture)
          (description "Scheme-readable reliability fixture datum."))
         (k (type exact-integer)
          (description "Reliability exponent for pass^k."))
         (options (type list)
          (description
           ("Association list of ablation options.  `advisory-policy'"
             "may be `disabled'; `gate-enforced-policy disabled' is"
             "accepted but does not remove gate policy."))))
        (returns (type reliability-report)
         (description
          ("Report with total, passed, pass^1, pass^k, stop-reason"
            "slices, and per-trial receipts.")))
        (effects allocation))
      (let* ((trials (field-value fixture 'trials '()))
             (results
              (map (lambda (trial)
                     (trial-result fixture trial options))
                   trials))
             (total (length results))
             (passed (passed-count results)))
        (list 'reliability-report
              (list 'k k)
              (list 'total total)
              (list 'passed passed)
              (list 'pass^1 (pass-k passed total 1))
              (list 'pass^k (pass-k passed total k))
              (list 'slices
                    (map (lambda (reason)
                           (slice-result results total k reason))
                         reliability-reasons))
              (list 'trials results))))

    (define (measure-policy-ablation fixture)
      "Return the two-tier policy ablation report for FIXTURE."
      #((parameters
         (fixture (type consent-agent-reliability-fixture)
          (description "Scheme-readable reliability fixture datum.")))
        (returns (type policy-ablation-report)
         (description
          ("Baseline, advisory-disabled, and gate-disabled reports plus"
            "pass^1 deltas.  Gate-enforced policy remains active, so"
            "its delta is zero when the fixture is well formed.")))
        (effects allocation))
      (let* ((baseline (measure-reliability fixture 1 '()))
             (advisory-disabled
              (measure-reliability fixture 1 '((advisory-policy disabled))))
             (gate-disabled
              (measure-reliability fixture 1
                                   '((gate-enforced-policy disabled))))
             (baseline-pass (field-value baseline 'pass^1 0))
             (advisory-pass (field-value advisory-disabled 'pass^1 0))
             (gate-pass (field-value gate-disabled 'pass^1 0))
             (gate-delta (- gate-pass baseline-pass)))
        (list 'policy-ablation-report
              (list 'baseline baseline)
              (list 'advisory-disabled advisory-disabled)
              (list 'gate-disabled gate-disabled)
              (list 'advisory-pass^1-delta
                    (- advisory-pass baseline-pass))
              (list 'gate-pass^1-delta gate-delta)
              (list 'gate-enforced-unablatable
                    (if (= gate-delta 0) #t #f)))))))
