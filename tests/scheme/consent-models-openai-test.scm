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
 'model-openai-http-error-status '(portable core)
(let* ((result
        (completion-result
         '((timeout-seconds 7) (retry-count 0))
         (lambda (url request-json timeout)
           (retrieval-output
            "{\"error\":{\"message\":\"model still loading\"}}"
            503))))
       (error-datum (result-field result 'error '()))
       (request (result-field error-datum 'request '()))
       (http (result-field error-datum 'http '())))
  (check-value 'model-openai-http-error-status
               (result-field result 'status #f) 'error)
  (check-value 'model-openai-http-error-phase
               (result-field error-datum 'phase #f) 'http)
  (check-value 'model-openai-http-error-code
               (result-field http 'status #f) 503)
  (check-value 'model-openai-http-error-excerpt
               (result-field http 'body-excerpt #f)
               "{\"error\":{\"message\":\"model still loading\"}}")
  (check-value 'model-openai-http-error-timeout
               (result-field request 'timeout-seconds #f) 7)
  (let ((out (open-output-string)))
    (write error-datum out)
    (check-value 'model-openai-http-error-prompt-redacted
                 (string-contains?
                  (get-output-string out) "prompt text must not leak")
                 #f))))

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
 'model-openai-decode-error-status '(portable core)
(let* ((body "{\"choices\":[{\"message\":{\"content\":42}}]}")
       (result
        (completion-result
         '()
         (lambda (url request-json timeout)
           (retrieval-output body 200))))
       (error-datum (result-field result 'error '()))
       (decode (result-field error-datum 'decode '())))
  (check-value 'model-openai-decode-error-status
               (result-field result 'status #f) 'error)
  (check-value 'model-openai-decode-error-phase
               (result-field error-datum 'phase #f) 'decode)
  (check-value 'model-openai-decode-error-body
               (result-field decode 'body-excerpt #f) body)))

(testing-runner-main "Consent Models Openai portable tests" (command-line))
