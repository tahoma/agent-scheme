;;; agent-scheme-capability.el --- Emacs capability primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; Host adapter primitives for read-only Emacs capability libraries.  Scheme
;; programs receive opaque handles; live Emacs objects stay in a private side
;; table owned by this module.

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
  "Manifest metadata for read-only Emacs capability primitives.")

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

(defun agent-scheme--authorize-emacs-capability
    (name arguments context)
  "Authorize read-only Emacs capability NAME with ARGUMENTS in CONTEXT."
  (unless agent-scheme--emacs-capability-preauthorized
    (let ((spec (agent-scheme--emacs-capability-manifest-spec name)))
      (agent-scheme-policy-authorize
       'emacs-read-only
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
      `((category . emacs-read-only)
        (operation . ,name)
        (library . ,(and spec (plist-get spec :library)))
        (capability . ,name)
        (arguments . ,arguments)
        (outcome . ,outcome)
        (decision . ,(if (eq outcome 'success) 'completed 'errored)))
      fields))))

(defun agent-scheme--call-emacs-capability
    (name function arguments context)
  "Call Emacs capability FUNCTION and audit its outcome."
  (agent-scheme--authorize-emacs-capability name arguments context)
  (condition-case condition
      (let ((result (let ((agent-scheme--emacs-capability-preauthorized t))
                      (funcall function arguments context))))
        (agent-scheme--audit-emacs-capability-result
         name
         arguments
         'success
         `((result . ,(agent-scheme--capability-result-string result))))
        result)
    (error
     (agent-scheme--audit-emacs-capability-result
      name
      arguments
      'error
      `((error . ,(error-message-string condition))))
     (signal (car condition) (cdr condition)))))

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
