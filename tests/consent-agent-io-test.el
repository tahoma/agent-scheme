;;; consent-agent-io-test.el --- Agent event channel tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the `(agent io)' event channel and its audit records.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-result)

(defun consent-agent-io-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-agent-io-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-agent-io-test--audit-strings)))

(defun consent-agent-io-test--eval-result-string (source &optional options)
  "Evaluate SOURCE as a result datum and return its external string."
  (consent-result->external
   (consent-eval-source-result source nil options)))

(ert-deftest consent-agent-io-test-agent-yield-records-audit-event ()
  "Record `agent-yield' values as Scheme-readable audit entries."
  (consent-audit-clear)
  (should
   (equal
    (consent-value->external
     (consent-eval-source
      "(import (scheme base) (agent io))
       (agent-yield '(kind observation))"))
    "#<unspecified>"))
  (should
   (consent-agent-io-test--audit-entry-matching
    "(event context-event)"
    "(category agent-io)"
    "(operation \"agent-yield\")"
    "(decision recorded)"
    "(datum (kind observation))")))

(ert-deftest consent-agent-io-test-core-event-procedures-audit ()
  "Record core `(agent io)' event procedures in the audit log."
  (consent-audit-clear)
  (consent-eval-source
   "(import (scheme base) (agent io))
    (agent-log 'info \"starting\" '(scope test))
    (agent-progress 'reader '(parsed 2))
    (agent-warn \"careful\" '(kind stale-handle))
    (agent-request '(approval (policy buffer-edit)))")
  (should
   (consent-agent-io-test--audit-entry-matching
    "(event context-event)"
    "(operation \"agent-log\")"
    "(level info)"
    "(message \"starting\")"
    "(fields ((scope test)))"))
  (should
   (consent-agent-io-test--audit-entry-matching
    "(event context-event)"
    "(operation \"agent-progress\")"
    "(phase reader)"
    "(datum (parsed 2))"))
  (should
   (consent-agent-io-test--audit-entry-matching
    "(event context-event)"
    "(operation \"agent-warn\")"
    "(message \"careful\")"
    "(fields ((kind stale-handle)))"))
  (should
   (consent-agent-io-test--audit-entry-matching
    "(event context-event)"
    "(operation \"agent-request\")"
    "(request (approval (policy buffer-edit)))")))

(ert-deftest consent-agent-io-test-result-carries-ordered-yields ()
  "Return ordered event records separately from the normal value."
  (let ((result
         (consent-agent-io-test--eval-result-string
          "(import (scheme base) (agent io))
           (agent-yield '(first 1))
           (agent-yield '(second 2))
           42")))
    (should (string-match-p (regexp-quote "(status ok)") result))
    (should (string-match-p (regexp-quote "(value 42)") result))
    (should
     (string-match-p
      (regexp-quote "(events ((yield (first 1)) (yield (second 2))))")
      result))))

(ert-deftest consent-agent-io-test-result-renders-core-events ()
  "Render log, progress, warning, and request records in the eval result."
  (let ((result
         (consent-agent-io-test--eval-result-string
          "(import (scheme base) (agent io))
           (agent-log 'info \"starting\" '(scope test))
           (agent-progress 'reader '(parsed 2))
           (agent-warn \"careful\" '(kind stale-handle))
           (agent-request '(approval (policy buffer-edit)))
           'done")))
    (should
     (string-match-p
      (regexp-quote
       "(events ((log (level info) (message \"starting\") (fields ((scope test))))")
      result))
    (should
     (string-match-p
      (regexp-quote
       "(progress (phase reader) (datum (parsed 2)))")
      result))
    (should
     (string-match-p
      (regexp-quote
       "(warn (message \"careful\") (fields ((kind stale-handle))))")
      result))
    (should
     (string-match-p
      (regexp-quote
       "(request (approval (policy buffer-edit)))")
      result))))

(ert-deftest consent-agent-io-test-event-count-limit-fails-closed ()
  "Reject evaluations that emit more event records than allowed."
  (let ((result
         (consent-agent-io-test--eval-result-string
          "(import (scheme base) (agent io))
           (agent-yield '(first))
           (agent-yield '(second))
           'unreachable"
          '(:max-events 1))))
    (should (string-match-p (regexp-quote "(status error)") result))
    (should
     (string-match-p
      (regexp-quote "event count budget exceeded")
      result))
    (should
     (string-match-p
      (regexp-quote "(events ((yield (first))))")
      result))))

(ert-deftest consent-agent-io-test-event-count-limit-uncatchable-by-guard ()
  "Keep budget enforcement uncatchable by interpreted guard.
Interpreted guard converts host conditions from primitives into catchable
raises, but budget conditions must keep failing closed."
  (let ((result
         (consent-agent-io-test--eval-result-string
          "(import (scheme base) (agent io))
           (guard (condition (#t 'swallowed))
             (agent-yield '(first))
             (agent-yield '(second))
             'unreachable)"
          '(:max-events 1))))
    (should (string-match-p (regexp-quote "(status error)") result))
    (should
     (string-match-p
      (regexp-quote "event count budget exceeded")
      result))))

(ert-deftest consent-agent-io-test-event-node-limit-fails-closed ()
  "Reject oversized event records before adding them to the result payload."
  (let ((result
         (consent-agent-io-test--eval-result-string
          "(import (scheme base) (agent io))
           (agent-yield '(too many nodes))"
          '(:max-event-nodes 2))))
    (should (string-match-p (regexp-quote "(status error)") result))
    (should
     (string-match-p
      (regexp-quote "event node budget exceeded")
      result))
    (should (string-match-p (regexp-quote "(events ())") result))))

;;; consent-agent-io-test.el ends here
