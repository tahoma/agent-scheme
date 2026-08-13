;;; Compiled Consent Scheme live model transport tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs directly inside a compiled Consent `--host-run' context.
;;; Direct R7RS hosts use consent-models-live-test.scm, which enters the
;;; Consent
;;; evaluator explicitly; nesting that evaluator inside a self-host needlessly
;;; repeats bootstrap and does not exercise the compiled interaction context.

(import (scheme base)
        (scheme process-context)
        (agent models)
        (testing harness)
        (stdlib testing))

(define (field datum name)
  "Return NAME from DATUM, or #f when the field is absent."
  (let loop ((fields (if (and (pair? datum)
                              (not (pair? (car datum))))
                         (cdr datum)
                         datum)))
    (cond
     ((not (pair? fields)) #f)
     ((and (pair? (car fields))
           (eq? (car (car fields)) name))
      (cadr (car fields)))
     (else (loop (cdr fields))))))

(define (env-or-default name default)
  "Return environment variable NAME, or DEFAULT when unset."
  (let ((value (get-environment-variable name)))
    (if (and value (> (string-length value) 0)) value default)))

(define (local-echo text)
  "Echo TEXT through a pure local helper."
  #((parameters
     (text (type string)
      (description "Text to echo.")))
    (returns (type string)
     (description "The echoed text."))
    (effects pure))
  text)

(model-provider-register!
 (list 'model-provider
       (list 'id 'portable-compiled-live-tools)
       (list 'kind 'local)
       (list 'transport 'openai-compatible-http)
       (list 'endpoint
             (env-or-default "CONSENT_LIVE_MODEL_ENDPOINT"
                             "http://127.0.0.1:11434/v1"))
       (list 'models
             (list
              (list
               (list 'id
                     (env-or-default "CONSENT_LIVE_MODEL_ID" "qwen3:0.6b"))
               (list 'roles '(scheme-scripter code))
               (list 'privacy 'local))))))

(testing-harness-run "Compiled live model tool call"
  (let* ((tool (model-tool-spec 'local-echo))
         (response
          (model-complete
           'scheme-scripter
           "Call local-echo with text exactly CONSENT_SMOKE_OK."
           (list (list 'tools (list tool))
                 (list 'tool-choice tool)
                 (list 'temperature 0))))
         (tool-calls (field response 'tool-calls))
         (call (if (and (pair? tool-calls) (pair? (car tool-calls)))
                   (car tool-calls)
                   '()))
         (arguments (field call 'arguments))
         (text (field arguments 'text)))
    (test-assert "compiled host returns a model message"
                 (and (pair? response)
                      (eq? (car response) 'model-message)))
    (test-assert "compiled host receives the forced tool name"
                 (let ((name (field call 'name)))
                   (and (symbol? name)
                        (string=? (symbol->string name) "local-echo"))))
    (test-assert "compiled host receives the exact tool argument"
                 (and (string? text)
                      (string=? text "CONSENT_SMOKE_OK")))))
