;;; Public Consent Scheme transcript records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral replayable transcript datums, replay
;;; classification, fixture generation, and summary views.  Host adapters may
;;; add generated ids and real timestamps, but the public shape stays ordinary
;;; Scheme data.

(define-library (agent transcript)
  (export transcript-event-kinds
          transcript-replay-modes
          transcript-export-formats
          transcript-retention-default
          make-transcript-event
          transcript-event?
          transcript-field-value
          transcript-event-replay-mode
          transcript-replayable?
          transcript-recorded-observation?
          transcript-event->fixture-case
          transcript-event-summary
          transcript-raw-view
          transcript-summary-view
          transcript-rotate
          transcript-export)
  (import (scheme base))
  (begin
    ;; Event kinds cover session lifecycle, evaluation, agent I/O, policy,
    ;; capability, skill, memory, and provider-routing activity.
    (define transcript-event-kinds
      '(session-start session-end session-snapshot session-fork
        eval-start eval-end eval-error macro-expansion import definition
        agent-yield agent-log agent-progress agent-warn agent-request
        approval-request approval-decision capability-call
        skill-discovery skill-activation skill-resource-access
        memory-write memory-summary model-route))

    ;; Replay modes explain what a consumer may do with a recorded event.
    (define transcript-replay-modes
      '(audit-only deterministic-pure fixture-generation
                   recorded-observation))

    ;; Export formats distinguish raw datums, summaries, and generated tests.
    (define transcript-export-formats
      '(scheme-datum text-summary fixture-cases))

    ;; Default retention policy is Scheme-readable so hosts can display or
    ;; persist policy without inventing a second configuration shape.
    (define transcript-retention-default
      '(transcript-retention
        (retain-events 200)
        (rotate-events 200)
        (summarize-after 100)
        (export-formats (scheme-datum text-summary fixture-cases))))

    (define (default-value maybe-default)
      "Return the optional DEFAULT value from MAYBE-DEFAULT."
      (if (null? maybe-default) #f (car maybe-default)))

    (define (field-named? field name)
      "Return #t when FIELD is named NAME."
      (and (pair? field) (eq? (car field) name)))

    (define (fields-value fields name default)
      "Return NAME from FIELDS, or DEFAULT when absent."
      (let loop ((rest fields))
        (cond
         ((null? rest) default)
         ((field-named? (car rest) name)
          (let ((value (cdr (car rest))))
            (if (and (pair? value) (null? (cdr value)))
                (car value)
                value)))
         (else (loop (cdr rest))))))

    (define (transcript-field-value datum name . maybe-default)
      "Return field NAME from DATUM, or DEFAULT when absent."
      #((parameters
         (datum
          (type any)
          (description "Transcript record or field list to inspect."))
         (name
          (type any)
          (description "Symbol naming the field to read."))
         (maybe-default
          (type any)
          (description "Optional fallback value; defaults to #f.")))
        (returns
         (type any)
         (description "The field value, or DEFAULT when NAME is absent."))
        (effects pure))
      (fields-value (if (pair? datum) (cdr datum) '())
                    name
                    (default-value maybe-default)))

    (define (transcript-event? datum)
      "Return #t when DATUM is a transcript event record."
      #((parameters
         (datum
          (type any)
          (description "Value to inspect.")))
        (returns
         (type any)
         (description
          ("#t when DATUM is tagged as a transcript event; otherwise"
           "#f.")))
        (effects pure))
      (and (pair? datum) (eq? (car datum) 'transcript-event)))

    (define (host-effect-kind? kind)
      "Report whether KIND represents a non-replayable host observation."
      (memq kind
            '(approval-request approval-decision capability-call
              skill-discovery skill-activation skill-resource-access
              memory-write memory-summary model-route)))

    (define (replay-record-mode replay-record)
      "Return replay mode from REPLAY-RECORD, or #f when absent."
      (if (pair? replay-record)
          (fields-value (cdr replay-record) 'mode #f)
          #f))

    (define (classify-transcript-event event)
      "Classify EVENT according to its kind and fields."
      (or (replay-record-mode (transcript-field-value event 'replay))
          (let ((kind (transcript-field-value event 'kind))
                (form (transcript-field-value event 'form))
                (result (transcript-field-value event 'result))
                (error (transcript-field-value event 'error))
                (effect (transcript-field-value event 'effect))
                (capability (transcript-field-value event 'capability)))
            (cond
             ((or effect capability (host-effect-kind? kind))
              'recorded-observation)
             ((and (eq? kind 'eval-end) form result)
              'deterministic-pure)
             ((and (eq? kind 'eval-error) form error)
              'fixture-generation)
             (else
              'audit-only)))))

    (define (replay-reason mode)
      "Return a short replay reason string for MODE."
      (cond
       ((eq? mode 'deterministic-pure)
        "pure Scheme evaluation can be replayed")
       ((eq? mode 'fixture-generation)
        "event can seed a test fixture")
       ((eq? mode 'recorded-observation)
        "host effect is replayed only as an observation")
       (else
        "event is retained for audit only")))

    (define (replay-effect mode)
      "Return the effect replay class for MODE."
      (cond
       ((eq? mode 'deterministic-pure) 'pure-evaluation)
       ((eq? mode 'fixture-generation) 'pure-fixture)
       ((eq? mode 'recorded-observation) 'recorded-observation)
       (else 'audit-only)))

    (define (replay-field event)
      "Return a replay field for EVENT."
      (let ((mode (classify-transcript-event event)))
        (list 'replay
              (list 'mode mode)
              (list 'effect (replay-effect mode))
              (list 'reason (replay-reason mode)))))

    (define (reserved-field? field)
      "Report whether FIELD is supplied by make-transcript-event."
      (memq (car field) '(id session kind time replay)))

    (define (event-body-fields fields)
      "Return FIELDS with reserved event-construction fields removed."
      (let loop ((rest fields) (result '()))
        (cond
         ((null? rest) (reverse result))
         ((reserved-field? (car rest))
          (loop (cdr rest) result))
         (else
          (loop (cdr rest) (cons (car rest) result))))))

    (define (make-transcript-event kind fields)
      "Create a transcript event with deterministic defaults for missing fields."
      #((parameters
         (kind
          (type any)
          (description "Transcript event kind symbol."))
         (fields
          (type any)
          (description
           ("Field list supplied by the caller; reserved construction"
            "fields are normalized."))))
        (returns
         (type any)
         (description
          ("A `transcript-event` datum with id, kind, time, and replay"
           "metadata.")))
        (effects pure)
        (see-also transcript-event-replay-mode transcript-event-summary))
      (let ((id (fields-value fields 'id 'e-0))
            (session (fields-value fields 'session #f))
            (time (fields-value fields 'time "portable")))
        (let ((base
               (append
                (list 'transcript-event
                      (list 'id id))
                (if session (list (list 'session session)) '())
                (list (list 'kind kind))
                (event-body-fields fields)
                (list (list 'time time)))))
          (append base (list (replay-field base))))))

    (define (transcript-event-replay-mode event)
      "Return EVENT's replay mode."
      #((parameters
         (event
          (type any)
          (description "Transcript event datum.")))
        (returns
         (type any)
         (description
          ("Replay mode symbol such as deterministic-pure,"
           "fixture-generation, recorded-observation, or audit-only.")))
        (effects pure))
      (classify-transcript-event event))

    (define (transcript-replayable? event)
      "Return #t when EVENT can drive deterministic replay or fixtures."
      #((parameters
         (event
          (type any)
          (description "Transcript event datum.")))
        (returns
         (type any)
         (description
          ("#t when EVENT can be replayed or converted into a fixture;"
           "otherwise #f.")))
        (effects pure))
      (memq (transcript-event-replay-mode event)
            '(deterministic-pure fixture-generation)))

    (define (transcript-recorded-observation? event)
      "Return #t when EVENT represents a recorded host observation."
      #((parameters
         (event
          (type any)
          (description "Transcript event datum.")))
        (returns
         (type any)
         (description
          ("#t when EVENT is host observation data rather than"
           "replayable computation; otherwise #f.")))
        (effects pure))
      (eq? (transcript-event-replay-mode event) 'recorded-observation))

    (define (summary-value value)
      "Return VALUE as a summary string."
      (cond
       ((not value) "")
       ((string? value) value)
       ((symbol? value) (symbol->string value))
       (else "<datum>")))

    (define (fixture-id id)
      "Return a generated fixture id for transcript event ID."
      (string->symbol
       (string-append "transcript-" (summary-value id))))

    (define (fixture-source form)
      "Return FORM as a fixture source string."
      (if (string? form) form "<datum>"))

    (define (fixture-result result)
      "Return RESULT as a fixture expected value string."
      (if (string? result) result "<datum>"))

    (define (transcript-event->fixture-case event)
      "Generate a shared fixture case from EVENT when replay permits it."
      #((parameters
         (event
          (type any)
          (description "Transcript event datum.")))
        (returns
         (type any)
         (description
          ("A shared fixture case datum when EVENT can seed one;"
           "otherwise #f.")))
        (effects pure)
        (see-also transcript-replayable? transcript-export))
      (let ((mode (transcript-event-replay-mode event))
            (id (transcript-field-value event 'id))
            (form (transcript-field-value event 'form))
            (result (transcript-field-value event 'result))
            (error (transcript-field-value event 'error)))
        (cond
         ((and (eq? mode 'deterministic-pure) form result)
          (list
           (list 'id (fixture-id id))
           (list 'kind 'agent-specific)
           (list 'phase 'eval)
           (list 'category 'transcript-replay)
           (list 'section "agent transcript")
           (list 'status 'implemented)
           (list 'oracle 'shared)
           (list 'options '())
           (list 'description
                 (string-append
                  "Generated from transcript event "
                  (summary-value id)
                  "."))
           (list 'source (fixture-source form))
           (list 'expect
                 (list 'value (fixture-result result)))))
         ((and (eq? mode 'fixture-generation) form error)
          (list
           (list 'id (fixture-id id))
           (list 'kind 'agent-specific)
           (list 'phase 'error)
           (list 'category 'transcript-replay)
           (list 'section "agent transcript")
           (list 'status 'implemented)
           (list 'oracle 'shared)
           (list 'options '())
           (list 'description
                 (string-append
                  "Generated from transcript event "
                  (summary-value id)
                  "."))
           (list 'source (fixture-source form))
           (list 'expect (list 'error))))
         (else #f))))

    (define (transcript-event-summary event)
      "Return a human-readable one-line summary for EVENT."
      #((parameters
         (event
          (type any)
          (description "Transcript event datum.")))
        (returns
         (type any)
         (description
          ("A compact text summary suitable for logs or transcript"
           "lists.")))
        (effects pure))
      (let ((id (summary-value (transcript-field-value event 'id)))
            (kind (summary-value (transcript-field-value event 'kind)))
            (session (summary-value
                      (transcript-field-value event 'session))))
        (let ((base (string-append
                     id
                     " "
                     kind
                     (if (= (string-length session) 0)
                         ""
                         (string-append " in " session))))
              (mode (transcript-event-replay-mode event))
              (result (transcript-field-value event 'result))
              (error (transcript-field-value event 'error)))
          (cond
           ((eq? mode 'recorded-observation)
            (string-append base " recorded observation"))
           (result
            (string-append base " => " (summary-value result)))
           (error
            (string-append base " ! " (summary-value error)))
           (else base)))))

    (define (transcript-raw-view events)
      "Return EVENTS as raw Scheme-readable datums."
      #((parameters
         (events
          (type any)
          (description "Chronological list of transcript event datums.")))
        (returns
         (type any)
         (description "EVENTS unchanged."))
        (effects pure))
      events)

    (define (transcript-summary-view events)
      "Return human-readable summaries for EVENTS."
      #((parameters
         (events
          (type any)
          (description "Chronological list of transcript event datums.")))
        (returns
         (type any)
         (description "List of one-line summary strings."))
        (effects pure))
      (map transcript-event-summary events))

    (define (drop items count)
      "Drop the first COUNT items from ITEMS."
      (if (or (= count 0) (null? items))
          items
          (drop (cdr items) (- count 1))))

    (define (transcript-rotate events keep)
      "Return the newest KEEP events from chronological EVENTS."
      #((parameters
         (events
          (type any)
          (description "Chronological list of transcript event datums."))
         (keep
          (type any)
          (description "Maximum number of newest events to retain.")))
        (returns
         (type any)
         (description "A suffix of EVENTS containing at most KEEP records."))
        (effects pure))
      (let ((count (length events)))
        (if (or (<= count keep) (<= keep 0))
            events
            (drop events (- count keep)))))

    (define (filter-map procedure items)
      "Return non-#f values from ITEMS after applying PROCEDURE."
      (let loop ((rest items) (result '()))
        (cond
         ((null? rest) (reverse result))
         (else
          (let ((value (procedure (car rest))))
            (loop (cdr rest)
                  (if value (cons value result) result)))))))

    (define (transcript-export events format)
      "Return a transcript view for EVENTS in FORMAT."
      #((parameters
         (events
          (type any)
          (description "Chronological list of transcript event datums."))
         (format
          (type any)
          (description
           ("Export format symbol: scheme-datum, text-summary, or"
            "fixture-cases."))))
        (returns
         (type any)
         (description
          ("Raw events, summary strings, or generated fixture cases"
           "for EVENTS.")))
        (effects pure)
        (see-also transcript-raw-view transcript-summary-view transcript-event->fixture-case))
      (cond
       ((eq? format 'scheme-datum)
        (transcript-raw-view events))
       ((eq? format 'text-summary)
        (transcript-summary-view events))
       ((eq? format 'fixture-cases)
        (filter-map transcript-event->fixture-case events))
       (else
        (error "unknown transcript export format" format))))))
