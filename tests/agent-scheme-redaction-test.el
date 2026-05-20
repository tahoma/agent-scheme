;;; agent-scheme-redaction-test.el --- Secrets and redaction policy tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for first-class redaction records, local-only context,
;; boundary redaction for memory/transcripts/audit/skills, and remote-provider
;; routing denial.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-memory)
(require 'agent-scheme-policy)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-session)
(require 'agent-scheme-skill nil t)

(defun agent-scheme-redaction-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-redaction-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-redaction-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-redaction-test--all-audit-text ()
  "Return all recent audit entries as one string."
  (mapconcat #'identity (agent-scheme-redaction-test--audit-strings) "\n"))

(defun agent-scheme-redaction-test--reset ()
  "Reset shared state touched by redaction policy tests."
  (agent-scheme-redaction-clear!)
  (agent-scheme-memory-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(defun agent-scheme-redaction-test--make-secret-skill-directory ()
  "Create a temporary Agent Skill directory whose resource contains a token."
  (let* ((root (make-temp-file "agent-scheme-redaction-skill-test-" t))
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

(ert-deftest agent-scheme-redaction-test-env-like-secret-redacts-as-record ()
  "Env-like credentials produce inspectable redaction records."
  (agent-scheme-redaction-test--reset)
  (let* ((datum (agent-scheme-read
                 "((source env)
                   (field \"OPENAI_API_KEY\")
                   (value \"sk-envsecret1234567890\"))"))
         (redacted (agent-scheme-redact datum 'remote-provider))
         (external (agent-scheme-redaction-test--external redacted))
         (log (agent-scheme-redaction-test--external
               (agent-scheme-redaction-log))))
    (should (agent-scheme-secret-source-p datum))
    (should (string-match-p "(redaction (kind secret)" external))
    (should (string-match-p "(source env)" external))
    (should (string-match-p "(field \"OPENAI_API_KEY\")" external))
    (should (string-match-p "(replacement \"\\[redacted\\]\")" external))
    (should (string-match-p "(policy local-only)" external))
    (should-not (string-match-p "sk-envsecret" external))
    (should (string-match-p "(redaction-log" log))
    (should-not (string-match-p "sk-envsecret" log))))

(ert-deftest agent-scheme-redaction-test-scheme-redaction-primitives ()
  "The `(agent redaction)' library exposes policy procedures to Scheme."
  (agent-scheme-redaction-test--reset)
  (let ((external
         (agent-scheme-redaction-test--value-external
          (agent-scheme-eval-source
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

(ert-deftest agent-scheme-redaction-test-auth-source-and-local-only-context ()
  "Auth-source stubs redact, and local-only context is unsafe for providers."
  (agent-scheme-redaction-test--reset)
  (let* ((auth (agent-scheme-read
                "((source auth-source)
                  (host \"api.example.test\")
                  (user \"alice\")
                  (secret \"hunter2\"))"))
         (local (agent-scheme-context-local-only!
                 (agent-scheme-read
                  "((buffer \"private-notes\") (text \"do not send\"))")
                 "private buffer")))
    (should (agent-scheme-secret-source-p auth))
    (let ((external (agent-scheme-redaction-test--external
                     (agent-scheme-redact auth 'audit-export))))
      (should (string-match-p "(source auth-source)" external))
      (should-not (string-match-p "hunter2" external)))
    (should-not (agent-scheme-safe-for-provider-p local 'openai))
    (should-error
     (agent-scheme-policy-authorize-provider-routing local 'openai)
     :type 'agent-scheme-policy-error)
    (should
     (string-match-p
      "(reason \"private buffer\")"
      (agent-scheme-redaction-test--external local)))))

(ert-deftest agent-scheme-redaction-test-memory-and-audit-redact-secrets ()
  "Memory writes and audit entries never keep raw secret values."
  (agent-scheme-redaction-test--reset)
  (agent-scheme-memory-put!
   'instance
   'api-key
   (agent-scheme-read
    "((tags (credential))
      (source env)
      (field \"OPENAI_API_KEY\")
      (value \"sk-memorysecret1234567890\"))"))
  (let ((memory (agent-scheme-redaction-test--external
                 (agent-scheme-memory-ref 'instance 'api-key)))
        (audit (agent-scheme-redaction-test--all-audit-text))
        (log (agent-scheme-redaction-test--external
              (agent-scheme-redaction-log))))
    (should (string-match-p "(redaction (kind secret)" memory))
    (should-not (string-match-p "sk-memorysecret" memory))
    (should-not (string-match-p "sk-memorysecret" audit))
    (should (string-match-p "(source env)" log))
    (should-not (string-match-p "sk-memorysecret" log))))

(ert-deftest agent-scheme-redaction-test-session-transcripts-redact-secrets ()
  "Session transcripts and evaluation audit entries redact literal secrets."
  (agent-scheme-redaction-test--reset)
  (agent-scheme-session-create! 'named '(:id "redaction-session"))
  (agent-scheme-session-eval-source
   "redaction-session"
   "(define provider-token \"sk-transcriptsecret1234567890\")
    provider-token")
  (let ((session (agent-scheme-redaction-test--external
                  (agent-scheme-session-ref "redaction-session")))
        (audit (agent-scheme-redaction-test--all-audit-text)))
    (should (string-match-p "(transcript" session))
    (should (string-match-p "\\[redacted\\]" session))
    (should-not (string-match-p "sk-transcriptsecret" session))
    (should-not (string-match-p "sk-transcriptsecret" audit))))

(ert-deftest agent-scheme-redaction-test-skill-resource-disclosure-redacts ()
  "Skill resource reads and imports disclose redacted instructions."
  (should (featurep 'agent-scheme-skill))
  (agent-scheme-redaction-test--reset)
  (let ((agent-scheme-policy-category-actions
         (append '((skill-resource-read . allow))
                 (seq-remove
                  (lambda (entry) (eq (car entry) 'skill-resource-read))
                  agent-scheme-policy-category-actions)))
        (directory (agent-scheme-redaction-test--make-secret-skill-directory)))
    (unwind-protect
        (let ((resource (agent-scheme-skill-read-resource
                         directory "SKILL.md"
                         '(:skill-name "secret-skill")))
              (imported (agent-scheme-redaction-test--external
                         (agent-scheme-skill-import directory))))
          (should (string-match-p "\\[redacted\\]" resource))
          (should-not (string-match-p "sk-skillsecret" resource))
          (should (string-match-p "\\[redacted\\]" imported))
          (should-not (string-match-p "sk-skillsecret" imported)))
      (delete-directory (file-name-directory
                         (directory-file-name directory))
                        t))))

;;; agent-scheme-redaction-test.el ends here
