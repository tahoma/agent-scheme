;;; Portable Consent Scheme planning records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral scoped plan records as Scheme-readable data.
;;; Event channels, memory persistence, buffers, and host UX are adapter
;;; concerns that can be rebuilt from these canonical plan records.

(define-library (consent plan)
  (export consent-plan-scopes
          consent-plan-statuses
          consent-plan-step-statuses
          consent-make-plan-store
          consent-plan-store?
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
          (consent reader))
  (begin
    ;; Public plan scopes mirror fresh one-off evaluations, durable sessions,
    ;; and project-shared work.
    (define consent-plan-scopes
      '(fresh session project))

    ;; Plan statuses describe the overall lifecycle visible to users.
    (define consent-plan-statuses
      '(pending active blocked done cancelled failed))

    ;; Step statuses describe stable checklist items inside a plan.
    (define consent-plan-step-statuses
      '(pending active blocked done skipped cancelled failed))

    ;; Mutable portable plan store for host-neutral tests and interpreter
    ;; primitives.  Records remain canonical datums in the records field.
    (define-record-type <consent-plan-store>
      (make-plan-store records next-id)
      consent-plan-store?
      (records store-records set-store-records!)
      (next-id store-next-id set-store-next-id!))

    (define (consent-make-plan-store)
      "Construct an empty plan store."
      #((parameters)
        (returns (type consent-plan-store)
         (description
          ("A mutable plan store with no records and the next"
            "generated id set to zero.")))
        (effects allocation))
      (make-plan-store '() 0))

    (define (member-equal? value list)
      "Report whether VALUE appears in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (if (member-equal? scope consent-plan-scopes)
          scope
          (error "unknown plan scope" scope)))

    (define (normalize-status status allowed description)
      "Validate and return STATUS from ALLOWED."
      (if (member-equal? status allowed)
          status
          (error description status)))

    (define (next-sequence! store)
      "Increment STORE's sequence and return the new value."
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        next))

    (define (generated-id prefix sequence)
      "Convert PREFIX and SEQUENCE into a generated id."
      (string->symbol
       (string-append prefix "-" (number->string sequence))))

    (define (integer-datum sequence)
      "Return SEQUENCE as an Consent Scheme exact integer datum."
      (consent-make-canonical-integer sequence))

    (define (field-value datum name)
      "Return field NAME from DATUM or #f."
      (let loop ((fields (if (and (pair? datum) (eq? (car datum) 'plan))
                             (cdr datum)
                             datum)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) name))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    (define (payload-fields datum)
      "Return DATUM's plan payload fields."
      (if (and (pair? datum) (eq? (car datum) 'plan))
          (cdr datum)
          datum))

    (define (plan-field name value)
      "Return FIELD with NAME and VALUE."
      (list name value))

    (define (replace-field record name value)
      "Return RECORD with field NAME replaced by VALUE."
      (cons
       (car record)
       (map (lambda (field)
              (if (and (pair? field) (eq? (car field) name))
                  (plan-field name value)
                  field))
            (cdr record))))

    (define (touch-plan store record)
      "Return RECORD with refreshed updated-at sequence."
      (replace-field record 'updated-at (integer-datum (next-sequence! store))))

    (define (plan-record-id record)
      "Return canonical id field from a plan RECORD."
      #((parameters
         (record (type plan)
          (description "Plan record datum.")))
        (returns (type symbol)
         (description "The plan id field."))
        (effects pure))
      (field-value record 'id))

    (define (plan-record-scope record)
      "Return RECORD's scope field."
      #((parameters
         (record (type plan)
          (description "Plan record datum.")))
        (returns (type symbol)
         (description "The plan scope field."))
        (effects pure))
      (field-value record 'scope))

    (define (plan-record-steps record)
      "Return RECORD's step list."
      #((parameters
         (record (type plan)
          (description "Plan record datum.")))
        (returns (type (list-of plan-step))
         (description "The list of plan step datums, or the empty list."))
        (effects pure))
      (let ((steps (field-value record 'steps)))
        (if steps steps '())))

    (define (plan-step-id step)
      "Return STEP's id field."
      #((parameters
         (step (type plan-step)
          (description "Plan step datum.")))
        (returns (type symbol)
         (description "The step id field."))
        (effects pure))
      (field-value step 'id))

    (define (plan-step-status step)
      "Return STEP's status field."
      #((parameters
         (step (type plan-step)
          (description "Plan step datum.")))
        (returns (type symbol)
         (description "The step status field."))
        (effects pure))
      (field-value step 'status))

    (define (plan-memory-important? datum)
      "Return #t when DATUM requests memory summarization."
      #((parameters
         (datum (type list)
          (description "Plan payload or field list to inspect.")))
        (returns (type boolean)
         (description
          ("#t when DATUM marks memory as important, persist, or"
            "summary; otherwise #f.")))
        (effects pure))
      (let ((memory (field-value (payload-fields datum) 'memory)))
        (or (eq? memory 'important)
            (eq? memory 'persist)
            (eq? memory 'summary))))

    (define (scope-records store scope)
      "Return records from STORE belonging to SCOPE, newest first."
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((eq? (field-value (car records) 'scope) normalized-scope)
            (loop (cdr records) (cons (car records) result)))
           (else (loop (cdr records) result))))))

    (define (plan-ref store id)
      "Return a plan record from STORE by ID, or #f."
      #((parameters
         (store (type consent-plan-store)
          (description "Plan store to search."))
         (id (type symbol)
          (description "Plan id symbol.")))
        (returns (type (or plan boolean))
         (description "The matching plan record datum, or #f."))
        (effects state-read))
      (let loop ((records (store-records store)))
        (cond
         ((null? records) #f)
         ((equal? (plan-record-id (car records)) id) (car records))
         (else (loop (cdr records))))))

    (define (plan-list store scope)
      "Return all plans in SCOPE."
      #((parameters
         (store (type consent-plan-store)
          (description "Plan store to inspect."))
         (scope (type symbol)
          (description "Plan scope symbol.")))
        (returns (type (list-of plan))
         (description "Plan record datums in SCOPE, newest first."))
        (effects state-read error))
      (scope-records store scope))

    (define (without-plan store id)
      "Return STORE records with any plan matching ID removed."
      (let loop ((records (store-records store)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((equal? (plan-record-id (car records)) id)
          (loop (cdr records) result))
         (else (loop (cdr records) (cons (car records) result))))))

    (define (normalize-step step generated)
      "Return STEP in canonical field order."
      (let* ((fields (payload-fields step))
             (id (let ((field (field-value fields 'id)))
                   (if field field generated)))
             (status (normalize-status
                      (let ((field (field-value fields 'status)))
                        (if field field 'pending))
                      consent-plan-step-statuses
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

    (define (normalize-steps steps)
      "Return STEPS as a canonical list of step datums."
      (map (lambda (step) (normalize-step step #f))
           (if steps steps '())))

    (define (make-plan-record store datum existing)
      "Build a canonical Scheme-readable plan record."
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
                      consent-plan-statuses
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

    (define (plan-create! store datum)
      "Create or replace a plan from DATUM and return its canonical record."
      #((parameters
         (store (type consent-plan-store)
          (description "Plan store to mutate."))
         (datum (type list)
          (description ("Plan payload or field list as Scheme-readable data."))))
        (returns (type plan)
         (description "The created or replaced plan record datum."))
        (effects state-write error))
      (let* ((id (field-value (payload-fields datum) 'id))
             (existing (and id (plan-ref store id)))
             (record (make-plan-record store datum existing)))
        (set-store-records!
         store
         (cons record (without-plan store (plan-record-id record))))
        record))

    (define (plan-step-add! store id step-datum)
      "Add STEP-DATUM to plan ID and return the updated plan."
      #((parameters
         (store (type consent-plan-store)
          (description "Plan store to mutate."))
         (id (type symbol)
          (description "Plan id symbol."))
         (step-datum (type list)
          (description ("Step payload or field list as Scheme-readable data."))))
        (returns (type plan)
         (description "The updated plan record datum."))
        (effects state-write error))
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

    (define (plan-step-status! store id step-id status)
      "Set plan ID step STEP-ID to STATUS and return the updated plan."
      #((parameters
         (store (type consent-plan-store)
          (description "Plan store to mutate."))
         (id (type symbol)
          (description "Plan id symbol."))
         (step-id (type symbol)
          (description "Step id symbol."))
         (status (type symbol)
          (description "Step status symbol.")))
        (returns (type plan)
         (description "The updated plan record datum."))
        (effects state-write error))
      (let ((record (plan-ref store id))
            (normalized-status
             (normalize-status status
                               consent-plan-step-statuses
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

    (define (plan-status! store id status)
      "Set plan ID to STATUS and return the updated plan."
      #((parameters
         (store (type consent-plan-store)
          (description "Plan store to mutate."))
         (id (type symbol)
          (description "Plan id symbol."))
         (status (type symbol)
          (description "Plan status symbol.")))
        (returns (type plan)
         (description "The updated plan record datum."))
        (effects state-write error))
      (let ((record (plan-ref store id))
            (normalized-status
             (normalize-status status
                               consent-plan-statuses
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
