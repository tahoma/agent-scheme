;;; Portable bootstrap-safe scratch-arena tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent scratch-arena)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raised-condition thunk)
  "Return THUNK's raised condition, or false when it returns normally."
  (guard (condition
          (else condition))
    (thunk)
    #f))

(define (raises? thunk)
  "Return whether THUNK raises a Scheme condition."
  (if (raised-condition thunk) #t #f))

(define (error-message=? condition expected)
  "Return whether CONDITION is an error with EXPECTED message."
  (and (error-object? condition)
       (string=? (error-object-message condition) expected)))

(define (stats-ref stats name)
  "Return NAME's value from private storage STATS."
  (let ((field (assq name (cdr stats))))
    (if field (cadr field) #f)))

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
 'scratch-arena-predicates-and-state-transitions
 '(portable runtime storage arena boundary state)
(test-assert 'scratch-arena-predicate-rejects-other-values
             (not (consent-scratch-arena? 'not-an-arena)))
(test-assert 'scratch-owner-predicate-rejects-other-values
             (not (consent-scratch-owner? 'not-an-owner)))
(test-assert 'scratch-owner-active-rejects-other-values
             (not (consent-scratch-owner-active? 'not-an-owner)))
(let ((arena (consent-make-scratch-arena 0 4 'allow-growth)))
  (test-assert 'scratch-arena-predicate
               (consent-scratch-arena? arena))
  (test-equal
   'scratch-arena-initial-stats
   '(scratch-arena-stats
     (growth-policy allow-growth)
     (active #f)
     (phase #f)
     (length 0)
     (capacity 0)
     (maximum-capacity 4)
     (high-water 0)
     (acquisitions 0)
     (resets 0)
     (releases 0)
     (storage-growths 0)
     (storage-copied-elements 0))
   (consent-scratch-arena-stats arena))
  (let ((before (consent-scratch-arena-stats arena))
        (condition
         (raised-condition
          (lambda ()
            (consent-scratch-arena-acquire! arena "not-a-phase")))))
    (test-assert
     'scratch-arena-invalid-phase-has-stable-error
     (error-message=?
      condition
      "consent-scratch-arena-acquire!: expected symbolic phase"))
    (test-equal 'scratch-arena-failed-acquire-is-atomic
                before
                (consent-scratch-arena-stats arena)))
  (let ((owner (consent-scratch-arena-acquire! arena 'trace)))
    (test-assert 'scratch-owner-predicate
                 (consent-scratch-owner? owner))
    (test-assert 'scratch-owner-is-active
                 (consent-scratch-owner-active? owner))
    (test-equal 'scratch-zero-capacity-owner-length
                0
                (consent-scratch-owner-length owner))
    (test-equal 'scratch-zero-capacity-owner-capacity
                0
                (consent-scratch-owner-capacity owner))
    (test-equal 'scratch-owner-first-index
                0
                (consent-scratch-owner-append! owner 'left))
    (test-equal 'scratch-owner-second-index
                1
                (consent-scratch-owner-append! owner 'right))
    (test-equal 'scratch-owner-set-returns-value
                'changed
                (consent-scratch-owner-set! owner 1 'changed))
    (test-equal 'scratch-owner-set-persists-value
                'changed
                (consent-scratch-owner-ref owner 1))
    (test-assert 'scratch-owner-unpopulated-ref-rejected
                 (raises?
                  (lambda ()
                    (consent-scratch-owner-ref owner 2))))
    (test-assert 'scratch-owner-negative-set-rejected
                 (raises?
                  (lambda ()
                    (consent-scratch-owner-set! owner -1 'outside))))
    (test-equal
     'scratch-arena-active-stats
     '(scratch-arena-stats
       (growth-policy allow-growth)
       (active #t)
       (phase trace)
       (length 2)
       (capacity 2)
       (maximum-capacity 4)
       (high-water 2)
       (acquisitions 1)
       (resets 0)
       (releases 0)
       (storage-growths 2)
       (storage-copied-elements 1))
     (consent-scratch-arena-stats arena))
    (consent-scratch-owner-release! owner)
    (let ((released (consent-scratch-arena-stats arena)))
      (consent-scratch-owner-release! owner)
      (test-equal 'scratch-owner-double-release-is-idempotent
                  released
                  (consent-scratch-arena-stats arena))))
  (test-equal
   'scratch-arena-released-owner-stats
   '(scratch-arena-stats
     (growth-policy allow-growth)
     (active #f)
     (phase #f)
     (length 0)
     (capacity 2)
     (maximum-capacity 4)
     (high-water 2)
     (acquisitions 1)
     (resets 0)
     (releases 1)
     (storage-growths 2)
     (storage-copied-elements 1))
   (consent-scratch-arena-stats arena))))

(testing-registry-case
 'scratch-arena-mark-ownership-and-failure-atomicity
 '(portable runtime storage arena mark boundary error state)
(let* ((left-arena
        (consent-make-scratch-arena 4 4 'pre-reserved))
       (right-arena
        (consent-make-scratch-arena 4 4 'pre-reserved))
       (left-owner
        (consent-scratch-arena-acquire! left-arena 'left))
       (right-owner
        (consent-scratch-arena-acquire! right-arena 'right)))
  (consent-scratch-owner-append! left-owner 'left-root)
  (consent-scratch-owner-append! right-owner 'right-0)
  (consent-scratch-owner-append! right-owner 'right-1)
  (let ((left-mark (consent-scratch-owner-mark left-owner))
        (before (consent-scratch-arena-stats right-arena)))
    (let ((condition
           (raised-condition
            (lambda ()
              (consent-scratch-owner-reset! right-owner left-mark)))))
      (test-assert
       'scratch-cross-arena-mark-has-stable-error
       (error-message=?
        condition
        "consent-scratch-owner-reset!: mark belongs to other lifetime")))
    (test-equal 'scratch-cross-arena-mark-failure-is-atomic
                before
                (consent-scratch-arena-stats right-arena)))
  (let* ((mark (consent-scratch-owner-mark right-owner))
         (future-mark (+ mark 1))
         (before (consent-scratch-arena-stats right-arena)))
    (test-assert 'scratch-future-mark-rejected
                 (raises?
                  (lambda ()
                    (consent-scratch-owner-reset!
                     right-owner future-mark))))
    (test-assert 'scratch-negative-mark-rejected
                 (raises?
                  (lambda ()
                    (consent-scratch-owner-reset! right-owner -1))))
    (test-assert 'scratch-inexact-mark-rejected
                 (raises?
                  (lambda ()
                    (consent-scratch-owner-reset! right-owner 1.0))))
    (test-equal 'scratch-invalid-mark-failures-are-atomic
                before
                (consent-scratch-arena-stats right-arena))
    (consent-scratch-owner-append! right-owner 'temporary)
    (let ((later-mark (consent-scratch-owner-mark right-owner)))
      (consent-scratch-owner-reset! right-owner mark)
      (test-equal 'scratch-valid-mark-restores-prefix
                  2
                  (consent-scratch-owner-length right-owner))
      (test-equal 'scratch-valid-mark-preserves-prefix-values
                  '(right-0 right-1)
                  (list
                   (consent-scratch-owner-ref right-owner 0)
                   (consent-scratch-owner-ref right-owner 1)))
      (test-assert 'scratch-mark-cannot-extend-shortened-prefix
                   (raises?
                    (lambda ()
                      (consent-scratch-owner-reset!
                       right-owner later-mark))))))
  (let ((stale-mark (consent-scratch-owner-mark right-owner)))
    (consent-scratch-owner-release! right-owner)
    (let ((next-owner
           (consent-scratch-arena-acquire! right-arena 'next)))
      (test-assert 'scratch-stale-lifetime-mark-rejected
                   (raises?
                    (lambda ()
                      (consent-scratch-owner-reset!
                       next-owner stale-mark))))
      (let ((before (consent-scratch-arena-stats right-arena)))
        (consent-scratch-owner-release! right-owner)
        (test-assert 'scratch-stale-release-keeps-current-owner-active
                     (consent-scratch-owner-active? next-owner))
        (test-equal 'scratch-stale-release-does-not-change-stats
                    before
                    (consent-scratch-arena-stats right-arena)))
      (consent-scratch-owner-release! next-owner)))
  (consent-scratch-owner-release! left-owner)
  (test-assert 'scratch-mark-tests-clear-left-arena
               (consent-scratch-arena-unused-slots-cleared? left-arena))
  (test-assert 'scratch-mark-tests-clear-right-arena
               (consent-scratch-arena-unused-slots-cleared? right-arena))))

(testing-registry-case
 'scratch-arena-growth-policy '(portable runtime storage arena error)
(let* ((lazy (consent-make-scratch-arena 4 8 'allow-growth))
       (owner (consent-scratch-arena-acquire! lazy 'lazy-floor)))
  (test-equal 'scratch-allow-growth-defers-initial-backing
              0
              (consent-scratch-owner-capacity owner))
  (consent-scratch-owner-append! owner 'materialized)
  (test-equal 'scratch-first-allocation-honors-initial-floor
              4
              (consent-scratch-owner-capacity owner))
  (consent-scratch-owner-release! owner))
(let* ((fixed (consent-make-scratch-arena 2 4 'pre-reserved))
       (fixed-owner
        (consent-scratch-arena-acquire! fixed 'collector-mark)))
  (consent-scratch-owner-append! fixed-owner 'left)
  (consent-scratch-owner-append! fixed-owner 'right)
  (test-assert 'pre-reserved-active-growth-fails-closed
               (raises?
                (lambda ()
                  (consent-scratch-owner-append! fixed-owner 'overflow))))
  (test-equal 'pre-reserved-exhaustion-preserves-prefix
              '(left right)
              (list
               (consent-scratch-owner-ref fixed-owner 0)
               (consent-scratch-owner-ref fixed-owner 1)))
  (test-equal 'pre-reserved-exhaustion-preserves-stats
              '(2 2 2 0 0)
              (let ((stats (consent-scratch-arena-stats fixed)))
                (list
                 (stats-ref stats 'length)
                 (stats-ref stats 'capacity)
                 (stats-ref stats 'high-water)
                 (stats-ref stats 'storage-growths)
                 (stats-ref stats 'storage-copied-elements))))
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
  (test-equal 'allow-growth-exhaustion-preserves-stats
              '(8 8 8 4 7)
              (let ((stats (consent-scratch-arena-stats growing)))
                (list
                 (stats-ref stats 'length)
                 (stats-ref stats 'capacity)
                 (stats-ref stats 'high-water)
                 (stats-ref stats 'storage-growths)
                 (stats-ref stats 'storage-copied-elements))))
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

(testing-runner-main "Consent scratch arena" (command-line))
