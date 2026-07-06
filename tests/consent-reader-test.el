;;; consent-reader-test.el --- R7RS reader tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the Emacs Lisp reader implementation. Shared external
;; reader behavior runs through the canonical fixture corpus; these tests keep
;; host-side object identity, writer round trips, limit errors, and low-level
;; reader diagnostics close to the implementation.

;;; Code:

(require 'ert)
(require 'consent-reader)

(defun consent-reader-test--external (source &optional options)
  "Read SOURCE and return its external representation."
  (consent-datum->external (consent-read source options)))

(ert-deftest consent-reader-test-booleans-and-empty-list-are-distinct ()
  "Read Scheme booleans without conflating false and the empty list."
  (should (eq (consent-read "#t") consent-true))
  (should (eq (consent-read "#true") consent-true))
  (should (eq (consent-read "#f") consent-false))
  (should (eq (consent-read "#false") consent-false))
  (should-not (null (consent-read "#f")))
  (should (null (consent-read "()")))
  (should (equal (consent-reader-test--external "#f") "#f"))
  (should (equal (consent-reader-test--external "()") "()")))

(ert-deftest consent-reader-test-symbols-case-and-vertical-bars ()
  "Read identifiers, vertical-bar identifiers, and case directives."
  (let ((symbol (consent-read "Consent-Scheme")))
    (should (consent-symbol-p symbol))
    (should (equal (consent-symbol-name symbol) "Consent-Scheme")))
  (should
   (equal (consent-symbol-name
           (consent-read "#!fold-case Consent-Scheme"))
          "consent-scheme"))
  (should
   (equal (consent-symbol-name
           (consent-read "|two\\x20;words|"))
          "two words"))
  (should
   (equal (consent-reader-test--external "|two words|")
          "|two words|")))

(ert-deftest consent-reader-test-strings-and-characters ()
  "Read strings and character literals with R7RS escapes."
  (should
   (equal (consent-read "\"line\\n\\x03bb;\"")
          (concat "line\n" (string #x03bb))))
  (should
   (equal (consent-read "\"a\\\n  b\"") "ab"))
  (should
   (= (consent-character-code (consent-read "#\\space")) 32))
  (should
   (= (consent-character-code (consent-read "#\\x03bb")) #x03bb))
  (should
   (= (consent-character-code (consent-read "#\\X03BB")) #x03bb))
  (should-error (consent-read "#\\Space")
                :type 'consent-reader-error)
  (should
   (= (consent-character-code
       (consent-read "#!fold-case #\\Space"))
      32))
  ;; Delimiter and reserved characters are valid single-character literals: the
  ;; reader must take the character after #\ literally even when it is ( ) [ ] |.
  (should (= (consent-character-code (consent-read "#\\(")) 40))
  (should (= (consent-character-code (consent-read "#\\)")) 41))
  (should (= (consent-character-code (consent-read "#\\[")) 91))
  (should (= (consent-character-code (consent-read "#\\]")) 93))
  (should (= (consent-character-code (consent-read "#\\|")) 124)))

(ert-deftest consent-reader-test-character-writer-canonical-forms ()
  "Write named, printable, Unicode, and control character forms."
  (dolist (case '(("#\\space" . "#\\space")
                  ("#\\tab" . "#\\tab")
                  ("#\\alarm" . "#\\alarm")
                  ("#\\backspace" . "#\\backspace")
                  ("#\\delete" . "#\\delete")
                  ("#\\escape" . "#\\escape")
                  ("#\\newline" . "#\\newline")
                  ("#\\null" . "#\\null")
                  ("#\\return" . "#\\return")
                  ("#\\a" . "#\\a")
                  ("#\\x03bb" . "#\\λ")
                  ("#\\x1" . "#\\x1")
                  ("#\\x1f" . "#\\x1f")
                  ("#\\x7f" . "#\\delete")))
    (let* ((source (car case))
           (expected (cdr case))
           (external (consent-reader-test--external source)))
      (should (equal external expected))
      (should (equal (consent-reader-test--external external)
                     expected)))))

(ert-deftest consent-reader-test-numbers ()
  "Read representative exact, inexact, radix, and rational numbers."
  (let ((integer (consent-read "42"))
        (hex (consent-read "#x2a"))
        (rational (consent-read "3/4"))
        (decimal (consent-read "1.5")))
    (should (consent-number-p integer))
    (should (eq (consent-number-kind integer) 'integer))
    (should (= (consent-number-value integer) 42))
    (should (= (consent-number-value hex) 42))
    (should (eq (consent-number-kind rational) 'rational))
    (should (equal (consent-number-value rational) '(3 . 4)))
    (should (eq (consent-number-kind decimal) 'decimal))
    (should (= (consent-number-value decimal) 1.5)))
  (should
   (equal
    (consent-datum->external
     (consent--make-canonical-decimal 3.0))
    "3.0"))
  (should (equal (consent-datum->external 42) "42"))
  (should (equal (consent-datum->external 1.5) "1.5"))
  (should (equal (consent-datum->external 3.0) "3.0"))
  (should-error (consent-read "1/0")
                :type 'consent-reader-error))

(ert-deftest consent-reader-test-numeric-tower-literals ()
  "Read normalized R7RS rational, exact decimal, and complex literals."
  (let ((reduced (consent-read "6/10"))
        (exact-decimal (consent-read "#e1.5"))
        (inexact-rational (consent-read "#i3/2"))
        (complex (consent-read "3/4-5/6i")))
    (should (eq (consent-number-kind reduced) 'rational))
    (should (equal (consent-number-value reduced) '(3 . 5)))
    (should (equal (consent-datum->external reduced) "3/5"))
    (should (eq (consent-number-exactness exact-decimal) 'exact))
    (should (equal (consent-datum->external exact-decimal) "3/2"))
    (should (eq (consent-number-exactness inexact-rational) 'inexact))
    (should (equal (consent-datum->external inexact-rational) "1.5"))
    (should (eq (consent-number-kind complex) 'complex))
    (should (equal (consent-datum->external complex) "3/4-5/6i"))))

(ert-deftest consent-reader-test-inexact-complex-special-values ()
  "Read inexact special values in complex external forms canonically."
  (should (equal (consent-reader-test--external "+inf.0i")
                 "0+inf.0i"))
  (should (equal (consent-reader-test--external "-inf.0i")
                 "0-inf.0i"))
  (should (equal (consent-reader-test--external "+nan.0i")
                 "0+nan.0i"))
  (should (equal (consent-reader-test--external "+inf.0@0")
                 "+inf.0+nan.0i"))
  (should (equal (consent-reader-test--external "1@+inf.0")
                 "+nan.0+nan.0i"))
  (should (equal (consent-reader-test--external "+nan.0@0")
                 "+nan.0+nan.0i")))

(ert-deftest consent-reader-test-lists-vectors-bytevectors-and-abbreviations ()
  "Read compound datum forms."
  (should
   (equal (consent-reader-test--external "(alpha beta . gamma)")
          "(alpha beta . gamma)"))
  (should
   (equal (consent-reader-test--external "'alpha")
          "(quote alpha)"))
  (should
   (equal (consent-reader-test--external "`(,alpha ,@beta)")
          "(quasiquote ((unquote alpha) (unquote-splicing beta)))"))
  (should
   (equal (consent-reader-test--external "#(1 alpha \"ok\")")
          "#(1 alpha \"ok\")"))
  (let ((bytevector (consent-read "#u8(0 127 255)")))
    (should (consent-bytevector-p bytevector))
    (should (equal (append (consent-bytevector-bytes bytevector) nil)
                   '(0 127 255)))
    (should (equal (consent-datum->external bytevector)
                   "#u8(0 127 255)")))
  (should-error (consent-read "#u8(256)")
                :type 'consent-reader-error)
  (should-error (consent-read "#u8(1 . 2)")
                :type 'consent-reader-error))

(ert-deftest consent-reader-test-datum-labels-preserve-identity ()
  "Read R7RS datum labels as shared and circular structure."
  (let ((circular (consent-read "#1=(a . #1#)"))
        (shared (consent-read "(#1=(a b) #1#)")))
    (should (eq circular (cdr circular)))
    (should (eq (car shared) (cadr shared)))
    (should (equal (consent-datum->external circular)
                   "#0=(a . #0#)"))
    (should (equal (consent-datum->external shared)
                   "((a b) (a b))"))))

(defun consent-reader-test--bounded (source limits)
  "Read SOURCE and return its external representation bounded by LIMITS."
  (consent-datum->external-bounded (consent-read source) limits))

(ert-deftest consent-reader-test-bounded-rendering ()
  "Bound rendering by depth/length/size with the `...' truncation marker (#508).
These mirror the portable reader tests so both cores render identically."
  ;; A length ceiling shows the first L elements then the marker.
  (should (equal (consent-reader-test--bounded "(1 2 3 4 5 6 7 8)" '((length . 4)))
                 "(1 2 3 4 ...)"))
  ;; A depth ceiling elides over-deep nesting with the marker.
  (should (equal (consent-reader-test--bounded "(1 (2 (3 (4 5))))" '((depth . 2)))
                 "(1 (2 ...))"))
  ;; Vectors and bytevectors honor the length ceiling.
  (should (equal (consent-reader-test--bounded "#(10 20 30 40)" '((length . 2)))
                 "#(10 20 ...)"))
  (should (equal (consent-reader-test--bounded "#u8(1 2 3 4 5)" '((length . 3)))
                 "#u8(1 2 3 ...)"))
  ;; The total-size ceiling is a hard backstop that stops mid-structure.
  (should (equal (consent-reader-test--bounded "(100 200 300 400 500)" '((size . 14)))
                 "(100 200 300 ..."))
  ;; A long string atom is pre-capped so a huge atom cannot escape the bound.
  (should (equal (consent-datum->external-bounded "abcdefghijklmnop" '((size . 6)))
                 "...")))

(ert-deftest consent-reader-test-bounded-rendering-breaks-cycles ()
  "Always terminate on shared and circular structure, regardless of LIMITS (#508)."
  ;; A real datum-label cycle terminates: the back-edge renders as the marker.
  (should (equal (consent-reader-test--bounded "#0=(1 2 3 . #0#)" '((depth . 8)))
                 "(1 2 3 . ...)"))
  ;; A cycle cut by the length ceiling before the back-edge also terminates.
  (should (equal (consent-reader-test--bounded "#0=(1 2 3 . #0#)" '((length . 2)))
                 "(1 2 ...)"))
  ;; A self-referential vector terminates via the ancestor check.
  (should (equal (consent-reader-test--bounded "#0=#(1 #0#)" '((depth . 8)))
                 "#(1 ...)"))
  ;; The ancestor check guarantees termination even with no ceilings at all.
  (should (equal (consent-reader-test--bounded "#0=(1 . #0#)" '())
                 "(1 . ...)"))
  ;; Shared (non-cyclic) structure renders in full when within the ceilings.
  (should (equal (consent-reader-test--bounded "(#0=(a b) #0#)" '())
                 "((a b) (a b))"))
  ;; With no ceilings, bounded output equals the canonical writer for acyclic data.
  (should (equal (consent-datum->external-bounded
                  (consent-read "(1 (2 3) #(4 5) \"s\")") '())
                 (consent-datum->external (consent-read "(1 (2 3) #(4 5) \"s\")")))))

(ert-deftest consent-reader-test-comments-and-read-all ()
  "Skip line, block, datum comments, and read multiple datums."
  (should
   (equal (mapcar #'consent-datum->external
                  (consent-read-all
                   "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))
          '("1" "2")))
  (should
   (equal (mapcar #'consent-datum->external
                  (consent-read-all
                   "#!fold-case FOO #!no-fold-case BAR"))
          '("foo" "BAR"))))

(ert-deftest consent-reader-test-resource-limits ()
  "Reject datums that exceed configured validator limits."
  (should-error (consent-read "(((x)))" '(:max-depth 2))
                :type 'consent-datum-limit-error)
  (should-error (consent-read "(1 2 3)" '(:max-list-length 2))
                :type 'consent-datum-limit-error)
  (should-error (consent-read "\"abc\"" '(:max-string-size 2))
                :type 'consent-datum-limit-error)
  (should-error (consent-read "#(1 2 3)" '(:max-vector-length 2))
                :type 'consent-datum-limit-error)
  (should-error (consent-read "#u8(1 2 3)" '(:max-bytevector-length 2))
                :type 'consent-datum-limit-error))

(ert-deftest consent-reader-test-friendly-syntax-errors ()
  "Reject malformed syntax with reader errors."
  (should-error (consent-read "(1 . 2 3)")
                :type 'consent-reader-error)
  (should-error (consent-read "(1 2")
                :type 'consent-reader-error)
  (should-error (consent-read "#1#")
                :type 'consent-reader-error)
  (should-error (consent-read "1 2")
                :type 'consent-reader-error)
  (should-error (consent-validate-datum (current-buffer))
                :type 'consent-reader-error))

;;;; Reader recovery: errors as data, resync, incomplete vs invalid.

(defun consent-reader-test--field-in (fields name)
  "Return the value of the field named NAME in FIELDS, or nil."
  (catch 'found
    (dolist (field fields)
      (when (and (consp field)
                 (consent-symbol-p (car field))
                 (equal (consent-symbol-name (car field)) name))
        (throw 'found (cadr field))))
    nil))

(defun consent-reader-test--field (record name)
  "Return the value of the tagged RECORD's field named NAME."
  (consent-reader-test--field-in (cdr record) name))

(defun consent-reader-test--range-offset (range name)
  "Return integer offset NAME from a diagnostic RANGE."
  (consent-number-value (consent-reader-test--field range name)))

(defun consent-reader-test--span-pair (diagnostic)
  "Return the (START . END) offsets of DIAGNOSTIC's range."
  (let ((range (consent-reader-test--field diagnostic "range")))
    (cons (consent-reader-test--range-offset range "start")
          (consent-reader-test--range-offset range "end"))))

(defun consent-reader-test--kind (diagnostic)
  "Return the recovery kind name stored in DIAGNOSTIC's metadata."
  (let ((metadata (consent-reader-test--field diagnostic "metadata")))
    (consent-symbol-name
     (consent-reader-test--field-in metadata "kind"))))

(ert-deftest consent-reader-test-recovery-collects-errors-as-data ()
  "Recover the good forms around malformed ones and collect diagnostics."
  (let* ((result
          (consent-read-recover "(good 1)\n(broken ]\n(also ]\n(good 2)\n"))
         (diagnostics (consent-recovery-result-diagnostics result))
         (spans (consent-recovery-result-spans result)))
    (should (eq (consent-recovery-result-status result) 'complete))
    (should (equal (mapcar #'consent-datum->external
                           (consent-recovery-result-datums result))
                   '("(good 1)" "(good 2)")))
    (should (= (length diagnostics) 2))
    (should (= (length spans) 2))
    (let ((diagnostic (car diagnostics)))
      (should (equal (consent-symbol-name
                      (consent-reader-test--field diagnostic "severity"))
                     "error"))
      (should (equal (consent-symbol-name
                      (consent-reader-test--field diagnostic "source"))
                     "reader"))
      (should (equal (consent-reader-test--kind diagnostic) "invalid"))
      (should (equal (consent-reader-test--span-pair diagnostic) '(9 . 19))))
    (let ((span (car spans)))
      (should (equal (consent-symbol-name
                      (consent-reader-test--field span "kind"))
                     "invalid"))
      ;; The skipped bytes are preserved in the span, never silently dropped.
      (should (equal (consent-reader-test--field span "text") "(broken ]\n")))))

(ert-deftest consent-reader-test-recovery-incomplete-vs-invalid ()
  "Surface an incomplete trailing prefix distinctly from a syntax error."
  (let ((result (consent-read-recover "(a 1)\n(b ")))
    (should (eq (consent-recovery-result-status result) 'incomplete))
    (should (equal (mapcar #'consent-datum->external
                           (consent-recovery-result-datums result))
                   '("(a 1)")))
    (should (equal (consent-reader-test--kind
                    (car (consent-recovery-result-diagnostics result)))
                   "incomplete"))))

(ert-deftest consent-reader-test-recovery-resync-is-pluggable ()
  "Honor a caller-supplied resync strategy."
  (let ((result
         (consent-read-recover
          "(bad ]\n(good)\n"
          (list :resync (lambda (source _position) (length source))))))
    (should (null (consent-recovery-result-datums result)))
    (should (= (length (consent-recovery-result-diagnostics result)) 1))))

(ert-deftest consent-reader-test-recovery-single-form-steps ()
  "Classify single-form recovery reads as datum, invalid, incomplete, or eof."
  (let ((datum-step (consent-read-recover-from-string-at "(a b) trailing" 0))
        (invalid-step (consent-read-recover-from-string-at ")oops\n(z)" 0))
        (incomplete-step (consent-read-recover-from-string-at "(a" 0))
        (eof-step (consent-read-recover-from-string-at "   \n" 0)))
    (should (eq (consent-recovery-step-status datum-step) 'datum))
    (should (equal (consent-datum->external
                    (consent-recovery-step-datum datum-step))
                   "(a b)"))
    (should (eq (consent-recovery-step-status invalid-step) 'invalid))
    (should (> (consent-recovery-step-next invalid-step) 0))
    (should (eq (consent-recovery-step-status incomplete-step) 'incomplete))
    ;; Incomplete input does not consume the prefix; the caller resumes at 0.
    (should (= (consent-recovery-step-next incomplete-step) 0))
    (should (eq (consent-recovery-step-status eof-step) 'eof))))

(ert-deftest consent-reader-test-recovery-step-pending-stack ()
  "Carry the open-construct stack, innermost first, on incomplete steps.
Interactive callers render nesting depth and the pending construct kind from
it; complete, invalid, and eof steps carry no stack."
  (should (equal (consent-recovery-step-pending
                  (consent-read-recover-from-string-at "(+ (* 1" 0))
                 '(list list)))
  (should (equal (consent-recovery-step-pending
                  (consent-read-recover-from-string-at "(display \"abc" 0))
                 '(string list)))
  (should (equal (consent-recovery-step-pending
                  (consent-read-recover-from-string-at "(a #(1" 0))
                 '(vector list)))
  (should (equal (consent-recovery-step-pending
                  (consent-read-recover-from-string-at "#| a #| b" 0))
                 '(comment comment)))
  ;; A pending datum prefix is incomplete with no construct open: the stack
  ;; is empty.
  (let ((prefix-step (consent-read-recover-from-string-at "'" 0)))
    (should (eq (consent-recovery-step-status prefix-step) 'incomplete))
    (should (null (consent-recovery-step-pending prefix-step))))
  (should-not (consent-recovery-step-pending
               (consent-read-recover-from-string-at "(a b)" 0)))
  (should-not (consent-recovery-step-pending
               (consent-read-recover-from-string-at ")" 0))))

(ert-deftest consent-reader-test-recovery-spans-are-deterministic ()
  "Produce identical ordered spans across repeated reads."
  (let ((first (consent-read-recover "(a ]\n(b }\n(c)\n"))
        (second (consent-read-recover "(a ]\n(b }\n(c)\n")))
    (should (equal (mapcar #'consent-reader-test--span-pair
                           (consent-recovery-result-diagnostics first))
                   (mapcar #'consent-reader-test--span-pair
                           (consent-recovery-result-diagnostics second))))))

(ert-deftest consent-reader-test-recovery-terminates-on-pathological-input ()
  "Guarantee termination and forward progress on adversarial input."
  (should (eq (consent-recovery-result-status
               (consent-read-recover (make-string 500 ?\))))
              'complete))
  (should (eq (consent-recovery-result-status
               (consent-read-recover (make-string 50 ?\()))
              'incomplete))
  (let ((result
         (consent-read-recover
          (mapconcat #'identity (make-list 200 "]") "\n"))))
    (should (eq (consent-recovery-result-status result) 'complete))
    (should (= (length (consent-recovery-result-diagnostics result)) 200))))

(ert-deftest consent-reader-test-recovery-default-path-unchanged ()
  "Keep the default raise-on-error behavior for existing callers."
  (should-error (consent-read "(a") :type 'consent-reader-error)
  (should-error (consent-read-all "(good) (bad ]") :type 'consent-reader-error))

;;; consent-reader-test.el ends here
