;;; generate-unicode-data.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Generate the portable Scheme Unicode table library from the pinned Unicode
;; Character Database inputs under the pinned vendor directory.  The
;; checked-in output is deterministic and can be verified with --check.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst consent--unicode-data-version "17.0.0"
  "Pinned Unicode Character Database version.")

(defconst consent--unicode-bmp-bucket-size #x1000
  "Number of scalar values in one generated BMP property bucket.")

(defconst consent--unicode-bmp-bucket-count 16
  "Number of 4K property buckets covering the BMP.")

(defconst consent--unicode-supplementary-plane-count 16
  "Number of supplementary Unicode planes after the BMP.")

(defconst consent--unicode-greek-affine-family-lowers
  '(#x1f80 #x1f88 #x1f90 #x1f98 #x1fa0 #x1fa8)
  "First sources of the repeated eight-code Greek mapping families.")

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

(defun consent--unicode-version-components ()
  "Return the three numeric components of the pinned Unicode version."
  (let ((parts (split-string consent--unicode-data-version "\\." nil)))
    (unless (and (= (length parts) 3)
                 (cl-every
                  (lambda (part)
                    (string-match-p "\\`[0-9]+\\'" part))
                  parts))
      (error "Unicode version must have three numeric components: %s"
             consent--unicode-data-version))
    (mapcar #'string-to-number parts)))

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

(defun consent--unicode-property-buckets (ranges)
  "Return direct coarse BMP and supplementary buckets for canonical RANGES.
The result is `(BMP-BUCKETS SUPPLEMENTARY-BUCKETS)'.  Canonical ranges are
copied into each coarse bucket they intersect rather than fragmented at page
boundaries."
  (let ((bmp (make-vector consent--unicode-bmp-bucket-count nil))
        (supplementary
         (make-vector consent--unicode-supplementary-plane-count nil)))
    (dolist (range ranges)
      (let ((lower (car range))
            (upper (cdr range)))
        (unless (and (<= 0 lower) (<= lower upper)
                     (<= upper #x10ffff))
          (error "Property range falls outside Unicode scalars: %S" range))
        (when (< lower #x10000)
          (let ((first (floor lower consent--unicode-bmp-bucket-size))
                (last
                 (floor (min upper #xffff)
                        consent--unicode-bmp-bucket-size)))
            (cl-loop for bucket from first to last do
                     (aset bmp bucket
                           (cons (cons lower upper)
                                 (aref bmp bucket))))))
        (when (> upper #xffff)
          (let ((first (1- (floor (max lower #x10000) #x10000)))
                (last (1- (floor upper #x10000))))
            (cl-loop for bucket from first to last do
                     (aset supplementary bucket
                           (cons (cons lower upper)
                                 (aref supplementary bucket))))))))
    (list
     (mapcar #'nreverse (append bmp nil))
     (mapcar #'nreverse (append supplementary nil)))))

(defun consent--unicode-property-bmp0-pages (ranges)
  "Return sixteen direct, non-overlapping page vectors covering BMP0 RANGES."
  (let ((pages (make-vector 16 nil)))
    (dolist (range ranges)
      (let ((lower (max 0 (car range)))
            (upper (min #xfff (cdr range))))
        (while (<= lower upper)
          (let* ((page (floor lower #x100))
                 (page-upper (min upper (+ (* page #x100) #xff))))
            (aset pages page
                  (cons (cons lower page-upper) (aref pages page)))
            (setq lower (1+ page-upper))))))
    (mapcar #'nreverse (append pages nil))))

(defun consent--unicode-simple-mapping-records (table)
  "Return sorted lower, upper, stride, and delta records for simple TABLE.
Only adjacent equal-delta entries with a stride of one or two are joined."
  (let ((entries (consent--unicode-table-entries table))
        records)
    (while entries
      (let* ((entry (pop entries))
             (lower (car entry))
             (upper lower)
             (mapping (cdr entry))
             (delta nil)
             (stride 1))
        (unless (= (length mapping) 1)
          (error "Expected single mapping for U+%04X" lower))
        (setq delta (- (car mapping) lower))
        (when entries
          (let* ((next (car entries))
                 (next-source (car next))
                 (next-mapping (cdr next))
                 (candidate-stride (- next-source lower)))
            (when (and (= (length next-mapping) 1)
                       (memq candidate-stride '(1 2))
                       (= (- (car next-mapping) next-source) delta))
              (setq stride candidate-stride)
              (while
                  (and entries
                       (= (length (cdar entries)) 1)
                       (= (caar entries) (+ upper stride))
                       (= (- (cadar entries) (caar entries)) delta))
                (setq upper (caar entries))
                (pop entries)))))
        (push (list lower upper stride delta) records)))
    (nreverse records)))

(defun consent--unicode-simple-mapping-buckets (records)
  "Return direct coarse BMP and supplementary buckets for mapping RECORDS."
  (let ((bmp (make-vector consent--unicode-bmp-bucket-count nil))
        (supplementary
         (make-vector consent--unicode-supplementary-plane-count nil)))
    (dolist (record records)
      (let ((lower (nth 0 record))
            (upper (nth 1 record)))
        (unless (and (= (length record) 4)
                     (<= 0 lower) (<= lower upper)
                     (<= upper #x10ffff))
          (error "Invalid simple mapping record: %S" record))
        (when (< lower #x10000)
          (let ((first (floor lower consent--unicode-bmp-bucket-size))
                (last
                 (floor (min upper #xffff)
                        consent--unicode-bmp-bucket-size)))
            (cl-loop for bucket from first to last do
                     (aset bmp bucket
                           (cons (copy-sequence record)
                                 (aref bmp bucket))))))
        (when (> upper #xffff)
          (let ((first (1- (floor (max lower #x10000) #x10000)))
                (last (1- (floor upper #x10000))))
            (cl-loop for bucket from first to last do
                     (aset supplementary bucket
                           (cons (copy-sequence record)
                                 (aref supplementary bucket))))))))
    (list
     (mapcar #'nreverse (append bmp nil))
     (mapcar #'nreverse (append supplementary nil)))))

(defun consent--unicode-extract-greek-affine-rules (table)
  "Return Greek affine RULES and residual EXCEPTIONS copied from TABLE.
Each rule is `(LOWER UPPER TARGET-LOWER SUFFIX)' and covers eight codes."
  (let ((exceptions (consent--unicode-copy-table table))
        rules)
    (dolist (lower consent--unicode-greek-affine-family-lowers)
      (let* ((first-mapping (gethash lower table))
             (target-lower (car first-mapping))
             (suffix (cadr first-mapping)))
        (unless (= (length first-mapping) 2)
          (error "Missing Greek affine mapping at U+%04X" lower))
        (dotimes (offset 8)
          (let ((source (+ lower offset))
                (expected (list (+ target-lower offset) suffix)))
            (unless (equal (gethash source table) expected)
              (error "Non-affine Greek mapping at U+%04X" source))
            (remhash source exceptions)))
        (push (list lower (+ lower 7) target-lower suffix) rules)))
    (list (nreverse rules) exceptions)))

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

(defun consent--unicode-record-text (record)
  "Return integer RECORD as space-separated Scheme hexadecimal values."
  (mapconcat #'consent--unicode-scheme-hex record " "))

(defun consent--unicode-insert-record-table
    (name description fields records)
  "Insert fixed-width RECORDS for NAME with DESCRIPTION and FIELDS."
  (insert "    ;; " description "\n"
          "    ;; Record fields: " fields ".\n"
          "    (define " name "\n"
          "      #(\n")
  (dolist (record records)
    (insert "        " (consent--unicode-record-text record) "\n"))
  (insert "        ))\n\n"))

(defun consent--unicode-insert-scalar-table
    (name description records)
  "Insert scalar RECORDS for NAME with DESCRIPTION, one per line."
  (insert "    ;; " description "\n"
          "    ;; Each record is one scalar block start.\n"
          "    (define " name "\n"
          "      #(\n")
  (dolist (record records)
    (insert "        " (consent--unicode-scheme-hex record) "\n"))
  (insert "        ))\n\n"))

(defun consent--unicode-insert-mapping-table
    (name description table)
  "Insert variable-width full mapping TABLE for NAME with DESCRIPTION."
  (insert "    ;; " description "\n"
          "    ;; Record fields: source followed by mapped scalars.\n"
          "    (define " name "\n"
          "      #(\n")
  (dolist (entry (consent--unicode-table-entries table))
    (insert "        #(" (consent--unicode-record-text entry) ")\n"))
  (insert "        ))\n\n"))

(defun consent--unicode-insert-range-vector (ranges indentation)
  "Insert flat inclusive RANGES as a vector at INDENTATION."
  (let ((prefix (make-string indentation ?\s)))
    (if ranges
        (progn
          (insert prefix "#(\n")
          (dolist (range ranges)
            (insert prefix "  "
                    (consent--unicode-record-text
                     (list (car range) (cdr range)))
                    "\n"))
          (insert prefix "  )\n"))
      (insert prefix "#()\n"))))

(defun consent--unicode-insert-property-buckets
    (name description buckets bmp-p)
  "Insert direct property BUCKETS under NAME with DESCRIPTION.
BMP-P selects 4K BMP labels; otherwise use supplementary-plane labels."
  (insert "    ;; " description "\n"
          "    ;; Range record fields: inclusive lower and upper.\n"
          "    (define " name "\n"
          "      #(\n")
  (cl-loop
   for ranges in buckets
   for index from 0
   do
   (if bmp-p
       (let ((lower (* index consent--unicode-bmp-bucket-size)))
         (insert (format "        ;; U+%04X..U+%04X.\n"
                         lower
                         (+ lower consent--unicode-bmp-bucket-size -1))))
     (let ((lower (* (1+ index) #x10000)))
       (insert (format "        ;; U+%05X..U+%05X.\n"
                       lower (+ lower #xffff)))))
   (consent--unicode-insert-range-vector ranges 8))
  (insert "        ))\n\n"))

(defun consent--unicode-insert-property-bmp0-pages
    (name description pages)
  "Insert sixteen direct BMP0 property PAGES under NAME with DESCRIPTION."
  (insert "    ;; " description "\n"
          "    ;; Range record fields: inclusive lower and upper.\n"
          "    (define " name "\n"
          "      #(\n")
  (cl-loop
   for ranges in pages
   for page from 0
   for lower = (* page #x100)
   do
   (insert (format "        ;; U+%04X..U+%04X.\n"
                   lower (+ lower #xff)))
   (consent--unicode-insert-range-vector ranges 8))
  (insert "        ))\n\n"))

(defun consent--unicode-insert-record-buckets
    (name description fields buckets bmp-p)
  "Insert direct fixed-width BUCKETS under NAME with DESCRIPTION and FIELDS.
BMP-P selects 4K BMP labels; otherwise use supplementary-plane labels."
  (insert "    ;; " description "\n"
          "    ;; Record fields: " fields ".\n"
          "    (define " name "\n"
          "      #(\n")
  (cl-loop
   for records in buckets
   for index from 0
   do
   (if bmp-p
       (let ((lower (* index consent--unicode-bmp-bucket-size)))
         (insert (format "        ;; U+%04X..U+%04X.\n"
                         lower
                         (+ lower consent--unicode-bmp-bucket-size -1))))
     (let ((lower (* (1+ index) #x10000)))
       (insert (format "        ;; U+%05X..U+%05X.\n"
                       lower (+ lower #xffff)))))
   (if records
       (progn
         (insert "        #(\n")
         (dolist (record records)
           (insert "          "
                   (consent--unicode-record-text record)
                   "\n"))
         (insert "          )\n"))
     (insert "        #()\n")))
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
   "    (define (%range-table-contains? table code)\n"
   "      \"Return #t when CODE occurs in flat range TABLE.\"\n"
   "      (let loop\n"
   "          ((lower 0)\n"
   "           (upper (- (quotient (vector-length table) 2) 1)))\n"
   "        (if (> lower upper)\n"
   "            #f\n"
   "            (let* ((middle (quotient (+ lower upper) 2))\n"
   "                   (offset (* middle 2))\n"
   "                   (range-lower (vector-ref table offset))\n"
   "                   (range-upper (vector-ref table (+ offset 1))))\n"
   "              (cond\n"
   "               ((< code range-lower)\n"
   "                (loop lower (- middle 1)))\n"
   "               ((> code range-upper)\n"
   "                (loop (+ middle 1) upper))\n"
   "               (else #t))))))\n\n"
   "    (define (%property-range-contains?\n"
   "             bmp0-pages bmp supplementary code)\n"
   "      \"Return #t when CODE occurs in direct property buckets.\"\n"
   "      (cond\n"
   "       ((or (< code 0) (> code #x10ffff)) #f)\n"
   "       ((< code #x1000)\n"
   "        (let ((page\n"
   "               (vector-ref bmp0-pages (quotient code #x100))))\n"
   "          (let loop\n"
   "              ((lower 0)\n"
   "               (upper (- (quotient (vector-length page) 2) 1)))\n"
   "            (if (> lower upper)\n"
   "                #f\n"
   "                (let* ((middle (quotient (+ lower upper) 2))\n"
   "                       (offset (* middle 2))\n"
   "                       (range-lower (vector-ref page offset))\n"
   "                       (range-upper\n"
   "                        (vector-ref page (+ offset 1))))\n"
   "                  (cond\n"
   "                   ((< code range-lower)\n"
   "                    (loop lower (- middle 1)))\n"
   "                   ((> code range-upper)\n"
   "                    (loop (+ middle 1) upper))\n"
   "                   (else #t)))))))\n"
   "       ((< code #x10000)\n"
   "        (%range-table-contains?\n"
   "         (vector-ref bmp (quotient code #x1000)) code))\n"
   "       (else\n"
   "        (%range-table-contains?\n"
   "         (vector-ref supplementary\n"
   "                     (- (quotient code #x10000) 1))\n"
   "         code))))\n\n"
   "    (define (%simple-mapping-ref bmp supplementary code)\n"
   "      \"Return CODE mapped through coarse simple buckets, or #f.\"\n"
   "      (let ((table\n"
   "             (cond\n"
   "              ((or (< code 0) (> code #x10ffff)) #f)\n"
   "              ((< code #x10000)\n"
   "               (vector-ref bmp (quotient code #x1000)))\n"
   "              (else\n"
   "               (vector-ref supplementary\n"
   "                           (- (quotient code #x10000) 1))))))\n"
   "        (and table\n"
   "             (let loop\n"
   "                 ((lower 0)\n"
   "                  (upper\n"
   "                   (- (quotient (vector-length table) 4) 1)))\n"
   "               (if (> lower upper)\n"
   "                   #f\n"
   "                   (let* ((middle (quotient (+ lower upper) 2))\n"
   "                          (offset (* middle 4))\n"
   "                          (range-lower (vector-ref table offset))\n"
   "                          (range-upper\n"
   "                           (vector-ref table (+ offset 1))))\n"
   "                     (cond\n"
   "                      ((< code range-lower)\n"
   "                       (loop lower (- middle 1)))\n"
   "                      ((> code range-upper)\n"
   "                       (loop (+ middle 1) upper))\n"
   "                      ((= (remainder (- code range-lower)\n"
   "                                     (vector-ref\n"
   "                                      table (+ offset 2)))\n"
   "                          0)\n"
   "                       (+ code (vector-ref table (+ offset 3))))\n"
   "                      (else #f))))))))\n\n"
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
   "    (define (%greek-affine-full-mapping-ref table code)\n"
   "      \"Return CODE's fresh Greek affine mapping from TABLE, or #f.\"\n"
   "      (and (<= #x1f80 code)\n"
   "           (<= code #x1faf)\n"
   "           (let* ((record (quotient (- code #x1f80) 8))\n"
   "                  (offset (* record 4))\n"
   "                  (source-lower (vector-ref table offset)))\n"
   "             (list\n"
   "              (+ (vector-ref table (+ offset 2))\n"
   "                 (- code source-lower))\n"
   "              (vector-ref table (+ offset 3))))))\n\n"
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
   "      (%property-range-contains?\n"
   "       %unicode-alphabetic-bmp0-pages\n"
   "       %unicode-alphabetic-bmp-buckets\n"
   "       %unicode-alphabetic-supplementary-buckets\n"
   "       code))\n\n"
   "    (define (consent-unicode-uppercase? code)\n"
   "      \"Return #t when CODE has the Unicode Uppercase property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode Uppercase.\"))\n"
   "        (effects pure))\n"
   "      (%property-range-contains?\n"
   "       %unicode-uppercase-bmp0-pages\n"
   "       %unicode-uppercase-bmp-buckets\n"
   "       %unicode-uppercase-supplementary-buckets\n"
   "       code))\n\n"
   "    (define (consent-unicode-lowercase? code)\n"
   "      \"Return #t when CODE has the Unicode Lowercase property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode Lowercase.\"))\n"
   "        (effects pure))\n"
   "      (%property-range-contains?\n"
   "       %unicode-lowercase-bmp0-pages\n"
   "       %unicode-lowercase-bmp-buckets\n"
   "       %unicode-lowercase-supplementary-buckets\n"
   "       code))\n\n"
   "    (define (consent-unicode-whitespace? code)\n"
   "      \"Return #t when CODE has the Unicode White_Space property.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to classify.\")))\n"
   "        (returns (type boolean)\n"
   "         (description \"Whether CODE has Unicode White_Space.\"))\n"
   "        (effects pure))\n"
   "      (%range-table-contains? %unicode-whitespace-ranges code))\n\n"
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
   "      (or (%simple-mapping-ref\n"
   "           %unicode-simple-uppercase-bmp-buckets\n"
   "           %unicode-simple-uppercase-supplementary-buckets code)\n"
   "          code))\n\n"
   "    (define (consent-unicode-simple-lowercase code)\n"
   "      \"Return CODE's simple Unicode lowercase mapping.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type exact-integer)\n"
   "         (description \"Simple lowercase scalar value.\"))\n"
   "        (effects pure))\n"
   "      (or (%simple-mapping-ref\n"
   "           %unicode-simple-lowercase-bmp-buckets\n"
   "           %unicode-simple-lowercase-supplementary-buckets code)\n"
   "          code))\n\n"
   "    (define (consent-unicode-simple-foldcase code)\n"
   "      \"Return CODE's simple Unicode case-folding mapping.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type exact-integer)\n"
   "         (description \"Simple case-folded scalar value.\"))\n"
   "        (effects pure))\n"
   "      (or (%simple-mapping-ref\n"
   "           %unicode-simple-foldcase-bmp-buckets\n"
   "           %unicode-simple-foldcase-supplementary-buckets code)\n"
   "          code))\n\n"
   "    (define (consent-unicode-full-uppercase code)\n"
   "      \"Return CODE's full Unicode uppercase mapping as a fresh list.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type list)\n"
   "         (description \"Fresh list of full uppercase scalar values.\"))\n"
   "        (effects allocation))\n"
   "      (or (%greek-affine-full-mapping-ref\n"
   "           %unicode-full-uppercase-greek-affine-rules code)\n"
   "          (%full-mapping-ref\n"
   "           %unicode-full-uppercase-exceptions code)\n"
   "          (list (consent-unicode-simple-uppercase code))))\n\n"
   "    (define (consent-unicode-full-lowercase code)\n"
   "      \"Return CODE's full Unicode lowercase mapping as a fresh list.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type list)\n"
   "         (description \"Fresh list of full lowercase scalar values.\"))\n"
   "        (effects allocation))\n"
   "      (or (%full-mapping-ref\n"
   "           %unicode-full-lowercase-exceptions code)\n"
   "          (list (consent-unicode-simple-lowercase code))))\n\n"
   "    (define (consent-unicode-full-foldcase code)\n"
   "      \"Return CODE's full case-folding mapping as a fresh list.\"\n"
   "      #((parameters\n"
   "         (code (type exact-integer)\n"
   "          (description \"Unicode scalar value to map.\")))\n"
   "        (returns (type list)\n"
   "         (description \"Fresh list of full case-folded scalar values.\"))\n"
   "        (effects allocation))\n"
   "      (or (%greek-affine-full-mapping-ref\n"
   "           %unicode-full-foldcase-greek-affine-rules code)\n"
   "          (%full-mapping-ref\n"
   "           %unicode-full-foldcase-exceptions code)\n"
   "          (list (consent-unicode-simple-foldcase code))))\n\n"))

(defun consent--unicode-insert-metadata ()
  "Insert the generated runtime-visible Unicode provenance datum."
  (insert
   "    ;; Record the version, license, sources, and fallback policy.\n"
   "    (define %unicode-data-metadata\n"
   "      '((unicode-version \""
   consent--unicode-data-version
   "\")\n"
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
           (alphabetic-buckets
            (consent--unicode-property-buckets alphabetic))
           (alphabetic-all-bmp-buckets (nth 0 alphabetic-buckets))
           (alphabetic-bmp0-pages
            (consent--unicode-property-bmp0-pages
             (car alphabetic-all-bmp-buckets)))
           (alphabetic-bmp-buckets
            (cons nil (cdr alphabetic-all-bmp-buckets)))
           (alphabetic-supplementary-buckets
            (nth 1 alphabetic-buckets))
           (uppercase-buckets
            (consent--unicode-property-buckets uppercase))
           (uppercase-all-bmp-buckets (nth 0 uppercase-buckets))
           (uppercase-bmp0-pages
            (consent--unicode-property-bmp0-pages
             (car uppercase-all-bmp-buckets)))
           (uppercase-bmp-buckets
            (cons nil (cdr uppercase-all-bmp-buckets)))
           (uppercase-supplementary-buckets
            (nth 1 uppercase-buckets))
           (lowercase-buckets
            (consent--unicode-property-buckets lowercase))
           (lowercase-all-bmp-buckets (nth 0 lowercase-buckets))
           (lowercase-bmp0-pages
            (consent--unicode-property-bmp0-pages
             (car lowercase-all-bmp-buckets)))
           (lowercase-bmp-buckets
            (cons nil (cdr lowercase-all-bmp-buckets)))
           (lowercase-supplementary-buckets
            (nth 1 lowercase-buckets))
           (whitespace-records
            (mapcar (lambda (range)
                      (list (car range) (cdr range)))
                    whitespace))
           (simple-upper-records
            (consent--unicode-simple-mapping-records simple-upper))
           (simple-upper-buckets
            (consent--unicode-simple-mapping-buckets
             simple-upper-records))
           (simple-lower-records
            (consent--unicode-simple-mapping-records simple-lower))
           (simple-lower-buckets
            (consent--unicode-simple-mapping-buckets
             simple-lower-records))
           (simple-fold-records
            (consent--unicode-simple-mapping-records simple-fold))
           (simple-fold-buckets
            (consent--unicode-simple-mapping-buckets
             simple-fold-records))
           (decimal-block-starts
            (consent--unicode-decimal-block-starts digits))
           (full-upper-parts
            (consent--unicode-extract-greek-affine-rules full-upper))
           (full-fold-parts
            (consent--unicode-extract-greek-affine-rules full-fold))
           (full-upper-rules (nth 0 full-upper-parts))
           (full-upper-exceptions (nth 1 full-upper-parts))
           (full-fold-rules (nth 0 full-fold-parts))
           (full-fold-exceptions (nth 1 full-fold-parts))
           (version-components (consent--unicode-version-components))
           (version-list
            (mapconcat #'number-to-string version-components " ")))
      (unless (= (hash-table-count full-lower) 1)
        (error "Expected one full lowercase exception, got %d"
               (hash-table-count full-lower)))
      (with-temp-buffer
        (insert
         (format ";;; Generated Unicode %s character data.\n"
                 consent--unicode-data-version)
         ";; SPDX-License-" "Identifier: Unicode-3.0\n"
         ";; SPDX-FileCopyrightText: 1991-2025 Unicode, Inc.\n"
         ";;;\n"
         ";;; Generated by tools/generate-unicode-data.el from the pinned UCD\n"
         (format ";;; inputs in vendor/unicode/%s.\n"
                 consent--unicode-data-version)
         ";;; Do not edit this file by hand.\n\n"
         "(define-library (consent unicode-data)\n"
         "  (export consent-unicode-data-version\n"
         "          consent-unicode-data-metadata\n"
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
         (format "    (define %%unicode-data-version '(%s))\n\n"
                 version-list))
        (consent--unicode-insert-metadata)
        (consent--unicode-insert-property-buckets
         "%unicode-alphabetic-bmp-buckets"
         "Private canonical Alphabetic ranges by coarse 4K BMP bucket."
         alphabetic-bmp-buckets t)
        (consent--unicode-insert-property-bmp0-pages
         "%unicode-alphabetic-bmp0-pages"
         "Private direct Alphabetic pages for U+0000 through U+0FFF."
         alphabetic-bmp0-pages)
        (consent--unicode-insert-property-buckets
         "%unicode-alphabetic-supplementary-buckets"
         "Private canonical Alphabetic ranges by supplementary plane."
         alphabetic-supplementary-buckets nil)
        (consent--unicode-insert-property-buckets
         "%unicode-uppercase-bmp-buckets"
         "Private canonical Uppercase ranges by coarse 4K BMP bucket."
         uppercase-bmp-buckets t)
        (consent--unicode-insert-property-bmp0-pages
         "%unicode-uppercase-bmp0-pages"
         "Private direct Uppercase pages for U+0000 through U+0FFF."
         uppercase-bmp0-pages)
        (consent--unicode-insert-property-buckets
         "%unicode-uppercase-supplementary-buckets"
         "Private canonical Uppercase ranges by supplementary plane."
         uppercase-supplementary-buckets nil)
        (consent--unicode-insert-property-buckets
         "%unicode-lowercase-bmp-buckets"
         "Private canonical Lowercase ranges by coarse 4K BMP bucket."
         lowercase-bmp-buckets t)
        (consent--unicode-insert-property-bmp0-pages
         "%unicode-lowercase-bmp0-pages"
         "Private direct Lowercase pages for U+0000 through U+0FFF."
         lowercase-bmp0-pages)
        (consent--unicode-insert-property-buckets
         "%unicode-lowercase-supplementary-buckets"
         "Private canonical Lowercase ranges by supplementary plane."
         lowercase-supplementary-buckets nil)
        (consent--unicode-insert-record-table
         "%unicode-whitespace-ranges"
         "Private canonical ranges carrying White_Space."
         "inclusive lower and upper"
         whitespace-records)
        (consent--unicode-insert-scalar-table
         "%unicode-decimal-block-starts"
         "Private starts of contiguous ten-code-point decimal blocks."
         decimal-block-starts)
        (consent--unicode-insert-record-buckets
         "%unicode-simple-uppercase-bmp-buckets"
         "Private simple-uppercase records by coarse 4K BMP bucket."
         "inclusive lower, inclusive upper, stride, and delta"
         (nth 0 simple-upper-buckets) t)
        (consent--unicode-insert-record-buckets
         "%unicode-simple-uppercase-supplementary-buckets"
         "Private simple-uppercase records by supplementary plane."
         "inclusive lower, inclusive upper, stride, and delta"
         (nth 1 simple-upper-buckets) nil)
        (consent--unicode-insert-record-buckets
         "%unicode-simple-lowercase-bmp-buckets"
         "Private simple-lowercase records by coarse 4K BMP bucket."
         "inclusive lower, inclusive upper, stride, and delta"
         (nth 0 simple-lower-buckets) t)
        (consent--unicode-insert-record-buckets
         "%unicode-simple-lowercase-supplementary-buckets"
         "Private simple-lowercase records by supplementary plane."
         "inclusive lower, inclusive upper, stride, and delta"
         (nth 1 simple-lower-buckets) nil)
        (consent--unicode-insert-record-buckets
         "%unicode-simple-foldcase-bmp-buckets"
         "Private simple-foldcase records by coarse 4K BMP bucket."
         "inclusive lower, inclusive upper, stride, and delta"
         (nth 0 simple-fold-buckets) t)
        (consent--unicode-insert-record-buckets
         "%unicode-simple-foldcase-supplementary-buckets"
         "Private simple-foldcase records by supplementary plane."
         "inclusive lower, inclusive upper, stride, and delta"
         (nth 1 simple-fold-buckets) nil)
        (consent--unicode-insert-record-table
         "%unicode-full-uppercase-greek-affine-rules"
         "Private repeated Greek full-uppercase affine rules."
         "source lower, source upper, target lower, and suffix"
         full-upper-rules)
        (consent--unicode-insert-mapping-table
         "%unicode-full-uppercase-exceptions"
         "Private unrelated full-uppercase expansion exceptions."
         full-upper-exceptions)
        (consent--unicode-insert-mapping-table
         "%unicode-full-lowercase-exceptions"
         "Private full-lowercase expansion exception."
         full-lower)
        (consent--unicode-insert-record-table
         "%unicode-full-foldcase-greek-affine-rules"
         "Private repeated Greek full-foldcase affine rules."
         "source lower, source upper, target lower, and suffix"
         full-fold-rules)
        (consent--unicode-insert-mapping-table
         "%unicode-full-foldcase-exceptions"
         "Private unrelated full-foldcase expansion exceptions."
         full-fold-exceptions)
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
