;;; Portable reader test runner for the Consent Scheme R7RS library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; reader library without loading the Emacs host adapter.

(import (scheme base)
        (scheme cxr)
        (scheme time)
        (scheme write)
        (consent datum)
        (consent identity-map)
        (consent reader)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Report whether this suite runs inside a compiled host subprocess.
(define compiled-host-run?
  (if (get-environment-variable "TESTING_RUNNER_HOST_RUN") #t #f))

;; Shared reader behavior runs through consent-fixture-test.scm. This file
;; keeps portable reader API and bootstrap invariants close to the R7RS
;; library.

(testing-registry-case
 'identity-map-uses-object-identity '(portable core datum performance)
(let* ((left (vector 'same))
       (right (vector 'same))
       (map (consent-make-identity-map)))
  (test-assert
   'gambit-identity-map-selects-fast-backend
   (cond-expand
    (gambit (consent-identity-map-fast-backend?))
    (else #t)))
  (consent-identity-map-set! map left 'left)
  (test-equal
   'identity-map-distinguishes-equal-containers
   '(left missing)
   (list
    (consent-identity-map-ref map left 'missing)
    (consent-identity-map-ref map right 'missing)))))

;; Read SOURCE through the portable reader and compare its external form.
(define (check-external name source expected)
  (test-equal name
             expected
             (consent-datum->external (consent-read source))))

;; Return #t when THUNK raises any portable Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

;; The reader owns this deliberately private verification option. It exposes
;; no binding and records only general validation's host map adapter calls.
(define reader-validation-map-counter-option
  '%reader-validation-identity-map-operation-counter)

(define (reader-validation-options counter maximum-total)
  "Return focused unlabelled-reader options with validation COUNTER."
  (list (cons 'source-metadata #f)
        (cons reader-validation-map-counter-option counter)
        (cons 'max-depth 8)
        (cons 'max-list-length 4)
        (cons 'max-vector-length 4)
        (cons 'max-bytevector-length 4)
        (cons 'max-string-size 8)
        (cons 'max-total-nodes maximum-total)))

(testing-registry-case
 'unlabelled-private-host-validation-fast-path
 '(portable core datum performance)
(let* ((counter (vector -1))
       (pass-options (reader-validation-options counter 9)))
  (test-equal
   'unlabelled-host-tree-mixed-datum
   "(a #(b) \"c\" #u8(1))"
   (consent-datum->external
    (consent-read "(a #(b) \"c\" #u8(1))" pass-options)))
  (test-equal
   'unlabelled-host-tree-zero-validation-map-operations
   0
   (vector-ref counter 0))
  ;; The parser charges this two-element list as three lexical nodes, while
  ;; validation charges its two pair cells and two atoms exactly once.
  (test-assert
   'unlabelled-host-tree-exact-node-limit-pass
   (pair? (consent-read "(a b)"
                        (reader-validation-options counter 4))))
  (test-assert
   'unlabelled-host-tree-exact-node-limit-fail
   (raises?
    (lambda ()
      (consent-read "(a b)"
                    (reader-validation-options counter 3)))))
  (test-equal
   'unlabelled-host-tree-node-failure-still-uses-zero-map-operations
   0
   (vector-ref counter 0))
  (test-equal
   'unlabelled-host-tree-improper-list
   "(a b . c)"
   (consent-datum->external
    (consent-read
     "(a b . c)"
     (reader-validation-options counter 5))))
  (test-equal
   'unlabelled-host-tree-vector-contained-list
   "#((a b c))"
   (consent-datum->external
    (consent-read
     "#((a b c))"
     (reader-validation-options counter 7))))
  (test-assert
   'unlabelled-host-tree-vector-contained-list-limit
   (raises?
    (lambda ()
      (consent-read
       "#((a b c d e))"
       (reader-validation-options counter 16)))))
  (let ((datums
         (consent-read-all
          "(first) #(second) \"third\""
          pass-options)))
    (test-equal
     'unlabelled-host-tree-read-all-source-order
     '("(first)" "#(second)" "\"third\"")
     (map consent-datum->external datums))
    (test-equal
     'unlabelled-host-tree-read-all-zero-map-operations
     0
     (vector-ref counter 0)))
  (let ((incremental
         (consent-read-from-string-at
          "(next) tail" 0 pass-options)))
    (test-equal
     'unlabelled-host-tree-incremental-result
     '("(next)" 6)
     (list (consent-datum->external (car incremental))
           (cdr incremental)))
    (test-equal
     'unlabelled-host-tree-incremental-zero-map-operations
     0
     (vector-ref counter 0)))
  ;; Labelled syntax, arbitrary public datums, and recovery must continue to
  ;; select the general graph validator; each control self-calibrates the
  ;; exact counter by requiring at least one host adapter operation.
  (consent-read "#0=(labelled . #0#)" pass-options)
  (test-assert
   'labelled-reader-retains-general-validator
   (> (vector-ref counter 0) 0))
  (consent-validate-datum '(public datum) pass-options)
  (test-assert
   'public-validation-retains-general-validator
   (> (vector-ref counter 0) 0))
  (consent-read-recover "(recovery)" pass-options)
  (test-assert
   'recovery-retains-general-validator
   (> (vector-ref counter 0) 0))
  ;; A metadata sink can mutate unpublished host syntax. Such a callback can
  ;; introduce graph topology even when the source contains no datum labels,
  ;; so its active path must retain the general validator.
  (let* ((sink-counter (vector -1))
         (mutated? #f)
         (sink-options
          (cons
           (cons 'source-metadata #t)
           (cons
            (cons
             'source-metadata-sink
             (lambda (datum source)
               (if (and (pair? datum) (not mutated?))
                   (begin
                     (set! mutated? #t)
                     (set-cdr! datum datum)))))
            (reader-validation-options sink-counter 8))))
         (sinked (consent-read "(sinked)" sink-options)))
    (test-assert
     'active-metadata-sink-cycle-survives-validation
     (eq? sinked (cdr sinked)))
    (test-assert
     'active-metadata-sink-retains-general-validator
     (> (vector-ref sink-counter 0) 0)))))

;; Return the smallest elapsed-jiffy reading across ATTEMPTS runs of THUNK.
(define (reader-minimum-probe-jiffies thunk attempts)
  (let loop ((remaining attempts) (best #f))
    (if (= remaining 0)
        best
        (let ((elapsed (thunk)))
          (loop (- remaining 1)
                (if (or (not best) (< elapsed best)) elapsed best))))))

;; Return one vector whose COUNT numeric elements each start on their own line.
(define (multiline-reader-vector-source count)
  (let ((output (open-output-string)))
    (display "#(\n" output)
    (let loop ((remaining count))
      (if (> remaining 0)
          (begin
            (display "1\n" output)
            (loop (- remaining 1)))))
    (display ")" output)
    (get-output-string output)))

;; Return COUNT one-line forms for prepared incremental reader coverage.
(define (multiline-reader-incremental-source count)
  (let ((output (open-output-string)))
    (let loop ((remaining count))
      (if (> remaining 0)
          (begin
            (display "(1)\n" output)
            (loop (- remaining 1)))))
    (get-output-string output)))

;; Sum the real fixed location-index probe over COUNT regular source offsets.
(define (reader-source-location-probes source first stride count)
  (let loop ((index 0) (probes 0))
    (if (= index count)
        probes
        (loop
         (+ index 1)
         (+ probes
            (consent-reader-source-location-probe-count
             source (+ first (* index stride))))))))

;; Return DATUM's source metadata field NAME, or #f when it is absent.
(define (reader-source-field datum name)
  (let* ((metadata (consent-datum-source datum))
         (cell (and metadata (assq name (cdr metadata)))))
    (if cell (cadr cell) #f)))

;; Return DATUM's numeric source metadata field NAME as a host integer.
(define (reader-source-number-field datum name)
  (let ((value (reader-source-field datum name)))
    (if (consent-number? value) (consent-number-value value) value)))

;; Return the portable semantic fields of DATUM's source metadata.
(define (reader-source-fields datum)
  (list (reader-source-field datum 'source-id)
        (reader-source-number-field datum 'line)
        (reader-source-number-field datum 'column)
        (reader-source-number-field datum 'offset)
        (reader-source-number-field datum 'span)
        (reader-source-field datum 'phase)))

;; Measure repeated global source-metadata lookups after ENTRY-COUNT distinct
;; host identities. Setup is outside the timed region so this isolates whether
;; compatibility-table size affects one current-key lookup.
(define (reader-host-source-lookup-probe entry-count lookup-count)
  (let ((oldest (vector 'oldest)))
    (consent-datum-source-set! oldest '(source-probe))
    (let fill ((remaining (- entry-count 1)))
      (if (> remaining 0)
          (begin
            (consent-datum-source-set!
             (vector remaining) '(source-probe))
            (fill (- remaining 1)))))
    (let ((started (current-jiffy)))
      (let lookup ((remaining lookup-count))
        (if (> remaining 0)
            (begin
              (if (not (equal? (consent-datum-source oldest)
                               '(source-probe)))
                  (error "source metadata table probe lost its key"))
              (lookup (- remaining 1)))))
      (- (current-jiffy) started))))

;; Measure an owned V-node import whose source-copy callback reads and writes
;; one directly owned provenance slot per compound node.
(define (reader-owned-source-import-probe size rounds)
  (let* ((source-heap (consent-make-datum-heap))
         (root (consent-datum-make-vector source-heap size #f)))
    (let fill ((index 0))
      (if (< index size)
          (let ((node (consent-datum-cons source-heap index '())))
            (consent-datum-source-set! node '(source-probe))
            (consent-datum-vector-set! source-heap root index node)
            (fill (+ index 1)))))
    (consent-datum-source-set! root '(source-probe))
    (let ((started (current-jiffy)))
      (let import ((remaining rounds))
        (if (> remaining 0)
            (let ((copy
                   (consent-datum-import
                    (consent-make-datum-heap)
                    root
                    (lambda (leaf) leaf)
                    (lambda (target source)
                      (consent-copy-datum-source! target source #t)))))
              (if (not (equal? (consent-datum-source copy)
                               '(source-probe)))
                  (error "owned source-copy import lost root metadata"))
              (import (- remaining 1)))))
      (- (current-jiffy) started))))

(testing-registry-case
 'source-metadata-index-scaling '(portable core datum performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'source-metadata-index-scaling-reference-host #t)
    (let* ((host-small
            (reader-minimum-probe-jiffies
             (lambda () (reader-host-source-lookup-probe 1024 32768))
             2))
           (host-large
            (reader-minimum-probe-jiffies
             (lambda () (reader-host-source-lookup-probe 8192 32768))
             2))
           (owned-small
            (reader-minimum-probe-jiffies
             (lambda () (reader-owned-source-import-probe 256 4))
             2))
           (owned-large
            (reader-minimum-probe-jiffies
             (lambda () (reader-owned-source-import-probe 1024 4))
             2))
           (jitter (quotient (jiffies-per-second) 20)))
      (write
       (list 'source-metadata-index-probe
             (list 'host-entries-1024 host-small)
             (list 'host-entries-8192 host-large)
             (list 'owned-import-256 owned-small)
             (list 'owned-import-1024 owned-large)
             (list 'jiffies-per-second (jiffies-per-second))))
      (newline)
      (test-assert
       'host-source-lookup-size-independent
       (<= host-large (+ (* 4 (max 1 host-small)) jitter)))
      (test-assert
       'owned-source-copy-import-near-linear
       (<= owned-large (+ (* 8 (max 1 owned-small)) jitter))))))

(testing-registry-case
 'source-metadata-replacement-retains-budget-count '(portable core datum)
(let ((before (consent-source-metadata-count))
      (datum (vector 'source-target)))
  (consent-datum-source-set! datum 'older-source)
  (consent-datum-source-set! datum 'newer-source)
  (test-equal
   'source-metadata-replacement-retains-budget-count
   (list 1 'newer-source)
   (list (- (consent-source-metadata-count) before)
         (consent-datum-source datum)))))

;; Context-backed readers publish immutable notes through their supplied sink;
;; their private parser containers never enter the process-global provenance
;; map. Their per-run arena accounts identities locally and is then dropped.
(testing-registry-case
 'source-metadata-context-sink '(portable core datum performance)
(let ((before (consent-source-metadata-count))
      (notes '()))
  (let* ((options
          (list
           (cons 'source-id 'context-sink-test)
           (cons 'source-metadata-sink
                 (lambda (value metadata)
                   (set! notes (cons (cons value metadata) notes))))))
         (datums (consent-read-all "(alpha) #(beta)" options))
         (pair (car datums))
         (vector (cadr datums))
         (single (consent-read "(gamma)" options)))
    (test-equal 'source-metadata-context-sink-count
                3
                (length notes))
    (test-equal 'source-metadata-context-sink-budget-charge
                0
                (- (consent-source-metadata-count) before))
    (test-assert 'source-metadata-context-sink-pair-not-global
                 (not (consent-datum-source pair)))
    (test-assert 'source-metadata-context-sink-vector-not-global
                 (not (consent-datum-source vector)))
    (test-assert 'source-metadata-context-sink-single-not-global
                 (not (consent-datum-source single))))))

(testing-registry-case
 'source-metadata-labelled-replacement-count
 '(portable core datum performance)
(let ((notes '()))
  (let* ((datum
          (consent-read
           "#1=(x . #1#)"
           (list
            (cons 'max-source-metadata 1)
            (cons 'source-metadata-sink
                  (lambda (value metadata)
                    (set! notes (cons (cons value metadata) notes)))))))
         (outer
          (consent-source-metadata->record (cdr (car notes))))
         (inner
          (consent-source-metadata->record (cdr (cadr notes))))
         (span
          (lambda (metadata)
            (consent-number-value
             (cadr (assq 'span (cdr metadata)))))))
    ;; The list parser attaches one fresh note. The enclosing label definition
    ;; then replaces that same identity's note without consuming another unit.
    (test-equal
     'source-metadata-labelled-replacement-preserves-count-and-span
     '(2 #t #t 12 9)
     (list
      (length notes)
      (eq? datum (cdr datum))
      (eq? (car (car notes)) (car (cadr notes)))
      (span outer)
      (span inner))))))

;; Owned reads attach provenance directly even when context options carry a
;; sink. No parser compound graph or identity arena enters either process
;; index.
(testing-registry-case
 'owned-source-metadata-direct-lifetime
 '(portable core datum boundary performance)
(if compiled-host-run?
    (test-assert 'owned-source-metadata-direct-not-applicable #t)
    (let ((before (consent-source-metadata-count))
          (heap (consent-make-datum-heap))
          (sink-count 0)
          (last #f))
      (let ((options
             (list
              (cons 'source-id 'owned-direct-test)
              (cons 'source-metadata-sink
                    (lambda (value metadata)
                      (set! sink-count (+ sink-count 1)))))))
        (let loop ((remaining 512))
          (if (> remaining 0)
              (begin
                (set! last
                      (consent-read-datum heap "(17 #(field))" options))
                (loop (- remaining 1))))))
      (let* ((number (consent-datum-car last))
             (nested-vector
              (consent-datum-car
               (consent-datum-cdr last))))
        (test-equal 'owned-source-metadata-direct-not-global
                    0
                    (- (consent-source-metadata-count) before))
        (test-equal 'owned-source-metadata-direct-not-sunk 0 sink-count)
        (test-assert 'owned-source-metadata-compound-survives
                     (consent-datum-source last))
        (test-assert 'owned-source-metadata-number-survives
                     (and (consent-number? number)
                          (consent-datum-source number)))
        (test-assert 'owned-source-metadata-vector-survives
                     (consent-datum-source nested-vector))
        (let* ((type (consent-make-record-type 'sample '(field)))
               (record (consent-make-record type (vector number))))
          ;; Copy after the read call has returned. Record constructors keep
          ;; their public two-argument arities while private current slots
          ;; retain the metadata.
          (consent-copy-datum-source! type number #t)
          (consent-copy-datum-source! record number #t)
          (consent-datum-source-set! record 'replacement-source)
          (test-equal 'record-type-source-survives-direct-read
                      (reader-source-fields number)
                      (reader-source-fields type))
          (test-equal 'record-current-source-replaces-in-place
                      'replacement-source
                      (consent-datum-source record))
          (test-equal 'direct-source-slots-remain-not-global
                      0
                      (- (consent-source-metadata-count) before)))))))

(testing-registry-case
 'boolean-true '(portable core)
(check-external 'boolean-true "#true" "#t"))
(testing-registry-case
 'boolean-false '(portable core)
(check-external 'boolean-false "#false" "#f"))
(testing-registry-case
 'false-is-not-null '(portable core)
(test-equal 'false-is-not-null #f (null? (consent-read "#f"))))
(testing-registry-case
 'empty-list-is-null '(portable core)
(test-equal 'empty-list-is-null #t (null? (consent-read "()"))))

(testing-registry-case
 'symbol-case '(portable core)
(check-external 'symbol-case "Consent-Scheme" "Consent-Scheme"))
(testing-registry-case
 'fold-case '(portable core)
(check-external 'fold-case "#!fold-case Consent-Scheme" "consent-scheme"))
(testing-registry-case
 'vertical-symbol '(portable core)
(check-external 'vertical-symbol "|two\\x20;words|" "|two words|"))
(testing-registry-case
 'vertical-symbol-delimiter '(portable core)
(check-external 'vertical-symbol-delimiter "|left\\|right|" "|left\\|right|"))
(testing-registry-case
 'string-vertical-bar '(portable core)
(test-equal 'string-vertical-bar
            "\"left|right\""
            (consent-datum->external "left|right")))

(testing-registry-case
 'string-escapes '(portable core)
(test-equal 'string-escapes
             (string-append "line\n" (string (integer->char #x03bb)))
             (consent-read "\"line\\n\\x03bb;\"")))
(testing-registry-case
 'string-line-continuation '(portable core)
(test-equal 'string-line-continuation
             "ab"
             (consent-read (string-append "\"a\\" "\n  b\""))))
(testing-registry-case
 'character-name '(portable core)
(check-external 'character-name "#\\space" "#\\space"))
(testing-registry-case
 'character-hex '(portable core)
(check-external 'character-hex "#\\X03BB" "#\\λ"))
(testing-registry-case
 'character-owned-scalar '(portable core)
(let ((character (consent-read "#\\x10ffff")))
  (test-equal 'character-owned-scalar
              (list #t #x10ffff)
              (list (consent-character? character)
                    (consent-character-code character)))))
(testing-registry-case
 'character-invalid-surrogate '(portable core)
(test-equal 'character-invalid-surrogate
            #t
            (raises? (lambda () (consent-read "#\\xd800")))))
(testing-registry-case
 'character-invalid-surrogate-end '(portable core)
(test-equal 'character-invalid-surrogate-end
            #t
            (raises? (lambda () (consent-read "#\\xdfff")))))
(testing-registry-case
 'character-invalid-out-of-range '(portable core)
(test-equal 'character-invalid-out-of-range
            #t
            (raises? (lambda () (consent-read "#\\x110000")))))
(testing-registry-case
 'character-malformed-hex '(portable core)
(test-equal 'character-malformed-hex
            #t
            (raises? (lambda () (consent-read "#\\xzz")))))
(testing-registry-case
 'character-name-case '(portable core)
(let ((folded (consent-read "#!fold-case #\\Space")))
  (test-assert 'character-name-default-case-sensitive
               (raises? (lambda () (consent-read "#\\Space"))))
  (test-equal 'character-name-fold-case
              #x20
              (consent-character-code folded))))

;; Character writer fixtures cover named, printable, Unicode, and control
;; forms.
(define character-writer-cases
  '(("character-writer-space" "#\\space" "#\\space")
    ("character-writer-tab" "#\\tab" "#\\tab")
    ("character-writer-alarm" "#\\alarm" "#\\alarm")
    ("character-writer-backspace" "#\\backspace" "#\\backspace")
    ("character-writer-delete-name" "#\\delete" "#\\delete")
    ("character-writer-escape" "#\\escape" "#\\escape")
    ("character-writer-newline" "#\\newline" "#\\newline")
    ("character-writer-null" "#\\null" "#\\null")
    ("character-writer-return" "#\\return" "#\\return")
    ("character-writer-printable" "#\\a" "#\\a")
    ("character-writer-unicode" "#\\x03bb" "#\\λ")
    ("character-writer-control-start-of-heading" "#\\x1" "#\\x1")
    ("character-writer-control-unit-separator" "#\\x1f" "#\\x1f")
    ("character-writer-delete" "#\\x7f" "#\\delete")))

(testing-registry-case
 'name '(portable core)
(for-each
 (lambda (case)
   (let* ((name (string->symbol (car case)))
          (source (cadr case))
          (expected (list-ref case 2))
          (external (consent-datum->external
                     (consent-read source))))
     (test-equal name expected external)
     (test-equal (string->symbol (string-append (car case) "-round-trip"))
             expected
             (consent-datum->external
             (consent-read external)))))
 character-writer-cases))

(testing-registry-case
 'supplementary-character-writer '(portable core)
(for-each
 (lambda (code)
   (let* ((source (string-append "#\\x" (number->string code 16)))
          (expected (string-append "#\\" (string (integer->char code))))
          (external (consent-datum->external (consent-read source))))
     (test-equal (list 'supplementary-character-writer code)
                 expected
                 external)
     (test-equal (list 'supplementary-character-writer-roundtrip code)
                 expected
                 (consent-datum->external (consent-read external)))))
 '(#x1f642 #x10ffff)))

(testing-registry-case
 'integer '(portable core)
(check-external 'integer "42" "42"))
;; Read numbers share the canonical constructors' representation class.
;; Compare against a canonical integer rather than hardcoding what the
;; surrounding Scheme's `number?' answers: on a reference host both are
;; records (#f and #f); when this file runs on the Consent runtime itself via
;; --host-run, canonical Consent numbers ARE the runtime's numbers (#t and
;; #t). The invariant is the agreement, not the host's answer.
(testing-registry-case
 'integer-matches-canonical-number-class '(portable core)
(test-equal 'integer-matches-canonical-number-class
             (number? (consent-make-canonical-integer 42))
             (number? (consent-read "42"))))
(testing-registry-case
 'host-integer-writer '(portable core)
(test-equal 'host-integer-writer
             "42"
             (consent-datum->external 42)))
(testing-registry-case
 'host-rational-writer '(portable core)
(test-equal 'host-rational-writer
             "3/2"
             (consent-datum->external (/ 3 2))))
(testing-registry-case
 'host-decimal-writer '(portable core)
(test-equal 'host-decimal-writer
             "3.0"
             (consent-datum->external 3.0)))
(testing-registry-case
 'hex-integer '(portable core)
(check-external 'hex-integer "#x2a" "42"))
(testing-registry-case
 'rational '(portable core)
(check-external 'rational "3/4" "3/4"))
(testing-registry-case
 'decimal '(portable core)
(check-external 'decimal "1.5" "1.5"))
(testing-registry-case
 'decimal-integer-external-form '(portable core)
(test-equal 'decimal-integer-external-form
             "3.0"
             (consent-datum->external
        (consent-make-canonical-decimal 3.0))))
(testing-registry-case
 'reduced-rational '(portable core)
(check-external 'reduced-rational "6/10" "3/5"))
(testing-registry-case
 'exact-decimal '(portable core)
(check-external 'exact-decimal "#e1.5" "3/2"))
(testing-registry-case
 'owned-decimal-exponent '(portable core)
(check-external 'owned-decimal-exponent "#e0e1000001" "0"))
(testing-registry-case
 'inexact-rational '(portable core)
(check-external 'inexact-rational "#i3/2" "1.5"))

;; Numeric-prefix and component forms selected from the R7RS lexical grammar.
(define numeric-reader-valid-cases
  '((binary-prefix "#b101010" "42")
    (octal-prefix "#o52" "42")
    (decimal-prefix "#d42" "42")
    (hexadecimal-prefix-case-insensitive "#x2A" "42")
    (exactness-before-radix "#e#x2a" "42")
    (radix-before-exactness "#x#e2a" "42")
    (inexactness-before-radix "#i#b10" "2.0")
    (radix-before-inexactness "#b#i10" "2.0")
    (exact-positive-exponent "#e1e3" "1000")
    (exact-leading-dot "#e.125" "1/8")
    (exact-trailing-dot "#e1." "1")
    (exact-negative-exponent "#e1e-3" "1/1000")
    (positive-unit-imaginary "+i" "0+1i")
    (negative-unit-imaginary "-i" "0-1i")
    (implicit-positive-imaginary "2+i" "2+1i")
    (implicit-negative-imaginary "2-i" "2-1i")
    (hexadecimal-rectangular "#xA+Bi" "10+11i")
    (hexadecimal-e-digit-before-sign "#xE-1i" "14-1i")
    (slash-led-numeric-like-identifier "/1" "/1")
    (at-led-numeric-like-identifier "@1" "@1")
    (dot-led-numeric-like-identifier ".e1" ".e1")
    (sign-led-numeric-like-identifier "+e1" "+e1")))

(testing-registry-case
 'numeric-reader-valid-grammar-matrix '(portable core numeric)
(for-each
 (lambda (entry)
   (check-external (car entry) (cadr entry) (caddr entry)))
 numeric-reader-valid-cases))

;; Tokens that begin as numeric syntax must be rejected rather than truncated,
;; accepted with duplicate prefixes, or silently reclassified as identifiers.
(define numeric-reader-invalid-cases
  '((binary-digit-out-of-range "#b2")
    (octal-digit-out-of-range "#o8")
    (hexadecimal-digit-out-of-range "#xg")
    (duplicate-exactness "#e#i1")
    (duplicate-radix "#x#b1")
    (missing-exact-body "#e")
    (missing-radix-body "#x")
    (missing-ratio-denominator "1/")
    (zero-ratio-denominator "1/0")
    (missing-exponent-digits "1e")
    (missing-positive-exponent-digits "1e+")
    (duplicate-decimal-point "1..0")
    (missing-polar-angle "1@")
    (duplicate-polar-separator "1@2@3")
    (misordered-imaginary-suffix "1+i2")
    (missing-imaginary-unit "1+2")
    (duplicate-imaginary-unit "1+2ii")
    (nondecimal-fraction "#x1.0")
    (nondecimal-exponent "#b1e2")))

(testing-registry-case
 'numeric-reader-invalid-grammar-matrix '(portable core numeric)
(for-each
 (lambda (entry)
   (test-equal
    (car entry)
    #t
    (raises? (lambda () (consent-read (cadr entry))))))
 numeric-reader-invalid-cases))

(testing-registry-case
 'complex-rectangular '(portable core)
(check-external 'complex-rectangular "3/4-5/6i" "3/4-5/6i"))
(testing-registry-case
 'infinity '(portable core)
(check-external 'infinity "+inf.0" "+inf.0"))
(testing-registry-case
 'complex-positive-infinity-imaginary '(portable core)
(check-external 'complex-positive-infinity-imaginary "+inf.0i" "0+inf.0i"))
(testing-registry-case
 'complex-negative-infinity-imaginary '(portable core)
(check-external 'complex-negative-infinity-imaginary "-inf.0i" "0-inf.0i"))
(testing-registry-case
 'complex-nan-imaginary '(portable core)
(check-external 'complex-nan-imaginary "+nan.0i" "0+nan.0i"))
(testing-registry-case
 'polar-infinite-magnitude '(portable core)
(check-external 'polar-infinite-magnitude "+inf.0@0" "+inf.0+nan.0i"))
(testing-registry-case
 'polar-infinite-angle '(portable core)
(check-external 'polar-infinite-angle "1@+inf.0" "+nan.0+nan.0i"))
(testing-registry-case
 'polar-nan-magnitude '(portable core)
(check-external 'polar-nan-magnitude "+nan.0@0" "+nan.0+nan.0i"))
(testing-registry-case
 'bare-i-symbol '(portable core)
(check-external 'bare-i-symbol "i" "i"))
(testing-registry-case
 'ordinary-identifier '(portable core)
(check-external 'ordinary-identifier
                "number-parser-should-not-see-me"
                "number-parser-should-not-see-me"))
(testing-registry-case
 'signed-identifier '(portable core)
(check-external 'signed-identifier
                "+number-parser-should-not-see-me"
                "+number-parser-should-not-see-me"))
(testing-registry-case
 'dotted-identifier '(portable core)
(check-external 'dotted-identifier
                ".number-parser-should-not-see-me"
                ".number-parser-should-not-see-me"))

;; Exercise large-source cursor access without asserting a host-specific time.
;; Multibyte contents also cover readers whose strings use UTF-8 storage.
(testing-registry-case
 'large-unicode-string-length '(portable core)
(let* ((length 1024)
       (source (string-append "\"" (make-string length #\λ) "\""))
       (value (consent-read source)))
  (test-equal 'large-unicode-string-length
             length
             (string-length value))))

(testing-registry-case
 'dotted-list '(portable core)
(check-external 'dotted-list "(alpha beta . gamma)" "(alpha beta . gamma)"))
(testing-registry-case
 'quote '(portable core)
(check-external 'quote "'alpha" "(quote alpha)"))
(testing-registry-case
 'quasiquote '(portable core)
(check-external
 'quasiquote
 "`(,alpha ,@beta)"
 "(quasiquote ((unquote alpha) (unquote-splicing beta)))"))
(testing-registry-case
 'vector '(portable core)
(check-external 'vector "#(1 alpha \"ok\")" "#(1 alpha \"ok\")"))
(testing-registry-case
 'bytevector '(portable core)
(check-external 'bytevector "#u8(0 127 255)" "#u8(0 127 255)"))

;; Return COUNT nested datum-comment prefixes followed by exactly COUNT
;; ignored atomic datums and one surviving symbol.
(define (nested-datum-comment-source count)
  "Return a source exercising COUNT pending datum-comment continuations."
  (let ((output (open-output-string)))
    (let prefixes ((remaining count))
      (if (> remaining 0)
          (begin
            (display "#;" output)
            (prefixes (- remaining 1)))))
    (let datums ((remaining count))
      (if (> remaining 0)
          (begin
            (display " 0" output)
            (datums (- remaining 1)))))
    (display " survivor" output)
    (get-output-string output)))

(testing-registry-case
 'comments '(portable core)
(test-equal 'comments
             '("1" "2")
             (map consent-datum->external
            (consent-read-all
             "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))))

(testing-registry-case
 'nested-datum-comments-stack-safe '(portable core datum performance)
(let* ((count 24000)
       (source (nested-datum-comment-source count)))
  (test-equal
   'nested-datum-comments-stack-safe
   "survivor"
   (consent-datum->external
    (consent-read
     source
     (list (cons 'max-depth count)
           (cons 'max-total-nodes (+ count 1))
           (cons 'source-metadata #f)))))
  (test-assert
   'nested-datum-comments-depth-budget
   (raises?
    (lambda ()
      (consent-read
       (nested-datum-comment-source 9)
       '((max-depth . 8)
         (max-total-nodes . 10)
         (source-metadata . #f))))))))

(testing-registry-case
 'list-limit '(portable core)
(test-equal 'list-limit
             #t
             (raises?
        (lambda ()
          (consent-read "(1 2 3)" '((max-list-length . 2)))))))
(testing-registry-case
 'vector-limit '(portable core)
(test-equal 'vector-limit
             #t
             (raises?
        (lambda ()
          (consent-read "#(1 2 3)" '((max-vector-length . 2)))))))
(testing-registry-case
 'datum-labels-circular-identity '(portable core)
(let ((circular (consent-read "#1=(a . #1#)"))
      (shared (consent-read "(#1=(a b) #1#)"))
      (multi-pair (consent-read "#0=(1 2 3 . #0#)"))
      (multi-vector (consent-read "#0=#(1 #0#)")))
  (test-equal 'datum-labels-circular-identity
             #t
             (eq? circular (cdr circular)))
  (test-equal 'datum-labels-shared-identity
             #t
             (eq? (car shared) (cadr shared)))
  (test-equal 'datum-labels-circular-writer
             "#0=(a . #0#)"
             (consent-datum->external circular))
  (test-equal 'datum-labels-shared-simple-writer
             "((a b) (a b))"
             (consent-datum->external shared))
  (test-equal 'datum-labels-multi-pair-identity
              #t
              (eq? multi-pair (cdddr multi-pair)))
  (test-equal 'datum-labels-multi-vector-identity
              #t
              (eq? multi-vector (vector-ref multi-vector 1)))
  (test-equal 'datum-labels-multi-pair-writer
              "#0=(1 2 3 . #0#)"
              (consent-datum->external multi-pair))
  (test-equal 'datum-labels-multi-vector-writer
             "#0=#(1 #0#)"
             (consent-datum->external multi-vector))))

;; A reader-local hash table owns datum-label lookup. This wide source makes
;; every label definition and reference distinct, so an accidental return to
;; a growing association-list scan is visible in the focused scaling gate.
(define (wide-datum-label-source count)
  "Return one vector containing COUNT label definitions and references."
  (let ((output (open-output-string)))
    (display "#(" output)
    (let loop ((id 0))
      (if (< id count)
          (begin
            (if (> id 0) (display " " output))
            (display "#" output)
            (display id output)
            (display "=(" output)
            (display id output)
            (display ") #" output)
            (display id output)
            (display "#" output)
            (loop (+ id 1)))))
    (display ")" output)
    (get-output-string output)))

;; Return one vector whose first element defines a WIDTH-element target and
;; whose remaining FANOUT elements all reference that same label. A resolver
;; that recursively revisits the target performs WIDTH * FANOUT work.
(define (shared-datum-label-fanout-source width fanout)
  "Return a wide datum-label target followed by FANOUT references."
  (let ((output (open-output-string)))
    (display "#(#0=#(" output)
    (let fill-target ((index 0))
      (if (< index width)
          (begin
            (if (> index 0) (display " " output))
            (display index output)
            (fill-target (+ index 1)))))
    (display ")" output)
    (let fill-references ((remaining fanout))
      (if (> remaining 0)
          (begin
            (display " #0#" output)
            (fill-references (- remaining 1)))))
    (display ")" output)
    (get-output-string output)))

;; Return one vector containing COUNT backward label aliases and a final
;; reference to the longest chain. The resolver deliberately visits the final
;; vector slot first, so this is a real COUNT-link compression traversal.
(define (datum-label-alias-chain-source count)
  "Return a datum-label alias chain of COUNT definitions."
  (let ((output (open-output-string)))
    (display "#(#0=leaf" output)
    (let loop ((id 1))
      (if (< id count)
          (begin
            (display " #" output)
            (display id output)
            (display "=#" output)
            (display (- id 1) output)
            (display "#" output)
            (loop (+ id 1)))))
    (display " #" output)
    (display (- count 1) output)
    (display "#)" output)
    (get-output-string output)))

;; Return COUNT consecutive definitions around one empty list. Each prefix is
;; same-depth syntax and therefore must not consume one host stack frame.
(define (datum-label-definition-chain-source count)
  "Return COUNT consecutive datum-label definitions."
  (let ((output (open-output-string)))
    (let loop ((id 0))
      (if (< id count)
          (begin
            (display "#" output)
            (display id output)
            (display "=" output)
            (loop (+ id 1)))))
    (display "()" output)
    (get-output-string output)))

;; The two six-digit blocks have the same old polynomial hash at every
;; power-of-two table capacity. All 2^13 concatenations therefore formed one
;; deterministic open-address collision cluster before the digit-radix trie.
(define (adversarial-datum-label-id number)
  "Return one 13-block decimal label spelling selected by NUMBER's bits."
  (let ((output (open-output-string)))
    (let loop ((remaining number) (blocks 13))
      (if (> blocks 0)
          (begin
            (display (if (odd? remaining) "001039" "000500") output)
            (loop (quotient remaining 2) (- blocks 1)))))
    (get-output-string output)))

(define (adversarial-datum-label-source count)
  "Return COUNT distinct labels that collided in the former hash table."
  (let ((output (open-output-string)))
    (display "#(" output)
    (let loop ((id 0))
      (if (< id count)
          (begin
            (if (> id 0) (display " " output))
            (display "#" output)
            (display (adversarial-datum-label-id id) output)
            (display "=leaf" output)
            (loop (+ id 1)))))
    (display ")" output)
    (get-output-string output)))

(define (adversarial-datum-label-probe source count)
  "Parse adversarial label SOURCE and return elapsed jiffies."
  (let ((started (current-jiffy)))
    (let ((datum
           (consent-read source '((source-metadata . #f)))))
      (if (not (= (vector-length datum) count))
          (error "adversarial datum-label probe lost definitions"))
      (- (current-jiffy) started))))

;; Read SOURCE once and return elapsed jiffies after verifying that resolution
;; preserved one target identity at both ends of the fanout.
(define (datum-label-fanout-probe source width fanout)
  "Measure one shared datum-label parse and validation pass."
  (let ((started (current-jiffy)))
    (let ((datum
           (consent-read source '((source-metadata . #f)))))
      (if (or (not (= (vector-length datum) (+ fanout 1)))
              (not (= (vector-length (vector-ref datum 0)) width))
              (not (eq? (vector-ref datum 0)
                        (vector-ref datum fanout))))
          (error "datum-label fanout probe lost sharing"))
      (- (current-jiffy) started))))

(testing-registry-case
 'datum-label-table-wide '(portable core performance)
(let* ((count 4096)
       (datum (consent-read (wide-datum-label-source count))))
  (test-equal 'datum-label-table-wide-length
              (* count 2)
              (vector-length datum))
  (test-assert 'datum-label-table-wide-first-shared
               (eq? (vector-ref datum 0) (vector-ref datum 1)))
  (test-assert 'datum-label-table-wide-last-shared
               (eq? (vector-ref datum (- (* count 2) 2))
                    (vector-ref datum (- (* count 2) 1))))))

(testing-registry-case
 'datum-label-resolution-scaling '(portable core datum performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'datum-label-resolution-scaling-fast-map-required #t)
    (let* ((small-width 512)
           (small-fanout 512)
           (large-width 4096)
           (large-fanout 4096)
           (small-source
            (shared-datum-label-fanout-source
             small-width small-fanout))
           (large-source
            (shared-datum-label-fanout-source
             large-width large-fanout))
           (small
            (reader-minimum-probe-jiffies
             (lambda ()
               (datum-label-fanout-probe
                small-source small-width small-fanout))
             2))
           (large
            (reader-minimum-probe-jiffies
             (lambda ()
               (datum-label-fanout-probe
                large-source large-width large-fanout))
             2))
           (jitter (quotient (jiffies-per-second) 20)))
      (write
       (list 'datum-label-resolution-probe
             (list 'nodes-1024 small)
             (list 'nodes-8192 large)
             (list 'jiffies-per-second (jiffies-per-second))))
      (newline)
      (test-assert
       'datum-label-resolution-near-linear
       (<= large (+ (* 16 (max 1 small)) jitter))))))

(testing-registry-case
 'datum-label-radix-trie-adversarial-scaling
 '(portable core datum performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'datum-label-radix-trie-fast-map-required #t)
    (let* ((small-count 1024)
           (large-count 8192)
           (small-source
            (adversarial-datum-label-source small-count))
           (large-source
            (adversarial-datum-label-source large-count))
           (small
            (reader-minimum-probe-jiffies
             (lambda ()
               (adversarial-datum-label-probe
                small-source small-count))
             2))
           (large
            (reader-minimum-probe-jiffies
             (lambda ()
               (adversarial-datum-label-probe
                large-source large-count))
             2))
           (jitter (quotient (jiffies-per-second) 20)))
      (write
       (list 'datum-label-radix-adversarial-probe
             (list 'labels-1024 small)
             (list 'labels-8192 large)
             (list 'jiffies-per-second (jiffies-per-second))))
      (newline)
      (test-assert
       'datum-label-radix-adversarial-near-linear
       (<= large (+ (* 20 (max 1 small)) jitter))))))

(testing-registry-case
 'datum-label-long-definition-chain '(portable core datum performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'datum-label-definition-chain-fast-map-required #t)
    (let* ((count 24000)
           (datum
            (consent-read
             (datum-label-definition-chain-source count)
             (list (cons 'max-total-nodes (+ count 1))
                   (cons 'source-metadata #f)))))
      (test-assert 'datum-label-long-definition-chain-result (null? datum))
      (test-assert
       'datum-label-definition-chain-node-budget
       (raises?
        (lambda ()
          (consent-read
           (datum-label-definition-chain-source 9)
           '((max-total-nodes . 9)
             (source-metadata . #f)))))))))

(testing-registry-case
 'datum-label-long-alias-chain '(portable core datum performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'datum-label-long-alias-chain-fast-map-required #t)
    (let* ((count 24000)
           (datum
            (consent-read
             (datum-label-alias-chain-source count)
             '((source-metadata . #f)))))
      (test-equal 'datum-label-long-alias-chain-length
                  (+ count 1)
                  (vector-length datum))
      (test-assert 'datum-label-long-alias-chain-identity
                   (eq? (vector-ref datum 0)
                        (vector-ref datum count))))))

;; Explicit heap owner calls are direct borrowed-host ABI coverage. Compiled
;; Scheme-visible read and cycle behavior stays covered above and in fixtures;
;; nested native owner ABI remains tracked by #120.
(testing-registry-case
 'owned-reader-entry-points '(portable core datum boundary)
(if compiled-host-run?
    (test-assert 'owned-reader-entry-points-not-applicable #t)
    (let* ((heap (consent-make-datum-heap))
           (owned (consent-read-datum heap "#0=(a . #(#0#))"))
           (vector (consent-datum-cdr owned))
           (incremental
            (consent-read-datum-from-string-at heap "(next) tail" 0))
           (next (car incremental)))
      (test-assert 'owned-reader-pair (consent-datum-pair? owned))
      (test-assert 'owned-reader-vector (consent-datum-vector? vector))
      (test-assert 'owned-reader-cycle
                   (consent-datum-same?
                    owned
                    (consent-datum-vector-ref vector 0)))
      (test-assert 'owned-reader-source
                   (and (consent-datum-source owned)
                        (consent-datum-source vector)))
      (test-equal 'owned-reader-writer
                  "#0=(a . #1=#(#0#))"
                  (consent-datum->external owned))
      (test-assert 'owned-incremental-reader-pair
                   (consent-datum-pair? next))
      (test-equal 'owned-incremental-reader-position 6 (cdr incremental)))))

(testing-registry-case
 'owned-reader-prepared-incremental-source
 '(portable core datum boundary performance)
(if compiled-host-run?
    (test-assert 'owned-reader-prepared-source-not-applicable #t)
    (let* ((heap (consent-make-datum-heap))
           (source (consent-make-reader-source "(first) (second)"))
           (first (consent-read-datum-from-string-at heap source 0))
           (second
            (consent-read-datum-from-string-at heap source (cdr first))))
      (test-assert 'owned-reader-prepared-source-type
                   (consent-reader-source? source))
      (test-equal 'owned-reader-prepared-first "(first)"
                  (consent-datum->external (car first)))
      (test-equal 'owned-reader-prepared-second "(second)"
                  (consent-datum->external (car second)))
      (test-equal 'owned-reader-prepared-final-position
                  16
                  (cdr second)))))

;; Every source offset maps directly to a precomputed line index. N and 2N
;; multiline sources therefore require exactly N and 2N offset probes, without
;; a hidden binary search per parsed datum or per prepared incremental read.
(testing-registry-case
 'source-location-offset-index-scaling
 '(portable core datum boundary performance)
(let* ((small-count 256)
       (large-count (* small-count 2))
       (small-vector-text (multiline-reader-vector-source small-count))
       (large-vector-text (multiline-reader-vector-source large-count))
       (small-vector
        (consent-make-reader-source small-vector-text))
       (large-vector
        (consent-make-reader-source large-vector-text))
       (small-incremental
        (consent-make-reader-source
         (multiline-reader-incremental-source small-count)))
       (large-incremental
        (consent-make-reader-source
         (multiline-reader-incremental-source large-count))))
  (test-equal
   'source-location-vector-fixed-probes
   (list small-count large-count)
   (list
    (reader-source-location-probes small-vector 3 2 small-count)
    (reader-source-location-probes large-vector 3 2 large-count)))
  (test-equal
   'source-location-incremental-fixed-probes
   (list small-count large-count)
   (list
    (reader-source-location-probes small-incremental 0 4 small-count)
    (reader-source-location-probes large-incremental 0 4 large-count)))
  (if compiled-host-run?
      (test-assert 'source-location-owned-read-not-applicable #t)
      (let* ((heap (consent-make-datum-heap))
             ;; The complete read intentionally takes raw text; the incremental
             ;; loop below takes the reusable prepared-source path.
             (root (consent-read-datum heap large-vector-text))
             (first (consent-datum-vector-ref root 0))
             (last
              (consent-datum-vector-ref root (- large-count 1))))
        (test-equal 'source-location-complete-vector-length
                    large-count
                    (consent-datum-vector-length root))
        (test-equal 'source-location-complete-lines
                    (list 1 2 (+ large-count 1))
                    (list (reader-source-number-field root 'line)
                          (reader-source-number-field first 'line)
                          (reader-source-number-field last 'line)))
        (test-equal 'source-location-complete-columns
                    '(1 1 1)
                    (list (reader-source-number-field root 'column)
                          (reader-source-number-field first 'column)
                          (reader-source-number-field last 'column)))
        (let read ((position 0) (index 0) (correct-lines? #t))
          (if (= index large-count)
              (let ((eof
                     (consent-read-datum-from-string-at
                      heap large-incremental position)))
                (test-assert 'source-location-incremental-lines
                             correct-lines?)
                (test-assert 'source-location-incremental-eof
                             (consent-read-eof? (car eof)))
                (test-equal
                 'source-location-incremental-final-position
                 (* large-count 4)
                 (cdr eof)))
              (let* ((result
                      (consent-read-datum-from-string-at
                       heap large-incremental position))
                     (datum (car result)))
                (read
                 (cdr result)
                 (+ index 1)
                 (and correct-lines?
                      (= (reader-source-number-field datum 'line)
                         (+ index 1))
                      (= (reader-source-number-field datum 'column) 1))))))))))

(testing-registry-case
 'owned-reader-direct-construction
 '(portable core datum boundary performance)
(if compiled-host-run?
    (test-assert 'owned-reader-direct-construction-not-applicable #t)
    (let* ((heap (consent-make-datum-heap))
           (mutations 0)
           (metadata-before (consent-source-metadata-count))
           (before (consent-datum-cons heap 'before '())))
      (consent-datum-heap-mutation-hook-set!
       heap
       (lambda arguments
         (set! mutations (+ mutations 1))
         #t))
      (let* ((owned
              (consent-read-datum heap "(a \"b\" #(c) #u8(1))"))
             (after (consent-datum-cons heap 'after '()))
             (text (consent-datum-car (consent-datum-cdr owned)))
             (vector
              (consent-datum-car
               (consent-datum-cdr (consent-datum-cdr owned))))
             (bytes
              (consent-datum-car
               (consent-datum-cdr
                (consent-datum-cdr (consent-datum-cdr owned))))))
        (test-equal 'owned-reader-direct-object-count
                    7
                    (- (consent-datum-object-id after)
                       (consent-datum-object-id before)
                       1))
        (test-equal 'owned-reader-direct-mutation-hooks 0 mutations)
        (test-equal 'owned-reader-direct-root-revision
                    0
                    (consent-datum-object-revision owned))
        (test-equal 'owned-reader-direct-string-revision
                    0
                    (consent-datum-object-revision text))
        (test-equal 'owned-reader-direct-vector-revision
                    0
                    (consent-datum-object-revision vector))
        (test-equal 'owned-reader-direct-bytevector-revision
                    0
                    (consent-datum-object-revision bytes))
        (test-equal 'owned-reader-direct-provenance-not-global
                    metadata-before
                    (consent-source-metadata-count))))))

(testing-registry-case
 'owned-construction-capability-closes-on-error
 '(portable core datum boundary)
(if compiled-host-run?
    (test-assert 'owned-construction-capability-not-applicable #t)
    (let ((heap (consent-make-datum-heap))
          (mutations 0)
          (leaked #f))
      (consent-datum-heap-mutation-hook-set!
       heap
       (lambda arguments
         (set! mutations (+ mutations 1))
         #t))
      (test-assert
       'owned-construction-rejects-duplicate-fill
       (raises?
        (lambda ()
          (consent-call-with-datum-construction
           heap
           (lambda (make-shell fill-slot! fixup-slot!)
             (set! leaked (make-shell 'pair 2))
             (fill-slot! leaked 0 'kept)
             (fill-slot! leaked 0 'duplicate))))))
      (test-assert 'owned-construction-leaked-shell-is-valid
                   (consent-datum-pair? leaked))
      (test-equal 'owned-construction-leaked-filled-slot
                  'kept
                  (consent-datum-car leaked))
      (test-equal 'owned-construction-leaked-unfilled-slot
                  #f
                  (consent-datum-cdr leaked))
      (test-equal 'owned-construction-leaked-shell-revision
                  0
                  (consent-datum-object-revision leaked))
      (test-assert 'owned-construction-leaked-shell-sealed
                   (not (consent-datum-object-traversal leaked)))
      (test-equal 'owned-construction-error-has-no-mutation-hook
                  0
                  mutations)
      (let ((tampered #f))
        (test-assert
         'owned-construction-marker-is-not-mutable-host-data
         (raises?
          (lambda ()
            (consent-call-with-datum-construction
             heap
             (lambda (make-shell fill-slot! fixup-slot!)
               (set! tampered (make-shell 'string 1))
               (vector-set!
                (consent-datum-object-traversal tampered) 0 #f))))))
        (test-equal 'owned-construction-tamper-sanitizes-string
                    #\null
                    (consent-datum-string-ref-host tampered 0))
        (test-assert 'owned-construction-tampered-shell-sealed
                     (not (consent-datum-object-traversal tampered))))
      (let ((overwritten #f))
        (test-assert
         'owned-construction-overwritten-marker-fails-close
         (raises?
          (lambda ()
            (consent-call-with-datum-construction
             heap
             (lambda (make-shell fill-slot! fixup-slot!)
               (set! overwritten (make-shell 'pair 2))
               (fill-slot! overwritten 0 'kept)
               (consent-datum-object-traversal-set! overwritten #f))))))
        (test-equal 'owned-construction-overwrite-sanitizes-tail
                    #f
                    (consent-datum-cdr overwritten))
        (test-assert 'owned-construction-overwritten-shell-sealed
                     (not (consent-datum-object-traversal overwritten)))))))

(testing-registry-case
 'owned-vector-flat-host-elements '(portable core datum boundary performance)
(if compiled-host-run?
    (test-assert 'owned-vector-flat-host-elements-not-applicable #t)
    (let* ((heap (consent-make-datum-heap))
           (other-heap (consent-make-datum-heap))
           (mutations 0)
           (child (consent-datum-cons heap 'child '())))
      (consent-datum-heap-mutation-hook-set!
       heap
       (lambda (active-heap object operation slot old new)
         (set! mutations (+ mutations 1))
         #t))
      (let ((value
             (consent-datum-vector-from-host-elements
              heap
              (vector 'scalar child 3))))
        (test-equal 'owned-vector-flat-host-elements-length
                    3
                    (consent-datum-vector-length value))
        (test-assert 'owned-vector-flat-host-elements-identity
                     (consent-datum-same?
                      child
                      (consent-datum-vector-ref value 1)))
        (test-equal 'owned-vector-flat-host-elements-revision
                    0
                    (consent-datum-object-revision value))
        (test-equal 'owned-vector-flat-host-elements-no-mutations
                    0
                    mutations))
      (test-assert
       'owned-vector-flat-host-elements-reject-host-compound
       (raises?
        (lambda ()
          (consent-datum-vector-from-host-elements
           heap
           (vector (vector 'host))))))
      (test-assert
       'owned-vector-flat-host-elements-reject-cross-heap
       (raises?
        (lambda ()
          (consent-datum-vector-from-host-elements
           heap
           (vector (consent-datum-cons other-heap 'foreign '())))))))))

(testing-registry-case
 'owned-reader-provenance-follows-owned-lifetime
 '(portable core datum boundary performance)
(if compiled-host-run?
    (test-assert 'owned-reader-provenance-lifetime-not-applicable #t)
    (let* ((before (consent-source-metadata-count))
           (heap (consent-make-datum-heap))
           (owned (consent-read-datum heap "(a \"b\" #(c))"))
           (text (consent-datum-car (consent-datum-cdr owned)))
           (nested
            (consent-datum-car
             (consent-datum-cdr (consent-datum-cdr owned)))))
      ;; Direct construction writes each current note into its owned object
      ;; slot and never creates an entry in the legacy process-global table.
      (test-equal 'owned-reader-provenance-not-global
                  0
                  (- (consent-source-metadata-count) before))
      (test-assert 'owned-reader-root-current-source
                   (consent-datum-object-source-metadata owned))
      (test-assert 'owned-reader-string-source (consent-datum-source text))
      (test-assert 'owned-reader-vector-source (consent-datum-source nested)))))

;; A wide owned graph exercises every canonical-writer identity registry.
;; Each distinct pair appears twice, forcing shared counts, labels, and emitted
;; membership without letting process-lifetime object IDs affect table size.
(testing-registry-case
 'owned-writer-wide-shared-graph '(portable core datum performance)
(if compiled-host-run?
    (test-assert 'owned-writer-wide-shared-graph-not-applicable #t)
    (let* ((size 2048)
           (heap (consent-make-datum-heap))
           (objects (make-vector size #f))
           (root (consent-datum-make-vector heap (* size 2) #f)))
      (let fill ((index 0))
        (if (< index size)
            (let ((pair (consent-datum-cons heap #t #f)))
              (vector-set! objects index pair)
              (consent-datum-vector-set! heap root index pair)
              (consent-datum-vector-set!
               heap root (+ size index) pair)
              (fill (+ index 1)))))
      (let* ((output (consent-datum->external root 'shared))
             (digit-sum
              (let sum ((index 0) (total 0))
                (if (= index size)
                    total
                    (sum
                     (+ index 1)
                     (+ total (string-length (number->string index)))))))
             (expected-length
              (+ (* 15 size) (* 2 digit-sum) 2)))
        (test-equal
         'owned-writer-wide-shared-length
         expected-length
         (string-length output))
        (test-equal
         'owned-writer-wide-shared-prefix
         "#(#0=(#t . #f)"
         (substring output 0 14))
        (test-equal
         'owned-writer-wide-shared-suffix
         "#2047#)"
         (substring
          output
         (- (string-length output) 7)
         (string-length output)))))))

;; Hybrid graphs keep host-syntax identity separate from stable owned IDs, and
;; disjoint cycle periods retain deterministic labels in every writer mode.
(testing-registry-case
 'owned-writer-mixed-and-periodic-cycles '(portable core datum graph)
(if compiled-host-run?
    (test-assert 'owned-writer-mixed-cycles-not-applicable #t)
    (let* ((heap (consent-make-datum-heap))
           (mixed (consent-datum-make-vector heap 1 #f))
           (host (cons 'x #f))
           (root (consent-datum-make-vector heap 2 #f))
           (a (consent-datum-make-vector heap 1 #f))
           (b (consent-datum-make-vector heap 1 #f))
           (c (consent-datum-make-vector heap 1 #f))
           (d (consent-datum-make-vector heap 1 #f))
           (e (consent-datum-make-vector heap 1 #f)))
      (consent-datum-vector-set! heap mixed 0 host)
      (set-cdr! host mixed)
      (consent-datum-vector-set! heap root 0 a)
      (consent-datum-vector-set! heap root 1 c)
      (consent-datum-vector-set! heap a 0 b)
      (consent-datum-vector-set! heap b 0 a)
      (consent-datum-vector-set! heap c 0 d)
      (consent-datum-vector-set! heap d 0 e)
      (consent-datum-vector-set! heap e 0 c)
      (test-equal
       'owned-writer-mixed-write
       "#0=#(#1=(x . #0#))"
       (consent-datum->external mixed 'write))
      (test-equal
       'owned-writer-mixed-shared
       "#0=#((x . #0#))"
       (consent-datum->external mixed 'shared))
      (test-assert
       'owned-writer-mixed-simple-rejects-cycle
       (raises? (lambda () (consent-datum->external mixed 'simple))))
      (test-equal
       'owned-writer-periodic-write
       "#(#0=#(#1=#(#0#)) #2=#(#3=#(#4=#(#2#))))"
       (consent-datum->external root 'write))
      (test-equal
       'owned-writer-periodic-shared
       "#(#0=#(#(#0#)) #1=#(#(#(#1#))))"
       (consent-datum->external root 'shared)))))

;; A globally visited validator charges the shared two-pair tail and its two
;; scalar cars once. The root vector brings the exact unique-node total to 5;
;; an ancestor-only set would rewalk and recharge the tail through both edges.
(testing-registry-case
 'validation-shared-tail-count '(portable core datum graph performance)
(let* ((tail (cons 'alpha (cons 'beta '())))
       (root (vector tail tail))
       (exact-options
        '((max-depth . 8)
          (max-list-length . 8)
          (max-total-nodes . 5))))
  (test-assert 'validation-shared-tail-exact-budget
               (eq? root (consent-validate-datum root exact-options)))
  (test-assert
   'validation-shared-tail-one-node-too-small
   (raises?
    (lambda ()
      (consent-validate-datum
       root
       '((max-depth . 8)
         (max-list-length . 8)
         (max-total-nodes . 4))))))
  ;; Memoized tail spans must not weaken list-length enforcement when a
  ;; longer prefix reaches an already validated shared tail.
  (let ((prefixed (cons 'prefix tail)))
    (test-assert
     'validation-shared-tail-list-limit
     (raises?
      (lambda ()
        (consent-validate-datum
         (vector tail prefixed)
         '((max-depth . 8)
           (max-list-length . 2)
           (max-total-nodes . 16)))))))))

;; Shared compounds use their minimum weighted root distance (cdr edges cost
;; zero; car/vector edges cost one). Reordering a shallow and a deep incoming
;; edge therefore cannot change the depth-budget result.
(testing-registry-case
 'validation-shared-depth-order-independent
 '(portable core datum graph performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'validation-shared-depth-fast-map-required #t)
    (let* ((shared (vector (vector 'leaf)))
           (deep (vector shared))
           (shallow-first (vector shared deep))
           (deep-first (vector deep shared))
           (pass-options
            '((max-depth . 3)
              (max-vector-length . 4)
              (max-total-nodes . 5)))
           (fail-options
            '((max-depth . 2)
              (max-vector-length . 4)
              (max-total-nodes . 5))))
      (test-assert
       'validation-shared-depth-shallow-first-pass
       (eq? shallow-first
            (consent-validate-datum shallow-first pass-options)))
      (test-assert
       'validation-shared-depth-deep-first-pass
       (eq? deep-first
            (consent-validate-datum deep-first pass-options)))
      (test-assert
       'validation-shared-depth-shallow-first-fail
       (raises?
        (lambda ()
          (consent-validate-datum shallow-first fail-options))))
      (test-assert
       'validation-shared-depth-deep-first-fail
       (raises?
        (lambda ()
          (consent-validate-datum deep-first fail-options)))))))

;; The first occurrence of a labelled internal cdr must use dotted notation.
;; Flattening it into the enclosing list loses the pair identity and used to
;; leave a distinct self-cycle either unlabelled or nonterminating.
(testing-registry-case
 'writer-first-labelled-internal-tail '(portable core datum graph)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'writer-first-labelled-tail-fast-map-required #t)
    (let* ((tail (cons 'x #f))
           (root (cons 'prefix tail)))
      (set-cdr! tail tail)
      (test-equal
       'writer-first-labelled-internal-tail
       "(prefix . #0=(x . #0#))"
       (consent-datum->external root))
      (test-equal
       'bounded-first-labelled-internal-tail
       "(prefix x . ...)"
       (consent-datum->external-bounded root '())))))

;; Construct a nested vector chain iteratively so validation and both writers
;; are the only deep traversals under test.
(define (reader-deep-vector-chain depth)
  "Return DEPTH singleton vectors wrapped around the symbol leaf."
  (let loop ((remaining depth) (value 'leaf))
    (if (= remaining 0)
        value
        (loop (- remaining 1) (vector value)))))

(testing-registry-case
 'deep-vector-validation-and-rendering '(portable core datum performance)
(if (not (consent-identity-map-fast-backend?))
    (test-assert 'deep-vector-rendering-fast-map-required #t)
    (let* ((depth 24000)
           (root (reader-deep-vector-chain depth))
           (options
            (list (cons 'max-depth depth)
                  (cons 'max-vector-length 1)
                  (cons 'max-total-nodes (+ depth 1))))
           (validated (consent-validate-datum root options))
           (canonical (consent-datum->external validated))
           (bounded (consent-datum->external-bounded validated '())))
      (test-equal 'deep-vector-canonical-length
                  (+ (* depth 3) 4)
                  (string-length canonical))
      (test-equal 'deep-vector-canonical-prefix
                  "#("
                  (substring canonical 0 2))
      (test-equal 'deep-vector-bounded-matches
                  canonical
                  bounded))))

;; Escaping and fragment joining stream whole host strings. A long multibyte
;; value with the two escaped characters at its tail catches repeated indexed
;; access on variable-width string hosts while also checking exact round-trip.
(testing-registry-case
 'writer-long-multibyte-escape '(portable core datum performance)
(let* ((text
        (string-append
         (make-string 20000 (integer->char 955))
         "\"\\"))
       (external (consent-datum->external text)))
  (test-equal 'writer-long-multibyte-escape-length
              20006
              (string-length external))
  (test-equal 'writer-long-multibyte-escape-round-trip
              text
              (consent-read external '((source-metadata . #f))))))

;; Measure bounded rendering after owned-string allocation. The size ceiling
;; is six characters, so source length must not affect projection work.
(define (reader-bounded-owned-string-probe string rounds)
  "Measure ROUNDS bounded projections of owned STRING."
  (let ((started (current-jiffy)))
    (let loop ((remaining rounds))
      (if (> remaining 0)
          (begin
            (if (not
                 (= 6
                    (string-length
                     (consent-datum->external-bounded
                      string '((size . 6)) 'display #t))))
                (error "bounded owned-string probe returned wrong size"))
            (loop (- remaining 1)))))
    (- (current-jiffy) started)))

(testing-registry-case
 'bounded-owned-string-prefix-scaling '(portable core datum performance)
(if compiled-host-run?
    (test-assert 'bounded-owned-string-prefix-not-applicable #t)
    (let* ((heap (consent-make-datum-heap))
           (fill (integer->char 955))
           (small (consent-datum-make-string heap 32768 fill))
           (large (consent-datum-make-string heap 1048576 fill))
           (small-time
            (reader-minimum-probe-jiffies
             (lambda ()
               (reader-bounded-owned-string-probe small 16))
             2))
           (large-time
            (reader-minimum-probe-jiffies
             (lambda ()
               (reader-bounded-owned-string-probe large 16))
             2))
           (jitter (quotient (jiffies-per-second) 20)))
      (write
       (list 'bounded-owned-string-prefix-probe
             (list 'characters-32768 small-time)
             (list 'characters-1048576 large-time)
             (list 'jiffies-per-second (jiffies-per-second))))
      (newline)
      (test-equal
       'bounded-owned-string-prefix-value
       (make-string 6 fill)
       (consent-datum->external-bounded
        large '((size . 6)) 'display #t))
      (test-assert
       'bounded-owned-string-prefix-source-independent
       (<= large-time (+ (* 8 (max 1 small-time)) jitter))))))

;;;; Reader recovery: errors as data, resync, incomplete vs invalid.

;; Read one tagged field value from a tagged record list.
(define (record-field record name)
  (let ((cell (assq name (cdr record))))
    (and cell (cadr cell))))

;; Read one value from a bare field alist (such as diagnostic metadata).
(define (alist-field alist name)
  (let ((cell (assq name alist)))
    (and cell (cadr cell))))

;; Return an integer offset from a diagnostic range field.
(define (range-offset range name)
  (consent-number-value (alist-field (cdr range) name)))

;; Normalize a numeric literal across direct hosts and self-hosted runners.
(define (portable-host-number datum)
  (if (consent-number? datum)
      (consent-number-value datum)
      datum))

;; Return the (start . end) offset pair for a diagnostic's range.
(define (diagnostic-span-pair diagnostic)
  (let ((range (record-field diagnostic 'range)))
    (cons (range-offset range 'start)
          (range-offset range 'end))))

;; Return the recovery kind symbol stored in a diagnostic's metadata.
(define (diagnostic-kind diagnostic)
  (alist-field (record-field diagnostic 'metadata) 'kind))

;; The default form-level strategy recovers the good forms on either side of a
;; malformed top-level form and collects an ordered diagnostics list.
(testing-registry-case
 'recover-status-complete '(portable core)
(let ((result
       (consent-read-recover
        "(good 1)\n(broken ]\n(also ]\n(good 2)\n")))
  (test-equal 'recover-status-complete
             'complete
             (consent-recovery-result-status result))
  (test-equal 'recover-good-datums
             '("(good 1)" "(good 2)")
             (map consent-datum->external
              (consent-recovery-result-datums result)))
  (test-equal 'recover-multi-error-count
             2
             (length (consent-recovery-result-diagnostics result)))
  (test-equal 'recover-span-count
             2
             (length (consent-recovery-result-spans result)))
  (let ((diagnostic (car (consent-recovery-result-diagnostics result))))
    (test-equal 'recover-diagnostic-severity
             'error
             (record-field diagnostic 'severity))
    (test-equal 'recover-diagnostic-source
             'reader
             (record-field diagnostic 'source))
    (test-equal 'recover-diagnostic-kind
             'invalid
             (diagnostic-kind diagnostic))
    ;; The malformed top-level form runs from "(broken" to the next line.
    (test-equal 'recover-diagnostic-span
             (cons (portable-host-number 9)
                 (portable-host-number 19))
             (diagnostic-span-pair diagnostic)))
  ;; The skipped bytes are preserved in the span, never silently dropped.
  (let ((span (car (consent-recovery-result-spans result))))
    (test-equal 'recover-span-kind
             'invalid
             (record-field span 'kind))
    (test-equal 'recover-span-text-preserved
             "(broken ]\n"
             (record-field span 'text)))))

;; A recovery read returns the partial prefix even when the trailing form is an
;; incomplete (valid-prefix) region, and marks the result incomplete.
(testing-registry-case
 'recover-incomplete-status '(portable core)
(let ((result (consent-read-recover "(a 1)\n(b ")))
  (test-equal 'recover-incomplete-status
             'incomplete
             (consent-recovery-result-status result))
  (test-equal 'recover-incomplete-prefix
             '("(a 1)")
             (map consent-datum->external
              (consent-recovery-result-datums result)))
  (test-equal 'recover-incomplete-kind
             'incomplete
             (diagnostic-kind
          (car (consent-recovery-result-diagnostics result))))))

;; The resync point is caller-selectable: a strategy that jumps to end of
;; source discards everything after the first malformed form.
(testing-registry-case
 'recover-custom-resync-datums '(portable core)
(let ((result
       (consent-read-recover
        "(bad ]\n(good)\n"
        (list (cons 'resync
                    (lambda (source position)
                      (string-length source)))))))
  (test-equal 'recover-custom-resync-datums
             '()
             (consent-recovery-result-datums result))
  (test-equal 'recover-custom-resync-diagnostics
             1
             (length (consent-recovery-result-diagnostics result)))))

;; Single-form recovery distinguishes datum, invalid, incomplete, and eof, and
;; reports a resume offset for each.
(testing-registry-case
 'step-datum-status '(portable core)
(let ((datum-step (consent-read-recover-from-string-at "(a b) trailing" 0))
      (invalid-step (consent-read-recover-from-string-at ")oops\n(z)" 0))
      (incomplete-step (consent-read-recover-from-string-at "(a" 0))
      (eof-step (consent-read-recover-from-string-at "   \n" 0)))
  (test-equal 'step-datum-status
             'datum
             (consent-recovery-step-status datum-step))
  (test-equal 'step-datum-external
             "(a b)"
             (consent-datum->external (consent-recovery-step-datum
               datum-step)))
  (test-equal 'step-invalid-status
             'invalid
             (consent-recovery-step-status invalid-step))
  (test-equal 'step-invalid-progress
             #t
             (> (consent-recovery-step-next invalid-step) 0))
  (test-equal 'step-incomplete-status
             'incomplete
             (consent-recovery-step-status incomplete-step))
  ;; Incomplete input does not consume the prefix; the caller resumes at 0.
  (test-equal 'step-incomplete-rewinds
             0
             (consent-recovery-step-next incomplete-step))
  (test-equal 'step-eof-status
             'eof
             (consent-recovery-step-status eof-step))))

;; An incomplete step carries the reader's open-construct stack, innermost
;; first, so interactive callers can render nesting depth and the pending
;; construct kind; complete, invalid, and eof steps carry no stack.
(testing-registry-case
 'step-pending-nested-lists '(portable core)
(let ((nested-step (consent-read-recover-from-string-at "(+ (* 1" 0))
      (string-step (consent-read-recover-from-string-at "(display \"abc" 0))
      (vector-step (consent-read-recover-from-string-at "(a #(1" 0))
      (comment-step (consent-read-recover-from-string-at "#| a #| b" 0))
      (prefix-step (consent-read-recover-from-string-at "'" 0))
      (datum-step (consent-read-recover-from-string-at "(a b)" 0))
      (invalid-step (consent-read-recover-from-string-at ")" 0)))
  (test-equal 'step-pending-nested-lists
             '(list list)
             (consent-recovery-step-pending nested-step))
  (test-equal 'step-pending-string-innermost
             '(string list)
             (consent-recovery-step-pending string-step))
  (test-equal 'step-pending-vector-innermost
             '(vector list)
             (consent-recovery-step-pending vector-step))
  (test-equal 'step-pending-nested-block-comment
             '(comment comment)
             (consent-recovery-step-pending comment-step))
  ;; A pending datum prefix is incomplete with no construct open: the stack
  ;; is empty rather than absent.
  (test-equal 'step-pending-datum-prefix-status
             'incomplete
             (consent-recovery-step-status prefix-step))
  (test-equal 'step-pending-datum-prefix-empty
             '()
             (consent-recovery-step-pending prefix-step))
  (test-equal 'step-pending-datum-none
             #f
             (consent-recovery-step-pending datum-step))
  (test-equal 'step-pending-invalid-none
             #f
             (consent-recovery-step-pending invalid-step))))

;; Recovery spans are deterministic: two reads of the same source produce the
;; same ordered offset pairs, so cached editor diagnostics do not flicker.
(testing-registry-case
 'recover-spans-stable '(portable core)
(let ((first (consent-read-recover "(a ]\n(b }\n(c)\n"))
      (second (consent-read-recover "(a ]\n(b }\n(c)\n")))
  (test-equal 'recover-spans-stable
             (map diagnostic-span-pair
              (consent-recovery-result-diagnostics second))
             (map diagnostic-span-pair
              (consent-recovery-result-diagnostics first)))))

;; Recovery terminates on pathological input instead of looping forever.  A
;; long run of closers collapses to one skipped region; a nested run of openers
;; under the depth limit is a single incomplete prefix; and many malformed
;; lines
;; each make forward progress instead of wedging the driver.
(testing-registry-case
 'recover-pathological-closers '(portable core)
(let ((closers (consent-read-recover (make-string 500 #\))))
      (openers (consent-read-recover (make-string 50 #\()))
      (junk-lines
       (consent-read-recover
        (let loop ((n 0) (text ""))
          (if (= n 200) text (loop (+ n 1) (string-append text "]\n")))))))
  (test-equal 'recover-pathological-closers
             'complete
             (consent-recovery-result-status closers))
  (test-equal 'recover-pathological-openers
             'incomplete
             (consent-recovery-result-status openers))
  (test-equal 'recover-pathological-junk-terminates
             'complete
             (consent-recovery-result-status junk-lines))
  (test-equal 'recover-pathological-junk-progress
             #t
             (= (length (consent-recovery-result-diagnostics junk-lines))
               200))))

;; The default raise-on-error path is unchanged for existing callers.
(testing-registry-case
 'recover-default-still-raises '(portable core)
(test-equal 'recover-default-still-raises
             #t
             (raises? (lambda () (consent-read "(a")))))
(testing-registry-case
 'recover-default-read-all-raises '(portable core)
(test-equal 'recover-default-read-all-raises
             #t
             (raises? (lambda () (consent-read-all "(good) (bad ]")))))

;;;; Bounded rendering (#508): depth/length/size ceilings with the canonical
;;;; `...' truncation marker, used by the interactive REPL display path.
;;;;
;;;; This file is also run self-hosted (consent --host-run on the compiled and
;;;; gambit-native hosts), where the Consent evaluator interprets these forms.
;;;; Owned compound identity now lets the same reader and writer assertions
;;;; cover multi-element datum-label cycles in both direct and self-hosted
;;;; lanes.

;; Render SOURCE read through the reader, bounded by LIMITS, for comparison.
(define (check-bounded name source limits expected)
  (test-equal name
             expected
             (consent-datum->external-bounded (consent-read source) limits)))

;; A length ceiling shows the first L elements then the marker.
(testing-registry-case
 'bounded-length '(portable core)
(check-bounded 'bounded-length "(1 2 3 4 5 6 7 8)" '((length . 4))
  "(1 2 3 4 ...)"))
;; A depth ceiling elides the over-deep nesting with the marker.
(testing-registry-case
 'bounded-depth '(portable core)
(check-bounded 'bounded-depth "(1 (2 (3 (4 5))))" '((depth . 2))
  "(1 (2 ...))"))
;; Vectors honor the length ceiling too.
(testing-registry-case
 'bounded-vector '(portable core)
(check-bounded 'bounded-vector "#(10 20 30 40)" '((length . 2))
  "#(10 20 ...)"))
;; Bytevectors honor the length ceiling.
(testing-registry-case
 'bounded-bytevector '(portable core)
(check-bounded 'bounded-bytevector "#u8(1 2 3 4 5)" '((length . 3))
  "#u8(1 2 3 ...)"))
;; The total-size ceiling is a hard backstop that stops the walk mid-structure.
(testing-registry-case
 'bounded-size '(portable core)
(check-bounded 'bounded-size "(100 200 300 400 500)" '((size . 14))
  "(100 200 300 ..."))
;; A long string atom is pre-capped so a huge atom cannot escape the size
;; bound.
(testing-registry-case
 'bounded-size-string '(portable core)
(test-equal 'bounded-size-string
             "..."
             (consent-datum->external-bounded "abcdefghijklmnop" '((size .
               6)))))
;; Owned character atoms cross the compiled renderer boundary without host
;; conversion, just like the unbounded writer.
(testing-registry-case
 'bounded-character '(portable core)
(check-bounded 'bounded-character "#\\A" '() "#\\A"))
;; With no ceilings, bounded output equals the canonical writer for acyclic
;; data.
(testing-registry-case
 'bounded-no-limit-matches '(portable core)
(test-equal 'bounded-no-limit-matches
             (consent-datum->external (consent-read "(1 (2 3) #(4 5) \"s\")"))
             (consent-datum->external-bounded (consent-read
               "(1 (2 3) #(4 5) \"s\")") '())))

(testing-runner-main "Consent Reader portable tests" (command-line))
