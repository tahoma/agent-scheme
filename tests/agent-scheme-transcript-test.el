;;; agent-scheme-transcript-test.el --- Replayable transcript tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for transcript event datums, replay classification,
;; redaction, fixture generation, and session transcript integration.

;;; Code:

(require 'ert)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-reader)
(require 'agent-scheme-result)
(require 'agent-scheme-session)
(require 'agent-scheme-transcript)

(defun agent-scheme-transcript-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-transcript-test--reset ()
  "Reset transcript, session, and audit state for focused tests."
  (agent-scheme-transcript-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(ert-deftest agent-scheme-transcript-test-event-shape-classification-and-fixture ()
  "Create stable transcript events and pure evaluation fixtures."
  (agent-scheme-transcript-test--reset)
  (let* ((event
          (agent-scheme-transcript-event
           'eval-end
           `((session . ,(agent-scheme--syntax-symbol "replay-main"))
             (form . "(+ 1 2)")
             (result . "3")
             (yields . ())
             (policy . ,(agent-scheme-read
                         "((category pure-r7rs) (decision allowed))")))))
         (event-text (agent-scheme-transcript-test--external event))
         (fixture
          (agent-scheme-transcript-event->fixture-case event))
         (fixture-text (agent-scheme-transcript-test--external fixture)))
    (should
     (string-match-p
      (regexp-quote
       "(transcript-event (id e-1) (session replay-main) (kind eval-end)")
      event-text))
    (should (string-match-p "(replay (mode deterministic-pure)" event-text))
    (should
     (eq (agent-scheme-transcript-event-replay-mode event)
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
          (agent-scheme-transcript-event
           'capability-call
           `((session . ,(agent-scheme--syntax-symbol "replay-main"))
             (capability . ,(agent-scheme-read
                             "((emacs buffer) current-buffer)"))
             (result . ,(agent-scheme-read
                         "(host-result (status ok) (value observed))")))))
         (observation-text
          (agent-scheme-transcript-test--external observation)))
    (should (string-match-p "(replay (mode recorded-observation)"
                            observation-text))
    (should
     (eq (agent-scheme-transcript-event-replay-mode observation)
         'recorded-observation))
    (should (agent-scheme-transcript-recorded-observation-p observation))
    (should-not
     (agent-scheme-transcript-event->fixture-case observation))))

(ert-deftest agent-scheme-transcript-test-redacts-before-persistence ()
  "Transcript event creation redacts secret-bearing source and results."
  (agent-scheme-transcript-test--reset)
  (let* ((event
          (agent-scheme-transcript-event
           'eval-end
           '((session . redaction-main)
             (form . "(define token \"sk-transcriptsecret1234567890\") token")
             (result . "sk-transcriptsecret1234567890"))))
         (event-text (agent-scheme-transcript-test--external event)))
    (should (string-match-p "\\[redacted\\]" event-text))
    (should-not (string-match-p "sk-transcriptsecret" event-text))))

(ert-deftest agent-scheme-transcript-test-session-evaluations-append-events ()
  "Session evaluations append eval-start and eval-end transcript events."
  (agent-scheme-transcript-test--reset)
  (agent-scheme-session-create! 'named '(:id "transcript-main"))
  (should
   (equal
    (agent-scheme-value->external
     (agent-scheme-session-eval-source
      "transcript-main"
      "(import (scheme base) (agent io))
       (agent-yield '(ready))
       (+ 1 2)"))
    "3"))
  (let* ((session (agent-scheme-session-ref "transcript-main"))
         (transcript
          (agent-scheme-transcript-field-value session "transcript"))
         (start (car transcript))
         (end (cadr transcript))
         (end-text (agent-scheme-transcript-test--external end)))
    (should (= (length transcript) 2))
    (should (equal (agent-scheme-transcript-field-value start "id")
                   (agent-scheme--syntax-symbol "e-1")))
    (should (equal (agent-scheme-transcript-field-value start "kind")
                   (agent-scheme--syntax-symbol "eval-start")))
    (should (equal (agent-scheme-transcript-field-value end "id")
                   (agent-scheme--syntax-symbol "e-2")))
    (should (equal (agent-scheme-transcript-field-value end "kind")
                   (agent-scheme--syntax-symbol "eval-end")))
    (should (string-match-p (regexp-quote "(result \"3\")") end-text))
    (should (string-match-p
             (regexp-quote "(yields ((audit-entry")
             end-text))
    (should (string-match-p
             (regexp-quote "(record (yield (ready)))")
             end-text))
    (should
     (eq (agent-scheme-transcript-event-replay-mode end)
         'deterministic-pure))))

(ert-deftest agent-scheme-transcript-test-agent-library-loads ()
  "The public `(agent transcript)' library exposes pure transcript helpers."
  (agent-scheme-transcript-test--reset)
  (let ((result
         (agent-scheme-result->external
          (agent-scheme-eval-source-result
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

;;; agent-scheme-transcript-test.el ends here
