;;; consent-skill-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for concrete Agent Skills helpers that route filesystem skill
;; operations through shared policy gates and return Scheme-readable datums.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-policy)
(require 'consent-result)
(require 'consent-skill nil t)

(defun consent-skill-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           consent-policy-category-actions)))

(defun consent-skill-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-skill-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-skill-test--audit-strings)))

(defun consent-skill-test--make-skill-directory ()
  "Create and return a temporary Agent Skill directory."
  (let* ((root (make-temp-file "consent-skill-test-" t))
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

(defun consent-skill-test--make-grant-skill-directory ()
  "Create a temporary skill directory that declares requested grants."
  (let* ((root (make-temp-file "consent-skill-grant-test-" t))
         (directory (expand-file-name "grant-skill" root)))
    (make-directory directory)
    (with-temp-file (expand-file-name "SKILL.md" directory)
      (insert "---\n")
      (insert "name: grant-skill\n")
      (insert "description: Grant requesting skill\n")
      (insert
        "requested-grants: ((capability-grant (library (emacs buffer edit))\
 (effect buffer-replace!) (scope (skill grant-skill) (range 1 2)) (expires\
 after-eval)))\n")
      (insert "---\n")
      (insert
        "# Grant Skill\n\nUse this skill for grant declaration tests.\n"))
    directory))

(defmacro consent-skill-test--with-temp-skill (directory-var &rest body)
  "Bind DIRECTORY-VAR to a temporary skill directory while running BODY."
  (declare (indent 1))
  `(let ((,directory-var (consent-skill-test--make-skill-directory)))
     (unwind-protect
         (progn ,@body)
       (delete-directory (file-name-directory
                          (directory-file-name ,directory-var))
                         t))))

(ert-deftest consent-skill-test-import-normalizes-skill-directory ()
  "Import a skill directory through resource-read policy."
  (should (featurep 'consent-skill))
  (should (fboundp 'consent-skill-import))
  (let ((consent-policy-category-actions
         (consent-skill-test--actions
          '((skill-resource-read . allow)))))
    (consent-audit-clear)
    (consent-skill-test--with-temp-skill directory
      (let ((external
             (consent-result->external
              (consent-skill-import
               directory
               '(:trust project-approved)))))
        (should (string-match-p "(agent-skill" external))
        (should (string-match-p "(name \"example-skill\")" external))
        (should (string-match-p "(trust project-approved)" external))
        (should (string-match-p
                 (regexp-quote
                   "(instructions (markdown-resource \"SKILL.md\"))")
                 external))
        (should
         (consent-skill-test--audit-entry-matching
          "(event skill-resource)"
          "(category skill-resource-read)"
          "(skill-name \"example-skill\")"
          "(decision allowed)"))))))

(ert-deftest consent-skill-test-import-declares-requested-grants-only ()
  "Imported skills can request grants without receiving them automatically."
  (should (featurep 'consent-skill))
  (let ((consent-policy-category-actions
         (consent-skill-test--actions
          '((skill-resource-read . allow)))))
    (consent-audit-clear)
    (let ((directory (consent-skill-test--make-grant-skill-directory)))
      (unwind-protect
          (let ((external
                 (consent-result->external
                  (consent-skill-import directory))))
            (should (string-match-p "(agent-skill" external))
            (should (string-match-p "(name \"grant-skill\")" external))
            (should (string-match-p "(requested-grants ((capability-grant"
              external))
            (should (string-match-p "(scope (skill grant-skill) (range 1 2))"
                                    external))
            (should
             (equal
              (consent-value->external
               (consent-eval-source
                "(import (consent capability))
                 (current-grants)"))
              "()")))
        (delete-directory (file-name-directory
                           (directory-file-name directory))
                          t)))))

(ert-deftest consent-skill-test-trust-and-activate-audit-decisions ()
  "Authorize project trust and activate a concrete skill directory."
  (should (featurep 'consent-skill))
  (should (fboundp 'consent-skill-trust-project))
  (should (fboundp 'consent-skill-activate))
  (let ((consent-policy-category-actions
         (consent-skill-test--actions
          '((project-skill-trust . allow)
            (skill-discovery-activation . allow)
            (skill-resource-read . allow)))))
    (consent-audit-clear)
    (consent-skill-test--with-temp-skill directory
      (let ((project-directory
             (file-name-directory (directory-file-name directory))))
        (consent-skill-trust-project "example-project" project-directory)
        (consent-skill-activate directory '(:trust-scope project))
        (should
         (consent-skill-test--audit-entry-matching
          "(event trust-decision)"
          "(project \"example-project\")"
          "(decision allowed)"))
        (should
         (consent-skill-test--audit-entry-matching
          "(event skill-activation)"
          "(skill-name \"example-skill\")"
          "(trust-scope project)"
          "(decision allowed)"))))))

(ert-deftest consent-skill-test-export-writes-skill-package-after-policy ()
  "Export a normalized skill datum only after export-write policy approval."
  (should (featurep 'consent-skill))
  (should (fboundp 'consent-skill-export))
  (let ((consent-policy-category-actions
         (consent-skill-test--actions
          '((skill-resource-read . allow)
            (skill-export-write . allow)))))
    (consent-audit-clear)
    (consent-skill-test--with-temp-skill source-directory
      (let* ((root (make-temp-file "consent-skill-export-test-" t))
             (export-directory (expand-file-name "exported-skill" root))
             (datum (consent-skill-import source-directory)))
        (unwind-protect
            (progn
              (consent-skill-export datum export-directory)
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
               (consent-skill-test--audit-entry-matching
                "(event skill-export)"
                "(category skill-export-write)"
                "(skill-name \"example-skill\")"
                "(decision allowed)")))
          (delete-directory root t))))))

(ert-deftest consent-skill-test-read-resource-helper-audits-denial ()
  "Audit direct resource-read helper denials before reading skill files."
  (should (featurep 'consent-skill))
  (should (fboundp 'consent-skill-read-resource))
  (let ((consent-policy-category-actions
         (consent-skill-test--actions
          '((skill-resource-read . deny)))))
    (consent-audit-clear)
    (consent-skill-test--with-temp-skill directory
      (should-error
       (consent-skill-read-resource
        directory "SKILL.md" '(:skill-name "example-skill"))
       :type 'consent-policy-error)
      (should
       (consent-skill-test--audit-entry-matching
        "(event skill-resource)"
        "(category skill-resource-read)"
        "(skill-name \"example-skill\")"
        "(resource-path"
        "SKILL.md"
        "(decision denied)")))))

(ert-deftest consent-skill-test-bundled-script-request-audits-confirmation ()
  "Audit bundled script execution requests with confirmation decisions."
  (should (featurep 'consent-skill))
  (should (fboundp 'consent-skill-script-execution-request))
  (let ((consent-policy-category-actions
         (consent-skill-test--actions
          '((skill-script-execution . confirm))))
        (consent-policy-confirmation-function (lambda (_request) t)))
    (consent-audit-clear)
    (consent-skill-test--with-temp-skill directory
      (let ((external
             (consent-result->external
              (consent-skill-script-execution-request
               directory "scripts/run.sh"
               '(:skill-name "example-skill")))))
        (should (string-match-p "(skill-script-execution" external))
        (should (string-match-p "(skill-name \"example-skill\")" external))
        (should (string-match-p "(decision authorized)" external))
        (should
         (consent-skill-test--audit-entry-matching
          "(event skill-script)"
          "(category skill-script-execution)"
          "(skill-name \"example-skill\")"
          "(script-path"
          "scripts/run.sh"
          "(decision confirmed)"))))))

;;; consent-skill-test.el ends here
