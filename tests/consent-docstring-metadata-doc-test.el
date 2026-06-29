;;; consent-docstring-metadata-doc-test.el --- Docstring metadata doc checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Verifies that the docstring metadata convention covers the public design
;; contract requested by issue 300.

;;; Code:

(require 'ert)

(defun consent-docstring-metadata-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(ert-deftest consent-docstring-metadata-doc-test-covers-issue-300 ()
  "Ensure the docstring metadata convention is documented and linked."
  (let ((doc-path (expand-file-name
                   "docs/docstring-metadata.md"
                   consent--test-root)))
    (should (file-exists-p doc-path))
    (let ((index
           (consent-docstring-metadata-doc-test--read "docs/README.md"))
          (architecture
           (consent-docstring-metadata-doc-test--read
            "docs/architecture.md"))
          (development
           (consent-docstring-metadata-doc-test--read
            "docs/development.md"))
          (references
           (consent-docstring-metadata-doc-test--read
            "docs/references.md"))
          (doc
           (consent-docstring-metadata-doc-test--read
            "docs/docstring-metadata.md")))
      (dolist (linked-doc (list index architecture development references))
        (should (string-match-p
                 (regexp-quote "docstring-metadata.md")
                 linked-doc)))
      (dolist (needle
               '("# Docstring Metadata Convention"
                 "## R7RS Compatibility"
                 "## Simple String Form"
                 "## Rich Property Records"
                 "## Applies To"
                 "## Metadata Records"
                 "## Merge and Malformed Rules"
                 "## Implementation Status"
                 "Comments remain source-only"
                 "standard R7RS reader does not"
                 "return comments as datums"
                 "Internal definitions come first"
                 "At least one non-metadata body expression must remain"
	                 "A string or rich property record in final position"
	                 "Adjacent simple strings in metadata position"
	                 "\"Return the arithmetic sum of XS. XS must be a list of numbers.\""
	                 "#((documentation ."
	                 "Parameter and return descriptors"
	                 "`(type any)` is the top type"
	                 "`returns` may appear at most once"
	                 "The simple string form and rich property form may appear together"
                 "Procedures with no body-literal documentation still expose their signature"
                 "procedure shorthand `define`"
                 "`lambda` expressions"
                 "`case-lambda` clause body"
                 "`docstring-retention` option"
                 "`full` is the default"
                 "`simple` keeps generated `arguments`"
                 "`none`, Emacs Lisp `nil`, and Scheme `#f`"
                 "`define-syntax` and macro exports"
                 "`define-record-type` and record fields"
                 "`define-library` forms"
                 "re-exported or renamed bindings"
                 "(documentation-metadata"
                 "(origin (signature))"
                 "(origin (body-literal string))"
                 "(origin (body-literal string vector))"
                 "(origin (primitive-manifest metadata))"
                 "(origin (primitive-manifest string))"
                 "(origin (implementation-procedure string))"
                 "`arguments`: the procedure formals"
                 "manifest-backed primitive documentation"
                 "Every `parameters` key must be present"
                 "`malformed-documentation-metadata`"
                 "Guile's procedure-property"
                 "influence, but the fields"
                 "#301 implements simple string docstrings"
	                 "#303 implements rich documentation property records"
	                 "#344 adds manifest-backed primitive documentation"
	                 "#304 preserves documentation metadata"
	                 "#325 adds evaluator docstring retention modes"
	                 "#604 adds typed parameter and return descriptors"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; consent-docstring-metadata-doc-test.el ends here
