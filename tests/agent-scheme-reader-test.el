;;; agent-scheme-reader-test.el --- R7RS reader tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the Agent Scheme R7RS datum reader.

;;; Code:

(require 'ert)
(require 'agent-scheme-reader)

(defun agent-scheme-reader-test--external (source &optional options)
  "Read SOURCE and return its external representation."
  (agent-scheme-datum->external (agent-scheme-read source options)))

(ert-deftest agent-scheme-reader-test-booleans-and-empty-list-are-distinct ()
  "Read Scheme booleans without conflating false and the empty list."
  (should (eq (agent-scheme-read "#t") agent-scheme-true))
  (should (eq (agent-scheme-read "#true") agent-scheme-true))
  (should (eq (agent-scheme-read "#f") agent-scheme-false))
  (should (eq (agent-scheme-read "#false") agent-scheme-false))
  (should-not (null (agent-scheme-read "#f")))
  (should (null (agent-scheme-read "()")))
  (should (equal (agent-scheme-reader-test--external "#f") "#f"))
  (should (equal (agent-scheme-reader-test--external "()") "()")))

(ert-deftest agent-scheme-reader-test-symbols-case-and-vertical-bars ()
  "Read identifiers, vertical-bar identifiers, and case directives."
  (let ((symbol (agent-scheme-read "Agent-Scheme")))
    (should (agent-scheme-symbol-p symbol))
    (should (equal (agent-scheme-symbol-name symbol) "Agent-Scheme")))
  (should
   (equal (agent-scheme-symbol-name
           (agent-scheme-read "#!fold-case Agent-Scheme"))
          "agent-scheme"))
  (should
   (equal (agent-scheme-symbol-name
           (agent-scheme-read "|two\\x20;words|"))
          "two words"))
  (should
   (equal (agent-scheme-reader-test--external "|two words|")
          "|two words|")))

(ert-deftest agent-scheme-reader-test-strings-and-characters ()
  "Read strings and character literals with R7RS escapes."
  (should
   (equal (agent-scheme-read "\"line\\n\\x03bb;\"")
          (concat "line\n" (string #x03bb))))
  (should
   (equal (agent-scheme-read "\"a\\\n  b\"") "ab"))
  (should
   (= (agent-scheme-character-code (agent-scheme-read "#\\space")) 32))
  (should
   (= (agent-scheme-character-code (agent-scheme-read "#\\x03bb")) #x03bb))
  (should
   (= (agent-scheme-character-code (agent-scheme-read "#\\X03BB")) #x03bb))
  (should-error (agent-scheme-read "#\\Space")
                :type 'agent-scheme-reader-error)
  (should
   (= (agent-scheme-character-code
       (agent-scheme-read "#!fold-case #\\Space"))
      32)))

(ert-deftest agent-scheme-reader-test-numbers ()
  "Read representative exact, inexact, radix, and rational numbers."
  (let ((integer (agent-scheme-read "42"))
        (hex (agent-scheme-read "#x2a"))
        (rational (agent-scheme-read "3/4"))
        (decimal (agent-scheme-read "1.5")))
    (should (agent-scheme-number-p integer))
    (should (eq (agent-scheme-number-kind integer) 'integer))
    (should (= (agent-scheme-number-value integer) 42))
    (should (= (agent-scheme-number-value hex) 42))
    (should (eq (agent-scheme-number-kind rational) 'rational))
    (should (equal (agent-scheme-number-value rational) '(3 . 4)))
    (should (eq (agent-scheme-number-kind decimal) 'decimal))
    (should (= (agent-scheme-number-value decimal) 1.5)))
  (should-error (agent-scheme-read "1/0")
                :type 'agent-scheme-reader-error))

(ert-deftest agent-scheme-reader-test-numeric-tower-literals ()
  "Read normalized R7RS rational, exact decimal, and complex literals."
  (let ((reduced (agent-scheme-read "6/10"))
        (exact-decimal (agent-scheme-read "#e1.5"))
        (inexact-rational (agent-scheme-read "#i3/2"))
        (complex (agent-scheme-read "3/4-5/6i")))
    (should (eq (agent-scheme-number-kind reduced) 'rational))
    (should (equal (agent-scheme-number-value reduced) '(3 . 5)))
    (should (equal (agent-scheme-datum->external reduced) "3/5"))
    (should (eq (agent-scheme-number-exactness exact-decimal) 'exact))
    (should (equal (agent-scheme-datum->external exact-decimal) "3/2"))
    (should (eq (agent-scheme-number-exactness inexact-rational) 'inexact))
    (should (equal (agent-scheme-datum->external inexact-rational) "1.5"))
    (should (eq (agent-scheme-number-kind complex) 'complex))
    (should (equal (agent-scheme-datum->external complex) "3/4-5/6i"))))

(ert-deftest agent-scheme-reader-test-lists-vectors-bytevectors-and-abbreviations ()
  "Read compound datum forms."
  (should
   (equal (agent-scheme-reader-test--external "(alpha beta . gamma)")
          "(alpha beta . gamma)"))
  (should
   (equal (agent-scheme-reader-test--external "'alpha")
          "(quote alpha)"))
  (should
   (equal (agent-scheme-reader-test--external "`(,alpha ,@beta)")
          "(quasiquote ((unquote alpha) (unquote-splicing beta)))"))
  (should
   (equal (agent-scheme-reader-test--external "#(1 alpha \"ok\")")
          "#(1 alpha \"ok\")"))
  (let ((bytevector (agent-scheme-read "#u8(0 127 255)")))
    (should (agent-scheme-bytevector-p bytevector))
    (should (equal (append (agent-scheme-bytevector-bytes bytevector) nil)
                   '(0 127 255)))
    (should (equal (agent-scheme-datum->external bytevector)
                   "#u8(0 127 255)")))
  (should-error (agent-scheme-read "#u8(256)")
                :type 'agent-scheme-reader-error)
  (should-error (agent-scheme-read "#u8(1 . 2)")
                :type 'agent-scheme-reader-error))

(ert-deftest agent-scheme-reader-test-comments-and-read-all ()
  "Skip line, block, datum comments, and read multiple datums."
  (should
   (equal (mapcar #'agent-scheme-datum->external
                  (agent-scheme-read-all
                   "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))
          '("1" "2")))
  (should
   (equal (mapcar #'agent-scheme-datum->external
                  (agent-scheme-read-all
                   "#!fold-case FOO #!no-fold-case BAR"))
          '("foo" "BAR"))))

(ert-deftest agent-scheme-reader-test-resource-limits ()
  "Reject datums that exceed configured validator limits."
  (should-error (agent-scheme-read "(((x)))" '(:max-depth 2))
                :type 'agent-scheme-datum-limit-error)
  (should-error (agent-scheme-read "(1 2 3)" '(:max-list-length 2))
                :type 'agent-scheme-datum-limit-error)
  (should-error (agent-scheme-read "\"abc\"" '(:max-string-size 2))
                :type 'agent-scheme-datum-limit-error)
  (should-error (agent-scheme-read "#(1 2 3)" '(:max-vector-length 2))
                :type 'agent-scheme-datum-limit-error)
  (should-error (agent-scheme-read "#u8(1 2 3)" '(:max-bytevector-length 2))
                :type 'agent-scheme-datum-limit-error))

(ert-deftest agent-scheme-reader-test-friendly-syntax-errors ()
  "Reject malformed syntax with reader errors."
  (should-error (agent-scheme-read "(1 . 2 3)")
                :type 'agent-scheme-reader-error)
  (should-error (agent-scheme-read "(1 2")
                :type 'agent-scheme-reader-error)
  (should-error (agent-scheme-read "#1=(a . #1#)")
                :type 'agent-scheme-reader-error)
  (should-error (agent-scheme-read "1 2")
                :type 'agent-scheme-reader-error)
  (should-error (agent-scheme-validate-datum (current-buffer))
                :type 'agent-scheme-reader-error))

;;; agent-scheme-reader-test.el ends here
