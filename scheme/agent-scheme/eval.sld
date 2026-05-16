(define-library (agent-scheme eval)
  (export agent-scheme-eval
          agent-scheme-eval-source
          agent-scheme-eval-string
          agent-scheme-make-empty-environment
          agent-scheme-make-base-environment
          agent-scheme-value->external
          agent-scheme-unspecified
          agent-scheme-unspecified?
          agent-scheme-procedure?
          agent-scheme-primitive-procedure?)
  (import (scheme base)
          (agent-scheme reader))
  (begin
    (define agent-scheme-default-maximum-steps 100000)
    (define agent-scheme-default-maximum-value-nodes 100000)
    (define agent-scheme-default-maximum-host-callbacks 10000)

    (define-record-type <agent-scheme-unspecified>
      (make-unspecified)
      agent-scheme-unspecified?
      (tag unspecified-tag))

    (define agent-scheme-unspecified (make-unspecified))

    (define-record-type <undefined>
      (make-undefined)
      undefined?
      (tag undefined-tag))

    (define undefined (make-undefined))

    (define-record-type <cell>
      (make-cell value)
      cell?
      (value cell-value set-cell-value!))

    (define-record-type <environment>
      (make-environment frame parent)
      environment?
      (frame environment-frame set-environment-frame!)
      (parent environment-parent))

    (define-record-type <formals>
      (make-formals required rest)
      formals?
      (required formals-required)
      (rest formals-rest))

    (define-record-type <procedure>
      (make-procedure formals body environment)
      agent-scheme-procedure?
      (formals procedure-formals)
      (body procedure-body)
      (environment procedure-environment))

    (define-record-type <primitive-procedure>
      (make-primitive-procedure name function minimum-arity maximum-arity)
      agent-scheme-primitive-procedure?
      (name primitive-procedure-name)
      (function primitive-procedure-function)
      (minimum-arity primitive-procedure-minimum-arity)
      (maximum-arity primitive-procedure-maximum-arity))

    (define-record-type <sequence>
      (make-sequence forms allow-definitions)
      sequence?
      (forms sequence-forms)
      (allow-definitions sequence-allow-definitions))

    (define-record-type <bounce>
      (make-bounce expression environment)
      bounce?
      (expression bounce-expression)
      (environment bounce-environment))

    (define-record-type <eval-context>
      (make-eval-context steps maximum-steps
                         maximum-value-nodes
                         host-callbacks maximum-host-callbacks)
      eval-context?
      (steps context-steps set-context-steps!)
      (maximum-steps context-maximum-steps)
      (maximum-value-nodes context-maximum-value-nodes)
      (host-callbacks context-host-callbacks set-context-host-callbacks!)
      (maximum-host-callbacks context-maximum-host-callbacks))

    (define (option-ref options key default)
      (let ((cell (assq key options)))
        (if cell (cdr cell) default)))

    (define (eval-error message . irritants)
      (apply error
             (string-append "agent-scheme eval error: " message)
             irritants))

    (define (budget-error message . irritants)
      (apply error
             (string-append "agent-scheme budget error: " message)
             irritants))

    (define (new-eval-context options)
      (make-eval-context
       0
       (if (assq 'max-steps options)
           (option-ref options 'max-steps agent-scheme-default-maximum-steps)
           (option-ref options
                       'max-non-tail-steps
                       agent-scheme-default-maximum-steps))
       (option-ref options
                   'max-value-nodes
                   agent-scheme-default-maximum-value-nodes)
       0
       (option-ref options
                   'max-host-callbacks
                   agent-scheme-default-maximum-host-callbacks)))

    (define (note-step! context)
      (set-context-steps! context (+ (context-steps context) 1))
      (if (> (context-steps context) (context-maximum-steps context))
          (budget-error "evaluation step budget exceeded"
                        (context-maximum-steps context))))

    (define (note-host-callback! context primitive)
      (set-context-host-callbacks!
       context
       (+ (context-host-callbacks context) 1))
      (if (> (context-host-callbacks context)
             (context-maximum-host-callbacks context))
          (budget-error "host callback budget exceeded"
                        (primitive-procedure-name primitive))))

    (define (value-node-count value seen)
      (cond
       ((or (boolean? value)
            (null? value)
            (symbol? value)
            (char? value)
            (number? value)
            (agent-scheme-unspecified? value)
            (agent-scheme-procedure? value)
            (agent-scheme-primitive-procedure? value))
        1)
       ((string? value)
        (+ 1 (string-length value)))
       ((bytevector? value)
        (+ 1 (bytevector-length value)))
       ((pair? value)
        (if (memq value seen)
            0
            (+ 1
               (value-node-count (car value) (cons value seen))
               (value-node-count (cdr value) (cons value seen)))))
       ((vector? value)
        (if (memq value seen)
            0
            (let loop ((index 0) (count 1))
              (if (= index (vector-length value))
                  count
                  (loop (+ index 1)
                        (+ count
                           (value-node-count
                            (vector-ref value index)
                            (cons value seen))))))))
       (else
        (eval-error "unsupported Scheme value" value))))

    (define (check-value-budget value context)
      (let ((count (value-node-count value '())))
        (if (> count (context-maximum-value-nodes context))
            (budget-error "value node budget exceeded"
                          count
                          (context-maximum-value-nodes context))))
      value)

    (define (proper-list-elements datum description)
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else
          (eval-error
           (string-append description " must be a proper list"))))))

    (define (second list)
      (car (cdr list)))

    (define (third list)
      (car (cdr (cdr list))))

    (define (fourth list)
      (car (cdr (cdr (cdr list)))))

    (define (expect-symbol datum description)
      (if (symbol? datum)
          datum
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    (define (agent-scheme-make-empty-environment . maybe-parent)
      (make-environment
       '()
       (if (null? maybe-parent) #f (car maybe-parent))))

    (define (frame-cell environment name)
      (let ((cell (assq name (environment-frame environment))))
        (if cell (cdr cell) #f)))

    (define (environment-cell environment name)
      (let loop ((cursor environment))
        (cond
         ((not cursor) #f)
         ((frame-cell cursor name) => (lambda (cell) cell))
         (else (loop (environment-parent cursor))))))

    (define (environment-define! environment name value)
      (set-environment-frame!
       environment
       (cons (cons name (make-cell value))
             (environment-frame environment))))

    (define (environment-set! environment name value)
      (let ((cell (environment-cell environment name)))
        (if cell
            (set-cell-value! cell value)
            (eval-error "unbound identifier in set!" name))))

    (define (environment-ref environment name)
      (let ((cell (environment-cell environment name)))
        (if (not cell)
            (eval-error "unbound identifier" name)
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   name)
                  value)))))

    (define (ensure-distinct-names names description)
      (let loop ((rest names) (seen '()))
        (if (not (null? rest))
            (begin
              (if (memq (car rest) seen)
                  (eval-error
                   (string-append "duplicate identifier in " description)
                   (car rest)))
              (loop (cdr rest) (cons (car rest) seen))))))

    (define (parse-formals formals)
      (cond
       ((symbol? formals)
        (make-formals '() formals))
       (else
        (let loop ((cursor formals) (required '()))
          (cond
           ((null? cursor)
            (let ((names (reverse required)))
              (ensure-distinct-names names "lambda formals")
              (make-formals names #f)))
           ((pair? cursor)
            (loop (cdr cursor)
                  (cons (expect-symbol (car cursor) "lambda formal")
                        required)))
           ((symbol? cursor)
            (let ((names (reverse required)))
              (ensure-distinct-names (append names (list cursor))
                                     "lambda formals")
              (make-formals names cursor)))
           (else
            (eval-error
             "lambda formals must be an identifier, a proper list, or a dotted list"
             formals)))))))

    (define (self-evaluating? expression)
      (or (boolean? expression)
          (number? expression)
          (char? expression)
          (string? expression)
          (vector? expression)
          (bytevector? expression)))

    (define (true-value? value)
      (not (eq? value #f)))

    (define (definition-form? form)
      (and (pair? form) (eq? (car form) 'define)))

    (define (begin-form? form)
      (and (pair? form) (eq? (car form) 'begin)))

    (define (make-lambda-expression formals body)
      (cons 'lambda (cons formals body)))

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
            (cons target (car body)))
           ((pair? target)
            (let ((name (expect-symbol (car target)
                                       "function define name")))
              (if (null? body)
                  (eval-error "function define requires a body" form))
              (cons name (make-lambda-expression (cdr target) body))))
           (else
            (eval-error
             "define target must be an identifier or function signature"
             form))))))

    (define (split-body body)
      (let loop ((cursor body) (definitions '()))
        (cond
         ((and (pair? cursor) (definition-form? (car cursor)))
          (loop (cdr cursor) (cons (car cursor) definitions)))
         ((null? cursor)
          (eval-error "body must contain at least one expression" body))
         (else
          (cons (reverse definitions) cursor)))))

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
                            (environment-set!
                             body-environment
                             (caar remaining)
                             (eval-expression
                              (cdar remaining)
                              body-environment
                              context
                              #f))
                            (initialize-loop (cdr remaining)))))
                    (let ((parsed-definition (parse-definition (car rest))))
                      (if (frame-cell body-environment
                                      (car parsed-definition))
                          (eval-error "duplicate internal definition"
                                      (car parsed-definition)))
                      (environment-define!
                       body-environment
                       (car parsed-definition)
                       undefined)
                      (install-loop (cdr rest)
                                    (cons parsed-definition parsed)))))))))

    (define (eval-definition form environment context)
      (let* ((parsed (parse-definition form))
             (name (car parsed))
             (cell (frame-cell environment name))
             (value (eval-expression (cdr parsed)
                                     environment
                                     context
                                     #f)))
        (if cell
            (set-cell-value! cell value)
            (environment-define! environment name value))
        agent-scheme-unspecified))

    (define (bind-formals formals arguments closure-environment context)
      (let* ((required (formals-required formals))
             (rest (formals-rest formals))
             (required-count (length required))
             (argument-count (length arguments)))
        (cond
         ((and (not rest) (not (= argument-count required-count)))
          (eval-error "procedure received wrong number of arguments"
                      required-count
                      argument-count))
         ((and rest (< argument-count required-count))
          (eval-error "procedure received too few arguments"
                      required-count
                      argument-count)))
        (let ((environment
               (agent-scheme-make-empty-environment closure-environment)))
          (let loop ((names required) (values arguments))
            (if (null? names)
                (begin
                  (if rest
                      (begin
                        (environment-define! environment
                                             rest
                                             values)
                        (check-value-budget values context)))
                  environment)
                (begin
                  (environment-define! environment
                                       (car names)
                                       (car values))
                  (loop (cdr names) (cdr values))))))))

    (define (arity-match? primitive count)
      (and (>= count (primitive-procedure-minimum-arity primitive))
           (let ((maximum (primitive-procedure-maximum-arity primitive)))
             (or (not maximum) (<= count maximum)))))

    (define (apply-procedure procedure arguments context tail?)
      (cond
       ((agent-scheme-primitive-procedure? procedure)
        (if (not (arity-match? procedure (length arguments)))
            (eval-error "primitive received wrong number of arguments"
                        (primitive-procedure-name procedure)
                        (length arguments)))
        (note-host-callback! context procedure)
        (check-value-budget
         ((primitive-procedure-function procedure) arguments context)
         context))
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
          (if tail?
              (make-bounce body-expression (car body-state))
              (eval-sequence (cdr body-state)
                             (car body-state)
                             context
                             #f
                             #f))))
       (else
        (eval-error "attempted to call non-procedure"
                    (agent-scheme-value->external procedure)))))

    (define (eval-if parts environment context tail?)
      (if (not (or (= (length parts) 3) (= (length parts) 4)))
          (eval-error
           "if requires test, consequent, and optional alternate"
           parts))
      (let ((test-value (eval-expression (second parts)
                                         environment
                                         context
                                         #f)))
        (cond
         ((true-value? test-value)
          (if tail?
              (make-bounce (third parts) environment)
              (eval-expression (third parts) environment context #f)))
         ((= (length parts) 4)
          (if tail?
              (make-bounce (fourth parts) environment)
              (eval-expression (fourth parts) environment context #f)))
         (else
          agent-scheme-unspecified))))

    (define (eval-set! parts environment context)
      (if (not (= (length parts) 3))
          (eval-error "set! requires an identifier and an expression" parts))
      (let ((name (expect-symbol (second parts) "set! target"))
            (value (eval-expression (third parts)
                                    environment
                                    context
                                    #f)))
        (environment-set! environment name value)
        agent-scheme-unspecified))

    (define (eval-combination expression environment context tail?)
      (let ((parts (proper-list-elements expression "expression")))
        (if (null? parts)
            (eval-error "empty list is not an expression"))
        (let ((operator (car parts)))
          (cond
           ((eq? operator 'quote)
            (if (not (= (length parts) 2))
                (eval-error "quote requires exactly one datum" parts))
            (check-value-budget (second parts) context))
           ((eq? operator 'lambda)
            (if (< (length parts) 3)
                (eval-error "lambda requires formals and a body" parts))
            (make-procedure (parse-formals (second parts))
                            (cddr parts)
                            environment))
           ((eq? operator 'if)
            (eval-if parts environment context tail?))
           ((eq? operator 'set!)
            (eval-set! parts environment context))
           ((eq? operator 'define)
            (eval-error "define is not valid in expression position" parts))
           ((eq? operator 'begin)
            (eval-sequence (cdr parts) environment context tail? #f))
           (else
            (let ((procedure
                   (eval-expression operator environment context #f))
                  (arguments
                   (let loop ((operands (cdr parts)) (values '()))
                     (if (null? operands)
                         (reverse values)
                         (loop (cdr operands)
                               (cons
                                (eval-expression
                                 (car operands)
                                 environment
                                 context
                                 #f)
                                values))))))
              (apply-procedure procedure arguments context tail?)))))))

    (define (eval-expression expression environment context tail?)
      (note-step! context)
      (cond
       ((sequence? expression)
        (eval-sequence (sequence-forms expression)
                       environment
                       context
                       tail?
                       (sequence-allow-definitions expression)))
       ((self-evaluating? expression)
        (check-value-budget expression context))
       ((symbol? expression)
        (environment-ref environment expression))
       ((null? expression)
        (eval-error "empty list is not an expression"))
       ((pair? expression)
        (eval-combination expression environment context tail?))
       (else
        (eval-error "unsupported expression datum" expression))))

    (define (eval-sequence forms environment context tail? allow-definitions?)
      (cond
       ((null? forms)
        agent-scheme-unspecified)
       ((null? (cdr forms))
        (let ((form (car forms)))
          (cond
           ((definition-form? form)
            (if allow-definitions?
                (eval-definition form environment context)
                (eval-error
                 "define is only allowed before body expressions"
                 form)))
           ((and allow-definitions? (begin-form? form))
            (eval-sequence
             (cdr (proper-list-elements form "begin form"))
             environment
             context
             tail?
             #t))
           (tail?
            (make-bounce form environment))
           (else
            (eval-expression form environment context #f)))))
       (else
        (let ((form (car forms)))
          (cond
           ((definition-form? form)
            (if allow-definitions?
                (eval-definition form environment context)
                (eval-error
                 "define is only allowed before body expressions"
                 form)))
           ((and allow-definitions? (begin-form? form))
            (eval-sequence
             (cdr (proper-list-elements form "begin form"))
             environment
             context
             #f
             #t))
           (else
            (eval-expression form environment context #f)))
          (eval-sequence (cdr forms)
                         environment
                         context
                         tail?
                         allow-definitions?)))))

    (define (trampoline expression environment context)
      (let loop ((state (make-bounce expression environment)))
        (if (bounce? state)
            (loop (eval-expression (bounce-expression state)
                                   (bounce-environment state)
                                   context
                                   #t))
            (check-value-budget state context))))

    (define (primitive+ arguments context)
      (apply + arguments))

    (define (primitive* arguments context)
      (apply * arguments))

    (define (primitive- arguments context)
      (if (= (length arguments) 1)
          (- (car arguments))
          (apply - arguments)))

    (define (primitive-compare arguments predicate)
      (let loop ((rest arguments))
        (if (or (null? rest) (null? (cdr rest)))
            #t
            (and (predicate (car rest) (second rest))
                 (loop (cdr rest))))))

    (define (primitive= arguments context)
      (primitive-compare arguments =))

    (define (primitive< arguments context)
      (primitive-compare arguments <))

    (define (primitive> arguments context)
      (primitive-compare arguments >))

    (define (primitive<= arguments context)
      (primitive-compare arguments <=))

    (define (primitive>= arguments context)
      (primitive-compare arguments >=))

    (define (primitive-cons arguments context)
      (cons (car arguments) (second arguments)))

    (define (primitive-car arguments context)
      (let ((pair (car arguments)))
        (if (pair? pair)
            (car pair)
            (eval-error "car expected pair" pair))))

    (define (primitive-cdr arguments context)
      (let ((pair (car arguments)))
        (if (pair? pair)
            (cdr pair)
            (eval-error "cdr expected pair" pair))))

    (define (primitive-list arguments context)
      arguments)

    (define (primitive-null? arguments context)
      (null? (car arguments)))

    (define (primitive-pair? arguments context)
      (pair? (car arguments)))

    (define (primitive-not arguments context)
      (if (eq? (car arguments) #f) #t #f))

    (define (primitive-boolean? arguments context)
      (boolean? (car arguments)))

    (define (primitive-number? arguments context)
      (number? (car arguments)))

    (define (primitive-symbol? arguments context)
      (symbol? (car arguments)))

    (define (primitive-procedure? arguments context)
      (or (agent-scheme-procedure? (car arguments))
          (agent-scheme-primitive-procedure? (car arguments))))

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

    (define (agent-scheme-make-base-environment)
      (let ((environment (agent-scheme-make-empty-environment)))
        (define-primitive! environment '+ primitive+ 0 #f)
        (define-primitive! environment '* primitive* 0 #f)
        (define-primitive! environment '- primitive- 1 #f)
        (define-primitive! environment '= primitive= 2 #f)
        (define-primitive! environment '< primitive< 2 #f)
        (define-primitive! environment '> primitive> 2 #f)
        (define-primitive! environment '<= primitive<= 2 #f)
        (define-primitive! environment '>= primitive>= 2 #f)
        (define-primitive! environment 'cons primitive-cons 2 2)
        (define-primitive! environment 'car primitive-car 1 1)
        (define-primitive! environment 'cdr primitive-cdr 1 1)
        (define-primitive! environment 'list primitive-list 0 #f)
        (define-primitive! environment 'null? primitive-null? 1 1)
        (define-primitive! environment 'pair? primitive-pair? 1 1)
        (define-primitive! environment 'not primitive-not 1 1)
        (define-primitive! environment 'boolean? primitive-boolean? 1 1)
        (define-primitive! environment 'number? primitive-number? 1 1)
        (define-primitive! environment 'symbol? primitive-symbol? 1 1)
        (define-primitive! environment 'procedure? primitive-procedure? 1 1)
        environment))

    (define (rest-environment rest)
      (if (or (null? rest) (not (car rest)))
          (agent-scheme-make-base-environment)
          (car rest)))

    (define (rest-options rest)
      (if (or (null? rest) (null? (cdr rest)))
          '()
          (second rest)))

    (define (agent-scheme-eval expression . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (trampoline expression environment context)))

    (define (agent-scheme-eval-source source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest))
            (forms (agent-scheme-read-all source)))
        (trampoline (make-sequence forms #t) environment context)))

    (define agent-scheme-eval-string agent-scheme-eval-source)

    (define (agent-scheme-value->external value)
      (cond
       ((agent-scheme-unspecified? value)
        "#<unspecified>")
       ((agent-scheme-procedure? value)
        "#<procedure>")
       ((agent-scheme-primitive-procedure? value)
        (string-append
         "#<primitive "
         (symbol->string (primitive-procedure-name value))
         ">"))
       (else
        (agent-scheme-datum->external value))))))
