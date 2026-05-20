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

(declare-function agent-scheme--apply-procedure "agent-scheme-interpreter")

(define-error 'agent-scheme-capability-grant-error
  "Agent Scheme capability grant denied"
  'agent-scheme-eval-error)

(defcustom agent-scheme-capability-require-grants-for-mutations t
  "Non-nil means host mutation capabilities require matching grants."
  :type 'boolean
  :group 'agent-scheme)

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

(defvar agent-scheme--next-capability-grant-number 0
  "Next numeric suffix for generated capability grant ids.")

(defvar agent-scheme--next-capability-revocation-number 0
  "Next numeric suffix for generated capability revocation ids.")

(defvar agent-scheme--next-file-capability-request-number 0
  "Next numeric suffix for generated file capability request ids.")

(defvar agent-scheme--next-file-capability-decision-number 0
  "Next numeric suffix for generated file capability decision ids.")

(defvar agent-scheme--next-code-loading-request-number 0
  "Next numeric suffix for generated code-loading request ids.")

(defvar agent-scheme--next-code-loading-decision-number 0
  "Next numeric suffix for generated code-loading decision ids.")

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
     :requires-grant t
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-delete!" :library "(emacs buffer edit)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-delete!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-replace!" :library "(emacs buffer edit)"
     :minimum-arity 4 :maximum-arity 4
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-replace!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-save!" :library "(emacs buffer edit)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-save!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
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

(defun agent-scheme--capability-grant-symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--intern-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme--capability-grant-symbol-name (value)
  "Return VALUE as a stable grant field name."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun agent-scheme--capability-grant-field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (equal (agent-scheme--capability-grant-symbol-name (car field))
              name)))

(defun agent-scheme--capability-grant-field (grant name)
  "Return the first field named NAME in GRANT, or nil."
  (seq-find
   (lambda (field)
     (agent-scheme--capability-grant-field-named-p field name))
   (cdr-safe grant)))

(defun agent-scheme--capability-grant-field-value (grant name)
  "Return the single value of field NAME in GRANT, or nil."
  (cadr (agent-scheme--capability-grant-field grant name)))

(defun agent-scheme--capability-grant-field-values (grant name)
  "Return all values from field NAME in GRANT."
  (cdr (agent-scheme--capability-grant-field grant name)))

(defun agent-scheme--capability-grant-replace-field (grant name values)
  "Return GRANT with field NAME replaced by VALUES."
  (let ((seen nil)
        (name-symbol (agent-scheme--capability-grant-symbol name)))
    (append
     (list (car grant))
     (mapcar
      (lambda (field)
        (if (agent-scheme--capability-grant-field-named-p field name)
            (progn
              (setq seen t)
              (cons name-symbol values))
          field))
      (cdr grant))
     (unless seen
       (list (cons name-symbol values))))))

(defun agent-scheme--capability-grant-remove-fields (grant names)
  "Return GRANT without fields named by NAMES."
  (cons
   (car grant)
   (seq-remove
    (lambda (field)
      (member (agent-scheme--capability-grant-symbol-name (car-safe field))
              names))
    (cdr grant))))

(defun agent-scheme--capability-grant-datum-p (datum)
  "Return non-nil when DATUM is a capability-grant record."
  (and (consp datum)
       (equal (agent-scheme--capability-grant-symbol-name (car datum))
              "capability-grant")))

(defun agent-scheme--capability-grant-id-name (id)
  "Return ID as a stable capability grant id string."
  (or (agent-scheme--capability-grant-symbol-name id)
      (agent-scheme--eval-error
       "capability grant id must be a symbol or string")))

(defun agent-scheme--capability-generated-grant-id ()
  "Return a fresh generated capability grant id."
  (agent-scheme--capability-grant-symbol
   (format "g-%d" (cl-incf agent-scheme--next-capability-grant-number))))

(defun agent-scheme--capability-grant-expires-uses (expires)
  "Return the use count from EXPIRES, or nil."
  (when (and (consp expires)
             (equal (agent-scheme--capability-grant-symbol-name (car expires))
                    "uses"))
    (agent-scheme--capability-exact-integer
     (cadr expires) "capability grant uses")))

(defun agent-scheme--capability-grant-status (grant)
  "Return GRANT status as an Emacs symbol."
  (let ((field (agent-scheme--capability-grant-field grant "status")))
    (intern
     (or (and field
              (agent-scheme--capability-grant-symbol-name
               (cadr field)))
         "active"))))

(defun agent-scheme--capability-grant-normalize (datum)
  "Return DATUM as a normalized capability-grant record."
  (unless (agent-scheme--capability-grant-datum-p datum)
    (signal 'agent-scheme-capability-grant-error
            (list "grant-capability! expects a capability-grant datum")))
  (let* ((id (or (agent-scheme--capability-grant-field-value datum "id")
                 (agent-scheme--capability-generated-grant-id)))
         (domain (agent-scheme--capability-grant-field-value datum "domain"))
         (operations (agent-scheme--capability-grant-field-values
                      datum "operations"))
         (library (agent-scheme--capability-grant-field-value datum "library"))
         (effect (agent-scheme--capability-grant-field-value datum "effect"))
         (expires (or (agent-scheme--capability-grant-field-value
                       datum "expires")
                      (agent-scheme--capability-grant-symbol "never")))
         (uses (agent-scheme--capability-grant-expires-uses expires))
         (normalized
          (agent-scheme--capability-grant-remove-fields
           datum '("id" "status" "uses-remaining"))))
    (unless (or (and library effect)
                (and domain operations))
      (signal 'agent-scheme-capability-grant-error
              (list "capability grant requires either library/effect or domain/operations fields")))
    (setq normalized
          (agent-scheme--capability-grant-replace-field
           normalized "id" (list (agent-scheme--capability-grant-symbol id))))
    (setq normalized
          (agent-scheme--capability-grant-replace-field
           normalized "expires" (list expires)))
    (setq normalized
          (agent-scheme--capability-grant-replace-field
           normalized "status"
           (list (agent-scheme--capability-grant-symbol "active"))))
    (when uses
      (setq normalized
            (agent-scheme--capability-grant-replace-field
             normalized
             "uses-remaining"
             (list (agent-scheme--scheme-integer uses)))))
    normalized))

(defun agent-scheme--capability-context-grants (context)
  "Return capability grants carried by CONTEXT."
  (and context
       (agent-scheme--eval-context-p context)
       (agent-scheme--eval-context-capability-grants context)))

(defun agent-scheme--capability-set-context-grants (context grants)
  "Store GRANTS in CONTEXT."
  (when (and context (agent-scheme--eval-context-p context))
    (setf (agent-scheme--eval-context-capability-grants context) grants))
  grants)

(defun agent-scheme--capability-grant-id (grant)
  "Return GRANT's id datum."
  (agent-scheme--capability-grant-field-value grant "id"))

(defun agent-scheme--capability-grant-same-id-p (grant id)
  "Return non-nil when GRANT has ID."
  (equal (agent-scheme--capability-grant-id-name
          (agent-scheme--capability-grant-id grant))
         (agent-scheme--capability-grant-id-name id)))

(defun agent-scheme--capability-store-grant! (grant context)
  "Store GRANT in CONTEXT and return it."
  (let* ((id (agent-scheme--capability-grant-id grant))
         (grants
          (seq-remove
           (lambda (candidate)
             (agent-scheme--capability-grant-same-id-p candidate id))
           (agent-scheme--capability-context-grants context))))
    (agent-scheme--capability-set-context-grants
     context (append grants (list grant)))
    grant))

(defun agent-scheme--capability-grant-by-id (id context)
  "Return grant ID from CONTEXT, or nil."
  (seq-find
   (lambda (grant)
     (agent-scheme--capability-grant-same-id-p grant id))
   (agent-scheme--capability-context-grants context)))

(defun agent-scheme--capability-grant-active-p (grant)
  "Return non-nil when GRANT is currently active."
  (and grant
       (eq (agent-scheme--capability-grant-status grant) 'active)
       (let ((uses (agent-scheme--capability-grant-field-value
                    grant "uses-remaining")))
         (or (null uses)
             (> (agent-scheme--capability-exact-integer
                 uses "capability grant uses-remaining")
                0)))))

(defun agent-scheme--capability-current-grants (context)
  "Return active grants in CONTEXT."
  (seq-filter
   #'agent-scheme--capability-grant-active-p
   (agent-scheme--capability-context-grants context)))

(defun agent-scheme--capability-grant-audit-fields
    (operation grant decision &optional fields)
  "Return audit fields for OPERATION on GRANT with DECISION."
  (append
   `((category . capability-grant)
     (operation . ,operation)
     (id . ,(or (and grant (agent-scheme--capability-grant-id grant))
                agent-scheme-false))
     (decision . ,decision))
   (when grant
     `((library . ,(agent-scheme--capability-grant-field-value
                    grant "library"))
       (effect . ,(agent-scheme--capability-grant-field-value
                   grant "effect"))
       (domain . ,(agent-scheme--capability-grant-field-value
                   grant "domain"))
       (operations . ,(agent-scheme--capability-grant-field-values
                       grant "operations"))))
   fields))

(defun agent-scheme--capability-audit-grant
    (operation grant decision &optional fields)
  "Audit OPERATION on GRANT with DECISION."
  (agent-scheme-audit-record
   'capability-grant
   (agent-scheme--capability-grant-audit-fields
    operation grant decision fields)))

(defun agent-scheme--capability-grant-error
    (message grant &optional fields)
  "Audit a denied GRANT use and signal MESSAGE."
  (agent-scheme--capability-audit-grant
   "capability-grant-use" grant 'denied fields)
  (signal 'agent-scheme-capability-grant-error (list message)))

(defun agent-scheme--capability-grant-library-key (grant)
  "Return GRANT library key as external text."
  (when-let ((library (agent-scheme--capability-grant-field-value
                       grant "library")))
    (agent-scheme-datum->external library)))

(defun agent-scheme--capability-grant-effect-name (grant)
  "Return GRANT effect name."
  (agent-scheme--capability-grant-symbol-name
   (agent-scheme--capability-grant-field-value grant "effect")))

(defun agent-scheme--capability-grant-scope-clauses (grant)
  "Return scope clauses from GRANT."
  (agent-scheme--capability-grant-field-values grant "scope"))

(defun agent-scheme--capability-scope-clause (grant name)
  "Return GRANT scope clause named NAME, or nil."
  (seq-find
   (lambda (clause)
     (agent-scheme--capability-grant-field-named-p clause name))
   (agent-scheme--capability-grant-scope-clauses grant)))

(defun agent-scheme--capability-scope-value (grant name)
  "Return first value from GRANT scope clause NAME, or nil."
  (cadr (agent-scheme--capability-scope-clause grant name)))

(defun agent-scheme--capability-range-values (grant)
  "Return GRANT's range or region values as a two-element list."
  (let ((clause (or (agent-scheme--capability-scope-clause grant "range")
                    (agent-scheme--capability-scope-clause grant "region"))))
    (when clause
      (list
       (agent-scheme--capability-exact-integer
        (cadr clause) "capability grant range start")
       (agent-scheme--capability-exact-integer
        (caddr clause) "capability grant range end")))))

(defun agent-scheme--capability-operation-region (name arguments)
  "Return the buffer region touched by capability NAME with ARGUMENTS."
  (pcase name
    ("buffer-insert!"
     (let ((position (agent-scheme--capability-exact-integer
                      (cadr arguments) "buffer-insert! position")))
       (list position position)))
    ((or "buffer-delete!" "buffer-replace!")
     (list
      (agent-scheme--capability-exact-integer
       (cadr arguments) (format "%s start" name))
      (agent-scheme--capability-exact-integer
       (caddr arguments) (format "%s end" name))))
    (_ nil)))

(defun agent-scheme--capability-operation-buffer-handle (name arguments)
  "Return the buffer handle argument for capability NAME."
  (when (member name '("buffer-insert!" "buffer-delete!"
                      "buffer-replace!" "buffer-save!"))
    (car arguments)))

(defun agent-scheme--capability-same-handle-p (left right)
  "Return non-nil when LEFT and RIGHT name the same opaque handle."
  (and (agent-scheme-handle-p left)
       (agent-scheme-handle-p right)
       (eq (agent-scheme-handle-kind left)
           (agent-scheme-handle-kind right))
       (equal (agent-scheme-handle-id left)
              (agent-scheme-handle-id right))))

(defun agent-scheme--capability-check-grant-handle-live (grant handle)
  "Signal if GRANT is scoped to stale HANDLE."
  (when (and (agent-scheme-handle-p handle)
             (not (agent-scheme-capability-handle-live-p handle)))
    (agent-scheme--capability-grant-error
     (format "stale capability grant handle: %s"
             (agent-scheme-handle-id handle))
     grant
     `((grant-handle . ,handle)))))

(defun agent-scheme--capability-file-in-project-p (file root)
  "Return non-nil when FILE is under project ROOT."
  (and file
       root
       (file-in-directory-p
        (expand-file-name file)
        (file-name-as-directory (expand-file-name root)))))

(defun agent-scheme--file-capability-symbol-name (value)
  "Return VALUE as a file capability symbol name, or nil."
  (agent-scheme--capability-grant-symbol-name value))

(defun agent-scheme--file-capability-operation-symbol (operation)
  "Return OPERATION as an Agent Scheme symbol datum."
  (agent-scheme--capability-grant-symbol operation))

(defun agent-scheme--file-capability-effect-symbol (operation)
  "Return the effect class for file OPERATION."
  (agent-scheme--capability-grant-symbol
   (if (member (agent-scheme--file-capability-symbol-name operation)
               '("write" "create" "delete"))
       "host-file-mutation"
     "read-only-observation")))

(defun agent-scheme--file-capability-request-id ()
  "Return a fresh file capability request id."
  (agent-scheme--capability-grant-symbol
   (format "req-file-%d"
           (cl-incf agent-scheme--next-file-capability-request-number))))

(defun agent-scheme--file-capability-decision-id ()
  "Return a fresh file capability decision id."
  (agent-scheme--capability-grant-symbol
   (format "dec-file-%d"
           (cl-incf agent-scheme--next-file-capability-decision-number))))

(defun agent-scheme--capability-revocation-id ()
  "Return a fresh capability revocation id."
  (agent-scheme--capability-grant-symbol
   (format "rev-%d"
           (cl-incf agent-scheme--next-capability-revocation-number))))

(defun agent-scheme--code-loading-request-id ()
  "Return a fresh code-loading capability request id."
  (agent-scheme--capability-grant-symbol
   (format "req-code-loading-%d"
           (cl-incf agent-scheme--next-code-loading-request-number))))

(defun agent-scheme--code-loading-decision-id ()
  "Return a fresh code-loading capability decision id."
  (agent-scheme--capability-grant-symbol
   (format "dec-code-loading-%d"
           (cl-incf agent-scheme--next-code-loading-decision-number))))

(defun agent-scheme--file-capability-remote-path-p (filename path)
  "Return non-nil when FILENAME or PATH names non-local file authority."
  (or (and (stringp filename)
           (or (file-remote-p filename)
               (string-match-p "\\`[[:alpha:]][[:alnum:].+-]*://" filename)))
      (and (stringp path)
           (file-remote-p path))))

(defun agent-scheme--file-capability-existing-truename (path)
  "Return PATH with symlinks resolved when the target exists."
  (if (file-exists-p path)
      (file-truename path)
    (agent-scheme--file-capability-parent-truename path)))

(defun agent-scheme--file-capability-parent-truename (path)
  "Return PATH with existing parent directories canonicalized.
The final path component is not resolved, so a symlink inside an
approved root still counts as syntactically inside that root before
the separate resolved-target check runs."
  (let ((directory (file-name-directory path))
        (leaf (file-name-nondirectory path)))
    (if (and directory (file-directory-p directory))
        (expand-file-name leaf (file-truename directory))
      (expand-file-name path))))

(defun agent-scheme--file-capability-directory-root-p (path)
  "Return non-nil when PATH should be treated as an allowed directory root."
  (or (file-directory-p path)
      (string-suffix-p "/" path)))

(defun agent-scheme--file-capability-contained-p (path allowed)
  "Return non-nil when PATH is exactly ALLOWED or inside ALLOWED."
  (let ((path* (directory-file-name (expand-file-name path)))
        (allowed* (directory-file-name (expand-file-name allowed))))
    (or (equal path* allowed*)
        (and (agent-scheme--file-capability-directory-root-p allowed)
             (string-prefix-p
              (file-name-as-directory allowed*)
              path*)))))

(defun agent-scheme--file-capability-field-values-list (values)
  "Return VALUES as a flattened Scheme field value list."
  (if (and (= (length values) 1)
           (listp (car values))
           (not (agent-scheme-symbol-p (car values))))
      (car values)
    values))

(defun agent-scheme--file-capability-scope-values (grant name)
  "Return flattened scope values named NAME from GRANT."
  (agent-scheme--file-capability-field-values-list
   (cdr (agent-scheme--capability-scope-clause grant name))))

(defun agent-scheme--file-capability-grant-domain-p (grant)
  "Return non-nil when GRANT is a file-domain grant."
  (equal (agent-scheme--file-capability-symbol-name
          (agent-scheme--capability-grant-field-value grant "domain"))
         "file"))

(defun agent-scheme--file-capability-operation-p (grant operation)
  "Return non-nil when GRANT allows OPERATION."
  (let ((operation-name
         (agent-scheme--file-capability-symbol-name operation)))
    (cl-some
     (lambda (candidate)
       (equal (agent-scheme--file-capability-symbol-name candidate)
              operation-name))
     (agent-scheme--capability-grant-field-values grant "operations"))))

(defun agent-scheme--file-capability-grants (context)
  "Return file-domain grants carried by CONTEXT."
  (seq-filter
   #'agent-scheme--file-capability-grant-domain-p
   (agent-scheme--capability-context-grants context)))

(defun agent-scheme--file-capability-legacy-grants
    (allowed-paths operation)
  "Return synthetic file grants for legacy ALLOWED-PATHS and OPERATION."
  (when allowed-paths
    (list
     `(capability-grant
       (id legacy-file-path-policy)
       (domain file)
       (operations ,operation)
       (scope (file-root "/")
              (paths ,allowed-paths)
              (remote denied)
              (symlinks resolve-within-root))
       (expires after-eval)
       (status active)))))

(defun agent-scheme--file-capability-path-roots (grant context)
  "Return absolute allowed roots described by GRANT."
  (let* ((project-root
          (agent-scheme--capability-scope-value grant "project-root"))
         (file-root
          (agent-scheme--capability-scope-value grant "file-root"))
         (base-root
          (or project-root
              file-root
              (and context
                   (agent-scheme--eval-context-p context)
                   (agent-scheme--eval-context-include-directory context))
              default-directory))
         (base-directory
          (file-name-as-directory (expand-file-name base-root)))
         (paths
          (or (agent-scheme--file-capability-scope-values grant "paths")
              '("."))))
    (mapcar
     (lambda (path)
       (if (file-name-absolute-p path)
           (expand-file-name path)
         (expand-file-name path base-directory)))
     paths)))

(defun agent-scheme--file-capability-grant-match
    (grant path resolved-path operation context)
  "Return a match plist when GRANT authorizes PATH for OPERATION."
  (cond
   ((not (agent-scheme--file-capability-operation-p grant operation))
    nil)
   ((eq (agent-scheme--capability-grant-status grant) 'revoked)
    (list :denied grant :reason "revoked file capability grant"))
   ((not (agent-scheme--capability-grant-active-p grant))
    (list :denied grant :reason "expired file capability grant"))
   (t
    (let ((outside-reason "path is outside approved file grant root")
          symlink-denial)
      (catch 'matched
        (dolist (allowed (agent-scheme--file-capability-path-roots grant context))
          (let* ((syntactic-path
                  (agent-scheme--file-capability-parent-truename path))
                 (resolved-allowed
                  (agent-scheme--file-capability-existing-truename allowed))
                 (syntactic-allowed resolved-allowed)
                 (syntactic-match
                  (agent-scheme--file-capability-contained-p
                   syntactic-path syntactic-allowed))
                 (resolved-match
                  (agent-scheme--file-capability-contained-p
                   resolved-path resolved-allowed)))
            (cond
             ((and syntactic-match resolved-match)
              (throw 'matched
                     (list :grant grant
                           :allowed-root allowed
                           :resolved-root resolved-allowed)))
             ((and syntactic-match (not resolved-match))
              (setq symlink-denial
                    (list :denied grant
                          :reason
                          "symlink target escapes approved file grant root"
                          :allowed-root allowed
                          :resolved-root resolved-allowed))))))
        (or symlink-denial
            (list :denied grant :reason outside-reason)))))))

(defun agent-scheme--file-capability-request-datum
    (request-id filename path operation binding)
  "Return a Scheme-readable file capability request datum."
  `(,(agent-scheme--capability-grant-symbol "capability-request")
    (,(agent-scheme--capability-grant-symbol "id") ,request-id)
    (,(agent-scheme--capability-grant-symbol "session")
     ,(or nil agent-scheme-false))
    (,(agent-scheme--capability-grant-symbol "library")
     (,(agent-scheme--capability-grant-symbol "scheme")
      ,(agent-scheme--capability-grant-symbol
        (if (member (agent-scheme--file-capability-symbol-name operation)
                    '("include" "include-ci" "library-source"))
            "base"
          (if (equal (agent-scheme--file-capability-symbol-name operation)
                     "load")
              "load"
            "file")))))
    (,(agent-scheme--capability-grant-symbol "binding") ,binding)
    (,(agent-scheme--capability-grant-symbol "domain")
     ,(agent-scheme--capability-grant-symbol "file"))
    (,(agent-scheme--capability-grant-symbol "operation")
     ,(agent-scheme--file-capability-operation-symbol operation))
    (,(agent-scheme--capability-grant-symbol "resource")
     (,(agent-scheme--capability-grant-symbol "path") ,filename)
     (,(agent-scheme--capability-grant-symbol "normalized-path") ,path))
    (,(agent-scheme--capability-grant-symbol "effect")
     ,(agent-scheme--file-capability-effect-symbol operation))))

(defun agent-scheme--file-capability-record-request
    (request operation filename path)
  "Audit file capability REQUEST."
  (agent-scheme-audit-record
   'capability-request
   `((request . ,request)
     (domain . file)
     (operation . ,operation)
     (path . ,filename)
     (normalized-path . ,path))))

(defun agent-scheme--file-capability-record-decision
    (request request-id status grant reason &optional fields)
  "Audit and return a file capability decision datum."
  (let* ((decision-id (agent-scheme--file-capability-decision-id))
         (grant-id (or (and grant (agent-scheme--capability-grant-id grant))
                       (agent-scheme--capability-grant-symbol "none")))
         (decision
          `(,(agent-scheme--capability-grant-symbol "capability-decision")
            (,(agent-scheme--capability-grant-symbol "id") ,decision-id)
            (,(agent-scheme--capability-grant-symbol "request") ,request-id)
            (,(agent-scheme--capability-grant-symbol "status")
             ,(agent-scheme--capability-grant-symbol status))
            (,(agent-scheme--capability-grant-symbol "grant") ,grant-id)
            (,(agent-scheme--capability-grant-symbol "reason") ,reason))))
    (agent-scheme-audit-record
     'capability-decision
     (append
      `((request . ,request)
        (decision . ,decision)
        (status . ,status)
        (grant . ,grant-id)
        (reason . ,reason))
      fields))
    decision))

(defun agent-scheme-capability-audit-file-result
    (authorization result &optional errored)
  "Audit file capability AUTHORIZATION with RESULT.
When ERRORED is non-nil, RESULT is recorded as an error payload."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (agent-scheme-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . file)
       (operation . ,operation)
       (result . ,(if errored
                    (list 'error result)
                  (list 'ok result)))))))

(defun agent-scheme--file-capability-handle-datum
    (handle path resolved-path grant-id status)
  "Return a Scheme-readable file HANDLE datum."
  `(,(agent-scheme--capability-grant-symbol "handle")
    (,(agent-scheme--capability-grant-symbol "id")
     ,(agent-scheme-handle-id handle))
    (,(agent-scheme--capability-grant-symbol "kind")
     ,(agent-scheme--capability-grant-symbol "file"))
    (,(agent-scheme--capability-grant-symbol "domain")
     ,(agent-scheme--capability-grant-symbol "file"))
    (,(agent-scheme--capability-grant-symbol "path") ,path)
    (,(agent-scheme--capability-grant-symbol "resolved-path")
     ,resolved-path)
    (,(agent-scheme--capability-grant-symbol "grant") ,grant-id)
    (,(agent-scheme--capability-grant-symbol "status")
     ,(agent-scheme--capability-grant-symbol status))))

(defun agent-scheme--file-capability-register-handle
    (path resolved-path grant operation)
  "Register and audit a file handle for an approved file request."
  (let* ((grant-id (agent-scheme--capability-grant-id grant))
         (handle
          (agent-scheme--register-handle
           'file
           (list :path path
                 :resolved-path resolved-path
                 :grant grant-id
                 :operation operation
                 :status 'live)))
         (handle-datum
          (agent-scheme--file-capability-handle-datum
           handle path resolved-path grant-id 'live)))
    (agent-scheme-audit-record
     'capability-handle
     `((handle . ,handle-datum)
       (domain . file)
       (kind . file)
       (path . ,path)
       (resolved-path . ,resolved-path)
       (grant . ,grant-id)
       (status . live)))
    handle))

(defun agent-scheme-capability-revalidate-file-authorization
    (authorization)
  "Fail closed unless AUTHORIZATION still has a live file handle and grant."
  (let ((handle (plist-get authorization :handle))
        (grant (plist-get authorization :grant)))
    (unless (and handle
                 (agent-scheme-capability-handle-live-p handle))
      (signal 'agent-scheme-capability-grant-error
              (list "stale file capability handle")))
    (unless (and grant
                 (agent-scheme--capability-grant-active-p grant))
      (signal 'agent-scheme-capability-grant-error
              (list "inactive file capability grant")))
    authorization))

(defun agent-scheme--code-loading-request-datum
    (request-id file-authorization binding)
  "Return a Scheme-readable code-loading request datum."
  (let ((path (plist-get file-authorization :path))
        (file-request (plist-get file-authorization :request)))
    `(,(agent-scheme--capability-grant-symbol "capability-request")
      (,(agent-scheme--capability-grant-symbol "id") ,request-id)
      (,(agent-scheme--capability-grant-symbol "library")
       (,(agent-scheme--capability-grant-symbol "scheme")
        ,(agent-scheme--capability-grant-symbol "load")))
      (,(agent-scheme--capability-grant-symbol "binding") ,binding)
      (,(agent-scheme--capability-grant-symbol "domain")
       ,(agent-scheme--capability-grant-symbol "code-loading"))
      (,(agent-scheme--capability-grant-symbol "operation")
       ,(agent-scheme--capability-grant-symbol "load"))
      (,(agent-scheme--capability-grant-symbol "resource")
       (,(agent-scheme--capability-grant-symbol "path") ,path)
       (,(agent-scheme--capability-grant-symbol "file-request")
        ,file-request))
      (,(agent-scheme--capability-grant-symbol "effect")
       ,(agent-scheme--capability-grant-symbol "environment-mutation")))))

(defun agent-scheme--code-loading-record-request
    (request binding path)
  "Audit code-loading capability REQUEST."
  (agent-scheme-audit-record
   'capability-request
   `((request . ,request)
     (domain . code-loading)
     (operation . load)
     (binding . ,binding)
     (path . ,path))))

(defun agent-scheme--code-loading-record-decision
    (request request-id status reason &optional fields)
  "Audit and return a code-loading capability decision datum."
  (let* ((decision-id (agent-scheme--code-loading-decision-id))
         (decision
          `(,(agent-scheme--capability-grant-symbol "capability-decision")
            (,(agent-scheme--capability-grant-symbol "id") ,decision-id)
            (,(agent-scheme--capability-grant-symbol "request") ,request-id)
            (,(agent-scheme--capability-grant-symbol "status")
             ,(agent-scheme--capability-grant-symbol status))
            (,(agent-scheme--capability-grant-symbol "domain")
             ,(agent-scheme--capability-grant-symbol "code-loading"))
            (,(agent-scheme--capability-grant-symbol "reason") ,reason))))
    (agent-scheme-audit-record
     'capability-decision
     (append
      `((request . ,request)
        (decision . ,decision)
        (domain . code-loading)
        (operation . load)
        (status . ,status)
        (reason . ,reason))
      fields))
    decision))

(defun agent-scheme-capability-audit-code-loading-result
    (authorization result &optional errored)
  "Audit code-loading AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision)))
    (agent-scheme-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . code-loading)
       (operation . load)
       (result . ,(if errored
                      (list 'error result)
                    (list 'ok result)))))))

(defun agent-scheme-capability-authorize-code-loading
    (file-authorization context binding)
  "Authorize loading code read by FILE-AUTHORIZATION."
  (let* ((path (plist-get file-authorization :path))
         (request-id (agent-scheme--code-loading-request-id))
         (request
          (agent-scheme--code-loading-request-datum
           request-id file-authorization binding)))
    (agent-scheme--code-loading-record-request request binding path)
    (condition-case condition
        (progn
          (agent-scheme-policy-authorize
           'standard-host-effect
           binding
           `((domain . code-loading)
             (operation . load)
             (path . ,path)
             (file-request . ,(plist-get file-authorization :request)))
           context)
          (list :path path
                :operation 'load
                :request request
                :decision
                (agent-scheme--code-loading-record-decision
                 request request-id 'approved
                 "load target is authorized under current evaluation context"
                 `((path . ,path)))))
      (agent-scheme-policy-error
       (let ((decision
              (agent-scheme--code-loading-record-decision
               request request-id 'denied
               (error-message-string condition)
               `((path . ,path)))))
         (agent-scheme-capability-audit-code-loading-result
          (list :request request :decision decision)
          (error-message-string condition)
          t)
         (signal (car condition) (cdr condition)))))))

(defun agent-scheme--file-capability-deny
    (request request-id operation filename path grant reason
             &optional policy-denial context policy-operation)
  "Record a denied file capability request and signal REASON."
  (let ((decision
         (agent-scheme--file-capability-record-decision
          request request-id 'denied grant reason)))
    (agent-scheme-capability-audit-file-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (if policy-denial
        (agent-scheme-policy-deny
         'standard-host-effect
         (or policy-operation (format "%s" operation))
         `((filename . ,filename)
           (path . ,path))
         context
         reason)
      (signal 'agent-scheme-capability-grant-error
              (list (format "file capability denied: %s" reason))))))

(defun agent-scheme-capability-authorize-file
    (filename context operation binding &optional legacy-allowed-paths)
  "Authorize FILENAME for file OPERATION and return an authorization plist.
LEGACY-ALLOWED-PATHS converts the old path allow-list options into a
synthetic file grant so existing callers share the capability vocabulary."
  (let* ((path (expand-file-name
                filename
                (agent-scheme--eval-context-include-directory context)))
         (resolved-path
          (agent-scheme--file-capability-existing-truename path))
         (request-id (agent-scheme--file-capability-request-id))
         (request
          (agent-scheme--file-capability-request-datum
           request-id filename path operation binding))
         (file-grants
          (append
           (agent-scheme--file-capability-grants context)
           (agent-scheme--file-capability-legacy-grants
            legacy-allowed-paths operation)))
         match
         denied)
    (agent-scheme--file-capability-record-request
     request operation filename path)
    (when (agent-scheme--file-capability-remote-path-p filename path)
      (agent-scheme--file-capability-deny
       request request-id operation filename path nil
       "remote file paths require a non-file capability domain"
       nil
       context
       binding))
    (unless file-grants
      (agent-scheme--file-capability-deny
       request request-id operation filename path nil
       (format "%s requires policy-gated host file access: %s"
               binding filename)
       t
       context
       binding))
    (dolist (grant file-grants)
      (let ((candidate
             (agent-scheme--file-capability-grant-match
              grant path resolved-path operation context)))
        (when candidate
          (if (plist-get candidate :grant)
              (setq match candidate)
            (setq denied candidate)))))
    (unless match
      (agent-scheme--file-capability-deny
       request request-id operation filename path
       (plist-get denied :denied)
       (or (plist-get denied :reason)
           "no active file grant covers path")))
    (let ((grant (plist-get match :grant)))
      (agent-scheme-policy-authorize
       'standard-host-effect
       binding
       `((filename . ,filename)
         (path . ,path)
         (resolved-path . ,resolved-path)
         (grant . ,(agent-scheme--capability-grant-id grant)))
       context)
      (agent-scheme--capability-grant-use! grant context)
      (let ((decision
             (agent-scheme--file-capability-record-decision
              request request-id 'approved grant
              "path is inside approved file grant root"
              `((path . ,path)
                (resolved-path . ,resolved-path)
                (approved-root . ,(plist-get match :allowed-root))
                (resolved-root . ,(plist-get match :resolved-root)))))
            (handle
             (agent-scheme--file-capability-register-handle
              path resolved-path grant operation)))
        (list :path path
              :resolved-path resolved-path
              :operation operation
              :request request
              :decision decision
              :handle handle
              :grant grant)))))

(defun agent-scheme--capability-grant-scope-match-p
    (grant name arguments context)
  "Return non-nil when GRANT scope matches NAME with ARGUMENTS."
  (let* ((target-handle
          (agent-scheme--capability-operation-buffer-handle name arguments))
         (grant-handle
          (agent-scheme--capability-scope-value grant "buffer"))
         (operation-region
          (agent-scheme--capability-operation-region name arguments))
         (grant-range
          (agent-scheme--capability-range-values grant))
         (session
          (agent-scheme--capability-scope-value grant "session"))
         (file
          (or (agent-scheme--capability-scope-value grant "file")
              (agent-scheme--capability-scope-value grant "path")))
         (project-root
          (agent-scheme--capability-scope-value grant "project-root"))
         (skill
          (agent-scheme--capability-scope-value grant "skill")))
    (agent-scheme--capability-check-grant-handle-live grant grant-handle)
    (and
     (or (null grant-handle)
         (agent-scheme--capability-same-handle-p grant-handle target-handle))
     (or (null grant-range)
         (and operation-region
              (<= (car grant-range) (car operation-region))
              (<= (cadr operation-region) (cadr grant-range))))
     (or (null session)
         (equal (agent-scheme--capability-grant-id-name session)
                (and context
                     (agent-scheme--eval-context-p context)
                     (agent-scheme--eval-context-session-id context))))
     (or (null skill)
         ;; No skill execution identity exists yet, so skill-scoped grants are
         ;; declarative until a host activates a matching skill context.
         nil)
     (or (and (null file) (null project-root))
         (let* ((buffer
                 (and target-handle
                      (agent-scheme-handle-p target-handle)
                      (agent-scheme-capability-handle-live-p target-handle)
                      (agent-scheme--live-buffer-for-handle
                       target-handle name)))
                (target-file
                 (and buffer (agent-scheme--buffer-target-file buffer))))
           (and
            (or (null file)
                (and target-file
                     (equal (expand-file-name file)
                            (expand-file-name target-file))))
            (or (null project-root)
                (agent-scheme--capability-file-in-project-p
                 target-file project-root))))))))

(defun agent-scheme--capability-grant-candidate-p (grant spec name)
  "Return non-nil when GRANT targets SPEC and NAME."
  (and (equal (agent-scheme--capability-grant-library-key grant)
              (plist-get spec :library))
       (equal (agent-scheme--capability-grant-effect-name grant)
              name)))

(defun agent-scheme--capability-grant-mark-expired!
    (grant context operation)
  "Mark GRANT expired in CONTEXT and audit OPERATION."
  (let ((expired
         (agent-scheme--capability-grant-replace-field
          grant "status"
          (list (agent-scheme--capability-grant-symbol "expired")))))
    (agent-scheme--capability-store-grant! expired context)
    (agent-scheme--capability-audit-grant operation expired 'expired)
    (agent-scheme--capability-audit-revocation
     expired 'expired "capability grant expired")
    expired))

(defun agent-scheme--capability-revocation-datum
    (grant status reason)
  "Return a Scheme-readable revocation datum for GRANT."
  (let ((grant-id (agent-scheme--capability-grant-id grant)))
    `(,(agent-scheme--capability-grant-symbol "capability-revocation")
      (,(agent-scheme--capability-grant-symbol "id")
       ,(agent-scheme--capability-revocation-id))
      (,(agent-scheme--capability-grant-symbol "target")
       (,(agent-scheme--capability-grant-symbol "grant") ,grant-id))
      (,(agent-scheme--capability-grant-symbol "status")
       ,(agent-scheme--capability-grant-symbol status))
      (,(agent-scheme--capability-grant-symbol "reason") ,reason))))

(defun agent-scheme--capability-audit-revocation
    (grant status reason)
  "Audit a capability revocation for GRANT."
  (let* ((grant-id (agent-scheme--capability-grant-id grant))
         (revocation
          (agent-scheme--capability-revocation-datum
           grant status reason)))
    (agent-scheme-audit-record
     'capability-revocation
     `((revocation . ,revocation)
       (target . (grant ,grant-id))
       (status . ,status)
       (reason . ,reason)))))

(defun agent-scheme--capability-grant-use! (grant context)
  "Record one successful use of GRANT in CONTEXT."
  (agent-scheme--capability-audit-grant
   "capability-grant-use" grant 'allowed)
  (when-let ((uses (agent-scheme--capability-grant-field-value
                    grant "uses-remaining")))
    (let* ((remaining (1- (agent-scheme--capability-exact-integer
                           uses "capability grant uses-remaining")))
           (updated
            (agent-scheme--capability-grant-replace-field
             grant "uses-remaining"
             (list (agent-scheme--scheme-integer remaining)))))
      (agent-scheme--capability-store-grant! updated context)
      (when (<= remaining 0)
        (agent-scheme--capability-grant-mark-expired!
         updated context "capability-grant-expire!")))))

(defun agent-scheme--require-capability-grant (name arguments context spec)
  "Require a matching capability grant for NAME with ARGUMENTS."
  (let ((candidate nil)
        (denied nil))
    (dolist (grant (agent-scheme--capability-context-grants context))
      (when (agent-scheme--capability-grant-candidate-p grant spec name)
        (unless candidate
          (setq candidate grant))
        (cond
         ((eq (agent-scheme--capability-grant-status grant) 'revoked)
          (setq denied
                (list grant "revoked capability grant")))
         ((not (agent-scheme--capability-grant-active-p grant))
          (setq denied
                (list grant "expired capability grant")))
         ((agent-scheme--capability-grant-scope-match-p
           grant name arguments context)
          (agent-scheme--capability-grant-use! grant context)
          (setq candidate :authorized))
         ((not denied)
          (setq denied
                (list grant "outside capability grant scope"))))))
    (cond
     ((eq candidate :authorized)
      t)
     (denied
      (agent-scheme--capability-grant-error
       (cadr denied)
       (car denied)
       `((capability . ,name)
         (arguments . ,arguments))))
     (candidate
      (agent-scheme--capability-grant-error
       "outside capability grant scope"
       candidate
       `((capability . ,name)
         (arguments . ,arguments))))
     (t
      (agent-scheme--capability-grant-error
       (format "missing capability grant for %s" name)
       nil
       `((capability . ,name)
         (arguments . ,arguments)))))))

(defun agent-scheme--authorize-capability-grant-datum (grant context)
  "Authorize creation of GRANT in CONTEXT."
  (if (agent-scheme--file-capability-grant-domain-p grant)
      (agent-scheme-policy-authorize
       'standard-host-effect
       "grant-capability!"
       `((domain . file)
         (operations . ,(agent-scheme--capability-grant-field-values
                         grant "operations"))
         (grant . ,grant))
       context
       'capability-grant)
    (let* ((library (agent-scheme--capability-grant-library-key grant))
           (effect (agent-scheme--capability-grant-effect-name grant))
           (spec (agent-scheme--emacs-capability-manifest-spec effect))
           (category (agent-scheme--emacs-capability-policy-category spec)))
      (agent-scheme-policy-authorize
       category
       "grant-capability!"
       `((library . ,library)
         (capability . ,effect)
         (grant . ,grant))
       context
       'capability-grant))))

(defun agent-scheme-capability-grant! (datum &optional context)
  "Create a capability grant from DATUM in CONTEXT."
  (let ((grant (agent-scheme--capability-grant-normalize datum)))
    (agent-scheme--authorize-capability-grant-datum grant context)
    (agent-scheme--capability-store-grant! grant context)
    (agent-scheme--capability-audit-grant
     "grant-capability!" grant 'created)
    grant))

(defun agent-scheme-capability-current-grants (&optional context)
  "Return current active capability grants in CONTEXT."
  (agent-scheme--capability-current-grants context))

(defun agent-scheme-capability-grant-ref (id &optional context)
  "Return capability grant ID from CONTEXT, or nil."
  (agent-scheme--capability-grant-by-id id context))

(defun agent-scheme--capability-restriction-field (restrictions name)
  "Return field NAME from RESTRICTIONS."
  (seq-find
   (lambda (field)
     (agent-scheme--capability-grant-field-named-p field name))
   restrictions))

(defun agent-scheme--capability-scope-range-values (scope)
  "Return SCOPE range values, or nil."
  (when-let ((clause
              (seq-find
               (lambda (entry)
                 (or (agent-scheme--capability-grant-field-named-p
                      entry "range")
                     (agent-scheme--capability-grant-field-named-p
                      entry "region")))
               scope)))
    (list
     (agent-scheme--capability-exact-integer
      (cadr clause) "attenuated grant range start")
     (agent-scheme--capability-exact-integer
      (caddr clause) "attenuated grant range end"))))

(defun agent-scheme--capability-range-contained-p (inner outer)
  "Return non-nil when INNER range is contained by OUTER range."
  (or (null outer)
      (and inner
           (<= (car outer) (car inner))
           (<= (cadr inner) (cadr outer)))))

(defun agent-scheme--capability-scope-clause-named (scope name)
  "Return clause NAME from SCOPE."
  (seq-find
   (lambda (clause)
     (agent-scheme--capability-grant-field-named-p clause name))
   scope))

(defun agent-scheme--capability-merge-scope (parent restriction)
  "Return parent scope attenuated by RESTRICTION scope."
  (let* ((parent-scope parent)
         (child-scope (cdr restriction))
         (parent-range
          (agent-scheme--capability-scope-range-values parent-scope))
         (child-range
          (agent-scheme--capability-scope-range-values child-scope))
         (merged (copy-tree parent-scope)))
    (unless (agent-scheme--capability-range-contained-p
             child-range parent-range)
      (signal 'agent-scheme-capability-grant-error
              (list "attenuated grant range must stay within parent grant")))
    (dolist (clause child-scope)
      (let ((name (agent-scheme--capability-grant-symbol-name (car clause))))
        (when-let ((parent-clause
                    (and (not (member name '("range" "region")))
                         (agent-scheme--capability-scope-clause-named
                          parent-scope name))))
          (unless (equal parent-clause clause)
            (signal 'agent-scheme-capability-grant-error
                    (list "attenuated grant cannot broaden parent scope"))))
        (setq merged
              (cons clause
                    (seq-remove
                     (lambda (candidate)
                       (member
                        (agent-scheme--capability-grant-symbol-name
                         (car candidate))
                        (if (member name '("range" "region"))
                            '("range" "region")
                          (list name))))
                     merged)))))
    (nreverse merged)))

(defun agent-scheme--capability-merge-expires (parent-expires child-expires)
  "Return CHILD-EXPIRES when it does not broaden PARENT-EXPIRES."
  (let ((parent-uses (agent-scheme--capability-grant-expires-uses
                      parent-expires))
        (child-uses (agent-scheme--capability-grant-expires-uses
                     child-expires))
        (parent-name (agent-scheme--capability-grant-symbol-name
                      parent-expires))
        (child-name (agent-scheme--capability-grant-symbol-name
                     child-expires)))
    (cond
     ((equal child-name "after-eval")
      child-expires)
     ((and parent-uses child-uses (<= child-uses parent-uses))
      child-expires)
     ((and (equal parent-name "never")
           (or child-uses (equal child-name "never")))
      child-expires)
     ((equal parent-name child-name)
      child-expires)
     (t
      (signal 'agent-scheme-capability-grant-error
              (list "attenuated grant cannot broaden parent lifetime"))))))

(defun agent-scheme-capability-grant-attenuate
    (grant-id restrictions &optional context)
  "Create an attenuated child grant from GRANT-ID using RESTRICTIONS."
  (let* ((parent
          (or (agent-scheme--capability-grant-by-id grant-id context)
              (signal 'agent-scheme-capability-grant-error
                      (list "unknown parent capability grant"))))
         (parent-scope
          (agent-scheme--capability-grant-scope-clauses parent))
         (child
          (agent-scheme--capability-grant-remove-fields
           (copy-tree parent)
           '("id" "status" "uses-remaining" "parent")))
         (id-field
          (agent-scheme--capability-restriction-field restrictions "id"))
         (scope-field
          (agent-scheme--capability-restriction-field restrictions "scope"))
         (expires-field
          (agent-scheme--capability-restriction-field restrictions "expires"))
         (child-id
          (or (cadr id-field)
              (agent-scheme--capability-generated-grant-id))))
    (unless (agent-scheme--capability-grant-active-p parent)
      (signal 'agent-scheme-capability-grant-error
              (list "cannot attenuate inactive capability grant")))
    (dolist (field restrictions)
      (let ((name (agent-scheme--capability-grant-symbol-name (car field))))
        (unless (member name '("id" "scope" "expires"))
          (when (and (member name '("library" "effect"))
                     (not (equal
                           (cdr field)
                           (cdr (agent-scheme--capability-grant-field
                                 parent name)))))
            (signal 'agent-scheme-capability-grant-error
                    (list "attenuated grant cannot broaden parent authority")))
          (setq child
                (agent-scheme--capability-grant-replace-field
                 child name (cdr field))))))
    (when scope-field
      (setq child
            (agent-scheme--capability-grant-replace-field
             child "scope"
             (agent-scheme--capability-merge-scope parent-scope scope-field))))
    (when expires-field
      (setq child
            (agent-scheme--capability-grant-replace-field
             child "expires"
             (list
               (agent-scheme--capability-merge-expires
                (agent-scheme--capability-grant-field-value parent "expires")
               (cadr expires-field))))))
    (setq child
          (agent-scheme--capability-grant-replace-field
           child "id" (list (agent-scheme--capability-grant-symbol child-id))))
    (setq child
          (agent-scheme--capability-grant-replace-field
           child "parent"
           (list (agent-scheme--capability-grant-id parent))))
    (setq child (agent-scheme--capability-grant-normalize child))
    (agent-scheme--capability-store-grant! child context)
    (agent-scheme--capability-audit-grant
     "grant-attenuate" child 'attenuated
     `((parent . ,(agent-scheme--capability-grant-id parent))))
    child))

(defun agent-scheme-capability-grant-revoke! (grant-id &optional context)
  "Revoke capability grant GRANT-ID in CONTEXT and return it."
  (let* ((grant
          (or (agent-scheme--capability-grant-by-id grant-id context)
              (signal 'agent-scheme-capability-grant-error
                      (list "unknown capability grant"))))
         (revoked
          (agent-scheme--capability-grant-replace-field
           grant "status"
           (list (agent-scheme--capability-grant-symbol "revoked")))))
    (agent-scheme--capability-store-grant! revoked context)
    (agent-scheme--capability-audit-grant
     "grant-revoke!" revoked 'revoked)
    (agent-scheme--capability-audit-revocation
     revoked 'revoked "grant-revoke!")
    revoked))

(defun agent-scheme-capability-expire-after-eval! (context)
  "Expire all active after-eval grants in CONTEXT."
  (dolist (grant (agent-scheme--capability-context-grants context))
    (when (and (agent-scheme--capability-grant-active-p grant)
               (equal
                (agent-scheme--capability-grant-symbol-name
                 (agent-scheme--capability-grant-field-value
                  grant "expires"))
                "after-eval"))
      (agent-scheme--capability-grant-mark-expired!
       grant context "capability-grant-expire!"))))

(defun agent-scheme--primitive-grant-capability (arguments context)
  "Primitive grant-capability! over ARGUMENTS."
  (agent-scheme-capability-grant! (car arguments) context))

(defun agent-scheme--primitive-current-grants (_arguments context)
  "Primitive current-grants."
  (agent-scheme-capability-current-grants context))

(defun agent-scheme--primitive-grant-ref (arguments context)
  "Primitive grant-ref over ARGUMENTS."
  (or (agent-scheme-capability-grant-ref (car arguments) context)
      agent-scheme-false))

(defun agent-scheme--primitive-grant-attenuate (arguments context)
  "Primitive grant-attenuate over ARGUMENTS."
  (agent-scheme-capability-grant-attenuate
   (car arguments) (cadr arguments) context))

(defun agent-scheme--primitive-grant-revoke (arguments context)
  "Primitive grant-revoke! over ARGUMENTS."
  (agent-scheme-capability-grant-revoke! (car arguments) context))

(defun agent-scheme--primitive-call-with-capability-grant
    (arguments context)
  "Primitive call-with-capability-grant over ARGUMENTS."
  (let* ((grant-or-id (car arguments))
         (thunk (cadr arguments))
         (grant
          (if (agent-scheme--capability-grant-datum-p grant-or-id)
              (agent-scheme-capability-grant! grant-or-id context)
            (or (agent-scheme-capability-grant-ref grant-or-id context)
                (signal 'agent-scheme-capability-grant-error
                        (list "unknown capability grant")))))
         (active (agent-scheme--eval-context-active-capability-grants
                  context)))
    (unwind-protect
        (progn
          (push (agent-scheme--capability-grant-id grant)
                (agent-scheme--eval-context-active-capability-grants
                 context))
          (agent-scheme--apply-procedure
           thunk nil context nil))
      (setf (agent-scheme--eval-context-active-capability-grants context)
            active))))

(defun agent-scheme-capability-primitive-specs ()
  "Return primitive specs for the private `(agent capability primitive)' library."
  `(("grant-capability!" ,#'agent-scheme--primitive-grant-capability 1 1)
    ("current-grants" ,#'agent-scheme--primitive-current-grants 0 0)
    ("grant-ref" ,#'agent-scheme--primitive-grant-ref 1 1)
    ("grant-attenuate" ,#'agent-scheme--primitive-grant-attenuate 2 2)
    ("grant-revoke!" ,#'agent-scheme--primitive-grant-revoke 1 1)
    ("call-with-capability-grant"
     ,#'agent-scheme--primitive-call-with-capability-grant 2 2)))

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
       'capability-call)
      (when (and agent-scheme-capability-require-grants-for-mutations
                 (plist-get spec :requires-grant))
        (agent-scheme--require-capability-grant
         name arguments context spec)))))

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
