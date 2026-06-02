;;; consent-transcript-test.el --- Replayable transcript tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for transcript event datums, replay classification,
;; redaction, fixture generation, and session transcript integration.

;;; Code:

(require 'ert)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-result)
(require 'consent-session)
(require 'consent-transcript)

(defun consent-transcript-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-transcript-test--reset ()
  "Reset transcript, session, and audit state for focused tests."
  (consent-transcript-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(ert-deftest consent-transcript-test-event-shape-classification-and-fixture ()
  "Create stable transcript events and pure evaluation fixtures."
  (consent-transcript-test--reset)
  (let* ((event
          (consent-transcript-event
           'eval-end
           `((session . ,(consent--syntax-symbol "replay-main"))
             (form . "(+ 1 2)")
             (result . "3")
             (yields . ())
             (policy . ,(consent-read
                         "((category pure-r7rs) (decision allowed))")))))
         (event-text (consent-transcript-test--external event))
         (fixture
          (consent-transcript-event->fixture-case event))
         (fixture-text (consent-transcript-test--external fixture)))
    (should
     (string-match-p
      (regexp-quote
       "(transcript-event (id e-1) (session replay-main) (kind eval-end)")
      event-text))
    (should (string-match-p "(replay (mode deterministic-pure)" event-text))
    (should
     (eq (consent-transcript-event-replay-mode event)
         'deterministic-pure))
    (should
     (string-match-p
      (regexp-quote "(id transcript-e-1)")
      fixture-text))
    (should
     (string-match-p
      (regexp-quote "(phase eval)")
      fixture-text))
    (should
     (string-match-p
      (regexp-quote "(source \"(+ 1 2)\")")
      fixture-text))
    (should
     (string-match-p
      (regexp-quote "(expect (value \"3\"))")
      fixture-text)))
  (let* ((observation
          (consent-transcript-event
           'capability-call
           `((session . ,(consent--syntax-symbol "replay-main"))
             (capability . ,(consent-read
                             "((emacs buffer) current-buffer)"))
             (result . ,(consent-read
                         "(host-result (status ok) (value observed))")))))
         (observation-text
          (consent-transcript-test--external observation)))
    (should (string-match-p "(replay (mode recorded-observation)"
                            observation-text))
    (should
     (eq (consent-transcript-event-replay-mode observation)
         'recorded-observation))
    (should (consent-transcript-recorded-observation-p observation))
    (should-not
     (consent-transcript-event->fixture-case observation))))

(ert-deftest consent-transcript-test-redacts-before-persistence ()
  "Transcript event creation redacts secret-bearing source and results."
  (consent-transcript-test--reset)
  (let* ((event
          (consent-transcript-event
           'eval-end
           '((session . redaction-main)
             (form . "(define token \"sk-transcriptsecret1234567890\") token")
             (result . "sk-transcriptsecret1234567890"))))
         (event-text (consent-transcript-test--external event)))
    (should (string-match-p "\\[redacted\\]" event-text))
    (should-not (string-match-p "sk-transcriptsecret" event-text))))

(ert-deftest consent-transcript-test-session-evaluations-append-events ()
  "Session evaluations append eval-start and eval-end transcript events."
  (consent-transcript-test--reset)
  (consent-session-create! 'named '(:id "transcript-main"))
  (should
   (equal
    (consent-value->external
     (consent-session-eval-source
      "transcript-main"
      "(import (scheme base) (agent io))
       (agent-yield '(ready))
       (+ 1 2)"))
    "3"))
  (let* ((session (consent-session-ref "transcript-main"))
         (transcript
          (consent-transcript-field-value session "transcript"))
         (start (car transcript))
         (end (cadr transcript))
         (end-text (consent-transcript-test--external end)))
    (should (= (length transcript) 2))
    (should (equal (consent-transcript-field-value start "id")
                   (consent--syntax-symbol "e-1")))
    (should (equal (consent-transcript-field-value start "kind")
                   (consent--syntax-symbol "eval-start")))
    (should (equal (consent-transcript-field-value end "id")
                   (consent--syntax-symbol "e-2")))
    (should (equal (consent-transcript-field-value end "kind")
                   (consent--syntax-symbol "eval-end")))
    (should (string-match-p (regexp-quote "(result \"3\")") end-text))
    (should (string-match-p
             (regexp-quote "(yields ((audit-entry")
             end-text))
    (should (string-match-p
             (regexp-quote "(record (yield (ready)))")
             end-text))
    (should
     (eq (consent-transcript-event-replay-mode end)
         'deterministic-pure))))

(ert-deftest consent-transcript-test-agent-library-loads ()
  "The public `(agent transcript)' library exposes pure transcript helpers."
  (consent-transcript-test--reset)
  (let ((result
         (consent-result->external
          (consent-eval-source-result
           "(import (scheme base) (agent transcript))
            (transcript-event-replay-mode
             (make-transcript-event
              'eval-end
              '((id e-import)
                (form \"(+ 1 2)\")
                (result \"3\"))))"))))
    (should
     (string-match-p
      (regexp-quote "(evaluation-result (status ok) (value deterministic-pure)")
      result))))

;;; consent-transcript-test.el ends here
