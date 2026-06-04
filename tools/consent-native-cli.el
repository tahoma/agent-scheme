;;; consent-native-cli.el --- Native CLI process-boundary entrypoint  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Minimal native CLI process-boundary entrypoint for the native CLI and daemon
;; host adapter (docs/native-cli-daemon-adapter.md, fixture
;; fixtures/host-adapters/native-cli-daemon.scm).
;;
;; This file is the Emacs-host PARITY TWIN of the `(process-boundary-suite
;; native-cli)' lane.  The canonical, non-Emacs entrypoint is the portable
;; Consent Scheme program `tools/consent-native-cli.scm' over the `(cli
;; native-cli)' and `(cli process-host)' libraries; this Emacs implementation
;; mirrors the same Scheme-readable record contract under the Emacs host so the
;; two bootstrap hosts stay at parity.  It is run as a real OS process (see the
;; `tools/consent-native-cli' wrapper with `CONSENT_NATIVE_CLI_HOST=emacs') and,
;; when a capability request is approved, it spawns, streams, waits for, signals,
;; and reaps a real child process before emitting the contract's records.
;;
;; Design invariants the harness depends on:
;;
;; - The adapter resolves the request authority posture from the checked-in
;;   fixture, so the interpreted process path and the future compiled path share
;;   one capability-request/decision vocabulary (effect-path
;;   `shared-capability-request').
;; - Every denial -- noninteractive confirmation, stale or invalid job handle,
;;   denied stdin port -- is decided before any host operation runs, so a denied
;;   request never spawns, signals, or reads a child.
;; - The Scheme-readable boundary record stream is written to stdout only.
;;   Approval prompts and adapter diagnostics are written to stderr, so an
;;   approval prompt never consumes the data stream a host-backed stdin port
;;   delivers to a child process.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'consent-reader)

;;;; Fixture-derived authority vocabulary

(defconst consent-native-cli--fixture-path
  "fixtures/host-adapters/native-cli-daemon.scm"
  "Repository-relative path to the native CLI and daemon adapter fixture.")

(defconst consent-native-cli--timestamp
  "2026-05-21T13:25:00-0700"
  "Fixed timestamp so emitted records stay deterministic across runs.")

(defvar consent-native-cli--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root inferred from this file's location.")

(defvar consent-native-cli--fixture-cache nil
  "Cached parsed native CLI and daemon adapter fixture datum.")

(defun consent-native-cli--name (value)
  "Return VALUE as a stable identifier name string, or nil.
Handles Consent Scheme reader symbols, Emacs symbols, and strings so the
same navigation works over parsed fixture datums and built record sexps."
  (cond
   ((consent-symbol-p value) (consent-symbol-name value))
   ((stringp value) value)
   ((symbolp value) (and value (symbol-name value)))
   (t nil)))

(defun consent-native-cli--named-p (datum name)
  "Return non-nil when DATUM is a list whose head identifier is NAME."
  (and (consp datum)
       (equal (consent-native-cli--name (car datum)) name)))

(defun consent-native-cli--field (record name)
  "Return RECORD's field named NAME, or nil.
A field is a sub-list whose head identifier is NAME."
  (if (consent-native-cli--named-p record name)
      record
    (let ((fields (if (consp (car-safe record)) record (cdr-safe record))))
      (seq-find (lambda (field) (consent-native-cli--named-p field name))
                fields))))

(defun consent-native-cli--field-value (record name)
  "Return the first value of RECORD's field named NAME, or nil."
  (cadr (consent-native-cli--field record name)))

(defun consent-native-cli--fixture ()
  "Return the parsed native CLI and daemon adapter fixture datum."
  (or consent-native-cli--fixture-cache
      (setq consent-native-cli--fixture-cache
            (car (consent-read-all
                  (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name consent-native-cli--fixture-path
                                       consent-native-cli--root))
                    (buffer-string)))))))

(defun consent-native-cli--adapter ()
  "Return the adapter declaration section of the fixture."
  (consent-native-cli--field-value (consent-native-cli--fixture) "adapter"))

(defun consent-native-cli--authority-entry (class)
  "Return the fixture authority entry whose class name is CLASS, or nil."
  (seq-find
   (lambda (entry)
     (equal (consent-native-cli--name
             (consent-native-cli--field-value entry "class"))
            class))
   (consent-native-cli--field-value (consent-native-cli--adapter) "authority")))

(defun consent-native-cli--policy-for (class)
  "Return the declared policy posture name for authority CLASS."
  (consent-native-cli--name
   (consent-native-cli--field-value
    (consent-native-cli--authority-entry class) "policy")))

;;;; Operation table

;; Each operation maps to the fixture binding, domain, authority class, and the
;; `(library ...)' that owns it.  The adapter never invents authority outside
;; this table; it resolves the posture for the authority class from the fixture.
(defconst consent-native-cli--operations
  '(("process-run"
     :binding cli-process-start! :library (cli process)
     :domain process :operation spawn :authority "process-control")
    ("process-status"
     :binding cli-process-status :library (cli process)
     :domain process :operation process-status :authority "process-observation")
    ("process-signal"
     :binding cli-process-signal! :library (cli process)
     :domain process :operation signal :authority "process-control")
    ("stdin-read"
     :binding cli-standard-input :library (cli stdio)
     :domain port :operation read :authority "terminal-io"))
  "Adapter operation table keyed by CLI subcommand name.")

(defun consent-native-cli--operation-spec (name)
  "Return the operation plist for subcommand NAME, or signal an error."
  (or (cdr (assoc name consent-native-cli--operations))
      (error "Unknown native CLI operation: %s" name)))

;;;; Argument parsing

(defun consent-native-cli--parse-args (args)
  "Parse ARGS (a list of strings) into an options plist.
Leading \"--\" separators are ignored so the wrapper can pass a clean
argument vector after Emacs option processing."
  (let ((opts (list :mode "cli" :execution "interpreted"
                    :session "project-main" :child-arguments nil))
        (rest (seq-remove (lambda (a) (equal a "--")) args)))
    (when rest
      (setq opts (plist-put opts :subcommand (car rest)))
      (setq rest (cdr rest)))
    (while rest
      (let ((flag (car rest)))
        (pcase flag
          ("--mode" (setq opts (plist-put opts :mode (cadr rest)) rest (cddr rest)))
          ("--execution" (setq opts (plist-put opts :execution (cadr rest)) rest (cddr rest)))
          ("--session" (setq opts (plist-put opts :session (cadr rest)) rest (cddr rest)))
          ("--request-id" (setq opts (plist-put opts :request-id (cadr rest)) rest (cddr rest)))
          ("--command" (setq opts (plist-put opts :command (cadr rest)) rest (cddr rest)))
          ("--arg"
           (setq opts (plist-put opts :child-arguments
                                 (append (plist-get opts :child-arguments)
                                         (list (cadr rest))))
                 rest (cddr rest)))
          ("--stdin-file" (setq opts (plist-put opts :stdin-file (cadr rest)) rest (cddr rest)))
          ("--cwd" (setq opts (plist-put opts :cwd (cadr rest)) rest (cddr rest)))
          ("--env"
           (setq opts (plist-put opts :child-environment
                                 (append (plist-get opts :child-environment)
                                         (list (cadr rest))))
                 rest (cddr rest)))
          ("--job-id" (setq opts (plist-put opts :job-id (cadr rest)) rest (cddr rest)))
          ("--job-state" (setq opts (plist-put opts :job-state (cadr rest)) rest (cddr rest)))
          ("--signal" (setq opts (plist-put opts :signal (cadr rest)) rest (cddr rest)))
          ("--grant" (setq opts (plist-put opts :grant (cadr rest)) rest (cddr rest)))
          ("--terminal" (setq opts (plist-put opts :terminal t) rest (cdr rest)))
          ("--channel" (setq opts (plist-put opts :channel t) rest (cdr rest)))
          ("--approval" (setq opts (plist-put opts :approval t) rest (cdr rest)))
          (_ (error "Unknown native CLI flag: %s" flag)))))
    opts))

(defun consent-native-cli--environment-entry (assignment)
  "Return the `(NAME VALUE)' datum for a NAME=VALUE child environment ASSIGNMENT."
  (let ((split (string-match "=" assignment)))
    (if split
        (list (intern (substring assignment 0 split))
              (substring assignment (1+ split)))
      (list (intern assignment) ""))))

;;;; Record builders

;; The record builders mirror the fixture's boundary record shapes exactly so
;; the harness, the mock lane, and the portable validator share one vocabulary.

(defun consent-native-cli--request-datum (opts spec resource-term)
  "Return the Scheme-readable capability-request datum for OPTS/SPEC.
RESOURCE-TERM is the already-built `(resource ...)' field."
  (list 'capability-request
        (list 'id (intern (or (plist-get opts :request-id) "req-native-cli")))
        (list 'session (intern (plist-get opts :session)))
        (list 'adapter 'native-cli-daemon)
        (list 'library (plist-get spec :library))
        (list 'binding (plist-get spec :binding))
        (list 'domain (plist-get spec :domain))
        (list 'operation (plist-get spec :operation))
        (list 'effect (intern (plist-get spec :authority)))
        resource-term))

(defun consent-native-cli--decision-datum (id request-id status reason grant)
  "Return the Scheme-readable capability-decision datum."
  (list 'capability-decision
        (list 'id id)
        (list 'request request-id)
        (list 'status status)
        (list 'grant (or grant 'none))
        (list 'reason reason)))

(defun consent-native-cli--event-datum (id session kind source payload)
  "Return the Scheme-readable adapter-event datum."
  (list 'adapter-event
        (list 'id id)
        (list 'adapter 'native-cli-daemon)
        (list 'session session)
        (list 'kind kind)
        (list 'source source)
        (list 'payload payload)
        (list 'timestamp consent-native-cli--timestamp)))

(defun consent-native-cli--result-datum (id opts value events audit usage)
  "Return the Scheme-readable adapter-result datum."
  (list 'adapter-result
        (list 'id id)
        (list 'adapter 'native-cli-daemon)
        (list 'mode (intern (plist-get opts :mode)))
        (list 'execution (intern (plist-get opts :execution)))
        (list 'session (intern (plist-get opts :session)))
        (list 'status 'ok)
        (list 'value value)
        (list 'events events)
        (list 'audit audit)
        (list 'resource-usage usage)))

(defun consent-native-cli--audit-datum (id session request-id decision-id result)
  "Return the Scheme-readable adapter-audit datum."
  (list 'adapter-audit
        (list 'id id)
        (list 'adapter 'native-cli-daemon)
        (list 'session session)
        (list 'request request-id)
        (list 'decision decision-id)
        (list 'result result)
        (list 'sink '(handle audit-sink h-audit-1))
        (list 'redactions '())
        (list 'timestamp consent-native-cli--timestamp)))

(defun consent-native-cli--error-datum
    (kind session request-id decision-id message irritants
          handle domain operation condition)
  "Return the Scheme-readable adapter-error datum.
HANDLE, DOMAIN, OPERATION, and CONDITION are appended only when non-nil so a
liveness denial can carry the nested capability-error condition."
  (append
   (list 'adapter-error
         (list 'kind kind)
         (list 'adapter 'native-cli-daemon)
         (list 'session session)
         (list 'request request-id)
         (list 'decision decision-id)
         (list 'message message)
         (list 'irritants irritants))
   (and handle (list (list 'handle handle)))
   (and domain (list (list 'domain domain)))
   (and operation (list (list 'operation operation)))
   (and condition (list (list 'condition condition)))))

;;;; Capability decision resolver

;; The resolver derives the decision from the fixture authority posture plus the
;; prompt-posture inputs.  It runs the liveness gate first, so a stale or invalid
;; job handle is denied before any prompt posture or host operation is reached.
(defun consent-native-cli--resolve (opts spec)
  "Resolve the capability decision for OPTS against operation SPEC.
Return a plist with `:status' (`approved' or `denied'), `:reason',
`:error-kind' (on denial), `:grant', and `:prompt' (a stderr summary string
when an interactive approval channel rendered one)."
  (let* ((authority (plist-get spec :authority))
         (policy (consent-native-cli--policy-for authority))
         (job-state (plist-get opts :job-state))
         (grant (plist-get opts :grant))
         (mode (plist-get opts :mode)))
    (cond
     ;; Liveness gate: a non-live handle fails closed before any posture runs.
     ((and job-state (not (equal job-state "live")))
      (let ((kind (if (equal job-state "stale") 'stale-handle 'invalid-handle)))
        (list :status 'denied :error-kind kind :reason kind)))
     ;; A covering grant approves a confirmation-gated request directly.
     ((and grant (member policy '("confirmation-gated" "grant-required")))
      (list :status 'approved :reason "covered-by-grant" :grant (intern grant)))
     ((member policy '("allow-or-confirm" "redaction-gated"))
      (list :status 'approved :reason "allowed-by-policy"))
     ((member policy '("confirmation-gated" "grant-required"))
      (pcase mode
        ("cli"
         (if (plist-get opts :terminal)
             (list :status 'approved :reason "approved-terminal-prompt"
                   :prompt "terminal approval prompt")
           (list :status 'denied
                 :error-kind 'noninteractive-confirmation-unavailable
                 :reason 'noninteractive-confirmation-unavailable)))
        ("batch"
         (if (plist-get opts :approval)
             (list :status 'approved :reason "approved-preloaded-decision")
           (list :status 'denied
                 :error-kind 'noninteractive-confirmation-unavailable
                 :reason 'noninteractive-confirmation-unavailable)))
        ("daemon"
         (if (plist-get opts :channel)
             (list :status 'approved :reason "approved-daemon-channel"
                   :prompt "daemon approval request")
           (list :status 'denied
                 :error-kind 'noninteractive-confirmation-unavailable
                 :reason 'noninteractive-confirmation-unavailable)))
        (_ (list :status 'denied
                 :error-kind 'noninteractive-confirmation-unavailable
                 :reason 'noninteractive-confirmation-unavailable))))
     (t (list :status 'denied :error-kind 'unsupported-effect
              :reason 'unsupported-effect)))))

;;;; Real host process operations

(defun consent-native-cli--run-child (opts)
  "Spawn the requested child across a real process boundary.
Return a plist with `:exit', `:stdout', and `:stderr'.  A host-backed stdin
port is delivered from `:stdin-file'; the child never sees the adapter's own
prompt stream."
  (let* ((command (plist-get opts :command))
         (arguments (plist-get opts :child-arguments))
         (stdin-file (plist-get opts :stdin-file))
         (stderr-file (make-temp-file "consent-native-cli-stderr"))
         ;; A granted cwd and environment are delivered to the child across the
         ;; real process boundary by binding the host process context.
         (default-directory (or (plist-get opts :cwd) default-directory))
         (process-environment
          (append (plist-get opts :child-environment) process-environment))
         (exit nil) (stderr ""))
    (unwind-protect
        (with-temp-buffer
          (setq exit (apply #'call-process command stdin-file
                            (list (current-buffer) stderr-file) nil arguments))
          (setq stderr (with-temp-buffer
                         (insert-file-contents stderr-file)
                         (buffer-string)))
          (list :exit exit :stdout (buffer-string) :stderr stderr))
      (ignore-errors (delete-file stderr-file)))))

(defun consent-native-cli--signal-child (opts)
  "Spawn a long-lived child, signal it, and reap it across a real boundary.
Return a plist with `:exit' (the reaped status) and `:signal' (the name sent)."
  (let* ((signal-name (or (plist-get opts :signal) "TERM"))
         (proc (make-process
                :name "consent-native-cli-signal"
                :command (list "sh" "-c" "while : ; do sleep 1 ; done")
                :noquery t
                :connection-type 'pipe)))
    (signal-process proc (intern signal-name))
    (let ((deadline (+ (float-time) 10)))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.05)))
    (when (process-live-p proc)
      (kill-process proc)
      (while (process-live-p proc) (accept-process-output proc 0.05)))
    (list :exit (process-exit-status proc) :signal signal-name)))

;;;; Output

(defun consent-native-cli--emit (datum)
  "Write DATUM to stdout as a Scheme-readable record followed by a newline."
  (prin1 datum)
  (terpri))

(defun consent-native-cli--prompt (text)
  "Render approval prompt TEXT to stderr without touching the stdin stream."
  ;; `message' writes to stderr under `--batch', keeping the stdout record
  ;; stream and any host-backed stdin port free of prompt traffic.
  (message "consent-native-cli: approval: %s" text))

(defun consent-native-cli--id (prefix request-id)
  "Return a deterministic record id symbol from PREFIX and REQUEST-ID."
  (intern (format "%s-%s" prefix request-id)))

;;;; Operation dispatch

(defun consent-native-cli--deny (opts spec request decision-id resolution)
  "Emit decision, error, and audit records for a denied RESOLUTION.
Return the denial exit code after proving no host operation ran."
  (let* ((session (intern (plist-get opts :session)))
         (request-id (cadr (consent-native-cli--field request "id")))
         (kind (plist-get resolution :error-kind))
         (reason (plist-get resolution :reason))
         (handle (and (plist-get opts :job-id) (intern (plist-get opts :job-id))))
         (liveness (memq kind '(stale-handle invalid-handle)))
         (decision (consent-native-cli--decision-datum
                    decision-id request-id 'denied reason nil))
         (error-datum
          (consent-native-cli--error-datum
           kind session request-id decision-id
           (format "%s denied in %s mode" reason (plist-get opts :mode))
           (or (plist-get opts :child-arguments)
               (and (plist-get opts :command)
                    (list (list 'command (plist-get opts :command)))))
           (and liveness handle)
           (and liveness (plist-get spec :domain))
           (and liveness (plist-get spec :operation))
           (and liveness
                (list 'capability-error
                      (list 'kind kind)
                      (list 'handle handle)
                      (list 'domain (plist-get spec :domain))))))
         (audit (consent-native-cli--audit-datum
                 (consent-native-cli--id "audit" request-id)
                 session request-id decision-id (list 'denied reason))))
    (consent-native-cli--emit request)
    (consent-native-cli--emit decision)
    (consent-native-cli--emit error-datum)
    (consent-native-cli--emit audit)
    3))

(defun consent-native-cli--approve (opts request decision-id resolution)
  "Run the approved host operation named by OPTS and emit its records.
Return 0 after the real host operation completes."
  (let* ((session (intern (plist-get opts :session)))
         (subcommand (plist-get opts :subcommand))
         (request-id (cadr (consent-native-cli--field request "id")))
         (grant (plist-get resolution :grant))
         (prompt (plist-get resolution :prompt))
         (decision (consent-native-cli--decision-datum
                    decision-id request-id 'approved
                    (plist-get resolution :reason) grant))
         (job (intern (or (plist-get opts :job-id) "h-job-1")))
         (events '()) (event-ids '()) host-value usage)
    (when prompt (consent-native-cli--prompt prompt))
    (pcase subcommand
      ("process-run"
       (let* ((run (consent-native-cli--run-child opts))
              (exit (plist-get run :exit))
              (source (list 'handle 'process-job job)))
         (when prompt
           ;; The approval channel emits its own event; it shares the record
           ;; stream with output events but never the child's stdin port.
           (let ((id (consent-native-cli--id "event-approval" request-id)))
             (push (consent-native-cli--event-datum
                    id session
                    (if (equal (plist-get opts :mode) "daemon")
                        'approval-request 'approval-decision)
                    source prompt)
                   events)
             (push id event-ids)))
         (unless (string-empty-p (plist-get run :stdout))
           (let ((id (consent-native-cli--id "event-out" request-id)))
             (push (consent-native-cli--event-datum
                    id session 'stdout source (plist-get run :stdout))
                   events)
             (push id event-ids)))
         (unless (string-empty-p (plist-get run :stderr))
           (let ((id (consent-native-cli--id "event-err" request-id)))
             (push (consent-native-cli--event-datum
                    id session 'stderr source (plist-get run :stderr))
                   events)
             (push id event-ids)))
         (let ((id (consent-native-cli--id "event-exit" request-id)))
           (push (consent-native-cli--event-datum
                  id session 'process-exit source
                  (list 'exit-status (if (integerp exit) exit -1)))
                 events)
           (push id event-ids))
         (setq host-value (list 'handle 'process-job job)
               usage '((host-calls 1)))))
      ("process-signal"
       (let* ((sig (consent-native-cli--signal-child opts))
              (source (list 'handle 'process-job job))
              (id (consent-native-cli--id "event-exit" request-id)))
         (push (consent-native-cli--event-datum
                id session 'process-exit source
                (list (list 'signal (intern (plist-get sig :signal)))
                      (list 'exit-status (plist-get sig :exit))))
               events)
         (push id event-ids)
         (setq host-value (list 'handle 'process-job job)
               usage '((host-calls 1)))))
      ("process-status"
       (setq host-value (list 'handle 'process-job job)
             usage '((host-calls 1))))
      ("stdin-read"
       (setq host-value
             (list 'handle 'stdio-port
                   (intern (or (plist-get opts :job-id) "h-stdin-1")))
             usage '((host-calls 1)))))
    (setq events (nreverse events)
          event-ids (nreverse event-ids))
    (let* ((audit-id (consent-native-cli--id "audit" request-id))
           (result (consent-native-cli--result-datum
                    (consent-native-cli--id "result" request-id)
                    opts host-value event-ids (list audit-id) usage))
           (audit (consent-native-cli--audit-datum
                   audit-id session request-id decision-id
                   (list 'ok host-value))))
      (consent-native-cli--emit request)
      (consent-native-cli--emit decision)
      (dolist (event events) (consent-native-cli--emit event))
      (consent-native-cli--emit result)
      (consent-native-cli--emit audit))
    0))

(defun consent-native-cli-run (args)
  "Run the native CLI adapter over ARGS and return the process exit code.
ARGS is the raw argument vector after Emacs option processing."
  (let* ((opts (consent-native-cli--parse-args args))
         (subcommand (plist-get opts :subcommand)))
    (unless subcommand
      (error "Usage: consent-native-cli OPERATION [OPTIONS]"))
    (let* ((spec (consent-native-cli--operation-spec subcommand))
           (resource-term
            (cond
             ((plist-get opts :command)
              (append
               (list 'resource (list 'command (plist-get opts :command)))
               (and (plist-get opts :child-arguments)
                    (list (list 'arguments (plist-get opts :child-arguments))))
               (and (plist-get opts :cwd)
                    (list (list 'cwd (plist-get opts :cwd))))
               (and (plist-get opts :child-environment)
                    (list (cons 'environment
                                (list (mapcar
                                       #'consent-native-cli--environment-entry
                                       (plist-get opts :child-environment))))))))
             ((plist-get opts :job-id)
              (list 'resource (list 'handle 'process-job
                                    (intern (plist-get opts :job-id)))))
             (t (list 'resource 'none))))
           (request (consent-native-cli--request-datum opts spec resource-term))
           (request-id (cadr (consent-native-cli--field request "id")))
           (decision-id (consent-native-cli--id "dec" request-id))
           (resolution (consent-native-cli--resolve opts spec)))
      (if (eq (plist-get resolution :status) 'approved)
          (consent-native-cli--approve opts request decision-id resolution)
        (consent-native-cli--deny opts spec request decision-id resolution)))))

(defun consent-native-cli-main ()
  "Entry point for the native CLI process-boundary wrapper.
Run the adapter over the remaining command-line arguments and exit with the
adapter's process exit code."
  (let ((code (consent-native-cli-run command-line-args-left)))
    (setq command-line-args-left nil)
    (kill-emacs code)))

(provide 'consent-native-cli)

;;; consent-native-cli.el ends here
