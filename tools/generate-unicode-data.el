;;; generate-unicode-data.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Generate the portable Scheme Unicode table library from the pinned Unicode
;; Character Database inputs under vendor/unicode/17.0.0.  The checked-in
;; output is deterministic and can be verified with --check.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst consent--unicode-data-version "17.0.0"
  "Pinned Unicode Character Database version.")

(defconst consent--unicode-index-bucket-count 272
  "Number of BMP-page and supplementary-plane lookup buckets.")

(defconst consent--unicode-input-hashes
  '(("CaseFolding.txt"
     . "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183")
    ("DerivedCoreProperties.txt"
     . "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08")
    ("PropList.txt"
     . "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd")
    ("SpecialCasing.txt"
     . "efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588")
    ("UnicodeData.txt"
     . "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"))
  "Expected SHA-256 hashes for the pinned UCD inputs.")

(defun consent--unicode-file-lines (path)
  "Return the text lines in PATH."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (split-string (buffer-string) "\n" t)))

(defun consent--unicode-file-sha256 (path)
  "Return the lowercase SHA-256 digest of PATH."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun consent--unicode-input-path (directory name)
  "Return NAME beneath UCD input DIRECTORY."
  (expand-file-name name directory))

(defun consent--unicode-verify-inputs (directory)
  "Verify pinned UCD files beneath DIRECTORY."
  (dolist (entry consent--unicode-input-hashes)
    (let* ((name (car entry))
           (expected (cdr entry))
           (path (consent--unicode-input-path directory name)))
      (unless (file-readable-p path)
        (error "Missing Unicode input: %s" path))
      (let ((actual (consent--unicode-file-sha256 path)))
        (unless (string= actual expected)
          (error "Unicode input hash mismatch for %s: expected %s, got %s"
                 name expected actual))))))

(defun consent--unicode-data-text (line)
  "Return LINE without its UCD comment and surrounding whitespace."
  (string-trim (car (split-string line "#"))))

(defun consent--unicode-hex (text)
  "Parse hexadecimal integer TEXT."
  (string-to-number text 16))

(defun consent--unicode-hex-sequence (text)
  "Parse a whitespace-separated hexadecimal sequence from TEXT."
  (mapcar #'consent--unicode-hex
          (split-string (string-trim text) "[[:space:]]+" t)))

(defun consent--unicode-code-range (text)
  "Parse one UCD code-point range from TEXT."
  (let ((trimmed (string-trim text)))
    (if (string-match
         "\\`\\([0-9A-F]+\\)\\(?:\\.\\.\\([0-9A-F]+\\)\\)?\\'"
         trimmed)
        (let ((lower (consent--unicode-hex (match-string 1 trimmed)))
              (upper (match-string 2 trimmed)))
          (cons lower (if upper (consent--unicode-hex upper) lower)))
      (error "Invalid Unicode code-point range: %s" text))))

(defun consent--unicode-merge-ranges (ranges)
  "Return sorted, overlapping or adjacent RANGES merged."
  (let ((sorted (sort (copy-tree ranges)
                      (lambda (left right) (< (car left) (car right)))))
        result)
    (dolist (range sorted)
      (let ((previous (car result)))
        (if (and previous (<= (car range) (1+ (cdr previous))))
            (setcdr previous (max (cdr previous) (cdr range)))
          (push (cons (car range) (cdr range)) result))))
    (nreverse result)))

(defun consent--unicode-property-ranges (path property)
  "Read PROPERTY ranges from the UCD file at PATH."
  (let (ranges)
    (dolist (line (consent--unicode-file-lines path))
      (let ((text (consent--unicode-data-text line)))
        (when (and (not (string-empty-p text))
                   (string-match
                    "\\`\\([^;]+\\);[[:space:]]*\\([^[:space:]]+\\)"
                    text)
                   (string= (match-string 2 text) property))
          (push (consent--unicode-code-range (match-string 1 text))
                ranges))))
    (consent--unicode-merge-ranges ranges)))

(defun consent--unicode-put-single-mapping (table source text)
  "Store SOURCE's single-code-point mapping from TEXT in TABLE."
  (unless (string-empty-p (string-trim text))
    (let ((mapping (consent--unicode-hex-sequence text)))
      (unless (= (length mapping) 1)
        (error "Expected a single Unicode mapping for U+%04X" source))
      (puthash source mapping table))))

(defun consent--unicode-parse-unicode-data (path)
  "Return decimal, uppercase, and lowercase tables parsed from PATH."
  (let ((digits (make-hash-table :test #'eql))
        (uppercase (make-hash-table :test #'eql))
        (lowercase (make-hash-table :test #'eql)))
    (dolist (line (consent--unicode-file-lines path))
      (let ((fields (split-string line ";" nil)))
        (unless (= (length fields) 15)
          (error "UnicodeData.txt row has %d fields" (length fields)))
        (let ((code (consent--unicode-hex (nth 0 fields))))
          (unless (string-empty-p (nth 6 fields))
            (puthash code (string-to-number (nth 6 fields)) digits))
          (consent--unicode-put-single-mapping uppercase code
                                                 (nth 12 fields))
          (consent--unicode-put-single-mapping lowercase code
                                                 (nth 13 fields)))))
    (list digits uppercase lowercase)))

(defun consent--unicode-copy-table (table)
  "Return a shallow copy of hash TABLE and its list values."
  (let ((copy (make-hash-table :test #'eql)))
    (maphash (lambda (key value) (puthash key (copy-sequence value) copy))
             table)
    copy))

(defun consent--unicode-mapping-overrides (table fallback)
  "Return TABLE mappings that differ from FALLBACK or identity."
  (let ((sources (make-hash-table :test #'eql))
        (overrides (make-hash-table :test #'eql)))
    (maphash (lambda (source _mapping)
               (puthash source t sources))
             table)
    (maphash (lambda (source _mapping)
               (puthash source t sources))
             fallback)
    (maphash
     (lambda (source _present)
       (let ((mapping (or (gethash source table) (list source)))
             (fallback-mapping
              (or (gethash source fallback) (list source))))
         (unless (equal mapping fallback-mapping)
           (puthash source (copy-sequence mapping) overrides))))
     sources)
    overrides))

(defun consent--unicode-store-full-mapping (table source mapping)
  "Store SOURCE to MAPPING in TABLE, omitting identity mappings."
  (if (equal mapping (list source))
      (remhash source table)
    (puthash source mapping table)))

(defun consent--unicode-apply-special-casing (path lower upper)
  "Apply unconditional SpecialCasing PATH entries to LOWER and UPPER."
  (dolist (line (consent--unicode-file-lines path))
    (let ((text (consent--unicode-data-text line)))
      (unless (string-empty-p text)
        (let ((fields (split-string text ";" nil)))
          (unless (>= (length fields) 5)
            (error "SpecialCasing.txt row has %d fields" (length fields)))
          (when (string-empty-p (string-trim (nth 4 fields)))
            (let ((source (consent--unicode-hex (string-trim (nth 0 fields)))))
              (consent--unicode-store-full-mapping
               lower source (consent--unicode-hex-sequence (nth 1 fields)))
              (consent--unicode-store-full-mapping
               upper source (consent--unicode-hex-sequence
                             (nth 3 fields))))))))))

(defun consent--unicode-parse-case-folding (path)
  "Return simple and full default case-folding tables parsed from PATH."
  (let ((simple (make-hash-table :test #'eql))
        (full (make-hash-table :test #'eql)))
    (dolist (line (consent--unicode-file-lines path))
      (let ((text (consent--unicode-data-text line)))
        (unless (string-empty-p text)
          (let* ((fields (split-string text ";" nil))
                 (source (consent--unicode-hex
                          (string-trim (nth 0 fields))))
                 (status (string-trim (nth 1 fields)))
                 (mapping (consent--unicode-hex-sequence (nth 2 fields))))
            (when (member status '("C" "S"))
              (consent--unicode-store-full-mapping simple source mapping))
            (when (member status '("C" "F"))
              (consent--unicode-store-full-mapping full source mapping))))))
    (list simple full)))

(defun consent--unicode-table-entries (table)
  "Return TABLE entries sorted by integer key."
  (let (entries)
    (maphash (lambda (key value) (push (cons key value) entries)) table)
    (sort entries (lambda (left right) (< (car left) (car right))))))

(defun consent--unicode-index-bucket (code)
  "Return the generated lookup bucket containing CODE."
  (if (< code #x10000)
      (floor code #x100)
    (+ #xff (floor code #x10000))))

(defun consent--unicode-index-bucket-end (bucket)
  "Return the inclusive scalar ending lookup BUCKET."
  (if (< bucket #x100)
      (1- (* (+ bucket 1) #x100))
    (1- (* (- bucket #xfe) #x10000))))

(defun consent--unicode-split-ranges (ranges)
  "Split RANGES at generated lookup-bucket boundaries."
  (let (result)
    (dolist (range ranges)
      (let ((lower (car range))
            (upper (cdr range)))
        (while (<= lower upper)
          (let ((part-upper
                 (min upper
                      (consent--unicode-index-bucket-end
                       (consent--unicode-index-bucket lower)))))
            (push (cons lower part-upper) result)
            (setq lower (1+ part-upper))))))
    (nreverse result)))

(defun consent--unicode-bucket-index (entries source-function)
  "Return deterministic bucket offsets for sorted ENTRIES.
SOURCE-FUNCTION returns an entry's first code point."
  (let ((remaining entries)
        (offset 0)
        index)
    (dotimes (bucket consent--unicode-index-bucket-count)
      (push offset index)
      (while (and remaining
                  (= bucket
                     (consent--unicode-index-bucket
                      (funcall source-function (car remaining)))))
        (setq offset (1+ offset))
        (setq remaining (cdr remaining))))
    (when remaining
      (error "Unicode lookup entry falls outside the scalar buckets"))
    (nreverse (cons offset index))))

(defun consent--unicode-ranges-flat (ranges)
  "Return RANGES as a flat list of lower and upper bounds."
  (apply #'append
         (mapcar (lambda (range) (list (car range) (cdr range))) ranges)))

(defun consent--unicode-simple-mapping-segments (table)
  "Return sorted lower, upper, and delta segments for simple mapping TABLE."
  (let (segments current)
    (dolist (entry (consent--unicode-table-entries table))
      (unless (= (length (cdr entry)) 1)
        (error "Expected single mapping for U+%04X" (car entry)))
      (let* ((source (car entry))
             (delta (- (cadr entry) source)))
        (if (and current
                 (= source (1+ (nth 1 current)))
                 (= delta (nth 2 current))
                 (= (consent--unicode-index-bucket source)
                    (consent--unicode-index-bucket (car current))))
            (setcar (cdr current) source)
          (setq current (list source source delta))
          (push current segments))))
    (nreverse segments)))

(defun consent--unicode-segments-flat (segments)
  "Return mapping SEGMENTS as flat lower, upper, and delta integers."
  (apply #'append segments))

(defun consent--unicode-decimal-block-starts (table)
  "Return validated ten-code-point decimal block starts from TABLE."
  (let ((entries (consent--unicode-table-entries table))
        starts)
    (while entries
      (let ((start (caar entries)))
        (dotimes (value 10)
          (let ((entry (pop entries)))
            (unless (and entry
                         (= (car entry) (+ start value))
                         (= (cdr entry) value))
              (error "Malformed Unicode decimal block at U+%04X" start))))
        (push start starts)))
    (nreverse starts)))

(defun consent--unicode-scheme-hex (value)
  "Return VALUE as a lowercase Scheme hexadecimal integer."
  (format "#x%x" value))

(defun consent--unicode-insert-wrapped-tokens (tokens indentation)
  "Insert TOKENS wrapped at 79 columns with INDENTATION spaces."
  (let ((column indentation))
    (insert (make-string indentation ?\s))
    (dolist (token tokens)
      (let ((width (+ (length token) (if (= column indentation) 0 1))))
        (when (> (+ column width) 79)
          (insert "\n" (make-string indentation ?\s))
          (setq column indentation)
          (setq width (length token)))
        (unless (= column indentation)
          (insert " ")
          (setq column (1+ column)))
        (insert token)
        (setq column (+ column (length token)))))
    (insert "\n")))

(defun consent--unicode-insert-flat-vector (name description values)
  "Insert generated flat vector NAME with DESCRIPTION and VALUES."
  (insert "    ;; " description "\n"
          "    (define " name "\n"
          "      #(\n")
  (consent--unicode-insert-wrapped-tokens
   (mapcar #'consent--unicode-scheme-hex values) 8)
  (insert "        ))\n\n"))

(defun consent--unicode-entry-token (entry)
  "Return full Unicode mapping ENTRY as one Scheme vector token."
  (format "#(%s)"
          (mapconcat #'consent--unicode-scheme-hex
                     (cons (car entry) (cdr entry)) " ")))

(defun consent--unicode-insert-mapping-vector (name description table)
  "Insert generated full mapping vector NAME from TABLE."
  (insert "    ;; " description "\n"
          "    (define " name "\n"
          "      #(\n")
  (consent--unicode-insert-wrapped-tokens
   (mapcar #'consent--unicode-entry-token
           (consent--unicode-table-entries table))
   8)
  (insert "        ))\n\n"))

(defun consent--unicode-insert-counts (counts)
  "Insert runtime-visible structural COUNTS for generated private data."
  (insert "    ;; Expose representation counts without exporting mutable\n"
          "    ;; tables.\n"
          "    (define %unicode-data-counts\n"
          "      '(\n")
  (dolist (entry counts)
    (insert "        (" (symbol-name (car entry)) " "
            (number-to-string (cdr entry)) ")\n"))
  (insert "        ))\n\n"))

(defun consent--unicode-insert-query-procedures ()
  "Insert read-only procedures over the generated private data."
  (insert
   "    ;; Mutable aggregate data never crosses the library boundary.\n"
   "    (define (%copy-public-data value)\n"
   "      \"Return a fresh copy of mutable aggregate VALUE.\"\n"
   "      (cond\n"
   "       ((pair? value)\n"
   "        (cons (%copy-public-data (car value))\n"
   "              (%copy-public-data (cdr value))))\n"
   "       ((string? value) (string-copy value))\n"
   "       (else value)))\n\n"
   "    (define (consent-unicode-data-version)\n"
   "      \"Return a fresh list naming the pinned Unicode release.\"\n"
   "      #((parameters)\n"
   "        (returns (type list)\n"
   "         (description \"Three integers naming the Unicode release.\"))\n"
   "        (effects allocation))\n"
   "      (%copy-public-data %unicode-data-version))\n\n"
   "    (define (consent-unicode-data-metadata)\n"
   "      \"Return a fresh copy of Unicode data provenance metadata.\"\n"
   "      #((parameters)\n"
   "        (returns (type list)\n"
   "         (description \"Unicode release provenance metadata.\"))\n"
   "        (effects allocation))\n"
   "      (%copy-public-data %unicode-data-metadata))\n\n"
   "    (define (consent-unicode-data-counts)\n"
   "      \"Return a fresh copy of generated Unicode table counts.\"\n"
   "      #((parameters)\n"
   "        (returns (type list)\n"
   "         (description \"Names and sizes of generated Unicode tables.\"))\n"
   "        (effects allocation))\n"
   "      (%copy-public-data %unicode-data-counts))\n\n"
   "    ;; Resolve a BMP page or supplementary plane without host Unicode.\n"
   "    (define (%unicode-bucket code)\n"
   "      \"Return CODE's BMP-page or supplementary-plane bucket.\"\n"
   "      (cond\n"
   "       ((or (< code 0) (> code #x10ffff)) #f)\n"
   "       ((< code #x10000) (quotient code #x100))\n"
   "       (else (+ #xff (quotient code #x10000)))))\n\n"
   "    (define (%indexed-range-contains? table index code)\n"
   "      \"Return #t when CODE occurs in indexed range TABLE.\"\n"
   "      (let ((bucket (%unicode-bucket code)))\n"
   "        (and bucket\n"
   "             (let loop\n"
   "                 ((lower (vector-ref index bucket))\n"
   "                  (upper (- (vector-ref index (+ bucket 1)) 1)))\n"
   "               (if (> lower upper)\n"
   "                   #f\n"
   "                   (let* ((middle (quotient (+ lower upper) 2))\n"
   "                          (offset (* middle 2))\n"
   "                          (range-lower (vector-ref table offset))\n"
   "                          (range-upper\n"
   "                           (vector-ref table (+ offset 1))))\n"
   "                     (cond\n"
   "                      ((< code range-lower)\n"
   "                       (loop lower (- middle 1)))\n"
   "                      ((> code range-upper)\n"
   "                       (loop (+ middle 1) upper))\n"
   "                      (else #t))))))))\n\n"
   "    (define (%indexed-delta-ref table index code)\n"
   "      \"Return CODE mapped through indexed delta TABLE, or #f.\"\n"
   "      (let ((bucket (%unicode-bucket code)))\n"
   "        (and bucket\n"
   "             (let loop\n"
   "                 ((lower (vector-ref index bucket))\n"
   "                  (upper (- (vector-ref index (+ bucket 1)) 1)))\n"
   "               (if (> lower upper)\n"
   "                   #f\n"
   "                   (let* ((middle (quotient (+ lower upper) 2))\n"
   "                          (offset (* middle 3))\n"
   "                          (range-lower (vector-ref table offset))\n"
   "                          (range-upper\n"
   "                           (vector-ref table (+ offset 1))))\n"
   "                     (cond\n"
   "                      ((< code range-lower)\n"
   "                       (loop lower (- middle 1)))\n"
   "                      ((> code range-upper)\n"
   "                       (loop (+ middle 1) upper))\n"
   "                      (else\n"
   "                       (+ code (vector-ref table (+ offset 2)))))))))))\n\n"
   "    (define (%decimal-block-ref table code)\n"
   "      \"Return CODE's decimal-block value from TABLE, or #f.\"\n"
   "      (let loop ((lower 0) (upper (- (vector-length table) 1)))\n"
   "        (if (> lower upper)\n"
   "            #f\n"
   "            (let* ((middle (quotient (+ lower upper) 2))\n"
   "                   (start (vector-ref table middle)))\n"
   "              (cond\n"
   "               ((< code start) (loop lower (- middle 1)))\n"
   "               ((> code (+ start 9)) (loop (+ middle 1) upper))\n"
   "               (else (- code start)))))))\n\n"
   "    (define (%full-mapping-ref table code)\n"
   "      \"Return CODE's fresh full mapping from TABLE, or #f.\"\n"
   "      (let loop ((lower 0) (upper (- (vector-length table) 1)))\n"
   "        (if (> lower upper)\n"
   "            #f\n"
   "            (let* ((middle (quotient (+ lower upper) 2))\n"
   "                   (entry (vector-ref table middle))\n"
   "                   (source (vector-ref entry 0)))\n"
   "              (cond\n"
   "               ((< code source) (loop lower (- middle 1)))\n"
   "               ((> code source) (loop (+ middle 1) upper))\n"
   "               (else\n"
   "                (let copy ((position 1) (result '()))\n"
   "                  (if (= position (vector-length entry))\n"
   "                      (reverse result)\n"
   "                      (copy\n"
   "                       (+ position 1)\n"
   "                       (cons (vector-ref entry position)\n"
   "                             result))))))))))\n\n"
   "    (define (consent-unicode-alphabetic? code)\n"
   "      \"Return #t when CODE has the Unicode Alphabetic property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode Alphabetic.\"))\n"
   "        (effects pure))\n"
   "      (%indexed-range-contains?\n"
   "       %unicode-alphabetic-ranges %unicode-alphabetic-index code))\n\n"
   "    (define (consent-unicode-uppercase? code)\n"
   "      \"Return #t when CODE has the Unicode Uppercase property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode Uppercase.\"))\n"
   "        (effects pure))\n"
   "      (%indexed-range-contains?\n"
   "       %unicode-uppercase-ranges %unicode-uppercase-index code))\n\n"
   "    (define (consent-unicode-lowercase? code)\n"
   "      \"Return #t when CODE has the Unicode Lowercase property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode Lowercase.\"))\n"
   "        (effects pure))\n"
   "      (%indexed-range-contains?\n"
   "       %unicode-lowercase-ranges %unicode-lowercase-index code))\n\n"
   "    (define (consent-unicode-whitespace? code)\n"
   "      \"Return #t when CODE has the Unicode White_Space property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode White_Space.\"))\n"
   "        (effects pure))\n"
   "      (%indexed-range-contains?\n"
   "       %unicode-whitespace-ranges %unicode-whitespace-index code))\n\n"
   "    (define (consent-unicode-decimal-value code)\n"
   "      \"Return CODE's decimal digit value, or #f.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to inspect.\")))\n"
   "        (returns (type (or exact-integer boolean))\n"
   "         (description \"Decimal value from zero through nine, or #f.\"))\n"
   "        (effects pure))\n"
   "      (%decimal-block-ref %unicode-decimal-block-starts code))\n\n"
   "    (define (consent-unicode-simple-uppercase code)\n"
   "      \"Return CODE's simple Unicode uppercase mapping.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type exact-integer)\n"
   "         (description \"Simple uppercase scalar value.\"))\n"
   "        (effects pure))\n"
   "      (or (%indexed-delta-ref\n"
   "           %unicode-simple-uppercase-segments\n"
   "           %unicode-simple-uppercase-index code)\n"
   "          code))\n\n"
   "    (define (consent-unicode-simple-lowercase code)\n"
   "      \"Return CODE's simple Unicode lowercase mapping.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type exact-integer)\n"
   "         (description \"Simple lowercase scalar value.\"))\n"
   "        (effects pure))\n"
   "      (or (%indexed-delta-ref\n"
   "           %unicode-simple-lowercase-segments\n"
   "           %unicode-simple-lowercase-index code)\n"
   "          code))\n\n"
   "    (define (consent-unicode-simple-foldcase code)\n"
   "      \"Return CODE's simple Unicode case-folding mapping.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type exact-integer)\n"
   "         (description \"Simple case-folded scalar value.\"))\n"
   "        (effects pure))\n"
   "      (or (%indexed-delta-ref\n"
   "           %unicode-simple-foldcase-segments\n"
   "           %unicode-simple-foldcase-index code)\n"
   "          code))\n\n"
   "    (define (consent-unicode-full-uppercase code)\n"
   "      \"Return CODE's full Unicode uppercase mapping as a fresh list.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type list)\n"
   "         (description \"Fresh list of full uppercase scalar values.\"))\n"
   "        (effects allocation))\n"
   "      (or (%full-mapping-ref %unicode-full-uppercase-overrides code)\n"
   "          (list (consent-unicode-simple-uppercase code))))\n\n"
   "    (define (consent-unicode-full-lowercase code)\n"
   "      \"Return CODE's full Unicode lowercase mapping as a fresh list.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type list)\n"
   "         (description \"Fresh list of full lowercase scalar values.\"))\n"
   "        (effects allocation))\n"
   "      (or (%full-mapping-ref %unicode-full-lowercase-overrides code)\n"
   "          (list (consent-unicode-simple-lowercase code))))\n\n"
   "    (define (consent-unicode-full-foldcase code)\n"
   "      \"Return CODE's full case-folding mapping as a fresh list.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type list)\n"
   "         (description \"Fresh list of full case-folded scalar values.\"))\n"
   "        (effects allocation))\n"
   "      (or (%full-mapping-ref %unicode-full-foldcase-overrides code)\n"
   "          (list (consent-unicode-simple-foldcase code))))\n\n"))

(defun consent--unicode-insert-metadata ()
  "Insert the generated runtime-visible Unicode provenance datum."
  (insert
   "    ;; Record the version, license, sources, and fallback policy.\n"
   "    (define %unicode-data-metadata\n"
   "      '((unicode-version \"17.0.0\")\n"
   "        (source unicode-character-database)\n"
   "        (license Unicode-3.0)\n"
   "        (case-mapping default-non-turkic)\n"
   "        (conditional-special-casing final-sigma-omitted)\n"
   "        (fallback\n"
   "         (unassigned classification-false mapping-identity))\n"
   "        (inputs\n")
  (dolist (entry consent--unicode-input-hashes)
    (insert "         ((file \"" (car entry) "\")\n"
            "          (sha256\n"
            "           \"" (cdr entry) "\"))\n"))
  (insert "         )))\n\n"))

(defun consent--unicode-generate-text (directory)
  "Return generated Scheme Unicode data from UCD input DIRECTORY."
  (consent--unicode-verify-inputs directory)
  (let* ((unicode-data
          (consent--unicode-parse-unicode-data
           (consent--unicode-input-path directory "UnicodeData.txt")))
         (digits (nth 0 unicode-data))
         (simple-upper (nth 1 unicode-data))
         (simple-lower (nth 2 unicode-data))
         (effective-full-upper (consent--unicode-copy-table simple-upper))
         (effective-full-lower (consent--unicode-copy-table simple-lower))
         (case-folding
          (consent--unicode-parse-case-folding
           (consent--unicode-input-path directory "CaseFolding.txt")))
         (simple-fold (nth 0 case-folding))
         (effective-full-fold (nth 1 case-folding))
         (derived
          (consent--unicode-input-path directory
                                       "DerivedCoreProperties.txt"))
         (property-list
          (consent--unicode-input-path directory "PropList.txt"))
         (alphabetic (consent--unicode-property-ranges derived "Alphabetic"))
         (uppercase (consent--unicode-property-ranges derived "Uppercase"))
         (lowercase (consent--unicode-property-ranges derived "Lowercase"))
         (whitespace
          (consent--unicode-property-ranges property-list "White_Space")))
    (consent--unicode-apply-special-casing
     (consent--unicode-input-path directory "SpecialCasing.txt")
     effective-full-lower effective-full-upper)
    (let* ((full-upper
            (consent--unicode-mapping-overrides effective-full-upper
                                                simple-upper))
           (full-lower
            (consent--unicode-mapping-overrides effective-full-lower
                                                simple-lower))
           (full-fold
            (consent--unicode-mapping-overrides effective-full-fold
                                                simple-fold))
           (alphabetic-ranges (consent--unicode-split-ranges alphabetic))
           (uppercase-ranges (consent--unicode-split-ranges uppercase))
           (lowercase-ranges (consent--unicode-split-ranges lowercase))
           (whitespace-ranges (consent--unicode-split-ranges whitespace))
           (simple-upper-segments
            (consent--unicode-simple-mapping-segments simple-upper))
           (simple-lower-segments
            (consent--unicode-simple-mapping-segments simple-lower))
           (simple-fold-segments
            (consent--unicode-simple-mapping-segments simple-fold))
           (decimal-block-starts
            (consent--unicode-decimal-block-starts digits)))
      (with-temp-buffer
        (insert
         ";;; Generated Unicode 17.0.0 character data.\n"
         ";; SPDX-License-" "Identifier: Unicode-3.0\n"
         ";; SPDX-FileCopyrightText: 1991-2025 Unicode, Inc.\n"
         ";;;\n"
         ";;; Generated by tools/generate-unicode-data.el from the pinned UCD\n"
         ";;; inputs in vendor/unicode/17.0.0.\n"
         ";;; Do not edit this file by hand.\n\n"
         "(define-library (consent unicode-data)\n"
         "  (export consent-unicode-data-version\n"
         "          consent-unicode-data-metadata\n"
         "          consent-unicode-data-counts\n"
         "          consent-unicode-alphabetic?\n"
         "          consent-unicode-uppercase?\n"
         "          consent-unicode-lowercase?\n"
         "          consent-unicode-whitespace?\n"
         "          consent-unicode-decimal-value\n"
         "          consent-unicode-simple-uppercase\n"
         "          consent-unicode-simple-lowercase\n"
         "          consent-unicode-simple-foldcase\n"
         "          consent-unicode-full-uppercase\n"
         "          consent-unicode-full-lowercase\n"
         "          consent-unicode-full-foldcase)\n"
         "  (import (scheme base))\n"
         "  (begin\n"
         "    ;; Record the supported Unicode release as a Scheme datum.\n"
         "    (define %unicode-data-version '(17 0 0))\n\n")
        (consent--unicode-insert-metadata)
        (consent--unicode-insert-counts
         `((alphabetic-range-segments . ,(length alphabetic-ranges))
           (uppercase-range-segments . ,(length uppercase-ranges))
           (lowercase-range-segments . ,(length lowercase-ranges))
           (whitespace-range-segments . ,(length whitespace-ranges))
           (decimal-blocks . ,(length decimal-block-starts))
           (simple-uppercase-segments . ,(length simple-upper-segments))
           (simple-lowercase-segments . ,(length simple-lower-segments))
           (simple-foldcase-segments . ,(length simple-fold-segments))
           (full-uppercase-overrides . ,(hash-table-count full-upper))
           (full-lowercase-overrides . ,(hash-table-count full-lower))
           (full-foldcase-overrides . ,(hash-table-count full-fold))))
        (consent--unicode-insert-flat-vector
         "%unicode-alphabetic-ranges"
         "Private indexed ranges carrying the Alphabetic property."
         (consent--unicode-ranges-flat alphabetic-ranges))
        (consent--unicode-insert-flat-vector
         "%unicode-alphabetic-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index alphabetic-ranges #'car))
        (consent--unicode-insert-flat-vector
         "%unicode-uppercase-ranges"
         "Private indexed ranges carrying the Uppercase property."
         (consent--unicode-ranges-flat uppercase-ranges))
        (consent--unicode-insert-flat-vector
         "%unicode-uppercase-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index uppercase-ranges #'car))
        (consent--unicode-insert-flat-vector
         "%unicode-lowercase-ranges"
         "Private indexed ranges carrying the Lowercase property."
         (consent--unicode-ranges-flat lowercase-ranges))
        (consent--unicode-insert-flat-vector
         "%unicode-lowercase-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index lowercase-ranges #'car))
        (consent--unicode-insert-flat-vector
         "%unicode-whitespace-ranges"
         "Private indexed ranges carrying the White_Space property."
         (consent--unicode-ranges-flat whitespace-ranges))
        (consent--unicode-insert-flat-vector
         "%unicode-whitespace-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index whitespace-ranges #'car))
        (consent--unicode-insert-flat-vector
         "%unicode-decimal-block-starts"
         "Private starts of contiguous ten-code-point decimal blocks."
         decimal-block-starts)
        (consent--unicode-insert-flat-vector
         "%unicode-simple-uppercase-segments"
         "Private simple uppercase lower, upper, and delta segments."
         (consent--unicode-segments-flat simple-upper-segments))
        (consent--unicode-insert-flat-vector
         "%unicode-simple-uppercase-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index simple-upper-segments #'car))
        (consent--unicode-insert-flat-vector
         "%unicode-simple-lowercase-segments"
         "Private simple lowercase lower, upper, and delta segments."
         (consent--unicode-segments-flat simple-lower-segments))
        (consent--unicode-insert-flat-vector
         "%unicode-simple-lowercase-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index simple-lower-segments #'car))
        (consent--unicode-insert-flat-vector
         "%unicode-simple-foldcase-segments"
         "Private simple foldcase lower, upper, and delta segments."
         (consent--unicode-segments-flat simple-fold-segments))
        (consent--unicode-insert-flat-vector
         "%unicode-simple-foldcase-index"
         "Private entry offsets by BMP page or supplementary plane."
         (consent--unicode-bucket-index simple-fold-segments #'car))
        (consent--unicode-insert-mapping-vector
         "%unicode-full-uppercase-overrides"
         "Private full uppercase overrides, including expansions."
         full-upper)
        (consent--unicode-insert-mapping-vector
         "%unicode-full-lowercase-overrides"
         "Private full lowercase overrides, including expansions."
         full-lower)
        (consent--unicode-insert-mapping-vector
         "%unicode-full-foldcase-overrides"
         "Private full non-Turkic fold overrides to simple mappings."
         full-fold)
        (consent--unicode-insert-query-procedures)
        (insert "    ))\n")
        (buffer-string)))))

(defun consent--unicode-write-or-check (text output check)
  "Write TEXT to OUTPUT, or compare it when CHECK is non-nil."
  (if check
      (let ((actual (and (file-readable-p output)
                         (with-temp-buffer
                           (insert-file-contents-literally output)
                           (buffer-string)))))
        (unless (equal text actual)
          (error "Generated Unicode data is out of date: %s" output))
        (message "Unicode data is current: %s" output))
    (make-directory (file-name-directory output) t)
    (with-temp-file output (insert text))
    (message "Generated Unicode data: %s" output)))

(defun consent--unicode-batch-main ()
  "Generate or check the pinned Unicode Scheme data library."
  (let ((arguments command-line-args-left)
        (directory nil)
        (output nil)
        (check nil))
    (setq command-line-args-left nil)
    (when (equal (car arguments) "--")
      (setq arguments (cdr arguments)))
    (while arguments
      (pcase (pop arguments)
        ("--ucd-dir"
         (setq directory (or (pop arguments)
                             (error "--ucd-dir requires a path"))))
        ("--output"
         (setq output (or (pop arguments)
                          (error "--output requires a path"))))
        ("--check" (setq check t))
        (argument (error "Unknown Unicode generator argument: %s" argument))))
    (unless directory
      (error "--ucd-dir is required"))
    (unless output
      (error "--output is required"))
    (consent--unicode-write-or-check
     (consent--unicode-generate-text (expand-file-name directory))
     (expand-file-name output)
     check)))

(when noninteractive
  (condition-case condition
      (progn
        (consent--unicode-batch-main)
        (kill-emacs 0))
    (error
     (message "generate-unicode-data: %s" (error-message-string condition))
     (kill-emacs 1))))

;;; generate-unicode-data.el ends here
