;;; consent-session.el --- Session lifecycle and snapshots  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Consent Scheme sessions are host-managed runtime records exposed as
;; Scheme-readable datums.  This module owns lifecycle state, snapshot/fork
;; records, registry lookup, and handle cleanup; evaluator entry points layer on
;; top from `consent-eval'.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'consent-audit)
(require 'consent-base)
(require 'consent-capability)
(require 'consent-policy)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)
(require 'consent-transcript)

(declare-function consent--source-library-call "consent-library")

(define-error 'consent-session-error
  "Consent Scheme session error"
  'consent-eval-error)

(cl-defstruct (consent-session
               (:constructor consent--make-session)
               (:copier nil))
  "Host-managed Consent Scheme session state.
ENVIRONMENT and CONTEXT carry the live evaluator state.  Scheme-visible state
is returned through `consent-session-datum' and snapshot records, not by
exposing this host structure."
  id
  scope
  status
  environment
  context
  baseline-bindings
  baseline-syntax
  project-root
  memory
  handles
  transcript
  recent-events
  capability-grants
  skill-activations
  locked-by-job
  created-at
  updated-at
  retired-at
  failure)

(defvar consent--session-source-store nil
  "Source-backed session store for canonical lifecycle records.")

(defvar consent--session-registry (make-hash-table :test #'equal)
  "Registry of durable live Emacs sessions by source-model id.")

(defvar consent--session-current-job-id nil
  "Dynamically bound job id allowed to evaluate a locked session.")

(defvar consent-session-current-id nil
  "Canonical default Consent Scheme session id.
Shared by the `(agent session)' verbs (`switch-session', `current-session',
`close-session') and the native REPL session commands; `consent-repl.el'
aliases `consent-current-session-id' to this variable so a verb run in the
REPL changes which session subsequent interactive forms evaluate in.")

(defun consent-session--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-session--field (name value)
  "Return a Scheme-readable field named NAME with VALUE."
  (list (consent-session--symbol name) value))

(defun consent-session--timestamp ()
  "Return the current time as a public timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun consent-session--scope (scope)
  "Return normalized SCOPE or signal a session error."
  (let ((normalized
         (cond
          ((consent-symbol-p scope)
           (intern (consent-symbol-name scope)))
          ((symbolp scope)
           scope)
          ((stringp scope)
           (intern scope))
          (t nil))))
    (unless (memq normalized '(fresh named project))
      (signal 'consent-session-error
              (list (format "unknown session scope: %S" scope))))
    normalized))

(defun consent-session--name (value description)
  "Return VALUE as a stable string name for DESCRIPTION."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (signal 'consent-session-error
            (list (format "%s must be a symbol or string" description))))))

(defun consent-session--option-key (key)
  "Return KEY normalized to an Emacs Lisp keyword."
  (intern
   (concat
    ":"
    (cond
     ((keywordp key)
      (substring (symbol-name key) 1))
     ((consent-symbol-p key)
      (consent-symbol-name key))
     ((symbolp key)
      (symbol-name key))
     ((stringp key)
      key)
     (t
      (format "%S" key))))))

(defun consent-session--primitive-options (options)
  "Return Scheme OPTIONS datum as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (consent--proper-list-elements options "session options")
                   plist)
      (let ((elements (consent--proper-list-elements-maybe entry)))
        (cond
         ((and elements (= (length elements) 2))
          (setq plist
                (plist-put plist
                           (consent-session--option-key (car elements))
                           (cadr elements))))
         ((consp entry)
          (setq plist
                (plist-put plist
                           (consent-session--option-key (car entry))
                           (cdr entry))))
         (t
          (signal 'consent-session-error
                  (list "session option entries must be pairs"))))))))

(defun consent-session--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun consent-session--source-call (name &rest arguments)
  "Call source-backed session procedure NAME with ARGUMENTS."
  (apply #'consent--source-library-call
         "(agent session)" name arguments))

(defun consent-session--source-store ()
  "Return the source-backed canonical session store."
  (or consent--session-source-store
      (setq consent--session-source-store
            (consent-session--source-call
             "consent-make-session-store"))))

(defun consent-session--source-id (value description)
  "Return VALUE as a source-library id symbol for DESCRIPTION."
  (consent-session--symbol
   (consent-session--name value description)))

(defun consent-session--source-option-value (key value)
  "Return VALUE normalized for source-library option KEY."
  (pcase key
    ((or :id :parent-id :forked-from :locked-by-job)
     (consent-session--source-id value
                                 (substring (symbol-name key) 1)))
    (:status
     (consent-session--symbol value))
    (_ value)))

(defun consent-session--source-options (&rest plists)
  "Return PLISTS as a source-library options alist."
  (let (fields)
    (dolist (plist plists (nreverse fields))
      (while plist
        (let ((key (pop plist))
              (value (pop plist)))
          (when value
            (push
             (consent-session--field
              (substring (symbol-name key) 1)
              (consent-session--source-option-value key value))
             fields)))))))

(defun consent-session--source-fields (session &rest plists)
  "Return source-library field updates for SESSION and PLISTS."
  (append
   (list
    (consent-session--field
     "status" (consent-session--symbol (consent-session-status session)))
    (consent-session--field
     "imports" (consent-session--session-imports session))
    (consent-session--field
     "definitions"
     (consent-session--name-list-datum
      (consent-session--session-definitions session)))
    (consent-session--field
     "macros"
     (consent-session--name-list-datum
      (consent-session--session-macros session)))
    (consent-session--field "memory" (consent-session-memory session))
    (consent-session--field "handles" (consent-session-handles session))
    (consent-session--field
     "capability-grants"
     (consent-session-capability-grants session))
    (consent-session--field
     "skill-activations"
     (consent-session-skill-activations session))
    (consent-session--field "transcript"
                            (consent-session-transcript session))
    (consent-session--field "recent-events"
                            (consent-session-recent-events session))
    (consent-session--field "created-at"
                            (consent-session-created-at session))
    (consent-session--field "updated-at"
                            (consent-session-updated-at session)))
   (when (consent-session-locked-by-job session)
     (list
      (consent-session--field
       "locked-by-job"
       (consent-session--symbol
        (consent-session-locked-by-job session)))))
   (when (consent-session-project-root session)
     (list
      (consent-session--field
       "project-root" (consent-session-project-root session))))
   (when (consent-session-retired-at session)
     (list
      (consent-session--field
       "retired-at" (consent-session-retired-at session))))
   (when (consent-session-failure session)
     (list
      (consent-session--field
       "failure" (consent-session-failure session))))
   (apply #'consent-session--source-options plists)))

(defun consent-session--source-sync! (session &rest plists)
  "Sync SESSION's public record fields into the source store."
  (consent-session--source-call
   "session-store-set-fields!"
   (consent-session--source-store)
   (consent-session--source-id (consent-session-id session) "session id")
   (apply #'consent-session--source-fields session plists)))

(defun consent-session--source-field-name (datum name description)
  "Return source DATUM field NAME as a stable string for DESCRIPTION."
  (consent-session--name
   (consent-session--datum-field-value datum name)
   description))

(defun consent-session--source-field-symbol (datum name description)
  "Return source DATUM field NAME as an Emacs symbol for DESCRIPTION."
  (intern
   (consent-session--source-field-name datum name description)))

(defun consent-session--current-project-root ()
  "Return the current `project.el' root, or nil."
  (when-let ((project (project-current nil)))
    (file-name-as-directory (expand-file-name (project-root project)))))

(defun consent-session--hash-keys (table)
  "Return sorted string keys from hash TABLE."
  (let (keys)
    (maphash (lambda (key _value) (push key keys)) table)
    (sort keys #'string<)))

(defun consent-session--environment-current-names (environment)
  "Return sorted names bound in ENVIRONMENT's current frame."
  (consent-session--hash-keys
   (consent--environment-bindings environment)))

(defun consent-session--syntax-current-names (syntax-environment)
  "Return sorted syntax names bound in SYNTAX-ENVIRONMENT's current frame."
  (consent-session--hash-keys
   (consent--syntax-environment-bindings syntax-environment)))

(defun consent-session--name-list-datum (names)
  "Return NAMES as a list of Consent Scheme symbols."
  (mapcar #'consent-session--symbol names))

(defun consent-session--imported-current-name-p (environment name)
  "Return non-nil when NAME is imported in ENVIRONMENT's current frame."
  (gethash name (consent--environment-imported-bindings environment)))

(defun consent-session--session-definitions (session)
  "Return user-defined value names for SESSION."
  (let* ((environment (consent-session-environment session))
         (baseline (consent-session-baseline-bindings session)))
    (seq-remove
     (lambda (name)
       (or (member name baseline)
           (consent-session--imported-current-name-p environment name)))
     (consent-session--environment-current-names environment))))

(defun consent-session--session-macros (session)
  "Return user-defined syntax names for SESSION."
  (let* ((context (consent-session-context session))
         (syntax-environment
          (consent--eval-context-syntax-environment context))
         (baseline (consent-session-baseline-syntax session)))
    (seq-remove
     (lambda (name) (member name baseline))
     (consent-session--syntax-current-names syntax-environment))))

(defun consent-session--library-datum (key)
  "Return library KEY as a Scheme-readable library-name datum."
  (condition-case _
      (consent-read key)
    (error key)))

(defun consent-session--session-imports (session)
  "Return imported or registered library names for SESSION."
  (mapcar
   #'consent-session--library-datum
   (let (keys)
     (maphash
      (lambda (key _library)
        (push key keys))
      (consent--eval-context-libraries
       (consent-session-context session)))
     (sort keys #'string<))))

(defun consent-session--handle-key (handle)
  "Return a stable key for HANDLE."
  (and (consent-handle-p handle)
       (format "%s:%s"
               (consent-handle-kind handle)
               (consent-handle-id handle))))

(defun consent-session--append-handle (handle handles)
  "Append HANDLE to HANDLES if it is not already present."
  (if (seq-some
       (lambda (candidate)
         (equal (consent-session--handle-key candidate)
                (consent-session--handle-key handle)))
       handles)
      handles
    (append handles (list handle))))

(defun consent-session--collect-handles (value &optional seen)
  "Return opaque handles reachable from VALUE."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((consent-handle-p value)
      (list value))
     ((or (null value)
          (eq value consent-true)
          (eq value consent-false)
          (consent-unspecified-p value)
          (consent-symbol-p value)
          (consent-character-p value)
          (consent-number-p value)
          (consent-bytevector-p value)
          (stringp value)
          (consent-procedure-p value)
          (consent-primitive-procedure-p value)
          (consent-record-type-p value))
      nil)
     ((or (consp value) (vectorp value) (consent-record-p value))
      (if (gethash value seen)
          nil
        (puthash value t seen)
        (cond
         ((consp value)
          (append (consent-session--collect-handles (car value) seen)
                  (consent-session--collect-handles (cdr value) seen)))
         ((vectorp value)
          (cl-loop for item across value
                   append (consent-session--collect-handles item seen)))
         ((consent-record-p value)
          (cl-loop for item across (consent-record-fields value)
                   append (consent-session--collect-handles item seen))))))
     ((consent--multiple-values-p value)
      (cl-loop for item in (consent--multiple-values-values value)
               append (consent-session--collect-handles item seen)))
     (t nil))))

(defun consent-session--environment-handles (environment)
  "Return opaque handles reachable from ENVIRONMENT values."
  (let ((handles nil)
        (seen-cells (make-hash-table :test #'eq))
        (cursor environment))
    (while cursor
      (maphash
       (lambda (_name cell)
         (unless (gethash cell seen-cells)
           (puthash cell t seen-cells)
           (dolist (handle
                    (consent-session--collect-handles
                     (consent--cell-value cell)))
             (setq handles
                   (consent-session--append-handle handle handles)))))
       (consent--environment-bindings cursor))
      (setq cursor (consent--environment-parent cursor)))
    handles))

(defun consent-session--refresh-handles (session &optional value)
  "Refresh SESSION handle references using ENVIRONMENT and optional VALUE."
  (let ((handles (consent-session--environment-handles
                  (consent-session-environment session))))
    (dolist (handle (consent-session--collect-handles value))
      (setq handles (consent-session--append-handle handle handles)))
    (setf (consent-session-handles session) handles)
    handles))

(defun consent-session--cleanup-handles (session)
  "Drop stale SESSION handles, releasing their registry entries.
Return the stale handles that were removed."
  (consent-session--refresh-handles session)
  (let (live stale)
    (dolist (handle (consent-session-handles session))
      (if (consent-capability-handle-live-p handle)
          (setq live (consent-session--append-handle handle live))
        (push handle stale)
        (consent-capability-release-handle handle)))
    (setq stale (nreverse stale))
    (setf (consent-session-handles session) live)
    (when stale
      (consent-audit-record
       'session-lifecycle
       `((category . agent-session)
         (operation . "session-cleanup-handles!")
         (session . ,(consent-session--symbol
                      (consent-session-id session)))
         (stale-handles . ,stale)
         (decision . completed))))
    stale))

(defun consent-session--set-updated! (session)
  "Refresh SESSION's updated timestamp."
  (setf (consent-session-updated-at session)
        (consent-session--timestamp)))

(defun consent-session--record-lifecycle!
    (session to operation &optional fields source-procedure)
  "Record SESSION moving to TO for OPERATION through the source model."
  (let ((from (consent-session-status session))
        (timestamp (consent-session--timestamp))
        datum)
    (setq datum
          (if source-procedure
              (consent-session--source-call
               source-procedure
               (consent-session--source-store)
               (consent-session--source-id
                (consent-session-id session) "session id")
               (consent-session--source-fields
                session
                (list :updated-at timestamp)))
            (consent-session--source-call
             "session-store-set-fields!"
             (consent-session--source-store)
             (consent-session--source-id
              (consent-session-id session) "session id")
             (consent-session--source-fields
              session
              (list :status to :updated-at timestamp)))))
    (setf (consent-session-status session)
          (consent-session--source-field-symbol
           datum "status" "session status"))
    (setf (consent-session-updated-at session) timestamp)
    (consent-audit-record
     'session-lifecycle
     (append
      `((category . agent-session)
        (operation . ,operation)
        (session . ,(consent-session--symbol
                     (consent-session-id session)))
        (from . ,from)
        (to . ,(consent-session-status session))
        (decision . completed))
      fields))
    datum))

(defun consent-session--require (id)
  "Return the durable session named ID or signal."
  (let* ((name (if (consent-session-p id)
                   (consent-session-id id)
                 (consent-session--name id "session id")))
         (session (gethash name consent--session-registry)))
    (unless session
      (signal 'consent-session-error
              (list (format "unknown session: %s" name))))
    session))

(defun consent-session--maybe (id)
  "Return the durable session named ID, or nil."
  (let ((name (consent-session--name id "session id")))
    (gethash name consent--session-registry)))

(defun consent-session--job-id-name (job-id)
  "Return JOB-ID as a stable session-lock name."
  (consent-session--name job-id "job id"))

(defun consent-session--lock! (session job-id)
  "Lock SESSION for JOB-ID or signal when another job owns it."
  (let ((name (consent-session--job-id-name job-id))
        (locked-by (consent-session-locked-by-job session)))
    (when (and locked-by (not (equal locked-by name)))
      (signal 'consent-session-error
              (list (format "session is locked by job: %s" locked-by))))
    (when (and (eq (consent-session-status session) 'active)
               (not (equal locked-by name)))
      (signal 'consent-session-error
              (list "session is already active")))
    (setf (consent-session-locked-by-job session) name)
    (consent-session--set-updated! session)
    session))

(defun consent-session--unlock! (session job-id)
  "Release SESSION's lock when JOB-ID owns it."
  (let ((name (consent-session--job-id-name job-id)))
    (when (equal (consent-session-locked-by-job session) name)
      (setf (consent-session-locked-by-job session) nil)
      (consent-session--set-updated! session)))
  session)

(defun consent-session--register-live! (session)
  "Register live SESSION unless it is a fresh collectable session."
  (unless (eq (consent-session-scope session) 'fresh)
    (when (gethash (consent-session-id session)
                   consent--session-registry)
      (signal 'consent-session-error
              (list (format "session already exists: %s"
                            (consent-session-id session)))))
    (puthash (consent-session-id session)
             session
             consent--session-registry))
  session)

(defun consent-session--make-live (scope options source-datum)
  "Construct a live Emacs session for SCOPE from SOURCE-DATUM."
  (let* ((normalized-scope (consent-session--scope scope))
         (id (consent-session--source-field-name
              source-datum "id" "session id"))
         (status (consent-session--source-field-symbol
                  source-datum "status" "session status"))
         (environment (consent-make-base-environment))
         (context (consent--new-eval-context options))
         (capability-grants
          (consent-session--option options :capability-grants nil))
         (timestamp
          (or (consent-session--datum-field-value source-datum "created-at")
              (consent-session--timestamp)))
         (project-root
          (when (eq normalized-scope 'project)
            (or (consent-session--option options :project-root nil)
                (consent-session--current-project-root)))))
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (setf (consent--eval-context-capability-grants context)
          capability-grants)
    (setf (consent--eval-context-session-id context) id)
    (consent--make-session
     :id id
     :scope normalized-scope
     :status status
     :environment environment
     :context context
     :baseline-bindings
     (consent-session--environment-current-names environment)
     :baseline-syntax
     (consent-session--syntax-current-names
      (consent--eval-context-syntax-environment context))
     :project-root project-root
     :memory (consent-session--option options :memory nil)
     :handles nil
     :transcript nil
     :recent-events nil
     :capability-grants capability-grants
     :skill-activations
     (consent-session--option options :skill-activations nil)
     :locked-by-job nil
     :created-at timestamp
     :updated-at timestamp)))

(defun consent-session-datum (session)
  "Return SESSION as a Scheme-readable datum."
  (consent-session--source-sync! session))

;;;###autoload
(defun consent-session-create! (scope &optional options)
  "Create a session in SCOPE using OPTIONS and return its datum."
  (let* ((normalized-scope (consent-session--scope scope))
         (timestamp (consent-session--timestamp))
         (project-root
          (when (eq normalized-scope 'project)
            (or (consent-session--option options :project-root nil)
                (consent-session--current-project-root))))
         (source-options
          (consent-session--source-options
           options
           (append
            (list :created-at timestamp :updated-at timestamp)
            (when project-root
              (list :project-root project-root)))))
         (source-datum
          (consent-session--source-call
           "session-store-create!"
           (consent-session--source-store)
           (consent-session--symbol normalized-scope)
           source-options)))
    (if (eq normalized-scope 'fresh)
        (progn
          (consent-audit-record
           'session-lifecycle
           `((category . agent-session)
             (operation . "session-create!")
             (session . ,(consent-session--datum-field-value
                          source-datum "id"))
             (scope . fresh)
             (to . collectable)
             (decision . completed)))
          source-datum)
      (let ((session
             (consent-session--register-live!
              (consent-session--make-live
               normalized-scope
               (append options
                       (when project-root
                         (list :project-root project-root)))
               source-datum))))
        (consent-audit-record
         'session-lifecycle
         `((category . agent-session)
           (operation . "session-create!")
           (session . ,(consent-session--symbol
                        (consent-session-id session)))
           (scope . ,(consent-session-scope session))
           (to . ,(consent-session-status session))
           (decision . completed)))
        (consent-session-datum session)))))

;;;###autoload
(defun consent-session-ref (id)
  "Return the session datum for ID, or nil when it is unknown."
  (when-let ((session (consent-session--maybe id)))
    (consent-session-datum session)))

;;;###autoload
(defun consent-session-list (&optional scope)
  "Return known session datums, optionally filtered by SCOPE."
  (let ((normalized-scope (and scope (consent-session--scope scope))))
    (maphash
     (lambda (_id session)
       (consent-session--source-sync! session))
     consent--session-registry)
    (if normalized-scope
        (consent-session--source-call
         "session-store-list"
         (consent-session--source-store)
         (consent-session--symbol normalized-scope))
      (consent-session--source-call
       "session-store-list"
       (consent-session--source-store)))))

(defun consent-session--datum-field-value (datum name)
  "Return field NAME from public tagged DATUM, or nil."
  (when (consp datum)
    (cadr
     (seq-find
      (lambda (field)
        (and (consp field)
             (or (and (consent-symbol-p (car field))
                      (equal (consent-symbol-name (car field)) name))
                 (and (symbolp (car field))
                      (equal (symbol-name (car field)) name)))))
      (cdr datum)))))

(defun consent-session--datum-p (datum)
  "Return non-nil when DATUM is a public session record."
  (and (consp datum)
       (consent-symbol-p (car datum))
       (equal (consent-symbol-name (car datum)) "session")))

;;;###autoload
(defun consent-session-handle-list (session-or-id)
  "Return handles owned by SESSION-OR-ID after stale cleanup."
  (cond
   ((consent-session-p session-or-id)
    (unless (memq (consent-session-status session-or-id)
                  '(retired collectable))
      (consent-session--cleanup-handles session-or-id))
    (consent-session-handles session-or-id))
   ((consent-session--datum-p session-or-id)
    (consent-session--datum-field-value session-or-id "handles"))
   (t
    (let ((session (consent-session--require session-or-id)))
      (unless (memq (consent-session-status session) '(retired collectable))
        (consent-session--cleanup-handles session))
      (consent-session-handles session)))))

;;;###autoload
(defun consent-session-suspend! (id)
  "Suspend session ID and return its updated datum."
  (let ((session (consent-session--require id)))
    (consent-session--record-lifecycle!
     session 'suspended "session-suspend!" nil "session-store-suspend!")))

;;;###autoload
(defun consent-session-resume! (id)
  "Resume session ID and return its updated datum."
  (let ((session (consent-session--require id)))
    (setf (consent-session-failure session) nil)
    (consent-session--record-lifecycle!
     session 'active "session-resume!" nil "session-store-resume!")))

;;;###autoload
(defun consent-session-snapshot! (id &optional options)
  "Snapshot session ID using OPTIONS and return a Scheme-readable record."
  (let* ((session (consent-session--require id))
         (stale-handles (consent-session--cleanup-handles session))
         (timestamp (consent-session--timestamp))
         (snapshot
          (progn
            (setf (consent-session-updated-at session) timestamp)
            (consent-session--source-sync! session)
            (consent-session--source-call
             "session-store-snapshot!"
             (consent-session--source-store)
             (consent-session--source-id
              (consent-session-id session) "session id")
             (consent-session--source-options
              options
              (list :created-at timestamp
                    :updated-at timestamp
                    :stale-handles stale-handles))))))
    (consent-audit-record
     'session-lifecycle
     `((category . agent-session)
       (operation . "session-snapshot!")
       (session . ,(consent-session--symbol
                    (consent-session-id session)))
       (snapshot . ,(consent-session--datum-field-value
                     snapshot "id"))
       (decision . completed)))
    snapshot))

(defun consent-session--copy-hash-table (table)
  "Return a shallow copy of hash TABLE."
  (let ((copy (make-hash-table :test (hash-table-test table))))
    (maphash (lambda (key value) (puthash key value copy)) table)
    copy))

(defun consent-session--copy-environment (environment)
  "Return a cell-copy of ENVIRONMENT and its parents."
  (when environment
    (let ((copy (consent-make-empty-environment
                 (consent-session--copy-environment
                  (consent--environment-parent environment)))))
      (maphash
       (lambda (name cell)
         (puthash name
                  (consent--make-cell (consent--cell-value cell))
                  (consent--environment-bindings copy)))
       (consent--environment-bindings environment))
      (setf (consent--environment-imported-bindings copy)
            (consent-session--copy-hash-table
             (consent--environment-imported-bindings environment)))
      copy)))

(defun consent-session--copy-syntax-environment (environment)
  "Return a shallow binding copy of syntax ENVIRONMENT and its parents."
  (when environment
    (consent--make-syntax-environment
     (consent-session--copy-hash-table
      (consent--syntax-environment-bindings environment))
     (consent-session--copy-syntax-environment
      (consent--syntax-environment-parent environment))
     (consent-session--copy-hash-table
      (consent--syntax-environment-imported-bindings environment)))))

(defun consent-session--copy-context (context environment)
  "Return a context copy based on CONTEXT for forked ENVIRONMENT."
  (let ((copy
         (consent--make-eval-context
          :steps 0
          :maximum-steps
          (consent--eval-context-maximum-steps context)
          :maximum-value-nodes
          (consent--eval-context-maximum-value-nodes context)
          :maximum-source-metadata
          (consent--eval-context-maximum-source-metadata context)
          :host-callbacks 0
          :maximum-host-callbacks
          (consent--eval-context-maximum-host-callbacks context)
          :events nil
          :event-count 0
          :maximum-events
          (consent--eval-context-maximum-events context)
          :maximum-event-nodes
          (consent--eval-context-maximum-event-nodes context)
          :event-hook nil
          :syntax-environment
          (consent-session--copy-syntax-environment
           (consent--eval-context-syntax-environment context))
          :libraries
          (consent-session--copy-hash-table
           (consent--eval-context-libraries context))
          :include-paths
          (copy-sequence
           (consent--eval-context-include-paths context))
          :include-directory
          (consent--eval-context-include-directory context)
          :file-paths
          (copy-sequence
           (consent--eval-context-file-paths context))
          :policy-actions
          (copy-sequence
           (consent--eval-context-policy-actions context))
          :policy-confirmation-function
          (consent--eval-context-policy-confirmation-function context)
          :capability-grants
          (copy-tree (consent--eval-context-capability-grants context))
          :active-capability-grants nil
          :current-input-port
          (consent--eval-context-current-input-port context)
          :current-output-port
          (consent--eval-context-current-output-port context)
          :current-error-port
          (consent--eval-context-current-error-port context)
          :current-error nil
          :session-id
          (consent--eval-context-session-id context)
          :request-id
          (consent--eval-context-request-id context)
          :request
          (consent--eval-context-request context)
          :focus
          (consent--eval-context-focus context)
          :region-context
          (consent--eval-context-region-context context)
          :buffer-context
          (consent--eval-context-buffer-context context)
          :project-context
          (consent--eval-context-project-context context)
          :conversation-summary
          (consent--eval-context-conversation-summary context)
          :command-line
          (copy-sequence (consent--eval-context-command-line context))
          :job-id nil
          :cancel-requested nil
          :interrupt-reason nil
          :interaction-environment environment
          :base-syntax-installed
          (consent--eval-context-base-syntax-installed context)
          :exception-handlers nil
          :dynamic-winds nil
          :docstring-retention
          (consent--eval-context-docstring-retention-mode context))))
    copy))

(defun consent-session--sync-capability-grants! (session)
  "Copy SESSION context grants back to the session record."
  (setf (consent-session-capability-grants session)
        (consent--eval-context-capability-grants
         (consent-session-context session))))

;;;###autoload
(defun consent-session-fork! (id &optional options)
  "Fork session ID using OPTIONS and return the new session datum."
  (let* ((source (consent-session--require id))
         (_stale-handles (consent-session--cleanup-handles source))
         (timestamp (consent-session--timestamp))
         (_source-datum (consent-session--source-sync! source))
         (fork-datum
          (consent-session--source-call
           "session-store-fork!"
           (consent-session--source-store)
           (consent-session--source-id
            (consent-session-id source) "session id")
           (consent-session--source-options
            options
            (list :created-at timestamp :updated-at timestamp))))
         (fork-id
          (consent-session--source-field-name
           fork-datum "id" "fork session id"))
         (environment
          (consent-session--copy-environment
           (consent-session-environment source)))
         (context
          (consent-session--copy-context
           (consent-session-context source)
           environment))
         (fork
          (consent--make-session
           :id fork-id
           :scope (consent-session-scope source)
           :status (consent-session--source-field-symbol
                    fork-datum "status" "session status")
           :environment environment
           :context context
           :baseline-bindings
           (copy-sequence (consent-session-baseline-bindings source))
           :baseline-syntax
           (copy-sequence (consent-session-baseline-syntax source))
           :project-root (consent-session-project-root source)
           :memory (copy-tree (consent-session-memory source))
           :handles (copy-sequence (consent-session-handles source))
           :transcript
           (copy-tree (consent-session-transcript source))
           :recent-events
           (copy-tree (consent-session-recent-events source))
           :capability-grants
           (copy-tree (consent-session-capability-grants source))
           :skill-activations
           (copy-tree (consent-session-skill-activations source))
           :locked-by-job nil
           :created-at timestamp
           :updated-at timestamp)))
    (setf (consent--eval-context-session-id context) fork-id)
    (consent-session--register-live! fork)
    (consent-audit-record
     'session-lifecycle
     `((category . agent-session)
       (operation . "session-fork!")
       (session . ,(consent-session--symbol
                    (consent-session-id source)))
       (fork . ,(consent-session--symbol fork-id))
       (decision . completed)))
    (consent-session-datum fork)))

;;;###autoload
(defun consent-session-retire! (id)
  "Retire session ID, release handles, and return its updated datum."
  (let ((session (consent-session--require id)))
    (consent-session--refresh-handles session)
    (let ((released
           (consent-capability-release-handles
            (consent-session-handles session))))
      (setf (consent-session-handles session) nil)
      (setf (consent-session-retired-at session)
            (consent-session--timestamp))
      (consent-session--record-lifecycle!
       session 'retired "session-retire!"
       `((released-handles . ,released))
       "session-store-retire!"))))

;;;###autoload
(defun consent-session-clear! ()
  "Clear all registered sessions and release their tracked handles."
  (maphash
   (lambda (_id session)
     (consent-capability-release-handles
      (consent-session-handles session)))
   consent--session-registry)
  (clrhash consent--session-registry)
  (setq consent--session-source-store nil)
  (setq consent--session-current-job-id nil)
  consent-unspecified)

(defun consent-session--audit-start-count ()
  "Return the current audit log length."
  (length (consent-audit-recent-entries)))

(defun consent-session--new-audit-entries (start-count)
  "Return audit entries recorded since START-COUNT in chronological order."
  (let* ((entries (consent-audit-recent-entries))
         (newest-first (cl-subseq entries 0
                                  (max 0 (- (length entries) start-count)))))
    (nreverse newest-first)))

(defun consent-session--context-event-p (entry)
  "Return non-nil when ENTRY is a context event audit datum."
  (let ((event-field
         (seq-find
          (lambda (field)
            (and (consp field)
                 (consent-symbol-p (car field))
                 (equal (consent-symbol-name (car field)) "event")))
          (cdr-safe entry))))
    (and event-field
         (consent-symbol-p (cadr event-field))
         (equal (consent-symbol-name (cadr event-field))
                "context-event"))))

(defun consent-session--policy-datum (decision)
  "Return a Scheme-readable pure-evaluation policy datum for DECISION."
  (list
   (list (consent-session--symbol "category")
         (consent-session--symbol "pure-r7rs"))
   (list (consent-session--symbol "decision")
         (consent-session--symbol decision))))

(defun consent-session--append-transcript-event! (session event)
  "Append transcript EVENT to SESSION using transcript retention policy."
  (setf (consent-session-transcript session)
        (consent-transcript-rotate
         (append (consent-session-transcript session) (list event))))
  event)

(defun consent-session--record-eval-start! (session source)
  "Record the start of SESSION evaluation of SOURCE."
  (consent-session--append-transcript-event!
   session
   (consent-transcript-event
    'eval-start
    `((session . ,(consent-session--symbol
                   (consent-session-id session)))
      (form . ,source)
      (policy . ,(consent-session--policy-datum 'requested))))))

(defun consent-session--prepare-eval! (session)
  "Mark SESSION active and reset per-evaluation counters."
  (when (memq (consent-session-status session) '(retired collectable))
    (signal 'consent-session-error
            (list "retired sessions cannot be evaluated")))
  (when-let ((locked-by (consent-session-locked-by-job session)))
    (unless (equal locked-by consent--session-current-job-id)
      (signal 'consent-session-error
              (list (format "session is locked by job: %s" locked-by)))))
  (let ((context (consent-session-context session)))
    (setf (consent--eval-context-steps context) 0)
    (setf (consent--eval-context-host-callbacks context) 0)
    (setf (consent--eval-context-events context) nil)
    (setf (consent--eval-context-event-count context) 0)
    (setf (consent--eval-context-capability-grants context)
          (consent-session-capability-grants session))
    (setf (consent--eval-context-active-capability-grants context) nil)
    (setf (consent--eval-context-current-error context) nil)
    (setf (consent--eval-context-session-id context)
          (consent-session-id session))
    (setf (consent--eval-context-job-id context)
          consent--session-current-job-id)
    (setf (consent--eval-context-cancel-requested context) nil)
    (setf (consent--eval-context-interrupt-reason context) nil)
    (unless consent--session-current-job-id
      (setf (consent--eval-context-event-hook context) nil))
    (setf (consent--eval-context-interaction-environment context)
          (consent-session-environment session)))
  (consent-session--record-lifecycle!
   session 'active "session-eval-start!"))

(defun consent-session--record-eval-success!
    (session source value start-count)
  "Record successful SESSION evaluation of SOURCE producing VALUE."
  (consent-session--refresh-handles session value)
  (let* ((new-entries (consent-session--new-audit-entries start-count))
         (events (consent-redact
                  (seq-filter #'consent-session--context-event-p
                              new-entries)
                  'transcript))
         (entry
          (consent-transcript-event
           'eval-end
           `((session . ,(consent-session--symbol
                          (consent-session-id session)))
             (form . ,source)
             (status . ok)
             (result . ,(consent-value->external value))
             (yields ,events)
             (policy . ,(consent-session--policy-datum 'allowed))))))
    (setf (consent-session-recent-events session) events)
    (consent-session--append-transcript-event! session entry)
    (setf (consent-session-failure session) nil)
    (consent-audit-record
     'session-evaluation
     `((category . pure-r7rs)
       (operation . "session-evaluate")
       (session . ,(consent-session--symbol
                    (consent-session-id session)))
       (input-form . ,source)
       (events . ,events)
       (decision . allowed)
       (result . ,(consent-value->external value))))
    (consent-session--record-lifecycle!
     session 'idle "session-eval-finish!"))
  value)

(defun consent-session--record-eval-error!
    (session source condition start-count)
  "Record failed SESSION evaluation of SOURCE with CONDITION."
  (let* ((new-entries (consent-session--new-audit-entries start-count))
         (events (consent-redact
                  (seq-filter #'consent-session--context-event-p
                              new-entries)
                  'transcript))
         (message (error-message-string condition))
         (transcript-status
          (pcase (car-safe condition)
            ('consent-cancelled-error "cancelled")
            ('consent-interrupt-error "interrupted")
            (_ "error")))
         (audit-decision
          (pcase (car-safe condition)
            ('consent-cancelled-error 'cancelled)
            ('consent-interrupt-error 'interrupted)
            (_ 'error)))
         (session-status
          (if (eq (car-safe condition) 'consent-cancelled-error)
              'idle
            'failed))
         (transition-operation
          (pcase (car-safe condition)
            ('consent-cancelled-error "session-eval-cancelled!")
            ('consent-interrupt-error "session-eval-interrupted!")
            (_ "session-eval-failed!")))
         (entry
          (consent-transcript-event
           'eval-error
           `((session . ,(consent-session--symbol
                          (consent-session-id session)))
             (form . ,source)
             (status . ,(intern transcript-status))
             (error . ,message)
             (yields ,events)
             (policy . ,(consent-session--policy-datum
                         audit-decision))))))
    (setf (consent-session-recent-events session) events)
    (consent-session--append-transcript-event! session entry)
    (setf (consent-session-failure session) message)
    (consent-audit-record
     'session-evaluation
     `((category . pure-r7rs)
       (operation . "session-evaluate")
       (session . ,(consent-session--symbol
                    (consent-session-id session)))
       (input-form . ,source)
       (events . ,events)
       (decision . ,audit-decision)
       (error . ,message)))
    (consent-session--record-lifecycle!
     session session-status transition-operation))
  condition)

(defun consent-session--primitive-create (arguments _context)
  "Primitive session-create! over ARGUMENTS."
  (consent-session-create!
   (car arguments)
   (if (cdr arguments)
       (consent-session--primitive-options (cadr arguments))
     nil)))

(defun consent-session--primitive-ref (arguments _context)
  "Primitive session-ref over ARGUMENTS."
  (or (consent-session-ref (car arguments))
      consent-false))

(defun consent-session--primitive-list (arguments _context)
  "Primitive session-list over ARGUMENTS."
  (if arguments
      (consent-session-list (car arguments))
    (consent-session-list)))

(defun consent-session--primitive-handles (arguments _context)
  "Primitive session-handles over ARGUMENTS."
  (consent-session-handle-list (car arguments)))

(defun consent-session--primitive-suspend (arguments _context)
  "Primitive session-suspend! over ARGUMENTS."
  (consent-session-suspend! (car arguments)))

(defun consent-session--primitive-resume (arguments _context)
  "Primitive session-resume! over ARGUMENTS."
  (consent-session-resume! (car arguments)))

(defun consent-session--primitive-snapshot (arguments _context)
  "Primitive session-snapshot! over ARGUMENTS."
  (consent-session-snapshot!
   (car arguments)
   (if (cdr arguments)
       (consent-session--primitive-options (cadr arguments))
     nil)))

(defun consent-session--primitive-fork (arguments _context)
  "Primitive session-fork! over ARGUMENTS."
  (consent-session-fork!
   (car arguments)
   (if (cdr arguments)
       (consent-session--primitive-options (cadr arguments))
     nil)))

(defun consent-session--primitive-retire (arguments _context)
  "Primitive session-retire! over ARGUMENTS."
  (consent-session-retire! (car arguments)))

(defun consent-session--primitive-create-session (arguments context)
  "Primitive create-session over ARGUMENTS, gated by window-session policy.
Optional ARGUMENTS are a scope symbol (default `named') and an options alist.
Does not change the default session."
  (consent-policy-authorize
   'window-session "create-session" '((domain . session)) context)
  (consent-session-create!
   (if (and arguments (car arguments)) (car arguments) 'named)
   (and (cdr arguments)
        (consent-session--primitive-options (cadr arguments)))))

(defun consent-session--primitive-switch-session (arguments context)
  "Primitive switch-session/set-default-session! over ARGUMENTS.
Sets the canonical default session, gated by window-session policy, and
signals when the named session is unknown."
  (consent-policy-authorize
   'window-session "switch-session" '((domain . session)) context)
  (let ((session (consent-session--maybe (car arguments))))
    (unless session
      (signal 'consent-session-error
              (list (format "unknown session: %s"
                            (consent-session--name (car arguments)
                                                   "session id")))))
    (setq consent-session-current-id (consent-session-id session))
    (consent-audit-record
     'session-lifecycle
     `((category . agent-session)
       (operation . "switch-session")
       (session . ,(consent-session--symbol consent-session-current-id))
       (decision . completed)))
    (consent-session-datum session)))

(defun consent-session--primitive-current-session (_arguments context)
  "Primitive current-session over CONTEXT.
Returns the default session datum, or current session info when no default
session is selected."
  (or (and consent-session-current-id
           (consent-session-ref consent-session-current-id))
      (and (fboundp 'consent-reflect-current-session-info)
           (consent-reflect-current-session-info context))
      consent-false))

(defun consent-session--primitive-list-sessions (arguments _context)
  "Primitive list-sessions over ARGUMENTS, optionally filtered by scope."
  (if arguments
      (consent-session-list (car arguments))
    (consent-session-list)))

(defun consent-session--primitive-close-session (arguments context)
  "Primitive close-session over ARGUMENTS, gated by window-session policy.
Retires the named session and clears the default session when it was current."
  (consent-policy-authorize
   'window-session "close-session" '((domain . session)) context)
  (let* ((session (consent-session--require (car arguments)))
         (id (consent-session-id session))
         (datum (consent-session-retire! (car arguments))))
    (when (equal consent-session-current-id id)
      (setq consent-session-current-id nil))
    datum))

(defun consent--session-adapter-primitive-specs ()
  "Return host adapter primitive specs layered over `(agent session)'."
  `(("session-create!" ,#'consent-session--primitive-create 1 2)
    ("session-ref" ,#'consent-session--primitive-ref 1 1)
    ("session-list" ,#'consent-session--primitive-list 0 1)
    ("session-handles" ,#'consent-session--primitive-handles 1 1)
    ("session-suspend!" ,#'consent-session--primitive-suspend 1 1)
    ("session-resume!" ,#'consent-session--primitive-resume 1 1)
    ("session-snapshot!" ,#'consent-session--primitive-snapshot 1 2)
    ("session-fork!" ,#'consent-session--primitive-fork 1 2)
    ("session-retire!" ,#'consent-session--primitive-retire 1 1)
    ("create-session" ,#'consent-session--primitive-create-session 0 2)
    ("switch-session" ,#'consent-session--primitive-switch-session 1 1)
    ("set-default-session!" ,#'consent-session--primitive-switch-session 1 1)
    ("current-session" ,#'consent-session--primitive-current-session 0 0)
    ("list-sessions" ,#'consent-session--primitive-list-sessions 0 1)
    ("close-session" ,#'consent-session--primitive-close-session 1 1)))

(provide 'consent-session)

;;; consent-session.el ends here
