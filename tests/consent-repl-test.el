;;; consent-repl-test.el --- Native REPL session UX tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the Emacs-native Consent Scheme REPL/session UX over the
;; existing session runtime.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-approval)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-repl)
(require 'consent-result)
(require 'consent-session)

(defun consent-repl-test--reset ()
  "Reset session, audit, and current REPL UI state."
  (consent-approval-clear!)
  (consent-session-clear!)
  (consent-audit-clear)
  (setq consent-current-session-id nil))

(defun consent-repl-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun consent-repl-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-repl-test--audit-entry-matching (&rest snippets)
  "Return non-nil when a recent audit entry contains all SNIPPETS."
  (seq-some
   (lambda (entry)
     (cl-every
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-repl-test--audit-strings)))

(ert-deftest consent-repl-test-starts-project-session-and-buffers ()
  "Start a project session and create the native special buffers."
  (consent-repl-test--reset)
  (let* ((default-directory
           (file-name-as-directory
            (expand-file-name ".." (file-name-directory
                                    (or load-file-name buffer-file-name)))))
         (project-label (consent-repl-project-label))
         (expected-id (concat "project-" project-label))
         (status-buffer
          (consent-start-repl 'project)))
    (should (equal consent-current-session-id expected-id))
    (should (consent-session-ref expected-id))
    (should (get-buffer (format "*Consent: %s*" project-label)))
    (should (get-buffer (format "*Consent Scheme: %s*" project-label)))
    (should (get-buffer (format "*Consent Events: %s*" project-label)))
    (should (get-buffer (format "*Consent Audit: %s*" project-label)))
    (should (get-buffer (format "*Consent Approvals: %s*" project-label)))
    ;; `C-c LETTER' keys are reserved for users; loading the package must
    ;; not claim a global dispatch binding.
    (should-not (lookup-key global-map (kbd "C-c a")))
    (should (string-match-p
             (regexp-quote (format "Consent[%s:new]" expected-id))
             consent-mode-line-string))
    (should (string-match-p
             (regexp-quote "(session")
             (consent-repl-test--buffer-string status-buffer)))))

(ert-deftest consent-repl-test-session-scope-persists-and-fresh-isolates ()
  "Persistent REPL sessions retain definitions, imports, macros, and events."
  (consent-repl-test--reset)
  (let* ((default-directory
           (file-name-as-directory
            (expand-file-name ".." (file-name-directory
                                    (or load-file-name buffer-file-name)))))
         (_status-buffer (consent-start-repl 'project))
         (session-id consent-current-session-id)
         (project-label (consent-repl-project-label)))
    (should
     (equal
      (consent-value->external
       (consent-repl-eval-source
        "(import (agent io))
         (define saved-answer 21)
         (define-syntax double
           (syntax-rules ()
             ((_ value) (+ value value))))
         (agent-yield '(ready))
         saved-answer"))
      "21"))
    (should
     (equal
      (consent-value->external
       (consent-repl-eval-source
        "(agent-yield '(persisted))
         (double saved-answer)"))
      "42"))
    (should-error
     (consent-eval-source "(double saved-answer)")
     :type 'consent-eval-error)
    (let ((transcript
           (consent-repl-test--buffer-string
            (get-buffer (format "*Consent Scheme: %s*" project-label))))
          (events
           (consent-repl-test--buffer-string
            (get-buffer (format "*Consent Events: %s*" project-label))))
          (audit
           (consent-repl-test--buffer-string
            (get-buffer (format "*Consent Audit: %s*" project-label)))))
      (should (string-match-p "(transcript-event" transcript))
      (should (string-match-p ";; e-" transcript))
      (should (string-match-p "(kind eval-end)" transcript))
      (should (string-match-p "(form \"(agent-yield '(persisted))" transcript))
      (should (string-match-p "(result \"42\")" transcript))
      (should (string-match-p "(record (yield (persisted)))" events))
      (should (string-match-p "(event session-evaluation)" audit))
      (should (string-match-p
               (regexp-quote (format "(session %s)" session-id))
               audit)))))

(ert-deftest consent-repl-test-macroexpand-view-renders-comparison ()
  "Render a session-local macro expansion as original, expanded, and steps."
  (consent-repl-test--reset)
  (consent-start-repl 'named "macro-view")
  (consent-repl-eval-source
   "(import (scheme base))
    (define-syntax my-unless
      (syntax-rules ()
        ((my-unless test body ...)
         (if test #f (begin body ...)))))"
   "macro-view")
  (let* ((buffer
          (consent-repl-macroexpand-source
           "(my-unless #f 42)"
           "macro-view"))
         (contents (consent-repl-test--buffer-string buffer)))
    (with-current-buffer buffer
      (should (derived-mode-p 'consent-macroexpand-mode)))
    (should (equal (buffer-name buffer) "*Consent Macroexpand: macro-view*"))
    (should (string-match-p ";; Original" contents))
    (should (string-match-p ";; Expanded" contents))
    (should (string-match-p
             (regexp-quote "(my-unless #f 42)")
             contents))
    (should (string-match-p
             (regexp-quote "(if #f #f (begin 42))")
             contents))
    (should (string-match-p
             (regexp-quote "(step (index 1) (macro my-unless)")
             contents))))

(ert-deftest consent-repl-test-interaction-environment-is-session-gated ()
  "Return the current mutable session environment only under session policy."
  (consent-repl-test--reset)
  (consent-session-create! 'named '(:id "repl-env-alpha"))
  (consent-session-create! 'named '(:id "repl-env-beta"))
  (should
   (equal
    (consent-value->external
     (consent-session-eval-source
      "repl-env-alpha"
      "(import (scheme base) (scheme eval) (scheme repl))
       (define alpha-value 41)
       (eval '(define session-made 42) (interaction-environment))
       session-made"))
    "42"))
  (should
   (equal
    (consent-value->external
     (consent-session-eval-source
      "repl-env-alpha"
      "(eval '(+ session-made 1) (interaction-environment))"))
    "43"))
  (should
   (equal
    (consent-value->external
     (consent-session-eval-source
      "repl-env-beta"
      "(import (scheme base) (scheme eval) (scheme repl))
       (eval '(define session-made 7) (interaction-environment))
       session-made"))
    "7"))
  (should
   (equal
    (consent-value->external
     (consent-session-eval-source "repl-env-alpha" "session-made"))
    "42"))
  (should
   (consent-repl-test--audit-entry-matching
    "(event policy-decision)"
    "(operation \"interaction-environment\")"
    "(session repl-env-alpha)"
    "(decision allowed)"))
  (consent-session-create!
   'named
   '(:id "repl-env-denied"
     :policy-actions ((standard-host-effect . deny))))
  (should-error
   (consent-session-eval-source
    "repl-env-denied"
    "(import (scheme base) (scheme repl))
     (interaction-environment)")
   :type 'consent-policy-error)
  (should
   (consent-repl-test--audit-entry-matching
    "(event policy-decision)"
    "(operation \"interaction-environment\")"
    "(session repl-env-denied)"
    "(decision denied)")))

(ert-deftest consent-repl-test-approvals-switch-inspect-and-stop ()
  "Show request events as approvals and support session switching/teardown."
  (consent-repl-test--reset)
  (let* ((first-status (consent-start-repl 'named "alpha"))
         (_second-status (consent-start-repl 'named "beta"))
         (_switched (consent-switch-session "alpha")))
    (should (equal consent-current-session-id "alpha"))
    (should (eq (consent-inspect-session "alpha") first-status))
    (consent-repl-eval-source
     "(import (scheme base) (agent approval))
      (approval-request!
       '(approval-request
          (policy buffer-edit)
          (effect (buffer-replace! h-1 1 2 \"x\"))
          (reason \"Replace text?\")))")
    (let ((approvals
           (consent-repl-test--buffer-string
            (get-buffer "*Consent Approvals: alpha*"))))
      (should (string-match-p
               "(approval-request (id a-1) (policy buffer-edit)"
               approvals)))
    (let ((retired (consent-stop-session "alpha")))
      (should (string-match-p
               "(status retired)"
               (consent-result->external retired))))))

;;; consent-repl-test.el ends here
