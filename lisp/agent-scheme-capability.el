;;; agent-scheme-capability.el --- Emacs capability primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; Host adapter primitives for Emacs capability libraries.  Scheme programs
;; receive opaque handles; live Emacs objects stay in a private side table
;; owned by this module.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-policy)

(cl-defstruct (agent-scheme--handle-entry
               (:constructor agent-scheme--make-handle-entry (kind object))
               (:copier nil))
  "Private host object registered behind an opaque Agent Scheme handle."
  kind object)

(defvar agent-scheme--handle-registry (make-hash-table :test #'equal)
  "Private table from opaque handle ids to live host objects.")

(defvar agent-scheme--next-handle-number 0
  "Next numeric suffix for generated opaque handle ids.")

(defvar agent-scheme--emacs-capability-preauthorized nil
  "Non-nil while a wrapped Emacs capability has already passed policy.")

(defvar agent-scheme--emacs-capability-result-fields nil
  "Additional Scheme-readable audit fields for the active capability call.")

(defconst agent-scheme--emacs-capability-manifest-specs
  '((:name "emacs-current-buffer" :library "(emacs buffer)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-emacs-current-buffer
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer handle))
    (:name "buffer-name" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "buffer-file-name" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-file-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "buffer-major-mode" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-major-mode
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "buffer-text" :library "(emacs buffer)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-text
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer text))
    (:name "buffer-insert!" :library "(emacs buffer edit)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-insert!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-delete!" :library "(emacs buffer edit)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-delete!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-replace!" :library "(emacs buffer edit)"
     :minimum-arity 4 :maximum-arity 4
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-replace!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-save!" :library "(emacs buffer edit)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-save!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :test-categories (emacs buffer edit mutation file))
    (:name "buffer-point" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-point
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "emacs-buffer-list" :library "(emacs buffer)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-emacs-buffer-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer handle))
    (:name "emacs-window-list" :library "(emacs window)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-window
     :emacs-hook agent-scheme--primitive-emacs-window-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs window handle))
    (:name "window-frame" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-window
     :emacs-hook agent-scheme--primitive-window-frame
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs window frame handle))
    (:name "emacs-current-frame" :library "(emacs frame)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-frame
     :emacs-hook agent-scheme--primitive-emacs-current-frame
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs frame handle))
    (:name "emacs-frame-list" :library "(emacs frame)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-frame
     :emacs-hook agent-scheme--primitive-emacs-frame-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs frame handle))
    (:name "frame-name" :library "(emacs frame)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-frame
     :emacs-hook agent-scheme--primitive-frame-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs frame))
    (:name "emacs-current-project" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-project
     :emacs-hook agent-scheme--primitive-emacs-current-project
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs project handle))
    (:name "project-root" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-project
     :emacs-hook agent-scheme--primitive-project-root
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs project))
    (:name "emacs-process-list" :library "(emacs process)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-emacs-process-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs process handle))
    (:name "process-name" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs process))
    (:name "process-status" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-status
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs process))
    (:name "process-buffer" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-buffer
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs process buffer handle))
    (:name "command-doc" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook agent-scheme--primitive-command-doc
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation))
    (:name "function-doc" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook agent-scheme--primitive-function-doc
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation))
    (:name "variable-info" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook agent-scheme--primitive-variable-info
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation variable)))
  "Manifest metadata for Emacs capability primitives.")

(defconst agent-scheme--emacs-capability-library-keys
  '("(emacs buffer)"
    "(emacs buffer edit)"
    "(emacs command)"
    "(emacs frame)"
    "(emacs process)"
    "(emacs project)"
    "(emacs window)")
  "Recognized Emacs capability library keys.")

(defun agent-scheme-emacs-capability-binding-specs ()
  "Return manifest metadata for Emacs capability primitive bindings."
  agent-scheme--emacs-capability-manifest-specs)

(defun agent-scheme-emacs-capability-library-keys ()
  "Return importable Emacs capability library keys."
  agent-scheme--emacs-capability-library-keys)

(defun agent-scheme-emacs-capability-primitive-specs (library)
  "Return primitive registration specs for Emacs capability LIBRARY."
  (mapcar
   (lambda (spec)
     (let ((name (plist-get spec :name)))
       (list name
             (agent-scheme--wrap-emacs-capability
              name
              (plist-get spec :emacs-hook))
             (plist-get spec :minimum-arity)
             (plist-get spec :maximum-arity))))
   (seq-filter
    (lambda (spec)
      (equal (plist-get spec :library) library))
    agent-scheme--emacs-capability-manifest-specs)))

(defun agent-scheme--emacs-capability-manifest-spec (name)
  "Return manifest metadata for Emacs capability NAME."
  (seq-find
   (lambda (spec)
     (equal (plist-get spec :name) name))
   agent-scheme--emacs-capability-manifest-specs))

(defun agent-scheme--emacs-capability-policy-category (spec)
  "Return the policy category for Emacs capability SPEC."
  (or (and spec (plist-get spec :policy-category))
      'emacs-read-only))

(defun agent-scheme--authorize-emacs-capability
    (name arguments context)
  "Authorize Emacs capability NAME with ARGUMENTS in CONTEXT."
  (unless agent-scheme--emacs-capability-preauthorized
    (let ((spec (agent-scheme--emacs-capability-manifest-spec name)))
      (agent-scheme-policy-authorize
       (agent-scheme--emacs-capability-policy-category spec)
       name
       `((library . ,(and spec (plist-get spec :library)))
         (capability . ,name)
         (arguments . ,arguments))
       context
       'capability-call))))

(defun agent-scheme--capability-result-string (result)
  "Return a printable audit string for capability RESULT."
  (condition-case _
      (agent-scheme-value->external result)
    (error "#<unprintable>")))

(defun agent-scheme--audit-emacs-capability-result
    (name arguments outcome fields)
  "Audit Emacs capability NAME with ARGUMENTS producing OUTCOME."
  (let ((spec (agent-scheme--emacs-capability-manifest-spec name)))
    (agent-scheme-audit-record
     'capability-result
     (append
      `((category . ,(agent-scheme--emacs-capability-policy-category spec))
        (operation . ,name)
        (library . ,(and spec (plist-get spec :library)))
        (capability . ,name)
        (arguments . ,arguments)
        (outcome . ,outcome)
        (decision . ,(if (eq outcome 'success) 'completed 'errored)))
      fields))))

(defun agent-scheme--add-emacs-capability-result-fields (fields)
  "Add FIELDS to the active Emacs capability result audit entry."
  (setq agent-scheme--emacs-capability-result-fields
        (append agent-scheme--emacs-capability-result-fields fields)))

(defun agent-scheme--call-emacs-capability
    (name function arguments context)
  "Call Emacs capability FUNCTION and audit its outcome."
  (agent-scheme--authorize-emacs-capability name arguments context)
  (let ((agent-scheme--emacs-capability-result-fields nil))
    (condition-case condition
        (let ((result
               (let ((agent-scheme--emacs-capability-preauthorized t))
                 (funcall function arguments context))))
          (agent-scheme--audit-emacs-capability-result
           name
           arguments
           'success
           (append
            agent-scheme--emacs-capability-result-fields
            `((result . ,(agent-scheme--capability-result-string result)))))
          result)
      (error
       (agent-scheme--audit-emacs-capability-result
        name
        arguments
        'error
        (append
         agent-scheme--emacs-capability-result-fields
         `((error . ,(error-message-string condition)))))
       (signal (car condition) (cdr condition))))))

(defun agent-scheme--wrap-emacs-capability (name function)
  "Return a policy and outcome-auditing wrapper for capability FUNCTION."
  (lambda (arguments context)
    (agent-scheme--call-emacs-capability name function arguments context)))

(defun agent-scheme--register-handle (kind object)
  "Register live host OBJECT of KIND and return an opaque Scheme handle."
  (let ((id (format "h-%d" (cl-incf agent-scheme--next-handle-number))))
    (puthash id
             (agent-scheme--make-handle-entry kind object)
             agent-scheme--handle-registry)
    (agent-scheme--make-handle kind id)))

(defun agent-scheme--scheme-boolean-value (value)
  "Return the canonical Scheme boolean for host truth VALUE."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme--scheme-integer (value)
  "Return exact integer datum for host integer VALUE."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme--scheme-symbol (symbol)
  "Return Agent Scheme symbol datum for host SYMBOL."
  (agent-scheme--intern-symbol (symbol-name symbol)))

(defun agent-scheme--maybe-string (value)
  "Return VALUE as a copied string datum, or #f when VALUE is nil."
  (if value (substring-no-properties value) agent-scheme-false))

(defun agent-scheme--capability-exact-integer (datum description)
  "Return DATUM as a host exact integer for DESCRIPTION."
  (unless (and (agent-scheme-number-p datum)
               (eq (agent-scheme-number-kind datum) 'integer)
               (eq (agent-scheme-number-exactness datum) 'exact))
    (agent-scheme--eval-error
     "%s expected an exact integer, got %s"
     description
     (agent-scheme-value->external datum)))
  (agent-scheme-number-value datum))

(defun agent-scheme--capability-string (datum description)
  "Return DATUM as a host string for DESCRIPTION."
  (unless (stringp datum)
    (agent-scheme--eval-error
     "%s expected a string, got %s"
     description
     (agent-scheme-value->external datum)))
  (substring-no-properties datum))

(defun agent-scheme--capability-name-symbol (datum description)
  "Return DATUM as an existing Emacs symbol for DESCRIPTION, or nil."
  (let ((name
         (cond
          ((agent-scheme-symbol-p datum)
           (agent-scheme-symbol-name datum))
          ((stringp datum)
           datum)
          (t
           (agent-scheme--eval-error
            "%s expected a symbol or string, got %s"
            description
            (agent-scheme-value->external datum))))))
    (intern-soft name)))

(defun agent-scheme--handle-entry-for (value kind description)
  "Return private registry entry for handle VALUE of KIND."
  (unless (agent-scheme-handle-p value)
    (agent-scheme--eval-error
     "%s expected %s handle, got %s"
     description kind (agent-scheme-value->external value)))
  (unless (eq (agent-scheme-handle-kind value) kind)
    (agent-scheme--eval-error
     "%s expected %s handle, got %s handle"
     description kind (agent-scheme-handle-kind value)))
  (let ((entry (gethash (agent-scheme-handle-id value)
                        agent-scheme--handle-registry)))
    (unless (and entry (eq (agent-scheme--handle-entry-kind entry) kind))
      (agent-scheme--eval-error
       "unknown %s handle: %s"
       kind (agent-scheme-handle-id value)))
    entry))

;;;###autoload
(defun agent-scheme-capability-handle-known-p (handle)
  "Return non-nil when HANDLE is present in the private registry."
  (and (agent-scheme-handle-p handle)
       (gethash (agent-scheme-handle-id handle)
                agent-scheme--handle-registry)
       t))

(defun agent-scheme-capability--entry-live-p (entry)
  "Return non-nil when ENTRY still points at a live host object."
  (pcase (agent-scheme--handle-entry-kind entry)
    ('buffer
     (buffer-live-p (agent-scheme--handle-entry-object entry)))
    ('window
     (window-live-p (agent-scheme--handle-entry-object entry)))
    ('frame
     (frame-live-p (agent-scheme--handle-entry-object entry)))
    ('process
     (process-live-p (agent-scheme--handle-entry-object entry)))
    ('project
     t)
    (_
     t)))

;;;###autoload
(defun agent-scheme-capability-handle-live-p (handle)
  "Return non-nil when HANDLE names a currently live host object."
  (and (agent-scheme-handle-p handle)
       (let ((entry (gethash (agent-scheme-handle-id handle)
                             agent-scheme--handle-registry)))
         (and entry
              (agent-scheme-capability--entry-live-p entry)))))

;;;###autoload
(defun agent-scheme-capability-release-handle (handle)
  "Release HANDLE from the private registry.
Return non-nil when a registry entry was removed."
  (when (agent-scheme-handle-p handle)
    (let* ((id (agent-scheme-handle-id handle))
           (present (gethash id agent-scheme--handle-registry)))
      (when present
        (remhash id agent-scheme--handle-registry)
        t))))

;;;###autoload
(defun agent-scheme-capability-release-handles (handles)
  "Release every handle in HANDLES and return the removed count."
  (let ((count 0))
    (dolist (handle handles count)
      (when (agent-scheme-capability-release-handle handle)
        (cl-incf count)))))

(defun agent-scheme--live-buffer-for-handle (value description)
  "Return live Emacs buffer for handle VALUE."
  (let ((buffer
         (agent-scheme--handle-entry-object
          (agent-scheme--handle-entry-for value 'buffer description))))
    (unless (buffer-live-p buffer)
      (agent-scheme--eval-error
       "stale buffer handle: %s" (agent-scheme-handle-id value)))
    buffer))

(defun agent-scheme--live-window-for-handle (value description)
  "Return live Emacs window for handle VALUE."
  (let ((window
         (agent-scheme--handle-entry-object
          (agent-scheme--handle-entry-for value 'window description))))
    (unless (window-live-p window)
      (agent-scheme--eval-error
       "stale window handle: %s" (agent-scheme-handle-id value)))
    window))

(defun agent-scheme--live-frame-for-handle (value description)
  "Return live Emacs frame for handle VALUE."
  (let ((frame
         (agent-scheme--handle-entry-object
          (agent-scheme--handle-entry-for value 'frame description))))
    (unless (frame-live-p frame)
      (agent-scheme--eval-error
       "stale frame handle: %s" (agent-scheme-handle-id value)))
    frame))

(defun agent-scheme--project-for-handle (value description)
  "Return registered Emacs project for handle VALUE."
  (agent-scheme--handle-entry-object
   (agent-scheme--handle-entry-for value 'project description)))

(defun agent-scheme--live-process-for-handle (value description)
  "Return live Emacs process for handle VALUE."
  (let ((process
         (agent-scheme--handle-entry-object
          (agent-scheme--handle-entry-for value 'process description))))
    (unless (process-live-p process)
      (agent-scheme--eval-error
       "stale process handle: %s" (agent-scheme-handle-id value)))
    process))

(defun agent-scheme--buffer-handle (buffer)
  "Return an opaque handle for BUFFER."
  (agent-scheme--register-handle 'buffer buffer))

(defun agent-scheme--window-handle (window)
  "Return an opaque handle for WINDOW."
  (agent-scheme--register-handle 'window window))

(defun agent-scheme--frame-handle (frame)
  "Return an opaque handle for FRAME."
  (agent-scheme--register-handle 'frame frame))

(defun agent-scheme--project-handle (project)
  "Return an opaque handle for PROJECT."
  (agent-scheme--register-handle 'project project))

(defun agent-scheme--process-handle (process)
  "Return an opaque handle for PROCESS."
  (agent-scheme--register-handle 'process process))

(defun agent-scheme--primitive-emacs-current-buffer (arguments context)
  "Primitive emacs-current-buffer."
  (agent-scheme--authorize-emacs-capability
   "emacs-current-buffer" arguments context)
  (agent-scheme--buffer-handle (current-buffer)))

(defun agent-scheme--primitive-buffer-name (arguments context)
  "Primitive buffer-name over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-name" arguments context)
  (buffer-name
   (agent-scheme--live-buffer-for-handle (car arguments) "buffer-name")))

(defun agent-scheme--primitive-buffer-file-name (arguments context)
  "Primitive buffer-file-name over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "buffer-file-name" arguments context)
  (agent-scheme--maybe-string
   (buffer-local-value
    'buffer-file-name
    (agent-scheme--live-buffer-for-handle
     (car arguments) "buffer-file-name"))))

(defun agent-scheme--primitive-buffer-major-mode (arguments context)
  "Primitive buffer-major-mode over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "buffer-major-mode" arguments context)
  (agent-scheme--scheme-symbol
   (buffer-local-value
    'major-mode
    (agent-scheme--live-buffer-for-handle
     (car arguments) "buffer-major-mode"))))

(defun agent-scheme--primitive-buffer-point (arguments context)
  "Primitive buffer-point over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "buffer-point" arguments context)
  (agent-scheme--scheme-integer
   (with-current-buffer
       (agent-scheme--live-buffer-for-handle (car arguments) "buffer-point")
     (point))))

(defun agent-scheme--primitive-buffer-text (arguments context)
  "Primitive buffer-text over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "buffer-text" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-text"))
         (start (agent-scheme--capability-exact-integer
                 (cadr arguments) "buffer-text start"))
         (end (agent-scheme--capability-exact-integer
               (caddr arguments) "buffer-text end")))
    (with-current-buffer buffer
      (unless (and (<= (point-min) start)
                   (<= start end)
                   (<= end (point-max)))
        (agent-scheme--eval-error
         "buffer-text range outside buffer: %d..%d" start end))
      (buffer-substring-no-properties start end))))

(defun agent-scheme--check-buffer-range (buffer start end description)
  "Signal unless START and END are a valid range in BUFFER for DESCRIPTION."
  (with-current-buffer buffer
    (unless (and (<= (point-min) start)
                 (<= start end)
                 (<= end (point-max)))
      (agent-scheme--eval-error
       "%s range outside buffer: %d..%d" description start end))))

(defun agent-scheme--check-buffer-position (buffer position description)
  "Signal unless POSITION is valid in BUFFER for DESCRIPTION."
  (with-current-buffer buffer
    (unless (and (<= (point-min) position)
                 (<= position (point-max)))
      (agent-scheme--eval-error
       "%s position outside buffer: %d" description position))))

(defun agent-scheme--buffer-target-file (buffer)
  "Return BUFFER's file name, or nil when BUFFER is not file-backed."
  (buffer-local-value 'buffer-file-name buffer))

(defun agent-scheme--buffer-target-fields (buffer)
  "Return Scheme-readable audit fields describing BUFFER."
  `((target-buffer . ,(buffer-name buffer))
    (target-file . ,(or (agent-scheme--buffer-target-file buffer)
                        agent-scheme-false))))

(defun agent-scheme--internal-buffer-p (buffer)
  "Return non-nil when BUFFER is an internal or special Emacs buffer."
  (let ((name (buffer-name buffer)))
    (or (string-prefix-p " " name)
        (and (> (length name) 1)
             (eq (aref name 0) ?*)
             (eq (aref name (1- (length name))) ?*)))))

(defun agent-scheme--remote-buffer-p (buffer)
  "Return non-nil when BUFFER is backed by a remote file or directory."
  (with-current-buffer buffer
    (or (and buffer-file-name (file-remote-p buffer-file-name))
        (and default-directory (file-remote-p default-directory)))))

(defun agent-scheme--check-buffer-edit-target (buffer operation)
  "Signal unless BUFFER is an ordinary local target for OPERATION."
  (cond
   ((minibufferp buffer)
    (agent-scheme--eval-error
     "%s cannot edit minibuffer: %s" operation (buffer-name buffer)))
   ((agent-scheme--internal-buffer-p buffer)
    (agent-scheme--eval-error
     "%s cannot edit internal buffer: %s" operation (buffer-name buffer)))
   ((agent-scheme--remote-buffer-p buffer)
    (agent-scheme--eval-error
     "%s cannot edit remote buffer: %s" operation (buffer-name buffer)))))

(defun agent-scheme--record-buffer-edit-fields
    (buffer start end before-text after-text)
  "Record audit fields for an edit to BUFFER from START to END."
  (agent-scheme--add-emacs-capability-result-fields
   (append
    (agent-scheme--buffer-target-fields buffer)
    `((region . (,start ,end))
      (before-text . ,before-text)
      (after-text . ,after-text)))))

(defun agent-scheme--apply-buffer-edit
    (buffer start end replacement operation)
  "Apply one transactional BUFFER edit for OPERATION.
The edit replaces START..END with REPLACEMENT, records metadata, and
creates undo boundaries around the atomic change group."
  (agent-scheme--check-buffer-edit-target buffer operation)
  (agent-scheme--check-buffer-range buffer start end operation)
  (let ((before-text
         (with-current-buffer buffer
           (buffer-substring-no-properties start end))))
    (agent-scheme--record-buffer-edit-fields
     buffer start end before-text replacement)
    (with-current-buffer buffer
      (undo-boundary)
      (atomic-change-group
        (delete-region start end)
        (goto-char start)
        (insert replacement))
      (undo-boundary))))

(defun agent-scheme--primitive-buffer-insert! (arguments context)
  "Primitive buffer-insert! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-insert!" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-insert!"))
         (position (agent-scheme--capability-exact-integer
                    (cadr arguments) "buffer-insert! position"))
         (text (agent-scheme--capability-string
                (caddr arguments) "buffer-insert! text")))
    (agent-scheme--check-buffer-position buffer position "buffer-insert!")
    (agent-scheme--apply-buffer-edit
     buffer position position text "buffer-insert!")
    agent-scheme-unspecified))

(defun agent-scheme--primitive-buffer-delete! (arguments context)
  "Primitive buffer-delete! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-delete!" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-delete!"))
         (start (agent-scheme--capability-exact-integer
                 (cadr arguments) "buffer-delete! start"))
         (end (agent-scheme--capability-exact-integer
               (caddr arguments) "buffer-delete! end")))
    (agent-scheme--apply-buffer-edit
     buffer start end "" "buffer-delete!")
    agent-scheme-unspecified))

(defun agent-scheme--primitive-buffer-replace! (arguments context)
  "Primitive buffer-replace! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-replace!" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-replace!"))
         (start (agent-scheme--capability-exact-integer
                 (cadr arguments) "buffer-replace! start"))
         (end (agent-scheme--capability-exact-integer
               (caddr arguments) "buffer-replace! end"))
         (text (agent-scheme--capability-string
                (cadddr arguments) "buffer-replace! text")))
    (agent-scheme--apply-buffer-edit
     buffer start end text "buffer-replace!")
    agent-scheme-unspecified))

(defun agent-scheme--primitive-buffer-save! (arguments context)
  "Primitive buffer-save! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-save!" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-save!"))
         (file (agent-scheme--buffer-target-file buffer)))
    (agent-scheme--check-buffer-edit-target buffer "buffer-save!")
    (unless file
      (agent-scheme--eval-error
       "buffer-save! requires a file-backed buffer: %s"
       (buffer-name buffer)))
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--buffer-target-fields buffer)
      `((modified-before-save . ,(with-current-buffer buffer
                                   (buffer-modified-p))))))
    (with-current-buffer buffer
      (save-buffer))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-emacs-buffer-list (arguments context)
  "Primitive emacs-buffer-list."
  (agent-scheme--authorize-emacs-capability
   "emacs-buffer-list" arguments context)
  (mapcar #'agent-scheme--buffer-handle (buffer-list)))

(defun agent-scheme--primitive-emacs-window-list (arguments context)
  "Primitive emacs-window-list."
  (agent-scheme--authorize-emacs-capability
   "emacs-window-list" arguments context)
  (mapcar #'agent-scheme--window-handle (window-list nil 'no-minibuf)))

(defun agent-scheme--primitive-window-frame (arguments context)
  "Primitive window-frame over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "window-frame" arguments context)
  (agent-scheme--frame-handle
   (window-frame
    (agent-scheme--live-window-for-handle (car arguments) "window-frame"))))

(defun agent-scheme--primitive-emacs-current-frame (arguments context)
  "Primitive emacs-current-frame."
  (agent-scheme--authorize-emacs-capability
   "emacs-current-frame" arguments context)
  (agent-scheme--frame-handle (selected-frame)))

(defun agent-scheme--primitive-emacs-frame-list (arguments context)
  "Primitive emacs-frame-list."
  (agent-scheme--authorize-emacs-capability
   "emacs-frame-list" arguments context)
  (mapcar #'agent-scheme--frame-handle (frame-list)))

(defun agent-scheme--primitive-frame-name (arguments context)
  "Primitive frame-name over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "frame-name" arguments context)
  (agent-scheme--maybe-string
   (frame-parameter
    (agent-scheme--live-frame-for-handle (car arguments) "frame-name")
    'name)))

(defun agent-scheme--primitive-emacs-current-project (arguments context)
  "Primitive emacs-current-project."
  (agent-scheme--authorize-emacs-capability
   "emacs-current-project" arguments context)
  (let ((project (project-current nil)))
    (if project
        (agent-scheme--project-handle project)
      agent-scheme-false)))

(defun agent-scheme--primitive-project-root (arguments context)
  "Primitive project-root over optional project handle ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "project-root" arguments context)
  (let ((project
         (if arguments
             (agent-scheme--project-for-handle
              (car arguments) "project-root")
           (project-current nil))))
    (if project
        (file-name-as-directory (expand-file-name (project-root project)))
      agent-scheme-false)))

(defun agent-scheme--primitive-emacs-process-list (arguments context)
  "Primitive emacs-process-list."
  (agent-scheme--authorize-emacs-capability
   "emacs-process-list" arguments context)
  (mapcar #'agent-scheme--process-handle
          (seq-filter #'process-live-p (process-list))))

(defun agent-scheme--primitive-process-name (arguments context)
  "Primitive process-name over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "process-name" arguments context)
  (process-name
   (agent-scheme--live-process-for-handle (car arguments) "process-name")))

(defun agent-scheme--primitive-process-status (arguments context)
  "Primitive process-status over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "process-status" arguments context)
  (agent-scheme--scheme-symbol
   (process-status
    (agent-scheme--live-process-for-handle
     (car arguments) "process-status"))))

(defun agent-scheme--primitive-process-buffer (arguments context)
  "Primitive process-buffer over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "process-buffer" arguments context)
  (let ((buffer
         (process-buffer
          (agent-scheme--live-process-for-handle
           (car arguments) "process-buffer"))))
    (if buffer
        (agent-scheme--buffer-handle buffer)
      agent-scheme-false)))

(defun agent-scheme--documentation-string (symbol commandp)
  "Return raw documentation string for SYMBOL.
When COMMANDP is non-nil, SYMBOL must name an interactive command."
  (if (and symbol
           (if commandp (commandp symbol) (fboundp symbol)))
      (agent-scheme--maybe-string (documentation symbol t))
    agent-scheme-false))

(defun agent-scheme--primitive-command-doc (arguments context)
  "Primitive command-doc over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "command-doc" arguments context)
  (agent-scheme--documentation-string
   (agent-scheme--capability-name-symbol (car arguments) "command-doc")
   t))

(defun agent-scheme--primitive-function-doc (arguments context)
  "Primitive function-doc over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "function-doc" arguments context)
  (agent-scheme--documentation-string
   (agent-scheme--capability-name-symbol (car arguments) "function-doc")
   nil))

(defun agent-scheme--primitive-variable-info (arguments context)
  "Primitive variable-info over ARGUMENTS without exposing variable values."
  (agent-scheme--authorize-emacs-capability "variable-info" arguments context)
  (let* ((argument (car arguments))
         (name
          (cond
           ((agent-scheme-symbol-p argument)
            (agent-scheme-symbol-name argument))
           ((stringp argument)
            argument)
           (t
            (agent-scheme--eval-error
             "variable-info expected a symbol or string, got %s"
             (agent-scheme-value->external argument)))))
         (symbol (intern-soft name))
         (documentation
          (and symbol
               (documentation-property symbol 'variable-documentation t))))
    (list
     (list (agent-scheme--intern-symbol "name")
           (agent-scheme--intern-symbol name))
     (list (agent-scheme--intern-symbol "bound?")
           (agent-scheme--scheme-boolean-value
            (and symbol (boundp symbol))))
     (list (agent-scheme--intern-symbol "custom?")
           (agent-scheme--scheme-boolean-value
            (and symbol (custom-variable-p symbol))))
     (list (agent-scheme--intern-symbol "documentation")
           (agent-scheme--maybe-string documentation)))))

(provide 'agent-scheme-capability)

;;; agent-scheme-capability.el ends here
