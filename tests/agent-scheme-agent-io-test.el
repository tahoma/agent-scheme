;;; agent-scheme-agent-io-test.el --- Agent event channel tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the `(agent io)' event channel and its audit records.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)

(defun agent-scheme-agent-io-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-agent-io-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-agent-io-test--audit-strings)))

(defun agent-scheme-agent-io-test--eval-result-string (source &optional options)
  "Evaluate SOURCE as a result datum and return its external string."
  (agent-scheme-result->external
   (agent-scheme-eval-source-result source nil options)))

(ert-deftest agent-scheme-agent-io-test-agent-yield-records-audit-event ()
  "Record `agent-yield' values as Scheme-readable audit entries."
  (agent-scheme-audit-clear)
  (should
   (equal
    (agent-scheme-value->external
     (agent-scheme-eval-source
      "(import (scheme base) (agent io))
       (agent-yield '(kind observation))"))
    "#<unspecified>"))
  (should
   (agent-scheme-agent-io-test--audit-entry-matching
    "(event agent-event)"
    "(category agent-io)"
    "(operation \"agent-yield\")"
    "(decision recorded)"
    "(datum (kind observation))")))

(ert-deftest agent-scheme-agent-io-test-core-event-procedures-audit ()
  "Record core `(agent io)' event procedures in the audit log."
  (agent-scheme-audit-clear)
  (agent-scheme-eval-source
   "(import (scheme base) (agent io))
    (agent-log 'info \"starting\" '(scope test))
    (agent-progress 'reader '(parsed 2))
    (agent-warn \"careful\" '(kind stale-handle))
    (agent-request '(approval (policy buffer-edit)))")
  (should
   (agent-scheme-agent-io-test--audit-entry-matching
    "(event agent-event)"
    "(operation \"agent-log\")"
    "(level info)"
    "(message \"starting\")"
    "(fields ((scope test)))"))
  (should
   (agent-scheme-agent-io-test--audit-entry-matching
    "(event agent-event)"
    "(operation \"agent-progress\")"
    "(phase reader)"
    "(datum (parsed 2))"))
  (should
   (agent-scheme-agent-io-test--audit-entry-matching
    "(event agent-event)"
    "(operation \"agent-warn\")"
    "(message \"careful\")"
    "(fields ((kind stale-handle)))"))
  (should
   (agent-scheme-agent-io-test--audit-entry-matching
    "(event agent-event)"
    "(operation \"agent-request\")"
    "(request (approval (policy buffer-edit)))")))

(ert-deftest agent-scheme-agent-io-test-result-carries-ordered-yields ()
  "Return ordered event records separately from the normal value."
  (let ((result
         (agent-scheme-agent-io-test--eval-result-string
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

(ert-deftest agent-scheme-agent-io-test-result-renders-core-events ()
  "Render log, progress, warning, and request records in the eval result."
  (let ((result
         (agent-scheme-agent-io-test--eval-result-string
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

(ert-deftest agent-scheme-agent-io-test-event-count-limit-fails-closed ()
  "Reject evaluations that emit more event records than allowed."
  (let ((result
         (agent-scheme-agent-io-test--eval-result-string
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

(ert-deftest agent-scheme-agent-io-test-event-node-limit-fails-closed ()
  "Reject oversized event records before adding them to the result payload."
  (let ((result
         (agent-scheme-agent-io-test--eval-result-string
          "(import (scheme base) (agent io))
           (agent-yield '(too many nodes))"
          '(:max-event-nodes 2))))
    (should (string-match-p (regexp-quote "(status error)") result))
    (should
     (string-match-p
      (regexp-quote "event node budget exceeded")
      result))
    (should (string-match-p (regexp-quote "(events ())") result))))

;;; agent-scheme-agent-io-test.el ends here
