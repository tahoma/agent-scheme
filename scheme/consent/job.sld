;;; Portable Consent Scheme job records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral job lifecycle model as Scheme-readable
;;; datums.  Host adapters own scheduling, threads, process supervision, and
;;; forceful stop mechanics while preserving these public state names and
;;; record fields.

(define-library (consent job)
  (export consent-job-states
          consent-make-job-store
          consent-job-store?
          job-start!
          job-ref
          job-list
          job-cancel!
          job-interrupt!
          job-yields
          job-status
          job-mark-running!
          job-record-yield!
          job-complete!
          job-fail!
          job-finish-cancelled!
          job-datum-id)
  (import (scheme base))
  (begin
    ;; Public job states are Scheme data shared by host adapters and portable
    ;; tests.
    (define consent-job-states
      '(queued running yielding waiting-approval waiting-input
               cancel-requested cancelled completed failed))

    ;; Mutable store for portable tests and host-neutral job record operations.
    (define-record-type <consent-job-store>
      (make-job-store records next-id)
      consent-job-store?
      (records store-records set-store-records!)
      (next-id store-next-id set-store-next-id!))

    ;; Mutable portable job record.  Hosts expose job->datum rather than this
    ;; record so thread and process handles never become Scheme values.
    (define-record-type <consent-job>
      (make-job id session kind status can-cancel started-at completed-at
                budget yields result error source options interrupt-reason)
      job?
      (id job-id)
      (session job-session)
      (kind job-kind)
      (status job-record-status set-job-status!)
      (can-cancel job-can-cancel set-job-can-cancel!)
      (started-at job-started-at)
      (completed-at job-completed-at set-job-completed-at!)
      (budget job-budget)
      (yields job-record-yields set-job-yields!)
      (result job-result set-job-result!)
      (error job-error set-job-error!)
      (source job-source)
      (options job-options)
      (interrupt-reason job-interrupt-reason set-job-interrupt-reason!))

    (define (consent-make-job-store)
      "Construct an empty portable job store."
      #((parameters . ())
        (returns . "A mutable job store with no records and the next generated id set to zero.")
        (effects . (allocation)))
      (make-job-store '() 0))

    (define (member-eq? value list)
      "Report whether VALUE is in LIST using eq?."
      (cond
       ((null? list) #f)
       ((eq? value (car list)) #t)
       (else (member-eq? value (cdr list)))))

    (define (normalize-status status)
      "Validate and return STATUS."
      (if (member-eq? status consent-job-states)
          status
          (error "unknown job status" status)))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT if absent."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (generated-id store)
      "Generate a fresh job id in STORE."
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        (string->symbol
         (string-append "j-" (number->string next)))))

    (define (portable-timestamp)
      "Return a portable placeholder timestamp."
      "portable")

    (define (budget-datum options)
      "Return a budget datum derived from OPTIONS."
      (list 'budget
            (list 'max-steps (option-ref options 'max-steps 100000))
            (list 'max-host-callbacks
                  (option-ref options 'max-host-callbacks 10000))
            (list 'max-events (option-ref options 'max-events 1000))))

    (define (session-id-value session)
      "Return the session id from SESSION."
      session)

    (define (record-id record)
      "Return RECORD's id field."
      (job-id record))

    (define (without-record store id)
      "Return STORE records without ID."
      (let loop ((records (store-records store)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((eq? (record-id (car records)) id)
          (loop (cdr records) result))
         (else
          (loop (cdr records) (cons (car records) result))))))

    (define (store-record! store record)
      "Store RECORD, replacing any previous record with the same id."
      (set-store-records!
       store
       (append (without-record store (record-id record))
               (list record)))
      record)

    (define (find-job store id)
      "Return job ID record from STORE, or #f."
      (let loop ((records (store-records store)))
        (cond
         ((null? records) #f)
         ((eq? (record-id (car records)) id) (car records))
         (else (loop (cdr records))))))

    (define (require-job store id)
      "Return job ID record from STORE or raise an error."
      (let ((job (find-job store id)))
        (if job
            job
            (error "unknown job" id))))

    (define (terminal-job? job)
      "Report whether JOB is in a terminal state."
      (member-eq? (job-record-status job) '(cancelled completed failed)))

    (define (job->datum job)
      "Return JOB as a Scheme-readable datum."
      (append
       (list 'job
             (list 'id (job-id job))
             (list 'session (job-session job))
             (list 'kind (job-kind job))
             (list 'status (job-record-status job))
             (list 'can-cancel (job-can-cancel job))
             (list 'started-at (job-started-at job))
             (job-budget job)
             (list 'yields (job-record-yields job)))
       (if (job-completed-at job)
           (list (list 'completed-at (job-completed-at job)))
           '())
       (if (job-result job)
           (list (list 'result (job-result job)))
           '())
       (if (job-error job)
           (list (list 'error (job-error job)))
           '())))

    (define (job-datum-id job-datum)
      "Return the id field from a public JOB-DATUM."
      #((parameters . ((job-datum . "Public job datum.")))
        (returns . "The job id field.")
        (effects . (pure)))
      (cadr (cadr job-datum)))

    (define (job-start! store session form options)
      "Create a queued eval job in STORE for SESSION and FORM."
      #((parameters . ((store . "Job store to mutate.")
                       (session . "Session id or session datum associated with the job.")
                       (form . "Scheme form or source datum to evaluate.")
                       (options . "Association list overriding id, budget, source, and other job fields.")))
        (returns . "The queued public job datum.")
        (effects . (state-write)))
      (let* ((id (option-ref options 'id (generated-id store)))
             (job (make-job id
                            (session-id-value session)
                            'eval
                            'queued
                            #t
                            (portable-timestamp)
                            #f
                            (budget-datum options)
                            '()
                            #f
                            #f
                            form
                            options
                            #f)))
        (store-record! store job)
        (job->datum job)))

    (define (job-ref store id)
      "Return job ID datum from STORE, or #f."
      #((parameters . ((store . "Job store to search.")
                       (id . "Job id symbol.")))
        (returns . "The public job datum, or #f when ID is unknown.")
        (effects . (state-read)))
      (let ((job (find-job store id)))
        (if job (job->datum job) #f)))

    (define (job-list store . maybe-session)
      "Return job datums from STORE, optionally filtered by SESSION."
      #((parameters . ((store . "Job store to inspect.")
                       (maybe-session . "Optional session id used to filter jobs.")))
        (returns . "List of public job datums in creation order.")
        (effects . (state-read)))
      (let ((session (if (null? maybe-session) #f (car maybe-session))))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((or (not session) (eq? (job-session (car records)) session))
            (loop (cdr records)
                  (cons (job->datum (car records)) result)))
           (else
            (loop (cdr records) result))))))

    (define (job-status store id)
      "Return job ID status from STORE, or #f."
      #((parameters . ((store . "Job store to search.")
                       (id . "Job id symbol.")))
        (returns . "The job status symbol, or #f when ID is unknown.")
        (effects . (state-read)))
      (let ((job (find-job store id)))
        (if job (job-record-status job) #f)))

    (define (job-yields store id options)
      "Return job ID yields from STORE after any requested offset."
      #((parameters . ((store . "Job store to search.")
                       (id . "Job id symbol.")
                       (options . "Association list; `after` skips events already seen.")))
        (returns . "List of yield events recorded after the requested offset.")
        (effects . (state-read error)))
      (let ((after (option-ref options 'after 0))
            (yields (job-record-yields (require-job store id))))
        (let loop ((rest yields) (index after))
          (if (or (= index 0) (null? rest))
              rest
              (loop (cdr rest) (- index 1))))))

    (define (job-mark-running! store id)
      "Mark job ID as running."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")))
        (returns . "The updated public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (if (not (terminal-job? job))
            (set-job-status! job 'running))
        (job->datum job)))

    (define (event-status event)
      "Return the streaming status suggested by EVENT."
      (cond
       ((and (pair? event) (eq? (car event) 'request))
        (if (and (pair? (cadr event)) (eq? (car (cadr event)) 'approval))
            'waiting-approval
            'waiting-input))
       ((and (pair? event)
             (member-eq? (car event) '(yield progress warn log debugger)))
        'yielding)
       (else 'running)))

    (define (job-record-yield! store id event)
      "Append EVENT to job ID's stream and update its streaming status."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")
                       (event . "Yield event datum to append.")))
        (returns . "The updated public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (set-job-yields!
         job
         (append (job-record-yields job) (list event)))
        (if (not (terminal-job? job))
            (set-job-status! job (event-status event)))
        (job->datum job)))

    (define (job-cancel! store id)
      "Request cooperative cancellation of job ID."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")))
        (returns . "The updated public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (if (not (terminal-job? job))
            (begin
              (set-job-can-cancel! job #f)
              (set-job-status! job 'cancel-requested)))
        (job->datum job)))

    (define (job-interrupt! store id reason)
      "Request cooperative interrupt of job ID with REASON."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")
                       (reason . "Interrupt reason datum.")))
        (returns . "The updated public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (if (not (terminal-job? job))
            (begin
              (set-job-can-cancel! job #f)
              (set-job-interrupt-reason! job reason)
              (set-job-status! job 'cancel-requested)))
        (job->datum job)))

    (define (job-complete! store id result)
      "Complete job ID with RESULT."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")
                       (result . "Evaluation or host result datum.")))
        (returns . "The completed public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (set-job-can-cancel! job #f)
        (set-job-result! job result)
        (set-job-completed-at! job (portable-timestamp))
        (set-job-status! job 'completed)
        (job->datum job)))

    (define (job-fail! store id message)
      "Fail job ID with MESSAGE."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")
                       (message . "Failure message string or datum.")))
        (returns . "The failed public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (set-job-can-cancel! job #f)
        (set-job-error! job message)
        (set-job-completed-at! job (portable-timestamp))
        (set-job-status! job 'failed)
        (job->datum job)))

    (define (job-finish-cancelled! store id message)
      "Finish job ID as cancelled with MESSAGE."
      #((parameters . ((store . "Job store to mutate.")
                       (id . "Job id symbol.")
                       (message . "Cancellation message string or datum.")))
        (returns . "The cancelled public job datum.")
        (effects . (state-write error)))
      (let ((job (require-job store id)))
        (set-job-can-cancel! job #f)
        (set-job-error! job message)
        (set-job-completed-at! job (portable-timestamp))
        (set-job-status! job 'cancelled)
        (job->datum job)))))
