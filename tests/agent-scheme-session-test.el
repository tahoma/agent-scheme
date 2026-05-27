;;; agent-scheme-session-test.el --- Session lifecycle tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for named and project session lifecycle records, snapshots,
;; forks, and handle cleanup.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-capability)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-session-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-session-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-session-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-session-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-session-test--audit-strings)))

(defun agent-scheme-session-test--reset ()
  "Reset session and audit state for a focused lifecycle test."
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(ert-deftest agent-scheme-session-test-create-list-ref-and-scheme-primitives ()
  "Create, list, and reference sessions through Elisp and Scheme APIs."
  (agent-scheme-session-test--reset)
  (let ((created
         (agent-scheme-session-create! 'named '(:id "repl-main"))))
    (should
     (string-match-p
      (regexp-quote "(session (id repl-main) (scope named) (status new)")
      (agent-scheme-session-test--external created)))
    (should (= (length (agent-scheme-session-list 'named)) 1))
    (should
     (string-match-p
      (regexp-quote "(id repl-main)")
      (agent-scheme-session-test--external
       (agent-scheme-session-ref "repl-main")))))
  (should
   (string-match-p
    (regexp-quote "(session (id scheme-main) (scope named) (status new)")
    (agent-scheme-session-test--value-external
     (agent-scheme-eval-source
      "(import (agent session))
       (session-create! 'named '((id scheme-main)))"))))
  (should (= (length (agent-scheme-session-list 'named)) 2)))

(ert-deftest agent-scheme-session-test-suspend-resume-snapshot-fork-and-audit ()
  "Track lifecycle transitions, snapshots, forks, and audit entries."
  (agent-scheme-session-test--reset)
  (agent-scheme-session-create! 'named '(:id "work-main"))
  (let ((suspended
         (agent-scheme-session-test--external
          (agent-scheme-session-suspend! "work-main")))
        (resumed
         (agent-scheme-session-test--external
          (agent-scheme-session-resume! "work-main"))))
    (should (string-match-p (regexp-quote "(status suspended)") suspended))
    (should (string-match-p (regexp-quote "(status active)") resumed)))
  (should
   (equal
    (agent-scheme-session-test--value-external
     (agent-scheme-session-eval-source
      "work-main"
      "(define answer 41)
       (+ answer 1)"))
    "42"))
  (let ((snapshot
         (agent-scheme-session-test--external
          (agent-scheme-session-snapshot! "work-main" '(:id "snap-main"))))
        (fork
         (agent-scheme-session-test--external
          (agent-scheme-session-fork! "work-main" '(:id "work-copy")))))
    (should (string-match-p "(session-snapshot" snapshot))
    (should (string-match-p (regexp-quote "(source-session work-main)") snapshot))
    (should (string-match-p (regexp-quote "(definitions (answer))") snapshot))
    (should (string-match-p "(never-restore" snapshot))
    (should
     (string-match-p
      (regexp-quote "(session (id work-copy) (scope named) (status new)")
      fork))
    (should (string-match-p (regexp-quote "(forked-from work-main)") fork)))
  (should
   (agent-scheme-session-test--audit-entry-matching
    "(event session-lifecycle)"
    "(operation \"session-suspend!\")"
    "(session work-main)"
    "(to suspended)"))
  (should
   (agent-scheme-session-test--audit-entry-matching
    "(event session-lifecycle)"
    "(operation \"session-snapshot!\")"
    "(session work-main)"
    "(snapshot snap-main)")))

(ert-deftest agent-scheme-session-test-stale-handle-cleanup-and-retirement ()
  "Do not blindly restore stale handles, and release handles on retirement."
  (agent-scheme-session-test--reset)
  (let ((buffer (generate-new-buffer "agent-scheme-session-stale"))
        stale-handle)
    (unwind-protect
        (progn
          (agent-scheme-session-create! 'named '(:id "handle-main"))
          (with-current-buffer buffer
            (setq stale-handle
                  (agent-scheme-session-eval-source
                   "handle-main"
                   "(import (scheme base) (emacs buffer))
                    (define saved (emacs-current-buffer))
                    saved")))
          (should (agent-scheme-handle-p stale-handle))
          (should (agent-scheme-capability-handle-known-p stale-handle))
          (kill-buffer buffer)
          (setq buffer nil)
          (let ((snapshot
                 (agent-scheme-session-test--external
                  (agent-scheme-session-snapshot! "handle-main"))))
            (should (string-match-p "(stale-handles ((handle buffer h-" snapshot))
            (should-not
             (agent-scheme-capability-handle-known-p stale-handle))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))
  (let ((buffer (generate-new-buffer "agent-scheme-session-retire"))
        live-handle)
    (unwind-protect
        (progn
          (agent-scheme-session-create! 'named '(:id "retire-main"))
          (with-current-buffer buffer
            (setq live-handle
                  (agent-scheme-session-eval-source
                   "retire-main"
                   "(import (scheme base) (emacs buffer))
                    (define saved (emacs-current-buffer))
                    saved")))
          (should (agent-scheme-capability-handle-known-p live-handle))
          (let ((retired
                 (agent-scheme-session-test--external
                  (agent-scheme-session-retire! "retire-main"))))
            (should
             (string-match-p (regexp-quote "(status retired)") retired)))
          (should-not
           (agent-scheme-capability-handle-known-p live-handle)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-session-test-session-handles-primitive ()
  "Expose session-owned handle references through `(agent session)'."
  (agent-scheme-session-test--reset)
  (let ((buffer (generate-new-buffer "agent-scheme-session-handles")))
    (unwind-protect
        (progn
          (agent-scheme-session-create! 'named '(:id "handle-list"))
          (with-current-buffer buffer
            (let ((external
                   (agent-scheme-session-test--value-external
                    (agent-scheme-session-eval-source
                     "handle-list"
                     "(import (scheme base) (agent session) (emacs buffer))
                      (define saved (emacs-current-buffer))
                      (session-handles 'handle-list)"))))
              (should
               (string-match-p "\\`((handle buffer h-[0-9]+))\\'" external))))
          (let ((retired
                 (agent-scheme-session-test--value-external
                  (agent-scheme-session-eval-source
                   "handle-list"
                   "(import (scheme base) (agent session))
                    (session-retire! 'handle-list)
                    (session-handles 'handle-list)"))))
            (should (equal retired "()"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;;; agent-scheme-session-test.el ends here
