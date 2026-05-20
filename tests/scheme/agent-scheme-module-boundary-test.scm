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
        (prefix (agent-scheme memory) memory:)
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
