;;; agent-scheme-helper-test.el --- Helper artifact workflow tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for reusable Agent Scheme helper libraries, artifacts,
;; skill candidates, scoped storage, and tracked-write policy gates.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-helper)
(require 'agent-scheme-memory)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-helper-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-helper-test--result-external (result)
  "Return RESULT as stable Scheme-readable result text."
  (agent-scheme-result->external result))

(defun agent-scheme-helper-test--reset ()
  "Reset helper, memory, session, and audit state for a focused test."
  (agent-scheme-helper-clear!)
  (agent-scheme-memory-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(defun agent-scheme-helper-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-helper-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-helper-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-helper-test--audit-strings)))

(ert-deftest agent-scheme-helper-test-session-save-list-load-and-isolation ()
  "Save a helper in one session, load it later, and keep sessions isolated."
  (agent-scheme-helper-test--reset)
  (agent-scheme-session-create! 'named '(:id "helper-alpha"))
  (agent-scheme-session-create! 'named '(:id "helper-beta"))
  (let ((saved
         (agent-scheme-helper-test--value-external
          (agent-scheme-session-eval-source
           "helper-alpha"
           "(import (scheme base) (agent helper))
            (agent-helper-save!
             '(agent helpers math)
             '((define (double x) (+ x x))))
            (agent-helper-list 'session)"))))
    (should (string-match-p "(agent-helper-library" saved))
    (should (string-match-p "(name (agent helpers math))" saved))
    (should (string-match-p "(scope session)" saved)))
  (should
   (equal
    (agent-scheme-helper-test--value-external
     (agent-scheme-session-eval-source
      "helper-alpha"
      "(import (scheme base) (agent helper))
       (agent-helper-load '(agent helpers math))
       (double 21)"))
    "42"))
  (should
   (equal
    (agent-scheme-helper-test--value-external
     (agent-scheme-session-eval-source
      "helper-beta"
      "(import (scheme base) (agent helper))
       (agent-helper-list 'session)"))
    "()"))
  (should-error
   (agent-scheme-session-eval-source
    "helper-beta"
    "(import (scheme base) (agent helper))
     (agent-helper-load '(agent helpers math))")
   :type 'agent-scheme-helper-error))

(ert-deftest agent-scheme-helper-test-artifacts-memory-and-skill-candidate ()
  "Artifacts yield through `(agent io)' and helpers promote to skill candidates."
  (agent-scheme-helper-test--reset)
  (agent-scheme-session-create! 'named '(:id "helper-artifacts"))
  (let ((agent-scheme-helper-directory
         (file-name-as-directory
          (make-temp-file "agent-scheme-helper-artifacts-" t))))
    (unwind-protect
        (let ((result
               (agent-scheme-helper-test--result-external
                (agent-scheme-eval-source-result
                 "(import (scheme base) (agent helper) (agent io) (agent memory))
                  (agent-artifact
                   'example
                   '(example (source \"(emit)\") (expect \"(helper-result ok)\")))
                  (agent-helper-save!
                   '(agent helpers yielding)
                   '((define (emit)
                       (agent-yield '(helper-result ok)))))
                  (agent-helper-load '(agent helpers yielding))
                  (emit)
                  (list
                   (memory-find 'project \"agent helpers yielding\")
                   (agent-helper-promote-to-skill
                    '(agent helpers yielding)
                    '((name \"yielding-helper\")
                      (examples ((emit-example
                                   (source \"(emit)\")
                                   (expect \"(helper-result ok)\"))))
                      (references ((r7rs \"docs/r7rs-small-report.md\")))
                      (tests (((source \"(emit)\")
                               (expect \"(helper-result ok)\")))))))"))))
          (should (string-match-p "(status ok)" result))
          (should (string-match-p "(agent-skill-candidate" result))
          (should (string-match-p "(name \"yielding-helper\")" result))
          (should (string-match-p "(source-library (agent helpers yielding))" result))
          (should (string-match-p "(examples ((emit-example" result))
          (should (string-match-p "(references ((r7rs \"docs/r7rs-small-report.md\")))" result))
          (should (string-match-p "(tests (((source \"(emit)\")" result))
          (should (string-match-p "(tags (helper library))" result))
          (should
           (string-match-p
            (regexp-quote "(events ((yield (agent-artifact")
            result))
          (should
           (string-match-p
            (regexp-quote "(yield (helper-result ok))")
            result)))
      (delete-directory agent-scheme-helper-directory t))))

(ert-deftest agent-scheme-helper-test-project-private-storage-stays-untracked ()
  "Project-private helper storage uses private-local files by default."
  (agent-scheme-helper-test--reset)
  (let* ((project-root (file-name-as-directory
                        (make-temp-file "agent-scheme-helper-project-" t)))
         (private-root (file-name-as-directory
                        (make-temp-file "agent-scheme-helper-private-" t)))
         (agent-scheme-helper-directory private-root)
         (default-directory project-root))
    (unwind-protect
        (let ((external
               (agent-scheme-helper-test--value-external
                (agent-scheme-eval-source
                 "(import (scheme base) (agent helper))
                  (agent-helper-save!
                   '(agent helpers private)
                   '((define private-answer 42))
                   '((scope project-private)))
                  (agent-helper-list 'project-private)"))))
          (should (string-match-p "(name (agent helpers private))" external))
          (should (string-match-p "(scope project-private)" external))
          (should-not
           (file-exists-p
            (expand-file-name ".agent-scheme" project-root)))
          (should
           (seq-some
            (lambda (path)
              (string-suffix-p ".scm" path))
            (directory-files-recursively private-root "\\.scm\\'"))))
      (delete-directory project-root t)
      (delete-directory private-root t))))

(ert-deftest agent-scheme-helper-test-tracked-helper-write-requires-approval ()
  "Project-tracked helper writes fail closed until policy approves them."
  (agent-scheme-helper-test--reset)
  (let* ((project-root (file-name-as-directory
                        (make-temp-file "agent-scheme-helper-tracked-" t)))
         (private-root (file-name-as-directory
                        (make-temp-file "agent-scheme-helper-private-" t)))
         (agent-scheme-helper-directory private-root)
         (default-directory project-root))
    (unwind-protect
        (progn
          (let ((agent-scheme-policy-category-actions
                 (agent-scheme-helper-test--actions
                  '((helper-tracked-write . deny)))))
            (should-error
             (agent-scheme-eval-source
              "(import (scheme base) (agent helper))
               (agent-helper-save!
                '(agent helpers tracked)
                '((define tracked-answer 42))
                '((scope project-tracked)))")
             :type 'agent-scheme-policy-error)
            (should-not
             (file-exists-p
              (expand-file-name ".agent-scheme/helpers" project-root)))
            (should
             (agent-scheme-helper-test--audit-entry-matching
              "(event helper-tracked-write)"
              "(category helper-tracked-write)"
              "(decision denied)")))
          (let ((agent-scheme-policy-category-actions
                 (agent-scheme-helper-test--actions
                  '((helper-tracked-write . allow)))))
            (let ((external
                   (agent-scheme-helper-test--value-external
                    (agent-scheme-eval-source
                     "(import (scheme base) (agent helper))
                      (agent-helper-save!
                       '(agent helpers tracked)
                       '((define tracked-answer 42))
                       '((scope project-tracked)))"))))
              (should (string-match-p "(scope project-tracked)" external))
              (should
               (file-exists-p
                (expand-file-name
                 ".agent-scheme/helpers/agent/helpers/tracked.scm"
                 project-root)))
              (should
               (agent-scheme-helper-test--audit-entry-matching
                "(event helper-tracked-write)"
                "(category helper-tracked-write)"
                "(decision allowed)")))))
      (delete-directory project-root t)
      (delete-directory private-root t))))

(ert-deftest agent-scheme-helper-test-skill-candidate-export-requires-approval ()
  "Writing skill candidate files is a separate approval-gated operation."
  (agent-scheme-helper-test--reset)
  (let* ((export-root (make-temp-file "agent-scheme-helper-skill-" t))
         (private-root (file-name-as-directory
                        (make-temp-file "agent-scheme-helper-private-" t)))
         (agent-scheme-helper-directory private-root)
         (candidate
          (agent-scheme-helper-promote-to-skill
           (agent-scheme-helper-save!
            '(agent helpers candidate)
            (agent-scheme-read
             "((define (candidate-helper) 'ok))")
            '(:scope project-private))
           '(:name "candidate-helper"))))
    (unwind-protect
        (progn
          (let ((agent-scheme-policy-category-actions
                 (agent-scheme-helper-test--actions
                  '((helper-skill-candidate-write . deny)))))
            (should-error
             (agent-scheme-helper-export-skill-candidate!
              candidate export-root)
             :type 'agent-scheme-policy-error)
            (should-not
             (file-exists-p (expand-file-name "SKILL.scm" export-root))))
          (let ((agent-scheme-policy-category-actions
                 (agent-scheme-helper-test--actions
                  '((helper-skill-candidate-write . allow)))))
            (agent-scheme-helper-export-skill-candidate!
             candidate export-root)
            (should
             (file-exists-p (expand-file-name "SKILL.scm" export-root)))
            (should
             (string-match-p
              "(agent-skill-candidate"
              (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "SKILL.scm" export-root))
                (buffer-string))))))
      (delete-directory export-root t)
      (delete-directory private-root t))))

;;; agent-scheme-helper-test.el ends here
