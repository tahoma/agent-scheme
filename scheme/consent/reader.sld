;;; Portable R7RS datum reader for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library mirrors the Emacs Lisp reader in portable Scheme.  It returns
;;; native Scheme datums, but it still enforces the same resource limits and
;;; reader-directive behavior so portable bootstrap tests exercise the same
;;; language boundary.

(define-library (consent reader)
  (export consent-read
          consent-read-all
          consent-read-from-string-at
          consent-read-recover
          consent-read-recover-from-string-at
          consent-resync-to-next-form
          consent-recovery-result?
          consent-recovery-result-datums
          consent-recovery-result-diagnostics
          consent-recovery-result-spans
          consent-recovery-result-status
          consent-recovery-step?
          consent-recovery-step-status
          consent-recovery-step-datum
          consent-recovery-step-diagnostic
          consent-recovery-step-span
          consent-recovery-step-next
          consent-recovery-step-pending
          consent-read-eof
          consent-read-eof?
          consent-source-metadata-count
          consent-datum-source
          consent-datum-source-set!
          consent-copy-datum-source!
          consent-validate-datum
          consent-datum->external
          consent-datum->external-bounded
          consent-number?
          consent-number-lexeme
          consent-number-exactness
          consent-number-radix
          consent-number-kind
          consent-number-value
          consent-number-owned-value
          consent-make-canonical-integer
          consent-make-canonical-decimal
          consent-make-canonical-rational
          consent-make-canonical-infnan
          consent-make-canonical-complex
          consent-number-zero?
          consent-number-negative?
          consent-number-abs
          consent-number->external
          consent-integer->radix-string
          consent-character?
          consent-character-code
          consent-make-character
          consent-make-record-type
          consent-record-type?
          consent-record-type-name
          consent-record-type-fields
          consent-make-record
          consent-record?
          consent-record-type
          consent-record-fields)
  (import (scheme base)
          (scheme char)
          (scheme inexact)
          (scheme write)
          (consent character)
          (consent numeric)
          (consent symbol)
          (consent symbol-boundary))
  (begin
    ;; Default maximum nested datum depth accepted by the portable reader.
    (define consent-default-maximum-depth 256)
    ;; Default maximum list length accepted by the portable reader.
    (define consent-default-maximum-list-length 100000)
    ;; Default maximum vector length accepted by the portable reader.
    (define consent-default-maximum-vector-length 100000)
    ;; Default maximum bytevector length accepted by the portable reader.
    (define consent-default-maximum-bytevector-length 100000)
    ;; Default maximum string size accepted by the portable reader.
    (define consent-default-maximum-string-size 1048576)
    ;; Default maximum total datum node count accepted by reader validation.
    (define consent-default-maximum-total-nodes 1000000)

    ;; Reader records own one parse run's immutable source and mutable cursor.
    (define-record-type <reader>
      ;; Reader state is mutable only for cursor position, fold-case mode, and
      ;; node count.  SOURCE remains the immutable snapshot of input text.
      (make-reader source characters position length line-starts fold-case
                   symbol-table
                   node-count datum-labels
                   maximum-depth maximum-list-length maximum-vector-length
                   maximum-bytevector-length maximum-string-size
                   maximum-total-nodes maximum-source-metadata source-id
                   source-metadata recovery pending-stack)
      reader?
      (source reader-source)
      (characters reader-characters)
      (position reader-position set-reader-position!)
      (length reader-length)
      (line-starts reader-line-starts)
      (fold-case reader-fold-case set-reader-fold-case!)
      (symbol-table reader-symbol-table)
      (node-count reader-node-count set-reader-node-count!)
      (datum-labels reader-datum-labels set-reader-datum-labels!)
      (maximum-depth reader-maximum-depth)
      (maximum-list-length reader-maximum-list-length)
      (maximum-vector-length reader-maximum-vector-length)
      (maximum-bytevector-length reader-maximum-bytevector-length)
      (maximum-string-size reader-maximum-string-size)
      (maximum-total-nodes reader-maximum-total-nodes)
      (maximum-source-metadata reader-maximum-source-metadata)
      (source-id reader-source-id)
      (source-metadata reader-source-metadata)
      ;; RECOVERY toggles errors-as-data: when set, reader errors raise a
      ;; structured <reader-condition> the recovery driver can resynchronize
      ;; past instead of unwinding the whole read.
      (recovery reader-recovery)
      ;; PENDING-STACK tracks the constructs currently open at the cursor,
      ;; innermost first (`list`, `vector`, `bytevector`, `string`, `symbol`,
      ;; `comment`).  An incomplete condition snapshots it so interactive
      ;; callers can render nesting depth and the pending construct kind.
      (pending-stack reader-pending-stack set-reader-pending-stack!))

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
    (define-record-type <consent-read-eof>
      (make-consent-read-eof)
      consent-read-eof?)

    ;; Singleton EOF sentinel returned by incremental reader calls at end of
    ;; input.
    (define consent-read-eof (make-consent-read-eof))

    ;; Identity side table for source metadata.  It keeps metadata auxiliary so
    ;; ordinary datum equality and external writing remain R7RS datums.
    (define consent-source-metadata '())

    ;; Default cap for the portable source side table. Portable R7RS has no
    ;; weak hash table, so the table remains explicit runtime state. Keep the
    ;; cap option-backed so trusted callers can retry with a higher bound.
    (define consent-default-maximum-source-metadata 10000000)

    ;; Recognize owned and bootstrap symbols while reading mixed datums.
    (define reader-datum-symbol? consent-host-symbol?)
    ;; Read names from owned and bootstrap symbols.
    (define reader-datum-symbol-name consent-host-symbol-name)

    ;; Current number of retained source metadata entries in the portable
    ;; table.
    (define consent-source-metadata-entry-count 0)

    (define (consent-source-metadata-count)
      "Return the number of retained portable source metadata entries."
      #((parameters)
        (returns (type exact-non-negative-integer)
         (description
          ("The process-global count of retained portable source"
            "metadata entries.")))
        (effects state-read))
      consent-source-metadata-entry-count)

    ;; Consent-owned numbers preserve lexical exactness, radix, and special
    ;; values without entrusting payload semantics to the host numeric tower.
    (define-record-type <consent-number>
      ;; VALUE is an owned integer, rational pair, binary64 tuple, special tag,
      ;; or pair of canonical real components.
      (make-consent-number lexeme exactness radix kind value)
      consent-number?
      (lexeme consent-number-lexeme)
      (exactness consent-number-exactness)
      (radix consent-number-radix)
      (kind consent-number-kind)
      (value consent-number-value-field))

    ;; One fixed profile backs the portable runtime. White-box tests
    ;; instantiate
    ;; alternate profiles directly through `(consent numeric)'.
    (define numeric-backend consent-default-numeric-backend)
    ;; Bound checked host-integer conversions to this backend's direct range.
    (define host-adapter-positive-integer-limit
      (consent-numeric-backend-positive-fixnum-limit numeric-backend))

    (define (owned-numeric operation . arguments)
      "Apply owned numeric OPERATION to ARGUMENTS."
      (apply consent-numeric numeric-backend operation arguments))

    (define (consent-number-owned-value datum)
      "Return the opaque owned payload of canonical number DATUM."
      #((parameters
         (datum (type consent-number)
          (description "Canonical number whose owned payload is requested.")))
        (returns
         (type
          (or owned-integer owned-rational owned-binary64 string pair))
         (description
           "Opaque integer, rational, binary64, or component payload."))
        (effects error))
      (if (consent-number? datum)
          (consent-number-value-field datum)
          (error "consent-number-owned-value expected a canonical number"
                 datum)))

    (define (owned-integer->host value)
      "Convert small owned integer VALUE for a bootstrap adapter."
      (or (owned-numeric
           'integer->small value host-adapter-positive-integer-limit)
          (error "canonical integer exceeds checked host adapter range"
                 (owned-numeric 'integer->string value 10))))

    (define (consent-number-value datum)
      "Return DATUM through the checked bootstrap host-adapter seam."
      "Core numeric code uses `consent-number-owned-value`; this compatibility\
"
      "accessor is limited to small metadata integers, finite host-math inputs\
,"
      "and legacy tests. It refuses to manufacture a host bignum."
      #((parameters
         (datum (type (or consent-number number))
          (description "Canonical number or plain bootstrap host number.")))
        (returns (type (or number pair string))
         (description
          ("A bounded host adapter value, structured rational or special"
           "payload, or DATUM when already a host number.")))
        (effects error))
      (cond
       ((and (consent-number? datum)
             (eq? (consent-number-kind datum) 'integer))
        (owned-integer->host (consent-number-value-field datum)))
       ((and (consent-number? datum)
             (eq? (consent-number-kind datum) 'rational))
        (let ((pair (consent-number-value-field datum)))
          (cons (owned-integer->host (car pair))
                (owned-integer->host (cdr pair)))))
       ((and (consent-number? datum)
             (eq? (consent-number-kind datum) 'decimal))
        (owned-numeric 'binary64->host (consent-number-value-field datum)))
       ((consent-number? datum) (consent-number-value-field datum))
       ((number? datum) datum)
       (else (error "consent-number-value expected a canonical number"
         datum))))

    ;; Portable record metadata belongs to Consent Scheme, not the host record
    ;; system, so evaluator-created records remain printable datums.
    (define-record-type <consent-record-type>
      (consent-make-record-type name fields)
      consent-record-type?
      (name consent-record-type-name)
      (fields consent-record-type-fields))

    ;; Portable record instances pair Consent Scheme record metadata with field
    ;; storage that the evaluator owns and may mutate through generated
    ;; setters.
    (define-record-type <consent-record>
      (consent-make-record type fields)
      consent-record?
      (type consent-record-type)
      (fields consent-record-fields))

    ;; Datum-label records hold placeholders while resolving shared and
    ;; circular
    ;; datum syntax; FILLED guards references to labels before their value
    ;; lands.
    (define-record-type <datum-label>
      (make-datum-label id filled value)
      datum-label?
      (id datum-label-id)
      (filled datum-label-filled? set-datum-label-filled!)
      (value datum-label-value set-datum-label-value!))

    ;; Structured reader condition raised in recovery mode.  KIND is one of
    ;; `invalid` (genuine syntax error), `incomplete` (a valid prefix that
    ;; needs
    ;; more input, such as an unterminated list at end of input), or `limit` (a
    ;; resource budget was exceeded). OFFSET is the source position at the
    ;; point
    ;; of failure.  PENDING snapshots the reader's open-construct stack at the
    ;; raise, innermost first; it is meaningful for `incomplete` conditions. In
    ;; the default raise-on-error mode these conditions are never constructed;
    ;; reader errors stay plain `error` objects.
    (define-record-type <reader-condition>
      (make-reader-condition kind offset message irritants pending)
      reader-condition?
      (kind reader-condition-kind)
      (offset reader-condition-offset)
      (message reader-condition-message)
      (irritants reader-condition-irritants)
      (pending reader-condition-pending))

    ;; Recovery read result for a whole source: a partial datum list plus the
    ;; ordered diagnostics and recovery spans collected along the way. STATUS
    ;; is
    ;; `complete` when the source was fully consumed or `incomplete` when the
    ;; trailing region is a valid prefix awaiting more input.
    (define-record-type <consent-recovery-result>
      (make-recovery-result datums diagnostics spans status)
      consent-recovery-result?
      (datums consent-recovery-result-datums)
      (diagnostics consent-recovery-result-diagnostics)
      (spans consent-recovery-result-spans)
      (status consent-recovery-result-status))

    ;; Recovery read step for a single form, the substrate interactive callers
    ;; (REPL, editor adapters) drive one form at a time.  STATUS is `datum`,
    ;; `invalid`, `incomplete`, or `eof`.  NEXT is the offset to resume from.
    ;; PENDING carries the open-construct stack for an `incomplete` step,
    ;; innermost first (and #f otherwise), so a continuation prompt can render
    ;; nesting depth without re-deriving the reader's lexical state.
    (define-record-type <consent-recovery-step>
      (make-recovery-step status datum diagnostic span next pending)
      consent-recovery-step?
      (status consent-recovery-step-status)
      (datum consent-recovery-step-datum)
      (diagnostic consent-recovery-step-diagnostic)
      (span consent-recovery-step-span)
      (next consent-recovery-step-next)
      (pending consent-recovery-step-pending))

    ;; Character constant for R7RS page whitespace.
    (define char-page (integer->char 12))

    (define (consent-integer->radix-string integer radix)
      "Exported writer helper used by the reader, evaluator, and tests wheneve\
r"
      "Consent Scheme needs canonical integer text independent of host"
      "formatting."
      #((parameters
         (integer (type exact-integer)
          (description "Owned or bootstrap host integer to render."))
         (radix (type exact-integer)
          (description
            ("Numeric base from 2 through 16 for the digit conversion."))))
        (returns (type string)
         (description
          ("A string of RADIX digits for INTEGER, with a leading minus"
            "sign for negative values and \"0\" for zero.")))
        (effects allocation))
      (owned-numeric
       'integer->string
       (if (owned-numeric 'integer? integer)
           integer
           (owned-numeric 'integer-import-host integer))
       radix))

    (define (option-ref options key default)
      "Return the option value for KEY or DEFAULT when KEY is absent."
      (let ((cell (assq key options)))
        (if cell (cdr cell) default)))

    (define (option-count options key default)
      "Return numeric option KEY as a host count."
      "A canonical number record is unwrapped when present, but plain host"
      "numbers are accepted too so compiled/native postures preserve the"
      "same Scheme numeric surface as source-hosted code."
      (let ((value (option-ref options key default)))
        (if (consent-number? value)
            (consent-number-value value)
            value)))

    (define (source-line-starts characters)
      "Return zero-based line starts for a string or character vector."
      (let* ((characters
              (if (string? characters)
                  (list->vector (string->list characters))
                  characters))
             (length (vector-length characters)))
        (let loop ((index 0) (starts '(0)))
          (if (= index length)
              (list->vector (reverse starts))
              (loop (+ index 1)
                    (if (and (char=? (vector-ref characters index) #\newline)
                             (< (+ index 1) length))
                        (cons (+ index 1) starts)
                        starts))))))

    (define (reader-from-source source options)
      "Create a reader state object from SOURCE and per-run option overrides."
      (if (not (string? source))
          (error "consent reader source must be a string" source)
          (let* ((source-metadata
                  (option-ref options 'source-metadata #t))
                 (characters (list->vector (string->list source))))
            ;; Keep cursor access independent of the host's string indexing
            ;; representation.  Some R7RS systems use variable-width UTF-8
            ;; strings, turning repeated indexed access into a large-source
            ;; performance cliff.
            (make-reader source
                         characters
                         0
                         (vector-length characters)
                         (if source-metadata
                             (source-line-starts characters)
                             #f)
                         #f
                         (option-ref options
                                     'symbol-table
                                     consent-default-symbol-table)
                         0
                         '()
                         (option-count options 'max-depth
                                       consent-default-maximum-depth)
                         (option-count options 'max-list-length
                                       consent-default-maximum-list-length)
                         (option-count options 'max-vector-length
                                       consent-default-maximum-vector-length)
                         (option-count
                          options
                          'max-bytevector-length
                          consent-default-maximum-bytevector-length)
                         (option-count options 'max-string-size
                                       consent-default-maximum-string-size)
                         (option-count options 'max-total-nodes
                                       consent-default-maximum-total-nodes)
                         (option-count options 'max-source-metadata
                                       consent-default-maximum-source-metadata)
                         (if source-metadata
                             (option-ref options 'source-id #f)
                             #f)
                         source-metadata
                         (option-ref options 'recovery #f)
                         '()))))

    (define (reader-intern-symbol reader name)
      "Return NAME as an owned symbol, or a private bootstrap symbol."
      (let ((table (reader-symbol-table reader)))
        (if table
            (consent-intern-symbol table name)
            (string->symbol name))))

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
                              (consent-make-canonical-integer
                               (vector-ref metadata 2)))
                (source-field 'column
                              (consent-make-canonical-integer
                               (vector-ref metadata 3)))
                (source-field 'offset
                              (consent-make-canonical-integer
                               (vector-ref metadata 4)))
                (source-field 'span
                              (consent-make-canonical-integer
                               (vector-ref metadata 5)))
                (source-field 'phase 'read))
          metadata))

    (define (source-attachable? datum)
      "Report whether DATUM has stable identity for source metadata."
      (or (pair? datum)
          (vector? datum)
          (string? datum)
          (bytevector? datum)
          (consent-number? datum)
          ;; Owned symbols are represented by records, but retain symbol
          ;; semantics here: identifiers are atomic datums and must not consume
          ;; one retained source-metadata entry per occurrence.
          (and (consent-record? datum)
               (not (consent-symbol? datum)))
          (consent-record-type? datum)))

    (define (consent-datum-source-set! datum source . maybe-limit)
      "Attach SOURCE metadata to DATUM when DATUM has stable identity."
      #((parameters
         (datum
          . ("Datum to associate source metadata with; ignored unless it"
             "has stable identity."))
         (source (type (or source-metadata boolean))
          (description
            ("Source metadata to attach, or #f to attach nothing.")))
         (maybe-limit (type list)
          (description
           ("Optional maximum retained source metadata entries allowed"
             "before this attachment fails closed."))))
        (returns
         . ("DATUM, after attaching SOURCE when DATUM is"
            "identity-attachable, or an error when the metadata table"
            "would exceed its resource limit."))
        (effects state-read state-write error))
      (if (and source (source-attachable? datum))
          (let ((limit
                 (if (null? maybe-limit)
                     consent-default-maximum-source-metadata
                     (car maybe-limit))))
            (if (>= consent-source-metadata-entry-count limit)
                (error
                 "consent datum limit error: source metadata count exceeds \
maximum source metadata"
                 consent-source-metadata-entry-count
                 limit))
            (set! consent-source-metadata
                  (cons (cons datum source)
                        consent-source-metadata))
            (set! consent-source-metadata-entry-count
                  (+ consent-source-metadata-entry-count 1))))
      datum)

    (define (consent-datum-source datum)
      "Return source metadata attached to DATUM, or #f when absent."
      #((parameters
         (datum . "Datum to look up source metadata for."))
        (returns (type (or source-metadata boolean))
         (description
          ("A source-metadata record built from DATUM's attached"
            "metadata, or #f when none is attached.")))
        (effects state-read))
      (let ((cell (assq datum consent-source-metadata)))
        (if cell (source-metadata->record (cdr cell)) #f)))

    (define (datum-source-metadata datum)
      "Return raw source metadata attached to DATUM, or #f when absent."
      (let ((cell (assq datum consent-source-metadata)))
        (if cell (cdr cell) #f)))

    (define (consent-copy-datum-source! target source . maybe-overwrite)
      "Copy source metadata from SOURCE to TARGET, preserving existing metadat\
a"
      "by default."
      #((parameters
         (target . "Datum to receive copied source metadata.")
         (source . "Datum whose attached source metadata is copied.")
         (maybe-overwrite (type list)
          (description
           ("Optional flag; when truthy, overwrite TARGET's existing"
             "metadata."))))
        (returns
         . ("TARGET, with SOURCE's metadata attached when SOURCE has"
            "metadata and overwrite is requested or TARGET had none."))
        (effects state-write))
      (let ((metadata (datum-source-metadata source))
            (overwrite? (and (not (null? maybe-overwrite))
                             (car maybe-overwrite))))
        (if (and metadata
                 (or overwrite?
                     (not (datum-source-metadata target))))
            (consent-datum-source-set! target metadata))
        target))

    (define (push-pending! reader kind)
      "Mark a KIND construct open at the reader cursor for nesting snapshots."
      (set-reader-pending-stack! reader
                                 (cons kind (reader-pending-stack reader))))

    (define (pop-pending! reader)
      "Mark the innermost open construct closed after its delimiter is consume\
d."
      (set-reader-pending-stack! reader
                                 (cdr (reader-pending-stack reader))))

    (define (raise-reader-condition reader kind prefix message irritants)
      "Raise a reader failure as a structured condition under recovery mode, o\
r"
      "as the historical plain error otherwise."
      (if (reader-recovery reader)
          (raise (make-reader-condition kind
                                        (reader-position reader)
                                        message
                                        irritants
                                        (reader-pending-stack reader)))
          (apply error
                 (string-append
                  prefix
                  (consent-integer->radix-string
                   (reader-position reader)
                   10)
                  ": "
                  message)
                 irritants)))

    (define (reader-error reader message . irritants)
      "Raise a reader syntax error annotated with the current source offset."
      (raise-reader-condition reader 'invalid
                              "consent reader error at offset "
                              message irritants))

    (define (reader-incomplete reader message . irritants)
      "Raise a reader failure for a valid prefix that needs more input.  The"
      "default error text is identical to `reader-error`; only recovery mode"
      "tells the two apart."
      (raise-reader-condition reader 'incomplete
                              "consent reader error at offset "
                              message irritants))

    (define (limit-error reader message . irritants)
      "Raise a datum resource-limit error annotated with the current source of\
fset."
      (raise-reader-condition reader 'limit
                              "consent datum limit error at offset "
                              message irritants))

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
      "Return the source character at the current cursor plus an optional offs\
et."
      (let* ((offset (if (null? maybe-offset) 0 (car maybe-offset)))
             (index (+ (reader-position reader) offset)))
        (if (< index (reader-length reader))
            (vector-ref (reader-characters reader) index)
            #f)))

    (define (reader-substring reader start end)
      "Return reader source characters from START up to END as a string."
      (list->string
       (vector->list (reader-characters reader) start end)))

    (define (advance! reader . maybe-count)
      "Move the reader cursor forward by one character or the requested count.\
"
      (let ((count (if (null? maybe-count) 1 (car maybe-count))))
        (set-reader-position! reader (+ (reader-position reader) count))))

    (define (starts-with? reader text)
      "Test whether TEXT appears at the reader cursor without advancing it."
      (let ((position (reader-position reader))
            (end (+ (reader-position reader) (string-length text))))
        (and (<= end (reader-length reader))
             (let loop ((index 0))
               (or (= index (string-length text))
                   (and (char=?
                         (string-ref text index)
                         (vector-ref (reader-characters reader)
                                     (+ position index)))
                        (loop (+ index 1))))))))

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
          (reader-incomplete reader "unterminated block comment"))
         ((starts-with? reader "#|")
          (advance! reader 2)
          (push-pending! reader 'comment)
          (loop (+ depth 1)))
         ((starts-with? reader "|#")
          (advance! reader 2)
          (pop-pending! reader)
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
      "Skip whitespace, comments, directives, and datum comments between \
datums."
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
        (reader-substring reader start (reader-position reader))))

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
      (owned-numeric 'integer-gcd left right))

    (define (integer-power base exponent)
      "Compute BASE raised to nonnegative EXPONENT for reader number parsing."
      (owned-numeric
       'integer-power
       (if (owned-numeric 'integer? base)
           base
           (owned-numeric 'integer-from-small base))
       (if (owned-numeric 'integer? exponent)
           exponent
           (owned-numeric 'integer-from-small exponent))))

    (define (normalize-rational-pair numerator denominator)
      "Normalize a rational numerator and denominator to canonical sign and gc\
d."
      (owned-numeric 'rational-normalize numerator denominator))

    (define (consent-make-canonical-integer value . rest)
      "Canonical number constructors are the public boundary for"
      "canonical Consent numeric values created by readers, primitives,"
      "and result renderers."
      "An already-canonical number is returned unchanged, so a call site"
      "that already carries a reader-owned number can normalize idempotently"
      "alongside a plain host literal from another evaluation posture."
      #((parameters
         (value (type exact-integer)
          (description
           ("Owned or bootstrap host integer, or canonical number returned"
             "unchanged.")))
         (rest (type exact-integer)
          (description
           ("Optional exactness symbol (default `exact') followed by an"
             "optional radix integer (default 10)."))))
        (returns (type exact-integer)
         (description
          ("A canonical integer number record wrapping VALUE with the"
            "requested exactness and radix.")))
        (effects allocation))
      (if (consent-number? value)
          value
          (let ((exactness (if (null? rest) 'exact (car rest)))
                (radix (if (or (null? rest) (null? (cdr rest)))
                           10
                           (cadr rest))))
            (let ((owned
                   (if (owned-numeric 'integer? value)
                       value
                       (owned-numeric 'integer-import-host value))))
              (make-consent-number
             (consent-integer->radix-string owned 10)
             exactness
             radix
             'integer
             owned)))))

    (define (host-inexact-special-kind value)
      "Classify a host-accelerated inexact value at the canonical ingress seam\
."
      (cond
       ((not (= value value)) "+nan.0")
       ((= value (/ 1.0 0.0)) "+inf.0")
       ((= value (/ -1.0 0.0)) "-inf.0")
       (else #f)))

    (define (owned-exact-component value)
      "Return exact component VALUE in owned integer storage."
      (if (consent-number? value)
          (consent-number-value-field value)
          (if (owned-numeric 'integer? value)
              value
              (owned-numeric 'integer-import-host value))))

    (define (canonical-component value)
      "Return VALUE through the bounded bootstrap host adapter."
      (if (consent-number? value)
          (consent-number-value value)
          value))

    (define (consent-make-canonical-decimal value . maybe-lexeme)
      "Public constructor for canonical inexact decimal number records."
      "An already-canonical number is returned unchanged (see"
      "consent-make-canonical-integer)."
      #((parameters
         (value (type (or number consent-number))
          (description
           ("Owned or host inexact number, or canonical number"
             "returned unchanged.")))
         (maybe-lexeme (type string)
          (description
           ("Optional source lexeme string overriding the"
             "host-formatted spelling."))))
        (returns (type consent-number)
         (description
          ("A canonical inexact decimal number record, delegating to"
            "the infnan constructor when VALUE is a host infinity or"
            "NaN.")))
        (effects allocation))
      (if (consent-number? value)
          value
          (let* ((owned-input? (owned-numeric 'binary64? value))
                 (normalized-host
                  (and (not owned-input?)
                       (if (= value 0.0) 0.0 value)))
                 (owned-value
                  (if owned-input?
                      value
                      (owned-numeric
                       'binary64-import-host normalized-host)))
                 (special-kind
                  (case (owned-numeric 'binary64-class owned-value)
                    ((nan) "+nan.0")
                    ((infinity)
                     (if (< (owned-numeric 'binary64-sign owned-value) 0)
                         "-inf.0"
                         "+inf.0"))
                    (else #f))))
            (if special-kind
                (consent-make-canonical-infnan special-kind)
                (make-consent-number
                 (if (null? maybe-lexeme)
                     ;; The lexeme is private syntax metadata. Host-created
                     ;; values may retain the checked accelerator's spelling;
                     ;; external rendering always uses the owned tuple.
                     (if owned-input?
                         (owned-numeric 'binary64->string owned-value)
                         (number->string normalized-host))
                     (car maybe-lexeme))
                 'inexact
                 10
                 'decimal
                 owned-value)))))

    (define (consent-make-canonical-rational
             raw-numerator raw-denominator . rest)
      "Public constructor for normalized rational number records."
      "Canonical-record components are unwrapped to their host payloads."
      #((parameters
         (raw-numerator (type (or exact-integer consent-number))
          (description
            ("Numerator as a host integer or canonical number record.")))
         (raw-denominator (type (or exact-integer consent-number))
          (description
            ("Denominator as a host integer or canonical number record.")))
         (rest (type list)
          (description
           ("Optional exactness symbol followed by an optional radix"
             "integer."))))
        (returns (type consent-number)
         (description
          ("A normalized canonical rational record, collapsing to a"
            "canonical integer when the reduced denominator is one.")))
        (effects allocation))
      (let* ((numerator (owned-exact-component raw-numerator))
             (denominator (owned-exact-component raw-denominator))
             (pair (normalize-rational-pair numerator denominator))
             (normalized-numerator (car pair))
             (normalized-denominator (cdr pair))
             (exactness (if (null? rest) 'exact (car rest)))
             (radix (if (or (null? rest) (null? (cdr rest)))
                        10
                        (cadr rest))))
        (if (= (owned-numeric
                'integer-compare
                normalized-denominator
                (owned-numeric 'integer-from-small 1))
               0)
            (consent-make-canonical-integer
             normalized-numerator
             exactness
             radix)
            (make-consent-number
             (string-append
              (consent-integer->radix-string normalized-numerator 10)
              "/"
              (consent-integer->radix-string normalized-denominator 10))
             exactness
             radix
             'rational
             pair))))

    (define (consent-make-canonical-infnan kind)
      "Public constructor for canonical infinity and NaN number records."
      #((parameters
         (kind
          . ("Special-value spelling, one of \"+inf.0\", \"-inf.0\", or"
             "\"+nan.0\".")))
        (returns (type consent-number)
         (description "A canonical inexact infnan number record for KIND."))
        (effects error))
      (make-consent-number
       (cond
        ((string=? kind "+inf.0") "+inf.0")
        ((string=? kind "-inf.0") "-inf.0")
        ((string=? kind "+nan.0") "+nan.0")
        (else (error "unknown inexact special number" kind)))
       'inexact
       10
       'infnan
       kind))

    (define (consent-make-canonical-complex real imaginary)
      "Public constructor for canonical rectangular complex number records."
      #((parameters
         (real (type consent-number)
          (description "Canonical number record for the real component."))
         (imaginary (type consent-number)
          (description
            ("Canonical number record for the imaginary component."))))
        (returns (type consent-number)
         (description
          ("A canonical complex number record pairing REAL and"
            "IMAGINARY, exact only when both components are exact.")))
        (effects allocation))
      (let ((exactness
             (if (and (eq? (consent-number-exactness real) 'exact)
                      (eq? (consent-number-exactness imaginary)
                           'exact))
                 'exact
                 'inexact)))
        (make-consent-number
         #f
         exactness
         10
         'complex
         (cons real imaginary))))

    (define (consent-number-zero? number)
      "Numeric predicates and helpers inspect the canonical Consent"
      "representation instead of asking the host whether wrapped numbers are"
      "ordinary numbers."
      #((parameters
         (number (type consent-number)
          (description
            ("Value to test; only a canonical number record can be zero."))))
        (returns (type boolean)
         (description
          ("#t when NUMBER is a canonical integer, rational, decimal,"
            "or complex record equal to zero; #f otherwise.")))
        (effects pure))
      (and (consent-number? number)
           (cond
            ((eq? (consent-number-kind number) 'integer)
             (owned-numeric
              'integer-zero? (consent-number-value-field number)))
            ((eq? (consent-number-kind number) 'rational)
             (owned-numeric
              'integer-zero? (car (consent-number-value-field number))))
            ((eq? (consent-number-kind number) 'decimal)
             (owned-numeric
              'binary64-zero? (consent-number-value-field number)))
            ((eq? (consent-number-kind number) 'complex)
             (and (consent-number-zero?
                   (car (consent-number-value-field number)))
                  (consent-number-zero?
                   (cdr (consent-number-value-field number)))))
            (else #f))))

    (define (consent-number-negative? number)
      "Public predicate for negative real Consent Scheme number records."
      #((parameters
         (number (type consent-number)
          (description
            ("Canonical Consent Scheme number record to test for sign."))))
        (returns (type boolean)
         (description
          ("#t when NUMBER is a negative integer, rational, decimal,"
            "or negative infinity; #f otherwise.")))
        (effects pure))
      (cond
       ((eq? (consent-number-kind number) 'integer)
        (owned-numeric
         'integer-negative? (consent-number-value-field number)))
       ((eq? (consent-number-kind number) 'rational)
        (owned-numeric
         'integer-negative? (car (consent-number-value-field number))))
       ((eq? (consent-number-kind number) 'decimal)
        (owned-numeric
         'binary64-negative? (consent-number-value-field number)))
       ((eq? (consent-number-kind number) 'infnan)
        (string=? (consent-number-value number) "-inf.0"))
       (else #f)))

    (define (consent-number-abs number)
      "Public helper that returns the absolute value of an Consent Scheme numb\
er record."
      #((parameters
         (number (type consent-number)
          (description
           ("Canonical Consent Scheme number record to take the"
             "magnitude of."))))
        (returns (type consent-number)
         (description
          ("A canonical number record holding the absolute value of"
            "NUMBER, preserving its exactness and radix.")))
        (effects allocation))
      (cond
       ((eq? (consent-number-kind number) 'integer)
        (consent-make-canonical-integer
         (owned-numeric
          'integer-abs (consent-number-value-field number))
         (consent-number-exactness number)
         (consent-number-radix number)))
       ((eq? (consent-number-kind number) 'rational)
        (let ((value (consent-number-value-field number)))
          (consent-make-canonical-rational
           (owned-numeric 'integer-abs (car value))
           (cdr value)
           (consent-number-exactness number)
           (consent-number-radix number))))
       ((eq? (consent-number-kind number) 'decimal)
        (consent-make-canonical-decimal
         (if (owned-numeric
              'binary64-negative? (consent-number-value-field number))
             (owned-numeric
              'binary64-negate (consent-number-value-field number))
             (consent-number-value-field number))))
       ((eq? (consent-number-kind number) 'infnan)
        (if (string=? (consent-number-value number) "-inf.0")
            (consent-make-canonical-infnan "+inf.0")
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

    (define (consent-number->external number)
      "Public renderer for Consent Scheme numeric values."
      #((parameters
         (number (type (or consent-number number))
          (description
           ("Canonical Consent Scheme number record or plain host"
             "number to render."))))
        (returns (type string)
         (description
          ("A string with the number's canonical external spelling,"
            "accepting plain host numbers so native/exported code can"
            "stay on the ordinary Scheme numeric surface.")))
        (effects error))
      (cond
       ((not (or (consent-number? number) (number? number)))
        (error "consent-number->external expected numeric value" number))
       ((not (consent-number? number))
        (if (and (real? number) (inexact? number))
            (let ((special-kind (host-inexact-special-kind number)))
              (if special-kind
                  special-kind
                  (let ((text (number->string number)))
                    (cond
                     ((integer-decimal-text? text)
                      (string-append text ".0"))
                     ((terminal-dot-decimal-text? text)
                      (string-append text "0"))
                     (else text)))))
            (number->string number)))
       ((eq? (consent-number-kind number) 'integer)
        (consent-integer->radix-string
         (consent-number-value-field number)
         10))
       ((eq? (consent-number-kind number) 'rational)
        (let ((value (consent-number-value-field number)))
          (string-append
           (consent-integer->radix-string (car value) 10)
           "/"
           (consent-integer->radix-string (cdr value) 10))))
       ((eq? (consent-number-kind number) 'decimal)
        (owned-numeric
         'binary64->string (consent-number-value-field number)))
       ((eq? (consent-number-kind number) 'infnan)
        (cond
         ((string=? (consent-number-value number) "+inf.0") "+inf.0")
         ((string=? (consent-number-value number) "-inf.0") "-inf.0")
         (else "+nan.0")))
       ((eq? (consent-number-kind number) 'complex)
        (let* ((value (consent-number-value-field number))
               (real (car value))
               (imaginary (cdr value)))
          (string-append
           (consent-number->external real)
           (if (eq? (consent-number-kind imaginary) 'infnan)
               (consent-number->external imaginary)
               (let ((negative? (consent-number-negative? imaginary))
                     (magnitude (consent-number-abs imaginary)))
                 (string-append
                  (if negative? "-" "+")
                  (consent-number->external magnitude))))
           "i")))
       (else
        (or (consent-number-lexeme number)
            (error "cannot write unknown number kind"
                   (consent-number-kind number))))))

    (define (parse-unsigned-integer digits radix)
      "Parse DIGITS in RADIX into an exact integer or #f on invalid input."
      (owned-numeric 'integer-parse digits radix))

    (define (parse-signed-integer body radix)
      "Parse BODY as an optional-sign integer in RADIX."
      (let ((length (string-length body)))
        (and (> length 0)
             (let* ((first (string-ref body 0))
                    (negative? (char=? first #\-))
                    (signed? (or negative? (char=? first #\+)))
                    (digits (if signed? (substring body 1 length) body))
                    (value (parse-unsigned-integer digits radix)))
               (and value
                    (if negative?
                        (owned-numeric 'integer-negate value)
                        value))))))

    (define (parse-decimal-exponent body)
      "Parse signed decimal exponent BODY as an owned integer."
      (owned-numeric 'integer-parse body 10))

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
                  (parse-decimal-exponent
                   (substring body (+ after-fraction 1) length))
                  (owned-numeric 'integer-from-small 0)))
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
                    (scale
                     (owned-numeric
                      'integer-subtract
                      exponent
                      (owned-numeric
                       'integer-from-small (string-length fraction)))))
               (and integer
                    (if (owned-numeric 'integer-zero? integer)
                        (cons integer
                              (owned-numeric 'integer-from-small 1))
                        (if (not (owned-numeric 'integer-negative? scale))
                            (cons
                             (owned-numeric
                              'integer-multiply
                              (if (< sign 0)
                                  (owned-numeric 'integer-negate integer)
                                  integer)
                              (integer-power 10 scale))
                             (owned-numeric 'integer-from-small 1))
                            (cons
                             (if (< sign 0)
                                 (owned-numeric 'integer-negate integer)
                                 integer)
                             (integer-power
                              10
                              (owned-numeric
                               'integer-negate scale))))))))))

    (define (rational-pair->inexact pair)
      "Convert a normalized rational pair to an owned binary64 value."
      (let ((numerator
             (owned-numeric
              'integer->small (car pair) 9007199254740991))
            (denominator
             (owned-numeric
              'integer->small (cdr pair) 9007199254740991)))
        (if (and numerator denominator)
            (owned-numeric
             'binary64-import-host
             (/ (inexact numerator) (inexact denominator)))
            (owned-numeric 'binary64-from-rational pair))))

    (define (number->reader-float number)
      "Convert a Consent number through the reader's temporary polar-math seam\
."
      (cond
       ((eq? (consent-number-kind number) 'integer)
        (owned-numeric
         'binary64->host
         (owned-numeric
          'binary64-from-rational
          (cons (consent-number-value-field number)
                (owned-numeric 'integer-from-small 1)))))
       ((eq? (consent-number-kind number) 'rational)
        (owned-numeric
         'binary64->host
         (rational-pair->inexact
          (consent-number-value-field number))))
       ((eq? (consent-number-kind number) 'decimal)
        (owned-numeric
         'binary64->host (consent-number-value-field number)))
       ((eq? (consent-number-kind number) 'infnan)
        (cond
         ((string=? (consent-number-value number) "+inf.0")
          (/ 1.0 0.0))
         ((string=? (consent-number-value number) "-inf.0")
          (/ -1.0 0.0))
         (else (/ 0.0 0.0))))
       (else 0.0)))

    (define (parse-real-number-body reader token body exactness radix)
      "Parse the body of a real-number token into the reader's numeric record.\
"
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
          (consent-make-canonical-infnan
           (cond
            ((string=? lower "+inf.0") "+inf.0")
            ((string=? lower "-inf.0") "-inf.0")
            (else "+nan.0"))))
         ((parse-signed-integer body radix)
          => (lambda (value)
               (if (eq? exactness 'inexact)
                   (consent-make-canonical-decimal
                    (rational-pair->inexact
                     (cons value
                           (owned-numeric 'integer-from-small 1))))
                   (consent-make-canonical-integer value 'exact radix))))
         ((string-index body #\/ 0)
          (let ((parts (split-on-char body #\/)))
            (if (not (= (length parts) 2))
                #f
                (let ((numerator
                       (parse-signed-integer (car parts) radix))
                      (denominator
                       (parse-unsigned-integer (cadr parts) radix)))
                  (cond
                   ((and numerator
                         denominator
                         (owned-numeric 'integer-zero? denominator))
                    (reader-error reader "invalid rational number" token))
                   ((and numerator denominator)
                    (if (eq? exactness 'inexact)
                        (consent-make-canonical-decimal
                         (rational-pair->inexact
                          (cons numerator denominator)))
                        (consent-make-canonical-rational
                         numerator denominator 'exact radix)))
                   (else #f))))))
         ((and (= radix 10) (decimal-components body))
          (let ((pair (parse-exact-decimal body)))
            (if (eq? exactness 'exact)
                (consent-make-canonical-rational
                 (car pair)
                 (cdr pair))
                (consent-make-canonical-decimal
                 (rational-pair->inexact pair)
                 body))))
         (else #f))))

    (define (complex-split-index body radix)
      "Find a rectangular split in BODY under numeric RADIX."
      (let loop ((index 1) (split #f))
        (if (>= index (string-length body))
            split
            (let ((char (string-ref body index))
                  (previous (string-ref body (- index 1))))
              (loop (+ index 1)
                    (if (and (or (char=? char #\+)
                                 (char=? char #\-))
                             (or (not (= radix 10))
                                 (not (or (char=? previous #\e)
                                          (char=? previous #\E)))))
                        index
                        split))))))

    (define (parse-complex-number-body reader token body exactness radix)
      "Parse a complex-number token into rectangular or polar numeric records.\
"
      (let ((lower (string-foldcase body)))
        (cond
         ((string-suffix? "i" lower)
          (let* ((rectangular (substring body 0 (- (string-length body) 1)))
                 (split (complex-split-index rectangular radix))
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
                        (consent-make-canonical-complex
                         real
                         imaginary))))))
         ((string-index body #\@ 0)
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
                          (consent-make-canonical-complex
                           (consent-make-canonical-decimal
                            (* r (cos theta)))
                           (consent-make-canonical-decimal
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

    (define (number-token-candidate? token)
      "Report whether TOKEN can begin an R7RS numeric literal."
      "This constant-time gate keeps ordinary identifiers out of the full"
      "radix, exactness, real, rational, decimal, and complex-number parser."
      (let ((length (string-length token)))
        (and (> length 0)
             (let ((first (string-ref token 0)))
               (or (and (char>=? first #\0) (char<=? first #\9))
                   (char=? first #\#)
                   (and (or (char=? first #\+) (char=? first #\-))
                        (> length 1))
                   (and (char=? first #\.)
                        (> length 1)
                        (let ((second (string-ref token 1)))
                          (and (char>=? second #\0)
                               (char<=? second #\9)))))))))

    (define (hex-scalar-value reader digits)
      "Validate and return a hexadecimal Unicode scalar value."
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
              value)
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
            (reader-incomplete reader "unterminated hexadecimal escape"))
        (let ((digits (reader-substring reader
                                        start
                                        (reader-position reader))))
          (advance! reader)
          (integer->char (hex-scalar-value reader digits)))))

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
      (push-pending! reader 'string)
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
            (reader-incomplete reader
                               "expected line ending in string continuation"))
                    )
          (let loop-trailing ()
            (if (intraline-whitespace? (peek reader))
                (begin
                  (advance! reader)
                  (loop-trailing)))))
        (let loop ()
          (cond
           ((eof? reader)
            (reader-incomplete reader "unterminated string"))
           ((char=? (peek reader) #\")
            (advance! reader)
            (pop-pending! reader)
            (list->string (reverse result)))
           ((char=? (peek reader) #\\)
            (advance! reader)
            (let ((escaped (peek reader)))
              (cond
               ((not escaped)
                (reader-incomplete reader "unterminated string escape"))
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
      (push-pending! reader 'symbol)
      (let ((result '()))
        (let loop ()
          (cond
           ((eof? reader)
            (reader-incomplete reader "unterminated vertical symbol"))
           ((char=? (peek reader) #\|)
            (advance! reader)
            (pop-pending! reader)
            (let ((name (list->string (reverse result))))
              (if (reader-fold-case reader)
                  (string-foldcase name)
                  name)))
           ((char=? (peek reader) #\\)
            (advance! reader)
            (let ((escaped (peek reader)))
              (cond
               ((not escaped)
                (reader-incomplete reader "unterminated vertical symbol \
escape"))
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

    (define (character-name-start? char)
      "Report whether CHAR (an ASCII letter) can begin a named or #\\x hex \
literal."
      (and char
           (or (and (char<=? #\a char) (char<=? char #\z))
               (and (char<=? #\A char) (char<=? char #\Z)))))

    (define (read-character-literal reader)
      "Read an R7RS character literal after the #\\\\ introducer."
      (advance! reader 2)
      (if (eof? reader)
          (reader-incomplete reader "missing character after #\\"))
      (let ((first (peek reader)))
        (if (not (character-name-start? first))
            ;; Any non-letter first character — including delimiters and
            ;; bracket/pipe characters like #\( #\) #\[ #\] #\| — is taken
            ;; literally per the R7RS grammar #\<any character>. read-token
            ;; would refuse these (delimiter or reserved), so take the
            ;; character directly.
            (begin
              (advance! reader)
              (consent-host-character->character first))
            (let* ((token (read-token reader))
                   (name (if (reader-fold-case reader)
                             (string-foldcase token)
                             token)))
              (cond
               ((and (> (string-length token) 1)
                     (or (char=? (string-ref token 0) #\x)
                         (char=? (string-ref token 0) #\X)))
                (consent-make-character
                 (hex-scalar-value
                  reader
                  (substring token 1 (string-length token)))))
               ((string=? name "alarm") (consent-make-character 7))
               ((string=? name "backspace") (consent-make-character 8))
               ((string=? name "delete") (consent-make-character 127))
               ((string=? name "escape") (consent-make-character 27))
               ((string=? name "newline") (consent-make-character 10))
               ((string=? name "null") (consent-make-character 0))
               ((string=? name "return") (consent-make-character 13))
               ((string=? name "space") (consent-make-character 32))
               ((string=? name "tab") (consent-make-character 9))
               ((= (string-length token) 1)
                (consent-host-character->character (string-ref token 0)))
               (else
                (reader-error reader "unknown character literal" token)))))))

    (define (classify-token reader token)
      "Classify a raw token as number, boolean, identifier, or syntax error."
      (cond
       ((or (string=? token "#t") (string=? token "#true")) #t)
       ((or (string=? token "#f") (string=? token "#false")) #f)
       ((and (number-token-candidate? token)
             (parse-number-token reader token))
        => (lambda (number) number))
       ((identifier-token? token)
        (reader-intern-symbol
         reader
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
      (push-pending! reader 'list)
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
            (reader-incomplete reader "unterminated list"))
           ((char=? (peek reader) #\))
            (advance! reader)
            (pop-pending! reader)
            (note-node! reader)
            head)
           (else
            (let ((saved (reader-position reader)))
              ;; A period is dotted-tail syntax only when it is a delimited
              ;; token. Otherwise restore the cursor and classify it
              ;; normally.
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
                                      "expected closing parenthesis after \
dotted tail"))
                    (advance! reader)
                    (pop-pending! reader)
                    (note-node! reader)
                    head)
                  (begin
                    (set-reader-position! reader saved)
                    (append! (read-datum reader (+ depth 1)))
                    (loop)))))))))

    (define (read-vector-elements reader depth kind close-char maximum-length)
      "Read vector or bytevector elements under the active length budget."
      (check-depth reader depth)
      (push-pending! reader (string->symbol kind))
      (let loop ((items '()) (count 0))
        (skip-intertoken-space! reader depth)
        (cond
         ((eof? reader)
          (reader-incomplete reader "unterminated sequence" kind))
         ((char=? (peek reader) close-char)
          (advance! reader)
          (pop-pending! reader)
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
      "Extract an exact integer value from an Consent Scheme number datum."
      (and (consent-number? datum)
           (eq? (consent-number-kind datum) 'integer)
           (eq? (consent-number-exactness datum) 'exact)
           (consent-number-value datum)))

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

    (define (read-bytevector-literal reader depth)
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
                          (consent-datum->external (car rest))))))))

    (define (quote-datum reader name datum)
      "Build the canonical abbreviated quote form for NAME and DATUM."
      (list (reader-intern-symbol reader name) datum))

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
        (let* ((id (reader-substring reader
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
       ((starts-with? reader "#u8(") (read-bytevector-literal reader depth))
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
          (reader-incomplete reader "unexpected end of input"))
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
                        (reader-intern-symbol
                         reader
                         (read-vertical-symbol-name reader))))
                   (note-node! reader)
                   datum))
                ((char=? char #\')
                 (advance! reader)
                 (let ((datum (quote-datum reader "quote"
                                           (read-datum reader (+ depth 1)))))
                   (note-node! reader)
                   datum))
                ((char=? char #\`)
                 (advance! reader)
                 (let ((datum (quote-datum reader "quasiquote"
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
                               reader
                               "unquote-splicing"
                               (read-datum reader (+ depth 1)))))
                         (note-node! reader)
                         datum))
                     (let ((datum
                            (quote-datum
                             reader
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
              (consent-datum-source-set!
               datum
               (source-note reader start (reader-position reader))
               (reader-maximum-source-metadata reader))
              datum))))

    (define (options-from-rest maybe-options)
      "Normalize optional argument lists to an options association list."
      (if (null? maybe-options) '() (car maybe-options)))

    (define (consent-read source . maybe-options)
      "Read one datum from SOURCE, enforce complete input consumption, and"
      "validate the resulting host data against Consent Scheme resource \
limits."
      #((parameters
         (source (type (or string port))
          (description
           ("Source string or port body to read a single datum from.")))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying budget overrides."))))
        (returns
         . ("The single datum read from SOURCE after confirming no"
            "trailing input remains."))
        (effects error))
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options)))
        (set-reader-datum-labels! reader '())
        (let ((datum (resolve-datum-labels (read-datum reader 0)
                                           reader)))
          (skip-intertoken-space! reader 0)
          (if (not (eof? reader))
              (reader-error reader "unexpected trailing input"))
          (consent-validate-datum datum options)
          datum)))

    (define (consent-read-all source . maybe-options)
      "Read a source body into datums for program/library evaluation.  Datum"
      "labels are scoped per datum, matching R7RS external representations."
      #((parameters
         (source (type (or string port))
          (description
           ("Source string or port body to read fully into datums.")))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying budget overrides."))))
        (returns (type list)
         (description
          ("A list of every datum read from SOURCE, in source order,"
            "each validated against the resource budgets.")))
        (effects error))
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
                        (consent-validate-datum (car rest) options)
                        (validate-loop (cdr rest))))))
              (begin
                (set-reader-datum-labels! reader '())
                (loop (cons (resolve-datum-labels
                             (read-datum reader 0)
                             reader)
                            datums)))))))

    (define (consent-read-from-string-at source position . maybe-options)
      "Incremental read entry point for ports and REPL-like \
callers; the cdr of"
      "the result is the next source offset no matter which datum was returned\
."
      #((parameters
         (source (type string)
          (description "Source string to read one datum from."))
         (position (type exact-non-negative-integer)
          (description
           ("Nonnegative offset within SOURCE at which to begin"
             "reading.")))
         (maybe-options (type list)
          (description
            ("Optional reader options alist supplying budget overrides."))))
        (returns (type pair)
         (description
          ("A pair whose car is the read datum (or the end-of-file"
            "object) and whose cdr is the next source offset.")))
        (effects error))
      (set! position (canonical-component position))
      (if (not (string? source))
          (error "consent reader source must be a string" source))
      (if (or (not (integer? position))
              (< position 0)
              (> position (string-length source)))
          (error "consent reader position out of range" position))
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options)))
        (set-reader-position! reader position)
        (skip-intertoken-space! reader 0)
        (if (eof? reader)
            (cons consent-read-eof (reader-position reader))
            (begin
              (set-reader-datum-labels! reader '())
              (let ((datum (resolve-datum-labels
                            (read-datum reader 0)
                            reader)))
                (consent-validate-datum datum options)
                (cons datum (reader-position reader)))))))

    ;;;; Reader recovery: errors as data, resynchronization, and spans.

    (define (form-start-char? char)
      "Report whether CHAR can begin a top-level form for resync purposes."
      (not (or (whitespace? char)
               (char=? char #\)))))

    (define (consent-resync-to-next-form source position)
      "Form-level batch resync strategy: return the offset of the next"
      "top-level form strictly after POSITION.  A top-level form is anchored t\
o"
      "a line start whose first character is neither whitespace nor a closing"
      "parenthesis; when none remains, return the end of SOURCE.  This is the"
      "default recovery resync strategy; callers may supply their own (for"
      "example a lexer-level or editor-grade strategy) through the `resync`"
      "option."
      #((parameters
         (source (type string)
          (description
            ("Source string being scanned for the next top-level form.")))
         (position (type exact-integer)
          (description
            ("Offset after which to search for the next top-level form."))))
        (returns (type exact-integer)
         (description
          ("The offset of the next line-anchored top-level form"
            "strictly after POSITION, or the length of SOURCE when none"
            "remains.")))
        (effects pure))
      (set! position (canonical-component position))
      (let ((length (string-length source)))
        (let loop ((index position))
          (cond
           ((>= index length) length)
           ((and (> index position)
                 (char=? (string-ref source (- index 1)) #\newline)
                 (form-start-char? (string-ref source index)))
            index)
           (else (loop (+ index 1)))))))

    (define (render-irritant value)
      "Render one reader-error irritant as stable text for a diagnostic reason\
."
      (cond
       ((string? value) value)
       ((reader-datum-symbol? value) (reader-datum-symbol-name value))
       ((consent-character? value)
        (string (consent-character->host-character value)))
       ((or (consent-number? value) (number? value))
        (consent-number->external value))
       (else "?")))

    (define (condition-reason condition)
      "Return the human-readable reason text for a reader CONDITION."
      (let ((message (reader-condition-message condition))
            (irritants (reader-condition-irritants condition)))
        (if (null? irritants)
            message
            (string-append
             message
             ": "
             (join (map render-irritant irritants) " ")))))

    (define (recovery-range line-starts start end)
      "Build a diagnostic-range datum spanning START..END using LINE-STARTS. "
      "The shape matches `(agent diagnostics)` `make-diagnostic-range`."
      (let ((start-position (line-starts-line-column line-starts start))
            (end-position (line-starts-line-column line-starts end)))
        (list 'diagnostic-range
              (list 'start (consent-make-canonical-integer start))
              (list 'end (consent-make-canonical-integer end))
              (list 'line (consent-make-canonical-integer (car
                start-position)))
              (list 'column (consent-make-canonical-integer (cdr
                start-position)))
              (list 'end-line (consent-make-canonical-integer (car
                end-position)))
              (list 'end-column
                    (consent-make-canonical-integer (cdr end-position))))))

    (define (recovery-diagnostic source-id kind reason range)
      "Build a Scheme-readable diagnostic datum for a recovery event.  The"
      "shape matches `(agent diagnostics)` `make-diagnostic`; KIND (`invalid`"
      "or `incomplete`) rides in the metadata so every host adapter consumes i\
t"
      "identically."
      (list 'diagnostic
            (list 'severity 'error)
            (list 'message reason)
            (list 'source 'reader)
            (list 'file (if source-id source-id #f))
            (list 'buffer #f)
            (list 'range range)
            (list 'metadata
                  (list (list 'kind kind)
                        (list 'phase 'read)))))

    (define (recovery-span kind reason range text)
      "Build a recovery span datum recording one skipped or incomplete region. \
"
      "TEXT preserves the source bytes so recovery never silently drops input;\
"
      "the range vocabulary is shared with comment trivia and CST recovery"
      "nodes."
      (list 'recovery-span
            (list 'kind kind)
            (list 'reason reason)
            (list 'range range)
            (list 'text text)))

    (define (guard-reader-failure reader thunk)
      "Run THUNK, returning its value tagged (value . V), or (condition . C)"
      "when it raises.  Non-reader conditions are normalized to an `invalid`"
      "reader condition at the current offset."
      (call/cc
       (lambda (return)
         (with-exception-handler
          (lambda (condition)
            (return
             (cons 'condition
                   (if (reader-condition? condition)
                       condition
                       (make-reader-condition
                        'invalid
                        (reader-position reader)
                        (if (error-object? condition)
                            (error-object-message condition)
                            "reader error")
                        (if (error-object? condition)
                            (error-object-irritants condition)
                            '())
                        '())))))
          (lambda ()
            (cons 'value (thunk)))))))

    (define (build-failure-step reader resync line-starts source-id start
      condition)
      "Build the <consent-recovery-step> for a reader failure anchored at"
      "START.  Incomplete input rewinds to START and carries the open-construc\
t"
      "stack; a genuine error advances past the malformed region via RESYNC"
      "with guaranteed forward progress."
      (let ((kind (reader-condition-kind condition))
            (reason (condition-reason condition)))
        (if (eq? kind 'incomplete)
            (let* ((end (reader-length reader))
                   (range (recovery-range line-starts start end))
                   (text (reader-substring reader start end))
                   (diagnostic
                    (recovery-diagnostic source-id 'incomplete reason range))
                   (span (recovery-span 'incomplete reason range text)))
              (set-reader-position! reader start)
              (make-recovery-step 'incomplete #f diagnostic span start
                                  (reader-condition-pending condition)))
            (let* ((proposed (resync (reader-source reader) start))
                   (next (min (reader-length reader)
                              (max proposed (+ start 1))))
                   (range (recovery-range line-starts start next))
                   (text (reader-substring reader start next))
                   (diagnostic
                    (recovery-diagnostic source-id 'invalid reason range))
                   (span (recovery-span 'invalid reason range text)))
              (set-reader-position! reader next)
              (make-recovery-step 'invalid #f diagnostic span next #f)))))

    (define (recover-step! reader resync line-starts source-id options)
      "Read one form in recovery mode and return a <consent-recovery-step>. "
      "Leading trivia is skipped first so a malformed region is anchored at th\
e"
      "datum start, not at preceding whitespace; trivia-level failures (such a\
s"
      "an unterminated block comment) are anchored where the trivia began."
      ;; A prior step that unwound mid-construct leaves stale open-construct
      ;; entries behind; each step starts from a balanced cursor, so reset.
      (set-reader-pending-stack! reader '())
      (let* ((pre (reader-position reader))
             (skip-outcome
              (guard-reader-failure
               reader
               (lambda () (skip-intertoken-space! reader 0)))))
        (cond
         ((eq? (car skip-outcome) 'condition)
          (build-failure-step reader resync line-starts source-id
                              pre (cdr skip-outcome)))
         ((eof? reader)
          (make-recovery-step 'eof #f #f #f (reader-position reader) #f))
         (else
          (let* ((start (reader-position reader))
                 (read-outcome
                  (guard-reader-failure
                   reader
                   (lambda ()
                     (set-reader-datum-labels! reader '())
                     (let ((datum (resolve-datum-labels
                                   (read-datum reader 0)
                                   reader)))
                       (consent-validate-datum datum options)
                       datum)))))
            (if (eq? (car read-outcome) 'value)
                (make-recovery-step 'datum (cdr read-outcome) #f #f
                                    (reader-position reader) #f)
                (build-failure-step reader resync line-starts source-id
                                    start (cdr read-outcome))))))))

    (define (recovery-reader source options)
      "Create a recovery-mode reader over SOURCE, forcing the recovery flag on\
."
      (reader-from-source source (cons (cons 'recovery #t) options)))

    (define (consent-read-recover source . maybe-options)
      "Read SOURCE in recovery mode, collecting every readable datum plus an"
      "ordered diagnostics list and recovery spans instead of aborting on the"
      "first malformed form.  The result's STATUS is `incomplete` when the"
      "trailing region is a valid prefix awaiting more input, otherwise"
      "`complete`.  The resync point is caller-selectable through the `resync`\
"
      "option (defaulting to `consent-resync-to-next-form`)."
      #((parameters
         (source (type string)
          (description "Source string to read fully in recovery mode."))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying `resync',"
             "`source-id', and budget overrides."))))
        (returns (type consent-recovery-result)
         (description
          ("A `<consent-recovery-result>' bundling the readable"
            "datums, the ordered diagnostics, the recovery spans, and a"
            "STATUS of `complete' or `incomplete'.")))
        (effects error))
      (if (not (string? source))
          (error "consent reader source must be a string" source))
      (let* ((options (options-from-rest maybe-options))
             (resync (option-ref options 'resync consent-resync-to-next-form))
             (source-id (option-ref options 'source-id #f))
             (line-starts (source-line-starts source))
             (reader (recovery-reader source options)))
        (let loop ((datums '()) (diagnostics '()) (spans '()))
          (let* ((step (recover-step! reader resync line-starts
                                      source-id options))
                 (status (consent-recovery-step-status step)))
            (cond
             ((eq? status 'eof)
              (make-recovery-result (reverse datums)
                                    (reverse diagnostics)
                                    (reverse spans)
                                    'complete))
             ((eq? status 'datum)
              (loop (cons (consent-recovery-step-datum step) datums)
                    diagnostics
                    spans))
             ((eq? status 'incomplete)
              (make-recovery-result
               (reverse datums)
               (reverse (cons (consent-recovery-step-diagnostic step)
                              diagnostics))
               (reverse (cons (consent-recovery-step-span step) spans))
               'incomplete))
             (else
              (loop datums
                    (cons (consent-recovery-step-diagnostic step) diagnostics)
                    (cons (consent-recovery-step-span step) spans))))))))

    (define (consent-read-recover-from-string-at source position .
      maybe-options)
      "Recovery-aware single-form read for interactive and streaming callers"
      "(REPL, editor adapters).  Returns a <consent-recovery-step> whose STATU\
S"
      "is `datum`, `invalid`, `incomplete`, or `eof`, and whose NEXT offset is\
"
      "where the caller should resume.  Incomplete input is surfaced as its ow\
n"
      "status so auto-indent and continuation prompts never confuse a valid"
      "prefix with a syntax error."
      #((parameters
         (source (type string)
          (description "Source string to read one recovery step from."))
         (position (type exact-non-negative-integer)
          (description
           ("Nonnegative offset within SOURCE at which to begin"
             "reading.")))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying `resync',"
             "`source-id', and budget overrides."))))
        (returns (type consent-recovery-step)
         (description
          ("A `<consent-recovery-step>' describing the next form:"
            "STATUS is `datum', `invalid', `incomplete', or `eof', and"
            "NEXT is the offset to resume from.")))
        (effects error))
      (set! position (canonical-component position))
      (if (not (string? source))
          (error "consent reader source must be a string" source))
      (if (or (not (integer? position))
              (< position 0)
              (> position (string-length source)))
          (error "consent reader position out of range" position))
      (let* ((options (options-from-rest maybe-options))
             (resync (option-ref options 'resync consent-resync-to-next-form))
             (source-id (option-ref options 'source-id #f))
             (line-starts (source-line-starts source))
             (reader (recovery-reader source options)))
        (set-reader-position! reader position)
        (recover-step! reader resync line-starts source-id options)))

    (define (validation-note-node! validation)
      "Charge one validation node against the post-read total-node budget."
      (set-validation-node-count!
       validation
       (+ (validation-node-count validation) 1))
      (if (> (validation-node-count validation)
             (validation-maximum-total-nodes validation))
          (error
            "consent datum limit error: datum node count exceeds maximum total \
nodes"
                 (validation-maximum-total-nodes validation))))

    (define (validate-datum datum options validation depth seen)
      "Datum validation protects the evaluator from host-constructed values"
      "that bypassed lexical reader checks, including cycles and oversized"
      "objects."
      (if (> depth
             (option-count options 'max-depth
                         consent-default-maximum-depth))
          (error "consent datum limit error: datum depth exceeds maximum depth\
"
                 depth))
      (cond
       ((or (boolean? datum)
            (reader-datum-symbol? datum)
            (consent-character? datum)
            (consent-number? datum))
        (validation-note-node! validation))
       ((string? datum)
        (if (> (string-length datum)
               (option-count options 'max-string-size
                           consent-default-maximum-string-size))
            (error
              "consent datum limit error: string size exceeds maximum string s\
ize"
                   (option-count options 'max-string-size
                               consent-default-maximum-string-size)))
        (validation-note-node! validation))
       ((bytevector? datum)
        (if (> (bytevector-length datum)
               (option-count options 'max-bytevector-length
                           consent-default-maximum-bytevector-length))
            (error
              "consent datum limit error: bytevector length exceeds maximum by\
tevector length"
                   (option-count options 'max-bytevector-length
                               consent-default-maximum-bytevector-length)))
        (let loop ((index 0))
          (if (< index (bytevector-length datum))
              (begin
                (if (not (let ((byte (bytevector-u8-ref datum index)))
                           (and (integer? byte) (<= 0 byte) (<= byte 255))))
                    (error
                      "consent reader error: bytevector contains invalid byte"
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
                         (option-count options 'max-list-length
                                     consent-default-maximum-list-length))
                      (error
                        "consent datum limit error: list length exceeds maximu\
m list length"
                             (option-count options 'max-list-length
                                         consent-default-maximum-list-length)))
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
                     (option-count options 'max-vector-length
                                 consent-default-maximum-vector-length))
                  (error
                    "consent datum limit error: vector length exceeds maximum \
vector length"
                         (option-count options 'max-vector-length
                                     consent-default-maximum-vector-length)))
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
        (error "consent reader error: datum contains unsupported object"
               datum))))

    (define (consent-validate-datum datum . maybe-options)
      "Public validation returns DATUM unchanged so callers can place it inlin\
e"
      "in read/evaluate pipelines while still enforcing depth and size budgets\
."
      #((parameters
         (datum . "Datum to validate against the resource budgets.")
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying `max-depth',"
             "`max-total-nodes', `max-string-size', and"
             "`max-bytevector-length' overrides."))))
        (returns . "DATUM unchanged when it stays within every budget.")
        (effects error))
      (let* ((options (options-from-rest maybe-options))
             (validation
              (make-validation
               0
               (option-count options 'max-total-nodes
                           consent-default-maximum-total-nodes))))
        (validate-datum datum options validation 0 '())
        datum))

    (define (escape-text text vertical-symbol?)
      "Escape TEXT for a string or, when requested, a vertical symbol."
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
                 ((and vertical-symbol? (char=? char #\|)) "\\|")
                 (else (string char)))
                parts))))))

    (define (escape-string text)
      "Escape string TEXT for stable external rendering."
      (escape-text text #f))

    (define (escape-symbol-name name)
      "Escape vertical symbol NAME for stable external rendering."
      (escape-text name #t))

    (define (symbol-needs-bars? name)
      "Report whether NAME requires vertical bars in external syntax."
      (or (not (identifier-token? name))
          (parse-number-token (reader-from-source "" '()) name)))

    (define (write-symbol-name name)
      "Render a symbol name with escaping when the token grammar requires it."
      (if (symbol-needs-bars? name)
          (string-append "|" (escape-symbol-name name) "|")
          name))

    (define (write-character-datum char)
      "Render a character in canonical R7RS external syntax."
      (let ((code (consent-character-code char)))
        (cond
         ((= code 7) "#\\alarm")
         ((= code 8) "#\\backspace")
         ((= code 127) "#\\delete")
         ((= code 27) "#\\escape")
         ((= code 10) "#\\newline")
         ((= code 0) "#\\null")
         ((= code 13) "#\\return")
         ((= code 32) "#\\space")
         ((= code 9) "#\\tab")
         ((or (< code 33) (= code 127))
          (string-append
           "#\\x"
           (consent-integer->radix-string code 16)))
         (else
          (string-append
           "#\\"
           (string (consent-character->host-character char)))))))

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

    (define (consent-datum->external datum . maybe-options)
      "Render Consent Scheme datums with stable external syntax, including"
      "shared and circular structure labels for write/shared mode."
      #((parameters
         (datum . "Consent Scheme datum to render as external text.")
         (maybe-options (type list)
          (description
           ("Optional `mode' symbol (`write', `shared', or `display')"
             "followed by an optional display flag controlling string"
             "and character quoting."))))
        (returns (type string)
         (description
          ("A string holding the datum's external representation,"
            "emitting `#N=`/`#N#` datum labels for shared and circular"
            "structure in write/shared mode.")))
        (effects allocation))
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
           ((reader-datum-symbol? name) (reader-datum-symbol-name name))
           ((string? name) name)
           (else (error "consent reader error: invalid record name"
                        name))))

        (define (render value)
          (if (label-needed? value)
              (let ((label (label-for value)))
                (if (memq value emitted)
                    (string-append
                     "#"
                     (consent-integer->radix-string label 10)
                     "#")
                    (begin
                      (set! emitted (cons value emitted))
                      (string-append
                       "#"
                       (consent-integer->radix-string label 10)
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
                      (cons (consent-integer->radix-string
                             (bytevector-u8-ref value index)
                             10)
                            parts)))))

        (define (render-body value)
          (cond
           ((boolean? value) (if value "#t" "#f"))
           ((null? value) "()")
           ((reader-datum-symbol? value)
            (if display?
                (reader-datum-symbol-name value)
                (write-symbol-name (reader-datum-symbol-name value))))
           ((consent-character? value)
            (if display?
                (string (consent-character->host-character value))
                (write-character-datum value)))
           ((or (consent-number? value) (number? value))
            (consent-number->external value))
           ((string? value)
            (if display?
                value
                (string-append "\"" (escape-string value) "\"")))
           ((bytevector? value) (render-bytevector value))
           ((pair? value) (render-list value))
           ((vector? value) (render-vector value))
           ((consent-record? value)
            (string-append
             "#<record "
             (record-name->external
              (consent-record-type-name
               (consent-record-type value)))
             ">"))
           ((consent-record-type? value)
            (string-append
             "#<record-type "
             (record-name->external
              (consent-record-type-name value))
             ">"))
           (else
            (error "consent reader error: cannot write unsupported datum"
                   value))))

        (scan datum '())
        (if (and (eq? mode 'simple) (not (null? cyclic)))
            (error
              "consent reader error: write-simple cannot render circular datum\
"))
        (render datum)))

    (define (consent--render-limit-ref limits key)
      "Return the host-integer ceiling for KEY in the LIMITS alist, or #f when\
"
      "KEY is absent.  A ceiling may arrive as a host integer (the usual"
      "interactive default) or as a Consent number record (when LIMITS came fr\
om"
      "evaluated Consent data, such as a `render-limits' option read on a"
      "self-hosted host); since the bounded renderer's depth/length/size count\
ers"
      "are host integers, a number record is normalized through"
      "`consent-number-value' so the host comparisons do not compare an intege\
r"
      "against a record and raise."
      (let ((entry (and (pair? limits) (assq key limits))))
        (and entry
             (let ((value (cdr entry)))
               (if (consent-number? value)
                   (consent-number-value value)
                   value)))))

    (define (consent-datum->external-bounded datum limits . maybe-mode+display)
      "Render DATUM as external text bounded by LIMITS so a deep, long, or"
      "cyclic value renders in bounded time and space with the `...' truncatio\
n"
      "marker instead of wedging an interactive loop or flooding output (#508)\
."
      #((parameters
         (datum . "Datum to render for an interactive display surface.")
         (limits (type list)
          (description
           ("Alist `((depth . D) (length . L) (size . S))' of"
             "nonnegative integer ceilings, each #f or absent for no"
             "ceiling: DEPTH bounds nesting (a compound at the ceiling"
             "renders as the marker), LENGTH bounds the elements"
             "rendered per list/vector/bytevector (the overflow renders"
             "as a trailing marker), and SIZE bounds the total"
             "characters emitted (a hard backstop that stops the walk"
             "once reached, so rendering is bounded in time as well as"
             "space).")))
         (maybe-mode+display (type list)
          (description
            ("Optional `consent-datum->external' mode and display flag."))))
        (returns (type string)
         (description
          ("Bounded external text: each elided depth/length/size point"
            "and each shared or circular back-edge renders as the"
            "parseable `...' marker, so rendering always terminates"
            "regardless of LIMITS. Atoms delegate to the unbounded"
            "`consent-datum->external', so numbers, strings, symbols,"
            "characters, and records render identically to the"
            "canonical writer.")))
        (effects pure))
      ;; The canonical writer stays unbounded for the capture/round-trip
      ;; surface;
      ;; this bound is the interactive display path only.
      (let ((mode (if (pair? maybe-mode+display) (car maybe-mode+display)
        'write))
            (displayp (if (and (pair? maybe-mode+display)
                               (pair? (cdr maybe-mode+display)))
                          (cadr maybe-mode+display)
                          #f))
            (depth-limit (consent--render-limit-ref limits 'depth))
            (length-limit (consent--render-limit-ref limits 'length))
            (size-limit (consent--render-limit-ref limits 'size))
            (marker "...")
            (parts '())
            (used 0)
            (overflow #f)
            (ancestors '()))

        (define (raw-emit! text)
          "Append TEXT to the output accumulator and charge its length against\
"
          "the running size counter, without consulting the size ceiling."
          (set! parts (cons text parts))
          (set! used (+ used (string-length text))))

        (define (emit! text)
          "Append TEXT under the size ceiling: drop it once overflow is set,"
          "or emit the marker and set overflow when TEXT would cross SIZE-LIMI\
T,"
          "otherwise append it via `raw-emit!'."
          (cond
           (overflow #t)
           ((and size-limit (> (+ used (string-length text)) size-limit))
            (set! overflow #t)
            (raw-emit! marker))
           (else (raw-emit! text))))

        (define (atom-text value)
          "Render atomic VALUE through the unbounded writer for identical atom\
"
          "text, pre-capping a long string by source prefix so a huge atom doe\
s"
          "not force the writer to build a huge intermediate before the size"
          "backstop in `emit!' can apply. A borrowed-host binding converts"
          "owned characters in its datum argument to host characters while it"
          "also converts the limits alist, so normalize that adapter value bac\
k"
          "to the owned representation before calling the canonical writer."
          (let* ((value
                 (if (and (char? value) (not (consent-character? value)))
                     (consent-host-character->character value)
                     value))
                 (value
                  (if (and size-limit
                           (string? value)
                           (> (string-length value) (- size-limit used)))
                      (substring value 0 (max 0 (- size-limit used)))
                      value)))
            (consent-datum->external value mode displayp)))

        (define (render value depth)
          "Render VALUE at nesting DEPTH, dispatching compounds to their"
          "bounded renderers and atoms to `atom-text'; a no-op once overflow"
          "is set so the walk unwinds in bounded time."
          (cond
           (overflow #t)
           ((pair? value) (render-pair value depth))
           ((vector? value) (render-vector value depth))
           ((bytevector? value) (render-bytevector value depth))
           (else (emit! (atom-text value)))))

        (define (render-pair value depth)
          "Render pair VALUE at nesting DEPTH, breaking a cycle back to an"
          "ancestor or an over-deep nesting with the marker, and eliding the"
          "spine past LENGTH-LIMIT with a trailing marker."
          (cond
           ((memq value ancestors) (emit! marker))
           ((and depth-limit (>= depth depth-limit)) (emit! marker))
           (else
            (let ((saved ancestors))
              (emit! "(")
              (let loop ((cursor value) (count 0) (first #t))
                (cond
                 (overflow #t)
                 ((not (pair? cursor))
                  (if (not (null? cursor))
                      (begin (emit! " . ") (render cursor (+ depth 1))))
                  (emit! ")"))
                 ((memq cursor ancestors)
                  (emit! " . ") (emit! marker) (emit! ")"))
                 ((and length-limit (>= count length-limit))
                  (emit! " ") (emit! marker) (emit! ")"))
                 (else
                  (if (not first) (emit! " "))
                  (set! ancestors (cons cursor ancestors))
                  (render (car cursor) (+ depth 1))
                  (loop (cdr cursor) (+ count 1) #f))))
              (set! ancestors saved)))))

        (define (render-vector value depth)
          "Render vector VALUE at nesting DEPTH, breaking a self-reference or"
          "an over-deep nesting with the marker, and eliding elements past"
          "LENGTH-LIMIT with a trailing marker."
          (cond
           ((memq value ancestors) (emit! marker))
           ((and depth-limit (>= depth depth-limit)) (emit! marker))
           (else
            (let ((saved ancestors)
                  (size (vector-length value)))
              (set! ancestors (cons value ancestors))
              (emit! "#(")
              (let loop ((index 0) (first #t))
                (cond
                 (overflow #t)
                 ((>= index size) #t)
                 ((and length-limit (>= index length-limit))
                  (if (not first) (emit! " ")) (emit! marker))
                 (else
                  (if (not first) (emit! " "))
                  (render (vector-ref value index) (+ depth 1))
                  (loop (+ index 1) #f))))
              (emit! ")")
              (set! ancestors saved)))))

        (define (render-bytevector value depth)
          "Render bytevector VALUE at nesting DEPTH (over-deep nesting renders\
"
          "as the marker), eliding bytes past LENGTH-LIMIT with a trailing"
          "marker; bytevectors hold no compounds, so no cycle check is needed.\
"
          (cond
           ((and depth-limit (>= depth depth-limit)) (emit! marker))
           (else
            (let ((size (bytevector-length value)))
              (emit! "#u8(")
              (let loop ((index 0) (first #t))
                (cond
                 (overflow #t)
                 ((>= index size) #t)
                 ((and length-limit (>= index length-limit))
                  (if (not first) (emit! " ")) (emit! marker))
                 (else
                  (if (not first) (emit! " "))
                  (emit! (consent-integer->radix-string
                          (bytevector-u8-ref value index) 10))
                  (loop (+ index 1) #f))))
              (emit! ")")))))

        (render datum 0)
        (apply string-append (reverse parts))))))
