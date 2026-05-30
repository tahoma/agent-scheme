;;; agent-scheme-runtime-test.el --- Runtime value module tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the evaluator runtime module boundary.  These checks keep
;; value records, lexical environments, and per-run context setup loadable
;; without depending on interpreter entry points.

;;; Code:

(require 'ert)
(require 'agent-scheme-result)

(defconst agent-scheme-runtime-test--version-source
  "scheme/agent-scheme/version.sld"
  "Repository-relative canonical Agent Scheme version source.")

(ert-deftest agent-scheme-runtime-test-version-components-are-canonical ()
  "Expose the runtime version as host components and a Scheme datum."
  (should (equal (agent-scheme-version-components) '(0 15 1)))
  (should (equal (agent-scheme-value->external (agent-scheme-version))
                 "(agent-scheme-version 0 15 1)"))
  (should (equal (agent-scheme-version-string) "0.15.1")))

(ert-deftest agent-scheme-runtime-test-version-comes-from-shared-source ()
  "Keep the version number in one Scheme-readable source file."
  (let* ((path (expand-file-name
                agent-scheme-runtime-test--version-source
                agent-scheme--test-root))
         (forms (agent-scheme-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (should
     (string-match-p
      "(define-library (agent-scheme version)"
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))))
    (should
     (string-match-p
      "(export agent-scheme-version-datum)"
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))))
    (should
     (equal (agent-scheme-value->external (agent-scheme-version))
            "(agent-scheme-version 0 15 1)"))
    (should
     (string-match-p
      "single source of truth"
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))))))

(ert-deftest agent-scheme-runtime-test-version-literal-is-not-duplicated ()
  "Keep runtime implementation sources from repeating the version number."
  (let ((canonical (expand-file-name
                    agent-scheme-runtime-test--version-source
                    agent-scheme--test-root))
        matches)
    (dolist (directory '("lisp" "scheme" "fixtures"))
      (dolist (file (directory-files-recursively
                     (expand-file-name directory agent-scheme--test-root)
                     "\\.\\(el\\|scm\\|sld\\)\\'"))
        (unless (equal file canonical)
          (with-temp-buffer
            (insert-file-contents file)
            (when (re-search-forward
                   "\\(agent-scheme-version 0 15 1\\|0\\.15\\.1\\|'(0 15 1\\|(list 0 15 1\\)"
                   nil t)
              (push file matches))))))
    (should-not matches)))

(defun agent-scheme-runtime-test--emacs-command ()
  "Return the current Emacs executable for runtime module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest agent-scheme-runtime-test-records-and-context-live-in-runtime-module ()
  "Load the runtime module and construct its core state records."
  (let ((runtime-library (locate-library "agent-scheme-runtime")))
    (should runtime-library)
    (load runtime-library nil t))
  (should (featurep 'agent-scheme-runtime))
  (let ((environment (agent-scheme-make-empty-environment))
        (child (agent-scheme-make-empty-environment
                (agent-scheme-make-empty-environment))))
    (should (agent-scheme--environment-p environment))
    (should (hash-table-p (agent-scheme--environment-bindings environment)))
    (should-not (agent-scheme--environment-parent environment))
    (should (agent-scheme--environment-parent child)))
  (let ((context (agent-scheme--new-eval-context
                  '(:max-steps 3
                    :max-value-nodes 4
                    :max-host-callbacks 5))))
    (should (agent-scheme--eval-context-p context))
    (should (= (agent-scheme--eval-context-maximum-steps context) 3))
    (should (= (agent-scheme--eval-context-maximum-value-nodes context) 4))
    (should (= (agent-scheme--eval-context-maximum-host-callbacks context) 5))
    (should (hash-table-p (agent-scheme--eval-context-libraries context)))
    (should (agent-scheme--syntax-environment-p
             (agent-scheme--eval-context-syntax-environment context)))
    (dotimes (_ 3)
      (agent-scheme--note-step context))
    (should-error (agent-scheme--note-step context)
                  :type 'agent-scheme-budget-error)))

(ert-deftest agent-scheme-runtime-test-loads-without-evaluator-module ()
  "Load only the runtime module in a fresh Emacs process."
  (let ((output-buffer (generate-new-buffer " *agent-scheme-runtime*")))
    (unwind-protect
        (let ((status
               (process-file
                (agent-scheme-runtime-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" agent-scheme--test-root)
                "--eval"
                "(progn
                   (require 'agent-scheme-runtime)
                   (when (featurep 'agent-scheme-eval)
                     (error \"runtime loaded evaluator\"))
                   (unless (equal (agent-scheme-version-components)
                                  '(0 15 1))
                     (kill-emacs 6))
                   (let ((context
                          (agent-scheme--new-eval-context
                           '(:max-steps 1))))
                     (agent-scheme--note-step context)
                     (condition-case nil
                         (progn
                           (agent-scheme--note-step context)
                           (kill-emacs 3))
                       (agent-scheme-budget-error
                        nil)))
                   (let ((environment
                          (agent-scheme-make-empty-environment)))
                     (agent-scheme--environment-define
                      environment \"answer\" 42)
                     (unless (= (agent-scheme--environment-ref
                                 environment \"answer\")
                                42)
                       (kill-emacs 4))
                     (agent-scheme--environment-set-cell
                      environment \"answer\" 43)
                     (unless (= (agent-scheme--environment-ref
                                 environment \"answer\")
                                43)
                       (kill-emacs 5)))
                   (kill-emacs 0))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; agent-scheme-runtime-test.el ends here
