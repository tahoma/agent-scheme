;;; Portable R7RS evaluator kernel for Agent Scheme.
;;;
;;; This library mirrors the Emacs Lisp bootstrap evaluator in portable Scheme.
;;; It keeps runtime state as Scheme-readable records, uses explicit lexical
;;; and syntactic environments, and preserves tail calls with an explicit
;;; trampoline instead of delegating evaluation to the host implementation.

(define-library (agent-scheme eval)
  (export agent-scheme-eval
          agent-scheme-eval-source
          agent-scheme-eval-string
          agent-scheme-expand
          agent-scheme-expand-source
          agent-scheme-eval-result
          agent-scheme-eval-source-result
          agent-scheme-make-empty-environment
          agent-scheme-make-base-environment
          agent-scheme-base-primitive-names
          agent-scheme-base-primitive-specs
          agent-scheme-base-prelude-binding-names
          agent-scheme-base-prelude-binding-specs
          agent-scheme-base-binding-specs
          agent-scheme-standard-source-library-specs
          agent-scheme-primitive-manifest-binding-specs
          agent-scheme-result->external
          agent-scheme-value->external
          agent-scheme-unspecified
          agent-scheme-unspecified?
          agent-scheme-procedure?
          agent-scheme-primitive-procedure?)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme inexact)
          (agent-scheme reader)
          (agent-scheme runtime)
          (agent-scheme result))
  (begin
    ;; Return the stack prefix before FRAME in dynamic-wind order.
    (define (dynamic-wind-prefix-before frame stack)
      (let loop ((cursor stack) (prefix '()))
        (cond
         ((null? cursor) (reverse prefix))
         ((eq? (car cursor) frame) (reverse prefix))
         (else (loop (cdr cursor) (cons (car cursor) prefix))))))

    ;; Find the outermost shared frame between dynamic-wind stacks.
    (define (dynamic-wind-common-frame current target)
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

    ;; Call PROCEDURE for dynamic control effects and discard its values.
    (define (call-ignoring-values procedure context description)
      (expect-procedure procedure description)
      (apply-procedure procedure '() context #f)
      agent-scheme-unspecified)

    ;; Continuation-aware variant of call-ignoring-values.
    (define (call-ignoring-values/k
             procedure context description continuation)
      (expect-procedure procedure description)
      (apply-procedure
       procedure
       '()
       context
       #t
       (lambda (value)
         (continue continuation agent-scheme-unspecified))))

    ;; Continuation jumps call each after thunk being exited and each before
    ;; thunk being entered, updating the active stack as those callbacks run.
    (define (switch-dynamic-winds! target context)
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

    ;; Report whether EXPRESSION evaluates to itself in core evaluation.
    (define (self-evaluating? expression)
      (or (boolean? expression)
          (agent-scheme-number? expression)
          (char? expression)
          (string? expression)
          (vector? expression)
          (bytevector? expression)))

    ;; Implement Scheme truthiness, where only #f is false.
    (define (true-value? value)
      (not (eq? value #f)))

    ;; Report whether FORM is a core define form headed by the raw symbol.
    (define (definition-form? form)
      (and (pair? form) (eq? (car form) 'define)))

    ;; Report whether FORM is a define-values form after identifier unwrapping.
    (define (define-values-form? form)
      (and (pair? form) (identifier-named? (car form) 'define-values)))

    ;; Report whether FORM is a core begin form headed by the raw symbol.
    (define (begin-form? form)
      (and (pair? form) (eq? (car form) 'begin)))

    ;; Construct the lambda expression used by function-definition shorthand.
    (define (make-lambda-expression formals body)
      (cons 'lambda (cons formals body)))

    ;; Parse variable or procedure define syntax into a name/expression pair.
    (define (parse-definition form)
      (let ((parts (proper-list-elements form "define form")))
        (if (< (length parts) 3)
            (eval-error "define requires a target and a value" form))
        (let ((target (second parts))
              (body (cddr parts)))
          (cond
           ((symbol? target)
            (if (not (= (length body) 1))
                (eval-error
                 "variable define requires exactly one expression"
                 form))
            (cons (identifier-key target) (car body)))
           ((identifier? target)
            (if (not (= (length body) 1))
                (eval-error
                 "variable define requires exactly one expression"
                 form))
            (cons (identifier-key target) (car body)))
           ((pair? target)
            (let ((name (expect-identifier-key
                         (car target)
                         "function define name")))
              (if (null? body)
                  (eval-error "function define requires a body" form))
              (cons name (make-lambda-expression (cdr target) body))))
           (else
            (eval-error
             "define target must be an identifier or function signature"
             form))))))

    ;; Parse define-values syntax into formals metadata and an initializer.
    (define (parse-define-values form)
      (let ((parts (proper-list-elements form "define-values form")))
        (if (not (= (length parts) 3))
            (eval-error
             "define-values requires formals and one expression"
             form))
        (cons (parse-formals (second parts)) (third parts))))

    ;; Return every name bound by a define-values form.
    (define (define-values-bound-names form)
      (formals-names (car (parse-define-values form))))

    ;; Report whether FORM is a define-record-type form.
    (define (record-definition-form? form)
      (and (pair? form) (identifier-named? (car form) 'define-record-type)))

    ;; Report whether FORM is any definition accepted at body start.
    (define (body-definition-form? form)
      (or (definition-form? form)
          (define-values-form? form)
          (record-definition-form? form)))

    ;; Parse define-record-type syntax into constructor, predicate, and field
    ;; specs.
    (define (parse-record-definition form)
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

    ;; Return every binding introduced by a define-record-type form.
    (define (record-definition-bound-names form)
      (let ((spec (parse-record-definition form)))
        (append
         (list (second (assq 'type-name spec))
               (second (assq 'constructor-name spec))
               (second (assq 'predicate-name spec)))
         (map car (second (assq 'accessors spec)))
         (map car (second (assq 'mutators spec))))))

    ;; Return FIELD's zero-based index in RECORD-TYPE, or raise on mismatch.
    (define (record-field-index record-type field)
      (let loop ((rest (agent-scheme-record-type-fields record-type))
                 (index 0))
        (cond
         ((null? rest)
          (eval-error "record type does not contain field" field))
         ((eq? (car rest) field) index)
         (else (loop (cdr rest) (+ index 1))))))

    ;; Validate record of type input and raise an evaluator error on mismatch.
    (define (expect-record-of-type value record-type description)
      (if (not (and (agent-scheme-record? value)
                    (eq? (agent-scheme-record-type value) record-type)))
          (eval-error
           (string-append (symbol->string description) " expected record")
           value))
      value)

    ;; Install or update a record-related binding while preserving import
    ;; protection.
    (define (define-or-set-record-binding! environment name value)
      (let ((cell (frame-cell environment name)))
        (if cell
            (begin
              (if (environment-cell-imported? environment cell)
                  (eval-error "cannot redefine imported binding" name))
              (set-cell-value! cell value))
            (environment-define! environment name value))))

    ;; Install a record type plus generated constructor, predicate, and field
    ;; procedures.
    (define (eval-record-definition form environment context)
      (let* ((spec (parse-record-definition form))
             (type-name (second (assq 'type-name spec)))
             (fields (second (assq 'fields spec)))
             (record-type (agent-scheme-make-record-type type-name fields))
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
                                agent-scheme-unspecified)))
                   (let loop ((rest-fields constructor-fields)
                              (rest-arguments arguments))
                     (if (null? rest-fields)
                         (agent-scheme-make-record record-type values)
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
                 (and (agent-scheme-record? (car arguments))
                      (eq? (agent-scheme-record-type (car arguments))
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
                  (agent-scheme-record-fields
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
                  (agent-scheme-record-fields
                   (expect-record-of-type
                    (car arguments)
                    record-type
                    name))
                  index
                  (second arguments))
                 agent-scheme-unspecified)
               2
               2))))
         (second (assq 'mutators spec)))
        agent-scheme-unspecified))

    ;; Split a body into leading internal definitions and remaining expressions.
    (define (split-body body)
      (let loop ((cursor body) (definitions '()))
        (cond
         ((and (pair? cursor) (body-definition-form? (car cursor)))
          (loop (cdr cursor) (cons (car cursor) definitions)))
         ((null? cursor)
          (eval-error "body must contain at least one expression" body))
         (else
          (cons (reverse definitions) cursor)))))

    ;; Allocate and initialize an internal-definition environment for BODY.
    (define (prepare-body-environment body environment context)
      (let* ((split (split-body body))
             (definitions (car split))
             (expressions (cdr split)))
        (if (null? definitions)
            (cons environment expressions)
            (let ((body-environment
                   (agent-scheme-make-empty-environment environment)))
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

    ;; Evaluate a define form and install the resulting single value.
    (define (eval-definition form environment context . maybe-continuation)
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
                   (continue continuation agent-scheme-unspecified))))))
        (if direct-call?
            (drain-state state context)
            state)))

    ;; Bind multiple values to define-values formals in ENVIRONMENT.
    (define (define-values-bind
             formals values environment context description)
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

    ;; Evaluate a define-values form and install all returned values.
    (define (eval-define-values
             form environment context . maybe-continuation)
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
                 (continue continuation agent-scheme-unspecified)))))
        (if direct-call?
            (drain-state state context)
            state)))

    ;; Create a call environment and bind FORMALS to ARGUMENTS.
    (define (bind-formals formals arguments closure-environment context)
      (let ((environment
             (agent-scheme-make-empty-environment closure-environment)))
        (bind-formals-in-environment
         formals arguments environment context "procedure")
        environment))

    ;; Bind FORMALS to ARGUMENTS inside an existing call environment.
    (define (bind-formals-in-environment
             formals arguments environment context description)
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
                      (check-value-budget values context)))
                environment)
              (begin
                (environment-define! environment
                                     (car names)
                                     (car values))
                (loop (cdr names) (cdr values)))))))

    ;; Return every symbol named by parsed FORMALS.
    (define (formals-names formals)
      (if (formals-rest formals)
          (append (formals-required formals) (list (formals-rest formals)))
          (formals-required formals)))

    ;; Report whether COUNT satisfies PRIMITIVE's arity bounds.
    (define (arity-match? primitive count)
      (and (>= count (primitive-procedure-minimum-arity primitive))
           (let ((maximum (primitive-procedure-maximum-arity primitive)))
             (or (not maximum) (<= count maximum)))))

    ;; All callable values pass through this boundary so primitive callbacks,
    ;; parameter procedures, compound procedures, and continuations share arity,
    ;; budget, tail-position, and trampoline behavior.
    (define (apply-procedure procedure arguments context tail? . maybe-continuation)
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
         ((agent-scheme-primitive-procedure? procedure)
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
               (continue
                continuation
                (check-value-budget
                 (function arguments context)
                 context)))))))
         ((agent-scheme-parameter? procedure)
          (finish
           (apply-parameter/k procedure arguments context continuation)))
         ((agent-scheme-procedure? procedure)
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
                 (body-expression (make-sequence (cdr body-state) #f)))
            (finish
             (make-bounce body-expression
                          (car body-state)
                          (context-syntax-environment context)
                          continuation))))
         ((continuation? procedure)
          (finish
           (invoke-continuation procedure arguments context)))
         (else
          (eval-error "attempted to call non-procedure"
                      (agent-scheme-value->external procedure))))))

    ;; Evaluate an if form, preserving tail position for selected branches.
    (define (eval-if parts environment context tail? continuation)
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
             (continue continuation agent-scheme-unspecified)))))))

    ;; Evaluate a set! form and mutate the target identifier binding.
    (define (eval-set! parts environment context continuation)
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
             (continue continuation agent-scheme-unspecified))))))

    ;; Report whether DATUM is a pair headed by identifier TAG.
    (define (tagged-list? datum tag)
      (and (pair? datum)
           (identifier-named? (car datum) tag)))

    ;; Return the sole operand from FORM or raise a syntax error.
    (define (single-argument-syntax form description)
      (let ((parts (proper-list-elements form description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description " requires exactly one operand")
             form))
        (second parts)))

    ;; Report whether FORM is a syntax-error expansion result.
    (define (syntax-error-form? form)
      (tagged-list? form 'syntax-error))

    ;; Render syntax-error operands into one diagnostic message.
    (define (syntax-error-message form)
      (let ((parts (proper-list-elements form "syntax-error form")))
        (let loop ((rest (cdr parts)) (message ""))
          (cond
           ((null? rest) message)
           ((string=? message "")
            (loop (cdr rest) (agent-scheme-value->external (car rest))))
           (else
            (loop (cdr rest)
                  (string-append
                   message
                   " "
                   (agent-scheme-value->external (car rest)))))))))

    ;; Raise the diagnostic represented by a syntax-error form.
    (define (raise-syntax-error form . maybe-source-form)
      (let ((message (syntax-error-message form)))
        (if (null? maybe-source-form)
            (eval-error (string-append "syntax-error: " message))
            (eval-error
             (string-append
              "syntax-error while expanding "
              (agent-scheme-value->external (car maybe-source-form))
              ": "
              message)))))

    ;; Evaluate a quasiquote list template, including depth-aware splicing.
    (define (eval-quasiquote-list template depth environment context)
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

    ;; Evaluate one quasiquote template with nested quasiquote depth tracking.
    (define (eval-quasiquote-template template depth environment context)
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

    ;; Evaluate a quasiquote form after validating its single template operand.
    (define (eval-quasiquote parts environment context)
      (if (not (= (length parts) 2))
          (eval-error "quasiquote requires exactly one template" parts))
      (eval-quasiquote-template (second parts) 1 environment context))

    ;; Parse one letrec or letrec* binding into a name/expression pair.
    (define (parse-letrec-binding binding description)
      (let ((parts (proper-list-elements binding description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description
                            " binding must contain an identifier and initializer")
             binding))
        (cons (expect-identifier-key (car parts) description)
              (second parts))))

    ;; Evaluate letrec or letrec* with preallocated recursive binding cells.
    (define (eval-letrec
             parts environment context tail? sequential? . maybe-continuation)
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
              (agent-scheme-make-empty-environment environment)))
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

    ;; Parse one let-values binding into formals metadata and initializer.
    (define (parse-mv-binding binding description)
      (let ((parts (proper-list-elements binding description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description
                            " binding must contain formals and initializer")
             binding))
        (cons (parse-formals (car parts))
              (second parts))))

    ;; Evaluate let-values or let*-values with parallel or sequential binding.
    (define (eval-let-values
             parts environment context tail? sequential? . maybe-continuation)
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
              (agent-scheme-make-empty-environment environment))
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

    ;; Construct an empty syntax environment with an optional parent.
    (define (make-empty-syntax-environment parent)
      (make-syntax-environment '() parent '()))

    ;; Return NAME's syntax transformer by walking syntax-environment parents.
    (define (syntax-environment-ref syntax-environment name)
      (let loop ((cursor syntax-environment))
        (cond
         ((not cursor) #f)
         ((assq name (syntax-environment-frame cursor))
          => (lambda (cell) (cdr cell)))
         (else (loop (syntax-environment-parent cursor))))))

    ;; Add a syntax binding unless NAME is imported into this syntax frame.
    (define (syntax-environment-define! syntax-environment name transformer)
      (if (memq name (syntax-environment-imported-names syntax-environment))
          (eval-error "cannot redefine imported syntax binding" name))
      (set-syntax-environment-frame!
       syntax-environment
       (cons (cons name transformer)
             (syntax-environment-frame syntax-environment))))

    ;; Run THUNK with CONTEXT temporarily using SYNTAX-ENVIRONMENT.
    (define (with-syntax-environment context syntax-environment thunk)
      (let ((old-syntax-environment (context-syntax-environment context)))
        (set-context-syntax-environment! context syntax-environment)
        (let ((value (thunk)))
          (set-context-syntax-environment! context old-syntax-environment)
          value)))

    ;; Report whether OPERATOR is shadowed by a value binding.
    (define (operator-shadowed? operator environment)
      (and (symbol? operator) (environment-cell environment operator)))

    ;; Report whether OPERATOR can still dispatch as syntax in ENVIRONMENT.
    (define (special-operator-active? operator environment)
      (and (identifier-datum? operator)
           (or (identifier? operator)
               (not (operator-shadowed? operator environment)))))

    ;; Resolve OPERATOR to its active syntax transformer, respecting hygiene.
    (define (syntax-binding-for-operator operator environment context)
      ;; Macro-introduced operators consult their definition-time syntax
      ;; environment.  Plain symbols use the active syntax environment unless a
      ;; value binding shadows the syntactic keyword.
      (let ((name (identifier-datum-name operator)))
        (if (and name (not (operator-shadowed? operator environment)))
            (or
             (and (identifier? operator)
                  (let* ((identifier-context (identifier-context operator))
                         (definition-syntax-environment
                          (and identifier-context
                               (syntax-context-syntax-environment
                                identifier-context))))
                    (and definition-syntax-environment
                         (syntax-environment-ref
                          definition-syntax-environment
                          name))))
             (syntax-environment-ref
              (context-syntax-environment context)
              name))
            #f)))

    ;; Report whether DATUM names the active syntax-rules ellipsis identifier.
    (define (ellipsis-identifier? datum ellipsis)
      (and (identifier-datum? datum)
           (eq? (identifier-datum-name datum) ellipsis)))

    ;; Return DATUM's list elements, or #f when DATUM is not a proper list.
    (define (proper-list-elements/maybe datum)
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else #f))))

    ;; Report whether FORM is a syntax-rules transformer spec.
    (define (syntax-rules-spec? form)
      (and (pair? form) (identifier-named? (car form) 'syntax-rules)))

    ;; Parse one syntax-rules rule into pattern and template.
    (define (parse-syntax-rule rule)
      (let ((parts (proper-list-elements rule "syntax-rules rule")))
        (if (not (= (length parts) 2))
            (eval-error
             "syntax-rules rule must contain a pattern and a template"
             rule))
        (let ((pattern (car parts)))
          (if (not (and (pair? pattern)
                        (identifier-datum? (car pattern))))
              (eval-error
               "syntax-rules pattern must be a list beginning with an identifier"
               pattern))
          (cons pattern (second parts)))))

    ;; Parse a syntax-rules transformer, including optional custom ellipsis.
    (define (parse-syntax-rules form value-environment syntax-environment)
      (if (not (syntax-rules-spec? form))
          (eval-error "transformer spec must be a syntax-rules form" form))
      (let* ((parts (proper-list-elements form "syntax-rules form"))
             (tail (cdr parts)))
        (if (< (length tail) 2)
            (eval-error
             "syntax-rules requires literals and at least one rule"
             form))
        (let* ((custom-ellipsis?
                (and (identifier-datum? (car tail))
                     (pair? (cdr tail))))
               (ellipsis (if custom-ellipsis?
                             (expect-symbol (car tail)
                                            "syntax-rules ellipsis")
                             '...))
               (literal-form (if custom-ellipsis?
                                 (second tail)
                                 (car tail)))
               (rule-forms (if custom-ellipsis?
                               (cddr tail)
                               (cdr tail)))
               (literals
                (map (lambda (literal)
                       (if (not (identifier-datum? literal))
                           (eval-error
                            "syntax-rules literal must be an identifier"
                            literal))
                       literal)
                     (proper-list-elements
                      literal-form
                      "syntax-rules literal list"))))
          (make-syntax-transformer
           ellipsis
           literals
           (map parse-syntax-rule rule-forms)
           value-environment
           syntax-environment))))

    ;; Report whether IDENTIFIER names one of the syntax-rules literals.
    (define (syntax-literal? identifier literals)
      (let ((name (identifier-datum-name identifier)))
        (let loop ((rest literals))
          (cond
           ((null? rest) #f)
           ((eq? name (identifier-datum-name (car rest))) #t)
           (else (loop (cdr rest)))))))

    ;; Create the mutable capture table used while matching one macro rule.
    (define (make-pattern-bindings)
      (list 'bindings))

    ;; Return the capture-table cell for pattern variable NAME, or #f.
    (define (pattern-binding-cell bindings name)
      (assoc name (cdr bindings)))

    ;; Return the pattern binding entry for NAME, or #f.
    (define (pattern-binding bindings name)
      (let ((cell (pattern-binding-cell bindings name)))
        (if cell (cdr cell) #f)))

    ;; Add ENTRY for pattern variable NAME to the capture table.
    (define (add-pattern-binding! bindings name entry)
      (set-cdr! bindings (cons (cons name entry) (cdr bindings))))

    ;; Report whether PREFIX is an initial segment of repetition PATH.
    (define (path-prefix? prefix path)
      (cond
       ((null? prefix) #t)
       ((null? path) #f)
       ((= (car prefix) (car path))
        (path-prefix? (cdr prefix) (cdr path)))
       (else #f)))

    ;; Return the capture stored for PATH, or #f when none exists.
    (define (capture-ref captures path)
      (let ((cell (assoc path captures)))
        (if cell (cdr cell) #f)))

    ;; Return NAME's capture entry, creating it with DEPTH when needed.
    (define (ensure-pattern-binding! bindings name depth)
      (let ((entry (pattern-binding bindings name)))
        (cond
         ((not entry)
          (let ((new-entry (make-pattern-binding depth '() '())))
            (add-pattern-binding! bindings name new-entry)
            new-entry))
         ((and (not (null? (pattern-binding-captures entry)))
               (not (= (pattern-binding-depth entry) depth)))
          (eval-error
           "pattern variable used at inconsistent ellipsis depth"
           name))
         (else
          (if (< (pattern-binding-depth entry) depth)
              (set-pattern-binding-depth! entry depth))
          entry))))

    ;; Record VALUE as NAME's capture at the current ellipsis PATH.
    (define (syntax-bind-pattern-variable! bindings name value path)
      (let* ((entry (ensure-pattern-binding! bindings name (length path)))
             (captures (pattern-binding-captures entry)))
        (if (assoc path captures)
            (eval-error "duplicate pattern variable" name))
        ;; PATH is the repetition-index trail leading to this capture.
        ;; Template expansion reuses it to distribute nested ellipses.
        (set-pattern-binding-captures!
         entry
         (cons (cons path value) captures)))
      #t)

    ;; Split DATUM into list elements and the final tail value.
    (define (list-elements-tail datum)
      (let loop ((cursor datum) (elements '()))
        (if (pair? cursor)
            (loop (cdr cursor) (cons (car cursor) elements))
            (cons (reverse elements) cursor))))

    ;; Append ELEMENTS in front of TAIL without requiring TAIL to be a list.
    (define (append-tail elements tail)
      (if (null? elements)
          tail
          (cons (car elements) (append-tail (cdr elements) tail))))

    ;; Return every pattern variable name introduced by PATTERN.
    (define (pattern-variable-names pattern literals ellipsis)
      (cond
       ((identifier-datum? pattern)
        (let ((name (identifier-datum-name pattern)))
          (if (or (eq? name '_)
                  (eq? name ellipsis)
                  (syntax-literal? pattern literals))
              '()
              (list name))))
       ((pair? pattern)
        (let* ((pieces (list-elements-tail pattern))
               (names
                (apply append
                       (map (lambda (element)
                              (pattern-variable-names
                               element literals ellipsis))
                            (car pieces)))))
          (if (cdr pieces)
              (append names
                      (pattern-variable-names
                       (cdr pieces) literals ellipsis))
              names)))
       ((vector? pattern)
        (apply append
               (map (lambda (element)
                      (pattern-variable-names element literals ellipsis))
                    (vector->list pattern))))
       (else '())))

    ;; Mark repeated variables under PATTERN as captured zero times at PATH.
    (define (bind-empty-repeated-pattern-variables!
             pattern literals ellipsis bindings path)
      (for-each
       (lambda (name)
         (let ((entry
                (ensure-pattern-binding! bindings name (+ (length path) 1))))
           (if (not (member path (pattern-binding-empty-prefixes entry)))
               (set-pattern-binding-empty-prefixes!
                entry
                (cons path (pattern-binding-empty-prefixes entry))))))
       (pattern-variable-names pattern literals ellipsis)))

    ;; Return the first COUNT elements of LIST.
    (define (list-take list count)
      (let loop ((rest list) (remaining count) (result '()))
        (if (= remaining 0)
            (reverse result)
            (loop (cdr rest) (- remaining 1) (cons (car rest) result)))))

    ;; Return LIST after skipping COUNT elements.
    (define (list-drop list count)
      (if (= count 0)
          list
          (list-drop (cdr list) (- count 1))))

    ;; Return the last COUNT elements of LIST.
    (define (list-last-n list count)
      (list-drop list (- (length list) count)))

    ;; Resolve IDENTIFIER's syntax binding in a given syntax environment.
    (define (identifier-syntax-binding-in identifier syntax-environment)
      (let ((name (identifier-datum-name identifier)))
        (and name
             (or
              (and (identifier? identifier)
                   (let* ((identifier-context (identifier-context identifier))
                          (definition-syntax-environment
                           (and identifier-context
                                (syntax-context-syntax-environment
                                 identifier-context))))
                     (and definition-syntax-environment
                          (syntax-environment-ref
                           definition-syntax-environment
                           name))))
              (and syntax-environment
                   (syntax-environment-ref syntax-environment name))))))

    ;; Return the value or syntax token used for literal-identifier comparison.
    (define (identifier-binding-token identifier value-environment
                                      syntax-environment)
      (let ((cell
             (and value-environment
                  (environment-cell-for-identifier
                   value-environment identifier)))
            (syntax-binding
             (identifier-syntax-binding-in identifier syntax-environment)))
        (cond
         (cell (cons 'value cell))
         (syntax-binding (cons 'syntax syntax-binding))
         (else #f))))

    ;; Report whether two literal-identifier binding tokens denote the same
    ;; binding.
    (define (binding-tokens-equal? left right)
      (cond
       ((and (not left) (not right)) #t)
       ((and left right
             (eq? (car left) (car right))
             (eq? (cdr left) (cdr right)))
        #t)
       (else #f)))

    ;; Report whether a syntax-rules literal matches by name and binding.
    (define (literal-identifier-match? pattern input transformer
                                       use-environment use-syntax-environment)
      (and (identifier-datum? input)
           (eq? (identifier-datum-name pattern)
                (identifier-datum-name input))
           (binding-tokens-equal?
            (identifier-binding-token
             pattern
             (syntax-transformer-value-environment transformer)
             (syntax-transformer-syntax-environment transformer))
            (identifier-binding-token
             input use-environment use-syntax-environment))))

    ;; Match one syntax-rules pattern node and record pattern captures.
    (define (match-pattern pattern input transformer bindings path
                           use-environment use-syntax-environment)
      (let ((literals (syntax-transformer-literals transformer))
            (ellipsis (syntax-transformer-ellipsis transformer)))
        (cond
         ((identifier-datum? pattern)
          (let ((name (identifier-datum-name pattern)))
            (cond
             ((and (eq? name '_) (not (syntax-literal? pattern literals)))
              #t)
             ((syntax-literal? pattern literals)
              (literal-identifier-match?
               pattern input transformer use-environment
               use-syntax-environment))
             ((eq? name ellipsis)
              (and (identifier-datum? input)
                   (eq? name (identifier-datum-name input))))
             (else
              (syntax-bind-pattern-variable!
               bindings name input path)))))
         ((pair? pattern)
          (and (pair? input)
               (let ((pattern-pieces (list-elements-tail pattern))
                     (input-pieces (list-elements-tail input)))
                 (match-pattern-elements
                  (car pattern-pieces)
                  (cdr pattern-pieces)
                  (car input-pieces)
                  (cdr input-pieces)
                  transformer
                  bindings
                  path
                  use-environment
                  use-syntax-environment))))
         ((vector? pattern)
          (and (vector? input)
               (match-pattern-elements
                (vector->list pattern)
                '()
                (vector->list input)
                '()
                transformer
                bindings
                path
                use-environment
                use-syntax-environment)))
         (else
          (equal? pattern input)))))

    ;; Return the index of the ellipsis marker in PATTERNS, or #f.
    (define (find-ellipsis-index patterns ellipsis)
      (if (null? patterns)
          #f
          (let loop ((rest (cdr patterns)) (index 1))
            (cond
             ((null? rest) #f)
             ((ellipsis-identifier? (car rest) ellipsis) index)
             (else (loop (cdr rest) (+ index 1)))))))

    ;; Match fixed pattern and input element lists from left to right.
    (define (match-pattern-list patterns inputs transformer bindings path
                                use-environment use-syntax-environment)
      (cond
       ((null? patterns) #t)
       ((null? inputs) #f)
       ((match-pattern (car patterns)
                       (car inputs)
                       transformer
                       bindings
                       path
                       use-environment
                       use-syntax-environment)
        (match-pattern-list (cdr patterns)
                            (cdr inputs)
                            transformer
                            bindings
                            path
                            use-environment
                            use-syntax-environment))
       (else #f)))

    ;; Return PATH extended with one repetition INDEX.
    (define (path-add-index path index)
      (append path (list index)))

    ;; Match list/vector pattern elements, including one ellipsis repetition.
    (define (match-pattern-elements patterns pattern-tail input-elements
                                    input-tail transformer bindings path
                                    use-environment use-syntax-environment)
      (let* ((ellipsis (syntax-transformer-ellipsis transformer))
             (ellipsis-index (find-ellipsis-index patterns ellipsis)))
        (if ellipsis-index
            ;; R7RS ellipses repeat the pattern immediately before the
            ;; ellipsis.  Prefix and suffix patterns remain fixed while PATH
            ;; tracks each repeated match.
            (let* ((prefix-count (- ellipsis-index 1))
                   (suffix (list-drop patterns (+ ellipsis-index 1)))
                   (suffix-count (length suffix))
                   (repeat-pattern (list-ref patterns (- ellipsis-index 1)))
                   (repeat-count (- (length input-elements)
                                    prefix-count
                                    suffix-count)))
              (and (>= repeat-count 0)
                   (match-pattern-list
                    (list-take patterns prefix-count)
                    (list-take input-elements prefix-count)
                    transformer
                    bindings
                    path
                    use-environment
                    use-syntax-environment)
                   (let repeat-loop
                       ((rest (list-take
                               (list-drop input-elements prefix-count)
                               repeat-count))
                        (index 0))
                     (if (null? rest)
                         (begin
                           (if (= repeat-count 0)
                               (bind-empty-repeated-pattern-variables!
                                repeat-pattern
                                (syntax-transformer-literals transformer)
                                ellipsis
                                bindings
                                path))
                           #t)
                         (and
                          (match-pattern repeat-pattern
                                         (car rest)
                                         transformer
                                         bindings
                                         (path-add-index path index)
                                         use-environment
                                         use-syntax-environment)
                          (repeat-loop (cdr rest) (+ index 1)))))
                   (match-pattern-list
                    suffix
                    (if (> suffix-count 0)
                        (list-last-n input-elements suffix-count)
                        '())
                    transformer
                    bindings
                    path
                    use-environment
                    use-syntax-environment)
                   (if pattern-tail
                       (match-pattern pattern-tail
                                      input-tail
                                      transformer
                                      bindings
                                      path
                                      use-environment
                                      use-syntax-environment)
                       (null? input-tail))))
            (and (>= (length input-elements) (length patterns))
                 (match-pattern-list
                  patterns
                  (list-take input-elements (length patterns))
                  transformer
                  bindings
                  path
                  use-environment
                  use-syntax-environment)
                 (let ((remaining
                        (list-drop input-elements (length patterns))))
                   (if pattern-tail
                       (match-pattern pattern-tail
                                      (append-tail remaining input-tail)
                                      transformer
                                      bindings
                                      path
                                      use-environment
                                      use-syntax-environment)
                       (and (null? remaining) (null? input-tail))))))))

    ;; Try one syntax-rules rule against FORM and fill BINDINGS on success.
    (define (match-syntax-rule rule form transformer bindings
                               use-environment use-syntax-environment)
      (let* ((pattern-pieces (list-elements-tail (car rule)))
             (input-pieces (list-elements-tail form))
             (pattern-elements (car pattern-pieces))
             (input-elements (car input-pieces)))
        (and (not (null? pattern-elements))
             input-elements
             (null? (cdr input-pieces))
             (match-pattern-elements
              (cdr pattern-elements)
              (cdr pattern-pieces)
              (cdr input-elements)
              '()
              transformer
              bindings
              '()
              use-environment
              use-syntax-environment))))

    ;; Return captured pattern variables referenced by a template fragment.
    (define (template-pattern-variable-names template bindings ellipsis)
      (cond
       ((identifier-datum? template)
        (let ((name (identifier-datum-name template)))
          (if (and (not (eq? name ellipsis))
                   (pattern-binding bindings name))
              (list name)
              '())))
       ((pair? template)
        (let* ((pieces (list-elements-tail template))
               (names
                (apply append
                       (map (lambda (element)
                              (template-pattern-variable-names
                               element bindings ellipsis))
                            (car pieces)))))
          (if (null? (cdr pieces))
              names
              (append names
                      (template-pattern-variable-names
                       (cdr pieces) bindings ellipsis)))))
       ((vector? template)
        (apply append
               (map (lambda (element)
                      (template-pattern-variable-names
                       element bindings ellipsis))
                    (vector->list template))))
       (else '())))

    ;; Return the greatest number in a nonempty list.
    (define (max-number-list numbers)
      (let loop ((rest (cdr numbers)) (best (car numbers)))
        (if (null? rest)
            best
            (loop (cdr rest)
                  (if (> (car rest) best) (car rest) best)))))

    ;; Return distinct repetition indices immediately under PATH.
    (define (collect-next-indices paths path)
      (let ((path-length (length path)))
        (let loop ((rest paths) (indices '()))
          (cond
           ((null? rest) indices)
           ((and (> (length (car rest)) path-length)
                 (path-prefix? path (car rest)))
            (let ((index (list-ref (car rest) path-length)))
              (loop (cdr rest)
                    (if (memv index indices)
                        indices
                        (cons index indices)))))
           (else
            (loop (cdr rest) indices))))))

    ;; Return how many repetitions ENTRY has below PATH, if knowable.
    (define (pattern-binding-repeat-count-at entry path)
      (if (<= (pattern-binding-depth entry) (length path))
          #f
          (let* ((capture-paths (map car (pattern-binding-captures entry)))
                 (empty-prefixes (pattern-binding-empty-prefixes entry))
                 (indices
                  (collect-next-indices
                   (append capture-paths empty-prefixes)
                   path)))
            (cond
             ((not (null? indices))
              (+ (max-number-list indices) 1))
             ((member path empty-prefixes) 0)
             (else #f)))))

    ;; Determine the repetition count required for a template ellipsis.
    (define (template-repeat-count template bindings ellipsis path)
      (let loop ((names (template-pattern-variable-names
                         template bindings ellipsis))
                 (count #f))
        (cond
         ((null? names)
          (if count
              count
              (eval-error
               "template ellipsis must contain a repeated pattern variable")))
         (else
          (let* ((entry (pattern-binding bindings (car names)))
                 (entry-count
                  (and entry
                       (pattern-binding-repeat-count-at entry path))))
            (if entry-count
                (if (and count (not (= count entry-count)))
                      (eval-error
                       "template ellipsis variables have different lengths")
                      (loop (cdr names) entry-count))
                (loop (cdr names) count)))))))

    ;; Return NAME's captured value at PATH, enforcing ellipsis depth.
    (define (pattern-binding-value-at entry name path)
      (let* ((depth (pattern-binding-depth entry))
             (capture-path
              (if (<= depth (length path))
                  (list-take path depth)
                  (eval-error
                   "repeated pattern variable used without enough ellipses"
                   name)))
             (cell (assoc capture-path (pattern-binding-captures entry))))
        (if cell
            (cdr cell)
            (eval-error "missing pattern variable capture" name))))

    ;; Expand a syntax-rules template using captured pattern bindings.
    (define (expand-template template bindings syntax-context ellipsis . rest)
      ;; Identifiers not captured by BINDINGS are wrapped with SYNTAX-CONTEXT
      ;; so free template identifiers keep their definition-time bindings.
      (let ((path (if (null? rest) '() (car rest)))
            (ellipsis-literal? (if (or (null? rest) (null? (cdr rest)))
                                   #f
                                   (second rest))))
        (cond
         ((identifier-datum? template)
          (let* ((name (identifier-datum-name template))
                 (entry (and (not (eq? name ellipsis))
                            (pattern-binding bindings name))))
            (cond
             (entry
              (pattern-binding-value-at entry name path))
             ((and (eq? name ellipsis) (not ellipsis-literal?))
              (eval-error "misplaced ellipsis in template"))
             (else
              (make-identifier name syntax-context)))))
         ((pair? template)
          (let* ((pieces (list-elements-tail template))
                 (elements (car pieces))
                 (tail (cdr pieces)))
            (if (and (not ellipsis-literal?)
                     (null? tail)
                     (= (length elements) 2)
                     (ellipsis-identifier? (car elements) ellipsis))
                (expand-template (second elements)
                                 bindings
                                 syntax-context
                                 ellipsis
                                 path
                                 #t)
                (let loop ((cursor elements) (output '()))
                  (if (null? cursor)
                      (append-tail
                       (reverse output)
                       (if (null? tail)
                           '()
                           (expand-template tail
                                            bindings
                                            syntax-context
                                            ellipsis
                                            path
                                            ellipsis-literal?)))
                      (let ((element (car cursor))
                            (next (if (null? (cdr cursor))
                                      #f
                                      (second cursor))))
                        (if (and next
                                 (not ellipsis-literal?)
                                 (ellipsis-identifier? next ellipsis))
                            (let ((count
                                   (template-repeat-count
                                    element bindings ellipsis path)))
                              (let repeat-loop ((index 0) (out output))
                                (if (= index count)
                                    (loop (cdr (cdr cursor)) out)
                                    (repeat-loop
                                     (+ index 1)
                                     (cons (expand-template
                                            element
                                            bindings
                                            syntax-context
                                            ellipsis
                                            (path-add-index path index))
                                           out)))))
                            (loop (cdr cursor)
                                  (cons (expand-template
                                         element
                                         bindings
                                         syntax-context
                                         ellipsis
                                         path
                                         ellipsis-literal?)
                                        output)))))))))
         ((vector? template)
          (list->vector
           (expand-template (vector->list template)
                            bindings
                            syntax-context
                            ellipsis
                            path
                            ellipsis-literal?)))
         (else template))))

    ;; Allocate a fresh syntax context for identifiers introduced by a macro.
    (define (next-syntax-context! context value-environment syntax-environment)
      ;; Each expansion gets a fresh context id so introduced bindings cannot
      ;; collide accidentally with names from the macro use site.
      (let ((id (context-next-syntax-id context)))
        (set-context-next-syntax-id! context (+ id 1))
        (make-syntax-context id value-environment syntax-environment)))

    ;; Apply TRANSFORMER to FORM by matching rules and expanding the template.
    (define (apply-syntax-transformer transformer form environment context)
      (let loop ((rules (syntax-transformer-rules transformer)))
        (if (null? rules)
            (eval-error
             "macro use does not match any syntax-rules pattern"
             form)
            (let ((bindings (make-pattern-bindings)))
             (if (match-syntax-rule
                  (car rules)
                  form
                  transformer
                  bindings
                  environment
                  (context-syntax-environment context))
                  (let ((result
                         (expand-template
                          (cdr (car rules))
                          bindings
                          (next-syntax-context!
                           context
                           (syntax-transformer-value-environment transformer)
                           (syntax-transformer-syntax-environment transformer))
                          (syntax-transformer-ellipsis transformer))))
                    (if (syntax-error-form? result)
                        (raise-syntax-error result form)
                        result))
                  (loop (cdr rules)))))))

    ;; Report whether FORM is a define-syntax form.
    (define (syntax-definition-form? form)
      (and (pair? form) (identifier-named? (car form) 'define-syntax)))

    ;; Evaluate a define-syntax form and install its transformer.
    (define (eval-define-syntax form environment context syntax-environment)
      (let ((parts (proper-list-elements form "define-syntax form")))
        (if (not (= (length parts) 3))
            (eval-error
             "define-syntax requires a keyword and transformer spec"
             form))
        (let ((keyword (expect-symbol (second parts)
                                      "define-syntax keyword"))
              (transformer
               (parse-syntax-rules (third parts)
                                   environment
                                   syntax-environment)))
          (syntax-environment-define!
           syntax-environment keyword transformer)
          agent-scheme-unspecified)))

    ;; Parse one let-syntax binding into keyword and transformer spec.
    (define (parse-let-syntax-binding binding)
      (let ((parts (proper-list-elements binding "syntax binding")))
        (if (not (= (length parts) 2))
            (eval-error
             "syntax binding must contain a keyword and transformer spec"
             binding))
        (cons (expect-symbol (car parts) "syntax binding keyword")
              (second parts))))

    ;; Build the syntax scope created by let-syntax or letrec-syntax.
    (define (make-local-syntax-scope parts environment context recursive?)
      (if (< (length parts) 3)
          (eval-error
           (string-append
            (if recursive? "letrec-syntax" "let-syntax")
            " requires bindings and a body")
           parts))
      (let* ((outer-syntax-environment (context-syntax-environment context))
             (local-syntax-environment
              (make-empty-syntax-environment outer-syntax-environment))
             (bindings
              (map parse-let-syntax-binding
                   (proper-list-elements
                    (second parts)
                    "syntax binding list"))))
        (ensure-distinct-names (map car bindings) "syntax binding list")
        (for-each
         (lambda (binding)
           (syntax-environment-define!
            local-syntax-environment
            (car binding)
            (parse-syntax-rules
             (cdr binding)
             environment
             (if recursive?
                 local-syntax-environment
                 outer-syntax-environment))))
         bindings)
        (make-syntax-scope (cddr parts) local-syntax-environment)))

    ;; Canonical key for the required `(scheme base)' library.
    (define scheme-base-library-key '(scheme base))

    ;; Bootstrap libraries are registered lazily into the current context.  The
    ;; required base library snapshots the active base environment; smaller
    ;; standard libraries are subsets, primitive wrappers, or source libraries.
    (define empty-emacs-capability-library-keys
      '((emacs buffer)
        (emacs buffer edit)
        (emacs command)
        (emacs project)
        (emacs window)))

    ;; Standard library keys recognized by the portable library registry.
    (define standard-library-keys
      '((scheme case-lambda)
        (scheme char)
        (scheme complex)
        (scheme cxr)
        (scheme eval)
        (scheme file)
        (scheme inexact)
        (scheme lazy)
        (scheme load)
        (scheme process-context)
        (scheme read)
        (scheme repl)
        (scheme r5rs)
        (scheme time)
        (scheme write)))

    ;; Checked-in standard libraries loaded as portable Scheme source files.
    (define standard-source-library-load-paths
      '(((scheme case-lambda)
         "scheme/standard-library/case-lambda.sld"
         "standard-library/case-lambda.sld")
        ((scheme lazy)
         "scheme/standard-library/lazy.sld"
         "standard-library/lazy.sld")))

    ;; Cache selected source path and contents by standard library key.
    (define standard-source-library-source-cache '())

    ;; Report whether DATUM is a proper R7RS library name.
    (define (proper-library-name? datum)
      (and (pair? datum)
           (let ((parts (proper-list-elements/maybe datum)))
             (and parts
                  (let loop ((rest parts))
                    (cond
                     ((null? rest) #t)
                     ((or (symbol? (car rest))
                          (and (agent-scheme-number? (car rest))
                               (eq? (agent-scheme-number-kind (car rest))
                                    'integer)
                               (eq? (agent-scheme-number-exactness (car rest))
                                    'exact)
                               (>= (agent-scheme-number-value (car rest)) 0)))
                      (loop (cdr rest)))
                     (else #f)))))))

    ;; Validate and return NAME as a library registry key.
    (define (library-name-key name)
      (if (proper-library-name? name)
          name
          (eval-error "invalid library name" name)))

    ;; Search ALIST for KEY using equal? comparison.
    (define (assoc/equal key alist)
      (cond
       ((null? alist) #f)
       ((equal? key (caar alist)) (car alist))
       (else (assoc/equal key (cdr alist)))))

    ;; Return the configured path candidates for source-backed standard library
    ;; KEY.
    (define (standard-source-library-paths key)
      (let ((entry (assoc/equal key standard-source-library-load-paths)))
        (if entry
            (cdr entry)
            (eval-error "standard source library is not available" key))))

    ;; Read KEY's source from the first path that works in this host layout.
    (define (load-standard-source-library-source key)
      (let try ((paths (standard-source-library-paths key)))
        (if (null? paths)
            (eval-error "unable to load standard source library" key)
            (guard (condition
                    (else (try (cdr paths))))
              (let ((source
                     (call-with-input-file
                         (car paths)
                       read-port-string)))
                (cons (car paths) source))))))

    ;; Return cached source-file/source pair for source-backed standard library
    ;; KEY.
    (define (standard-source-library-source-entry key)
      (let ((cached (assoc/equal key standard-source-library-source-cache)))
        (if cached
            (cdr cached)
            (let ((loaded (load-standard-source-library-source key)))
              (set! standard-source-library-source-cache
                    (cons (cons key loaded)
                          standard-source-library-source-cache))
              loaded))))

    ;; Return KEY's portable source text.
    (define (standard-source-library-source key)
      (cdr (standard-source-library-source-entry key)))

    ;; Return the single define-library form read from KEY's source file.
    (define (standard-source-library-form key)
      (let ((forms (agent-scheme-read-all
                    (standard-source-library-source key))))
        (if (not (= (length forms) 1))
            (eval-error
             "standard source library must contain exactly one form"
             key))
        (let* ((form (car forms))
               (parts (proper-list-elements
                       form
                       "standard source library")))
          (if (not (and (>= (length parts) 2)
                        (identifier-named? (car parts) 'define-library)
                        (equal? (second parts) key)))
              (eval-error
               "standard source library name does not match registry key"
               key))
          form)))

    ;; Return external export names declared by source library FORM.
    (define (standard-source-library-export-names form)
      (apply append
             (map
              (lambda (declaration)
                (if (form-named? declaration 'export)
                    (map cdr
                         (export-specs
                          (cdr
                           (proper-list-elements
                            declaration
                            "standard source export"))))
                    '()))
              (cddr
               (proper-list-elements form "standard source library")))))

    ;; Public metadata accessor for standard libraries backed by source files.
    (define (agent-scheme-standard-source-library-specs)
      (map
       (lambda (entry)
         (let* ((key (car entry))
                (source-entry (standard-source-library-source-entry key)))
           (list
            (list 'name key)
            (list 'exports
                  (standard-source-library-export-names
                   (standard-source-library-form key)))
            (list 'source-file (car source-entry)))))
       standard-source-library-load-paths))

    ;; Return the registered library for KEY in CONTEXT, or #f.
    (define (library-registry-ref context key)
      (let ((cell (assoc/equal key (context-libraries context))))
        (if cell (cdr cell) #f)))

    ;; Store LIBRARY under KEY in CONTEXT's registry.
    (define (library-registry-set! context key library)
      (let replace ((rest (context-libraries context)) (prefix '()))
        (cond
         ((null? rest)
          (set-context-libraries!
           context
           (cons (cons key library) (context-libraries context))))
         ((equal? key (caar rest))
          (set-context-libraries!
           context
           (append (reverse prefix)
                   (cons (cons key library) (cdr rest)))))
         (else
          (replace (cdr rest) (cons (car rest) prefix))))))

    ;; Return NAME's binding from SYNTAX-ENVIRONMENT's current frame only.
    (define (current-syntax-binding syntax-environment name)
      (let ((cell (assq name (syntax-environment-frame syntax-environment))))
        (if cell (cdr cell) #f)))

    ;; Report whether FORM is headed by identifier NAME.
    (define (form-named? form name)
      (and (pair? form) (identifier-named? (car form) name)))

    ;; Report whether FORM is an import declaration.
    (define (import-form? form)
      (form-named? form 'import))

    ;; Report whether FORM is a define-library declaration.
    (define (define-library-form? form)
      (form-named? form 'define-library))

    ;; Return BINDING under exported NAME while preserving its target object.
    (define (library-binding-with-name binding name)
      (make-library-binding
       name
       (library-binding-kind binding)
       (library-binding-object binding)
       (library-binding-library-key binding)))

    ;; Report whether two library bindings refer to the same exported object.
    (define (same-library-binding? left right)
      (and (library-binding? left)
           (library-binding? right)
           (eq? (library-binding-kind left) (library-binding-kind right))
           (eq? (library-binding-object left)
                (library-binding-object right))))

    ;; Snapshot current value and syntax frames as exports for LIBRARY-KEY.
    (define (snapshot-library-bindings value-environment syntax-environment
                                       library-key)
      (append
       (map (lambda (entry)
              (make-library-binding
               (car entry)
               'value
               (cdr entry)
               library-key))
            (environment-frame value-environment))
       (map (lambda (entry)
              (make-library-binding
               (car entry)
               'syntax
               (cdr entry)
               library-key))
            (syntax-environment-frame syntax-environment))))

    ;; Register `(scheme base)' from the active or freshly built base state.
    (define (register-scheme-base-library! context environment)
      (if (not (library-registry-ref context scheme-base-library-key))
          (let* ((use-current-environment?
                  (environment-cell environment '+))
                 (base-environment
                  (if use-current-environment?
                      environment
                      (agent-scheme-make-base-environment)))
                 (base-context
                  (if use-current-environment?
                      context
                      (new-eval-context '()))))
            (if (not use-current-environment?)
                (ensure-base-syntax! base-context base-environment))
            (let* ((base-syntax-environment
                    (context-syntax-environment base-context))
                   (exports
                    (snapshot-library-bindings
                     base-environment
                     base-syntax-environment
                     scheme-base-library-key)))
              (library-registry-set!
               context
               scheme-base-library-key
               (make-library
                scheme-base-library-key
                scheme-base-library-key
                exports
                base-environment
                base-syntax-environment))))))

    ;; Register an intentionally empty capability library for KEY.
    (define (register-empty-emacs-capability-library! key context)
      (if (not (library-registry-ref context key))
          (let ((value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (make-empty-syntax-environment #f)))
            (library-registry-set!
             context
             key
             (make-library key key '() value-environment syntax-environment)))))

    ;; Read and evaluate a define-library form from SOURCE.
    (define (register-source-library! source context environment)
      (let ((forms (agent-scheme-read-all source)))
        (if (not (= (length forms) 1))
            (eval-error "source library must contain exactly one form"))
        (eval-define-library
         (car forms)
         environment
         context)))

    ;; Return NAME's binding from EXPORTS, or #f when absent.
    (define (find-library-export name exports)
      (cond
       ((null? exports) #f)
       ((eq? name (library-binding-name (car exports))) (car exports))
       (else (find-library-export name (cdr exports)))))

    ;; Register KEY as a subset of `(scheme base)' exports.
    (define (register-subset-library! key export-names context environment)
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (exports
                  (map
                   (lambda (name)
                     (or (find-library-export name base-exports)
                         (eval-error
                          "standard library binding is not available"
                          name)))
                   export-names)))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              exports
              (library-value-environment base-library)
              (library-syntax-environment base-library))))))

    ;; Register KEY as a library populated from primitive specs.
    (define (register-primitive-library! key primitive-specs context)
      (if (not (library-registry-ref context key))
          (let ((value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (make-empty-syntax-environment #f)))
            (for-each
             (lambda (spec)
               (define-primitive!
                value-environment
                (car spec)
                (second spec)
                (third spec)
                (fourth spec)))
             primitive-specs)
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              (snapshot-library-bindings
               value-environment
               syntax-environment
               key)
              value-environment
              syntax-environment)))))

    ;; Return primitive specs for `(scheme char)'.
    (define (char-library-specs)
      (list
       (list 'char-alphabetic? primitive-char-alphabetic? 1 1)
       (list 'char-ci<=? primitive-char-ci<=? 2 #f)
       (list 'char-ci<? primitive-char-ci<? 2 #f)
       (list 'char-ci=? primitive-char-ci=? 2 #f)
       (list 'char-ci>=? primitive-char-ci>=? 2 #f)
       (list 'char-ci>? primitive-char-ci>? 2 #f)
       (list 'char-downcase primitive-char-downcase 1 1)
       (list 'char-foldcase primitive-char-foldcase 1 1)
       (list 'char-lower-case? primitive-char-lower-case? 1 1)
       (list 'char-numeric? primitive-char-numeric? 1 1)
       (list 'char-upcase primitive-char-upcase 1 1)
       (list 'char-upper-case? primitive-char-upper-case? 1 1)
       (list 'char-whitespace? primitive-char-whitespace? 1 1)
       (list 'digit-value primitive-digit-value 1 1)
       (list 'string-ci<=? primitive-string-ci<=? 2 #f)
       (list 'string-ci<? primitive-string-ci<? 2 #f)
       (list 'string-ci=? primitive-string-ci=? 2 #f)
       (list 'string-ci>=? primitive-string-ci>=? 2 #f)
       (list 'string-ci>? primitive-string-ci>? 2 #f)
       (list 'string-downcase primitive-string-downcase 1 1)
       (list 'string-foldcase primitive-string-foldcase 1 1)
       (list 'string-upcase primitive-string-upcase 1 1)))

    ;; Base-library cxr names re-exported by `(scheme cxr)'.
    (define cxr-library-base-names
      '(caar cadr cdar cddr))

    ;; Additional cxr names implemented directly by `(scheme cxr)'.
    (define cxr-library-extra-names
      '(caaar caadr cadar caddr cdaar cdadr cddar cdddr
        caaaar caaadr caadar caaddr cadaar cadadr caddar cadddr
        cdaaar cdaadr cdadar cdaddr cddaar cddadr cdddar cddddr))

    ;; Implement the `cxr-function` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-cxr-function name)
      (let ((text (symbol->string name)))
        (lambda (arguments context)
          (let loop ((index (- (string-length text) 2))
                     (value (car arguments)))
            (if (= index 0)
                value
                (let ((step (string-ref text index)))
                  (loop (- index 1)
                        (cond
                         ((char=? step #\a)
                          (primitive-car (list value) context))
                         ((char=? step #\d)
                          (primitive-cdr (list value) context))
                         (else
                          (eval-error "invalid cxr name" name))))))))))

    ;; Return primitive specs for generated cxr selectors.
    (define (cxr-library-specs)
      (map (lambda (name)
             (list name (primitive-cxr-function name) 1 1))
           cxr-library-extra-names))

    ;; Register `(scheme cxr)' from base selectors and generated selectors.
    (define (register-cxr-library! key context environment)
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (base-bindings
                  (map
                   (lambda (name)
                     (or (find-library-export name base-exports)
                         (eval-error
                          "standard library binding is not available"
                          name)))
                   cxr-library-base-names))
                 (value-environment (agent-scheme-make-empty-environment))
                 (syntax-environment (make-empty-syntax-environment #f)))
            (for-each
             (lambda (spec)
               (define-primitive!
                value-environment
                (car spec)
                (second spec)
                (third spec)
                (fourth spec)))
             (cxr-library-specs))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              (append
               base-bindings
               (snapshot-library-bindings
                value-environment
                syntax-environment
                key))
              value-environment
              syntax-environment)))))

    ;; Return primitive specs for `(scheme inexact)'.
    (define (inexact-library-specs)
      (list
       (list 'acos primitive-acos 1 1)
       (list 'asin primitive-asin 1 1)
       (list 'atan primitive-atan 1 2)
       (list 'cos primitive-cos 1 1)
       (list 'exp primitive-exp 1 1)
       (list 'finite? primitive-finite? 1 1)
       (list 'infinite? primitive-infinite? 1 1)
       (list 'log primitive-log 1 2)
       (list 'nan? primitive-nan? 1 1)
       (list 'sin primitive-sin 1 1)
       (list 'sqrt primitive-sqrt 1 1)
       (list 'tan primitive-tan 1 1)))

    ;; Return a primitive spec that always raises a policy-denied error.
    (define (policy-denied-spec name)
      (list name (policy-denied-primitive (symbol->string name)) 0 #f))

    ;; Register `(scheme r5rs)' with R5RS aliases for exact/inexact conversion.
    (define (register-r5rs-library! key context environment)
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (inexact-binding
                  (or (find-library-export 'inexact base-exports)
                      (eval-error "R5RS inexact alias missing")))
                 (exact-binding
                  (or (find-library-export 'exact base-exports)
                      (eval-error "R5RS exact alias missing")))
                 (exports
                  (append
                   base-exports
                   (list
                    (library-binding-with-name
                     inexact-binding
                     'exact->inexact)
                    (library-binding-with-name
                     exact-binding
                     'inexact->exact)))))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              exports
              (library-value-environment base-library)
              (library-syntax-environment base-library))))))

    ;; Register a supported standard library by KEY.
    (define (register-standard-library! key context environment)
      (cond
       ((equal? key '(scheme case-lambda))
        (register-source-library!
         (standard-source-library-source key)
         context
         environment))
       ((equal? key '(scheme char))
        (register-primitive-library!
         key
         (char-library-specs)
         context))
       ((equal? key '(scheme complex))
        (register-primitive-library!
         key
         (list
          (list 'angle primitive-angle 1 1)
          (list 'imag-part primitive-imag-part 1 1)
          (list 'magnitude primitive-magnitude 1 1)
          (list 'make-polar primitive-make-polar 2 2)
          (list 'make-rectangular primitive-make-rectangular 2 2)
          (list 'real-part primitive-real-part 1 1))
         context))
       ((equal? key '(scheme cxr))
        (register-cxr-library! key context environment))
       ((equal? key '(scheme eval))
        (register-primitive-library!
         key
         (list
          (list 'environment primitive-environment 1 #f)
          (list 'eval primitive-eval 2 2))
         context))
       ((equal? key '(scheme file))
        (register-primitive-library!
         key
         (list
          (list 'delete-file primitive-delete-file 1 1)
          (list 'file-exists? primitive-file-exists? 1 1))
         context))
       ((equal? key '(scheme inexact))
        (register-primitive-library!
         key
         (inexact-library-specs)
         context))
       ((equal? key '(scheme lazy))
        (register-source-library!
         (standard-source-library-source key)
         context
         environment))
       ((equal? key '(scheme load))
        (register-primitive-library!
         key
         (list (list 'load primitive-load 1 2))
         context))
       ((equal? key '(scheme process-context))
        (register-primitive-library!
         key
         (map policy-denied-spec
              '(command-line
                emergency-exit
                exit
                get-environment-variable
                get-environment-variables))
         context))
       ((equal? key '(scheme read))
        (register-primitive-library!
         key
         (list (list 'read primitive-read 0 1))
         context))
       ((equal? key '(scheme repl))
        (register-primitive-library!
         key
         (list (policy-denied-spec 'interaction-environment))
         context))
       ((equal? key '(scheme r5rs))
        (register-r5rs-library! key context environment))
       ((equal? key '(scheme time))
        (register-primitive-library!
         key
         (map policy-denied-spec
              '(current-jiffy current-second jiffies-per-second))
         context))
       ((equal? key '(scheme write))
        (register-primitive-library!
         key
         (list
          (list 'display primitive-display 1 2)
          (list 'write primitive-write 1 2)
          (list 'write-shared primitive-write-shared 1 2)
          (list 'write-simple primitive-write-simple 1 2))
         context))
       (else
        (eval-error "unknown standard library" key))))

    ;; Report whether NAME is a known or already registered library.
    (define (library-available? name context environment)
      (let ((key (library-name-key name)))
        (or (equal? key scheme-base-library-key)
            (member key standard-library-keys)
            (member key empty-emacs-capability-library-keys)
            (and (library-registry-ref context key) #t))))

    ;; Resolve NAME to a library, registering lazy standard libraries as needed.
    (define (resolve-library name context environment)
      (let ((key (library-name-key name)))
        (cond
         ((equal? key scheme-base-library-key)
          (register-scheme-base-library! context environment))
         ((member key standard-library-keys)
          (register-standard-library! key context environment))
         ((member key empty-emacs-capability-library-keys)
          (register-empty-emacs-capability-library! key context)))
        (or (library-registry-ref context key)
            (eval-error "unknown library" key))))

    ;; Return NAME's import binding from BINDINGS, or #f.
    (define (find-import-binding name bindings)
      (cond
       ((null? bindings) #f)
       ((eq? name (library-binding-name (car bindings))) (car bindings))
       (else (find-import-binding name (cdr bindings)))))

    ;; Reject import modifiers naming exports that are absent from BINDINGS.
    (define (ensure-import-names-present names bindings description)
      (for-each
       (lambda (name)
         (if (not (find-import-binding name bindings))
             (eval-error
              (string-append description " import name not found")
              name)))
       names))

    ;; Merge duplicate compatible imports and reject conflicting imports.
    (define (ensure-compatible-import-bindings bindings)
      (let loop ((rest bindings) (seen '()) (result '()))
        (if (null? rest)
            (reverse result)
            (let* ((binding (car rest))
                   (name (library-binding-name binding))
                   (previous (assq name seen)))
              (cond
               ((not previous)
                (loop (cdr rest)
                      (cons (cons name binding) seen)
                      (cons binding result)))
               ((same-library-binding? (cdr previous) binding)
                (loop (cdr rest) seen result))
               (else
                (eval-error
                 "conflicting imports for identifier"
                 name)))))))

    ;; Validate import modifier operands as symbols.
    (define (import-modifier-identifiers forms description)
      (map (lambda (form) (expect-symbol form description)) forms))

    ;; Resolve an import set, applying only/except/prefix/rename modifiers.
    (define (resolve-import-set import-set context environment)
      (cond
       ((proper-library-name? import-set)
        (library-exports
         (resolve-library import-set context environment)))
       ((pair? import-set)
        (let* ((parts (proper-list-elements import-set "import set"))
               (operator (car parts)))
          (cond
           ((identifier-named? operator 'only)
            (if (< (length parts) 2)
                (eval-error "only import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (names
                    (import-modifier-identifiers (cddr parts) "only")))
              (ensure-import-names-present names bindings "only")
              (let loop ((rest bindings) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) (cons (car rest) result)))
                 (else (loop (cdr rest) result))))))
           ((identifier-named? operator 'except)
            (if (< (length parts) 2)
                (eval-error "except import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (names
                    (import-modifier-identifiers (cddr parts) "except")))
              (ensure-import-names-present names bindings "except")
              (let loop ((rest bindings) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) result))
                 (else (loop (cdr rest) (cons (car rest) result)))))))
           ((identifier-named? operator 'prefix)
            (if (not (= (length parts) 3))
                (eval-error
                 "prefix import set requires an import set and prefix"))
            (let ((prefix
                   (symbol->string
                    (expect-symbol (third parts) "prefix identifier"))))
              (map
               (lambda (binding)
                 (library-binding-with-name
                  binding
                  (string->symbol
                   (string-append
                    prefix
                    (symbol->string (library-binding-name binding))))))
               (resolve-import-set (second parts) context environment))))
           ((identifier-named? operator 'rename)
            (if (< (length parts) 2)
                (eval-error "rename import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (renames
                    (map
                     (lambda (rename-form)
                       (let ((rename-parts
                              (proper-list-elements
                               rename-form
                               "rename pair")))
                         (if (not (= (length rename-parts) 2))
                             (eval-error
                              "rename pair requires old and new identifiers"))
                         (cons
                          (expect-symbol
                           (car rename-parts)
                           "rename old identifier")
                          (expect-symbol
                           (second rename-parts)
                           "rename new identifier"))))
                     (cddr parts))))
              (ensure-import-names-present (map car renames)
                                           bindings
                                           "rename")
              (map
               (lambda (binding)
                 (let ((rename
                        (assq (library-binding-name binding) renames)))
                   (if rename
                       (library-binding-with-name binding (cdr rename))
                       binding)))
               bindings)))
           (else
            (eval-error "invalid import set" import-set)))))
       (else
        (eval-error "invalid import set" import-set))))

    ;; Install one imported value or syntax binding into the target frames.
    (define (install-imported-binding! binding value-environment
                                       syntax-environment)
      (let ((name (library-binding-name binding))
            (kind (library-binding-kind binding))
            (object (library-binding-object binding))
            (binding-library-key (library-binding-library-key binding)))
        (cond
         ((eq? kind 'value)
          (let ((existing (frame-cell value-environment name)))
            (cond
             ((not existing)
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((equal? binding-library-key scheme-base-library-key)
              ;; Repeated `(scheme base)' imports are common while source
              ;; libraries bootstrap; reinstalling the same base name is
              ;; harmless and keeps import-set handling small.
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((eq? existing object))
             (else
              (eval-error "conflicting import for identifier" name))))
          (if (not (memq name (environment-imported-names value-environment)))
              (set-environment-imported-names!
               value-environment
               (cons name (environment-imported-names value-environment)))))
         ((eq? kind 'syntax)
          (let ((existing (current-syntax-binding syntax-environment name)))
            (cond
             ((or (not existing)
                  (equal? binding-library-key scheme-base-library-key))
              (set-syntax-environment-frame!
               syntax-environment
               (cons (cons name object)
                     (syntax-environment-frame syntax-environment))))
             ((eq? existing object))
             (else
              (eval-error "conflicting syntax import for identifier" name))))
          (if (not (memq name
                         (syntax-environment-imported-names
                          syntax-environment)))
              (set-syntax-environment-imported-names!
               syntax-environment
               (cons name
                     (syntax-environment-imported-names
                      syntax-environment)))))
         (else
          (eval-error "unsupported library binding kind" kind)))))

    ;; Resolve IMPORT-SET and install all compatible imported bindings.
    (define (install-import-set! import-set value-environment
                                 syntax-environment context)
      (for-each
       (lambda (binding)
         (install-imported-binding! binding
                                    value-environment
                                    syntax-environment))
       (ensure-compatible-import-bindings
        (resolve-import-set import-set context value-environment))))

    ;; Evaluate an import declaration into the active value and syntax frames.
    (define (eval-import form environment context)
      (let ((parts (proper-list-elements form "import declaration")))
        (if (< (length parts) 2)
            (eval-error "import requires at least one import set"))
        (for-each
         (lambda (import-set)
           (install-import-set!
            import-set
            environment
            (context-syntax-environment context)
            context))
         (cdr parts))
        agent-scheme-unspecified))

    ;; Parse export clauses into internal-name/external-name pairs.
    (define (export-specs forms)
      (let loop ((rest forms) (specs '()))
        (if (null? rest)
            (reverse specs)
            (let ((form (car rest)))
              (cond
               ((identifier-datum? form)
                (let ((name (expect-symbol form "export identifier")))
                  (loop (cdr rest) (cons (cons name name) specs))))
               ((form-named? form 'rename)
                (let ((parts (proper-list-elements form "export rename")))
                  (if (not (= (length parts) 3))
                      (eval-error
                       "export rename requires internal and external identifiers"))
                  (loop
                   (cdr rest)
                   (cons
                    (cons
                     (expect-symbol
                      (second parts)
                      "export internal identifier")
                     (expect-symbol
                      (third parts)
                      "export external identifier"))
                    specs))))
               (else
                (eval-error "invalid export spec" form)))))))

    ;; Report whether a cond-expand feature requirement is satisfied.
    (define (feature-requirement-satisfied? requirement context environment)
      (cond
       ((identifier-datum? requirement)
        (eq? (identifier-datum-name requirement) 'r7rs))
       ((pair? requirement)
        (let* ((parts (proper-list-elements requirement "feature requirement"))
               (operator (car parts)))
          (cond
           ((identifier-named? operator 'library)
            (if (not (= (length parts) 2))
                (eval-error
                 "library feature requirement requires one library name"))
            (library-available? (second parts) context environment))
           ((identifier-named? operator 'and)
            (let loop ((rest (cdr parts)))
              (or (null? rest)
                  (and (feature-requirement-satisfied?
                        (car rest)
                        context
                        environment)
                       (loop (cdr rest))))))
           ((identifier-named? operator 'or)
            (let loop ((rest (cdr parts)))
              (and (not (null? rest))
                   (or (feature-requirement-satisfied?
                        (car rest)
                        context
                        environment)
                       (loop (cdr rest))))))
           ((identifier-named? operator 'not)
            (if (not (= (length parts) 2))
                (eval-error
                 "not feature requirement requires one nested requirement"))
            (not
             (feature-requirement-satisfied?
              (second parts)
              context
              environment)))
           (else #f))))
       (else #f)))

    ;; Select declarations from the first satisfied library cond-expand clause.
    (define (expand-library-cond-expand clauses context environment)
      (let loop ((rest clauses))
        (if (null? rest)
            (eval-error "unfulfilled library cond-expand")
            (let* ((parts (proper-list-elements
                           (car rest)
                           "cond-expand clause"))
                   (requirement (car parts)))
              (if (or (identifier-named? requirement 'else)
                      (feature-requirement-satisfied?
                       requirement context environment))
                  (cdr parts)
                  (loop (cdr rest)))))))

    ;; Expand library declaration wrappers such as cond-expand and includes.
    (define (expand-library-declaration declaration context environment)
      (cond
       ((form-named? declaration 'cond-expand)
        (apply append
               (map
                (lambda (nested)
                  (expand-library-declaration nested context environment))
                (expand-library-cond-expand
                 (cdr (proper-list-elements
                       declaration
                       "library cond-expand"))
                 context
                 environment))))
       ((form-named? declaration 'include-library-declarations)
        (expand-include-library-declarations
         declaration
         context
         environment))
       (else
        (list declaration))))

    ;; Return string literal filenames from an include-style declaration.
    (define (include-filenames declaration)
      (let* ((parts (proper-list-elements declaration "include declaration"))
             (operator (identifier-datum-name (car parts))))
        (if (null? (cdr parts))
            (eval-error "include requires at least one filename" operator))
        (map
         (lambda (filename)
           (if (not (string? filename))
               (eval-error "include filename must be a string literal"
                           operator))
           filename)
         (cdr parts))))

    ;; Test whether TEXT begins with PREFIX.
    (define (string-prefix? prefix string)
      (let ((prefix-length (string-length prefix))
            (string-length-value (string-length string)))
        (and (<= prefix-length string-length-value)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref string index))
                        (loop (+ index 1))))))))

    ;; Remove a single trailing slash from PATH for policy-prefix checks.
    (define (strip-trailing-slash path)
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    ;; Report whether PATH is exactly allowed or inside an allowed directory.
    (define (path-policy-allows-file? path allowed-paths)
      (let loop ((rest allowed-paths))
        (and (not (null? rest))
             (let* ((allowed (strip-trailing-slash (car rest)))
                    (allowed-directory (string-append allowed "/")))
               (or (string=? path allowed)
                   (string-prefix? allowed-directory path)
                   (loop (cdr rest)))))))

    ;; Report whether PATH satisfies the current include allow-list policy.
    (define (include-policy-allows-file? path context)
      (path-policy-allows-file? path (context-include-paths context)))

    ;; Resolve FILENAME against the include directory and enforce file policy.
    (define (resolve-include-file filename context)
      (let ((path (path-join (context-include-directory context) filename)))
        (cond
         ((null? (context-include-paths context))
          ;; Includes are host file reads, so even portable Scheme evaluation
          ;; requires an explicit allow-list before opening a file.
          (eval-error "include requires policy-gated host file access"
                      filename))
         ((not (include-policy-allows-file? path context))
          (eval-error "include file is not allowed by policy" filename))
         ((not (file-exists? path))
          (eval-error "include file is not readable" filename))
         (else path))))

    ;; Return PATH's directory component without the trailing slash.
    (define (path-directory path)
      (let loop ((index (- (string-length path) 1)))
        (cond
         ((< index 0) "")
         ((char=? (string-ref path index) #\/)
          (substring path 0 index))
         (else (loop (- index 1))))))

    ;; Read PATH into a string using the Scheme file API.
    (define (read-file-string path)
      (call-with-input-file
       path
       (lambda (port)
         (let loop ((chars '()))
           (let ((char (read-char port)))
             (if (eof-object? char)
                 (list->string (reverse chars))
                 (loop (cons char chars))))))))

    ;; Run THUNK with CONTEXT's include directory temporarily set.
    (define (with-include-directory context directory thunk)
      (let ((previous-directory (context-include-directory context)))
        (dynamic-wind
          (lambda ()
            (set-context-include-directory!
             context
             (normalize-include-directory directory)))
          thunk
          (lambda ()
            (set-context-include-directory!
             context
             previous-directory)))))

    ;; Read and parse all forms from an include file, returning forms and
    ;; directory.
    (define (read-include-file-forms filename context fold-case?)
      (let* ((path (resolve-include-file filename context))
             (source (read-file-string path)))
        (cons
         (agent-scheme-read-all
          (if fold-case?
              (string-append "#!fold-case\n" source)
              source))
         (path-directory path))))

    ;; Return all body forms read by an include or include-ci declaration.
    (define (library-include-body-forms declaration context fold-case?)
      (apply append
             (map (lambda (filename)
                    (car (read-include-file-forms
                          filename
                          context
                          fold-case?)))
                  (include-filenames declaration))))

    ;; Read include-library-declarations files and expand their declarations.
    (define (expand-include-library-declarations declaration context
                                                 environment)
      (apply
       append
       (map
        (lambda (filename)
          (let* ((read-result
                  (read-include-file-forms filename context #f))
                 (forms (car read-result))
                 (directory (cdr read-result)))
            (with-include-directory
             context
             directory
             (lambda ()
               (apply
                append
                (map
                 (lambda (nested)
                   (expand-library-declaration
                    nested
                    context
                    environment))
                 forms))))))
        (include-filenames declaration))))

    ;; Resolve one export spec to a value or syntax library binding.
    (define (library-export-binding spec library-key value-environment
                                    syntax-environment)
      (let* ((internal-name (car spec))
             (external-name (cdr spec))
             (cell (environment-cell value-environment internal-name))
             (syntax-binding
              (syntax-environment-ref syntax-environment internal-name)))
        (cond
         ((and cell syntax-binding)
          (eval-error
           "export identifier has both value and syntax bindings"
           internal-name))
         (cell
          (make-library-binding external-name 'value cell library-key))
         (syntax-binding
          (make-library-binding external-name
                                'syntax
                                syntax-binding
                                library-key))
         (else
          (eval-error "exported identifier is not bound" internal-name)))))

    ;; Build checked library exports from parsed export specs.
    (define (library-exports-from-specs specs library-key value-environment
                                        syntax-environment)
      (ensure-distinct-names (map cdr specs) "library exports")
      (ensure-compatible-import-bindings
       (map (lambda (spec)
              (library-export-binding spec
                                      library-key
                                      value-environment
                                      syntax-environment))
            specs)))

    ;; Evaluate library body forms under the library syntax environment.
    (define (eval-library-begin forms value-environment
                                syntax-environment context)
      (with-syntax-environment
       context
       syntax-environment
       (lambda ()
         (trampoline
          (make-sequence forms #t)
          value-environment
          context))))

    ;; Evaluate a define-library form and register its exported bindings.
    (define (eval-define-library form environment context)
      (let ((parts (proper-list-elements form "define-library form")))
        (if (< (length parts) 2)
            (eval-error "define-library requires a library name"))
        (let ((name (second parts)))
          (if (not (proper-library-name? name))
              (eval-error "invalid library name" name))
          (let ((library-key (library-name-key name))
                (value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (make-empty-syntax-environment #f)))
            (let loop ((raw-declarations (cddr parts))
                       (export-spec-list '()))
              (if (null? raw-declarations)
                  (begin
                    (library-registry-set!
                     context
                     library-key
                     (make-library
                      name
                      library-key
                      (library-exports-from-specs
                       export-spec-list
                       library-key
                       value-environment
                       syntax-environment)
                      value-environment
                      syntax-environment))
                    agent-scheme-unspecified)
                  (let declaration-loop
                      ((declarations
                        (expand-library-declaration
                         (car raw-declarations)
                         context
                         environment))
                       (exports export-spec-list))
                    (if (null? declarations)
                        (loop (cdr raw-declarations) exports)
                        (let* ((declaration (car declarations))
                               (declaration-parts
                                (proper-list-elements
                                 declaration
                                 "library declaration"))
                               (operator (car declaration-parts)))
                          ;; `cond-expand' and include-library-declarations are
                          ;; flattened before this dispatch; only core library
                          ;; declarations should reach this point.
                          (cond
                           ((identifier-named? operator 'export)
                            (declaration-loop
                             (cdr declarations)
                             (append exports
                                     (export-specs
                                      (cdr declaration-parts)))))
                           ((identifier-named? operator 'import)
                            (with-syntax-environment
                             context
                             syntax-environment
                             (lambda ()
                               (eval-import declaration
                                            value-environment
                                            context)))
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'begin)
                            (eval-library-begin
                             (cdr declaration-parts)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'include)
                            (eval-library-begin
                             (library-include-body-forms
                              declaration
                              context
                              #f)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'include-ci)
                            (eval-library-begin
                             (library-include-body-forms
                              declaration
                              context
                              #t)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named?
                             operator
                             'include-library-declarations)
                            (eval-error
                             "include-library-declarations must expand before evaluation"
                             operator))
                           (else
                            (eval-error
                             "unsupported library declaration"
                             declaration))))))))))))

    ;; Expand one expression enough to expose core forms or syntax scopes.
    (define (expand-expression expression environment context)
      (if (not (pair? expression))
          expression
          (let* ((parts (proper-list-elements expression "expression"))
                 (operator (car parts)))
            (cond
             ((and (identifier-named? operator 'syntax-error)
                   (special-operator-active? operator environment))
              (raise-syntax-error expression))
             ((and (identifier-named? operator 'let-syntax)
                   (special-operator-active? operator environment))
              (make-local-syntax-scope parts environment context #f))
             ((and (identifier-named? operator 'letrec-syntax)
                   (special-operator-active? operator environment))
              (make-local-syntax-scope parts environment context #t))
             ((syntax-binding-for-operator operator environment context)
             => (lambda (transformer)
                   (apply-syntax-transformer transformer
                                             expression
                                             environment
                                             context)))
             (else expression)))))

    ;; Evaluate procedure operands from left to right into argument values.
    (define (eval-arguments operands environment context arguments continuation)
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

    ;; Evaluate a combination or special form with tail-position awareness.
    (define (eval-combination expression environment context tail? continuation)
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
                      (check-value-budget (second parts) context)))
           ((and (identifier-named? operator 'quasiquote)
                 (special-operator-active? operator environment))
            (continue
             continuation
             (check-value-budget
              (eval-quasiquote parts environment context)
              context)))
           ((and (identifier-named? operator 'lambda)
                 (special-operator-active? operator environment))
            (if (< (length parts) 3)
                (eval-error "lambda requires formals and a body" parts))
            (continue
             continuation
             (make-procedure (parse-formals (second parts))
                             (cddr parts)
                             environment)))
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

    ;; Evaluate one expression, interleaving macro expansion and trampoline
    ;; setup.
    (define (eval-expression
             expression environment context tail? . maybe-continuation)
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
                           (check-value-budget expression context)))
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

    ;; Reject import declarations that appear after body expressions.
    (define (ensure-imports-precede-body forms)
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

    ;; Evaluate a sequence, optionally accepting leading definitions/imports.
    (define (eval-sequence
             forms environment context tail? allow-definitions?
             . maybe-continuation)
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
              (continue continuation agent-scheme-unspecified)
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

    ;; Run bounce states until evaluation produces a final value.
    (define (drain-state state context)
      (let loop ((state state))
        (if (bounce? state)
            ;; A bounce carries the value environment, syntax environment, and
            ;; evaluator continuation needed by the next tail step.
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
            state)))

    ;; Evaluate EXPRESSION in tail-call trampoline mode and budget the result.
    (define (trampoline expression environment context)
      (check-value-budget
       (drain-state
        (make-bounce expression
                     environment
                     (context-syntax-environment context)
                     identity-continuation)
        context)
       context))

    ;; Validate number input and raise an evaluator error on mismatch.
    (define (expect-number datum description)
      (if (agent-scheme-number? datum)
          datum
          (eval-error
           (string-append description " expected number")
           datum)))

    ;; Report whether DATUM is an exact Agent Scheme number.
    (define (number-exact? datum)
      (and (agent-scheme-number? datum)
           (eq? (agent-scheme-number-exactness datum) 'exact)))

    ;; Report whether DATUM is an inexact Agent Scheme number.
    (define (number-inexact? datum)
      (and (agent-scheme-number? datum)
           (eq? (agent-scheme-number-exactness datum) 'inexact)))

    ;; Report whether DATUM contains a NaN numeric component.
    (define (number-nan? datum)
      (and (agent-scheme-number? datum)
           (or (and (eq? (agent-scheme-number-kind datum) 'infnan)
                    (string=? (agent-scheme-number-value datum) "+nan.0"))
               (and (eq? (agent-scheme-number-kind datum) 'complex)
                    (or (number-nan?
                         (car (agent-scheme-number-value datum)))
                        (number-nan?
                         (cdr (agent-scheme-number-value datum))))))))

    ;; Report whether DATUM contains an infinite numeric component.
    (define (number-infinite? datum)
      (and (agent-scheme-number? datum)
           (or (and (eq? (agent-scheme-number-kind datum) 'infnan)
                    (or (string=? (agent-scheme-number-value datum) "+inf.0")
                        (string=? (agent-scheme-number-value datum) "-inf.0")))
               (and (eq? (agent-scheme-number-kind datum) 'complex)
                    (or (number-infinite?
                         (car (agent-scheme-number-value datum)))
                        (number-infinite?
                         (cdr (agent-scheme-number-value datum))))))))

    ;; Report whether DATUM is neither infinite nor NaN.
    (define (number-finite? datum)
      (and (agent-scheme-number? datum)
           (not (number-nan? datum))
           (not (number-infinite? datum))))

    ;; Report whether DATUM is exactly zero.
    (define (number-exact-zero? datum)
      (and (number-exact? datum)
           (agent-scheme-number-zero? datum)))

    ;; Report whether NUMBER is stored as a complex pair.
    (define (number-complex-representation? number)
      (eq? (agent-scheme-number-kind number) 'complex))

    ;; Return NUMBER's rectangular parts, using zero imaginary part for reals.
    (define (complex-parts number)
      (if (number-complex-representation? number)
          (agent-scheme-number-value number)
          (cons number (agent-scheme-make-canonical-integer 0))))

    ;; Report whether DATUM has no nonzero imaginary component.
    (define (number-real? datum)
      (and (agent-scheme-number? datum)
           (or (not (number-complex-representation? datum))
               (number-exact-zero?
                (cdr (agent-scheme-number-value datum))))))

    ;; Report whether DATUM is a finite real number.
    (define (number-rational? datum)
      (and (number-real? datum)
           (let ((real (if (number-complex-representation? datum)
                           (car (agent-scheme-number-value datum))
                           datum)))
             (not (eq? (agent-scheme-number-kind real) 'infnan)))))

    ;; Report whether DATUM represents an integer numeric value.
    (define (number-integer? datum)
      (and (agent-scheme-number? datum)
           (cond
            ((number-complex-representation? datum)
             (and (number-exact-zero?
                   (cdr (agent-scheme-number-value datum)))
                  (number-integer?
                   (car (agent-scheme-number-value datum)))))
            ((eq? (agent-scheme-number-kind datum) 'integer) #t)
            ((eq? (agent-scheme-number-kind datum) 'rational)
             (= (cdr (agent-scheme-number-value datum)) 1))
            ((eq? (agent-scheme-number-kind datum) 'decimal)
             (let ((value (agent-scheme-number-value datum)))
               (= value (truncate value))))
            (else #f))))

    ;; Convert DATUM to an exact numerator/denominator pair.
    (define (number->rational-pair datum description)
      (let ((number (expect-number datum description)))
        (cond
         ((eq? (agent-scheme-number-kind number) 'integer)
          (cons (agent-scheme-number-value number) 1))
         ((eq? (agent-scheme-number-kind number) 'rational)
          (agent-scheme-number-value number))
         ((number-complex-representation? number)
          (if (number-exact-zero? (cdr (agent-scheme-number-value number)))
              (number->rational-pair
               (car (agent-scheme-number-value number))
               description)
              (eval-error
               (string-append description " expected real number")
               datum)))
         (else
          (eval-error
           (string-append description " expected exact rational number")
           datum)))))

    ;; Convert DATUM to a host inexact real for transcendental operations.
    (define (number->host-float datum description)
      (let ((number (expect-number datum description)))
        (cond
         ((eq? (agent-scheme-number-kind number) 'integer)
          (inexact (agent-scheme-number-value number)))
         ((eq? (agent-scheme-number-kind number) 'rational)
          (let ((value (agent-scheme-number-value number)))
            (/ (inexact (car value)) (inexact (cdr value)))))
         ((eq? (agent-scheme-number-kind number) 'decimal)
          (agent-scheme-number-value number))
         ((eq? (agent-scheme-number-kind number) 'infnan)
          (cond
           ((string=? (agent-scheme-number-value number) "+inf.0")
            (/ 1.0 0.0))
           ((string=? (agent-scheme-number-value number) "-inf.0")
            (/ -1.0 0.0))
           (else (/ 0.0 0.0))))
         ((number-complex-representation? number)
          (if (number-exact-zero? (cdr (agent-scheme-number-value number)))
              (number->host-float
               (car (agent-scheme-number-value number))
               description)
              (eval-error
               (string-append description " expected real number")
               datum))))))

    ;; Convert a host numeric result to the canonical Agent Scheme number.
    (define (host-number->agent-number number)
      (cond
       ((integer? number)
        (agent-scheme-make-canonical-integer number))
       (else
        (agent-scheme-make-canonical-decimal number))))

    ;; Build an Agent Scheme number from a numerator/denominator pair.
    (define (number-from-rational-pair pair . maybe-exactness)
      (let* ((exactness
              (if (null? maybe-exactness) 'exact (car maybe-exactness)))
             (number
              (agent-scheme-make-canonical-rational
               (car pair)
               (cdr pair)
               exactness
               10)))
        (if (eq? exactness 'inexact)
            (agent-scheme-make-canonical-decimal
             (/ (inexact (car pair)) (inexact (cdr pair))))
            number)))

    ;; Convert NUMBER to an inexact Agent Scheme number.
    (define (number-inexact number)
      (let ((datum (expect-number number "inexact")))
        (cond
         ((or (eq? (agent-scheme-number-kind datum) 'decimal)
              (eq? (agent-scheme-number-kind datum) 'infnan))
          datum)
         ((eq? (agent-scheme-number-kind datum) 'integer)
          (agent-scheme-make-canonical-decimal
           (inexact (agent-scheme-number-value datum))))
         ((eq? (agent-scheme-number-kind datum) 'rational)
          (let ((value (agent-scheme-number-value datum)))
            (agent-scheme-make-canonical-decimal
             (/ (inexact (car value)) (inexact (cdr value))))))
         ((number-complex-representation? datum)
          (let ((value (agent-scheme-number-value datum)))
            (agent-scheme-make-canonical-complex
             (number-inexact (car value))
             (number-inexact (cdr value))))))))

    ;; Reparse an inexact decimal as its exact rational representation.
    (define (decimal->exact-rational-pair number)
      (number->rational-pair
       (agent-scheme-read
        (string-append "#e" (agent-scheme-number->external number)))
       "exact"))

    ;; Convert NUMBER to an exact Agent Scheme number when representable.
    (define (number-exact number)
      (let ((datum (expect-number number "exact")))
        (cond
         ((or (eq? (agent-scheme-number-kind datum) 'integer)
              (eq? (agent-scheme-number-kind datum) 'rational))
          datum)
         ((eq? (agent-scheme-number-kind datum) 'decimal)
          (number-from-rational-pair
           (decimal->exact-rational-pair datum)))
         ((number-complex-representation? datum)
          (let ((value (agent-scheme-number-value datum)))
            (agent-scheme-make-canonical-complex
             (number-exact (car value))
             (number-exact (cdr value)))))
         ((eq? (agent-scheme-number-kind datum) 'infnan)
          (eval-error "exact cannot represent inexact special value" datum)))))

    ;; Return DATUM as a host exact integer or raise a typed error.
    (define (exact-integer->host datum description)
      (if (and (agent-scheme-number? datum)
               (eq? (agent-scheme-number-kind datum) 'integer)
               (eq? (agent-scheme-number-exactness datum) 'exact))
          (agent-scheme-number-value datum)
          (eval-error
           (string-append description " must be an exact integer")
           datum)))

    ;; Validate nonnegative index input and raise an evaluator error on
    ;; mismatch.
    (define (expect-nonnegative-index datum limit description allow-end?)
      (let ((index (exact-integer->host datum description)))
        (if (not (and (<= 0 index)
                      (if allow-end? (<= index limit) (< index limit))))
            (eval-error
             (string-append description " index out of range")
             index))
        index))

    ;; Validate byte input and raise an evaluator error on mismatch.
    (define (expect-byte datum description)
      (let ((byte (exact-integer->host datum description)))
        (if (not (and (<= 0 byte) (<= byte 255)))
            (eval-error
             (string-append description " must be in byte range")
             byte))
        byte))

    ;; Validate string input and raise an evaluator error on mismatch.
    (define (expect-string datum description)
      (if (string? datum)
          datum
          (eval-error (string-append description " must be a string") datum)))

    ;; Validate character input and raise an evaluator error on mismatch.
    (define (expect-character datum description)
      (if (char? datum)
          datum
          (eval-error
           (string-append description " must be a character")
           datum)))

    ;; Validate vector input and raise an evaluator error on mismatch.
    (define (expect-vector datum description)
      (if (vector? datum)
          datum
          (eval-error (string-append description " must be a vector") datum)))

    ;; Validate bytevector input and raise an evaluator error on mismatch.
    (define (expect-bytevector datum description)
      (if (bytevector? datum)
          datum
          (eval-error
           (string-append description " must be a bytevector")
           datum)))

    ;; Validate procedure input and raise an evaluator error on mismatch.
    (define (expect-procedure datum description)
      (if (or (agent-scheme-procedure? datum)
              (agent-scheme-primitive-procedure? datum)
              (agent-scheme-parameter? datum)
              (continuation? datum))
          datum
          (eval-error
           (string-append description " must be a procedure")
           datum)))

    ;; Parse optional start/end indices for sequence operations.
    (define (optional-range arguments offset limit description)
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

    ;; Validate all ARGUMENTS as numbers.
    (define (numeric-arguments arguments description)
      (map (lambda (argument) (expect-number argument description))
           arguments))

    ;; Report whether any number in NUMBERS is inexact.
    (define (any-number-inexact? numbers)
      (let loop ((rest numbers))
        (and (not (null? rest))
             (or (number-inexact? (car rest))
                 (loop (cdr rest))))))

    ;; Apply exact rational arithmetic for one binary operation.
    (define (binary-rational left right operation description)
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

    ;; Handle NaN and infinity cases for inexact binary arithmetic.
    (define (special-inexact-binary left right operation description)
      (cond
       ((or (number-nan? left) (number-nan? right))
        (agent-scheme-make-canonical-infnan "+nan.0"))
       ((or (eq? (agent-scheme-number-kind left) 'infnan)
            (eq? (agent-scheme-number-kind right) 'infnan))
        (let ((left-kind
               (and (eq? (agent-scheme-number-kind left) 'infnan)
                    (agent-scheme-number-value left)))
              (right-kind
               (and (eq? (agent-scheme-number-kind right) 'infnan)
                    (agent-scheme-number-value right))))
          (cond
           ((eq? operation '+)
            (cond
             ((and left-kind right-kind (not (string=? left-kind right-kind)))
              (agent-scheme-make-canonical-infnan "+nan.0"))
             (left-kind left)
             (right-kind right)
             (else #f)))
           ((eq? operation '-)
            (cond
             ((and left-kind right-kind (string=? left-kind right-kind))
              (agent-scheme-make-canonical-infnan "+nan.0"))
             (left-kind left)
             ((and right-kind (string=? right-kind "+inf.0"))
              (agent-scheme-make-canonical-infnan "-inf.0"))
             ((and right-kind (string=? right-kind "-inf.0"))
              (agent-scheme-make-canonical-infnan "+inf.0"))
             (else #f)))
           (else
            (host-number->agent-number
             ((if (eq? operation '*) * /)
              (number->host-float left description)
              (number->host-float right description)))))))
       (else #f)))

    ;; Apply a binary arithmetic operation to real numbers.
    (define (binary-real-number left right operation description)
      (or (special-inexact-binary left right operation description)
          (if (or (number-inexact? left) (number-inexact? right))
              (agent-scheme-make-canonical-decimal
               ((cond
                 ((eq? operation '+) +)
                 ((eq? operation '-) -)
                 ((eq? operation '*) *)
                 (else /))
                (number->host-float left description)
                (number->host-float right description)))
              (binary-rational left right operation description))))

    ;; Apply a binary arithmetic operation to real or complex numbers.
    (define (binary-number left right operation description)
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
              (agent-scheme-make-canonical-complex
               (binary-number a c '+ description)
               (binary-number b d '+ description)))
             ((eq? operation '-)
              (agent-scheme-make-canonical-complex
               (binary-number a c '- description)
               (binary-number b d '- description)))
             ((eq? operation '*)
              (agent-scheme-make-canonical-complex
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
                (if (agent-scheme-number-zero? denominator)
                    (eval-error
                     (string-append description " division by zero")))
                (agent-scheme-make-canonical-complex
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

    ;; Fold a variadic numeric primitive with optional unary inverse behavior.
    (define (fold-numbers arguments identity operation description
                          . maybe-unary-inverse)
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

    ;; Implement the `+' primitive over any number of numeric arguments.
    (define (primitive+ arguments context)
      (fold-numbers
       arguments
       (agent-scheme-make-canonical-integer 0)
       '+
       "+"))

    ;; Implement the `*' primitive over any number of numeric arguments.
    (define (primitive* arguments context)
      (fold-numbers
       arguments
       (agent-scheme-make-canonical-integer 1)
       '*
       "*"))

    ;; Implement the `-' primitive, including unary negation.
    (define (primitive- arguments context)
      (fold-numbers
       arguments
       #f
       '-
       "-"
       (lambda (number)
         (binary-number
          (agent-scheme-make-canonical-integer 0)
          number
          '-
          "-"))))

    ;; Implement the `/' primitive, including unary reciprocal.
    (define (primitive/ arguments context)
      (fold-numbers
       arguments
       #f
       '/
       "/"
       (lambda (number)
         (binary-number
          (agent-scheme-make-canonical-integer 1)
          number
          '/
          "/"))))

    ;; Return NUMBER's real component or reject non-real complex values.
    (define (number-real-part-for-ordering number description)
      (let ((datum (expect-number number description)))
        (if (number-complex-representation? datum)
            (if (number-exact-zero? (cdr (agent-scheme-number-value datum)))
                (car (agent-scheme-number-value datum))
                (eval-error
                 (string-append description " expected real number")
                 datum))
            datum)))

    ;; Compare two Agent Scheme numbers for Scheme numeric equality.
    (define (number=2 left right)
      (cond
       ((or (number-nan? left) (number-nan? right)) #f)
       ((or (number-complex-representation? left)
            (number-complex-representation? right))
        (let ((left-parts (complex-parts left))
              (right-parts (complex-parts right)))
          (and (number=2 (car left-parts) (car right-parts))
               (number=2 (cdr left-parts) (cdr right-parts)))))
       ((or (eq? (agent-scheme-number-kind left) 'infnan)
            (eq? (agent-scheme-number-kind right) 'infnan))
        (and (eq? (agent-scheme-number-kind left) 'infnan)
             (eq? (agent-scheme-number-kind right) 'infnan)
             (string=? (agent-scheme-number-value left)
                       (agent-scheme-number-value right))))
       ((or (number-inexact? left) (number-inexact? right))
        (= (number->host-float left "=")
           (number->host-float right "=")))
       (else
        (let ((left-pair (number->rational-pair left "="))
              (right-pair (number->rational-pair right "=")))
          (= (* (car left-pair) (cdr right-pair))
             (* (car right-pair) (cdr left-pair)))))))

    ;; Compare two real Agent Scheme numbers with PREDICATE.
    (define (number-order2 left right predicate description)
      (let ((ordered-left (number-real-part-for-ordering left description))
            (ordered-right (number-real-part-for-ordering right description)))
        (cond
         ((or (number-nan? ordered-left) (number-nan? ordered-right)) #f)
         ((or (number-inexact? ordered-left)
              (number-inexact? ordered-right)
              (eq? (agent-scheme-number-kind ordered-left) 'infnan)
              (eq? (agent-scheme-number-kind ordered-right) 'infnan))
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

    ;; Implement the `compare` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-compare arguments predicate description)
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

    ;; Implement the `=' primitive over adjacent numeric pairs.
    (define (primitive= arguments context)
      (primitive-compare arguments = "="))

    ;; Implement the `<' primitive over adjacent numeric pairs.
    (define (primitive< arguments context)
      (primitive-compare arguments < "<"))

    ;; Implement the `>' primitive over adjacent numeric pairs.
    (define (primitive> arguments context)
      (primitive-compare arguments > ">"))

    ;; Implement the `<=' primitive over adjacent numeric pairs.
    (define (primitive<= arguments context)
      (primitive-compare arguments <= "<="))

    ;; Implement the `>=' primitive over adjacent numeric pairs.
    (define (primitive>= arguments context)
      (primitive-compare arguments >= ">="))

    ;; Implement the `abs` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-abs arguments context)
      (let ((number (expect-number (car arguments) "abs")))
        (if (number-complex-representation? number)
            (eval-error "abs expected real number" number)
            (agent-scheme-number-abs number))))

    ;; Implement the `min` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-min arguments context)
      (let ((numbers (numeric-arguments arguments "min")))
        (let loop ((best (car numbers)) (rest (cdr numbers)))
          (if (null? rest)
              (if (any-number-inexact? numbers) (number-inexact best) best)
              (loop (if (primitive-compare (list (car rest) best) < "min")
                        (car rest)
                        best)
                    (cdr rest))))))

    ;; Implement the `max` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-max arguments context)
      (let ((numbers (numeric-arguments arguments "max")))
        (let loop ((best (car numbers)) (rest (cdr numbers)))
          (if (null? rest)
              (if (any-number-inexact? numbers) (number-inexact best) best)
              (loop (if (primitive-compare (list (car rest) best) > "max")
                        (car rest)
                        best)
                    (cdr rest))))))

    ;; Implement the `square` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-square arguments context)
      (let ((number (expect-number (car arguments) "square")))
        (binary-number number number '* "square")))

    ;; Implement the `zero?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-zero? arguments context)
      (agent-scheme-number-zero? (expect-number (car arguments) "zero?")))

    ;; Implement the `positive?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-positive? arguments context)
      (primitive-compare
       (list (car arguments) (agent-scheme-make-canonical-integer 0))
       >
       "positive?"))

    ;; Implement the `negative?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-negative? arguments context)
      (primitive-compare
       (list (car arguments) (agent-scheme-make-canonical-integer 0))
       <
       "negative?"))

    ;; Implement the `odd?` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-odd? arguments context)
      (odd? (exact-integer->host (car arguments) "odd?")))

    ;; Implement the `even?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-even? arguments context)
      (even? (exact-integer->host (car arguments) "even?")))

    ;; Return integer quotient rounded toward zero for exact host integers.
    (define (truncate-quotient-value left right)
      (let ((quotient (quotient (abs left) (abs right))))
        (if (= (if (< left 0) -1 1)
               (if (< right 0) -1 1))
            quotient
            (- quotient))))

    ;; Return the remainder paired with truncate-quotient-value.
    (define (truncate-remainder-value left right)
      (- left (* right (truncate-quotient-value left right))))

    ;; Validate two exact integers and apply QUOTIENT-FUNCTION.
    (define (integer-quotient arguments quotient-function description)
      (let ((left (exact-integer->host (car arguments) description))
            (right (exact-integer->host (second arguments) description)))
        (if (zero? right)
            (eval-error (string-append description " division by zero")))
        (agent-scheme-make-canonical-integer
         (quotient-function left right))))

    ;; Implement the `quotient` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-quotient arguments context)
      (integer-quotient arguments truncate-quotient-value "quotient"))

    ;; Implement the `floor-quotient` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-floor-quotient arguments context)
      (integer-quotient arguments floor-quotient "floor-quotient"))

    ;; Implement the `truncate-quotient` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-truncate-quotient arguments context)
      (integer-quotient arguments truncate-quotient-value "truncate-quotient"))

    ;; Implement the `remainder` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-remainder arguments context)
      (let ((left (exact-integer->host (car arguments) "remainder"))
            (right (exact-integer->host (second arguments) "remainder")))
        (if (zero? right)
            (eval-error "remainder division by zero"))
        (agent-scheme-make-canonical-integer
         (truncate-remainder-value left right))))

    ;; Implement the `modulo` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-modulo arguments context)
      (let ((left (exact-integer->host (car arguments) "modulo"))
            (right (exact-integer->host (second arguments) "modulo")))
        (if (zero? right)
            (eval-error "modulo division by zero"))
        (agent-scheme-make-canonical-integer
         (floor-remainder left right))))

    ;; Implement the `floor-remainder` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-floor-remainder arguments context)
      (primitive-modulo arguments context))

    ;; Implement the `truncate-remainder` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-truncate-remainder arguments context)
      (primitive-remainder arguments context))

    ;; Return the mathematical floor of a rational pair.
    (define (floor-rational-pair pair)
      (floor-quotient (car pair) (cdr pair)))

    ;; Return the mathematical ceiling of a rational pair.
    (define (ceiling-rational-pair pair)
      (- (floor-quotient (- (car pair)) (cdr pair))))

    ;; Return a rational pair rounded toward zero.
    (define (truncate-rational-pair pair)
      (let* ((numerator (car pair))
             (denominator (cdr pair))
             (quotient (quotient (abs numerator) denominator)))
        (if (< numerator 0) (- quotient) quotient)))

    ;; Return a rational pair rounded using Scheme's ties-to-even rule.
    (define (round-rational-pair pair)
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

    ;; Implement the `rounding` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-rounding arguments function description)
      (let ((number
             (number-real-part-for-ordering (car arguments) description)))
        (cond
         ((or (eq? (agent-scheme-number-kind number) 'integer)
              (eq? (agent-scheme-number-kind number) 'rational))
          (agent-scheme-make-canonical-integer
           (function (number->rational-pair number description))))
         ((eq? (agent-scheme-number-kind number) 'decimal)
          (agent-scheme-make-canonical-decimal
           (inexact
            (function (decimal->exact-rational-pair number)))))
         ((eq? (agent-scheme-number-kind number) 'infnan)
          number))))

    ;; Implement the `floor` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-floor arguments context)
      (primitive-rounding arguments floor-rational-pair "floor"))

    ;; Implement the `ceiling` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-ceiling arguments context)
      (primitive-rounding arguments ceiling-rational-pair "ceiling"))

    ;; Implement the `truncate` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-truncate arguments context)
      (primitive-rounding arguments truncate-rational-pair "truncate"))

    ;; Implement the `round` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-round arguments context)
      (primitive-rounding arguments round-rational-pair "round"))

    ;; Return DATUM as a host integer, accepting exact and inexact integers.
    (define (integer-argument datum description)
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

    ;; Compute the nonnegative greatest common divisor for exact integers.
    (define (integer-gcd left right)
      (let loop ((a (abs left)) (b (abs right)))
        (if (zero? b) a (loop b (modulo a b)))))

    ;; Compute BASE raised to nonnegative EXPONENT for reader number parsing.
    (define (integer-power base exponent)
      (let loop ((result 1) (factor base) (power exponent))
        (cond
         ((zero? power) result)
         ((odd? power)
          (loop (* result factor) (* factor factor) (quotient power 2)))
         (else
          (loop result (* factor factor) (quotient power 2))))))

    ;; Implement the `gcd` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-gcd arguments context)
      (let loop ((rest (numeric-arguments arguments "gcd"))
                 (result 0)
                 (inexact? #f))
        (if (null? rest)
            (let ((value (agent-scheme-make-canonical-integer result)))
              (if inexact? (number-inexact value) value))
            (loop (cdr rest)
                  (integer-gcd result (integer-argument (car rest) "gcd"))
                  (or inexact? (number-inexact? (car rest)))))))

    ;; Implement the `lcm` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-lcm arguments context)
      (let loop ((rest (numeric-arguments arguments "lcm"))
                 (result 1)
                 (inexact? #f))
        (if (null? rest)
            (let ((value (agent-scheme-make-canonical-integer result)))
              (if inexact? (number-inexact value) value))
            (let ((value (abs (integer-argument (car rest) "lcm"))))
              (loop (cdr rest)
                    (if (or (zero? result) (zero? value))
                        0
                        (quotient (* result value)
                                  (integer-gcd result value)))
                    (or inexact? (number-inexact? (car rest))))))))

    ;; Implement the `numerator` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-numerator arguments context)
      (let* ((number (expect-number (car arguments) "numerator"))
             (pair (if (number-inexact? number)
                       (decimal->exact-rational-pair number)
                       (number->rational-pair number "numerator")))
             (value (agent-scheme-make-canonical-integer (car pair))))
        (if (number-inexact? number) (number-inexact value) value)))

    ;; Implement the `denominator` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-denominator arguments context)
      (let* ((number (expect-number (car arguments) "denominator"))
             (pair (if (number-inexact? number)
                       (decimal->exact-rational-pair number)
                       (number->rational-pair number "denominator")))
             (value (agent-scheme-make-canonical-integer (cdr pair))))
        (if (number-inexact? number) (number-inexact value) value)))

    ;; Implement the `exact` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-exact arguments context)
      (number-exact (car arguments)))

    ;; Implement the `inexact` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-inexact arguments context)
      (number-inexact (car arguments)))

    ;; Implement the `expt` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-expt arguments context)
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
            (agent-scheme-make-canonical-decimal
             (expt (number->host-float base "expt")
                   (number->host-float power "expt"))))))

    ;; Implement the `inexact-unary` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-inexact-unary arguments function description)
      (agent-scheme-make-canonical-decimal
       (function (number->host-float (car arguments) description))))

    ;; Implement the `exp` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-exp arguments context)
      (primitive-inexact-unary arguments exp "exp"))

    ;; Implement the `log` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-log arguments context)
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

    ;; Implement the `sin` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-sin arguments context)
      (primitive-inexact-unary arguments sin "sin"))

    ;; Implement the `cos` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-cos arguments context)
      (primitive-inexact-unary arguments cos "cos"))

    ;; Implement the `tan` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-tan arguments context)
      (primitive-inexact-unary arguments tan "tan"))

    ;; Implement the `asin` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-asin arguments context)
      (primitive-inexact-unary arguments asin "asin"))

    ;; Implement the `acos` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-acos arguments context)
      (primitive-inexact-unary arguments acos "acos"))

    ;; Implement the `atan` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-atan arguments context)
      (if (null? (cdr arguments))
          (primitive-inexact-unary arguments atan "atan")
          (agent-scheme-make-canonical-decimal
           (atan (number->host-float (car arguments) "atan")
                 (number->host-float (second arguments) "atan")))))

    ;; Implement the `sqrt` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-sqrt arguments context)
      (let* ((number (expect-number (car arguments) "sqrt"))
             (value (number->host-float number "sqrt")))
        (if (and (not (number-complex-representation? number))
                 (< value 0.0))
            (agent-scheme-make-canonical-complex
             (agent-scheme-make-canonical-decimal 0.0)
             (agent-scheme-make-canonical-decimal (sqrt (- value))))
            (agent-scheme-make-canonical-decimal (sqrt value)))))

    ;; Return the greatest integer whose square is no larger than VALUE.
    (define (integer-sqrt value)
      (let loop ((low 0) (high (+ value 1)))
        (if (<= (- high low) 1)
            low
            (let ((mid (quotient (+ low high) 2)))
              (if (> (* mid mid) value)
                  (loop low mid)
                  (loop mid high))))))

    ;; Implement the `exact-integer-sqrt` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-exact-integer-sqrt arguments context)
      (let ((value (exact-integer->host
                    (car arguments)
                    "exact-integer-sqrt")))
        (if (< value 0)
            (eval-error
             "exact-integer-sqrt expected non-negative integer"))
        (let ((root (integer-sqrt value)))
          (make-multiple-values
           (list (agent-scheme-make-canonical-integer root)
                 (agent-scheme-make-canonical-integer
                  (- value (* root root))))))))

    ;; Implement the `floor/` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-floor/ arguments context)
      (let ((left (exact-integer->host (car arguments) "floor/"))
            (right (exact-integer->host (second arguments) "floor/")))
        (if (zero? right)
            (eval-error "floor/ division by zero"))
        (let* ((quotient (floor-quotient left right))
               (remainder (- left (* right quotient))))
          (make-multiple-values
           (list (agent-scheme-make-canonical-integer quotient)
                 (agent-scheme-make-canonical-integer remainder))))))

    ;; Implement the `truncate/` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-truncate/ arguments context)
      (let ((left (exact-integer->host (car arguments) "truncate/"))
            (right (exact-integer->host (second arguments) "truncate/")))
        (if (zero? right)
            (eval-error "truncate/ division by zero"))
        (let* ((quotient (truncate-quotient-value left right))
               (remainder (- left (* right quotient))))
          (make-multiple-values
           (list (agent-scheme-make-canonical-integer quotient)
                 (agent-scheme-make-canonical-integer remainder))))))

    ;; Report whether rational pair LEFT is less than RIGHT.
    (define (rational-pair< left right)
      (< (* (car left) (cdr right))
         (* (car right) (cdr left))))

    ;; Normalize a rational pair to positive denominator and lowest terms.
    (define (rational-pair-normalize pair)
      (let* ((numerator (car pair))
             (denominator (cdr pair))
             (adjusted
              (if (< denominator 0)
                  (cons (- numerator) (- denominator))
                  pair))
             (divisor (integer-gcd (car adjusted) (cdr adjusted))))
        (cons (quotient (car adjusted) divisor)
              (quotient (cdr adjusted) divisor))))

    ;; Negate a rational pair without changing its denominator.
    (define (rational-pair-negate pair)
      (cons (- (car pair)) (cdr pair)))

    ;; Add two rational pairs and normalize the result.
    (define (rational-pair+ left right)
      (rational-pair-normalize
       (cons (+ (* (car left) (cdr right))
                (* (car right) (cdr left)))
             (* (cdr left) (cdr right)))))

    ;; Subtract RIGHT from LEFT as rational pairs.
    (define (rational-pair- left right)
      (rational-pair+ left (rational-pair-negate right)))

    ;; Return the reciprocal of a rational pair in normalized form.
    (define (rational-pair-reciprocal pair)
      (rational-pair-normalize (cons (cdr pair) (car pair))))

    ;; Report whether a rational pair has denominator one.
    (define (rational-pair-integer? pair)
      (= (cdr pair) 1))

    ;; Return the simplest nonnegative rational pair in [LOWER, UPPER].
    (define (simplest-positive-rational-pair lower upper)
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

    ;; Return the simplest rational pair in the interval [LOWER, UPPER].
    (define (simplest-rational-pair lower upper)
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

    ;; Return the rationalize result pair for X with tolerance Y.
    (define (rationalize-pair x y)
      (simplest-rational-pair
       (rational-pair- x y)
       (rational-pair+ x y)))

    ;; Implement the `rationalize` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-rationalize arguments context)
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

    ;; Implement the `finite?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-finite? arguments context)
      (number-finite? (expect-number (car arguments) "finite?")))

    ;; Implement the `infinite?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-infinite? arguments context)
      (number-infinite? (expect-number (car arguments) "infinite?")))

    ;; Implement the `nan?` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-nan? arguments context)
      (number-nan? (expect-number (car arguments) "nan?")))

    ;; Implement the `make-rectangular` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-make-rectangular arguments context)
      (agent-scheme-make-canonical-complex
       (expect-number (car arguments) "make-rectangular")
       (expect-number (second arguments) "make-rectangular")))

    ;; Implement the `make-polar` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-make-polar arguments context)
      (let ((magnitude (number->host-float
                        (car arguments)
                        "make-polar"))
            (angle (number->host-float
                    (second arguments)
                    "make-polar")))
        (agent-scheme-make-canonical-complex
         (agent-scheme-make-canonical-decimal
          (* magnitude (cos angle)))
         (agent-scheme-make-canonical-decimal
          (* magnitude (sin angle))))))

    ;; Implement the `real-part` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-real-part arguments context)
      (let ((number (expect-number (car arguments) "real-part")))
        (if (number-complex-representation? number)
            (car (agent-scheme-number-value number))
            number)))

    ;; Implement the `imag-part` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-imag-part arguments context)
      (let ((number (expect-number (car arguments) "imag-part")))
        (if (number-complex-representation? number)
            (cdr (agent-scheme-number-value number))
            (agent-scheme-make-canonical-integer 0))))

    ;; Implement the `magnitude` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-magnitude arguments context)
      (let ((number (expect-number (car arguments) "magnitude")))
        (if (number-complex-representation? number)
            (let* ((parts (agent-scheme-number-value number))
                   (real (number->host-float (car parts) "magnitude"))
                   (imaginary (number->host-float
                               (cdr parts)
                               "magnitude")))
              (agent-scheme-make-canonical-decimal
               (sqrt (+ (* real real) (* imaginary imaginary)))))
            (agent-scheme-number-abs number))))

    ;; Implement the `angle` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-angle arguments context)
      (let ((number (expect-number (car arguments) "angle")))
        (if (number-complex-representation? number)
            (let* ((parts (agent-scheme-number-value number))
                   (real (number->host-float (car parts) "angle"))
                   (imaginary (number->host-float
                               (cdr parts)
                               "angle")))
              (agent-scheme-make-canonical-decimal (atan imaginary real)))
            (if (agent-scheme-number-negative? number)
                (agent-scheme-make-canonical-decimal 3.141592653589793)
                (agent-scheme-make-canonical-decimal 0.0)))))

    ;; Implement the `cons` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-cons arguments context)
      (cons (car arguments) (second arguments)))

    ;; Implement the `car` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-car arguments context)
      (let ((pair (car arguments)))
        (if (pair? pair)
            (car pair)
            (eval-error "car expected pair" pair))))

    ;; Implement the `cdr` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-cdr arguments context)
      (let ((pair (car arguments)))
        (if (pair? pair)
            (cdr pair)
            (eval-error "cdr expected pair" pair))))

    ;; Implement the `list` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-list arguments context)
      arguments)

    ;; Report whether VALUE is a proper, acyclic list.
    (define (proper-list? value)
      (let loop ((cursor value) (seen '()))
        (cond
         ((null? cursor) #t)
         ((not (pair? cursor)) #f)
         ((memq cursor seen) #f)
         (else (loop (cdr cursor) (cons cursor seen))))))

    ;; Implement the `list?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-list? arguments context)
      (proper-list? (car arguments)))

    ;; Implement the `length` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-length arguments context)
      (length (proper-list-elements (car arguments) "length")))

    ;; Implement the `append` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-append arguments context)
      (apply append arguments))

    ;; Implement the `reverse` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-reverse arguments context)
      (reverse (proper-list-elements (car arguments) "reverse")))

    ;; Implement the `list-tail` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-list-tail arguments context)
      (let ((index (exact-integer->host (second arguments) "list-tail")))
        (if (< index 0)
            (eval-error "list-tail index must be non-negative"))
        (let loop ((cursor (car arguments)) (remaining index))
          (cond
           ((zero? remaining) cursor)
           ((pair? cursor) (loop (cdr cursor) (- remaining 1)))
           (else (eval-error "list-tail index exceeds list length"))))))

    ;; Implement the `list-ref` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-list-ref arguments context)
      (let ((tail (primitive-list-tail arguments context)))
        (if (pair? tail)
            (car tail)
            (eval-error "list-ref index exceeds list length"))))

    ;; Implement the `list-set!` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-list-set! arguments context)
      (let ((tail (primitive-list-tail arguments context)))
        (if (not (pair? tail))
            (eval-error "list-set! index exceeds list length"))
        (set-car! tail (third arguments))
        agent-scheme-unspecified))

    ;; Implement the `set-car!` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-set-car! arguments context)
      (let ((pair (car arguments)))
        (if (not (pair? pair))
            (eval-error "set-car! expected pair" pair))
        (set-car! pair (second arguments))
        agent-scheme-unspecified))

    ;; Implement the `set-cdr!` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-set-cdr! arguments context)
      (let ((pair (car arguments)))
        (if (not (pair? pair))
            (eval-error "set-cdr! expected pair" pair))
        (set-cdr! pair (second arguments))
        agent-scheme-unspecified))

    ;; Implement the `make-list` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-make-list arguments context)
      (let ((length (exact-integer->host (car arguments) "make-list"))
            (fill (if (null? (cdr arguments))
                      agent-scheme-unspecified
                      (second arguments))))
        (if (< length 0)
            (eval-error "make-list length must be non-negative"))
        (make-list length fill)))

    ;; Copy a pair spine while preserving any improper tail.
    (define (copy-list value)
      (cond
       ((null? value) '())
       ((pair? value) (cons (car value) (copy-list (cdr value))))
       (else value)))

    ;; Implement the `list-copy` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-list-copy arguments context)
      (copy-list (car arguments)))

    ;; Implement the `caar` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-caar arguments context)
      (primitive-car (list (primitive-car arguments context)) context))

    ;; Implement the `cadr` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-cadr arguments context)
      (primitive-car (list (primitive-cdr arguments context)) context))

    ;; Implement the `cdar` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-cdar arguments context)
      (primitive-cdr (list (primitive-car arguments context)) context))

    ;; Implement the `cddr` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-cddr arguments context)
      (primitive-cdr (list (primitive-cdr arguments context)) context))

    ;; Implement the `null?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-null? arguments context)
      (null? (car arguments)))

    ;; Implement the `pair?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-pair? arguments context)
      (pair? (car arguments)))

    ;; Implement the `not` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-not arguments context)
      (if (eq? (car arguments) #f) #t #f))

    ;; Implement the `boolean?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-boolean? arguments context)
      (boolean? (car arguments)))

    ;; Implement the `boolean=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-boolean=? arguments context)
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

    ;; Implement the `number?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-number? arguments context)
      (agent-scheme-number? (car arguments)))

    ;; Implement the `complex?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-complex? arguments context)
      (agent-scheme-number? (car arguments)))

    ;; Implement the `real?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-real? arguments context)
      (number-real? (car arguments)))

    ;; Implement the `rational?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-rational? arguments context)
      (number-rational? (car arguments)))

    ;; Implement the `integer?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-integer? arguments context)
      (number-integer? (car arguments)))

    ;; Implement the `exact-integer?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-exact-integer? arguments context)
      (and (number-integer? (car arguments))
           (number-exact? (car arguments))))

    ;; Implement the `exact?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-exact? arguments context)
      (number-exact? (car arguments)))

    ;; Implement the `inexact?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-inexact? arguments context)
      (number-inexact? (car arguments)))

    ;; Render NUMBER using RADIX for exact integers and rationals.
    (define (number->string/radix number radix)
      (cond
       ((eq? (agent-scheme-number-kind number) 'integer)
        (agent-scheme-integer->radix-string
         (agent-scheme-number-value number)
         radix))
       ((eq? (agent-scheme-number-kind number) 'rational)
        (let ((value (agent-scheme-number-value number)))
          (string-append
           (agent-scheme-integer->radix-string (car value) radix)
           "/"
           (agent-scheme-integer->radix-string (cdr value) radix))))
       ((or (eq? (agent-scheme-number-kind number) 'decimal)
            (eq? (agent-scheme-number-kind number) 'infnan))
        (if (not (= radix 10))
            (eval-error
             "number->string only supports radix 10 for inexact numbers"))
        (agent-scheme-number->external number))
       ((eq? (agent-scheme-number-kind number) 'complex)
        (if (not (= radix 10))
            (eval-error
             "number->string only supports radix 10 for complex numbers"))
        (agent-scheme-number->external number))))

    ;; Implement the `number->string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-number->string arguments context)
      (let ((number (expect-number (car arguments) "number->string"))
            (radix (if (null? (cdr arguments))
                       10
                       (exact-integer->host
                        (second arguments)
                        "number->string radix"))))
        (if (not (or (= radix 2) (= radix 8) (= radix 10) (= radix 16)))
            (eval-error "number->string radix must be 2, 8, 10, or 16"))
        (number->string/radix number radix)))

    ;; Report whether TEXT begins with an explicit reader radix/exactness
    ;; prefix.
    (define (explicit-number-prefix? text)
      (and (>= (string-length text) 2)
           (char=? (string-ref text 0) #\#)
           (let ((marker (char-downcase (string-ref text 1))))
             (or (char=? marker #\b)
                 (char=? marker #\o)
                 (char=? marker #\d)
                 (char=? marker #\x)
                 (char=? marker #\e)
                 (char=? marker #\i)))))

    ;; Implement the `string->number` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string->number arguments context)
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
          (let ((datum (agent-scheme-read source)))
            (if (agent-scheme-number? datum)
                datum
                #f)))))

    ;; Implement the `string->utf8` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string->utf8 arguments context)
      (let* ((string (expect-string (car arguments) "string->utf8"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string->utf8")))
        (string->utf8 (substring string (car range) (cdr range)))))

    ;; Implement the `utf8->string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-utf8->string arguments context)
      (let* ((bytes (expect-bytevector (car arguments) "utf8->string"))
             (range (optional-range
                     arguments
                     1
                     (bytevector-length bytes)
                     "utf8->string")))
        (utf8->string bytes (car range) (cdr range))))

    ;; Implement the `symbol?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-symbol? arguments context)
      (symbol? (car arguments)))

    ;; Implement the `symbol->string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-symbol->string arguments context)
      (if (not (symbol? (car arguments)))
          (eval-error "symbol->string expected a symbol"))
      (symbol->string (car arguments)))

    ;; Implement the `string->symbol` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string->symbol arguments context)
      (string->symbol (expect-string (car arguments) "string->symbol")))

    ;; Implement the `symbol=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-symbol=? arguments context)
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

    ;; Implement the `char?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char? arguments context)
      (char? (car arguments)))

    ;; Implement the `char->integer` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char->integer arguments context)
      (char->integer
       (expect-character (car arguments) "char->integer")))

    ;; Implement the `integer->char` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-integer->char arguments context)
      (integer->char
       (exact-integer->host (car arguments) "integer->char")))

    ;; Implement the `char-compare` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-compare arguments predicate description)
      (let loop ((rest arguments))
        (cond
         ((or (null? rest) (null? (cdr rest))) #t)
         (else
          (let ((left (expect-character (car rest) description))
                (right (expect-character (second rest) description)))
            (and (predicate left right) (loop (cdr rest))))))))

    ;; Implement the `char=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char=? arguments context)
      (primitive-char-compare arguments char=? "char=?"))

    ;; Implement the `char<?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char<? arguments context)
      (primitive-char-compare arguments char<? "char<?"))

    ;; Implement the `char>?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char>? arguments context)
      (primitive-char-compare arguments char>? "char>?"))

    ;; Implement the `char<=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char<=? arguments context)
      (primitive-char-compare arguments char<=? "char<=?"))

    ;; Implement the `char>=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char>=? arguments context)
      (primitive-char-compare arguments char>=? "char>=?"))

    ;; Implement the `char-upcase` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-upcase arguments context)
      (char-upcase (expect-character (car arguments) "char-upcase")))

    ;; Implement the `char-downcase` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-downcase arguments context)
      (char-downcase (expect-character (car arguments) "char-downcase")))

    ;; Implement the `char-foldcase` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-foldcase arguments context)
      (char-foldcase (expect-character (car arguments) "char-foldcase")))

    ;; Implement the `char-alphabetic?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-alphabetic? arguments context)
      (char-alphabetic? (expect-character
                         (car arguments)
                         "char-alphabetic?")))

    ;; Implement the `char-numeric?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-numeric? arguments context)
      (char-numeric? (expect-character (car arguments) "char-numeric?")))

    ;; Implement the `char-whitespace?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-whitespace? arguments context)
      (char-whitespace? (expect-character
                         (car arguments)
                         "char-whitespace?")))

    ;; Implement the `char-upper-case?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-upper-case? arguments context)
      (char-upper-case? (expect-character
                         (car arguments)
                         "char-upper-case?")))

    ;; Implement the `char-lower-case?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-lower-case? arguments context)
      (char-lower-case? (expect-character
                         (car arguments)
                         "char-lower-case?")))

    ;; Implement the `digit-value` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-digit-value arguments context)
      (let ((value (digit-value
                    (expect-character (car arguments) "digit-value"))))
        (if value
            (agent-scheme-make-canonical-integer value)
            #f)))

    ;; Implement the `char-ci-compare` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-char-ci-compare arguments predicate description)
      (primitive-char-compare
       arguments
       (lambda (left right)
         (predicate (char-foldcase left) (char-foldcase right)))
       description))

    ;; Implement the `char-ci=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-ci=? arguments context)
      (primitive-char-ci-compare arguments char=? "char-ci=?"))

    ;; Implement the `char-ci<?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-ci<? arguments context)
      (primitive-char-ci-compare arguments char<? "char-ci<?"))

    ;; Implement the `char-ci>?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-ci>? arguments context)
      (primitive-char-ci-compare arguments char>? "char-ci>?"))

    ;; Implement the `char-ci<=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-ci<=? arguments context)
      (primitive-char-ci-compare arguments char<=? "char-ci<=?"))

    ;; Implement the `char-ci>=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-ci>=? arguments context)
      (primitive-char-ci-compare arguments char>=? "char-ci>=?"))

    ;; Implement the `string-upcase` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-upcase arguments context)
      (string-upcase (expect-string (car arguments) "string-upcase")))

    ;; Implement the `string-downcase` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-downcase arguments context)
      (string-downcase (expect-string (car arguments) "string-downcase")))

    ;; Implement the `string-foldcase` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-foldcase arguments context)
      (string-foldcase (expect-string (car arguments) "string-foldcase")))

    ;; Implement the `string-ci-compare` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-ci-compare arguments predicate description)
      (primitive-string-compare
       arguments
       (lambda (left right)
         (predicate (string-foldcase left) (string-foldcase right)))
       description))

    ;; Implement the `string-ci=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string-ci=? arguments context)
      (primitive-string-ci-compare arguments string=? "string-ci=?"))

    ;; Implement the `string-ci<?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string-ci<? arguments context)
      (primitive-string-ci-compare arguments string<? "string-ci<?"))

    ;; Implement the `string-ci>?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string-ci>? arguments context)
      (primitive-string-ci-compare arguments string>? "string-ci>?"))

    ;; Implement the `string-ci<=?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-ci<=? arguments context)
      (primitive-string-ci-compare arguments string<=? "string-ci<=?"))

    ;; Implement the `string-ci>=?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-ci>=? arguments context)
      (primitive-string-ci-compare arguments string>=? "string-ci>=?"))

    ;; Render VALUE for display output rather than write output.
    (define (display-string value)
      (agent-scheme-datum->external value 'write #t))

    ;; Validate port input and raise an evaluator error on mismatch.
    (define (expect-port value description)
      (if (not (agent-scheme-port? value))
          (eval-error (string-append description " expected a port") value))
      value)

    ;; Validate open port input and raise an evaluator error on mismatch.
    (define (expect-open-port value description)
      (let ((port (expect-port value description)))
        (if (not (agent-scheme-port-open? port))
            (eval-error
             (string-append description " expected an open port")
             value))
        port))

    ;; Validate input port input and raise an evaluator error on mismatch.
    (define (expect-input-port value description)
      (let ((port (expect-open-port value description)))
        (if (not (agent-scheme-port-input? port))
            (eval-error
             (string-append description " expected an input port")
             value))
        port))

    ;; Validate output port input and raise an evaluator error on mismatch.
    (define (expect-output-port value description)
      (let ((port (expect-open-port value description)))
        (if (not (agent-scheme-port-output? port))
            (eval-error
             (string-append description " expected an output port")
             value))
        port))

    ;; Validate textual input port input and raise an evaluator error on
    ;; mismatch.
    (define (expect-textual-input-port value description)
      (let ((port (expect-input-port value description)))
        (if (not (agent-scheme-port-textual? port))
            (eval-error
             (string-append description " expected a textual input port")
             value))
        port))

    ;; Validate textual output port input and raise an evaluator error on
    ;; mismatch.
    (define (expect-textual-output-port value description)
      (let ((port (expect-output-port value description)))
        (if (not (agent-scheme-port-textual? port))
            (eval-error
             (string-append description " expected a textual output port")
             value))
        port))

    ;; Validate binary input port input and raise an evaluator error on
    ;; mismatch.
    (define (expect-binary-input-port value description)
      (let ((port (expect-input-port value description)))
        (if (not (agent-scheme-port-binary? port))
            (eval-error
             (string-append description " expected a binary input port")
             value))
        port))

    ;; Validate binary output port input and raise an evaluator error on
    ;; mismatch.
    (define (expect-binary-output-port value description)
      (let ((port (expect-output-port value description)))
        (if (not (agent-scheme-port-binary? port))
            (eval-error
             (string-append description " expected a binary output port")
             value))
        port))

    ;; Validate string output port input and raise an evaluator error on
    ;; mismatch.
    (define (expect-string-output-port value description)
      (let ((port (expect-textual-output-port value description)))
        (if (not (eq? (agent-scheme-port-medium port) 'string))
            (eval-error
             (string-append description " expected an output string port")
             value))
        port))

    ;; Validate bytevector output port input and raise an evaluator error on
    ;; mismatch.
    (define (expect-bytevector-output-port value description)
      (let ((port (expect-binary-output-port value description)))
        (if (not (eq? (agent-scheme-port-medium port) 'bytevector))
            (eval-error
             (string-append description
                            " expected an output bytevector port")
             value))
        port))

    ;; Write text to port data through the Agent Scheme port or datum renderer.
    (define (write-text-to-port text port description)
      (let ((output (expect-textual-output-port port description)))
        (if (not (eq? (agent-scheme-port-medium output) 'string))
            (eval-error
             (string-append description
                            " host textual output ports are not available")
             port))
        (set-agent-scheme-port-contents!
         output
         (string-append (agent-scheme-port-contents output) text))
        agent-scheme-unspecified))

    ;; Write to output port data through the Agent Scheme port or datum
    ;; renderer.
    (define (write-to-output-port value port mode display?)
      (write-text-to-port
       (if display?
           (display-string value)
           (agent-scheme-datum->external value mode))
       port
       (if display? "display" "write")))

    ;; Implement the `eof-object?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-eof-object? arguments context)
      (agent-scheme-eof-object? (car arguments)))

    ;; Implement the `eof-object` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-eof-object arguments context)
      agent-scheme-eof-object)

    ;; Implement the `port?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-port? arguments context)
      (agent-scheme-port? (car arguments)))

    ;; Implement the `input-port?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-input-port? arguments context)
      (and (agent-scheme-port? (car arguments))
           (agent-scheme-port-input? (car arguments))))

    ;; Implement the `output-port?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-output-port? arguments context)
      (and (agent-scheme-port? (car arguments))
           (agent-scheme-port-output? (car arguments))))

    ;; Implement the `textual-port?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-textual-port? arguments context)
      (and (agent-scheme-port? (car arguments))
           (agent-scheme-port-textual? (car arguments))))

    ;; Implement the `binary-port?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-binary-port? arguments context)
      (and (agent-scheme-port? (car arguments))
           (agent-scheme-port-binary? (car arguments))))

    ;; Implement the `input-port-open?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-input-port-open? arguments context)
      (let ((port (expect-port (car arguments) "input-port-open?")))
        (and (agent-scheme-port-input? port)
             (agent-scheme-port-open? port))))

    ;; Implement the `output-port-open?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-output-port-open? arguments context)
      (let ((port (expect-port (car arguments) "output-port-open?")))
        (and (agent-scheme-port-output? port)
             (agent-scheme-port-open? port))))

    ;; Mark PORT closed and return the unspecified value.
    (define (close-port-value port)
      (set-agent-scheme-port-open?! port #f)
      agent-scheme-unspecified)

    ;; Implement the `close-port` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-close-port arguments context)
      (close-port-value (expect-port (car arguments) "close-port")))

    ;; Implement the `close-input-port` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-close-input-port arguments context)
      (close-port-value
       (expect-input-port (car arguments) "close-input-port")))

    ;; Implement the `close-output-port` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-close-output-port arguments context)
      (close-port-value
       (expect-output-port (car arguments) "close-output-port")))

    ;; Implement the `open-output-string` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-open-output-string arguments context)
      (make-agent-scheme-port 'string #f #t #t #f #t #f 0 ""))

    ;; Implement the `open-input-string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-open-input-string arguments context)
      (make-agent-scheme-port
       'string #t #f #t #f #t
       (expect-string (car arguments) "open-input-string")
       0 #f))

    ;; Implement the `get-output-string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-get-output-string arguments context)
      (agent-scheme-port-contents
       (expect-string-output-port
        (car arguments)
        "get-output-string")))

    ;; Implement the `open-output-bytevector` primitive with argument
    ;; validation and Agent Scheme values.
    (define (primitive-open-output-bytevector arguments context)
      (make-agent-scheme-port 'bytevector #f #t #f #t #t #f 0 '()))

    ;; Return a fresh bytevector with the same bytes as BYTES.
    (define (copy-bytevector bytes)
      (let* ((length (bytevector-length bytes))
             (copy (make-bytevector length 0)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (bytevector-u8-set! copy index (bytevector-u8-ref bytes index))
                (loop (+ index 1)))))
        copy))

    ;; Implement the `open-input-bytevector` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-open-input-bytevector arguments context)
      (make-agent-scheme-port
       'bytevector #t #f #f #t #t
       (copy-bytevector
        (expect-bytevector (car arguments) "open-input-bytevector"))
       0 #f))

    ;; Convert a list of exact byte values into a bytevector.
    (define (list->bytevector bytes)
      (let ((result (make-bytevector (length bytes) 0)))
        (let loop ((index 0) (rest bytes))
          (if (null? rest)
              result
              (begin
                (bytevector-u8-set! result index (car rest))
                (loop (+ index 1) (cdr rest)))))))

    ;; Implement the `get-output-bytevector` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-get-output-bytevector arguments context)
      (list->bytevector
       (agent-scheme-port-contents
        (expect-bytevector-output-port
         (car arguments)
         "get-output-bytevector"))))

    ;; Implement the `read` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-read arguments context)
      (if (null? arguments)
          agent-scheme-eof-object
          (let* ((port (expect-textual-input-port (car arguments) "read"))
                 (result
                  (agent-scheme-read-from-string-at
                   (agent-scheme-port-source port)
                   (agent-scheme-port-position port))))
            (set-agent-scheme-port-position! port (cdr result))
            (if (agent-scheme-read-eof? (car result))
                agent-scheme-eof-object
                (car result)))))

    ;; Return the next character from PORT, optionally advancing its cursor.
    (define (text-port-next-char port advance? description)
      (let ((input (expect-textual-input-port port description)))
        (if (not (eq? (agent-scheme-port-medium input) 'string))
            (eval-error
             (string-append description
                            " host textual input ports are not available")
             port))
        (let ((position (agent-scheme-port-position input))
              (source (agent-scheme-port-source input)))
          (if (>= position (string-length source))
              agent-scheme-eof-object
              (let ((char (string-ref source position)))
                (if advance?
                    (set-agent-scheme-port-position! input (+ position 1)))
                char)))))

    ;; Implement the `read-char` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-read-char arguments context)
      (if (null? arguments)
          agent-scheme-eof-object
          (text-port-next-char (car arguments) #t "read-char")))

    ;; Implement the `peek-char` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-peek-char arguments context)
      (if (null? arguments)
          agent-scheme-eof-object
          (text-port-next-char (car arguments) #f "peek-char")))

    ;; Implement the `char-ready?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-char-ready? arguments context)
      (if (not (null? arguments))
          (expect-textual-input-port (car arguments) "char-ready?"))
      #t)

    ;; Implement the `read-string` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-read-string arguments context)
      (let ((count (exact-integer->host (car arguments) "read-string"))
            (port (if (null? (cdr arguments))
                      #f
                      (expect-textual-input-port
                       (second arguments)
                       "read-string"))))
        (if (< count 0)
            (eval-error "read-string count must be non-negative"))
        (cond
         ((not port) (if (= count 0) "" agent-scheme-eof-object))
         ((not (eq? (agent-scheme-port-medium port) 'string))
          (eval-error "read-string host textual input ports are not available"))
         (else
          (let* ((source (agent-scheme-port-source port))
                 (position (agent-scheme-port-position port))
                 (remaining (- (string-length source) position))
                 (amount (if (< count remaining) count remaining)))
            (cond
             ((= count 0) "")
             ((= amount 0) agent-scheme-eof-object)
             (else
              (set-agent-scheme-port-position! port (+ position amount))
              (substring source position (+ position amount)))))))))

    ;; Implement the `read-line` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-read-line arguments context)
      (if (null? arguments)
          agent-scheme-eof-object
          (let ((port (expect-textual-input-port
                       (car arguments)
                       "read-line")))
            (if (not (eq? (agent-scheme-port-medium port) 'string))
                (eval-error
                 "read-line host textual input ports are not available"))
            (let* ((source (agent-scheme-port-source port))
                   (start (agent-scheme-port-position port))
                   (length (string-length source)))
              (let loop ((position start))
                (if (and (< position length)
                         (not (or (char=? (string-ref source position)
                                           #\newline)
                                  (char=? (string-ref source position)
                                           #\return))))
                    (loop (+ position 1))
                    (if (and (= start position) (>= position length))
                        agent-scheme-eof-object
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
                          (set-agent-scheme-port-position! port position)
                          line))))))))

    ;; Write byte to port data through the Agent Scheme port or datum renderer.
    (define (write-byte-to-port byte port description)
      (let ((output (expect-binary-output-port port description)))
        (if (not (eq? (agent-scheme-port-medium output) 'bytevector))
            (eval-error
             (string-append description
                            " host binary output ports are not available")
             port))
        (set-agent-scheme-port-contents!
         output
         (append (agent-scheme-port-contents output) (list byte)))
        agent-scheme-unspecified))

    ;; Implement the `read-u8` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-read-u8 arguments context)
      (if (null? arguments)
          agent-scheme-eof-object
          (let* ((port (expect-binary-input-port (car arguments) "read-u8"))
                 (source (agent-scheme-port-source port))
                 (position (agent-scheme-port-position port)))
            (if (not (eq? (agent-scheme-port-medium port) 'bytevector))
                (eval-error
                 "read-u8 host binary input ports are not available"))
            (if (>= position (bytevector-length source))
                agent-scheme-eof-object
                (begin
                  (set-agent-scheme-port-position! port (+ position 1))
                  (host-number->agent-number
                   (bytevector-u8-ref source position)))))))

    ;; Implement the `peek-u8` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-peek-u8 arguments context)
      (if (null? arguments)
          agent-scheme-eof-object
          (let* ((port (expect-binary-input-port (car arguments) "peek-u8"))
                 (source (agent-scheme-port-source port))
                 (position (agent-scheme-port-position port)))
            (if (not (eq? (agent-scheme-port-medium port) 'bytevector))
                (eval-error
                 "peek-u8 host binary input ports are not available"))
            (if (>= position (bytevector-length source))
                agent-scheme-eof-object
                (host-number->agent-number
                 (bytevector-u8-ref source position))))))

    ;; Implement the `u8-ready?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-u8-ready? arguments context)
      (if (not (null? arguments))
          (expect-binary-input-port (car arguments) "u8-ready?"))
      #t)

    ;; Return SOURCE bytes in the half-open range [START, END).
    (define (subbytevector source start end)
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

    ;; Implement the `read-bytevector` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-read-bytevector arguments context)
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
          (if (= count 0) (make-bytevector 0 0) agent-scheme-eof-object))
         ((not (eq? (agent-scheme-port-medium port) 'bytevector))
          (eval-error "read-bytevector host binary input ports are not available"))
         (else
          (let* ((source (agent-scheme-port-source port))
                 (position (agent-scheme-port-position port))
                 (remaining (- (bytevector-length source) position))
                 (amount (if (< count remaining) count remaining)))
            (cond
             ((= count 0) (make-bytevector 0 0))
             ((= amount 0) agent-scheme-eof-object)
             (else
              (set-agent-scheme-port-position! port (+ position amount))
              (subbytevector source position (+ position amount)))))))))

    ;; Implement the `read-bytevector!` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-read-bytevector! arguments context)
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
            agent-scheme-eof-object
            (let* ((source (agent-scheme-port-source port))
                   (position (agent-scheme-port-position port))
                   (capacity (- end start))
                   (remaining (- (bytevector-length source) position))
                   (amount (if (< capacity remaining) capacity remaining)))
              (if (= amount 0)
                  agent-scheme-eof-object
                  (begin
                    (let loop ((offset 0))
                      (if (< offset amount)
                          (begin
                            (bytevector-u8-set!
                             target
                             (+ start offset)
                             (bytevector-u8-ref source (+ position offset)))
                            (loop (+ offset 1)))))
                    (set-agent-scheme-port-position! port (+ position amount))
                    (host-number->agent-number amount)))))))

    ;; Implement the `write-u8` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-write-u8 arguments context)
      (if (not (null? (cdr arguments)))
          (write-byte-to-port
           (expect-byte (car arguments) "write-u8")
           (second arguments)
           "write-u8"))
      agent-scheme-unspecified)

    ;; Implement the `write-bytevector` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-write-bytevector arguments context)
      (if (not (null? (cdr arguments)))
          (let* ((bytes (expect-bytevector
                         (car arguments)
                         "write-bytevector"))
                 (range (optional-range arguments
                                        2
                                        (bytevector-length bytes)
                                        "write-bytevector")))
            (let loop ((index (car range)))
              (if (< index (cdr range))
                  (begin
                    (write-byte-to-port
                     (bytevector-u8-ref bytes index)
                     (second arguments)
                     "write-bytevector")
                    (loop (+ index 1)))))))
      agent-scheme-unspecified)

    ;; Implement the `write-char` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-write-char arguments context)
      (if (not (null? (cdr arguments)))
          (write-text-to-port
           (string (expect-character (car arguments) "write-char"))
           (second arguments)
           "write-char"))
      agent-scheme-unspecified)

    ;; Implement the `write-string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-write-string arguments context)
      (if (not (null? (cdr arguments)))
          (let* ((string (expect-string (car arguments) "write-string"))
                 (range (optional-range arguments
                                        2
                                        (string-length string)
                                        "write-string")))
            (write-text-to-port
             (substring string (car range) (cdr range))
             (second arguments)
             "write-string")))
      agent-scheme-unspecified)

    ;; Implement the `newline` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-newline arguments context)
      (if (not (null? arguments))
          (write-text-to-port "\n" (car arguments) "newline"))
      agent-scheme-unspecified)

    ;; Implement the `display` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-display arguments context)
      (if (null? (cdr arguments))
          agent-scheme-unspecified
          (write-to-output-port (car arguments) (second arguments) 'write #t)))

    ;; Implement the `write` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-write arguments context)
      (if (null? (cdr arguments))
          agent-scheme-unspecified
          (write-to-output-port (car arguments) (second arguments) 'write #f)))

    ;; Implement the `write-shared` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-write-shared arguments context)
      (if (null? (cdr arguments))
          agent-scheme-unspecified
          (write-to-output-port (car arguments) (second arguments) 'shared #f)))

    ;; Implement the `write-simple` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-write-simple arguments context)
      (if (null? (cdr arguments))
          agent-scheme-unspecified
          (write-to-output-port (car arguments) (second arguments) 'simple #f)))

    ;; Implement the `flush-output-port` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-flush-output-port arguments context)
      (if (not (null? arguments))
          (expect-output-port (car arguments) "flush-output-port"))
      agent-scheme-unspecified)

    ;; Implement the `read-error?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-read-error? arguments context)
      #f)

    ;; Implement the `file-error?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-file-error? arguments context)
      #f)

    ;; Implement the `features` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-features arguments context)
      '(r7rs ratios exact-complex ieee-float agent-scheme))

    ;; Raise a policy-gated host-access denial for DESCRIPTION.
    (define (policy-denied description)
      (eval-error
       (string-append description " requires policy-gated host access")))

    ;; Return a primitive callback that always raises a policy denial.
    (define (policy-denied-primitive description)
      (lambda (arguments context)
        (policy-denied description)))

    ;; Resolve FILENAME and enforce the file-operation allow-list policy.
    (define (resolve-file-policy-path filename context description)
      (let ((path (path-join (context-include-directory context) filename)))
        (cond
         ((null? (context-file-paths context))
          (eval-error
           (string-append description
                          " requires policy-gated host file access")
           filename))
         ((not (path-policy-allows-file? path (context-file-paths context)))
          (eval-error
           (string-append description " file is not allowed by policy")
           filename))
         (else path))))

    ;; Implement the `file-exists?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-file-exists? arguments context)
      (let ((path
             (resolve-file-policy-path
              (expect-string (car arguments) "file-exists?")
              context
              "file-exists?")))
        (file-exists? path)))

    ;; Implement the `delete-file` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-delete-file arguments context)
      (expect-string (car arguments) "delete-file")
      (policy-denied "delete-file"))

    ;; Implement the `call-with-port` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-call-with-port arguments context)
      (drain-state
       (primitive-call-with-port/k
        arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `call-with-port` primitive for
    ;; trampoline evaluation.
    (define (primitive-call-with-port/k arguments context continuation)
      (let ((port (expect-port (car arguments) "call-with-port port"))
            (procedure
             (expect-procedure (second arguments) "call-with-port procedure")))
        (apply-procedure
         procedure
         (list port)
         context
         #t
         (lambda (value)
           (close-port-value port)
           (continue continuation value)))))

    ;; Implement the `environment` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-environment arguments context)
      (let ((environment (agent-scheme-make-empty-environment))
            (syntax-environment (make-syntax-environment '() #f '())))
        (with-syntax-environment
         context
         syntax-environment
         (lambda ()
           (eval-import (cons 'import arguments) environment context)))
        (make-environment-specifier environment syntax-environment #t)))

    ;; Validate environment specifier input and raise an evaluator error on
    ;; mismatch.
    (define (expect-environment-specifier value description)
      (if (not (environment-specifier? value))
          (eval-error
           (string-append description " expected an environment specifier")
           value))
      value)

    ;; Report whether FORM mutates an evaluation environment.
    (define (eval-form-mutates-environment? form)
      (or (import-form? form)
          (define-library-form? form)
          (syntax-definition-form? form)
          (record-definition-form? form)
          (definition-form? form)))

    ;; Implement the `eval` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-eval arguments context)
      (drain-state
       (primitive-eval/k arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `eval` primitive for trampoline
    ;; evaluation.
    (define (primitive-eval/k arguments context continuation)
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

    ;; Read policy-approved source file forms and return forms plus directory.
    (define (read-policy-file-forms filename context description)
      (let ((path (resolve-file-policy-path filename context description)))
        (if (not (file-exists? path))
            (eval-error
             (string-append description " file is not readable")
             filename))
        (cons (agent-scheme-read-all (read-file-string path))
              (path-directory path))))

    ;; Return the value and syntax environments targeted by load.
    (define (load-target arguments context)
      (if (not (null? (cdr arguments)))
          (let ((specifier
                 (expect-environment-specifier (second arguments) "load")))
            (if (environment-specifier-immutable? specifier)
                (eval-error
                 "load cannot mutate an immutable environment"))
            (cons (environment-specifier-environment specifier)
                  (environment-specifier-syntax-environment specifier)))
          (cons (or (context-interaction-environment context)
                    (agent-scheme-make-base-environment))
                (context-syntax-environment context))))

    ;; Implement the `load` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-load arguments context)
      (drain-state
       (primitive-load/k arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `load` primitive for trampoline
    ;; evaluation.
    (define (primitive-load/k arguments context continuation)
      (let* ((filename (expect-string (car arguments) "load"))
             (read-result
              (read-policy-file-forms filename context "load"))
             (target (load-target arguments context)))
        (with-include-directory
         context
         (cdr read-result)
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
                 (continue continuation agent-scheme-unspecified)))))))))

    ;; Implement the `string?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string? arguments context)
      (string? (car arguments)))

    ;; Implement the `make-string` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-make-string arguments context)
      (let ((length (exact-integer->host (car arguments) "make-string"))
            (fill (if (null? (cdr arguments))
                      #\null
                      (expect-character
                       (second arguments)
                       "make-string fill"))))
        (if (< length 0)
            (eval-error "make-string length must be non-negative"))
        (make-string length fill)))

    ;; Implement the `string` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string arguments context)
      (list->string
       (map (lambda (argument)
              (expect-character argument "string"))
            arguments)))

    ;; Implement the `string-length` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-length arguments context)
      (string-length (expect-string (car arguments) "string-length")))

    ;; Implement the `string-ref` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string-ref arguments context)
      (let* ((string (expect-string (car arguments) "string-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (string-length string)
                     "string-ref"
                     #f)))
        (string-ref string index)))

    ;; Implement the `string-set!` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string-set! arguments context)
      (let* ((string (expect-string (car arguments) "string-set!"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (string-length string)
                     "string-set!"
                     #f))
             (char (expect-character (third arguments) "string-set! value")))
        (string-set! string index char)
        agent-scheme-unspecified))

    ;; Implement the `substring` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-substring arguments context)
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
        (substring string start end)))

    ;; Implement the `string-append` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-append arguments context)
      (apply string-append
             (map (lambda (argument)
                    (expect-string argument "string-append"))
                  arguments)))

    ;; Implement the `string->list` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string->list arguments context)
      (let* ((string (expect-string (car arguments) "string->list"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string->list")))
        (let loop ((index (car range)) (result '()))
          (if (= index (cdr range))
              (reverse result)
              (loop (+ index 1)
                    (cons (string-ref string index) result))))))

    ;; Implement the `list->string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-list->string arguments context)
      (list->string
       (map (lambda (argument)
              (expect-character argument "list->string"))
            (proper-list-elements (car arguments) "list->string"))))

    ;; Implement the `string->vector` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string->vector arguments context)
      (list->vector (primitive-string->list arguments context)))

    ;; Implement the `vector->string` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-vector->string arguments context)
      (let* ((vector (expect-vector (car arguments) "vector->string"))
             (range (optional-range
                     arguments
                     1
                     (vector-length vector)
                     "vector->string")))
        (let loop ((index (car range)) (result '()))
          (if (= index (cdr range))
              (list->string (reverse result))
              (loop (+ index 1)
                    (cons (expect-character
                           (vector-ref vector index)
                           "vector->string")
                          result))))))

    ;; Implement the `string-copy` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string-copy arguments context)
      (let* ((string (expect-string (car arguments) "string-copy"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string-copy")))
        (substring string (car range) (cdr range))))

    ;; Implement the `string-copy!` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-copy! arguments context)
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
        agent-scheme-unspecified))

    ;; Implement the `string-fill!` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-fill! arguments context)
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
        agent-scheme-unspecified))

    ;; Implement the `string-compare` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-string-compare arguments predicate description)
      (let loop ((rest arguments))
        (cond
         ((or (null? rest) (null? (cdr rest))) #t)
         (else
          (let ((left (expect-string (car rest) description))
                (right (expect-string (second rest) description)))
            (and (predicate left right) (loop (cdr rest))))))))

    ;; Implement the `string=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string=? arguments context)
      (primitive-string-compare arguments string=? "string=?"))

    ;; Implement the `string<?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string<? arguments context)
      (primitive-string-compare arguments string<? "string<?"))

    ;; Implement the `string>?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string>? arguments context)
      (primitive-string-compare arguments string>? "string>?"))

    ;; Implement the `string<=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string<=? arguments context)
      (primitive-string-compare arguments string<=? "string<=?"))

    ;; Implement the `string>=?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-string>=? arguments context)
      (primitive-string-compare arguments string>=? "string>=?"))

    ;; Apply PROCEDURE over LISTS, collecting results only when requested.
    (define (map-over-lists procedure lists context keep-results?)
      (let loop ((cursors lists) (results '()))
        (cond
         ((let any-empty? ((rest cursors))
            (cond
             ((null? rest) #f)
             ((null? (car rest)) #t)
             (else (any-empty? (cdr rest)))))
          (if keep-results? (reverse results) agent-scheme-unspecified))
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

    ;; Implement the `apply` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-apply arguments context)
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

    ;; Apply a parameter procedure in continuation-passing form.
    (define (apply-parameter/k parameter arguments context continuation)
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
           (continue continuation agent-scheme-unspecified))))
       (else
        (set-parameter-value! parameter (car arguments))
        (continue continuation agent-scheme-unspecified))))

    ;; Implement the `make-parameter` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-make-parameter arguments context)
      (drain-state
       (primitive-make-parameter/k
        arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `make-parameter` primitive for
    ;; trampoline evaluation.
    (define (primitive-make-parameter/k arguments context continuation)
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
                  (make-parameter
                   (single-value converted "make-parameter converter")
                   converter)))))
            (continue continuation (make-parameter initial #f)))))

    ;; Continuation-aware implementation of the `apply` primitive for
    ;; trampoline evaluation.
    (define (primitive-apply/k arguments context continuation)
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

    ;; Implement the `values` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-values arguments context)
      (make-multiple-values arguments))

    ;; Implement the `call-with-values` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-call-with-values arguments context)
      (let* ((producer (expect-procedure
                        (car arguments)
                        "call-with-values producer"))
             (consumer (expect-procedure
                        (second arguments)
                        "call-with-values consumer"))
             (produced (apply-procedure producer '() context #f)))
        (apply-procedure consumer (values-list produced) context #f)))

    ;; Continuation-aware implementation of the `call-with-values` primitive
    ;; for trampoline evaluation.
    (define (primitive-call-with-values/k
             arguments context continuation)
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

    ;; Implement the `call/cc` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-call/cc arguments context)
      (drain-state
       (primitive-call/cc/k
        arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `call/cc` primitive for
    ;; trampoline evaluation.
    (define (primitive-call/cc/k arguments context continuation)
      (let* ((procedure
              (expect-procedure
               (car arguments)
               "call-with-current-continuation procedure"))
             (captured
              (make-continuation
               continuation
               (append (context-dynamic-winds context) '())
               (append (context-exception-handlers context) '()))))
        (apply-procedure
         procedure
         (list captured)
         context
         #t
         continuation)))

    ;; Restore a captured continuation's dynamic context and pass arguments.
    (define (invoke-continuation continuation arguments context)
      (switch-dynamic-winds!
       (continuation-dynamic-winds continuation)
       context)
      (set-context-exception-handlers!
       context
       (append (continuation-exception-handlers continuation) '()))
      (continue
       (continuation-procedure continuation)
       (continuation-value arguments)))

    ;; Implement the `dynamic-wind` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-dynamic-wind arguments context)
      (drain-state
       (primitive-dynamic-wind/k
        arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `dynamic-wind` primitive for
    ;; trampoline evaluation.
    (define (primitive-dynamic-wind/k arguments context continuation)
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

    ;; Invoke the current exception handler and drain its trampoline state.
    (define (invoke-exception-handler condition context)
      (drain-state
       (invoke-exception-handler/k
        condition context identity-continuation)
       context))

    ;; Invoke the current exception handler in continuation-passing form.
    (define (invoke-exception-handler/k
             condition context continuation)
      (let ((handlers (context-exception-handlers context)))
        (if (null? handlers)
            (eval-error
             "unhandled exception"
             (agent-scheme-value->external condition)))
        (set-context-exception-handlers! context (cdr handlers))
        (apply-procedure
         (car handlers)
         (list condition)
         context
         #t
         (lambda (value)
           (set-context-exception-handlers! context handlers)
           (continue continuation value)))))

    ;; Implement the `with-exception-handler` primitive with argument
    ;; validation and Agent Scheme values.
    (define (primitive-with-exception-handler arguments context)
      (drain-state
       (primitive-with-exception-handler/k
        arguments context identity-continuation)
       context))

    ;; Continuation-aware implementation of the `with-exception-handler`
    ;; primitive for trampoline evaluation.
    (define (primitive-with-exception-handler/k
             arguments context continuation)
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

    ;; Implement the `raise-continuable` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-raise-continuable arguments context)
      (invoke-exception-handler (car arguments) context))

    ;; Continuation-aware implementation of the `raise-continuable` primitive
    ;; for trampoline evaluation.
    (define (primitive-raise-continuable/k
             arguments context continuation)
      (invoke-exception-handler/k
       (car arguments) context continuation))

    ;; Implement the `raise` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-raise arguments context)
      (invoke-exception-handler (car arguments) context)
      (eval-error "non-continuable exception handler returned"))

    ;; Continuation-aware implementation of the `raise` primitive for
    ;; trampoline evaluation.
    (define (primitive-raise/k arguments context continuation)
      (invoke-exception-handler/k
       (car arguments)
       context
       (lambda (value)
         (eval-error
          "non-continuable exception handler returned"))))

    ;; Implement the `error` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-error arguments context)
      (let ((message (expect-string (car arguments) "error message"))
            (irritants (cdr arguments)))
        (primitive-raise
         (list (make-agent-scheme-error-object message irritants))
         context)))

    ;; Continuation-aware implementation of the `error` primitive for
    ;; trampoline evaluation.
    (define (primitive-error/k arguments context continuation)
      (let ((message (expect-string (car arguments) "error message"))
            (irritants (cdr arguments)))
        (primitive-raise/k
         (list (make-agent-scheme-error-object message irritants))
         context
         continuation)))

    ;; Implement the `error-object?` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-error-object? arguments context)
      (agent-scheme-error-object? (car arguments)))

    ;; Validate error object input and raise an evaluator error on mismatch.
    (define (expect-error-object value description)
      (if (agent-scheme-error-object? value)
          value
          (eval-error
           (string-append description " expected an error object")
           value)))

    ;; Implement the `error-object-message` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-error-object-message arguments context)
      (agent-scheme-error-object-message
       (expect-error-object (car arguments) "error-object-message")))

    ;; Implement the `error-object-irritants` primitive with argument
    ;; validation and Agent Scheme values.
    (define (primitive-error-object-irritants arguments context)
      (agent-scheme-error-object-irritants
       (expect-error-object (car arguments) "error-object-irritants")))

    ;; Implement the `map` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-map arguments context)
      (map-over-lists
       (expect-procedure (car arguments) "map procedure")
       (cdr arguments)
       context
       #t))

    ;; Implement the `for-each` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-for-each arguments context)
      (map-over-lists
       (expect-procedure (car arguments) "for-each procedure")
       (cdr arguments)
       context
       #f))

    ;; Implement the `vector?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-vector? arguments context)
      (vector? (car arguments)))

    ;; Implement the `make-vector` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-make-vector arguments context)
      (let ((length (exact-integer->host (car arguments) "make-vector"))
            (fill (if (null? (cdr arguments))
                      agent-scheme-unspecified
                      (second arguments))))
        (if (< length 0)
            (eval-error "make-vector length must be non-negative"))
        (make-vector length fill)))

    ;; Implement the `vector` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-vector arguments context)
      (list->vector arguments))

    ;; Implement the `vector-length` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-vector-length arguments context)
      (vector-length (expect-vector (car arguments) "vector-length")))

    ;; Implement the `vector-ref` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-vector-ref arguments context)
      (let* ((vector (expect-vector (car arguments) "vector-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (vector-length vector)
                     "vector-ref"
                     #f)))
        (vector-ref vector index)))

    ;; Implement the `vector-set!` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-vector-set! arguments context)
      (let* ((vector (expect-vector (car arguments) "vector-set!"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (vector-length vector)
                     "vector-set!"
                     #f)))
        (vector-set! vector index (third arguments))
        agent-scheme-unspecified))

    ;; Implement the `vector->list` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-vector->list arguments context)
      (let* ((vector (expect-vector (car arguments) "vector->list"))
             (range (optional-range
                     arguments
                     1
                     (vector-length vector)
                     "vector->list")))
        (let loop ((index (car range)) (result '()))
          (if (= index (cdr range))
              (reverse result)
              (loop (+ index 1)
                    (cons (vector-ref vector index) result))))))

    ;; Implement the `list->vector` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-list->vector arguments context)
      (list->vector
       (proper-list-elements (car arguments) "list->vector")))

    ;; Implement the `vector-copy` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-vector-copy arguments context)
      (list->vector (primitive-vector->list arguments context)))

    ;; Implement the `vector-copy!` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-vector-copy! arguments context)
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
        agent-scheme-unspecified))

    ;; Implement the `vector-append` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-vector-append arguments context)
      (list->vector
       (apply append
              (map (lambda (argument)
                     (vector->list
                      (expect-vector argument "vector-append")))
                   arguments))))

    ;; Implement the `vector-fill!` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-vector-fill! arguments context)
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
        agent-scheme-unspecified))

    ;; Implement the `bytevector?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-bytevector? arguments context)
      (bytevector? (car arguments)))

    ;; Implement the `make-bytevector` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-make-bytevector arguments context)
      (let ((length (exact-integer->host (car arguments) "make-bytevector"))
            (fill (if (null? (cdr arguments))
                      0
                      (expect-byte
                       (second arguments)
                       "make-bytevector fill"))))
        (if (< length 0)
            (eval-error "make-bytevector length must be non-negative"))
        (make-bytevector length fill)))

    ;; Implement the `bytevector` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-bytevector arguments context)
      (apply bytevector
             (map (lambda (argument)
                    (expect-byte argument "bytevector"))
                  arguments)))

    ;; Implement the `bytevector-length` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-bytevector-length arguments context)
      (bytevector-length
       (expect-bytevector (car arguments) "bytevector-length")))

    ;; Implement the `bytevector-u8-ref` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-bytevector-u8-ref arguments context)
      (let* ((bytevector
              (expect-bytevector
               (car arguments)
               "bytevector-u8-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (bytevector-length bytevector)
                     "bytevector-u8-ref"
                     #f)))
        (bytevector-u8-ref bytevector index)))

    ;; Implement the `bytevector-u8-set!` primitive with argument validation
    ;; and Agent Scheme values.
    (define (primitive-bytevector-u8-set! arguments context)
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
        agent-scheme-unspecified))

    ;; Implement the `bytevector-copy` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-bytevector-copy arguments context)
      (let* ((bytevector
              (expect-bytevector (car arguments) "bytevector-copy"))
             (range (optional-range
                     arguments
                     1
                     (bytevector-length bytevector)
                     "bytevector-copy")))
        (bytevector-copy bytevector (car range) (cdr range))))

    ;; Implement the `bytevector-copy!` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-bytevector-copy! arguments context)
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
        agent-scheme-unspecified))

    ;; Implement the `bytevector-append` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-bytevector-append arguments context)
      (apply bytevector-append
             (map (lambda (argument)
                    (expect-bytevector argument "bytevector-append"))
                  arguments)))

    ;; Implement the `procedure?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-procedure? arguments context)
      (or (agent-scheme-procedure? (car arguments))
          (agent-scheme-primitive-procedure? (car arguments))
          (agent-scheme-parameter? (car arguments))
          (continuation? (car arguments))))

    ;; Report whether two numbers share kind, exactness, and stored value.
    (define (numeric-representation-eqv? left right)
      (and (agent-scheme-number? left)
           (agent-scheme-number? right)
           (eq? (agent-scheme-number-kind left)
                (agent-scheme-number-kind right))
           (eq? (agent-scheme-number-exactness left)
                (agent-scheme-number-exactness right))
           (if (and (number-complex-representation? left)
                    (number-complex-representation? right))
               (and (numeric-representation-eqv?
                     (car (agent-scheme-number-value left))
                     (car (agent-scheme-number-value right)))
                    (numeric-representation-eqv?
                     (cdr (agent-scheme-number-value left))
                     (cdr (agent-scheme-number-value right))))
               (equal? (agent-scheme-number-value left)
                       (agent-scheme-number-value right)))))

    ;; Implement eqv? comparison with Agent Scheme numeric representation.
    (define (eqv-value? left right)
      (if (and (agent-scheme-number? left) (agent-scheme-number? right))
          (numeric-representation-eqv? left right)
          (eqv? left right)))

    ;; Implement eq? comparison with canonical-number identity semantics.
    (define (eq-value? left right)
      (or (eq? left right)
          (and (agent-scheme-number? left)
               (agent-scheme-number? right)
               (numeric-representation-eqv? left right))))

    ;; Report whether LEFT/RIGHT was already visited during equal? traversal.
    (define (equal-seen-pair? left right seen)
      (cond
       ((null? seen) #f)
       ((and (eq? left (caar seen))
             (eq? right (cdar seen)))
        #t)
       (else
        (equal-seen-pair? left right (cdr seen)))))

    ;; Implement equal? comparison with cycle detection for pairs and vectors.
    (define (equal-value? left right seen)
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
       ((or (agent-scheme-record? left)
            (agent-scheme-record? right)
            (agent-scheme-record-type? left)
            (agent-scheme-record-type? right))
        #f)
       (else
        (equal? left right))))

    ;; Implement the `eq?` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-eq? arguments context)
      (eq-value? (car arguments) (second arguments)))

    ;; Implement the `eqv?` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-eqv? arguments context)
      (eqv-value? (car arguments) (second arguments)))

    ;; Implement the `equal?` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-equal? arguments context)
      (equal-value? (car arguments) (second arguments) '()))

    ;; Implement the `memq` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-memq arguments context)
      (let ((result (memq (car arguments) (second arguments))))
        (if result result #f)))

    ;; Implement the `memv` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-memv arguments context)
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((eqv-value? (car arguments) (car cursor)) cursor)
         (else (loop (cdr cursor))))))

    ;; Implement the `member` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-member arguments context)
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((equal-value? (car arguments) (car cursor) '()) cursor)
         (else (loop (cdr cursor))))))

    ;; Implement the `assq` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-assq arguments context)
      (let ((result (assq (car arguments) (second arguments))))
        (if result result #f)))

    ;; Implement the `assv` primitive with argument validation and Agent Scheme
    ;; values.
    (define (primitive-assv arguments context)
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((and (pair? (car cursor))
               (eqv-value? (car arguments) (caar cursor)))
          (car cursor))
         (else (loop (cdr cursor))))))

    ;; Implement the `assoc` primitive with argument validation and Agent
    ;; Scheme values.
    (define (primitive-assoc arguments context)
      (let loop ((cursor (second arguments)))
        (cond
         ((null? cursor) #f)
         ((not (pair? cursor)) #f)
         ((and (pair? (car cursor))
               (equal-value? (car arguments) (caar cursor) '()))
          (car cursor))
         (else (loop (cdr cursor))))))

    ;; Registry mapping primitive names to implementation procedures and
    ;; arities.
    (define base-primitive-registry
      ;; Each entry is `(name procedure minimum-arity maximum-arity)'.  A false
      ;; maximum means the primitive accepts arbitrarily many arguments.
      (list
       (list '* primitive* 0 #f)
       (list '+ primitive+ 0 #f)
       (list '- primitive- 1 #f)
       (list '/ primitive/ 1 #f)
       (list '< primitive< 2 #f)
       (list '<= primitive<= 2 #f)
       (list '= primitive= 2 #f)
       (list '> primitive> 2 #f)
       (list '>= primitive>= 2 #f)
       (list 'apply primitive-apply 2 #f)
       (list 'binary-port? primitive-binary-port? 1 1)
       (list 'boolean=? primitive-boolean=? 2 #f)
       (list 'boolean? primitive-boolean? 1 1)
       (list 'bytevector primitive-bytevector 0 #f)
       (list 'bytevector-append primitive-bytevector-append 0 #f)
       (list 'bytevector-copy primitive-bytevector-copy 1 3)
       (list 'bytevector-copy! primitive-bytevector-copy! 3 5)
       (list 'bytevector-length primitive-bytevector-length 1 1)
       (list 'bytevector-u8-ref primitive-bytevector-u8-ref 2 2)
       (list 'bytevector-u8-set! primitive-bytevector-u8-set! 3 3)
       (list 'bytevector? primitive-bytevector? 1 1)
       (list 'call-with-current-continuation primitive-call/cc 1 1)
       (list 'call-with-port primitive-call-with-port 2 2)
       (list 'call-with-values primitive-call-with-values 2 2)
       (list 'call/cc primitive-call/cc 1 1)
       (list 'car primitive-car 1 1)
       (list 'cdr primitive-cdr 1 1)
       (list 'ceiling primitive-ceiling 1 1)
       (list 'char->integer primitive-char->integer 1 1)
       (list 'char<=? primitive-char<=? 2 #f)
       (list 'char<? primitive-char<? 2 #f)
       (list 'char=? primitive-char=? 2 #f)
       (list 'char>=? primitive-char>=? 2 #f)
       (list 'char>? primitive-char>? 2 #f)
       (list 'char-ready? primitive-char-ready? 0 1)
       (list 'char? primitive-char? 1 1)
       (list 'close-input-port primitive-close-input-port 1 1)
       (list 'close-output-port primitive-close-output-port 1 1)
       (list 'close-port primitive-close-port 1 1)
       (list 'complex? primitive-complex? 1 1)
       (list 'cons primitive-cons 2 2)
       (list 'dynamic-wind primitive-dynamic-wind 3 3)
       (list 'eq? primitive-eq? 2 2)
       (list 'equal? primitive-equal? 2 2)
       (list 'eqv? primitive-eqv? 2 2)
       (list 'eof-object primitive-eof-object 0 0)
       (list 'eof-object? primitive-eof-object? 1 1)
       (list 'error primitive-error 1 #f)
       (list 'error-object-irritants primitive-error-object-irritants 1 1)
       (list 'error-object-message primitive-error-object-message 1 1)
       (list 'error-object? primitive-error-object? 1 1)
       (list 'denominator primitive-denominator 1 1)
       (list 'exact primitive-exact 1 1)
       (list 'exact-integer-sqrt primitive-exact-integer-sqrt 1 1)
       (list 'exact-integer? primitive-exact-integer? 1 1)
       (list 'exact? primitive-exact? 1 1)
       (list 'expt primitive-expt 2 2)
       (list 'features primitive-features 0 0)
       (list 'file-error? primitive-file-error? 1 1)
       (list 'floor primitive-floor 1 1)
       (list 'floor/ primitive-floor/ 2 2)
       (list 'floor-quotient primitive-floor-quotient 2 2)
       (list 'floor-remainder primitive-floor-remainder 2 2)
       (list 'flush-output-port primitive-flush-output-port 0 1)
       (list 'gcd primitive-gcd 0 #f)
       (list 'get-output-bytevector primitive-get-output-bytevector 1 1)
       (list 'get-output-string primitive-get-output-string 1 1)
       (list 'inexact primitive-inexact 1 1)
       (list 'inexact? primitive-inexact? 1 1)
       (list 'input-port-open? primitive-input-port-open? 1 1)
       (list 'input-port? primitive-input-port? 1 1)
       (list 'integer->char primitive-integer->char 1 1)
       (list 'integer? primitive-integer? 1 1)
       (list 'lcm primitive-lcm 0 #f)
       (list 'list->string primitive-list->string 1 1)
       (list 'list->vector primitive-list->vector 1 1)
       (list 'list? primitive-list? 1 1)
       (list 'make-bytevector primitive-make-bytevector 1 2)
       (list 'make-parameter primitive-make-parameter 1 2)
       (list 'make-string primitive-make-string 1 2)
       (list 'make-vector primitive-make-vector 1 2)
       (list 'modulo primitive-modulo 2 2)
       (list 'newline primitive-newline 0 1)
       (list 'null? primitive-null? 1 1)
       (list 'number->string primitive-number->string 1 2)
       (list 'number? primitive-number? 1 1)
       (list 'numerator primitive-numerator 1 1)
       (list 'open-input-bytevector primitive-open-input-bytevector 1 1)
       (list 'open-input-string primitive-open-input-string 1 1)
       (list 'open-output-bytevector primitive-open-output-bytevector 0 0)
       (list 'open-output-string primitive-open-output-string 0 0)
       (list 'output-port-open? primitive-output-port-open? 1 1)
       (list 'output-port? primitive-output-port? 1 1)
       (list 'pair? primitive-pair? 1 1)
       (list 'peek-char primitive-peek-char 0 1)
       (list 'peek-u8 primitive-peek-u8 0 1)
       (list 'port? primitive-port? 1 1)
       (list 'procedure? primitive-procedure? 1 1)
       (list 'quotient primitive-quotient 2 2)
       (list 'raise primitive-raise 1 1)
       (list 'raise-continuable primitive-raise-continuable 1 1)
       (list 'rational? primitive-rational? 1 1)
       (list 'rationalize primitive-rationalize 2 2)
       (list 'read-bytevector primitive-read-bytevector 1 2)
       (list 'read-bytevector! primitive-read-bytevector! 1 4)
       (list 'read-char primitive-read-char 0 1)
       (list 'read-error? primitive-read-error? 1 1)
       (list 'read-line primitive-read-line 0 1)
       (list 'read-string primitive-read-string 1 2)
       (list 'read-u8 primitive-read-u8 0 1)
       (list 'real? primitive-real? 1 1)
       (list 'remainder primitive-remainder 2 2)
       (list 'round primitive-round 1 1)
       (list 'set-car! primitive-set-car! 2 2)
       (list 'set-cdr! primitive-set-cdr! 2 2)
       (list 'string primitive-string 0 #f)
       (list 'string->list primitive-string->list 1 3)
       (list 'string->number primitive-string->number 1 2)
       (list 'string->symbol primitive-string->symbol 1 1)
       (list 'string->utf8 primitive-string->utf8 1 3)
       (list 'string->vector primitive-string->vector 1 3)
       (list 'string-append primitive-string-append 0 #f)
       (list 'string-copy primitive-string-copy 1 3)
       (list 'string-copy! primitive-string-copy! 3 5)
       (list 'string-fill! primitive-string-fill! 2 4)
       (list 'string-length primitive-string-length 1 1)
       (list 'string-ref primitive-string-ref 2 2)
       (list 'string-set! primitive-string-set! 3 3)
       (list 'string<=? primitive-string<=? 2 #f)
       (list 'string<? primitive-string<? 2 #f)
       (list 'string=? primitive-string=? 2 #f)
       (list 'string>=? primitive-string>=? 2 #f)
       (list 'string>? primitive-string>? 2 #f)
       (list 'string? primitive-string? 1 1)
       (list 'substring primitive-substring 3 3)
       (list 'symbol->string primitive-symbol->string 1 1)
       (list 'symbol=? primitive-symbol=? 2 #f)
       (list 'symbol? primitive-symbol? 1 1)
       (list 'textual-port? primitive-textual-port? 1 1)
       (list 'truncate primitive-truncate 1 1)
       (list 'truncate/ primitive-truncate/ 2 2)
       (list 'truncate-quotient primitive-truncate-quotient 2 2)
       (list 'truncate-remainder primitive-truncate-remainder 2 2)
       (list 'u8-ready? primitive-u8-ready? 0 1)
       (list 'utf8->string primitive-utf8->string 1 3)
       (list 'vector primitive-vector 0 #f)
       (list 'vector->list primitive-vector->list 1 3)
       (list 'vector->string primitive-vector->string 1 3)
       (list 'vector-append primitive-vector-append 0 #f)
       (list 'vector-copy primitive-vector-copy 1 3)
       (list 'vector-copy! primitive-vector-copy! 3 5)
       (list 'vector-fill! primitive-vector-fill! 2 4)
       (list 'vector-length primitive-vector-length 1 1)
       (list 'vector-ref primitive-vector-ref 2 2)
       (list 'vector-set! primitive-vector-set! 3 3)
       (list 'vector? primitive-vector? 1 1)
       (list 'values primitive-values 0 #f)
       (list 'with-exception-handler
             primitive-with-exception-handler
             2
             2)
       (list 'write-bytevector primitive-write-bytevector 1 4)
       (list 'write-char primitive-write-char 1 2)
       (list 'write-string primitive-write-string 1 4)
       (list 'write-u8 primitive-write-u8 1 2)))

    ;; Kernel primitive names grouped by effect tier for manifest metadata.
    (define primitive-mutation-names
      '(bytevector-copy! bytevector-u8-set! read-bytevector!
        set-car! set-cdr! string-copy! string-fill! string-set!
        vector-copy! vector-fill! vector-set!))

    ;; Kernel primitive names that observe or update port state.
    (define primitive-port-io-names
      '(binary-port? call-with-port char-ready? close-input-port
        close-output-port close-port eof-object eof-object? file-error?
        flush-output-port get-output-bytevector get-output-string
        input-port-open? input-port? newline open-input-bytevector
        open-input-string open-output-bytevector open-output-string
        output-port-open? output-port? peek-char peek-u8 port?
        read-bytevector read-char read-error? read-line read-string
        read-u8 textual-port? u8-ready? write-bytevector write-char
        write-string write-u8))

    ;; Kernel primitive names that affect evaluator control flow.
    (define primitive-control-names
      '(apply call-with-current-continuation call-with-values call/cc
        dynamic-wind error raise raise-continuable values
        with-exception-handler))

    ;; Return the effect tier for primitive NAME.
    (define (primitive-effect-for-name name)
      (cond
       ((memq name primitive-mutation-names) 'mutation)
       ((memq name primitive-port-io-names) 'port-io)
       ((memq name primitive-control-names) 'control)
       ((eq? name 'make-parameter) 'dynamic-state)
       (else 'pure)))

    ;; Return a future backend lowering hint for EFFECT.
    (define (primitive-emitter-hook-for-effect effect)
      (cond
       ((eq? effect 'mutation) 'runtime-mutation)
       ((eq? effect 'port-io) 'capability-port)
       ((eq? effect 'control) 'runtime-control)
       ((eq? effect 'dynamic-state) 'runtime-parameter)
       ((eq? effect 'host-file) 'capability-file)
       ((eq? effect 'host-process) 'capability-process)
       ((eq? effect 'host-time) 'capability-time)
       ((eq? effect 'host-repl) 'capability-repl)
       ((eq? effect 'eval) 'runtime-eval)
       (else 'inline-or-call)))

    ;; Return test category tags for NAME and EFFECT.
    (define (primitive-test-categories-for-name name effect)
      (cond
       ((memq name '(vector vector? vector-ref vector-set! vector-length
                    vector-copy vector-copy! vector-fill! vector-append
                    vector->list vector->string vector-map vector-for-each
                    string->vector))
        '(vector))
       ((memq name '(bytevector bytevector? bytevector-length
                     bytevector-u8-ref bytevector-u8-set! bytevector-copy
                     bytevector-copy! bytevector-append read-bytevector
                     read-bytevector! write-bytevector))
        '(bytevector))
       ((eq? effect 'port-io)
        '(port))
       ((eq? effect 'control)
        '(control))
       (else
        '(base))))

    ;; Return canonical manifest metadata for one base primitive ENTRY.
    (define (base-primitive-manifest-spec entry)
      (let* ((name (car entry))
             (effect (primitive-effect-for-name name)))
        (list (list 'name name)
              (list 'library scheme-base-library-key)
              (list 'minimum-arity (third entry))
              (list 'maximum-arity (fourth entry))
              (list 'source 'kernel)
              (list 'effect effect)
              (list 'required-capability #f)
              (list 'emacs-hook #f)
              (list 'portable-hook #f)
              (list 'emitter-hook
                    (primitive-emitter-hook-for-effect effect))
              (list 'policy 'allow)
              (list 'test-categories
                    (primitive-test-categories-for-name name effect)))))

    ;; Primitive metadata is exported for tests and future conformance reports;
    ;; it describes the kernel surface without exposing implementation closures.
    (define (agent-scheme-base-primitive-names)
      (map car base-primitive-registry))

    ;; Public metadata accessor for kernel primitive arity and source specs.
    (define (agent-scheme-base-primitive-specs)
      (map (lambda (spec)
             (list (assq 'name spec)
                   (assq 'minimum-arity spec)
                   (assq 'maximum-arity spec)
                   (assq 'source spec)
                   (assq 'effect spec)))
           (map base-primitive-manifest-spec base-primitive-registry)))

    ;; Prelude source paths are the only host-files read during base environment
    ;; construction; they support project-root and library-path test layouts.
    (define agent-scheme-base-prelude-load-paths
      ;; Portable Scheme tests may run from the project root or with the
      ;; `agent-scheme' directory on the implementation's library path.
      '("scheme/agent-scheme/base-prelude.scm"
        "agent-scheme/base-prelude.scm"))

    ;; Syntax prelude paths mirror value prelude loading so derived syntax stays
    ;; portable source, not embedded host data.
    (define agent-scheme-base-syntax-load-paths
      '("scheme/agent-scheme/base-syntax.scm"
        "agent-scheme/base-syntax.scm"))

    ;; Cache for parsed base prelude forms shared across base environment
    ;; creation.
    (define base-prelude-forms-cache #f)
    ;; Cache for parsed syntax prelude forms shared across evaluation contexts.
    (define base-syntax-forms-cache #f)

    ;; Read all characters from PORT into a string.
    (define (read-port-string port)
      (let loop ((chars '()))
        (let ((char (read-char port)))
          (if (eof-object? char)
              (list->string (reverse chars))
              (loop (cons char chars))))))

    ;; Read and parse all datums from PORT.
    (define (read-all-datums port)
      (agent-scheme-read-all (read-port-string port)))

    ;; Prelude forms are cached after reader validation; metadata extraction
    ;; depends on each top-level form remaining one define.
    (define (base-prelude-forms)
      (or base-prelude-forms-cache
          (let ((forms
                 (let try ((paths agent-scheme-base-prelude-load-paths))
                   (if (null? paths)
                       (eval-error "unable to load base prelude")
                       (guard (condition
                               (else (try (cdr paths))))
                         (call-with-input-file
                             (car paths)
                           read-all-datums))))))
            (set! base-prelude-forms-cache forms)
            forms)))

    ;; Syntax prelude forms are cached separately because they install into the
    ;; current syntax environment, not the value environment.
    (define (base-syntax-forms)
      (or base-syntax-forms-cache
          (let ((forms
                 (let try ((paths agent-scheme-base-syntax-load-paths))
                   (if (null? paths)
                       (eval-error "unable to load base syntax prelude")
                       (guard (condition
                               (else (try (cdr paths))))
                         (call-with-input-file
                             (car paths)
                           read-all-datums))))))
            (set! base-syntax-forms-cache forms)
            forms)))

    ;; Return minimum and maximum arity metadata for Scheme formals.
    (define (formals-arity formals)
      (cond
       ((symbol? formals)
        (cons 0 #f))
       (else
        (let loop ((cursor formals) (minimum 0))
          (cond
           ((null? cursor)
            (cons minimum minimum))
           ((pair? cursor)
            (loop (cdr cursor) (+ minimum 1)))
           ((symbol? cursor)
            (cons minimum #f))
           (else
            (eval-error "prelude definition has invalid formals")))))))

    ;; Extract name, arity, and source metadata from one prelude define.
    (define (prelude-definition-spec form)
      (if (not (and (pair? form)
                    (eq? (car form) 'define)
                    (pair? (cdr form))
                    (pair? (cdr (cdr form)))))
          (eval-error "prelude form must be one definition" form))
      (let ((target (second form)))
        (cond
         ((symbol? target)
          (if (not (null? (cdr (cdr (cdr form)))))
              (eval-error
               "prelude variable definition must have one initializer"))
          (let ((initializer (third form)))
            (if (not (and (pair? initializer)
                          (eq? (car initializer) 'lambda)))
                (eval-error
                 "prelude variable definition must initialize a lambda"))
            (let ((arity (formals-arity (second initializer))))
              (list (list 'name target)
                    (list 'minimum-arity (car arity))
                    (list 'maximum-arity (cdr arity))
                    (list 'source 'prelude)))))
         ((pair? target)
          (let ((arity (formals-arity (cdr target))))
            (list (list 'name (car target))
                  (list 'minimum-arity (car arity))
                  (list 'maximum-arity (cdr arity))
                  (list 'source 'prelude))))
         (else
          (eval-error
           "prelude define target must be an identifier or function signature"
           form)))))

    ;; Prelude binding specs identify derived procedures separately from kernel
    ;; primitives so tests can catch accidental boundary movement.
    (define (agent-scheme-base-prelude-binding-specs)
      (map prelude-definition-spec (base-prelude-forms)))

    ;; Public metadata accessor for derived base prelude names.
    (define (agent-scheme-base-prelude-binding-names)
      (map (lambda (spec)
             (second (assq 'name spec)))
           (agent-scheme-base-prelude-binding-specs)))

    ;; Public metadata accessor for all base binding specs.
    (define (agent-scheme-base-binding-specs)
      (append (agent-scheme-base-primitive-specs)
              (agent-scheme-base-prelude-binding-specs)))

    ;; Explicit manifest metadata for currently host-effecting standard
    ;; primitives.  These records keep denied stubs visible before the full
    ;; capability system exists.
    (define standard-primitive-manifest-specs
      (list
       (list (list 'name 'delete-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-delete-file)
             (list 'portable-hook 'primitive-delete-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'file-exists?)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-file-exists?)
             (list 'portable-hook 'primitive-file-exists?)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'call-with-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'call-with-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-binary-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-binary-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'with-input-from-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'with-output-to-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'load)
             (list 'library '(scheme load))
             (list 'minimum-arity 1)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-load)
             (list 'portable-hook 'primitive-load)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(load file policy)))
       (list (list 'name 'command-line)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'emergency-exit)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'exit)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'get-environment-variable)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'get-environment-variables)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'interaction-environment)
             (list 'library '(scheme repl))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-repl)
             (list 'required-capability 'repl)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-repl)
             (list 'policy 'deny)
             (list 'test-categories '(repl policy)))
       (list (list 'name 'current-jiffy)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'deny)
             (list 'test-categories '(time policy)))
       (list (list 'name 'current-second)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'deny)
             (list 'test-categories '(time policy)))
       (list (list 'name 'jiffies-per-second)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'deny)
             (list 'test-categories '(time policy)))))

    ;; Return manifest metadata for portable prelude SPEC.
    (define (prelude-manifest-spec spec)
      (let* ((name (second (assq 'name spec)))
             (effect 'pure))
        (append spec
                (list (list 'library scheme-base-library-key)
                      (list 'effect effect)
                      (list 'required-capability #f)
                      (list 'emacs-hook #f)
                      (list 'portable-hook #f)
                      (list 'emitter-hook 'inline-or-call)
                      (list 'policy 'allow)
                      (list 'test-categories
                            (primitive-test-categories-for-name
                             name
                             effect))))))

    ;; Public manifest accessor shared by portable tests and future tools.
    (define (agent-scheme-primitive-manifest-binding-specs)
      (append (map base-primitive-manifest-spec base-primitive-registry)
              (map prelude-manifest-spec
                   (agent-scheme-base-prelude-binding-specs))
              standard-primitive-manifest-specs))

    ;; Install a primitive procedure binding into ENVIRONMENT.
    (define (define-primitive! environment
                               name
                               function
                               minimum-arity
                               maximum-arity)
      (environment-define!
       environment
       name
       (make-primitive-procedure
        name function minimum-arity maximum-arity)))

    ;; The base environment installs primitive kernel bindings first, then
    ;; evaluates derived Scheme definitions in the same environment.
    (define (agent-scheme-make-base-environment)
      (let ((environment (agent-scheme-make-empty-environment)))
        (let loop ((rest base-primitive-registry))
          (if (null? rest)
              (begin
                ;; Derived base procedures are ordinary Scheme definitions
                ;; loaded through the same evaluator and trampoline.
                (trampoline
                 (make-sequence (base-prelude-forms) #t)
                 environment
                 (new-eval-context '()))
                environment)
              (begin
                (define-primitive! environment
                                   (car (car rest))
                                   (second (car rest))
                                   (third (car rest))
                                   (fourth (car rest)))
                (loop (cdr rest)))))))

    ;; Install derived base syntax into CONTEXT once.
    (define (ensure-base-syntax! context environment)
      (if (not (context-base-syntax-installed context))
          (begin
            (for-each
             (lambda (form)
               (eval-define-syntax
                form
                environment
                context
                (context-syntax-environment context)))
             (base-syntax-forms))
            (set-context-base-syntax-installed! context #t))))

    ;; Fully expand a define form while preserving its definition shape.
    (define (expand-definition-form form environment context)
      (let* ((parts (proper-list-elements form "define form"))
             (target (second parts)))
        (cond
         ((identifier-datum? target)
          (if (not (= (length parts) 3))
              (eval-error
               "define requires an identifier and an expression"
               form))
          (list (car parts)
                target
                (expand-expression/fully
                 (third parts) environment context)))
         ((pair? target)
          (append (list (car parts) target)
                  (expand-sequence-forms
                   (cddr parts) environment context #t)))
         (else
          (eval-error
           "define target must be an identifier or function signature"
           form)))))

    ;; Fully expand the initializer in a define-values form.
    (define (expand-define-values-form form environment context)
      (let ((parts (proper-list-elements form "define-values form")))
        (if (not (= (length parts) 3))
            (eval-error
             "define-values requires formals and one expression"
             form))
        (list (car parts)
              (second parts)
              (expand-expression/fully (third parts) environment context))))

    ;; Fully expand core special forms and ordinary combinations.
    (define (expand-core-combination expression environment context)
      (let* ((parts (proper-list-elements expression "expression"))
             (operator (car parts)))
        (cond
         ((or (and (identifier-named? operator 'quote)
                   (special-operator-active? operator environment))
              (and (identifier-named? operator 'quasiquote)
                   (special-operator-active? operator environment)))
          expression)
         ((and (identifier-named? operator 'lambda)
               (special-operator-active? operator environment))
          (if (< (length parts) 3)
              (eval-error "lambda requires formals and a body" parts))
          (append (list operator (second parts))
                  (expand-sequence-forms
                   (cddr parts) environment context #t)))
         ((and (identifier-named? operator 'if)
               (special-operator-active? operator environment))
          (if (not (or (= (length parts) 3) (= (length parts) 4)))
              (eval-error
               "if requires test, consequent, and optional alternate"
               parts))
          (append
           (list operator
                 (expand-expression/fully
                  (second parts) environment context)
                 (expand-expression/fully
                  (third parts) environment context))
           (if (= (length parts) 4)
               (list (expand-expression/fully
                      (fourth parts) environment context))
               '())))
         ((and (identifier-named? operator 'set!)
               (special-operator-active? operator environment))
          (if (not (= (length parts) 3))
              (eval-error
               "set! requires an identifier and an expression"
               parts))
          (list operator
                (second parts)
                (expand-expression/fully
                 (third parts) environment context)))
         ((and (identifier-named? operator 'define-values)
               (special-operator-active? operator environment))
          (eval-error
           "define-values is not valid in expression position"
           parts))
         ((and (or (identifier-named? operator 'let-values)
                   (identifier-named? operator 'let*-values))
               (special-operator-active? operator environment))
          (let ((description
                 (symbol->string (identifier-datum-name operator))))
            (let ((bindings
                   (map (lambda (binding)
                          (let ((binding-parts
                                 (proper-list-elements
                                  binding
                                  (string-append description " binding"))))
                            (if (not (= (length binding-parts) 2))
                                (eval-error
                                 (string-append
                                  description
                                  " binding must contain formals and initializer")
                                 binding))
                            (list (car binding-parts)
                                  (expand-expression/fully
                                   (second binding-parts)
                                   environment
                                   context))))
                        (proper-list-elements
                         (second parts)
                         (string-append description " binding list")))))
              (append (list operator bindings)
                      (expand-sequence-forms
                       (cddr parts) environment context #t)))))
         ((and (or (identifier-named? operator 'letrec)
                   (identifier-named? operator 'letrec*))
               (special-operator-active? operator environment))
          (let ((bindings
                 (map (lambda (binding)
                        (let ((binding-parts
                               (proper-list-elements
                                binding
                                "letrec binding")))
                          (if (not (= (length binding-parts) 2))
                              (eval-error
                               "letrec binding must contain an identifier and initializer"
                               binding))
                          (list (car binding-parts)
                                (expand-expression/fully
                                 (second binding-parts)
                                 environment
                                 context))))
                      (proper-list-elements
                       (second parts)
                       "letrec binding list"))))
            (append (list operator bindings)
                    (expand-sequence-forms
                     (cddr parts) environment context #t))))
         ((and (identifier-named? operator 'begin)
               (special-operator-active? operator environment))
          (cons operator
                (expand-sequence-forms
                 (cdr parts) environment context #f)))
         (else
          (map (lambda (part)
                 (expand-expression/fully part environment context))
               parts)))))

    ;; Recursively expand EXPRESSION until no macro expansion remains.
    (define (expand-expression/fully expression environment context)
      (let ((expanded (expand-expression expression environment context)))
        (cond
         ((not (eq? expanded expression))
          (cond
           ((syntax-scope? expanded)
            (with-syntax-environment
             context
             (syntax-scope-syntax-environment expanded)
             (lambda ()
               (cons 'begin
                     (expand-sequence-forms
                      (syntax-scope-forms expanded)
                      environment
                      context
                      #t)))))
           (else
            (expand-expression/fully expanded environment context))))
         ((pair? expression)
          (expand-core-combination expression environment context))
         (else expression))))

    ;; Fully expand a sequence, executing allowed definition-time forms.
    (define (expand-sequence-forms forms environment context allow-definitions?)
      (let loop ((rest forms) (expanded '()))
        (if (null? rest)
            (reverse expanded)
            (let ((form (car rest)))
              (cond
               ((and allow-definitions? (import-form? form))
                (eval-import form environment context)
                (loop (cdr rest) expanded))
               ((and allow-definitions? (define-library-form? form))
                (eval-define-library form environment context)
                (loop (cdr rest) expanded))
               ((and allow-definitions? (syntax-definition-form? form))
                (eval-define-syntax
                 form
                 environment
                 context
                 (context-syntax-environment context))
                (loop (cdr rest) expanded))
               ((and allow-definitions? (definition-form? form))
                (loop (cdr rest)
                      (cons (expand-definition-form
                             form environment context)
                            expanded)))
               ((and allow-definitions? (define-values-form? form))
                (loop (cdr rest)
                      (cons (expand-define-values-form
                             form environment context)
                            expanded)))
               ((and allow-definitions? (begin-form? form))
                (loop (cdr rest)
                      (append
                       (reverse
                        (expand-sequence-forms
                         (cdr (proper-list-elements form "begin form"))
                         environment
                         context
                         #t))
                       expanded)))
               (else
                (loop (cdr rest)
                      (cons (expand-expression/fully
                             form environment context)
                            expanded))))))))

    ;; Return the optional caller environment or a fresh base environment.
    (define (rest-environment rest)
      (if (or (null? rest) (not (car rest)))
          (agent-scheme-make-base-environment)
          (car rest)))

    ;; Return the optional caller options alist, defaulting to empty.
    (define (rest-options rest)
      (if (or (null? rest) (null? (cdr rest)))
          '()
          (second rest)))

    ;; Evaluate one already-read expression in the supplied environment, or a
    ;; fresh base environment when no environment is provided.
    (define (agent-scheme-eval expression . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (trampoline expression environment context)))

    ;; Read and evaluate a source body as a sequence that may contain
    ;; definitions, imports, libraries, and expressions.
    (define (agent-scheme-eval-source source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest))
            (forms (agent-scheme-read-all source)))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (trampoline (make-sequence forms #t) environment context)))

    ;; String evaluation is an alias kept for callers that name the source kind.
    (define agent-scheme-eval-string agent-scheme-eval-source)

    ;; Fully expand one already-read expression without evaluating its result.
    (define (agent-scheme-expand expression . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (ensure-base-syntax! context environment)
        (expand-expression/fully expression environment context)))

    ;; Read and expand a source body, preserving top-level definition structure
    ;; for tests and future compiler/backend passes.
    (define (agent-scheme-expand-source source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest))
            (forms (agent-scheme-read-all source)))
        (ensure-base-syntax! context environment)
        (expand-sequence-forms forms environment context #t)))

    ;; Result-producing evaluation catches conditions and returns an inspectable
    ;; Scheme-readable evaluation-result datum instead of raising to the host.
    (define (agent-scheme-eval-result expression . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (guard (condition
                (else (condition-result-datum condition context)))
          (ok-result-datum
           (trampoline expression environment context)
           context))))

    ;; Source result evaluation combines reader, evaluator, condition capture,
    ;; and budget reporting for REPL and protocol-boundary callers.
    (define (agent-scheme-eval-source-result source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (guard (condition
                (else (condition-result-datum condition context)))
          (let ((forms (agent-scheme-read-all source)))
            (ok-result-datum
             (trampoline (make-sequence forms #t) environment context)
             context)))))

    ))
