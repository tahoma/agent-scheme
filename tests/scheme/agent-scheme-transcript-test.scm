;;; Portable replayable transcript tests.
;;;
;;; This program runs under an external R7RS Scheme and checks the public
;;; `(agent transcript)' datum helpers without loading the Emacs host adapter.

(import (scheme base)
        (scheme write)
        (agent transcript))

;; Count failed checks so the portable runner can report all mismatches.
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

;; Assert VALUE is false after normalizing to canonical booleans.
(define (check-false name value)
  (check name (if value #t #f) #f))

;; Pure evaluation events classify as deterministic replay and generate
;; executable fixture cases.
(define pure-event
  (make-transcript-event
   'eval-end
   '((id e-portable)
     (session portable-main)
     (form "(+ 1 2)")
     (result "3")
     (time "2026-05-26T00:00:00+0000"))))

(check-true 'pure-event-shape (transcript-event? pure-event))
(check 'pure-event-mode
       (transcript-event-replay-mode pure-event)
       'deterministic-pure)
(check-true 'pure-event-replayable (transcript-replayable? pure-event))
(check 'pure-event-session
       (transcript-field-value pure-event 'session)
       'portable-main)
(check 'pure-event-fixture
       (transcript-event->fixture-case pure-event)
       '((id transcript-e-portable)
         (kind agent-specific)
         (phase eval)
         (category transcript-replay)
         (section "agent transcript")
         (status implemented)
         (oracle shared)
         (options ())
         (description "Generated from transcript event e-portable.")
         (source "(+ 1 2)")
         (expect (value "3"))))

;; Host effects become recorded observations and are never silently re-run as
;; test fixtures.
(define host-event
  (make-transcript-event
   'capability-call
   '((id e-host)
     (session portable-main)
     (capability ((emacs buffer) current-buffer))
     (result (host-result (status ok) (value observed)))
     (time "2026-05-26T00:00:00+0000"))))

(check 'host-event-mode
       (transcript-event-replay-mode host-event)
       'recorded-observation)
(check-true 'host-event-observation
             (transcript-recorded-observation? host-event))
(check-false 'host-event-no-fixture
             (transcript-event->fixture-case host-event))

;; Transcript views keep raw datums available and provide human summaries for
;; buffers and exports.
(check 'raw-view
       (transcript-raw-view (list pure-event host-event))
       (list pure-event host-event))
(check 'summary-view
       (transcript-summary-view (list pure-event host-event))
       '("e-portable eval-end in portable-main => 3"
         "e-host capability-call in portable-main recorded observation"))
(check 'rotation
       (transcript-rotate (list pure-event host-event) 1)
       (list host-event))

(if (> failures 0)
    (error "portable transcript tests failed" failures))
