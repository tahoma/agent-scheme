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
          agent-scheme-result->external
          agent-scheme-value->external
          agent-scheme-unspecified
          agent-scheme-unspecified?
          agent-scheme-procedure?
          agent-scheme-primitive-procedure?)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme read)
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
      (make-environment frame parent imported-names)
      environment?
      (frame environment-frame set-environment-frame!)
      (parent environment-parent)
      (imported-names environment-imported-names
                      set-environment-imported-names!))

    (define-record-type <syntax-environment>
      (make-syntax-environment frame parent imported-names)
      syntax-environment?
      (frame syntax-environment-frame set-syntax-environment-frame!)
      (parent syntax-environment-parent)
      (imported-names syntax-environment-imported-names
                      set-syntax-environment-imported-names!))

    (define-record-type <syntax-context>
      (make-syntax-context id value-environment syntax-environment)
      syntax-context?
      (id syntax-context-id)
      (value-environment syntax-context-value-environment)
      (syntax-environment syntax-context-syntax-environment))

    (define-record-type <identifier>
      (make-identifier name context)
      identifier?
      (name identifier-name)
      (context identifier-context))

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

    (define-record-type <string-output-port>
      (make-string-output-port contents)
      string-output-port?
      (contents string-output-port-contents
                set-string-output-port-contents!))

    (define-record-type <sequence>
      (make-sequence forms allow-definitions)
      sequence?
      (forms sequence-forms)
      (allow-definitions sequence-allow-definitions))

    (define-record-type <bounce>
      (make-bounce expression environment syntax-environment)
      bounce?
      (expression bounce-expression)
      (environment bounce-environment)
      (syntax-environment bounce-syntax-environment))

    (define-record-type <eval-context>
      (make-eval-context steps maximum-steps
                         maximum-value-nodes host-callbacks
                         maximum-host-callbacks syntax-environment libraries
                         include-paths include-directory file-paths
                         base-syntax-installed next-syntax-id)
      eval-context?
      (steps context-steps set-context-steps!)
      (maximum-steps context-maximum-steps)
      (maximum-value-nodes context-maximum-value-nodes)
      (host-callbacks context-host-callbacks set-context-host-callbacks!)
      (maximum-host-callbacks context-maximum-host-callbacks)
      (syntax-environment context-syntax-environment
                          set-context-syntax-environment!)
      (libraries context-libraries set-context-libraries!)
      (include-paths context-include-paths)
      (include-directory context-include-directory
                         set-context-include-directory!)
      (file-paths context-file-paths)
      (base-syntax-installed context-base-syntax-installed
                             set-context-base-syntax-installed!)
      (next-syntax-id context-next-syntax-id set-context-next-syntax-id!))

    (define-record-type <syntax-transformer>
      (make-syntax-transformer ellipsis literals rules
                               value-environment syntax-environment)
      syntax-transformer?
      (ellipsis syntax-transformer-ellipsis)
      (literals syntax-transformer-literals)
      (rules syntax-transformer-rules)
      (value-environment syntax-transformer-value-environment)
      (syntax-environment syntax-transformer-syntax-environment))

    (define-record-type <pattern-binding>
      (make-pattern-binding depth captures empty-prefixes)
      pattern-binding?
      (depth pattern-binding-depth set-pattern-binding-depth!)
      (captures pattern-binding-captures set-pattern-binding-captures!)
      (empty-prefixes pattern-binding-empty-prefixes
                      set-pattern-binding-empty-prefixes!))

    (define-record-type <syntax-scope>
      (make-syntax-scope forms syntax-environment)
      syntax-scope?
      (forms syntax-scope-forms)
      (syntax-environment syntax-scope-syntax-environment))

    (define-record-type <library-binding>
      (make-library-binding name kind object library-key)
      library-binding?
      (name library-binding-name)
      (kind library-binding-kind)
      (object library-binding-object)
      (library-key library-binding-library-key))

    (define-record-type <library>
      (make-library name key exports value-environment syntax-environment)
      library?
      (name library-name)
      (key library-key)
      (exports library-exports)
      (value-environment library-value-environment)
      (syntax-environment library-syntax-environment))

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

    (define (normalize-include-directory directory)
      (cond
       ((or (string=? directory "")
            (string=? directory "."))
        "")
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        directory)
       (else
        (string-append directory "/"))))

    (define (path-absolute? path)
      (and (> (string-length path) 0)
           (char=? (string-ref path 0) #\/)))

    (define (path-join directory path)
      (cond
       ((or (string=? directory "") (path-absolute? path))
        path)
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        (string-append directory path))
       (else
        (string-append directory "/" path))))

    (define (normalize-include-paths paths directory)
      (map (lambda (path)
             (path-join directory path))
           paths))

    (define (new-eval-context options)
      (let ((include-directory
             (normalize-include-directory
              (option-ref options 'include-directory "."))))
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
                   agent-scheme-default-maximum-host-callbacks)
       (make-syntax-environment '() #f '())
       '()
       (normalize-include-paths
        (option-ref options 'include-paths '())
        include-directory)
       include-directory
       (normalize-include-paths
        (option-ref options 'file-paths '())
        include-directory)
       #f
       0)))

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
            (identifier? value)
            (char? value)
            (number? value)
            (agent-scheme-unspecified? value)
            (agent-scheme-procedure? value)
            (agent-scheme-primitive-procedure? value)
            (string-output-port? value))
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

    (define (identifier-datum? datum)
      (or (symbol? datum) (identifier? datum)))

    (define (identifier-datum-name datum)
      (cond
       ((symbol? datum) datum)
       ((identifier? datum) (identifier-name datum))
       (else #f)))

    (define (identifier-key identifier)
      (cond
       ((identifier? identifier)
        (let ((context (identifier-context identifier)))
          (if context
              (list 'syntax
                    (syntax-context-id context)
                    (identifier-name identifier))
              (identifier-name identifier))))
       ((symbol? identifier) identifier)
       (else
        (eval-error "expected identifier" identifier))))

    (define (identifier-named? datum name)
      (let ((actual (identifier-datum-name datum)))
        (and actual (eq? actual name))))

    (define (expect-identifier-key datum description)
      (if (identifier-datum? datum)
          (identifier-key datum)
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    (define (agent-scheme-make-empty-environment . maybe-parent)
      (make-environment
       '()
       (if (null? maybe-parent) #f (car maybe-parent))
       '()))

    (define (frame-cell environment name)
      (let ((cell (assoc name (environment-frame environment))))
        (if cell (cdr cell) #f)))

    (define (environment-cell environment name)
      (let loop ((cursor environment))
        (cond
         ((not cursor) #f)
         ((frame-cell cursor name) => (lambda (cell) cell))
         (else (loop (environment-parent cursor))))))

    (define (environment-cell-imported? environment cell)
      (let environment-loop ((cursor environment))
        (and cursor
             (or (let frame-loop ((frame (environment-frame cursor)))
                   (and (not (null? frame))
                        (or (and (eq? (cdr (car frame)) cell)
                                 (memq (car (car frame))
                                       (environment-imported-names cursor)))
                            (frame-loop (cdr frame)))))
                 (environment-loop (environment-parent cursor))))))

    (define (current-environment-imported? environment name)
      (memq name (environment-imported-names environment)))

    (define (environment-define! environment name value)
      (if (current-environment-imported? environment name)
          (eval-error "cannot redefine imported binding" name))
      (set-environment-frame!
       environment
       (cons (cons name (make-cell value))
             (environment-frame environment))))

    (define (environment-set! environment name value)
      (let ((cell (environment-cell environment name)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!" name))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding" name))
         (else
          (set-cell-value! cell value)))))

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

    (define (environment-cell-for-identifier environment identifier)
      (cond
       ((identifier? identifier)
        (let ((context (identifier-context identifier)))
          (if context
              (or (environment-cell environment (identifier-key identifier))
                  (let ((definition-environment
                         (syntax-context-value-environment context)))
                    (and definition-environment
                         (environment-cell definition-environment
                                           (identifier-name identifier)))))
              (environment-cell environment (identifier-name identifier)))))
       ((symbol? identifier)
        (environment-cell environment identifier))
       (else #f)))

    (define (environment-ref-identifier environment identifier)
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (if (not cell)
            (eval-error "unbound identifier" (identifier-datum-name identifier))
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   (identifier-datum-name identifier))
                  value)))))

    (define (environment-set-identifier! environment identifier value)
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!"
                      (identifier-datum-name identifier)))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding"
                      (identifier-datum-name identifier)))
         (else
          (set-cell-value! cell value)))))

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
        (make-formals '() (identifier-key formals)))
       ((identifier? formals)
        (make-formals '() (identifier-key formals)))
       (else
        (let loop ((cursor formals) (required '()))
          (cond
           ((null? cursor)
            (let ((names (reverse required)))
              (ensure-distinct-names names "lambda formals")
              (make-formals names #f)))
           ((pair? cursor)
            (loop (cdr cursor)
                  (cons (expect-identifier-key (car cursor) "lambda formal")
                        required)))
           ((identifier-datum? cursor)
            (let ((names (reverse required)))
              (ensure-distinct-names
               (append names (list (identifier-key cursor)))
                                     "lambda formals")
              (make-formals names (identifier-key cursor))))
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
            (begin
              (if (current-environment-imported? environment name)
                  (eval-error "cannot redefine imported binding" name))
              (set-cell-value! cell value))
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
              (make-bounce body-expression
                           (car body-state)
                           (context-syntax-environment context))
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
              (make-bounce (third parts)
                           environment
                           (context-syntax-environment context))
              (eval-expression (third parts) environment context #f)))
         ((= (length parts) 4)
          (if tail?
              (make-bounce (fourth parts)
                           environment
                           (context-syntax-environment context))
              (eval-expression (fourth parts) environment context #f)))
         (else
          agent-scheme-unspecified))))

    (define (eval-set! parts environment context)
      (if (not (= (length parts) 3))
          (eval-error "set! requires an identifier and an expression" parts))
      (let ((target (second parts))
            (value (eval-expression (third parts) environment context #f)))
        (if (not (identifier-datum? target))
            (eval-error "set! target must be an identifier" target))
        (environment-set-identifier! environment target value)
        agent-scheme-unspecified))

    (define (tagged-list? datum tag)
      (and (pair? datum)
           (identifier-named? (car datum) tag)))

    (define (single-argument-syntax form description)
      (let ((parts (proper-list-elements form description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description " requires exactly one operand")
             form))
        (second parts)))

    (define (syntax-error-form? form)
      (tagged-list? form 'syntax-error))

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

    (define (eval-quasiquote-list template depth environment context)
      (let loop ((cursor template) (output '()))
        (if (pair? cursor)
            (let ((element (car cursor)))
              (if (and (= depth 1)
                       (tagged-list? element 'unquote-splicing))
                  (let ((splice
                         (eval-expression
                          (single-argument-syntax
                           element
                           "unquote-splicing")
                          environment
                          context
                          #f)))
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
               (eval-expression
                (single-argument-syntax cursor "unquote")
                environment
                context
                #f))
              (else
               (eval-quasiquote-template
                cursor depth environment context)))))))

    (define (eval-quasiquote-template template depth environment context)
      (cond
       ((tagged-list? template 'unquote)
        (let ((operand (single-argument-syntax template "unquote")))
          (if (= depth 1)
              (eval-expression operand environment context #f)
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
      (if (not (= (length parts) 2))
          (eval-error "quasiquote requires exactly one template" parts))
      (eval-quasiquote-template (second parts) 1 environment context))

    (define (parse-letrec-binding binding description)
      (let ((parts (proper-list-elements binding description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description
                            " binding must contain an identifier and initializer")
             binding))
        (cons (expect-identifier-key (car parts) description)
              (second parts))))

    (define (eval-letrec parts environment context tail? sequential?)
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
                (eval-expression (cdr binding)
                                 local-environment
                                 context
                                 #f)))
             bindings)
            (let ((values
                   (map (lambda (binding)
                          (cons (car binding)
                                (eval-expression (cdr binding)
                                                 local-environment
                                                 context
                                                 #f)))
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
                       #t)))

    (define (make-empty-syntax-environment parent)
      (make-syntax-environment '() parent '()))

    (define (syntax-environment-ref syntax-environment name)
      (let loop ((cursor syntax-environment))
        (cond
         ((not cursor) #f)
         ((assq name (syntax-environment-frame cursor))
          => (lambda (cell) (cdr cell)))
         (else (loop (syntax-environment-parent cursor))))))

    (define (syntax-environment-define! syntax-environment name transformer)
      (if (memq name (syntax-environment-imported-names syntax-environment))
          (eval-error "cannot redefine imported syntax binding" name))
      (set-syntax-environment-frame!
       syntax-environment
       (cons (cons name transformer)
             (syntax-environment-frame syntax-environment))))

    (define (with-syntax-environment context syntax-environment thunk)
      (let ((old-syntax-environment (context-syntax-environment context)))
        (set-context-syntax-environment! context syntax-environment)
        (let ((value (thunk)))
          (set-context-syntax-environment! context old-syntax-environment)
          value)))

    (define (operator-shadowed? operator environment)
      (and (symbol? operator) (environment-cell environment operator)))

    (define (special-operator-active? operator environment)
      (and (identifier-datum? operator)
           (or (identifier? operator)
               (not (operator-shadowed? operator environment)))))

    (define (syntax-binding-for-operator operator environment context)
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

    (define (ellipsis-identifier? datum ellipsis)
      (and (identifier-datum? datum)
           (eq? (identifier-datum-name datum) ellipsis)))

    (define (proper-list-elements/maybe datum)
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else #f))))

    (define (syntax-rules-spec? form)
      (and (pair? form) (identifier-named? (car form) 'syntax-rules)))

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

    (define (syntax-literal? identifier literals)
      (let ((name (identifier-datum-name identifier)))
        (let loop ((rest literals))
          (cond
           ((null? rest) #f)
           ((eq? name (identifier-datum-name (car rest))) #t)
           (else (loop (cdr rest)))))))

    (define (make-pattern-bindings)
      (list 'bindings))

    (define (pattern-binding-cell bindings name)
      (assoc name (cdr bindings)))

    (define (pattern-binding bindings name)
      (let ((cell (pattern-binding-cell bindings name)))
        (if cell (cdr cell) #f)))

    (define (add-pattern-binding! bindings name entry)
      (set-cdr! bindings (cons (cons name entry) (cdr bindings))))

    (define (path-prefix? prefix path)
      (cond
       ((null? prefix) #t)
       ((null? path) #f)
       ((= (car prefix) (car path))
        (path-prefix? (cdr prefix) (cdr path)))
       (else #f)))

    (define (capture-ref captures path)
      (let ((cell (assoc path captures)))
        (if cell (cdr cell) #f)))

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

    (define (syntax-bind-pattern-variable! bindings name value path)
      (let* ((entry (ensure-pattern-binding! bindings name (length path)))
             (captures (pattern-binding-captures entry)))
        (if (assoc path captures)
            (eval-error "duplicate pattern variable" name))
        (set-pattern-binding-captures!
         entry
         (cons (cons path value) captures)))
      #t)

    (define (list-elements-tail datum)
      (let loop ((cursor datum) (elements '()))
        (if (pair? cursor)
            (loop (cdr cursor) (cons (car cursor) elements))
            (cons (reverse elements) cursor))))

    (define (append-tail elements tail)
      (if (null? elements)
          tail
          (cons (car elements) (append-tail (cdr elements) tail))))

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

    (define (list-take list count)
      (let loop ((rest list) (remaining count) (result '()))
        (if (= remaining 0)
            (reverse result)
            (loop (cdr rest) (- remaining 1) (cons (car rest) result)))))

    (define (list-drop list count)
      (if (= count 0)
          list
          (list-drop (cdr list) (- count 1))))

    (define (list-last-n list count)
      (list-drop list (- (length list) count)))

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

    (define (binding-tokens-equal? left right)
      (cond
       ((and (not left) (not right)) #t)
       ((and left right
             (eq? (car left) (car right))
             (eq? (cdr left) (cdr right)))
        #t)
       (else #f)))

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

    (define (find-ellipsis-index patterns ellipsis)
      (if (null? patterns)
          #f
          (let loop ((rest (cdr patterns)) (index 1))
            (cond
             ((null? rest) #f)
             ((ellipsis-identifier? (car rest) ellipsis) index)
             (else (loop (cdr rest) (+ index 1)))))))

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

    (define (path-add-index path index)
      (append path (list index)))

    (define (match-pattern-elements patterns pattern-tail input-elements
                                    input-tail transformer bindings path
                                    use-environment use-syntax-environment)
      (let* ((ellipsis (syntax-transformer-ellipsis transformer))
             (ellipsis-index (find-ellipsis-index patterns ellipsis)))
        (if ellipsis-index
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

    (define (max-number-list numbers)
      (let loop ((rest (cdr numbers)) (best (car numbers)))
        (if (null? rest)
            best
            (loop (cdr rest)
                  (if (> (car rest) best) (car rest) best)))))

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

    (define (expand-template template bindings syntax-context ellipsis . rest)
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

    (define (next-syntax-context! context value-environment syntax-environment)
      (let ((id (context-next-syntax-id context)))
        (set-context-next-syntax-id! context (+ id 1))
        (make-syntax-context id value-environment syntax-environment)))

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

    (define (syntax-definition-form? form)
      (and (pair? form) (identifier-named? (car form) 'define-syntax)))

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

    (define (parse-let-syntax-binding binding)
      (let ((parts (proper-list-elements binding "syntax binding")))
        (if (not (= (length parts) 2))
            (eval-error
             "syntax binding must contain a keyword and transformer spec"
             binding))
        (cons (expect-symbol (car parts) "syntax binding keyword")
              (second parts))))

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

    (define scheme-base-library-key '(scheme base))

    (define empty-emacs-capability-library-keys
      '((emacs buffer)
        (emacs buffer edit)
        (emacs command)
        (emacs project)
        (emacs window)))

    (define standard-library-keys
      '((scheme case-lambda)
        (scheme char)
        (scheme cxr)
        (scheme file)
        (scheme lazy)
        (scheme write)))

    (define case-lambda-library-source
      "(define-library (scheme case-lambda)
         (export case-lambda)
         (import (scheme base))
         (begin
           (define-syntax case-lambda
             (syntax-rules ()
               ((case-lambda)
                (lambda args (car '())))
               ((case-lambda ((param ...) body ...) more ...)
                (lambda args
                  (if (= (length args) (length '(param ...)))
                      (apply (lambda (param ...) body ...) args)
                      (apply (case-lambda more ...) args))))))))")

    (define lazy-library-source
      "(define-library (scheme lazy)
         (export delay delay-force force make-promise promise?)
         (import (scheme base))
         (begin
           (define (%promise lazy? value)
             (list 'agent-scheme-promise lazy? value))
           (define (promise? obj)
             (and (pair? obj)
                  (eq? (car obj) 'agent-scheme-promise)))
           (define (make-promise obj)
             (if (promise? obj)
                 obj
                 (%promise #t obj)))
           (define (force promise)
             (if (promise? promise)
                 (if (cadr promise)
                     (car (cdr (cdr promise)))
                     (let ((value ((car (cdr (cdr promise))))))
                       (set-car! (cdr promise) #t)
                       (set-car! (cdr (cdr promise)) value)
                       value))
                 promise))
           (define-syntax delay-force
             (syntax-rules ()
               ((delay-force expression)
                (%promise #f (lambda () expression)))))
           (define-syntax delay
             (syntax-rules ()
               ((delay expression)
                (delay-force expression))))))")

    (define (proper-library-name? datum)
      (and (pair? datum)
           (let ((parts (proper-list-elements/maybe datum)))
             (and parts
                  (let loop ((rest parts))
                    (cond
                     ((null? rest) #t)
                     ((or (symbol? (car rest))
                          (and (exact-integer? (car rest))
                               (>= (car rest) 0)))
                      (loop (cdr rest)))
                     (else #f)))))))

    (define (library-name-key name)
      (if (proper-library-name? name)
          name
          (eval-error "invalid library name" name)))

    (define (assoc/equal key alist)
      (cond
       ((null? alist) #f)
       ((equal? key (caar alist)) (car alist))
       (else (assoc/equal key (cdr alist)))))

    (define (library-registry-ref context key)
      (let ((cell (assoc/equal key (context-libraries context))))
        (if cell (cdr cell) #f)))

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

    (define (current-syntax-binding syntax-environment name)
      (let ((cell (assq name (syntax-environment-frame syntax-environment))))
        (if cell (cdr cell) #f)))

    (define (form-named? form name)
      (and (pair? form) (identifier-named? (car form) name)))

    (define (import-form? form)
      (form-named? form 'import))

    (define (define-library-form? form)
      (form-named? form 'define-library))

    (define (library-binding-with-name binding name)
      (make-library-binding
       name
       (library-binding-kind binding)
       (library-binding-object binding)
       (library-binding-library-key binding)))

    (define (same-library-binding? left right)
      (and (library-binding? left)
           (library-binding? right)
           (eq? (library-binding-kind left) (library-binding-kind right))
           (eq? (library-binding-object left)
                (library-binding-object right))))

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

    (define (register-empty-emacs-capability-library! key context)
      (if (not (library-registry-ref context key))
          (let ((value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (make-empty-syntax-environment #f)))
            (library-registry-set!
             context
             key
             (make-library key key '() value-environment syntax-environment)))))

    (define (register-source-library! source context environment)
      (eval-define-library
       (agent-scheme-read source)
       environment
       context))

    (define (find-library-export name exports)
      (cond
       ((null? exports) #f)
       ((eq? name (library-binding-name (car exports))) (car exports))
       (else (find-library-export name (cdr exports)))))

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

    (define (register-standard-library! key context environment)
      (cond
       ((equal? key '(scheme case-lambda))
        (register-source-library!
         case-lambda-library-source
         context
         environment))
       ((equal? key '(scheme char))
        (register-primitive-library!
         key
         (list (list 'char-upcase primitive-char-upcase 1 1))
         context))
       ((equal? key '(scheme cxr))
        (register-subset-library!
         key
         '(caar cadr cdar cddr)
         context
         environment))
       ((equal? key '(scheme file))
        (register-primitive-library!
         key
         (list (list 'file-exists? primitive-file-exists? 1 1))
         context))
       ((equal? key '(scheme lazy))
        (register-source-library!
         lazy-library-source
         context
         environment))
       ((equal? key '(scheme write))
        (register-primitive-library!
         key
         (list
          (list 'display primitive-display 1 2)
          (list 'write primitive-write 1 2)
          (list 'open-output-string primitive-open-output-string 0 0)
          (list 'get-output-string primitive-get-output-string 1 1))
         context))
       (else
        (eval-error "unknown standard library" key))))

    (define (library-available? name context environment)
      (let ((key (library-name-key name)))
        (or (equal? key scheme-base-library-key)
            (member key standard-library-keys)
            (member key empty-emacs-capability-library-keys)
            (and (library-registry-ref context key) #t))))

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

    (define (find-import-binding name bindings)
      (cond
       ((null? bindings) #f)
       ((eq? name (library-binding-name (car bindings))) (car bindings))
       (else (find-import-binding name (cdr bindings)))))

    (define (ensure-import-names-present names bindings description)
      (for-each
       (lambda (name)
         (if (not (find-import-binding name bindings))
             (eval-error
              (string-append description " import name not found")
              name)))
       names))

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

    (define (import-modifier-identifiers forms description)
      (map (lambda (form) (expect-symbol form description)) forms))

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

    (define (install-import-set! import-set value-environment
                                 syntax-environment context)
      (for-each
       (lambda (binding)
         (install-imported-binding! binding
                                    value-environment
                                    syntax-environment))
       (ensure-compatible-import-bindings
        (resolve-import-set import-set context value-environment))))

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

    (define (string-prefix? prefix string)
      (let ((prefix-length (string-length prefix))
            (string-length-value (string-length string)))
        (and (<= prefix-length string-length-value)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref string index))
                        (loop (+ index 1))))))))

    (define (strip-trailing-slash path)
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    (define (path-policy-allows-file? path allowed-paths)
      (let loop ((rest allowed-paths))
        (and (not (null? rest))
             (let* ((allowed (strip-trailing-slash (car rest)))
                    (allowed-directory (string-append allowed "/")))
               (or (string=? path allowed)
                   (string-prefix? allowed-directory path)
                   (loop (cdr rest)))))))

    (define (include-policy-allows-file? path context)
      (path-policy-allows-file? path (context-include-paths context)))

    (define (resolve-include-file filename context)
      (let ((path (path-join (context-include-directory context) filename)))
        (cond
         ((null? (context-include-paths context))
          (eval-error "include requires policy-gated host file access"
                      filename))
         ((not (include-policy-allows-file? path context))
          (eval-error "include file is not allowed by policy" filename))
         ((not (file-exists? path))
          (eval-error "include file is not readable" filename))
         (else path))))

    (define (path-directory path)
      (let loop ((index (- (string-length path) 1)))
        (cond
         ((< index 0) "")
         ((char=? (string-ref path index) #\/)
          (substring path 0 index))
         (else (loop (- index 1))))))

    (define (read-file-string path)
      (call-with-input-file
       path
       (lambda (port)
         (let loop ((chars '()))
           (let ((char (read-char port)))
             (if (eof-object? char)
                 (list->string (reverse chars))
                 (loop (cons char chars))))))))

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

    (define (read-include-file-forms filename context fold-case?)
      (let* ((path (resolve-include-file filename context))
             (source (read-file-string path)))
        (cons
         (agent-scheme-read-all
          (if fold-case?
              (string-append "#!fold-case\n" source)
              source))
         (path-directory path))))

    (define (library-include-body-forms declaration context fold-case?)
      (apply append
             (map (lambda (filename)
                    (car (read-include-file-forms
                          filename
                          context
                          fold-case?)))
                  (include-filenames declaration))))

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

    (define (eval-combination expression environment context tail?)
      (let ((parts (proper-list-elements expression "expression")))
        (if (null? parts)
            (eval-error "empty list is not an expression"))
        (let ((operator (car parts)))
          (cond
           ((and (identifier-named? operator 'quote)
                 (special-operator-active? operator environment))
            (if (not (= (length parts) 2))
                (eval-error "quote requires exactly one datum" parts))
            (check-value-budget (second parts) context))
           ((and (identifier-named? operator 'quasiquote)
                 (special-operator-active? operator environment))
            (check-value-budget
             (eval-quasiquote parts environment context)
             context))
           ((and (identifier-named? operator 'lambda)
                 (special-operator-active? operator environment))
            (if (< (length parts) 3)
                (eval-error "lambda requires formals and a body" parts))
            (make-procedure (parse-formals (second parts))
                            (cddr parts)
                            environment))
           ((and (identifier-named? operator 'if)
                 (special-operator-active? operator environment))
            (eval-if parts environment context tail?))
           ((and (identifier-named? operator 'set!)
                 (special-operator-active? operator environment))
            (eval-set! parts environment context))
           ((and (identifier-named? operator 'letrec)
                 (special-operator-active? operator environment))
            (eval-letrec parts environment context tail? #f))
           ((and (identifier-named? operator 'letrec*)
                 (special-operator-active? operator environment))
            (eval-letrec parts environment context tail? #t))
           ((and (identifier-named? operator 'define)
                 (special-operator-active? operator environment))
            (eval-error "define is not valid in expression position" parts))
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
       ((syntax-scope? expression)
        (with-syntax-environment
         context
         (syntax-scope-syntax-environment expression)
         (lambda ()
           (eval-sequence (syntax-scope-forms expression)
                          environment
                          context
                          tail?
                          #t))))
       ((self-evaluating? expression)
        (check-value-budget expression context))
       ((symbol? expression)
        (environment-ref-identifier environment expression))
       ((identifier? expression)
        (environment-ref-identifier environment expression))
       ((null? expression)
        (eval-error "empty list is not an expression"))
       ((pair? expression)
        (let ((expanded (expand-expression expression environment context)))
          (if (eq? expanded expression)
              (eval-combination expression environment context tail?)
              (eval-expression expanded environment context tail?))))
       (else
        (eval-error "unsupported expression datum" expression))))

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

    (define (eval-sequence forms environment context tail? allow-definitions?)
      (if allow-definitions?
          (ensure-imports-precede-body forms))
      (cond
       ((null? forms)
        agent-scheme-unspecified)
       ((null? (cdr forms))
        (let ((form (car forms)))
          (cond
           ((import-form? form)
            (if allow-definitions?
                (eval-import form environment context)
                (eval-error
                 "import is only allowed at top level or in library bodies"
                 form)))
           ((define-library-form? form)
            (if allow-definitions?
                (eval-define-library form environment context)
                (eval-error
                 "define-library is only allowed at top level"
                 form)))
           ((syntax-definition-form? form)
            (if allow-definitions?
                (eval-define-syntax
                 form
                 environment
                 context
                 (context-syntax-environment context))
                (eval-error
                 "define-syntax is only allowed before body expressions"
                 form)))
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
            (make-bounce form
                         environment
                         (context-syntax-environment context)))
           (else
            (eval-expression form environment context #f)))))
       (else
        (let ((form (car forms)))
          (cond
           ((import-form? form)
            (if allow-definitions?
                (eval-import form environment context)
                (eval-error
                 "import is only allowed at top level or in library bodies"
                 form)))
           ((define-library-form? form)
            (if allow-definitions?
                (eval-define-library form environment context)
                (eval-error
                 "define-library is only allowed at top level"
                 form)))
           ((syntax-definition-form? form)
            (if allow-definitions?
                (eval-define-syntax
                 form
                 environment
                 context
                 (context-syntax-environment context))
                (eval-error
                 "define-syntax is only allowed before body expressions"
                 form)))
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
      (let loop ((state (make-bounce expression
                                     environment
                                     (context-syntax-environment context))))
        (if (bounce? state)
            (loop
             (with-syntax-environment
              context
              (bounce-syntax-environment state)
              (lambda ()
                (eval-expression (bounce-expression state)
                                 (bounce-environment state)
                                 context
                                 #t))))
            (check-value-budget state context))))

    (define (exact-integer->host datum description)
      (if (exact-integer? datum)
          datum
          (eval-error
           (string-append description " must be an exact integer")
           datum)))

    (define (expect-nonnegative-index datum limit description allow-end?)
      (let ((index (exact-integer->host datum description)))
        (if (not (and (<= 0 index)
                      (if allow-end? (<= index limit) (< index limit))))
            (eval-error
             (string-append description " index out of range")
             index))
        index))

    (define (expect-byte datum description)
      (let ((byte (exact-integer->host datum description)))
        (if (not (and (<= 0 byte) (<= byte 255)))
            (eval-error
             (string-append description " must be in byte range")
             byte))
        byte))

    (define (expect-string datum description)
      (if (string? datum)
          datum
          (eval-error (string-append description " must be a string") datum)))

    (define (expect-character datum description)
      (if (char? datum)
          datum
          (eval-error
           (string-append description " must be a character")
           datum)))

    (define (expect-vector datum description)
      (if (vector? datum)
          datum
          (eval-error (string-append description " must be a vector") datum)))

    (define (expect-bytevector datum description)
      (if (bytevector? datum)
          datum
          (eval-error
           (string-append description " must be a bytevector")
           datum)))

    (define (expect-procedure datum description)
      (if (or (agent-scheme-procedure? datum)
              (agent-scheme-primitive-procedure? datum))
          datum
          (eval-error
           (string-append description " must be a procedure")
           datum)))

    (define (optional-range arguments offset length description)
      (let ((optional-count (- (length arguments) offset)))
        (if (not (and (<= 0 optional-count) (<= optional-count 2)))
            (eval-error
             (string-append description
                            " expected at most start and end arguments")))
        (let ((start (if (>= optional-count 1)
                         (expect-nonnegative-index
                          (list-ref arguments offset)
                          length
                          description
                          #t)
                         0))
              (end (if (>= optional-count 2)
                       (expect-nonnegative-index
                        (list-ref arguments (+ offset 1))
                        length
                        description
                        #t)
                       length)))
          (if (> start end)
              (eval-error
               (string-append description " start index exceeds end index")))
          (cons start end))))

    (define (primitive+ arguments context)
      (apply + arguments))

    (define (primitive* arguments context)
      (apply * arguments))

    (define (scheme-divide left right)
      (if (zero? right)
          (eval-error "division by zero"))
      (if (and (integer? left) (integer? right)
               (zero? (remainder left right)))
          (/ left right)
          (inexact (/ left right))))

    (define (primitive- arguments context)
      (if (= (length arguments) 1)
          (- (car arguments))
          (apply - arguments)))

    (define (primitive/ arguments context)
      (if (= (length arguments) 1)
          (scheme-divide 1 (car arguments))
          (let loop ((result (car arguments)) (rest (cdr arguments)))
            (if (null? rest)
                result
                (loop (scheme-divide result (car rest))
                      (cdr rest))))))

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

    (define (primitive-abs arguments context)
      (abs (car arguments)))

    (define (primitive-min arguments context)
      (apply min arguments))

    (define (primitive-max arguments context)
      (apply max arguments))

    (define (primitive-square arguments context)
      (* (car arguments) (car arguments)))

    (define (primitive-zero? arguments context)
      (zero? (car arguments)))

    (define (primitive-positive? arguments context)
      (positive? (car arguments)))

    (define (primitive-negative? arguments context)
      (negative? (car arguments)))

    (define (primitive-odd? arguments context)
      (odd? (exact-integer->host (car arguments) "odd?")))

    (define (primitive-even? arguments context)
      (even? (exact-integer->host (car arguments) "even?")))

    (define (integer-quotient arguments quotient-function description)
      (let ((left (exact-integer->host (car arguments) description))
            (right (exact-integer->host (second arguments) description)))
        (if (zero? right)
            (eval-error (string-append description " division by zero")))
        (quotient-function left right)))

    (define (primitive-quotient arguments context)
      (integer-quotient arguments truncate-quotient "quotient"))

    (define (primitive-floor-quotient arguments context)
      (integer-quotient arguments floor-quotient "floor-quotient"))

    (define (primitive-truncate-quotient arguments context)
      (integer-quotient arguments truncate-quotient "truncate-quotient"))

    (define (primitive-remainder arguments context)
      (let ((left (exact-integer->host (car arguments) "remainder"))
            (right (exact-integer->host (second arguments) "remainder")))
        (if (zero? right)
            (eval-error "remainder division by zero"))
        (truncate-remainder left right)))

    (define (primitive-modulo arguments context)
      (let ((left (exact-integer->host (car arguments) "modulo"))
            (right (exact-integer->host (second arguments) "modulo")))
        (if (zero? right)
            (eval-error "modulo division by zero"))
        (floor-remainder left right)))

    (define (primitive-floor-remainder arguments context)
      (primitive-modulo arguments context))

    (define (primitive-truncate-remainder arguments context)
      (primitive-remainder arguments context))

    (define (primitive-floor arguments context)
      (floor (car arguments)))

    (define (primitive-ceiling arguments context)
      (ceiling (car arguments)))

    (define (primitive-truncate arguments context)
      (truncate (car arguments)))

    (define (primitive-round arguments context)
      (round (car arguments)))

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

    (define (proper-list? value)
      (let loop ((cursor value) (seen '()))
        (cond
         ((null? cursor) #t)
         ((not (pair? cursor)) #f)
         ((memq cursor seen) #f)
         (else (loop (cdr cursor) (cons cursor seen))))))

    (define (primitive-list? arguments context)
      (proper-list? (car arguments)))

    (define (primitive-length arguments context)
      (length (proper-list-elements (car arguments) "length")))

    (define (primitive-append arguments context)
      (apply append arguments))

    (define (primitive-reverse arguments context)
      (reverse (proper-list-elements (car arguments) "reverse")))

    (define (primitive-list-tail arguments context)
      (let ((index (exact-integer->host (second arguments) "list-tail")))
        (if (< index 0)
            (eval-error "list-tail index must be non-negative"))
        (let loop ((cursor (car arguments)) (remaining index))
          (cond
           ((zero? remaining) cursor)
           ((pair? cursor) (loop (cdr cursor) (- remaining 1)))
           (else (eval-error "list-tail index exceeds list length"))))))

    (define (primitive-list-ref arguments context)
      (let ((tail (primitive-list-tail arguments context)))
        (if (pair? tail)
            (car tail)
            (eval-error "list-ref index exceeds list length"))))

    (define (primitive-list-set! arguments context)
      (let ((tail (primitive-list-tail arguments context)))
        (if (not (pair? tail))
            (eval-error "list-set! index exceeds list length"))
        (set-car! tail (third arguments))
        agent-scheme-unspecified))

    (define (primitive-set-car! arguments context)
      (let ((pair (car arguments)))
        (if (not (pair? pair))
            (eval-error "set-car! expected pair" pair))
        (set-car! pair (second arguments))
        agent-scheme-unspecified))

    (define (primitive-set-cdr! arguments context)
      (let ((pair (car arguments)))
        (if (not (pair? pair))
            (eval-error "set-cdr! expected pair" pair))
        (set-cdr! pair (second arguments))
        agent-scheme-unspecified))

    (define (primitive-make-list arguments context)
      (let ((length (exact-integer->host (car arguments) "make-list"))
            (fill (if (null? (cdr arguments))
                      agent-scheme-unspecified
                      (second arguments))))
        (if (< length 0)
            (eval-error "make-list length must be non-negative"))
        (make-list length fill)))

    (define (copy-list value)
      (cond
       ((null? value) '())
       ((pair? value) (cons (car value) (copy-list (cdr value))))
       (else value)))

    (define (primitive-list-copy arguments context)
      (copy-list (car arguments)))

    (define (primitive-caar arguments context)
      (primitive-car (list (primitive-car arguments context)) context))

    (define (primitive-cadr arguments context)
      (primitive-car (list (primitive-cdr arguments context)) context))

    (define (primitive-cdar arguments context)
      (primitive-cdr (list (primitive-car arguments context)) context))

    (define (primitive-cddr arguments context)
      (primitive-cdr (list (primitive-cdr arguments context)) context))

    (define (primitive-null? arguments context)
      (null? (car arguments)))

    (define (primitive-pair? arguments context)
      (pair? (car arguments)))

    (define (primitive-not arguments context)
      (if (eq? (car arguments) #f) #t #f))

    (define (primitive-boolean? arguments context)
      (boolean? (car arguments)))

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

    (define (primitive-number? arguments context)
      (number? (car arguments)))

    (define (primitive-complex? arguments context)
      (complex? (car arguments)))

    (define (primitive-real? arguments context)
      (real? (car arguments)))

    (define (primitive-rational? arguments context)
      (rational? (car arguments)))

    (define (primitive-integer? arguments context)
      (integer? (car arguments)))

    (define (primitive-exact-integer? arguments context)
      (exact-integer? (car arguments)))

    (define (primitive-exact? arguments context)
      (and (number? (car arguments)) (exact? (car arguments))))

    (define (primitive-inexact? arguments context)
      (and (number? (car arguments)) (inexact? (car arguments))))

    (define (primitive-number->string arguments context)
      (if (not (number? (car arguments)))
          (eval-error "number->string expected a number"))
      (number->string (car arguments)))

    (define (primitive-string->number arguments context)
      (let ((source (expect-string (car arguments) "string->number")))
        (guard (condition (else #f))
          (let ((datum (agent-scheme-read source)))
            (if (number? datum) datum #f)))))

    (define (primitive-symbol? arguments context)
      (symbol? (car arguments)))

    (define (primitive-symbol->string arguments context)
      (if (not (symbol? (car arguments)))
          (eval-error "symbol->string expected a symbol"))
      (symbol->string (car arguments)))

    (define (primitive-string->symbol arguments context)
      (string->symbol (expect-string (car arguments) "string->symbol")))

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

    (define (primitive-char? arguments context)
      (char? (car arguments)))

    (define (primitive-char->integer arguments context)
      (char->integer
       (expect-character (car arguments) "char->integer")))

    (define (primitive-integer->char arguments context)
      (integer->char
       (exact-integer->host (car arguments) "integer->char")))

    (define (primitive-char-compare arguments predicate description)
      (let loop ((rest arguments))
        (cond
         ((or (null? rest) (null? (cdr rest))) #t)
         (else
          (let ((left (expect-character (car rest) description))
                (right (expect-character (second rest) description)))
            (and (predicate left right) (loop (cdr rest))))))))

    (define (primitive-char=? arguments context)
      (primitive-char-compare arguments char=? "char=?"))

    (define (primitive-char<? arguments context)
      (primitive-char-compare arguments char<? "char<?"))

    (define (primitive-char>? arguments context)
      (primitive-char-compare arguments char>? "char>?"))

    (define (primitive-char<=? arguments context)
      (primitive-char-compare arguments char<=? "char<=?"))

    (define (primitive-char>=? arguments context)
      (primitive-char-compare arguments char>=? "char>=?"))

    (define (primitive-char-upcase arguments context)
      (char-upcase (expect-character (car arguments) "char-upcase")))

    (define (display-string value)
      (cond
       ((string? value) value)
       ((char? value) (string value))
       (else (agent-scheme-value->external value))))

    (define (expect-string-output-port value description)
      (if (not (string-output-port? value))
          (eval-error
           (string-append description " expected an output string port")
           value))
      value)

    (define (write-to-output-port value port display?)
      (set-string-output-port-contents!
       port
       (string-append
        (string-output-port-contents port)
        (if display?
            (display-string value)
            (agent-scheme-value->external value))))
      agent-scheme-unspecified)

    (define (primitive-open-output-string arguments context)
      (make-string-output-port ""))

    (define (primitive-get-output-string arguments context)
      (string-output-port-contents
       (expect-string-output-port
        (car arguments)
        "get-output-string")))

    (define (primitive-display arguments context)
      (if (null? (cdr arguments))
          agent-scheme-unspecified
          (write-to-output-port
           (car arguments)
           (expect-string-output-port (second arguments) "display")
           #t)))

    (define (primitive-write arguments context)
      (if (null? (cdr arguments))
          agent-scheme-unspecified
          (write-to-output-port
           (car arguments)
           (expect-string-output-port (second arguments) "write")
           #f)))

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

    (define (primitive-file-exists? arguments context)
      (let ((path
             (resolve-file-policy-path
              (expect-string (car arguments) "file-exists?")
              context
              "file-exists?")))
        (file-exists? path)))

    (define (primitive-string? arguments context)
      (string? (car arguments)))

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

    (define (primitive-string arguments context)
      (list->string
       (map (lambda (argument)
              (expect-character argument "string"))
            arguments)))

    (define (primitive-string-length arguments context)
      (string-length (expect-string (car arguments) "string-length")))

    (define (primitive-string-ref arguments context)
      (let* ((string (expect-string (car arguments) "string-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (string-length string)
                     "string-ref"
                     #f)))
        (string-ref string index)))

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

    (define (primitive-string-append arguments context)
      (apply string-append
             (map (lambda (argument)
                    (expect-string argument "string-append"))
                  arguments)))

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

    (define (primitive-list->string arguments context)
      (list->string
       (map (lambda (argument)
              (expect-character argument "list->string"))
            (proper-list-elements (car arguments) "list->string"))))

    (define (primitive-string->vector arguments context)
      (list->vector (primitive-string->list arguments context)))

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

    (define (primitive-string-copy arguments context)
      (let* ((string (expect-string (car arguments) "string-copy"))
             (range (optional-range
                     arguments
                     1
                     (string-length string)
                     "string-copy")))
        (substring string (car range) (cdr range))))

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

    (define (primitive-string-compare arguments predicate description)
      (let loop ((rest arguments))
        (cond
         ((or (null? rest) (null? (cdr rest))) #t)
         (else
          (let ((left (expect-string (car rest) description))
                (right (expect-string (second rest) description)))
            (and (predicate left right) (loop (cdr rest))))))))

    (define (primitive-string=? arguments context)
      (primitive-string-compare arguments string=? "string=?"))

    (define (primitive-string<? arguments context)
      (primitive-string-compare arguments string<? "string<?"))

    (define (primitive-string>? arguments context)
      (primitive-string-compare arguments string>? "string>?"))

    (define (primitive-string<=? arguments context)
      (primitive-string-compare arguments string<=? "string<=?"))

    (define (primitive-string>=? arguments context)
      (primitive-string-compare arguments string>=? "string>=?"))

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
                      (cons value results)
                      results)))))))

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

    (define (primitive-map arguments context)
      (map-over-lists
       (expect-procedure (car arguments) "map procedure")
       (cdr arguments)
       context
       #t))

    (define (primitive-for-each arguments context)
      (map-over-lists
       (expect-procedure (car arguments) "for-each procedure")
       (cdr arguments)
       context
       #f))

    (define (primitive-string-map arguments context)
      (let* ((procedure (expect-procedure
                         (car arguments)
                         "string-map procedure"))
             (strings (map (lambda (argument)
                             (expect-string argument "string-map"))
                           (cdr arguments)))
             (limit (apply min (map string-length strings))))
        (let loop ((index 0) (result '()))
          (if (= index limit)
              (list->string (reverse result))
              (let ((value
                     (apply-procedure
                      procedure
                      (map (lambda (string) (string-ref string index))
                           strings)
                      context
                      #f)))
                (loop (+ index 1)
                      (cons (expect-character value "string-map result")
                            result)))))))

    (define (primitive-string-for-each arguments context)
      (let* ((procedure (expect-procedure
                         (car arguments)
                         "string-for-each procedure"))
             (strings (map (lambda (argument)
                             (expect-string argument "string-for-each"))
                           (cdr arguments)))
             (limit (apply min (map string-length strings))))
        (let loop ((index 0))
          (if (< index limit)
              (begin
                (apply-procedure
                 procedure
                 (map (lambda (string) (string-ref string index)) strings)
                 context
                 #f)
                (loop (+ index 1)))))
        agent-scheme-unspecified))

    (define (primitive-vector? arguments context)
      (vector? (car arguments)))

    (define (primitive-make-vector arguments context)
      (let ((length (exact-integer->host (car arguments) "make-vector"))
            (fill (if (null? (cdr arguments))
                      agent-scheme-unspecified
                      (second arguments))))
        (if (< length 0)
            (eval-error "make-vector length must be non-negative"))
        (make-vector length fill)))

    (define (primitive-vector arguments context)
      (list->vector arguments))

    (define (primitive-vector-length arguments context)
      (vector-length (expect-vector (car arguments) "vector-length")))

    (define (primitive-vector-ref arguments context)
      (let* ((vector (expect-vector (car arguments) "vector-ref"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (vector-length vector)
                     "vector-ref"
                     #f)))
        (vector-ref vector index)))

    (define (primitive-vector-set! arguments context)
      (let* ((vector (expect-vector (car arguments) "vector-set!"))
             (index (expect-nonnegative-index
                     (second arguments)
                     (vector-length vector)
                     "vector-set!"
                     #f)))
        (vector-set! vector index (third arguments))
        agent-scheme-unspecified))

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

    (define (primitive-list->vector arguments context)
      (list->vector
       (proper-list-elements (car arguments) "list->vector")))

    (define (primitive-vector-copy arguments context)
      (list->vector (primitive-vector->list arguments context)))

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

    (define (primitive-vector-append arguments context)
      (list->vector
       (apply append
              (map (lambda (argument)
                     (vector->list
                      (expect-vector argument "vector-append")))
                   arguments))))

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

    (define (primitive-vector-map arguments context)
      (let* ((procedure (expect-procedure
                         (car arguments)
                         "vector-map procedure"))
             (vectors (map (lambda (argument)
                             (expect-vector argument "vector-map"))
                           (cdr arguments)))
             (limit (apply min (map vector-length vectors))))
        (let loop ((index 0) (result '()))
          (if (= index limit)
              (list->vector (reverse result))
              (loop (+ index 1)
                    (cons
                     (apply-procedure
                      procedure
                      (map (lambda (vector) (vector-ref vector index))
                           vectors)
                      context
                      #f)
                     result))))))

    (define (primitive-vector-for-each arguments context)
      (primitive-vector-map arguments context)
      agent-scheme-unspecified)

    (define (primitive-bytevector? arguments context)
      (bytevector? (car arguments)))

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

    (define (primitive-bytevector arguments context)
      (apply bytevector
             (map (lambda (argument)
                    (expect-byte argument "bytevector"))
                  arguments)))

    (define (primitive-bytevector-length arguments context)
      (bytevector-length
       (expect-bytevector (car arguments) "bytevector-length")))

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

    (define (primitive-bytevector-copy arguments context)
      (let* ((bytevector
              (expect-bytevector (car arguments) "bytevector-copy"))
             (range (optional-range
                     arguments
                     1
                     (bytevector-length bytevector)
                     "bytevector-copy")))
        (bytevector-copy bytevector (car range) (cdr range))))

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

    (define (primitive-bytevector-append arguments context)
      (apply bytevector-append
             (map (lambda (argument)
                    (expect-bytevector argument "bytevector-append"))
                  arguments)))

    (define (primitive-procedure? arguments context)
      (or (agent-scheme-procedure? (car arguments))
          (agent-scheme-primitive-procedure? (car arguments))))

    (define (primitive-eq? arguments context)
      (eq? (car arguments) (second arguments)))

    (define (primitive-eqv? arguments context)
      (eqv? (car arguments) (second arguments)))

    (define (primitive-equal? arguments context)
      (equal? (car arguments) (second arguments)))

    (define (primitive-memq arguments context)
      (let ((result (memq (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-memv arguments context)
      (let ((result (memv (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-member arguments context)
      (let ((result (member (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-assq arguments context)
      (let ((result (assq (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-assv arguments context)
      (let ((result (assv (car arguments) (second arguments))))
        (if result result #f)))

    (define (primitive-assoc arguments context)
      (let ((result (assoc (car arguments) (second arguments))))
        (if result result #f)))

    (define base-primitive-registry
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
       (list 'car primitive-car 1 1)
       (list 'cdr primitive-cdr 1 1)
       (list 'ceiling primitive-ceiling 1 1)
       (list 'char->integer primitive-char->integer 1 1)
       (list 'char<=? primitive-char<=? 2 #f)
       (list 'char<? primitive-char<? 2 #f)
       (list 'char=? primitive-char=? 2 #f)
       (list 'char>=? primitive-char>=? 2 #f)
       (list 'char>? primitive-char>? 2 #f)
       (list 'char? primitive-char? 1 1)
       (list 'complex? primitive-complex? 1 1)
       (list 'cons primitive-cons 2 2)
       (list 'eq? primitive-eq? 2 2)
       (list 'equal? primitive-equal? 2 2)
       (list 'eqv? primitive-eqv? 2 2)
       (list 'exact-integer? primitive-exact-integer? 1 1)
       (list 'exact? primitive-exact? 1 1)
       (list 'floor primitive-floor 1 1)
       (list 'floor-quotient primitive-floor-quotient 2 2)
       (list 'floor-remainder primitive-floor-remainder 2 2)
       (list 'inexact? primitive-inexact? 1 1)
       (list 'integer->char primitive-integer->char 1 1)
       (list 'integer? primitive-integer? 1 1)
       (list 'list->string primitive-list->string 1 1)
       (list 'list->vector primitive-list->vector 1 1)
       (list 'list? primitive-list? 1 1)
       (list 'make-bytevector primitive-make-bytevector 1 2)
       (list 'make-string primitive-make-string 1 2)
       (list 'make-vector primitive-make-vector 1 2)
       (list 'modulo primitive-modulo 2 2)
       (list 'null? primitive-null? 1 1)
       (list 'number->string primitive-number->string 1 1)
       (list 'number? primitive-number? 1 1)
       (list 'pair? primitive-pair? 1 1)
       (list 'procedure? primitive-procedure? 1 1)
       (list 'quotient primitive-quotient 2 2)
       (list 'rational? primitive-rational? 1 1)
       (list 'real? primitive-real? 1 1)
       (list 'remainder primitive-remainder 2 2)
       (list 'round primitive-round 1 1)
       (list 'set-car! primitive-set-car! 2 2)
       (list 'set-cdr! primitive-set-cdr! 2 2)
       (list 'string primitive-string 0 #f)
       (list 'string->list primitive-string->list 1 3)
       (list 'string->number primitive-string->number 1 1)
       (list 'string->symbol primitive-string->symbol 1 1)
       (list 'string->vector primitive-string->vector 1 3)
       (list 'string-append primitive-string-append 0 #f)
       (list 'string-copy primitive-string-copy 1 3)
       (list 'string-copy! primitive-string-copy! 3 5)
       (list 'string-fill! primitive-string-fill! 2 4)
       (list 'string-for-each primitive-string-for-each 2 #f)
       (list 'string-length primitive-string-length 1 1)
       (list 'string-map primitive-string-map 2 #f)
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
       (list 'truncate primitive-truncate 1 1)
       (list 'truncate-quotient primitive-truncate-quotient 2 2)
       (list 'truncate-remainder primitive-truncate-remainder 2 2)
       (list 'vector primitive-vector 0 #f)
       (list 'vector->list primitive-vector->list 1 3)
       (list 'vector->string primitive-vector->string 1 3)
       (list 'vector-append primitive-vector-append 0 #f)
       (list 'vector-copy primitive-vector-copy 1 3)
       (list 'vector-copy! primitive-vector-copy! 3 5)
       (list 'vector-fill! primitive-vector-fill! 2 4)
       (list 'vector-for-each primitive-vector-for-each 2 #f)
       (list 'vector-length primitive-vector-length 1 1)
       (list 'vector-map primitive-vector-map 2 #f)
       (list 'vector-ref primitive-vector-ref 2 2)
       (list 'vector-set! primitive-vector-set! 3 3)
       (list 'vector? primitive-vector? 1 1)))

    (define (agent-scheme-base-primitive-names)
      (map car base-primitive-registry))

    (define (agent-scheme-base-primitive-specs)
      (map (lambda (entry)
             (list (list 'name (car entry))
                   (list 'minimum-arity (third entry))
                   (list 'maximum-arity (fourth entry))
                   (list 'source 'kernel)))
           base-primitive-registry))

    (define agent-scheme-base-prelude-load-paths
      '("scheme/agent-scheme/base-prelude.scm"
        "agent-scheme/base-prelude.scm"))

    (define agent-scheme-base-syntax-load-paths
      '("scheme/agent-scheme/base-syntax.scm"
        "agent-scheme/base-syntax.scm"))

    (define (read-all-datums port)
      (let ((datum (read port)))
        (if (eof-object? datum)
            '()
            (cons datum (read-all-datums port)))))

    (define (base-prelude-forms)
      (let try ((paths agent-scheme-base-prelude-load-paths))
        (if (null? paths)
            (eval-error "unable to load base prelude")
            (guard (condition
                    (else (try (cdr paths))))
              (call-with-input-file (car paths) read-all-datums)))))

    (define (base-syntax-forms)
      (let try ((paths agent-scheme-base-syntax-load-paths))
        (if (null? paths)
            (eval-error "unable to load base syntax prelude")
            (guard (condition
                    (else (try (cdr paths))))
              (call-with-input-file (car paths) read-all-datums)))))

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

    (define (agent-scheme-base-prelude-binding-specs)
      (map prelude-definition-spec (base-prelude-forms)))

    (define (agent-scheme-base-prelude-binding-names)
      (map (lambda (spec)
             (second (assq 'name spec)))
           (agent-scheme-base-prelude-binding-specs)))

    (define (agent-scheme-base-binding-specs)
      (append (agent-scheme-base-primitive-specs)
              (agent-scheme-base-prelude-binding-specs)))

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
        (let loop ((rest base-primitive-registry))
          (if (null? rest)
              (begin
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
        (ensure-base-syntax! context environment)
        (trampoline expression environment context)))

    (define (agent-scheme-eval-source source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest))
            (forms (agent-scheme-read-all source)))
        (ensure-base-syntax! context environment)
        (trampoline (make-sequence forms #t) environment context)))

    (define agent-scheme-eval-string agent-scheme-eval-source)

    (define (agent-scheme-expand expression . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (ensure-base-syntax! context environment)
        (expand-expression/fully expression environment context)))

    (define (agent-scheme-expand-source source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest))
            (forms (agent-scheme-read-all source)))
        (ensure-base-syntax! context environment)
        (expand-sequence-forms forms environment context #t)))

    (define (result-field name . values)
      (cons name values))

    (define (value->result-datum value . maybe-seen)
      (let ((seen (if (null? maybe-seen) '() (car maybe-seen))))
        (cond
         ((or (boolean? value)
              (null? value)
              (symbol? value)
              (char? value)
              (number? value)
              (string? value)
              (bytevector? value))
          value)
         ((identifier? value)
          (identifier-name value))
         ((agent-scheme-unspecified? value)
          '(unspecified))
         ((agent-scheme-primitive-procedure? value)
          (list 'procedure
                (result-field 'kind 'primitive)
                (result-field 'name (primitive-procedure-name value))))
         ((agent-scheme-procedure? value)
          (list 'procedure (result-field 'kind 'compound)))
         ((pair? value)
          (if (memq value seen)
              '(cycle)
              (cons (value->result-datum (car value) (cons value seen))
                    (value->result-datum (cdr value) (cons value seen)))))
         ((vector? value)
          (if (memq value seen)
              #(cycle)
              (list->vector
               (map (lambda (item)
                      (value->result-datum item (cons value seen)))
                    (vector->list value)))))
         (else
         (list 'host-object
                (result-field 'printed "#<host-object>"))))))

    (define (strip-identifiers value . maybe-seen)
      (let ((seen (if (null? maybe-seen) '() (car maybe-seen))))
        (cond
         ((identifier? value)
          (identifier-name value))
         ((pair? value)
          (if (memq value seen)
              value
              (cons (strip-identifiers (car value) (cons value seen))
                    (strip-identifiers (cdr value) (cons value seen)))))
         ((vector? value)
          (if (memq value seen)
              value
              (list->vector
               (map (lambda (item)
                      (strip-identifiers item (cons value seen)))
                    (vector->list value)))))
         (else value))))

    (define (budget-result-field context)
      (result-field
       'budget
       (result-field 'steps-used (context-steps context))
       (result-field 'host-calls (context-host-callbacks context))))

    (define (ok-result-datum value context)
      (list 'evaluation-result
            (result-field 'status 'ok)
            (result-field 'value (value->result-datum value))
            (result-field 'events '())
            (budget-result-field context)))

    (define (condition-message condition)
      (if (error-object? condition)
          (error-object-message condition)
          "error"))

    (define (condition-result-datum condition context)
      (list 'evaluation-result
            (result-field 'status 'error)
            (result-field
             'error
             (result-field 'condition 'error)
             (result-field 'message (condition-message condition)))
            (result-field 'events '())
            (budget-result-field context)))

    (define (agent-scheme-eval-result expression . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (ensure-base-syntax! context environment)
        (guard (condition
                (else (condition-result-datum condition context)))
          (ok-result-datum
           (trampoline expression environment context)
           context))))

    (define (agent-scheme-eval-source-result source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
        (ensure-base-syntax! context environment)
        (guard (condition
                (else (condition-result-datum condition context)))
          (let ((forms (agent-scheme-read-all source)))
            (ok-result-datum
             (trampoline (make-sequence forms #t) environment context)
             context)))))

    (define (agent-scheme-result->external result)
      (agent-scheme-datum->external result))

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
        (agent-scheme-datum->external (strip-identifiers value)))))))
