;;; Portable Consent Scheme inspectable memory records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral scoped memory records as Scheme-readable
;;; datums.  Persistence, indexes, and UI buffers are adapter concerns that can
;;; be rebuilt from these canonical records.

(define-library (agent memory)
  (export consent-memory-scopes
          consent-make-memory-store
          consent-memory-store?
          memory-store-put!
          memory-store-ref
          memory-store-delete!
          memory-store-add!
          memory-store-find
          memory-store-by-tag
          memory-store-recent
          memory-store-records
          memory-store-replace-records!
          memory-storage-rules
          memory-scope-datum
          memory-scope-datum-records
          memory-record-id)
  (import (scheme base)
          (only (stdlib list) filter find remove take)
          (scheme write))
  (cond-expand
   ((library (consent reader))
    (import (only (consent reader)
                  consent-make-canonical-integer
                  consent-number?
                  consent-number-exactness
                  consent-number-kind
                  consent-number-value))
     (begin
       (define (integer-datum sequence)
         "Return SEQUENCE as an Consent Scheme exact integer datum."
         (consent-make-canonical-integer sequence))

       (define (integer-value value)
         "Return VALUE as a host integer for memory count arguments."
         (cond
          ((integer? value) value)
          ((and (consent-number? value)
                (eq? (consent-number-kind value) 'integer)
                (eq? (consent-number-exactness value) 'exact))
           (consent-number-value value))
          (else
           (error "memory count must be an exact integer" value))))))
   (else
    (begin
      (define (integer-datum sequence)
        "Return SEQUENCE as an exact integer datum."
        sequence)

      (define (integer-value value)
        "Validate and return VALUE for memory count arguments."
        (if (integer? value)
            value
            (error "memory count must be an exact integer" value))))))
  (begin
    ;; Public memory scopes mirror the Consent Scheme architecture document.
    (define consent-memory-scopes
      '(instance session project))

    ;; Mutable portable memory store for host-neutral tests and interpreter
    ;; primitives.  Records remain canonical datums in the records field.
    (define-record-type <consent-memory-store>
      (make-memory-store records next-id)
      consent-memory-store?
      (records store-records set-store-records!)
      (next-id store-next-id set-store-next-id!))

    (define (consent-make-memory-store)
      "Construct an empty memory store."
      #((parameters)
        (returns (type consent-memory-store)
         (description
          ("A mutable memory store with no records and the next"
            "generated id set to zero.")))
        (effects allocation))
      (make-memory-store '() 0))

    (define (member-equal? value list)
      "Report whether VALUE appears in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (if (member-equal? scope consent-memory-scopes)
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
      #((parameters
         (record (type list)
          (description "Memory record datum.")))
        (returns (type symbol)
         (description "The record id field."))
        (effects pure))
      (field-value record 'id))

    (define (memory-scope-datum-records datum)
      "Return the records field from an agent-memory scope DATUM."
      #((parameters
         (datum (type list)
          (description "Agent memory scope datum.")))
        (returns (type list)
         (description "The scope datum's memory records."))
        (effects pure error))
      (let ((records (field-value datum 'records)))
        (if records
            records
            (error "memory scope datum must contain records"))))

    (define (memory-record-key record)
      "Return RECORD's key field."
      (field-value record 'key))

    (define (memory-record-tags record)
      "Return RECORD's tags field."
      (let ((tags (field-value record 'tags)))
        (if tags tags '())))

    (define (memory-record-sequence record)
      "Return RECORD's highest timestamp sequence, or zero when absent."
      (max
       (let ((created-at (field-value record 'created-at)))
         (if created-at (integer-value created-at) 0))
       (let ((updated-at (field-value record 'updated-at)))
         (if updated-at (integer-value updated-at) 0))))

    (define (memory-records-next-id records)
      "Return the next-id floor implied by RECORDS."
      (let loop ((rest records) (highest 0))
        (if (null? rest)
            highest
            (loop (cdr rest)
                  (max highest (memory-record-sequence (car rest)))))))

    (define (memory-store-records store)
      "Return STORE's canonical records, newest first."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect.")))
        (returns (type list)
         (description "Canonical memory records in newest-first order."))
        (effects state-read))
      (store-records store))

    (define (memory-store-replace-records! store records)
      "Replace STORE's records and reset its generated id sequence."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (records (type list)
          (description "Canonical memory records in newest-first order.")))
        (returns (type list)
         (description "The installed record list."))
        (effects state-write error))
      (set-store-records! store records)
      (set-store-next-id! store (memory-records-next-id records))
      records)

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
        (filter
         (lambda (record)
           (eq? (field-value record 'scope) normalized-scope))
         (store-records store))))

    (define (memory-store-ref store scope key)
      "Return a memory record from STORE by SCOPE and KEY, or #f."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to search."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (key . "Memory key datum."))
        (returns (type (or list boolean))
         (description "The matching memory record datum, or #f."))
        (effects state-read error))
      (find
       (lambda (record)
         (equal? (memory-record-key record) key))
       (scope-records store scope)))

    (define (without-record store scope key)
      "Return STORE records with any record matching KEY in SCOPE removed."
      (let ((normalized-scope (normalize-scope scope)))
        (remove
         (lambda (record)
           (and (eq? (field-value record 'scope) normalized-scope)
                (equal? (memory-record-key record) key)))
         (store-records store))))

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

    (define (memory-store-put! store scope key datum)
      "Store DATUM under KEY in SCOPE and return its memory record."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (key . "Memory key datum.")
         (datum (type list)
          (description ("Memory payload or field list as Scheme-readable data."))))
        (returns (type list)
         (description "The stored memory record datum."))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (existing (memory-store-ref store normalized-scope key))
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

    (define (memory-store-delete! store scope key)
      "Delete memory KEY in SCOPE and return the deleted record, or #f."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (key . "Memory key datum."))
        (returns (type (or list boolean))
         (description
          ("The deleted memory record datum, or #f when no record"
            "matched.")))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (record (memory-store-ref store normalized-scope key)))
        (if record
            (set-store-records!
             store
             (without-record store normalized-scope key)))
        record))

    (define (memory-store-add! store scope kind datum)
      "Add DATUM as generated KIND memory in SCOPE and return the record."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (kind (type symbol)
          (description "Memory kind symbol."))
         (datum (type list)
          (description ("Memory payload or field list as Scheme-readable data."))))
        (returns (type list)
         (description "The generated memory record datum."))
        (effects state-write error))
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

    (define (memory-store-find store scope query)
      "Return SCOPE records matching QUERY."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (query . "Query datum matched against records."))
        (returns (type (list-of list))
         (description "List of matching memory record datums in SCOPE."))
        (effects state-read error))
      (filter
       (lambda (record)
         (record-matches? record query))
       (scope-records store scope)))

    (define (memory-store-by-tag store scope tag)
      "Return SCOPE records tagged with TAG."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (tag . "Tag datum to match."))
        (returns (type (list-of list))
         (description "List of memory record datums whose tags include TAG."))
        (effects state-read error))
      (filter
       (lambda (record)
         (member-equal? tag (memory-record-tags record)))
       (scope-records store scope)))

    (define (memory-store-recent store scope count)
      "Return COUNT newest memory records in SCOPE."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (count (type exact-integer)
          (description
           ("Exact nonnegative integer or Consent Scheme integer datum"
             "limiting result size."))))
        (returns (type (list-of list))
         (description "At most COUNT newest memory record datums in SCOPE."))
        (effects state-read error))
      (let* ((records (scope-records store scope))
             (limit (integer-value count)))
        (if (<= limit 0)
            '()
            (take records (min limit (length records))))))

    (define (memory-storage-rules scope private-file project-root tracked-file
                                  tracked-enabled)
      "Return safe public storage rules for SCOPE."
      #((parameters
         (scope (type symbol)
          (description "Memory scope symbol."))
         (private-file (type string)
          (description "Private-local persistence path."))
         (project-root (type (or string boolean))
          (description "Project root for project scope, or #f."))
         (tracked-file (type (or string boolean))
          (description "Tracked project memory file, or #f."))
         (tracked-enabled (type boolean)
          (description "Whether tracked project memory is enabled.")))
        (returns (type list)
         (description "Public memory-storage rule datum."))
        (effects pure error))
      (append
       (list 'memory-storage
             (list 'scope (normalize-scope scope))
             (list 'mode 'private-local)
             (list 'private-file private-file))
       (if project-root
           (list
            (list 'project-root project-root)
            (list 'tracked-file tracked-file)
            (list 'tracked-enabled tracked-enabled)
            (list 'public-repository-safe #t))
           '())))

    (define (memory-scope-datum scope subject storage records)
      "Return inspectable agent-memory SCOPE datum."
      #((parameters
         (scope (type symbol)
          (description "Memory scope symbol."))
         (subject (type (or symbol boolean))
          (description "Session id for session scope, or #f."))
         (storage (type (or list boolean))
          (description "Storage rules for project scope, or #f."))
         (records (type list)
          (description "Canonical memory records for SCOPE.")))
        (returns (type list)
         (description "Inspectable agent-memory scope datum."))
        (effects pure error))
      (let ((normalized-scope (normalize-scope scope)))
        (append
         (list 'agent-memory
               (list 'scope normalized-scope))
         (cond
          ((and (eq? normalized-scope 'session) subject)
           (list (list 'session subject)))
          ((and (eq? normalized-scope 'project) storage)
           (list (list 'storage storage)))
          (else '()))
         (list (list 'records records)))))))
