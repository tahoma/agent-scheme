;;; Public Agent Scheme transcript records.
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

    ;; Return the optional DEFAULT value from MAYBE-DEFAULT.
    (define (default-value maybe-default)
      (if (null? maybe-default) #f (car maybe-default)))

    ;; Return #t when FIELD is named NAME.
    (define (field-named? field name)
      (and (pair? field) (eq? (car field) name)))

    ;; Return NAME from FIELDS, or DEFAULT when absent.
    (define (fields-value fields name default)
      (let loop ((rest fields))
        (cond
         ((null? rest) default)
         ((field-named? (car rest) name)
          (let ((value (cdr (car rest))))
            (if (and (pair? value) (null? (cdr value)))
                (car value)
                value)))
         (else (loop (cdr rest))))))

    ;; Return field NAME from DATUM, or DEFAULT when absent.
    (define (transcript-field-value datum name . maybe-default)
      (fields-value (if (pair? datum) (cdr datum) '())
                    name
                    (default-value maybe-default)))

    ;; Report whether DATUM is a transcript event record.
    (define (transcript-event? datum)
      (and (pair? datum) (eq? (car datum) 'transcript-event)))

    ;; Report whether KIND represents a non-replayable host observation.
    (define (host-effect-kind? kind)
      (memq kind
            '(approval-request approval-decision capability-call
              skill-discovery skill-activation skill-resource-access
              memory-write memory-summary model-route)))

    ;; Return replay mode from REPLAY-RECORD, or #f when absent.
    (define (replay-record-mode replay-record)
      (if (pair? replay-record)
          (fields-value (cdr replay-record) 'mode #f)
          #f))

    ;; Classify EVENT according to its kind and fields.
    (define (classify-transcript-event event)
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

    ;; Return a short replay reason string for MODE.
    (define (replay-reason mode)
      (cond
       ((eq? mode 'deterministic-pure)
        "pure Scheme evaluation can be replayed")
       ((eq? mode 'fixture-generation)
        "event can seed a test fixture")
       ((eq? mode 'recorded-observation)
        "host effect is replayed only as an observation")
       (else
        "event is retained for audit only")))

    ;; Return the effect replay class for MODE.
    (define (replay-effect mode)
      (cond
       ((eq? mode 'deterministic-pure) 'pure-evaluation)
       ((eq? mode 'fixture-generation) 'pure-fixture)
       ((eq? mode 'recorded-observation) 'recorded-observation)
       (else 'audit-only)))

    ;; Return a replay field for EVENT.
    (define (replay-field event)
      (let ((mode (classify-transcript-event event)))
        (list 'replay
              (list 'mode mode)
              (list 'effect (replay-effect mode))
              (list 'reason (replay-reason mode)))))

    ;; Report whether FIELD is supplied by make-transcript-event.
    (define (reserved-field? field)
      (memq (car field) '(id session kind time replay)))

    ;; Return FIELDS with reserved event-construction fields removed.
    (define (event-body-fields fields)
      (let loop ((rest fields) (result '()))
        (cond
         ((null? rest) (reverse result))
         ((reserved-field? (car rest))
          (loop (cdr rest) result))
         (else
          (loop (cdr rest) (cons (car rest) result))))))

    ;; Create a transcript event.  Hosts may pass explicit `id' and `time'
    ;; fields; otherwise this portable constructor uses deterministic defaults.
    (define (make-transcript-event kind fields)
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

    ;; Return EVENT's replay mode.
    (define (transcript-event-replay-mode event)
      (classify-transcript-event event))

    ;; Report whether EVENT can drive deterministic replay or fixtures.
    (define (transcript-replayable? event)
      (memq (transcript-event-replay-mode event)
            '(deterministic-pure fixture-generation)))

    ;; Report whether EVENT represents a recorded host observation.
    (define (transcript-recorded-observation? event)
      (eq? (transcript-event-replay-mode event) 'recorded-observation))

    ;; Return VALUE as a summary string.
    (define (summary-value value)
      (cond
       ((not value) "")
       ((string? value) value)
       ((symbol? value) (symbol->string value))
       (else "<datum>")))

    ;; Return a generated fixture id for transcript event ID.
    (define (fixture-id id)
      (string->symbol
       (string-append "transcript-" (summary-value id))))

    ;; Return FORM as a fixture source string.
    (define (fixture-source form)
      (if (string? form) form "<datum>"))

    ;; Return RESULT as a fixture expected value string.
    (define (fixture-result result)
      (if (string? result) result "<datum>"))

    ;; Generate a shared fixture case from EVENT when replay permits it.
    (define (transcript-event->fixture-case event)
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

    ;; Return a human-readable one-line summary for EVENT.
    (define (transcript-event-summary event)
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

    ;; Return EVENTS as raw Scheme-readable datums.
    (define (transcript-raw-view events)
      events)

    ;; Return human-readable summaries for EVENTS.
    (define (transcript-summary-view events)
      (map transcript-event-summary events))

    ;; Drop the first COUNT items from ITEMS.
    (define (drop items count)
      (if (or (= count 0) (null? items))
          items
          (drop (cdr items) (- count 1))))

    ;; Return the newest KEEP events from chronological EVENTS.
    (define (transcript-rotate events keep)
      (let ((count (length events)))
        (if (or (<= count keep) (<= keep 0))
            events
            (drop events (- count keep)))))

    ;; Return non-#f values from ITEMS after applying PROCEDURE.
    (define (filter-map procedure items)
      (let loop ((rest items) (result '()))
        (cond
         ((null? rest) (reverse result))
         (else
          (let ((value (procedure (car rest))))
            (loop (cdr rest)
                  (if value (cons value result) result)))))))

    ;; Return a transcript view for EVENTS in FORMAT.
    (define (transcript-export events format)
      (cond
       ((eq? format 'scheme-datum)
        (transcript-raw-view events))
       ((eq? format 'text-summary)
        (transcript-summary-view events))
       ((eq? format 'fixture-cases)
        (filter-map transcript-event->fixture-case events))
       (else
        (error "unknown transcript export format" format))))))
