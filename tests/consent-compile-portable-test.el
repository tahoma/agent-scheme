;;; consent-compile-portable-test.el --- Portable executable compile tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the top-level `make compile' host-compiled portable
;; runtime packaging path.

;;; Code:

(require 'ert)

(defun consent-compile-portable-test--command (env-name fallback)
  "Return ENV-NAME's configured command or FALLBACK from PATH."
  (let ((configured (getenv env-name)))
    (cond
     ((and configured (> (length configured) 0))
      configured)
     (t
      (executable-find fallback)))))

(defun consent-compile-portable-test--repo-file-string (relative-path)
  "Return RELATIVE-PATH from the repository root as a string."
  (with-temp-buffer
    (insert-file-contents (consent--test-target-file relative-path))
    (buffer-string)))

;; Process-global cache of host builds shared by the four full-native-build
;; tests (#556). Each call to `make compile' for the gambit or racket host takes
;; tens of seconds; the runner-smoke and install/dist tests for a given host
;; both exercise the same compiled tree, so the second test in each pair reuses
;; the first one's build instead of rebuilding identical artifacts. Entries are
;; plists with :build-dir, :status, and :output. Cleanup runs once at Emacs
;; exit via `kill-emacs-hook'.
(defvar consent-compile-portable-test--shared-builds
  (make-hash-table :test 'eq)
  "Map of host symbol to a shared build plist.
Keys are `racket' or `gambit'; values are plists with :build-dir, :status, and
:output captured from a single `make compile' run.  Both tests for a host
reuse the cached entry instead of rebuilding.")

(defun consent-compile-portable-test--cleanup-shared-builds ()
  "Delete all shared build directories captured during the session."
  (maphash
   (lambda (_host entry)
     (let ((dir (plist-get entry :build-dir)))
       (when (and dir (file-directory-p dir))
         (ignore-errors (delete-directory dir t)))))
   consent-compile-portable-test--shared-builds)
  (clrhash consent-compile-portable-test--shared-builds))

(add-hook 'kill-emacs-hook
          #'consent-compile-portable-test--cleanup-shared-builds)

(defun consent-compile-portable-test--ensure-shared-build (host)
  "Return the shared build plist for HOST, building once and caching the result.
HOST must be `racket' or `gambit'.  Returns a plist with :build-dir, :status,
and :output.  The first call for HOST runs `make compile' into a fresh temp
directory; subsequent calls return the cached entry verbatim, so the build
status and output assertions stay deterministic across tests."
  (or (gethash host consent-compile-portable-test--shared-builds)
      (let* ((host-name (symbol-name host))
             (build-dir
              (make-temp-file
               (format "consent-compile-shared-%s-" host-name) t))
             (host-args
              (cond
               ((eq host 'racket)
                (list
                 (format "CONSENT_RACKET=%s"
                         (consent-compile-portable-test--command
                          "CONSENT_RACKET" "racket"))
                 (format "CONSENT_RACO=%s"
                         (consent-compile-portable-test--command
                          "CONSENT_RACO" "raco"))))
               ((eq host 'gambit)
                (list
                 (format "CONSENT_GAMBIT=%s"
                         (consent-compile-portable-test--command
                          "CONSENT_GAMBIT" "gsi"))
                 (format "CONSENT_GAMBIT_COMPILER=%s"
                         (consent-compile-portable-test--command
                          "CONSENT_GAMBIT_COMPILER" "gsc"))))
               (t (error "Unknown compile host: %S" host))))
             (result
              (apply #'consent-compile-portable-test--run-make
                     "-s"
                     (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
                     (format "CONSENT_COMPILE_HOST=%s" host-name)
                     (append host-args (list "compile"))))
             (entry
              (list :build-dir build-dir
                    :status (plist-get result :status)
                    :output (plist-get result :output))))
        (puthash host entry consent-compile-portable-test--shared-builds)
        entry)))

(defun consent-compile-portable-test--run-make (&rest arguments)
  "Run make with ARGUMENTS from the repository root.
Return a plist containing :status and :output."
  (let ((buffer (generate-new-buffer " *consent-make-compile-test*")))
    (unwind-protect
        (let ((status
               (let ((default-directory consent--test-root))
                 (apply #'process-file "make" nil buffer nil arguments))))
          (list :status status
                :output
                (with-current-buffer buffer
                  (buffer-string))))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--version-string ()
  "Return the canonical target runtime version as a dotted string."
  (with-temp-buffer
    (insert-file-contents
     (consent--test-target-file "scheme/consent/version.sld"))
    (goto-char (point-min))
    (unless
        (re-search-forward
         "'(consent-version[[:space:]]+\\([0-9]+\\)[[:space:]]+\\([0-9]+\\)[[:space:]]+\\([0-9]+\\))"
         nil
         t)
      (error "Could not read target Consent Scheme version datum"))
    (format "%s.%s.%s"
            (match-string 1)
            (match-string 2)
            (match-string 3))))

(defun consent-compile-portable-test--run-executable
    (program &rest arguments)
  "Run compiled PROGRAM with ARGUMENTS.
Return a plist containing :status and :output."
  (let ((buffer (generate-new-buffer " *consent-compiled-runner-test*")))
    (unwind-protect
        (let ((status
               (let ((default-directory consent--test-root))
                 (apply #'process-file program nil buffer nil arguments))))
          (list :status status
                :output
                (with-current-buffer buffer
                  (buffer-string))))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--run-repl (program input)
  "Run compiled PROGRAM's `--repl' with INPUT fed on standard input.
Return a plist with :status and :output, where :output is the program-output
stream (stdout) only; the interaction record stream (stderr) is discarded so the
assertion covers stream separation as well as the command.  Runs under `--chrome
silent', the chrome whose job is exactly raw program output on stdout: the
default `comment' chrome instead owns program output and renders it on the
control channel, so stdout would be empty there (see the
`(cli repl-chrome)' program-output policy)."
  (let ((in-file (make-temp-file "consent-repl-input-"))
        (err-file (make-temp-file "consent-repl-stderr-"))
        (buffer (generate-new-buffer " *consent-compiled-repl-test*")))
    (unwind-protect
        (progn
          (with-temp-file in-file (insert input))
          (let ((status
                 (let ((default-directory consent--test-root))
                   (process-file program in-file (list buffer err-file) nil
                                 "--repl" "--chrome" "silent"))))
            (list :status status
                  :output
                  (with-current-buffer buffer
                    (buffer-string)))))
      (ignore-errors (delete-file in-file))
      (ignore-errors (delete-file err-file))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--run-repl-control (program input)
  "Run compiled PROGRAM's `--repl' and capture its control-channel stream.
Return a plist with :status and :output, where :output is the stderr record
stream rendered through `--chrome datum'; stdout is discarded."
  (let ((in-file (make-temp-file "consent-repl-input-"))
        (err-file (make-temp-file "consent-repl-stderr-"))
        (buffer (generate-new-buffer " *consent-compiled-repl-control-test*")))
    (unwind-protect
        (progn
          (with-temp-file in-file (insert input))
          (let ((status
                 (let ((default-directory consent--test-root))
                   (process-file program in-file (list buffer err-file) nil
                                 "--repl" "--chrome" "datum"))))
            (list :status status
                  :output
                  (with-temp-buffer
                    (insert-file-contents err-file)
                    (buffer-string)))))
      (ignore-errors (delete-file in-file))
      (ignore-errors (delete-file err-file))
      (kill-buffer buffer))))

(defun consent-compile-portable-test--status (result)
  "Return RESULT's process status."
  (plist-get result :status))

(defun consent-compile-portable-test--output (result)
  "Return RESULT's captured process output."
  (plist-get result :output))

(defun consent-compile-portable-test--assert-gated-script (runner)
  "Assert RUNNER's --script runs through the Consent interpreter, not host load.
A pure script evaluates and exits 0, but an ungranted, confirm-gated file write
is denied and leaves no file -- the discriminator that would fail if --script
regressed to host execution (the host would create the file). Together these are
a positive/negative control: the interpreter selectively gates rather than
failing closed on everything."
  (let ((ok-script (make-temp-file "consent-script-ok-" nil ".scm"))
        (args-script (make-temp-file "consent-script-args-" nil ".scm"))
        (deny-script (make-temp-file "consent-script-deny-" nil ".scm"))
        (deny-marker (make-temp-file "consent-script-marker-" nil ".txt")))
    (delete-file deny-marker)
    (unwind-protect
        (progn
          (with-temp-file ok-script
            (insert "(import (scheme base))\n"
                    "(define (smoke-sq n) (* n n))\n"
                    "(if (not (= (smoke-sq 6) 36))\n"
                    "    (error \"consent --script smoke computed the wrong value\"))\n"))
          (should
           (equal
            (consent-compile-portable-test--status
             (consent-compile-portable-test--run-executable
              runner "--script" ok-script))
            0))
          (with-temp-file args-script
            (insert "(import (scheme base) (scheme process-context))\n"
                    "(define expected\n"
                    (format "  (list %S \"alpha\" \"beta\"))\n" args-script)
                    "(if (not (equal? (command-line) expected))\n"
                    "    (error \"script command-line was not normalized\"\n"
                    "           (command-line)))\n"))
          (should
           (equal
            (consent-compile-portable-test--status
             (consent-compile-portable-test--run-executable
              runner "--script" args-script "alpha" "beta"))
            0))
          (should
           (equal
            (consent-compile-portable-test--status
             (consent-compile-portable-test--run-executable
              runner args-script "alpha" "beta"))
            0))
          (with-temp-file deny-script
            (insert "(import (scheme base) (scheme file))\n"
                    (format "(call-with-output-file %S\n" deny-marker)
                    "  (lambda (port) (write-char #\\x port)))\n"))
          (let ((deny-result
                 (consent-compile-portable-test--run-executable
                  runner "--script" deny-script)))
            (should-not
             (equal (consent-compile-portable-test--status deny-result) 0))
            (should-not (file-exists-p deny-marker))))
      (ignore-errors (delete-file ok-script))
      (ignore-errors (delete-file args-script))
      (ignore-errors (delete-file deny-script))
      (ignore-errors (delete-file deny-marker)))))

(defun consent-compile-portable-test--assert-eval-error-diagnostics (runner)
  "Assert RUNNER's `--eval' surfaces the underlying error message."
  (let ((result
         (consent-compile-portable-test--run-executable
          runner
          "--eval"
          "(error \"boom\")")))
    (should-not
     (equal (consent-compile-portable-test--status result) 0))
    (should
     (string-match-p
      (regexp-quote "boom")
      (consent-compile-portable-test--output result)))
    (should-not
     (string-match-p
     (regexp-quote "#<error-exception")
      (consent-compile-portable-test--output result)))))

(defun consent-compile-portable-test--assert-host-run-timeout-option-diagnostics
    (runner)
  "Assert RUNNER's `--host-run' preserves numeric transport options."
  (let ((probe-script (make-temp-file "consent-timeout-option-probe-" nil ".scm")))
    (unwind-protect
        (progn
          (with-temp-file probe-script
            (insert
             "(import (scheme base)\n"
             "        (scheme write)\n"
             "        (agent models openai))\n"
             "(write\n"
             " (model-openai-compatible-http-completion-result\n"
             "  '(model-provider\n"
             "    (id local-fail)\n"
             "    (kind local)\n"
             "    (transport openai-compatible-http)\n"
             "    (endpoint \"http://127.0.0.1:1/v1\"))\n"
             "  '((id qwen-coder)\n"
             "    (roles (scheme-scripter))\n"
             "    (privacy local))\n"
             "  'scheme-scripter\n"
             "  \"transport diagnostic prompt\"\n"
             "  '((timeout-seconds 7)\n"
             "    (retry-count 1)\n"
             "    (max-transport-detail-bytes 320))))\n"
             "(newline)\n"))
          (let ((result
                 (consent-compile-portable-test--run-executable
                  runner "--host-run" probe-script)))
            (should
             (equal (consent-compile-portable-test--status result) 0))
            (should
             (string-match-p
              (regexp-quote "(timeout-seconds 7)")
              (consent-compile-portable-test--output result)))
            (should
             (string-match-p
              (regexp-quote "(retry-count 1)")
              (consent-compile-portable-test--output result)))
            (should
             (string-match-p
              (regexp-quote "(max-transport-detail-bytes 320)")
              (consent-compile-portable-test--output result)))
            (should-not
             (string-match-p
              (regexp-quote "(timeout-seconds 30)")
              (consent-compile-portable-test--output result)))))
      (ignore-errors (delete-file probe-script)))))

(defun consent-compile-portable-test--assert-repl-timeout-option-diagnostics
    (runner)
  "Assert RUNNER's `--repl' preserves numeric transport options."
  (let ((result
         (consent-compile-portable-test--run-repl-control
          runner
          (concat
           "(import (scheme base) (agent models openai))\n"
           "(model-openai-compatible-http-completion-result\n"
           "  '(model-provider\n"
           "    (id local-fail)\n"
           "    (kind local)\n"
           "    (transport openai-compatible-http)\n"
           "    (endpoint \"http://127.0.0.1:1/v1\"))\n"
           "  '((id qwen-coder)\n"
           "    (roles (scheme-scripter))\n"
           "    (privacy local))\n"
           "  'scheme-scripter\n"
           "  \"transport diagnostic prompt\"\n"
           "  '((timeout-seconds 7)\n"
           "    (retry-count 1)\n"
           "    (max-transport-detail-bytes 320)))\n"
           "(exit)\n"))))
    (should
     (equal (consent-compile-portable-test--status result) 0))
    (should
     (string-match-p
      (regexp-quote "(timeout-seconds 7)")
      (consent-compile-portable-test--output result)))
    (should
     (string-match-p
      (regexp-quote "(retry-count 1)")
      (consent-compile-portable-test--output result)))
    (should
     (string-match-p
      (regexp-quote "(max-transport-detail-bytes 320)")
      (consent-compile-portable-test--output result)))
    (should-not
     (string-match-p
      (regexp-quote "(timeout-seconds 30)")
      (consent-compile-portable-test--output result)))))

(ert-deftest consent-compile-portable-test-rejects-unknown-host ()
  "Reject unknown compile hosts with an actionable setup message."
  (let* ((build-dir
          (make-temp-file "consent-compile-unknown-host-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           "CONSENT_COMPILE_HOST=bogus"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (consent-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "CONSENT_COMPILE_HOST must be one of: racket, gambit"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest consent-compile-portable-test-gambit-links-stdlib-dependencies ()
  "Link source-backed stdlib dependencies into the Gambit runner."
  (let* ((script
          (consent-compile-portable-test--repo-file-string
           "tools/compile-portable.sh"))
         (gambit-main-start
          (string-match "write_gambit_main_common()" script))
         (gambit-main-end
          (and gambit-main-start
               (string-match "write_gambit_main()" script gambit-main-start)))
         (gambit-main
          (and gambit-main-start
               gambit-main-end
               (substring script gambit-main-start gambit-main-end))))
    (should gambit-main)
    (should
     (string-match-p
      "(prefix (stdlib and-let-star) consent-main:stdlib-and-let-star:)"
      gambit-main))
    (should
     (string-match-p
      "(prefix (stdlib list) consent-main:stdlib-list:)"
      gambit-main))
    (should
     (string-match-p
      "(prefix (stdlib generator) consent-main:stdlib-generator:)"
      gambit-main))
    (should
     (string-match-p
      "(prefix (stdlib receive) consent-main:stdlib-receive:)"
      gambit-main))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/and-let-star\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/receive\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/list\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/generator\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/comparator\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/assume\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/rbtree\\.sld\""
      script))
    (should
     (string-match-p
      "\"\\$scheme_dir/stdlib/mapping\\.sld\""
      script))
    (should
     (string-match-p
      "gambit_module_order='[^']*stdlib/and-let-star[[:space:]]+stdlib/list[[:space:]]+stdlib/generator[[:space:]]+stdlib/comparator[[:space:]]+stdlib/receive[[:space:]]+stdlib/assume[[:space:]]+stdlib/rbtree[[:space:]]+stdlib/mapping[[:space:]]+stdlib/json"
      script))))

(ert-deftest consent-compile-portable-test-racket-builds-runner ()
  "Build a Racket-hosted portable executable and run smoke commands."
  (let ((racket
         (consent-compile-portable-test--command
          "CONSENT_RACKET" "racket"))
        (raco
         (consent-compile-portable-test--command
          "CONSENT_RACO" "raco")))
    (unless (and racket raco)
      (ert-skip "Racket and raco are not available"))
    (let* ((entry
            (consent-compile-portable-test--ensure-shared-build 'racket))
           (build-dir (plist-get entry :build-dir))
           (host-root (expand-file-name "racket" build-dir))
           (runner (expand-file-name "bin/consent" host-root))
           (manifest (expand-file-name "manifest.scm" host-root))
           (smoke-log (expand-file-name "logs/smoke.log" host-root))
           (version-string
            (consent-compile-portable-test--version-string)))
      (should (equal (plist-get entry :status) 0))
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
        (consent-compile-portable-test--run-executable
         runner "--version")
        (list :status 0
              :output (format "Consent Scheme %s\n" version-string))))
      (should
       (equal
        (consent-compile-portable-test--run-executable
         runner "--eval" "(+ 1 2)")
        '(:status 0 :output "3\n")))
      (consent-compile-portable-test--assert-eval-error-diagnostics runner)
      (consent-compile-portable-test--assert-host-run-timeout-option-diagnostics
       runner)
      (consent-compile-portable-test--assert-repl-timeout-option-diagnostics
       runner)
      (consent-compile-portable-test--assert-gated-script runner)
      (should
       (equal
        (consent-compile-portable-test--run-repl
         runner
         (concat "(import (scheme base) (scheme write))\n"
                 "(display \"ok\")(newline)\n"
                 "(exit)\n"))
        '(:status 0 :output "ok\n"))))))

(ert-deftest consent-compile-portable-test-racket-missing-tools-fail ()
  "Fail explicit Racket compile requests with setup guidance."
  (let* ((build-dir
          (make-temp-file "consent-compile-missing-racket-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           "CONSENT_COMPILE_HOST=racket"
           "CONSENT_RACKET=/no/such/racket"
           "CONSENT_RACO=/no/such/raco"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (consent-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "Racket compile prerequisites are missing"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest consent-compile-portable-test-gambit-missing-tools-fail ()
  "Fail explicit Gambit compile requests with setup guidance."
  (let* ((build-dir
          (make-temp-file "consent-compile-missing-gambit-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           "CONSENT_COMPILE_HOST=gambit"
           "CONSENT_GAMBIT=/no/such/gsi"
           "CONSENT_GAMBIT_COMPILER=/no/such/gsc"
           "compile")))
    (unwind-protect
        (progn
          (should-not (equal (consent-compile-portable-test--status result)
                             0))
          (should
           (string-match-p
            "Gambit compile prerequisites are missing"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t)))))

(ert-deftest consent-compile-portable-test-gambit-builds-runner ()
  "Build a Gambit-hosted portable executable and run smoke commands."
  (let ((gsi
         (consent-compile-portable-test--command
          "CONSENT_GAMBIT" "gsi"))
        (gsc
         (consent-compile-portable-test--command
          "CONSENT_GAMBIT_COMPILER" "gsc")))
    (unless (and gsi gsc)
      (ert-skip "Gambit gsi and gsc are not available"))
    (let* ((entry
            (consent-compile-portable-test--ensure-shared-build 'gambit))
           (build-dir (plist-get entry :build-dir))
           (host-root (expand-file-name "gambit" build-dir))
           (runner (expand-file-name "bin/consent" host-root))
           (manifest (expand-file-name "manifest.scm" host-root))
           (smoke-log (expand-file-name "logs/smoke.log" host-root))
           (version-string
            (consent-compile-portable-test--version-string)))
      (should (equal (plist-get entry :status) 0))
      (should (file-executable-p runner))
      (should (file-exists-p manifest))
      (should (file-exists-p smoke-log))
      (should
       (file-directory-p
        (expand-file-name "src" host-root)))
      (should
       (string-match-p
        "(compile-host gambit)"
        (with-temp-buffer
          (insert-file-contents manifest)
          (buffer-string))))
      (should
       (equal
        (consent-compile-portable-test--run-executable
         runner "--version")
        (list :status 0
              :output (format "Consent Scheme %s\n" version-string))))
      (should
       (equal
        (consent-compile-portable-test--run-executable
         runner "--eval" "(+ 1 2)")
        '(:status 0 :output "3\n")))
      (consent-compile-portable-test--assert-eval-error-diagnostics runner)
      (consent-compile-portable-test--assert-host-run-timeout-option-diagnostics
       runner)
      (consent-compile-portable-test--assert-repl-timeout-option-diagnostics
       runner)
      (consent-compile-portable-test--assert-gated-script runner)
      (should
       (equal
        (consent-compile-portable-test--run-repl
         runner
         (concat "(import (scheme base) (scheme write))\n"
                 "(display \"ok\")(newline)\n"
                 "(exit)\n"))
        '(:status 0 :output "ok\n"))))))

(defun consent-compile-portable-test--exercise-distribution (host build-dir)
  "Exercise `make install', `uninstall', and `dist' for HOST.
BUILD-DIR holds a freshly built executable under HOST.  Stages an install into
a throwaway DESTDIR without writing to the real system, round-trips the man-page
and binary install, uninstalls, and packages a versioned tarball."
  (let* ((version-string (consent-compile-portable-test--version-string))
         (dest-dir (make-temp-file "consent-install-dest-" t))
         (man-file (make-temp-file "consent-man-" nil ".1"))
         (staged-bin (expand-file-name "usr/local/bin/consent" dest-dir))
         (staged-man
          (expand-file-name "usr/local/share/man/man1/consent.1" dest-dir)))
    (unwind-protect
        (progn
          (with-temp-file man-file (insert ".TH CONSENT 1\n"))
          ;; Install with no man page: succeeds, prints the skip notice, stages
          ;; an executable binary whose --version matches version.sld.
          (let ((result
                 (consent-compile-portable-test--run-make
                  "-s"
                  (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
                  (format "CONSENT_COMPILE_HOST=%s" host)
                  (format "DESTDIR=%s" dest-dir)
                  "CONSENT_MANPAGE=/no/such/consent.1"
                  "install")))
            (should (equal (consent-compile-portable-test--status result) 0))
            (should
             (string-match-p
              "no man page"
              (consent-compile-portable-test--output result)))
            (should (file-executable-p staged-bin))
            (should-not (file-exists-p staged-man))
            (should
             (equal
              (consent-compile-portable-test--run-executable
               staged-bin "--version")
              (list :status 0
                    :output (format "Consent Scheme %s\n" version-string)))))
          ;; Install with a man page present: stages the page alongside.
          (let ((result
                 (consent-compile-portable-test--run-make
                  "-s"
                  (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
                  (format "CONSENT_COMPILE_HOST=%s" host)
                  (format "DESTDIR=%s" dest-dir)
                  (format "CONSENT_MANPAGE=%s" man-file)
                  "install")))
            (should (equal (consent-compile-portable-test--status result) 0))
            (should (file-exists-p staged-man)))
          ;; Uninstall removes exactly the staged paths and is idempotent.
          (let ((result
                 (consent-compile-portable-test--run-make
                  "-s"
                  (format "CONSENT_COMPILE_HOST=%s" host)
                  (format "DESTDIR=%s" dest-dir)
                  "uninstall")))
            (should (equal (consent-compile-portable-test--status result) 0))
            (should-not (file-exists-p staged-bin))
            (should-not (file-exists-p staged-man)))
          ;; Package a versioned tarball carrying the expected members.
          (let* ((dist-dir (make-temp-file "consent-dist-" t))
                 (result
                  (consent-compile-portable-test--run-make
                   "-s"
                   (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
                   (format "CONSENT_COMPILE_HOST=%s" host)
                   (format "CONSENT_DIST_DIR=%s" dist-dir)
                   "dist"))
                 (stem (format "consent-%s-%s" version-string host))
                 (tarball
                  (expand-file-name (format "%s.tar.gz" stem) dist-dir)))
            (unwind-protect
                (progn
                  (should
                   (equal (consent-compile-portable-test--status result) 0))
                  (should (file-exists-p tarball))
                  (let ((listing
                         (consent-compile-portable-test--run-executable
                          "tar" "-tzf" tarball)))
                    (should
                     (equal
                      (consent-compile-portable-test--status listing) 0))
                    (dolist (member
                             (list (format "%s/bin/consent" stem)
                                   (format "%s/manifest.scm" stem)
                                   (format "%s/README.md" stem)
                                   (format "%s/LICENSE" stem)))
                      (should
                       (string-match-p
                        (regexp-quote member)
                        (consent-compile-portable-test--output listing))))))
              (when (file-directory-p dist-dir)
                (delete-directory dist-dir t)))))
      (ignore-errors (delete-file man-file))
      (when (file-directory-p dest-dir)
        (delete-directory dest-dir t)))))

(ert-deftest consent-compile-portable-test-install-without-binary-fails ()
  "Fail `make install' with setup guidance when no binary has been built."
  (let* ((build-dir
          (make-temp-file "consent-install-missing-" t))
         (dest-dir
          (make-temp-file "consent-install-missing-dest-" t))
         (result
          (consent-compile-portable-test--run-make
           "-s"
           (format "CONSENT_COMPILE_BUILD_DIR=%s" build-dir)
           (format "DESTDIR=%s" dest-dir)
           "install")))
    (unwind-protect
        (progn
          (should (equal (consent-compile-portable-test--status result) 2))
          (should
           (string-match-p
            "no compiled binary"
            (consent-compile-portable-test--output result)))
          (should
           (string-match-p
            "make compile"
            (consent-compile-portable-test--output result))))
      (when (file-directory-p build-dir)
        (delete-directory build-dir t))
      (when (file-directory-p dest-dir)
        (delete-directory dest-dir t)))))

(ert-deftest consent-compile-portable-test-racket-install-and-dist ()
  "Install, uninstall, and package a Racket-hosted binary."
  (let ((racket
         (consent-compile-portable-test--command
          "CONSENT_RACKET" "racket"))
        (raco
         (consent-compile-portable-test--command
          "CONSENT_RACO" "raco")))
    (unless (and racket raco)
      (ert-skip "Racket and raco are not available"))
    (let* ((entry
            (consent-compile-portable-test--ensure-shared-build 'racket))
           (build-dir (plist-get entry :build-dir)))
      (should (equal (plist-get entry :status) 0))
      (consent-compile-portable-test--exercise-distribution
       "racket" build-dir))))

(ert-deftest consent-compile-portable-test-gambit-install-and-dist ()
  "Install, uninstall, and package a Gambit-hosted binary."
  (let ((gsi
         (consent-compile-portable-test--command
          "CONSENT_GAMBIT" "gsi"))
        (gsc
         (consent-compile-portable-test--command
          "CONSENT_GAMBIT_COMPILER" "gsc")))
    (unless (and gsi gsc)
      (ert-skip "Gambit gsi and gsc are not available"))
    (let* ((entry
            (consent-compile-portable-test--ensure-shared-build 'gambit))
           (build-dir (plist-get entry :build-dir)))
      (should (equal (plist-get entry :status) 0))
      (consent-compile-portable-test--exercise-distribution
       "gambit" build-dir))))

(provide 'consent-compile-portable-test)

;;; consent-compile-portable-test.el ends here
