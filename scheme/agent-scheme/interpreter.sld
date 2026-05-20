;;; Portable Agent Scheme interpreter backend.
;;;
;;; This library owns evaluation, procedure application, primitive
;;; implementations, trampoline execution, and result-producing eval entry
;;; points for the portable bootstrap.

(define-library (agent-scheme interpreter)
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
          (agent-scheme result)
          (agent-scheme base)
          (agent-scheme library)
          (prefix (agent-scheme approval) approval-model:)
          (prefix (agent-scheme memory) memory-model:)
          (agent-scheme macro))
  (begin
    ;; Process-local portable approvals used by `(agent approval)' primitives.
    (define interpreter-approval-store
      (approval-model:agent-scheme-make-approval-store))

    ;; Process-local portable memory used by `(agent memory)' primitives.
    (define interpreter-memory-store
      (memory-model:agent-scheme-make-memory-store))

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

    ;; Canonical key for the required `(scheme base)' library.
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

    ;; Emit a primary structured observation event into the current context.
    (define (primitive-agent-yield arguments context)
      (record-agent-event! context (list 'yield (car arguments)))
      agent-scheme-unspecified)

    ;; Emit a structured log event into the current context.
    (define (primitive-agent-log arguments context)
      (record-agent-event!
       context
       (list 'log
             (result-field 'level (car arguments))
             (result-field 'message (second arguments))
             (result-field 'fields (cddr arguments))))
      agent-scheme-unspecified)

    ;; Emit a structured progress event into the current context.
    (define (primitive-agent-progress arguments context)
      (record-agent-event!
       context
       (list 'progress
             (result-field 'phase (car arguments))
             (result-field 'datum (second arguments))))
      agent-scheme-unspecified)

    ;; Emit a structured warning event into the current context.
    (define (primitive-agent-warn arguments context)
      (record-agent-event!
       context
       (list 'warn
             (result-field 'message (car arguments))
             (result-field 'fields (cdr arguments))))
      agent-scheme-unspecified)

    ;; Emit a structured request event into the current context.
    (define (primitive-agent-request arguments context)
      (record-agent-event! context (list 'request (car arguments)))
      agent-scheme-unspecified)

    ;; Create a portable approval request and return its id.
    (define (primitive-approval-request! arguments context)
      (approval-model:approval-request! interpreter-approval-store
                                        (car arguments)))

    ;; Return a portable approval request status, or #f when unknown.
    (define (primitive-approval-status arguments context)
      (approval-model:approval-status interpreter-approval-store
                                      (car arguments)))

    ;; Cancel a portable approval request.
    (define (primitive-approval-cancel! arguments context)
      (approval-model:approval-cancel! interpreter-approval-store
                                       (car arguments)))

    ;; Yield all pending portable approval requests.
    (define (primitive-approval-yield-pending arguments context)
      (let ((records
             (approval-model:approval-pending interpreter-approval-store)))
        (for-each
         (lambda (record)
           (record-agent-event! context (list 'yield record)))
         records)
        records))

    ;; Report whether CONTEXT allows Scheme-side approval resolution.
    (define (approval-resolution-allowed? context)
      (let ((entry (assq 'approval-resolution
                         (context-policy-actions context))))
        (and entry (eq? (cdr entry) 'allow))))

    ;; Resolve a portable approval only when policy explicitly allows it.
    (define (primitive-approval-resolve! arguments context)
      (if (not (approval-resolution-allowed? context))
          (eval-error "approval resolution is host-side only"))
      (approval-model:approval-resolve! interpreter-approval-store
                                        (car arguments)
                                        (second arguments)))

    ;; Return FIELD from Scheme-readable grant DATUM, or #f when absent.
    (define (capability-grant-field datum field)
      (let loop ((fields (if (pair? datum) (cdr datum) '())))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields)) (eq? (caar fields) field))
          (car fields))
         (else (loop (cdr fields))))))

    ;; Return GRANT's id or raise a portable evaluator error.
    (define (capability-grant-id grant)
      (let ((field (capability-grant-field grant 'id)))
        (if field
            (second field)
            (eval-error "capability grant requires an id field"))))

    ;; Return GRANT status, defaulting to active.
    (define (capability-grant-status grant)
      (let ((field (capability-grant-field grant 'status)))
        (if field (second field) 'active)))

    ;; Remove fields named by NAMES from GRANT.
    (define (capability-grant-remove-fields grant names)
      (cons
       (car grant)
       (let loop ((fields (cdr grant)))
         (cond
          ((null? fields) '())
          ((memq (caar fields) names) (loop (cdr fields)))
          (else (cons (car fields) (loop (cdr fields))))))))

    ;; Return GRANT with one field replaced by VALUES.
    (define (capability-grant-replace-field grant name values)
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

    ;; Return a normalized portable capability grant datum.
    (define (normalize-capability-grant datum)
      (if (not (and (pair? datum) (eq? (car datum) 'capability-grant)))
          (eval-error "grant-capability! expects a capability-grant datum"))
      (let ((without-status
             (capability-grant-remove-fields datum '(status))))
        (capability-grant-replace-field
         without-status
         'status
         '(active))))

    ;; Return GRANT if it has ID.
    (define (capability-grant-has-id? grant id)
      (equal? (capability-grant-id grant) id))

    ;; Return grant ID from GRANTS or #f.
    (define (capability-grant-find grants id)
      (cond
       ((null? grants) #f)
       ((capability-grant-has-id? (car grants) id) (car grants))
       (else (capability-grant-find (cdr grants) id))))

    ;; Store GRANT in CONTEXT, replacing any existing grant with the same id.
    (define (capability-grant-store! context grant)
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

    ;; Create a portable capability grant in the current context.
    (define (primitive-grant-capability! arguments context)
      (capability-grant-store!
       context
       (normalize-capability-grant (car arguments))))

    ;; Return active portable capability grants in the current context.
    (define (primitive-current-grants arguments context)
      (let loop ((grants (context-capability-grants context)))
        (cond
         ((null? grants) '())
         ((eq? (capability-grant-status (car grants)) 'active)
          (cons (car grants) (loop (cdr grants))))
         (else (loop (cdr grants))))))

    ;; Return a portable capability grant by id, or #f when unknown.
    (define (primitive-grant-ref arguments context)
      (let ((grant
             (capability-grant-find
              (context-capability-grants context)
              (car arguments))))
        (if grant grant #f)))

    ;; Create a portable attenuated child grant by replacing declared fields.
    (define (primitive-grant-attenuate arguments context)
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

    ;; Revoke a portable capability grant in the current context.
    (define (primitive-grant-revoke! arguments context)
      (let* ((grant
              (or (capability-grant-find
                   (context-capability-grants context)
                   (car arguments))
                  (eval-error "unknown capability grant")))
             (revoked
              (capability-grant-replace-field grant 'status '(revoked))))
        (capability-grant-store! context revoked)))

    ;; Call THUNK with GRANT present in the portable context.
    (define (primitive-call-with-capability-grant arguments context)
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

    ;; Store a keyed memory record in the portable interpreter memory store.
    (define (primitive-memory-put! arguments context)
      (memory-model:memory-put! interpreter-memory-store
                                (car arguments)
                                (second arguments)
                                (third arguments)))

    ;; Return a keyed memory record or #f from the portable memory store.
    (define (primitive-memory-ref arguments context)
      (memory-model:memory-ref interpreter-memory-store
                               (car arguments)
                               (second arguments)))

    ;; Delete a keyed memory record from the portable memory store.
    (define (primitive-memory-delete! arguments context)
      (memory-model:memory-delete! interpreter-memory-store
                                   (car arguments)
                                   (second arguments)))

    ;; Add a generated memory record to the portable memory store.
    (define (primitive-memory-add! arguments context)
      (memory-model:memory-add! interpreter-memory-store
                                (car arguments)
                                (second arguments)
                                (third arguments)))

    ;; Find matching memory records in the portable memory store.
    (define (primitive-memory-find arguments context)
      (memory-model:memory-find interpreter-memory-store
                                (car arguments)
                                (second arguments)))

    ;; Find tagged memory records in the portable memory store.
    (define (primitive-memory-by-tag arguments context)
      (memory-model:memory-by-tag interpreter-memory-store
                                  (car arguments)
                                  (second arguments)))

    ;; Return recent memory records from the portable memory store.
    (define (primitive-memory-recent arguments context)
      (memory-model:memory-recent interpreter-memory-store
                                  (car arguments)
                                  (second arguments)))

    ;; Yield matching memory records through the event channel.
    (define (primitive-memory-yield arguments context)
      (let ((records
             (memory-model:memory-find interpreter-memory-store
                                       (car arguments)
                                       (second arguments))))
        (for-each
         (lambda (record)
           (record-agent-event! context (list 'yield record)))
         records)
        records))

    ;; Record a portable policy decision into the context audit event list.
    (define (record-policy-decision! context category operation decision fields)
      (record-audit-event!
       context
       'policy-decision
       (append
        (list (result-field 'category category)
              (result-field 'operation operation)
              (result-field 'decision decision))
        fields)))

    ;; Raise a policy-gated host-access denial for DESCRIPTION.
    (define (policy-denied description context fields)
      (record-policy-decision!
       context
       'standard-host-effect
       description
       'denied
       fields)
      (eval-error
       (string-append description " requires policy-gated host access")))

    ;; Return a primitive callback that always raises a policy denial.
    (define (policy-denied-primitive description)
      (lambda (arguments context)
        (policy-denied description context '())))

    ;; Resolve FILENAME and enforce the file-operation allow-list policy.
    (define (resolve-file-policy-path filename context description)
      (let ((path (path-join (context-include-directory context) filename)))
        (cond
         ((null? (context-file-paths context))
          (record-policy-decision!
           context
           'standard-host-effect
           description
           'denied
           (list (result-field 'filename filename)
                 (result-field 'path path)))
          (eval-error
           (string-append description
                          " requires policy-gated host file access")
           filename))
         ((not (path-policy-allows-file? path (context-file-paths context)))
          (record-policy-decision!
           context
           'standard-host-effect
           description
           'denied
           (list (result-field 'filename filename)
                 (result-field 'path path)))
          (eval-error
           (string-append description " file is not allowed by policy")
           filename))
         (else
          (record-policy-decision!
           context
           'standard-host-effect
           description
           'allowed
           (list (result-field 'filename filename)
                 (result-field 'path path)))
          path))))

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
      (policy-denied
       "delete-file"
       context
       (list (result-field 'filename (car arguments)))))

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
       (cons 'primitive-delete-file primitive-delete-file)
       (cons 'primitive-file-exists? primitive-file-exists?)
       (cons 'primitive-load primitive-load)
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
       (cons 'primitive-approval-request! primitive-approval-request!)
       (cons 'primitive-approval-status primitive-approval-status)
       (cons 'primitive-approval-cancel! primitive-approval-cancel!)
       (cons 'primitive-approval-yield-pending
             primitive-approval-yield-pending)
       (cons 'primitive-approval-resolve! primitive-approval-resolve!)
       (cons 'primitive-grant-capability! primitive-grant-capability!)
       (cons 'primitive-current-grants primitive-current-grants)
       (cons 'primitive-grant-ref primitive-grant-ref)
       (cons 'primitive-grant-attenuate primitive-grant-attenuate)
       (cons 'primitive-grant-revoke! primitive-grant-revoke!)
       (cons 'primitive-call-with-capability-grant
             primitive-call-with-capability-grant)
       (cons 'primitive-memory-put! primitive-memory-put!)
       (cons 'primitive-memory-ref primitive-memory-ref)
       (cons 'primitive-memory-delete! primitive-memory-delete!)
       (cons 'primitive-memory-add! primitive-memory-add!)
       (cons 'primitive-memory-find primitive-memory-find)
       (cons 'primitive-memory-by-tag primitive-memory-by-tag)
       (cons 'primitive-memory-recent primitive-memory-recent)
       (cons 'primitive-memory-yield primitive-memory-yield)
       (cons 'primitive-car primitive-car)
       (cons 'primitive-cdr primitive-cdr)))

    ;; Resolve primitive implementations requested by the library module.
    (define (library-primitive-implementation-for-name name)
      (let ((entry (assq name library-primitive-implementation-table)))
        (if entry
            (cdr entry)
            (eval-error "unknown library primitive implementation" name))))

    ;; Install this interpreter and macro expander for library resolution.
    (define library-backend-installed
      (agent-scheme-install-library-backend!
       library-primitive-implementation-for-name
       policy-denied-primitive
       trampoline
       make-empty-syntax-environment
       syntax-environment-ref
       with-syntax-environment))
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

    ;; Resolve primitive implementation names requested by the base module.
    (define (base-primitive-implementation-for-name name)
      (let ((entry (assq name base-primitive-implementation-table)))
        (if entry
            (cdr entry)
            (eval-error "unknown base primitive implementation" name))))

    ;; Install this interpreter as the backend for base bootstrapping.
    (define base-backend-installed
      (agent-scheme-install-base-backend!
       base-primitive-implementation-for-name
       trampoline
       eval-define-syntax))
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
