;;; Portable owned compound datum heap tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (prefix (agent context) native-context:)
        (prefix (agent memory-key) native-memory-key:)
        (prefix (agent memory-query) native-memory-query:)
        (prefix (agent models openai-codec) native-openai-codec:)
        (prefix (agent redaction-kernel) native-redaction-kernel:)
        (prefix (agent task) native-task:)
        (prefix (agent transcript) native-transcript:)
        (prefix (consent symbol) native-symbol:)
        (only (consent character) consent-make-character)
        (consent datum)
        (only (consent identity-map)
              consent-identity-map-fast-backend?
              consent-identity-map-ref
              consent-identity-map-set!)
        (only (consent interpreter)
              consent-eval
              consent-eval-source)
        (only (consent manifest) consent-library-manifest-ref)
        (only (consent library)
              consent-apply-callable
              consent-call-native-library
              consent-native-argument-value
              consent-runtime-datum->native-datum
              resolve-library)
        (only (consent reader)
              consent-datum->external
              consent-datum-source
              consent-datum-source-set!
              consent-make-record
              consent-make-record-type
              consent-record?
              consent-source-metadata-count)
        (only (consent result) value->result-datum)
        (only (consent runtime)
              cell-value
              consent-error-object-irritants
              consent-error-object-message
              consent-error-object?
              consent-install-native-applier!
              consent-make-empty-environment
              consent-native-applier-ref
              consent-register-native-library!
              context-cell-set!
              context-datum-heap
              context-native-binding-cache
              context-value-nodes
              environment-cell
              environment-define!
              environment-set!
              library-binding-name
              library-binding-object
              library-exports
              make-cell
              make-primitive-procedure
              make-consent-error-object
              new-eval-context
              primitive-procedure-function
              set-context-libraries!)
        (only (consent symbol-boundary) consent-host-symbol-eq?)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; True when the evaluator exposes owned compound records through Scheme's
;; ordinary pair/string/vector/bytevector predicates.
(define datum-compiled-host-run?
  (let ((value (get-environment-variable "TESTING_RUNNER_HOST_RUN")))
    (and value (string=? value "1"))))

;; Register a bridge test whose procedure arguments must be real host
;; procedures.  Direct Scheme hosts provide those procedures; a compiled
;; host-run interprets this test source, so its lambdas belong to the guest
;; evaluator and cannot stand in for host callbacks.  The compiled lane still
;; exercises registered native libraries through their actual native exports.
(define-syntax datum-direct-host-case
  (syntax-rules ()
    ((_ name tags body ...)
     (testing-registry-case
      name tags
      (if datum-compiled-host-run?
          (begin
            (test-skip 1)
            (test-assert name #t))
          (begin body ...))))))

(define (make-alternating-host-chain depth leaf)
  "Return DEPTH host pair/vector nodes ending in LEAF."
  (let loop ((index 0) (result leaf))
    (if (= index depth)
        result
        (loop
         (+ index 1)
         (if (even? index)
             (cons 'pair result)
             (vector result))))))

(define (alternating-host-chain-leaf depth value)
  "Return the leaf below DEPTH alternating host pair/vector nodes."
  (let loop ((remaining depth) (cursor value))
    (if (= remaining 0)
        cursor
        (let ((index (- remaining 1)))
          (loop
           index
           (if (even? index)
               (cdr cursor)
               (vector-ref cursor 0)))))))

;; Retired prime modulus used by the quadratic stable-ID map baseline.
(define old-datum-object-map-hash-modulus 536870909)

(define (old-datum-object-map-hash object capacity)
  "Return OBJECT's bucket under the retired stable-ID hash map."
  (modulo
   (modulo
    (+ (* (modulo (consent-datum-object-heap-id object)
                  old-datum-object-map-hash-modulus)
          1000003)
       (* (modulo (consent-datum-object-id object)
                  old-datum-object-map-hash-modulus)
          91771))
    old-datum-object-map-hash-modulus)
   capacity))

(define (datum-map-continuation-reentry-condition object)
  "Return the condition raised when a closed map continuation is resumed."
  (call/cc
   (lambda (finish)
     (let ((resume #f) (reentering? #f))
       (guard (condition
               (else
                (if reentering?
                    (finish condition)
                    (raise condition))))
         (call/cc
          (lambda (leave)
            (call-with-consent-datum-object-map
             (lambda (map)
               (consent-datum-object-map-set! map object 'marked)
               (call/cc
                (lambda (continuation)
                  (set! resume continuation)
                  (leave #t)))
               (consent-datum-object-map-ref map object #f)))))
         (set! reentering? #t)
         (resume #t)
         (finish #f))))))

(define (datum-residency-stat stats category field)
  "Return FIELD from CATEGORY in datum residency STATS."
  (let ((category-entry (assq category (cdr stats))))
    (if (not category-entry)
        (error "missing datum residency category" category))
    (let ((field-entry (assq field (cdr category-entry))))
      (if field-entry
          (cadr field-entry)
          (error "missing datum residency field" category field)))))

;; Keep the public category ordinals paired with stable assertion labels.
(define datum-residency-test-category-names
  '#(owned-pair
     owned-string
     owned-vector
     owned-bytevector
     owned-internal
     construction-marker
     construction-index-slot
     revision-sidecar-page
     traversal-sidecar-page
     map-sidecar-page
     source-sidecar-page
     phase-map-page
     graph-map-entry
     import-result-shell
     import-host-memo-entry
     import-owned-memo-entry
     import-work-entry
     export-result-shell
     export-host-memo-entry
     export-owned-memo-entry
     export-work-entry))

;; Keep the public field ordinals paired with stable assertion labels.
(define datum-residency-test-field-names
  '#(allocations releases live high-water))

(define (datum-residency-stats-for-token token)
  "Build named residency statistics through scalar TOKEN queries."
  (let category-loop ((category 0) (categories '()))
    (if (= category (vector-length datum-residency-test-category-names))
        (cons
         'datum-residency-stats
         (cons '(active #f) (reverse categories)))
        (let field-loop ((field 0) (fields '()))
          (if (= field (vector-length datum-residency-test-field-names))
              (category-loop
               (+ category 1)
               (cons
                (cons
                 (vector-ref datum-residency-test-category-names category)
                 (reverse fields))
                categories))
              (field-loop
               (+ field 1)
               (cons
                (list
                 (vector-ref datum-residency-test-field-names field)
                 (consent-datum-residency-tracking-statistic
                  token category field))
                fields)))))))

(define (finish-datum-residency-stats! token)
  "Finish TOKEN, collect scalar counters, and release tracker storage."
  (let ((completed-token
         (consent-datum-residency-tracking-finish! token))
        (stats #f))
    (dynamic-wind
     (lambda () #t)
     (lambda ()
       (set! stats (datum-residency-stats-for-token completed-token)))
     (lambda ()
       (consent-datum-residency-tracking-release! completed-token)))
    stats))

(define (call-with-datum-residency-stats procedure)
  "Call PROCEDURE in a residency scope and return #(result statistics)."
  (let ((token (consent-datum-residency-tracking-start!))
        (result #f)
        (stats #f))
    (dynamic-wind
     (lambda () #t)
     (lambda () (set! result (procedure)))
     (lambda ()
       (set! stats (finish-datum-residency-stats! token))))
    (vector result stats)))

(define (test-library-binding-cell library name)
  "Return exported NAME's cell from test LIBRARY."
  (let loop ((rest (library-exports library)))
    (cond
     ((null? rest) #f)
     ((consent-host-symbol-eq?
       name (library-binding-name (car rest)))
      (library-binding-object (car rest)))
     (else (loop (cdr rest))))))

(define (native-symbol-test-bindings)
  "Return the compiled symbol bindings used by native-boundary tests."
  (list
    (cons 'consent-symbol? native-symbol:consent-symbol?)
    (cons 'consent-symbol-name native-symbol:consent-symbol-name)
    (cons 'consent-symbol-equivalent?
          native-symbol:consent-symbol-equivalent?)
    (cons 'consent-symbol=? native-symbol:consent-symbol=?)
    (cons 'consent-symbol-table? native-symbol:consent-symbol-table?)
    (cons 'consent-make-symbol-table
          native-symbol:consent-make-symbol-table)
    (cons 'consent-symbol-table-from-root
          native-symbol:consent-symbol-table-from-root)
    (cons 'consent-symbol-table-root
          native-symbol:consent-symbol-table-root)
    (cons 'consent-symbol-table-root-set!
          native-symbol:consent-symbol-table-root-set!)
    (cons 'consent-intern-symbol native-symbol:consent-intern-symbol)
    (cons 'consent-default-symbol-table
          native-symbol:consent-default-symbol-table)))

(define (register-native-symbol-test-library!)
  "Register the compiled symbol bindings used by native-boundary tests."
  (consent-register-native-library!
   '(consent symbol)
   (native-symbol-test-bindings)))

(define (native-symbol-bindings-with name value)
  "Return test symbol bindings with NAME replaced by VALUE."
  (map
   (lambda (binding)
     (if (consent-host-symbol-eq? (car binding) name)
         (cons name value)
         binding))
   (native-symbol-test-bindings)))

(define (native-openai-codec-test-bindings)
  "Return the exact compiled OpenAI codec borrow inventory."
  (list
   (cons
    'model-openai-codec-request-json-projected
    native-openai-codec:model-openai-codec-request-json-projected)
   (cons
    'model-openai-codec-parse-response
    native-openai-codec:model-openai-codec-parse-response)
   (cons
    'model-openai-codec-provider-error-projected
    native-openai-codec:model-openai-codec-provider-error-projected)))

(define (native-memory-query-test-bindings)
  "Return the exact compiled memory-query borrow inventory."
  (list
   (cons 'memory-query-find native-memory-query:memory-query-find)
   (cons 'memory-query-by-tag native-memory-query:memory-query-by-tag)
   (cons 'memory-query-recent native-memory-query:memory-query-recent)
   (cons 'memory-query-select native-memory-query:memory-query-select)))

(define (native-memory-query-test-key scope key)
  "Return one detached query key prepared outside the borrowed call."
  (native-memory-key:memory-prepare-index-key scope key))

(define (native-memory-query-test-sidecar
         live-key id-key kind-key tag-keys flags)
  "Return one valid detached six-slot live query SIDECAR fixture."
  (vector live-key id-key #f kind-key (list->vector tag-keys) flags))

(define (native-memory-query-test-live-projection sidecar access-sequence)
  "Return SIDECAR with its detached current access sequence."
  (vector sidecar access-sequence))

(define (native-memory-query-test-term-projection term project-key)
  "Return TERM's detached text and known per-scope key projections."
  (vector
   (cond
    ((string? term) (string-copy term))
    ((symbol? term) (string-copy (symbol->string term)))
    (else #f))
   (vector #f #f project-key)))

(define (native-memory-query-test-select-projection query project-keys)
  "Return QUERY with its detached relevance-term projection vector."
  (let ((terms (if (list? query) query (list query))))
    (vector
     query
     (list->vector
      (map native-memory-query-test-term-projection terms project-keys)))))

(define (native-memory-query-test-field datum name)
  "Return NAME from host tagged record DATUM, or #f."
  (let loop ((fields (cdr datum)))
    (cond
     ((null? fields) #f)
     ((and (pair? (car fields)) (eq? (caar fields) name))
      (cadr (car fields)))
     (else (loop (cdr fields))))))

(define (native-redaction-kernel-test-bindings)
  "Return the exact compiled redaction-kernel borrow inventory."
  (list
   (cons
    'redaction-kernel-secret-string?
    native-redaction-kernel:redaction-kernel-secret-string?)))

(define (native-memory-query-bindings-with name value)
  "Return memory-query bindings with NAME replaced by VALUE."
  (map
   (lambda (binding)
     (if (consent-host-symbol-eq? (car binding) name)
         (cons name value)
         binding))
   (native-memory-query-test-bindings)))

(testing-registry-case
 'owned-compound-representation '(portable runtime datum boundary)
(let* ((heap (consent-make-datum-heap))
       (pair (consent-datum-cons heap 'head 'tail))
       (string (consent-datum-string-from-host heap "text"))
       (vector (consent-datum-make-vector heap 2 #f))
       (bytevector (consent-datum-make-bytevector heap 2 0)))
  (test-assert 'heap-record (consent-datum-heap? heap))
  (test-assert 'compound-records
               (and (consent-datum-object? pair)
                    (consent-datum-object? string)
                    (consent-datum-object? vector)
                    (consent-datum-object? bytevector)))
  (test-equal 'compound-kinds
              '(pair string vector bytevector)
              (map consent-datum-object-kind
                   (list pair string vector bytevector)))
  (if datum-compiled-host-run?
      (test-assert 'compiled-language-predicates-see-owned-compounds
                   (and (pair? pair)
                        (string? string)
                        (vector? vector)
                        (bytevector? bytevector)))
      (test-assert 'direct-host-containers-stay-private
                   (and (not (pair? pair))
                        (not (string? string))
                        (not (vector? vector))
                        (not (bytevector? bytevector)))))))

(datum-direct-host-case
 'owned-long-multibyte-string-adapters
 '(portable runtime datum boundary mutation performance)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (other-heap (consent-make-datum-heap))
       (length 20000)
       (last (- length 1))
       (source (make-string length #\λ))
       (owned (consent-datum-string-from-host heap source)))
  (consent-datum-string-set-host! heap owned last #\ω)
  (let* ((cross-heap (consent-datum-import other-heap owned))
         (exported (consent-datum-export cross-heap)))
    (test-equal 'long-owned-string-length
                length
                (consent-datum-string-length owned))
    (test-equal 'long-owned-string-last-index-ref
                #\ω
                (consent-datum-string-ref-host owned last))
    (test-assert 'long-owned-string-cross-heap-is-fresh
                 (not (consent-datum-same? owned cross-heap)))
    (test-equal 'long-owned-string-cross-heap-last-index
                #\ω
                (consent-datum-string-ref-host cross-heap last))
    (test-equal 'long-owned-string-export-last-index
                #\ω
                (string-ref exported last)))
  (consent-call-native-library
   (lambda (native)
     (string-set! native last #\ξ))
   context
   owned)
  (test-equal 'long-native-string-last-index-writeback
              #\ξ
              (consent-datum-string-ref-host owned last))))

(datum-direct-host-case
 'owned-string-range-copy
 '(portable runtime datum boundary mutation performance)
(let* ((heap (consent-make-datum-heap))
       (other-heap (consent-make-datum-heap))
       (source-text (make-string 20000 #\λ))
       (ignored (string-set! source-text 9999 #\ω))
       (source (consent-datum-string-from-host heap source-text))
       (events '())
       (manifest-entry (consent-library-manifest-ref '(consent datum)))
       (exports (cadr (assq 'exports (cdr manifest-entry))))
       (raises?
        (lambda (thunk)
          (guard (condition (else #t))
            (thunk)
            #f))))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! events
           (cons (list (eq? active-heap heap)
                       (consent-datum-object-kind object)
                       operation
                       slot
                       old
                       new)
                 events))
     #t))
  (let ((copy (consent-datum-string-copy-range heap source 9998 10000)))
    (test-equal 'owned-range-copy-content
                "λω"
                (consent-datum-string->host copy))
    (test-equal 'owned-range-copy-length
                2
                (consent-datum-string-length copy))
    (test-assert 'owned-range-copy-fresh-mutable
                 (and (not (consent-datum-same? source copy))
                      (consent-datum-object-mutable? copy)))
    (test-equal 'owned-range-copy-starts-unmutated
                '(0 0 ())
                (list (consent-datum-object-revision source)
                      (consent-datum-object-revision copy)
                      events))
    (consent-datum-string-set-host! heap copy 0 #\ξ)
    (test-equal 'owned-range-copy-private-storage
                '("ξω" #\λ 0 1)
                (list (consent-datum-string->host copy)
                      (consent-datum-string-ref-host source 9998)
                      (consent-datum-object-revision source)
                      (consent-datum-object-revision copy)))
    (test-equal 'owned-range-copy-mutation-hook
                '((#t string string-set! 0 #\λ #\ξ))
                events))
  (test-assert 'owned-range-copy-validates-heap-and-range
               (and (raises?
                     (lambda ()
                       (consent-datum-string-copy-range
                        other-heap source 0 1)))
                    (raises?
                     (lambda ()
                       (consent-datum-string-copy-range heap source -1 1)))
                    (raises?
                     (lambda ()
                       (consent-datum-string-copy-range heap source 2 1)))
                    (raises?
                     (lambda ()
                       (consent-datum-string-copy-range
                        heap source 0 20001)))
                    (raises?
                     (lambda ()
                       (consent-datum-string-copy-range
                        heap source 0.0 1)))))
  (test-assert 'owned-range-copy-source-and-manifest-export
               (memq 'consent-datum-string-copy-range exports))))

(datum-direct-host-case
 'owned-identity-and-mutation-gateway '(portable runtime datum mutation)
(let* ((heap (consent-make-datum-heap))
       (events '())
       (pair (consent-datum-cons heap 'before 'tail)))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (observed-heap object operation slot old new)
     (set! events
           (cons (list (eq? observed-heap heap)
                       (consent-datum-same? object pair)
                       operation
                       slot
                       old
                       new)
                 events))
     #t))
  (test-equal 'fresh-revision 0 (consent-datum-object-revision pair))
  (consent-datum-set-car! heap pair 'after)
  (test-equal 'mutated-car 'after (consent-datum-car pair))
  (test-equal 'mutation-revision 1 (consent-datum-object-revision pair))
  (test-equal 'mutation-event
              '((#t #t set-car! 0 before after))
              events)
  (test-assert 'identity-is-reflexive (consent-datum-same? pair pair))
  (test-assert 'fresh-pairs-have-distinct-identities
               (not (consent-datum-same?
                     pair
                     (consent-datum-cons heap 'after 'tail))))))

(datum-direct-host-case
 'owned-trusted-pair-vector-and-string-access
 '(portable runtime datum mutation performance)
(let* ((heap (consent-make-datum-heap))
       (other-heap (consent-make-datum-heap))
       (pair (consent-datum-cons heap 'head 'tail))
       (vector (consent-datum-make-vector heap 2 'before))
       (string (consent-datum-string-from-host heap "fast"))
       (default-vector (consent-datum-make-vector heap 1 'default-before))
       (events '())
       (reentering? #f)
       (manifest-entry (consent-library-manifest-ref '(consent datum)))
       (exports (cadr (assq 'exports (cdr manifest-entry))))
       (raises?
        (lambda (thunk)
          (guard (condition (else #t))
            (thunk)
            #f))))
  (test-equal
   'trusted-pair-access
   '(head tail head tail)
   (list
    (consent-datum-car-trusted pair)
    (consent-datum-cdr-trusted pair)
    (consent-datum-car pair)
    (consent-datum-cdr pair)))
  (test-assert
   'checked-pair-access-rejects-other-kinds
   (and
    (raises? (lambda () (consent-datum-car vector)))
    (raises? (lambda () (consent-datum-cdr vector)))))
  (test-equal
   'trusted-vector-access
   '(2 before)
   (list
    (consent-datum-vector-length-trusted vector)
    (consent-datum-vector-ref-trusted vector 0)))
  (test-equal
   'trusted-string-access
   '(4 #\a 4 #\a)
   (list
    (consent-datum-string-length-trusted string)
    (consent-datum-string-ref-host-trusted string 1)
    (consent-datum-string-length string)
    (consent-datum-string-ref-host string 1)))
  (consent-datum-vector-set-trusted!
   heap default-vector 0 'default-after)
  (test-equal
   'trusted-vector-default-write
   '(default-after 1)
   (list
    (consent-datum-vector-ref-trusted default-vector 0)
    (consent-datum-object-revision default-vector)))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! events
           (cons
            (list
             (eq? active-heap heap)
             operation
             slot
             old
             new
             (consent-datum-vector-ref-trusted object slot)
             (consent-datum-object-revision object))
            events))
     #t))
  (consent-datum-vector-set-trusted! heap vector 0 'after)
  ;; Setting the same value remains an observable mutation.
  (consent-datum-vector-set-trusted! heap vector 0 'after)
  (test-equal
   'trusted-vector-hook-observes-old-state
   '((#t vector-set! 0 before after before 0)
     (#t vector-set! 0 after after after 1))
   (reverse events))
  (test-equal
   'trusted-vector-same-value-advances-revision
   '(after 2)
   (list
    (consent-datum-vector-ref-trusted vector 0)
    (consent-datum-object-revision vector)))
  (set! events '())
  (test-assert
   'trusted-vector-rejects-cross-heap-and-index
   (and
    (raises?
     (lambda ()
       (consent-datum-vector-set-trusted!
        other-heap vector 0 'cross-heap)))
    (raises?
     (lambda ()
       (consent-datum-vector-set-trusted! heap vector 2 'past-end)))))
  (test-equal
   'trusted-vector-validation-does-not-mutate
   '(after 2 ())
   (list
    (consent-datum-vector-ref-trusted vector 0)
    (consent-datum-object-revision vector)
    events))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! events
           (list
            (eq? active-heap heap)
            operation
            slot
            old
            new
            (consent-datum-vector-ref-trusted object slot)
            (consent-datum-object-revision object)))
     (error "test mutation hook abort")))
  (test-assert
   'trusted-vector-hook-can-abort
   (raises?
    (lambda ()
      (consent-datum-vector-set-trusted! heap vector 1 'aborted))))
  (test-equal
   'trusted-vector-hook-abort-leaves-state
   '(before 2 (#t vector-set! 1 before aborted before 2))
   (list
    (consent-datum-vector-ref-trusted vector 1)
    (consent-datum-object-revision vector)
    events))
  (set! events '())
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (let ((phase (if reentering? 'inner 'outer)))
       (set! events
             (cons
              (list
               phase
               operation
               old
               new
               (consent-datum-vector-ref-trusted object slot)
               (consent-datum-object-revision object))
              events))
       (if (not reentering?)
           (begin
             (set! reentering? #t)
             (consent-datum-vector-set-trusted!
              active-heap object slot 'inner)
             (set! reentering? #f)))
       #t)))
  (consent-datum-vector-set-trusted! heap vector 0 'outer)
  (test-equal
   'trusted-vector-reentrant-hook-order
   '((outer vector-set! after outer after 2)
     (inner vector-set! after inner after 2))
   (reverse events))
  (test-equal
   'trusted-vector-reentrant-revision
   '(outer 4)
   (list
    (consent-datum-vector-ref-trusted vector 0)
    (consent-datum-object-revision vector)))
  (let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (library
          (resolve-library
           '(consent datum)
           context
           (consent-make-empty-environment)))
         (internal-exports
          (map library-binding-name (library-exports library))))
    ;; The source exports remain available to statically linked core code, as
    ;; exercised above. The manifest must filter the unchecked helpers from
    ;; even an explicitly authorized interpreted internal import.
    (test-assert
     'trusted-vector-kept-off-interpreted-surface
     (and
      (not (memq 'consent-datum-vector-length-trusted exports))
      (not (memq 'consent-datum-vector-ref-trusted exports))
      (not (memq 'consent-datum-vector-set-trusted! exports))
      (not (memq 'consent-datum-car-trusted exports))
      (not (memq 'consent-datum-cdr-trusted exports))
      (not (memq 'consent-datum-string-length-trusted exports))
      (not (memq 'consent-datum-string-ref-host-trusted exports))
      (not (memq 'consent-datum-make-internal-slots exports))
      (not (memq 'consent-datum-internal-slot-ref exports))
      (not (memq 'consent-datum-internal-slot-set! exports))
      (not
       (memq 'consent-datum-vector-length-trusted internal-exports))
      (not (memq 'consent-datum-vector-ref-trusted internal-exports))
      (not
       (memq 'consent-datum-vector-set-trusted! internal-exports))
      (not (memq 'consent-datum-car-trusted internal-exports))
      (not (memq 'consent-datum-cdr-trusted internal-exports))
      (not
       (memq 'consent-datum-string-length-trusted internal-exports))
      (not
       (memq 'consent-datum-string-ref-host-trusted internal-exports))
      (not
       (memq 'consent-datum-make-internal-slots internal-exports))
      (not
       (memq 'consent-datum-internal-slot-ref internal-exports))
      (not
       (memq 'consent-datum-internal-slot-set! internal-exports)))))))

(datum-direct-host-case
 'owned-bytevector-mutation-order-and-abort
 '(portable runtime datum mutation performance)
(let* ((heap (consent-make-datum-heap))
       (bytes (consent-datum-make-bytevector heap 1 7))
       (event #f)
       (raises?
        (lambda (thunk)
          (guard (condition (else #t))
            (thunk)
            #f))))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! event
           (list
            (eq? active-heap heap)
            operation
            slot
            old
            new
            (consent-datum-bytevector-u8-ref object slot)
            (consent-datum-object-revision object)))
     #t))
  (consent-datum-bytevector-u8-set! heap bytes 0 9)
  (test-equal
   'bytevector-hook-observes-old-state
   '(#t bytevector-u8-set! 0 7 9 7 0)
   event)
  (test-equal
   'bytevector-write-advances-revision
   '(9 1)
   (list
    (consent-datum-bytevector-u8-ref bytes 0)
    (consent-datum-object-revision bytes)))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! event
           (list
            (eq? active-heap heap)
            operation
            slot
            old
            new
            (consent-datum-bytevector-u8-ref object slot)
            (consent-datum-object-revision object)))
     (error "test bytevector mutation hook abort")))
  (test-assert
   'bytevector-hook-can-abort
   (raises?
    (lambda ()
      (consent-datum-bytevector-u8-set! heap bytes 0 11))))
  (test-equal
   'bytevector-hook-abort-leaves-state
   '(9 1 (#t bytevector-u8-set! 0 9 11 9 1))
   (list
    (consent-datum-bytevector-u8-ref bytes 0)
    (consent-datum-object-revision bytes)
    event))))

(testing-registry-case
 'owned-fork-metadata '(portable runtime datum checkpoint)
(let ((heap (consent-make-datum-heap)))
  (consent-datum-heap-owner-set! heap 'branch-a)
  (let ((first (consent-datum-cons heap 'value '())))
    (consent-datum-heap-owner-set! heap 'branch-b)
    (let ((second (consent-datum-make-vector heap 0 #f)))
      (consent-datum-object-traversal-set! first '(visited))
      (test-equal 'heap-generation 0
                  (consent-datum-heap-generation heap))
      (test-equal 'object-generations
                  '(0 0)
                  (list (consent-datum-object-generation first)
                        (consent-datum-object-generation second)))
      (test-equal 'heap-owner-is-derived-by-existing-objects
                  '(branch-b branch-b)
                  (list (consent-datum-object-owner first)
                        (consent-datum-object-owner second)))
      (test-assert 'fresh-object-ids-are-distinct
                   (not (= (consent-datum-object-id first)
                           (consent-datum-object-id second))))
      (test-assert 'fresh-objects-are-mutable
                   (and (consent-datum-object-mutable? first)
                        (consent-datum-object-mutable? second)))
      (test-equal 'object-traversal-metadata
                  '(visited)
                  (consent-datum-object-traversal first))))))

(datum-direct-host-case
 'owned-frozen-runtime-image-boundary
 '(portable runtime datum identity mutation graph)
(let* ((heap (consent-make-datum-heap))
       (target (consent-make-datum-heap))
       (foreign-heap (consent-make-datum-heap))
       (foreign (consent-datum-cons foreign-heap 'foreign 'leaf))
       (text (consent-datum-string-from-host heap "image"))
       (bytes (consent-datum-bytevector-from-host heap (bytevector 1 2)))
       (root (consent-datum-cons heap 'root #f))
       (children
        (consent-datum-vector-from-host-elements
         heap (vector root text bytes)))
       (orphan (consent-datum-cons heap 'orphan 'leaf))
       (raises?
        (lambda (thunk)
          (guard (condition (else #t))
            (thunk)
            #f))))
  (consent-datum-set-cdr! heap root children)
  (consent-datum-object-source-metadata-set! root 'frozen-source)
  (test-assert
   'runtime-image-validation-failure-leaves-heap-mutable
   (and
    (raises?
     (lambda ()
       (consent-datum-heap-freeze! heap (list (vector 'raw)))))
    (raises?
     (lambda ()
       (consent-datum-heap-freeze! heap (list foreign))))
    (not (consent-datum-heap-frozen? heap))
    (consent-datum-object-mutable? root)))
  (test-assert
   'runtime-image-freeze-is-idempotent
   (eq? heap
        (consent-datum-heap-freeze!
         (consent-datum-heap-freeze! heap (list root))
         (list orphan))))
  (test-assert
   'runtime-image-certifies-only-reachable-owned-objects
   (and
    (consent-datum-heap-frozen? heap)
    (consent-datum-object-shareable? root)
    (consent-datum-object-shareable? children)
    (consent-datum-object-shareable? text)
    (consent-datum-object-shareable? bytes)
    (not (consent-datum-object-shareable? orphan))
    (not (consent-datum-object-shareable? 'scalar))))
  (test-equal
   'runtime-image-preserves-cold-metadata
   '(1 frozen-source)
   (list
    (consent-datum-object-revision root)
    (consent-datum-object-source-metadata root)))
  (test-assert
   'frozen-heap-rejects-all-content-and-heap-mutation
   (and
    (not (consent-datum-object-mutable? root))
    (not (consent-datum-object-mutable? orphan))
    (raises? (lambda () (consent-datum-set-car! heap root 'changed)))
    (raises?
     (lambda ()
       (consent-datum-vector-set! heap children 0 'changed)))
    (raises?
     (lambda ()
       (consent-datum-string-set-host! heap text 0 #\I)))
    (raises?
     (lambda ()
       (consent-datum-bytevector-u8-set! heap bytes 0 9)))
    (raises? (lambda () (consent-datum-cons heap 'new 'pair)))
    (raises? (lambda () (consent-datum-heap-owner-set! heap 'branch)))
    (raises?
     (lambda ()
       (consent-datum-heap-mutation-hook-set! heap #f)))
    (raises?
     (lambda ()
       (consent-datum-object-source-metadata-set! root 'changed)))))
  (let* ((reused (consent-datum-import target root (lambda (value) value)))
         (thawed
          (consent-datum-import target orphan (lambda (value) value)))
         (exported
          (consent-datum-export reused (lambda (value) value))))
    (test-assert
     'runtime-image-import-reuses-certified-identity
     (and
      (consent-datum-same? reused root)
      (consent-datum-same?
       reused
       (consent-datum-vector-ref (consent-datum-cdr reused) 0))))
    (test-assert
     'runtime-image-import-copies-uncertified-frozen-object
     (and
      (not (consent-datum-same? thawed orphan))
      (= (consent-datum-object-heap-id thawed)
         (consent-datum-heap-id target))
      (consent-datum-object-mutable? thawed)))
    (test-assert
     'runtime-image-export-preserves-cycle
     (eq? exported (vector-ref (cdr exported) 0))))))

(datum-direct-host-case
 'owned-call-scoped-map-restoration
 '(portable runtime datum graph performance)
(let* ((heap (consent-make-datum-heap))
       (object (consent-datum-cons heap 'head 'tail))
       (released-map #f))
  (consent-datum-object-traversal-set! object '(public-traversal))
  (call-with-consent-datum-object-map
   (lambda (outer)
     (set! released-map outer)
     (consent-datum-object-map-set! outer object 'outer)
     (call-with-consent-datum-object-map
      (lambda (inner)
        (consent-datum-object-map-set! inner object 'inner)
        (test-equal 'nested-map-inner-entry
                    'inner
                    (consent-datum-object-map-ref inner object #f))
        (test-equal 'nested-map-hides-outer-entry
                    'absent
                    (consent-datum-object-map-ref outer object 'absent))))
     (test-equal 'nested-map-restores-outer-entry
                 'outer
                 (consent-datum-object-map-ref outer object #f))))
  (test-assert
   'released-map-rejects-post-scope-lookup
   (guard (condition (else #t))
     (consent-datum-object-map-ref released-map object #f)
     #f))
  (call-with-consent-datum-object-map
   (lambda (fresh)
     (test-equal 'released-map-entry-is-absent
                 'absent
                 (consent-datum-object-map-ref fresh object 'absent))))
  (let ((outer (consent-make-datum-object-map))
        (inner (consent-make-datum-object-map)))
    (consent-datum-object-map-set! outer object 'outer)
    (consent-datum-object-map-set! inner object 'inner)
    (consent-datum-object-map-release! outer)
    (test-equal 'explicit-out-of-order-release-keeps-inner
                'inner
                (consent-datum-object-map-ref inner object #f))
    (consent-datum-object-map-release! inner)
    (call-with-consent-datum-object-map
     (lambda (fresh)
       (test-equal 'explicit-release-restores-empty-header
                   'absent
                   (consent-datum-object-map-ref fresh object 'absent)))))
  (test-equal 'map-does-not-alias-public-traversal-metadata
              '(public-traversal)
              (consent-datum-object-traversal object))
  (let ((captured #f))
    (guard (condition (else (set! captured condition)))
      (call-with-consent-datum-object-map
       (lambda (map)
         (consent-datum-object-map-set! map object 'temporary)
         (error "forced datum-object map unwind"))))
    (test-assert 'datum-map-test-error-was-raised captured)
    (test-equal 'exception-cleanup-preserves-public-traversal
                '(public-traversal)
                (consent-datum-object-traversal object)))
  (call-with-consent-datum-object-map
   (lambda (fresh)
     (test-equal 'exception-cleanup-restores-object-header
                 'absent
                 (consent-datum-object-map-ref fresh object 'absent))))
  (test-assert
   'closed-map-continuation-reentry-fails-closed
   (datum-map-continuation-reentry-condition object))))

(datum-direct-host-case
 'owned-residency-accounting-and-release
 '(portable runtime datum graph performance)
(let ((retained #f))
  (let* ((observation
          (call-with-datum-residency-stats
           (lambda ()
             (let* ((first (cons 'first #f))
                    (second (cons 'second #f))
                    (third (cons 'third first))
                    (heap (consent-make-datum-heap)))
               (set-cdr! first second)
               (set-cdr! second third)
               (let ((root (consent-datum-import heap first)))
                 (consent-datum-object-source-metadata-set! root 'source)
                 (consent-datum-object-source-metadata-set! root #f)
                 (consent-datum-object-traversal-set! root 'visited)
                 (consent-datum-object-traversal-set! root #f)
                 (call-with-consent-datum-object-map
                  (lambda (map)
                    (consent-datum-object-map-set! map root 'root)))
                 (let ((constructed
                        (consent-call-with-datum-construction
                         heap
                         (lambda (make-shell fill-slot! fixup-slot!)
                           (let ((pair (make-shell 'pair 2)))
                             (fill-slot! pair 0 'constructed)
                             (fill-slot! pair 1 '())
                             pair)))))
                   (set! retained
                         (vector
                          root constructed (consent-datum-export root)))))))))
         (stats (vector-ref observation 1))
         (balanced-categories
          '(construction-marker
            construction-index-slot
            traversal-sidecar-page
            map-sidecar-page
            source-sidecar-page
            phase-map-page
            graph-map-entry
            import-host-memo-entry
            import-work-entry
            export-owned-memo-entry
            export-work-entry)))
    (test-assert
     'residency-tracker-closes-after-dynamic-scope
     (and (not (cadr (assq 'active (cdr stats)))) retained))
    (test-assert
     'transient-residency-categories-balance
     (let loop ((rest balanced-categories))
       (or
        (null? rest)
        (let* ((category (car rest))
               (allocations
                (datum-residency-stat stats category 'allocations)))
          (and (> allocations 0)
               (= allocations
                  (datum-residency-stat stats category 'releases))
               (= 0 (datum-residency-stat stats category 'live))
               (loop (cdr rest)))))))
    (test-equal
     'residency-owned-pair-census
     '(4 0 4 4)
     (map
      (lambda (field)
        (datum-residency-stat stats 'owned-pair field))
      '(allocations releases live high-water)))
    (test-equal
     'residency-result-shell-census
     '((3 0 3 3) (3 0 3 3))
     (map
      (lambda (category)
        (map
         (lambda (field) (datum-residency-stat stats category field))
         '(allocations releases live high-water)))
     '(import-result-shell export-result-shell))))))

(datum-direct-host-case
 'owned-residency-error-and-nonlocal-release
 '(portable runtime datum graph continuation)
(let ((error-stats #f)
      (nonlocal-stats #f)
      (construction-stats #f)
      (captured #f))
  (define (balanced? stats category)
    "Report whether STATS released every allocated CATEGORY unit."
    (let ((allocated
            (datum-residency-stat stats category 'allocations)))
      (and (> allocated 0)
           (= allocated
              (datum-residency-stat stats category 'releases))
           (= 0 (datum-residency-stat stats category 'live)))))
  (set! error-stats
        (vector-ref
         (call-with-datum-residency-stats
          (lambda ()
            (guard (condition (else (set! captured condition)))
              (consent-datum-import
               (consent-make-datum-heap)
               '(before boom after)
               (lambda (value)
                 (if (eq? value 'boom)
                     (error "forced import leaf failure")
                     value))))))
         1))
  (call/cc
   (lambda (leave)
     (let ((token (consent-datum-residency-tracking-start!)))
       (dynamic-wind
        (lambda () #t)
        (lambda ()
          (consent-datum-import
           (consent-make-datum-heap)
           '(first second third)
           (lambda (value) value)
           (lambda (target source) (leave 'escaped))))
        (lambda ()
          (set! nonlocal-stats
                (finish-datum-residency-stats! token)))))))
  (set! construction-stats
        (vector-ref
         (call-with-datum-residency-stats
          (lambda ()
            (guard (condition (else #t))
              (consent-call-with-datum-construction
               (consent-make-datum-heap)
               (lambda (make-shell fill-slot! fixup-slot!)
                 (let ((pair (make-shell 'pair 2)))
                   (fill-slot! pair 0 'only-one-slot)
                   pair))))))
         1))
  (test-assert 'residency-import-error-was-raised captured)
  (test-assert
   'residency-import-error-releases-temporary-roots
   (and
    (balanced? error-stats 'import-host-memo-entry)
    (balanced? error-stats 'import-work-entry)))
  (test-assert
   'residency-import-nonlocal-exit-releases-temporary-roots
   (and
    (balanced? nonlocal-stats 'import-host-memo-entry)
    (balanced? nonlocal-stats 'import-work-entry)))
  (test-assert
   'residency-construction-error-releases-temporary-roots
   (and
    (balanced? construction-stats 'construction-marker)
    (balanced? construction-stats 'construction-index-slot)))))

(testing-registry-case
 'owned-residency-scalar-boundary-accounting
 '(portable runtime datum graph performance)
(let* ((observation
        (call-with-datum-residency-stats
         (lambda ()
           (let* ((heap (consent-make-datum-heap))
                  (root (consent-datum-import heap '(first second third))))
             (consent-datum-export root)))))
       (stats (vector-ref observation 1)))
  (define (balanced? category)
    "Report whether STATS released every allocated CATEGORY unit."
    (let ((allocated
           (datum-residency-stat stats category 'allocations)))
      (and (> allocated 0)
           (= allocated
              (datum-residency-stat stats category 'releases))
           (= 0 (datum-residency-stat stats category 'live)))))
  (test-assert
   'residency-scalar-boundary-temporary-owners-balance
   (and
    (balanced? 'import-host-memo-entry)
    (balanced? 'import-work-entry)
    (balanced? 'export-owned-memo-entry)
    (balanced? 'export-work-entry)))
  (test-assert
   'residency-scalar-boundary-result-shells-remain-owned
   (and
    (> (datum-residency-stat
        stats 'import-result-shell 'live)
       0)
    (> (datum-residency-stat
        stats 'export-result-shell 'live)
       0)))))

(datum-direct-host-case
 'owned-call-scoped-map-fixed-probe-work
 '(portable runtime datum graph performance)
(let* ((heap (consent-make-datum-heap))
       (count 24000)
       (objects (make-vector count #f))
       (collision-family '()))
  (let allocate ((index 0))
    (if (< index count)
        (begin
          (vector-set!
           objects index (consent-datum-make-vector heap 0 #f))
          (allocate (+ index 1)))))
  (let ((bucket (old-datum-object-map-hash (vector-ref objects 0) 128)))
    (let select ((index 0) (family '()) (remaining 128))
      (cond
       ((= remaining 0)
        (set! collision-family family)
        (test-equal
         'retired-hash-collision-family-size 128 (length family))
        (test-assert
         'retired-hash-family-shares-one-bucket
         (let check ((rest family))
           (or (null? rest)
               (and (= bucket
                       (old-datum-object-map-hash (car rest) 128))
                    (check (cdr rest)))))))
       ((= index count)
        (test-assert 'retired-hash-collision-family-found #f))
       (else
        (let ((object (vector-ref objects index)))
          (select
           (+ index 1)
           (if (= bucket (old-datum-object-map-hash object 128))
               (cons object family)
               family)
           (if (= bucket (old-datum-object-map-hash object 128))
               (- remaining 1)
               remaining))))))
  (call-with-consent-datum-object-map
   (lambda (map)
     (let insert ((index 0) (probes 0))
       (if (= index count)
           (test-equal 'datum-map-24k-insert-probes count probes)
           (let ((object (vector-ref objects index)))
             (consent-datum-object-map-set! map object index)
             (insert
              (+ index 1)
              (+ probes
                 (consent-datum-object-map-probe-count map object))))))
     (let lookup ((index 0) (probes 0) (correct? #t))
       (if (= index count)
           (begin
             (test-equal 'datum-map-24k-lookup-probes count probes)
             (test-assert 'datum-map-24k-values correct?))
           (let ((object (vector-ref objects index)))
             (lookup
              (+ index 1)
              (+ probes
                 (consent-datum-object-map-probe-count map object))
             (and correct?
                   (= index
                      (consent-datum-object-map-ref
                       map object -1)))))))
     (let collision-probes ((rest collision-family) (probes 0))
       (if (null? rest)
           (test-equal
            'retired-collision-family-fixed-probes 128 probes)
           (collision-probes
            (cdr rest)
            (+ probes
               (consent-datum-object-map-probe-count
                map (car rest)))))))))))

(datum-direct-host-case
 'owned-lexical-cell-mutation-gateway '(portable runtime datum mutation)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (environment (consent-make-empty-environment))
       (events '()))
  (environment-define! environment 'binding 'before context)
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (observed-heap object operation slot old new)
     (set! events
           (cons (list (eq? observed-heap heap)
                       (consent-datum-object-kind object)
                       operation
                       slot
                       old
                       new)
                 events))
     #t))
  (environment-set! environment 'binding 'after context)
  (test-equal 'lexical-cell-value
              'after
              (cell-value (environment-cell environment 'binding)))
  (test-equal 'lexical-cell-mutation-event
              '((#t cell binding-set! 0 before after))
              events)))

(datum-direct-host-case
 'owned-cell-cache-coherence '(portable runtime datum mutation performance)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (success-cell (make-cell 'before context))
       (success-slots #f)
       (success-event #f)
       (abort-cell (make-cell 'before context))
       (abort-slots #f)
       (abort-event #f)
       (reentrant-cell (make-cell 'before context))
       (reentrant-slots #f)
       (reentrant? #f)
       (reentrant-events '())
       (lazy-cell (make-cell 'bootstrap))
       (lazy-slots #f)
       (lazy-event #f)
       (raises?
        (lambda (thunk)
          (guard (condition (else #t))
            (thunk)
            #f))))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! success-slots object)
     (set! success-event
           (list
            (eq? active-heap heap)
            operation
            slot
            old
            new
            (consent-datum-internal-slot-ref object slot)
            (cell-value success-cell)))
     #t))
  (context-cell-set! context success-cell 'binding-set! 'after)
  (test-equal
   'cell-cache-hook-sees-old-slot-and-value
   '(#t binding-set! 0 before after before before)
   success-event)
  (test-equal
   'cell-cache-success-keeps-slot-and-value-equal
   '(after after)
   (list
    (consent-datum-internal-slot-ref success-slots 0)
    (cell-value success-cell)))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! abort-slots object)
     (set! abort-event
           (list
            operation
            slot
            old
            new
            (consent-datum-internal-slot-ref object slot)
            (cell-value abort-cell)))
     (error "test cell mutation hook abort")))
  (test-assert
   'cell-cache-hook-can-abort
   (raises?
    (lambda ()
      (context-cell-set! context abort-cell 'binding-set! 'aborted))))
  (test-equal
   'cell-cache-abort-hook-sees-old-slot-and-value
   '(binding-set! 0 before aborted before before)
   abort-event)
  (test-equal
   'cell-cache-abort-keeps-slot-and-value-unchanged
   '(before before 0)
   (list
    (consent-datum-internal-slot-ref abort-slots 0)
    (cell-value abort-cell)
    (consent-datum-object-revision abort-slots)))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! reentrant-slots object)
     (let ((phase (if reentrant? 'inner 'outer)))
       (set! reentrant-events
             (cons
              (list
               phase
               old
               new
               (consent-datum-internal-slot-ref object slot)
               (cell-value reentrant-cell))
              reentrant-events))
       (if (not reentrant?)
           (begin
             (set! reentrant? #t)
             (context-cell-set!
              context reentrant-cell 'binding-set! 'inner)
             (set! reentrant? #f)
             (set! reentrant-events
                   (cons
                    (list
                     'outer-after-inner
                     (consent-datum-internal-slot-ref object slot)
                     (cell-value reentrant-cell))
                    reentrant-events))))
       #t)))
  (context-cell-set! context reentrant-cell 'binding-set! 'outer)
  (test-equal
   'cell-cache-reentrant-hook-order-and-coherence
   '((outer before outer before before)
     (inner before inner before before)
     (outer-after-inner inner inner))
   (reverse reentrant-events))
  (test-equal
   'cell-cache-reentrant-final-slot-and-value
   '(outer outer 2)
   (list
    (consent-datum-internal-slot-ref reentrant-slots 0)
    (cell-value reentrant-cell)
    (consent-datum-object-revision reentrant-slots)))
  (consent-datum-heap-mutation-hook-set!
   heap
   (lambda (active-heap object operation slot old new)
     (set! lazy-slots object)
     (set! lazy-event
           (list
            old
            new
            (consent-datum-internal-slot-ref object slot)
            (cell-value lazy-cell)))
     #t))
  (context-cell-set! context lazy-cell 'binding-set! 'promoted)
  (test-equal
   'cell-cache-lazy-promotion-hook-sees-old-values
   '(bootstrap promoted bootstrap bootstrap)
   lazy-event)
  (test-equal
   'cell-cache-lazy-promotion-keeps-slot-and-value-equal
   '(promoted promoted)
   (list
    (consent-datum-internal-slot-ref lazy-slots 0)
    (cell-value lazy-cell)))))

(testing-registry-case
 'owned-string-and-bytevector-mutation '(portable runtime datum mutation)
(let* ((heap (consent-make-datum-heap))
       (string (consent-datum-string-from-host heap "heap"))
       (bytes (consent-datum-bytevector-from-host
               heap
               (bytevector 1 2 3))))
  (consent-datum-string-set-host! heap string 0 #\s)
  (consent-datum-bytevector-u8-set! heap bytes 1 9)
  (test-equal 'owned-string-mutation
              "seap"
              (consent-datum-string->host string))
  (test-equal 'owned-bytevector-mutation
              9
              (consent-datum-bytevector-u8-ref bytes 1))
  (test-equal 'independent-mutation-revisions
              '(1 1)
              (list (consent-datum-object-revision string)
                    (consent-datum-object-revision bytes)))))

(testing-registry-case
 'owned-mixed-cycle-and-sharing '(portable runtime datum graph mutation)
(let* ((source-pair (cons #f '()))
       (source-vector (vector source-pair source-pair))
       (heap (consent-make-datum-heap)))
  (set-car! source-pair source-vector)
  (set-cdr! source-pair source-pair)
  (let* ((owned-pair (consent-datum-import heap source-pair))
         (owned-vector (consent-datum-car owned-pair)))
    (test-assert 'pair-cycle-preserved
                 (consent-datum-same?
                  owned-pair
                  (consent-datum-cdr owned-pair)))
    (test-assert 'pair-vector-sharing-preserved
                 (and (consent-datum-vector? owned-vector)
                      (consent-datum-same?
                       owned-pair
                       (consent-datum-vector-ref owned-vector 0))
                      (consent-datum-same?
                       (consent-datum-vector-ref owned-vector 0)
                       (consent-datum-vector-ref owned-vector 1)))))))

(testing-registry-case
 'owned-cross-heap-import '(portable runtime datum graph)
(let* ((source-heap (consent-make-datum-heap))
       (target-heap (consent-make-datum-heap))
       (shared (consent-datum-cons source-heap 'value '()))
       (source (consent-datum-make-vector source-heap 2 shared)))
  (consent-datum-vector-set! source-heap source 1 shared)
  (let* ((copy (consent-datum-import target-heap source))
         (left (consent-datum-vector-ref copy 0))
         (right (consent-datum-vector-ref copy 1)))
    (test-assert 'cross-heap-root-is-fresh
                 (not (consent-datum-same? source copy)))
    (test-assert 'cross-heap-sharing-preserved
                 (consent-datum-same? left right))
    (consent-datum-set-car! target-heap left 'changed)
    (test-equal 'target-copy-is-mutable
                'changed
                (consent-datum-car right))
    (test-equal 'source-heap-isolated
                'value
                (consent-datum-car shared)))))

(testing-registry-case
 'owned-graph-export '(portable runtime datum graph boundary)
(let* ((heap (consent-make-datum-heap))
       (pair (consent-datum-cons heap 'value '()))
       (vector (consent-datum-make-vector heap 2 pair)))
  (consent-datum-vector-set! heap vector 1 pair)
  (consent-datum-set-cdr! heap pair vector)
  (let* ((exported (consent-datum-export vector))
         (left (vector-ref exported 0))
         (right (vector-ref exported 1)))
    (test-assert 'export-sharing-preserved (eq? left right))
    (test-assert 'export-cycle-preserved (eq? (cdr left) exported)))))

(testing-registry-case
 'owned-graph-copy-is-iterative
 '(portable runtime datum graph boundary performance)
(let* ((depth 24000)
       (first (cons 0 '()))
       (last
        (let loop ((index 1) (tail first))
          (if (= index depth)
              tail
              (let ((next (cons index '())))
                (set-cdr! tail next)
                (loop (+ index 1) next)))))
       (source-root (vector first first))
       (source-heap (consent-make-datum-heap))
       (target-heap (consent-make-datum-heap)))
  (set-cdr! last first)
  (let* ((source-owned (consent-datum-import source-heap source-root))
         (target-owned (consent-datum-import target-heap source-owned))
         (exported (consent-datum-export target-owned))
         (source-chain (consent-datum-vector-ref source-owned 0))
         (target-chain (consent-datum-vector-ref target-owned 0))
         (exported-chain (vector-ref exported 0)))
    (test-assert
     'deep-host-import-preserves-sharing
     (consent-datum-same?
      source-chain (consent-datum-vector-ref source-owned 1)))
    (test-assert
     'deep-cross-heap-copy-is-fresh
     (and
      (not (consent-datum-same? source-owned target-owned))
      (not (consent-datum-same? source-chain target-chain))))
    (test-assert
     'deep-cross-heap-copy-preserves-sharing
     (consent-datum-same?
      target-chain (consent-datum-vector-ref target-owned 1)))
    (test-assert
     'deep-cross-heap-copy-preserves-cycle
     (let loop ((remaining depth) (current target-chain))
       (if (= remaining 0)
           (consent-datum-same? current target-chain)
           (and
            (consent-datum-pair? current)
            (loop (- remaining 1) (consent-datum-cdr current))))))
    (test-assert
     'deep-export-preserves-sharing
     (eq? exported-chain (vector-ref exported 1)))
    (test-assert
     'deep-export-preserves-cycle
     (let loop ((remaining depth) (current exported-chain))
       (if (= remaining 0)
           (eq? current exported-chain)
           (and (pair? current)
                (loop (- remaining 1) (cdr current)))))))))

(datum-direct-host-case
 'owned-graph-copy-reuse-hooks
 '(portable runtime datum graph boundary performance)
(let* ((heap (consent-make-datum-heap))
       (host-shared (cons 'host 'shared))
       (host-root (vector host-shared host-shared))
       (owned-reuse (consent-datum-cons heap 'owned 'reuse))
       (import-reuse-calls 0)
       (import-source-copies 0)
       (import-root-ready? #f)
       (imported
        (consent-datum-import
         heap
         host-root
         (lambda (item) item)
         (lambda (target source)
           (set! import-source-copies (+ import-source-copies 1))
           (if (eq? source host-root)
               (set! import-root-ready?
                     (and
                      (consent-datum-same?
                       owned-reuse (consent-datum-vector-ref target 0))
                      (consent-datum-same?
                       owned-reuse (consent-datum-vector-ref target 1)))))
           target)
         (lambda (source absent)
           (set! import-reuse-calls (+ import-reuse-calls 1))
           (if (eq? source host-shared) owned-reuse absent))))
       (owned-shared (consent-datum-cons heap 'export 'source))
       (owned-root (consent-datum-make-vector heap 2 owned-shared))
       (host-reuse (cons 'host 'reuse))
       (export-reuse-calls 0)
       (export-source-copies 0)
       (export-root-ready? #f))
  (consent-datum-vector-set! heap owned-root 1 owned-shared)
  (let ((exported
         (consent-datum-export
          owned-root
          (lambda (item) item)
          (lambda (target source)
            (set! export-source-copies (+ export-source-copies 1))
            (if (consent-datum-same? source owned-root)
                (set! export-root-ready?
                      (and (eq? host-reuse (vector-ref target 0))
                           (eq? host-reuse (vector-ref target 1)))))
            target)
          (lambda (source absent)
            (set! export-reuse-calls (+ export-reuse-calls 1))
            (if (consent-datum-same? source owned-shared)
                host-reuse
                absent)))))
    (test-assert
     'import-reuse-target-is-memoized
     (and
      (consent-datum-same?
       owned-reuse (consent-datum-vector-ref imported 0))
      (consent-datum-same?
       owned-reuse (consent-datum-vector-ref imported 1))))
    (test-equal 'import-reuse-hook-runs-once-per-source
                2
                import-reuse-calls)
    (test-equal 'import-copy-source-skips-reused-target
                1
                import-source-copies)
    (test-assert 'import-copy-source-runs-after-edges import-root-ready?)
    (test-assert
     'export-reuse-target-is-memoized
     (and (eq? host-reuse (vector-ref exported 0))
          (eq? host-reuse (vector-ref exported 1))))
    (test-equal 'export-reuse-hook-runs-once-per-source
                2
                export-reuse-calls)
    (test-equal 'export-copy-source-skips-reused-target
                1
                export-source-copies)
    (test-assert 'export-copy-source-runs-after-edges export-root-ready?))))

(datum-direct-host-case
 'owned-import-reuses-false-target
 '(portable runtime datum graph boundary performance)
(let* ((heap (consent-make-datum-heap))
       (shared (cons 'ignored 'ignored))
       (root (vector shared shared))
       (reuse-calls 0)
       (copy-calls 0)
       (raises?
        (lambda (thunk)
          (guard (condition (else #t))
            (thunk)
            #f)))
       (imported
        (consent-datum-import
         heap
         root
         (lambda (item) item)
         (lambda (target source)
           (set! copy-calls (+ copy-calls 1))
           target)
         (lambda (source absent)
           (set! reuse-calls (+ reuse-calls 1))
           (if (eq? source shared) #f absent)))))
  (test-equal
   'false-reuse-target-is-memoized
   '(#f #f)
   (list
    (consent-datum-vector-ref imported 0)
    (consent-datum-vector-ref imported 1)))
  (test-equal 'false-reuse-hook-runs-once-per-source 2 reuse-calls)
  (test-equal 'false-reuse-skips-source-copy 1 copy-calls)
  (test-assert
   'ordinary-import-still-rejects-false-leaf-converter
   (raises?
    (lambda ()
      (consent-datum-import heap (cons 'leaf 'tail) #f))))
  (test-assert
   'ordinary-import-still-rejects-false-reuse-callback
   (raises?
    (lambda ()
      (consent-datum-import
       heap
       (cons 'leaf 'tail)
       (lambda (item) item)
       (lambda (target source) target)
       #f))))))

(datum-direct-host-case
 'owned-counted-import-host-cycle-and-invalid
 '(portable runtime datum graph boundary performance)
(let* ((heap (consent-make-datum-heap))
       (source-pair (cons 'valid #f))
       (source-string (string-copy "ab"))
       (source-bytes (bytevector 1 2))
       (source-root
        (vector
         source-pair
         source-pair
         source-string
         source-string
         source-bytes
         source-bytes
         'bad))
       (owned #f)
       (node-count #f)
       (invalid-leaf? #f)
       (first-invalid-leaf #f)
       (leaf-events '())
       (copy-events '())
       (callbacks-ready? #t))
  (set-cdr! source-pair source-root)
  (call-with-values
   (lambda ()
     (consent-datum-import-with-node-count
      heap
      source-root
      (lambda (item)
        (set! leaf-events (cons item leaf-events))
        (not (eq? item 'bad)))
      (lambda (target source)
        (let ((label
               (cond
                ((eq? source source-pair) 'pair)
                ((eq? source source-string) 'string)
                ((eq? source source-bytes) 'bytevector)
                ((eq? source source-root) 'vector)
                (else 'unexpected))))
          (set! copy-events (cons label copy-events))
          (cond
           ((eq? source source-pair)
            (set! callbacks-ready?
                  (and
                   callbacks-ready?
                   (eq? 'valid (consent-datum-car target))
                   (consent-datum-same?
                    target
                    (consent-datum-vector-ref
                     (consent-datum-cdr target) 0)))))
           ((eq? source source-root)
            (set! callbacks-ready?
                  (and
                   callbacks-ready?
                   (consent-datum-same?
                    (consent-datum-vector-ref target 0)
                    (consent-datum-vector-ref target 1))
                   (consent-datum-same?
                    (consent-datum-vector-ref target 2)
                    (consent-datum-vector-ref target 3))
                   (consent-datum-same?
                    (consent-datum-vector-ref target 4)
                    (consent-datum-vector-ref target 5)))))))
        target)))
   (lambda (result count invalid? invalid)
     (set! owned result)
     (set! node-count count)
     (set! invalid-leaf? invalid?)
     (set! first-invalid-leaf invalid)))
  (test-assert
   'counted-host-import-preserves-cycle-and-sharing
   (let ((pair (consent-datum-vector-ref owned 0)))
     (and
      (consent-datum-vector? owned)
      (consent-datum-same?
       pair (consent-datum-vector-ref owned 1))
      (consent-datum-same? owned (consent-datum-cdr pair))
      (consent-datum-same?
       (consent-datum-vector-ref owned 2)
       (consent-datum-vector-ref owned 3))
      (consent-datum-same?
       (consent-datum-vector-ref owned 4)
       (consent-datum-vector-ref owned 5)))))
  (test-equal 'counted-host-import-exact-node-count 10 node-count)
  (test-equal
   'counted-host-import-defers-first-invalid-leaf
   '(#t bad)
   (list invalid-leaf? first-invalid-leaf))
  (test-equal
   'counted-host-import-leaf-observation-order
   '(valid bad)
   (reverse leaf-events))
  (test-equal
   'counted-host-import-copy-callback-order
   '(pair string bytevector vector)
   (reverse copy-events))
  (test-assert
   'counted-host-import-callbacks-see-initialized-edges
   callbacks-ready?)
  (let* ((manifest-entry
          (consent-library-manifest-ref '(consent datum)))
         (exports (cadr (assq 'exports (cdr manifest-entry))))
         (context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (library
          (resolve-library
           '(consent datum)
           context
           (consent-make-empty-environment)))
         (internal-exports
          (map library-binding-name (library-exports library))))
    (test-assert
     'counted-import-kept-off-interpreted-surface
     (and
      (not
       (memq 'consent-datum-import-with-node-count exports))
      (not
       (memq
        'consent-datum-import-with-node-count internal-exports)))))))

(datum-direct-host-case
 'owned-counted-import-scalar-false-sentinel
 '(portable runtime datum graph boundary performance)
(let ((copy-calls 0))
  (call-with-values
   (lambda ()
     (consent-datum-import-with-node-count
      (consent-make-datum-heap)
      #f
      (lambda (item) #f)
      (lambda (target source)
        (set! copy-calls (+ copy-calls 1))
        target)))
   (lambda (owned count invalid? invalid)
     (test-equal
      'counted-scalar-false-has-separate-invalid-flag
      '(#f 1 #t #f)
      (list owned count invalid? invalid))))
  (test-equal 'counted-scalar-skips-copy-callback 0 copy-calls)))

(datum-direct-host-case
 'owned-counted-import-defers-non-atomic-wrapper
 '(portable runtime datum graph boundary performance)
(let* ((heap (consent-make-datum-heap))
       (type (consent-make-record-type 'box '(value)))
       (fields (consent-datum-make-vector heap 1 'value))
       (record (consent-make-record type fields))
       (source (vector record)))
  (call-with-values
   (lambda ()
     (consent-datum-import-with-node-count
      heap
      source
      (lambda (item) (not (consent-record? item)))
      (lambda (target original) target)))
   (lambda (owned count invalid? invalid)
     (test-assert
      'counted-non-atomic-wrapper-is-retained-for-fallback
      (eq? record (consent-datum-vector-ref owned 0)))
     (test-equal
      'counted-non-atomic-wrapper-returns-invalid-without-raising
      '(2 #t)
      (list count invalid?))
     (test-assert
      'counted-non-atomic-wrapper-is-first-invalid
      (eq? record invalid))))))

(datum-direct-host-case
 'owned-counted-import-same-heap-cycle
 '(portable runtime datum graph boundary performance)
(let* ((heap (consent-make-datum-heap))
       (string (consent-datum-string-from-host heap "ok"))
       (pair (consent-datum-cons heap string #f))
       (root (consent-datum-make-vector heap 3 pair))
       (copy-calls 0))
  (consent-datum-vector-set! heap root 1 pair)
  (consent-datum-vector-set! heap root 2 'bad)
  (consent-datum-set-cdr! heap pair root)
  (call-with-values
   (lambda ()
     (consent-datum-import-with-node-count
      heap
      root
      (lambda (item) (not (eq? item 'bad)))
      (lambda (target source)
        (set! copy-calls (+ copy-calls 1))
        target)))
   (lambda (owned count invalid? invalid)
     (test-assert
      'counted-same-heap-root-keeps-identity
      (consent-datum-same? root owned))
     (test-equal 'counted-same-heap-exact-node-count 6 count)
     (test-equal
      'counted-same-heap-reports-invalid
      '(#t bad)
      (list invalid? invalid))))
  (test-equal 'counted-same-heap-skips-copy-callbacks 0 copy-calls)))

(datum-direct-host-case
 'owned-counted-import-cross-heap-cycle
 '(portable runtime datum graph boundary performance)
(let* ((source-heap (consent-make-datum-heap))
       (target-heap (consent-make-datum-heap))
       (pair (consent-datum-cons source-heap 'leaf #f))
       (root (consent-datum-make-vector source-heap 2 pair))
       (copy-events '()))
  (consent-datum-vector-set! source-heap root 1 pair)
  (consent-datum-set-cdr! source-heap pair root)
  (call-with-values
   (lambda ()
     (consent-datum-import-with-node-count
      target-heap
      root
      (lambda (item) #t)
      (lambda (target source)
        (set! copy-events
              (cons
               (consent-datum-object-kind target)
               copy-events))
        target)))
   (lambda (owned count invalid? invalid)
     (let ((owned-pair (consent-datum-vector-ref owned 0)))
       (test-assert
        'counted-cross-heap-preserves-fresh-cycle-and-sharing
        (and
         (not (consent-datum-same? root owned))
         (consent-datum-same?
          owned-pair (consent-datum-vector-ref owned 1))
         (consent-datum-same? owned (consent-datum-cdr owned-pair))))
       (test-equal 'counted-cross-heap-exact-node-count 3 count)
       (test-equal
        'counted-cross-heap-valid-result
        '(#f #f)
        (list invalid? invalid)))))
  (test-equal
   'counted-cross-heap-copy-callback-order
   '(pair vector)
   (reverse copy-events))))

(datum-direct-host-case
 'datum-scalar-path-skips-owned-allocation
 '(portable runtime datum boundary performance)
(let* ((heap (consent-make-datum-heap))
       (before (consent-datum-cons heap 'before '()))
       (leaf-calls 0)
       (copy-calls 0)
       (reuse-calls 0)
       (converted
        (consent-datum-import
         heap
         'leaf
         (lambda (item)
           (set! leaf-calls (+ leaf-calls 1))
           'converted)
         (lambda (target source)
           (set! copy-calls (+ copy-calls 1))
           target)
         (lambda (source absent)
           (set! reuse-calls (+ reuse-calls 1))
           absent)))
       (same (consent-datum-import heap before))
       (exported (consent-datum-export 'host-leaf))
       (after (consent-datum-cons heap 'after '())))
  (test-equal 'scalar-import-uses-leaf-converter 'converted converted)
  (test-equal 'scalar-import-calls-leaf-once 1 leaf-calls)
  (test-equal 'scalar-import-skips-copy-source 0 copy-calls)
  (test-equal 'scalar-import-skips-reuse-hook 0 reuse-calls)
  (test-assert 'same-heap-import-returns-owned-object
               (consent-datum-same? before same))
  (test-equal 'scalar-export-returns-host-leaf 'host-leaf exported)
  (test-equal
   'scalar-and-same-heap-paths-allocate-no-owned-objects
   (+ (consent-datum-object-id before) 1)
   (consent-datum-object-id after))))

(datum-direct-host-case
 'native-call-preserves-owned-identity '(portable runtime datum boundary)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (pair (consent-datum-cons heap 'value '()))
       (vector (consent-datum-make-vector heap 1 pair)))
  (test-assert 'native-repeated-argument-identity
               (consent-call-native-library
                (lambda (left right) (eq? left right))
                context
                pair
                pair))
  (test-assert 'native-returned-root-identity
               (consent-datum-same?
                pair
                (consent-call-native-library
                 (lambda (value) value)
                 context
                 pair)))
  (test-assert 'native-returned-subobject-identity
               (consent-datum-same?
                pair
                (consent-call-native-library
                 (lambda (value) (vector-ref value 0))
                 context
                 vector)))
  (test-equal 'native-borrowed-results-charge-no-fresh-nodes
              0
              (context-value-nodes context))))

(testing-registry-case
 'native-runtime-egress-is-stack-safe
 '(portable runtime datum boundary graph performance)
(let* ((depth 24000)
       (leaf
        (native-symbol:consent-intern-symbol
         native-symbol:consent-default-symbol-table
         "deep-native-leaf"))
       (source (make-alternating-host-chain depth leaf)))
  (consent-datum-source-set! source 'deep-native-source)
  (let* ((before (consent-source-metadata-count))
         (converted (consent-runtime-datum->native-datum source))
         (after (consent-source-metadata-count)))
    (test-assert 'deep-native-egress-copies-changed-root
                 (not (eq? source converted)))
    (test-assert 'deep-native-egress-converts-leaf
                 (consent-host-symbol-eq?
                  'deep-native-leaf
                  (alternating-host-chain-leaf depth converted)))
    (test-equal 'deep-native-egress-does-not-retain-source-metadata
                #f
                (consent-datum-source converted))
    (test-equal 'deep-native-egress-adds-no-global-source-root
                0
                (- after before)))))

(datum-direct-host-case
 'native-callback-egress-is-stack-safe
 '(portable runtime datum boundary callback graph performance)
(let* ((depth 24000)
       (source
        (make-alternating-host-chain
         depth (consent-make-character (char->integer #\Q))))
       (callable
        (make-primitive-procedure
         'deep-native-callback-result
         (lambda (arguments callback-context) source)
         0
         0))
       (previous-applier (consent-native-applier-ref))
       (converted
        (dynamic-wind
         (lambda ()
           (consent-install-native-applier!
            (lambda (procedure arguments callback-context)
              ((primitive-procedure-function procedure)
               arguments
               callback-context))))
         (lambda () (consent-apply-callable callable '()))
         (lambda ()
           (consent-install-native-applier! previous-applier)))))
  (test-assert 'deep-native-callback-copies-changed-root
               (not (eq? source converted)))
  (test-equal 'deep-native-callback-converts-leaf
              #\Q
              (alternating-host-chain-leaf depth converted))))

(testing-registry-case
 'native-egress-unifies-mixed-cycles-and-sharing
 '(portable runtime datum boundary graph performance)
(let* ((heap (consent-make-datum-heap))
       (leaf
        (native-symbol:consent-intern-symbol
         native-symbol:consent-default-symbol-table
         "mixed-native-leaf"))
       (owned (consent-datum-make-vector heap 2 #f))
       (host (cons 'host #f)))
  (consent-datum-vector-set! heap owned 0 host)
  (consent-datum-vector-set! heap owned 1 leaf)
  (set-cdr! host owned)
  (let* ((converted (consent-runtime-datum->native-datum owned))
         (converted-host (vector-ref converted 0)))
    (test-assert 'mixed-native-owned-host-cycle
                 (eq? converted (cdr converted-host)))
    (test-assert 'mixed-native-host-node-is-copied
                 (not (eq? host converted-host)))
    (test-assert 'mixed-native-leaf-is-converted
                 (consent-host-symbol-eq?
                  'mixed-native-leaf
                  (vector-ref converted 1))))))

(datum-direct-host-case
 'native-no-bridge-result-import-charges-only-fresh-compounds
 '(portable runtime datum boundary callback budget)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (last-argument #f)
       (callable
        (make-primitive-procedure
         'native-no-bridge-budget-callback
         (lambda (arguments callback-context)
           (set! last-argument (car arguments))
           last-argument)
         1
         1))
       (wrapper (consent-datum-make-vector heap 1 callable))
       (already-owned (consent-datum-cons heap 'already-owned '()))
       (previous-applier (consent-native-applier-ref)))
  (dynamic-wind
   (lambda ()
     (consent-install-native-applier!
      (lambda (procedure arguments callback-context)
        ((primitive-procedure-function procedure)
         arguments
         callback-context))))
   (lambda ()
     ;; A standalone nested callback adapter has a context but no active
     ;; borrowed-graph bridge, so its host compound argument takes the
     ;; ordinary native-own-result import path.
     (let* ((native-wrapper
             (consent-native-argument-value wrapper context))
            (shim (vector-ref native-wrapper 0))
            (fast? (consent-identity-map-fast-backend?)))
       (if fast?
           (let* ((fresh-result (shim (cons 'fresh-callback '())))
                  (after-pair (context-value-nodes context))
                  (fresh-string (shim "fresh"))
                  (after-string (context-value-nodes context))
                  (fresh-bytes (shim (bytevector 1 2 3 4)))
                  (after-bytes (context-value-nodes context)))
             (test-assert 'native-no-bridge-fresh-result-is-host-pair
                          (pair? fresh-result))
             (test-equal 'native-no-bridge-fresh-result-node-charge
                         1
                         after-pair)
             (test-equal 'native-no-bridge-fresh-string-result
                         "fresh"
                         fresh-string)
             (test-equal 'native-no-bridge-fresh-string-node-charge
                         6
                         (- after-string after-pair))
             (test-equal 'native-no-bridge-fresh-bytevector-result
                         (bytevector 1 2 3 4)
                         fresh-bytes)
             (test-equal 'native-no-bridge-fresh-bytevector-node-charge
                         5
                         (- after-bytes after-string))
             (shim already-owned)
             (test-assert 'native-no-bridge-same-heap-result-is-reused
                          (consent-datum-same?
                           already-owned last-argument))
             (shim 11)
             (test-equal
              'native-no-bridge-owned-and-scalar-results-uncharged
              after-bytes
              (context-value-nodes context)))
           (let* ((owned-string
                   (consent-datum-string-from-host heap "owned"))
                  (owned-bytes
                   (consent-datum-bytevector-from-host
                    heap (bytevector 4 5)))
                  (other-heap (consent-make-datum-heap))
                  (cross-heap
                   (consent-datum-cons other-heap 'cross 'heap))
                  (large
                   (make-alternating-host-chain 4096 'large-leaf))
                  (shared-leaf (cons 'shared 'leaf))
                  (shared (vector shared-leaf shared-leaf))
                  (cycle (cons 'cycle '()))
                  (rejection-message
                   (lambda (value)
                     (guard
                      (condition
                       (else
                        (if (error-object? condition)
                            (error-object-message condition)
                            #f)))
                       (shim value)
                       #f))))
             (set-cdr! cycle cycle)
             (test-equal 'native-nohash-scalar-result 11 (shim 11))
             (test-assert 'native-nohash-same-heap-pair-result
                          (pair? (shim already-owned)))
             (test-assert 'native-nohash-same-heap-pair-is-reused
                          (consent-datum-same?
                           already-owned last-argument))
             (test-equal 'native-nohash-same-heap-string-result
                         "owned"
                         (shim owned-string))
             (test-equal 'native-nohash-same-heap-bytevector-result
                         (bytevector 4 5)
                         (shim owned-bytes))
             (test-equal 'native-nohash-supported-results-uncharged
                         0
                         (context-value-nodes context))
             (test-equal 'native-nohash-rejects-host-pair
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message (cons 'fresh 'pair)))
             (test-equal 'native-nohash-rejects-host-string
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message "fresh"))
             (test-equal 'native-nohash-rejects-host-bytevector
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message (bytevector 1 2)))
             (test-equal 'native-nohash-rejects-large-host-graph
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message large))
             (test-equal 'native-nohash-rejects-shared-host-graph
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message shared))
             (test-equal 'native-nohash-rejects-cyclic-host-graph
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message cycle))
             (test-equal 'native-nohash-rejects-cross-heap-graph
                         "native-result-import-unavailable: fast identity \
maps are required"
                         (rejection-message cross-heap))
             (test-equal 'native-nohash-rejections-are-uncharged
                         0
                         (context-value-nodes context))))))
   (lambda ()
     (consent-install-native-applier! previous-applier)))))

(testing-registry-case
 'native-egress-visits-shared-host-subgraph-once
 '(portable runtime datum boundary graph performance)
(let* ((heap (consent-make-datum-heap))
       (fanout 1024)
       (depth 4096)
       (leaf
        (native-symbol:consent-intern-symbol
         native-symbol:consent-default-symbol-table
         "shared-native-leaf"))
       (shared (make-alternating-host-chain depth leaf))
       (owned (consent-datum-make-vector heap fanout shared)))
  (consent-datum-source-set! shared 'shared-native-source)
  (let* ((before (consent-source-metadata-count))
         (converted (consent-runtime-datum->native-datum owned))
         (after (consent-source-metadata-count))
         (first (vector-ref converted 0)))
    (test-assert
     'shared-native-subgraph-keeps-one-result-identity
     (let loop ((index 1))
       (or (= index fanout)
           (and (eq? first (vector-ref converted index))
                (loop (+ index 1))))))
    ;; Context-free projection must not retain its ephemeral host mirror in
    ;; the process-global source index. Identity above and the scaling probe
    ;; cover one-pass traversal independently of provenance.
    (test-equal 'shared-native-subgraph-adds-no-global-source-root
                0
                (- after before))
    (test-assert 'shared-native-subgraph-converts-leaf
                 (consent-host-symbol-eq?
                  'shared-native-leaf
                  (alternating-host-chain-leaf depth first))))))

(datum-direct-host-case
 'native-bridge-unifies-mixed-cycle-without-retention
 '(portable runtime datum boundary graph performance)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (owned (consent-datum-make-vector heap 2 #f))
       (host (cons 'host #f)))
  (consent-datum-vector-set! heap owned 0 host)
  (consent-datum-vector-set!
   heap owned 1 (consent-make-character (char->integer #\B)))
  (set-cdr! host owned)
  (consent-datum-source-set! owned 'owned-bridge-source)
  (consent-datum-source-set! host 'host-bridge-source)
  (let* ((before (consent-source-metadata-count))
         (topology-valid?
          (consent-call-native-library
           (lambda (mirror)
             (let ((mirror-host (vector-ref mirror 0)))
               (and (eq? mirror (cdr mirror-host))
                    (char=? #\B (vector-ref mirror 1)))))
           context
           owned))
         (after (consent-source-metadata-count)))
    (test-assert 'native-bridge-mixed-cycle-is-valid topology-valid?)
    (test-equal 'borrowed-mirrors-enter-no-source-index
                0
                (- after before)))))

(datum-direct-host-case
 'native-scalar-calls-allocate-no-owned-graph
 '(portable runtime datum boundary performance)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (before (consent-datum-cons heap #t '()))
       (before-id (consent-datum-object-id before))
       (count 128)
       (results-valid?
        (let loop ((remaining count))
          (or
           (= remaining 0)
           (and
            (consent-call-native-library
             (lambda (value) value)
             context
             #t)
            (loop (- remaining 1))))))
       (after (consent-datum-cons heap #t '())))
  (test-assert 'native-scalar-results-remain-valid results-valid?)
  ;; Adjacent IDs prove that no temporary owned root vector entered the heap
  ;; during any scalar call. The bridge indexes are likewise lazy in source.
  (test-equal
   'native-scalar-calls-skip-owned-root-allocation
   (+ before-id 1)
   (consent-datum-object-id after))))

(datum-direct-host-case
 'native-call-writes-back-mutation '(portable runtime datum boundary mutation)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (pair (consent-datum-cons heap 'before '()))
       (vector (consent-datum-make-vector heap 1 'before))
       (string (consent-datum-string-from-host heap "heap"))
       (bytes (consent-datum-bytevector-from-host
               heap
               (bytevector 1 2 3))))
  (consent-call-native-library
   (lambda (native-pair native-vector native-string native-bytes)
     (set-car! native-pair 'after)
     (vector-set! native-vector 0 'after)
     (string-set! native-string 0 #\s)
     (bytevector-u8-set! native-bytes 1 9))
   context
   pair
   vector
   string
   bytes)
  (test-assert 'native-pair-writeback
               (consent-host-symbol-eq?
                'after
                (consent-datum-car pair)))
  (test-assert 'native-vector-writeback
               (consent-host-symbol-eq?
                'after
                (consent-datum-vector-ref vector 0)))
  (test-equal 'native-string-writeback
              "seap"
              (consent-datum-string->host string))
  (test-equal 'native-bytevector-writeback
              9
              (consent-datum-bytevector-u8-ref bytes 1))))

(datum-direct-host-case
 'native-call-imports-shared-cycle '(portable runtime datum boundary graph)
(let* ((context (new-eval-context '()))
       (result
        (consent-call-native-library
         (lambda ()
           (let* ((pair (cons 'value '()))
                  (vector (vector pair pair)))
             (set-cdr! pair vector)
             vector))
         context))
       (left (consent-datum-vector-ref result 0))
       (right (consent-datum-vector-ref result 1)))
  (test-assert 'native-result-sharing
               (consent-datum-same? left right))
  (test-assert 'native-result-cycle
               (consent-datum-same?
                result
                (consent-datum-cdr left)))
  ;; One fresh pair plus one two-slot vector: 1 + (1 + 2).
  (test-equal 'native-result-shared-cycle-node-charge
              4
              (context-value-nodes context))))

(datum-direct-host-case
 'native-known-mirror-result-reconciles-once
 '(portable runtime datum boundary graph mutation)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'before 'tail))
       (result
        (consent-call-native-library
         (lambda (mirror)
           (let ((fresh (cons 'fresh mirror)))
             (set-car! mirror fresh)
             (vector mirror fresh fresh)))
         context
         original))
       (returned (consent-datum-vector-ref result 0))
       (fresh (consent-datum-vector-ref result 1)))
  (test-assert 'native-result-reuses-known-mirror
               (consent-datum-same? original returned))
  (test-assert 'native-result-keeps-fresh-sharing
               (consent-datum-same?
                fresh
                (consent-datum-vector-ref result 2)))
  (test-assert 'native-result-and-writeback-share-fresh-node
               (consent-datum-same?
                fresh
                (consent-datum-car original)))
  (test-assert 'native-result-fresh-node-closes-known-cycle
               (consent-datum-same?
                original
                (consent-datum-cdr fresh)))
  ;; The borrowed original is uncharged. The one fresh pair and three-slot
  ;; result vector cost 1 + (1 + 3), even though result and writeback alias it.
  (test-equal 'native-result-and-writeback-charge-fresh-nodes-once
              5
              (context-value-nodes context))))

(datum-direct-host-case
 'native-known-mirror-condition-reconciles-once
 '(portable runtime datum boundary condition graph mutation)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'before 'tail))
       (condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda (mirror)
             (let ((fresh (cons 'condition mirror)))
               (set-cdr! mirror fresh)
               (raise (vector mirror fresh fresh))))
           context
           original)))
       (returned (consent-datum-vector-ref condition 0))
       (fresh (consent-datum-vector-ref condition 1)))
  (test-assert 'native-condition-reuses-known-mirror
               (consent-datum-same? original returned))
  (test-assert 'native-condition-keeps-fresh-sharing
               (consent-datum-same?
                fresh
                (consent-datum-vector-ref condition 2)))
  (test-assert 'native-condition-and-writeback-share-fresh-node
               (consent-datum-same?
                fresh
                (consent-datum-cdr original)))
  (test-assert 'native-condition-fresh-node-closes-known-cycle
               (consent-datum-same?
                original
                (consent-datum-cdr fresh)))
  (test-equal 'native-condition-and-writeback-charge-fresh-nodes-once
              5
              (context-value-nodes context))))

(datum-direct-host-case
 'native-result-budget-stops-after-transactional-writeback
 '(portable runtime datum boundary mutation budget error-order)
(let* ((context
        (new-eval-context (list (cons 'max-value-nodes 0))))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'before 'tail))
       (raised?
        (guard (condition (else #t))
          (consent-call-native-library
           (lambda (mirror)
             (let ((fresh (cons 'fresh '())))
               (set-car! mirror fresh)
               fresh))
           context
           original)
          #f)))
  (test-assert 'native-result-tight-budget-raises raised?)
  (test-equal 'native-result-tight-budget-counts-fresh-once
              1
              (context-value-nodes context))
  ;; The outer bridge publishes all host mutations before its aggregate
  ;; value-node charge can stop, so reconciliation is never half-applied.
  (test-assert 'native-result-writeback-precedes-budget-stop
               (consent-datum-pair? (consent-datum-car original)))))

(datum-direct-host-case
 'native-raised-argument-keeps-owned-identity
 '(portable runtime datum boundary condition)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'value '()))
       (condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda (value) (raise value))
           context
           original))))
  (test-assert 'native-raised-argument-keeps-owned-identity
               (consent-datum-same? original condition))))

(datum-direct-host-case
 'native-raised-fresh-cycle-is-owned
 '(portable runtime datum boundary condition graph)
(let* ((context (new-eval-context '()))
       (condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda ()
             (let* ((pair (cons 'value '()))
                    (vector (vector pair pair)))
               (set-cdr! pair vector)
               (raise vector)))
           context)))
       (left (consent-datum-vector-ref condition 0))
       (right (consent-datum-vector-ref condition 1)))
  (test-assert 'native-raised-fresh-condition-is-owned
               (and (consent-datum-vector? condition)
                    (consent-datum-pair? left)))
  (test-assert 'native-raised-fresh-condition-keeps-sharing
               (consent-datum-same? left right))
  (test-assert 'native-raised-fresh-condition-keeps-cycle
               (consent-datum-same?
                condition
                (consent-datum-cdr left)))))

(datum-direct-host-case
 'native-error-object-becomes-portable-condition
 '(portable runtime datum boundary condition)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'value '()))
       (condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda (value) (error "native bridge failure" value))
           context
           original))))
  (test-assert 'native-error-object-is-portable-condition
               (consent-error-object? condition))
  (test-equal 'native-error-object-message-preserved
              "native bridge failure"
              (consent-error-object-message condition))
  (let ((irritants (consent-error-object-irritants condition)))
    (test-equal 'native-error-object-irritant-count 1 (length irritants))
    (test-assert 'native-error-object-irritant-keeps-owned-identity
                 (consent-datum-same? original (car irritants))))))

(testing-registry-case
 'result-error-object-cycle-is-bounded
 '(portable runtime datum result graph)
(let* ((irritants (cons #f '()))
       (condition (make-consent-error-object "cycle" irritants))
       (shared (make-consent-error-object "shared" '())))
  (set-car! irritants condition)
  (test-equal
   'result-error-object-cycle-is-bounded
   '(error-object (message "cycle") (irritants ((cycle))))
   (value->result-datum condition))
  (let ((rendered (value->result-datum (vector shared shared))))
    (test-assert 'result-shared-error-object-is-converted-once
                 (eq? (vector-ref rendered 0)
                      (vector-ref rendered 1))))))

(datum-direct-host-case
 'native-many-callback-shims-keep-identity
 '(portable runtime datum boundary callback graph)
(let* ((context (new-eval-context '()))
       (count 32)
       (callbacks
        (let loop ((index 0) (result '()))
          (if (= index count)
              (reverse result)
              (loop
               (+ index 1)
               (cons
                (make-primitive-procedure
                 'test-distinct-callback
                 (lambda (arguments callback-context) index)
                 0
                 0)
                result)))))
       (callback-arguments
        (let ((arguments (make-vector (* count 2) #f)))
          (let fill ((rest callbacks) (index 0))
            (if (pair? rest)
                (begin
                  (vector-set! arguments index (car rest))
                  (vector-set! arguments (+ count index) (car rest))
                  (fill (cdr rest) (+ index 1)))))
          arguments))
       (observed
        (consent-call-native-library
         (lambda (shims)
           (let* ((repeated?
                   (let loop ((index 0))
                     (or
                      (= index count)
                      (and
                       (eq? (vector-ref shims index)
                            (vector-ref shims (+ count index)))
                       (loop (+ index 1))))))
                  (adjacent-distinct?
                   (let loop ((index 1))
                     (or
                      (= index count)
                      (and
                       (not
                        (eq? (vector-ref shims (- index 1))
                             (vector-ref shims index)))
                       (loop (+ index 1)))))))
             (vector repeated? adjacent-distinct? shims)))
         context
         callback-arguments))
       (origins (consent-datum-vector-ref observed 2)))
  (test-assert 'repeated-callback-reuses-shim
               (consent-datum-vector-ref observed 0))
  (test-assert 'distinct-callbacks-use-distinct-shims
               (consent-datum-vector-ref observed 1))
  (test-assert
   'callback-shims-return-to-original-callables
   (let loop ((rest callbacks) (index 0))
     (or
      (null? rest)
      (and
       (eq? (car rest) (consent-datum-vector-ref origins index))
       (eq? (car rest)
            (consent-datum-vector-ref origins (+ count index)))
       (loop (cdr rest) (+ index 1))))))))

(datum-direct-host-case
 'native-compound-callbacks-fail-closed
 '(portable runtime datum boundary callback condition)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'before 'tail))
       (previous-applier (consent-native-applier-ref))
       (scalar-called? #f)
       (active-called? #f)
       (argument-called? #f)
       (result-called? #f)
       (scalar-callback
        (make-primitive-procedure
         'test-scalar-callback
         (lambda (arguments callback-context)
           (set! scalar-called? #t)
           #t)
         0
         0))
       (active-callback
        (make-primitive-procedure
         'test-active-compound-callback
         (lambda (arguments callback-context)
           (set! active-called? #t)
           #t)
         0
         0))
       (argument-callback
        (make-primitive-procedure
         'test-compound-argument-callback
         (lambda (arguments callback-context)
           (set! argument-called? #t)
           #t)
         1
         1))
       (result-callback
        (make-primitive-procedure
         'test-compound-result-callback
         (lambda (arguments callback-context)
           (set! result-called? #t)
           original)
         0
         0))
       (outcomes
        (dynamic-wind
         (lambda ()
           (consent-install-native-applier!
            (lambda (procedure arguments callback-context)
              ((primitive-procedure-function procedure)
               arguments
               callback-context))))
         (lambda ()
           (list
            (consent-call-native-library
             (lambda (callable)
               (consent-apply-callable callable '()))
             context
             scalar-callback)
            (guard (raised (else raised))
              (consent-call-native-library
               (lambda (mirror callable)
                 (consent-apply-callable callable '()))
               context
               original
               active-callback))
            (guard (raised (else raised))
              (consent-call-native-library
               (lambda (callable)
                 (consent-apply-callable
                  callable
                  (list (cons 'native 'compound))))
               context
               argument-callback))
            (guard (raised (else raised))
              (consent-call-native-library
               (lambda (callable)
                 (consent-apply-callable callable '()))
               context
               result-callback))))
         (lambda ()
           (consent-install-native-applier! previous-applier))))
       (scalar-result (list-ref outcomes 0))
       (active-condition (list-ref outcomes 1))
       (argument-condition (list-ref outcomes 2))
       (result-condition (list-ref outcomes 3)))
  (test-assert 'scalar-callback-remains-available scalar-result)
  (test-assert 'scalar-callback-ran scalar-called?)
  (test-assert 'active-compound-callback-rejected
               (consent-error-object? active-condition))
  (test-assert 'active-compound-callback-not-run
               (not active-called?))
  (test-assert 'compound-callback-argument-rejected
               (consent-error-object? argument-condition))
  (test-assert 'compound-callback-argument-not-delivered
               (not argument-called?))
  (test-assert 'compound-callback-result-rejected
               (consent-error-object? result-condition))
  (test-assert 'compound-callback-ran-before-result-rejection
               result-called?)
  (test-equal
   'active-compound-callback-message
   "native-compound-callback-unavailable: scalar values required"
   (consent-error-object-message active-condition))
  (test-equal
   'compound-callback-argument-message
   "native-compound-callback-unavailable: scalar values required"
   (consent-error-object-message argument-condition))
  (test-equal
   'compound-callback-result-message
   "native-compound-callback-unavailable: scalar values required"
   (consent-error-object-message result-condition))))

(datum-direct-host-case
 'native-compound-reentry-fails-closed
 '(portable runtime datum boundary condition)
(let* ((outer-context (new-eval-context '()))
       (heap (context-datum-heap outer-context))
       (inner-context
        (new-eval-context (list (cons 'datum-heap heap))))
       (original (consent-datum-cons heap 'before 'tail))
       (scalar-result
        (consent-call-native-library
         (lambda ()
           (consent-call-native-library
            (lambda (value) value)
            inner-context
            #t))
         outer-context))
       (active-condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda (mirror)
             (consent-call-native-library (lambda () #t) inner-context))
           outer-context
           original)))
       (argument-condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda ()
             (consent-call-native-library
              (lambda (mirror) #t)
              inner-context
              original))
           outer-context)))
       (result-condition
        (guard (raised (else raised))
          (consent-call-native-library
           (lambda ()
             (consent-call-native-library
              (lambda () (cons 'native 'compound))
              inner-context))
           outer-context))))
  (test-assert 'scalar-reentry-remains-available scalar-result)
  (test-assert 'active-compound-reentry-rejected
               (consent-error-object? active-condition))
  (test-assert 'compound-reentry-argument-rejected
               (consent-error-object? argument-condition))
  (test-assert 'compound-reentry-result-rejected
               (consent-error-object? result-condition))
  (test-equal
   'active-compound-reentry-message
   "native-compound-reentry-unavailable: scalar values required"
   (consent-error-object-message active-condition))
  (test-equal
   'compound-reentry-argument-message
   "native-compound-reentry-unavailable: scalar values required"
   (consent-error-object-message argument-condition))
  (test-equal
   'compound-reentry-result-message
   "native-compound-reentry-unavailable: scalar values required"
   (consent-error-object-message result-condition))))

(datum-direct-host-case
 'native-outer-compound-mutation-remains-available
 '(portable runtime datum boundary mutation)
(let* ((context (new-eval-context '()))
       (heap (context-datum-heap context))
       (original (consent-datum-cons heap 'before 'tail))
       (returned
        (consent-call-native-library
         (lambda (mirror)
           (set-car! mirror 'after)
           mirror)
         context
         original)))
  (test-assert 'native-outer-return-keeps-owned-identity
               (consent-datum-same? original returned))
  (test-assert 'native-outer-mutation-writes-back
               (consent-host-symbol-eq?
                'after
                (consent-datum-car original)))))

(datum-direct-host-case
 'native-compound-borrow-inventories-match-bindings
 '(portable runtime datum boundary registry)
(begin
  (if (not datum-compiled-host-run?)
      (begin
        (consent-register-native-library!
         '(agent memory-query)
         (native-memory-query-test-bindings))
        (consent-register-native-library!
         '(agent models openai-codec)
         (native-openai-codec-test-bindings))
        (consent-register-native-library!
         '(agent redaction-kernel)
         (native-redaction-kernel-test-bindings))
        (consent-register-native-library!
         '(agent task)
         (list
    (cons 'task-states native-task:task-states)
    (cons 'task-pause-states native-task:task-pause-states)
    (cons 'task-terminal-states native-task:task-terminal-states)
    (cons 'task-allowed-transitions native-task:task-allowed-transitions)
    (cons 'task-pause-reasons native-task:task-pause-reasons)
    (cons 'task-stop-reasons native-task:task-stop-reasons)
    (cons 'task-state? native-task:task-state?)
    (cons 'task-transition-allowed?
          native-task:task-transition-allowed?)
    (cons 'validate-task-transition native-task:validate-task-transition)
    (cons 'make-task-condition native-task:make-task-condition)
    (cons 'task-field-value native-task:task-field-value)
    (cons 'task-record? native-task:task-record?)
    (cons 'agent-task? native-task:agent-task?)
    (cons 'agent-step? native-task:agent-step?)
    (cons 'agent-action? native-task:agent-action?)
    (cons 'agent-observation? native-task:agent-observation?)
    (cons 'agent-decision? native-task:agent-decision?)
    (cons 'task-pause? native-task:task-pause?)
    (cons 'task-stop? native-task:task-stop?)
    (cons 'task-wait? native-task:task-wait?)
    (cons 'task-failure? native-task:task-failure?)
    (cons 'agent-completion? native-task:agent-completion?)
    (cons 'task-record-valid? native-task:task-record-valid?)
    (cons 'validate-task-record native-task:validate-task-record)
    (cons 'make-agent-task native-task:make-agent-task)
    (cons 'make-agent-step native-task:make-agent-step)
    (cons 'make-agent-action native-task:make-agent-action)
    (cons 'make-agent-observation native-task:make-agent-observation)
    (cons 'make-agent-decision native-task:make-agent-decision)
    (cons 'make-task-pause native-task:make-task-pause)
    (cons 'make-task-stop native-task:make-task-stop)
    (cons 'make-task-wait native-task:make-task-wait)
          (cons 'make-task-failure native-task:make-task-failure)
          (cons 'make-agent-completion native-task:make-agent-completion)))
        (consent-register-native-library!
         '(agent transcript)
         (list
    (cons 'transcript-event-kinds
          native-transcript:transcript-event-kinds)
    (cons 'transcript-replay-modes
          native-transcript:transcript-replay-modes)
    (cons 'transcript-export-formats
          native-transcript:transcript-export-formats)
    (cons 'transcript-retention-default
          native-transcript:transcript-retention-default)
    (cons 'make-transcript-event
          native-transcript:make-transcript-event)
    (cons 'transcript-event? native-transcript:transcript-event?)
    (cons 'transcript-field-value
          native-transcript:transcript-field-value)
    (cons 'transcript-event-replay-mode
          native-transcript:transcript-event-replay-mode)
    (cons 'transcript-replayable?
          native-transcript:transcript-replayable?)
    (cons 'transcript-recorded-observation?
          native-transcript:transcript-recorded-observation?)
    (cons 'transcript-event->fixture-case
          native-transcript:transcript-event->fixture-case)
    (cons 'transcript-event-summary
          native-transcript:transcript-event-summary)
    (cons 'transcript-raw-view native-transcript:transcript-raw-view)
    (cons 'transcript-summary-view
          native-transcript:transcript-summary-view)
          (cons 'transcript-rotate native-transcript:transcript-rotate)
          (cons 'transcript-export native-transcript:transcript-export)))
        (consent-register-native-library!
         '(agent context)
         (list
    (cons 'context-field native-context:context-field)
    (cons 'context-present? native-context:context-present?)
    (cons 'make-request-context native-context:make-request-context)
          (cons 'make-conversation-summary
                native-context:make-conversation-summary)
          (cons 'make-focus-context native-context:make-focus-context)
          (cons 'make-context-bundle native-context:make-context-bundle)))))
  (let ((context
         (new-eval-context
          '((internal-libraries-allowed . #t))))
        (environment (consent-make-empty-environment)))
    (test-equal
     'native-memory-query-binding-inventory
     '(memory-query-find
       memory-query-by-tag
       memory-query-recent
       memory-query-select)
     (map car (native-memory-query-test-bindings)))
    (test-assert
     'native-memory-query-binding-inventory-valid
     (resolve-library '(agent memory-query) context environment))
    (test-equal
     'native-openai-codec-binding-inventory
     '(model-openai-codec-request-json-projected
       model-openai-codec-parse-response
       model-openai-codec-provider-error-projected)
     (map car (native-openai-codec-test-bindings)))
    (test-assert
     'native-openai-codec-binding-inventory-valid
     (resolve-library
      '(agent models openai-codec) context environment))
    (test-equal
     'native-redaction-kernel-binding-inventory
     '(redaction-kernel-secret-string?)
     (map car (native-redaction-kernel-test-bindings)))
    (test-assert
     'native-redaction-kernel-binding-inventory-valid
     (resolve-library '(agent redaction-kernel) context environment))
    (test-assert
     'native-task-binding-inventory-valid
     (resolve-library '(agent task) context environment))
    (test-assert
     'native-transcript-binding-inventory-valid
     (resolve-library '(agent transcript) context environment))
    (test-assert
     'native-context-binding-inventory-valid
     (resolve-library '(agent context) context environment)))))

(datum-direct-host-case
 'native-memory-query-borrow-inventory-fails-closed
 '(portable runtime datum boundary registry)
(let* ((bindings (native-memory-query-test-bindings))
       (resolve-condition
        (lambda (candidate-bindings)
          (consent-register-native-library!
           '(agent memory-query)
           candidate-bindings)
          (guard (condition (else condition))
            (resolve-library
             '(agent memory-query)
             (new-eval-context
              '((internal-libraries-allowed . #t)))
             (consent-make-empty-environment))
            #f)))
       (missing-condition (resolve-condition (cdr bindings)))
       (extra-procedure-condition
        (resolve-condition
         (append
          bindings
          (list (cons 'unexpected-memory-query (lambda () #t))))))
       (extra-data-condition
        (resolve-condition
         (append bindings (list (cons 'unexpected-memory-data 'retained))))))
  (consent-register-native-library! '(agent memory-query) bindings)
  (test-assert
   'native-memory-query-missing-procedure-rejected
   (error-object? missing-condition))
  (test-equal
   'native-memory-query-missing-procedure-message
   "native-binding-inventory-mismatch: missing procedure"
   (error-object-message missing-condition))
  (test-assert
   'native-memory-query-extra-procedure-rejected
   (error-object? extra-procedure-condition))
  (test-assert
   'native-memory-query-zero-data-inventory-rejects-data
   (error-object? extra-data-condition))
  (test-equal
   'native-memory-query-unexpected-binding-message
   '("native-binding-inventory-mismatch: unexpected binding"
     "native-binding-inventory-mismatch: unexpected binding")
   (list
    (error-object-message extra-procedure-condition)
    (error-object-message extra-data-condition)))))

(datum-direct-host-case
 'native-openai-codec-borrow-inventory-fails-closed
 '(portable runtime datum boundary registry)
(let* ((bindings (native-openai-codec-test-bindings))
       (resolve-condition
        (lambda (candidate-bindings)
          (consent-register-native-library!
           '(agent models openai-codec)
           candidate-bindings)
          (guard (condition (else condition))
            (resolve-library
             '(agent models openai-codec)
             (new-eval-context
              '((internal-libraries-allowed . #t)))
             (consent-make-empty-environment))
            #f)))
       (missing-condition
        (resolve-condition (cdr bindings)))
       (extra-procedure-condition
        (resolve-condition
         (append
          bindings
          (list (cons 'unexpected-codec-binding (lambda () #t))))))
       (extra-data-condition
        (resolve-condition
         (append bindings (list (cons 'unexpected-codec-data 'retained))))))
  (consent-register-native-library!
   '(agent models openai-codec)
   bindings)
  (test-assert
   'native-openai-codec-missing-binding-rejected
   (error-object? missing-condition))
  (test-equal
   'native-openai-codec-missing-binding-message
   "native-binding-inventory-mismatch: missing procedure"
   (error-object-message missing-condition))
  (test-assert
   'native-openai-codec-extra-binding-rejected
   (error-object? extra-procedure-condition))
  (test-assert
   'native-openai-codec-zero-data-inventory-rejects-data
   (error-object? extra-data-condition))
  (test-equal
   'native-openai-codec-extra-binding-messages
   '("native-binding-inventory-mismatch: unexpected binding"
     "native-binding-inventory-mismatch: unexpected binding")
   (list
    (error-object-message extra-procedure-condition)
    (error-object-message extra-data-condition)))))

(datum-direct-host-case
 'native-redaction-kernel-borrow-inventory-fails-closed
 '(portable runtime datum boundary registry)
(let* ((bindings (native-redaction-kernel-test-bindings))
       (resolve-condition
        (lambda (candidate-bindings)
          (consent-register-native-library!
           '(agent redaction-kernel)
           candidate-bindings)
          (guard (condition (else condition))
            (resolve-library
             '(agent redaction-kernel)
             (new-eval-context
              '((internal-libraries-allowed . #t)))
             (consent-make-empty-environment))
            #f)))
       (missing-condition (resolve-condition '()))
       (extra-procedure-condition
        (resolve-condition
         (append
          bindings
          (list (cons 'unexpected-redaction-kernel (lambda () #t))))))
       (extra-data-condition
        (resolve-condition
         (append
          bindings
          (list (cons 'unexpected-redaction-data 'retained))))))
  (consent-register-native-library!
   '(agent redaction-kernel)
   bindings)
  (test-assert
   'native-redaction-kernel-missing-procedure-rejected
   (error-object? missing-condition))
  (test-equal
   'native-redaction-kernel-missing-procedure-message
   "native-binding-inventory-mismatch: missing procedure"
   (error-object-message missing-condition))
  (test-assert
   'native-redaction-kernel-extra-procedure-rejected
   (error-object? extra-procedure-condition))
  (test-assert
   'native-redaction-kernel-zero-data-inventory-rejects-data
   (error-object? extra-data-condition))
  (test-equal
   'native-redaction-kernel-unexpected-binding-messages
   '("native-binding-inventory-mismatch: unexpected binding"
     "native-binding-inventory-mismatch: unexpected binding")
   (list
    (error-object-message extra-procedure-condition)
    (error-object-message extra-data-condition)))))

(datum-direct-host-case
 'native-redaction-kernel-callback-and-reentry-fail-closed
 '(portable runtime datum boundary callback reentry)
(let ((previous-applier (consent-native-applier-ref))
      (callback-called? #f)
      (callback-binding-entered? #f)
      (nested-native-called? #f)
      (reentry-binding-entered? #f))
  (let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (text
          (consent-datum-import
           (context-datum-heap context)
           "prefix sk-x"))
         (callback
          (make-primitive-procedure
           'redaction-kernel-test-callback
           (lambda (arguments callback-context)
             (set! callback-called? #t)
             #t)
           0
           0)))
    (consent-register-native-library!
     '(agent redaction-kernel)
     (list
      (cons
       'redaction-kernel-secret-string?
       (lambda (text-mirror)
         (set! callback-binding-entered? #t)
         (consent-apply-callable callback '())))))
    (let* ((library
            (resolve-library
             '(agent redaction-kernel)
             context
             (consent-make-empty-environment)))
           (callable
            (cell-value
             (test-library-binding-cell
              library
              'redaction-kernel-secret-string?)))
           (condition
            (dynamic-wind
             (lambda ()
               (consent-install-native-applier!
                (lambda (procedure arguments callback-context)
                  ((primitive-procedure-function procedure)
                   arguments
                   callback-context))))
             (lambda ()
               (guard (raised (else raised))
                 ((primitive-procedure-function callable)
                  (list text)
                  context)))
             (lambda ()
               (consent-install-native-applier! previous-applier)))))
      (test-assert
       'native-redaction-kernel-malicious-callback-binding-entered
       callback-binding-entered?)
      (test-assert
       'native-redaction-kernel-callback-not-invoked
       (not callback-called?))
      (test-assert
       'native-redaction-kernel-nested-callback-rejected
       (consent-error-object? condition))
      (test-equal
       'native-redaction-kernel-nested-callback-message
       "native-compound-callback-unavailable: scalar values required"
       (consent-error-object-message condition))))
  (let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (text
          (consent-datum-import
           (context-datum-heap context)
           "prefix sk-x")))
    (consent-register-native-library!
     '(agent redaction-kernel)
     (list
      (cons
       'redaction-kernel-secret-string?
       (lambda (text-mirror)
         (set! reentry-binding-entered? #t)
         (consent-call-native-library
          (lambda ()
            (set! nested-native-called? #t)
            #t)
          context)))))
    (let* ((library
            (resolve-library
             '(agent redaction-kernel)
             context
             (consent-make-empty-environment)))
           (callable
            (cell-value
             (test-library-binding-cell
              library
              'redaction-kernel-secret-string?)))
           (condition
            (guard (raised (else raised))
              ((primitive-procedure-function callable)
               (list text)
               context))))
      (test-assert
       'native-redaction-kernel-malicious-reentry-binding-entered
       reentry-binding-entered?)
      (test-assert
       'native-redaction-kernel-nested-native-not-called
       (not nested-native-called?))
      (test-assert
       'native-redaction-kernel-nested-reentry-rejected
       (consent-error-object? condition))
      (test-equal
       'native-redaction-kernel-nested-reentry-message
       "native-compound-reentry-unavailable: scalar values required"
       (consent-error-object-message condition))))
  (consent-register-native-library!
   '(agent redaction-kernel)
   (native-redaction-kernel-test-bindings))))

(datum-direct-host-case
 'native-redaction-kernel-preserves-string-identity
 '(portable runtime datum boundary identity mutation)
(begin
  (consent-register-native-library!
   '(agent redaction-kernel)
   (native-redaction-kernel-test-bindings))
  (let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (heap (context-datum-heap context))
         (text (consent-datum-import heap "prefix ghp_x"))
         (alias text)
         (revision (consent-datum-object-revision text))
         (library
          (resolve-library
           '(agent redaction-kernel)
           context
           (consent-make-empty-environment)))
         (callable
          (cell-value
           (test-library-binding-cell
            library
            'redaction-kernel-secret-string?)))
         (result
          ((primitive-procedure-function callable)
           (list text)
           context)))
    (test-assert 'native-redaction-kernel-match-result result)
    (test-assert
     'native-redaction-kernel-input-keeps-owned-identity
     (consent-datum-same? text alias))
    (test-equal
     'native-redaction-kernel-input-revision-unchanged
     revision
     (consent-datum-object-revision text))
    (test-equal
     'native-redaction-kernel-input-content-unchanged
     "prefix ghp_x"
     (consent-runtime-datum->native-datum text)))))

(datum-direct-host-case
 'native-openai-codec-owned-error-projection
 '(portable runtime datum boundary graph)
(begin
  (consent-register-native-library!
   '(agent models openai-codec)
   (native-openai-codec-test-bindings))
  (let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (heap (context-datum-heap context))
         (library
          (resolve-library
           '(agent models openai-codec)
           context
           (consent-make-empty-environment)))
         (callable
          (cell-value
           (test-library-binding-cell
            library
            'model-openai-codec-provider-error-projected)))
         (transport-context
          (consent-datum-import
           heap
           '#(local-errors
              qwen-coder
              local
              openai-compatible-http
              7
              0
              240)))
         (url
          (consent-datum-import
           heap
           "http://127.0.0.1:11434/v1/chat/completions"))
         (reason (consent-datum-import heap "HTTP 503: safe"))
         (extra-fields
          (consent-datum-import heap '((phase http))))
         (projection
          ((primitive-procedure-function callable)
           (list
            transport-context
            'scheme-scripter
            url
            reason
            reason
            extra-fields)
           context))
         (native-projection
          (consent-runtime-datum->native-datum projection))
         (error-datum (vector-ref native-projection 1)))
    (test-assert
     'native-openai-codec-projection-is-owned
     (and (consent-datum-object? projection)
          (eq? (consent-datum-object-kind projection) 'vector)))
    (test-equal
     'native-openai-codec-owned-summary
     (string-append
      "local model transport failed for provider local-errors model "
      "qwen-coder via openai-compatible-http: HTTP 503: safe")
     (vector-ref native-projection 0))
    (test-equal
     'native-openai-codec-owned-error-shape
     '(model-provider-error (phase http))
     (list (car error-datum) (car (reverse (cdr error-datum))))))))

(datum-direct-host-case
 'native-openai-codec-rejects-borrowed-request-cycles
 '(portable runtime datum boundary graph condition budget)
(let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t)
             (max-steps . 64))))
         (heap (context-datum-heap context))
         (recursive (make-vector 1 #f))
         (tool
          (list
           'model-tool
           '(name recursive-tool)
           (list
            'schema
            (list
             'openai-tool
             '(type function)
             (list
              'function
              '(name "recursive-tool")
              (list 'parameters recursive))))))
         (cyclic-tools (list tool)))
    (vector-set! recursive 0 recursive)
    (let* ((model-id (consent-datum-import heap "qwen3:0.6b"))
           (prompt (consent-datum-import heap "prompt"))
           (schema-options
            (consent-datum-import heap (vector (list tool) #f)))
           (schema-condition
            (guard (raised (else raised))
              (consent-call-native-library
               native-openai-codec:model-openai-codec-request-json-projected
               context
               model-id
               prompt
               schema-options)
              #f)))
      (set-cdr! cyclic-tools cyclic-tools)
      (let* ((tools-options
              (consent-datum-import heap (vector cyclic-tools #f)))
             (tools-condition
             (guard (raised (else raised))
                (consent-call-native-library
                 native-openai-codec:model-openai-codec-request-json-projected
                 context
                 model-id
                 prompt
                 tools-options)
                #f)))
        (test-assert 'native-openai-codec-schema-cycle-rejected
                     (consent-error-object? schema-condition))
        (test-equal
         'native-openai-codec-schema-cycle-message
         "OpenAI tool schema must be acyclic"
         (consent-error-object-message schema-condition))
        (test-assert 'native-openai-codec-tools-cycle-rejected
                     (consent-error-object? tools-condition))
        (test-equal
         'native-openai-codec-tools-cycle-message
         "OpenAI tools must form a finite proper list"
         (consent-error-object-message tools-condition))))))

(testing-registry-case
 'native-memory-query-detached-projection-semantics
 '(portable runtime datum boundary query identity mutation)
(let* ((arbitrary-key (vector 'key-node 1))
       (arbitrary-kind (vector 'kind-node 2))
       (arbitrary-tag (vector 'tag-node 3))
       (arbitrary-record
        (list
         'memory
         (list 'id 'arbitrary-record)
         (list 'scope 'project)
         (list 'key arbitrary-key)
         (list 'kind arbitrary-kind)
         (list 'memory-class 'semantic)
         (list 'tags (list arbitrary-tag))
         (list 'value "exact accepted payload")
         (list 'source '())
         (list 'confidence 'high)
         (list 'importance 1)
         (list 'created-at 1)
         (list 'updated-at 1)))
       (symbol-record
        '(memory
          (id symbol-record)
          (scope project)
          (key symbol-key)
          (kind symbol-kind)
          (memory-class semantic)
          (tags (symbol-tag))
          (value "other payload")
          (source ())
          (confidence high)
          (importance 1)
          (created-at 2)
          (updated-at 2)))
       (arbitrary-live-key
        (native-memory-query-test-key 'project arbitrary-key))
       (arbitrary-id-key
        (native-memory-query-test-key 'project 'arbitrary-record))
       (arbitrary-kind-key
        (native-memory-query-test-key 'project arbitrary-kind))
       (arbitrary-tag-key
        (native-memory-query-test-key 'project arbitrary-tag))
       (symbol-live-key
        (native-memory-query-test-key 'project 'symbol-key))
       (symbol-id-key
        (native-memory-query-test-key 'project 'symbol-record))
       (symbol-kind-key
        (native-memory-query-test-key 'project 'symbol-kind))
       (symbol-tag-key
        (native-memory-query-test-key 'project 'symbol-tag))
       (arbitrary-sidecar
        (native-memory-query-test-sidecar
         arbitrary-live-key
         arbitrary-id-key
         arbitrary-kind-key
         (list arbitrary-tag-key)
         4))
       (symbol-sidecar
        (native-memory-query-test-sidecar
         symbol-live-key
         symbol-id-key
         symbol-kind-key
         (list symbol-tag-key)
         0))
       (records (list symbol-record arbitrary-record))
       (live-projections
        (list
         (native-memory-query-test-live-projection symbol-sidecar 0)
         (native-memory-query-test-live-projection arbitrary-sidecar 2)))
       (query (list arbitrary-key arbitrary-kind arbitrary-tag))
       (select-projection
        (native-memory-query-test-select-projection
         query
         (list arbitrary-live-key arbitrary-kind-key arbitrary-tag-key)))
       (policy
        '(retrieval-policy
          (weights ((recency 0) (importance 0) (relevance 1)))
          (cutoff 0)
          (limit 1)))
       (local-context
        '(retrieval-context
          (scope project)
          (allowed-scopes (project))
          (trust local)
          (logical-clock 2)))
       (remote-context
        '(retrieval-context
          (scope project)
          (allowed-scopes (project))
          (trust remote)
          (logical-clock 2))))
  (define (candidate-for-id selection id)
    "Return ID's candidate from SELECTION."
    (let loop
        ((rest (native-memory-query-test-field selection 'candidates)))
      (cond
       ((null? rest) #f)
       ((eq? id (native-memory-query-test-field (car rest) 'id))
        (car rest))
       (else (loop (cdr rest))))))
  ;; Mutating the borrowed identity fields after preparation must not alter
  ;; query behavior; only detached append-time projections own these matches.
  (vector-set! arbitrary-key 1 'mutated-key)
  (vector-set! arbitrary-kind 1 'mutated-kind)
  (vector-set! arbitrary-tag 1 'mutated-tag)
  (let* ((text-result
          (native-memory-query:memory-query-find
           records
           live-projections
           'project
           (vector "exact accepted payload" #f #f)))
         (whole-result
          (native-memory-query:memory-query-find
           records live-projections 'project (vector #f #f '(#f #t))))
         (key-result
          (native-memory-query:memory-query-find
           records
           live-projections
           'project
           (vector "symbol-key" symbol-live-key #f)))
         (kind-result
          (native-memory-query:memory-query-find
           records
           live-projections
           'project
           (vector "symbol-kind" symbol-kind-key #f)))
         (tag-result
          (native-memory-query:memory-query-find
           records
           live-projections
           'project
           (vector "symbol-tag" symbol-tag-key #f)))
         (by-tag-result
          (native-memory-query:memory-query-by-tag
           records live-projections 'project arbitrary-tag-key))
         (recent-result
          (native-memory-query:memory-query-recent
           records live-projections 'project 2))
         (local-selection
          (native-memory-query:memory-query-select
           records
           live-projections
           2
           select-projection
           policy
           local-context))
         (remote-selection
          (native-memory-query:memory-query-select
           records
           live-projections
           2
           select-projection
           policy
           remote-context))
         (local-candidate
          (candidate-for-id local-selection 'arbitrary-record))
         (remote-candidate
          (candidate-for-id remote-selection 'arbitrary-record)))
    (test-assert
     'detached-find-text-preserves-exact-accepted-spelling
     (eq? arbitrary-record (car text-result)))
    (test-assert
     'detached-find-whole-record-flags-preserve-nontext-equality
     (eq? arbitrary-record (car whole-result)))
    (test-assert
     'detached-find-key-kind-and-tag-preserve-symbol-semantics
     (and (eq? symbol-record (car key-result))
          (eq? symbol-record (car kind-result))
          (eq? symbol-record (car tag-result))))
    (test-assert
     'detached-by-tag-supports-arbitrary-datum-tags
     (eq? arbitrary-record (car by-tag-result)))
    (test-assert
     'detached-recent-keeps-current-live-order-and-identities
     (and (eq? symbol-record (car recent-result))
          (eq? arbitrary-record (cadr recent-result))))
    (test-assert
     'detached-select-supports-arbitrary-key-kind-and-tag-terms
     (and
      (eq?
       arbitrary-record
       (car
        (native-memory-query-test-field local-selection 'records)))
      (= 3
         (cadr
          (assq
           'relevance
           (native-memory-query-test-field local-candidate 'subscores))))))
    (test-equal
     'detached-access-sequence-drives-recency
     1
     (cadr
      (assq
       'recency
       (native-memory-query-test-field local-candidate 'subscores))))
    (test-equal
     'detached-redaction-flags-preserve-lower-trust-filtering
     'redaction-or-local-only
     (native-memory-query-test-field remote-candidate 'reason)))))

(testing-registry-case
 'native-memory-query-rejects-malformed-detached-inputs
 '(portable runtime datum boundary query validation)
(let* ((record
        '(memory
          (id malformed-record)
          (scope project)
          (key malformed-record)
          (kind datum)
          (memory-class semantic)
          (tags (malformed-query))
          (value "malformed fixture")
          (source ())
          (confidence high)
          (importance 1)
          (created-at 1)
          (updated-at 1)))
       (live-key
        (native-memory-query-test-key 'project 'malformed-record))
       (kind-key (native-memory-query-test-key 'project 'datum))
       (tag-key
        (native-memory-query-test-key 'project 'malformed-query))
       (sidecar
        (native-memory-query-test-sidecar
         live-key
         live-key
         kind-key
         (list tag-key)
         0))
       (projection
        (native-memory-query-test-live-projection sidecar 0))
       (bad-flags-sidecar
        (native-memory-query-test-sidecar
         live-key
         live-key
         kind-key
         (list tag-key)
         8))
       (bad-flags-projection
        (native-memory-query-test-live-projection bad-flags-sidecar 0))
       (bad-access-projection
        (native-memory-query-test-live-projection sidecar -1))
       (records (list record))
       (cyclic-projections (list projection))
       (cyclic-records (list record)))
  (define (raises? thunk)
    "Return #t when THUNK raises a condition."
    (guard (condition (else #t))
      (thunk)
      #f))
  (set-cdr! cyclic-projections cyclic-projections)
  (set-cdr! cyclic-records cyclic-records)
  (test-assert
   'memory-query-rejects-misaligned-sidecars
   (raises?
    (lambda ()
      (native-memory-query:memory-query-recent
       records '() 'project 1))))
  (test-assert
   'memory-query-rejects-improper-and-cyclic-sidecar-lists
   (and
    (raises?
     (lambda ()
       (native-memory-query:memory-query-recent
        records (cons projection 'tail) 'project 1)))
    (raises?
     (lambda ()
       (native-memory-query:memory-query-recent
        records cyclic-projections 'project 1)))))
  (test-assert
   'memory-query-rejects-cyclic-record-lists
   (raises?
    (lambda ()
      (native-memory-query:memory-query-recent
       cyclic-records (list projection) 'project 1))))
  (test-assert
   'memory-query-rejects-invalid-sidecar-flags-and-access
   (and
    (raises?
     (lambda ()
       (native-memory-query:memory-query-recent
        records (list bad-flags-projection) 'project 1)))
    (raises?
     (lambda ()
       (native-memory-query:memory-query-recent
        records (list bad-access-projection) 'project 1)))))
  (test-assert
   'memory-query-rejects-malformed-find-and-tag-projections
   (and
    (raises?
     (lambda ()
       (native-memory-query:memory-query-find
        records (list projection) 'project (vector #f #f '(#t #f)))))
    (raises?
     (lambda ()
       (native-memory-query:memory-query-by-tag
        records
        (list projection)
        'project
        (native-memory-query-test-key 'session 'malformed-query))))))
  (test-assert
   'memory-query-rejects-malformed-select-term-projections
   (and
    (raises?
     (lambda ()
       (native-memory-query:memory-query-select
        records
        (list projection)
        1
        (vector 'malformed-query (vector (vector #f (vector #f))))
        '(retrieval-policy (cutoff 0) (limit 1))
        '(retrieval-context
          (scope project)
          (allowed-scopes (project))
          (logical-clock 1)))))
    (raises?
     (lambda ()
       (native-memory-query:memory-query-select
        records
        (list projection)
        "not-a-clock"
        (native-memory-query-test-select-projection
         'malformed-query (list live-key kind-key tag-key))
        '(retrieval-policy (cutoff 0) (limit 1))
        '(retrieval-context
          (scope project)
          (allowed-scopes (project))
          (logical-clock 1)))))))))

(datum-direct-host-case
 'native-memory-query-callback-and-reentry-fail-closed
 '(portable runtime datum boundary callback reentry)
(let ((previous-applier (consent-native-applier-ref)))
  (define (callback-probe name)
    "Probe one memory-query NAME with a compound-active callback."
    (let ((callback-called? #f)
          (native-called? #f))
      (let* ((context
              (new-eval-context
               '((internal-libraries-allowed . #t))))
             (heap (context-datum-heap context))
             (record-datum
              '(memory
                (id callback-record)
                (scope project)
                (key callback-record)
                (kind datum)
                (memory-class semantic)
                (tags (callback-query))
                (value "callback payload")
                (source ())
                (confidence high)
                (importance 1)
                (created-at 1)
                (updated-at 1)))
             (live-key
              (native-memory-query-test-key 'project 'callback-record))
             (kind-key
              (native-memory-query-test-key 'project 'datum))
             (tag-key
              (native-memory-query-test-key 'project 'callback-query))
             (sidecar
              (native-memory-query-test-sidecar
               live-key
               live-key
               kind-key
               (list tag-key)
               0))
             (records
              (consent-datum-import heap (list record-datum)))
             (live-projections
              (consent-datum-import
               heap
               (list
                (native-memory-query-test-live-projection sidecar 0))))
             (find-projection
              (consent-datum-import
               heap
               (vector "callback payload" #f #f)))
             (tag-projection (consent-datum-import heap tag-key))
             (select-projection
              (consent-datum-import
               heap
               (native-memory-query-test-select-projection
                'callback-query
                (list tag-key))))
             (policy
              (consent-datum-import
               heap
               '(retrieval-policy (cutoff 0) (limit 1))))
             (request-context
              (consent-datum-import
               heap
               '(retrieval-context
                 (scope project)
                 (allowed-scopes (project))
                 (logical-clock 1))))
             (callback
              (make-primitive-procedure
               'memory-query-test-callback
               (lambda (arguments callback-context)
                 (set! callback-called? #t)
                 #t)
               0
               0))
             (arguments
              (cond
               ((consent-host-symbol-eq? name 'memory-query-find)
                (list records live-projections 'project find-projection))
               ((consent-host-symbol-eq? name 'memory-query-by-tag)
                (list records live-projections 'project tag-projection))
               ((consent-host-symbol-eq? name 'memory-query-recent)
                (list records live-projections 'project 1))
               (else
                (list
                 records
                 live-projections
                 1
                 select-projection
                 policy
                 request-context))))
             (library
              (begin
                (consent-register-native-library!
                 '(agent memory-query)
                 (native-memory-query-bindings-with
                  name
                  (lambda native-arguments
                    (set! native-called? #t)
                    (consent-apply-callable callback '()))))
                (resolve-library
                 '(agent memory-query)
                 context
                 (consent-make-empty-environment))))
             (callable
              (cell-value (test-library-binding-cell library name)))
             (condition
              (dynamic-wind
               (lambda ()
                 (consent-install-native-applier!
                  (lambda (procedure arguments callback-context)
                    ((primitive-procedure-function procedure)
                     arguments
                     callback-context))))
               (lambda ()
                 (guard (raised (else raised))
                   ((primitive-procedure-function callable)
                    arguments
                    context)))
               (lambda ()
                 (consent-install-native-applier! previous-applier)))))
        (list native-called? callback-called? condition))))
  (define (boundary-condition-message condition)
    "Return CONDITION's portable error message, or #f."
    (cond
     ((consent-error-object? condition)
      (consent-error-object-message condition))
     ((error-object? condition) (error-object-message condition))
     (else #f)))
  (let* ((probes
          (list
           (callback-probe 'memory-query-find)
           (callback-probe 'memory-query-by-tag)
           (callback-probe 'memory-query-recent)
           (callback-probe 'memory-query-select)))
         (conditions (map (lambda (probe) (list-ref probe 2)) probes)))
    (test-equal
     'all-memory-query-native-bindings-entered
     '(#t #t #t #t)
     (map car probes))
    (test-equal
     'memory-query-callbacks-rejected-before-reentry
     '(#f #f #f #f)
     (map cadr probes))
    (test-equal
     'memory-query-nested-callbacks-fail-closed
     '("native-compound-callback-unavailable: scalar values required"
       "native-compound-callback-unavailable: scalar values required"
       "native-compound-callback-unavailable: scalar values required"
       "native-compound-callback-unavailable: scalar values required")
     (map boundary-condition-message conditions)))
  (consent-register-native-library!
   '(agent memory-query)
   (native-memory-query-test-bindings))))

(datum-direct-host-case
 'native-memory-query-preserves-identities-without-mutation
 '(portable runtime datum boundary identity mutation)
(begin
  (consent-register-native-library!
   '(agent memory-query)
   (native-memory-query-test-bindings))
  (let* ((context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (heap (context-datum-heap context))
         (record-datum
          '(memory
            (id identity-record)
            (scope project)
            (key identity-record)
            (kind datum)
            (memory-class semantic)
            (tags (identity-query))
            (value "identity payload")
            (source ())
            (confidence high)
            (importance 1)
            (created-at 1)
            (updated-at 1)))
         (live-key
          (native-memory-query-test-key 'project 'identity-record))
         (kind-key (native-memory-query-test-key 'project 'datum))
         (tag-key
          (native-memory-query-test-key 'project 'identity-query))
         (sidecar
          (native-memory-query-test-sidecar
           live-key
           live-key
           kind-key
           (list tag-key)
           0))
         (records
          (consent-datum-import heap (list record-datum)))
         (live-projections
          (consent-datum-import
           heap
           (list (native-memory-query-test-live-projection sidecar 0))))
         (find-projection
          (consent-datum-import
           heap
           (vector "identity payload" #f #f)))
         (tag-projection (consent-datum-import heap tag-key))
         (select-projection
          (consent-datum-import
           heap
           (native-memory-query-test-select-projection
            '(identity-query)
            (list tag-key))))
         (query (consent-datum-vector-ref select-projection 0))
         (policy
          (consent-datum-import
           heap
           '(retrieval-policy (cutoff 0) (limit 1))))
         (request-context
          (consent-datum-import
           heap
           '(retrieval-context
             (scope project)
             (allowed-scopes (project))
             (logical-clock 1))))
         (library
          (resolve-library
           '(agent memory-query)
           context
           (consent-make-empty-environment))))
    (define (runtime-car value)
      "Return VALUE's first slot across host and owned pairs."
      (if (consent-datum-pair? value)
          (consent-datum-car value)
          (car value)))
    (define (runtime-cdr value)
      "Return VALUE's tail across host and owned pairs."
      (if (consent-datum-pair? value)
          (consent-datum-cdr value)
          (cdr value)))
    (define (runtime-field value name)
      "Return field NAME from an owned tagged record VALUE."
      (let loop ((fields (runtime-cdr value)))
        (if (null? fields)
            #f
            (let ((field (runtime-car fields)))
              (if (consent-host-symbol-eq? (runtime-car field) name)
                  (runtime-car (runtime-cdr field))
                  (loop (runtime-cdr fields)))))))
    (define (call-query name arguments)
      "Call native query binding NAME with runtime ARGUMENTS."
      ((primitive-procedure-function
        (cell-value (test-library-binding-cell library name)))
       arguments
       context))
    (let* ((record (runtime-car records))
           (prepared-projection (runtime-car live-projections))
           (prepared-sidecar
            (consent-datum-vector-ref prepared-projection 0))
           (records-revision (consent-datum-object-revision records))
           (record-revision (consent-datum-object-revision record))
           (projections-revision
            (consent-datum-object-revision live-projections))
           (projection-revision
            (consent-datum-object-revision prepared-projection))
           (sidecar-revision
            (consent-datum-object-revision prepared-sidecar))
           (records-snapshot
            (consent-runtime-datum->native-datum records))
           (prepared-snapshot
            (consent-runtime-datum->native-datum live-projections))
           (projection-revisions
            (map
             consent-datum-object-revision
             (list find-projection tag-projection select-projection)))
           (projection-snapshots
            (map
             consent-runtime-datum->native-datum
             (list find-projection tag-projection select-projection)))
           (found
            (call-query
             'memory-query-find
             (list records live-projections 'project find-projection)))
           (tagged
            (call-query
             'memory-query-by-tag
             (list records live-projections 'project tag-projection)))
           (recent
            (call-query
             'memory-query-recent
             (list records live-projections 'project 1)))
           (selection
            (call-query
             'memory-query-select
             (list
              records
              live-projections
              1
              select-projection
              policy
              request-context))))
      (test-assert
       'memory-query-results-reuse-canonical-record
       (and
        (consent-datum-same? record (runtime-car found))
        (consent-datum-same? record (runtime-car tagged))
        (consent-datum-same? record (runtime-car recent))
        (consent-datum-same?
         record
         (runtime-car (runtime-field selection 'records)))))
      (test-assert
       'memory-query-selection-reuses-input-receipts
       (and
        (consent-datum-same? query (runtime-field selection 'query))
        (consent-datum-same? policy (runtime-field selection 'policy))
        (consent-datum-same?
         request-context
         (runtime-field selection 'context))))
      (test-equal
       'memory-query-leaves-source-record-and-sidecar-graphs-unchanged
       (list
        records-revision
        record-revision
        projections-revision
        projection-revision
        sidecar-revision
        records-snapshot
        prepared-snapshot)
       (list
        (consent-datum-object-revision records)
        (consent-datum-object-revision record)
        (consent-datum-object-revision live-projections)
        (consent-datum-object-revision prepared-projection)
        (consent-datum-object-revision prepared-sidecar)
        (consent-runtime-datum->native-datum records)
        (consent-runtime-datum->native-datum live-projections)))
      (test-equal
       'memory-query-leaves-source-projection-graphs-unchanged
       (list projection-revisions projection-snapshots)
       (list
        (map
         consent-datum-object-revision
         (list find-projection tag-projection select-projection))
        (map
         consent-runtime-datum->native-datum
         (list find-projection tag-projection select-projection))))))))

(datum-direct-host-case
 'native-binding-cache-owned-by-evaluation-context
 '(portable runtime datum boundary registry performance)
(begin
  (if (not datum-compiled-host-run?)
      (register-native-symbol-test-library!))
  (let* ((untouched-context (new-eval-context '()))
         (context
          (new-eval-context
           '((internal-libraries-allowed . #t))))
         (environment (consent-make-empty-environment))
         (library
          (resolve-library '(consent symbol) context environment))
         (procedure-cell
          (test-library-binding-cell library 'consent-symbol?))
         (data-cell
          (test-library-binding-cell
           library 'consent-default-symbol-table))
         (cache (context-native-binding-cache context)))
    (test-equal
     'native-binding-cache-is-lazy
     #f
     (context-native-binding-cache untouched-context))
    (test-assert 'native-binding-cache-created cache)
    (test-assert 'native-procedure-cell-found procedure-cell)
    (test-assert 'native-data-cell-found data-cell)
    ;; Re-registering the table models a same-context re-export: the nested
    ;; cache must retain both procedure and data binding locations.
    (set-context-libraries! context '())
    (let ((registered-again
           (resolve-library '(consent symbol) context environment)))
      (test-assert
       'native-procedure-cell-shared-within-context
       (eq? procedure-cell
            (test-library-binding-cell
             registered-again 'consent-symbol?)))
      (test-assert
       'native-data-cell-shared-within-context
       (eq? data-cell
            (test-library-binding-cell
             registered-again 'consent-default-symbol-table))))
    ;; Poison this context's native-value entry. A later context must neither
    ;; consult that history nor reuse either cached binding cell.
    (consent-identity-map-set!
     cache native-symbol:consent-symbol? 'old-context-poison)
    (let* ((later-context
            (new-eval-context
             '((internal-libraries-allowed . #t))))
           (later-environment (consent-make-empty-environment))
           (later-library
            (resolve-library
             '(consent symbol) later-context later-environment))
           (later-cache
            (context-native-binding-cache later-context)))
      (test-assert
       'native-binding-cache-not-reused-across-contexts
       (not (eq? cache later-cache)))
      (test-assert
       'native-binding-cache-does-not-scan-old-context
       (not
        (eq?
         'old-context-poison
         (consent-identity-map-ref
          later-cache native-symbol:consent-symbol? #f))))
      (test-assert
       'native-procedure-cell-not-reused-across-contexts
       (not
        (eq?
         procedure-cell
         (test-library-binding-cell
          later-library 'consent-symbol?))))
      (test-assert
       'native-data-cell-not-reused-across-contexts
       (not
        (eq?
         data-cell
         (test-library-binding-cell
          later-library 'consent-default-symbol-table))))))))

(datum-direct-host-case
 'native-symbol-intern-copies-owned-name
 '(portable runtime datum boundary symbol)
(begin
  (if (not datum-compiled-host-run?)
      (register-native-symbol-test-library!))
  (test-assert
   'native-symbol-intern-copies-owned-name
   (consent-eval-source
    "(import (only (consent symbol)
                   consent-intern-symbol
                   consent-make-symbol-table
                   consent-symbol=?))
     (let ((table (consent-make-symbol-table)))
       (consent-symbol=?
        (consent-intern-symbol table \"borrowed-name\")
        (consent-intern-symbol table \"borrowed-name\")))"
    #f
    '((internal-libraries-allowed . #t))))))

(datum-direct-host-case
 'native-core-borrow-policy-fails-closed
 '(portable runtime datum boundary registry)
(let ((resolve-condition
       (lambda (bindings)
         (consent-register-native-library! '(consent symbol) bindings)
         (guard (condition (else condition))
           (resolve-library
            '(consent symbol)
            (new-eval-context
             '((internal-libraries-allowed . #t)))
            (consent-make-empty-environment))
           #f))))
  (test-assert
   'native-core-borrow-binding-must-be-present
   (resolve-condition
    (let loop ((rest (native-symbol-test-bindings)) (result '()))
      (cond
       ((null? rest) (reverse result))
       ((consent-host-symbol-eq?
         'consent-intern-symbol (car (car rest)))
        (loop (cdr rest) result))
       (else (loop (cdr rest) (cons (car rest) result)))))))
  (test-assert
   'native-core-borrow-binding-must-be-procedure
   (resolve-condition
    (native-symbol-bindings-with 'consent-intern-symbol #f)))
  (test-assert
   'native-core-borrow-binding-must-be-unique
   (resolve-condition
    (cons
     (cons 'consent-intern-symbol native-symbol:consent-intern-symbol)
     (native-symbol-test-bindings))))
  (let ((captured #f))
    (consent-register-native-library!
     '(consent symbol)
     (native-symbol-bindings-with
      'consent-symbol-name
      (lambda (value)
        (set! captured value)
        'captured)))
    (let* ((context
            (new-eval-context
             '((internal-libraries-allowed . #t))))
           (library
            (resolve-library
             '(consent symbol)
             context
             (consent-make-empty-environment)))
           (callable
            (cell-value
             (test-library-binding-cell library 'consent-symbol-name)))
           (owned
            (consent-datum-cons (context-datum-heap context) 'head 'tail))
           (wrapper (vector 'private-host-wrapper owned))
           (condition
            (guard (raised (else raised))
              (consent-apply-callable callable (list wrapper))
              #f)))
      (test-assert 'nested-owned-borrow-is-rejected condition)
      (test-equal 'denied-native-binding-is-not-invoked #f captured)))))

(testing-runner-main "Consent Datum portable tests" (command-line))
