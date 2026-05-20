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

    ;; Construct an empty memory store.
    (define (agent-scheme-make-memory-store)
      (make-memory-store '() 0))

    ;; Report whether VALUE appears in LIST using equal?.
    (define (member-equal? value list)
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    ;; Validate and return SCOPE.
    (define (normalize-scope scope)
      (if (member-equal? scope agent-scheme-memory-scopes)
          scope
          (error "unknown memory scope" scope)))

    ;; Increment STORE's sequence and return the new value.
    (define (next-sequence! store)
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        next))

    ;; Convert SEQUENCE into a generated memory id.
    (define (generated-id sequence)
      (string->symbol
       (string-append "m-" (number->string sequence))))

    ;; Return SEQUENCE as an Agent Scheme exact integer datum.
    (define (integer-datum sequence)
      (agent-scheme-make-canonical-integer sequence))

    ;; Return VALUE as a host integer for memory count arguments.
    (define (integer-value value)
      (cond
       ((integer? value) value)
       ((and (agent-scheme-number? value)
             (eq? (agent-scheme-number-kind value) 'integer)
             (eq? (agent-scheme-number-exactness value) 'exact))
        (agent-scheme-number-value value))
       (else
        (error "memory count must be an exact integer" value))))

    ;; Return field NAME from RECORD or payload DATUM, or #f.
    (define (field-value datum name)
      (let loop ((fields (if (and (pair? datum) (eq? (car datum) 'memory))
                             (cdr datum)
                             datum)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) name))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    ;; Return canonical id field from a memory RECORD.
    (define (memory-record-id record)
      (field-value record 'id))

    ;; Return RECORD's key field.
    (define (memory-record-key record)
      (field-value record 'key))

    ;; Return RECORD's tags field.
    (define (memory-record-tags record)
      (let ((tags (field-value record 'tags)))
        (if tags tags '())))

    ;; Render DATUM to a string for simple portable substring search.
    (define (datum->string datum)
      (let ((port (open-output-string)))
        (write datum port)
        (get-output-string port)))

    ;; Return #t when NEEDLE occurs in HAYSTACK.
    (define (string-contains? haystack needle)
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (cond
           ((> (+ index needle-length) haystack-length) #f)
           ((string=? (substring haystack index (+ index needle-length))
                      needle)
            #t)
           (else (loop (+ index 1)))))))

    ;; Return records from STORE belonging to SCOPE, newest first.
    (define (scope-records store scope)
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((eq? (field-value (car records) 'scope) normalized-scope)
            (loop (cdr records) (cons (car records) result)))
           (else (loop (cdr records) result))))))

    ;; Return a memory record from STORE by SCOPE and KEY, or #f.
    (define (memory-ref store scope key)
      (let loop ((records (scope-records store scope)))
        (cond
         ((null? records) #f)
         ((equal? (memory-record-key (car records)) key) (car records))
         (else (loop (cdr records))))))

    ;; Return STORE records with any record matching KEY in SCOPE removed.
    (define (without-record store scope key)
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((and (eq? (field-value (car records) 'scope) normalized-scope)
                 (equal? (memory-record-key (car records)) key))
            (loop (cdr records) result))
           (else (loop (cdr records) (cons (car records) result)))))))

    ;; Build a canonical Scheme-readable memory record.
    (define (make-memory-record store scope key kind datum existing)
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

    ;; Store DATUM under KEY in SCOPE and return its memory record.
    (define (memory-put! store scope key datum)
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

    ;; Delete memory KEY in SCOPE and return the deleted record, or #f.
    (define (memory-delete! store scope key)
      (let* ((normalized-scope (normalize-scope scope))
             (record (memory-ref store normalized-scope key)))
        (if record
            (set-store-records!
             store
             (without-record store normalized-scope key)))
        record))

    ;; Add DATUM as generated KIND memory in SCOPE and return the record.
    (define (memory-add! store scope kind datum)
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

    ;; Report whether RECORD matches QUERY.
    (define (record-matches? record query)
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

    ;; Return SCOPE records matching QUERY.
    (define (memory-find store scope query)
      (let loop ((records (scope-records store scope)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((record-matches? (car records) query)
          (loop (cdr records) (cons (car records) result)))
         (else (loop (cdr records) result)))))

    ;; Return SCOPE records tagged with TAG.
    (define (memory-by-tag store scope tag)
      (let loop ((records (scope-records store scope)) (result '()))
        (cond
         ((null? records) (reverse result))
         ((member-equal? tag (memory-record-tags (car records)))
          (loop (cdr records) (cons (car records) result)))
         (else (loop (cdr records) result)))))

    ;; Return the first COUNT records from RECORDS.
    (define (take records count)
      (if (or (<= count 0) (null? records))
          '()
          (cons (car records) (take (cdr records) (- count 1)))))

    ;; Return COUNT newest memory records in SCOPE.
    (define (memory-recent store scope count)
      (take (scope-records store scope) (integer-value count)))))
