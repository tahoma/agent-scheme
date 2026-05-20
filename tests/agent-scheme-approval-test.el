;;; agent-scheme-approval-test.el --- Approval library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for first-class `(agent approval)' request records,
;; host-side decisions, policy integration, and native approvals UX.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-approval)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-repl)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-approval-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-approval-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-approval-test--reset ()
  "Reset approval, session, audit, and native REPL state."
  (agent-scheme-approval-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear)
  (setq agent-scheme-current-session-id nil))

(defun agent-scheme-approval-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-approval-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-approval-test--audit-strings)))

(defun agent-scheme-approval-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-approval-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest agent-scheme-approval-test-request-status-and-audit ()
  "Scheme code can request approval and observe the pending status."
  (agent-scheme-approval-test--reset)
  (should
   (equal
    (agent-scheme-approval-test--value-external
     (agent-scheme-eval-source
      "(import (scheme base) (agent approval))
       (define id
         (approval-request!
          '(approval-request
             (policy buffer-edit)
             (effect (buffer-replace! h-1 1 2 \"x\"))
             (reason \"Replace text?\"))))
       (list id (approval-status id))"))
    "(a-1 pending)"))
  (should
   (string-match-p
    (regexp-quote
     "(approval-request (id a-1) (policy buffer-edit)")
    (agent-scheme-approval-test--external
     (agent-scheme-approval-ref 'a-1))))
  (should
   (agent-scheme-approval-test--audit-entry-matching
    "(event approval-request)"
    "(id a-1)"
    "(policy buffer-edit)"
    "(status pending)")))

(ert-deftest agent-scheme-approval-test-yield-pending-records ()
  "Pending approvals can be yielded as Scheme-readable records."
  (agent-scheme-approval-test--reset)
  (let* ((source
          "(import (scheme base) (agent approval))
           (approval-request!
            '(approval-request
               (policy buffer-edit)
               (effect (buffer-delete! h-1 1 2))
               (reason \"Delete text?\")))
           (approval-yield-pending)
           'done")
         (result
          (agent-scheme-approval-test--external
           (agent-scheme-eval-source-result source))))
    (should (string-match-p "(status ok)" result))
    (should
     (string-match-p
      "events .*approval-request .*id a-1.*policy buffer-edit"
      result))
    (should
     (string-match-p
      (regexp-quote "(status pending)")
      result))))

(ert-deftest agent-scheme-approval-test-host-decisions-update-status-and-audit ()
  "Host-side decisions update approval records and audit entries."
  (agent-scheme-approval-test--reset)
  (let ((id
         (agent-scheme-approval-request!
          (agent-scheme-read
           "(approval-request
              (policy buffer-edit)
              (effect (buffer-insert! h-1 1 \"x\"))
              (reason \"Insert text?\"))"))))
    (should (equal (agent-scheme-approval-status id) 'pending))
    (agent-scheme-approval-resolve! id 'denied)
    (should (equal (agent-scheme-approval-status id) 'denied))
    (should-error
     (agent-scheme-approval-cancel! id)
     :type 'agent-scheme-approval-error)
    (should
     (agent-scheme-approval-test--audit-entry-matching
      "(event approval-decision)"
      "(id a-1)"
      "(decision denied)"
      "(status denied)"))))

(ert-deftest agent-scheme-approval-test-scheme-self-approval-denied-by-default ()
  "Scheme code cannot approve its own approval records by default."
  (agent-scheme-approval-test--reset)
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (agent approval))
     (define id
       (approval-request!
        '(approval-request
           (policy buffer-edit)
           (effect (buffer-insert! h-1 1 \"x\"))
           (reason \"Insert text?\"))))
     (approval-resolve! id 'approved)")
   :type 'agent-scheme-policy-error)
  (should (equal (agent-scheme-approval-status 'a-1) 'pending)))

(ert-deftest agent-scheme-approval-test-session-approval-access-is-scoped ()
  "Scheme code only sees and cancels approval records from its session."
  (agent-scheme-approval-test--reset)
  (agent-scheme-start-repl 'named "alpha")
  (agent-scheme-start-repl 'named "beta")
  (agent-scheme-repl-eval-source
   "(import (scheme base) (agent approval))
    (approval-request!
     '(approval-request
        (policy buffer-edit)
        (effect (buffer-insert! h-1 1 \"x\"))
        (reason \"Insert text?\")
        (session beta)))"
   "alpha")
  (should
   (string-match-p
    (regexp-quote "(session alpha)")
    (agent-scheme-approval-test--external
     (agent-scheme-approval-ref 'a-1))))
  (should
   (equal
    (agent-scheme-approval-test--value-external
     (agent-scheme-repl-eval-source
      "(import (scheme base) (agent approval))
       (approval-status 'a-1)"
      "beta"))
    "#f"))
  (should-error
   (agent-scheme-repl-eval-source
    "(import (scheme base) (agent approval))
     (approval-cancel! 'a-1)"
    "beta")
   :type 'agent-scheme-approval-error)
  (should (equal (agent-scheme-approval-status 'a-1) 'pending)))

(ert-deftest agent-scheme-approval-test-policy-confirmation-creates-record ()
  "Confirmation-gated policy calls create and resolve approval records."
  (agent-scheme-approval-test--reset)
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-approval-test--actions
          '((buffer-edit . confirm))))
        (agent-scheme-policy-confirmation-function (lambda (_request) t)))
    (with-temp-buffer
      (insert "abcdef")
      (agent-scheme-eval-source
       "(import (scheme base) (emacs buffer) (emacs buffer edit))
        (buffer-replace! (emacs-current-buffer) 2 5 \"XYZ\")")
      (should (equal (buffer-string) "aXYZef"))))
  (should (equal (agent-scheme-approval-status 'a-1) 'approved))
  (should
   (agent-scheme-approval-test--audit-entry-matching
    "(event approval-request)"
    "(policy buffer-edit)"
    "(operation \"buffer-replace!\")"))
  (should
   (agent-scheme-approval-test--audit-entry-matching
    "(event approval-decision)"
    "(id a-1)"
    "(status approved)")))

(ert-deftest agent-scheme-approval-test-native-buffer-renders-records ()
  "The native approvals buffer shows approval records for the session."
  (agent-scheme-approval-test--reset)
  (agent-scheme-start-repl 'named "approval-main")
  (agent-scheme-repl-eval-source
   "(import (scheme base) (agent approval))
    (approval-request!
     '(approval-request
       (policy buffer-edit)
       (effect (buffer-replace! h-1 1 2 \"x\"))
        (reason \"Replace text?\")))"
   "approval-main")
  (let ((approvals
         (agent-scheme-approval-test--buffer-string
          (get-buffer "*Agent Approvals: approval-main*"))))
    (should
     (string-match-p
      (regexp-quote "(approval-request (id a-1) (policy buffer-edit)")
      approvals))
    (should
     (string-match-p
      (regexp-quote "(session approval-main)")
      approvals))))

;;; agent-scheme-approval-test.el ends here
