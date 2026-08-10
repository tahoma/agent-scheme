;;; Emit the canonical exhaustive Unicode semantic stream.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This is an opt-in exhaustive oracle, not an ordinary test-plan program.
;;; It observes only the exported `(consent unicode-data)' query behavior and
;;; writes a compact representation-independent stream for an external
;;; SHA-256 check.  `(scheme char)' consumes this exact semantic surface.

(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (consent unicode-data))

;; Destination selected by the exhaustive-check wrapper.
(define output-path
  (get-environment-variable "CONSENT_UNICODE_SEMANTIC_OUTPUT"))

;; Number of Unicode scalar records emitted.
(define scalar-count 0)

;; Number of canonical stream bytes emitted.
(define byte-count 0)

(define (emit-byte port value)
  "Write VALUE to PORT and account for the canonical stream size."
  (write-u8 value port)
  (set! byte-count (+ byte-count 1)))

(define (emit-bytes port values)
  "Write VALUES to PORT in order."
  (for-each (lambda (value) (emit-byte port value)) values))

(define (emit-scalar port value)
  "Write Unicode scalar VALUE as three big-endian bytes."
  (if (or (< value 0)
          (> value #x10ffff)
          (and (<= #xd800 value) (<= value #xdfff)))
      (error "semantic stream received a non-scalar value" value))
  (emit-byte port (quotient value #x10000))
  (emit-byte port (modulo (quotient value #x100) #x100))
  (emit-byte port (modulo value #x100)))

(define (emit-mapped-sequence port value)
  "Write mapped scalar list VALUE as one length byte and scalar sequence."
  (let ((length (length value)))
    (if (> length #xff)
        (error "Unicode full mapping exceeds stream length byte" length))
    (emit-byte port length)
    (for-each (lambda (code) (emit-scalar port code)) value)))

(define (classification-bit value mask name code)
  "Return MASK for true VALUE or zero for false, rejecting other values."
  (cond
   ((eq? value #t) mask)
   ((eq? value #f) 0)
   (else (error "Unicode classifier returned a non-boolean"
                name code value))))

(define (classification-flags code)
  "Pack CODE's four owned Unicode properties into one byte."
  (+
   (classification-bit
    (consent-unicode-alphabetic? code) 1 'alphabetic code)
   (classification-bit
    (consent-unicode-uppercase? code) 2 'uppercase code)
   (classification-bit
    (consent-unicode-lowercase? code) 4 'lowercase code)
   (classification-bit
    (consent-unicode-whitespace? code) 8 'whitespace code)))

(define (decimal-byte value code)
  "Return VALUE's canonical decimal byte, rejecting invalid results."
  (cond
   ((eq? value #f) #xff)
   ((and (exact-integer? value) (<= 0 value) (<= value 9)) value)
   (else (error "Unicode decimal query returned an invalid value"
                code value))))

(define (emit-record port code)
  "Write the owned Unicode data semantics for scalar CODE."
  (let ((decimal (consent-unicode-decimal-value code)))
    (emit-scalar port code)
    (emit-byte port (classification-flags code))
    (emit-byte port (decimal-byte decimal code))
    (emit-scalar port (consent-unicode-simple-uppercase code))
    (emit-scalar port (consent-unicode-simple-lowercase code))
    (emit-scalar port (consent-unicode-simple-foldcase code))
    (emit-mapped-sequence port (consent-unicode-full-uppercase code))
    (emit-mapped-sequence port (consent-unicode-full-lowercase code))
    (emit-mapped-sequence port (consent-unicode-full-foldcase code))
    (set! scalar-count (+ scalar-count 1))))

;; ASCII "Consent Unicode semantics", NUL, schema version 1, NUL.
(define stream-header
  '(67 111 110 115 101 110 116 32 85 110 105 99 111 100 101 32
    115 101 109 97 110 116 105 99 115 0 1 0))

(if (not output-path)
    (error "CONSENT_UNICODE_SEMANTIC_OUTPUT is required"))

(let ((port (open-binary-output-file output-path)))
  (emit-bytes port stream-header)
  (let loop ((code 0))
    (cond
     ((> code #x10ffff)
      (close-output-port port))
     ((and (<= #xd800 code) (<= code #xdfff))
      (loop (+ code 1)))
     (else
      (emit-record port code)
      (loop (+ code 1))))))

(if (not (= scalar-count 1112064))
    (error "Unicode semantic stream scalar count mismatch" scalar-count))

(display "Unicode semantic stream: ")
(display scalar-count)
(display " scalars, ")
(display byte-count)
(display " bytes")
(newline)
