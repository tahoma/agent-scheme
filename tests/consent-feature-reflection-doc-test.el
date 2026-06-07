;;; consent-feature-reflection-doc-test.el --- Feature reflection doc checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Verifies that the public docs explain feature and host reflection across
;; static library selection, implementation features, and host-adapter datums.

;;; Code:

(require 'ert)

(defun consent-feature-reflection-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(ert-deftest consent-feature-reflection-doc-test-covers-reflection-guidance ()
  "Ensure feature reflection guidance is documented and linked."
  (let ((doc-path (expand-file-name
                   "docs/feature-reflection.md"
                   consent--test-root)))
    (should (file-exists-p doc-path))
    (let ((index
           (consent-feature-reflection-doc-test--read "docs/README.md"))
          (architecture
           (consent-feature-reflection-doc-test--read
            "docs/architecture.md"))
          (multi-host
           (consent-feature-reflection-doc-test--read
            "docs/multi-host-bootstrap.md"))
          (native
           (consent-feature-reflection-doc-test--read
            "docs/native-cli-daemon-adapter.md"))
          (doc
           (consent-feature-reflection-doc-test--read
            "docs/feature-reflection.md")))
      (dolist (linked-doc (list index architecture multi-host native))
        (should (string-match-p
                 (regexp-quote "feature-reflection.md")
                 linked-doc)))
      (dolist (needle
               '("# Feature and Host Reflection"
                 "## Static Library Selection"
                 "## Implementation Features"
                 "## Runtime Adapter Reflection"
                 "## Host Effects"
                 "## Current Implementation Status"
                 "cond-expand"
                 "(library (emacs buffer))"
                 "(library (cli process))"
                 "(features)"
                 "(current-host-adapter)"
                 "(host-adapter"
                 "(current-host-capabilities)"
                 "(host-capability"
                 "## Runtime Reflection Library"
                 "(agent reflect)"
                 "(current-capabilities)"
                 "(current-budget)"
                 "(recent-yields)"
                 "(recent-policy-decisions)"
                 "Availability is not authority"
                 "fixtures/host-adapters/emacs.scm"
                 "(name emacs)"
                 "#229"
                 "#235"
                 "#236"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; consent-feature-reflection-doc-test.el ends here
