;;; consent-models-test.el --- Model provider routing tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the user-facing `(agent models)' vertical slice:
;; provider registration, role routing, local OpenAI-compatible completion,
;; fallback, privacy denial, and redacted diagnostics.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-models)
(require 'consent-policy)
(require 'consent-result)

(defvar consent-models-test--requests nil
  "Requests received by the fake model transport.")

(defun consent-models-test--transport
    (provider model request _context)
  "Return a fake completion for PROVIDER, MODEL, and REQUEST."
  (push (list provider model request) consent-models-test--requests)
  "mock completion")

(defun consent-models-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(defun consent-models-test--audit-text ()
  "Return recent audit entries as one stable external string."
  (mapconcat #'consent-result->external
             (consent-audit-recent-entries)
             "\n"))

(defun consent-models-test--reset ()
  "Reset shared state touched by model routing tests."
  (consent-models-clear!)
  (consent-audit-clear)
  (setq consent-models-test--requests nil))

(defun consent-models-test--live-enabled-p ()
  "Return non-nil when live local model tests are explicitly enabled."
  (let ((enabled (getenv "CONSENT_LIVE_MODEL_TEST")))
    (and enabled (> (length enabled) 0))))

(defun consent-models-test--live-endpoint ()
  "Return the live local OpenAI-compatible endpoint for integration tests."
  (or (getenv "CONSENT_LIVE_MODEL_ENDPOINT")
      "http://127.0.0.1:11434/v1"))

(defun consent-models-test--live-model ()
  "Return the live local model id for integration tests."
  (or (getenv "CONSENT_LIVE_MODEL_ID")
      "qwen2.5-coder:0.5b"))

(defun consent-models-test--live-matrix-enabled-p ()
  "Return non-nil when the full live local model matrix is enabled."
  (let ((enabled (getenv "CONSENT_LIVE_MODEL_MATRIX")))
    (and enabled (> (length enabled) 0))))

(defconst consent-models-test--live-suggested-models
  '((cheap-background . "qwen2.5-coder:0.5b")
    (cheap-background . "qwen3:0.6b")
    (cheap-background . "gemma3:1b")
    (scheme-scripter . "qwen2.5-coder:7b")
    (coder . "qwen2.5-coder:14b")
    (reviewer . "qwen2.5-coder:32b")
    (memory-curator . "qwen3:4b")
    (approval-explainer . "qwen3:8b")
    (planner . "qwen3:30b")
    (planner . "qwen3:32b")
    (reviewer . "llama3.1:70b")
    (summarizer . "gemma3:4b")
    (approval-explainer . "gemma3:12b"))
  "Representative live local model cases for the documented role matrix.")

(defun consent-models-test--live-completion-external (role model)
  "Return live completion output for ROLE and MODEL as external text."
  (let ((role-name (symbol-name role)))
    (consent-models-test--external
     (format
      "(import (scheme base) (agent models))
       (model-provider-register!
        '(model-provider
          (id local-live)
          (kind local)
          (transport openai-compatible-http)
          (endpoint %S)
          (models
           (((id %S)
             (roles (%s))
             (privacy local))))))
       (model-complete '%s
                       \"What is 2 plus 3? Reply with only the numeral.\"
                       '())"
      (consent-models-test--live-endpoint)
      model
      role-name
      role-name))))

(defun consent-models-test--live-completion-present-p (external)
  "Return non-nil when EXTERNAL renders a non-empty completion string."
  (and (stringp external)
       (> (length external) 2)
       (not (string-match-p "\\`\"[[:space:]]*\"\\'" external))))

(ert-deftest consent-models-test-local-complete-through-transport ()
  "Expose `(agent models)' and complete through a selected local provider."
  (consent-models-test--reset)
  (let ((consent-models-transport-function
         #'consent-models-test--transport))
    (should
     (equal
      (consent-models-test--external
       "(import (scheme base) (agent models))
        (model-provider-register!
         '(model-provider
           (id local-llama)
           (kind local)
           (transport openai-compatible-http)
           (endpoint \"http://127.0.0.1:11434/v1\")
           (models
            (((id qwen-coder)
              (roles (scheme-scripter code))
              (privacy local))))))
        (list (model-complete 'scheme-scripter
                              \"Write a Scheme helper.\"
                              '((temperature 0)))
              (model-route 'scheme-scripter '()))")
      "(\"mock completion\" (model-routing-decision (status selected) (role scheme-scripter) (provider local-llama) (model qwen-coder) (kind local) (transport openai-compatible-http) (endpoint \"http://127.0.0.1:11434/v1\")))"))
    (should (= (length consent-models-test--requests) 1))
    (let* ((request (car consent-models-test--requests))
           (provider (car request))
           (model (cadr request))
           (payload (caddr request)))
      (should (equal (plist-get provider :id) "local-llama"))
      (should (equal (plist-get model :id) "qwen-coder"))
      (should (equal (plist-get payload :prompt)
                     "Write a Scheme helper.")))))

(ert-deftest consent-models-test-live-local-openai-compatible-completion ()
  "Opt-in live proof that `model-complete' reaches a local model endpoint."
  (skip-unless (consent-models-test--live-enabled-p))
  (consent-models-test--reset)
  (let* ((endpoint (consent-models-test--live-endpoint))
         (model (consent-models-test--live-model))
         (external
          (consent-models-test--external
           (format
            "(import (scheme base) (agent models))
             (model-provider-register!
              '(model-provider
                (id local-live)
                (kind local)
                (transport openai-compatible-http)
                (endpoint %S)
                (models
                 (((id %S)
                   (roles (scheme-scripter code))
                   (privacy local))))))
             (model-complete 'scheme-scripter
                             \"What is 2 plus 3? Reply with only the numeral.\"
                             '())"
            endpoint
            model))))
    (should (string-match-p "5" external))))

(ert-deftest consent-models-test-live-local-suggested-model-matrix ()
  "Opt-in live proof across the documented local role/model matrix."
  (skip-unless (and (consent-models-test--live-enabled-p)
                    (consent-models-test--live-matrix-enabled-p)))
  (let (failures)
    (dolist (case consent-models-test--live-suggested-models)
      (let ((role (car case))
            (model (cdr case)))
        (consent-models-test--reset)
        (condition-case error
            (let ((external
                   (consent-models-test--live-completion-external
                    role
                    model)))
              (unless (consent-models-test--live-completion-present-p
                       external)
                (push (format "%s/%s returned %s" role model external)
                      failures)))
          (error
           (push (format "%s/%s failed: %S" role model error)
                 failures)))))
    (when failures
      (ert-fail (mapconcat #'identity (nreverse failures) "\n")))))

(ert-deftest consent-models-test-routing-falls-back-past-unavailable ()
  "Skip unavailable models and select the next role-compatible local model."
  (consent-models-test--reset)
  (should
   (equal
    (consent-models-test--external
     "(import (scheme base) (agent models))
      (model-provider-register!
       '(model-provider
         (id local-stack)
         (kind local)
         (transport openai-compatible-http)
         (endpoint \"http://127.0.0.1:11434/v1\")
         (models
          (((id cold-model)
            (roles (scheme-scripter))
            (status unavailable))
           ((id warm-model)
            (roles (scheme-scripter))
            (privacy local))))))
      (model-route 'scheme-scripter '())")
    "(model-routing-decision (status selected) (role scheme-scripter) (provider local-stack) (model warm-model) (kind local) (transport openai-compatible-http) (endpoint \"http://127.0.0.1:11434/v1\"))")))

(ert-deftest consent-models-test-remote-local-only-denied-before-transport ()
  "Deny local-only context before a remote provider can run transport."
  (consent-models-test--reset)
  (let ((consent-models-transport-function
         #'consent-models-test--transport))
    (should-error
     (consent-eval-source
      "(import (scheme base) (agent models) (agent redaction))
       (model-provider-register!
        '(model-provider
          (id remote-openai)
          (kind remote)
          (transport openai-compatible-http)
          (endpoint \"https://api.openai.example/v1\")
          (models
           (((id gpt-example)
             (roles (scheme-scripter))
             (privacy public))))))
       (model-complete 'scheme-scripter
                       (context-local-only! \"private buffer text\"
                                            \"private buffer\")
                       '())")
     :type 'consent-policy-error)
    (should-not consent-models-test--requests)
    (should
     (string-match-p
      "local-only context requires explicit approval"
      (consent-models-test--audit-text)))))

(ert-deftest consent-models-test-diagnostics-redact-credentials ()
  "Diagnostics show configured providers without exposing raw credentials."
  (consent-models-test--reset)
  (let ((external
         (consent-models-test--external
          "(import (scheme base) (agent models))
           (model-provider-register!
            '(model-provider
              (id local-secret)
              (kind local)
              (transport openai-compatible-http)
              (endpoint \"http://127.0.0.1:11434/v1\")
              (credentials
               ((source env)
                (field \"OPENAI_API_KEY\")
                (value \"sk-modelsecret1234567890\")))
              (models
               (((id qwen-coder)
                 (roles (scheme-scripter))
                 (privacy local))))))
           (model-provider-diagnostics)")))
    (should (string-match-p "(model-provider-diagnostics" external))
    (should (string-match-p "(provider local-secret)" external))
    (should-not (string-match-p "sk-modelsecret" external))))

;;; consent-models-test.el ends here
