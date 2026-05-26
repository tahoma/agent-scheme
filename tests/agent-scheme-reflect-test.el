;;; agent-scheme-reflect-test.el --- Runtime reflection tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the `(agent reflect)' library: capability metadata,
;; budgets, imports, recent event/error inspection, and redaction at the
;; reflection boundary.

;;; Code:

(require 'ert)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)
(require 'agent-scheme-reflect)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-reflect-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-reflect-test--eval-value-string (source &optional options)
  "Evaluate SOURCE and return its external value string."
  (agent-scheme-reflect-test--value-external
   (agent-scheme-eval-source source nil options)))

(defun agent-scheme-reflect-test--reset ()
  "Reset shared state touched by reflection tests."
  (agent-scheme-redaction-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(ert-deftest agent-scheme-reflect-test-runtime-version-is-canonical-triple ()
  "Expose the Agent Scheme runtime version through `(agent reflect)'."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (let ((version (agent-scheme-version)))
        (list version
              (map exact-integer? (cdr version))
              (map (lambda (component) (>= component 0))
                   (cdr version))))")
    "((agent-scheme-version 0 14 5) (#t #t #t) (#t #t #t))")))

(ert-deftest agent-scheme-reflect-test-capability-budget-and-imports ()
  "Inspect capability metadata, active budget limits, imports, and session ids."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (list (capability-info 'buffer-text)
                 (current-budget)
                 (current-imports)
                 (current-session-info))"
          '(:max-steps 1234
            :max-host-callbacks 77
            :max-events 9
            :max-event-nodes 88
            :session-id "reflect-run"))))
    (should (string-match-p "(host-capability" external))
    (should (string-match-p (regexp-quote "(library (emacs buffer))") external))
    (should (string-match-p (regexp-quote "(name buffer-text)") external))
    (should (string-match-p (regexp-quote "(policy-category emacs-read-only)") external))
    (should (string-match-p (regexp-quote "(max-steps 1234)") external))
    (should (string-match-p (regexp-quote "(max-host-calls 77)") external))
    (should (string-match-p (regexp-quote "(max-events 9)") external))
    (should (string-match-p (regexp-quote "(max-event-nodes 88)") external))
    (should (string-match-p (regexp-quote "(agent reflect)") external))
    (should (string-match-p (regexp-quote "(id reflect-run)") external))))

(ert-deftest agent-scheme-reflect-test-current-capabilities-lists-host-capabilities ()
  "List importable host capabilities as Scheme-readable metadata records."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (current-capabilities)")))
    (should (string-match-p "(host-capability" external))
    (should (string-match-p (regexp-quote "(name emacs-current-buffer)") external))
    (should (string-match-p (regexp-quote "(name file-exists?)") external))
    (should-not (string-match-p "agent-scheme--primitive" external))
    (should-not (string-match-p "emacs-hook" external))))

(ert-deftest agent-scheme-reflect-test-time-capability-uses-clock-grant-policy ()
  "Reflect `(scheme time)` as a functional clock capability."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (capability-info 'current-second)")))
    (should (string-match-p (regexp-quote "(library (scheme time))") external))
    (should (string-match-p (regexp-quote "(name current-second)") external))
    (should (string-match-p (regexp-quote "(effect host-time)") external))
    (should (string-match-p (regexp-quote "(required-capability clock)") external))
    (should (string-match-p
             (regexp-quote "(backend-effect-path shared-capability-request)")
             external))
    (should (string-match-p (regexp-quote "(policy grant)") external))))

(ert-deftest agent-scheme-reflect-test-recent-yields-redact-secret-values ()
  "Reflect recent yield events without exposing raw credential-like data."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent io) (agent reflect))
           (agent-yield '((source env)
                          (field \"OPENAI_API_KEY\")
                          (value \"sk-reflectsecret1234567890\")))
           (agent-yield '(visible ok))
           (recent-yields)")))
    (should (string-match-p "(yield (visible ok))" external))
    (should (string-match-p "(redaction (kind secret)" external))
    (should-not (string-match-p "sk-reflectsecret" external))))

(ert-deftest agent-scheme-reflect-test-recent-errors-and-policy-decisions ()
  "Reflect recent error and policy audit entries as redacted datums."
  (agent-scheme-reflect-test--reset)
  (agent-scheme-session-create! 'named '(:id "reflect-errors"))
  (should-error
   (agent-scheme-session-eval-source
    "reflect-errors"
    "(error \"sk-errorsecret1234567890\")")
   :type 'agent-scheme-eval-error)
  (agent-scheme-policy-authorize
   'pure-r7rs "reflect-policy" '((detail . "ok")) nil)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (list (recent-errors) (recent-policy-decisions))")))
    (should (string-match-p (regexp-quote "(event session-evaluation)") external))
    (should (string-match-p (regexp-quote "(event policy-decision)") external))
    (should (string-match-p (regexp-quote "(operation \"reflect-policy\")") external))
    (should-not (string-match-p "sk-errorsecret" external))))

;;; agent-scheme-reflect-test.el ends here
