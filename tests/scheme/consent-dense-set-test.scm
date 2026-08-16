;;; Portable generation-stamped dense-set tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent dense-set)
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
  "Return NAME's value from private dense-set STATS."
  (let ((field (assq name (cdr stats))))
    (if field (cadr field) #f)))

(define (check-model dense model name)
  "Assert DENSE matches color-or-false MODEL under test NAME."
  (let loop ((identifier 0) (marked 0))
    (if (= identifier (vector-length model))
        (test-equal name marked (consent-dense-set-size dense))
        (let ((expected (vector-ref model identifier)))
          (test-equal name
                      (if (eqv? expected #f) #f #t)
                      (consent-dense-set-member? dense identifier))
          (test-equal name
                      expected
                      (consent-dense-set-color dense identifier))
          (loop (+ identifier 1)
                (if (eqv? expected #f) marked (+ marked 1)))))))

(define (run-model! initial maximum steps)
  "Compare one growing dense set with a fixed-vector model for STEPS."
  (let ((dense
         (consent-make-dense-set
          initial maximum 31 4 'allow-growth 'model))
        (model (make-vector maximum #f)))
    (let loop ((step 0))
      (if (< step steps)
          (let* ((identifier
                  (modulo (+ (* step 13) 7) maximum))
                 (choice (modulo step 9))
                 (color (modulo (+ step 1) 4)))
            (cond
             ((or (= choice 0) (= choice 4))
              (consent-dense-set-unmark! dense identifier)
              (vector-set! model identifier #f))
             ((= choice 8)
              (consent-dense-set-clear! dense)
              (vector-fill! model #f))
             (else
              (consent-dense-set-mark! dense identifier color)
              (vector-set! model identifier color)))
            (check-model dense model 'dense-set-model-step)
            (test-assert 'dense-set-model-integral-storage
                         (consent-dense-set-integral-storage? dense))
            (loop (+ step 1)))
          (begin
            (test-assert 'dense-set-model-used-sparse-high-id
                         (= (stats-ref
                             (consent-dense-set-stats dense)
                             'high-water)
                            maximum))
            (consent-dense-set-release! dense))))))

(testing-registry-case
 'dense-set-membership-colors-and-unmark
 '(portable runtime storage dense-set epoch color)
(let ((dense
       (consent-make-dense-set
        2 16 100 3 'allow-growth 'collector-color)))
  (test-assert 'dense-set-predicate (consent-dense-set? dense))
  (test-assert 'dense-set-active (consent-dense-set-active? dense))
  (test-assert 'dense-set-initially-empty
               (consent-dense-set-empty? dense))
  (test-equal 'dense-set-domain 'collector-color
              (consent-dense-set-domain dense))
  (test-equal 'dense-set-initial-size 0
              (consent-dense-set-size dense))
  (test-equal 'dense-set-lazy-initial-capacity 0
              (consent-dense-set-capacity dense))
  (test-equal 'dense-set-maximum-capacity 16
              (consent-dense-set-maximum-capacity dense))
  (test-equal 'dense-set-maximum-generation 100
              (consent-dense-set-maximum-generation dense))
  (test-equal 'dense-set-color-count 3
              (consent-dense-set-color-count dense))
  (test-equal 'dense-set-growth-policy 'allow-growth
              (consent-dense-set-growth-policy dense))
  (test-equal 'dense-set-initial-generation 1
              (consent-dense-set-generation dense))
  (test-equal 'dense-set-new-mark-return #f
              (consent-dense-set-mark! dense 1))
  (test-equal 'dense-set-first-allocation-honors-initial-floor
              2
              (consent-dense-set-capacity dense))
  (test-equal 'dense-set-default-color 0
              (consent-dense-set-color dense 1))
  (test-equal 'dense-set-duplicate-mark-return 0
              (consent-dense-set-mark! dense 1))
  (test-equal 'dense-set-recolor-return 0
              (consent-dense-set-mark! dense 1 2))
  (test-equal 'dense-set-updated-color 2
              (consent-dense-set-color dense 1))
  (test-equal 'dense-set-sparse-mark-return #f
              (consent-dense-set-mark! dense 9 1))
  (test-assert 'dense-set-sparse-member
               (consent-dense-set-member? dense 9))
  (test-equal 'dense-set-growth-addresses-sparse-id 10
              (consent-dense-set-capacity dense))
  (test-equal 'dense-set-distinct-size 2
              (consent-dense-set-size dense))
  (test-equal 'dense-set-unmark-return 2
              (consent-dense-set-unmark! dense 1))
  (test-assert 'dense-set-unmark-removes-membership
               (not (consent-dense-set-member? dense 1)))
  (test-equal 'dense-set-unmark-absent-return #f
              (consent-dense-set-unmark! dense 1))
  (test-equal 'dense-set-size-after-unmark 1
              (consent-dense-set-size dense))
  (let ((stats (consent-dense-set-stats dense)))
    (test-equal 'dense-set-mark-operation-count 4
                (stats-ref stats 'mark-operations))
    (test-equal 'dense-set-new-mark-count 2
                (stats-ref stats 'new-marks))
    (test-equal 'dense-set-duplicate-mark-count 1
                (stats-ref stats 'duplicate-marks))
    (test-equal 'dense-set-recolor-count 1
                (stats-ref stats 'recolors))
    (test-equal 'dense-set-unmark-count 1
                (stats-ref stats 'unmarks))
    (test-equal 'dense-set-high-water 10
                (stats-ref stats 'high-water)))
  (test-assert 'dense-set-storage-is-scalar
               (consent-dense-set-integral-storage? dense))))

(testing-registry-case
 'dense-set-logical-clear-and-forced-wrap
 '(portable runtime storage dense-set epoch performance wraparound)
(let ((ordinary
       (consent-make-dense-set
        64 64 1000 1 'pre-reserved 'query-generation)))
  (test-equal 'dense-set-pre-reserved-constructor-is-eager
              64
              (consent-dense-set-capacity ordinary))
  (consent-dense-set-mark! ordinary 63)
  (let clear ((count 0))
    (if (< count 100)
        (begin
          (consent-dense-set-clear! ordinary)
          (consent-dense-set-mark! ordinary (modulo count 64))
          (clear (+ count 1)))))
  (let ((stats (consent-dense-set-stats ordinary)))
    (test-equal 'dense-set-ordinary-clear-count 100
                (stats-ref stats 'clears))
    (test-equal 'dense-set-ordinary-generation-advances 100
                (stats-ref stats 'generation-advances))
    (test-equal 'dense-set-ordinary-physical-clears 0
                (stats-ref stats 'physical-clears))
    (test-equal 'dense-set-ordinary-physical-clear-slots 0
                (stats-ref stats 'physical-clear-slots)))
  (consent-dense-set-release! ordinary))
(let ((wrapping
       (consent-make-dense-set
        8 8 4 2 'pre-reserved 'collector-epoch)))
  (consent-dense-set-mark! wrapping 7 1)
  (consent-dense-set-clear! wrapping)
  (test-assert 'dense-set-first-clear-hides-stale-mark
               (not (consent-dense-set-member? wrapping 7)))
  (consent-dense-set-mark! wrapping 3 0)
  (consent-dense-set-clear! wrapping)
  (consent-dense-set-clear! wrapping)
  (test-equal 'dense-set-generation-at-ceiling 4
              (consent-dense-set-generation wrapping))
  (consent-dense-set-mark! wrapping 2 1)
  (consent-dense-set-clear! wrapping)
  (test-equal 'dense-set-wrap-restores-generation-one 1
              (consent-dense-set-generation wrapping))
  (test-assert 'dense-set-wrap-cannot-revive-old-mark
               (not (consent-dense-set-member? wrapping 7)))
  (let ((stats (consent-dense-set-stats wrapping)))
    (test-equal 'dense-set-wrap-clear-count 4
                (stats-ref stats 'clears))
    (test-equal 'dense-set-wrap-generation-advances 3
                (stats-ref stats 'generation-advances))
    (test-equal 'dense-set-wrap-physical-clears 1
                (stats-ref stats 'physical-clears))
    (test-equal 'dense-set-wrap-physical-clear-slots 8
                (stats-ref stats 'physical-clear-slots)))
  (consent-dense-set-mark! wrapping 5)
  (consent-dense-set-full-clear! wrapping)
  (test-assert 'dense-set-explicit-full-clear-is-empty
               (consent-dense-set-empty? wrapping))
  (let ((stats (consent-dense-set-stats wrapping)))
    (test-equal 'dense-set-explicit-full-clear-counts 2
                (stats-ref stats 'physical-clears))
    (test-equal 'dense-set-explicit-full-clear-slots 16
                (stats-ref stats 'physical-clear-slots)))))

(testing-registry-case
 'dense-set-reserve-bounds-and-failure-atomicity
 '(portable runtime storage dense-set collector boundary error)
(let ((dense
       (consent-make-dense-set
        4 9 7 2 'allow-growth 'lazy-reserve)))
  (consent-dense-set-reserve! dense 1)
  (test-equal 'dense-set-first-reserve-honors-initial-floor
              4
              (consent-dense-set-capacity dense)))
(let ((dense
       (consent-make-dense-set
        0 9 7 2 'pre-reserved 'remembered-set)))
  (test-assert 'dense-set-pre-reserved-mark-rejected
               (raises?
                (lambda () (consent-dense-set-mark! dense 0))))
  (test-assert 'dense-set-reserve-returns-self
               (eq? dense (consent-dense-set-reserve! dense 5)))
  (consent-dense-set-mark! dense 4 1)
  (let ((before (consent-dense-set-stats dense)))
    (test-assert 'dense-set-pre-reserved-overflow-rejected
                 (raises?
                  (lambda () (consent-dense-set-mark! dense 5))))
    (test-equal 'dense-set-overflow-preserves-stats
                before
                (consent-dense-set-stats dense))
    (test-equal 'dense-set-overflow-preserves-mark 1
                (consent-dense-set-color dense 4)))
  (let ((before (consent-dense-set-stats dense)))
    (test-assert 'dense-set-reserve-over-maximum-rejected
                 (raises?
                  (lambda () (consent-dense-set-reserve! dense 10))))
    (test-equal 'dense-set-reserve-failure-preserves-stats
                before
                (consent-dense-set-stats dense)))
  (let ((before (consent-dense-set-stats dense)))
    (test-assert 'dense-set-malformed-id-rejected
                 (raises?
                  (lambda () (consent-dense-set-member? dense -1))))
    (test-assert 'dense-set-inexact-id-rejected
                 (raises?
                  (lambda () (consent-dense-set-mark! dense 1.0))))
    (test-assert 'dense-set-object-id-rejected
                 (raises?
                  (lambda ()
                    (consent-dense-set-mark! dense (vector 'root)))))
    (test-assert 'dense-set-invalid-color-rejected
                 (raises?
                  (lambda () (consent-dense-set-mark! dense 1 2))))
    (test-assert 'dense-set-extra-color-rejected
                 (raises?
                  (lambda () (consent-dense-set-mark! dense 1 0 1))))
    (test-equal 'dense-set-malformed-input-preserves-stats
                before
                (consent-dense-set-stats dense)))
  (test-assert 'dense-set-malformed-input-cannot-retain-object
               (consent-dense-set-integral-storage? dense))))

(testing-registry-case
 'dense-set-independent-ownership-domains
 '(portable runtime storage dense-set collector ownership nested)
(let ((collector
       (consent-make-dense-set
        4 4 20 3 'pre-reserved 'collector-color))
      (query
       (consent-make-dense-set
        4 4 20 3 'pre-reserved 'query-generation))
      (writer
       (consent-make-dense-set
        4 4 20 3 'pre-reserved 'writer-metadata))
      (graph
       (consent-make-dense-set
        4 4 20 3 'pre-reserved 'graph-traversal))
      (collector-current? #t)
      (query-color #f)
      (writer-color #f)
      (graph-color #f))
  (consent-dense-set-mark! collector 2 0)
  (let ((nested-query query))
    (consent-dense-set-mark! nested-query 2 1)
    (let ((nested-writer writer)
          (nested-graph graph))
      (consent-dense-set-mark! nested-writer 2 2)
      (consent-dense-set-mark! nested-graph 2 0)
      (consent-dense-set-clear! collector)
      (set! collector-current?
            (consent-dense-set-member? collector 2))
      (set! query-color (consent-dense-set-color nested-query 2))
      (set! writer-color (consent-dense-set-color nested-writer 2))
      (set! graph-color (consent-dense-set-color nested-graph 2))))
  (consent-dense-set-release! graph)
  (consent-dense-set-release! writer)
  (consent-dense-set-release! query)
  (consent-dense-set-release! collector)
  (test-assert 'dense-set-collector-clear-is-independent
               (not collector-current?))
  (test-equal 'dense-set-query-domain-keeps-color 1 query-color)
  (test-equal 'dense-set-writer-domain-keeps-color 2 writer-color)
  (test-equal 'dense-set-graph-domain-keeps-color 0 graph-color)
  (test-assert 'dense-set-collector-release-is-terminal
               (not (consent-dense-set-active? collector)))
  (test-assert 'dense-set-query-release-is-terminal
               (not (consent-dense-set-active? query)))
  (test-assert 'dense-set-writer-release-is-terminal
               (not (consent-dense-set-active? writer)))
  (test-assert 'dense-set-graph-release-is-terminal
               (not (consent-dense-set-active? graph)))
  (test-assert 'dense-set-collector-release-clears-scalars
               (consent-dense-set-integral-storage? collector))
  (test-assert 'dense-set-query-release-clears-scalars
               (consent-dense-set-integral-storage? query))
  (test-assert 'dense-set-writer-release-clears-scalars
               (consent-dense-set-integral-storage? writer))
  (test-assert 'dense-set-graph-release-clears-scalars
               (consent-dense-set-integral-storage? graph))))

(testing-registry-case
 'dense-set-constructor-boundaries
 '(portable runtime storage dense-set boundary error)
(test-assert 'dense-set-predicate-rejects-other-values
             (not (consent-dense-set? 'not-storage)))
(test-assert 'dense-set-active-rejects-other-values
             (not (consent-dense-set-active? 'not-storage)))
(test-assert 'dense-set-negative-initial-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set
                 -1 4 5 1 'allow-growth 'test))))
(test-assert 'dense-set-inexact-maximum-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set
                 0 4.0 5 1 'allow-growth 'test))))
(test-assert 'dense-set-inverted-capacity-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set
                 5 4 5 1 'allow-growth 'test))))
(test-assert 'dense-set-zero-generation-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set
                 0 4 0 1 'allow-growth 'test))))
(test-assert 'dense-set-zero-color-count-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set
                 0 4 5 0 'allow-growth 'test))))
(test-assert 'dense-set-invalid-policy-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set 0 4 5 1 'sometimes 'test))))
(test-assert 'dense-set-invalid-domain-rejected
             (raises?
              (lambda ()
                (consent-make-dense-set
                 0 4 5 1 'allow-growth "test"))))
(let ((zero
       (consent-make-dense-set
        0 0 1 1 'allow-growth 'zero-capacity)))
  (let* ((before (consent-dense-set-stats zero))
         (condition
          (raised-condition
           (lambda () (consent-dense-set-mark! zero 0)))))
    (test-assert 'dense-set-zero-capacity-stable-error
                 (error-message=?
                  condition
                  (string-append
                   "consent-dense-set-mark!: identifier outside "
                   "configured range")))
    (test-equal 'dense-set-zero-capacity-failure-is-atomic
                before
                (consent-dense-set-stats zero)))))

(testing-registry-case
 'dense-set-deterministic-model-sweep
 '(portable runtime storage dense-set model performance state)
(run-model! 0 11 24)
(run-model! 1 11 24)
(run-model! 3 11 24)
(run-model! 11 11 24))

(testing-registry-case
 'dense-set-exception-release-and-continuation-reentry
 '(portable runtime storage dense-set continuation error)
(let ((dense
       (consent-make-dense-set
        4 4 8 2 'pre-reserved 'exception-phase))
      (condition #f))
  (guard (caught
          (else (set! condition caught)))
    (dynamic-wind
     (lambda ()
       (if (not (consent-dense-set-active? dense))
           (error "dense set is not active")))
     (lambda ()
       (consent-dense-set-mark! dense 3 1)
       (error "forced dense-set unwind"))
     (lambda ()
       (consent-dense-set-release! dense))))
  (test-assert 'dense-set-exception-observed condition)
  (test-assert 'dense-set-exception-releases-lifetime
               (not (consent-dense-set-active? dense)))
  (test-assert 'dense-set-released-operation-rejected
               (raises?
                (lambda () (consent-dense-set-mark! dense 0))))
  (let ((released (consent-dense-set-stats dense)))
    (test-equal 'dense-set-release-drops-capacity 0
                (stats-ref released 'capacity))
    (test-equal 'dense-set-release-clears-reserved-slots 4
                (stats-ref released 'release-clear-slots))
    (consent-dense-set-release! dense)
    (test-equal 'dense-set-double-release-is-idempotent
                released
                (consent-dense-set-stats dense))))
(let ((saved-runner (test-runner-current))
      (dense
       (consent-make-dense-set
        1 1 8 1 'pre-reserved 'continuation-phase))
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
                 (if (not (consent-dense-set-active? dense))
                     (set! reentered? #t)))
               (lambda ()
                 (if reentered?
                     (error "dense-set continuation cannot be re-entered")
                     (begin
                       (consent-dense-set-mark! dense 0)
                       (call/cc
                        (lambda (return)
                          (set! continuation return)
                          'initial-return)))))
               (lambda ()
                 (consent-dense-set-release! dense)))))
         (if first-return?
             (begin
               (set! first-return? #f)
               (continuation 'reentered))
             (finish value)))))))
  (test-runner-current saved-runner)
  (test-assert 'dense-set-continuation-reentry-fails-closed
               reentry-condition)
  (test-assert 'dense-set-reentry-keeps-scalar-storage
               (consent-dense-set-integral-storage? dense))))

(testing-runner-main "Consent dense set" (command-line))
