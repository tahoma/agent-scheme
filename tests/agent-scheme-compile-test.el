;;; agent-scheme-compile-test.el --- Emacs compile capability tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the `(emacs compile)' adapter library.  These tests
;; keep compile/test workflow authority behind process-domain grants while
;; exposing Emacs compilation buffers as Scheme-readable datums.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-capability)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)

(defvar agent-scheme-compile-start-function)

(defvar agent-scheme-compile-test--starts nil
  "Compile start requests observed by compile capability tests.")

(defvar agent-scheme-compile-test--buffers nil
  "Compilation buffers created by compile capability tests.")

(defun agent-scheme-compile-test--start-stub (command options _context)
  "Return a fake compile job for COMMAND and OPTIONS."
  (push (list command options) agent-scheme-compile-test--starts)
  (list :name "compile"
        :command command
        :arguments nil
        :options options
        :status 'exit
        :stdout "compile ok\n"
        :stderr ""
        :exit-status 0))

(defun agent-scheme-compile-test--error-start-stub (command options _context)
  "Return a fake failed compile job backed by a compilation buffer."
  (let ((buffer (generate-new-buffer " *agent-scheme-compile-errors*")))
    (push buffer agent-scheme-compile-test--buffers)
    (push (list command options) agent-scheme-compile-test--starts)
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

(defun agent-scheme-compile-test--kill-buffers ()
  "Kill compilation buffers created by compile capability tests."
  (dolist (buffer agent-scheme-compile-test--buffers)
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (setq agent-scheme-compile-test--buffers nil))

(defun agent-scheme-compile-test--external (source &optional environment options)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source environment options)))

(defun agent-scheme-compile-test--manifest-spec (name)
  "Return Emacs compile capability metadata for binding NAME."
  (seq-find
   (lambda (spec)
     (and (equal (plist-get spec :library) "(emacs compile)")
          (equal (plist-get spec :name) name)))
   (agent-scheme-emacs-capability-binding-specs)))

(defun agent-scheme-compile-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-compile-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-compile-test--audit-strings)))

(defun agent-scheme-compile-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(ert-deftest agent-scheme-compile-test-manifest-and-import ()
  "Expose `(emacs compile)' as an explicit capability library."
  (dolist (binding '(("compile-run!" host-mutation confirm)
                     ("project-compile!" host-mutation confirm)
                     ("recompile!" host-mutation confirm)
                     ("compile-status" host-observation allow)
                     ("compile-output" host-observation allow)
                     ("compile-yield" host-observation allow)))
    (let ((spec (agent-scheme-compile-test--manifest-spec (car binding))))
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
    (agent-scheme-compile-test--external
     "(import (scheme base) (emacs compile))
      (list (procedure? compile-run!)
            (procedure? project-compile!)
            (procedure? recompile!)
            (procedure? compile-status)
            (procedure? compile-output)
            (procedure? compile-yield))")
    "(#t #t #t #t #t #t)")))

(ert-deftest agent-scheme-compile-test-run-denies-without-process-grant ()
  "Deny compile-run! through the process domain before starting Emacs compile."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-compile-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist '("make test"))
        (agent-scheme-compile-start-function
         #'agent-scheme-compile-test--start-stub))
    (setq agent-scheme-compile-test--starts nil)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (emacs compile))
       (compile-run! \"make test\" '())")
     :type 'agent-scheme-capability-grant-error)
    (should-not agent-scheme-compile-test--starts)
    (should
     (agent-scheme-compile-test--audit-entry-matching
      "(event capability-request)"
      "(domain process)"
      "(operation spawn)"
      "(binding compile-run!)"
      "(command \"make test\")"))
    (should
     (agent-scheme-compile-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(reason \"no active process grant covers request\")"))))

(ert-deftest agent-scheme-compile-test-run-status-and-output-through-grant ()
  "Start an approved compile job and inspect status/output datums."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-compile-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist '("make test"))
        (agent-scheme-compile-start-function
         #'agent-scheme-compile-test--start-stub))
    (setq agent-scheme-compile-test--starts nil)
    (agent-scheme-audit-clear)
    (let ((external
           (agent-scheme-compile-test--external
            "(import (scheme base)
                     (agent capability)
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
      (should (= (length agent-scheme-compile-test--starts) 1))
      (should (string-match-p "(handle process h-[0-9]+)" external))
      (should (string-match-p "(compile-status " external))
      (should (string-match-p "(status completed)" external))
      (should (string-match-p "(process-status exit)" external))
      (should (string-match-p "(exit-status 0)" external))
      (should (string-match-p "(compile-output " external))
      (should (string-match-p "(text \"compile ok\\\\n\")" external))
      (should (string-match-p "(truncated #f)" external)))
    (should
     (agent-scheme-compile-test--audit-entry-matching
      "(event capability-audit)"
      "(domain process)"
      "(operation spawn)"
      "(result (ok (handle process-job"))
    (should
     (agent-scheme-compile-test--audit-entry-matching
      "(event capability-result)"
      "(adapter emacs-compile)"
      "(operation \"compile-output\")"))))

(ert-deftest agent-scheme-compile-test-output-parses-compilation-locations ()
  "Return parsed error locations from an Emacs compilation buffer."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-compile-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist '("make test"))
        (agent-scheme-compile-start-function
         #'agent-scheme-compile-test--error-start-stub))
    (unwind-protect
        (progn
          (setq agent-scheme-compile-test--starts nil)
          (agent-scheme-audit-clear)
          (let ((external
                 (agent-scheme-compile-test--external
                  "(import (scheme base)
                           (agent capability)
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
      (agent-scheme-compile-test--kill-buffers))))

(ert-deftest agent-scheme-compile-test-project-compile-and-recompile ()
  "Project compile uses project cwd and recompile starts from a prior handle."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-compile-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist '("make test"))
        (agent-scheme-compile-start-function
         #'agent-scheme-compile-test--start-stub)
        (root (file-name-as-directory
               (make-temp-file "agent-scheme-compile-project-" t))))
    (unwind-protect
        (progn
          (setq agent-scheme-compile-test--starts nil)
          (agent-scheme-audit-clear)
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       (cons 'transient root))))
            (let ((external
                   (let ((default-directory root))
                     (agent-scheme-compile-test--external
                      (format
                       "(import (scheme base)
                                (agent capability)
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
              (should (= (length agent-scheme-compile-test--starts) 2))
              (should (string-match-p "(status completed)" external))
              (should (string-match-p "(command \"make test\")" external)))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest agent-scheme-compile-test-command-allowlist-denies ()
  "Deny compile commands that are not in the process allow-list."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-compile-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist nil)
        (agent-scheme-compile-start-function
         #'agent-scheme-compile-test--start-stub))
    (setq agent-scheme-compile-test--starts nil)
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-eval-source
      "(import (scheme base)
               (agent capability)
               (emacs compile))
       (grant-capability!
        '(capability-grant
          (id compile-grant)
          (domain process)
          (operations (spawn))
          (scope (command \"make test\"))
          (expires (uses 1))))
       (compile-run! \"make test\" '())")
     :type 'agent-scheme-capability-grant-error)
    (should-not agent-scheme-compile-test--starts)
    (should
     (agent-scheme-compile-test--audit-entry-matching
      "(event capability-decision)"
      "(status denied)"
      "(reason \"command is not in process allow-list\")"))))

(ert-deftest agent-scheme-compile-test-yield-records-output-event ()
  "Yield compile output through the evaluation event channel."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-compile-test--actions '((command-process . allow))))
        (agent-scheme-process-command-allowlist '("make test"))
        (agent-scheme-compile-start-function
         #'agent-scheme-compile-test--start-stub))
    (setq agent-scheme-compile-test--starts nil)
    (agent-scheme-audit-clear)
    (let ((result
           (agent-scheme-result->external
            (agent-scheme-eval-source-result
             "(import (scheme base)
                      (agent capability)
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

;;; agent-scheme-compile-test.el ends here
