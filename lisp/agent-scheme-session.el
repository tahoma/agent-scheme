;;; agent-scheme-session.el --- Session lifecycle and snapshots  -*- lexical-binding: t; -*-

;;; Commentary:

;; Agent Scheme sessions are host-managed runtime records exposed as
;; Scheme-readable datums.  This module owns lifecycle state, snapshot/fork
;; records, registry lookup, and handle cleanup; evaluator entry points layer on
;; top from `agent-scheme-eval'.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-base)
(require 'agent-scheme-capability)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)
(require 'agent-scheme-transcript)

(define-error 'agent-scheme-session-error
  "Agent Scheme session error"
  'agent-scheme-eval-error)

(cl-defstruct (agent-scheme-session
               (:constructor agent-scheme--make-session)
               (:copier nil))
  "Host-managed Agent Scheme session state.
ENVIRONMENT and CONTEXT carry the live evaluator state.  Scheme-visible state
is returned through `agent-scheme-session-datum' and snapshot records, not by
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
  snapshots
  capability-grants
  skill-activations
  locked-by-job
  parent-id
  forked-from
  created-at
  updated-at
  retired-at
  failure)

(defconst agent-scheme-session-scopes
  '(fresh named project)
  "Recognized Agent Scheme session scopes.")

(defconst agent-scheme-session-states
  '(new active idle suspended retired failed collectable)
  "Recognized Agent Scheme session lifecycle states.")

(defconst agent-scheme-session-restored-fields
  '(imports definitions macros memory-bindings capability-grant-requests
            transcripts recent-yields)
  "Snapshot fields that can be restored directly as Scheme data.")

(defconst agent-scheme-session-revalidated-fields
  '(project-root handle-references capability-grants skill-activations)
  "Snapshot fields that must be revalidated before use.")

(defconst agent-scheme-session-never-restored-fields
  '(stale-emacs-handles active-jobs approval-decisions provider-secrets
                        host-runtime-internals)
  "Runtime state that snapshots never blindly restore.")

(defvar agent-scheme--session-registry (make-hash-table :test #'equal)
  "Registry of durable non-fresh sessions by string id.")

(defvar agent-scheme--next-session-number 0
  "Next numeric suffix used for generated session ids.")

(defvar agent-scheme--next-snapshot-number 0
  "Next numeric suffix used for generated snapshot ids.")

(defvar agent-scheme--session-current-job-id nil
  "Dynamically bound job id allowed to evaluate a locked session.")

(defun agent-scheme-session--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-session--field (name value)
  "Return a Scheme-readable field named NAME with VALUE."
  (list (agent-scheme-session--symbol name) value))

(defun agent-scheme-session--timestamp ()
  "Return the current time as a public timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun agent-scheme-session--scope (scope)
  "Return normalized SCOPE or signal a session error."
  (let ((normalized
         (cond
          ((agent-scheme-symbol-p scope)
           (intern (agent-scheme-symbol-name scope)))
          ((symbolp scope)
           scope)
          ((stringp scope)
           (intern scope))
          (t nil))))
    (unless (memq normalized agent-scheme-session-scopes)
      (signal 'agent-scheme-session-error
              (list (format "unknown session scope: %S" scope))))
    normalized))

(defun agent-scheme-session--name (value description)
  "Return VALUE as a stable string name for DESCRIPTION."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (signal 'agent-scheme-session-error
            (list (format "%s must be a symbol or string" description))))))

(defun agent-scheme-session--option-key (key)
  "Return KEY normalized to an Emacs Lisp keyword."
  (intern
   (concat
    ":"
    (cond
     ((keywordp key)
      (substring (symbol-name key) 1))
     ((agent-scheme-symbol-p key)
      (agent-scheme-symbol-name key))
     ((symbolp key)
      (symbol-name key))
     ((stringp key)
      key)
     (t
      (format "%S" key))))))

(defun agent-scheme-session--primitive-options (options)
  "Return Scheme OPTIONS datum as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (agent-scheme--proper-list-elements options "session options")
                   plist)
      (let ((elements (agent-scheme--proper-list-elements-maybe entry)))
        (cond
         ((and elements (= (length elements) 2))
          (setq plist
                (plist-put plist
                           (agent-scheme-session--option-key (car elements))
                           (cadr elements))))
         ((consp entry)
          (setq plist
                (plist-put plist
                           (agent-scheme-session--option-key (car entry))
                           (cdr entry))))
         (t
          (signal 'agent-scheme-session-error
                  (list "session option entries must be pairs"))))))))

(defun agent-scheme-session--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun agent-scheme-session--generated-id (scope)
  "Return a fresh id string for SCOPE."
  (format "%s-%d" scope (cl-incf agent-scheme--next-session-number)))

(defun agent-scheme-session--generated-snapshot-id ()
  "Return a fresh snapshot id string."
  (format "snapshot-%d" (cl-incf agent-scheme--next-snapshot-number)))

(defun agent-scheme-session--current-project-root ()
  "Return the current `project.el' root, or nil."
  (when-let ((project (project-current nil)))
    (file-name-as-directory (expand-file-name (project-root project)))))

(defun agent-scheme-session--hash-keys (table)
  "Return sorted string keys from hash TABLE."
  (let (keys)
    (maphash (lambda (key _value) (push key keys)) table)
    (sort keys #'string<)))

(defun agent-scheme-session--environment-current-names (environment)
  "Return sorted names bound in ENVIRONMENT's current frame."
  (agent-scheme-session--hash-keys
   (agent-scheme--environment-bindings environment)))

(defun agent-scheme-session--syntax-current-names (syntax-environment)
  "Return sorted syntax names bound in SYNTAX-ENVIRONMENT's current frame."
  (agent-scheme-session--hash-keys
   (agent-scheme--syntax-environment-bindings syntax-environment)))

(defun agent-scheme-session--name-list-datum (names)
  "Return NAMES as a list of Agent Scheme symbols."
  (mapcar #'agent-scheme-session--symbol names))

(defun agent-scheme-session--imported-current-name-p (environment name)
  "Return non-nil when NAME is imported in ENVIRONMENT's current frame."
  (gethash name (agent-scheme--environment-imported-bindings environment)))

(defun agent-scheme-session--session-definitions (session)
  "Return user-defined value names for SESSION."
  (let* ((environment (agent-scheme-session-environment session))
         (baseline (agent-scheme-session-baseline-bindings session)))
    (seq-remove
     (lambda (name)
       (or (member name baseline)
           (agent-scheme-session--imported-current-name-p environment name)))
     (agent-scheme-session--environment-current-names environment))))

(defun agent-scheme-session--session-macros (session)
  "Return user-defined syntax names for SESSION."
  (let* ((context (agent-scheme-session-context session))
         (syntax-environment
          (agent-scheme--eval-context-syntax-environment context))
         (baseline (agent-scheme-session-baseline-syntax session)))
    (seq-remove
     (lambda (name) (member name baseline))
     (agent-scheme-session--syntax-current-names syntax-environment))))

(defun agent-scheme-session--library-datum (key)
  "Return library KEY as a Scheme-readable library-name datum."
  (condition-case _
      (agent-scheme-read key)
    (error key)))

(defun agent-scheme-session--session-imports (session)
  "Return imported or registered library names for SESSION."
  (mapcar
   #'agent-scheme-session--library-datum
   (let (keys)
     (maphash
      (lambda (key _library)
        (push key keys))
      (agent-scheme--eval-context-libraries
       (agent-scheme-session-context session)))
     (sort keys #'string<))))

(defun agent-scheme-session--handle-key (handle)
  "Return a stable key for HANDLE."
  (and (agent-scheme-handle-p handle)
       (format "%s:%s"
               (agent-scheme-handle-kind handle)
               (agent-scheme-handle-id handle))))

(defun agent-scheme-session--append-handle (handle handles)
  "Append HANDLE to HANDLES if it is not already present."
  (if (seq-some
       (lambda (candidate)
         (equal (agent-scheme-session--handle-key candidate)
                (agent-scheme-session--handle-key handle)))
       handles)
      handles
    (append handles (list handle))))

(defun agent-scheme-session--collect-handles (value &optional seen)
  "Return opaque handles reachable from VALUE."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((agent-scheme-handle-p value)
      (list value))
     ((or (null value)
          (eq value agent-scheme-true)
          (eq value agent-scheme-false)
          (agent-scheme-unspecified-p value)
          (agent-scheme-symbol-p value)
          (agent-scheme-character-p value)
          (agent-scheme-number-p value)
          (agent-scheme-bytevector-p value)
          (stringp value)
          (agent-scheme-procedure-p value)
          (agent-scheme-primitive-procedure-p value)
          (agent-scheme-record-type-p value))
      nil)
     ((or (consp value) (vectorp value) (agent-scheme-record-p value))
      (if (gethash value seen)
          nil
        (puthash value t seen)
        (cond
         ((consp value)
          (append (agent-scheme-session--collect-handles (car value) seen)
                  (agent-scheme-session--collect-handles (cdr value) seen)))
         ((vectorp value)
          (cl-loop for item across value
                   append (agent-scheme-session--collect-handles item seen)))
         ((agent-scheme-record-p value)
          (cl-loop for item across (agent-scheme-record-fields value)
                   append (agent-scheme-session--collect-handles item seen))))))
     ((agent-scheme--multiple-values-p value)
      (cl-loop for item in (agent-scheme--multiple-values-values value)
               append (agent-scheme-session--collect-handles item seen)))
     (t nil))))

(defun agent-scheme-session--environment-handles (environment)
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
                    (agent-scheme-session--collect-handles
                     (agent-scheme--cell-value cell)))
             (setq handles
                   (agent-scheme-session--append-handle handle handles)))))
       (agent-scheme--environment-bindings cursor))
      (setq cursor (agent-scheme--environment-parent cursor)))
    handles))

(defun agent-scheme-session--refresh-handles (session &optional value)
  "Refresh SESSION handle references using ENVIRONMENT and optional VALUE."
  (let ((handles (agent-scheme-session--environment-handles
                  (agent-scheme-session-environment session))))
    (dolist (handle (agent-scheme-session--collect-handles value))
      (setq handles (agent-scheme-session--append-handle handle handles)))
    (setf (agent-scheme-session-handles session) handles)
    handles))

(defun agent-scheme-session--cleanup-handles (session)
  "Drop stale SESSION handles, releasing their registry entries.
Return the stale handles that were removed."
  (agent-scheme-session--refresh-handles session)
  (let (live stale)
    (dolist (handle (agent-scheme-session-handles session))
      (if (agent-scheme-capability-handle-live-p handle)
          (setq live (agent-scheme-session--append-handle handle live))
        (push handle stale)
        (agent-scheme-capability-release-handle handle)))
    (setq stale (nreverse stale))
    (setf (agent-scheme-session-handles session) live)
    (when stale
      (agent-scheme-audit-record
       'session-lifecycle
       `((category . agent-session)
         (operation . "session-cleanup-handles!")
         (session . ,(agent-scheme-session--symbol
                      (agent-scheme-session-id session)))
         (stale-handles . ,stale)
         (decision . completed))))
    stale))

(defun agent-scheme-session--set-updated! (session)
  "Refresh SESSION's updated timestamp."
  (setf (agent-scheme-session-updated-at session)
        (agent-scheme-session--timestamp)))

(defun agent-scheme-session--transition! (session to operation &optional fields)
  "Move SESSION to lifecycle state TO for OPERATION and audit it."
  (unless (memq to agent-scheme-session-states)
    (signal 'agent-scheme-session-error
            (list (format "unknown session status: %S" to))))
  (let ((from (agent-scheme-session-status session)))
    (setf (agent-scheme-session-status session) to)
    (agent-scheme-session--set-updated! session)
    (agent-scheme-audit-record
     'session-lifecycle
     (append
      `((category . agent-session)
        (operation . ,operation)
        (session . ,(agent-scheme-session--symbol
                     (agent-scheme-session-id session)))
        (from . ,from)
        (to . ,to)
        (decision . completed))
      fields)))
  session)

(defun agent-scheme-session--require (id)
  "Return the durable session named ID or signal."
  (let* ((name (if (agent-scheme-session-p id)
                   (agent-scheme-session-id id)
                 (agent-scheme-session--name id "session id")))
         (session (gethash name agent-scheme--session-registry)))
    (unless session
      (signal 'agent-scheme-session-error
              (list (format "unknown session: %s" name))))
    session))

(defun agent-scheme-session--maybe (id)
  "Return the durable session named ID, or nil."
  (let ((name (agent-scheme-session--name id "session id")))
    (gethash name agent-scheme--session-registry)))

(defun agent-scheme-session--job-id-name (job-id)
  "Return JOB-ID as a stable session-lock name."
  (agent-scheme-session--name job-id "job id"))

(defun agent-scheme-session--lock! (session job-id)
  "Lock SESSION for JOB-ID or signal when another job owns it."
  (let ((name (agent-scheme-session--job-id-name job-id))
        (locked-by (agent-scheme-session-locked-by-job session)))
    (when (and locked-by (not (equal locked-by name)))
      (signal 'agent-scheme-session-error
              (list (format "session is locked by job: %s" locked-by))))
    (when (and (eq (agent-scheme-session-status session) 'active)
               (not (equal locked-by name)))
      (signal 'agent-scheme-session-error
              (list "session is already active")))
    (setf (agent-scheme-session-locked-by-job session) name)
    (agent-scheme-session--set-updated! session)
    session))

(defun agent-scheme-session--unlock! (session job-id)
  "Release SESSION's lock when JOB-ID owns it."
  (let ((name (agent-scheme-session--job-id-name job-id)))
    (when (equal (agent-scheme-session-locked-by-job session) name)
      (setf (agent-scheme-session-locked-by-job session) nil)
      (agent-scheme-session--set-updated! session)))
  session)

(defun agent-scheme-session--register! (session)
  "Register SESSION unless it is a fresh collectable session."
  (unless (eq (agent-scheme-session-scope session) 'fresh)
    (when (gethash (agent-scheme-session-id session)
                   agent-scheme--session-registry)
      (signal 'agent-scheme-session-error
              (list (format "session already exists: %s"
                            (agent-scheme-session-id session)))))
    (puthash (agent-scheme-session-id session)
             session
             agent-scheme--session-registry))
  session)

(defun agent-scheme-session--make (scope options)
  "Construct a session for SCOPE using OPTIONS."
  (let* ((normalized-scope (agent-scheme-session--scope scope))
         (id-value (agent-scheme-session--option options :id nil))
         (id (if id-value
                 (agent-scheme-session--name id-value "session id")
               (agent-scheme-session--generated-id normalized-scope)))
         (environment (agent-scheme-make-base-environment))
         (context (agent-scheme--new-eval-context options))
         (capability-grants
          (agent-scheme-session--option options :capability-grants nil))
         (timestamp (agent-scheme-session--timestamp))
         (project-root
          (when (eq normalized-scope 'project)
            (or (agent-scheme-session--option options :project-root nil)
                (agent-scheme-session--current-project-root))))
         (status (if (eq normalized-scope 'fresh) 'collectable 'new)))
    (setf (agent-scheme--eval-context-interaction-environment context)
          environment)
    (setf (agent-scheme--eval-context-capability-grants context)
          capability-grants)
    (setf (agent-scheme--eval-context-session-id context) id)
    (agent-scheme--make-session
     :id id
     :scope normalized-scope
     :status status
     :environment environment
     :context context
     :baseline-bindings
     (agent-scheme-session--environment-current-names environment)
     :baseline-syntax
     (agent-scheme-session--syntax-current-names
      (agent-scheme--eval-context-syntax-environment context))
     :project-root project-root
     :memory (agent-scheme-session--option options :memory nil)
     :handles nil
     :transcript nil
     :recent-events nil
     :snapshots nil
     :capability-grants capability-grants
     :skill-activations
     (agent-scheme-session--option options :skill-activations nil)
     :locked-by-job nil
     :parent-id (agent-scheme-session--option options :parent-id nil)
     :forked-from (agent-scheme-session--option options :forked-from nil)
     :created-at timestamp
     :updated-at timestamp)))

(defun agent-scheme-session-datum (session)
  "Return SESSION as a Scheme-readable datum."
  (append
   (list
    (agent-scheme-session--symbol "session")
    (agent-scheme-session--field
     "id" (agent-scheme-session--symbol (agent-scheme-session-id session)))
    (agent-scheme-session--field
     "scope" (agent-scheme-session--symbol
              (agent-scheme-session-scope session)))
    (agent-scheme-session--field
     "status" (agent-scheme-session--symbol
               (agent-scheme-session-status session))))
   (when (agent-scheme-session-locked-by-job session)
     (list (agent-scheme-session--field
            "locked-by-job"
            (agent-scheme-session--symbol
             (agent-scheme-session-locked-by-job session)))))
   (when (agent-scheme-session-project-root session)
     (list (agent-scheme-session--field
            "project-root" (agent-scheme-session-project-root session))))
   (when (agent-scheme-session-parent-id session)
     (list (agent-scheme-session--field
            "parent-id"
            (agent-scheme-session--symbol
             (agent-scheme-session-parent-id session)))))
   (when (agent-scheme-session-forked-from session)
     (list (agent-scheme-session--field
            "forked-from"
            (agent-scheme-session--symbol
             (agent-scheme-session-forked-from session)))))
   (list
    (agent-scheme-session--field
     "imports" (agent-scheme-session--session-imports session))
    (agent-scheme-session--field
     "definitions"
     (agent-scheme-session--name-list-datum
      (agent-scheme-session--session-definitions session)))
    (agent-scheme-session--field
     "macros"
     (agent-scheme-session--name-list-datum
      (agent-scheme-session--session-macros session)))
    (agent-scheme-session--field "memory"
                                  (agent-scheme-session-memory session))
    (agent-scheme-session--field "handles"
                                  (agent-scheme-session-handles session))
    (agent-scheme-session--field
     "capability-grants"
     (agent-scheme-session-capability-grants session))
    (agent-scheme-session--field
     "skill-activations"
     (agent-scheme-session-skill-activations session))
    (agent-scheme-session--field "transcript"
                                  (agent-scheme-session-transcript session))
    (agent-scheme-session--field "recent-events"
                                  (agent-scheme-session-recent-events session))
    (agent-scheme-session--field
     "snapshots"
     (mapcar
      (lambda (snapshot)
        (cadr (cadr snapshot)))
      (agent-scheme-session-snapshots session)))
    (agent-scheme-session--field "created-at"
                                  (agent-scheme-session-created-at session))
    (agent-scheme-session--field "updated-at"
                                  (agent-scheme-session-updated-at session)))
   (when (agent-scheme-session-retired-at session)
     (list (agent-scheme-session--field
            "retired-at" (agent-scheme-session-retired-at session))))
   (when (agent-scheme-session-failure session)
     (list (agent-scheme-session--field
            "failure" (agent-scheme-session-failure session))))))

;;;###autoload
(defun agent-scheme-session-create! (scope &optional options)
  "Create a session in SCOPE using OPTIONS and return its datum."
  (let ((session (agent-scheme-session--register!
                  (agent-scheme-session--make scope options))))
    (agent-scheme-audit-record
     'session-lifecycle
     `((category . agent-session)
       (operation . "session-create!")
       (session . ,(agent-scheme-session--symbol
                    (agent-scheme-session-id session)))
       (scope . ,(agent-scheme-session-scope session))
       (to . ,(agent-scheme-session-status session))
       (decision . completed)))
    (agent-scheme-session-datum session)))

;;;###autoload
(defun agent-scheme-session-ref (id)
  "Return the session datum for ID, or nil when it is unknown."
  (when-let ((session (agent-scheme-session--maybe id)))
    (agent-scheme-session-datum session)))

;;;###autoload
(defun agent-scheme-session-list (&optional scope)
  "Return known session datums, optionally filtered by SCOPE."
  (let ((normalized-scope (and scope (agent-scheme-session--scope scope)))
        sessions)
    (maphash
     (lambda (_id session)
       (when (or (not normalized-scope)
                 (eq (agent-scheme-session-scope session) normalized-scope))
         (push session sessions)))
     agent-scheme--session-registry)
    (mapcar #'agent-scheme-session-datum
            (sort sessions
                  (lambda (left right)
                    (string< (agent-scheme-session-id left)
                             (agent-scheme-session-id right)))))))

(defun agent-scheme-session--datum-field-value (datum name)
  "Return field NAME from public session DATUM, or nil."
  (when (and (consp datum)
             (agent-scheme-symbol-p (car datum))
             (equal (agent-scheme-symbol-name (car datum)) "session"))
    (cadr
     (seq-find
      (lambda (field)
        (and (consp field)
             (agent-scheme-symbol-p (car field))
             (equal (agent-scheme-symbol-name (car field)) name)))
      (cdr datum)))))

(defun agent-scheme-session--datum-p (datum)
  "Return non-nil when DATUM is a public session record."
  (and (consp datum)
       (agent-scheme-symbol-p (car datum))
       (equal (agent-scheme-symbol-name (car datum)) "session")))

;;;###autoload
(defun agent-scheme-session-handle-list (session-or-id)
  "Return handles owned by SESSION-OR-ID after stale cleanup."
  (cond
   ((agent-scheme-session-p session-or-id)
    (unless (memq (agent-scheme-session-status session-or-id)
                  '(retired collectable))
      (agent-scheme-session--cleanup-handles session-or-id))
    (agent-scheme-session-handles session-or-id))
   ((agent-scheme-session--datum-p session-or-id)
    (agent-scheme-session--datum-field-value session-or-id "handles"))
   (t
    (let ((session (agent-scheme-session--require session-or-id)))
      (unless (memq (agent-scheme-session-status session) '(retired collectable))
        (agent-scheme-session--cleanup-handles session))
      (agent-scheme-session-handles session)))))

;;;###autoload
(defun agent-scheme-session-suspend! (id)
  "Suspend session ID and return its updated datum."
  (let ((session (agent-scheme-session--require id)))
    (when (memq (agent-scheme-session-status session) '(retired collectable))
      (signal 'agent-scheme-session-error
              (list "retired sessions cannot be suspended")))
    (agent-scheme-session-datum
     (agent-scheme-session--transition!
      session 'suspended "session-suspend!"))))

;;;###autoload
(defun agent-scheme-session-resume! (id)
  "Resume session ID and return its updated datum."
  (let ((session (agent-scheme-session--require id)))
    (when (memq (agent-scheme-session-status session) '(retired collectable))
      (signal 'agent-scheme-session-error
              (list "retired sessions cannot be resumed")))
    (setf (agent-scheme-session-failure session) nil)
    (agent-scheme-session-datum
     (agent-scheme-session--transition!
      session 'active "session-resume!"))))

(defun agent-scheme-session--snapshot-id (options)
  "Return snapshot id from OPTIONS or a generated id."
  (let ((id (agent-scheme-session--option options :id nil)))
    (if id
        (agent-scheme-session--name id "snapshot id")
      (agent-scheme-session--generated-snapshot-id))))

;;;###autoload
(defun agent-scheme-session-snapshot! (id &optional options)
  "Snapshot session ID using OPTIONS and return a Scheme-readable record."
  (let* ((session (agent-scheme-session--require id))
         (snapshot-id (agent-scheme-session--snapshot-id options))
         (stale-handles (agent-scheme-session--cleanup-handles session))
         (snapshot
          (list
           (agent-scheme-session--symbol "session-snapshot")
           (agent-scheme-session--field
            "id" (agent-scheme-session--symbol snapshot-id))
           (agent-scheme-session--field
           "source-session"
           (agent-scheme-session--symbol (agent-scheme-session-id session)))
           (agent-scheme-session--field "scope"
                                        (agent-scheme-session--symbol
                                         (agent-scheme-session-scope session)))
           (agent-scheme-session--field "status"
                                        (agent-scheme-session--symbol
                                         (agent-scheme-session-status
                                          session)))
           (agent-scheme-session--field
            "imports" (agent-scheme-session--session-imports session))
           (agent-scheme-session--field
            "definitions"
            (agent-scheme-session--name-list-datum
             (agent-scheme-session--session-definitions session)))
           (agent-scheme-session--field
            "macros"
            (agent-scheme-session--name-list-datum
             (agent-scheme-session--session-macros session)))
           (agent-scheme-session--field "memory"
                                        (agent-scheme-session-memory session))
           (agent-scheme-session--field
            "capability-grants"
            (agent-scheme-session-capability-grants session))
           (agent-scheme-session--field
            "skill-activations"
            (agent-scheme-session-skill-activations session))
           (agent-scheme-session--field
            "handles" (agent-scheme-session-handles session))
           (agent-scheme-session--field "stale-handles" stale-handles)
           (agent-scheme-session--field
            "transcript" (agent-scheme-session-transcript session))
           (agent-scheme-session--field
            "recent-events" (agent-scheme-session-recent-events session))
           (agent-scheme-session--field
            "restores"
            (agent-scheme-session--name-list-datum
             (mapcar #'symbol-name agent-scheme-session-restored-fields)))
           (agent-scheme-session--field
            "revalidates"
            (agent-scheme-session--name-list-datum
             (mapcar #'symbol-name agent-scheme-session-revalidated-fields)))
           (agent-scheme-session--field
            "never-restore"
            (agent-scheme-session--name-list-datum
             (mapcar #'symbol-name
                     agent-scheme-session-never-restored-fields)))
           (agent-scheme-session--field
            "created-at" (agent-scheme-session--timestamp)))))
    (push snapshot (agent-scheme-session-snapshots session))
    (agent-scheme-session--set-updated! session)
    (agent-scheme-audit-record
     'session-lifecycle
     `((category . agent-session)
       (operation . "session-snapshot!")
       (session . ,(agent-scheme-session--symbol
                    (agent-scheme-session-id session)))
       (snapshot . ,(agent-scheme-session--symbol snapshot-id))
       (decision . completed)))
    snapshot))

(defun agent-scheme-session--copy-hash-table (table)
  "Return a shallow copy of hash TABLE."
  (let ((copy (make-hash-table :test (hash-table-test table))))
    (maphash (lambda (key value) (puthash key value copy)) table)
    copy))

(defun agent-scheme-session--copy-environment (environment)
  "Return a cell-copy of ENVIRONMENT and its parents."
  (when environment
    (let ((copy (agent-scheme-make-empty-environment
                 (agent-scheme-session--copy-environment
                  (agent-scheme--environment-parent environment)))))
      (maphash
       (lambda (name cell)
         (puthash name
                  (agent-scheme--make-cell (agent-scheme--cell-value cell))
                  (agent-scheme--environment-bindings copy)))
       (agent-scheme--environment-bindings environment))
      (setf (agent-scheme--environment-imported-bindings copy)
            (agent-scheme-session--copy-hash-table
             (agent-scheme--environment-imported-bindings environment)))
      copy)))

(defun agent-scheme-session--copy-syntax-environment (environment)
  "Return a shallow binding copy of syntax ENVIRONMENT and its parents."
  (when environment
    (agent-scheme--make-syntax-environment
     (agent-scheme-session--copy-hash-table
      (agent-scheme--syntax-environment-bindings environment))
     (agent-scheme-session--copy-syntax-environment
      (agent-scheme--syntax-environment-parent environment))
     (agent-scheme-session--copy-hash-table
      (agent-scheme--syntax-environment-imported-bindings environment)))))

(defun agent-scheme-session--copy-context (context environment)
  "Return a context copy based on CONTEXT for forked ENVIRONMENT."
  (let ((copy
         (agent-scheme--make-eval-context
          :steps 0
          :maximum-steps
          (agent-scheme--eval-context-maximum-steps context)
          :maximum-value-nodes
          (agent-scheme--eval-context-maximum-value-nodes context)
          :host-callbacks 0
          :maximum-host-callbacks
          (agent-scheme--eval-context-maximum-host-callbacks context)
          :events nil
          :event-count 0
          :maximum-events
          (agent-scheme--eval-context-maximum-events context)
          :maximum-event-nodes
          (agent-scheme--eval-context-maximum-event-nodes context)
          :event-hook nil
          :syntax-environment
          (agent-scheme-session--copy-syntax-environment
           (agent-scheme--eval-context-syntax-environment context))
          :libraries
          (agent-scheme-session--copy-hash-table
           (agent-scheme--eval-context-libraries context))
          :include-paths
          (copy-sequence
           (agent-scheme--eval-context-include-paths context))
          :include-directory
          (agent-scheme--eval-context-include-directory context)
          :file-paths
          (copy-sequence
           (agent-scheme--eval-context-file-paths context))
          :policy-actions
          (copy-sequence
           (agent-scheme--eval-context-policy-actions context))
          :policy-confirmation-function
          (agent-scheme--eval-context-policy-confirmation-function context)
          :capability-grants
          (copy-tree (agent-scheme--eval-context-capability-grants context))
          :active-capability-grants nil
          :current-input-port
          (agent-scheme--eval-context-current-input-port context)
          :current-output-port
          (agent-scheme--eval-context-current-output-port context)
          :current-error-port
          (agent-scheme--eval-context-current-error-port context)
          :current-error nil
          :session-id
          (agent-scheme--eval-context-session-id context)
          :request-id
          (agent-scheme--eval-context-request-id context)
          :request
          (agent-scheme--eval-context-request context)
          :focus
          (agent-scheme--eval-context-focus context)
          :region-context
          (agent-scheme--eval-context-region-context context)
          :buffer-context
          (agent-scheme--eval-context-buffer-context context)
          :project-context
          (agent-scheme--eval-context-project-context context)
          :conversation-summary
          (agent-scheme--eval-context-conversation-summary context)
          :job-id nil
          :cancel-requested nil
          :interrupt-reason nil
          :interaction-environment environment
          :base-syntax-installed
          (agent-scheme--eval-context-base-syntax-installed context)
          :exception-handlers nil
          :dynamic-winds nil)))
    copy))

(defun agent-scheme-session--sync-capability-grants! (session)
  "Copy SESSION context grants back to the session record."
  (setf (agent-scheme-session-capability-grants session)
        (agent-scheme--eval-context-capability-grants
         (agent-scheme-session-context session))))

;;;###autoload
(defun agent-scheme-session-fork! (id &optional options)
  "Fork session ID using OPTIONS and return the new session datum."
  (let* ((source (agent-scheme-session--require id))
         (_stale-handles (agent-scheme-session--cleanup-handles source))
         (fork-id-value (agent-scheme-session--option options :id nil))
         (fork-id
          (if fork-id-value
              (agent-scheme-session--name fork-id-value "fork session id")
            (agent-scheme-session--generated-id
             (agent-scheme-session-scope source))))
         (environment
          (agent-scheme-session--copy-environment
           (agent-scheme-session-environment source)))
         (context
          (agent-scheme-session--copy-context
           (agent-scheme-session-context source)
           environment))
         (timestamp (agent-scheme-session--timestamp))
         (fork
          (agent-scheme--make-session
           :id fork-id
           :scope (agent-scheme-session-scope source)
           :status 'new
           :environment environment
           :context context
           :baseline-bindings
           (copy-sequence (agent-scheme-session-baseline-bindings source))
           :baseline-syntax
           (copy-sequence (agent-scheme-session-baseline-syntax source))
           :project-root (agent-scheme-session-project-root source)
           :memory (copy-tree (agent-scheme-session-memory source))
           :handles (copy-sequence (agent-scheme-session-handles source))
           :transcript
           (copy-tree (agent-scheme-session-transcript source))
           :recent-events
           (copy-tree (agent-scheme-session-recent-events source))
           :snapshots nil
           :capability-grants
           (copy-tree (agent-scheme-session-capability-grants source))
           :skill-activations
           (copy-tree (agent-scheme-session-skill-activations source))
           :locked-by-job nil
           :parent-id (agent-scheme-session-id source)
           :forked-from (agent-scheme-session-id source)
           :created-at timestamp
           :updated-at timestamp)))
    (agent-scheme-session--register! fork)
    (agent-scheme-audit-record
     'session-lifecycle
     `((category . agent-session)
       (operation . "session-fork!")
       (session . ,(agent-scheme-session--symbol
                    (agent-scheme-session-id source)))
       (fork . ,(agent-scheme-session--symbol fork-id))
       (decision . completed)))
    (agent-scheme-session-datum fork)))

;;;###autoload
(defun agent-scheme-session-retire! (id)
  "Retire session ID, release handles, and return its updated datum."
  (let ((session (agent-scheme-session--require id)))
    (agent-scheme-session--refresh-handles session)
    (let ((released
           (agent-scheme-capability-release-handles
            (agent-scheme-session-handles session))))
      (setf (agent-scheme-session-handles session) nil)
      (setf (agent-scheme-session-retired-at session)
            (agent-scheme-session--timestamp))
      (agent-scheme-session-datum
       (agent-scheme-session--transition!
        session 'retired "session-retire!"
        `((released-handles . ,released)))))))

;;;###autoload
(defun agent-scheme-session-clear! ()
  "Clear all registered sessions and release their tracked handles."
  (maphash
   (lambda (_id session)
     (agent-scheme-capability-release-handles
      (agent-scheme-session-handles session)))
   agent-scheme--session-registry)
  (clrhash agent-scheme--session-registry)
  (setq agent-scheme--next-session-number 0)
  (setq agent-scheme--next-snapshot-number 0)
  (setq agent-scheme--session-current-job-id nil)
  agent-scheme-unspecified)

(defun agent-scheme-session--audit-start-count ()
  "Return the current audit log length."
  (length (agent-scheme-audit-recent-entries)))

(defun agent-scheme-session--new-audit-entries (start-count)
  "Return audit entries recorded since START-COUNT in chronological order."
  (let* ((entries (agent-scheme-audit-recent-entries))
         (newest-first (cl-subseq entries 0
                                  (max 0 (- (length entries) start-count)))))
    (nreverse newest-first)))

(defun agent-scheme-session--agent-event-p (entry)
  "Return non-nil when ENTRY is an agent event audit datum."
  (let ((event-field
         (seq-find
          (lambda (field)
            (and (consp field)
                 (agent-scheme-symbol-p (car field))
                 (equal (agent-scheme-symbol-name (car field)) "event")))
          (cdr-safe entry))))
    (and event-field
         (agent-scheme-symbol-p (cadr event-field))
         (equal (agent-scheme-symbol-name (cadr event-field))
                "agent-event"))))

(defun agent-scheme-session--policy-datum (decision)
  "Return a Scheme-readable pure-evaluation policy datum for DECISION."
  (list
   (list (agent-scheme-session--symbol "category")
         (agent-scheme-session--symbol "pure-r7rs"))
   (list (agent-scheme-session--symbol "decision")
         (agent-scheme-session--symbol decision))))

(defun agent-scheme-session--append-transcript-event! (session event)
  "Append transcript EVENT to SESSION using transcript retention policy."
  (setf (agent-scheme-session-transcript session)
        (agent-scheme-transcript-rotate
         (append (agent-scheme-session-transcript session) (list event))))
  event)

(defun agent-scheme-session--record-eval-start! (session source)
  "Record the start of SESSION evaluation of SOURCE."
  (agent-scheme-session--append-transcript-event!
   session
   (agent-scheme-transcript-event
    'eval-start
    `((session . ,(agent-scheme-session--symbol
                   (agent-scheme-session-id session)))
      (form . ,source)
      (policy . ,(agent-scheme-session--policy-datum 'requested))))))

(defun agent-scheme-session--prepare-eval! (session)
  "Mark SESSION active and reset per-evaluation counters."
  (when (memq (agent-scheme-session-status session) '(retired collectable))
    (signal 'agent-scheme-session-error
            (list "retired sessions cannot be evaluated")))
  (when-let ((locked-by (agent-scheme-session-locked-by-job session)))
    (unless (equal locked-by agent-scheme--session-current-job-id)
      (signal 'agent-scheme-session-error
              (list (format "session is locked by job: %s" locked-by)))))
  (let ((context (agent-scheme-session-context session)))
    (setf (agent-scheme--eval-context-steps context) 0)
    (setf (agent-scheme--eval-context-host-callbacks context) 0)
    (setf (agent-scheme--eval-context-events context) nil)
    (setf (agent-scheme--eval-context-event-count context) 0)
    (setf (agent-scheme--eval-context-capability-grants context)
          (agent-scheme-session-capability-grants session))
    (setf (agent-scheme--eval-context-active-capability-grants context) nil)
    (setf (agent-scheme--eval-context-current-error context) nil)
    (setf (agent-scheme--eval-context-session-id context)
          (agent-scheme-session-id session))
    (setf (agent-scheme--eval-context-job-id context)
          agent-scheme--session-current-job-id)
    (setf (agent-scheme--eval-context-cancel-requested context) nil)
    (setf (agent-scheme--eval-context-interrupt-reason context) nil)
    (unless agent-scheme--session-current-job-id
      (setf (agent-scheme--eval-context-event-hook context) nil))
    (setf (agent-scheme--eval-context-interaction-environment context)
          (agent-scheme-session-environment session)))
  (agent-scheme-session--transition! session 'active "session-eval-start!"))

(defun agent-scheme-session--record-eval-success!
    (session source value start-count)
  "Record successful SESSION evaluation of SOURCE producing VALUE."
  (agent-scheme-session--refresh-handles session value)
  (let* ((new-entries (agent-scheme-session--new-audit-entries start-count))
         (events (agent-scheme-redact
                  (seq-filter #'agent-scheme-session--agent-event-p
                              new-entries)
                  'transcript))
         (entry
          (agent-scheme-transcript-event
           'eval-end
           `((session . ,(agent-scheme-session--symbol
                          (agent-scheme-session-id session)))
             (form . ,source)
             (status . ok)
             (result . ,(agent-scheme-value->external value))
             (yields ,events)
             (policy . ,(agent-scheme-session--policy-datum 'allowed))))))
    (setf (agent-scheme-session-recent-events session) events)
    (agent-scheme-session--append-transcript-event! session entry)
    (setf (agent-scheme-session-failure session) nil)
    (agent-scheme-audit-record
     'session-evaluation
     `((category . pure-r7rs)
       (operation . "session-evaluate")
       (session . ,(agent-scheme-session--symbol
                    (agent-scheme-session-id session)))
       (input-form . ,source)
       (events . ,events)
       (decision . allowed)
       (result . ,(agent-scheme-value->external value))))
    (agent-scheme-session--transition! session 'idle "session-eval-finish!"))
  value)

(defun agent-scheme-session--record-eval-error!
    (session source condition start-count)
  "Record failed SESSION evaluation of SOURCE with CONDITION."
  (let* ((new-entries (agent-scheme-session--new-audit-entries start-count))
         (events (agent-scheme-redact
                  (seq-filter #'agent-scheme-session--agent-event-p
                              new-entries)
                  'transcript))
         (message (error-message-string condition))
         (transcript-status
          (pcase (car-safe condition)
            ('agent-scheme-cancelled-error "cancelled")
            ('agent-scheme-interrupt-error "interrupted")
            (_ "error")))
         (audit-decision
          (pcase (car-safe condition)
            ('agent-scheme-cancelled-error 'cancelled)
            ('agent-scheme-interrupt-error 'interrupted)
            (_ 'error)))
         (session-status
          (if (eq (car-safe condition) 'agent-scheme-cancelled-error)
              'idle
            'failed))
         (transition-operation
          (pcase (car-safe condition)
            ('agent-scheme-cancelled-error "session-eval-cancelled!")
            ('agent-scheme-interrupt-error "session-eval-interrupted!")
            (_ "session-eval-failed!")))
         (entry
          (agent-scheme-transcript-event
           'eval-error
           `((session . ,(agent-scheme-session--symbol
                          (agent-scheme-session-id session)))
             (form . ,source)
             (status . ,(intern transcript-status))
             (error . ,message)
             (yields ,events)
             (policy . ,(agent-scheme-session--policy-datum
                         audit-decision))))))
    (setf (agent-scheme-session-recent-events session) events)
    (agent-scheme-session--append-transcript-event! session entry)
    (setf (agent-scheme-session-failure session) message)
    (agent-scheme-audit-record
     'session-evaluation
     `((category . pure-r7rs)
       (operation . "session-evaluate")
       (session . ,(agent-scheme-session--symbol
                    (agent-scheme-session-id session)))
       (input-form . ,source)
       (events . ,events)
       (decision . ,audit-decision)
       (error . ,message)))
    (agent-scheme-session--transition!
     session session-status transition-operation))
  condition)

(defun agent-scheme-session--primitive-create (arguments _context)
  "Primitive session-create! over ARGUMENTS."
  (agent-scheme-session-create!
   (car arguments)
   (if (cdr arguments)
       (agent-scheme-session--primitive-options (cadr arguments))
     nil)))

(defun agent-scheme-session--primitive-ref (arguments _context)
  "Primitive session-ref over ARGUMENTS."
  (or (agent-scheme-session-ref (car arguments))
      agent-scheme-false))

(defun agent-scheme-session--primitive-list (arguments _context)
  "Primitive session-list over ARGUMENTS."
  (if arguments
      (agent-scheme-session-list (car arguments))
    (agent-scheme-session-list)))

(defun agent-scheme-session--primitive-handles (arguments _context)
  "Primitive session-handles over ARGUMENTS."
  (agent-scheme-session-handle-list (car arguments)))

(defun agent-scheme-session--primitive-suspend (arguments _context)
  "Primitive session-suspend! over ARGUMENTS."
  (agent-scheme-session-suspend! (car arguments)))

(defun agent-scheme-session--primitive-resume (arguments _context)
  "Primitive session-resume! over ARGUMENTS."
  (agent-scheme-session-resume! (car arguments)))

(defun agent-scheme-session--primitive-snapshot (arguments _context)
  "Primitive session-snapshot! over ARGUMENTS."
  (agent-scheme-session-snapshot!
   (car arguments)
   (if (cdr arguments)
       (agent-scheme-session--primitive-options (cadr arguments))
     nil)))

(defun agent-scheme-session--primitive-fork (arguments _context)
  "Primitive session-fork! over ARGUMENTS."
  (agent-scheme-session-fork!
   (car arguments)
   (if (cdr arguments)
       (agent-scheme-session--primitive-options (cadr arguments))
     nil)))

(defun agent-scheme-session--primitive-retire (arguments _context)
  "Primitive session-retire! over ARGUMENTS."
  (agent-scheme-session-retire! (car arguments)))

;;;###autoload
(defun agent-scheme-session-primitive-specs ()
  "Return primitive specs for the `(agent session)' library."
  `(("session-create!" ,#'agent-scheme-session--primitive-create 1 2)
    ("session-ref" ,#'agent-scheme-session--primitive-ref 1 1)
    ("session-list" ,#'agent-scheme-session--primitive-list 0 1)
    ("session-handles" ,#'agent-scheme-session--primitive-handles 1 1)
    ("session-suspend!" ,#'agent-scheme-session--primitive-suspend 1 1)
    ("session-resume!" ,#'agent-scheme-session--primitive-resume 1 1)
    ("session-snapshot!" ,#'agent-scheme-session--primitive-snapshot 1 2)
    ("session-fork!" ,#'agent-scheme-session--primitive-fork 1 2)
    ("session-retire!" ,#'agent-scheme-session--primitive-retire 1 1)))

(provide 'agent-scheme-session)

;;; agent-scheme-session.el ends here
