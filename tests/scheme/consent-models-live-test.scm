;;; Portable live model transport tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This file is intentionally kept out of the default portable suite and run
;;; by
;;; the opt-in Scheme-native live model shard.  It reaches a real local
;;; OpenAI-compatible endpoint through `(model-complete)' so the portable
;;; Scheme
;;; backend cannot satisfy the check with a fake transport.

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (only (consent eval)
              consent-eval-source-result)
        (only (consent result)
              consent-result->external)
        (testing harness)
        (stdlib testing))

(define (field-value datum field)
  "Return FIELD from a Scheme-readable result or record datum."
  (let ((entry (and (pair? datum) (assq field (cdr datum)))))
    (if entry (cadr entry) #f)))

(define (third list)
  "Return the third element of LIST without relying on optional caddr."
  (car (cdr (cdr list))))

(define (env-or-default name default)
  "Return environment variable NAME, or DEFAULT when unset."
  (let ((value (get-environment-variable name)))
    (if (and value (> (string-length value) 0)) value default)))

(define (scheme-literal value)
  "Return VALUE rendered as a Scheme source literal."
  (let ((port (open-output-string)))
    (write value port)
    (get-output-string port)))

(define (live-tool-call-source endpoint model)
  "Return a Consent Scheme program that forces one live local tool call."
  (string-append
   "(import (scheme base) (agent models))
    (define (field datum name)
      (let loop ((fields (if (and (pair? datum)
                                  (not (pair? (car datum))))
                             (cdr datum)
                             datum)))
        (cond
         ((not (pair? fields)) #f)
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
       (id portable-live-tools)
       (kind local)
       (transport openai-compatible-http)
       (endpoint "
   (scheme-literal endpoint)
   ")
       (models
        (((id "
   (scheme-literal model)
   ")
          (roles (scheme-scripter code))
          (privacy local))))))
    (let* ((tool (model-tool-spec 'local-echo))
           (response
            (model-complete
             'scheme-scripter
             \"Call the local-echo tool with text exactly portable-ci-tool-cal\
l.\"
             (list (list 'tools (list tool))
                   (list 'tool-choice tool))))
           (tool-calls (field response 'tool-calls))
           (call (if (and (pair? tool-calls) (pair? (car tool-calls)))
                     (car tool-calls)
                     '()))
           (arguments (field call 'arguments))
           (text (field arguments 'text)))
      (list (eq? (car response) 'model-message)
            (let ((name (field call 'name)))
              (and (symbol? name)
                   (string=? (symbol->string name) \"local-echo\")))
            (string? text)))"))

(define (run-live-tool-call-check)
  "Run the live portable model tool-call check against the configured endpoint\
."
  (let* ((endpoint
         (env-or-default "CONSENT_LIVE_MODEL_ENDPOINT"
                          "http://127.0.0.1:11434/v1"))
         (model
          (env-or-default "CONSENT_LIVE_MODEL_ID" "qwen3:0.6b"))
         (result
          (consent-eval-source-result
           (live-tool-call-source endpoint model)
           #f
           '((docstring-retention . full))))
         (status (field-value result 'status))
         (value (field-value result 'value)))
    (test-equal "portable live model tool-call status" 'ok status)
    (if (equal? status 'ok)
        (begin
          (test-assert "portable live model message"
                       (and (pair? value) (car value)))
          (test-assert "portable live model tool name"
                       (and (pair? value)
                            (pair? (cdr value))
                            (cadr value)))
          (test-assert "portable live model tool argument string"
                       (and (pair? value)
                            (pair? (cdr value))
                            (pair? (cddr value))
                            (third value))))
        (begin
          (display "Portable live model result: ")
          (display (consent-result->external result))
          (newline)))))

(testing-harness-run "Portable live model tool call"
  (run-live-tool-call-check))
