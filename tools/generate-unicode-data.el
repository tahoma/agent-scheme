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
  (if (string-match
       "\\`\\([0-9A-F]+\\)\\(?:\\.\\.\\([0-9A-F]+\\)\\)?\\'"
       (string-trim text))
      (let ((lower (consent--unicode-hex (match-string 1 text)))
            (upper (match-string 2 text)))
        (cons lower (if upper (consent--unicode-hex upper) lower)))
    (error "Invalid Unicode code-point range: %s" text)))

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

(defun consent--unicode-ranges-flat (ranges)
  "Return RANGES as a flat list of lower and upper bounds."
  (apply #'append
         (mapcar (lambda (range) (list (car range) (cdr range))) ranges)))

(defun consent--unicode-single-mappings-flat (table)
  "Return single-code-point TABLE as flat source and target integers."
  (apply
   #'append
   (mapcar
    (lambda (entry)
      (unless (= (length (cdr entry)) 1)
        (error "Expected single mapping for U+%04X" (car entry)))
      (list (car entry) (cadr entry)))
    (consent--unicode-table-entries table))))

(defun consent--unicode-value-mappings-flat (table)
  "Return scalar value TABLE as flat source and integer value pairs."
  (apply
   #'append
   (mapcar (lambda (entry) (list (car entry) (cdr entry)))
           (consent--unicode-table-entries table))))

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

(defun consent--unicode-insert-metadata ()
  "Insert the generated runtime-visible Unicode provenance datum."
  (insert
   "    ;; Record the version, license, sources, and fallback policy.\n"
   "    (define consent-unicode-data-metadata\n"
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
         (full-upper (consent--unicode-copy-table simple-upper))
         (full-lower (consent--unicode-copy-table simple-lower))
         (case-folding
          (consent--unicode-parse-case-folding
           (consent--unicode-input-path directory "CaseFolding.txt")))
         (simple-fold (nth 0 case-folding))
         (full-fold (nth 1 case-folding))
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
     full-lower full-upper)
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
       "          consent-unicode-alphabetic-ranges\n"
       "          consent-unicode-uppercase-ranges\n"
       "          consent-unicode-lowercase-ranges\n"
       "          consent-unicode-whitespace-ranges\n"
       "          consent-unicode-decimal-values\n"
       "          consent-unicode-simple-uppercase-mappings\n"
       "          consent-unicode-simple-lowercase-mappings\n"
       "          consent-unicode-simple-foldcase-mappings\n"
       "          consent-unicode-full-uppercase-mappings\n"
       "          consent-unicode-full-lowercase-mappings\n"
       "          consent-unicode-full-foldcase-mappings)\n"
       "  (import (scheme base))\n"
       "  (begin\n"
       "    ;; Record the supported Unicode release as a Scheme datum.\n"
       "    (define consent-unicode-data-version '(17 0 0))\n\n")
      (consent--unicode-insert-metadata)
      (consent--unicode-insert-flat-vector
       "consent-unicode-alphabetic-ranges"
       "Inclusive ranges carrying the Unicode Alphabetic property."
       (consent--unicode-ranges-flat alphabetic))
      (consent--unicode-insert-flat-vector
       "consent-unicode-uppercase-ranges"
       "Inclusive ranges carrying the Unicode Uppercase property."
       (consent--unicode-ranges-flat uppercase))
      (consent--unicode-insert-flat-vector
       "consent-unicode-lowercase-ranges"
       "Inclusive ranges carrying the Unicode Lowercase property."
       (consent--unicode-ranges-flat lowercase))
      (consent--unicode-insert-flat-vector
       "consent-unicode-whitespace-ranges"
       "Inclusive ranges carrying the Unicode White_Space property."
       (consent--unicode-ranges-flat whitespace))
      (consent--unicode-insert-flat-vector
       "consent-unicode-decimal-values"
       "Code-point and Numeric_Type=Decimal value pairs."
       (consent--unicode-value-mappings-flat digits))
      (consent--unicode-insert-flat-vector
       "consent-unicode-simple-uppercase-mappings"
       "Code-point pairs for Unicode simple uppercase mappings."
       (consent--unicode-single-mappings-flat simple-upper))
      (consent--unicode-insert-flat-vector
       "consent-unicode-simple-lowercase-mappings"
       "Code-point pairs for Unicode simple lowercase mappings."
       (consent--unicode-single-mappings-flat simple-lower))
      (consent--unicode-insert-flat-vector
       "consent-unicode-simple-foldcase-mappings"
       "Code-point pairs for default Unicode simple case folding."
       (consent--unicode-single-mappings-flat simple-fold))
      (consent--unicode-insert-mapping-vector
       "consent-unicode-full-uppercase-mappings"
       "Full default uppercase mappings, including expansions."
       full-upper)
      (consent--unicode-insert-mapping-vector
       "consent-unicode-full-lowercase-mappings"
       "Full default lowercase mappings, including expansions."
       full-lower)
      (consent--unicode-insert-mapping-vector
       "consent-unicode-full-foldcase-mappings"
       "Full default non-Turkic case-folding mappings."
       full-fold)
      (insert "    ))\n")
      (buffer-string))))

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
