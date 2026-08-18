;;; Benchmark the portable standard hash-table engine.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; Run this program through tools/run-portable-tests.sh on the same host and
;;; target roots being compared.  Raw jiffy samples are evidence, not test
;;; assertions; hash-table conformance never depends on elapsed wall time.

(import (scheme base)
        (scheme time)
        (scheme write)
        (stdlib comparator)
        (except (stdlib hash-table) string-hash string-ci-hash))

(define benchmark-size 50000)
(define lookup-rounds 10)
(define traversal-rounds 10)
(define benchmark-attempts 3)
(define benchmark-sink 0)

(define integer-comparator
  (make-comparator integer? = < number-hash))

(define collision-comparator
  (make-comparator integer? = < (lambda (key) 0)))

(define (elapsed-jiffies thunk)
  "Run THUNK and return its elapsed jiffies."
  (let ((started (current-jiffy)))
    (thunk)
    (- (current-jiffy) started)))

(define (fill-table! table size)
  "Associate every integer below SIZE with itself in TABLE."
  (let loop ((index 0))
    (if (< index size)
        (begin
          (hash-table-set! table index index)
          (loop (+ index 1))))))

(define (measure-lookups table start rounds)
  "Measure ROUNDS complete lookup passes beginning at START."
  (elapsed-jiffies
   (lambda ()
     (let repeat ((remaining rounds) (total 0))
       (if (= remaining 0)
           (set! benchmark-sink total)
           (let lookup ((offset 0) (subtotal total))
             (if (= offset benchmark-size)
                 (repeat (- remaining 1) subtotal)
                 (lookup
                  (+ offset 1)
                  (+ subtotal
                     (hash-table-ref/default
                      table (+ start offset) 1))))))))))

(define (measure-attempt attempt)
  "Return one ordinary-workload measurement for ATTEMPT."
  (let ((table (make-hash-table integer-comparator))
        (reserved (make-hash-table integer-comparator benchmark-size)))
    (let ((insert-grow
           (elapsed-jiffies
            (lambda () (fill-table! table benchmark-size))))
          (insert-reserved
           (elapsed-jiffies
            (lambda () (fill-table! reserved benchmark-size)))))
      (let ((lookup-hit (measure-lookups table 0 lookup-rounds))
            (lookup-miss
             (measure-lookups table benchmark-size lookup-rounds))
            (traverse
             (elapsed-jiffies
              (lambda ()
                (let repeat ((remaining traversal-rounds) (total 0))
                  (if (= remaining 0)
                      (set! benchmark-sink total)
                      (begin
                        (hash-table-for-each
                         (lambda (key value)
                           (set! total (+ total value)))
                         table)
                        (repeat (- remaining 1) total))))))))
        (list
         'attempt attempt
         (list 'insert-grow insert-grow)
         (list 'insert-reserved insert-reserved)
         (list 'lookup-hit lookup-hit)
         (list 'lookup-miss lookup-miss)
         (list 'traverse traverse))))))

(define (measure-collision-size size)
  "Return insertion and lookup jiffies for SIZE colliding keys."
  (let ((table (make-hash-table collision-comparator)))
    (let ((insert
           (elapsed-jiffies (lambda () (fill-table! table size)))))
      (let ((lookup
             (elapsed-jiffies
              (lambda ()
                (let loop ((index 0) (total 0))
                  (if (= index size)
                      (set! benchmark-sink total)
                      (loop (+ index 1)
                            (+ total (hash-table-ref table index)))))))))
        (list size (list 'insert insert) (list 'lookup lookup))))))

(define (measure-attempts)
  "Return the configured ordinary-workload attempts."
  (let loop ((attempt 1) (result '()))
    (if (> attempt benchmark-attempts)
        (reverse result)
        (loop (+ attempt 1)
              (cons (measure-attempt attempt) result)))))

(write
 (list
  'stdlib-hash-table-benchmark
  '(schema 1)
  (list 'size benchmark-size)
  (list 'lookup-rounds lookup-rounds)
  (list 'traversal-rounds traversal-rounds)
  (list 'attempts (measure-attempts))
  (list 'collision-measurements
        (map measure-collision-size '(500 1000 2000)))
  (list 'jiffies-per-second (jiffies-per-second))
  (list 'sink benchmark-sink)))
(newline)
