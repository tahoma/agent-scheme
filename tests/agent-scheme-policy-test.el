;;; agent-scheme-policy-test.el --- Policy and audit tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for shared policy decisions, Scheme-readable audit entries,
;; read-only capability gates, and early Agent Skills policy stubs.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-audit)

(defun agent-scheme-policy-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-policy-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-policy-test--latest-audit-string ()
  "Return the latest audit entry as an external string."
  (car (agent-scheme-policy-test--audit-strings)))

(defun agent-scheme-policy-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-policy-test--audit-strings)))

(ert-deftest agent-scheme-policy-test-read-only-capability-denial-audits ()
  "Deny read-only Emacs capabilities through the shared policy gate."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-policy-test--actions '((emacs-read-only . deny)))))
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (emacs buffer))
       (emacs-current-buffer)")
     :type 'agent-scheme-policy-error)
    (should
     (agent-scheme-policy-test--audit-entry-matching
      "(event capability-call)"
      "(category emacs-read-only)"
      "(operation \"emacs-current-buffer\")"
      "(decision denied)"))))

(ert-deftest agent-scheme-policy-test-read-only-capability-allow-audits ()
  "Allow read-only Emacs capabilities while recording the capability call."
  (agent-scheme-audit-clear)
  (with-temp-buffer
    (rename-buffer "agent-scheme-policy-buffer")
    (agent-scheme-eval-source
     "(import (scheme base) (emacs buffer))
      (buffer-name (emacs-current-buffer))"))
  (let ((entries (agent-scheme-policy-test--audit-strings)))
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

(ert-deftest agent-scheme-policy-test-confirmation-stub-audits ()
  "Use a noninteractive confirmation stub and audit the confirmed decision."
  (let* ((requests nil)
         (agent-scheme-policy-category-actions
          (agent-scheme-policy-test--actions '((emacs-read-only . confirm))))
         (agent-scheme-policy-confirmation-function
          (lambda (request)
            (push request requests)
            t)))
    (agent-scheme-audit-clear)
    (agent-scheme-eval-source
     "(import (emacs buffer))
      (emacs-current-buffer)")
    (should (= (length requests) 1))
    (should
     (agent-scheme-policy-test--audit-entry-matching
      "(operation \"emacs-current-buffer\")"
      "(decision confirmed)"))))

(ert-deftest agent-scheme-policy-test-standard-file-denial-audits ()
  "Audit default denial for host-effecting standard Scheme file access."
  (agent-scheme-audit-clear)
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme file))
     (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")
   :type 'agent-scheme-policy-error)
  (should
   (agent-scheme-policy-test--audit-entry-matching
    "(event policy-decision)"
    "(category standard-host-effect)"
    "(operation \"file-exists?\")"
    "(decision denied)"
    "fixtures/r7rs/conformance-cases.scm")))

(ert-deftest agent-scheme-policy-test-evaluation-audit-record ()
  "Record evaluated source and result as a Scheme-readable audit datum."
  (agent-scheme-audit-clear)
  (should (equal (agent-scheme-value->external
                  (agent-scheme-eval-source "(+ 1 2)"))
                 "3"))
  (let ((entry (agent-scheme-policy-test--latest-audit-string)))
    (should (string-match-p "(event evaluation)" entry))
    (should (string-match-p
             (regexp-quote "(input-form \"(+ 1 2)\")")
             entry))
    (should (string-match-p "(decision allowed)" entry))
    (should (string-match-p (regexp-quote "(result \"3\")") entry))))

(ert-deftest agent-scheme-policy-test-skill-activation-audits ()
  "Audit skill activation policy decisions with source-directory details."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-policy-test--actions
          '((skill-discovery-activation . allow)))))
    (agent-scheme-audit-clear)
    (agent-scheme-policy-authorize-skill-activation
     "host-boundary-review" "/tmp/agent-scheme-skill" 'project)
    (let ((entry (agent-scheme-policy-test--latest-audit-string)))
      (should (string-match-p "(event skill-activation)" entry))
      (should (string-match-p "(skill-name \"host-boundary-review\")" entry))
      (should (string-match-p "(source-directory \"/tmp/agent-scheme-skill\")"
                              entry))
      (should (string-match-p "(trust-scope project)" entry))
      (should (string-match-p "(decision allowed)" entry)))))

(ert-deftest agent-scheme-policy-test-project-skill-trust-denial-audits ()
  "Deny untrusted project-level skill trust by default and audit it."
  (agent-scheme-audit-clear)
  (should-error
   (agent-scheme-policy-authorize-project-skill-trust
    "example-project" "/tmp/agent-scheme-project")
   :type 'agent-scheme-policy-error)
  (let ((entry (agent-scheme-policy-test--latest-audit-string)))
    (should (string-match-p "(event trust-decision)" entry))
    (should (string-match-p "(category project-skill-trust)" entry))
    (should (string-match-p "(project \"example-project\")" entry))
    (should (string-match-p "(decision denied)" entry))))

(ert-deftest agent-scheme-policy-test-skill-export-confirmation-stub-audits ()
  "Require explicit confirmation for skill export writes and audit approval."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-policy-test--actions '((skill-export-write . confirm))))
        (agent-scheme-policy-confirmation-function (lambda (_request) t)))
    (agent-scheme-audit-clear)
    (agent-scheme-policy-authorize-skill-export-write
     "example-skill" "/tmp/agent-scheme-export.scm")
    (let ((entry (agent-scheme-policy-test--latest-audit-string)))
      (should (string-match-p "(event skill-export)" entry))
      (should (string-match-p "(category skill-export-write)" entry))
      (should (string-match-p "(skill-name \"example-skill\")" entry))
      (should (string-match-p "(export-path \"/tmp/agent-scheme-export.scm\")"
                              entry))
      (should (string-match-p "(decision confirmed)" entry)))))

(ert-deftest agent-scheme-policy-test-audit-buffer-clear-and-rotate ()
  "Display audit entries and provide lightweight clear and rotate commands."
  (agent-scheme-audit-clear)
  (agent-scheme-audit-record
   'policy-decision
   '((category . pure-r7rs)
     (operation . "first")
     (decision . allowed)))
  (agent-scheme-audit-record
   'policy-decision
   '((category . pure-r7rs)
     (operation . "second")
     (decision . allowed)))
  (let ((buffer (agent-scheme-audit-display)))
    (with-current-buffer buffer
      (should (derived-mode-p 'special-mode))
      (should (string-match-p "(audit-entry" (buffer-string)))
      (should (string-match-p "(operation \"second\")" (buffer-string)))))
  (agent-scheme-audit-rotate 1)
  (should (= (length (agent-scheme-audit-recent-entries)) 1))
  (should (string-match-p "(operation \"second\")"
                          (agent-scheme-policy-test--latest-audit-string)))
  (agent-scheme-audit-clear)
  (should (null (agent-scheme-audit-recent-entries))))

;;; agent-scheme-policy-test.el ends here
