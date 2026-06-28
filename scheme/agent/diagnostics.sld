;;; diagnostics.sld --- Portable Consent Scheme diagnostic datum library
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
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
      #((parameters
         (name
          (type any)
          (description "Symbol naming the diagnostic field."))
         (values
          (type any)
          (description "Zero or more Scheme-readable field values.")))
        (returns
         (type any)
         (description
          ("A field pair whose car is NAME and whose cdr is VALUES.")))
        (effects pure))
      (cons name values))

    (define (diagnostics-field-value record field default)
      "Return FIELD's first value from RECORD, or DEFAULT when absent."
      #((parameters
         (record
          (type any)
          (description "Diagnostic record represented as a tagged list."))
         (field
          (type any)
          (description "Symbol naming the field to read."))
         (default
          (type any)
          (description
           ("Fallback value returned when FIELD is absent or empty."))))
        (returns
         (type any)
         (description "The first stored value for FIELD, or DEFAULT."))
        (effects pure))
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    (define (diagnostics-record? datum tag)
      "Report whether DATUM is a record tagged by TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (make-diagnostic-range start end line column end-line end-column)
      "Return a source range with absolute and line/column positions."
      #((parameters
         (start
          (type any)
          (description "Absolute start offset."))
         (end
          (type any)
          (description "Absolute end offset."))
         (line
          (type any)
          (description "One-based start line, or host-provided line datum."))
         (column
          (type any)
          (description
           ("One-based start column, or host-provided column datum.")))
         (end-line
          (type any)
          (description "One-based end line, or host-provided line datum."))
         (end-column
          (type any)
          (description
           ("One-based end column, or host-provided column datum."))))
        (returns
         (type any)
         (description "A `diagnostic-range` datum."))
        (effects pure))
      (list 'diagnostic-range
            (diagnostics-field 'start start)
            (diagnostics-field 'end end)
            (diagnostics-field 'line line)
            (diagnostics-field 'column column)
            (diagnostics-field 'end-line end-line)
            (diagnostics-field 'end-column end-column)))

    (define (diagnostic-range? datum)
      "Return #t when DATUM is a diagnostic range record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a diagnostic range; otherwise"
           "#f.")))
        (effects pure))
      (diagnostics-record? datum 'diagnostic-range))

    (define (diagnostic-range-start range)
      "Return RANGE's absolute start position."
      #((parameters
         (range
          (type any)
          (description "Diagnostic range datum.")))
        (returns
         (type any)
         (description "The absolute start offset, or #f when absent."))
        (effects pure))
      (diagnostics-field-value range 'start #f))

    (define (diagnostic-range-end range)
      "Return RANGE's absolute end position."
      #((parameters
         (range
          (type any)
          (description "Diagnostic range datum.")))
        (returns
         (type any)
         (description "The absolute end offset, or #f when absent."))
        (effects pure))
      (diagnostics-field-value range 'end #f))

    (define (make-diagnostic severity message source file buffer range metadata)
      "Return one diagnostic record in the shared adapter-neutral shape."
      #((parameters
         (severity
          (type any)
          (description
           ("Severity symbol from the shared diagnostic vocabulary.")))
         (message
          (type any)
          (description "Human-readable diagnostic message."))
         (source
          (type any)
          (description "Backend, tool, or protocol source datum."))
         (file
          (type any)
          (description "File path datum, or #f for buffer-only diagnostics."))
         (buffer
          (type any)
          (description "Buffer name or handle metadata, or #f."))
         (range
          (type any)
          (description "Diagnostic range datum, or #f."))
         (metadata
          (type any)
          (description
           ("Additional backend metadata as Scheme-readable data."))))
        (returns
         (type any)
         (description "A `diagnostic` datum."))
        (effects pure))
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
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a diagnostic record; otherwise"
           "#f.")))
        (effects pure))
      (diagnostics-record? datum 'diagnostic))

    (define (diagnostic-severity diagnostic)
      "Return DIAGNOSTIC's severity symbol."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description "The diagnostic severity symbol, or #f when absent."))
        (effects pure))
      (diagnostics-field-value diagnostic 'severity #f))

    (define (diagnostic-message diagnostic)
      "Return DIAGNOSTIC's human-readable message."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description "The diagnostic message string, or #f when absent."))
        (effects pure))
      (diagnostics-field-value diagnostic 'message #f))

    (define (diagnostic-source diagnostic)
      "Return DIAGNOSTIC's originating backend or protocol source."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description "The source datum, or #f when absent."))
        (effects pure))
      (diagnostics-field-value diagnostic 'source #f))

    (define (diagnostic-file diagnostic)
      "Return DIAGNOSTIC's file path, or #f when it is buffer-only."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description "The file path datum, or #f."))
        (effects pure))
      (diagnostics-field-value diagnostic 'file #f))

    (define (diagnostic-buffer diagnostic)
      "Return DIAGNOSTIC's buffer name or handle metadata."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description
          ("The buffer name or handle metadata, or #f when absent.")))
        (effects pure))
      (diagnostics-field-value diagnostic 'buffer #f))

    (define (diagnostic-range diagnostic)
      "Return DIAGNOSTIC's source range record."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description "The diagnostic range datum, or #f when absent."))
        (effects pure))
      (diagnostics-field-value diagnostic 'range #f))

    (define (diagnostic-metadata diagnostic)
      "Return DIAGNOSTIC's backend metadata fields."
      #((parameters
         (diagnostic
          (type any)
          (description "Diagnostic datum.")))
        (returns
         (type any)
         (description "Backend metadata fields, or the empty list."))
        (effects pure))
      (diagnostics-field-value diagnostic 'metadata '()))

    (define (make-diagnostics-snapshot status scope buffer file diagnostics metadata)
      "Return a stable diagnostic snapshot for one adapter observation."
      #((parameters
         (status
          (type any)
          (description "Snapshot status symbol."))
         (scope
          (type any)
          (description "Observation scope, such as buffer or project."))
         (buffer
          (type any)
          (description "Buffer name or handle metadata, or #f."))
         (file
          (type any)
          (description "File path datum, or #f."))
         (diagnostics
          (type any)
          (description "List of diagnostic records."))
         (metadata
          (type any)
          (description "Additional adapter metadata.")))
        (returns
         (type any)
         (description "A `diagnostics-snapshot` datum."))
        (effects pure))
      (list 'diagnostics-snapshot
            (diagnostics-field 'status status)
            (diagnostics-field 'scope scope)
            (diagnostics-field 'buffer buffer)
            (diagnostics-field 'file file)
            (diagnostics-field 'diagnostics diagnostics)
            (diagnostics-field 'metadata metadata)))

    (define (diagnostics-snapshot? datum)
      "Return #t when DATUM is a diagnostics snapshot record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a diagnostics snapshot;"
           "otherwise #f.")))
        (effects pure))
      (diagnostics-record? datum 'diagnostics-snapshot))

    (define (diagnostics-snapshot-status snapshot)
      "Return SNAPSHOT's status symbol."
      #((parameters
         (snapshot
          (type any)
          (description "Diagnostics snapshot datum.")))
        (returns
         (type any)
         (description "The snapshot status symbol, or #f when absent."))
        (effects pure))
      (diagnostics-field-value snapshot 'status #f))

    (define (diagnostics-snapshot-diagnostics snapshot)
      "Return SNAPSHOT's diagnostic record list."
      #((parameters
         (snapshot
          (type any)
          (description "Diagnostics snapshot datum.")))
        (returns
         (type any)
         (description "The diagnostic record list, or the empty list."))
        (effects pure))
      (diagnostics-field-value snapshot 'diagnostics '()))

    (define (make-diagnostics-capability-request id operation authority arguments)
      "Return a host-adapter request datum for a diagnostics operation."
      #((parameters
         (id
          (type any)
          (description "Stable request id."))
         (operation
          (type any)
          (description "Diagnostics operation symbol."))
         (authority
          (type any)
          (description "Requested authority family."))
         (arguments
          (type any)
          (description "Operation arguments as Scheme-readable data.")))
        (returns
         (type any)
         (description "A `diagnostics-capability-request` datum."))
        (effects pure))
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
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a diagnostics capability"
           "request; otherwise #f.")))
        (effects pure))
      (diagnostics-record? datum 'diagnostics-capability-request))

    (define (diagnostics-capability-request-operation request)
      "Return REQUEST's operation symbol."
      #((parameters
         (request
          (type any)
          (description "Diagnostics capability request datum.")))
        (returns
         (type any)
         (description "The operation symbol, or #f when absent."))
        (effects pure))
      (diagnostics-field-value request 'operation #f))

    (define (make-diagnostics-capability-result id status value)
      "Return a host-adapter result datum for a diagnostics operation."
      #((parameters
         (id
          (type any)
          (description "Request id associated with the result."))
         (status
          (type any)
          (description "Result status symbol."))
         (value
          (type any)
          (description
           ("Result payload, usually a snapshot or outcome datum."))))
        (returns
         (type any)
         (description "A `diagnostics-capability-result` datum."))
        (effects pure))
      (list 'diagnostics-capability-result
            (diagnostics-field 'id id)
            (diagnostics-field 'status status)
            (diagnostics-field 'value value)))

    (define (make-diagnostics-outcome status message)
      "Return an explicit diagnostics outcome record for adapter availability."
      #((parameters
         (status
          (type any)
          (description "Outcome status symbol."))
         (message
          (type any)
          (description "Human-readable outcome message.")))
        (returns
         (type any)
         (description "A `diagnostics-outcome` datum."))
        (effects pure))
      (list 'diagnostics-outcome
            (diagnostics-field 'status status)
            (diagnostics-field 'message message)))

    (define (diagnostics-outcome? datum)
      "Return #t when DATUM is a diagnostics outcome record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a diagnostics outcome;"
           "otherwise #f.")))
        (effects pure))
      (diagnostics-record? datum 'diagnostics-outcome))

    (define (diagnostics-outcome-status outcome)
      "Return OUTCOME's status symbol."
      #((parameters
         (outcome
          (type any)
          (description "Diagnostics outcome datum.")))
        (returns
         (type any)
         (description "The outcome status symbol, or #f when absent."))
        (effects pure))
      (diagnostics-field-value outcome 'status #f))

    ;; Stable severity vocabulary shared by host adapters.
    (define diagnostic-known-severities
      '(error warning note info hint unknown))

    (define (diagnostic-known-severity? severity)
      "Return #t when SEVERITY is in the shared diagnostic vocabulary."
      #((parameters
         (severity
          (type any)
          (description "Severity symbol to check.")))
        (returns
         (type any)
         (description
          ("#t when SEVERITY is one of the portable diagnostic"
           "severities; otherwise #f.")))
        (effects pure))
      (if (memq severity diagnostic-known-severities) #t #f))

    ;; Read-only diagnostic observations never perform code actions.
    (define diagnostics-read-only-operations
      '(buffer-diagnostics project-diagnostics diagnostic-at))

    (define (diagnostics-read-only-operation? operation)
      "Return #t when OPERATION is a read-only diagnostics observation."
      #((parameters
         (operation
          (type any)
          (description "Diagnostics operation symbol to classify.")))
        (returns
         (type any)
         (description "#t when OPERATION is read-only; otherwise #f."))
        (effects pure))
      (if (memq operation diagnostics-read-only-operations) #t #f))

    (define (diagnostics-yield diagnostics)
      "Yield DIAGNOSTICS through the portable Consent Scheme event channel."
      #((parameters
         (diagnostics
          (type any)
          (description
           ("Diagnostic snapshot, diagnostic list, or related"
            "diagnostic datum to publish."))))
        (returns
         (type any)
         (description "The host-specific result of `agent-yield`."))
        (effects agent-yield))
      (agent-yield diagnostics))))
