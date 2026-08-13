;;; Portable OpenAI-compatible model transport projection.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral parts of the local OpenAI-compatible
;;; transport: canonical model/tool datums to JSON, loopback endpoint
;;; validation,
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
          (prefix (agent models openai-codec) openai-codec:)
          (prefix (agent redaction) redaction-model:)
          (prefix (cli process-host) cli-host:))
  (begin
    ;; Default request timeout for local OpenAI-compatible HTTP transports.
    (define model-openai-default-timeout-seconds 30)
    ;; Maximum process diagnostic text copied into model transport conditions.
    (define model-openai-transport-detail-limit 240)
    ;; Hard upper bound for per-call transport diagnostic excerpts.
    (define model-openai-transport-detail-limit-maximum 4096)
    ;; Curl metadata marker appended after the response body.
    (define model-openai-curl-meta-marker "__CONSENT_OPENAI_META__")
    ;; Unique marker distinguishing an absent field from one whose value
    ;; happens to equal the caller's default.
    (define model-openai-missing-field (list 'missing-field))
    (define (model-openai-field-name=? left right)
      "Return #t when LEFT and RIGHT name the same field."
      (cond
       ((and (symbol? left) (symbol? right))
        (symbol=? left right))
       (else
        (eq? left right))))

    (define (model-openai-field-entry-value entry default)
      "Return ENTRY's value for either list-field or alist-field shapes."
      (let ((tail (cdr entry)))
        (cond
         ((null? tail) default)
         ((pair? tail) (car tail))
         (else tail))))

    (define (model-openai-third list)
      "Return the third element of LIST without relying on optional caddr."
      (car (cdr (cdr list))))

    (define (model-openai-field-value datum name default)
      "Return field NAME from DATUM, or DEFAULT when absent."
      (if (not (pair? datum))
          default
          (let ((fields
                 (if (and (symbol? (car datum))
                          (not (and (pair? (car datum))
                                    (symbol? (caar datum)))))
                     (cdr datum)
                     datum)))
            ;; Keep walking after a match to validate the full proper spine,
            ;; while retaining the first matching field without a copied list.
            (let loop ((cursor fields)
                       (slow fields)
                       (advance-slow? #f)
                       (found? #f)
                       (value default))
              (cond
               ((null? cursor) value)
               ((not (pair? cursor))
                (error "model fields must form a proper list"
                       'invalid-field-spine))
               (else
                (let* ((entry (car cursor))
                       (next (cdr cursor))
                       (next-slow (if advance-slow? (cdr slow) slow))
                       (match?
                        (and (not found?)
                             (pair? entry)
                             (symbol? (car entry))
                             (model-openai-field-name=? (car entry) name)))
                       (next-value
                        (if match?
                            (model-openai-field-entry-value entry default)
                            value)))
                  (if (and (pair? next) (eq? next next-slow))
                      (error "model fields must form a proper list"
                             'invalid-field-spine)
                      (loop next
                            next-slow
                            (not advance-slow?)
                            (or found? match?)
                            next-value)))))))))

    (define (model-openai-matching-field-name name names)
      "Return NAME's canonical member of NAMES, or #f."
      (cond
       ((null? names) #f)
       ((model-openai-field-name=? name (car names)) (car names))
       (else
        (model-openai-matching-field-name name (cdr names)))))

    (define (model-openai-remove-field-name name names)
      "Return NAMES without its member equal to NAME."
      (cond
       ((null? names) '())
       ((model-openai-field-name=? name (car names)) (cdr names))
       (else
        (cons (car names)
              (model-openai-remove-field-name name (cdr names))))))

    (define (model-openai-field-index datum names)
      "Validate DATUM once and index the first fields named by NAMES."
      (let ((fields
             (if (not (pair? datum))
                 '()
                 (if (and (symbol? (car datum))
                          (not (and (pair? (car datum))
                                    (symbol? (caar datum)))))
                     (cdr datum)
                     datum))))
        (let loop ((cursor fields)
                   (slow fields)
                   (advance-slow? #f)
                   (remaining names)
                   (index '()))
          (cond
           ((null? cursor) index)
           ((not (pair? cursor))
            (error "model fields must form a proper list"
                   'invalid-field-spine))
           (else
            (let* ((entry (car cursor))
                   (name
                    (and (pair? entry)
                         (symbol? (car entry))
                         (model-openai-matching-field-name
                          (car entry)
                          remaining)))
                   (next (cdr cursor))
                   (next-slow (if advance-slow? (cdr slow) slow)))
              (if (and (pair? next) (eq? next next-slow))
                  (error "model fields must form a proper list"
                         'invalid-field-spine)
                  (loop
                   next
                   next-slow
                   (not advance-slow?)
                   (if name
                       (model-openai-remove-field-name name remaining)
                       remaining)
                   (if name
                       (cons
                        (cons name
                              (model-openai-field-entry-value
                               entry
                               model-openai-missing-field))
                        index)
                       index)))))))))

    (define (model-openai-index-value index name default)
      "Return NAME from field INDEX, or DEFAULT when absent or valueless."
      (let ((entry (assq name index)))
        (if (or (not entry)
                (eq? (cdr entry) model-openai-missing-field))
            default
            (cdr entry))))

    (define (model-openai-provider-projection datum)
      "Validate DATUM once and return its provider fields as a vector."
      (let ((index
             (model-openai-field-index
              datum
              '(id kind transport endpoint))))
        (vector (model-openai-index-value index 'id 'unknown-provider)
                (model-openai-index-value index 'kind #f)
                (model-openai-index-value index 'transport #f)
                (model-openai-index-value index 'endpoint #f))))

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

    (define (model-openai-exact-integer value)
      "Return VALUE when it is an exact integer, or #f otherwise."
      (and (integer? value) (exact? value) value))

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

    (define (model-openai-options-projection options)
      "Validate OPTIONS once and return fields needed by one completion."
      (let* ((index
              (model-openai-field-index
               options
               '(tools
                 tool-choice
                 tool_choice
                 timeout-seconds
                 retry-count
                 max-transport-detail-bytes
                 max_transport_detail_bytes)))
             (choice-primary
              (model-openai-index-value
               index 'tool-choice model-openai-missing-field))
             (choice
              (if (eq? choice-primary model-openai-missing-field)
                  (model-openai-index-value index 'tool_choice #f)
                  choice-primary))
             (timeout
              (model-openai-exact-integer
               (model-openai-index-value index 'timeout-seconds #f)))
             (retry
              (model-openai-exact-integer
               (model-openai-index-value index 'retry-count #f)))
             (detail-primary
              (model-openai-index-value
               index
               'max-transport-detail-bytes
               model-openai-missing-field))
             (detail
              (if (eq? detail-primary model-openai-missing-field)
                  (model-openai-index-value
                   index
                   'max_transport_detail_bytes
                   model-openai-transport-detail-limit)
                  detail-primary))
             (detail-integer (model-openai-exact-integer detail)))
        (vector
         (model-openai-index-value index 'tools #f)
         choice
         (if timeout timeout model-openai-default-timeout-seconds)
         (max 0 (if retry retry 0))
         (model-openai-normalize-transport-detail-limit
          (if detail-integer
              detail-integer
              model-openai-transport-detail-limit)))))

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

    (define (model-openai-last-index-of haystack needle)
      "Return the last index of NEEDLE in HAYSTACK, or #f."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((start (- haystack-length needle-length)))
          (cond
           ((< start 0) #f)
           ((let match ((offset 0))
              (cond
               ((= offset needle-length) #t)
               ((char=? (string-ref haystack (+ start offset))
                        (string-ref needle offset))
                (match (+ offset 1)))
               (else #f)))
            start)
           (else
            (loop (- start 1)))))))

    (define (model-openai-provider-error-projection
             context role url reason extra-fields)
      "Return a structured error and its concise summary."
      (openai-codec:model-openai-codec-provider-error-projected
       context
       role
       url
       reason
       (model-openai-bounded-detail reason (vector-ref context 6))
       extra-fields))

    (define (model-openai-raise-provider-error projection)
      "Raise a structured local transport failure PROJECTION."
      (error (vector-ref projection 0) (vector-ref projection 1)))

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

    (define (model-openai-process-error-projection
             context role url status stderr elapsed-ms)
      "Return a structured process failure record."
      (let ((detail
             (model-openai-bounded-detail
              (model-openai-curl-status-detail
               status
               (vector-ref context 4)
               stderr)
              (vector-ref context 6))))
        (model-openai-provider-error-projection
         context
         role
         url
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

    (define (model-openai-http-error-projection
             context role url status body elapsed-ms)
      "Return a structured HTTP failure record."
      (let ((excerpt
             (model-openai-bounded-detail
              body
              (vector-ref context 6))))
        (model-openai-provider-error-projection
         context
         role
         url
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

    (define (model-openai-decode-error-projection
             context role url detail body elapsed-ms status)
      "Return a structured decode failure record."
      (let* ((limit (vector-ref context 6))
             (excerpt (model-openai-bounded-detail body limit))
             (detail-text (model-openai-bounded-detail detail limit)))
        (model-openai-provider-error-projection
         context
         role
         url
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


    (define (model-openai-request-json-projected
             model-id prompt options-projection)
      "Return request JSON using a validated OPTIONS-PROJECTION."
      (openai-codec:model-openai-codec-request-json-projected
       model-id prompt options-projection))

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
      (model-openai-request-json-projected
       model-id prompt (model-openai-options-projection options)))

    (define (model-openai-parse-response body)
      "Return completion data from OpenAI-compatible response BODY."
      #((parameters
         (body (type string)
          (description
           "JSON response body from an OpenAI-compatible chat endpoint.")))
        (returns (type (or string model-message))
         (description
          ("Completion text or a canonical `model-message` datum when"
            "the response contains tool calls.")))
        (effects port-io error))
      (openai-codec:model-openai-codec-parse-response body))

    (define (model-openai-split-curl-output stdout)
      "Return `(BODY HTTP-STATUS ELAPSED-MS)' parsed from curl STDOUT."
      (let ((marker-index
             (model-openai-last-index-of stdout
               model-openai-curl-meta-marker)))
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
      "POST REQUEST-JSON to URL with curl and return `(STATUS STDOUT STDERR)'.\
"
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

    (define (model-openai-retrieve
             url request-json options-projection . maybe-attempt)
      "POST REQUEST-JSON using validated OPTIONS-PROJECTION."
      (let ((attempts (+ 1 (vector-ref options-projection 3)))
            (timeout (vector-ref options-projection 2))
            (attempt
             (if (null? maybe-attempt)
                 model-openai-curl-attempt
                 (car maybe-attempt))))
        (let loop ((remaining attempts) (last-result #f))
          (if (= remaining 0)
              last-result
              (let ((result
                     (attempt url request-json timeout)))
                (if (= (car result) 0)
                    result
                    (loop (- remaining 1) result)))))))

    (define (model-openai-compatible-http-complete
             provider model role prompt options . maybe-attempt)
      "Complete PROMPT through local OpenAI-compatible PROVIDER and MODEL."
      #((parameters
         (provider (type list)
          (description
            "Normalized provider entry selected by the model router."))
         (model (type list)
          (description "Normalized model entry selected by the model router."))
         (role (type symbol)
          (description "Requested model role."))
         (prompt (type string)
          (description "User prompt text to send as one chat message."))
         (options (type list)
          (description "Model completion options, including tools."))
         (maybe-attempt (type list)
          (description
           ("Optional singleton list containing a host retrieval"
             "procedure for adapters and deterministic tests."))))
        (returns (type (or string model-message))
         (description "Completion text or a canonical model-message datum."))
        (effects host-eval error))
      (let* ((provider-fields
              (model-openai-provider-projection provider))
             (provider-id (vector-ref provider-fields 0))
             (kind (vector-ref provider-fields 1))
             (transport (vector-ref provider-fields 2))
             (endpoint (vector-ref provider-fields 3)))
        (if (not (model-openai-field-name=? kind 'local))
            (error "remote model transport is not configured" role))
        (if (not (model-openai-field-name=?
                  transport
                  'openai-compatible-http))
            (error "unsupported local model transport" transport))
        (if (not (model-openai-local-endpoint? endpoint))
            (error "local model endpoint must use a loopback host"))
        (if (and (null? maybe-attempt)
                 (not (cli-host:cli-host-available?)))
            (error "portable model transport requires a process host"))
        (let* ((model-id-value
                (model-openai-field-value model 'id #f))
               (model-id
                (model-openai-name-string
                 model-id-value
                 "model id"))
               (options-projection
                (model-openai-options-projection options))
               (context
                (vector provider-id
                        model-id-value
                        kind
                        transport
                        (vector-ref options-projection 2)
                        (vector-ref options-projection 3)
                        (vector-ref options-projection 4)))
               (url (model-openai-completion-url endpoint))
               (request-json
                (model-openai-request-json-projected
                 model-id prompt options-projection))
               (result
                (guard (condition
                        (else
                         (model-openai-raise-provider-error
                          (model-openai-process-error-projection
                           context
                           role
                           url
                           -1
                           (model-openai-condition-detail
                            condition
                            (vector-ref context 6))
                           #f))))
                  (apply model-openai-retrieve
                         (append
                          (list url
                                request-json
                                options-projection)
                          maybe-attempt))))
               (status (car result))
               (stdout (cadr result))
               (stderr (model-openai-third result))
               (parsed (model-openai-split-curl-output stdout))
               (body (car parsed))
               (http-status (cadr parsed))
               (elapsed-ms (model-openai-third parsed)))
          (if (not (= status 0))
              (model-openai-raise-provider-error
               (model-openai-process-error-projection
                context role url status stderr elapsed-ms)))
          (if (>= http-status 400)
              (model-openai-raise-provider-error
               (model-openai-http-error-projection
                context role url http-status body elapsed-ms)))
          (guard (condition
                  (else
                   (model-openai-raise-provider-error
                    (model-openai-decode-error-projection
                     context
                     role
                     url
                     (model-openai-condition-detail
                      condition
                      (vector-ref context 6))
                     body
                     elapsed-ms
                     http-status))))
            (model-openai-parse-response body)))))

    (define (model-openai-compatible-http-completion-result
             provider model role prompt options . maybe-attempt)
      "Return a result datum for an OpenAI-compatible completion attempt."
      #((parameters
         (provider (type list)
          (description
            "Normalized provider entry selected by the model router."))
         (model (type list)
          (description "Normalized model entry selected by the model router."))
         (role (type symbol)
          (description "Requested model role."))
         (prompt (type string)
          (description "User prompt text to send as one chat message."))
         (options (type list)
          (description "Model completion options, including tools."))
         (maybe-attempt (type list)
          (description
           ("Optional singleton list containing a host retrieval"
             "procedure for adapters and deterministic tests."))))
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
                                 (model-openai-condition-message condition))
                           (list 'error datum))
                     (list 'model-completion-result
                           (list 'status 'error)
                           (list 'message
                                 (model-openai-condition-message
                              condition)))))))
        (list 'model-completion-result
              (list 'status 'ok)
              (list 'value
                    (apply model-openai-compatible-http-complete
                           (append (list provider model role prompt options)
                                   maybe-attempt))))))))
