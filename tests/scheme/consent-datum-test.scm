;;; Portable owned compound datum heap tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (prefix (agent context) native-context:)
        (prefix (agent task) native-task:)
        (prefix (agent transcript) native-transcript:)
        (prefix (consent symbol) native-symbol:)
        (only (consent character) consent-make-character)
        (consent datum)
        (only (consent identity-map)
              consent-identity-map-ref
              consent-identity-map-set!)
        (only (consent interpreter)
              consent-eval
              consent-eval-source)
        (only (consent manifest) consent-library-manifest-ref)
        (only (consent library)
              consent-apply-callable
              consent-call-native-library
              consent-runtime-datum->native-datum
              resolve-library)
        (only (consent reader)
              consent-datum-source
              consent-datum-source-set!
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
              context-datum-heap
              context-native-binding-cache
              environment-cell
              environment-define!
              environment-set!
              library-binding-name
              library-binding-object
              library-exports
              make-primitive-procedure
              make-consent-error-object
              new-eval-context
              primitive-procedure-function
              set-context-libraries!)
        (only (consent symbol-boundary) consent-host-symbol-eq?)
        (testing registry)
        (testing runner)
        (stdlib testing))

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
  (test-assert 'direct-host-containers-stay-private
               (and (not (pair? pair))
                    (not (string? string))
                    (not (vector? vector))
                    (not (bytevector? bytevector))))))

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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
      (test-equal 'allocation-owner-propagation
                  '(branch-a branch-b)
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

(testing-registry-case
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
                    (consent-datum-object-map-ref inner object #f))))
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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
                 vector)))))

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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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
                (consent-datum-cdr left)))))

(testing-registry-case
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
                (consent-datum-cdr fresh)))))

(testing-registry-case
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
                (consent-datum-cdr fresh)))))

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
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

(testing-registry-case
 'native-compound-borrow-inventories-match-bindings
 '(portable runtime datum boundary registry)
(begin
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
    (cons 'make-context-bundle native-context:make-context-bundle)))
  (let ((context (new-eval-context '()))
        (environment (consent-make-empty-environment)))
    (test-assert
     'native-task-binding-inventory-valid
     (resolve-library '(agent task) context environment))
    (test-assert
     'native-transcript-binding-inventory-valid
     (resolve-library '(agent transcript) context environment))
    (test-assert
     'native-context-binding-inventory-valid
     (resolve-library '(agent context) context environment)))))

(testing-registry-case
 'native-binding-cache-owned-by-evaluation-context
 '(portable runtime datum boundary registry performance)
(begin
  (register-native-symbol-test-library!)
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

(testing-registry-case
 'native-symbol-intern-copies-owned-name
 '(portable runtime datum boundary symbol)
(begin
  (register-native-symbol-test-library!)
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

(testing-registry-case
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
