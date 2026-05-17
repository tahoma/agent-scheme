;;; Portable R7RS datum reader for Agent Scheme.
;;;
;;; This library mirrors the Emacs Lisp reader in portable Scheme.  It returns
;;; native Scheme datums, but it still enforces the same resource limits and
;;; reader-directive behavior so portable bootstrap tests exercise the same
;;; language boundary.

(define-library (agent-scheme reader)
  (export agent-scheme-read
          agent-scheme-read-all
          agent-scheme-validate-datum
          agent-scheme-datum->external)
  (import (scheme base)
          (scheme char)
          (scheme write))
  (begin
    ;; Per-run defaults match the Emacs Lisp host reader.  Callers can override
    ;; them with an association list, using keys such as `max-depth'.
    (define agent-scheme-default-maximum-depth 256)
    (define agent-scheme-default-maximum-list-length 100000)
    (define agent-scheme-default-maximum-vector-length 100000)
    (define agent-scheme-default-maximum-bytevector-length 100000)
    (define agent-scheme-default-maximum-string-size 1048576)
    (define agent-scheme-default-maximum-total-nodes 1000000)

    (define-record-type <reader>
      ;; Reader state is mutable only for cursor position, fold-case mode, and
      ;; node count.  SOURCE remains the immutable snapshot of input text.
      (make-reader source position length fold-case node-count
                   maximum-depth maximum-list-length maximum-vector-length
                   maximum-bytevector-length maximum-string-size
                   maximum-total-nodes)
      reader?
      (source reader-source)
      (position reader-position set-reader-position!)
      (length reader-length)
      (fold-case reader-fold-case set-reader-fold-case!)
      (node-count reader-node-count set-reader-node-count!)
      (maximum-depth reader-maximum-depth)
      (maximum-list-length reader-maximum-list-length)
      (maximum-vector-length reader-maximum-vector-length)
      (maximum-bytevector-length reader-maximum-bytevector-length)
      (maximum-string-size reader-maximum-string-size)
      (maximum-total-nodes reader-maximum-total-nodes))

    (define-record-type <validation>
      ;; Validation walks host-created datums after parsing.  It has its own
      ;; counter so callers cannot bypass node limits by constructing values.
      (make-validation node-count maximum-total-nodes)
      validation?
      (node-count validation-node-count set-validation-node-count!)
      (maximum-total-nodes validation-maximum-total-nodes))

    (define char-page (integer->char 12))

    (define (option-ref options key default)
      (let ((cell (assq key options)))
        (if cell (cdr cell) default)))

    (define (reader-from-source source options)
      (if (not (string? source))
          (error "agent-scheme reader source must be a string" source)
          (make-reader source
                       0
                       (string-length source)
                       #f
                       0
                       (option-ref options 'max-depth
                                   agent-scheme-default-maximum-depth)
                       (option-ref options 'max-list-length
                                   agent-scheme-default-maximum-list-length)
                       (option-ref options 'max-vector-length
                                   agent-scheme-default-maximum-vector-length)
                       (option-ref options 'max-bytevector-length
                                   agent-scheme-default-maximum-bytevector-length)
                       (option-ref options 'max-string-size
                                   agent-scheme-default-maximum-string-size)
                       (option-ref options 'max-total-nodes
                                   agent-scheme-default-maximum-total-nodes))))

    (define (reader-error reader message . irritants)
      (apply error
             (string-append
              "agent-scheme reader error at offset "
              (number->string (reader-position reader))
              ": "
              message)
             irritants))

    (define (limit-error reader message . irritants)
      (apply error
             (string-append
              "agent-scheme datum limit error at offset "
              (number->string (reader-position reader))
              ": "
              message)
             irritants))

    (define (check-depth reader depth)
      (if (> depth (reader-maximum-depth reader))
          (limit-error reader
                       "datum depth exceeds maximum depth"
                       depth
                       (reader-maximum-depth reader))))

    (define (note-node! reader)
      (set-reader-node-count! reader (+ (reader-node-count reader) 1))
      (if (> (reader-node-count reader) (reader-maximum-total-nodes reader))
          (limit-error reader
                       "datum node count exceeds maximum total nodes"
                       (reader-maximum-total-nodes reader))))

    (define (eof? reader)
      (>= (reader-position reader) (reader-length reader)))

    (define (peek reader . maybe-offset)
      (let* ((offset (if (null? maybe-offset) 0 (car maybe-offset)))
             (index (+ (reader-position reader) offset)))
        (if (< index (reader-length reader))
            (string-ref (reader-source reader) index)
            #f)))

    (define (advance! reader . maybe-count)
      (let ((count (if (null? maybe-count) 1 (car maybe-count))))
        (set-reader-position! reader (+ (reader-position reader) count))))

    (define (starts-with? reader text)
      (let ((position (reader-position reader))
            (end (+ (reader-position reader) (string-length text))))
        (and (<= end (reader-length reader))
             (string=? text
                       (substring (reader-source reader)
                                  position
                                  end)))))

    (define (whitespace? char)
      (and char
           (or (char=? char #\space)
               (char=? char #\tab)
               (char=? char #\newline)
               (char=? char #\return)
               (char=? char char-page))))

    (define (intraline-whitespace? char)
      (and char
           (or (char=? char #\space)
               (char=? char #\tab))))

    (define (delimiter? char)
      (or (not char)
          (whitespace? char)
          (char=? char #\|)
          (char=? char #\()
          (char=? char #\))
          (char=? char #\")
          (char=? char #\;)))

    (define (reserved? char)
      (and char
           (or (char=? char #\[)
               (char=? char #\])
               (char=? char #\{)
               (char=? char #\}))))

    (define (skip-line-comment! reader)
      (let loop ()
        (if (and (not (eof? reader))
                 (let ((char (peek reader)))
                   (and (not (char=? char #\newline))
                        (not (char=? char #\return)))))
            (begin
              (advance! reader)
              (loop))))
      (if (and (peek reader) (char=? (peek reader) #\return))
          (begin
            (advance! reader)
            (if (and (peek reader) (char=? (peek reader) #\newline))
                (advance! reader))))
      (if (and (peek reader) (char=? (peek reader) #\newline))
          (advance! reader)))

    (define (skip-nested-comment! reader)
      (let loop ((depth 0))
        (cond
         ((and (= depth 0) (not (starts-with? reader "#|")))
          #t)
         ((eof? reader)
          (reader-error reader "unterminated block comment"))
         ((starts-with? reader "#|")
          (advance! reader 2)
          (loop (+ depth 1)))
         ((starts-with? reader "|#")
          (advance! reader 2)
          (loop (- depth 1)))
         (else
          (advance! reader)
          (loop depth)))))

    (define (skip-directive! reader)
      (cond
       ((and (starts-with? reader "#!fold-case")
             (delimiter? (peek reader 11)))
        (set-reader-fold-case! reader #t)
        (advance! reader 11))
       ((and (starts-with? reader "#!no-fold-case")
             (delimiter? (peek reader 14)))
        (set-reader-fold-case! reader #f)
        (advance! reader 14))
       (else
        (reader-error reader "unknown reader directive"))))

    (define (skip-intertoken-space! reader depth)
      (let loop ()
        (cond
         ((whitespace? (peek reader))
          (advance! reader)
          (loop))
         ((and (peek reader) (char=? (peek reader) #\;))
          (skip-line-comment! reader)
          (loop))
         ((starts-with? reader "#|")
          (skip-nested-comment! reader)
          (loop))
         ((starts-with? reader "#!")
          (skip-directive! reader)
          (loop))
         ((starts-with? reader "#;")
          (advance! reader 2)
          ;; A datum comment consumes a full datum, including nested comments
          ;; and directives, so keep using the active reader state.
          (skip-intertoken-space! reader depth)
          (read-datum reader depth)
          (loop))
         (else
          #t))))

    (define (read-token reader)
      (let ((start (reader-position reader)))
        (let loop ()
          (if (not (delimiter? (peek reader)))
              (begin
                (if (reserved? (peek reader))
                    (reader-error reader
                                  "reserved character in token"
                                  (peek reader)))
                (advance! reader)
                (loop))))
        (substring (reader-source reader) start (reader-position reader))))

    (define (hex-digit-value char)
      (cond
       ((and (char>=? char #\0) (char<=? char #\9))
        (- (char->integer char) (char->integer #\0)))
       ((and (char>=? char #\a) (char<=? char #\f))
        (+ 10 (- (char->integer char) (char->integer #\a))))
       ((and (char>=? char #\A) (char<=? char #\F))
        (+ 10 (- (char->integer char) (char->integer #\A))))
       (else
        #f)))

    (define (hex-scalar->char reader digits)
      (if (= (string-length digits) 0)
          (reader-error reader "invalid hexadecimal scalar escape"))
      (let loop ((index 0) (value 0))
        (if (= index (string-length digits))
            (begin
              (if (or (> value #x10ffff)
                      (and (>= value #xd800) (<= value #xdfff)))
                  (reader-error reader
                                "invalid Unicode scalar value"
                                value))
              (integer->char value))
            (let ((digit (hex-digit-value (string-ref digits index))))
              (if digit
                  (loop (+ index 1) (+ (* value 16) digit))
                  (reader-error reader
                                "invalid hexadecimal scalar escape"
                                digits))))))

    (define (read-hex-escape reader)
      (let ((start (reader-position reader)))
        (let loop ()
          (if (and (not (eof? reader))
                   (not (char=? (peek reader) #\;)))
              (begin
                (advance! reader)
                (loop))))
        (if (eof? reader)
            (reader-error reader "unterminated hexadecimal escape"))
        (let ((digits (substring (reader-source reader)
                                 start
                                 (reader-position reader))))
          (advance! reader)
          (hex-scalar->char reader digits))))

    (define (mnemonic-escape reader char)
      (cond
       ((char=? char #\a) (integer->char 7))
       ((char=? char #\b) (integer->char 8))
       ((char=? char #\t) #\tab)
       ((char=? char #\n) #\newline)
       ((char=? char #\r) #\return)
       ((char=? char #\") #\")
       ((char=? char #\\) #\\)
       ((char=? char #\|) #\|)
       (else
        (reader-error reader "unknown escape sequence" char))))

    (define (read-string-literal reader)
      (advance! reader)
      (let ((result '())
            (size 0))
        (define (emit! char)
          (set! size (+ size 1))
          (if (> size (reader-maximum-string-size reader))
              (limit-error reader
                           "string size exceeds maximum string size"
                           (reader-maximum-string-size reader)))
          (set! result (cons char result)))
        (define (skip-line-continuation!)
          (let loop-leading ()
            (if (intraline-whitespace? (peek reader))
                (begin
                  (advance! reader)
                  (loop-leading))))
          (cond
           ((and (peek reader) (char=? (peek reader) #\return))
            (advance! reader)
            (if (and (peek reader) (char=? (peek reader) #\newline))
                (advance! reader)))
           ((and (peek reader) (char=? (peek reader) #\newline))
            (advance! reader))
           (else
            (reader-error reader
                          "expected line ending in string continuation")))
          (let loop-trailing ()
            (if (intraline-whitespace? (peek reader))
                (begin
                  (advance! reader)
                  (loop-trailing)))))
        (let loop ()
          (cond
           ((eof? reader)
            (reader-error reader "unterminated string"))
           ((char=? (peek reader) #\")
            (advance! reader)
            (list->string (reverse result)))
           ((char=? (peek reader) #\\)
            (advance! reader)
            (let ((escaped (peek reader)))
              (cond
               ((not escaped)
                (reader-error reader "unterminated string escape"))
               ((char=? escaped #\x)
                (advance! reader)
                (emit! (read-hex-escape reader))
                (loop))
               ((or (intraline-whitespace? escaped)
                    (char=? escaped #\newline)
                    (char=? escaped #\return))
                (skip-line-continuation!)
                (loop))
               (else
                (advance! reader)
                (emit! (mnemonic-escape reader escaped))
                (loop)))))
           (else
            (emit! (peek reader))
            (advance! reader)
            (loop))))))

    (define (read-vertical-symbol-name reader)
      (advance! reader)
      (let ((result '()))
        (let loop ()
          (cond
           ((eof? reader)
            (reader-error reader "unterminated vertical symbol"))
           ((char=? (peek reader) #\|)
            (advance! reader)
            (let ((name (list->string (reverse result))))
              (if (reader-fold-case reader)
                  (string-foldcase name)
                  name)))
           ((char=? (peek reader) #\\)
            (advance! reader)
            (let ((escaped (peek reader)))
              (cond
               ((not escaped)
                (reader-error reader "unterminated vertical symbol escape"))
               ((char=? escaped #\x)
                (advance! reader)
                (set! result (cons (read-hex-escape reader) result))
                (loop))
               (else
                (advance! reader)
                (set! result
                      (cons (mnemonic-escape reader escaped) result))
                (loop)))))
           (else
            (set! result (cons (peek reader) result))
            (advance! reader)
            (loop))))))

    (define (char-in-string? char string)
      (let loop ((index 0))
        (and (< index (string-length string))
             (or (char=? char (string-ref string index))
                 (loop (+ index 1))))))

    (define (ascii-letter? char)
      (or (and (char>=? char #\a) (char<=? char #\z))
          (and (char>=? char #\A) (char<=? char #\Z))))

    (define (initial-char? char)
      (or (ascii-letter? char)
          (> (char->integer char) 127)
          (char-in-string? char "!$%&*/:<=>?@^_~")))

    (define (subsequent-char? char)
      (or (initial-char? char)
          (and (char>=? char #\0) (char<=? char #\9))
          (char-in-string? char "+-.@")))

    (define (sign-subsequent-char? char)
      (or (initial-char? char)
          (char-in-string? char "+-@")))

    (define (dot-subsequent-char? char)
      (or (sign-subsequent-char? char)
          (char=? char #\.)))

    (define (all-chars? string start predicate)
      (let loop ((index start))
        (or (= index (string-length string))
            (and (predicate (string-ref string index))
                 (loop (+ index 1))))))

    (define (identifier-token? token)
      (let ((length (string-length token)))
        (cond
         ((= length 0) #f)
         ((string=? token ".") #f)
         ((or (string=? token "+") (string=? token "-")) #t)
         ((initial-char? (string-ref token 0))
          (all-chars? token 1 subsequent-char?))
         ((and (or (char=? (string-ref token 0) #\+)
                   (char=? (string-ref token 0) #\-))
               (> length 1)
               (sign-subsequent-char? (string-ref token 1)))
          (all-chars? token 2 subsequent-char?))
         ((and (or (char=? (string-ref token 0) #\+)
                   (char=? (string-ref token 0) #\-))
               (> length 2)
               (char=? (string-ref token 1) #\.)
               (dot-subsequent-char? (string-ref token 2)))
          (all-chars? token 3 subsequent-char?))
         ((and (char=? (string-ref token 0) #\.)
               (> length 1)
               (dot-subsequent-char? (string-ref token 1)))
          (all-chars? token 2 subsequent-char?))
         (else #f))))

    (define (read-character-literal reader)
      (advance! reader 2)
      (if (eof? reader)
          (reader-error reader "missing character after #\\"))
      (let* ((token (read-token reader))
             (name (if (reader-fold-case reader)
                       (string-foldcase token)
                       token)))
        (cond
         ((= (string-length token) 0)
          (reader-error reader "missing character after #\\"))
         ((and (> (string-length token) 1)
               (or (char=? (string-ref token 0) #\x)
                   (char=? (string-ref token 0) #\X)))
          (hex-scalar->char reader (substring token 1 (string-length token))))
         ((string=? name "alarm") (integer->char 7))
         ((string=? name "backspace") (integer->char 8))
         ((string=? name "delete") (integer->char 127))
         ((string=? name "escape") (integer->char 27))
         ((string=? name "newline") #\newline)
         ((string=? name "null") (integer->char 0))
         ((string=? name "return") #\return)
         ((string=? name "space") #\space)
         ((string=? name "tab") #\tab)
         ((= (string-length token) 1) (string-ref token 0))
         (else
          (reader-error reader "unknown character literal" token)))))

    (define (classify-token reader token)
      (cond
       ((or (string=? token "#t") (string=? token "#true")) #t)
       ((or (string=? token "#f") (string=? token "#false")) #f)
       ((string->number token) => (lambda (number) number))
       ((identifier-token? token)
        (string->symbol
         (if (reader-fold-case reader)
             (string-foldcase token)
             token)))
       ((string=? token ".")
        (reader-error reader "unexpected dot"))
       (else
        (reader-error reader "invalid token" token))))

    (define (read-list reader depth)
      (check-depth reader depth)
      (advance! reader)
      (let ((head '())
            (tail '())
            (count 0))
        (define (append! datum)
          (set! count (+ count 1))
          (if (> count (reader-maximum-list-length reader))
              (limit-error reader
                           "list length exceeds maximum list length"
                           (reader-maximum-list-length reader)))
          (let ((cell (cons datum '())))
            (if (null? tail)
                (begin
                  (set! head cell)
                  (set! tail cell))
                (begin
                  (set-cdr! tail cell)
                  (set! tail cell)))))
        (let loop ()
          (skip-intertoken-space! reader depth)
          (cond
           ((eof? reader)
            (reader-error reader "unterminated list"))
           ((char=? (peek reader) #\))
            (advance! reader)
            (note-node! reader)
            head)
           (else
            (let ((saved (reader-position reader)))
              ;; A period is dotted-tail syntax only when it is a delimited
              ;; token.  Otherwise restore the cursor and classify it normally.
              (if (and (char=? (peek reader) #\.)
                       (begin
                         (advance! reader)
                         (delimiter? (peek reader))))
                  (begin
                    (if (null? tail)
                        (reader-error reader "dot before list element"))
                    (skip-intertoken-space! reader depth)
                    (set-cdr! tail (read-datum reader (+ depth 1)))
                    (skip-intertoken-space! reader depth)
                    (if (not (and (peek reader)
                                  (char=? (peek reader) #\))))
                        (reader-error reader
                                      "expected closing parenthesis after dotted tail"))
                    (advance! reader)
                    (note-node! reader)
                    head)
                  (begin
                    (set-reader-position! reader saved)
                    (append! (read-datum reader (+ depth 1)))
                    (loop)))))))))

    (define (read-vector-elements reader depth kind close-char maximum-length)
      (check-depth reader depth)
      (let loop ((items '()) (count 0))
        (skip-intertoken-space! reader depth)
        (cond
         ((eof? reader)
          (reader-error reader "unterminated sequence" kind))
         ((char=? (peek reader) close-char)
          (advance! reader)
          (reverse items))
         ((char=? (peek reader) #\.)
          (reader-error reader "dot is not allowed in sequence" kind))
         (else
          (let ((datum (read-datum reader (+ depth 1)))
                (next-count (+ count 1)))
            (if (> next-count maximum-length)
                (limit-error reader
                             "sequence length exceeds maximum length"
                             kind
                             maximum-length))
            (loop (cons datum items) next-count))))))

    (define (exact-byte? datum)
      (and (integer? datum)
           (exact? datum)
           (<= 0 datum)
           (<= datum 255)))

    (define (list->bytevector bytes)
      (let* ((length (length bytes))
             (bytevector (make-bytevector length)))
        (let loop ((index 0) (rest bytes))
          (if (null? rest)
              bytevector
              (begin
                (bytevector-u8-set! bytevector index (car rest))
                (loop (+ index 1) (cdr rest)))))))

    (define (read-vector reader depth)
      (advance! reader 2)
      (let ((items (read-vector-elements
                    reader
                    depth
                    "vector"
                    #\)
                    (reader-maximum-vector-length reader))))
        (note-node! reader)
        (list->vector items)))

    (define (read-bytevector reader depth)
      (advance! reader 4)
      (let ((items (read-vector-elements
                    reader
                    depth
                    "bytevector"
                    #\)
                    (reader-maximum-bytevector-length reader))))
        (let loop ((rest items) (bytes '()))
          (cond
           ((null? rest)
            (note-node! reader)
            (list->bytevector (reverse bytes)))
           ((exact-byte? (car rest))
            (loop (cdr rest) (cons (car rest) bytes)))
           (else
            (reader-error reader
                          "bytevector element is not an exact byte"
                          (agent-scheme-datum->external (car rest))))))))

    (define (quote-datum name datum)
      (list (string->symbol name) datum))

    (define (read-dispatch reader depth)
      (cond
       ((starts-with? reader "#(") (read-vector reader depth))
       ((starts-with? reader "#u8(") (read-bytevector reader depth))
       ((starts-with? reader "#\\") (read-character-literal reader))
       ((let ((char (peek reader 1)))
          (and char (char>=? char #\0) (char<=? char #\9)))
        ;; Datum labels need graph-aware allocation and writing; reject them
        ;; until the runtime has explicit support for shared/circular datums.
        (reader-error reader "datum labels are not supported yet"))
       (else
        (classify-token reader (read-token reader)))))

    (define (read-datum reader depth)
      (check-depth reader depth)
      (skip-intertoken-space! reader depth)
      (if (eof? reader)
          (reader-error reader "unexpected end of input"))
      (let ((char (peek reader)))
        (cond
         ((char=? char #\() (read-list reader (+ depth 1)))
         ((char=? char #\))
          (reader-error reader "unexpected closing parenthesis"))
         ((char=? char #\")
          (let ((datum (read-string-literal reader)))
            (note-node! reader)
            datum))
         ((char=? char #\|)
          (let ((datum
                 (string->symbol (read-vertical-symbol-name reader))))
            (note-node! reader)
            datum))
         ((char=? char #\')
          (advance! reader)
          (let ((datum (quote-datum "quote"
                                    (read-datum reader (+ depth 1)))))
            (note-node! reader)
            datum))
         ((char=? char #\`)
          (advance! reader)
          (let ((datum (quote-datum "quasiquote"
                                    (read-datum reader (+ depth 1)))))
            (note-node! reader)
            datum))
         ((char=? char #\,)
          (advance! reader)
          (if (and (peek reader) (char=? (peek reader) #\@))
              (begin
                (advance! reader)
                (let ((datum
                       (quote-datum "unquote-splicing"
                                    (read-datum reader (+ depth 1)))))
                  (note-node! reader)
                  datum))
              (let ((datum (quote-datum "unquote"
                                        (read-datum reader (+ depth 1)))))
                (note-node! reader)
                datum)))
         ((char=? char #\#)
          (let ((datum (read-dispatch reader (+ depth 1))))
            (note-node! reader)
            datum))
         (else
          (let ((datum (classify-token reader (read-token reader))))
            (note-node! reader)
            datum)))))

    (define (options-from-rest maybe-options)
      (if (null? maybe-options) '() (car maybe-options)))

    (define (agent-scheme-read source . maybe-options)
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options))
             (datum (read-datum reader 0)))
        (skip-intertoken-space! reader 0)
        (if (not (eof? reader))
            (reader-error reader "unexpected trailing input"))
        (agent-scheme-validate-datum datum options)
        datum))

    (define (agent-scheme-read-all source . maybe-options)
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options)))
        (let loop ((datums '()))
          (skip-intertoken-space! reader 0)
          (if (eof? reader)
              (let ((result (reverse datums)))
                (let validate-loop ((rest result))
                  (if (null? rest)
                      result
                      (begin
                        (agent-scheme-validate-datum (car rest) options)
                        (validate-loop (cdr rest))))))
              (loop (cons (read-datum reader 0) datums))))))

    (define (validation-note-node! validation)
      (set-validation-node-count!
       validation
       (+ (validation-node-count validation) 1))
      (if (> (validation-node-count validation)
             (validation-maximum-total-nodes validation))
          (error "agent-scheme datum limit error: datum node count exceeds maximum total nodes"
                 (validation-maximum-total-nodes validation))))

    (define (validate-datum datum options validation depth seen)
      (if (> depth
             (option-ref options 'max-depth
                         agent-scheme-default-maximum-depth))
          (error "agent-scheme datum limit error: datum depth exceeds maximum depth"
                 depth))
      (cond
       ((or (boolean? datum)
            (symbol? datum)
            (char? datum)
            (number? datum))
        (validation-note-node! validation))
       ((string? datum)
        (if (> (string-length datum)
               (option-ref options 'max-string-size
                           agent-scheme-default-maximum-string-size))
            (error "agent-scheme datum limit error: string size exceeds maximum string size"
                   (option-ref options 'max-string-size
                               agent-scheme-default-maximum-string-size)))
        (validation-note-node! validation))
       ((bytevector? datum)
        (if (> (bytevector-length datum)
               (option-ref options 'max-bytevector-length
                           agent-scheme-default-maximum-bytevector-length))
            (error "agent-scheme datum limit error: bytevector length exceeds maximum bytevector length"
                   (option-ref options 'max-bytevector-length
                               agent-scheme-default-maximum-bytevector-length)))
        (let loop ((index 0))
          (if (< index (bytevector-length datum))
              (begin
                (if (not (exact-byte? (bytevector-u8-ref datum index)))
                    (error "agent-scheme reader error: bytevector contains invalid byte"
                           (bytevector-u8-ref datum index)))
                (loop (+ index 1)))))
        (validation-note-node! validation))
       ((null? datum)
        (validation-note-node! validation))
       ((pair? datum)
        (if (memq datum seen)
            #t
            (let loop ((cursor datum)
                       (count 0)
                       (next-seen (cons datum seen)))
              (cond
               ((pair? cursor)
                (let ((next-count (+ count 1)))
                  (if (> next-count
                         (option-ref options 'max-list-length
                                     agent-scheme-default-maximum-list-length))
                      (error "agent-scheme datum limit error: list length exceeds maximum list length"
                             (option-ref options 'max-list-length
                                         agent-scheme-default-maximum-list-length)))
                  (validation-note-node! validation)
                  (validate-datum (car cursor)
                                  options
                                  validation
                                  (+ depth 1)
                                  next-seen)
                  (loop (cdr cursor) next-count next-seen)))
               ((null? cursor) #t)
               (else
                (validate-datum cursor
                                options
                                validation
                                (+ depth 1)
                                next-seen))))))
       ((vector? datum)
        (if (memq datum seen)
            #t
            (begin
              (if (> (vector-length datum)
                     (option-ref options 'max-vector-length
                                 agent-scheme-default-maximum-vector-length))
                  (error "agent-scheme datum limit error: vector length exceeds maximum vector length"
                         (option-ref options 'max-vector-length
                                     agent-scheme-default-maximum-vector-length)))
              (validation-note-node! validation)
              (let loop ((index 0))
                (if (< index (vector-length datum))
                    (begin
                      (validate-datum (vector-ref datum index)
                                      options
                                      validation
                                      (+ depth 1)
                                      (cons datum seen))
                      (loop (+ index 1))))))))
       (else
        (error "agent-scheme reader error: datum contains unsupported object"
               datum))))

    (define (agent-scheme-validate-datum datum . maybe-options)
      (let* ((options (options-from-rest maybe-options))
             (validation
              (make-validation
               0
               (option-ref options 'max-total-nodes
                           agent-scheme-default-maximum-total-nodes))))
        (validate-datum datum options validation 0 '())
        datum))

    (define (escape-string text)
      (let loop ((index 0) (parts '()))
        (if (= index (string-length text))
            (apply string-append (reverse parts))
            (let ((char (string-ref text index)))
              (loop
               (+ index 1)
               (cons
                (cond
                 ((char=? char (integer->char 7)) "\\a")
                 ((char=? char (integer->char 8)) "\\b")
                 ((char=? char #\tab) "\\t")
                 ((char=? char #\newline) "\\n")
                 ((char=? char #\return) "\\r")
                 ((char=? char #\") "\\\"")
                 ((char=? char #\\) "\\\\")
                 ((char=? char #\|) "\\|")
                 (else (string char)))
                parts))))))

    (define (symbol-needs-bars? name)
      (or (not (identifier-token? name))
          (string->number name)))

    (define (write-symbol-name name)
      (if (symbol-needs-bars? name)
          (string-append "|" (escape-string name) "|")
          name))

    (define (write-character-datum char)
      (cond
       ((char=? char (integer->char 7)) "#\\alarm")
       ((char=? char (integer->char 8)) "#\\backspace")
       ((char=? char (integer->char 127)) "#\\delete")
       ((char=? char (integer->char 27)) "#\\escape")
       ((char=? char #\newline) "#\\newline")
       ((char=? char (integer->char 0)) "#\\null")
       ((char=? char #\return) "#\\return")
       ((char=? char #\space) "#\\space")
       ((char=? char #\tab) "#\\tab")
       (else (string-append "#\\" (string char)))))

    (define (join strings separator)
      (cond
       ((null? strings) "")
       ((null? (cdr strings)) (car strings))
       (else
        (let loop ((rest (cdr strings))
                   (result (car strings)))
          (if (null? rest)
              result
              (loop (cdr rest)
                    (string-append result separator (car rest))))))))

    (define (write-list datum)
      (let loop ((cursor datum) (parts '()))
        (cond
         ((pair? cursor)
          (loop (cdr cursor)
                (cons (agent-scheme-datum->external (car cursor)) parts)))
         ((null? cursor)
          (string-append "(" (join (reverse parts) " ") ")"))
         (else
          (string-append
           "("
           (join (reverse parts) " ")
           (if (null? parts) ". " " . ")
           (agent-scheme-datum->external cursor)
           ")")))))

    (define (bytevector->strings bytevector)
      (let loop ((index 0) (parts '()))
        (if (= index (bytevector-length bytevector))
            (reverse parts)
            (loop (+ index 1)
                  (cons (number->string (bytevector-u8-ref bytevector index))
                        parts)))))

    (define (vector->strings vector)
      (let loop ((index 0) (parts '()))
        (if (= index (vector-length vector))
            (reverse parts)
            (loop (+ index 1)
                  (cons (agent-scheme-datum->external
                         (vector-ref vector index))
                        parts)))))

    (define (agent-scheme-datum->external datum)
      ;; This writer is intentionally simple: it renders current bootstrap
      ;; datums but does not generate labels for shared or circular structure.
      (cond
       ((boolean? datum) (if datum "#t" "#f"))
       ((null? datum) "()")
       ((symbol? datum) (write-symbol-name (symbol->string datum)))
       ((char? datum) (write-character-datum datum))
       ((number? datum) (number->string datum))
       ((string? datum)
        (string-append "\"" (escape-string datum) "\""))
       ((bytevector? datum)
        (string-append "#u8("
                       (join (bytevector->strings datum) " ")
                       ")"))
       ((pair? datum) (write-list datum))
       ((vector? datum)
        (string-append "#("
                       (join (vector->strings datum) " ")
                       ")"))
       (else
        (error "agent-scheme reader error: cannot write unsupported datum"
               datum))))))
