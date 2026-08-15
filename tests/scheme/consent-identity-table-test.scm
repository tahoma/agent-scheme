;;; Portable fixed-policy identity-table tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent identity-map)
        (consent identity-table)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raised-condition thunk)
  "Return THUNK's raised condition, or false after normal return."
  (guard (condition
          (else condition))
    (thunk)
    #f))

(define (raises? thunk)
  "Return whether THUNK raises a Scheme condition."
  (if (raised-condition thunk) #t #f))

(define (stats-ref stats name)
  "Return NAME's value from identity-table STATS."
  (let ((field (assq name (cdr stats))))
    (if field (cadr field) #f)))

(define (make-distinct-keys count)
  "Return COUNT freshly allocated vector identity keys."
  (let loop ((index 0) (keys '()))
    (if (= index count)
        (reverse keys)
        (loop (+ index 1) (cons (vector 'key index) keys)))))

(define (identity-table-scale-work count)
  "Build and read COUNT owned identities and return deterministic work."
  (let ((table
         (consent-make-identity-table
          0 (* count 8) 'allow-growth 'owned 'scale)))
    (let insert ((object-id 0))
      (if (< object-id count)
          (begin
            (consent-identity-table-owned-set!
             table 7 object-id (vector object-id) object-id)
            (insert (+ object-id 1)))))
    (let lookup ((object-id 0))
      (if (< object-id count)
          (begin
            (test-equal
             'identity-table-scale-lookup
             object-id
             (consent-identity-table-owned-ref
              table 7 object-id #f))
            (lookup (+ object-id 1)))))
    (let* ((stats (consent-identity-table-stats table))
           (work
            (+ (stats-ref stats 'hashes)
               (stats-ref stats 'probe-steps)
               (stats-ref stats 'rehashed-entries))))
      (test-equal 'identity-table-scale-inserts
                  count
                  (stats-ref stats 'inserts))
      (test-equal 'identity-table-scale-hashes
                  (* count 2)
                  (stats-ref stats 'hashes))
      (consent-identity-table-release! table)
      work)))

(define (identity-table-host-scale-work count)
  "Build and read COUNT host identities and return deterministic work."
  (let ((table
         (consent-make-identity-table
          0 (* count 8) 'allow-growth 'host 'host-scale))
        (keys (make-distinct-keys count)))
    (if (not (consent-identity-table-fast-host-backend? table))
        (error "identity-table-host-scale-work: fast backend required"))
    (let insert ((rest keys) (index 0))
      (if (pair? rest)
          (begin
            (consent-identity-table-host-set! table (car rest) index)
            (insert (cdr rest) (+ index 1)))))
    (let lookup ((rest keys) (index 0))
      (if (pair? rest)
          (begin
            (test-equal
             'identity-table-host-scale-lookup
             index
             (consent-identity-table-host-ref
              table (car rest) #f))
            (lookup (cdr rest) (+ index 1)))))
    (let* ((stats (consent-identity-table-stats table))
           (work
            (+ (stats-ref stats 'hashes)
               (stats-ref stats 'probe-steps)
               (stats-ref stats 'rehashed-entries))))
      (test-equal 'identity-table-host-scale-inserts
                  count
                  (stats-ref stats 'inserts))
      (test-equal 'identity-table-host-scale-hashes
                  (* count 2)
                  (stats-ref stats 'hashes))
      (consent-identity-table-release! table)
      work)))

(testing-registry-case
 'identity-table-host-identity-cycle-sharing-and-delete
 '(portable runtime storage identity hash cycle sharing mutation)
(let* ((table
        (consent-make-identity-table
         3 127 'allow-growth 'host 'host-graph))
       (left (vector 'equal))
       (right (vector 'equal))
       (same-text-left (string #\s #\a #\m #\e))
       (same-text-right (string #\s #\a #\m #\e))
       (shared (vector 'shared)))
  (vector-set! left 0 left)
  (vector-set! right 0 right)
  (test-assert 'identity-table-distinct-host-keys
               (not (eq? left right)))
  (consent-identity-table-host-set! table left shared)
  (consent-identity-table-host-set! table right #f)
  (test-assert 'identity-table-equal-distinct-host-keys
               (and (equal? same-text-left same-text-right)
                    (not (eq? same-text-left same-text-right))))
  (consent-identity-table-host-set! table same-text-left 'left)
  (consent-identity-table-host-set! table same-text-right 'right)
  (test-equal 'identity-table-equal-distinct-left
              'left
              (consent-identity-table-host-ref
               table same-text-left 'absent))
  (test-equal 'identity-table-equal-distinct-right
              'right
              (consent-identity-table-host-ref
               table same-text-right 'absent))
  (test-assert 'identity-table-stored-false-is-present
               (consent-identity-table-host-contains? table right))
  (test-equal 'identity-table-stored-false
              #f
              (consent-identity-table-host-ref table right 'absent))
  (test-assert 'identity-table-sharing-value-preserved
               (eq? shared
                    (consent-identity-table-host-ref
                     table left 'absent)))
  (consent-identity-table-host-set! table left 'updated)
  (test-equal 'identity-table-host-update
              'updated
              (consent-identity-table-host-ref table left 'absent))
  (test-assert 'identity-table-host-delete-hit
               (consent-identity-table-host-delete! table right))
  (test-assert 'identity-table-host-delete-miss
               (not (consent-identity-table-host-delete! table right)))
  (test-equal 'identity-table-deleted-host-key
              'absent
              (consent-identity-table-host-ref table right 'absent))
  (let ((stats (consent-identity-table-stats table)))
    (test-equal 'identity-table-host-size 3
                (stats-ref stats 'size))
    (test-equal 'identity-table-host-inserts 4
                (stats-ref stats 'inserts))
    (test-equal 'identity-table-host-lookups 7
                (stats-ref stats 'lookups))
    (test-equal 'identity-table-host-sets 5
                (stats-ref stats 'sets))
    (test-equal 'identity-table-host-updates 1
                (stats-ref stats 'updates))
    (test-equal 'identity-table-host-deletes 2
                (stats-ref stats 'deletes))
    (test-equal 'identity-table-host-delete-hits 1
                (stats-ref stats 'delete-hits))
    (test-equal 'identity-table-host-delete-needs-no-tombstone 0
                (stats-ref stats 'tombstones))
    (test-equal 'identity-table-host-misses 2
                (stats-ref stats 'misses))
    (test-assert 'identity-table-host-work-counted
                 (> (+ (stats-ref stats 'probe-steps)
                       (stats-ref stats 'compatibility-scan-steps))
                    0)))
  (test-equal 'identity-table-host-snapshot-size
              3
              (length (consent-identity-table-entries table)))
  (let ((callback-count 0)
        (procedure-key
         (lambda () (set! callback-count (+ callback-count 1)))))
    (consent-identity-table-host-set! table procedure-key 'procedure)
    (test-equal 'identity-table-procedure-key-ref
                'procedure
                (consent-identity-table-host-ref
                 table procedure-key 'absent))
    (consent-identity-table-host-delete! table procedure-key)
    (test-equal 'identity-table-never-invokes-key
                0
                callback-count))
  (consent-identity-table-release! table)))

(testing-registry-case
 'identity-table-owned-and-host-namespaces-are-distinct
 '(portable runtime storage identity owned mixed root)
(let* ((table
        (consent-make-identity-table
         5 127 'allow-growth 'mixed 'mixed-graph))
       (owned-root (vector 'owned-root))
       (replacement-root (vector 'replacement-root)))
  (consent-identity-table-owned-set!
   table 11 4 owned-root 'owned-value)
  (consent-identity-table-owned-set!
   table 12 4 replacement-root 'other-heap)
  (consent-identity-table-host-set!
   table owned-root 'host-value)
  (test-equal 'identity-table-owned-lookup
              'owned-value
              (consent-identity-table-owned-ref table 11 4 'absent))
  (test-equal 'identity-table-other-heap-lookup
              'other-heap
              (consent-identity-table-owned-ref table 12 4 'absent))
  (test-equal 'identity-table-host-namespace-lookup
              'host-value
              (consent-identity-table-host-ref
               table owned-root 'absent))
  (consent-identity-table-owned-set!
   table 11 4 replacement-root 'stable-id-update)
  (test-equal 'identity-table-owned-id-controls-update
              'stable-id-update
              (consent-identity-table-owned-ref table 11 4 'absent))
  (let find-updated-root ((rest (consent-identity-table-entries table)))
    (if (and (pair? rest)
             (not (and (eq? (car (car rest)) 'owned)
                       (= (cadr (car rest)) 11)
                       (= (list-ref (car rest) 2) 4))))
        (find-updated-root (cdr rest))
        (test-assert 'identity-table-owned-update-replaces-root
                     (and (pair? rest)
                          (eq? (list-ref (car rest) 3)
                               replacement-root)))))
  (test-equal 'identity-table-mixed-size 3
              (consent-identity-table-size table))
  (let ((entries (consent-identity-table-entries table)))
    (test-equal 'identity-table-snapshot-count 3 (length entries))
    (test-assert 'identity-table-snapshot-has-owned
                 (assq 'owned entries))
    (test-assert 'identity-table-snapshot-has-host
                 (assq 'host entries)))
  (consent-identity-table-clear! table)
  (test-equal 'identity-table-clear-size
              0
              (consent-identity-table-size table))
  (test-equal 'identity-table-clear-drops-owned-root
              'absent
              (consent-identity-table-owned-ref table 11 4 'absent))
  (test-equal 'identity-table-clear-drops-host-root
              'absent
              (consent-identity-table-host-ref
               table owned-root 'absent))
  (test-equal 'identity-table-clear-snapshot-empty
              '()
              (consent-identity-table-entries table))
  (consent-identity-table-release! table)))

(testing-registry-case
 'identity-table-growth-tombstones-and-storage-limits
 '(portable runtime storage identity growth tombstone boundary error)
(let ((table
       (consent-make-identity-table
        8 127 'allow-growth 'host 'compact-host-reserve)))
  (consent-identity-table-reserve! table 1)
  (test-equal 'identity-table-reserve-honors-initial-floor
              8
              (consent-identity-table-capacity table))
  (consent-identity-table-release! table))
(let ((table
       (consent-make-identity-table
        8 127 'allow-growth 'host 'compact-host-growth)))
  (test-equal 'identity-table-growable-starts-without-buckets
              0
              (consent-identity-table-capacity table))
  (let insert ((id 0))
    (if (< id 8)
        (begin
          (consent-identity-table-host-set! table (vector id) id)
          (insert (+ id 1)))))
  (test-equal 'identity-table-host-fills-initial-buckets
              8
              (consent-identity-table-capacity table))
  (consent-identity-table-host-set! table (vector 8) 8)
  (test-equal 'identity-table-host-grows-after-one-per-bucket
              17
              (consent-identity-table-capacity table))
  (test-equal 'identity-table-host-relinks-live-entries
              8
              (stats-ref
               (consent-identity-table-stats table)
               'rehashed-entries))
  (consent-identity-table-release! table))
(let ((table
       (consent-make-identity-table
        8 16 'pre-reserved 'host 'full-host-reserve)))
  (let insert ((id 0))
    (if (< id 8)
        (begin
          (consent-identity-table-host-set! table (vector id) id)
          (insert (+ id 1)))))
  (test-equal 'identity-table-host-reserve-uses-full-capacity
              8
              (consent-identity-table-size table))
  (test-assert 'identity-table-host-reserve-fails-when-full
               (raises?
                (lambda ()
                  (consent-identity-table-host-set!
                   table (vector 8) 8))))
  (consent-identity-table-release! table))
(let ((table
       (consent-make-identity-table
        0 31 'allow-growth 'owned 'growth)))
  (let insert ((id 0))
    (if (< id 12)
        (begin
          (consent-identity-table-owned-set!
           table 1 id (vector id) id)
          (insert (+ id 1)))))
  (test-assert 'identity-table-grew
               (> (consent-identity-table-capacity table) 0))
  (consent-identity-table-owned-delete! table 1 3)
  (consent-identity-table-owned-delete! table 1 7)
  (test-equal 'identity-table-tombstones-counted
              2
              (stats-ref
               (consent-identity-table-stats table) 'tombstones))
  (consent-identity-table-owned-set!
   table 1 20 (vector 20) 'twenty)
  (test-equal 'identity-table-post-delete-insert
              'twenty
              (consent-identity-table-owned-ref table 1 20 #f))
  (consent-identity-table-release! table))
(let ((table
       (consent-make-identity-table
        0 8 'pre-reserved 'owned 'collector-phase)))
  (test-assert 'identity-table-pre-reserved-empty-rejects
               (raises?
                (lambda ()
                  (consent-identity-table-owned-set!
                   table 0 0 (vector 0) #t))))
  (consent-identity-table-reserve! table 8)
  (let insert ((id 0))
    (if (< id 5)
        (begin
          (consent-identity-table-owned-set!
           table 0 id (vector id) id)
          (insert (+ id 1)))))
  (test-assert 'identity-table-load-factor-fails-closed
               (raises?
                (lambda ()
                  (consent-identity-table-owned-set!
                   table 0 5 (vector 5) 5))))
  (test-equal 'identity-table-failed-insert-preserves-size
              5
              (consent-identity-table-size table))
  (test-assert 'identity-table-reserve-over-limit-rejected
               (raises?
                (lambda ()
                  (consent-identity-table-reserve! table 9))))
  (consent-identity-table-release! table))
(let ((table
       (consent-make-identity-table
        0 1 'allow-growth 'owned 'undersized-maximum)))
  (test-assert 'identity-table-undersized-maximum-fails-closed
               (raises?
                (lambda ()
                  (consent-identity-table-owned-set!
                   table 0 0 (vector 0) #t))))
  (test-equal 'identity-table-undersized-maximum-preserves-capacity
              0
              (consent-identity-table-capacity table))
  (test-equal 'identity-table-undersized-maximum-preserves-size
              0
              (consent-identity-table-size table))
  (consent-identity-table-release! table)))

(testing-registry-case
 'identity-table-probes-filter-by-full-hash
 '(portable runtime storage identity performance hash)
(let ((table
       (consent-make-identity-table
        5 5 'pre-reserved 'owned 'full-hash-filter)))
  ;; These identities start in the same bucket but have different complete
  ;; hashes. Only the matching entry requires a fixed identity comparison.
  (consent-identity-table-owned-set! table 0 0 (vector 0) 'zero)
  (consent-identity-table-owned-set! table 0 5 (vector 5) 'five)
  (test-equal 'identity-table-full-hash-collision-lookup
              'five
              (consent-identity-table-owned-ref table 0 5 'absent))
  (let ((stats (consent-identity-table-stats table)))
    (test-assert 'identity-table-full-hash-probed-collision
                 (> (stats-ref stats 'probe-steps) 3))
    (test-equal 'identity-table-full-hash-one-identity-test
                1
                (stats-ref stats 'identity-tests)))
  (consent-identity-table-release! table)))

(testing-registry-case
 'identity-table-forced-nohash-envelope
 '(portable runtime storage identity nohash bounded error)
(let* ((table
       (consent-make-identity-table
         32 128 'pre-reserved 'host 'forced-nohash 'compatibility))
       (keys (make-distinct-keys 65)))
  (test-assert 'identity-table-forced-nohash-selected
               (not
                (consent-identity-table-fast-host-backend? table)))
  (test-equal 'identity-table-nohash-has-no-unused-buckets
              0
              (consent-identity-table-capacity table))
  (consent-identity-table-reserve! table 32)
  (test-equal 'identity-table-nohash-reserve-stays-bucketless
              0
              (consent-identity-table-capacity table))
  (let insert ((rest keys) (count 0))
    (if (< count 64)
        (begin
          (consent-identity-table-host-set!
           table (car rest) count)
          (insert (cdr rest) (+ count 1)))))
  (test-equal 'identity-table-nohash-limit-size
              64
              (consent-identity-table-size table))
  (test-equal 'identity-table-nohash-last-lookup
              63
              (consent-identity-table-host-ref
               table (list-ref keys 63) 'absent))
  (let* ((before (consent-identity-table-stats table))
         (condition
          (raised-condition
           (lambda ()
             (consent-identity-table-host-set!
              table (list-ref keys 64) 'overflow))))
         (after (consent-identity-table-stats table)))
    (test-assert 'identity-table-nohash-overflow-rejected condition)
    (test-equal 'identity-table-nohash-overflow-preserves-size
                64
                (stats-ref after 'size))
    (test-equal 'identity-table-nohash-never-hashes
                0
                (stats-ref after 'hashes))
    (test-equal 'identity-table-nohash-one-bounded-final-scan
                64
                (- (stats-ref after 'compatibility-scan-steps)
                   (stats-ref before 'compatibility-scan-steps)))
    (test-equal 'identity-table-nohash-limit-reported
                64
                (stats-ref after 'compatibility-limit)))
  (consent-identity-table-release! table)))

(testing-registry-case
 'identity-table-counted-linear-scale
 '(portable runtime storage identity performance scale)
(let ((small (identity-table-scale-work 128))
      (large (identity-table-scale-work 256))
      (host-small (identity-table-host-scale-work 128))
      (host-large (identity-table-host-scale-work 256)))
  (test-assert 'identity-table-small-linear-work-bound
               (< small (* 128 24)))
  (test-assert 'identity-table-large-linear-work-bound
               (< large (* 256 24)))
  (test-assert 'identity-table-doubling-remains-linear
               (< large (+ (* small 3) 64)))
  (test-assert 'identity-table-host-small-linear-work-bound
               (< host-small (* 128 48)))
  (test-assert 'identity-table-host-large-linear-work-bound
               (< host-large (* 256 48)))
  (test-assert 'identity-table-host-doubling-remains-linear
               (< host-large (+ (* host-small 3) 128)))))

(testing-registry-case
 'identity-table-host-hash-bursts-remain-distributed
 '(portable runtime storage identity performance hash)
(let* ((capacity 2303)
       (batch-size 300)
       (advance-count (- capacity batch-size))
       (table
        (consent-make-identity-table
         capacity capacity 'pre-reserved 'host 'host-hash-bursts))
       (first (make-distinct-keys batch-size)))
  (let insert ((rest first) (index 0))
    (if (pair? rest)
        (begin
          (consent-identity-table-host-set! table (car rest) index)
          (insert (cdr rest) (+ index 1)))))
  ;; Gambit's audited identity hash assigns stable allocation serials. Advance
  ;; by one bucket-capacity interval before a second retained burst. Raw modulo
  ;; indexing overlays the bursts and becomes quadratic; portable mixing must
  ;; keep the fixed-policy table within a linear-work envelope.
  (let ((transient (make-distinct-keys advance-count)))
    (for-each consent-host-identity-hash transient)
    (let ((second (make-distinct-keys batch-size)))
      (let insert ((rest second) (index batch-size))
        (if (pair? rest)
            (begin
              (consent-identity-table-host-set! table (car rest) index)
              (insert (cdr rest) (+ index 1)))))
      (let lookup ((rest (append first second)) (index 0))
        (if (pair? rest)
            (begin
              (test-equal
               'identity-table-host-hash-burst-lookup
               index
               (consent-identity-table-host-ref
                table (car rest) #f))
              (lookup (cdr rest) (+ index 1)))))))
  (let ((stats (consent-identity-table-stats table)))
    (test-equal 'identity-table-host-hash-burst-size
                (* batch-size 2)
                (stats-ref stats 'size))
    (test-assert 'identity-table-host-hash-burst-linear-work
                 (< (stats-ref stats 'probe-steps)
                    (* batch-size 2 16))))
  (consent-identity-table-release! table)))

(testing-registry-case
 'identity-table-release-exception-and-continuation-reentry
 '(portable runtime storage identity release continuation error)
(let ((table
       (consent-make-identity-table
        4 16 'allow-growth 'host 'exception-scope))
      (condition #f))
  (guard (caught
          (else (set! condition caught)))
    (dynamic-wind
     (lambda ()
       (if (not (consent-identity-table-active? table))
           (error "identity table is not active")))
     (lambda ()
       (consent-identity-table-host-set! table (vector 'root) 'value)
       (error "forced identity-table unwind"))
     (lambda ()
       (consent-identity-table-release! table))))
  (test-assert 'identity-table-exception-observed condition)
  (test-assert 'identity-table-exception-released
               (not (consent-identity-table-active? table)))
  (test-assert 'identity-table-released-ref-rejected
               (raises?
                (lambda ()
                  (consent-identity-table-host-ref
                   table (vector 'root) #f))))
  (let ((stats (consent-identity-table-stats table)))
    (test-equal 'identity-table-release-size 0
                (stats-ref stats 'size))
    (test-equal 'identity-table-release-capacity 0
                (stats-ref stats 'capacity))
    (test-equal 'identity-table-release-count 1
                (stats-ref stats 'releases))
    (consent-identity-table-release! table)
    (test-equal 'identity-table-release-idempotent
                stats
                (consent-identity-table-stats table))))
(let ((saved-runner (test-runner-current))
      (table
       (consent-make-identity-table
        1 8 'allow-growth 'host 'continuation-scope))
      (reentry-condition #f)
      (continuation #f)
      (first-return? #t)
      (reentered? #f))
  (set!
   reentry-condition
   (call/cc
    (lambda (finish)
      (guard
       (caught (else (finish caught)))
       (let ((value
              (dynamic-wind
               (lambda ()
                 (if (not (consent-identity-table-active? table))
                     (set! reentered? #t)))
               (lambda ()
                 (if reentered?
                     (error
                      "identity-table continuation cannot be re-entered")
                     (begin
                       (consent-identity-table-host-set!
                        table (vector 'root) 'value)
                       (call/cc
                        (lambda (return)
                          (set! continuation return)
                          'initial-return)))))
               (lambda ()
                 (consent-identity-table-release! table)))))
         (if first-return?
             (begin
               (set! first-return? #f)
               (continuation 'reentered))
             (finish value)))))))
  (test-runner-current saved-runner)
  (test-assert 'identity-table-continuation-reentry-fails
               reentry-condition)
  (test-equal 'identity-table-reentry-retains-no-roots
              0
              (stats-ref
               (consent-identity-table-stats table) 'size))))

(testing-registry-case
 'identity-map-compatibility-facade-lifecycle
 '(portable runtime storage identity compatibility)
(let ((map (consent-make-identity-map))
      (key (vector 'legacy)))
  (test-equal 'identity-map-constructor-defers-buckets
              0
              (consent-identity-table-capacity map))
  (test-equal 'identity-map-constructor-uses-adapter
              (consent-identity-map-fast-backend?)
              (consent-identity-table-fast-host-backend? map))
  (test-assert 'identity-map-facade-adjoin-inserts
               (consent-identity-map-adjoin! map key 'first))
  (test-equal 'identity-map-first-insert-uses-small-bucket-floor
              4
              (consent-identity-table-capacity map))
  (test-assert 'identity-map-facade-adjoin-preserves-existing
               (not (consent-identity-map-adjoin! map key 'ignored)))
  (test-equal 'identity-map-facade-adjoin-value
              'first
              (consent-identity-map-ref map key 'absent))
  (consent-identity-map-set! map key 'value)
  (test-equal 'identity-map-facade-ref
              'value
              (consent-identity-map-ref map key 'absent))
  (test-assert 'identity-map-facade-delete
               (consent-identity-map-delete! map key))
  (consent-identity-map-set! map key 'replacement)
  (consent-identity-map-clear! map)
  (test-equal 'identity-map-facade-clear
              'absent
              (consent-identity-map-ref map key 'absent))
  (consent-identity-map-release! map)
  (test-equal 'identity-map-facade-release-size
              0
              (stats-ref (consent-identity-map-stats map) 'size))
  (test-assert 'identity-map-facade-released-operation
               (raises?
                (lambda ()
                  (consent-identity-map-set! map key 'late))))))

(testing-runner-main "Consent identity table" (command-line))
