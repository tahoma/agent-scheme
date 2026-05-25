;;; agent-scheme-models-test.el --- Model provider routing tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the user-facing `(agent models)' vertical slice:
;; provider registration, role routing, local OpenAI-compatible completion,
;; fallback, privacy denial, and redacted diagnostics.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-models)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)

(defvar agent-scheme-models-test--requests nil
  "Requests received by the fake model transport.")

(defun agent-scheme-models-test--transport
    (provider model request _context)
  "Return a fake completion for PROVIDER, MODEL, and REQUEST."
  (push (list provider model request) agent-scheme-models-test--requests)
  "mock completion")

(defun agent-scheme-models-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source)))

(defun agent-scheme-models-test--audit-text ()
  "Return recent audit entries as one stable external string."
  (mapconcat #'agent-scheme-result->external
             (agent-scheme-audit-recent-entries)
             "\n"))

(defun agent-scheme-models-test--reset ()
  "Reset shared state touched by model routing tests."
  (agent-scheme-models-clear!)
  (agent-scheme-audit-clear)
  (setq agent-scheme-models-test--requests nil))

(ert-deftest agent-scheme-models-test-local-complete-through-transport ()
  "Expose `(agent models)' and complete through a selected local provider."
  (agent-scheme-models-test--reset)
  (let ((agent-scheme-models-transport-function
         #'agent-scheme-models-test--transport))
    (should
     (equal
      (agent-scheme-models-test--external
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
    (should (= (length agent-scheme-models-test--requests) 1))
    (let* ((request (car agent-scheme-models-test--requests))
           (provider (car request))
           (model (cadr request))
           (payload (caddr request)))
      (should (equal (plist-get provider :id) "local-llama"))
      (should (equal (plist-get model :id) "qwen-coder"))
      (should (equal (plist-get payload :prompt)
                     "Write a Scheme helper.")))))

(ert-deftest agent-scheme-models-test-routing-falls-back-past-unavailable ()
  "Skip unavailable models and select the next role-compatible local model."
  (agent-scheme-models-test--reset)
  (should
   (equal
    (agent-scheme-models-test--external
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

(ert-deftest agent-scheme-models-test-remote-local-only-denied-before-transport ()
  "Deny local-only context before a remote provider can run transport."
  (agent-scheme-models-test--reset)
  (let ((agent-scheme-models-transport-function
         #'agent-scheme-models-test--transport))
    (should-error
     (agent-scheme-eval-source
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
     :type 'agent-scheme-policy-error)
    (should-not agent-scheme-models-test--requests)
    (should
     (string-match-p
      "local-only context requires explicit approval"
      (agent-scheme-models-test--audit-text)))))

(ert-deftest agent-scheme-models-test-diagnostics-redact-credentials ()
  "Diagnostics show configured providers without exposing raw credentials."
  (agent-scheme-models-test--reset)
  (let ((external
         (agent-scheme-models-test--external
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

;;; agent-scheme-models-test.el ends here
