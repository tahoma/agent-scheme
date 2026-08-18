;;; R7RS-large and SRFI 125 hash tables.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib hash-table)' directly from the SRFI 125 specification.
;;; The official sample implementation is not vendored because it depends on
;;; SRFI 126, whose distinct R6RS-compatible facade follows this issue.  This
;;; facade delegates storage to `(stdlib hash-table implementation)' so SRFI
;;; 69, SRFI 126, and SRFI 250 can share one engine without conflating APIs.

(define-library (stdlib hash-table)
  (export make-hash-table
          hash-table
          hash-table-unfold
          alist->hash-table
          hash-table?
          hash-table-contains?
          hash-table-exists?
          hash-table-empty?
          hash-table=?
          hash-table-mutable?
          hash-table-ref
          hash-table-ref/default
          hash-table-set!
          hash-table-delete!
          hash-table-intern!
          hash-table-update!
          hash-table-update!/default
          hash-table-pop!
          hash-table-clear!
          hash-table-size
          hash-table-keys
          hash-table-values
          hash-table-entries
          hash-table-find
          hash-table-count
          hash-table-map
          hash-table-for-each
          hash-table-walk
          hash-table-map!
          hash-table-map->list
          hash-table-fold
          hash-table-prune!
          hash-table-copy
          hash-table-empty-copy
          hash-table->alist
          hash-table-union!
          hash-table-merge!
          hash-table-intersection!
          hash-table-difference!
          hash-table-xor!
          hash
          string-hash
          string-ci-hash
          hash-by-identity
          hash-table-equivalence-function
          hash-table-hash-function)
  (import (scheme base)
          (scheme char)
          (rename
           (only (stdlib comparator)
                 comparator?
                 comparator-hashable?
                 comparator-type-test-predicate
                 comparator-equality-predicate
                 comparator-hash-function
                 default-hash
                 string-hash
                 string-ci-hash
                 symbol-hash)
           (default-hash comparator-default-hash)
           (string-hash comparator-string-hash)
           (string-ci-hash comparator-string-ci-hash)
           (symbol-hash comparator-symbol-hash))
          (stdlib hash-table implementation))
  (begin
    ;; Optional facilities that this portable provider cannot implement.
    (define unsupported-options
      '(thread-safe weak-keys ephemeral-keys weak-values ephemeral-values))

    (define (check-options operation options)
      "Validate portable hash-table OPTIONS and return initial capacity."
      (let loop ((rest options) (capacity 0))
        (cond
         ((null? rest) capacity)
         ((memq (car rest) unsupported-options)
          (error "unsupported hash-table option" operation (car rest)))
         ((and (exact-integer? (car rest)) (>= (car rest) 0))
          (loop (cdr rest) (car rest)))
         (else (loop (cdr rest) capacity)))))

    (define (inferred-hash equivalence)
      "Return a standard hash for EQUIVALENCE, or #f."
      (cond
       ((or (eq? equivalence eq?)
            (eq? equivalence eqv?)
            (eq? equivalence equal?))
        comparator-default-hash)
       ((eq? equivalence string=?) comparator-string-hash)
       ((eq? equivalence string-ci=?) comparator-string-ci-hash)
       ((eq? equivalence symbol=?) comparator-symbol-hash)
       (else #f)))

    (define (arguments->policy comparator/equivalence arguments)
      "Return a policy, implementation options, and comparator marker."
      (if (comparator? comparator/equivalence)
          (begin
            (if (not (comparator-hashable? comparator/equivalence))
                (error "hash-table comparator is not hashable"
                       comparator/equivalence))
            (values
             (make-hash-table-policy
              (comparator-type-test-predicate comparator/equivalence)
              (comparator-equality-predicate comparator/equivalence)
              (comparator-hash-function comparator/equivalence)
              comparator/equivalence
              comparator/equivalence)
             arguments))
          (let* ((equivalence comparator/equivalence)
                 (explicit-hash
                  (and (pair? arguments)
                       (procedure? (car arguments))
                       (car arguments)))
                 (options (if explicit-hash (cdr arguments) arguments))
                 (hash-function (or explicit-hash
                                    (inferred-hash equivalence))))
            (if (not (procedure? equivalence))
                (error "hash-table requires comparator or equivalence"
                       comparator/equivalence))
            (if (not hash-function)
                (error "unable to infer hash function" equivalence))
            (values
             (make-hash-table-policy
              (lambda (key) #t)
              equivalence
              hash-function
              equivalence
              #f)
             options))))

    (define (make-storage comparator/equivalence arguments mutable?)
      "Return storage using COMPARATOR/EQUIVALENCE and ARGUMENTS."
      (call-with-values
       (lambda ()
         (arguments->policy comparator/equivalence arguments))
       (lambda (policy options)
         (make-hash-table-storage
          policy (check-options 'make-hash-table options) mutable?))))

    (define (make-hash-table comparator/equivalence . arguments)
      "Return a new mutable SRFI 125 hash table."
      #((parameters
         (comparator/equivalence (type any)
          (description "SRFI 128 comparator or legacy equivalence."))
         (arguments (type list)
          (description "Optional hash function and implementation options.")))
        (returns (type hash-table) (description "New mutable hash table."))
        (effects allocation error procedure-call))
      (make-storage comparator/equivalence arguments #t))

    (define (hash-table comparator . associations)
      "Return an immutable hash table containing ASSOCIATIONS."
      #((parameters
         (comparator (type comparator) (description "Key comparator."))
         (associations (type list)
          (description "Alternating keys and values.")))
        (returns (type hash-table) (description "New immutable hash table."))
        (effects allocation error procedure-call))
      (let ((storage (make-storage comparator '() #t)))
        (let loop ((rest associations))
          (cond
           ((null? rest)
            (hash-table-storage-copy storage #f))
           ((null? (cdr rest))
            (error "hash-table requires key/value pairs" associations))
           ((hash-table-storage-ref-entry storage (car rest))
            (error "hash-table received equivalent keys" (car rest)))
           (else
            (hash-table-storage-set! storage (car rest) (cadr rest))
            (loop (cddr rest)))))))

    (define (hash-table-unfold
             stop? mapper successor seed comparator . arguments)
      "Unfold SEED into a new mutable hash table."
      #((parameters
         (stop? (type procedure) (description "Seed termination predicate."))
         (mapper (type procedure) (description "Key/value producer."))
         (successor (type procedure) (description "Seed successor."))
         (seed (type any) (description "Initial seed."))
         (comparator (type any) (description "Comparator or equivalence."))
         (arguments (type list) (description "Implementation options.")))
        (returns (type hash-table) (description "Unfolded hash table."))
        (effects allocation mutation error procedure-call))
      (let ((storage (apply make-hash-table comparator arguments)))
        (let loop ((seed seed))
          (if (stop? seed)
              storage
              (call-with-values
               (lambda () (mapper seed))
               (lambda (key value)
                 (hash-table-storage-set! storage key value)
                 (loop (successor seed))))))))

    (define (alist->hash-table alist comparator/equivalence . arguments)
      "Return a mutable hash table initialized from ALIST."
      #((parameters
         (alist (type list) (description "Association list."))
         (comparator/equivalence (type any)
          (description "Comparator or legacy equivalence."))
         (arguments (type list)
          (description "Optional hash function and implementation options.")))
        (returns (type hash-table) (description "Initialized hash table."))
        (effects allocation mutation error procedure-call))
      (let ((storage
             (apply make-hash-table comparator/equivalence arguments)))
        (for-each
         (lambda (association)
           (hash-table-storage-set!
            storage (car association) (cdr association)))
         (reverse alist))
        storage))

    (define (hash-table? object)
      "Return #t when OBJECT is a hash table."
      #((parameters (object (type any) (description "Candidate object.")))
        (returns (type boolean) (description "Whether OBJECT is a table."))
        (effects pure))
      (hash-table-storage? object))

    (define (check-table table operation)
      "Return TABLE or signal an OPERATION type error."
      (if (hash-table? table)
          table
          (error "expected hash table" operation table)))

    (define (check-mutable-table table operation)
      "Return TABLE or signal an immutable-table error."
      (check-table table operation)
      (if (not (hash-table-storage-mutable? table))
          (error "immutable hash table" operation table))
      table)

    (define (hash-table-contains? table key)
      "Return whether TABLE contains KEY."
      #((parameters
         (table (type hash-table) (description "Hash table."))
         (key (type any) (description "Candidate key.")))
        (returns (type boolean) (description "Whether KEY is present."))
        (effects error procedure-call))
      (if (hash-table-storage-ref-entry
           (check-table table 'hash-table-contains?) key)
          #t
          #f))

    (define (hash-table-exists? table key)
      "Return whether TABLE contains KEY; deprecated SRFI 69 spelling."
      #((parameters
         (table (type hash-table) (description "Hash table."))
         (key (type any) (description "Candidate key.")))
        (returns (type boolean) (description "Whether KEY is present."))
        (effects error procedure-call))
      (hash-table-contains? table key))

    (define (hash-table-empty? table)
      "Return whether TABLE has no associations."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type boolean) (description "Whether TABLE is empty."))
        (effects error))
      (= 0 (hash-table-storage-size
            (check-table table 'hash-table-empty?))))

    (define (table-ref-entry-if-accepted table key)
      "Return KEY's entry when TABLE's key type accepts KEY, or #f."
      (let ((type-test
             (hash-table-policy-type-test
              (hash-table-storage-policy table))))
        (and (type-test key)
             (hash-table-storage-ref-entry table key))))

    (define (table-entries-match? source target value=?)
      "Return whether every SOURCE association occurs in TARGET."
      (let loop ((entries (hash-table-storage-entries source)))
        (if (null? entries)
            #t
            (let* ((entry (car entries))
                   (other
                    (table-ref-entry-if-accepted
                     target (hash-table-entry-key entry))))
              (and other
                   (value=? (hash-table-entry-value entry)
                            (hash-table-entry-value other))
                   (loop (cdr entries)))))))

    (define (hash-table=? value-comparator left right)
      "Return whether compatible tables LEFT and RIGHT have equal values."
      #((parameters
         (value-comparator (type comparator)
          (description "Comparator for association values."))
         (left (type hash-table) (description "First hash table."))
         (right (type hash-table) (description "Second hash table.")))
        (returns (type boolean) (description "Whether tables are equal."))
        (effects error procedure-call))
      (if (not (comparator? value-comparator))
          (error "expected value comparator" value-comparator))
      (check-table left 'hash-table=?)
      (check-table right 'hash-table=?)
      (let ((value=?
             (comparator-equality-predicate value-comparator)))
        (and
         (= (hash-table-storage-size left)
            (hash-table-storage-size right))
         (table-entries-match? left right value=?)
         (table-entries-match? right left value=?))))

    (define (hash-table-mutable? table)
      "Return whether TABLE permits mutation."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type boolean) (description "Whether TABLE is mutable."))
        (effects error))
      (hash-table-storage-mutable?
       (check-table table 'hash-table-mutable?)))

    (define (hash-table-ref table key . handlers)
      "Return KEY's value in TABLE, with optional failure and success calls."
      #((parameters
         (table (type hash-table) (description "Hash table."))
         (key (type any) (description "Key to find."))
         (handlers (type list)
          (description "Optional failure thunk and success procedure.")))
        (returns (type any) (description "Value or handler result."))
        (effects error procedure-call))
      (if (> (length handlers) 2)
          (error "hash-table-ref received too many handlers" handlers))
      (let ((entry
             (hash-table-storage-ref-entry
              (check-table table 'hash-table-ref) key)))
        (if entry
            (let ((value (hash-table-entry-value entry)))
              (if (and (pair? handlers) (pair? (cdr handlers)))
                  ((cadr handlers) value)
                  value))
            (if (pair? handlers)
                ((car handlers))
                (error "hash-table key not found" table key)))))

    (define (hash-table-ref/default table key default)
      "Return KEY's value in TABLE, or DEFAULT when absent."
      #((parameters
         (table (type hash-table) (description "Hash table."))
         (key (type any) (description "Key to find."))
         (default (type any) (description "Missing-key result.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects error procedure-call))
      (let ((entry
             (hash-table-storage-ref-entry
              (check-table table 'hash-table-ref/default) key)))
        (if entry (hash-table-entry-value entry) default)))

    (define (hash-table-set! table . associations)
      "Set alternating ASSOCIATIONS in mutable TABLE."
      #((parameters
         (table (type hash-table) (description "Mutable hash table."))
         (associations (type list)
          (description "Alternating keys and values.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-set!)
      (let loop ((rest associations))
        (cond
         ((null? rest) #f)
         ((null? (cdr rest))
          (error "hash-table-set! requires key/value pairs" associations))
         (else
          (hash-table-storage-set! table (car rest) (cadr rest))
          (loop (cddr rest))))))

    (define (hash-table-delete! table . keys)
      "Delete KEYS from mutable TABLE and return the number present."
      #((parameters
         (table (type hash-table) (description "Mutable hash table."))
         (keys (type list) (description "Keys to delete.")))
        (returns (type exact-non-negative-integer)
         (description "Number of present keys deleted."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-delete!)
      (let loop ((rest keys) (count 0))
        (if (null? rest)
            count
            (loop (cdr rest)
                  (if (hash-table-storage-delete! table (car rest))
                      (+ count 1)
                      count)))))

    (define (hash-table-intern! table key failure)
      "Return KEY's value, inserting FAILURE's result when absent."
      #((parameters
         (table (type hash-table) (description "Mutable hash table."))
         (key (type any) (description "Association key."))
         (failure (type procedure) (description "Missing-value thunk.")))
        (returns (type any) (description "Existing or inserted value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-intern!)
      (let ((entry (hash-table-storage-ref-entry table key)))
        (if entry
            (hash-table-entry-value entry)
            (let ((value (failure)))
              (hash-table-storage-set! table key value)
              value))))

    (define (hash-table-update! table key updater . handlers)
      "Update KEY in TABLE using UPDATER and optional ref HANDLERS."
      #((parameters
         (table (type hash-table) (description "Mutable hash table."))
         (key (type any) (description "Association key."))
         (updater (type procedure) (description "Value updater."))
         (handlers (type list) (description "Optional ref handlers.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-update!)
      (hash-table-storage-set!
       table key (updater (apply hash-table-ref table key handlers))))

    (define (hash-table-update!/default table key updater default)
      "Update KEY in TABLE, supplying DEFAULT when it is absent."
      #((parameters
         (table (type hash-table) (description "Mutable hash table."))
         (key (type any) (description "Association key."))
         (updater (type procedure) (description "Value updater."))
         (default (type any) (description "Missing-key input.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-update!/default)
      (hash-table-storage-set!
       table key (updater (hash-table-ref/default table key default))))

    (define (hash-table-pop! table)
      "Remove and return an arbitrary association from mutable TABLE."
      #((parameters
         (table (type hash-table) (description "Mutable hash table.")))
        (returns (type values) (description "Removed key and value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-pop!)
      (let ((entry (hash-table-storage-last-entry table)))
        (if (not entry)
            (error "cannot pop an empty hash table" table))
        (let ((key (hash-table-entry-key entry))
              (value (hash-table-entry-value entry)))
          (hash-table-storage-delete! table key)
          (values key value))))

    (define (hash-table-clear! table)
      "Delete every association from mutable TABLE."
      #((parameters
         (table (type hash-table) (description "Mutable hash table.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error))
      (hash-table-storage-clear!
       (check-mutable-table table 'hash-table-clear!)))

    (define (hash-table-size table)
      "Return TABLE's number of associations."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type exact-non-negative-integer)
         (description "Association count."))
        (effects error))
      (hash-table-storage-size (check-table table 'hash-table-size)))

    (define (entries->keys entries)
      "Return ENTRIES' keys."
      (map hash-table-entry-key entries))

    (define (entries->values entries)
      "Return ENTRIES' values."
      (map hash-table-entry-value entries))

    (define (hash-table-keys table)
      "Return a fresh list of TABLE's keys in unspecified order."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type list) (description "Fresh key list."))
        (effects allocation error))
      (entries->keys
       (hash-table-storage-entries
        (check-table table 'hash-table-keys))))

    (define (hash-table-values table)
      "Return a fresh list of TABLE's values in unspecified order."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type list) (description "Fresh value list."))
        (effects allocation error))
      (entries->values
       (hash-table-storage-entries
        (check-table table 'hash-table-values))))

    (define (hash-table-entries table)
      "Return fresh corresponding key and value lists for TABLE."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type values) (description "Key list and value list."))
        (effects allocation error))
      (let ((entries
             (hash-table-storage-entries
              (check-table table 'hash-table-entries))))
        (values (entries->keys entries) (entries->values entries))))

    (define (call-without-table-mutation table procedure arguments operation)
      "Call PROCEDURE with ARGUMENTS and reject mutation of TABLE."
      (let ((version (hash-table-storage-mutation-version table)))
        (let ((result (apply procedure arguments)))
          (if (not (= version
                      (hash-table-storage-mutation-version table)))
              (error "callback mutated hash table" operation table))
          result)))

    (define (hash-table-find procedure table failure)
      "Return the first true PROCEDURE result, or call FAILURE."
      #((parameters
         (procedure (type procedure) (description "Association predicate."))
         (table (type hash-table) (description "Hash table."))
         (failure (type procedure) (description "Failure thunk.")))
        (returns (type any) (description "Predicate or failure result."))
        (effects allocation error procedure-call))
      (check-table table 'hash-table-find)
      (let loop ((entries (hash-table-storage-entries table)))
        (if (null? entries)
            (failure)
            (let* ((entry (car entries))
                   (result
                    (call-without-table-mutation
                     table
                     procedure
                     (list (hash-table-entry-key entry)
                           (hash-table-entry-value entry))
                     'hash-table-find)))
              (if result result (loop (cdr entries)))))))

    (define (hash-table-count predicate table)
      "Return the number of TABLE associations satisfying PREDICATE."
      #((parameters
         (predicate (type procedure) (description "Association predicate."))
         (table (type hash-table) (description "Hash table.")))
        (returns (type exact-non-negative-integer)
         (description "Number of true predicate results."))
        (effects allocation error procedure-call))
      (check-table table 'hash-table-count)
      (let loop ((entries (hash-table-storage-entries table)) (count 0))
        (if (null? entries)
            count
            (let ((entry (car entries)))
              (loop
               (cdr entries)
               (if (call-without-table-mutation
                    table
                    predicate
                    (list (hash-table-entry-key entry)
                          (hash-table-entry-value entry))
                    'hash-table-count)
                   (+ count 1)
                   count))))))

    (define (hash-table-map procedure comparator table)
      "Map PROCEDURE over TABLE's values into a table using COMPARATOR."
      #((parameters
         (procedure (type procedure) (description "Value mapper."))
         (comparator (type comparator) (description "Result key comparator."))
         (table (type hash-table) (description "Source hash table.")))
        (returns (type hash-table) (description "Mapped mutable table."))
        (effects allocation mutation error procedure-call))
      (check-table table 'hash-table-map)
      (let ((result (make-hash-table comparator)))
        (let loop ((entries (hash-table-storage-entries table)))
          (if (null? entries)
              result
              (let ((entry (car entries)))
                (hash-table-storage-set!
                 result
                 (hash-table-entry-key entry)
                 (call-without-table-mutation
                  table
                  procedure
                  (list (hash-table-entry-value entry))
                  'hash-table-map))
                (loop (cdr entries)))))))

    (define (hash-table-for-each procedure table)
      "Call PROCEDURE for every association in TABLE."
      #((parameters
         (procedure (type procedure) (description "Association consumer."))
         (table (type hash-table) (description "Hash table.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects allocation error procedure-call))
      (check-table table 'hash-table-for-each)
      (let loop ((entries (hash-table-storage-entries table)))
        (if (pair? entries)
            (let ((entry (car entries)))
              (call-without-table-mutation
               table
               procedure
               (list (hash-table-entry-key entry)
                     (hash-table-entry-value entry))
               'hash-table-for-each)
              (loop (cdr entries))))))

    (define (hash-table-walk table procedure)
      "Call PROCEDURE for TABLE's associations; deprecated SRFI 69 order."
      #((parameters
         (table (type hash-table) (description "Hash table."))
         (procedure (type procedure) (description "Association consumer.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects allocation error procedure-call))
      (hash-table-for-each procedure table))

    (define (hash-table-map! procedure table)
      "Replace TABLE's values with PROCEDURE's results."
      #((parameters
         (procedure (type procedure) (description "Association mapper."))
         (table (type hash-table) (description "Mutable hash table.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-map!)
      (let loop ((entries (hash-table-storage-entries table)))
        (if (pair? entries)
            (let* ((entry (car entries))
                   (value
                    (call-without-table-mutation
                     table
                     procedure
                     (list (hash-table-entry-key entry)
                           (hash-table-entry-value entry))
                     'hash-table-map!)))
              (hash-table-entry-set-value! entry value)
              (loop (cdr entries))))))

    (define (hash-table-map->list procedure table)
      "Return a list of PROCEDURE results for TABLE's associations."
      #((parameters
         (procedure (type procedure) (description "Association mapper."))
         (table (type hash-table) (description "Hash table.")))
        (returns (type list) (description "Fresh result list."))
        (effects allocation error procedure-call))
      (check-table table 'hash-table-map->list)
      (let loop ((entries (hash-table-storage-entries table)) (result '()))
        (if (null? entries)
            (reverse result)
            (let ((entry (car entries)))
              (loop
               (cdr entries)
               (cons
                (call-without-table-mutation
                 table
                 procedure
                 (list (hash-table-entry-key entry)
                       (hash-table-entry-value entry))
                 'hash-table-map->list)
                result))))))

    (define (hash-table-fold procedure-or-table seed-or-procedure table-or-seed)
      "Fold a hash table, accepting current or deprecated argument order."
      #((parameters
         (procedure-or-table (type (or procedure hash-table))
          (description "Folder procedure or deprecated table."))
         (seed-or-procedure (type (or object procedure))
          (description "Seed or deprecated folder."))
         (table-or-seed (type (or hash-table object))
          (description "Table or deprecated seed.")))
        (returns (type any) (description "Final accumulated value."))
        (effects allocation error procedure-call))
      (let ((procedure
             (if (hash-table? procedure-or-table)
                 seed-or-procedure
                 procedure-or-table))
            (seed
             (if (hash-table? procedure-or-table)
                 table-or-seed
                 seed-or-procedure))
            (table
             (if (hash-table? procedure-or-table)
                 procedure-or-table
                 table-or-seed)))
        (check-table table 'hash-table-fold)
        (let loop ((entries (hash-table-storage-entries table)) (value seed))
          (if (null? entries)
              value
              (let ((entry (car entries)))
                (loop
                 (cdr entries)
                 (call-without-table-mutation
                  table
                  procedure
                  (list (hash-table-entry-key entry)
                        (hash-table-entry-value entry)
                        value)
                  'hash-table-fold)))))))

    (define (hash-table-prune! predicate table)
      "Delete TABLE associations satisfying PREDICATE."
      #((parameters
         (predicate (type procedure) (description "Association predicate."))
         (table (type hash-table) (description "Mutable hash table.")))
        (returns (type unspecified) (description "Unspecified value."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table table 'hash-table-prune!)
      (let loop ((entries (hash-table-storage-entries table)))
        (if (pair? entries)
            (let ((entry (car entries)))
              (if (call-without-table-mutation
                   table
                   predicate
                   (list (hash-table-entry-key entry)
                         (hash-table-entry-value entry))
                   'hash-table-prune!)
                  (hash-table-storage-delete!
                   table (hash-table-entry-key entry)))
              (loop (cdr entries))))))

    (define (hash-table-copy table . mutable)
      "Return a copy of TABLE, immutable unless MUTABLE is true."
      #((parameters
         (table (type hash-table) (description "Source hash table."))
         (mutable (type list) (description "Optional mutability flag.")))
        (returns (type hash-table) (description "Copied hash table."))
        (effects allocation error procedure-call))
      (if (> (length mutable) 1)
          (error "hash-table-copy received too many arguments" mutable))
      (hash-table-storage-copy
       (check-table table 'hash-table-copy)
       (and (pair? mutable) (car mutable))))

    (define (hash-table-empty-copy table)
      "Return an empty mutable table with TABLE's key policy."
      #((parameters (table (type hash-table) (description "Source table.")))
        (returns (type hash-table) (description "Empty mutable table."))
        (effects allocation error))
      (check-table table 'hash-table-empty-copy)
      (make-hash-table-storage
       (hash-table-storage-policy table)
       (hash-table-storage-capacity table)
       #t))

    (define (hash-table->alist table)
      "Return a fresh association list containing TABLE's entries."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type list) (description "Fresh association list."))
        (effects allocation error))
      (map
       (lambda (entry)
         (cons (hash-table-entry-key entry)
               (hash-table-entry-value entry)))
       (hash-table-storage-entries
        (check-table table 'hash-table->alist))))

    (define (hash-table-union! left right)
      "Add RIGHT's absent associations to mutable LEFT and return LEFT."
      #((parameters
         (left (type hash-table) (description "Mutable destination."))
         (right (type hash-table) (description "Source table.")))
        (returns (type hash-table) (description "Mutated LEFT."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table left 'hash-table-union!)
      (check-table right 'hash-table-union!)
      (let loop ((entries (hash-table-storage-entries right)))
        (if (pair? entries)
            (let ((entry (car entries)))
              (if (not (table-ref-entry-if-accepted
                        left (hash-table-entry-key entry)))
                  (hash-table-storage-set!
                   left
                   (hash-table-entry-key entry)
                   (hash-table-entry-value entry)))
              (loop (cdr entries)))))
      left)

    (define (hash-table-merge! left right)
      "Union RIGHT into LEFT; deprecated SRFI 69 spelling."
      #((parameters
         (left (type hash-table) (description "Mutable destination."))
         (right (type hash-table) (description "Source table.")))
        (returns (type hash-table) (description "Mutated LEFT."))
        (effects mutation allocation error procedure-call))
      (hash-table-union! left right))

    (define (hash-table-intersection! left right)
      "Retain only LEFT associations also present in RIGHT."
      #((parameters
         (left (type hash-table) (description "Mutable destination."))
         (right (type hash-table) (description "Comparison table.")))
        (returns (type hash-table) (description "Mutated LEFT."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table left 'hash-table-intersection!)
      (check-table right 'hash-table-intersection!)
      (let loop ((entries (hash-table-storage-entries left)))
        (if (pair? entries)
            (let ((entry (car entries)))
              (if (not (table-ref-entry-if-accepted
                        right (hash-table-entry-key entry)))
                  (hash-table-storage-delete!
                   left (hash-table-entry-key entry)))
              (loop (cdr entries)))))
      left)

    (define (hash-table-difference! left right)
      "Delete from LEFT every association whose key occurs in RIGHT."
      #((parameters
         (left (type hash-table) (description "Mutable destination."))
         (right (type hash-table) (description "Comparison table.")))
        (returns (type hash-table) (description "Mutated LEFT."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table left 'hash-table-difference!)
      (check-table right 'hash-table-difference!)
      (let loop ((entries (hash-table-storage-entries left)))
        (if (pair? entries)
            (let ((entry (car entries)))
              (if (table-ref-entry-if-accepted
                   right (hash-table-entry-key entry))
                  (hash-table-storage-delete!
                   left (hash-table-entry-key entry)))
              (loop (cdr entries)))))
      left)

    (define (hash-table-xor! left right)
      "Replace LEFT with its association-key symmetric difference with RIGHT."
      #((parameters
         (left (type hash-table) (description "Mutable destination."))
         (right (type hash-table) (description "Comparison table.")))
        (returns (type hash-table) (description "Mutated LEFT."))
        (effects mutation allocation error procedure-call))
      (check-mutable-table left 'hash-table-xor!)
      (check-table right 'hash-table-xor!)
      (let loop ((entries (hash-table-storage-entries right)))
        (if (pair? entries)
            (let* ((entry (car entries))
                   (key (hash-table-entry-key entry)))
              (if (table-ref-entry-if-accepted left key)
                  (hash-table-storage-delete! left key)
                  (hash-table-storage-set!
                   left key (hash-table-entry-value entry)))
              (loop (cdr entries)))))
      left)

    (define (hash object . ignored)
      "Return OBJECT's deprecated SRFI 125 default hash."
      #((parameters
         (object (type any) (description "Object to hash."))
         (ignored (type list) (description "Ignored compatibility bound.")))
        (returns (type exact-non-negative-integer)
         (description "Default hash."))
        (effects error))
      (if (> (length ignored) 1)
          (error "hash received too many bounds" ignored))
      (comparator-default-hash object))

    (define (string-hash string . ignored)
      "Return STRING's deprecated SRFI 125 case-sensitive hash."
      #((parameters
         (string (type string) (description "String to hash."))
         (ignored (type list) (description "Ignored compatibility bound.")))
        (returns (type exact-non-negative-integer)
         (description "Case-sensitive string hash."))
        (effects error))
      (if (> (length ignored) 1)
          (error "string-hash received too many bounds" ignored))
      (comparator-string-hash string))

    (define (string-ci-hash string . ignored)
      "Return STRING's deprecated SRFI 125 case-insensitive hash."
      #((parameters
         (string (type string) (description "String to hash."))
         (ignored (type list) (description "Ignored compatibility bound.")))
        (returns (type exact-non-negative-integer)
         (description "Case-insensitive string hash."))
        (effects error))
      (if (> (length ignored) 1)
          (error "string-ci-hash received too many bounds" ignored))
      (comparator-string-ci-hash string))

    (define (hash-by-identity object . ignored)
      "Return OBJECT's deprecated portable identity-compatible hash."
      #((parameters
         (object (type any) (description "Object to hash."))
         (ignored (type list) (description "Ignored compatibility bound.")))
        (returns (type exact-non-negative-integer)
         (description "Portable hash value."))
        (effects error))
      (if (> (length ignored) 1)
          (error "hash-by-identity received too many bounds" ignored))
      (comparator-default-hash object))

    (define (hash-table-equivalence-function table)
      "Return TABLE's deprecated key equivalence procedure."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type procedure) (description "Key equivalence."))
        (effects error))
      (hash-table-policy-equivalence
       (hash-table-storage-policy
        (check-table table 'hash-table-equivalence-function))))

    (define (hash-table-hash-function table)
      "Return TABLE's deprecated key hash procedure."
      #((parameters (table (type hash-table) (description "Hash table.")))
        (returns (type procedure) (description "Key hash procedure."))
        (effects error))
      (hash-table-policy-hash
       (hash-table-storage-policy
        (check-table table 'hash-table-hash-function))))))
