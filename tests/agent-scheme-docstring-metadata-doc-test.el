;;; agent-scheme-docstring-metadata-doc-test.el --- Docstring metadata doc checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the docstring metadata convention covers the public design
;; contract requested by issue 300.

;;; Code:

(require 'ert)

(defun agent-scheme-docstring-metadata-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-docstring-metadata-doc-test-covers-issue-300 ()
  "Ensure the docstring metadata convention is documented and linked."
  (let ((doc-path (expand-file-name
                   "docs/docstring-metadata.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((readme
           (agent-scheme-docstring-metadata-doc-test--read "README.md"))
          (architecture
           (agent-scheme-docstring-metadata-doc-test--read
            "docs/architecture.md"))
          (development
           (agent-scheme-docstring-metadata-doc-test--read
            "docs/development.md"))
          (references
           (agent-scheme-docstring-metadata-doc-test--read
            "docs/references.md"))
          (doc
           (agent-scheme-docstring-metadata-doc-test--read
            "docs/docstring-metadata.md")))
      (dolist (linked-doc (list readme architecture development references))
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
                 "A string or future rich property record in final position"
                 "Adjacent simple strings in metadata position"
                 "\"Return the arithmetic sum of XS.\\nXS must be a list of numbers.\""
                 "#((documentation ."
                 "The simple string form and rich property form may appear together"
                 "No metadata is also valid"
                 "procedure shorthand `define`"
                 "`lambda` expressions"
                 "`case-lambda` clause body"
                 "`define-syntax` and macro exports"
                 "`define-record-type` and record fields"
                 "`define-library` forms"
                 "re-exported or renamed bindings"
                 "(documentation-metadata"
                 "(origin (body-literal string))"
                 "`malformed-documentation-metadata`"
                 "Guile's procedure-property"
                 "style as an influence"
                 "#301 implements simple string docstrings"
                 "#303 implements rich documentation property records"
                 "#304 preserves documentation metadata"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; agent-scheme-docstring-metadata-doc-test.el ends here
