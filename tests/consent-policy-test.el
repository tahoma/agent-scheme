;;; consent-policy-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for shared policy decisions, Scheme-readable audit entries,
;; read-only capability gates, and early Agent Skills policy stubs.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-eval)
(require 'consent-policy)
(require 'consent-audit)

(defun consent-policy-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           consent-policy-category-actions)))

(defun consent-policy-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-policy-test--latest-audit-string ()
  "Return the latest audit entry as an external string."
  (car (consent-policy-test--audit-strings)))

(defun consent-policy-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-policy-test--audit-strings)))

(ert-deftest consent-policy-test-read-only-capability-denial-audits ()
  "Deny read-only Emacs capabilities through the shared policy gate."
  (let ((consent-policy-category-actions
         (consent-policy-test--actions '((emacs-read-only . deny)))))
    (consent-audit-clear)
    (should-error
     (consent-eval-source
      "(import (emacs buffer))
       (emacs-current-buffer)")
     :type 'consent-policy-error)
    (should
     (consent-policy-test--audit-entry-matching
      "(event capability-call)"
      "(category emacs-read-only)"
      "(operation \"emacs-current-buffer\")"
      "(decision denied)"))))

(ert-deftest consent-policy-test-read-only-capability-allow-audits ()
  "Allow read-only Emacs capabilities while recording the capability call."
  (consent-audit-clear)
  (with-temp-buffer
    (rename-buffer "consent-policy-buffer")
    (consent-eval-source
     "(import (scheme base) (emacs buffer))
      (buffer-name (emacs-current-buffer))"))
  (let ((entries (consent-policy-test--audit-strings)))
    (should
     (seq-some
      (lambda (entry)
        (and (string-match-p "(event capability-call)" entry)
             (string-match-p "(operation \"emacs-current-buffer\")" entry)
             (string-match-p "(decision allowed)" entry)))
      entries))
    (should
     (seq-some
      (lambda (entry)
        (and (string-match-p "(event capability-call)" entry)
             (string-match-p "(operation \"buffer-name\")" entry)
             (string-match-p "(decision allowed)" entry)))
      entries))))

(ert-deftest consent-policy-test-confirmation-stub-audits ()
  "Use a noninteractive confirmation stub and audit the confirmed decision."
  (let* ((requests nil)
         (consent-policy-category-actions
          (consent-policy-test--actions '((emacs-read-only . confirm))))
         (consent-policy-confirmation-function
          (lambda (request)
            (push request requests)
            t)))
    (consent-audit-clear)
    (consent-eval-source
     "(import (emacs buffer))
      (emacs-current-buffer)")
    (should (= (length requests) 1))
    (should
     (consent-policy-test--audit-entry-matching
      "(operation \"emacs-current-buffer\")"
      "(decision confirmed)"))))

(ert-deftest consent-policy-test-standard-file-denial-audits ()
  "Audit default denial for host-effecting standard Scheme file access."
  (consent-audit-clear)
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme file))
     (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")
   :type 'consent-policy-error)
  (should
   (consent-policy-test--audit-entry-matching
    "(event policy-decision)"
    "(category standard-host-effect)"
    "(operation \"file-exists?\")"
    "(decision denied)"
    "fixtures/r7rs/conformance-cases.scm")))

(ert-deftest consent-policy-test-evaluation-audit-record ()
  "Record evaluated source and result as a Scheme-readable audit datum."
  (consent-audit-clear)
  (should (equal (consent-value->external
                  (consent-eval-source "(+ 1 2)"))
                 "3"))
  (let ((entry (consent-policy-test--latest-audit-string)))
    (should (string-match-p "(event evaluation)" entry))
    (should (string-match-p
             (regexp-quote "(input-form \"(+ 1 2)\")")
             entry))
    (should (string-match-p "(decision allowed)" entry))
    (should (string-match-p (regexp-quote "(result \"3\")") entry))))

(ert-deftest consent-policy-test-skill-activation-audits ()
  "Audit skill activation policy decisions with source-directory details."
  (let ((consent-policy-category-actions
         (consent-policy-test--actions
          '((skill-discovery-activation . allow)))))
    (consent-audit-clear)
    (consent-policy-authorize-skill-activation
     "host-boundary-review" "/tmp/consent-skill" 'project)
    (let ((entry (consent-policy-test--latest-audit-string)))
      (should (string-match-p "(event skill-activation)" entry))
      (should (string-match-p "(skill-name \"host-boundary-review\")" entry))
      (should (string-match-p "(source-directory \"/tmp/consent-skill\")"
                              entry))
      (should (string-match-p "(trust-scope project)" entry))
      (should (string-match-p "(decision allowed)" entry)))))

(ert-deftest consent-policy-test-project-skill-trust-denial-audits ()
  "Deny untrusted project-level skill trust by default and audit it."
  (consent-audit-clear)
  (should-error
   (consent-policy-authorize-project-skill-trust
    "example-project" "/tmp/consent-project")
   :type 'consent-policy-error)
  (let ((entry (consent-policy-test--latest-audit-string)))
    (should (string-match-p "(event trust-decision)" entry))
    (should (string-match-p "(category project-skill-trust)" entry))
    (should (string-match-p "(project \"example-project\")" entry))
    (should (string-match-p "(decision denied)" entry))))

(ert-deftest consent-policy-test-skill-export-confirmation-stub-audits ()
  "Require explicit confirmation for skill export writes and audit approval."
  (let ((consent-policy-category-actions
         (consent-policy-test--actions '((skill-export-write . confirm))))
        (consent-policy-confirmation-function (lambda (_request) t)))
    (consent-audit-clear)
    (consent-policy-authorize-skill-export-write
     "example-skill" "/tmp/consent-export.scm")
    (let ((entry (consent-policy-test--latest-audit-string)))
      (should (string-match-p "(event skill-export)" entry))
      (should (string-match-p "(category skill-export-write)" entry))
      (should (string-match-p "(skill-name \"example-skill\")" entry))
      (should (string-match-p "(export-path \"/tmp/consent-export.scm\")"
                              entry))
      (should (string-match-p "(decision confirmed)" entry)))))

(ert-deftest consent-policy-test-audit-buffer-clear-and-rotate ()
  "Display audit entries and provide lightweight clear and rotate commands."
  (consent-audit-clear)
  (consent-audit-record
   'policy-decision
   '((category . pure-r7rs)
     (operation . "first")
     (decision . allowed)))
  (consent-audit-record
   'policy-decision
   '((category . pure-r7rs)
     (operation . "second")
     (decision . allowed)))
  (let ((buffer (consent-audit-display)))
    (with-current-buffer buffer
      (should (derived-mode-p 'special-mode))
      (should (string-match-p "(audit-entry" (buffer-string)))
      (should (string-match-p "(operation \"second\")" (buffer-string)))))
  (consent-audit-rotate 1)
  (should (= (length (consent-audit-recent-entries)) 1))
  (should (string-match-p "(operation \"second\")"
                          (consent-policy-test--latest-audit-string)))
  (consent-audit-clear)
  (should (null (consent-audit-recent-entries))))

;;; consent-policy-test.el ends here
