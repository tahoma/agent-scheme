;;; consent-helper-doc-test.el --- Helper artifact documentation checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Verifies that helper artifact workflow documentation covers the public
;; boundary introduced by issue 23.

;;; Code:

(require 'ert)

(defun consent-helper-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(ert-deftest consent-helper-doc-test-covers-helper-artifact-workflow ()
  "Ensure helper libraries and artifacts are documented."
  (let ((doc-path (expand-file-name
                   "docs/helper-artifacts.md"
                   consent--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (consent-helper-doc-test--read "docs/architecture.md"))
          (multi-host
           (consent-helper-doc-test--read "docs/multi-host-bootstrap.md"))
          (doc
           (consent-helper-doc-test--read "docs/helper-artifacts.md")))
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
                 "packaged Consent Scheme skills"
                 "SKILL.scm"
                 "examples"
                 "references"
                 "tests"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; consent-helper-doc-test.el ends here
