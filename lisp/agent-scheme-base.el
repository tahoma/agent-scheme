;;; agent-scheme-base.el --- R7RS base registry and bootstrap metadata  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Primitive registry, portable prelude discovery, and primitive manifest
;; metadata for `(scheme base)'.  The registry is loadable without the evaluator
;; backend so tooling can inspect binding metadata independently.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-capability)

(defconst agent-scheme--base-source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Agent Scheme base registry source.")

(defcustom agent-scheme-base-prelude-file nil
  "Optional path to the portable `(scheme base)' prelude source file."
  :type '(choice (const :tag "Use bundled prelude" nil)
                 file)
  :group 'agent-scheme)

(defcustom agent-scheme-base-syntax-file nil
  "Optional path to the portable `(scheme base)' syntax prelude file."
  :type '(choice (const :tag "Use bundled syntax prelude" nil)
                 file)
  :group 'agent-scheme)

(defconst agent-scheme--scheme-base-library-key "(scheme base)"
  "Registry key for the required R7RS `(scheme base)' library.")

(declare-function agent-scheme--eval-define-syntax "agent-scheme-macro")
(declare-function agent-scheme--trampoline "agent-scheme-interpreter")

(defconst agent-scheme--base-primitive-registry
  '(("*" agent-scheme--primitive* 0 nil)
    ("+" agent-scheme--primitive+ 0 nil)
    ("-" agent-scheme--primitive- 1 nil)
    ("/" agent-scheme--primitive/ 1 nil)
    ("<" agent-scheme--primitive< 2 nil)
    ("<=" agent-scheme--primitive<= 2 nil)
    ("=" agent-scheme--primitive= 2 nil)
    (">" agent-scheme--primitive> 2 nil)
    (">=" agent-scheme--primitive>= 2 nil)
    ("apply" agent-scheme--primitive-apply 2 nil)
    ("binary-port?" agent-scheme--primitive-binary-port? 1 1)
    ("boolean=?" agent-scheme--primitive-boolean=? 2 nil)
    ("boolean?" agent-scheme--primitive-boolean? 1 1)
    ("bytevector" agent-scheme--primitive-bytevector 0 nil)
    ("bytevector-append" agent-scheme--primitive-bytevector-append 0 nil)
    ("bytevector-copy" agent-scheme--primitive-bytevector-copy 1 3)
    ("bytevector-copy!" agent-scheme--primitive-bytevector-copy! 3 5)
    ("bytevector-length" agent-scheme--primitive-bytevector-length 1 1)
    ("bytevector-u8-ref" agent-scheme--primitive-bytevector-u8-ref 2 2)
    ("bytevector-u8-set!" agent-scheme--primitive-bytevector-u8-set! 3 3)
    ("bytevector?" agent-scheme--primitive-bytevector? 1 1)
    ("call-with-current-continuation" agent-scheme--primitive-call/cc 1 1)
    ("call-with-port" agent-scheme--primitive-call-with-port 2 2)
    ("call-with-values" agent-scheme--primitive-call-with-values 2 2)
    ("call/cc" agent-scheme--primitive-call/cc 1 1)
    ("car" agent-scheme--primitive-car 1 1)
    ("cdr" agent-scheme--primitive-cdr 1 1)
    ("ceiling" agent-scheme--primitive-ceiling 1 1)
    ("char->integer" agent-scheme--primitive-char->integer 1 1)
    ("char<=?" agent-scheme--primitive-char<=? 2 nil)
    ("char<?" agent-scheme--primitive-char<? 2 nil)
    ("char=?" agent-scheme--primitive-char=? 2 nil)
    ("char>=?" agent-scheme--primitive-char>=? 2 nil)
    ("char>?" agent-scheme--primitive-char>? 2 nil)
    ("char-ready?" agent-scheme--primitive-char-ready? 0 1)
    ("char?" agent-scheme--primitive-char? 1 1)
    ("close-input-port" agent-scheme--primitive-close-input-port 1 1)
    ("close-output-port" agent-scheme--primitive-close-output-port 1 1)
    ("close-port" agent-scheme--primitive-close-port 1 1)
    ("complex?" agent-scheme--primitive-complex? 1 1)
    ("cons" agent-scheme--primitive-cons 2 2)
    ("dynamic-wind" agent-scheme--primitive-dynamic-wind 3 3)
    ("eq?" agent-scheme--primitive-eq? 2 2)
    ("equal?" agent-scheme--primitive-equal? 2 2)
    ("eqv?" agent-scheme--primitive-eqv? 2 2)
    ("eof-object" agent-scheme--primitive-eof-object 0 0)
    ("eof-object?" agent-scheme--primitive-eof-object? 1 1)
    ("error" agent-scheme--primitive-error 1 nil)
    ("error-object-irritants" agent-scheme--primitive-error-object-irritants 1 1)
    ("error-object-message" agent-scheme--primitive-error-object-message 1 1)
    ("error-object?" agent-scheme--primitive-error-object? 1 1)
    ("current-error-port" agent-scheme--primitive-current-error-port 0 0)
    ("current-input-port" agent-scheme--primitive-current-input-port 0 0)
    ("current-output-port" agent-scheme--primitive-current-output-port 0 0)
    ("denominator" agent-scheme--primitive-denominator 1 1)
    ("exact" agent-scheme--primitive-exact 1 1)
    ("exact-integer-sqrt" agent-scheme--primitive-exact-integer-sqrt 1 1)
    ("exact-integer?" agent-scheme--primitive-exact-integer? 1 1)
    ("exact?" agent-scheme--primitive-exact? 1 1)
    ("expt" agent-scheme--primitive-expt 2 2)
    ("features" agent-scheme--primitive-features 0 0)
    ("file-error?" agent-scheme--primitive-file-error? 1 1)
    ("flush-output-port" agent-scheme--primitive-flush-output-port 0 1)
    ("floor" agent-scheme--primitive-floor 1 1)
    ("floor/" agent-scheme--primitive-floor/ 2 2)
    ("floor-quotient" agent-scheme--primitive-floor-quotient 2 2)
    ("floor-remainder" agent-scheme--primitive-floor-remainder 2 2)
    ("gcd" agent-scheme--primitive-gcd 0 nil)
    ("get-output-bytevector" agent-scheme--primitive-get-output-bytevector 1 1)
    ("get-output-string" agent-scheme--primitive-get-output-string 1 1)
    ("inexact" agent-scheme--primitive-inexact 1 1)
    ("inexact?" agent-scheme--primitive-inexact? 1 1)
    ("input-port-open?" agent-scheme--primitive-input-port-open? 1 1)
    ("input-port?" agent-scheme--primitive-input-port? 1 1)
    ("integer->char" agent-scheme--primitive-integer->char 1 1)
    ("integer?" agent-scheme--primitive-integer? 1 1)
    ("lcm" agent-scheme--primitive-lcm 0 nil)
    ("list->string" agent-scheme--primitive-list->string 1 1)
    ("list->vector" agent-scheme--primitive-list->vector 1 1)
    ("list?" agent-scheme--primitive-list? 1 1)
    ("make-bytevector" agent-scheme--primitive-make-bytevector 1 2)
    ("make-parameter" agent-scheme--primitive-make-parameter 1 2)
    ("make-string" agent-scheme--primitive-make-string 1 2)
    ("make-vector" agent-scheme--primitive-make-vector 1 2)
    ("modulo" agent-scheme--primitive-modulo 2 2)
    ("newline" agent-scheme--primitive-newline 0 1)
    ("null?" agent-scheme--primitive-null? 1 1)
    ("number->string" agent-scheme--primitive-number->string 1 2)
    ("number?" agent-scheme--primitive-number? 1 1)
    ("open-input-bytevector" agent-scheme--primitive-open-input-bytevector 1 1)
    ("open-input-string" agent-scheme--primitive-open-input-string 1 1)
    ("open-output-bytevector" agent-scheme--primitive-open-output-bytevector 0 0)
    ("open-output-string" agent-scheme--primitive-open-output-string 0 0)
    ("output-port-open?" agent-scheme--primitive-output-port-open? 1 1)
    ("output-port?" agent-scheme--primitive-output-port? 1 1)
    ("numerator" agent-scheme--primitive-numerator 1 1)
    ("pair?" agent-scheme--primitive-pair? 1 1)
    ("peek-char" agent-scheme--primitive-peek-char 0 1)
    ("peek-u8" agent-scheme--primitive-peek-u8 0 1)
    ("port?" agent-scheme--primitive-port? 1 1)
    ("procedure?" agent-scheme--primitive-procedure? 1 1)
    ("quotient" agent-scheme--primitive-quotient 2 2)
    ("raise" agent-scheme--primitive-raise 1 1)
    ("raise-continuable" agent-scheme--primitive-raise-continuable 1 1)
    ("rational?" agent-scheme--primitive-rational? 1 1)
    ("rationalize" agent-scheme--primitive-rationalize 2 2)
    ("read-bytevector" agent-scheme--primitive-read-bytevector 1 2)
    ("read-bytevector!" agent-scheme--primitive-read-bytevector! 1 4)
    ("read-char" agent-scheme--primitive-read-char 0 1)
    ("read-error?" agent-scheme--primitive-read-error? 1 1)
    ("read-line" agent-scheme--primitive-read-line 0 1)
    ("read-string" agent-scheme--primitive-read-string 1 2)
    ("read-u8" agent-scheme--primitive-read-u8 0 1)
    ("real?" agent-scheme--primitive-real? 1 1)
    ("remainder" agent-scheme--primitive-remainder 2 2)
    ("round" agent-scheme--primitive-round 1 1)
    ("set-car!" agent-scheme--primitive-set-car! 2 2)
    ("set-cdr!" agent-scheme--primitive-set-cdr! 2 2)
    ("string" agent-scheme--primitive-string 0 nil)
    ("string->list" agent-scheme--primitive-string->list 1 3)
    ("string->number" agent-scheme--primitive-string->number 1 2)
    ("string->symbol" agent-scheme--primitive-string->symbol 1 1)
    ("string->utf8" agent-scheme--primitive-string->utf8 1 3)
    ("string->vector" agent-scheme--primitive-string->vector 1 3)
    ("string-append" agent-scheme--primitive-string-append 0 nil)
    ("string-copy" agent-scheme--primitive-string-copy 1 3)
    ("string-copy!" agent-scheme--primitive-string-copy! 3 5)
    ("string-fill!" agent-scheme--primitive-string-fill! 2 4)
    ("string-length" agent-scheme--primitive-string-length 1 1)
    ("string-ref" agent-scheme--primitive-string-ref 2 2)
    ("string-set!" agent-scheme--primitive-string-set! 3 3)
    ("string<=?" agent-scheme--primitive-string<=? 2 nil)
    ("string<?" agent-scheme--primitive-string<? 2 nil)
    ("string=?" agent-scheme--primitive-string=? 2 nil)
    ("string>=?" agent-scheme--primitive-string>=? 2 nil)
    ("string>?" agent-scheme--primitive-string>? 2 nil)
    ("string?" agent-scheme--primitive-string? 1 1)
    ("substring" agent-scheme--primitive-substring 3 3)
    ("symbol->string" agent-scheme--primitive-symbol->string 1 1)
    ("symbol=?" agent-scheme--primitive-symbol=? 2 nil)
    ("symbol?" agent-scheme--primitive-symbol? 1 1)
    ("textual-port?" agent-scheme--primitive-textual-port? 1 1)
    ("truncate" agent-scheme--primitive-truncate 1 1)
    ("truncate/" agent-scheme--primitive-truncate/ 2 2)
    ("truncate-quotient" agent-scheme--primitive-truncate-quotient 2 2)
    ("truncate-remainder" agent-scheme--primitive-truncate-remainder 2 2)
    ("u8-ready?" agent-scheme--primitive-u8-ready? 0 1)
    ("utf8->string" agent-scheme--primitive-utf8->string 1 3)
    ("vector" agent-scheme--primitive-vector 0 nil)
    ("vector->list" agent-scheme--primitive-vector->list 1 3)
    ("vector->string" agent-scheme--primitive-vector->string 1 3)
    ("vector-append" agent-scheme--primitive-vector-append 0 nil)
    ("vector-copy" agent-scheme--primitive-vector-copy 1 3)
    ("vector-copy!" agent-scheme--primitive-vector-copy! 3 5)
    ("vector-fill!" agent-scheme--primitive-vector-fill! 2 4)
    ("vector-length" agent-scheme--primitive-vector-length 1 1)
    ("vector-ref" agent-scheme--primitive-vector-ref 2 2)
    ("vector-set!" agent-scheme--primitive-vector-set! 3 3)
    ("vector?" agent-scheme--primitive-vector? 1 1)
    ("values" agent-scheme--primitive-values 0 nil)
    ("with-exception-handler" agent-scheme--primitive-with-exception-handler 2 2)
    ("write-bytevector" agent-scheme--primitive-write-bytevector 1 4)
    ("write-char" agent-scheme--primitive-write-char 1 2)
    ("write-string" agent-scheme--primitive-write-string 1 4)
    ("write-u8" agent-scheme--primitive-write-u8 1 2))
  "Registry of implemented `(scheme base)' primitive procedures.
Each entry is (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY).")

(defun agent-scheme-base-primitive-names ()
  "Return implemented `(scheme base)' primitive procedure names."
  (mapcar #'car agent-scheme--base-primitive-registry))

(defconst agent-scheme--base-primitive-documentation-table
  '(("*" . "Return the product of all numeric arguments, or 1 when called with no arguments.")
    ("+" . "Return the sum of all numeric arguments, or 0 when called with no arguments.")
    ("-" . "Return the negation of one number, or subtract each later number from the first.")
    ("/" . "Return the reciprocal of one number, or divide the first by each later number.")
    ("<" . "Return #t when the numeric arguments are strictly increasing.")
    ("<=" . "Return #t when the numeric arguments are monotonically nondecreasing.")
    ("=" . "Return #t when all numeric arguments are numerically equal.")
    (">" . "Return #t when the numeric arguments are strictly decreasing.")
    (">=" . "Return #t when the numeric arguments are monotonically nonincreasing.")
    ("apply" . "Call a procedure with leading arguments followed by the elements of the final list argument.")
    ("binary-port?" . "Return #t when an object is a binary input or output port.")
    ("boolean=?" . "Return #t when all boolean arguments have the same truth value.")
    ("boolean?" . "Return #t when an object is either #t or #f.")
    ("bytevector" . "Return a newly allocated bytevector containing the given byte values.")
    ("bytevector-append" . "Return a newly allocated bytevector containing the bytes from each argument in order.")
    ("bytevector-copy" . "Return a newly allocated copy of a bytevector slice.")
    ("bytevector-copy!" . "Copy bytes from one bytevector slice into another bytevector in place.")
    ("bytevector-length" . "Return the number of bytes in a bytevector.")
    ("bytevector-u8-ref" . "Return the byte at a zero-based bytevector index.")
    ("bytevector-u8-set!" . "Store an unsigned byte at a zero-based bytevector index.")
    ("bytevector?" . "Return #t when an object is a bytevector.")
    ("call-with-current-continuation" . "Call a procedure with the current continuation as an escape procedure.")
    ("call-with-port" . "Call a procedure with a port and close the port after the procedure returns or raises.")
    ("call-with-values" . "Call a producer and pass all produced values to a consumer.")
    ("call/cc" . "Alias for `call-with-current-continuation`.")
    ("car" . "Return the first field of a pair.")
    ("cdr" . "Return the second field of a pair.")
    ("ceiling" . "Return the least integer not less than a real number.")
    ("char->integer" . "Return a character's Unicode scalar value.")
    ("char<=?" . "Return #t when the characters are monotonically nondecreasing by scalar value.")
    ("char<?" . "Return #t when the characters are strictly increasing by scalar value.")
    ("char=?" . "Return #t when all characters have the same scalar value.")
    ("char>=?" . "Return #t when the characters are monotonically nonincreasing by scalar value.")
    ("char>?" . "Return #t when the characters are strictly decreasing by scalar value.")
    ("char-ready?" . "Return #t when a character can be read from a textual input port without blocking.")
    ("char?" . "Return #t when an object is a character.")
    ("close-input-port" . "Close an input port.")
    ("close-output-port" . "Close an output port.")
    ("close-port" . "Close an input, output, or bidirectional port.")
    ("complex?" . "Return #t when an object is a complex number.")
    ("cons" . "Return a newly allocated pair whose car and cdr are the two arguments.")
    ("dynamic-wind" . "Run before, thunk, and after procedures while preserving dynamic-wind entry and exit behavior.")
    ("eq?" . "Return #t when two objects are the same object under `eq?` identity.")
    ("equal?" . "Return #t when two objects have recursively equivalent contents.")
    ("eqv?" . "Return #t when two objects are equivalent under R7RS `eqv?` rules.")
    ("eof-object" . "Return the distinguished end-of-file object.")
    ("eof-object?" . "Return #t when an object is the distinguished end-of-file object.")
    ("error" . "Raise a non-continuable error object with a message and optional irritants.")
    ("error-object-irritants" . "Return the irritants carried by an error object.")
    ("error-object-message" . "Return the message string carried by an error object.")
    ("error-object?" . "Return #t when an object is an error object.")
    ("current-error-port" . "Return the current textual error output port.")
    ("current-input-port" . "Return the current textual input port.")
    ("current-output-port" . "Return the current textual output port.")
    ("denominator" . "Return the denominator of a rational number in lowest terms.")
    ("exact" . "Return an exact representation of a number when one is available.")
    ("exact-integer-sqrt" . "Return the exact integer square root and remainder for a nonnegative exact integer.")
    ("exact-integer?" . "Return #t when an object is both exact and an integer.")
    ("exact?" . "Return #t when a number is represented exactly.")
    ("expt" . "Return a number raised to a numeric power.")
    ("features" . "Return the implementation feature identifiers available to `cond-expand`.")
    ("file-error?" . "Return #t when an object is an error object caused by file-system access.")
    ("flush-output-port" . "Flush buffered output on an output port.")
    ("floor" . "Return the greatest integer not greater than a real number.")
    ("floor/" . "Return floor quotient and floor remainder for two integers.")
    ("floor-quotient" . "Return the floor quotient for two integers.")
    ("floor-remainder" . "Return the floor remainder for two integers.")
    ("gcd" . "Return the greatest common divisor of all integer arguments, or 0 with no arguments.")
    ("get-output-bytevector" . "Return the accumulated bytes from an output bytevector port.")
    ("get-output-string" . "Return the accumulated text from an output string port.")
    ("inexact" . "Return an inexact representation of a number.")
    ("inexact?" . "Return #t when a number is represented inexactly.")
    ("input-port-open?" . "Return #t when an input port is still open.")
    ("input-port?" . "Return #t when an object is an input port.")
    ("integer->char" . "Return the character for a Unicode scalar value.")
    ("integer?" . "Return #t when an object is an integer.")
    ("lcm" . "Return the least common multiple of all integer arguments, or 1 with no arguments.")
    ("list->string" . "Return a newly allocated string containing the characters from a list.")
    ("list->vector" . "Return a newly allocated vector containing the elements from a list.")
    ("list?" . "Return #t when an object is a proper list.")
    ("make-bytevector" . "Return a newly allocated bytevector of a given length and optional fill byte.")
    ("make-parameter" . "Return a parameter procedure with an initial value and optional converter.")
    ("make-string" . "Return a newly allocated string of a given length and optional fill character.")
    ("make-vector" . "Return a newly allocated vector of a given length and optional fill value.")
    ("modulo" . "Return the modulo remainder for two integers.")
    ("newline" . "Write a newline character to an output port.")
    ("null?" . "Return #t when an object is the empty list.")
    ("number->string" . "Return the textual representation of a number, optionally using a radix.")
    ("number?" . "Return #t when an object is a number.")
    ("open-input-bytevector" . "Return a binary input port that reads from a bytevector.")
    ("open-input-string" . "Return a textual input port that reads from a string.")
    ("open-output-bytevector" . "Return a binary output port that accumulates bytes in memory.")
    ("open-output-string" . "Return a textual output port that accumulates characters in memory.")
    ("output-port-open?" . "Return #t when an output port is still open.")
    ("output-port?" . "Return #t when an object is an output port.")
    ("numerator" . "Return the numerator of a rational number in lowest terms.")
    ("pair?" . "Return #t when an object is a pair.")
    ("peek-char" . "Return the next character from a textual input port without consuming it.")
    ("peek-u8" . "Return the next byte from a binary input port without consuming it.")
    ("port?" . "Return #t when an object is an input or output port.")
    ("procedure?" . "Return #t when an object is a callable procedure.")
    ("quotient" . "Return the truncated integer quotient for two integers.")
    ("raise" . "Raise a non-continuable exception object.")
    ("raise-continuable" . "Raise a continuable exception object.")
    ("rational?" . "Return #t when an object is a rational number.")
    ("rationalize" . "Return the simplest rational number within a tolerance of a real number.")
    ("read-bytevector" . "Read up to a requested number of bytes from a binary input port.")
    ("read-bytevector!" . "Read bytes from a binary input port into a bytevector slice.")
    ("read-char" . "Read and consume one character from a textual input port.")
    ("read-error?" . "Return #t when an object is an error object caused by reading input.")
    ("read-line" . "Read one line of text from a textual input port.")
    ("read-string" . "Read up to a requested number of characters from a textual input port.")
    ("read-u8" . "Read and consume one byte from a binary input port.")
    ("real?" . "Return #t when an object is a real number.")
    ("remainder" . "Return the truncated integer remainder for two integers.")
    ("round" . "Return the nearest integer to a real number, using the implementation's tie behavior.")
    ("set-car!" . "Replace the first field of a mutable pair.")
    ("set-cdr!" . "Replace the second field of a mutable pair.")
    ("string" . "Return a newly allocated string containing the given characters.")
    ("string->list" . "Return a list containing the characters from a string slice.")
    ("string->number" . "Parse a number from a string, optionally using a radix.")
    ("string->symbol" . "Return the symbol whose name is a string.")
    ("string->utf8" . "Encode a string slice as a UTF-8 bytevector.")
    ("string->vector" . "Return a vector containing the characters from a string slice.")
    ("string-append" . "Return a newly allocated string containing each argument's characters in order.")
    ("string-copy" . "Return a newly allocated copy of a string slice.")
    ("string-copy!" . "Copy characters from one string slice into another string in place.")
    ("string-fill!" . "Fill a string slice with a character in place.")
    ("string-length" . "Return the number of characters in a string.")
    ("string-ref" . "Return the character at a zero-based string index.")
    ("string-set!" . "Store a character at a zero-based string index.")
    ("string<=?" . "Return #t when strings are monotonically nondecreasing by character order.")
    ("string<?" . "Return #t when strings are strictly increasing by character order.")
    ("string=?" . "Return #t when all strings have the same characters.")
    ("string>=?" . "Return #t when strings are monotonically nonincreasing by character order.")
    ("string>?" . "Return #t when strings are strictly decreasing by character order.")
    ("string?" . "Return #t when an object is a string.")
    ("substring" . "Return a newly allocated string slice between start and end indexes.")
    ("symbol->string" . "Return a symbol's name as a string.")
    ("symbol=?" . "Return #t when all symbols have the same name.")
    ("symbol?" . "Return #t when an object is a symbol.")
    ("textual-port?" . "Return #t when an object is a textual input or output port.")
    ("truncate" . "Return the integer nearest to zero for a real number.")
    ("truncate/" . "Return truncated quotient and truncated remainder for two integers.")
    ("truncate-quotient" . "Return the truncated quotient for two integers.")
    ("truncate-remainder" . "Return the truncated remainder for two integers.")
    ("u8-ready?" . "Return #t when a byte can be read from a binary input port without blocking.")
    ("utf8->string" . "Decode a UTF-8 bytevector slice as a string.")
    ("vector" . "Return a newly allocated vector containing the given values.")
    ("vector->list" . "Return a list containing the elements from a vector slice.")
    ("vector->string" . "Return a string containing the characters from a vector slice.")
    ("vector-append" . "Return a newly allocated vector containing each argument's elements in order.")
    ("vector-copy" . "Return a newly allocated copy of a vector slice.")
    ("vector-copy!" . "Copy elements from one vector slice into another vector in place.")
    ("vector-fill!" . "Fill a vector slice with a value in place.")
    ("vector-length" . "Return the number of elements in a vector.")
    ("vector-ref" . "Return the element at a zero-based vector index.")
    ("vector-set!" . "Store a value at a zero-based vector index.")
    ("vector?" . "Return #t when an object is a vector.")
    ("values" . "Return all arguments as multiple values.")
    ("with-exception-handler" . "Call a thunk with an exception handler installed for its dynamic extent.")
    ("write-bytevector" . "Write bytes from a bytevector slice to a binary output port.")
    ("write-char" . "Write one character to a textual output port.")
    ("write-string" . "Write characters from a string slice to a textual output port.")
    ("write-u8" . "Write one byte to a binary output port."))
  "User-facing documentation for kernel primitive bindings.")

(defun agent-scheme--base-primitive-documentation (name)
  "Return public manifest documentation for kernel primitive NAME."
  (cdr (assoc name agent-scheme--base-primitive-documentation-table)))

(defconst agent-scheme--primitive-mutation-names
  '("bytevector-copy!" "bytevector-u8-set!" "read-bytevector!"
    "set-car!" "set-cdr!" "string-copy!" "string-fill!" "string-set!"
    "vector-copy!" "vector-fill!" "vector-set!")
  "Kernel primitive names that mutate Agent Scheme data.")

(defconst agent-scheme--primitive-port-io-names
  '("binary-port?" "call-with-port" "char-ready?" "close-input-port"
    "close-output-port" "close-port" "eof-object" "eof-object?"
    "file-error?" "flush-output-port" "get-output-bytevector"
    "get-output-string" "input-port-open?" "input-port?" "newline"
    "open-input-bytevector" "open-input-string" "open-output-bytevector"
    "open-output-string" "output-port-open?" "output-port?" "peek-char"
    "peek-u8" "port?" "read-bytevector" "read-char" "read-error?"
    "read-line" "read-string" "read-u8" "textual-port?" "u8-ready?"
    "write-bytevector" "write-char" "write-string" "write-u8")
  "Kernel primitive names that observe or mutate port state.")

(defconst agent-scheme--primitive-control-names
  '("apply" "call-with-current-continuation" "call-with-values" "call/cc"
    "dynamic-wind" "error" "raise" "raise-continuable" "values"
    "with-exception-handler")
  "Kernel primitive names that affect evaluator control flow.")

(defun agent-scheme--primitive-effect-for-name (name)
  "Return the effect tier for primitive NAME."
  (cond
   ((member name agent-scheme--primitive-mutation-names)
    'mutation)
   ((member name agent-scheme--primitive-port-io-names)
    'port-io)
   ((member name agent-scheme--primitive-control-names)
    'control)
   ((equal name "make-parameter")
    'dynamic-state)
   (t
    'pure)))

(defun agent-scheme--primitive-emitter-hook-for-effect (effect)
  "Return a lowering hint symbol for EFFECT."
  (pcase effect
    ('mutation 'runtime-mutation)
    ('port-io 'capability-port)
    ('control 'runtime-control)
    ('dynamic-state 'runtime-parameter)
    ('host-file 'capability-file)
    ('host-process 'capability-process)
    ('host-time 'capability-time)
    ('host-repl 'capability-repl)
    ('eval 'runtime-eval)
    (_ 'inline-or-call)))

(defun agent-scheme--primitive-backend-effect-path-for-effect (effect)
  "Return the shared backend execution path for EFFECT."
  (pcase effect
    ('pure 'direct-runtime)
    ('mutation 'runtime-mutation)
    ('port-io 'runtime-port-check)
    ('control 'runtime-control)
    ('dynamic-state 'runtime-parameter)
    ((or 'host-file 'host-process 'host-time 'host-repl)
     'shared-capability-request)
    (_ 'direct-runtime)))

(defun agent-scheme--primitive-test-categories-for-name (name effect)
  "Return manifest test category symbols for primitive NAME and EFFECT."
  (let (categories)
    (when (string-match-p "bytevector" name)
      (push 'bytevector categories))
    (when (string-match-p "vector" name)
      (push 'vector categories))
    (when (string-match-p "string" name)
      (push 'string categories))
    (when (string-match-p "char" name)
      (push 'character categories))
    (when (string-match-p "symbol" name)
      (push 'symbol categories))
    (when (string-match-p "boolean" name)
      (push 'boolean categories))
    (when (member name
                  '("+" "-" "*" "/" "<" "<=" "=" ">" ">=" "ceiling"
                    "complex?" "denominator" "exact" "exact-integer-sqrt"
                    "exact-integer?" "exact?" "expt" "floor" "floor/"
                    "floor-quotient" "floor-remainder" "gcd" "inexact"
                    "inexact?" "integer?" "lcm" "modulo" "number->string"
                    "number?" "numerator" "quotient" "rational?"
                    "rationalize" "real?" "remainder" "round"
                    "string->number" "truncate" "truncate/"
                    "truncate-quotient" "truncate-remainder"))
      (push 'numeric categories))
    (when (eq effect 'port-io)
      (push 'port categories))
    (when (eq effect 'control)
      (push 'control categories))
    (unless categories
      (push 'base categories))
    (nreverse categories)))

(defun agent-scheme--base-primitive-manifest-spec (entry)
  "Return manifest metadata for base primitive registry ENTRY."
  (let* ((name (nth 0 entry))
         (hook (nth 1 entry))
         (effect (agent-scheme--primitive-effect-for-name name)))
    (list :name name
          :library agent-scheme--scheme-base-library-key
          :minimum-arity (nth 2 entry)
          :maximum-arity (nth 3 entry)
          :source 'kernel
          :effect effect
          :required-capability nil
          :emacs-hook hook
          :portable-hook
          (intern (replace-regexp-in-string
                   "\\`agent-scheme--" "" (symbol-name hook)))
          :backend-effect-path
          (agent-scheme--primitive-backend-effect-path-for-effect effect)
          :emitter-hook
          (agent-scheme--primitive-emitter-hook-for-effect effect)
          :policy-category 'pure-r7rs
          :policy 'allow
          :test-categories
          (agent-scheme--primitive-test-categories-for-name name effect)
          :documentation
          (agent-scheme--primitive-manifest-documentation
           (agent-scheme--base-primitive-documentation name)))))

(defun agent-scheme-base-primitive-specs ()
  "Return discoverable metadata for implemented `(scheme base)' primitives."
  (mapcar
   (lambda (spec)
     (list :name (plist-get spec :name)
           :minimum-arity (plist-get spec :minimum-arity)
           :maximum-arity (plist-get spec :maximum-arity)
           :source (plist-get spec :source)
           :effect (plist-get spec :effect)))
   (mapcar #'agent-scheme--base-primitive-manifest-spec
           agent-scheme--base-primitive-registry)))

(defun agent-scheme--base-prelude-file ()
  "Return the portable `(scheme base)' prelude source file path."
  (or agent-scheme-base-prelude-file
      (expand-file-name
       "../scheme/agent-scheme/base-prelude.scm"
       agent-scheme--base-source-directory)))

(defun agent-scheme--base-prelude-source ()
  "Return the portable `(scheme base)' prelude source."
  (with-temp-buffer
    (insert-file-contents (agent-scheme--base-prelude-file))
    (buffer-string)))

(defun agent-scheme--base-prelude-forms ()
  "Return parsed portable prelude definition forms."
  (agent-scheme-read-all (agent-scheme--base-prelude-source)))

(defun agent-scheme--base-syntax-file ()
  "Return the portable `(scheme base)' syntax prelude source file path."
  (or agent-scheme-base-syntax-file
      (expand-file-name
       "../scheme/agent-scheme/base-syntax.scm"
       agent-scheme--base-source-directory)))

(defun agent-scheme--base-syntax-source ()
  "Return the portable `(scheme base)' syntax prelude source."
  (with-temp-buffer
    (insert-file-contents (agent-scheme--base-syntax-file))
    (buffer-string)))

(defun agent-scheme--base-syntax-forms ()
  "Return parsed portable base syntax definition forms."
  (agent-scheme-read-all (agent-scheme--base-syntax-source)))

(defun agent-scheme--formals-arity (formals)
  "Return (MINIMUM-ARITY . MAXIMUM-ARITY) for Scheme FORMALS."
  (cond
   ((agent-scheme-symbol-p formals)
    (cons 0 nil))
   (t
    (let ((cursor formals)
          (minimum 0))
      (while (consp cursor)
        (setq minimum (1+ minimum))
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor)
        (cons minimum minimum))
       ((agent-scheme-symbol-p cursor)
        (cons minimum nil))
       (t
       (agent-scheme--eval-error
        "prelude definition has invalid formals")))))))

(defun agent-scheme--base-body-definition-form-p (form)
  "Return non-nil if FORM is a definition-like body form."
  (and (consp form)
       (member (agent-scheme--symbol-name (car form))
               '("define" "define-values" "define-record-type"))))

(defun agent-scheme--base-body-documentation (body &rest maybe-formals)
  "Return documentation metadata from BODY and optional FORMALS."
  (apply
   #'agent-scheme--documentation-metadata-from-body
   body
   #'agent-scheme--base-body-definition-form-p
   maybe-formals))

(defun agent-scheme--base-documentation-properties (documentation)
  "Return plist fields for optional DOCUMENTATION metadata."
  (when documentation
    (list :documentation documentation)))

(defun agent-scheme--prelude-definition-spec (form)
  "Return metadata for one portable prelude definition FORM."
  (let ((parts (agent-scheme--proper-list-elements
                form "prelude definition")))
    (unless (and (>= (length parts) 3)
                 (agent-scheme--symbol-named-p (car parts) "define"))
      (agent-scheme--eval-error "prelude form must be one definition"))
    (let ((target (cadr parts))
          arity)
      (cond
       ((agent-scheme-symbol-p target)
        (unless (= (length parts) 3)
          (agent-scheme--eval-error
           "prelude variable definition must have one initializer"))
        (let ((initializer (caddr parts)))
          (unless (and (consp initializer)
                       (agent-scheme--symbol-named-p
                        (car initializer) "lambda"))
            (agent-scheme--eval-error
             "prelude variable definition must initialize a lambda"))
          (setq arity (agent-scheme--formals-arity (cadr initializer)))
          (append
           (list :name (agent-scheme-symbol-name target)
                 :minimum-arity (car arity)
                 :maximum-arity (cdr arity)
                 :source 'prelude)
           (agent-scheme--base-documentation-properties
            (agent-scheme--base-body-documentation
             (cddr initializer)
             (cadr initializer))))))
       ((consp target)
        (setq arity (agent-scheme--formals-arity (cdr target)))
        (append
         (list :name (agent-scheme--expect-symbol-name
                      (car target) "prelude function name")
               :minimum-arity (car arity)
               :maximum-arity (cdr arity)
               :source 'prelude)
         (agent-scheme--base-documentation-properties
          (agent-scheme--base-body-documentation
           (cddr parts)
           (cdr target)))))
       (t
        (agent-scheme--eval-error
         "prelude define target must be an identifier or function signature"))))))

(defun agent-scheme-base-prelude-binding-specs ()
  "Return discoverable metadata for portable prelude bindings."
  (mapcar #'agent-scheme--prelude-definition-spec
          (agent-scheme--base-prelude-forms)))

(defun agent-scheme-base-prelude-binding-names ()
  "Return names supplied by the portable `(scheme base)' prelude."
  (mapcar (lambda (spec) (plist-get spec :name))
          (agent-scheme-base-prelude-binding-specs)))

(defun agent-scheme-base-binding-specs ()
  "Return discoverable metadata for kernel and prelude base bindings."
  (append (agent-scheme-base-primitive-specs)
          (agent-scheme-base-prelude-binding-specs)))

(defconst agent-scheme--standard-primitive-documentation-table
  '((("(scheme file)" . "delete-file")
     . "Delete the file at PATH, subject to the file-system capability policy.")
    (("(scheme file)" . "file-exists?")
     . "Return #t when PATH names an existing file, subject to the file-system capability policy.")
    (("(scheme file)" . "call-with-input-file")
     . "Open PATH for textual input, call PROC with the port, and close the port afterward.")
    (("(scheme file)" . "call-with-output-file")
     . "Open PATH for textual output, call PROC with the port, and close the port afterward.")
    (("(scheme file)" . "open-binary-input-file")
     . "Open PATH as a binary input port, subject to the file-system capability policy.")
    (("(scheme file)" . "open-binary-output-file")
     . "Open PATH as a binary output port, subject to the file-system capability policy.")
    (("(scheme file)" . "open-input-file")
     . "Open PATH as a textual input port, subject to the file-system capability policy.")
    (("(scheme file)" . "open-output-file")
     . "Open PATH as a textual output port, subject to the file-system capability policy.")
    (("(scheme file)" . "with-input-from-file")
     . "Evaluate THUNK with the current input port temporarily bound to PATH's textual input port.")
    (("(scheme file)" . "with-output-to-file")
     . "Evaluate THUNK with the current output port temporarily bound to PATH's textual output port.")
    (("(scheme load)" . "load")
     . "Read and evaluate Scheme source from PATH, subject to the file-system capability policy.")
    (("(scheme process-context)" . "command-line")
     . "Return the process command line when process-environment access is allowed.")
    (("(scheme process-context)" . "emergency-exit")
     . "Request immediate process termination, denied by default by the process policy.")
    (("(scheme process-context)" . "exit")
     . "Request orderly process termination, denied by default by the process policy.")
    (("(scheme process-context)" . "get-environment-variable")
     . "Return one environment variable value, subject to process-environment policy.")
    (("(scheme process-context)" . "get-environment-variables")
     . "Return environment variable bindings, subject to process-environment policy.")
    (("(scheme repl)" . "interaction-environment")
     . "Return the current session interaction environment when REPL access is allowed.")
    (("(scheme time)" . "current-jiffy")
     . "Return the current clock reading as an integer jiffy count, subject to the clock capability policy.")
    (("(scheme time)" . "current-second")
     . "Return the current time as a real number of seconds since the Unix epoch, subject to the clock capability policy.")
    (("(scheme time)" . "jiffies-per-second")
     . "Return the number of jiffies per second used by `current-jiffy`."))
  "User-facing documentation for standard host-capability primitives.")

(defun agent-scheme--standard-primitive-documentation (library name)
  "Return public manifest documentation for standard binding LIBRARY NAME."
  (cdr (assoc (cons library name)
              agent-scheme--standard-primitive-documentation-table)))

(defconst agent-scheme--standard-primitive-manifest-specs
  '((:name "delete-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-delete-file
     :portable-hook primitive-delete-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "file-exists?" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-file-exists?
     :portable-hook primitive-file-exists? :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "call-with-input-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-call-with-input-file
     :portable-hook primitive-call-with-input-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "call-with-output-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-call-with-output-file
     :portable-hook primitive-call-with-output-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-binary-input-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-binary-input-file
     :portable-hook primitive-open-binary-input-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-binary-output-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-binary-output-file
     :portable-hook primitive-open-binary-output-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-input-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-input-file
     :portable-hook primitive-open-input-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-output-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-output-file
     :portable-hook primitive-open-output-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "with-input-from-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-with-input-from-file
     :portable-hook primitive-with-input-from-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "with-output-to-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-with-output-to-file
     :portable-hook primitive-with-output-to-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "load" :library "(scheme load)" :minimum-arity 1
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-load
     :portable-hook primitive-load :emitter-hook capability-file
     :policy deny :test-categories (load file policy))
    (:name "command-line" :library "(scheme process-context)" :minimum-arity 0
     :maximum-arity nil :source host-capability :effect host-process
     :required-capability process-environment :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "emergency-exit" :library "(scheme process-context)" :minimum-arity 0
     :maximum-arity nil :source host-capability :effect host-process
     :required-capability process-environment :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "exit" :library "(scheme process-context)" :minimum-arity 0
     :maximum-arity nil :source host-capability :effect host-process
     :required-capability process-environment :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "get-environment-variable" :library "(scheme process-context)"
     :minimum-arity 0 :maximum-arity nil :source host-capability
     :effect host-process :required-capability process-environment
     :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "get-environment-variables" :library "(scheme process-context)"
     :minimum-arity 0 :maximum-arity nil :source host-capability
     :effect host-process :required-capability process-environment
     :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "interaction-environment" :library "(scheme repl)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-repl
     :required-capability repl :emacs-hook agent-scheme--primitive-interaction-environment
     :portable-hook primitive-interaction-environment
     :emitter-hook capability-repl
     :policy session :test-categories (repl policy session))
    (:name "current-jiffy" :library "(scheme time)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-time
     :required-capability clock :emacs-hook agent-scheme--primitive-current-jiffy
     :portable-hook primitive-current-jiffy :emitter-hook capability-time
     :policy grant :test-categories (time policy clock))
    (:name "current-second" :library "(scheme time)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-time
     :required-capability clock :emacs-hook agent-scheme--primitive-current-second
     :portable-hook primitive-current-second :emitter-hook capability-time
     :policy grant :test-categories (time policy clock))
    (:name "jiffies-per-second" :library "(scheme time)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-time
     :required-capability clock
     :emacs-hook agent-scheme--primitive-jiffies-per-second
     :portable-hook primitive-jiffies-per-second
     :emitter-hook capability-time
     :policy grant :test-categories (time policy clock)))
  "Explicit manifest metadata for host-effecting standard primitives.")

(defun agent-scheme-standard-primitive-binding-specs ()
  "Return manifest metadata for standard-library primitive bindings."
  (mapcar
   (lambda (spec)
     (append spec
             (list :backend-effect-path 'shared-capability-request
                   :policy-category 'standard-host-effect)
             (agent-scheme--primitive-manifest-documentation-properties
              (agent-scheme--standard-primitive-documentation
               (plist-get spec :library)
               (plist-get spec :name)))))
   agent-scheme--standard-primitive-manifest-specs))

(defun agent-scheme--prelude-manifest-spec (spec)
  "Return manifest metadata for portable prelude SPEC."
  (let ((name (plist-get spec :name))
        (effect 'pure))
    (append spec
            (list :library agent-scheme--scheme-base-library-key
                  :effect effect
                  :required-capability nil
                  :emacs-hook nil
                  :portable-hook nil
                  :backend-effect-path 'direct-runtime
                  :emitter-hook 'inline-or-call
                  :policy-category 'pure-r7rs
                  :policy 'allow
                  :test-categories
                  (agent-scheme--primitive-test-categories-for-name
                   name effect)))))

(defun agent-scheme-primitive-manifest-binding-specs ()
  "Return canonical primitive and effect metadata records.
Each record is inspectable data with name, library, arity, source, effect,
capability, interpreter hooks, emitter hint, policy, and test categories."
  (append
   (mapcar #'agent-scheme--base-primitive-manifest-spec
           agent-scheme--base-primitive-registry)
   (mapcar #'agent-scheme--prelude-manifest-spec
           (agent-scheme-base-prelude-binding-specs))
   (agent-scheme-standard-primitive-binding-specs)
   (agent-scheme-emacs-capability-binding-specs)))

(defun agent-scheme--define-primitive
    (environment name function minimum-arity maximum-arity)
  "Register primitive NAME in ENVIRONMENT."
  (agent-scheme--environment-define
   environment
   name
   (agent-scheme--make-primitive-procedure
    name function minimum-arity maximum-arity)))

(defun agent-scheme-make-base-environment ()
  "Return a fresh environment with kernel and prelude `(scheme base)' bindings."
  (let ((environment (agent-scheme-make-empty-environment)))
    (dolist (entry agent-scheme--base-primitive-registry)
      (agent-scheme--define-primitive
       environment
       (nth 0 entry)
       (nth 1 entry)
       (nth 2 entry)
       (nth 3 entry)))
    ;; Derived base procedures are ordinary Scheme definitions evaluated by the
    ;; same trampoline.  This keeps the bootstrap surface inspectable.
    (agent-scheme--trampoline
     (agent-scheme--make-sequence (agent-scheme--base-prelude-forms) t)
     environment
     (agent-scheme--new-eval-context nil))
    environment))

(defun agent-scheme--ensure-base-syntax (context environment)
  "Install base derived syntax into CONTEXT once, capturing ENVIRONMENT."
  (unless (agent-scheme--eval-context-base-syntax-installed context)
    (dolist (form (agent-scheme--base-syntax-forms))
      (agent-scheme--eval-define-syntax
       form
       environment
       context
       (agent-scheme--eval-context-syntax-environment context)))
    (setf (agent-scheme--eval-context-base-syntax-installed context) t)))

(provide 'agent-scheme-base)

;;; agent-scheme-base.el ends here
