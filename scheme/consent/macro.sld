;;; Portable Consent Scheme macro expansion and syntax environments.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns syntax environments, syntax-rules expansion, recursive
;;; expansion helpers, and public expansion entry points.

(define-library (consent macro)
  (export consent-expand
          consent-expand-source
          consent-macroexpand
          consent-macroexpand-1
          consent-macroexpand-library
          consent-macro-binding-info
          consent-syntax-source
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
          (consent reader)
          (consent runtime)
          (consent result)
          (consent base)
          (consent library))
  (begin
    (define (definition-form? form)
      "Report whether FORM is a core define form headed by the raw symbol."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description
          ("True when FORM is a pair whose head is the raw symbol"
            "define.")))
        (effects pure))
      (and (pair? form) (eq? (car form) 'define)))

    (define (define-values-form? form)
      "Report whether FORM is a define-values form after identifier unwrapping."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description ("True when FORM is a pair whose head names define-values.")))
        (effects pure))
      (and (pair? form) (identifier-named? (car form) 'define-values)))

    (define (begin-form? form)
      "Report whether FORM is a core begin form headed by the raw symbol."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description
          ("True when FORM is a pair whose head is the raw symbol"
            "begin.")))
        (effects pure))
      (and (pair? form) (eq? (car form) 'begin)))

    (define (make-lambda-expression formals body)
      "Construct the lambda expression used by function-definition shorthand."
      #((parameters
         (formals
          (type list)
          (description "Formal parameter list for the lambda."))
         (body
          (type list)
          (description "List of body forms for the lambda.")))
        (returns
         (type pair)
         (description
          ("A lambda expression consing FORMALS and BODY after the"
            "lambda symbol.")))
        (effects allocation))
      (cons 'lambda (cons formals body)))

    (define (parse-definition form)
      "Parse variable or procedure define syntax into a name/expression pair."
      #((parameters
         (form . "A define form to parse."))
        (returns
         (type pair)
         (description
          ("A pair of the bound identifier key and its value"
            "expression.")))
        (effects error))
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

    (define (parse-define-values form)
      "Parse define-values syntax into formals metadata and an initializer."
      #((parameters
         (form . "A define-values form to parse."))
        (returns
         (type pair)
         (description
          ("A pair of parsed formals metadata and the initializer"
            "expression.")))
        (effects error))
      (let ((parts (proper-list-elements form "define-values form")))
        (if (not (= (length parts) 3))
            (eval-error
             "define-values requires formals and one expression"
             form))
        (cons (parse-formals (second parts)) (third parts))))

    (define (formals-names formals)
      "Return every symbol named by parsed FORMALS."
      #((parameters
         (formals
          (type formals)
          (description "Parsed formals metadata to enumerate.")))
        (returns
         (type (list-of symbol))
         (description
          ("A list of required parameter names plus the rest name when"
            "present.")))
        (effects state-read))
      (if (formals-rest formals)
          (append (formals-required formals) (list (formals-rest formals)))
          (formals-required formals)))

    (define (define-values-bound-names form)
      "Return every name bound by a define-values form."
      #((parameters
         (form . "A define-values form to inspect."))
        (returns
         (type (list-of symbol))
         (description "A list of every name the define-values form binds."))
        (effects error))
      (formals-names (car (parse-define-values form))))

    (define (record-definition-form? form)
      "Report whether FORM is a define-record-type form."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description
          ("True when FORM is a pair whose head names"
            "define-record-type.")))
        (effects pure))
      (and (pair? form) (identifier-named? (car form) 'define-record-type)))

    (define (body-definition-form? form)
      "Report whether FORM is any definition accepted at body start."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description
          ("True when FORM is a define, define-values, or record"
            "definition.")))
        (effects pure))
      (or (definition-form? form)
          (define-values-form? form)
          (record-definition-form? form)))

    (define (tagged-list? datum tag)
      "Report whether DATUM is a pair headed by identifier TAG."
      #((parameters
         (datum
          . "Candidate datum to classify.")
         (tag
          (type symbol)
          (description "Symbol the head identifier must name.")))
        (returns
         (type boolean)
         (description ("True when DATUM is a pair whose head identifier names TAG.")))
        (effects pure))
      (and (pair? datum)
           (identifier-named? (car datum) tag)))

    (define (single-argument-syntax form description)
      "Return the sole operand from FORM or raise a syntax error."
      #((parameters
         (form . "A one-operand syntactic form to validate.")
         (description
          (type string)
          (description "Form name used in any raised error message.")))
        (returns . "The single operand of FORM.")
        (effects error))
      (let ((parts (proper-list-elements form description)))
        (if (not (= (length parts) 2))
            (eval-error
             (string-append description " requires exactly one operand")
             form))
        (second parts)))

    (define (syntax-error-form? form)
      "Report whether FORM is a syntax-error expansion result."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description
          ("True when FORM is a list headed by the syntax-error"
            "identifier.")))
        (effects pure))
      (tagged-list? form 'syntax-error))

    (define (syntax-error-message form)
      "Render syntax-error operands into one diagnostic message."
      #((parameters
         (form
          . ("A syntax-error form whose operands form the message.")))
        (returns
         (type string)
         (description
          ("A space-joined string of the syntax-error operands"
            "rendered externally.")))
        (effects error))
      (let ((parts (proper-list-elements form "syntax-error form")))
        (let loop ((rest (cdr parts)) (message ""))
          (cond
           ((null? rest) message)
           ((string=? message "")
            (loop (cdr rest) (consent-value->external (car rest))))
           (else
            (loop (cdr rest)
                  (string-append
                   message
                   " "
                   (consent-value->external (car rest)))))))))

    (define (raise-syntax-error form . maybe-source-form)
      "Raise the diagnostic represented by a syntax-error form."
      #((parameters
         (form
          (type pair)
          (description ("A syntax-error form supplying the diagnostic message.")))
         (maybe-source-form
          (type list)
          (description "Optional source form named in the error.")))
        (returns . "Does not return; always raises an evaluation error.")
        (effects error))
      (let ((message (syntax-error-message form)))
        (if (null? maybe-source-form)
            (eval-error (string-append "syntax-error: " message))
            (eval-error
             (string-append
              "syntax-error while expanding "
              (consent-value->external (car maybe-source-form))
              ": "
              message)))))

    (define (make-empty-syntax-environment parent)
      "Construct an empty syntax environment with an optional parent."
      #((parameters
         (parent
          (type (or syntax-environment boolean))
          (description "Parent syntax environment, or #f for a root.")))
        (returns
         (type syntax-environment)
         (description
          ("A fresh syntax environment with an empty frame and no"
            "imports.")))
        (effects allocation))
      (make-syntax-environment '() parent '()))

    (define (syntax-environment-ref syntax-environment name)
      "Return NAME's syntax transformer by walking syntax-environment parents."
      #((parameters
         (syntax-environment
          (type syntax-environment)
          (description "Syntax environment to search."))
         (name
          (type symbol)
          (description "Keyword symbol whose transformer is sought.")))
        (returns
         (type (or syntax-transformer boolean))
         (description "NAME's syntax transformer, or #f when no parent binds it."))
        (effects state-read))
      (let loop ((cursor syntax-environment))
        (cond
         ((not cursor) #f)
         ((assq name (syntax-environment-frame cursor))
          => (lambda (cell) (cdr cell)))
         (else (loop (syntax-environment-parent cursor))))))

    (define (syntax-environment-define! syntax-environment name transformer)
      "Add a syntax binding unless NAME is imported into this syntax frame."
      #((parameters
         (syntax-environment
          (type syntax-environment)
          (description "Syntax environment to mutate."))
         (name
          (type symbol)
          (description "Keyword symbol to bind."))
         (transformer
          (type syntax-transformer)
          (description "Syntax transformer to associate with NAME.")))
        (returns . ("An unspecified value; the frame gains the new binding."))
        (effects state-write error))
      (if (memq name (syntax-environment-imported-names syntax-environment))
          (eval-error "cannot redefine imported syntax binding" name))
      (set-syntax-environment-frame!
       syntax-environment
       (cons (cons name transformer)
             (syntax-environment-frame syntax-environment))))

    (define (with-syntax-environment context syntax-environment thunk)
      "Run THUNK with CONTEXT temporarily using SYNTAX-ENVIRONMENT."
      #((parameters
         (context
          (type eval-context)
          (description ("Evaluation context whose syntax environment is swapped.")))
         (syntax-environment
          (type syntax-environment)
          (description "Syntax environment to install for the call."))
         (thunk
          (type procedure)
          (description "Zero-argument procedure to run under the swap.")))
        (returns
         . ("THUNK's result, after restoring the prior syntax"
            "environment."))
        (effects state-write))
      (let ((old-syntax-environment (context-syntax-environment context)))
        (set-context-syntax-environment! context syntax-environment)
        (let ((value (thunk)))
          (set-context-syntax-environment! context old-syntax-environment)
          value)))

    (define (operator-shadowed? operator environment)
      "Report whether OPERATOR is shadowed by a value binding."
      (and (symbol? operator) (environment-cell environment operator)))

    (define (special-operator-active? operator environment)
      "Report whether OPERATOR can still dispatch as syntax in ENVIRONMENT."
      #((parameters
         (operator
          . "Candidate operator identifier datum.")
         (environment
          (type environment)
          (description "Value environment that may shadow the operator.")))
        (returns
         (type boolean)
         (description
          ("True when OPERATOR is an identifier not shadowed by a"
            "value binding.")))
        (effects state-read))
      (and (identifier-datum? operator)
           (or (identifier? operator)
               (not (operator-shadowed? operator environment)))))

    (define (syntax-binding-for-operator operator environment context)
      "Resolve OPERATOR to its active syntax transformer, respecting hygiene."
      "Macro-introduced operators consult their definition-time syntax"
      "environment; plain symbols use the active syntax environment unless a"
      "value binding shadows the syntactic keyword."
      #((parameters
         (operator
          . "Operator identifier datum to resolve.")
         (environment
          (type environment)
          (description "Value environment that may shadow the keyword."))
         (context
          (type eval-context)
          (description
           ("Evaluation context supplying the active syntax"
             "environment."))))
        (returns
         (type (or syntax-transformer boolean))
         (description
          ("OPERATOR's active syntax transformer, or #f when none"
            "applies.")))
        (effects state-read))
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
      "Report whether DATUM names the active syntax-rules ellipsis identifier."
      (and (identifier-datum? datum)
           (eq? (identifier-datum-name datum) ellipsis)))

    (define (proper-list-elements/maybe datum)
      "Return DATUM's list elements, or #f when DATUM is not a proper list."
      #((parameters
         (datum
          (type list)
          (description "Candidate proper list to flatten.")))
        (returns
         (type (or list boolean))
         (description ("DATUM's elements as a list, or #f when DATUM is improper.")))
        (effects allocation))
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else #f))))

    (define (syntax-rules-spec? form)
      "Report whether FORM is a syntax-rules transformer spec."
      (and (pair? form) (identifier-named? (car form) 'syntax-rules)))

    (define (parse-syntax-rule rule)
      "Parse one syntax-rules rule into pattern and template."
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
      "Parse a syntax-rules transformer, including optional custom ellipsis."
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
      "Report whether IDENTIFIER names one of the syntax-rules literals."
      (let ((name (identifier-datum-name identifier)))
        (let loop ((rest literals))
          (cond
           ((null? rest) #f)
           ((eq? name (identifier-datum-name (car rest))) #t)
           (else (loop (cdr rest)))))))

    (define (make-pattern-bindings)
      "Create the mutable capture table used while matching one macro rule."
      (list 'bindings))

    (define (pattern-binding-cell bindings name)
      "Return the capture-table cell for pattern variable NAME, or #f."
      (assoc name (cdr bindings)))

    (define (pattern-binding bindings name)
      "Return the pattern binding entry for NAME, or #f."
      (let ((cell (pattern-binding-cell bindings name)))
        (if cell (cdr cell) #f)))

    (define (add-pattern-binding! bindings name entry)
      "Add ENTRY for pattern variable NAME to the capture table."
      (set-cdr! bindings (cons (cons name entry) (cdr bindings))))

    (define (path-prefix? prefix path)
      "Report whether PREFIX is an initial segment of repetition PATH."
      (cond
       ((null? prefix) #t)
       ((null? path) #f)
       ((= (car prefix) (car path))
        (path-prefix? (cdr prefix) (cdr path)))
       (else #f)))

    (define (capture-ref captures path)
      "Return the capture stored for PATH, or #f when none exists."
      (let ((cell (assoc path captures)))
        (if cell (cdr cell) #f)))

    (define (ensure-pattern-binding! bindings name depth)
      "Return NAME's capture entry, creating it with DEPTH when needed."
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
      "Record VALUE as NAME's capture at the current ellipsis PATH."
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

    (define (list-elements-tail datum)
      "Split DATUM into list elements and the final tail value."
      (let loop ((cursor datum) (elements '()))
        (if (pair? cursor)
            (loop (cdr cursor) (cons (car cursor) elements))
            (cons (reverse elements) cursor))))

    (define (append-tail elements tail)
      "Append ELEMENTS in front of TAIL without requiring TAIL to be a list."
      #((parameters
         (elements
          (type list)
          (description "Proper list of leading elements."))
         (tail . "Final tail value, which may be improper."))
        (returns . ("A structure consing ELEMENTS onto TAIL, possibly improper."))
        (effects allocation))
      (if (null? elements)
          tail
          (cons (car elements) (append-tail (cdr elements) tail))))

    (define (pattern-variable-names pattern literals ellipsis)
      "Return every pattern variable name introduced by PATTERN."
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
      "Mark repeated variables under PATTERN as captured zero times at PATH."
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
      "Return the first COUNT elements of LIST."
      (let loop ((rest list) (remaining count) (result '()))
        (if (= remaining 0)
            (reverse result)
            (loop (cdr rest) (- remaining 1) (cons (car rest) result)))))

    (define (list-drop list count)
      "Return LIST after skipping COUNT elements."
      (if (= count 0)
          list
          (list-drop (cdr list) (- count 1))))

    (define (list-last-n list count)
      "Return the last COUNT elements of LIST."
      (list-drop list (- (length list) count)))

    (define (identifier-syntax-binding-in identifier syntax-environment)
      "Resolve IDENTIFIER's syntax binding in a given syntax environment."
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
      "Return the value or syntax token used for literal-identifier comparison."
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
      "Report whether two literal-identifier binding tokens denote the same binding."
      (cond
       ((and (not left) (not right)) #t)
       ((and left right
             (eq? (car left) (car right))
             (eq? (cdr left) (cdr right)))
        #t)
       (else #f)))

    (define (literal-identifier-match? pattern input transformer
                                       use-environment use-syntax-environment)
      "Report whether a syntax-rules literal matches by name and binding."
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
      "Match one syntax-rules pattern node and record pattern captures."
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
          ;; A pair pattern can still match the empty list when it is wholly
          ;; collapsible through an ellipsis, e.g. ((name val) ...) against ()
          ;; as in (let () body ...).  match-pattern-elements rejects pairs that
          ;; genuinely require elements, so admitting null input here is safe.
          (and (or (pair? input) (null? input))
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
      "Return the index of the ellipsis marker in PATTERNS, or #f."
      (if (null? patterns)
          #f
          (let loop ((rest (cdr patterns)) (index 1))
            (cond
             ((null? rest) #f)
             ((ellipsis-identifier? (car rest) ellipsis) index)
             (else (loop (cdr rest) (+ index 1)))))))

    (define (match-pattern-list patterns inputs transformer bindings path
                                use-environment use-syntax-environment)
      "Match fixed pattern and input element lists from left to right."
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
      "Return PATH extended with one repetition INDEX."
      (append path (list index)))

    (define (match-pattern-elements patterns pattern-tail input-elements
                                    input-tail transformer bindings path
                                    use-environment use-syntax-environment)
      "Match list/vector pattern elements, including one ellipsis repetition."
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

    (define (match-syntax-rule rule form transformer bindings
                               use-environment use-syntax-environment)
      "Try one syntax-rules rule against FORM and fill BINDINGS on success."
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
      "Return captured pattern variables referenced by a template fragment."
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
      "Return the greatest number in a nonempty list."
      (let loop ((rest (cdr numbers)) (best (car numbers)))
        (if (null? rest)
            best
            (loop (cdr rest)
                  (if (> (car rest) best) (car rest) best)))))

    (define (collect-next-indices paths path)
      "Return distinct repetition indices immediately under PATH."
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
      "Return how many repetitions ENTRY has below PATH, if knowable."
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
      "Determine the repetition count required for a template ellipsis."
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
      "Return NAME's captured value at PATH, enforcing ellipsis depth."
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
      "Expand a syntax-rules template using captured pattern bindings."
      "Identifiers not captured by BINDINGS are wrapped with SYNTAX-CONTEXT so"
      "free template identifiers keep their definition-time bindings."
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
      "Allocate a fresh syntax context for identifiers introduced by a macro."
      "Each expansion gets a fresh context id so introduced bindings cannot"
      "collide accidentally with names from the macro use site."
      (let ((id (context-next-syntax-id context)))
        (set-context-next-syntax-id! context (+ id 1))
        (make-syntax-context id value-environment syntax-environment)))

    (define (apply-syntax-transformer transformer form environment context)
      "Apply TRANSFORMER to FORM by matching rules and expanding the template."
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
      "Report whether FORM is a define-syntax form."
      #((parameters
         (form . "Candidate form to classify."))
        (returns
         (type boolean)
         (description ("True when FORM is a pair whose head names define-syntax.")))
        (effects pure))
      (and (pair? form) (identifier-named? (car form) 'define-syntax)))

    (define (eval-define-syntax form environment context syntax-environment)
      "Evaluate a define-syntax form and install its transformer."
      #((parameters
         (form
          (type pair)
          (description "A define-syntax form to evaluate."))
         (environment
          (type environment)
          (description "Value environment captured by the transformer."))
         (context . "Evaluation context (unused beyond parsing).")
         (syntax-environment
          (type syntax-environment)
          (description "Syntax environment that receives the binding.")))
        (returns
         . ("The unspecified value after installing the keyword's"
            "transformer."))
        (effects state-write error))
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
          consent-unspecified)))

    (define (parse-let-syntax-binding binding)
      "Parse one let-syntax binding into keyword and transformer spec."
      (let ((parts (proper-list-elements binding "syntax binding")))
        (if (not (= (length parts) 2))
            (eval-error
             "syntax binding must contain a keyword and transformer spec"
             binding))
        (cons (expect-symbol (car parts) "syntax binding keyword")
              (second parts))))

    (define (make-local-syntax-scope parts environment context recursive?)
      "Build the syntax scope created by let-syntax or letrec-syntax."
      #((parameters
         (parts
          (type list)
          (description "Operator and operands of the let-syntax form."))
         (environment
          (type environment)
          (description "Value environment captured by the transformers."))
         (context
          (type eval-context)
          (description ("Evaluation context supplying the outer syntax environment.")))
         (recursive?
          (type boolean)
          (description "True for letrec-syntax so bindings see each other.")))
        (returns
         (type syntax-scope)
         (description
          ("A syntax scope pairing the body forms with the local"
            "syntax environment.")))
        (effects allocation error))
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

    (define (expand-expression expression environment context)
      "Expand one expression enough to expose core forms or syntax scopes."
      #((parameters
         (expression . "Expression to expand one syntactic layer.")
         (environment
          (type environment)
          (description "Value environment used for shadowing checks."))
         (context
          (type environment)
          (description ("Evaluation context supplying the syntax environment."))))
        (returns
         . ("The single-step expansion: a syntax scope, a transformed"
            "form, or EXPRESSION unchanged."))
        (effects state-read error))
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

    (define (expand-definition-form form environment context)
      "Fully expand a define form while preserving its definition shape."
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

    (define (expand-define-values-form form environment context)
      "Fully expand the initializer in a define-values form."
      (let ((parts (proper-list-elements form "define-values form")))
        (if (not (= (length parts) 3))
            (eval-error
             "define-values requires formals and one expression"
             form))
        (list (car parts)
              (second parts)
              (expand-expression/fully (third parts) environment context))))

    (define (expand-core-combination expression environment context)
      "Fully expand core special forms and ordinary combinations."
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

    (define (expand-expression/fully expression environment context)
      "Recursively expand EXPRESSION until no macro expansion remains."
      #((parameters
         (expression . "Expression to expand to a fixed point.")
         (environment
          (type environment)
          (description "Value environment used for shadowing checks."))
         (context
          (type eval-context)
          (description "Evaluation context tracking expansion step budget.")))
        (returns
         . ("The fully expanded expression with all macros and core"
            "forms resolved."))
        (effects state-write error))
      (note-step! context)
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
      "Fully expand a sequence, executing allowed definition-time forms."
      #((parameters
         (forms
          (type list)
          (description "Sequence of forms to expand in order."))
         (environment
          (type environment)
          (description "Value environment used during expansion."))
         (context
          (type eval-context)
          (description ("Evaluation context whose syntax environment is mutated.")))
         (allow-definitions?
          (type boolean)
          (description
           ("True to run import, library, and syntax definitions in"
             "place."))))
        (returns
         (type list)
         (description "A list of the expanded forms in source order."))
        (effects state-write error))
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


    (define (macro-rest-environment rest)
      "Return the optional caller environment or a fresh base environment."
      (if (or (null? rest) (not (car rest)))
          (consent-make-base-environment)
          (car rest)))

    (define (macro-rest-options rest)
      "Return the optional caller options alist, defaulting to empty."
      (if (or (null? rest) (null? (cdr rest)))
          '()
          (second rest)))

    (define (consent-expand expression . rest)
      "Fully expand one already-read expression without evaluating its result."
      #((parameters
         (expression . "Already-read expression to expand.")
         (rest
          (type list)
          (description "Optional caller environment then options alist.")))
        (returns . "The fully expanded expression.")
        (effects state-write error))
      (let ((context (new-eval-context (macro-rest-options rest)))
            (environment (macro-rest-environment rest)))
        (ensure-base-syntax! context environment)
        (expand-expression/fully expression environment context)))

    (define (consent-expand-source source . rest)
      "Read and expand a source body, preserving top-level definition structure"
      "for tests and future compiler/backend passes."
      #((parameters
         (source
          (type string)
          (description "Source text to read into a form sequence."))
         (rest
          (type list)
          (description "Optional caller environment then options alist.")))
        (returns
         (type list)
         (description "A list of expanded top-level forms in source order."))
        (effects state-write error))
      (let ((context (new-eval-context (macro-rest-options rest)))
            (environment (macro-rest-environment rest))
            (forms (consent-read-all source (macro-rest-options rest))))
        (ensure-base-syntax! context environment)
        (expand-sequence-forms forms environment context #t)))

    (define (macro-field name . values)
      "Build one field for Scheme-readable macro introspection records."
      (cons name values))

    (define (macro-active-name form environment context)
      "Return the active macro operator name for FORM, or #f."
      (and (pair? form)
           (let ((operator (car form)))
             (cond
              ((and (identifier-named? operator 'let-syntax)
                    (special-operator-active? operator environment))
               'let-syntax)
              ((and (identifier-named? operator 'letrec-syntax)
                    (special-operator-active? operator environment))
               'letrec-syntax)
              ((syntax-binding-for-operator operator environment context)
               (identifier-datum-name operator))
              (else #f)))))

    (define (macro-step-record index macro-name input output)
      "Return one Scheme-readable top-level macro expansion step."
      (list 'step
            (macro-field 'index (consent-make-canonical-integer index))
            (macro-field 'macro macro-name)
            (macro-field 'input (strip-identifiers input))
            (macro-field 'output (strip-identifiers output))
            (macro-field 'source (consent-datum-source input))))

    (define (macro-option-name datum)
      "Return NAME as a supported macro expansion option name."
      (let ((name (identifier-datum-name datum)))
        (cond
         ((not name)
          (eval-error "macroexpand option name must be an identifier" datum))
         ((or (eq? name 'max-steps)
              (eq? name 'max-non-tail-steps)
              (eq? name 'max-value-nodes)
              (eq? name 'max-events)
              (eq? name 'max-event-nodes))
          name)
         (else
          (eval-error "unknown macroexpand option" name)))))

    (define (macro-option-integer value name)
      "Return VALUE as a host exact integer for macro option NAME."
      (cond
       ((and (consent-number? value)
             (eq? (consent-number-kind value) 'integer)
             (eq? (consent-number-exactness value) 'exact))
        (consent-number-value value))
       ((and (integer? value) (exact? value))
        value)
       (else
        (eval-error "macroexpand option expects exact integer" name))))

    (define (macro-option-entry entry)
      "Convert one Scheme-readable option entry to the host context alist shape."
      (let ((parts (proper-list-elements/maybe entry)))
        (cond
         ((and parts (= (length parts) 2))
          (let ((name (macro-option-name (car parts))))
            (cons name (macro-option-integer (cadr parts) name))))
         ((pair? entry)
          (let ((name (macro-option-name (car entry))))
            (cons name (macro-option-integer (cdr entry) name))))
         (else
          (eval-error "macroexpand option must be a pair" entry)))))

    (define (macro-options-alist options)
      "Convert Scheme-readable macroexpand OPTIONS to evaluator context options."
      (map macro-option-entry
           (proper-list-elements
            (if options options '())
            "macroexpand options")))

    (define (macro-introspection-context context options)
      "Return a child expansion context sharing the caller's macro state."
      (let ((child (new-eval-context (macro-options-alist options))))
        (set-context-syntax-environment!
         child
         (context-syntax-environment context))
        (set-context-libraries! child (context-libraries context))
        (set-context-interaction-environment!
         child
         (context-interaction-environment context))
        (set-context-base-syntax-installed!
         child
         (context-base-syntax-installed context))
        child))

    (define (macro-visible-expanded expanded)
      "Return EXPANDED in the readable shape used by expansion records."
      (if (syntax-scope? expanded)
          (cons 'begin (syntax-scope-forms expanded))
          expanded))

    (define (macro-expand-target/fully target environment context)
      "Fully expand TARGET, preserving local syntax scope when present."
      (if (syntax-scope? target)
          (with-syntax-environment
           context
           (syntax-scope-syntax-environment target)
           (lambda ()
             (cons 'begin
                   (expand-sequence-forms
                    (syntax-scope-forms target)
                    environment
                    context
                    #t))))
          (expand-expression/fully target environment context)))

    (define (macro-trace-top-level form environment context one-step?)
      "Return a top-level expansion trace for FORM."
      (let loop ((current form)
                 (index 0)
                 (steps '())
                 (macros '()))
        (note-step! context)
        (let* ((macro-name (macro-active-name current environment context))
               (expanded (expand-expression current environment context))
               (visible-expanded (macro-visible-expanded expanded)))
          (consent-copy-datum-source! visible-expanded current)
          (if (not (eq? expanded current))
              (let ((name (or macro-name 'syntax))
                    (step-index (+ index 1)))
                (if (or one-step? (syntax-scope? expanded))
                    (list (cons 'expanded visible-expanded)
                          (cons 'target expanded)
                          (cons 'steps
                                (reverse
                                 (cons
                                  (macro-step-record
                                   step-index name current visible-expanded)
                                  steps)))
                          (cons 'macros (reverse (cons name macros))))
                    (loop expanded
                          step-index
                          (cons
                           (macro-step-record
                            step-index name current visible-expanded)
                           steps)
                          (if (memq name macros)
                              macros
                              (cons name macros)))))
              (list (cons 'expanded current)
                    (cons 'target current)
                    (cons 'steps (reverse steps))
                    (cons 'macros (reverse macros)))))))

    (define (macro-trace-ref trace field)
      "Return FIELD from a trace alist."
      (cdr (assq field trace)))

    (define (macro-condition-datum condition context)
      "Convert a raised condition into a macro-expansion condition datum."
      (map (lambda (field)
             (if (and (pair? field) (eq? (car field) 'phase))
                 (macro-field 'phase 'macro-expansion)
                 field))
           (debugger-condition-datum condition context)))

    (define (macro-expansion-result status mode original expanded
                                    steps macros errors)
      "Build a Scheme-readable macro expansion result datum."
      (list 'macro-expansion
            (macro-field 'status status)
            (macro-field 'mode mode)
            (macro-field 'original (strip-identifiers original))
            (macro-field 'expanded
                         (if expanded (strip-identifiers expanded) #f))
            (macro-field 'steps steps)
            (macro-field 'macros macros)
            (macro-field 'source (consent-datum-source original))
            (macro-field 'warnings '())
            (macro-field 'errors errors)))

    (define (macroexpand/result form environment context options mode)
      "Return macro expansion introspection for FORM."
      (let* ((child (macro-introspection-context context options))
             (trace #f))
        (guard (condition
                (else
                 (macro-expansion-result
                  'error
                  mode
                  form
                  #f
                  (if trace (macro-trace-ref trace 'steps) '())
                  (if trace (macro-trace-ref trace 'macros) '())
                  (list (macro-condition-datum condition child)))))
          (ensure-base-syntax! child environment)
          (set! trace
                (macro-trace-top-level
                 form environment child (eq? mode 'one-step)))
          (let ((expanded
                 (if (eq? mode 'one-step)
                     (macro-trace-ref trace 'expanded)
                     (macro-expand-target/fully
                      (macro-trace-ref trace 'target)
                      environment
                      child))))
            (macro-expansion-result
             'ok
             mode
             form
             expanded
             (macro-trace-ref trace 'steps)
             (macro-trace-ref trace 'macros)
             '())))))

    (define (consent-macroexpand form environment context options)
      "Return a full macro expansion introspection datum for FORM."
      #((parameters
         (form . "Form to fully macroexpand.")
         (environment
          (type environment)
          (description "Value environment used during expansion."))
         (context
          (type eval-context)
          (description "Parent context whose macro state is shared."))
         (options
          (type list)
          (description "Scheme-readable expansion option list.")))
        (returns
         (type macro-expansion)
         (description
          ("A Scheme-readable macro-expansion datum for the full"
            "expansion.")))
        (effects state-write error))
      (macroexpand/result form environment context options 'full))

    (define (consent-macroexpand-1 form environment context options)
      "Return a one-step macro expansion introspection datum for FORM."
      #((parameters
         (form . "Form to macroexpand by a single step.")
         (environment
          (type environment)
          (description "Value environment used during expansion."))
         (context
          (type eval-context)
          (description "Parent context whose macro state is shared."))
         (options
          (type list)
          (description "Scheme-readable expansion option list.")))
        (returns
         (type macro-expansion)
         (description
          ("A Scheme-readable macro-expansion datum for the one-step"
            "expansion.")))
        (effects state-write error))
      (macroexpand/result form environment context options 'one-step))

    (define (consent-macro-binding-info identifier environment context)
      "Return syntax binding metadata for IDENTIFIER in CONTEXT."
      #((parameters
         (identifier
          (type symbol)
          (description "Identifier whose syntax binding is queried."))
         (environment
          (type environment)
          (description "Value environment (unused by this lookup)."))
         (context
          (type eval-context)
          (description ("Evaluation context supplying the syntax environment."))))
        (returns
         (type (or macro-binding boolean))
         (description
          ("A Scheme-readable macro-binding record, or #f when"
            "IDENTIFIER is unbound as syntax.")))
        (effects state-read error))
      (let ((name (expect-symbol identifier "macro-binding-info identifier")))
        (if (syntax-environment-ref (context-syntax-environment context) name)
            (list 'macro-binding
                  (macro-field 'identifier name)
                  (macro-field 'status 'bound)
                  (macro-field 'kind 'syntax-rules)
                  (macro-field 'library #f))
            #f)))

    (define (consent-syntax-source datum)
      "Return source metadata for DATUM, or #f when none is attached."
      #((parameters
         (datum . "Datum whose attached source metadata is read."))
        (returns
         . ("The source metadata attached to DATUM, or #f when none"
            "exists."))
        (effects state-read))
      (consent-datum-source datum))

    (define (macro-library-record status library-name macros errors)
      "Build a Scheme-readable macro library introspection record."
      (list 'macro-library
            (macro-field 'status status)
            (macro-field 'library (strip-identifiers library-name))
            (macro-field 'macros macros)
            (macro-field 'warnings '())
            (macro-field 'errors errors)))

    (define (insert-macro-record record records)
      "Insert RECORD into sorted macro RECORDS by exported name."
      (cond
       ((null? records) (list record))
       ((string<? (symbol->string (second record))
                  (symbol->string (second (car records))))
        (cons record records))
       (else
        (cons (car records) (insert-macro-record record (cdr records))))))

    (define (consent-macroexpand-library library-name environment
                                              context options)
      "Return syntax export metadata for LIBRARY-NAME."
      #((parameters
         (library-name
          (type list)
          (description "Library name to resolve and inspect."))
         (environment
          (type environment)
          (description "Value environment used to resolve the library."))
         (context
          (type eval-context)
          (description "Parent context whose macro state is shared."))
         (options
          (type list)
          (description "Scheme-readable expansion option list.")))
        (returns
         (type macro-library)
         (description
          ("A Scheme-readable macro-library record of the library's"
            "syntax exports.")))
        (effects state-write error))
      (let ((child (macro-introspection-context context options)))
        (guard (condition
                (else
                 (macro-library-record
                  'error
                  library-name
                  '()
                  (list (macro-condition-datum condition child)))))
          (ensure-base-syntax! child environment)
          (let* ((library (resolve-library library-name child environment))
                 (macros
                  (let loop ((exports (library-exports library))
                             (records '()))
                    (cond
                     ((null? exports) records)
                     ((eq? (library-binding-kind (car exports)) 'syntax)
                      (loop
                       (cdr exports)
                       (insert-macro-record
                        (list 'macro
                              (library-binding-name (car exports))
                              (macro-field 'kind 'syntax-rules))
                        records)))
                     (else (loop (cdr exports) records))))))
            (macro-library-record 'ok library-name macros '())))))

    ))
