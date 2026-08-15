;;; Direct-owned reader poison-backend and linear-allocation gate.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (consent datum)
        (consent identity-map)
        (consent reader)
        (only (consent symbol)
              consent-intern-symbol
              consent-make-symbol-table)
        (only (consent symbol-boundary)
              consent-host-symbol-equal?))

(define (check condition message . irritants)
  "Raise MESSAGE with IRRITANTS unless CONDITION is true."
  (if (not condition) (apply error message irritants)))

(define (compound-source count)
  "Return one labelled vector with COUNT representative compound elements."
  (let ((output (open-output-string)))
    (display "#0=#(" output)
    (let loop ((remaining count))
      (if (> remaining 0)
          (begin
            (display "(a \"x\" #u8(1)) " output)
            (loop (- remaining 1)))))
    (display "#0#)" output)
    (get-output-string output)))

(define (incremental-source count)
  "Return COUNT small forms for repeated prepared-source reads."
  (let ((output (open-output-string)))
    (let loop ((remaining count))
      (if (> remaining 0)
          (begin
            (display "(x) " output)
            (loop (- remaining 1)))))
    (get-output-string output)))

(define (check-zero-revision object message)
  "Require fresh owned OBJECT to have revision zero."
  (check (= (consent-datum-object-revision object) 0) message))

(define (check-owned-read count)
  "Read COUNT elements and prove its exact direct-owned allocation shape."
  (let* ((heap (consent-make-datum-heap))
         (hook-count 0)
         (before (consent-datum-cons heap 'before '())))
    (consent-datum-heap-mutation-hook-set!
     heap
     (lambda arguments
       (set! hook-count (+ hook-count 1))
       #t))
    (let* ((metadata-before (consent-source-metadata-count))
           (root (consent-read-datum heap (compound-source count)))
           (after (consent-datum-cons heap 'after '()))
           (first (consent-datum-vector-ref root 0))
           (first-tail (consent-datum-cdr first))
           (text (consent-datum-car first-tail))
           (byte-tail (consent-datum-cdr first-tail))
           (bytes (consent-datum-car byte-tail)))
      ;; Each element contributes three pairs, one string, and one bytevector;
      ;; the labelled root contributes one vector. No import copy is hidden.
      (check
       (= (- (consent-datum-object-id after)
             (consent-datum-object-id before)
             1)
          (+ (* count 5) 1))
       "owned reader allocation count was not exactly linear"
       count)
      (check (consent-datum-vector? root) "root was not an owned vector")
      (check (consent-datum-pair? first) "element was not an owned pair")
      (check (consent-datum-string? text) "string was not directly owned")
      (check (consent-datum-bytevector? bytes)
             "bytevector was not directly owned")
      (check
       (consent-datum-same?
        root (consent-datum-vector-ref root count))
       "datum-label cycle did not resolve to owned identity")
      (check-zero-revision root "root revision changed during construction")
      (check-zero-revision first "pair revision changed during construction")
      (check-zero-revision text "string revision changed during construction")
      (check-zero-revision
       bytes "bytevector revision changed during construction")
      (check (= hook-count 0) "construction invoked the mutation hook")
      (check (= metadata-before (consent-source-metadata-count))
             "owned provenance entered the legacy global table")
      (check (consent-datum-object-source-metadata root)
             "owned root lost source metadata")
      (check (not (consent-datum-object-traversal root))
             "owned root remained under construction")
      (call-with-consent-datum-object-map
       (lambda (map)
         (consent-datum-object-map-set! map root 'seen)
         (check (eq? (consent-datum-object-map-ref map root #f) 'seen)
                "owned object map lost its value")
         (check (= (consent-datum-object-map-probe-count map root) 1)
                "owned object map lookup was not one header probe"))))))

(define (check-owned-incremental-read)
  "Exercise the incremental owned entry while the host map stays poisoned."
  (let* ((heap (consent-make-datum-heap))
         (before (consent-datum-cons heap 'before '()))
         (result
          (consent-read-datum-from-string-at
           heap "#0=(a . #(#0#)) tail" 0))
         (root (car result))
         (vector (consent-datum-cdr root))
         (after (consent-datum-cons heap 'after '())))
    (check (= (cdr result) 15) "incremental reader returned wrong position")
    (check (= (- (consent-datum-object-id after)
                 (consent-datum-object-id before)
                 1)
              2)
           "incremental reader did not allocate exactly pair plus vector")
    (check
     (consent-datum-same? root (consent-datum-vector-ref vector 0))
     "incremental reader lost its owned cycle")))

(define (check-prepared-incremental-scaling count)
  "Read COUNT forms through one prepared snapshot with exact allocations."
  (let* ((heap (consent-make-datum-heap))
         (source (consent-make-reader-source (incremental-source count)))
         (before (consent-datum-cons heap 'before '())))
    (check (consent-reader-source? source)
           "prepared source did not retain its nominal type")
    (let loop ((position 0) (read-count 0))
      (let ((result
             (consent-read-datum-from-string-at
              heap source position)))
        (if (consent-read-eof? (car result))
            (let ((after (consent-datum-cons heap 'after '())))
              (check (= read-count count)
                     "prepared incremental reader lost a form")
              ;; Every `(x)' contributes exactly one owned pair. Preparing and
              ;; reopening the shared lexical snapshot contributes none.
              (check (= (- (consent-datum-object-id after)
                           (consent-datum-object-id before)
                           1)
                        count)
                     "prepared incremental allocation was not linear"))
            (loop (cdr result) (+ read-count 1)))))))

;; The overlay starts poisoned. Any constructor, lookup, or set through the
;; host identity-map interface aborts this program immediately.
(let* ((table (consent-make-symbol-table))
       (owned (consent-intern-symbol table "shared-name")))
  (check
   (consent-host-symbol-equal?
    (list owned 'tail 3) '(shared-name tail 3))
   "short symbol-aware list equality allocated an identity map")
  (check
   (not
    (consent-host-symbol-equal?
     (list owned 'tail 3) '(shared-name other 3)))
   "short symbol-aware list mismatch allocated an identity map"))
(check (= (consent-test-identity-map-operation-count) 0)
       "identity map was touched while importing owned reader libraries")
(check-owned-read 256)
(check-owned-read 1024)
(check-owned-incremental-read)
(check-prepared-incremental-scaling 256)
(check-prepared-incremental-scaling 1024)
(check (= (consent-test-identity-map-operation-count) 0)
       "direct owned reader touched the host identity-map interface")

;; Disable poison and prove the same forced plain-R7RS backend remains a
;; correctness path for legacy private syntax and its cyclic writer.
(consent-test-identity-map-poison-set! #f)
(let* ((legacy (consent-read "#0=(a . #(#0#))"))
       (vector (cdr legacy)))
  (check (eq? legacy (vector-ref vector 0))
         "legacy fallback lost datum-label identity")
  (check (string=? (consent-datum->external legacy)
                   "#0=(a . #1=#(#0#))")
         "legacy fallback writer lost cyclic syntax"))
(check (> (consent-test-identity-map-operation-count) 0)
       "legacy fallback did not exercise the identity alist")
(check (> (consent-test-identity-map-release-count) 0)
       "legacy fallback did not release its host identity maps")

(write '(owned-reader-no-host-identity pass
         exact-allocations ((256 . 1281) (1024 . 5121))
         prepared-incremental-allocations ((256 . 256) (1024 . 1024))
         owned-map-header-probes 1))
(newline)
