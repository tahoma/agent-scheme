;;; agent-scheme-native-cli-daemon-doc-test.el --- Native CLI daemon contract doc checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the native CLI and daemon adapter contract covers the design
;; requirements requested by issue 136.

;;; Code:

(require 'ert)

(defun agent-scheme-native-cli-daemon-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-native-cli-daemon-doc-test-covers-issue-136 ()
  "Ensure the native CLI and daemon design documents required semantics."
  (let ((doc-path (expand-file-name
                   "docs/native-cli-daemon-adapter.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (agent-scheme-native-cli-daemon-doc-test--read
            "docs/architecture.md"))
          (multi-host
           (agent-scheme-native-cli-daemon-doc-test--read
            "docs/multi-host-bootstrap.md"))
          (readme
           (agent-scheme-native-cli-daemon-doc-test--read
            "README.md"))
          (doc
           (agent-scheme-native-cli-daemon-doc-test--read
            "docs/native-cli-daemon-adapter.md")))
      (dolist (needle
               '("native-cli-daemon-adapter.md"
                 "Native CLI and Daemon Adapter Contract"))
        (should (string-match-p (regexp-quote needle) architecture))
        (should (string-match-p (regexp-quote needle) multi-host))
        (should (string-match-p (regexp-quote needle) readme)))
      (dolist (needle
               '("# Native CLI and Daemon Adapter Contract"
                 "## Adapter Declaration"
                 "## Initial Capability Libraries"
                 "## Handles and Liveness"
                 "## Prompt Policy"
                 "## Boundary Records"
                 "## Interpreted and Compiled Execution"
                 "## Test Strategy"
                 "## Acceptance and First Executable Slice"
                 "(host-adapter"
                 "(name native-cli-daemon)"
                 "(library (cli cwd))"
                 "(library (cli process))"
                 "(library (cli daemon))"
                 "(library (cli audit))"
                 "filesystem-read"
                 "process-control"
                 "daemon-control"
                 "audit-export"
                 "noninteractive-confirmation-unavailable"
                 "adapter-result"
                 "adapter-event"
                 "adapter-audit"
                 "adapter-error"
                 "shared-capability-request"
                 "stale-handle"
                 "portable contract validation"
                 "real process-boundary coverage"
                 "first executable slice"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; agent-scheme-native-cli-daemon-doc-test.el ends here
