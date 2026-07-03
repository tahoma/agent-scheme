;;; Portable Consent Scheme base-library registry and bootstrap metadata.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns `(scheme base)' primitive metadata, prelude discovery, and
;;; base-environment construction hooks without importing the evaluator module.

(define-library (consent base)
  (export scheme-base-library-key
          consent-install-base-backend!
          base-primitive-registry
          base-prelude-forms
          base-syntax-forms
          consent-base-prelude-load-paths
          consent-base-syntax-load-paths
          read-port-string
          read-all-datums
          resolve-source-text
          resolve-source-entry
          define-primitive!
          ensure-base-syntax!
          consent-make-base-environment
          consent-base-primitive-names
          consent-base-primitive-specs
          consent-base-prelude-binding-names
          consent-base-prelude-binding-specs
          consent-base-binding-specs
          consent-primitive-manifest-binding-specs)
  (import (scheme base)
          (scheme file)
          (consent reader)
          (consent runtime))
  (begin
    ;; Registry key for the required R7RS `(scheme base)' library.
    (define scheme-base-library-key '(scheme base))

    ;; Backend hook resolving primitive implementation identifiers.
    (define (base-primitive-resolver name)
      "Resolve primitive implementation NAME through the installed backend."
      (eval-error "base primitive backend is not installed" name))
    ;; Backend hook for evaluating derived base prelude forms.
    (define (base-trampoline sequence environment context)
      "Evaluate SEQUENCE in ENVIRONMENT and CONTEXT through the backend."
      (eval-error "base trampoline backend is not installed"))
    ;; Backend hook for installing derived base syntax forms.
    (define (base-define-syntax form environment context syntax-environment)
      "Install syntax FORM through the installed base backend."
      (eval-error "base syntax backend is not installed"))

    (define (consent-install-base-backend!
             primitive-resolver trampoline define-syntax)
      "Install the evaluator backend hooks used for base bootstrapping."
      #((parameters
         (primitive-resolver (type procedure)
          (description
           ("Procedure mapping a registry implementation name to its"
             "primitive function.")))
         (trampoline (type procedure)
          (description
           ("Procedure that evaluates a derived base prelude sequence"
             "in an environment and context.")))
         (define-syntax (type procedure)
          (description
           ("Procedure that installs a derived base syntax form into a"
             "syntax environment."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! base-primitive-resolver primitive-resolver)
      (set! base-trampoline trampoline)
      (set! base-define-syntax define-syntax)
      consent-unspecified)

    (define (base-primitive-implementation name)
      "Resolve a registry implementation name through the installed backend."
      (base-primitive-resolver name))

    ;; Registry mapping primitive names to implementation identifiers and
    ;; arities.
    (define base-primitive-registry
      ;; Each entry is `(name implementation minimum-arity maximum-arity)'.
      ;; A false maximum means the primitive accepts arbitrarily many arguments.
      (list
       (list '* 'primitive* 0 #f)
       (list '+ 'primitive+ 0 #f)
       (list '- 'primitive- 1 #f)
       (list '/ 'primitive/ 1 #f)
       (list '< 'primitive< 2 #f)
       (list '<= 'primitive<= 2 #f)
       (list '= 'primitive= 2 #f)
       (list '> 'primitive> 2 #f)
       (list '>= 'primitive>= 2 #f)
       (list 'apply 'primitive-apply 2 #f)
       (list 'binary-port? 'primitive-binary-port? 1 1)
       (list 'boolean=? 'primitive-boolean=? 2 #f)
       (list 'boolean? 'primitive-boolean? 1 1)
       (list 'bytevector 'primitive-bytevector 0 #f)
       (list 'bytevector-append 'primitive-bytevector-append 0 #f)
       (list 'bytevector-copy 'primitive-bytevector-copy 1 3)
       (list 'bytevector-copy! 'primitive-bytevector-copy! 3 5)
       (list 'bytevector-length 'primitive-bytevector-length 1 1)
       (list 'bytevector-u8-ref 'primitive-bytevector-u8-ref 2 2)
       (list 'bytevector-u8-set! 'primitive-bytevector-u8-set! 3 3)
       (list 'bytevector? 'primitive-bytevector? 1 1)
       (list 'call-with-current-continuation 'primitive-call/cc 1 1)
       (list 'call-with-port 'primitive-call-with-port 2 2)
       (list 'call-with-values 'primitive-call-with-values 2 2)
       (list 'call/cc 'primitive-call/cc 1 1)
       (list 'car 'primitive-car 1 1)
       (list 'cdr 'primitive-cdr 1 1)
       (list 'ceiling 'primitive-ceiling 1 1)
       (list 'char->integer 'primitive-char->integer 1 1)
       (list 'char<=? 'primitive-char<=? 2 #f)
       (list 'char<? 'primitive-char<? 2 #f)
       (list 'char=? 'primitive-char=? 2 #f)
       (list 'char>=? 'primitive-char>=? 2 #f)
       (list 'char>? 'primitive-char>? 2 #f)
       (list 'char-ready? 'primitive-char-ready? 0 1)
       (list 'char? 'primitive-char? 1 1)
       (list 'close-input-port 'primitive-close-input-port 1 1)
       (list 'close-output-port 'primitive-close-output-port 1 1)
       (list 'close-port 'primitive-close-port 1 1)
       (list 'complex? 'primitive-complex? 1 1)
       (list 'cons 'primitive-cons 2 2)
       (list 'current-error-port 'primitive-current-error-port 0 0)
       (list 'current-input-port 'primitive-current-input-port 0 0)
       (list 'current-output-port 'primitive-current-output-port 0 0)
       (list 'dynamic-wind 'primitive-dynamic-wind 3 3)
       (list 'eq? 'primitive-eq? 2 2)
       (list 'equal? 'primitive-equal? 2 2)
       (list 'eqv? 'primitive-eqv? 2 2)
       (list 'eof-object 'primitive-eof-object 0 0)
       (list 'eof-object? 'primitive-eof-object? 1 1)
       (list 'error 'primitive-error 1 #f)
       (list 'error-object-irritants 'primitive-error-object-irritants 1 1)
       (list 'error-object-message 'primitive-error-object-message 1 1)
       (list 'error-object? 'primitive-error-object? 1 1)
       (list 'denominator 'primitive-denominator 1 1)
       (list 'exact 'primitive-exact 1 1)
       (list 'exact-integer-sqrt 'primitive-exact-integer-sqrt 1 1)
       (list 'exact-integer? 'primitive-exact-integer? 1 1)
       (list 'exact? 'primitive-exact? 1 1)
       (list 'expt 'primitive-expt 2 2)
       (list 'features 'primitive-features 0 0)
       (list 'file-error? 'primitive-file-error? 1 1)
       (list 'floor 'primitive-floor 1 1)
       (list 'floor/ 'primitive-floor/ 2 2)
       (list 'floor-quotient 'primitive-floor-quotient 2 2)
       (list 'floor-remainder 'primitive-floor-remainder 2 2)
       (list 'flush-output-port 'primitive-flush-output-port 0 1)
       (list 'gcd 'primitive-gcd 0 #f)
       (list 'get-output-bytevector 'primitive-get-output-bytevector 1 1)
       (list 'get-output-string 'primitive-get-output-string 1 1)
       (list 'inexact 'primitive-inexact 1 1)
       (list 'inexact? 'primitive-inexact? 1 1)
       (list 'input-port-open? 'primitive-input-port-open? 1 1)
       (list 'input-port? 'primitive-input-port? 1 1)
       (list 'integer->char 'primitive-integer->char 1 1)
       (list 'integer? 'primitive-integer? 1 1)
       (list 'lcm 'primitive-lcm 0 #f)
       (list 'list->string 'primitive-list->string 1 1)
       (list 'list->vector 'primitive-list->vector 1 1)
       (list 'list? 'primitive-list? 1 1)
       (list 'make-bytevector 'primitive-make-bytevector 1 2)
       (list 'make-parameter 'primitive-make-parameter 1 2)
       (list 'make-string 'primitive-make-string 1 2)
       (list 'make-vector 'primitive-make-vector 1 2)
       (list 'modulo 'primitive-modulo 2 2)
       (list 'newline 'primitive-newline 0 1)
       (list 'null? 'primitive-null? 1 1)
       (list 'number->string 'primitive-number->string 1 2)
       (list 'number? 'primitive-number? 1 1)
       (list 'numerator 'primitive-numerator 1 1)
       (list 'open-input-bytevector 'primitive-open-input-bytevector 1 1)
       (list 'open-input-string 'primitive-open-input-string 1 1)
       (list 'open-output-bytevector 'primitive-open-output-bytevector 0 0)
       (list 'open-output-string 'primitive-open-output-string 0 0)
       (list 'output-port-open? 'primitive-output-port-open? 1 1)
       (list 'output-port? 'primitive-output-port? 1 1)
       (list 'pair? 'primitive-pair? 1 1)
       (list 'peek-char 'primitive-peek-char 0 1)
       (list 'peek-u8 'primitive-peek-u8 0 1)
       (list 'port? 'primitive-port? 1 1)
       (list 'procedure? 'primitive-procedure? 1 1)
       (list 'quotient 'primitive-quotient 2 2)
       (list 'raise 'primitive-raise 1 1)
       (list 'raise-continuable 'primitive-raise-continuable 1 1)
       (list 'rational? 'primitive-rational? 1 1)
       (list 'rationalize 'primitive-rationalize 2 2)
       (list 'read-bytevector 'primitive-read-bytevector 1 2)
       (list 'read-bytevector! 'primitive-read-bytevector! 1 4)
       (list 'read-char 'primitive-read-char 0 1)
       (list 'read-error? 'primitive-read-error? 1 1)
       (list 'read-line 'primitive-read-line 0 1)
       (list 'read-string 'primitive-read-string 1 2)
       (list 'read-u8 'primitive-read-u8 0 1)
       (list 'real? 'primitive-real? 1 1)
       (list 'remainder 'primitive-remainder 2 2)
       (list 'round 'primitive-round 1 1)
       (list 'set-car! 'primitive-set-car! 2 2)
       (list 'set-cdr! 'primitive-set-cdr! 2 2)
       (list 'string 'primitive-string 0 #f)
       (list 'string->list 'primitive-string->list 1 3)
       (list 'string->number 'primitive-string->number 1 2)
       (list 'string->symbol 'primitive-string->symbol 1 1)
       (list 'string->utf8 'primitive-string->utf8 1 3)
       (list 'string->vector 'primitive-string->vector 1 3)
       (list 'string-append 'primitive-string-append 0 #f)
       (list 'string-copy 'primitive-string-copy 1 3)
       (list 'string-copy! 'primitive-string-copy! 3 5)
       (list 'string-fill! 'primitive-string-fill! 2 4)
       (list 'string-length 'primitive-string-length 1 1)
       (list 'string-ref 'primitive-string-ref 2 2)
       (list 'string-set! 'primitive-string-set! 3 3)
       (list 'string<=? 'primitive-string<=? 2 #f)
       (list 'string<? 'primitive-string<? 2 #f)
       (list 'string=? 'primitive-string=? 2 #f)
       (list 'string>=? 'primitive-string>=? 2 #f)
       (list 'string>? 'primitive-string>? 2 #f)
       (list 'string? 'primitive-string? 1 1)
       (list 'substring 'primitive-substring 3 3)
       (list 'symbol->string 'primitive-symbol->string 1 1)
       (list 'symbol=? 'primitive-symbol=? 2 #f)
       (list 'symbol? 'primitive-symbol? 1 1)
       (list 'textual-port? 'primitive-textual-port? 1 1)
       (list 'truncate 'primitive-truncate 1 1)
       (list 'truncate/ 'primitive-truncate/ 2 2)
       (list 'truncate-quotient 'primitive-truncate-quotient 2 2)
       (list 'truncate-remainder 'primitive-truncate-remainder 2 2)
       (list 'u8-ready? 'primitive-u8-ready? 0 1)
       (list 'utf8->string 'primitive-utf8->string 1 3)
       (list 'vector 'primitive-vector 0 #f)
       (list 'vector->list 'primitive-vector->list 1 3)
       (list 'vector->string 'primitive-vector->string 1 3)
       (list 'vector-append 'primitive-vector-append 0 #f)
       (list 'vector-copy 'primitive-vector-copy 1 3)
       (list 'vector-copy! 'primitive-vector-copy! 3 5)
       (list 'vector-fill! 'primitive-vector-fill! 2 4)
       (list 'vector-length 'primitive-vector-length 1 1)
       (list 'vector-ref 'primitive-vector-ref 2 2)
       (list 'vector-set! 'primitive-vector-set! 3 3)
       (list 'vector? 'primitive-vector? 1 1)
       (list 'values 'primitive-values 0 #f)
       (list 'with-exception-handler
             'primitive-with-exception-handler
             2
             2)
       (list 'write-bytevector 'primitive-write-bytevector 1 4)
       (list 'write-char 'primitive-write-char 1 2)
       (list 'write-string 'primitive-write-string 1 4)
       (list 'write-u8 'primitive-write-u8 1 2)))

    ;; User-facing documentation for kernel primitive bindings.
    (define (base-primitive-documentation-descriptor signature)
      "Return a rich metadata descriptor for compact primitive SIGNATURE."
      (list (list 'type (car signature))
            (list 'description (cadr signature))))

    (define (base-primitive-documentation-parameter parameter)
      "Return a rich metadata parameter descriptor for compact PARAMETER."
      (cons (car parameter)
            (base-primitive-documentation-descriptor (cdr parameter))))

    (define (base-primitive-documentation-fields name signature)
      "Return rich manifest documentation fields for primitive NAME SIGNATURE."
      (list
       (cons 'documentation (car signature))
       (cons 'parameters
             (map base-primitive-documentation-parameter
                  (cadr signature)))
       (cons 'returns
             (base-primitive-documentation-descriptor
              (car (cdr (cdr signature)))))
       (cons 'effects (list (primitive-effect-for-name name)))))

    ;; Compact per-primitive signatures: name, prose, parameters, and returns.
    (define base-primitive-documentation-table
      '((* "Return the product of all numeric arguments, or 1 when called with no arguments."
         ((numbers (list-of number) "Numeric factors to multiply."))
         (number "The numeric product."))
        (+ "Return the sum of all numeric arguments, or 0 when called with no arguments."
         ((numbers (list-of number) "Numeric addends to sum."))
         (number "The numeric sum."))
        (- "Return the negation of one number, or subtract each later number from the first."
         ((numbers (list-of number) "One or more numeric minuend/subtrahend values."))
         (number "The numeric negation or difference."))
        (/ "Return the reciprocal of one number, or divide the first by each later number."
         ((numbers (list-of number) "One or more numeric dividend/divisor values."))
         (number "The numeric reciprocal or quotient."))
        (< "Return #t when the numeric arguments are strictly increasing."
         ((numbers (list-of real) "Real numbers to compare."))
         (boolean "Whether the numbers are strictly increasing."))
        (<= "Return #t when the numeric arguments are monotonically nondecreasing."
         ((numbers (list-of real) "Real numbers to compare."))
         (boolean "Whether the numbers are monotonically nondecreasing."))
        (= "Return #t when all numeric arguments are numerically equal."
         ((numbers (list-of number) "Numbers to compare."))
         (boolean "Whether all numbers are numerically equal."))
        (> "Return #t when the numeric arguments are strictly decreasing."
         ((numbers (list-of real) "Real numbers to compare."))
         (boolean "Whether the numbers are strictly decreasing."))
        (>= "Return #t when the numeric arguments are monotonically nonincreasing."
         ((numbers (list-of real) "Real numbers to compare."))
         (boolean "Whether the numbers are monotonically nonincreasing."))
        (apply
         "Call a procedure with leading arguments followed by the final list argument."
         ((proc procedure "Procedure to call.")
          (arguments (list-of any) "Leading arguments followed by the final list."))
         (any "Values returned by PROC."))
        (binary-port? "Return #t when an object is a binary input or output port."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a binary port."))
        (boolean=? "Return #t when all boolean arguments have the same truth value."
         ((booleans (list-of boolean) "Boolean values to compare."))
         (boolean "Whether all booleans have the same truth value."))
        (boolean? "Return #t when an object is either #t or #f."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a boolean."))
        (bytevector "Return a newly allocated bytevector containing the given byte values."
         ((bytes (list-of byte) "Byte values for the new bytevector."))
         (bytevector "A newly allocated bytevector."))
        (bytevector-append
         "Return a newly allocated bytevector containing each argument's bytes."
         ((bytevectors (list-of bytevector) "Bytevectors to concatenate."))
         (bytevector "A newly allocated concatenated bytevector."))
        (bytevector-copy "Return a newly allocated copy of a bytevector slice."
         ((bytevector bytevector "Bytevector to copy.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (bytevector "A newly allocated bytevector slice."))
        (bytevector-copy! "Copy bytes from one bytevector slice into another in place."
         ((to bytevector "Destination bytevector.")
          (at exact-non-negative-integer "Destination start index.")
          (from bytevector "Source bytevector.")
          (start exact-non-negative-integer "Inclusive source start index.")
          (end exact-non-negative-integer "Exclusive source end index."))
         (unspecified "The unspecified value."))
        (bytevector-length "Return the number of bytes in a bytevector."
         ((bytevector bytevector "Bytevector whose length is requested."))
         (exact-non-negative-integer "The bytevector length."))
        (bytevector-u8-ref "Return the byte at a zero-based bytevector index."
         ((bytevector bytevector "Bytevector to read.")
          (k exact-non-negative-integer "Zero-based bytevector index."))
         (byte "The byte at index K."))
        (bytevector-u8-set! "Store an unsigned byte at a zero-based bytevector index."
         ((bytevector bytevector "Bytevector to mutate.")
          (k exact-non-negative-integer "Zero-based bytevector index.")
          (byte byte "Byte value to store."))
         (unspecified "The unspecified value."))
        (bytevector? "Return #t when an object is a bytevector."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a bytevector."))
        (call-with-current-continuation
         "Call a procedure with the current continuation as an escape procedure."
         ((proc procedure "Procedure that accepts the current continuation."))
         (any "Values delivered to the captured continuation."))
        (call-with-port
         "Call a procedure with a port and close the port when control leaves it."
         ((port port "Port passed to PROC and then closed.")
          (proc procedure "Procedure to call with PORT."))
         (any "Values returned by PROC."))
        (call-with-values "Call a producer and pass all produced values to a consumer."
         ((producer procedure "Zero-argument producer procedure.")
          (consumer procedure "Consumer procedure receiving producer values."))
         (any "Values returned by CONSUMER."))
        (call/cc "Alias for `call-with-current-continuation`."
         ((proc procedure "Procedure that accepts the current continuation."))
         (any "Values delivered to the captured continuation."))
        (car "Return the first field of a pair."
         ((pair pair "Pair to inspect."))
         (any "The pair's car field."))
        (cdr "Return the second field of a pair."
         ((pair pair "Pair to inspect."))
         (any "The pair's cdr field."))
        (ceiling "Return the least integer not less than a real number."
         ((x real "Real number to round upward."))
         (integer "The least integer not less than X."))
        (char->integer "Return a character's Unicode scalar value."
         ((char char "Character to convert."))
         (exact-integer "The character scalar value."))
        (char<=? "Return #t when characters are monotonically nondecreasing."
         ((chars (list-of char) "Characters to compare."))
         (boolean "Whether the characters are monotonically nondecreasing."))
        (char<? "Return #t when the characters are strictly increasing."
         ((chars (list-of char) "Characters to compare."))
         (boolean "Whether the characters are strictly increasing."))
        (char=? "Return #t when all characters have the same scalar value."
         ((chars (list-of char) "Characters to compare."))
         (boolean "Whether all characters have the same scalar value."))
        (char>=? "Return #t when characters are monotonically nonincreasing."
         ((chars (list-of char) "Characters to compare."))
         (boolean "Whether the characters are monotonically nonincreasing."))
        (char>? "Return #t when the characters are strictly decreasing."
         ((chars (list-of char) "Characters to compare."))
         (boolean "Whether the characters are strictly decreasing."))
        (char-ready? "Return #t when a character can be read without blocking."
         ((port textual-input-port "Textual input port to query."))
         (boolean "Whether a character is ready."))
        (char? "Return #t when an object is a character."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a character."))
        (close-input-port "Close an input port."
         ((port input-port "Input port to close."))
         (unspecified "The unspecified value."))
        (close-output-port "Close an output port."
         ((port output-port "Output port to close."))
         (unspecified "The unspecified value."))
        (close-port "Close an input, output, or bidirectional port."
         ((port port "Port to close."))
         (unspecified "The unspecified value."))
        (complex? "Return #t when an object is a complex number."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a complex number."))
        (cons "Return a newly allocated pair whose car and cdr are the arguments."
         ((obj1 any "Value for the new pair's car.")
          (obj2 any "Value for the new pair's cdr."))
         (pair "A newly allocated pair."))
        (current-error-port "Return the current textual error output port."
         ()
         (textual-output-port "The current textual error output port."))
        (current-input-port "Return the current textual input port."
         ()
         (textual-input-port "The current textual input port."))
        (current-output-port "Return the current textual output port."
         ()
         (textual-output-port "The current textual output port."))
        (dynamic-wind "Call before, thunk, and after around dynamic extent changes."
         ((before procedure "Zero-argument procedure called on entry.")
          (thunk procedure "Zero-argument procedure whose values are returned.")
          (after procedure "Zero-argument procedure called on exit."))
         (any "Values returned by THUNK."))
        (eq? "Return #t when two objects are the same under `eq?` identity."
         ((obj1 any "First object to compare.")
          (obj2 any "Second object to compare."))
         (boolean "Whether the objects are the same under `eq?`."))
        (equal? "Return #t when two objects have recursively equivalent contents."
         ((obj1 any "First object to compare.")
          (obj2 any "Second object to compare."))
         (boolean "Whether the objects are recursively equivalent."))
        (eqv? "Return #t when two objects are equivalent under R7RS `eqv?` rules."
         ((obj1 any "First object to compare.")
          (obj2 any "Second object to compare."))
         (boolean "Whether the objects are equivalent under `eqv?`."))
        (eof-object "Return the distinguished end-of-file object."
         ()
         (eof-object "An end-of-file object."))
        (eof-object? "Return #t when an object is the distinguished end-of-file object."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is an end-of-file object."))
        (error "Raise a non-continuable error object with optional irritants."
         ((message string "Error message string.")
          (irritants (list-of any) "Additional error irritants."))
         (never "This procedure does not return."))
        (error-object-irritants "Return the irritants carried by an error object."
         ((error-object error-object "Error object to inspect."))
         (list "The error object's irritants."))
        (error-object-message "Return the message string carried by an error object."
         ((error-object error-object "Error object to inspect."))
         (string "The error object's message."))
        (error-object? "Return #t when an object is an error object."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is an error object."))
        (denominator "Return a rational number's positive denominator."
         ((q rational "Rational number to inspect."))
         (integer "The denominator in lowest terms."))
        (exact "Return an exact representation of a number when one is available."
         ((z number "Number to convert."))
         (number "An exact representation of Z."))
        (exact-integer-sqrt "Return the exact integer square root and remainder."
         ((k exact-non-negative-integer "Non-negative exact integer."))
         ((values exact-non-negative-integer exact-non-negative-integer)
          "The square root and remainder."))
        (exact-integer? "Return #t when an object is both exact and an integer."
         ((z number "Number to test."))
         (boolean "Whether Z is an exact integer."))
        (exact? "Return #t when a number is represented exactly."
         ((z number "Number to test."))
         (boolean "Whether Z is exact."))
        (expt "Return a number raised to a numeric power."
         ((z1 number "Base number.")
          (z2 number "Exponent number."))
         (number "Z1 raised to the power Z2."))
        (features "Return the feature identifiers available to `cond-expand`."
         ()
         ((list-of symbol) "Feature identifiers true for `cond-expand`."))
        (file-error? "Return #t when an object is a file-system error object."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a file error object."))
        (flush-output-port "Flush buffered output on an output port."
         ((port output-port "Output port to flush."))
         (unspecified "The unspecified value."))
        (floor "Return the greatest integer not greater than a real number."
         ((x real "Real number to round downward."))
         (integer "The greatest integer not greater than X."))
        (floor/ "Return floor quotient and floor remainder for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         ((values integer integer) "The floor quotient and floor remainder."))
        (floor-quotient "Return the floor quotient for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The floor quotient."))
        (floor-remainder "Return the floor remainder for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The floor remainder."))
        (gcd "Return the greatest common divisor, or 0 with no arguments."
         ((integers (list-of integer) "Integer arguments."))
         (integer "The non-negative greatest common divisor."))
        (get-output-bytevector "Return accumulated bytes from an output bytevector port."
         ((port binary-output-port "Output bytevector port to drain."))
         (bytevector "Accumulated output bytes."))
        (get-output-string "Return accumulated text from an output string port."
         ((port textual-output-port "Output string port to drain."))
         (string "Accumulated output text."))
        (inexact "Return an inexact representation of a number."
         ((z number "Number to convert."))
         (number "An inexact representation of Z."))
        (inexact? "Return #t when a number is represented inexactly."
         ((z number "Number to test."))
         (boolean "Whether Z is inexact."))
        (input-port-open? "Return #t when an input port is still open."
         ((port input-port "Input port to inspect."))
         (boolean "Whether PORT is open for input."))
        (input-port? "Return #t when an object is an input port."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is an input port."))
        (integer->char "Return the character for a Unicode scalar value."
         ((n exact-integer "Character scalar value."))
         (char "The character represented by N."))
        (integer? "Return #t when an object is an integer."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is an integer."))
        (lcm "Return the least common multiple, or 1 with no arguments."
         ((integers (list-of integer) "Integer arguments."))
         (integer "The non-negative least common multiple."))
        (list->string "Return a newly allocated string containing list characters."
         ((list (list-of char) "List of characters."))
         (string "A newly allocated string."))
        (list->vector "Return a newly allocated vector containing list elements."
         ((list list "List whose elements become vector elements."))
         (vector "A newly allocated vector."))
        (list? "Return #t when an object is a proper list."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a proper list."))
        (make-bytevector "Return a newly allocated bytevector."
         ((k exact-non-negative-integer "Requested bytevector length.")
          (byte byte "Optional fill byte."))
         (bytevector "A newly allocated bytevector."))
        (make-parameter "Return a parameter procedure."
         ((init any "Initial parameter value.")
          (converter procedure "Optional converter procedure."))
         (procedure "A parameter procedure."))
        (make-string "Return a newly allocated string."
         ((k exact-non-negative-integer "Requested string length.")
          (char char "Optional fill character."))
         (string "A newly allocated string."))
        (make-vector "Return a newly allocated vector."
         ((k exact-non-negative-integer "Requested vector length.")
          (fill any "Optional fill value."))
         (vector "A newly allocated vector."))
        (modulo "Return the modulo remainder for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The modulo remainder."))
        (newline "Write a newline character to an output port."
         ((port textual-output-port "Textual output port to write."))
         (unspecified "The unspecified value."))
        (null? "Return #t when an object is the empty list."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is the empty list."))
        (number->string "Return a number's textual representation."
         ((z number "Number to render.")
          (radix exact-integer "Optional radix: 2, 8, 10, or 16."))
         (string "External representation of Z."))
        (number? "Return #t when an object is a number."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a number."))
        (numerator "Return the numerator of a rational number in lowest terms."
         ((q rational "Rational number to inspect."))
         (integer "The numerator in lowest terms."))
        (open-input-bytevector "Return a binary input port reading from a bytevector."
         ((bytevector bytevector "Bytevector backing the input port."))
         (binary-input-port "A binary input port."))
        (open-input-string "Return a textual input port reading from a string."
         ((string string "String backing the input port."))
         (textual-input-port "A textual input port."))
        (open-output-bytevector "Return a binary output port accumulating bytes."
         ()
         (binary-output-port "A binary output bytevector port."))
        (open-output-string "Return a textual output port accumulating characters."
         ()
         (textual-output-port "A textual output string port."))
        (output-port-open? "Return #t when an output port is still open."
         ((port output-port "Output port to inspect."))
         (boolean "Whether PORT is open for output."))
        (output-port? "Return #t when an object is an output port."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is an output port."))
        (pair? "Return #t when an object is a pair."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a pair."))
        (peek-char "Return the next character without consuming it."
         ((port textual-input-port "Textual input port to inspect."))
         ((or char eof-object) "The next character, or an end-of-file object."))
        (peek-u8 "Return the next byte without consuming it."
         ((port binary-input-port "Binary input port to inspect."))
         ((or byte eof-object) "The next byte, or an end-of-file object."))
        (port? "Return #t when an object is an input or output port."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a port."))
        (procedure? "Return #t when an object is a callable procedure."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a procedure."))
        (quotient "Return the truncated integer quotient for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The truncated quotient."))
        (raise "Raise a non-continuable exception object."
         ((obj any "Exception object to raise."))
         (never "This procedure does not return normally."))
        (raise-continuable "Raise a continuable exception object."
         ((obj any "Exception object to raise."))
         (any "Values returned by the exception handler."))
        (rational? "Return #t when an object is a rational number."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a rational number."))
        (rationalize "Return the simplest rational number within a tolerance."
         ((x real "Real number to approximate.")
          (y real "Real tolerance."))
         (rational "The simplest rational within tolerance."))
        (read-bytevector "Read up to a requested number of bytes."
         ((k exact-non-negative-integer "Maximum number of bytes to read.")
          (port binary-input-port "Binary input port to read."))
         ((or bytevector eof-object) "Bytes read, or an end-of-file object."))
        (read-bytevector! "Read bytes from a binary input port into a bytevector."
         ((bytevector bytevector "Destination bytevector.")
          (port binary-input-port "Binary input port to read.")
          (start exact-non-negative-integer "Inclusive destination start index.")
          (end exact-non-negative-integer "Exclusive destination end index."))
         ((or exact-non-negative-integer eof-object)
          "Number of bytes read, or an end-of-file object."))
        (read-char "Read and consume one character from a textual input port."
         ((port textual-input-port "Textual input port to read."))
         ((or char eof-object) "The next character, or an end-of-file object."))
        (read-error? "Return #t when an object is an error caused by reading."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a read error object."))
        (read-line "Read one line of text from a textual input port."
         ((port textual-input-port "Textual input port to read."))
         ((or string eof-object) "The next line, or an end-of-file object."))
        (read-string "Read up to a requested number of characters."
         ((k exact-non-negative-integer "Maximum number of characters to read.")
          (port textual-input-port "Textual input port to read."))
         ((or string eof-object) "Characters read, or an end-of-file object."))
        (read-u8 "Read and consume one byte from a binary input port."
         ((port binary-input-port "Binary input port to read."))
         ((or byte eof-object) "The next byte, or an end-of-file object."))
        (real? "Return #t when an object is a real number."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a real number."))
        (remainder "Return the truncated integer remainder for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The truncated remainder."))
        (round "Return the nearest integer to a real number."
         ((x real "Real number to round."))
         (integer "The nearest integer to X."))
        (set-car! "Replace the first field of a mutable pair."
         ((pair pair "Pair to mutate.")
          (obj any "New car value."))
         (unspecified "The unspecified value."))
        (set-cdr! "Replace the second field of a mutable pair."
         ((pair pair "Pair to mutate.")
          (obj any "New cdr value."))
         (unspecified "The unspecified value."))
        (string "Return a newly allocated string containing the given characters."
         ((chars (list-of char) "Characters for the new string."))
         (string "A newly allocated string."))
        (string->list "Return a list containing characters from a string slice."
         ((string string "String to copy from.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         ((list-of char) "A newly allocated list of characters."))
        (string->number "Parse a number from a string, optionally using a radix."
         ((string string "String to parse.")
          (radix exact-integer "Optional radix: 2, 8, 10, or 16."))
         ((or number boolean) "The parsed number, or #f."))
        (string->symbol "Return the symbol whose name is a string."
         ((string string "Symbol name."))
         (symbol "The interned symbol named by STRING."))
        (string->utf8 "Encode a string slice as a UTF-8 bytevector."
         ((string string "String to encode.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (bytevector "A UTF-8 encoded bytevector."))
        (string->vector "Return a vector containing characters from a string slice."
         ((string string "String to copy from.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         ((vector-of char) "A newly allocated vector of characters."))
        (string-append "Return a newly allocated string containing each argument."
         ((strings (list-of string) "Strings to concatenate."))
         (string "A newly allocated concatenated string."))
        (string-copy "Return a newly allocated copy of a string slice."
         ((string string "String to copy.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (string "A newly allocated string slice."))
        (string-copy! "Copy characters from one string slice into another in place."
         ((to string "Destination string.")
          (at exact-non-negative-integer "Destination start index.")
          (from string "Source string.")
          (start exact-non-negative-integer "Inclusive source start index.")
          (end exact-non-negative-integer "Exclusive source end index."))
         (unspecified "The unspecified value."))
        (string-fill! "Fill a string slice with a character in place."
         ((string string "String to mutate.")
          (fill char "Character to store.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (unspecified "The unspecified value."))
        (string-length "Return the number of characters in a string."
         ((string string "String whose length is requested."))
         (exact-non-negative-integer "The string length."))
        (string-ref "Return the character at a zero-based string index."
         ((string string "String to read.")
          (k exact-non-negative-integer "Zero-based string index."))
         (char "The character at index K."))
        (string-set! "Store a character at a zero-based string index."
         ((string string "String to mutate.")
          (k exact-non-negative-integer "Zero-based string index.")
          (char char "Character to store."))
         (unspecified "The unspecified value."))
        (string<=? "Return #t when strings are monotonically nondecreasing."
         ((strings (list-of string) "Strings to compare."))
         (boolean "Whether the strings are monotonically nondecreasing."))
        (string<? "Return #t when strings are strictly increasing."
         ((strings (list-of string) "Strings to compare."))
         (boolean "Whether the strings are strictly increasing."))
        (string=? "Return #t when all strings have the same characters."
         ((strings (list-of string) "Strings to compare."))
         (boolean "Whether all strings have the same characters."))
        (string>=? "Return #t when strings are monotonically nonincreasing."
         ((strings (list-of string) "Strings to compare."))
         (boolean "Whether the strings are monotonically nonincreasing."))
        (string>? "Return #t when strings are strictly decreasing."
         ((strings (list-of string) "Strings to compare."))
         (boolean "Whether the strings are strictly decreasing."))
        (string? "Return #t when an object is a string."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a string."))
        (substring "Return a newly allocated string slice."
         ((string string "String to copy.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (string "A newly allocated string slice."))
        (symbol->string "Return a symbol's name as a string."
         ((symbol symbol "Symbol to inspect."))
         (string "The symbol's name."))
        (symbol=? "Return #t when all symbols have the same name."
         ((symbols (list-of symbol) "Symbols to compare."))
         (boolean "Whether all symbols have the same name."))
        (symbol? "Return #t when an object is a symbol."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a symbol."))
        (textual-port? "Return #t when an object is a textual input or output port."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a textual port."))
        (truncate "Return the integer nearest to zero for a real number."
         ((x real "Real number to truncate."))
         (integer "The integer nearest to zero."))
        (truncate/ "Return truncated quotient and remainder for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         ((values integer integer) "The truncated quotient and remainder."))
        (truncate-quotient "Return the truncated quotient for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The truncated quotient."))
        (truncate-remainder "Return the truncated remainder for two integers."
         ((n1 integer "Dividend integer.")
          (n2 integer "Divisor integer."))
         (integer "The truncated remainder."))
        (u8-ready? "Return #t when a byte can be read without blocking."
         ((port binary-input-port "Binary input port to query."))
         (boolean "Whether a byte is ready."))
        (utf8->string "Decode a UTF-8 bytevector slice as a string."
         ((bytevector bytevector "UTF-8 bytevector to decode.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (string "A newly allocated decoded string."))
        (vector "Return a newly allocated vector containing the given values."
         ((values (list-of any) "Values for the new vector."))
         (vector "A newly allocated vector."))
        (vector->list "Return a list containing elements from a vector slice."
         ((vector vector "Vector to copy from.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (list "A newly allocated list."))
        (vector->string "Return a string containing characters from a vector slice."
         ((vector (vector-of char) "Vector of characters to copy from.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (string "A newly allocated string."))
        (vector-append "Return a newly allocated vector containing each argument."
         ((vectors (list-of vector) "Vectors to concatenate."))
         (vector "A newly allocated concatenated vector."))
        (vector-copy "Return a newly allocated copy of a vector slice."
         ((vector vector "Vector to copy.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (vector "A newly allocated vector slice."))
        (vector-copy! "Copy elements from one vector slice into another in place."
         ((to vector "Destination vector.")
          (at exact-non-negative-integer "Destination start index.")
          (from vector "Source vector.")
          (start exact-non-negative-integer "Inclusive source start index.")
          (end exact-non-negative-integer "Exclusive source end index."))
         (unspecified "The unspecified value."))
        (vector-fill! "Fill a vector slice with a value in place."
         ((vector vector "Vector to mutate.")
          (fill any "Value to store.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (unspecified "The unspecified value."))
        (vector-length "Return the number of elements in a vector."
         ((vector vector "Vector whose length is requested."))
         (exact-non-negative-integer "The vector length."))
        (vector-ref "Return the element at a zero-based vector index."
         ((vector vector "Vector to read.")
          (k exact-non-negative-integer "Zero-based vector index."))
         (any "The element at index K."))
        (vector-set! "Store a value at a zero-based vector index."
         ((vector vector "Vector to mutate.")
          (k exact-non-negative-integer "Zero-based vector index.")
          (obj any "Value to store."))
         (unspecified "The unspecified value."))
        (vector? "Return #t when an object is a vector."
         ((obj any "Object to test."))
         (boolean "Whether OBJ is a vector."))
        (values "Return all arguments as multiple values."
         ((values (list-of any) "Values to deliver to the continuation."))
         (values "The supplied arguments as multiple values."))
        (with-exception-handler
         "Call a thunk with an exception handler installed for its dynamic extent."
         ((handler procedure "One-argument exception handler.")
          (thunk procedure "Zero-argument thunk to call."))
         (any "Values returned by THUNK."))
        (write-bytevector "Write bytes from a bytevector slice."
         ((bytevector bytevector "Bytevector to write.")
          (port binary-output-port "Binary output port to write.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (unspecified "The unspecified value."))
        (write-char "Write one character to a textual output port."
         ((char char "Character to write.")
          (port textual-output-port "Textual output port to write."))
         (unspecified "The unspecified value."))
        (write-string "Write characters from a string slice."
         ((string string "String to write.")
          (port textual-output-port "Textual output port to write.")
          (start exact-non-negative-integer "Inclusive start index.")
          (end exact-non-negative-integer "Exclusive end index."))
         (unspecified "The unspecified value."))
        (write-u8 "Write one byte to a binary output port."
         ((byte byte "Byte to write.")
          (port binary-output-port "Binary output port to write."))
         (unspecified "The unspecified value."))))

    (define (primitive-manifest-documentation documentation)
      "Return normalized primitive manifest DOCUMENTATION metadata."
      (if (string? documentation)
          (make-documentation-metadata
           (list (cons 'documentation documentation))
           '(primitive-manifest-string))
          (make-documentation-metadata
           documentation
           '(primitive-manifest-metadata))))

    (define (primitive-manifest-documentation-field text)
      "Return an optional manifest documentation field for TEXT."
      (if text
          (list (list 'documentation
                      (primitive-manifest-documentation text)))
          '()))

    (define (base-primitive-documentation name)
      "Return public manifest documentation for kernel primitive NAME."
      (let ((entry (assq name base-primitive-documentation-table)))
        (and entry
             (base-primitive-documentation-fields name (cdr entry)))))

    ;; Kernel primitive names grouped by effect tier for manifest metadata.
    (define primitive-mutation-names
      '(bytevector-copy! bytevector-u8-set! read-bytevector!
        set-car! set-cdr! string-copy! string-fill! string-set!
        vector-copy! vector-fill! vector-set!))

    ;; Kernel primitive names that observe or update port state.
    (define primitive-port-io-names
      '(binary-port? call-with-port char-ready? close-input-port
        close-output-port close-port eof-object eof-object? file-error?
        flush-output-port get-output-bytevector get-output-string
        input-port-open? input-port? newline open-input-bytevector
        open-input-string open-output-bytevector open-output-string
        output-port-open? output-port? peek-char peek-u8 port?
        read-bytevector read-char read-error? read-line read-string
        read-u8 textual-port? u8-ready? write-bytevector write-char
        write-string write-u8))

    ;; Kernel primitive names that affect evaluator control flow.
    (define primitive-control-names
      '(apply call-with-current-continuation call-with-values call/cc
        dynamic-wind error raise raise-continuable values
        with-exception-handler))

    (define (primitive-effect-for-name name)
      "Return the effect tier for primitive NAME."
      (cond
       ((memq name primitive-mutation-names) 'mutation)
       ((memq name primitive-port-io-names) 'port-io)
       ((memq name primitive-control-names) 'control)
       ((eq? name 'make-parameter) 'dynamic-state)
       (else 'pure)))

    (define (primitive-emitter-hook-for-effect effect)
      "Return a future backend lowering hint for EFFECT."
      (cond
       ((eq? effect 'mutation) 'runtime-mutation)
       ((eq? effect 'port-io) 'capability-port)
       ((eq? effect 'control) 'runtime-control)
       ((eq? effect 'dynamic-state) 'runtime-parameter)
       ((eq? effect 'host-file) 'capability-file)
       ((eq? effect 'host-process) 'capability-process)
       ((eq? effect 'host-time) 'capability-time)
       ((eq? effect 'host-repl) 'capability-repl)
       ((eq? effect 'eval) 'runtime-eval)
       (else 'inline-or-call)))

    (define (primitive-backend-effect-path-for-effect effect)
      "Return the shared backend execution path for EFFECT."
      (cond
       ((eq? effect 'pure) 'direct-runtime)
       ((eq? effect 'mutation) 'runtime-mutation)
       ((eq? effect 'port-io) 'runtime-port-check)
       ((eq? effect 'control) 'runtime-control)
       ((eq? effect 'dynamic-state) 'runtime-parameter)
       ((memq effect '(host-file host-process host-time host-repl))
        'shared-capability-request)
       (else 'direct-runtime)))

    (define (primitive-test-categories-for-name name effect)
      "Return test category tags for NAME and EFFECT."
      (cond
       ((memq name '(vector vector? vector-ref vector-set! vector-length
                    vector-copy vector-copy! vector-fill! vector-append
                    vector->list vector->string vector-map vector-for-each
                    string->vector))
        '(vector))
       ((memq name '(bytevector bytevector? bytevector-length
                     bytevector-u8-ref bytevector-u8-set! bytevector-copy
                     bytevector-copy! bytevector-append read-bytevector
                     read-bytevector! write-bytevector))
        '(bytevector))
       ((eq? effect 'port-io)
        '(port))
       ((eq? effect 'control)
        '(control))
       (else
        '(base))))

    (define (base-primitive-manifest-spec entry)
      "Return canonical manifest metadata for one base primitive ENTRY."
      (let* ((name (car entry))
             (effect (primitive-effect-for-name name)))
        (list (list 'name name)
              (list 'library scheme-base-library-key)
              (list 'minimum-arity (third entry))
              (list 'maximum-arity (fourth entry))
              (list 'source 'kernel)
              (list 'effect effect)
              (list 'required-capability #f)
              (list 'emacs-hook #f)
              (list 'portable-hook (second entry))
              (list 'backend-effect-path
                    (primitive-backend-effect-path-for-effect effect))
              (list 'emitter-hook
                    (primitive-emitter-hook-for-effect effect))
              (list 'policy-category 'pure-r7rs)
              (list 'policy 'allow)
              (list 'test-categories
                    (primitive-test-categories-for-name name effect))
              (list 'documentation
                    (primitive-manifest-documentation
                     (base-primitive-documentation name))))))

    (define (consent-base-primitive-names)
      "Primitive metadata is exported for tests and future conformance reports;"
      "it describes the kernel surface without exposing implementation"
      "closures."
      #((parameters)
        (returns (type (list-of symbol))
         (description
          ("A list of the symbol names of every registered kernel"
            "primitive.")))
        (effects state-read allocation))
      (map car base-primitive-registry))

    (define (consent-base-primitive-specs)
      "Public metadata accessor for kernel primitive arity and source specs."
      #((parameters)
        (returns (type list)
         (description
          ("A list of association lists, one per kernel primitive,"
            "carrying its name, minimum and maximum arity, source, and"
            "effect fields.")))
        (effects state-read allocation))
      (map (lambda (spec)
             (list (assq 'name spec)
                   (assq 'minimum-arity spec)
                   (assq 'maximum-arity spec)
                   (assq 'source spec)
                   (assq 'effect spec)))
           (map base-primitive-manifest-spec base-primitive-registry)))

    ;; Prelude source paths are the only host-files read during base environment
    ;; construction; they support project-root and library-path test layouts.
    (define consent-base-prelude-load-paths
      ;; Portable Scheme tests may run from the project root or with the
      ;; `consent' directory on the implementation's library path.
      '("scheme/consent/base-prelude.scm"
        "consent/base-prelude.scm"))

    ;; Syntax prelude paths mirror value prelude loading so derived syntax stays
    ;; portable source, not embedded host data.
    (define consent-base-syntax-load-paths
      '("scheme/consent/base-syntax.scm"
        "consent/base-syntax.scm"))

    ;; Cache for parsed base prelude forms shared across base environment
    ;; creation.
    (define base-prelude-forms-cache #f)
    ;; Cache for parsed syntax prelude forms shared across evaluation contexts.
    (define base-syntax-forms-cache #f)

    (define (read-port-string port)
      "Read all characters from PORT into a string."
      #((parameters
         (port (type port)
          (description "Open textual input port to drain to end of file.")))
        (returns (type string)
         (description ("A string containing every character read from the port.")))
        (effects state-read allocation))
      (let loop ((chars '()))
        (let ((char (read-char port)))
          (if (eof-object? char)
              (list->string (reverse chars))
              (loop (cons char chars))))))

    (define (read-all-datums port)
      "Read and parse all datums from PORT."
      #((parameters
         (port (type port)
          (description
           ("Open textual input port whose contents are read and"
             "parsed."))))
        (returns (type list)
         (description ("A list of every datum parsed from the port's contents.")))
        (effects state-read allocation))
      (consent-read-all (read-port-string port)))

    (define (try-read-file-text path)
      "Return PATH's contents as a string, or #f when it cannot be read."
      (guard (condition (else #f))
        (call-with-input-file path read-port-string)))

    (define (resolve-source-entry relative-path default-paths)
      "Return (RESOLVED-PATH . TEXT) for logical RELATIVE-PATH from the"
      "first source that works, or #f."
      "Search order matches the host/core resolution contract:"
      "host-injected search directories (CONSENT_LIBRARY_PATH, datadir,"
      "executable-relative) highest, then the built-in cwd-relative"
      "DEFAULT-PATHS (source tree), then embedded source (the"
      "zero-dependency floor). RESOLVED-PATH is the on-disk path read, or"
      "RELATIVE-PATH for embedded source."
      #((parameters
         (relative-path (type string)
          (description "Logical path of the source resource to resolve."))
         (default-paths (type list)
          (description
           ("List of built-in cwd-relative fallback paths searched"
             "before embedded source."))))
        (returns (type (or pair boolean))
         (description
          ("A pair (RESOLVED-PATH . TEXT) from the first source that"
            "works, or #f when none resolve.")))
        (effects state-read allocation))
      (let loop-dirs ((dirs (consent-library-search-directory-list)))
        (if (pair? dirs)
            (let* ((path (string-append (car dirs) "/" relative-path))
                   (text (try-read-file-text path)))
              (if text
                  (cons path text)
                  (loop-dirs (cdr dirs))))
            (let loop-defaults ((paths default-paths))
              (if (pair? paths)
                  (let ((text (try-read-file-text (car paths))))
                    (if text
                        (cons (car paths) text)
                        (loop-defaults (cdr paths))))
                  (let ((embedded (consent-embedded-source-ref relative-path)))
                    (and embedded (cons relative-path embedded))))))))

    (define (resolve-source-text relative-path default-paths)
      "Return runtime source TEXT for logical RELATIVE-PATH, or #f when none is found."
      #((parameters
         (relative-path (type string)
          (description "Logical path of the source resource to resolve."))
         (default-paths (type list)
          (description
           ("List of built-in cwd-relative fallback paths searched"
             "before embedded source."))))
        (returns (type (or string boolean))
         (description
          ("The source text string for the resolved resource, or #f"
            "when none is found.")))
        (effects state-read allocation))
      (let ((entry (resolve-source-entry relative-path default-paths)))
        (and entry (cdr entry))))

    (define (base-prelude-forms)
      "Prelude forms are cached after reader validation; metadata extraction"
      "depends on each top-level form remaining one define."
      #((parameters)
        (returns (type list)
         (description
          ("The list of parsed top-level base prelude forms, cached"
            "after first read.")))
        (effects state-read state-write allocation error))
      (or base-prelude-forms-cache
          (let ((text (resolve-source-text "consent/base-prelude.scm"
                                           consent-base-prelude-load-paths)))
            (if text
                (let ((forms (consent-read-all text)))
                  (set! base-prelude-forms-cache forms)
                  forms)
                (eval-error "unable to load base prelude")))))

    (define (base-syntax-forms)
      "Syntax prelude forms are cached separately because they install into the"
      "current syntax environment, not the value environment."
      #((parameters)
        (returns (type list)
         (description
          ("The list of parsed top-level base syntax prelude forms,"
            "cached after first read.")))
        (effects state-read state-write allocation error))
      (or base-syntax-forms-cache
          (let ((text (resolve-source-text "consent/base-syntax.scm"
                                           consent-base-syntax-load-paths)))
            (if text
                (let ((forms (consent-read-all text)))
                  (set! base-syntax-forms-cache forms)
                  forms)
                (eval-error "unable to load base syntax prelude")))))

    (define (formals-arity formals)
      "Return minimum and maximum arity metadata for Scheme formals."
      (cond
       ((symbol? formals)
        (cons 0 #f))
       (else
        (let loop ((cursor formals) (minimum 0))
          (cond
           ((null? cursor)
            (cons minimum minimum))
           ((pair? cursor)
            (loop (cdr cursor) (+ minimum 1)))
           ((symbol? cursor)
            (cons minimum #f))
           (else
            (eval-error "prelude definition has invalid formals")))))))

    (define (base-body-definition-form? form)
      "Report whether FORM is a definition-like body form for documentation"
      "prefix detection."
      (and (pair? form)
           (or (eq? (car form) 'define)
               (eq? (car form) 'define-values)
               (eq? (car form) 'define-record-type))))

    (define (base-body-documentation body . maybe-formals)
      "Return documentation metadata from BODY and optional FORMALS, or #f."
      (apply documentation-metadata-from-body
             body
             base-body-definition-form?
             maybe-formals))

    (define (base-documentation-field documentation)
      "Return an optional documentation field for metadata records."
      (if documentation
          (list (list 'documentation documentation))
          '()))

    (define (prelude-definition-spec form)
      "Extract name, arity, and source metadata from one prelude define."
      (if (not (and (pair? form)
                    (eq? (car form) 'define)
                    (pair? (cdr form))
                    (pair? (cdr (cdr form)))))
          (eval-error "prelude form must be one definition" form))
      (let ((target (second form)))
        (cond
         ((symbol? target)
          (if (not (null? (cdr (cdr (cdr form)))))
              (eval-error
               "prelude variable definition must have one initializer"))
          (let ((initializer (third form)))
            (if (not (and (pair? initializer)
                          (eq? (car initializer) 'lambda)))
                (eval-error
                 "prelude variable definition must initialize a lambda"))
            (let ((arity (formals-arity (second initializer))))
              (append
               (list (list 'name target)
                     (list 'minimum-arity (car arity))
                     (list 'maximum-arity (cdr arity))
                     (list 'source 'prelude))
               (base-documentation-field
                (base-body-documentation
                 (cdr (cdr initializer))
                 (second initializer)))))))
         ((pair? target)
          (let ((arity (formals-arity (cdr target))))
            (append
             (list (list 'name (car target))
                   (list 'minimum-arity (car arity))
                   (list 'maximum-arity (cdr arity))
                   (list 'source 'prelude))
             (base-documentation-field
              (base-body-documentation
               (cdr (cdr form))
               (cdr target))))))
         (else
          (eval-error
           "prelude define target must be an identifier or function signature"
           form)))))

    (define (consent-base-prelude-binding-specs)
      "Prelude binding specs identify derived procedures separately from kernel"
      "primitives so tests can catch accidental boundary movement."
      #((parameters)
        (returns (type list)
         (description
          ("A list of association lists describing each derived"
            "prelude binding's name, arity, source, and documentation.")))
        (effects state-read state-write allocation error))
      (map prelude-definition-spec (base-prelude-forms)))

    (define (consent-base-prelude-binding-names)
      "Public metadata accessor for derived base prelude names."
      #((parameters)
        (returns (type symbol)
         (description
          ("A list of the symbol names of every derived base prelude"
            "binding.")))
        (effects state-read state-write allocation error))
      (map (lambda (spec)
             (second (assq 'name spec)))
           (consent-base-prelude-binding-specs)))

    (define (consent-base-binding-specs)
      "Public metadata accessor for all base binding specs."
      #((parameters)
        (returns (type list)
         (description
          ("A list of binding specs covering both kernel primitives"
            "and derived prelude bindings.")))
        (effects state-read state-write allocation error))
      (append (consent-base-primitive-specs)
              (consent-base-prelude-binding-specs)))

    ;; User-facing documentation for host-effecting standard primitives.
    (define standard-primitive-documentation-table
      (list
       (list '(scheme file) 'delete-file
             "Delete the file at PATH, subject to the file-system capability policy.")
       (list '(scheme file) 'file-exists?
             (string-append
              "Return #t when PATH names an existing file, subject to the "
              "file-system capability policy."))
       (list '(scheme file) 'call-with-input-file
             "Open PATH for textual input, call PROC with the port, and close the port afterward.")
       (list '(scheme file) 'call-with-output-file
             "Open PATH for textual output, call PROC with the port, and close the port afterward.")
       (list '(scheme file) 'open-binary-input-file
             "Open PATH as a binary input port, subject to the file-system capability policy.")
       (list '(scheme file) 'open-binary-output-file
             "Open PATH as a binary output port, subject to the file-system capability policy.")
       (list '(scheme file) 'open-input-file
             "Open PATH as a textual input port, subject to the file-system capability policy.")
       (list '(scheme file) 'open-output-file
             "Open PATH as a textual output port, subject to the file-system capability policy.")
       (list '(scheme file) 'with-input-from-file
             (string-append
              "Evaluate THUNK with the current input port temporarily bound "
              "to PATH's textual input port."))
       (list '(scheme file) 'with-output-to-file
             (string-append
              "Evaluate THUNK with the current output port temporarily bound "
              "to PATH's textual output port."))
       (list '(scheme load) 'load
             (string-append
              "Read and evaluate Scheme source from PATH, subject to the "
              "file-system capability policy."))
       (list '(scheme process-context) 'command-line
             (string-append
              "Return script invocation arguments, or the process command "
              "line when process-environment access is allowed."))
       (list '(scheme process-context) 'emergency-exit
             "Request immediate process termination, denied by default by the process policy.")
       (list '(scheme process-context) 'exit
             "Request orderly process termination, denied by default by the process policy.")
       (list '(scheme process-context) 'get-environment-variable
             "Return one environment variable value, subject to process-environment policy.")
       (list '(scheme process-context) 'get-environment-variables
             "Return environment variable bindings, subject to process-environment policy.")
       (list '(scheme repl) 'interaction-environment
             "Return the current session interaction environment when REPL access is allowed.")
       (list '(scheme time) 'current-jiffy
             (string-append
              "Return the current clock reading as an integer jiffy count, "
              "subject to the clock capability policy."))
       (list '(scheme time) 'current-second
             (string-append
              "Return the current time as a real number of seconds since the "
              "Unix epoch, subject to the clock capability policy."))
       (list '(scheme time) 'jiffies-per-second
             "Return the number of jiffies per second used by `current-jiffy`.")))

    (define (primitive-documentation-lookup table library name)
      "Return manifest documentation in TABLE for LIBRARY and NAME."
      (let loop ((rest table))
        (cond
         ((null? rest) #f)
         ((and (equal? (car (car rest)) library)
               (eq? (second (car rest)) name))
          (third (car rest)))
         (else (loop (cdr rest))))))

    ;; Explicit manifest metadata for host-effecting standard primitives.
    ;; These records keep the shared capability path visible to reflection and
    ;; backend planning even when a binding still fails closed by default.
    (define standard-primitive-manifest-specs
      (list
       (list (list 'name 'delete-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-delete-file)
             (list 'portable-hook 'primitive-delete-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'file-exists?)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-file-exists?)
             (list 'portable-hook 'primitive-file-exists?)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'call-with-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-call-with-input-file)
             (list 'portable-hook 'primitive-call-with-input-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'call-with-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-call-with-output-file)
             (list 'portable-hook 'primitive-call-with-output-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-binary-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-open-binary-input-file)
             (list 'portable-hook 'primitive-open-binary-input-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-binary-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-open-binary-output-file)
             (list 'portable-hook 'primitive-open-binary-output-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-open-input-file)
             (list 'portable-hook 'primitive-open-input-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-open-output-file)
             (list 'portable-hook 'primitive-open-output-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'with-input-from-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-with-input-from-file)
             (list 'portable-hook 'primitive-with-input-from-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'with-output-to-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-with-output-to-file)
             (list 'portable-hook 'primitive-with-output-to-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'load)
             (list 'library '(scheme load))
             (list 'minimum-arity 1)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'consent--primitive-load)
             (list 'portable-hook 'primitive-load)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(load file policy)))
       (list (list 'name 'command-line)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'consent--primitive-command-line)
             (list 'portable-hook 'primitive-command-line)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'emergency-exit)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'consent--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'exit)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'consent--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'get-environment-variable)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'consent--primitive-get-environment-variable)
             (list 'portable-hook 'primitive-get-environment-variable)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'grant)
             (list 'test-categories '(process policy)))
       (list (list 'name 'get-environment-variables)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity 0)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'consent--primitive-get-environment-variables)
             (list 'portable-hook 'primitive-get-environment-variables)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'grant)
             (list 'test-categories '(process policy)))
       (list (list 'name 'interaction-environment)
             (list 'library '(scheme repl))
             (list 'minimum-arity 0)
             (list 'maximum-arity 0)
             (list 'source 'host-capability)
             (list 'effect 'host-repl)
             (list 'required-capability 'repl)
             (list 'emacs-hook
                   'consent--primitive-interaction-environment)
             (list 'portable-hook 'primitive-interaction-environment)
             (list 'emitter-hook 'capability-repl)
             (list 'policy 'session)
             (list 'test-categories '(repl policy session)))
       (list (list 'name 'current-jiffy)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity 0)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'consent--primitive-current-jiffy)
             (list 'portable-hook 'primitive-current-jiffy)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'grant)
             (list 'test-categories '(time policy clock)))
       (list (list 'name 'current-second)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity 0)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'consent--primitive-current-second)
             (list 'portable-hook 'primitive-current-second)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'grant)
             (list 'test-categories '(time policy clock)))
       (list (list 'name 'jiffies-per-second)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity 0)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'consent--primitive-jiffies-per-second)
             (list 'portable-hook 'primitive-jiffies-per-second)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'grant)
             (list 'test-categories '(time policy clock)))))

    (define (standard-primitive-manifest-spec spec)
      "Add shared backend policy-path metadata to host-effecting standard specs."
      (append spec
              (list (list 'backend-effect-path 'shared-capability-request)
                    (list 'policy-category 'standard-host-effect))
              (primitive-manifest-documentation-field
               (primitive-documentation-lookup
                standard-primitive-documentation-table
                (second (assq 'library spec))
                (second (assq 'name spec))))))

    (define (standard-primitive-binding-specs)
      "Return manifest metadata for standard-library primitive bindings."
      (map standard-primitive-manifest-spec standard-primitive-manifest-specs))

    (define (prelude-manifest-spec spec)
      "Return manifest metadata for portable prelude SPEC."
      (let* ((name (second (assq 'name spec)))
             (effect 'pure))
        (append spec
                (list (list 'library scheme-base-library-key)
                      (list 'effect effect)
                      (list 'required-capability #f)
                      (list 'emacs-hook #f)
                      (list 'portable-hook #f)
                      (list 'backend-effect-path 'direct-runtime)
                      (list 'emitter-hook 'inline-or-call)
                      (list 'policy-category 'pure-r7rs)
                      (list 'policy 'allow)
                      (list 'test-categories
                            (primitive-test-categories-for-name
                             name
                             effect))))))

    (define (consent-primitive-manifest-binding-specs)
      "Public manifest accessor shared by portable tests and future tools."
      #((parameters)
        (returns (type list)
         (description
          ("A list of manifest specs covering kernel primitives,"
            "derived prelude bindings, and host-effecting standard"
            "primitives.")))
        (effects state-read state-write allocation error))
      (append (map base-primitive-manifest-spec base-primitive-registry)
              (map prelude-manifest-spec
                   (consent-base-prelude-binding-specs))
              (standard-primitive-binding-specs)))

    (define (define-primitive! environment
                               name
                               function
                               minimum-arity
                               maximum-arity)
      "Install a primitive procedure binding into ENVIRONMENT."
      #((parameters
         (environment (type environment)
          (description ("Target environment to receive the primitive binding.")))
         (name (type symbol)
          (description "Symbol under which the primitive is bound."))
         (function (type procedure)
          (description "Host procedure implementing the primitive."))
         (minimum-arity (type exact-integer)
          (description "Minimum number of arguments the primitive accepts."))
         (maximum-arity (type (or exact-integer boolean))
          (description "Maximum number of arguments, or #f for unbounded.")))
        (returns . "The unspecified result of installing the binding.")
        (effects state-write allocation))
      (environment-define!
       environment
       name
       (make-primitive-procedure
        name function minimum-arity maximum-arity)))

    (define (consent-make-base-environment)
      "The base environment installs primitive kernel bindings first, then"
      "evaluates derived Scheme definitions in the same environment."
      #((parameters)
        (returns
         . ("A fresh environment populated with kernel primitives and"
            "derived base definitions."))
        (effects state-read state-write allocation host-eval error))
      (let ((environment (consent-make-empty-environment)))
        (let loop ((rest base-primitive-registry))
          (if (null? rest)
              (begin
                ;; Derived base procedures are ordinary Scheme definitions
                ;; loaded through the same evaluator and trampoline.
                (base-trampoline
                 (make-sequence (base-prelude-forms) #t)
                 environment
                 (new-eval-context '()))
                environment)
              (begin
                (define-primitive! environment
                                   (car (car rest))
                                   (base-primitive-implementation (second (car rest)))
                                   (third (car rest))
                                   (fourth (car rest)))
                (loop (cdr rest)))))))

    (define (ensure-base-syntax! context environment)
      "Install derived base syntax into CONTEXT once."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context tracking whether base syntax is already"
             "installed.")))
         (environment (type environment)
          (description
           ("Environment into which the derived syntax forms are"
             "installed."))))
        (returns
         . ("The unspecified value once base syntax is installed in the"
            "context."))
        (effects state-read state-write allocation host-eval error))
      (if (not (context-base-syntax-installed context))
          (begin
            (for-each
             (lambda (form)
               (base-define-syntax
                form
                environment
                context
                (context-syntax-environment context)))
             (base-syntax-forms))
            (set-context-base-syntax-installed! context #t))))

    ))
