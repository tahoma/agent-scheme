;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
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
      #((parameters . ((name . "Symbol naming the diagnostic field.")
                       (values . "Zero or more Scheme-readable field values.")))
        (returns . "A field pair whose car is NAME and whose cdr is VALUES.")
        (effects . (pure)))
      (cons name values))

    (define (diagnostics-field-value record field default)
      "Return FIELD's first value from RECORD, or DEFAULT when absent."
      #((parameters . ((record . "Diagnostic record represented as a tagged list.")
                       (field . "Symbol naming the field to read.")
                       (default . "Fallback value returned when FIELD is absent or empty.")))
        (returns . "The first stored value for FIELD, or DEFAULT.")
        (effects . (pure)))
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    (define (diagnostics-record? datum tag)
      "Report whether DATUM is a record tagged by TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (make-diagnostic-range start end line column end-line end-column)
      "Return a source range with absolute and line/column positions."
      #((parameters . ((start . "Absolute start offset.")
                       (end . "Absolute end offset.")
                       (line . "One-based start line, or host-provided line datum.")
                       (column . "One-based start column, or host-provided column datum.")
                       (end-line . "One-based end line, or host-provided line datum.")
                       (end-column . "One-based end column, or host-provided column datum.")))
        (returns . "A `diagnostic-range` datum.")
        (effects . (pure)))
      (list 'diagnostic-range
            (diagnostics-field 'start start)
            (diagnostics-field 'end end)
            (diagnostics-field 'line line)
            (diagnostics-field 'column column)
            (diagnostics-field 'end-line end-line)
            (diagnostics-field 'end-column end-column)))

    (define (diagnostic-range? datum)
      "Return #t when DATUM is a diagnostic range record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a diagnostic range; otherwise #f.")
        (effects . (pure)))
      (diagnostics-record? datum 'diagnostic-range))

    (define (diagnostic-range-start range)
      "Return RANGE's absolute start position."
      #((parameters . ((range . "Diagnostic range datum.")))
        (returns . "The absolute start offset, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value range 'start #f))

    (define (diagnostic-range-end range)
      "Return RANGE's absolute end position."
      #((parameters . ((range . "Diagnostic range datum.")))
        (returns . "The absolute end offset, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value range 'end #f))

    (define (make-diagnostic severity message source file buffer range metadata)
      "Return one diagnostic record in the shared adapter-neutral shape."
      #((parameters . ((severity . "Severity symbol from the shared diagnostic vocabulary.")
                       (message . "Human-readable diagnostic message.")
                       (source . "Backend, tool, or protocol source datum.")
                       (file . "File path datum, or #f for buffer-only diagnostics.")
                       (buffer . "Buffer name or handle metadata, or #f.")
                       (range . "Diagnostic range datum, or #f.")
                       (metadata . "Additional backend metadata as Scheme-readable data.")))
        (returns . "A `diagnostic` datum.")
        (effects . (pure)))
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
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a diagnostic record; otherwise #f.")
        (effects . (pure)))
      (diagnostics-record? datum 'diagnostic))

    (define (diagnostic-severity diagnostic)
      "Return DIAGNOSTIC's severity symbol."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "The diagnostic severity symbol, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'severity #f))

    (define (diagnostic-message diagnostic)
      "Return DIAGNOSTIC's human-readable message."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "The diagnostic message string, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'message #f))

    (define (diagnostic-source diagnostic)
      "Return DIAGNOSTIC's originating backend or protocol source."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "The source datum, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'source #f))

    (define (diagnostic-file diagnostic)
      "Return DIAGNOSTIC's file path, or #f when it is buffer-only."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "The file path datum, or #f.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'file #f))

    (define (diagnostic-buffer diagnostic)
      "Return DIAGNOSTIC's buffer name or handle metadata."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "The buffer name or handle metadata, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'buffer #f))

    (define (diagnostic-range diagnostic)
      "Return DIAGNOSTIC's source range record."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "The diagnostic range datum, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'range #f))

    (define (diagnostic-metadata diagnostic)
      "Return DIAGNOSTIC's backend metadata fields."
      #((parameters . ((diagnostic . "Diagnostic datum.")))
        (returns . "Backend metadata fields, or the empty list.")
        (effects . (pure)))
      (diagnostics-field-value diagnostic 'metadata '()))

    (define (make-diagnostics-snapshot status scope buffer file diagnostics metadata)
      "Return a stable diagnostic snapshot for one adapter observation."
      #((parameters . ((status . "Snapshot status symbol.")
                       (scope . "Observation scope, such as buffer or project.")
                       (buffer . "Buffer name or handle metadata, or #f.")
                       (file . "File path datum, or #f.")
                       (diagnostics . "List of diagnostic records.")
                       (metadata . "Additional adapter metadata.")))
        (returns . "A `diagnostics-snapshot` datum.")
        (effects . (pure)))
      (list 'diagnostics-snapshot
            (diagnostics-field 'status status)
            (diagnostics-field 'scope scope)
            (diagnostics-field 'buffer buffer)
            (diagnostics-field 'file file)
            (diagnostics-field 'diagnostics diagnostics)
            (diagnostics-field 'metadata metadata)))

    (define (diagnostics-snapshot? datum)
      "Return #t when DATUM is a diagnostics snapshot record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a diagnostics snapshot; otherwise #f.")
        (effects . (pure)))
      (diagnostics-record? datum 'diagnostics-snapshot))

    (define (diagnostics-snapshot-status snapshot)
      "Return SNAPSHOT's status symbol."
      #((parameters . ((snapshot . "Diagnostics snapshot datum.")))
        (returns . "The snapshot status symbol, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value snapshot 'status #f))

    (define (diagnostics-snapshot-diagnostics snapshot)
      "Return SNAPSHOT's diagnostic record list."
      #((parameters . ((snapshot . "Diagnostics snapshot datum.")))
        (returns . "The diagnostic record list, or the empty list.")
        (effects . (pure)))
      (diagnostics-field-value snapshot 'diagnostics '()))

    (define (make-diagnostics-capability-request id operation authority arguments)
      "Return a host-adapter request datum for a diagnostics operation."
      #((parameters . ((id . "Stable request id.")
                       (operation . "Diagnostics operation symbol.")
                       (authority . "Requested authority family.")
                       (arguments . "Operation arguments as Scheme-readable data.")))
        (returns . "A `diagnostics-capability-request` datum.")
        (effects . (pure)))
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
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a diagnostics capability request; otherwise #f.")
        (effects . (pure)))
      (diagnostics-record? datum 'diagnostics-capability-request))

    (define (diagnostics-capability-request-operation request)
      "Return REQUEST's operation symbol."
      #((parameters . ((request . "Diagnostics capability request datum.")))
        (returns . "The operation symbol, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value request 'operation #f))

    (define (make-diagnostics-capability-result id status value)
      "Return a host-adapter result datum for a diagnostics operation."
      #((parameters . ((id . "Request id associated with the result.")
                       (status . "Result status symbol.")
                       (value . "Result payload, usually a snapshot or outcome datum.")))
        (returns . "A `diagnostics-capability-result` datum.")
        (effects . (pure)))
      (list 'diagnostics-capability-result
            (diagnostics-field 'id id)
            (diagnostics-field 'status status)
            (diagnostics-field 'value value)))

    (define (make-diagnostics-outcome status message)
      "Return an explicit diagnostics outcome record for adapter availability."
      #((parameters . ((status . "Outcome status symbol.")
                       (message . "Human-readable outcome message.")))
        (returns . "A `diagnostics-outcome` datum.")
        (effects . (pure)))
      (list 'diagnostics-outcome
            (diagnostics-field 'status status)
            (diagnostics-field 'message message)))

    (define (diagnostics-outcome? datum)
      "Return #t when DATUM is a diagnostics outcome record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a diagnostics outcome; otherwise #f.")
        (effects . (pure)))
      (diagnostics-record? datum 'diagnostics-outcome))

    (define (diagnostics-outcome-status outcome)
      "Return OUTCOME's status symbol."
      #((parameters . ((outcome . "Diagnostics outcome datum.")))
        (returns . "The outcome status symbol, or #f when absent.")
        (effects . (pure)))
      (diagnostics-field-value outcome 'status #f))

    ;; Stable severity vocabulary shared by host adapters.
    (define diagnostic-known-severities
      '(error warning note info hint unknown))

    (define (diagnostic-known-severity? severity)
      "Return #t when SEVERITY is in the shared diagnostic vocabulary."
      #((parameters . ((severity . "Severity symbol to check.")))
        (returns . "#t when SEVERITY is one of the portable diagnostic severities; otherwise #f.")
        (effects . (pure)))
      (if (memq severity diagnostic-known-severities) #t #f))

    ;; Read-only diagnostic observations never perform code actions.
    (define diagnostics-read-only-operations
      '(buffer-diagnostics project-diagnostics diagnostic-at))

    (define (diagnostics-read-only-operation? operation)
      "Return #t when OPERATION is a read-only diagnostics observation."
      #((parameters . ((operation . "Diagnostics operation symbol to classify.")))
        (returns . "#t when OPERATION is read-only; otherwise #f.")
        (effects . (pure)))
      (if (memq operation diagnostics-read-only-operations) #t #f))

    (define (diagnostics-yield diagnostics)
      "Yield DIAGNOSTICS through the portable Agent Scheme event channel."
      #((parameters . ((diagnostics . "Diagnostic snapshot, diagnostic list, or related diagnostic datum to publish.")))
        (returns . "The host-specific result of `agent-yield`.")
        (effects . (agent-yield)))
      (agent-yield diagnostics))))
