;;; consent-unicode-data-generator-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused unit tests for the pinned Unicode Character Database generator.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'scheme)

(eval-and-compile
  (defconst consent-unicode-data-generator-test--root
    (file-name-directory
     (directory-file-name
      (file-name-directory
       (or load-file-name
           (and (boundp 'byte-compile-current-file)
                byte-compile-current-file)
           buffer-file-name))))
    "Repository root containing the Unicode data generator.")
  (let ((noninteractive nil))
    (load
     (expand-file-name
      "tools/generate-unicode-data.el"
      consent-unicode-data-generator-test--root)
     nil
     t))
  (add-to-list
   'load-path
   (expand-file-name
    "lisp" consent-unicode-data-generator-test--root))
  (let ((noninteractive nil))
    (load
     (expand-file-name
      "tools/benchmark-unicode.el"
      consent-unicode-data-generator-test--root)
     nil
     t)))

(defconst
  consent-unicode-data-generator-test--owned-library-byte-ceiling
  150000
  "Maximum combined bytes for the owned Unicode and character libraries.
This leaves growth room while rejecting a gross return to expanded tables.")

(defconst
  consent-unicode-data-generator-test--unicode-library-bytes
  103329
  "Expected literal byte size of the deterministic generated Unicode library.")

(defun consent-unicode-data-generator-test--write-file
    (directory name contents)
  "Write CONTENTS to NAME beneath DIRECTORY and return its path."
  (let ((path (expand-file-name name directory)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert contents))
    path))

(defun consent-unicode-data-generator-test--repository-file (name)
  "Return repository-relative file NAME as a string."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name
      name consent-unicode-data-generator-test--root))
    (buffer-string)))

(defun consent-unicode-data-generator-test--repository-datum (name)
  "Return the single Lisp-compatible datum in repository file NAME."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name
      name consent-unicode-data-generator-test--root))
    (goto-char (point-min))
    (let* ((datum (read (current-buffer)))
           (extra
            (condition-case nil
                (read (current-buffer))
              (end-of-file :end-of-file))))
      (unless (eq extra :end-of-file)
        (error "Expected one datum in %s" name))
      datum)))

(defun consent-unicode-data-generator-test--repository-file-size (name)
  "Return the literal byte size of repository-relative file NAME."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name
      name consent-unicode-data-generator-test--root))
    (buffer-size)))

(defun consent-unicode-data-generator-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source
    source nil '(:internal-libraries-allowed t))))

(defun consent-unicode-data-generator-test--inserted-text (inserter)
  "Return text produced by zero-argument INSERTER in a temporary buffer."
  (with-temp-buffer
    (funcall inserter)
    (buffer-string)))

(defun consent-unicode-data-generator-test--scheme-forms (source head)
  "Return complete Scheme forms in SOURCE whose first symbol is HEAD."
  (with-temp-buffer
    (insert source)
    (scheme-mode)
    (goto-char (point-min))
    (let ((pattern (concat "(" (regexp-quote head) "\\_>"))
          forms)
      (while (re-search-forward pattern nil t)
        (let ((start (match-beginning 0)))
          (unless (nth 8 (syntax-ppss start))
            (goto-char start)
            (forward-sexp)
            (push (buffer-substring-no-properties start (point)) forms))))
      (nreverse forms))))

(defun consent-unicode-data-generator-test--manifest-source-version
    (manifest library)
  "Return LIBRARY's source-version form from MANIFEST source."
  (let (versions)
    (dolist (entry
             (consent-unicode-data-generator-test--scheme-forms
              manifest "manifest-entry"))
      (let* ((name-forms
              (consent-unicode-data-generator-test--scheme-forms
               entry "name"))
             (name (and (= (length name-forms) 1)
                        (cadr (read (car name-forms))))))
        (when (equal name library)
          (let ((version-forms
                 (consent-unicode-data-generator-test--scheme-forms
                  entry "source-version")))
            (unless (= (length version-forms) 1)
              (error "Expected one source-version for %S" library))
            (push (cadr (read (car version-forms))) versions)))))
    (unless (= (length versions) 1)
      (error "Expected one manifest entry for %S" library))
    (car versions)))

(defun consent-unicode-data-generator-test--generated-definition
    (source name)
  "Return generated Scheme definition NAME from SOURCE."
  (let ((pattern
         (concat "\\`(define[[:space:]]+"
                 (regexp-quote (symbol-name name))
                 "\\_>"))
        matches)
    (dolist (form
             (consent-unicode-data-generator-test--scheme-forms
              source "define"))
      (when (string-match-p pattern form)
        (push (read form) matches)))
    (unless (= (length matches) 1)
      (error "Expected one generated definition for %S" name))
    (car matches)))

(defun consent-unicode-data-generator-test--unicode-data-row
    (code category decimal uppercase lowercase)
  "Return a synthetic UnicodeData row for CODE and its selected fields."
  (mapconcat
   #'identity
   (list code "SYNTHETIC" category "0" "L" "" decimal "" "" "N"
         "" "" uppercase lowercase "")
   ";"))

(defun consent-unicode-data-generator-test--digit-table (&optional corrupt)
  "Return two synthetic decimal blocks, optionally applying CORRUPT."
  (let ((table (make-hash-table :test #'eql)))
    (dolist (start '(#x30 #x660))
      (dotimes (value 10)
        (puthash (+ start value) value table)))
    (when corrupt
      (funcall corrupt table))
    table))

(ert-deftest consent-unicode-data-generator-test-parses-and-normalizes-input ()
  "Parse synthetic UCD rows, comments, properties, and code ranges."
  (let ((root (make-temp-file "consent-unicode-parse-" t)))
    (unwind-protect
        (let* ((unicode-data-path
                (consent-unicode-data-generator-test--write-file
                 root
                 "UnicodeData.txt"
                 (concat
                  (consent-unicode-data-generator-test--unicode-data-row
                   "0030" "Nd" "0" "" "")
                  "\n"
                  (consent-unicode-data-generator-test--unicode-data-row
                   "0041" "Lu" "" "" "0061")
                  "\n"
                  (consent-unicode-data-generator-test--unicode-data-row
                   "0061" "Ll" "" "0041" "")
                  "\n")))
               (property-path
                (consent-unicode-data-generator-test--write-file
                 root
                 "DerivedCoreProperties.txt"
                 (concat
                  "0041..0042 ; Alphabetic # first range\n"
                  "0043 ; Alphabetic\n"
                  "0044 ; Other_Property\n"
                  "0044..0045 ; Alphabetic # adjacent range\n")))
               (parsed
                (consent--unicode-parse-unicode-data unicode-data-path))
               (digits (nth 0 parsed))
               (uppercase (nth 1 parsed))
               (lowercase (nth 2 parsed)))
          (should (equal (consent--unicode-data-text
                          "  0041 ; Alphabetic # comment  ")
                         "0041 ; Alphabetic"))
          (should (equal (consent--unicode-code-range " 0041..005A ")
                         '(#x41 . #x5a)))
          (should (equal (consent--unicode-code-range "0061")
                         '(#x61 . #x61)))
          (should-error (consent--unicode-code-range "not-a-range"))
          (should (= (gethash #x30 digits) 0))
          (should (equal (gethash #x41 lowercase) '(#x61)))
          (should (equal (gethash #x61 uppercase) '(#x41)))
          (should (equal
                   (consent--unicode-property-ranges
                    property-path "Alphabetic")
                   '((#x41 . #x45)))))
      (delete-directory root t))))

(ert-deftest consent-unicode-data-generator-test-normalizes-case-mappings ()
  "Parse simple/full mappings and retain only meaningful overrides."
  (let ((root (make-temp-file "consent-unicode-mapping-" t)))
    (unwind-protect
        (let* ((folding-path
                (consent-unicode-data-generator-test--write-file
                 root
                 "CaseFolding.txt"
                 (concat
                  "0041; C; 0061; # common\n"
                  "0042; S; 0062; # simple only\n"
                  "00DF; F; 0073 0073; # full only\n"
                  "0049; T; 0131; # Turkic omitted\n")))
               (special-path
                (consent-unicode-data-generator-test--write-file
                 root
                 "SpecialCasing.txt"
                 (concat
                  "00DF; 00DF; 0053 0073; 0053 0053; ;\n"
                  "0049; 0069; 0049; 0049; tr;\n")))
               (folding (consent--unicode-parse-case-folding folding-path))
               (simple-fold (nth 0 folding))
               (full-fold (nth 1 folding))
               (lower (make-hash-table :test #'eql))
               (upper (make-hash-table :test #'eql)))
          (should (equal (consent--unicode-table-entries simple-fold)
                         '((#x41 #x61) (#x42 #x62))))
          (should (equal (consent--unicode-table-entries full-fold)
                         '((#x41 #x61) (#xdf #x73 #x73))))
          (puthash #xdf '(#xdf) lower)
          (puthash #x49 '(#x49) lower)
          (consent--unicode-apply-special-casing special-path lower upper)
          (should-not (gethash #xdf lower))
          (should (equal (gethash #xdf upper) '(#x53 #x53)))
          (should (equal (gethash #x49 lower) '(#x49))))
      (delete-directory root t))))

(ert-deftest consent-unicode-data-generator-test-builds-property-buckets ()
  "Keep canonical ranges while assigning them to coarse lookup buckets."
  (should
   (equal
    (consent--unicode-merge-ranges
     '((#x100 . #x101) (#xff . #xff) (#x105 . #x106)
       (#x102 . #x105)))
    '((#xff . #x106))))
  (let* ((cross-bmp '(#xffe . #x1002))
         (cross-plane '(#xffff . #x10001))
         (last-scalar '(#x10ffff . #x10ffff))
         (buckets
          (consent--unicode-property-buckets
           (list cross-bmp cross-plane last-scalar)))
         (bmp (car buckets))
         (supplementary (cadr buckets)))
    (should (= (length bmp) 16))
    (should (= (length supplementary) 16))
    (should (equal (nth 0 bmp) (list cross-bmp)))
    (should (equal (nth 1 bmp) (list cross-bmp)))
    (should (equal (nth 2 bmp) nil))
    (should (equal (nth 15 bmp) (list cross-plane)))
    (should (equal (nth 0 supplementary) (list cross-plane)))
    (should (equal (nth 1 supplementary) nil))
    (should (equal (nth 15 supplementary) (list last-scalar))))
  (should-error
   (consent--unicode-property-buckets '((#x110000 . #x110000))))
  (should-error
   (consent--unicode-property-buckets '((#x10 . #xf))))
  (let ((pages
         (consent--unicode-property-bmp0-pages
          '((#xfe . #x101) (#x2ff . #x301)
            (#xfff . #x1001)))))
    (should (= (length pages) 16))
    (should (equal (nth 0 pages) '((#xfe . #xff))))
    (should (equal (nth 1 pages) '((#x100 . #x101))))
    (should (equal (nth 2 pages) '((#x2ff . #x2ff))))
    (should (equal (nth 3 pages) '((#x300 . #x301))))
    (should (equal (nth 4 pages) nil))
    (should (equal (nth 15 pages) '((#xfff . #xfff))))))

(ert-deftest consent-unicode-data-generator-test-compacts-mapping-records ()
  "Compact only stride-one or stride-two affine simple mappings."
  (let ((table (make-hash-table :test #'eql))
        (full (make-hash-table :test #'eql))
        (fallback (make-hash-table :test #'eql)))
    (dolist (entry '((#x41 #x61) (#x42 #x62)
                     (#x101 #x100) (#x103 #x102) (#x105 #x104)
                     (#x201 #x200) (#x204 #x203)))
      (puthash (car entry) (cdr entry) table))
    (let ((records (consent--unicode-simple-mapping-records table)))
      (should
       (equal records
              '((#x41 #x42 1 32)
                (#x101 #x105 2 -1)
                (#x201 #x201 1 -1)
                (#x204 #x204 1 -1))))
      (should
       (cl-every
        (lambda (record) (memq (nth 2 record) '(1 2)))
        records)))
    (puthash #x41 '(#x61) fallback)
    (puthash #x42 '(#x62) fallback)
    (puthash #x41 '(#x61) full)
    (puthash #x43 '(#x44) full)
    (should
     (equal
      (consent--unicode-table-entries
       (consent--unicode-mapping-overrides full fallback))
      '((#x42 #x42) (#x43 #x44))))))

(ert-deftest consent-unicode-data-generator-test-buckets-mapping-records ()
  "Assign simple records directly to coarse BMP and plane buckets."
  (let* ((cross-bmp '(#xfff #x1001 1 1))
         (cross-plane '(#xffff #x10001 1 -1))
         (last-scalar '(#x10ffff #x10ffff 1 0))
         (buckets
          (consent--unicode-simple-mapping-buckets
           (list cross-bmp cross-plane last-scalar)))
         (bmp (car buckets))
         (supplementary (cadr buckets)))
    (should (= (length bmp) 16))
    (should (= (length supplementary) 16))
    (should (equal (nth 0 bmp) (list cross-bmp)))
    (should (equal (nth 1 bmp) (list cross-bmp)))
    (should (equal (nth 15 bmp) (list cross-plane)))
    (should (equal (nth 0 supplementary) (list cross-plane)))
    (should (equal (nth 15 supplementary) (list last-scalar))))
  (should-error
   (consent--unicode-simple-mapping-buckets '((#x41 #x5a -32))))
  (should-error
   (consent--unicode-simple-mapping-buckets
    '((#x110000 #x110000 1 0)))))

(ert-deftest consent-unicode-data-generator-test-extracts-greek-affine-rules ()
  "Compact every complete Greek affine family and retain other overrides."
  (let ((table (make-hash-table :test #'eql))
        expected-rules)
    (dolist (lower consent--unicode-greek-affine-family-lowers)
      (let ((target-lower (+ lower #x100))
            (suffix #x399))
        (push (list lower (+ lower 7) target-lower suffix)
              expected-rules)
        (dotimes (offset 8)
          (puthash (+ lower offset)
                   (list (+ target-lower offset) suffix)
                   table))))
    (puthash #xdf '(#x53 #x53) table)
    (let* ((result (consent--unicode-extract-greek-affine-rules table))
           (rules (car result))
           (exceptions (cadr result)))
      (should (equal rules (nreverse expected-rules)))
      (should (= (hash-table-count exceptions) 1))
      (should (equal (gethash #xdf exceptions) '(#x53 #x53)))
      (should (= (hash-table-count table) 49)))
    (puthash (car consent--unicode-greek-affine-family-lowers)
             '(#x0 #x399)
             table)
    (should-error (consent--unicode-extract-greek-affine-rules table))))

(ert-deftest consent-unicode-data-generator-test-formats-complete-records ()
  "Put each generated fixed-width or variable-width record on one line."
  (should
   (equal
    (consent-unicode-data-generator-test--inserted-text
     (lambda ()
       (consent--unicode-insert-record-table
        "%synthetic-records"
        "Synthetic fixed-width records."
        "lower, upper, stride, delta"
        '((#x41 #x42 1 32) (#x101 #x105 2 -1)))))
    (concat
     "    ;; Synthetic fixed-width records.\n"
     "    ;; Record fields: lower, upper, stride, delta.\n"
     "    (define %synthetic-records\n"
     "      #(\n"
     "        #x41 #x42 #x1 #x20\n"
     "        #x101 #x105 #x2 #x-1\n"
     "        ))\n\n")))
  (let ((table (make-hash-table :test #'eql)))
    (puthash #xdf '(#x53 #x53) table)
    (puthash #x130 '(#x69 #x307) table)
    (should
     (equal
      (consent-unicode-data-generator-test--inserted-text
       (lambda ()
         (consent--unicode-insert-mapping-table
          "%synthetic-mappings"
          "Synthetic variable-width mappings."
          table)))
      (concat
       "    ;; Synthetic variable-width mappings.\n"
       "    ;; Record fields: source followed by mapped scalars.\n"
       "    (define %synthetic-mappings\n"
       "      #(\n"
       "        #(#xdf #x53 #x53)\n"
       "        #(#x130 #x69 #x307)\n"
       "        ))\n\n")))))

(ert-deftest consent-unicode-data-generator-test-parses-single-version-source ()
  "Derive every generated version spelling from the pinned string."
  (let ((consent--unicode-data-version "18.2.3"))
    (should (equal (consent--unicode-version-components) '(18 2 3)))
    (let ((generated
           (consent--unicode-generate-text
            (expand-file-name
             "vendor/unicode/17.0.0"
             consent-unicode-data-generator-test--root))))
      (should-not (string-match-p "17\\.0\\.0" generated))
      (should
       (string-match-p
        "Generated Unicode 18\\.2\\.3 character data" generated))
      (should
       (string-match-p
        "inputs in vendor/unicode/18\\.2\\.3" generated))
      (should
       (string-match-p
        (regexp-quote "(unicode-version \"18.2.3\")")
        generated))
      (should
       (string-match-p
        (regexp-quote "(define %unicode-data-version '(18 2 3))")
        generated))))
  (dolist (invalid '("18.2" "18.next.3" "18.2.3.4"))
    (let ((consent--unicode-data-version invalid))
      (should-error (consent--unicode-version-components)))))

(ert-deftest consent-unicode-data-generator-test-pinned-structure-counts ()
  "Keep canonical and compact table counts deterministic for the pinned UCD."
  (let* ((directory
          (expand-file-name
           (concat "vendor/unicode/" consent--unicode-data-version)
           consent-unicode-data-generator-test--root))
         (derived
          (consent--unicode-input-path
           directory "DerivedCoreProperties.txt"))
         (property-list
          (consent--unicode-input-path directory "PropList.txt"))
         (unicode-data
          (consent--unicode-parse-unicode-data
           (consent--unicode-input-path directory "UnicodeData.txt")))
         (digits (nth 0 unicode-data))
         (simple-upper (nth 1 unicode-data))
         (simple-lower (nth 2 unicode-data))
         (effective-upper (consent--unicode-copy-table simple-upper))
         (effective-lower (consent--unicode-copy-table simple-lower))
         (case-folding
          (consent--unicode-parse-case-folding
           (consent--unicode-input-path directory "CaseFolding.txt")))
         (simple-fold (nth 0 case-folding))
         (effective-fold (nth 1 case-folding))
         (alphabetic
          (consent--unicode-property-ranges derived "Alphabetic"))
         (uppercase
          (consent--unicode-property-ranges derived "Uppercase"))
         (lowercase
          (consent--unicode-property-ranges derived "Lowercase"))
         (whitespace
          (consent--unicode-property-ranges property-list "White_Space")))
    (consent--unicode-apply-special-casing
     (consent--unicode-input-path directory "SpecialCasing.txt")
     effective-lower effective-upper)
    (let* ((full-upper
            (consent--unicode-mapping-overrides
             effective-upper simple-upper))
           (full-lower
            (consent--unicode-mapping-overrides
             effective-lower simple-lower))
           (full-fold
            (consent--unicode-mapping-overrides
             effective-fold simple-fold))
           (upper-parts
            (consent--unicode-extract-greek-affine-rules full-upper))
           (fold-parts
            (consent--unicode-extract-greek-affine-rules full-fold)))
      (should
       (equal
        (mapcar #'length
                (list alphabetic uppercase lowercase whitespace))
        '(761 660 677 10)))
      (should
       (equal
        (mapcar
         (lambda (ranges)
           (apply
            #'+
            (mapcar #'length
                    (apply #'append
                           (consent--unicode-property-buckets ranges)))))
         (list alphabetic uppercase lowercase))
        '(771 660 677)))
      (should
       (equal
        (mapcar
         (lambda (ranges)
           (let* ((buckets
                   (consent--unicode-property-buckets ranges))
                  (bmp (car buckets))
                  (bmp0-pages
                   (consent--unicode-property-bmp0-pages (car bmp))))
             (apply
              #'+
              (mapcar
               #'length
               (append bmp0-pages (cdr bmp) (cadr buckets))))))
         (list alphabetic uppercase lowercase))
        '(776 661 677)))
      (should
       (equal
        (mapcar
         (lambda (ranges)
           (mapcar
            #'length
            (consent--unicode-property-bmp0-pages
             (car (car (consent--unicode-property-buckets ranges))))))
         (list alphabetic uppercase lowercase))
        '((8 1 5 11 2 11 9 5 11 20 28 29 24 20 14 6)
          (3 107 34 28 76 25 0 0 0 0 0 0 0 0 0 0)
          (6 107 37 24 76 25 0 0 0 0 0 0 0 0 0 0))))
      (should
       (equal
        (mapcar
         (lambda (table)
           (length (consent--unicode-simple-mapping-records table)))
         (list simple-upper simple-lower simple-fold))
        '(204 186 209)))
      (should
       (= (length (consent--unicode-decimal-block-starts digits)) 77))
      (should
       (equal
        (mapcar
         (lambda (table)
           (apply
            #'+
            (mapcar
             #'length
             (apply
              #'append
              (consent--unicode-simple-mapping-buckets
               (consent--unicode-simple-mapping-records table))))))
         (list simple-upper simple-lower simple-fold))
        '(204 186 209)))
      (should (= (length (car upper-parts)) 6))
      (should (= (hash-table-count (cadr upper-parts)) 54))
      (should (= (hash-table-count full-lower) 1))
      (should (= (length (car fold-parts)) 6))
      (should (= (hash-table-count (cadr fold-parts)) 56)))))

(ert-deftest consent-unicode-data-generator-test-generated-layout-is-compact ()
  "Omit dense indexes and representation-count APIs from generated source."
  (let ((generated
         (consent-unicode-data-generator-test--repository-file
          "scheme/consent/unicode-data.sld")))
    (dolist (obsolete '("%unicode-whitespace-index"
                        "%unicode-alphabetic-index"
                        "%unicode-uppercase-index"
                        "%unicode-lowercase-index"
                        "%unicode-simple-uppercase-index"
                        "%unicode-simple-lowercase-index"
                        "%unicode-simple-foldcase-index"
                        "%unicode-simple-uppercase-records"
                        "%unicode-simple-lowercase-records"
                        "%unicode-simple-foldcase-records"
                        "%unicode-alphabetic-bmp-page-windows"
                        "%unicode-uppercase-bmp-page-windows"
                        "%unicode-lowercase-bmp-page-windows"
                        "%unicode-data-counts"
                        "consent-unicode-data-counts"))
      (should-not (string-match-p (regexp-quote obsolete) generated)))
    (dolist (current '("%unicode-alphabetic-bmp-buckets"
                       "%unicode-alphabetic-bmp0-pages"
                       "%unicode-alphabetic-supplementary-buckets"
                       "%unicode-uppercase-bmp0-pages"
                       "%unicode-lowercase-bmp0-pages"
                       "%unicode-whitespace-ranges"
                       "%unicode-simple-uppercase-bmp-buckets"
                       "%unicode-simple-uppercase-supplementary-buckets"
                       "%unicode-simple-lowercase-bmp-buckets"
                       "%unicode-simple-foldcase-bmp-buckets"
                       "%unicode-full-uppercase-greek-affine-rules"
                       "%property-range-contains?"
                       "%greek-affine-full-mapping-ref"))
      (should (string-match-p (regexp-quote current) generated)))
    (dolist (name '(%unicode-alphabetic-bmp-buckets
                    %unicode-uppercase-bmp-buckets
                    %unicode-lowercase-bmp-buckets))
      (should
       (string-match-p
        (regexp-quote
         (format
          (concat "(define %s\n"
                  "      #(\n"
                  "        ;; U+0000..U+0FFF.\n"
                  "        #()")
          name))
        generated)))))

(ert-deftest consent-unicode-data-generator-test-checks-record-lookups ()
  "Exercise bucket boundaries, stride holes, and Greek affine full mappings."
  (should
   (equal
    (consent-unicode-data-generator-test--external
     (concat
      "(import (scheme base) (consent unicode-data))\n"
      "(list\n"
      " (consent-unicode-alphabetic? #xff)\n"
      " (consent-unicode-alphabetic? #x100)\n"
      " (consent-unicode-alphabetic? #x2c1)\n"
      " (consent-unicode-alphabetic? #x2c2)\n"
      " (consent-unicode-uppercase? #x3fd)\n"
      " (consent-unicode-uppercase? #x3ff)\n"
      " (consent-unicode-uppercase? #x400)\n"
      " (consent-unicode-uppercase? #x42f)\n"
      " (consent-unicode-uppercase? #x430)\n"
      " (consent-unicode-alphabetic? #xfff)\n"
      " (consent-unicode-alphabetic? #x1000)\n"
      " (consent-unicode-alphabetic? #x33ff)\n"
      " (consent-unicode-alphabetic? #x3400)\n"
      " (consent-unicode-alphabetic? #x3fff)\n"
      " (consent-unicode-alphabetic? #x4000)\n"
      " (consent-unicode-alphabetic? #x4dbf)\n"
      " (consent-unicode-alphabetic? #x4dc0)\n"
      " (consent-unicode-whitespace? #x205f)\n"
      " (consent-unicode-whitespace? #x2060)\n"
      " (consent-unicode-simple-uppercase #x101)\n"
      " (consent-unicode-simple-uppercase #x102)\n"
      " (consent-unicode-simple-uppercase #x103)\n"
      " (consent-unicode-full-uppercase #x1f80)\n"
      " (consent-unicode-full-uppercase #x1f87))"))
    (concat
     "(#t #t #t #f #t #t #t #t #f "
     "#f #t #f #t #t #t #t #f #t #f "
     "256 258 258 (7944 921) (7951 921))"))))

(ert-deftest consent-unicode-data-generator-test-validates-decimal-blocks ()
  "Accept complete decimal blocks and reject missing or incorrect digits."
  (should
   (equal
    (consent--unicode-decimal-block-starts
     (consent-unicode-data-generator-test--digit-table))
    '(#x30 #x660)))
  (should-error
   (consent--unicode-decimal-block-starts
    (consent-unicode-data-generator-test--digit-table
     (lambda (table) (remhash #x35 table)))))
  (should-error
   (consent--unicode-decimal-block-starts
    (consent-unicode-data-generator-test--digit-table
     (lambda (table) (puthash #x662 9 table))))))

(ert-deftest consent-unicode-data-generator-test-verifies-pinned-inputs ()
  "Reject missing and hash-mismatched pinned Unicode inputs."
  (let ((root (make-temp-file "consent-unicode-inputs-" t))
        (consent--unicode-input-hashes '(("Synthetic.txt" . "unused"))))
    (unwind-protect
        (progn
          (let ((condition
                 (should-error (consent--unicode-verify-inputs root))))
            (should
             (string-match-p "Missing Unicode input"
                             (error-message-string condition))))
          (let* ((path
                  (consent-unicode-data-generator-test--write-file
                   root "Synthetic.txt" "expected\n"))
                 (expected (consent--unicode-file-sha256 path)))
            (let ((consent--unicode-input-hashes
                   `(("Synthetic.txt" . ,expected))))
              (should-not (consent--unicode-verify-inputs root))
              (with-temp-file path
                (insert "changed\n"))
              (let ((condition
                     (should-error
                      (consent--unicode-verify-inputs root))))
                (should
                 (string-match-p
                  "Unicode input hash mismatch for Synthetic.txt"
                  (error-message-string condition)))))))
      (delete-directory root t))))

(ert-deftest consent-unicode-data-generator-test-versions-stay-coherent ()
  "Keep every Unicode version and provenance declaration synchronized."
  (let* ((makefile
          (consent-unicode-data-generator-test--repository-file "Makefile"))
         (manifest
          (consent-unicode-data-generator-test--repository-file
           "scheme/consent/manifest.sld"))
         (generated
          (consent-unicode-data-generator-test--repository-file
           "scheme/consent/unicode-data.sld"))
         (components
          (mapcar #'string-to-number
                  (split-string consent--unicode-data-version "\\." t)))
         (version-definition
          (consent-unicode-data-generator-test--generated-definition
           generated '%unicode-data-version))
         (metadata-definition
          (consent-unicode-data-generator-test--generated-definition
           generated '%unicode-data-metadata))
         (semantic-expectation
          (consent-unicode-data-generator-test--repository-datum
           "tests/fixtures/unicode-17.0.0-semantic-digest.scm"))
         (semantic-fields (cdr semantic-expectation))
         (generated-components (cadr (nth 2 version-definition)))
         (metadata (cadr (nth 2 metadata-definition)))
         (expected-metadata
          `((unicode-version ,consent--unicode-data-version)
            (source unicode-character-database)
            (license Unicode-3.0)
            (case-mapping default-non-turkic)
            (conditional-special-casing final-sigma-omitted)
            (fallback
             (unassigned classification-false mapping-identity))
            (inputs
             ,@(mapcar
                (lambda (entry)
                  `((file ,(car entry)) (sha256 ,(cdr entry))))
                consent--unicode-input-hashes)))))
    (should
     (string-match
      (concat "^CONSENT_UNICODE_VERSION[[:space:]]*[?]="
              "[[:space:]]*\\([^[:space:]#]+\\)[[:space:]]*$")
      makefile))
    (should (equal (match-string 1 makefile)
                   consent--unicode-data-version))
    (dolist (library '((scheme char) (consent unicode-data)))
      (should
       (equal
        (consent-unicode-data-generator-test--manifest-source-version
         manifest library)
        (cons 'unicode components))))
    (should (equal generated-components components))
    (should (equal metadata expected-metadata))
    (should (eq (car semantic-expectation)
                'consent-unicode-semantic-digest))
    (should
     (equal (mapcar #'car semantic-fields)
            '(schema unicode-version scalar-count byte-count sha256)))
    (should (cl-every (lambda (field) (= (length field) 2))
                      semantic-fields))
    (should (equal (cadr (assq 'schema semantic-fields)) 1))
    (should
     (equal (cadr (assq 'unicode-version semantic-fields))
            consent--unicode-data-version))
    (should (equal (cadr (assq 'scalar-count semantic-fields)) 1112064))
    (should (> (cadr (assq 'byte-count semantic-fields)) 0))
    (should
     (string-match-p
      "\\`[[:xdigit:]]\\{64\\}\\'"
      (cadr (assq 'sha256 semantic-fields))))))

(ert-deftest consent-unicode-data-generator-test-provenance-is-deep-copied ()
  "Keep nested generated input provenance private from callers."
  (let* ((first-input (car consent--unicode-input-hashes))
         (expected-file (car first-input))
         (expected-hash (cdr first-input)))
    (should
     (equal
      (consent-unicode-data-generator-test--external
       (concat
        "(import (scheme base) (consent unicode-data))\n"
        "(let* ((metadata (consent-unicode-data-metadata))\n"
        "       (inputs (cdr (assq 'inputs metadata)))\n"
        "       (input (car inputs))\n"
        "       (file (cadr (assq 'file input)))\n"
        "       (hash (cadr (assq 'sha256 input))))\n"
        "  (string-set! file 0 #\\X)\n"
        "  (string-set! hash 0 #\\0)\n"
        "  (set-car! input '(file \"poisoned\"))\n"
        "  (let* ((fresh (consent-unicode-data-metadata))\n"
        "         (fresh-input (car (cdr (assq 'inputs fresh)))))\n"
        "    (list (cadr (assq 'file fresh-input))\n"
        "          (cadr (assq 'sha256 fresh-input)))))"))
      (format "(\"%s\" \"%s\")" expected-file expected-hash)))))

(ert-deftest consent-unicode-data-generator-test-bounds-owned-source-size ()
  "Reject gross deterministic growth in owned character source data."
  (let* ((unicode-bytes
          (consent-unicode-data-generator-test--repository-file-size
           "scheme/consent/unicode-data.sld"))
         (bytes
          (+
           unicode-bytes
           (consent-unicode-data-generator-test--repository-file-size
            "scheme/consent/char.sld"))))
    (should
     (= unicode-bytes
        consent-unicode-data-generator-test--unicode-library-bytes))
    (should
     (<= bytes
         consent-unicode-data-generator-test--owned-library-byte-ceiling))))

(ert-deftest consent-unicode-data-generator-test-benchmark-schema-smoke ()
  "Keep benchmark metrics and records deterministic without timing gates."
  (let ((expected-metrics
         '(unicode.scheme-char.import.cold
           unicode.scheme-char.import.warm-fresh-context
           unicode.char-alphabetic.ascii.persistent
           unicode.char-alphabetic.bmp.persistent
           unicode.char-downcase.bmp-hit.persistent
           unicode.char-downcase.occupied-miss.persistent
           unicode.char-downcase.empty-bmp-miss.persistent
           unicode.char-upcase.supplementary-hit.persistent
           unicode.string-upcase.full.persistent))
        observed)
    (let ((process-environment (copy-sequence process-environment)))
      (setenv "CONSENT_UNICODE_BENCHMARK_ITERATIONS" "2")
      (setenv "CONSENT_UNICODE_BENCHMARK_IMPORT_ITERATIONS" "3")
      (cl-letf
          (((symbol-function 'consent--unicode-benchmark-measure)
            (lambda (metric iterations _thunk _validate)
              (push (list metric iterations) observed)))
           ((symbol-function
             'consent--unicode-benchmark-prepare-interaction)
            (lambda (_options) 'synthetic-interaction)))
        (consent--unicode-benchmark-run)))
    (should
     (equal (nreverse observed)
            '((unicode.scheme-char.import.cold 1)
              (unicode.scheme-char.import.warm-fresh-context 3)
              (unicode.char-alphabetic.ascii.persistent 2)
              (unicode.char-alphabetic.bmp.persistent 2)
              (unicode.char-downcase.bmp-hit.persistent 2)
              (unicode.char-downcase.occupied-miss.persistent 2)
              (unicode.char-downcase.empty-bmp-miss.persistent 2)
              (unicode.char-upcase.supplementary-hit.persistent 2)
              (unicode.string-upcase.full.persistent 2))))
    (should (equal consent--unicode-benchmark-metrics expected-metrics))
    (let* ((text
            (consent--unicode-benchmark-render
             'unicode.char-alphabetic.ascii.persistent
             4
             '(2.5 3 0.25)))
           (parsed (read-from-string text))
           (record (car parsed)))
      (should
       (string-match-p
        "\\`[[:space:]]*\\'" (substring text (cdr parsed))))
      (should
       (equal
        record
        '(consent-benchmark
          (schema-version 1)
          (metric unicode.char-alphabetic.ascii.persistent)
          (iterations 4)
          (seconds 2.5)
          (seconds-per-iteration 0.625)
          (garbage-collections 3)
          (garbage-collection-seconds 0.25))))
      (should-error
       (consent--unicode-benchmark-render
        'unicode.unknown 1 '(0.0 0 0.0)))
      (should-error
       (consent--unicode-benchmark-render
        'unicode.char-alphabetic.ascii.persistent 0 '(0.0 0 0.0)))
      (should-error
       (consent--unicode-benchmark-render
        'unicode.char-alphabetic.ascii.persistent 1 '(-1.0 0 0.0))))))

(ert-deftest consent-unicode-data-generator-test-checks-output-freshness ()
  "Write deterministic output and reject stale or missing checked output."
  (let* ((root (make-temp-file "consent-unicode-output-" t))
         (output (expand-file-name "generated/unicode-data.sld" root))
         (text "synthetic generated output\n"))
    (unwind-protect
        (progn
          (consent--unicode-write-or-check text output nil)
          (should (equal
                   (with-temp-buffer
                     (insert-file-contents-literally output)
                     (buffer-string))
                   text))
          (should
           (string-match-p
            "Unicode data is current"
            (consent--unicode-write-or-check text output t)))
          (with-temp-file output
            (insert "stale output\n"))
          (should-error (consent--unicode-write-or-check text output t))
          (delete-file output)
          (should-error (consent--unicode-write-or-check text output t)))
      (delete-directory root t))))

;;; consent-unicode-data-generator-test.el ends here
