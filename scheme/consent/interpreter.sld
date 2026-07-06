;;; Portable Consent Scheme interpreter backend.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns evaluation, procedure application, primitive
;;; implementations, trampoline execution, and result-producing eval entry
;;; points for the portable bootstrap.

(define-library (consent interpreter)
  (export consent-eval
          consent-eval-source
          consent-eval-string
          consent-expand
          consent-expand-source
          consent-eval-result
          consent-eval-source-result
          consent-make-interaction-context
          consent-interaction-context?
          consent-interaction-context-session-id
          consent-interaction-program-output
          consent-interaction-eval-form
          consent-interaction-program-input-port
          consent-interaction-seed-program-input!
          consent-interaction-program-input-remainder
          consent-repl-session-manager
          consent-repl-seed-initial-session!
          consent-session-manager-current-context
          consent-program-input-from-string
          consent-program-input-from-bytevector
          consent-make-empty-environment
          consent-make-base-environment
          consent-base-primitive-names
          consent-base-primitive-specs
          consent-base-prelude-binding-names
          consent-base-prelude-binding-specs
          consent-base-binding-specs
          consent-standard-source-library-specs
          consent-stdlib-source-library-specs
          consent-primitive-manifest-binding-specs
          consent-result->external
          consent-value->external
          consent-unspecified
          consent-unspecified?
          consent-procedure?
          consent-primitive-procedure?)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme inexact)
          (rename (scheme time)
                  (current-second host-current-second)
                  (current-jiffy host-current-jiffy)
                  (jiffies-per-second host-jiffies-per-second))
          (rename (scheme process-context)
                  (command-line host-command-line)
                  (get-environment-variable host-get-environment-variable)
                  (get-environment-variables host-get-environment-variables))
          (scheme write)
          (consent reader)
          (consent runtime)
          (consent result)
          (consent base)
          (consent library)
          (prefix (agent approval) approval-model:)
          (prefix (agent context) context-model:)
          (prefix (agent helper) helper-model:)
          (prefix (agent job) job-model:)
          (prefix (agent memory) memory-model:)
          (prefix (agent plan) plan-model:)
          (prefix (agent models openai) model-openai:)
          (prefix (agent redaction) redaction-model:)
          (prefix (agent session) session-model:)
          (consent macro))
  (begin
    ;; Process-local portable approvals used by `(agent approval)' primitives.
    (define interpreter-approval-store
      (approval-model:consent-make-approval-store))

    ;; Process-local portable jobs used by `(agent job)' primitives.
    (define interpreter-job-store
      (job-model:consent-make-job-store))

    ;; Process-local portable memory used by `(agent memory)' primitives.
    (define interpreter-memory-store
      (memory-model:consent-make-memory-store))

    ;; Process-local portable helpers used by `(agent helper)' primitives.
    (define interpreter-helper-store
      (helper-model:consent-make-helper-store))

    ;; Process-local portable plans used by `(agent plan)' primitives.
    (define interpreter-plan-store
      (plan-model:consent-make-plan-store))

    ;; Process-local live session manager backing the `(agent session)' verbs
    ;; and the multi-environment REPL loop.  Its interaction-context factory is
    ;; injected at module load (see the install below) so this store can build
    ;; per-session sandbox environments without a `session -> interpreter'
    ;; import cycle.
    (define interpreter-session-manager
      (session-model:consent-make-session-manager))

    (define (default-session-context-factory id scope options)
      "Build a fresh sandbox interaction context for session ID.
The default factory gives each session its own base environment with no
shared stdin; the multi-session REPL replaces it (see
`consent-repl-seed-initial-session!') with one that shares a single stdin
cursor across sessions."
      (consent-make-interaction-context (cons (cons 'session-id id) options)))

    (define (active-session-manager)
      "Return the live session manager, ensuring a context factory is installed."
      (if (not (session-model:session-manager-context-factory
                interpreter-session-manager))
          (session-model:session-manager-set-context-factory!
           interpreter-session-manager default-session-context-factory))
      interpreter-session-manager)

    (define (portable-library-argument value context)
      "Normalize interpreted VALUE for direct compiled portable-library calls."
      "Interpreter primitives that call shared portable libraries directly"
      "must cross the same bridge as imported native-library shims, so those"
      "libraries still see ordinary `(scheme base)' numbers and other host"
      "scalars instead of reader/runtime representation details."
      (consent-native-argument-value value context))

    (define (portable-library-call procedure context . arguments)
      "Apply PROCEDURE to ARGUMENTS normalized for a compiled portable library."
      (apply procedure
             (map (lambda (argument)
                    (portable-library-argument argument context))
                  arguments)))

    ;; Process-local portable model provider profiles.
    (define interpreter-model-providers '())

    ;; Process-local ids for portable host-backed port capability handles.
    (define next-port-capability-handle-number 0)

    (define (dynamic-wind-prefix-before frame stack)
      "Return the stack prefix before FRAME in dynamic-wind order."
      (let loop ((cursor stack) (prefix '()))
        (cond
         ((null? cursor) (reverse prefix))
         ((eq? (car cursor) frame) (reverse prefix))
         (else (loop (cdr cursor) (cons (car cursor) prefix))))))

    (define (dynamic-wind-common-frame current target)
      "Find the outermost shared frame between dynamic-wind stacks."
      (let loop ((current-outer (reverse current))
                 (target-outer (reverse target))
                 (common #f))
        (if (and (pair? current-outer)
                 (pair? target-outer)
                 (eq? (car current-outer) (car target-outer)))
            (loop (cdr current-outer)
                  (cdr target-outer)
                  (car current-outer))
            common)))

    (define (call-ignoring-values procedure context description)
      "Call PROCEDURE for dynamic control effects and discard its values."
      (expect-procedure procedure description)
      (apply-procedure procedure '() context #f)
      consent-unspecified)

    (define (call-ignoring-values/k
             procedure context description continuation)
      "Continuation-aware variant of call-ignoring-values."
      (expect-procedure procedure description)
      (apply-procedure
       procedure
       '()
       context
       #t
       (lambda (value)
         (continue continuation consent-unspecified))))

    (define (switch-dynamic-winds! target context)
      "Continuation jumps call each after thunk being exited and each before"
      "thunk being entered, updating the active stack as those callbacks run."
      (let* ((current (context-dynamic-winds context))
             (common (dynamic-wind-common-frame current target))
             (exiting (if common
                          (dynamic-wind-prefix-before common current)
                          current))
             (entering (if common
                           (dynamic-wind-prefix-before common target)
                           target)))
        (for-each
         (lambda (frame)
           (if (and (pair? (context-dynamic-winds context))
                    (eq? (car (context-dynamic-winds context)) frame))
               (set-context-dynamic-winds!
                context
                (cdr (context-dynamic-winds context))))
           (call-ignoring-values
            (dynamic-wind-frame-after frame)
            context
            "dynamic-wind after"))
         exiting)
        (for-each
         (lambda (frame)
           (call-ignoring-values
            (dynamic-wind-frame-before frame)
            context
            "dynamic-wind before")
           (set-context-dynamic-winds!
            context
            (cons frame (context-dynamic-winds context))))
         (reverse entering))
        (set-context-dynamic-winds! context (append target '()))))

    (define (self-evaluating? expression)
      "Report whether EXPRESSION evaluates to itself in core evaluation."
      (or (boolean? expression)
          (consent-number? expression)
          (char? expression)
          (string? expression)
          (vector? expression)
          (bytevector? expression)))

    (define (true-value? value)
      "Implement Scheme truthiness, where only #f is false."
      (not (eq? value #f)))

    (define (parse-record-definition form)
      "Parse define-record-type syntax into constructor, predicate, and field specs."
      (let ((parts (proper-list-elements form "define-record-type form")))
        (if (< (length parts) 4)
            (eval-error
             "define-record-type requires name, constructor, predicate, and fields"
             form))
        (let* ((type-name
                (expect-identifier-key (second parts) "record type name"))
               (constructor-spec
                (proper-list-elements (third parts) "record constructor"))
               (constructor-name
                (expect-identifier-key
                 (car constructor-spec) "record constructor name"))
               (constructor-fields
                (map (lambda (field)
                       (expect-identifier-key
                        field
                        "record constructor field"))
                     (cdr constructor-spec)))
               (predicate-name
                (expect-identifier-key
                 (fourth parts)
                 "record predicate name")))
          (let loop ((field-specs (cdr (cdr (cdr (cdr parts)))))
                     (fields '())
                     (accessors '())
                     (mutators '()))
            (if (null? field-specs)
                (let ((field-names (reverse fields))
                      (accessor-specs (reverse accessors))
                      (mutator-specs (reverse mutators)))
                  (ensure-distinct-names field-names "record fields")
                  (ensure-distinct-names
                   (append (map car accessor-specs)
                           (map car mutator-specs))
                   "record accessors and mutators")
                  (let constructor-loop ((rest constructor-fields))
                    (if (not (null? rest))
                        (begin
                          (if (not (memq (car rest) field-names))
                              (eval-error
                               "record constructor references unknown field"
                               (car rest)))
                          (constructor-loop (cdr rest)))))
                  (list (list 'type-name type-name)
                        (list 'constructor-name constructor-name)
                        (list 'constructor-fields constructor-fields)
                        (list 'predicate-name predicate-name)
                        (list 'fields field-names)
                        (list 'accessors accessor-specs)
                        (list 'mutators mutator-specs)))
                (let ((field-parts
                       (proper-list-elements
                        (car field-specs)
                        "record field")))
                  (if (not (or (= (length field-parts) 2)
                               (= (length field-parts) 3)))
                      (eval-error
                       "record field requires name, accessor, and optional mutator"
                       (car field-specs)))
                  (let ((field-name
                         (expect-identifier-key
                          (car field-parts)
                          "record field name"))
                        (accessor-name
                         (expect-identifier-key
                          (second field-parts)
                          "record accessor name"))
                        (mutator-name
                         (if (= (length field-parts) 3)
                             (expect-identifier-key
                              (third field-parts)
                              "record mutator name")
                             #f)))
                    (loop (cdr field-specs)
                          (cons field-name fields)
                          (cons (cons accessor-name field-name) accessors)
                          (if mutator-name
                              (cons (cons mutator-name field-name) mutators)
                              mutators)))))))))

    (define (record-definition-bound-names form)
      "Return every binding introduced by a define-record-type form."
      (let ((spec (parse-record-definition form)))
        (append
         (list (second (assq 'type-name spec))
               (second (assq 'constructor-name spec))
               (second (assq 'predicate-name spec)))
         (map car (second (assq 'accessors spec)))
         (map car (second (assq 'mutators spec))))))

    (define (record-field-index record-type field)
      "Return FIELD's zero-based index in RECORD-TYPE, or raise on mismatch."
      (let loop ((rest (consent-record-type-fields record-type))
                 (index 0))
        (cond
         ((null? rest)
          (eval-error "record type does not contain field" field))
         ((eq? (car rest) field) index)
         (else (loop (cdr rest) (+ index 1))))))

    (define (expect-record-of-type value record-type description)
      "Validate record of type input and raise an evaluator error on mismatch."
      (if (not (and (consent-record? value)
                    (eq? (consent-record-type value) record-type)))
          (eval-error
           (string-append (symbol->string description) " expected record")
           value))
      value)

    (define (define-or-set-record-binding! environment name value)
      "Install or update a record-related binding while preserving import protection."
      (let ((cell (frame-cell environment name)))
        (if cell
            (begin
              (if (environment-cell-imported? environment cell)
                  (eval-error "cannot redefine imported binding" name))
              (set-cell-value! cell value))
            (environment-define! environment name value))))

    (define (eval-record-definition form environment context)
      "Install a record type plus generated constructor, predicate, and field procedures."
      (let* ((spec (parse-record-definition form))
             (type-name (second (assq 'type-name spec)))
             (fields (second (assq 'fields spec)))
             (record-type (consent-make-record-type type-name fields))
             (constructor-fields
              (second (assq 'constructor-fields spec)))
             (constructor-name (second (assq 'constructor-name spec)))
             (predicate-name (second (assq 'predicate-name spec)))
             (constructor
              (make-primitive-procedure
               constructor-name
               (lambda (arguments context)
                 (let ((values (make-vector
                                (length fields)
                                consent-unspecified)))
                   (let loop ((rest-fields constructor-fields)
                              (rest-arguments arguments))
                     (if (null? rest-fields)
                         ;; Charge the record header plus its field slots; the
                         ;; field values were charged where they were allocated.
                         (charge-value-allocation!
                          (consent-make-record record-type values)
                          (+ 1 (vector-length values))
                          context)
                         (begin
                           (vector-set!
                            values
                            (record-field-index record-type (car rest-fields))
                            (car rest-arguments))
                           (loop (cdr rest-fields)
                                 (cdr rest-arguments)))))))
               (length constructor-fields)
               (length constructor-fields)))
             (predicate
              (make-primitive-procedure
               predicate-name
               (lambda (arguments context)
                 (and (consent-record? (car arguments))
                      (eq? (consent-record-type (car arguments))
                           record-type)))
               1
               1)))
        (define-or-set-record-binding! environment type-name record-type)
        (define-or-set-record-binding! environment constructor-name constructor)
        (define-or-set-record-binding! environment predicate-name predicate)
        (for-each
         (lambda (accessor)
           (let* ((name (car accessor))
                  (field (cdr accessor))
                  (index (record-field-index record-type field)))
             (define-or-set-record-binding!
              environment
              name
              (make-primitive-procedure
               name
               (lambda (arguments context)
                 (vector-ref
                  (consent-record-fields
                   (expect-record-of-type
                    (car arguments)
                    record-type
                    name))
                  index))
               1
               1))))
         (second (assq 'accessors spec)))
        (for-each
         (lambda (mutator)
           (let* ((name (car mutator))
                  (field (cdr mutator))
                  (index (record-field-index record-type field)))
             (define-or-set-record-binding!
              environment
              name
              (make-primitive-procedure
               name
               (lambda (arguments context)
                 (vector-set!
                  (consent-record-fields
                   (expect-record-of-type
                    (car arguments)
                    record-type
                    name))
                  index
                  (second arguments))
                 consent-unspecified)
               2
               2))))
         (second (assq 'mutators spec)))
        consent-unspecified))

    (define (split-body body)
      "Split a body into leading internal definitions and remaining expressions."
      (let loop ((cursor body) (definitions '()))
        (cond
         ((and (pair? cursor) (body-definition-form? (car cursor)))
          (loop (cdr cursor) (cons (car cursor) definitions)))
         ((null? cursor)
          (eval-error "body must contain at least one expression" body))
         (else
          (cons (reverse definitions) cursor)))))

    (define (body-documentation body . maybe-formals)
      "Return documentation metadata from BODY and optional FORMALS, or #f."
      (apply documentation-metadata-from-body
             body
             body-definition-form?
             maybe-formals))

    (define (body-documentation-result body context . maybe-formals)
      "Return `(metadata . body)' for BODY using CONTEXT retention settings."
      (apply documentation-body-result
             body
             body-definition-form?
             (context-docstring-retention context)
             maybe-formals))

    (define (prepare-body-environment body environment context)
      "Allocate and initialize an internal-definition environment for BODY."
      (let* ((split (split-body body))
             (definitions (car split))
             (expressions (cdr split)))
        (if (null? definitions)
            (cons environment expressions)
            (let ((body-environment
                   (consent-make-empty-environment environment)))
              (let install-loop ((rest definitions) (parsed '()))
                (if (null? rest)
                    (let initialize-loop ((remaining (reverse parsed)))
                      (if (null? remaining)
                          (cons body-environment expressions)
                          (begin
                            (cond
                             ((eq? (car (car remaining)) 'define)
                              (environment-set!
                               body-environment
                               (car (cdr (car remaining)))
                               (eval-expression
                                (cdr (cdr (car remaining)))
                                body-environment
                                context
                                #f)))
                             ((eq? (car (car remaining)) 'define-values)
                              (let* ((parsed (cdr (car remaining)))
                                     (value
                                      (eval-expression
                                       (cdr parsed)
                                       body-environment
                                       context
                                       #f)))
                                (define-values-bind
                                 (car parsed)
                                 (values-list value)
                                 body-environment
                                 context
                                 "define-values")))
                             ((eq? (car (car remaining)) 'record)
                              (eval-record-definition
                               (cdr (car remaining))
                               body-environment
                               context)))
                            (initialize-loop (cdr remaining)))))
                    (let ((definition (car rest)))
                      (cond
                       ((definition-form? definition)
                        (let ((parsed-definition
                               (parse-definition definition)))
                          (if (frame-cell body-environment
                                          (car parsed-definition))
                              (eval-error "duplicate internal definition"
                                          (car parsed-definition)))
                          ;; Allocate every internal-definition cell before any
                          ;; initializer runs so recursive references have a
                          ;; location, even if its value is still undefined.
                          (environment-define!
                           body-environment
                           (car parsed-definition)
                           undefined)
                          (install-loop
                           (cdr rest)
                           (cons (cons 'define parsed-definition)
                                 parsed))))
                       ((define-values-form? definition)
                        (let ((parsed-definition
                               (parse-define-values definition)))
                          (let names-loop
                              ((names (formals-names (car parsed-definition))))
                            (if (not (null? names))
                                (begin
                                  (if (frame-cell
                                       body-environment
                                       (car names))
                                      (eval-error
                                       "duplicate internal definition"
                                       (car names)))
                                  (environment-define!
                                   body-environment
                                   (car names)
                                   undefined)
                                  (names-loop (cdr names)))))
                          (install-loop
                           (cdr rest)
                           (cons (cons 'define-values parsed-definition)
                                 parsed))))
                       ((record-definition-form? definition)
                        (let names-loop
                            ((names (record-definition-bound-names
                                     definition)))
                          (if (not (null? names))
                              (begin
                                (if (frame-cell body-environment (car names))
                                    (eval-error
                                     "duplicate internal definition"
                                     (car names)))
                                (environment-define!
                                 body-environment
                                 (car names)
                                 undefined)
                                (names-loop (cdr names)))))
                        (install-loop
                         (cdr rest)
                         (cons (cons 'record definition) parsed)))))))))))

    (define (eval-definition form environment context . maybe-continuation)
      "Evaluate a define form and install the resulting single value."
      (let* ((parsed (parse-definition form))
             (name (car parsed))
             (cell (frame-cell environment name))
             (direct-call? (null? maybe-continuation))
             (continuation
              (if direct-call?
                  identity-continuation
                  (car maybe-continuation)))
             (state
              (eval-expression
               (cdr parsed)
               environment
               context
               #f
               (lambda (raw-value)
                 (let ((value
                        (single-value
                         raw-value
                         "define initializer")))
                   (if cell
                       (begin
                         (if (current-environment-imported? environment name)
                             (eval-error
                              "cannot redefine imported binding"
                              name))
                         (set-cell-value! cell value))
                       (environment-define! environment name value))
                   (continue continuation consent-unspecified))))))
        (if direct-call?
            (drain-state state context)
            state)))

    (define (define-values-bind
             formals values environment context description)
      "Bind multiple values to define-values formals in ENVIRONMENT."
      (let* ((required (formals-required formals))
             (rest (formals-rest formals))
             (required-count (length required))
             (value-count (length values)))
        (cond
         ((and (not rest) (not (= value-count required-count)))
          (eval-error
           (string-append description " received wrong number of values")
           required-count
           value-count))
         ((and rest (< value-count required-count))
          (eval-error
           (string-append description " received too few values")
           required-count
           value-count)))
        (let loop ((names required) (remaining-values values))
          (if (null? names)
              (if rest
                  (environment-define-or-set!
                   environment
                   rest
                   remaining-values))
              (begin
                (environment-define-or-set!
                 environment
                 (car names)
                 (car remaining-values))
                (loop (cdr names) (cdr remaining-values)))))))

    (define (eval-define-values
             form environment context . maybe-continuation)
      "Evaluate a define-values form and install all returned values."
      (let* ((parsed (parse-define-values form))
             (direct-call? (null? maybe-continuation))
             (continuation
              (if direct-call?
                  identity-continuation
                  (car maybe-continuation)))
             (state
              (eval-expression
               (cdr parsed)
               environment
               context
               #f
               (lambda (raw-value)
                 (define-values-bind
                  (car parsed)
                  (values-list raw-value)
                  environment
                  context
                  "define-values")
                 (continue continuation consent-unspecified)))))
        (if direct-call?
            (drain-state state context)
            state)))

    (define (bind-formals formals arguments closure-environment context)
      "Create a call environment and bind FORMALS to ARGUMENTS."
      (let ((environment
             (consent-make-empty-environment closure-environment)))
        (bind-formals-in-environment
         formals arguments environment context "procedure")
        environment))

    (define (bind-formals-in-environment
             formals arguments environment context description)
      "Bind FORMALS to ARGUMENTS inside an existing call environment."
      (let* ((required (formals-required formals))
             (rest (formals-rest formals))
             (required-count (length required))
             (argument-count (length arguments)))
        (cond
         ((and (not rest) (not (= argument-count required-count)))
          (eval-error
                      (string-append description
                                     " received wrong number of values")
                      required-count
                      argument-count))
         ((and rest (< argument-count required-count))
          (eval-error
                      (string-append description " received too few values")
                      required-count
                      argument-count)))
        (let loop ((names required) (values arguments))
          (if (null? names)
              (begin
                (if rest
                    (begin
                      (environment-define! environment rest values)
                      ;; The rest list is freshly consed by the apply machinery;
                      ;; charge its pairs as the allocation they are.
                      (note-value-allocation! context (length values))))
                environment)
              (begin
                (environment-define! environment
                                     (car names)
                                     (car values))
                (loop (cdr names) (cdr values)))))))

    (define (arity-match? primitive count)
      "Report whether COUNT satisfies PRIMITIVE's arity bounds."
      (and (>= count (primitive-procedure-minimum-arity primitive))
           (let ((maximum (primitive-procedure-maximum-arity primitive)))
             (or (not maximum) (<= count maximum)))))

    ;; Unique marker distinguishing a caught host condition from a value.
    (define host-condition-tag (list 'host-condition))

    (define (host-condition-budget? condition)
      "Report whether CONDITION carries a Consent budget diagnostic."
      "Budget enforcement fails closed, so budget conditions stay host-level"
      "and uncatchable by interpreted exception handlers."
      (and (error-object? condition)
           (let ((message (error-object-message condition))
                 (prefix "consent budget error: "))
             (and (string? message)
                  (>= (string-length message) (string-length prefix))
                  (string=? (substring message 0 (string-length prefix))
                            prefix)))))

    (define (host-condition->consent-condition condition)
      "Return CONDITION as a value interpreted exception handlers can inspect."
      "Host error objects become interpreter error objects so guard clauses"
      "can use error-object? and the message and irritant accessors; any"
      "other raised host value crosses unchanged."
      (if (error-object? condition)
          (make-consent-error-object
           (error-object-message condition)
           (error-object-irritants condition))
          condition))

    (define (native-primitive-name? name)
      "Report whether NAME marks a natively bound library procedure shim."
      (let ((text (symbol->string name)))
        (and (>= (string-length text) 7)
             (string=? (substring text 0 7) "native:"))))

    (define (apply-host-primitive/k
             function arguments context continuation native?)
      "Invoke host primitive FUNCTION and deliver its budgeted result."
      "A host condition escaping FUNCTION (a primitive argument error, a"
      "native module raise) becomes an interpreted raise that walks the"
      "context's exception handlers, so interpreted guard catches primitive"
      "errors the way it catches interpreted raises. Budget conditions from"
      "the interpreter's own primitives enforce this context's budgets and"
      "propagate unchanged so enforcement stays uncatchable; a budget"
      "condition surfacing from a NATIVE? call is a nested evaluation's"
      "error result (a consent-eval-source running its own budgeted context)"
      "and converts like any other condition. When the handler stack empties"
      "before the condition surfaces it also propagates unchanged, preserving"
      "top-level diagnostics."
      (let ((outcome
             (guard (condition
                     ((and (pair? (context-exception-handlers context))
                           (or native?
                               (not (host-condition-budget? condition))))
                      (cons host-condition-tag condition)))
               (cons 'value (function arguments context)))))
        (if (eq? (car outcome) host-condition-tag)
            (primitive-raise/k
             (list (host-condition->consent-condition (cdr outcome)))
             context
             continuation)
            ;; Primitive results are no longer walked: allocating primitives
            ;; charge their own nodes, and an accessor result is a substructure
            ;; of an already-budgeted argument, so it creates nothing to charge.
            (continue continuation (cdr outcome)))))

    (define (apply-procedure procedure arguments context tail? . maybe-continuation)
      "All callable values pass through this boundary so primitive callbacks,"
      "parameter procedures, compound procedures, and continuations share"
      "arity, budget, tail-position, and trampoline behavior."
      (let ((direct-call? (null? maybe-continuation))
            (continuation
             (if (null? maybe-continuation)
                 identity-continuation
                 (car maybe-continuation))))
        (define (finish state)
          (if direct-call?
              (drain-state state context)
              state))
        (cond
         ((consent-primitive-procedure? procedure)
          (if (not (arity-match? procedure (length arguments)))
              (eval-error "primitive received wrong number of arguments"
                          (primitive-procedure-name procedure)
                          (length arguments)))
          (note-host-callback! context procedure)
          (let ((name (primitive-procedure-name procedure))
                (function (primitive-procedure-function procedure)))
            (finish
             (cond
              ((eq? name 'apply)
               (primitive-apply/k arguments context continuation))
              ((eq? name 'call-with-values)
               (primitive-call-with-values/k arguments context continuation))
              ((eq? name 'call-with-port)
               (primitive-call-with-port/k arguments context continuation))
              ((eq? name 'call-with-input-file)
               (primitive-call-with-input-file/k
                arguments context continuation))
              ((eq? name 'call-with-output-file)
               (primitive-call-with-output-file/k
                arguments context continuation))
              ((eq? name 'with-input-from-file)
               (primitive-with-input-from-file/k
                arguments context continuation))
              ((eq? name 'with-output-to-file)
               (primitive-with-output-to-file/k
                arguments context continuation))
              ((or (eq? name 'call-with-current-continuation)
                   (eq? name 'call/cc))
               (primitive-call/cc/k arguments context continuation))
              ((eq? name 'dynamic-wind)
               (primitive-dynamic-wind/k arguments context continuation))
              ((eq? name 'with-exception-handler)
               (primitive-with-exception-handler/k
                arguments context continuation))
              ((eq? name 'raise-continuable)
               (primitive-raise-continuable/k
                arguments context continuation))
              ((eq? name 'raise)
               (primitive-raise/k arguments context continuation))
              ((eq? name 'error)
               (primitive-error/k arguments context continuation))
              ((eq? name 'eval)
               (primitive-eval/k arguments context continuation))
              ((eq? name 'load)
               (primitive-load/k arguments context continuation))
              ((eq? name 'make-parameter)
               (primitive-make-parameter/k arguments context continuation))
              (else
               ;; The guarded path costs a host guard per call, so reserve
               ;; it for dynamic extents with installed interpreted
               ;; handlers; without them conversion would be a no-op.
               (if (pair? (context-exception-handlers context))
                   (apply-host-primitive/k
                    function arguments context continuation
                    (native-primitive-name? name))
                   (continue
                    continuation
                    (function arguments context))))))))
         ((consent-parameter? procedure)
          (finish
           (apply-parameter/k procedure arguments context continuation)))
         ((consent-procedure? procedure)
          (let ((closure-syntax-environment
                 (procedure-syntax-environment procedure))
                (caller-syntax-environment
                 (context-syntax-environment context)))
            (finish
             (with-syntax-environment
              context
              closure-syntax-environment
              (lambda ()
                (let* ((call-environment
                        (bind-formals
                         (procedure-formals procedure)
                         arguments
                         (procedure-environment procedure)
                         context))
                       (body-state
                        (prepare-body-environment
                         (procedure-body procedure)
                         call-environment
                         context))
                       (body-expression
                        (make-sequence (cdr body-state) #f)))
                  (make-bounce body-expression
                               (car body-state)
                               closure-syntax-environment
                               (if tail?
                                   continuation
                                   (lambda (value)
                                     (with-syntax-environment
                                      context
                                      caller-syntax-environment
                                      (lambda ()
                                        (continue continuation value))))))))))))
         ((continuation? procedure)
          (finish
           (invoke-continuation procedure arguments context)))
         (else
          (eval-error "attempted to call non-procedure"
                      (consent-value->external procedure))))))

    (define (eval-if parts environment context tail? continuation)
      "Evaluate an if form, preserving tail position for selected branches."
      (if (not (or (= (length parts) 3) (= (length parts) 4)))
          (eval-error
           "if requires test, consequent, and optional alternate"
           parts))
      (eval-expression
       (second parts)
       environment
       context
       #f
       (lambda (test-result)
         (let ((test-value (single-value test-result "if test")))
           (cond
            ((true-value? test-value)
             (if tail?
                 (make-bounce (third parts)
                              environment
                              (context-syntax-environment context)
                              continuation)
                 (eval-expression
                  (third parts) environment context #f continuation)))
            ((= (length parts) 4)
             (if tail?
                 (make-bounce (fourth parts)
                              environment
                              (context-syntax-environment context)
                              continuation)
                 (eval-expression
                  (fourth parts) environment context #f continuation)))
            (else
             (continue continuation consent-unspecified)))))))

    (define (eval-set! parts environment context continuation)
      "Evaluate a set! form and mutate the target identifier binding."
      (if (not (= (length parts) 3))
          (eval-error "set! requires an identifier and an expression" parts))
      (let ((target (second parts)))
        (eval-expression
         (third parts)
         environment
         context
         #f
         (lambda (raw-value)
           (let ((value (single-value raw-value "set! expression")))
             (if (not (identifier-datum? target))
                 (eval-error "set! target must be an identifier" target))
             (environment-set-identifier! environment target value)
             (continue continuation consent-unspecified))))))

    (define (eval-quasiquote-list template depth environment context)
      "Evaluate a quasiquote list template, including depth-aware splicing."
      (let loop ((cursor template) (output '()))
        (if (pair? cursor)
            (let ((element (car cursor)))
              (if (and (= depth 1)
                       (tagged-list? element 'unquote-splicing))
                  (let ((splice
                         (single-value
                          (eval-expression
                           (single-argument-syntax
                            element
                            "unquote-splicing")
                           environment
                           context
                           #f)
                          "unquote-splicing result")))
                    (loop (cdr cursor)
                          (append (reverse
                                   (proper-list-elements
                                    splice
                                    "unquote-splicing result"))
                                  output)))
                  (loop (cdr cursor)
                        (cons (eval-quasiquote-template
                               element depth environment context)
                              output))))
            (append-tail
             (reverse output)
             (cond
              ((null? cursor) '())
              ((and (= depth 1)
                    (tagged-list? cursor 'unquote))
               (single-value
                (eval-expression
                 (single-argument-syntax cursor "unquote")
                 environment
                 context
                 #f)
                "unquote result"))
              (else
               (eval-quasiquote-template
                cursor depth environment context)))))))

    (define (eval-quasiquote-template template depth environment context)
      "Evaluate one quasiquote template with nested quasiquote depth tracking."
      (cond
       ((tagged-list? template 'unquote)
        (let ((operand (single-argument-syntax template "unquote")))
          (if (= depth 1)
              (single-value
               (eval-expression operand environment context #f)
               "unquote result")
              (list (car template)
                    (eval-quasiquote-template
                     operand (- depth 1) environment context)))))
       ((tagged-list? template 'unquote-splicing)
        (if (= depth 1)
            (eval-error
             "unquote-splicing is only valid inside a quasiquoted list or vector"
             template)
            (let ((operand
                   (single-argument-syntax template "unquote-splicing")))
              (list (car template)
                    (eval-quasiquote-template
                     operand (- depth 1) environment context)))))
       ((tagged-list? template 'quasiquote)
        (let ((operand (single-argument-syntax template "quasiquote")))
          (list (car template)
                (eval-quasiquote-template
                 operand (+ depth 1) environment context))))
       ((pair? template)
        (eval-quasiquote-list template depth environment context))
       ((vector? template)
        (list->vector
         (eval-quasiquote-list
          (vector->list template) depth environment context)))
       (else template)))

    (define (eval-quasiquote parts environment context)
      "Evaluate a quasiquote form after validating its single template operand."
      (if (not (= (length parts) 2))
          (eval-error "quasiquote requires exactly one template" parts))
      (eval-quasiquote-template (second parts) 1 environment context))

    (define (parse-letrec-binding binding description)
      "Parse one letrec or letrec* binding into a name/expression pair."
      (let ((parts (proper-list-elements binding description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description
                            " binding must contain an identifier and initializer")
             binding))
        (cons (expect-identifier-key (car parts) description)
              (second parts))))

    (define (eval-letrec
             parts environment context tail? sequential? . maybe-continuation)
      "Evaluate letrec or letrec* with preallocated recursive binding cells."
      (if (< (length parts) 3)
          (eval-error
           (string-append
            (if sequential? "letrec*" "letrec")
            " requires bindings and a body")
           parts))
      (let* ((description (if sequential? "letrec*" "letrec"))
             (bindings
              (map (lambda (binding)
                     (parse-letrec-binding binding description))
                   (proper-list-elements
                    (second parts)
                    (string-append description " binding list"))))
             (names (map car bindings))
             (local-environment
              (consent-make-empty-environment environment)))
        (ensure-distinct-names names description)
        (for-each
         (lambda (name)
           (environment-define! local-environment name undefined))
         names)
        (if sequential?
            (for-each
             (lambda (binding)
               (environment-set!
                local-environment
                (car binding)
                (single-value
                 (eval-expression (cdr binding)
                                  local-environment
                                  context
                                  #f)
                 "letrec* initializer")))
             bindings)
            (let ((values
                   (map (lambda (binding)
                          (cons (car binding)
                                (single-value
                                 (eval-expression (cdr binding)
                                                  local-environment
                                                  context
                                                  #f)
                                 "letrec initializer")))
                        bindings)))
              (for-each
               (lambda (binding-value)
                 (environment-set!
                  local-environment
                  (car binding-value)
                  (cdr binding-value)))
               values)))
        (eval-sequence (cddr parts)
                       local-environment
                       context
                       tail?
                       #t
                       (if (null? maybe-continuation)
                           identity-continuation
                           (car maybe-continuation)))))

    (define (parse-mv-binding binding description)
      "Parse one let-values binding into formals metadata and initializer."
      (let ((parts (proper-list-elements binding description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description
                            " binding must contain formals and initializer")
             binding))
        (cons (parse-formals (car parts))
              (second parts))))

    (define (eval-let-values
             parts environment context tail? sequential? . maybe-continuation)
      "Evaluate let-values or let*-values with parallel or sequential binding."
      (if (< (length parts) 3)
          (eval-error
           (string-append
            (if sequential? "let*-values" "let-values")
            " requires bindings and a body")
           parts))
      (let* ((description (if sequential? "let*-values" "let-values"))
             (bindings
              (map (lambda (binding)
                     (parse-mv-binding binding description))
                   (proper-list-elements
                    (second parts)
                    (string-append description " binding list"))))
             (local-environment
              (consent-make-empty-environment environment))
             (direct-call? (null? maybe-continuation))
             (continuation
              (if direct-call?
                  identity-continuation
                  (car maybe-continuation))))
        (define (body)
          (eval-sequence (cddr parts)
                         local-environment
                         context
                         tail?
                         #t
                         continuation))
        (define (step-sequential remaining)
          (if (null? remaining)
              (body)
              (let ((binding (car remaining)))
                (eval-expression
                 (cdr binding)
                 local-environment
                 context
                 #f
                 (lambda (value)
                   (bind-formals-in-environment
                    (car binding)
                    (values-list value)
                    local-environment
                    context
                    description)
                   (step-sequential (cdr remaining)))))))
        (define (step-parallel remaining all-names evaluated)
          (if (null? remaining)
              (begin
                (ensure-distinct-names all-names description)
                (for-each
                 (lambda (binding-values)
                   (bind-formals-in-environment
                    (car binding-values)
                    (cdr binding-values)
                    local-environment
                    context
                    description))
                 (reverse evaluated))
                (body))
              (let ((binding (car remaining)))
                (eval-expression
                 (cdr binding)
                 environment
                 context
                 #f
                 (lambda (value)
                   (step-parallel
                    (cdr remaining)
                    (append all-names
                            (formals-names (car binding)))
                    (cons (cons (car binding)
                                (values-list value))
                          evaluated)))))))
        (let ((state (if sequential?
                         (step-sequential bindings)
                         (step-parallel bindings '() '()))))
          (if direct-call?
              (drain-state state context)
              state))))

    (define (eval-arguments operands environment context arguments continuation)
      "Evaluate procedure operands from left to right into argument values."
      (if (null? operands)
          (continue continuation (reverse arguments))
          (eval-expression
           (car operands)
           environment
           context
           #f
           (lambda (raw-argument)
             (eval-arguments
              (cdr operands)
              environment
              context
              (cons (single-value raw-argument "procedure argument")
                    arguments)
              continuation)))))

    (define (eval-combination expression environment context tail? continuation)
      "Evaluate a combination or special form with tail-position awareness."
      (let ((parts (proper-list-elements expression "expression")))
        (if (null? parts)
            (eval-error "empty list is not an expression"))
        (let ((operator (car parts)))
          (cond
           ((and (identifier-named? operator 'quote)
                 (special-operator-active? operator environment))
            (if (not (= (length parts) 2))
                (eval-error "quote requires exactly one datum" parts))
            (continue continuation
                      (charge-literal! (second parts) context)))
           ((and (identifier-named? operator 'quasiquote)
                 (special-operator-active? operator environment))
            ;; The quasiquote builder assembles its result with host cons/append
            ;; rather than the charged primitives, so charge the realized result
            ;; once -- like any other literal -- off the hot primitive path.
            (continue
             continuation
             (charge-literal!
              (eval-quasiquote parts environment context)
              context)))
           ((and (identifier-named? operator 'lambda)
                 (special-operator-active? operator environment))
            (if (< (length parts) 3)
                (eval-error "lambda requires formals and a body" parts))
            (let ((formals (second parts))
                  (body (cddr parts)))
              (let* ((parsed-formals (parse-formals formals))
                     (documentation-result
                      (body-documentation-result body context parsed-formals)))
                (continue
                 continuation
                 (make-procedure parsed-formals
                                 (cdr documentation-result)
                                 environment
                                 (car documentation-result)
                                 (context-syntax-environment context))))))
           ((and (identifier-named? operator 'if)
                 (special-operator-active? operator environment))
            (eval-if parts environment context tail? continuation))
           ((and (identifier-named? operator 'set!)
                 (special-operator-active? operator environment))
            (eval-set! parts environment context continuation))
           ((and (identifier-named? operator 'let-values)
                 (special-operator-active? operator environment))
            (eval-let-values
             parts environment context tail? #f continuation))
           ((and (identifier-named? operator 'let*-values)
                 (special-operator-active? operator environment))
            (eval-let-values
             parts environment context tail? #t continuation))
           ((and (identifier-named? operator 'letrec)
                 (special-operator-active? operator environment))
            (eval-letrec
             parts environment context tail? #f continuation))
           ((and (identifier-named? operator 'letrec*)
                 (special-operator-active? operator environment))
            (eval-letrec
             parts environment context tail? #t continuation))
           ((and (identifier-named? operator 'define)
                 (special-operator-active? operator environment))
            (eval-error "define is not valid in expression position" parts))
           ((and (identifier-named? operator 'define-values)
                 (special-operator-active? operator environment))
            (eval-error
             "define-values is not valid in expression position"
             parts))
           ((and (identifier-named? operator 'define-record-type)
                 (special-operator-active? operator environment))
            (eval-error
             "define-record-type is not valid in expression position"
             parts))
           ((and (identifier-named? operator 'define-syntax)
                 (special-operator-active? operator environment))
            (eval-error
             "define-syntax is not valid in expression position"
             parts))
           ((and (identifier-named? operator 'define-library)
                 (special-operator-active? operator environment))
            (eval-error
             "define-library is not valid in expression position"
             parts))
           ((and (identifier-named? operator 'import)
                 (special-operator-active? operator environment))
            (eval-error
             "import is not valid in expression position"
             parts))
           ((and (identifier-named? operator 'begin)
                 (special-operator-active? operator environment))
            (eval-sequence
             (cdr parts) environment context tail? #f continuation))
           ((and (identifier-named? operator 'with-budget)
                 (special-operator-active? operator environment))
            (eval-with-budget parts environment context tail? continuation))
           (else
            (eval-expression
             operator
             environment
             context
             #f
             (lambda (raw-procedure)
               (let ((procedure
                      (single-value raw-procedure "procedure operator")))
                 (eval-arguments
                  (cdr parts)
                  environment
                  context
                  '()
                  (lambda (arguments)
                    (apply-procedure
                     procedure
                     arguments
                     context
                     tail?
                     continuation)))))))))))

    (define (eval-with-budget parts environment context tail? continuation)
      "Evaluate (with-budget SPEC BODY ...) under a tightened budget."
      "SPEC evaluates to a `(budget ...)' datum; for its dynamic extent the"
      "active counter ceilings admit at most the SPEC amount more. The"
      "inherited ceilings are restored when the body completes. A non-local"
      "exit out of the body leaves the tightened ceilings in place, which is a"
      "conservative, fail-closed outcome rather than a relaxation. The body is"
      "an implicit `begin'; wrap it in `(let () ...)' for internal definitions."
      (if (< (length parts) 3)
          (eval-error "with-budget requires a budget spec and a body" parts))
      (eval-expression
       (second parts)
       environment
       context
       #f
       (lambda (spec-result)
         (let ((spec (single-value spec-result "with-budget spec"))
               (saved (budget-ceiling-snapshot context)))
           (budget-tighten! context spec)
           (eval-sequence
            (cddr parts)
            environment
            context
            #f
            #f
            (lambda (body-result)
              (budget-restore! context saved)
              (continue continuation body-result)))))))

    (define (eval-expression
             expression environment context tail? . maybe-continuation)
      "Evaluate one expression, interleaving macro expansion and trampoline setup."
      (let ((direct-call? (null? maybe-continuation))
            (continuation
             (if (null? maybe-continuation)
                 identity-continuation
                 (car maybe-continuation))))
        (note-step! context)
        (let ((state
               (cond
                ((sequence? expression)
                 (eval-sequence (sequence-forms expression)
                                environment
                                context
                                tail?
                                (sequence-allow-definitions expression)
                                continuation))
                ((syntax-scope? expression)
                 (with-syntax-environment
                  context
                  (syntax-scope-syntax-environment expression)
                  (lambda ()
                    (eval-sequence (syntax-scope-forms expression)
                                   environment
                                   context
                                   tail?
                                   #t
                                   continuation))))
                ((self-evaluating? expression)
                 (continue continuation
                           (charge-literal! expression context)))
                ((symbol? expression)
                 (continue
                  continuation
                  (environment-ref-identifier environment expression)))
                ((identifier? expression)
                 (continue
                  continuation
                  (environment-ref-identifier environment expression)))
                ((null? expression)
                 (eval-error "empty list is not an expression"))
                ((pair? expression)
                 (let ((expanded
                        (expand-expression expression environment context)))
                   ;; Expansion is interleaved with evaluation so local syntax
                   ;; forms can update CONTEXT before the resulting core
                   ;; expression is evaluated.
                   (if (eq? expanded expression)
                       (eval-combination
                        expression environment context tail? continuation)
                       (eval-expression
                        expanded environment context tail? continuation))))
                (else
                 (eval-error "unsupported expression datum" expression)))))
          (if direct-call?
              (drain-state state context)
              state))))

    (define (ensure-imports-precede-body forms)
      "Reject import declarations that appear after body expressions."
      (let loop ((rest forms) (imports-open? #t))
        (if (not (null? rest))
            (let ((form (car rest)))
              (cond
               ((import-form? form)
                (if (not imports-open?)
                    (eval-error
                     "import declarations must precede program body forms"
                     form))
                (loop (cdr rest) imports-open?))
               ((define-library-form? form)
                (loop (cdr rest) imports-open?))
               (else
                (loop (cdr rest) #f)))))))

    (define (eval-sequence
             forms environment context tail? allow-definitions?
             . maybe-continuation)
      "Evaluate a sequence, optionally accepting leading definitions/imports."
      (if allow-definitions?
          (ensure-imports-precede-body forms))
      (let ((continuation
             (if (null? maybe-continuation)
                 identity-continuation
                 (car maybe-continuation))))
        (define (after-form value rest)
          (if (null? rest)
              (continue continuation value)
              (step rest)))
        (define (step rest)
          (if (null? rest)
              (continue continuation consent-unspecified)
              (let* ((form (car rest))
                     (remaining (cdr rest))
                     (last? (null? remaining)))
                (cond
                 ((import-form? form)
                  (if allow-definitions?
                      (after-form
                       (eval-import form environment context)
                       remaining)
                      (eval-error
                       "import is only allowed at top level or in library bodies"
                       form)))
                 ((define-library-form? form)
                  (if allow-definitions?
                      (after-form
                       (eval-define-library form environment context)
                       remaining)
                      (eval-error
                       "define-library is only allowed at top level"
                       form)))
                 ((syntax-definition-form? form)
                  (if allow-definitions?
                      (after-form
                       (eval-define-syntax
                        form
                        environment
                        context
                        (context-syntax-environment context))
                       remaining)
                      (eval-error
                       "define-syntax is only allowed before body expressions"
                       form)))
                 ((record-definition-form? form)
                  (if allow-definitions?
                      (after-form
                       (eval-record-definition form environment context)
                       remaining)
                      (eval-error
                       "define-record-type is only allowed before body expressions"
                       form)))
                 ((definition-form? form)
                  (if allow-definitions?
                      (eval-definition
                       form
                       environment
                       context
                       (lambda (value)
                         (after-form value remaining)))
                      (eval-error
                       "define is only allowed before body expressions"
                       form)))
                 ((define-values-form? form)
                  (if allow-definitions?
                      (eval-define-values
                       form
                       environment
                       context
                       (lambda (value)
                         (after-form value remaining)))
                      (eval-error
                       "define-values is only allowed before body expressions"
                       form)))
                 ((and allow-definitions? (begin-form? form))
                  (eval-sequence
                   (cdr (proper-list-elements form "begin form"))
                   environment
                   context
                   (and last? tail?)
                   #t
                   (lambda (value)
                     (after-form value remaining))))
                 (last?
                  (if tail?
                      (make-bounce form
                                   environment
                                   (context-syntax-environment context)
                                   continuation)
                      (eval-expression
                       form environment context #f continuation)))
                 (else
                  (eval-expression
                   form
                   environment
                   context
                   #f
                   (lambda (value)
                     (step remaining))))))))
        (step forms)))

    (define (capture-dynamic-state context)
      "Return a checkpoint of CONTEXT's dynamic-extent state."
      "The checkpoint covers the exception-handler stack, current-error,"
      "and the dynamic-wind stack -- the state CPS primitives mutate and"
      "unwind through their success continuations."
      (list (context-exception-handlers context)
            (context-current-error context)
            (context-dynamic-winds context)))

    (define (restore-dynamic-state context checkpoint)
      "Restore CONTEXT's dynamic-extent state from CHECKPOINT."
      (set-context-exception-handlers! context (list-ref checkpoint 0))
      (set-context-current-error! context (list-ref checkpoint 1))
      (set-context-dynamic-winds! context (list-ref checkpoint 2)))

    (define (drain-state state context)
      "Run bounce states until evaluation produces a final value."
      "The CPS primitives restore the exception-handler stack, current-error,"
      "and the dynamic-wind stack from inside their success continuation,"
      "which never runs when an invoked handler or wind thunk escapes via a"
      "raised condition (an unhandled or non-continuable raise, a budget"
      "overflow).  Checkpoint that state on entry and restore it should the"
      "trampoline unwind before producing a final value, so the CPS path is"
      "unwind-safe like the direct path.  Normal return and"
      "reified-continuation escapes leave the checkpoint untouched, so an"
      "aborting condition cannot leak handler or wind frames into a reused"
      "context.  Caught escapes still run dynamic-wind after thunks via"
      "switch-dynamic-winds!; an aborting condition does not."
      (let ((checkpoint (capture-dynamic-state context))
            (completed #f))
        (dynamic-wind
         (lambda () #f)
         (lambda ()
           (let loop ((state state))
             (if (bounce? state)
                 ;; A bounce carries the value environment, syntax
                 ;; environment, and evaluator continuation needed by the
                 ;; next tail step.
                 (loop
                  (with-syntax-environment
                   context
                   (bounce-syntax-environment state)
                   (lambda ()
                     (eval-expression (bounce-expression state)
                                      (bounce-environment state)
                                      context
                                      #t
                                      (bounce-continuation state)))))
                 (begin
                   (set! completed #t)
                   state))))
         (lambda ()
           (if (not completed)
               (restore-dynamic-state context checkpoint))))))

    (define (trampoline expression environment context)
      "Evaluate EXPRESSION in tail-call trampoline mode and return the result."
      "The result needs no final budget walk: every node it reaches was"
      "charged at the allocation that produced it."
      (drain-state
       (make-bounce expression
                    environment
                    (context-syntax-environment context)
                    identity-continuation)
       context))

    (define (expect-number datum description)
      "Validate number input and raise an evaluator error on mismatch."
      (if (consent-number? datum)
          datum
          (eval-error
           (string-append description " expected number")
           datum)))

    (define (number-exact? datum)
      "Report whether DATUM is an exact Consent Scheme number."
      (and (consent-number? datum)
           (eq? (consent-number-exactness datum) 'exact)))

    (define (number-inexact? datum)
      "Report whether DATUM is an inexact Consent Scheme number."
      (and (consent-number? datum)
           (eq? (consent-number-exactness datum) 'inexact)))

    (define (number-nan? datum)
      "Report whether DATUM contains a NaN numeric component."
      (and (consent-number? datum)
           (or (and (eq? (consent-number-kind datum) 'infnan)
                    (string=? (consent-number-value datum) "+nan.0"))
               (and (eq? (consent-number-kind datum) 'complex)
                    (or (number-nan?
                         (car (consent-number-value datum)))
                        (number-nan?
                         (cdr (consent-number-value datum))))))))

    (define (number-infinite? datum)
      "Report whether DATUM contains an infinite numeric component."
      (and (consent-number? datum)
           (or (and (eq? (consent-number-kind datum) 'infnan)
                    (or (string=? (consent-number-value datum) "+inf.0")
                        (string=? (consent-number-value datum) "-inf.0")))
               (and (eq? (consent-number-kind datum) 'complex)
                    (or (number-infinite?
                         (car (consent-number-value datum)))
                        (number-infinite?
                         (cdr (consent-number-value datum))))))))

    (define (number-finite? datum)
      "Report whether DATUM is neither infinite nor NaN."
      (and (consent-number? datum)
           (not (number-nan? datum))
           (not (number-infinite? datum))))

    (define (number-exact-zero? datum)
      "Report whether DATUM is exactly zero."
      (and (number-exact? datum)
           (consent-number-zero? datum)))

    (define (number-complex-representation? number)
      "Report whether NUMBER is stored as a complex pair."
      (eq? (consent-number-kind number) 'complex))

    (define (complex-parts number)
      "Return NUMBER's rectangular parts, using zero imaginary part for reals."
      (if (number-complex-representation? number)
          (consent-number-value number)
          (cons number (consent-make-canonical-integer 0))))

    (define (number-real? datum)
      "Report whether DATUM has no nonzero imaginary component."
      (and (consent-number? datum)
           (or (not (number-complex-representation? datum))
               (number-exact-zero?
                (cdr (consent-number-value datum))))))

    (define (number-rational? datum)
      "Report whether DATUM is a finite real number."
      (and (number-real? datum)
           (let ((real (if (number-complex-representation? datum)
                           (car (consent-number-value datum))
                           datum)))
             (not (eq? (consent-number-kind real) 'infnan)))))

    (define (number-integer? datum)
      "Report whether DATUM represents an integer numeric value."
      (and (consent-number? datum)
           (cond
            ((number-complex-representation? datum)
             (and (number-exact-zero?
                   (cdr (consent-number-value datum)))
                  (number-integer?
                   (car (consent-number-value datum)))))
            ((eq? (consent-number-kind datum) 'integer) #t)
            ((eq? (consent-number-kind datum) 'rational)
             (= (cdr (consent-number-value datum)) 1))
            ((eq? (consent-number-kind datum) 'decimal)
             (let ((value (consent-number-value datum)))
               (= value (truncate value))))
            (else #f))))

    (define (number->rational-pair datum description)
      "Convert DATUM to an exact numerator/denominator pair."
      (let ((number (expect-number datum description)))
        (cond
         ((eq? (consent-number-kind number) 'integer)
          (cons (consent-number-value number) 1))
         ((eq? (consent-number-kind number) 'rational)
          (consent-number-value number))
         ((number-complex-representation? number)
          (if (number-exact-zero? (cdr (consent-number-value number)))
              (number->rational-pair
               (car (consent-number-value number))
               description)
              (eval-error
               (string-append description " expected real number")
               datum)))
         (else
          (eval-error
           (string-append description " expected exact rational number")
           datum)))))

    (define (number->host-float datum description)
      "Convert DATUM to a host inexact real for transcendental operations."
      (let ((number (expect-number datum description)))
        (cond
         ((eq? (consent-number-kind number) 'integer)
          (inexact (consent-number-value number)))
         ((eq? (consent-number-kind number) 'rational)
          (let ((value (consent-number-value number)))
            (/ (inexact (car value)) (inexact (cdr value)))))
         ((eq? (consent-number-kind number) 'decimal)
          (consent-number-value number))
         ((eq? (consent-number-kind number) 'infnan)
          (cond
           ((string=? (consent-number-value number) "+inf.0")
            (/ 1.0 0.0))
           ((string=? (consent-number-value number) "-inf.0")
            (/ -1.0 0.0))
           (else (/ 0.0 0.0))))
         ((number-complex-representation? number)
          (if (number-exact-zero? (cdr (consent-number-value number)))
              (number->host-float
               (car (consent-number-value number))
               description)
              (eval-error
               (string-append description " expected real number")
               datum))))))

    (define (host-number->agent-number number)
      "Convert a host numeric result to the canonical Consent Scheme number."
      (cond
       ((integer? number)
        (consent-make-canonical-integer number))
       (else
        (consent-make-canonical-decimal number))))

    (define (number-from-rational-pair pair . maybe-exactness)
      "Build an Consent Scheme number from a numerator/denominator pair."
      (let* ((exactness
              (if (null? maybe-exactness) 'exact (car maybe-exactness)))
             (number
              (consent-make-canonical-rational
               (car pair)
               (cdr pair)
               exactness
               10)))
        (if (eq? exactness 'inexact)
            (consent-make-canonical-decimal
             (/ (inexact (car pair)) (inexact (cdr pair))))
            number)))

    (define (number-inexact number)
      "Convert NUMBER to an inexact Consent Scheme number."
      (let ((datum (expect-number number "inexact")))
        (cond
         ((or (eq? (consent-number-kind datum) 'decimal)
              (eq? (consent-number-kind datum) 'infnan))
          datum)
         ((eq? (consent-number-kind datum) 'integer)
          (consent-make-canonical-decimal
           (inexact (consent-number-value datum))))
         ((eq? (consent-number-kind datum) 'rational)
          (let ((value (consent-number-value datum)))
            (consent-make-canonical-decimal
             (/ (inexact (car value)) (inexact (cdr value))))))
         ((number-complex-representation? datum)
          (let ((value (consent-number-value datum)))
            (consent-make-canonical-complex
             (number-inexact (car value))
             (number-inexact (cdr value))))))))

    (define (decimal->exact-rational-pair number)
      "Reparse an inexact decimal as its exact rational representation."
      (number->rational-pair
       (consent-read
        (string-append "#e" (consent-number->external number))
        '((source-metadata . #f)))
       "exact"))

    (define (number-exact number)
      "Convert NUMBER to an exact Consent Scheme number when representable."
      (let ((datum (expect-number number "exact")))
        (cond
         ((or (eq? (consent-number-kind datum) 'integer)
              (eq? (consent-number-kind datum) 'rational))
          datum)
         ((eq? (consent-number-kind datum) 'decimal)
          (number-from-rational-pair
           (decimal->exact-rational-pair datum)))
         ((number-complex-representation? datum)
          (let ((value (consent-number-value datum)))
            (consent-make-canonical-complex
             (number-exact (car value))
             (number-exact (cdr value)))))
         ((eq? (consent-number-kind datum) 'infnan)
          (eval-error "exact cannot represent inexact special value" datum)))))

    (define (exact-integer->host datum description)
      "Return DATUM as a host exact integer or raise a typed error."
      (if (and (consent-number? datum)
               (eq? (consent-number-kind datum) 'integer)
               (eq? (consent-number-exactness datum) 'exact))
          (consent-number-value datum)
          (eval-error
           (string-append description " must be an exact integer")
           datum)))

    (define (expect-nonnegative-index datum limit description allow-end?)
      "Validate nonnegative index input and raise an evaluator error on mismatch."
      (let ((index (exact-integer->host datum description)))
        (if (not (and (<= 0 index)
                      (if allow-end? (<= index limit) (< index limit))))
            (eval-error
             (string-append description " index out of range")
             index))
        index))

    (define (expect-byte datum description)
      "Validate byte input and raise an evaluator error on mismatch."
      (let ((byte (exact-integer->host datum description)))
        (if (not (and (<= 0 byte) (<= byte 255)))
            (eval-error
             (string-append description " must be in byte range")
             byte))
        byte))

    (define (expect-string datum description)
      "Validate string input and raise an evaluator error on mismatch."
      (if (string? datum)
          datum
          (eval-error (string-append description " must be a string") datum)))

    (define (expect-character datum description)
      "Validate character input and raise an evaluator error on mismatch."
      (if (char? datum)
          datum
          (eval-error
           (string-append description " must be a character")
           datum)))

    (define (expect-vector datum description)
      "Validate vector input and raise an evaluator error on mismatch."
      (if (vector? datum)
          datum
          (eval-error (string-append description " must be a vector") datum)))

    (define (expect-bytevector datum description)
      "Validate bytevector input and raise an evaluator error on mismatch."
      (if (bytevector? datum)
          datum
          (eval-error
           (string-append description " must be a bytevector")
           datum)))

    (define (expect-procedure datum description)
      "Validate procedure input and raise an evaluator error on mismatch."
      (if (or (consent-procedure? datum)
              (consent-primitive-procedure? datum)
              (consent-parameter? datum)
              (continuation? datum))
          datum
          (eval-error
           (string-append description " must be a procedure")
           datum)))

    (define (optional-range arguments offset limit description)
      "Parse optional start/end indices for sequence operations."
      (let ((optional-count (- (length arguments) offset)))
        (if (not (and (<= 0 optional-count) (<= optional-count 2)))
            (eval-error
             (string-append description
                            " expected at most start and end arguments")))
        (let ((start (if (>= optional-count 1)
                         (expect-nonnegative-index
                          (list-ref arguments offset)
                          limit
                          description
                          #t)
                         0))
              (end (if (>= optional-count 2)
                       (expect-nonnegative-index
                        (list-ref arguments (+ offset 1))
                        limit
                        description
                        #t)
                       limit)))
          (if (> start end)
              (eval-error
               (string-append description " start index exceeds end index")))
          (cons start end))))

    (define (numeric-arguments arguments description)
      "Validate all ARGUMENTS as numbers."
      (map (lambda (argument) (expect-number argument description))
           arguments))

    (define (any-number-inexact? numbers)
      "Report whether any number in NUMBERS is inexact."
      (let loop ((rest numbers))
        (and (not (null? rest))
             (or (number-inexact? (car rest))
                 (loop (cdr rest))))))

    (define (binary-rational left right operation description)
      "Apply exact rational arithmetic for one binary operation."
      (let* ((left-pair (number->rational-pair left description))
             (right-pair (number->rational-pair right description))
             (left-numerator (car left-pair))
             (left-denominator (cdr left-pair))
             (right-numerator (car right-pair))
             (right-denominator (cdr right-pair)))
        (cond
         ((eq? operation '+)
          (number-from-rational-pair
           (cons (+ (* left-numerator right-denominator)
                    (* right-numerator left-denominator))
                 (* left-denominator right-denominator))))
         ((eq? operation '-)
          (number-from-rational-pair
           (cons (- (* left-numerator right-denominator)
                    (* right-numerator left-denominator))
                 (* left-denominator right-denominator))))
         ((eq? operation '*)
          (number-from-rational-pair
           (cons (* left-numerator right-numerator)
                 (* left-denominator right-denominator))))
         ((eq? operation '/)
          (if (zero? right-numerator)
              (eval-error (string-append description " division by zero")))
          (number-from-rational-pair
           (cons (* left-numerator right-denominator)
                 (* left-denominator right-numerator)))))))

    (define (special-inexact-binary left right operation description)
      "Handle NaN and infinity cases for inexact binary arithmetic."
      (cond
       ((or (number-nan? left) (number-nan? right))
        (consent-make-canonical-infnan "+nan.0"))
       ((or (eq? (consent-number-kind left) 'infnan)
            (eq? (consent-number-kind right) 'infnan))
        (let ((left-kind
               (and (eq? (consent-number-kind left) 'infnan)
                    (consent-number-value left)))
              (right-kind
               (and (eq? (consent-number-kind right) 'infnan)
                    (consent-number-value right))))
          (cond
           ((eq? operation '+)
            (cond
             ((and left-kind right-kind (not (string=? left-kind right-kind)))
              (consent-make-canonical-infnan "+nan.0"))
             (left-kind left)
             (right-kind right)
             (else #f)))
           ((eq? operation '-)
            (cond
             ((and left-kind right-kind (string=? left-kind right-kind))
              (consent-make-canonical-infnan "+nan.0"))
             (left-kind left)
             ((and right-kind (string=? right-kind "+inf.0"))
              (consent-make-canonical-infnan "-inf.0"))
             ((and right-kind (string=? right-kind "-inf.0"))
              (consent-make-canonical-infnan "+inf.0"))
             (else #f)))
           (else
            (host-number->agent-number
             ((if (eq? operation '*) * /)
              (number->host-float left description)
              (number->host-float right description)))))))
       (else #f)))

    (define (binary-real-number left right operation description)
      "Apply a binary arithmetic operation to real numbers."
      (or (special-inexact-binary left right operation description)
          (if (or (number-inexact? left) (number-inexact? right))
              (consent-make-canonical-decimal
               ((cond
                 ((eq? operation '+) +)
                 ((eq? operation '-) -)
                 ((eq? operation '*) *)
                 (else /))
                (number->host-float left description)
                (number->host-float right description)))
              (binary-rational left right operation description))))

    (define (binary-number left right operation description)
      "Apply a binary arithmetic operation to real or complex numbers."
      (if (or (number-complex-representation? left)
              (number-complex-representation? right))
          (let* ((left-parts (complex-parts left))
                 (right-parts (complex-parts right))
                 (a (car left-parts))
                 (b (cdr left-parts))
                 (c (car right-parts))
                 (d (cdr right-parts)))
            (cond
             ((eq? operation '+)
              (consent-make-canonical-complex
               (binary-number a c '+ description)
               (binary-number b d '+ description)))
             ((eq? operation '-)
              (consent-make-canonical-complex
               (binary-number a c '- description)
               (binary-number b d '- description)))
             ((eq? operation '*)
              (consent-make-canonical-complex
               (binary-number
                (binary-number a c '* description)
                (binary-number b d '* description)
                '-
                description)
               (binary-number
                (binary-number a d '* description)
                (binary-number b c '* description)
                '+
                description)))
             ((eq? operation '/)
              (let ((denominator
                     (binary-number
                      (binary-number c c '* description)
                      (binary-number d d '* description)
                      '+
                      description)))
                (if (consent-number-zero? denominator)
                    (eval-error
                     (string-append description " division by zero")))
                (consent-make-canonical-complex
                 (binary-number
                  (binary-number
                   (binary-number a c '* description)
                   (binary-number b d '* description)
                   '+
                   description)
                  denominator
                  '/
                  description)
                 (binary-number
                  (binary-number
                   (binary-number b c '* description)
                   (binary-number a d '* description)
                   '-
                   description)
                  denominator
                  '/
                  description))))))
          (binary-real-number left right operation description)))

    (define (fold-numbers arguments identity operation description
                          . maybe-unary-inverse)
      "Fold a variadic numeric primitive with optional unary inverse behavior."
      (let ((numbers (numeric-arguments arguments description))
            (unary-inverse
             (if (null? maybe-unary-inverse) #f (car maybe-unary-inverse))))
        (cond
         ((null? numbers) identity)
         ((and unary-inverse (= (length numbers) 1))
          (unary-inverse (car numbers)))
         (else
          (let loop ((result (car numbers)) (rest (cdr numbers)))
            (if (null? rest)
                result
                (loop (binary-number result
                                     (car rest)
                                     operation
                                     description)
                      (cdr rest))))))))

    (define (primitive+ arguments context)
      "Implement the `+' primitive over any number of numeric arguments."
      (fold-numbers
       arguments
       (consent-make-canonical-integer 0)
       '+
       "+"))

    (define (primitive* arguments context)
      "Implement the `*' primitive over any number of numeric arguments."
      (fold-numbers
       arguments
       (consent-make-canonical-integer 1)
       '*
       "*"))

    (define (primitive- arguments context)
      "Implement the `-' primitive, including unary negation."
      (fold-numbers
       arguments
       #f
       '-
       "-"
       (lambda (number)
         (binary-number
          (consent-make-canonical-integer 0)
          number
          '-
          "-"))))

    (define (primitive/ arguments context)
      "Implement the `/' primitive, including unary reciprocal."
      (fold-numbers
       arguments
       #f
       '/
       "/"
       (lambda (number)
         (binary-number
          (consent-make-canonical-integer 1)
          number
          '/
          "/"))))

    (define (number-real-part-for-ordering number description)
      "Return NUMBER's real component or reject non-real complex values."
      (let ((datum (expect-number number description)))
        (if (number-complex-representation? datum)
            (if (number-exact-zero? (cdr (consent-number-value datum)))
                (car (consent-number-value datum))
                (eval-error
                 (string-append description " expected real number")
                 datum))
            datum)))

    (define (number=2 left right)
      "Compare two Consent Scheme numbers for Scheme numeric equality."
      (cond
       ((or (number-nan? left) (number-nan? right)) #f)
       ((or (number-complex-representation? left)
            (number-complex-representation? right))
        (let ((left-parts (complex-parts left))
              (right-parts (complex-parts right)))
          (and (number=2 (car left-parts) (car right-parts))
               (number=2 (cdr left-parts) (cdr right-parts)))))
       ((or (eq? (consent-number-kind left) 'infnan)
            (eq? (consent-number-kind right) 'infnan))
        (and (eq? (consent-number-kind left) 'infnan)
             (eq? (consent-number-kind right) 'infnan)
             (string=? (consent-number-value left)
                       (consent-number-value right))))
       ((or (number-inexact? left) (number-inexact? right))
        (= (number->host-float left "=")
           (number->host-float right "=")))
       (else
        (let ((left-pair (number->rational-pair left "="))
              (right-pair (number->rational-pair right "=")))
          (= (* (car left-pair) (cdr right-pair))
             (* (car right-pair) (cdr left-pair)))))))

    (define (number-order2 left right predicate description)
      "Compare two real Consent Scheme numbers with PREDICATE."
      (let ((ordered-left (number-real-part-for-ordering left description))
            (ordered-right (number-real-part-for-ordering right description)))
        (cond
         ((or (number-nan? ordered-left) (number-nan? ordered-right)) #f)
         ((or (number-inexact? ordered-left)
              (number-inexact? ordered-right)
              (eq? (consent-number-kind ordered-left) 'infnan)
              (eq? (consent-number-kind ordered-right) 'infnan))
          (predicate (number->host-float ordered-left description)
                     (number->host-float ordered-right description)))
         (else
          (let ((left-pair
                 (number->rational-pair ordered-left description))
                (right-pair
                 (number->rational-pair ordered-right description)))
            (predicate
             (* (car left-pair) (cdr right-pair))
             (* (car right-pair) (cdr left-pair))))))))

    (define (primitive-compare arguments predicate description)
      "Implement the `compare` primitive with argument validation and Consent"
      "Scheme values."
      (let loop ((numbers (numeric-arguments arguments description)))
        (cond
         ((or (null? numbers) (null? (cdr numbers))) #t)
         ((if (eq? predicate =)
              (number=2 (car numbers) (second numbers))
              (number-order2 (car numbers)
                             (second numbers)
                             predicate
                             description))
          (loop (cdr numbers)))
         (else #f))))

    (define (primitive= arguments context)
      "Implement the `=' primitive over adjacent numeric pairs."
      (primitive-compare arguments = "="))

    (define (primitive< arguments context)
      "Implement the `<' primitive over adjacent numeric pairs."
      (primitive-compare arguments < "<"))

    (define (primitive> arguments context)
      "Implement the `>' primitive over adjacent numeric pairs."
      (primitive-compare arguments > ">"))

    (define (primitive<= arguments context)
      "Implement the `<=' primitive over adjacent numeric pairs."
      (primitive-compare arguments <= "<="))

    (define (primitive>= arguments context)
      "Implement the `>=' primitive over adjacent numeric pairs."
      (primitive-compare arguments >= ">="))

    (define (primitive-abs arguments context)
      "Implement the `abs` primitive with argument validation and Consent Scheme values."
      (let ((number (expect-number (car arguments) "abs")))
        (if (number-complex-representation? number)
            (eval-error "abs expected real number" number)
            (consent-number-abs number))))

    (define (primitive-min arguments context)
      "Implement the `min` primitive with argument validation and Consent Scheme values."
      (let ((numbers (numeric-arguments arguments "min")))
        (let loop ((best (car numbers)) (rest (cdr numbers)))
          (if (null? rest)
              (if (any-number-inexact? numbers) (number-inexact best) best)
              (loop (if (primitive-compare (list (car rest) best) < "min")
                        (car rest)
                        best)
                    (cdr rest))))))

    (define (primitive-max arguments context)
      "Implement the `max` primitive with argument validation and Consent Scheme values."
      (let ((numbers (numeric-arguments arguments "max")))
        (let loop ((best (car numbers)) (rest (cdr numbers)))
          (if (null? rest)
              (if (any-number-inexact? numbers) (number-inexact best) best)
              (loop (if (primitive-compare (list (car rest) best) > "max")
                        (car rest)
                        best)
                    (cdr rest))))))

    (define (primitive-square arguments context)
      "Implement the `square` primitive with argument validation and Consent"
      "Scheme values."
      (let ((number (expect-number (car arguments) "square")))
        (binary-number number number '* "square")))

    (define (primitive-zero? arguments context)
      "Implement the `zero?` primitive with argument validation and Consent"
      "Scheme values."
      (consent-number-zero? (expect-number (car arguments) "zero?")))

    (define (primitive-positive? arguments context)
      "Implement the `positive?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-compare
       (list (car arguments) (consent-make-canonical-integer 0))
       >
       "positive?"))

    (define (primitive-negative? arguments context)
      "Implement the `negative?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-compare
       (list (car arguments) (consent-make-canonical-integer 0))
       <
       "negative?"))

    (define (primitive-odd? arguments context)
      "Implement the `odd?` primitive with argument validation and Consent Scheme values."
      (odd? (exact-integer->host (car arguments) "odd?")))

    (define (primitive-even? arguments context)
      "Implement the `even?` primitive with argument validation and Consent"
      "Scheme values."
      (even? (exact-integer->host (car arguments) "even?")))

    (define (truncate-quotient-value left right)
      "Return integer quotient rounded toward zero for exact host integers."
      (let ((quotient (quotient (abs left) (abs right))))
        (if (= (if (< left 0) -1 1)
               (if (< right 0) -1 1))
            quotient
            (- quotient))))

    (define (truncate-remainder-value left right)
      "Return the remainder paired with truncate-quotient-value."
      (- left (* right (truncate-quotient-value left right))))

    (define (integer-quotient arguments quotient-function description)
      "Validate two exact integers and apply QUOTIENT-FUNCTION."
      (let ((left (exact-integer->host (car arguments) description))
            (right (exact-integer->host (second arguments) description)))
        (if (zero? right)
            (eval-error (string-append description " division by zero")))
        (consent-make-canonical-integer
         (quotient-function left right))))

    (define (primitive-quotient arguments context)
      "Implement the `quotient` primitive with argument validation and Consent"
      "Scheme values."
      (integer-quotient arguments truncate-quotient-value "quotient"))

    (define (primitive-floor-quotient arguments context)
      "Implement the `floor-quotient` primitive with argument validation and"
      "Consent Scheme values."
      (integer-quotient arguments floor-quotient "floor-quotient"))

    (define (primitive-truncate-quotient arguments context)
      "Implement the `truncate-quotient` primitive with argument validation and"
      "Consent Scheme values."
      (integer-quotient arguments truncate-quotient-value "truncate-quotient"))

    (define (primitive-remainder arguments context)
      "Implement the `remainder` primitive with argument validation and Consent"
      "Scheme values."
      (let ((left (exact-integer->host (car arguments) "remainder"))
            (right (exact-integer->host (second arguments) "remainder")))
        (if (zero? right)
            (eval-error "remainder division by zero"))
        (consent-make-canonical-integer
         (truncate-remainder-value left right))))

    (define (primitive-modulo arguments context)
      "Implement the `modulo` primitive with argument validation and Consent"
      "Scheme values."
      (let ((left (exact-integer->host (car arguments) "modulo"))
            (right (exact-integer->host (second arguments) "modulo")))
        (if (zero? right)
            (eval-error "modulo division by zero"))
        (consent-make-canonical-integer
         (floor-remainder left right))))

    (define (primitive-floor-remainder arguments context)
      "Implement the `floor-remainder` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-modulo arguments context))

    (define (primitive-truncate-remainder arguments context)
      "Implement the `truncate-remainder` primitive with argument validation"
      "and Consent Scheme values."
      (primitive-remainder arguments context))

    (define (floor-rational-pair pair)
      "Return the mathematical floor of a rational pair."
      (floor-quotient (car pair) (cdr pair)))

    (define (ceiling-rational-pair pair)
      "Return the mathematical ceiling of a rational pair."
      (- (floor-quotient (- (car pair)) (cdr pair))))

    (define (truncate-rational-pair pair)
      "Return a rational pair rounded toward zero."
      (let* ((numerator (car pair))
             (denominator (cdr pair))
             (quotient (quotient (abs numerator) denominator)))
        (if (< numerator 0) (- quotient) quotient)))

    (define (round-rational-pair pair)
      "Return a rational pair rounded using Scheme's ties-to-even rule."
      (let* ((numerator (car pair))
             (denominator (cdr pair))
             (sign (if (< numerator 0) -1 1))
             (absolute (abs numerator))
             (quotient (quotient absolute denominator))
             (remainder (modulo absolute denominator))
             (twice (* 2 remainder))
             (rounded
              (cond
               ((< twice denominator) quotient)
               ((> twice denominator) (+ quotient 1))
               ((even? quotient) quotient)
               (else (+ quotient 1)))))
        (* sign rounded)))

    (define (primitive-rounding arguments function description)
      "Implement the `rounding` primitive with argument validation and Consent"
      "Scheme values."
      (let ((number
             (number-real-part-for-ordering (car arguments) description)))
        (cond
         ((or (eq? (consent-number-kind number) 'integer)
              (eq? (consent-number-kind number) 'rational))
          (consent-make-canonical-integer
           (function (number->rational-pair number description))))
         ((eq? (consent-number-kind number) 'decimal)
          (consent-make-canonical-decimal
           (inexact
            (function (decimal->exact-rational-pair number)))))
         ((eq? (consent-number-kind number) 'infnan)
          number))))

    (define (primitive-floor arguments context)
      "Implement the `floor` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-rounding arguments floor-rational-pair "floor"))

    (define (primitive-ceiling arguments context)
      "Implement the `ceiling` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-rounding arguments ceiling-rational-pair "ceiling"))

    (define (primitive-truncate arguments context)
      "Implement the `truncate` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-rounding arguments truncate-rational-pair "truncate"))

    (define (primitive-round arguments context)
      "Implement the `round` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-rounding arguments round-rational-pair "round"))

    (define (integer-argument datum description)
      "Return DATUM as a host integer, accepting exact and inexact integers."
      (let ((number (expect-number datum description)))
        (cond
         ((and (number-exact? number) (number-integer? number))
          (car (number->rational-pair number description)))
         ((and (number-inexact? number) (number-integer? number))
          (truncate (number->host-float number description)))
         (else
          (eval-error
           (string-append description " expected integer")
           datum)))))

    (define (integer-gcd left right)
      "Compute the nonnegative greatest common divisor for exact integers."
      (let loop ((a (abs left)) (b (abs right)))
        (if (zero? b) a (loop b (modulo a b)))))

    (define (integer-power base exponent)
      "Compute BASE raised to nonnegative EXPONENT for reader number parsing."
      (let loop ((result 1) (factor base) (power exponent))
        (cond
         ((zero? power) result)
         ((odd? power)
          (loop (* result factor) (* factor factor) (quotient power 2)))
         (else
          (loop result (* factor factor) (quotient power 2))))))

    (define (primitive-gcd arguments context)
      "Implement the `gcd` primitive with argument validation and Consent Scheme values."
      (let loop ((rest (numeric-arguments arguments "gcd"))
                 (result 0)
                 (inexact? #f))
        (if (null? rest)
            (let ((value (consent-make-canonical-integer result)))
              (if inexact? (number-inexact value) value))
            (loop (cdr rest)
                  (integer-gcd result (integer-argument (car rest) "gcd"))
                  (or inexact? (number-inexact? (car rest)))))))

    (define (primitive-lcm arguments context)
      "Implement the `lcm` primitive with argument validation and Consent Scheme values."
      (let loop ((rest (numeric-arguments arguments "lcm"))
                 (result 1)
                 (inexact? #f))
        (if (null? rest)
            (let ((value (consent-make-canonical-integer result)))
              (if inexact? (number-inexact value) value))
            (let ((value (abs (integer-argument (car rest) "lcm"))))
              (loop (cdr rest)
                    (if (or (zero? result) (zero? value))
                        0
                        (quotient (* result value)
                                  (integer-gcd result value)))
                    (or inexact? (number-inexact? (car rest))))))))

    (define (primitive-numerator arguments context)
      "Implement the `numerator` primitive with argument validation and Consent"
      "Scheme values."
      (let* ((number (expect-number (car arguments) "numerator"))
             (pair (if (number-inexact? number)
                       (decimal->exact-rational-pair number)
                       (number->rational-pair number "numerator")))
             (value (consent-make-canonical-integer (car pair))))
        (if (number-inexact? number) (number-inexact value) value)))

    (define (primitive-denominator arguments context)
      "Implement the `denominator` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((number (expect-number (car arguments) "denominator"))
             (pair (if (number-inexact? number)
                       (decimal->exact-rational-pair number)
                       (number->rational-pair number "denominator")))
             (value (consent-make-canonical-integer (cdr pair))))
        (if (number-inexact? number) (number-inexact value) value)))

    (define (primitive-exact arguments context)
      "Implement the `exact` primitive with argument validation and Consent"
      "Scheme values."
      (number-exact (car arguments)))

    (define (primitive-inexact arguments context)
      "Implement the `inexact` primitive with argument validation and Consent"
      "Scheme values."
      (number-inexact (car arguments)))

    (define (primitive-expt arguments context)
      "Implement the `expt` primitive with argument validation and Consent Scheme values."
      (let ((base (expect-number (car arguments) "expt"))
            (power (expect-number (second arguments) "expt")))
        (if (and (number-exact? base)
                 (number-exact? power)
                 (number-integer? power)
                 (not (number-complex-representation? base)))
            (let* ((base-pair (number->rational-pair base "expt"))
                   (exponent
                    (car (number->rational-pair power "expt")))
                   (numerator
                    (integer-power (car base-pair) (abs exponent)))
                   (denominator
                    (integer-power (cdr base-pair) (abs exponent))))
              (if (>= exponent 0)
                  (number-from-rational-pair
                   (cons numerator denominator))
                  (number-from-rational-pair
                   (cons denominator numerator))))
            (consent-make-canonical-decimal
             (expt (number->host-float base "expt")
                   (number->host-float power "expt"))))))

    (define (primitive-inexact-unary arguments function description)
      "Implement the `inexact-unary` primitive with argument validation and"
      "Consent Scheme values."
      (consent-make-canonical-decimal
       (function (number->host-float (car arguments) description))))

    (define (primitive-exp arguments context)
      "Implement the `exp` primitive with argument validation and Consent Scheme values."
      (primitive-inexact-unary arguments exp "exp"))

    (define (primitive-log arguments context)
      "Implement the `log` primitive with argument validation and Consent Scheme values."
      (let ((value (primitive-inexact-unary (list (car arguments))
                                            log
                                            "log")))
        (if (null? (cdr arguments))
            value
            (let ((base (primitive-inexact-unary
                         (list (second arguments))
                         log
                         "log")))
              (primitive/ (list value base) context)))))

    (define (primitive-sin arguments context)
      "Implement the `sin` primitive with argument validation and Consent Scheme values."
      (primitive-inexact-unary arguments sin "sin"))

    (define (primitive-cos arguments context)
      "Implement the `cos` primitive with argument validation and Consent Scheme values."
      (primitive-inexact-unary arguments cos "cos"))

    (define (primitive-tan arguments context)
      "Implement the `tan` primitive with argument validation and Consent Scheme values."
      (primitive-inexact-unary arguments tan "tan"))

    (define (primitive-asin arguments context)
      "Implement the `asin` primitive with argument validation and Consent Scheme values."
      (primitive-inexact-unary arguments asin "asin"))

    (define (primitive-acos arguments context)
      "Implement the `acos` primitive with argument validation and Consent Scheme values."
      (primitive-inexact-unary arguments acos "acos"))

    (define (primitive-atan arguments context)
      "Implement the `atan` primitive with argument validation and Consent Scheme values."
      (if (null? (cdr arguments))
          (primitive-inexact-unary arguments atan "atan")
          (consent-make-canonical-decimal
           (atan (number->host-float (car arguments) "atan")
                 (number->host-float (second arguments) "atan")))))

    (define (primitive-sqrt arguments context)
      "Implement the `sqrt` primitive with argument validation and Consent Scheme values."
      (let* ((number (expect-number (car arguments) "sqrt"))
             (value (number->host-float number "sqrt")))
        (if (and (not (number-complex-representation? number))
                 (< value 0.0))
            (consent-make-canonical-complex
             (consent-make-canonical-decimal 0.0)
             (consent-make-canonical-decimal (sqrt (- value))))
            (consent-make-canonical-decimal (sqrt value)))))

    (define (integer-sqrt value)
      "Return the greatest integer whose square is no larger than VALUE."
      (let loop ((low 0) (high (+ value 1)))
        (if (<= (- high low) 1)
            low
            (let ((mid (quotient (+ low high) 2)))
              (if (> (* mid mid) value)
                  (loop low mid)
                  (loop mid high))))))

    (define (primitive-exact-integer-sqrt arguments context)
      "Implement the `exact-integer-sqrt` primitive with argument validation"
      "and Consent Scheme values."
      (let ((value (exact-integer->host
                    (car arguments)
                    "exact-integer-sqrt")))
        (if (< value 0)
            (eval-error
             "exact-integer-sqrt expected non-negative integer"))
        (let ((root (integer-sqrt value)))
          (make-multiple-values
           (list (consent-make-canonical-integer root)
                 (consent-make-canonical-integer
                  (- value (* root root))))))))

    (define (primitive-floor/ arguments context)
      "Implement the `floor/` primitive with argument validation and Consent"
      "Scheme values."
      (let ((left (exact-integer->host (car arguments) "floor/"))
            (right (exact-integer->host (second arguments) "floor/")))
        (if (zero? right)
            (eval-error "floor/ division by zero"))
        (let* ((quotient (floor-quotient left right))
               (remainder (- left (* right quotient))))
          (make-multiple-values
           (list (consent-make-canonical-integer quotient)
                 (consent-make-canonical-integer remainder))))))

    (define (primitive-truncate/ arguments context)
      "Implement the `truncate/` primitive with argument validation and Consent"
      "Scheme values."
      (let ((left (exact-integer->host (car arguments) "truncate/"))
            (right (exact-integer->host (second arguments) "truncate/")))
        (if (zero? right)
            (eval-error "truncate/ division by zero"))
        (let* ((quotient (truncate-quotient-value left right))
               (remainder (- left (* right quotient))))
          (make-multiple-values
           (list (consent-make-canonical-integer quotient)
                 (consent-make-canonical-integer remainder))))))

    (define (rational-pair< left right)
      "Report whether rational pair LEFT is less than RIGHT."
      (< (* (car left) (cdr right))
         (* (car right) (cdr left))))

    (define (rational-pair-normalize pair)
      "Normalize a rational pair to positive denominator and lowest terms."
      (let* ((numerator (car pair))
             (denominator (cdr pair))
             (adjusted
              (if (< denominator 0)
                  (cons (- numerator) (- denominator))
                  pair))
             (divisor (integer-gcd (car adjusted) (cdr adjusted))))
        (cons (quotient (car adjusted) divisor)
              (quotient (cdr adjusted) divisor))))

    (define (rational-pair-negate pair)
      "Negate a rational pair without changing its denominator."
      (cons (- (car pair)) (cdr pair)))

    (define (rational-pair+ left right)
      "Add two rational pairs and normalize the result."
      (rational-pair-normalize
       (cons (+ (* (car left) (cdr right))
                (* (car right) (cdr left)))
             (* (cdr left) (cdr right)))))

    (define (rational-pair- left right)
      "Subtract RIGHT from LEFT as rational pairs."
      (rational-pair+ left (rational-pair-negate right)))

    (define (rational-pair-reciprocal pair)
      "Return the reciprocal of a rational pair in normalized form."
      (rational-pair-normalize (cons (cdr pair) (car pair))))

    (define (rational-pair-integer? pair)
      "Report whether a rational pair has denominator one."
      (= (cdr pair) 1))

    (define (simplest-positive-rational-pair lower upper)
      "Return the simplest nonnegative rational pair in [LOWER, UPPER]."
      (cond
       ((not (rational-pair< (cons 0 1) lower))
        (cons 0 1))
       ((rational-pair-integer? lower)
        lower)
       (else
        (let ((lower-floor (floor-quotient (car lower) (cdr lower)))
              (upper-floor (floor-quotient (car upper) (cdr upper))))
          (if (< lower-floor upper-floor)
              (cons (+ lower-floor 1) 1)
              (rational-pair+
               (cons lower-floor 1)
               (rational-pair-reciprocal
                (simplest-positive-rational-pair
                 (rational-pair-reciprocal
                  (rational-pair-
                   upper
                   (cons upper-floor 1)))
                 (rational-pair-reciprocal
                  (rational-pair-
                   lower
                   (cons lower-floor 1)))))))))))

    (define (simplest-rational-pair lower upper)
      "Return the simplest rational pair in the interval [LOWER, UPPER]."
      (cond
       ((rational-pair< upper lower)
        (eval-error "rationalize tolerance produced empty interval"))
       ((not (rational-pair< (cons 0 1) lower))
        (if (not (rational-pair< upper (cons 0 1)))
            (cons 0 1)
            (rational-pair-negate
             (simplest-positive-rational-pair
              (rational-pair-negate upper)
              (rational-pair-negate lower)))))
       (else
        (simplest-positive-rational-pair lower upper))))

    (define (rationalize-pair x y)
      "Return the rationalize result pair for X with tolerance Y."
      (simplest-rational-pair
       (rational-pair- x y)
       (rational-pair+ x y)))

    (define (primitive-rationalize arguments context)
      "Implement the `rationalize` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((x (expect-number (car arguments) "rationalize"))
             (y (expect-number (second arguments) "rationalize"))
             (inexact?
              (or (number-inexact? x) (number-inexact? y)))
             (x-pair
              (if (number-inexact? x)
                  (decimal->exact-rational-pair x)
                  (number->rational-pair x "rationalize")))
             (y-pair
              (if (number-inexact? y)
                  (decimal->exact-rational-pair y)
                  (number->rational-pair y "rationalize")))
             (result (rationalize-pair x-pair y-pair)))
        (if inexact?
            (number-inexact (number-from-rational-pair result))
            (number-from-rational-pair result))))

    (define (primitive-finite? arguments context)
      "Implement the `finite?` primitive with argument validation and Consent"
      "Scheme values."
      (number-finite? (expect-number (car arguments) "finite?")))

    (define (primitive-infinite? arguments context)
      "Implement the `infinite?` primitive with argument validation and Consent"
      "Scheme values."
      (number-infinite? (expect-number (car arguments) "infinite?")))

    (define (primitive-nan? arguments context)
      "Implement the `nan?` primitive with argument validation and Consent Scheme values."
      (number-nan? (expect-number (car arguments) "nan?")))

    (define (primitive-make-rectangular arguments context)
      "Implement the `make-rectangular` primitive with argument validation and"
      "Consent Scheme values."
      (consent-make-canonical-complex
       (expect-number (car arguments) "make-rectangular")
       (expect-number (second arguments) "make-rectangular")))

    (define (primitive-make-polar arguments context)
      "Implement the `make-polar` primitive with argument validation and"
      "Consent Scheme values."
      (let ((magnitude (number->host-float
                        (car arguments)
                        "make-polar"))
            (angle (number->host-float
                    (second arguments)
                    "make-polar")))
        (consent-make-canonical-complex
         (consent-make-canonical-decimal
          (* magnitude (cos angle)))
         (consent-make-canonical-decimal
          (* magnitude (sin angle))))))

    (define (primitive-real-part arguments context)
      "Implement the `real-part` primitive with argument validation and Consent"
      "Scheme values."
      (let ((number (expect-number (car arguments) "real-part")))
        (if (number-complex-representation? number)
            (car (consent-number-value number))
            number)))

    (define (primitive-imag-part arguments context)
      "Implement the `imag-part` primitive with argument validation and Consent"
      "Scheme values."
      (let ((number (expect-number (car arguments) "imag-part")))
        (if (number-complex-representation? number)
            (cdr (consent-number-value number))
            (consent-make-canonical-integer 0))))

    (define (primitive-magnitude arguments context)
      "Implement the `magnitude` primitive with argument validation and Consent"
      "Scheme values."
      (let ((number (expect-number (car arguments) "magnitude")))
        (if (number-complex-representation? number)
            (let* ((parts (consent-number-value number))
                   (real (number->host-float (car parts) "magnitude"))
                   (imaginary (number->host-float
                               (cdr parts)
                               "magnitude")))
              (consent-make-canonical-decimal
               (sqrt (+ (* real real) (* imaginary imaginary)))))
            (consent-number-abs number))))

    (define (primitive-angle arguments context)
      "Implement the `angle` primitive with argument validation and Consent"
      "Scheme values."
      (let ((number (expect-number (car arguments) "angle")))
        (if (number-complex-representation? number)
            (let* ((parts (consent-number-value number))
                   (real (number->host-float (car parts) "angle"))
                   (imaginary (number->host-float
                               (cdr parts)
                               "angle")))
              (consent-make-canonical-decimal (atan imaginary real)))
            (if (consent-number-negative? number)
                (consent-make-canonical-decimal 3.141592653589793)
                (consent-make-canonical-decimal 0.0)))))

    (define (primitive-cons arguments context)
      "Implement the `cons` primitive with argument validation and Consent Scheme values."
      ;; One fresh pair; its car/cdr were charged where they were allocated.
      ;; Charging `cons' charges every prelude list builder (list, append,
      ;; reverse, map, ...) that conses, with no walk of the growing result.
      (charge-value-allocation!
       (cons (car arguments) (second arguments))
       1
       context))

    (define (primitive-car arguments context)
      "Implement the `car` primitive with argument validation and Consent Scheme values."
      (let ((pair (car arguments)))
        (if (pair? pair)
            (car pair)
            (eval-error "car expected pair" pair))))

    (define (primitive-cdr arguments context)
      "Implement the `cdr` primitive with argument validation and Consent Scheme values."
      (let ((pair (car arguments)))
        (if (pair? pair)
            (cdr pair)
            (eval-error "cdr expected pair" pair))))

    (define (primitive-list arguments context)
      "Implement the `list` primitive with argument validation and Consent Scheme values."
      arguments)

    (define (proper-list? value)
      "Report whether VALUE is a proper, acyclic list."
      (let loop ((cursor value) (seen '()))
        (cond
         ((null? cursor) #t)
         ((not (pair? cursor)) #f)
         ((memq cursor seen) #f)
         (else (loop (cdr cursor) (cons cursor seen))))))

    (define (primitive-list? arguments context)
      "Implement the `list?` primitive with argument validation and Consent"
      "Scheme values."
      (proper-list? (car arguments)))

    (define (primitive-length arguments context)
      "Implement the `length` primitive with argument validation and Consent"
      "Scheme values."
      (length (proper-list-elements (car arguments) "length")))

    (define (primitive-append arguments context)
      "Implement the `append` primitive with argument validation and Consent"
      "Scheme values."
      (apply append arguments))

    (define (primitive-reverse arguments context)
      "Implement the `reverse` primitive with argument validation and Consent"
      "Scheme values."
      (reverse (proper-list-elements (car arguments) "reverse")))

    (define (primitive-list-tail arguments context)
      "Implement the `list-tail` primitive with argument validation and Consent"
      "Scheme values."
      (let ((index (exact-integer->host (second arguments) "list-tail")))
        (if (< index 0)
            (eval-error "list-tail index must be non-negative"))
        (let loop ((cursor (car arguments)) (remaining index))
          (cond
           ((zero? remaining) cursor)
           ((pair? cursor) (loop (cdr cursor) (- remaining 1)))
           (else (eval-error "list-tail index exceeds list length"))))))

    (define (primitive-list-ref arguments context)
      "Implement the `list-ref` primitive with argument validation and Consent"
      "Scheme values."
      (let ((tail (primitive-list-tail arguments context)))
        (if (pair? tail)
            (car tail)
            (eval-error "list-ref index exceeds list length"))))

    (define (primitive-list-set! arguments context)
      "Implement the `list-set!` primitive with argument validation and Consent"
      "Scheme values."
      (let ((tail (primitive-list-tail arguments context)))
        (if (not (pair? tail))
            (eval-error "list-set! index exceeds list length"))
        (set-car! tail (third arguments))
        consent-unspecified))

    (define (primitive-set-car! arguments context)
      "Implement the `set-car!` primitive with argument validation and Consent"
      "Scheme values."
      (let ((pair (car arguments)))
        (if (not (pair? pair))
            (eval-error "set-car! expected pair" pair))
        (set-car! pair (second arguments))
        consent-unspecified))

    (define (primitive-set-cdr! arguments context)
      "Implement the `set-cdr!` primitive with argument validation and Consent"
      "Scheme values."
      (let ((pair (car arguments)))
        (if (not (pair? pair))
            (eval-error "set-cdr! expected pair" pair))
        (set-cdr! pair (second arguments))
        consent-unspecified))

    (define (primitive-make-list arguments context)
      "Implement the `make-list` primitive with argument validation and Consent"
      "Scheme values."
      (let ((length (exact-integer->host (car arguments) "make-list"))
            (fill (if (null? (cdr arguments))
                      consent-unspecified
                      (second arguments))))
        (if (< length 0)
            (eval-error "make-list length must be non-negative"))
        (make-list length fill)))

    (define (copy-list value)
      "Copy a pair spine while preserving any improper tail."
      (cond
       ((null? value) '())
       ((pair? value) (cons (car value) (copy-list (cdr value))))
       (else value)))

    (define (primitive-list-copy arguments context)
      "Implement the `list-copy` primitive with argument validation and Consent"
      "Scheme values."
      (copy-list (car arguments)))

    (define (primitive-caar arguments context)
      "Implement the `caar` primitive with argument validation and Consent Scheme values."
      (primitive-car (list (primitive-car arguments context)) context))

    (define (primitive-cadr arguments context)
      "Implement the `cadr` primitive with argument validation and Consent Scheme values."
      (primitive-car (list (primitive-cdr arguments context)) context))

    (define (primitive-cdar arguments context)
      "Implement the `cdar` primitive with argument validation and Consent Scheme values."
      (primitive-cdr (list (primitive-car arguments context)) context))

    (define (primitive-cddr arguments context)
      "Implement the `cddr` primitive with argument validation and Consent Scheme values."
      (primitive-cdr (list (primitive-cdr arguments context)) context))

    (define (primitive-null? arguments context)
      "Implement the `null?` primitive with argument validation and Consent"
      "Scheme values."
      (null? (car arguments)))

    (define (primitive-pair? arguments context)
      "Implement the `pair?` primitive with argument validation and Consent"
      "Scheme values."
      (pair? (car arguments)))

    (define (primitive-not arguments context)
      "Implement the `not` primitive with argument validation and Consent Scheme values."
      (if (eq? (car arguments) #f) #t #f))

    (define (primitive-boolean? arguments context)
      "Implement the `boolean?` primitive with argument validation and Consent"
      "Scheme values."
      (boolean? (car arguments)))

    (define (primitive-boolean=? arguments context)
      "Implement the `boolean=?` primitive with argument validation and Consent"
      "Scheme values."
      (let ((first (car arguments)))
        (if (not (boolean? first))
            (eval-error "boolean=? expected booleans"))
        (let loop ((rest (cdr arguments)))
          (cond
           ((null? rest) #t)
           ((not (boolean? (car rest)))
            (eval-error "boolean=? expected booleans"))
           ((eq? first (car rest)) (loop (cdr rest)))
           (else #f)))))

    (define (primitive-number? arguments context)
      "Implement the `number?` primitive with argument validation and Consent"
      "Scheme values."
      (consent-number? (car arguments)))

    (define (primitive-complex? arguments context)
      "Implement the `complex?` primitive with argument validation and Consent"
      "Scheme values."
      (consent-number? (car arguments)))

    (define (primitive-real? arguments context)
      "Implement the `real?` primitive with argument validation and Consent"
      "Scheme values."
      (number-real? (car arguments)))

    (define (primitive-rational? arguments context)
      "Implement the `rational?` primitive with argument validation and Consent"
      "Scheme values."
      (number-rational? (car arguments)))

    (define (primitive-integer? arguments context)
      "Implement the `integer?` primitive with argument validation and Consent"
      "Scheme values."
      (number-integer? (car arguments)))

    (define (primitive-exact-integer? arguments context)
      "Implement the `exact-integer?` primitive with argument validation and"
      "Consent Scheme values."
      (and (number-integer? (car arguments))
           (number-exact? (car arguments))))

    (define (primitive-exact? arguments context)
      "Implement the `exact?` primitive with argument validation and Consent"
      "Scheme values."
      (number-exact? (car arguments)))

    (define (primitive-inexact? arguments context)
      "Implement the `inexact?` primitive with argument validation and Consent"
      "Scheme values."
      (number-inexact? (car arguments)))

    (define (number->string/radix number radix)
      "Render NUMBER using RADIX for exact integers and rationals."
      (cond
       ((eq? (consent-number-kind number) 'integer)
        (consent-integer->radix-string
         (consent-number-value number)
         radix))
       ((eq? (consent-number-kind number) 'rational)
        (let ((value (consent-number-value number)))
          (string-append
           (consent-integer->radix-string (car value) radix)
           "/"
           (consent-integer->radix-string (cdr value) radix))))
       ((or (eq? (consent-number-kind number) 'decimal)
            (eq? (consent-number-kind number) 'infnan))
        (if (not (= radix 10))
            (eval-error
             "number->string only supports radix 10 for inexact numbers"))
        (consent-number->external number))
       ((eq? (consent-number-kind number) 'complex)
        (if (not (= radix 10))
            (eval-error
             "number->string only supports radix 10 for complex numbers"))
        (consent-number->external number))))

    (define (primitive-number->string arguments context)
      "Implement the `number->string` primitive with argument validation and"
      "Consent Scheme values."
      (let ((number (expect-number (car arguments) "number->string"))
            (radix (if (null? (cdr arguments))
                       10
                       (exact-integer->host
                        (second arguments)
                        "number->string radix"))))
        (if (not (or (= radix 2) (= radix 8) (= radix 10) (= radix 16)))
            (eval-error "number->string radix must be 2, 8, 10, or 16"))
        (charge-string-allocation! (number->string/radix number radix) context)))

    (define (explicit-number-prefix? text)
      "Report whether TEXT begins with an explicit reader radix/exactness prefix."
      (and (>= (string-length text) 2)
           (char=? (string-ref text 0) #\#)
           (let ((marker (char-downcase (string-ref text 1))))
             (or (char=? marker #\b)
                 (char=? marker #\o)
                 (char=? marker #\d)
                 (char=? marker #\x)
                 (char=? marker #\e)
                 (char=? marker #\i)))))

    (define (primitive-string->number arguments context)
      "Implement the `string->number` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((source-text (expect-string (car arguments) "string->number"))
             (radix (if (null? (cdr arguments))
                        10
                        (exact-integer->host
                         (second arguments)
                         "string->number radix")))
             (source
              (if (or (null? (cdr arguments))
                      (explicit-number-prefix? source-text))
                  source-text
                  (string-append
                   (cond
                    ((= radix 2) "#b")
                    ((= radix 8) "#o")
                    ((= radix 10) "#d")
                    ((= radix 16) "#x")
                    (else
                     (eval-error
                      "string->number radix must be 2, 8, 10, or 16")))
                   source-text))))
        (guard (condition
                (else #f))
          (let ((datum (consent-read source '((source-metadata . #f)))))
            (if (consent-number? datum)
                datum
                #f)))))

    (define (primitive-string->utf8 arguments context)
      "Implement the `string->utf8` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "string->utf8"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string->utf8")))
        (charge-bytevector-allocation!
         (string->utf8 (substring string (car range) (cdr range)))
         context)))

    (define (primitive-utf8->string arguments context)
      "Implement the `utf8->string` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((bytes (expect-bytevector (car arguments) "utf8->string"))
             (range (optional-range
                     arguments
                     1
                     (bytevector-length bytes)
                     "utf8->string")))
        (charge-string-allocation!
         (utf8->string bytes (car range) (cdr range))
         context)))

    (define (primitive-symbol? arguments context)
      "Implement the `symbol?` primitive with argument validation and Consent"
      "Scheme values."
      (symbol? (car arguments)))

    (define (primitive-symbol->string arguments context)
      "Implement the `symbol->string` primitive with argument validation and"
      "Consent Scheme values."
      (if (not (symbol? (car arguments)))
          (eval-error "symbol->string expected a symbol"))
      (charge-string-allocation! (symbol->string (car arguments)) context))

    (define (primitive-string->symbol arguments context)
      "Implement the `string->symbol` primitive with argument validation and"
      "Consent Scheme values. The interned-symbol budget is charged before the"
      "name is interned so a flood of distinct names fails closed on its own"
      "dimension rather than relying on the step budget as a proxy."
      (let ((name (expect-string (car arguments) "string->symbol")))
        (note-interned-symbol! context)
        (string->symbol name)))

    (define (primitive-symbol=? arguments context)
      "Implement the `symbol=?` primitive with argument validation and Consent"
      "Scheme values."
      (let ((first (car arguments)))
        (if (not (symbol? first))
            (eval-error "symbol=? expected symbols"))
        (let loop ((rest (cdr arguments)))
          (cond
           ((null? rest) #t)
           ((not (symbol? (car rest)))
            (eval-error "symbol=? expected symbols"))
           ((eq? first (car rest)) (loop (cdr rest)))
           (else #f)))))

    (define (primitive-char? arguments context)
      "Implement the `char?` primitive with argument validation and Consent"
      "Scheme values."
      (char? (car arguments)))

    (define (primitive-char->integer arguments context)
      "Implement the `char->integer` primitive with argument validation and"
      "Consent Scheme values."
      (consent-make-canonical-integer
       (char->integer
        (expect-character (car arguments) "char->integer"))))

    (define (primitive-integer->char arguments context)
      "Implement the `integer->char` primitive with argument validation and"
      "Consent Scheme values."
      (integer->char
       (exact-integer->host (car arguments) "integer->char")))

    (define (primitive-char-compare arguments predicate description)
      "Implement the `char-compare` primitive with argument validation and"
      "Consent Scheme values."
      (let loop ((rest arguments))
        (cond
         ((or (null? rest) (null? (cdr rest))) #t)
         (else
          (let ((left (expect-character (car rest) description))
                (right (expect-character (second rest) description)))
            (and (predicate left right) (loop (cdr rest))))))))

    (define (primitive-char=? arguments context)
      "Implement the `char=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-compare arguments char=? "char=?"))

    (define (primitive-char<? arguments context)
      "Implement the `char<?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-compare arguments char<? "char<?"))

    (define (primitive-char>? arguments context)
      "Implement the `char>?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-compare arguments char>? "char>?"))

    (define (primitive-char<=? arguments context)
      "Implement the `char<=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-compare arguments char<=? "char<=?"))

    (define (primitive-char>=? arguments context)
      "Implement the `char>=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-compare arguments char>=? "char>=?"))

    (define (primitive-char-upcase arguments context)
      "Implement the `char-upcase` primitive with argument validation and"
      "Consent Scheme values."
      (char-upcase (expect-character (car arguments) "char-upcase")))

    (define (primitive-char-downcase arguments context)
      "Implement the `char-downcase` primitive with argument validation and"
      "Consent Scheme values."
      (char-downcase (expect-character (car arguments) "char-downcase")))

    (define (primitive-char-foldcase arguments context)
      "Implement the `char-foldcase` primitive with argument validation and"
      "Consent Scheme values."
      (char-foldcase (expect-character (car arguments) "char-foldcase")))

    (define (primitive-char-alphabetic? arguments context)
      "Implement the `char-alphabetic?` primitive with argument validation and"
      "Consent Scheme values."
      (char-alphabetic? (expect-character
                         (car arguments)
                         "char-alphabetic?")))

    (define (primitive-char-numeric? arguments context)
      "Implement the `char-numeric?` primitive with argument validation and"
      "Consent Scheme values."
      (char-numeric? (expect-character (car arguments) "char-numeric?")))

    (define (primitive-char-whitespace? arguments context)
      "Implement the `char-whitespace?` primitive with argument validation and"
      "Consent Scheme values."
      (char-whitespace? (expect-character
                         (car arguments)
                         "char-whitespace?")))

    (define (primitive-char-upper-case? arguments context)
      "Implement the `char-upper-case?` primitive with argument validation and"
      "Consent Scheme values."
      (char-upper-case? (expect-character
                         (car arguments)
                         "char-upper-case?")))

    (define (primitive-char-lower-case? arguments context)
      "Implement the `char-lower-case?` primitive with argument validation and"
      "Consent Scheme values."
      (char-lower-case? (expect-character
                         (car arguments)
                         "char-lower-case?")))

    (define (primitive-digit-value arguments context)
      "Implement the `digit-value` primitive with argument validation and"
      "Consent Scheme values."
      (let ((value (digit-value
                    (expect-character (car arguments) "digit-value"))))
        (if value
            (consent-make-canonical-integer value)
            #f)))

    (define (primitive-char-ci-compare arguments predicate description)
      "Implement the `char-ci-compare` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-char-compare
       arguments
       (lambda (left right)
         (predicate (char-foldcase left) (char-foldcase right)))
       description))

    (define (primitive-char-ci=? arguments context)
      "Implement the `char-ci=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-ci-compare arguments char=? "char-ci=?"))

    (define (primitive-char-ci<? arguments context)
      "Implement the `char-ci<?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-ci-compare arguments char<? "char-ci<?"))

    (define (primitive-char-ci>? arguments context)
      "Implement the `char-ci>?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-char-ci-compare arguments char>? "char-ci>?"))

    (define (primitive-char-ci<=? arguments context)
      "Implement the `char-ci<=?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-char-ci-compare arguments char<=? "char-ci<=?"))

    (define (primitive-char-ci>=? arguments context)
      "Implement the `char-ci>=?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-char-ci-compare arguments char>=? "char-ci>=?"))

    (define (primitive-string-upcase arguments context)
      "Implement the `string-upcase` primitive with argument validation and"
      "Consent Scheme values."
      (string-upcase (expect-string (car arguments) "string-upcase")))

    (define (primitive-string-downcase arguments context)
      "Implement the `string-downcase` primitive with argument validation and"
      "Consent Scheme values."
      (string-downcase (expect-string (car arguments) "string-downcase")))

    (define (primitive-string-foldcase arguments context)
      "Implement the `string-foldcase` primitive with argument validation and"
      "Consent Scheme values."
      (string-foldcase (expect-string (car arguments) "string-foldcase")))

    (define (primitive-string-ci-compare arguments predicate description)
      "Implement the `string-ci-compare` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-string-compare
       arguments
       (lambda (left right)
         (predicate (string-foldcase left) (string-foldcase right)))
       description))

    (define (primitive-string-ci=? arguments context)
      "Implement the `string-ci=?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-string-ci-compare arguments string=? "string-ci=?"))

    (define (primitive-string-ci<? arguments context)
      "Implement the `string-ci<?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-string-ci-compare arguments string<? "string-ci<?"))

    (define (primitive-string-ci>? arguments context)
      "Implement the `string-ci>?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-string-ci-compare arguments string>? "string-ci>?"))

    (define (primitive-string-ci<=? arguments context)
      "Implement the `string-ci<=?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-string-ci-compare arguments string<=? "string-ci<=?"))

    (define (primitive-string-ci>=? arguments context)
      "Implement the `string-ci>=?` primitive with argument validation and"
      "Consent Scheme values."
      (primitive-string-ci-compare arguments string>=? "string-ci>=?"))

    (define (display-string value)
      "Render VALUE for display output rather than write output."
      (consent-datum->external value 'write #t))

    (define (expect-port value description)
      "Validate port input and raise an evaluator error on mismatch."
      (if (not (consent-port? value))
          (eval-error (string-append description " expected a port") value))
      value)

    (define (expect-open-port value description)
      "Validate open port input and raise an evaluator error on mismatch."
      (let ((port (expect-port value description)))
        (if (not (consent-port-open? port))
            (if (consent-port-backing-domain port)
                (eval-error "stale port capability handle: closed port")
                (eval-error
                 (string-append description " expected an open port")
                 value)))
        port))

    (define (expect-input-port value description)
      "Validate input port input and raise an evaluator error on mismatch."
      (let ((port (expect-open-port value description)))
        (if (not (consent-port-input? port))
            (eval-error
             (string-append description " expected an input port")
             value))
        port))

    (define (expect-output-port value description)
      "Validate output port input and raise an evaluator error on mismatch."
      (let ((port (expect-open-port value description)))
        (if (not (consent-port-output? port))
            (eval-error
             (string-append description " expected an output port")
             value))
        port))

    (define (expect-textual-input-port value description)
      "Validate textual input port input and raise an evaluator error on mismatch."
      (let ((port (expect-input-port value description)))
        (if (not (consent-port-textual? port))
            (eval-error
             (string-append description " expected a textual input port")
             value))
        port))

    (define (expect-textual-output-port value description)
      "Validate textual output port input and raise an evaluator error on mismatch."
      (let ((port (expect-output-port value description)))
        (if (not (consent-port-textual? port))
            (eval-error
             (string-append description " expected a textual output port")
             value))
        port))

    (define (expect-binary-input-port value description)
      "Validate binary input port input and raise an evaluator error on mismatch."
      (let ((port (expect-input-port value description)))
        (if (not (consent-port-binary? port))
            (eval-error
             (string-append description " expected a binary input port")
             value))
        port))

    (define (expect-binary-output-port value description)
      "Validate binary output port input and raise an evaluator error on mismatch."
      (let ((port (expect-output-port value description)))
        (if (not (consent-port-binary? port))
            (eval-error
             (string-append description " expected a binary output port")
             value))
        port))

    (define (expect-string-output-port value description)
      "Validate string output port input and raise an evaluator error on mismatch."
      (let ((port (expect-textual-output-port value description)))
        (if (not (eq? (consent-port-medium port) 'string))
            (eval-error
             (string-append description " expected an output string port")
             value))
        port))

    (define (expect-bytevector-output-port value description)
      "Validate bytevector output port input and raise an evaluator error on mismatch."
      (let ((port (expect-binary-output-port value description)))
        (if (not (eq? (consent-port-medium port) 'bytevector))
            (eval-error
             (string-append description
                            " expected an output bytevector port")
             value))
        port))

    (define (capability-grant-field-values grant field)
      "Return FIELD values from a capability grant datum."
      (let ((entry (capability-grant-field grant field)))
        (if entry (cdr entry) '())))

    (define (capability-grant-field-value grant field)
      "Return FIELD's first value from a capability grant datum."
      (let ((values (capability-grant-field-values grant field)))
        (if (null? values) #f (car values))))

    (define (authorization-field authorization field)
      "Return FIELD from an authorization alist."
      (let ((entry (assq field authorization)))
        (if entry (second entry) #f)))

    (define (port-capability-handle-id)
      "Allocate a fresh Scheme-readable port capability handle id."
      (set! next-port-capability-handle-number
            (+ next-port-capability-handle-number 1))
      (string->symbol
       (string-append
        "p-file-"
        (number->string next-port-capability-handle-number))))

    (define (port-capability-datum
             handle kind backing operations grant limits status path)
      "Return a Scheme-readable host-backed port capability handle datum."
      (list 'port-capability
            (list 'id handle)
            (list 'kind kind)
            (list 'backing backing)
            (cons 'operations operations)
            (list 'grant grant)
            (cons 'limits limits)
            (list 'path path)
            (list 'status status)))

    (define (register-file-port! context port kind)
      "Record the creation of host-backed PORT's capability handle."
      (record-audit-event!
       context
       'capability-handle
       (list
        (list 'handle
              (port-capability-datum
               (consent-port-handle port)
               kind
               'file
               (consent-port-operations port)
               (consent-port-grant port)
               (consent-port-limits port)
               (consent-port-status port)
               (consent-port-path port)))
        (list 'domain 'port)
        (list 'kind kind)
        (list 'backing 'file)
        (cons 'operations (consent-port-operations port))
        (list 'grant (consent-port-grant port))
        (cons 'limits (consent-port-limits port))
        (list 'path (consent-port-path port))
        (list 'status 'open)))
      port)

    (define (audit-port-capability-result!
             context port operation result error?)
      "Record the result of a host-backed port capability operation."
      "A byte/character count is wrapped as a canonical integer so the audit"
      "datum stays Scheme-readable -- the evaluation-result `events' field"
      "carries these, and a host integer there would not render through the"
      "consent writer."
      (if (and context (consent-port-backing-domain port))
          (record-audit-event!
           context
           'capability-audit
           (list (list 'domain 'port)
                 (list 'operation operation)
                 (list 'handle (consent-port-handle port))
                 (list 'backing (consent-port-backing-domain port))
                 (list 'grant (consent-port-grant port))
                 (list 'path (consent-port-path port))
                 (list 'result
                       (if error?
                           (list 'error result)
                           (list 'ok (if (integer? result)
                                         (consent-make-canonical-integer result)
                                         result))))))))

    (define (port-capability-limit-name operation)
      "Return the named operation counter limit for OPERATION."
      (cond
       ((eq? operation 'read) 'reads)
       ((eq? operation 'write) 'writes)
       ((eq? operation 'flush) 'flushes)
       ((eq? operation 'close) 'closes)
       (else #f)))

    (define (port-capability-limit-value port name)
      "Return PORT limit NAME as a host integer, or #f when unlimited."
      (let ((field (and name (assq name (consent-port-limits port)))))
        (if field
            (exact-integer->host
             (second field)
             (string-append
              "port capability limit "
              (symbol->string name)))
            #f)))

    (define (port-capability-counter port name)
      "Return PORT's consumed counter for NAME."
      (let ((entry (assq name (consent-port-counters port))))
        (if entry (cdr entry) 0)))

    (define (set-port-capability-counter! port name value)
      "Store PORT's consumed counter for NAME."
      (let loop ((counters (consent-port-counters port)) (kept '()))
        (cond
         ((null? counters)
          (set-consent-port-counters!
           port
           (cons (cons name value) (reverse kept))))
         ((eq? (caar counters) name)
          (set-consent-port-counters!
           port
           (append (reverse kept)
                   (cons (cons name value) (cdr counters)))))
         (else
          (loop (cdr counters) (cons (car counters) kept))))))

    (define (check-port-capability-limit! context port operation)
      "Consume one PORT operation limit unit for OPERATION."
      (let* ((name (port-capability-limit-name operation))
             (limit (port-capability-limit-value port name)))
        (if limit
            (let ((used (port-capability-counter port name)))
              (if (>= used limit)
                  (begin
                    (audit-port-capability-result!
                     context
                     port
                     operation
                     (string-append
                      "port capability limit exceeded: "
                      (symbol->string name))
                     #t)
                    (eval-error
                     (string-append
                      "port capability limit exceeded: "
                      (symbol->string name)))))
              (set-port-capability-counter! port name (+ used 1))))))

    (define (revalidate-port-operation! port context operation)
      "Fail closed unless host-backed PORT can perform OPERATION in CONTEXT."
      (if (consent-port-backing-domain port)
          (cond
           ((not (consent-port-open? port))
            (audit-port-capability-result!
             context port operation "closed port capability handle" #t)
            (eval-error "stale port capability handle: closed port"))
           ((not (memq operation (consent-port-operations port)))
            (audit-port-capability-result!
             context port operation "operation outside port capability" #t)
            (eval-error "operation outside port capability"))
           (else
            (let ((grant
                   (and context
                        (capability-grant-find
                         (context-capability-grants context)
                         (consent-port-grant port)))))
              (if (not (and grant
                            (eq? (capability-grant-status grant) 'active)))
                  (begin
                    (audit-port-capability-result!
                     context
                     port
                     operation
                     "inactive port capability grant"
                     #t)
                    (eval-error
                     "stale port capability handle: inactive grant")))
              (check-port-capability-limit! context port operation)))))
      port)

    (define (current-input-port-or-deny context description)
      "Return CONTEXT's current input port or deny host default access."
      (or (and context (context-current-input-port context))
          (policy-denied description context '())))

    (define (current-output-port-or-deny context description)
      "Return CONTEXT's current output port or deny host default access."
      (or (and context (context-current-output-port context))
          (policy-denied description context '())))

    (define (current-error-port-or-deny context description)
      "Return CONTEXT's current error port or deny host default access."
      (or (and context (context-current-error-port context))
          (policy-denied description context '())))

    (define (primitive-current-input-port arguments context)
      "Implement the `current-input-port` primitive."
      (current-input-port-or-deny context "current-input-port"))

    (define (primitive-current-output-port arguments context)
      "Implement the `current-output-port` primitive."
      (current-output-port-or-deny context "current-output-port"))

    (define (primitive-current-error-port arguments context)
      "Implement the `current-error-port` primitive."
      (current-error-port-or-deny context "current-error-port"))

    (define (write-text-to-port text port description . maybe-context)
      "Write text to port data through the Consent Scheme port or datum renderer."
      (let ((output (expect-textual-output-port port description))
            (context (if (null? maybe-context) #f (car maybe-context))))
        (if (not (memq (consent-port-medium output) '(string file)))
            (eval-error
             (string-append description
                            " host textual output ports are not available")
             port))
        (revalidate-port-operation! output context 'write)
        ;; Charge the emitted characters against the output budget before the
        ;; write lands so an unbounded printing loop fails closed without first
        ;; emitting the over-budget bytes.
        (if context
            (note-output! context (string-length text)))
        ;; A streaming stdio output port flushes each write through its host
        ;; writer immediately (so a single-form filter loop streams instead of
        ;; buffering to end of program), charged against the host-callback budget;
        ;; an ordinary in-memory port accumulates its contents as before.
        (if (program-output-streaming? output)
            (begin
              (if context
                  (note-host-callback! context program-output-write-primitive))
              ((program-output-writer-of output) text))
            (set-consent-port-contents!
             output
             (string-append (consent-port-contents output) text)))
        (audit-port-capability-result!
         context output 'write (string-length text) #f)
        consent-unspecified))

    (define (write-to-output-port value port mode display? . maybe-context)
      "Write to output port data through the Consent Scheme port or datum renderer."
      (write-text-to-port
       (if display?
           (display-string value)
           (consent-datum->external value mode))
       port
       (if display? "display" "write")
       (if (null? maybe-context) #f (car maybe-context))))

    (define (primitive-eof-object? arguments context)
      "Implement the `eof-object?` primitive with argument validation and"
      "Consent Scheme values."
      (consent-eof-object? (car arguments)))

    (define (primitive-eof-object arguments context)
      "Implement the `eof-object` primitive with argument validation and"
      "Consent Scheme values."
      consent-eof-object)

    (define (primitive-port? arguments context)
      "Implement the `port?` primitive with argument validation and Consent"
      "Scheme values."
      (consent-port? (car arguments)))

    (define (primitive-input-port? arguments context)
      "Implement the `input-port?` primitive with argument validation and"
      "Consent Scheme values."
      (and (consent-port? (car arguments))
           (consent-port-input? (car arguments))))

    (define (primitive-output-port? arguments context)
      "Implement the `output-port?` primitive with argument validation and"
      "Consent Scheme values."
      (and (consent-port? (car arguments))
           (consent-port-output? (car arguments))))

    (define (primitive-textual-port? arguments context)
      "Implement the `textual-port?` primitive with argument validation and"
      "Consent Scheme values."
      (and (consent-port? (car arguments))
           (consent-port-textual? (car arguments))))

    (define (primitive-binary-port? arguments context)
      "Implement the `binary-port?` primitive with argument validation and"
      "Consent Scheme values."
      (and (consent-port? (car arguments))
           (consent-port-binary? (car arguments))))

    (define (primitive-input-port-open? arguments context)
      "Implement the `input-port-open?` primitive with argument validation and"
      "Consent Scheme values."
      (let ((port (expect-port (car arguments) "input-port-open?")))
        (and (consent-port-input? port)
             (consent-port-open? port))))

    (define (primitive-output-port-open? arguments context)
      "Implement the `output-port-open?` primitive with argument validation and"
      "Consent Scheme values."
      (let ((port (expect-port (car arguments) "output-port-open?")))
        (and (consent-port-output? port)
             (consent-port-open? port))))

    (define (write-host-file-string path contents)
      "Write CONTENTS to PATH using the host Scheme file API."
      (if (file-exists? path)
          (delete-file path))
      (call-with-output-file
       path
       (lambda (host-port)
         (display contents host-port))))

    (define (write-host-file-bytes path bytes)
      "Write BYTES to PATH using the host Scheme binary file API."
      (if (file-exists? path)
          (delete-file path))
      (let ((host-port (open-binary-output-file path)))
        (let loop ((rest bytes))
          (if (null? rest)
              (close-port host-port)
              (begin
                (write-u8 (car rest) host-port)
                (loop (cdr rest)))))))

    (define (write-host-file-port-contents port)
      "Write host-backed output PORT contents to its file path."
      (if (consent-port-binary? port)
          (write-host-file-bytes
           (consent-port-path port)
           (or (consent-port-contents port) '()))
          (write-host-file-string
           (consent-port-path port)
           (or (consent-port-contents port) ""))))

    (define (flush-file-output-port port context operation)
      "Flush host-backed output PORT to its file path for OPERATION."
      (if (and (eq? (consent-port-backing-domain port) 'file)
               (consent-port-output? port))
          (begin
            (revalidate-port-operation! port context operation)
            (write-host-file-port-contents port)
            (audit-port-capability-result!
             context port operation 'flushed #f))))

    (define (close-port-value port . maybe-context)
      "Mark PORT closed and return the unspecified value."
      (let ((context (if (null? maybe-context) #f (car maybe-context))))
        (if (consent-port-open? port)
            (begin
              (if (consent-port-backing-domain port)
                  (revalidate-port-operation! port context 'close))
              (if (and (eq? (consent-port-backing-domain port) 'file)
                       (consent-port-output? port))
                  (write-host-file-port-contents port))
              (set-consent-port-open?! port #f)
              (set-consent-port-status! port 'closed)
              (audit-port-capability-result!
               context port 'close 'closed #f))))
      consent-unspecified)

    (define (primitive-close-port arguments context)
      "Implement the `close-port` primitive with argument validation and"
      "Consent Scheme values."
      (close-port-value (expect-port (car arguments) "close-port") context))

    (define (primitive-close-input-port arguments context)
      "Implement the `close-input-port` primitive with argument validation and"
      "Consent Scheme values."
      (close-port-value
       (expect-input-port (car arguments) "close-input-port")
       context))

    (define (primitive-close-output-port arguments context)
      "Implement the `close-output-port` primitive with argument validation and"
      "Consent Scheme values."
      (close-port-value
       (expect-output-port (car arguments) "close-output-port")
       context))

    (define (primitive-open-output-string arguments context)
      "Implement the `open-output-string` primitive with argument validation"
      "and Consent Scheme values."
      (make-consent-port
       'string #f #t #t #f #t #f 0 ""
       #f '() #f '() #f #f #f '()))

    (define (primitive-open-input-string arguments context)
      "Implement the `open-input-string` primitive with argument validation and"
      "Consent Scheme values."
      (make-consent-port
       'string #t #f #t #f #t
       (expect-string (car arguments) "open-input-string")
       0 #f
       #f '() #f '() #f #f #f '()))

    (define (primitive-get-output-string arguments context)
      "Implement the `get-output-string` primitive with argument validation and"
      "Consent Scheme values."
      (charge-string-allocation!
       (consent-port-contents
        (expect-string-output-port
         (car arguments)
         "get-output-string"))
       context))

    (define (primitive-open-output-bytevector arguments context)
      "Implement the `open-output-bytevector` primitive with argument"
      "validation and Consent Scheme values."
      (make-consent-port
       'bytevector #f #t #f #t #t #f 0 '()
       #f '() #f '() #f #f #f '()))

    (define (copy-bytevector bytes)
      "Return a fresh bytevector with the same bytes as BYTES."
      (let* ((length (bytevector-length bytes))
             (copy (make-bytevector length 0)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (bytevector-u8-set! copy index (bytevector-u8-ref bytes index))
                (loop (+ index 1)))))
        copy))

    (define (primitive-open-input-bytevector arguments context)
      "Implement the `open-input-bytevector` primitive with argument validation"
      "and Consent Scheme values."
      (make-consent-port
       'bytevector #t #f #f #t #t
       (copy-bytevector
        (expect-bytevector (car arguments) "open-input-bytevector"))
       0 #f
       #f '() #f '() #f #f #f '()))

    (define (list->bytevector bytes)
      "Convert a list of exact byte values into a bytevector."
      (let ((result (make-bytevector (length bytes) 0)))
        (let loop ((index 0) (rest bytes))
          (if (null? rest)
              result
              (begin
                (bytevector-u8-set! result index (car rest))
                (loop (+ index 1) (cdr rest)))))))

    (define (primitive-get-output-bytevector arguments context)
      "Implement the `get-output-bytevector` primitive with argument validation"
      "and Consent Scheme values."
      (charge-bytevector-allocation!
       (list->bytevector
        (consent-port-contents
         (expect-bytevector-output-port
          (car arguments)
          "get-output-bytevector")))
       context))

    (define (primitive-read arguments context)
      "Implement the `read` primitive with argument validation and Consent Scheme values."
      (let ((port
             (expect-textual-input-port
              (if (null? arguments)
                  (current-input-port-or-deny context "read")
                  (car arguments))
              "read")))
        (revalidate-port-operation! port context 'read)
        ;; `read' realizes fresh structure from external input, so charge the
        ;; parsed datum once -- like a literal -- to bound oversized input.
        (if (program-input-streaming? port)
            (charge-literal! (program-input-read-streaming port context) context)
            (let ((result
                   (consent-read-from-string-at
                    (consent-port-source port)
                    (consent-port-position port)
                    (context-reader-options context))))
              (set-consent-port-position! port (cdr result))
              (audit-port-capability-result! context port 'read 'datum #f)
              (charge-literal!
               (if (consent-read-eof? (car result))
                   consent-eof-object
                   (car result))
               context)))))

    (define (text-port-next-char port advance? description . maybe-context)
      "Return the next character from PORT, optionally advancing its cursor."
      (let ((input (expect-textual-input-port port description))
            (maybe-ctx (if (null? maybe-context) #f (car maybe-context))))
        (if (not (memq (consent-port-medium input)
                       '(string file network)))
            (eval-error
             (string-append description
                            " host textual input ports are not available")
             port))
        (revalidate-port-operation! input maybe-ctx 'read)
        (if (and maybe-ctx (program-input-streaming? input))
            (program-input-fill-until!
             input maybe-ctx
             (lambda ()
               (> (string-length (consent-port-source input))
                  (consent-port-position input)))))
        (let ((position (consent-port-position input))
              (source (consent-port-source input)))
          (if (>= position (string-length source))
              (begin
                (audit-port-capability-result!
                 (if (null? maybe-context) #f (car maybe-context))
                 input
                 'read
                 'eof
                 #f)
                consent-eof-object)
              (let ((char (string-ref source position)))
                (if advance?
                    (set-consent-port-position! input (+ position 1)))
                (audit-port-capability-result!
                 (if (null? maybe-context) #f (car maybe-context))
                 input
                 'read
                 1
                 #f)
                char)))))

    (define (primitive-read-char arguments context)
      "Implement the `read-char` primitive with argument validation and Consent"
      "Scheme values."
      (if (null? arguments)
          (text-port-next-char
           (current-input-port-or-deny context "read-char")
           #t
           "read-char"
           context)
          (text-port-next-char (car arguments) #t "read-char" context)))

    (define (primitive-peek-char arguments context)
      "Implement the `peek-char` primitive with argument validation and Consent"
      "Scheme values."
      (if (null? arguments)
          (text-port-next-char
           (current-input-port-or-deny context "peek-char")
           #f
           "peek-char"
           context)
          (text-port-next-char (car arguments) #f "peek-char" context)))

    (define (primitive-char-ready? arguments context)
      "Implement the `char-ready?` primitive with argument validation and"
      "Consent Scheme values."
      (if (not (null? arguments))
          (expect-textual-input-port (car arguments) "char-ready?"))
      #t)

    (define (primitive-read-string arguments context)
      "Implement the `read-string` primitive with argument validation and"
      "Consent Scheme values."
      (let ((count (exact-integer->host (car arguments) "read-string"))
            (port (if (null? (cdr arguments))
                      (current-input-port-or-deny context "read-string")
                      (expect-textual-input-port
                       (second arguments)
                       "read-string"))))
        (if (< count 0)
            (eval-error "read-string count must be non-negative"))
        (cond
         ((not port) (if (= count 0) "" consent-eof-object))
         ((not (memq (consent-port-medium port) '(string file network)))
          (eval-error "read-string host textual input ports are not available"))
         (else
          (revalidate-port-operation! port context 'read)
          (if (program-input-streaming? port)
              (program-input-fill-until!
               port context
               (lambda ()
                 (>= (- (string-length (consent-port-source port))
                        (consent-port-position port))
                     count))))
          (let* ((source (consent-port-source port))
                 (position (consent-port-position port))
                 (remaining (- (string-length source) position))
                 (amount (if (< count remaining) count remaining)))
            (cond
             ((= count 0) "")
             ((= amount 0) consent-eof-object)
             (else
              (set-consent-port-position! port (+ position amount))
              (audit-port-capability-result!
               context port 'read amount #f)
              (charge-string-allocation!
               (substring source position (+ position amount))
               context))))))))

    (define (primitive-read-line arguments context)
      "Implement the `read-line` primitive with argument validation and Consent"
      "Scheme values."
      (let ((port (expect-textual-input-port
                   (if (null? arguments)
                       (current-input-port-or-deny context "read-line")
                       (car arguments))
                   "read-line")))
        (if (not (memq (consent-port-medium port) '(string file network)))
            (eval-error
             "read-line host textual input ports are not available"))
        (revalidate-port-operation! port context 'read)
        (if (program-input-streaming? port)
            (program-input-fill-until!
             port context
             (lambda ()
               (program-input-line-buffered?
                (consent-port-source port)
                (consent-port-position port)))))
        (let* ((source (consent-port-source port))
               (start (consent-port-position port))
               (length (string-length source)))
          (let loop ((position start))
            (if (and (< position length)
                     (not (or (char=? (string-ref source position)
                                       #\newline)
                              (char=? (string-ref source position)
                                       #\return))))
                (loop (+ position 1))
                (if (and (= start position) (>= position length))
                    consent-eof-object
                    (let ((line (substring source start position)))
                      (if (< position length)
                          (if (and (char=? (string-ref source position)
                                            #\return)
                                   (< (+ position 1) length)
                                   (char=? (string-ref
                                            source
                                            (+ position 1))
                                           #\newline))
                              (set! position (+ position 2))
                              (set! position (+ position 1))))
                      (set-consent-port-position! port position)
                      (audit-port-capability-result!
                       context port 'read (string-length line) #f)
                      (charge-string-allocation! line context))))))))

    (define (append-bytes-to-port bytes port description . maybe-context)
      "Append BYTES to binary output PORT."
      (let ((output (expect-binary-output-port port description))
            (context (if (null? maybe-context) #f (car maybe-context))))
        (if (not (memq (consent-port-medium output) '(bytevector file)))
            (eval-error
             (string-append description
                            " host binary output ports are not available")
             port))
        (revalidate-port-operation! output context 'write)
        ;; A streaming stdio binary port flushes each byte write through its host
        ;; byte writer immediately (so a single-form byte filter streams instead of
        ;; buffering to end of program), charged against the host-callback budget;
        ;; an ordinary in-memory port accumulates its bytes as before.
        (if (program-binary-output-streaming? output)
            (begin
              (if context
                  (note-host-callback! context program-binary-output-write-primitive))
              ((program-binary-output-writer-of output) bytes))
            (set-consent-port-contents!
             output
             (append (consent-port-contents output) bytes)))
        (audit-port-capability-result!
         context output 'write (length bytes) #f)
        consent-unspecified))

    (define (write-byte-to-port byte port description . maybe-context)
      "Write byte to port data through the Consent Scheme port or datum renderer."
      (append-bytes-to-port
       (list byte)
       port
       description
       (if (null? maybe-context) #f (car maybe-context))))

    (define (primitive-read-u8 arguments context)
      "Implement the `read-u8` primitive with argument validation and Consent"
      "Scheme values."
      (if (null? arguments)
          consent-eof-object
          (let ((port (expect-binary-input-port (car arguments) "read-u8")))
            (if (not (memq (consent-port-medium port) '(bytevector file)))
                (eval-error
                 "read-u8 host binary input ports are not available"))
            (revalidate-port-operation! port context 'read)
            ;; A streaming stdio binary port refills bytes on demand: pull one
            ;; chunk when no byte is buffered, so a byte filter never drains the
            ;; pipe up front.
            (if (program-binary-input-streaming? port)
                (program-binary-input-fill-until!
                 port context
                 (lambda () (program-binary-input-buffered>=? port 1))))
            (let ((source (consent-port-source port))
                  (position (consent-port-position port)))
              (if (>= position (bytevector-length source))
                  (begin
                    (audit-port-capability-result! context port 'read 'eof #f)
                    consent-eof-object)
                  (begin
                    (set-consent-port-position! port (+ position 1))
                    (audit-port-capability-result! context port 'read 1 #f)
                    (host-number->agent-number
                     (bytevector-u8-ref source position))))))))

    (define (primitive-peek-u8 arguments context)
      "Implement the `peek-u8` primitive with argument validation and Consent"
      "Scheme values."
      (if (null? arguments)
          consent-eof-object
          (let ((port (expect-binary-input-port (car arguments) "peek-u8")))
            (if (not (memq (consent-port-medium port) '(bytevector file)))
                (eval-error
                 "peek-u8 host binary input ports are not available"))
            (revalidate-port-operation! port context 'read)
            ;; Peeking refills like `read-u8' but does not advance the cursor.
            (if (program-binary-input-streaming? port)
                (program-binary-input-fill-until!
                 port context
                 (lambda () (program-binary-input-buffered>=? port 1))))
            (let ((source (consent-port-source port))
                  (position (consent-port-position port)))
              (if (>= position (bytevector-length source))
                  (begin
                    (audit-port-capability-result! context port 'read 'eof #f)
                    consent-eof-object)
                  (begin
                    (audit-port-capability-result! context port 'read 1 #f)
                    (host-number->agent-number
                     (bytevector-u8-ref source position))))))))

    (define (primitive-u8-ready? arguments context)
      "Implement the `u8-ready?` primitive with argument validation and Consent"
      "Scheme values."
      (if (not (null? arguments))
          (expect-binary-input-port (car arguments) "u8-ready?"))
      #t)

    (define (subbytevector source start end)
      "Return SOURCE bytes in the half-open range [START, END)."
      (let ((result (make-bytevector (- end start) 0)))
        (let loop ((index start))
          (if (< index end)
              (begin
                (bytevector-u8-set!
                 result
                 (- index start)
                 (bytevector-u8-ref source index))
                (loop (+ index 1)))))
        result))

    (define (primitive-read-bytevector arguments context)
      "Implement the `read-bytevector` primitive with argument validation and"
      "Consent Scheme values."
      (let ((count (exact-integer->host
                    (car arguments)
                    "read-bytevector"))
            (port (if (null? (cdr arguments))
                      #f
                      (expect-binary-input-port
                       (second arguments)
                       "read-bytevector"))))
        (if (< count 0)
            (eval-error "read-bytevector count must be non-negative"))
        (cond
         ((not port)
          (if (= count 0) (make-bytevector 0 0) consent-eof-object))
         ((not (memq (consent-port-medium port) '(bytevector file)))
          (eval-error "read-bytevector host binary input ports are not available"))
         (else
          (revalidate-port-operation! port context 'read)
          ;; A streaming stdio binary port refills until COUNT bytes are buffered
          ;; or the stream ends, so a bounded read pulls only what it needs.
          (if (program-binary-input-streaming? port)
              (program-binary-input-fill-until!
               port context
               (lambda () (program-binary-input-buffered>=? port count))))
          (let* ((source (consent-port-source port))
                 (position (consent-port-position port))
                 (remaining (- (bytevector-length source) position))
                 (amount (if (< count remaining) count remaining)))
            (cond
             ((= count 0) (make-bytevector 0 0))
             ((= amount 0) consent-eof-object)
             (else
              (set-consent-port-position! port (+ position amount))
              (audit-port-capability-result! context port 'read amount #f)
              (charge-bytevector-allocation!
               (subbytevector source position (+ position amount))
               context))))))))

    (define (primitive-read-bytevector! arguments context)
      "Implement the `read-bytevector!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((arity (length arguments))
             (target (expect-bytevector
                      (car arguments)
                      "read-bytevector! target"))
             (port (if (< arity 2)
                       #f
                       (expect-binary-input-port
                        (second arguments)
                        "read-bytevector!")))
             (start (if (< arity 3)
                        0
                        (expect-nonnegative-index
                         (third arguments)
                         (bytevector-length target)
                         "read-bytevector!"
                         #t)))
             (end (if (< arity 4)
                      (bytevector-length target)
                      (expect-nonnegative-index
                       (fourth arguments)
                       (bytevector-length target)
                       "read-bytevector!"
                       #t))))
        (if (> start end)
            (eval-error "read-bytevector! invalid range"))
        (if (not port)
            consent-eof-object
            (begin
              (if (not (memq (consent-port-medium port) '(bytevector file)))
                  (eval-error
                   "read-bytevector! host binary input ports are not available"))
              (revalidate-port-operation! port context 'read)
              ;; A streaming stdio binary port refills until the target range can
              ;; be filled or the stream ends.
              (if (program-binary-input-streaming? port)
                  (program-binary-input-fill-until!
                   port context
                   (lambda ()
                     (program-binary-input-buffered>=? port (- end start)))))
              (let* ((source (consent-port-source port))
                     (position (consent-port-position port))
                     (capacity (- end start))
                     (remaining (- (bytevector-length source) position))
                     (amount (if (< capacity remaining) capacity remaining)))
                (if (= amount 0)
                    consent-eof-object
                    (begin
                      (let loop ((offset 0))
                        (if (< offset amount)
                            (begin
                              (bytevector-u8-set!
                               target
                               (+ start offset)
                               (bytevector-u8-ref source (+ position offset)))
                              (loop (+ offset 1)))))
                      (set-consent-port-position! port (+ position amount))
                      (audit-port-capability-result!
                       context port 'read amount #f)
                      (host-number->agent-number amount))))))))

    (define (primitive-write-u8 arguments context)
      "Implement the `write-u8` primitive with argument validation and Consent"
      "Scheme values."
      (if (not (null? (cdr arguments)))
          (write-byte-to-port
           (expect-byte (car arguments) "write-u8")
           (second arguments)
           "write-u8"
           context))
      consent-unspecified)

    (define (primitive-write-bytevector arguments context)
      "Implement the `write-bytevector` primitive with argument validation and"
      "Consent Scheme values."
      (if (not (null? (cdr arguments)))
          (let* ((bytes (expect-bytevector
                         (car arguments)
                         "write-bytevector"))
                 (range (optional-range arguments
                                        2
                                        (bytevector-length bytes)
                                        "write-bytevector")))
            (let loop ((index (car range)) (payload '()))
              (if (< index (cdr range))
                  (loop (+ index 1)
                        (cons (bytevector-u8-ref bytes index) payload))
                  (append-bytes-to-port
                   (reverse payload)
                   (second arguments)
                   "write-bytevector"
                   context)))))
      consent-unspecified)

    (define (primitive-write-char arguments context)
      "Implement the `write-char` primitive with argument validation and"
      "Consent Scheme values."
      (write-text-to-port
       (string (expect-character (car arguments) "write-char"))
       (if (null? (cdr arguments))
           (current-output-port-or-deny context "write-char")
           (second arguments))
       "write-char"
       context)
      consent-unspecified)

    (define (primitive-write-string arguments context)
      "Implement the `write-string` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "write-string"))
             (port (if (null? (cdr arguments))
                       (current-output-port-or-deny context "write-string")
                       (second arguments)))
             (range (optional-range arguments
                                    (if (null? (cdr arguments)) 1 2)
                                    (string-length string)
                                    "write-string")))
        (write-text-to-port
         (substring string (car range) (cdr range))
         port
         "write-string"
         context))
      consent-unspecified)

    (define (primitive-newline arguments context)
      "Implement the `newline` primitive with argument validation and Consent"
      "Scheme values."
      (write-text-to-port
       "\n"
       (if (null? arguments)
           (current-output-port-or-deny context "newline")
           (car arguments))
       "newline"
       context)
      consent-unspecified)

    (define (primitive-display arguments context)
      "Implement the `display` primitive with argument validation and Consent"
      "Scheme values."
      (write-to-output-port
       (car arguments)
       (if (null? (cdr arguments))
           (current-output-port-or-deny context "display")
           (second arguments))
       'write
       #t
       context))

    (define (primitive-write arguments context)
      "Implement the `write` primitive with argument validation and Consent"
      "Scheme values."
      (write-to-output-port
       (car arguments)
       (if (null? (cdr arguments))
           (current-output-port-or-deny context "write")
           (second arguments))
       'write
       #f
       context))

    (define (primitive-write-shared arguments context)
      "Implement the `write-shared` primitive with argument validation and"
      "Consent Scheme values."
      (write-to-output-port
       (car arguments)
       (if (null? (cdr arguments))
           (current-output-port-or-deny context "write-shared")
           (second arguments))
       'shared
       #f
       context))

    (define (primitive-write-simple arguments context)
      "Implement the `write-simple` primitive with argument validation and"
      "Consent Scheme values."
      (write-to-output-port
       (car arguments)
       (if (null? (cdr arguments))
           (current-output-port-or-deny context "write-simple")
           (second arguments))
       'simple
       #f
       context))

    (define (primitive-flush-output-port arguments context)
      "Implement the `flush-output-port` primitive with argument validation and"
      "Consent Scheme values."
      (if (not (null? arguments))
          (flush-file-output-port
           (expect-output-port (car arguments) "flush-output-port")
           context
           'flush))
      consent-unspecified)

    (define (primitive-read-error? arguments context)
      "Implement the `read-error?` primitive with argument validation and"
      "Consent Scheme values."
      #f)

    (define (primitive-file-error? arguments context)
      "Implement the `file-error?` primitive with argument validation and"
      "Consent Scheme values."
      #f)

    (define (primitive-features arguments context)
      "Implement the `features` primitive with argument validation and Consent"
      "Scheme values."
      '(r7rs ratios exact-complex ieee-float consent))

    (define (primitive-agent-yield arguments context)
      "Emit a primary structured observation event into the current context."
      (record-agent-event! context (list 'yield (car arguments)))
      consent-unspecified)

    (define (primitive-agent-log arguments context)
      "Emit a structured log event into the current context."
      (record-agent-event!
       context
       (list 'log
             (result-field 'level (car arguments))
             (result-field 'message (second arguments))
             (result-field 'fields (cddr arguments))))
      consent-unspecified)

    (define (primitive-agent-progress arguments context)
      "Emit a structured progress event into the current context."
      (record-agent-event!
       context
       (list 'progress
             (result-field 'phase (car arguments))
             (result-field 'datum (second arguments))))
      consent-unspecified)

    (define (primitive-agent-warn arguments context)
      "Emit a structured warning event into the current context."
      (record-agent-event!
       context
       (list 'warn
             (result-field 'message (car arguments))
             (result-field 'fields (cdr arguments))))
      consent-unspecified)

    (define (primitive-agent-request arguments context)
      "Emit a structured request event into the current context."
      (record-agent-event! context (list 'request (car arguments)))
      consent-unspecified)

    (define (context-current-request context)
      "Return the current request context, or #f when no request was supplied."
      (context-model:make-request-context
       (context-request-id context)
       (context-session-id context)
       (context-request context)))

    (define (context-current-region-context context)
      "Return the current region context supplied by the host, or #f."
      (context-region-context context))

    (define (context-current-buffer-context context)
      "Return the current buffer context supplied by the host, or #f."
      (context-buffer-context context))

    (define (context-current-project-context context)
      "Return the current project context supplied by the host, or #f."
      (context-project-context context))

    (define (context-current-conversation-summary context)
      "Return the current conversation summary, or #f when no summary exists."
      (context-model:make-conversation-summary
       (context-session-id context)
       (context-conversation-summary context)))

    (define (context-current-focus context)
      "Return the current focus context, synthesizing one from known records."
      (or (context-focus context)
          (context-model:make-focus-context
           (list
            (context-current-request context)
            (context-current-region-context context)
            (context-current-buffer-context context)
            (context-current-project-context context)
            (context-current-conversation-summary context)))))

    (define (context-query-name query)
      "Return QUERY as a context selector name, or #f when unsupported."
      (cond
       ((symbol? query) query)
       ((string? query) (string->symbol query))
       (else #f)))

    (define (context-select-one name context)
      "Return one context record selected by NAME."
      (cond
       ((or (eq? name 'all) (eq? name 'context))
        (context-model:make-context-bundle
         (list
          (context-current-request context)
          (context-current-region-context context)
          (context-current-buffer-context context)
          (context-current-project-context context)
          (context-current-conversation-summary context))))
       ((eq? name 'request) (context-current-request context))
       ((eq? name 'focus) (context-current-focus context))
       ((eq? name 'region) (context-current-region-context context))
       ((eq? name 'buffer) (context-current-buffer-context context))
       ((eq? name 'project) (context-current-project-context context))
       ((or (eq? name 'conversation)
            (eq? name 'conversation-summary))
        (context-current-conversation-summary context))
       (else #f)))

    (define (context-select query context)
      "Return context records selected by QUERY."
      (let ((name (context-query-name query)))
        (cond
         (name (context-select-one name context))
         ((pair? query)
          (context-model:make-context-bundle
           (map
            (lambda (item)
              (context-select-one
               (or (context-query-name item) 'unknown)
               context))
            (proper-list-elements query "context-yield query"))))
         (else #f))))

    (define (primitive-current-request arguments context)
      "Return the current request context primitive value."
      (context-current-request context))

    (define (primitive-current-focus arguments context)
      "Return the current focus context primitive value."
      (context-current-focus context))

    (define (primitive-current-region-context arguments context)
      "Return the current region context primitive value."
      (context-current-region-context context))

    (define (primitive-current-buffer-context arguments context)
      "Return the current buffer context primitive value."
      (context-current-buffer-context context))

    (define (primitive-current-project-context arguments context)
      "Return the current project context primitive value."
      (context-current-project-context context))

    (define (primitive-current-conversation-summary arguments context)
      "Return the current conversation summary primitive value."
      (context-current-conversation-summary context))

    (define (primitive-context-yield arguments context)
      "Yield selected context through the event channel."
      (let ((record (context-select (car arguments) context)))
        (if record
            (record-agent-event!
             context
             (list 'yield (redaction-model:redact record 'agent-context))))
        record))

    ;; Policy categories reported by `(agent reflect)'.
    (define reflect-policy-categories
      '(pure-r7rs
        emacs-read-only
        buffer-edit
        vcs-mutation
        window-session
        command-process
        standard-host-effect
        debugger-recovery
        raw-emacs-lisp
        approval-resolution
        skill-discovery-activation
        project-skill-trust
        skill-resource-read
        skill-script-execution
        skill-export-write
        network-access
        remote-provider-routing))

    ;; Default policy actions mirror the Emacs bootstrap policy table.
    (define reflect-default-policy-actions
      '((pure-r7rs . allow)
        (emacs-read-only . allow)
        (buffer-edit . confirm)
        (vcs-mutation . confirm)
        (window-session . confirm)
        (command-process . confirm)
        (standard-host-effect . allow)
        (debugger-recovery . confirm)
        (raw-emacs-lisp . deny)
        (approval-resolution . deny)
        (skill-discovery-activation . confirm)
        (project-skill-trust . deny)
        (skill-resource-read . confirm)
        (skill-script-execution . confirm)
        (skill-export-write . confirm)
        (network-access . deny)
        (remote-provider-routing . allow)))

    (define (reflect-field-value spec field default)
      "Return FIELD's value from association-list SPEC, or DEFAULT."
      (let ((entry (assq field spec)))
        (if entry (cadr entry) default)))

    (define (reflect-datumize value)
      "Return host VALUE as a Scheme-readable reflection datum."
      (cond
       ((integer? value) (consent-make-canonical-integer value))
       ((pair? value)
        (cons (reflect-datumize (car value))
              (reflect-datumize (cdr value))))
       ((vector? value)
        (list->vector (map reflect-datumize (vector->list value))))
       (else value)))

    (define (reflect-host-capability-spec? spec)
      "Report whether SPEC describes a host capability."
      (eq? (reflect-field-value spec 'source #f) 'host-capability))

    (define (reflect-capability-record spec)
      "Convert a primitive manifest SPEC into a public capability record."
      (list 'host-capability
            (result-field 'library
                          (reflect-field-value spec 'library #f))
            (result-field 'name
                          (reflect-field-value spec 'name #f))
            (result-field 'minimum-arity
                          (reflect-datumize
                           (reflect-field-value spec 'minimum-arity #f)))
            (result-field 'maximum-arity
                          (reflect-datumize
                           (reflect-field-value spec 'maximum-arity #f)))
            (result-field 'source
                          (reflect-field-value spec 'source #f))
            (result-field 'effect
                          (reflect-field-value spec 'effect #f))
            (result-field 'required-capability
                          (reflect-field-value spec
                                               'required-capability
                                               #f))
            (result-field 'backend-effect-path
                          (reflect-field-value spec
                                               'backend-effect-path
                                               #f))
            (result-field 'policy-category
                          (reflect-field-value spec 'policy-category #f))
            (result-field 'policy
                          (reflect-field-value spec 'policy #f))
            (result-field 'requires-grant
                          (if (reflect-field-value spec
                                                   'requires-grant
                                                   #f)
                              #t
                              #f))))

    (define (reflect-current-capabilities)
      "Return all host capability reflection records from the manifest."
      (let loop ((specs (consent-primitive-manifest-binding-specs))
                 (records '()))
        (cond
         ((null? specs) (reverse records))
         ((reflect-host-capability-spec? (car specs))
          (loop (cdr specs)
                (cons (reflect-capability-record (car specs))
                      records)))
         (else (loop (cdr specs) records)))))

    (define (reflect-capability-name symbol-or-name)
      "Return SYMBOL-OR-NAME as a capability name symbol."
      (cond
       ((symbol? symbol-or-name) symbol-or-name)
       ((string? symbol-or-name) (string->symbol symbol-or-name))
       (else (eval-error "capability-info expects a symbol or string"))))

    (define (reflect-capability-info symbol-or-name)
      "Return capability metadata for SYMBOL-OR-NAME, or #f."
      (let ((name (reflect-capability-name symbol-or-name)))
        (let loop ((specs (consent-primitive-manifest-binding-specs)))
          (cond
           ((null? specs) #f)
           ((and (reflect-host-capability-spec? (car specs))
                 (eq? (reflect-field-value (car specs) 'name #f) name))
            (reflect-capability-record (car specs)))
           (else (loop (cdr specs)))))))

    (define (reflect-manifest-spec-for-name name)
      "Return primitive manifest metadata for binding NAME, or #f."
      (let loop ((specs (consent-primitive-manifest-binding-specs)))
        (cond
         ((null? specs) #f)
         ((eq? (reflect-field-value (car specs) 'name #f) name)
          (car specs))
         (else (loop (cdr specs))))))

    ;; Best-effort public documentation for primitive implementation hooks
    ;; where standard R7RS gives no way to reflect host procedure docstrings.
    (define primitive-implementation-documentation-specs
      (list
       (cons 'primitive+
             "Implement the `+' primitive over any number of numeric arguments.")
       (cons 'primitive-current-second
             "Implement R7RS `current-second` through a policy-gated clock read.")))

    (define (reflect-implementation-documentation hook)
      "Return documentation metadata derived from implementation HOOK."
      (let ((entry (and hook
                        (assq hook
                              primitive-implementation-documentation-specs))))
        (and entry
             (make-documentation-metadata
              (list (cons 'documentation (cdr entry)))
              '(implementation-procedure-string)))))

    (define (reflect-primitive-documentation spec)
      "Return manifest or implementation documentation for primitive SPEC."
      (or (reflect-field-value spec 'documentation #f)
          (reflect-implementation-documentation
           (reflect-field-value spec 'portable-hook #f))))

    (define (reflect-primitive-procedure-spec value)
      "Return primitive manifest metadata for primitive procedure VALUE."
      (and (consent-primitive-procedure? value)
           (reflect-manifest-spec-for-name
            (primitive-procedure-name value))))

    (define (reflect-procedure-documentation value)
      "Return documentation metadata attached to callable VALUE, or #f."
      (cond
       ((consent-procedure? value)
        (procedure-documentation value))
       ((consent-primitive-procedure? value)
        (let ((spec (reflect-primitive-procedure-spec value)))
          (and spec (reflect-primitive-documentation spec))))
       (else #f)))

    (define (reflect-documentation-origin documentation)
      "Return documentation origin data for reflection."
      (let ((origins
             (cond
              ((string? documentation) '(string))
              ((documentation-metadata? documentation)
               (documentation-metadata-origins documentation))
              (else '()))))
        (cond
         ((null? origins)
          '(signature))
         ((equal? origins '(implementation-procedure-string))
          '(implementation-procedure string))
         ((equal? origins '(primitive-manifest-string))
          '(primitive-manifest string))
         ((equal? origins '(primitive-manifest-metadata))
          '(primitive-manifest metadata))
         (else
          (cons 'body-literal origins)))))

    (define (reflect-documentation-fields documentation)
      "Return documentation field data for reflection."
      (map (lambda (field)
             (list (car field) (reflect-datumize (cdr field))))
           (cond
            ((string? documentation)
             (list (cons 'documentation documentation)))
            ((documentation-metadata? documentation)
             (documentation-metadata-fields documentation))
            (else '()))))

    (define (reflect-documentation-record subject documentation . maybe-spec)
      "Return a Scheme-readable documentation metadata record."
      (let ((spec (if (null? maybe-spec) #f (car maybe-spec))))
        (list 'documentation-metadata
              (result-field 'subject subject)
              (result-field 'kind 'procedure)
              (result-field 'library
                            (if spec
                                (reflect-field-value spec 'library #f)
                                #f))
              (result-field 'source
                            (if spec
                                (reflect-field-value spec 'source #f)
                                #f))
              (result-field 'origin
                            (reflect-documentation-origin documentation))
              (result-field 'fields
                            (reflect-documentation-fields documentation)))))

    (define (reflect-binding-name symbol-or-name)
      "Return SYMBOL-OR-NAME as a binding symbol, or #f."
      (cond
       ((symbol? symbol-or-name) symbol-or-name)
       ((string? symbol-or-name) (string->symbol symbol-or-name))
       (else #f)))

    (define (reflect-documentation subject context)
      "Return documentation metadata for SUBJECT, or #f."
      (cond
       ((or (consent-procedure? subject)
            (consent-primitive-procedure? subject))
        (let ((documentation (reflect-procedure-documentation subject))
              (spec (reflect-primitive-procedure-spec subject)))
          (if documentation
              (reflect-documentation-record '(procedure) documentation spec)
              #f)))
       (else
        (let* ((name (reflect-binding-name subject))
               (environment (context-interaction-environment context))
               (cell (and name environment (environment-cell environment name)))
               (value (and cell (cell-value cell)))
               (spec (reflect-primitive-procedure-spec value))
               (documentation
                (and value
                     (not (undefined? value))
                     (reflect-procedure-documentation value))))
          (if documentation
              (reflect-documentation-record
               (list 'binding name)
               documentation
               spec)
              #f)))))

    (define (reflect-value-kind value)
      "Return VALUE's Scheme-readable introspection kind."
      (cond
       ((consent-primitive-procedure? value) 'primitive-procedure)
       ((consent-parameter? value) 'parameter)
       ((consent-procedure? value) 'procedure)
       ((continuation? value) 'continuation)
       ((consent-unspecified? value) 'unspecified)
       ((undefined? value) 'undefined)
       (else 'value)))

    (define (reflect-binding-documentation subject value context)
      "Return documentation metadata for SUBJECT and VALUE in CONTEXT."
      (let* ((spec (reflect-primitive-procedure-spec value))
             (documentation
              (and value
                   (not (undefined? value))
                   (reflect-procedure-documentation value))))
        (if documentation
            (reflect-documentation-record subject documentation spec)
            #f)))

    (define (reflect-binding-description subject binding-kind value context)
      "Return a Scheme-readable binding-description record."
      (let ((spec (reflect-primitive-procedure-spec value)))
        (list 'binding-description
              (result-field 'subject subject)
              (result-field 'binding-kind binding-kind)
              (result-field 'value-kind (reflect-value-kind value))
              (result-field 'library
                            (if spec
                                (reflect-field-value spec 'library #f)
                                #f))
              (result-field 'source
                            (if spec
                                (reflect-field-value spec 'source #f)
                                #f))
              (result-field 'value-summary (consent-value->external value))
              (result-field 'documentation
                            (reflect-binding-documentation subject
                                                           value
                                                           context)))))

    (define (reflect-syntax-description name)
      "Return a Scheme-readable syntax binding-description for NAME."
      (list 'binding-description
            (result-field 'subject (list 'binding name))
            (result-field 'binding-kind 'syntax)
            (result-field 'value-kind 'syntax)
            (result-field 'library #f)
            (result-field 'source #f)
            (result-field 'value-summary "#<syntax>")
            (result-field 'documentation #f)))

    (define (reflect-describe subject context)
      "Return Scheme-readable description data for SUBJECT, or #f."
      (cond
       ((or (consent-procedure? subject)
            (consent-primitive-procedure? subject))
        (reflect-binding-description '(procedure) #f subject context))
       (else
        (let* ((name (reflect-binding-name subject))
               (environment (context-interaction-environment context))
               (cell (and name environment (environment-cell environment name)))
               (value (if cell (cell-value cell) #f)))
          (cond
           ((and cell (not (undefined? value)))
            (reflect-binding-description
             (list 'binding name)
             'value
             value
             context))
           ((and name
                 (syntax-environment-ref (context-syntax-environment context)
                                         name))
            (reflect-syntax-description name))
           (else #f))))))

    (define (reflect-current-budget context)
      "Return the active budget ledger -- counters, limits, and stop reason."
      "The ledger is the single inspectable budget object: every enforced and"
      "reserved dimension reports its used count and ceiling, and `reason'"
      "names the dimension that stopped the run (or #f while admissible)."
      (list 'budget
            (result-field 'steps-used
                          (consent-make-canonical-integer
                           (context-steps context)))
            (result-field 'max-steps
                          (reflect-datumize
                           (context-maximum-steps context)))
            (result-field 'host-calls
                          (consent-make-canonical-integer
                           (context-host-callbacks context)))
            (result-field 'max-host-calls
                          (reflect-datumize
                           (context-maximum-host-callbacks context)))
            (result-field 'events-used
                          (consent-make-canonical-integer
                           (context-event-count context)))
            (result-field 'max-events
                          (reflect-datumize
                           (context-maximum-events context)))
            (result-field 'max-event-nodes
                          (reflect-datumize
                           (context-maximum-event-nodes context)))
            (result-field 'value-nodes-used
                          (consent-make-canonical-integer
                           (context-value-nodes context)))
            (result-field 'max-value-nodes
                          (reflect-datumize
                           (context-maximum-value-nodes context)))
            (result-field 'source-metadata-used
                          (consent-make-canonical-integer
                           (consent-source-metadata-count)))
            (result-field 'max-source-metadata
                          (reflect-datumize
                           (context-maximum-source-metadata context)))
            (result-field 'interned-symbols-used
                          (consent-make-canonical-integer
                           (context-interned-symbols context)))
            (result-field 'max-interned-symbols
                          (reflect-datumize
                           (context-maximum-interned-symbols context)))
            (result-field 'output-bytes-used
                          (consent-make-canonical-integer
                           (context-output-bytes context)))
            (result-field 'max-output-bytes
                          (reflect-datumize
                           (context-maximum-output-bytes context)))
            (result-field 'max-wall-time-ms
                          (reflect-datumize
                           (context-maximum-wall-time-ms context)))
            (result-field 'reason
                          (context-exhaustion-reason context))))

    (define (reflect-budget-remaining context)
      "Return the budget ledger as remaining headroom per enforced dimension."
      "Each dimension reports `limit - used'; an unbounded dimension (a #f"
      "wall-time limit) reports #f so callers can distinguish unbounded from"
      "exhausted."
      (list 'budget-remaining
            (result-field 'steps
                          (reflect-budget-headroom
                           (context-maximum-steps context)
                           (context-steps context)))
            (result-field 'host-calls
                          (reflect-budget-headroom
                           (context-maximum-host-callbacks context)
                           (context-host-callbacks context)))
            (result-field 'events
                          (reflect-budget-headroom
                           (context-maximum-events context)
                           (context-event-count context)))
            (result-field 'value-nodes
                          (reflect-budget-headroom
                           (context-maximum-value-nodes context)
                           (context-value-nodes context)))
            (result-field 'source-metadata
                          (reflect-budget-headroom
                           (context-maximum-source-metadata context)
                           (consent-source-metadata-count)))
            (result-field 'interned-symbols
                          (reflect-budget-headroom
                           (context-maximum-interned-symbols context)
                           (context-interned-symbols context)))
            (result-field 'output-bytes
                          (reflect-budget-headroom
                           (context-maximum-output-bytes context)
                           (context-output-bytes context)))
            (result-field 'reason
                          (context-exhaustion-reason context))))

    (define (reflect-budget-headroom limit used)
      "Return LIMIT minus USED as a canonical integer, or #f when unbounded."
      (if (integer? limit)
          (consent-make-canonical-integer (- limit used))
          #f))

    (define (reflect-policy-action context category)
      "Return CATEGORY's effective policy action in CONTEXT."
      (let ((override (assq category (context-policy-actions context))))
        (if override
            (cdr override)
            (let ((default (assq category reflect-default-policy-actions)))
              (if default (cdr default) 'deny)))))

    (define (reflect-current-policy context)
      "Return the active policy table and per-context overrides."
      (list 'policy
            (result-field
             'categories
             (map (lambda (category)
                    (list category
                          (reflect-policy-action context category)))
                  reflect-policy-categories))
            (result-field 'overrides
                          (context-policy-actions context))
            (result-field 'confirmation
                          (if (context-policy-confirmation-function context)
                              #t
                              #f))))

    (define (reflect-current-imports context)
      "Return registered library names for CONTEXT."
      (map car (context-libraries context)))

    (define (reflect-library-binding-record binding)
      "Return BINDING as a Scheme-readable library-binding record."
      (list 'library-binding
            (result-field 'name (library-binding-name binding))
            (result-field 'kind (library-binding-kind binding))
            (result-field 'library
                          (map (lambda (part) part)
                               (library-binding-library-key binding)))))

    (define (reflect-library-bindings library-name context)
      "Return registered exported binding records for LIBRARY-NAME in CONTEXT."
      (let* ((key (library-name-key library-name))
             (library (library-registry-ref context key)))
        (if library
            (map reflect-library-binding-record
                 (library-exports library))
            (eval-error "unknown library" key))))

    (define (reflect-library-catalog-field entry field default)
      "Return FIELD from catalog ENTRY, or DEFAULT when absent."
      (let ((cell (assq field entry)))
        (if cell (cadr cell) default)))

    (define (reflect-library-catalog-value entry field default)
      "Return FIELD from catalog ENTRY as a Scheme-readable datum."
      (reflect-datumize
       (reflect-library-catalog-field entry field default)))

    (define (reflect-library-info-record entry)
      "Return catalog ENTRY as a Scheme-readable library-info record."
      (list 'library-info
            (result-field
             'name
             (reflect-library-catalog-value entry 'name '()))
            (result-field
             'category
             (reflect-library-catalog-value entry 'category 'library))
            (result-field
             'status
             (reflect-library-catalog-value entry 'status 'implemented))
            (result-field
             'source-kind
             (reflect-library-catalog-value entry 'source-kind 'manifest))
            (result-field
             'source-file
             (reflect-library-catalog-value entry 'source-file #f))
            (result-field
             'aliases
             (reflect-library-catalog-value entry 'aliases '()))
            (result-field
             'target
             (reflect-library-catalog-value entry 'target #f))
            (result-field
             'exports
             (reflect-library-catalog-value entry 'exports '()))
            (result-field
             'dependencies
             (reflect-library-catalog-value entry 'dependencies '()))
            (result-field
             'origin
             (reflect-library-catalog-value entry 'origin 'built-in-seed))
            (result-field
             'source-id
             (reflect-library-catalog-value entry 'source-id #f))
            (result-field
             'summary
             (reflect-library-catalog-value entry 'summary #f))))

    (define (reflect-libraries)
      "Return cataloged libraries as library-info records."
      (map reflect-library-info-record (consent-library-catalog-entries)))

    (define (reflect-library-info library-name)
      "Return catalog metadata for LIBRARY-NAME, or #f when absent."
      (let ((entry (consent-library-catalog-entry library-name)))
        (if entry (reflect-library-info-record entry) #f)))

    (define (reflect-library-search-query query)
      "Return QUERY as catalog search input."
      (cond
       ((or (string? query) (symbol? query) (pair? query)) query)
       (else (consent-value->external query))))

    (define (reflect-library-search query)
      "Return library catalog entries matching QUERY."
      (map reflect-library-info-record
           (consent-library-catalog-search
            (reflect-library-search-query query))))

    (define (reflect-catalog-sources)
      "Return manifest catalog source records."
      (reflect-datumize (consent-library-catalog-sources)))

    (define (reflect-catalog-diagnostics)
      "Return manifest catalog diagnostics."
      (reflect-datumize (consent-library-catalog-diagnostics)))

    (define (reflect-catalog-private-library library-name)
      "Return (LIBRARY . CONTEXT) for LIBRARY-NAME in a private context."
      (let* ((context (new-eval-context '()))
             (environment (consent-make-base-environment)))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (cons (resolve-library (library-name-key library-name)
                               context
                               environment)
              context)))

    (define (reflect-library-documentation library-name)
      "Return documentation records for exported bindings in LIBRARY-NAME."
      (let* ((library/context (reflect-catalog-private-library library-name))
             (library (car library/context))
             (context (cdr library/context)))
        (let loop ((bindings (library-exports library)) (result '()))
          (if (null? bindings)
              (reverse result)
              (let ((documentation
                     (reflect-documentation
                      (library-binding-name (car bindings))
                      context)))
                (loop (cdr bindings)
                      (if documentation
                          (cons documentation result)
                          result)))))))

    (define (reflect-binding-libraries symbol-or-name)
      "Return cataloged libraries exporting SYMBOL-OR-NAME."
      (let ((name (reflect-binding-name symbol-or-name)))
        (if (not name)
            (eval-error "binding-libraries expects a symbol or string"
                        symbol-or-name))
        (let loop ((entries (consent-library-catalog-entries)) (result '()))
          (cond
           ((null? entries)
            (map reflect-library-info-record (reverse result)))
           ((memq name
                  (reflect-library-catalog-field
                   (car entries)
                   'exports
                   '()))
            (loop (cdr entries) (cons (car entries) result)))
           (else (loop (cdr entries) result))))))

    (define (reflect-documented-bindings context)
      "Return documentation records for documented current bindings."
      (let ((environment (context-interaction-environment context)))
        (let loop ((frame (if environment (environment-frame environment) '()))
                   (result '()))
          (if (null? frame)
              (reverse result)
              (let ((documentation
                     (reflect-documentation (caar frame) context)))
                (loop (cdr frame)
                      (if documentation
                          (cons documentation result)
                          result)))))))

    (define (reflect-field-name name)
      "Return NAME as a reflection field symbol."
      (cond
       ((symbol? name) name)
       ((string? name) (string->symbol name))
       (else name)))

    (define (reflect-reflection-field record name default)
      "Return NAME's value in RECORD, or DEFAULT when absent."
      (if (not (pair? record))
          default
          (let ((cell (assq (reflect-field-name name) (cdr record))))
            (if (and cell (pair? (cdr cell)))
                (cadr cell)
                default))))

    (define (reflect-documentation-field documentation name default)
      "Return NAME's value from DOCUMENTATION metadata, or DEFAULT."
      (let ((fields
             (reflect-reflection-field documentation 'fields #f)))
        (if (not (list? fields))
            default
            (let ((cell (assq (reflect-field-name name) fields)))
              (if (and cell (pair? (cdr cell)))
                  (cadr cell)
                  default)))))

    (define (reflect-docstring subject default context)
      "Return SUBJECT's documentation string, or DEFAULT when absent."
      (let ((documentation
             (if (and (pair? subject)
                      (eq? (car subject) 'documentation-metadata))
                 subject
                 (reflect-documentation subject context))))
        (reflect-documentation-field documentation 'documentation default)))

    (define (reflect-string-prefix? prefix text)
      "Report whether TEXT starts with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (string=? prefix (substring text 0 prefix-length)))))

    (define (reflect-string-contains? text needle)
      "Report whether TEXT contains NEEDLE."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (reflect-string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    (define (reflect-documentation-summary documentation)
      "Return DOCUMENTATION's human-readable summary, or #f."
      (reflect-documentation-field documentation 'documentation #f))

    (define (reflect-apropos-match kind name matched summary)
      "Return a compact apropos-match record."
      (list 'apropos-match
            (result-field 'kind kind)
            (result-field 'name name)
            (result-field 'matched matched)
            (result-field 'summary summary)))

    (define (reflect-apropos query context)
      "Search current documented bindings and the library catalog for QUERY."
      (let ((needle
             (string-downcase
              (cond
               ((string? query) query)
               ((symbol? query) (symbol->string query))
               (else (consent-value->external query))))))
        (append
         (let loop ((documents (reflect-documented-bindings context))
                    (result '()))
           (if (null? documents)
               (reverse result)
               (let* ((documentation (car documents))
                      (subject
                       (reflect-reflection-field documentation 'subject #f))
                      (name
                       (and (pair? subject)
                            (pair? (cdr subject))
                            (cadr subject)))
                      (summary
                       (reflect-documentation-summary documentation))
                      (name-match?
                       (and (symbol? name)
                            (reflect-string-contains?
                             (string-downcase (symbol->string name))
                             needle)))
                      (summary-match?
                       (and (string? summary)
                            (reflect-string-contains?
                             (string-downcase summary)
                             needle))))
                 (loop
                  (cdr documents)
                  (if (or name-match? summary-match?)
                      (cons
                       (reflect-apropos-match
                        'binding
                        name
                        (if summary-match?
                            '(documentation name)
                            '(name))
                        summary)
                       result)
                      result)))))
         (map
          (lambda (entry)
             (reflect-apropos-match
              'library
             (reflect-library-catalog-value entry 'name '())
             '(library)
             (reflect-library-catalog-value entry 'source-file #f)))
          (consent-library-catalog-search needle)))))

    (define (reflect-current-session-info context)
      "Return public session and event identity for CONTEXT."
      ;; Report the session id this evaluation runs under (matching the Emacs
      ;; twin); in the REPL each session's interaction context carries its own
      ;; id, so this agrees with `current-session'.
      (list 'session-info
            (result-field 'id (context-session-id context))
            (result-field 'job #f)
            (result-field 'events-used
                          (consent-make-canonical-integer
                           (context-event-count context)))))

    (define (reflect-entry-field entry field)
      "Return FIELD from a Scheme-readable reflection or audit ENTRY."
      (let ((cell (assq field (cdr entry))))
        (if cell (cadr cell) #f)))

    (define (reflect-filter predicate list)
      "Filter LIST by PREDICATE while preserving source order."
      (let loop ((rest list) (kept '()))
        (cond
         ((null? rest) (reverse kept))
         ((predicate (car rest))
          (loop (cdr rest) (cons (car rest) kept)))
         (else (loop (cdr rest) kept)))))

    (define (reflect-recent-yields context)
      "Return recent yield events from CONTEXT in emission order."
      (redaction-model:redact
       (reflect-filter
        (lambda (event)
          (and (pair? event) (eq? (car event) 'yield)))
        (reverse (context-audit-events context)))
       'runtime-reflection))

    (define (reflect-recent-errors context)
      "Return recent error conditions known to CONTEXT."
      (redaction-model:redact
       (if (context-current-error context)
           (list (context-current-error context))
           '())
       'runtime-reflection))

    (define (reflect-recent-policy-decisions context)
      "Return recent policy decisions from CONTEXT in emission order."
      (redaction-model:redact
       (reflect-filter
        (lambda (entry)
          (and (pair? entry)
               (eq? (car entry) 'audit-entry)
               (eq? (reflect-entry-field entry 'event) 'policy-decision)))
        (reverse (context-audit-events context)))
       'runtime-reflection))

    (define (primitive-consent-version arguments context)
      "Return the canonical Consent Scheme version datum."
      (consent-version))

    (define (primitive-current-capabilities arguments context)
      "Return the runtime capability metadata list."
      (redaction-model:redact (reflect-current-capabilities)
                              'runtime-reflection))

    (define (primitive-current-policy arguments context)
      "Return the runtime policy snapshot."
      (redaction-model:redact (reflect-current-policy context)
                              'runtime-reflection))

    (define (primitive-current-budget arguments context)
      "Return the current evaluation budget snapshot."
      (redaction-model:redact (reflect-current-budget context)
                              'runtime-reflection))

    (define (primitive-budget-remaining arguments context)
      "Return remaining budget headroom per enforced dimension."
      (redaction-model:redact (reflect-budget-remaining context)
                              'runtime-reflection))

    (define (primitive-budget-exhausted? arguments context)
      "Report whether ARGUMENT is a budget-exhaustion stop receipt."
      "Accepts a condition datum or an evaluation-result error datum so a"
      "caller can classify a recent error or a nested evaluation's outcome."
      (budget-exhausted-condition? (car arguments)))

    (define (primitive-budget-yield arguments context)
      "Emit the current budget ledger as a yield event and return it."
      (let ((ledger (reflect-current-budget context)))
        (record-agent-event! context (list 'yield ledger))
        (redaction-model:redact ledger 'runtime-reflection)))

    (define (primitive-current-imports arguments context)
      "Return the current import snapshot."
      (redaction-model:redact (reflect-current-imports context)
                              'runtime-reflection))

    (define (primitive-library-bindings arguments context)
      "Return exported bindings for a library name."
      (redaction-model:redact
       (reflect-library-bindings (car arguments) context)
       'runtime-reflection))

    (define (primitive-libraries arguments context)
      "Return catalog metadata for every known library."
      (redaction-model:redact (reflect-libraries) 'runtime-reflection))

    (define (primitive-library-info arguments context)
      "Return catalog metadata for one library name."
      (redaction-model:redact
       (reflect-library-info (car arguments))
       'runtime-reflection))

    (define (primitive-library-search arguments context)
      "Search catalog metadata."
      (redaction-model:redact
       (reflect-library-search (car arguments))
       'runtime-reflection))

    (define (primitive-catalog-sources arguments context)
      "Return manifest catalog source records."
      (redaction-model:redact
       (reflect-catalog-sources)
       'runtime-reflection))

    (define (primitive-catalog-diagnostics arguments context)
      "Return manifest catalog diagnostics."
      (redaction-model:redact
       (reflect-catalog-diagnostics)
       'runtime-reflection))

    (define (primitive-add-manifest! arguments context)
      "Add or replace an ad-hoc manifest datum."
      (redaction-model:redact
       (reflect-datumize
        (consent-library-catalog-add-manifest! (car arguments)
                                               (second arguments)))
       'runtime-reflection))

    (define (primitive-remove-manifest! arguments context)
      "Remove an ad-hoc manifest source."
      (consent-library-catalog-remove-manifest! (car arguments)))

    (define (primitive-add-manifest-root! arguments context)
      "Add or replace an explicit manifest-root input."
      (redaction-model:redact
       (reflect-datumize
        (consent-library-catalog-add-root! (car arguments)
                                           (second arguments)))
       'runtime-reflection))

    (define (primitive-remove-manifest-root! arguments context)
      "Remove an explicit manifest-root input."
      (consent-library-catalog-remove-root! (car arguments)))

    (define (primitive-refresh-library-catalog! arguments context)
      "Refresh catalog caches and diagnostics."
      (consent-library-catalog-refresh!))

    (define (primitive-library-documentation arguments context)
      "Return documentation records for one library's exports."
      (redaction-model:redact
       (reflect-library-documentation (car arguments))
       'runtime-reflection))

    (define (primitive-binding-libraries arguments context)
      "Return cataloged libraries exporting a binding name."
      (redaction-model:redact
       (reflect-binding-libraries (car arguments))
       'runtime-reflection))

    (define (primitive-documented-bindings arguments context)
      "Return documentation records for documented current bindings."
      (redaction-model:redact
       (reflect-documented-bindings context)
       'runtime-reflection))

    (define (primitive-apropos arguments context)
      "Search current documentation and the library catalog."
      (redaction-model:redact
       (reflect-apropos (car arguments) context)
       'runtime-reflection))

    (define (primitive-optional-default arguments offset)
      "Return optional default argument at OFFSET, or #f when absent."
      (if (> (length arguments) offset)
          (list-ref arguments offset)
          #f))

    (define (primitive-reflection-field arguments context)
      "Return a named field from a reflection record."
      (reflect-reflection-field
       (car arguments)
       (second arguments)
       (primitive-optional-default arguments 2)))

    (define (primitive-documentation-field arguments context)
      "Return a named metadata field from a documentation record."
      (reflect-documentation-field
       (car arguments)
       (second arguments)
       (primitive-optional-default arguments 2)))

    (define (primitive-docstring arguments context)
      "Return SUBJECT's documentation string."
      (reflect-docstring
       (car arguments)
       (primitive-optional-default arguments 1)
       context))

    (define (primitive-current-session-info arguments context)
      "Return current session metadata."
      (redaction-model:redact (reflect-current-session-info context)
                              'runtime-reflection))

    (define (primitive-recent-yields arguments context)
      "Return recent yield events."
      (reflect-recent-yields context))

    (define (primitive-recent-errors arguments context)
      "Return recent error records."
      (reflect-recent-errors context))

    (define (primitive-recent-policy-decisions arguments context)
      "Return recent policy decision records."
      (reflect-recent-policy-decisions context))

    (define (authorize-session-verb context operation)
      "Gate a mutating `(agent session)' verb on the window-session policy."
      "Records the capability request and decision, then raises fail-closed"
      "when window-session is not granted.  The portable host has no"
      "interactive confirmer, so only an explicit `allow' passes; the default"
      "`confirm' denies."
      (record-audit-event!
       context
       'capability-request
       (list (result-field 'domain 'session)
             (result-field 'operation operation)))
      (if (eq? (reflect-policy-action context 'window-session) 'allow)
          (record-policy-decision! context 'window-session operation 'allowed
                                   (list (result-field 'domain 'session)))
          (begin
            (record-policy-decision! context 'window-session operation 'denied
                                     (list (result-field 'domain 'session)))
            (eval-error
             (string-append operation
                            " requires policy-gated session access")))))

    (define (record-session-lifecycle! context operation id)
      "Record a `session-lifecycle' audit entry for OPERATION on session ID."
      (record-audit-event!
       context
       'session-lifecycle
       (list (result-field 'operation operation)
             (result-field 'session id))))

    (define (primitive-create-session arguments context)
      "Create a session with its own sandbox environment and return its datum."
      "Optional ARGUMENTS are a scope symbol (default `named') and an options"
      "alist overriding id and construction fields.  Does not change the"
      "default session."
      (authorize-session-verb context "create-session")
      (let* ((scope (if (null? arguments) 'named (car arguments)))
             (options (if (or (null? arguments) (null? (cdr arguments)))
                          '()
                          (cadr arguments)))
             (datum
              (portable-library-call session-model:session-manager-create!
                                     context
                                     (active-session-manager)
                                     scope
                                     options)))
        (record-session-lifecycle! context 'create
                                   (session-model:session-datum-id datum))
        (redaction-model:redact datum 'runtime-reflection)))

    (define (primitive-switch-session arguments context)
      "Switch the default session to the existing session named in ARGUMENTS."
      "Bound as both `switch-session' and `set-default-session!'; raises when"
      "the named session is unknown."
      (authorize-session-verb context "switch-session")
      (let ((datum
             (portable-library-call session-model:session-manager-switch!
                                    context
                                    (active-session-manager)
                                    (car arguments))))
        (if datum
            (begin
              (record-session-lifecycle! context 'switch (car arguments))
              (redaction-model:redact datum 'runtime-reflection))
            (eval-error "unknown session" (car arguments)))))

    (define (primitive-current-session arguments context)
      "Return the default session datum, or session info when none is selected."
      (let ((datum (session-model:session-manager-current
                    interpreter-session-manager)))
        (redaction-model:redact
         (or datum (reflect-current-session-info context))
         'runtime-reflection)))

    (define (primitive-list-sessions arguments context)
      "Return the manager's session datums, optionally filtered by scope."
      (redaction-model:redact
       (if (null? arguments)
           (session-model:session-manager-list interpreter-session-manager)
           (portable-library-call session-model:session-manager-list
                                  context
                                  interpreter-session-manager
                                  (car arguments)))
       'runtime-reflection))

    (define (primitive-close-session arguments context)
      "Retire the session named in ARGUMENTS and drop its live context."
      (authorize-session-verb context "close-session")
      (let ((datum
             (portable-library-call session-model:session-manager-close!
                                    context
                                    (active-session-manager)
                                    (car arguments))))
        (record-session-lifecycle! context 'close (car arguments))
        (redaction-model:redact datum 'runtime-reflection)))

    (define (primitive-capability-info arguments context)
      "Return metadata for one named capability."
      (redaction-model:redact (reflect-capability-info (car arguments))
                              'runtime-reflection))

    (define (primitive-documentation arguments context)
      "Return documentation metadata for a binding or procedure."
      (redaction-model:redact (reflect-documentation (car arguments) context)
                              'runtime-reflection))

    (define (primitive-consent-doc arguments context)
      "Return documentation metadata for a binding or procedure."
      (redaction-model:redact (reflect-documentation (car arguments) context)
                              'runtime-reflection))

    (define (primitive-consent-describe arguments context)
      "Return Scheme-readable description data for a binding or procedure."
      (redaction-model:redact (reflect-describe (car arguments) context)
                              'runtime-reflection))

    (define (macro-primitive-options arguments)
      "Return optional macro introspection options from primitive ARGUMENTS."
      (if (null? (cdr arguments)) '() (second arguments)))

    (define (primitive-macroexpand arguments context)
      "Return a full macro expansion record."
      (consent-macroexpand
       (car arguments)
       (context-interaction-environment context)
       context
       (macro-primitive-options arguments)))

    (define (primitive-macroexpand-1 arguments context)
      "Return a one-step macro expansion record."
      (consent-macroexpand-1
       (car arguments)
       (context-interaction-environment context)
       context
       (macro-primitive-options arguments)))

    (define (primitive-macroexpand-library arguments context)
      "Return macro export metadata for a library."
      (consent-macroexpand-library
       (car arguments)
       (context-interaction-environment context)
       context
       (macro-primitive-options arguments)))

    (define (primitive-macro-binding-info arguments context)
      "Return metadata for an active syntax binding."
      (consent-macro-binding-info
       (car arguments)
       (context-interaction-environment context)
       context))

    (define (primitive-syntax-source arguments context)
      "Return source metadata attached to a syntax datum, if any."
      (consent-syntax-source (car arguments)))

    (define (primitive-macroexpand-yield arguments context)
      "Record a macro expansion event and return the expansion record."
      (let ((result
             (consent-macroexpand
              (car arguments)
              (context-interaction-environment context)
              context
              (second arguments))))
        (record-agent-event! context (list 'macroexpand result))
        result))

    (define (primitive-current-error arguments context)
      "Return the active debugger condition, or #f outside error handling."
      (let ((current (context-current-error context)))
        (if current current #f)))

    (define (primitive-condition-stack arguments context)
      "Return a debugger condition's stack frames."
      (debugger-field-value
       (debugger-expect-condition (car arguments) "condition-stack")
       'stack))

    (define (primitive-condition-environment arguments context)
      "Return debugger environment frames, or one frame by id."
      (let* ((condition
              (debugger-expect-condition
               (car arguments)
               "condition-environment"))
             (frames (debugger-field-values condition 'environment))
             (frame-id (second arguments)))
        (if (not frame-id)
            frames
            (let ((name (debugger-restart-id-name frame-id)))
              (let loop ((rest frames))
                (cond
                 ((null? rest) #f)
                 ((eq? (debugger-field-value (car rest) 'frame) name)
                  (car rest))
                 (else (loop (cdr rest)))))))))

    (define (primitive-condition-restarts arguments context)
      "Return a debugger condition's restart records."
      (debugger-field-value
       (debugger-expect-condition (car arguments) "condition-restarts")
       'restarts))

    (define (primitive-restart-invoke! arguments context)
      "Invoke a debugger restart that can be modeled in portable Scheme."
      (let ((id (debugger-restart-id-name (car arguments)))
            (options (second arguments)))
        (cond
         ((eq? id 'continue-with-warning)
          (list 'restart-result
                (result-field 'id id)
                (result-field 'status 'continued)
                (result-field 'options options)))
         ((eq? id 'abort)
          (eval-error "debugger abort restart invoked"))
         (else
          (eval-error "restart requires host debugger policy" id)))))

    (define (primitive-debugger-yield arguments context)
      "Emit a structured debugger event into the current result stream."
      (let* ((condition (redaction-model:redact (car arguments) 'debugger))
             (event (list 'debugger condition)))
        (record-agent-event! context event)
        consent-unspecified))

    (define (primitive-approval-request! arguments context)
      "Create a portable approval request and return its id."
      (portable-library-call approval-model:approval-store-request!
                             context
                             interpreter-approval-store
                             (car arguments)))

    (define (primitive-approval-status arguments context)
      "Return a portable approval request status, or #f when unknown."
      (portable-library-call approval-model:approval-store-status
                             context
                             interpreter-approval-store
                             (car arguments)))

    (define (primitive-approval-cancel! arguments context)
      "Cancel a portable approval request."
      (portable-library-call approval-model:approval-store-cancel!
                             context
                             interpreter-approval-store
                             (car arguments)))

    (define (primitive-approval-yield-pending arguments context)
      "Yield all pending portable approval requests."
      (let ((records
             (approval-model:approval-store-pending interpreter-approval-store)))
        (for-each
         (lambda (record)
           (record-agent-event! context (list 'yield record)))
         records)
        records))

    (define (approval-resolution-allowed? context)
      "Report whether CONTEXT allows Scheme-side approval resolution."
      (let ((entry (assq 'approval-resolution
                         (context-policy-actions context))))
        (and entry (eq? (cdr entry) 'allow))))

    (define (primitive-approval-resolve! arguments context)
      "Resolve a portable approval only when policy explicitly allows it."
      (if (not (approval-resolution-allowed? context))
          (eval-error "approval resolution is host-side only"))
      (portable-library-call approval-model:approval-store-resolve!
                             context
                             interpreter-approval-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-job-start! arguments context)
      "Create a portable queued job record and return its job datum."
      (portable-library-call job-model:job-store-start!
                             context
                             interpreter-job-store
                             (car arguments)
                             (second arguments)
                             (third arguments)))

    (define (primitive-job-ref arguments context)
      "Return a portable job record, or #f when unknown."
      (portable-library-call job-model:job-store-ref
                             context
                             interpreter-job-store
                             (car arguments)))

    (define (primitive-job-list arguments context)
      "Return portable job records, optionally scoped to one session."
      (if (null? arguments)
          (job-model:job-store-list interpreter-job-store)
          (portable-library-call job-model:job-store-list
                                 context
                                 interpreter-job-store
                                 (car arguments))))

    (define (primitive-job-cancel! arguments context)
      "Request cooperative cancellation of a portable job record."
      (portable-library-call job-model:job-store-cancel!
                             context
                             interpreter-job-store
                             (car arguments)))

    (define (primitive-job-interrupt! arguments context)
      "Request cooperative interrupt of a portable job record."
      (portable-library-call job-model:job-store-interrupt!
                             context
                             interpreter-job-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-job-yields arguments context)
      "Return portable job stream events, optionally after an offset."
      (portable-library-call job-model:job-store-yields
                             context
                             interpreter-job-store
                             (car arguments)
                             (if (null? (cdr arguments))
                                 '()
                                 (second arguments))))

    (define (primitive-job-status arguments context)
      "Return a portable job status, or #f when unknown."
      (portable-library-call job-model:job-store-status
                             context
                             interpreter-job-store
                             (car arguments)))

    (define (capability-grant-field datum field)
      "Return FIELD from Scheme-readable grant DATUM, or #f when absent."
      (let loop ((fields (if (pair? datum) (cdr datum) '())))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields)) (eq? (caar fields) field))
          (car fields))
         (else (loop (cdr fields))))))

    (define (capability-grant-id grant)
      "Return GRANT's id or raise a portable evaluator error."
      (let ((field (capability-grant-field grant 'id)))
        (if field
            (second field)
            (eval-error "capability grant requires an id field"))))

    (define (capability-grant-status grant)
      "Return GRANT status, defaulting to active."
      (let ((field (capability-grant-field grant 'status)))
        (if field (second field) 'active)))

    (define (capability-grant-remove-fields grant names)
      "Remove fields named by NAMES from GRANT."
      (cons
       (car grant)
       (let loop ((fields (cdr grant)))
         (cond
          ((null? fields) '())
          ((memq (caar fields) names) (loop (cdr fields)))
          (else (cons (car fields) (loop (cdr fields))))))))

    (define (capability-grant-replace-field grant name values)
      "Return GRANT with one field replaced by VALUES."
      (let loop ((fields (cdr grant)) (seen? #f))
        (cond
         ((null? fields)
          (if seen?
              (list (car grant))
              (list (car grant) (cons name values))))
         ((eq? (caar fields) name)
          (cons (car grant)
                (cons (cons name values)
                      (cdr fields))))
         (else
          (let ((rest (loop (cdr fields) seen?)))
            (cons (car rest)
                  (cons (car fields) (cdr rest))))))))

    (define (normalize-capability-grant datum)
      "Return a normalized portable capability grant datum."
      (if (not (and (pair? datum) (eq? (car datum) 'capability-grant)))
          (eval-error "grant-capability! expects a capability-grant datum"))
      (let ((without-status
             (capability-grant-remove-fields datum '(status))))
        (capability-grant-replace-field
         without-status
         'status
         '(active))))

    (define (capability-grant-has-id? grant id)
      "Return GRANT if it has ID."
      (equal? (capability-grant-id grant) id))

    (define (capability-grant-find grants id)
      "Return grant ID from GRANTS or #f."
      (cond
       ((null? grants) #f)
       ((capability-grant-has-id? (car grants) id) (car grants))
       (else (capability-grant-find (cdr grants) id))))

    (define (capability-grant-store! context grant)
      "Store GRANT in CONTEXT, replacing any existing grant with the same id."
      (let ((id (capability-grant-id grant)))
        (let loop ((grants (context-capability-grants context))
                   (kept '()))
          (cond
           ((null? grants)
            (set-context-capability-grants!
             context
             (append (reverse kept) (list grant)))
            grant)
           ((capability-grant-has-id? (car grants) id)
            (loop (cdr grants) kept))
           (else
            (loop (cdr grants) (cons (car grants) kept)))))))

    (define (primitive-grant-capability! arguments context)
      "Create a portable capability grant in the current context."
      (capability-grant-store!
       context
       (normalize-capability-grant (car arguments))))

    (define (primitive-current-grants arguments context)
      "Return active portable capability grants in the current context."
      (let loop ((grants (context-capability-grants context)))
        (cond
         ((null? grants) '())
         ((eq? (capability-grant-status (car grants)) 'active)
          (cons (car grants) (loop (cdr grants))))
         (else (loop (cdr grants))))))

    (define (primitive-grant-ref arguments context)
      "Return a portable capability grant by id, or #f when unknown."
      (let ((grant
             (capability-grant-find
              (context-capability-grants context)
              (car arguments))))
        (if grant grant #f)))

    (define (primitive-grant-attenuate arguments context)
      "Create a portable attenuated child grant by replacing declared fields."
      (let* ((parent
              (or (capability-grant-find
                   (context-capability-grants context)
                   (car arguments))
                  (eval-error "unknown parent capability grant")))
             (restrictions (second arguments))
             (id-field (assq 'id restrictions))
             (child
              (capability-grant-remove-fields
               parent
               '(id status parent))))
        (if (not (eq? (capability-grant-status parent) 'active))
            (eval-error "cannot attenuate inactive capability grant"))
        (for-each
         (lambda (field)
           (if (and (memq (car field) '(library effect))
                    (not (equal? (capability-grant-field parent (car field))
                                 field)))
               (eval-error
                "attenuated grant cannot broaden parent authority"))
           (if (not (eq? (car field) 'id))
               (set! child
                     (capability-grant-replace-field
                      child
                      (car field)
                      (cdr field)))))
         restrictions)
        (set! child
              (capability-grant-replace-field
               child
               'id
               (list (if id-field (second id-field) 'attenuated-grant))))
        (set! child
              (capability-grant-replace-field
               child
               'parent
               (list (capability-grant-id parent))))
        (capability-grant-store!
         context
         (normalize-capability-grant child))))

    (define (primitive-grant-revoke! arguments context)
      "Revoke a portable capability grant in the current context."
      (let* ((grant
              (or (capability-grant-find
                   (context-capability-grants context)
                   (car arguments))
                  (eval-error "unknown capability grant")))
             (revoked
              (capability-grant-replace-field grant 'status '(revoked))))
        (capability-grant-store! context revoked)
        (record-audit-event!
         context
         'capability-revocation
         (list (list 'revocation
                     (list 'capability-revocation
                           (list 'target
                                 (list 'grant
                                       (capability-grant-id grant)))
                           (list 'status 'revoked)
                           (list 'reason "grant-revoke!")))
               (list 'target
                     (list 'grant (capability-grant-id grant)))
               (list 'status 'revoked)
               (list 'reason "grant-revoke!")))))

    (define (primitive-call-with-capability-grant arguments context)
      "Call THUNK with GRANT present in the portable context."
      (let ((grant-or-id (car arguments))
            (thunk (second arguments)))
        (if (and (pair? grant-or-id)
                 (eq? (car grant-or-id) 'capability-grant))
            (primitive-grant-capability! (list grant-or-id) context)
            (if (not (capability-grant-find
                      (context-capability-grants context)
                      grant-or-id))
                (eval-error "unknown capability grant")))
        (apply-procedure thunk '() context #f)))

    (define (portable-handle-datum? value)
      "Return true when VALUE is a Scheme-readable handle datum."
      (and (pair? value)
           (or (eq? (car value) 'handle)
               (eq? (car value) 'port-capability))))

    (define (portable-handle-field datum field)
      "Return FIELD from portable handle DATUM, or #f."
      (let loop ((fields (if (pair? datum) (cdr datum) '())))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields)) (eq? (caar fields) field))
          (car fields))
         (else (loop (cdr fields))))))

    (define (portable-handle-field-value datum field)
      "Return FIELD's first value from portable handle DATUM, or #f."
      (let ((entry (portable-handle-field datum field)))
        (if entry (second entry) #f)))

    (define (portable-port-kind port)
      "Return PORT's portable capability kind."
      (cond
       ((and (consent-port-input? port)
             (consent-port-textual? port))
        'textual-input)
       ((and (consent-port-input? port)
             (consent-port-binary? port))
        'binary-input)
       ((and (consent-port-output? port)
             (consent-port-textual? port))
        'textual-output)
       ((and (consent-port-output? port)
             (consent-port-binary? port))
        'binary-output)
       (else 'port)))

    (define (portable-port-handle-metadata port)
      "Return Scheme-readable lifecycle metadata for host-backed PORT."
      (if (and (consent-port? port)
               (consent-port-backing-domain port))
          (port-capability-datum
           (consent-port-handle port)
           (portable-port-kind port)
           (consent-port-backing-domain port)
           (consent-port-operations port)
           (consent-port-grant port)
           (consent-port-limits port)
           (consent-port-status port)
           (consent-port-path port))
          #f))

    (define (portable-port-live? port context)
      "Return true when host-backed PORT is open and its grant is active."
      (and (consent-port? port)
           (consent-port-backing-domain port)
           (consent-port-open? port)
           (eq? (consent-port-status port) 'open)
           (let ((grant
                  (and context
                       (capability-grant-find
                        (context-capability-grants context)
                        (consent-port-grant port)))))
             (and grant
                  (eq? (capability-grant-status grant) 'active)))))

    (define (portable-handle-live? value context)
      "Return true when VALUE describes a portable live handle."
      (cond
       ((consent-port? value)
        (portable-port-live? value context))
       ((portable-handle-datum? value)
        (let ((status (portable-handle-field-value value 'status)))
          (or (eq? status 'live)
              (eq? status 'open))))
       (else #f)))

    (define (portable-handle-replace-status datum status)
      "Return portable handle DATUM with STATUS replacing its status field."
      (let loop ((fields (cdr datum)) (seen? #f))
        (cond
         ((null? fields)
          (if seen?
              (list (car datum))
              (list (car datum) (list 'status status))))
         ((and (pair? (car fields)) (eq? (caar fields) 'status))
          (cons (car datum)
                (cons (list 'status status)
                      (cdr fields))))
         (else
          (cons (car datum)
                (cons (car fields)
                      (cdr (loop (cdr fields) seen?))))))))

    (define (primitive-handle-ref arguments context)
      "Return portable lifecycle metadata for a handle datum or port."
      (let ((value (car arguments)))
        (cond
         ((consent-port? value)
          (portable-port-handle-metadata value))
         ((portable-handle-datum? value) value)
         (else #f))))

    (define (primitive-handle-live? arguments context)
      "Return true when the portable handle is live."
      (portable-handle-live? (car arguments) context))

    (define (primitive-handle-kind arguments context)
      "Return the portable handle kind, or #f when unknown."
      (let ((value (car arguments)))
        (cond
         ((consent-port? value)
          (portable-port-kind value))
         ((portable-handle-datum? value)
          (portable-handle-field-value value 'kind))
         (else #f))))

    (define (primitive-handle-revalidate arguments context)
      "Revalidate a portable handle and return metadata when known."
      (let ((value (car arguments)))
        (cond
         ((consent-port? value)
          (let ((metadata (portable-port-handle-metadata value)))
            (if (and metadata (not (portable-port-live? value context)))
                (portable-handle-replace-status metadata 'stale)
                metadata)))
         ((portable-handle-datum? value)
          (if (portable-handle-live? value context)
              value
              (portable-handle-replace-status value 'stale)))
         (else #f))))

    (define (primitive-handle-release! arguments context)
      "Return released portable lifecycle metadata when VALUE is known."
      (let ((value (car arguments)))
        (cond
         ((consent-port? value)
          (let ((metadata (portable-port-handle-metadata value)))
            (if metadata
                (begin
                  (set-consent-port-open?! value #f)
                  (set-consent-port-status! value 'released)
                  (portable-handle-replace-status metadata 'released))
                #f)))
         ((portable-handle-datum? value)
          (portable-handle-replace-status value 'released))
         (else #f))))

    (define (primitive-memory-put! arguments context)
      "Store a keyed memory record in the portable interpreter memory store."
      (portable-library-call memory-model:memory-store-put!
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)
                             (third arguments)))

    (define (primitive-memory-ref arguments context)
      "Return a keyed memory record or #f from the portable memory store."
      (portable-library-call memory-model:memory-store-ref
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-memory-delete! arguments context)
      "Delete a keyed memory record from the portable memory store."
      (portable-library-call memory-model:memory-store-delete!
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-memory-add! arguments context)
      "Add a generated memory record to the portable memory store."
      (portable-library-call memory-model:memory-store-add!
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)
                             (third arguments)))

    (define (primitive-memory-find arguments context)
      "Find matching memory records in the portable memory store."
      (portable-library-call memory-model:memory-store-find
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-memory-by-tag arguments context)
      "Find tagged memory records in the portable memory store."
      (portable-library-call memory-model:memory-store-by-tag
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-memory-recent arguments context)
      "Return recent memory records from the portable memory store."
      (portable-library-call memory-model:memory-store-recent
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)))

    (define (primitive-memory-access! arguments context)
      "Append a memory access event to the portable memory store."
      (portable-library-call memory-model:memory-store-access!
                             context
                             interpreter-memory-store
                             (second arguments)
                             (car arguments)
                             (third arguments)))

    (define (primitive-memory-reflect! arguments context)
      "Append a gated reflection datum to the portable memory store."
      (portable-library-call memory-model:memory-store-reflect!
                             context
                             interpreter-memory-store
                             (car arguments)
                             (second arguments)
                             (third arguments)
                             (fourth arguments)
                             (list-ref arguments 4)
                             (list-ref arguments 5)))

    (define (primitive-memory-select arguments context)
      "Select memory records with a replayable receipt."
      (portable-library-call memory-model:memory-store-select
                             context
                             interpreter-memory-store
                             (second arguments)
                             (third arguments)
                             (fourth arguments)))

    (define (primitive-memory-yield arguments context)
      "Yield matching memory records through the event channel."
      (let ((records
             (portable-library-call memory-model:memory-store-find
                                    context
                                    interpreter-memory-store
                                    (car arguments)
                                    (second arguments))))
        (for-each
         (lambda (record)
           (record-agent-event! context (list 'yield record)))
         records)
        records))

    (define (helper-option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT if absent."
      (let ((entry (assq key options)))
        (if entry
            (let ((value (cdr entry)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (helper-default-scope context)
      "Return the default helper scope for CONTEXT."
      (if (context-session-id context)
          'session
          'project-private))

    (define (helper-options arguments)
      "Return helper options from optional primitive ARGUMENTS."
      (if (and (pair? arguments) (pair? (cdr arguments)) (pair? (cddr arguments)))
          (third arguments)
          '()))

    (define (helper-scope options context)
      "Return helper scope from OPTIONS and CONTEXT."
      (let ((scope (helper-option-ref options
                                      'scope
                                      (helper-default-scope context))))
        (if (eq? scope 'project)
            'project-private
            scope)))

    (define (helper-source scope context)
      "Return a Scheme-readable source datum for helper SCOPE and CONTEXT."
      (if (eq? scope 'session)
          (list 'session (context-session-id context))
          '(project-root portable)))

    (define (primitive-agent-artifact arguments context)
      "Save a structured helper artifact and yield it through the event channel."
      (let* ((scope (helper-default-scope context))
            (record
              (portable-library-call helper-model:helper-store-artifact-save!
                                     context
                                     interpreter-helper-store
                                     scope
                                     (car arguments)
                                     (second arguments)
                                     (helper-source scope context))))
        (record-agent-event! context (list 'yield record))
        record))

    (define (primitive-agent-helper-save! arguments context)
      "Save helper source forms in the portable helper store."
      (let* ((options (helper-options arguments))
             (scope (helper-scope options context))
            (record
              (portable-library-call helper-model:helper-store-save!
                                     context
                                     interpreter-helper-store
                                     scope
                                     (car arguments)
                                     (second arguments)
                                     (helper-source scope context))))
        (record-audit-event!
         context
         'agent-helper
         (list (list 'operation "agent-helper-store-save!")
               (list 'scope scope)
               (list 'library (helper-model:helper-record-name record))
               (list 'record record)))
        record))

    (define (helper-record-ref library-name options context)
      "Return a helper record by library name and options, or #f."
      (portable-library-call helper-model:helper-store-ref
                             context
                             interpreter-helper-store
                             (helper-scope options context)
                             library-name))

    (define (primitive-agent-helper-load arguments context)
      "Load helper source forms into the current interaction environment."
      (let* ((options (if (pair? (cdr arguments)) (second arguments) '()))
             (record (helper-record-ref (car arguments) options context)))
        (if (not record)
            (eval-error "unknown helper library" (car arguments)))
        (drain-state
         (eval-sequence (helper-model:helper-record-forms record)
                        (context-interaction-environment context)
                        context
                        #t
                        #t)
         context)
        record))

    (define (primitive-agent-helper-list arguments context)
      "Return portable helper records in a scope."
      (portable-library-call helper-model:helper-store-list
                             context
                             interpreter-helper-store
                             (car arguments)))

    (define (primitive-agent-helper-ref arguments context)
      "Return one portable helper record or #f."
      (let ((options (if (pair? (cdr arguments)) (second arguments) '())))
        (helper-record-ref (car arguments) options context)))

    (define (primitive-agent-helper-promote-to-skill arguments context)
      "Promote a portable helper into a skill candidate datum."
      (let* ((helper-or-name (car arguments))
             (options (if (pair? (cdr arguments)) (second arguments) '()))
             (record (if (and (pair? helper-or-name)
                              (eq? (car helper-or-name)
                                   'agent-helper-library))
                         helper-or-name
                         (helper-record-ref helper-or-name options context))))
        (if (not record)
            (eval-error "unknown helper library" helper-or-name))
        (portable-library-call helper-model:helper-promote-to-skill
                               context
                               record
                               options)))

    ;; Budget option names accepted by source-string self-tests.
    (define agent-test-budget-option-keys
      '(max-steps
        max-non-tail-steps
        max-value-nodes
        max-source-metadata
        max-interned-symbols
        max-host-callbacks
        max-events
        max-event-nodes
        max-output-bytes
        max-wall-time-ms))

    (define (agent-test-budget-option? key)
      "Return #t when KEY names an allowed self-test budget option."
      (memq key agent-test-budget-option-keys))

    (define (agent-test-option-entry entry)
      "Return one normalized evaluator option entry, or #f for unknown keys."
      (let ((elements (proper-list-elements entry "agent test option")))
        (if (and (= (length elements) 2)
                 (agent-test-budget-option? (car elements)))
            (cons (car elements)
                  (exact-integer->host
                   (second elements)
                   "agent test budget option"))
            #f)))

    (define (agent-test-options options)
      "Return OPTIONS restricted to budget controls for nested source tests."
      (let loop ((rest (proper-list-elements options "agent test options"))
                 (result '()))
        (cond
         ((null? rest) (reverse result))
         ((agent-test-option-entry (car rest))
          => (lambda (entry)
               (loop (cdr rest) (cons entry result))))
         (else
          (loop (cdr rest) result)))))

    (define (primitive-agent-test-eval-source-result arguments context)
      "Evaluate one declared source-string test under normal evaluator policy."
      (let ((source (expect-string
                     (car arguments)
                     "agent-test-eval-source-result source"))
            (options (if (pair? (cdr arguments)) (second arguments) '())))
        (consent-eval-source-result
         source
         #f
         (agent-test-options options))))

    (define (plan-memory-scope plan-scope)
      "Return the memory scope corresponding to PLAN-SCOPE."
      (if (eq? plan-scope 'fresh)
          'instance
          plan-scope))

    (define (primitive-plan-create! arguments context)
      "Create or replace a portable plan record."
      (let* ((datum (car arguments))
             (record
              (portable-library-call plan-model:plan-store-create!
                                     context
                                     interpreter-plan-store
                                     datum)))
        (if (portable-library-call plan-model:plan-memory-important?
                                   context
                                   datum)
            (portable-library-call memory-model:memory-store-put!
                                   context
                                   interpreter-memory-store
                                   (plan-memory-scope
                                    (plan-model:plan-record-scope record))
                                   (plan-model:plan-record-id record)
                                   (list
                                    (list 'tags '(plan important))
                                    (list 'value record)
                                    (list 'source '(agent-plan))
                                    (list 'confidence 'high))))
        (record-audit-event!
         context
         'agent-plan
         (list (list 'operation "plan-store-create!")
               (list 'plan (plan-model:plan-record-id record))
               (list 'scope (plan-model:plan-record-scope record))
               (list 'record record)))
        record))

    (define (primitive-plan-ref arguments context)
      "Return a portable plan record by id, or #f."
      (portable-library-call plan-model:plan-store-ref
                             context
                             interpreter-plan-store
                             (car arguments)))

    (define (primitive-plan-list arguments context)
      "Return portable plans in a scope."
      (portable-library-call plan-model:plan-store-list
                             context
                             interpreter-plan-store
                             (car arguments)))

    (define (primitive-plan-step-add! arguments context)
      "Add a step to a portable plan."
      (let ((record
             (portable-library-call plan-model:plan-store-step-add!
                                    context
                                    interpreter-plan-store
                                    (car arguments)
                                    (second arguments))))
        (record-audit-event!
         context
         'agent-plan
         (list (list 'operation "plan-store-step-add!")
               (list 'plan (plan-model:plan-record-id record))
               (list 'record record)))
        record))

    (define (primitive-plan-step-status! arguments context)
      "Update a portable plan step status."
      (let ((record
             (portable-library-call plan-model:plan-store-step-status!
                                    context
                                    interpreter-plan-store
                                    (car arguments)
                                    (second arguments)
                                    (third arguments))))
        (record-audit-event!
         context
         'agent-plan
         (list (list 'operation "plan-store-step-status!")
               (list 'plan (plan-model:plan-record-id record))
               (list 'step (second arguments))
               (list 'status (third arguments))
               (list 'record record)))
        record))

    (define (primitive-plan-status! arguments context)
      "Update a portable plan status."
      (let ((record
             (portable-library-call plan-model:plan-store-status!
                                    context
                                    interpreter-plan-store
                                    (car arguments)
                                    (second arguments))))
        (record-audit-event!
         context
         'agent-plan
         (list (list 'operation "plan-store-status!")
               (list 'plan (plan-model:plan-record-id record))
               (list 'status (second arguments))
               (list 'record record)))
        record))

    (define (primitive-plan-yield arguments context)
      "Yield a portable plan through the event channel."
      (let ((record
             (portable-library-call plan-model:plan-store-ref
                                    context
                                    interpreter-plan-store
                                    (car arguments))))
        (if (not record)
            (eval-error "unknown plan"))
        (record-agent-event! context (list 'yield record))
        (record-audit-event!
         context
         'agent-plan
         (list (list 'operation "plan-yield")
               (list 'plan (plan-model:plan-record-id record))
               (list 'scope (plan-model:plan-record-scope record))))
        record))

    (define (model-record-head datum)
      "Return DATUM's model-record head or #f for association-list payloads."
      (if (and (pair? datum)
               (not (and (pair? (car datum))
                         (symbol? (caar datum))))
               (symbol? (car datum)))
          (car datum)
          #f))

    (define (model-field-values datum)
      "Return model field pairs from DATUM."
      (if (not (pair? datum))
          '()
          (let ((fields (if (model-record-head datum)
                            (cdr datum)
                            datum)))
            (let loop ((cursor fields) (result '()))
              (cond
               ((null? cursor) (reverse result))
               ((and (pair? (car cursor))
                     (symbol? (caar cursor)))
                (loop (cdr cursor) (cons (car cursor) result)))
               (else (loop (cdr cursor) result)))))))

    (define (model-field-value datum name default)
      "Return field NAME from DATUM, or DEFAULT."
      (let loop ((fields (model-field-values datum)))
        (cond
         ((null? fields) default)
         ((eq? (car (car fields)) name)
          (if (null? (cdr (car fields)))
              default
              (car (cdr (car fields)))))
         (else (loop (cdr fields))))))

    (define (model-name value description)
      "Return VALUE as a provider/model name."
      (cond
       ((symbol? value) value)
       ((string? value) (string->symbol value))
       (else (eval-error
              (string-append description " must be a symbol or string")
              value))))

    (define (model-name-string value description)
      "Return VALUE as a provider/model name string."
      (symbol->string (model-name value description)))

    (define (model-name-list datum description)
      "Return DATUM as a list of model names."
      (map (lambda (item) (model-name item description))
           (proper-list-elements datum description)))

    (define (model-truthy? value)
      "Return VALUE's truth value using Scheme conventions."
      (if value #t #f))

    (define (model-normalize-model datum)
      "Normalize a model profile datum."
      (list
       (cons 'id (model-name (model-field-value datum 'id #f)
                             "model id"))
       (cons 'roles
             (model-name-list (model-field-value datum 'roles '())
                              "model roles"))
       (cons 'privacy
             (model-name (model-field-value datum 'privacy 'public)
                         "model privacy"))
       (cons 'status
             (model-name (model-field-value datum 'status 'available)
                         "model status"))
       (cons 'raw datum)))

    (define (model-normalize-provider datum)
      "Normalize a provider profile datum."
      (if (not (eq? (model-record-head datum) 'model-provider))
          (eval-error
           "model-provider-register! expects a model-provider datum"
           datum))
      (list
       (cons 'id (model-name (model-field-value datum 'id #f)
                             "provider id"))
       (cons 'kind
             (model-name (model-field-value datum 'kind 'local)
                         "provider kind"))
       (cons 'transport
             (model-name
              (model-field-value datum 'transport 'openai-compatible-http)
              "provider transport"))
       (cons 'endpoint (model-field-value datum 'endpoint #f))
       (cons 'credentials (model-field-value datum 'credentials #f))
       (cons 'available
             (model-truthy? (model-field-value datum 'available #t)))
       (cons 'models
             (map model-normalize-model
                  (proper-list-elements
                   (model-field-value datum 'models '())
                   "provider models")))
       (cons 'raw datum)))

    (define (model-entry-ref entry field)
      "Return FIELD from normalized model/provider ENTRY."
      (let ((cell (assq field entry)))
        (if cell (cdr cell) #f)))

    (define (model-register-provider! provider)
      "Replace existing provider with PROVIDER by id."
      (let ((id (model-entry-ref provider 'id)))
        (let loop ((cursor interpreter-model-providers) (result '()))
          (cond
           ((null? cursor)
            (set! interpreter-model-providers
                  (append (reverse result) (list provider))))
           ((eq? id (model-entry-ref (car cursor) 'id))
            (set! interpreter-model-providers
                  (append (reverse result) (cons provider (cdr cursor)))))
           (else (loop (cdr cursor) (cons (car cursor) result)))))))

    (define (model-available? model)
      "Return #t when MODEL is selectable."
      (let ((status (model-entry-ref model 'status)))
        (or (eq? status 'available)
            (eq? status 'ready))))

    (define (model-role? model role)
      "Return #t when ROLE is declared by MODEL."
      (let loop ((roles (model-entry-ref model 'roles)))
        (cond
         ((null? roles) #f)
         ((eq? (car roles) role) #t)
         (else (loop (cdr roles))))))

    (define (model-role-candidates role)
      "Return route candidates for ROLE."
      (let provider-loop ((providers interpreter-model-providers)
                          (local '())
                          (remote '()))
        (if (null? providers)
            (append (reverse local) (reverse remote))
            (let ((provider (car providers)))
              (let model-loop ((models (model-entry-ref provider 'models))
                               (next-local local)
                               (next-remote remote))
                (if (null? models)
                    (provider-loop (cdr providers)
                                   next-local
                                   next-remote)
                    (let ((model (car models)))
                      (if (and (model-entry-ref provider 'available)
                               (model-available? model)
                               (model-role? model role))
                          (if (eq? (model-entry-ref provider 'kind) 'local)
                              (model-loop (cdr models)
                                          (cons (cons provider model)
                                                next-local)
                                          next-remote)
                              (model-loop (cdr models)
                                          next-local
                                          (cons (cons provider model)
                                                next-remote)))
                          (model-loop (cdr models)
                                      next-local
                                      next-remote)))))))))

    (define (model-select role)
      "Return selected provider/model candidate for ROLE."
      (let ((candidates (model-role-candidates role)))
        (if (null? candidates) #f (car candidates))))

    (define (model-routing-decision role candidate)
      "Return a Scheme-readable routing decision."
      (if candidate
          (let ((provider (car candidate))
                (model (cdr candidate)))
            (append
             (list 'model-routing-decision
                   (list 'status 'selected)
                   (list 'role role)
                   (list 'provider (model-entry-ref provider 'id))
                   (list 'model (model-entry-ref model 'id))
                   (list 'kind (model-entry-ref provider 'kind))
                   (list 'transport (model-entry-ref provider 'transport)))
             (let ((endpoint (model-entry-ref provider 'endpoint)))
               (if endpoint
                   (list (list 'endpoint endpoint))
                   '()))))
          (list 'model-routing-decision
                (list 'status 'unavailable)
                (list 'role role)
                (list 'reason
                      "no registered provider model supports role"))))

    (define (model-diagnostic model)
      "Return a model diagnostic datum."
      (list
       (list 'model (model-entry-ref model 'id))
       (list 'roles (model-entry-ref model 'roles))
       (list 'status (model-entry-ref model 'status))
       (list 'privacy (model-entry-ref model 'privacy))))

    (define (model-provider-diagnostic provider)
      "Return a provider diagnostic datum."
      (append
       (list
        (list 'provider (model-entry-ref provider 'id))
        (list 'kind (model-entry-ref provider 'kind))
        (list 'transport (model-entry-ref provider 'transport))
        (list 'available (model-entry-ref provider 'available)))
       (let ((endpoint (model-entry-ref provider 'endpoint)))
         (if endpoint (list (list 'endpoint endpoint)) '()))
       (let ((credentials (model-entry-ref provider 'credentials)))
         (if credentials
             (list (list 'credentials
                         (redaction-model:redact credentials
                                                 'model-diagnostics)))
             '()))
       (list
        (list 'models
              (map model-diagnostic
                   (model-entry-ref provider 'models))))))

    (define (primitive-model-provider-register! arguments context)
      "Register a portable model provider profile."
      (let ((provider (model-normalize-provider (car arguments))))
        (model-register-provider! provider)
        (model-provider-diagnostic provider)))

    (define (primitive-model-providers arguments context)
      "Return registered provider diagnostics."
      (list 'providers
            (map model-provider-diagnostic interpreter-model-providers)))

    (define (primitive-model-route arguments context)
      "Return a portable model routing decision."
      (let* ((role (model-name (car arguments) "model role"))
             (candidate (model-select role)))
        (model-routing-decision role candidate)))

    (define (primitive-model-complete arguments context)
      "Complete through the portable local OpenAI-compatible transport."
      (let* ((role (model-name (car arguments) "model role"))
             (prompt (expect-string (cadr arguments) "model-complete prompt"))
             (options (if (null? (cddr arguments)) '() (third arguments)))
             (candidate (model-select role)))
        (if (not candidate)
            (eval-error "no registered provider model supports role" role)
            (portable-library-call
             model-openai:model-openai-compatible-http-complete
             context
             (car candidate)
             (cdr candidate)
             role
             prompt
             options))))

    (define (primitive-model-provider-diagnostics arguments context)
      "Return redacted portable model provider diagnostics."
      (list 'model-provider-diagnostics
            (list 'providers
                  (map model-provider-diagnostic
                       interpreter-model-providers))))

    (define (primitive-secret-source? arguments context)
      "Report whether a datum contains secret-prone source data."
      (if (redaction-model:secret-source? (car arguments)) #t #f))

    (define (primitive-redact arguments context)
      "Return a datum with secrets and local-only context redacted."
      (redaction-model:redact (car arguments) (second arguments)))

    (define (primitive-context-local-only! arguments context)
      "Mark a datum as local-only context."
      (redaction-model:context-local-only! (car arguments)
                                           (second arguments)))

    (define (primitive-redaction-log arguments context)
      "Return the portable redaction decision log."
      (if (null? arguments)
          (redaction-model:redaction-log)
          (redaction-model:redaction-log (car arguments))))

    (define (primitive-safe-for-provider? arguments context)
      "Report whether a datum can be routed to a provider without redaction."
      (if (redaction-model:safe-for-provider? (car arguments)
                                              (second arguments))
          #t
          #f))

    (define (record-policy-decision! context category operation decision fields)
      "Record a portable policy decision into the context audit event list."
      (record-audit-event!
       context
       'policy-decision
       (append
        (list (result-field 'category category)
              (result-field 'operation operation)
              (result-field 'decision decision))
        fields)))

    (define (policy-denied description context fields)
      "Raise a policy-gated host-access denial for DESCRIPTION."
      (record-policy-decision!
       context
       'standard-host-effect
       description
       'denied
       fields)
      (eval-error
       (string-append description " requires policy-gated host access")))

    (define (policy-denied-primitive description)
      "Return a primitive callback that always raises a policy denial."
      (lambda (arguments context)
        (policy-denied description context '())))

    (define (interaction-environment-fields session-id)
      "Return audit fields for a session-scoped interaction environment."
      (if session-id
          (list (list 'session session-id))
          '()))

    (define (deny-interaction-environment! context reason fields)
      "Record and raise an interaction-environment denial before exposing state."
      (record-audit-event!
       context
       'policy-decision
       (append
        (list (list 'category 'standard-host-effect)
              (list 'operation "interaction-environment")
              (list 'decision 'denied)
              (list 'reason reason))
        fields))
      (eval-error reason))

    (define (primitive-interaction-environment arguments context)
      "Implement `interaction-environment` as a session-gated mutable specifier."
      (let ((session-id (context-session-id context))
            (environment (context-interaction-environment context))
            (syntax-environment (context-syntax-environment context)))
        (if (or (not session-id) (not environment) (not syntax-environment))
            (deny-interaction-environment!
             context
             "interaction-environment requires an active session"
             '()))
        (let ((fields (interaction-environment-fields session-id)))
          (if (eq? (reflect-policy-action context 'standard-host-effect)
                   'allow)
              (begin
                (record-audit-event!
                 context
                 'policy-decision
                 (append
                  (list (list 'category 'standard-host-effect)
                        (list 'operation "interaction-environment")
                        (list 'decision 'allowed))
                  fields))
                (make-environment-specifier
                 environment syntax-environment #f))
              (deny-interaction-environment!
               context
               "interaction-environment requires policy-gated host access"
               fields)))))

    (define (time-inexact-number value description)
      "Return VALUE as an inexact Consent Scheme number for DESCRIPTION."
      (if (not (number? value))
          (eval-error
           (string-append description " host adapter returned non-number")
           value))
      (consent-make-canonical-decimal (inexact value)))

    (define (time-exact-integer value description)
      "Return VALUE as an exact Consent Scheme integer for DESCRIPTION."
      (if (not (exact-integer? value))
          (eval-error
           (string-append description
                          " host adapter returned non-exact-integer")
           value))
      (consent-make-canonical-integer value))

    (define (time-positive-exact-integer value description)
      "Return VALUE as a positive exact Consent Scheme integer for DESCRIPTION."
      (if (not (and (exact-integer? value) (> value 0)))
          (eval-error
           (string-append description
                          " host adapter returned non-positive exact integer")
           value))
      (consent-make-canonical-integer value))

    (define (call-authorized-clock binding context thunk)
      "Authorize clock BINDING, call THUNK, and record the capability result."
      (let* ((authorization (authorize-clock-capability binding context))
             (value (thunk)))
        (audit-clock-capability-result!
         context
         authorization
         value
         #f)
        value))

    (define (primitive-current-second arguments context)
      "Implement R7RS `current-second` through a policy-gated clock read."
      (call-authorized-clock
       'current-second
       context
       (lambda ()
         (time-inexact-number
          (host-current-second)
          "current-second"))))

    (define (primitive-command-line arguments context)
      "Implement `command-line` from script invocation metadata or a grant."
      (let ((script-command-line
             (and context (context-command-line context))))
        (if script-command-line
            script-command-line
            (begin
              (authorize-process-environment-capability "command-line" context)
              (host-command-line)))))

    (define (primitive-get-environment-variable arguments context)
      "Implement `get-environment-variable` through a policy-gated host read."
      (authorize-process-environment-capability
       "get-environment-variable" context)
      (host-get-environment-variable
       (expect-string (car arguments) "get-environment-variable")))

    (define (primitive-get-environment-variables arguments context)
      "Implement `get-environment-variables` through a policy-gated host read."
      (authorize-process-environment-capability
       "get-environment-variables" context)
      (host-get-environment-variables))

    (define (primitive-current-jiffy arguments context)
      "Implement R7RS `current-jiffy` through a policy-gated clock read."
      (call-authorized-clock
       'current-jiffy
       context
       (lambda ()
         (time-exact-integer
          (host-current-jiffy)
          "current-jiffy"))))

    (define (primitive-jiffies-per-second arguments context)
      "Implement R7RS `jiffies-per-second` through a policy-gated clock read."
      (call-authorized-clock
       'jiffies-per-second
       context
       (lambda ()
         (time-positive-exact-integer
          (host-jiffies-per-second)
          "jiffies-per-second"))))

    (define (resolve-file-policy-path filename context description)
      "Resolve FILENAME and enforce the file-operation capability policy."
      (authorize-file-capability
       filename
       context
       (cond
        ((string=? description "file-exists?") 'metadata)
        ((string=? description "delete-file") 'delete)
        ((string=? description "load") 'load)
        (else 'read))
       description
       (context-file-paths context)))

    (define (resolve-output-file-policy-path filename context description)
      "Resolve FILENAME and enforce output file creation/write policy."
      (let* ((path
              (path-normalize
               (path-join (context-include-directory context) filename)))
             (operation (if (file-exists? path) 'write 'create)))
        (authorize-file-capability
         filename
         context
         operation
         description
         (context-file-paths context))))

    (define (read-file-port-source context authorization description filename)
      "Return file contents for an approved input port authorization."
      (let ((path (file-authorization-path authorization)))
        (if (not (file-exists? path))
            (begin
              (audit-file-capability-result!
               context
               authorization
               (string-append description " file is not readable")
               #t)
              (eval-error
               (string-append description " file is not readable")
               filename)))
        (let ((source (read-file-string path)))
          (audit-file-capability-result! context authorization 'opened #f)
          source)))

    (define (read-file-bytevector path)
      "Read PATH into a bytevector using the host Scheme binary file API."
      (let ((host-port (open-binary-input-file path)))
        (let loop ((bytes '()))
          (let ((byte (read-u8 host-port)))
            (if (eof-object? byte)
                (begin
                  (close-port host-port)
                  (list->bytevector (reverse bytes)))
                (loop (cons byte bytes)))))))

    (define (read-binary-file-port-source
             context authorization description filename)
      "Return file bytes for an approved binary input port authorization."
      (let ((path (file-authorization-path authorization)))
        (if (not (file-exists? path))
            (begin
              (audit-file-capability-result!
               context
               authorization
               (string-append description " file is not readable")
               #t)
              (eval-error
               (string-append description " file is not readable")
               filename)))
        (let ((source (read-file-bytevector path)))
          (audit-file-capability-result! context authorization 'opened #f)
          source)))

    (define (make-file-input-port context authorization source)
      "Return host-backed textual input port for approved AUTHORIZATION."
      (let* ((grant (authorization-field authorization 'grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'file #t #f #t #f #t source 0 #f
               'file
               '(read close)
               (capability-grant-id grant)
               limits
               (port-capability-handle-id)
               'open
               (file-authorization-path authorization)
               '())))
        (register-file-port! context port 'textual-input)))

    (define (primitive-open-input-file arguments context)
      "Implement the `open-input-file` primitive with capability checks."
      (let* ((filename (expect-string (car arguments) "open-input-file"))
             (authorization
              (resolve-file-policy-path
               filename
               context
               "open-input-file"))
             (source
              (read-file-port-source
               context
               authorization
               "open-input-file"
               filename)))
        (make-file-input-port context authorization source)))

    (define (make-binary-file-input-port context authorization source)
      "Return host-backed binary input port for approved AUTHORIZATION."
      (let* ((grant (authorization-field authorization 'grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'file #t #f #f #t #t source 0 #f
               'file
               '(read close)
               (capability-grant-id grant)
               limits
               (port-capability-handle-id)
               'open
               (file-authorization-path authorization)
               '())))
        (register-file-port! context port 'binary-input)))

    (define (primitive-open-binary-input-file arguments context)
      "Implement the `open-binary-input-file` primitive with capability checks."
      (let* ((filename
              (expect-string (car arguments) "open-binary-input-file"))
             (authorization
              (resolve-file-policy-path
               filename
               context
               "open-binary-input-file"))
             (source
              (read-binary-file-port-source
               context
               authorization
               "open-binary-input-file"
               filename)))
        (make-binary-file-input-port context authorization source)))

    (define (make-file-output-port context authorization)
      "Return host-backed textual output port for approved AUTHORIZATION."
      (let* ((grant (authorization-field authorization 'grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'file #f #t #t #f #t #f 0 ""
               'file
               '(write flush close)
               (capability-grant-id grant)
               limits
               (port-capability-handle-id)
               'open
               (file-authorization-path authorization)
               '())))
        (register-file-port! context port 'textual-output)))

    (define (primitive-open-output-file arguments context)
      "Implement the `open-output-file` primitive with capability checks."
      (let* ((filename (expect-string (car arguments) "open-output-file"))
             (authorization
             (resolve-output-file-policy-path
               filename
               context
               "open-output-file")))
        (audit-file-capability-result! context authorization 'opened #f)
        (make-file-output-port context authorization)))

    (define (make-binary-file-output-port context authorization)
      "Return host-backed binary output port for approved AUTHORIZATION."
      (let* ((grant (authorization-field authorization 'grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'file #f #t #f #t #t #f 0 '()
               'file
               '(write flush close)
               (capability-grant-id grant)
               limits
               (port-capability-handle-id)
               'open
               (file-authorization-path authorization)
               '())))
        (register-file-port! context port 'binary-output)))

    (define (primitive-open-binary-output-file arguments context)
      "Implement `open-binary-output-file` with capability checks."
      (let* ((filename
              (expect-string (car arguments) "open-binary-output-file"))
             (authorization
             (resolve-output-file-policy-path
               filename
               context
               "open-binary-output-file")))
        (audit-file-capability-result! context authorization 'opened #f)
        (make-binary-file-output-port context authorization)))

    (define (primitive-file-exists? arguments context)
      "Implement the `file-exists?` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((authorization
             (resolve-file-policy-path
              (expect-string (car arguments) "file-exists?")
              context
              "file-exists?"))
             (exists? (file-exists? (file-authorization-path authorization))))
        (audit-file-capability-result! context authorization exists? #f)
        exists?))

    (define (primitive-delete-file arguments context)
      "Implement the `delete-file` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((authorization
              (resolve-file-policy-path
               (expect-string (car arguments) "delete-file")
               context
               "delete-file"))
             (path (file-authorization-path authorization)))
        (if (not (file-exists? path))
            (begin
              (audit-file-capability-result!
               context
               authorization
               "delete-file target does not exist"
               #t)
              (eval-error "delete-file target does not exist" path)))
        (delete-file path)
        (audit-file-capability-result!
         context
         authorization
         'deleted
         #f)
        consent-unspecified))

    (define (primitive-call-with-port arguments context)
      "Implement the `call-with-port` primitive with argument validation and"
      "Consent Scheme values."
      (drain-state
       (primitive-call-with-port/k
        arguments context identity-continuation)
       context))

    (define (primitive-call-with-port/k arguments context continuation)
      "Continuation-aware implementation of the `call-with-port` primitive for"
      "trampoline evaluation."
      (let ((port (expect-port (car arguments) "call-with-port port"))
            (procedure
             (expect-procedure (second arguments) "call-with-port procedure")))
        (apply-procedure
         procedure
         (list port)
         context
         #t
         (lambda (value)
           (close-port-value port context)
           (continue continuation value)))))

    (define (primitive-call-with-input-file arguments context)
      "Implement the `call-with-input-file` primitive."
      (drain-state
       (primitive-call-with-input-file/k
        arguments context identity-continuation)
       context))

    (define (primitive-call-with-input-file/k arguments context continuation)
      "Continuation-aware implementation of `call-with-input-file`."
      (let ((port (primitive-open-input-file (list (car arguments)) context))
            (procedure
             (expect-procedure
              (second arguments)
              "call-with-input-file procedure")))
        (apply-procedure
         procedure
         (list port)
         context
         #t
         (lambda (value)
           (close-port-value port context)
           (continue continuation value)))))

    (define (primitive-call-with-output-file arguments context)
      "Implement the `call-with-output-file` primitive."
      (drain-state
       (primitive-call-with-output-file/k
        arguments context identity-continuation)
       context))

    (define (primitive-call-with-output-file/k arguments context continuation)
      "Continuation-aware implementation of `call-with-output-file`."
      (let ((port (primitive-open-output-file (list (car arguments)) context))
            (procedure
             (expect-procedure
              (second arguments)
              "call-with-output-file procedure")))
        (apply-procedure
         procedure
         (list port)
         context
         #t
         (lambda (value)
           (close-port-value port context)
           (continue continuation value)))))

    (define (primitive-with-input-from-file arguments context)
      "Implement the `with-input-from-file` primitive."
      (drain-state
       (primitive-with-input-from-file/k
        arguments context identity-continuation)
       context))

    (define (primitive-with-input-from-file/k arguments context continuation)
      "Continuation-aware implementation of `with-input-from-file`."
      (let ((port (primitive-open-input-file (list (car arguments)) context))
            (procedure
             (expect-procedure
              (second arguments)
              "with-input-from-file thunk"))
            (previous (context-current-input-port context)))
        (set-context-current-input-port! context port)
        (apply-procedure
         procedure
         '()
         context
         #t
         (lambda (value)
           (set-context-current-input-port! context previous)
           (close-port-value port context)
           (continue continuation value)))))

    (define (primitive-with-output-to-file arguments context)
      "Implement the `with-output-to-file` primitive."
      (drain-state
       (primitive-with-output-to-file/k
        arguments context identity-continuation)
       context))

    (define (primitive-with-output-to-file/k arguments context continuation)
      "Continuation-aware implementation of `with-output-to-file`."
      (let ((port (primitive-open-output-file (list (car arguments)) context))
            (procedure
             (expect-procedure
              (second arguments)
              "with-output-to-file thunk"))
            (previous (context-current-output-port context)))
        (set-context-current-output-port! context port)
        (apply-procedure
         procedure
         '()
         context
         #t
         (lambda (value)
           (set-context-current-output-port! context previous)
           (close-port-value port context)
           (continue continuation value)))))

    (define (primitive-environment arguments context)
      "Implement the `environment` primitive with argument validation and"
      "Consent Scheme values."
      (let ((environment (consent-make-empty-environment))
            (syntax-environment (make-syntax-environment '() #f '())))
        (with-syntax-environment
         context
         syntax-environment
         (lambda ()
           (eval-import (cons 'import arguments) environment context)))
        (make-environment-specifier environment syntax-environment #t)))

    (define (expect-environment-specifier value description)
      "Validate environment specifier input and raise an evaluator error on mismatch."
      (if (not (environment-specifier? value))
          (eval-error
           (string-append description " expected an environment specifier")
           value))
      value)

    (define (eval-form-mutates-environment? form)
      "Report whether FORM mutates an evaluation environment."
      (or (import-form? form)
          (define-library-form? form)
          (syntax-definition-form? form)
          (record-definition-form? form)
          (definition-form? form)))

    (define (primitive-eval arguments context)
      "Implement the `eval` primitive with argument validation and Consent Scheme values."
      (drain-state
       (primitive-eval/k arguments context identity-continuation)
       context))

    (define (primitive-eval/k arguments context continuation)
      "Continuation-aware implementation of the `eval` primitive for trampoline"
      "evaluation."
      (let* ((expression (car arguments))
             (specifier
              (expect-environment-specifier (second arguments) "eval"))
             (environment (environment-specifier-environment specifier))
             (syntax-environment
              (environment-specifier-syntax-environment specifier)))
        (if (and (environment-specifier-immutable? specifier)
                 (eval-form-mutates-environment? expression))
            (eval-error "eval cannot mutate an immutable environment"))
        (with-syntax-environment
         context
         syntax-environment
         (lambda ()
           (if (eval-form-mutates-environment? expression)
               (eval-sequence
                (list expression) environment context #t #t continuation)
               (eval-expression
                expression environment context #t continuation))))))

    (define (read-policy-file-forms filename context description)
      "Read policy-approved source file forms and return forms, directory, and"
      "authorization data."
      (let* ((authorization
              (resolve-file-policy-path filename context description))
             (path (file-authorization-path authorization)))
        (if (not (file-exists? path))
            (begin
              (audit-file-capability-result!
               context
               authorization
               (string-append description " file is not readable")
               #t)
              (eval-error
               (string-append description " file is not readable")
               filename)))
        (audit-file-capability-result! context authorization 'read #f)
        (list (consent-read-all
               (read-file-string path)
               (context-reader-options context))
              (path-directory path)
              authorization)))

    (define (load-target arguments context)
      "Return the value and syntax environments targeted by load."
      (if (not (null? (cdr arguments)))
          (let ((specifier
                 (expect-environment-specifier (second arguments) "load")))
            (if (environment-specifier-immutable? specifier)
                (eval-error
                 "load cannot mutate an immutable environment"))
            (cons (environment-specifier-environment specifier)
                  (environment-specifier-syntax-environment specifier)))
          (cons (or (context-interaction-environment context)
                    (consent-make-base-environment))
                (context-syntax-environment context))))

    (define (primitive-load arguments context)
      "Implement the `load` primitive with argument validation and Consent Scheme values."
      (drain-state
       (primitive-load/k arguments context identity-continuation)
       context))

    (define (primitive-load/k arguments context continuation)
      "Continuation-aware implementation of the `load` primitive for trampoline"
      "evaluation."
      (let* ((filename (expect-string (car arguments) "load"))
             (read-result
              (read-policy-file-forms filename context "load"))
             (target (load-target arguments context))
             (code-loading
              (authorize-code-loading (third read-result) context "load")))
        (with-include-directory
         context
         (second read-result)
         (lambda ()
           (with-syntax-environment
            context
            (cdr target)
            (lambda ()
              (eval-sequence
               (car read-result)
               (car target)
               context
               #t
               #t
               (lambda (value)
                 (audit-code-loading-result!
                  context
                  code-loading
                  'evaluated
                  #f)
                 (continue continuation consent-unspecified)))))))))

    (define (primitive-string? arguments context)
      "Implement the `string?` primitive with argument validation and Consent"
      "Scheme values."
      (string? (car arguments)))

    (define (primitive-make-string arguments context)
      "Implement the `make-string` primitive with argument validation and"
      "Consent Scheme values."
      (let ((length (exact-integer->host (car arguments) "make-string"))
            (fill (if (null? (cdr arguments))
                      #\null
                      (expect-character
                       (second arguments)
                       "make-string fill"))))
        (if (< length 0)
            (eval-error "make-string length must be non-negative"))
        (charge-string-allocation! (make-string length fill) context)))

    (define (primitive-string arguments context)
      "Implement the `string` primitive with argument validation and Consent"
      "Scheme values."
      (charge-string-allocation!
       (list->string
        (map (lambda (argument)
               (expect-character argument "string"))
             arguments))
       context))

    (define (primitive-string-length arguments context)
      "Implement the `string-length` primitive with argument validation and"
      "Consent Scheme values."
      (consent-make-canonical-integer
       (string-length (expect-string (car arguments) "string-length"))))

    (define (primitive-string-ref arguments context)
      "Implement the `string-ref` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "string-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (string-length string)
                     "string-ref"
                     #f)))
        (string-ref string index)))

    (define (primitive-string-set! arguments context)
      "Implement the `string-set!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "string-set!"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (string-length string)
                     "string-set!"
                     #f))
             (char (expect-character (third arguments) "string-set! value")))
        (string-set! string index char)
        consent-unspecified))

    (define (primitive-substring arguments context)
      "Implement the `substring` primitive with argument validation and Consent"
      "Scheme values."
      (let* ((string (expect-string (car arguments) "substring"))
             (start (expect-nonnegative-index
                     (second arguments)
                     (string-length string)
                     "substring"
                     #t))
             (end (expect-nonnegative-index
                   (third arguments)
                   (string-length string)
                   "substring"
                   #t)))
        (if (> start end)
            (eval-error "substring start exceeds end"))
        (charge-string-allocation! (substring string start end) context)))

    (define (primitive-string-append arguments context)
      "Implement the `string-append` primitive with argument validation and"
      "Consent Scheme values."
      (charge-string-allocation!
       (apply string-append
              (map (lambda (argument)
                     (expect-string argument "string-append"))
                   arguments))
       context))

    (define (primitive-string->list arguments context)
      "Implement the `string->list` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "string->list"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string->list")))
        (let loop ((index (car range)) (result '()))
          (if (= index (cdr range))
              (charge-list-allocation! (reverse result) context)
              (loop (+ index 1)
                    (cons (string-ref string index) result))))))

    (define (primitive-list->string arguments context)
      "Implement the `list->string` primitive with argument validation and"
      "Consent Scheme values."
      (charge-string-allocation!
       (list->string
        (map (lambda (argument)
               (expect-character argument "list->string"))
             (proper-list-elements (car arguments) "list->string")))
       context))

    (define (primitive-string->vector arguments context)
      "Implement the `string->vector` primitive with argument validation and"
      "Consent Scheme values."
      (charge-vector-allocation!
       (list->vector (primitive-string->list arguments context))
       context))

    (define (primitive-vector->string arguments context)
      "Implement the `vector->string` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((vector (expect-vector (car arguments) "vector->string"))
             (range (optional-range
                     arguments
                     1
                     (vector-length vector)
                     "vector->string")))
        (let loop ((index (car range)) (result '()))
          (if (= index (cdr range))
              (charge-string-allocation! (list->string (reverse result)) context)
              (loop (+ index 1)
                    (cons (expect-character
                           (vector-ref vector index)
                           "vector->string")
                          result))))))

    (define (primitive-string-copy arguments context)
      "Implement the `string-copy` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "string-copy"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string-copy")))
        (charge-string-allocation!
         (substring string (car range) (cdr range))
         context)))

    (define (primitive-string-copy! arguments context)
      "Implement the `string-copy!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((to (expect-string (car arguments) "string-copy! target"))
             (at (expect-nonnegative-index
                  (second arguments)
                  (string-length to)
                  "string-copy!"
                  #t))
             (from (expect-string (third arguments) "string-copy! source"))
             (range (optional-range
                     arguments
                     3
                     (string-length from)
                     "string-copy!")))
        (if (> (+ at (- (cdr range) (car range))) (string-length to))
            (eval-error "string-copy! target range exceeds length"))
        (let loop ((source-index (car range)) (target-index at))
          (if (< source-index (cdr range))
              (begin
                (string-set! to target-index (string-ref from source-index))
                (loop (+ source-index 1) (+ target-index 1)))))
        consent-unspecified))

    (define (primitive-string-fill! arguments context)
      "Implement the `string-fill!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((string (expect-string (car arguments) "string-fill!"))
             (fill (expect-character (second arguments) "string-fill! value"))
             (range (optional-range
                     arguments
                     2
                     (string-length string)
                     "string-fill!")))
        (let loop ((index (car range)))
          (if (< index (cdr range))
              (begin
                (string-set! string index fill)
                (loop (+ index 1)))))
        consent-unspecified))

    (define (primitive-string-compare arguments predicate description)
      "Implement the `string-compare` primitive with argument validation and"
      "Consent Scheme values."
      (let loop ((rest arguments))
        (cond
         ((or (null? rest) (null? (cdr rest))) #t)
         (else
          (let ((left (expect-string (car rest) description))
                (right (expect-string (second rest) description)))
            (and (predicate left right) (loop (cdr rest))))))))

    (define (primitive-string=? arguments context)
      "Implement the `string=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-string-compare arguments string=? "string=?"))

    (define (primitive-string<? arguments context)
      "Implement the `string<?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-string-compare arguments string<? "string<?"))

    (define (primitive-string>? arguments context)
      "Implement the `string>?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-string-compare arguments string>? "string>?"))

    (define (primitive-string<=? arguments context)
      "Implement the `string<=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-string-compare arguments string<=? "string<=?"))

    (define (primitive-string>=? arguments context)
      "Implement the `string>=?` primitive with argument validation and Consent"
      "Scheme values."
      (primitive-string-compare arguments string>=? "string>=?"))

    (define (map-over-lists procedure lists context keep-results?)
      "Apply PROCEDURE over LISTS, collecting results only when requested."
      (let loop ((cursors lists) (results '()))
        (cond
         ((let any-empty? ((rest cursors))
            (cond
             ((null? rest) #f)
             ((null? (car rest)) #t)
             (else (any-empty? (cdr rest)))))
          (if keep-results? (reverse results) consent-unspecified))
         ((let any-improper? ((rest cursors))
            (cond
             ((null? rest) #f)
             ((not (pair? (car rest))) #t)
             (else (any-improper? (cdr rest)))))
          (eval-error "map expected proper lists"))
         (else
          (let ((value
                 (apply-procedure procedure (map car cursors) context #f)))
            (loop (map cdr cursors)
                  (if keep-results?
                      (cons (single-value value "map result") results)
                      results)))))))

    (define (primitive-apply arguments context)
      "Implement the `apply` primitive with argument validation and Consent"
      "Scheme values."
      (let ((procedure (expect-procedure (car arguments) "apply procedure"))
            (fixed-arguments (reverse (cdr (reverse (cdr arguments)))))
            (tail-arguments
             (proper-list-elements
              (car (reverse arguments))
              "apply final argument")))
        (apply-procedure procedure
                         (append fixed-arguments tail-arguments)
                         context
                         #f)))

    (define (apply-parameter/k parameter arguments context continuation)
      "Apply a parameter procedure in continuation-passing form."
      (cond
       ((null? arguments)
        (continue continuation (parameter-value parameter)))
       ((not (null? (cdr arguments)))
        (eval-error
         "parameter expected 0..1 arguments"
         (length arguments)))
       ((parameter-converter parameter)
        (apply-procedure
         (parameter-converter parameter)
         (list (car arguments))
         context
         #t
         (lambda (converted)
           (set-parameter-value!
            parameter
            (single-value converted "parameter converter"))
           (continue continuation consent-unspecified))))
       (else
        (set-parameter-value! parameter (car arguments))
        (continue continuation consent-unspecified))))

    (define (primitive-make-parameter arguments context)
      "Implement the `make-parameter` primitive with argument validation and"
      "Consent Scheme values."
      (drain-state
       (primitive-make-parameter/k
        arguments context identity-continuation)
       context))

    (define (primitive-make-parameter/k arguments context continuation)
      "Continuation-aware implementation of the `make-parameter` primitive for"
      "trampoline evaluation."
      (let ((initial (car arguments))
            (converter (if (null? (cdr arguments))
                           #f
                           (second arguments))))
        (if converter
            (begin
              (expect-procedure converter "make-parameter converter")
              (apply-procedure
               converter
               (list initial)
               context
               #t
               (lambda (converted)
                 (continue
                  continuation
                  (make-consent-parameter
                   (single-value converted "make-parameter converter")
                   converter)))))
            (continue continuation (make-consent-parameter initial #f)))))

    (define (primitive-apply/k arguments context continuation)
      "Continuation-aware implementation of the `apply` primitive for"
      "trampoline evaluation."
      (let ((procedure (expect-procedure (car arguments) "apply procedure"))
            (fixed-arguments (reverse (cdr (reverse (cdr arguments)))))
            (tail-arguments
             (proper-list-elements
              (car (reverse arguments))
              "apply final argument")))
        (apply-procedure procedure
                         (append fixed-arguments tail-arguments)
                         context
                         #t
                         continuation)))

    (define (primitive-values arguments context)
      "Implement the `values` primitive with argument validation and Consent"
      "Scheme values."
      ;; One fresh multiple-values wrapper; the values it carries were charged
      ;; where they were allocated.
      (charge-value-allocation! (make-multiple-values arguments) 1 context))

    (define (primitive-call-with-values arguments context)
      "Implement the `call-with-values` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((producer (expect-procedure
                        (car arguments)
                        "call-with-values producer"))
             (consumer (expect-procedure
                        (second arguments)
                        "call-with-values consumer"))
             (produced (apply-procedure producer '() context #f)))
        (apply-procedure consumer (values-list produced) context #f)))

    (define (primitive-call-with-values/k
             arguments context continuation)
      "Continuation-aware implementation of the `call-with-values` primitive"
      "for trampoline evaluation."
      (let ((producer (expect-procedure
                       (car arguments)
                       "call-with-values producer"))
            (consumer (expect-procedure
                       (second arguments)
                       "call-with-values consumer")))
        (apply-procedure
         producer
         '()
         context
         #t
         (lambda (produced)
           (apply-procedure
            consumer
            (values-list produced)
            context
            #t
            continuation)))))

    (define (primitive-call/cc arguments context)
      "Implement the `call/cc` primitive with argument validation and Consent"
      "Scheme values."
      (drain-state
       (primitive-call/cc/k
        arguments context identity-continuation)
       context))

    (define (primitive-call/cc/k arguments context continuation)
      "Continuation-aware implementation of the `call/cc` primitive for"
      "trampoline evaluation."
      (let* ((procedure
              (expect-procedure
               (car arguments)
               "call-with-current-continuation procedure"))
             (captured
              (make-continuation
               continuation
               (append (context-dynamic-winds context) '())
               (append (context-exception-handlers context) '())
               (context-current-error context))))
        (apply-procedure
         procedure
         (list captured)
         context
         #t
         continuation)))

    (define (invoke-continuation continuation arguments context)
      "Restore a captured continuation's dynamic context and pass arguments."
      (switch-dynamic-winds!
       (continuation-dynamic-winds continuation)
       context)
      (set-context-exception-handlers!
       context
       (append (continuation-exception-handlers continuation) '()))
      (set-context-current-error!
       context
       (continuation-current-error continuation))
      (continue
       (continuation-procedure continuation)
       (continuation-value arguments)))

    (define (primitive-dynamic-wind arguments context)
      "Implement the `dynamic-wind` primitive with argument validation and"
      "Consent Scheme values."
      (drain-state
       (primitive-dynamic-wind/k
        arguments context identity-continuation)
       context))

    (define (primitive-dynamic-wind/k arguments context continuation)
      "Continuation-aware implementation of the `dynamic-wind` primitive for"
      "trampoline evaluation."
      (let ((before (expect-procedure (car arguments) "dynamic-wind before"))
            (thunk (expect-procedure (second arguments) "dynamic-wind thunk"))
            (after (expect-procedure (third arguments) "dynamic-wind after")))
        (let ((frame (make-dynamic-wind-frame before after)))
          (call-ignoring-values/k
           before
           context
           "dynamic-wind before"
           (lambda (ignored)
             (set-context-dynamic-winds!
              context
              (cons frame (context-dynamic-winds context)))
             (apply-procedure
              thunk
              '()
              context
              #t
              (lambda (result)
                (if (and (pair? (context-dynamic-winds context))
                         (eq? (car (context-dynamic-winds context)) frame))
                    (set-context-dynamic-winds!
                     context
                     (cdr (context-dynamic-winds context))))
                (call-ignoring-values/k
                 after
                 context
                 "dynamic-wind after"
                 (lambda (after-result)
                   (continue continuation result))))))))))

    (define (invoke-exception-handler condition context)
      "Invoke the current exception handler and drain its trampoline state."
      (drain-state
       (invoke-exception-handler/k
        condition context identity-continuation)
       context))

    (define (invoke-exception-handler/k
             condition context continuation)
      "Invoke the current exception handler in continuation-passing form."
      (let ((handlers (context-exception-handlers context))
            (old-error (context-current-error context)))
        (if (null? handlers)
            (eval-error
             "unhandled exception"
             (consent-value->external condition)))
        (set-context-current-error!
         context
         (debugger-exception-datum condition context))
        (set-context-exception-handlers! context (cdr handlers))
        (apply-procedure
         (car handlers)
         (list condition)
         context
         #t
         (lambda (value)
           (set-context-exception-handlers! context handlers)
           (set-context-current-error! context old-error)
           (continue continuation value)))))

    (define (primitive-with-exception-handler arguments context)
      "Implement the `with-exception-handler` primitive with argument"
      "validation and Consent Scheme values."
      (drain-state
       (primitive-with-exception-handler/k
        arguments context identity-continuation)
       context))

    (define (primitive-with-exception-handler/k
             arguments context continuation)
      "Continuation-aware implementation of the `with-exception-handler`"
      "primitive for trampoline evaluation."
      (let ((handler (expect-procedure
                      (car arguments)
                      "with-exception-handler handler"))
            (thunk (expect-procedure
                    (second arguments)
                    "with-exception-handler thunk"))
            (old-handlers (context-exception-handlers context)))
        (set-context-exception-handlers!
         context
         (cons handler old-handlers))
        (apply-procedure
         thunk
         '()
         context
         #t
         (lambda (value)
           (set-context-exception-handlers!
            context
            old-handlers)
           (continue continuation value)))))

    (define (primitive-raise-continuable arguments context)
      "Implement the `raise-continuable` primitive with argument validation and"
      "Consent Scheme values."
      (invoke-exception-handler (car arguments) context))

    (define (primitive-raise-continuable/k
             arguments context continuation)
      "Continuation-aware implementation of the `raise-continuable` primitive"
      "for trampoline evaluation."
      (invoke-exception-handler/k
       (car arguments) context continuation))

    (define (primitive-raise arguments context)
      "Implement the `raise` primitive with argument validation and Consent"
      "Scheme values."
      (invoke-exception-handler (car arguments) context)
      (eval-error "non-continuable exception handler returned"))

    (define (primitive-raise/k arguments context continuation)
      "Continuation-aware implementation of the `raise` primitive for"
      "trampoline evaluation."
      (invoke-exception-handler/k
       (car arguments)
       context
       (lambda (value)
         (eval-error
          "non-continuable exception handler returned"))))

    (define (primitive-error arguments context)
      "Implement the `error` primitive with argument validation and Consent"
      "Scheme values."
      (let ((message (expect-string (car arguments) "error message"))
            (irritants (cdr arguments)))
        (primitive-raise
         (list (make-consent-error-object message irritants))
         context)))

    (define (primitive-error/k arguments context continuation)
      "Continuation-aware implementation of the `error` primitive for"
      "trampoline evaluation."
      (let ((message (expect-string (car arguments) "error message"))
            (irritants (cdr arguments)))
        (primitive-raise/k
         (list (make-consent-error-object message irritants))
         context
         continuation)))

    (define (primitive-error-object? arguments context)
      "Implement the `error-object?` primitive with argument validation and"
      "Consent Scheme values."
      (consent-error-object? (car arguments)))

    (define (expect-error-object value description)
      "Validate error object input and raise an evaluator error on mismatch."
      (if (consent-error-object? value)
          value
          (eval-error
           (string-append description " expected an error object")
           value)))

    (define (primitive-error-object-message arguments context)
      "Implement the `error-object-message` primitive with argument validation"
      "and Consent Scheme values."
      (consent-error-object-message
       (expect-error-object (car arguments) "error-object-message")))

    (define (primitive-error-object-irritants arguments context)
      "Implement the `error-object-irritants` primitive with argument"
      "validation and Consent Scheme values."
      (consent-error-object-irritants
       (expect-error-object (car arguments) "error-object-irritants")))

    (define (primitive-map arguments context)
      "Implement the `map` primitive with argument validation and Consent Scheme values."
      (map-over-lists
       (expect-procedure (car arguments) "map procedure")
       (cdr arguments)
       context
       #t))

    (define (primitive-for-each arguments context)
      "Implement the `for-each` primitive with argument validation and Consent"
      "Scheme values."
      (map-over-lists
       (expect-procedure (car arguments) "for-each procedure")
       (cdr arguments)
       context
       #f))

    (define (primitive-vector? arguments context)
      "Implement the `vector?` primitive with argument validation and Consent"
      "Scheme values."
      (vector? (car arguments)))

    (define (primitive-make-vector arguments context)
      "Implement the `make-vector` primitive with argument validation and"
      "Consent Scheme values."
      (let ((length (exact-integer->host (car arguments) "make-vector"))
            (fill (if (null? (cdr arguments))
                      consent-unspecified
                      (second arguments))))
        (if (< length 0)
            (eval-error "make-vector length must be non-negative"))
        (charge-vector-allocation! (make-vector length fill) context)))

    (define (primitive-vector arguments context)
      "Implement the `vector` primitive with argument validation and Consent"
      "Scheme values."
      (charge-vector-allocation! (list->vector arguments) context))

    (define (primitive-vector-length arguments context)
      "Implement the `vector-length` primitive with argument validation and"
      "Consent Scheme values."
      (consent-make-canonical-integer
       (vector-length (expect-vector (car arguments) "vector-length"))))

    (define (primitive-vector-ref arguments context)
      "Implement the `vector-ref` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((vector (expect-vector (car arguments) "vector-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (vector-length vector)
                     "vector-ref"
                     #f)))
        (vector-ref vector index)))

    (define (primitive-vector-set! arguments context)
      "Implement the `vector-set!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((vector (expect-vector (car arguments) "vector-set!"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (vector-length vector)
                     "vector-set!"
                     #f)))
        (vector-set! vector index (third arguments))
        consent-unspecified))

    (define (primitive-vector->list arguments context)
      "Implement the `vector->list` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((vector (expect-vector (car arguments) "vector->list"))
             (range (optional-range
                     arguments
                     1
                     (vector-length vector)
                     "vector->list")))
        (let loop ((index (car range)) (result '()))
          (if (= index (cdr range))
              (charge-list-allocation! (reverse result) context)
              (loop (+ index 1)
                    (cons (vector-ref vector index) result))))))

    (define (primitive-list->vector arguments context)
      "Implement the `list->vector` primitive with argument validation and"
      "Consent Scheme values."
      (charge-vector-allocation!
       (list->vector
        (proper-list-elements (car arguments) "list->vector"))
       context))

    (define (primitive-vector-copy arguments context)
      "Implement the `vector-copy` primitive with argument validation and"
      "Consent Scheme values."
      (charge-vector-allocation!
       (list->vector (primitive-vector->list arguments context))
       context))

    (define (primitive-vector-copy! arguments context)
      "Implement the `vector-copy!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((to (expect-vector (car arguments) "vector-copy! target"))
             (at (expect-nonnegative-index
                  (second arguments)
                  (vector-length to)
                  "vector-copy!"
                  #t))
             (from (expect-vector (third arguments) "vector-copy! source"))
             (range (optional-range
                     arguments
                     3
                     (vector-length from)
                     "vector-copy!")))
        (if (> (+ at (- (cdr range) (car range))) (vector-length to))
            (eval-error "vector-copy! target range exceeds length"))
        (let loop ((source-index (car range)) (target-index at))
          (if (< source-index (cdr range))
              (begin
                (vector-set! to target-index
                             (vector-ref from source-index))
                (loop (+ source-index 1) (+ target-index 1)))))
        consent-unspecified))

    (define (primitive-vector-append arguments context)
      "Implement the `vector-append` primitive with argument validation and"
      "Consent Scheme values."
      (charge-vector-allocation!
       (list->vector
        (apply append
               (map (lambda (argument)
                      (vector->list
                       (expect-vector argument "vector-append")))
                    arguments)))
       context))

    (define (primitive-vector-fill! arguments context)
      "Implement the `vector-fill!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((vector (expect-vector (car arguments) "vector-fill!"))
             (fill (second arguments))
             (range (optional-range
                     arguments
                     2
                     (vector-length vector)
                     "vector-fill!")))
        (let loop ((index (car range)))
          (if (< index (cdr range))
              (begin
                (vector-set! vector index fill)
                (loop (+ index 1)))))
        consent-unspecified))

    (define (primitive-bytevector? arguments context)
      "Implement the `bytevector?` primitive with argument validation and"
      "Consent Scheme values."
      (bytevector? (car arguments)))

    (define (primitive-make-bytevector arguments context)
      "Implement the `make-bytevector` primitive with argument validation and"
      "Consent Scheme values."
      (let ((length (exact-integer->host (car arguments) "make-bytevector"))
            (fill (if (null? (cdr arguments))
                      0
                      (expect-byte
                       (second arguments)
                       "make-bytevector fill"))))
        (if (< length 0)
            (eval-error "make-bytevector length must be non-negative"))
        (charge-bytevector-allocation! (make-bytevector length fill) context)))

    (define (primitive-bytevector arguments context)
      "Implement the `bytevector` primitive with argument validation and"
      "Consent Scheme values."
      (charge-bytevector-allocation!
       (apply bytevector
              (map (lambda (argument)
                     (expect-byte argument "bytevector"))
                   arguments))
       context))

    (define (primitive-bytevector-length arguments context)
      "Implement the `bytevector-length` primitive with argument validation and"
      "Consent Scheme values."
      (consent-make-canonical-integer
       (bytevector-length
        (expect-bytevector (car arguments) "bytevector-length"))))

    (define (primitive-bytevector-u8-ref arguments context)
      "Implement the `bytevector-u8-ref` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((bytevector
              (expect-bytevector
               (car arguments)
               "bytevector-u8-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (bytevector-length bytevector)
                     "bytevector-u8-ref"
                     #f)))
        (consent-make-canonical-integer
         (bytevector-u8-ref bytevector index))))

    (define (primitive-bytevector-u8-set! arguments context)
      "Implement the `bytevector-u8-set!` primitive with argument validation"
      "and Consent Scheme values."
      (let* ((bytevector
              (expect-bytevector
               (car arguments)
               "bytevector-u8-set!"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (bytevector-length bytevector)
                     "bytevector-u8-set!"
                     #f))
             (byte (expect-byte
                    (third arguments)
                    "bytevector-u8-set! value")))
        (bytevector-u8-set! bytevector index byte)
        consent-unspecified))

    (define (primitive-bytevector-copy arguments context)
      "Implement the `bytevector-copy` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((bytevector
              (expect-bytevector (car arguments) "bytevector-copy"))
             (range (optional-range
                     arguments
                     1
                     (bytevector-length bytevector)
                     "bytevector-copy")))
        (charge-bytevector-allocation!
         (bytevector-copy bytevector (car range) (cdr range))
         context)))

    (define (primitive-bytevector-copy! arguments context)
      "Implement the `bytevector-copy!` primitive with argument validation and"
      "Consent Scheme values."
      (let* ((to (expect-bytevector
                  (car arguments)
                  "bytevector-copy! target"))
             (at (expect-nonnegative-index
                  (second arguments)
                  (bytevector-length to)
                  "bytevector-copy!"
                  #t))
             (from (expect-bytevector
                    (third arguments)
                    "bytevector-copy! source"))
             (range (optional-range
                     arguments
                     3
                     (bytevector-length from)
                     "bytevector-copy!")))
        (if (> (+ at (- (cdr range) (car range))) (bytevector-length to))
            (eval-error "bytevector-copy! target range exceeds length"))
        (bytevector-copy! to at from (car range) (cdr range))
        consent-unspecified))

    (define (primitive-bytevector-append arguments context)
      "Implement the `bytevector-append` primitive with argument validation and"
      "Consent Scheme values."
      (charge-bytevector-allocation!
       (apply bytevector-append
              (map (lambda (argument)
                     (expect-bytevector argument "bytevector-append"))
                   arguments))
       context))

    (define (primitive-procedure? arguments context)
      "Implement the `procedure?` primitive with argument validation and"
      "Consent Scheme values."
      (or (consent-procedure? (car arguments))
          (consent-primitive-procedure? (car arguments))
          (consent-parameter? (car arguments))
          (continuation? (car arguments))))

    (define (numeric-representation-eqv? left right)
      "Report whether two numbers share kind, exactness, and stored value."
      (and (consent-number? left)
           (consent-number? right)
           (eq? (consent-number-kind left)
                (consent-number-kind right))
           (eq? (consent-number-exactness left)
                (consent-number-exactness right))
           (if (and (number-complex-representation? left)
                    (number-complex-representation? right))
               (and (numeric-representation-eqv?
                     (car (consent-number-value left))
                     (car (consent-number-value right)))
                    (numeric-representation-eqv?
                     (cdr (consent-number-value left))
                     (cdr (consent-number-value right))))
               (equal? (consent-number-value left)
                       (consent-number-value right)))))

    (define (eqv-value? left right)
      "Implement eqv? comparison with Consent Scheme numeric representation."
      (if (and (consent-number? left) (consent-number? right))
          (numeric-representation-eqv? left right)
          (eqv? left right)))

    (define (eq-value? left right)
      "Implement eq? comparison with canonical-number identity semantics."
      (or (eq? left right)
          (and (consent-number? left)
               (consent-number? right)
               (numeric-representation-eqv? left right))))

    (define (equal-seen-pair? left right seen)
      "Report whether LEFT/RIGHT was already visited during equal? traversal."
      (cond
       ((null? seen) #f)
       ((and (eq? left (caar seen))
             (eq? right (cdar seen)))
        #t)
       (else
        (equal-seen-pair? left right (cdr seen)))))

    (define (equal-value? left right seen)
      "Implement equal? comparison with cycle detection for pairs and vectors."
      (cond
       ((eqv-value? left right) #t)
       ((and (pair? left) (pair? right))
        (if (equal-seen-pair? left right seen)
            #t
            (let ((seen (cons (cons left right) seen)))
              (and (equal-value? (car left) (car right) seen)
                   (equal-value? (cdr left) (cdr right) seen)))))
       ((and (vector? left) (vector? right))
        (and (= (vector-length left) (vector-length right))
             (if (equal-seen-pair? left right seen)
                 #t
                 (let ((seen (cons (cons left right) seen)))
                   (let loop ((index 0))
                     (or (= index (vector-length left))
                         (and (equal-value? (vector-ref left index)
                                            (vector-ref right index)
                                            seen)
                              (loop (+ index 1)))))))))
       ((or (consent-record? left)
            (consent-record? right)
            (consent-record-type? left)
            (consent-record-type? right))
        #f)
       (else
        (equal? left right))))

    (define (primitive-eq? arguments context)
      "Implement the `eq?` primitive with argument validation and Consent Scheme values."
      (eq-value? (car arguments) (second arguments)))

    (define (primitive-eqv? arguments context)
      "Implement the `eqv?` primitive with argument validation and Consent Scheme values."
      (eqv-value? (car arguments) (second arguments)))

    (define (primitive-equal? arguments context)
      "Implement the `equal?` primitive with argument validation and Consent"
      "Scheme values."
      (equal-value? (car arguments) (second arguments) '()))

    (define (primitive-memq arguments context)
      "Implement the `memq` primitive with argument validation and Consent Scheme values."
      (let ((result (memq (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-memv arguments context)
      "Implement the `memv` primitive with argument validation and Consent Scheme values."
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((eqv-value? (car arguments) (car cursor)) cursor)
         (else (loop (cdr cursor))))))

    (define (primitive-member arguments context)
      "Implement the `member` primitive with argument validation and Consent"
      "Scheme values."
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((equal-value? (car arguments) (car cursor) '()) cursor)
         (else (loop (cdr cursor))))))

    (define (primitive-assq arguments context)
      "Implement the `assq` primitive with argument validation and Consent Scheme values."
      (let ((result (assq (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-assv arguments context)
      "Implement the `assv` primitive with argument validation and Consent Scheme values."
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((and (pair? (car cursor))
               (eqv-value? (car arguments) (caar cursor)))
          (car cursor))
         (else (loop (cdr cursor))))))

    (define (primitive-assoc arguments context)
      "Implement the `assoc` primitive with argument validation and Consent"
      "Scheme values."
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((and (pair? (car cursor))
               (equal-value? (car arguments) (caar cursor) '()))
          (car cursor))
         (else (loop (cdr cursor))))))

    ;; Map library resolver implementation names to interpreter procedures.
    (define library-primitive-implementation-table
      (list
       (cons 'primitive-char-alphabetic? primitive-char-alphabetic?)
       (cons 'primitive-char-ci<=? primitive-char-ci<=?)
       (cons 'primitive-char-ci<? primitive-char-ci<?)
       (cons 'primitive-char-ci=? primitive-char-ci=?)
       (cons 'primitive-char-ci>=? primitive-char-ci>=?)
       (cons 'primitive-char-ci>? primitive-char-ci>?)
       (cons 'primitive-char-downcase primitive-char-downcase)
       (cons 'primitive-char-foldcase primitive-char-foldcase)
       (cons 'primitive-char-lower-case? primitive-char-lower-case?)
       (cons 'primitive-char-numeric? primitive-char-numeric?)
       (cons 'primitive-char-upcase primitive-char-upcase)
       (cons 'primitive-char-upper-case? primitive-char-upper-case?)
       (cons 'primitive-char-whitespace? primitive-char-whitespace?)
       (cons 'primitive-digit-value primitive-digit-value)
       (cons 'primitive-string-ci<=? primitive-string-ci<=?)
       (cons 'primitive-string-ci<? primitive-string-ci<?)
       (cons 'primitive-string-ci=? primitive-string-ci=?)
       (cons 'primitive-string-ci>=? primitive-string-ci>=?)
       (cons 'primitive-string-ci>? primitive-string-ci>?)
       (cons 'primitive-string-downcase primitive-string-downcase)
       (cons 'primitive-string-foldcase primitive-string-foldcase)
       (cons 'primitive-string-upcase primitive-string-upcase)
       (cons 'primitive-acos primitive-acos)
       (cons 'primitive-asin primitive-asin)
       (cons 'primitive-atan primitive-atan)
       (cons 'primitive-cos primitive-cos)
       (cons 'primitive-exp primitive-exp)
       (cons 'primitive-finite? primitive-finite?)
       (cons 'primitive-infinite? primitive-infinite?)
       (cons 'primitive-log primitive-log)
       (cons 'primitive-nan? primitive-nan?)
       (cons 'primitive-sin primitive-sin)
       (cons 'primitive-sqrt primitive-sqrt)
       (cons 'primitive-tan primitive-tan)
       (cons 'primitive-angle primitive-angle)
       (cons 'primitive-imag-part primitive-imag-part)
       (cons 'primitive-magnitude primitive-magnitude)
       (cons 'primitive-make-polar primitive-make-polar)
       (cons 'primitive-make-rectangular primitive-make-rectangular)
       (cons 'primitive-real-part primitive-real-part)
       (cons 'primitive-environment primitive-environment)
       (cons 'primitive-eval primitive-eval)
       (cons 'primitive-interaction-environment
             primitive-interaction-environment)
       (cons 'primitive-current-error-port primitive-current-error-port)
       (cons 'primitive-current-input-port primitive-current-input-port)
       (cons 'primitive-current-output-port primitive-current-output-port)
       (cons 'primitive-call-with-input-file primitive-call-with-input-file)
       (cons 'primitive-call-with-output-file primitive-call-with-output-file)
       (cons 'primitive-delete-file primitive-delete-file)
       (cons 'primitive-file-exists? primitive-file-exists?)
       (cons 'primitive-open-binary-input-file
             primitive-open-binary-input-file)
       (cons 'primitive-open-binary-output-file
             primitive-open-binary-output-file)
       (cons 'primitive-open-input-file primitive-open-input-file)
       (cons 'primitive-open-output-file primitive-open-output-file)
       (cons 'primitive-with-input-from-file primitive-with-input-from-file)
       (cons 'primitive-with-output-to-file primitive-with-output-to-file)
       (cons 'primitive-load primitive-load)
       (cons 'primitive-current-second primitive-current-second)
       (cons 'primitive-current-jiffy primitive-current-jiffy)
       (cons 'primitive-jiffies-per-second primitive-jiffies-per-second)
       (cons 'primitive-command-line primitive-command-line)
       (cons 'primitive-get-environment-variable
             primitive-get-environment-variable)
       (cons 'primitive-get-environment-variables
             primitive-get-environment-variables)
       (cons 'primitive-read primitive-read)
       (cons 'primitive-display primitive-display)
       (cons 'primitive-write primitive-write)
       (cons 'primitive-write-shared primitive-write-shared)
       (cons 'primitive-write-simple primitive-write-simple)
       (cons 'primitive-agent-yield primitive-agent-yield)
       (cons 'primitive-agent-log primitive-agent-log)
       (cons 'primitive-agent-progress primitive-agent-progress)
       (cons 'primitive-agent-warn primitive-agent-warn)
       (cons 'primitive-agent-request primitive-agent-request)
       (cons 'primitive-consent-version primitive-consent-version)
       (cons 'primitive-current-capabilities primitive-current-capabilities)
       (cons 'primitive-current-policy primitive-current-policy)
       (cons 'primitive-current-budget primitive-current-budget)
       (cons 'primitive-budget-remaining primitive-budget-remaining)
       (cons 'primitive-budget-exhausted? primitive-budget-exhausted?)
       (cons 'primitive-budget-yield primitive-budget-yield)
       (cons 'primitive-current-imports primitive-current-imports)
       (cons 'primitive-library-bindings primitive-library-bindings)
       (cons 'primitive-libraries primitive-libraries)
       (cons 'primitive-library-info primitive-library-info)
       (cons 'primitive-library-search primitive-library-search)
       (cons 'primitive-catalog-sources primitive-catalog-sources)
       (cons 'primitive-catalog-diagnostics primitive-catalog-diagnostics)
       (cons 'primitive-add-manifest! primitive-add-manifest!)
       (cons 'primitive-remove-manifest! primitive-remove-manifest!)
       (cons 'primitive-add-manifest-root! primitive-add-manifest-root!)
       (cons 'primitive-remove-manifest-root!
             primitive-remove-manifest-root!)
       (cons 'primitive-refresh-library-catalog!
             primitive-refresh-library-catalog!)
       (cons 'primitive-library-documentation
             primitive-library-documentation)
       (cons 'primitive-binding-libraries primitive-binding-libraries)
       (cons 'primitive-documented-bindings primitive-documented-bindings)
       (cons 'primitive-apropos primitive-apropos)
       (cons 'primitive-reflection-field primitive-reflection-field)
       (cons 'primitive-documentation-field primitive-documentation-field)
       (cons 'primitive-docstring primitive-docstring)
       (cons 'primitive-current-session-info primitive-current-session-info)
       (cons 'primitive-create-session primitive-create-session)
       (cons 'primitive-switch-session primitive-switch-session)
       (cons 'primitive-current-session primitive-current-session)
       (cons 'primitive-list-sessions primitive-list-sessions)
       (cons 'primitive-close-session primitive-close-session)
       (cons 'primitive-recent-yields primitive-recent-yields)
       (cons 'primitive-recent-errors primitive-recent-errors)
       (cons 'primitive-recent-policy-decisions
             primitive-recent-policy-decisions)
       (cons 'primitive-capability-info primitive-capability-info)
       (cons 'primitive-documentation primitive-documentation)
       (cons 'primitive-consent-doc primitive-consent-doc)
       (cons 'primitive-consent-describe primitive-consent-describe)
       (cons 'primitive-macroexpand primitive-macroexpand)
       (cons 'primitive-macroexpand-1 primitive-macroexpand-1)
       (cons 'primitive-macroexpand-library primitive-macroexpand-library)
       (cons 'primitive-macro-binding-info primitive-macro-binding-info)
       (cons 'primitive-syntax-source primitive-syntax-source)
       (cons 'primitive-macroexpand-yield primitive-macroexpand-yield)
       (cons 'primitive-current-error primitive-current-error)
       (cons 'primitive-condition-stack primitive-condition-stack)
       (cons 'primitive-condition-environment
             primitive-condition-environment)
       (cons 'primitive-condition-restarts primitive-condition-restarts)
       (cons 'primitive-restart-invoke! primitive-restart-invoke!)
       (cons 'primitive-debugger-yield primitive-debugger-yield)
       (cons 'primitive-approval-request! primitive-approval-request!)
       (cons 'primitive-approval-status primitive-approval-status)
       (cons 'primitive-approval-cancel! primitive-approval-cancel!)
       (cons 'primitive-approval-yield-pending
             primitive-approval-yield-pending)
       (cons 'primitive-approval-resolve! primitive-approval-resolve!)
       (cons 'primitive-job-start! primitive-job-start!)
       (cons 'primitive-job-ref primitive-job-ref)
       (cons 'primitive-job-list primitive-job-list)
       (cons 'primitive-job-cancel! primitive-job-cancel!)
       (cons 'primitive-job-interrupt! primitive-job-interrupt!)
       (cons 'primitive-job-yields primitive-job-yields)
       (cons 'primitive-job-status primitive-job-status)
       (cons 'primitive-grant-capability! primitive-grant-capability!)
       (cons 'primitive-current-grants primitive-current-grants)
       (cons 'primitive-grant-ref primitive-grant-ref)
       (cons 'primitive-grant-attenuate primitive-grant-attenuate)
       (cons 'primitive-grant-revoke! primitive-grant-revoke!)
       (cons 'primitive-call-with-capability-grant
             primitive-call-with-capability-grant)
       (cons 'primitive-handle-ref primitive-handle-ref)
       (cons 'primitive-handle-live? primitive-handle-live?)
       (cons 'primitive-handle-kind primitive-handle-kind)
       (cons 'primitive-handle-revalidate primitive-handle-revalidate)
       (cons 'primitive-handle-release! primitive-handle-release!)
       (cons 'primitive-memory-put! primitive-memory-put!)
       (cons 'primitive-memory-ref primitive-memory-ref)
       (cons 'primitive-memory-delete! primitive-memory-delete!)
       (cons 'primitive-memory-add! primitive-memory-add!)
       (cons 'primitive-memory-find primitive-memory-find)
       (cons 'primitive-memory-by-tag primitive-memory-by-tag)
       (cons 'primitive-memory-recent primitive-memory-recent)
       (cons 'primitive-memory-access! primitive-memory-access!)
       (cons 'primitive-memory-reflect! primitive-memory-reflect!)
       (cons 'primitive-memory-select primitive-memory-select)
       (cons 'primitive-memory-yield primitive-memory-yield)
       (cons 'primitive-agent-artifact primitive-agent-artifact)
       (cons 'primitive-agent-helper-save! primitive-agent-helper-save!)
       (cons 'primitive-agent-helper-load primitive-agent-helper-load)
       (cons 'primitive-agent-helper-list primitive-agent-helper-list)
       (cons 'primitive-agent-helper-ref primitive-agent-helper-ref)
       (cons 'primitive-agent-helper-promote-to-skill
             primitive-agent-helper-promote-to-skill)
       (cons 'primitive-agent-test-eval-source-result
             primitive-agent-test-eval-source-result)
       (cons 'primitive-plan-create! primitive-plan-create!)
       (cons 'primitive-plan-ref primitive-plan-ref)
       (cons 'primitive-plan-list primitive-plan-list)
       (cons 'primitive-plan-step-add! primitive-plan-step-add!)
       (cons 'primitive-plan-step-status! primitive-plan-step-status!)
       (cons 'primitive-plan-status! primitive-plan-status!)
       (cons 'primitive-plan-yield primitive-plan-yield)
       (cons 'primitive-model-provider-register!
             primitive-model-provider-register!)
       (cons 'primitive-model-providers primitive-model-providers)
       (cons 'primitive-model-route primitive-model-route)
       (cons 'primitive-model-complete primitive-model-complete)
       (cons 'primitive-model-provider-diagnostics
             primitive-model-provider-diagnostics)
       (cons 'primitive-current-request primitive-current-request)
       (cons 'primitive-current-focus primitive-current-focus)
       (cons 'primitive-current-region-context
             primitive-current-region-context)
       (cons 'primitive-current-buffer-context
             primitive-current-buffer-context)
       (cons 'primitive-current-project-context
             primitive-current-project-context)
       (cons 'primitive-current-conversation-summary
             primitive-current-conversation-summary)
       (cons 'primitive-context-yield primitive-context-yield)
       (cons 'primitive-secret-source? primitive-secret-source?)
       (cons 'primitive-redact primitive-redact)
       (cons 'primitive-context-local-only! primitive-context-local-only!)
       (cons 'primitive-redaction-log primitive-redaction-log)
       (cons 'primitive-safe-for-provider? primitive-safe-for-provider?)
       (cons 'primitive-car primitive-car)
       (cons 'primitive-cdr primitive-cdr)))

    (define (library-primitive-implementation-for-name name)
      "Resolve primitive implementations requested by the library module."
      (let ((entry (assq name library-primitive-implementation-table)))
        (if entry
            (cdr entry)
            (eval-error "unknown library primitive implementation" name))))

    ;; Install this interpreter and macro expander for library resolution.
    (define library-backend-installed
      (consent-install-library-backend!
       library-primitive-implementation-for-name
       policy-denied-primitive
       trampoline
       make-empty-syntax-environment
       syntax-environment-ref
       with-syntax-environment))

    ;; Install the applier the library layer uses to call interpreted closures
    ;; that programs pass as callbacks into natively bound library procedures.
    (define native-applier-installed
      (consent-install-native-applier!
       (lambda (procedure arguments context)
         (apply-procedure procedure arguments context #f))))
    ;; Map base registry implementation names to interpreter procedures.
    (define base-primitive-implementation-table
      (list
       (cons 'primitive* primitive*)
       (cons 'primitive+ primitive+)
       (cons 'primitive- primitive-)
       (cons 'primitive/ primitive/)
       (cons 'primitive< primitive<)
       (cons 'primitive<= primitive<=)
       (cons 'primitive= primitive=)
       (cons 'primitive> primitive>)
       (cons 'primitive>= primitive>=)
       (cons 'primitive-apply primitive-apply)
       (cons 'primitive-binary-port? primitive-binary-port?)
       (cons 'primitive-boolean=? primitive-boolean=?)
       (cons 'primitive-boolean? primitive-boolean?)
       (cons 'primitive-bytevector primitive-bytevector)
       (cons 'primitive-bytevector-append primitive-bytevector-append)
       (cons 'primitive-bytevector-copy primitive-bytevector-copy)
       (cons 'primitive-bytevector-copy! primitive-bytevector-copy!)
       (cons 'primitive-bytevector-length primitive-bytevector-length)
       (cons 'primitive-bytevector-u8-ref primitive-bytevector-u8-ref)
       (cons 'primitive-bytevector-u8-set! primitive-bytevector-u8-set!)
       (cons 'primitive-bytevector? primitive-bytevector?)
       (cons 'primitive-call/cc primitive-call/cc)
       (cons 'primitive-call-with-port primitive-call-with-port)
       (cons 'primitive-call-with-values primitive-call-with-values)
       (cons 'primitive-car primitive-car)
       (cons 'primitive-cdr primitive-cdr)
       (cons 'primitive-ceiling primitive-ceiling)
       (cons 'primitive-char->integer primitive-char->integer)
       (cons 'primitive-char<=? primitive-char<=?)
       (cons 'primitive-char<? primitive-char<?)
       (cons 'primitive-char=? primitive-char=?)
       (cons 'primitive-char>=? primitive-char>=?)
       (cons 'primitive-char>? primitive-char>?)
       (cons 'primitive-char-ready? primitive-char-ready?)
       (cons 'primitive-char? primitive-char?)
       (cons 'primitive-close-input-port primitive-close-input-port)
       (cons 'primitive-close-output-port primitive-close-output-port)
       (cons 'primitive-close-port primitive-close-port)
       (cons 'primitive-complex? primitive-complex?)
       (cons 'primitive-cons primitive-cons)
       (cons 'primitive-current-error-port primitive-current-error-port)
       (cons 'primitive-current-input-port primitive-current-input-port)
       (cons 'primitive-current-output-port primitive-current-output-port)
       (cons 'primitive-dynamic-wind primitive-dynamic-wind)
       (cons 'primitive-eq? primitive-eq?)
       (cons 'primitive-equal? primitive-equal?)
       (cons 'primitive-eqv? primitive-eqv?)
       (cons 'primitive-eof-object primitive-eof-object)
       (cons 'primitive-eof-object? primitive-eof-object?)
       (cons 'primitive-error primitive-error)
       (cons 'primitive-error-object-irritants primitive-error-object-irritants)
       (cons 'primitive-error-object-message primitive-error-object-message)
       (cons 'primitive-error-object? primitive-error-object?)
       (cons 'primitive-denominator primitive-denominator)
       (cons 'primitive-exact primitive-exact)
       (cons 'primitive-exact-integer-sqrt primitive-exact-integer-sqrt)
       (cons 'primitive-exact-integer? primitive-exact-integer?)
       (cons 'primitive-exact? primitive-exact?)
       (cons 'primitive-expt primitive-expt)
       (cons 'primitive-features primitive-features)
       (cons 'primitive-file-error? primitive-file-error?)
       (cons 'primitive-floor primitive-floor)
       (cons 'primitive-floor/ primitive-floor/)
       (cons 'primitive-floor-quotient primitive-floor-quotient)
       (cons 'primitive-floor-remainder primitive-floor-remainder)
       (cons 'primitive-flush-output-port primitive-flush-output-port)
       (cons 'primitive-gcd primitive-gcd)
       (cons 'primitive-get-output-bytevector primitive-get-output-bytevector)
       (cons 'primitive-get-output-string primitive-get-output-string)
       (cons 'primitive-inexact primitive-inexact)
       (cons 'primitive-inexact? primitive-inexact?)
       (cons 'primitive-input-port-open? primitive-input-port-open?)
       (cons 'primitive-input-port? primitive-input-port?)
       (cons 'primitive-integer->char primitive-integer->char)
       (cons 'primitive-integer? primitive-integer?)
       (cons 'primitive-lcm primitive-lcm)
       (cons 'primitive-list->string primitive-list->string)
       (cons 'primitive-list->vector primitive-list->vector)
       (cons 'primitive-list? primitive-list?)
       (cons 'primitive-make-bytevector primitive-make-bytevector)
       (cons 'primitive-make-parameter primitive-make-parameter)
       (cons 'primitive-make-string primitive-make-string)
       (cons 'primitive-make-vector primitive-make-vector)
       (cons 'primitive-modulo primitive-modulo)
       (cons 'primitive-newline primitive-newline)
       (cons 'primitive-null? primitive-null?)
       (cons 'primitive-number->string primitive-number->string)
       (cons 'primitive-number? primitive-number?)
       (cons 'primitive-numerator primitive-numerator)
       (cons 'primitive-open-input-bytevector primitive-open-input-bytevector)
       (cons 'primitive-open-input-string primitive-open-input-string)
       (cons 'primitive-open-output-bytevector primitive-open-output-bytevector)
       (cons 'primitive-open-output-string primitive-open-output-string)
       (cons 'primitive-output-port-open? primitive-output-port-open?)
       (cons 'primitive-output-port? primitive-output-port?)
       (cons 'primitive-pair? primitive-pair?)
       (cons 'primitive-peek-char primitive-peek-char)
       (cons 'primitive-peek-u8 primitive-peek-u8)
       (cons 'primitive-port? primitive-port?)
       (cons 'primitive-procedure? primitive-procedure?)
       (cons 'primitive-quotient primitive-quotient)
       (cons 'primitive-raise primitive-raise)
       (cons 'primitive-raise-continuable primitive-raise-continuable)
       (cons 'primitive-rational? primitive-rational?)
       (cons 'primitive-rationalize primitive-rationalize)
       (cons 'primitive-read-bytevector primitive-read-bytevector)
       (cons 'primitive-read-bytevector! primitive-read-bytevector!)
       (cons 'primitive-read-char primitive-read-char)
       (cons 'primitive-read-error? primitive-read-error?)
       (cons 'primitive-read-line primitive-read-line)
       (cons 'primitive-read-string primitive-read-string)
       (cons 'primitive-read-u8 primitive-read-u8)
       (cons 'primitive-real? primitive-real?)
       (cons 'primitive-remainder primitive-remainder)
       (cons 'primitive-round primitive-round)
       (cons 'primitive-set-car! primitive-set-car!)
       (cons 'primitive-set-cdr! primitive-set-cdr!)
       (cons 'primitive-string primitive-string)
       (cons 'primitive-string->list primitive-string->list)
       (cons 'primitive-string->number primitive-string->number)
       (cons 'primitive-string->symbol primitive-string->symbol)
       (cons 'primitive-string->utf8 primitive-string->utf8)
       (cons 'primitive-string->vector primitive-string->vector)
       (cons 'primitive-string-append primitive-string-append)
       (cons 'primitive-string-copy primitive-string-copy)
       (cons 'primitive-string-copy! primitive-string-copy!)
       (cons 'primitive-string-fill! primitive-string-fill!)
       (cons 'primitive-string-length primitive-string-length)
       (cons 'primitive-string-ref primitive-string-ref)
       (cons 'primitive-string-set! primitive-string-set!)
       (cons 'primitive-string<=? primitive-string<=?)
       (cons 'primitive-string<? primitive-string<?)
       (cons 'primitive-string=? primitive-string=?)
       (cons 'primitive-string>=? primitive-string>=?)
       (cons 'primitive-string>? primitive-string>?)
       (cons 'primitive-string? primitive-string?)
       (cons 'primitive-substring primitive-substring)
       (cons 'primitive-symbol->string primitive-symbol->string)
       (cons 'primitive-symbol=? primitive-symbol=?)
       (cons 'primitive-symbol? primitive-symbol?)
       (cons 'primitive-textual-port? primitive-textual-port?)
       (cons 'primitive-truncate primitive-truncate)
       (cons 'primitive-truncate/ primitive-truncate/)
       (cons 'primitive-truncate-quotient primitive-truncate-quotient)
       (cons 'primitive-truncate-remainder primitive-truncate-remainder)
       (cons 'primitive-u8-ready? primitive-u8-ready?)
       (cons 'primitive-utf8->string primitive-utf8->string)
       (cons 'primitive-vector primitive-vector)
       (cons 'primitive-vector->list primitive-vector->list)
       (cons 'primitive-vector->string primitive-vector->string)
       (cons 'primitive-vector-append primitive-vector-append)
       (cons 'primitive-vector-copy primitive-vector-copy)
       (cons 'primitive-vector-copy! primitive-vector-copy!)
       (cons 'primitive-vector-fill! primitive-vector-fill!)
       (cons 'primitive-vector-length primitive-vector-length)
       (cons 'primitive-vector-ref primitive-vector-ref)
       (cons 'primitive-vector-set! primitive-vector-set!)
       (cons 'primitive-vector? primitive-vector?)
       (cons 'primitive-values primitive-values)
       (cons 'primitive-with-exception-handler primitive-with-exception-handler)
       (cons 'primitive-write-bytevector primitive-write-bytevector)
       (cons 'primitive-write-char primitive-write-char)
       (cons 'primitive-write-string primitive-write-string)
       (cons 'primitive-write-u8 primitive-write-u8)))

    (define (base-primitive-implementation-for-name name)
      "Resolve primitive implementation names requested by the base module."
      (let ((entry (assq name base-primitive-implementation-table)))
        (if entry
            (cdr entry)
            (eval-error "unknown base primitive implementation" name))))

    ;; Install this interpreter as the backend for base bootstrapping.
    (define base-backend-installed
      (consent-install-base-backend!
       base-primitive-implementation-for-name
       trampoline
       eval-define-syntax))
    (define (rest-environment rest)
      "Return the optional caller environment or a fresh base environment."
      (if (or (null? rest) (not (car rest)))
          (consent-make-base-environment)
          (car rest)))

    (define (rest-options rest)
      "Return the optional caller options alist, defaulting to empty."
      (if (or (null? rest) (null? (cdr rest)))
          '()
          (second rest)))

    ;; Standard streams (docs/repl-interaction-contract.md, "Stream Separation"):
    ;; an evaluation may connect its `(current-input-port)',
    ;; `(current-output-port)', and `(current-error-port)' to the process standard
    ;; streams.  The standard streams are *consented by invocation* -- they are what
    ;; the caller handed the process -- so the host that attaches real stdio also
    ;; supplies, by default, the device callbacks plus one `port' grant per stream
    ;; (`(backing stdin)'/`stdout'/`stderr'); the core stays fail-closed and connects
    ;; a stream only when its device and a matching active grant are both present.  A
    ;; context with no devices/grants (the daemon/agent adapter, the host-run test
    ;; runner) keeps its streams disconnected/captured.  No raw host port is exposed
    ;; to Scheme: input is pulled through a reader thunk and output flushed through a
    ;; writer thunk.  Ambient effects (files, processes, network, env, clock,
    ;; providers, editor) still gate independently.
    (define (standard-stream-grant-backing grant)
      "Return GRANT's scope `(backing X)' value, or #f when absent."
      (let loop ((scope (capability-grant-field-values grant 'scope)))
        (cond
         ((null? scope) #f)
         ((and (pair? (car scope)) (eq? (caar scope) 'backing))
          (let ((clause (car scope)))
            (and (pair? (cdr clause)) (cadr clause))))
         (else (loop (cdr scope))))))

    (define (standard-stream-grant? grant backing operation)
      "Report whether GRANT is an active `port' grant for OPERATION backed by BACKING."
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-grant-field-value grant 'domain) 'port)
           (eq? (capability-grant-status grant) 'active)
           (memq operation (capability-grant-field-values grant 'operations))
           (eq? (standard-stream-grant-backing grant) backing)))

    (define (find-standard-stream-grant context backing operation)
      "Return CONTEXT's active `port' grant for OPERATION backed by BACKING, or #f."
      (let loop ((grants (context-capability-grants context)))
        (cond
         ((null? grants) #f)
         ((standard-stream-grant? (car grants) backing operation) (car grants))
         (else (loop (cdr grants))))))

    ;; A program-input port draws characters from a host *reader* on demand: a
    ;; zero-argument procedure returning the next chunk of input as a non-empty
    ;; string, or #f at end of stream.  The host supplies it (its real stdin read,
    ;; one line/chunk at a time); genuinely finite in-memory input is wrapped as a
    ;; one-shot reader by `consent-program-input-from-string'.  Reads refill only
    ;; as far as the current operation needs, so a `(read-line)' filter over a
    ;; live or unbounded pipe processes input incrementally instead of draining it
    ;; all up front.  The reader and an end-of-stream flag ride in the port's
    ;; mutable counters alist; the growable buffer is the port `source'.
    (define program-input-refill-primitive
      (make-primitive-procedure 'program-input-read #f 0 0))

    (define (consent-program-input-from-string content)
      "Return a one-shot program-input reader that yields CONTENT once, then"
      "ends.  This is the honest finite-input constructor -- a stream whose"
      "whole contents are available immediately and which then reaches end of"
      "stream.  Use it for fixtures, captured-transcript replay, and other"
      "genuinely in-memory input; it is never a way to model a live stdin,"
      "which has a time dimension a buffer cannot represent."
      #((parameters
         (content (type string)
          (description
           ("String holding the whole finite program input, yielded"
             "once."))))
        (returns
         . ("A reader thunk returning CONTENT on its first call and #f"
            "thereafter."))
        (effects allocation))
      (let ((pending content))
        (lambda ()
          (let ((chunk pending))
            (set! pending #f)
            chunk))))

    ;; The binary peer of `consent-program-input-from-string': a one-shot byte
    ;; reader for genuinely finite in-memory input.  The textual stream's chunk is
    ;; a string; the binary stream's chunk is a bytevector, so this is the honest
    ;; finite binary-input constructor (fixtures, captured byte streams) and never
    ;; a way to model a live stdin, which has a time dimension a buffer cannot
    ;; represent.
    (define (consent-program-input-from-bytevector content)
      "Return a one-shot binary program-input reader yielding CONTENT once,"
      "then ends.  CONTENT is a bytevector whose bytes are the whole finite"
      "input, available immediately and then at end of stream.  Use it for"
      "fixtures and captured byte streams; for a live byte pipe the host"
      "supplies its own incremental byte reader."
      #((parameters
         (content (type bytevector)
          (description
           ("Bytevector holding the whole finite binary input, yielded"
             "once."))))
        (returns
         . ("A reader thunk returning CONTENT on its first call and #f"
            "thereafter."))
        (effects allocation))
      (let ((pending content))
        (lambda ()
          (let ((chunk pending))
            (set! pending #f)
            chunk))))

    (define (program-input-reader-from-options options)
      "Return the host input reader thunk from OPTIONS'"
      "`program-input-reader', or #f.  Program input is always a reader (a"
      "stream); a caller with finite in-memory input wraps it with"
      "`consent-program-input-from-string' rather than passing a raw string,"
      "so the finite case states its no-time-dimension nature explicitly."
      (let ((reader (option-ref options 'program-input-reader #f)))
        (and (procedure? reader) reader)))

    (define (program-input-streaming? port)
      "Report whether PORT draws from a host program-input reader."
      (and (consent-port? port)
           (eq? (consent-port-backing-domain port) 'stdio)
           (assq 'program-input-reader (consent-port-counters port))
           #t))

    (define (program-input-reader-of port)
      "Return PORT's host input reader procedure."
      (let ((entry (assq 'program-input-reader (consent-port-counters port))))
        (and entry (cdr entry))))

    (define (program-input-eof? port)
      "Report whether PORT's host reader has reached end of stream."
      (let ((entry (assq 'program-input-eof (consent-port-counters port))))
        (and entry (cdr entry))))

    (define (program-input-set-eof! port)
      "Mark PORT's host reader as exhausted so it is not called again."
      (set-consent-port-counters!
       port
       (cons (cons 'program-input-eof #t) (consent-port-counters port))))

    (define (program-input-refill! port context)
      "Pull one more chunk from PORT's host reader onto its buffer."
      "Return #t when characters were appended, #f at end of stream.  Each"
      "pull is charged against the host-callback budget and audited as a"
      "port read, so an unbounded stream stays budget-bounded and fail-closed"
      "like every host effect."
      (if (program-input-eof? port)
          #f
          (begin
            (note-host-callback! context program-input-refill-primitive)
            (let ((chunk ((program-input-reader-of port))))
              (if (and (string? chunk) (> (string-length chunk) 0))
                  (begin
                    (set-consent-port-source!
                     port
                     (string-append (consent-port-source port) chunk))
                    (audit-port-capability-result!
                     context port 'read (string-length chunk) #f)
                    #t)
                  (begin
                    (program-input-set-eof! port)
                    #f))))))

    (define (program-input-fill-until! port context done?)
      "Refill PORT from its host reader until DONE? holds or the stream ends."
      (let loop ()
        (if (and (not (done?)) (not (program-input-eof? port)))
            (begin
              (program-input-refill! port context)
              (loop)))))

    (define (program-input-line-buffered? source position)
      "Report whether SOURCE holds a newline at or after POSITION (line is complete)."
      (let ((length (string-length source)))
        (let loop ((index position))
          (cond
           ((>= index length) #f)
           ((char=? (string-ref source index) #\newline) #t)
           (else (loop (+ index 1)))))))

    (define (program-input-read-streaming port context)
      "Read one datum from streaming PORT, refilling until a complete datum"
      "is buffered, then delegating to the validating raise-on-error reader"
      "so streaming `read' shares the single datum path.  Refilling keeps"
      "pulling while the buffered prefix is `incomplete' (a valid partial"
      "datum) or `eof' (exhausted without a datum yet), and stops once a whole"
      "`datum' is buffered or the prefix is `invalid'; `program-input-fill-until!'"
      "also stops when the host stream itself ends."
      (program-input-fill-until!
       port context
       (lambda ()
         (memq (consent-recovery-step-status
                (consent-read-recover-from-string-at
                 (consent-port-source port)
                 (consent-port-position port)
                 (context-reader-options context)))
               '(datum invalid))))
      (let ((result (consent-read-from-string-at
                     (consent-port-source port)
                     (consent-port-position port)
                     (context-reader-options context))))
        (set-consent-port-position! port (cdr result))
        (audit-port-capability-result! context port 'read 'datum #f)
        (if (consent-read-eof? (car result))
            consent-eof-object
            (car result))))

    (define (make-program-input-port context grant reader)
      "Return a capability-gated, refill-on-demand textual input port for"
      "GRANT.  The port is backed by the `stdio' domain so every read"
      "revalidates GRANT and audits the operation, and pulls characters from"
      "READER on demand rather than holding a live host port."
      (let* ((grant-id (capability-grant-id grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'string #t #f #t #f #t "" 0 #f
               'stdio
               '(read close)
               grant-id
               limits
               (port-capability-handle-id)
               'open
               'program-input
               (list (cons 'program-input-reader reader)))))
        (record-audit-event!
         context
         'capability-handle
         (list (list 'handle
                     (port-capability-datum
                      (consent-port-handle port) 'textual-input 'stdio
                      (consent-port-operations port) grant-id limits 'open
                      'program-input))
               (list 'domain 'port)
               (list 'kind 'textual-input)
               (list 'backing 'stdio)
               (cons 'operations (consent-port-operations port))
               (list 'grant grant-id)
               (list 'status 'open)))
        port))

    ;; The binary peer of the program-input port (#528): a `stdio'-backed binary
    ;; input port that refills *bytes* on demand from a host byte reader -- a
    ;; zero-argument procedure returning the next chunk as a non-empty bytevector,
    ;; or #f at end of stream -- so a byte filter calling `read-u8'/`peek-u8'/
    ;; `read-bytevector' over a live or unbounded pipe processes input incrementally
    ;; instead of draining it up front.  The byte reader and an end-of-stream flag
    ;; ride in the port's counters alist; the growable buffer is the port `source'
    ;; bytevector.  It is the byte twin of the textual reader thunk and uses a
    ;; distinct counters key so a binary and a textual stdin port never cross paths.
    (define program-binary-input-refill-primitive
      (make-primitive-procedure 'program-binary-input-read #f 0 0))

    (define (program-binary-input-streaming? port)
      "Report whether PORT draws bytes from a host program-input byte reader."
      (and (consent-port? port)
           (eq? (consent-port-backing-domain port) 'stdio)
           (assq 'program-input-byte-reader (consent-port-counters port))
           #t))

    (define (program-binary-input-reader-of port)
      "Return PORT's host input byte reader procedure."
      (let ((entry (assq 'program-input-byte-reader (consent-port-counters port))))
        (and entry (cdr entry))))

    (define (program-binary-input-eof? port)
      "Report whether PORT's host byte reader has reached end of stream."
      (let ((entry (assq 'program-input-byte-eof (consent-port-counters port))))
        (and entry (cdr entry))))

    (define (program-binary-input-set-eof! port)
      "Mark PORT's host byte reader as exhausted so it is not called again."
      (set-consent-port-counters!
       port
       (cons (cons 'program-input-byte-eof #t) (consent-port-counters port))))

    (define (program-binary-input-refill! port context)
      "Pull one more chunk from PORT's host byte reader onto its buffer."
      "Return #t when bytes were appended, #f at end of stream.  Each pull"
      "is charged against the host-callback budget and audited as a port"
      "read, so an unbounded byte stream stays budget-bounded and fail-closed"
      "like every host effect."
      (if (program-binary-input-eof? port)
          #f
          (begin
            (note-host-callback! context program-binary-input-refill-primitive)
            (let ((chunk ((program-binary-input-reader-of port))))
              (if (and (bytevector? chunk) (> (bytevector-length chunk) 0))
                  (begin
                    (set-consent-port-source!
                     port
                     (bytevector-append (consent-port-source port) chunk))
                    (audit-port-capability-result!
                     context port 'read (bytevector-length chunk) #f)
                    #t)
                  (begin
                    (program-binary-input-set-eof! port)
                    #f))))))

    (define (program-binary-input-fill-until! port context done?)
      "Refill PORT from its host byte reader until DONE? holds or the stream ends."
      (let loop ()
        (if (and (not (done?)) (not (program-binary-input-eof? port)))
            (begin
              (program-binary-input-refill! port context)
              (loop)))))

    (define (program-binary-input-buffered>=? port amount)
      "Report whether PORT has at least AMOUNT unread bytes buffered."
      (>= (- (bytevector-length (consent-port-source port))
             (consent-port-position port))
          amount))

    (define (make-program-binary-input-port context grant reader)
      "Return a capability-gated, refill-on-demand binary input port for"
      "GRANT.  The port is backed by the `stdio' domain so every read"
      "revalidates GRANT and audits the operation, and pulls bytes from"
      "READER on demand rather than holding a live host port.  It is the"
      "binary twin of `make-program-input-port'."
      (let* ((grant-id (capability-grant-id grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'bytevector #t #f #f #t #t (make-bytevector 0 0) 0 #f
               'stdio
               '(read close)
               grant-id
               limits
               (port-capability-handle-id)
               'open
               'program-input
               (list (cons 'program-input-byte-reader reader)))))
        (record-audit-event!
         context
         'capability-handle
         (list (list 'handle
                     (port-capability-datum
                      (consent-port-handle port) 'binary-input 'stdio
                      (consent-port-operations port) grant-id limits 'open
                      'program-input))
               (list 'domain 'port)
               (list 'kind 'binary-input)
               (list 'backing 'stdio)
               (cons 'operations (consent-port-operations port))
               (list 'grant grant-id)
               (list 'status 'open)))
        port))

    ;; A program-output / program-error port is the write side of the standard
    ;; streams: a `stdio'-backed port whose textual writes flush through a host
    ;; writer thunk immediately (see `write-text-to-port'), so program output is
    ;; never buffered to end of program and a filter streams as it runs.  The
    ;; writer rides in the port's counters alist.
    (define program-output-write-primitive
      (make-primitive-procedure 'program-output-write #f 0 0))

    (define (program-output-streaming? port)
      "Report whether PORT flushes through a host program-output writer."
      (and (consent-port? port)
           (consent-port-output? port)
           (eq? (consent-port-backing-domain port) 'stdio)
           (assq 'program-output-writer (consent-port-counters port))
           #t))

    (define (program-output-writer-of port)
      "Return PORT's host output writer procedure."
      (let ((entry (assq 'program-output-writer (consent-port-counters port))))
        (and entry (cdr entry))))

    (define (make-program-output-port context grant writer purpose)
      "Return a capability-gated, write-through textual output port for"
      "GRANT.  PURPOSE is `program-output' or `program-error'.  The port is"
      "backed by the `stdio' domain so every write revalidates GRANT and"
      "audits the operation, and flushes through WRITER immediately rather"
      "than holding a live host port."
      (let* ((grant-id (capability-grant-id grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'string #f #t #t #f #t #f 0 ""
               'stdio
               '(write flush close)
               grant-id
               limits
               (port-capability-handle-id)
               'open
               purpose
               (list (cons 'program-output-writer writer)))))
        (record-audit-event!
         context
         'capability-handle
         (list (list 'handle
                     (port-capability-datum
                      (consent-port-handle port) 'textual-output 'stdio
                      (consent-port-operations port) grant-id limits 'open
                      purpose))
               (list 'domain 'port)
               (list 'kind 'textual-output)
               (list 'backing 'stdio)
               (cons 'operations (consent-port-operations port))
               (list 'grant grant-id)
               (list 'status 'open)))
        port))

    ;; The binary peer of the program-output / program-error port (#528): a
    ;; `stdio'-backed binary output port whose byte writes flush through a host
    ;; byte writer immediately (see `append-bytes-to-port'), so a `write-u8'/
    ;; `write-bytevector' filter streams as it runs instead of buffering to end of
    ;; program.  The byte writer receives each flush as a list of byte integers --
    ;; the representation `append-bytes-to-port' already accumulates -- and rides in
    ;; the port's counters under a distinct key from the textual writer.
    (define program-binary-output-write-primitive
      (make-primitive-procedure 'program-binary-output-write #f 0 0))

    (define (program-binary-output-streaming? port)
      "Report whether PORT flushes through a host program-output byte writer."
      (and (consent-port? port)
           (consent-port-output? port)
           (eq? (consent-port-backing-domain port) 'stdio)
           (assq 'program-output-byte-writer (consent-port-counters port))
           #t))

    (define (program-binary-output-writer-of port)
      "Return PORT's host output byte writer procedure."
      (let ((entry (assq 'program-output-byte-writer
                         (consent-port-counters port))))
        (and entry (cdr entry))))

    (define (make-program-binary-output-port context grant writer purpose)
      "Return a capability-gated, write-through binary output port for"
      "GRANT.  PURPOSE is `program-output' or `program-error'.  The port is"
      "backed by the `stdio' domain so every write revalidates GRANT and"
      "audits the operation, and flushes bytes through WRITER immediately."
      "Binary twin of `make-program-output-port'."
      (let* ((grant-id (capability-grant-id grant))
             (limits (capability-grant-field-values grant 'limits))
             (port
              (make-consent-port
               'bytevector #f #t #f #t #t #f 0 '()
               'stdio
               '(write flush close)
               grant-id
               limits
               (port-capability-handle-id)
               'open
               purpose
               (list (cons 'program-output-byte-writer writer)))))
        (record-audit-event!
         context
         'capability-handle
         (list (list 'handle
                     (port-capability-datum
                      (consent-port-handle port) 'binary-output 'stdio
                      (consent-port-operations port) grant-id limits 'open
                      purpose))
               (list 'domain 'port)
               (list 'kind 'binary-output)
               (list 'backing 'stdio)
               (cons 'operations (consent-port-operations port))
               (list 'grant grant-id)
               (list 'status 'open)))
        port))

    (define (connect-standard-stream! context device backing operation build install)
      "Connect one standard stream when DEVICE and a matching grant are"
      "present.  DEVICE is the host reader/writer (or #f); BACKING/OPERATION"
      "select the grant; BUILD makes the port from (context grant); INSTALL"
      "stores it on CONTEXT.  Without the grant the connection is denied and"
      "recorded; without the device it is a no-op, so the default posture"
      "stays fail-closed."
      (if device
          (let ((grant (find-standard-stream-grant context backing operation))
                (request
                 (list 'capability-request
                       (list 'domain 'port)
                       (list 'operation operation)
                       (list 'backing backing))))
            (record-audit-event!
             context
             'capability-request
             (list (list 'request request)
                   (list 'domain 'port)
                   (list 'operation operation)
                   (list 'backing backing)))
            (if grant
                (begin
                  (record-audit-event!
                   context
                   'capability-decision
                   (list (list 'request request)
                         (list 'status 'approved)
                         (list 'domain 'port)
                         (list 'operation operation)
                         (list 'backing backing)
                         (list 'grant (capability-grant-id grant))))
                  (install (build context grant)))
                (record-audit-event!
                 context
                 'capability-decision
                 (list (list 'request request)
                       (list 'status 'denied)
                       (list 'domain 'port)
                       (list 'operation operation)
                       (list 'backing backing)
                       (list 'reason
                             "standard stream requires a matching port grant")))))))

    (define (connect-standard-streams! context options)
      "Connect CONTEXT's current input/output/error ports to the granted"
      "standard streams.  Each stream is wired only when OPTIONS supply its"
      "host device (a textual `program-input-reader' thunk /"
      "`program-output-writer' / `program-error-writer', or the binary"
      "`program-input-byte-reader' / `program-output-byte-writer' /"
      "`program-error-byte-writer' peers) AND CONTEXT holds a matching active"
      "`port' grant; absent the grant the stream fails closed, absent the"
      "device it is left untouched.  A stream is textual or binary, not both"
      "within a run: the binary device connects only when the textual device"
      "for the same stream is absent, so the established textual path takes"
      "precedence and the binary peer is purely additive (a byte filter"
      "offers byte devices instead).  The standard streams are consented by"
      "invocation -- the host attaching them is the authorization -- while"
      "ambient effects keep gating separately."
      (let ((reader (program-input-reader-from-options options))
            (out-writer (option-ref options 'program-output-writer #f))
            (err-writer (option-ref options 'program-error-writer #f))
            (byte-reader (option-ref options 'program-input-byte-reader #f))
            (out-byte-writer (option-ref options 'program-output-byte-writer #f))
            (err-byte-writer (option-ref options 'program-error-byte-writer #f)))
        (connect-standard-stream!
         context reader 'stdin 'read
         (lambda (ctx grant) (make-program-input-port ctx grant reader))
         (lambda (port) (set-context-current-input-port! context port)))
        (connect-standard-stream!
         context (and (not reader) (procedure? byte-reader) byte-reader)
         'stdin 'read
         (lambda (ctx grant)
           (make-program-binary-input-port ctx grant byte-reader))
         (lambda (port) (set-context-current-input-port! context port)))
        (connect-standard-stream!
         context (and (procedure? out-writer) out-writer) 'stdout 'write
         (lambda (ctx grant)
           (make-program-output-port ctx grant out-writer 'program-output))
         (lambda (port) (set-context-current-output-port! context port)))
        (connect-standard-stream!
         context (and (not (procedure? out-writer))
                      (procedure? out-byte-writer) out-byte-writer)
         'stdout 'write
         (lambda (ctx grant)
           (make-program-binary-output-port
            ctx grant out-byte-writer 'program-output))
         (lambda (port) (set-context-current-output-port! context port)))
        (connect-standard-stream!
         context (and (procedure? err-writer) err-writer) 'stderr 'write
         (lambda (ctx grant)
           (make-program-output-port ctx grant err-writer 'program-error))
         (lambda (port) (set-context-current-error-port! context port)))
        (connect-standard-stream!
         context (and (not (procedure? err-writer))
                      (procedure? err-byte-writer) err-byte-writer)
         'stderr 'write
         (lambda (ctx grant)
           (make-program-binary-output-port
            ctx grant err-byte-writer 'program-error))
         (lambda (port) (set-context-current-error-port! context port)))))

    (define (consent-eval expression . rest)
      "Evaluate one already-read expression in the supplied environment, or a"
      "fresh base environment when no environment is provided."
      #((parameters
         (expression . "Already-read datum to evaluate.")
         (rest (type list)
          (description
           ("Optional environment then options alist; both default when"
             "absent."))))
        (returns . "The value produced by evaluating EXPRESSION.")
        (effects host-eval state-read state-write error))
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (set-context-interaction-environment! context environment)
        (connect-standard-streams! context (rest-options rest))
        (ensure-base-syntax! context environment)
        (trampoline expression environment context)))

    (define (consent-eval-source source . rest)
      "Read and evaluate a source body as a sequence that may contain"
      "definitions, imports, libraries, and expressions."
      #((parameters
         (source (type (or string port))
          (description ("Program source text or port read into a form sequence.")))
         (rest (type list)
          (description
           ("Optional environment then options alist; both default when"
             "absent."))))
        (returns . ("The value of the last form in the evaluated sequence."))
        (effects host-eval state-read state-write error))
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest))
            (forms (consent-read-all source (rest-options rest))))
        (set-context-interaction-environment! context environment)
        (connect-standard-streams! context (rest-options rest))
        (ensure-base-syntax! context environment)
        (trampoline (make-sequence forms #t) environment context)))

    ;; String evaluation is an alias kept for callers that name the source kind.
    (define consent-eval-string consent-eval-source)

    (define (call-with-result-condition-handler context thunk)
      "Call THUNK, converting any raised condition to an evaluation-result datum."
      (call/cc
       (lambda (return)
         (with-exception-handler
          (lambda (condition)
            (return (condition-result-datum condition context)))
          thunk))))

    (define (consent-eval-result expression . rest)
      "Result-producing evaluation catches conditions and returns an"
      "inspectable Scheme-readable evaluation-result datum instead of raising"
      "to the host."
      #((parameters
         (expression . "Already-read datum to evaluate.")
         (rest (type list)
          (description
           ("Optional environment then options alist; both default when"
             "absent."))))
        (returns (type evaluation-result)
         (description
          ("An `evaluation-result' datum capturing the value or the"
            "raised condition.")))
        (effects host-eval state-read state-write))
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (set-context-interaction-environment! context environment)
        (connect-standard-streams! context (rest-options rest))
        (ensure-base-syntax! context environment)
        (call-with-result-condition-handler
         context
         (lambda ()
           (ok-result-datum
            (trampoline expression environment context)
            context)))))

    (define (consent-eval-source-result source . rest)
      "Source result evaluation combines reader, evaluator, condition"
      "capture, and budget reporting for REPL and protocol-boundary callers."
      #((parameters
         (source (type (or string port))
          (description ("Program source text or port read into a form sequence.")))
         (rest (type list)
          (description
           ("Optional environment then options alist; both default when"
             "absent."))))
        (returns (type evaluation-result)
         (description
          ("An `evaluation-result' datum capturing the value or the"
            "raised condition.")))
        (effects host-eval state-read state-write))
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (set-context-interaction-environment! context environment)
        (connect-standard-streams! context (rest-options rest))
        (ensure-base-syntax! context environment)
        (call-with-result-condition-handler
         context
         (lambda ()
           (let ((forms (consent-read-all source (rest-options rest))))
             (ok-result-datum
              (trampoline (make-sequence forms #t) environment context)
              context))))))

    ;; A durable interaction context bundles the persistent state a REPL session
    ;; reuses across submissions: the evaluator options (carrying `session-id',
    ;; policy actions, and capability grants), the mutable value environment, and
    ;; the syntax environment.  Each submission still runs in a fresh evaluation
    ;; context with its own step/host-callback/event budget -- exactly as
    ;; `consent-eval-source-result' does -- but that context reuses the persisted
    ;; value and syntax environments.  Value definitions and imports persist
    ;; because they mutate the shared value environment; macros and imported
    ;; syntax persist because the shared syntax environment is threaded through
    ;; instead of being rebuilt per call.  This is the portable peer of the Emacs
    ;; session evaluator that drives `consent-repl-eval-source'.
    (define-record-type <consent-interaction-context>
      (make-consent-interaction-context options environment syntax-environment
                                        program-output-port program-input-port)
      consent-interaction-context?
      (options interaction-context-options)
      (environment interaction-context-environment)
      (syntax-environment interaction-context-syntax-environment)
      (program-output-port interaction-context-program-output-port)
      ;; The session program-input port, shared as the single stdin cursor between
      ;; the REPL form reader and evaluated reads, or #f when program input is not
      ;; connected (no reader/grant).  See the REPL engine's submission-boundary
      ;; hand-off via `consent-interaction-seed-program-input!'.
      (program-input-port interaction-context-program-input-port))

    (define (interaction-context-session-id-from-options options)
      "Return the SESSION-ID configured in OPTIONS, or #f when unsessioned."
      (let ((entry (assq 'session-id options)))
        (and entry (cdr entry))))

    (define (make-interaction-program-output-port)
      "Return a fresh textual string output port (like `open-output-string')"
      "for the program output stream."
      (make-consent-port
       'string #f #t #t #f #t #f 0 ""
       #f '() #f '() #f #f #f '()))

    (define (program-input-port-from-options options)
      "Return a pre-built program-input port supplied in OPTIONS, or #f."
      "The multi-session REPL injects one shared stdin port into every"
      "session's interaction context so switching sessions never forks the"
      "single stdin cursor."
      (let ((entry (assq 'program-input-port options)))
        (and entry (cdr entry))))

    (define (consent-make-interaction-context . rest)
      "Create a durable interaction context from optional REST options"
      "(session-id, policy-actions, capability-grants) whose definitions,"
      "imports, macros, and program output persist across"
      "`consent-interaction-eval-form' submissions."
      "When OPTIONS supply a pre-built `program-input-port' it is reused (the"
      "multi-session shared stdin cursor); otherwise, when OPTIONS supply a"
      "`program-input-reader' and a matching active `port'/`read' grant backed"
      "by `stdin', a program-input port is created and shared as the session's"
      "single stdin cursor (the REPL form reader and evaluated reads draw from"
      "it); otherwise program input stays disconnected and reads fail closed."
      #((parameters
         (rest (type list)
          (description
           ("Optional single options alist (session-id, policy-actions,"
             "capability-grants, program-input port/reader)."))))
        (returns (type consent-interaction-context)
         (description
          ("A durable `<consent-interaction-context>' record reused"
            "across submissions.")))
        (effects state-read allocation))
      (let* ((options (if (null? rest) '() (car rest)))
             (context (new-eval-context options))
             (environment (consent-make-base-environment))
             (reader (program-input-reader-from-options options))
             (grant (and reader
                         (find-standard-stream-grant context 'stdin 'read)))
             (input-port (or (program-input-port-from-options options)
                             (and reader grant
                                  (make-program-input-port
                                   context grant reader)))))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (make-consent-interaction-context
         options environment (context-syntax-environment context)
         (make-interaction-program-output-port)
         input-port)))

    (define (consent-repl-session-manager)
      "Return the process-local live session manager backing the REPL verbs."
      #((parameters)
        (returns . "The process-local active session manager.")
        (effects state-read))
      (active-session-manager))

    (define (consent-session-manager-current-context manager)
      "Return MANAGER's default session interaction context, or #f when none."
      #((parameters
         (manager (type consent-session-manager)
          (description ("Session manager whose current session is looked up."))))
        (returns (type (or consent-interaction-context boolean))
         (description
          ("The current session's interaction context, or #f when no"
            "session is current.")))
        (effects state-read))
      (let ((id (session-model:session-manager-current-id manager)))
        (and id (session-model:session-manager-context-ref manager id))))

    (define (consent-repl-seed-initial-session! manager session-id options)
      "Reset MANAGER and seed an initial named session for SESSION-ID."
      "Each REPL run starts from a clean manager (the process-local store is"
      "shared across evaluations), then installs a context factory that shares"
      "one program-input port across all sessions so the multi-session REPL"
      "keeps a single stdin cursor, and registers the initial session as the"
      "default."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to reset and seed."))
         (session-id (type (or symbol string))
          (description ("Symbol or string naming the initial default session.")))
         (options (type list)
          (description
           ("Options alist seeded into every session's interaction"
             "context."))))
        (returns (type consent-session-manager)
         (description "The seeded MANAGER."))
        (effects state-write allocation))
      (session-model:session-manager-reset! manager)
      (let* ((id (if (symbol? session-id)
                     session-id
                     (string->symbol session-id)))
             (initial (consent-make-interaction-context options))
             (shared-port
              (consent-interaction-program-input-port initial)))
        (session-model:session-manager-set-context-factory!
         manager
         (lambda (sid scope create-options)
           (consent-make-interaction-context
            (cons (cons 'session-id sid)
                  (cons (cons 'program-input-port shared-port)
                        options)))))
        (session-model:session-manager-seed! manager id 'named initial))
      manager)

    (define (consent-interaction-program-input-port interaction)
      "Return INTERACTION's shared program-input port, or #f when disconnected."
      #((parameters
         (interaction (type consent-interaction-context)
          (description ("Interaction context whose shared stdin port is read."))))
        (returns (type (or port boolean))
         (description
          ("The shared program-input port, or #f when program input is"
            "not connected.")))
        (effects state-read))
      (interaction-context-program-input-port interaction))

    (define (consent-interaction-seed-program-input! interaction text)
      "Seed the shared program-input cursor with TEXT (the post-form"
      "remainder) at position 0, so an evaluated read consumes the input"
      "that follows the just-read submission.  A no-op when program input is"
      "not connected.  The end-of-stream flag is left untouched: once the"
      "host stream truly ends, both form and program reads are at end."
      #((parameters
         (interaction (type consent-interaction-context)
          (description ("Interaction context holding the shared stdin cursor.")))
         (text (type string)
          (description "Post-form remainder string to seed at position 0.")))
        (returns
         . ("An unspecified value; called for its effect on the shared"
            "cursor."))
        (effects state-read state-write))
      (let ((port (interaction-context-program-input-port interaction)))
        (if port
            (begin
              (set-consent-port-source! port text)
              (set-consent-port-position! port 0)))))

    (define (consent-interaction-program-input-remainder interaction)
      "Return the shared program-input cursor's unconsumed remainder (the"
      "input the evaluated form did not read), or #f when program input is"
      "not connected.  The REPL engine threads this back as the next"
      "form-reading buffer, so neither reader steals the other's characters."
      #((parameters
         (interaction (type consent-interaction-context)
          (description ("Interaction context holding the shared stdin cursor."))))
        (returns (type (or string boolean))
         (description
          ("The unconsumed remainder string after the port position,"
            "or #f when disconnected.")))
        (effects state-read allocation))
      (let ((port (interaction-context-program-input-port interaction)))
        (and port
             (substring (consent-port-source port)
                        (consent-port-position port)
                        (string-length (consent-port-source port))))))

    (define (consent-interaction-context-session-id interaction)
      "Return the session id INTERACTION evaluates under, or #f when unsessioned."
      #((parameters
         (interaction (type consent-interaction-context)
          (description ("Interaction context whose options carry the session id."))))
        (returns
         . ("The configured session id, or #f when the context is"
            "unsessioned."))
        (effects state-read))
      (interaction-context-session-id-from-options
       (interaction-context-options interaction)))

    (define (consent-interaction-program-output interaction)
      "Return the program output the most recent"
      "`consent-interaction-eval-form' submission wrote, cleared before each"
      "evaluation."
      #((parameters
         (interaction (type consent-interaction-context)
          (description ("Interaction context whose program-output port is read."))))
        (returns (type string)
         (description
          ("The string written to program output by the most recent"
            "submission.")))
        (effects state-read))
      (consent-port-contents
       (interaction-context-program-output-port interaction)))

    (define (consent-interaction-eval-form interaction form)
      "Evaluate one already-read top-level FORM in durable INTERACTION, reusing"
      "its value/syntax environments and program-output port, and return an"
      "`evaluation-result' datum (ok/values or captured error) like"
      "`consent-eval-source-result'."
      #((parameters
         (interaction (type consent-interaction-context)
          (description
           ("Durable interaction context supplying persistent"
             "environments and ports.")))
         (form . "Already-read top-level datum to evaluate."))
        (returns (type evaluation-result)
         (description
          ("An `evaluation-result' datum capturing the value or the"
            "raised condition.")))
        (effects host-eval state-read state-write))
      (let* ((options (interaction-context-options interaction))
             (environment (interaction-context-environment interaction))
             (syntax-environment
              (interaction-context-syntax-environment interaction))
             (program-output-port
              (interaction-context-program-output-port interaction))
             (program-input-port
              (interaction-context-program-input-port interaction))
             (context (new-eval-context options)))
        (set-consent-port-contents! program-output-port "")
        (set-context-syntax-environment! context syntax-environment)
        (set-context-interaction-environment! context environment)
        (set-context-current-output-port! context program-output-port)
        (if program-input-port
            (set-context-current-input-port! context program-input-port))
        (call-with-result-condition-handler
         context
         (lambda ()
           (ok-result-datum
            (trampoline (make-sequence (list form) #t) environment context)
            context)))))

    ))
