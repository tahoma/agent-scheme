;;; Portable Consent Scheme inspectable memory records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral scoped memory records as Scheme-readable
;;; datums.  Persistence, indexes, and UI buffers are adapter concerns that can
;;; be rebuilt from these canonical records.

(define-library (agent memory)
  (export consent-memory-scopes
          consent-memory-classes
          consent-make-memory-store
          consent-memory-store?
          memory-store-put!
          memory-store-ref
          memory-store-delete!
          memory-store-add!
          memory-store-access!
          memory-store-reflect!
          memory-store-select
          memory-store-find
          memory-store-by-tag
          memory-store-recent
          memory-store-records
          memory-store-replace-records!
          memory-storage-rules
          memory-scope-datum
          memory-scope-datum-records
          memory-record-id
          memory-record-field-value
          memory-record-class
          memory-selection?
          memory-selection-records
          memory-selection-candidates
          memory-selection-cutoff)
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
           (error "memory count must be an exact integer" value))))

       (define (numeric-value value)
         "Return VALUE as a host real number for memory scoring."
         (cond
          ((number? value) value)
          ((and (consent-number? value)
                (eq? (consent-number-kind value) 'integer))
           (consent-number-value value))
          ((and (consent-number? value)
                (eq? (consent-number-kind value) 'rational))
           (let ((pair (consent-number-value value)))
             (/ (car pair) (cdr pair))))
          (else
           (error "memory score must be numeric" value))))

       (define (memory-number? value)
         "Return #t when VALUE is a host or Consent number."
         (or (number? value) (consent-number? value)))))
   (else
    (begin
      (define (integer-datum sequence)
        "Return SEQUENCE as an exact integer datum."
        sequence)

      (define (integer-value value)
        "Validate and return VALUE for memory count arguments."
        (if (integer? value)
            value
            (error "memory count must be an exact integer" value)))

      (define (numeric-value value)
        "Validate and return VALUE for memory scoring."
        (if (number? value)
            value
            (error "memory score must be numeric" value)))

      (define (memory-number? value)
        "Return #t when VALUE is a host number."
        (number? value)))))
  (begin
    ;; Public memory scopes mirror the Consent Scheme architecture document.
    (define consent-memory-scopes
      '(instance session project))

    ;; Public memory classes reconcile CoALA-style memory taxonomy with one
    ;; append-only record stream.
    (define consent-memory-classes
      '(working episodic semantic procedural))

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

    (define (field-value/default datum name default)
      "Return field NAME from DATUM, or DEFAULT when NAME is absent."
      (let loop ((fields (if (and (pair? datum)
                                  (symbol? (car datum))
                                  (not (and (pair? (car datum))
                                            (symbol? (caar datum)))))
                             (cdr datum)
                             datum)))
        (cond
         ((null? fields) default)
         ((and (pair? (car fields))
               (eq? (caar fields) name))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    (define (memory-record-field-value record name . maybe-default)
      "Return field NAME from RECORD, or DEFAULT when absent."
      #((parameters
         (record (type list)
          (description "Scheme-readable memory or memory-selection record."))
         (name (type symbol)
          (description "Field name to read."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . "The field value, or the fallback when NAME is absent.")
        (effects pure))
      (field-value/default record name
                           (if (null? maybe-default) #f (car maybe-default))))

    (define (normalize-memory-class memory-class)
      "Validate and return MEMORY-CLASS."
      (if (member-equal? memory-class consent-memory-classes)
          memory-class
          (error "unknown memory class" memory-class)))

    (define (default-memory-class kind)
      "Return the default memory class for KIND."
      (cond
       ((eq? kind 'memory-access) 'working)
       ((eq? kind 'memory-tombstone) 'working)
       (else 'semantic)))

    (define (memory-record-class record)
      "Return RECORD's memory-class field."
      #((parameters
         (record (type list)
          (description "Memory record datum.")))
        (returns (type symbol)
         (description "One of the public memory class symbols."))
        (effects pure error))
      (normalize-memory-class
       (field-value/default record 'memory-class
                            (default-memory-class
                             (field-value record 'kind)))))

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

    (define (memory-record-live-key record)
      "Return RECORD's scope-qualified key for live projections."
      (list (field-value record 'scope) (memory-record-key record)))

    (define (memory-record-tags record)
      "Return RECORD's tags field."
      (let ((tags (field-value record 'tags)))
        (if tags tags '())))

    (define (memory-record-kind record)
      "Return RECORD's kind field."
      (field-value record 'kind))

    (define (memory-record-tombstone? record)
      "Return #t when RECORD is a tombstone event."
      (eq? (memory-record-kind record) 'memory-tombstone))

    (define (memory-record-access? record)
      "Return #t when RECORD is a memory-access event."
      (eq? (memory-record-kind record) 'memory-access))

    (define (selectable-memory-record? record)
      "Return #t when RECORD can enter retrieval candidate ranking."
      (and (not (memory-record-tombstone? record))
           (not (memory-record-access? record))))

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
      "Return all canonical records from STORE belonging to SCOPE, newest first."
      (let ((normalized-scope (normalize-scope scope)))
        (filter
         (lambda (record)
           (eq? (field-value record 'scope) normalized-scope))
         (store-records store))))

    (define (live-records records)
      "Return the newest live projection from append-only RECORDS."
      (let loop ((rest records) (seen '()) (selected '()))
        (cond
         ((null? rest) (reverse selected))
         ((not (selectable-memory-record? (car rest)))
          (let ((key (memory-record-live-key (car rest))))
            (if (memory-record-tombstone? (car rest))
                (loop (cdr rest) (cons key seen) selected)
                (loop (cdr rest) seen selected))))
         ((member-equal? (memory-record-live-key (car rest)) seen)
          (loop (cdr rest) seen selected))
         (else
          (loop (cdr rest)
                (cons (memory-record-live-key (car rest)) seen)
                (cons (car rest) selected))))))

    (define (scope-live-records store scope)
      "Return live records from STORE belonging to SCOPE, newest first."
      (live-records (scope-records store scope)))

    (define (all-live-records store)
      "Return all live records from STORE, newest first."
      (live-records (store-records store)))

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
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-records store)))
          (cond
           ((null? records) #f)
           ((not (eq? (field-value (car records) 'scope) normalized-scope))
            (loop (cdr records)))
           ((not (equal? (memory-record-key (car records)) key))
            (loop (cdr records)))
           ((memory-record-tombstone? (car records)) #f)
           ((memory-record-access? (car records)) (loop (cdr records)))
           (else (car records))))))

    (define (without-record store scope key)
      "Return STORE records with any record matching KEY in SCOPE removed."
      (let ((normalized-scope (normalize-scope scope)))
        (remove
         (lambda (record)
           (and (eq? (field-value record 'scope) normalized-scope)
                (equal? (memory-record-key record) key)))
         (store-records store))))

    (define (optional-record-fields datum names)
      "Return optional fields named by NAMES from DATUM."
      (let loop ((rest names) (fields '()))
        (if (null? rest)
            (reverse fields)
            (let ((value (field-value datum (car rest))))
              (loop (cdr rest)
                    (if value
                        (cons (list (car rest) value) fields)
                        fields))))))

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
                           (if field field 'unknown)))
             (memory-class
              (normalize-memory-class
               (let ((field (field-value datum 'memory-class)))
                 (if field field (default-memory-class kind)))))
             (importance
              (let ((field (field-value datum 'importance)))
                (if field field (integer-datum 1)))))
        (append
         (list 'memory
               (list 'id id)
               (list 'scope scope)
               (list 'key key)
               (list 'kind kind)
               (list 'memory-class memory-class)
               (list 'tags tags)
               (list 'value value)
               (list 'source source)
               (list 'confidence confidence)
               (list 'importance importance)
               (list 'created-at created-at)
               (list 'updated-at (integer-datum sequence)))
         (optional-record-fields
          datum
          '(cites supersedes receipt accessed local-only disclosure)))))

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
         (cons record (store-records store)))
        record))

    (define (make-memory-tombstone store scope key record)
      "Build a tombstone event for RECORD."
      (make-memory-record
       store
       scope
       key
       'memory-tombstone
       (list (list 'memory-class 'working)
             (list 'value 'tombstone)
             (list 'source (list 'memory-delete key))
             (list 'confidence 'high)
             (list 'supersedes (list (memory-record-id record))))
       #f))

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
             (cons (make-memory-tombstone store normalized-scope key record)
                   (store-records store))))
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
       (scope-live-records store scope)))

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
       (scope-live-records store scope)))

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
      (let* ((records (scope-live-records store scope))
             (limit (integer-value count)))
        (if (<= limit 0)
            '()
            (take records (min limit (length records))))))

    (define (memory-store-access! store memory-id scope context)
      "Append a logical-clock access event for MEMORY-ID."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (memory-id . "Memory record id that was selected or inspected.")
         (scope (type symbol)
          (description "Memory scope symbol."))
         (context . "Prompt, task, or retrieval context that accessed memory."))
        (returns (type list)
         (description "The appended `memory-access` event record."))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (sequence (+ (store-next-id store) 1))
             (record
              (make-memory-record
               store
               normalized-scope
               (generated-id sequence)
               'memory-access
               (list (list 'memory-class 'working)
                     (list 'tags '(memory-access))
                     (list 'value (list 'accessed memory-id))
                     (list 'source (list 'retrieval context))
                     (list 'confidence 'high)
                     (list 'accessed memory-id))
               #f)))
        (set-store-records! store (cons record (store-records store)))
        record))

    (define (memory-store-reflect! store scope kind datum cites receipt loop-id)
      "Append a gated reflection or synthesis datum with provenance."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to mutate."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (kind (type symbol)
          (description "Reflection or synthesis memory kind."))
         (datum (type list)
          (description "Model-authored reflection payload admitted as data."))
         (cites (type list)
          (description "Base memory ids this insight cites."))
         (receipt (type symbol)
          (description "Task receipt or stop reason that gated the write."))
         (loop-id . "Deterministic loop step id admitting the reflection."))
        (returns (type list)
         (description "The appended reflection memory record."))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (sequence (+ (store-next-id store) 1))
             (record
              (make-memory-record
               store
               normalized-scope
               (generated-id sequence)
               kind
               (append
                (list (list 'memory-class 'semantic)
                      (list 'source (list 'deterministic-loop loop-id))
                      (list 'cites cites)
                      (list 'receipt receipt))
                datum)
               #f)))
        (set-store-records! store (cons record (store-records store)))
        record))

    (define (tagged-record? datum tag)
      "Return #t when DATUM is a tagged list with TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (contains-tagged? datum tag)
      "Return #t when DATUM recursively contains a tagged TAG record."
      (cond
       ((tagged-record? datum tag) #t)
       ((pair? datum)
        (or (contains-tagged? (car datum) tag)
            (contains-tagged? (cdr datum) tag)))
       ((vector? datum)
        (let loop ((index 0))
          (cond
           ((= index (vector-length datum)) #f)
           ((contains-tagged? (vector-ref datum index) tag) #t)
           (else (loop (+ index 1))))))
       (else #f)))

    (define (truthy-field? datum name)
      "Return #t when DATUM field NAME is present and not #f."
      (let ((value (field-value/default datum name #f)))
        (and value #t)))

    (define (redaction-sensitive? record)
      "Return #t when RECORD carries redacted or local-only content."
      (or (truthy-field? record 'local-only)
          (contains-tagged? record 'local-only)
          (contains-tagged? record 'redaction)))

    (define (lower-trust? trust)
      "Return #t when TRUST names a lower-trust prompt boundary."
      (or (eq? trust 'remote)
          (eq? trust 'public)
          (eq? trust 'lower-trust)))

    (define (weight-ref weights name default)
      "Return NAME's weight from WEIGHTS, or DEFAULT."
      (let ((entry (assq name weights)))
        (if (and entry (pair? (cdr entry)))
            (numeric-value (cadr entry))
            default)))

    (define (policy-field policy name default)
      "Return POLICY field NAME, or DEFAULT."
      (field-value/default policy name default))

    (define (context-field context name default)
      "Return CONTEXT field NAME, or DEFAULT."
      (field-value/default context name default))

    (define (pow2 exponent)
      "Return 2 raised to nonnegative integer EXPONENT."
      (let loop ((remaining exponent) (result 1))
        (if (<= remaining 0)
            result
            (loop (- remaining 1) (* result 2)))))

    (define (record-access-sequence records record)
      "Return highest memory-access sequence for RECORD in RECORDS."
      (let loop ((rest records) (highest 0))
        (cond
         ((null? rest) highest)
         ((and (memory-record-access? (car rest))
               (eq? (field-value (car rest) 'scope)
                    (field-value record 'scope))
               (equal? (field-value (car rest) 'accessed)
                       (memory-record-id record)))
          (loop (cdr rest)
                (max highest (memory-record-sequence (car rest)))))
         (else (loop (cdr rest) highest)))))

    (define (recency-score records logical-clock record)
      "Return exact recency score for RECORD at LOGICAL-CLOCK."
      (let* ((record-sequence (memory-record-sequence record))
             (access-sequence
              (record-access-sequence records record))
             (latest (max record-sequence access-sequence))
             (age (max 0 (- logical-clock latest))))
        (/ 1 (pow2 age))))

    (define (importance-score record)
      "Return RECORD's effective importance score."
      (let ((importance (field-value/default record 'importance 1)))
        (cond
         ((memory-number? importance)
          (numeric-value importance))
         ((pair? importance)
          (numeric-value
           (field-value/default importance
                                'effective
                                (field-value/default importance 'proposed 1))))
         (else 1))))

    (define (query-terms query)
      "Return QUERY as a list of relevance terms."
      (if (list? query) query (list query)))

    (define (term-relevant? term record)
      "Return #t when TERM overlaps RECORD tags, key, kind, or text."
      (cond
       ((member-equal? term (memory-record-tags record)) #t)
       ((equal? term (memory-record-key record)) #t)
       ((eq? term (memory-record-kind record)) #t)
       ((string? term) (string-contains? (datum->string record) term))
       ((symbol? term)
        (string-contains? (datum->string record) (symbol->string term)))
       (else #f)))

    (define (relevance-score query record)
      "Return tag/keyword overlap score for QUERY against RECORD."
      (let loop ((terms (query-terms query)) (score 0))
        (cond
         ((null? terms) score)
         ((term-relevant? (car terms) record)
          (loop (cdr terms) (+ score 1)))
         (else (loop (cdr terms) score)))))

    (define (candidate-field candidate name)
      "Return CANDIDATE field NAME."
      (field-value candidate name))

    (define (candidate-score candidate)
      "Return CANDIDATE's score."
      (candidate-field candidate 'score))

    (define (candidate-id candidate)
      "Return CANDIDATE's id."
      (candidate-field candidate 'id))

    (define (score> left right)
      "Return #t when LEFT should sort before RIGHT."
      (let ((left-score (candidate-score left))
            (right-score (candidate-score right)))
        (cond
         ((> left-score right-score) #t)
         ((< left-score right-score) #f)
         (else
          (string<? (symbol->string (candidate-id left))
                    (symbol->string (candidate-id right)))))))

    (define (insert-candidate candidate candidates)
      "Insert CANDIDATE into sorted CANDIDATES."
      (cond
       ((null? candidates) (list candidate))
       ((score> candidate (car candidates))
        (cons candidate candidates))
       (else
        (cons (car candidates)
              (insert-candidate candidate (cdr candidates))))))

    (define (sort-candidates candidates)
      "Return CANDIDATES sorted by score descending, then id."
      (let loop ((rest candidates) (sorted '()))
        (if (null? rest)
            sorted
            (loop (cdr rest) (insert-candidate (car rest) sorted)))))

    (define (candidate-selected? candidate selected)
      "Return #t when CANDIDATE appears in SELECTED."
      (let loop ((rest selected))
        (cond
         ((null? rest) #f)
         ((equal? candidate (car rest)) #t)
         (else (loop (cdr rest))))))

    (define (make-filtered-candidate record reason)
      "Return a filtered memory-selection candidate for RECORD."
      (list 'memory-candidate
            (list 'id (memory-record-id record))
            (list 'status 'filtered)
            (list 'reason reason)
            (list 'score 'not-ranked)
            (list 'subscores '())))

    (define (make-ranked-candidate records query weights logical-clock record)
      "Return a ranked memory-selection candidate for RECORD."
      (let* ((recency (recency-score records logical-clock record))
             (importance (importance-score record))
             (relevance (relevance-score query record))
             (score (+ (* (weight-ref weights 'recency 1) recency)
                       (* (weight-ref weights 'importance 1) importance)
                       (* (weight-ref weights 'relevance 1) relevance))))
        (list 'memory-candidate
              (list 'id (memory-record-id record))
              (list 'record record)
              (list 'status 'ranked)
              (list 'score score)
              (list 'subscores
                    (list (list 'recency recency)
                          (list 'importance importance)
                          (list 'relevance relevance))))))

    (define (finalize-candidate candidate selected)
      "Mark ranked CANDIDATE as selected or below-cutoff."
      (if (not (eq? (candidate-field candidate 'status) 'ranked))
          candidate
          (append
           (list 'memory-candidate
                 (list 'id (candidate-id candidate))
                 (list 'record (candidate-field candidate 'record))
                 (list 'status
                       (if (candidate-selected? candidate selected)
                           'selected
                           'not-selected))
                 (list 'score (candidate-score candidate))
                 (list 'subscores (candidate-field candidate 'subscores)))
           (if (candidate-selected? candidate selected)
               '()
               (list (list 'reason 'below-cutoff-or-limit))))))

    (define (memory-store-select store query policy context)
      "Return a deterministic memory-selection receipt for QUERY."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (query (type (or symbol string list))
          (description "Tag, keyword, or list of relevance terms."))
         (policy (type retrieval-policy)
          (description "Printable retrieval policy record."))
         (context (type retrieval-context)
          (description "Request scope, trust, and logical-clock context.")))
        (returns (type memory-selection)
         (description
          ("A replayable selection receipt with selected records,"
            "per-candidate scores, filter reasons, and the cutoff.")))
        (effects state-read error))
      (let* ((records (store-records store))
             (live (all-live-records store))
             (weights (policy-field policy 'weights '()))
             (cutoff (numeric-value (policy-field policy 'cutoff 0)))
             (limit (integer-value (policy-field policy 'limit (length live))))
             (context-scope (context-field context 'scope 'project))
             (trust (context-field context 'trust 'local))
             (logical-clock
              (integer-value
               (context-field context
                              'logical-clock
                              (memory-records-next-id records))))
             (allowed-scopes
              (context-field context 'allowed-scopes (list context-scope)))
             (candidates
              (map
               (lambda (record)
                 (cond
                  ((not (member-equal? (field-value record 'scope)
                                       allowed-scopes))
                   (make-filtered-candidate record 'scope-mismatch))
                  ((and (lower-trust? trust) (redaction-sensitive? record))
                   (make-filtered-candidate record 'redaction-or-local-only))
                  (else
                   (make-ranked-candidate
                    records query weights logical-clock record))))
               live))
             (eligible
              (filter
               (lambda (candidate)
                 (and (eq? (candidate-field candidate 'status) 'ranked)
                      (>= (candidate-score candidate) cutoff)))
               candidates))
             (selected (take (sort-candidates eligible)
                             (min limit (length eligible))))
             (final-candidates
              (map
               (lambda (candidate)
                 (finalize-candidate candidate selected))
               candidates)))
        (list 'memory-selection
              (list 'query query)
              (list 'policy policy)
              (list 'context context)
              (list 'cutoff cutoff)
              (list 'selected (map candidate-id selected))
              (list 'records
                    (map (lambda (candidate)
                           (candidate-field candidate 'record))
                         selected))
              (list 'candidates final-candidates))))

    (define (memory-selection? datum)
      "Return #t when DATUM is a memory-selection receipt."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description "#t when DATUM is tagged as a memory-selection receipt."))
        (effects pure))
      (tagged-record? datum 'memory-selection))

    (define (memory-selection-records selection)
      "Return selected records from memory-selection SELECTION."
      #((parameters
         (selection (type memory-selection)
          (description "Memory selection receipt.")))
        (returns (type list)
         (description "Selected memory records safe for the request context."))
        (effects pure))
      (field-value/default selection 'records '()))

    (define (memory-selection-candidates selection)
      "Return candidate receipts from memory-selection SELECTION."
      #((parameters
         (selection (type memory-selection)
          (description "Memory selection receipt.")))
        (returns (type list)
         (description "Per-candidate ranking or filtering receipts."))
        (effects pure))
      (field-value/default selection 'candidates '()))

    (define (memory-selection-cutoff selection)
      "Return cutoff from memory-selection SELECTION."
      #((parameters
         (selection (type memory-selection)
          (description "Memory selection receipt.")))
        (returns . "The policy cutoff datum used for selection.")
        (effects pure))
      (field-value/default selection 'cutoff 0))

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
