;;; Portable OpenAI-compatible JSON codec.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This internal library owns the stateless request and response codec used by
;;; the public OpenAI-compatible transport facade. It deliberately exposes no
;;; callback or transport orchestration surface, so compiled hosts can borrow
;;; compound arguments only for the duration of these three codec calls.

(define-library (agent models openai-codec)
  (export model-openai-codec-request-json-projected
          model-openai-codec-parse-response
          model-openai-codec-provider-error-projected)
  (import (scheme base)
          (only (consent identity-map)
                consent-identity-map-fast-backend?
                consent-identity-map-ref
                consent-identity-map-set!
                consent-make-identity-map)
          (prefix (stdlib generator) gen:)
          (prefix (stdlib json) json-model:))
  (begin
    ;; Replacement text used when prompt content is intentionally withheld.
    (define model-openai-local-only-replacement "[local-only]")
    ;; Maximum active schema depth on compatibility-only identity maps.
    (define model-openai-schema-nohash-depth-limit 64)

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

    (define (model-openai-schema-entry-value entry)
      "Return ENTRY's full schema value, preserving multi-field records."
      (let ((tail (cdr entry)))
        (cond
         ((null? tail) '())
         ((and (pair? tail) (null? (cdr tail))) (car tail))
         (else tail))))

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

    (define (model-openai-url-request-projection url)
      "Return URL's endpoint origin and request path in one vector."
      ;; A character stream keeps this linear on hosts whose variable-width
      ;; strings make repeated `string-ref' by numeric index non-constant.
      (let ((characters (string->list url)))
        (let scan ((cursor characters)
                   (scheme-found? #f)
                   (path #f))
          (cond
           ((null? cursor)
            (cond
             ((not scheme-found?) (vector #f "/"))
             ((not path) (vector url "/"))
             (else
              (let copy-origin ((rest characters) (reverse-origin '()))
                (if (eq? rest path)
                    (vector (list->string (reverse reverse-origin))
                            (list->string path))
                    (copy-origin
                     (cdr rest)
                     (cons (car rest) reverse-origin)))))))
           ((and (char=? (car cursor) #\:)
                 (pair? (cdr cursor))
                 (char=? (car (cdr cursor)) #\/)
                 (pair? (cdr (cdr cursor)))
                 (char=? (car (cdr (cdr cursor))) #\/))
            (scan (cdr (cdr (cdr cursor))) #t #f))
           (else
            (scan (cdr cursor)
                  scheme-found?
                  (if (and scheme-found?
                           (not path)
                           (char=? (car cursor) #\/))
                      cursor
                      path)))))))

    (define (model-openai-redaction-marker kind source replacement policy)
      "Return a Scheme-readable redaction marker."
      (list 'redaction
            (model-openai-field 'kind kind)
            (model-openai-field 'source source)
            (model-openai-field 'replacement replacement)
            (model-openai-field 'policy policy)))

    (define (model-openai-safe-request-datum context role url)
      "Return safe request metadata from validated transport CONTEXT."
      ;; CONTEXT slots are provider id, model id, kind, transport, timeout,
      ;; retry count, and transport-detail limit.
      (let* ((url-projection (model-openai-url-request-projection url))
             (origin (vector-ref url-projection 0))
             (path (vector-ref url-projection 1)))
        (list 'model-provider-request
              (model-openai-field 'role role)
              (model-openai-field 'provider (vector-ref context 0))
              (model-openai-field 'model (vector-ref context 1))
              (model-openai-field 'kind (vector-ref context 2))
              (model-openai-field 'transport (vector-ref context 3))
              (if origin
                  (model-openai-field 'endpoint-origin origin)
                  '(endpoint-origin #f))
              (model-openai-field 'request-path path)
              (model-openai-field
               'prompt
               (model-openai-redaction-marker
                'prompt
                'provider-request
                model-openai-local-only-replacement
                'local-only))
              (model-openai-field 'timeout-seconds (vector-ref context 4))
              (model-openai-field
               'max-transport-detail-bytes
               (vector-ref context 6))
              (model-openai-field 'retry-count (vector-ref context 5)))))

    (define (model-openai-provider-error-projection
             context role url reason summary-reason extra-fields)
      "Return the exact provider-error summary and structured datum."
      (let ((datum
             (append
              (list 'model-provider-error
                    (model-openai-field
                     'request
                     (model-openai-safe-request-datum context role url))
                    (model-openai-field 'status 'unavailable)
                    (model-openai-field 'provider (vector-ref context 0))
                    (model-openai-field 'model (vector-ref context 1))
                    (model-openai-field 'transport (vector-ref context 3))
                    (model-openai-field 'reason reason)
                    (model-openai-field
                     'retry
                     'bounded-local-transport-retry)
                    (model-openai-field 'task-state 'blocked))
              extra-fields)))
        (vector
         (string-append
          "local model transport failed for provider "
          (model-openai-name-string
           (vector-ref context 0)
           "provider id")
          " model "
          (model-openai-name-string
           (vector-ref context 1)
           "model id")
          " via "
          (model-openai-name-string
           (vector-ref context 3)
           "transport")
          ": "
          summary-reason)
         datum)))

    (define (model-openai-record-head datum)
      "Return DATUM's record head, or #f."
      (and (pair? datum) (symbol? (car datum)) (car datum)))

    (define (model-openai-model-tool? datum)
      "Return #t when DATUM is a canonical model-tool record."
      (eq? (model-openai-record-head datum) 'model-tool))

    (define (model-openai-proper-list? value)
      "Return #t when VALUE has a finite proper list spine."
      (let loop ((cursor value)
                 (slow value)
                 (advance-slow? #f))
        (cond
         ((null? cursor) #t)
         ((not (pair? cursor)) #f)
         (else
          (let ((next (cdr cursor))
                (next-slow (if advance-slow? (cdr slow) slow)))
            (and (not (and (pair? next) (eq? next next-slow)))
                 (loop next next-slow (not advance-slow?))))))))

    (define (model-openai-ancestor? value ancestors)
      "Return #t when VALUE occurs by identity in ANCESTORS."
      (let loop ((rest ancestors))
        (and (pair? rest)
             (or (eq? value (car rest))
                 (loop (cdr rest))))))

    (define (model-openai-schema-field? value)
      "Return #t when VALUE is a Scheme-readable schema field entry."
      (and (pair? value) (symbol? (car value))))

    (define (model-openai-schema-fields? value)
      "Return #t when proper VALUE contains only schema field entries."
      (and (pair? value)
           (let loop ((cursor value))
             (cond
              ((null? cursor) #t)
              ((model-openai-schema-field? (car cursor))
               (loop (cdr cursor)))
              (else #f)))))

    (define (model-openai-json-value datum)
      "Project canonical Scheme datums into `(stdlib json)' values."
      (let* ((fast? (consent-identity-map-fast-backend?))
             (active (and fast? (consent-make-identity-map)))
             (active-marker (list 'active))
             (absent (list 'absent))
             (bounded-active '())
             (bounded-depth 0)
             (root (vector #f)))
        (define (assign! target kind index value)
          "Assign VALUE into one pending projection TARGET."
          (if (eq? kind 'pair)
              (set-cdr! target value)
              (vector-set! target index value)))

        (define (enter! value)
          "Mark compound VALUE active or reject a cycle or unsafe depth."
          (if fast?
              (begin
                (if (eq? (consent-identity-map-ref active value absent)
                         active-marker)
                    (error "OpenAI tool schema must be acyclic" value))
                (consent-identity-map-set! active value active-marker))
              (begin
                (if (model-openai-ancestor? value bounded-active)
                    (error "OpenAI tool schema must be acyclic" value))
                (if (>= bounded-depth
                        model-openai-schema-nohash-depth-limit)
                    (error
                     "OpenAI tool schema depth requires fast identity maps"
                     value))
                (set! bounded-active (cons value bounded-active))
                (set! bounded-depth (+ bounded-depth 1)))))

        (define (leave! value)
          "Mark compound VALUE inactive after all of its children."
          (if fast?
              (consent-identity-map-set! active value #f)
              (begin
                (set! bounded-active (cdr bounded-active))
                (set! bounded-depth (- bounded-depth 1)))))

        (define (visit-task value target kind index)
          "Return a work item projecting VALUE into TARGET."
          (vector 'visit value target kind index))

        (define (leave-task value)
          "Return a work item leaving active compound VALUE."
          (vector 'leave value))

        (let loop ((tasks (list (visit-task datum root 'vector 0))))
          (if (null? tasks)
              (vector-ref root 0)
              (let* ((task (car tasks))
                     (rest (cdr tasks))
                     (kind (vector-ref task 0))
                     (value (vector-ref task 1)))
                (if (eq? kind 'leave)
                    (begin
                      (leave! value)
                      (loop rest))
                    (let ((target (vector-ref task 2))
                          (target-kind (vector-ref task 3))
                          (index (vector-ref task 4)))
                      (cond
                       ((boolean? value)
                        (assign! target target-kind index value)
                        (loop rest))
                       ((number? value)
                        (assign! target target-kind index value)
                        (loop rest))
                       ((string? value)
                        (assign! target target-kind index value)
                        (loop rest))
                       ((symbol? value)
                        (assign!
                         target target-kind index (symbol->string value))
                        (loop rest))
                       ((vector? value)
                        (enter! value)
                        (let* ((length (vector-length value))
                               (output (make-vector length #f))
                               (next
                                (cons (leave-task value) rest)))
                          (assign! target target-kind index output)
                          (let add ((child (- length 1))
                                    (pending next))
                            (if (< child 0)
                                (loop pending)
                                (add
                                 (- child 1)
                                 (cons
                                  (visit-task
                                   (vector-ref value child)
                                   output
                                   'vector
                                   child)
                                  pending))))))
                       ((pair? value)
                        (if (not (model-openai-proper-list? value))
                            (error
                             "OpenAI schema lists must be finite and proper"
                             value))
                        (enter! value)
                        (if (model-openai-schema-fields? value)
                            (let build ((cursor value)
                                        (entries '())
                                        (visits '()))
                              (if (null? cursor)
                                  (let ((output (reverse entries)))
                                    (assign!
                                     target target-kind index output)
                                    (loop
                                     (append
                                      (reverse visits)
                                      (cons (leave-task value) rest))))
                                  (let* ((field (car cursor))
                                         (entry (cons (car field) #f)))
                                    (build
                                     (cdr cursor)
                                     (cons entry entries)
                                     (cons
                                      (visit-task
                                       (model-openai-schema-entry-value field)
                                       entry
                                       'pair
                                       #f)
                                      visits)))))
                            (let* ((length (length value))
                                   (output (make-vector length #f)))
                              (assign! target target-kind index output)
                              (let build ((cursor value)
                                          (child 0)
                                          (visits '()))
                                (if (null? cursor)
                                    (loop
                                     (append
                                      (reverse visits)
                                      (cons (leave-task value) rest)))
                                    (build
                                     (cdr cursor)
                                     (+ child 1)
                                     (cons
                                      (visit-task
                                       (car cursor)
                                       output
                                       'vector
                                       child)
                                      visits)))))))
                       ((null? value)
                        (assign! target target-kind index '#())
                        (loop rest))
                       (else
                        (assign! target target-kind index value)
                        (loop rest))))))))))

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

    (define (model-openai-request-json-projected
             model-id prompt options-projection)
      "Return request JSON using a validated OPTIONS-PROJECTION."
      (let* ((tools (vector-ref options-projection 0))
             (tool-choice (vector-ref options-projection 1))
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
                  (begin
                    (if (not (model-openai-proper-list? tools))
                        (error
                         "OpenAI tools must form a finite proper list"
                         tools))
                    (append payload
                            (list
                             (cons
                              'tools
                              (gen:generator->vector
                               (gen:gmap
                                model-openai-tool-json
                                (gen:list->generator tools)))))))
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
      ;; Validate the full object even after finding KEY.  Invalid or cyclic
      ;; spines still return DEFAULT, and duplicate keys retain the first value.
      (let loop ((cursor object)
                 (slow object)
                 (advance-slow? #f)
                 (found? #f)
                 (value default))
        (cond
         ((null? cursor) value)
         ((not (pair? cursor)) default)
         ((or (not (pair? (car cursor)))
              (not (symbol? (caar cursor))))
          default)
         (else
          (let* ((entry (car cursor))
                 (next (cdr cursor))
                 (next-slow (if advance-slow? (cdr slow) slow))
                 (match? (and (not found?) (eq? (car entry) key)))
                 (next-value (if match? (cdr entry) value)))
            (if (and (pair? next) (eq? next next-slow))
                default
                (loop next
                      next-slow
                      (not advance-slow?)
                      (or found? match?)
                      next-value)))))))

    (define (model-openai-json-pair-projection
             object first-key first-default second-key second-default)
      "Validate OBJECT once and return two first-match JSON fields."
      (let loop ((cursor object)
                 (slow object)
                 (advance-slow? #f)
                 (first-found? #f)
                 (first-value first-default)
                 (second-found? #f)
                 (second-value second-default))
        (cond
         ((null? cursor) (vector first-value second-value))
         ((not (pair? cursor)) (vector first-default second-default))
         ((or (not (pair? (car cursor)))
              (not (symbol? (caar cursor))))
          (vector first-default second-default))
         (else
          (let* ((entry (car cursor))
                 (key (car entry))
                 (next (cdr cursor))
                 (next-slow (if advance-slow? (cdr slow) slow))
                 (first-match?
                  (and (not first-found?) (eq? key first-key)))
                 (second-match?
                  (and (not second-found?) (eq? key second-key))))
            (if (and (pair? next) (eq? next next-slow))
                (vector first-default second-default)
                (loop next
                      next-slow
                      (not advance-slow?)
                      (or first-found? first-match?)
                      (if first-match? (cdr entry) first-value)
                      (or second-found? second-match?)
                      (if second-match? (cdr entry) second-value))))))))

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
      (let* ((tool-call-fields
              (model-openai-json-pair-projection
               tool-call 'id #f 'function #f))
             (id (vector-ref tool-call-fields 0))
             (function (vector-ref tool-call-fields 1))
             (function-fields
              (model-openai-json-pair-projection
               function 'name #f 'arguments "{}"))
             (name (vector-ref function-fields 0))
             (arguments (vector-ref function-fields 1)))
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

    (define (model-openai-codec-request-json-projected
             model-id prompt options-projection)
      "Return request JSON using the facade's OPTIONS-PROJECTION."
      #((parameters
         (model-id (type string)
          (description "Provider-specific model identifier."))
         (prompt (type string)
          (description "User prompt text to send as one chat message."))
         (options-projection (type vector)
          (description
           ("Validated completion options whose first two slots are"
             "the optional tools and tool-choice values."))))
        (returns (type string)
         (description
          ("OpenAI-compatible chat completion request JSON with any"
            "canonical model-tool datums lowered to JSON Schema"
            "objects.")))
        (effects port-io error))
      (model-openai-request-json-projected
       model-id
       prompt
       options-projection))

    (define (model-openai-codec-parse-response body)
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
      (let* ((data (json-model:json-read (open-input-string body)))
             (choices (model-openai-json-ref data 'choices '#()))
             (choice
              (if (and (vector? choices) (> (vector-length choices) 0))
                  (vector-ref choices 0)
                  #f))
             (message (model-openai-json-ref choice 'message #f))
             (message-fields
              (model-openai-json-pair-projection
               message 'content #f 'tool_calls '#()))
             (content (vector-ref message-fields 0))
             (tool-calls (vector-ref message-fields 1)))
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

    (define (model-openai-codec-provider-error-projected
             context role url reason summary-reason extra-fields)
      "Return a safe provider-error summary and datum projection."
      #((parameters
         (context (type vector)
          (description "Validated provider/model transport context."))
         (role (type symbol)
          (description "Requested model role."))
         (url (type string)
          (description "Validated local completion URL."))
         (reason (type string)
          (description "Already redacted and bounded structured reason."))
         (summary-reason (type string)
          (description "Already redacted and bounded summary reason."))
         (extra-fields (type list)
          (description "Already safe phase-specific error fields.")))
        (returns (type vector)
         (description
          "Two slots containing the exact summary and provider-error datum."))
        (effects allocation error))
      (model-openai-provider-error-projection
       context
       role
       url
       reason
       summary-reason
       extra-fields))

))
