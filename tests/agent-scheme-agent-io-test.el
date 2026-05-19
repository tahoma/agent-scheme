;;; agent-scheme-agent-io-test.el --- Agent event channel tests  -*- lexical-binding: t; -*-

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

;;; agent-scheme-agent-io-test.el ends here
