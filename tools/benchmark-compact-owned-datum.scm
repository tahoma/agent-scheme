;;; Benchmark compact owned compound representations by workload phase.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;; Run this program against both an issue-base worktree and the current tree.
;; CONSENT_COMPACT_DATUM_WORKLOAD selects one workload. Each process reports
;; setup separately from three operation samples so external `/usr/bin/time`
;; runs can add comparable peak-residency evidence.

(import (scheme base)
        (scheme process-context)
        (scheme time)
        (scheme write)
        (only (consent datum)
              consent-datum-car-trusted
              consent-datum-cdr-trusted
              consent-datum-cons
              consent-datum-export
              consent-datum-import
              consent-datum-list-copy
              consent-datum-make-bytevector
              consent-datum-make-string
              consent-datum-make-vector
              consent-datum-set-cdr!
              consent-make-datum-heap)
        (only (consent eval)
              consent-eval-source
              consent-make-base-environment)
        (only (consent reader) consent-read-datum))

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

(define benchmark-workload
  (environment-string "CONSENT_COMPACT_DATUM_WORKLOAD" "pair-construction"))

(define benchmark-size
  (environment-positive-integer "CONSENT_COMPACT_DATUM_SIZE" 32768))

(define (elapsed-jiffies thunk)
  "Call THUNK, retain its result, and return elapsed jiffies."
  (let ((started (current-jiffy)))
    (set! benchmark-sink (thunk))
    (- (current-jiffy) started)))

(define (measure-attempts thunk)
  "Return raw elapsed-jiffy samples for THUNK."
  (let loop ((remaining benchmark-attempts) (samples '()))
    (if (= remaining 0)
        (reverse samples)
        (loop (- remaining 1)
              (cons (elapsed-jiffies thunk) samples)))))

(define (make-owned-spine heap size)
  "Return a SIZE-pair owned list in HEAP."
  (let loop ((remaining size) (result '()))
    (if (= remaining 0)
        result
        (loop (- remaining 1)
              (consent-datum-cons heap remaining result)))))

(define (traverse-owned-spine root)
  "Return the numeric sum of owned pair cars in ROOT."
  (let loop ((cursor root) (sum 0))
    (if (null? cursor)
        sum
        (loop (consent-datum-cdr-trusted cursor)
              (+ sum (consent-datum-car-trusted cursor))))))

(define (make-reader-list-source size)
  "Return source text for a SIZE-element symbol list."
  (let ((port (open-output-string)))
    (write-char #\( port)
    (let loop ((remaining size))
      (if (> remaining 0)
          (begin
            (write-string "leaf " port)
            (loop (- remaining 1)))))
    (write-char #\) port)
    (get-output-string port)))

(define (make-owned-cycle heap size)
  "Return a SIZE-pair owned cycle in HEAP."
  (let ((root (consent-datum-cons heap 0 #f)))
    (let loop ((index 1) (head root))
      (if (= index size)
          (begin
            (consent-datum-set-cdr! heap root head)
            root)
          (loop (+ index 1)
                (consent-datum-cons heap index head))))))

(define (make-repeated-character-string length)
  "Return a host string containing LENGTH copies of `x`."
  (make-string length #\x))

(define (benchmark-pair-construction)
  "Return setup time and pair-spine allocation samples."
  (list
   0
   (measure-attempts
    (lambda ()
      (let ((heap (consent-make-datum-heap)))
        (vector heap (make-owned-spine heap benchmark-size)))))))

(define (benchmark-pair-traversal)
  "Return pair-spine setup time and trusted traversal samples."
  (let ((heap (consent-make-datum-heap))
        (root #f))
    (let ((setup
           (elapsed-jiffies
            (lambda ()
              (set! root (make-owned-spine heap benchmark-size))
              root))))
      (list setup
            (measure-attempts
             (lambda () (traverse-owned-spine root)))))))

(define (benchmark-list-copy)
  "Return list setup time and owned-copy samples."
  (let ((heap (consent-make-datum-heap))
        (root #f))
    (let ((setup
           (elapsed-jiffies
            (lambda ()
              (set! root (make-owned-spine heap benchmark-size))
              root))))
      (list setup
            (measure-attempts
             (lambda () (consent-datum-list-copy heap root)))))))

(define (benchmark-reader-list source-metadata?)
  "Return setup and reader samples with SOURCE-METADATA? enabled."
  (let ((source #f)
        (setup #f))
    (set! setup
          (elapsed-jiffies
           (lambda ()
             (set! source (make-reader-list-source benchmark-size))
             source)))
    (list
     setup
     (measure-attempts
      (lambda ()
        (consent-read-datum
         (consent-make-datum-heap)
         source
         (list (cons 'source-metadata source-metadata?))))))))

(define (benchmark-cyclic-boundary)
  "Return cyclic graph setup time and export/import samples."
  (let ((source #f)
        (setup #f))
    (set! setup
          (elapsed-jiffies
           (lambda ()
             (let ((heap (consent-make-datum-heap)))
               (set! source (make-owned-cycle heap benchmark-size))
               source))))
    (list
     setup
     (measure-attempts
      (lambda ()
        (let* ((host
                (consent-datum-export source (lambda (value) value)))
               (heap (consent-make-datum-heap)))
          (consent-datum-import heap host (lambda (value) value))))))))

(define (benchmark-deep-equality)
  "Return evaluator setup time and deep `equal?` samples."
  (let* ((environment (consent-make-base-environment))
         (options
          '((max-steps . 100000000)
            (max-host-callbacks . 100000000)
            (max-value-nodes . 100000000)))
         (setup-source
          (string-append
           "(define (benchmark-list remaining result)\n"
           "  (if (= remaining 0) result\n"
           "      (benchmark-list (- remaining 1)\n"
           "                      (cons remaining result))))\n"
           "(define benchmark-left\n"
           "  (benchmark-list " (number->string benchmark-size) " '()))\n"
           "(define benchmark-right\n"
           "  (benchmark-list " (number->string benchmark-size) " '()))\n"
           "#t")))
    (let ((setup
           (elapsed-jiffies
            (lambda ()
              (consent-eval-source setup-source environment options)))))
      (list
       setup
       (measure-attempts
        (lambda ()
          (let ((result
                 (consent-eval-source
                  "(equal? benchmark-left benchmark-right)"
                  environment
                  options)))
            (if result
                result
                (error "deep equality returned false")))))))))

(define (benchmark-nonpair kind)
  "Return setup time and compact KIND allocation samples."
  (let ((text (make-repeated-character-string 16)))
    (list
     0
     (measure-attempts
      (lambda ()
        (let ((heap (consent-make-datum-heap))
              (objects (make-vector benchmark-size #f)))
          (let loop ((index 0))
            (if (< index benchmark-size)
                (begin
                  (vector-set!
                   objects
                   index
                   (cond
                    ((eq? kind 'vector)
                     (consent-datum-make-vector heap 4 index))
                    ((eq? kind 'string)
                     (consent-datum-make-string heap 16 #\x))
                    (else
                     (consent-datum-make-bytevector heap 16 1))))
                  (loop (+ index 1)))))
          (vector heap text objects)))))))

(define benchmark-result
  (cond
   ((string=? benchmark-workload "pair-construction")
    (benchmark-pair-construction))
   ((string=? benchmark-workload "pair-traversal")
    (benchmark-pair-traversal))
   ((string=? benchmark-workload "deep-equality")
    (benchmark-deep-equality))
   ((string=? benchmark-workload "list-copy")
    (benchmark-list-copy))
   ((string=? benchmark-workload "reader-list")
    (benchmark-reader-list #t))
   ((string=? benchmark-workload "reader-list-no-source")
    (benchmark-reader-list #f))
   ((string=? benchmark-workload "cyclic-boundary")
    (benchmark-cyclic-boundary))
   ((string=? benchmark-workload "vector-allocation")
    (benchmark-nonpair 'vector))
   ((string=? benchmark-workload "string-allocation")
    (benchmark-nonpair 'string))
   ((string=? benchmark-workload "bytevector-allocation")
    (benchmark-nonpair 'bytevector))
   (else (error "unknown compact datum benchmark workload"
                benchmark-workload))))

(write
 (list 'consent-compact-owned-datum-benchmark
       '(schema 1)
       (list 'workload benchmark-workload)
       (list 'size benchmark-size)
       (list 'attempts benchmark-attempts)
       (list 'setup-jiffies (car benchmark-result))
       (list 'operation-jiffies (cadr benchmark-result))
       (list 'jiffies-per-second (jiffies-per-second))))
(newline)
