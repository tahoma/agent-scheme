;;; Portable Consent Scheme result rendering boundary.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns conversion from runtime values and evaluation outcomes to
;;; stable external datums and strings.

(define-library (consent result)
  (export result-field
          value->result-datum
          strip-identifiers
          budget-result-field
          ok-result-datum
          debugger-condition-datum
          debugger-exception-datum
          debugger-field-values
          debugger-field-value
          debugger-expect-condition
          debugger-restart-id-name
          debugger-default-restarts
          condition-result-datum
          budget-exhausted-condition?
          consent-result->external
          consent-value->external)
  (import (scheme base)
          (consent datum)
          (consent identity-map)
          (consent reader)
          (consent symbol)
          (consent symbol-boundary)
          (consent runtime))
  (begin
    ;; This module serializes values assembled on both sides of the bootstrap
    ;; boundary. Keep the imported base procedures as the local default and
    ;; name the exceptional mixed-symbol operations at their call sites.
    (define host-eq? eq?)
    ;; Recognize result symbols across the owned/bootstrap boundary.
    (define result-symbol? consent-host-symbol?)
    ;; Read result symbol names across the owned/bootstrap boundary.
    (define result-symbol-name consent-host-symbol-name)
    ;; Compare result names across the owned/bootstrap boundary.
    (define result-symbol-eq? consent-host-symbol-eq?)
    ;; Compare result datums across the owned/bootstrap boundary.
    (define result-datum-equal? consent-host-symbol-equal?)
    (define (result-pair? value)
      "Report whether VALUE is a host or owned pair."
      (or (pair? value) (consent-datum-pair? value)))

    (define (result-car pair)
      "Return host or owned PAIR's car."
      (if (pair? pair)
          (car pair)
          (consent-datum-car pair)))

    (define (result-cdr pair)
      "Return host or owned PAIR's cdr."
      (if (pair? pair)
          (cdr pair)
          (consent-datum-cdr pair)))

    (define (result-assq key alist)
      "Look up KEY in a host or owned result association list."
      (let loop ((rest alist))
        (cond
         ((null? rest) #f)
         ((not (result-pair? rest)) #f)
         ((let ((entry (result-car rest)))
            (and (result-pair? entry)
                 (result-symbol-eq? key (result-car entry))
                 entry)))
         (else (loop (result-cdr rest))))))

    (define (result-field name . values)
      "Construct a named field for public result datums."
      #((parameters
         (name (type symbol)
          (description "Symbol naming the result field."))
         (values (type list)
          (description "Zero or more Scheme-readable field values.")))
        (returns (type pair)
         (description
           ("A field pair whose car is NAME and whose cdr is VALUES.")))
        (effects pure))
      (cons name values))

    (define (value->result-datum value . maybe-seen)
      "Return VALUE converted to a public result datum."
      #((parameters
         (value . ("Runtime value to render as stable Scheme-readable data."))
         (maybe-seen (type list)
          (description
           ("Optional legacy ancestor list used only by internal callers."
             "Ordinary calls omit it."))))
        (returns
         . ("A public datum representation of VALUE suitable for"
            "evaluation-result records."))
        (effects pure))
      ;; A traversal entry holds state (`active' or `done') and its output.
      ;; Maps are allocated lazily so scalar results keep the scalar hot path.
      (let ((absent (vector 'result-graph-absent))
            (owned-map #f)
            (host-map #f)
            (pending '())
            (root (vector #f)))
        (define (graph-ref item)
          (if (consent-datum-object? item)
              (if owned-map
                  (consent-datum-object-map-ref owned-map item absent)
                  absent)
              (if host-map
                  (consent-identity-map-ref host-map item absent)
                  absent)))
        (define (graph-set! item entry)
          (if (consent-datum-object? item)
              (begin
                (if (not owned-map)
                    (set! owned-map (consent-make-datum-object-map)))
                (consent-datum-object-map-set! owned-map item entry))
              (begin
                (if (not host-map)
                    (set! host-map (consent-make-identity-map)))
                (consent-identity-map-set! host-map item entry))))
        (define (push! task)
          (set! pending (cons task pending)))
        (define (push-visit! item setter)
          (push! (vector 'visit item setter)))
        (define (active-entry? entry)
          (eq? (vector-ref entry 0) 'active))
        (define (finish-entry! entry)
          (vector-set! entry 0 'done))
        (define (pair-cycle-marker item)
          (if (or (consent-datum-pair? item) (pair? item))
              '(cycle)
              #(cycle)))
        (define (visit-compound! item setter pair-kind? owned?)
          (let ((entry (graph-ref item)))
            (cond
             ((not (eq? entry absent))
              (setter
               (if (active-entry? entry)
                   (pair-cycle-marker item)
                   (vector-ref entry 1))))
             (pair-kind?
              (let* ((copy (cons #f #f))
                     (entry (vector 'active copy)))
                (graph-set! item entry)
                (setter copy)
                (push! (vector 'finish entry))
                (push-visit!
                 (if owned?
                     (consent-datum-cdr item)
                     (cdr item))
                 (lambda (rendered) (set-cdr! copy rendered)))
                (push-visit!
                 (if owned?
                     (consent-datum-car item)
                     (car item))
                 (lambda (rendered) (set-car! copy rendered)))))
             (else
              (let* ((length
                      (if owned?
                          (consent-datum-vector-length item)
                          (vector-length item)))
                     (copy (make-vector length #f))
                     (entry (vector 'active copy)))
                (graph-set! item entry)
                (setter copy)
                (push! (vector 'finish entry))
                (let loop ((index (- length 1)))
                  (if (>= index 0)
                      (begin
                        (push-visit!
                         (if owned?
                             (consent-datum-vector-ref item index)
                             (vector-ref item index))
                         (lambda (rendered)
                           (vector-set! copy index rendered)))
                        (loop (- index 1))))))))))
        (define (visit! item setter)
          (cond
           ((or (boolean? item)
                (null? item)
                (result-symbol? item)
                (char? item)
                (number? item)
                (consent-number? item)
                (string? item)
                (bytevector? item))
            (setter item))
           ((or (consent-datum-string? item)
                (consent-datum-bytevector? item))
            (let ((entry (graph-ref item)))
              (if (eq? entry absent)
                  (let* ((copy
                          (if (consent-datum-string? item)
                              (consent-datum-string->host item)
                              (consent-datum-bytevector->host item)))
                         (entry (vector 'done copy)))
                    (graph-set! item entry)
                    (setter copy))
                  (setter (vector-ref entry 1)))))
           ((identifier? item)
            (setter (identifier-name item)))
           ((consent-unspecified? item)
            (setter '(unspecified)))
           ((consent-eof-object? item)
            (setter '(eof-object)))
           ((consent-port? item)
            (setter
             (list 'port
                   (result-field 'medium (consent-port-medium item))
                   (result-field
                    'open
                    (if (consent-port-open? item) #t #f)))))
           ((environment-specifier? item)
            (setter '(environment)))
           ((consent-primitive-procedure? item)
            (setter
             (list 'procedure
                   (result-field 'kind 'primitive)
                   (result-field 'name
                                 (primitive-procedure-name item)))))
           ((consent-parameter? item)
            (setter (list 'procedure (result-field 'kind 'parameter))))
           ((consent-procedure? item)
            (setter (list 'procedure (result-field 'kind 'compound))))
           ((continuation? item)
            (setter (list 'procedure (result-field 'kind 'continuation))))
           ((consent-error-object? item)
            (let ((entry (graph-ref item)))
              (if (not (eq? entry absent))
                  (setter
                   (if (active-entry? entry)
                       '(cycle)
                       (vector-ref entry 1)))
                  (let* ((irritants-field (result-field 'irritants #f))
                         (rendered
                          (list 'error-object
                                (result-field
                                 'message
                                 (consent-error-object-message item))
                                irritants-field))
                         (entry (vector 'active rendered)))
                    ;; Error objects are graph nodes too: their mutable
                    ;; irritants may point back to the error or be shared by
                    ;; many parents. Register before scheduling that edge.
                    (graph-set! item entry)
                    (setter rendered)
                    (push! (vector 'finish entry))
                    (push-visit!
                     (consent-error-object-irritants item)
                     (lambda (value)
                       (set-car! (cdr irritants-field) value)))))))
           ((consent-record-type? item)
            (setter
             (list 'record-type
                   (result-field 'name
                                 (consent-record-type-name item)))))
           ((consent-record? item)
            (setter
             (list 'record
                   (result-field
                    'type
                    (consent-record-type-name
                     (consent-record-type item))))))
           ((consent-datum-pair? item)
            (visit-compound! item setter #t #t))
           ((consent-datum-vector? item)
            (visit-compound! item setter #f #t))
           ((pair? item)
            (visit-compound! item setter #t #f))
           ((vector? item)
            (visit-compound! item setter #f #f))
           (else
            (setter
             (list 'host-object
                   (result-field 'printed "#<host-object>"))))))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           ;; Preserve the old internal ancestor argument without making it
           ;; the traversal's lookup structure. Seeded nodes are active cycle
           ;; roots.
           (if (not (null? maybe-seen))
               (let seed ((rest (car maybe-seen)))
                 (if (pair? rest)
                     (begin
                       (let ((item (car rest)))
                         (if (or (consent-datum-pair? item)
                                 (consent-datum-vector? item)
                                 (pair? item)
                                 (vector? item))
                             (graph-set! item (vector 'active #f))))
                       (seed (cdr rest))))))
           (push-visit! value (lambda (rendered)
                                (vector-set! root 0 rendered)))
           (let loop ()
             (if (pair? pending)
                 (let ((task (car pending)))
                   (set! pending (cdr pending))
                   (if (eq? (vector-ref task 0) 'finish)
                       (finish-entry! (vector-ref task 1))
                       (visit! (vector-ref task 1)
                               (vector-ref task 2)))
                   (loop))))
           (vector-ref root 0))
         (lambda ()
           (if host-map
               (consent-identity-map-release! host-map))
           (if owned-map
               (consent-datum-object-map-release! owned-map))))))

    (define (strip-identifiers value . maybe-context)
      "Remove hygienic identifier wrappers from VALUE for readable output."
      #((parameters
         (value . "Runtime value to simplify for display.")
         (maybe-context (type list)
          (description
           ("Optional evaluation context used to preserve context-local"
             "source provenance on rebuilt containers."))))
        (returns
         . ("VALUE with identifiers replaced by their names inside"
            "compound values."))
        (effects state-read state-write))
      (let ((context (if (null? maybe-context)
                         #f
                         (car maybe-context)))
            (absent (vector 'strip-graph-absent))
            (host-map #f)
            (pending '())
            (root (vector #f)))
        (define (copy-source! target source)
          (if context
              (context-copy-datum-source! context target source #t)
              (consent-copy-datum-source! target source #t)))
        (define (graph-ref item)
          (if host-map
              (consent-identity-map-ref host-map item absent)
              absent))
        (define (graph-set! item entry)
          (if (not host-map)
              (set! host-map (consent-make-identity-map)))
          (consent-identity-map-set! host-map item entry))
        (define (push! task)
          (set! pending (cons task pending)))
        (define (push-visit! item setter)
          (push! (vector 'visit item setter)))
        (define (note-child! changed copy setter original rendered)
          (setter rendered)
          (if (not (host-eq? rendered original))
              (vector-set! changed 0 #t)))
        (define (visit-host-compound! item setter pair-kind?)
          (let ((entry (graph-ref item)))
            (if (not (eq? entry absent))
                (setter (vector-ref entry 1))
                (let* ((copy
                        (if pair-kind?
                            (cons #f #f)
                            (make-vector (vector-length item) #f)))
                       (entry (vector 'active copy))
                       (changed (vector #f)))
                  (graph-set! item entry)
                  (push!
                   (vector
                    'finish
                    (lambda ()
                      (let ((output
                             (if (vector-ref changed 0) copy item)))
                        (if (vector-ref changed 0)
                            (copy-source! copy item))
                        (vector-set! entry 0 'done)
                        (vector-set! entry 1 output)
                        (setter output)))))
                  (if pair-kind?
                      (begin
                        (push-visit!
                         (cdr item)
                         (lambda (rendered)
                           (note-child! changed copy
                                        (lambda (value)
                                          (set-cdr! copy value))
                                        (cdr item)
                                        rendered)))
                        (push-visit!
                         (car item)
                         (lambda (rendered)
                           (note-child! changed copy
                                        (lambda (value)
                                          (set-car! copy value))
                                        (car item)
                                        rendered))))
                      (let loop ((index (- (vector-length item) 1)))
                        (if (>= index 0)
                            (begin
                              (push-visit!
                               (vector-ref item index)
                               (lambda (rendered)
                                 (note-child!
                                  changed
                                  copy
                                  (lambda (value)
                                    (vector-set! copy index value))
                                  (vector-ref item index)
                                  rendered)))
                              (loop (- index 1))))))))))
        (define (visit! item setter)
          (cond
           ((identifier? item)
            (setter (identifier-name item)))
           ((consent-datum-object? item)
            ;; Published runtime data is already identifier-free. Keep its
            ;; owned identity instead of projecting and re-importing it.
            (setter item))
           ((pair? item)
            (visit-host-compound! item setter #t))
           ((vector? item)
            (visit-host-compound! item setter #f))
           (else (setter item))))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (push-visit! value (lambda (rendered)
                                (vector-set! root 0 rendered)))
           (let loop ()
             (if (pair? pending)
                 (let ((task (car pending)))
                   (set! pending (cdr pending))
                   (if (eq? (vector-ref task 0) 'finish)
                       ((vector-ref task 1))
                       (visit! (vector-ref task 1)
                               (vector-ref task 2)))
                   (loop))))
           (vector-ref root 0))
         (lambda ()
           (if host-map
               (consent-identity-map-release! host-map))))))

    (define (budget-result-field context)
      "Build the budget field for a public evaluation-result datum."
      #((parameters
         (context (type eval-context)
          (description "Evaluation context containing budget counters.")))
        (returns (type pair)
         (description
          ("A `budget` result field with steps-used and host-calls"
            "counters.")))
        (effects state-read))
      (result-field
       'budget
       (result-field
        'steps-used
        (consent-make-canonical-integer (context-steps context)))
       (result-field
        'host-calls
        (consent-make-canonical-integer
         (context-host-callbacks context)))))

    (define (context-events context)
      "Return policy and event-channel events in the order they were recorded.\
"
      (reverse (context-audit-events context)))

    ;; Maximum current-frame binding names included in debugger conditions.
    (define debugger-maximum-frame-bindings 40)
    ;; Maximum condition irritants included in debugger records.
    (define debugger-maximum-condition-irritants 5)

    (define (string-prefix? prefix text)
      "Report whether TEXT begins with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref text index))
                        (loop (+ index 1))))))))

    (define (string-contains? text needle)
      "Report whether TEXT contains NEEDLE."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    (define (condition-irritants condition)
      "Return CONDITION's portable irritants when they are available."
      (let ((irritants
             (cond
              ((error-object? condition)
               (error-object-irritants condition))
              ((consent-error-object? condition)
               (consent-error-object-irritants condition))
              (else '()))))
        (if (list? irritants) irritants '())))

    (define (condition-symbol-irritant condition)
      "Return CONDITION's first symbol irritant, or #f."
      (let loop ((irritants (condition-irritants condition)))
        (cond
         ((null? irritants) #f)
         ((result-symbol? (car irritants)) (car irritants))
         (else (loop (cdr irritants))))))

    (define (condition-message condition)
      "Return CONDITION's printable message."
      (let ((message
             (cond
              ((error-object? condition)
               (error-object-message condition))
              ((consent-error-object? condition)
               (consent-error-object-message condition))
              ((string? condition)
               condition)
              (else
               "error"))))
        (let ((symbol (condition-symbol-irritant condition)))
          (if (and (string-contains? message "unbound identifier") symbol)
              (string-append message
                             ": "
                             (result-symbol-name symbol))
              message))))

    (define (debugger-condition-type condition message)
      "Return a debugger condition type derived from CONDITION and MESSAGE."
      (cond
       ((string-contains? message "budget")
        'budget-exhausted)
       ((string-contains? message "policy")
        'policy-denial)
       ((string-contains? message "boundary contract checking unavailable")
        'boundary-contract-unavailable)
       ((string-contains? message "boundary contract violation")
        'boundary-contract)
       ((string-contains? message "unbound identifier")
        'unbound-variable)
       ((or (string-contains? message "arity")
            (string-contains? message "arguments"))
        'arity-error)
       ((string-contains? message "syntax-error while expanding")
        'macro-expansion)
       ((or (string-contains? message "expected")
            (string-contains? message "must be"))
        'type-error)
       (else
        'evaluation-error)))

    (define (debugger-condition-symbol condition)
      "Return the first symbol irritant for CONDITION, if any."
      (condition-symbol-irritant condition))

    (define (take items count)
      "Return the first COUNT items from ITEMS."
      (if (or (= count 0) (null? items))
          '()
          (cons (car items) (take (cdr items) (- count 1)))))

    (define (debugger-condition-irritants condition)
      "Return public debugger irritants for CONDITION."
      (map value->result-datum
           (take (condition-irritants condition)
                 debugger-maximum-condition-irritants)))

    (define (debugger-documentation-field fields name)
      "Return documentation metadata field NAME from FIELDS, or #f."
      (result-assq name fields))

    (define (debugger-documentation-origin documentation)
      "Return debugger documentation origin data."
      (let ((origins (documentation-metadata-origins documentation)))
        (cond
         ((null? origins) '(signature))
         ((result-datum-equal? origins '(implementation-procedure-string))
          '(implementation-procedure string))
         ((result-datum-equal? origins '(primitive-manifest-string))
          '(primitive-manifest string))
         ((result-datum-equal? origins '(primitive-manifest-metadata))
          '(primitive-manifest metadata))
         (else (cons 'body-literal origins)))))

    (define (debugger-documentation-fields documentation)
      "Return Scheme-readable documentation fields for DOCUMENTATION."
      (map (lambda (field)
             (list (car field) (value->result-datum (cdr field))))
           (documentation-metadata-fields documentation)))

    (define (debugger-documentation-metadata documentation)
      "Return procedure-value documentation metadata for debugger output."
      (list 'documentation-metadata
            (result-field 'subject '(procedure))
            (result-field 'kind 'procedure)
            (result-field 'library #f)
            (result-field 'source #f)
            (result-field 'origin
                          (debugger-documentation-origin documentation))
            (result-field 'fields
                          (debugger-documentation-fields documentation))))

    (define (debugger-procedure-documentation value)
      "Return debugger documentation for compound procedure VALUE, or #f."
      (and (consent-procedure? value)
           (let ((documentation (procedure-documentation value)))
             (and documentation
                  (debugger-documentation-field
                   (documentation-metadata-fields documentation)
                   'documentation)
                  (debugger-documentation-metadata documentation)))))

    (define (debugger-binding-record entry)
      "Return a safe binding record for frame ENTRY."
      (let* ((name (car entry))
             (cell (cdr entry))
             (value (cell-value cell))
             (documentation (debugger-procedure-documentation value)))
        (append
         (list 'binding
               (result-field 'name
                             (if (result-symbol? name)
                                 name
                                 'unknown-binding)))
         (if documentation
             (list (result-field 'procedure-documentation documentation))
             '()))))

    (define (debugger-binding-documented? binding)
      "Return #t when BINDING carries debugger procedure documentation."
      (if (debugger-field-value binding 'procedure-documentation) #t #f))

    (define (debugger-select-frame-bindings bindings)
      "Return BINDINGS with documented procedures preserved before truncation.\
"
      (let loop ((rest bindings) (documented '()) (plain '()))
        (cond
         ((null? rest)
          (let* ((documented-bindings (reverse documented))
                 (plain-bindings (reverse plain))
                 (plain-limit
                  (- debugger-maximum-frame-bindings
                     (length documented-bindings))))
            (append documented-bindings
                    (take plain-bindings
                          (if (< plain-limit 0) 0 plain-limit)))))
         ((debugger-binding-documented? (car rest))
          (loop (cdr rest) (cons (car rest) documented) plain))
         (else
          (loop (cdr rest) documented (cons (car rest) plain))))))

    (define (debugger-frame-bindings environment)
      "Return binding-name records for ENVIRONMENT's current frame."
      (if environment
          (debugger-select-frame-bindings
           (map debugger-binding-record (environment-frame environment)))
          '()))

    (define (debugger-environment-frame environment frame-id)
      "Return a debugger environment frame for ENVIRONMENT and FRAME-ID."
      (let ((binding-count
             (if environment (length (environment-frame environment)) 0)))
        (list
         (result-field 'frame frame-id)
         (result-field 'bindings (debugger-frame-bindings environment))
         (result-field
          'truncated
          (if (> binding-count debugger-maximum-frame-bindings) #t #f)))))

    (define (debugger-stack-frame phase frame-id)
      "Return a debugger stack frame."
      (list 'frame
            (result-field 'id frame-id)
            (result-field 'phase phase)))

    (define (debugger-restart-record id category policy)
      "Return a debugger restart record."
      (list 'restart
            (result-field 'id id)
            (result-field 'category category)
            (result-field 'policy policy)
            (result-field 'status 'available)))

    (define (debugger-default-restarts)
      "Return debugger restarts that are always safe to advertise."
      #((parameters)
        (returns (type list)
         (description
          ("List of debugger restart datums available for ordinary"
            "evaluation failures.")))
        (effects pure))
      (list
       (debugger-restart-record 'abort 'abort 'pure-r7rs)
       (debugger-restart-record 'retry 'retry 'debugger-recovery)
       (debugger-restart-record
        'provide-value 'provide-value 'debugger-recovery)
       (debugger-restart-record
        'define-binding 'define-binding 'debugger-recovery)
       (debugger-restart-record
        'import-library 'import-library 'debugger-recovery)
       (debugger-restart-record
        'continue-with-warning 'continue-with-warning 'pure-r7rs)
       (debugger-restart-record
        'request-user-input 'request-user-input 'approval-resolution)))

    (define (debugger-field-values datum field)
      "Return values for FIELD from a debugger datum."
      #((parameters
         (datum (type pair)
          (description "Debugger datum represented as a tagged list."))
         (field (type symbol)
          (description "Symbol naming the field to read.")))
        (returns (type list)
         (description "The field values for FIELD, or the empty list."))
        (effects pure))
      (let ((entry (and (result-pair? datum)
                        (result-assq field (result-cdr datum)))))
        (if entry (result-cdr entry) '())))

    (define (debugger-field-value datum field)
      "Return the first value for FIELD from a debugger datum."
      #((parameters
         (datum (type pair)
          (description "Debugger datum represented as a tagged list."))
         (field (type symbol)
          (description "Symbol naming the field to read.")))
        (returns . "The first field value for FIELD, or #f.")
        (effects pure))
      (let ((values (debugger-field-values datum field)))
        (if (null? values) #f (result-car values))))

    (define (debugger-expect-condition datum operation)
      "Return DATUM or raise when OPERATION expected a debugger condition."
      #((parameters
         (datum (type pair)
          (description "Value expected to be a debugger condition datum."))
         (operation (type string)
          (description "Operation name used in the error message.")))
        (returns (type pair)
         (description "DATUM when it is tagged as a debugger condition."))
        (effects error))
      (if (not (and (result-pair? datum)
                    (result-symbol-eq? (result-car datum) 'condition)))
          (eval-error
           (string-append operation " expected a debugger condition")))
      datum)

    (define (debugger-restart-id-name id . maybe-context)
      "Return ID as a debugger restart symbol."
      #((parameters
         (id (type (or symbol string))
          (description "Restart id as a symbol or string."))
         (maybe-context (type list)
          (description
           "Optional singleton evaluation context owning string ids.")))
        (returns (type symbol)
         (description "ID as a symbol."))
        (effects state-read state-write allocation error))
      (cond
       ((result-symbol? id)
        (if (null? maybe-context)
            id
            (consent-intern-symbol
             (context-symbol-table (car maybe-context))
             (result-symbol-name id))))
       ((or (string? id) (consent-datum-string? id))
        (let ((name
               (if (consent-datum-string? id)
                   (consent-datum-string->host id)
                   id)))
        (if (null? maybe-context)
            (string->symbol name)
            (consent-intern-symbol
             (context-symbol-table (car maybe-context))
             name))))
       (else (eval-error "restart id must be a symbol or string"))))

    (define (debugger-condition-datum condition context)
      "Build a Scheme-readable debugger condition datum."
      #((parameters
         (condition . "Host or Consent Scheme condition value.")
         (context (type eval-context)
          (description
           ("Evaluation context used for current frame and restart"
             "metadata."))))
        (returns (type condition)
         (description
           "A `condition` datum for debugger and result consumers."))
        (effects state-read))
      (let* ((message (condition-message condition))
             (type (debugger-condition-type condition message))
             (frame-id 'f-0)
             (phase 'evaluation)
             (environment-frame
              (debugger-environment-frame
               (context-interaction-environment context)
               frame-id))
             (symbol (debugger-condition-symbol condition))
             (irritants (debugger-condition-irritants condition)))
        (append
         (list 'condition
               (result-field 'type type)
               (result-field 'message message)
               (result-field 'phase phase))
         (if symbol (list (result-field 'symbol symbol)) '())
         (if (null? irritants)
             '()
             (list (result-field 'irritants irritants)))
         ;; A budget exhaustion names the dimension that stopped the run so the
         ;; stop receipt answers "which budget was no longer admissible?".
         (if (and (result-symbol-eq? type 'budget-exhausted)
                  (context-exhaustion-reason context))
             (list (result-field 'reason (context-exhaustion-reason context)))
             '())
         (list
          (result-field
           'stack
           (list (debugger-stack-frame phase frame-id)))
          (result-field 'environment environment-frame)
          (result-field 'restarts (debugger-default-restarts))))))

    (define (debugger-exception-datum exception context)
      "Build a debugger condition for a Scheme-raised EXCEPTION value."
      #((parameters
         (exception . "Scheme value raised as an exception.")
         (context (type eval-context)
          (description "Evaluation context used for debugger metadata.")))
        (returns (type condition)
         (description
          ("A debugger condition datum that preserves EXCEPTION as a"
            "public result value.")))
        (effects state-read))
      (append
       (debugger-condition-datum
        (make-consent-error-object
         "raised exception"
         (list exception))
        context)
       (list (result-field 'value (value->result-datum exception)))))

    (define (ok-result-datum value context)
      "Build a successful evaluation-result datum for VALUE."
      #((parameters
         (value . "Runtime value returned by evaluation.")
         (context (type eval-context)
          (description
            ("Evaluation context containing events and budget counters."))))
        (returns (type evaluation-result)
         (description
           "An `evaluation-result` datum with status ok or values."))
        (effects state-read))
      (if (multiple-values? value)
          (list 'evaluation-result
                (result-field 'status 'values)
                (result-field
                 'values
                 (map value->result-datum
                      (multiple-values-values value)))
                (result-field 'events (context-events context))
                (budget-result-field context))
          (list 'evaluation-result
                (result-field 'status 'ok)
                (result-field 'value (value->result-datum value))
                (result-field 'events (context-events context))
                (budget-result-field context))))

    (define (condition-result-datum condition context)
      "Build an error evaluation-result datum for CONDITION."
      #((parameters
         (condition . "Host or Consent Scheme condition value.")
         (context (type eval-context)
          (description
           ("Evaluation context to update with the current debugger"
             "error."))))
        (returns (type evaluation-result)
         (description "An `evaluation-result` datum with status error."))
        (effects state-write))
      (let ((debugger-condition
             (debugger-condition-datum condition context)))
        (set-context-current-error! context debugger-condition)
        (list 'evaluation-result
              (result-field 'status 'error)
              (result-field
               'error
               (result-field 'condition debugger-condition)
               (result-field 'host-condition 'error)
               (result-field 'message (condition-message condition)))
              (result-field 'events (context-events context))
              (budget-result-field context))))

    (define (budget-exhausted-condition? value)
      "Report whether VALUE is a budget-exhaustion condition or stop receipt."
      #((parameters
         (value (type pair)
          (description "Condition datum or evaluation-result error datum.")))
        (returns (type boolean)
         (description "#t when VALUE names a budget exhaustion, else #f."))
        (effects pure))
      (and (pair? value)
           (cond
            ((result-symbol-eq? (car value) 'condition)
             (result-symbol-eq?
              (debugger-field-value value 'type)
              'budget-exhausted))
            ((result-symbol-eq? (car value) 'evaluation-result)
             (let ((error-entry (result-assq 'error (cdr value))))
               (and (pair? error-entry)
                    (let ((condition
                           (debugger-field-value error-entry 'condition)))
                      (and (pair? condition)
                           (budget-exhausted-condition? condition))))))
            (else #f))))

    (define (consent-result->external result)
      "Render an evaluation-result datum using the reader/writer external form\
."
      #((parameters
         (result (type evaluation-result)
          (description "Public evaluation-result datum.")))
        (returns (type string)
         (description "External written text for RESULT."))
        (effects pure))
      (consent-datum->external result))

    (define (consent-value->external value)
      "Render runtime VALUE for diagnostics using stable external text."
      #((parameters
         (value . "Runtime value to render."))
        (returns (type string)
         (description
          ("Stable external text suitable for tests, diagnostics, and"
            "logs.")))
        (effects pure))
      (cond
       ((consent-unspecified? value)
        "#<unspecified>")
       ((consent-eof-object? value)
        "#<eof>")
       ((consent-port? value)
        (string-append
         "#<"
         (result-symbol-name (consent-port-medium value))
         "-port"
         (if (consent-port-open? value) "" " closed")
         ">"))
       ((environment-specifier? value)
        "#<environment>")
       ((consent-parameter? value)
        "#<procedure>")
       ((consent-procedure? value)
        "#<procedure>")
       ((consent-primitive-procedure? value)
        (string-append
         "#<primitive "
         (result-symbol-name (primitive-procedure-name value))
         ">"))
       ((continuation? value)
        "#<continuation>")
       ((consent-error-object? value)
        (string-append
         "#<error-object "
         (consent-error-object-message value)
         ">"))
       ((multiple-values? value)
        (consent-datum->external
         (cons 'values
               (map strip-identifiers (multiple-values-values value)))))
       (else
        (consent-datum->external (strip-identifiers value)))))))
