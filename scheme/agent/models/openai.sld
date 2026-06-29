;;; Portable OpenAI-compatible model transport projection.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral parts of the local OpenAI-compatible
;;; transport: canonical model/tool datums to JSON, loopback endpoint validation,
;;; and JSON response parsing.  The only host effect is delegated to
;;; `(cli process-host)', whose per-host implementations are the small process
;;; boundary needed to run `curl'.

(define-library (agent models openai)
  (export model-openai-request-json
          model-openai-parse-response
          model-openai-compatible-http-complete)
  (import (scheme base)
          (prefix (cli process-host) cli-host:)
          (prefix (consent json) json-model:))
  (begin
    ;; Default request timeout for local OpenAI-compatible HTTP transports.
    (define model-openai-default-timeout-seconds 30)

    (define (model-openai-field-values datum)
      "Return field pairs from DATUM, skipping a record head when present."
      (if (not (pair? datum))
          '()
          (let ((fields
                 (if (and (symbol? (car datum))
                          (not (and (pair? (car datum))
                                    (symbol? (caar datum)))))
                     (cdr datum)
                     datum)))
            (let loop ((cursor fields) (result '()))
              (cond
               ((null? cursor) (reverse result))
               ((and (pair? (car cursor)) (symbol? (caar cursor)))
                (loop (cdr cursor) (cons (car cursor) result)))
               (else (loop (cdr cursor) result)))))))

    (define (model-openai-field-entry-value entry default)
      "Return ENTRY's value for either list-field or alist-field shapes."
      (let ((tail (cdr entry)))
        (cond
         ((null? tail) default)
         ((pair? tail) (car tail))
         (else tail))))

    (define (model-openai-schema-entry-value entry)
      "Return ENTRY's full schema value, preserving multi-field records."
      (let ((tail (cdr entry)))
        (cond
         ((null? tail) '())
         ((and (pair? tail) (null? (cdr tail))) (car tail))
         (else tail))))

    (define (model-openai-third list)
      "Return the third element of LIST without relying on optional caddr."
      (car (cdr (cdr list))))

    (define (model-openai-field-value datum name default)
      "Return field NAME from DATUM, or DEFAULT when absent."
      (let loop ((fields (model-openai-field-values datum)))
        (cond
         ((null? fields) default)
         ((eq? (car (car fields)) name)
          (model-openai-field-entry-value (car fields) default))
         (else (loop (cdr fields))))))

    (define (model-openai-field-value-any datum names default)
      "Return the first field in NAMES found in DATUM, or DEFAULT."
      (if (null? names)
          default
          (let ((value
                 (model-openai-field-value datum (car names) default)))
            (if (eq? value default)
                (model-openai-field-value-any datum (cdr names) default)
                value))))

    (define (model-openai-name value description)
      "Return VALUE as a provider/model symbol or raise DESCRIPTION."
      (cond
       ((symbol? value) value)
       ((string? value) (string->symbol value))
       (else (error (string-append description " must be a symbol or string")
                    value))))

    (define (model-openai-name-string value description)
      "Return VALUE as a provider/model name string."
      (symbol->string (model-openai-name value description)))

    (define (model-openai-record-head datum)
      "Return DATUM's record head, or #f."
      (and (pair? datum) (symbol? (car datum)) (car datum)))

    (define (model-openai-model-tool? datum)
      "Return #t when DATUM is a canonical model-tool record."
      (eq? (model-openai-record-head datum) 'model-tool))

    (define (model-openai-string-prefix? prefix string)
      "Return #t when STRING starts with PREFIX."
      (let ((prefix-length (string-length prefix))
            (string-length* (string-length string)))
        (and (<= prefix-length string-length*)
             (string=? prefix (substring string 0 prefix-length)))))

    (define (model-openai-string-suffix? suffix string)
      "Return #t when STRING ends with SUFFIX."
      (let ((suffix-length (string-length suffix))
            (string-length* (string-length string)))
        (and (<= suffix-length string-length*)
             (string=?
              suffix
              (substring string
                         (- string-length* suffix-length)
                         string-length*)))))

    (define (model-openai-strip-trailing-slashes endpoint)
      "Return ENDPOINT without trailing slash characters."
      (let loop ((end (string-length endpoint)))
        (if (and (> end 0)
                 (char=? (string-ref endpoint (- end 1)) #\/))
            (loop (- end 1))
            (substring endpoint 0 end))))

    (define (model-openai-loopback-host-prefix? endpoint prefix)
      "Return #t when ENDPOINT starts with loopback host PREFIX."
      (let ((length (string-length endpoint))
            (prefix-length (string-length prefix)))
        (and (model-openai-string-prefix? prefix endpoint)
             (or (= length prefix-length)
                 (let ((next (string-ref endpoint prefix-length)))
                   (or (char=? next #\/)
                       (char=? next #\:)))))))

    (define (model-openai-local-endpoint? endpoint)
      "Return #t when ENDPOINT targets a loopback HTTP(S) host."
      (and
       (string? endpoint)
       (or (model-openai-loopback-host-prefix? endpoint "http://localhost")
           (model-openai-loopback-host-prefix? endpoint "https://localhost")
           (model-openai-string-prefix? "http://127." endpoint)
           (model-openai-string-prefix? "https://127." endpoint)
           (model-openai-loopback-host-prefix? endpoint "http://[::1]")
           (model-openai-loopback-host-prefix? endpoint "https://[::1]"))))

    (define (model-openai-completion-url endpoint)
      "Return OpenAI-compatible chat completions URL for ENDPOINT."
      (let ((base (model-openai-strip-trailing-slashes endpoint)))
        (cond
         ((model-openai-string-suffix? "/chat/completions" base)
          base)
         ((model-openai-string-suffix? "/v1" base)
          (string-append base "/chat/completions"))
         (else
          (string-append base "/v1/chat/completions")))))

    (define (model-openai-schema-field? value)
      "Return #t when VALUE is a Scheme-readable schema field entry."
      (and (pair? value) (symbol? (car value))))

    (define (model-openai-schema-fields? value)
      "Return #t when VALUE is a non-empty list of schema field entries."
      (and (pair? value)
           (let loop ((cursor value))
             (cond
              ((null? cursor) #t)
              ((and (pair? cursor)
                    (model-openai-schema-field? (car cursor)))
               (loop (cdr cursor)))
              (else #f)))))

    (define (model-openai-json-value datum)
      "Project canonical Scheme datums into `(consent json)' values."
      (cond
       ((boolean? datum) datum)
       ((number? datum) datum)
       ((string? datum) datum)
       ((symbol? datum) (symbol->string datum))
       ((vector? datum)
        (list->vector
         (map model-openai-json-value (vector->list datum))))
       ((model-openai-schema-fields? datum)
        (map
         (lambda (field)
           (cons
            (model-openai-name (car field) "schema field")
            (model-openai-json-value
             (model-openai-schema-entry-value field))))
         datum))
       ((pair? datum)
        (list->vector (map model-openai-json-value datum)))
       ((null? datum) '#())
       (else datum)))

    (define (model-openai-tool-json tool)
      "Return TOOL as an OpenAI-compatible JSON object."
      (let ((schema (model-openai-field-value tool 'schema #f)))
        (if (not (eq? (model-openai-record-head schema) 'openai-tool))
            (error "model-tool schema must be an openai-tool datum" tool))
        (model-openai-json-value (cdr schema))))

    (define (model-openai-tool-choice-json tool-choice)
      "Return TOOL-CHOICE projected into OpenAI-compatible JSON."
      (cond
       ((not tool-choice) #f)
       ((model-openai-model-tool? tool-choice)
        (let* ((name (model-openai-field-value tool-choice 'name #f))
               (name-text (model-openai-name-string name "tool name")))
          `((type . "function")
            (function . ((name . ,name-text))))))
       ((or (symbol? tool-choice) (string? tool-choice))
        (model-openai-name-string tool-choice "tool-choice"))
       (else
        (error "tool-choice must be a symbol, string, or model-tool"
               tool-choice))))

    (define (model-openai-request-json model-id prompt options)
      "Return JSON request payload for MODEL-ID, PROMPT, and OPTIONS."
      #((parameters
         (model-id (type string)
          (description "Provider-specific model identifier."))
         (prompt (type string)
          (description "User prompt text to send as one chat message."))
         (options (type list)
          (description
           ("Canonical model completion options, including optional"
             "`tools` and `tool-choice` fields."))))
        (returns (type string)
         (description
          ("OpenAI-compatible chat completion request JSON with any"
            "canonical model-tool datums lowered to JSON Schema"
            "objects.")))
        (effects port-io error))
      (let* ((tools
              (model-openai-field-value options 'tools #f))
             (tool-choice
              (model-openai-field-value-any options
                                            '(tool-choice tool_choice)
                                            #f))
             (payload
              `((model . ,model-id)
                (messages . #(((role . "user")
                               (content . ,prompt))))
                (stream . #f)))
             (with-tools
              (if tools
                  (append payload
                          (list
                           (cons 'tools
                                 (list->vector
                                  (map model-openai-tool-json tools)))))
                  payload))
             (tool-choice-json
              (model-openai-tool-choice-json tool-choice))
             (with-choice
              (if tool-choice-json
                  (append with-tools
                          (list (cons 'tool_choice tool-choice-json)))
                  with-tools))
             (port (open-output-string)))
        (json-model:json-write with-choice port)
        (get-output-string port)))

    (define (model-openai-json-object? value)
      "Return #t when VALUE is a decoded JSON object alist."
      (and (list? value)
           (let loop ((cursor value))
             (cond
              ((null? cursor) #t)
              ((and (pair? cursor)
                    (pair? (car cursor))
                    (symbol? (caar cursor)))
               (loop (cdr cursor)))
              (else #f)))))

    (define (model-openai-json-ref object key default)
      "Return KEY from decoded JSON OBJECT, or DEFAULT."
      (let ((entry (and (model-openai-json-object? object)
                        (assq key object))))
        (if entry (cdr entry) default)))

    (define (model-openai-json->datum value)
      "Return decoded JSON VALUE as a Scheme-readable datum."
      (cond
       ((json-model:json-null? value) #f)
       ((boolean? value) value)
       ((string? value) value)
       ((number? value) value)
       ((vector? value)
        (map model-openai-json->datum (vector->list value)))
       ((model-openai-json-object? value)
        (map
         (lambda (entry)
           (list (car entry) (model-openai-json->datum (cdr entry))))
         value))
       ((list? value)
        (map model-openai-json->datum value))
       (else value)))

    (define (model-openai-parse-tool-arguments arguments)
      "Decode OpenAI function ARGUMENTS into Scheme-readable fields."
      (let ((decoded
             (cond
              ((string? arguments)
               (if (= (string-length arguments) 0)
                   '()
                   (json-model:json-read (open-input-string arguments))))
              ((model-openai-json-object? arguments)
               arguments)
              (else
               (error "OpenAI tool arguments must be a JSON object"
                      arguments)))))
        (if (not (model-openai-json-object? decoded))
            (error "OpenAI tool arguments must be a JSON object" arguments))
        (model-openai-json->datum decoded)))

    (define (model-openai-parse-tool-call tool-call)
      "Decode one OpenAI-compatible TOOL-CALL object."
      (let* ((id (model-openai-json-ref tool-call 'id #f))
             (function (model-openai-json-ref tool-call 'function #f))
             (name (model-openai-json-ref function 'name #f))
             (arguments (model-openai-json-ref function 'arguments "{}")))
        (if (not (string? name))
            (error "OpenAI tool call did not contain a function name"))
        (append
         (list 'tool-call)
         (if (string? id)
             (list (list 'id id))
             '())
         (list
          (list 'name (string->symbol name))
          (list 'arguments
                (model-openai-parse-tool-arguments arguments))))))

    (define (model-openai-vector-map procedure vector)
      "Return a list of PROCEDURE results for VECTOR's elements."
      (let loop ((index 0) (result '()))
        (if (= index (vector-length vector))
            (reverse result)
            (loop (+ index 1)
                  (cons (procedure (vector-ref vector index)) result)))))

    (define (model-openai-parse-response body)
      "Return completion data from OpenAI-compatible response BODY."
      #((parameters
         (body (type string)
          (description "JSON response body from an OpenAI-compatible chat endpoint.")))
        (returns (type (or string model-message))
         (description
          ("Completion text or a canonical `model-message` datum when"
            "the response contains tool calls.")))
        (effects port-io error))
      (let* ((data (json-model:json-read (open-input-string body)))
             (choices (model-openai-json-ref data 'choices '#()))
             (choice
              (if (and (vector? choices) (> (vector-length choices) 0))
                  (vector-ref choices 0)
                  #f))
             (message (model-openai-json-ref choice 'message #f))
             (content (model-openai-json-ref message 'content #f))
             (tool-calls (model-openai-json-ref message 'tool_calls '#())))
        (cond
         ((and (vector? tool-calls) (> (vector-length tool-calls) 0))
          (list 'model-message
                (list 'text (if (string? content) content ""))
                (list 'tool-calls
                      (model-openai-vector-map
                       model-openai-parse-tool-call
                       tool-calls))))
         ((string? content) content)
         (else
          (error "OpenAI-compatible response did not contain text")))))

    (define (model-openai-option-integer options names default)
      "Return integer option from OPTIONS field NAMES, or DEFAULT."
      (let ((value (model-openai-field-value-any options names default)))
        (if (integer? value) value default)))

    (define (model-openai-curl-attempt url request-json timeout)
      "POST REQUEST-JSON to URL with curl and return `(STATUS STDOUT STDERR)'."
      (cli-host:cli-host-run
       "curl"
       (list "-sS"
             "--max-time" (number->string timeout)
             "-X" "POST"
             "-H" "Content-Type: application/json"
             "-d" request-json
             url)
       #f
       #f
       #f
       '()))

    (define (model-openai-retrieve url request-json options)
      "POST REQUEST-JSON to URL with bounded local retry OPTIONS."
      (let ((attempts
             (+ 1 (max 0
                       (model-openai-option-integer options
                                                    '(retry-count)
                                                    0))))
            (timeout
             (model-openai-option-integer
              options
              '(timeout-seconds)
              model-openai-default-timeout-seconds)))
        (let loop ((remaining attempts) (last-result #f))
          (if (= remaining 0)
              last-result
              (let ((result
                     (model-openai-curl-attempt url request-json timeout)))
                (if (= (car result) 0)
                    result
                    (loop (- remaining 1) result)))))))

    (define (model-openai-compatible-http-complete provider model role prompt options)
      "Complete PROMPT through local OpenAI-compatible PROVIDER and MODEL."
      #((parameters
         (provider (type list)
          (description "Normalized provider entry selected by the model router."))
         (model (type list)
          (description "Normalized model entry selected by the model router."))
         (role (type symbol)
          (description "Requested model role."))
         (prompt (type string)
          (description "User prompt text to send as one chat message."))
         (options (type list)
          (description "Model completion options, including tools.")))
        (returns (type (or string model-message))
         (description "Completion text or a canonical model-message datum."))
        (effects host-eval error))
      (if (not (eq? (model-openai-field-value provider 'kind #f) 'local))
          (error "remote model transport is not configured" role))
      (if (not (eq? (model-openai-field-value provider 'transport #f)
                    'openai-compatible-http))
          (error "unsupported local model transport"
                 (model-openai-field-value provider 'transport #f)))
      (let ((endpoint (model-openai-field-value provider 'endpoint #f)))
        (if (not (model-openai-local-endpoint? endpoint))
            (error "local model endpoint must use a loopback host"))
        (if (not (cli-host:cli-host-available?))
            (error "portable model transport requires a process host"))
        (let* ((model-id
                (model-openai-name-string
                 (model-openai-field-value model 'id #f)
                 "model id"))
               (request-json
                (model-openai-request-json model-id prompt options))
               (result
                (model-openai-retrieve
                 (model-openai-completion-url endpoint)
                 request-json
                 options))
               (status (car result))
               (stdout (cadr result))
               (stderr (model-openai-third result)))
          (if (not (= status 0))
              (error "local model transport failed" stderr))
          (model-openai-parse-response stdout))))))
