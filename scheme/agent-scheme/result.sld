;;; Portable Agent Scheme result rendering boundary.
;;;
;;; This library owns conversion from runtime values and evaluation outcomes to
;;; stable external datums and strings.

(define-library (agent-scheme result)
  (export result-field
          value->result-datum
          strip-identifiers
          budget-result-field
          ok-result-datum
          debugger-condition-datum
          debugger-exception-datum
          debugger-field-values
          debugger-field-value
          debugger-expect-condition
          debugger-restart-id-name
          debugger-default-restarts
          condition-result-datum
          agent-scheme-result->external
          agent-scheme-value->external)
  (import (scheme base)
          (agent-scheme reader)
          (except (agent-scheme runtime) make-parameter))
  (begin
    (define (result-field name . values)
      "Construct a named field for public result datums."
      #((parameters . ((name . "Symbol naming the result field.")
                       (values . "Zero or more Scheme-readable field values.")))
        (returns . "A field pair whose car is NAME and whose cdr is VALUES.")
        (effects . (pure)))
      (cons name values))

    (define (value->result-datum value . maybe-seen)
      "Return VALUE converted to a public result datum."
      #((parameters . ((value . "Runtime value to render as stable Scheme-readable data.")
                       (maybe-seen . "Internal cycle-detection list used while rendering compound values.")))
        (returns . "A public datum representation of VALUE suitable for evaluation-result records.")
        (effects . (pure)))
      (let ((seen (if (null? maybe-seen) '() (car maybe-seen))))
        (cond
         ((or (boolean? value)
              (null? value)
              (symbol? value)
              (char? value)
              (agent-scheme-number? value)
              (string? value)
              (bytevector? value))
          value)
         ((identifier? value)
          (identifier-name value))
         ((agent-scheme-unspecified? value)
          '(unspecified))
         ((agent-scheme-eof-object? value)
          '(eof-object))
         ((agent-scheme-port? value)
          (list 'port
                (result-field 'medium (agent-scheme-port-medium value))
                (result-field
                 'open
                 (if (agent-scheme-port-open? value) #t #f))))
         ((environment-specifier? value)
          '(environment))
         ((agent-scheme-primitive-procedure? value)
          (list 'procedure
                (result-field 'kind 'primitive)
                (result-field 'name (primitive-procedure-name value))))
         ((agent-scheme-parameter? value)
          (list 'procedure (result-field 'kind 'parameter)))
         ((agent-scheme-procedure? value)
          (list 'procedure (result-field 'kind 'compound)))
         ((continuation? value)
          (list 'procedure (result-field 'kind 'continuation)))
         ((agent-scheme-error-object? value)
          (list 'error-object
                (result-field 'message
                              (agent-scheme-error-object-message value))
                (result-field
                 'irritants
                 (map (lambda (irritant)
                        (value->result-datum irritant seen))
                      (agent-scheme-error-object-irritants value)))))
         ((agent-scheme-record-type? value)
          (list 'record-type
                (result-field 'name
                              (agent-scheme-record-type-name value))))
         ((agent-scheme-record? value)
          (list 'record
                (result-field
                 'type
                 (agent-scheme-record-type-name
                  (agent-scheme-record-type value)))))
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
      "Remove hygienic identifier wrappers from VALUE for readable output."
      #((parameters . ((value . "Runtime value to simplify for display.")
                       (maybe-seen . "Internal cycle-detection list used while walking compound values.")))
        (returns . "VALUE with identifiers replaced by their names inside lists and vectors.")
        (effects . (pure)))
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
         ((agent-scheme-record? value)
          value)
         ((agent-scheme-record-type? value)
          value)
         (else value))))

    (define (budget-result-field context)
      "Build the budget field for a public evaluation-result datum."
      #((parameters . ((context . "Evaluation context containing budget counters.")))
        (returns . "A `budget` result field with steps-used and host-calls counters.")
        (effects . (state-read)))
      (result-field
       'budget
       (result-field
        'steps-used
        (agent-scheme-make-canonical-integer (context-steps context)))
       (result-field
        'host-calls
        (agent-scheme-make-canonical-integer
         (context-host-callbacks context)))))

    (define (context-events context)
      "Return policy and agent-channel events in the order they were recorded."
      (reverse (context-audit-events context)))

    ;; Maximum current-frame binding names included in debugger conditions.
    (define debugger-maximum-frame-bindings 40)

    (define (string-prefix? prefix text)
      "Report whether TEXT begins with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref text index))
                        (loop (+ index 1))))))))

    (define (string-contains? text needle)
      "Report whether TEXT contains NEEDLE."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    (define (condition-message condition)
      "Return CONDITION's printable message."
      (cond
       ((error-object? condition)
        (error-object-message condition))
       ((agent-scheme-error-object? condition)
        (agent-scheme-error-object-message condition))
       ((string? condition)
        condition)
       (else
        "error")))

    (define (condition-irritants condition)
      "Return CONDITION's portable irritants when they are available."
      (cond
       ((error-object? condition)
        (error-object-irritants condition))
       ((agent-scheme-error-object? condition)
        (agent-scheme-error-object-irritants condition))
       (else '())))

    (define (debugger-condition-type condition message)
      "Return a debugger condition type derived from CONDITION and MESSAGE."
      (cond
       ((string-contains? message "budget")
        'budget-exhausted)
       ((string-contains? message "policy")
        'policy-denial)
       ((string-contains? message "unbound identifier")
        'unbound-variable)
       ((or (string-contains? message "arity")
            (string-contains? message "arguments"))
        'arity-error)
       ((string-contains? message "syntax-error while expanding")
        'macro-expansion)
       ((or (string-contains? message "expected")
            (string-contains? message "must be"))
        'type-error)
       (else
        'evaluation-error)))

    (define (debugger-condition-symbol condition)
      "Return the first symbol irritant for CONDITION, if any."
      (let loop ((irritants (condition-irritants condition)))
        (cond
         ((null? irritants) #f)
         ((symbol? (car irritants)) (car irritants))
         (else (loop (cdr irritants))))))

    (define (take items count)
      "Return the first COUNT items from ITEMS."
      (if (or (= count 0) (null? items))
          '()
          (cons (car items) (take (cdr items) (- count 1)))))

    (define (debugger-documentation-field fields name)
      "Return documentation metadata field NAME from FIELDS, or #f."
      (assq name fields))

    (define (debugger-documentation-origin documentation)
      "Return debugger documentation origin data."
      (let ((origins (documentation-metadata-origins documentation)))
        (cond
         ((null? origins) '(signature))
         ((equal? origins '(implementation-procedure-string))
          '(implementation-procedure string))
         ((equal? origins '(primitive-manifest-string))
          '(primitive-manifest string))
         (else (cons 'body-literal origins)))))

    (define (debugger-documentation-fields documentation)
      "Return Scheme-readable documentation fields for DOCUMENTATION."
      (map (lambda (field)
             (list (car field) (value->result-datum (cdr field))))
           (documentation-metadata-fields documentation)))

    (define (debugger-documentation-metadata documentation)
      "Return procedure-value documentation metadata for debugger output."
      (list 'documentation-metadata
            (result-field 'subject '(procedure))
            (result-field 'kind 'procedure)
            (result-field 'library #f)
            (result-field 'source #f)
            (result-field 'origin
                          (debugger-documentation-origin documentation))
            (result-field 'fields
                          (debugger-documentation-fields documentation))))

    (define (debugger-procedure-documentation value)
      "Return debugger documentation for compound procedure VALUE, or #f."
      (and (agent-scheme-procedure? value)
           (let ((documentation (procedure-documentation value)))
             (and documentation
                  (debugger-documentation-field
                   (documentation-metadata-fields documentation)
                   'documentation)
                  (debugger-documentation-metadata documentation)))))

    (define (debugger-binding-record entry)
      "Return a safe binding record for frame ENTRY."
      (let* ((name (car entry))
             (cell (cdr entry))
             (value (cell-value cell))
             (documentation (debugger-procedure-documentation value)))
        (append
         (list 'binding
               (result-field 'name
                             (if (symbol? name) name 'unknown-binding)))
         (if documentation
             (list (result-field 'procedure-documentation documentation))
             '()))))

    (define (debugger-binding-documented? binding)
      "Return #t when BINDING carries debugger procedure documentation."
      (if (debugger-field-value binding 'procedure-documentation) #t #f))

    (define (debugger-select-frame-bindings bindings)
      "Return BINDINGS with documented procedures preserved before truncation."
      (let loop ((rest bindings) (documented '()) (plain '()))
        (cond
         ((null? rest)
          (let* ((documented-bindings (reverse documented))
                 (plain-bindings (reverse plain))
                 (plain-limit
                  (- debugger-maximum-frame-bindings
                     (length documented-bindings))))
            (append documented-bindings
                    (take plain-bindings
                          (if (< plain-limit 0) 0 plain-limit)))))
         ((debugger-binding-documented? (car rest))
          (loop (cdr rest) (cons (car rest) documented) plain))
         (else
          (loop (cdr rest) documented (cons (car rest) plain))))))

    (define (debugger-frame-bindings environment)
      "Return binding-name records for ENVIRONMENT's current frame."
      (if environment
          (debugger-select-frame-bindings
           (map debugger-binding-record (environment-frame environment)))
          '()))

    (define (debugger-environment-frame environment frame-id)
      "Return a debugger environment frame for ENVIRONMENT and FRAME-ID."
      (let ((binding-count
             (if environment (length (environment-frame environment)) 0)))
        (list
         (result-field 'frame frame-id)
         (result-field 'bindings (debugger-frame-bindings environment))
         (result-field
          'truncated
          (if (> binding-count debugger-maximum-frame-bindings) #t #f)))))

    (define (debugger-stack-frame phase frame-id)
      "Return a debugger stack frame."
      (list 'frame
            (result-field 'id frame-id)
            (result-field 'phase phase)))

    (define (debugger-restart-record id category policy)
      "Return a debugger restart record."
      (list 'restart
            (result-field 'id id)
            (result-field 'category category)
            (result-field 'policy policy)
            (result-field 'status 'available)))

    (define (debugger-default-restarts)
      "Return debugger restarts that are always safe to advertise."
      #((parameters . ())
        (returns . "List of debugger restart datums available for ordinary evaluation failures.")
        (effects . (pure)))
      (list
       (debugger-restart-record 'abort 'abort 'pure-r7rs)
       (debugger-restart-record 'retry 'retry 'debugger-recovery)
       (debugger-restart-record
        'provide-value 'provide-value 'debugger-recovery)
       (debugger-restart-record
        'define-binding 'define-binding 'debugger-recovery)
       (debugger-restart-record
        'import-library 'import-library 'debugger-recovery)
       (debugger-restart-record
        'continue-with-warning 'continue-with-warning 'pure-r7rs)
       (debugger-restart-record
        'request-user-input 'request-user-input 'approval-resolution)))

    (define (debugger-field-values datum field)
      "Return values for FIELD from a debugger datum."
      #((parameters . ((datum . "Debugger datum represented as a tagged list.")
                       (field . "Symbol naming the field to read.")))
        (returns . "The field values for FIELD, or the empty list.")
        (effects . (pure)))
      (let ((entry (and (pair? datum) (assq field (cdr datum)))))
        (if entry (cdr entry) '())))

    (define (debugger-field-value datum field)
      "Return the first value for FIELD from a debugger datum."
      #((parameters . ((datum . "Debugger datum represented as a tagged list.")
                       (field . "Symbol naming the field to read.")))
        (returns . "The first field value for FIELD, or #f.")
        (effects . (pure)))
      (let ((values (debugger-field-values datum field)))
        (if (null? values) #f (car values))))

    (define (debugger-expect-condition datum operation)
      "Return DATUM or raise when OPERATION expected a debugger condition."
      #((parameters . ((datum . "Value expected to be a debugger condition datum.")
                       (operation . "Operation name used in the error message.")))
        (returns . "DATUM when it is tagged as a debugger condition.")
        (effects . (error)))
      (if (not (and (pair? datum) (eq? (car datum) 'condition)))
          (eval-error
           (string-append operation " expected a debugger condition")))
      datum)

    (define (debugger-restart-id-name id)
      "Return ID as a debugger restart symbol."
      #((parameters . ((id . "Restart id as a symbol or string.")))
        (returns . "ID as a symbol.")
        (effects . (error)))
      (cond
       ((symbol? id) id)
       ((string? id) (string->symbol id))
       (else (eval-error "restart id must be a symbol or string"))))

    (define (debugger-condition-datum condition context)
      "Build a Scheme-readable debugger condition datum."
      #((parameters . ((condition . "Host or Agent Scheme condition value.")
                       (context . "Evaluation context used for current frame and restart metadata.")))
        (returns . "A `condition` datum for debugger and result consumers.")
        (effects . (state-read)))
      (let* ((message (condition-message condition))
             (type (debugger-condition-type condition message))
             (frame-id 'f-0)
             (phase 'evaluation)
             (environment-frame
              (debugger-environment-frame
               (context-interaction-environment context)
               frame-id))
             (symbol (debugger-condition-symbol condition)))
        (append
         (list 'condition
               (result-field 'type type)
               (result-field 'message message)
               (result-field 'phase phase))
         (if symbol (list (result-field 'symbol symbol)) '())
         (list
          (result-field
           'stack
           (list (debugger-stack-frame phase frame-id)))
          (result-field 'environment environment-frame)
          (result-field 'restarts (debugger-default-restarts))))))

    (define (debugger-exception-datum exception context)
      "Build a debugger condition for a Scheme-raised EXCEPTION value."
      #((parameters . ((exception . "Scheme value raised as an exception.")
                       (context . "Evaluation context used for debugger metadata.")))
        (returns . "A debugger condition datum that preserves EXCEPTION as a public result value.")
        (effects . (state-read)))
      (append
       (debugger-condition-datum
        (make-agent-scheme-error-object
         "raised exception"
         (list exception))
        context)
       (list (result-field 'value (value->result-datum exception)))))

    (define (ok-result-datum value context)
      "Build a successful evaluation-result datum for VALUE."
      #((parameters . ((value . "Runtime value returned by evaluation.")
                       (context . "Evaluation context containing events and budget counters.")))
        (returns . "An `evaluation-result` datum with status ok or values.")
        (effects . (state-read)))
      (if (multiple-values? value)
          (list 'evaluation-result
                (result-field 'status 'values)
                (result-field
                 'values
                 (map value->result-datum
                      (multiple-values-values value)))
                (result-field 'events (context-events context))
                (budget-result-field context))
          (list 'evaluation-result
                (result-field 'status 'ok)
                (result-field 'value (value->result-datum value))
                (result-field 'events (context-events context))
                (budget-result-field context))))

    (define (condition-result-datum condition context)
      "Build an error evaluation-result datum for CONDITION."
      #((parameters . ((condition . "Host or Agent Scheme condition value.")
                       (context . "Evaluation context to update with the current debugger error.")))
        (returns . "An `evaluation-result` datum with status error.")
        (effects . (state-write)))
      (let ((debugger-condition
             (debugger-condition-datum condition context)))
        (set-context-current-error! context debugger-condition)
        (list 'evaluation-result
              (result-field 'status 'error)
              (result-field
               'error
               (result-field 'condition debugger-condition)
               (result-field 'host-condition 'error)
               (result-field 'message (condition-message condition)))
              (result-field 'events (context-events context))
              (budget-result-field context))))

    (define (agent-scheme-result->external result)
      "Render an evaluation-result datum using the reader/writer external form."
      #((parameters . ((result . "Public evaluation-result datum.")))
        (returns . "External written text for RESULT.")
        (effects . (pure)))
      (agent-scheme-datum->external result))

    (define (agent-scheme-value->external value)
      "Render runtime VALUE for diagnostics using stable external text."
      #((parameters . ((value . "Runtime value to render.")))
        (returns . "Stable external text suitable for tests, diagnostics, and logs.")
        (effects . (pure)))
      (cond
       ((agent-scheme-unspecified? value)
        "#<unspecified>")
       ((agent-scheme-eof-object? value)
        "#<eof>")
       ((agent-scheme-port? value)
        (string-append
         "#<"
         (symbol->string (agent-scheme-port-medium value))
         "-port"
         (if (agent-scheme-port-open? value) "" " closed")
         ">"))
       ((environment-specifier? value)
        "#<environment>")
       ((agent-scheme-parameter? value)
        "#<procedure>")
       ((agent-scheme-procedure? value)
        "#<procedure>")
       ((agent-scheme-primitive-procedure? value)
        (string-append
         "#<primitive "
         (symbol->string (primitive-procedure-name value))
         ">"))
       ((continuation? value)
        "#<continuation>")
       ((agent-scheme-error-object? value)
        (string-append
         "#<error-object "
         (agent-scheme-error-object-message value)
         ">"))
       ((multiple-values? value)
        (agent-scheme-datum->external
         (cons 'values
               (map strip-identifiers (multiple-values-values value)))))
       (else
        (agent-scheme-datum->external (strip-identifiers value)))))))
