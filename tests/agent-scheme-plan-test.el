;;; agent-scheme-plan-test.el --- First-class planning library tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for `(agent plan)' as editable Scheme data with scoped
;; stores, step updates, event yielding, memory summaries, and plan buffers.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-memory)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-plan-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-plan-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-plan-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-plan-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-plan-test--audit-strings)))

(defun agent-scheme-plan-test--reset ()
  "Reset plan, memory, session, and audit state for a focused test."
  (when (require 'agent-scheme-plan nil t)
    (agent-scheme-plan-clear!))
  (agent-scheme-memory-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(defun agent-scheme-plan-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest agent-scheme-plan-test-crud-step-status-and-scope ()
  "Scheme code can create, inspect, list, and update scoped plans."
  (agent-scheme-plan-test--reset)
  (let ((value
         (agent-scheme-plan-test--value-external
          (agent-scheme-eval-source
           "(import (scheme base) (agent plan))
            (plan-create!
             '(plan
                (id launch)
                (scope project)
                (goal \"Expose planning data\")
                (steps (((id reader) (status pending))))))
            (plan-step-add!
             'launch
             '((id tests) (status pending) (goal \"Run plan tests\")))
            (plan-step-status! 'launch 'reader 'done)
            (plan-status! 'launch 'active)
            (list (plan-ref 'launch)
                  (plan-list 'project))"))))
    (should (string-match-p "(plan (id launch)" value))
    (should (string-match-p "(scope project)" value))
    (should (string-match-p "(goal \"Expose planning data\")" value))
    (should (string-match-p "(status active)" value))
    (should (string-match-p "(id reader) (status done)" value))
    (should (string-match-p "(id tests) (status pending)" value)))
  (should
   (agent-scheme-plan-test--audit-entry-matching
    "(event agent-plan)"
    "(operation \"plan-step-status!\")"
    "(plan launch)"
    "(step reader)"
    "(status done)")))

(ert-deftest agent-scheme-plan-test-session-scope-is-isolated ()
  "Session plans are tied to the active durable session."
  (agent-scheme-plan-test--reset)
  (agent-scheme-session-create! 'named '(:id "plan-alpha"))
  (agent-scheme-session-create! 'named '(:id "plan-beta"))
  (should
   (string-match-p
    "(scope session)"
    (agent-scheme-plan-test--value-external
     (agent-scheme-session-eval-source
      "plan-alpha"
      "(import (scheme base) (agent plan))
       (plan-create!
        '(plan
           (id alpha-plan)
           (scope session)
           (goal \"Keep session-local plan\")
           (steps ())))"))))
  (should
   (string-match-p
    "(id alpha-plan)"
    (agent-scheme-plan-test--value-external
     (agent-scheme-session-eval-source
      "plan-alpha"
      "(import (scheme base) (agent plan))
       (plan-ref 'alpha-plan)"))))
  (should
   (equal
    (agent-scheme-plan-test--value-external
     (agent-scheme-session-eval-source
      "plan-beta"
      "(import (scheme base) (agent plan))
       (plan-list 'session)"))
    "()"))
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (agent plan))
     (plan-list 'session)")
   :type 'agent-scheme-plan-error))

(ert-deftest agent-scheme-plan-test-yield-memory-and-buffer ()
  "Plans can be yielded, summarized to memory, and opened in a plan buffer."
  (agent-scheme-plan-test--reset)
  (let ((result
         (agent-scheme-plan-test--external
          (agent-scheme-eval-source-result
           "(import (scheme base) (agent plan) (agent memory))
            (plan-create!
             '(plan
                (id shared)
                (scope project)
                (goal \"Share a REPL plan\")
                (memory important)
                (steps ())))
            (plan-step-add!
             'shared
             '((id review) (status pending) (goal \"Review with user\")))
            (plan-step-status! 'shared 'review 'active)
            (list (plan-yield 'shared)
                  (memory-ref 'project 'shared))"))))
    (should (string-match-p "(status ok)" result))
    (should (string-match-p "(events ((yield (plan (id shared)" result))
    (should (string-match-p "(tags (plan important))" result))
    (should (string-match-p "(value (plan (id shared)" result)))
  (let ((buffer (agent-scheme-plan-open 'project)))
    (should (equal (buffer-name buffer) "*Agent Plans: project*"))
    (should (eq (buffer-local-value 'major-mode buffer)
                'agent-scheme-plan-mode))
    (should-not (buffer-local-value 'buffer-read-only buffer))
    (should
     (string-match-p
      "(agent-plans (scope project)"
      (agent-scheme-plan-test--buffer-string buffer)))
    (should
     (string-match-p
      "(goal \"Share a REPL plan\")"
      (agent-scheme-plan-test--buffer-string buffer)))))

;;; agent-scheme-plan-test.el ends here
