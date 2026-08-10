;;; Benchmark the host-datum graph conversion used by the portable heap.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;; Run this same program against two target roots through
;; tools/run-portable-tests.sh.  The emitted raw jiffy samples let reviewers
;; compare doubling ratios without treating elapsed time as a correctness
;; assertion.

(import (scheme base)
        (scheme time)
        (scheme write)
        (only (consent runtime)
              consent-host-datum->consent-datum))

(define benchmark-sizes '(1024 2048 4096))
(define benchmark-rounds 8)
(define benchmark-attempts 3)
(define benchmark-sink #f)

(define (make-symbol-list size)
  "Return a host list containing SIZE copies of the symbol `leaf`."
  (let loop ((remaining size) (result '()))
    (if (= remaining 0)
        result
        (loop (- remaining 1) (cons 'leaf result)))))

(define (elapsed-jiffies graph)
  "Return elapsed jiffies for repeated unchanged GRAPH conversions."
  (let ((started (current-jiffy)))
    (let loop ((remaining benchmark-rounds))
      (if (> remaining 0)
          (begin
            (set! benchmark-sink
                  (consent-host-datum->consent-datum graph))
            (if (not (eq? benchmark-sink graph))
                (error "unchanged graph was copied"))
            (loop (- remaining 1)))))
    (- (current-jiffy) started)))

(define (measure-attempts graph)
  "Return raw elapsed-jiffy samples for GRAPH."
  (let loop ((remaining benchmark-attempts) (result '()))
    (if (= remaining 0)
        (reverse result)
        (loop (- remaining 1)
              (cons (elapsed-jiffies graph) result)))))

(define (measure-size size)
  "Return SIZE and its raw graph-conversion samples."
  (let ((graph (make-symbol-list size)))
    ;; Warm the converter before collecting samples.
    (set! benchmark-sink
          (consent-host-datum->consent-datum graph))
    (list size (measure-attempts graph))))

(write
 (list 'consent-compound-datum-graph-benchmark
       '(schema 1)
       (list 'rounds benchmark-rounds)
       (list 'attempts benchmark-attempts)
       (list 'measurements (map measure-size benchmark-sizes))
       (list 'jiffies-per-second (jiffies-per-second))))
(newline)
