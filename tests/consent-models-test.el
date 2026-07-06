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
(require 'consent-scheme-host)

(defvar consent-models-test--requests nil
  "Requests received by the fake model transport.")

(defun consent-models-test--transport
    (provider model request _context)
  "Return a fake completion for PROVIDER, MODEL, and REQUEST."
  (push (list provider model request) consent-models-test--requests)
  "mock completion")

(defun consent-models-test--tool-call-transport
    (provider model request _context)
  "Return a fake tool-calling completion for PROVIDER, MODEL, and REQUEST."
  (push (list provider model request) consent-models-test--requests)
  (consent-read
   "(model-message
      (text \"Need the local echo tool.\")
      (tool-calls
       ((tool-call
         (id \"call-1\")
         (name local-echo)
         (arguments ((text \"hello\")))))))"))

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

(defun consent-models-test--register-local-provider (&optional endpoint)
  "Register one local provider rooted at ENDPOINT."
  (consent-models-register-provider!
   (consent-read
    (format
     "(model-provider
       (id local-errors)
       (kind local)
       (transport openai-compatible-http)
       (endpoint %S)
       (models
        (((id qwen-coder)
          (roles (scheme-scripter))
          (privacy local)))))"
     (or endpoint "http://127.0.0.1:11434/v1")))))

(defun consent-models-test--complete-local-model (prompt &optional options)
  "Complete PROMPT through the registered local test model."
  (consent-models-complete 'scheme-scripter
                           prompt
                           (or options '())))

(defun consent-models-test--error-message (error)
  "Return the stable message carried by transport ERROR."
  (if (and (consp error)
           (stringp (cadr error)))
      (cadr error)
    (error-message-string error)))

(defun consent-models-test--error-datum (error)
  "Return the structured provider datum carried by ERROR, or nil."
  (cond
   ((and (consp error) (nth 2 error))
    (nth 2 error))
   ((and (consp error)
         (nth 1 error)
         (not (stringp (nth 1 error))))
    (nth 1 error))
   (t nil)))

(defun consent-models-test--error-external (error)
  "Return ERROR's structured datum as a stable external string."
  (consent-result->external
   (consent-models-test--error-datum error)))

(defun consent-models-test--http-buffer
    (status reason body &optional headers)
  "Return a fake HTTP response buffer with STATUS, REASON, BODY, and HEADERS."
  (let ((buffer (generate-new-buffer " *consent-model-http*")))
    (with-current-buffer buffer
      (insert (format "HTTP/1.1 %d %s\r\n" status reason))
      (dolist (header headers)
        (insert (format "%s: %s\r\n" (car header) (cdr header))))
      (insert "\r\n")
      (insert body))
    buffer))

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
      "qwen3:0.6b"))

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

(defun consent-models-test--live-tool-call-external ()
  "Return a live forced tool-call output as external text."
  (consent-models-test--external
   (format
    "(import (scheme base) (agent models))
     (define (local-echo text)
       \"Echo TEXT through a pure local helper.\"
       #((parameters
          (text (type string)
           (description \"Text to echo.\")))
         (returns (type string)
          (description \"The echoed text.\"))
         (effects pure))
       text)
     (model-provider-register!
      '(model-provider
        (id local-live-tools)
        (kind local)
        (transport openai-compatible-http)
        (endpoint %S)
        (models
         (((id %S)
           (roles (scheme-scripter code))
           (privacy local))))))
     (let ((tool (model-tool-spec 'local-echo)))
       (model-complete
        'scheme-scripter
        \"Call the local-echo tool with text exactly portable-ci-tool-call.\"
        (list (list 'tools (list tool))
              (list 'tool-choice tool))))"
    (consent-models-test--live-endpoint)
    (consent-models-test--live-model))))

(defconst consent-models-test--live-portable-test-files
  '("tests/scheme/consent-models-live-test.scm")
  "Portable live model files run by the model-specific ERT bridge tests.")

(defun consent-models-test--run-live-portable-host (host display-name)
  "Run live model portable tests on HOST named DISPLAY-NAME."
  (let ((consent--scheme-host-test-files
         consent-models-test--live-portable-test-files))
    (consent--scheme-host-run-suite host display-name)))

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

(ert-deftest consent-models-test-tool-spec-derived-and-routed ()
  "Derive tool specs from metadata and route canonical tool calls."
  (consent-models-test--reset)
  (let ((consent-models-transport-function
         #'consent-models-test--tool-call-transport))
    (should
     (equal
      (consent-models-test--external
       "(import (scheme base) (agent models))
        (define (field datum name)
          (let loop ((fields (cdr datum)))
            (cond
             ((null? fields) #f)
             ((eq? (car (car fields)) name) (cadr (car fields)))
             (else (loop (cdr fields))))))
        (define (local-echo text)
          \"Echo TEXT through a pure local helper.\"
          #((parameters
             (text (type string)
              (description \"Text to echo.\")))
            (returns (type string)
             (description \"The echoed text.\"))
            (effects pure))
          text)
        (model-provider-register!
         '(model-provider
           (id local-tools)
           (kind local)
           (transport openai-compatible-http)
           (endpoint \"http://127.0.0.1:11434/v1\")
           (models
            (((id qwen-coder)
              (roles (scheme-scripter code))
              (privacy local))))))
        (let* ((tool (model-tool-spec 'local-echo))
               (response
                (model-complete 'scheme-scripter
                                \"Call local-echo with hello.\"
                                (list (list 'tools (list tool))
                                      (list 'tool-choice 'auto)))))
          (list (field tool 'name)
                (field tool 'parameters)
                (field tool 'returns)
                (field tool 'effects)
                (field tool 'schema)
                (field tool 'example)
                (field tool 'gate)
                response))")
      (concat
       "(local-echo "
       "((text (type string) (description \"Text to echo.\"))) "
       "((type string) (description \"The echoed text.\")) "
       "(pure) "
       "(openai-tool (type function) "
       "(function (name \"local-echo\") "
       "(description \"Echo TEXT through a pure local helper.\") "
       "(parameters ((type \"object\") "
       "(properties ((text ((type \"string\") "
       "(description \"Text to echo.\"))))) "
       "(required (\"text\")))))) "
       "(tool-call (name local-echo) "
       "(arguments ((text \"<string>\")))) "
       "(tool-gate (decision pure-under-budget) (effects (pure))) "
       "(model-message (text \"Need the local echo tool.\") "
       "(tool-calls ((tool-call (id \"call-1\") "
       "(name local-echo) (arguments ((text \"hello\"))))))))")))
    (should (= (length consent-models-test--requests) 1))
    (let* ((payload (caddr (car consent-models-test--requests)))
           (tools (plist-get payload :tools))
           (tool-choice (plist-get payload :tool-choice)))
      (should (equal (consent-result->external tool-choice) "auto"))
      (should
       (string-match-p
        "(model-tool (name local-echo)"
        (consent-result->external tools))))))

(ert-deftest consent-models-test-tool-spec-any-schema-default ()
  "Keep `any' parameter schemas JSON-object shaped when prose is absent."
  (consent-models-test--reset)
  (should
   (equal
    (consent-models-test--external
     "(import (scheme base) (agent models))
      (define (field datum name)
        (let loop ((fields (cdr datum)))
          (cond
           ((null? fields) #f)
           ((eq? (car (car fields)) name) (cadr (car fields)))
           (else (loop (cdr fields))))))
      (define (local-inspect value)
        \"Inspect VALUE locally.\"
        #((parameters (value (type any)))
          (returns (type any))
          (effects pure))
        value)
      (field (model-tool-spec 'local-inspect) 'schema)")
    (concat
     "(openai-tool (type function) "
     "(function (name \"local-inspect\") "
     "(description \"Inspect VALUE locally.\") "
     "(parameters ((type \"object\") "
     "(properties ((value ((description "
     "\"Any Scheme-readable value.\"))))) "
     "(required (\"value\"))))))"))))

(ert-deftest consent-models-test-openai-response-tool-calls ()
  "Decode OpenAI-compatible tool_calls into canonical model-message datums."
  (should
   (equal
    (consent-result->external
     (consent-models--parse-openai-response
      "{\"choices\":[{\"message\":{\"content\":\"Use a tool.\",\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"local-echo\",\"arguments\":\"{\\\"text\\\":\\\"hello\\\"}\"}}]}}]}"))
    (concat
     "(model-message (text \"Use a tool.\") "
     "(tool-calls ((tool-call (id \"call-1\") "
     "(name local-echo) (arguments ((text \"hello\")))))))"))))

(ert-deftest consent-models-test-openai-request-includes-tools ()
  "Lower canonical model-tool datums into OpenAI tools and tool_choice."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (tool
          (consent-read
           "(model-tool
              (name local-echo)
              (schema
               (openai-tool
                (type function)
                (function
                 (name \"local-echo\")
                 (description \"Echo text.\")
                 (parameters
                  ((type \"object\")
                   (properties
                    ((text ((type \"string\")
                            (description \"Text to echo.\")))))
                   (required (\"text\"))))))))"))
         (payload
          (json-read-from-string
           (consent-models--openai-request-data
            '(:id "qwen-coder")
            (list :prompt "Call local-echo."
                  :tools (list tool)
                  :tool-choice (consent--syntax-symbol "auto"))))))
    (should (equal (alist-get 'tool_choice payload) "auto"))
    (should (= (length (alist-get 'tools payload)) 1))
    (let* ((tool-json (car (alist-get 'tools payload)))
           (function (alist-get 'function tool-json))
           (parameters (alist-get 'parameters function))
           (properties (alist-get 'properties parameters))
           (text (alist-get 'text properties)))
      (should (equal (alist-get 'type tool-json) "function"))
      (should (equal (alist-get 'name function) "local-echo"))
      (should (equal (alist-get 'type parameters) "object"))
      (should (equal (alist-get 'type text) "string"))
      (should (equal (alist-get 'required parameters) '("text"))))))

(ert-deftest consent-models-test-local-retry-uses-request-timeout ()
  "Retry local transport errors within the configured request timeout."
  (let ((calls 0)
        (seen-timeouts nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (_url _silent _inhibit-cookies timeout)
                 (push timeout seen-timeouts)
                 (setq calls (1+ calls))
                 (when (= calls 2)
                   (generate-new-buffer " *model-response*")))))
      (let ((buffer
             (consent-models--retrieve-synchronously
              "http://127.0.0.1:11434/v1/chat/completions"
              '(:timeout-seconds 7 :retry-count 1))))
        (unwind-protect
            (progn
              (should (buffer-live-p buffer))
              (should (= calls 2))
              (should (equal seen-timeouts '(7 7))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest consent-models-test-transport-error-maps-to-provider-error ()
  "Map local transport failures to structured model-provider-error data."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let ((consent-models-transport-function
         (lambda (_provider _model _request _context)
           (signal 'consent-models-error
                   (list "connection refused")))))
    (let ((error
           (should-error
            (consent-models-test--complete-local-model
             "Write a helper.")
            :type 'consent-models-error)))
      (should
       (string-match-p
        "connection refused"
        (consent-models-test--error-message error)))
      (should
       (string-match-p
        "(model-provider-error"
        (consent-models-test--error-external error)))
      (should
       (string-match-p
        "(status unavailable)"
        (consent-models-test--error-external error))))))

(ert-deftest consent-models-test-transport-error-preserves-structured-detail ()
  "Preserve a transport's structured provider diagnostic instead of collapsing it."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let* ((detail
          (consent-read
           "(model-provider-error
              (status unavailable)
              (provider local-errors)
              (model qwen-coder)
              (transport openai-compatible-http)
              (phase http)
              (request
               (model-provider-request
                (prompt
                 (redaction
                  (kind prompt)
                  (source provider-request)
                  (replacement \"[local-only]\")
                  (policy local-only)))))
              (http
               (http-failure
                (status 503)
                (body-excerpt \"model still loading\")))
              (reason \"HTTP 503 Service Unavailable: model still loading\"))"))
         (consent-models-transport-function
          (lambda (_provider _model _request _context)
            (signal 'consent-models-error
                    (list
                     "HTTP 503 Service Unavailable: model still loading"
                     detail)))))
    (let* ((error
            (should-error
             (consent-models-test--complete-local-model
              "prompt text must not leak")
             :type 'consent-models-error))
           (external (consent-models-test--error-external error)))
      (should
       (string-match-p
        "HTTP 503 Service Unavailable"
        (consent-models-test--error-message error)))
      (should
       (string-match-p
        "(http (http-failure (status 503)"
        external))
      (should
       (string-match-p
        "(redaction (kind prompt)"
        external))
      (should-not
       (string-match-p
        "prompt text must not leak"
        external)))))

(ert-deftest consent-models-test-openai-http-error-keeps-status-and-body-excerpt ()
  "HTTP failures keep status, bounded body detail, and safe request metadata."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let ((consent-models-transport-function
         #'consent-models-openai-compatible-http))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (_url _silent _inhibit-cookies _timeout)
                 (consent-models-test--http-buffer
                  503
                  "Service Unavailable"
                  "{\"error\":{\"message\":\"model still loading\"}}"
                  '(("Content-Type" . "application/json"))))))
      (let* ((error
              (should-error
               (consent-models-test--complete-local-model
                "transport prompt must stay hidden"
                (consent-read "((timeout-seconds 7) (retry-count 0))"))
               :type 'consent-models-error))
             (external (consent-models-test--error-external error)))
        (should
         (string-match-p
          "HTTP 503 Service Unavailable"
          (consent-models-test--error-message error)))
        (should
         (string-match-p
          "(endpoint-origin \"http://127.0.0.1:11434\")"
          external))
        (should
         (string-match-p
          "(request-path \"/v1/chat/completions\")"
          external))
        (should
         (string-match-p
          "(timeout-seconds 7)"
          external))
        (should
         (string-match-p
          "model still loading"
          external))
        (should-not
         (string-match-p
          "transport prompt must stay hidden"
          external))))))

(ert-deftest consent-models-test-openai-decode-failure-keeps-body-excerpt ()
  "Malformed provider bodies surface decode detail without leaking prompts."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let ((consent-models-transport-function
         #'consent-models-openai-compatible-http))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (_url _silent _inhibit-cookies _timeout)
                 (consent-models-test--http-buffer
                  200
                  "OK"
                  "{\"choices\":[{\"message\":{\"content\":42}}]}"
                  '(("Content-Type" . "application/json"))))))
      (let* ((error
              (should-error
               (consent-models-test--complete-local-model
                "decode prompt must stay hidden")
               :type 'consent-models-error))
             (external (consent-models-test--error-external error)))
        (should
         (string-match-p
          "decode"
          (consent-models-test--error-message error)))
        (should
         (string-match-p
          "(phase decode)"
          external))
        (should
         (string-match-p
          "(body-excerpt"
          external))
        (should-not
         (string-match-p
          "decode prompt must stay hidden"
          external))))))

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

(ert-deftest consent-models-test-live-local-openai-compatible-tool-call ()
  "Opt-in live proof that the Emacs host receives model tool calls."
  (skip-unless (consent-models-test--live-enabled-p))
  (consent-models-test--reset)
  (let ((external (consent-models-test--live-tool-call-external)))
    (should (string-match-p "(model-message" external))
    (should (string-match-p "(tool-calls" external))
    (should (string-match-p "(name local-echo)" external))
    (should (string-match-p "(arguments ((text \"" external))))

(ert-deftest consent-models-test-live-portable-racket-local-openai-compatible-tool-call ()
  "Opt-in live proof that the portable Racket host receives model tool calls."
  (skip-unless (consent-models-test--live-enabled-p))
  (consent-models-test--run-live-portable-host
   'racket
   "Racket live model tool-call"))

(ert-deftest consent-models-test-live-portable-compiled-local-openai-compatible-tool-call ()
  "Opt-in live proof that the compiled Consent host receives model tool calls."
  (skip-unless (consent-models-test--live-enabled-p))
  (consent-models-test--run-live-portable-host
   'compiled
   "Racket-compiled Consent Scheme live model tool-call"))

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
