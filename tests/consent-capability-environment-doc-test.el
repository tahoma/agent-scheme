;;; consent-capability-environment-doc-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Verifies that the capability environment architecture note covers the
;; design contract requested by issue 102.

;;; Code:

(require 'ert)

(defun consent-capability-environment-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(ert-deftest consent-capability-environment-doc-test-covers-issue-102 ()
  "Ensure the capability environment design documents required semantics."
  (let ((doc-path (expand-file-name
                   "docs/capability-environment.md"
                   consent--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (consent-capability-environment-doc-test--read
            "docs/architecture.md"))
          (doc
           (consent-capability-environment-doc-test--read
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
                 "## Backend Effect Contract"
                 "backend-effect-path"
                 "shared-capability-request"
                 "no backend may bypass policy"
                 "allowed, denied, revoked, and stale"
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

;;; consent-capability-environment-doc-test.el ends here
