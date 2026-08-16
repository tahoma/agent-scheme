;;; Portable R7RS datum reader for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library mirrors the Emacs Lisp reader in portable Scheme. The
;;; `consent-read', `consent-read-all', and incremental syntax APIs build
;;; private host-native syntax while bootstrapping. Scheme-visible reads use
;;; the explicit heap-taking `consent-read-datum' entry points. Metadata,
;;; validation, and writer boundaries accept both representations under the
;;; same resource and rendering rules.

(define-library (consent reader)
  (export consent-read
          consent-read-datum
          consent-read-all
          consent-reader-source?
          consent-make-reader-source
          consent-reader-source-location-probe-count
          consent-read-from-string-at
          consent-read-datum-from-string-at
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
          consent-datum-source-metadata
          consent-source-metadata->record
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
          consent-number-representation-snapshot
          consent-number-representation-snapshot-outer
          consent-outer-representation-kind
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
          (consent datum)
          (consent identity-map)
          (consent numeric)
          (only (consent growable-vector)
                consent-growable-vector-active?
                consent-growable-vector-append!
                consent-growable-vector-release!
                consent-growable-vector-snapshot
                consent-make-growable-vector)
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

    ;; Small builders avoid an initial resize without reserving their full
    ;; configured ceiling up front.
    (define reader-initial-growable-capacity 16)

    (define (make-reader-growable-vector maximum-capacity)
      "Return empty bounded storage for one reader-local builder."
      (consent-make-growable-vector
       (min reader-initial-growable-capacity maximum-capacity)
       maximum-capacity))
    ;; Default maximum total datum node count accepted by reader validation.
    (define consent-default-maximum-total-nodes 1000000)

    ;; Repeated incremental reads share this immutable lexical snapshot. The
    ;; public constructor pays character decoding and line indexing once.
    (define-record-type <consent-reader-source>
      (make-consent-reader-source-record
       text characters line-starts offset-lines)
      consent-reader-source?
      (text prepared-reader-source-text)
      (characters prepared-reader-source-characters)
      (line-starts prepared-reader-source-line-starts)
      (offset-lines prepared-reader-source-offset-lines))

    ;; Reader records own one parse run's immutable source and mutable cursor.
    (define-record-type <reader>
      ;; Reader state is mutable only for cursor position, fold-case mode, and
      ;; node count.  SOURCE remains the immutable snapshot of input text.
      (make-reader source characters position length line-starts offset-lines
                   fold-case
                   symbol-table
                   node-count datum-labels
                   maximum-depth maximum-list-length maximum-vector-length
                   maximum-bytevector-length maximum-string-size
                   maximum-total-nodes maximum-source-metadata source-id
                   source-metadata source-metadata-table source-metadata-sink
                   source-metadata-count construction-make construction-fill
                   construction-fixup recovery pending-stack)
      reader?
      (source reader-source)
      (characters reader-characters)
      (position reader-position set-reader-position!)
      (length reader-length)
      (line-starts reader-line-starts)
      (offset-lines reader-offset-lines)
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
      (source-metadata reader-source-metadata set-reader-source-metadata!)
      ;; Direct owned publication uses the heap sidecar and keeps this false.
      ;; Legacy syntax readers use either a read-scoped or global host table.
      (source-metadata-table reader-source-metadata-table)
      ;; Context-backed readers publish immutable notes into the context's
      ;; indexed overlay instead of retaining private syntax process-wide.
      (source-metadata-sink reader-source-metadata-sink)
      (source-metadata-count reader-source-metadata-count
                             set-reader-source-metadata-count!)
      ;; Heap-taking reader entry points receive one-shot shell, initial-fill,
      ;; and datum-label-fixup capabilities. Legacy syntax readers keep these
      ;; fields false.
      (construction-make reader-construction-make)
      (construction-fill reader-construction-fill)
      (construction-fixup reader-construction-fixup)
      ;; RECOVERY toggles errors-as-data: when set, reader errors raise a
      ;; structured <reader-condition> the recovery driver can resynchronize
      ;; past instead of unwinding the whole read.
      (recovery reader-recovery)
      ;; PENDING-STACK tracks the constructs currently open at the cursor,
      ;; innermost first (`list`, `vector`, `bytevector`, `string`, `symbol`,
      ;; `comment`).  An incomplete condition snapshots it so interactive
      ;; callers can render nesting depth and the pending construct kind.
      (pending-stack reader-pending-stack set-reader-pending-stack!))

    ;; Validation records own the post-read resource budget for mixed datums.
    (define-record-type <validation>
      ;; Validation walks host-created or owned datums after parsing. It has
      ;; its own counter so callers cannot bypass node limits by constructing
      ;; values.
      (make-validation node-count maximum-total-nodes)
      validation?
      (node-count validation-node-count set-validation-node-count!)
      (maximum-total-nodes validation-maximum-total-nodes))

    ;; Datum labels are keyed by decimal spelling. A reader-local digit radix
    ;; trie makes lookup deterministically linear in the label's digit count;
    ;; untrusted spellings cannot force the collision chains possible in an
    ;; open-address hash table.

    (define (make-reader-label-node)
      "Return one empty radix-trie node with ten digit edges."
      (make-vector 11 #f))

    (define (make-reader-label-table)
      "Return an empty reader-local datum-label table."
      (vector 0 (make-reader-label-node)))

    (define (reader-label-digit-edge char)
      "Return CHAR's one-based decimal-trie edge index."
      (+ 1 (- (char->integer char) (char->integer #\0))))

    (define (reader-label-table-ref table id)
      "Return ID's label cell from TABLE, or #f."
      (let ((node (vector-ref table 1)))
        (string-for-each
         (lambda (char)
           (if node
               (set! node
                     (vector-ref node (reader-label-digit-edge char)))))
         id)
        (and node (vector-ref node 0))))

    (define (reader-label-table-set! table id value)
      "Associate ID with VALUE in TABLE and return VALUE."
      (let ((node (vector-ref table 1)))
        (string-for-each
         (lambda (char)
           (let* ((edge (reader-label-digit-edge char))
                  (child (vector-ref node edge)))
             (if (not child)
                 (begin
                   (set! child (make-reader-label-node))
                   (vector-set! node edge child)))
             (set! node child)))
         id)
        (if (not (vector-ref node 0))
            (vector-set! table 0 (+ (vector-ref table 0) 1)))
        (vector-set! node 0 value)
        value))

    ;; The exported EOF sentinel lets incremental readers distinguish end of
    ;; input from any Scheme datum a source string can contain.
    (define-record-type <consent-read-eof>
      (make-consent-read-eof)
      consent-read-eof?)

    ;; Singleton EOF sentinel returned by incremental reader calls at end of
    ;; input.
    (define consent-read-eof (make-consent-read-eof))

    ;; Default cap for the portable source side table. Portable R7RS has no
    ;; weak hash table, so the table remains explicit runtime state. Keep the
    ;; cap option-backed so trusted callers can retry with a higher bound.
    (define consent-default-maximum-source-metadata 10000000)

    ;; Recognize owned and bootstrap symbols while reading mixed datums.
    (define reader-datum-symbol? consent-host-symbol?)
    ;; Read names from owned and bootstrap symbols.
    (define reader-datum-symbol-name consent-host-symbol-name)

    (define (reader-pair? value)
      "Report whether VALUE is a host-native or owned pair."
      (or (pair? value) (consent-datum-pair? value)))

    (define (reader-car value)
      "Return VALUE's car across the host and owned representations."
      (if (pair? value)
          (car value)
          (consent-datum-car-trusted value)))

    (define (reader-cdr value)
      "Return VALUE's cdr across the host and owned representations."
      (if (pair? value)
          (cdr value)
          (consent-datum-cdr-trusted value)))

    (define (reader-string? value)
      "Report whether VALUE is a host-native or owned string."
      (or (string? value) (consent-datum-string? value)))

    (define (reader-string-length value)
      "Return VALUE's string length across both representations."
      (if (consent-datum-string? value)
          (consent-datum-string-length-trusted value)
          (string-length value)))

    (define (reader-string->host value)
      "Return VALUE as host text for the external writer adapter."
      (if (consent-datum-string? value)
          (consent-datum-string->host value)
          value))

    (define (reader-string-prefix->host value length)
      "Return VALUE's first LENGTH characters without projecting an owned tail."
      (if (consent-datum-string? value)
          (let ((output (open-output-string)))
            (do ((index 0 (+ index 1)))
                ((= index length) (get-output-string output))
              (write-char
               (consent-datum-string-ref-host-trusted value index)
               output)))
          (substring value 0 length)))

    (define (reader-vector? value)
      "Report whether VALUE is a host-native or owned vector."
      (or (vector? value) (consent-datum-vector? value)))

    (define (reader-vector-length value)
      "Return VALUE's vector length across both representations."
      (if (consent-datum-vector? value)
          (consent-datum-vector-length-trusted value)
          (vector-length value)))

    (define (reader-vector-ref value index)
      "Return VALUE's vector element at INDEX across both representations."
      (if (consent-datum-vector? value)
          (consent-datum-vector-ref-trusted value index)
          (vector-ref value index)))

    (define (reader-bytevector? value)
      "Report whether VALUE is a host-native or owned bytevector."
      (or (bytevector? value) (consent-datum-bytevector? value)))

    (define (reader-bytevector-length value)
      "Return VALUE's bytevector length across both representations."
      (if (consent-datum-bytevector? value)
          (consent-datum-bytevector-length value)
          (bytevector-length value)))

    (define (reader-bytevector-u8-ref value index)
      "Return VALUE's byte at INDEX across both representations."
      (if (consent-datum-bytevector? value)
          (consent-datum-bytevector-u8-ref value index)
          (bytevector-u8-ref value index)))

    (define (reader-owned-construction? reader)
      "Report whether READER publishes compounds directly into an owned heap."
      (if (reader-construction-make reader) #t #f))

    (define (reader-make-owned-shell reader kind length)
      "Allocate one KIND shell of LENGTH through READER's owned capability."
      (let ((make-shell (reader-construction-make reader)))
        (if (not make-shell)
            (error "owned reader construction is unavailable" kind))
        (make-shell kind length)))

    (define (reader-fill-owned-slot! reader object index value)
      "Fill owned OBJECT's construction slot through READER's capability."
      (let ((fill-slot! (reader-construction-fill reader)))
        (if (not fill-slot!)
            (error "owned reader construction is unavailable" object))
        (fill-slot! object index value)))

    (define (reader-fixup-owned-slot! reader object index value)
      "Replace one owned construction slot during datum-label resolution."
      (let ((fixup-slot! (reader-construction-fixup reader)))
        (if (not fixup-slot!)
            (error "owned reader label fixup is unavailable" object))
        (fixup-slot! object index value)))

    ;; Mixed reader boundaries can contain owned datums and private host
    ;; syntax in one graph. Owned keys use stable heap/object IDs; bootstrap
    ;; host keys use the host identity-map adapter.
    (define (make-reader-identity-map)
      "Return an empty hybrid owned-datum and host-syntax identity map."
      ;; Allocate each backing table only when its first key arrives. Scalar
      ;; writes and all-owned/all-host traversals should not pay for unused
      ;; identity domains.
      (vector #f #f))

    (define (reader-identity-map-ref map key default)
      "Return identity KEY's value in hybrid MAP, or DEFAULT."
      (let ((table
             (vector-ref map (if (consent-datum-object? key) 0 1))))
        (if (not table)
            default
            (if (consent-datum-object? key)
                (consent-datum-object-map-ref table key default)
                (consent-identity-map-ref table key default)))))

    (define (reader-identity-map-set! map key value)
      "Associate identity KEY with VALUE in hybrid MAP and return VALUE."
      (let* ((owned? (consent-datum-object? key))
             (index (if owned? 0 1))
             (table
              (or
               (vector-ref map index)
               (let ((created
                      (if owned?
                          (consent-make-datum-object-map)
                          (consent-make-identity-map
                           'reader-identity-map))))
                 (vector-set! map index created)
                 created))))
        (if owned?
            (consent-datum-object-map-set! table key value)
            (consent-identity-map-set! table key value)))
      value)

    (define (reader-identity-map-clear! map values)
      "Mark every identity in VALUES absent from active-set MAP."
      (let loop ((rest values))
        (if (not (null? rest))
            (begin
              (reader-identity-map-set! map (car rest) #f)
              (loop (cdr rest))))))

    (define (reader-identity-map-release! map)
      "Release MAP's call-scoped owned and host backends when allocated."
      (let ((owned (vector-ref map 0))
            (host (vector-ref map 1)))
        (if owned (consent-datum-object-map-release! owned))
        (if host (consent-identity-map-release! host)))
      map)

    ;; Legacy private host syntax has no field for provenance, so it uses one
    ;; process-global identity map. Owned and canonical record values carry one
    ;; current metadata slot and therefore leave no allocation-history entry in
    ;; this table.
    (define consent-source-metadata #f)

    (define (ensure-consent-source-metadata!)
      "Return the lazily allocated legacy host-syntax provenance table."
      (if (not consent-source-metadata)
          (set! consent-source-metadata
                (consent-make-identity-map 'reader-source-metadata)))
      consent-source-metadata)

    ;; Count unique current entries in the legacy host-syntax compatibility
    ;; table. Replacing one key's metadata does not increase this count.
    (define consent-source-metadata-entry-count 0)

    (define (consent-source-metadata-count)
      "Return the number of legacy host source metadata entries."
      #((parameters)
        (returns (type exact-non-negative-integer)
         (description
          ("The number of unique identities in the process-global"
            "compatibility table.")))
        (effects state-read))
      consent-source-metadata-entry-count)

    ;; Consent-owned numbers preserve lexical exactness, radix, and special
    ;; values without entrusting payload semantics to the host numeric tower.
    (define-record-type <consent-number>
      ;; VALUE is an owned integer, rational pair, binary64 tuple, special tag,
      ;; or pair of canonical real components.
      (make-consent-number-record
       lexeme exactness radix kind value source-metadata)
      consent-number?
      (lexeme consent-number-lexeme)
      (exactness consent-number-exactness)
      (radix consent-number-radix)
      (kind consent-number-kind)
      (value consent-number-value-field)
      (source-metadata consent-number-source-metadata
                       set-consent-number-source-metadata!))

    (define (make-consent-number lexeme exactness radix kind value)
      "Construct a canonical number with no current source metadata."
      (make-consent-number-record lexeme exactness radix kind value #f))

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

;; Decimal digit alphabet used by canonical numeric snapshots.
(define snapshot-decimal-digits "0123456789")

    (define (canonical-number-exactness-character exactness)
      "Return the stable representation character for canonical EXACTNESS."
      (case exactness
        ((exact) #\e)
        ((inexact) #\i)
        (else (error "unknown canonical number exactness" exactness))))

    (define (canonical-infnan-character value)
      "Return the stable representation character for special VALUE."
      (cond
       ((string=? value "-inf.0") #\0)
       ((string=? value "+inf.0") #\1)
       ((string=? value "+nan.0") #\2)
       (else (error "unknown canonical special number" value))))

    (define (snapshot-decimal-digit-count value)
      "Return the number of decimal digits in nonnegative host VALUE."
      (let loop ((remaining value) (count 1))
        (if (< remaining 10)
            count
            (loop (quotient remaining 10) (+ count 1)))))

    (define (snapshot-length-prefixed-size length)
      "Return encoded size of decimal LENGTH, a colon, and its payload."
      (+ (snapshot-decimal-digit-count length) 1 length))

    (define (canonical-number-snapshot-plan datum)
      "Plan DATUM's snapshot without retaining an owned payload reference."
      (if (not (consent-number? datum))
          (error "number snapshot expected a canonical number" datum))
      (let ((exactness
             (canonical-number-exactness-character
              (consent-number-exactness datum)))
            (value (consent-number-value-field datum)))
        (case (consent-number-kind datum)
          ((integer)
           (let ((payload
                  (owned-numeric
                   'integer-representation-snapshot value)))
             (vector (+ 2 (string-length payload))
                     #\I exactness payload)))
          ((rational)
           (let ((numerator
                  (owned-numeric
                   'integer-representation-snapshot (car value)))
                 (denominator
                  (owned-numeric
                   'integer-representation-snapshot (cdr value))))
             (vector
              (+ 2
                 (snapshot-length-prefixed-size
                  (string-length numerator))
                 (snapshot-length-prefixed-size
                  (string-length denominator)))
              #\R exactness numerator denominator)))
          ((decimal)
           (let ((payload
                  (owned-numeric
                   'binary64-representation-snapshot value)))
             (vector (+ 2 (string-length payload))
                     #\D exactness payload)))
          ((infnan)
           (vector 3 #\S exactness
                   (canonical-infnan-character value)))
          ((complex)
           (let ((real
                  (canonical-number-snapshot-plan (car value)))
                 (imaginary
                  (canonical-number-snapshot-plan (cdr value))))
             (vector
              (+ 2
                 (snapshot-length-prefixed-size (vector-ref real 0))
                 (snapshot-length-prefixed-size
                  (vector-ref imaginary 0)))
              #\C exactness real imaginary)))
          (else
           (error "unknown canonical number kind"
                  (consent-number-kind datum))))))

    (define (snapshot-copy-string! target index source)
      "Copy SOURCE into TARGET at INDEX and return the following index."
      (let ((length (string-length source)))
        (let loop ((source-index 0))
          (if (= source-index length)
              (+ index length)
              (begin
                (string-set!
                 target
                 (+ index source-index)
                 (string-ref source source-index))
                (loop (+ source-index 1)))))))

    (define (snapshot-write-length-prefix! target index length)
      "Write decimal LENGTH and a colon at INDEX; return the following index."
      (let ((digits (snapshot-decimal-digit-count length)))
        (string-set! target (+ index digits) #\:)
        (let loop ((offset (- digits 1)) (remaining length))
          (if (< offset 0)
              (+ index digits 1)
              (begin
                (string-set!
                 target
                 (+ index offset)
                 (string-ref snapshot-decimal-digits
                             (modulo remaining 10)))
                (loop (- offset 1) (quotient remaining 10)))))))

    (define (snapshot-write-plan! target index plan)
      "Write payload-free PLAN into TARGET at INDEX; return the next index."
      (let ((kind (vector-ref plan 1)))
        (string-set! target index kind)
        (string-set! target (+ index 1) (vector-ref plan 2))
        (let ((payload-index (+ index 2)))
          (cond
           ((or (char=? kind #\I) (char=? kind #\D))
            (snapshot-copy-string!
             target payload-index (vector-ref plan 3)))
           ((char=? kind #\S)
            (string-set! target payload-index (vector-ref plan 3))
            (+ payload-index 1))
           ((char=? kind #\R)
            (let* ((numerator (vector-ref plan 3))
                   (denominator (vector-ref plan 4))
                   (after-prefix
                    (snapshot-write-length-prefix!
                     target payload-index (string-length numerator)))
                   (after-numerator
                    (snapshot-copy-string!
                     target after-prefix numerator))
                   (after-second-prefix
                    (snapshot-write-length-prefix!
                     target
                     after-numerator
                     (string-length denominator))))
              (snapshot-copy-string!
               target after-second-prefix denominator)))
           ((char=? kind #\C)
            (let* ((real (vector-ref plan 3))
                   (imaginary (vector-ref plan 4))
                   (after-prefix
                    (snapshot-write-length-prefix!
                     target payload-index (vector-ref real 0)))
                   (after-real
                    (snapshot-write-plan! target after-prefix real))
                   (after-second-prefix
                    (snapshot-write-length-prefix!
                     target after-real (vector-ref imaginary 0))))
              (snapshot-write-plan!
               target after-second-prefix imaginary)))
           (else (error "unknown canonical number snapshot plan" plan))))))

    (define (consent-number-representation-snapshot-outer datum)
      "Return #f unless an interpreter overlay recognizes outer DATUM."
      #((parameters
         (datum (type object)
          (description "Possible outer-owner canonical number to inspect.")))
        (returns (type (or string false))
         (description
          "Fresh O-prefixed internal numeric ASCII, or #f when unrecognized."))
        (effects allocation error))
      #f)

    (define (consent-outer-representation-kind datum markers)
      "Classify DATUM by returning one caller-supplied identity marker."
      "MARKERS supplies seven outer kinds, private/raw, and direct markers."
      #((parameters
         (datum (type any)
          (description "Possible outer-owner datum to classify."))
         (markers (type vector)
          (description "Nine private identity markers in documented order.")))
        (returns (type any)
         (description "An outer-kind, private/raw, or direct-host marker."))
        (effects pure error))
      (vector-ref markers 8))

    (define (consent-number-representation-snapshot datum)
      "Return fresh collision-free ASCII for canonical DATUM, or #f."
      "Owner, kind, and exactness precede length-delimited payload snapshots."
      #((parameters
         (datum (type object)
          (description "Possible canonical number to inspect and copy.")))
        (returns (type (or string false))
         (description
          "Fresh nonretaining ASCII for a canonical number; otherwise #f."))
        (effects error allocation))
      (if (not (consent-number? datum))
          (consent-number-representation-snapshot-outer datum)
          (let* ((plan (canonical-number-snapshot-plan datum))
                 (payload-length (vector-ref plan 0))
                 (length (+ payload-length 1))
                 (result (make-string length #\0))
                 (end
                  (begin
                    (string-set! result 0 #\L)
                    (snapshot-write-plan! result 1 plan))))
            (if (not (= end length))
                (error "canonical number snapshot length mismatch"
                       end length))
            result)))

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
      (make-consent-record-type-record name fields source-metadata)
      consent-record-type?
      (name consent-record-type-name)
      (fields consent-record-type-fields)
      (source-metadata consent-record-type-source-metadata
                       set-consent-record-type-source-metadata!))

    (define (consent-make-record-type name fields)
      "Construct a portable record type with no current source metadata."
      #((parameters
         (name (type symbol) (description "Record type name."))
         (fields (type list) (description "Ordered field names.")))
        (returns (type record-type)
         (description "A fresh portable record type."))
        (effects allocation))
      (make-consent-record-type-record name fields #f))

    ;; Portable record instances pair Consent Scheme record metadata with field
    ;; storage that the evaluator owns and may mutate through generated
    ;; setters.
    (define-record-type <consent-record>
      (make-consent-record-record type fields source-metadata)
      consent-record?
      (type consent-record-type)
      (fields consent-record-fields)
      (source-metadata consent-record-source-metadata
                       set-consent-record-source-metadata!))

    (define (consent-make-record type fields)
      "Construct a portable record with no current source metadata."
      #((parameters
         (type (type record-type) (description "Record type descriptor."))
         (fields (type vector) (description "Owned field storage.")))
        (returns (type record)
         (description "A fresh portable record instance."))
        (effects allocation))
      (make-consent-record-record type fields #f))

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

    (define (source-location-index characters)
      "Return line starts and one zero-based line index per source offset."
      "The offset vector includes the end position. A final newline retains"
      "the historical end-column convention because no datum starts after it."
      (let* ((length (vector-length characters))
             (offset-lines (make-vector (+ length 1) 0))
             (starts (make-reader-growable-vector (+ length 1))))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (consent-growable-vector-append! starts 0)
           (let loop ((offset 0) (line 0))
             (vector-set! offset-lines offset line)
             (if (= offset length)
                 (vector
                  (consent-growable-vector-snapshot starts)
                  offset-lines)
                 (let ((next (+ offset 1)))
                   (if (and
                        (char=?
                         (vector-ref characters offset) #\newline)
                        (< next length))
                       (begin
                         (consent-growable-vector-append! starts next)
                         (loop next (+ line 1)))
                       (loop next line))))))
         (lambda ()
           (if (consent-growable-vector-active? starts)
               (consent-growable-vector-release! starts))))))

    (define (source-location-line-column line-starts offset-lines offset)
      "Return one-based (LINE . COLUMN) through the direct offset index."
      (let* ((line (vector-ref offset-lines offset))
             (line-start (vector-ref line-starts line)))
        (cons (+ line 1) (+ (- offset line-start) 1))))

    (define (consent-make-reader-source source)
      "Return one immutable lexical snapshot of string SOURCE for reuse."
      #((parameters
         (source (type string)
          (description "Source text to decode and index once.")))
        (returns (type reader-source)
         (description
          ("Prepared input accepted by complete and incremental reader"
            "entry points.")))
        (effects allocation error))
      (if (not (string? source))
          (error "consent-make-reader-source expected a string" source))
      (let* ((characters-list (string->list source))
             (text (list->string characters-list))
             (characters (list->vector characters-list))
             (locations (source-location-index characters)))
        (make-consent-reader-source-record
         text
         characters
         (vector-ref locations 0)
         (vector-ref locations 1))))

    (define (consent-reader-source-location-probe-count source offset)
      "Return the fixed offset-index probe count for SOURCE at OFFSET."
      #((parameters
         (source (type reader-source)
          (description "Prepared source whose location index is probed."))
         (offset (type exact-non-negative-integer)
          (description "Offset from zero through the source length.")))
        (returns (type exact-positive-integer)
         (description "One after exercising the actual location index."))
        (effects allocation error))
      (set! offset (canonical-component offset))
      (if (not (consent-reader-source? source))
          (error
           "consent-reader-source-location-probe-count: expected reader source"
           source))
      (let ((length
             (vector-length (prepared-reader-source-characters source))))
        (if (or (not (integer? offset)) (< offset 0) (> offset length))
            (error
             "consent-reader-source-location-probe-count: invalid offset"
             offset))
        ;; Exercise the same real lookup as source-note; this diagnostic must
        ;; not merely report the documented constant without probing the index.
        (source-location-line-column
         (prepared-reader-source-line-starts source)
         (prepared-reader-source-offset-lines source)
         offset)
        1))

    (define (reader-from-source source options . maybe-construction)
      "Create a reader over SOURCE with optional owned construction callbacks."
      (if (not (or (string? source) (consent-reader-source? source)))
          (error "consent reader source must be a string or snapshot" source)
          (let* ((prepared
                  (and (consent-reader-source? source) source))
                 (source-text
                  (if prepared
                      (prepared-reader-source-text prepared)
                      source))
                 (source-metadata
                  (option-ref options 'source-metadata #t))
                 (source-metadata-sink
                  (option-ref options 'source-metadata-sink #f))
                 (construction
                  (if (null? maybe-construction)
                      #f
                      (car maybe-construction)))
                 (owned? (if construction #t #f))
                 (construction-make
                  (and construction (vector-ref construction 0)))
                 (construction-fill
                  (and construction (vector-ref construction 1)))
                 (construction-fixup
                  (and construction (vector-ref construction 2)))
                 ;; Direct owned reads attach provenance to a heap sidecar.
                 ;; Context sinks and identity tables remain legacy syntax
                 ;; machinery and must not observe unpublished owned shells.
                 (active-source-metadata-sink
                  (and (not owned?) source-metadata-sink))
                 (characters
                  (if prepared
                      (prepared-reader-source-characters prepared)
                      (list->vector (string->list source-text))))
                 (locations
                  (and (or source-metadata
                           (option-ref options 'recovery #f))
                       (if prepared
                           (vector
                            (prepared-reader-source-line-starts prepared)
                            (prepared-reader-source-offset-lines prepared))
                           (source-location-index characters)))))
            ;; Keep cursor access independent of the host's string indexing
            ;; representation.  Some R7RS systems use variable-width UTF-8
            ;; strings, turning repeated indexed access into a large-source
            ;; performance cliff.
            (make-reader source-text
                         characters
                         0
                         (vector-length characters)
                         (and locations (vector-ref locations 0))
                         (and locations (vector-ref locations 1))
                         #f
                         (option-ref options
                                     'symbol-table
                                     consent-default-symbol-table)
                         0
                         (make-reader-label-table)
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
                         (and source-metadata
                              (not owned?)
                              (if active-source-metadata-sink
                                  (consent-make-identity-map
                                   'reader-local-source-metadata)
                                  (ensure-consent-source-metadata!)))
                         active-source-metadata-sink
                         0
                         construction-make
                         construction-fill
                         construction-fixup
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

    (define (reader-line-column reader offset)
      "Return one-based (LINE . COLUMN) in READER at OFFSET."
      (source-location-line-column
       (reader-line-starts reader) (reader-offset-lines reader) offset))

    ;; Compact source notes cross only the private reader/runtime boundary. No
    ;; field mutators or accessors are exported, so callers can retain and move
    ;; one immutable note without exposing its backing representation.
    (define-record-type <source-note>
      (make-source-note-record source-id line column offset span)
      source-note?
      (source-id source-note-source-id)
      (line source-note-line)
      (column source-note-column)
      (offset source-note-offset)
      (span source-note-span))

    (define (source-note reader start end)
      "Return compact source metadata for READER between START and END."
      (let ((line-column (reader-line-column reader start)))
        (make-source-note-record
         (reader-source-id reader)
         (car line-column)
         (cdr line-column)
         start
         (max 0 (- end start)))))

    (define (consent-source-metadata->record metadata)
      "Return Scheme-readable source metadata for METADATA."
      "Compact reader notes remain opaque runtime data until this observable"
      "boundary materializes their public source record."
      #((parameters
         (metadata
          . ("Opaque compact source metadata or an already materialized"
             "metadata value.")))
        (returns (type source-metadata)
         (description "Scheme-readable source metadata."))
        (effects allocation))
      (if (source-note? metadata)
          (list 'source
                (source-field 'origin 'source)
                (source-field 'source-id
                              (source-note-source-id metadata))
                (source-field 'line
                              (consent-make-canonical-integer
                               (source-note-line metadata)))
                (source-field 'column
                              (consent-make-canonical-integer
                               (source-note-column metadata)))
                (source-field 'offset
                              (consent-make-canonical-integer
                               (source-note-offset metadata)))
                (source-field 'span
                              (consent-make-canonical-integer
                               (source-note-span metadata)))
                (source-field 'phase 'read))
          metadata))

    (define (source-attachable? datum)
      "Report whether DATUM has stable identity for source metadata."
      (or (reader-pair? datum)
          (reader-vector? datum)
          (reader-string? datum)
          (reader-bytevector? datum)
          (consent-number? datum)
          ;; Owned symbols are represented by records, but retain symbol
          ;; semantics here: identifiers are atomic datums and must not consume
          ;; one retained source-metadata entry per occurrence.
          (and (consent-record? datum)
               (not (consent-symbol? datum)))
          (consent-record-type? datum)))

    ;; A private sentinel distinguishes a missing identity-map entry from any
    ;; valid truthy metadata value.
    (define source-metadata-absent (vector 'source-metadata-absent))

    (define (direct-source-metadata-owner? datum)
      "Report whether DATUM owns one current source metadata slot."
      (or (consent-datum-object? datum)
          (consent-number? datum)
          (consent-record? datum)
          (consent-record-type? datum)))

    (define (direct-source-metadata datum)
      "Return DATUM's current directly owned source metadata."
      (cond
       ((consent-datum-object? datum)
        (consent-datum-object-source-metadata datum))
       ((consent-number? datum) (consent-number-source-metadata datum))
       ((consent-record? datum) (consent-record-source-metadata datum))
       ((consent-record-type? datum)
        (consent-record-type-source-metadata datum))
       (else #f)))

    (define (direct-source-metadata-set! datum metadata)
      "Replace DATUM's current directly owned source METADATA."
      (cond
       ((consent-datum-object? datum)
        (consent-datum-object-source-metadata-set! datum metadata))
       ((consent-number? datum)
        (set-consent-number-source-metadata! datum metadata))
       ((consent-record? datum)
        (set-consent-record-source-metadata! datum metadata))
       ((consent-record-type? datum)
        (set-consent-record-type-source-metadata! datum metadata))
       (else
        (error "datum has no directly owned source metadata slot" datum))))

    (define (datum-source-metadata-entry-in table datum)
      "Return DATUM's raw metadata or the private absence sentinel."
      (if (direct-source-metadata-owner? datum)
          (or (direct-source-metadata datum) source-metadata-absent)
          (if table
              (consent-identity-map-ref
               table datum source-metadata-absent)
              source-metadata-absent)))

    (define (datum-source-metadata-in table datum)
      "Return DATUM's current raw source metadata from its owner or TABLE."
      (let ((metadata (datum-source-metadata-entry-in table datum)))
        (if (eq? metadata source-metadata-absent) #f metadata)))

    (define (datum-source-metadata-set-in! table datum metadata)
      "Replace DATUM's current source METADATA in its owner or TABLE."
      (if (direct-source-metadata-owner? datum)
          (direct-source-metadata-set! datum metadata)
          (if table
              (consent-identity-map-set! table datum metadata)
              (error "source metadata table required" datum))))

    (define (consent-datum-source-metadata datum)
      "Return raw source metadata attached to DATUM, or #f when absent."
      "This internal runtime boundary does not materialize compact reader"
      "notes; callers must treat the result as opaque and immutable."
      #((parameters
         (datum . "Datum whose opaque current source metadata is requested."))
        (returns (type (or source-metadata boolean))
         (description "Opaque current source metadata, or #f."))
        (effects state-read))
      (datum-source-metadata-in consent-source-metadata datum))

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
           ("Optional maximum source metadata attachments allowed"
             "before this attachment fails closed."))))
        (returns
         . ("DATUM, after attaching SOURCE when DATUM is"
            "identity-attachable, or an error when the metadata table"
            "would exceed its resource limit."))
        (effects state-read state-write error))
      (if (and source (source-attachable? datum))
          (let* ((limit
                  (if (null? maybe-limit)
                      consent-default-maximum-source-metadata
                      (car maybe-limit)))
                 (direct? (direct-source-metadata-owner? datum))
                 (table
                  (if direct?
                      #f
                      (ensure-consent-source-metadata!)))
                 (old
                  (datum-source-metadata-entry-in
                   table datum))
                 (new? (eq? old source-metadata-absent)))
            (if (and new?
                     (if direct?
                         (<= limit 0)
                         (>= consent-source-metadata-entry-count limit)))
                (error
                 "consent datum limit error: source metadata count exceeds \
maximum source metadata"
                 (if direct? 0 consent-source-metadata-entry-count)
                 limit))
            (datum-source-metadata-set-in!
             table datum source)
            (if (and new? (not direct?))
                (set! consent-source-metadata-entry-count
                      (+ consent-source-metadata-entry-count 1)))))
      datum)

    (define (reader-datum-source-set-fresh! reader datum source)
      "Attach SOURCE to a freshly parsed DATUM without an existence lookup."
      "The ordinary token, list, vector, string, and abbreviation parsers each"
      "publish a new identity exactly once. Datum-label syntax uses the checked"
      "replacement path below because its outer occurrence can reuse an"
      "identity already annotated by the labelled subdatum."
      (if (and source (source-attachable? datum))
          (let* ((count (reader-source-metadata-count reader))
                 (limit (reader-maximum-source-metadata reader))
                 (table (reader-source-metadata-table reader))
                 (sink (reader-source-metadata-sink reader))
                 (direct? (direct-source-metadata-owner? datum))
                 (global? (and (not direct?)
                               consent-source-metadata
                               (eq? table consent-source-metadata))))
            (if (and (reader-owned-construction? reader) (not direct?))
                (error
                 "owned reader produced a host compound provenance owner"
                 datum))
            (if (>= count limit)
                (error
                 "consent datum limit error: source metadata count exceeds \
maximum source metadata"
                 count
                 limit))
            (if (and global?
                     (>= consent-source-metadata-entry-count
                         consent-default-maximum-source-metadata))
                (error
                 "consent datum limit error: global source metadata count \
exceeds maximum source metadata"
                 consent-source-metadata-entry-count
                 consent-default-maximum-source-metadata))
            (datum-source-metadata-set-in! table datum source)
            (if sink (sink datum source))
            (set-reader-source-metadata-count! reader (+ count 1))
            (if global?
                (set! consent-source-metadata-entry-count
                      (+ consent-source-metadata-entry-count 1)))))
      datum)

    (define (reader-datum-source-set! reader datum source)
      "Attach or replace SOURCE in DATUM's reader-local metadata owner."
      (if (and source (source-attachable? datum))
          (let* ((count (reader-source-metadata-count reader))
                 (limit (reader-maximum-source-metadata reader))
                 (table (reader-source-metadata-table reader))
                 (sink (reader-source-metadata-sink reader))
                 (direct? (direct-source-metadata-owner? datum))
                 (old (datum-source-metadata-entry-in table datum))
                 (new? (eq? old source-metadata-absent))
                 (global? (and (not direct?)
                               consent-source-metadata
                               (eq? table consent-source-metadata))))
            (if (and (reader-owned-construction? reader) (not direct?))
                (error
                 "owned reader produced a host compound provenance owner"
                 datum))
            (if (and new? (>= count limit))
                (error
                 "consent datum limit error: source metadata count exceeds \
maximum source metadata"
                 count
                 limit))
            (if (and new?
                     global?
                     (>= consent-source-metadata-entry-count
                         consent-default-maximum-source-metadata))
                (error
                 "consent datum limit error: global source metadata count \
exceeds maximum source metadata"
                 consent-source-metadata-entry-count
                 consent-default-maximum-source-metadata))
            (datum-source-metadata-set-in! table datum source)
            (if sink (sink datum source))
            (if new?
                (set-reader-source-metadata-count! reader (+ count 1)))
            (if (and new? global?)
                (set! consent-source-metadata-entry-count
                      (+ consent-source-metadata-entry-count 1)))))
      datum)

    (define (consent-datum-source datum)
      "Return source metadata attached to DATUM, or #f when absent."
      #((parameters
         (datum . "Datum to look up source metadata for."))
        (returns (type (or source-metadata boolean))
         (description
          ("A source-metadata record built from DATUM's attached"
            "metadata, or #f when none is attached.")))
        (effects allocation state-read))
      (let ((metadata (consent-datum-source-metadata datum)))
        (if metadata (consent-source-metadata->record metadata) #f)))

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
      (let ((metadata (consent-datum-source-metadata source))
            (overwrite? (and (not (null? maybe-overwrite))
                             (car maybe-overwrite))))
        (if (and metadata
                 (or overwrite?
                     (not (consent-datum-source-metadata target))))
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
      ;; COMMENT-DEPTH is the explicit continuation for nested `#;' prefixes.
      ;; It both removes host-stack dependence and charges the nesting against
      ;; the ordinary datum-depth budget before any ignored datum is read.
      (let loop ((comment-depth depth))
        (cond
         ((whitespace? (peek reader))
          (advance! reader)
          (loop comment-depth))
         ((and (peek reader) (char=? (peek reader) #\;))
          (skip-line-comment! reader)
          (loop comment-depth))
         ((starts-with? reader "#|")
          (skip-nested-comment! reader)
          (loop comment-depth))
         ((starts-with? reader "#!")
          (skip-directive! reader)
          (loop comment-depth))
         ((starts-with? reader "#;")
          (advance! reader 2)
          (check-depth reader (+ comment-depth 1))
          (loop (+ comment-depth 1)))
         ((> comment-depth depth)
          ;; Ignored syntax must not escape through a provenance sink or the
          ;; legacy process table. The reader is abandoned if parsing raises,
          ;; so restoration is only needed after a successful ignored datum.
          (let ((source-metadata? (reader-source-metadata reader)))
            (if source-metadata?
                (set-reader-source-metadata! reader #f))
            (read-datum reader comment-depth)
            (if source-metadata?
                (set-reader-source-metadata! reader source-metadata?))
            (loop (- comment-depth 1))))
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
                  (owned-numeric
                   'binary64->string
                   (owned-numeric 'binary64-import-host number))))
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
            (if (reader-owned-construction? reader)
                (let ((string
                       (reader-make-owned-shell reader 'string size)))
                  ;; RESULT is reverse source order. Fill from the final slot
                  ;; backward without allocating a second character list or a
                  ;; host string that could become an identity-map key.
                  (let fill ((rest result) (index (- size 1)))
                    (if (null? rest)
                        string
                        (begin
                          (reader-fill-owned-slot!
                           reader string index (car rest))
                          (fill (cdr rest) (- index 1))))))
                (list->string (reverse result))))
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
            (tail #f)
            (count 0))
        (define (append! datum)
          (set! count (+ count 1))
          (if (> count (reader-maximum-list-length reader))
              (limit-error reader
                           "list length exceeds maximum list length"
                           (reader-maximum-list-length reader)))
          (let ((cell
                 (if (reader-owned-construction? reader)
                     (let ((shell
                            (reader-make-owned-shell reader 'pair 2)))
                       (reader-fill-owned-slot! reader shell 0 datum)
                       shell)
                     (cons datum '()))))
            (if (not tail)
                (begin
                  (set! head cell)
                  (set! tail cell))
                (begin
                  (if (reader-owned-construction? reader)
                      (reader-fill-owned-slot! reader tail 1 cell)
                      (set-cdr! tail cell))
                  (set! tail cell)))))
        (let loop ()
          (skip-intertoken-space! reader depth)
          (cond
           ((eof? reader)
            (reader-incomplete reader "unterminated list"))
           ((char=? (peek reader) #\))
            (advance! reader)
            (pop-pending! reader)
            (if (and tail (reader-owned-construction? reader))
                (reader-fill-owned-slot! reader tail 1 '()))
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
                    (if (not tail)
                        (reader-error reader "dot before list element"))
                    (skip-intertoken-space! reader depth)
                    (let ((datum (read-datum reader (+ depth 1))))
                      (if (reader-owned-construction? reader)
                          (reader-fill-owned-slot! reader tail 1 datum)
                          (set-cdr! tail datum)))
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
      (let ((items (make-reader-growable-vector maximum-length)))
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (let loop ((count 0))
             (skip-intertoken-space! reader depth)
             (cond
              ((eof? reader)
               (reader-incomplete reader "unterminated sequence" kind))
              ((char=? (peek reader) close-char)
               (advance! reader)
               (pop-pending! reader)
               (consent-growable-vector-snapshot items))
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
                 (consent-growable-vector-append! items datum)
                 (loop next-count))))))
         (lambda ()
           (if (consent-growable-vector-active? items)
               (consent-growable-vector-release! items))))))

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

    (define (read-vector reader depth)
      "Read an R7RS vector literal."
      (advance! reader 2)
      (let* ((items
              (read-vector-elements
               reader
               depth
               "vector"
               #\)
               (reader-maximum-vector-length reader)))
             (count (vector-length items)))
        (note-node! reader)
        (if (reader-owned-construction? reader)
            (let ((vector
                   (reader-make-owned-shell reader 'vector count)))
              (let fill ((index 0))
                (if (= index count)
                    vector
                    (begin
                      (reader-fill-owned-slot!
                       reader vector index (vector-ref items index))
                      (fill (+ index 1))))))
            items)))

    (define (read-bytevector-literal reader depth)
      "Read an R7RS bytevector literal and validate byte elements."
      (advance! reader 4)
      (let* ((items
              (read-vector-elements
               reader
               depth
               "bytevector"
               #\)
               (reader-maximum-bytevector-length reader)))
             (count (vector-length items))
             (bytevector
              (if (reader-owned-construction? reader)
                  (reader-make-owned-shell reader 'bytevector count)
                  (make-bytevector count))))
        (let loop ((index 0))
          (if (= index count)
              (begin
                (note-node! reader)
                bytevector)
              (let ((datum (vector-ref items index)))
                (if (exact-byte? datum)
                    (let ((byte (exact-integer-value datum)))
                      (if (reader-owned-construction? reader)
                          (reader-fill-owned-slot!
                           reader bytevector index byte)
                          (bytevector-u8-set! bytevector index byte))
                      (loop (+ index 1)))
                    (reader-error
                     reader
                     "bytevector element is not an exact byte"
                     (consent-datum->external datum))))))))

    (define (quote-datum reader name datum)
      "Build the canonical abbreviated quote form for NAME and DATUM."
      (let ((symbol (reader-intern-symbol reader name)))
        (if (reader-owned-construction? reader)
            (let ((head (reader-make-owned-shell reader 'pair 2))
                  (tail (reader-make-owned-shell reader 'pair 2)))
              (reader-fill-owned-slot! reader head 0 symbol)
              (reader-fill-owned-slot! reader head 1 tail)
              (reader-fill-owned-slot! reader tail 0 datum)
              (reader-fill-owned-slot! reader tail 1 '())
              head)
            (list symbol datum))))

    (define (reader-label-cell reader id)
      "Find an existing datum-label cell for ID in the reader state."
      (reader-label-table-ref (reader-datum-labels reader) id))

    (define (read-datum-label-token! reader)
      "Consume one label token and return its ID and marker."
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
        (let ((id (reader-substring reader
                                    start
                                    (reader-position reader)))
              (marker (peek reader)))
          (if (not (and marker
                        (or (char=? marker #\=)
                            (char=? marker #\#))))
              (reader-error reader "datum label must end with = or #"))
          (advance! reader)
          (cons id marker))))

    (define (reader-label-reference reader token)
      "Return the label placeholder referenced by TOKEN."
      (let ((cell (reader-label-cell reader (car token))))
        (if (not cell)
            (reader-error reader "undefined datum label" (car token)))
        (cdr cell)))

    (define (reader-fill-datum-labels! reader labels datum)
      "Resolve pending definition LABELS to DATUM and return DATUM."
      (let loop ((rest labels))
        (if (null? rest)
            datum
            (let ((label (car rest)))
              (if (eq? datum label)
                  (reader-error
                   reader
                   "datum label cannot reference itself directly"
                   (datum-label-id label)))
              (set-datum-label-value! label datum)
              (set-datum-label-filled! label #t)
              (loop (cdr rest))))))

    (define (read-datum-label reader depth)
      "Read and resolve shared datum label definitions and references."
      (let ((first (read-datum-label-token! reader)))
        (if (char=? (cdr first) #\#)
            (reader-label-reference reader first)
            ;; Consecutive definitions are same-depth syntax. Keep their
            ;; continuations explicitly so a long alias chain neither grows
            ;; the host stack nor postpones its total-node budget charge.
            (let loop ((token first) (pending '()) (first? #t))
              (let ((id (car token)))
                (if (reader-label-cell reader id)
                    (reader-error reader "duplicate datum label" id))
                (let ((label (make-datum-label id #f #f)))
                  (reader-label-table-set!
                   (reader-datum-labels reader) id (cons id label))
                  (if (not first?) (note-node! reader))
                  (let ((next-pending (cons label pending)))
                    (skip-intertoken-space! reader depth)
                    (if (let ((char (peek reader 1)))
                          (and (peek reader)
                               (char=? (peek reader) #\#)
                               char
                               (char>=? char #\0)
                               (char<=? char #\9)))
                        (let ((next (read-datum-label-token! reader)))
                          (if (char=? (cdr next) #\=)
                              (loop next next-pending #f)
                              (begin
                                (note-node! reader)
                                (reader-fill-datum-labels!
                                 reader
                                 next-pending
                                 (reader-label-reference reader next)))))
                        (reader-fill-datum-labels!
                         reader
                         next-pending
                         (read-datum reader depth))))))))))

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
      (let ((label-count (vector-ref (reader-datum-labels reader) 0)))
        ;; Without labels the parser graph is already final and remains a
        ;; scalar/allocation-free fast path. Labelled owned syntax uses the
        ;; object's intrusive map header; legacy private host syntax retains
        ;; the correctness-only host identity adapter.
        (if (= label-count 0)
            datum
            (let ((root (vector datum))
                  (seen (make-reader-identity-map)))
                (define (resolved-target value)
                  "Resolve one label chain with bounded path compression."
                  (let ((cursor value) (steps 0) (path '()))
                    (do ()
                        ((not (datum-label? cursor))
                         (do ((rest path (cdr rest)))
                             ((null? rest))
                           (set-datum-label-value! (car rest) cursor))
                         cursor)
                      (if (not (datum-label-filled? cursor))
                          (reader-error reader
                                        "undefined datum label"
                                        (datum-label-id cursor)))
                      ;; A chain can visit each reader-local label once.
                      ;; Reaching another label after that proves a pure
                      ;; placeholder cycle such as #0=#0#, which has no
                      ;; compound shell capable of closing the graph.
                      (if (>= steps label-count)
                          (reader-error reader
                                        "cyclic datum label alias"
                                        (datum-label-id cursor)))
                      (let ((next (datum-label-value cursor)))
                        (set! path (cons cursor path))
                        (set! steps (+ steps 1))
                        (set! cursor next)))))

                (define (store! parent slot source value)
                  "Replace label SOURCE in PARENT's SLOT with VALUE."
                  ;; Non-placeholder edges already hold VALUE and must not
                  ;; consume their shell's one permitted fixup.
                  (if (not (eq? source value))
                      (cond
                       ((not parent) (vector-set! root 0 value))
                       ((consent-datum-pair? parent)
                        (reader-fixup-owned-slot!
                         reader parent (if (eq? slot 'car) 0 1) value))
                       ((pair? parent)
                        (if (eq? slot 'car)
                            (set-car! parent value)
                            (set-cdr! parent value)))
                       ((consent-datum-vector? parent)
                        (reader-fixup-owned-slot!
                         reader parent slot value))
                       (else (vector-set! parent slot value)))))

                ;; Each action is #(source parent slot). Register a compound
                ;; before scheduling its edges so cycles and shared targets
                ;; never re-enter the traversal.
                (dynamic-wind
                 (lambda () #t)
                 (lambda ()
                   (let walk ((work (list (vector datum #f 0))))
                     (if (null? work)
                         (vector-ref root 0)
                         (let* ((action (car work))
                                (source (vector-ref action 0))
                                (value (resolved-target source))
                                (parent (vector-ref action 1))
                                (slot (vector-ref action 2))
                                (rest (cdr work)))
                           (store! parent slot source value)
                           (cond
                            ((reader-pair? value)
                             (if (reader-identity-map-ref seen value #f)
                                 (walk rest)
                                 (begin
                                   (reader-identity-map-set! seen value #t)
                                   (walk
                                    (cons
                                     (vector
                                      (reader-car value) value 'car)
                                     (cons
                                      (vector
                                       (reader-cdr value) value 'cdr)
                                      rest))))))
                            ((reader-vector? value)
                             (if (reader-identity-map-ref seen value #f)
                                 (walk rest)
                                 (begin
                                   (reader-identity-map-set! seen value #t)
                                   ;; Schedule the highest slot first. Besides
                                   ;; being semantically neutral, this
                                   ;; exercises complete backward label-alias
                                   ;; chains before earlier slots compress.
                                   (let push
                                       ((index 0)
                                        (next rest))
                                     (if (= index
                                            (reader-vector-length value))
                                         (walk next)
                                         (push
                                          (+ index 1)
                                          (cons
                                           (vector
                                            (reader-vector-ref value index)
                                            value
                                            index)
                                           next)))))))
                            (else (walk rest)))))))
                 (lambda ()
                   (reader-identity-map-release! seen)))))))


    (define (read-datum reader depth)
      "Read one datum at DEPTH from the current reader cursor."
      (check-depth reader depth)
      (skip-intertoken-space! reader depth)
      (if (eof? reader)
          (reader-incomplete reader "unexpected end of input"))
      (let* ((start (reader-position reader))
             (char (peek reader))
             (datum-label-syntax?
              (and
               (char=? char #\#)
               (let ((next (peek reader 1)))
                 (and next
                      (char>=? next #\0)
                      (char<=? next #\9))))))
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
          (if (and (reader-source-metadata reader)
                   (source-attachable? datum))
              ((if datum-label-syntax?
                   reader-datum-source-set!
                   reader-datum-source-set-fresh!)
               reader
               datum
               (source-note reader start (reader-position reader)))
              datum))))

    (define (options-from-rest maybe-options)
      "Normalize optional argument lists to an options association list."
      (if (null? maybe-options) '() (car maybe-options)))

    (define (reader-parse-one-with-state
             source options . maybe-construction)
      "Parse one complete datum and return it with its reader state."
      (let ((reader
             (if (null? maybe-construction)
                 (reader-from-source source options)
                 (reader-from-source
                  source options (car maybe-construction)))))
        (set-reader-datum-labels! reader (make-reader-label-table))
        (let ((datum (resolve-datum-labels (read-datum reader 0)
                                           reader)))
          (skip-intertoken-space! reader 0)
          (if (not (eof? reader))
              (reader-error reader "unexpected trailing input"))
          (values datum reader))))

    (define (reader-parse-one source options . maybe-construction)
      "Parse one complete datum with optional owned construction callbacks."
      (call-with-values
       (lambda ()
         (if (null? maybe-construction)
             (reader-parse-one-with-state source options)
             (reader-parse-one-with-state
              source options (car maybe-construction))))
       (lambda (datum reader) datum)))

    (define (reader-private-host-tree? reader)
      "Report whether READER produced an unlabelled private host tree."
      "Owned construction, recovery, active metadata sinks, and datum-label"
      "syntax retain the general graph validator even for an acyclic result."
      (and (not (reader-owned-construction? reader))
           (not (reader-recovery reader))
           (not (and (reader-source-metadata reader)
                     (reader-source-metadata-sink reader)))
           (= (vector-ref (reader-datum-labels reader) 0) 0)))

    (define (reader-validate-parsed-datum datum reader options)
      "Validate DATUM through READER's proven representation boundary."
      (if (reader-private-host-tree? reader)
          (validate-parser-host-tree datum options)
          (consent-validate-datum datum options))
      datum)

    (define (reader-read-one source options)
      "Read one validated private host-syntax datum."
      (call-with-values
       (lambda () (reader-parse-one-with-state source options))
       (lambda (datum reader)
         (reader-validate-parsed-datum datum reader options))))

    (define (consent-read source . maybe-options)
      "Read one private syntax datum from SOURCE and require complete input."
      "Compound results use host-native bootstrap syntax; Scheme-visible"
      "values must enter through `consent-read-datum'."
      #((parameters
         (source (type (or string port))
          (description
           ("Source string or port body to read a single datum from.")))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying budget overrides."))))
        (returns
         . ("The single private syntax datum read from SOURCE after"
            "confirming no trailing input remains."))
        (effects error))
      (reader-read-one
       source
       (options-from-rest maybe-options)))

    (define (consent-read-datum heap source . maybe-options)
      "Read one datum from SOURCE into the explicit owned HEAP."
      "Compound syntax is allocated directly in HEAP. Datum-label fixups run"
      "inside the private construction scope; validation follows publication."
      #((parameters
         (heap (type datum-heap)
          (description "Heap that owns the returned compound graph."))
         (source (type (or string reader-source))
          (description "Source string or reusable prepared snapshot."))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying budget overrides."))))
        (returns
         . ("The parsed value with every compound allocated in HEAP;"
            "sharing and cycles are preserved."))
        (effects allocation state-read state-write error))
      (if (not (consent-datum-heap? heap))
          (error "consent-read-datum expected a datum heap" heap))
      (let* ((options (options-from-rest maybe-options))
             (datum
              (consent-call-with-datum-construction
               heap
               (lambda (make-shell fill-slot! fixup-slot!)
                 (reader-parse-one
                  source
                  options
                  (vector make-shell fill-slot! fixup-slot!))))))
        ;; Construction closes before validation, so bytevectors and every
        ;; other owned compound expose only their final public representation.
        (consent-validate-datum datum options)
        datum))

    (define (consent-read-all source . maybe-options)
      "Read a source body into private syntax for program/library evaluation."
      "Compound results remain host-native bootstrap syntax. Datum labels are"
      "scoped per datum, matching R7RS external representations."
      #((parameters
         (source (type (or string port))
          (description
           ("Source string or port body to read fully into datums.")))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying budget overrides."))))
        (returns (type list)
         (description
          ("A private host list of syntax datums read from SOURCE in"
            "source order and validated against the resource budgets.")))
        (effects error))
      (let* ((options (options-from-rest maybe-options))
             (reader (reader-from-source source options)))
        (let loop ((datums '()) (host-trees '()))
          (skip-intertoken-space! reader 0)
          (if (eof? reader)
              (let ((result (reverse datums))
                    (tree-flags (reverse host-trees)))
                ;; Preserve the existing parse-before-validation ordering:
                ;; later lexical errors still precede earlier datum limits.
                (let validate-loop ((rest result) (flags tree-flags))
                  (if (null? rest)
                      result
                      (begin
                        ((if (car flags)
                             validate-parser-host-tree
                             consent-validate-datum)
                         (car rest) options)
                        (validate-loop (cdr rest) (cdr flags))))))
              (begin
                (set-reader-datum-labels! reader (make-reader-label-table))
                (let ((datum
                       (resolve-datum-labels
                        (read-datum reader 0)
                        reader)))
                  (loop (cons datum datums)
                        (cons (reader-private-host-tree? reader)
                              host-trees))))))))

    (define (checked-reader-position source position)
      "Return validated POSITION for incremental SOURCE input."
      (set! position (canonical-component position))
      (if (not (or (string? source) (consent-reader-source? source)))
          (error "consent reader source must be a string or snapshot" source))
      (let ((length
             (if (consent-reader-source? source)
                 (vector-length
                  (prepared-reader-source-characters source))
                 (string-length source))))
        (if (or (not (integer? position))
                (< position 0)
                (> position length))
          (error "consent reader position out of range" position))
        position))

    (define (reader-parse-from-string-at-with-state
             source position options . maybe-construction)
      "Parse at POSITION and return its adapter result with reader state."
      (let ((reader
             (if (null? maybe-construction)
                 (reader-from-source source options)
                 (reader-from-source
                  source options (car maybe-construction)))))
        (set-reader-position! reader position)
        (skip-intertoken-space! reader 0)
        (if (eof? reader)
            (values
             (cons consent-read-eof (reader-position reader))
             reader)
            (begin
              (set-reader-datum-labels! reader (make-reader-label-table))
              (let ((datum (resolve-datum-labels
                            (read-datum reader 0)
                            reader)))
                (values
                 (cons datum (reader-position reader))
                 reader))))))

    (define (reader-parse-from-string-at
             source position options . maybe-construction)
      "Parse at POSITION with optional owned construction callbacks."
      (call-with-values
       (lambda ()
         (if (null? maybe-construction)
             (reader-parse-from-string-at-with-state
              source position options)
             (reader-parse-from-string-at-with-state
              source position options (car maybe-construction))))
       (lambda (result reader) result)))

    (define (reader-read-from-string-at source position options)
      "Read one validated private host-syntax datum at POSITION."
      (call-with-values
       (lambda ()
         (reader-parse-from-string-at-with-state
          source position options))
       (lambda (result reader)
         (if (not (consent-read-eof? (car result)))
             (reader-validate-parsed-datum
              (car result) reader options))
         result)))

    (define (consent-read-from-string-at source position . maybe-options)
      "Read one private syntax datum incrementally from SOURCE at POSITION."
      "Prepare repeated SOURCE reads with `consent-make-reader-source' so"
      "character decoding and line indexing occur once rather than per form."
      "A raw string retains stateless one-shot compatibility semantics."
      "The result's host-native adapter cdr is the next source offset."
      #((parameters
         (source (type (or string reader-source))
          (description "Source string or reusable prepared snapshot."))
         (position (type exact-non-negative-integer)
          (description
           ("Nonnegative offset within SOURCE at which to begin"
             "reading.")))
         (maybe-options (type list)
          (description
            ("Optional reader options alist supplying budget overrides."))))
        (returns (type pair)
         (description
          ("A private adapter pair whose car is the syntax datum or EOF"
            "sentinel and whose cdr is the next source offset.")))
        (effects error))
      (reader-read-from-string-at
       source
       (checked-reader-position source position)
       (options-from-rest maybe-options)))

    (define (consent-read-datum-from-string-at
             heap source position . maybe-options)
      "Read one datum incrementally into HEAP from SOURCE at POSITION."
      "The outer `(datum . position)' pair remains a private host adapter;"
      "its datum's compounds are allocated directly in HEAP."
      "Prepare repeated SOURCE reads with `consent-make-reader-source'."
      "A raw string retains stateless one-shot compatibility semantics."
      #((parameters
         (heap (type datum-heap)
          (description "Heap that owns the returned compound graph."))
         (source (type (or string reader-source))
          (description "Source string or reusable prepared snapshot."))
         (position (type exact-non-negative-integer)
          (description "Offset within SOURCE at which reading begins."))
         (maybe-options (type list)
          (description
           ("Optional reader options alist supplying budget overrides."))))
        (returns (type pair)
         (description
          ("A private adapter pair whose car is an owned datum or EOF"
            "sentinel and whose cdr is the next source offset.")))
        (effects allocation state-read state-write error))
      (if (not (consent-datum-heap? heap))
          (error
           "consent-read-datum-from-string-at expected a datum heap"
           heap))
      (let* ((options (options-from-rest maybe-options))
             (result
              (consent-call-with-datum-construction
               heap
               (lambda (make-shell fill-slot! fixup-slot!)
                 (reader-parse-from-string-at
                  source
                  (checked-reader-position source position)
                  options
                  (vector make-shell fill-slot! fixup-slot!))))))
        (if (not (consent-read-eof? (car result)))
            (consent-validate-datum (car result) options))
        result))

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

    (define (recovery-range reader start end)
      "Build a diagnostic-range datum spanning START..END through READER."
      "The shape matches `(agent diagnostics)` `make-diagnostic-range`."
      (let ((start-position (reader-line-column reader start))
            (end-position (reader-line-column reader end)))
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

    (define (build-failure-step reader resync source-id start condition)
      "Build the <consent-recovery-step> for a reader failure anchored at"
      "START.  Incomplete input rewinds to START and carries the open-construc\
t"
      "stack; a genuine error advances past the malformed region via RESYNC"
      "with guaranteed forward progress."
      (let ((kind (reader-condition-kind condition))
            (reason (condition-reason condition)))
        (if (eq? kind 'incomplete)
            (let* ((end (reader-length reader))
                   (range (recovery-range reader start end))
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
                   (range (recovery-range reader start next))
                   (text (reader-substring reader start next))
                   (diagnostic
                    (recovery-diagnostic source-id 'invalid reason range))
                   (span (recovery-span 'invalid reason range text)))
              (set-reader-position! reader next)
              (make-recovery-step 'invalid #f diagnostic span next #f)))))

    (define (recover-step! reader resync source-id options)
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
          (build-failure-step
           reader resync source-id pre (cdr skip-outcome)))
         ((eof? reader)
          (make-recovery-step 'eof #f #f #f (reader-position reader) #f))
         (else
          (let* ((start (reader-position reader))
                 (read-outcome
                  (guard-reader-failure
                   reader
                   (lambda ()
                     (set-reader-datum-labels!
                      reader
                      (make-reader-label-table))
                     (let ((datum (resolve-datum-labels
                                   (read-datum reader 0)
                                   reader)))
                       (consent-validate-datum datum options)
                       datum)))))
            (if (eq? (car read-outcome) 'value)
                (make-recovery-step 'datum (cdr read-outcome) #f #f
                                    (reader-position reader) #f)
                (build-failure-step
                 reader resync source-id start (cdr read-outcome))))))))

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
             (reader (recovery-reader source options)))
        (let loop ((datums '()) (diagnostics '()) (spans '()))
          (let* ((step (recover-step! reader resync source-id options))
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
             (reader (recovery-reader source options)))
        (set-reader-position! reader position)
        (recover-step! reader resync source-id options)))

    ;; Internal verification only: focused reader tests may supply a mutable
    ;; one-slot vector under this option to count general validation's exact
    ;; host identity-map make/ref/set calls. It is not a supported reader API.
    (define validation-identity-map-counter-option
      '%reader-validation-identity-map-operation-counter)

    (define (validation-identity-map-counter options)
      "Return and reset OPTIONS' private identity-map operation counter."
      (let ((counter
             (option-ref
              options validation-identity-map-counter-option #f)))
        (if (and counter
                 (not (and (vector? counter)
                           (= (vector-length counter) 1))))
            (error
             "reader validation identity-map counter must be one-slot vector"
             counter))
        (if counter (vector-set! counter 0 0))
        counter))

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

    (define (validate-parser-host-tree datum options)
      "Validate one parser-produced unlabelled private host tree."
      "The parser proves acyclicity and exclusive compound identity when its"
      "datum-label table is empty. Walk that tree once without allocating an"
      "identity map; pair cdr edges retain zero depth and one list-length"
      "scope while car and vector edges increase depth."
      (validation-identity-map-counter options)
      (let ((maximum-depth
             (option-count options 'max-depth
                           consent-default-maximum-depth))
            (maximum-list-length
             (option-count options 'max-list-length
                           consent-default-maximum-list-length))
            (maximum-vector-length
             (option-count options 'max-vector-length
                           consent-default-maximum-vector-length))
            (maximum-bytevector-length
             (option-count options 'max-bytevector-length
                           consent-default-maximum-bytevector-length))
            (maximum-string-size
             (option-count options 'max-string-size
                           consent-default-maximum-string-size))
            (validation
             (make-validation
              0
              (option-count options 'max-total-nodes
                            consent-default-maximum-total-nodes))))

        (define (depth-check! depth)
          "Reject DEPTH above this host-tree validation's cached ceiling."
          (if (> depth maximum-depth)
              (error
               "consent datum limit error: datum depth exceeds maximum depth"
               depth)))

        (define (list-limit-error)
          "Raise this host-tree validation's list-length error."
          (error
           "consent datum limit error: list length exceeds maximum list length"
           maximum-list-length))

        (define (push-vector-elements value depth rest)
          "Prepend VALUE's host-vector element jobs in source order."
          (let push ((index (- (vector-length value) 1))
                     (next rest))
            (if (< index 0)
                next
                (push
                 (- index 1)
                 (cons
                  (vector 'datum
                          (vector-ref value index)
                          (+ depth 1)
                          0)
                  next)))))

        ;; Jobs carry KIND, VALUE, DEPTH, and the pair count already consumed
        ;; by one active cdr spine. This is an explicit stack, so deeply nested
        ;; parser trees cannot consume the host control stack.
        (let walk ((work (list (vector 'datum datum 0 0))))
          (if (not (null? work))
              (let* ((job (car work))
                     (kind (vector-ref job 0))
                     (value (vector-ref job 1))
                     (depth (vector-ref job 2))
                     (list-length (vector-ref job 3))
                     (rest (cdr work)))
                (depth-check! depth)
                (if (eq? kind 'pair-tail)
                    (cond
                     ((pair? value)
                      (let ((next-length (+ list-length 1)))
                        (validation-note-node! validation)
                        (if (> next-length maximum-list-length)
                            (list-limit-error))
                        (walk
                         (cons
                          (vector 'datum (car value) (+ depth 1) 0)
                          (cons
                           (vector 'pair-tail
                                   (cdr value)
                                   depth
                                   next-length)
                           rest)))))
                     ((null? value) (walk rest))
                     (else
                      (walk
                       (cons (vector 'datum value depth 0) rest))))
                    (cond
                     ((or (boolean? value)
                          (reader-datum-symbol? value)
                          (consent-character? value)
                          (consent-number? value))
                      (validation-note-node! validation)
                      (walk rest))
                     ((string? value)
                      (if (> (string-length value) maximum-string-size)
                          (error
                           "consent datum limit error: string size exceeds \
maximum string size"
                           maximum-string-size))
                      (validation-note-node! validation)
                      (walk rest))
                     ((bytevector? value)
                      (if (> (bytevector-length value)
                             maximum-bytevector-length)
                          (error
                           "consent datum limit error: bytevector length \
exceeds maximum bytevector length"
                           maximum-bytevector-length))
                      (let check ((index 0))
                        (if (< index (bytevector-length value))
                            (let ((byte (bytevector-u8-ref value index)))
                              (if (not (and (integer? byte)
                                            (<= 0 byte)
                                            (<= byte 255)))
                                  (error
                                   "consent reader error: bytevector contains \
invalid byte"
                                   byte))
                              (check (+ index 1)))))
                      (validation-note-node! validation)
                      (walk rest))
                     ((null? value)
                      (validation-note-node! validation)
                      (walk rest))
                     ((pair? value)
                      (validation-note-node! validation)
                      (if (> 1 maximum-list-length)
                          (list-limit-error))
                      (walk
                       (cons
                        (vector 'datum (car value) (+ depth 1) 0)
                        (cons
                         (vector 'pair-tail (cdr value) depth 1)
                         rest))))
                     ((vector? value)
                      (validation-note-node! validation)
                      (if (> (vector-length value) maximum-vector-length)
                          (error
                           "consent datum limit error: vector length exceeds \
maximum vector length"
                           maximum-vector-length))
                      (walk
                       (push-vector-elements value depth rest)))
                     (else
                      (error
                       "consent reader error: datum contains unsupported object"
                       value))))))))
      datum)

    (define (validate-datum datum options validation)
      "Validate one mixed datum graph with a global visited set and worklist."
      "Shared compounds are traversed and charged once. Pair-spine spans are"
      "memoized separately so every list entry still enforces its full length"
      "without rewalking a shared tail. Graph depth is the minimum weighted"
      "distance from the root: pair cdr edges cost zero; pair car and vector"
      "element edges cost one. This makes shared-DAG validation independent"
      "of edge order while the parser separately enforces source nesting."
      (let ((maximum-depth
             (option-count options 'max-depth
                           consent-default-maximum-depth))
            (maximum-list-length
             (option-count options 'max-list-length
                           consent-default-maximum-list-length))
            (maximum-vector-length
             (option-count options 'max-vector-length
                           consent-default-maximum-vector-length))
            (maximum-bytevector-length
             (option-count options 'max-bytevector-length
                           consent-default-maximum-bytevector-length))
            (maximum-string-size
             (option-count options 'max-string-size
                           consent-default-maximum-string-size))
            (nodes (make-reader-identity-map))
            (node-absent (vector 'validation-node-absent))
            (operation-counter
             (validation-identity-map-counter options)))

        (define (count-host-identity-operation!)
          "Charge one exact host identity-map call to the private counter."
          ;; The ordinary path retains the branch-free hybrid adapter. Only a
          ;; focused verification run substitutes counted operations selected
          ;; once here; the supported path pays no per-operation probe.
          (vector-set!
           operation-counter
           0
           (+ (vector-ref operation-counter 0) 1)))

        (define (counted-identity-map-ref map key default)
          "Return KEY from MAP while counting exact host adapter calls."
          (let ((table
                 (vector-ref
                  map (if (consent-datum-object? key) 0 1))))
            (if (not table)
                default
                (if (consent-datum-object? key)
                    (consent-datum-object-map-ref table key default)
                    (begin
                      (count-host-identity-operation!)
                      (consent-identity-map-ref table key default))))))

        (define (counted-identity-map-set! map key value)
          "Set KEY in MAP while counting exact host adapter calls."
          (let* ((owned? (consent-datum-object? key))
                 (index (if owned? 0 1))
                 (table (vector-ref map index)))
            (if (not table)
                (begin
                  (if owned?
                      #t
                      (count-host-identity-operation!))
                  (set! table
                        (if owned?
                            (consent-make-datum-object-map)
                            (consent-make-identity-map
                             'reader-validation)))
                  (vector-set! map index table)))
            (if owned?
                (consent-datum-object-map-set! table key value)
                (begin
                  (count-host-identity-operation!)
                  (consent-identity-map-set! table key value))))
          value)

        (define validation-identity-map-ref
          (if operation-counter
              counted-identity-map-ref
              reader-identity-map-ref))

        (define validation-identity-map-set!
          (if operation-counter
              counted-identity-map-set!
              reader-identity-map-set!))

        (define (validation-node-state value create?)
          "Return VALUE's composite validation state, optionally creating it."
          "One entry keeps every validation fact under one owned traversal"
          "token: #(seen? minimum-depth list-span list-position)."
          (let ((state
                 (validation-identity-map-ref
                  nodes value node-absent)))
            (if (and create? (eq? state node-absent))
                (let ((created (vector #f #f #f #f)))
                  (validation-identity-map-set! nodes value created)
                  created)
                state)))

        (define (validation-state-ref value slot default)
          "Return VALUE's validation SLOT, or DEFAULT when absent."
          (let ((state (validation-node-state value #f)))
            (if (eq? state node-absent)
                default
                (or (vector-ref state slot) default))))

        (define (validation-state-set! value slot datum)
          "Store DATUM in VALUE's composite validation SLOT."
          (vector-set! (validation-node-state value #t) slot datum)
          datum)

        (define (depth-check! depth)
          "Reject DEPTH above this validation run's cached ceiling."
          (if (> depth maximum-depth)
              (error
               "consent datum limit error: datum depth exceeds maximum depth"
               depth)))

        (define (list-limit-error)
          "Raise this validation run's list-length error."
          (error
           "consent datum limit error: list length exceeds maximum list length"
           maximum-list-length))

        (define (memoize-list-path! start path length base cycle-start)
          "Memoize every pair in reversed PATH and return its head span."
          (let finish ((rest path))
            (if (not (null? rest))
                (let* ((entry (car rest))
                       (node (vector-ref entry 0))
                       (index (vector-ref entry 1))
                       (span
                        (if cycle-start
                            (if (>= index cycle-start)
                                (- length cycle-start)
                                (- length index))
                            (+ base (- length index)))))
                  (validation-state-set! node 2 span)
                  (validation-state-set! node 3 #f)
                  (finish (cdr rest)))))
          (validation-state-ref start 2 #f))

        (define (list-span start)
          "Return START's unique pair-spine span in expected linear total time."
          (let ((known (validation-state-ref start 2 #f)))
            (if known
                known
                (let walk ((cursor start) (path '()) (length 0))
                  (if (> length maximum-list-length)
                      (list-limit-error))
                  (cond
                   ((not (reader-pair? cursor))
                    (memoize-list-path! start path length 0 #f))
                   ((validation-state-ref cursor 2 #f)
                    => (lambda (base)
                         (memoize-list-path!
                          start path length base #f)))
                   ((validation-state-ref cursor 3 #f)
                    => (lambda (position)
                         (memoize-list-path!
                          start path length 0 (- position 1))))
                   (else
                    (validation-state-set! cursor 3 (+ length 1))
                    (walk (reader-cdr cursor)
                          (cons (vector cursor length) path)
                          (+ length 1))))))))

        (define (validation-identity-node? value)
          "Report whether VALUE has graph identity relevant to validation."
          (or (reader-pair? value)
              (reader-vector? value)
              (reader-string? value)
              (reader-bytevector? value)))

        (define (minimum-depth value proposed)
          "Return VALUE's minimum graph depth, or PROPOSED for an atom."
          (if (validation-identity-node? value)
              (validation-state-ref value 1 proposed)
              proposed))

        (define (compute-minimum-depths! root)
          "Index minimum 0/1-weighted depths for ROOT's identity graph."
          ;; FRONT is consumed directly. BACK is stored in reverse insertion
          ;; order and reversed only when FRONT empties, yielding an amortized
          ;; constant-time deque for the zero-one shortest-path traversal.
          (let ((queue (vector '() '())))
            (define (push-front! job)
              (vector-set! queue 0 (cons job (vector-ref queue 0))))

            (define (push-back! job)
              (vector-set! queue 1 (cons job (vector-ref queue 1))))

            (define (pop-front!)
              (if (null? (vector-ref queue 0))
                  (begin
                    (vector-set! queue 0 (reverse (vector-ref queue 1)))
                    (vector-set! queue 1 '())))
              (let ((front (vector-ref queue 0)))
                (if (null? front)
                    #f
                    (begin
                      (vector-set! queue 0 (cdr front))
                      (car front)))))

            (define (relax! value depth front?)
              (if (validation-identity-node? value)
                  (begin
                    (let ((old
                           (validation-state-ref value 1 #f)))
                      (if (or (not old) (< depth old))
                          (begin
                            ;; First discovery is also the compound's single
                            ;; total-node charge, so an undersized budget stops
                            ;; the depth prepass before it can scan the graph.
                            (if (not old)
                                (validation-note-node! validation))
                            (validation-state-set! value 1 depth)
                            ((if front? push-front! push-back!)
                             (vector value depth))))))))

            (relax! root 0 #t)
            (let drain ()
              (let ((job (pop-front!)))
                (if job
                    (begin
                      (let ((value (vector-ref job 0))
                            (depth (vector-ref job 1)))
                        ;; Ignore a queued distance superseded by a shorter
                        ;; zero-edge path before this action reached the front.
                        (if (= depth
                               (validation-state-ref value 1 depth))
                            (cond
                             ((reader-pair? value)
                              (if (> (list-span value)
                                     maximum-list-length)
                                  (list-limit-error))
                              (relax! (reader-car value)
                                      (+ depth 1)
                                      #f)
                              (relax! (reader-cdr value) depth #t))
                             ((reader-vector? value)
                              (if (> (reader-vector-length value)
                                     maximum-vector-length)
                                  (error
                                   "consent datum limit error: vector length \
exceeds maximum vector length"
                                   maximum-vector-length))
                              (let schedule ((index 0))
                                (if (< index
                                       (reader-vector-length value))
                                    (begin
                                      (relax!
                                       (reader-vector-ref value index)
                                       (+ depth 1)
                                       #f)
                                      (schedule (+ index 1))))))))
                      (drain))))))))

        (define (first-visit? value)
          "Mark VALUE visited and report whether it was previously absent."
          (if (validation-state-ref value 0 #f)
              #f
              (begin
                (validation-state-set! value 0 #t)
                #t)))

        (define (push-vector-elements value depth rest)
          "Prepend VALUE's element jobs in index order to REST."
          (let push ((index (- (reader-vector-length value) 1))
                     (next rest))
            (if (< index 0)
                next
                (push
                 (- index 1)
                 (cons
                  (vector 'datum
                          (reader-vector-ref value index)
                          (+ depth 1))
                  next)))))

        ;; A datum job starts a new list-length scope. A pair-tail job follows
        ;; one already-checked cdr spine without charging its null terminator.
        (dynamic-wind
         (lambda () #t)
         (lambda ()
          (compute-minimum-depths! datum)
          (let walk ((work (list (vector 'datum datum 0))))
            (if (not (null? work))
                (let* ((job (car work))
                     (kind (vector-ref job 0))
                     (value (vector-ref job 1))
                     (depth
                      (minimum-depth value (vector-ref job 2)))
                     (rest (cdr work)))
                (depth-check! depth)
                (if (eq? kind 'pair-tail)
                    (cond
                     ((reader-pair? value)
                      (if (first-visit? value)
                          (begin
                            (walk
                             (cons
                              (vector 'datum
                                      (reader-car value)
                                      (+ depth 1))
                              (cons
                               (vector 'pair-tail
                                       (reader-cdr value)
                                       depth)
                               rest))))
                          (walk rest)))
                     ((null? value) (walk rest))
                     (else
                      (walk
                       (cons (vector 'datum value depth) rest))))
                    (cond
                     ((or (boolean? value)
                          (reader-datum-symbol? value)
                          (consent-character? value)
                          (consent-number? value))
                      (validation-note-node! validation)
                      (walk rest))
                     ((reader-string? value)
                      (if (> (reader-string-length value)
                             maximum-string-size)
                          (error
                           "consent datum limit error: string size exceeds \
maximum string size"
                           maximum-string-size))
                      (if (first-visit? value)
                          #t)
                      (walk rest))
                     ((reader-bytevector? value)
                      (if (> (reader-bytevector-length value)
                             maximum-bytevector-length)
                          (error
                           "consent datum limit error: bytevector length \
exceeds maximum bytevector length"
                           maximum-bytevector-length))
                      (if (first-visit? value)
                          (begin
                            (let check ((index 0))
                              (if (< index
                                     (reader-bytevector-length value))
                                  (let ((byte
                                         (reader-bytevector-u8-ref
                                          value index)))
                                    (if (not (and (integer? byte)
                                                  (<= 0 byte)
                                                  (<= byte 255)))
                                        (error
                                         "consent reader error: bytevector \
contains invalid byte"
                                         byte))
                                    (check (+ index 1)))))
                            #t))
                      (walk rest))
                     ((null? value)
                      (validation-note-node! validation)
                      (walk rest))
                     ((reader-pair? value)
                      (if (> (list-span value) maximum-list-length)
                          (list-limit-error))
                      (if (first-visit? value)
                          (begin
                            (walk
                             (cons
                              (vector 'datum
                                      (reader-car value)
                                      (+ depth 1))
                              (cons
                               (vector 'pair-tail
                                       (reader-cdr value)
                                       depth)
                               rest))))
                          (walk rest)))
                     ((reader-vector? value)
                      (if (> (reader-vector-length value)
                             maximum-vector-length)
                          (error
                           "consent datum limit error: vector length exceeds \
maximum vector length"
                           maximum-vector-length))
                      (if (first-visit? value)
                          (begin
                            (walk
                             (push-vector-elements value depth rest)))
                          (walk rest)))
                     (else
                      (error
                       "consent reader error: datum contains unsupported object"
                       value))))))))
         (lambda ()
           (reader-identity-map-release! nodes)))))

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
        (validate-datum datum options validation)
        datum))

    (define (escape-text text vertical-symbol?)
      "Escape TEXT for a string or, when requested, a vertical symbol."
      (let ((output (open-output-string)))
        (string-for-each
         (lambda (char)
           (cond
            ((char=? char (integer->char 7)) (display "\\a" output))
            ((char=? char (integer->char 8)) (display "\\b" output))
            ((char=? char #\tab) (display "\\t" output))
            ((char=? char #\newline) (display "\\n" output))
            ((char=? char #\return) (display "\\r" output))
            ((char=? char #\") (display "\\\"" output))
            ((char=? char #\\) (display "\\\\" output))
            ((and vertical-symbol? (char=? char #\|))
             (display "\\|" output))
            (else (write-char char output))))
         text)
        (get-output-string output)))

    (define (escape-string text)
      "Escape string TEXT for stable external rendering."
      (escape-text text #f))

    (define (escape-symbol-name name)
      "Escape vertical symbol NAME for stable external rendering."
      (escape-text name #t))

    (define (symbol-needs-bars? name)
      "Report whether NAME requires vertical bars in external syntax."
      (or (not (identifier-token? name))
          (and
           (number-token-candidate? name)
           (parse-number-token (reader-from-source "" '()) name))))

    (define (write-symbol-name name)
      "Render a symbol name with escaping when the token grammar requires it."
      (if (symbol-needs-bars? name)
          (string-append "|" (escape-symbol-name name) "|")
          name))

    ;; Symbols are interned and immutable.  Retaining a small bounded set of
    ;; their canonical spellings avoids reparsing the same runtime field names
    ;; on every diagnostic, memory search, and prompt projection.  The bound
    ;; also makes the plain-R7RS identity-map compatibility backend constant
    ;; space and constant-bounded lookup work.
    (define writer-symbol-cache '())
    ;; Number of canonical spellings currently retained in the cache.
    (define writer-symbol-cache-count 0)
    ;; Fixed upper bound keeps the compatibility lookup cost bounded.
    (define writer-symbol-cache-limit 256)

    (define (write-symbol-datum symbol)
      "Return interned SYMBOL's cached canonical external spelling."
      (let ((known (assq symbol writer-symbol-cache)))
        (if known
            (cdr known)
            (let ((rendered
                   (write-symbol-name
                    (reader-datum-symbol-name symbol))))
              (if (< writer-symbol-cache-count writer-symbol-cache-limit)
                  (begin
                    (set! writer-symbol-cache
                          (cons (cons symbol rendered)
                                writer-symbol-cache))
                    (set! writer-symbol-cache-count
                          (+ writer-symbol-cache-count 1))))
              rendered))))

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
      (let ((output (open-output-string)))
        (let loop ((rest strings) (first? #t))
          (if (null? rest)
              (get-output-string output)
              (begin
                (if (not first?) (display separator output))
                (display (car rest) output)
                (loop (cdr rest) #f))))))

    (define (writer-compound? datum)
      "Report whether DATUM can participate in shared or circular structure."
      (or (reader-pair? datum) (reader-vector? datum)))

    (define (writer-tree->external datum mode display?)
      "Render tree-shaped DATUM quickly, or return #f for a graph."
      ;; The general writer below must retain per-node DFS state so it can
      ;; label cycles and write-shared aliases.  Most values are trees.  Prove
      ;; that bounded case while rendering, then fall back before publishing
      ;; any partial output when sharing, a cycle, or a large graph appears.

      (let ()
        (define (record-name->external name)
          (cond
           ((reader-datum-symbol? name) (reader-datum-symbol-name name))
           ((reader-string? name) (reader-string->host name))
           (else
            (error "consent reader error: invalid record name" name))))

        (define (render-fast root)
          "Render a bounded acyclic value, or return #f for graph fallback."
          (call-with-current-continuation
           (lambda (fallback)
             (let ((output (open-output-string))
                   (seen '())
                   (count 0))
               (define (emit! text)
                 (display text output))
               (define (enter-compound value ancestors)
                 (set! count (+ count 1))
                 (if (or (> count 128) (memq value ancestors))
                     (fallback #f))
                 (if (and (eq? mode 'shared) (memq value seen))
                     (fallback #f))
                 (set! seen (cons value seen))
                 (cons value ancestors))
               (define (write-pair cursor first? ancestors)
                 (cond
                  ((reader-pair? cursor)
                   (let ((next-ancestors
                          (enter-compound cursor ancestors)))
                     (if (not first?) (emit! " "))
                     (write-value
                      (reader-car cursor) next-ancestors)
                     (write-pair
                      (reader-cdr cursor) #f next-ancestors)))
                  ((null? cursor) (emit! ")"))
                  (else
                   (emit! (if first? ". " " . "))
                   (write-value cursor ancestors)
                   (emit! ")"))))
               (define (write-value value ancestors)
                 (cond
                  ((boolean? value) (emit! (if value "#t" "#f")))
                  ((null? value) (emit! "()"))
                  ((reader-datum-symbol? value)
                   (emit!
                    (if display?
                        (reader-datum-symbol-name value)
                        (write-symbol-datum value))))
                  ((or (consent-character? value) (char? value))
                   (let ((character
                          (if (consent-character? value)
                              value
                              (consent-host-character->character value))))
                     (emit!
                      (if display?
                          (string
                           (consent-character->host-character character))
                          (write-character-datum character)))))
                  ((or (consent-number? value) (number? value))
                   (emit! (consent-number->external value)))
                  ((reader-string? value)
                   (let ((text (reader-string->host value)))
                     (if display?
                         (emit! text)
                         (begin
                           (emit! "\"")
                           (emit! (escape-string text))
                           (emit! "\"")))))
                  ((reader-bytevector? value)
                   (emit! "#u8(")
                   (let loop ((index 0))
                     (if (= index (reader-bytevector-length value))
                         (emit! ")")
                         (begin
                           (if (> index 0) (emit! " "))
                           (emit!
                            (consent-integer->radix-string
                             (reader-bytevector-u8-ref value index)
                             10))
                           (loop (+ index 1))))))
                  ((reader-pair? value)
                   (emit! "(")
                   (write-pair value #t ancestors))
                  ((reader-vector? value)
                   (let ((next-ancestors
                          (enter-compound value ancestors)))
                     (emit! "#(")
                     (let loop ((index 0))
                       (if (= index (reader-vector-length value))
                           (emit! ")")
                           (begin
                             (if (> index 0) (emit! " "))
                             (write-value
                              (reader-vector-ref value index)
                              next-ancestors)
                             (loop (+ index 1)))))))
                  ((consent-record? value)
                   (emit! "#<record ")
                   (emit!
                    (record-name->external
                     (consent-record-type-name
                      (consent-record-type value))))
                   (emit! ">"))
                  ((consent-record-type? value)
                   (emit! "#<record-type ")
                   (emit!
                    (record-name->external
                     (consent-record-type-name value)))
                   (emit! ">"))
                  (else
                   (error
                    (string-append
                     "consent reader error: cannot write unsupported datum")
                    value))))
               (write-value root '())
               (get-output-string output)))))

        (render-fast datum)))

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
        (effects allocation state-read state-write))
      (let* ((mode (if (null? maybe-options) 'write (car maybe-options)))
             (display? (if (or (null? maybe-options)
                               (null? (cdr maybe-options)))
                           #f
                           (cadr maybe-options)))
             (tree-output
              (writer-tree->external datum mode display?)))
        (if tree-output
            tree-output
            (let ((nodes (make-reader-identity-map))
                  (node-absent (vector 'writer-node-absent))
                  (cyclic-found? #f)
                  (next-label 0)
                  (parts '()))

        (define (emit! text)
          "Append TEXT to the reverse writer fragment accumulator."
          (set! parts (cons text parts)))

        (define (writer-node-state value create?)
          "Return VALUE's composite writer state, optionally creating it."
          "One entry carries every canonical-writer fact under one owned map"
          "token: #(count state cyclic? parent depth cycle-skip label"
          "emitted?)."
          (let ((state
                 (reader-identity-map-ref nodes value node-absent)))
            (if (and create? (eq? state node-absent))
                (let ((created (vector 0 #f #f #f -1 #f #f #f)))
                  (reader-identity-map-set! nodes value created)
                  created)
                state)))

        (define (writer-state-ref value slot default)
          "Return VALUE's writer SLOT, or DEFAULT when no state exists."
          (let ((state (writer-node-state value #f)))
            (if (eq? state node-absent)
                default
                (vector-ref state slot))))

        (define (writer-state-set! value slot datum)
          "Store DATUM in VALUE's composite writer SLOT."
          (vector-set! (writer-node-state value #t) slot datum)
          datum)

        (define (set-count! value count)
          (writer-state-set! value 0 count))

        (define (set-state! value state)
          (writer-state-set! value 1 state))

        (define (mark-cyclic! value)
          (set! cyclic-found? #t)
          (writer-state-set! value 2 #t))

        (define (next-unmarked-cycle-node value)
          "Return VALUE's nearest unmarked ancestor with path compression."
          (let find ((value value) (path '()))
            (if (or (not value)
                    (not (writer-state-ref value 2 #f)))
                (begin
                  (let compress ((rest path))
                    (if (not (null? rest))
                        (begin
                          (writer-state-set! (car rest) 5 value)
                          (compress (cdr rest)))))
                  value)
                (find
                 (writer-state-ref value 5 #f)
                 (cons value path)))))

        (define (mark-cycle-path! source target)
          "Mark the DFS ancestor path from SOURCE through TARGET cyclic."
          (let ((target-depth
                 (writer-state-ref target 4 -1)))
            (let loop ((value (next-unmarked-cycle-node source)))
              (if (and value
                       (>= (writer-state-ref value 4 -1)
                           target-depth))
                  (begin
                    (mark-cyclic! value)
                    (writer-state-set!
                     value 5 (writer-state-ref value 3 #f))
                    (loop (next-unmarked-cycle-node value)))))))

        (define (scan root)
          "Count and classify ROOT's graph with an explicit DFS worklist."
          (let loop ((work (list (vector root #f #f))))
            (if (not (null? work))
                (let* ((action (car work))
                       (value (vector-ref action 0))
                       (leaving? (vector-ref action 1))
                       (parent (vector-ref action 2))
                       (rest (cdr work)))
                  (cond
                   (leaving?
                    (set-state! value 'done)
                    (loop rest))
                   ((not (writer-compound? value)) (loop rest))
                   (else
                    (set-count!
                     value
                     (+ (writer-state-ref value 0 0) 1))
                    (let ((state
                           (writer-state-ref value 1 #f)))
                      (cond
                       ((eq? state 'visiting)
                        (mark-cycle-path! parent value)
                        (loop rest))
                       ((eq? state 'done) (loop rest))
                       (else
                        (set-state! value 'visiting)
                        (writer-state-set! value 3 parent)
                        (writer-state-set!
                         value
                         4
                         (if parent
                             (+ (writer-state-ref parent 4 -1) 1)
                             0))
                        (if (reader-pair? value)
                            (loop
                             (cons
                              (vector (reader-car value) #f value)
                              (cons
                               (vector (reader-cdr value) #f value)
                               (cons (vector value #t #f) rest))))
                            (let push
                                ((index
                                  (- (reader-vector-length value) 1))
                                 (next (cons (vector value #t #f) rest)))
                              (if (< index 0)
                                  (loop next)
                                  (push
                                   (- index 1)
                                   (cons
                                    (vector
                                     (reader-vector-ref value index) #f value)
                                    next))))))))))))))

        (define (label-needed? value)
          (and (writer-compound? value)
               (cond
                ((eq? mode 'shared)
                 (> (writer-state-ref value 0 0) 1))
                ((eq? mode 'write)
                 (writer-state-ref value 2 #f))
                (else #f))))

        (define (label-for value)
          (let ((label (writer-state-ref value 6 #f)))
            (if label
                label
                (let ((label next-label))
                  (set! next-label (+ next-label 1))
                  (writer-state-set! value 6 label)
                  label))))

        (define (labelled-tail-boundary? value)
          "Report whether VALUE must start a labelled dotted cdr tail."
          (and (label-needed? value)
               (or (writer-state-ref value 7 #f)
                   (> (writer-state-ref value 0 0) 1))))

        (define (record-name->external name)
          (cond
           ((reader-datum-symbol? name) (reader-datum-symbol-name name))
           ((reader-string? name) (reader-string->host name))
           (else (error "consent reader error: invalid record name"
                        name))))

        (define (render root)
          "Render ROOT with an explicit action stack."
          (let loop ((actions (list (vector 'render root))))
            (if (not (null? actions))
                (let* ((action (car actions))
                       (kind (vector-ref action 0))
                       (rest (cdr actions)))
                  (case kind
                    ((text)
                     (emit! (vector-ref action 1))
                     (loop rest))
                    ((render)
                     (let ((value (vector-ref action 1)))
                       (if (label-needed? value)
                           (let ((label (label-for value)))
                             (emit! "#")
                             (emit!
                              (consent-integer->radix-string label 10))
                             (if (writer-state-ref value 7 #f)
                                 (begin
                                   (emit! "#")
                                   (loop rest))
                                 (begin
                                   (writer-state-set! value 7 #t)
                                   (emit! "=")
                                   (loop
                                    (cons (vector 'body value) rest)))))
                           (loop (cons (vector 'body value) rest)))))
                    ((body)
                     (let ((value (vector-ref action 1)))
                       (cond
                        ((boolean? value)
                         (emit! (if value "#t" "#f"))
                         (loop rest))
                        ((null? value)
                         (emit! "()")
                         (loop rest))
                        ((reader-datum-symbol? value)
                         (emit!
                          (if display?
                              (reader-datum-symbol-name value)
                              (write-symbol-datum value)))
                         (loop rest))
                        ((or (consent-character? value) (char? value))
                         (let ((character
                                (if (consent-character? value)
                                    value
                                    (consent-host-character->character value))))
                           (emit!
                            (if display?
                                (string
                                 (consent-character->host-character character))
                                (write-character-datum character)))
                           (loop rest)))
                        ((or (consent-number? value) (number? value))
                         (emit! (consent-number->external value))
                         (loop rest))
                        ((reader-string? value)
                         (let ((text (reader-string->host value)))
                           (if display?
                               (emit! text)
                               (begin
                                 (emit! "\"")
                                 (emit! (escape-string text))
                                 (emit! "\""))))
                         (loop rest))
                        ((reader-bytevector? value)
                         (emit! "#u8(")
                         (loop (cons (vector 'bytevector value 0) rest)))
                        ((reader-pair? value)
                         (emit! "(")
                         (loop (cons (vector 'list value #t) rest)))
                        ((reader-vector? value)
                         (emit! "#(")
                         (loop (cons (vector 'vector value 0) rest)))
                        ((consent-record? value)
                         (emit! "#<record ")
                         (emit!
                          (record-name->external
                           (consent-record-type-name
                            (consent-record-type value))))
                         (emit! ">")
                         (loop rest))
                        ((consent-record-type? value)
                         (emit! "#<record-type ")
                         (emit!
                          (record-name->external
                           (consent-record-type-name value)))
                         (emit! ">")
                         (loop rest))
                        (else
                         (error
                          "consent reader error: cannot write unsupported datum"
                          value)))))
                    ((list)
                     (let ((cursor (vector-ref action 1))
                           (first? (vector-ref action 2)))
                       (cond
                        ((and (reader-pair? cursor)
                              (not (and (not first?)
                                        (labelled-tail-boundary? cursor))))
                         (if (not first?) (emit! " "))
                         (loop
                          (cons
                           (vector 'render (reader-car cursor))
                           (cons
                            (vector 'list (reader-cdr cursor) #f)
                            rest))))
                        ((null? cursor)
                         (emit! ")")
                         (loop rest))
                        (else
                         (emit! (if first? ". " " . "))
                         (loop
                          (cons
                           (vector 'render cursor)
                           (cons (vector 'text ")") rest)))))))
                    ((vector)
                     (let ((value (vector-ref action 1))
                           (index (vector-ref action 2)))
                       (if (= index (reader-vector-length value))
                           (begin
                             (emit! ")")
                             (loop rest))
                           (begin
                             (if (> index 0) (emit! " "))
                             (loop
                              (cons
                               (vector
                                'render
                                (reader-vector-ref value index))
                               (cons
                                (vector 'vector value (+ index 1))
                                rest)))))))
                    ((bytevector)
                     (let ((value (vector-ref action 1))
                           (index (vector-ref action 2)))
                       (if (= index (reader-bytevector-length value))
                           (begin
                             (emit! ")")
                             (loop rest))
                           (begin
                             (if (> index 0) (emit! " "))
                             (emit!
                              (consent-integer->radix-string
                               (reader-bytevector-u8-ref value index)
                               10))
                             (loop
                              (cons
                               (vector 'bytevector value (+ index 1))
                               rest)))))))))))

        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (scan datum)
           (if (and (eq? mode 'simple) cyclic-found?)
               (error
                (string-append
                 "consent reader error: write-simple cannot render "
                 "circular datum")))
           (render datum)
           (join (reverse parts) ""))
         (lambda ()
           (reader-identity-map-release! nodes)))))))

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
      (let ((entry
             (let loop ((rest limits))
               (cond
                ((null? rest) #f)
                ((not (reader-pair? rest)) #f)
                (else
                 (let ((candidate (reader-car rest)))
                   (if (and (reader-pair? candidate)
                            (consent-host-symbol-eq?
                             key
                             (reader-car candidate)))
                       candidate
                       (loop (reader-cdr rest)))))))))
        (and entry
             (let ((value (reader-cdr entry)))
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
            (ancestors (make-reader-identity-map)))

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
                           (reader-string? value)
                           (> (reader-string-length value)
                              (- size-limit used)))
                      (reader-string-prefix->host
                       value
                       (max 0 (- size-limit used)))
                      value)))
            (consent-datum->external value mode displayp)))

        (define (finish-pair! frame)
          "Close and clear one active pair-spine FRAME."
          (emit! ")")
          (reader-identity-map-clear! ancestors (vector-ref frame 0)))

        (define (render root)
          "Render ROOT under LIMITS with an explicit action stack."
          (let loop ((actions (list (vector 'render root 0))))
            (if (and (not overflow) (not (null? actions)))
                (let* ((action (car actions))
                       (kind (vector-ref action 0))
                       (rest (cdr actions)))
                  (case kind
                    ((render)
                     (let ((value (vector-ref action 1))
                           (depth (vector-ref action 2)))
                       (cond
                        ((reader-pair? value)
                         (cond
                          ((reader-identity-map-ref ancestors value #f)
                           (emit! marker)
                           (loop rest))
                          ((and depth-limit (>= depth depth-limit))
                           (emit! marker)
                           (loop rest))
                          (else
                           (emit! "(")
                           (loop
                            (cons
                             (vector
                              'pair value depth 0 #t (vector '()))
                             rest)))))
                        ((reader-vector? value)
                         (cond
                          ((reader-identity-map-ref ancestors value #f)
                           (emit! marker)
                           (loop rest))
                          ((and depth-limit (>= depth depth-limit))
                           (emit! marker)
                           (loop rest))
                          (else
                           (reader-identity-map-set! ancestors value #t)
                           (emit! "#(")
                           (loop
                            (cons (vector 'vector value depth 0 #t)
                                  rest)))))
                        ((reader-bytevector? value)
                         (if (and depth-limit (>= depth depth-limit))
                             (begin
                               (emit! marker)
                               (loop rest))
                             (begin
                               (emit! "#u8(")
                               (loop
                                (cons
                                 (vector 'bytevector value 0 #t)
                                 rest)))))
                        (else
                         (emit! (atom-text value))
                         (loop rest)))))
                    ((pair)
                     (let ((cursor (vector-ref action 1))
                           (depth (vector-ref action 2))
                           (count (vector-ref action 3))
                           (first? (vector-ref action 4))
                           (frame (vector-ref action 5)))
                       (cond
                        ((not (reader-pair? cursor))
                         (if (null? cursor)
                             (begin
                               (finish-pair! frame)
                               (loop rest))
                             (begin
                               (emit! " . ")
                               (loop
                                (cons
                                 (vector 'render cursor (+ depth 1))
                                 (cons
                                  (vector 'finish-pair frame)
                                  rest))))))
                        (else
                         (cond
                          ((reader-identity-map-ref ancestors cursor #f)
                           (emit! " . ")
                           (emit! marker)
                           (finish-pair! frame)
                           (loop rest))
                          ((and length-limit (>= count length-limit))
                           (emit! " ")
                           (emit! marker)
                           (finish-pair! frame)
                           (loop rest))
                          (else
                           (if (not first?) (emit! " "))
                           (reader-identity-map-set! ancestors cursor #t)
                           (vector-set!
                            frame 0 (cons cursor (vector-ref frame 0)))
                           (loop
                            (cons
                             (vector 'render
                                     (reader-car cursor)
                                     (+ depth 1))
                             (cons
                              (vector 'pair
                                      (reader-cdr cursor)
                                      depth
                                      (+ count 1)
                                      #f
                                      frame)
                              rest)))))))))
                    ((finish-pair)
                     (finish-pair! (vector-ref action 1))
                     (loop rest))
                    ((vector)
                     (let ((value (vector-ref action 1))
                           (depth (vector-ref action 2))
                           (index (vector-ref action 3))
                           (first? (vector-ref action 4)))
                       (cond
                        ((>= index (reader-vector-length value))
                         (emit! ")")
                         (reader-identity-map-set! ancestors value #f)
                         (loop rest))
                        ((and length-limit (>= index length-limit))
                         (if (not first?) (emit! " "))
                         (emit! marker)
                         (emit! ")")
                         (reader-identity-map-set! ancestors value #f)
                         (loop rest))
                        (else
                         (if (not first?) (emit! " "))
                         (loop
                          (cons
                           (vector 'render
                                   (reader-vector-ref value index)
                                   (+ depth 1))
                           (cons
                            (vector 'vector
                                    value depth (+ index 1) #f)
                            rest)))))))
                    ((bytevector)
                     (let ((value (vector-ref action 1))
                           (index (vector-ref action 2))
                           (first? (vector-ref action 3)))
                       (cond
                        ((>= index (reader-bytevector-length value))
                         (emit! ")")
                         (loop rest))
                        ((and length-limit (>= index length-limit))
                         (if (not first?) (emit! " "))
                         (emit! marker)
                         (emit! ")")
                         (loop rest))
                        (else
                         (if (not first?) (emit! " "))
                         (emit!
                          (consent-integer->radix-string
                           (reader-bytevector-u8-ref value index)
                           10))
                         (loop
                          (cons
                           (vector 'bytevector value (+ index 1) #f)
                           rest)))))))))))

        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (render datum)
           (join (reverse parts) ""))
         (lambda ()
           (reader-identity-map-release! ancestors)))))))
