;;; Portable Agent Scheme module-boundary test runner.
;;;
;;; This program runs under an external R7RS Scheme and verifies that the
;;; portable facade libraries mirror the Emacs Lisp pass-boundary modules.

(import (scheme base)
        (scheme write)
        (prefix (agent-scheme runtime) runtime:)
        (prefix (agent-scheme base) base:)
        (prefix (agent-scheme library) library:)
        (prefix (agent-scheme macro) macro:)
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

(check 'runtime-facade
       (procedure? runtime:agent-scheme-make-empty-environment)
       #t)

(check 'base-facade
       (if (memq '+ (base:agent-scheme-base-primitive-names)) #t #f)
       #t)

(check 'library-facade
       (pair? (library:agent-scheme-standard-source-library-specs))
       #t)

(check 'macro-facade
       (procedure? macro:agent-scheme-expand-source)
       #t)

(check 'interpreter-facade
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
