;;; agent-scheme-helper-doc-test.el --- Helper artifact documentation checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that helper artifact workflow documentation covers the public
;; boundary introduced by issue 23.

;;; Code:

(require 'ert)

(defun agent-scheme-helper-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-helper-doc-test-covers-helper-artifact-workflow ()
  "Ensure helper libraries and artifacts are documented."
  (let ((doc-path (expand-file-name
                   "docs/helper-artifacts.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (agent-scheme-helper-doc-test--read "docs/architecture.md"))
          (multi-host
           (agent-scheme-helper-doc-test--read "docs/multi-host-bootstrap.md"))
          (doc
           (agent-scheme-helper-doc-test--read "docs/helper-artifacts.md")))
      (dolist (needle
               '("helper-artifacts.md"
                 "Helper Libraries and Artifacts"))
        (should (string-match-p (regexp-quote needle) architecture))
        (should (string-match-p (regexp-quote needle) multi-host)))
      (dolist (needle
               '("# Helper Libraries and Artifacts"
                 "(agent helper)"
                 "agent-artifact"
                 "agent-helper-save!"
                 "agent-helper-load"
                 "agent-helper-list"
                 "agent-helper-promote-to-skill"
                 "session-local"
                 "project-private"
                 "project-tracked"
                 "helper-tracked-write"
                 "helper-skill-candidate-write"
                 "(agent io)"
                 "(agent memory)"
                 "R7RS standard libraries"
                 "Emacs capability libraries"
                 "packaged Agent Scheme skills"
                 "SKILL.scm"
                 "examples"
                 "references"
                 "tests"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; agent-scheme-helper-doc-test.el ends here
