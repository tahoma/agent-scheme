;;; Portable OpenAI-compatible model protocol tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; These tests exercise the pure JSON/protocol projection used by the portable
;;; Scheme model transport.  They deliberately inspect decoded JSON structure so
;;; nested model-tool schemas cannot collapse silently before reaching a live
;;; endpoint.

(import (scheme base)
        (scheme write)
        (only (agent models openai)
              model-openai-request-json
              model-openai-parse-response)
        (only (stdlib json)
              json-null?
              json-read
              json-write))

;; Number of failed checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed OpenAI protocol check."
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (check-value name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (json-ref object name)
  "Return NAME from decoded JSON OBJECT, or #f."
  (let ((entry (and (list? object) (assq name object))))
    (if entry (cdr entry) #f)))

(define (field-value record name)
  "Return NAME from a Scheme-readable RECORD, or #f."
  (let ((entry (and (pair? record) (assq name (cdr record)))))
    (if entry (cadr entry) #f)))

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
               "local-echo"))

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
    (function (name . "local-echo")))))

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
               '((text "hello") (count 2))))

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
                 '("nested" #f #t))))

(if (= failures 0)
    (begin
      (display "Portable OpenAI model protocol tests passed")
      (newline))
    (begin
      (display failures)
      (display " portable OpenAI model protocol test failure(s)")
      (newline)
      (error "portable OpenAI model protocol tests failed")))
