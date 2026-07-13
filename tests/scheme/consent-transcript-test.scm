;;; Portable replayable transcript tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and checks the public
;;; `(agent transcript)' datum helpers without loading the Emacs host adapter.

(import (scheme base)
        (scheme write)
        (agent transcript)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

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

(testing-registry-case
 'pure-event-shape '(portable core)
 ("consent-transcript-test.scm" 27)
(test-assert 'pure-event-shape (transcript-event? pure-event)))
(testing-registry-case
 'pure-event-mode '(portable core)
 ("consent-transcript-test.scm" 31)
(test-equal 'pure-event-mode
             'deterministic-pure
             (transcript-event-replay-mode pure-event)))
(testing-registry-case
 'pure-event-replayable '(portable core)
 ("consent-transcript-test.scm" 37)
(test-assert 'pure-event-replayable (transcript-replayable? pure-event)))
(testing-registry-case
 'pure-event-session '(portable core)
 ("consent-transcript-test.scm" 41)
(test-equal 'pure-event-session
             'portable-main
             (transcript-field-value pure-event 'session)))
(testing-registry-case
 'pure-event-fixture '(portable core)
 ("consent-transcript-test.scm" 47)
(test-equal 'pure-event-fixture
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
         (expect (value "3")))
             (transcript-event->fixture-case pure-event)))

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

(testing-registry-case
 'host-event-mode '(portable core)
 ("consent-transcript-test.scm" 75)
(test-equal 'host-event-mode
             'recorded-observation
             (transcript-event-replay-mode host-event)))
(testing-registry-case
 'host-event-observation '(portable core)
 ("consent-transcript-test.scm" 81)
(test-assert 'host-event-observation
             (transcript-recorded-observation? host-event)))
(testing-registry-case
 'host-event-no-fixture '(portable core)
 ("consent-transcript-test.scm" 86)
(test-assert 'host-event-no-fixture
             (not (transcript-event->fixture-case host-event))))

;; Transcript views keep raw datums available and provide human summaries for
;; buffers and exports.
(testing-registry-case
 'raw-view '(portable core)
 ("consent-transcript-test.scm" 94)
(test-equal 'raw-view
             (list pure-event host-event)
             (transcript-raw-view (list pure-event host-event))))
(testing-registry-case
 'summary-view '(portable core)
 ("consent-transcript-test.scm" 100)
(test-equal 'summary-view
             '("e-portable eval-end in portable-main => 3"
         "e-host capability-call in portable-main recorded observation")
             (transcript-summary-view (list pure-event host-event))))
(testing-registry-case
 'rotation '(portable core)
 ("consent-transcript-test.scm" 107)
(test-equal 'rotation
             (list host-event)
             (transcript-rotate (list pure-event host-event) 1)))

(testing-runner-main "Consent Transcript portable tests" (command-line))
