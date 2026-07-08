;;; consent-helper-test.el --- Helper artifact workflow tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for reusable Consent Scheme helper libraries, artifacts,
;; skill candidates, scoped storage, and tracked-write policy gates.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-helper)
(require 'consent-memory)
(require 'consent-policy)
(require 'consent-result)
(require 'consent-session)

(defun consent-helper-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-helper-test--result-external (result)
  "Return RESULT as stable Scheme-readable result text."
  (consent-result->external result))

(defun consent-helper-test--reset ()
  "Reset helper, memory, session, and audit state for a focused test."
  (consent-helper-clear!)
  (consent-memory-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(defun consent-helper-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           consent-policy-category-actions)))

(defun consent-helper-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-helper-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-helper-test--audit-strings)))

(ert-deftest consent-helper-test-emacs-adapter-has-no-pure-store-twin ()
  "Keep pure helper store semantics in the source-loaded library."
  (dolist (helper '(consent-helper--next-sequence
                    consent-helper--make-helper-record
                    consent-helper--make-artifact-record
                    consent-helper--replace-record
                    consent-helper--find-record
                    consent-helper--candidate-name
                    consent-helper--candidate-resources))
    (should-not (fboundp helper))))

(ert-deftest consent-helper-test-session-save-list-load-and-isolation ()
  "Save a helper in one session, load it later, and keep sessions isolated."
  (consent-helper-test--reset)
  (consent-session-create! 'named '(:id "helper-alpha"))
  (consent-session-create! 'named '(:id "helper-beta"))
  (let ((saved
         (consent-helper-test--value-external
          (consent-session-eval-source
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
    (consent-helper-test--value-external
     (consent-session-eval-source
      "helper-alpha"
      "(import (scheme base) (agent helper))
       (agent-helper-load '(agent helpers math))
       (double 21)"))
    "42"))
  (should
   (equal
    (consent-helper-test--value-external
     (consent-session-eval-source
      "helper-beta"
      "(import (scheme base) (agent helper))
       (agent-helper-list 'session)"))
    "()"))
  (should-error
   (consent-session-eval-source
    "helper-beta"
    "(import (scheme base) (agent helper))
     (agent-helper-load '(agent helpers math))")
   :type 'consent-helper-error))

(ert-deftest consent-helper-test-artifacts-memory-and-skill-candidate ()
  "Artifacts yield through `(agent io)' and helpers promote to skill candidates."
  (consent-helper-test--reset)
  (consent-session-create! 'named '(:id "helper-artifacts"))
  (let ((consent-helper-directory
         (file-name-as-directory
          (make-temp-file "consent-helper-artifacts-" t))))
    (unwind-protect
        (let ((result
               (consent-helper-test--result-external
                (consent-eval-source-result
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
      (delete-directory consent-helper-directory t))))

(ert-deftest consent-helper-test-project-private-storage-stays-untracked ()
  "Project-private helper storage uses private-local files by default."
  (consent-helper-test--reset)
  (let* ((project-root (file-name-as-directory
                        (make-temp-file "consent-helper-project-" t)))
         (private-root (file-name-as-directory
                        (make-temp-file "consent-helper-private-" t)))
         (consent-helper-directory private-root)
         (default-directory project-root))
    (unwind-protect
        (let ((external
               (consent-helper-test--value-external
                (consent-eval-source
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
            (expand-file-name ".consent" project-root)))
          (should
           (seq-some
            (lambda (path)
              (string-suffix-p ".scm" path))
            (directory-files-recursively private-root "\\.scm\\'"))))
      (delete-directory project-root t)
      (delete-directory private-root t))))

(ert-deftest consent-helper-test-tracked-helper-write-requires-approval ()
  "Project-tracked helper writes fail closed until policy approves them."
  (consent-helper-test--reset)
  (let* ((project-root (file-name-as-directory
                        (make-temp-file "consent-helper-tracked-" t)))
         (private-root (file-name-as-directory
                        (make-temp-file "consent-helper-private-" t)))
         (consent-helper-directory private-root)
         (default-directory project-root))
    (unwind-protect
        (progn
          (let ((consent-policy-category-actions
                 (consent-helper-test--actions
                  '((helper-tracked-write . deny)))))
            (should-error
             (consent-eval-source
              "(import (scheme base) (agent helper))
               (agent-helper-save!
                '(agent helpers tracked)
                '((define tracked-answer 42))
                '((scope project-tracked)))")
             :type 'consent-policy-error)
            (should-not
             (file-exists-p
              (expand-file-name ".consent/helpers" project-root)))
            (should
             (consent-helper-test--audit-entry-matching
              "(event helper-tracked-write)"
              "(category helper-tracked-write)"
              "(decision denied)")))
          (let ((consent-policy-category-actions
                 (consent-helper-test--actions
                  '((helper-tracked-write . allow)))))
            (let ((external
                   (consent-helper-test--value-external
                    (consent-eval-source
                     "(import (scheme base) (agent helper))
                      (agent-helper-save!
                       '(agent helpers tracked)
                       '((define tracked-answer 42))
                       '((scope project-tracked)))"))))
              (should (string-match-p "(scope project-tracked)" external))
              (should
               (file-exists-p
                (expand-file-name
                 ".consent/helpers/agent/helpers/tracked.scm"
                 project-root)))
              (should
               (consent-helper-test--audit-entry-matching
                "(event helper-tracked-write)"
                "(category helper-tracked-write)"
                "(decision allowed)")))))
      (delete-directory project-root t)
      (delete-directory private-root t))))

(ert-deftest consent-helper-test-skill-candidate-export-requires-approval ()
  "Writing skill candidate files is a separate approval-gated operation."
  (consent-helper-test--reset)
  (let* ((export-root (make-temp-file "consent-helper-skill-" t))
         (private-root (file-name-as-directory
                        (make-temp-file "consent-helper-private-" t)))
         (consent-helper-directory private-root)
         (candidate
          (consent-helper-promote-to-skill
           (consent-helper-save!
            '(agent helpers candidate)
            (consent-read
             "((define (candidate-helper) 'ok))")
            '(:scope project-private))
           '(:name "candidate-helper"))))
    (unwind-protect
        (progn
          (let ((consent-policy-category-actions
                 (consent-helper-test--actions
                  '((helper-skill-candidate-write . deny)))))
            (should-error
             (consent-helper-export-skill-candidate!
              candidate export-root)
             :type 'consent-policy-error)
            (should-not
             (file-exists-p (expand-file-name "SKILL.scm" export-root))))
          (let ((consent-policy-category-actions
                 (consent-helper-test--actions
                  '((helper-skill-candidate-write . allow)))))
            (consent-helper-export-skill-candidate!
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

;;; consent-helper-test.el ends here
