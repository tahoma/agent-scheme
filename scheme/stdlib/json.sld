;;; Portable stdlib JSON support.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Consent Scheme owns this stdlib translator because JSON is an
;;; agent/protocol edge format. Canonical runtime state remains
;;; Scheme-readable data; this library converts at explicit boundaries only.
;;; The public `(consent json)', `(srfi 180)', and `(srfi srfi-180)' imports
;;; are registry aliases over this implementation.

(define-library (stdlib json)
  (export json-number-of-character-limit
          json-nesting-depth-limit
          json-null?
          json-error?
          json-error-reason
          json-fold
          json-generator
          json-read
          json-lines-read
          json-sequence-read
          json-accumulator
          json-write)
  (import (scheme base)
          (scheme case-lambda)
          (prefix (stdlib generator) gen:)
          (stdlib and-let-star))
  (begin
    ;; Limit the number of characters read from one JSON value when non-#f.
    (define json-number-of-character-limit (make-parameter #f))
    ;; Limit recursive JSON array/object nesting when non-#f.
    (define json-nesting-depth-limit (make-parameter #f))
    ;; Track characters consumed while reading one JSON value.
    (define json-character-count (make-parameter 0))

    ;; JSON errors carry a portable reason string across hosts.
    (define-record-type <json-error>
      (make-json-error reason)
      json-error?
      (reason json-error-reason))

    (define (json-null? obj)
      "Return #t when OBJ is the SRFI 180 JSON null sentinel."
      #((parameters
         (obj . "Value to inspect."))
        (returns (type boolean)
         (description "#t when OBJ is the symbol `null`; otherwise #f."))
        (effects pure))
      (eq? obj 'null))

    (define (json-fail reason)
      "Raise a JSON parse or encoding error with REASON."
      (raise (make-json-error reason)))

    ;; Produce the R7RS unspecified value after side-effecting writers.
    (define (json-unspecified)
      "Return the R7RS unspecified value."
      (if #f #f))

    ;; Recognize JSON whitespace, including record separators for sequences.
    (define (json-whitespace? char)
      "Return #t when CHAR is insignificant JSON whitespace."
      (and (not (eof-object? char))
           (or (char=? char #\space)
               (char=? char #\tab)
               (char=? char #\newline)
               (char=? char #\return)
               (char=? char #\x1e))))

    ;; JSON strings may not contain unescaped control characters.
    (define (json-control-character? char)
      "Return #t when CHAR is a JSON string control character."
      (< (char->integer char) 32))

    ;; Recognize decimal digits without depending on implementation char sets.
    (define (json-digit? char)
      "Return #t when CHAR is an ASCII decimal digit."
      (and (not (eof-object? char))
           (let ((code (char->integer char)))
             (and (<= (char->integer #\0) code)
                  (<= code (char->integer #\9))))))

    ;; Numbers cannot have leading zeroes before another digit.
    (define (json-nonzero-digit? char)
      "Return #t when CHAR is a decimal digit other than zero."
      (and (json-digit? char) (not (char=? char #\0))))

    ;; Decode one hexadecimal digit from a JSON unicode escape.
    (define (json-hex-digit-value char)
      "Return CHAR's hexadecimal value, or #f when CHAR is not hex."
      (let ((code (char->integer char)))
        (cond
         ((and (<= (char->integer #\0) code)
               (<= code (char->integer #\9)))
          (- code (char->integer #\0)))
         ((and (<= (char->integer #\a) code)
               (<= code (char->integer #\f)))
          (+ 10 (- code (char->integer #\a))))
         ((and (<= (char->integer #\A) code)
               (<= code (char->integer #\F)))
          (+ 10 (- code (char->integer #\A))))
         (else #f))))

    ;; Wrapper kept to isolate string indexing choices in one helper.
    (define (json-string-ref text index)
      "Return TEXT's character at INDEX."
      (string-ref text index))

    ;; Wrapper kept beside `json-string-ref' for parser symmetry.
    (define (json-string-length text)
      "Return TEXT's length in characters."
      (string-length text))

    ;; Recognize the character set that may appear inside JSON numbers.
    (define (json-number-char? char)
      "Return #t when CHAR may appear inside a JSON number token."
      (and (not (eof-object? char))
           (or (json-digit? char)
               (char=? char #\-)
               (char=? char #\+)
               (char=? char #\.)
               (char=? char #\e)
               (char=? char #\E))))

    ;; Delimiters mark the end of a JSON lexical token.
    (define (json-delimiter? char)
      "Return #t when CHAR ends the current JSON token."
      (or (eof-object? char)
          (json-whitespace? char)
          (char=? char #\,)
          (char=? char #\])
          (char=? char #\})))

    ;; Read a character while enforcing the configured character limit.
    (define (json-read-char port)
      "Read one character from PORT while enforcing the active limit."
      (let ((limit (json-number-of-character-limit))
            (count (json-character-count))
            (peeked (peek-char port)))
        (if (and limit
                 (not (eof-object? peeked))
                 (>= count limit))
            (json-fail "Maximum number of JSON characters reached."))
        (let ((char (read-char port)))
          (if (not (eof-object? char))
              (json-character-count (+ count 1)))
          char)))

    ;; Advance PORT past insignificant whitespace.
    (define (json-skip-whitespace port)
      "Skip JSON whitespace on PORT and return the next character."
      (let loop ()
        (let ((char (peek-char port)))
          (if (json-whitespace? char)
              (begin
                (json-read-char port)
                (loop))
              char))))

    ;; Consume the remaining literal characters after an already-read prefix.
    (define (json-expect-sequence port expected)
      "Read EXPECTED from PORT or raise a JSON error."
      (let loop ((chars (string->list expected)))
        (if (not (null? chars))
            (let ((char (json-read-char port)))
              (if (or (eof-object? char)
                      (not (char=? char (car chars))))
                  (json-fail "Unexpected JSON literal."))
              (loop (cdr chars))))))

    ;; Read four hexadecimal digits and return their numeric code.
    (define (json-read-hex4 port)
      "Read four hexadecimal digits from PORT and return their value."
      (let loop ((remaining 4) (value 0))
        (if (= remaining 0)
            value
            (let* ((char (json-read-char port))
                   (digit
                    (and (not (eof-object? char))
                         (json-hex-digit-value char))))
              (if (not digit)
                  (json-fail "Invalid JSON unicode escape."))
              (loop (- remaining 1) (+ (* value 16) digit))))))

    ;; Decode a JSON unicode escape, including surrogate pairs.
    (define (json-read-unicode-escape port)
      "Read and decode a JSON unicode escape from PORT."
      (let ((code (json-read-hex4 port)))
        (cond
         ((and (<= #xd800 code) (<= code #xdbff))
          (let ((slash (json-read-char port))
                (u (json-read-char port)))
            (if (or (eof-object? slash)
                    (eof-object? u)
                    (not (char=? slash #\\))
                    (not (char=? u #\u)))
                (json-fail "High surrogate must be followed by a low surrogate."))
            (let ((low (json-read-hex4 port)))
              (if (not (and (<= #xdc00 low) (<= low #xdfff)))
                  (json-fail "High surrogate must be followed by a low surrogate."))
              (integer->char
               (+ #x10000
                  (+ (* (- code #xd800) #x400)
                     (- low #xdc00)))))))
         ((and (<= #xdc00 code) (<= code #xdfff))
          (json-fail "Low surrogate cannot appear without a high surrogate."))
         (else (integer->char code)))))

    ;; Read a JSON string after its opening quote has been consumed.
    (define (json-read-string-body port)
      "Read a JSON string body from PORT and return a Scheme string."
      (let ((chars (gen:string-accumulator)))
        (let loop ()
          (let ((char (json-read-char port)))
            (cond
             ((eof-object? char)
              (json-fail "Unexpected end of JSON string."))
             ((char=? char #\")
              (chars (eof-object)))
             ((json-control-character? char)
              (json-fail "Unescaped control character in JSON string."))
             ((char=? char #\\)
              (let ((escaped (json-read-char port)))
                (cond
                 ((eof-object? escaped)
                  (json-fail "Unexpected end of JSON escape."))
                 ((char=? escaped #\")
                  (chars #\")
                  (loop))
                 ((char=? escaped #\\)
                  (chars #\\)
                  (loop))
                 ((char=? escaped #\/)
                  (chars #\/)
                  (loop))
                 ((char=? escaped #\b)
                  (chars (integer->char 8))
                  (loop))
                 ((char=? escaped #\f)
                  (chars (integer->char 12))
                  (loop))
                 ((char=? escaped #\n)
                  (chars #\newline)
                  (loop))
                 ((char=? escaped #\r)
                  (chars #\return)
                  (loop))
                 ((char=? escaped #\t)
                  (chars #\tab)
                  (loop))
                 ((char=? escaped #\u)
                  (chars (json-read-unicode-escape port))
                  (loop))
                 (else
                  (json-fail "Invalid JSON escape sequence.")))))
             (else
              (chars char)
              (loop)))))))

    ;; Validate JSON number grammar before delegating numeric conversion.
    (define (json-valid-number? text)
      "Return #t when TEXT satisfies the JSON number grammar."
      (let ((length (json-string-length text)))
        (define (at index) (json-string-ref text index))
        (define (scan-digits index)
          (let loop ((cursor index))
            (if (and (< cursor length) (json-digit? (at cursor)))
                (loop (+ cursor 1))
                cursor)))
        (define (parse-integer index)
          (if (>= index length)
              #f
              (let ((char (at index)))
                (cond
                 ((char=? char #\0)
                  (let ((next (+ index 1)))
                    (if (and (< next length) (json-digit? (at next)))
                        #f
                        next)))
                 ((json-nonzero-digit? char)
                  (scan-digits (+ index 1)))
                 (else #f)))))
        (define (parse-fraction index)
          (if (and (< index length) (char=? (at index) #\.))
              (let ((after-dot (+ index 1)))
                (if (or (>= after-dot length)
                        (not (json-digit? (at after-dot))))
                    #f
                    (scan-digits after-dot)))
              index))
        (define (parse-exponent index)
          (if (and (< index length)
                   (or (char=? (at index) #\e)
                       (char=? (at index) #\E)))
              (let* ((after-e (+ index 1))
                     (after-sign
                      (if (and (< after-e length)
                               (or (char=? (at after-e) #\+)
                                   (char=? (at after-e) #\-)))
                          (+ after-e 1)
                          after-e)))
                (if (or (>= after-sign length)
                        (not (json-digit? (at after-sign))))
                    #f
                    (scan-digits after-sign)))
              index))
        (if (= length 0)
            #f
            (let ((start (if (char=? (at 0) #\-) 1 0)))
              (and-let* ((integer-end (parse-integer start))
                         (fraction-end (parse-fraction integer-end))
                         (exponent-end (parse-exponent fraction-end)))
                (= exponent-end length))))))

    ;; Read and parse a JSON number whose first character has been consumed.
    (define (json-read-number port first)
      "Read a JSON number from PORT after FIRST has already been consumed."
      (let ((chars (gen:string-accumulator)))
        (chars first)
        (let loop ()
          (let ((char (peek-char port)))
            (cond
             ((json-number-char? char)
              (json-read-char port)
              (chars char)
              (loop))
             ((json-delimiter? char)
              (let* ((text (chars (eof-object)))
                     (number (and (json-valid-number? text)
                                  (string->number text))))
                (if number
                    number
                    (json-fail "Invalid JSON number."))))
             (else
              (json-fail "Invalid character after JSON number.")))))))

    ;; Enforce the configured recursive nesting limit.
    (define (json-check-depth depth)
      "Raise a JSON error when DEPTH exceeds the configured nesting limit."
      (let ((limit (json-nesting-depth-limit)))
        (if (and limit (>= depth limit))
            (json-fail "Maximum JSON nesting depth reached."))))

    ;; Read a JSON array into a Scheme vector.
    (define (json-read-array port depth read-value)
      "Read a JSON array from PORT at DEPTH using READ-VALUE."
      (json-check-depth depth)
      (json-skip-whitespace port)
      (if (char=? (peek-char port) #\])
          (begin
            (json-read-char port)
            '#())
          (let ((values (gen:vector-accumulator)))
            (let loop ()
              (let ((value (read-value (+ depth 1))))
                (json-skip-whitespace port)
                (let ((separator (json-read-char port)))
                  (cond
                   ((eof-object? separator)
                    (json-fail "Unexpected end of JSON array."))
                   ((char=? separator #\,)
                    (json-skip-whitespace port)
                    (if (char=? (peek-char port) #\])
                        (json-fail "Trailing comma in JSON array."))
                    (values value)
                    (loop))
                   ((char=? separator #\])
                    (values value)
                    (values (eof-object)))
                   (else
                    (json-fail
                     "Expected comma or close bracket in JSON array.")))))))))

    ;; Read a JSON object into an alist with symbol keys.
    (define (json-read-object port depth read-value)
      "Read a JSON object from PORT at DEPTH using READ-VALUE."
      (json-check-depth depth)
      (json-skip-whitespace port)
      (if (char=? (peek-char port) #\})
          (begin
            (json-read-char port)
            '())
          (let ((entries (gen:list-accumulator)))
            (let loop ()
              (json-skip-whitespace port)
              (let ((quote (json-read-char port)))
                (if (or (eof-object? quote) (not (char=? quote #\")))
                    (json-fail "Expected JSON object key."))
                (let ((key (json-read-string-body port)))
                  (json-skip-whitespace port)
                  (let ((colon (json-read-char port)))
                    (if (or (eof-object? colon) (not (char=? colon #\:)))
                        (json-fail "Expected colon after JSON object key."))
                    (let ((value (read-value (+ depth 1))))
                      (json-skip-whitespace port)
                      (let ((separator (json-read-char port)))
                        (cond
                         ((eof-object? separator)
                          (json-fail "Unexpected end of JSON object."))
                         ((char=? separator #\,)
                          (json-skip-whitespace port)
                          (if (char=? (peek-char port) #\})
                              (json-fail "Trailing comma in JSON object."))
                          (entries (cons (string->symbol key) value))
                          (loop))
                         ((char=? separator #\})
                          (entries (cons (string->symbol key) value))
                          (entries (eof-object)))
                         (else
                          (json-fail
                           "Expected comma or close brace in JSON object."))))))))))))

    ;; Read one complete JSON value from PORT.
    (define (json-read-from-port port)
      (define (read-value depth)
        (json-skip-whitespace port)
        (let ((char (json-read-char port)))
          (cond
           ((eof-object? char) (eof-object))
           ((char=? char #\") (json-read-string-body port))
           ((char=? char #\{) (json-read-object port depth read-value))
           ((char=? char #\[) (json-read-array port depth read-value))
           ((char=? char #\t)
            (json-expect-sequence port "rue")
            #t)
           ((char=? char #\f)
            (json-expect-sequence port "alse")
            #f)
           ((char=? char #\n)
            (json-expect-sequence port "ull")
            'null)
           ((or (json-digit? char) (char=? char #\-))
            (json-read-number port char))
           (else (json-fail "Unexpected character in JSON input.")))))
      "Read one complete JSON value from PORT."
      (json-character-count 0)
      (read-value 0))

    ;; Optional-arity dispatcher for the public JSON reader.
    (define (json-read-dispatch . maybe-port)
      "Dispatch optional JSON reader port arguments."
      (apply
       (case-lambda
       (() (json-read-from-port (current-input-port)))
       ((port) (json-read-from-port port)))
       maybe-port))

    (define (json-read . maybe-port)
      "Read one JSON value from a textual input port."
      #((parameters
         (maybe-port (type list)
          (description
           ("Optional textual input port. The current input port is"
             "used when omitted."))))
        (returns . "The decoded JSON value as Scheme data.")
        (effects port-io error))
      (apply json-read-dispatch maybe-port))

    ;; Optional-arity dispatcher for JSON value generators.
    (define (json-generator-dispatch . maybe-port)
      "Dispatch optional JSON generator port arguments."
      (apply
       (case-lambda
       (()
        (let ((port (current-input-port)))
          (lambda ()
            (json-read port))))
       ((port)
        (lambda ()
          (json-read port))))
       maybe-port))

    (define (json-generator . maybe-port)
      "Return a generator that reads one JSON value at a time."
      #((parameters
         (maybe-port (type list)
          (description
           ("Optional textual input port. The current input port is"
            "used when omitted."))))
        (returns (type procedure)
         (description "Thunk returning the next decoded JSON value."))
        (effects port-io error))
      (apply json-generator-dispatch maybe-port))

    ;; Optional-arity dispatcher for JSON lines readers.
    (define (json-lines-read-dispatch . maybe-port)
      "Dispatch optional JSON lines reader port arguments."
      (apply
       (case-lambda
       (() (json-generator))
       ((port) (json-generator port)))
       maybe-port))

    (define (json-lines-read . maybe-port)
      "Return a generator that reads consecutive JSON values."
      #((parameters
         (maybe-port (type list)
          (description
           ("Optional textual input port. The current input port is"
            "used when omitted."))))
        (returns (type procedure)
         (description "Thunk returning the next decoded JSON value."))
        (effects port-io error))
      (apply json-lines-read-dispatch maybe-port))

    ;; Optional-arity dispatcher for JSON sequence readers.
    (define (json-sequence-read-dispatch . maybe-port)
      "Dispatch optional JSON sequence reader port arguments."
      (apply
       (case-lambda
       (() (json-generator))
       ((port) (json-generator port)))
       maybe-port))

    (define (json-sequence-read . maybe-port)
      "Return a generator that reads consecutive JSON sequence values."
      #((parameters
         (maybe-port (type list)
          (description
           ("Optional textual input port. The current input port is"
            "used when omitted."))))
        (returns (type procedure)
         (description "Thunk returning the next decoded JSON sequence value."))
        (effects port-io error))
      (apply json-sequence-read-dispatch maybe-port))

    (define (json-fold proc array-start array-end object-start object-end seed
                       . maybe-port)
      "Fold over a decoded JSON value using SRFI 180-style callbacks."
      #((parameters
         (proc (type procedure)
          (description "Callback applied to scalar and completed containers."))
         (array-start (type procedure)
          (description "Callback that starts array accumulation."))
         (array-end (type procedure)
          (description "Callback that completes array accumulation."))
         (object-start (type procedure)
          (description "Callback that starts object accumulation."))
         (object-end (type procedure)
          (description "Callback that completes object accumulation."))
         (seed . "Initial fold state.")
         (maybe-port (type list)
          (description
           ("Optional textual input port. The current input port is"
            "used when omitted."))))
        (returns . "The completed fold state.")
        (effects port-io error))
      (letrec
          ((walk
            (lambda (datum state)
              (cond
               ((vector? datum)
                (let ((array-state
                       (gen:generator-fold
                        (lambda (item item-state) (walk item item-state))
                        (array-start state)
                        (gen:vector->generator datum))))
                  (proc (array-end array-state) state)))
               ((pair? datum)
                (let ((object-state
                       (gen:generator-fold
                        (lambda (entry entry-state)
                          (walk (cdr entry) (proc (car entry) entry-state)))
                        (object-start state)
                        (gen:list->generator datum))))
                  (proc (object-end object-state) state)))
               (else (proc datum state))))))
        (let ((value (apply json-read maybe-port)))
          (if (eof-object? value) seed (walk value seed)))))

    ;; Build an emitter procedure around a textual output port.
    (define (json-emit-port port)
      "Return an emitter procedure that writes fragments to PORT."
      (lambda (char-or-string)
        (cond
         ((char? char-or-string) (write-char char-or-string port))
         ((string? char-or-string) (write-string char-or-string port))
         (else (json-fail "JSON output expected a character or string.")))))

    ;; Emit CODE as a four-digit JSON unicode escape.
    (define (json-write-hex4 code emit)
      "Emit CODE as a four-digit JSON unicode escape through EMIT."
      (let* ((hex (number->string code 16))
             (length (string-length hex)))
        (emit "\\u")
        (let loop ((count (- 4 length)))
          (if (> count 0)
              (begin
                (emit #\0)
                (loop (- count 1)))))
        (emit hex)))

    ;; Emit TEXT with JSON string escaping.
    (define (json-write-string-value text emit)
      "Emit TEXT as a JSON string through EMIT."
      (emit #\")
      (string-for-each
       (lambda (char)
         (cond
          ((char=? char #\") (emit "\\\""))
          ((char=? char #\\) (emit "\\\\"))
          ((char=? char #\/) (emit "\\/"))
          ((char=? char (integer->char 8)) (emit "\\b"))
          ((char=? char (integer->char 12)) (emit "\\f"))
          ((char=? char #\newline) (emit "\\n"))
          ((char=? char #\return) (emit "\\r"))
          ((char=? char #\tab) (emit "\\t"))
          ((json-control-character? char)
           (json-write-hex4 (char->integer char) emit))
          (else (emit char))))
       text)
      (emit #\"))

    ;; Reject numbers JSON cannot represent portably.
    (define (json-valid-number-value? value)
      "Return #t when VALUE can be represented as a JSON number."
      (and (number? value)
           (real? value)
           (or (and (exact? value) (= (denominator value) 1))
               (and (inexact? value)
                    (not (= value +inf.0))
                    (not (= value -inf.0))
                    (= value value)))))

    ;; Emit DATUM as JSON through EMIT.
    (define (json-write-value datum emit)
      "Emit DATUM as JSON through EMIT."
      (cond
       ((json-null? datum) (emit "null"))
       ((boolean? datum) (emit (if datum "true" "false")))
       ((string? datum) (json-write-string-value datum emit))
       ((json-valid-number-value? datum) (emit (number->string datum)))
       ((vector? datum)
        (emit #\[)
        (let ((first? #t))
          (gen:generator-for-each
           (lambda (value)
             (if first?
                 (set! first? #f)
                 (emit #\,))
             (json-write-value value emit))
           (gen:vector->generator datum)))
        (emit #\]))
       ((null? datum)
        (emit #\{)
        (emit #\}))
       ((pair? datum)
        (emit #\{)
        (let ((first? #t))
          (gen:generator-for-each
           (lambda (entry)
             (if (not (and (pair? entry) (symbol? (car entry))))
                 (json-fail "JSON object entries must be symbol pairs."))
             (if first?
                 (set! first? #f)
                 (emit #\,))
             (json-write-string-value (symbol->string (car entry)) emit)
             (emit #\:)
             (json-write-value (cdr entry) emit))
           (gen:list->generator datum)))
        (emit #\}))
       (else
        (json-fail "Value cannot be encoded as JSON."))))

    (define (json-write-target datum target)
      "Write DATUM as JSON to TARGET, a port or accumulator procedure."
      (let ((emit (if (procedure? target) target (json-emit-port target))))
        (json-write-value datum emit)
        (json-unspecified)))

    ;; Optional-arity dispatcher for the public JSON writer.
    (define (json-write-dispatch datum . maybe-target)
      "Dispatch optional JSON writer target arguments."
      (apply
       (case-lambda
       ((datum) (json-write-target datum (current-output-port)))
       ((datum target) (json-write-target datum target)))
       datum
       maybe-target))

    (define (json-write datum . maybe-port-or-accumulator)
      "Write DATUM as JSON to a port or accumulator procedure."
      #((parameters
         (datum . "Scheme datum to lower to JSON.")
         (maybe-port-or-accumulator (type list)
          (description
           ("Optional textual output port or accumulator procedure."
             "The current output port is used when omitted."))))
        (returns . "The unspecified value.")
        (effects port-io error))
      (apply json-write-dispatch datum maybe-port-or-accumulator))

    (define (json-accumulator accumulator)
      "Return a small SRFI 180 event accumulator over ACCUMULATOR."
      #((parameters
         (accumulator (type procedure)
          (description "Procedure receiving JSON output fragments.")))
        (returns (type procedure)
         (description "Procedure accepting SRFI 180-style JSON events."))
        (effects procedure-call error))
      (lambda (event)
        (cond
         ((and (pair? event) (eq? (car event) 'json-value))
          (json-write (cdr event) accumulator))
         ((and (pair? event) (eq? (car event) 'json-structure))
          (case (cdr event)
            ((array-start) (accumulator #\[))
            ((array-end) (accumulator #\]))
            ((object-start) (accumulator #\{))
            ((object-end) (accumulator #\}))
            (else (json-fail "Unknown JSON structure event."))))
         (else
          (json-fail "Unknown JSON accumulator event.")))))))
