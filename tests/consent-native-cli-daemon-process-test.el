;;; consent-native-cli-daemon-process-test.el --- Native CLI process-boundary tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT process-boundary lane for the native CLI and daemon host adapter contract
;; (docs/native-cli-daemon-adapter.md, fixture
;; fixtures/host-adapters/native-cli-daemon.scm).
;;
;; The portable validator (tests/scheme/consent-native-cli-daemon-adapter-test.scm)
;; checks the static record shapes, and the mock adapter lane
;; (tests/consent-native-cli-daemon-mock-test.el) drives a deterministic
;; in-process mock that never starts a real process.  This lane is the
;; `(process-boundary-suite native-cli)' lane named in the fixture: it runs the
;; real native CLI entrypoint (tools/consent-native-cli, tools/consent-native-cli.el)
;; as a child OS process and asserts on the Scheme-readable records the adapter
;; emits after it spawns, streams, waits for, signals, and reaps a real child
;; process.
;;
;; The deftests are named `consent-native-cli-daemon-process-...' so the
;; `consent-native-cli-daemon.*' Emacs tools shard selector runs them through
;; `make test'.  A narrower invocation is documented in
;; docs/native-cli-daemon-adapter.md.
;;
;; The harness asserts the contract invariants:
;;
;; - a real process boundary streams stdout, stderr, and exit status;
;; - a host-backed stdin port reaches a child while the approval prompt is
;;   written only to the adapter's stderr, so the prompt never consumes the
;;   stdin stream;
;; - noninteractive confirmation, stale job handles, and denied stdin ports fail
;;   closed with Scheme-readable audit and error records before any host
;;   operation runs;
;; - interpreted and future compiled execution share one record shape.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'consent-reader)

;;;; Entrypoint invocation

(defconst consent-native-cli-daemon-process--entrypoint
  "tools/consent-native-cli"
  "Repository-relative path to the native CLI process-boundary entrypoint.")

(defun consent-native-cli-daemon-process--emacs ()
  "Return the Emacs binary running this harness, for the child entrypoint."
  (expand-file-name (or invocation-name "emacs") invocation-directory))

(defun consent-native-cli-daemon-process--run (args &optional stdin-file)
  "Run the native CLI entrypoint with ARGS and return an outcome plist.
ARGS is a list of strings.  STDIN-FILE, when non-nil, is delivered as the
entrypoint's own stdin.  The plist carries `:exit', `:records' (the parsed
stdout datum stream), `:stdout', and `:stderr'."
  (let* ((entrypoint (expand-file-name
                      consent-native-cli-daemon-process--entrypoint
                      consent--test-root))
         (stderr-file (make-temp-file "consent-native-cli-process-stderr"))
         (process-environment
          (cons (format "CONSENT_EMACS=%s"
                        (consent-native-cli-daemon-process--emacs))
                process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (apply #'call-process entrypoint stdin-file
                              (list (current-buffer) stderr-file) nil args))
                 (stdout (buffer-string))
                 (stderr (with-temp-buffer
                           (insert-file-contents stderr-file)
                           (buffer-string)))
                 (records (condition-case err
                              (consent-read-all stdout)
                            (error
                             (ert-fail
                              (format "unreadable record stream: %S\nstdout:\n%s\nstderr:\n%s"
                                      err stdout stderr))))))
            (list :exit exit :records records :stdout stdout :stderr stderr)))
      (ignore-errors (delete-file stderr-file)))))

;;;; Datum navigation

(defun consent-native-cli-daemon-process--name (value)
  "Return VALUE as a stable identifier name string, or nil."
  (cond
   ((consent-symbol-p value) (consent-symbol-name value))
   ((stringp value) value)
   ((symbolp value) (and value (symbol-name value)))
   (t nil)))

(defun consent-native-cli-daemon-process--named-p (datum name)
  "Return non-nil when DATUM is a list whose head identifier is NAME."
  (and (consp datum)
       (equal (consent-native-cli-daemon-process--name (car datum)) name)))

(defun consent-native-cli-daemon-process--field (record name)
  "Return RECORD's field named NAME, or nil."
  (if (consent-native-cli-daemon-process--named-p record name)
      record
    (let ((fields (if (consp (car-safe record)) record (cdr-safe record))))
      (seq-find (lambda (field)
                  (consent-native-cli-daemon-process--named-p field name))
                fields))))

(defun consent-native-cli-daemon-process--field-value (record name)
  "Return the first value of RECORD's field named NAME, or nil."
  (cadr (consent-native-cli-daemon-process--field record name)))

(defun consent-native-cli-daemon-process--integer (value)
  "Return VALUE as an Emacs integer, unwrapping a `consent-number' reader datum."
  (if (consent-number-p value) (consent-number-value value) value))

(defun consent-native-cli-daemon-process--records-of (records kind)
  "Return every datum in RECORDS whose head identifier is KIND."
  (seq-filter (lambda (record)
                (consent-native-cli-daemon-process--named-p record kind))
              records))

(defun consent-native-cli-daemon-process--record-of (records kind)
  "Return the first datum in RECORDS whose head identifier is KIND, or nil."
  (car (consent-native-cli-daemon-process--records-of records kind)))

(defun consent-native-cli-daemon-process--event-of-kind (records kind)
  "Return the first adapter-event in RECORDS whose `kind' field is KIND."
  (seq-find
   (lambda (event)
     (equal (consent-native-cli-daemon-process--name
             (consent-native-cli-daemon-process--field-value event "kind"))
            kind))
   (consent-native-cli-daemon-process--records-of records "adapter-event")))

;; Scheme-readability of the whole record stream is established structurally:
;; `consent-native-cli-daemon-process--run' parses the entrypoint's stdout with
;; `consent-read-all', which validates every datum, so a record present in
;; `:records' is by construction a datum the Consent reader accepted.

;;;; Fixture vocabulary

(defvar consent-native-cli-daemon-process--fixture-cache nil
  "Cached parsed native CLI and daemon adapter fixture datum.")

(defun consent-native-cli-daemon-process--fixture ()
  "Return the parsed native CLI and daemon adapter fixture datum."
  (or consent-native-cli-daemon-process--fixture-cache
      (setq consent-native-cli-daemon-process--fixture-cache
            (car (consent-read-all
                  (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name
                      "fixtures/host-adapters/native-cli-daemon.scm"
                      consent--test-root))
                    (buffer-string)))))))

(defun consent-native-cli-daemon-process--adapter ()
  "Return the adapter declaration section of the fixture."
  (consent-native-cli-daemon-process--field-value
   (consent-native-cli-daemon-process--fixture) "adapter"))

(defun consent-native-cli-daemon-process--vocabulary (field)
  "Return the adapter declaration FIELD's identifier names."
  (mapcar #'consent-native-cli-daemon-process--name
          (consent-native-cli-daemon-process--field-value
           (consent-native-cli-daemon-process--adapter) field)))

;;;; Tests: real process boundary streaming

(ert-deftest consent-native-cli-daemon-process-test-spawn-stdout-wait-exit ()
  "An approved spawn streams child stdout and a zero exit status."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-run" "--mode" "cli" "--terminal"
                     "--command" "/bin/echo" "--arg" "harness-stdout")))
         (records (plist-get outcome :records))
         (decision (consent-native-cli-daemon-process--record-of
                    records "capability-decision"))
         (stdout-event (consent-native-cli-daemon-process--event-of-kind
                        records "stdout"))
         (exit-event (consent-native-cli-daemon-process--event-of-kind
                      records "process-exit")))
    (should (= (plist-get outcome :exit) 0))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     decision "status"))
                   "approved"))
    (should stdout-event)
    (should (string-match-p
             "harness-stdout"
             (consent-native-cli-daemon-process--field-value
              stdout-event "payload")))
    (should (equal (consent-native-cli-daemon-process--integer
                    (consent-native-cli-daemon-process--field-value
                     (consent-native-cli-daemon-process--field-value
                      exit-event "payload")
                     "exit-status"))
                   0))
    ;; The adapter recorded a result and an audit for the performed host op.
    (should (consent-native-cli-daemon-process--record-of records "adapter-result"))
    (should (consent-native-cli-daemon-process--record-of records "adapter-audit"))))

(ert-deftest consent-native-cli-daemon-process-test-stderr-stream ()
  "Child stderr is streamed as a Scheme-readable stderr event."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-run" "--mode" "batch" "--approval"
                     "--command" "sh" "--arg" "-c"
                     "--arg" "echo harness-stderr 1>&2")))
         (records (plist-get outcome :records))
         (stderr-event (consent-native-cli-daemon-process--event-of-kind
                        records "stderr")))
    (should stderr-event)
    (should (string-match-p
             "harness-stderr"
             (consent-native-cli-daemon-process--field-value
              stderr-event "payload")))
    ;; The child's stderr is captured into the record stream, not echoed onto
    ;; the adapter's own stderr (the approval prompt channel).
    (should-not (string-match-p "harness-stderr" (plist-get outcome :stderr)))))

(ert-deftest consent-native-cli-daemon-process-test-nonzero-exit-status ()
  "The adapter waits for and records a nonzero child exit status."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-run" "--mode" "batch" "--approval"
                     "--command" "sh" "--arg" "-c" "--arg" "exit 7")))
         (records (plist-get outcome :records))
         (exit-event (consent-native-cli-daemon-process--event-of-kind
                      records "process-exit")))
    (should exit-event)
    (should (equal (consent-native-cli-daemon-process--integer
                    (consent-native-cli-daemon-process--field-value
                     (consent-native-cli-daemon-process--field-value
                      exit-event "payload")
                     "exit-status"))
                   7))))

(ert-deftest consent-native-cli-daemon-process-test-stdin-port-does-not-consume-prompt ()
  "A host-backed stdin port reaches the child while the prompt stays on stderr."
  (let* ((payload "stdin-port-payload")
         (stdin-file (make-temp-file "consent-native-cli-process-stdin")))
    (unwind-protect
        (progn
          (with-temp-file stdin-file (insert payload "\n"))
          (let* ((outcome (consent-native-cli-daemon-process--run
                           (list "process-run" "--mode" "cli" "--terminal"
                                 "--command" "cat" "--stdin-file" stdin-file)
                           stdin-file))
                 (records (plist-get outcome :records))
                 (stdout-event (consent-native-cli-daemon-process--event-of-kind
                                records "stdout")))
            ;; The child saw the entire stdin port payload...
            (should stdout-event)
            (should (string-match-p
                     payload
                     (consent-native-cli-daemon-process--field-value
                      stdout-event "payload")))
            ;; ...while the approval prompt was rendered only on the adapter's
            ;; stderr, so the prompt never consumed the stdin stream.
            (should (string-match-p "approval" (plist-get outcome :stderr)))
            ;; The stdin payload reaches the child only; it never appears on the
            ;; adapter's prompt channel.
            (should-not (string-match-p payload (plist-get outcome :stderr)))))
      (ignore-errors (delete-file stdin-file)))))

;;;; Tests: cwd and environment grants in a child

(ert-deftest consent-native-cli-daemon-process-test-cwd-grant-in-child ()
  "A granted cwd is observed by a real child process."
  (let ((dir (file-name-as-directory (make-temp-file "consent-native-cli-cwd" t))))
    (unwind-protect
        (let* ((outcome (consent-native-cli-daemon-process--run
                         (list "process-run" "--mode" "batch" "--approval"
                               "--cwd" dir "--command" "pwd")))
               (records (plist-get outcome :records))
               (stdout-event (consent-native-cli-daemon-process--event-of-kind
                              records "stdout"))
               (observed (string-trim
                          (consent-native-cli-daemon-process--field-value
                           stdout-event "payload"))))
          ;; The child's working directory is the granted directory (compared by
          ;; true name so macOS /var symlinks do not cause spurious mismatches).
          (should (equal (file-truename (file-name-as-directory observed))
                         (file-truename dir)))
          ;; The grant is recorded in the request resource.
          (should (consent-native-cli-daemon-process--field
                   (consent-native-cli-daemon-process--field
                    (consent-native-cli-daemon-process--record-of
                     records "capability-request")
                    "resource")
                   "cwd")))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest consent-native-cli-daemon-process-test-environment-grant-in-child ()
  "A granted environment variable is observed by a real child process."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-run" "--mode" "batch" "--approval"
                     "--env" "CONSENT_GRANT=granted-value"
                     "--command" "sh" "--arg" "-c"
                     "--arg" "printf %s \"$CONSENT_GRANT\"")))
         (records (plist-get outcome :records))
         (stdout-event (consent-native-cli-daemon-process--event-of-kind
                        records "stdout")))
    (should (equal (consent-native-cli-daemon-process--field-value
                    stdout-event "payload")
                   "granted-value"))
    ;; The grant is recorded in the request resource environment field.
    (should (consent-native-cli-daemon-process--field
             (consent-native-cli-daemon-process--field
              (consent-native-cli-daemon-process--record-of
               records "capability-request")
              "resource")
             "environment"))))

;;;; Tests: signal and reap a real child

(ert-deftest consent-native-cli-daemon-process-test-signal-and-reap ()
  "An approved signal terminates and reaps a real long-lived child."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-signal" "--mode" "cli" "--terminal"
                     "--job-id" "h-job-sig" "--signal" "TERM")))
         (records (plist-get outcome :records))
         (exit-event (consent-native-cli-daemon-process--event-of-kind
                      records "process-exit")))
    (should (= (plist-get outcome :exit) 0))
    (should exit-event)
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     (consent-native-cli-daemon-process--field-value
                      exit-event "payload")
                     "signal"))
                   "TERM"))
    (should (consent-native-cli-daemon-process--record-of records "adapter-result"))))

;;;; Tests: denials fail closed before any host operation

(ert-deftest consent-native-cli-daemon-process-test-batch-noninteractive-denial ()
  "Batch confirmation fails closed with audit and error, and runs no host op."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-run" "--mode" "batch"
                     "--command" "/bin/echo" "--arg" "should-not-run")))
         (records (plist-get outcome :records))
         (decision (consent-native-cli-daemon-process--record-of
                    records "capability-decision"))
         (error-datum (consent-native-cli-daemon-process--record-of
                       records "adapter-error")))
    (should (= (plist-get outcome :exit) 3))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     decision "status"))
                   "denied"))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     error-datum "kind"))
                   "noninteractive-confirmation-unavailable"))
    ;; The denial is audited and no host operation ran: no result record and no
    ;; child-output event mean the child never spawned.
    (should (consent-native-cli-daemon-process--record-of records "adapter-audit"))
    (should-not (consent-native-cli-daemon-process--record-of
                 records "adapter-result"))
    (should-not (consent-native-cli-daemon-process--event-of-kind
                 records "stdout"))))

(ert-deftest consent-native-cli-daemon-process-test-stdin-port-denial ()
  "A stdin port request fails closed in batch with a Scheme-readable error."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("stdin-read" "--mode" "batch")))
         (records (plist-get outcome :records))
         (error-datum (consent-native-cli-daemon-process--record-of
                       records "adapter-error")))
    (should (= (plist-get outcome :exit) 3))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     error-datum "kind"))
                   "noninteractive-confirmation-unavailable"))
    (should (consp error-datum))
    (should-not (consent-native-cli-daemon-process--record-of
                 records "adapter-result"))))

(ert-deftest consent-native-cli-daemon-process-test-stale-job-handle-denial ()
  "A stale job handle denies with a nested condition before any host op."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-status" "--mode" "daemon" "--channel"
                     "--job-id" "h-job-42" "--job-state" "stale")))
         (records (plist-get outcome :records))
         (error-datum (consent-native-cli-daemon-process--record-of
                       records "adapter-error"))
         (condition (consent-native-cli-daemon-process--field-value
                     error-datum "condition")))
    (should (= (plist-get outcome :exit) 3))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     error-datum "kind"))
                   "stale-handle"))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     error-datum "handle"))
                   "h-job-42"))
    (should condition)
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     condition "kind"))
                   "stale-handle"))
    (should-not (consent-native-cli-daemon-process--record-of
                 records "adapter-result"))))

;;;; Tests: vocabulary and record shape

(ert-deftest consent-native-cli-daemon-process-test-records-scheme-readable-and-in-vocabulary ()
  "Emitted records reparse and stay within the fixture's declared vocabulary."
  (let* ((approval (consent-native-cli-daemon-process--run
                    '("process-run" "--mode" "cli" "--terminal"
                      "--command" "/bin/echo" "--arg" "vocab")))
         (denial (consent-native-cli-daemon-process--run
                  '("process-run" "--mode" "batch"
                    "--command" "/bin/echo" "--arg" "vocab")))
         (event-kinds (consent-native-cli-daemon-process--vocabulary "event-kinds"))
         (error-kinds (consent-native-cli-daemon-process--vocabulary "error-kinds")))
    ;; The stream parsed through `consent-read-all', so each record is a datum
    ;; the Consent reader accepted; the run additionally produced records at all.
    (should (plist-get approval :records))
    (dolist (record (plist-get approval :records))
      (should (consp record)))
    (dolist (event (consent-native-cli-daemon-process--records-of
                    (plist-get approval :records) "adapter-event"))
      (should (member (consent-native-cli-daemon-process--name
                       (consent-native-cli-daemon-process--field-value event "kind"))
                      event-kinds)))
    (should (member
             (consent-native-cli-daemon-process--name
              (consent-native-cli-daemon-process--field-value
               (consent-native-cli-daemon-process--record-of
                (plist-get denial :records) "adapter-error")
               "kind"))
             error-kinds))
    ;; The request authority names a declared adapter authority class.
    (let ((effect (consent-native-cli-daemon-process--name
                   (consent-native-cli-daemon-process--field-value
                    (consent-native-cli-daemon-process--record-of
                     (plist-get approval :records) "capability-request")
                    "effect"))))
      (should (seq-find
               (lambda (entry)
                 (equal (consent-native-cli-daemon-process--name
                         (consent-native-cli-daemon-process--field-value
                          entry "class"))
                        effect))
               (consent-native-cli-daemon-process--field-value
                (consent-native-cli-daemon-process--adapter) "authority"))))))

(ert-deftest consent-native-cli-daemon-process-test-grant-covers-confirmation ()
  "A covering grant approves a confirmation-gated spawn without a prompt."
  (let* ((outcome (consent-native-cli-daemon-process--run
                   '("process-run" "--mode" "batch" "--grant" "g-run-tests"
                     "--command" "/bin/echo" "--arg" "granted")))
         (records (plist-get outcome :records))
         (decision (consent-native-cli-daemon-process--record-of
                    records "capability-decision")))
    (should (= (plist-get outcome :exit) 0))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     decision "status"))
                   "approved"))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     decision "grant"))
                   "g-run-tests"))
    ;; A covering grant approves without rendering an interactive prompt.
    (should-not (string-match-p "approval" (plist-get outcome :stderr)))))

(ert-deftest consent-native-cli-daemon-process-test-interpreted-compiled-shapes-align ()
  "Interpreted and compiled runs differ only in the result execution field."
  (let* ((interp (consent-native-cli-daemon-process--run
                  '("process-run" "--mode" "batch" "--approval"
                    "--execution" "interpreted"
                    "--command" "/bin/echo" "--arg" "exec")))
         (compiled (consent-native-cli-daemon-process--run
                    '("process-run" "--mode" "batch" "--approval"
                      "--execution" "compiled"
                      "--command" "/bin/echo" "--arg" "exec")))
         (interp-result (consent-native-cli-daemon-process--record-of
                         (plist-get interp :records) "adapter-result"))
         (compiled-result (consent-native-cli-daemon-process--record-of
                           (plist-get compiled :records) "adapter-result")))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     interp-result "execution"))
                   "interpreted"))
    (should (equal (consent-native-cli-daemon-process--name
                    (consent-native-cli-daemon-process--field-value
                     compiled-result "execution"))
                   "compiled"))
    ;; Every record except the result execution field is identical across paths.
    (should (equal (plist-get interp :stdout)
                   (replace-regexp-in-string
                    "(execution compiled)" "(execution interpreted)"
                    (plist-get compiled :stdout))))))

(provide 'consent-native-cli-daemon-process-test)

;;; consent-native-cli-daemon-process-test.el ends here
