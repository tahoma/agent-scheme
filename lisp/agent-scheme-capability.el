;;; agent-scheme-capability.el --- Emacs capability primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; Host adapter primitives for read-only Emacs capability libraries.  Scheme
;; programs receive opaque handles; live Emacs objects stay in a private side
;; table owned by this module.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)

(cl-defstruct (agent-scheme--handle-entry
               (:constructor agent-scheme--make-handle-entry (kind object))
               (:copier nil))
  "Private host object registered behind an opaque Agent Scheme handle."
  kind object)

(defvar agent-scheme--handle-registry (make-hash-table :test #'equal)
  "Private table from opaque handle ids to live host objects.")

(defvar agent-scheme--next-handle-number 0
  "Next numeric suffix for generated opaque handle ids.")

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
    (:name "project-root" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-project
     :emacs-hook agent-scheme--primitive-project-root
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs project))
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
     (list (plist-get spec :name)
           (plist-get spec :emacs-hook)
           (plist-get spec :minimum-arity)
           (plist-get spec :maximum-arity)))
   (seq-filter
    (lambda (spec)
      (equal (plist-get spec :library) library))
    agent-scheme--emacs-capability-manifest-specs)))

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

(defun agent-scheme--buffer-handle (buffer)
  "Return an opaque handle for BUFFER."
  (agent-scheme--register-handle 'buffer buffer))

(defun agent-scheme--window-handle (window)
  "Return an opaque handle for WINDOW."
  (agent-scheme--register-handle 'window window))

(defun agent-scheme--primitive-emacs-current-buffer (_arguments _context)
  "Primitive emacs-current-buffer."
  (agent-scheme--buffer-handle (current-buffer)))

(defun agent-scheme--primitive-buffer-name (arguments _context)
  "Primitive buffer-name over ARGUMENTS."
  (buffer-name
   (agent-scheme--live-buffer-for-handle (car arguments) "buffer-name")))

(defun agent-scheme--primitive-buffer-file-name (arguments _context)
  "Primitive buffer-file-name over ARGUMENTS."
  (agent-scheme--maybe-string
   (buffer-local-value
    'buffer-file-name
    (agent-scheme--live-buffer-for-handle
     (car arguments) "buffer-file-name"))))

(defun agent-scheme--primitive-buffer-major-mode (arguments _context)
  "Primitive buffer-major-mode over ARGUMENTS."
  (agent-scheme--scheme-symbol
   (buffer-local-value
    'major-mode
    (agent-scheme--live-buffer-for-handle
     (car arguments) "buffer-major-mode"))))

(defun agent-scheme--primitive-buffer-point (arguments _context)
  "Primitive buffer-point over ARGUMENTS."
  (agent-scheme--scheme-integer
   (with-current-buffer
       (agent-scheme--live-buffer-for-handle (car arguments) "buffer-point")
     (point))))

(defun agent-scheme--primitive-buffer-text (arguments _context)
  "Primitive buffer-text over ARGUMENTS."
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

(defun agent-scheme--primitive-emacs-buffer-list (_arguments _context)
  "Primitive emacs-buffer-list."
  (mapcar #'agent-scheme--buffer-handle (buffer-list)))

(defun agent-scheme--primitive-emacs-window-list (_arguments _context)
  "Primitive emacs-window-list."
  (mapcar #'agent-scheme--window-handle (window-list nil 'no-minibuf)))

(defun agent-scheme--primitive-project-root (_arguments _context)
  "Primitive project-root."
  (let ((project (project-current nil)))
    (if project
        (file-name-as-directory (expand-file-name (project-root project)))
      agent-scheme-false)))

(defun agent-scheme--documentation-string (symbol commandp)
  "Return raw documentation string for SYMBOL.
When COMMANDP is non-nil, SYMBOL must name an interactive command."
  (if (and symbol
           (if commandp (commandp symbol) (fboundp symbol)))
      (agent-scheme--maybe-string (documentation symbol t))
    agent-scheme-false))

(defun agent-scheme--primitive-command-doc (arguments _context)
  "Primitive command-doc over ARGUMENTS."
  (agent-scheme--documentation-string
   (agent-scheme--capability-name-symbol (car arguments) "command-doc")
   t))

(defun agent-scheme--primitive-function-doc (arguments _context)
  "Primitive function-doc over ARGUMENTS."
  (agent-scheme--documentation-string
   (agent-scheme--capability-name-symbol (car arguments) "function-doc")
   nil))

(defun agent-scheme--primitive-variable-info (arguments _context)
  "Primitive variable-info over ARGUMENTS without exposing variable values."
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
