;;; agent-scheme-capability.el --- Emacs capability primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; Host adapter primitives for Emacs capability libraries.  Scheme programs
;; receive opaque handles; live Emacs objects stay in a private side table
;; owned by this module.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'project)
(require 'seq)
(require 'url-parse)
(require 'agent-scheme-audit)
(require 'agent-scheme-diagnostics)
(require 'agent-scheme-diff)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)
(require 'agent-scheme-vcs)

(declare-function agent-scheme--apply-procedure "agent-scheme-interpreter")

(define-error 'agent-scheme-capability-grant-error
  "Agent Scheme capability grant denied"
  'agent-scheme-eval-error)

(defcustom agent-scheme-capability-require-grants-for-mutations t
  "Non-nil means host mutation capabilities require matching grants."
  :type 'boolean
  :group 'agent-scheme)

(defcustom agent-scheme-command-whitelist
  '((save-buffer :allow-interactive nil)
    (revert-buffer :allow-interactive nil :default-arguments (nil t))
    (compile :allow-interactive nil)
    (recompile :allow-interactive nil))
  "Commands that `command-call!' may invoke from Agent Scheme.
Each entry has the form (COMMAND . PLIST).  COMMAND must name an
interactive Emacs command.  `:allow-interactive' permits
`command-call!' to collect interactive arguments with
`call-interactively' when the supplied Scheme arguments are
insufficient.  Keep this disabled unless a command's prompts are
known to be bounded and safe.  `:default-arguments' supplies Emacs
Lisp arguments when Scheme does not pass any arguments."
  :type '(alist :key-type symbol
                :value-type
                (plist :options
                       ((:allow-interactive boolean)
                        (:default-arguments sexp))))
  :group 'agent-scheme)

(defcustom agent-scheme-process-command-allowlist nil
  "Command names that `process-start!' may launch.
Entries may be command strings or symbols.  Process grants still
need to authorize the specific command, working directory, and
operations requested by Scheme code."
  :type '(repeat (choice string symbol))
  :group 'agent-scheme)

(defun agent-scheme--default-process-start
    (name command arguments options _context)
  "Default host adapter for `process-start!'."
  (let* ((buffer (generate-new-buffer
                  (format " *Agent Scheme process: %s*" name)))
         (process-environment
          (append
           (mapcar
            (lambda (entry)
              (format "%s=%s" (car entry) (cadr entry)))
            (agent-scheme--process-normalized-environment options))
           process-environment))
         (process (apply #'start-process name buffer command arguments)))
    (set-process-query-on-exit-flag process nil)
    (list :name name
          :command command
          :arguments arguments
          :status (process-status process)
          :process process
          :buffer buffer
          :stdout ""
          :stderr "")))

(defcustom agent-scheme-process-start-function
  #'agent-scheme--default-process-start
  "Function that starts host process jobs for `process-start!'.
The function receives NAME, COMMAND, ARGUMENTS, OPTIONS, and
CONTEXT, and returns either a host process object or a plist with
Scheme-readable metadata such as `:name', `:status', `:stdout',
and `:stderr'.  It is called only after command allow-list,
grant, and policy checks succeed."
  :type 'function
  :group 'agent-scheme)

(defun agent-scheme--default-network-request (resource _context)
  "Default host adapter for network requests.
RESOURCE is a redacted Scheme-readable request resource.  The
default refuses live transport so tests and hosts must install an
explicit adapter before bytes can leave the runtime."
  (signal 'agent-scheme-capability-grant-error
          (list "no network request adapter configured")))

(defcustom agent-scheme-network-request-function
  #'agent-scheme--default-network-request
  "Function that performs authorized network request resources.
The function receives a redacted Scheme-readable RESOURCE and
CONTEXT after network grant, policy, and redaction checks have
succeeded.  It must return a Scheme-readable response datum."
  :type 'function
  :group 'agent-scheme)

(defun agent-scheme--default-network-stream (resource _context)
  "Default host adapter for network stream requests."
  (signal 'agent-scheme-capability-grant-error
          (list "no network stream adapter configured")))

(defcustom agent-scheme-network-stream-function
  #'agent-scheme--default-network-stream
  "Function that opens authorized network stream resources.
The function receives a redacted Scheme-readable RESOURCE and
CONTEXT after network grant, policy, and redaction checks have
succeeded.  It must return textual stream contents for the
network-backed port."
  :type 'function
  :group 'agent-scheme)

(defcustom agent-scheme-search-default-limit 100
  "Default maximum number of results returned by one search capability call."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-search-default-file-limit 10000
  "Default maximum number of project files considered by search calls."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-search-default-maximum-file-bytes 1048576
  "Default maximum size of a project file read by search capabilities."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-search-default-preview-characters 160
  "Default maximum number of line-preview characters in search results."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-search-generated-directories
  '(".agent-scheme"
    ".cache"
    ".git"
    ".hg"
    ".svn"
    "__pycache__"
    "build"
    "coverage"
    "dist"
    "node_modules"
    "target"
    "vendor")
  "Project subdirectories skipped by search capabilities unless requested."
  :type '(repeat string)
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

(defvar agent-scheme--next-port-capability-handle-number 0
  "Next numeric suffix for generated port capability handle ids.")

(defvar agent-scheme--next-code-loading-request-number 0
  "Next numeric suffix for generated code-loading request ids.")

(defvar agent-scheme--next-code-loading-decision-number 0
  "Next numeric suffix for generated code-loading decision ids.")

(defvar agent-scheme--next-process-capability-request-number 0
  "Next numeric suffix for generated process capability request ids.")

(defvar agent-scheme--next-process-capability-decision-number 0
  "Next numeric suffix for generated process capability decision ids.")

(defvar agent-scheme--next-process-port-capability-handle-number 0
  "Next numeric suffix for generated process-backed port capability ids.")

(defvar agent-scheme--next-network-capability-request-number 0
  "Next numeric suffix for generated network capability request ids.")

(defvar agent-scheme--next-network-capability-decision-number 0
  "Next numeric suffix for generated network capability decision ids.")

(defvar agent-scheme--next-network-stream-handle-number 0
  "Next numeric suffix for generated network stream handles.")

(defvar agent-scheme--next-network-port-capability-handle-number 0
  "Next numeric suffix for generated network-backed port capability ids.")

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
    (:name "buffer-switch!" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook agent-scheme--primitive-buffer-switch!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs buffer window session mutation))
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
    (:name "window-select!" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-window
     :emacs-hook agent-scheme--primitive-window-select!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs window session mutation))
    (:name "window-split!" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-window
     :emacs-hook agent-scheme--primitive-window-split!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs window session mutation))
    (:name "window-delete!" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-window
     :emacs-hook agent-scheme--primitive-window-delete!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs window session mutation))
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
    (:name "project-compile!" :library "(emacs project)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-project
     :emacs-hook agent-scheme--primitive-project-compile!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :test-categories (emacs project command process mutation))
    (:name "project-recompile!" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-mutation
     :required-capability emacs-project
     :emacs-hook agent-scheme--primitive-project-recompile!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :test-categories (emacs project command process mutation))
    (:name "buffer-search" :library "(emacs search)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook agent-scheme--primitive-buffer-search
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search buffer))
    (:name "project-search" :library "(emacs search)"
     :minimum-arity 2 :maximum-arity 2
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook agent-scheme--primitive-project-search
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search project))
    (:name "project-files" :library "(emacs search)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook agent-scheme--primitive-project-files
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search project files))
    (:name "buffer-diff" :library "(emacs diff)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diff
     :emacs-hook agent-scheme--primitive-buffer-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diff buffer))
    (:name "file-diff" :library "(emacs diff)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diff
     :emacs-hook agent-scheme--primitive-file-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diff file))
    (:name "project-diff" :library "(emacs diff)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diff
     :emacs-hook agent-scheme--primitive-project-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diff project))
    (:name "vcs-root" :library "(emacs vcs)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-root
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs root))
    (:name "vcs-branch" :library "(emacs vcs)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-branch
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs branch))
    (:name "vcs-status" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-status
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs status))
    (:name "vcs-diff" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs diff))
    (:name "vcs-recent-commits" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-recent-commits
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs commits))
    (:name "vcs-yield" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-yield
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs yield))
    (:name "vcs-stage!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-stage!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation stage))
    (:name "vcs-unstage!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-unstage!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation unstage))
    (:name "vcs-commit!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-commit!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation commit))
    (:name "vcs-branch-create!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-branch-create!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation branch))
    (:name "vcs-switch!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-switch!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation switch))
    (:name "vcs-fetch!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-fetch!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation remote fetch))
    (:name "vcs-pull!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-pull!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation remote pull))
    (:name "vcs-push!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook agent-scheme--primitive-vcs-push!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation remote push))
    (:name "buffer-diagnostics" :library "(emacs diagnostics)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diagnostics
     :emacs-hook agent-scheme--primitive-buffer-diagnostics
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diagnostics buffer))
    (:name "project-diagnostics" :library "(emacs diagnostics)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diagnostics
     :emacs-hook agent-scheme--primitive-project-diagnostics
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diagnostics project))
    (:name "diagnostic-at" :library "(emacs diagnostics)"
     :minimum-arity 2 :maximum-arity 2
     :source host-capability :effect host-observation
     :required-capability emacs-diagnostics
     :emacs-hook agent-scheme--primitive-diagnostic-at
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diagnostics buffer))
    (:name "search-yield" :library "(emacs search)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook agent-scheme--primitive-search-yield
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search agent-io))
    (:name "process-start!" :library "(emacs process)"
     :minimum-arity 4 :maximum-arity 4
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-start!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process mutation handle))
    (:name "emacs-process-list" :library "(emacs process)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-emacs-process-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process handle))
    (:name "process-name" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process))
    (:name "process-status" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-status
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process))
    (:name "process-buffer" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-buffer
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process buffer handle))
    (:name "process-output-port" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-output-port
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process port output))
    (:name "process-error-port" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-error-port
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process port output))
    (:name "process-input-port" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-input-port
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process port input mutation))
    (:name "process-interrupt!" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-interrupt!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process control mutation))
    (:name "process-kill!" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook agent-scheme--primitive-process-kill!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process control mutation))
    (:name "network-http-request" :library "(emacs network)"
     :minimum-arity 5 :maximum-arity 5
     :source host-capability :effect host-network
     :required-capability network
     :emacs-hook agent-scheme--primitive-network-http-request
     :portable-hook nil :emitter-hook capability-network
     :policy deny :policy-category network-access
     :requires-network-grant t
     :test-categories (emacs network http))
    (:name "network-open-sse-stream" :library "(emacs network)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-network
     :required-capability network
     :emacs-hook agent-scheme--primitive-network-open-sse-stream
     :portable-hook nil :emitter-hook capability-network
     :policy deny :policy-category network-access
     :requires-network-grant t
     :test-categories (emacs network sse port stream))
    (:name "command-doc" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook agent-scheme--primitive-command-doc
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation))
    (:name "command-call!" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity nil
     :source host-capability :effect host-mutation
     :required-capability emacs-command
     :emacs-hook agent-scheme--primitive-command-call!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :test-categories (emacs command process mutation whitelist))
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
    "(emacs diagnostics)"
    "(emacs diff)"
    "(emacs frame)"
    "(emacs network)"
    "(emacs process)"
    "(emacs project)"
    "(emacs search)"
    "(emacs vcs)"
    "(emacs vcs mutation)"
    "(emacs window)")
  "Recognized Emacs capability library keys.")

(defun agent-scheme-emacs-capability-binding-specs ()
  "Return manifest metadata for Emacs capability primitive bindings."
  (mapcar
   (lambda (spec)
     (append spec
             (list :backend-effect-path 'shared-capability-request
                   :policy-category 'emacs-read-only)))
   agent-scheme--emacs-capability-manifest-specs))

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
                      "buffer-replace!" "buffer-save!"
                      "buffer-switch!"))
    (car arguments)))

(defun agent-scheme--capability-operation-window-handle (name arguments)
  "Return the window handle argument for capability NAME."
  (when (member name '("window-select!" "window-delete!"))
    (car arguments)))

(defun agent-scheme--capability-operation-direction (name arguments)
  "Return the direction argument for capability NAME, or nil."
  (when (equal name "window-split!")
    (agent-scheme--capability-direction-name
     (car arguments) "window-split! direction")))

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

(defun agent-scheme--process-capability-request-id ()
  "Return a fresh process capability request id."
  (agent-scheme--capability-grant-symbol
   (format "req-process-%d"
           (cl-incf agent-scheme--next-process-capability-request-number))))

(defun agent-scheme--process-capability-decision-id ()
  "Return a fresh process capability decision id."
  (agent-scheme--capability-grant-symbol
   (format "dec-process-%d"
           (cl-incf agent-scheme--next-process-capability-decision-number))))

(defun agent-scheme--process-port-capability-handle-id ()
  "Return a fresh process-backed port capability handle id."
  (agent-scheme--capability-grant-symbol
   (format "p-process-%d"
           (cl-incf agent-scheme--next-process-port-capability-handle-number))))

(defun agent-scheme--network-capability-request-id ()
  "Return a fresh network capability request id."
  (agent-scheme--capability-grant-symbol
   (format "req-network-%d"
           (cl-incf agent-scheme--next-network-capability-request-number))))

(defun agent-scheme--network-capability-decision-id ()
  "Return a fresh network capability decision id."
  (agent-scheme--capability-grant-symbol
   (format "dec-network-%d"
           (cl-incf agent-scheme--next-network-capability-decision-number))))

(defun agent-scheme--network-stream-handle-id ()
  "Return a fresh network stream handle id."
  (format "h-network-%d"
          (cl-incf agent-scheme--next-network-stream-handle-number)))

(defun agent-scheme--network-port-capability-handle-id ()
  "Return a fresh network-backed port capability handle id."
  (agent-scheme--capability-grant-symbol
   (format "p-network-%d"
           (cl-incf agent-scheme--next-network-port-capability-handle-number))))

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

(defun agent-scheme--port-capability-handle-id ()
  "Return a fresh port capability handle id."
  (agent-scheme--capability-grant-symbol
   (format "p-file-%d"
           (cl-incf agent-scheme--next-port-capability-handle-number))))

(defun agent-scheme--port-capability-datum
    (handle-id kind backing operations grant limits status path)
  "Return a Scheme-readable port capability datum."
  `(,(agent-scheme--capability-grant-symbol "port-capability")
    (,(agent-scheme--capability-grant-symbol "id") ,handle-id)
    (,(agent-scheme--capability-grant-symbol "kind")
     ,(agent-scheme--capability-grant-symbol kind))
    (,(agent-scheme--capability-grant-symbol "backing")
     ,(agent-scheme--capability-grant-symbol backing))
    (,(agent-scheme--capability-grant-symbol "operations")
     ,@operations)
    (,(agent-scheme--capability-grant-symbol "grant") ,grant)
    (,(agent-scheme--capability-grant-symbol "limits") ,@limits)
    (,(agent-scheme--capability-grant-symbol "path") ,path)
    (,(agent-scheme--capability-grant-symbol "status")
     ,(agent-scheme--capability-grant-symbol status))))

(defun agent-scheme--port-capability-limits (grant)
  "Return port limits inherited from GRANT, or nil."
  (agent-scheme--capability-grant-field-values grant "limits"))

(defun agent-scheme-capability-register-file-port
    (port kind authorization operations)
  "Attach a port capability handle to PORT and audit its creation.
AUTHORIZATION is the approved file authorization that created PORT."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (agent-scheme--capability-grant-id grant))
         (path (plist-get authorization :path))
         (limits (agent-scheme--port-capability-limits grant))
         (handle-id (agent-scheme--port-capability-handle-id))
         (handle
          (agent-scheme--port-capability-datum
           handle-id kind 'file operations grant-id limits 'open path)))
    (setf (agent-scheme--port-backing-domain port) 'file)
    (setf (agent-scheme--port-operations port) operations)
    (setf (agent-scheme--port-grant port) grant-id)
    (setf (agent-scheme--port-limits port) limits)
    (setf (agent-scheme--port-handle port) handle-id)
    (setf (agent-scheme--port-status port) 'open)
    (setf (agent-scheme--port-path port) path)
    (setf (agent-scheme--port-counters port) nil)
    (agent-scheme-audit-record
     'capability-handle
     `((handle . ,handle)
       (domain . port)
       (kind . ,kind)
       (backing . file)
       (operations . ,operations)
       (grant . ,grant-id)
       (limits . ,limits)
       (path . ,path)
       (status . open)))
    port))

(defun agent-scheme-capability-audit-port-result
    (port operation result &optional errored)
  "Audit host-backed PORT capability OPERATION with RESULT."
  (when (and port (agent-scheme--port-backing-domain port))
    (agent-scheme-audit-record
     'capability-audit
     `((domain . port)
       (operation . ,operation)
       (handle . ,(agent-scheme--port-handle port))
       (backing . ,(agent-scheme--port-backing-domain port))
       (grant . ,(agent-scheme--port-grant port))
       (path . ,(agent-scheme--port-path port))
       (result . ,(if errored
                      (list 'error result)
                    (list 'ok result)))))))

(defun agent-scheme--port-capability-limit-name (operation)
  "Return the limit field name for port OPERATION, or nil."
  (pcase operation
    ('read "reads")
    ('write "writes")
    ('flush "flushes")
    ('close "closes")
    (_ nil)))

(defun agent-scheme--port-capability-limit-value (port name)
  "Return PORT limit NAME as a host integer, or nil."
  (when name
    (when-let ((field
                (seq-find
                 (lambda (entry)
                   (and (consp entry)
                        (equal
                         (agent-scheme--capability-grant-symbol-name
                          (car entry))
                         name)))
                 (agent-scheme--port-limits port))))
      (agent-scheme--capability-exact-integer
       (cadr field)
       (format "port capability limit %s" name)))))

(defun agent-scheme--port-capability-counter (port name)
  "Return PORT operation counter NAME."
  (or (cdr (assoc name (agent-scheme--port-counters port))) 0))

(defun agent-scheme--port-capability-set-counter! (port name value)
  "Set PORT operation counter NAME to VALUE."
  (let ((counters (assq-delete-all name (agent-scheme--port-counters port))))
    (setf (agent-scheme--port-counters port)
          (cons (cons name value) counters))))

(defun agent-scheme--process-port-live-p (port)
  "Return non-nil when PORT's owning process handle is still live."
  (let ((id (agent-scheme--port-path port)))
    (and (stringp id)
         (let ((entry (gethash id agent-scheme--handle-registry)))
           (and entry
                (eq (agent-scheme--handle-entry-kind entry) 'process)
                (agent-scheme-capability--entry-live-p entry))))))

(defun agent-scheme--port-capability-check-limit! (port operation)
  "Consume one PORT operation limit unit for OPERATION."
  (let* ((name (agent-scheme--port-capability-limit-name operation))
         (limit (agent-scheme--port-capability-limit-value port name)))
    (when limit
      (let ((used (agent-scheme--port-capability-counter port name)))
        (when (>= used limit)
          (let ((reason (format "port capability limit exceeded: %s" name)))
            (agent-scheme-capability-audit-port-result
             port operation reason t)
            (signal 'agent-scheme-capability-grant-error (list reason))))
        (agent-scheme--port-capability-set-counter! port name (1+ used))))))

(defun agent-scheme-capability-revalidate-port-operation
    (port context operation)
  "Fail closed unless PORT can perform OPERATION in CONTEXT."
  (when (agent-scheme--port-backing-domain port)
    (cond
     ((not (agent-scheme--port-openp port))
      (agent-scheme-capability-audit-port-result
       port operation "closed port capability handle" t)
      (signal 'agent-scheme-capability-grant-error
              (list "stale port capability handle: closed port")))
     ((not (member operation (agent-scheme--port-operations port)))
      (agent-scheme-capability-audit-port-result
       port operation "operation outside port capability" t)
      (signal 'agent-scheme-capability-grant-error
              (list "operation outside port capability")))
     ((and (eq (agent-scheme--port-backing-domain port) 'process)
           (not (agent-scheme--process-port-live-p port)))
      (agent-scheme-capability-audit-port-result
       port operation "stale process port handle" t)
      (signal 'agent-scheme-capability-grant-error
              (list "stale port capability handle: process is not live")))
     ((and (eq (agent-scheme--port-backing-domain port) 'network)
           (not (agent-scheme--network-stream-live-p
                 (agent-scheme--port-path port))))
      (agent-scheme-capability-audit-port-result
       port operation "stale network stream handle" t)
      (signal 'agent-scheme-capability-grant-error
              (list "stale port capability handle: network stream is not live")))
     ((and (eq (agent-scheme--port-backing-domain port) 'network)
           (eq operation 'close))
      (agent-scheme--port-capability-check-limit! port operation))
     (t
      (let* ((grant-id (agent-scheme--port-grant port))
             (grant
              (and grant-id
                   (agent-scheme--capability-grant-by-id
                    grant-id context))))
          (unless (and grant
                     (agent-scheme--capability-grant-active-p grant))
          (agent-scheme-capability-audit-port-result
           port operation "inactive port capability grant" t)
          (signal 'agent-scheme-capability-grant-error
                  (list "stale port capability handle: inactive grant")))
        (agent-scheme--port-capability-check-limit! port operation)))))
  port)

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

(defun agent-scheme--process-capability-operation-symbol (operation)
  "Return OPERATION as an Agent Scheme symbol datum."
  (agent-scheme--capability-grant-symbol operation))

(defun agent-scheme--process-capability-effect-symbol (operation)
  "Return the effect class for process OPERATION."
  (agent-scheme--capability-grant-symbol
   (if (member (agent-scheme--capability-grant-symbol-name operation)
               '("spawn" "input" "interrupt" "terminate"))
       "process-control"
     "read-only-observation")))

(defun agent-scheme--process-capability-policy-category (operation)
  "Return policy category for process OPERATION."
  (if (member (agent-scheme--capability-grant-symbol-name operation)
              '("spawn" "input" "interrupt" "terminate"))
      'command-process
    'emacs-read-only))

(defun agent-scheme--process-capability-grant-domain-p (grant)
  "Return non-nil when GRANT is a process-domain grant."
  (equal (agent-scheme--capability-grant-symbol-name
          (agent-scheme--capability-grant-field-value grant "domain"))
         "process"))

(defun agent-scheme--process-capability-operation-p (grant operation)
  "Return non-nil when GRANT allows process OPERATION."
  (let ((operation-name
         (agent-scheme--capability-grant-symbol-name operation)))
    (cl-some
     (lambda (candidate)
       (equal (agent-scheme--capability-grant-symbol-name candidate)
              operation-name))
     (agent-scheme--file-capability-field-values-list
      (agent-scheme--capability-grant-field-values grant "operations")))))

(defun agent-scheme--process-capability-grants (context)
  "Return process-domain grants carried by CONTEXT."
  (seq-filter
   #'agent-scheme--process-capability-grant-domain-p
   (agent-scheme--capability-context-grants context)))

(defun agent-scheme--process-command-allowlist-entry (command)
  "Return non-nil when COMMAND is allowed for process creation."
  (seq-find
   (lambda (entry)
     (equal command (agent-scheme--capability-grant-symbol-name entry)))
   agent-scheme-process-command-allowlist))

(defun agent-scheme--process-option-field (options name)
  "Return process OPTIONS field named NAME, or nil."
  (seq-find
   (lambda (field)
     (agent-scheme--capability-grant-field-named-p field name))
   (agent-scheme--proper-list-elements options "process options")))

(defun agent-scheme--process-option-value (options name)
  "Return process OPTIONS field NAME's first value, or nil."
  (cadr (agent-scheme--process-option-field options name)))

(defun agent-scheme--process-cwd (options)
  "Return the process working directory described by OPTIONS."
  (let ((cwd (agent-scheme--process-option-value options "cwd")))
    (if cwd
        (file-name-as-directory
         (expand-file-name
          (agent-scheme--capability-string cwd "process cwd")))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun agent-scheme--process-string-list (datum description)
  "Return DATUM as a proper list of strings for DESCRIPTION."
  (mapcar
   (lambda (entry)
     (agent-scheme--capability-string entry description))
   (agent-scheme--proper-list-elements datum description)))

(defun agent-scheme--process-normalized-arguments (arguments)
  "Return process ARGUMENTS as host strings."
  (agent-scheme--process-string-list arguments "process arguments"))

(defun agent-scheme--process-environment-name (datum description)
  "Return DATUM as a process environment variable name."
  (or (agent-scheme--capability-grant-symbol-name datum)
      (agent-scheme--eval-error
       "%s expected an environment variable name, got %s"
       description
       (agent-scheme-value->external datum))))

(defun agent-scheme--process-environment-entry (entry description)
  "Return process environment ENTRY as a two-string list."
  (let ((elements (agent-scheme--proper-list-elements entry description)))
    (unless (= (length elements) 2)
      (agent-scheme--eval-error
       "%s expected environment entries as (name value)" description))
    (list (agent-scheme--process-environment-name (car elements) description)
          (agent-scheme--capability-string (cadr elements) description))))

(defun agent-scheme--process-normalized-environment (options)
  "Return process OPTIONS environment entries as (NAME VALUE) lists."
  (when-let ((environment
              (agent-scheme--process-option-value options "environment")))
    (mapcar
     (lambda (entry)
       (agent-scheme--process-environment-entry
        entry "process environment"))
     (agent-scheme--proper-list-elements
      environment "process environment"))))

(defun agent-scheme--process-environment-names (environment)
  "Return variable names from normalized process ENVIRONMENT."
  (mapcar #'car environment))

(defun agent-scheme--process-scope-command (grant)
  "Return GRANT's process command scope, or nil."
  (when-let ((command (agent-scheme--capability-scope-value grant "command")))
    (agent-scheme--capability-string command "process grant command")))

(defun agent-scheme--process-scope-cwd (grant)
  "Return GRANT's working-directory scope, or nil."
  (when-let ((cwd (or (agent-scheme--capability-scope-value
                      grant "working-directory")
                     (agent-scheme--capability-scope-value grant "cwd"))))
    (file-name-as-directory
     (expand-file-name
      (agent-scheme--capability-string cwd "process grant working directory")))))

(defun agent-scheme--process-scope-arguments (grant)
  "Return GRANT's argument scope, or nil."
  (when-let ((clause (agent-scheme--capability-scope-clause grant "arguments")))
    (agent-scheme--file-capability-field-values-list (cdr clause))))

(defun agent-scheme--process-scope-environment-name (datum)
  "Return DATUM's process environment variable name."
  (if (and (consp datum) (not (agent-scheme-symbol-p datum)))
      (agent-scheme--process-environment-name
       (car datum) "process grant environment")
    (agent-scheme--process-environment-name
     datum "process grant environment")))

(defun agent-scheme--process-scope-environment (grant)
  "Return GRANT's allowed process environment names, or nil."
  (when-let ((clause (agent-scheme--capability-scope-clause grant "environment")))
    (mapcar
     #'agent-scheme--process-scope-environment-name
     (agent-scheme--file-capability-field-values-list (cdr clause)))))

(defun agent-scheme--process-scope-handle (grant)
  "Return GRANT's process handle scope, or nil."
  (or (agent-scheme--capability-scope-value grant "handle")
      (agent-scheme--capability-scope-value grant "process")))

(defun agent-scheme--process-resource-handle (resource)
  "Return process handle from RESOURCE plist, or nil."
  (plist-get resource :handle))

(defun agent-scheme--process-resource-command (resource)
  "Return process command from RESOURCE plist, or nil."
  (plist-get resource :command))

(defun agent-scheme--process-resource-arguments (resource)
  "Return process arguments from RESOURCE plist, or nil."
  (plist-get resource :arguments))

(defun agent-scheme--process-resource-cwd (resource)
  "Return process cwd from RESOURCE plist, or nil."
  (plist-get resource :cwd))

(defun agent-scheme--process-resource-environment (resource)
  "Return process environment from RESOURCE plist, or nil."
  (plist-get resource :environment))

(defun agent-scheme--process-capability-grant-match
    (grant operation resource)
  "Return a match plist when GRANT authorizes process OPERATION."
  (cond
   ((not (agent-scheme--process-capability-operation-p grant operation))
    nil)
   ((eq (agent-scheme--capability-grant-status grant) 'revoked)
    (list :denied grant :reason "revoked process capability grant"))
   ((not (agent-scheme--capability-grant-active-p grant))
    (list :denied grant :reason "expired process capability grant"))
   (t
    (let ((scope-command (agent-scheme--process-scope-command grant))
          (scope-arguments (agent-scheme--process-scope-arguments grant))
          (scope-cwd (agent-scheme--process-scope-cwd grant))
          (scope-environment
           (agent-scheme--process-scope-environment grant))
          (scope-handle (agent-scheme--process-scope-handle grant))
          (command (agent-scheme--process-resource-command resource))
          (arguments (agent-scheme--process-resource-arguments resource))
          (cwd (agent-scheme--process-resource-cwd resource))
          (environment (agent-scheme--process-resource-environment resource))
          (handle (agent-scheme--process-resource-handle resource)))
      (cond
       ((and scope-command command (not (equal scope-command command)))
        (list :denied grant
              :reason "command is outside approved process grant scope"))
       ((and scope-arguments arguments
             (not (equal scope-arguments arguments)))
        (list :denied grant
              :reason "arguments are outside approved process grant scope"))
       ((and scope-cwd cwd (not (equal scope-cwd cwd)))
        (list :denied grant
              :reason "working directory is outside approved process grant scope"))
       ((and environment (not scope-environment))
        (list :denied grant
              :reason "environment is outside approved process grant scope"))
       ((and environment
             (cl-set-difference
              (agent-scheme--process-environment-names environment)
              scope-environment
              :test #'equal))
        (list :denied grant
              :reason "environment is outside approved process grant scope"))
       ((and scope-handle handle
             (not (agent-scheme--capability-same-handle-p
                   scope-handle handle)))
        (list :denied grant
              :reason "handle is outside approved process grant scope"))
       (t
        (list :grant grant)))))))

(defun agent-scheme--process-capability-request-datum
    (request-id binding operation resource)
  "Return a Scheme-readable process capability request datum."
  `(,(agent-scheme--capability-grant-symbol "capability-request")
    (,(agent-scheme--capability-grant-symbol "id") ,request-id)
    (,(agent-scheme--capability-grant-symbol "session")
     ,(or nil agent-scheme-false))
    (,(agent-scheme--capability-grant-symbol "library")
     (,(agent-scheme--capability-grant-symbol "emacs")
      ,(agent-scheme--capability-grant-symbol "process")))
    (,(agent-scheme--capability-grant-symbol "binding")
     ,(agent-scheme--capability-grant-symbol binding))
    (,(agent-scheme--capability-grant-symbol "domain")
     ,(agent-scheme--capability-grant-symbol "process"))
    (,(agent-scheme--capability-grant-symbol "operation")
     ,(agent-scheme--process-capability-operation-symbol operation))
    (,(agent-scheme--capability-grant-symbol "resource")
     ,@(when-let ((handle (agent-scheme--process-resource-handle resource)))
         `((,(agent-scheme--capability-grant-symbol "handle") ,handle)))
     ,@(when-let ((command (agent-scheme--process-resource-command resource)))
         `((,(agent-scheme--capability-grant-symbol "command") ,command)))
     ,@(when-let ((arguments
                   (agent-scheme--process-resource-arguments resource)))
         `((,(agent-scheme--capability-grant-symbol "arguments")
            ,arguments)))
     ,@(when-let ((cwd (agent-scheme--process-resource-cwd resource)))
         `((,(agent-scheme--capability-grant-symbol "cwd") ,cwd)))
     ,@(when-let ((environment
                   (agent-scheme--process-resource-environment resource)))
         `((,(agent-scheme--capability-grant-symbol "environment")
            ,environment)))
     ,@(when-let ((options (plist-get resource :options)))
         `((,(agent-scheme--capability-grant-symbol "options") ,options))))
    (,(agent-scheme--capability-grant-symbol "effect")
     ,(agent-scheme--process-capability-effect-symbol operation))))

(defun agent-scheme--process-capability-record-request
    (request operation resource)
  "Audit process capability REQUEST."
  (agent-scheme-audit-record
   'capability-request
   `((request . ,request)
     (domain . process)
     (operation . ,operation)
     (handle . ,(or (agent-scheme--process-resource-handle resource)
                    agent-scheme-false))
     (command . ,(or (agent-scheme--process-resource-command resource)
                     agent-scheme-false))
     (arguments . ,(or (agent-scheme--process-resource-arguments resource)
                       nil))
     (environment . ,(or (agent-scheme--process-resource-environment resource)
                         nil))
     (cwd . ,(or (agent-scheme--process-resource-cwd resource)
                 agent-scheme-false))
     (options . ,(or (plist-get resource :options) nil)))))

(defun agent-scheme--process-capability-record-decision
    (request request-id status grant reason &optional fields)
  "Audit and return a process capability decision datum."
  (let* ((decision-id (agent-scheme--process-capability-decision-id))
         (grant-id (or (and grant (agent-scheme--capability-grant-id grant))
                       (agent-scheme--capability-grant-symbol "none")))
         (decision
          `(,(agent-scheme--capability-grant-symbol "capability-decision")
            (,(agent-scheme--capability-grant-symbol "id") ,decision-id)
            (,(agent-scheme--capability-grant-symbol "request") ,request-id)
            (,(agent-scheme--capability-grant-symbol "status")
             ,(agent-scheme--capability-grant-symbol status))
            (,(agent-scheme--capability-grant-symbol "domain")
             ,(agent-scheme--capability-grant-symbol "process"))
            (,(agent-scheme--capability-grant-symbol "grant") ,grant-id)
            (,(agent-scheme--capability-grant-symbol "reason") ,reason))))
    (agent-scheme-audit-record
     'capability-decision
     (append
      `((request . ,request)
        (decision . ,decision)
        (domain . process)
        (status . ,status)
        (grant . ,grant-id)
        (reason . ,reason))
      fields))
    decision))

(defun agent-scheme-capability-audit-process-result
    (authorization result &optional errored)
  "Audit process capability AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (agent-scheme-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . process)
       (operation . ,operation)
       (result . ,(if errored
                      (list 'error result)
                    (list 'ok result)))))))

(defun agent-scheme--process-capability-deny
    (request request-id operation resource grant reason)
  "Record denied process REQUEST and signal REASON."
  (let ((decision
         (agent-scheme--process-capability-record-decision
          request request-id 'denied grant reason
          `((operation . ,operation)
            (handle . ,(or (agent-scheme--process-resource-handle resource)
                           agent-scheme-false))
            (command . ,(or (agent-scheme--process-resource-command resource)
                            agent-scheme-false))))))
    (agent-scheme-capability-audit-process-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (signal 'agent-scheme-capability-grant-error
            (list (format "process capability denied: %s" reason)))))

(defun agent-scheme--process-handle-live-p (handle)
  "Return non-nil when HANDLE names a live process registry entry."
  (and (agent-scheme-handle-p handle)
       (let ((entry (gethash (agent-scheme-handle-id handle)
                             agent-scheme--handle-registry)))
         (and entry
              (eq (agent-scheme--handle-entry-kind entry) 'process)
              (agent-scheme-capability--entry-live-p entry)))))

(defun agent-scheme--process-handle-object (handle)
  "Return the private object for process HANDLE, or nil."
  (when (agent-scheme-handle-p handle)
    (when-let ((entry (gethash (agent-scheme-handle-id handle)
                               agent-scheme--handle-registry)))
      (and (eq (agent-scheme--handle-entry-kind entry) 'process)
           (agent-scheme--handle-entry-object entry)))))

(defun agent-scheme--process-object-process (object)
  "Return live Emacs process inside OBJECT, or nil."
  (cond
   ((processp object) object)
   ((and (consp object) (plist-get object :process))
    (plist-get object :process))
   (t nil)))

(defun agent-scheme--process-object-live-p (object)
  "Return non-nil when process OBJECT is still live."
  (cond
   ((processp object)
    (process-live-p object))
   ((agent-scheme--process-object-process object)
    (process-live-p (agent-scheme--process-object-process object)))
   ((and (consp object) (plist-member object :status))
    (not (memq (plist-get object :status)
               '(closed deleted exit failed killed signal stale stopped))))
   (t object)))

(defun agent-scheme--process-object-status (object)
  "Return Scheme-readable status symbol for process OBJECT."
  (cond
   ((agent-scheme--process-object-process object)
    (process-status (agent-scheme--process-object-process object)))
   ((and (consp object) (plist-get object :status))
    (plist-get object :status))
   (t 'run)))

(defun agent-scheme--process-object-name (object)
  "Return process OBJECT's public name."
  (cond
   ((processp object) (process-name object))
   ((and (consp object) (plist-get object :name))
    (plist-get object :name))
   ((agent-scheme--process-object-process object)
    (process-name (agent-scheme--process-object-process object)))
   (t "process")))

(defun agent-scheme--process-object-command (object)
  "Return process OBJECT's command string, or nil."
  (cond
   ((and (consp object) (plist-get object :command))
    (plist-get object :command))
   ((agent-scheme--process-object-process object)
    (car (process-command (agent-scheme--process-object-process object))))
   (t nil)))

(defun agent-scheme--process-object-arguments (object)
  "Return process OBJECT's command arguments, or nil."
  (cond
   ((and (consp object) (plist-get object :arguments))
    (plist-get object :arguments))
   ((agent-scheme--process-object-process object)
    (cdr (process-command (agent-scheme--process-object-process object))))
   (t nil)))

(defun agent-scheme--process-object-buffer (object)
  "Return process OBJECT's live buffer, or nil."
  (let ((buffer
         (cond
          ((and (consp object) (plist-get object :buffer))
           (plist-get object :buffer))
          ((agent-scheme--process-object-process object)
           (process-buffer (agent-scheme--process-object-process object)))
          (t nil))))
    (and (buffer-live-p buffer) buffer)))

(defun agent-scheme--process-object-output (object stream)
  "Return text for process OBJECT STREAM."
  (cond
   ((and (eq stream 'stdout)
         (consp object)
         (plist-member object :stdout))
    (or (plist-get object :stdout) ""))
   ((and (eq stream 'stderr)
         (consp object)
         (plist-member object :stderr))
    (or (plist-get object :stderr) ""))
   ((and (eq stream 'stdout)
         (agent-scheme--process-object-buffer object))
    (with-current-buffer (agent-scheme--process-object-buffer object)
      (buffer-substring-no-properties (point-min) (point-max))))
   (t "")))

(defun agent-scheme--process-job-object
    (raw name command arguments options)
  "Return a normalized private process object for RAW start result."
  (cond
   ((processp raw)
    (list :name name
          :command command
          :arguments arguments
          :options options
          :status (process-status raw)
          :process raw
          :buffer (process-buffer raw)
          :stdout ""
          :stderr ""))
   ((consp raw)
    (append
     (list :name (or (plist-get raw :name) name)
           :command (or (plist-get raw :command) command)
           :arguments (or (plist-get raw :arguments) arguments)
           :options (or (plist-get raw :options) options)
           :status (or (plist-get raw :status) 'run))
     raw))
   (t
    (agent-scheme--eval-error
     "process-start! adapter returned unsupported process object"))))

(defun agent-scheme--process-handle-datum (handle object grant-id status)
  "Return a Scheme-readable process HANDLE datum."
  `(,(agent-scheme--capability-grant-symbol "handle")
    (,(agent-scheme--capability-grant-symbol "id")
     ,(agent-scheme-handle-id handle))
    (,(agent-scheme--capability-grant-symbol "kind")
     ,(agent-scheme--capability-grant-symbol "process-job"))
    (,(agent-scheme--capability-grant-symbol "domain")
     ,(agent-scheme--capability-grant-symbol "process"))
    (,(agent-scheme--capability-grant-symbol "command")
     ,(or (agent-scheme--process-object-command object) agent-scheme-false))
    (,(agent-scheme--capability-grant-symbol "arguments")
     ,(or (agent-scheme--process-object-arguments object) nil))
    (,(agent-scheme--capability-grant-symbol "grant") ,grant-id)
    (,(agent-scheme--capability-grant-symbol "status")
     ,(agent-scheme--capability-grant-symbol status))))

(defun agent-scheme--process-register-handle (object grant)
  "Register and audit a process OBJECT handle."
  (let* ((grant-id (agent-scheme--capability-grant-id grant))
         (handle (agent-scheme--register-handle 'process object))
         (handle-datum
          (agent-scheme--process-handle-datum handle object grant-id 'live)))
    (agent-scheme-audit-record
     'capability-handle
     `((handle . ,handle-datum)
       (domain . process)
       (kind . process-job)
       (command . ,(or (agent-scheme--process-object-command object)
                       agent-scheme-false))
       (arguments . ,(or (agent-scheme--process-object-arguments object)
                         nil))
       (grant . ,grant-id)
       (status . live)))
    handle))

(defun agent-scheme-capability-authorize-process
    (binding operation context resource)
  "Authorize process OPERATION for BINDING with RESOURCE."
  (let* ((request-id (agent-scheme--process-capability-request-id))
         (request
          (agent-scheme--process-capability-request-datum
           request-id binding operation resource))
         (command (agent-scheme--process-resource-command resource))
         (handle (agent-scheme--process-resource-handle resource))
         (grants (agent-scheme--process-capability-grants context))
         match
         denied)
    (agent-scheme--process-capability-record-request
     request operation resource)
    (when (and command
               (equal (agent-scheme--capability-grant-symbol-name operation)
                      "spawn")
               (not (agent-scheme--process-command-allowlist-entry command)))
      (agent-scheme--process-capability-deny
       request request-id operation resource nil
       "command is not in process allow-list"))
    (when (and handle (not (agent-scheme--process-handle-live-p handle)))
      (agent-scheme--process-capability-deny
       request request-id operation resource nil
       "stale process handle"))
    (unless grants
      (agent-scheme--process-capability-deny
       request request-id operation resource nil
       "no active process grant covers request"))
    (dolist (grant grants)
      (let ((candidate
             (agent-scheme--process-capability-grant-match
              grant operation resource)))
        (when candidate
          (if (plist-get candidate :grant)
              (setq match candidate)
            (setq denied candidate)))))
    (unless match
      (agent-scheme--process-capability-deny
       request request-id operation resource
       (plist-get denied :denied)
       (or (plist-get denied :reason)
           "no active process grant covers request")))
    (let ((grant (plist-get match :grant)))
      (condition-case condition
          (progn
            (agent-scheme-policy-authorize
             (agent-scheme--process-capability-policy-category operation)
             binding
             `((domain . process)
               (operation . ,operation)
               (handle . ,(or handle agent-scheme-false))
               (command . ,(or command agent-scheme-false))
               (arguments . ,(or (agent-scheme--process-resource-arguments
                                  resource)
                                 nil))
               (environment . ,(or (agent-scheme--process-resource-environment
                                    resource)
                                   nil))
               (cwd . ,(or (agent-scheme--process-resource-cwd resource)
                           agent-scheme-false))
               (grant . ,(agent-scheme--capability-grant-id grant)))
             context)
            (agent-scheme--capability-grant-use! grant context)
            (list :operation operation
                  :request request
                  :decision
                  (agent-scheme--process-capability-record-decision
                   request request-id 'approved grant
                   "process request is covered by active grant")
                  :grant grant))
        (agent-scheme-policy-error
         (let ((decision
                (agent-scheme--process-capability-record-decision
                 request request-id 'denied grant
                 (error-message-string condition))))
           (agent-scheme-capability-audit-process-result
            (list :request request
                  :decision decision
                  :operation operation)
            (error-message-string condition)
            t)
           (signal (car condition) (cdr condition))))))))

(defun agent-scheme-capability-register-process-port
    (port kind authorization process-handle stream operations)
  "Attach a process-backed port capability handle to PORT."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (agent-scheme--capability-grant-id grant))
         (handle-id (agent-scheme--process-port-capability-handle-id))
         (limits (agent-scheme--port-capability-limits grant))
         (path (agent-scheme-handle-id process-handle))
         (handle
          (agent-scheme--port-capability-datum
           handle-id kind 'process operations grant-id limits 'open path)))
    (setf (agent-scheme--port-backing-domain port) 'process)
    (setf (agent-scheme--port-operations port) operations)
    (setf (agent-scheme--port-grant port) grant-id)
    (setf (agent-scheme--port-limits port) limits)
    (setf (agent-scheme--port-handle port) handle-id)
    (setf (agent-scheme--port-status port) 'open)
    (setf (agent-scheme--port-path port) path)
    (setf (agent-scheme--port-counters port) nil)
    (agent-scheme-audit-record
     'capability-handle
     `((handle . ,handle)
       (domain . port)
       (kind . ,kind)
       (backing . process)
       (process . ,process-handle)
       (stream . ,stream)
       (operations . ,operations)
       (grant . ,grant-id)
       (limits . ,limits)
       (status . open)))
    port))

(defun agent-scheme--network-capability-grant-domain-p (grant)
  "Return non-nil when GRANT is a network-domain grant."
  (equal (agent-scheme--capability-grant-symbol-name
          (agent-scheme--capability-grant-field-value grant "domain"))
         "network"))

(defun agent-scheme--network-capability-operation-p (grant operation)
  "Return non-nil when GRANT allows network OPERATION."
  (let ((operation-name
         (agent-scheme--capability-grant-symbol-name operation)))
    (cl-some
     (lambda (candidate)
       (equal (agent-scheme--capability-grant-symbol-name candidate)
              operation-name))
     (agent-scheme--file-capability-field-values-list
      (agent-scheme--capability-grant-field-values grant "operations")))))

(defun agent-scheme--network-capability-grants (context)
  "Return network-domain grants carried by CONTEXT."
  (seq-filter
   #'agent-scheme--network-capability-grant-domain-p
   (agent-scheme--capability-context-grants context)))

(defun agent-scheme--network-name (value description)
  "Return VALUE as a network scope string for DESCRIPTION."
  (or (agent-scheme--capability-grant-symbol-name value)
      (agent-scheme--capability-string value description)))

(defun agent-scheme--network-scope-values (grant name description)
  "Return GRANT scope NAME values normalized as strings."
  (mapcar
   (lambda (value)
     (agent-scheme--network-name value description))
   (agent-scheme--file-capability-field-values-list
    (cdr (agent-scheme--capability-scope-clause grant name)))))

(defun agent-scheme--network-scope-integers (grant name description)
  "Return GRANT scope NAME values normalized as integers."
  (mapcar
   (lambda (value)
     (agent-scheme--capability-exact-integer value description))
   (agent-scheme--file-capability-field-values-list
    (cdr (agent-scheme--capability-scope-clause grant name)))))

(defun agent-scheme--network-scope-integer (grant name description)
  "Return GRANT scope NAME as one integer, or nil."
  (when-let ((value (agent-scheme--capability-scope-value grant name)))
    (agent-scheme--capability-exact-integer value description)))

(defun agent-scheme--network-member-string-p (value allowed)
  "Return non-nil when VALUE is allowed by ALLOWED strings."
  (or (null allowed)
      (member "all" allowed)
      (member value allowed)))

(defun agent-scheme--network-member-integer-p (value allowed)
  "Return non-nil when VALUE is allowed by ALLOWED integers."
  (or (null allowed)
      (member value allowed)))

(defun agent-scheme--network-subset-p (values allowed)
  "Return non-nil when every value in VALUES is included in ALLOWED."
  (or (null values)
      (null allowed)
      (member "all" allowed)
      (cl-every
       (lambda (value)
         (member value allowed))
       values)))

(defun agent-scheme--network-option-field (options name)
  "Return network OPTIONS field named NAME, or nil."
  (seq-find
   (lambda (field)
     (agent-scheme--capability-grant-field-named-p field name))
   (agent-scheme--proper-list-elements options "network options")))

(defun agent-scheme--network-option-value (options name)
  "Return network OPTIONS field NAME's first value, or nil."
  (cadr (agent-scheme--network-option-field options name)))

(defun agent-scheme--network-option-integer (options name description)
  "Return network OPTIONS integer field NAME, or nil."
  (when-let ((value (agent-scheme--network-option-value options name)))
    (agent-scheme--capability-exact-integer value description)))

(defun agent-scheme--network-option-boolean-p (options name)
  "Return non-nil when network OPTIONS field NAME is true."
  (let ((value (agent-scheme--network-option-value options name)))
    (and value (not (eq value agent-scheme-false)))))

(defun agent-scheme--network-header-entry (entry)
  "Return ENTRY as a two-string network header."
  (let ((elements (agent-scheme--proper-list-elements entry "network header")))
    (unless (= (length elements) 2)
      (agent-scheme--eval-error
       "network header entries must have exactly two fields"))
    (list (agent-scheme--capability-string
           (car elements)
           "network header name")
          (agent-scheme--capability-string
           (cadr elements)
           "network header value"))))

(defun agent-scheme--network-normalized-headers (headers)
  "Return HEADERS as a list of string pairs."
  (mapcar
   #'agent-scheme--network-header-entry
   (agent-scheme--proper-list-elements headers "network headers")))

(defun agent-scheme--network-header-class (header)
  "Return HEADER's disclosure class."
  (let ((name (downcase (car header))))
    (if (string-match-p
         "\\(authorization\\|cookie\\|token\\|api[-_]?key\\|secret\\|credential\\)"
         name)
        "credential"
      "metadata")))

(defun agent-scheme--network-header-classes (headers)
  "Return unique disclosure classes for HEADERS."
  (let (classes)
    (dolist (header headers (nreverse classes))
      (let ((class (agent-scheme--network-header-class header)))
        (unless (member class classes)
          (push class classes))))))

(defun agent-scheme--network-payload-class (payload options)
  "Return PAYLOAD disclosure class from PAYLOAD and OPTIONS."
  (cond
   ((and (not (or (null payload) (eq payload agent-scheme-false)))
         (agent-scheme-redaction-local-only-p payload))
    "local-only")
   ((and (not (or (null payload) (eq payload agent-scheme-false)))
         (agent-scheme-secret-source-p payload))
    "redacted")
   ((agent-scheme--network-option-value options "payload-class")
    (agent-scheme--network-name
     (agent-scheme--network-option-value options "payload-class")
     "network payload-class"))
   ((or (null payload) (eq payload agent-scheme-false))
    "none")
   (t "public")))

(defun agent-scheme--network-method-name (method)
  "Return METHOD as an uppercase string."
  (upcase (agent-scheme--network-name method "network method")))

(defun agent-scheme--network-url-parts (url)
  "Return parsed network URL parts as a plist."
  (let* ((parsed (url-generic-parse-url url))
         (scheme (url-type parsed))
         (host (url-host parsed))
         (port (or (url-port parsed)
                   (pcase scheme
                     ("https" 443)
                     ("http" 80)
                     (_ nil)))))
    (unless (and scheme host port)
      (agent-scheme--eval-error "network URL must include scheme and host"))
    (list :scheme scheme :host host :port port)))

(defun agent-scheme--network-resource-field (name value)
  "Return a Scheme-readable network resource field."
  (list (agent-scheme--capability-grant-symbol name) value))

(defun agent-scheme--network-redacted-resource (resource)
  "Return RESOURCE as redacted Scheme-readable fields."
  (let ((payload (plist-get resource :payload))
        (headers (plist-get resource :headers)))
    (list
     (agent-scheme--network-resource-field "url" (plist-get resource :url))
     (agent-scheme--network-resource-field
      "scheme" (plist-get resource :scheme))
     (agent-scheme--network-resource-field "host" (plist-get resource :host))
     (agent-scheme--network-resource-field "port"
                                           (agent-scheme--scheme-integer
                                            (plist-get resource :port)))
     (agent-scheme--network-resource-field "method"
                                           (agent-scheme--capability-grant-symbol
                                            (plist-get resource :method)))
     (agent-scheme--network-resource-field
      "headers" (agent-scheme--network-redacted-headers headers))
     (agent-scheme--network-resource-field
      "header-classes"
      (mapcar #'agent-scheme--capability-grant-symbol
              (plist-get resource :header-classes)))
     (agent-scheme--network-resource-field
      "payload" (agent-scheme-redact payload 'network))
     (agent-scheme--network-resource-field
      "payload-class"
      (agent-scheme--capability-grant-symbol
       (plist-get resource :payload-class)))
     (agent-scheme--network-resource-field
      "response-size"
      (agent-scheme--scheme-integer
       (or (plist-get resource :response-size) 0)))
     (agent-scheme--network-resource-field
      "redirects"
      (agent-scheme--scheme-integer (or (plist-get resource :redirects) 0)))
     (agent-scheme--network-resource-field
      "timeout-ms"
      (if-let ((timeout (plist-get resource :timeout-ms)))
          (agent-scheme--scheme-integer timeout)
        agent-scheme-false))
     (agent-scheme--network-resource-field
      "stream-lifetime-ms"
      (if-let ((lifetime (plist-get resource :stream-lifetime-ms)))
          (agent-scheme--scheme-integer lifetime)
        agent-scheme-false)))))

(defun agent-scheme--network-redacted-headers (headers)
  "Return HEADERS with credential-bearing values redacted."
  (mapcar
   (lambda (header)
     (list (car header)
           (if (equal (agent-scheme--network-header-class header)
                      "credential")
               agent-scheme-redaction-replacement
             (agent-scheme-redact (cadr header) 'network))))
   headers))

(defun agent-scheme--network-resource
    (method url headers payload options &optional stream)
  "Return normalized network resource for METHOD URL HEADERS PAYLOAD OPTIONS."
  (let* ((url-text (agent-scheme--capability-string url "network URL"))
         (parts (agent-scheme--network-url-parts url-text))
         (normalized-headers
          (agent-scheme--network-normalized-headers headers))
         (payload-class
          (agent-scheme--network-payload-class payload options)))
    (list :url url-text
          :scheme (plist-get parts :scheme)
          :host (plist-get parts :host)
          :port (plist-get parts :port)
          :method (agent-scheme--network-method-name method)
          :headers normalized-headers
          :header-classes
          (agent-scheme--network-header-classes normalized-headers)
          :payload payload
          :payload-class payload-class
          :response-size
          (agent-scheme--network-option-integer
           options "response-size" "network response-size")
          :redirects
          (or (agent-scheme--network-option-integer
               options "redirects" "network redirects")
              0)
          :timeout-ms
          (agent-scheme--network-option-integer
           options "timeout-ms" "network timeout-ms")
          :stream-lifetime-ms
          (and stream
               (agent-scheme--network-option-integer
                options
                "stream-lifetime-ms"
                "network stream-lifetime-ms"))
          :allow-local-only
          (agent-scheme--network-option-boolean-p options "allow-local-only"))))

(defun agent-scheme--network-capability-effect-symbol (operation)
  "Return the effect class for a network operation."
  (agent-scheme--capability-grant-symbol
   (if (equal (agent-scheme--capability-grant-symbol-name operation) "stream")
       "network-stream"
     "network-egress")))

(defun agent-scheme--network-capability-request-datum
    (request-id library binding operation resource)
  "Return a Scheme-readable network capability request datum."
  `(,(agent-scheme--capability-grant-symbol "capability-request")
    (,(agent-scheme--capability-grant-symbol "id") ,request-id)
    (,(agent-scheme--capability-grant-symbol "session")
     ,agent-scheme-false)
    (,(agent-scheme--capability-grant-symbol "library") ,library)
    (,(agent-scheme--capability-grant-symbol "binding") ,binding)
    (,(agent-scheme--capability-grant-symbol "domain")
     ,(agent-scheme--capability-grant-symbol "network"))
    (,(agent-scheme--capability-grant-symbol "operation")
     ,(agent-scheme--capability-grant-symbol operation))
    (,(agent-scheme--capability-grant-symbol "resource")
     ,@(agent-scheme--network-redacted-resource resource))
    (,(agent-scheme--capability-grant-symbol "effect")
     ,(agent-scheme--network-capability-effect-symbol operation))))

(defun agent-scheme--network-capability-record-request
    (request operation resource)
  "Audit network capability REQUEST."
  (agent-scheme-audit-record
   'capability-request
   `((request . ,request)
     (domain . network)
     (operation . ,operation)
     (scheme . ,(plist-get resource :scheme))
     (host . ,(plist-get resource :host))
     (port . ,(plist-get resource :port))
     (method . ,(plist-get resource :method))
     (header-classes . ,(plist-get resource :header-classes))
     (payload-class . ,(plist-get resource :payload-class))
     (response-size . ,(or (plist-get resource :response-size) 0))
     (redirects . ,(or (plist-get resource :redirects) 0)))))

(defun agent-scheme--network-capability-record-decision
    (request request-id status grant reason &optional fields)
  "Audit and return a network capability decision datum."
  (let* ((decision-id (agent-scheme--network-capability-decision-id))
         (grant-id (or (and grant (agent-scheme--capability-grant-id grant))
                       (agent-scheme--capability-grant-symbol "none")))
         (decision
          `(,(agent-scheme--capability-grant-symbol "capability-decision")
            (,(agent-scheme--capability-grant-symbol "id") ,decision-id)
            (,(agent-scheme--capability-grant-symbol "request") ,request-id)
            (,(agent-scheme--capability-grant-symbol "status")
             ,(agent-scheme--capability-grant-symbol status))
            (,(agent-scheme--capability-grant-symbol "domain")
             ,(agent-scheme--capability-grant-symbol "network"))
            (,(agent-scheme--capability-grant-symbol "grant") ,grant-id)
            (,(agent-scheme--capability-grant-symbol "reason") ,reason))))
    (agent-scheme-audit-record
     'capability-decision
     (append
      `((request . ,request)
        (decision . ,decision)
        (domain . network)
        (status . ,status)
        (grant . ,grant-id)
        (reason . ,reason))
      fields))
    decision))

(defun agent-scheme-capability-audit-network-result
    (authorization result &optional errored)
  "Audit network capability AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (agent-scheme-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . network)
       (operation . ,operation)
       (result . ,(if errored
                      (list 'error (agent-scheme-redact result 'network))
                    (list 'ok (agent-scheme-redact result 'network))))))))

(defun agent-scheme--network-capability-deny
    (request request-id operation resource grant reason)
  "Record denied network REQUEST and signal REASON."
  (let ((decision
         (agent-scheme--network-capability-record-decision
          request request-id 'denied grant reason
          `((operation . ,operation)
            (host . ,(plist-get resource :host))
            (method . ,(plist-get resource :method))))))
    (agent-scheme-capability-audit-network-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (signal 'agent-scheme-capability-grant-error
            (list (format "network capability denied: %s" reason)))))

(defun agent-scheme--network-capability-grant-match
    (grant operation resource)
  "Return a match plist when GRANT authorizes network OPERATION."
  (let ((schemes (agent-scheme--network-scope-values
                  grant "schemes" "network grant scheme"))
        (hosts (agent-scheme--network-scope-values
                grant "hosts" "network grant host"))
        (ports (agent-scheme--network-scope-integers
                grant "ports" "network grant port"))
        (methods (mapcar #'upcase
                         (agent-scheme--network-scope-values
                          grant "methods" "network grant method")))
        (header-classes (agent-scheme--network-scope-values
                         grant
                         "header-classes"
                         "network grant header-class"))
        (payload-classes (agent-scheme--network-scope-values
                          grant
                          "payload-classes"
                          "network grant payload-class"))
        (max-response-bytes
         (agent-scheme--network-scope-integer
          grant "max-response-bytes" "network grant max-response-bytes"))
        (max-redirects
         (agent-scheme--network-scope-integer
          grant "max-redirects" "network grant max-redirects"))
        (max-timeout-ms
         (agent-scheme--network-scope-integer
          grant "max-timeout-ms" "network grant max-timeout-ms"))
        (max-stream-lifetime-ms
         (agent-scheme--network-scope-integer
          grant "stream-lifetime-ms" "network grant stream-lifetime-ms")))
    (cond
     ((not (agent-scheme--network-capability-operation-p grant operation))
      nil)
     ((eq (agent-scheme--capability-grant-status grant) 'revoked)
      (list :denied grant :reason "revoked network capability grant"))
     ((not (agent-scheme--capability-grant-active-p grant))
      (list :denied grant :reason "expired network capability grant"))
     ((not (agent-scheme--network-member-string-p
            (plist-get resource :scheme) schemes))
      (list :denied grant
            :reason "scheme is outside approved network grant scope"))
     ((not (agent-scheme--network-member-string-p
            (plist-get resource :host) hosts))
      (list :denied grant
            :reason "host is outside approved network grant scope"))
     ((not (agent-scheme--network-member-integer-p
            (plist-get resource :port) ports))
      (list :denied grant
            :reason "port is outside approved network grant scope"))
     ((not (agent-scheme--network-member-string-p
            (plist-get resource :method) methods))
      (list :denied grant
            :reason "method is outside approved network grant scope"))
     ((not (agent-scheme--network-subset-p
            (plist-get resource :header-classes) header-classes))
      (list :denied grant
            :reason "header class is outside approved network grant scope"))
     ((not (agent-scheme--network-member-string-p
            (plist-get resource :payload-class) payload-classes))
      (list :denied grant
            :reason "payload class is outside approved network grant scope"))
     ((and max-response-bytes
           (plist-get resource :response-size)
           (> (plist-get resource :response-size) max-response-bytes))
      (list :denied grant
            :reason "response size is outside approved network grant scope"))
     ((and max-redirects
           (> (or (plist-get resource :redirects) 0) max-redirects))
      (list :denied grant
            :reason "redirect count is outside approved network grant scope"))
     ((and max-timeout-ms
           (plist-get resource :timeout-ms)
           (> (plist-get resource :timeout-ms) max-timeout-ms))
      (list :denied grant
            :reason "timeout is outside approved network grant scope"))
     ((and max-stream-lifetime-ms
           (plist-get resource :stream-lifetime-ms)
           (> (plist-get resource :stream-lifetime-ms)
              max-stream-lifetime-ms))
      (list :denied grant
            :reason "stream lifetime is outside approved network grant scope"))
     (t
      (list :grant grant :max-response-bytes max-response-bytes)))))

(defun agent-scheme-capability-authorize-network
    (library binding context operation resource)
  "Authorize network OPERATION for BINDING with RESOURCE."
  (let* ((request-id (agent-scheme--network-capability-request-id))
         (library-datum (agent-scheme-read library))
         (binding-datum (agent-scheme--capability-grant-symbol binding))
         (request
          (agent-scheme--network-capability-request-datum
           request-id library-datum binding-datum operation resource))
         (grants (agent-scheme--network-capability-grants context))
         match
         denied)
    (agent-scheme--network-capability-record-request
     request operation resource)
    (when (and (equal (plist-get resource :payload-class) "local-only")
               (not (plist-get resource :allow-local-only)))
      (agent-scheme--network-capability-deny
       request request-id operation resource nil
       "local-only payload requires explicit network disclosure approval"))
    (unless grants
      (agent-scheme--network-capability-deny
       request request-id operation resource nil
       "no active network grant covers request"))
    (dolist (grant grants)
      (let ((candidate
             (agent-scheme--network-capability-grant-match
              grant operation resource)))
        (when candidate
          (if (plist-get candidate :grant)
              (setq match candidate)
            (setq denied candidate)))))
    (unless match
      (agent-scheme--network-capability-deny
       request request-id operation resource
       (plist-get denied :denied)
       (or (plist-get denied :reason)
           "no active network grant covers request")))
    (let ((grant (plist-get match :grant)))
      (condition-case condition
          (progn
            (agent-scheme-policy-authorize
             'network-access
             binding
             `((domain . network)
               (operation . ,operation)
               (scheme . ,(plist-get resource :scheme))
               (host . ,(plist-get resource :host))
               (port . ,(plist-get resource :port))
               (method . ,(plist-get resource :method))
               (header-classes . ,(plist-get resource :header-classes))
               (payload-class . ,(plist-get resource :payload-class))
               (grant . ,(agent-scheme--capability-grant-id grant)))
             context)
            (agent-scheme--capability-grant-use! grant context)
            (list :operation operation
                  :request request
                  :decision
                  (agent-scheme--network-capability-record-decision
                   request request-id 'approved grant
                   "network request is covered by active grant")
                  :grant grant
                  :max-response-bytes
                  (plist-get match :max-response-bytes)
                  :transport-resource
                  (agent-scheme--network-redacted-resource resource)))
        (agent-scheme-policy-error
         (let ((decision
                (agent-scheme--network-capability-record-decision
                 request request-id 'denied grant
                 (error-message-string condition))))
           (agent-scheme-capability-audit-network-result
            (list :request request
                  :decision decision
                  :operation operation)
            (error-message-string condition)
            t)
           (signal (car condition) (cdr condition))))))))

(defun agent-scheme--network-response-body-size (response)
  "Return RESPONSE body size in characters when visible, or 0."
  (let ((body
         (and (consp response)
              (cadr (seq-find
                     (lambda (field)
                       (agent-scheme--capability-grant-field-named-p
                        field "body"))
                     (cdr response))))))
    (cond
     ((stringp body) (length body))
     ((null body) 0)
     (t (length (agent-scheme-value->external body))))))

(defun agent-scheme--network-check-response-limit! (authorization response)
  "Fail if RESPONSE exceeds AUTHORIZATION's response limit."
  (when-let ((limit (plist-get authorization :max-response-bytes)))
    (let ((size (agent-scheme--network-response-body-size response)))
      (when (> size limit)
        (let ((reason "network response size exceeds grant limit"))
          (agent-scheme-capability-audit-network-result
           authorization reason t)
          (signal 'agent-scheme-capability-grant-error (list reason)))))))

(defun agent-scheme--network-normalize-response-datum (datum)
  "Return DATUM using Agent Scheme symbols for host adapter symbols."
  (cond
   ((agent-scheme-symbol-p datum)
    datum)
   ((symbolp datum)
    (agent-scheme--capability-grant-symbol datum))
   ((consp datum)
    (mapcar #'agent-scheme--network-normalize-response-datum datum))
   ((vectorp datum)
    (vconcat
     (mapcar #'agent-scheme--network-normalize-response-datum
             (append datum nil))))
   (t datum)))

(defun agent-scheme--network-stream-handle-datum
    (handle request url grant-id status)
  "Return a Scheme-readable network stream HANDLE datum."
  `(,(agent-scheme--capability-grant-symbol "handle")
    (,(agent-scheme--capability-grant-symbol "id")
     ,(agent-scheme-handle-id handle))
    (,(agent-scheme--capability-grant-symbol "kind")
     ,(agent-scheme--capability-grant-symbol "network-stream"))
    (,(agent-scheme--capability-grant-symbol "domain")
     ,(agent-scheme--capability-grant-symbol "network"))
    (,(agent-scheme--capability-grant-symbol "request") ,request)
    (,(agent-scheme--capability-grant-symbol "url") ,url)
    (,(agent-scheme--capability-grant-symbol "grant") ,grant-id)
    (,(agent-scheme--capability-grant-symbol "status")
     ,(agent-scheme--capability-grant-symbol status))))

(defun agent-scheme--network-register-stream-handle
    (url source authorization)
  "Register and audit a network stream handle."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (agent-scheme--capability-grant-id grant))
         (id (agent-scheme--network-stream-handle-id))
         (handle (agent-scheme--make-handle 'network-stream id))
         (object (list :url url
                       :source source
                       :grant grant-id
                       :status 'live)))
    (puthash id
             (agent-scheme--make-handle-entry 'network-stream object)
             agent-scheme--handle-registry)
    (agent-scheme-audit-record
     'capability-handle
     `((handle . ,(agent-scheme--network-stream-handle-datum
                   handle
                   (plist-get authorization :request)
                   url
                   grant-id
                   'live))
       (domain . network)
       (kind . network-stream)
       (url . ,url)
       (grant . ,grant-id)
       (status . live)))
    handle))

(defun agent-scheme--network-stream-object-live-p (object)
  "Return non-nil when network stream OBJECT is live."
  (not (memq (plist-get object :status)
             '(closed cancelled stale expired revoked))))

(defun agent-scheme--network-stream-live-p (id)
  "Return non-nil when ID names a live network stream."
  (and (stringp id)
       (let ((entry (gethash id agent-scheme--handle-registry)))
         (and entry
              (eq (agent-scheme--handle-entry-kind entry) 'network-stream)
              (agent-scheme--network-stream-object-live-p
               (agent-scheme--handle-entry-object entry))))))

(defun agent-scheme-capability-register-network-port
    (port kind authorization stream-handle operations)
  "Attach a network-backed port capability handle to PORT."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (agent-scheme--capability-grant-id grant))
         (handle-id (agent-scheme--network-port-capability-handle-id))
         (limits (agent-scheme--port-capability-limits grant))
         (path (agent-scheme-handle-id stream-handle))
         (handle
          (agent-scheme--port-capability-datum
           handle-id kind 'network operations grant-id limits 'open path)))
    (setf (agent-scheme--port-backing-domain port) 'network)
    (setf (agent-scheme--port-operations port) operations)
    (setf (agent-scheme--port-grant port) grant-id)
    (setf (agent-scheme--port-limits port) limits)
    (setf (agent-scheme--port-handle port) handle-id)
    (setf (agent-scheme--port-status port) 'open)
    (setf (agent-scheme--port-path port) path)
    (setf (agent-scheme--port-counters port) nil)
    (agent-scheme-audit-record
     'capability-handle
     `((handle . ,handle)
       (domain . port)
       (kind . ,kind)
       (backing . network)
       (stream . ,stream-handle)
       (operations . ,operations)
       (grant . ,grant-id)
       (limits . ,limits)
       (status . open)))
    port))

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
         (target-window-handle
          (agent-scheme--capability-operation-window-handle name arguments))
         (grant-window-handle
          (agent-scheme--capability-scope-value grant "window"))
         (operation-region
          (agent-scheme--capability-operation-region name arguments))
         (grant-range
          (agent-scheme--capability-range-values grant))
         (operation-direction
          (agent-scheme--capability-operation-direction name arguments))
         (grant-direction
          (agent-scheme--capability-scope-value grant "direction"))
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
    (agent-scheme--capability-check-grant-handle-live grant grant-window-handle)
    (and
     (or (null grant-handle)
         (agent-scheme--capability-same-handle-p grant-handle target-handle))
     (or (null grant-window-handle)
         (agent-scheme--capability-same-handle-p
          grant-window-handle target-window-handle))
     (or (null grant-range)
         (and operation-region
              (<= (car grant-range) (car operation-region))
              (<= (cadr operation-region) (cadr grant-range))))
     (or (null grant-direction)
         (and operation-direction
              (equal
               (agent-scheme--capability-grant-symbol-name grant-direction)
               operation-direction)))
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
  (cond
   ((agent-scheme--file-capability-grant-domain-p grant)
    (agent-scheme-policy-authorize
     'standard-host-effect
     "grant-capability!"
     `((domain . file)
       (operations . ,(agent-scheme--capability-grant-field-values
                       grant "operations"))
       (grant . ,grant))
     context
     'capability-grant))
   ((agent-scheme--process-capability-grant-domain-p grant)
    (agent-scheme-policy-authorize
     'command-process
     "grant-capability!"
     `((domain . process)
       (operations . ,(agent-scheme--capability-grant-field-values
                       grant "operations"))
       (grant . ,grant))
     context
     'capability-grant))
   ((agent-scheme--network-capability-grant-domain-p grant)
    (agent-scheme-policy-authorize
     'network-access
     "grant-capability!"
     `((domain . network)
       (operations . ,(agent-scheme--capability-grant-field-values
                       grant "operations"))
       (grant . ,grant))
     context
     'capability-grant))
   (t
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
       'capability-grant)))))

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
      (unless (or (plist-get spec :requires-process-grant)
                  (plist-get spec :requires-network-grant))
        (agent-scheme-policy-authorize
         (agent-scheme--emacs-capability-policy-category spec)
         name
         `((library . ,(and spec (plist-get spec :library)))
           (capability . ,name)
           (arguments . ,arguments))
         context
         'capability-call))
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

(defun agent-scheme--search-symbol (name)
  "Return NAME as an Agent Scheme search datum symbol."
  (agent-scheme--syntax-symbol name))

(defun agent-scheme--search-field (name &rest values)
  "Return a Scheme-readable search field NAME with VALUES."
  (cons (agent-scheme--search-symbol name) values))

(defun agent-scheme--search-option-name (datum description)
  "Return DATUM as a search option name string for DESCRIPTION."
  (cond
   ((agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum))
   ((stringp datum)
    datum)
   (t
    (agent-scheme--eval-error
     "%s option name must be a symbol or string, got %s"
     description
     (agent-scheme-value->external datum)))))

(defun agent-scheme--search-options (datum description)
  "Return DATUM as an alist of search option names to values."
  (let (options)
    (dolist (entry (agent-scheme--proper-list-elements datum description)
                   (nreverse options))
      (let ((elements (agent-scheme--proper-list-elements entry description)))
        (unless (= (length elements) 2)
          (agent-scheme--eval-error
           "%s option entries must have exactly two fields" description))
        (push (cons (agent-scheme--search-option-name
                     (car elements) description)
                    (cadr elements))
              options)))))

(defun agent-scheme--search-option (options name default)
  "Return option NAME from OPTIONS, or DEFAULT."
  (let ((entry (assoc name options)))
    (if entry (cdr entry) default)))

(defun agent-scheme--search-option-integer
    (options name default description)
  "Return non-negative integer search option NAME."
  (let ((value (agent-scheme--search-option options name default)))
    (unless (and (agent-scheme-number-p value)
                 (eq (agent-scheme-number-kind value) 'integer)
                 (eq (agent-scheme-number-exactness value) 'exact)
                 (>= (agent-scheme-number-value value) 0))
      (agent-scheme--eval-error
       "%s option %s expected a non-negative exact integer, got %s"
       description
       name
       (agent-scheme-value->external value)))
    (agent-scheme-number-value value)))

(defun agent-scheme--search-option-boolean
    (options name default description)
  "Return boolean search option NAME."
  (let ((value (agent-scheme--search-option options name default)))
    (cond
     ((eq value agent-scheme-true) t)
     ((eq value agent-scheme-false) nil)
     (t
      (agent-scheme--eval-error
       "%s option %s expected a boolean, got %s"
       description
       name
       (agent-scheme-value->external value))))))

(defun agent-scheme--search-limit (options description)
  "Return the result limit from OPTIONS for DESCRIPTION."
  (agent-scheme--search-option-integer
   options
   "limit"
   (agent-scheme--scheme-integer agent-scheme-search-default-limit)
   description))

(defun agent-scheme--search-preview-limit (options description)
  "Return the preview limit from OPTIONS for DESCRIPTION."
  (agent-scheme--search-option-integer
   options
   "max-preview"
   (agent-scheme--scheme-integer
    agent-scheme-search-default-preview-characters)
   description))

(defun agent-scheme--search-file-byte-limit (options description)
  "Return the file byte limit from OPTIONS for DESCRIPTION."
  (agent-scheme--search-option-integer
   options
   "max-file-bytes"
   (agent-scheme--scheme-integer
    agent-scheme-search-default-maximum-file-bytes)
   description))

(defun agent-scheme--search-file-limit (options description)
  "Return the project file count limit from OPTIONS for DESCRIPTION."
  (agent-scheme--search-option-integer
   options
   "file-limit"
   (agent-scheme--scheme-integer agent-scheme-search-default-file-limit)
   description))

(defun agent-scheme--search-case-fold-p (options description)
  "Return non-nil when OPTIONS request case-folded search."
  (agent-scheme--search-option-boolean
   options "case-fold" agent-scheme-false description))

(defun agent-scheme--search-include-generated-p (options description)
  "Return non-nil when OPTIONS request generated directories."
  (or (agent-scheme--search-option-boolean
       options "include-generated" agent-scheme-false description)
      (agent-scheme--search-option-boolean
       options "include-ignored" agent-scheme-false description)))

(defun agent-scheme--search-include-binary-p (options description)
  "Return non-nil when OPTIONS request binary files."
  (agent-scheme--search-option-boolean
   options "include-binary" agent-scheme-false description))

(defun agent-scheme--search-truncate-preview (preview limit)
  "Return PREVIEW truncated to LIMIT characters."
  (let ((clean (substring-no-properties preview)))
    (if (<= (length clean) limit)
        clean
      (concat (substring clean 0 limit) "..."))))

(defun agent-scheme--search-relative-file (file root)
  "Return FILE relative to ROOT, or #f when either is nil."
  (if (and file root)
      (file-relative-name (expand-file-name file)
                          (file-name-as-directory (expand-file-name root)))
    agent-scheme-false))

(defun agent-scheme--search-result-datum
    (source buffer file root line column start end preview)
  "Return a Scheme-readable search result datum."
  (list
   (agent-scheme--search-symbol "search-result")
   (agent-scheme--search-field
    "source" (agent-scheme--search-symbol (symbol-name source)))
   (agent-scheme--search-field
    "buffer" (if buffer (buffer-name buffer) agent-scheme-false))
   (agent-scheme--search-field
    "file" (if file (expand-file-name file) agent-scheme-false))
   (agent-scheme--search-field
    "relative-file" (agent-scheme--search-relative-file file root))
   (agent-scheme--search-field "line" (agent-scheme--scheme-integer line))
   (agent-scheme--search-field "column" (agent-scheme--scheme-integer column))
   (agent-scheme--search-field "start" (agent-scheme--scheme-integer start))
   (agent-scheme--search-field "end" (agent-scheme--scheme-integer end))
   (agent-scheme--search-field "preview" preview)))

(defun agent-scheme--search-buffer-results
    (buffer pattern options source &optional file root)
  "Return search result datums for PATTERN in BUFFER."
  (let ((limit (agent-scheme--search-limit options "search"))
        (preview-limit (agent-scheme--search-preview-limit options "search"))
        (case-fold-search (agent-scheme--search-case-fold-p options "search"))
        results)
    (when (> limit 0)
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (while (and (< (length results) limit)
                        (re-search-forward pattern nil t))
              (let* ((start (match-beginning 0))
                     (end (match-end 0))
                     (line (line-number-at-pos start t))
                     (column
                      (save-excursion
                        (goto-char start)
                        (1+ (current-column))))
                     (preview
                      (agent-scheme--search-truncate-preview
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))
                       preview-limit)))
                (push
                 (agent-scheme--search-result-datum
                  source buffer file root line column start end preview)
                 results)
                (when (and (= start end)
                           (not (eobp)))
                  (forward-char 1))))))))
    (nreverse results)))

(defun agent-scheme--search-project-root (operation)
  "Return current project root for OPERATION."
  (let ((root (agent-scheme--current-project-root-or-error operation)))
    (when (file-remote-p root)
      (agent-scheme--eval-error
       "%s cannot search remote project root: %s" operation root))
    root))

(defun agent-scheme--search-project-files-raw (root)
  "Return absolute project files under ROOT."
  (let* ((project (project-current nil))
         (files
          (condition-case nil
              (and project (project-files project))
            (error nil))))
    (unless files
      (setq files
            (directory-files-recursively
             root
             directory-files-no-dot-files-regexp
             nil)))
    (mapcar
     (lambda (file)
       (if (file-name-absolute-p file)
           (expand-file-name file)
         (expand-file-name file root)))
     files)))

(defun agent-scheme--search-generated-file-p (file root)
  "Return non-nil when FILE is under a generated/runtime directory."
  (let ((parts (split-string
                (file-relative-name (expand-file-name file)
                                    (file-name-as-directory
                                     (expand-file-name root)))
                "/" t)))
    (seq-some
     (lambda (part)
       (member part agent-scheme-search-generated-directories))
     parts)))

(defun agent-scheme--search-file-size (file)
  "Return FILE size in bytes, or nil."
  (file-attribute-size (file-attributes file)))

(defun agent-scheme--search-binary-file-p (file)
  "Return non-nil when FILE appears to contain binary data."
  (let ((limit (min (or (agent-scheme--search-file-size file) 0) 4096)))
    (when (> limit 0)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 limit)
        (goto-char (point-min))
        (search-forward (string 0) nil t)))))

(defun agent-scheme--search-project-file-allowed-p
    (file root options)
  "Return non-nil when FILE may be inspected under ROOT and OPTIONS."
  (let ((maximum-bytes
         (agent-scheme--search-file-byte-limit options "project search")))
    (and (file-regular-p file)
         (not (file-remote-p file))
         (file-in-directory-p (expand-file-name file)
                              (file-name-as-directory
                               (expand-file-name root)))
         (or (agent-scheme--search-include-generated-p
              options "project search")
             (not (agent-scheme--search-generated-file-p file root)))
         (let ((size (agent-scheme--search-file-size file)))
           (and size (<= size maximum-bytes)))
         (or (agent-scheme--search-include-binary-p options "project search")
             (not (agent-scheme--search-binary-file-p file))))))

(defun agent-scheme--search-project-files (root options &optional file-limit)
  "Return guarded absolute project files under ROOT."
  (let ((limit (or file-limit
                   (agent-scheme--search-limit options "project files")))
        files)
    (when (> limit 0)
      (catch 'done
        (dolist (file (sort (agent-scheme--search-project-files-raw root)
                            #'string<))
          (when (agent-scheme--search-project-file-allowed-p file root options)
            (push file files)
            (when (>= (length files) limit)
              (throw 'done nil))))))
    (nreverse files)))

(defun agent-scheme--project-file-datum (file root)
  "Return a Scheme-readable project file datum for FILE."
  (list
   (agent-scheme--search-symbol "project-file")
   (agent-scheme--search-field "file" (expand-file-name file))
   (agent-scheme--search-field
    "relative-file" (agent-scheme--search-relative-file file root))
   (agent-scheme--search-field
    "size" (agent-scheme--scheme-integer
            (or (agent-scheme--search-file-size file) 0)))))

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

(defun agent-scheme--capability-symbol-name (datum description)
  "Return DATUM as a Scheme or Emacs symbol name for DESCRIPTION."
  (cond
   ((agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)
   (t
    (agent-scheme--eval-error
     "%s expected a symbol or string, got %s"
     description
     (agent-scheme-value->external datum)))))

(defun agent-scheme--capability-direction-name (datum description)
  "Return a supported window split direction name for DATUM."
  (let ((name (agent-scheme--capability-symbol-name datum description)))
    (unless (member name '("below" "right"))
      (agent-scheme--eval-error
       "%s expected 'below or 'right, got %s"
       description
       (agent-scheme-value->external datum)))
    name))

(defun agent-scheme--command-whitelist-entry (command)
  "Return the whitelist entry for COMMAND, or nil."
  (seq-find
   (lambda (entry)
     (eq (if (consp entry) (car entry) entry)
         command))
   agent-scheme-command-whitelist))

(defun agent-scheme--command-whitelist-plist (entry)
  "Return the property list carried by whitelist ENTRY."
  (if (consp entry)
      (cdr entry)
    nil))

(defun agent-scheme--command-name (datum)
  "Return command name DATUM as a string."
  (agent-scheme--capability-symbol-name datum "command-call! name"))

(defun agent-scheme--command-symbol (datum)
  "Return command DATUM as an interned Emacs symbol, or nil."
  (intern-soft (agent-scheme--command-name datum)))

(defun agent-scheme--command-call-deny (command reason context)
  "Deny COMMAND for REASON through the command-process policy path."
  (agent-scheme-policy-deny
   'command-process
   "command-call!"
   `((library . "(emacs command)")
     (capability . "command-call!")
     (command . ,command))
   context
   reason
   'capability-call))

(defun agent-scheme--command-argument-value (datum)
  "Convert a Scheme DATUM into a conservative Emacs command argument."
  (cond
   ((eq datum agent-scheme-true) t)
   ((eq datum agent-scheme-false) nil)
   ((stringp datum) (substring-no-properties datum))
   ((and (agent-scheme-number-p datum)
         (eq (agent-scheme-number-kind datum) 'integer)
         (eq (agent-scheme-number-exactness datum) 'exact))
    (agent-scheme-number-value datum))
   ((agent-scheme-symbol-p datum)
    (intern (agent-scheme-symbol-name datum)))
   ((null datum) nil)
   ((consp datum)
    (mapcar #'agent-scheme--command-argument-value datum))
   (t
    (agent-scheme--eval-error
     "command-call! unsupported argument: %s"
     (agent-scheme-value->external datum)))))

(defun agent-scheme--command-minimum-arity (command)
  "Return COMMAND's minimum noninteractive arity, or 0 if unknown."
  (condition-case nil
      (let ((arity (func-arity command)))
        (cond
         ((consp arity) (car arity))
         ((integerp arity) arity)
         (t 0)))
    (error 0)))

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
     (agent-scheme--process-object-live-p
      (agent-scheme--handle-entry-object entry)))
    ('network-stream
     (agent-scheme--network-stream-object-live-p
      (agent-scheme--handle-entry-object entry)))
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
  "Return live private process object for handle VALUE."
  (let ((object
         (agent-scheme--handle-entry-object
          (agent-scheme--handle-entry-for value 'process description))))
    (unless (agent-scheme--process-object-live-p object)
      (agent-scheme--eval-error
       "stale process handle: %s" (agent-scheme-handle-id value)))
    object))

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

(defun agent-scheme--primitive-buffer-switch! (arguments context)
  "Primitive buffer-switch! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-switch!" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-switch!"))
         (window (selected-window)))
    (when (minibufferp buffer)
      (agent-scheme--eval-error
       "buffer-switch! cannot switch to minibuffer: %s"
       (buffer-name buffer)))
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--buffer-target-fields buffer)
      `((target-window . ,(agent-scheme--window-handle window))
        (previous-buffer . ,(buffer-name (window-buffer window))))))
    (set-window-buffer window buffer)
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

(defun agent-scheme--window-target-fields (window)
  "Return Scheme-readable audit fields describing WINDOW."
  `((target-window . ,(agent-scheme--window-handle window))
    (target-buffer . ,(buffer-name (window-buffer window)))
    (target-frame . ,(agent-scheme--frame-handle (window-frame window)))))

(defun agent-scheme--check-window-session-target (window operation)
  "Signal unless WINDOW can be used for OPERATION."
  (when (window-minibuffer-p window)
    (agent-scheme--eval-error
     "%s cannot target minibuffer window" operation)))

(defun agent-scheme--primitive-window-select! (arguments context)
  "Primitive window-select! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "window-select!" arguments context)
  (let ((window (agent-scheme--live-window-for-handle
                 (car arguments) "window-select!")))
    (agent-scheme--check-window-session-target window "window-select!")
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--window-target-fields window)
      `((previous-window . ,(agent-scheme--window-handle
                             (selected-window))))))
    (select-window window)
    agent-scheme-unspecified))

(defun agent-scheme--primitive-window-split! (arguments context)
  "Primitive window-split! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "window-split!" arguments context)
  (let* ((direction
          (agent-scheme--capability-direction-name
           (car arguments) "window-split! direction"))
         (side (intern direction))
         (source-window (selected-window)))
    (agent-scheme--check-window-session-target source-window "window-split!")
    (let ((new-window (split-window source-window nil side)))
      (agent-scheme--add-emacs-capability-result-fields
       `((source-window . ,(agent-scheme--window-handle source-window))
         (target-window . ,(agent-scheme--window-handle new-window))
         (direction . ,(intern direction))))
      (agent-scheme--window-handle new-window))))

(defun agent-scheme--primitive-window-delete! (arguments context)
  "Primitive window-delete! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "window-delete!" arguments context)
  (let ((window (agent-scheme--live-window-for-handle
                 (car arguments) "window-delete!")))
    (agent-scheme--check-window-session-target window "window-delete!")
    (when (<= (length (window-list (window-frame window) 'no-minibuf)) 1)
      (agent-scheme--eval-error
       "window-delete! cannot delete the sole ordinary window"))
    (agent-scheme--add-emacs-capability-result-fields
     (agent-scheme--window-target-fields window))
    (delete-window window)
    agent-scheme-unspecified))

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

(defun agent-scheme--current-project-root-or-error (operation)
  "Return the current project root, or signal for OPERATION."
  (let ((project (project-current nil)))
    (unless project
      (agent-scheme--eval-error
       "%s requires a current project" operation))
    (file-name-as-directory (expand-file-name (project-root project)))))

(defun agent-scheme--diff-buffer-text (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun agent-scheme--diff-file-text (path)
  "Return local file PATH contents as plain text, or an empty string."
  (if (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun agent-scheme--diff-buffer-datum (buffer)
  "Return a canonical diff datum for live BUFFER."
  (let ((file (agent-scheme--buffer-target-file buffer)))
    (when (and file (file-remote-p file))
      (agent-scheme--eval-error
       "buffer-diff cannot inspect remote file: %s" file))
    (let ((old-text (if file (agent-scheme--diff-file-text file)
                      (agent-scheme--diff-buffer-text buffer)))
          (new-text (agent-scheme--diff-buffer-text buffer))
          (old-label (or file (format "buffer:%s" (buffer-name buffer))))
          (new-label (format "buffer:%s" (buffer-name buffer))))
      (agent-scheme-diff-from-strings
       'buffer
       old-label
       new-label
       old-text
       new-text))))

(defun agent-scheme--diff-file-datum (path)
  "Return a canonical diff datum for local file PATH."
  (let ((expanded (expand-file-name path)))
    (when (file-remote-p expanded)
      (agent-scheme--eval-error "file-diff cannot inspect remote file: %s"
                                expanded))
    (let* ((buffer (get-file-buffer expanded))
           (old-text (agent-scheme--diff-file-text expanded))
           (new-text (if (and buffer (buffer-live-p buffer))
                         (agent-scheme--diff-buffer-text buffer)
                       old-text))
           (new-label (if (and buffer (buffer-live-p buffer))
                          (format "buffer:%s" (buffer-name buffer))
                        expanded)))
      (agent-scheme-diff-from-strings
       'file expanded new-label old-text new-text))))

(defun agent-scheme--primitive-buffer-diff (arguments context)
  "Primitive buffer-diff over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-diff" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-diff"))
         (diff (agent-scheme--diff-buffer-datum buffer)))
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--buffer-target-fields buffer)
      `((changed . ,(if (agent-scheme-diff-changed-p diff) t nil)))))
    diff))

(defun agent-scheme--primitive-file-diff (arguments context)
  "Primitive file-diff over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "file-diff" arguments context)
  (let* ((path (expand-file-name
                (agent-scheme--capability-string
                 (car arguments) "file-diff path")))
         (diff (agent-scheme--diff-file-datum path)))
    (agent-scheme--add-emacs-capability-result-fields
     `((target-file . ,path)
       (changed . ,(if (agent-scheme-diff-changed-p diff) t nil))))
    diff))

(defun agent-scheme--primitive-project-diff (arguments context)
  "Primitive project-diff over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "project-diff" arguments context)
  (agent-scheme--proper-list-elements
   (car arguments) "project-diff options")
  (let ((root (agent-scheme--current-project-root-or-error "project-diff"))
        diffs)
    (dolist (buffer (buffer-list))
      (when-let ((file (and (buffer-live-p buffer)
                            (agent-scheme--buffer-target-file buffer))))
        (when (and (file-in-directory-p (expand-file-name file) root)
                   (with-current-buffer buffer (buffer-modified-p)))
          (let ((diff (agent-scheme--diff-buffer-datum buffer)))
            (when (agent-scheme-diff-changed-p diff)
              (push diff diffs))))))
    (setq diffs (nreverse diffs))
    (agent-scheme--add-emacs-capability-result-fields
     `((project-root . ,root)
       (result-count . ,(length diffs))))
    diffs))

(defun agent-scheme--primitive-vcs-root (arguments context)
  "Primitive vcs-root over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-root" arguments context)
  (let ((datum (agent-scheme-vcs-root-datum)))
    (agent-scheme--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)))
    datum))

(defun agent-scheme--primitive-vcs-branch (arguments context)
  "Primitive vcs-branch over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-branch" arguments context)
  (let ((datum (agent-scheme-vcs-branch-datum)))
    (agent-scheme--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)))
    datum))

(defun agent-scheme--primitive-vcs-status (arguments context)
  "Primitive vcs-status over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-status" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-status options")
  (let* ((datum (agent-scheme-vcs-status-datum (car arguments)))
         (entries (agent-scheme-vcs-field-value datum "entries" nil)))
    (agent-scheme--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (result-count . ,(length entries))))
    datum))

(defun agent-scheme--primitive-vcs-diff (arguments context)
  "Primitive vcs-diff over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-diff" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-diff options")
  (let* ((datum (agent-scheme-vcs-diff-datum (car arguments)))
         (files (agent-scheme-vcs-field-value datum "files" nil)))
    (agent-scheme--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (result-count . ,(length files))))
    datum))

(defun agent-scheme--primitive-vcs-recent-commits (arguments context)
  "Primitive vcs-recent-commits over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "vcs-recent-commits" arguments context)
  (let* ((count (agent-scheme--capability-exact-integer
                 (car arguments) "vcs-recent-commits count"))
         (commits (agent-scheme-vcs-recent-commits-datum count)))
    (agent-scheme--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (result-count . ,(length commits))))
    commits))

(defun agent-scheme--primitive-vcs-yield (arguments context)
  "Primitive vcs-yield over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-yield" arguments context)
  (agent-scheme--add-emacs-capability-result-fields
   `((adapter . emacs-vcs)
     (yielded . t)))
  (agent-scheme-agent-io--primitive-yield arguments context))

(defun agent-scheme--record-vcs-mutation-result-fields (operation result)
  "Record audit fields for VCS mutation OPERATION returning RESULT."
  (let* ((status (agent-scheme-vcs-field-value result "status"))
         (outcome (agent-scheme-vcs-field-value result "value"))
         (outcome-status
          (and (agent-scheme-vcs--record-p outcome "vcs-outcome")
               (agent-scheme-vcs-field-value outcome "status"))))
    (agent-scheme--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (vcs-operation . ,operation)
       (vcs-result-status . ,status)
       (vcs-outcome . ,(or outcome-status agent-scheme-false))))))

(defun agent-scheme--primitive-vcs-stage! (arguments context)
  "Primitive vcs-stage! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-stage!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-stage! options")
  (let ((result (agent-scheme-vcs-stage-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'stage result)
    result))

(defun agent-scheme--primitive-vcs-unstage! (arguments context)
  "Primitive vcs-unstage! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-unstage!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-unstage! options")
  (let ((result (agent-scheme-vcs-unstage-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'unstage result)
    result))

(defun agent-scheme--primitive-vcs-commit! (arguments context)
  "Primitive vcs-commit! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-commit!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-commit! options")
  (let ((result (agent-scheme-vcs-commit-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'commit result)
    result))

(defun agent-scheme--primitive-vcs-branch-create! (arguments context)
  "Primitive vcs-branch-create! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "vcs-branch-create!"
   arguments
   context)
  (agent-scheme--proper-list-elements
   (car arguments) "vcs-branch-create! options")
  (let ((result (agent-scheme-vcs-branch-create-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'branch-create result)
    result))

(defun agent-scheme--primitive-vcs-switch! (arguments context)
  "Primitive vcs-switch! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-switch!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-switch! options")
  (let ((result (agent-scheme-vcs-switch-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'switch result)
    result))

(defun agent-scheme--primitive-vcs-fetch! (arguments context)
  "Primitive vcs-fetch! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-fetch!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-fetch! options")
  (let ((result (agent-scheme-vcs-fetch-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'fetch result)
    result))

(defun agent-scheme--primitive-vcs-pull! (arguments context)
  "Primitive vcs-pull! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-pull!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-pull! options")
  (let ((result (agent-scheme-vcs-pull-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'pull result)
    result))

(defun agent-scheme--primitive-vcs-push! (arguments context)
  "Primitive vcs-push! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "vcs-push!" arguments context)
  (agent-scheme--proper-list-elements (car arguments) "vcs-push! options")
  (let ((result (agent-scheme-vcs-push-datum (car arguments))))
    (agent-scheme--record-vcs-mutation-result-fields 'push result)
    result))

(defun agent-scheme--diagnostics-result-count (snapshot)
  "Return the number of diagnostics in SNAPSHOT."
  (length (agent-scheme-diagnostics-snapshot-diagnostics snapshot)))

(defun agent-scheme--primitive-buffer-diagnostics (arguments context)
  "Primitive buffer-diagnostics over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "buffer-diagnostics" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-diagnostics"))
         (snapshot
          (agent-scheme-diagnostics-buffer-snapshot buffer context)))
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--buffer-target-fields buffer)
      `((result-count . ,(agent-scheme--diagnostics-result-count
                          snapshot)))))
    snapshot))

(defun agent-scheme--primitive-project-diagnostics (arguments context)
  "Primitive project-diagnostics over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability
   "project-diagnostics" arguments context)
  (agent-scheme--proper-list-elements
   (car arguments) "project-diagnostics options")
  (let ((snapshot
         (agent-scheme-diagnostics-project-snapshot
          (car arguments) context)))
    (agent-scheme--add-emacs-capability-result-fields
     `((result-count . ,(agent-scheme--diagnostics-result-count snapshot))))
    snapshot))

(defun agent-scheme--primitive-diagnostic-at (arguments context)
  "Primitive diagnostic-at over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "diagnostic-at" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "diagnostic-at"))
         (position
          (agent-scheme--capability-exact-integer
           (cadr arguments) "diagnostic-at position"))
         (diagnostic
          (agent-scheme-diagnostics-at buffer position context)))
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--buffer-target-fields buffer)
      `((position . ,position)
        (matched . ,(not (eq diagnostic agent-scheme-false))))))
    diagnostic))

(defun agent-scheme--primitive-project-compile! (arguments context)
  "Primitive project-compile! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "project-compile!" arguments context)
  (let ((command (agent-scheme--capability-string
                  (car arguments) "project-compile! command"))
        (root (agent-scheme--current-project-root-or-error
               "project-compile!")))
    (agent-scheme--add-emacs-capability-result-fields
     `((project-root . ,root)
       (command . compile)
       (command-arguments . (,command))))
    (let ((default-directory root))
      (compile command))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-project-recompile! (arguments context)
  "Primitive project-recompile!."
  (agent-scheme--authorize-emacs-capability
   "project-recompile!" arguments context)
  (let ((root (agent-scheme--current-project-root-or-error
               "project-recompile!")))
    (agent-scheme--add-emacs-capability-result-fields
     `((project-root . ,root)
       (command . recompile)))
    (let ((default-directory root))
      (recompile))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-buffer-search (arguments context)
  "Primitive buffer-search over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "buffer-search" arguments context)
  (let* ((buffer (agent-scheme--live-buffer-for-handle
                  (car arguments) "buffer-search"))
         (pattern (agent-scheme--capability-string
                   (cadr arguments) "buffer-search pattern"))
         (options (agent-scheme--search-options
                   (caddr arguments) "buffer-search options"))
         (file (agent-scheme--buffer-target-file buffer))
         (results
          (agent-scheme--search-buffer-results
           buffer pattern options 'buffer file nil)))
    (agent-scheme--add-emacs-capability-result-fields
     (append
      (agent-scheme--buffer-target-fields buffer)
      `((pattern . ,pattern)
        (result-count . ,(length results)))))
    results))

(defun agent-scheme--primitive-project-search (arguments context)
  "Primitive project-search over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "project-search" arguments context)
  (let* ((pattern (agent-scheme--capability-string
                   (car arguments) "project-search pattern"))
         (options (agent-scheme--search-options
                   (cadr arguments) "project-search options"))
         (limit (agent-scheme--search-limit options "project-search"))
         (file-limit
          (agent-scheme--search-file-limit options "project-search"))
         (root (agent-scheme--search-project-root "project-search"))
         results)
    (catch 'done
      (dolist (file (agent-scheme--search-project-files
                     root options file-limit))
        (with-temp-buffer
          (insert-file-contents file)
          (let ((file-results
                 (agent-scheme--search-buffer-results
                  (current-buffer) pattern options 'project file root)))
            (dolist (result file-results)
              (push result results)
              (when (>= (length results) limit)
                (throw 'done nil)))))))
    (setq results (nreverse results))
    (agent-scheme--add-emacs-capability-result-fields
     `((project-root . ,root)
       (pattern . ,pattern)
       (result-count . ,(length results))))
    results))

(defun agent-scheme--primitive-project-files (arguments context)
  "Primitive project-files over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "project-files" arguments context)
  (let* ((options (agent-scheme--search-options
                   (car arguments) "project-files options"))
         (root (agent-scheme--search-project-root "project-files"))
         (files (agent-scheme--search-project-files root options))
         (results
          (mapcar
           (lambda (file)
             (agent-scheme--project-file-datum file root))
           files)))
    (agent-scheme--add-emacs-capability-result-fields
     `((project-root . ,root)
       (result-count . ,(length results))))
    results))

(defun agent-scheme--primitive-search-yield (arguments context)
  "Primitive search-yield over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "search-yield" arguments context)
  (let* ((results
          (agent-scheme--proper-list-elements
           (car arguments) "search-yield results"))
         (event
          (list
           (agent-scheme--search-symbol "yield")
           (cons (agent-scheme--search-symbol "search-results")
                 results))))
    (agent-scheme--record-event! context event)
    (agent-scheme-audit-record
     'agent-event
     `((category . emacs-search)
       (operation . "search-yield")
       (decision . recorded)
       (record . ,event)
       (result-count . ,(length results))))
    (agent-scheme--add-emacs-capability-result-fields
     `((result-count . ,(length results))))
    agent-scheme-unspecified))

(defun agent-scheme--process-resource-for-handle (handle)
  "Return an authorization resource plist for process HANDLE."
  (let ((object (agent-scheme--process-handle-object handle)))
    (list :handle handle
          :command (and object (agent-scheme--process-object-command object))
          :arguments (and object
                          (agent-scheme--process-object-arguments object)))))

(defun agent-scheme--primitive-process-start! (arguments context)
  "Primitive process-start! over ARGUMENTS."
  (let* ((name (agent-scheme--capability-string
                (car arguments) "process-start! name"))
         (command (agent-scheme--capability-string
                   (cadr arguments) "process-start! command"))
         (process-arguments
          (agent-scheme--process-normalized-arguments (caddr arguments)))
         (options (cadddr arguments))
         (cwd (agent-scheme--process-cwd options))
         (environment
          (agent-scheme--process-normalized-environment options))
         (resource (list :command command
                         :arguments process-arguments
                         :cwd cwd
                         :environment environment
                         :options options))
         (authorization
          (agent-scheme-capability-authorize-process
           "process-start!" 'spawn context resource))
         (raw
          (let ((default-directory cwd))
            (funcall agent-scheme-process-start-function
                     name command process-arguments options context)))
         (object
          (agent-scheme--process-job-object
           raw name command process-arguments options))
         (handle
          (agent-scheme--process-register-handle
           object (plist-get authorization :grant))))
    (agent-scheme-capability-audit-process-result
     authorization
     `(handle process-job ,(agent-scheme-handle-id handle)))
    (agent-scheme--add-emacs-capability-result-fields
     `((domain . process)
       (operation . spawn)
       (command . ,command)
       (arguments . ,process-arguments)
       (environment . ,environment)
       (cwd . ,cwd)
       (handle . ,handle)))
    handle))

(defun agent-scheme--primitive-emacs-process-list (_arguments context)
  "Primitive emacs-process-list."
  (let ((authorization
         (agent-scheme-capability-authorize-process
          "emacs-process-list" 'observe context nil))
        handles)
    (dolist (process (seq-filter #'process-live-p (process-list)))
      (push (agent-scheme--process-register-handle
             (agent-scheme--process-job-object
              process
              (process-name process)
              (or (car (process-command process)) (process-name process))
              (or (cdr (process-command process)) nil)
              nil)
             (plist-get authorization :grant))
            handles))
    (setq handles (nreverse handles))
    (agent-scheme-capability-audit-process-result
     authorization `(handles ,(length handles)))
    handles))

(defun agent-scheme--primitive-process-name (arguments context)
  "Primitive process-name over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorization
          (agent-scheme-capability-authorize-process
           "process-name" 'observe context
           (agent-scheme--process-resource-for-handle handle)))
         (object (agent-scheme--live-process-for-handle handle "process-name"))
         (name (agent-scheme--process-object-name object)))
    (agent-scheme-capability-audit-process-result authorization name)
    name))

(defun agent-scheme--primitive-process-status (arguments context)
  "Primitive process-status over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorization
          (agent-scheme-capability-authorize-process
           "process-status" 'observe context
           (agent-scheme--process-resource-for-handle handle)))
         (object (agent-scheme--live-process-for-handle
                  handle "process-status"))
         (status (agent-scheme--process-object-status object)))
    (agent-scheme-capability-audit-process-result authorization status)
    (agent-scheme--scheme-symbol status)))

(defun agent-scheme--primitive-process-buffer (arguments context)
  "Primitive process-buffer over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorization
          (agent-scheme-capability-authorize-process
           "process-buffer" 'observe context
           (agent-scheme--process-resource-for-handle handle)))
         (object (agent-scheme--live-process-for-handle
                  handle "process-buffer"))
         (buffer (agent-scheme--process-object-buffer object)))
    (agent-scheme-capability-audit-process-result
     authorization
     (if buffer (buffer-name buffer) agent-scheme-false))
    (if buffer
        (agent-scheme--buffer-handle buffer)
      agent-scheme-false)))

(defun agent-scheme--process-port (handle stream kind operations context)
  "Return process HANDLE STREAM as an Agent Scheme port."
  (let* ((operation (if (eq stream 'stdin) 'input 'output))
         (authorization
          (agent-scheme-capability-authorize-process
           (pcase stream
             ('stdin "process-input-port")
             ('stderr "process-error-port")
             (_ "process-output-port"))
           operation
           context
           (agent-scheme--process-resource-for-handle handle)))
         (object
          (agent-scheme--live-process-for-handle handle "process port"))
         (port
          (if (eq stream 'stdin)
              (agent-scheme--make-port
               :medium 'process
               :outputp t
               :textualp t
               :contents "")
            (agent-scheme--make-port
             :medium 'process
             :inputp t
             :textualp t
             :source (agent-scheme--process-object-output object stream)
             :position 0))))
    (agent-scheme-capability-audit-process-result
     authorization `(port ,stream))
    (agent-scheme-capability-register-process-port
     port kind authorization handle stream operations)))

(defun agent-scheme--primitive-process-output-port (arguments context)
  "Primitive process-output-port over ARGUMENTS."
  (agent-scheme--process-port
   (car arguments) 'stdout 'textual-input '(read close) context))

(defun agent-scheme--primitive-process-error-port (arguments context)
  "Primitive process-error-port over ARGUMENTS."
  (agent-scheme--process-port
   (car arguments) 'stderr 'textual-input '(read close) context))

(defun agent-scheme--primitive-process-input-port (arguments context)
  "Primitive process-input-port over ARGUMENTS."
  (agent-scheme--process-port
   (car arguments) 'stdin 'textual-output '(write flush close) context))

(defun agent-scheme--process-control! (handle operation binding context)
  "Apply process control OPERATION for BINDING to HANDLE."
  (let* ((authorization
          (agent-scheme-capability-authorize-process
           binding operation context
           (agent-scheme--process-resource-for-handle handle)))
         (object (agent-scheme--live-process-for-handle handle binding))
         (process (agent-scheme--process-object-process object)))
    (when process
      (pcase operation
        ('interrupt (interrupt-process process))
        ('terminate (delete-process process))))
    (agent-scheme-capability-audit-process-result authorization operation)
    agent-scheme-unspecified))

(defun agent-scheme--primitive-process-interrupt! (arguments context)
  "Primitive process-interrupt! over ARGUMENTS."
  (agent-scheme--process-control!
   (car arguments) 'interrupt "process-interrupt!" context))

(defun agent-scheme--primitive-process-kill! (arguments context)
  "Primitive process-kill! over ARGUMENTS."
  (agent-scheme--process-control!
   (car arguments) 'terminate "process-kill!" context))

(defun agent-scheme--primitive-network-http-request (arguments context)
  "Primitive network-http-request over ARGUMENTS."
  (let* ((method (car arguments))
         (url (cadr arguments))
         (headers (caddr arguments))
         (payload (cadddr arguments))
         (options (nth 4 arguments))
         (resource
          (agent-scheme--network-resource
           method url headers payload options))
         (authorization
          (agent-scheme-capability-authorize-network
           "(emacs network)"
           "network-http-request"
           context
           'request
           resource))
         (response
          (agent-scheme--network-normalize-response-datum
           (funcall agent-scheme-network-request-function
                    (plist-get authorization :transport-resource)
                    context))))
    (agent-scheme--network-check-response-limit! authorization response)
    (agent-scheme-capability-audit-network-result authorization response)
    (agent-scheme--add-emacs-capability-result-fields
     `((domain . network)
       (operation . request)
       (scheme . ,(plist-get resource :scheme))
       (host . ,(plist-get resource :host))
       (port . ,(plist-get resource :port))
       (method . ,(plist-get resource :method))
       (payload-class . ,(plist-get resource :payload-class))
       (response-size . ,(agent-scheme--network-response-body-size response))))
    response))

(defun agent-scheme--primitive-network-open-sse-stream (arguments context)
  "Primitive network-open-sse-stream over ARGUMENTS."
  (let* ((url (car arguments))
         (headers (cadr arguments))
         (options (caddr arguments))
         (resource
          (agent-scheme--network-resource
           'GET url headers "" options t))
         (authorization
          (agent-scheme-capability-authorize-network
           "(emacs network)"
           "network-open-sse-stream"
           context
           'stream
           resource))
         (source
          (funcall agent-scheme-network-stream-function
                   (plist-get authorization :transport-resource)
                   context)))
    (unless (stringp source)
      (agent-scheme--eval-error
       "network-open-sse-stream adapter must return textual stream contents"))
    (let* ((stream-handle
            (agent-scheme--network-register-stream-handle
             (plist-get resource :url)
             source
             authorization))
           (port
            (agent-scheme--make-port
             :medium 'network
             :inputp t
             :textualp t
             :source source
             :position 0)))
      (agent-scheme-capability-audit-network-result
       authorization
       `(handle network-stream ,(agent-scheme-handle-id stream-handle)))
      (agent-scheme--add-emacs-capability-result-fields
       `((domain . network)
         (operation . stream)
         (scheme . ,(plist-get resource :scheme))
         (host . ,(plist-get resource :host))
         (port . ,(plist-get resource :port))
         (method . ,(plist-get resource :method))
         (handle . ,stream-handle)))
      (agent-scheme-capability-register-network-port
       port 'textual-input authorization stream-handle '(read close)))))

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

(defun agent-scheme--primitive-command-call! (arguments context)
  "Primitive command-call! over ARGUMENTS."
  (agent-scheme--authorize-emacs-capability "command-call!" arguments context)
  (let* ((command (agent-scheme--command-symbol (car arguments)))
         (command-name (agent-scheme--command-name (car arguments)))
         (entry (and command
                     (agent-scheme--command-whitelist-entry command)))
         (plist (agent-scheme--command-whitelist-plist entry))
         (scheme-arguments (cdr arguments))
         (emacs-arguments
          (if scheme-arguments
              (mapcar #'agent-scheme--command-argument-value scheme-arguments)
            (copy-sequence (plist-get plist :default-arguments))))
         (allow-interactive (plist-get plist :allow-interactive)))
    (unless entry
      (agent-scheme--command-call-deny
       command-name "command is not whitelisted" context))
    (unless (and command (commandp command))
      (agent-scheme--command-call-deny
       command-name "command is not an interactive command" context))
    (when (and (< (length emacs-arguments)
                  (agent-scheme--command-minimum-arity command))
               (not allow-interactive))
      (agent-scheme--eval-error
       "interactive prompt is not allowed for command: %s"
       command-name))
    (agent-scheme--add-emacs-capability-result-fields
     `((command . ,command)
       (command-arguments . ,emacs-arguments)
       (interactive . ,(if allow-interactive
                           agent-scheme-true
                         agent-scheme-false))))
    (if (< (length emacs-arguments)
           (agent-scheme--command-minimum-arity command))
        (call-interactively command)
      (apply command emacs-arguments))
    agent-scheme-unspecified))

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
