;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; Portable Agent Scheme inspectable memory records.
;;;
;;; This library owns host-neutral scoped memory records as Scheme-readable
;;; datums.  Persistence, indexes, and UI buffers are adapter concerns that can
;;; be rebuilt from these canonical records.

(define-library (agent-scheme memory)
  (export agent-scheme-memory-scopes
          agent-scheme-make-memory-store
          agent-scheme-memory-store?
          memory-put!
          memory-ref
          memory-delete!
          memory-add!
          memory-find
          memory-by-tag
          memory-recent
          memory-record-id)
  (import (scheme base)
          (agent-scheme reader)
          (scheme write))
  (begin
    ;; Public memory scopes mirror the Agent Scheme architecture document.
    (define agent-scheme-memory-scopes
      '(instance session project))

    ;; Mutable portable memory store for host-neutral tests and interpreter
    ;; primitives.  Records remain canonical datums in the records field.
    (define-record-type <agent-scheme-memory-store>
      (make-memory-store records next-id)
      agent-scheme-memory-store?
      (records store-records set-store-records!)
      (next-id store-next-id set-store-next-id!))

    (define (agent-scheme-make-memory-store)
      "Construct an empty memory store."
      #((parameters . ())
        (returns . "A mutable memory store with no records and the next generated id set to zero.")
        (effects . (allocation)))
      (make-memory-store '() 0))

    (define (member-equal? value list)
      "Report whether VALUE appears in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (if (member-equal? scope agent-scheme-memory-scopes)
          scope
          (error "unknown memory scope" scope)))

    (define (next-sequence! store)
      "Increment STORE's sequence and return the new value."
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        next))

    (define (generated-id sequence)
      "Convert SEQUENCE into a generated memory id."
      (string->symbol
       (string-append "m-" (number->string sequence))))

    (define (integer-datum sequence)
      "Return SEQUENCE as an Agent Scheme exact integer datum."
      (agent-scheme-make-canonical-integer sequence))

    (define (integer-value value)
      "Return VALUE as a host integer for memory count arguments."
      (cond
       ((integer? value) value)
       ((and (agent-scheme-number? value)
             (eq? (agent-scheme-number-kind value) 'integer)
             (eq? (agent-scheme-number-exactness value) 'exact))
        (agent-scheme-number-value value))
       (else
        (error "memory count must be an exact integer" value))))

    (define (field-value datum name)
      "Return field NAME from RECORD or payload DATUM, or #f."
      (let loop ((fields (if (and (pair? datum) (eq? (car datum) 'memory))
                             (cdr datum)
                             datum)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) name))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    (define (memory-record-id record)
      "Return canonical id field from a memory RECORD."
      #((parameters . ((record . "Memory record datum.")))
        (returns . "The record id field.")
        (effects . (pure)))
      (field-value record 'id))

    (define (memory-record-key record)
      "Return RECORD's key field."
      (field-value record 'key))

    (define (memory-record-tags record)
      "Return RECORD's tags field."
      (let ((tags (field-value record 'tags)))
        (if tags tags '())))

    (define (datum->string datum)
      "Render DATUM to a string for simple portable substring search."
      (let ((port (open-output-string)))
        (write datum port)
        (get-output-string port)))

    (define (string-contains? haystack needle)
      "Return #t when NEEDLE occurs in HAYSTACK."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (cond
           ((> (+ index needle-length) haystack-length) #f)
           ((string=? (substring haystack index (+ index needle-length))
                      needle)
            #t)
           (else (loop (+ index 1)))))))

    (define (scope-records store scope)
      "Return records from STORE belonging to SCOPE, newest first."
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((eq? (field-value (car records) 'scope) normalized-scope)
            (loop (cdr records) (cons (car records) result)))
           (else (loop (cdr records) result))))))

    (define (memory-ref store scope key)
      "Return a memory record from STORE by SCOPE and KEY, or #f."
      #((parameters . ((store . "Memory store to search.")
                       (scope . "Memory scope symbol.")
                       (key . "Memory key datum.")))
        (returns . "The matching memory record datum, or #f.")
        (effects . (state-read error)))
      (let loop ((records (scope-records store scope)))
        (cond
         ((null? records) #f)
         ((equal? (memory-record-key (car records)) key) (car records))
         (else (loop (cdr records))))))

    (define (without-record store scope key)
      "Return STORE records with any record matching KEY in SCOPE removed."
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((and (eq? (field-value (car records) 'scope) normalized-scope)
                 (equal? (memory-record-key (car records)) key))
            (loop (cdr records) result))
           (else (loop (cdr records) (cons (car records) result)))))))

    (define (make-memory-record store scope key kind datum existing)
      "Build a canonical Scheme-readable memory record."
      (let* ((sequence (next-sequence! store))
             (id (if existing (field-value existing 'id) key))
             (created-at (if existing
                             (field-value existing 'created-at)
                             (integer-datum sequence)))
             (tags (let ((field (field-value datum 'tags)))
                     (if field field '())))
             (value (let ((field (field-value datum 'value)))
                      (if field field datum)))
             (source (let ((field (field-value datum 'source)))
                       (if field field '())))
             (confidence (let ((field (field-value datum 'confidence)))
                           (if field field 'unknown))))
        (list 'memory
              (list 'id id)
              (list 'scope scope)
              (list 'key key)
              (list 'kind kind)
              (list 'tags tags)
              (list 'value value)
              (list 'source source)
              (list 'confidence confidence)
              (list 'created-at created-at)
              (list 'updated-at (integer-datum sequence)))))

    (define (memory-put! store scope key datum)
      "Store DATUM under KEY in SCOPE and return its memory record."
      #((parameters . ((store . "Memory store to mutate.")
                       (scope . "Memory scope symbol.")
                       (key . "Memory key datum.")
                       (datum . "Memory payload or field list as Scheme-readable data.")))
        (returns . "The stored memory record datum.")
        (effects . (state-write error)))
      (let* ((normalized-scope (normalize-scope scope))
             (existing (memory-ref store normalized-scope key))
             (record (make-memory-record store
                                         normalized-scope
                                         key
                                         'datum
                                         datum
                                         existing)))
        (set-store-records!
         store
         (cons record (without-record store normalized-scope key)))
        record))

    (define (memory-delete! store scope key)
      "Delete memory KEY in SCOPE and return the deleted record, or #f."
      #((parameters . ((store . "Memory store to mutate.")
                       (scope . "Memory scope symbol.")
                       (key . "Memory key datum.")))
        (returns . "The deleted memory record datum, or #f when no record matched.")
        (effects . (state-write error)))
      (let* ((normalized-scope (normalize-scope scope))
             (record (memory-ref store normalized-scope key)))
        (if record
            (set-store-records!
             store
             (without-record store normalized-scope key)))
        record))

    (define (memory-add! store scope kind datum)
      "Add DATUM as generated KIND memory in SCOPE and return the record."
      #((parameters . ((store . "Memory store to mutate.")
                       (scope . "Memory scope symbol.")
                       (kind . "Memory kind symbol.")
                       (datum . "Memory payload or field list as Scheme-readable data.")))
        (returns . "The generated memory record datum.")
        (effects . (state-write error)))
      (let* ((normalized-scope (normalize-scope scope))
             (sequence (+ (store-next-id store) 1))
             (id (generated-id sequence))
             (record (make-memory-record store
                                         normalized-scope
                                         id
                                         kind
                                         datum
                                         #f)))
        (set-store-records! store (cons record (store-records store)))
        record))

    (define (record-matches? record query)
      "Report whether RECORD matches QUERY."
      (cond
       ((string? query)
        (string-contains? (datum->string record) query))
       ((symbol? query)
        (or (eq? query (field-value record 'kind))
            (equal? query (field-value record 'key))
            (member-equal? query (memory-record-tags record))
            (string-contains? (datum->string record)
                              (symbol->string query))))
       (else (equal? query record))))

    (define (memory-find store scope query)
      "Return SCOPE records matching QUERY."
      #((parameters . ((store . "Memory store to inspect.")
                       (scope . "Memory scope symbol.")
                       (query . "String, symbol, or datum query matched against records.")))
        (returns . "List of matching memory record datums in SCOPE.")
        (effects . (state-read error)))
      (let loop ((records (scope-records store scope)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((record-matches? (car records) query)
          (loop (cdr records) (cons (car records) result)))
         (else (loop (cdr records) result)))))

    (define (memory-by-tag store scope tag)
      "Return SCOPE records tagged with TAG."
      #((parameters . ((store . "Memory store to inspect.")
                       (scope . "Memory scope symbol.")
                       (tag . "Tag symbol or datum to match.")))
        (returns . "List of memory record datums whose tags include TAG.")
        (effects . (state-read error)))
      (let loop ((records (scope-records store scope)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((member-equal? tag (memory-record-tags (car records)))
          (loop (cdr records) (cons (car records) result)))
         (else (loop (cdr records) result)))))

    (define (take records count)
      "Return the first COUNT records from RECORDS."
      (if (or (<= count 0) (null? records))
          '()
          (cons (car records) (take (cdr records) (- count 1)))))

    (define (memory-recent store scope count)
      "Return COUNT newest memory records in SCOPE."
      #((parameters . ((store . "Memory store to inspect.")
                       (scope . "Memory scope symbol.")
                       (count . "Exact nonnegative integer or Agent Scheme integer datum limiting result size.")))
        (returns . "At most COUNT newest memory record datums in SCOPE.")
        (effects . (state-read error)))
      (take (scope-records store scope) (integer-value count)))))
