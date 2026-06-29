;;; Public Consent Scheme model provider and tool protocol facade.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral model protocol surface. Provider state,
;;; routing side effects, and live transport remain behind `(agent models
;;; primitive)', while tool specification derivation is portable Scheme over
;;; reflection metadata.  The public `(agent models)' import therefore has one
;;; protocol implementation across Emacs and Scheme hosts.

(define-library (agent models)
  (export model-provider-register!
          model-providers
          model-route
          model-tool-spec
          model-complete
          model-provider-diagnostics)
  (import (scheme base)
          (agent reflect)
          (rename
           (agent models primitive)
           (primitive-model-provider-register! model-provider-register!)
           (primitive-model-providers model-providers)
           (primitive-model-route model-route)
           (primitive-model-complete model-complete)
           (primitive-model-provider-diagnostics model-provider-diagnostics)))
  (begin
    (define (model-field-values datum)
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

    (define (model-field-value datum name default)
      "Return field NAME from DATUM, or DEFAULT when absent."
      (let loop ((fields (model-field-values datum)))
        (cond
         ((null? fields) default)
         ((eq? (car (car fields)) name)
          (if (null? (cdr (car fields)))
              default
              (car (cdr (car fields)))))
         (else (loop (cdr fields))))))

    (define (model-name value description)
      "Return VALUE as a provider/model symbol or raise DESCRIPTION."
      (cond
       ((symbol? value) value)
       ((string? value) (string->symbol value))
       (else (error (string-append description " must be a symbol or string")
                    value))))

    (define (model-name-string value description)
      "Return VALUE as a provider/model name string."
      (symbol->string (model-name value description)))

    (define (model-descriptor-field descriptor name default)
      "Return descriptor field NAME from DESCRIPTOR, or DEFAULT."
      (model-field-value descriptor name default))

    (define (model-json-type-name type)
      "Return a JSON-schema type name for metadata TYPE, or #f."
      (let ((name (and (symbol? type) (symbol->string type))))
        (if (not name)
            #f
            (cond
             ((or (string=? name "string")
                  (string=? name "symbol")
                  (string=? name "character"))
              "string")
             ((or (string=? name "boolean") (string=? name "bool"))
              "boolean")
             ((or (string=? name "exact-integer")
                  (string=? name "integer")
                  (string=? name "nonnegative-integer"))
              "integer")
             ((or (string=? name "number")
                  (string=? name "real")
                  (string=? name "rational")
                  (string=? name "complex"))
              "number")
             ((or (string=? name "list") (string=? name "vector"))
              "array")
             ((or (string=? name "pair")
                  (string=? name "record")
                  (string=? name "procedure"))
              "object")
             (else #f)))))

    (define (model-schema-for-type type . maybe-description)
      "Return a Scheme-readable JSON-schema subset for TYPE."
      (let* ((description
              (if (null? maybe-description) #f (car maybe-description)))
             (schema
              (cond
               ((and (pair? type) (eq? (car type) 'or))
                (list (list 'anyOf
                            (map model-schema-for-type (cdr type)))))
               ((and (pair? type)
                     (or (eq? (car type) 'list-of)
                         (eq? (car type) 'vector-of)))
                (list (list 'type "array")
                      (list 'items
                            (model-schema-for-type (car (cdr type))))))
               (else
                (let ((json-type (model-json-type-name type)))
                  (if json-type
                      (list (list 'type json-type))
                      '()))))))
        (cond
         ((and description (not (string=? description "")))
          (append schema (list (list 'description description))))
         ((null? schema)
          '((description "Any Scheme-readable value.")))
         (else schema))))

    (define (model-example-for-type type)
      "Return an in-context example value for metadata TYPE."
      (let ((name (and (symbol? type) (symbol->string type))))
        (cond
         ((or (and name
                   (or (string=? name "string")
                       (string=? name "symbol")
                       (string=? name "character")))
              (and (pair? type) (eq? (car type) 'or)))
          "<string>")
         ((and name (string=? name "boolean")) #f)
         ((and name
               (or (string=? name "exact-integer")
                   (string=? name "integer")
                   (string=? name "nonnegative-integer")
                   (string=? name "number")
                   (string=? name "real")
                   (string=? name "rational")
                   (string=? name "complex")))
          0)
         ((and name
               (or (string=? name "list") (string=? name "vector")))
          '())
         (else "<value>"))))

    (define (model-parameter-schema parameter)
      "Return a `(name schema)' property entry for PARAMETER metadata."
      (let* ((name (model-name (car parameter) "tool parameter"))
             (descriptor (cdr parameter))
             (type (model-descriptor-field descriptor 'type 'any))
             (description
              (model-descriptor-field descriptor 'description "")))
        (list name (model-schema-for-type type description))))

    (define (model-parameter-example parameter)
      "Return a `(name example)' entry for PARAMETER metadata."
      (let* ((name (model-name (car parameter) "tool parameter"))
             (descriptor (cdr parameter))
             (type (model-descriptor-field descriptor 'type 'any)))
        (list name (model-example-for-type type))))

    (define (model-tool-schema name description parameters)
      "Return OpenAI-compatible tool schema datum for NAME."
      (list 'openai-tool
            (list 'type 'function)
            (list 'function
                  (list 'name name)
                  (list 'description description)
                  (list 'parameters
                        (list (list 'type "object")
                              (list 'properties
                                    (map model-parameter-schema
                                         parameters))
                              (list 'required
                                    (map (lambda (parameter)
                                           (model-name-string
                                            (car parameter)
                                            "tool parameter"))
                                         parameters)))))))

    (define (model-tool-gate effects)
      "Return a capability gate summary derived from EFFECTS."
      (let ((pure (and (pair? effects)
                       (null? (cdr effects))
                       (eq? (car effects) 'pure))))
        (list 'tool-gate
              (list 'decision
                    (if pure
                        'pure-under-budget
                        'capability-request))
              (list 'effects effects))))

    (define (model-tool-spec subject)
      "Return a canonical model tool spec for documented SUBJECT."
      #((parameters
         (subject (type (or symbol procedure))
          (description "Documented procedure binding or procedure value.")))
        (returns (type model-tool)
         (description
          ("A canonical `model-tool' datum with OpenAI-compatible schema,"
            "example call, return metadata, and capability gate.")))
        (effects state-read error))
      (let* ((name-symbol (model-name subject "tool subject"))
             (name (symbol->string name-symbol))
             (documentation (documentation subject)))
        (if (not documentation)
            (error "model-tool-spec expected a documented procedure"
                   subject))
        (let* ((fields (model-field-value documentation 'fields '()))
               (description
                (model-field-value fields 'documentation ""))
               (parameters
                (model-field-value fields 'parameters '()))
               (returns
                (model-field-value fields 'returns '((type any))))
               (effects
                (model-field-value fields 'effects '(pure))))
          (list 'model-tool
                (list 'name name-symbol)
                (list 'description description)
                (list 'parameters parameters)
                (list 'returns returns)
                (list 'effects effects)
                (list 'schema
                      (model-tool-schema name description parameters))
                (list 'example
                      (list 'tool-call
                            (list 'name name-symbol)
                            (list 'arguments
                                  (map model-parameter-example
                                       parameters))))
                (list 'gate (model-tool-gate effects))))))))
