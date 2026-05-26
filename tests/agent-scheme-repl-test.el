;;; agent-scheme-repl-test.el --- Native REPL session UX tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the Emacs-native Agent Scheme REPL/session UX over the
;; existing session runtime.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-approval)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-repl)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-repl-test--reset ()
  "Reset session, audit, and current REPL UI state."
  (agent-scheme-approval-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear)
  (setq agent-scheme-current-session-id nil))

(defun agent-scheme-repl-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun agent-scheme-repl-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-repl-test--audit-entry-matching (&rest snippets)
  "Return non-nil when a recent audit entry contains all SNIPPETS."
  (seq-some
   (lambda (entry)
     (cl-every
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-repl-test--audit-strings)))

(ert-deftest agent-scheme-repl-test-starts-project-session-and-buffers ()
  "Start a project session and create the native special buffers."
  (agent-scheme-repl-test--reset)
  (let* ((default-directory
           (file-name-as-directory
            (expand-file-name ".." (file-name-directory
                                    (or load-file-name buffer-file-name)))))
         (project-label (agent-scheme-repl-project-label))
         (expected-id (concat "project-" project-label))
         (status-buffer
          (agent-scheme-start-repl 'project)))
    (should (equal agent-scheme-current-session-id expected-id))
    (should (agent-scheme-session-ref expected-id))
    (should (get-buffer (format "*Agent: %s*" project-label)))
    (should (get-buffer (format "*Agent Scheme: %s*" project-label)))
    (should (get-buffer (format "*Agent Events: %s*" project-label)))
    (should (get-buffer (format "*Agent Audit: %s*" project-label)))
    (should (get-buffer (format "*Agent Approvals: %s*" project-label)))
    (should (eq (lookup-key global-map (kbd "C-c a"))
                #'agent-scheme-dispatch))
    (should (string-match-p
             (regexp-quote (format "Agent[%s:new]" expected-id))
             agent-scheme-mode-line-string))
    (should (string-match-p
             (regexp-quote "(session")
             (agent-scheme-repl-test--buffer-string status-buffer)))))

(ert-deftest agent-scheme-repl-test-session-scope-persists-and-fresh-isolates ()
  "Persistent REPL sessions retain definitions, imports, macros, and events."
  (agent-scheme-repl-test--reset)
  (let* ((default-directory
           (file-name-as-directory
            (expand-file-name ".." (file-name-directory
                                    (or load-file-name buffer-file-name)))))
         (_status-buffer (agent-scheme-start-repl 'project))
         (session-id agent-scheme-current-session-id)
         (project-label (agent-scheme-repl-project-label)))
    (should
     (equal
      (agent-scheme-value->external
       (agent-scheme-repl-eval-source
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
      (agent-scheme-value->external
       (agent-scheme-repl-eval-source
        "(agent-yield '(persisted))
         (double saved-answer)"))
      "42"))
    (should-error
     (agent-scheme-eval-source "(double saved-answer)")
     :type 'agent-scheme-eval-error)
    (let ((transcript
           (agent-scheme-repl-test--buffer-string
            (get-buffer (format "*Agent Scheme: %s*" project-label))))
          (events
           (agent-scheme-repl-test--buffer-string
            (get-buffer (format "*Agent Events: %s*" project-label))))
          (audit
           (agent-scheme-repl-test--buffer-string
            (get-buffer (format "*Agent Audit: %s*" project-label)))))
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

(ert-deftest agent-scheme-repl-test-macroexpand-view-renders-comparison ()
  "Render a session-local macro expansion as original, expanded, and steps."
  (agent-scheme-repl-test--reset)
  (agent-scheme-start-repl 'named "macro-view")
  (agent-scheme-repl-eval-source
   "(import (scheme base))
    (define-syntax my-unless
      (syntax-rules ()
        ((my-unless test body ...)
         (if test #f (begin body ...)))))"
   "macro-view")
  (let* ((buffer
          (agent-scheme-repl-macroexpand-source
           "(my-unless #f 42)"
           "macro-view"))
         (contents (agent-scheme-repl-test--buffer-string buffer)))
    (with-current-buffer buffer
      (should (derived-mode-p 'agent-scheme-macroexpand-mode)))
    (should (equal (buffer-name buffer) "*Agent Macroexpand: macro-view*"))
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

(ert-deftest agent-scheme-repl-test-interaction-environment-is-session-gated ()
  "Return the current mutable session environment only under session policy."
  (agent-scheme-repl-test--reset)
  (agent-scheme-session-create! 'named '(:id "repl-env-alpha"))
  (agent-scheme-session-create! 'named '(:id "repl-env-beta"))
  (should
   (equal
    (agent-scheme-value->external
     (agent-scheme-session-eval-source
      "repl-env-alpha"
      "(import (scheme base) (scheme eval) (scheme repl))
       (define alpha-value 41)
       (eval '(define session-made 42) (interaction-environment))
       session-made"))
    "42"))
  (should
   (equal
    (agent-scheme-value->external
     (agent-scheme-session-eval-source
      "repl-env-alpha"
      "(eval '(+ session-made 1) (interaction-environment))"))
    "43"))
  (should
   (equal
    (agent-scheme-value->external
     (agent-scheme-session-eval-source
      "repl-env-beta"
      "(import (scheme base) (scheme eval) (scheme repl))
       (eval '(define session-made 7) (interaction-environment))
       session-made"))
    "7"))
  (should
   (equal
    (agent-scheme-value->external
     (agent-scheme-session-eval-source "repl-env-alpha" "session-made"))
    "42"))
  (should
   (agent-scheme-repl-test--audit-entry-matching
    "(event policy-decision)"
    "(operation \"interaction-environment\")"
    "(session repl-env-alpha)"
    "(decision allowed)"))
  (agent-scheme-session-create!
   'named
   '(:id "repl-env-denied"
     :policy-actions ((standard-host-effect . deny))))
  (should-error
   (agent-scheme-session-eval-source
    "repl-env-denied"
    "(import (scheme base) (scheme repl))
     (interaction-environment)")
   :type 'agent-scheme-policy-error)
  (should
   (agent-scheme-repl-test--audit-entry-matching
    "(event policy-decision)"
    "(operation \"interaction-environment\")"
    "(session repl-env-denied)"
    "(decision denied)")))

(ert-deftest agent-scheme-repl-test-approvals-switch-inspect-and-stop ()
  "Show request events as approvals and support session switching/teardown."
  (agent-scheme-repl-test--reset)
  (let* ((first-status (agent-scheme-start-repl 'named "alpha"))
         (_second-status (agent-scheme-start-repl 'named "beta"))
         (_switched (agent-scheme-switch-session "alpha")))
    (should (equal agent-scheme-current-session-id "alpha"))
    (should (eq (agent-scheme-inspect-session "alpha") first-status))
    (agent-scheme-repl-eval-source
     "(import (scheme base) (agent approval))
      (approval-request!
       '(approval-request
          (policy buffer-edit)
          (effect (buffer-replace! h-1 1 2 \"x\"))
          (reason \"Replace text?\")))")
    (let ((approvals
           (agent-scheme-repl-test--buffer-string
            (get-buffer "*Agent Approvals: alpha*"))))
      (should (string-match-p
               "(approval-request (id a-1) (policy buffer-edit)"
               approvals)))
    (let ((retired (agent-scheme-stop-session "alpha")))
      (should (string-match-p
               "(status retired)"
               (agent-scheme-result->external retired))))))

;;; agent-scheme-repl-test.el ends here
