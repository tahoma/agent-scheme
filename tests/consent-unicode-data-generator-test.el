;;; consent-unicode-data-generator-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused unit tests for the pinned Unicode Character Database generator.

;;; Code:

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
     t)))

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

(ert-deftest consent-unicode-data-generator-test-merges-splits-and-indexes ()
  "Merge ranges and split them across BMP pages and Unicode planes."
  (should
   (equal
    (consent--unicode-merge-ranges
     '((#x100 . #x101) (#xff . #xff) (#x105 . #x106)
       (#x102 . #x105)))
    '((#xff . #x106))))
  (let* ((split
          (consent--unicode-split-ranges
           '((#xfe . #x101) (#xffff . #x10001)
             (#x10ffff . #x10ffff))))
         (index (consent--unicode-bucket-index split #'car)))
    (should
     (equal split
            '((#xfe . #xff) (#x100 . #x101) (#xffff . #xffff)
              (#x10000 . #x10001) (#x10ffff . #x10ffff))))
    (should (= (length index) 273))
    (should (= (nth 0 index) 0))
    (should (= (nth 1 index) 1))
    (should (= (nth 255 index) 2))
    (should (= (nth 256 index) 3))
    (should (= (nth 257 index) 4))
    (should (= (nth 271 index) 4))
    (should (= (nth 272 index) 5)))
  (should-error
   (consent--unicode-bucket-index
    '((#x110000 . #x110000)) #'car)))

(ert-deftest consent-unicode-data-generator-test-compacts-mapping-segments ()
  "Compact equal deltas without joining entries across index buckets."
  (let ((table (make-hash-table :test #'eql))
        (full (make-hash-table :test #'eql))
        (fallback (make-hash-table :test #'eql)))
    (dolist (entry '((#x41 #x61) (#x42 #x62) (#xff #x100)
                     (#x100 #x101) (#x102 #x104)))
      (puthash (car entry) (cdr entry) table))
    (should
     (equal
      (consent--unicode-simple-mapping-segments table)
      '((#x41 #x42 32) (#xff #xff 1) (#x100 #x100 1)
        (#x102 #x102 2))))
    (puthash #x41 '(#x61) fallback)
    (puthash #x42 '(#x62) fallback)
    (puthash #x41 '(#x61) full)
    (puthash #x43 '(#x44) full)
    (should
     (equal
      (consent--unicode-table-entries
       (consent--unicode-mapping-overrides full fallback))
      '((#x42 #x42) (#x43 #x44))))))

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
  "Keep every checked-in Unicode version declaration synchronized."
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
         (generated-components (cadr (nth 2 version-definition)))
         (metadata (cadr (nth 2 metadata-definition))))
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
    (should
     (equal (cadr (assq 'unicode-version metadata))
            consent--unicode-data-version))))

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
