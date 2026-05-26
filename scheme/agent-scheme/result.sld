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
          (agent-scheme runtime))
  (begin
    ;; Construct a named field for public result datums.
    (define (result-field name . values)
      (cons name values))

    ;; Result datums are the public reporting surface: they preserve useful
    ;; Scheme data while reducing procedures, ports, and host objects to handles.
    (define (value->result-datum value . maybe-seen)
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

    ;; Remove hygienic identifier wrappers from VALUE for readable output.
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
         ((agent-scheme-record? value)
          value)
         ((agent-scheme-record-type? value)
          value)
         (else value))))

    ;; Build the budget field for a public evaluation-result datum.
    (define (budget-result-field context)
      (result-field
       'budget
       (result-field
        'steps-used
        (agent-scheme-make-canonical-integer (context-steps context)))
       (result-field
        'host-calls
        (agent-scheme-make-canonical-integer
         (context-host-callbacks context)))))

    ;; Return policy and agent-channel events in the order they were recorded.
    (define (context-events context)
      (reverse (context-audit-events context)))

    ;; Maximum current-frame binding names included in debugger conditions.
    (define debugger-maximum-frame-bindings 40)

    ;; Report whether TEXT begins with PREFIX.
    (define (string-prefix? prefix text)
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref text index))
                        (loop (+ index 1))))))))

    ;; Report whether TEXT contains NEEDLE.
    (define (string-contains? text needle)
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    ;; Return CONDITION's printable message.
    (define (condition-message condition)
      (cond
       ((error-object? condition)
        (error-object-message condition))
       ((agent-scheme-error-object? condition)
        (agent-scheme-error-object-message condition))
       ((string? condition)
        condition)
       (else
        "error")))

    ;; Return CONDITION's portable irritants when they are available.
    (define (condition-irritants condition)
      (cond
       ((error-object? condition)
        (error-object-irritants condition))
       ((agent-scheme-error-object? condition)
        (agent-scheme-error-object-irritants condition))
       (else '())))

    ;; Return a debugger condition type derived from CONDITION and MESSAGE.
    (define (debugger-condition-type condition message)
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

    ;; Return the first symbol irritant for CONDITION, if any.
    (define (debugger-condition-symbol condition)
      (let loop ((irritants (condition-irritants condition)))
        (cond
         ((null? irritants) #f)
         ((symbol? (car irritants)) (car irritants))
         (else (loop (cdr irritants))))))

    ;; Return the first COUNT items from ITEMS.
    (define (take items count)
      (if (or (= count 0) (null? items))
          '()
          (cons (car items) (take (cdr items) (- count 1)))))

    ;; Return a safe binding record for NAME.
    (define (debugger-binding-record name)
      (list 'binding
            (result-field 'name
                          (if (symbol? name) name 'unknown-binding))))

    ;; Return binding-name records for ENVIRONMENT's current frame.
    (define (debugger-frame-bindings environment)
      (if environment
          (map debugger-binding-record
               (take (map car (environment-frame environment))
                     debugger-maximum-frame-bindings))
          '()))

    ;; Return a debugger environment frame for ENVIRONMENT and FRAME-ID.
    (define (debugger-environment-frame environment frame-id)
      (let ((binding-count
             (if environment (length (environment-frame environment)) 0)))
        (list
         (result-field 'frame frame-id)
         (result-field 'bindings (debugger-frame-bindings environment))
         (result-field
          'truncated
          (if (> binding-count debugger-maximum-frame-bindings) #t #f)))))

    ;; Return a debugger stack frame.
    (define (debugger-stack-frame phase frame-id)
      (list 'frame
            (result-field 'id frame-id)
            (result-field 'phase phase)))

    ;; Return a debugger restart record.
    (define (debugger-restart-record id category policy)
      (list 'restart
            (result-field 'id id)
            (result-field 'category category)
            (result-field 'policy policy)
            (result-field 'status 'available)))

    ;; Return debugger restarts that are always safe to advertise.
    (define (debugger-default-restarts)
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

    ;; Return values for FIELD from a debugger datum.
    (define (debugger-field-values datum field)
      (let ((entry (and (pair? datum) (assq field (cdr datum)))))
        (if entry (cdr entry) '())))

    ;; Return the first value for FIELD from a debugger datum.
    (define (debugger-field-value datum field)
      (let ((values (debugger-field-values datum field)))
        (if (null? values) #f (car values))))

    ;; Return DATUM or raise when OPERATION expected a debugger condition.
    (define (debugger-expect-condition datum operation)
      (if (not (and (pair? datum) (eq? (car datum) 'condition)))
          (eval-error
           (string-append operation " expected a debugger condition")))
      datum)

    ;; Return ID as a debugger restart symbol.
    (define (debugger-restart-id-name id)
      (cond
       ((symbol? id) id)
       ((string? id) (string->symbol id))
       (else (eval-error "restart id must be a symbol or string"))))

    ;; Build a Scheme-readable debugger condition datum.
    (define (debugger-condition-datum condition context)
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

    ;; Build a debugger condition for a Scheme-raised EXCEPTION value.
    (define (debugger-exception-datum exception context)
      (append
       (debugger-condition-datum
        (make-agent-scheme-error-object
         "raised exception"
         (list exception))
        context)
       (list (result-field 'value (value->result-datum exception)))))

    ;; Build a successful evaluation-result datum for VALUE.
    (define (ok-result-datum value context)
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

    ;; Build an error evaluation-result datum for CONDITION.
    (define (condition-result-datum condition context)
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

    ;; Render an evaluation-result datum using the reader/writer external form.
    (define (agent-scheme-result->external result)
      (agent-scheme-datum->external result))

    ;; Render runtime values for diagnostics while keeping non-datum values
    ;; opaque and stripping macro identifier wrappers from datum-like results.
    (define (agent-scheme-value->external value)
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
