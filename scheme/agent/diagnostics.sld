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
    (define (diagnostics-field name . values)
      "Return a Scheme-readable record field named NAME with VALUES."
      (cons name values))

    (define (diagnostics-field-value record field default)
      "Return FIELD's first value from RECORD, or DEFAULT when absent."
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    ;; Report whether DATUM is a record tagged by TAG.
    (define (diagnostics-record? datum tag)
      (and (pair? datum) (eq? (car datum) tag)))

    (define (make-diagnostic-range start end line column end-line end-column)
      "Return a source range with absolute and line/column positions."
      (list 'diagnostic-range
            (diagnostics-field 'start start)
            (diagnostics-field 'end end)
            (diagnostics-field 'line line)
            (diagnostics-field 'column column)
            (diagnostics-field 'end-line end-line)
            (diagnostics-field 'end-column end-column)))

    (define (diagnostic-range? datum)
      "Return #t when DATUM is a diagnostic range record."
      (diagnostics-record? datum 'diagnostic-range))

    (define (diagnostic-range-start range)
      "Return RANGE's absolute start position."
      (diagnostics-field-value range 'start #f))

    (define (diagnostic-range-end range)
      "Return RANGE's absolute end position."
      (diagnostics-field-value range 'end #f))

    (define (make-diagnostic severity message source file buffer range metadata)
      "Return one diagnostic record in the shared adapter-neutral shape."
      (list 'diagnostic
            (diagnostics-field 'severity severity)
            (diagnostics-field 'message message)
            (diagnostics-field 'source source)
            (diagnostics-field 'file file)
            (diagnostics-field 'buffer buffer)
            (diagnostics-field 'range range)
            (diagnostics-field 'metadata metadata)))

    (define (diagnostic? datum)
      "Return #t when DATUM is a diagnostic record."
      (diagnostics-record? datum 'diagnostic))

    (define (diagnostic-severity diagnostic)
      "Return DIAGNOSTIC's severity symbol."
      (diagnostics-field-value diagnostic 'severity #f))

    (define (diagnostic-message diagnostic)
      "Return DIAGNOSTIC's human-readable message."
      (diagnostics-field-value diagnostic 'message #f))

    (define (diagnostic-source diagnostic)
      "Return DIAGNOSTIC's originating backend or protocol source."
      (diagnostics-field-value diagnostic 'source #f))

    (define (diagnostic-file diagnostic)
      "Return DIAGNOSTIC's file path, or #f when it is buffer-only."
      (diagnostics-field-value diagnostic 'file #f))

    (define (diagnostic-buffer diagnostic)
      "Return DIAGNOSTIC's buffer name or handle metadata."
      (diagnostics-field-value diagnostic 'buffer #f))

    (define (diagnostic-range diagnostic)
      "Return DIAGNOSTIC's source range record."
      (diagnostics-field-value diagnostic 'range #f))

    (define (diagnostic-metadata diagnostic)
      "Return DIAGNOSTIC's backend metadata fields."
      (diagnostics-field-value diagnostic 'metadata '()))

    (define (make-diagnostics-snapshot status scope buffer file diagnostics metadata)
      "Return a stable diagnostic snapshot for one adapter observation."
      (list 'diagnostics-snapshot
            (diagnostics-field 'status status)
            (diagnostics-field 'scope scope)
            (diagnostics-field 'buffer buffer)
            (diagnostics-field 'file file)
            (diagnostics-field 'diagnostics diagnostics)
            (diagnostics-field 'metadata metadata)))

    (define (diagnostics-snapshot? datum)
      "Return #t when DATUM is a diagnostics snapshot record."
      (diagnostics-record? datum 'diagnostics-snapshot))

    (define (diagnostics-snapshot-status snapshot)
      "Return SNAPSHOT's status symbol."
      (diagnostics-field-value snapshot 'status #f))

    (define (diagnostics-snapshot-diagnostics snapshot)
      "Return SNAPSHOT's diagnostic record list."
      (diagnostics-field-value snapshot 'diagnostics '()))

    (define (make-diagnostics-capability-request id operation authority arguments)
      "Return a host-adapter request datum for a diagnostics operation."
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

    (define (diagnostics-capability-request? datum)
      "Return #t when DATUM is a diagnostics capability request record."
      (diagnostics-record? datum 'diagnostics-capability-request))

    (define (diagnostics-capability-request-operation request)
      "Return REQUEST's operation symbol."
      (diagnostics-field-value request 'operation #f))

    (define (make-diagnostics-capability-result id status value)
      "Return a host-adapter result datum for a diagnostics operation."
      (list 'diagnostics-capability-result
            (diagnostics-field 'id id)
            (diagnostics-field 'status status)
            (diagnostics-field 'value value)))

    (define (make-diagnostics-outcome status message)
      "Return an explicit diagnostics outcome record for adapter availability."
      (list 'diagnostics-outcome
            (diagnostics-field 'status status)
            (diagnostics-field 'message message)))

    (define (diagnostics-outcome? datum)
      "Return #t when DATUM is a diagnostics outcome record."
      (diagnostics-record? datum 'diagnostics-outcome))

    (define (diagnostics-outcome-status outcome)
      "Return OUTCOME's status symbol."
      (diagnostics-field-value outcome 'status #f))

    ;; Stable severity vocabulary shared by host adapters.
    (define diagnostic-known-severities
      '(error warning note info hint unknown))

    (define (diagnostic-known-severity? severity)
      "Return #t when SEVERITY is in the shared diagnostic vocabulary."
      (if (memq severity diagnostic-known-severities) #t #f))

    ;; Read-only diagnostic observations never perform code actions.
    (define diagnostics-read-only-operations
      '(buffer-diagnostics project-diagnostics diagnostic-at))

    (define (diagnostics-read-only-operation? operation)
      "Return #t when OPERATION is a read-only diagnostics observation."
      (if (memq operation diagnostics-read-only-operations) #t #f))

    (define (diagnostics-yield diagnostics)
      "Yield DIAGNOSTICS through the portable Agent Scheme event channel."
      (agent-yield diagnostics))))
