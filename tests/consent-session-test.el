;;; consent-session-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for named and project session lifecycle records, snapshots,
;; forks, and handle cleanup.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-capability)
(require 'consent-eval)
(require 'consent-repl)
(require 'consent-result)
(require 'consent-session)

(defun consent-session-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-session-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-session-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-session-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-session-test--audit-strings)))

(defun consent-session-test--reset ()
  "Reset session and audit state for a focused lifecycle test."
  (consent-session-clear!)
  (consent-audit-clear))

(ert-deftest consent-session-test-create-list-ref-and-scheme-primitives ()
  "Create, list, and reference sessions through Elisp and Scheme APIs."
  (consent-session-test--reset)
  (let ((created
         (consent-session-create! 'named '(:id "repl-main"))))
    (should
     (string-match-p
      (regexp-quote "(session (id repl-main) (scope named) (status new)")
      (consent-session-test--external created)))
    (should (= (length (consent-session-list 'named)) 1))
    (should
     (string-match-p
      (regexp-quote "(id repl-main)")
      (consent-session-test--external
       (consent-session-ref "repl-main")))))
  (should
   (string-match-p
    (regexp-quote "(session (id scheme-main) (scope named) (status new)")
    (consent-session-test--value-external
     (consent-eval-source
      "(import (agent session))
       (session-create! 'named '((id scheme-main)))"))))
  (should (= (length (consent-session-list 'named)) 2)))

(ert-deftest consent-session-test-source-library-legacy-session-verbs ()
  "Expose legacy pure lifecycle verbs from the source-loaded session library."
  (consent-session-test--reset)
  (should
   (equal
    (consent-session-test--value-external
     (consent-eval-source
      "(import (scheme base) (agent session))
       (define created
         (session-create! 'named '((id source-legacy-a))))
       (define snapshot
         (session-snapshot! 'source-legacy-a '((id source-legacy-snap))))
       (define forked
         (session-fork! 'source-legacy-a '((id source-legacy-b))))
       (list
        (session-datum-id created)
        (session-datum-id (session-ref 'source-legacy-a))
        (map session-datum-id (session-list))
        (cadr (assq 'status
                    (cdr (session-suspend! 'source-legacy-a))))
        (cadr (assq 'status
                    (cdr (session-resume! 'source-legacy-a))))
        (cadr (assq 'id (cdr snapshot)))
        (session-datum-id forked)
        (session-handles (session-ref 'source-legacy-b))
        (cadr (assq 'status
                    (cdr (session-retire! 'source-legacy-a)))))"))
    (concat
     "(source-legacy-a source-legacy-a (source-legacy-a source-legacy-b) "
     "suspended active source-legacy-snap source-legacy-b () retired)"))))

(ert-deftest consent-session-test-emacs-adapter-has-no-pure-store-twin ()
  "Keep pure session lifecycle state single-sourced in `(agent session)'."
  (dolist (symbol
           '(consent-session--generated-id
             consent-session--generated-snapshot-id
             consent-session--snapshot-id
             consent-session--make
             consent-session--register!
             consent-session--transition!))
    (should-not (fboundp symbol))))

(ert-deftest consent-session-test-suspend-resume-snapshot-fork-and-audit ()
  "Track lifecycle transitions, snapshots, forks, and audit entries."
  (consent-session-test--reset)
  (consent-session-create! 'named '(:id "work-main"))
  (let ((suspended
         (consent-session-test--external
          (consent-session-suspend! "work-main")))
        (resumed
         (consent-session-test--external
          (consent-session-resume! "work-main"))))
    (should (string-match-p (regexp-quote "(status suspended)") suspended))
    (should (string-match-p (regexp-quote "(status active)") resumed)))
  (should
   (equal
    (consent-session-test--value-external
     (consent-session-eval-source
      "work-main"
      "(define answer 41)
       (+ answer 1)"))
    "42"))
  (let ((snapshot
         (consent-session-test--external
          (consent-session-snapshot! "work-main" '(:id "snap-main"))))
        (fork
         (consent-session-test--external
          (consent-session-fork! "work-main" '(:id "work-copy")))))
    (should (string-match-p "(session-snapshot" snapshot))
    (should (string-match-p (regexp-quote "(source-session work-main)")
      snapshot))
    (should (string-match-p (regexp-quote "(definitions (answer))") snapshot))
    (should (string-match-p "(never-restore" snapshot))
    (should
     (string-match-p
      (regexp-quote "(session (id work-copy) (scope named) (status new)")
      fork))
    (should (string-match-p (regexp-quote "(forked-from work-main)") fork)))
  (should
   (consent-session-test--audit-entry-matching
    "(event session-lifecycle)"
    "(operation \"session-suspend!\")"
    "(session work-main)"
    "(to suspended)"))
  (should
   (consent-session-test--audit-entry-matching
    "(event session-lifecycle)"
    "(operation \"session-snapshot!\")"
    "(session work-main)"
    "(snapshot snap-main)")))

(ert-deftest consent-session-test-stale-handle-cleanup-and-retirement ()
  "Do not blindly restore stale handles, and release handles on retirement."
  (consent-session-test--reset)
  (let ((buffer (generate-new-buffer "consent-session-stale"))
        stale-handle)
    (unwind-protect
        (progn
          (consent-session-create! 'named '(:id "handle-main"))
          (with-current-buffer buffer
            (setq stale-handle
                  (consent-session-eval-source
                   "handle-main"
                   "(import (scheme base) (emacs buffer))
                    (define saved (emacs-current-buffer))
                    saved")))
          (should (consent-handle-p stale-handle))
          (should (consent-capability-handle-known-p stale-handle))
          (kill-buffer buffer)
          (setq buffer nil)
          (let ((snapshot
                 (consent-session-test--external
                  (consent-session-snapshot! "handle-main"))))
            (should (string-match-p "(stale-handles ((handle buffer h-"
              snapshot))
            (should-not
             (consent-capability-handle-known-p stale-handle))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))
  (let ((buffer (generate-new-buffer "consent-session-retire"))
        live-handle)
    (unwind-protect
        (progn
          (consent-session-create! 'named '(:id "retire-main"))
          (with-current-buffer buffer
            (setq live-handle
                  (consent-session-eval-source
                   "retire-main"
                   "(import (scheme base) (emacs buffer))
                    (define saved (emacs-current-buffer))
                    saved")))
          (should (consent-capability-handle-known-p live-handle))
          (let ((retired
                 (consent-session-test--external
                  (consent-session-retire! "retire-main"))))
            (should
             (string-match-p (regexp-quote "(status retired)") retired)))
          (should-not
           (consent-capability-handle-known-p live-handle)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest consent-session-test-scheme-verbs-policy-shared-pointer-and-audit
  ()
  "Gate the `(agent session)' REPL verbs, share the default pointer, and\
 audit."
  (consent-session-test--reset)
  (setq consent-session-current-id nil)
  ;; Without a window-session grant the mutating verbs fail closed.
  (should
   (eq 'consent-policy-error
       (condition-case condition
           (progn
             (consent-eval-source
              "(import (agent session))
               (create-session 'named '((id denied-a)))")
             'no-error)
         (consent-policy-error 'consent-policy-error))))
  (should-not (consent-session-ref "denied-a"))
  ;; With the grant, create-session returns a session datum without changing
  ;; the
  ;; default session, and emits Scheme-readable audit entries.
  (let ((created
         (consent-session-test--value-external
          (consent-eval-source
           "(import (agent session))
            (create-session 'named '((id verb-a)))"
           nil
           '(:policy-actions ((window-session . allow)))))))
    (should
     (string-match-p
      (regexp-quote "(session (id verb-a) (scope named) (status new)")
      created))
    (should-not consent-session-current-id))
  (should
   (consent-session-test--audit-entry-matching
    "(event policy-decision)"
    "(category window-session)"
    "(operation \"create-session\")"
    "(decision allowed)"))
  ;; switch-session sets the canonical default pointer that the native REPL
  ;; commands also read through the `consent-current-session-id' alias.
  (let ((switched
         (consent-session-test--value-external
          (consent-eval-source
           "(import (agent session))
            (switch-session 'verb-a)"
           nil
           '(:policy-actions ((window-session . allow)))))))
    (should (string-match-p (regexp-quote "(id verb-a)") switched)))
  (should (equal consent-session-current-id "verb-a"))
  (should (equal consent-current-session-id "verb-a"))
  (should
   (consent-session-test--audit-entry-matching
    "(event session-lifecycle)"
    "(operation \"switch-session\")"
    "(session verb-a)"))
  ;; current-session reports the default; list-sessions enumerates records.
  (should
   (string-match-p
    (regexp-quote "(id verb-a)")
    (consent-session-test--value-external
     (consent-eval-source
      "(import (agent session)) (current-session)"
      nil
      '(:policy-actions ((window-session . allow)))))))
  (should
   (string-match-p
    (regexp-quote "(session (id verb-a)")
    (consent-session-test--value-external
     (consent-eval-source
      "(import (agent session)) (list-sessions)"
      nil
      '(:policy-actions ((window-session . allow)))))))
  ;; close-session retires the session and clears the default when it was
  ;; current.
  (let ((closed
         (consent-session-test--value-external
          (consent-eval-source
           "(import (agent session)) (close-session 'verb-a)"
           nil
           '(:policy-actions ((window-session . allow)))))))
    (should (string-match-p (regexp-quote "(status retired)") closed)))
  (should-not consent-session-current-id))

(ert-deftest consent-session-test-session-handles-primitive ()
  "Expose session-owned handle references through `(agent session)'."
  (consent-session-test--reset)
  (let ((buffer (generate-new-buffer "consent-session-handles")))
    (unwind-protect
        (progn
          (consent-session-create! 'named '(:id "handle-list"))
          (with-current-buffer buffer
            (let ((external
                   (consent-session-test--value-external
                    (consent-session-eval-source
                     "handle-list"
                     "(import (scheme base) (agent session) (emacs buffer))
                      (define saved (emacs-current-buffer))
                      (session-handles 'handle-list)"))))
              (should
               (string-match-p "\\`((handle buffer h-[0-9]+))\\'" external))))
          (let ((retired
                 (consent-session-test--value-external
                  (consent-session-eval-source
                   "handle-list"
                   "(import (scheme base) (agent session))
                    (session-retire! 'handle-list)
                    (session-handles 'handle-list)"))))
            (should (equal retired "()"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;;; consent-session-test.el ends here
