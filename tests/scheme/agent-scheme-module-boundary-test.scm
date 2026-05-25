;;; Portable Agent Scheme module-boundary test runner.
;;;
;;; This program runs under an external R7RS Scheme and verifies that the
;;; portable pass-boundary libraries expose their expected public surfaces.

(import (scheme base)
        (scheme write)
        (prefix (agent-scheme runtime) runtime:)
        (prefix (agent-scheme base) base:)
        (prefix (agent-scheme library) library:)
        (prefix (agent-scheme macro) macro:)
        (prefix (agent-scheme approval) approval:)
        (prefix (agent-scheme job) job:)
        (prefix (agent-scheme memory) memory:)
        (prefix (agent-scheme context) context:)
        (prefix (agent-scheme redaction) redaction:)
        (prefix (agent-scheme session) session:)
        (prefix (agent-scheme interpreter) interpreter:))

;; Record one failed portable module-boundary check.
(define failures 0)

;; Record one failed portable module-boundary check and keep running.
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

;; Report whether THUNK raises a Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(check 'runtime-boundary
       (procedure? runtime:agent-scheme-make-empty-environment)
       #t)

(check 'base-boundary
       (if (memq '+ (base:agent-scheme-base-primitive-names)) #t #f)
       #t)

(check 'library-boundary
       (pair? (library:agent-scheme-standard-source-library-specs))
       #t)

(check 'macro-boundary
       (procedure? macro:agent-scheme-expand-source)
       #t)

;; Store for exercising the portable approval boundary.
(define approval-store (approval:agent-scheme-make-approval-store))

;; Approval records are canonical Scheme-readable datums.
(define portable-approval-id
  (approval:approval-request!
   approval-store
   '(approval-request
      (policy buffer-edit)
      (effect (buffer-replace! h-1 1 2 "x"))
      (reason "Replace text?"))))

(check 'approval-boundary-request-status
       (approval:approval-status approval-store portable-approval-id)
       'pending)

(check 'approval-boundary-pending
       (length (approval:approval-pending approval-store))
       1)

(approval:approval-resolve! approval-store portable-approval-id 'denied)

(check 'approval-boundary-resolved-status
       (approval:approval-status approval-store portable-approval-id)
       'denied)

(check 'approval-boundary-cancel-resolved-denied
       (raises?
        (lambda ()
          (approval:approval-cancel! approval-store portable-approval-id)))
       #t)

;; Store for exercising the portable job boundary.
(define job-store (job:agent-scheme-make-job-store))

;; Job records are canonical Scheme-readable datums even when a host adapter
;; owns actual scheduling.
(define portable-job
  (job:job-start! job-store
                  'portable-main
                  '(begin (agent-yield '(phase ready)) 'done)
                  '((max-steps . 100))))

;; Id of the portable job record under test.
(define portable-job-id (job:job-datum-id portable-job))

(check 'job-boundary-start-status
       (job:job-status job-store portable-job-id)
       'queued)

(job:job-mark-running! job-store portable-job-id)
(job:job-record-yield! job-store portable-job-id '(yield (phase ready)))

(check 'job-boundary-stream-yield
       (job:job-yields job-store portable-job-id '())
       '((yield (phase ready))))

(job:job-cancel! job-store portable-job-id)

(check 'job-boundary-cancel-requested
       (job:job-status job-store portable-job-id)
       'cancel-requested)

(job:job-finish-cancelled! job-store portable-job-id "job cancelled: j-1")

(check 'job-boundary-cancelled-status
       (job:job-status job-store portable-job-id)
       'cancelled)

;; Store for exercising the portable memory boundary.
(define memory-store (memory:agent-scheme-make-memory-store))

;; Memory records are canonical Scheme-readable datums.
(define portable-memory
  (memory:memory-put! memory-store
                      'instance
                      'portable-key
                      '((tags (portable fact))
                        (value "portable memory")
                        (confidence high))))

(check 'memory-boundary-put-ref
       (memory:memory-record-id
        (memory:memory-ref memory-store 'instance 'portable-key))
       'portable-key)

(check 'memory-boundary-by-tag
       (length (memory:memory-by-tag memory-store 'instance 'portable))
       1)

(check 'memory-boundary-find
       (length (memory:memory-find memory-store 'instance "portable memory"))
       1)

;; Context helpers preserve canonical Scheme-readable record shape.
(check 'context-boundary-request-record
       (car (context:make-request-context 'portable-req
                                          #f
                                          "portable request"))
       'request-context)

;; Portable redaction records never reveal the original secret.
(define portable-secret
  '((source env)
    (field "OPENAI_API_KEY")
    (value "sk-portablesecret1234567890")))

;; Redacted portable secret datum used for boundary checks.
(define redacted-secret
  (redaction:redact portable-secret 'remote-provider))

(check 'redaction-boundary-secret-source
       (redaction:secret-source? portable-secret)
       #t)

(check 'redaction-boundary-redact-record
       (car redacted-secret)
       'redaction)

(check 'redaction-boundary-provider-safe
       (redaction:safe-for-provider? portable-secret 'openai)
       #f)

(check 'redaction-boundary-local-only-provider-safe
       (redaction:safe-for-provider?
        (redaction:context-local-only!
         '((buffer "private-notes") (text "do not send"))
         "private buffer")
        'openai)
       #f)

;; Store for exercising the portable session lifecycle boundary.
(define session-store (session:agent-scheme-make-session-store))

;; Session datum created through the portable session module.
(define portable-session
  (session:session-create! session-store
                           'named
                           '((id portable-main))))

(check 'session-boundary-create-ref
       (session:session-datum-id
        (session:session-ref session-store 'portable-main))
       'portable-main)

(check 'session-boundary-snapshot
       (car (session:session-snapshot! session-store
                                       'portable-main
                                       '((id portable-snap))))
       'session-snapshot)

(check 'interpreter-boundary
       (interpreter:agent-scheme-value->external
        (interpreter:agent-scheme-eval-source "(+ 1 2)"))
       "3")

(if (= failures 0)
    (begin
      (display "Scheme module-boundary tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme module-boundary test failure(s)")
      (newline)
      (error "Scheme module-boundary tests failed")))
