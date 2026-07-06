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
          model-openai-compatible-http-completion-result
          model-openai-compatible-http-complete)
  (import (scheme base)
          (scheme write)
          (prefix (agent redaction) redaction-model:)
          (prefix (cli process-host) cli-host:)
          (prefix (stdlib generator) gen:)
          (prefix (stdlib json) json-model:))
  (begin
    ;; Default request timeout for local OpenAI-compatible HTTP transports.
    (define model-openai-default-timeout-seconds 30)
    ;; Maximum process diagnostic text copied into model transport conditions.
    (define model-openai-transport-detail-limit 240)
    ;; Hard upper bound for per-call transport diagnostic excerpts.
    (define model-openai-transport-detail-limit-maximum 4096)
    ;; Replacement text used when prompt content is intentionally withheld.
    (define model-openai-local-only-replacement "[local-only]")
    ;; Curl metadata marker appended after the response body.
    (define model-openai-curl-meta-marker "__CONSENT_OPENAI_META__")

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

    (define (model-openai-field name value)
      "Return a Scheme-readable field named NAME with VALUE."
      (list name value))

    (define (model-openai-object->string value)
      "Return VALUE as a Scheme-readable diagnostic string."
      (let ((port (open-output-string)))
        (write value port)
        (get-output-string port)))

    (define (model-openai-normalize-transport-detail-limit value)
      "Return VALUE as an effective transport detail limit."
      (if (and (integer? value) (> value 0))
          (min value model-openai-transport-detail-limit-maximum)
          model-openai-transport-detail-limit))

    (define (model-openai-transport-detail-limit-for-options options)
      "Return OPTIONS's effective transport detail limit."
      (model-openai-normalize-transport-detail-limit
       (model-openai-option-integer
        options
        '(max-transport-detail-bytes max_transport_detail_bytes)
        model-openai-transport-detail-limit)))

    (define (model-openai-bounded-detail detail limit)
      "Return DETAIL as non-empty bounded transport diagnostic text."
      (let* ((text
              (cond
               ((and (string? detail) (> (string-length detail) 0))
                detail)
               ((string? detail)
                "no process detail")
               (else
                (model-openai-object->string detail))))
             (effective-limit
              (model-openai-normalize-transport-detail-limit limit)))
        (let ((redacted (redaction-model:redact text 'model-diagnostics)))
          (if (> (string-length redacted) effective-limit)
              (string-append
               (substring redacted 0 (- effective-limit 3))
               "...")
              redacted))))

    (define (model-openai-condition-detail condition limit)
      "Return host CONDITION as bounded transport diagnostic text."
      (model-openai-bounded-detail
       (cond
        ((error-object? condition)
         (error-object-message condition))
        ((string? condition)
         condition)
        (else
         condition))
       limit))

    (define (model-openai-string-contains? haystack needle)
      "Return #t when HAYSTACK contains NEEDLE."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((start 0))
          (cond
           ((> (+ start needle-length) haystack-length) #f)
           ((string=? (substring haystack start (+ start needle-length))
                      needle)
            #t)
           (else (loop (+ start 1)))))))

    (define (model-openai-last-index-of haystack needle)
      "Return the last index of NEEDLE in HAYSTACK, or #f."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((start (- haystack-length needle-length)))
          (cond
           ((< start 0) #f)
           ((string=? (substring haystack start (+ start needle-length))
                      needle)
            start)
           (else
            (loop (- start 1)))))))

    (define (model-openai-redaction-marker kind source replacement policy)
      "Return a Scheme-readable redaction marker."
      (list 'redaction
            (model-openai-field 'kind kind)
            (model-openai-field 'source source)
            (model-openai-field 'replacement replacement)
            (model-openai-field 'policy policy)))

    (define (model-openai-endpoint-origin url)
      "Return URL's origin prefix, or #f."
      (let ((scheme-index (model-openai-last-index-of url "://")))
        (if (not scheme-index)
            #f
            (let* ((authority-start (+ scheme-index 3))
                   (path-index
                    (let loop ((index authority-start))
                      (cond
                       ((>= index (string-length url)) #f)
                       ((char=? (string-ref url index) #\/) index)
                       (else (loop (+ index 1)))))))
              (if path-index
                  (substring url 0 path-index)
                  url)))))

    (define (model-openai-request-path url)
      "Return URL's request path, or `/'."
      (let ((scheme-index (model-openai-last-index-of url "://")))
        (if (not scheme-index)
            "/"
            (let* ((authority-start (+ scheme-index 3))
                   (path-index
                    (let loop ((index authority-start))
                      (cond
                       ((>= index (string-length url)) #f)
                       ((char=? (string-ref url index) #\/) index)
                       (else (loop (+ index 1)))))))
              (if path-index
                  (substring url path-index (string-length url))
                  "/")))))

    (define (model-openai-safe-request-datum provider model role url options)
      "Return safe request metadata for transport diagnostics."
      (list 'model-provider-request
            (model-openai-field 'role role)
            (model-openai-field
             'provider
             (model-openai-field-value provider 'id 'unknown-provider))
            (model-openai-field
             'model
             (model-openai-field-value model 'id 'unknown-model))
            (model-openai-field
             'kind
             (model-openai-field-value provider 'kind 'local))
            (model-openai-field
             'transport
             (model-openai-field-value provider
                                       'transport
                                       'openai-compatible-http))
            (if (model-openai-endpoint-origin url)
                (model-openai-field
                 'endpoint-origin
                 (model-openai-endpoint-origin url))
                '(endpoint-origin #f))
            (model-openai-field 'request-path
                                (model-openai-request-path url))
            (model-openai-field
             'prompt
             (model-openai-redaction-marker
              'prompt
              'provider-request
              model-openai-local-only-replacement
              'local-only))
            (model-openai-field
             'timeout-seconds
             (model-openai-option-integer
              options
              '(timeout-seconds)
              model-openai-default-timeout-seconds))
            (model-openai-field
             'max-transport-detail-bytes
             (model-openai-transport-detail-limit-for-options options))
            (model-openai-field
             'retry-count
             (max 0
                  (model-openai-option-integer options '(retry-count) 0)))))

    (define (model-openai-provider-error-datum
             provider model role url options reason extra-fields)
      "Return a structured transport failure record."
      (append
       (list 'model-provider-error
             (model-openai-field
              'request
              (model-openai-safe-request-datum
               provider model role url options))
             (model-openai-field 'status 'unavailable)
             (model-openai-field
              'provider
              (model-openai-field-value provider 'id 'unknown-provider))
             (model-openai-field
              'model
              (model-openai-field-value model 'id 'unknown-model))
             (model-openai-field
              'transport
              (model-openai-field-value provider
                                        'transport
                                        'openai-compatible-http))
             (model-openai-field 'reason reason)
             (model-openai-field 'retry 'bounded-local-transport-retry)
             (model-openai-field 'task-state 'blocked))
       extra-fields))

    (define (model-openai-provider-error-summary datum)
      "Return DATUM as one concise human-facing transport error string."
      (let* ((request (model-openai-field-value datum 'request #f))
             (limit
              (model-openai-normalize-transport-detail-limit
               (model-openai-field-value
                request
                'max-transport-detail-bytes
                model-openai-transport-detail-limit))))
        (string-append
         "local model transport failed for provider "
         (model-openai-name-string
          (model-openai-field-value datum 'provider 'unknown-provider)
          "provider id")
         " model "
         (model-openai-name-string
          (model-openai-field-value datum 'model 'unknown-model)
          "model id")
         " via "
         (model-openai-name-string
          (model-openai-field-value datum
                                    'transport
                                    'openai-compatible-http)
          "transport")
         ": "
         (model-openai-bounded-detail
          (model-openai-field-value datum 'reason "transport failed")
          limit))))

    (define (model-openai-raise-provider-error datum)
      "Raise DATUM as a structured local transport failure."
      (error (model-openai-provider-error-summary datum) datum))

    (define (model-openai-curl-status-detail status timeout stderr)
      "Return a concise detail string for curl STATUS and STDERR."
      (let ((stderr-text
             (model-openai-bounded-detail
              stderr
              model-openai-transport-detail-limit)))
        (cond
         ((and (= status 28)
               (> timeout 0))
          (string-append
           "request timed out after "
           (number->string timeout)
           "s"))
         ((= status 7)
          "curl exited 7: connection refused")
         ((= status 6)
          "curl exited 6: dns failure")
         ((and (string? stderr-text)
               (> (string-length stderr-text) 0)
               (not (string=? stderr-text "no process detail")))
          (string-append
           "curl exited "
           (number->string status)
           ": "
           stderr-text))
         (else
          (string-append
           "curl exited "
           (number->string status))))))

    (define (model-openai-process-error-datum
             provider model role url options status stderr elapsed-ms)
      "Return a structured process failure record."
      (let ((detail
             (model-openai-bounded-detail
              (model-openai-curl-status-detail
               status
               (model-openai-option-integer
                options
                '(timeout-seconds)
                model-openai-default-timeout-seconds)
               stderr)
              (model-openai-transport-detail-limit-for-options options))))
        (model-openai-provider-error-datum
         provider
         model
         role
         url
         options
         detail
         (append
          (list (model-openai-field 'phase 'process)
                (model-openai-field
                 'process
                 (list 'process-failure
                       (model-openai-field 'exit-status status)
                       (model-openai-field 'detail detail))))
          (if elapsed-ms
              (list (model-openai-field 'elapsed-ms elapsed-ms))
              '())))))

    (define (model-openai-http-error-datum
             provider model role url options status body elapsed-ms)
      "Return a structured HTTP failure record."
      (let ((excerpt
             (model-openai-bounded-detail
              body
              (model-openai-transport-detail-limit-for-options options))))
        (model-openai-provider-error-datum
         provider
         model
         role
         url
         options
         (string-append
          "HTTP "
          (number->string status)
          (if (> (string-length excerpt) 0)
              (string-append ": " excerpt)
              ""))
         (append
          (list (model-openai-field 'phase 'http)
                (model-openai-field
                 'http
                 (append
                  (list 'http-failure
                        (model-openai-field 'status status))
                  (if (> (string-length excerpt) 0)
                      (list (model-openai-field 'body-excerpt excerpt))
                      '()))))
          (if elapsed-ms
              (list (model-openai-field 'elapsed-ms elapsed-ms))
              '())))))

    (define (model-openai-decode-error-datum
             provider model role url options detail body elapsed-ms status)
      "Return a structured decode failure record."
      (let* ((limit
              (model-openai-transport-detail-limit-for-options options))
             (excerpt (model-openai-bounded-detail body limit))
             (detail-text (model-openai-bounded-detail detail limit)))
        (model-openai-provider-error-datum
         provider
         model
         role
         url
         options
         (string-append "response decode failed: " detail-text)
         (append
          (list
           (model-openai-field 'phase 'decode)
           (model-openai-field
            'decode
            (append
             (list 'decode-failure
                   (model-openai-field 'detail detail-text))
             (if status
                 (list (model-openai-field 'http-status status))
                 '())
             (if (> (string-length excerpt) 0)
                 (list (model-openai-field 'body-excerpt excerpt))
                 '()))))
          (if elapsed-ms
              (list (model-openai-field 'elapsed-ms elapsed-ms))
              '())))))

    (define (model-openai-record-head datum)
      "Return DATUM's record head, or #f."
      (and (pair? datum) (symbol? (car datum)) (car datum)))

    (define (model-openai-provider-error? datum)
      "Return #t when DATUM is a structured model-provider-error record."
      (eq? (model-openai-record-head datum) 'model-provider-error))

    (define (model-openai-condition-provider-error condition)
      "Return CONDITION's structured provider-error irritant, or #f."
      (and
       (error-object? condition)
       (let loop ((irritants (error-object-irritants condition)))
         (cond
          ((null? irritants) #f)
          ((model-openai-provider-error? (car irritants)) (car irritants))
          (else (loop (cdr irritants)))))))

    (define (model-openai-condition-message condition)
      "Return CONDITION's concise message."
      (if (error-object? condition)
          (error-object-message condition)
          (model-openai-object->string condition)))

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
      "Project canonical Scheme datums into `(stdlib json)' values."
      (cond
       ((boolean? datum) datum)
       ((number? datum) datum)
       ((string? datum) datum)
       ((symbol? datum) (symbol->string datum))
       ((vector? datum)
        (gen:generator->vector
         (gen:gmap model-openai-json-value (gen:vector->generator datum))))
       ((model-openai-schema-fields? datum)
        (map
         (lambda (field)
           (cons
            (model-openai-name (car field) "schema field")
            (model-openai-json-value
             (model-openai-schema-entry-value field))))
         datum))
       ((pair? datum)
        (gen:generator->vector
         (gen:gmap model-openai-json-value (gen:list->generator datum))))
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
          (list (cons 'type "function")
                (cons 'function
                      (list (cons 'name name-text))))))
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
              (list
               (cons 'model model-id)
               (cons 'messages
                     (vector
                      (list (cons 'role "user")
                            (cons 'content prompt))))
               (cons 'stream #f)))
             (with-tools
              (if tools
                  (append payload
                          (list
                           (cons 'tools
                                 (gen:generator->vector
                                  (gen:gmap model-openai-tool-json
                                            (gen:list->generator tools))))))
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
        (gen:generator-map->list
         model-openai-json->datum
         (gen:vector->generator value)))
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
      (gen:generator-map->list procedure (gen:vector->generator vector)))

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

    (define (model-openai-split-curl-output stdout)
      "Return `(BODY HTTP-STATUS ELAPSED-MS)' parsed from curl STDOUT."
      (let ((marker-index
             (model-openai-last-index-of stdout model-openai-curl-meta-marker)))
        (if (not marker-index)
            (list stdout 0 #f)
            (let* ((body (substring stdout 0 marker-index))
                   (meta (substring stdout
                                    (+ marker-index
                                       (string-length
                                        model-openai-curl-meta-marker))
                                    (string-length stdout)))
                   (space-index
                    (let loop ((index 0))
                      (cond
                       ((>= index (string-length meta)) #f)
                       ((char=? (string-ref meta index) #\space) index)
                       (else (loop (+ index 1))))))
                   (status-text
                    (if space-index
                        (substring meta 0 space-index)
                        meta))
                   (time-text
                    (if space-index
                        (substring meta (+ space-index 1) (string-length meta))
                        ""))
                   (status
                    (let ((value (string->number status-text)))
                      (if (number? value) value 0)))
                   (elapsed-ms
                    (let ((value (string->number time-text)))
                      (if (number? value)
                          (exact
                           (round (* value 1000)))
                          #f))))
              (list body status elapsed-ms)))))

    (define (model-openai-curl-attempt url request-json timeout)
      "POST REQUEST-JSON to URL with curl and return `(STATUS STDOUT STDERR)'."
      (cli-host:cli-host-run
       "curl"
       (list "-sS"
             "--max-time" (number->string timeout)
             "--write-out"
             (string-append
              model-openai-curl-meta-marker
              "%{http_code} %{time_total}")
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
                (guard (condition
                        (else
                         (model-openai-raise-provider-error
                         (model-openai-process-error-datum
                           provider
                           model
                           role
                           (model-openai-completion-url endpoint)
                           options
                           -1
                           (model-openai-condition-detail
                            condition
                            (model-openai-transport-detail-limit-for-options
                             options))
                           #f))))
                  (model-openai-retrieve
                   (model-openai-completion-url endpoint)
                   request-json
                   options)))
               (status (car result))
               (stdout (cadr result))
               (stderr (model-openai-third result))
               (parsed (model-openai-split-curl-output stdout))
               (body (car parsed))
               (http-status (cadr parsed))
               (elapsed-ms (model-openai-third parsed))
               (url (model-openai-completion-url endpoint)))
          (if (not (= status 0))
              (model-openai-raise-provider-error
               (model-openai-process-error-datum
                provider model role url options status stderr elapsed-ms)))
          (if (>= http-status 400)
              (model-openai-raise-provider-error
               (model-openai-http-error-datum
                provider model role url options http-status body elapsed-ms)))
          (guard (condition
                  (else
                   (model-openai-raise-provider-error
                    (model-openai-decode-error-datum
                     provider
                     model
                     role
                     url
                     options
                     (model-openai-condition-detail
                      condition
                      (model-openai-transport-detail-limit-for-options
                       options))
                     body
                     elapsed-ms
                     http-status))))
            (model-openai-parse-response body)))))

    (define (model-openai-compatible-http-completion-result
             provider model role prompt options)
      "Return a result datum for an OpenAI-compatible completion attempt."
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
        (returns (type list)
         (description
          ("A model-completion-result datum with either an ok value or a"
            "structured model-provider-error.")))
        (effects host-eval allocation))
      (guard (condition
              (else
               (let ((datum
                      (model-openai-condition-provider-error condition)))
                 (if datum
                     (list 'model-completion-result
                           (list 'status 'error)
                           (list 'message
                                 (model-openai-provider-error-summary datum))
                           (list 'error datum))
                     (list 'model-completion-result
                           (list 'status 'error)
                           (list 'message
                                 (model-openai-condition-message condition)))))))
        (list 'model-completion-result
              (list 'status 'ok)
              (list 'value
                    (model-openai-compatible-http-complete
                     provider model role prompt options)))))))
