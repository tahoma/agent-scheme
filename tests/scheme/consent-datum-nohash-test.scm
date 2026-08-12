;;; Forced-no-hash datum graph compatibility envelope tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (consent datum)
        (consent identity-map)
        (only (consent runtime)
              consent-host-datum->consent-datum
              value-node-count))

(define (check condition message . irritants)
  "Raise MESSAGE with IRRITANTS unless CONDITION is true."
  (if (not condition) (apply error message irritants)))

(define (host-graph compound-count)
  "Return a vector graph with exactly COMPOUND-COUNT distinct compounds."
  (let ((root (make-vector (- compound-count 1) #f)))
    (let loop ((index 0))
      (if (= index (vector-length root))
          root
          (begin
            (vector-set! root index (cons index '()))
            (loop (+ index 1)))))))

(define (owned-graph heap compound-count)
  "Return an owned vector graph with COMPOUND-COUNT distinct compounds."
  (let ((root
         (consent-datum-make-vector
          heap (- compound-count 1) #f)))
    (let loop ((index 0))
      (if (= index (consent-datum-vector-length root))
          root
          (begin
            (consent-datum-vector-set!
             heap root index (consent-datum-cons heap index '()))
            (loop (+ index 1)))))))

(define (hybrid-export-root heap host-count)
  "Return one owned vector containing HOST-COUNT distinct host pairs."
  (let ((root (consent-datum-make-vector heap host-count #f)))
    (let loop ((index 0))
      (if (= index host-count)
          root
          (begin
            (consent-datum-vector-set! heap root index (cons index '()))
            (loop (+ index 1)))))))

(define (rejection-message thunk)
  "Return THUNK's error message, or #f when it does not raise."
  (guard
   (condition
    (else
     (if (error-object? condition)
         (error-object-message condition)
         #f)))
   (thunk)
   #f))

;; This program runs only with the checked-in poison adapter. Disable poison
;; while retaining its forced `fast-backend? = #f' answer.
(consent-test-identity-map-poison-set! #f)
(check (not (consent-identity-map-fast-backend?))
       "test did not install the no-hash identity adapter")

(let* ((heap (consent-make-datum-heap))
       (within (consent-datum-import heap (host-graph 64)))
       (message
        (rejection-message
         (lambda ()
           (consent-datum-import heap (host-graph 65))))))
  (check (= (consent-datum-vector-length within) 63)
         "ordinary import rejected its fixed compatibility envelope")
  (check
   (string=?
    message
    "consent-datum-import: foreign graph requires fast identity maps")
   "ordinary import did not fail closed beyond its envelope"
   message))

(let* ((heap (consent-make-datum-heap))
       (within
        (call-with-values
         (lambda ()
           (consent-datum-import-with-node-count
            heap
            (host-graph 64)
            (lambda (item) #t)
            (lambda (target source) target)))
         (lambda (value count invalid? invalid-leaf)
           (vector value count invalid? invalid-leaf))))
       (message
        (rejection-message
         (lambda ()
           (call-with-values
            (lambda ()
              (consent-datum-import-with-node-count
               heap
               (host-graph 65)
               (lambda (item) #t)
               (lambda (target source) target)))
            (lambda results results))))))
  ;; One vector, 63 pairs, and each pair's two scalar leaves.
  (check (= (vector-ref within 1) 190)
         "counted import returned the wrong exact node count")
  (check (not (vector-ref within 2))
         "counted import rejected a valid leaf")
  (check
   (string=?
    message
    "consent-datum-import: foreign graph requires fast identity maps")
   "counted import did not fail closed beyond its envelope"
   message))

(let* ((heap (consent-make-datum-heap))
       (cycle (cons 'cycle '()))
       (host (make-vector 63 cycle)))
  (set-cdr! cycle cycle)
  (let* ((within (consent-datum-import heap host))
         (first (consent-datum-vector-ref within 0)))
    (check
     (consent-datum-same? first (consent-datum-cdr first))
     "shared cyclic import lost identity inside its envelope")
    (check
     (consent-datum-same?
      first (consent-datum-vector-ref within 62))
     "shared import copied one source identity more than once")))

(let* ((source-heap (consent-make-datum-heap))
       (target-heap (consent-make-datum-heap))
       (source (owned-graph source-heap 130))
       (copy (consent-datum-import target-heap source)))
  (check (= (consent-datum-vector-length copy) 129)
         "owned cross-heap import was incorrectly capped"))

(let* ((within (value-node-count (host-graph 64) '()))
       (message
        (rejection-message
         (lambda () (value-node-count (host-graph 65) '())))))
  (check (= within 190)
         "runtime host graph counter returned the wrong node count")
  (check
   (string=?
    message
    "runtime foreign graph requires fast identity maps")
   "runtime host graph counter did not fail closed beyond its envelope"
   message))

(let* ((within
        (consent-host-datum->consent-datum (host-graph 64)))
       (message
        (rejection-message
         (lambda ()
           (consent-host-datum->consent-datum (host-graph 65))))))
  (check (= (vector-length within) 63)
         "host conversion rejected its fixed compatibility envelope")
  (check
   (string=?
    message
    "host datum conversion requires fast identity maps")
   "host conversion did not fail closed beyond its envelope"
   message))

(let* ((heap (consent-make-datum-heap))
       (within
        (consent-datum-export (hybrid-export-root heap 64)))
       (message
        (rejection-message
         (lambda ()
           (consent-datum-export
            (hybrid-export-root heap 65))))))
  (check (= (vector-length within) 64)
         "hybrid export rejected its fixed compatibility envelope")
  (check
   (string=?
    message
    "consent-datum-export: foreign graph requires fast identity maps")
   "hybrid export did not fail closed beyond its envelope"
   message))

(write '(datum-nohash-compatibility pass limit 64))
(newline)
