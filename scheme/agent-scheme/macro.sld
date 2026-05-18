;;; Portable Agent Scheme macro expansion and syntax environments.
;;;
;;; This library owns syntax environments, syntax-rules expansion, recursive
;;; expansion helpers, and public expansion entry points.

(define-library (agent-scheme macro)
  (export agent-scheme-expand
          agent-scheme-expand-source
          definition-form?
          define-values-form?
          begin-form?
          make-lambda-expression
          parse-definition
          parse-define-values
          formals-names
          define-values-bound-names
          record-definition-form?
          body-definition-form?
          tagged-list?
          single-argument-syntax
          syntax-error-form?
          syntax-error-message
          raise-syntax-error
          make-empty-syntax-environment
          syntax-environment-ref
          syntax-environment-define!
          with-syntax-environment
          special-operator-active?
          syntax-binding-for-operator
          proper-list-elements/maybe
          append-tail
          syntax-definition-form?
          eval-define-syntax
          make-local-syntax-scope
          expand-expression
          expand-expression/fully
          expand-sequence-forms)
  (import (scheme base)
          (scheme char)
          (agent-scheme reader)
          (except (agent-scheme runtime) make-parameter)
          (agent-scheme result)
          (agent-scheme base)
          (agent-scheme library))
  (begin
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

    ;; Return every symbol named by parsed FORMALS.
    (define (formals-names formals)
      (if (formals-rest formals)
          (append (formals-required formals) (list (formals-rest formals)))
          (formals-required formals)))

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
    (define (macro-rest-environment rest)
      (if (or (null? rest) (not (car rest)))
          (agent-scheme-make-base-environment)
          (car rest)))

    ;; Return the optional caller options alist, defaulting to empty.
    (define (macro-rest-options rest)
      (if (or (null? rest) (null? (cdr rest)))
          '()
          (second rest)))

    ;; Fully expand one already-read expression without evaluating its result.
    (define (agent-scheme-expand expression . rest)
      (let ((context (new-eval-context (macro-rest-options rest)))
            (environment (macro-rest-environment rest)))
        (ensure-base-syntax! context environment)
        (expand-expression/fully expression environment context)))

    ;; Read and expand a source body, preserving top-level definition structure
    ;; for tests and future compiler/backend passes.
    (define (agent-scheme-expand-source source . rest)
      (let ((context (new-eval-context (macro-rest-options rest)))
            (environment (macro-rest-environment rest))
            (forms (agent-scheme-read-all source)))
        (ensure-base-syntax! context environment)
        (expand-sequence-forms forms environment context #t)))

    ))
