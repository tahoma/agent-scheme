;;; agent-scheme-vcs-doc-test.el --- VCS contract doc checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the shared VCS capability contract covers the design
;; requirements requested by issue 266.

;;; Code:

(require 'ert)

(defun agent-scheme-vcs-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-vcs-doc-test-covers-issue-266 ()
  "Ensure the VCS design documents required semantics."
  (let ((doc-path (expand-file-name
                   "docs/vcs-capability.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (agent-scheme-vcs-doc-test--read "docs/architecture.md"))
          (multi-host
           (agent-scheme-vcs-doc-test--read "docs/multi-host-bootstrap.md"))
          (doc
           (agent-scheme-vcs-doc-test--read "docs/vcs-capability.md")))
      (dolist (needle
               '("vcs-capability.md"
                 "Shared VCS Capability Contract"))
        (should (string-match-p (regexp-quote needle) architecture))
        (should (string-match-p (regexp-quote needle) multi-host)))
      (dolist (needle
               '("# Shared VCS Capability Contract"
                 "## Datum Vocabulary"
                 "## Git Parser Fixtures"
                 "## Capability Requests"
                 "## Read-Only Versus Mutation"
                 "## Mutation Authority"
                 "## Outcomes"
                 "## SRFI Relationship"
                 "(agent vcs)"
                 "vcs-repository"
                 "vcs-branch"
                 "vcs-status-entry"
                 "vcs-diff-summary"
                 "vcs-capability-request"
                 "vcs-capability-result"
                 "vcs-capability-grant"
                 "vcs-capability-decision"
                 "vcs-capability-audit"
                 "vcs-approval-decision"
                 "repository-mutation"
                 "remote-mutation"
                 "git status --porcelain=v2 -z"
                 "git diff --raw -z"
                 "no-vcs"
                 "unsupported-vcs"
                 "git-not-found"
                 "dirty-index"
                 "conflict"
                 "timeout"
                 "permission-denied"
                 "remote-authentication-failed"
                 "remote-unavailable"
                 "not an SRFI compatibility target"))
        (should (string-match-p (regexp-quote needle) doc))))))

(ert-deftest agent-scheme-vcs-doc-test-covers-emacs-adapter ()
  "Ensure the Emacs VCS adapter docs preserve the host/core boundary."
  (let ((architecture
         (agent-scheme-vcs-doc-test--read "docs/architecture.md"))
        (readme
         (agent-scheme-vcs-doc-test--read "README.md"))
        (doc
         (agent-scheme-vcs-doc-test--read "docs/vcs-capability.md")))
    (dolist (needle
             '("(emacs vcs)"
               "vcs-root"
               "vcs-branch"
               "vcs-status"
               "vcs-diff"
               "vcs-recent-commits"
               "vcs-yield"))
      (should (string-match-p (regexp-quote needle) architecture))
      (should (string-match-p (regexp-quote needle) readme))
      (should (string-match-p (regexp-quote needle) doc)))
    (dolist (needle
             '("read-only adapter"
               "No repository mutation is exported by `(emacs vcs)`"
               "Stage, unstage, commit"
               "fetch, pull, push"))
      (should (string-match-p (regexp-quote needle) doc)))
    (should
     (string-match-p
      (regexp-quote
       "Repository mutation, including stage, commit, branch creation, fetch, pull, and")
      readme))))

;;; agent-scheme-vcs-doc-test.el ends here
