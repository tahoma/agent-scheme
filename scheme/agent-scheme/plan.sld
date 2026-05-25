;;; Portable Agent Scheme planning records.
;;;
;;; This library owns host-neutral scoped plan records as Scheme-readable data.
;;; Event channels, memory persistence, buffers, and host UX are adapter
;;; concerns that can be rebuilt from these canonical plan records.

(define-library (agent-scheme plan)
  (export agent-scheme-plan-scopes
          agent-scheme-plan-statuses
          agent-scheme-plan-step-statuses
          agent-scheme-make-plan-store
          agent-scheme-plan-store?
          plan-create!
          plan-ref
          plan-list
          plan-step-add!
          plan-step-status!
          plan-status!
          plan-record-id
          plan-record-scope
          plan-record-steps
          plan-step-id
          plan-step-status
          plan-memory-important?)
  (import (scheme base)
          (agent-scheme reader))
  (begin
    ;; Public plan scopes mirror fresh one-off evaluations, durable sessions,
    ;; and project-shared work.
    (define agent-scheme-plan-scopes
      '(fresh session project))

    ;; Plan statuses describe the overall lifecycle visible to users.
    (define agent-scheme-plan-statuses
      '(pending active blocked done cancelled failed))

    ;; Step statuses describe stable checklist items inside a plan.
    (define agent-scheme-plan-step-statuses
      '(pending active blocked done skipped cancelled failed))

    ;; Mutable portable plan store for host-neutral tests and interpreter
    ;; primitives.  Records remain canonical datums in the records field.
    (define-record-type <agent-scheme-plan-store>
      (make-plan-store records next-id)
      agent-scheme-plan-store?
      (records store-records set-store-records!)
      (next-id store-next-id set-store-next-id!))

    ;; Construct an empty plan store.
    (define (agent-scheme-make-plan-store)
      (make-plan-store '() 0))

    ;; Report whether VALUE appears in LIST using equal?.
    (define (member-equal? value list)
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    ;; Validate and return SCOPE.
    (define (normalize-scope scope)
      (if (member-equal? scope agent-scheme-plan-scopes)
          scope
          (error "unknown plan scope" scope)))

    ;; Validate and return STATUS from ALLOWED.
    (define (normalize-status status allowed description)
      (if (member-equal? status allowed)
          status
          (error description status)))

    ;; Increment STORE's sequence and return the new value.
    (define (next-sequence! store)
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        next))

    ;; Convert PREFIX and SEQUENCE into a generated id.
    (define (generated-id prefix sequence)
      (string->symbol
       (string-append prefix "-" (number->string sequence))))

    ;; Return SEQUENCE as an Agent Scheme exact integer datum.
    (define (integer-datum sequence)
      (agent-scheme-make-canonical-integer sequence))

    ;; Return field NAME from DATUM or #f.
    (define (field-value datum name)
      (let loop ((fields (if (and (pair? datum) (eq? (car datum) 'plan))
                             (cdr datum)
                             datum)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) name))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    ;; Return DATUM's plan payload fields.
    (define (payload-fields datum)
      (if (and (pair? datum) (eq? (car datum) 'plan))
          (cdr datum)
          datum))

    ;; Return FIELD with NAME and VALUE.
    (define (plan-field name value)
      (list name value))

    ;; Return RECORD with field NAME replaced by VALUE.
    (define (replace-field record name value)
      (cons
       (car record)
       (map (lambda (field)
              (if (and (pair? field) (eq? (car field) name))
                  (plan-field name value)
                  field))
            (cdr record))))

    ;; Return RECORD with refreshed updated-at sequence.
    (define (touch-plan store record)
      (replace-field record 'updated-at (integer-datum (next-sequence! store))))

    ;; Return canonical id field from a plan RECORD.
    (define (plan-record-id record)
      (field-value record 'id))

    ;; Return RECORD's scope field.
    (define (plan-record-scope record)
      (field-value record 'scope))

    ;; Return RECORD's step list.
    (define (plan-record-steps record)
      (let ((steps (field-value record 'steps)))
        (if steps steps '())))

    ;; Return STEP's id field.
    (define (plan-step-id step)
      (field-value step 'id))

    ;; Return STEP's status field.
    (define (plan-step-status step)
      (field-value step 'status))

    ;; Return #t when DATUM requests memory summarization.
    (define (plan-memory-important? datum)
      (let ((memory (field-value (payload-fields datum) 'memory)))
        (or (eq? memory 'important)
            (eq? memory 'persist)
            (eq? memory 'summary))))

    ;; Return records from STORE belonging to SCOPE, newest first.
    (define (scope-records store scope)
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((eq? (field-value (car records) 'scope) normalized-scope)
            (loop (cdr records) (cons (car records) result)))
           (else (loop (cdr records) result))))))

    ;; Return a plan record from STORE by ID, or #f.
    (define (plan-ref store id)
      (let loop ((records (store-records store)))
        (cond
         ((null? records) #f)
         ((equal? (plan-record-id (car records)) id) (car records))
         (else (loop (cdr records))))))

    ;; Return all plans in SCOPE.
    (define (plan-list store scope)
      (scope-records store scope))

    ;; Return STORE records with any plan matching ID removed.
    (define (without-plan store id)
      (let loop ((records (store-records store)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((equal? (plan-record-id (car records)) id)
          (loop (cdr records) result))
         (else (loop (cdr records) (cons (car records) result))))))

    ;; Return STEP in canonical field order.
    (define (normalize-step step generated)
      (let* ((fields (payload-fields step))
             (id (let ((field (field-value fields 'id)))
                   (if field field generated)))
             (status (normalize-status
                      (let ((field (field-value fields 'status)))
                        (if field field 'pending))
                      agent-scheme-plan-step-statuses
                      "unknown plan step status"))
             (extras
              (let loop ((rest fields) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((or (eq? (caar rest) 'id)
                      (eq? (caar rest) 'status))
                  (loop (cdr rest) result))
                 (else (loop (cdr rest) (cons (car rest) result)))))))
        (append
         (list (plan-field 'id id)
               (plan-field 'status status))
         extras)))

    ;; Return STEPS as a canonical list of step datums.
    (define (normalize-steps steps)
      (map (lambda (step) (normalize-step step #f))
           (if steps steps '())))

    ;; Build a canonical Scheme-readable plan record.
    (define (make-plan-record store datum existing)
      (let* ((sequence (next-sequence! store))
             (id (let ((field (field-value (payload-fields datum) 'id)))
                   (if field
                       field
                       (if existing
                           (plan-record-id existing)
                           (generated-id "p" sequence)))))
             (scope (normalize-scope
                     (let ((field (field-value (payload-fields datum)
                                               'scope)))
                       (if field
                           field
                           (if existing
                               (plan-record-scope existing)
                               'fresh)))))
             (status (normalize-status
                      (let ((field (field-value (payload-fields datum)
                                                'status)))
                        (if field
                            field
                            (let ((existing-status
                                   (and existing
                                        (field-value existing 'status))))
                              (if existing-status existing-status 'pending))))
                      agent-scheme-plan-statuses
                      "unknown plan status"))
             (goal (let ((field (field-value (payload-fields datum) 'goal)))
                     (if field
                         field
                         (let ((existing-goal
                                (and existing
                                     (field-value existing 'goal))))
                           (if existing-goal existing-goal "")))))
             (steps (normalize-steps
                     (let ((field (field-value (payload-fields datum)
                                               'steps)))
                       (if field
                           field
                           (let ((existing-steps
                                  (and existing
                                       (field-value existing 'steps))))
                             (if existing-steps existing-steps '()))))))
             (created-at (if existing
                             (field-value existing 'created-at)
                             (integer-datum sequence))))
        (list 'plan
              (plan-field 'id id)
              (plan-field 'scope scope)
              (plan-field 'status status)
              (plan-field 'goal goal)
              (plan-field 'steps steps)
              (plan-field 'created-at created-at)
              (plan-field 'updated-at (integer-datum sequence)))))

    ;; Create or replace a plan from DATUM and return its canonical record.
    (define (plan-create! store datum)
      (let* ((id (field-value (payload-fields datum) 'id))
             (existing (and id (plan-ref store id)))
             (record (make-plan-record store datum existing)))
        (set-store-records!
         store
         (cons record (without-plan store (plan-record-id record))))
        record))

    ;; Add STEP-DATUM to plan ID and return the updated plan.
    (define (plan-step-add! store id step-datum)
      (let ((record (plan-ref store id)))
        (if (not record)
            (error "unknown plan" id))
        (let* ((step (normalize-step
                      step-datum
                      (generated-id "step" (+ (store-next-id store) 1))))
               (updated
                (touch-plan
                 store
                 (replace-field
                  record
                  'steps
                  (append (plan-record-steps record) (list step))))))
          (set-store-records!
           store
           (cons updated (without-plan store id)))
          updated)))

    ;; Set plan ID step STEP-ID to STATUS and return the updated plan.
    (define (plan-step-status! store id step-id status)
      (let ((record (plan-ref store id))
            (normalized-status
             (normalize-status status
                               agent-scheme-plan-step-statuses
                               "unknown plan step status"))
            (found #f))
        (if (not record)
            (error "unknown plan" id))
        (let* ((steps
                (map
                 (lambda (step)
                   (if (equal? (plan-step-id step) step-id)
                       (begin
                         (set! found #t)
                         (normalize-step
                          (replace-field step 'status normalized-status)
                          #f))
                       step))
                 (plan-record-steps record)))
               (updated
                (touch-plan store (replace-field record 'steps steps))))
          (if (not found)
              (error "unknown plan step" step-id))
          (set-store-records!
           store
           (cons updated (without-plan store id)))
          updated)))

    ;; Set plan ID to STATUS and return the updated plan.
    (define (plan-status! store id status)
      (let ((record (plan-ref store id))
            (normalized-status
             (normalize-status status
                               agent-scheme-plan-statuses
                               "unknown plan status")))
        (if (not record)
            (error "unknown plan" id))
        (let ((updated
               (touch-plan
                store
                (replace-field record 'status normalized-status))))
          (set-store-records!
           store
           (cons updated (without-plan store id)))
          updated)))))
