;;; Portable bootstrap-safe growable-vector tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent growable-vector)
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

(define (append-integers! grow count)
  "Append integers below COUNT to GROW."
  (let loop ((index 0))
    (if (< index count)
        (begin
          (consent-growable-vector-append! grow index)
          (loop (+ index 1))))))

(define (integers-below count)
  "Return the ascending exact integers below COUNT."
  (let loop ((index 0) (result '()))
    (if (= index count)
        (reverse result)
        (loop (+ index 1) (cons index result)))))

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
 'growable-vector-zero-capacity-and-idempotence
 '(portable runtime storage boundary error)
(test-assert 'growable-vector-predicate-rejects-other-values
             (not (consent-growable-vector? 'not-storage)))
(test-assert 'growable-vector-active-rejects-other-values
             (not (consent-growable-vector-active? 'not-storage)))
(let ((grow (consent-make-growable-vector 0 0)))
  (test-equal
   'zero-capacity-initial-stats
   '(growable-vector-stats
     (length 0)
     (capacity 0)
     (maximum-capacity 0)
     (high-water 0)
     (growths 0)
     (copied-elements 0)
     (resets 0)
     (released #f))
   (consent-growable-vector-stats grow))
  (test-equal 'zero-capacity-empty-snapshot
              '#()
              (consent-growable-vector-snapshot grow))
  (let* ((before (consent-growable-vector-stats grow))
         (condition
          (raised-condition
           (lambda ()
             (consent-growable-vector-append! grow 'overflow)))))
    (test-assert
     'zero-capacity-append-has-stable-error
     (error-message=?
      condition
      "consent-growable-vector-grow!: maximum capacity exceeded"))
    (test-equal 'zero-capacity-failure-is-atomic
                before
                (consent-growable-vector-stats grow)))
  (test-assert 'growable-vector-release-returns-self
               (eq? grow (consent-growable-vector-release! grow)))
  (let ((released (consent-growable-vector-stats grow)))
    (test-equal
     'zero-capacity-released-stats
     '(growable-vector-stats
       (length 0)
       (capacity 0)
       (maximum-capacity 0)
       (high-water 0)
       (growths 0)
       (copied-elements 0)
       (resets 1)
       (released #t))
     released)
    (consent-growable-vector-release! grow)
    (test-equal 'growable-vector-double-release-is-idempotent
                released
                (consent-growable-vector-stats grow)))
  (test-assert 'growable-vector-released-query-is-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-length grow))))))

(testing-registry-case
 'growable-vector-transitions-and-failure-atomicity
 '(portable runtime storage boundary error state)
(let ((grow (consent-make-growable-vector 1 4)))
  (consent-growable-vector-append! grow 'a)
  (let ((before (consent-growable-vector-stats grow)))
    (test-assert 'growable-vector-reserve-no-op-returns-self
                 (eq? grow (consent-growable-vector-reserve! grow 1)))
    (test-assert 'growable-vector-grow-no-op-returns-self
                 (eq? grow (consent-growable-vector-grow! grow 0)))
    (test-equal 'growable-vector-no-ops-do-not-count-growth
                before
                (consent-growable-vector-stats grow)))
  (consent-growable-vector-reserve! grow 3)
  (test-equal 'growable-vector-reserve-preserves-prefix
              'a
              (consent-growable-vector-ref grow 0))
  (test-equal 'growable-vector-reserve-counts-copied-prefix
              '(1 1)
              (list
               (stats-ref (consent-growable-vector-stats grow) 'growths)
               (stats-ref
                (consent-growable-vector-stats grow) 'copied-elements)))
  (consent-growable-vector-append! grow 'b)
  (consent-growable-vector-append! grow 'c)
  (consent-growable-vector-append! grow 'd)
  (test-equal 'growable-vector-set-returns-value
              'changed
              (consent-growable-vector-set! grow 2 'changed))
  (test-equal 'growable-vector-growth-preserves-prefix
              '#(a b changed d)
              (consent-growable-vector-snapshot grow))
  (let ((before-stats (consent-growable-vector-stats grow))
        (before-values (consent-growable-vector-snapshot grow)))
    (test-assert 'growable-vector-full-append-rejected
                 (raises?
                  (lambda ()
                    (consent-growable-vector-append! grow 'overflow))))
    (test-assert 'growable-vector-grow-over-maximum-rejected
                 (raises?
                  (lambda ()
                    (consent-growable-vector-grow! grow 5))))
    (test-assert 'growable-vector-reserve-over-maximum-rejected
                 (raises?
                  (lambda ()
                    (consent-growable-vector-reserve! grow 5))))
    (test-assert 'growable-vector-inexact-reserve-rejected
                 (raises?
                  (lambda ()
                    (consent-growable-vector-reserve! grow 3.0))))
    (test-equal 'growable-vector-capacity-failures-preserve-values
                before-values
                (consent-growable-vector-snapshot grow))
    (test-equal 'growable-vector-capacity-failures-preserve-stats
                before-stats
                (consent-growable-vector-stats grow)))
  (consent-growable-vector-reset! grow)
  (test-equal
   'growable-vector-reset-preserves-history
   '(growable-vector-stats
     (length 0)
     (capacity 4)
     (maximum-capacity 4)
     (high-water 4)
     (growths 2)
     (copied-elements 4)
     (resets 1)
     (released #f))
   (consent-growable-vector-stats grow))
  (consent-growable-vector-reset! grow)
  (test-equal 'growable-vector-empty-reset-counts-operation
              2
              (stats-ref (consent-growable-vector-stats grow) 'resets))
  (test-equal 'growable-vector-reuse-starts-at-zero
              0
              (consent-growable-vector-append! grow 'reused))
  (test-assert 'growable-vector-reuse-keeps-unused-slots-cleared
               (consent-growable-vector-unused-slots-cleared? grow))))

(testing-registry-case
 'growable-vector-deterministic-model-sweep
 '(portable runtime storage model boundary state)
(for-each
 (lambda (specification)
   (let* ((initial-capacity (car specification))
          (maximum-capacity (cadr specification))
          (grow
           (consent-make-growable-vector
            initial-capacity maximum-capacity))
          (expected (integers-below maximum-capacity)))
     (append-integers! grow maximum-capacity)
     (test-equal 'growable-model-full-prefix
                 (list specification expected)
                 (list
                  specification
                  (vector->list
                   (consent-growable-vector-snapshot grow))))
     (test-equal 'growable-model-full-length
                 (list specification maximum-capacity)
                 (list
                  specification
                  (consent-growable-vector-length grow)))
     (test-equal 'growable-model-full-capacity
                 (list specification maximum-capacity)
                 (list
                  specification
                  (consent-growable-vector-capacity grow)))
     (let ((before (consent-growable-vector-stats grow)))
       (test-assert 'growable-model-overflow-rejected
                    (raises?
                     (lambda ()
                       (consent-growable-vector-append!
                        grow 'overflow))))
       (test-equal 'growable-model-overflow-is-atomic
                   (list specification before)
                   (list
                    specification
                    (consent-growable-vector-stats grow))))
     (test-equal 'growable-model-set-returns-value
                 'changed
                 (consent-growable-vector-set! grow 0 'changed))
     (test-equal 'growable-model-set-persists-value
                 'changed
                 (consent-growable-vector-ref grow 0))
     (consent-growable-vector-reset! grow)
     (test-assert 'growable-model-reset-clears-storage
                  (consent-growable-vector-unused-slots-cleared? grow))
     (test-equal 'growable-model-reuse-index
                 0
                 (consent-growable-vector-append! grow 'reused))
     (test-equal 'growable-model-reuse-value
                 'reused
                 (consent-growable-vector-ref grow 0))
     (consent-growable-vector-release! grow)
     (test-assert 'growable-model-release-is-terminal
                  (not (consent-growable-vector-active? grow)))))
 '((0 1) (0 3) (1 5) (2 7) (4 4))))

(testing-registry-case
 'growable-vector-bulk-copy-and-fill
 '(portable runtime storage copy overlap boundary state)
(let ((source (consent-make-growable-vector 4 4))
      (destination (consent-make-growable-vector 1 4)))
  (for-each
   (lambda (value)
     (consent-growable-vector-append! source value))
   '(a b c d))
  (consent-growable-vector-append! destination 'seed)
  (test-assert
   'growable-vector-copy-returns-destination
   (eq? destination
        (consent-growable-vector-copy! destination 1 source 1 4)))
  (test-equal 'growable-vector-copy-extends-prefix
              '#(seed b c d)
              (consent-growable-vector-snapshot destination))
  (test-equal 'growable-vector-copy-updates-high-water
              4
              (stats-ref
               (consent-growable-vector-stats destination) 'high-water))
  (test-assert
   'growable-vector-fill-returns-self
   (eq? destination
        (consent-growable-vector-fill! destination 'filled 1 3)))
  (test-equal 'growable-vector-fill-populated-slice
              '#(seed filled filled d)
              (consent-growable-vector-snapshot destination))
  (consent-growable-vector-copy! destination 1 destination 0 3)
  (test-equal 'growable-vector-copy-overlap-right
              '#(seed seed filled filled)
              (consent-growable-vector-snapshot destination))
  (consent-growable-vector-copy! destination 0 destination 1 4)
  (test-equal 'growable-vector-copy-overlap-left
              '#(seed filled filled filled)
              (consent-growable-vector-snapshot destination))
  (let ((before-stats (consent-growable-vector-stats destination))
        (before-values (consent-growable-vector-snapshot destination)))
    (test-assert
     'growable-vector-copy-over-maximum-rejected
     (raises?
      (lambda ()
        (consent-growable-vector-copy! destination 3 source 0 2))))
    (test-assert
     'growable-vector-copy-invalid-boundary-rejected
     (raises?
      (lambda ()
        (consent-growable-vector-copy! destination 5 source 0 0))))
    (test-assert
     'growable-vector-fill-invalid-slice-rejected
     (raises?
      (lambda ()
        (consent-growable-vector-fill! destination 'bad 2 5))))
    (test-equal 'growable-vector-bulk-failures-preserve-values
                before-values
                (consent-growable-vector-snapshot destination))
    (test-equal 'growable-vector-bulk-failures-preserve-stats
                before-stats
                (consent-growable-vector-stats destination)))))

(testing-registry-case
 'growable-vector-reset-release-and-errors
 '(portable runtime storage error)
(let ((grow (consent-make-growable-vector 8 8)))
  (consent-growable-vector-append! grow (vector 'owned-reference))
  (consent-growable-vector-append! grow (cons 'owned 'reference))
  (consent-growable-vector-append! grow (vector 'discarded-reference))
  (test-assert 'growable-vector-negative-index-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-ref grow -1))))
  (test-assert 'growable-vector-unpopulated-index-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-set! grow 3 'outside))))
  (test-assert 'growable-vector-maximum-rejected
               (raises?
                (lambda ()
                  (consent-growable-vector-reserve! grow 9))))
  (consent-growable-vector-truncate! grow 1)
  (test-equal 'growable-vector-truncate-length
              1
              (consent-growable-vector-length grow))
  (test-assert 'growable-vector-truncate-preserves-prefix
               (vector?
                (consent-growable-vector-ref grow 0)))
  (test-assert 'growable-vector-truncate-clears-suffix
               (consent-growable-vector-unused-slots-cleared? grow))
  (let ((before (consent-growable-vector-stats grow)))
    (test-assert 'growable-vector-invalid-truncate-rejected
                 (raises?
                  (lambda ()
                    (consent-growable-vector-truncate! grow 2))))
    (test-equal 'growable-vector-invalid-truncate-is-atomic
                before
                (consent-growable-vector-stats grow)))
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


(testing-runner-main "Consent growable vector" (command-line))
