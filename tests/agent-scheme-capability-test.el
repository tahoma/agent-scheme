;;; agent-scheme-capability-test.el --- Emacs capability library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for opaque Emacs handles and capability libraries imported
;; by Agent Scheme programs.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defvar agent-scheme-capability-test--secret "secret-value"
  "Private test value whose contents must not be exposed through variable-info.")

(defvar agent-scheme-capability-test--command-log nil
  "Arguments received by command capability test commands.")

(defvar agent-scheme-capability-test--process-starts nil
  "Process start requests received by process capability test stubs.")

(defun agent-scheme-capability-test-command (value &optional flag)
  "Record VALUE and FLAG for command-call! tests."
  (interactive "sValue: ")
  (setq agent-scheme-capability-test--command-log
        (list value flag))
  'agent-scheme-capability-test-command-result)

(defun agent-scheme-capability-test-prompt-command (value)
  "Interactive-only command used to prove prompt rejection."
  (interactive "sValue: ")
  (setq agent-scheme-capability-test--command-log
        (list value)))

(defun agent-scheme-capability-test--process-stub
    (name command arguments options _context)
  "Return a Scheme-facing process job plist for test process starts."
  (push (list name command arguments options)
        agent-scheme-capability-test--process-starts)
  (list :name name
        :command command
        :arguments arguments
        :options options
        :status 'run
        :stdout "out-secret sk-processoutput1234567890\n"
        :stderr "err\n"))

(defun agent-scheme-capability-test--external
    (source &optional environment options)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source environment options)))

(defun agent-scheme-capability-test--value-external (value)
  "Return VALUE as its stable external value representation."
  (agent-scheme-value->external value))

(defun agent-scheme-capability-test--manifest-spec (library name)
  "Return Emacs capability metadata for binding NAME in LIBRARY."
  (seq-find
   (lambda (spec)
     (and (equal (plist-get spec :library) library)
          (equal (plist-get spec :name) name)))
   (agent-scheme-emacs-capability-binding-specs)))

(defun agent-scheme-capability-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-capability-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-capability-test--audit-strings)))

(defun agent-scheme-capability-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-capability-test--write-file (path contents)
  "Write CONTENTS to PATH, creating parent directories."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert contents)))

(defun agent-scheme-capability-test--write-binary-file (path bytes)
  "Write BYTES to PATH, creating parent directories."
  (make-directory (file-name-directory path) t)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dolist (byte bytes)
      (insert (unibyte-string byte)))
    (write-region (point-min) (point-max) path nil 'silent)))

(ert-deftest agent-scheme-capability-test-manifest-names-backend-policy-path ()
  "Emacs capabilities expose the shared policy-gated backend path."
  (dolist (binding '(("(emacs buffer)" "buffer-name" host-observation
                      emacs-buffer emacs-read-only allow)
                     ("(emacs buffer edit)" "buffer-replace!" host-mutation
                      emacs-buffer buffer-edit confirm)))
    (let ((spec (agent-scheme-capability-test--manifest-spec
                 (nth 0 binding)
                 (nth 1 binding))))
      (should spec)
      (should (eq (plist-get spec :source) 'host-capability))
      (should (eq (plist-get spec :effect) (nth 2 binding)))
      (should (eq (plist-get spec :required-capability) (nth 3 binding)))
      (should (eq (plist-get spec :backend-effect-path)
                  'shared-capability-request))
      (should (eq (plist-get spec :policy-category) (nth 4 binding)))
      (should (eq (plist-get spec :policy) (nth 5 binding))))))

(ert-deftest agent-scheme-capability-test-buffer-capabilities-use-handles ()
  "Inspect the current buffer through an opaque handle."
  (let ((buffer (generate-new-buffer "agent-scheme-capability-buffer")))
    (unwind-protect
        (with-current-buffer buffer
          (erase-buffer)
          (insert "hello world")
          (goto-char 7)
          (should
           (equal
            (agent-scheme-capability-test--external
             "(import (scheme base) (emacs buffer))
              (let ((handle (emacs-current-buffer)))
                (list (buffer-name handle)
                      (buffer-file-name handle)
                      (buffer-major-mode handle)
                      (buffer-point handle)
                      (buffer-text handle 1 6)))")
            (format "(\"%s\" #f fundamental-mode 7 \"hello\")"
                    (buffer-name buffer))))
          (should
           (string-match-p
            "\\`(handle buffer h-[0-9]+)\\'"
            (agent-scheme-capability-test--external
             "(import (emacs buffer))
              (emacs-current-buffer)"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-buffer-list-returns-usable-handles ()
  "Return buffer-list handles that can be passed back to buffer capabilities."
  (let ((buffer (generate-new-buffer "agent-scheme-capability-listed")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal
            (agent-scheme-capability-test--external
             "(import (scheme base) (emacs buffer))
              (define current-name (buffer-name (emacs-current-buffer)))
              (define (contains-current? handles)
                (cond
                 ((null? handles) #f)
                 ((string=? (buffer-name (car handles)) current-name) #t)
                 (else (contains-current? (cdr handles)))))
              (contains-current? (emacs-buffer-list))")
            "#t")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-stale-buffer-handles-fail-clearly ()
  "Reject buffer handles after the live Emacs buffer disappears."
  (let ((environment (agent-scheme-make-base-environment))
        (buffer (generate-new-buffer "agent-scheme-capability-stale"))
        handle)
    (with-current-buffer buffer
      (setq handle
            (agent-scheme-eval-source
             "(import (emacs buffer))
              (emacs-current-buffer)"
             environment)))
    (kill-buffer buffer)
    (agent-scheme--environment-define environment "stale" handle)
    (let ((condition
           (should-error
            (agent-scheme-eval-source "(buffer-name stale)" environment)
            :type 'agent-scheme-eval-error)))
      (should
       (string-match-p "stale buffer handle" (cadr condition))))))

(ert-deftest agent-scheme-capability-test-success-outcomes-are-audited ()
  "Audit successful capability outcomes separately from policy decisions."
  (agent-scheme-audit-clear)
  (with-temp-buffer
    (rename-buffer "agent-scheme-capability-outcome" t)
    (agent-scheme-eval-source
     "(import (scheme base) (emacs buffer))
      (buffer-name (emacs-current-buffer))"))
  (should
   (agent-scheme-capability-test--audit-entry-matching
    "(event capability-result)"
    "(category emacs-read-only)"
    "(operation \"buffer-name\")"
    "(capability \"buffer-name\")"
    "(outcome success)"
    "(decision completed)")))

(ert-deftest agent-scheme-capability-test-error-outcomes-are-audited ()
  "Audit capability errors separately from policy decisions."
  (let ((environment (agent-scheme-make-base-environment))
        (buffer (generate-new-buffer "agent-scheme-capability-error-outcome"))
        handle)
    (with-current-buffer buffer
      (setq handle
            (agent-scheme-eval-source
             "(import (emacs buffer))
              (emacs-current-buffer)"
             environment)))
    (kill-buffer buffer)
    (agent-scheme--environment-define environment "stale" handle)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source "(buffer-name stale)" environment)
     :type 'agent-scheme-eval-error)
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-result)"
      "(category emacs-read-only)"
      "(operation \"buffer-name\")"
      "(capability \"buffer-name\")"
      "(outcome error)"
      "(decision errored)"
      "stale buffer handle"))))

(ert-deftest agent-scheme-capability-test-buffer-edit-denial-audits ()
  "Deny buffer edits through the buffer-edit policy gate."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions
          '((buffer-edit . deny)))))
    (agent-scheme-audit-clear)
    (with-temp-buffer
      (insert "unchanged")
      (should-error
       (agent-scheme-eval-source
        "(import (scheme base) (emacs buffer) (emacs buffer edit))
         (buffer-insert! (emacs-current-buffer) 1 \"x\")")
       :type 'agent-scheme-policy-error)
      (should (equal (buffer-string) "unchanged")))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-call)"
      "(category buffer-edit)"
      "(operation \"buffer-insert!\")"
      "(decision denied)"))))

(ert-deftest agent-scheme-capability-test-buffer-edit-confirmed-outcome-audits ()
  "Confirm and audit successful buffer edit outcomes."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions
          '((buffer-edit . confirm))))
        (agent-scheme-policy-confirmation-function (lambda (_request) t))
        (buffer (generate-new-buffer "agent-scheme-capability-confirmed-edit")))
    (unwind-protect
        (progn
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (insert "abcdef")
            (agent-scheme-eval-source
             "(import (scheme base)
                      (agent capability)
                      (emacs buffer)
                      (emacs buffer edit))
              (define handle (emacs-current-buffer))
              (grant-capability!
               `(capability-grant
                 (id confirmed-edit-grant)
                 (library (emacs buffer edit))
                 (effect buffer-replace!)
                 (scope (buffer ,handle) (range 2 5))
                 (expires (uses 1))))
              (buffer-replace! handle 2 5 \"XYZ\")")
            (should (equal (buffer-string) "aXYZef")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-call)"
            "(category buffer-edit)"
            "(operation \"buffer-replace!\")"
            "(decision confirmed)"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(category buffer-edit)"
            "(operation \"buffer-replace!\")"
            "(outcome success)"
            "(decision completed)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-buffer-edits-record-transaction-metadata ()
  "Insert, delete, and replace edit audits record touched text and region."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-edit")))
    (unwind-protect
        (progn
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (insert "abcdef")
            (should
             (equal
              (agent-scheme-capability-test--external
               "(import (scheme base)
                        (agent capability)
                        (emacs buffer)
                        (emacs buffer edit))
                (define handle (emacs-current-buffer))
                (grant-capability!
                 `(capability-grant
                   (id insert-metadata-grant)
                   (library (emacs buffer edit))
                   (effect buffer-insert!)
                   (scope (buffer ,handle) (range 4 4))
                   (expires (uses 1))))
                (grant-capability!
                 `(capability-grant
                   (id delete-metadata-grant)
                   (library (emacs buffer edit))
                   (effect buffer-delete!)
                   (scope (buffer ,handle) (range 2 3))
                   (expires (uses 1))))
                (grant-capability!
                 `(capability-grant
                   (id replace-metadata-grant)
                   (library (emacs buffer edit))
                   (effect buffer-replace!)
                   (scope (buffer ,handle) (range 5 7))
                   (expires (uses 1))))
                (buffer-insert! handle 4 \"XX\")
                (buffer-delete! handle 2 3)
                (buffer-replace! handle 5 7 \"YZ\")
                (buffer-text handle 1 8)")
              "\"acXXYZf\""))
            (should (equal (buffer-string) "acXXYZf")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(operation \"buffer-insert!\")"
            "(target-buffer \"agent-scheme-capability-edit\")"
            "(region (4 4))"
            "(before-text \"\")"
            "(after-text \"XX\")"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(operation \"buffer-delete!\")"
            "(target-buffer \"agent-scheme-capability-edit\")"
            "(region (2 3))"
            "(before-text \"b\")"
            "(after-text \"\")"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(operation \"buffer-replace!\")"
            "(target-buffer \"agent-scheme-capability-edit\")"
            "(region (5 7))"
            "(before-text \"de\")"
            "(after-text \"YZ\")")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-buffer-edit-rolls-back-on-error ()
  "Rollback a partially applied edit when a buffer change hook errors."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-rollback")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "abcdef")
          (let ((triggered nil)
                (after-change-functions
                 (list
                  (lambda (&rest _)
                    (unless triggered
                      (setq triggered t)
                      (error "forced buffer edit failure"))))))
            (should-error
             (agent-scheme-eval-source
              "(import (scheme base)
                       (agent capability)
                       (emacs buffer)
                       (emacs buffer edit))
               (define handle (emacs-current-buffer))
               (grant-capability!
                `(capability-grant
                  (id rollback-edit-grant)
                  (library (emacs buffer edit))
                  (effect buffer-insert!)
                  (scope (buffer ,handle) (range 4 4))
                  (expires (uses 1))))
               (buffer-insert! handle 4 \"XX\")")))
          (should (equal (buffer-string) "abcdef")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-buffer-edits-create-undo-boundaries ()
  "Each buffer edit leaves undo boundaries for ordinary Emacs undo."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-undo")))
    (unwind-protect
        (with-current-buffer buffer
          (buffer-enable-undo)
          (setq buffer-undo-list nil)
          (insert "abc")
          (setq buffer-undo-list nil)
          (agent-scheme-eval-source
           "(import (scheme base)
                    (agent capability)
                    (emacs buffer)
                    (emacs buffer edit))
            (define handle (emacs-current-buffer))
            (grant-capability!
             `(capability-grant
               (id undo-insert-grant)
               (library (emacs buffer edit))
               (effect buffer-insert!)
               (scope (buffer ,handle) (range 4 5))
               (expires (uses 2))))
            (buffer-insert! handle 4 \"X\")
            (buffer-insert! handle 5 \"Y\")")
          (should (equal (buffer-string) "abcXY"))
          (should (>= (cl-count nil buffer-undo-list) 2)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-region-grant-allows-buffer-edit ()
  "A matching region grant authorizes a mutating buffer capability."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-grant-region")))
    (unwind-protect
        (progn
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (insert "abcdef")
            (should
             (equal
              (agent-scheme-capability-test--external
               "(import (scheme base)
                        (agent capability)
                        (emacs buffer)
                        (emacs buffer edit))
                (define handle (emacs-current-buffer))
                (grant-capability!
                 `(capability-grant
                   (id test-region-grant)
                   (library (emacs buffer edit))
                   (effect buffer-replace!)
                   (scope (buffer ,handle) (range 2 5))
                   (expires (uses 1))
                   (reason \"Apply approved region edit.\")))
                (buffer-replace! handle 2 5 \"XYZ\")
                (current-grants)")
              "()"))
            (should (equal (buffer-string) "aXYZef")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"grant-capability!\")"
            "(id test-region-grant)"
            "(decision created)"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"capability-grant-use\")"
            "(id test-region-grant)"
            "(effect buffer-replace!)"
            "(decision allowed)"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"capability-grant-expire!\")"
            "(id test-region-grant)"
            "(decision expired)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-region-grant-denies-outside-scope ()
  "A grant for one range does not authorize edits outside that range."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-grant-deny")))
    (unwind-protect
        (progn
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (insert "abcdef")
            (let ((condition
                   (should-error
                    (agent-scheme-eval-source
                     "(import (scheme base)
                              (agent capability)
                              (emacs buffer)
                              (emacs buffer edit))
                      (define handle (emacs-current-buffer))
                      (grant-capability!
                       `(capability-grant
                         (id test-range-grant)
                         (library (emacs buffer edit))
                         (effect buffer-replace!)
                         (scope (buffer ,handle) (range 3 5))
                         (expires never)))
                      (buffer-replace! handle 1 2 \"X\")")
                    :type 'agent-scheme-capability-grant-error)))
              (should
               (string-match-p "outside capability grant scope"
                               (cadr condition))))
            (should (equal (buffer-string) "abcdef")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"capability-grant-use\")"
            "(id test-range-grant)"
            "(decision denied)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-attenuated-grant-narrows-scope ()
  "Attenuating a grant creates a narrower usable child grant."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-grant-attenuate")))
    (unwind-protect
        (progn
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (insert "abcdef")
            (should
             (equal
              (agent-scheme-capability-test--external
               "(import (scheme base)
                        (agent capability)
                        (emacs buffer)
                        (emacs buffer edit))
                (define handle (emacs-current-buffer))
                (grant-capability!
                 `(capability-grant
                   (id test-parent-grant)
                   (library (emacs buffer edit))
                   (effect buffer-replace!)
                   (scope (buffer ,handle) (range 1 7))
                   (expires (uses 2))))
                (define child
                  (grant-attenuate
                   'test-parent-grant
                   '((id test-child-grant)
                     (scope (range 2 5))
                     (expires (uses 1)))))
                (with-capability-grant child
                  (buffer-replace! handle 2 5 \"XYZ\"))
                (buffer-text handle 1 7)")
              "\"aXYZef\""))
            (should (equal (buffer-string) "aXYZef")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"grant-attenuate\")"
            "(id test-child-grant)"
            "(parent test-parent-grant)"
            "(decision attenuated)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-revoked-grant-fails-closed ()
  "Revoked grants no longer authorize capability use."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-grant-revoke")))
    (unwind-protect
        (progn
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (insert "abcdef")
            (let ((condition
                   (should-error
                    (agent-scheme-eval-source
                     "(import (scheme base)
                              (agent capability)
                              (emacs buffer)
                              (emacs buffer edit))
                      (define handle (emacs-current-buffer))
                      (grant-capability!
                       `(capability-grant
                         (id test-revoked-grant)
                         (library (emacs buffer edit))
                         (effect buffer-insert!)
                         (scope (buffer ,handle) (range 1 7))
                         (expires never)))
                      (grant-revoke! 'test-revoked-grant)
                      (buffer-insert! handle 2 \"X\")")
                    :type 'agent-scheme-capability-grant-error)))
              (should
               (string-match-p "revoked capability grant" (cadr condition))))
            (should (equal (buffer-string) "abcdef")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"grant-revoke!\")"
            "(id test-revoked-grant)"
            "(decision revoked)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-after-eval-grants-expire-in-session ()
  "Session grants with after-eval lifetime are removed after that evaluation."
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear)
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-grant-eval")))
    (unwind-protect
        (progn
          (agent-scheme-session-create! 'named '(:id "grant-session"))
          (with-current-buffer buffer
            (insert "abcdef")
            (should
             (equal
              (agent-scheme-capability-test--value-external
               (agent-scheme-session-eval-source
                "grant-session"
                "(import (scheme base)
                         (agent capability)
                         (emacs buffer)
                         (emacs buffer edit))
                 (define handle (emacs-current-buffer))
                 (grant-capability!
                  `(capability-grant
                    (id test-after-eval-grant)
                    (library (emacs buffer edit))
                    (effect buffer-replace!)
                    (scope (buffer ,handle) (range 2 5))
                    (expires after-eval)))
                 (buffer-replace! handle 2 5 \"XYZ\")
                 (pair? (current-grants))"))
              "#t"))
            (should (equal (buffer-string) "aXYZef")))
          (should
           (equal
            (agent-scheme-capability-test--value-external
             (agent-scheme-session-eval-source
              "grant-session"
              "(import (agent capability))
               (current-grants)"))
            "()"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-grant)"
            "(operation \"capability-grant-expire!\")"
            "(id test-after-eval-grant)"
            "(decision expired)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (agent-scheme-session-clear!))))

(ert-deftest agent-scheme-capability-test-stale-grant-handle-fails-closed ()
  "A grant scoped to a stale handle fails before a host mutation."
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear)
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-grant-stale")))
    (unwind-protect
        (progn
          (agent-scheme-session-create! 'named '(:id "stale-grant-session"))
          (with-current-buffer buffer
            (insert "abcdef")
            (agent-scheme-session-eval-source
             "stale-grant-session"
             "(import (scheme base)
                      (agent capability)
                      (emacs buffer))
              (define saved (emacs-current-buffer))
              (grant-capability!
               `(capability-grant
                 (id test-stale-grant)
                 (library (emacs buffer edit))
                 (effect buffer-insert!)
                 (scope (buffer ,saved) (range 1 7))
                 (expires never)))"))
          (kill-buffer buffer)
          (setq buffer nil)
          (let ((condition
                 (should-error
                  (agent-scheme-session-eval-source
                   "stale-grant-session"
                   "(import (emacs buffer edit))
                    (buffer-insert! saved 2 \"X\")")
                  :type 'agent-scheme-capability-grant-error)))
            (should
             (string-match-p "stale capability grant handle"
                             (cadr condition)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (agent-scheme-session-clear!))))

(ert-deftest agent-scheme-capability-test-buffer-save-writes-file-backed-buffer ()
  "Save a file-backed buffer through the buffer-edit policy gate."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (path (make-temp-file "agent-scheme-buffer-save-" nil ".txt"))
        buffer)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect path))
          (agent-scheme-audit-clear)
          (with-current-buffer buffer
            (setq-local require-final-newline nil)
            (erase-buffer)
            (insert "saved through capability")
            (set-buffer-modified-p t)
            (agent-scheme-eval-source
             "(import (scheme base)
                      (agent capability)
                      (emacs buffer)
                      (emacs buffer edit))
              (define handle (emacs-current-buffer))
              (grant-capability!
               `(capability-grant
                 (id save-buffer-grant)
                 (library (emacs buffer edit))
                 (effect buffer-save!)
                 (scope (buffer ,handle))
                 (expires (uses 1))))
              (buffer-save! handle)")
            (should-not (buffer-modified-p)))
          (with-temp-buffer
            (insert-file-contents path)
            (should (equal (buffer-string) "saved through capability")))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(operation \"buffer-save!\")"
            "(target-file"
            "(outcome success)")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p path)
        (delete-file path)))))

(ert-deftest agent-scheme-capability-test-buffer-edit-denies-internal-buffers ()
  "Reject edits to hidden/internal buffers even when buffer-edit is allowed."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer " *agent-scheme-capability-internal*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "unchanged")
          (let ((condition
                 (should-error
                  (agent-scheme-eval-source
                   "(import (scheme base)
                            (agent capability)
                            (emacs buffer)
                            (emacs buffer edit))
                    (define handle (emacs-current-buffer))
                    (grant-capability!
                     `(capability-grant
                       (id internal-buffer-grant)
                       (library (emacs buffer edit))
                       (effect buffer-insert!)
                       (scope (buffer ,handle) (range 1 10))
                       (expires (uses 1))))
                    (buffer-insert! handle 1 \"x\")")
                  :type 'agent-scheme-eval-error)))
            (should
             (string-match-p "internal buffer" (cadr condition))))
          (should (equal (buffer-string) "unchanged")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-buffer-edit-denies-remote-buffers ()
  "Reject edits to remote file buffers even when buffer-edit is allowed."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((buffer-edit . allow))))
        (buffer (generate-new-buffer "agent-scheme-capability-remote")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "unchanged")
          (setq buffer-file-name "/ssh:agent-scheme.invalid:/tmp/file.txt")
          (let ((condition
                 (should-error
                  (agent-scheme-eval-source
                   "(import (scheme base)
                            (agent capability)
                            (emacs buffer)
                            (emacs buffer edit))
                    (define handle (emacs-current-buffer))
                    (grant-capability!
                     `(capability-grant
                       (id remote-buffer-grant)
                       (library (emacs buffer edit))
                       (effect buffer-insert!)
                       (scope (buffer ,handle) (range 1 10))
                       (expires (uses 1))))
                    (buffer-insert! handle 1 \"x\")")
                  :type 'agent-scheme-eval-error)))
            (should
             (string-match-p "remote buffer" (cadr condition))))
          (should (equal (buffer-string) "unchanged")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-window-and-project-queries ()
  "Expose current window handles and project root through capability libraries."
  (let ((default-directory agent-scheme--test-root))
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (scheme base) (emacs window))
        (pair? (emacs-window-list))")
      "#t"))
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (emacs project))
        (project-root)")
      (format "\"%s\""
              (file-name-as-directory
               (expand-file-name agent-scheme--test-root)))))))

(ert-deftest agent-scheme-capability-test-search-manifest-and-import ()
  "Expose the `(emacs search)' library as read-only capability bindings."
  (dolist (binding '("buffer-search"
                     "project-search"
                     "project-files"
                     "search-yield"))
    (let ((spec (agent-scheme-capability-test--manifest-spec
                 "(emacs search)" binding)))
      (should spec)
      (should (eq (plist-get spec :source) 'host-capability))
      (should (eq (plist-get spec :effect) 'host-observation))
      (should (eq (plist-get spec :required-capability) 'emacs-search))
      (should (eq (plist-get spec :policy) 'allow))))
  (should
   (equal
    (agent-scheme-capability-test--external
     "(import (scheme base) (emacs search))
      (list (procedure? buffer-search)
            (procedure? project-search)
            (procedure? project-files)
            (procedure? search-yield))")
    "(#t #t #t #t)")))

(ert-deftest agent-scheme-capability-test-buffer-search-returns-source-locations ()
  "Search a live buffer and return Scheme-readable source locations."
  (with-temp-buffer
    (rename-buffer "agent-scheme-search-buffer" t)
    (insert "alpha one\nbeta\nalpha two\n")
    (let ((external
           (agent-scheme-capability-test--external
            "(import (scheme base) (emacs buffer) (emacs search))
             (buffer-search
              (emacs-current-buffer)
              \"alpha\"
              '((limit 2)))")))
      (should
       (string-match-p
        (regexp-quote
         "((search-result (source buffer) (buffer \"agent-scheme-search-buffer\")")
        external))
      (should
       (string-match-p
        (regexp-quote
         "(file #f) (relative-file #f) (line 1) (column 1) (start 1) (end 6)")
        external))
      (should
       (string-match-p
        (regexp-quote "(preview \"alpha one\")")
        external))
      (should
       (string-match-p
        (regexp-quote "(line 3) (column 1) (start 16) (end 21)")
        external)))))

(ert-deftest agent-scheme-capability-test-buffer-search-no-match-and-limit ()
  "Return no matches cleanly and enforce the result limit."
  (with-temp-buffer
    (rename-buffer "agent-scheme-search-limit" t)
    (insert "needle one\nneedle two\n")
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (emacs buffer) (emacs search))
        (buffer-search (emacs-current-buffer) \"missing\" '())")
      "()"))
    (let ((external
           (agent-scheme-capability-test--external
            "(import (emacs buffer) (emacs search))
             (buffer-search
              (emacs-current-buffer)
              \"needle\"
              '((limit 1)))")))
      (should
       (string-match-p (regexp-quote "(preview \"needle one\")") external))
      (should-not
       (string-match-p (regexp-quote "(preview \"needle two\")") external)))))

(ert-deftest agent-scheme-capability-test-project-search-respects-default-guards ()
  "Search project files while skipping generated, binary, and oversized files."
  (let* ((root (file-name-as-directory
                (make-temp-file "agent-scheme-project-search-" t)))
         (source (expand-file-name "src/main.scm" root))
         (no-match (expand-file-name "src/a-no-match.scm" root))
         (generated (expand-file-name "node_modules/generated.scm" root))
         (binary (expand-file-name "src/blob.dat" root))
         (large (expand-file-name "src/large.scm" root))
         (default-directory root))
    (unwind-protect
        (progn
          (agent-scheme-capability-test--write-file
           source "(define needle 42)\n")
          (agent-scheme-capability-test--write-file
           no-match "(define other 42)\n")
          (agent-scheme-capability-test--write-file
           generated "needle from generated code\n")
          (agent-scheme-capability-test--write-binary-file
           binary '(110 101 101 100 108 101 0 120))
          (agent-scheme-capability-test--write-file
           large "needle in oversized file\n")
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       (cons 'transient root))))
            (let ((external
                   (agent-scheme-capability-test--external
                    "(import (emacs search))
                     (project-search
                      \"needle\"
                      '((limit 10) (max-file-bytes 20)))")))
              (should
               (string-match-p
                (regexp-quote "(relative-file \"src/main.scm\")")
                external))
              (should-not
               (string-match-p (regexp-quote "node_modules") external))
              (should-not
               (string-match-p (regexp-quote "blob.dat") external))
              (should-not
               (string-match-p (regexp-quote "large.scm") external)))
            (let ((external
                   (agent-scheme-capability-test--external
                    "(import (emacs search))
                     (project-search
                      \"needle\"
                      '((limit 1) (max-file-bytes 20)))")))
              (should
               (string-match-p
                (regexp-quote "(relative-file \"src/main.scm\")")
                external)))
            (let ((files
                   (agent-scheme-capability-test--external
                    "(import (emacs search))
                     (project-files '((limit 10)))")))
              (should
               (string-match-p
                (regexp-quote "((project-file (file")
                files))
              (should
               (string-match-p
                (regexp-quote "(relative-file \"src/main.scm\")")
                files))
              (should-not
               (string-match-p (regexp-quote "node_modules") files)))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest agent-scheme-capability-test-search-yield-records-events ()
  "Yield search results through the evaluation event channel."
  (agent-scheme-audit-clear)
  (with-temp-buffer
    (rename-buffer "agent-scheme-search-yield" t)
    (insert "alpha\n")
    (let ((result
           (agent-scheme-result->external
            (agent-scheme-eval-source-result
             "(import (scheme base) (emacs buffer) (emacs search))
              (search-yield
               (buffer-search
                (emacs-current-buffer)
                \"alpha\"
                '((limit 1))))
              'ok"))))
      (should (string-match-p (regexp-quote "(status ok)") result))
      (should
       (string-match-p
        (regexp-quote "(events ((yield (search-results")
        result))
      (should
       (string-match-p
        (regexp-quote "(buffer \"agent-scheme-search-yield\")")
        result))))
  (should
   (agent-scheme-capability-test--audit-entry-matching
    "(event agent-event)"
    "(category emacs-search)"
    "(operation \"search-yield\")"
    "(decision recorded)")))

(ert-deftest agent-scheme-capability-test-window-session-manifest-metadata ()
  "Expose mutating window/session capabilities through policy metadata."
  (dolist (binding '(("(emacs buffer)" "buffer-switch!" emacs-buffer)
                     ("(emacs window)" "window-select!" emacs-window)
                     ("(emacs window)" "window-split!" emacs-window)
                     ("(emacs window)" "window-delete!" emacs-window)
                     ("(emacs command)" "command-call!" emacs-command)
                     ("(emacs project)" "project-compile!" emacs-project)
                     ("(emacs project)" "project-recompile!" emacs-project)))
    (let ((spec (agent-scheme-capability-test--manifest-spec
                 (nth 0 binding)
                 (nth 1 binding))))
      (should spec)
      (should (eq (plist-get spec :source) 'host-capability))
      (should (eq (plist-get spec :effect) 'host-mutation))
      (should (eq (plist-get spec :required-capability) (nth 2 binding)))
      (should (eq (plist-get spec :backend-effect-path)
                  'shared-capability-request))
      (should (eq (plist-get spec :policy) 'confirm))
      (should
       (eq (plist-get spec :policy-category)
           (if (member (nth 1 binding)
                       '("command-call!"
                         "project-compile!"
                         "project-recompile!"))
               'command-process
             'window-session))))))

(ert-deftest agent-scheme-capability-test-buffer-switch-and-window-select ()
  "Switch buffers and select windows through controlled session capabilities."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((window-session . allow))))
        (environment (agent-scheme-make-base-environment))
        (original-window (selected-window))
        (left-buffer (generate-new-buffer "agent-scheme-window-left"))
        (right-buffer (generate-new-buffer "agent-scheme-window-right"))
        right-window)
    (unwind-protect
        (progn
          (switch-to-buffer left-buffer)
          (setq right-window (split-window original-window nil 'right))
          (set-window-buffer right-window right-buffer)
          (select-window original-window)
          (agent-scheme--environment-define
           environment "target-buffer"
           (agent-scheme--buffer-handle right-buffer))
          (agent-scheme--environment-define
           environment "target-window"
           (agent-scheme--window-handle right-window))
          (agent-scheme-audit-clear)
          (agent-scheme-eval-source
           "(import (scheme base)
                    (agent capability)
                    (emacs buffer)
                    (emacs window))
            (grant-capability!
             `(capability-grant
               (id switch-buffer-grant)
               (library (emacs buffer))
               (effect buffer-switch!)
               (scope (buffer ,target-buffer))
               (expires (uses 1))))
            (grant-capability!
             `(capability-grant
               (id select-window-grant)
               (library (emacs window))
               (effect window-select!)
               (scope (window ,target-window))
               (expires (uses 1))))
            (buffer-switch! target-buffer)
            (window-select! target-window)"
           environment)
          (should (eq (window-buffer original-window) right-buffer))
          (should (eq (selected-window) right-window))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(category window-session)"
            "(operation \"buffer-switch!\")"
            "(target-buffer \"agent-scheme-window-right\")"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(category window-session)"
            "(operation \"window-select!\")"
            "(outcome success)")))
      (when (window-live-p right-window)
        (delete-window right-window))
      (when (window-live-p original-window)
        (select-window original-window))
      (when (buffer-live-p left-buffer)
        (kill-buffer left-buffer))
      (when (buffer-live-p right-buffer)
        (kill-buffer right-buffer)))))

(ert-deftest agent-scheme-capability-test-window-split-and-delete ()
  "Split and delete windows through controlled session capabilities."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((window-session . allow))))
        (original-window (selected-window)))
    (unwind-protect
        (progn
          (delete-other-windows original-window)
          (agent-scheme-audit-clear)
          (agent-scheme-eval-source
           "(import (scheme base)
                    (agent capability)
                    (emacs window))
            (grant-capability!
             '(capability-grant
               (id split-window-grant)
               (library (emacs window))
               (effect window-split!)
               (scope (direction right))
               (expires (uses 1))))
            (define created (window-split! 'right))
            (grant-capability!
             `(capability-grant
               (id delete-window-grant)
               (library (emacs window))
               (effect window-delete!)
               (scope (window ,created))
               (expires (uses 1))))
            (window-delete! created)")
          (should (= (length (window-list nil 'no-minibuf)) 1))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(operation \"window-split!\")"
            "(direction right)"
            "(outcome success)"))
          (should
           (agent-scheme-capability-test--audit-entry-matching
            "(event capability-result)"
            "(operation \"window-delete!\")"
            "(outcome success)")))
      (when (window-live-p original-window)
        (select-window original-window)
        (delete-other-windows original-window)))))

(ert-deftest agent-scheme-capability-test-stale-window-handles-fail-clearly ()
  "Reject window handles after the live Emacs window disappears."
  (let ((environment (agent-scheme-make-base-environment))
        (original-window (selected-window))
        window handle)
    (unwind-protect
        (progn
          (setq window (split-window original-window nil 'below))
          (select-window window)
          (setq handle
                (agent-scheme-eval-source
                 "(import (scheme base) (emacs window))
                  (car (emacs-window-list))"
                 environment))
          (delete-window window)
          (setq window nil)
          (select-window original-window)
          (agent-scheme--environment-define environment "stale-window" handle)
          (let ((condition
                 (should-error
                  (agent-scheme-eval-source
                   "(window-frame stale-window)" environment)
                  :type 'agent-scheme-eval-error)))
            (should
             (string-match-p "stale window handle" (cadr condition)))))
      (when (window-live-p window)
        (delete-window window))
      (when (window-live-p original-window)
        (select-window original-window)))))

(ert-deftest agent-scheme-capability-test-frame-handles ()
  "Inspect frames through opaque handles."
  (should
   (string-match-p
    "\\`(handle frame h-[0-9]+)\\'"
    (agent-scheme-capability-test--external
     "(import (emacs frame))
      (emacs-current-frame)")))
  (should
   (equal
    (agent-scheme-capability-test--external
     "(import (scheme base) (emacs frame) (emacs window))
      (list (string? (frame-name (emacs-current-frame)))
            (pair? (emacs-frame-list))
            (string? (frame-name
                      (window-frame (car (emacs-window-list))))))")
    "(#t #t #t)")))

(ert-deftest agent-scheme-capability-test-project-handles ()
  "Inspect the current project through an opaque project handle."
  (let ((default-directory agent-scheme--test-root)
        (expected-root
         (file-name-as-directory (expand-file-name agent-scheme--test-root))))
    (should
     (string-match-p
      "\\`(handle project h-[0-9]+)\\'"
      (agent-scheme-capability-test--external
       "(import (emacs project))
        (emacs-current-project)")))
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (scheme base) (emacs project))
        (let ((project (emacs-current-project)))
          (list (not (eq? project #f))
                (project-root project)
                (project-root)))")
      (format "(#t \"%s\" \"%s\")" expected-root expected-root)))))

(ert-deftest agent-scheme-capability-test-process-handles ()
  "Inspect live processes through opaque handles and reject stale handles."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (environment (agent-scheme-make-base-environment))
        (buffer (generate-new-buffer "agent-scheme-capability-process-buffer"))
        process handle)
    (unwind-protect
        (progn
          (setq process
                (start-process
                 "agent-scheme-capability-process" buffer "cat"))
          (set-process-query-on-exit-flag process nil)
          (accept-process-output process 0.1)
          (should
           (equal
            (agent-scheme-capability-test--external
             "(import (scheme base)
                      (agent capability)
                      (emacs buffer)
                      (emacs process))
              (grant-capability!
               '(capability-grant
                 (id process-observe-grant)
                 (domain process)
                 (operations (observe))
                 (expires never)))
              (define (find-process handles)
                (cond
                 ((null? handles) #f)
                 ((string=? (process-name (car handles))
                            \"agent-scheme-capability-process\")
                  (car handles))
                 (else (find-process (cdr handles)))))
              (let ((handle (find-process (emacs-process-list))))
                (list (process-name handle)
                      (process-status handle)
                      (buffer-name (process-buffer handle))))")
            (format "(\"agent-scheme-capability-process\" run \"%s\")"
                    (buffer-name buffer))))
          (setq handle
                (agent-scheme-eval-source
                 "(import (scheme base)
                          (agent capability)
                          (emacs process))
                  (grant-capability!
                   '(capability-grant
                     (id process-observe-grant)
                     (domain process)
                     (operations (observe))
                     (expires never)))
                  (define (find-process handles)
                    (cond
                     ((null? handles) #f)
                     ((string=? (process-name (car handles))
                                \"agent-scheme-capability-process\")
                      (car handles))
                     (else (find-process (cdr handles)))))
                  (find-process (emacs-process-list))"
                 environment))
          (delete-process process)
          (setq process nil)
          (agent-scheme--environment-define environment "stale-process" handle)
          (let ((condition
                 (should-error
                  (agent-scheme-eval-source
                   "(process-name stale-process)" environment)
                  :type 'agent-scheme-eval-error)))
            (should
             (string-match-p "stale process handle" (cadr condition)))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-process-domain-denied-by-default ()
  "Construct and deny process requests before the host adapter starts a job."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub))
    (setq agent-scheme-capability-test--process-starts nil)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (scheme base) (emacs process))
       (process-start!
        \"denied\" \"agent-scheme-test-process\" '(\"ok\") '())")
     :type 'agent-scheme-capability-grant-error)
    (should-not agent-scheme-capability-test--process-starts)
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-request)"
      "(domain process)"
      "(operation spawn)"
      "(command \"agent-scheme-test-process\")"))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(reason \"no active process grant covers request\")"))))

(ert-deftest agent-scheme-capability-test-process-domain-starts-through-grant ()
  "Start a process through a grant and expose only Scheme-readable handles."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub))
    (setq agent-scheme-capability-test--process-starts nil)
    (agent-scheme-audit-clear)
    (let ((external
           (agent-scheme-capability-test--external
            "(import (scheme base)
                     (agent capability)
                     (emacs process))
             (grant-capability!
              '(capability-grant
                (id process-grant)
                (domain process)
                (operations (spawn observe output input terminate))
                (scope (command \"agent-scheme-test-process\")
                       (working-directory \"/tmp\")
                       (environment (\"OPENAI_API_KEY\")))
                (expires (uses 6))))
             (let ((handle
                    (process-start!
                     \"allowed\"
                     \"agent-scheme-test-process\"
                     '(\"--token=sk-processarg1234567890\")
                     '((cwd \"/tmp\")
                       (environment
                        ((\"OPENAI_API_KEY\"
                          \"sk-processenv1234567890\")))))))
               (list handle
                     (process-name handle)
                     (process-status handle)))")))
      (should (string-match-p "(handle process h-[0-9]+)" external))
      (should (string-match-p "\"allowed\"" external))
      (should (string-match-p "run" external))
      (should (= (length agent-scheme-capability-test--process-starts) 1))
      (should-not (string-match-p "sk-processarg" external)))
    (let ((audit (mapconcat #'identity
                            (agent-scheme-capability-test--audit-strings)
                            "\n")))
      (should (string-match-p "\\[redacted\\]" audit))
      (should-not (string-match-p "sk-processarg" audit))
      (should-not (string-match-p "sk-processenv" audit)))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-handle)"
      "(domain process)"
      "(kind process-job)"
      "(grant process-grant)"
      "(status live)"))))

(ert-deftest agent-scheme-capability-test-process-command-mismatch-denies ()
  "Deny process starts whose command is outside the grant scope."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process" "agent-scheme-other-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub))
    (setq agent-scheme-capability-test--process-starts nil)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (scheme base)
               (agent capability)
               (emacs process))
       (grant-capability!
        '(capability-grant
          (id process-grant)
          (domain process)
          (operations (spawn))
          (scope (command \"agent-scheme-test-process\"))
          (expires (uses 1))))
       (process-start!
        \"mismatch\" \"agent-scheme-other-process\" '() '())")
     :type 'agent-scheme-capability-grant-error)
    (should-not agent-scheme-capability-test--process-starts)
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(grant process-grant)"
      "command is outside approved process grant scope"))))

(ert-deftest agent-scheme-capability-test-process-environment-mismatch-denies ()
  "Deny process starts whose environment is outside the grant scope."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub))
    (setq agent-scheme-capability-test--process-starts nil)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (scheme base)
               (agent capability)
               (emacs process))
       (grant-capability!
        '(capability-grant
          (id process-grant)
          (domain process)
          (operations (spawn))
          (scope (command \"agent-scheme-test-process\")
                 (environment (\"ALLOWED_ENV\")))
          (expires (uses 1))))
       (process-start!
        \"env-mismatch\" \"agent-scheme-test-process\" '()
        '((environment
           ((\"DENIED_ENV\" \"sk-processenv-denied1234567890\")))))")
     :type 'agent-scheme-capability-grant-error)
    (should-not agent-scheme-capability-test--process-starts)
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(grant process-grant)"
      "environment is outside approved process grant scope"))
    (let ((audit (mapconcat #'identity
                            (agent-scheme-capability-test--audit-strings)
                            "\n")))
      (should-not (string-match-p "sk-processenv-denied" audit)))))

(ert-deftest agent-scheme-capability-test-process-ports-route-through-capabilities ()
  "Represent process streams as process-backed port capabilities."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub))
    (agent-scheme-audit-clear)
    (let ((external
           (agent-scheme-capability-test--external
            "(import (scheme base)
                     (agent capability)
                     (emacs process))
             (grant-capability!
              '(capability-grant
                (id process-port-grant)
                (domain process)
                (operations (spawn output input))
                (scope (command \"agent-scheme-test-process\"))
                (expires (uses 5))))
             (define handle
               (process-start!
                \"ports\" \"agent-scheme-test-process\" '() '()))
             (define stdout (process-output-port handle))
             (define stdin (process-input-port handle))
             (write-string \"payload\" stdin)
             (list (input-port? stdout)
                   (output-port? stdin)
                   (read-string 3 stdout)
                   (output-port-open? stdin))")))
      (should (equal external "(#t #t \"out\" #t)")))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-handle)"
      "(domain port)"
      "(backing process)"
      "(kind textual-input)"
      "(grant process-port-grant)"))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-handle)"
      "(domain port)"
      "(backing process)"
      "(kind textual-output)"
      "(grant process-port-grant)"))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-audit)"
      "(domain port)"
      "(operation read)"
      "(backing process)"))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-audit)"
      "(domain port)"
      "(operation write)"
      "(backing process)"))))

(ert-deftest agent-scheme-capability-test-process-port-stale-handle-denies ()
  "Fail closed when a process-backed port outlives its process handle."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub)
        (environment (agent-scheme-make-base-environment))
        handle)
    (setq handle
          (agent-scheme-eval-source
           "(import (scheme base)
                    (agent capability)
                    (emacs process))
            (grant-capability!
             '(capability-grant
               (id process-port-grant)
               (domain process)
               (operations (spawn output))
               (scope (command \"agent-scheme-test-process\"))
               (expires never)))
            (define handle
              (process-start!
               \"stale-port\" \"agent-scheme-test-process\" '() '()))
            (define stdout (process-output-port handle))
            handle"
           environment))
    (agent-scheme-capability-release-handle handle)
    (agent-scheme--environment-define
     environment
     "stale-stdout"
     (agent-scheme--environment-ref environment "stdout"))
    (agent-scheme-audit-clear)
    (let ((condition
           (should-error
            (agent-scheme-eval-source
             "(read-string 1 stale-stdout)" environment)
            :type 'agent-scheme-capability-grant-error)))
      (should
       (string-match-p "stale port capability handle" (cadr condition))))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-audit)"
      "(domain port)"
      "(operation read)"
      "stale process port handle"))))

(ert-deftest agent-scheme-capability-test-process-stale-handle-denies ()
  "Fail closed when a process handle has gone stale."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist
         '("agent-scheme-test-process"))
        (agent-scheme-process-start-function
         #'agent-scheme-capability-test--process-stub)
        (environment (agent-scheme-make-base-environment))
        handle)
    (setq handle
          (agent-scheme-eval-source
           "(import (scheme base)
                    (agent capability)
                    (emacs process))
            (grant-capability!
             '(capability-grant
               (id process-grant)
               (domain process)
               (operations (spawn observe))
               (scope (command \"agent-scheme-test-process\"))
               (expires (uses 2))))
            (process-start!
             \"stale\" \"agent-scheme-test-process\" '() '())"
           environment))
    (agent-scheme-capability-release-handle handle)
    (agent-scheme--environment-define environment "stale-process" handle)
    (agent-scheme-audit-clear)
    (let ((condition
           (should-error
            (agent-scheme-eval-source
             "(process-status stale-process)" environment)
            :type 'agent-scheme-capability-grant-error)))
      (should
       (string-match-p "stale process handle" (cadr condition))))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-decision)"
      "(domain process)"
      "(status denied)"
      "(reason \"stale process handle\")"))))

(ert-deftest agent-scheme-capability-test-documentation-capabilities ()
  "Expose documentation metadata without exposing variable values."
  (should
   (equal
    (agent-scheme-capability-test--external
     "(import (scheme base) (emacs command))
      (list (string? (command-doc 'find-file))
            (string? (function-doc 'car)))")
    "(#t #t)"))
  (let ((external
         (agent-scheme-capability-test--external
          "(import (emacs command))
           (variable-info 'agent-scheme-capability-test--secret)")))
    (should
     (string-match-p "agent-scheme-capability-test--secret" external))
    (should
     (string-match-p "documentation" external))
    (should-not
     (string-match-p "secret-value" external))))

(ert-deftest agent-scheme-capability-test-command-call-whitelist-allows-command ()
  "Run whitelisted commands through command-call!."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-command-whitelist
         '((agent-scheme-capability-test-command :allow-interactive nil))))
    (setq agent-scheme-capability-test--command-log nil)
    (agent-scheme-audit-clear)
    (agent-scheme-eval-source
     "(import (emacs command))
      (command-call! 'agent-scheme-capability-test-command \"value\" #t)")
    (should
     (equal agent-scheme-capability-test--command-log
            '("value" t)))
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-result)"
      "(category command-process)"
      "(operation \"command-call!\")"
      "(command agent-scheme-capability-test-command)"
      "(outcome success)"))))

(ert-deftest agent-scheme-capability-test-command-call-denies-unlisted-command ()
  "Reject commands that are not present in the command whitelist."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-command-whitelist nil))
    (setq agent-scheme-capability-test--command-log nil)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (emacs command))
       (command-call! 'agent-scheme-capability-test-command \"value\")")
     :type 'agent-scheme-policy-error)
    (should-not agent-scheme-capability-test--command-log)
    (should
     (agent-scheme-capability-test--audit-entry-matching
      "(event capability-call)"
      "(category command-process)"
      "(operation \"command-call!\")"
      "(decision denied)"
      "command is not whitelisted"))))

(ert-deftest agent-scheme-capability-test-command-call-rejects-prompts-by-default ()
  "Reject interactive prompt collection unless a whitelist entry allows it."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-capability-test--actions '((command-process . allow))))
        (agent-scheme-command-whitelist
         '((agent-scheme-capability-test-prompt-command
            :allow-interactive nil))))
    (setq agent-scheme-capability-test--command-log nil)
    (let ((condition
           (should-error
            (agent-scheme-eval-source
             "(import (emacs command))
              (command-call! 'agent-scheme-capability-test-prompt-command)")
            :type 'agent-scheme-eval-error)))
      (should
       (string-match-p "interactive prompt is not allowed"
                       (cadr condition))))
    (should-not agent-scheme-capability-test--command-log)))

(ert-deftest agent-scheme-capability-test-manifest-describes-emacs-bindings ()
  "Expose metadata for Emacs capability bindings."
  (let ((current-buffer (agent-scheme-capability-test--manifest-spec
                         "(emacs buffer)" "emacs-current-buffer"))
        (buffer-text (agent-scheme-capability-test--manifest-spec
                      "(emacs buffer)" "buffer-text"))
        (buffer-replace (agent-scheme-capability-test--manifest-spec
                         "(emacs buffer edit)" "buffer-replace!"))
        (buffer-save (agent-scheme-capability-test--manifest-spec
                      "(emacs buffer edit)" "buffer-save!"))
        (current-frame (agent-scheme-capability-test--manifest-spec
                        "(emacs frame)" "emacs-current-frame"))
        (current-project (agent-scheme-capability-test--manifest-spec
                          "(emacs project)" "emacs-current-project"))
        (process-status (agent-scheme-capability-test--manifest-spec
                         "(emacs process)" "process-status"))
        (command-doc (agent-scheme-capability-test--manifest-spec
                      "(emacs command)" "command-doc")))
    (should current-buffer)
    (should (eq (plist-get current-buffer :source) 'host-capability))
    (should (eq (plist-get current-buffer :effect) 'host-observation))
    (should (eq (plist-get current-buffer :required-capability)
                'emacs-buffer))
    (should (eq (plist-get current-buffer :policy) 'allow))
    (should (equal (plist-get buffer-text :minimum-arity) 3))
    (should (eq (plist-get buffer-text :required-capability) 'emacs-buffer))
    (should (eq (plist-get buffer-replace :effect) 'host-mutation))
    (should (eq (plist-get buffer-replace :policy-category) 'buffer-edit))
    (should (eq (plist-get buffer-replace :policy) 'confirm))
    (should (plist-get buffer-replace :requires-grant))
    (should (eq (plist-get buffer-save :effect) 'host-mutation))
    (should (eq (plist-get buffer-save :policy-category) 'buffer-edit))
    (should (plist-get buffer-save :requires-grant))
    (should (eq (plist-get current-frame :required-capability) 'emacs-frame))
    (should (eq (plist-get current-project :required-capability)
                'emacs-project))
    (should (eq (plist-get process-status :required-capability)
                'emacs-process))
    (should (eq (plist-get command-doc :required-capability)
                'emacs-documentation))))

;;; agent-scheme-capability-test.el ends here
