;;; Benchmark compact private storage by representation shape and phase.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;; Run this program against an issue-base worktree and the current tree.
;; Environment variables select a kind, shape, phase, and iteration count.
;; Three raw samples support median comparison; external `/usr/bin/time -l`
;; adds fresh-process peak-residency evidence.

(import (scheme base)
        (scheme process-context)
        (scheme time)
        (scheme write)
        (consent dense-set)
        (consent growable-vector)
        (consent scratch-arena)
        (consent worklist)
        (stdlib flexvectors))

(define benchmark-attempts 3)
(define benchmark-sink #f)

(define (environment-string name default)
  "Return NAME's nonempty environment string, or DEFAULT."
  (let ((value (get-environment-variable name)))
    (if (and value (> (string-length value) 0)) value default)))

(define (environment-positive-integer name default)
  "Return NAME's positive exact integer, or DEFAULT when absent."
  (let* ((text (get-environment-variable name))
         (value (and text (string->number text))))
    (if (not text)
        default
        (if (and value (integer? value) (exact? value) (> value 0))
            value
            (error "expected positive benchmark integer" name text)))))

(define benchmark-kind
  (environment-string "CONSENT_PRIVATE_STORAGE_KIND" "worklist"))

(define benchmark-shape
  (environment-string "CONSENT_PRIVATE_STORAGE_SHAPE" "empty"))

(define benchmark-phase
  (environment-string "CONSENT_PRIVATE_STORAGE_PHASE" "construction"))

(define benchmark-iterations
  (environment-positive-integer
   "CONSENT_PRIVATE_STORAGE_ITERATIONS" 20000))

(define (shape-size)
  "Return the logical element count selected by BENCHMARK-SHAPE."
  (cond
   ((string=? benchmark-shape "empty") 0)
   ((string=? benchmark-shape "one") 1)
   ((string=? benchmark-shape "small") 8)
   ((string=? benchmark-shape "high-water") 64)
   (else (error "unknown private-storage benchmark shape"
                benchmark-shape))))

(define (pre-reserved-phase?)
  "Return whether BENCHMARK-PHASE needs eager fixed backing."
  (string=? benchmark-phase "steady"))

(define (make-state)
  "Return one fresh selected storage state."
  (let ((policy
         (if (pre-reserved-phase?) 'pre-reserved 'allow-growth)))
    (cond
     ((string=? benchmark-kind "growable")
      (consent-make-growable-vector
       (if (pre-reserved-phase?) 64 8) 64))
     ((string=? benchmark-kind "scratch")
      (let* ((arena
              (consent-make-scratch-arena 8 64 policy))
             (owner
              (consent-scratch-arena-acquire! arena 'benchmark)))
        (vector arena owner (consent-scratch-owner-mark owner))))
     ((string=? benchmark-kind "worklist")
      (consent-make-worklist 8 64 policy))
     ((string=? benchmark-kind "dense-set")
      (consent-make-dense-set
       8 64 1000000 3 policy 'benchmark))
     ((string=? benchmark-kind "flexvector")
      (flexvector))
     (else (error "unknown private-storage benchmark kind"
                  benchmark-kind)))))

(define (state-add! state value)
  "Add VALUE to selected STATE."
  (cond
   ((string=? benchmark-kind "growable")
    (consent-growable-vector-append! state value))
   ((string=? benchmark-kind "scratch")
    (consent-scratch-owner-append! (vector-ref state 1) value))
   ((string=? benchmark-kind "worklist")
    (consent-worklist-push-back! state value))
   ((string=? benchmark-kind "dense-set")
    (consent-dense-set-mark! state value (remainder value 3)))
   (else (flexvector-add-back! state value))))

(define (populate-state! state)
  "Populate STATE to the selected logical shape and return it."
  (let ((size (shape-size)))
    (let loop ((index 0))
      (if (< index size)
          (begin
            (state-add! state index)
            (loop (+ index 1)))))
    state))

(define (make-populated-state)
  "Return one selected state populated to BENCHMARK-SHAPE."
  (populate-state! (make-state)))

(define (make-state-vector)
  "Return BENCHMARK-ITERATIONS independent populated states."
  (let ((states (make-vector benchmark-iterations #f)))
    (let loop ((index 0))
      (if (< index benchmark-iterations)
          (begin
            (vector-set! states index (make-populated-state))
            (loop (+ index 1)))))
    states))

(define (elapsed-jiffies thunk)
  "Call THUNK, retain its result, and return elapsed jiffies."
  (let ((started (current-jiffy)))
    (set! benchmark-sink (thunk))
    (- (current-jiffy) started)))

(define (for-each-state states operation)
  "Apply OPERATION to every member of STATES and return STATES."
  (let loop ((index 0))
    (if (< index (vector-length states))
        (begin
          (operation (vector-ref states index))
          (loop (+ index 1)))))
  states)

(define (state-clear! state)
  "Apply the selected abstraction's ordinary clear operation."
  (cond
   ((string=? benchmark-kind "growable")
    (consent-growable-vector-clear! state))
   ((string=? benchmark-kind "scratch")
    (consent-scratch-owner-release! (vector-ref state 1)))
   ((string=? benchmark-kind "worklist")
    (consent-worklist-clear! state))
   ((string=? benchmark-kind "dense-set")
    (consent-dense-set-clear! state))
   (else (flexvector-clear! state))))

(define (state-reset! state)
  "Apply the selected abstraction's reusable reset analogue."
  (cond
   ((string=? benchmark-kind "growable")
    (consent-growable-vector-reset! state))
   ((string=? benchmark-kind "scratch")
    (consent-scratch-owner-reset!
     (vector-ref state 1) (vector-ref state 2)))
   ((string=? benchmark-kind "worklist")
    (consent-worklist-reset! state))
   ((string=? benchmark-kind "dense-set")
    (consent-dense-set-full-clear! state))
   (else (flexvector-clear! state))))

(define (state-release! state)
  "Apply the selected abstraction's terminal release analogue."
  (cond
   ((string=? benchmark-kind "growable")
    (consent-growable-vector-release! state))
   ((string=? benchmark-kind "scratch")
    (consent-scratch-owner-release! (vector-ref state 1)))
   ((string=? benchmark-kind "worklist")
    (consent-worklist-release! state))
   ((string=? benchmark-kind "dense-set")
    (consent-dense-set-release! state))
   (else (flexvector-clear! state))))

(define (measure-construction)
  "Return raw construction samples retaining every selected state."
  (let loop ((remaining benchmark-attempts) (samples '()))
    (if (= remaining 0)
        (reverse samples)
        (loop (- remaining 1)
              (cons (elapsed-jiffies make-state-vector) samples)))))

(define (measure-lifecycle operation)
  "Return raw samples applying OPERATION to prebuilt state vectors."
  (let loop ((remaining benchmark-attempts) (samples '()))
    (if (= remaining 0)
        (reverse samples)
        (let ((states (make-state-vector)))
          (loop
           (- remaining 1)
           (cons
            (elapsed-jiffies
             (lambda () (for-each-state states operation)))
            samples))))))

(define (steady-step! state value)
  "Perform one balanced steady-state step on STATE using VALUE."
  (cond
   ((string=? benchmark-kind "growable")
    (consent-growable-vector-append! state value)
    (consent-growable-vector-reset! state))
   ((string=? benchmark-kind "scratch")
    (let ((owner (vector-ref state 1)))
      (consent-scratch-owner-append! owner value)
      (consent-scratch-owner-reset! owner (vector-ref state 2))))
   ((string=? benchmark-kind "worklist")
    (consent-worklist-push-back! state value)
    (consent-worklist-pop-front! state))
   ((string=? benchmark-kind "dense-set")
    (consent-dense-set-mark! state 7 1)
    (consent-dense-set-unmark! state 7))
   (else
    (flexvector-add-back! state value)
    (flexvector-remove-back! state))))

(define (measure-steady)
  "Return raw balanced steady-state samples."
  (let loop ((remaining benchmark-attempts) (samples '()))
    (if (= remaining 0)
        (reverse samples)
        (let ((state (make-state)))
          (loop
           (- remaining 1)
           (cons
            (elapsed-jiffies
             (lambda ()
               (let run ((index 0))
                 (if (< index benchmark-iterations)
                     (begin
                       (steady-step! state index)
                       (run (+ index 1)))))
               state))
            samples))))))

(define benchmark-operation
  (cond
   ((string=? benchmark-phase "construction") 'construction)
   ((string=? benchmark-phase "steady") 'steady)
   ((string=? benchmark-phase "clear") 'clear)
   ((string=? benchmark-phase "reset")
    (cond
     ((string=? benchmark-kind "dense-set") 'full-clear)
     ((string=? benchmark-kind "flexvector") 'clear)
     (else 'reset)))
   ((string=? benchmark-phase "release")
    (if (string=? benchmark-kind "flexvector") 'clear 'release))
   (else (error "unknown private-storage benchmark phase"
                benchmark-phase))))

(define benchmark-samples
  (cond
   ((eq? benchmark-operation 'construction) (measure-construction))
   ((eq? benchmark-operation 'steady) (measure-steady))
   ((eq? benchmark-operation 'clear)
    (measure-lifecycle state-clear!))
   ((or (eq? benchmark-operation 'reset)
        (eq? benchmark-operation 'full-clear))
    (measure-lifecycle state-reset!))
   (else (measure-lifecycle state-release!))))

(write
 (list 'consent-private-storage-benchmark
       '(schema 1)
       (list 'kind benchmark-kind)
       (list 'shape benchmark-shape)
       (list 'phase benchmark-phase)
       (list 'operation benchmark-operation)
       (list 'iterations benchmark-iterations)
       (list 'attempts benchmark-attempts)
       (list 'jiffies benchmark-samples)
       (list 'jiffies-per-second (jiffies-per-second))))
(newline)
