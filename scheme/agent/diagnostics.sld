;;; diagnostics.sld --- Portable Agent Scheme diagnostic datum library
;;;
;;; This host-neutral library owns canonical diagnostic datums, adapter
;;; request/result records, and event yielding. Host adapters obtain diagnostic
;;; state, but Scheme-visible values stay printable data and code actions stay
;;; outside this read-only contract.

(define-library (agent diagnostics)
  (export diagnostics-field
          diagnostics-field-value
          make-diagnostic-range
          diagnostic-range?
          diagnostic-range-start
          diagnostic-range-end
          make-diagnostic
          diagnostic?
          diagnostic-severity
          diagnostic-message
          diagnostic-source
          diagnostic-file
          diagnostic-buffer
          diagnostic-range
          diagnostic-metadata
          make-diagnostics-snapshot
          diagnostics-snapshot?
          diagnostics-snapshot-status
          diagnostics-snapshot-diagnostics
          make-diagnostics-capability-request
          diagnostics-capability-request?
          diagnostics-capability-request-operation
          make-diagnostics-capability-result
          make-diagnostics-outcome
          diagnostics-outcome?
          diagnostics-outcome-status
          diagnostic-known-severity?
          diagnostics-read-only-operation?
          diagnostics-yield)
  (import (scheme base)
          (agent io))
  (begin
    ;; Return a Scheme-readable record field named NAME with VALUES.
    (define (diagnostics-field name . values)
      (cons name values))

    ;; Return FIELD's first value from RECORD, or DEFAULT when absent.
    (define (diagnostics-field-value record field default)
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    ;; Report whether DATUM is a record tagged by TAG.
    (define (diagnostics-record? datum tag)
      (and (pair? datum) (eq? (car datum) tag)))

    ;; Return a source range with absolute and line/column positions.
    (define (make-diagnostic-range start end line column end-line end-column)
      (list 'diagnostic-range
            (diagnostics-field 'start start)
            (diagnostics-field 'end end)
            (diagnostics-field 'line line)
            (diagnostics-field 'column column)
            (diagnostics-field 'end-line end-line)
            (diagnostics-field 'end-column end-column)))

    ;; Report whether DATUM is a diagnostic range record.
    (define (diagnostic-range? datum)
      (diagnostics-record? datum 'diagnostic-range))

    ;; Return RANGE's absolute start position.
    (define (diagnostic-range-start range)
      (diagnostics-field-value range 'start #f))

    ;; Return RANGE's absolute end position.
    (define (diagnostic-range-end range)
      (diagnostics-field-value range 'end #f))

    ;; Return one diagnostic record in the shared adapter-neutral shape.
    (define (make-diagnostic severity message source file buffer range metadata)
      (list 'diagnostic
            (diagnostics-field 'severity severity)
            (diagnostics-field 'message message)
            (diagnostics-field 'source source)
            (diagnostics-field 'file file)
            (diagnostics-field 'buffer buffer)
            (diagnostics-field 'range range)
            (diagnostics-field 'metadata metadata)))

    ;; Report whether DATUM is a diagnostic record.
    (define (diagnostic? datum)
      (diagnostics-record? datum 'diagnostic))

    ;; Return DIAGNOSTIC's severity symbol.
    (define (diagnostic-severity diagnostic)
      (diagnostics-field-value diagnostic 'severity #f))

    ;; Return DIAGNOSTIC's human-readable message.
    (define (diagnostic-message diagnostic)
      (diagnostics-field-value diagnostic 'message #f))

    ;; Return DIAGNOSTIC's originating backend or protocol source.
    (define (diagnostic-source diagnostic)
      (diagnostics-field-value diagnostic 'source #f))

    ;; Return DIAGNOSTIC's file path, or #f when it is buffer-only.
    (define (diagnostic-file diagnostic)
      (diagnostics-field-value diagnostic 'file #f))

    ;; Return DIAGNOSTIC's buffer name or handle metadata.
    (define (diagnostic-buffer diagnostic)
      (diagnostics-field-value diagnostic 'buffer #f))

    ;; Return DIAGNOSTIC's source range record.
    (define (diagnostic-range diagnostic)
      (diagnostics-field-value diagnostic 'range #f))

    ;; Return DIAGNOSTIC's backend metadata fields.
    (define (diagnostic-metadata diagnostic)
      (diagnostics-field-value diagnostic 'metadata '()))

    ;; Return a stable diagnostic snapshot for one adapter observation.
    (define (make-diagnostics-snapshot status scope buffer file diagnostics metadata)
      (list 'diagnostics-snapshot
            (diagnostics-field 'status status)
            (diagnostics-field 'scope scope)
            (diagnostics-field 'buffer buffer)
            (diagnostics-field 'file file)
            (diagnostics-field 'diagnostics diagnostics)
            (diagnostics-field 'metadata metadata)))

    ;; Report whether DATUM is a diagnostics snapshot record.
    (define (diagnostics-snapshot? datum)
      (diagnostics-record? datum 'diagnostics-snapshot))

    ;; Return SNAPSHOT's status symbol.
    (define (diagnostics-snapshot-status snapshot)
      (diagnostics-field-value snapshot 'status #f))

    ;; Return SNAPSHOT's diagnostic record list.
    (define (diagnostics-snapshot-diagnostics snapshot)
      (diagnostics-field-value snapshot 'diagnostics '()))

    ;; Return a host-adapter request datum for a diagnostics operation.
    (define (make-diagnostics-capability-request id operation authority arguments)
      (list 'diagnostics-capability-request
            (diagnostics-field 'id id)
            (diagnostics-field 'operation operation)
            (diagnostics-field 'authority authority)
            (diagnostics-field 'arguments arguments)
            (diagnostics-field 'required-authority
                               (if (diagnostics-read-only-operation? operation)
                                   'read-only-observation
                                   'unknown))
            (diagnostics-field 'mutating? #f)))

    ;; Report whether DATUM is a diagnostics capability request record.
    (define (diagnostics-capability-request? datum)
      (diagnostics-record? datum 'diagnostics-capability-request))

    ;; Return REQUEST's operation symbol.
    (define (diagnostics-capability-request-operation request)
      (diagnostics-field-value request 'operation #f))

    ;; Return a host-adapter result datum for a diagnostics operation.
    (define (make-diagnostics-capability-result id status value)
      (list 'diagnostics-capability-result
            (diagnostics-field 'id id)
            (diagnostics-field 'status status)
            (diagnostics-field 'value value)))

    ;; Return an explicit diagnostics outcome record for adapter availability.
    (define (make-diagnostics-outcome status message)
      (list 'diagnostics-outcome
            (diagnostics-field 'status status)
            (diagnostics-field 'message message)))

    ;; Report whether DATUM is a diagnostics outcome record.
    (define (diagnostics-outcome? datum)
      (diagnostics-record? datum 'diagnostics-outcome))

    ;; Return OUTCOME's status symbol.
    (define (diagnostics-outcome-status outcome)
      (diagnostics-field-value outcome 'status #f))

    ;; Stable severity vocabulary shared by host adapters.
    (define diagnostic-known-severities
      '(error warning note info hint unknown))

    ;; Report whether SEVERITY is in the shared diagnostic vocabulary.
    (define (diagnostic-known-severity? severity)
      (if (memq severity diagnostic-known-severities) #t #f))

    ;; Read-only diagnostic observations never perform code actions.
    (define diagnostics-read-only-operations
      '(buffer-diagnostics project-diagnostics diagnostic-at))

    ;; Report whether OPERATION is a read-only diagnostics observation.
    (define (diagnostics-read-only-operation? operation)
      (if (memq operation diagnostics-read-only-operations) #t #f))

    ;; Yield a diagnostic datum through the portable Agent Scheme event channel.
    (define (diagnostics-yield diagnostics)
      (agent-yield diagnostics))))
