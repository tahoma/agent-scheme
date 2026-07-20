;;; Portable reader test runner for the Consent Scheme R7RS library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; reader library without loading the Emacs host adapter.

(import (scheme base)
        (scheme cxr)
        (scheme write)
        (consent reader)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Shared reader behavior runs through consent-fixture-test.scm. This file
;; keeps portable reader API and bootstrap invariants close to the R7RS library.

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

;; Character writer fixtures cover named, printable, Unicode, and control forms.
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

(testing-registry-case
 'comments '(portable core)
(test-equal 'comments
             '("1" "2")
             (map consent-datum->external
            (consent-read-all
             "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))))

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
      (shared (consent-read "(#1=(a b) #1#)")))
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
             (consent-datum->external shared))))

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
             (consent-datum->external (consent-recovery-step-datum datum-step)))
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
;; under the depth limit is a single incomplete prefix; and many malformed lines
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
             (= (length (consent-recovery-result-diagnostics junk-lines)) 200))))

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
;;;; gambit-native hosts), where the consent evaluator interprets these forms.
;;;; Datum-label structures (`#0=...'/`#0#') are deliberately NOT exercised here:
;;;; the self-hosted reader does not reconstruct the shared eq?-identity a
;;;; datum-label cycle needs, so neither the canonical writer nor the bounded
;;;; renderer can resolve such a cycle self-hosted.  Cycle and shared-structure
;;;; breaking is covered on the Emacs host (consent-reader-test.el), where the
;;;; reader builds real cyclic structure; the cases below stay datum-label-free
;;;; so they pass both directly and self-hosted.

;; Render SOURCE read through the reader, bounded by LIMITS, for comparison.
(define (check-bounded name source limits expected)
  (test-equal name
             expected
             (consent-datum->external-bounded (consent-read source) limits)))

;; A length ceiling shows the first L elements then the marker.
(testing-registry-case
 'bounded-length '(portable core)
(check-bounded 'bounded-length "(1 2 3 4 5 6 7 8)" '((length . 4)) "(1 2 3 4 ...)"))
;; A depth ceiling elides the over-deep nesting with the marker.
(testing-registry-case
 'bounded-depth '(portable core)
(check-bounded 'bounded-depth "(1 (2 (3 (4 5))))" '((depth . 2)) "(1 (2 ...))"))
;; Vectors honor the length ceiling too.
(testing-registry-case
 'bounded-vector '(portable core)
(check-bounded 'bounded-vector "#(10 20 30 40)" '((length . 2)) "#(10 20 ...)"))
;; Bytevectors honor the length ceiling.
(testing-registry-case
 'bounded-bytevector '(portable core)
(check-bounded 'bounded-bytevector "#u8(1 2 3 4 5)" '((length . 3)) "#u8(1 2 3 ...)"))
;; The total-size ceiling is a hard backstop that stops the walk mid-structure.
(testing-registry-case
 'bounded-size '(portable core)
(check-bounded 'bounded-size "(100 200 300 400 500)" '((size . 14)) "(100 200 300 ..."))
;; A long string atom is pre-capped so a huge atom cannot escape the size bound.
(testing-registry-case
 'bounded-size-string '(portable core)
(test-equal 'bounded-size-string
             "..."
             (consent-datum->external-bounded "abcdefghijklmnop" '((size . 6)))))
;; With no ceilings, bounded output equals the canonical writer for acyclic data.
(testing-registry-case
 'bounded-no-limit-matches '(portable core)
(test-equal 'bounded-no-limit-matches
             (consent-datum->external (consent-read "(1 (2 3) #(4 5) \"s\")"))
             (consent-datum->external-bounded (consent-read "(1 (2 3) #(4 5) \"s\")") '())))

(testing-runner-main "Consent Reader portable tests" (command-line))
