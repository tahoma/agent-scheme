;;; consent-native-cli-daemon-doc-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Verifies that the native CLI and daemon adapter contract covers the design
;; requirements requested by issue 136.

;;; Code:

(require 'ert)

(defun consent-native-cli-daemon-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(ert-deftest consent-native-cli-daemon-doc-test-covers-issue-136 ()
  "Ensure the native CLI and daemon design documents required semantics."
  (let ((doc-path (expand-file-name
                   "docs/native-cli-daemon-adapter.md"
                   consent--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (consent-native-cli-daemon-doc-test--read
            "docs/architecture.md"))
          (multi-host
           (consent-native-cli-daemon-doc-test--read
            "docs/multi-host-bootstrap.md"))
          (index
           (consent-native-cli-daemon-doc-test--read
            "docs/README.md"))
          (doc
           (consent-native-cli-daemon-doc-test--read
            "docs/native-cli-daemon-adapter.md")))
      (dolist (needle
               '("native-cli-daemon-adapter.md"
                 "Native CLI and Daemon Adapter Contract"))
        (should (string-match-p (regexp-quote needle) architecture))
        (should (string-match-p (regexp-quote needle) multi-host))
        (should (string-match-p (regexp-quote needle) index)))
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

;;; consent-native-cli-daemon-doc-test.el ends here
