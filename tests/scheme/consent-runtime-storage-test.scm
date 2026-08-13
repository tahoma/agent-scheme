;;; Portable bootstrap-safe runtime storage tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent runtime-storage)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return whether THUNK raises a Scheme condition."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (stats-ref stats name)
  "Return NAME's value from private storage STATS."
  (let ((field (assq name (cdr stats))))
    (if field (cadr field) #f)))

(define (append-integers! grow count)
  "Append integers below COUNT to GROW."
  (let loop ((index 0))
    (if (< index count)
        (begin
          (consent-growable-vector-append! grow index)
          (loop (+ index 1))))))

(testing-registry-case
 'growable-vector-contract '(portable runtime storage)
(let ((grow (consent-make-growable-vector 2 16)))
  (test-assert 'growable-vector-predicate
               (consent-growable-vector? grow))
  (test-equal 'growable-vector-initial-length
              0
              (consent-growable-vector-length grow))
  (test-equal 'growable-vector-initial-capacity
              2
              (consent-growable-vector-capacity grow))
  (test-equal 'growable-vector-first-index
              0
              (consent-growable-vector-append! grow 'first))
  (test-equal 'growable-vector-second-index
              1
              (consent-growable-vector-append! grow 'second))
  (test-equal 'growable-vector-geometric-index
              2
              (consent-growable-vector-append! grow 'third))
  (consent-growable-vector-set! grow 1 'changed)
  (test-equal 'growable-vector-indexed-ref
              'changed
              (consent-growable-vector-ref grow 1))
  (let ((snapshot (consent-growable-vector-snapshot grow)))
    (test-equal 'growable-vector-snapshot
                '#(first changed third)
                snapshot)
    (vector-set! snapshot 0 'mutated)
    (test-equal 'growable-vector-snapshot-is-detached
                'first
                (consent-growable-vector-ref grow 0)))
  (consent-growable-vector-reserve! grow 9)
  (test-equal 'growable-vector-explicit-reserve
              9
              (consent-growable-vector-capacity grow))
  (consent-growable-vector-grow! grow 10)
  (test-equal 'growable-vector-explicit-geometric-grow
              16
              (consent-growable-vector-capacity grow))
  (test-equal 'growable-vector-configured-maximum
              16
              (consent-growable-vector-maximum-capacity grow))
  (test-assert 'growable-vector-unused-slots-cleared
               (consent-growable-vector-unused-slots-cleared? grow))))

(testing-registry-case
 'growable-vector-amortized-growth '(portable runtime storage performance)
(let ((grow (consent-make-growable-vector 1 2048)))
  (append-integers! grow 1025)
  (let ((stats (consent-growable-vector-stats grow)))
    (test-equal 'amortized-growth-logical-elements
                1025
                (stats-ref stats 'length))
    (test-equal 'amortized-growth-reserved-capacity
                2048
                (stats-ref stats 'capacity))
    (test-equal 'amortized-growth-high-water
                1025
                (stats-ref stats 'high-water))
    (test-equal 'amortized-growth-count
                11
                (stats-ref stats 'growths))
    (test-equal 'amortized-growth-copied-elements
                2047
                (stats-ref stats 'copied-elements))
    (test-assert 'amortized-growth-copy-work-is-linear
                 (< (stats-ref stats 'copied-elements)
                    (* 2 (stats-ref stats 'length)))))))

(testing-registry-case
 'growable-vector-reset-release-and-errors
 '(portable runtime storage error)
(let ((grow (consent-make-growable-vector 8 8)))
  (consent-growable-vector-append! grow (vector 'owned-reference))
  (consent-growable-vector-append! grow (cons 'owned 'reference))
  (test-assert 'growable-vector-negative-index-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-ref grow -1))))
  (test-assert 'growable-vector-unpopulated-index-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-set! grow 2 'outside))))
  (test-assert 'growable-vector-maximum-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-reserve! grow 9))))
  (consent-growable-vector-reset! grow)
  (test-equal 'growable-vector-reset-length
              0
              (consent-growable-vector-length grow))
  (test-equal 'growable-vector-reset-keeps-capacity
              8
              (consent-growable-vector-capacity grow))
  (test-assert 'growable-vector-reset-clears-retained-references
               (consent-growable-vector-unused-slots-cleared? grow))
  (consent-growable-vector-release! grow)
  (test-assert 'growable-vector-release-is-terminal
               (not (consent-growable-vector-active? grow)))
  (test-assert 'growable-vector-release-drops-storage
               (and
                (= 0 (stats-ref
                      (consent-growable-vector-stats grow) 'capacity))
                (consent-growable-vector-unused-slots-cleared? grow)))
  (test-assert 'growable-vector-released-operation-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-append! grow 'stale)))))
(test-assert 'growable-vector-malformed-initial-capacity-rejected
             (raises?
              (lambda ()
                (consent-make-growable-vector -1 8))))
(test-assert 'growable-vector-malformed-maximum-rejected
             (raises?
              (lambda ()
                (consent-make-growable-vector 0 1.0))))
(test-assert 'growable-vector-inverted-capacity-rejected
             (raises?
              (lambda ()
                (consent-make-growable-vector 9 8)))))

(testing-registry-case
 'scratch-arena-pre-reserved-lifetime '(portable runtime storage arena)
(let* ((arena (consent-make-scratch-arena 4 8 'pre-reserved)))
  (consent-scratch-arena-reserve! arena 8)
  (let ((owner (consent-scratch-arena-acquire! arena 'trace)))
    (test-equal 'scratch-owner-phase
                'trace
                (consent-scratch-owner-phase owner))
    (test-equal 'scratch-owner-capacity
                8
                (consent-scratch-owner-capacity owner))
    (consent-scratch-owner-append! owner 'root-0)
    (consent-scratch-owner-append! owner 'root-1)
    (let ((mark (consent-scratch-owner-mark owner)))
      (consent-scratch-owner-append! owner (vector 'temporary-0))
      (consent-scratch-owner-append! owner (vector 'temporary-1))
      (consent-scratch-owner-set! owner 0 'root-updated)
      (test-equal 'scratch-owner-indexed-ref
                  'root-updated
                  (consent-scratch-owner-ref owner 0))
      (consent-scratch-owner-reset! owner mark)
      (test-equal 'scratch-owner-reset-length
                  2
                  (consent-scratch-owner-length owner))
      (test-assert 'scratch-owner-reset-clears-suffix
                   (consent-scratch-arena-unused-slots-cleared? arena)))
    (consent-scratch-owner-release! owner)
    (test-assert 'scratch-release-invalidates-owner
                 (not (consent-scratch-owner-active? owner)))
    (test-assert 'scratch-release-rejects-escaped-operation
                 (raises?
                  (lambda ()
                    (consent-scratch-owner-ref owner 0)))))
  (let ((stats (consent-scratch-arena-stats arena)))
    (test-equal 'scratch-stats-logical-elements
                0
                (stats-ref stats 'length))
    (test-equal 'scratch-stats-reserved-capacity
                8
                (stats-ref stats 'capacity))
    (test-equal 'scratch-stats-high-water
                4
                (stats-ref stats 'high-water))
    (test-equal 'scratch-stats-resets
                1
                (stats-ref stats 'resets))
    (test-equal 'scratch-stats-releases
                1
                (stats-ref stats 'releases))
    (test-assert 'scratch-release-clears-retained-references
                 (consent-scratch-arena-unused-slots-cleared? arena)))))

(testing-registry-case
 'scratch-arena-growth-policy '(portable runtime storage arena error)
(let* ((fixed (consent-make-scratch-arena 2 4 'pre-reserved))
       (fixed-owner
        (consent-scratch-arena-acquire! fixed 'collector-mark)))
  (consent-scratch-owner-append! fixed-owner 'left)
  (consent-scratch-owner-append! fixed-owner 'right)
  (test-assert 'pre-reserved-active-growth-fails-closed
               (raises?
                (lambda ()
                  (consent-scratch-owner-append! fixed-owner 'overflow))))
  (test-assert 'active-arena-reserve-rejected
               (raises?
                (lambda ()
                  (consent-scratch-arena-reserve! fixed 4))))
  (test-assert 'nested-arena-acquire-rejected
               (raises?
                (lambda ()
                  (consent-scratch-arena-acquire! fixed 'nested))))
  (let ((stale-mark (consent-scratch-owner-mark fixed-owner)))
    (consent-scratch-owner-release! fixed-owner)
    (let ((next-owner
           (consent-scratch-arena-acquire! fixed 'collector-sweep)))
      (test-assert 'stale-scratch-mark-rejected
                   (raises?
                    (lambda ()
                      (consent-scratch-owner-reset!
                       next-owner stale-mark))))
      (consent-scratch-owner-release! next-owner))))
(let* ((growing (consent-make-scratch-arena 1 8 'allow-growth))
       (owner (consent-scratch-arena-acquire! growing 'graph)))
  (let loop ((index 0))
    (if (< index 8)
        (begin
          (consent-scratch-owner-append! owner index)
          (loop (+ index 1)))))
  (test-equal 'allow-growth-reaches-maximum
              8
              (consent-scratch-owner-capacity owner))
  (test-assert 'allow-growth-maximum-fails-closed
               (raises?
                (lambda ()
                  (consent-scratch-owner-append! owner 8))))
  (consent-scratch-owner-release! owner))
(test-assert 'scratch-invalid-growth-policy-rejected
             (raises?
              (lambda ()
                (consent-make-scratch-arena 0 8 'collector-heap)))))

(testing-registry-case
 'scratch-arena-dynamic-cleanup-and-reentry
 '(portable runtime storage arena continuation error)
(let* ((arena (consent-make-scratch-arena 4 4 'pre-reserved))
       (owner (consent-scratch-arena-acquire! arena 'exception))
       (condition #f)
       (reentry-condition #f)
       (continuation #f)
       (first-continuation-return? #t)
       (reentered? #f))
  (guard (caught
          (else (set! condition caught)))
    (dynamic-wind
     (lambda ()
       (if (not (consent-scratch-owner-active? owner))
           (error "scratch owner is not active")))
     (lambda ()
       (consent-scratch-owner-append! owner (vector 'temporary))
       (error "forced scratch owner unwind"))
     (lambda ()
       (consent-scratch-owner-release! owner))))
  (test-assert 'scratch-exception-observed condition)
  (test-assert 'scratch-exception-invalidates-owner
               (not (consent-scratch-owner-active? owner)))
  (test-assert 'scratch-exception-clears-references
               (consent-scratch-arena-unused-slots-cleared? arena))
  (let ((saved-runner (test-runner-current)))
    (set!
     reentry-condition
     (call/cc
      (lambda (finish)
        (guard
         (caught (else (finish caught)))
         (let* ((reentry-owner
                 (consent-scratch-arena-acquire! arena 'reentry))
                (value
                 (dynamic-wind
                  (lambda ()
                    (if (not (consent-scratch-owner-active? reentry-owner))
                        (set! reentered? #t)))
                  (lambda ()
                    (if reentered?
                        (error
                         "scratch owner continuation cannot be re-entered")
                        (begin
                          (consent-scratch-owner-append!
                           reentry-owner 'temporary)
                          (call/cc
                           (lambda (return)
                             (set! continuation return)
                             'initial-return)))))
                  (lambda ()
                    (if (consent-scratch-owner-active? reentry-owner)
                        (consent-scratch-owner-release! reentry-owner))))))
           (if first-continuation-return?
               (begin
                 (set! first-continuation-return? #f)
                 (continuation 'reentered))
               (finish value)))))))
    ;; Continuation transfer may temporarily unwind parameter guards.  Restore
    ;; the registry runner before recording results.
    (test-runner-current saved-runner))
  (test-assert 'scratch-continuation-reentry-fails-closed reentry-condition)
  (test-assert 'scratch-reentry-keeps-arena-cleared
               (consent-scratch-arena-unused-slots-cleared? arena))))

(testing-registry-case
 'scratch-arena-synthetic-collector-workload
 '(portable runtime storage arena collector performance)
(let ((arena (consent-make-scratch-arena 2048 2048 'pre-reserved)))
  (let cycle ((cycle-index 0))
    (if (< cycle-index 4)
        (let ((owner
               (consent-scratch-arena-acquire! arena 'collector-trace)))
          (let roots ((index 0))
            (if (< index 1024)
                (begin
                  (consent-scratch-owner-append! owner index)
                  (roots (+ index 1)))))
          (let ((mark (consent-scratch-owner-mark owner)))
            (let edges ((index 1024))
              (if (< index 2048)
                  (begin
                    (consent-scratch-owner-append! owner index)
                    (edges (+ index 1)))))
            (consent-scratch-owner-reset! owner mark)
            (let retry ((index 1024))
              (if (< index 2048)
                  (begin
                    (consent-scratch-owner-append! owner index)
                    (retry (+ index 1))))))
          (consent-scratch-owner-release! owner)
          (cycle (+ cycle-index 1)))))
  (let ((stats (consent-scratch-arena-stats arena)))
    (test-equal 'collector-workload-logical-elements
                0
                (stats-ref stats 'length))
    (test-equal 'collector-workload-reserved-capacity
                2048
                (stats-ref stats 'capacity))
    (test-equal 'collector-workload-high-water
                2048
                (stats-ref stats 'high-water))
    (test-equal 'collector-workload-acquisitions
                4
                (stats-ref stats 'acquisitions))
    (test-equal 'collector-workload-resets
                4
                (stats-ref stats 'resets))
    (test-equal 'collector-workload-releases
                4
                (stats-ref stats 'releases))
    (test-equal 'collector-workload-active-growths
                0
                (stats-ref stats 'storage-growths))
    (test-equal 'collector-workload-copied-elements
                0
                (stats-ref stats 'storage-copied-elements))
    (test-assert 'collector-workload-clears-all-roots
                 (consent-scratch-arena-unused-slots-cleared? arena)))))

(testing-runner-main "Consent runtime storage" (command-line))
