;;; Portable OpenAI-compatible model protocol tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; These tests exercise the pure JSON/protocol projection used by the portable
;;; Scheme model transport. They deliberately inspect decoded JSON structure so
;;; nested model-tool schemas cannot collapse silently before reaching a live
;;; endpoint.

(import (scheme base)
        (scheme write)
        (only (agent models openai)
              model-openai-request-json
              model-openai-parse-response
              model-openai-compatible-http-completion-result)
        (only (stdlib json)
              json-null?
              json-read
              json-write)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (check-value name actual expected)
  "Compare ACTUAL and EXPECTED as the named SRFI 64 assertion."
  (test-equal name expected actual))

(define (json-ref object name)
  "Return NAME from decoded JSON OBJECT, or #f."
  (let ((entry (and (list? object) (assq name object))))
    (if entry (cdr entry) #f)))

(define (field-value record name)
  "Return NAME from a Scheme-readable RECORD, or #f."
  (let ((entry (and (pair? record) (assq name (cdr record)))))
    (if entry (cadr entry) #f)))

(define (string-contains? haystack needle)
  "Return #t when HAYSTACK contains NEEDLE."
  (let ((hay (string-length haystack))
        (need (string-length needle)))
    (if (zero? need)
        #t
        (let loop ((start 0))
          (cond
           ((> (+ start need) hay) #f)
           ((let match ((index 0))
              (cond
               ((>= index need) #t)
               ((char=? (string-ref haystack (+ start index))
                        (string-ref needle index))
                (match (+ index 1)))
               (else #f)))
            #t)
           (else (loop (+ start 1))))))))

(define (ascii-string? text)
  "Return #t when TEXT contains only ASCII characters."
  (let ((length (string-length text)))
    (let loop ((index 0))
      (or (= index length)
          (and (< (char->integer (string-ref text index)) 128)
               (loop (+ index 1)))))))

(define (result-field record name default)
  "Return NAME from RECORD, or DEFAULT."
  (let ((entry (and (pair? record) (assq name (cdr record)))))
    (if entry (cadr entry) default)))

;; Canonical provider and model datums used by transport-result tests.
(define portable-provider
  '(model-provider
    (id local-errors)
    (kind local)
    (transport openai-compatible-http)
    (endpoint "http://127.0.0.1:11434/v1")))

;; Canonical model paired with portable-provider for transport-result tests.
(define portable-model '(model (id qwen-coder)))

(define (retrieval-output body status)
  "Return fake successful process retrieval output for BODY and HTTP STATUS."
  (list 0
        (string-append body
                       "__CONSENT_OPENAI_META__"
                       (number->string status)
                       " 0.001")
        ""))

(define (completion-result options attempt)
  "Run a deterministic portable model completion with OPTIONS and ATTEMPT."
  (model-openai-compatible-http-completion-result
   portable-provider portable-model 'scheme-scripter
   "prompt text must not leak" options attempt))

(define (expected-request-datum timeout detail-limit)
  "Return the exact safe request metadata for transport error checks."
  (list
   'model-provider-request
   (list 'role 'scheme-scripter)
   (list 'provider 'local-errors)
   (list 'model 'qwen-coder)
   (list 'kind 'local)
   (list 'transport 'openai-compatible-http)
   (list 'endpoint-origin "http://127.0.0.1:11434")
   (list 'request-path "/v1/chat/completions")
   (list
    'prompt
    '(redaction
      (kind prompt)
      (source provider-request)
      (replacement "[local-only]")
      (policy local-only)))
   (list 'timeout-seconds timeout)
   (list 'max-transport-detail-bytes detail-limit)
   (list 'retry-count 0)))

(define (expected-provider-error timeout detail-limit reason extra-fields)
  "Return the exact structured provider error for EXTRA-FIELDS."
  (append
   (list
    'model-provider-error
    (list 'request (expected-request-datum timeout detail-limit))
    (list 'status 'unavailable)
    (list 'provider 'local-errors)
    (list 'model 'qwen-coder)
    (list 'transport 'openai-compatible-http)
    (list 'reason reason)
    (list 'retry 'bounded-local-transport-retry)
    (list 'task-state 'blocked))
   extra-fields))

(define (expected-provider-error-summary reason)
  "Return the exact human-facing provider error summary for REASON."
  (string-append
   "local model transport failed for provider local-errors model "
   "qwen-coder via openai-compatible-http: "
   reason))

(define (detail-budget-error options)
  "Return the structured HTTP error produced with detail-limit OPTIONS."
  (let ((body
         (string-append
          "{\"error\":\""
          (make-string 400 #\a)
          "\"}")))
    (result-field
     (completion-result
      options
      (lambda (url request-json timeout)
        (retrieval-output body 503)))
     'error
     '())))

(define (padding-fields count)
  "Return COUNT irrelevant fields for large record traversal tests."
  (let loop ((remaining count) (fields '()))
    (if (= remaining 0)
        fields
        (loop (- remaining 1)
              (cons (list 'unused remaining) fields)))))

(define (cyclic-field-spine fields)
  "Make and return a cycle through the last pair of FIELDS."
  (let loop ((cursor fields))
    (if (null? (cdr cursor))
        (set-cdr! cursor fields)
        (loop (cdr cursor))))
  fields)

(define (make-cyclic-provider)
  "Return a provider whose public field spine contains a cycle."
  (let ((fields
         (list '(id local-errors)
               '(kind local)
               '(transport openai-compatible-http)
               '(endpoint "http://127.0.0.1:11434/v1"))))
    (cons 'model-provider (cyclic-field-spine fields))))

(define (make-cyclic-model)
  "Return a model whose public field spine contains a cycle."
  (cons 'model (cyclic-field-spine (list '(id qwen-coder)))))

(define (make-cyclic-options)
  "Return completion options whose public field spine contains a cycle."
  (cyclic-field-spine (list '(timeout-seconds 7) '(retry-count 1))))

;; Canonical tool schema used by request projection checks.
(define local-echo-tool
  '(model-tool
    (name local-echo)
    (schema
     (openai-tool
      (type function)
      (function
       (name "local-echo")
       (description "Echo text.")
       (parameters
        ((type "object")
         (properties
          ((text ((type "string")
                  (description "Text to echo.")))
           (count ((type "integer")
                   (description "Repeat count.")))))
         (required ("text" "count")))))))))

(define (request-with-tool)
  "Return the decoded JSON request for a forced local-echo tool call."
  (json-read
   (open-input-string
    (model-openai-request-json
     "qwen3:0.6b"
     "Call local-echo."
     (list (list 'tools (list local-echo-tool))
           (list 'tool-choice local-echo-tool))))))

(testing-registry-case
 'model-openai-request-non-ascii-json-ascii-only '(portable core)
(let* ((non-ascii-prompt
        (string-append "Reuse "
                       (string (integer->char #x2192))
                       " and "
                       (string (integer->char #x3bb))
                       " and "
                       (string (integer->char #x1f600))))
       (request-json
        (model-openai-request-json "qwen3:0.6b" non-ascii-prompt '()))
       (request (json-read (open-input-string request-json)))
       (message (vector-ref (json-ref request 'messages) 0)))
  (check-value 'model-openai-request-non-ascii-json-ascii-only
               (ascii-string? request-json)
               #t)
  (check-value 'model-openai-request-non-ascii-roundtrip
               (json-ref message 'content)
               non-ascii-prompt)
  (check-value 'model-openai-request-non-ascii-escapes-bmp
               (and (string-contains? request-json "\\u2192")
                    (string-contains? request-json "\\u03bb"))
               #t)
  (check-value 'model-openai-request-non-ascii-escapes-non-bmp
               (string-contains? request-json "\\ud83d\\ude00")
               #t)
  (let* ((completion non-ascii-prompt)
         (next-json
          (model-openai-request-json "qwen3:0.6b" completion '()))
         (next-request (json-read (open-input-string next-json)))
         (next-message (vector-ref (json-ref next-request 'messages) 0)))
    (check-value 'model-openai-request-non-ascii-roundtrip-reuse-as-prompt
                 (json-ref next-message 'content)
                 completion)
    (check-value 'model-openai-request-non-ascii-reused-json-ascii-only
                 (ascii-string? next-json)
                 #t))))

(testing-registry-case
 'model-openai-request-tool-count '(portable core)
(let* ((request (request-with-tool))
       (tools (json-ref request 'tools))
       (tool (vector-ref tools 0))
       (function (json-ref tool 'function))
       (parameters (json-ref function 'parameters))
       (properties (json-ref parameters 'properties))
       (text (json-ref properties 'text))
       (count (json-ref properties 'count))
       (required (json-ref parameters 'required))
       (tool-choice (json-ref request 'tool_choice))
       (choice-function (json-ref tool-choice 'function)))
  (check-value 'model-openai-request-tool-count
               (vector-length tools)
               1)
  (check-value 'model-openai-request-tool-type
               (json-ref tool 'type)
               "function")
  (check-value 'model-openai-request-function-name
               (json-ref function 'name)
               "local-echo")
  (check-value 'model-openai-request-function-description
               (json-ref function 'description)
               "Echo text.")
  (check-value 'model-openai-request-parameters-type
               (json-ref parameters 'type)
               "object")
  (check-value 'model-openai-request-text-type
               (json-ref text 'type)
               "string")
  (check-value 'model-openai-request-count-type
               (json-ref count 'type)
               "integer")
  (check-value 'model-openai-request-required
               (vector->list required)
               '("text" "count"))
  (check-value 'model-openai-request-tool-choice
               (json-ref choice-function 'name)
               "local-echo")))

(testing-registry-case
 'model-openai-request-full-shape '(portable core)
(check-value
 'model-openai-request-full-shape
 (request-with-tool)
 `((model . "qwen3:0.6b")
   (messages . #(((role . "user")
                  (content . "Call local-echo."))))
   (stream . #f)
   (tools . #(((type . "function")
               (function
                (name . "local-echo")
                (description . "Echo text.")
                (parameters
                 (type . "object")
                 (properties
                  (text
                   (type . "string")
                   (description . "Text to echo."))
                  (count
                   (type . "integer")
                   (description . "Repeat count.")))
                 (required . #("text" "count")))))))
   (tool_choice
    (type . "function")
    (function (name . "local-echo"))))))

(testing-registry-case
 'model-openai-parse-message-head '(portable core)
(let* ((response
        (model-openai-parse-response
         (string-append
          "{\"choices\":[{\"message\":{\"content\":\"Use a tool.\","
          "\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\","
          "\"function\":{\"name\":\"local-echo\",\"arguments\":"
          "\"{\\\"text\\\":\\\"hello\\\",\\\"count\\\":2}\"}}]}}]}")))
       (tool-calls (field-value response 'tool-calls))
       (call (car tool-calls))
       (arguments (field-value call 'arguments)))
  (check-value 'model-openai-parse-message-head
               (car response)
               'model-message)
  (check-value 'model-openai-parse-message-text
               (field-value response 'text)
               "Use a tool.")
  (check-value 'model-openai-parse-tool-id
               (field-value call 'id)
               "call-1")
  (check-value 'model-openai-parse-tool-name
               (field-value call 'name)
               'local-echo)
  (check-value 'model-openai-parse-tool-arguments
               arguments
               '((text "hello") (count 2)))))

(testing-registry-case
 'model-openai-parse-duplicate-content-first '(portable core)
(check-value
 'model-openai-parse-duplicate-content-first
 (model-openai-parse-response
  (string-append
   "{\"choices\":[{\"message\":{"
   "\"content\":\"first\",\"content\":\"second\"}}]}"))
 "first"))

(testing-registry-case
 'model-openai-parse-duplicate-tool-fields-first '(portable core)
(let* ((response
        (model-openai-parse-response
         (string-append
          "{\"choices\":[{\"message\":{\"tool_calls\":[{"
          "\"id\":\"first\",\"id\":\"second\",\"function\":{"
          "\"name\":\"one\",\"name\":\"two\","
          "\"arguments\":\"{\\\"x\\\":1}\","
          "\"arguments\":\"{\\\"x\\\":2}\"}}]}}]}")))
       (call (car (field-value response 'tool-calls))))
  (check-value 'model-openai-parse-duplicate-tool-id
               (field-value call 'id)
               "first")
  (check-value 'model-openai-parse-duplicate-tool-name
               (field-value call 'name)
               'one)
  (check-value 'model-openai-parse-duplicate-tool-arguments
               (field-value call 'arguments)
               '((x 1)))))

(testing-registry-case
 'consent-json-nested-first '(portable core)
(let ((out (open-output-string)))
  (json-write
   '((outer
      (first . "one")
      (second
       (third . 3)
       (fourth . #t))
      (array . #(((name . "nested") (enabled . #f)) null))))
   out)
  (let* ((decoded
          (json-read (open-input-string (get-output-string out))))
         (outer (json-ref decoded 'outer))
         (second (json-ref outer 'second))
         (array (json-ref outer 'array))
         (nested (vector-ref array 0)))
    (check-value 'consent-json-nested-first
                 (json-ref outer 'first)
                 "one")
    (check-value 'consent-json-nested-third
                 (json-ref second 'third)
                 3)
    (check-value 'consent-json-nested-fourth
                 (json-ref second 'fourth)
                 #t)
    (check-value 'consent-json-nested-array-object
                 (list (json-ref nested 'name)
                       (json-ref nested 'enabled)
                       (json-null? (vector-ref array 1)))
                 '("nested" #f #t)))))

(testing-registry-case
 'model-openai-retry-count '(portable core)
(let ((calls 0))
  (let ((result
         (completion-result
          '((timeout-seconds 7) (retry-count 1))
          (lambda (url request-json timeout)
            (set! calls (+ calls 1))
            (if (= calls 1)
                (list 7 "" "connection refused")
                (retrieval-output
                 "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"
                 200))))))
    (check-value 'model-openai-retry-count calls 2)
    (check-value 'model-openai-retry-status
                 (result-field result 'status #f) 'ok)
    (check-value 'model-openai-retry-value
                 (result-field result 'value #f) "ok"))))

(testing-registry-case
 'model-openai-option-projection-precedence '(portable core)
(let* ((request
        (json-read
         (open-input-string
          (model-openai-request-json
           "qwen3:0.6b"
           "prompt"
           '((tool_choice required)
             (tool-choice auto)
             (tool-choice none))))))
       (valueless-request
        (json-read
         (open-input-string
          (model-openai-request-json
           "qwen3:0.6b"
           "prompt"
           '((tool_choice required)
             (tool-choice)
             (tool_choice none)
             (tool-choice auto))))))
       (suppressed-request
        (json-read
         (open-input-string
          (model-openai-request-json
           "qwen3:0.6b"
           "prompt"
           '((tool_choice required)
             (tool-choice #f)
             (tool_choice none)
             (tool-choice auto))))))
       (calls 0)
       (timeouts '())
       (result
        (completion-result
         '((timeout-seconds 7)
           (timeout-seconds 99)
           (retry-count 1)
           (retry-count 3))
         (lambda (url request-json timeout)
           (set! calls (+ calls 1))
           (set! timeouts (cons timeout timeouts))
           (if (= calls 1)
               (list 7 "" "connection refused")
               (retrieval-output
                "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"
                200))))))
  (check-value 'model-openai-option-projection-tool-choice
               (json-ref request 'tool_choice)
               "auto")
  (check-value 'model-openai-option-valueless-primary-uses-first-alias
               (json-ref valueless-request 'tool_choice)
               "required")
  (check-value 'model-openai-option-false-primary-suppresses-alias
               (assq 'tool_choice suppressed-request)
               #f)
  (check-value 'model-openai-option-projection-retry-count calls 2)
  (check-value 'model-openai-option-projection-timeout
               (reverse timeouts)
               '(7 7))
  (check-value 'model-openai-option-projection-result
               (result-field result 'value #f)
               "ok")))

(testing-registry-case
 'model-openai-request-non-pair-options '(portable core)
(check-value
 'model-openai-request-non-pair-options
 (model-openai-request-json "qwen3:0.6b" "prompt" #f)
 (model-openai-request-json "qwen3:0.6b" "prompt" '())))

(testing-registry-case
 'model-openai-large-provider-first-fields '(portable core)
(let ((calls 0)
      (seen-url #f))
  (let* ((provider
          (append
           portable-provider
           (padding-fields 1024)
           '((kind remote)
             (transport unsupported)
             (endpoint "https://example.com/v1"))))
         (result
          (model-openai-compatible-http-completion-result
           provider portable-model 'scheme-scripter "prompt" '()
           (lambda (url request-json timeout)
             (set! calls (+ calls 1))
             (set! seen-url url)
             (retrieval-output
              "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"
              200)))))
    (check-value 'model-openai-large-provider-first-fields calls 1)
    (check-value 'model-openai-large-provider-first-url
                 seen-url
                 "http://127.0.0.1:11434/v1/chat/completions")
    (check-value 'model-openai-large-provider-first-value
                 (result-field result 'value #f)
                 "ok"))))

(testing-registry-case
 'model-openai-provider-validates-improper-tail '(portable core)
(let ((calls 0))
  (let ((result
         (model-openai-compatible-http-completion-result
          '(model-provider
            (id local-errors)
            (kind local)
            (transport openai-compatible-http)
            (endpoint "http://127.0.0.1:11434/v1")
            . malformed-tail)
          portable-model
          'scheme-scripter
          "prompt"
          '()
          (lambda (url request-json timeout)
            (set! calls (+ calls 1))
            (retrieval-output
             "{\"choices\":[{\"message\":{\"content\":\"wrong\"}}]}"
             200)))))
    (check-value 'model-openai-provider-validates-improper-tail calls 0)
    (check-value 'model-openai-provider-improper-tail-status
                 (result-field result 'status #f)
                 'error))))

(testing-registry-case
 'model-openai-provider-rejects-cyclic-spine '(portable core)
(let ((calls 0))
  (let ((result
         (model-openai-compatible-http-completion-result
          (make-cyclic-provider)
          portable-model
          'scheme-scripter
          "prompt"
          '()
          (lambda (url request-json timeout)
            (set! calls (+ calls 1))
            (retrieval-output
             "{\"choices\":[{\"message\":{\"content\":\"wrong\"}}]}"
             200)))))
    (check-value 'model-openai-provider-rejects-cyclic-spine calls 0)
    (check-value 'model-openai-provider-cyclic-result-head
                 (car result)
                 'model-completion-result)
    (check-value 'model-openai-provider-cyclic-status
                 (result-field result 'status #f)
                 'error))))

(testing-registry-case
 'model-openai-model-and-options-reject-cyclic-spines '(portable core)
(let ((calls 0))
  (let ((model-result
         (model-openai-compatible-http-completion-result
          portable-provider
          (make-cyclic-model)
          'scheme-scripter
          "prompt"
          '()
          (lambda (url request-json timeout)
            (set! calls (+ calls 1))
            (retrieval-output
             "{\"choices\":[{\"message\":{\"content\":\"wrong\"}}]}"
             200))))
        (options-result
         (completion-result
          (make-cyclic-options)
          (lambda (url request-json timeout)
            (set! calls (+ calls 1))
            (retrieval-output
             "{\"choices\":[{\"message\":{\"content\":\"wrong\"}}]}"
             200)))))
    (check-value 'model-openai-model-options-cyclic-no-transport calls 0)
    (check-value 'model-openai-model-cyclic-status
                 (result-field model-result 'status #f)
                 'error)
    (check-value 'model-openai-options-cyclic-status
                 (result-field options-result 'status #f)
                 'error))))

(testing-registry-case
 'model-openai-long-curl-metadata-scan '(portable core)
(let* ((body "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}")
       (result
        (completion-result
         '()
         (lambda (url request-json timeout)
           (list 0
                 (string-append body
                                "__CONSENT_OPENAI_META__"
                                (make-string 4096 #\x))
                 "")))))
  (check-value 'model-openai-long-curl-metadata-status
               (result-field result 'status #f)
               'ok)
  (check-value 'model-openai-long-curl-metadata-value
               (result-field result 'value #f)
               "ok")))

(testing-registry-case
 'model-openai-process-error-exact-projection '(portable core)
(let* ((reason "curl exited 7: connection refused")
       (result
        (completion-result
         '((timeout-seconds 7) (retry-count 0))
         (lambda (url request-json timeout)
           (list 7 "" "connection refused"))))
       (expected-error
        (expected-provider-error
         7
         240
         reason
         (list
          (list 'phase 'process)
          (list
           'process
           (list
            'process-failure
            (list 'exit-status 7)
            (list 'detail reason)))))))
  (check-value
   'model-openai-process-error-field-order
   (result-field result 'error #f)
   expected-error)
  (check-value
   'model-openai-process-error-summary
   (result-field result 'message #f)
   (expected-provider-error-summary reason))))

(testing-registry-case
 'model-openai-http-error-status '(portable core)
(let* ((body "{\"error\":{\"message\":\"model still loading\"}}")
       (reason (string-append "HTTP 503: " body))
       (result
        (completion-result
         '((timeout-seconds 7) (retry-count 0))
         (lambda (url request-json timeout)
           (retrieval-output body 503))))
       (error-datum (result-field result 'error '()))
       (request (result-field error-datum 'request '()))
       (http (result-field error-datum 'http '()))
       (expected-error
        (expected-provider-error
         7
         240
         reason
         (list
          (list 'phase 'http)
          (list
           'http
           (list
            'http-failure
            (list 'status 503)
            (list 'body-excerpt body)))
          (list 'elapsed-ms 1)))))
  (check-value 'model-openai-http-error-status
               (result-field result 'status #f) 'error)
  (check-value 'model-openai-http-error-phase
               (result-field error-datum 'phase #f) 'http)
  (check-value 'model-openai-http-error-code
               (result-field http 'status #f) 503)
  (check-value 'model-openai-http-error-excerpt
               (result-field http 'body-excerpt #f)
               body)
  (check-value 'model-openai-http-error-timeout
               (result-field request 'timeout-seconds #f) 7)
  (let ((out (open-output-string)))
    (write error-datum out)
    (check-value 'model-openai-http-error-prompt-redacted
                 (string-contains?
                  (get-output-string out) "prompt text must not leak")
                 #f))
  (check-value
   'model-openai-http-error-field-order
   error-datum
   expected-error)
  (check-value
   'model-openai-http-error-summary
   (result-field result 'message #f)
   (expected-provider-error-summary reason))))

(testing-registry-case
 'model-openai-detail-budget-status '(portable core)
(let* ((detail (string-append (make-string 260 #\a) "tail-marker"))
       (body (string-append "{\"error\":{\"message\":\"" detail "\"}}"))
       (result
        (completion-result
         '((max-transport-detail-bytes 320) (retry-count 0))
         (lambda (url request-json timeout)
           (retrieval-output body 503))))
       (error-datum (result-field result 'error '()))
       (http (result-field error-datum 'http '()))
       (excerpt (result-field http 'body-excerpt "")))
  (check-value 'model-openai-detail-budget-status
               (result-field result 'status #f) 'error)
  (check-value 'model-openai-detail-budget-lower-bound
               (> (string-length excerpt) 240) #t)
  (check-value 'model-openai-detail-budget-upper-bound
               (<= (string-length excerpt) 320) #t)
  (check-value 'model-openai-detail-budget-tail
               (string-contains? excerpt "tail-marker") #t)))

(testing-registry-case
 'model-openai-inexact-detail-budgets-use-default '(portable core)
(let* ((primary-error
        (detail-budget-error
         '((max-transport-detail-bytes 320.0)
           (max_transport_detail_bytes 320))))
       (primary-request (result-field primary-error 'request '()))
       (primary-http (result-field primary-error 'http '()))
       (alias-error
        (detail-budget-error
         '((max_transport_detail_bytes 320.0))))
       (alias-request (result-field alias-error 'request '()))
       (alias-http (result-field alias-error 'http '())))
  (check-value 'model-openai-inexact-primary-detail-budget
               (result-field
                primary-request
                'max-transport-detail-bytes
                #f)
               240)
  (check-value 'model-openai-inexact-primary-detail-excerpt
               (string-length
                (result-field primary-http 'body-excerpt ""))
               240)
  (check-value 'model-openai-inexact-alias-detail-budget
               (result-field
                alias-request
                'max-transport-detail-bytes
                #f)
               240)
  (check-value 'model-openai-inexact-alias-detail-excerpt
               (string-length
                (result-field alias-http 'body-excerpt ""))
               240)))

(testing-registry-case
 'model-openai-decode-error-status '(portable core)
(let* ((body "{\"choices\":[{\"message\":{\"content\":42}}]}")
       (detail "OpenAI-compatible response did not contain text")
       (reason (string-append "response decode failed: " detail))
       (result
        (completion-result
         '()
         (lambda (url request-json timeout)
           (retrieval-output body 200))))
       (error-datum (result-field result 'error '()))
       (decode (result-field error-datum 'decode '()))
       (expected-error
        (expected-provider-error
         30
         240
         reason
         (list
          (list 'phase 'decode)
          (list
           'decode
           (list
            'decode-failure
            (list 'detail detail)
            (list 'http-status 200)
            (list 'body-excerpt body)))
          (list 'elapsed-ms 1)))))
  (check-value 'model-openai-decode-error-status
               (result-field result 'status #f) 'error)
  (check-value 'model-openai-decode-error-phase
               (result-field error-datum 'phase #f) 'decode)
  (check-value 'model-openai-decode-error-body
               (result-field decode 'body-excerpt #f) body)
  (check-value
   'model-openai-decode-error-field-order
   error-datum
   expected-error)
  (check-value
   'model-openai-decode-error-summary
   (result-field result 'message #f)
   (expected-provider-error-summary reason))))

(testing-runner-main "Consent Models Openai portable tests" (command-line))
