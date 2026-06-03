;;; consent-native-cli-daemon-mock-test.el --- Native CLI/daemon mock adapter tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT mock-adapter lane for the native CLI and daemon host adapter contract
;; (docs/native-cli-daemon-adapter.md, fixture
;; fixtures/host-adapters/native-cli-daemon.scm).
;;
;; The portable validator
;; (tests/scheme/consent-native-cli-daemon-adapter-test.scm) checks the static
;; record shapes under any available R7RS host.  This lane is the
;; `(mock-adapter-suite emacs-ert)' validation lane named in the fixture: it
;; drives a deterministic in-process mock adapter that never starts a real
;; process, terminal, socket, or daemon.  The mock reads the checked-in adapter
;; declaration for its authority postures and vocabulary, then:
;;
;; - exercises the terminal, batch, and daemon prompt postures with
;;   deterministic noninteractive behavior,
;; - denies noninteractive confirmation with
;;   `noninteractive-confirmation-unavailable' when no approval channel,
;;   covering grant, or preloaded approval is available,
;; - proves stale handles, revoked grants, and expired grants fail before the
;;   mock adapter advances any host-operation counter,
;; - audits noninteractive denials as Scheme-readable records,
;; - keeps request, decision, result, event, audit, and error datums comparable
;;   with the capability environment vocabulary,
;; - compares interpreted and compiled effect records for the same request,
;; - proves redaction precedes event export and audit export.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'consent-capability)
(require 'consent-reader)
(require 'consent-redaction)

;;;; Fixture access

(defconst consent-native-cli-daemon-mock--fixture-path
  "fixtures/host-adapters/native-cli-daemon.scm"
  "Repository-relative path to the native CLI and daemon adapter fixture.")

(defconst consent-native-cli-daemon-mock--timestamp
  "2026-05-21T13:25:00-0700"
  "Fixed timestamp so mock records stay deterministic across runs.")

(defvar consent-native-cli-daemon-mock--fixture-cache nil
  "Cached parsed native CLI and daemon adapter fixture datum.")

(defun consent-native-cli-daemon-mock--fixture ()
  "Return the parsed native CLI and daemon adapter fixture datum."
  (or consent-native-cli-daemon-mock--fixture-cache
      (setq consent-native-cli-daemon-mock--fixture-cache
            (let ((forms (consent-read-all
                          (with-temp-buffer
                            (insert-file-contents
                             (expand-file-name
                              consent-native-cli-daemon-mock--fixture-path
                              consent--test-root))
                            (buffer-string)))))
              (car forms)))))

(defun consent-native-cli-daemon-mock--name (value)
  "Return VALUE as a stable identifier name string, or nil.
Handles Consent Scheme symbols, Emacs symbols, and strings so the same
navigation works over parsed fixture datums and mock-built record sexps."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((stringp value)
    value)
   ((symbolp value)
    (and value (symbol-name value)))
   (t nil)))

(defun consent-native-cli-daemon-mock--named-p (datum name)
  "Return non-nil when DATUM is a list whose head identifier is NAME."
  (and (consp datum)
       (equal (consent-native-cli-daemon-mock--name (car datum)) name)))

(defun consent-native-cli-daemon-mock--field (record name)
  "Return RECORD's field named NAME, or nil.
A field is a sub-list whose head identifier is NAME.  A leading sub-list
marks a headless record whose first field is its `car'."
  (if (consent-native-cli-daemon-mock--named-p record name)
      record
    (let ((fields (if (consp (car-safe record))
                      record
                    (cdr-safe record))))
      (seq-find
       (lambda (field)
         (consent-native-cli-daemon-mock--named-p field name))
       fields))))

(defun consent-native-cli-daemon-mock--field-value (record name)
  "Return the first value of RECORD's field named NAME, or nil."
  (cadr (consent-native-cli-daemon-mock--field record name)))

(defun consent-native-cli-daemon-mock--names (values)
  "Return VALUES mapped to their stable identifier name strings."
  (mapcar #'consent-native-cli-daemon-mock--name values))

(defun consent-native-cli-daemon-mock--adapter ()
  "Return the adapter declaration section of the fixture."
  (consent-native-cli-daemon-mock--field-value
   (consent-native-cli-daemon-mock--fixture) "adapter"))

(defun consent-native-cli-daemon-mock--authority-entries ()
  "Return the adapter's declared authority class entries."
  (consent-native-cli-daemon-mock--field-value
   (consent-native-cli-daemon-mock--adapter) "authority"))

(defun consent-native-cli-daemon-mock--authority-entry (class)
  "Return the authority entry whose class name is CLASS, or nil."
  (seq-find
   (lambda (entry)
     (equal (consent-native-cli-daemon-mock--name
             (consent-native-cli-daemon-mock--field-value entry "class"))
            class))
   (consent-native-cli-daemon-mock--authority-entries)))

(defun consent-native-cli-daemon-mock--policy-for (class)
  "Return the declared policy posture name for authority CLASS."
  (consent-native-cli-daemon-mock--name
   (consent-native-cli-daemon-mock--field-value
    (consent-native-cli-daemon-mock--authority-entry class) "policy")))

(defun consent-native-cli-daemon-mock--effect-for (class)
  "Return the declared host effect name for authority CLASS."
  (consent-native-cli-daemon-mock--name
   (consent-native-cli-daemon-mock--field-value
    (consent-native-cli-daemon-mock--authority-entry class) "effect")))

(defun consent-native-cli-daemon-mock--error-kinds ()
  "Return the adapter's declared error-kind names."
  (consent-native-cli-daemon-mock--names
   (consent-native-cli-daemon-mock--field-value
    (consent-native-cli-daemon-mock--adapter) "error-kinds")))

(defun consent-native-cli-daemon-mock--event-kinds ()
  "Return the adapter's declared event-kind names."
  (consent-native-cli-daemon-mock--names
   (consent-native-cli-daemon-mock--field-value
    (consent-native-cli-daemon-mock--adapter) "event-kinds")))

(defun consent-native-cli-daemon-mock--capability-environment-effects ()
  "Return the distinct host effect names used by the Emacs capability environment."
  (delete-dups
   (mapcar (lambda (spec) (symbol-name (plist-get spec :effect)))
           (consent-emacs-capability-binding-specs))))

;;;; Mock adapter datums

(defun consent-native-cli-daemon-mock--scheme-readable-p (record)
  "Return non-nil when RECORD prints as data the Consent reader accepts."
  (condition-case nil
      (consp (consent-read (prin1-to-string record)))
    (error nil)))

(defun consent-native-cli-daemon-mock--export (datum)
  "Return DATUM as it would cross an export boundary, with redaction applied."
  (consent-redact datum))

(defun consent-native-cli-daemon-mock--id (prefix base)
  "Return a deterministic record id symbol from PREFIX and BASE."
  (intern (format "%s-%s" prefix base)))

(defun consent-native-cli-daemon-mock--policy-verb (policy)
  "Return the decision policy verb symbol for posture POLICY."
  (pcase policy
    ("confirmation-gated" 'confirm)
    ("allow-or-confirm" 'allow-or-confirm)
    ("grant-required" 'grant-required)
    ("redaction-gated" 'redaction-gated)
    (_ 'deny)))

(defun consent-native-cli-daemon-mock--request-datum (request)
  "Return the Scheme-readable capability-request datum for REQUEST."
  (list 'capability-request
        (list 'id (plist-get request :id))
        (list 'session (plist-get request :session))
        (list 'adapter 'native-cli-daemon)
        (list 'library (plist-get request :library))
        (list 'binding (plist-get request :binding))
        (list 'domain (plist-get request :domain))
        (list 'operation (plist-get request :operation))
        (list 'effect (intern (plist-get request :authority)))
        (list 'requires (plist-get request :requires))))

(defun consent-native-cli-daemon-mock--decision
    (id request-id status policy policy-category reason grant)
  "Return the Scheme-readable capability-decision datum."
  (list 'capability-decision
        (list 'id id)
        (list 'request request-id)
        (list 'status status)
        (list 'policy
              (list policy-category
                    (consent-native-cli-daemon-mock--policy-verb policy)))
        (list 'grant (or grant 'none))
        (list 'reason reason)))

(defun consent-native-cli-daemon-mock--event (id session kind source payload)
  "Return the Scheme-readable adapter-event datum."
  (list 'adapter-event
        (list 'id id)
        (list 'adapter 'native-cli-daemon)
        (list 'session session)
        (list 'kind kind)
        (list 'source source)
        (list 'payload payload)
        (list 'timestamp consent-native-cli-daemon-mock--timestamp)))

(defun consent-native-cli-daemon-mock--result
    (id host session value event-ids audit-ids)
  "Return the Scheme-readable adapter-result datum for mock HOST."
  (list 'adapter-result
        (list 'id id)
        (list 'adapter 'native-cli-daemon)
        (list 'mode (consent-native-cli-daemon-mock--host-mode host))
        (list 'execution (consent-native-cli-daemon-mock--host-execution host))
        (list 'session session)
        (list 'status 'ok)
        (list 'value value)
        (list 'events event-ids)
        (list 'audit audit-ids)
        (list 'resource-usage '((host-calls 1)))))

(defun consent-native-cli-daemon-mock--audit
    (id session request-id decision-id result-summary redactions)
  "Return the Scheme-readable adapter-audit datum."
  (list 'adapter-audit
        (list 'id id)
        (list 'adapter 'native-cli-daemon)
        (list 'session session)
        (list 'request request-id)
        (list 'decision decision-id)
        (list 'result result-summary)
        (list 'sink '(handle audit-sink h-audit-1))
        (list 'redactions redactions)
        (list 'timestamp consent-native-cli-daemon-mock--timestamp)))

(defun consent-native-cli-daemon-mock--error
    (kind session request-id decision-id message irritants
          handle domain operation condition)
  "Return the Scheme-readable adapter-error datum.
HANDLE, DOMAIN, OPERATION, and CONDITION are appended only when non-nil so
liveness denials can carry the nested capability-error condition."
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

(defun consent-native-cli-daemon-mock--without-execution (result)
  "Return RESULT with its execution field removed for cross-strategy compare."
  (seq-remove
   (lambda (field)
     (and (consp field) (eq (car field) 'execution)))
   result))

;;;; Mock adapter engine

(cl-defstruct (consent-native-cli-daemon-mock--host
               (:constructor consent-native-cli-daemon-mock--host-create)
               (:copier nil))
  "Deterministic native CLI and daemon mock host adapter state.
No slot holds a live process, terminal, socket, or daemon object; the mock
only records the Scheme-readable boundary datums."
  (mode 'cli)
  (terminal nil)
  (channel nil)
  (suspendable nil)
  (execution 'interpreted)
  (grants nil)
  (approvals nil)
  (handles nil)
  (operations 0)
  (audit-log nil))

(defun consent-native-cli-daemon-mock--deny
    (host request policy request-datum kind reason handle-condition)
  "Record a denied REQUEST against mock HOST without performing a host op.
HANDLE-CONDITION, when non-nil, attaches the nested capability-error
condition so the denial mirrors the fixture's stale-handle scenario."
  (let* ((id (plist-get request :id))
         (session (plist-get request :session))
         (dec-id (consent-native-cli-daemon-mock--id "dec" id))
         (audit-id (consent-native-cli-daemon-mock--id "audit" id))
         (handle (plist-get request :handle))
         (domain (plist-get request :domain))
         (operation (plist-get request :operation))
         (decision (consent-native-cli-daemon-mock--decision
                    dec-id id 'denied policy
                    (plist-get request :policy-category) reason nil))
         (error-datum
          (consent-native-cli-daemon-mock--error
           kind session id dec-id
           (format "%s denied in %s mode"
                   reason (consent-native-cli-daemon-mock--host-mode host))
           (plist-get request :irritants)
           (and handle-condition handle)
           (and handle-condition domain)
           (and handle-condition operation)
           (and handle-condition
                (list 'capability-error
                      (list 'kind kind)
                      (list 'handle handle)
                      (list 'domain domain)))))
         (audit (consent-native-cli-daemon-mock--audit
                 audit-id session id dec-id (list 'denied reason) nil)))
    (push audit (consent-native-cli-daemon-mock--host-audit-log host))
    (list :status 'denied
          :request request-datum
          :decision decision
          :error error-datum
          :events nil
          :audit audit
          :reason reason
          :error-kind kind
          :host-performed nil)))

(defun consent-native-cli-daemon-mock--approve
    (host request policy request-datum opts)
  "Record an approved REQUEST against mock HOST and advance its host op count.
OPTS may carry `:event' (an event kind to emit) and `:payload'."
  (let* ((id (plist-get request :id))
         (session (plist-get request :session))
         (dec-id (consent-native-cli-daemon-mock--id "dec" id))
         (result-id (consent-native-cli-daemon-mock--id "result" id))
         (audit-id (consent-native-cli-daemon-mock--id "audit" id))
         (event-kind (plist-get opts :event))
         (event-id (and event-kind
                        (consent-native-cli-daemon-mock--id "event" id)))
         (events (and event-kind
                      (list (consent-native-cli-daemon-mock--event
                             event-id session event-kind
                             (plist-get request :resource)
                             (or (plist-get opts :payload) "")))))
         (value (or (plist-get request :value)
                    '(handle process-job h-job-42)))
         (decision (consent-native-cli-daemon-mock--decision
                    dec-id id 'approved policy
                    (plist-get request :policy-category)
                    "approved" (plist-get request :grant)))
         (result (consent-native-cli-daemon-mock--result
                  result-id host session value
                  (and event-id (list event-id)) (list audit-id)))
         (audit (consent-native-cli-daemon-mock--audit
                 audit-id session id dec-id (list 'ok value) nil)))
    (cl-incf (consent-native-cli-daemon-mock--host-operations host))
    (push audit (consent-native-cli-daemon-mock--host-audit-log host))
    (list :status 'approved
          :request request-datum
          :decision decision
          :result result
          :events events
          :audit audit
          :reason "approved"
          :host-performed t)))

(defun consent-native-cli-daemon-mock--confirm
    (host request policy request-datum)
  "Resolve a confirmation-gated REQUEST under mock HOST's prompt posture."
  (pcase (consent-native-cli-daemon-mock--host-mode host)
    ('cli
     (if (consent-native-cli-daemon-mock--host-terminal host)
         (consent-native-cli-daemon-mock--approve
          host request policy request-datum
          '(:event approval-decision :payload "approved terminal prompt"))
       (consent-native-cli-daemon-mock--deny
        host request policy request-datum
        'noninteractive-confirmation-unavailable
        'noninteractive-confirmation-unavailable nil)))
    ('batch
     (if (memq (plist-get request :id)
               (consent-native-cli-daemon-mock--host-approvals host))
         (consent-native-cli-daemon-mock--approve
          host request policy request-datum nil)
       (consent-native-cli-daemon-mock--deny
        host request policy request-datum
        'noninteractive-confirmation-unavailable
        'noninteractive-confirmation-unavailable nil)))
    ('daemon
     (if (and (consent-native-cli-daemon-mock--host-channel host)
              (consent-native-cli-daemon-mock--host-suspendable host))
         (consent-native-cli-daemon-mock--approve
          host request policy request-datum
          '(:event approval-request :payload "approval requested"))
       (consent-native-cli-daemon-mock--deny
        host request policy request-datum
        'noninteractive-confirmation-unavailable
        'noninteractive-confirmation-unavailable nil)))
    (_
     (consent-native-cli-daemon-mock--deny
      host request policy request-datum
      'noninteractive-confirmation-unavailable
      'noninteractive-confirmation-unavailable nil))))

(defun consent-native-cli-daemon-mock--evaluate (host request)
  "Evaluate REQUEST against mock HOST and return an outcome plist.
Liveness and grant-validity gates run before any authorization posture, so
a stale handle, revoked grant, or expired grant fails before HOST advances
its host-operation counter."
  (let* ((authority (plist-get request :authority))
         (policy (consent-native-cli-daemon-mock--policy-for authority))
         (handle (plist-get request :handle))
         (grant (plist-get request :grant))
         (handle-status
          (and handle
               (cdr (assq handle
                          (consent-native-cli-daemon-mock--host-handles host)))))
         (grant-status
          (and grant
               (cdr (assq grant
                          (consent-native-cli-daemon-mock--host-grants host)))))
         (request-datum (consent-native-cli-daemon-mock--request-datum request)))
    (cond
     ((and handle (not (eq handle-status 'live)))
      (consent-native-cli-daemon-mock--deny
       host request policy request-datum
       (if handle-status 'stale-handle 'invalid-handle)
       (if handle-status 'stale-handle 'invalid-handle)
       t))
     ((eq grant-status 'revoked)
      (consent-native-cli-daemon-mock--deny
       host request policy request-datum 'policy-denied 'grant-revoked nil))
     ((eq grant-status 'expired)
      (consent-native-cli-daemon-mock--deny
       host request policy request-datum 'policy-denied 'grant-expired nil))
     (t
      (pcase policy
        ((or "allow-or-confirm" "redaction-gated")
         (consent-native-cli-daemon-mock--approve
          host request policy request-datum nil))
        ("grant-required"
         (if (eq grant-status 'valid)
             (consent-native-cli-daemon-mock--approve
              host request policy request-datum nil)
           (consent-native-cli-daemon-mock--deny
            host request policy request-datum
            'policy-denied 'grant-required nil)))
        ("confirmation-gated"
         (if (eq grant-status 'valid)
             (consent-native-cli-daemon-mock--approve
              host request policy request-datum nil)
           (consent-native-cli-daemon-mock--confirm
            host request policy request-datum)))
        (_
         (consent-native-cli-daemon-mock--deny
          host request policy request-datum
          'unsupported-effect 'unsupported-authority nil)))))))

;;;; Mock request shapes

(defun consent-native-cli-daemon-mock--spawn-request (id session &optional grant)
  "Return a confirmation-gated process-spawn REQUEST plist."
  (list :id id :session session
        :library '(cli process) :binding 'cli-process-start!
        :domain 'process :operation 'spawn
        :authority "process-control" :policy-category 'command-process
        :grant grant
        :resource '(handle process-job h-job-42)
        :requires '((policy command-process)
                    (grant (domain process) (operation spawn)))
        :irritants '((command "make") (arguments ("test")))))

(defun consent-native-cli-daemon-mock--status-request (id session handle)
  "Return an observation REQUEST plist that depends on HANDLE liveness."
  (list :id id :session session
        :library '(cli process) :binding 'cli-process-status
        :domain 'process :operation 'process-status
        :authority "process-observation" :policy-category 'command-process
        :handle handle
        :resource (list 'handle 'process-job handle)
        :requires (list '(policy command-process)
                        (list 'handle '(kind process-job)
                              (list 'id handle)))))

;;;; Tests: prompt postures

(ert-deftest consent-native-cli-daemon-mock-test-batch-noninteractive-denial ()
  "Batch mode fails a confirm closed and audits a Scheme-readable record."
  (let* ((host (consent-native-cli-daemon-mock--host-create :mode 'batch))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-batch-1 'batch-main))))
    (should (eq (plist-get outcome :status) 'denied))
    (should (eq (plist-get outcome :error-kind)
                'noninteractive-confirmation-unavailable))
    (should (eq (plist-get outcome :reason)
                'noninteractive-confirmation-unavailable))
    (should-not (plist-get outcome :host-performed))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 0))
    (should (member (symbol-name (plist-get outcome :error-kind))
                    (consent-native-cli-daemon-mock--error-kinds)))
    (should (consent-native-cli-daemon-mock--scheme-readable-p
             (plist-get outcome :decision)))
    (should (consent-native-cli-daemon-mock--scheme-readable-p
             (plist-get outcome :error)))
    (should (consent-native-cli-daemon-mock--scheme-readable-p
             (plist-get outcome :audit)))
    (should (equal (consent-native-cli-daemon-mock--name
                    (consent-native-cli-daemon-mock--field-value
                     (plist-get outcome :decision) "status"))
                   "denied"))
    ;; The adapter recorded the denial in its own audit log.
    (should (memq (plist-get outcome :audit)
                  (consent-native-cli-daemon-mock--host-audit-log host)))))

(ert-deftest consent-native-cli-daemon-mock-test-daemon-noninteractive-denial ()
  "Daemon mode without an approval channel fails closed and audits the denial."
  (let* ((host (consent-native-cli-daemon-mock--host-create :mode 'daemon))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-daemon-1 'project-main))))
    (should (eq (plist-get outcome :status) 'denied))
    (should (eq (plist-get outcome :error-kind)
                'noninteractive-confirmation-unavailable))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 0))
    (should (consent-native-cli-daemon-mock--scheme-readable-p
             (plist-get outcome :audit)))))

(ert-deftest consent-native-cli-daemon-mock-test-cli-without-terminal-denial ()
  "Terminal mode without a controlling terminal falls back to fail closed."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'cli :terminal nil))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-cli-1 'project-main))))
    (should (eq (plist-get outcome :status) 'denied))
    (should (eq (plist-get outcome :error-kind)
                'noninteractive-confirmation-unavailable))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 0))))

(ert-deftest consent-native-cli-daemon-mock-test-terminal-prompt-approval ()
  "Terminal mode with a controlling terminal approves and emits a decision event."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'cli :terminal t))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-cli-2 'project-main))))
    (should (eq (plist-get outcome :status) 'approved))
    (should (plist-get outcome :host-performed))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 1))
    (let ((events (plist-get outcome :events)))
      (should (= (length events) 1))
      (should (equal (consent-native-cli-daemon-mock--name
                      (consent-native-cli-daemon-mock--field-value
                       (car events) "kind"))
                     "approval-decision")))))

(ert-deftest consent-native-cli-daemon-mock-test-daemon-channel-approval ()
  "Daemon mode with a suspendable channel emits an approval-request and approves."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'daemon :channel t :suspendable t))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-daemon-2 'project-main))))
    (should (eq (plist-get outcome :status) 'approved))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 1))
    (let ((events (plist-get outcome :events)))
      (should (= (length events) 1))
      (should (member (consent-native-cli-daemon-mock--name
                       (consent-native-cli-daemon-mock--field-value
                        (car events) "kind"))
                      (consent-native-cli-daemon-mock--event-kinds)))
      (should (equal (consent-native-cli-daemon-mock--name
                      (consent-native-cli-daemon-mock--field-value
                       (car events) "kind"))
                     "approval-request")))))

(ert-deftest consent-native-cli-daemon-mock-test-batch-grant-covers-confirm ()
  "A covering grant approves a confirmation-gated request without a preload."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'batch :grants '((g-run-tests . valid))))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-batch-2 'batch-main 'g-run-tests))))
    (should (eq (plist-get outcome :status) 'approved))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 1))
    (should (equal (consent-native-cli-daemon-mock--name
                    (consent-native-cli-daemon-mock--field-value
                     (plist-get outcome :decision) "grant"))
                   "g-run-tests"))))

;;;; Tests: liveness and grant validity fail before host operations

(ert-deftest consent-native-cli-daemon-mock-test-stale-handle-denial-before-host-op ()
  "A stale handle denies with a nested condition before any host op runs.
The mock host carries an approval channel so only the liveness gate, not the
prompt posture, can be responsible for the denial."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'daemon :channel t :suspendable t
                :handles '((h-job-42 . stale))))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--status-request
                         'req-status-9 'project-main 'h-job-42))))
    (should (eq (plist-get outcome :status) 'denied))
    (should (eq (plist-get outcome :error-kind) 'stale-handle))
    (should-not (plist-get outcome :host-performed))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 0))
    (let* ((error-datum (plist-get outcome :error))
           (condition (consent-native-cli-daemon-mock--field-value
                       error-datum "condition")))
      (should (equal (consent-native-cli-daemon-mock--name
                      (consent-native-cli-daemon-mock--field-value
                       error-datum "handle"))
                     "h-job-42"))
      (should condition)
      (should (equal (consent-native-cli-daemon-mock--name
                      (consent-native-cli-daemon-mock--field-value
                       condition "kind"))
                     "stale-handle"))
      (should (consent-native-cli-daemon-mock--scheme-readable-p error-datum)))))

(ert-deftest consent-native-cli-daemon-mock-test-revoked-grant-denial-before-host-op ()
  "A revoked grant denies before any host op even when a channel is present."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'daemon :channel t :suspendable t
                :grants '((g-run-tests . revoked))))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-revoked 'project-main 'g-run-tests))))
    (should (eq (plist-get outcome :status) 'denied))
    (should (eq (plist-get outcome :error-kind) 'policy-denied))
    (should (eq (plist-get outcome :reason) 'grant-revoked))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 0))))

(ert-deftest consent-native-cli-daemon-mock-test-expired-grant-denial-before-host-op ()
  "An expired grant denies before any host op even when a channel is present."
  (let* ((host (consent-native-cli-daemon-mock--host-create
                :mode 'daemon :channel t :suspendable t
                :grants '((g-run-tests . expired))))
         (outcome (consent-native-cli-daemon-mock--evaluate
                   host (consent-native-cli-daemon-mock--spawn-request
                         'req-expired 'project-main 'g-run-tests))))
    (should (eq (plist-get outcome :status) 'denied))
    (should (eq (plist-get outcome :error-kind) 'policy-denied))
    (should (eq (plist-get outcome :reason) 'grant-expired))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 0))))

(ert-deftest consent-native-cli-daemon-mock-test-denial-does-not-advance-counter ()
  "A denial leaves the host-operation counter where the last approval left it."
  (let ((host (consent-native-cli-daemon-mock--host-create
               :mode 'cli :terminal t)))
    (consent-native-cli-daemon-mock--evaluate
     host (consent-native-cli-daemon-mock--spawn-request 'req-ok 'project-main))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 1))
    (setf (consent-native-cli-daemon-mock--host-handles host)
          '((h-job-9 . stale)))
    (consent-native-cli-daemon-mock--evaluate
     host (consent-native-cli-daemon-mock--status-request
           'req-stale 'project-main 'h-job-9))
    (should (= (consent-native-cli-daemon-mock--host-operations host) 1))))

;;;; Tests: interpreted and compiled comparison

(ert-deftest consent-native-cli-daemon-mock-test-interpreted-compiled-records-match ()
  "Interpreted and compiled runs differ only in the result execution field."
  (let* ((interp (consent-native-cli-daemon-mock--host-create
                  :mode 'cli :terminal t :execution 'interpreted))
         (comp (consent-native-cli-daemon-mock--host-create
                :mode 'cli :terminal t :execution 'compiled))
         (a (consent-native-cli-daemon-mock--evaluate
             interp (consent-native-cli-daemon-mock--spawn-request
                     'req-exec 'project-main)))
         (b (consent-native-cli-daemon-mock--evaluate
             comp (consent-native-cli-daemon-mock--spawn-request
                   'req-exec 'project-main))))
    (should (equal (plist-get a :request) (plist-get b :request)))
    (should (equal (plist-get a :decision) (plist-get b :decision)))
    (should (equal (plist-get a :events) (plist-get b :events)))
    (should (equal (plist-get a :audit) (plist-get b :audit)))
    (should-not (equal (plist-get a :result) (plist-get b :result)))
    (should (equal (consent-native-cli-daemon-mock--without-execution
                    (plist-get a :result))
                   (consent-native-cli-daemon-mock--without-execution
                    (plist-get b :result))))
    (should (equal (consent-native-cli-daemon-mock--name
                    (consent-native-cli-daemon-mock--field-value
                     (plist-get a :result) "execution"))
                   "interpreted"))
    (should (equal (consent-native-cli-daemon-mock--name
                    (consent-native-cli-daemon-mock--field-value
                     (plist-get b :result) "execution"))
                   "compiled"))))

;;;; Tests: capability environment vocabulary

(ert-deftest consent-native-cli-daemon-mock-test-records-comparable-with-vocabulary ()
  "Mock boundary datums stay within the declared and capability-env vocabulary."
  (let* ((approval (consent-native-cli-daemon-mock--evaluate
                    (consent-native-cli-daemon-mock--host-create
                     :mode 'cli :terminal t)
                    (consent-native-cli-daemon-mock--spawn-request
                     'req-vocab-ok 'project-main)))
         (denial (consent-native-cli-daemon-mock--evaluate
                  (consent-native-cli-daemon-mock--host-create :mode 'batch)
                  (consent-native-cli-daemon-mock--spawn-request
                   'req-vocab-deny 'batch-main)))
         (cap-effects
          (consent-native-cli-daemon-mock--capability-environment-effects))
         (authority (consent-native-cli-daemon-mock--name
                     (consent-native-cli-daemon-mock--field-value
                      (plist-get approval :request) "effect"))))
    ;; The request authority resolves, through the fixture, to a host effect
    ;; the Emacs capability environment recognizes.
    (should (member (consent-native-cli-daemon-mock--effect-for authority)
                    cap-effects))
    (dolist (status (list (plist-get approval :decision)
                          (plist-get denial :decision)))
      (should (member (consent-native-cli-daemon-mock--name
                       (consent-native-cli-daemon-mock--field-value
                        status "status"))
                      '("approved" "denied"))))
    (dolist (event (plist-get approval :events))
      (should (member (consent-native-cli-daemon-mock--name
                       (consent-native-cli-daemon-mock--field-value event "kind"))
                      (consent-native-cli-daemon-mock--event-kinds))))
    (should (member (consent-native-cli-daemon-mock--name
                     (consent-native-cli-daemon-mock--field-value
                      (plist-get denial :error) "kind"))
                    (consent-native-cli-daemon-mock--error-kinds)))
    (dolist (datum (list (plist-get approval :request)
                         (plist-get approval :decision)
                         (plist-get approval :result)
                         (plist-get approval :audit)
                         (plist-get denial :error)))
      (should (consent-native-cli-daemon-mock--scheme-readable-p datum)))))

(ert-deftest consent-native-cli-daemon-mock-test-effects-subset-of-capability-env ()
  "Every adapter authority effect is recognized by the capability environment."
  (let ((adapter-effects
         (delete-dups
          (mapcar (lambda (entry)
                    (consent-native-cli-daemon-mock--name
                     (consent-native-cli-daemon-mock--field-value
                      entry "effect")))
                  (consent-native-cli-daemon-mock--authority-entries))))
        (cap-effects
         (consent-native-cli-daemon-mock--capability-environment-effects)))
    (should adapter-effects)
    (should (seq-every-p (lambda (effect) (member effect cap-effects))
                         adapter-effects))))

;;;; Tests: redaction precedes export

(ert-deftest consent-native-cli-daemon-mock-test-redaction-before-event-export ()
  "An event carrying a secret is unsafe until export redaction removes it."
  (let ((event (consent-native-cli-daemon-mock--event
                'event-99 'project-main 'stdout
                '(handle process-job h-job-42)
                "build log token sk-ABCDEFGH12345678 emitted")))
    (should-not (consent-safe-for-provider-p event 'export))
    (let ((exported (consent-native-cli-daemon-mock--export event)))
      (should (consent-safe-for-provider-p exported 'export))
      (should-not (string-match-p "sk-ABCDEFGH12345678"
                                  (prin1-to-string exported)))
      (should (consent-native-cli-daemon-mock--scheme-readable-p exported)))))

(ert-deftest consent-native-cli-daemon-mock-test-redaction-before-audit-export ()
  "Audit secrets are redacted and local-only context is withheld before export."
  (let ((audit (consent-native-cli-daemon-mock--audit
                'audit-99 'project-main 'req-99 'dec-99
                '(ok (output "exported gho_ABCDEFGHIJKLMNOP token"))
                nil)))
    (should-not (consent-safe-for-provider-p audit 'export))
    (let ((exported (consent-native-cli-daemon-mock--export audit)))
      (should (consent-safe-for-provider-p exported 'export))
      (should-not (string-match-p "gho_ABCDEFGHIJKLMNOP"
                                  (prin1-to-string exported)))))
  (let* ((context (consent-context-local-only!
                   '(home-directory "/Users/example") "local path"))
         (exported (consent-native-cli-daemon-mock--export context)))
    (should (consent-redaction-local-only-p context))
    (should-not (consent-safe-for-provider-p context 'export))
    (should-not (string-match-p "/Users/example" (prin1-to-string exported)))
    (should (equal (consent-native-cli-daemon-mock--name (car exported))
                   "local-only"))))

(provide 'consent-native-cli-daemon-mock-test)

;;; consent-native-cli-daemon-mock-test.el ends here
