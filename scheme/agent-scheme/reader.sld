;;; Portable R7RS datum reader for Agent Scheme.
;;;
;;; This library mirrors the Emacs Lisp reader in portable Scheme.  It returns
;;; native Scheme datums, but it still enforces the same resource limits and
;;; reader-directive behavior so portable bootstrap tests exercise the same
;;; language boundary.

(define-library (agent-scheme reader)
  (export agent-scheme-read
          agent-scheme-read-all
          agent-scheme-read-from-string-at
          agent-scheme-read-eof
          agent-scheme-read-eof?
          agent-scheme-datum-source
          agent-scheme-datum-source-set!
          agent-scheme-copy-datum-source!
          agent-scheme-validate-datum
          agent-scheme-datum->external
          agent-scheme-number?
          agent-scheme-number-lexeme
          agent-scheme-number-exactness
          agent-scheme-number-radix
          agent-scheme-number-kind
          agent-scheme-number-value
          agent-scheme-make-canonical-integer
          agent-scheme-make-canonical-decimal
          agent-scheme-make-canonical-rational
          agent-scheme-make-canonical-infnan
          agent-scheme-make-canonical-complex
          agent-scheme-number-zero?
          agent-scheme-number-negative?
          agent-scheme-number-abs
          agent-scheme-number->external
          agent-scheme-integer->radix-string
          agent-scheme-make-record-type
          agent-scheme-record-type?
          agent-scheme-record-type-name
          agent-scheme-record-type-fields
          agent-scheme-make-record
          agent-scheme-record?
          agent-scheme-record-type
          agent-scheme-record-fields)
  (import (scheme base)
          (scheme char)
          (scheme inexact)
          (scheme write))
  (begin
    ;; Default maximum nested datum depth accepted by the portable reader.
    (define agent-scheme-default-maximum-depth 256)
    ;; Default maximum list length accepted by the portable reader.
    (define agent-scheme-default-maximum-list-length 100000)
    ;; Default maximum vector length accepted by the portable reader.
    (define agent-scheme-default-maximum-vector-length 100000)
    ;; Default maximum bytevector length accepted by the portable reader.
    (define agent-scheme-default-maximum-bytevector-length 100000)
    ;; Default maximum string size accepted by the portable reader.
    (define agent-scheme-default-maximum-string-size 1048576)
    ;; Default maximum total datum node count accepted by reader validation.
    (define agent-scheme-default-maximum-total-nodes 1000000)

    ;; Reader records own one parse run's immutable source and mutable cursor.
    (define-record-type <reader>
      ;; Reader state is mutable only for cursor position, fold-case mode, and
      ;; node count.  SOURCE remains the immutable snapshot of input text.
      (make-reader source position length line-starts fold-case node-count datum-labels
                   maximum-depth maximum-list-length maximum-vector-length
                   maximum-bytevector-length maximum-string-size
                   maximum-total-nodes source-id source-metadata)
      reader?
      (source reader-source)
      (position reader-position set-reader-position!)
      (length reader-length)
      (line-starts reader-line-starts)
      (fold-case reader-fold-case set-reader-fold-case!)
      (node-count reader-node-count set-reader-node-count!)
      (datum-labels reader-datum-labels set-reader-datum-labels!)
      (maximum-depth reader-maximum-depth)
      (maximum-list-length reader-maximum-list-length)
      (maximum-vector-length reader-maximum-vector-length)
      (maximum-bytevector-length reader-maximum-bytevector-length)
      (maximum-string-size reader-maximum-string-size)
      (maximum-total-nodes reader-maximum-total-nodes)
      (source-id reader-source-id)
      (source-metadata reader-source-metadata))

    ;; Validation records own the post-read resource budget for host datums.
    (define-record-type <validation>
      ;; Validation walks host-created datums after parsing.  It has its own
      ;; counter so callers cannot bypass node limits by constructing values.
      (make-validation node-count maximum-total-nodes)
      validation?
      (node-count validation-node-count set-validation-node-count!)
      (maximum-total-nodes validation-maximum-total-nodes))

    ;; The exported EOF sentinel lets incremental readers distinguish end of
    ;; input from any Scheme datum a source string can contain.
    (define-record-type <agent-scheme-read-eof>
      (make-agent-scheme-read-eof)
      agent-scheme-read-eof?)

    ;; Singleton EOF sentinel returned by incremental reader calls at end of
    ;; input.
    (define agent-scheme-read-eof (make-agent-scheme-read-eof))

    ;; Identity side table for source metadata.  It keeps metadata auxiliary so
    ;; ordinary datum equality and external writing remain R7RS datums.
    (define agent-scheme-source-metadata '())

    ;; Cap for the portable source side table.  Portable R7RS has no weak hash
    ;; table, so long-lived sessions trade older source lookups for bounded
    ;; metadata scans.  Keep this above ordinary form size so one read does not
    ;; evict its own active source metadata.
    (define agent-scheme-source-metadata-limit 1000)

    ;; Current number of retained source metadata entries in the portable table.
    (define agent-scheme-source-metadata-count 0)

    ;; Agent-owned numbers preserve lexical exactness, radix, and special
    ;; values instead of trusting the host Scheme's numeric tower to round-trip.
    (define-record-type <agent-scheme-number>
      ;; Agent Scheme owns numeric syntax even in the portable implementation.
      ;; Host numbers are used only as representation pieces inside this datum.
      (make-agent-scheme-number lexeme exactness radix kind value)
      agent-scheme-number?
      (lexeme agent-scheme-number-lexeme)
      (exactness agent-scheme-number-exactness)
      (radix agent-scheme-number-radix)
      (kind agent-scheme-number-kind)
      (value agent-scheme-number-value))

    ;; Portable record metadata belongs to Agent Scheme, not the host record
    ;; system, so evaluator-created records remain printable datums.
    (define-record-type <agent-scheme-record-type>
      (agent-scheme-make-record-type name fields)
      agent-scheme-record-type?
      (name agent-scheme-record-type-name)
      (fields agent-scheme-record-type-fields))

    ;; Portable record instances pair Agent Scheme record metadata with field
    ;; storage that the evaluator owns and may mutate through generated setters.
    (define-record-type <agent-scheme-record>
      (agent-scheme-make-record type fields)
      agent-scheme-record?
      (type agent-scheme-record-type)
      (fields agent-scheme-record-fields))

    ;; Datum-label records hold placeholders while resolving shared and circular
    ;; datum syntax; FILLED guards references to labels before their value lands.
    (define-record-type <datum-label>
      (make-datum-label id filled value)
      datum-label?
      (id datum-label-id)
      (filled datum-label-filled? set-datum-label-filled!)
      (value datum-label-value set-datum-label-value!))

    ;; Character constant for R7RS page whitespace.
    (define char-page (integer->char 12))

    (define (agent-scheme-integer->radix-string integer radix)
      "Exported writer helper used by the reader, evaluator, and tests whenever Agent Scheme needs canonical integer text independent of host formatting."
      (let ((digits "0123456789abcdef")
            (negative? (< integer 0))
            (value (abs integer)))
        (let loop ((remaining value) (parts '()))
          (if (zero? remaining)
              (let ((body
                     (if (null? parts)
                         "0"
                         (list->string parts))))
                (if negative? (string-append "-" body) body))
              (let* ((digit (modulo remaining radix))
                     (next (quotient remaining radix)))
                (loop next (cons (string-ref digits digit) parts)))))))

    (define (option-ref options key default)
      "Return the option value for KEY or DEFAULT when KEY is absent."
      (let ((cell (assq key options)))
        (if cell (cdr cell) default)))

    (define (source-line-starts source)
      "Return a vector of zero-based offsets where each source line starts."
      (let ((length (string-length source)))
        (let loop ((index 0) (starts '(0)))
          (if (= index length)
              (list->vector (reverse starts))
              (loop (+ index 1)
                    (if (and (char=? (string-ref source index) #\newline)
                             (< (+ index 1) length))
                        (cons (+ index 1) starts)
                        starts))))))

    (define (reader-from-source source options)
      "Create a reader state object from SOURCE and per-run option overrides."
      (if (not (string? source))
          (error "agent-scheme reader source must be a string" source)
          (let ((source-metadata
                 (option-ref options 'source-metadata #t)))
            (make-reader source
                         0
                         (string-length source)
                         (if source-metadata (source-line-starts source) #f)
                         #f
                         0
                         '()
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
                                     agent-scheme-default-maximum-total-nodes)
                         (if source-metadata
                             (option-ref options 'source-id #f)
                             #f)
                         source-metadata))))

    (define (source-field name value)
      "Build one Scheme-readable source metadata field."
      (list name value))

    (define (line-starts-line-column starts offset)
      "Return one-based (LINE . COLUMN) from STARTS at OFFSET."
      (let ((count (vector-length starts)))
        (let loop ((low 0) (high (- count 1)) (best 0))
          (if (> low high)
              (let ((line-start (vector-ref starts best)))
                (cons (+ best 1)
                      (+ (- offset line-start) 1)))
              (let* ((middle (quotient (+ low high) 2))
                     (line-start (vector-ref starts middle)))
                (if (<= line-start offset)
                    (loop (+ middle 1) high middle)
                    (loop low (- middle 1) best)))))))

    (define (reader-line-column reader offset)
      "Return one-based (LINE . COLUMN) in READER at OFFSET."
      (line-starts-line-column (reader-line-starts reader) offset))

    (define (source-note reader start end)
      "Return compact source metadata for READER between START and END."
      (let ((line-column (reader-line-column reader start)))
        (vector 'source-note
                (reader-source-id reader)
                (car line-column)
                (cdr line-column)
                start
                (max 0 (- end start)))))

    (define (source-note? datum)
      "Report whether DATUM is compact source metadata."
      (and (vector? datum)
           (= (vector-length datum) 6)
           (eq? (vector-ref datum 0) 'source-note)))

    (define (source-metadata->record metadata)
      "Return Scheme-readable source metadata for METADATA."
      (if (source-note? metadata)
          (list 'source
                (source-field 'origin 'source)
                (source-field 'source-id (vector-ref metadata 1))
                (source-field 'line
                              (agent-scheme-make-canonical-integer
                               (vector-ref metadata 2)))
                (source-field 'column
                              (agent-scheme-make-canonical-integer
                               (vector-ref metadata 3)))
                (source-field 'offset
                              (agent-scheme-make-canonical-integer
                               (vector-ref metadata 4)))
                (source-field 'span
                              (agent-scheme-make-canonical-integer
                               (vector-ref metadata 5)))
                (source-field 'phase 'read))
          metadata))

    (define (source-attachable? datum)
      "Report whether DATUM has stable identity for source metadata."
      (or (pair? datum)
          (vector? datum)
          (string? datum)
          (bytevector? datum)
          (agent-scheme-number? datum)
          (agent-scheme-record? datum)
          (agent-scheme-record-type? datum)))

    (define (agent-scheme-datum-source-set! datum source)
      "Attach SOURCE metadata to DATUM when DATUM has stable identity."
      (if (and source (source-attachable? datum))
          (begin
            (if (> agent-scheme-source-metadata-count
                   agent-scheme-source-metadata-limit)
                (begin
                  (set! agent-scheme-source-metadata '())
                  (set! agent-scheme-source-metadata-count 0)))
            (set! agent-scheme-source-metadata
                  (cons (cons datum source)
                        agent-scheme-source-metadata))
            (set! agent-scheme-source-metadata-count
                  (+ agent-scheme-source-metadata-count 1))))
      datum)

    (define (agent-scheme-datum-source datum)
      "Return source metadata attached to DATUM, or #f when absent."
      (let ((cell (assq datum agent-scheme-source-metadata)))
        (if cell (source-metadata->record (cdr cell)) #f)))

    (define (datum-source-metadata datum)
      "Return raw source metadata attached to DATUM, or #f when absent."
      (let ((cell (assq datum agent-scheme-source-metadata)))
        (if cell (cdr cell) #f)))

    (define (agent-scheme-copy-datum-source! target source . maybe-overwrite)
      "Copy source metadata from SOURCE to TARGET, preserving existing metadata by default."
      (let ((metadata (datum-source-metadata source))
            (overwrite? (and (not (null? maybe-overwrite))
                             (car maybe-overwrite))))
        (if (and metadata
                 (or overwrite?
                     (not (datum-source-metadata target))))
            (agent-scheme-datum-source-set! target metadata))
        target))

    (define (reader-error reader message . irritants)
      "Raise a reader error annotated with the current source offset."
      (apply error
             (string-append
              "agent-scheme reader error at offset "
              (agent-scheme-integer->radix-string
               (reader-position reader)
               10)
              ": "
              message)
             irritants))

    (define (limit-error reader message . irritants)
      "Raise a datum resource-limit error annotated with the current source offset."
      (apply error
             (string-append
              "agent-scheme datum limit error at offset "
              (agent-scheme-integer->radix-string
               (reader-position reader)
               10)
              ": "
              message)
             irritants))

    (define (check-depth reader depth)
      "Enforce the active reader maximum depth budget."
      (if (> depth (reader-maximum-depth reader))
          (limit-error reader
                       "datum depth exceeds maximum depth"
                       depth
                       (reader-maximum-depth reader))))

    (define (note-node! reader)
      "Charge one reader datum node against the active total-node budget."
      (set-reader-node-count! reader (+ (reader-node-count reader) 1))
      (if (> (reader-node-count reader) (reader-maximum-total-nodes reader))
          (limit-error reader
                       "datum node count exceeds maximum total nodes"
                       (reader-maximum-total-nodes reader))))

    (define (eof? reader)
      "Report whether the reader cursor has reached the source length."
      (>= (reader-position reader) (reader-length reader)))

    (define (peek reader . maybe-offset)
      "Return the source character at the current cursor plus an optional offset."
      (let* ((offset (if (null? maybe-offset) 0 (car maybe-offset)))
             (index (+ (reader-position reader) offset)))
        (if (< index (reader-length reader))
            (string-ref (reader-source reader) index)
            #f)))

    (define (advance! reader . maybe-count)
      "Move the reader cursor forward by one character or the requested count."
      (let ((count (if (null? maybe-count) 1 (car maybe-count))))
        (set-reader-position! reader (+ (reader-position reader) count))))

    (define (starts-with? reader text)
      "Test whether TEXT appears at the reader cursor without advancing it."
      (let ((position (reader-position reader))
            (end (+ (reader-position reader) (string-length text))))
        (and (<= end (reader-length reader))
             (string=? text
                       (substring (reader-source reader)
                                  position
                                  end)))))

    (define (whitespace? char)
      "Recognize R7RS whitespace characters accepted between tokens."
      (and char
           (or (char=? char #\space)
               (char=? char #\tab)
               (char=? char #\newline)
               (char=? char #\return)
               (char=? char char-page))))

    (define (intraline-whitespace? char)
      "Recognize spaces and tabs used inside string continuations."
      (and char
           (or (char=? char #\space)
               (char=? char #\tab))))

    (define (delimiter? char)
      "Recognize characters that terminate reader tokens."
      (or (not char)
          (whitespace? char)
          (char=? char #\|)
          (char=? char #\()
          (char=? char #\))
          (char=? char #\")
          (char=? char #\;)))

    (define (reserved? char)
      "Recognize reserved reader characters that must signal syntax errors."
      (and char
           (or (char=? char #\[)
               (char=? char #\])
               (char=? char #\{)
               (char=? char #\}))))

    (define (skip-line-comment! reader)
      "Skip an R7RS line comment and its optional line ending."
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
      "Skip a nested block comment while preserving nesting depth."
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
      "Read and apply reader directives such as fold-case and no-fold-case."
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
      "Skip whitespace, comments, directives, and datum comments between datums."
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
      "Read a raw token from the current cursor up to the next delimiter."
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
      "Convert one hexadecimal digit character to its integer value."
      (cond
       ((and (char>=? char #\0) (char<=? char #\9))
        (- (char->integer char) (char->integer #\0)))
       ((and (char>=? char #\a) (char<=? char #\f))
        (+ 10 (- (char->integer char) (char->integer #\a))))
       ((and (char>=? char #\A) (char<=? char #\F))
        (+ 10 (- (char->integer char) (char->integer #\A))))
       (else
        #f)))

    (define (string-prefix? prefix text)
      "Test whether TEXT begins with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (string=? prefix (substring text 0 prefix-length)))))

    (define (string-suffix? suffix text)
      "Test whether TEXT ends with SUFFIX."
      (let ((suffix-length (string-length suffix))
            (text-length (string-length text)))
        (and (<= suffix-length text-length)
             (string=?
              suffix
              (substring text (- text-length suffix-length) text-length)))))

    (define (string-index text char start)
      "Find CHAR in TEXT at or after START, returning #f when absent."
      (let loop ((index start))
        (cond
         ((= index (string-length text)) #f)
         ((char=? (string-ref text index) char) index)
         (else (loop (+ index 1))))))

    (define (split-on-char text char)
      "Split TEXT at each occurrence of CHAR."
      (let loop ((index 0) (start 0) (parts '()))
        (cond
         ((= index (string-length text))
          (reverse
           (cons (substring text start index) parts)))
         ((char=? (string-ref text index) char)
          (loop (+ index 1)
                (+ index 1)
                (cons (substring text start index) parts)))
         (else
          (loop (+ index 1) start parts)))))

    (define (integer-gcd left right)
      "Compute the nonnegative greatest common divisor for exact integers."
      (let loop ((a (abs left)) (b (abs right)))
        (if (zero? b) a (loop b (modulo a b)))))

    (define (integer-power base exponent)
      "Compute BASE raised to nonnegative EXPONENT for reader number parsing."
      (let loop ((result 1) (factor base) (power exponent))
        (cond
         ((zero? power) result)
         ((odd? power)
          (loop (* result factor) (* factor factor) (quotient power 2)))
         (else
          (loop result (* factor factor) (quotient power 2))))))

    (define (normalize-rational-pair numerator denominator)
      "Normalize a rational numerator and denominator to canonical sign and gcd."
      (if (zero? denominator)
          (error "zero denominator"))
      (let* ((adjusted
              (if (< denominator 0)
                  (cons (- numerator) (- denominator))
                  (cons numerator denominator)))
             (divisor (integer-gcd (car adjusted) (cdr adjusted))))
        (cons (quotient (car adjusted) divisor)
              (quotient (cdr adjusted) divisor))))

    (define (agent-scheme-make-canonical-integer value . rest)
      "Canonical number constructors are the public boundary for agent-owned numeric values created by readers, primitives, and result renderers."
      (let ((exactness (if (null? rest) 'exact (car rest)))
            (radix (if (or (null? rest) (null? (cdr rest)))
                       10
                       (cadr rest))))
        (make-agent-scheme-number
         (agent-scheme-integer->radix-string value 10)
         exactness
         radix
         'integer
         value)))

    (define (host-inexact-special-kind value)
      "Classify host inexact special numbers as infinity, NaN, or ordinary."
      (cond
       ((not (= value value)) "+nan.0")
       ((= value (/ 1.0 0.0)) "+inf.0")
       ((= value (/ -1.0 0.0)) "-inf.0")
       (else #f)))

    (define (agent-scheme-make-canonical-decimal value . maybe-lexeme)
      "Public constructor for canonical inexact decimal number records."
      (let ((special-kind (host-inexact-special-kind value)))
        (if special-kind
            (agent-scheme-make-canonical-infnan special-kind)
            (make-agent-scheme-number
             (if (null? maybe-lexeme)
                 (number->string value)
                 (car maybe-lexeme))
             'inexact
             10
             'decimal
             value))))

    (define (agent-scheme-make-canonical-rational
             numerator denominator . rest)
      "Public constructor for normalized rational number records."
      (let* ((pair (normalize-rational-pair numerator denominator))
             (normalized-numerator (car pair))
             (normalized-denominator (cdr pair))
             (exactness (if (null? rest) 'exact (car rest)))
             (radix (if (or (null? rest) (null? (cdr rest)))
                        10
                        (cadr rest))))
        (if (= normalized-denominator 1)
            (agent-scheme-make-canonical-integer
             normalized-numerator
             exactness
             radix)
            (make-agent-scheme-number
             (string-append
              (agent-scheme-integer->radix-string normalized-numerator 10)
              "/"
              (agent-scheme-integer->radix-string normalized-denominator 10))
             exactness
             radix
             'rational
             pair))))

    (define (agent-scheme-make-canonical-infnan kind)
      "Public constructor for canonical infinity and NaN number records."
      (make-agent-scheme-number
       (cond
        ((string=? kind "+inf.0") "+inf.0")
        ((string=? kind "-inf.0") "-inf.0")
        ((string=? kind "+nan.0") "+nan.0")
        (else (error "unknown inexact special number" kind)))
       'inexact
       10
       'infnan
       kind))

    (define (agent-scheme-make-canonical-complex real imaginary)
      "Public constructor for canonical rectangular complex number records."
      (let ((exactness
             (if (and (eq? (agent-scheme-number-exactness real) 'exact)
                      (eq? (agent-scheme-number-exactness imaginary)
                           'exact))
                 'exact
                 'inexact)))
        (make-agent-scheme-number
         #f
         exactness
         10
         'complex
         (cons real imaginary))))

    (define (agent-scheme-number-zero? number)
      "Numeric predicates and helpers inspect the agent-owned representation instead of asking the host whether wrapped numbers are ordinary numbers."
      (and (agent-scheme-number? number)
           (cond
            ((eq? (agent-scheme-number-kind number) 'integer)
             (zero? (agent-scheme-number-value number)))
            ((eq? (agent-scheme-number-kind number) 'rational)
             (zero? (car (agent-scheme-number-value number))))
            ((eq? (agent-scheme-number-kind number) 'decimal)
             (zero? (agent-scheme-number-value number)))
            ((eq? (agent-scheme-number-kind number) 'complex)
             (and (agent-scheme-number-zero?
                   (car (agent-scheme-number-value number)))
                  (agent-scheme-number-zero?
                   (cdr (agent-scheme-number-value number)))))
            (else #f))))

    (define (agent-scheme-number-negative? number)
      "Public predicate for negative real Agent Scheme number records."
      (cond
       ((eq? (agent-scheme-number-kind number) 'integer)
        (< (agent-scheme-number-value number) 0))
       ((eq? (agent-scheme-number-kind number) 'rational)
        (< (car (agent-scheme-number-value number)) 0))
       ((eq? (agent-scheme-number-kind number) 'decimal)
        (< (agent-scheme-number-value number) 0))
       ((eq? (agent-scheme-number-kind number) 'infnan)
        (string=? (agent-scheme-number-value number) "-inf.0"))
       (else #f)))

    (define (agent-scheme-number-abs number)
      "Public helper that returns the absolute value of an Agent Scheme number record."
      (cond
       ((eq? (agent-scheme-number-kind number) 'integer)
        (agent-scheme-make-canonical-integer
         (abs (agent-scheme-number-value number))
         (agent-scheme-number-exactness number)
         (agent-scheme-number-radix number)))
       ((eq? (agent-scheme-number-kind number) 'rational)
        (let ((value (agent-scheme-number-value number)))
          (agent-scheme-make-canonical-rational
           (abs (car value))
           (cdr value)
           (agent-scheme-number-exactness number)
           (agent-scheme-number-radix number))))
       ((eq? (agent-scheme-number-kind number) 'decimal)
        (agent-scheme-make-canonical-decimal
         (abs (agent-scheme-number-value number))))
       ((eq? (agent-scheme-number-kind number) 'infnan)
        (if (string=? (agent-scheme-number-value number) "-inf.0")
            (agent-scheme-make-canonical-infnan "+inf.0")
            number))
       (else number)))

    (define (integer-decimal-text? text)
      "Report whether TEXT is an unsigned decimal integer token."
      (let ((length (string-length text)))
        (let ((start
               (if (and (> length 0)
                        (or (char=? (string-ref text 0) #\+)
                            (char=? (string-ref text 0) #\-)))
                   1
                   0)))
          (and (< start length)
               (let loop ((index start))
                 (or (= index length)
                     (and (char>=? (string-ref text index) #\0)
                          (char<=? (string-ref text index) #\9)
                          (loop (+ index 1)))))))))

    (define (terminal-dot-decimal-text? text)
      "Report whether TEXT is a host decimal spelling that ends with a dot."
      (let ((length (string-length text)))
        (and (> length 1)
             (char=? (string-ref text (- length 1)) #\.)
             (integer-decimal-text? (substring text 0 (- length 1))))))

    (define (agent-scheme-number->external number)
      "Public renderer for Agent Scheme number records."
      (cond
       ((eq? (agent-scheme-number-kind number) 'integer)
        (agent-scheme-integer->radix-string
         (agent-scheme-number-value number)
         10))
       ((eq? (agent-scheme-number-kind number) 'rational)
        (let ((value (agent-scheme-number-value number)))
          (string-append
           (agent-scheme-integer->radix-string (car value) 10)
           "/"
           (agent-scheme-integer->radix-string (cdr value) 10))))
       ((eq? (agent-scheme-number-kind number) 'decimal)
        (let ((text (number->string (agent-scheme-number-value number))))
          (cond
           ((integer-decimal-text? text) (string-append text ".0"))
           ((terminal-dot-decimal-text? text) (string-append text "0"))
           (else text))))
       ((eq? (agent-scheme-number-kind number) 'infnan)
        (cond
         ((string=? (agent-scheme-number-value number) "+inf.0") "+inf.0")
         ((string=? (agent-scheme-number-value number) "-inf.0") "-inf.0")
         (else "+nan.0")))
       ((eq? (agent-scheme-number-kind number) 'complex)
        (let* ((value (agent-scheme-number-value number))
               (real (car value))
               (imaginary (cdr value)))
          (string-append
           (agent-scheme-number->external real)
           (if (eq? (agent-scheme-number-kind imaginary) 'infnan)
               (agent-scheme-number->external imaginary)
               (let ((negative? (agent-scheme-number-negative? imaginary))
                     (magnitude (agent-scheme-number-abs imaginary)))
                 (string-append
                  (if negative? "-" "+")
                  (agent-scheme-number->external magnitude))))
           "i")))
       (else
        (or (agent-scheme-number-lexeme number)
            (error "cannot write unknown number kind"
                   (agent-scheme-number-kind number))))))

    (define (parse-unsigned-integer digits radix)
      "Parse DIGITS in RADIX into an exact integer or #f on invalid input."
      (and (> (string-length digits) 0)
           (let loop ((index 0) (value 0))
             (if (= index (string-length digits))
                 value
                 (let ((digit (hex-digit-value (string-ref digits index))))
                   (and digit
                        (< digit radix)
                        (loop (+ index 1) (+ (* value radix) digit))))))))

    (define (parse-signed-integer body radix)
      "Parse BODY as an optional-sign integer in RADIX."
      (let ((length (string-length body)))
        (and (> length 0)
             (let* ((first (string-ref body 0))
                    (negative? (char=? first #\-))
                    (signed? (or negative? (char=? first #\+)))
                    (digits (if signed? (substring body 1 length) body))
                    (value (parse-unsigned-integer digits radix)))
               (and value (if negative? (- value) value))))))

    (define (number-prefix reader token)
      "Parse exactness and radix prefixes from a numeric TOKEN."
      (let ((lower (string-foldcase token))
            (length (string-length token)))
        (let loop ((index 0)
                   (exactness #f)
                   (radix 10)
                   (seen-exactness? #f)
                   (seen-radix? #f)
                   (valid? #f))
          (if (and (<= (+ index 2) length)
                   (char=? (string-ref lower index) #\#))
              (let ((marker (string-ref lower (+ index 1))))
                (cond
                 ((or (char=? marker #\e) (char=? marker #\i))
                  (if seen-exactness?
                      (reader-error
                       reader
                       "duplicate exactness prefix in number"
                       token))
                  (loop (+ index 2)
                        (if (char=? marker #\e) 'exact 'inexact)
                        radix
                        #t
                        seen-radix?
                        #t))
                 ((or (char=? marker #\b)
                      (char=? marker #\o)
                      (char=? marker #\d)
                      (char=? marker #\x))
                  (if seen-radix?
                      (reader-error
                       reader
                       "duplicate radix prefix in number"
                       token))
                  (loop (+ index 2)
                        exactness
                        (cond
                         ((char=? marker #\b) 2)
                         ((char=? marker #\o) 8)
                         ((char=? marker #\d) 10)
                         (else 16))
                        seen-exactness?
                        #t
                        #t))
                 (else #f)))
              (and (or valid? (not (string-prefix? "#" token)))
                   (list (substring token index length)
                         exactness
                         radix))))))

    (define (decimal-digit? char)
      "Report whether CHAR is an ASCII decimal digit."
      (and (char>=? char #\0) (char<=? char #\9)))

    (define (scan-decimal-digits text start)
      "Return the first index after a run of decimal digits in TEXT."
      (let loop ((index start) (digits '()))
        (if (and (< index (string-length text))
                 (decimal-digit? (string-ref text index)))
            (loop (+ index 1) (cons (string-ref text index) digits))
            (cons index (list->string (reverse digits))))))

    (define (decimal-components body)
      "Split a decimal body into integer, fraction, and exponent components."
      (let* ((length (string-length body))
             (sign
              (if (and (> length 0)
                       (char=? (string-ref body 0) #\-))
                  -1
                  1))
             (start
              (if (and (> length 0)
                       (or (char=? (string-ref body 0) #\+)
                           (char=? (string-ref body 0) #\-)))
                  1
                  0))
             (whole-scan (scan-decimal-digits body start))
             (after-whole (car whole-scan))
             (whole-text (cdr whole-scan))
             (saw-dot?
              (and (< after-whole length)
                   (char=? (string-ref body after-whole) #\.)))
             (fraction-scan
              (if saw-dot?
                  (scan-decimal-digits body (+ after-whole 1))
                  (cons after-whole "")))
             (after-fraction (car fraction-scan))
             (fraction-text (cdr fraction-scan))
             (saw-exponent?
              (and (< after-fraction length)
                   (or (char=? (string-ref body after-fraction) #\e)
                       (char=? (string-ref body after-fraction) #\E))))
             (exponent
              (if saw-exponent?
                  (parse-signed-integer
                   (substring body (+ after-fraction 1) length)
                   10)
                  0))
             (after-exponent (if saw-exponent? length after-fraction))
             (digit-count
              (+ (string-length whole-text)
                 (string-length fraction-text))))
        (and (= after-exponent length)
             exponent
             (> digit-count 0)
             (or saw-dot? saw-exponent?)
             (list sign whole-text fraction-text exponent))))

    (define (parse-exact-decimal body)
      "Parse a finite decimal body into an exact rational pair."
      (let ((components (decimal-components body)))
        (and components
             (let* ((sign (car components))
                    (whole (cadr components))
                    (fraction (car (cdr (cdr components))))
                    (exponent (car (cdr (cdr (cdr components)))))
                    (digits (string-append whole fraction))
                    (integer (parse-unsigned-integer digits 10))
                    (scale (- exponent (string-length fraction))))
               (and integer
                    (if (>= scale 0)
                        (cons (* sign integer (integer-power 10 scale)) 1)
                        (cons (* sign integer)
                              (integer-power 10 (- scale)))))))))

    (define (rational-pair->inexact pair)
      "Convert a normalized rational pair to a host inexact approximation."
      (/ (inexact (car pair)) (inexact (cdr pair))))

    (define (number->reader-float number)
      "Convert an Agent Scheme number wrapper to a host float for polar parsing."
      (cond
       ((eq? (agent-scheme-number-kind number) 'integer)
        (inexact (agent-scheme-number-value number)))
       ((eq? (agent-scheme-number-kind number) 'rational)
        (rational-pair->inexact (agent-scheme-number-value number)))
       ((eq? (agent-scheme-number-kind number) 'decimal)
        (agent-scheme-number-value number))
       ((eq? (agent-scheme-number-kind number) 'infnan)
        (cond
         ((string=? (agent-scheme-number-value number) "+inf.0")
          (/ 1.0 0.0))
         ((string=? (agent-scheme-number-value number) "-inf.0")
          (/ -1.0 0.0))
         (else (/ 0.0 0.0))))
       (else 0.0)))

    (define (parse-real-number-body reader token body exactness radix)
      "Parse the body of a real-number token into the reader's numeric record."
      (let ((lower (string-foldcase body)))
        (cond
         ((or (string=? lower "+inf.0")
              (string=? lower "-inf.0")
              (string=? lower "+nan.0")
              (string=? lower "-nan.0"))
          (if (eq? exactness 'exact)
              (reader-error
               reader
               "infinite and NaN literals cannot be exact"
               token))
          (agent-scheme-make-canonical-infnan
           (cond
            ((string=? lower "+inf.0") "+inf.0")
            ((string=? lower "-inf.0") "-inf.0")
            (else "+nan.0"))))
         ((parse-signed-integer body radix)
          => (lambda (value)
               (if (eq? exactness 'inexact)
                   (agent-scheme-make-canonical-decimal (inexact value))
                   (agent-scheme-make-canonical-integer value 'exact radix))))
         ((string-index body #\/ 0)
          (let ((parts (split-on-char body #\/)))
            (if (not (= (length parts) 2))
                #f
                (let ((numerator
                       (parse-signed-integer (car parts) radix))
                      (denominator
                       (parse-unsigned-integer (cadr parts) radix)))
                  (cond
                   ((and numerator denominator (zero? denominator))
                    (reader-error reader "invalid rational number" token))
                   ((and numerator denominator)
                    (if (eq? exactness 'inexact)
                        (agent-scheme-make-canonical-decimal
                         (rational-pair->inexact
                          (cons numerator denominator)))
                        (agent-scheme-make-canonical-rational
                         numerator denominator 'exact radix)))
                   (else #f))))))
         ((and (= radix 10) (decimal-components body))
          (let ((pair (parse-exact-decimal body)))
            (if (eq? exactness 'exact)
                (agent-scheme-make-canonical-rational
                 (car pair)
                 (cdr pair))
                (agent-scheme-make-canonical-decimal
                 (rational-pair->inexact pair)
                 body))))
         (else #f))))

    (define (complex-split-index body)
      "Find the real/imaginary split point in a rectangular complex token."
      (let loop ((index 1) (split #f))
        (if (>= index (string-length body))
            split
            (let ((char (string-ref body index))
                  (previous (string-ref body (- index 1))))
              (loop (+ index 1)
                    (if (and (or (char=? char #\+)
                                 (char=? char #\-))
                             (not (or (char=? previous #\e)
                                      (char=? previous #\E))))
                        index
                        split))))))

    (define (parse-complex-number-body reader token body exactness radix)
      "Parse a complex-number token into rectangular or polar numeric records."
      (let ((lower (string-foldcase body)))
        (cond
         ((and (= radix 10) (string-suffix? "i" lower))
          (let* ((rectangular (substring body 0 (- (string-length body) 1)))
                 (split (complex-split-index rectangular))
                 (real-body
                  (if split
                      (substring rectangular 0 split)
                      "0"))
                 (imaginary-body
                  (if split
                      (substring rectangular split (string-length rectangular))
                      rectangular))
                 (adjusted-imaginary-body
                  (cond
                   ((string=? imaginary-body "") #f)
                   ((or (string=? imaginary-body "+")
                        (string=? imaginary-body "-"))
                    (string-append imaginary-body "1"))
                   (else imaginary-body))))
            (and adjusted-imaginary-body
                 (let ((real
                        (parse-real-number-body
                         reader token real-body exactness radix))
                       (imaginary
                        (parse-real-number-body
                         reader token adjusted-imaginary-body
                         exactness radix)))
                   (and real
                        imaginary
                        (agent-scheme-make-canonical-complex
                         real
                         imaginary))))))
         ((and (= radix 10) (string-index body #\@ 0))
          (let ((parts (split-on-char body #\@)))
            (and (= (length parts) 2)
                 (let ((magnitude
                        (parse-real-number-body
                         reader token (car parts) exactness radix))
                       (angle
                        (parse-real-number-body
                         reader token (cadr parts) exactness radix)))
                   (and magnitude
                        angle
                        (let ((r (number->reader-float magnitude))
                              (theta (number->reader-float angle)))
                          (agent-scheme-make-canonical-complex
                           (agent-scheme-make-canonical-decimal
                            (* r (cos theta)))
                           (agent-scheme-make-canonical-decimal
                            (* r (sin theta))))))))))
         (else #f))))

    (define (parse-number-token reader token)
      "Parse a complete number token with radix and exactness prefixes."
      (let ((prefix (number-prefix reader token)))
        (and prefix
             (let ((body (car prefix))
                   (exactness (cadr prefix))
                   (radix (car (cdr (cdr prefix)))))
               (and (> (string-length body) 0)
                    (or (parse-real-number-body
                         reader token body exactness radix)
                        (parse-complex-number-body
                         reader token body exactness radix)))))))

    (define (hex-scalar->char reader digits)
      "Validate and convert a hexadecimal scalar value to a character."
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
      "Read a semicolon-terminated hexadecimal escape from the source."
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
      "Map a named string or symbol escape character to its value."
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
      "Read a quoted string literal, escapes, and line continuations."
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
      "Read an escaped vertical-bar symbol name."
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
      "Report whether CHAR appears in STRING."
      (let loop ((index 0))
        (and (< index (string-length string))
             (or (char=? char (string-ref string index))
                 (loop (+ index 1))))))

    (define (ascii-letter? char)
      "Recognize ASCII letters for identifier token validation."
      (or (and (char>=? char #\a) (char<=? char #\z))
          (and (char>=? char #\A) (char<=? char #\Z))))

    (define (initial-char? char)
      "Recognize valid initial characters for ordinary identifiers."
      (or (ascii-letter? char)
          (> (char->integer char) 127)
          (char-in-string? char "!$%&*/:<=>?@^_~")))

    (define (subsequent-char? char)
      "Recognize valid subsequent characters for ordinary identifiers."
      (or (initial-char? char)
          (and (char>=? char #\0) (char<=? char #\9))
          (char-in-string? char "+-.@")))

    (define (sign-subsequent-char? char)
      "Recognize identifier characters that may follow an initial sign."
      (or (initial-char? char)
          (char-in-string? char "+-@")))

    (define (dot-subsequent-char? char)
      "Recognize identifier characters that may follow an initial dot."
      (or (sign-subsequent-char? char)
          (char=? char #\.)))

    (define (all-chars? string start predicate)
      "Check that every character from START satisfies PREDICATE."
      (let loop ((index start))
        (or (= index (string-length string))
            (and (predicate (string-ref string index))
                 (loop (+ index 1))))))

    (define (identifier-token? token)
      "Validate TOKEN against R7RS ordinary identifier grammar."
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
      "Read an R7RS character literal after the #\\\\ introducer."
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
      "Classify a raw token as number, boolean, identifier, or syntax error."
      (cond
       ((or (string=? token "#t") (string=? token "#true")) #t)
       ((or (string=? token "#f") (string=? token "#false")) #f)
       ((parse-number-token reader token) => (lambda (number) number))
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
      "Read a proper or dotted list up to a closing parenthesis."
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
      "Read vector or bytevector elements under the active length budget."
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

    (define (exact-integer-value datum)
      "Extract an exact integer value from an Agent Scheme number datum."
      (and (agent-scheme-number? datum)
           (eq? (agent-scheme-number-kind datum) 'integer)
           (eq? (agent-scheme-number-exactness datum) 'exact)
           (agent-scheme-number-value datum)))

    (define (exact-byte? datum)
      "Report whether DATUM is an exact integer byte."
      (let ((value (exact-integer-value datum)))
        (and value
             (<= 0 value)
             (<= value 255))))

    (define (list->bytevector bytes)
      "Convert a list of exact byte values into a bytevector."
      (let* ((length (length bytes))
             (bytevector (make-bytevector length)))
        (let loop ((index 0) (rest bytes))
          (if (null? rest)
              bytevector
              (begin
                (bytevector-u8-set! bytevector index (car rest))
                (loop (+ index 1) (cdr rest)))))))

    (define (read-vector reader depth)
      "Read an R7RS vector literal."
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
      "Read an R7RS bytevector literal and validate byte elements."
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
            (loop (cdr rest) (cons (exact-integer-value (car rest)) bytes)))
           (else
            (reader-error reader
                          "bytevector element is not an exact byte"
                          (agent-scheme-datum->external (car rest))))))))

    (define (quote-datum name datum)
      "Build the canonical abbreviated quote form for NAME and DATUM."
      (list (string->symbol name) datum))

    (define (reader-label-cell reader id)
      "Find an existing datum-label cell for ID in the reader state."
      (let loop ((rest (reader-datum-labels reader)))
        (cond
         ((null? rest) #f)
         ((string=? (caar rest) id) (car rest))
         (else (loop (cdr rest))))))

    (define (read-datum-label reader depth)
      "Read and resolve shared datum label definitions and references."
      (advance! reader)
      (let ((start (reader-position reader)))
        (let digit-loop ()
          (let ((char (peek reader)))
            (if (and char (char>=? char #\0) (char<=? char #\9))
                (begin
                  (advance! reader)
                  (digit-loop)))))
        (if (= start (reader-position reader))
            (reader-error reader "datum label requires digits"))
        (let* ((id (substring (reader-source reader)
                              start
                              (reader-position reader)))
               (marker (peek reader)))
          (cond
           ((and marker (char=? marker #\=))
            (advance! reader)
            (if (reader-label-cell reader id)
                (reader-error reader "duplicate datum label" id))
            (let ((label (make-datum-label id #f #f)))
              (set-reader-datum-labels!
               reader
               (cons (cons id label) (reader-datum-labels reader)))
              (let ((datum (read-datum reader depth)))
                (if (eq? datum label)
                    (reader-error
                     reader
                     "datum label cannot reference itself directly"
                     id))
                (set-datum-label-value! label datum)
                (set-datum-label-filled! label #t)
                datum)))
           ((and marker (char=? marker #\#))
            (advance! reader)
            (let ((cell (reader-label-cell reader id)))
              (if (not cell)
                  (reader-error reader "undefined datum label" id))
              (cdr cell)))
           (else
            (reader-error reader "datum label must end with = or #"))))))

    (define (read-dispatch reader depth)
      "Read a datum introduced by # dispatch syntax."
      (cond
       ((starts-with? reader "#(") (read-vector reader depth))
       ((starts-with? reader "#u8(") (read-bytevector reader depth))
       ((starts-with? reader "#\\") (read-character-literal reader))
       ((let ((char (peek reader 1)))
          (and char (char>=? char #\0) (char<=? char #\9)))
        (read-datum-label reader depth))
       (else
        (classify-token reader (read-token reader)))))

    (define (resolve-datum-labels datum reader)
      "Replace datum-label placeholders with their resolved shared values."
      (let resolve ((value datum) (seen '()))
        (cond
         ((datum-label? value)
          (if (not (datum-label-filled? value))
              (reader-error reader "undefined datum label"
                            (datum-label-id value)))
          (resolve (datum-label-value value) seen))
         ((pair? value)
          (if (memq value seen)
              value
              (begin
                (set-car! value (resolve (car value) (cons value seen)))
                (set-cdr! value (resolve (cdr value) (cons value seen)))
                value)))
         ((vector? value)
          (if (memq value seen)
              value
              (let loop ((index 0))
                (if (= index (vector-length value))
                    value
                    (begin
                      (vector-set!
                       value
                       index
                       (resolve (vector-ref value index)
                                (cons value seen)))
                      (loop (+ index 1)))))))
         (else value))))


    (define (read-datum reader depth)
      "Read one datum at DEPTH from the current reader cursor."
      (check-depth reader depth)
      (skip-intertoken-space! reader depth)
      (if (eof? reader)
          (reader-error reader "unexpected end of input"))
      (let ((start (reader-position reader))
            (char (peek reader)))
        (let ((datum
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
                              (quote-datum
                               "unquote-splicing"
                               (read-datum reader (+ depth 1)))))
                         (note-node! reader)
                         datum))
                     (let ((datum
                            (quote-datum
                             "unquote"
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
          (if (reader-source-metadata reader)
              (agent-scheme-datum-source-set!
               datum
               (source-note reader start (reader-position reader)))
              datum))))

    (define (options-from-rest maybe-options)
      "Normalize optional argument lists to an options association list."
      (if (null? maybe-options) '() (car maybe-options)))

    (define (agent-scheme-read source . maybe-options)
      "Read one datum from SOURCE, enforce complete input consumption, and validate the resulting host data against Agent Scheme resource limits."
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options))
             (ignored (set-reader-datum-labels! reader '()))
             (datum (resolve-datum-labels (read-datum reader 0)
                                          reader)))
        (skip-intertoken-space! reader 0)
        (if (not (eof? reader))
            (reader-error reader "unexpected trailing input"))
        (agent-scheme-validate-datum datum options)
        datum))

    (define (agent-scheme-read-all source . maybe-options)
      "Read a source body into datums for program/library evaluation.  Datum labels are scoped per datum, matching R7RS external representations."
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
              (begin
                (set-reader-datum-labels! reader '())
                (loop (cons (resolve-datum-labels
                             (read-datum reader 0)
                             reader)
                            datums)))))))

    (define (agent-scheme-read-from-string-at source position . maybe-options)
      "Incremental read entry point for ports and REPL-like callers; the cdr of the result is the next source offset no matter which datum was returned."
      (if (not (string? source))
          (error "agent-scheme reader source must be a string" source))
      (if (or (not (integer? position))
              (< position 0)
              (> position (string-length source)))
          (error "agent-scheme reader position out of range" position))
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options)))
        (set-reader-position! reader position)
        (skip-intertoken-space! reader 0)
        (if (eof? reader)
            (cons agent-scheme-read-eof (reader-position reader))
            (begin
              (set-reader-datum-labels! reader '())
              (let ((datum (resolve-datum-labels
                            (read-datum reader 0)
                            reader)))
                (agent-scheme-validate-datum datum options)
                (cons datum (reader-position reader)))))))

    (define (validation-note-node! validation)
      "Charge one validation node against the post-read total-node budget."
      (set-validation-node-count!
       validation
       (+ (validation-node-count validation) 1))
      (if (> (validation-node-count validation)
             (validation-maximum-total-nodes validation))
          (error "agent-scheme datum limit error: datum node count exceeds maximum total nodes"
                 (validation-maximum-total-nodes validation))))

    (define (validate-datum datum options validation depth seen)
      "Datum validation protects the evaluator from host-constructed values that bypassed lexical reader checks, including cycles and oversized objects."
      (if (> depth
             (option-ref options 'max-depth
                         agent-scheme-default-maximum-depth))
          (error "agent-scheme datum limit error: datum depth exceeds maximum depth"
                 depth))
      (cond
       ((or (boolean? datum)
            (symbol? datum)
            (char? datum)
            (agent-scheme-number? datum))
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
                (if (not (let ((byte (bytevector-u8-ref datum index)))
                           (and (integer? byte) (<= 0 byte) (<= byte 255))))
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
                       (next-seen seen))
              (cond
               ((memq cursor next-seen) #t)
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
                                  (cons cursor next-seen))
                  (loop (cdr cursor)
                        next-count
                        (cons cursor next-seen))))
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
      "Public validation returns DATUM unchanged so callers can place it inline in read/evaluate pipelines while still enforcing depth and size budgets."
      (let* ((options (options-from-rest maybe-options))
             (validation
              (make-validation
               0
               (option-ref options 'max-total-nodes
                           agent-scheme-default-maximum-total-nodes))))
        (validate-datum datum options validation 0 '())
        datum))

    (define (escape-string text)
      "Escape string and symbol text for stable external rendering."
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
      "Report whether NAME requires vertical bars in external syntax."
      (or (not (identifier-token? name))
          (parse-number-token (reader-from-source "" '()) name)))

    (define (write-symbol-name name)
      "Render a symbol name with escaping when the token grammar requires it."
      (if (symbol-needs-bars? name)
          (string-append "|" (escape-string name) "|")
          name))

    (define (write-character-datum char)
      "Render a character in canonical R7RS external syntax."
      (let ((code (char->integer char)))
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
         ((or (< code 33) (= code 127))
          (string-append
           "#\\x"
           (agent-scheme-integer->radix-string code 16)))
         (else (string-append "#\\" (string char))))))

    (define (join strings separator)
      "Join string fragments with SEPARATOR for writer output."
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

    (define (writer-compound? datum)
      "Report whether DATUM can participate in shared or circular structure."
      (or (pair? datum) (vector? datum)))

    (define (alist-ref-eq key alist default)
      "Return the eq?-keyed association value or DEFAULT when absent."
      (let ((cell (assq key alist)))
        (if cell (cdr cell) default)))

    (define (remove-assq key alist)
      "Remove the first eq?-keyed association from an alist."
      (cond
       ((null? alist) '())
       ((eq? key (caar alist)) (cdr alist))
       (else (cons (car alist) (remove-assq key (cdr alist))))))

    (define (agent-scheme-datum->external datum . maybe-options)
      "Render Agent Scheme datums with stable external syntax, including shared and circular structure labels for write/shared mode."
      (let ((mode (if (null? maybe-options) 'write (car maybe-options)))
            (display? (if (or (null? maybe-options)
                              (null? (cdr maybe-options)))
                          #f
                          (cadr maybe-options)))
            (counts '())
            (states '())
            (cyclic '())
            (labels '())
            (emitted '())
            (next-label 0))

        (define (set-count! value count)
          (set! counts (cons (cons value count)
                             (remove-assq value counts))))

        (define (set-state! value state)
          (set! states (cons (cons value state)
                             (remove-assq value states))))

        (define (mark-cyclic! value)
          (if (not (memq value cyclic))
              (set! cyclic (cons value cyclic))))

        (define (mark-cycle! target stack)
          (let loop ((rest stack))
            (if (not (null? rest))
                (begin
                  (mark-cyclic! (car rest))
                  (if (not (eq? (car rest) target))
                      (loop (cdr rest)))))))

        (define (scan value stack)
          (if (writer-compound? value)
              (begin
                (set-count! value (+ (alist-ref-eq value counts 0) 1))
                (let ((state (alist-ref-eq value states #f)))
                  (cond
                   ((eq? state 'visiting)
                    (mark-cycle! value stack))
                   ((eq? state 'done)
                    #t)
                   (else
                    (set-state! value 'visiting)
                    (cond
                     ((pair? value)
                      (scan (car value) (cons value stack))
                      (scan (cdr value) (cons value stack)))
                     ((vector? value)
                      (let loop ((index 0))
                        (if (< index (vector-length value))
                            (begin
                              (scan (vector-ref value index)
                                    (cons value stack))
                              (loop (+ index 1)))))))
                    (set-state! value 'done)))))))

        (define (label-needed? value)
          (and (writer-compound? value)
               (cond
                ((eq? mode 'shared)
                 (> (alist-ref-eq value counts 0) 1))
                ((eq? mode 'write)
                 (memq value cyclic))
                (else #f))))

        (define (label-reference-ready? value)
          (and (label-needed? value)
               (assq value labels)
               (memq value emitted)))

        (define (label-for value)
          (let ((cell (assq value labels)))
            (if cell
                (cdr cell)
                (let ((label next-label))
                  (set! next-label (+ next-label 1))
                  (set! labels (cons (cons value label) labels))
                  label))))

        (define (record-name->external name)
          (cond
           ((symbol? name) (symbol->string name))
           ((string? name) name)
           (else (error "agent-scheme reader error: invalid record name"
                        name))))

        (define (render value)
          (if (label-needed? value)
              (let ((label (label-for value)))
                (if (memq value emitted)
                    (string-append
                     "#"
                     (agent-scheme-integer->radix-string label 10)
                     "#")
                    (begin
                      (set! emitted (cons value emitted))
                      (string-append
                       "#"
                       (agent-scheme-integer->radix-string label 10)
                       "="
                       (render-body value)))))
              (render-body value)))

        (define (render-list value)
          (let loop ((cursor value)
                     (parts '())
                     (first? #t))
            (if (and (pair? cursor)
                     (not (and (not first?)
                               (label-reference-ready? cursor))))
                (loop (cdr cursor)
                      (cons (render (car cursor)) parts)
                      #f)
                (let ((body (join (reverse parts) " ")))
                  (string-append
                   "("
                   body
                   (cond
                    ((and (pair? cursor)
                          (label-reference-ready? cursor))
                     (string-append
                      (if (null? parts) ". " " . ")
                      (render cursor)))
                    ((null? cursor) "")
                    (else
                     (string-append
                      (if (null? parts) ". " " . ")
                      (render cursor))))
                   ")")))))

        (define (render-vector value)
          (let loop ((index 0) (parts '()))
            (if (= index (vector-length value))
                (string-append "#(" (join (reverse parts) " ") ")")
                (loop (+ index 1)
                      (cons (render (vector-ref value index)) parts)))))

        (define (render-bytevector value)
          (let loop ((index 0) (parts '()))
            (if (= index (bytevector-length value))
                (string-append "#u8(" (join (reverse parts) " ") ")")
                (loop (+ index 1)
                      (cons (agent-scheme-integer->radix-string
                             (bytevector-u8-ref value index)
                             10)
                            parts)))))

        (define (render-body value)
          (cond
           ((boolean? value) (if value "#t" "#f"))
           ((null? value) "()")
           ((symbol? value)
            (if display?
                (symbol->string value)
                (write-symbol-name (symbol->string value))))
           ((char? value)
            (if display?
                (string value)
                (write-character-datum value)))
           ((agent-scheme-number? value) (agent-scheme-number->external value))
           ((string? value)
            (if display?
                value
                (string-append "\"" (escape-string value) "\"")))
           ((bytevector? value) (render-bytevector value))
           ((pair? value) (render-list value))
           ((vector? value) (render-vector value))
           ((agent-scheme-record? value)
            (string-append
             "#<record "
             (record-name->external
              (agent-scheme-record-type-name
               (agent-scheme-record-type value)))
             ">"))
           ((agent-scheme-record-type? value)
            (string-append
             "#<record-type "
             (record-name->external
              (agent-scheme-record-type-name value))
             ">"))
           (else
            (error "agent-scheme reader error: cannot write unsupported datum"
                   value))))

        (scan datum '())
        (if (and (eq? mode 'simple) (not (null? cyclic)))
            (error "agent-scheme reader error: write-simple cannot render circular datum"))
        (render datum)))))
