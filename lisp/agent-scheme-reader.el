;;; agent-scheme-reader.el --- R7RS datum reader  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small, direct R7RS datum reader for Agent Scheme.  This module does not
;; delegate lexical syntax to Emacs `read'; it returns implementation datums
;; that keep Scheme booleans, symbols, characters, and bytevectors distinct
;; from their Emacs Lisp host representations.

;;; Code:

(require 'cl-lib)

(defgroup agent-scheme nil
  "Agent Scheme runtime."
  :group 'languages)

(defcustom agent-scheme-reader-maximum-depth 256
  "Maximum compound datum nesting depth accepted by the reader."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-reader-maximum-list-length 100000
  "Maximum list length accepted by the reader."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-reader-maximum-vector-length 100000
  "Maximum vector length accepted by the reader."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-reader-maximum-bytevector-length 100000
  "Maximum bytevector length accepted by the reader."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-reader-maximum-string-size 1048576
  "Maximum string size accepted by the reader."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-reader-maximum-total-nodes 1000000
  "Maximum total datum nodes accepted by the reader."
  :type 'integer
  :group 'agent-scheme)

(define-error 'agent-scheme-reader-error
  "Agent Scheme reader error")

(define-error 'agent-scheme-datum-limit-error
  "Agent Scheme datum resource limit exceeded"
  'agent-scheme-reader-error)

(cl-defstruct (agent-scheme-boolean
               (:constructor agent-scheme--make-boolean (value))
               (:copier nil))
  "Scheme boolean datum."
  value)

(defconst agent-scheme-true
  (agent-scheme--make-boolean t)
  "Scheme true boolean datum.")

(defconst agent-scheme-false
  (agent-scheme--make-boolean nil)
  "Scheme false boolean datum.")

(cl-defstruct (agent-scheme-symbol
               (:constructor agent-scheme--make-symbol (name))
               (:copier nil))
  "Scheme symbol datum."
  name)

(cl-defstruct (agent-scheme-character
               (:constructor agent-scheme--make-character (code))
               (:copier nil))
  "Scheme character datum."
  code)

(cl-defstruct (agent-scheme-number
               (:constructor agent-scheme--make-number
                             (lexeme exactness radix kind value))
               (:copier nil))
  "Scheme number datum.

LEXEME preserves the source spelling.  EXACTNESS is `exact',
`inexact', or nil when unspecified.  RADIX is 2, 8, 10, or 16.
KIND names the parsed shape, such as `integer', `decimal',
`rational', `complex', or `infnan'."
  lexeme exactness radix kind value)

(cl-defstruct (agent-scheme-bytevector
               (:constructor agent-scheme--make-bytevector (bytes))
               (:copier nil))
  "Scheme bytevector datum."
  bytes)

(cl-defstruct (agent-scheme--reader
               (:constructor agent-scheme--make-reader))
  "Mutable state for one reader pass.
SOURCE is an immutable input snapshot, while POSITION, FOLD-CASE,
and NODE-COUNT change as lexical directives, comments, and datums
are consumed.  The remaining slots are per-run resource limits."
  source
  (position 0)
  length
  fold-case
  (node-count 0)
  maximum-depth
  maximum-list-length
  maximum-vector-length
  maximum-bytevector-length
  maximum-string-size
  maximum-total-nodes)

(defvar agent-scheme--symbol-table (make-hash-table :test #'equal)
  "Intern table for Scheme symbol datums.")

(defconst agent-scheme--character-names
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

(defun agent-scheme--intern-symbol (name)
  "Return the interned Scheme symbol datum for NAME."
  (or (gethash name agent-scheme--symbol-table)
      (puthash name (agent-scheme--make-symbol name)
               agent-scheme--symbol-table)))

(defun agent-scheme--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun agent-scheme--source-string (source)
  "Return SOURCE as a string."
  (cond
   ((stringp source) source)
   ((bufferp source)
    (with-current-buffer source
      (buffer-substring-no-properties (point-min) (point-max))))
   (t
    (signal 'wrong-type-argument (list 'string-or-buffer-p source)))))

(defun agent-scheme--new-reader (source options)
  "Return a reader state over SOURCE using OPTIONS."
  (let ((text (agent-scheme--source-string source)))
    (agent-scheme--make-reader
     :source text
     :length (length text)
     :maximum-depth
     (agent-scheme--option options :max-depth
                           agent-scheme-reader-maximum-depth)
     :maximum-list-length
     (agent-scheme--option options :max-list-length
                           agent-scheme-reader-maximum-list-length)
     :maximum-vector-length
     (agent-scheme--option options :max-vector-length
                           agent-scheme-reader-maximum-vector-length)
     :maximum-bytevector-length
     (agent-scheme--option options :max-bytevector-length
                           agent-scheme-reader-maximum-bytevector-length)
     :maximum-string-size
     (agent-scheme--option options :max-string-size
                           agent-scheme-reader-maximum-string-size)
     :maximum-total-nodes
     (agent-scheme--option options :max-total-nodes
                           agent-scheme-reader-maximum-total-nodes))))

(defun agent-scheme--reader-error (reader message &rest args)
  "Signal a reader error at READER's current position.
MESSAGE and ARGS are passed to `format'."
  (signal 'agent-scheme-reader-error
          (list (format "at offset %d: %s"
                        (agent-scheme--reader-position reader)
                        (apply #'format message args)))))

(defun agent-scheme--limit-error (reader message &rest args)
  "Signal a datum resource limit error for READER.
MESSAGE and ARGS are passed to `format'."
  (signal 'agent-scheme-datum-limit-error
          (list (format "at offset %d: %s"
                        (agent-scheme--reader-position reader)
                        (apply #'format message args)))))

(defun agent-scheme--check-depth (reader depth)
  "Signal if DEPTH exceeds READER's maximum depth."
  (when (> depth (agent-scheme--reader-maximum-depth reader))
    (agent-scheme--limit-error
     reader
     "datum depth %d exceeds maximum depth %d"
     depth
     (agent-scheme--reader-maximum-depth reader))))

(defun agent-scheme--note-node (reader)
  "Record one parsed datum node in READER."
  (cl-incf (agent-scheme--reader-node-count reader))
  (when (> (agent-scheme--reader-node-count reader)
           (agent-scheme--reader-maximum-total-nodes reader))
    (agent-scheme--limit-error
     reader
     "datum node count exceeds maximum total nodes %d"
     (agent-scheme--reader-maximum-total-nodes reader))))

(defun agent-scheme--eof-p (reader)
  "Return non-nil when READER is at end of input."
  (>= (agent-scheme--reader-position reader)
      (agent-scheme--reader-length reader)))

(defun agent-scheme--peek (reader &optional offset)
  "Return READER character at OFFSET from point, or nil at EOF."
  (let ((index (+ (agent-scheme--reader-position reader) (or offset 0))))
    (when (< index (agent-scheme--reader-length reader))
      (aref (agent-scheme--reader-source reader) index))))

(defun agent-scheme--advance (reader &optional count)
  "Advance READER by COUNT characters."
  (setf (agent-scheme--reader-position reader)
        (+ (agent-scheme--reader-position reader) (or count 1))))

(defun agent-scheme--starts-with-p (reader text)
  "Return non-nil if READER input at point starts with TEXT."
  (let ((position (agent-scheme--reader-position reader))
        (end (+ (agent-scheme--reader-position reader) (length text))))
    (and (<= end (agent-scheme--reader-length reader))
         (string= text
                  (substring (agent-scheme--reader-source reader)
                             position end)))))

(defun agent-scheme--whitespace-char-p (char)
  "Return non-nil if CHAR is R7RS intertoken whitespace."
  (memq char '(?\s ?\t ?\n ?\r ?\f)))

(defun agent-scheme--intraline-whitespace-p (char)
  "Return non-nil if CHAR is space or tab."
  (memq char '(?\s ?\t)))

(defun agent-scheme--delimiter-p (char)
  "Return non-nil if CHAR is an R7RS token delimiter."
  (or (null char)
      (agent-scheme--whitespace-char-p char)
      (memq char '(?\| ?\( ?\) ?\" ?\;))))

(defun agent-scheme--reserved-char-p (char)
  "Return non-nil if CHAR is reserved by R7RS."
  (memq char '(?\[ ?\] ?\{ ?\})))

(defun agent-scheme--skip-line-comment (reader)
  "Skip a semicolon line comment in READER."
  (while (and (not (agent-scheme--eof-p reader))
              (not (memq (agent-scheme--peek reader) '(?\n ?\r))))
    (agent-scheme--advance reader))
  (when (eq (agent-scheme--peek reader) ?\r)
    (agent-scheme--advance reader)
    (when (eq (agent-scheme--peek reader) ?\n)
      (agent-scheme--advance reader)))
  (when (eq (agent-scheme--peek reader) ?\n)
    (agent-scheme--advance reader)))

(defun agent-scheme--skip-nested-comment (reader)
  "Skip one nested block comment in READER."
  (let ((depth 0))
    (while (or (> depth 0)
               (agent-scheme--starts-with-p reader "#|"))
      (cond
       ((agent-scheme--eof-p reader)
        (agent-scheme--reader-error reader "unterminated block comment"))
       ((agent-scheme--starts-with-p reader "#|")
        (cl-incf depth)
        (agent-scheme--advance reader 2))
       ((agent-scheme--starts-with-p reader "|#")
        (cl-decf depth)
        (agent-scheme--advance reader 2))
       (t
        (agent-scheme--advance reader))))))

(defun agent-scheme--skip-directive (reader)
  "Skip and apply one reader directive in READER."
  (cond
   ((and (agent-scheme--starts-with-p reader "#!fold-case")
         (agent-scheme--delimiter-p (agent-scheme--peek reader 11)))
    (setf (agent-scheme--reader-fold-case reader) t)
    (agent-scheme--advance reader 11))
   ((and (agent-scheme--starts-with-p reader "#!no-fold-case")
         (agent-scheme--delimiter-p (agent-scheme--peek reader 14)))
    (setf (agent-scheme--reader-fold-case reader) nil)
    (agent-scheme--advance reader 14))
   (t
    (agent-scheme--reader-error reader "unknown reader directive"))))

(defun agent-scheme--skip-intertoken-space (reader depth)
  "Skip whitespace, comments, directives, and datum comments in READER.
DEPTH is used when reading a datum comment's discarded datum."
  (let ((again t))
    (while again
      (setq again nil)
      (while (agent-scheme--whitespace-char-p (agent-scheme--peek reader))
        (setq again t)
        (agent-scheme--advance reader))
      (cond
       ((eq (agent-scheme--peek reader) ?\;)
        (setq again t)
        (agent-scheme--skip-line-comment reader))
       ((agent-scheme--starts-with-p reader "#|")
        (setq again t)
        (agent-scheme--skip-nested-comment reader))
       ((agent-scheme--starts-with-p reader "#!")
        (setq again t)
        (agent-scheme--skip-directive reader))
       ((agent-scheme--starts-with-p reader "#;")
        (setq again t)
        (agent-scheme--advance reader 2)
        ;; R7RS datum comments consume a complete datum, not just the next
        ;; token, so the recursive read must share the current reader state.
        (agent-scheme--skip-intertoken-space reader depth)
        (agent-scheme--read-datum reader depth))))))

(defun agent-scheme--read-token (reader)
  "Read one non-delimited token from READER."
  (let ((start (agent-scheme--reader-position reader)))
    (while (not (agent-scheme--delimiter-p (agent-scheme--peek reader)))
      (when (agent-scheme--reserved-char-p (agent-scheme--peek reader))
        (agent-scheme--reader-error
         reader "reserved character %c in token" (agent-scheme--peek reader)))
      (agent-scheme--advance reader))
    (substring (agent-scheme--reader-source reader)
               start
               (agent-scheme--reader-position reader))))

(defun agent-scheme--hex-scalar-to-char (reader digits)
  "Return character code for hexadecimal scalar DIGITS."
  (unless (string-match-p "\\`[[:xdigit:]]+\\'" digits)
    (agent-scheme--reader-error reader "invalid hexadecimal scalar escape"))
  (let ((code (string-to-number digits 16)))
    (when (or (> code #x10ffff)
              (and (>= code #xd800) (<= code #xdfff)))
      (agent-scheme--reader-error
       reader "invalid Unicode scalar value #x%x" code))
    code))

(defun agent-scheme--read-hex-escape (reader)
  "Read a `\\x...;' escape body from READER after the x."
  (let ((start (agent-scheme--reader-position reader)))
    (while (and (not (agent-scheme--eof-p reader))
                (not (eq (agent-scheme--peek reader) ?\;)))
      (agent-scheme--advance reader))
    (when (agent-scheme--eof-p reader)
      (agent-scheme--reader-error reader "unterminated hexadecimal escape"))
    (let ((digits (substring (agent-scheme--reader-source reader)
                             start
                             (agent-scheme--reader-position reader))))
      (agent-scheme--advance reader)
      (agent-scheme--hex-scalar-to-char reader digits))))

(defun agent-scheme--mnemonic-escape (reader char)
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
    (_ (agent-scheme--reader-error
        reader "unknown escape sequence \\%c" char))))

(defun agent-scheme--read-string (reader)
  "Read a string datum from READER."
  (agent-scheme--advance reader)
  (let ((result nil)
        (size 0))
    (cl-labels
        ((emit
          (char)
          (cl-incf size)
          (when (> size (agent-scheme--reader-maximum-string-size reader))
            (agent-scheme--limit-error
             reader
             "string size exceeds maximum string size %d"
             (agent-scheme--reader-maximum-string-size reader)))
          (push char result))
         (skip-line-continuation
          ()
          (while (agent-scheme--intraline-whitespace-p
                  (agent-scheme--peek reader))
            (agent-scheme--advance reader))
          (cond
           ((eq (agent-scheme--peek reader) ?\r)
            (agent-scheme--advance reader)
            (when (eq (agent-scheme--peek reader) ?\n)
              (agent-scheme--advance reader)))
           ((eq (agent-scheme--peek reader) ?\n)
            (agent-scheme--advance reader))
           (t
            (agent-scheme--reader-error
             reader "expected line ending in string continuation")))
          (while (agent-scheme--intraline-whitespace-p
                  (agent-scheme--peek reader))
            (agent-scheme--advance reader))))
      (while (not (eq (agent-scheme--peek reader) ?\"))
        (when (agent-scheme--eof-p reader)
          (agent-scheme--reader-error reader "unterminated string"))
        (let ((char (agent-scheme--peek reader)))
          (cond
           ((eq char ?\\)
            (agent-scheme--advance reader)
            (let ((escaped (agent-scheme--peek reader)))
              (cond
               ((eq escaped ?x)
                (agent-scheme--advance reader)
                (emit (agent-scheme--read-hex-escape reader)))
               ((agent-scheme--intraline-whitespace-p escaped)
                (skip-line-continuation))
               ((memq escaped '(?\n ?\r))
                (skip-line-continuation))
               (t
                (agent-scheme--advance reader)
                (emit (agent-scheme--mnemonic-escape reader escaped))))))
           (t
            (agent-scheme--advance reader)
            (emit char)))))
      (agent-scheme--advance reader)
      (apply #'string (nreverse result)))))

(defun agent-scheme--read-vertical-symbol-name (reader)
  "Read a vertical-bar symbol name from READER."
  (agent-scheme--advance reader)
  (let (result)
    (while (not (eq (agent-scheme--peek reader) ?|))
      (when (agent-scheme--eof-p reader)
        (agent-scheme--reader-error reader "unterminated vertical symbol"))
      (let ((char (agent-scheme--peek reader)))
        (cond
         ((eq char ?\\)
          (agent-scheme--advance reader)
          (let ((escaped (agent-scheme--peek reader)))
            (cond
             ((eq escaped ?x)
              (agent-scheme--advance reader)
              (push (agent-scheme--read-hex-escape reader) result))
             (t
              (agent-scheme--advance reader)
              (push (agent-scheme--mnemonic-escape reader escaped) result)))))
         (t
          (agent-scheme--advance reader)
          (push char result)))))
    (agent-scheme--advance reader)
    (let ((name (apply #'string (nreverse result))))
      (if (agent-scheme--reader-fold-case reader)
          (downcase name)
        name))))

(defun agent-scheme--char-in-string-p (char string)
  "Return non-nil if CHAR appears in STRING."
  (and char (not (null (cl-position char string)))))

(defun agent-scheme--ascii-letter-p (char)
  "Return non-nil if CHAR is an ASCII letter."
  (or (and (>= char ?a) (<= char ?z))
      (and (>= char ?A) (<= char ?Z))))

(defun agent-scheme--digit-value (char)
  "Return digit value of CHAR, or nil."
  (cond
   ((and (>= char ?0) (<= char ?9)) (- char ?0))
   ((and (>= char ?a) (<= char ?f)) (+ 10 (- char ?a)))
   ((and (>= char ?A) (<= char ?F)) (+ 10 (- char ?A)))
   (t nil)))

(defun agent-scheme--integer-gcd (left right)
  "Return the non-negative greatest common divisor of LEFT and RIGHT."
  (setq left (abs left))
  (setq right (abs right))
  (while (not (zerop right))
    (let ((next (% left right)))
      (setq left right)
      (setq right next)))
  left)

(defun agent-scheme--integer-power (base exponent)
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

(defun agent-scheme--normalize-rational-pair (numerator denominator)
  "Return normalized rational pair for NUMERATOR and DENOMINATOR."
  (when (zerop denominator)
    (error "zero denominator"))
  (when (< denominator 0)
    (setq numerator (- numerator))
    (setq denominator (- denominator)))
  (let ((divisor (agent-scheme--integer-gcd numerator denominator)))
    (cons (/ numerator divisor) (/ denominator divisor))))

(defun agent-scheme--make-canonical-integer (value &optional exactness radix)
  "Return a canonical integer number datum for VALUE."
  (let ((exactness (or exactness 'exact))
        (radix (or radix 10)))
    (agent-scheme--make-number
     (number-to-string value) exactness radix 'integer value)))

(defun agent-scheme--make-canonical-decimal (value &optional lexeme)
  "Return an inexact decimal number datum for VALUE."
  (agent-scheme--make-number
   (or lexeme (number-to-string value)) 'inexact 10 'decimal value))

(defun agent-scheme--make-canonical-rational
    (numerator denominator &optional exactness radix)
  "Return a normalized rational or integer datum."
  (let* ((pair (agent-scheme--normalize-rational-pair numerator denominator))
         (numerator (car pair))
         (denominator (cdr pair))
         (exactness (or exactness 'exact))
         (radix (or radix 10)))
    (if (= denominator 1)
        (agent-scheme--make-canonical-integer numerator exactness radix)
      (agent-scheme--make-number
       (format "%s/%s" numerator denominator)
       exactness
       radix
       'rational
       pair))))

(defun agent-scheme--make-canonical-infnan (kind)
  "Return an inexact infinity or NaN datum for KIND."
  (agent-scheme--make-number
   (pcase kind
     ('+inf.0 "+inf.0")
     ('-inf.0 "-inf.0")
     ('+nan.0 "+nan.0")
     (_ (error "unknown inexact special number: %S" kind)))
   'inexact 10 'infnan kind))

(defun agent-scheme--make-canonical-complex (real imaginary)
  "Return a complex number datum from REAL and IMAGINARY number datums."
  (let ((exactness (if (and (eq (agent-scheme-number-exactness real) 'exact)
                            (eq (agent-scheme-number-exactness imaginary)
                                'exact))
                       'exact
                     'inexact)))
    (agent-scheme--make-number nil exactness 10 'complex (cons real imaginary))))

(defun agent-scheme--number-zero-p (number)
  "Return non-nil if NUMBER is numerically zero."
  (and (agent-scheme-number-p number)
       (pcase (agent-scheme-number-kind number)
         ('integer (zerop (agent-scheme-number-value number)))
         ('rational (zerop (car (agent-scheme-number-value number))))
         ('decimal (zerop (agent-scheme-number-value number)))
         ('complex
          (and (agent-scheme--number-zero-p
                (car (agent-scheme-number-value number)))
               (agent-scheme--number-zero-p
                (cdr (agent-scheme-number-value number)))))
         (_ nil))))

(defun agent-scheme--number-negative-p (number)
  "Return non-nil if real NUMBER is negative."
  (pcase (agent-scheme-number-kind number)
    ('integer (< (agent-scheme-number-value number) 0))
    ('rational (< (car (agent-scheme-number-value number)) 0))
    ('decimal (< (agent-scheme-number-value number) 0))
    ('infnan (eq (agent-scheme-number-value number) '-inf.0))
    (_ nil)))

(defun agent-scheme--number-abs (number)
  "Return the absolute value of real NUMBER."
  (pcase (agent-scheme-number-kind number)
    ('integer
     (agent-scheme--make-canonical-integer
      (abs (agent-scheme-number-value number))
      (agent-scheme-number-exactness number)
      (agent-scheme-number-radix number)))
    ('rational
     (let ((value (agent-scheme-number-value number)))
       (agent-scheme--make-canonical-rational
        (abs (car value)) (cdr value)
        (agent-scheme-number-exactness number)
        (agent-scheme-number-radix number))))
    ('decimal
     (agent-scheme--make-canonical-decimal
      (abs (agent-scheme-number-value number))))
    ('infnan
     (pcase (agent-scheme-number-value number)
       ('-inf.0 (agent-scheme--make-canonical-infnan '+inf.0))
       (_ number)))
    (_ number)))

(defun agent-scheme--number->external (number)
  "Return canonical external representation for NUMBER."
  (pcase (agent-scheme-number-kind number)
    ('integer
     (number-to-string (agent-scheme-number-value number)))
    ('rational
     (let ((value (agent-scheme-number-value number)))
       (format "%s/%s" (car value) (cdr value))))
    ('decimal
     (let ((text (number-to-string (agent-scheme-number-value number))))
       (if (string-match-p "\\`[+-]?[0-9]+\\'" text)
           (concat text ".0")
         text)))
    ('infnan
     (pcase (agent-scheme-number-value number)
       ('+inf.0 "+inf.0")
       ('-inf.0 "-inf.0")
       ('+nan.0 "+nan.0")))
    ('complex
     (let* ((value (agent-scheme-number-value number))
            (real (car value))
            (imaginary (cdr value))
            (negative (agent-scheme--number-negative-p imaginary))
            (magnitude (agent-scheme--number-abs imaginary)))
        (concat
         (agent-scheme--number->external real)
        (if negative "-" "+")
         (agent-scheme--number->external magnitude)
         "i")))
    (_
     (or (agent-scheme-number-lexeme number)
         (error "cannot write unknown number kind: %S"
                (agent-scheme-number-kind number))))))

(defun agent-scheme--initial-char-p (char)
  "Return non-nil if CHAR can begin an ordinary identifier."
  (or (agent-scheme--ascii-letter-p char)
      (> char 127)
      (agent-scheme--char-in-string-p char "!$%&*/:<=>?@^_~")))

(defun agent-scheme--subsequent-char-p (char)
  "Return non-nil if CHAR can continue an identifier."
  (or (agent-scheme--initial-char-p char)
      (and (>= char ?0) (<= char ?9))
      (agent-scheme--char-in-string-p char "+-.@")))

(defun agent-scheme--sign-subsequent-char-p (char)
  "Return non-nil if CHAR can follow an identifier sign."
  (or (agent-scheme--initial-char-p char)
      (agent-scheme--char-in-string-p char "+-@")))

(defun agent-scheme--dot-subsequent-char-p (char)
  "Return non-nil if CHAR can follow an identifier dot."
  (or (agent-scheme--sign-subsequent-char-p char)
      (eq char ?.)))

(defun agent-scheme--all-chars-p (string start predicate)
  "Return non-nil if all STRING chars from START satisfy PREDICATE."
  (let ((index start)
        (ok t))
    (while (and ok (< index (length string)))
      (setq ok (funcall predicate (aref string index)))
      (cl-incf index))
    ok))

(defun agent-scheme--identifier-token-p (token)
  "Return non-nil if TOKEN is an R7RS identifier token."
  (let ((length (length token)))
    (cond
     ((= length 0) nil)
     ((string= token ".") nil)
     ((member token '("+" "-")) t)
     ((agent-scheme--initial-char-p (aref token 0))
      (agent-scheme--all-chars-p
       token 1 #'agent-scheme--subsequent-char-p))
     ((and (memq (aref token 0) '(?+ ?-))
           (> length 1)
           (agent-scheme--sign-subsequent-char-p (aref token 1)))
      (agent-scheme--all-chars-p
       token 2 #'agent-scheme--subsequent-char-p))
     ((and (memq (aref token 0) '(?+ ?-))
           (> length 2)
           (eq (aref token 1) ?.)
           (agent-scheme--dot-subsequent-char-p (aref token 2)))
      (agent-scheme--all-chars-p
       token 3 #'agent-scheme--subsequent-char-p))
     ((and (eq (aref token 0) ?.)
           (> length 1)
           (agent-scheme--dot-subsequent-char-p (aref token 1)))
      (agent-scheme--all-chars-p
       token 2 #'agent-scheme--subsequent-char-p))
     (t nil))))

(defun agent-scheme--parse-unsigned-integer (digits radix)
  "Parse DIGITS in RADIX, or return nil when invalid."
  (when (> (length digits) 0)
    (let ((value 0)
          (index 0)
          (ok t))
      (while (and ok (< index (length digits)))
        (let ((digit (agent-scheme--digit-value (aref digits index))))
          (if (and digit (< digit radix))
              (setq value (+ (* value radix) digit))
            (setq ok nil)))
        (cl-incf index))
      (when ok value))))

(defun agent-scheme--parse-signed-integer (body radix)
  "Parse signed integer BODY in RADIX, or return nil."
  (let ((sign 1))
    (when (and (> (length body) 0) (memq (aref body 0) '(?+ ?-)))
      (when (eq (aref body 0) ?-)
        (setq sign -1))
      (setq body (substring body 1)))
    (let ((value (agent-scheme--parse-unsigned-integer body radix)))
      (when value (* sign value)))))

(defun agent-scheme--number-prefix (reader token)
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
             (agent-scheme--reader-error
              reader "duplicate exactness prefix in number %s" token))
           (setq seen-exactness t)
           (setq exactness (if (eq marker ?e) 'exact 'inexact)))
          (?b
           (when seen-radix
             (agent-scheme--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 2))
          (?o
           (when seen-radix
             (agent-scheme--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 8))
          (?d
           (when seen-radix
             (agent-scheme--reader-error
              reader "duplicate radix prefix in number %s" token))
           (setq seen-radix t radix 10))
          (?x
           (when seen-radix
             (agent-scheme--reader-error
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

(defun agent-scheme--decimal-token-p (body)
  "Return non-nil if BODY is a decimal number token."
  (string-match-p
   "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][+-]?[0-9]+\\)?\\'"
   body))

(defun agent-scheme--parse-exact-decimal (body)
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
        (let* ((integer (or (agent-scheme--parse-unsigned-integer digits 10)
                            0))
               (scale (- exponent (length fraction))))
          (if (>= scale 0)
              (cons (* sign integer (agent-scheme--integer-power 10 scale)) 1)
            (cons (* sign integer)
                  (agent-scheme--integer-power 10 (- scale)))))))))

(defun agent-scheme--parse-real-number-body
    (reader token body exactness radix)
  "Parse real numeric BODY using TOKEN, EXACTNESS, and RADIX."
  (cond
   ((member (downcase body) '("+inf.0" "-inf.0" "+nan.0" "-nan.0"))
    (when (eq exactness 'exact)
      (agent-scheme--reader-error
       reader "infinite and NaN literals cannot be exact: %s" token))
    (agent-scheme--make-canonical-infnan
     (pcase (downcase body)
       ("+inf.0" '+inf.0)
       ("-inf.0" '-inf.0)
       (_ '+nan.0))))
   ((agent-scheme--parse-signed-integer body radix)
    (let ((value (agent-scheme--parse-signed-integer body radix)))
      (if (eq exactness 'inexact)
          (agent-scheme--make-canonical-decimal (float value))
        (agent-scheme--make-canonical-integer value 'exact radix))))
   ((and (string-match-p "\\`[+-]?[[:xdigit:]]+/[[:xdigit:]]+\\'" body)
         (let* ((parts (split-string body "/"))
                (denominator
                 (agent-scheme--parse-unsigned-integer (cadr parts) radix)))
           (and denominator (not (= denominator 0))
                (agent-scheme--parse-signed-integer (car parts) radix))))
    (let* ((parts (split-string body "/"))
           (numerator
            (agent-scheme--parse-signed-integer (car parts) radix))
           (denominator
            (agent-scheme--parse-unsigned-integer (cadr parts) radix)))
      (if (eq exactness 'inexact)
          (agent-scheme--make-canonical-decimal
           (/ (float numerator) denominator))
        (agent-scheme--make-canonical-rational
         numerator denominator 'exact radix))))
   ((and (= radix 10) (agent-scheme--decimal-token-p body))
    (if (eq exactness 'exact)
        (let ((value (agent-scheme--parse-exact-decimal body)))
          (agent-scheme--make-canonical-rational (car value) (cdr value)))
      (agent-scheme--make-canonical-decimal (string-to-number body) body)))
   ((string-match-p "\\`[+-]?[0-9A-Fa-f]+/[0-9A-Fa-f]+\\'" body)
    (agent-scheme--reader-error reader "invalid rational number %s" token))
   (t nil)))

(defun agent-scheme--complex-split-index (body)
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

(defun agent-scheme--parse-complex-number-body
    (reader token body exactness radix)
  "Parse complex numeric BODY using TOKEN, EXACTNESS, and RADIX."
  (let ((lower (downcase body)))
    (cond
     ((and (= radix 10) (string-suffix-p "i" lower))
      (let* ((rectangular (substring body 0 -1))
             (split (agent-scheme--complex-split-index rectangular))
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
                 (agent-scheme--parse-real-number-body
                  reader token real-body exactness radix))
                (imaginary
                 (agent-scheme--parse-real-number-body
                  reader token imaginary-body exactness radix)))
            (when (and real imaginary)
              (agent-scheme--make-canonical-complex real imaginary))))))
     ((and (= radix 10) (string-match-p "@" body))
      (let* ((parts (split-string body "@"))
             (magnitude
              (and (= (length parts) 2)
                   (agent-scheme--parse-real-number-body
                    reader token (car parts) exactness radix)))
             (angle
              (and (= (length parts) 2)
                   (agent-scheme--parse-real-number-body
                    reader token (cadr parts) exactness radix))))
        (when (and magnitude angle)
          (let ((r (string-to-number
                    (agent-scheme--number->external
                     (if (eq (agent-scheme-number-kind magnitude) 'rational)
                         (agent-scheme--make-canonical-decimal
                          (/ (float (car (agent-scheme-number-value magnitude)))
                             (cdr (agent-scheme-number-value magnitude))))
                       magnitude))))
                (theta (string-to-number
                        (agent-scheme--number->external
                         (if (eq (agent-scheme-number-kind angle) 'rational)
                             (agent-scheme--make-canonical-decimal
                              (/ (float (car (agent-scheme-number-value angle)))
                                 (cdr (agent-scheme-number-value angle))))
                           angle)))))
            (agent-scheme--make-canonical-complex
             (agent-scheme--make-canonical-decimal (* r (cos theta)))
             (agent-scheme--make-canonical-decimal (* r (sin theta))))))))
     (t nil))))

(defun agent-scheme--parse-number-token (reader token)
  "Return number datum for TOKEN, or nil if TOKEN is not a number."
  (let* ((prefix (agent-scheme--number-prefix reader token))
         (body (car prefix))
         (exactness (cadr prefix))
         (radix (or (caddr prefix) 10))
         (lower-body (and body (downcase body))))
    (when (and prefix (> (length body) 0))
      (or (agent-scheme--parse-real-number-body
           reader token body exactness radix)
          (agent-scheme--parse-complex-number-body
           reader token lower-body exactness radix)))))

(defun agent-scheme--read-character (reader)
  "Read a character datum from READER after `#\\'."
  (agent-scheme--advance reader 2)
  (when (agent-scheme--eof-p reader)
    (agent-scheme--reader-error reader "missing character after #\\"))
  (let ((token (agent-scheme--read-token reader)))
    (when (= (length token) 0)
      (agent-scheme--reader-error reader "missing character after #\\"))
    (let* ((name (if (agent-scheme--reader-fold-case reader)
                     (downcase token)
                   token))
           (code
            (cond
             ((and (> (length token) 1)
                   (memq (aref token 0) '(?x ?X)))
              (agent-scheme--hex-scalar-to-char reader (substring token 1)))
             ((assoc name agent-scheme--character-names)
              (cdr (assoc name agent-scheme--character-names)))
             ((= (length token) 1)
              (aref token 0))
             (t
              (agent-scheme--reader-error
               reader "unknown character literal #\\%s" token)))))
      (agent-scheme--make-character code))))

(defun agent-scheme--read-list (reader depth)
  "Read a list datum from READER at DEPTH."
  (agent-scheme--check-depth reader depth)
  (agent-scheme--advance reader)
  (let ((head nil)
        (tail nil)
        (count 0)
        done)
    (while (not done)
      (agent-scheme--skip-intertoken-space reader depth)
      (cond
       ((agent-scheme--eof-p reader)
        (agent-scheme--reader-error reader "unterminated list"))
       ((eq (agent-scheme--peek reader) ?\))
        (agent-scheme--advance reader)
        (setq done t))
       (t
        (let ((saved (agent-scheme--reader-position reader)))
          ;; A period is dotted-pair syntax only when it is a delimited token;
          ;; otherwise it belongs to the ordinary token being read below.
          (if (and (eq (agent-scheme--peek reader) ?.)
                   (progn
                     (agent-scheme--advance reader)
                     (agent-scheme--delimiter-p (agent-scheme--peek reader))))
              (progn
                (unless tail
                  (agent-scheme--reader-error reader "dot before list element"))
                (agent-scheme--skip-intertoken-space reader depth)
                (setcdr tail (agent-scheme--read-datum reader (1+ depth)))
                (agent-scheme--skip-intertoken-space reader depth)
                (unless (eq (agent-scheme--peek reader) ?\))
                  (agent-scheme--reader-error
                   reader "expected closing parenthesis after dotted tail"))
                (agent-scheme--advance reader)
                (setq done t))
            (setf (agent-scheme--reader-position reader) saved)
            (let ((datum (agent-scheme--read-datum reader (1+ depth))))
              (cl-incf count)
              (when (> count (agent-scheme--reader-maximum-list-length reader))
                (agent-scheme--limit-error
                 reader
                 "list length exceeds maximum list length %d"
                 (agent-scheme--reader-maximum-list-length reader)))
              (let ((cell (cons datum nil)))
                (if tail
                    (setcdr tail cell)
                  (setq head cell))
                (setq tail cell))))))))
    (agent-scheme--note-node reader)
    head))

(defun agent-scheme--read-vector-elements
    (reader depth kind close-char maximum-length)
  "Read sequence elements for vector-like KIND until CLOSE-CHAR.
Signal if the sequence exceeds MAXIMUM-LENGTH."
  (agent-scheme--check-depth reader depth)
  (let ((items nil)
        (count 0)
        done)
    (while (not done)
      (agent-scheme--skip-intertoken-space reader depth)
      (cond
       ((agent-scheme--eof-p reader)
        (agent-scheme--reader-error reader "unterminated %s" kind))
       ((eq (agent-scheme--peek reader) close-char)
        (agent-scheme--advance reader)
        (setq done t))
       ((eq (agent-scheme--peek reader) ?.)
        (agent-scheme--reader-error reader "dot is not allowed in %s" kind))
       (t
        (push (agent-scheme--read-datum reader (1+ depth)) items)
        (cl-incf count)
        (when (> count maximum-length)
          (agent-scheme--limit-error
           reader
           "%s length exceeds maximum %s length %d"
           kind
           kind
           maximum-length)))))
    (nreverse items)))

(defun agent-scheme--read-vector (reader depth)
  "Read a vector datum from READER."
  (agent-scheme--advance reader 2)
  (let ((items
         (agent-scheme--read-vector-elements
          reader
          depth
          "vector"
          ?\)
          (agent-scheme--reader-maximum-vector-length reader))))
    (agent-scheme--note-node reader)
    (vconcat items)))

(defun agent-scheme--exact-integer-value (datum)
  "Return DATUM's exact integer value, or nil."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-kind datum) 'integer)
       (eq (agent-scheme-number-exactness datum) 'exact)
       (agent-scheme-number-value datum)))

(defun agent-scheme--read-bytevector (reader depth)
  "Read a bytevector datum from READER."
  (agent-scheme--advance reader 4)
  (let* ((items (agent-scheme--read-vector-elements
                 reader
                 depth
                 "bytevector"
                 ?\)
                 (agent-scheme--reader-maximum-bytevector-length reader)))
         (bytes nil))
    (dolist (item items)
      (let ((byte (agent-scheme--exact-integer-value item)))
        (unless (and byte (<= 0 byte 255))
          (agent-scheme--reader-error
           reader "bytevector element is not an exact byte: %s"
           (agent-scheme-datum->external item)))
        (push byte bytes)))
    (agent-scheme--note-node reader)
    (agent-scheme--make-bytevector (vconcat (nreverse bytes)))))

(defun agent-scheme--quote-datum (name datum)
  "Return abbreviation NAME wrapping DATUM."
  (cons (agent-scheme--intern-symbol name) (cons datum nil)))

(defun agent-scheme--classify-token (reader token)
  "Classify TOKEN as a Scheme simple datum."
  (cond
   ((member token '("#t" "#true"))
    agent-scheme-true)
   ((member token '("#f" "#false"))
    agent-scheme-false)
   ((agent-scheme--parse-number-token reader token))
   ((agent-scheme--identifier-token-p token)
    (agent-scheme--intern-symbol
     (if (agent-scheme--reader-fold-case reader)
         (downcase token)
       token)))
   ((string= token ".")
    (agent-scheme--reader-error reader "unexpected dot"))
   (t
    (agent-scheme--reader-error reader "invalid token %s" token))))

(defun agent-scheme--read-dispatch (reader depth)
  "Read a datum beginning with # from READER."
  (cond
   ((agent-scheme--starts-with-p reader "#(")
    (agent-scheme--read-vector reader depth))
   ((agent-scheme--starts-with-p reader "#u8(")
    (agent-scheme--read-bytevector reader depth))
   ((agent-scheme--starts-with-p reader "#\\")
    (agent-scheme--read-character reader))
   ((and (agent-scheme--peek reader 1)
         (>= (agent-scheme--peek reader 1) ?0)
         (<= (agent-scheme--peek reader 1) ?9))
    (agent-scheme--reader-error
     reader "datum labels are not supported yet"))
   (t
    (agent-scheme--classify-token reader (agent-scheme--read-token reader)))))

(defun agent-scheme--read-datum (reader depth)
  "Read one datum from READER at DEPTH."
  (agent-scheme--check-depth reader depth)
  (agent-scheme--skip-intertoken-space reader depth)
  (when (agent-scheme--eof-p reader)
    (agent-scheme--reader-error reader "unexpected end of input"))
  (let ((char (agent-scheme--peek reader))
        datum)
    (setq datum
          (cond
           ((eq char ?\()
            (agent-scheme--read-list reader (1+ depth)))
           ((eq char ?\))
            (agent-scheme--reader-error reader "unexpected closing parenthesis"))
           ((eq char ?\")
            (prog1 (agent-scheme--read-string reader)
              (agent-scheme--note-node reader)))
           ((eq char ?\|)
            (prog1
                (agent-scheme--intern-symbol
                 (agent-scheme--read-vertical-symbol-name reader))
              (agent-scheme--note-node reader)))
           ((eq char ?\')
            (agent-scheme--advance reader)
            (prog1
                (agent-scheme--quote-datum
                 "quote" (agent-scheme--read-datum reader (1+ depth)))
              (agent-scheme--note-node reader)))
           ((eq char ?`)
            (agent-scheme--advance reader)
            (prog1
                (agent-scheme--quote-datum
                 "quasiquote" (agent-scheme--read-datum reader (1+ depth)))
              (agent-scheme--note-node reader)))
           ((eq char ?,)
            (agent-scheme--advance reader)
            (if (eq (agent-scheme--peek reader) ?@)
                (progn
                  (agent-scheme--advance reader)
                  (prog1
                      (agent-scheme--quote-datum
                       "unquote-splicing"
                       (agent-scheme--read-datum reader (1+ depth)))
                    (agent-scheme--note-node reader)))
              (prog1
                  (agent-scheme--quote-datum
                   "unquote" (agent-scheme--read-datum reader (1+ depth)))
                (agent-scheme--note-node reader))))
           ((eq char ?#)
            (prog1 (agent-scheme--read-dispatch reader (1+ depth))
              (agent-scheme--note-node reader)))
           (t
            (prog1 (agent-scheme--classify-token
                    reader (agent-scheme--read-token reader))
              (agent-scheme--note-node reader)))))
    datum))

;;;###autoload
(defun agent-scheme-read (source &optional options)
  "Read one R7RS datum from SOURCE.

SOURCE may be a string or buffer.  OPTIONS is a plist supporting
`:max-depth', `:max-list-length', `:max-vector-length',
`:max-bytevector-length', `:max-string-size', and
`:max-total-nodes'.  The whole SOURCE must contain exactly one
datum, apart from intertoken space and comments."
  (let ((reader (agent-scheme--new-reader source options)))
    (let ((datum (agent-scheme--read-datum reader 0)))
      (agent-scheme--skip-intertoken-space reader 0)
      (unless (agent-scheme--eof-p reader)
        (agent-scheme--reader-error reader "unexpected trailing input"))
      (agent-scheme-validate-datum datum options)
      datum)))

;;;###autoload
(defun agent-scheme-read-all (source &optional options)
  "Read all R7RS datums from SOURCE.

SOURCE may be a string or buffer.  OPTIONS has the same shape as
`agent-scheme-read'."
  (let ((reader (agent-scheme--new-reader source options))
        datums)
    (agent-scheme--skip-intertoken-space reader 0)
    (while (not (agent-scheme--eof-p reader))
      (push (agent-scheme--read-datum reader 0) datums)
      (agent-scheme--skip-intertoken-space reader 0))
    (setq datums (nreverse datums))
    (dolist (datum datums)
      (agent-scheme-validate-datum datum options))
    datums))

(defun agent-scheme--validate-note-node (reader)
  "Record one validated datum node in READER."
  (agent-scheme--note-node reader))

(defun agent-scheme--validate-datum (datum reader depth seen)
  "Validate DATUM using READER limits at DEPTH.
SEEN prevents infinite recursion over host-created cycles."
  (agent-scheme--check-depth reader depth)
  (cond
   ((null datum)
    (agent-scheme--validate-note-node reader))
   ((or (agent-scheme-boolean-p datum)
        (agent-scheme-symbol-p datum)
        (agent-scheme-character-p datum)
        (agent-scheme-number-p datum))
    (agent-scheme--validate-note-node reader))
   ((stringp datum)
    (when (> (length datum) (agent-scheme--reader-maximum-string-size reader))
      (agent-scheme--limit-error
       reader
       "string size exceeds maximum string size %d"
       (agent-scheme--reader-maximum-string-size reader)))
    (agent-scheme--validate-note-node reader))
   ((agent-scheme-bytevector-p datum)
    (when (> (length (agent-scheme-bytevector-bytes datum))
             (agent-scheme--reader-maximum-bytevector-length reader))
      (agent-scheme--limit-error
       reader
       "bytevector length exceeds maximum bytevector length %d"
       (agent-scheme--reader-maximum-bytevector-length reader)))
    (cl-loop for byte across (agent-scheme-bytevector-bytes datum)
             unless (and (integerp byte) (<= 0 byte 255))
             do (agent-scheme--reader-error
                 reader "bytevector contains invalid byte %S" byte))
    (agent-scheme--validate-note-node reader))
   ((consp datum)
    (unless (gethash datum seen)
      (puthash datum t seen)
      (let ((cursor datum)
            (count 0))
        (while (consp cursor)
          (cl-incf count)
          (when (> count (agent-scheme--reader-maximum-list-length reader))
            (agent-scheme--limit-error
             reader
             "list length exceeds maximum list length %d"
             (agent-scheme--reader-maximum-list-length reader)))
          (agent-scheme--validate-note-node reader)
          (agent-scheme--validate-datum (car cursor) reader (1+ depth) seen)
          (setq cursor (cdr cursor)))
        (when cursor
          (agent-scheme--validate-datum cursor reader (1+ depth) seen)))))
   ((vectorp datum)
    (unless (gethash datum seen)
      (puthash datum t seen)
      (when (> (length datum) (agent-scheme--reader-maximum-vector-length reader))
        (agent-scheme--limit-error
         reader
         "vector length exceeds maximum vector length %d"
         (agent-scheme--reader-maximum-vector-length reader)))
      (agent-scheme--validate-note-node reader)
      (cl-loop for item across datum
               do (agent-scheme--validate-datum item reader (1+ depth) seen))))
   (t
    (agent-scheme--reader-error
     reader "datum contains unsupported host object %S" datum))))

;;;###autoload
(defun agent-scheme-validate-datum (datum &optional options)
  "Validate that DATUM is an Agent Scheme implementation datum.

OPTIONS has the same resource limit shape as `agent-scheme-read'.
Return DATUM on success and signal `agent-scheme-reader-error' on
invalid host objects or `agent-scheme-datum-limit-error' on limit
failures."
  (let ((reader (agent-scheme--new-reader "" options)))
    (agent-scheme--validate-datum datum reader 0 (make-hash-table :test #'eq))
    datum))

(defun agent-scheme--escape-string (string)
  "Return R7RS escaped spelling for STRING contents."
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
                   (?| "\\|")
                   (_ (string char)))
                 result))
    (mapconcat #'identity (nreverse result) "")))

(defun agent-scheme--symbol-needs-bars-p (name)
  "Return non-nil if NAME should be written with vertical bars."
  (or (not (agent-scheme--identifier-token-p name))
      (agent-scheme--parse-number-token (agent-scheme--new-reader "" nil) name)))

(defun agent-scheme--write-symbol-name (name)
  "Return external representation of Scheme symbol NAME."
  (if (agent-scheme--symbol-needs-bars-p name)
      (concat "|" (agent-scheme--escape-string name) "|")
    name))

(defun agent-scheme--write-character (code)
  "Return external representation of character CODE."
  (let ((name (car (rassoc code agent-scheme--character-names))))
    (cond
     (name (concat "#\\" name))
     ((or (< code 33) (= code 127))
      (format "#\\x%x" code))
     (t (concat "#\\" (string code))))))

(defun agent-scheme--write-list (datum)
  "Return external representation of list or pair DATUM."
  (let ((parts nil)
        (cursor datum))
    (while (consp cursor)
      (push (agent-scheme-datum->external (car cursor)) parts)
      (setq cursor (cdr cursor)))
    (concat
     "("
     (mapconcat #'identity (nreverse parts) " ")
     (if cursor
         (concat (if parts " . " ". ")
                 (agent-scheme-datum->external cursor))
       "")
     ")")))

;;;###autoload
(defun agent-scheme-datum->external (datum)
  "Return a simple external representation for DATUM.
This writer is for current implementation datums and intentionally
does not yet implement shared or circular datum labels."
  (cond
   ((eq datum agent-scheme-true) "#t")
   ((eq datum agent-scheme-false) "#f")
   ((null datum) "()")
   ((agent-scheme-symbol-p datum)
    (agent-scheme--write-symbol-name (agent-scheme-symbol-name datum)))
   ((agent-scheme-character-p datum)
    (agent-scheme--write-character (agent-scheme-character-code datum)))
   ((agent-scheme-number-p datum)
    (agent-scheme--number->external datum))
   ((stringp datum)
    (concat "\"" (agent-scheme--escape-string datum) "\""))
   ((agent-scheme-bytevector-p datum)
    (concat
     "#u8("
     (mapconcat #'number-to-string
                (append (agent-scheme-bytevector-bytes datum) nil)
                " ")
     ")"))
   ((consp datum)
    (agent-scheme--write-list datum))
   ((vectorp datum)
    (concat
     "#("
     (mapconcat #'agent-scheme-datum->external (append datum nil) " ")
     ")"))
   (t
    (signal 'agent-scheme-reader-error
            (list (format "cannot write unsupported datum %S" datum))))))

(provide 'agent-scheme-reader)

;;; agent-scheme-reader.el ends here
