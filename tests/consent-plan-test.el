;;; consent-plan-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for `(agent plan)' as editable Scheme data with scoped
;; stores, step updates, event yielding, memory summaries, and plan buffers.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-memory)
(require 'consent-result)
(require 'consent-session)

(defun consent-plan-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-plan-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-plan-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-plan-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-plan-test--audit-strings)))

(defun consent-plan-test--reset ()
  "Reset plan, memory, session, and audit state for a focused test."
  (when (require 'consent-plan nil t)
    (consent-plan-clear!))
  (consent-memory-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(defun consent-plan-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest consent-plan-test-emacs-adapter-has-no-pure-store-twin ()
  "Keep pure plan store semantics in the source-loaded library."
  (dolist (helper '(consent--plan-find-by-id
                    consent--plan-generated-id
                    consent--plan-make-record
                    consent--plan-next-sequence
                    consent--plan-normalize-step
                    consent--plan-normalize-steps
                    consent--plan-replace-record
                    consent--plan-touch))
    (should-not (fboundp helper))))

(ert-deftest consent-plan-test-crud-step-status-and-scope ()
  "Scheme code can create, inspect, list, and update scoped plans."
  (consent-plan-test--reset)
  (let ((value
         (consent-plan-test--value-external
          (consent-eval-source
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
   (consent-plan-test--audit-entry-matching
    "(event agent-plan)"
    "(operation \"plan-step-status!\")"
    "(plan launch)"
    "(step reader)"
    "(status done)")))

(ert-deftest consent-plan-test-session-scope-is-isolated ()
  "Session plans are tied to the active durable session."
  (consent-plan-test--reset)
  (consent-session-create! 'named '(:id "plan-alpha"))
  (consent-session-create! 'named '(:id "plan-beta"))
  (should
   (string-match-p
    "(scope session)"
    (consent-plan-test--value-external
     (consent-session-eval-source
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
    (consent-plan-test--value-external
     (consent-session-eval-source
      "plan-alpha"
      "(import (scheme base) (agent plan))
       (plan-ref 'alpha-plan)"))))
  (should
   (equal
    (consent-plan-test--value-external
     (consent-session-eval-source
      "plan-beta"
      "(import (scheme base) (agent plan))
       (plan-list 'session)"))
    "()"))
  (should-error
   (consent-eval-source
    "(import (scheme base) (agent plan))
     (plan-list 'session)")
   :type 'consent-plan-error))

(ert-deftest consent-plan-test-yield-memory-and-buffer ()
  "Plans can be yielded, summarized to memory, and opened in a plan buffer."
  (consent-plan-test--reset)
  (let ((result
         (consent-plan-test--external
          (consent-eval-source-result
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
  (let ((buffer (consent-plan-open 'project)))
    (should (equal (buffer-name buffer) "*Consent Plans: project*"))
    (should (eq (buffer-local-value 'major-mode buffer)
                'consent-plan-mode))
    (should-not (buffer-local-value 'buffer-read-only buffer))
    (should
     (string-match-p
      "(agent-plans (scope project)"
      (consent-plan-test--buffer-string buffer)))
    (should
     (string-match-p
      "(goal \"Share a REPL plan\")"
      (consent-plan-test--buffer-string buffer)))))

;;; consent-plan-test.el ends here
