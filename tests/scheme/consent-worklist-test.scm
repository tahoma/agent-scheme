;;; Portable bootstrap-safe FIFO and deque worklist tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent worklist)
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
  "Return NAME's value from private worklist STATS."
  (let ((field (assq name (cdr stats))))
    (if field (cadr field) #f)))

(define (push-integers! worklist count)
  "Push ascending integers below COUNT onto WORKLIST's back."
  (let loop ((index 0))
    (if (< index count)
        (begin
          (consent-worklist-push-back! worklist index)
          (loop (+ index 1))))))

(define (list-last values)
  "Return the final value in nonempty VALUES."
  (if (null? (cdr values))
      (car values)
      (list-last (cdr values))))

(define (list-without-last values)
  "Return nonempty VALUES without its final pair."
  (reverse (cdr (reverse values))))

(define (model-value step)
  "Return a deterministic retained value for model STEP."
  (if (= (modulo step 11) 0)
      #f
      (list 'value step)))

(define (run-worklist-model! specification steps)
  "Compare a worklist with a list oracle for STEPS operations."
  (let* ((initial-capacity (car specification))
         (maximum-capacity (cadr specification))
         (growth-policy (car (cddr specification)))
         (worklist
          (consent-make-worklist
           initial-capacity maximum-capacity growth-policy)))
    (let loop ((step 0) (model '()))
      (if (< step steps)
          (let* ((size (length model))
                 (choice (modulo (+ step initial-capacity) 8))
                 (value (model-value step))
                 (next
                  (cond
                   ((= size 0)
                    (consent-worklist-push-back! worklist value)
                    (list value))
                   ((= size maximum-capacity)
                    (if (= (modulo step 2) 0)
                        (begin
                          (test-equal 'worklist-model-pop-front
                                      (car model)
                                      (consent-worklist-pop-front! worklist))
                          (cdr model))
                        (begin
                          (test-equal 'worklist-model-pop-back
                                      (list-last model)
                                      (consent-worklist-pop-back! worklist))
                          (list-without-last model))))
                   ((or (= choice 0) (= choice 1) (= choice 6))
                    (consent-worklist-push-front! worklist value)
                    (cons value model))
                   ((or (= choice 2) (= choice 3) (= choice 4))
                    (consent-worklist-push-back! worklist value)
                    (append model (list value)))
                   ((= choice 5)
                    (test-equal 'worklist-model-pop-front
                                (car model)
                                (consent-worklist-pop-front! worklist))
                    (cdr model))
                   (else
                    (test-equal 'worklist-model-pop-back
                                (list-last model)
                                (consent-worklist-pop-back! worklist))
                    (list-without-last model)))))
            (test-equal 'worklist-model-snapshot
                        (list specification step next)
                        (list
                         specification
                         step
                         (vector->list
                          (consent-worklist-snapshot worklist))))
            (test-equal 'worklist-model-size
                        (list specification step (length next))
                        (list
                         specification
                         step
                         (consent-worklist-size worklist)))
            (test-equal 'worklist-model-empty
                        (null? next)
                        (consent-worklist-empty? worklist))
            (if (not (null? next))
                (begin
                  (test-equal 'worklist-model-front
                              (car next)
                              (consent-worklist-front worklist))
                  (test-equal 'worklist-model-back
                              (list-last next)
                              (consent-worklist-back worklist))))
            (test-equal 'worklist-model-work-units
                        (+ step 1)
                        (consent-worklist-work-units worklist))
            (test-assert 'worklist-model-clears-inactive-slots
                         (consent-worklist-unused-slots-cleared? worklist))
            (loop (+ step 1) next))
          (let ((stats (consent-worklist-stats worklist)))
            (test-assert 'worklist-model-used-both-push-ends
                         (and (> (stats-ref stats 'push-fronts) 0)
                              (> (stats-ref stats 'push-backs) 0)))
            (test-assert 'worklist-model-used-both-pop-ends
                         (and (> (stats-ref stats 'pop-fronts) 0)
                              (> (stats-ref stats 'pop-backs) 0)))
            (test-equal 'worklist-model-directional-work-total
                        steps
                        (+ (stats-ref stats 'push-fronts)
                           (stats-ref stats 'push-backs)
                           (stats-ref stats 'pop-fronts)
                           (stats-ref stats 'pop-backs))))))))

(testing-registry-case
 'worklist-fifo-and-deque-contract '(portable runtime storage worklist)
(let ((worklist (consent-make-worklist 4 16 'allow-growth)))
  (test-assert 'worklist-predicate (consent-worklist? worklist))
  (test-assert 'worklist-active (consent-worklist-active? worklist))
  (test-assert 'worklist-initially-empty
               (consent-worklist-empty? worklist))
  (test-equal 'worklist-initial-size 0
              (consent-worklist-size worklist))
  (test-equal 'worklist-initial-capacity 4
              (consent-worklist-capacity worklist))
  (test-equal 'worklist-maximum-capacity 16
              (consent-worklist-maximum-capacity worklist))
  (test-equal 'worklist-growth-policy 'allow-growth
              (consent-worklist-growth-policy worklist))
  (test-assert 'worklist-push-back-returns-self
               (eq? worklist
                    (consent-worklist-push-back! worklist 'middle)))
  (test-assert 'worklist-push-front-returns-self
               (eq? worklist
                    (consent-worklist-push-front! worklist 'front)))
  (consent-worklist-push-back! worklist 'back)
  (test-equal 'worklist-front-peek 'front
              (consent-worklist-front worklist))
  (test-equal 'worklist-back-peek 'back
              (consent-worklist-back worklist))
  (test-equal 'worklist-deque-order '#(front middle back)
              (consent-worklist-snapshot worklist))
  (test-equal 'worklist-pop-front 'front
              (consent-worklist-pop-front! worklist))
  (test-equal 'worklist-pop-back 'back
              (consent-worklist-pop-back! worklist))
  (test-equal 'worklist-fifo-last-value 'middle
              (consent-worklist-pop-front! worklist))
  (test-assert 'worklist-empty-after-pops
               (consent-worklist-empty? worklist))
  (test-assert 'worklist-front-empty-rejected
               (raises? (lambda () (consent-worklist-front worklist))))
  (test-assert 'worklist-pop-empty-rejected
               (raises?
                (lambda ()
                  (consent-worklist-pop-front! worklist))))
  (test-equal 'worklist-successful-operation-units 6
              (consent-worklist-work-units worklist))
  (test-assert 'worklist-pops-clear-slots
               (consent-worklist-unused-slots-cleared? worklist))))

(testing-registry-case
 'worklist-wraparound-growth-and-linear-work
 '(portable runtime storage worklist performance)
(let ((worklist (consent-make-worklist 4 64 'allow-growth)))
  (push-integers! worklist 4)
  (test-equal 'worklist-wrap-pop-zero 0
              (consent-worklist-pop-front! worklist))
  (test-equal 'worklist-wrap-pop-one 1
              (consent-worklist-pop-front! worklist))
  (consent-worklist-push-back! worklist 4)
  (consent-worklist-push-back! worklist 5)
  (test-equal 'worklist-wrapped-order '#(2 3 4 5)
              (consent-worklist-snapshot worklist))
  (test-assert 'worklist-wrap-moves-front-index
               (> (stats-ref
                   (consent-worklist-stats worklist) 'front-index)
                  0))
  (consent-worklist-push-back! worklist 6)
  (test-equal 'worklist-growth-linearizes-order '#(2 3 4 5 6)
              (consent-worklist-snapshot worklist))
  (let fill ((value 7))
    (if (< value 40)
        (begin
          (consent-worklist-push-back! worklist value)
          (fill (+ value 1)))))
  (let drain ((expected 2))
    (if (< expected 40)
        (begin
          (test-equal 'worklist-fifo-drain
                      expected
                      (consent-worklist-pop-front! worklist))
          (drain (+ expected 1)))))
  (let ((stats (consent-worklist-stats worklist)))
    (test-equal 'worklist-linear-work-units 80
                (stats-ref stats 'work-units))
    (test-assert 'worklist-geometric-copy-bound
                 (< (stats-ref stats 'copied-elements) 80))
    (test-equal 'worklist-high-water 38
                (stats-ref stats 'high-water))
    (test-assert 'worklist-drain-clears-storage
                 (consent-worklist-unused-slots-cleared? worklist)))))

(testing-registry-case
 'worklist-bounded-reserve-and-failure-atomicity
 '(portable runtime storage worklist collector error)
(let ((worklist (consent-make-worklist 2 8 'pre-reserved)))
  (consent-worklist-reserve! worklist 4)
  (push-integers! worklist 4)
  (let ((before-values (consent-worklist-snapshot worklist))
        (before-stats (consent-worklist-stats worklist)))
    (test-assert 'worklist-pre-reserved-overflow-rejected
                 (raises?
                  (lambda ()
                    (consent-worklist-push-back! worklist 'overflow))))
    (test-equal 'worklist-overflow-preserves-values
                before-values
                (consent-worklist-snapshot worklist))
    (test-equal 'worklist-overflow-preserves-stats
                before-stats
                (consent-worklist-stats worklist)))
  (test-equal 'worklist-reserve-capacity 4
              (consent-worklist-capacity worklist))
  (test-assert 'worklist-reserve-over-maximum-rejected
               (raises?
                (lambda ()
                  (consent-worklist-reserve! worklist 9))))
  (test-equal 'worklist-reserve-preserves-order '#(0 1 2 3)
              (consent-worklist-snapshot worklist))))

(testing-registry-case
 'worklist-boundaries-stats-and-lifecycle
 '(portable runtime storage worklist model boundary error state)
(test-assert 'worklist-predicate-rejects-other-values
             (not (consent-worklist? 'not-storage)))
(test-assert 'worklist-active-rejects-other-values
             (not (consent-worklist-active? 'not-storage)))
(test-assert 'worklist-negative-initial-capacity-rejected
             (raises?
              (lambda ()
                (consent-make-worklist -1 8 'allow-growth))))
(test-assert 'worklist-inexact-maximum-capacity-rejected
             (raises?
              (lambda ()
                (consent-make-worklist 0 8.0 'allow-growth))))
(test-assert 'worklist-inverted-capacity-rejected
             (raises?
              (lambda ()
                (consent-make-worklist 9 8 'allow-growth))))
(test-assert 'worklist-invalid-growth-policy-rejected
             (raises?
              (lambda ()
                (consent-make-worklist 0 8 'sometimes))))
(let ((zero (consent-make-worklist 0 0 'allow-growth)))
  (test-equal
   'worklist-zero-capacity-initial-stats
   '(worklist-stats
     (growth-policy allow-growth)
     (active #t)
     (size 0)
     (capacity 0)
     (maximum-capacity 0)
     (high-water 0)
     (front-index 0)
     (push-fronts 0)
     (push-backs 0)
     (pop-fronts 0)
     (pop-backs 0)
     (pushes 0)
     (pops 0)
     (work-units 0)
     (capacity-changes 0)
     (automatic-growths 0)
     (copied-elements 0)
     (clears 0)
     (resets 0))
   (consent-worklist-stats zero))
  (let* ((before (consent-worklist-stats zero))
         (condition
          (raised-condition
           (lambda ()
             (consent-worklist-push-front! zero 'overflow)))))
    (test-assert
     'worklist-zero-capacity-push-has-stable-error
     (error-message=?
      condition
      "consent-worklist-push-front!: maximum capacity exceeded"))
    (test-equal 'worklist-zero-capacity-failure-is-atomic
                before
                (consent-worklist-stats zero))))
(let ((worklist (consent-make-worklist 3 6 'allow-growth)))
  (for-each
   (lambda (value)
     (consent-worklist-push-back! worklist value))
   '(a b c))
  (test-equal 'worklist-wrapped-reserve-pop 'a
              (consent-worklist-pop-front! worklist))
  (consent-worklist-push-back! worklist 'd)
  (let ((before (consent-worklist-stats worklist)))
    (test-assert 'worklist-reserve-no-op-returns-self
                 (eq? worklist
                      (consent-worklist-reserve! worklist 3)))
    (test-equal 'worklist-reserve-no-op-preserves-stats
                before
                (consent-worklist-stats worklist)))
  (consent-worklist-reserve! worklist 6)
  (test-equal 'worklist-wrapped-reserve-preserves-order
              '#(b c d)
              (consent-worklist-snapshot worklist))
  (test-equal 'worklist-wrapped-reserve-linearizes-front
              0
              (stats-ref (consent-worklist-stats worklist) 'front-index))
  (let ((snapshot (consent-worklist-snapshot worklist)))
    (vector-set! snapshot 0 'mutated)
    (test-equal 'worklist-snapshot-is-detached
                'b
                (consent-worklist-front worklist)))
  (consent-worklist-push-front! worklist 'front)
  (consent-worklist-push-back! worklist 'back)
  (consent-worklist-push-back! worklist 'last)
  (let ((before-values (consent-worklist-snapshot worklist))
        (before-stats (consent-worklist-stats worklist)))
    (test-assert 'worklist-maximum-overflow-rejected
                 (raises?
                  (lambda ()
                    (consent-worklist-push-front! worklist 'overflow))))
    (test-equal 'worklist-maximum-overflow-preserves-values
                before-values
                (consent-worklist-snapshot worklist))
    (test-equal 'worklist-maximum-overflow-preserves-stats
                before-stats
                (consent-worklist-stats worklist)))
  (consent-worklist-reset! worklist)
  (test-assert 'worklist-empty-back-rejected
               (raises? (lambda () (consent-worklist-back worklist))))
  (test-assert 'worklist-empty-pop-back-rejected
               (raises?
                (lambda ()
                  (consent-worklist-pop-back! worklist))))
  (test-assert 'worklist-reset-returns-self
               (eq? worklist (consent-worklist-reset! worklist)))
  (test-assert 'worklist-clear-returns-self
               (eq? worklist (consent-worklist-clear! worklist)))
  (test-equal 'worklist-clear-restores-initial-after-reserve
              3
              (consent-worklist-capacity worklist))
  (test-equal 'worklist-lifecycle-counts
              '(1 2)
              (let ((stats (consent-worklist-stats worklist)))
                (list
                 (stats-ref stats 'clears)
                 (stats-ref stats 'resets))))
  (test-assert 'worklist-release-returns-self
               (eq? worklist (consent-worklist-release! worklist)))
  (let ((released (consent-worklist-stats worklist)))
    (test-assert 'worklist-release-is-terminal
                 (not (consent-worklist-active? worklist)))
    (test-equal 'worklist-release-drops-capacity
                0
                (stats-ref released 'capacity))
    (test-assert 'worklist-release-clears-storage
                 (consent-worklist-unused-slots-cleared? worklist))
    (consent-worklist-release! worklist)
    (test-equal 'worklist-double-release-is-idempotent
                released
                (consent-worklist-stats worklist)))
  (test-assert 'worklist-released-query-rejected
               (raises?
                (lambda ()
                  (consent-worklist-size worklist))))))

(testing-registry-case
 'worklist-deterministic-model-sweep
 '(portable runtime storage worklist model performance state)
(for-each
 (lambda (specification)
   (run-worklist-model! specification 96))
 '((0 17 allow-growth)
   (1 17 allow-growth)
   (3 17 allow-growth)
   (5 5 pre-reserved))))

(testing-registry-case
 'worklist-clear-reset-release-and-reentry
 '(portable runtime storage worklist continuation error)
(let ((worklist (consent-make-worklist 2 8 'allow-growth))
      (condition #f)
      (reentry-condition #f)
      (continuation #f)
      (first-return? #t)
      (reentered? #f))
  (push-integers! worklist 5)
  (test-equal 'worklist-grown-capacity 8
              (consent-worklist-capacity worklist))
  (consent-worklist-reset! worklist)
  (test-equal 'worklist-reset-retains-capacity 8
              (consent-worklist-capacity worklist))
  (test-assert 'worklist-reset-clears-roots
               (consent-worklist-unused-slots-cleared? worklist))
  (push-integers! worklist 3)
  (consent-worklist-clear! worklist)
  (test-equal 'worklist-clear-restores-initial-capacity 2
              (consent-worklist-capacity worklist))
  (guard (caught
          (else (set! condition caught)))
    (dynamic-wind
     (lambda ()
       (if (not (consent-worklist-active? worklist))
           (error "worklist is not active")))
     (lambda ()
       (consent-worklist-push-back! worklist (vector 'temporary))
       (error "forced worklist unwind"))
     (lambda ()
       (consent-worklist-release! worklist))))
  (test-assert 'worklist-exception-observed condition)
  (test-assert 'worklist-exception-releases-lifetime
               (not (consent-worklist-active? worklist)))
  (test-assert 'worklist-release-clears-roots
               (consent-worklist-unused-slots-cleared? worklist))
  (let ((saved-runner (test-runner-current))
        (reentry-worklist
         (consent-make-worklist 1 1 'pre-reserved)))
    (set!
     reentry-condition
     (call/cc
      (lambda (finish)
        (guard
         (caught (else (finish caught)))
         (let ((value
                (dynamic-wind
                 (lambda ()
                   (if (not (consent-worklist-active? reentry-worklist))
                       (set! reentered? #t)))
                 (lambda ()
                   (if reentered?
                       (error
                        "worklist continuation cannot be re-entered")
                       (begin
                         (consent-worklist-push-back!
                          reentry-worklist 'temporary)
                         (call/cc
                          (lambda (return)
                            (set! continuation return)
                            'initial-return)))))
                 (lambda ()
                   (consent-worklist-release! reentry-worklist)))))
           (if first-return?
               (begin
                 (set! first-return? #f)
                 (continuation 'reentered))
               (finish value)))))))
    (test-runner-current saved-runner)
    (test-assert 'worklist-continuation-reentry-fails-closed
                 reentry-condition)
    (test-assert 'worklist-reentry-keeps-storage-cleared
                 (consent-worklist-unused-slots-cleared?
                  reentry-worklist)))
  (test-assert 'worklist-released-operation-rejected
               (raises?
                (lambda ()
                  (consent-worklist-push-back! worklist 'stale))))))

(testing-registry-case
 'worklist-explicit-suspend-and-resume-state
 '(portable runtime storage worklist collector)
(let* ((worklist (consent-make-worklist 4 4 'pre-reserved))
       (phase-state (list 'trace-phase worklist 0)))
  (consent-worklist-push-back! worklist 'root)
  (consent-worklist-push-back! worklist 'child)
  (test-equal 'worklist-suspended-front 'root
              (consent-worklist-pop-front! (cadr phase-state)))
  (set-car! (cddr phase-state) 1)
  (test-equal 'worklist-resumed-front 'child
              (consent-worklist-pop-front! (cadr phase-state)))
  (test-equal 'worklist-resumed-progress 1 (car (cddr phase-state)))
  (test-assert 'worklist-resumed-empty
               (consent-worklist-empty? worklist))))

(testing-runner-main "Consent worklist" (command-line))
