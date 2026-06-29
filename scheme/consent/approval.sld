;;; Portable Consent Scheme approval request records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral approval request datums.  Host adapters own
;;; display, persistence, and authority to resolve gated effects.

(define-library (consent approval)
  (export consent-approval-statuses
          consent-make-approval-store
          consent-approval-store?
          approval-request!
          approval-status
          approval-ref
          approval-resolve!
          approval-cancel!
          approval-pending)
  (import (scheme base))
  (begin
    ;; Public approval statuses are Scheme data visible to agents and hosts.
    (define consent-approval-statuses
      '(pending approved denied canceled))

    ;; Mutable approval store for portable interpreter state.
    (define-record-type <consent-approval-store>
      (make-approval-store records next-id)
      consent-approval-store?
      (records store-records set-store-records!)
      (next-id store-next-id set-store-next-id!))

    (define (consent-make-approval-store)
      "Construct an empty approval store."
      #((parameters)
        (returns
         (type consent-approval-store)
         (description
          ("A mutable approval store with no records and the next"
            "generated id set to zero.")))
        (effects allocation))
      (make-approval-store '() 0))

    (define (member-eq? value list)
      "Report whether VALUE is in LIST using eq?."
      (cond
       ((null? list) #f)
       ((eq? value (car list)) #t)
       (else (member-eq? value (cdr list)))))

    (define (normalize-status status)
      "Validate and return STATUS."
      (if (member-eq? status consent-approval-statuses)
          status
          (error "unknown approval status" status)))

    (define (generated-id store)
      "Generate a fresh approval id in STORE."
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        (string->symbol
         (string-append "a-" (number->string next)))))

    (define (field-value datum name)
      "Return field NAME from approval DATUM, or #f."
      (let loop ((fields (if (and (pair? datum)
                                  (eq? (car datum) 'approval-request))
                             (cdr datum)
                             datum)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) name))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    (define (optional-field name value)
      "Build an optional FIELD list from VALUE."
      (if value
          (list (list name value))
          '()))

    (define (make-approval-record store datum)
      "Return a canonical approval request record for DATUM."
      (let ((id (generated-id store)))
        (append
         (list 'approval-request
               (list 'id id)
               (list 'policy (let ((policy (field-value datum 'policy)))
                                (if policy policy 'manual)))
               (list 'effect (let ((effect (field-value datum 'effect)))
                                (if effect effect datum))))
         (optional-field 'operation (field-value datum 'operation))
         (optional-field 'reason (field-value datum 'reason))
         (list (list 'status 'pending)))))

    (define (record-id record)
      "Return RECORD's id field."
      (field-value record 'id))

    (define (record-status record)
      "Return RECORD's status field."
      (field-value record 'status))

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

    (define (approval-ref store id)
      "Return approval record ID from STORE, or #f."
      #((parameters
         (store
          (type consent-approval-store)
          (description "Approval store to search."))
         (id
          (type symbol)
          (description "Approval request id symbol.")))
        (returns
         (type (or approval-request boolean))
         (description
          ("The matching approval request datum, or #f when ID is"
            "unknown.")))
        (effects state-read))
      (let loop ((records (store-records store)))
        (cond
         ((null? records) #f)
         ((eq? (record-id (car records)) id) (car records))
         (else (loop (cdr records))))))

    (define (approval-request! store datum)
      "Create an approval request from DATUM in STORE and return its id."
      #((parameters
         (store
          (type consent-approval-store)
          (description "Approval store to mutate."))
         (datum
          . ("Requested effect or approval payload as Scheme-readable"
             "data.")))
        (returns
         (type symbol)
         (description "The generated approval id symbol."))
        (effects state-write))
      (let ((record (make-approval-record store datum)))
        (store-record! store record)
        (record-id record)))

    (define (approval-status store id)
      "Return approval ID status from STORE, or #f."
      #((parameters
         (store
          (type consent-approval-store)
          (description "Approval store to search."))
         (id
          (type symbol)
          (description "Approval request id symbol.")))
        (returns
         (type (or symbol boolean))
         (description ("The approval status symbol, or #f when ID is unknown.")))
        (effects state-read))
      (let ((record (approval-ref store id)))
        (if record (record-status record) #f)))

    (define (record-with-status record status)
      "Replace RECORD's status field with STATUS."
      (let loop ((fields (cdr record)) (result '()))
        (cond
         ((null? fields)
          (cons 'approval-request
                (reverse result)))
         ((eq? (caar fields) 'status)
          (loop (cdr fields)
                (cons (list 'status status) result)))
         (else
          (loop (cdr fields) (cons (car fields) result))))))

    (define (approval-resolve! store id decision)
      "Resolve approval ID in STORE with DECISION and return the record."
      #((parameters
         (store
          (type consent-approval-store)
          (description "Approval store to mutate."))
         (id
          (type symbol)
          (description "Approval request id symbol."))
         (decision
          (type symbol)
          (description "Resolution status, either approved or denied.")))
        (returns
         (type approval-request)
         (description "The resolved approval request datum."))
        (effects state-write error))
      (let ((status (normalize-status decision))
            (record (approval-ref store id)))
        (if (not (or (eq? status 'approved) (eq? status 'denied)))
            (error "approval decisions must be approved or denied" decision))
        (if (not record)
            (error "unknown approval id" id))
        (store-record! store (record-with-status record status))))

    (define (approval-cancel! store id)
      "Cancel approval ID in STORE and return the record."
      #((parameters
         (store
          (type consent-approval-store)
          (description "Approval store to mutate."))
         (id
          (type symbol)
          (description "Approval request id symbol.")))
        (returns
         (type approval-request)
         (description "The canceled approval request datum."))
        (effects state-write error))
      (let ((record (approval-ref store id)))
        (if (not record)
            (error "unknown approval id" id))
        (if (not (eq? (record-status record) 'pending))
            (error "only pending approvals can be canceled" id))
        (store-record! store (record-with-status record 'canceled))))

    (define (approval-pending store)
      "Return pending approval records in creation order."
      #((parameters
         (store
          (type consent-approval-store)
          (description "Approval store to inspect.")))
        (returns
         (type (list-of approval-request))
         (description ("List of approval request datums whose status is pending.")))
        (effects state-read))
      (let loop ((records (store-records store)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((eq? (record-status (car records)) 'pending)
          (loop (cdr records) (cons (car records) result)))
         (else
          (loop (cdr records) result)))))))
