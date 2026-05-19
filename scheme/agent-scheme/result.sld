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

    ;; Return audit events in the order they were recorded.
    (define (context-events context)
      (reverse (context-audit-events context)))

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

    ;; Return a printable message for a caught Scheme condition.
    (define (condition-message condition)
      (if (error-object? condition)
          (error-object-message condition)
          "error"))

    ;; Build an error evaluation-result datum for CONDITION.
    (define (condition-result-datum condition context)
      (list 'evaluation-result
            (result-field 'status 'error)
            (result-field
             'error
             (result-field 'condition 'error)
             (result-field 'message (condition-message condition)))
            (result-field 'events (context-events context))
            (budget-result-field context)))

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
