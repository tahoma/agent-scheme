(define-library (agent-scheme eval)
  (export agent-scheme-eval
          agent-scheme-eval-source
          agent-scheme-eval-string
          agent-scheme-eval-result
          agent-scheme-eval-source-result
          agent-scheme-make-empty-environment
          agent-scheme-make-base-environment
          agent-scheme-base-primitive-names
          agent-scheme-base-primitive-specs
          agent-scheme-result->external
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
       (list 'abs primitive-abs 1 1)
       (list 'append primitive-append 0 #f)
       (list 'apply primitive-apply 2 #f)
       (list 'assoc primitive-assoc 2 2)
       (list 'assq primitive-assq 2 2)
       (list 'assv primitive-assv 2 2)
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
       (list 'caar primitive-caar 1 1)
       (list 'cadr primitive-cadr 1 1)
       (list 'car primitive-car 1 1)
       (list 'cdar primitive-cdar 1 1)
       (list 'cddr primitive-cddr 1 1)
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
       (list 'even? primitive-even? 1 1)
       (list 'exact-integer? primitive-exact-integer? 1 1)
       (list 'exact? primitive-exact? 1 1)
       (list 'floor primitive-floor 1 1)
       (list 'floor-quotient primitive-floor-quotient 2 2)
       (list 'floor-remainder primitive-floor-remainder 2 2)
       (list 'for-each primitive-for-each 2 #f)
       (list 'inexact? primitive-inexact? 1 1)
       (list 'integer->char primitive-integer->char 1 1)
       (list 'integer? primitive-integer? 1 1)
       (list 'length primitive-length 1 1)
       (list 'list primitive-list 0 #f)
       (list 'list->string primitive-list->string 1 1)
       (list 'list->vector primitive-list->vector 1 1)
       (list 'list-copy primitive-list-copy 1 1)
       (list 'list-ref primitive-list-ref 2 2)
       (list 'list-set! primitive-list-set! 3 3)
       (list 'list-tail primitive-list-tail 2 2)
       (list 'list? primitive-list? 1 1)
       (list 'make-bytevector primitive-make-bytevector 1 2)
       (list 'make-list primitive-make-list 1 2)
       (list 'make-string primitive-make-string 1 2)
       (list 'make-vector primitive-make-vector 1 2)
       (list 'map primitive-map 2 #f)
       (list 'max primitive-max 1 #f)
       (list 'member primitive-member 2 2)
       (list 'memq primitive-memq 2 2)
       (list 'memv primitive-memv 2 2)
       (list 'min primitive-min 1 #f)
       (list 'modulo primitive-modulo 2 2)
       (list 'negative? primitive-negative? 1 1)
       (list 'not primitive-not 1 1)
       (list 'null? primitive-null? 1 1)
       (list 'number->string primitive-number->string 1 1)
       (list 'number? primitive-number? 1 1)
       (list 'odd? primitive-odd? 1 1)
       (list 'pair? primitive-pair? 1 1)
       (list 'positive? primitive-positive? 1 1)
       (list 'procedure? primitive-procedure? 1 1)
       (list 'quotient primitive-quotient 2 2)
       (list 'rational? primitive-rational? 1 1)
       (list 'real? primitive-real? 1 1)
       (list 'remainder primitive-remainder 2 2)
       (list 'reverse primitive-reverse 1 1)
       (list 'round primitive-round 1 1)
       (list 'set-car! primitive-set-car! 2 2)
       (list 'set-cdr! primitive-set-cdr! 2 2)
       (list 'square primitive-square 1 1)
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
       (list 'vector? primitive-vector? 1 1)
       (list 'zero? primitive-zero? 1 1)))

    (define (agent-scheme-base-primitive-names)
      (map car base-primitive-registry))

    (define (agent-scheme-base-primitive-specs)
      (map (lambda (entry)
             (list (list 'name (car entry))
                   (list 'minimum-arity (third entry))
                   (list 'maximum-arity (fourth entry))))
           base-primitive-registry))

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
              environment
              (begin
                (define-primitive! environment
                                   (car (car rest))
                                   (second (car rest))
                                   (third (car rest))
                                   (fourth (car rest)))
                (loop (cdr rest)))))))

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
        (guard (condition
                (else (condition-result-datum condition context)))
          (ok-result-datum
           (trampoline expression environment context)
           context))))

    (define (agent-scheme-eval-source-result source . rest)
      (let ((context (new-eval-context (rest-options rest)))
            (environment (rest-environment rest)))
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
        (agent-scheme-datum->external value))))))
