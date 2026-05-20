;;; agent-scheme-capability-environment-doc-test.el --- Capability design doc checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the capability environment architecture note covers the
;; design contract requested by issue 102.

;;; Code:

(require 'ert)

(defun agent-scheme-capability-environment-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-capability-environment-doc-test-covers-issue-102 ()
  "Ensure the capability environment design documents required semantics."
  (let ((doc-path (expand-file-name
                   "docs/capability-environment.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (agent-scheme-capability-environment-doc-test--read
            "docs/architecture.md"))
          (doc
           (agent-scheme-capability-environment-doc-test--read
            "docs/capability-environment.md")))
      (dolist (needle
               '("capability-environment.md"
                 "Capability Environment and Effect Lowering"))
        (should (string-match-p (regexp-quote needle) architecture)))
      (dolist (needle
               '("# Capability Environment and Effect Lowering"
                 "## Capability Environment Datum"
                 "## Grant Resolution"
                 "## Capability Domains"
                 "## File Sandboxing"
                 "## Port Sandboxing"
                 "## Revocation and Stale Handles"
                 "## Effect Lowering"
                 "## Follow-Up Implementation Issues"
                 "(capability-environment"
                 "(capability-request"
                 "(capability-decision"
                 "(capability-revocation"
                 "(capability-audit"
                 "task > session > project > user > defaults"
                 "file capabilities"
                 "port capabilities"
                 "process capabilities"
                 "provider capabilities"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; agent-scheme-capability-environment-doc-test.el ends here
