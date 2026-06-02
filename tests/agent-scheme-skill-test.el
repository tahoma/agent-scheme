;;; agent-scheme-skill-test.el --- Agent Skills helper tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for concrete Agent Skills helpers that route filesystem skill
;; operations through shared policy gates and return Scheme-readable datums.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)
(require 'agent-scheme-skill nil t)

(defun agent-scheme-skill-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-skill-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-skill-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-skill-test--audit-strings)))

(defun agent-scheme-skill-test--make-skill-directory ()
  "Create and return a temporary Agent Skill directory."
  (let* ((root (make-temp-file "agent-scheme-skill-test-" t))
         (directory (expand-file-name "example-skill" root)))
    (make-directory directory)
    (make-directory (expand-file-name "scripts" directory))
    (with-temp-file (expand-file-name "SKILL.md" directory)
      (insert "---\n")
      (insert "name: example-skill\n")
      (insert "description: Example skill\n")
      (insert "---\n")
      (insert "# Example Skill\n\nUse this skill for tests.\n"))
    (with-temp-file (expand-file-name "scripts/run.sh" directory)
      (insert "#!/bin/sh\n")
      (insert "printf '%s\\n' example-skill\n"))
    (set-file-modes (expand-file-name "scripts/run.sh" directory) #o755)
    directory))

(defun agent-scheme-skill-test--make-grant-skill-directory ()
  "Create a temporary skill directory that declares requested grants."
  (let* ((root (make-temp-file "agent-scheme-skill-grant-test-" t))
         (directory (expand-file-name "grant-skill" root)))
    (make-directory directory)
    (with-temp-file (expand-file-name "SKILL.md" directory)
      (insert "---\n")
      (insert "name: grant-skill\n")
      (insert "description: Grant requesting skill\n")
      (insert "requested-grants: ((capability-grant (library (emacs buffer edit)) (effect buffer-replace!) (scope (skill grant-skill) (range 1 2)) (expires after-eval)))\n")
      (insert "---\n")
      (insert "# Grant Skill\n\nUse this skill for grant declaration tests.\n"))
    directory))

(defmacro agent-scheme-skill-test--with-temp-skill (directory-var &rest body)
  "Bind DIRECTORY-VAR to a temporary skill directory while running BODY."
  (declare (indent 1))
  `(let ((,directory-var (agent-scheme-skill-test--make-skill-directory)))
     (unwind-protect
         (progn ,@body)
       (delete-directory (file-name-directory
                          (directory-file-name ,directory-var))
                         t))))

(ert-deftest agent-scheme-skill-test-import-normalizes-skill-directory ()
  "Import a skill directory through resource-read policy."
  (should (featurep 'agent-scheme-skill))
  (should (fboundp 'agent-scheme-skill-import))
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-skill-test--actions
          '((skill-resource-read . allow)))))
    (agent-scheme-audit-clear)
    (agent-scheme-skill-test--with-temp-skill directory
      (let ((external
             (agent-scheme-result->external
              (agent-scheme-skill-import
               directory
               '(:trust project-approved)))))
        (should (string-match-p "(agent-skill" external))
        (should (string-match-p "(name \"example-skill\")" external))
        (should (string-match-p "(trust project-approved)" external))
        (should (string-match-p
                 (regexp-quote "(instructions (markdown-resource \"SKILL.md\"))")
                 external))
        (should
         (agent-scheme-skill-test--audit-entry-matching
          "(event skill-resource)"
          "(category skill-resource-read)"
          "(skill-name \"example-skill\")"
          "(decision allowed)"))))))

(ert-deftest agent-scheme-skill-test-import-declares-requested-grants-only ()
  "Imported skills can request grants without receiving them automatically."
  (should (featurep 'agent-scheme-skill))
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-skill-test--actions
          '((skill-resource-read . allow)))))
    (agent-scheme-audit-clear)
    (let ((directory (agent-scheme-skill-test--make-grant-skill-directory)))
      (unwind-protect
          (let ((external
                 (agent-scheme-result->external
                  (agent-scheme-skill-import directory))))
            (should (string-match-p "(agent-skill" external))
            (should (string-match-p "(name \"grant-skill\")" external))
            (should (string-match-p "(requested-grants ((capability-grant" external))
            (should (string-match-p "(scope (skill grant-skill) (range 1 2))"
                                    external))
            (should
             (equal
              (agent-scheme-value->external
               (agent-scheme-eval-source
                "(import (agent capability))
                 (current-grants)"))
              "()")))
        (delete-directory (file-name-directory
                           (directory-file-name directory))
                          t)))))

(ert-deftest agent-scheme-skill-test-trust-and-activate-audit-decisions ()
  "Authorize project trust and activate a concrete skill directory."
  (should (featurep 'agent-scheme-skill))
  (should (fboundp 'agent-scheme-skill-trust-project))
  (should (fboundp 'agent-scheme-skill-activate))
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-skill-test--actions
          '((project-skill-trust . allow)
            (skill-discovery-activation . allow)
            (skill-resource-read . allow)))))
    (agent-scheme-audit-clear)
    (agent-scheme-skill-test--with-temp-skill directory
      (let ((project-directory
             (file-name-directory (directory-file-name directory))))
        (agent-scheme-skill-trust-project "example-project" project-directory)
        (agent-scheme-skill-activate directory '(:trust-scope project))
        (should
         (agent-scheme-skill-test--audit-entry-matching
          "(event trust-decision)"
          "(project \"example-project\")"
          "(decision allowed)"))
        (should
         (agent-scheme-skill-test--audit-entry-matching
          "(event skill-activation)"
          "(skill-name \"example-skill\")"
          "(trust-scope project)"
          "(decision allowed)"))))))

(ert-deftest agent-scheme-skill-test-export-writes-skill-package-after-policy ()
  "Export a normalized skill datum only after export-write policy approval."
  (should (featurep 'agent-scheme-skill))
  (should (fboundp 'agent-scheme-skill-export))
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-skill-test--actions
          '((skill-resource-read . allow)
            (skill-export-write . allow)))))
    (agent-scheme-audit-clear)
    (agent-scheme-skill-test--with-temp-skill source-directory
      (let* ((root (make-temp-file "agent-scheme-skill-export-test-" t))
             (export-directory (expand-file-name "exported-skill" root))
             (datum (agent-scheme-skill-import source-directory)))
        (unwind-protect
            (progn
              (agent-scheme-skill-export datum export-directory)
              (should
               (file-exists-p (expand-file-name "SKILL.md" export-directory)))
              (should
               (string-match-p
                "# Example Skill"
                (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "SKILL.md" export-directory))
                  (buffer-string))))
              (should
               (agent-scheme-skill-test--audit-entry-matching
                "(event skill-export)"
                "(category skill-export-write)"
                "(skill-name \"example-skill\")"
                "(decision allowed)")))
          (delete-directory root t))))))

(ert-deftest agent-scheme-skill-test-read-resource-helper-audits-denial ()
  "Audit direct resource-read helper denials before reading skill files."
  (should (featurep 'agent-scheme-skill))
  (should (fboundp 'agent-scheme-skill-read-resource))
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-skill-test--actions
          '((skill-resource-read . deny)))))
    (agent-scheme-audit-clear)
    (agent-scheme-skill-test--with-temp-skill directory
      (should-error
       (agent-scheme-skill-read-resource
        directory "SKILL.md" '(:skill-name "example-skill"))
       :type 'agent-scheme-policy-error)
      (should
       (agent-scheme-skill-test--audit-entry-matching
        "(event skill-resource)"
        "(category skill-resource-read)"
        "(skill-name \"example-skill\")"
        "(resource-path"
        "SKILL.md"
        "(decision denied)")))))

(ert-deftest agent-scheme-skill-test-bundled-script-request-audits-confirmation ()
  "Audit bundled script execution requests with confirmation decisions."
  (should (featurep 'agent-scheme-skill))
  (should (fboundp 'agent-scheme-skill-script-execution-request))
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-skill-test--actions
          '((skill-script-execution . confirm))))
        (agent-scheme-policy-confirmation-function (lambda (_request) t)))
    (agent-scheme-audit-clear)
    (agent-scheme-skill-test--with-temp-skill directory
      (let ((external
             (agent-scheme-result->external
              (agent-scheme-skill-script-execution-request
               directory "scripts/run.sh"
               '(:skill-name "example-skill")))))
        (should (string-match-p "(skill-script-execution" external))
        (should (string-match-p "(skill-name \"example-skill\")" external))
        (should (string-match-p "(decision authorized)" external))
        (should
         (agent-scheme-skill-test--audit-entry-matching
          "(event skill-script)"
          "(category skill-script-execution)"
          "(skill-name \"example-skill\")"
          "(script-path"
          "scripts/run.sh"
          "(decision confirmed)"))))))

;;; agent-scheme-skill-test.el ends here
