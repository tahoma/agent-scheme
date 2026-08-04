;;; consent-approval-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for first-class `(agent approval)' request records,
;; host-side decisions, policy integration, and native approvals UX.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-approval)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-policy)
(require 'consent-repl)
(require 'consent-result)
(require 'consent-session)

(defun consent-approval-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-approval-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-approval-test--reset ()
  "Reset approval, session, audit, and native REPL state."
  (consent-approval-clear!)
  (consent-session-clear!)
  (consent-audit-clear)
  (setq consent-current-session-id nil))

(defun consent-approval-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-approval-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-approval-test--audit-strings)))

(defun consent-approval-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           consent-policy-category-actions)))

(defun consent-approval-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest consent-approval-test-emacs-adapter-has-no-pure-store-twin ()
  "Keep pure approval store semantics in the source-loaded library."
  (dolist (helper '(consent-approval--generated-id
                    consent-approval--make-record
                    consent-approval--replace-field
                    consent-approval--set-record!
                    consent-approval--same-id-p))
    (should-not (fboundp helper))))

(ert-deftest consent-approval-test-request-status-and-audit ()
  "Scheme code can request approval and observe the pending status."
  (consent-approval-test--reset)
  (should
   (equal
    (consent-approval-test--value-external
     (consent-eval-source
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
    (consent-approval-test--external
     (consent-approval-ref 'a-1))))
  (should
   (consent-approval-test--audit-entry-matching
    "(event approval-request)"
    "(id a-1)"
    "(policy buffer-edit)"
    "(status pending)")))

(ert-deftest consent-approval-test-yield-pending-records ()
  "Pending approvals can be yielded as Scheme-readable records."
  (consent-approval-test--reset)
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
          (consent-approval-test--external
           (consent-eval-source-result source))))
    (should (string-match-p "(status ok)" result))
    (should
     (string-match-p
      "events .*approval-request .*id a-1.*policy buffer-edit"
      result))
    (should
     (string-match-p
      (regexp-quote "(status pending)")
      result))))

(ert-deftest consent-approval-test-host-decisions-update-status-and-audit ()
  "Host-side decisions update approval records and audit entries."
  (consent-approval-test--reset)
  (let ((id
         (consent-approval-request!
          (consent-read
           "(approval-request
              (policy buffer-edit)
              (effect (buffer-insert! h-1 1 \"x\"))
              (reason \"Insert text?\"))"))))
    (should (equal (consent-approval-status id) 'pending))
    (consent-approval-resolve! id 'denied)
    (should (equal (consent-approval-status id) 'denied))
    (should-error
     (consent-approval-cancel! id)
     :type 'consent-approval-error)
    (should
     (consent-approval-test--audit-entry-matching
      "(event approval-decision)"
      "(id a-1)"
      "(decision denied)"
      "(status denied)"))))

(ert-deftest consent-approval-test-scheme-self-approval-denied-by-default ()
  "Scheme code cannot approve its own approval records by default."
  (consent-approval-test--reset)
  (should-error
   (consent-eval-source
    "(import (scheme base) (agent approval))
     (define id
       (approval-request!
        '(approval-request
           (policy buffer-edit)
           (effect (buffer-insert! h-1 1 \"x\"))
           (reason \"Insert text?\"))))
     (approval-resolve! id 'approved)")
   :type 'consent-policy-error)
  (should (equal (consent-approval-status 'a-1) 'pending)))

(ert-deftest consent-approval-test-session-approval-access-is-scoped ()
  "Scheme code only sees and cancels approval records from its session."
  (consent-approval-test--reset)
  (consent-start-repl 'named "alpha")
  (consent-start-repl 'named "beta")
  (consent-repl-eval-source
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
    (consent-approval-test--external
     (consent-approval-ref 'a-1))))
  (should
   (equal
    (consent-approval-test--value-external
     (consent-repl-eval-source
      "(import (scheme base) (agent approval))
       (approval-status 'a-1)"
      "beta"))
    "#f"))
  (should-error
   (consent-repl-eval-source
    "(import (scheme base) (agent approval))
     (approval-cancel! 'a-1)"
    "beta")
   :type 'consent-approval-error)
  (should (equal (consent-approval-status 'a-1) 'pending)))

(ert-deftest consent-approval-test-policy-confirmation-creates-record ()
  "Confirmation-gated policy calls create and resolve approval records."
  (consent-approval-test--reset)
  (let ((consent-policy-category-actions
         (consent-approval-test--actions
          '((buffer-edit . confirm))))
        (consent-policy-confirmation-function (lambda (_request) t))
        (buffer (generate-new-buffer "consent-approval-confirmation")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "abcdef")
          (consent-eval-source
           "(import (scheme base)
                    (consent capability)
                    (emacs buffer)
                    (emacs buffer edit))
            (define handle (emacs-current-buffer))
            (grant-capability!
             `(capability-grant
               (id approval-buffer-grant)
               (library (emacs buffer edit))
               (effect buffer-replace!)
               (scope (buffer ,handle) (range 2 5))
               (expires (uses 1))))
            (buffer-replace! handle 2 5 \"XYZ\")")
          (should (equal (buffer-string) "aXYZef")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))
  (should (equal (consent-approval-status 'a-1) 'approved))
  (should
   (consent-approval-test--audit-entry-matching
    "(event approval-request)"
    "(policy buffer-edit)"
    "(operation \"buffer-replace!\")"))
  (should
   (consent-approval-test--audit-entry-matching
    "(event approval-decision)"
    "(id a-1)"
    "(status approved)")))

(ert-deftest consent-approval-test-native-buffer-renders-records ()
  "The native approvals buffer shows approval records for the session."
  (consent-approval-test--reset)
  (consent-start-repl 'named "approval-main")
  (consent-repl-eval-source
   "(import (scheme base) (agent approval))
    (approval-request!
     '(approval-request
       (policy buffer-edit)
       (effect (buffer-replace! h-1 1 2 \"x\"))
        (reason \"Replace text?\")))"
   "approval-main")
  (let ((approvals
         (consent-approval-test--buffer-string
          (get-buffer "*Consent Approvals: approval-main*"))))
    (should
     (string-match-p
      (regexp-quote "(approval-request (id a-1) (policy buffer-edit)")
      approvals))
    (should
     (string-match-p
      (regexp-quote "(session approval-main)")
      approvals))))

;;; consent-approval-test.el ends here
