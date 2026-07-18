;;; consent-reader.el --- R7RS datum reader  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; A small, direct R7RS datum reader for Consent Scheme.  This module does not
;; delegate lexical syntax to Emacs `read'; it returns implementation datums
;; that keep Scheme booleans, symbols, characters, and bytevectors distinct
;; from their Emacs Lisp host representations.

;;; Code:

(require 'cl-lib)

(defgroup consent nil
  "Consent Scheme runtime."
  :group 'languages)

(defcustom consent-reader-maximum-depth 256
  "Maximum compound datum nesting depth accepted by the reader."
  :type 'integer
  :group 'consent)

(defcustom consent-reader-maximum-list-length 100000
  "Maximum list length accepted by the reader."
  :type 'integer
  :group 'consent)

(defcustom consent-reader-maximum-vector-length 100000
  "Maximum vector length accepted by the reader."
  :type 'integer
  :group 'consent)

(defcustom consent-reader-maximum-bytevector-length 100000
  "Maximum bytevector length accepted by the reader."
  :type 'integer
  :group 'consent)

(defcustom consent-reader-maximum-string-size 1048576
  "Maximum string size accepted by the reader."
  :type 'integer
  :group 'consent)

(defcustom consent-reader-maximum-total-nodes 1000000
  "Maximum total datum nodes accepted by the reader."
  :type 'integer
  :group 'consent)

(define-error 'consent-reader-error
  "Consent Scheme reader error")

(define-error 'consent-datum-limit-error
  "Consent Scheme datum resource limit exceeded"
  'consent-reader-error)

(define-error 'consent--reader-recovery-condition
  "Consent Scheme reader recovery condition")

(cl-defstruct (consent--reader-condition
               (:constructor consent--make-reader-condition)
               (:copier nil))
  "Structured reader failure raised only in recovery mode.
KIND is `invalid' (genuine syntax error), `incomplete' (a valid prefix
needing more input, such as an unterminated list at end of input), or
`limit' (a resource budget was exceeded).  OFFSET is the failure position
and MESSAGE is the human-readable reason without the offset prefix.
PENDING snapshots the reader's open-construct stack at the raise,
innermost first; it is meaningful for `incomplete' conditions."
  kind offset message pending)

(cl-defstruct (consent-recovery-result
               (:constructor consent--make-recovery-result
                             (datums diagnostics spans status))
               (:copier nil))
  "Recovery read result for a whole source.
DATUMS is the partial list of successfully read datums; DIAGNOSTICS and
SPANS are the ordered Scheme-readable records collected along the way;
STATUS is `complete' when the source was fully consumed or `incomplete'
when the trailing region is a valid prefix awaiting more input."
  datums diagnostics spans status)

(cl-defstruct (consent-recovery-step
               (:constructor consent--make-recovery-step
                             (status datum diagnostic span next
                                     &optional pending))
               (:copier nil))
  "Recovery read step for a single form.
Interactive callers drive one form at a time.  STATUS is `datum',
`invalid', `incomplete', or `eof'; NEXT is the offset to resume from.
PENDING carries the open-construct stack for an `incomplete' step,
innermost first (and nil otherwise), so a continuation prompt can render
nesting depth without re-deriving the reader's lexical state."
  status datum diagnostic span next pending)

(cl-defstruct (consent-boolean
               (:constructor consent--make-boolean (value))
               (:copier nil))
  "Scheme boolean datum."
  value)

(defconst consent-true
  (consent--make-boolean t)
  "Scheme true boolean datum.")

(defconst consent-false
  (consent--make-boolean nil)
  "Scheme false boolean datum.")

(cl-defstruct (consent-symbol
               (:constructor consent--make-symbol (name))
               (:copier nil))
  "Scheme symbol datum."
  name)

(cl-defstruct (consent-character
               (:constructor consent--make-character (code))
               (:copier nil))
  "Scheme character datum."
  code)

(cl-defstruct (consent-number
               (:constructor consent--make-number
                             (lexeme exactness radix kind value))
               (:copier nil))
  "Scheme number datum.

LEXEME preserves the source spelling.  EXACTNESS is `exact',
`inexact', or nil when unspecified.  RADIX is 2, 8, 10, or 16.
KIND names the parsed shape, such as `integer', `decimal',
`rational', `complex', or `infnan'."
  lexeme exactness radix kind value)

(cl-defstruct (consent-bytevector
               (:constructor consent--make-bytevector (bytes))
               (:copier nil))
  "Scheme bytevector datum."
  bytes)

(cl-defstruct (consent-record-type
               (:constructor consent--make-record-type
                             (name fields))
               (:copier nil))
  "Scheme record type descriptor datum."
  name fields)

(cl-defstruct (consent-record
               (:constructor consent--make-record (type fields))
               (:copier nil))
  "Scheme record datum."
  type fields)

(cl-defstruct (consent-handle
               (:constructor consent--make-handle (kind id))
               (:copier nil))
  "Opaque Scheme-visible handle for a host adapter object.
KIND is a symbol naming the adapter object family, and ID is a printable
string key into a private host-side registry.  The live host object itself is
never stored in the Scheme value."
  kind id)

(cl-defstruct (consent--datum-label
               (:constructor consent--make-datum-label (id))
               (:copier nil))
  "Placeholder for one R7RS datum label while reading."
  id filled value)

(cl-defstruct (consent--reader
               (:constructor consent--make-reader))
  "Mutable state for one reader pass.
SOURCE is an immutable input snapshot, while POSITION, FOLD-CASE,
NODE-COUNT, and DATUM-LABELS change as lexical directives,
comments, and datums are consumed.  The remaining slots are
per-run resource limits."
  source
  (position 0)
  length
  line-starts
  fold-case
  (node-count 0)
  datum-labels
  maximum-depth
  maximum-list-length
  maximum-vector-length
  maximum-bytevector-length
  maximum-string-size
  maximum-total-nodes
  symbol-table
  source-id
  source-metadata
  ;; RECOVERY toggles errors-as-data: when non-nil, reader errors signal a
  ;; structured `consent--reader-condition' the recovery driver resynchronizes
  ;; past instead of unwinding the whole read.
  recovery
  ;; PENDING-STACK tracks the constructs currently open at the cursor,
  ;; innermost first (`list', `vector', `bytevector', `string', `symbol',
  ;; `comment').  An incomplete condition snapshots it so interactive callers
  ;; can render nesting depth and the pending construct kind.
  (pending-stack nil))

(defvar consent--symbol-table (make-hash-table :test #'equal)
  "Default process intern table for Scheme symbol datums.")

(defvar consent--active-symbol-table nil
  "Dynamically active explicit reader symbol table, or nil for the default.")

(defvar consent--datum-source-table
  (make-hash-table :test #'eq :weakness 'key)
  "Identity table from syntax datums to Scheme-readable source records.")

(defconst consent--read-eof (make-symbol "consent-read-eof")
  "Private marker returned by incremental reader helpers at end of input.")

(defconst consent--character-names
  '(("alarm" . 7)
    ("backspace" . 8)
    ("delete" . 127)
    ("escape" . 27)
    ("newline" . 10)
    ("null" . 0)
    ("return" . 13)
    ("space" . 32)
    ("tab" . 9))
  "R7RS named character mapping.")

(defun consent--make-symbol-table ()
  "Return a fresh hash-backed Scheme symbol-table handle."
  (make-hash-table :test #'equal))

(defun consent--intern-symbol (name &optional table)
  "Return NAME's Scheme symbol from TABLE or the active/default table."
  (let ((table (or table consent--active-symbol-table consent--symbol-table)))
    (unless (hash-table-p table)
      (signal 'wrong-type-argument (list 'hash-table-p table)))
    (or (gethash name table)
        (let ((owned-name (copy-sequence name)))
          (puthash owned-name
                   (consent--make-symbol owned-name)
                   table)))))

(defun consent--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun consent--source-string (source)
  "Return SOURCE as a string."
  (cond
   ((stringp source) source)
   ((bufferp source)
    (with-current-buffer source
      (buffer-substring-no-properties (point-min) (point-max))))
   (t
    (signal 'wrong-type-argument (list 'string-or-buffer-p source)))))

(defun consent--source-id (source options)
  "Return a Scheme-readable source identifier for SOURCE and OPTIONS."
  (or (consent--option options :source-id nil)
      (and (bufferp source)
           (buffer-name source))))

(defun consent--source-line-starts (source)
  "Return a vector of zero-based offsets where each line in SOURCE starts."
  (let ((starts '(0))
        (index 0)
        (length (length source)))
    (while (< index length)
      (when (and (= (aref source index) ?\n)
                 (< (1+ index) length))
        (push (1+ index) starts))
      (setq index (1+ index)))
    (vconcat (nreverse starts))))

(defun consent--new-reader (source options)
  "Return a reader state over SOURCE using OPTIONS."
  (let* ((text (consent--source-string source))
         (source-metadata
          (consent--option options :source-metadata t)))
    (consent--make-reader
     :source text
     :length (length text)
     :line-starts (and source-metadata
                       (consent--source-line-starts text))
     :datum-labels (make-hash-table :test #'equal)
     :maximum-depth
     (consent--option options :max-depth
                           consent-reader-maximum-depth)
     :maximum-list-length
     (consent--option options :max-list-length
                           consent-reader-maximum-list-length)
     :maximum-vector-length
     (consent--option options :max-vector-length
                           consent-reader-maximum-vector-length)
     :maximum-bytevector-length
     (consent--option options :max-bytevector-length
                           consent-reader-maximum-bytevector-length)
     :maximum-string-size
     (consent--option options :max-string-size
                           consent-reader-maximum-string-size)
     :maximum-total-nodes
     (consent--option options :max-total-nodes
                           consent-reader-maximum-total-nodes)
     :symbol-table
     (consent--option options :symbol-table consent--symbol-table)
     :source-id
     (and source-metadata
          (consent--source-id source options))
     :source-metadata source-metadata
     :recovery (consent--option options :recovery nil))))

(defun consent--source-field (name value)
  "Return a source metadata field named NAME with VALUE."
  (list (consent--intern-symbol name) value))

(defun consent--line-starts-line-column (starts offset)
  "Return one-based (LINE . COLUMN) from STARTS at OFFSET."
  (let* ((low 0)
         (high (1- (length starts)))
         (best 0))
    (while (<= low high)
      (let* ((middle (/ (+ low high) 2))
             (line-start (aref starts middle)))
        (if (<= line-start offset)
            (setq best middle
                  low (1+ middle))
          (setq high (1- middle)))))
    (let ((line-start (aref starts best)))
      (cons (1+ best)
            (1+ (- offset line-start))))))

(defun consent--reader-line-column (reader offset)
  "Return one-based (LINE . COLUMN) in READER at OFFSET."
  (consent--line-starts-line-column
   (consent--reader-line-starts reader)
   offset))

(defun consent--source-note (reader start end)
  "Return compact source metadata for READER between START and END."
  (let ((line-column (consent--reader-line-column reader start)))
    (vector 'consent--source-note
            (consent--reader-source-id reader)
            (car line-column)
            (cdr line-column)
            start
            (max 0 (- end start)))))

(defun consent--source-note-p (metadata)
  "Return non-nil when METADATA is a compact source note."
  (and (vectorp metadata)
       (= (length metadata) 6)
       (eq (aref metadata 0) 'consent--source-note)))

(defun consent--source-metadata-record (metadata)
  "Return a Scheme-readable source record for METADATA."
  (if (consent--source-note-p metadata)
      (list
       (consent--intern-symbol "source")
       (consent--source-field "origin"
                                   (consent--intern-symbol "source"))
       (consent--source-field "source-id"
                                   (or (aref metadata 1) consent-false))
       (consent--source-field
        "line" (consent--make-canonical-integer (aref metadata 2)))
       (consent--source-field
        "column" (consent--make-canonical-integer (aref metadata 3)))
       (consent--source-field
        "offset" (consent--make-canonical-integer (aref metadata 4)))
       (consent--source-field
        "span" (consent--make-canonical-integer (aref metadata 5)))
       (consent--source-field "phase"
                                   (consent--intern-symbol "read")))
    metadata))

(defun consent--source-attachable-p (datum)
  "Return non-nil if DATUM can carry identity-based source metadata."
  (or (consp datum)
      (vectorp datum)
      (stringp datum)
      (consent-number-p datum)
      (consent-character-p datum)
      (consent-bytevector-p datum)
      (consent-record-p datum)
      (consent-record-type-p datum)
      (consent-handle-p datum)))

(defun consent--set-datum-source (datum source)
  "Attach SOURCE metadata to DATUM when DATUM has stable identity."
  (when (and source (consent--source-attachable-p datum))
    (puthash datum source consent--datum-source-table))
  datum)

(defun consent-datum-source (datum)
  "Return source metadata attached to DATUM, or `consent-false'."
  (let ((metadata (gethash datum consent--datum-source-table)))
    (if metadata
        (consent--source-metadata-record metadata)
      consent-false)))

(defun consent--datum-source-metadata (datum)
  "Return raw source metadata attached to DATUM, or nil when absent."
  (gethash datum consent--datum-source-table))

(defun consent--copy-datum-source (target source &optional overwrite)
  "Copy source metadata from SOURCE to TARGET.
When OVERWRITE is nil, keep TARGET's existing source metadata."
  (let ((metadata (consent--datum-source-metadata source)))
    (when (and metadata
               (or overwrite
                   (not (consent--datum-source-metadata target))))
      (consent--set-datum-source target metadata)))
  target)

(defun consent--reader-pending-push (reader kind)
  "Mark a KIND construct open at READER's cursor for nesting snapshots."
  (push kind (consent--reader-pending-stack reader)))

(defun consent--reader-pending-pop (reader)
  "Mark READER's innermost open construct closed after its delimiter."
  (pop (consent--reader-pending-stack reader)))

(defun consent--raise-reader-condition (reader kind error-symbol formatted)
  "Raise a reader failure of KIND for READER.
In recovery mode this signals a structured `consent--reader-condition' the
recovery driver can resynchronize past; otherwise it signals ERROR-SYMBOL
with the historical offset-prefixed FORMATTED message."
  (if (consent--reader-recovery reader)
      (signal 'consent--reader-recovery-condition
              (list (consent--make-reader-condition
                     :kind kind
                     :offset (consent--reader-position reader)
                     :message formatted
                     :pending (consent--reader-pending-stack reader))))
    (signal error-symbol
            (list (format "at offset %d: %s"
                          (consent--reader-position reader)
                          formatted)))))

(defun consent--reader-error (reader message &rest args)
  "Signal a reader syntax error at READER's current position.
MESSAGE and ARGS are passed to `format'."
  (consent--raise-reader-condition
   reader 'invalid 'consent-reader-error
   (apply #'format message args)))

(defun consent--reader-incomplete (reader message &rest args)
  "Signal a reader failure for a valid prefix that needs more input.
The default error text is identical to `consent--reader-error'; only
recovery mode tells the two apart.  MESSAGE and ARGS are passed to `format'."
  (consent--raise-reader-condition
   reader 'incomplete 'consent-reader-error
   (apply #'format message args)))

(defun consent--limit-error (reader message &rest args)
  "Signal a datum resource limit error for READER.
MESSAGE and ARGS are passed to `format'."
  (consent--raise-reader-condition
   reader 'limit 'consent-datum-limit-error
   (apply #'format message args)))

(defun consent--check-depth (reader depth)
  "Signal if DEPTH exceeds READER's maximum depth."
  (when (> depth (consent--reader-maximum-depth reader))
    (consent--limit-error
     reader
     "datum depth %d exceeds maximum depth %d"
     depth
     (consent--reader-maximum-depth reader))))

(defun consent--note-node (reader)
  "Record one parsed datum node in READER."
  (cl-incf (consent--reader-node-count reader))
  (when (> (consent--reader-node-count reader)
           (consent--reader-maximum-total-nodes reader))
    (consent--limit-error
     reader
     "datum node count exceeds maximum total nodes %d"
     (consent--reader-maximum-total-nodes reader))))

(defun consent--eof-p (reader)
  "Return non-nil when READER is at end of input."
  (>= (consent--reader-position reader)
      (consent--reader-length reader)))

(defun consent--peek (reader &optional offset)
  "Return READER character at OFFSET from point, or nil at EOF."
  (let ((index (+ (consent--reader-position reader) (or offset 0))))
    (when (< index (consent--reader-length reader))
      (aref (consent--reader-source reader) index))))

(defun consent--advance (reader &optional count)
  "Advance READER by COUNT characters."
  (setf (consent--reader-position reader)
        (+ (consent--reader-position reader) (or count 1))))

(defun consent--starts-with-p (reader text)
  "Return non-nil if READER input at point starts with TEXT."
  (let ((position (consent--reader-position reader))
        (end (+ (consent--reader-position reader) (length text))))
    (and (<= end (consent--reader-length reader))
         (string= text
                  (substring (consent--reader-source reader)
                             position end)))))

(defun consent--whitespace-char-p (char)
  "Return non-nil if CHAR is R7RS intertoken whitespace."
  (memq char '(?\s ?\t ?\n ?\r ?\f)))

(defun consent--intraline-whitespace-p (char)
  "Return non-nil if CHAR is space or tab."
  (memq char '(?\s ?\t)))

(defun consent--delimiter-p (char)
  "Return non-nil if CHAR is an R7RS token delimiter."
  (or (null char)
      (consent--whitespace-char-p char)
      (memq char '(?\| ?\( ?\) ?\" ?\;))))

(defun consent--reserved-char-p (char)
  "Return non-nil if CHAR is reserved by R7RS."
  (memq char '(?\[ ?\] ?\{ ?\})))

(defun consent--skip-line-comment (reader)
  "Skip a semicolon line comment in READER."
  (while (and (not (consent--eof-p reader))
              (not (memq (consent--peek reader) '(?\n ?\r))))
    (consent--advance reader))
  (when (eq (consent--peek reader) ?\r)
    (consent--advance reader)
    (when (eq (consent--peek reader) ?\n)
      (consent--advance reader)))
  (when (eq (consent--peek reader) ?\n)
    (consent--advance reader)))

(defun consent--skip-nested-comment (reader)
  "Skip one nested block comment in READER."
  (let ((depth 0))
    (while (or (> depth 0)
               (consent--starts-with-p reader "#|"))
      (cond
       ((consent--eof-p reader)
        (consent--reader-incomplete reader "unterminated block comment"))
       ((consent--starts-with-p reader "#|")
        (cl-incf depth)
        (consent--advance reader 2)
        (consent--reader-pending-push reader 'comment))
       ((consent--starts-with-p reader "|#")
        (cl-decf depth)
        (consent--advance reader 2)
        (consent--reader-pending-pop reader))
       (t
        (consent--advance reader))))))

(defun consent--skip-directive (reader)
  "Skip and apply one reader directive in READER."
  (cond
   ((and (consent--starts-with-p reader "#!fold-case")
         (consent--delimiter-p (consent--peek reader 11)))
    (setf (consent--reader-fold-case reader) t)
    (consent--advance reader 11))
   ((and (consent--starts-with-p reader "#!no-fold-case")
         (consent--delimiter-p (consent--peek reader 14)))
    (setf (consent--reader-fold-case reader) nil)
    (consent--advance reader 14))
   (t
    (consent--reader-error reader "unknown reader directive"))))

(defun consent--skip-intertoken-space (reader depth)
  "Skip whitespace, comments, directives, and datum comments in READER.
DEPTH is used when reading a datum comment's discarded datum."
  (let ((again t))
    (while again
      (setq again nil)
      (while (consent--whitespace-char-p (consent--peek reader))
        (setq again t)
        (consent--advance reader))
      (cond
       ((eq (consent--peek reader) ?\;)
        (setq again t)
        (consent--skip-line-comment reader))
       ((consent--starts-with-p reader "#|")
        (setq again t)
        (consent--skip-nested-comment reader))
       ((consent--starts-with-p reader "#!")
        (setq again t)
        (consent--skip-directive reader))
       ((consent--starts-with-p reader "#;")
        (setq again t)
        (consent--advance reader 2)
        ;; R7RS datum comments consume a complete datum, not just the next
        ;; token, so the recursive read must share the current reader state.
        (consent--skip-intertoken-space reader depth)
        (consent--read-datum reader depth))))))

(defun consent--read-token (reader)
  "Read one non-delimited token from READER."
  (let ((start (consent--reader-position reader)))
    (while (not (consent--delimiter-p (consent--peek reader)))
      (when (consent--reserved-char-p (consent--peek reader))
        (consent--reader-error
         reader "reserved character %c in token" (consent--peek reader)))
      (consent--advance reader))
    (substring (consent--reader-source reader)
               start
               (consent--reader-position reader))))

(defun consent--hex-scalar-to-char (reader digits)
  "Return character code for hexadecimal scalar DIGITS."
  (unless (string-match-p "\\`[[:xdigit:]]+\\'" digits)
    (consent--reader-error reader "invalid hexadecimal scalar escape"))
  (let ((code (string-to-number digits 16)))
    (when (or (> code #x10ffff)
              (and (>= code #xd800) (<= code #xdfff)))
      (consent--reader-error
       reader "invalid Unicode scalar value #x%x" code))
    code))

(defun consent--read-hex-escape (reader)
  "Read a `\\x...;' escape body from READER after the x."
  (let ((start (consent--reader-position reader)))
    (while (and (not (consent--eof-p reader))
                (not (eq (consent--peek reader) ?\;)))
      (consent--advance reader))
    (when (consent--eof-p reader)
      (consent--reader-incomplete reader "unterminated hexadecimal escape"))
    (let ((digits (substring (consent--reader-source reader)
                             start
                             (consent--reader-position reader))))
      (consent--advance reader)
      (consent--hex-scalar-to-char reader digits))))

(defun consent--mnemonic-escape (reader char)
  "Return character code for mnemonic escape CHAR."
  (pcase char
    (?a 7)
    (?b 8)
    (?t 9)
    (?n 10)
    (?r 13)
    (?\" ?\")
    (?\\ ?\\)
    (?| ?|)
    (_ (consent--reader-error
        reader "unknown escape sequence \\%c" char))))

(defun consent--read-string (reader)
  "Read a string datum from READER."
  (consent--advance reader)
  (consent--reader-pending-push reader 'string)
  (let ((result nil)
        (size 0))
    (cl-labels
        ((emit
          (char)
          (cl-incf size)
          (when (> size (consent--reader-maximum-string-size reader))
            (consent--limit-error
             reader
             "string size exceeds maximum string size %d"
             (consent--reader-maximum-string-size reader)))
          (push char result))
         (skip-line-continuation
          ()
          (while (consent--intraline-whitespace-p
                  (consent--peek reader))
            (consent--advance reader))
          (cond
           ((eq (consent--peek reader) ?\r)
            (consent--advance reader)
            (when (eq (consent--peek reader) ?\n)
              (consent--advance reader)))
           ((eq (consent--peek reader) ?\n)
            (consent--advance reader))
           (t
            (consent--reader-incomplete
             reader "expected line ending in string continuation")))
          (while (consent--intraline-whitespace-p
                  (consent--peek reader))
            (consent--advance reader))))
      (while (not (eq (consent--peek reader) ?\"))
        (when (consent--eof-p reader)
          (consent--reader-incomplete reader "unterminated string"))
        (let ((char (consent--peek reader)))
          (cond
           ((eq char ?\\)
            (consent--advance reader)
            (let ((escaped (consent--peek reader)))
              (cond
               ((eq escaped ?x)
                (consent--advance reader)
                (emit (consent--read-hex-escape reader)))
               ((consent--intraline-whitespace-p escaped)
                (skip-line-continuation))
               ((memq escaped '(?\n ?\r))
                (skip-line-continuation))
               (t
                (consent--advance reader)
                (emit (consent--mnemonic-escape reader escaped))))))
           (t
            (consent--advance reader)
            (emit char)))))
      (consent--advance reader)
      (consent--reader-pending-pop reader)
      (apply #'string (nreverse result)))))

(defun consent--read-vertical-symbol-name (reader)
  "Read a vertical-bar symbol name from READER."
  (consent--advance reader)
  (consent--reader-pending-push reader 'symbol)
  (let (result)
    (while (not (eq (consent--peek reader) ?|))
      (when (consent--eof-p reader)
        (consent--reader-incomplete reader "unterminated vertical symbol"))
      (let ((char (consent--peek reader)))
        (cond
         ((eq char ?\\)
          (consent--advance reader)
          (let ((escaped (consent--peek reader)))
            (cond
             ((eq escaped ?x)
              (consent--advance reader)
              (push (consent--read-hex-escape reader) result))
             (t
              (consent--advance reader)
              (push (consent--mnemonic-escape reader escaped) result)))))
         (t
          (consent--advance reader)
          (push char result)))))
    (consent--advance reader)
    (consent--reader-pending-pop reader)
    (let ((name (apply #'string (nreverse result))))
      (if (consent--reader-fold-case reader)
          (downcase name)
        name))))

(defun consent--char-in-string-p (char string)
  "Return non-nil if CHAR appears in STRING."
  (and char (not (null (cl-position char string)))))

(defun consent--ascii-letter-p (char)
  "Return non-nil if CHAR is an ASCII letter."
  (or (and (>= char ?a) (<= char ?z))
      (and (>= char ?A) (<= char ?Z))))

(defun consent--digit-value (char)
  "Return digit value of CHAR, or nil."
  (cond
   ((and (>= char ?0) (<= char ?9)) (- char ?0))
   ((and (>= char ?a) (<= char ?f)) (+ 10 (- char ?a)))
   ((and (>= char ?A) (<= char ?F)) (+ 10 (- char ?A)))
   (t nil)))

(defun consent--integer-gcd (left right)
  "Return the non-negative greatest common divisor of LEFT and RIGHT."
  (setq left (abs left))
  (setq right (abs right))
  (while (not (zerop right))
    (let ((next (% left right)))
      (setq left right)
      (setq right next)))
  left)

(defun consent--integer-power (base exponent)
  "Return BASE raised to non-negative integer EXPONENT."
  (let ((result 1)
        (factor base)
        (power exponent))
    (while (> power 0)
      (when (= (% power 2) 1)
        (setq result (* result factor)))
      (setq factor (* factor factor))
      (setq power (/ power 2)))
    result))

(defun consent--normalize-rational-pair (numerator denominator)
  "Return normalized rational pair for NUMERATOR and DENOMINATOR."
  (when (zerop denominator)
    (error "zero denominator"))
  (when (< denominator 0)
    (setq numerator (- numerator))
    (setq denominator (- denominator)))
  (let ((divisor (consent--integer-gcd numerator denominator)))
    (cons (/ numerator divisor) (/ denominator divisor))))

(defun consent--make-canonical-integer (value &optional exactness radix)
  "Return a canonical integer number datum for VALUE."
  (let ((exactness (or exactness 'exact))
        (radix (or radix 10)))
    (consent--make-number
     (number-to-string value) exactness radix 'integer value)))

(defun consent--host-inexact-special-kind (value)
  "Return Consent Scheme's special inexact kind for host VALUE, or nil."
  (let ((text (number-to-string value)))
    (cond
     ((string-match-p "NaN" text) '+nan.0)
     ((string-match-p "INF" text)
      (if (string-prefix-p "-" text) '-inf.0 '+inf.0))
     (t nil))))

(defun consent--make-canonical-decimal (value &optional lexeme)
  "Return an inexact decimal number datum for VALUE."
  (let ((special-kind (consent--host-inexact-special-kind value)))
    (if special-kind
        (consent--make-canonical-infnan special-kind)
      (consent--make-number
       (or lexeme (number-to-string value)) 'inexact 10 'decimal value))))

(defun consent--make-canonical-rational
    (numerator denominator &optional exactness radix)
  "Return a normalized rational or integer datum."
  (let* ((pair (consent--normalize-rational-pair numerator denominator))
         (numerator (car pair))
         (denominator (cdr pair))
         (exactness (or exactness 'exact))
         (radix (or radix 10)))
    (if (= denominator 1)
        (consent--make-canonical-integer numerator exactness radix)
      (consent--make-number
       (format "%s/%s" numerator denominator)
       exactness
       radix
       'rational
       pair))))

(defun consent--make-canonical-infnan (kind)
  "Return an inexact infinity or NaN datum for KIND."
  (consent--make-number
   (pcase kind
     ('+inf.0 "+inf.0")
     ('-inf.0 "-inf.0")
     ('+nan.0 "+nan.0")
     (_ (error "unknown inexact special number: %S" kind)))
   'inexact 10 'infnan kind))

(defun consent--make-canonical-complex (real imaginary)
  "Return a complex number datum from REAL and IMAGINARY number datums."
  (let ((exactness (if (and (eq (consent-number-exactness real) 'exact)
                            (eq (consent-number-exactness imaginary)
                                'exact))
                       'exact
                     'inexact)))
    (consent--make-number nil exactness 10 'complex (cons real imaginary))))

(defun consent--number-zero-p (number)
  "Return non-nil if NUMBER is numerically zero."
  (and (consent-number-p number)
       (pcase (consent-number-kind number)
         ('integer (zerop (consent-number-value number)))
         ('rational (zerop (car (consent-number-value number))))
         ('decimal (zerop (consent-number-value number)))
         ('complex
          (and (consent--number-zero-p
                (car (consent-number-value number)))
               (consent--number-zero-p
                (cdr (consent-number-value number)))))
         (_ nil))))

(defun consent--number-negative-p (number)
  "Return non-nil if real NUMBER is negative."
  (pcase (consent-number-kind number)
    ('integer (< (consent-number-value number) 0))
    ('rational (< (car (consent-number-value number)) 0))
    ('decimal (< (consent-number-value number) 0))
    ('infnan (eq (consent-number-value number) '-inf.0))
    (_ nil)))

(defun consent--number-abs (number)
  "Return the absolute value of real NUMBER."
  (pcase (consent-number-kind number)
    ('integer
     (consent--make-canonical-integer
      (abs (consent-number-value number))
      (consent-number-exactness number)
      (consent-number-radix number)))
    ('rational
     (let ((value (consent-number-value number)))
       (consent--make-canonical-rational
        (abs (car value)) (cdr value)
        (consent-number-exactness number)
        (consent-number-radix number))))
    ('decimal
     (consent--make-canonical-decimal
      (abs (consent-number-value number))))
    ('infnan
     (pcase (consent-number-value number)
       ('-inf.0 (consent--make-canonical-infnan '+inf.0))
       (_ number)))
    (_ number)))

(defun consent--number->external (number)
  "Return canonical external representation for NUMBER.
NUMBER may be a reader-owned canonical number datum or a plain Emacs number."
  (cond
   ((numberp number)
    (let ((special-kind (and (floatp number)
                             (consent--host-inexact-special-kind number))))
      (if special-kind
          (pcase special-kind
            ('+inf.0 "+inf.0")
            ('-inf.0 "-inf.0")
            ('+nan.0 "+nan.0"))
        (let ((text (number-to-string number)))
          (if (and (floatp number)
                   (string-match-p "\\`[+-]?[0-9]+\\'" text))
              (concat text ".0")
            text)))))
   ((consent-number-p number)
    (pcase (consent-number-kind number)
      ('integer
       (number-to-string (consent-number-value number)))
      ('rational
       (let ((value (consent-number-value number)))
         (format "%s/%s" (car value) (cdr value))))
      ('decimal
       (let ((text (number-to-string (consent-number-value number))))
         (if (string-match-p "\\`[+-]?[0-9]+\\'" text)
             (concat text ".0")
           text)))
      ('infnan
       (pcase (consent-number-value number)
         ('+inf.0 "+inf.0")
         ('-inf.0 "-inf.0")
         ('+nan.0 "+nan.0")))
      ('complex
       (let* ((value (consent-number-value number))
              (real (car value))
              (imaginary (cdr value)))
         (concat
          (consent--number->external real)
          (if (eq (consent-number-kind imaginary) 'infnan)
              (consent--number->external imaginary)
            (let ((negative (consent--number-negative-p imaginary))
                  (magnitude (consent--number-abs imaginary)))
              (concat
               (if negative "-" "+")
               (consent--number->external magnitude))))
          "i")))
      (_
       (or (consent-number-lexeme number)
           (error "cannot write unknown number kind: %S"
                  (consent-number-kind number))))))
   (t
    (error "cannot write non-numeric value as a number: %S" number))))

(defun consent--initial-char-p (char)
  "Return non-nil if CHAR can begin an ordinary identifier."
  (or (consent--ascii-letter-p char)
      (> char 127)
      (consent--char-in-string-p char "!$%&*/:<=>?@^_~")))

(defun consent--subsequent-char-p (char)
  "Return non-nil if CHAR can continue an identifier."
  (or (consent--initial-char-p char)
      (and (>= char ?0) (<= char ?9))
      (consent--char-in-string-p char "+-.@")))

(defun consent--sign-subsequent-char-p (char)
  "Return non-nil if CHAR can follow an identifier sign."
  (or (consent--initial-char-p char)
      (consent--char-in-string-p char "+-@")))

(defun consent--dot-subsequent-char-p (char)
  "Return non-nil if CHAR can follow an identifier dot."
  (or (consent--sign-subsequent-char-p char)
      (eq char ?.)))

(defun consent--all-chars-p (string start predicate)
  "Return non-nil if all STRING chars from START satisfy PREDICATE."
  (let ((index start)
        (ok t))
    (while (and ok (< index (length string)))
      (setq ok (funcall predicate (aref string index)))
      (cl-incf index))
    ok))

(defun consent--identifier-token-p (token)
  "Return non-nil if TOKEN is an R7RS identifier token."
  (let ((length (length token)))
    (cond
     ((= length 0) nil)
     ((string= token ".") nil)
     ((member token '("+" "-")) t)
     ((consent--initial-char-p (aref token 0))
      (consent--all-chars-p
       token 1 #'consent--subsequent-char-p))
     ((and (memq (aref token 0) '(?+ ?-))
           (> length 1)
           (consent--sign-subsequent-char-p (aref token 1)))
      (consent--all-chars-p
       token 2 #'consent--subsequent-char-p))
     ((and (memq (aref token 0) '(?+ ?-))
           (> length 2)
           (eq (aref token 1) ?.)
           (consent--dot-subsequent-char-p (aref token 2)))
      (consent--all-chars-p
       token 3 #'consent--subsequent-char-p))
     ((and (eq (aref token 0) ?.)
           (> length 1)
           (consent--dot-subsequent-char-p (aref token 1)))
      (consent--all-chars-p
       token 2 #'consent--subsequent-char-p))
     (t nil))))

(defun consent--parse-unsigned-integer (digits radix)
  "Parse DIGITS in RADIX, or return nil when invalid."
  (when (> (length digits) 0)
    (let ((value 0)
          (index 0)
          (ok t))
      (while (and ok (< index (length digits)))
        (let ((digit (consent--digit-value (aref digits index))))
          (if (and digit (< digit radix))
              (setq value (+ (* value radix) digit))
            (setq ok nil)))
        (cl-incf index))
      (when ok value))))

(defun consent--parse-signed-integer (body radix)
  "Parse signed integer BODY in RADIX, or return nil."
  (let ((sign 1))
    (when (and (> (length body) 0) (memq (aref body 0) '(?+ ?-)))
      (when (eq (aref body 0) ?-)
        (setq sign -1))
      (setq body (substring body 1)))
    (let ((value (consent--parse-unsigned-integer body radix)))
      (when value (* sign value)))))

(defun consent--number-prefix (reader token)
  "Return parsed number prefix data for TOKEN.
The return value is (BODY EXACTNESS RADIX), or nil."
  (let ((index 0)
        (exactness nil)
        (radix 10)
        (seen-exactness nil)
        (seen-radix nil)
        (lower (downcase token))
        valid)
    (while (and (<= (+ index 2) (length lower))
                (eq (aref lower index) ?#))
      (let ((marker (aref lower (1+ index))))
        (pcase marker
          ((or ?e ?i)
           (when seen-exactness
             (consent--reader-error
              reader "duplicate exactness prefix in number %s" token))
           (setq seen-exactness t)
           (setq exactness (if (eq marker ?e) 'exact 'inexact)))
          (?b
           (when seen-radix
             (consent--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 2))
          (?o
           (when seen-radix
             (consent--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 8))
          (?d
           (when seen-radix
             (consent--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 10))
          (?x
           (when seen-radix
             (consent--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 16))
          (_
           (setq valid nil)
           (setq index (length lower)))))
      (when (< index (length lower))
        (setq valid t)
        (setq index (+ index 2))))
    (when (or valid (not (string-prefix-p "#" token)))
      (list (substring token index) exactness radix))))

(defun consent--decimal-token-p (body)
  "Return non-nil if BODY is a decimal number token."
  (string-match-p
   "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][+-]?[0-9]+\\)?\\'"
   body))

(defun consent--parse-exact-decimal (body)
  "Return exact rational components for decimal BODY, or nil."
  (when (string-match
         "\\`\\([+-]?\\)\\([0-9]*\\)\\(?:\\.\\([0-9]*\\)\\)?\\(?:[eE]\\([+-]?[0-9]+\\)\\)?\\'"
         body)
    (let* ((sign (if (string= (match-string 1 body) "-") -1 1))
           (whole (or (match-string 2 body) ""))
           (fraction (or (match-string 3 body) ""))
           (exponent-text (match-string 4 body))
           (exponent (if exponent-text (string-to-number exponent-text) 0))
           (digits (concat whole fraction)))
      (when (and (> (length digits) 0)
                 (string-match-p "[0-9]" digits))
        (let* ((integer (or (consent--parse-unsigned-integer digits 10)
                            0))
               (scale (- exponent (length fraction))))
          (if (>= scale 0)
              (cons (* sign integer (consent--integer-power 10 scale)) 1)
            (cons (* sign integer)
                  (consent--integer-power 10 (- scale)))))))))

(defun consent--parse-real-number-body
    (reader token body exactness radix)
  "Parse real numeric BODY using TOKEN, EXACTNESS, and RADIX."
  (cond
   ((member (downcase body) '("+inf.0" "-inf.0" "+nan.0" "-nan.0"))
    (when (eq exactness 'exact)
      (consent--reader-error
       reader "infinite and NaN literals cannot be exact: %s" token))
    (consent--make-canonical-infnan
     (pcase (downcase body)
       ("+inf.0" '+inf.0)
       ("-inf.0" '-inf.0)
       (_ '+nan.0))))
   ((consent--parse-signed-integer body radix)
    (let ((value (consent--parse-signed-integer body radix)))
      (if (eq exactness 'inexact)
          (consent--make-canonical-decimal (float value))
        (consent--make-canonical-integer value 'exact radix))))
   ((and (string-match-p "\\`[+-]?[[:xdigit:]]+/[[:xdigit:]]+\\'" body)
         (let* ((parts (split-string body "/"))
                (denominator
                 (consent--parse-unsigned-integer (cadr parts) radix)))
           (and denominator (not (= denominator 0))
                (consent--parse-signed-integer (car parts) radix))))
    (let* ((parts (split-string body "/"))
           (numerator
            (consent--parse-signed-integer (car parts) radix))
           (denominator
            (consent--parse-unsigned-integer (cadr parts) radix)))
      (if (eq exactness 'inexact)
          (consent--make-canonical-decimal
           (/ (float numerator) denominator))
        (consent--make-canonical-rational
         numerator denominator 'exact radix))))
   ((and (= radix 10) (consent--decimal-token-p body))
    (if (eq exactness 'exact)
        (let ((value (consent--parse-exact-decimal body)))
          (consent--make-canonical-rational (car value) (cdr value)))
      (consent--make-canonical-decimal (string-to-number body) body)))
   ((string-match-p "\\`[+-]?[0-9A-Fa-f]+/[0-9A-Fa-f]+\\'" body)
    (consent--reader-error reader "invalid rational number %s" token))
   (t nil)))

(defun consent--number->reader-float (number)
  "Return NUMBER as a host float for reader-only polar conversion."
  (pcase (consent-number-kind number)
    ('integer (float (consent-number-value number)))
    ('rational
     (let ((value (consent-number-value number)))
       (/ (float (car value)) (cdr value))))
    ('decimal (consent-number-value number))
    ('infnan
     (pcase (consent-number-value number)
       ('+inf.0 (/ 1.0 0.0))
       ('-inf.0 (/ -1.0 0.0))
       ('+nan.0 (/ 0.0 0.0))))))

(defun consent--complex-split-index (body)
  "Return the rectangular complex split index in BODY, or nil."
  (let ((index 1)
        split)
    (while (< index (length body))
      (let ((char (aref body index))
            (previous (aref body (1- index))))
        (when (and (memq char '(?+ ?-))
                   (not (memq previous '(?e ?E))))
          (setq split index)))
      (cl-incf index))
    split))

(defun consent--parse-complex-number-body
    (reader token body exactness radix)
  "Parse complex numeric BODY using TOKEN, EXACTNESS, and RADIX."
  (let ((lower (downcase body)))
    (cond
     ((and (= radix 10) (string-suffix-p "i" lower))
      (let* ((rectangular (substring body 0 -1))
             (split (consent--complex-split-index rectangular))
             (real-body (if split (substring rectangular 0 split) "0"))
             (imaginary-body
              (if split
                  (substring rectangular split)
                rectangular)))
        (when (string= imaginary-body "")
          (setq imaginary-body nil))
        (when (member imaginary-body '("+" "-"))
          (setq imaginary-body
                (concat imaginary-body "1")))
        (when imaginary-body
          (let ((real
                 (consent--parse-real-number-body
                  reader token real-body exactness radix))
                (imaginary
                 (consent--parse-real-number-body
                  reader token imaginary-body exactness radix)))
            (when (and real imaginary)
              (consent--make-canonical-complex real imaginary))))))
     ((and (= radix 10) (string-match-p "@" body))
      (let* ((parts (split-string body "@"))
             (magnitude
              (and (= (length parts) 2)
                   (consent--parse-real-number-body
                    reader token (car parts) exactness radix)))
             (angle
              (and (= (length parts) 2)
                   (consent--parse-real-number-body
                    reader token (cadr parts) exactness radix))))
        (when (and magnitude angle)
          (let ((r (consent--number->reader-float magnitude))
                (theta (consent--number->reader-float angle)))
            (consent--make-canonical-complex
             (consent--make-canonical-decimal (* r (cos theta)))
             (consent--make-canonical-decimal (* r (sin theta))))))))
     (t nil))))

(defun consent--parse-number-token (reader token)
  "Return number datum for TOKEN, or nil if TOKEN is not a number."
  (let* ((prefix (consent--number-prefix reader token))
         (body (car prefix))
         (exactness (cadr prefix))
         (radix (or (caddr prefix) 10))
         (lower-body (and body (downcase body))))
    (when (and prefix (> (length body) 0))
      (or (consent--parse-real-number-body
           reader token body exactness radix)
          (consent--parse-complex-number-body
           reader token lower-body exactness radix)))))

(defun consent--character-name-start-p (char)
  "Report whether CHAR (an ASCII letter) can begin a named or #\\x hex literal."
  (and char
       (or (and (<= ?a char) (<= char ?z))
           (and (<= ?A char) (<= char ?Z)))))

(defun consent--read-character (reader)
  "Read a character datum from READER after `#\\'."
  (consent--advance reader 2)
  (when (consent--eof-p reader)
    (consent--reader-incomplete reader "missing character after #\\"))
  (let ((first (consent--peek reader)))
    (if (not (consent--character-name-start-p first))
        ;; Any non-letter first character — including delimiters and
        ;; bracket/pipe characters like #\( #\) #\[ #\] #\| — is taken
        ;; literally per the R7RS grammar #\<any character>.
        ;; `consent--read-token' would refuse these (delimiter or reserved),
        ;; so take it directly.
        (progn
          (consent--advance reader)
          (consent--make-character first))
      (let* ((token (consent--read-token reader))
             (name (if (consent--reader-fold-case reader)
                       (downcase token)
                     token))
             (code
              (cond
               ((and (> (length token) 1)
                     (memq (aref token 0) '(?x ?X)))
                (consent--hex-scalar-to-char reader (substring token 1)))
               ((assoc name consent--character-names)
                (cdr (assoc name consent--character-names)))
               ((= (length token) 1)
                (aref token 0))
               (t
                (consent--reader-error
                 reader "unknown character literal #\\%s" token)))))
        (consent--make-character code)))))

(defun consent--read-list (reader depth)
  "Read a list datum from READER at DEPTH."
  (consent--check-depth reader depth)
  (consent--advance reader)
  (consent--reader-pending-push reader 'list)
  (let ((head nil)
        (tail nil)
        (count 0)
        done)
    (while (not done)
      (consent--skip-intertoken-space reader depth)
      (cond
       ((consent--eof-p reader)
        (consent--reader-incomplete reader "unterminated list"))
       ((eq (consent--peek reader) ?\))
        (consent--advance reader)
        (setq done t))
       (t
        (let ((saved (consent--reader-position reader)))
          ;; A period is dotted-pair syntax only when it is a delimited token;
          ;; otherwise it belongs to the ordinary token being read below.
          (if (and (eq (consent--peek reader) ?.)
                   (progn
                     (consent--advance reader)
                     (consent--delimiter-p (consent--peek reader))))
              (progn
                (unless tail
                  (consent--reader-error reader "dot before list element"))
                (consent--skip-intertoken-space reader depth)
                (setcdr tail (consent--read-datum reader (1+ depth)))
                (consent--skip-intertoken-space reader depth)
                (unless (eq (consent--peek reader) ?\))
                  (consent--reader-error
                   reader "expected closing parenthesis after dotted tail"))
                (consent--advance reader)
                (setq done t))
            (setf (consent--reader-position reader) saved)
            (let ((datum (consent--read-datum reader (1+ depth))))
              (cl-incf count)
              (when (> count (consent--reader-maximum-list-length reader))
                (consent--limit-error
                 reader
                 "list length exceeds maximum list length %d"
                 (consent--reader-maximum-list-length reader)))
              (let ((cell (cons datum nil)))
                (if tail
                    (setcdr tail cell)
                  (setq head cell))
                (setq tail cell))))))))
    (consent--reader-pending-pop reader)
    (consent--note-node reader)
    head))

(defun consent--read-vector-elements
    (reader depth kind close-char maximum-length)
  "Read sequence elements for vector-like KIND until CLOSE-CHAR.
Signal if the sequence exceeds MAXIMUM-LENGTH."
  (consent--check-depth reader depth)
  (consent--reader-pending-push reader (intern kind))
  (let ((items nil)
        (count 0)
        done)
    (while (not done)
      (consent--skip-intertoken-space reader depth)
      (cond
       ((consent--eof-p reader)
        (consent--reader-incomplete reader "unterminated %s" kind))
       ((eq (consent--peek reader) close-char)
        (consent--advance reader)
        (setq done t))
       ((eq (consent--peek reader) ?.)
        (consent--reader-error reader "dot is not allowed in %s" kind))
       (t
        (push (consent--read-datum reader (1+ depth)) items)
        (cl-incf count)
        (when (> count maximum-length)
          (consent--limit-error
           reader
           "%s length exceeds maximum %s length %d"
           kind
           kind
           maximum-length)))))
    (consent--reader-pending-pop reader)
    (nreverse items)))

(defun consent--read-vector (reader depth)
  "Read a vector datum from READER."
  (consent--advance reader 2)
  (let ((items
         (consent--read-vector-elements
          reader
          depth
          "vector"
          ?\)
          (consent--reader-maximum-vector-length reader))))
    (consent--note-node reader)
    (vconcat items)))

(defun consent--exact-integer-value (datum)
  "Return DATUM's exact integer value, or nil."
  (and (consent-number-p datum)
       (eq (consent-number-kind datum) 'integer)
       (eq (consent-number-exactness datum) 'exact)
       (consent-number-value datum)))

(defun consent--read-bytevector (reader depth)
  "Read a bytevector datum from READER."
  (consent--advance reader 4)
  (let* ((items (consent--read-vector-elements
                 reader
                 depth
                 "bytevector"
                 ?\)
                 (consent--reader-maximum-bytevector-length reader)))
         (bytes nil))
    (dolist (item items)
      (let ((byte (consent--exact-integer-value item)))
        (unless (and byte (<= 0 byte 255))
          (consent--reader-error
           reader "bytevector element is not an exact byte: %s"
           (consent-datum->external item)))
        (push byte bytes)))
    (consent--note-node reader)
    (consent--make-bytevector (vconcat (nreverse bytes)))))

(defun consent--quote-datum (name datum)
  "Return abbreviation NAME wrapping DATUM."
  (cons (consent--intern-symbol name) (cons datum nil)))

(defun consent--read-datum-label (reader depth)
  "Read an R7RS datum label or label reference from READER."
  (consent--advance reader)
  (let ((start (consent--reader-position reader)))
    (while (let ((char (consent--peek reader)))
             (and char (<= ?0 char ?9)))
      (consent--advance reader))
    (when (= start (consent--reader-position reader))
      (consent--reader-error reader "datum label requires digits"))
    (let* ((id (substring (consent--reader-source reader)
                          start
                          (consent--reader-position reader)))
           (labels (consent--reader-datum-labels reader))
           (marker (consent--peek reader)))
      (cond
       ((eq marker ?=)
        (consent--advance reader)
        (when (gethash id labels)
          (consent--reader-error reader "duplicate datum label %s" id))
        (let ((label (consent--make-datum-label id)))
          (puthash id label labels)
          (let ((datum (consent--read-datum reader depth)))
            (when (eq datum label)
              (consent--reader-error
               reader
               "datum label %s cannot reference itself directly"
               id))
            (setf (consent--datum-label-value label) datum
                  (consent--datum-label-filled label) t)
            datum)))
       ((eq marker ?#)
        (consent--advance reader)
        (let ((label (gethash id labels)))
          (unless label
            (consent--reader-error
             reader "undefined datum label %s" id))
          label))
       (t
        (consent--reader-error
         reader "datum label must end with = or #"))))))

(defun consent--classify-token (reader token)
  "Classify TOKEN as a Scheme simple datum."
  (cond
   ((member token '("#t" "#true"))
    consent-true)
   ((member token '("#f" "#false"))
    consent-false)
   ((consent--parse-number-token reader token))
   ((consent--identifier-token-p token)
    (consent--intern-symbol
     (if (consent--reader-fold-case reader)
         (downcase token)
       token)))
   ((string= token ".")
    (consent--reader-error reader "unexpected dot"))
   (t
    (consent--reader-error reader "invalid token %s" token))))

(defun consent--read-dispatch (reader depth)
  "Read a datum beginning with # from READER."
  (cond
   ((consent--starts-with-p reader "#(")
    (consent--read-vector reader depth))
   ((consent--starts-with-p reader "#u8(")
    (consent--read-bytevector reader depth))
   ((consent--starts-with-p reader "#\\")
    (consent--read-character reader))
   ((and (consent--peek reader 1)
         (>= (consent--peek reader 1) ?0)
         (<= (consent--peek reader 1) ?9))
    (consent--read-datum-label reader depth))
   (t
    (consent--classify-token reader (consent--read-token reader)))))

(defun consent--resolve-datum-labels (datum reader)
  "Replace label placeholders inside DATUM with their resolved values."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-labels
        ((resolve (value)
           (cond
            ((consent--datum-label-p value)
             (unless (consent--datum-label-filled value)
               (consent--reader-error
                reader
                "undefined datum label %s"
                (consent--datum-label-id value)))
             (resolve (consent--datum-label-value value)))
            ((consp value)
             (unless (gethash value seen)
               (puthash value t seen)
               (setcar value (resolve (car value)))
               (setcdr value (resolve (cdr value))))
             value)
            ((vectorp value)
             (unless (gethash value seen)
               (puthash value t seen)
               (cl-loop for index from 0 below (length value)
                        do (aset value index (resolve (aref value index)))))
             value)
            (t value))))
      (resolve datum))))

(defun consent--read-datum (reader depth)
  "Read one datum from READER at DEPTH."
  (consent--check-depth reader depth)
  (consent--skip-intertoken-space reader depth)
  (when (consent--eof-p reader)
    (consent--reader-incomplete reader "unexpected end of input"))
  (let ((start (consent--reader-position reader))
        (char (consent--peek reader))
        datum)
    (setq datum
          (cond
           ((eq char ?\()
            (consent--read-list reader (1+ depth)))
           ((eq char ?\))
            (consent--reader-error reader "unexpected closing parenthesis"))
           ((eq char ?\")
            (prog1 (consent--read-string reader)
              (consent--note-node reader)))
           ((eq char ?\|)
            (prog1
                (consent--intern-symbol
                 (consent--read-vertical-symbol-name reader))
              (consent--note-node reader)))
           ((eq char ?\')
            (consent--advance reader)
            (prog1
                (consent--quote-datum
                 "quote" (consent--read-datum reader (1+ depth)))
              (consent--note-node reader)))
           ((eq char ?`)
            (consent--advance reader)
            (prog1
                (consent--quote-datum
                 "quasiquote" (consent--read-datum reader (1+ depth)))
              (consent--note-node reader)))
           ((eq char ?,)
            (consent--advance reader)
            (if (eq (consent--peek reader) ?@)
                (progn
                  (consent--advance reader)
                  (prog1
                      (consent--quote-datum
                       "unquote-splicing"
                       (consent--read-datum reader (1+ depth)))
                    (consent--note-node reader)))
              (prog1
                  (consent--quote-datum
                   "unquote" (consent--read-datum reader (1+ depth)))
                (consent--note-node reader))))
           ((eq char ?#)
            (prog1 (consent--read-dispatch reader (1+ depth))
              (consent--note-node reader)))
           (t
            (prog1 (consent--classify-token
                    reader (consent--read-token reader))
              (consent--note-node reader)))))
    (when (consent--reader-source-metadata reader)
      (consent--set-datum-source
       datum
       (consent--source-note
        reader start (consent--reader-position reader))))
    datum))

;;;###autoload
(defun consent-read (source &optional options)
  "Read one R7RS datum from SOURCE.

SOURCE may be a string or buffer.  OPTIONS is a plist supporting
`:max-depth', `:max-list-length', `:max-vector-length',
`:max-bytevector-length', `:max-string-size', and
`:max-total-nodes'.  The whole SOURCE must contain exactly one
datum, apart from intertoken space and comments."
  (let ((reader (consent--new-reader source options)))
    (let ((consent--active-symbol-table
           (consent--reader-symbol-table reader)))
      (setf (consent--reader-datum-labels reader)
            (make-hash-table :test #'equal))
      (let ((datum (consent--resolve-datum-labels
                    (consent--read-datum reader 0)
                    reader)))
        (consent--skip-intertoken-space reader 0)
        (unless (consent--eof-p reader)
          (consent--reader-error reader "unexpected trailing input"))
        (consent-validate-datum datum options)
        datum))))

;;;###autoload
(defun consent-read-all (source &optional options)
  "Read all R7RS datums from SOURCE.

SOURCE may be a string or buffer.  OPTIONS has the same shape as
`consent-read'."
  (let ((reader (consent--new-reader source options))
        datums)
    (let ((consent--active-symbol-table
           (consent--reader-symbol-table reader)))
      (consent--skip-intertoken-space reader 0)
      (while (not (consent--eof-p reader))
        (setf (consent--reader-datum-labels reader)
              (make-hash-table :test #'equal))
        (push (consent--resolve-datum-labels
               (consent--read-datum reader 0)
               reader)
              datums)
        (consent--skip-intertoken-space reader 0))
      (setq datums (nreverse datums))
      (dolist (datum datums)
        (consent-validate-datum datum options))
      datums)))

(defun consent--read-one-from-string-at (source position &optional options)
  "Read one datum from SOURCE at POSITION.
Return (DATUM . NEXT-POSITION).  DATUM is
`consent--read-eof' when only intertoken space remains."
  (unless (and (stringp source)
               (integerp position)
               (<= 0 position)
               (<= position (length source)))
    (signal 'wrong-type-argument (list 'string-position (list source position))))
  (let ((reader (consent--new-reader source options)))
    (let ((consent--active-symbol-table
           (consent--reader-symbol-table reader)))
      (setf (consent--reader-position reader) position)
      (consent--skip-intertoken-space reader 0)
      (if (consent--eof-p reader)
          (cons consent--read-eof
                (consent--reader-position reader))
        (setf (consent--reader-datum-labels reader)
              (make-hash-table :test #'equal))
        (let ((datum
               (consent--resolve-datum-labels
                (consent--read-datum reader 0)
                reader)))
          (consent-validate-datum datum options)
          (cons datum (consent--reader-position reader)))))))

;;;; Reader recovery: errors as data, resynchronization, and spans.

(defun consent--form-start-char-p (char)
  "Return non-nil when CHAR can begin a top-level form for resync purposes."
  (not (or (consent--whitespace-char-p char)
           (eq char ?\)))))

(defun consent-resync-to-next-form (source position)
  "Form-level batch resync strategy for reader recovery.
Return the offset of the next top-level form strictly after POSITION in
SOURCE.  A top-level form is anchored to a line start whose first character
is neither whitespace nor a closing parenthesis; when none remains, return
the end of SOURCE.  This is the default resync strategy; callers may supply
their own (for example a lexer-level or editor-grade strategy) through the
`:resync' option."
  (let ((length (length source))
        (index position)
        (result nil))
    (while (and (not result) (< index length))
      (if (and (> index position)
               (eq (aref source (1- index)) ?\n)
               (consent--form-start-char-p (aref source index)))
          (setq result index)
        (setq index (1+ index))))
    (or result length)))

(defun consent--recovery-range (line-starts start end)
  "Build a diagnostic-range datum spanning START..END using LINE-STARTS.
The shape matches the `(agent diagnostics)' range record."
  (let ((start-position (consent--line-starts-line-column line-starts start))
        (end-position (consent--line-starts-line-column line-starts end)))
    (list (consent--intern-symbol "diagnostic-range")
          (list (consent--intern-symbol "start")
                (consent--make-canonical-integer start))
          (list (consent--intern-symbol "end")
                (consent--make-canonical-integer end))
          (list (consent--intern-symbol "line")
                (consent--make-canonical-integer (car start-position)))
          (list (consent--intern-symbol "column")
                (consent--make-canonical-integer (cdr start-position)))
          (list (consent--intern-symbol "end-line")
                (consent--make-canonical-integer (car end-position)))
          (list (consent--intern-symbol "end-column")
                (consent--make-canonical-integer (cdr end-position))))))

(defun consent--recovery-diagnostic (source-id kind reason range)
  "Build a Scheme-readable diagnostic datum for a recovery event.
The shape matches `(agent diagnostics)' `make-diagnostic'; KIND (`invalid'
or `incomplete') rides in the metadata so every host adapter consumes it
identically.  REASON is the human-readable message and RANGE is the
malformed region."
  (list (consent--intern-symbol "diagnostic")
        (list (consent--intern-symbol "severity")
              (consent--intern-symbol "error"))
        (list (consent--intern-symbol "message") reason)
        (list (consent--intern-symbol "source")
              (consent--intern-symbol "reader"))
        (list (consent--intern-symbol "file")
              (or source-id consent-false))
        (list (consent--intern-symbol "buffer") consent-false)
        (list (consent--intern-symbol "range") range)
        (list (consent--intern-symbol "metadata")
              (list (list (consent--intern-symbol "kind")
                          (consent--intern-symbol (symbol-name kind)))
                    (list (consent--intern-symbol "phase")
                          (consent--intern-symbol "read"))))))

(defun consent--recovery-span (kind reason range text)
  "Build a recovery span datum recording one skipped or incomplete region.
TEXT preserves the source bytes so recovery never silently drops input; the
range vocabulary is shared with comment trivia and CST recovery nodes."
  (list (consent--intern-symbol "recovery-span")
        (list (consent--intern-symbol "kind")
              (consent--intern-symbol (symbol-name kind)))
        (list (consent--intern-symbol "reason") reason)
        (list (consent--intern-symbol "range") range)
        (list (consent--intern-symbol "text") text)))

(defun consent--guard-reader-failure (reader thunk)
  "Run THUNK, returning (value . V) or (condition . C) when it raises.
Non-structured errors are normalized to an `invalid' reader condition at
READER's current offset."
  (condition-case err
      (cons 'value (funcall thunk))
    (consent--reader-recovery-condition
     (cons 'condition (car (cdr err))))
    (consent-reader-error
     (cons 'condition
           (consent--make-reader-condition
            :kind 'invalid
            :offset (consent--reader-position reader)
            :message (car (cdr err)))))
    (error
     (cons 'condition
           (consent--make-reader-condition
            :kind 'invalid
            :offset (consent--reader-position reader)
            :message (error-message-string err))))))

(defun consent--build-failure-step
    (reader resync line-starts source-id start condition)
  "Build the `consent-recovery-step' for a reader failure anchored at START.
Incomplete input rewinds to START; a genuine error advances past the
malformed region via RESYNC with guaranteed forward progress."
  (let ((kind (consent--reader-condition-kind condition))
        (reason (consent--reader-condition-message condition))
        (source (consent--reader-source reader))
        (length (consent--reader-length reader)))
    (if (eq kind 'incomplete)
        (let* ((range (consent--recovery-range line-starts start length))
               (text (substring source start length))
               (diagnostic
                (consent--recovery-diagnostic source-id 'incomplete reason range))
               (span (consent--recovery-span 'incomplete reason range text)))
          (setf (consent--reader-position reader) start)
          (consent--make-recovery-step
           'incomplete nil diagnostic span start
           (consent--reader-condition-pending condition)))
      (let* ((proposed (funcall resync source start))
             (next (min length (max proposed (1+ start))))
             (range (consent--recovery-range line-starts start next))
             (text (substring source start next))
             (diagnostic
              (consent--recovery-diagnostic source-id 'invalid reason range))
             (span (consent--recovery-span 'invalid reason range text)))
        (setf (consent--reader-position reader) next)
        (consent--make-recovery-step 'invalid nil diagnostic span next)))))

(defun consent--recover-step (reader resync line-starts source-id options)
  "Read one form from READER in recovery mode and return a `consent-recovery-step'.
Leading trivia is skipped first so a malformed region is anchored at the
datum start, not at preceding whitespace; trivia-level failures (such as an
unterminated block comment) are anchored where the trivia began.  RESYNC is
the resync strategy, LINE-STARTS positions diagnostics, SOURCE-ID labels
them, and OPTIONS carries reader limits."
  ;; A prior step that unwound mid-construct leaves stale open-construct
  ;; entries behind; each step starts from a balanced cursor, so reset.
  (setf (consent--reader-pending-stack reader) nil)
  (let* ((pre (consent--reader-position reader))
         (skip-outcome
          (consent--guard-reader-failure
           reader
           (lambda () (consent--skip-intertoken-space reader 0)))))
    (cond
     ((eq (car skip-outcome) 'condition)
      (consent--build-failure-step reader resync line-starts source-id
                                   pre (cdr skip-outcome)))
     ((consent--eof-p reader)
      (consent--make-recovery-step 'eof nil nil nil
                                   (consent--reader-position reader)))
     (t
      (let* ((start (consent--reader-position reader))
             (read-outcome
              (consent--guard-reader-failure
               reader
               (lambda ()
                 (setf (consent--reader-datum-labels reader)
                       (make-hash-table :test #'equal))
                 (let ((datum (consent--resolve-datum-labels
                               (consent--read-datum reader 0)
                               reader)))
                   (consent-validate-datum datum options)
                   datum)))))
        (if (eq (car read-outcome) 'value)
            (consent--make-recovery-step 'datum (cdr read-outcome) nil nil
                                         (consent--reader-position reader))
          (consent--build-failure-step reader resync line-starts source-id
                                       start (cdr read-outcome))))))))

(defun consent--recovery-reader (source options)
  "Create a recovery-mode reader over SOURCE, forcing recovery on."
  (consent--new-reader source (plist-put (copy-sequence options) :recovery t)))

;;;###autoload
(defun consent-read-recover (source &optional options)
  "Read SOURCE in recovery mode and return a `consent-recovery-result'.
Collect every readable datum plus an ordered diagnostics list and recovery
spans instead of aborting on the first malformed form.  The result STATUS is
`incomplete' when the trailing region is a valid prefix awaiting more input,
otherwise `complete'.  The resync point is caller-selectable through the
`:resync' option (defaulting to `consent-resync-to-next-form')."
  (unless (stringp source)
    (signal 'wrong-type-argument (list 'stringp source)))
  (let* ((resync (consent--option options :resync #'consent-resync-to-next-form))
         (source-id (consent--option options :source-id nil))
         (line-starts (consent--source-line-starts source))
         (reader (consent--recovery-reader source options))
         (datums nil)
         (diagnostics nil)
         (spans nil)
         (status 'complete)
         (done nil))
    (let ((consent--active-symbol-table
           (consent--reader-symbol-table reader)))
      (while (not done)
        (let* ((step (consent--recover-step reader resync line-starts
                                            source-id options))
               (step-status (consent-recovery-step-status step)))
          (cond
           ((eq step-status 'eof)
            (setq done t))
           ((eq step-status 'datum)
            (push (consent-recovery-step-datum step) datums))
           ((eq step-status 'incomplete)
            (push (consent-recovery-step-diagnostic step) diagnostics)
            (push (consent-recovery-step-span step) spans)
            (setq status 'incomplete done t))
           (t
            (push (consent-recovery-step-diagnostic step) diagnostics)
            (push (consent-recovery-step-span step) spans)))))
      (consent--make-recovery-result
       (nreverse datums) (nreverse diagnostics) (nreverse spans) status))))

;;;###autoload
(defun consent-read-recover-from-string-at (source position &optional options)
  "Recovery-aware single-form read for interactive and streaming callers.
Return a `consent-recovery-step' whose STATUS is `datum', `invalid',
`incomplete', or `eof', and whose NEXT offset is where the caller should
resume.  Incomplete input is surfaced as its own status so auto-indent and
continuation prompts never confuse a valid prefix with a syntax error."
  (unless (and (stringp source)
               (integerp position)
               (<= 0 position)
               (<= position (length source)))
    (signal 'wrong-type-argument (list 'string-position (list source position))))
  (let* ((resync (consent--option options :resync #'consent-resync-to-next-form))
         (source-id (consent--option options :source-id nil))
         (line-starts (consent--source-line-starts source))
         (reader (consent--recovery-reader source options)))
    (let ((consent--active-symbol-table
           (consent--reader-symbol-table reader)))
      (setf (consent--reader-position reader) position)
      (consent--recover-step reader resync line-starts source-id options))))

(defun consent--validate-note-node (reader)
  "Record one validated datum node in READER."
  (consent--note-node reader))

(defun consent--validate-datum (datum reader depth seen)
  "Validate DATUM using READER limits at DEPTH.
SEEN prevents infinite recursion over host-created cycles."
  (consent--check-depth reader depth)
  (cond
   ((null datum)
    (consent--validate-note-node reader))
   ((or (consent-boolean-p datum)
        (consent-symbol-p datum)
        (consent-character-p datum)
        (consent-number-p datum)
        (consent-handle-p datum))
    (consent--validate-note-node reader))
   ((stringp datum)
    (when (> (length datum) (consent--reader-maximum-string-size reader))
      (consent--limit-error
       reader
       "string size exceeds maximum string size %d"
       (consent--reader-maximum-string-size reader)))
    (consent--validate-note-node reader))
   ((consent-bytevector-p datum)
    (when (> (length (consent-bytevector-bytes datum))
             (consent--reader-maximum-bytevector-length reader))
      (consent--limit-error
       reader
       "bytevector length exceeds maximum bytevector length %d"
       (consent--reader-maximum-bytevector-length reader)))
    (cl-loop for byte across (consent-bytevector-bytes datum)
             unless (and (integerp byte) (<= 0 byte 255))
             do (consent--reader-error
                 reader "bytevector contains invalid byte %S" byte))
    (consent--validate-note-node reader))
   ((consp datum)
    (unless (gethash datum seen)
      (let ((cursor datum)
            (count 0))
        (while (and (consp cursor)
                    (not (gethash cursor seen)))
          (puthash cursor t seen)
          (cl-incf count)
          (when (> count (consent--reader-maximum-list-length reader))
            (consent--limit-error
             reader
             "list length exceeds maximum list length %d"
             (consent--reader-maximum-list-length reader)))
          (consent--validate-note-node reader)
          (consent--validate-datum (car cursor) reader (1+ depth) seen)
          (setq cursor (cdr cursor)))
        (when (and cursor (not (gethash cursor seen)))
          (consent--validate-datum cursor reader (1+ depth) seen)))))
   ((vectorp datum)
    (unless (gethash datum seen)
      (puthash datum t seen)
      (when (> (length datum) (consent--reader-maximum-vector-length reader))
        (consent--limit-error
         reader
         "vector length exceeds maximum vector length %d"
         (consent--reader-maximum-vector-length reader)))
      (consent--validate-note-node reader)
      (cl-loop for item across datum
               do (consent--validate-datum item reader (1+ depth) seen))))
   (t
    (consent--reader-error
     reader "datum contains unsupported host object %S" datum))))

;;;###autoload
(defun consent-validate-datum (datum &optional options)
  "Validate that DATUM is an Consent Scheme implementation datum.

OPTIONS has the same resource limit shape as `consent-read'.
Return DATUM on success and signal `consent-reader-error' on
invalid host objects or `consent-datum-limit-error' on limit
failures."
  (let ((reader (consent--new-reader "" options)))
    (consent--validate-datum datum reader 0 (make-hash-table :test #'eq))
    datum))

(defun consent--escape-string (string &optional vertical-symbol-p)
  "Return escaped STRING contents, including bars for a vertical symbol."
  (let (result)
    (cl-loop for char across string
             do (push
                 (pcase char
                   (?\a "\\a")
                   (?\b "\\b")
                   (?\t "\\t")
                   (?\n "\\n")
                   (?\r "\\r")
                   (?\" "\\\"")
                   (?\\ "\\\\")
                   (?| (if vertical-symbol-p "\\|" "|"))
                   (_ (string char)))
                 result))
    (mapconcat #'identity (nreverse result) "")))

(defun consent--symbol-needs-bars-p (name)
  "Return non-nil if NAME should be written with vertical bars."
  (or (not (consent--identifier-token-p name))
      (consent--parse-number-token (consent--new-reader "" nil) name)))

(defun consent--write-symbol-name (name)
  "Return external representation of Scheme symbol NAME."
  (if (consent--symbol-needs-bars-p name)
      (concat "|" (consent--escape-string name t) "|")
    name))

(defun consent--write-character (code)
  "Return external representation of character CODE."
  (let ((name (car (rassoc code consent--character-names))))
    (cond
     (name (concat "#\\" name))
     ((or (< code 33) (= code 127))
      (format "#\\x%x" code))
     (t (concat "#\\" (string code))))))

(defun consent--writer-compound-p (datum)
  "Return non-nil when DATUM can participate in datum-label graphs."
  (or (consp datum) (vectorp datum)))

(defun consent--writer-scan-graph (datum)
  "Return graph metadata for DATUM as (COUNTS . CYCLIC)."
  (let ((counts (make-hash-table :test #'eq))
        (states (make-hash-table :test #'eq))
        (cyclic (make-hash-table :test #'eq)))
    (cl-labels
        ((mark-cycle (target stack)
           (let ((cursor stack)
                 done)
             (while (and cursor (not done))
               (puthash (car cursor) t cyclic)
               (setq done (eq (car cursor) target))
               (setq cursor (cdr cursor)))))
         (scan (value stack)
           (when (consent--writer-compound-p value)
             (puthash value (1+ (gethash value counts 0)) counts)
             (pcase (gethash value states)
               ('visiting
                (mark-cycle value stack))
               ('done nil)
               (_
                (puthash value 'visiting states)
                (cond
                 ((consp value)
                  (scan (car value) (cons value stack))
                  (scan (cdr value) (cons value stack)))
                 ((vectorp value)
                  (cl-loop for item across value
                           do (scan item (cons value stack)))))
                (puthash value 'done states))))))
      (scan datum nil))
    (cons counts cyclic)))

(defun consent--writer-hash-nonempty-p (table)
  "Return non-nil if hash TABLE contains at least one entry."
  (let (found)
    (maphash (lambda (_key _value) (setq found t)) table)
    found))

(defun consent--record-name->external (name)
  "Return NAME as a record tag for writer output."
  (cond
   ((stringp name) name)
   ((consent-symbol-p name) (consent-symbol-name name))
   (t (format "%S" name))))

;;;###autoload
(defun consent-datum->external (datum &optional mode displayp)
  "Return an external representation for DATUM.
MODE is `write' by default, `shared' for write-shared behavior,
or `simple' for write-simple behavior.  When DISPLAYP is non-nil,
strings, symbols, and characters use display rendering."
  (let* ((writer-mode (or mode 'write))
         (graph (consent--writer-scan-graph datum))
         (counts (car graph))
         (cyclic (cdr graph))
         (labels (make-hash-table :test #'eq))
         (emitted (make-hash-table :test #'eq))
         (next-label 0))
    (when (and (eq writer-mode 'simple)
               (consent--writer-hash-nonempty-p cyclic))
      (signal 'consent-reader-error
              (list "write-simple cannot render circular datum")))
    (cl-labels
        ((label-needed-p
          (value)
          (and (consent--writer-compound-p value)
               (pcase writer-mode
                 ('shared (> (gethash value counts 0) 1))
                 ('write (gethash value cyclic))
                 (_ nil))))
         (label-reference-ready-p
          (value)
          (and (label-needed-p value)
               (gethash value labels)
               (gethash value emitted)))
         (label-for
          (value)
          (or (gethash value labels)
              (let ((label next-label))
                (setq next-label (1+ next-label))
                (puthash value label labels)
                label)))
         (render
          (value)
          (if (label-needed-p value)
              (let ((label (label-for value)))
                (if (gethash value emitted)
                    (format "#%d#" label)
                  (puthash value t emitted)
                  (concat (format "#%d=" label) (render-body value))))
            (render-body value)))
         (render-list
          (value)
          (let ((parts nil)
                (cursor value)
                (first t)
                tail)
            (while (and (consp cursor)
                        (not (and (not first)
                                  (label-reference-ready-p cursor))))
              (push (render (car cursor)) parts)
              (setq cursor (cdr cursor))
              (setq first nil))
            (setq parts (nreverse parts))
            (when (and (consp cursor)
                       (label-reference-ready-p cursor))
              (setq tail (render cursor)
                    cursor nil))
            (concat
             "("
             (mapconcat #'identity parts " ")
             (cond
              (tail
               (concat (if parts " . " ". ") tail))
              (cursor
               (concat (if parts " . " ". ") (render cursor)))
              (t ""))
             ")")))
         (render-vector
          (value)
          (concat
           "#("
           (mapconcat #'render (append value nil) " ")
           ")"))
         (render-bytevector
          (value)
          (concat
           "#u8("
           (mapconcat #'number-to-string
                      (append (consent-bytevector-bytes value) nil)
                      " ")
           ")"))
         (render-record
          (value)
          (format "#<record %s>"
                  (consent--record-name->external
                   (consent-record-type-name
                    (consent-record-type value)))))
         (render-record-type
          (value)
          (format "#<record-type %s>"
                  (consent--record-name->external
                   (consent-record-type-name value))))
         (render-handle
          (value)
          (format "(handle %s %s)"
                  (consent--write-symbol-name
                   (symbol-name (consent-handle-kind value)))
                  (consent--write-symbol-name
                   (consent-handle-id value))))
         (render-body
          (value)
          (cond
           ((eq value consent-true) "#t")
           ((eq value consent-false) "#f")
           ((null value) "()")
           ((consent-symbol-p value)
            (if displayp
                (consent-symbol-name value)
              (consent--write-symbol-name
               (consent-symbol-name value))))
           ((consent-character-p value)
            (if displayp
                (char-to-string (consent-character-code value))
              (consent--write-character
               (consent-character-code value))))
           ((or (consent-number-p value)
                (numberp value))
            (consent--number->external value))
           ((stringp value)
            (if displayp
                value
              (concat "\"" (consent--escape-string value) "\"")))
           ((consent-bytevector-p value)
            (render-bytevector value))
           ((consp value)
            (render-list value))
           ((vectorp value)
            (render-vector value))
           ((consent-record-p value)
            (render-record value))
           ((consent-record-type-p value)
            (render-record-type value))
           ((consent-handle-p value)
            (render-handle value))
           (t
            (signal 'consent-reader-error
                    (list (format "cannot write unsupported datum %S"
                                  value)))))))
      (render datum))))

(defun consent--render-limit-ref (limits key)
  "Return the integer ceiling for KEY in the LIMITS alist, or nil for none.
A ceiling may arrive as a host integer (the usual interactive default) or as a
Consent number record (when LIMITS came from evaluated Consent data); the
internal depth/length/size counters are host integers, so normalize the ceiling
to a host integer rather than risk comparing an integer against a record."
  (let ((entry (and (consp limits) (assq key limits))))
    (and entry
         (let ((value (cdr entry)))
           (if (consent-number-p value)
               (consent-number-value value)
             value)))))

(defun consent-datum->external-bounded (datum limits &optional mode displayp)
  "Return external text for DATUM bounded by LIMITS.
LIMITS is an alist `((depth . D) (length . L) (size . S))'; each value is a
nonnegative integer ceiling or nil/absent for no ceiling.  DEPTH bounds
nesting (a compound at the ceiling renders as the marker), LENGTH bounds the
elements rendered per list/vector/bytevector (the overflow renders as a
trailing marker), and SIZE bounds the total characters emitted (a hard
backstop that stops the walk once reached, so rendering is bounded in time as
well as space).  The canonical truncation marker is the parseable token `...'
at every elision point.  Cyclic structure is detected against the ancestor
path and broken with the marker, so the walk always terminates regardless of
LIMITS.  Atoms delegate to the unbounded `consent-datum->external' so numbers,
strings, symbols, characters, and records render identically to the canonical
writer; MODE and DISPLAYP are its arguments.  This is the interactive display
path (#508); the canonical writer stays unbounded for the capture/round-trip
surface.  Mirrors the portable `consent-datum->external-bounded'."
  (let ((writer-mode (or mode 'write))
        (depth-limit (consent--render-limit-ref limits 'depth))
        (length-limit (consent--render-limit-ref limits 'length))
        (size-limit (consent--render-limit-ref limits 'size))
        (marker "...")
        (parts nil)
        (used 0)
        (overflow nil)
        (ancestors nil))
    (cl-labels
        ((raw-emit
          (text)
          ;; Append TEXT to the accumulator and charge its length against the
          ;; running size counter, without consulting the size ceiling.
          (push text parts)
          (setq used (+ used (length text))))
         (emit
          (text)
          ;; Append TEXT under the size ceiling: drop it once overflow is set,
          ;; emit the marker and set overflow when it would cross SIZE-LIMIT,
          ;; otherwise append it.
          (cond
           (overflow t)
           ((and size-limit (> (+ used (length text)) size-limit))
            (setq overflow t)
            (raw-emit marker))
           (t (raw-emit text))))
         (atom-text
          (value)
          ;; Pre-cap a long string by source prefix so a huge atom does not
          ;; force the unbounded writer to build a huge intermediate before the
          ;; size backstop in `emit' can apply.
          (let ((value (if (and size-limit
                                 (stringp value)
                                 (> (length value) (- size-limit used)))
                           (substring value 0 (max 0 (- size-limit used)))
                         value)))
            (consent-datum->external value writer-mode displayp)))
         (render
          (value depth)
          ;; Render VALUE at nesting DEPTH, dispatching compounds to their
          ;; bounded renderers and atoms to `atom-text'; a no-op once overflow
          ;; is set so the walk unwinds in bounded time.
          (cond
           (overflow t)
           ((consp value) (render-pair value depth))
           ((vectorp value) (render-vector value depth))
           ((consent-bytevector-p value) (render-bytevector value depth))
           (t (emit (atom-text value)))))
         (render-pair
          (value depth)
          ;; Render pair VALUE at DEPTH, breaking a cycle back to an ancestor or
          ;; an over-deep nesting with the marker, and eliding the spine past
          ;; LENGTH-LIMIT with a trailing marker.
          (cond
           ((memq value ancestors) (emit marker))
           ((and depth-limit (>= depth depth-limit)) (emit marker))
           (t
            (let ((saved ancestors)
                  (cursor value)
                  (count 0)
                  (first t)
                  (done nil))
              (emit "(")
              (while (not done)
                (cond
                 (overflow (setq done t))
                 ((not (consp cursor))
                  (unless (null cursor)
                    (emit " . ")
                    (render cursor (1+ depth)))
                  (emit ")")
                  (setq done t))
                 ((memq cursor ancestors)
                  (emit " . ") (emit marker) (emit ")")
                  (setq done t))
                 ((and length-limit (>= count length-limit))
                  (emit " ") (emit marker) (emit ")")
                  (setq done t))
                 (t
                  (unless first (emit " "))
                  (push cursor ancestors)
                  (render (car cursor) (1+ depth))
                  (setq cursor (cdr cursor) count (1+ count) first nil))))
              (setq ancestors saved)))))
         (render-vector
          (value depth)
          ;; Render vector VALUE at DEPTH, breaking a self-reference or an
          ;; over-deep nesting with the marker, and eliding elements past
          ;; LENGTH-LIMIT with a trailing marker.
          (cond
           ((memq value ancestors) (emit marker))
           ((and depth-limit (>= depth depth-limit)) (emit marker))
           (t
            (let ((saved ancestors)
                  (size (length value))
                  (index 0)
                  (first t)
                  (done nil))
              (push value ancestors)
              (emit "#(")
              (while (not done)
                (cond
                 (overflow (setq done t))
                 ((>= index size) (setq done t))
                 ((and length-limit (>= index length-limit))
                  (unless first (emit " ")) (emit marker)
                  (setq done t))
                 (t
                  (unless first (emit " "))
                  (render (aref value index) (1+ depth))
                  (setq index (1+ index) first nil))))
              (emit ")")
              (setq ancestors saved)))))
         (render-bytevector
          (value depth)
          ;; Render bytevector VALUE at DEPTH (over-deep nesting renders as the
          ;; marker), eliding bytes past LENGTH-LIMIT with a trailing marker; no
          ;; cycle check is needed since a bytevector holds no compounds.
          (cond
           ((and depth-limit (>= depth depth-limit)) (emit marker))
           (t
            (let ((bytes (consent-bytevector-bytes value))
                  (index 0)
                  (first t)
                  (done nil))
              (emit "#u8(")
              (while (not done)
                (cond
                 (overflow (setq done t))
                 ((>= index (length bytes)) (setq done t))
                 ((and length-limit (>= index length-limit))
                  (unless first (emit " ")) (emit marker)
                  (setq done t))
                 (t
                  (unless first (emit " "))
                  (emit (number-to-string (aref bytes index)))
                  (setq index (1+ index) first nil))))
              (emit ")"))))))
      (render datum 0)
      (apply #'concat (nreverse parts)))))

(provide 'consent-reader)

;;; consent-reader.el ends here
