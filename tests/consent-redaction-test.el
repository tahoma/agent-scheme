;;; consent-redaction-test.el --- Secrets and redaction policy tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for first-class redaction records, local-only context,
;; boundary redaction for memory/transcripts/audit/skills, and remote-provider
;; routing denial.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-memory)
(require 'consent-policy)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-session)
(require 'consent-skill nil t)

(defun consent-redaction-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-redaction-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-redaction-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-redaction-test--all-audit-text ()
  "Return all recent audit entries as one string."
  (mapconcat #'identity (consent-redaction-test--audit-strings) "\n"))

(defun consent-redaction-test--reset ()
  "Reset shared state touched by redaction policy tests."
  (consent-redaction-clear!)
  (consent-memory-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(defun consent-redaction-test--make-secret-skill-directory ()
  "Create a temporary Agent Skill directory whose resource contains a token."
  (let* ((root (make-temp-file "consent-redaction-skill-test-" t))
         (directory (expand-file-name "secret-skill" root)))
    (make-directory directory)
    (with-temp-file (expand-file-name "SKILL.md" directory)
      (insert "---\n")
      (insert "name: secret-skill\n")
      (insert "description: Redaction test skill\n")
      (insert "---\n")
      (insert "# Secret Skill\n\n")
      (insert "Use token sk-skillsecret1234567890 for no one.\n"))
    directory))

(ert-deftest consent-redaction-test-env-like-secret-redacts-as-record ()
  "Env-like credentials produce inspectable redaction records."
  (consent-redaction-test--reset)
  (let* ((datum (consent-read
                 "((source env)
                   (field \"OPENAI_API_KEY\")
                   (value \"sk-envsecret1234567890\"))"))
         (redacted (consent-redact datum 'remote-provider))
         (external (consent-redaction-test--external redacted))
         (log (consent-redaction-test--external
               (consent-redaction-log))))
    (should (consent-secret-source-p datum))
    (should (string-match-p "(redaction (kind secret)" external))
    (should (string-match-p "(source env)" external))
    (should (string-match-p "(field \"OPENAI_API_KEY\")" external))
    (should (string-match-p "(replacement \"\\[redacted\\]\")" external))
    (should (string-match-p "(policy local-only)" external))
    (should-not (string-match-p "sk-envsecret" external))
    (should (string-match-p "(redaction-log" log))
    (should-not (string-match-p "sk-envsecret" log))))

(ert-deftest consent-redaction-test-scheme-redaction-primitives ()
  "The `(agent redaction)' library exposes policy procedures to Scheme."
  (consent-redaction-test--reset)
  (let ((external
         (consent-redaction-test--value-external
          (consent-eval-source
           "(import (scheme base) (agent redaction))
            (let ((secret '((source env)
                            (field \"OPENAI_API_KEY\")
                            (value \"sk-scheme1234567890\"))))
              (list (secret-source? secret)
                    (redact secret 'remote-provider)
                    (safe-for-provider? secret 'openai)))"))))
    (should (string-match-p "#t" external))
    (should (string-match-p "(redaction (kind secret)" external))
    (should (string-match-p "#f)" external))
    (should-not (string-match-p "sk-scheme" external))))

(ert-deftest consent-redaction-test-dotted-list-datums-remain-walkable ()
  "Redaction walks dotted Scheme datums without treating them as records."
  (let* ((datum (consent-read "(procedure first . rest-arguments)"))
         (redacted (consent-redact datum 'debugger)))
    (should (equal redacted datum))))

(ert-deftest consent-redaction-test-auth-source-and-local-only-context ()
  "Auth-source stubs redact, and local-only context is unsafe for providers."
  (consent-redaction-test--reset)
  (let* ((auth (consent-read
                "((source auth-source)
                  (host \"api.example.test\")
                  (user \"alice\")
                  (secret \"hunter2\"))"))
         (local (consent-context-local-only!
                 (consent-read
                  "((buffer \"private-notes\") (text \"do not send\"))")
                 "private buffer")))
    (should (consent-secret-source-p auth))
    (let ((external (consent-redaction-test--external
                     (consent-redact auth 'audit-export))))
      (should (string-match-p "(source auth-source)" external))
      (should-not (string-match-p "hunter2" external)))
    (should-not (consent-safe-for-provider-p local 'openai))
    (should-error
     (consent-policy-authorize-provider-routing local 'openai)
     :type 'consent-policy-error)
    (should
     (string-match-p
      "(reason \"private buffer\")"
      (consent-redaction-test--external local)))))

(ert-deftest consent-redaction-test-memory-and-audit-redact-secrets ()
  "Memory writes and audit entries never keep raw secret values."
  (consent-redaction-test--reset)
  (consent-memory-put!
   'instance
   'api-key
   (consent-read
    "((tags (credential))
      (source env)
      (field \"OPENAI_API_KEY\")
      (value \"sk-memorysecret1234567890\"))"))
  (let ((memory (consent-redaction-test--external
                 (consent-memory-ref 'instance 'api-key)))
        (audit (consent-redaction-test--all-audit-text))
        (log (consent-redaction-test--external
              (consent-redaction-log))))
    (should (string-match-p "(redaction (kind secret)" memory))
    (should-not (string-match-p "sk-memorysecret" memory))
    (should-not (string-match-p "sk-memorysecret" audit))
    (should (string-match-p "(source env)" log))
    (should-not (string-match-p "sk-memorysecret" log))))

(ert-deftest consent-redaction-test-session-transcripts-redact-secrets ()
  "Session transcripts and evaluation audit entries redact literal secrets."
  (consent-redaction-test--reset)
  (consent-session-create! 'named '(:id "redaction-session"))
  (consent-session-eval-source
   "redaction-session"
   "(define provider-token \"sk-transcriptsecret1234567890\")
    provider-token")
  (let ((session (consent-redaction-test--external
                  (consent-session-ref "redaction-session")))
        (audit (consent-redaction-test--all-audit-text)))
    (should (string-match-p "(transcript" session))
    (should (string-match-p "\\[redacted\\]" session))
    (should-not (string-match-p "sk-transcriptsecret" session))
    (should-not (string-match-p "sk-transcriptsecret" audit))))

(ert-deftest consent-redaction-test-skill-resource-disclosure-redacts ()
  "Skill resource reads and imports disclose redacted instructions."
  (should (featurep 'consent-skill))
  (consent-redaction-test--reset)
  (let ((consent-policy-category-actions
         (append '((skill-resource-read . allow))
                 (seq-remove
                  (lambda (entry) (eq (car entry) 'skill-resource-read))
                  consent-policy-category-actions)))
        (directory (consent-redaction-test--make-secret-skill-directory)))
    (unwind-protect
        (let ((resource (consent-skill-read-resource
                         directory "SKILL.md"
                         '(:skill-name "secret-skill")))
              (imported (consent-redaction-test--external
                         (consent-skill-import directory))))
          (should (string-match-p "\\[redacted\\]" resource))
          (should-not (string-match-p "sk-skillsecret" resource))
          (should (string-match-p "\\[redacted\\]" imported))
          (should-not (string-match-p "sk-skillsecret" imported)))
      (delete-directory (file-name-directory
                         (directory-file-name directory))
                        t))))

;;; consent-redaction-test.el ends here
