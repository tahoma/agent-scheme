;;; consent-models-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the user-facing `(agent models)' vertical slice:
;; provider registration, role routing, local OpenAI-compatible completion,
;; fallback, privacy denial, and redacted diagnostics.

;;; Code:

(require 'ert)
(require 'json)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-models)
(require 'consent-policy)
(require 'consent-result)

(defvar consent-models-test--requests nil
  "Requests received by the fake model transport.")

(defun consent-models-test--transport
    (provider model role prompt options)
  "Return a fake completion for PROVIDER, MODEL, ROLE, PROMPT, and OPTIONS."
  (push (list provider model role prompt options)
    consent-models-test--requests)
  "mock completion")

(defun consent-models-test--tool-call-transport
    (provider model role prompt options)
  "Return a fake tool-calling completion for PROVIDER, MODEL, ROLE, and\
 PROMPT."
  (push (list provider model role prompt options)
    consent-models-test--requests)
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

(defun consent-models-test--cli-captured-output (stdout status)
  "Return process-host captured STDOUT with shell exit STATUS."
  (format "%s__CONSENT_CLI_EXIT__%d" stdout status))

(defun consent-models-test--openai-curl-output (body status &optional elapsed)
  "Return OpenAI-compatible curl BODY with HTTP STATUS and ELAPSED seconds."
  (format "%s__CONSENT_OPENAI_META__%d %s" body status (or elapsed "0.001")))

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

(defun consent-models-test--live-matrix-case (case)
  "Return one live matrix CASE as a ROLE . MODEL pair."
  (unless (string-match "\\`\\([^=[:space:]]+\\)=\\(.+\\)\\'" case)
    (ert-fail (format "Malformed CONSENT_LIVE_MODEL_MATRIX_CASES entry: %S"
                      case)))
  (cons (intern (match-string 1 case))
        (match-string 2 case)))

(defun consent-models-test--live-matrix-cases ()
  "Return live matrix cases supplied by the invoking shard."
  (let ((cases (getenv "CONSENT_LIVE_MODEL_MATRIX_CASES")))
    (unless (and cases (> (length cases) 0))
      (ert-fail "CONSENT_LIVE_MODEL_MATRIX_CASES is required."))
    (mapcar #'consent-models-test--live-matrix-case
            (split-string cases "," t "[[:space:]\n\t]+"))))

(ert-deftest consent-models-test-live-matrix-cases-come-from-environment ()
  "Read opt-in live matrix cases from the invoking shard."
  (let ((process-environment
         (cons
          (concat
           "CONSENT_LIVE_MODEL_MATRIX_CASES="
           "scheme-scripter=qwen2.5-coder:7b,"
           "planner=qwen3:4b,"
           "memory-curator=gemma3:4b")
          process-environment)))
    (should
     (equal
      (consent-models-test--live-matrix-cases)
      '((scheme-scripter . "qwen2.5-coder:7b")
        (planner . "qwen3:4b")
        (memory-curator . "gemma3:4b"))))))

(ert-deftest consent-models-test-live-planner-matrix-uses-quick-start-prompt ()
  "The planner matrix case exercises the quick-start tutorial prompt shape."
  (let ((prompt (consent-models-test--live-role-prompt 'planner))
        (options (consent-models-test--live-role-options 'planner)))
    (should (string-match-p "symbolic differentiator tutorial" prompt))
    (should (string-match-p "exactly five numbered steps" prompt))
    (should (member '(timeout-seconds 300) options))))

(defun consent-models-test--live-role-prompt (role)
  "Return the quick-start matrix prompt for ROLE."
  (cond
   ((eq role 'planner)
    "Plan a tiny R7RS Scheme symbolic differentiator tutorial.
Use only ASCII text. Do not write code.
The implementation will represent sums as (+ left right), products as
(* left right), and will test d/dx of x, y, (+ (* x x) (* 3 x)), and
(* x (+ x 3)). Reply with exactly five numbered steps for a
beginner-friendly REPL workloop.")
   ((eq role 'scheme-scripter)
    "Write only executable R7RS Scheme source.
Define a procedure square that returns the product of its argument with itself.
Define square-tests as a list of two boolean test results for 3 and -4.
Use only ASCII text and do not include Markdown fences or prose.")
   ((eq role 'memory-curator)
    "Summarize these REPL session facts as three concise memory bullets:
planner produced five steps, scheme-scripter drafted a differentiator, and
the local tests passed. Use only ASCII text.")
   (t
    "What is 2 plus 3? Reply with only the numeral.")))

(defun consent-models-test--live-role-options (role)
  "Return quick-start matrix model options for ROLE."
  (if (memq role '(planner scheme-scripter memory-curator))
      '((temperature 0.1) (timeout-seconds 300))
    '()))

(defun consent-models-test--live-completion-external (role model)
  "Return live completion output for ROLE and MODEL as external text."
  (let ((role-name (symbol-name role))
        (prompt (consent-models-test--live-role-prompt role))
        (options (consent-models-test--live-role-options role)))
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
                       %S
                       '%S)"
      (consent-models-test--live-endpoint)
      model
      role-name
      role-name
      prompt
      options))))

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
        \"Call local-echo with text exactly CONSENT_SMOKE_OK.\"
        (list (list 'tools (list tool))
              (list 'tool-choice tool)
              (list 'temperature 0))))"
    (consent-models-test--live-endpoint)
    (consent-models-test--live-model))))

(ert-deftest consent-models-test-local-complete-through-transport ()
  "Expose `(agent models)' and complete through a selected local provider."
  (consent-models-test--reset)
  (cl-letf (((symbol-function
              'consent-models--source-openai-compatible-http-complete)
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
      "(\"mock completion\" (model-routing-decision (status selected) (role\
 scheme-scripter) (provider local-llama) (model qwen-coder) (kind local)\
 (transport openai-compatible-http) (endpoint\
 \"http://127.0.0.1:11434/v1\")))"))
    (should (= (length consent-models-test--requests) 1))
    (let* ((request (car consent-models-test--requests))
           (provider (car request))
           (model (cadr request))
           (role (caddr request))
           (prompt (cadddr request)))
      (should (equal (plist-get provider :id) "local-llama"))
      (should (equal (plist-get model :id) "qwen-coder"))
      (should (equal role (consent-models--symbol "scheme-scripter")))
      (should (equal prompt "Write a Scheme helper.")))))

(ert-deftest consent-models-test-tool-spec-derived-and-routed ()
  "Derive tool specs from metadata and route canonical tool calls."
  (consent-models-test--reset)
  (cl-letf (((symbol-function
              'consent-models--source-openai-compatible-http-complete)
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
    (let* ((payload (nth 4 (car consent-models-test--requests)))
           (tools (consent-models--field-value payload "tools"))
           (tool-choice (consent-models--field-value payload "tool-choice")))
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
     (consent--source-library-call
      "(agent models openai)"
      "model-openai-parse-response"
      (concat
       "{\"choices\":[{\"message\":{\"content\":\"Use a tool.\","
       "\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\","
       "\"function\":{\"name\":\"local-echo\",\"arguments\":"
       "\"{\\\"text\\\":\\\"hello\\\"}\"}}]}}]}")))
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
           (consent--source-library-call
            "(agent models openai)"
            "model-openai-request-json"
            "qwen-coder"
            "Call local-echo."
            (list (list (consent-models--symbol "tools") (list tool))
                  (list (consent-models--symbol "tool-choice")
                        (consent--syntax-symbol "auto")))))))
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

(ert-deftest consent-models-test-complete-uses-source-openai-transport ()
  "Route local completions through the source-backed OpenAI transport."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let (seen)
    (cl-letf (((symbol-function
                'consent-models--source-openai-compatible-http-complete)
               (lambda (provider model role prompt options)
                 (setq seen (list provider model role prompt options))
                 "source completion")))
      (should
       (equal
        (consent-models-test--complete-local-model
         "source prompt"
         (consent-read "((timeout-seconds 7) (retry-count 0))"))
        "source completion")))
    (pcase-let ((`(,provider ,model ,role ,prompt ,options) seen))
      (should (equal (plist-get provider :id) "local-errors"))
      (should (equal (plist-get model :id) "qwen-coder"))
      (should (equal role (consent-models--symbol "scheme-scripter")))
      (should (equal prompt "source prompt"))
      (should (equal options
                     (consent-read
                       "((timeout-seconds 7) (retry-count 0))"))))))

(ert-deftest consent-models-test-no-native-emacs-openai-transport-surface ()
  "Keep OpenAI-compatible transport implementation out of Emacs Lisp."
  (should-not (boundp 'consent-models-transport-function))
  (should-not (fboundp 'consent-models-openai-compatible-http)))

(ert-deftest consent-models-test-source-transport-retries-through-process-host
  ()
  "Retry local transport failures in the source-backed Scheme transport."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let ((calls 0))
    (cl-letf (((symbol-function 'consent--primitive-cli-host-run)
               (lambda (_arguments _context)
                 (setq calls (1+ calls))
                 (if (= calls 1)
                     (list (consent--scheme-integer 0)
                           (consent-models-test--cli-captured-output "" 7)
                           "")
                   (list (consent--scheme-integer 0)
                         (consent-models-test--cli-captured-output
                          (consent-models-test--openai-curl-output
                           "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"
                           200)
                          0)
                         "")))))
      (should
       (equal
        (consent-models-test--complete-local-model
         "retry prompt"
         (consent-read "((timeout-seconds 7) (retry-count 1))"))
        "ok"))
      (should (= calls 2)))))

(ert-deftest
  consent-models-test-source-transport-budget-covers-large-planner-response ()
  "Source-backed transport budget covers a large local planner completion."
  (consent-models-test--reset)
  (let ((callbacks 0))
    (cl-letf (((symbol-function 'consent--primitive-cli-host-run)
               (lambda (_arguments context)
                 (dotimes (_ 250000)
                   (setq callbacks (1+ callbacks))
                   (consent--note-host-callback
                    context
                    'primitive-cli-host-run))
                 (list (consent--scheme-integer 0)
                       (consent-models-test--cli-captured-output
                        (consent-models-test--openai-curl-output
                         "{\"choices\":[{\"message\":{\"content\":\"1.\
 inspect\\n2. plan\\n3. draft\\n4. test\\n5. review\"}}]}"
                         200)
                        0)
                       ""))))
      (should
       (equal
        (consent-models-test--external
         "(import (scheme base) (agent models))
          (model-provider-register!
           '(model-provider
             (id local-large)
             (kind local)
             (transport openai-compatible-http)
             (endpoint \"http://127.0.0.1:11434/v1\")
             (models
              (((id qwen3:30b)
                (roles (planner))
                (privacy local))))))
          (model-complete
           'planner
           \"Plan a tiny R7RS Scheme symbolic differentiator tutorial.\"
           '((temperature 0.1) (timeout-seconds 300)))")
        "\"1. inspect\\n2. plan\\n3. draft\\n4. test\\n5. review\""))
      (should (= callbacks 250000)))))

(ert-deftest consent-models-test-source-error-preserves-structured-detail ()
  "Preserve the source transport's structured provider diagnostic."
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
              (reason \"HTTP 503: model still loading\"))")))
    (let* ((error
            (cl-letf (((symbol-function
                        'consent-models--source-openai-compatible-http-complete)
                       (lambda (_provider _model _role _prompt _options)
                         (signal 'consent-models-error
                                 (list "HTTP 503: model still loading"
                                       detail)))))
              (should-error
               (consent-models-test--complete-local-model
                "prompt text must not leak")
               :type 'consent-models-error)))
           (external (consent-models-test--error-external error)))
      (should
       (string-match-p
        "HTTP 503"
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

(ert-deftest
  consent-models-test-openai-http-error-keeps-status-and-body-excerpt ()
  "HTTP failures keep status, bounded body detail, and safe request metadata."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (cl-letf (((symbol-function 'consent--primitive-cli-host-run)
             (lambda (_arguments _context)
               (list (consent--scheme-integer 0)
                     (consent-models-test--cli-captured-output
                      (consent-models-test--openai-curl-output
                       "{\"error\":{\"message\":\"model still loading\"}}"
                       503)
                      0)
                     ""))))
    (let* ((error
            (should-error
             (consent-models-test--complete-local-model
              "transport prompt must stay hidden"
              (consent-read "((timeout-seconds 7) (retry-count 0))"))
             :type 'consent-models-error))
           (external (consent-models-test--error-external error)))
      (should
       (string-match-p
        "HTTP 503"
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
        external)))))

(ert-deftest
  consent-models-test-openai-http-error-honors-detail-budget-override ()
  "Per-call detail budgets can raise the excerpt cap without removing it."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (let* ((detail (concat (make-string 260 ?a) "tail-marker"))
         (body (format "{\"error\":{\"message\":\"%s\"}}" detail)))
    (cl-letf (((symbol-function 'consent--primitive-cli-host-run)
               (lambda (_arguments _context)
                 (list (consent--scheme-integer 0)
                       (consent-models-test--cli-captured-output
                        (consent-models-test--openai-curl-output body 503)
                        0)
                       ""))))
      (let* ((error
              (should-error
               (consent-models-test--complete-local-model
                "override prompt must stay hidden"
                (consent-read
                 "((max-transport-detail-bytes 320) (retry-count 0))"))
               :type 'consent-models-error))
             (datum (consent-models-test--error-datum error))
             (http (consent-models--field-value datum "http"))
             (excerpt (consent-models--field-value http "body-excerpt"))
             (request (consent-models--field-value datum "request")))
        (should (stringp excerpt))
        (should (> (length excerpt) 240))
        (should (<= (length excerpt) 320))
        (should (string-match-p "tail-marker" excerpt))
        (should
         (= (consent-number-value
             (consent-models--field-value request
                                          "max-transport-detail-bytes"))
            320))
        (should-not
         (string-match-p
          "override prompt must stay hidden"
          (consent-models-test--error-external error)))))))

(ert-deftest consent-models-test-openai-decode-failure-keeps-body-excerpt ()
  "Malformed provider bodies surface decode detail without leaking prompts."
  (consent-models-test--reset)
  (consent-models-test--register-local-provider)
  (cl-letf (((symbol-function 'consent--primitive-cli-host-run)
             (lambda (_arguments _context)
               (list (consent--scheme-integer 0)
                     (consent-models-test--cli-captured-output
                      (consent-models-test--openai-curl-output
                       "{\"choices\":[{\"message\":{\"content\":42}}]}"
                       200)
                      0)
                     ""))))
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
        external)))))

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
                             (string-append
                              \"Reply with exactly CONSENT_SMOKE_OK \"
                              \"and nothing else.\")
                             '((temperature 0)))"
            endpoint
            model))))
    (should (string-match-p "CONSENT_SMOKE_OK" external))))

(ert-deftest consent-models-test-live-local-openai-compatible-tool-call ()
  "Opt-in live proof that the Emacs host receives model tool calls."
  (skip-unless (consent-models-test--live-enabled-p))
  (consent-models-test--reset)
  (let ((external (consent-models-test--live-tool-call-external)))
    (should (string-match-p "(model-message" external))
    (should (string-match-p "(tool-calls" external))
    (should (string-match-p "(name local-echo)" external))
    (should
     (string-match-p
      "(arguments ((text \"CONSENT_SMOKE_OK\")))"
      external))))

(ert-deftest consent-models-test-live-local-quick-start-model-matrix ()
  "Opt-in live proof across the selected quick-start role/model matrix."
  (skip-unless (and (consent-models-test--live-enabled-p)
                    (consent-models-test--live-matrix-enabled-p)))
  (let (failures)
    (dolist (case (consent-models-test--live-matrix-cases))
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
    "(model-routing-decision (status selected) (role scheme-scripter)\
 (provider local-stack) (model warm-model) (kind local) (transport\
 openai-compatible-http) (endpoint \"http://127.0.0.1:11434/v1\"))")))

(ert-deftest consent-models-test-remote-local-only-denied-before-transport ()
  "Deny local-only context before a remote provider can run transport."
  (consent-models-test--reset)
  (cl-letf (((symbol-function
              'consent-models--source-openai-compatible-http-complete)
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
