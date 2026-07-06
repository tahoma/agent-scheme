;;; Portable reader test runner for the Consent Scheme R7RS library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; reader library without loading the Emacs host adapter.

(import (scheme base)
        (scheme write)
        (consent reader))

;; Shared reader behavior runs through consent-fixture-test.scm. This file
;; keeps portable reader API and bootstrap invariants close to the R7RS library.

(define failures 0)

;; Record one failed portable reader check and keep running the rest of the
;; suite so failures report together.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Read SOURCE through the portable reader and compare its external form.
(define (check-external name source expected)
  (check name
         (consent-datum->external (consent-read source))
         expected))

;; Return #t when THUNK raises any portable Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(check-external 'boolean-true "#true" "#t")
(check-external 'boolean-false "#false" "#f")
(check 'false-is-not-null (null? (consent-read "#f")) #f)
(check 'empty-list-is-null (null? (consent-read "()")) #t)

(check-external 'symbol-case "Consent-Scheme" "Consent-Scheme")
(check-external 'fold-case "#!fold-case Consent-Scheme" "consent-scheme")
(check-external 'vertical-symbol "|two\\x20;words|" "|two words|")

(check 'string-escapes
       (consent-read "\"line\\n\\x03bb;\"")
       (string-append "line\n" (string (integer->char #x03bb))))
(check 'string-line-continuation
       (consent-read (string-append "\"a\\" "\n  b\""))
       "ab")
(check-external 'character-name "#\\space" "#\\space")
(check-external 'character-hex "#\\X03BB" "#\\λ")

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

(for-each
 (lambda (case)
   (let* ((name (string->symbol (car case)))
          (source (cadr case))
          (expected (list-ref case 2))
          (external (consent-datum->external
                     (consent-read source))))
     (check name external expected)
     (check (string->symbol (string-append (car case) "-round-trip"))
            (consent-datum->external
             (consent-read external))
            expected)))
 character-writer-cases)

(check-external 'integer "42" "42")
;; Agent ownership means read numbers share the canonical constructors'
;; representation class. Compare against a canonical integer rather than
;; hardcoding what the surrounding Scheme's `number?' answers: on a reference
;; host both are records (#f and #f); when this file runs on the Consent
;; runtime itself via --host-run, agent-owned numbers ARE the runtime's numbers
;; (#t and #t). The invariant is the agreement, not the host's answer.
(check 'integer-is-agent-owned
       (number? (consent-read "42"))
       (number? (consent-make-canonical-integer 42)))
(check 'host-integer-writer
       (consent-datum->external 42)
       "42")
(check 'host-rational-writer
       (consent-datum->external (/ 3 2))
       "3/2")
(check 'host-decimal-writer
       (consent-datum->external 3.0)
       "3.0")
(check-external 'hex-integer "#x2a" "42")
(check-external 'rational "3/4" "3/4")
(check-external 'decimal "1.5" "1.5")
(check 'decimal-integer-external-form
       (consent-datum->external
        (consent-make-canonical-decimal 3.0))
       "3.0")
(check-external 'reduced-rational "6/10" "3/5")
(check-external 'exact-decimal "#e1.5" "3/2")
(check-external 'inexact-rational "#i3/2" "1.5")
(check-external 'complex-rectangular "3/4-5/6i" "3/4-5/6i")
(check-external 'infinity "+inf.0" "+inf.0")
(check-external 'complex-positive-infinity-imaginary "+inf.0i" "0+inf.0i")
(check-external 'complex-negative-infinity-imaginary "-inf.0i" "0-inf.0i")
(check-external 'complex-nan-imaginary "+nan.0i" "0+nan.0i")
(check-external 'polar-infinite-magnitude "+inf.0@0" "+inf.0+nan.0i")
(check-external 'polar-infinite-angle "1@+inf.0" "+nan.0+nan.0i")
(check-external 'polar-nan-magnitude "+nan.0@0" "+nan.0+nan.0i")
(check-external 'bare-i-symbol "i" "i")

(check-external 'dotted-list "(alpha beta . gamma)" "(alpha beta . gamma)")
(check-external 'quote "'alpha" "(quote alpha)")
(check-external
 'quasiquote
 "`(,alpha ,@beta)"
 "(quasiquote ((unquote alpha) (unquote-splicing beta)))")
(check-external 'vector "#(1 alpha \"ok\")" "#(1 alpha \"ok\")")
(check-external 'bytevector "#u8(0 127 255)" "#u8(0 127 255)")

(check 'comments
       (map consent-datum->external
            (consent-read-all
             "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))
       '("1" "2"))

(check 'list-limit
       (raises?
        (lambda ()
          (consent-read "(1 2 3)" '((max-list-length . 2)))))
       #t)
(check 'vector-limit
       (raises?
        (lambda ()
          (consent-read "#(1 2 3)" '((max-vector-length . 2)))))
       #t)
(let ((circular (consent-read "#1=(a . #1#)"))
      (shared (consent-read "(#1=(a b) #1#)")))
  (check 'datum-labels-circular-identity
         (eq? circular (cdr circular))
         #t)
  (check 'datum-labels-shared-identity
         (eq? (car shared) (cadr shared))
         #t)
  (check 'datum-labels-circular-writer
         (consent-datum->external circular)
         "#0=(a . #0#)")
  (check 'datum-labels-shared-simple-writer
         (consent-datum->external shared)
         "((a b) (a b))"))

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
(let ((result
       (consent-read-recover
        "(good 1)\n(broken ]\n(also ]\n(good 2)\n")))
  (check 'recover-status-complete
         (consent-recovery-result-status result)
         'complete)
  (check 'recover-good-datums
         (map consent-datum->external
              (consent-recovery-result-datums result))
         '("(good 1)" "(good 2)"))
  (check 'recover-multi-error-count
         (length (consent-recovery-result-diagnostics result))
         2)
  (check 'recover-span-count
         (length (consent-recovery-result-spans result))
         2)
  (let ((diagnostic (car (consent-recovery-result-diagnostics result))))
    (check 'recover-diagnostic-severity
           (record-field diagnostic 'severity)
           'error)
    (check 'recover-diagnostic-source
           (record-field diagnostic 'source)
           'reader)
    (check 'recover-diagnostic-kind
           (diagnostic-kind diagnostic)
           'invalid)
    ;; The malformed top-level form runs from "(broken" to the next line.
    (check 'recover-diagnostic-span
           (diagnostic-span-pair diagnostic)
           (cons (portable-host-number 9)
                 (portable-host-number 19))))
  ;; The skipped bytes are preserved in the span, never silently dropped.
  (let ((span (car (consent-recovery-result-spans result))))
    (check 'recover-span-kind
           (record-field span 'kind)
           'invalid)
    (check 'recover-span-text-preserved
           (record-field span 'text)
           "(broken ]\n")))

;; A recovery read returns the partial prefix even when the trailing form is an
;; incomplete (valid-prefix) region, and marks the result incomplete.
(let ((result (consent-read-recover "(a 1)\n(b ")))
  (check 'recover-incomplete-status
         (consent-recovery-result-status result)
         'incomplete)
  (check 'recover-incomplete-prefix
         (map consent-datum->external
              (consent-recovery-result-datums result))
         '("(a 1)"))
  (check 'recover-incomplete-kind
         (diagnostic-kind
          (car (consent-recovery-result-diagnostics result)))
         'incomplete))

;; The resync point is caller-selectable: a strategy that jumps to end of
;; source discards everything after the first malformed form.
(let ((result
       (consent-read-recover
        "(bad ]\n(good)\n"
        (list (cons 'resync
                    (lambda (source position)
                      (string-length source)))))))
  (check 'recover-custom-resync-datums
         (consent-recovery-result-datums result)
         '())
  (check 'recover-custom-resync-diagnostics
         (length (consent-recovery-result-diagnostics result))
         1))

;; Single-form recovery distinguishes datum, invalid, incomplete, and eof, and
;; reports a resume offset for each.
(let ((datum-step (consent-read-recover-from-string-at "(a b) trailing" 0))
      (invalid-step (consent-read-recover-from-string-at ")oops\n(z)" 0))
      (incomplete-step (consent-read-recover-from-string-at "(a" 0))
      (eof-step (consent-read-recover-from-string-at "   \n" 0)))
  (check 'step-datum-status
         (consent-recovery-step-status datum-step)
         'datum)
  (check 'step-datum-external
         (consent-datum->external (consent-recovery-step-datum datum-step))
         "(a b)")
  (check 'step-invalid-status
         (consent-recovery-step-status invalid-step)
         'invalid)
  (check 'step-invalid-progress
         (> (consent-recovery-step-next invalid-step) 0)
         #t)
  (check 'step-incomplete-status
         (consent-recovery-step-status incomplete-step)
         'incomplete)
  ;; Incomplete input does not consume the prefix; the caller resumes at 0.
  (check 'step-incomplete-rewinds
         (consent-recovery-step-next incomplete-step)
         0)
  (check 'step-eof-status
         (consent-recovery-step-status eof-step)
         'eof))

;; An incomplete step carries the reader's open-construct stack, innermost
;; first, so interactive callers can render nesting depth and the pending
;; construct kind; complete, invalid, and eof steps carry no stack.
(let ((nested-step (consent-read-recover-from-string-at "(+ (* 1" 0))
      (string-step (consent-read-recover-from-string-at "(display \"abc" 0))
      (vector-step (consent-read-recover-from-string-at "(a #(1" 0))
      (comment-step (consent-read-recover-from-string-at "#| a #| b" 0))
      (prefix-step (consent-read-recover-from-string-at "'" 0))
      (datum-step (consent-read-recover-from-string-at "(a b)" 0))
      (invalid-step (consent-read-recover-from-string-at ")" 0)))
  (check 'step-pending-nested-lists
         (consent-recovery-step-pending nested-step)
         '(list list))
  (check 'step-pending-string-innermost
         (consent-recovery-step-pending string-step)
         '(string list))
  (check 'step-pending-vector-innermost
         (consent-recovery-step-pending vector-step)
         '(vector list))
  (check 'step-pending-nested-block-comment
         (consent-recovery-step-pending comment-step)
         '(comment comment))
  ;; A pending datum prefix is incomplete with no construct open: the stack
  ;; is empty rather than absent.
  (check 'step-pending-datum-prefix-status
         (consent-recovery-step-status prefix-step)
         'incomplete)
  (check 'step-pending-datum-prefix-empty
         (consent-recovery-step-pending prefix-step)
         '())
  (check 'step-pending-datum-none
         (consent-recovery-step-pending datum-step)
         #f)
  (check 'step-pending-invalid-none
         (consent-recovery-step-pending invalid-step)
         #f))

;; Recovery spans are deterministic: two reads of the same source produce the
;; same ordered offset pairs, so cached editor diagnostics do not flicker.
(let ((first (consent-read-recover "(a ]\n(b }\n(c)\n"))
      (second (consent-read-recover "(a ]\n(b }\n(c)\n")))
  (check 'recover-spans-stable
         (map diagnostic-span-pair
              (consent-recovery-result-diagnostics first))
         (map diagnostic-span-pair
              (consent-recovery-result-diagnostics second))))

;; Recovery terminates on pathological input instead of looping forever.  A
;; long run of closers collapses to one skipped region; a nested run of openers
;; under the depth limit is a single incomplete prefix; and many malformed lines
;; each make forward progress instead of wedging the driver.
(let ((closers (consent-read-recover (make-string 500 #\))))
      (openers (consent-read-recover (make-string 50 #\()))
      (junk-lines
       (consent-read-recover
        (let loop ((n 0) (text ""))
          (if (= n 200) text (loop (+ n 1) (string-append text "]\n")))))))
  (check 'recover-pathological-closers
         (consent-recovery-result-status closers)
         'complete)
  (check 'recover-pathological-openers
         (consent-recovery-result-status openers)
         'incomplete)
  (check 'recover-pathological-junk-terminates
         (consent-recovery-result-status junk-lines)
         'complete)
  (check 'recover-pathological-junk-progress
         (= (length (consent-recovery-result-diagnostics junk-lines)) 200)
         #t))

;; The default raise-on-error path is unchanged for existing callers.
(check 'recover-default-still-raises
       (raises? (lambda () (consent-read "(a")))
       #t)
(check 'recover-default-read-all-raises
       (raises? (lambda () (consent-read-all "(good) (bad ]")))
       #t)

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
  (check name
         (consent-datum->external-bounded (consent-read source) limits)
         expected))

;; A length ceiling shows the first L elements then the marker.
(check-bounded 'bounded-length "(1 2 3 4 5 6 7 8)" '((length . 4)) "(1 2 3 4 ...)")
;; A depth ceiling elides the over-deep nesting with the marker.
(check-bounded 'bounded-depth "(1 (2 (3 (4 5))))" '((depth . 2)) "(1 (2 ...))")
;; Vectors honor the length ceiling too.
(check-bounded 'bounded-vector "#(10 20 30 40)" '((length . 2)) "#(10 20 ...)")
;; Bytevectors honor the length ceiling.
(check-bounded 'bounded-bytevector "#u8(1 2 3 4 5)" '((length . 3)) "#u8(1 2 3 ...)")
;; The total-size ceiling is a hard backstop that stops the walk mid-structure.
(check-bounded 'bounded-size "(100 200 300 400 500)" '((size . 14)) "(100 200 300 ...")
;; A long string atom is pre-capped so a huge atom cannot escape the size bound.
(check 'bounded-size-string
       (consent-datum->external-bounded "abcdefghijklmnop" '((size . 6)))
       "...")
;; With no ceilings, bounded output equals the canonical writer for acyclic data.
(check 'bounded-no-limit-matches
       (consent-datum->external-bounded (consent-read "(1 (2 3) #(4 5) \"s\")") '())
       (consent-datum->external (consent-read "(1 (2 3) #(4 5) \"s\")")))

(if (= failures 0)
    (begin
      (display "Scheme reader tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme reader test failure(s)")
      (newline)
      (error "Scheme reader tests failed")))
