;;; agent-scheme-compile-portable-test.el --- Portable executable compile tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the top-level `make compile' host-compiled portable
;; runtime packaging path.

;;; Code:

(require 'ert)

(defun agent-scheme-compile-portable-test--command (env-name fallback)
  "Return ENV-NAME's configured command or FALLBACK from PATH."
  (let ((configured (getenv env-name)))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find fallback)))))

(defun agent-scheme-compile-portable-test--run-make (&rest arguments)
  "Run make with ARGUMENTS from the repository root.
Return a plist containing :status and :output."
  (let ((buffer (generate-new-buffer " *agent-scheme-make-compile-test*")))
    (unwind-protect
        (let ((status
               (let ((default-directory agent-scheme--test-root))
                 (apply #'process-file "make" nil buffer nil arguments))))
          (list :status status
                :output
                (with-current-buffer buffer
                  (buffer-string))))
      (kill-buffer buffer))))

(defun agent-scheme-compile-portable-test--version-string ()
  "Return the canonical target runtime version as a dotted string."
  (with-temp-buffer
    (insert-file-contents
     (agent-scheme--test-target-file "scheme/agent-scheme/version.sld"))
    (goto-char (point-min))
    (unless
        (re-search-forward
         "'(agent-scheme-version[[:space:]]+\\([0-9]+\\)[[:space:]]+\\([0-9]+\\)[[:space:]]+\\([0-9]+\\))"
         nil
         t)
      (error "Could not read target Agent Scheme version datum"))
    (format "%s.%s.%s"
            (match-string 1)
            (match-string 2)
            (match-string 3))))

(defun agent-scheme-compile-portable-test--run-executable
    (program &rest arguments)
  "Run compiled PROGRAM with ARGUMENTS.
Return a plist containing :status and :output."
  (let ((buffer (generate-new-buffer " *agent-scheme-compiled-runner-test*")))
    (unwind-protect
        (let ((status
               (let ((default-directory agent-scheme--test-root))
                 (apply #'process-file program nil buffer nil arguments))))
          (list :status status
                :output
                (with-current-buffer buffer
                  (buffer-string))))
      (kill-buffer buffer))))

(defun agent-scheme-compile-portable-test--status (result)
  "Return RESULT's process status."
  (plist-get result :status))

(defun agent-scheme-compile-portable-test--output (result)
  "Return RESULT's captured process output."
  (plist-get result :output))

(ert-deftest agent-scheme-compile-portable-test-rejects-unknown-host ()
  "Reject unknown compile hosts with an actionable setup message."
  (let* ((build-dir
          (make-temp-file "agent-scheme-compile-unknown-host-" t))
         (result
          (agent-scheme-compile-portable-test--run-make
           "-s"
           (format "AGENT_SCHEME_COMPILE_BUILD_DIR=%s" build-dir)
           "AGENT_SCHEME_COMPILE_HOST=bogus"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (agent-scheme-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "AGENT_SCHEME_COMPILE_HOST must be one of: racket, gambit"
            (agent-scheme-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest agent-scheme-compile-portable-test-racket-builds-runner ()
  "Build a Racket-hosted portable executable and run smoke commands."
  (let ((racket
         (agent-scheme-compile-portable-test--command
          "AGENT_SCHEME_RACKET" "racket"))
        (raco
         (agent-scheme-compile-portable-test--command
          "AGENT_SCHEME_RACO" "raco")))
    (unless (and racket raco)
      (ert-skip "Racket and raco are not available"))
    (let* ((build-dir
            (make-temp-file "agent-scheme-compile-racket-" t))
           (result
            (agent-scheme-compile-portable-test--run-make
             "-s"
             (format "AGENT_SCHEME_COMPILE_BUILD_DIR=%s" build-dir)
             "AGENT_SCHEME_COMPILE_HOST=racket"
             (format "AGENT_SCHEME_RACKET=%s" racket)
             (format "AGENT_SCHEME_RACO=%s" raco)
             "compile"))
           (host-root (expand-file-name "racket" build-dir))
           (runner (expand-file-name "bin/agent-scheme" host-root))
           (manifest (expand-file-name "manifest.scm" host-root))
           (smoke-log (expand-file-name "logs/smoke.log" host-root))
           (version-string
            (agent-scheme-compile-portable-test--version-string)))
      (unwind-protect
          (progn
            (should
             (equal (agent-scheme-compile-portable-test--status result) 0))
            (should (file-executable-p runner))
            (should (file-exists-p manifest))
            (should (file-exists-p smoke-log))
            (should
             (string-match-p
              "(compile-host racket)"
              (with-temp-buffer
                (insert-file-contents manifest)
                (buffer-string))))
            (should
             (equal
              (agent-scheme-compile-portable-test--run-executable
               runner "--version")
              (list :status 0
                    :output (format "Agent Scheme %s\n" version-string))))
            (should
             (equal
              (agent-scheme-compile-portable-test--run-executable
               runner "--eval" "(+ 1 2)")
              '(:status 0 :output "3\n")))
            (should
             (equal
              (agent-scheme-compile-portable-test--run-executable
               runner "--script" "tests/scheme/agent-scheme-reader-test.scm")
              '(:status 0 :output "Scheme reader tests passed\n"))))
        (when (file-directory-p build-dir)
          (delete-directory build-dir t))))))

(ert-deftest agent-scheme-compile-portable-test-racket-missing-tools-fail ()
  "Fail explicit Racket compile requests with setup guidance."
  (let* ((build-dir
          (make-temp-file "agent-scheme-compile-missing-racket-" t))
         (result
          (agent-scheme-compile-portable-test--run-make
           "-s"
           (format "AGENT_SCHEME_COMPILE_BUILD_DIR=%s" build-dir)
           "AGENT_SCHEME_COMPILE_HOST=racket"
           "AGENT_SCHEME_RACKET=/no/such/racket"
           "AGENT_SCHEME_RACO=/no/such/raco"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (agent-scheme-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "Racket compile prerequisites are missing"
            (agent-scheme-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(provide 'agent-scheme-compile-portable-test)

;;; agent-scheme-compile-portable-test.el ends here
