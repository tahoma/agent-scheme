;;; consent-compile-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the `(emacs compile)' adapter library.  These tests
;; keep compile/test workflow authority behind process-domain grants while
;; exposing Emacs compilation buffers as Scheme-readable datums.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-capability)
(require 'consent-eval)
(require 'consent-policy)
(require 'consent-result)

(defvar consent-compile-start-function)

(defvar consent-compile-test--starts nil
  "Compile start requests observed by compile capability tests.")

(defvar consent-compile-test--buffers nil
  "Compilation buffers created by compile capability tests.")

(defun consent-compile-test--start-stub (command options _context)
  "Return a fake compile job for COMMAND and OPTIONS."
  (push (list command options) consent-compile-test--starts)
  (list :name "compile"
        :command command
        :arguments nil
        :options options
        :status 'exit
        :stdout "compile ok\n"
        :stderr ""
        :exit-status 0))

(defun consent-compile-test--error-start-stub (command options _context)
  "Return a fake failed compile job backed by a compilation buffer."
  (let ((buffer (generate-new-buffer " *consent-compile-errors*")))
    (push buffer consent-compile-test--buffers)
    (push (list command options) consent-compile-test--starts)
    (with-current-buffer buffer
      (insert "src/main.scm:2:3: error: bad form\n")
      (compilation-mode))
    (list :name "compile-errors"
          :command command
          :arguments nil
          :options options
          :status 'exit
          :buffer buffer
          :exit-status 1)))

(defun consent-compile-test--kill-buffers ()
  "Kill compilation buffers created by compile capability tests."
  (dolist (buffer consent-compile-test--buffers)
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (setq consent-compile-test--buffers nil))

(defun consent-compile-test--external (source &optional environment options)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source environment options)))

(defun consent-compile-test--manifest-spec (name)
  "Return Emacs compile capability metadata for binding NAME."
  (seq-find
   (lambda (spec)
     (and (equal (plist-get spec :library) "(emacs compile)")
          (equal (plist-get spec :name) name)))
   (consent-emacs-capability-binding-specs)))

(defun consent-compile-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-compile-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-compile-test--audit-strings)))

(defun consent-compile-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           consent-policy-category-actions)))

(ert-deftest consent-compile-test-manifest-and-import ()
  "Expose `(emacs compile)' as an explicit capability library."
  (dolist (binding '(("compile-run!" host-mutation confirm)
                     ("project-compile!" host-mutation confirm)
                     ("recompile!" host-mutation confirm)
                     ("compile-status" host-observation allow)
                     ("compile-output" host-observation allow)
                     ("compile-yield" host-observation allow)))
    (let ((spec (consent-compile-test--manifest-spec (car binding))))
      (should spec)
      (should (eq (plist-get spec :source) 'host-capability))
      (should (eq (plist-get spec :effect) (cadr binding)))
      (should (eq (plist-get spec :required-capability) 'emacs-compile))
      (should (eq (plist-get spec :backend-effect-path)
                  'shared-capability-request))
      (should (eq (plist-get spec :policy-category) 'command-process))
      (should (eq (plist-get spec :policy) (caddr binding)))))
  (should
   (equal
    (consent-compile-test--external
     "(import (scheme base) (emacs compile))
      (list (procedure? compile-run!)
            (procedure? project-compile!)
            (procedure? recompile!)
            (procedure? compile-status)
            (procedure? compile-output)
            (procedure? compile-yield))")
    "(#t #t #t #t #t #t)")))

(ert-deftest consent-compile-test-run-denies-without-process-grant ()
  "Deny compile-run! through the process domain before starting Emacs compile."
  (let ((consent-policy-category-actions
         (consent-compile-test--actions '((command-process . allow))))
        (consent-process-command-allowlist '("make test"))
        (consent-compile-start-function
         #'consent-compile-test--start-stub))
    (setq consent-compile-test--starts nil)
    (consent-audit-clear)
    (should-error
     (consent-eval-source
      "(import (emacs compile))
       (compile-run! \"make test\" '())")
     :type 'consent-capability-grant-error)
    (should-not consent-compile-test--starts)
    (should
     (consent-compile-test--audit-entry-matching
      "(event capability-request)"
      "(domain process)"
      "(operation spawn)"
      "(binding compile-run!)"
      "(command \"make test\")"))
    (should
     (consent-compile-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(reason \"no active process grant covers request\")"))))

(ert-deftest consent-compile-test-run-status-and-output-through-grant ()
  "Start an approved compile job and inspect status/output datums."
  (let ((consent-policy-category-actions
         (consent-compile-test--actions '((command-process . allow))))
        (consent-process-command-allowlist '("make test"))
        (consent-compile-start-function
         #'consent-compile-test--start-stub))
    (setq consent-compile-test--starts nil)
    (consent-audit-clear)
    (let ((external
           (consent-compile-test--external
            "(import (scheme base)
                     (consent capability)
                     (emacs compile))
             (grant-capability!
              '(capability-grant
                (id compile-grant)
                (domain process)
                (operations (spawn observe output))
                (scope (command \"make test\")
                       (working-directory \"/tmp\"))
                (expires (uses 3))))
             (define handle
               (compile-run! \"make test\" '((cwd \"/tmp\"))))
             (list handle
                   (compile-status handle)
                   (compile-output handle '((max-chars 20))))")))
      (should (= (length consent-compile-test--starts) 1))
      (should (string-match-p "(handle process h-[0-9]+)" external))
      (should (string-match-p "(compile-status " external))
      (should (string-match-p "(status completed)" external))
      (should (string-match-p "(process-status exit)" external))
      (should (string-match-p "(exit-status 0)" external))
      (should (string-match-p "(compile-output " external))
      (should (string-match-p "(text \"compile ok\\\\n\")" external))
      (should (string-match-p "(truncated #f)" external)))
    (should
     (consent-compile-test--audit-entry-matching
      "(event capability-audit)"
      "(domain process)"
      "(operation spawn)"
      "(result (ok (handle process-job"))
    (should
     (consent-compile-test--audit-entry-matching
      "(event capability-result)"
      "(adapter emacs-compile)"
      "(operation \"compile-output\")"))))

(ert-deftest consent-compile-test-output-parses-compilation-locations ()
  "Return parsed error locations from an Emacs compilation buffer."
  (let ((consent-policy-category-actions
         (consent-compile-test--actions '((command-process . allow))))
        (consent-process-command-allowlist '("make test"))
        (consent-compile-start-function
         #'consent-compile-test--error-start-stub))
    (unwind-protect
        (progn
          (setq consent-compile-test--starts nil)
          (consent-audit-clear)
          (let ((external
                 (consent-compile-test--external
                  "(import (scheme base)
                           (consent capability)
                           (emacs compile))
                   (grant-capability!
                    '(capability-grant
                      (id compile-error-grant)
                      (domain process)
                      (operations (spawn observe output))
                      (scope (command \"make test\"))
                      (expires (uses 3))))
                   (define handle (compile-run! \"make test\" '()))
                   (list (compile-status handle)
                         (compile-output handle '()))")))
            (should (string-match-p "(status failed)" external))
            (should (string-match-p "(exit-status 1)" external))
            (should (string-match-p "(error-location " external))
            (should (string-match-p "(file \"src/main.scm\")" external))
            (should (string-match-p "(line 2)" external))
            (should (string-match-p "(column 3)" external))
            (should (string-match-p "(type error)" external))))
      (consent-compile-test--kill-buffers))))

(ert-deftest consent-compile-test-project-compile-and-recompile ()
  "Project compile uses project cwd and recompile starts from a prior handle."
  (let ((consent-policy-category-actions
         (consent-compile-test--actions '((command-process . allow))))
        (consent-process-command-allowlist '("make test"))
        (consent-compile-start-function
         #'consent-compile-test--start-stub)
        (root (file-name-as-directory
               (make-temp-file "consent-compile-project-" t))))
    (unwind-protect
        (progn
          (setq consent-compile-test--starts nil)
          (consent-audit-clear)
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       (cons 'transient root))))
            (let ((external
                   (let ((default-directory root))
                     (consent-compile-test--external
                      (format
                       "(import (scheme base)
                                (consent capability)
                                (emacs compile))
                        (grant-capability!
                         '(capability-grant
                           (id project-compile-grant)
                           (domain process)
                           (operations (spawn observe output))
                           (scope (command \"make test\")
                                  (working-directory %S))
                           (expires (uses 4))))
                        (define first
                          (project-compile! '((command \"make test\"))))
                        (define second (recompile! first))
                        (list (compile-status first)
                              (compile-status second))"
                       root)))))
              (should (= (length consent-compile-test--starts) 2))
              (should (string-match-p "(status completed)" external))
              (should (string-match-p "(command \"make test\")" external)))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-compile-test-command-allowlist-denies ()
  "Deny compile commands that are not in the process allow-list."
  (let ((consent-policy-category-actions
         (consent-compile-test--actions '((command-process . allow))))
        (consent-process-command-allowlist nil)
        (consent-compile-start-function
         #'consent-compile-test--start-stub))
    (setq consent-compile-test--starts nil)
    (consent-audit-clear)
    (should-error
     (consent-eval-source
      "(import (scheme base)
               (consent capability)
               (emacs compile))
       (grant-capability!
        '(capability-grant
          (id compile-grant)
          (domain process)
          (operations (spawn))
          (scope (command \"make test\"))
          (expires (uses 1))))
       (compile-run! \"make test\" '())")
     :type 'consent-capability-grant-error)
    (should-not consent-compile-test--starts)
    (should
     (consent-compile-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(reason \"command is not in process allow-list\")"))))

(ert-deftest consent-compile-test-yield-records-output-event ()
  "Yield compile output through the evaluation event channel."
  (let ((consent-policy-category-actions
         (consent-compile-test--actions '((command-process . allow))))
        (consent-process-command-allowlist '("make test"))
        (consent-compile-start-function
         #'consent-compile-test--start-stub))
    (setq consent-compile-test--starts nil)
    (consent-audit-clear)
    (let ((result
           (consent-result->external
            (consent-eval-source-result
             "(import (scheme base)
                      (consent capability)
                      (emacs compile))
              (grant-capability!
               '(capability-grant
                 (id compile-yield-grant)
                 (domain process)
                 (operations (spawn output))
                 (scope (command \"make test\"))
                 (expires (uses 2))))
              (define handle (compile-run! \"make test\" '()))
              (compile-yield handle)
              'ok"))))
      (should (string-match-p "(status ok)" result))
      (should (string-match-p "(events ((yield (compile-output" result))
      (should (string-match-p "(text \"compile ok\\\\n\")" result)))))

;;; consent-compile-test.el ends here
