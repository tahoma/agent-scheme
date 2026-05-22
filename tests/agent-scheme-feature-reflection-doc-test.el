;;; agent-scheme-feature-reflection-doc-test.el --- Feature reflection doc checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the public docs explain feature and host reflection across
;; static library selection, implementation features, and host-adapter datums.

;;; Code:

(require 'ert)

(defun agent-scheme-feature-reflection-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-feature-reflection-doc-test-covers-reflection-guidance ()
  "Ensure feature reflection guidance is documented and linked."
  (let ((doc-path (expand-file-name
                   "docs/feature-reflection.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((readme
           (agent-scheme-feature-reflection-doc-test--read "README.md"))
          (architecture
           (agent-scheme-feature-reflection-doc-test--read
            "docs/architecture.md"))
          (multi-host
           (agent-scheme-feature-reflection-doc-test--read
            "docs/multi-host-bootstrap.md"))
          (native
           (agent-scheme-feature-reflection-doc-test--read
            "docs/native-cli-daemon-adapter.md"))
          (doc
           (agent-scheme-feature-reflection-doc-test--read
            "docs/feature-reflection.md")))
      (dolist (linked-doc (list readme architecture multi-host native))
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
                 "Availability is not authority"
                 "#229"
                 "#234"
                 "#235"
                 "#236"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; agent-scheme-feature-reflection-doc-test.el ends here
