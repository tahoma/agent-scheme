;;; consent-capability.el --- Emacs capability primitives  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

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
(require 'consent-audit)
(require 'consent-diagnostics)
(require 'consent-diff)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-policy)
(require 'consent-redaction)
(require 'consent-vcs)

(declare-function consent--apply-procedure "consent-interpreter")

(define-error 'consent-capability-grant-error
  "Consent Scheme capability grant denied"
  'consent-eval-error)

(defcustom consent-capability-require-grants-for-mutations t
  "Non-nil means host mutation capabilities require matching grants."
  :type 'boolean
  :group 'consent)

(defcustom consent-command-whitelist
  '((save-buffer :allow-interactive nil)
    (revert-buffer :allow-interactive nil :default-arguments (nil t))
    (compile :allow-interactive nil)
    (recompile :allow-interactive nil))
  "Commands that `command-call!' may invoke from Consent Scheme.
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
  :group 'consent)

(defcustom consent-process-command-allowlist nil
  "Command names that `process-start!' may launch.
Entries may be command strings or symbols.  Process grants still
need to authorize the specific command, working directory, and
operations requested by Scheme code."
  :type '(repeat (choice string symbol))
  :group 'consent)

(defun consent--default-process-start
    (name command arguments options _context)
  "Default host adapter for `process-start!'."
  (let* ((buffer (generate-new-buffer
                  (format " *Consent Scheme process: %s*" name)))
         (process-environment
          (append
           (mapcar
            (lambda (entry)
              (format "%s=%s" (car entry) (cadr entry)))
            (consent--process-normalized-environment options))
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

(defcustom consent-process-start-function
  #'consent--default-process-start
  "Function that starts host process jobs for `process-start!'.
The function receives NAME, COMMAND, ARGUMENTS, OPTIONS, and
CONTEXT, and returns either a host process object or a plist with
Scheme-readable metadata such as `:name', `:status', `:stdout',
and `:stderr'.  It is called only after command allow-list,
grant, and policy checks succeed."
  :type 'function
  :group 'consent)

(defun consent--default-compile-start (command options _context)
  "Default host adapter for `(emacs compile)' COMMAND and OPTIONS."
  (let* ((default-directory (consent--process-cwd options))
         (buffer (compile command))
         (process (get-buffer-process buffer)))
    (list :name (buffer-name buffer)
          :command command
          :arguments nil
          :options options
          :status (if process (process-status process) 'exit)
          :process process
          :buffer buffer
          :stdout ""
          :stderr "")))

(defcustom consent-compile-start-function
  #'consent--default-compile-start
  "Function that starts authorized Emacs compilation jobs.
The function receives COMMAND, OPTIONS, and CONTEXT after process
allow-list, grant, and policy checks succeed.  It must return a
host process object or a plist with Scheme-readable process
metadata such as `:name', `:status', `:buffer', `:stdout', and
`:stderr'."
  :type 'function
  :group 'consent)

(defun consent--default-network-request (resource _context)
  "Default host adapter for network requests.
RESOURCE is a redacted Scheme-readable request resource.  The
default refuses live transport so tests and hosts must install an
explicit adapter before bytes can leave the runtime."
  (signal 'consent-capability-grant-error
          (list "no network request adapter configured")))

(defcustom consent-network-request-function
  #'consent--default-network-request
  "Function that performs authorized network request resources.
The function receives a redacted Scheme-readable RESOURCE and
CONTEXT after network grant, policy, and redaction checks have
succeeded.  It must return a Scheme-readable response datum."
  :type 'function
  :group 'consent)

(defun consent--default-network-stream (resource _context)
  "Default host adapter for network stream requests."
  (signal 'consent-capability-grant-error
          (list "no network stream adapter configured")))

(defcustom consent-network-stream-function
  #'consent--default-network-stream
  "Function that opens authorized network stream resources.
The function receives a redacted Scheme-readable RESOURCE and
CONTEXT after network grant, policy, and redaction checks have
succeeded.  It must return textual stream contents for the
network-backed port."
  :type 'function
  :group 'consent)

(defcustom consent-time-tai-utc-offset 37
  "TAI minus UTC offset applied to Emacs wall-clock seconds.
Emacs exposes POSIX-style seconds; R7RS `current-second' is specified on the
TAI scale.  Hosts can update this value when leap-second policy changes."
  :type 'integer
  :group 'consent)

(defcustom consent-time-jiffies-per-second 1000000
  "Number of clock jiffies per SI second for `(scheme time)'."
  :type 'integer
  :group 'consent)

(defun consent--default-time-current-second ()
  "Return an R7RS-compatible current-second value from the Emacs host clock."
  (+ (float-time) consent-time-tai-utc-offset))

(defun consent--default-time-current-jiffy ()
  "Return an exact current-jiffy value from the Emacs host clock."
  (truncate (* (float-time) consent-time-jiffies-per-second)))

(defun consent--default-time-jiffies-per-second ()
  "Return the Emacs host jiffies-per-second constant."
  consent-time-jiffies-per-second)

(defcustom consent-time-current-second-function
  #'consent--default-time-current-second
  "Function called after clock authorization to implement `current-second'."
  :type 'function
  :group 'consent)

(defcustom consent-time-current-jiffy-function
  #'consent--default-time-current-jiffy
  "Function called after clock authorization to implement `current-jiffy'."
  :type 'function
  :group 'consent)

(defcustom consent-time-jiffies-per-second-function
  #'consent--default-time-jiffies-per-second
  "Function called after clock authorization to implement `jiffies-per-second'."
  :type 'function
  :group 'consent)

(defcustom consent-search-default-limit 100
  "Default maximum number of results returned by one search capability call."
  :type 'integer
  :group 'consent)

(defcustom consent-search-default-file-limit 10000
  "Default maximum number of project files considered by search calls."
  :type 'integer
  :group 'consent)

(defcustom consent-search-default-maximum-file-bytes 1048576
  "Default maximum size of a project file read by search capabilities."
  :type 'integer
  :group 'consent)

(defcustom consent-search-default-preview-characters 160
  "Default maximum number of line-preview characters in search results."
  :type 'integer
  :group 'consent)

(defcustom consent-search-generated-directories
  '(".consent"
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
  :group 'consent)

(cl-defstruct (consent--handle-entry
               (:constructor consent--make-handle-entry (kind object))
               (:copier nil))
  "Private host object registered behind an opaque Consent Scheme handle."
  kind
  object
  id
  (status 'live)
  owner
  created-by
  created-at
  last-validated
  source
  durable-reference
  released-at)

(defvar consent--handle-registry (make-hash-table :test #'equal)
  "Private table from opaque handle ids to live host objects.")

(defvar consent--next-handle-number 0
  "Next numeric suffix for generated opaque handle ids.")

(defvar consent--handle-registration-context nil
  "Eval context used to annotate handles created by capability calls.")

(defvar consent--handle-registration-created-by nil
  "Capability binding currently creating a handle, or nil.")

(defvar consent--emacs-capability-preauthorized nil
  "Non-nil while a wrapped Emacs capability has already passed policy.")

(defvar consent--emacs-capability-result-fields nil
  "Additional Scheme-readable audit fields for the active capability call.")

(defvar consent--next-capability-grant-number 0
  "Next numeric suffix for generated capability grant ids.")

(defvar consent--next-capability-revocation-number 0
  "Next numeric suffix for generated capability revocation ids.")

(defvar consent--next-file-capability-request-number 0
  "Next numeric suffix for generated file capability request ids.")

(defvar consent--next-file-capability-decision-number 0
  "Next numeric suffix for generated file capability decision ids.")

(defvar consent--next-port-capability-handle-number 0
  "Next numeric suffix for generated port capability handle ids.")

(defvar consent--next-code-loading-request-number 0
  "Next numeric suffix for generated code-loading request ids.")

(defvar consent--next-code-loading-decision-number 0
  "Next numeric suffix for generated code-loading decision ids.")

(defvar consent--next-process-capability-request-number 0
  "Next numeric suffix for generated process capability request ids.")

(defvar consent--next-process-capability-decision-number 0
  "Next numeric suffix for generated process capability decision ids.")

(defvar consent--next-process-port-capability-handle-number 0
  "Next numeric suffix for generated process-backed port capability ids.")

(defvar consent--next-network-capability-request-number 0
  "Next numeric suffix for generated network capability request ids.")

(defvar consent--next-network-capability-decision-number 0
  "Next numeric suffix for generated network capability decision ids.")

(defvar consent--next-clock-capability-request-number 0
  "Next numeric suffix for generated clock capability request ids.")

(defvar consent--next-clock-capability-decision-number 0
  "Next numeric suffix for generated clock capability decision ids.")

(defvar consent--next-network-stream-handle-number 0
  "Next numeric suffix for generated network stream handles.")

(defvar consent--next-network-port-capability-handle-number 0
  "Next numeric suffix for generated network-backed port capability ids.")

(defconst consent--emacs-capability-manifest-specs
  '((:name "emacs-current-buffer" :library "(emacs buffer)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-emacs-current-buffer
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer handle))
    (:name "buffer-name" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "buffer-file-name" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-file-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "buffer-major-mode" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-major-mode
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "buffer-text" :library "(emacs buffer)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-text
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer text))
    (:name "buffer-insert!" :library "(emacs buffer edit)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-insert!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-delete!" :library "(emacs buffer edit)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-delete!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-replace!" :library "(emacs buffer edit)"
     :minimum-arity 4 :maximum-arity 4
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-replace!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
     :test-categories (emacs buffer edit mutation))
    (:name "buffer-save!" :library "(emacs buffer edit)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-save!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category buffer-edit
     :requires-grant t
     :test-categories (emacs buffer edit mutation file))
    (:name "buffer-switch!" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-switch!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs buffer window session mutation))
    (:name "buffer-point" :library "(emacs buffer)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-buffer-point
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer))
    (:name "emacs-buffer-list" :library "(emacs buffer)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-buffer
     :emacs-hook consent--primitive-emacs-buffer-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs buffer handle))
    (:name "emacs-window-list" :library "(emacs window)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-window
     :emacs-hook consent--primitive-emacs-window-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs window handle))
    (:name "window-frame" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-window
     :emacs-hook consent--primitive-window-frame
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs window frame handle))
    (:name "window-select!" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-window
     :emacs-hook consent--primitive-window-select!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs window session mutation))
    (:name "window-split!" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-window
     :emacs-hook consent--primitive-window-split!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs window session mutation))
    (:name "window-delete!" :library "(emacs window)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-window
     :emacs-hook consent--primitive-window-delete!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category window-session
     :requires-grant t
     :test-categories (emacs window session mutation))
    (:name "emacs-current-frame" :library "(emacs frame)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-frame
     :emacs-hook consent--primitive-emacs-current-frame
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs frame handle))
    (:name "emacs-frame-list" :library "(emacs frame)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-frame
     :emacs-hook consent--primitive-emacs-frame-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs frame handle))
    (:name "frame-name" :library "(emacs frame)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-frame
     :emacs-hook consent--primitive-frame-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs frame))
    (:name "emacs-current-project" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-project
     :emacs-hook consent--primitive-emacs-current-project
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs project handle))
    (:name "project-root" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-project
     :emacs-hook consent--primitive-project-root
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs project))
    (:name "project-compile!" :library "(emacs project)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-project
     :emacs-hook consent--primitive-project-compile!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :test-categories (emacs project command process mutation))
    (:name "project-recompile!" :library "(emacs project)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-mutation
     :required-capability emacs-project
     :emacs-hook consent--primitive-project-recompile!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :test-categories (emacs project command process mutation))
    (:name "buffer-search" :library "(emacs search)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook consent--primitive-buffer-search
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search buffer))
    (:name "project-search" :library "(emacs search)"
     :minimum-arity 2 :maximum-arity 2
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook consent--primitive-project-search
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search project))
    (:name "project-files" :library "(emacs search)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook consent--primitive-project-files
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search project files))
    (:name "buffer-diff" :library "(emacs diff)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diff
     :emacs-hook consent--primitive-buffer-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diff buffer))
    (:name "file-diff" :library "(emacs diff)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diff
     :emacs-hook consent--primitive-file-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diff file))
    (:name "project-diff" :library "(emacs diff)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diff
     :emacs-hook consent--primitive-project-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diff project))
    (:name "vcs-root" :library "(emacs vcs)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-root
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs root))
    (:name "vcs-branch" :library "(emacs vcs)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-branch
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs branch))
    (:name "vcs-status" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-status
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs status))
    (:name "vcs-diff" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-diff
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs diff))
    (:name "vcs-recent-commits" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-recent-commits
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs commits))
    (:name "vcs-yield" :library "(emacs vcs)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-yield
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs vcs yield))
    (:name "vcs-stage!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-stage!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation stage))
    (:name "vcs-unstage!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-unstage!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation unstage))
    (:name "vcs-commit!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-commit!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation commit))
    (:name "vcs-branch-create!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-branch-create!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation branch))
    (:name "vcs-switch!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-switch!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation switch))
    (:name "vcs-fetch!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-fetch!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation remote fetch))
    (:name "vcs-pull!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-pull!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation remote pull))
    (:name "vcs-push!" :library "(emacs vcs mutation)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-vcs
     :emacs-hook consent--primitive-vcs-push!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category vcs-mutation
     :test-categories (emacs vcs mutation remote push))
    (:name "buffer-diagnostics" :library "(emacs diagnostics)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diagnostics
     :emacs-hook consent--primitive-buffer-diagnostics
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diagnostics buffer))
    (:name "project-diagnostics" :library "(emacs diagnostics)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-diagnostics
     :emacs-hook consent--primitive-project-diagnostics
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diagnostics project))
    (:name "diagnostic-at" :library "(emacs diagnostics)"
     :minimum-arity 2 :maximum-arity 2
     :source host-capability :effect host-observation
     :required-capability emacs-diagnostics
     :emacs-hook consent--primitive-diagnostic-at
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs diagnostics buffer))
    (:name "search-yield" :library "(emacs search)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-search
     :emacs-hook consent--primitive-search-yield
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs search agent-io))
    (:name "process-start!" :library "(emacs process)"
     :minimum-arity 4 :maximum-arity 4
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-start!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process mutation handle))
    (:name "emacs-process-list" :library "(emacs process)"
     :minimum-arity 0 :maximum-arity 0
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook consent--primitive-emacs-process-list
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process handle))
    (:name "process-name" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-name
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process))
    (:name "process-status" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-status
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process))
    (:name "process-buffer" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-buffer
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process buffer handle))
    (:name "process-output-port" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-output-port
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process port output))
    (:name "process-error-port" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-error-port
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :requires-process-grant t
     :test-categories (emacs process port output))
    (:name "process-input-port" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-input-port
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process port input mutation))
    (:name "process-interrupt!" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-interrupt!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process control mutation))
    (:name "process-kill!" :library "(emacs process)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-process
     :emacs-hook consent--primitive-process-kill!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs process control mutation))
    (:name "compile-run!" :library "(emacs compile)"
     :minimum-arity 2 :maximum-arity 2
     :source host-capability :effect host-mutation
     :required-capability emacs-compile
     :emacs-hook consent--primitive-compile-run!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs compile process mutation handle))
    (:name "project-compile!" :library "(emacs compile)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-compile
     :emacs-hook consent--primitive-emacs-compile-project-compile!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs compile project process mutation handle))
    (:name "recompile!" :library "(emacs compile)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-mutation
     :required-capability emacs-compile
     :emacs-hook consent--primitive-compile-recompile!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs compile process mutation handle))
    (:name "compile-status" :library "(emacs compile)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-compile
     :emacs-hook consent--primitive-compile-status
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs compile process handle))
    (:name "compile-output" :library "(emacs compile)"
     :minimum-arity 2 :maximum-arity 2
     :source host-capability :effect host-observation
     :required-capability emacs-compile
     :emacs-hook consent--primitive-compile-output
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs compile process output))
    (:name "compile-yield" :library "(emacs compile)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-compile
     :emacs-hook consent--primitive-compile-yield
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :policy-category command-process
     :requires-process-grant t
     :test-categories (emacs compile process agent-io))
    (:name "network-http-request" :library "(emacs network)"
     :minimum-arity 5 :maximum-arity 5
     :source host-capability :effect host-network
     :required-capability network
     :emacs-hook consent--primitive-network-http-request
     :portable-hook nil :emitter-hook capability-network
     :policy deny :policy-category network-access
     :requires-network-grant t
     :test-categories (emacs network http))
    (:name "network-open-sse-stream" :library "(emacs network)"
     :minimum-arity 3 :maximum-arity 3
     :source host-capability :effect host-network
     :required-capability network
     :emacs-hook consent--primitive-network-open-sse-stream
     :portable-hook nil :emitter-hook capability-network
     :policy deny :policy-category network-access
     :requires-network-grant t
     :test-categories (emacs network sse port stream))
    (:name "command-doc" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook consent--primitive-command-doc
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation))
    (:name "command-call!" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity nil
     :source host-capability :effect host-mutation
     :required-capability emacs-command
     :emacs-hook consent--primitive-command-call!
     :portable-hook nil :emitter-hook capability-emacs
     :policy confirm :policy-category command-process
     :test-categories (emacs command process mutation whitelist))
    (:name "function-doc" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook consent--primitive-function-doc
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation))
    (:name "variable-info" :library "(emacs command)"
     :minimum-arity 1 :maximum-arity 1
     :source host-capability :effect host-observation
     :required-capability emacs-documentation
     :emacs-hook consent--primitive-variable-info
     :portable-hook nil :emitter-hook capability-emacs
     :policy allow :test-categories (emacs documentation variable)))
  "Manifest metadata for Emacs capability primitives.")

(defconst consent--emacs-capability-documentation-table
  '((("(emacs buffer)" . "emacs-current-buffer")
     . "Return a handle for the current Emacs buffer.")
    (("(emacs buffer)" . "buffer-name")
     . "Return the display name for a buffer handle.")
    (("(emacs buffer)" . "buffer-file-name")
     . "Return the visited file path for a buffer handle, or #f for non-file buffers.")
    (("(emacs buffer)" . "buffer-major-mode")
     . "Return the major-mode symbol for a buffer handle.")
    (("(emacs buffer)" . "buffer-text")
     . "Return text from a buffer handle between start and end positions.")
    (("(emacs buffer edit)" . "buffer-insert!")
     . "Insert text into a buffer handle at a position, subject to buffer edit policy.")
    (("(emacs buffer edit)" . "buffer-delete!")
     . "Delete text from a buffer handle between start and end positions, subject to buffer edit policy.")
    (("(emacs buffer edit)" . "buffer-replace!")
     . "Replace text in a buffer handle between start and end positions, subject to buffer edit policy.")
    (("(emacs buffer edit)" . "buffer-save!")
     . "Save a file-backed buffer handle, subject to buffer edit policy.")
    (("(emacs buffer)" . "buffer-switch!")
     . "Select a buffer in the current window, subject to window-session policy.")
    (("(emacs buffer)" . "buffer-point")
     . "Return the current point position for a buffer handle.")
    (("(emacs buffer)" . "emacs-buffer-list")
     . "Return handles for live Emacs buffers visible to the session.")
    (("(emacs window)" . "emacs-window-list")
     . "Return handles for live Emacs windows visible to the session.")
    (("(emacs window)" . "window-frame")
     . "Return the frame handle that owns a window handle.")
    (("(emacs window)" . "window-select!")
     . "Select a window handle, subject to window-session policy.")
    (("(emacs window)" . "window-split!")
     . "Split a window handle, subject to window-session policy.")
    (("(emacs window)" . "window-delete!")
     . "Delete a window handle, subject to window-session policy.")
    (("(emacs frame)" . "emacs-current-frame")
     . "Return a handle for the current Emacs frame.")
    (("(emacs frame)" . "emacs-frame-list")
     . "Return handles for live Emacs frames visible to the session.")
    (("(emacs frame)" . "frame-name")
     . "Return the display name for a frame handle.")
    (("(emacs project)" . "emacs-current-project")
     . "Return a handle for the current project, or #f when no project is active.")
    (("(emacs project)" . "project-root")
     . "Return the root directory for a project handle or the current project.")
    (("(emacs project)" . "project-compile!")
     . "Start the project compile command, subject to command-process policy.")
    (("(emacs project)" . "project-recompile!")
     . "Restart the previous project compilation, subject to command-process policy.")
    (("(emacs search)" . "buffer-search")
     . "Search a buffer handle and return bounded match locations.")
    (("(emacs search)" . "project-search")
     . "Search project files and return bounded match locations.")
    (("(emacs search)" . "project-files")
     . "Return project file paths visible to the current project capability.")
    (("(emacs diff)" . "buffer-diff")
     . "Return a structured diff for one buffer against its file or saved baseline.")
    (("(emacs diff)" . "file-diff")
     . "Return a structured diff for one file path.")
    (("(emacs diff)" . "project-diff")
     . "Return a structured diff for project changes visible to the session.")
    (("(emacs vcs)" . "vcs-root")
     . "Return the version-control root for the current project or #f.")
    (("(emacs vcs)" . "vcs-branch")
     . "Return the current version-control branch name or #f.")
    (("(emacs vcs)" . "vcs-status")
     . "Return structured version-control status for a requested scope.")
    (("(emacs vcs)" . "vcs-diff")
     . "Return structured version-control diff data for a requested scope.")
    (("(emacs vcs)" . "vcs-recent-commits")
     . "Return recent version-control commit summaries for a requested scope.")
    (("(emacs vcs)" . "vcs-yield")
     . "Record version-control information as an agent yield event.")
    (("(emacs vcs mutation)" . "vcs-stage!")
     . "Stage paths in version control, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-unstage!")
     . "Unstage paths in version control, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-commit!")
     . "Create a version-control commit, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-branch-create!")
     . "Create a version-control branch, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-switch!")
     . "Switch the version-control worktree to a branch, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-fetch!")
     . "Fetch version-control remote updates, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-pull!")
     . "Pull version-control remote updates, subject to VCS mutation policy.")
    (("(emacs vcs mutation)" . "vcs-push!")
     . "Push version-control commits to a remote, subject to VCS mutation policy.")
    (("(emacs diagnostics)" . "buffer-diagnostics")
     . "Return diagnostics for one buffer handle.")
    (("(emacs diagnostics)" . "project-diagnostics")
     . "Return diagnostics for project files visible to the session.")
    (("(emacs diagnostics)" . "diagnostic-at")
     . "Return diagnostics covering a buffer position.")
    (("(emacs search)" . "search-yield")
     . "Record search results as an agent yield event.")
    (("(emacs process)" . "process-start!")
     . "Start a configured process job, subject to command-process policy.")
    (("(emacs process)" . "emacs-process-list")
     . "Return handles for live process jobs visible to the session.")
    (("(emacs process)" . "process-name")
     . "Return the display name for a process handle.")
    (("(emacs process)" . "process-status")
     . "Return the current status for a process handle.")
    (("(emacs process)" . "process-buffer")
     . "Return the output buffer handle associated with a process handle.")
    (("(emacs process)" . "process-output-port")
     . "Return a textual input port for reading a process handle's standard output.")
    (("(emacs process)" . "process-error-port")
     . "Return a textual input port for reading a process handle's standard error.")
    (("(emacs process)" . "process-input-port")
     . "Return a textual output port for writing to a process handle's standard input, subject to process policy.")
    (("(emacs process)" . "process-interrupt!")
     . "Interrupt a process handle, subject to command-process policy.")
    (("(emacs process)" . "process-kill!")
     . "Kill a process handle, subject to command-process policy.")
    (("(emacs compile)" . "compile-run!")
     . "Start a compile command in a project directory, subject to command-process policy.")
    (("(emacs compile)" . "project-compile!")
     . "Start the project compile workflow, subject to command-process policy.")
    (("(emacs compile)" . "recompile!")
     . "Restart a compile job, subject to command-process policy.")
    (("(emacs compile)" . "compile-status")
     . "Return the status for a compile job handle.")
    (("(emacs compile)" . "compile-output")
     . "Return a bounded slice of compile output for a job handle.")
    (("(emacs compile)" . "compile-yield")
     . "Record compile output or status as an agent yield event.")
    (("(emacs network)" . "network-http-request")
     . "Submit an HTTP request through the network capability policy.")
    (("(emacs network)" . "network-open-sse-stream")
     . "Open a server-sent event stream through the network capability policy.")
    (("(emacs command)" . "command-doc")
     . "Return public documentation for an Emacs command symbol.")
    (("(emacs command)" . "command-call!")
     . "Invoke an allowlisted Emacs command with optional arguments, subject to command policy.")
    (("(emacs command)" . "function-doc")
     . "Return public documentation for an Emacs function symbol.")
    (("(emacs command)" . "variable-info")
     . "Return safe metadata about an Emacs variable without exposing its value."))
  "User-facing documentation for Emacs capability primitives.")

(defun consent--emacs-capability-documentation (library name)
  "Return public manifest documentation for Emacs capability LIBRARY NAME."
  (cdr (assoc (cons library name)
              consent--emacs-capability-documentation-table)))

(defconst consent--emacs-capability-library-keys
  '("(emacs buffer)"
    "(emacs buffer edit)"
    "(emacs command)"
    "(emacs compile)"
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

(defun consent-emacs-capability-binding-specs ()
  "Return manifest metadata for Emacs capability primitive bindings."
  (mapcar
   (lambda (spec)
     (append spec
             (list :backend-effect-path 'shared-capability-request
                   :policy-category 'emacs-read-only)
             (consent--primitive-manifest-documentation-properties
              (consent--emacs-capability-documentation
               (plist-get spec :library)
               (plist-get spec :name)))))
   consent--emacs-capability-manifest-specs))

(defun consent-emacs-capability-library-keys ()
  "Return importable Emacs capability library keys."
  consent--emacs-capability-library-keys)

(defun consent-emacs-capability-primitive-specs (library)
  "Return primitive registration specs for Emacs capability LIBRARY."
  (mapcar
   (lambda (spec)
     (let ((name (plist-get spec :name)))
       (list name
             (consent--wrap-emacs-capability
              name
              (plist-get spec :emacs-hook))
             (plist-get spec :minimum-arity)
             (plist-get spec :maximum-arity))))
   (seq-filter
    (lambda (spec)
      (equal (plist-get spec :library) library))
    consent--emacs-capability-manifest-specs)))

(defun consent--emacs-capability-manifest-spec (name)
  "Return manifest metadata for Emacs capability NAME."
  (seq-find
   (lambda (spec)
     (equal (plist-get spec :name) name))
   consent--emacs-capability-manifest-specs))

(defun consent--emacs-capability-policy-category (spec)
  "Return the policy category for Emacs capability SPEC."
  (or (and spec (plist-get spec :policy-category))
      'emacs-read-only))

(defun consent--capability-grant-symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--intern-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent--capability-grant-symbol-name (value)
  "Return VALUE as a stable grant field name."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun consent--capability-grant-field-named-p (field name)
  "Return non-nil when FIELD is named NAME."
  (and (consp field)
       (equal (consent--capability-grant-symbol-name (car field))
              name)))

(defun consent--capability-grant-field (grant name)
  "Return the first field named NAME in GRANT, or nil."
  (seq-find
   (lambda (field)
     (consent--capability-grant-field-named-p field name))
   (cdr-safe grant)))

(defun consent--capability-grant-field-value (grant name)
  "Return the single value of field NAME in GRANT, or nil."
  (cadr (consent--capability-grant-field grant name)))

(defun consent--capability-grant-field-values (grant name)
  "Return all values from field NAME in GRANT."
  (cdr (consent--capability-grant-field grant name)))

(defun consent--capability-grant-replace-field (grant name values)
  "Return GRANT with field NAME replaced by VALUES."
  (let ((seen nil)
        (name-symbol (consent--capability-grant-symbol name)))
    (append
     (list (car grant))
     (mapcar
      (lambda (field)
        (if (consent--capability-grant-field-named-p field name)
            (progn
              (setq seen t)
              (cons name-symbol values))
          field))
      (cdr grant))
     (unless seen
       (list (cons name-symbol values))))))

(defun consent--capability-grant-remove-fields (grant names)
  "Return GRANT without fields named by NAMES."
  (cons
   (car grant)
   (seq-remove
    (lambda (field)
      (member (consent--capability-grant-symbol-name (car-safe field))
              names))
    (cdr grant))))

(defun consent--capability-grant-datum-p (datum)
  "Return non-nil when DATUM is a capability-grant record."
  (and (consp datum)
       (equal (consent--capability-grant-symbol-name (car datum))
              "capability-grant")))

(defun consent--capability-grant-id-name (id)
  "Return ID as a stable capability grant id string."
  (or (consent--capability-grant-symbol-name id)
      (consent--eval-error
       "capability grant id must be a symbol or string")))

(defun consent--capability-generated-grant-id ()
  "Return a fresh generated capability grant id."
  (consent--capability-grant-symbol
   (format "g-%d" (cl-incf consent--next-capability-grant-number))))

(defun consent--capability-grant-expires-uses (expires)
  "Return the use count from EXPIRES, or nil."
  (when (and (consp expires)
             (equal (consent--capability-grant-symbol-name (car expires))
                    "uses"))
    (consent--capability-exact-integer
     (cadr expires) "capability grant uses")))

(defun consent--capability-grant-status (grant)
  "Return GRANT status as an Emacs symbol."
  (let ((field (consent--capability-grant-field grant "status")))
    (intern
     (or (and field
              (consent--capability-grant-symbol-name
               (cadr field)))
         "active"))))

(defun consent--capability-grant-normalize (datum)
  "Return DATUM as a normalized capability-grant record."
  (unless (consent--capability-grant-datum-p datum)
    (signal 'consent-capability-grant-error
            (list "grant-capability! expects a capability-grant datum")))
  (let* ((id (or (consent--capability-grant-field-value datum "id")
                 (consent--capability-generated-grant-id)))
         (domain (consent--capability-grant-field-value datum "domain"))
         (operations (consent--capability-grant-field-values
                      datum "operations"))
         (library (consent--capability-grant-field-value datum "library"))
         (effect (consent--capability-grant-field-value datum "effect"))
         (expires (or (consent--capability-grant-field-value
                       datum "expires")
                      (consent--capability-grant-symbol "never")))
         (uses (consent--capability-grant-expires-uses expires))
         (normalized
          (consent--capability-grant-remove-fields
           datum '("id" "status" "uses-remaining"))))
    (unless (or (and library effect)
                (and domain operations))
      (signal 'consent-capability-grant-error
              (list "capability grant requires either library/effect or domain/operations fields")))
    (setq normalized
          (consent--capability-grant-replace-field
           normalized "id" (list (consent--capability-grant-symbol id))))
    (setq normalized
          (consent--capability-grant-replace-field
           normalized "expires" (list expires)))
    (setq normalized
          (consent--capability-grant-replace-field
           normalized "status"
           (list (consent--capability-grant-symbol "active"))))
    (when uses
      (setq normalized
            (consent--capability-grant-replace-field
             normalized
             "uses-remaining"
             (list (consent--scheme-integer uses)))))
    normalized))

(defun consent--capability-context-grants (context)
  "Return capability grants carried by CONTEXT."
  (and context
       (consent--eval-context-p context)
       (consent--eval-context-capability-grants context)))

(defun consent--capability-set-context-grants (context grants)
  "Store GRANTS in CONTEXT."
  (when (and context (consent--eval-context-p context))
    (setf (consent--eval-context-capability-grants context) grants))
  grants)

(defun consent--capability-grant-id (grant)
  "Return GRANT's id datum."
  (consent--capability-grant-field-value grant "id"))

(defun consent--capability-grant-same-id-p (grant id)
  "Return non-nil when GRANT has ID."
  (equal (consent--capability-grant-id-name
          (consent--capability-grant-id grant))
         (consent--capability-grant-id-name id)))

(defun consent--capability-store-grant! (grant context)
  "Store GRANT in CONTEXT and return it."
  (let* ((id (consent--capability-grant-id grant))
         (grants
          (seq-remove
           (lambda (candidate)
             (consent--capability-grant-same-id-p candidate id))
           (consent--capability-context-grants context))))
    (consent--capability-set-context-grants
     context (append grants (list grant)))
    grant))

(defun consent--capability-grant-by-id (id context)
  "Return grant ID from CONTEXT, or nil."
  (seq-find
   (lambda (grant)
     (consent--capability-grant-same-id-p grant id))
   (consent--capability-context-grants context)))

(defun consent--capability-grant-active-p (grant)
  "Return non-nil when GRANT is currently active."
  (and grant
       (eq (consent--capability-grant-status grant) 'active)
       (let ((uses (consent--capability-grant-field-value
                    grant "uses-remaining")))
         (or (null uses)
             (> (consent--capability-exact-integer
                 uses "capability grant uses-remaining")
                0)))))

(defun consent--capability-current-grants (context)
  "Return active grants in CONTEXT."
  (seq-filter
   #'consent--capability-grant-active-p
   (consent--capability-context-grants context)))

(defun consent--capability-grant-audit-fields
    (operation grant decision &optional fields)
  "Return audit fields for OPERATION on GRANT with DECISION."
  (append
   `((category . capability-grant)
     (operation . ,operation)
     (id . ,(or (and grant (consent--capability-grant-id grant))
                consent-false))
     (decision . ,decision))
   (when grant
     `((library . ,(consent--capability-grant-field-value
                    grant "library"))
       (effect . ,(consent--capability-grant-field-value
                   grant "effect"))
       (domain . ,(consent--capability-grant-field-value
                   grant "domain"))
       (operations . ,(consent--capability-grant-field-values
                       grant "operations"))))
   fields))

(defun consent--capability-audit-grant
    (operation grant decision &optional fields)
  "Audit OPERATION on GRANT with DECISION."
  (consent-audit-record
   'capability-grant
   (consent--capability-grant-audit-fields
    operation grant decision fields)))

(defun consent--capability-grant-error
    (message grant &optional fields)
  "Audit a denied GRANT use and signal MESSAGE."
  (consent--capability-audit-grant
   "capability-grant-use" grant 'denied fields)
  (signal 'consent-capability-grant-error (list message)))

(defun consent--capability-grant-library-key (grant)
  "Return GRANT library key as external text."
  (when-let ((library (consent--capability-grant-field-value
                       grant "library")))
    (consent-datum->external library)))

(defun consent--capability-grant-effect-name (grant)
  "Return GRANT effect name."
  (consent--capability-grant-symbol-name
   (consent--capability-grant-field-value grant "effect")))

(defun consent--capability-grant-scope-clauses (grant)
  "Return scope clauses from GRANT."
  (consent--capability-grant-field-values grant "scope"))

(defun consent--capability-scope-clause (grant name)
  "Return GRANT scope clause named NAME, or nil."
  (seq-find
   (lambda (clause)
     (consent--capability-grant-field-named-p clause name))
   (consent--capability-grant-scope-clauses grant)))

(defun consent--capability-scope-value (grant name)
  "Return first value from GRANT scope clause NAME, or nil."
  (cadr (consent--capability-scope-clause grant name)))

(defun consent--capability-range-values (grant)
  "Return GRANT's range or region values as a two-element list."
  (let ((clause (or (consent--capability-scope-clause grant "range")
                    (consent--capability-scope-clause grant "region"))))
    (when clause
      (list
       (consent--capability-exact-integer
        (cadr clause) "capability grant range start")
       (consent--capability-exact-integer
        (caddr clause) "capability grant range end")))))

(defun consent--capability-operation-region (name arguments)
  "Return the buffer region touched by capability NAME with ARGUMENTS."
  (pcase name
    ("buffer-insert!"
     (let ((position (consent--capability-exact-integer
                      (cadr arguments) "buffer-insert! position")))
       (list position position)))
    ((or "buffer-delete!" "buffer-replace!")
     (list
      (consent--capability-exact-integer
       (cadr arguments) (format "%s start" name))
      (consent--capability-exact-integer
       (caddr arguments) (format "%s end" name))))
    (_ nil)))

(defun consent--capability-operation-buffer-handle (name arguments)
  "Return the buffer handle argument for capability NAME."
  (when (member name '("buffer-insert!" "buffer-delete!"
                      "buffer-replace!" "buffer-save!"
                      "buffer-switch!"))
    (car arguments)))

(defun consent--capability-operation-window-handle (name arguments)
  "Return the window handle argument for capability NAME."
  (when (member name '("window-select!" "window-delete!"))
    (car arguments)))

(defun consent--capability-operation-direction (name arguments)
  "Return the direction argument for capability NAME, or nil."
  (when (equal name "window-split!")
    (consent--capability-direction-name
     (car arguments) "window-split! direction")))

(defun consent--capability-same-handle-p (left right)
  "Return non-nil when LEFT and RIGHT name the same opaque handle."
  (and (consent-handle-p left)
       (consent-handle-p right)
       (eq (consent-handle-kind left)
           (consent-handle-kind right))
       (equal (consent-handle-id left)
              (consent-handle-id right))))

(defun consent--capability-check-grant-handle-live (grant handle)
  "Signal if GRANT is scoped to stale HANDLE."
  (when (and (consent-handle-p handle)
             (not (consent-capability-handle-live-p handle)))
    (consent--capability-grant-error
     (format "stale capability grant handle: %s"
             (consent-handle-id handle))
     grant
     `((grant-handle . ,handle)))))

(defun consent--capability-file-in-project-p (file root)
  "Return non-nil when FILE is under project ROOT."
  (and file
       root
       (file-in-directory-p
        (expand-file-name file)
        (file-name-as-directory (expand-file-name root)))))

(defun consent--file-capability-symbol-name (value)
  "Return VALUE as a file capability symbol name, or nil."
  (consent--capability-grant-symbol-name value))

(defun consent--file-capability-operation-symbol (operation)
  "Return OPERATION as an Consent Scheme symbol datum."
  (consent--capability-grant-symbol operation))

(defun consent--file-capability-effect-symbol (operation)
  "Return the effect class for file OPERATION."
  (consent--capability-grant-symbol
   (if (member (consent--file-capability-symbol-name operation)
               '("write" "create" "delete"))
       "host-file-mutation"
     "read-only-observation")))

(defun consent--file-capability-request-id ()
  "Return a fresh file capability request id."
  (consent--capability-grant-symbol
   (format "req-file-%d"
           (cl-incf consent--next-file-capability-request-number))))

(defun consent--file-capability-decision-id ()
  "Return a fresh file capability decision id."
  (consent--capability-grant-symbol
   (format "dec-file-%d"
           (cl-incf consent--next-file-capability-decision-number))))

(defun consent--capability-revocation-id ()
  "Return a fresh capability revocation id."
  (consent--capability-grant-symbol
   (format "rev-%d"
           (cl-incf consent--next-capability-revocation-number))))

(defun consent--code-loading-request-id ()
  "Return a fresh code-loading capability request id."
  (consent--capability-grant-symbol
   (format "req-code-loading-%d"
           (cl-incf consent--next-code-loading-request-number))))

(defun consent--code-loading-decision-id ()
  "Return a fresh code-loading capability decision id."
  (consent--capability-grant-symbol
   (format "dec-code-loading-%d"
           (cl-incf consent--next-code-loading-decision-number))))

(defun consent--process-capability-request-id ()
  "Return a fresh process capability request id."
  (consent--capability-grant-symbol
   (format "req-process-%d"
           (cl-incf consent--next-process-capability-request-number))))

(defun consent--process-capability-decision-id ()
  "Return a fresh process capability decision id."
  (consent--capability-grant-symbol
   (format "dec-process-%d"
           (cl-incf consent--next-process-capability-decision-number))))

(defun consent--process-port-capability-handle-id ()
  "Return a fresh process-backed port capability handle id."
  (consent--capability-grant-symbol
   (format "p-process-%d"
           (cl-incf consent--next-process-port-capability-handle-number))))

(defun consent--network-capability-request-id ()
  "Return a fresh network capability request id."
  (consent--capability-grant-symbol
   (format "req-network-%d"
           (cl-incf consent--next-network-capability-request-number))))

(defun consent--network-capability-decision-id ()
  "Return a fresh network capability decision id."
  (consent--capability-grant-symbol
   (format "dec-network-%d"
           (cl-incf consent--next-network-capability-decision-number))))

(defun consent--clock-capability-request-id ()
  "Return a fresh clock capability request id."
  (consent--capability-grant-symbol
   (format "req-clock-%d"
           (cl-incf consent--next-clock-capability-request-number))))

(defun consent--clock-capability-decision-id ()
  "Return a fresh clock capability decision id."
  (consent--capability-grant-symbol
   (format "dec-clock-%d"
           (cl-incf consent--next-clock-capability-decision-number))))

(defun consent--network-stream-handle-id ()
  "Return a fresh network stream handle id."
  (format "h-network-%d"
          (cl-incf consent--next-network-stream-handle-number)))

(defun consent--network-port-capability-handle-id ()
  "Return a fresh network-backed port capability handle id."
  (consent--capability-grant-symbol
   (format "p-network-%d"
           (cl-incf consent--next-network-port-capability-handle-number))))

(defun consent--file-capability-remote-path-p (filename path)
  "Return non-nil when FILENAME or PATH names non-local file authority."
  (or (and (stringp filename)
           (or (file-remote-p filename)
               (string-match-p "\\`[[:alpha:]][[:alnum:].+-]*://" filename)))
      (and (stringp path)
           (file-remote-p path))))

(defun consent--file-capability-existing-truename (path)
  "Return PATH with symlinks resolved when the target exists."
  (if (file-exists-p path)
      (file-truename path)
    (consent--file-capability-parent-truename path)))

(defun consent--file-capability-parent-truename (path)
  "Return PATH with existing parent directories canonicalized.
The final path component is not resolved, so a symlink inside an
approved root still counts as syntactically inside that root before
the separate resolved-target check runs."
  (let ((directory (file-name-directory path))
        (leaf (file-name-nondirectory path)))
    (if (and directory (file-directory-p directory))
        (expand-file-name leaf (file-truename directory))
      (expand-file-name path))))

(defun consent--file-capability-directory-root-p (path)
  "Return non-nil when PATH should be treated as an allowed directory root."
  (or (file-directory-p path)
      (string-suffix-p "/" path)))

(defun consent--file-capability-contained-p (path allowed)
  "Return non-nil when PATH is exactly ALLOWED or inside ALLOWED."
  (let ((path* (directory-file-name (expand-file-name path)))
        (allowed* (directory-file-name (expand-file-name allowed))))
    (or (equal path* allowed*)
        (and (consent--file-capability-directory-root-p allowed)
             (string-prefix-p
              (file-name-as-directory allowed*)
              path*)))))

(defun consent--file-capability-field-values-list (values)
  "Return VALUES as a flattened Scheme field value list."
  (if (and (= (length values) 1)
           (listp (car values))
           (not (consent-symbol-p (car values))))
      (car values)
    values))

(defun consent--file-capability-scope-values (grant name)
  "Return flattened scope values named NAME from GRANT."
  (consent--file-capability-field-values-list
   (cdr (consent--capability-scope-clause grant name))))

(defun consent--file-capability-grant-domain-p (grant)
  "Return non-nil when GRANT is a file-domain grant."
  (equal (consent--file-capability-symbol-name
          (consent--capability-grant-field-value grant "domain"))
         "file"))

(defun consent--file-capability-operation-p (grant operation)
  "Return non-nil when GRANT allows OPERATION."
  (let ((operation-name
         (consent--file-capability-symbol-name operation)))
    (cl-some
     (lambda (candidate)
       (equal (consent--file-capability-symbol-name candidate)
              operation-name))
     (consent--capability-grant-field-values grant "operations"))))

(defun consent--file-capability-grants (context)
  "Return file-domain grants carried by CONTEXT."
  (seq-filter
   #'consent--file-capability-grant-domain-p
   (consent--capability-context-grants context)))

(defun consent--file-capability-legacy-grants
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

(defun consent--file-capability-path-roots (grant context)
  "Return absolute allowed roots described by GRANT."
  (let* ((project-root
          (consent--capability-scope-value grant "project-root"))
         (file-root
          (consent--capability-scope-value grant "file-root"))
         (base-root
          (or project-root
              file-root
              (and context
                   (consent--eval-context-p context)
                   (consent--eval-context-include-directory context))
              default-directory))
         (base-directory
          (file-name-as-directory (expand-file-name base-root)))
         (paths
          (or (consent--file-capability-scope-values grant "paths")
              '("."))))
    (mapcar
     (lambda (path)
       (if (file-name-absolute-p path)
           (expand-file-name path)
         (expand-file-name path base-directory)))
     paths)))

(defun consent--file-capability-grant-match
    (grant path resolved-path operation context)
  "Return a match plist when GRANT authorizes PATH for OPERATION."
  (cond
   ((not (consent--file-capability-operation-p grant operation))
    nil)
   ((eq (consent--capability-grant-status grant) 'revoked)
    (list :denied grant :reason "revoked file capability grant"))
   ((not (consent--capability-grant-active-p grant))
    (list :denied grant :reason "expired file capability grant"))
   (t
    (let ((outside-reason "path is outside approved file grant root")
          symlink-denial)
      (catch 'matched
        (dolist (allowed (consent--file-capability-path-roots grant context))
          (let* ((syntactic-path
                  (consent--file-capability-parent-truename path))
                 (resolved-allowed
                  (consent--file-capability-existing-truename allowed))
                 (syntactic-allowed resolved-allowed)
                 (syntactic-match
                  (consent--file-capability-contained-p
                   syntactic-path syntactic-allowed))
                 (resolved-match
                  (consent--file-capability-contained-p
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

(defun consent--file-capability-request-datum
    (request-id filename path operation binding)
  "Return a Scheme-readable file capability request datum."
  `(,(consent--capability-grant-symbol "capability-request")
    (,(consent--capability-grant-symbol "id") ,request-id)
    (,(consent--capability-grant-symbol "session")
     ,(or nil consent-false))
    (,(consent--capability-grant-symbol "library")
     (,(consent--capability-grant-symbol "scheme")
      ,(consent--capability-grant-symbol
        (if (member (consent--file-capability-symbol-name operation)
                    '("include" "include-ci" "library-source"))
            "base"
          (if (equal (consent--file-capability-symbol-name operation)
                     "load")
              "load"
            "file")))))
    (,(consent--capability-grant-symbol "binding") ,binding)
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "file"))
    (,(consent--capability-grant-symbol "operation")
     ,(consent--file-capability-operation-symbol operation))
    (,(consent--capability-grant-symbol "resource")
     (,(consent--capability-grant-symbol "path") ,filename)
     (,(consent--capability-grant-symbol "normalized-path") ,path))
    (,(consent--capability-grant-symbol "effect")
     ,(consent--file-capability-effect-symbol operation))))

(defun consent--file-capability-record-request
    (request operation filename path)
  "Audit file capability REQUEST."
  (consent-audit-record
   'capability-request
   `((request . ,request)
     (domain . file)
     (operation . ,operation)
     (path . ,filename)
     (normalized-path . ,path))))

(defun consent--file-capability-record-decision
    (request request-id status grant reason &optional fields)
  "Audit and return a file capability decision datum."
  (let* ((decision-id (consent--file-capability-decision-id))
         (grant-id (or (and grant (consent--capability-grant-id grant))
                       (consent--capability-grant-symbol "none")))
         (decision
          `(,(consent--capability-grant-symbol "capability-decision")
            (,(consent--capability-grant-symbol "id") ,decision-id)
            (,(consent--capability-grant-symbol "request") ,request-id)
            (,(consent--capability-grant-symbol "status")
             ,(consent--capability-grant-symbol status))
            (,(consent--capability-grant-symbol "grant") ,grant-id)
            (,(consent--capability-grant-symbol "reason") ,reason))))
    (consent-audit-record
     'capability-decision
     (append
      `((request . ,request)
        (decision . ,decision)
        (status . ,status)
        (grant . ,grant-id)
        (reason . ,reason))
      fields))
    decision))

(defun consent-capability-audit-file-result
    (authorization result &optional errored)
  "Audit file capability AUTHORIZATION with RESULT.
When ERRORED is non-nil, RESULT is recorded as an error payload."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (consent-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . file)
       (operation . ,operation)
       (result . ,(if errored
                    (list 'error result)
                  (list 'ok result)))))))

(defun consent--file-capability-handle-datum
    (handle path resolved-path grant-id status)
  "Return a Scheme-readable file HANDLE datum."
  `(,(consent--capability-grant-symbol "handle")
    (,(consent--capability-grant-symbol "id")
     ,(consent-handle-id handle))
    (,(consent--capability-grant-symbol "kind")
     ,(consent--capability-grant-symbol "file"))
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "file"))
    (,(consent--capability-grant-symbol "path") ,path)
    (,(consent--capability-grant-symbol "resolved-path")
     ,resolved-path)
    (,(consent--capability-grant-symbol "grant") ,grant-id)
    (,(consent--capability-grant-symbol "status")
     ,(consent--capability-grant-symbol status))))

(defun consent--file-capability-register-handle
    (path resolved-path grant operation)
  "Register and audit a file handle for an approved file request."
  (let* ((grant-id (consent--capability-grant-id grant))
         (handle
          (consent--register-handle
           'file
           (list :path path
                 :resolved-path resolved-path
                 :grant grant-id
                 :operation operation
                 :status 'live)))
         (handle-datum
          (consent--file-capability-handle-datum
           handle path resolved-path grant-id 'live)))
    (consent-audit-record
     'capability-handle
     `((handle . ,handle-datum)
       (domain . file)
       (kind . file)
       (path . ,path)
       (resolved-path . ,resolved-path)
       (grant . ,grant-id)
       (status . live)))
    handle))

(defun consent-capability-revalidate-file-authorization
    (authorization)
  "Fail closed unless AUTHORIZATION still has a live file handle and grant."
  (let ((handle (plist-get authorization :handle))
        (grant (plist-get authorization :grant)))
    (unless (and handle
                 (consent-capability-handle-live-p handle))
      (signal 'consent-capability-grant-error
              (list "stale file capability handle")))
    (unless (and grant
                 (consent--capability-grant-active-p grant))
      (signal 'consent-capability-grant-error
              (list "inactive file capability grant")))
    authorization))

(defun consent--port-capability-handle-id ()
  "Return a fresh port capability handle id."
  (consent--capability-grant-symbol
   (format "p-file-%d"
           (cl-incf consent--next-port-capability-handle-number))))

(defun consent--port-capability-datum
    (handle-id kind backing operations grant limits status path)
  "Return a Scheme-readable port capability datum."
  `(,(consent--capability-grant-symbol "port-capability")
    (,(consent--capability-grant-symbol "id") ,handle-id)
    (,(consent--capability-grant-symbol "kind")
     ,(consent--capability-grant-symbol kind))
    (,(consent--capability-grant-symbol "backing")
     ,(consent--capability-grant-symbol backing))
    (,(consent--capability-grant-symbol "operations")
     ,@operations)
    (,(consent--capability-grant-symbol "grant") ,grant)
    (,(consent--capability-grant-symbol "limits") ,@limits)
    (,(consent--capability-grant-symbol "path") ,path)
    (,(consent--capability-grant-symbol "status")
     ,(consent--capability-grant-symbol status))))

(defun consent--port-capability-limits (grant)
  "Return port limits inherited from GRANT, or nil."
  (consent--capability-grant-field-values grant "limits"))

(defun consent-capability-register-file-port
    (port kind authorization operations)
  "Attach a port capability handle to PORT and audit its creation.
AUTHORIZATION is the approved file authorization that created PORT."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (consent--capability-grant-id grant))
         (path (plist-get authorization :path))
         (limits (consent--port-capability-limits grant))
         (handle-id (consent--port-capability-handle-id))
         (handle
          (consent--port-capability-datum
           handle-id kind 'file operations grant-id limits 'open path)))
    (setf (consent--port-backing-domain port) 'file)
    (setf (consent--port-operations port) operations)
    (setf (consent--port-grant port) grant-id)
    (setf (consent--port-limits port) limits)
    (setf (consent--port-handle port) handle-id)
    (setf (consent--port-status port) 'open)
    (setf (consent--port-path port) path)
    (setf (consent--port-counters port) nil)
    (consent-audit-record
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

(defun consent-capability-audit-port-result
    (port operation result &optional errored)
  "Audit host-backed PORT capability OPERATION with RESULT."
  (when (and port (consent--port-backing-domain port))
    (consent-audit-record
     'capability-audit
     `((domain . port)
       (operation . ,operation)
       (handle . ,(consent--port-handle port))
       (backing . ,(consent--port-backing-domain port))
       (grant . ,(consent--port-grant port))
       (path . ,(consent--port-path port))
       (result . ,(if errored
                      (list 'error result)
                    (list 'ok result)))))))

(defun consent--port-capability-limit-name (operation)
  "Return the limit field name for port OPERATION, or nil."
  (pcase operation
    ('read "reads")
    ('write "writes")
    ('flush "flushes")
    ('close "closes")
    (_ nil)))

(defun consent--port-capability-limit-value (port name)
  "Return PORT limit NAME as a host integer, or nil."
  (when name
    (when-let ((field
                (seq-find
                 (lambda (entry)
                   (and (consp entry)
                        (equal
                         (consent--capability-grant-symbol-name
                          (car entry))
                         name)))
                 (consent--port-limits port))))
      (consent--capability-exact-integer
       (cadr field)
       (format "port capability limit %s" name)))))

(defun consent--port-capability-counter (port name)
  "Return PORT operation counter NAME."
  (or (cdr (assoc name (consent--port-counters port))) 0))

(defun consent--port-capability-set-counter! (port name value)
  "Set PORT operation counter NAME to VALUE."
  (let ((counters (assq-delete-all name (consent--port-counters port))))
    (setf (consent--port-counters port)
          (cons (cons name value) counters))))

(defun consent--process-port-live-p (port)
  "Return non-nil when PORT's owning process handle is still live."
  (let ((id (consent--port-path port)))
    (and (stringp id)
         (let ((entry (gethash id consent--handle-registry)))
           (and entry
                (eq (consent--handle-entry-kind entry) 'process)
                (consent-capability--entry-live-p entry))))))

(defun consent--port-capability-check-limit! (port operation)
  "Consume one PORT operation limit unit for OPERATION."
  (let* ((name (consent--port-capability-limit-name operation))
         (limit (consent--port-capability-limit-value port name)))
    (when limit
      (let ((used (consent--port-capability-counter port name)))
        (when (>= used limit)
          (let ((reason (format "port capability limit exceeded: %s" name)))
            (consent-capability-audit-port-result
             port operation reason t)
            (signal 'consent-capability-grant-error (list reason))))
        (consent--port-capability-set-counter! port name (1+ used))))))

(defun consent-capability-revalidate-port-operation
    (port context operation)
  "Fail closed unless PORT can perform OPERATION in CONTEXT."
  (when (consent--port-backing-domain port)
    (cond
     ((not (consent--port-openp port))
      (consent-capability-audit-port-result
       port operation "closed port capability handle" t)
      (signal 'consent-capability-grant-error
              (list "stale port capability handle: closed port")))
     ((not (member operation (consent--port-operations port)))
      (consent-capability-audit-port-result
       port operation "operation outside port capability" t)
      (signal 'consent-capability-grant-error
              (list "operation outside port capability")))
     ((and (eq (consent--port-backing-domain port) 'process)
           (not (consent--process-port-live-p port)))
      (consent-capability-audit-port-result
       port operation "stale process port handle" t)
      (signal 'consent-capability-grant-error
              (list "stale port capability handle: process is not live")))
     ((and (eq (consent--port-backing-domain port) 'network)
           (not (consent--network-stream-live-p
                 (consent--port-path port))))
      (consent-capability-audit-port-result
       port operation "stale network stream handle" t)
      (signal 'consent-capability-grant-error
              (list "stale port capability handle: network stream is not live")))
     ((and (eq (consent--port-backing-domain port) 'network)
           (eq operation 'close))
      (consent--port-capability-check-limit! port operation))
     (t
      (let* ((grant-id (consent--port-grant port))
             (grant
              (and grant-id
                   (consent--capability-grant-by-id
                    grant-id context))))
          (unless (and grant
                     (consent--capability-grant-active-p grant))
          (consent-capability-audit-port-result
           port operation "inactive port capability grant" t)
          (signal 'consent-capability-grant-error
                  (list "stale port capability handle: inactive grant")))
        (consent--port-capability-check-limit! port operation)))))
  port)

(defun consent--code-loading-request-datum
    (request-id file-authorization binding)
  "Return a Scheme-readable code-loading request datum."
  (let ((path (plist-get file-authorization :path))
        (file-request (plist-get file-authorization :request)))
    `(,(consent--capability-grant-symbol "capability-request")
      (,(consent--capability-grant-symbol "id") ,request-id)
      (,(consent--capability-grant-symbol "library")
       (,(consent--capability-grant-symbol "scheme")
        ,(consent--capability-grant-symbol "load")))
      (,(consent--capability-grant-symbol "binding") ,binding)
      (,(consent--capability-grant-symbol "domain")
       ,(consent--capability-grant-symbol "code-loading"))
      (,(consent--capability-grant-symbol "operation")
       ,(consent--capability-grant-symbol "load"))
      (,(consent--capability-grant-symbol "resource")
       (,(consent--capability-grant-symbol "path") ,path)
       (,(consent--capability-grant-symbol "file-request")
        ,file-request))
      (,(consent--capability-grant-symbol "effect")
       ,(consent--capability-grant-symbol "environment-mutation")))))

(defun consent--code-loading-record-request
    (request binding path)
  "Audit code-loading capability REQUEST."
  (consent-audit-record
   'capability-request
   `((request . ,request)
     (domain . code-loading)
     (operation . load)
     (binding . ,binding)
     (path . ,path))))

(defun consent--code-loading-record-decision
    (request request-id status reason &optional fields)
  "Audit and return a code-loading capability decision datum."
  (let* ((decision-id (consent--code-loading-decision-id))
         (decision
          `(,(consent--capability-grant-symbol "capability-decision")
            (,(consent--capability-grant-symbol "id") ,decision-id)
            (,(consent--capability-grant-symbol "request") ,request-id)
            (,(consent--capability-grant-symbol "status")
             ,(consent--capability-grant-symbol status))
            (,(consent--capability-grant-symbol "domain")
             ,(consent--capability-grant-symbol "code-loading"))
            (,(consent--capability-grant-symbol "reason") ,reason))))
    (consent-audit-record
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

(defun consent-capability-audit-code-loading-result
    (authorization result &optional errored)
  "Audit code-loading AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision)))
    (consent-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . code-loading)
       (operation . load)
       (result . ,(if errored
                    (list 'error result)
                  (list 'ok result)))))))

(defun consent--clock-capability-operation-symbol (operation)
  "Return OPERATION as an Consent Scheme symbol datum."
  (consent--capability-grant-symbol operation))

(defun consent--clock-capability-operation-name (operation)
  "Return OPERATION as a stable string."
  (consent--capability-grant-symbol-name operation))

(defun consent--clock-capability-grant-p (grant)
  "Return non-nil when GRANT is a clock-domain grant."
  (and (consent--capability-grant-datum-p grant)
       (equal (consent--capability-grant-symbol-name
               (consent--capability-grant-field-value grant "domain"))
              "clock")))

(defun consent--clock-capability-grants (context)
  "Return active clock-domain grants carried by CONTEXT."
  (seq-filter
   #'consent--clock-capability-grant-p
   (consent--capability-context-grants context)))

(defun consent--clock-capability-operation-p (grant operation)
  "Return non-nil when GRANT authorizes clock OPERATION."
  (let ((operation-name (consent--clock-capability-operation-name operation)))
    (cl-some
     (lambda (candidate)
       (let ((candidate-name
              (consent--capability-grant-symbol-name candidate)))
         (or (equal candidate-name operation-name)
             (equal candidate-name "read"))))
     (consent--capability-grant-field-values grant "operations"))))

(defun consent--clock-capability-match (grants operation)
  "Return a grant match plist for clock OPERATION."
  (let (denied)
    (catch 'matched
      (dolist (grant grants)
        (cond
         ((not (consent--clock-capability-operation-p grant operation)))
         ((eq (consent--capability-grant-status grant) 'revoked)
          (setq denied
                (list :denied grant
                      :reason "revoked clock capability grant")))
         ((not (consent--capability-grant-active-p grant))
          (setq denied
                (list :denied grant
                      :reason "expired clock capability grant")))
         (t
          (throw 'matched (list :grant grant)))))
      denied)))

(defun consent--clock-capability-request-datum
    (request-id binding operation)
  "Return a Scheme-readable clock capability request datum."
  `(,(consent--capability-grant-symbol "capability-request")
    (,(consent--capability-grant-symbol "id") ,request-id)
    (,(consent--capability-grant-symbol "session") ,consent-false)
    (,(consent--capability-grant-symbol "library")
     (,(consent--capability-grant-symbol "scheme")
      ,(consent--capability-grant-symbol "time")))
    (,(consent--capability-grant-symbol "binding")
     ,(consent--clock-capability-operation-symbol binding))
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "clock"))
    (,(consent--capability-grant-symbol "operation")
     ,(consent--clock-capability-operation-symbol operation))
    (,(consent--capability-grant-symbol "resource")
     (,(consent--capability-grant-symbol "clock")
      ,(consent--capability-grant-symbol "system")))
    (,(consent--capability-grant-symbol "effect")
     ,(consent--capability-grant-symbol "read-only-observation"))))

(defun consent--clock-capability-record-request
    (request operation binding)
  "Audit clock capability REQUEST."
  (consent-audit-record
   'capability-request
   `((request . ,request)
     (domain . clock)
     (operation . ,(consent--clock-capability-operation-symbol operation))
     (binding . ,(consent--clock-capability-operation-symbol binding)))))

(defun consent--clock-capability-record-decision
    (request request-id operation status grant reason)
  "Audit and return a clock capability decision datum."
  (let* ((decision-id (consent--clock-capability-decision-id))
         (grant-id (or (and grant (consent--capability-grant-id grant))
                       (consent--capability-grant-symbol "none")))
         (decision
          `(,(consent--capability-grant-symbol "capability-decision")
            (,(consent--capability-grant-symbol "id") ,decision-id)
            (,(consent--capability-grant-symbol "request") ,request-id)
            (,(consent--capability-grant-symbol "status")
             ,(consent--capability-grant-symbol status))
            (,(consent--capability-grant-symbol "domain")
             ,(consent--capability-grant-symbol "clock"))
            (,(consent--capability-grant-symbol "grant") ,grant-id)
            (,(consent--capability-grant-symbol "reason") ,reason))))
    (consent-audit-record
     'capability-decision
     `((request . ,request)
       (decision . ,decision)
       (domain . clock)
       (operation . ,(consent--clock-capability-operation-symbol operation))
       (status . ,status)
       (grant . ,grant-id)
       (reason . ,reason)))
    decision))

(defun consent-capability-audit-clock-result
    (authorization result &optional errored)
  "Audit clock capability AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (consent-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . clock)
       (operation . ,(consent--clock-capability-operation-symbol operation))
       (result . ,(if errored
                    (list 'error result)
                  (list 'ok result)))))))

(defun consent--clock-capability-deny
    (request request-id operation binding grant reason context)
  "Record a denied clock capability REQUEST and signal REASON."
  (let ((decision
         (consent--clock-capability-record-decision
          request request-id operation 'denied grant reason)))
    (consent-capability-audit-clock-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (consent-policy-deny
     'standard-host-effect
     (consent--clock-capability-operation-name binding)
     `((domain . clock)
       (operation . ,(consent--clock-capability-operation-symbol operation)))
     context
     reason)))

(defun consent-capability-authorize-clock
    (binding context &optional operation)
  "Authorize a `(scheme time)` clock read for BINDING.
OPERATION defaults to BINDING and may be a symbol or string."
  (let* ((operation (or operation binding))
         (request-id (consent--clock-capability-request-id))
         (request
          (consent--clock-capability-request-datum
           request-id binding operation))
         (grants (consent--clock-capability-grants context)))
    (consent--clock-capability-record-request
     request operation binding)
    (unless grants
      (consent--clock-capability-deny
       request request-id operation binding nil
       "no active clock grant covers request"
       context))
    (let ((match (consent--clock-capability-match grants operation)))
      (unless (and match (plist-get match :grant))
        (consent--clock-capability-deny
         request request-id operation binding
         (plist-get match :denied)
         (or (plist-get match :reason)
             "no active clock grant covers request")
         context))
      (let ((grant (plist-get match :grant)))
        (consent-policy-authorize
         'standard-host-effect
         (consent--clock-capability-operation-name binding)
         `((domain . clock)
           (operation . ,(consent--clock-capability-operation-symbol operation))
           (grant . ,(consent--capability-grant-id grant)))
         context)
        (consent--capability-grant-use! grant context)
        (let ((decision
               (consent--clock-capability-record-decision
                request request-id operation 'approved grant
                "clock read is covered by active grant")))
          (list :request request
                :decision decision
                :operation operation
                :grant grant))))))

(defun consent-capability-authorize-code-loading
    (file-authorization context binding)
  "Authorize loading code read by FILE-AUTHORIZATION."
  (let* ((path (plist-get file-authorization :path))
         (request-id (consent--code-loading-request-id))
         (request
          (consent--code-loading-request-datum
           request-id file-authorization binding)))
    (consent--code-loading-record-request request binding path)
    (condition-case condition
        (progn
          (consent-policy-authorize
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
                (consent--code-loading-record-decision
                 request request-id 'approved
                 "load target is authorized under current evaluation context"
                 `((path . ,path)))))
      (consent-policy-error
       (let ((decision
              (consent--code-loading-record-decision
               request request-id 'denied
               (error-message-string condition)
               `((path . ,path)))))
         (consent-capability-audit-code-loading-result
          (list :request request :decision decision)
          (error-message-string condition)
          t)
         (signal (car condition) (cdr condition)))))))

(defun consent--process-capability-operation-symbol (operation)
  "Return OPERATION as an Consent Scheme symbol datum."
  (consent--capability-grant-symbol operation))

(defun consent--process-capability-effect-symbol (operation)
  "Return the effect class for process OPERATION."
  (consent--capability-grant-symbol
   (if (member (consent--capability-grant-symbol-name operation)
               '("spawn" "input" "interrupt" "terminate"))
       "process-control"
     "read-only-observation")))

(defun consent--process-capability-policy-category (operation)
  "Return policy category for process OPERATION."
  (if (member (consent--capability-grant-symbol-name operation)
              '("spawn" "input" "interrupt" "terminate"))
      'command-process
    'emacs-read-only))

(defun consent--process-capability-grant-domain-p (grant)
  "Return non-nil when GRANT is a process-domain grant."
  (equal (consent--capability-grant-symbol-name
          (consent--capability-grant-field-value grant "domain"))
         "process"))

(defun consent--process-capability-operation-p (grant operation)
  "Return non-nil when GRANT allows process OPERATION."
  (let ((operation-name
         (consent--capability-grant-symbol-name operation)))
    (cl-some
     (lambda (candidate)
       (equal (consent--capability-grant-symbol-name candidate)
              operation-name))
     (consent--file-capability-field-values-list
      (consent--capability-grant-field-values grant "operations")))))

(defun consent--process-capability-grants (context)
  "Return process-domain grants carried by CONTEXT."
  (seq-filter
   #'consent--process-capability-grant-domain-p
   (consent--capability-context-grants context)))

(defun consent--process-command-allowlist-entry (command)
  "Return non-nil when COMMAND is allowed for process creation."
  (seq-find
   (lambda (entry)
     (equal command (consent--capability-grant-symbol-name entry)))
   consent-process-command-allowlist))

(defun consent--process-option-field (options name)
  "Return process OPTIONS field named NAME, or nil."
  (seq-find
   (lambda (field)
     (consent--capability-grant-field-named-p field name))
   (consent--proper-list-elements options "process options")))

(defun consent--process-option-value (options name)
  "Return process OPTIONS field NAME's first value, or nil."
  (cadr (consent--process-option-field options name)))

(defun consent--process-cwd (options)
  "Return the process working directory described by OPTIONS."
  (let ((cwd (consent--process-option-value options "cwd")))
    (if cwd
        (file-name-as-directory
         (expand-file-name
          (consent--capability-string cwd "process cwd")))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun consent--process-string-list (datum description)
  "Return DATUM as a proper list of strings for DESCRIPTION."
  (mapcar
   (lambda (entry)
     (consent--capability-string entry description))
   (consent--proper-list-elements datum description)))

(defun consent--process-normalized-arguments (arguments)
  "Return process ARGUMENTS as host strings."
  (consent--process-string-list arguments "process arguments"))

(defun consent--process-environment-name (datum description)
  "Return DATUM as a process environment variable name."
  (or (consent--capability-grant-symbol-name datum)
      (consent--eval-error
       "%s expected an environment variable name, got %s"
       description
       (consent-value->external datum))))

(defun consent--process-environment-entry (entry description)
  "Return process environment ENTRY as a two-string list."
  (let ((elements (consent--proper-list-elements entry description)))
    (unless (= (length elements) 2)
      (consent--eval-error
       "%s expected environment entries as (name value)" description))
    (list (consent--process-environment-name (car elements) description)
          (consent--capability-string (cadr elements) description))))

(defun consent--process-normalized-environment (options)
  "Return process OPTIONS environment entries as (NAME VALUE) lists."
  (when-let ((environment
              (consent--process-option-value options "environment")))
    (mapcar
     (lambda (entry)
       (consent--process-environment-entry
        entry "process environment"))
     (consent--proper-list-elements
      environment "process environment"))))

(defun consent--process-environment-names (environment)
  "Return variable names from normalized process ENVIRONMENT."
  (mapcar #'car environment))

(defun consent--process-scope-command (grant)
  "Return GRANT's process command scope, or nil."
  (when-let ((command (consent--capability-scope-value grant "command")))
    (consent--capability-string command "process grant command")))

(defun consent--process-scope-cwd (grant)
  "Return GRANT's working-directory scope, or nil."
  (when-let ((cwd (or (consent--capability-scope-value
                      grant "working-directory")
                     (consent--capability-scope-value grant "cwd"))))
    (file-name-as-directory
     (expand-file-name
      (consent--capability-string cwd "process grant working directory")))))

(defun consent--process-scope-arguments (grant)
  "Return GRANT's argument scope, or nil."
  (when-let ((clause (consent--capability-scope-clause grant "arguments")))
    (consent--file-capability-field-values-list (cdr clause))))

(defun consent--process-scope-environment-name (datum)
  "Return DATUM's process environment variable name."
  (if (and (consp datum) (not (consent-symbol-p datum)))
      (consent--process-environment-name
       (car datum) "process grant environment")
    (consent--process-environment-name
     datum "process grant environment")))

(defun consent--process-scope-environment (grant)
  "Return GRANT's allowed process environment names, or nil."
  (when-let ((clause (consent--capability-scope-clause grant "environment")))
    (mapcar
     #'consent--process-scope-environment-name
     (consent--file-capability-field-values-list (cdr clause)))))

(defun consent--process-scope-handle (grant)
  "Return GRANT's process handle scope, or nil."
  (or (consent--capability-scope-value grant "handle")
      (consent--capability-scope-value grant "process")))

(defun consent--process-resource-handle (resource)
  "Return process handle from RESOURCE plist, or nil."
  (plist-get resource :handle))

(defun consent--process-resource-command (resource)
  "Return process command from RESOURCE plist, or nil."
  (plist-get resource :command))

(defun consent--process-resource-arguments (resource)
  "Return process arguments from RESOURCE plist, or nil."
  (plist-get resource :arguments))

(defun consent--process-resource-cwd (resource)
  "Return process cwd from RESOURCE plist, or nil."
  (plist-get resource :cwd))

(defun consent--process-resource-environment (resource)
  "Return process environment from RESOURCE plist, or nil."
  (plist-get resource :environment))

(defun consent--process-capability-grant-match
    (grant operation resource)
  "Return a match plist when GRANT authorizes process OPERATION."
  (cond
   ((not (consent--process-capability-operation-p grant operation))
    nil)
   ((eq (consent--capability-grant-status grant) 'revoked)
    (list :denied grant :reason "revoked process capability grant"))
   ((not (consent--capability-grant-active-p grant))
    (list :denied grant :reason "expired process capability grant"))
   (t
    (let ((scope-command (consent--process-scope-command grant))
          (scope-arguments (consent--process-scope-arguments grant))
          (scope-cwd (consent--process-scope-cwd grant))
          (scope-environment
           (consent--process-scope-environment grant))
          (scope-handle (consent--process-scope-handle grant))
          (command (consent--process-resource-command resource))
          (arguments (consent--process-resource-arguments resource))
          (cwd (consent--process-resource-cwd resource))
          (environment (consent--process-resource-environment resource))
          (handle (consent--process-resource-handle resource)))
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
              (consent--process-environment-names environment)
              scope-environment
              :test #'equal))
        (list :denied grant
              :reason "environment is outside approved process grant scope"))
       ((and scope-handle handle
             (not (consent--capability-same-handle-p
                   scope-handle handle)))
        (list :denied grant
              :reason "handle is outside approved process grant scope"))
       (t
        (list :grant grant)))))))

(defun consent--process-capability-request-datum
    (request-id binding operation resource)
  "Return a Scheme-readable process capability request datum."
  `(,(consent--capability-grant-symbol "capability-request")
    (,(consent--capability-grant-symbol "id") ,request-id)
    (,(consent--capability-grant-symbol "session")
     ,(or nil consent-false))
    (,(consent--capability-grant-symbol "library")
     (,(consent--capability-grant-symbol "emacs")
      ,(consent--capability-grant-symbol "process")))
    (,(consent--capability-grant-symbol "binding")
     ,(consent--capability-grant-symbol binding))
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "process"))
    (,(consent--capability-grant-symbol "operation")
     ,(consent--process-capability-operation-symbol operation))
    (,(consent--capability-grant-symbol "resource")
     ,@(when-let ((handle (consent--process-resource-handle resource)))
         `((,(consent--capability-grant-symbol "handle") ,handle)))
     ,@(when-let ((command (consent--process-resource-command resource)))
         `((,(consent--capability-grant-symbol "command") ,command)))
     ,@(when-let ((arguments
                   (consent--process-resource-arguments resource)))
         `((,(consent--capability-grant-symbol "arguments")
            ,arguments)))
     ,@(when-let ((cwd (consent--process-resource-cwd resource)))
         `((,(consent--capability-grant-symbol "cwd") ,cwd)))
     ,@(when-let ((environment
                   (consent--process-resource-environment resource)))
         `((,(consent--capability-grant-symbol "environment")
            ,environment)))
     ,@(when-let ((options (plist-get resource :options)))
         `((,(consent--capability-grant-symbol "options") ,options))))
    (,(consent--capability-grant-symbol "effect")
     ,(consent--process-capability-effect-symbol operation))))

(defun consent--process-capability-record-request
    (request operation resource)
  "Audit process capability REQUEST."
  (consent-audit-record
   'capability-request
   `((request . ,request)
     (domain . process)
     (operation . ,operation)
     (handle . ,(or (consent--process-resource-handle resource)
                    consent-false))
     (command . ,(or (consent--process-resource-command resource)
                     consent-false))
     (arguments . ,(or (consent--process-resource-arguments resource)
                       nil))
     (environment . ,(or (consent--process-resource-environment resource)
                         nil))
     (cwd . ,(or (consent--process-resource-cwd resource)
                 consent-false))
     (options . ,(or (plist-get resource :options) nil)))))

(defun consent--process-capability-record-decision
    (request request-id status grant reason &optional fields)
  "Audit and return a process capability decision datum."
  (let* ((decision-id (consent--process-capability-decision-id))
         (grant-id (or (and grant (consent--capability-grant-id grant))
                       (consent--capability-grant-symbol "none")))
         (decision
          `(,(consent--capability-grant-symbol "capability-decision")
            (,(consent--capability-grant-symbol "id") ,decision-id)
            (,(consent--capability-grant-symbol "request") ,request-id)
            (,(consent--capability-grant-symbol "status")
             ,(consent--capability-grant-symbol status))
            (,(consent--capability-grant-symbol "domain")
             ,(consent--capability-grant-symbol "process"))
            (,(consent--capability-grant-symbol "grant") ,grant-id)
            (,(consent--capability-grant-symbol "reason") ,reason))))
    (consent-audit-record
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

(defun consent-capability-audit-process-result
    (authorization result &optional errored)
  "Audit process capability AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (consent-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . process)
       (operation . ,operation)
       (result . ,(if errored
                      (list 'error result)
                    (list 'ok result)))))))

(defun consent--process-capability-deny
    (request request-id operation resource grant reason)
  "Record denied process REQUEST and signal REASON."
  (let ((decision
         (consent--process-capability-record-decision
          request request-id 'denied grant reason
          `((operation . ,operation)
            (handle . ,(or (consent--process-resource-handle resource)
                           consent-false))
            (command . ,(or (consent--process-resource-command resource)
                            consent-false))))))
    (consent-capability-audit-process-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (signal 'consent-capability-grant-error
            (list (format "process capability denied: %s" reason)))))

(defun consent--process-handle-live-p (handle)
  "Return non-nil when HANDLE names a live process registry entry."
  (and (consent-handle-p handle)
       (let ((entry (gethash (consent-handle-id handle)
                             consent--handle-registry)))
         (and entry
              (eq (consent--handle-entry-kind entry) 'process)
              (consent-capability--entry-live-p entry)))))

(defun consent--process-handle-object (handle)
  "Return the private object for process HANDLE, or nil."
  (when (consent-handle-p handle)
    (when-let ((entry (gethash (consent-handle-id handle)
                               consent--handle-registry)))
      (and (eq (consent--handle-entry-kind entry) 'process)
           (consent--handle-entry-object entry)))))

(defun consent--process-object-process (object)
  "Return live Emacs process inside OBJECT, or nil."
  (cond
   ((processp object) object)
   ((and (consp object) (plist-get object :process))
    (plist-get object :process))
   (t nil)))

(defun consent--process-object-live-p (object)
  "Return non-nil when process OBJECT is still live."
  (cond
   ((processp object)
    (process-live-p object))
   ((consent--process-object-process object)
    (process-live-p (consent--process-object-process object)))
   ((and (consp object) (plist-member object :status))
    (or (plist-get object :retain-after-exit)
        (not (memq (plist-get object :status)
                   '(closed deleted exit failed killed signal stale stopped)))))
   (t object)))

(defun consent--process-object-status (object)
  "Return Scheme-readable status symbol for process OBJECT."
  (cond
   ((consent--process-object-process object)
    (process-status (consent--process-object-process object)))
   ((and (consp object) (plist-get object :status))
    (plist-get object :status))
   (t 'run)))

(defun consent--process-object-name (object)
  "Return process OBJECT's public name."
  (cond
   ((processp object) (process-name object))
   ((and (consp object) (plist-get object :name))
    (plist-get object :name))
   ((consent--process-object-process object)
    (process-name (consent--process-object-process object)))
   (t "process")))

(defun consent--process-object-command (object)
  "Return process OBJECT's command string, or nil."
  (cond
   ((and (consp object) (plist-get object :command))
    (plist-get object :command))
   ((consent--process-object-process object)
    (car (process-command (consent--process-object-process object))))
   (t nil)))

(defun consent--process-object-arguments (object)
  "Return process OBJECT's command arguments, or nil."
  (cond
   ((and (consp object) (plist-get object :arguments))
    (plist-get object :arguments))
   ((consent--process-object-process object)
    (cdr (process-command (consent--process-object-process object))))
   (t nil)))

(defun consent--process-object-buffer (object)
  "Return process OBJECT's live buffer, or nil."
  (let ((buffer
         (cond
          ((and (consp object) (plist-get object :buffer))
           (plist-get object :buffer))
          ((consent--process-object-process object)
           (process-buffer (consent--process-object-process object)))
          (t nil))))
    (and (buffer-live-p buffer) buffer)))

(defun consent--process-object-output (object stream)
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
         (consent--process-object-buffer object))
    (with-current-buffer (consent--process-object-buffer object)
      (buffer-substring-no-properties (point-min) (point-max))))
   (t "")))

(defun consent--process-job-object
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
    (consent--eval-error
     "process-start! adapter returned unsupported process object"))))

(defun consent--process-handle-datum (handle object grant-id status)
  "Return a Scheme-readable process HANDLE datum."
  `(,(consent--capability-grant-symbol "handle")
    (,(consent--capability-grant-symbol "id")
     ,(consent-handle-id handle))
    (,(consent--capability-grant-symbol "kind")
     ,(consent--capability-grant-symbol "process-job"))
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "process"))
    (,(consent--capability-grant-symbol "command")
     ,(or (consent--process-object-command object) consent-false))
    (,(consent--capability-grant-symbol "arguments")
     ,(or (consent--process-object-arguments object) nil))
    (,(consent--capability-grant-symbol "grant") ,grant-id)
    (,(consent--capability-grant-symbol "status")
     ,(consent--capability-grant-symbol status))))

(defun consent--process-register-handle (object grant)
  "Register and audit a process OBJECT handle."
  (let* ((grant-id (consent--capability-grant-id grant))
         (handle (consent--register-handle 'process object))
         (handle-datum
          (consent--process-handle-datum handle object grant-id 'live)))
    (consent-audit-record
     'capability-handle
     `((handle . ,handle-datum)
       (domain . process)
       (kind . process-job)
       (command . ,(or (consent--process-object-command object)
                       consent-false))
       (arguments . ,(or (consent--process-object-arguments object)
                         nil))
       (grant . ,grant-id)
       (status . live)))
    handle))

(defun consent-capability-authorize-process
    (binding operation context resource)
  "Authorize process OPERATION for BINDING with RESOURCE."
  (let* ((request-id (consent--process-capability-request-id))
         (request
          (consent--process-capability-request-datum
           request-id binding operation resource))
         (command (consent--process-resource-command resource))
         (handle (consent--process-resource-handle resource))
         (grants (consent--process-capability-grants context))
         match
         denied)
    (consent--process-capability-record-request
     request operation resource)
    (when (and command
               (equal (consent--capability-grant-symbol-name operation)
                      "spawn")
               (not (consent--process-command-allowlist-entry command)))
      (consent--process-capability-deny
       request request-id operation resource nil
       "command is not in process allow-list"))
    (when (and handle (not (consent--process-handle-live-p handle)))
      (consent--process-capability-deny
       request request-id operation resource nil
       "stale process handle"))
    (unless grants
      (consent--process-capability-deny
       request request-id operation resource nil
       "no active process grant covers request"))
    (dolist (grant grants)
      (let ((candidate
             (consent--process-capability-grant-match
              grant operation resource)))
        (when candidate
          (if (plist-get candidate :grant)
              (setq match candidate)
            (setq denied candidate)))))
    (unless match
      (consent--process-capability-deny
       request request-id operation resource
       (plist-get denied :denied)
       (or (plist-get denied :reason)
           "no active process grant covers request")))
    (let ((grant (plist-get match :grant)))
      (condition-case condition
          (progn
            (consent-policy-authorize
             (consent--process-capability-policy-category operation)
             binding
             `((domain . process)
               (operation . ,operation)
               (handle . ,(or handle consent-false))
               (command . ,(or command consent-false))
               (arguments . ,(or (consent--process-resource-arguments
                                  resource)
                                 nil))
               (environment . ,(or (consent--process-resource-environment
                                    resource)
                                   nil))
               (cwd . ,(or (consent--process-resource-cwd resource)
                           consent-false))
               (grant . ,(consent--capability-grant-id grant)))
             context)
            (consent--capability-grant-use! grant context)
            (list :operation operation
                  :request request
                  :decision
                  (consent--process-capability-record-decision
                   request request-id 'approved grant
                   "process request is covered by active grant")
                  :grant grant))
        (consent-policy-error
         (let ((decision
                (consent--process-capability-record-decision
                 request request-id 'denied grant
                 (error-message-string condition))))
           (consent-capability-audit-process-result
            (list :request request
                  :decision decision
                  :operation operation)
            (error-message-string condition)
            t)
           (signal (car condition) (cdr condition))))))))

(defun consent-capability-register-process-port
    (port kind authorization process-handle stream operations)
  "Attach a process-backed port capability handle to PORT."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (consent--capability-grant-id grant))
         (handle-id (consent--process-port-capability-handle-id))
         (limits (consent--port-capability-limits grant))
         (path (consent-handle-id process-handle))
         (handle
          (consent--port-capability-datum
           handle-id kind 'process operations grant-id limits 'open path)))
    (setf (consent--port-backing-domain port) 'process)
    (setf (consent--port-operations port) operations)
    (setf (consent--port-grant port) grant-id)
    (setf (consent--port-limits port) limits)
    (setf (consent--port-handle port) handle-id)
    (setf (consent--port-status port) 'open)
    (setf (consent--port-path port) path)
    (setf (consent--port-counters port) nil)
    (consent-audit-record
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

(defun consent--network-capability-grant-domain-p (grant)
  "Return non-nil when GRANT is a network-domain grant."
  (equal (consent--capability-grant-symbol-name
          (consent--capability-grant-field-value grant "domain"))
         "network"))

(defun consent--network-capability-operation-p (grant operation)
  "Return non-nil when GRANT allows network OPERATION."
  (let ((operation-name
         (consent--capability-grant-symbol-name operation)))
    (cl-some
     (lambda (candidate)
       (equal (consent--capability-grant-symbol-name candidate)
              operation-name))
     (consent--file-capability-field-values-list
      (consent--capability-grant-field-values grant "operations")))))

(defun consent--network-capability-grants (context)
  "Return network-domain grants carried by CONTEXT."
  (seq-filter
   #'consent--network-capability-grant-domain-p
   (consent--capability-context-grants context)))

(defun consent--network-name (value description)
  "Return VALUE as a network scope string for DESCRIPTION."
  (or (consent--capability-grant-symbol-name value)
      (consent--capability-string value description)))

(defun consent--network-scope-values (grant name description)
  "Return GRANT scope NAME values normalized as strings."
  (mapcar
   (lambda (value)
     (consent--network-name value description))
   (consent--file-capability-field-values-list
    (cdr (consent--capability-scope-clause grant name)))))

(defun consent--network-scope-integers (grant name description)
  "Return GRANT scope NAME values normalized as integers."
  (mapcar
   (lambda (value)
     (consent--capability-exact-integer value description))
   (consent--file-capability-field-values-list
    (cdr (consent--capability-scope-clause grant name)))))

(defun consent--network-scope-integer (grant name description)
  "Return GRANT scope NAME as one integer, or nil."
  (when-let ((value (consent--capability-scope-value grant name)))
    (consent--capability-exact-integer value description)))

(defun consent--network-member-string-p (value allowed)
  "Return non-nil when VALUE is allowed by ALLOWED strings."
  (or (null allowed)
      (member "all" allowed)
      (member value allowed)))

(defun consent--network-member-integer-p (value allowed)
  "Return non-nil when VALUE is allowed by ALLOWED integers."
  (or (null allowed)
      (member value allowed)))

(defun consent--network-subset-p (values allowed)
  "Return non-nil when every value in VALUES is included in ALLOWED."
  (or (null values)
      (null allowed)
      (member "all" allowed)
      (cl-every
       (lambda (value)
         (member value allowed))
       values)))

(defun consent--network-option-field (options name)
  "Return network OPTIONS field named NAME, or nil."
  (seq-find
   (lambda (field)
     (consent--capability-grant-field-named-p field name))
   (consent--proper-list-elements options "network options")))

(defun consent--network-option-value (options name)
  "Return network OPTIONS field NAME's first value, or nil."
  (cadr (consent--network-option-field options name)))

(defun consent--network-option-integer (options name description)
  "Return network OPTIONS integer field NAME, or nil."
  (when-let ((value (consent--network-option-value options name)))
    (consent--capability-exact-integer value description)))

(defun consent--network-option-boolean-p (options name)
  "Return non-nil when network OPTIONS field NAME is true."
  (let ((value (consent--network-option-value options name)))
    (and value (not (eq value consent-false)))))

(defun consent--network-header-entry (entry)
  "Return ENTRY as a two-string network header."
  (let ((elements (consent--proper-list-elements entry "network header")))
    (unless (= (length elements) 2)
      (consent--eval-error
       "network header entries must have exactly two fields"))
    (list (consent--capability-string
           (car elements)
           "network header name")
          (consent--capability-string
           (cadr elements)
           "network header value"))))

(defun consent--network-normalized-headers (headers)
  "Return HEADERS as a list of string pairs."
  (mapcar
   #'consent--network-header-entry
   (consent--proper-list-elements headers "network headers")))

(defun consent--network-header-class (header)
  "Return HEADER's disclosure class."
  (let ((name (downcase (car header))))
    (if (string-match-p
         "\\(authorization\\|cookie\\|token\\|api[-_]?key\\|secret\\|credential\\)"
         name)
        "credential"
      "metadata")))

(defun consent--network-header-classes (headers)
  "Return unique disclosure classes for HEADERS."
  (let (classes)
    (dolist (header headers (nreverse classes))
      (let ((class (consent--network-header-class header)))
        (unless (member class classes)
          (push class classes))))))

(defun consent--network-payload-class (payload options)
  "Return PAYLOAD disclosure class from PAYLOAD and OPTIONS."
  (cond
   ((and (not (or (null payload) (eq payload consent-false)))
         (consent-redaction-local-only-p payload))
    "local-only")
   ((and (not (or (null payload) (eq payload consent-false)))
         (consent-secret-source-p payload))
    "redacted")
   ((consent--network-option-value options "payload-class")
    (consent--network-name
     (consent--network-option-value options "payload-class")
     "network payload-class"))
   ((or (null payload) (eq payload consent-false))
    "none")
   (t "public")))

(defun consent--network-method-name (method)
  "Return METHOD as an uppercase string."
  (upcase (consent--network-name method "network method")))

(defun consent--network-url-parts (url)
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
      (consent--eval-error "network URL must include scheme and host"))
    (list :scheme scheme :host host :port port)))

(defun consent--network-resource-field (name value)
  "Return a Scheme-readable network resource field."
  (list (consent--capability-grant-symbol name) value))

(defun consent--network-redacted-resource (resource)
  "Return RESOURCE as redacted Scheme-readable fields."
  (let ((payload (plist-get resource :payload))
        (headers (plist-get resource :headers)))
    (list
     (consent--network-resource-field "url" (plist-get resource :url))
     (consent--network-resource-field
      "scheme" (plist-get resource :scheme))
     (consent--network-resource-field "host" (plist-get resource :host))
     (consent--network-resource-field "port"
                                           (consent--scheme-integer
                                            (plist-get resource :port)))
     (consent--network-resource-field "method"
                                           (consent--capability-grant-symbol
                                            (plist-get resource :method)))
     (consent--network-resource-field
      "headers" (consent--network-redacted-headers headers))
     (consent--network-resource-field
      "header-classes"
      (mapcar #'consent--capability-grant-symbol
              (plist-get resource :header-classes)))
     (consent--network-resource-field
      "payload" (consent-redact payload 'network))
     (consent--network-resource-field
      "payload-class"
      (consent--capability-grant-symbol
       (plist-get resource :payload-class)))
     (consent--network-resource-field
      "response-size"
      (consent--scheme-integer
       (or (plist-get resource :response-size) 0)))
     (consent--network-resource-field
      "redirects"
      (consent--scheme-integer (or (plist-get resource :redirects) 0)))
     (consent--network-resource-field
      "timeout-ms"
      (if-let ((timeout (plist-get resource :timeout-ms)))
          (consent--scheme-integer timeout)
        consent-false))
     (consent--network-resource-field
      "stream-lifetime-ms"
      (if-let ((lifetime (plist-get resource :stream-lifetime-ms)))
          (consent--scheme-integer lifetime)
        consent-false)))))

(defun consent--network-redacted-headers (headers)
  "Return HEADERS with credential-bearing values redacted."
  (mapcar
   (lambda (header)
     (list (car header)
           (if (equal (consent--network-header-class header)
                      "credential")
               consent-redaction-replacement
             (consent-redact (cadr header) 'network))))
   headers))

(defun consent--network-resource
    (method url headers payload options &optional stream)
  "Return normalized network resource for METHOD URL HEADERS PAYLOAD OPTIONS."
  (let* ((url-text (consent--capability-string url "network URL"))
         (parts (consent--network-url-parts url-text))
         (normalized-headers
          (consent--network-normalized-headers headers))
         (payload-class
          (consent--network-payload-class payload options)))
    (list :url url-text
          :scheme (plist-get parts :scheme)
          :host (plist-get parts :host)
          :port (plist-get parts :port)
          :method (consent--network-method-name method)
          :headers normalized-headers
          :header-classes
          (consent--network-header-classes normalized-headers)
          :payload payload
          :payload-class payload-class
          :response-size
          (consent--network-option-integer
           options "response-size" "network response-size")
          :redirects
          (or (consent--network-option-integer
               options "redirects" "network redirects")
              0)
          :timeout-ms
          (consent--network-option-integer
           options "timeout-ms" "network timeout-ms")
          :stream-lifetime-ms
          (and stream
               (consent--network-option-integer
                options
                "stream-lifetime-ms"
                "network stream-lifetime-ms"))
          :allow-local-only
          (consent--network-option-boolean-p options "allow-local-only"))))

(defun consent--network-capability-effect-symbol (operation)
  "Return the effect class for a network operation."
  (consent--capability-grant-symbol
   (if (equal (consent--capability-grant-symbol-name operation) "stream")
       "network-stream"
     "network-egress")))

(defun consent--network-capability-request-datum
    (request-id library binding operation resource)
  "Return a Scheme-readable network capability request datum."
  `(,(consent--capability-grant-symbol "capability-request")
    (,(consent--capability-grant-symbol "id") ,request-id)
    (,(consent--capability-grant-symbol "session")
     ,consent-false)
    (,(consent--capability-grant-symbol "library") ,library)
    (,(consent--capability-grant-symbol "binding") ,binding)
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "network"))
    (,(consent--capability-grant-symbol "operation")
     ,(consent--capability-grant-symbol operation))
    (,(consent--capability-grant-symbol "resource")
     ,@(consent--network-redacted-resource resource))
    (,(consent--capability-grant-symbol "effect")
     ,(consent--network-capability-effect-symbol operation))))

(defun consent--network-capability-record-request
    (request operation resource)
  "Audit network capability REQUEST."
  (consent-audit-record
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

(defun consent--network-capability-record-decision
    (request request-id status grant reason &optional fields)
  "Audit and return a network capability decision datum."
  (let* ((decision-id (consent--network-capability-decision-id))
         (grant-id (or (and grant (consent--capability-grant-id grant))
                       (consent--capability-grant-symbol "none")))
         (decision
          `(,(consent--capability-grant-symbol "capability-decision")
            (,(consent--capability-grant-symbol "id") ,decision-id)
            (,(consent--capability-grant-symbol "request") ,request-id)
            (,(consent--capability-grant-symbol "status")
             ,(consent--capability-grant-symbol status))
            (,(consent--capability-grant-symbol "domain")
             ,(consent--capability-grant-symbol "network"))
            (,(consent--capability-grant-symbol "grant") ,grant-id)
            (,(consent--capability-grant-symbol "reason") ,reason))))
    (consent-audit-record
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

(defun consent-capability-audit-network-result
    (authorization result &optional errored)
  "Audit network capability AUTHORIZATION with RESULT."
  (let ((request (plist-get authorization :request))
        (decision (plist-get authorization :decision))
        (operation (plist-get authorization :operation)))
    (consent-audit-record
     'capability-audit
     `((request . ,request)
       (decision . ,decision)
       (domain . network)
       (operation . ,operation)
       (result . ,(if errored
                      (list 'error (consent-redact result 'network))
                    (list 'ok (consent-redact result 'network))))))))

(defun consent--network-capability-deny
    (request request-id operation resource grant reason)
  "Record denied network REQUEST and signal REASON."
  (let ((decision
         (consent--network-capability-record-decision
          request request-id 'denied grant reason
          `((operation . ,operation)
            (host . ,(plist-get resource :host))
            (method . ,(plist-get resource :method))))))
    (consent-capability-audit-network-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (signal 'consent-capability-grant-error
            (list (format "network capability denied: %s" reason)))))

(defun consent--network-capability-grant-match
    (grant operation resource)
  "Return a match plist when GRANT authorizes network OPERATION."
  (let ((schemes (consent--network-scope-values
                  grant "schemes" "network grant scheme"))
        (hosts (consent--network-scope-values
                grant "hosts" "network grant host"))
        (ports (consent--network-scope-integers
                grant "ports" "network grant port"))
        (methods (mapcar #'upcase
                         (consent--network-scope-values
                          grant "methods" "network grant method")))
        (header-classes (consent--network-scope-values
                         grant
                         "header-classes"
                         "network grant header-class"))
        (payload-classes (consent--network-scope-values
                          grant
                          "payload-classes"
                          "network grant payload-class"))
        (max-response-bytes
         (consent--network-scope-integer
          grant "max-response-bytes" "network grant max-response-bytes"))
        (max-redirects
         (consent--network-scope-integer
          grant "max-redirects" "network grant max-redirects"))
        (max-timeout-ms
         (consent--network-scope-integer
          grant "max-timeout-ms" "network grant max-timeout-ms"))
        (max-stream-lifetime-ms
         (consent--network-scope-integer
          grant "stream-lifetime-ms" "network grant stream-lifetime-ms")))
    (cond
     ((not (consent--network-capability-operation-p grant operation))
      nil)
     ((eq (consent--capability-grant-status grant) 'revoked)
      (list :denied grant :reason "revoked network capability grant"))
     ((not (consent--capability-grant-active-p grant))
      (list :denied grant :reason "expired network capability grant"))
     ((not (consent--network-member-string-p
            (plist-get resource :scheme) schemes))
      (list :denied grant
            :reason "scheme is outside approved network grant scope"))
     ((not (consent--network-member-string-p
            (plist-get resource :host) hosts))
      (list :denied grant
            :reason "host is outside approved network grant scope"))
     ((not (consent--network-member-integer-p
            (plist-get resource :port) ports))
      (list :denied grant
            :reason "port is outside approved network grant scope"))
     ((not (consent--network-member-string-p
            (plist-get resource :method) methods))
      (list :denied grant
            :reason "method is outside approved network grant scope"))
     ((not (consent--network-subset-p
            (plist-get resource :header-classes) header-classes))
      (list :denied grant
            :reason "header class is outside approved network grant scope"))
     ((not (consent--network-member-string-p
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

(defun consent-capability-authorize-network
    (library binding context operation resource)
  "Authorize network OPERATION for BINDING with RESOURCE."
  (let* ((request-id (consent--network-capability-request-id))
         (library-datum (consent-read library))
         (binding-datum (consent--capability-grant-symbol binding))
         (request
          (consent--network-capability-request-datum
           request-id library-datum binding-datum operation resource))
         (grants (consent--network-capability-grants context))
         match
         denied)
    (consent--network-capability-record-request
     request operation resource)
    (when (and (equal (plist-get resource :payload-class) "local-only")
               (not (plist-get resource :allow-local-only)))
      (consent--network-capability-deny
       request request-id operation resource nil
       "local-only payload requires explicit network disclosure approval"))
    (unless grants
      (consent--network-capability-deny
       request request-id operation resource nil
       "no active network grant covers request"))
    (dolist (grant grants)
      (let ((candidate
             (consent--network-capability-grant-match
              grant operation resource)))
        (when candidate
          (if (plist-get candidate :grant)
              (setq match candidate)
            (setq denied candidate)))))
    (unless match
      (consent--network-capability-deny
       request request-id operation resource
       (plist-get denied :denied)
       (or (plist-get denied :reason)
           "no active network grant covers request")))
    (let ((grant (plist-get match :grant)))
      (condition-case condition
          (progn
            (consent-policy-authorize
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
               (grant . ,(consent--capability-grant-id grant)))
             context)
            (consent--capability-grant-use! grant context)
            (list :operation operation
                  :request request
                  :decision
                  (consent--network-capability-record-decision
                   request request-id 'approved grant
                   "network request is covered by active grant")
                  :grant grant
                  :max-response-bytes
                  (plist-get match :max-response-bytes)
                  :transport-resource
                  (consent--network-redacted-resource resource)))
        (consent-policy-error
         (let ((decision
                (consent--network-capability-record-decision
                 request request-id 'denied grant
                 (error-message-string condition))))
           (consent-capability-audit-network-result
            (list :request request
                  :decision decision
                  :operation operation)
            (error-message-string condition)
            t)
           (signal (car condition) (cdr condition))))))))

(defun consent--network-response-body-size (response)
  "Return RESPONSE body size in characters when visible, or 0."
  (let ((body
         (and (consp response)
              (cadr (seq-find
                     (lambda (field)
                       (consent--capability-grant-field-named-p
                        field "body"))
                     (cdr response))))))
    (cond
     ((stringp body) (length body))
     ((null body) 0)
     (t (length (consent-value->external body))))))

(defun consent--network-check-response-limit! (authorization response)
  "Fail if RESPONSE exceeds AUTHORIZATION's response limit."
  (when-let ((limit (plist-get authorization :max-response-bytes)))
    (let ((size (consent--network-response-body-size response)))
      (when (> size limit)
        (let ((reason "network response size exceeds grant limit"))
          (consent-capability-audit-network-result
           authorization reason t)
          (signal 'consent-capability-grant-error (list reason)))))))

(defun consent--network-normalize-response-datum (datum)
  "Return DATUM using Consent Scheme symbols for host adapter symbols."
  (cond
   ((consent-symbol-p datum)
    datum)
   ((symbolp datum)
    (consent--capability-grant-symbol datum))
   ((consp datum)
    (mapcar #'consent--network-normalize-response-datum datum))
   ((vectorp datum)
    (vconcat
     (mapcar #'consent--network-normalize-response-datum
             (append datum nil))))
   (t datum)))

(defun consent--network-stream-handle-datum
    (handle request url grant-id status)
  "Return a Scheme-readable network stream HANDLE datum."
  `(,(consent--capability-grant-symbol "handle")
    (,(consent--capability-grant-symbol "id")
     ,(consent-handle-id handle))
    (,(consent--capability-grant-symbol "kind")
     ,(consent--capability-grant-symbol "network-stream"))
    (,(consent--capability-grant-symbol "domain")
     ,(consent--capability-grant-symbol "network"))
    (,(consent--capability-grant-symbol "request") ,request)
    (,(consent--capability-grant-symbol "url") ,url)
    (,(consent--capability-grant-symbol "grant") ,grant-id)
    (,(consent--capability-grant-symbol "status")
     ,(consent--capability-grant-symbol status))))

(defun consent--network-register-stream-handle
    (url source authorization)
  "Register and audit a network stream handle."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (consent--capability-grant-id grant))
         (id (consent--network-stream-handle-id))
         (handle (consent--make-handle 'network-stream id))
         (object (list :url url
                       :source source
                       :grant grant-id
                       :status 'live)))
    (puthash
     id
     (consent--initialize-handle-entry!
      (consent--make-handle-entry 'network-stream object)
      id 'network-stream object)
     consent--handle-registry)
    (consent-audit-record
     'capability-handle
     `((handle . ,(consent--network-stream-handle-datum
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

(defun consent--network-stream-object-live-p (object)
  "Return non-nil when network stream OBJECT is live."
  (not (memq (plist-get object :status)
             '(closed cancelled stale expired revoked))))

(defun consent--network-stream-live-p (id)
  "Return non-nil when ID names a live network stream."
  (and (stringp id)
       (let ((entry (gethash id consent--handle-registry)))
         (and entry
              (eq (consent--handle-entry-kind entry) 'network-stream)
              (consent--network-stream-object-live-p
               (consent--handle-entry-object entry))))))

(defun consent-capability-register-network-port
    (port kind authorization stream-handle operations)
  "Attach a network-backed port capability handle to PORT."
  (let* ((grant (plist-get authorization :grant))
         (grant-id (consent--capability-grant-id grant))
         (handle-id (consent--network-port-capability-handle-id))
         (limits (consent--port-capability-limits grant))
         (path (consent-handle-id stream-handle))
         (handle
          (consent--port-capability-datum
           handle-id kind 'network operations grant-id limits 'open path)))
    (setf (consent--port-backing-domain port) 'network)
    (setf (consent--port-operations port) operations)
    (setf (consent--port-grant port) grant-id)
    (setf (consent--port-limits port) limits)
    (setf (consent--port-handle port) handle-id)
    (setf (consent--port-status port) 'open)
    (setf (consent--port-path port) path)
    (setf (consent--port-counters port) nil)
    (consent-audit-record
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

(defun consent--file-capability-deny
    (request request-id operation filename path grant reason
             &optional policy-denial context policy-operation)
  "Record a denied file capability request and signal REASON."
  (let ((decision
         (consent--file-capability-record-decision
          request request-id 'denied grant reason)))
    (consent-capability-audit-file-result
     (list :request request :decision decision :operation operation)
     reason
     t)
    (if policy-denial
        (consent-policy-deny
         'standard-host-effect
         (or policy-operation (format "%s" operation))
         `((filename . ,filename)
           (path . ,path))
         context
         reason)
      (signal 'consent-capability-grant-error
              (list (format "file capability denied: %s" reason))))))

(defun consent-capability-authorize-file
    (filename context operation binding &optional legacy-allowed-paths)
  "Authorize FILENAME for file OPERATION and return an authorization plist.
LEGACY-ALLOWED-PATHS converts the old path allow-list options into a
synthetic file grant so existing callers share the capability vocabulary."
  (let* ((path (expand-file-name
                filename
                (consent--eval-context-include-directory context)))
         (resolved-path
          (consent--file-capability-existing-truename path))
         (request-id (consent--file-capability-request-id))
         (request
          (consent--file-capability-request-datum
           request-id filename path operation binding))
         (file-grants
          (append
           (consent--file-capability-grants context)
           (consent--file-capability-legacy-grants
            legacy-allowed-paths operation)))
         match
         denied)
    (consent--file-capability-record-request
     request operation filename path)
    (when (consent--file-capability-remote-path-p filename path)
      (consent--file-capability-deny
       request request-id operation filename path nil
       "remote file paths require a non-file capability domain"
       nil
       context
       binding))
    (unless file-grants
      (consent--file-capability-deny
       request request-id operation filename path nil
       (format "%s requires policy-gated host file access: %s"
               binding filename)
       t
       context
       binding))
    (dolist (grant file-grants)
      (let ((candidate
             (consent--file-capability-grant-match
              grant path resolved-path operation context)))
        (when candidate
          (if (plist-get candidate :grant)
              (setq match candidate)
            (setq denied candidate)))))
    (unless match
      (consent--file-capability-deny
       request request-id operation filename path
       (plist-get denied :denied)
       (or (plist-get denied :reason)
           "no active file grant covers path")))
    (let ((grant (plist-get match :grant)))
      (consent-policy-authorize
       'standard-host-effect
       binding
       `((filename . ,filename)
         (path . ,path)
         (resolved-path . ,resolved-path)
         (grant . ,(consent--capability-grant-id grant)))
       context)
      (consent--capability-grant-use! grant context)
      (let ((decision
             (consent--file-capability-record-decision
              request request-id 'approved grant
              "path is inside approved file grant root"
              `((path . ,path)
                (resolved-path . ,resolved-path)
                (approved-root . ,(plist-get match :allowed-root))
                (resolved-root . ,(plist-get match :resolved-root)))))
            (handle
             (consent--file-capability-register-handle
              path resolved-path grant operation)))
        (list :path path
              :resolved-path resolved-path
              :operation operation
              :request request
              :decision decision
              :handle handle
              :grant grant)))))

(defun consent--capability-grant-scope-match-p
    (grant name arguments context)
  "Return non-nil when GRANT scope matches NAME with ARGUMENTS."
  (let* ((target-handle
          (consent--capability-operation-buffer-handle name arguments))
         (grant-handle
          (consent--capability-scope-value grant "buffer"))
         (target-window-handle
          (consent--capability-operation-window-handle name arguments))
         (grant-window-handle
          (consent--capability-scope-value grant "window"))
         (operation-region
          (consent--capability-operation-region name arguments))
         (grant-range
          (consent--capability-range-values grant))
         (operation-direction
          (consent--capability-operation-direction name arguments))
         (grant-direction
          (consent--capability-scope-value grant "direction"))
         (session
          (consent--capability-scope-value grant "session"))
         (file
          (or (consent--capability-scope-value grant "file")
              (consent--capability-scope-value grant "path")))
         (project-root
          (consent--capability-scope-value grant "project-root"))
         (skill
          (consent--capability-scope-value grant "skill")))
    (consent--capability-check-grant-handle-live grant grant-handle)
    (consent--capability-check-grant-handle-live grant grant-window-handle)
    (and
     (or (null grant-handle)
         (consent--capability-same-handle-p grant-handle target-handle))
     (or (null grant-window-handle)
         (consent--capability-same-handle-p
          grant-window-handle target-window-handle))
     (or (null grant-range)
         (and operation-region
              (<= (car grant-range) (car operation-region))
              (<= (cadr operation-region) (cadr grant-range))))
     (or (null grant-direction)
         (and operation-direction
              (equal
               (consent--capability-grant-symbol-name grant-direction)
               operation-direction)))
     (or (null session)
         (equal (consent--capability-grant-id-name session)
                (and context
                     (consent--eval-context-p context)
                     (consent--eval-context-session-id context))))
     (or (null skill)
         ;; No skill execution identity exists yet, so skill-scoped grants are
         ;; declarative until a host activates a matching skill context.
         nil)
     (or (and (null file) (null project-root))
         (let* ((buffer
                 (and target-handle
                      (consent-handle-p target-handle)
                      (consent-capability-handle-live-p target-handle)
                      (consent--live-buffer-for-handle
                       target-handle name)))
                (target-file
                 (and buffer (consent--buffer-target-file buffer))))
           (and
            (or (null file)
                (and target-file
                     (equal (expand-file-name file)
                            (expand-file-name target-file))))
            (or (null project-root)
                (consent--capability-file-in-project-p
                 target-file project-root))))))))

(defun consent--capability-grant-candidate-p (grant spec name)
  "Return non-nil when GRANT targets SPEC and NAME."
  (and (equal (consent--capability-grant-library-key grant)
              (plist-get spec :library))
       (equal (consent--capability-grant-effect-name grant)
              name)))

(defun consent--capability-grant-mark-expired!
    (grant context operation)
  "Mark GRANT expired in CONTEXT and audit OPERATION."
  (let ((expired
         (consent--capability-grant-replace-field
          grant "status"
          (list (consent--capability-grant-symbol "expired")))))
    (consent--capability-store-grant! expired context)
    (consent--capability-audit-grant operation expired 'expired)
    (consent--capability-audit-revocation
     expired 'expired "capability grant expired")
    expired))

(defun consent--capability-revocation-datum
    (grant status reason)
  "Return a Scheme-readable revocation datum for GRANT."
  (let ((grant-id (consent--capability-grant-id grant)))
    `(,(consent--capability-grant-symbol "capability-revocation")
      (,(consent--capability-grant-symbol "id")
       ,(consent--capability-revocation-id))
      (,(consent--capability-grant-symbol "target")
       (,(consent--capability-grant-symbol "grant") ,grant-id))
      (,(consent--capability-grant-symbol "status")
       ,(consent--capability-grant-symbol status))
      (,(consent--capability-grant-symbol "reason") ,reason))))

(defun consent--capability-audit-revocation
    (grant status reason)
  "Audit a capability revocation for GRANT."
  (let* ((grant-id (consent--capability-grant-id grant))
         (revocation
          (consent--capability-revocation-datum
           grant status reason)))
    (consent-audit-record
     'capability-revocation
     `((revocation . ,revocation)
       (target . (grant ,grant-id))
       (status . ,status)
       (reason . ,reason)))))

(defun consent--capability-grant-use! (grant context)
  "Record one successful use of GRANT in CONTEXT."
  (consent--capability-audit-grant
   "capability-grant-use" grant 'allowed)
  (when-let ((uses (consent--capability-grant-field-value
                    grant "uses-remaining")))
    (let* ((remaining (1- (consent--capability-exact-integer
                           uses "capability grant uses-remaining")))
           (updated
            (consent--capability-grant-replace-field
             grant "uses-remaining"
             (list (consent--scheme-integer remaining)))))
      (consent--capability-store-grant! updated context)
      (when (<= remaining 0)
        (consent--capability-grant-mark-expired!
         updated context "capability-grant-expire!")))))

(defun consent--require-capability-grant (name arguments context spec)
  "Require a matching capability grant for NAME with ARGUMENTS."
  (let ((candidate nil)
        (denied nil))
    (dolist (grant (consent--capability-context-grants context))
      (when (consent--capability-grant-candidate-p grant spec name)
        (unless candidate
          (setq candidate grant))
        (cond
         ((eq (consent--capability-grant-status grant) 'revoked)
          (setq denied
                (list grant "revoked capability grant")))
         ((not (consent--capability-grant-active-p grant))
          (setq denied
                (list grant "expired capability grant")))
         ((consent--capability-grant-scope-match-p
           grant name arguments context)
          (consent--capability-grant-use! grant context)
          (setq candidate :authorized))
         ((not denied)
          (setq denied
                (list grant "outside capability grant scope"))))))
    (cond
     ((eq candidate :authorized)
      t)
     (denied
      (consent--capability-grant-error
       (cadr denied)
       (car denied)
       `((capability . ,name)
         (arguments . ,arguments))))
     (candidate
      (consent--capability-grant-error
       "outside capability grant scope"
       candidate
       `((capability . ,name)
         (arguments . ,arguments))))
     (t
      (consent--capability-grant-error
       (format "missing capability grant for %s" name)
       nil
       `((capability . ,name)
         (arguments . ,arguments)))))))

(defun consent--authorize-capability-grant-datum (grant context)
  "Authorize creation of GRANT in CONTEXT."
  (cond
   ((consent--file-capability-grant-domain-p grant)
    (consent-policy-authorize
     'standard-host-effect
     "grant-capability!"
     `((domain . file)
       (operations . ,(consent--capability-grant-field-values
                       grant "operations"))
       (grant . ,grant))
     context
     'capability-grant))
   ((consent--process-capability-grant-domain-p grant)
    (consent-policy-authorize
     'command-process
     "grant-capability!"
     `((domain . process)
       (operations . ,(consent--capability-grant-field-values
                       grant "operations"))
       (grant . ,grant))
     context
     'capability-grant))
   ((consent--network-capability-grant-domain-p grant)
    (consent-policy-authorize
     'network-access
     "grant-capability!"
     `((domain . network)
       (operations . ,(consent--capability-grant-field-values
                       grant "operations"))
       (grant . ,grant))
     context
     'capability-grant))
   (t
    (let* ((library (consent--capability-grant-library-key grant))
           (effect (consent--capability-grant-effect-name grant))
           (spec (consent--emacs-capability-manifest-spec effect))
           (category (consent--emacs-capability-policy-category spec)))
      (consent-policy-authorize
       category
       "grant-capability!"
       `((library . ,library)
         (capability . ,effect)
         (grant . ,grant))
       context
       'capability-grant)))))

(defun consent-capability-grant! (datum &optional context)
  "Create a capability grant from DATUM in CONTEXT."
  (let ((grant (consent--capability-grant-normalize datum)))
    (consent--authorize-capability-grant-datum grant context)
    (consent--capability-store-grant! grant context)
    (consent--capability-audit-grant
     "grant-capability!" grant 'created)
    grant))

(defun consent-capability-current-grants (&optional context)
  "Return current active capability grants in CONTEXT."
  (consent--capability-current-grants context))

(defun consent-capability-grant-ref (id &optional context)
  "Return capability grant ID from CONTEXT, or nil."
  (consent--capability-grant-by-id id context))

(defun consent--capability-restriction-field (restrictions name)
  "Return field NAME from RESTRICTIONS."
  (seq-find
   (lambda (field)
     (consent--capability-grant-field-named-p field name))
   restrictions))

(defun consent--capability-scope-range-values (scope)
  "Return SCOPE range values, or nil."
  (when-let ((clause
              (seq-find
               (lambda (entry)
                 (or (consent--capability-grant-field-named-p
                      entry "range")
                     (consent--capability-grant-field-named-p
                      entry "region")))
               scope)))
    (list
     (consent--capability-exact-integer
      (cadr clause) "attenuated grant range start")
     (consent--capability-exact-integer
      (caddr clause) "attenuated grant range end"))))

(defun consent--capability-range-contained-p (inner outer)
  "Return non-nil when INNER range is contained by OUTER range."
  (or (null outer)
      (and inner
           (<= (car outer) (car inner))
           (<= (cadr inner) (cadr outer)))))

(defun consent--capability-scope-clause-named (scope name)
  "Return clause NAME from SCOPE."
  (seq-find
   (lambda (clause)
     (consent--capability-grant-field-named-p clause name))
   scope))

(defun consent--capability-merge-scope (parent restriction)
  "Return parent scope attenuated by RESTRICTION scope."
  (let* ((parent-scope parent)
         (child-scope (cdr restriction))
         (parent-range
          (consent--capability-scope-range-values parent-scope))
         (child-range
          (consent--capability-scope-range-values child-scope))
         (merged (copy-tree parent-scope)))
    (unless (consent--capability-range-contained-p
             child-range parent-range)
      (signal 'consent-capability-grant-error
              (list "attenuated grant range must stay within parent grant")))
    (dolist (clause child-scope)
      (let ((name (consent--capability-grant-symbol-name (car clause))))
        (when-let ((parent-clause
                    (and (not (member name '("range" "region")))
                         (consent--capability-scope-clause-named
                          parent-scope name))))
          (unless (equal parent-clause clause)
            (signal 'consent-capability-grant-error
                    (list "attenuated grant cannot broaden parent scope"))))
        (setq merged
              (cons clause
                    (seq-remove
                     (lambda (candidate)
                       (member
                        (consent--capability-grant-symbol-name
                         (car candidate))
                        (if (member name '("range" "region"))
                            '("range" "region")
                          (list name))))
                     merged)))))
    (nreverse merged)))

(defun consent--capability-merge-expires (parent-expires child-expires)
  "Return CHILD-EXPIRES when it does not broaden PARENT-EXPIRES."
  (let ((parent-uses (consent--capability-grant-expires-uses
                      parent-expires))
        (child-uses (consent--capability-grant-expires-uses
                     child-expires))
        (parent-name (consent--capability-grant-symbol-name
                      parent-expires))
        (child-name (consent--capability-grant-symbol-name
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
      (signal 'consent-capability-grant-error
              (list "attenuated grant cannot broaden parent lifetime"))))))

(defun consent-capability-grant-attenuate
    (grant-id restrictions &optional context)
  "Create an attenuated child grant from GRANT-ID using RESTRICTIONS."
  (let* ((parent
          (or (consent--capability-grant-by-id grant-id context)
              (signal 'consent-capability-grant-error
                      (list "unknown parent capability grant"))))
         (parent-scope
          (consent--capability-grant-scope-clauses parent))
         (child
          (consent--capability-grant-remove-fields
           (copy-tree parent)
           '("id" "status" "uses-remaining" "parent")))
         (id-field
          (consent--capability-restriction-field restrictions "id"))
         (scope-field
          (consent--capability-restriction-field restrictions "scope"))
         (expires-field
          (consent--capability-restriction-field restrictions "expires"))
         (child-id
          (or (cadr id-field)
              (consent--capability-generated-grant-id))))
    (unless (consent--capability-grant-active-p parent)
      (signal 'consent-capability-grant-error
              (list "cannot attenuate inactive capability grant")))
    (dolist (field restrictions)
      (let ((name (consent--capability-grant-symbol-name (car field))))
        (unless (member name '("id" "scope" "expires"))
          (when (and (member name '("library" "effect"))
                     (not (equal
                           (cdr field)
                           (cdr (consent--capability-grant-field
                                 parent name)))))
            (signal 'consent-capability-grant-error
                    (list "attenuated grant cannot broaden parent authority")))
          (setq child
                (consent--capability-grant-replace-field
                 child name (cdr field))))))
    (when scope-field
      (setq child
            (consent--capability-grant-replace-field
             child "scope"
             (consent--capability-merge-scope parent-scope scope-field))))
    (when expires-field
      (setq child
            (consent--capability-grant-replace-field
             child "expires"
             (list
               (consent--capability-merge-expires
                (consent--capability-grant-field-value parent "expires")
               (cadr expires-field))))))
    (setq child
          (consent--capability-grant-replace-field
           child "id" (list (consent--capability-grant-symbol child-id))))
    (setq child
          (consent--capability-grant-replace-field
           child "parent"
           (list (consent--capability-grant-id parent))))
    (setq child (consent--capability-grant-normalize child))
    (consent--capability-store-grant! child context)
    (consent--capability-audit-grant
     "grant-attenuate" child 'attenuated
     `((parent . ,(consent--capability-grant-id parent))))
    child))

(defun consent-capability-grant-revoke! (grant-id &optional context)
  "Revoke capability grant GRANT-ID in CONTEXT and return it."
  (let* ((grant
          (or (consent--capability-grant-by-id grant-id context)
              (signal 'consent-capability-grant-error
                      (list "unknown capability grant"))))
         (revoked
          (consent--capability-grant-replace-field
           grant "status"
           (list (consent--capability-grant-symbol "revoked")))))
    (consent--capability-store-grant! revoked context)
    (consent--capability-audit-grant
     "grant-revoke!" revoked 'revoked)
    (consent--capability-audit-revocation
     revoked 'revoked "grant-revoke!")
    revoked))

(defun consent-capability-expire-after-eval! (context)
  "Expire all active after-eval grants in CONTEXT."
  (dolist (grant (consent--capability-context-grants context))
    (when (and (consent--capability-grant-active-p grant)
               (equal
                (consent--capability-grant-symbol-name
                 (consent--capability-grant-field-value
                  grant "expires"))
                "after-eval"))
      (consent--capability-grant-mark-expired!
       grant context "capability-grant-expire!"))))

(defun consent--primitive-grant-capability (arguments context)
  "Primitive grant-capability! over ARGUMENTS."
  (consent-capability-grant! (car arguments) context))

(defun consent--primitive-current-grants (_arguments context)
  "Primitive current-grants."
  (consent-capability-current-grants context))

(defun consent--primitive-grant-ref (arguments context)
  "Primitive grant-ref over ARGUMENTS."
  (or (consent-capability-grant-ref (car arguments) context)
      consent-false))

(defun consent--primitive-grant-attenuate (arguments context)
  "Primitive grant-attenuate over ARGUMENTS."
  (consent-capability-grant-attenuate
   (car arguments) (cadr arguments) context))

(defun consent--primitive-grant-revoke (arguments context)
  "Primitive grant-revoke! over ARGUMENTS."
  (consent-capability-grant-revoke! (car arguments) context))

(defun consent--primitive-call-with-capability-grant
    (arguments context)
  "Primitive call-with-capability-grant over ARGUMENTS."
  (let* ((grant-or-id (car arguments))
         (thunk (cadr arguments))
         (grant
          (if (consent--capability-grant-datum-p grant-or-id)
              (consent-capability-grant! grant-or-id context)
            (or (consent-capability-grant-ref grant-or-id context)
                (signal 'consent-capability-grant-error
                        (list "unknown capability grant")))))
         (active (consent--eval-context-active-capability-grants
                  context)))
    (unwind-protect
        (progn
          (push (consent--capability-grant-id grant)
                (consent--eval-context-active-capability-grants
                 context))
          (consent--apply-procedure
           thunk nil context nil))
      (setf (consent--eval-context-active-capability-grants context)
            active))))

(defun consent--primitive-handle-ref (arguments _context)
  "Primitive handle-ref over ARGUMENTS."
  (or (consent-capability-handle-ref (car arguments))
      consent-false))

(defun consent--primitive-handle-live? (arguments _context)
  "Primitive handle-live? over ARGUMENTS."
  (consent--scheme-boolean-value
   (consent-capability-handle-live-p (car arguments))))

(defun consent--primitive-handle-kind (arguments _context)
  "Primitive handle-kind over ARGUMENTS."
  (or (consent-capability-handle-kind (car arguments))
      consent-false))

(defun consent--primitive-handle-revalidate (arguments _context)
  "Primitive handle-revalidate over ARGUMENTS."
  (or (consent-capability-revalidate-handle (car arguments))
      consent-false))

(defun consent--primitive-handle-release! (arguments _context)
  "Primitive handle-release! over ARGUMENTS."
  (or (consent-capability-release-handle-datum (car arguments))
      consent-false))

(defun consent-capability-primitive-specs ()
  "Return primitive specs for the private `(consent capability primitive)' library."
  `(("grant-capability!" ,#'consent--primitive-grant-capability 1 1)
    ("current-grants" ,#'consent--primitive-current-grants 0 0)
    ("grant-ref" ,#'consent--primitive-grant-ref 1 1)
    ("grant-attenuate" ,#'consent--primitive-grant-attenuate 2 2)
    ("grant-revoke!" ,#'consent--primitive-grant-revoke 1 1)
    ("call-with-capability-grant"
     ,#'consent--primitive-call-with-capability-grant 2 2)
    ("handle-ref" ,#'consent--primitive-handle-ref 1 1)
    ("handle-live?" ,#'consent--primitive-handle-live? 1 1)
    ("handle-kind" ,#'consent--primitive-handle-kind 1 1)
    ("handle-revalidate" ,#'consent--primitive-handle-revalidate 1 1)
    ("handle-release!" ,#'consent--primitive-handle-release! 1 1)))

(defun consent--authorize-emacs-capability
    (name arguments context)
  "Authorize Emacs capability NAME with ARGUMENTS in CONTEXT."
  (unless consent--emacs-capability-preauthorized
    (let ((spec (consent--emacs-capability-manifest-spec name)))
      (unless (or (plist-get spec :requires-process-grant)
                  (plist-get spec :requires-network-grant))
        (consent-policy-authorize
         (consent--emacs-capability-policy-category spec)
         name
         `((library . ,(and spec (plist-get spec :library)))
           (capability . ,name)
           (arguments . ,arguments))
         context
         'capability-call))
      (when (and consent-capability-require-grants-for-mutations
                 (plist-get spec :requires-grant))
        (consent--require-capability-grant
         name arguments context spec)))))

(defun consent--capability-result-string (result)
  "Return a printable audit string for capability RESULT."
  (condition-case _
      (consent-value->external result)
    (error "#<unprintable>")))

(defun consent--audit-emacs-capability-result
    (name arguments outcome fields)
  "Audit Emacs capability NAME with ARGUMENTS producing OUTCOME."
  (let ((spec (consent--emacs-capability-manifest-spec name)))
    (consent-audit-record
     'capability-result
     (append
      `((category . ,(consent--emacs-capability-policy-category spec))
        (operation . ,name)
        (library . ,(and spec (plist-get spec :library)))
        (capability . ,name)
        (arguments . ,arguments)
        (outcome . ,outcome)
        (decision . ,(if (eq outcome 'success) 'completed 'errored)))
      fields))))

(defun consent--add-emacs-capability-result-fields (fields)
  "Add FIELDS to the active Emacs capability result audit entry."
  (setq consent--emacs-capability-result-fields
        (append consent--emacs-capability-result-fields fields)))

(defun consent--call-emacs-capability
    (name function arguments context)
  "Call Emacs capability FUNCTION and audit its outcome."
  (consent--authorize-emacs-capability name arguments context)
  (let ((consent--emacs-capability-result-fields nil))
    (condition-case condition
        (let ((result
               (let ((consent--emacs-capability-preauthorized t))
                 (let ((consent--handle-registration-context context)
                       (consent--handle-registration-created-by name))
                   (funcall function arguments context)))))
          (consent--audit-emacs-capability-result
           name
           arguments
           'success
           (append
            consent--emacs-capability-result-fields
            `((result . ,(consent--capability-result-string result)))))
          result)
      (error
       (consent--audit-emacs-capability-result
        name
        arguments
        'error
        (append
         consent--emacs-capability-result-fields
         `((error . ,(error-message-string condition)))))
       (signal (car condition) (cdr condition))))))

(defun consent--wrap-emacs-capability (name function)
  "Return a policy and outcome-auditing wrapper for capability FUNCTION."
  (lambda (arguments context)
    (consent--call-emacs-capability name function arguments context)))

(defun consent--handle-timestamp ()
  "Return a public timestamp for handle metadata."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun consent--handle-symbol (name)
  "Return NAME as an Consent Scheme metadata symbol."
  (consent--intern-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent--handle-field (name &rest values)
  "Return a Scheme-readable handle metadata field."
  (cons (consent--handle-symbol name) values))

(defun consent--handle-owner-from-context (context)
  "Return the owner metadata for a handle created in CONTEXT."
  (when-let ((session-id
              (and context
                   (consent--eval-context-session-id context))))
    (list (consent--handle-symbol "session")
          (consent--handle-symbol session-id))))

(defun consent--safe-project-root (project)
  "Return PROJECT's root as a directory string, or nil."
  (condition-case nil
      (when project
        (file-name-as-directory (expand-file-name (project-root project))))
    (error nil)))

(defun consent--handle-source-for (kind object)
  "Return Scheme-readable source metadata for host OBJECT of KIND."
  (pcase kind
    ('buffer
     (list
      (consent--handle-field
       "buffer-name"
       (if (buffer-live-p object) (buffer-name object) consent-false))
      (consent--handle-field
       "file"
       (if (and (buffer-live-p object)
                (buffer-local-value 'buffer-file-name object))
           (buffer-local-value 'buffer-file-name object)
         consent-false))))
    ('window
     (list
      (consent--handle-field
       "window-buffer"
       (if (window-live-p object)
           (buffer-name (window-buffer object))
         consent-false))))
    ('frame
     (list
      (consent--handle-field
       "frame-name"
       (if (frame-live-p object)
           (or (frame-parameter object 'name)
               consent-false)
         consent-false))))
    ('project
     (list
      (consent--handle-field
       "project-root"
       (or (consent--safe-project-root object)
           consent-false))))
    ('file
     (list
      (consent--handle-field
       "path"
       (or (plist-get object :path) consent-false))
      (consent--handle-field
       "resolved-path"
       (or (plist-get object :resolved-path) consent-false))))
    ('process
     (list
      (consent--handle-field
       "process-name"
       (or (consent--process-object-name object)
           consent-false))
      (consent--handle-field
       "command"
       (or (consent--process-object-command object)
           consent-false))))
    ('network-stream
     (list
      (consent--handle-field
       "url"
       (or (plist-get object :url) consent-false))))
    (_ nil)))

(defun consent--handle-durable-reference-for (kind source)
  "Return durable-reference metadata for KIND and SOURCE."
  (pcase kind
    ((or 'buffer 'project 'file)
     source)
    (_ nil)))

(defun consent--initialize-handle-entry! (entry id kind object)
  "Populate lifecycle metadata on ENTRY for handle ID, KIND, and OBJECT."
  (let* ((timestamp (consent--handle-timestamp))
         (source (consent--handle-source-for kind object)))
    (setf (consent--handle-entry-id entry) id)
    (setf (consent--handle-entry-status entry) 'live)
    (setf (consent--handle-entry-owner entry)
          (consent--handle-owner-from-context
           consent--handle-registration-context))
    (setf (consent--handle-entry-created-by entry)
          consent--handle-registration-created-by)
    (setf (consent--handle-entry-created-at entry) timestamp)
    (setf (consent--handle-entry-last-validated entry) timestamp)
    (setf (consent--handle-entry-source entry) source)
    (setf (consent--handle-entry-durable-reference entry)
          (consent--handle-durable-reference-for kind source))
    entry))

(defun consent--register-handle (kind object)
  "Register live host OBJECT of KIND and return an opaque Scheme handle."
  (let ((id (format "h-%d" (cl-incf consent--next-handle-number))))
    (puthash
     id
     (consent--initialize-handle-entry!
      (consent--make-handle-entry kind object)
      id kind object)
     consent--handle-registry)
    (consent--make-handle kind id)))

(defun consent--scheme-boolean-value (value)
  "Return the canonical Scheme boolean for host truth VALUE."
  (if value consent-true consent-false))

(defun consent--scheme-integer (value)
  "Return exact integer datum for host integer VALUE."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent--scheme-symbol (symbol)
  "Return Consent Scheme symbol datum for host SYMBOL."
  (consent--intern-symbol (symbol-name symbol)))

(defun consent--maybe-string (value)
  "Return VALUE as a copied string datum, or #f when VALUE is nil."
  (if value (substring-no-properties value) consent-false))

(defun consent--search-symbol (name)
  "Return NAME as an Consent Scheme search datum symbol."
  (consent--syntax-symbol name))

(defun consent--search-field (name &rest values)
  "Return a Scheme-readable search field NAME with VALUES."
  (cons (consent--search-symbol name) values))

(defun consent--search-option-name (datum description)
  "Return DATUM as a search option name string for DESCRIPTION."
  (cond
   ((consent-symbol-p datum)
    (consent-symbol-name datum))
   ((stringp datum)
    datum)
   (t
    (consent--eval-error
     "%s option name must be a symbol or string, got %s"
     description
     (consent-value->external datum)))))

(defun consent--search-options (datum description)
  "Return DATUM as an alist of search option names to values."
  (let (options)
    (dolist (entry (consent--proper-list-elements datum description)
                   (nreverse options))
      (let ((elements (consent--proper-list-elements entry description)))
        (unless (= (length elements) 2)
          (consent--eval-error
           "%s option entries must have exactly two fields" description))
        (push (cons (consent--search-option-name
                     (car elements) description)
                    (cadr elements))
              options)))))

(defun consent--search-option (options name default)
  "Return option NAME from OPTIONS, or DEFAULT."
  (let ((entry (assoc name options)))
    (if entry (cdr entry) default)))

(defun consent--search-option-integer
    (options name default description)
  "Return non-negative integer search option NAME."
  (let ((value (consent--search-option options name default)))
    (unless (and (consent-number-p value)
                 (eq (consent-number-kind value) 'integer)
                 (eq (consent-number-exactness value) 'exact)
                 (>= (consent-number-value value) 0))
      (consent--eval-error
       "%s option %s expected a non-negative exact integer, got %s"
       description
       name
       (consent-value->external value)))
    (consent-number-value value)))

(defun consent--search-option-boolean
    (options name default description)
  "Return boolean search option NAME."
  (let ((value (consent--search-option options name default)))
    (cond
     ((eq value consent-true) t)
     ((eq value consent-false) nil)
     (t
      (consent--eval-error
       "%s option %s expected a boolean, got %s"
       description
       name
       (consent-value->external value))))))

(defun consent--search-limit (options description)
  "Return the result limit from OPTIONS for DESCRIPTION."
  (consent--search-option-integer
   options
   "limit"
   (consent--scheme-integer consent-search-default-limit)
   description))

(defun consent--search-preview-limit (options description)
  "Return the preview limit from OPTIONS for DESCRIPTION."
  (consent--search-option-integer
   options
   "max-preview"
   (consent--scheme-integer
    consent-search-default-preview-characters)
   description))

(defun consent--search-file-byte-limit (options description)
  "Return the file byte limit from OPTIONS for DESCRIPTION."
  (consent--search-option-integer
   options
   "max-file-bytes"
   (consent--scheme-integer
    consent-search-default-maximum-file-bytes)
   description))

(defun consent--search-file-limit (options description)
  "Return the project file count limit from OPTIONS for DESCRIPTION."
  (consent--search-option-integer
   options
   "file-limit"
   (consent--scheme-integer consent-search-default-file-limit)
   description))

(defun consent--search-case-fold-p (options description)
  "Return non-nil when OPTIONS request case-folded search."
  (consent--search-option-boolean
   options "case-fold" consent-false description))

(defun consent--search-include-generated-p (options description)
  "Return non-nil when OPTIONS request generated directories."
  (or (consent--search-option-boolean
       options "include-generated" consent-false description)
      (consent--search-option-boolean
       options "include-ignored" consent-false description)))

(defun consent--search-include-binary-p (options description)
  "Return non-nil when OPTIONS request binary files."
  (consent--search-option-boolean
   options "include-binary" consent-false description))

(defun consent--search-truncate-preview (preview limit)
  "Return PREVIEW truncated to LIMIT characters."
  (let ((clean (substring-no-properties preview)))
    (if (<= (length clean) limit)
        clean
      (concat (substring clean 0 limit) "..."))))

(defun consent--search-relative-file (file root)
  "Return FILE relative to ROOT, or #f when either is nil."
  (if (and file root)
      (file-relative-name (expand-file-name file)
                          (file-name-as-directory (expand-file-name root)))
    consent-false))

(defun consent--search-result-datum
    (source buffer file root line column start end preview)
  "Return a Scheme-readable search result datum."
  (list
   (consent--search-symbol "search-result")
   (consent--search-field
    "source" (consent--search-symbol (symbol-name source)))
   (consent--search-field
    "buffer" (if buffer (buffer-name buffer) consent-false))
   (consent--search-field
    "file" (if file (expand-file-name file) consent-false))
   (consent--search-field
    "relative-file" (consent--search-relative-file file root))
   (consent--search-field "line" (consent--scheme-integer line))
   (consent--search-field "column" (consent--scheme-integer column))
   (consent--search-field "start" (consent--scheme-integer start))
   (consent--search-field "end" (consent--scheme-integer end))
   (consent--search-field "preview" preview)))

(defun consent--search-buffer-results
    (buffer pattern options source &optional file root)
  "Return search result datums for PATTERN in BUFFER."
  (let ((limit (consent--search-limit options "search"))
        (preview-limit (consent--search-preview-limit options "search"))
        (case-fold-search (consent--search-case-fold-p options "search"))
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
                      (consent--search-truncate-preview
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))
                       preview-limit)))
                (push
                 (consent--search-result-datum
                  source buffer file root line column start end preview)
                 results)
                (when (and (= start end)
                           (not (eobp)))
                  (forward-char 1))))))))
    (nreverse results)))

(defun consent--search-project-root (operation)
  "Return current project root for OPERATION."
  (let ((root (consent--current-project-root-or-error operation)))
    (when (file-remote-p root)
      (consent--eval-error
       "%s cannot search remote project root: %s" operation root))
    root))

(defun consent--search-project-files-raw (root)
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

(defun consent--search-generated-file-p (file root)
  "Return non-nil when FILE is under a generated/runtime directory."
  (let ((parts (split-string
                (file-relative-name (expand-file-name file)
                                    (file-name-as-directory
                                     (expand-file-name root)))
                "/" t)))
    (seq-some
     (lambda (part)
       (member part consent-search-generated-directories))
     parts)))

(defun consent--search-file-size (file)
  "Return FILE size in bytes, or nil."
  (file-attribute-size (file-attributes file)))

(defun consent--search-binary-file-p (file)
  "Return non-nil when FILE appears to contain binary data."
  (let ((limit (min (or (consent--search-file-size file) 0) 4096)))
    (when (> limit 0)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 limit)
        (goto-char (point-min))
        (search-forward (string 0) nil t)))))

(defun consent--search-project-file-allowed-p
    (file root options)
  "Return non-nil when FILE may be inspected under ROOT and OPTIONS."
  (let ((maximum-bytes
         (consent--search-file-byte-limit options "project search")))
    (and (file-regular-p file)
         (not (file-remote-p file))
         (file-in-directory-p (expand-file-name file)
                              (file-name-as-directory
                               (expand-file-name root)))
         (or (consent--search-include-generated-p
              options "project search")
             (not (consent--search-generated-file-p file root)))
         (let ((size (consent--search-file-size file)))
           (and size (<= size maximum-bytes)))
         (or (consent--search-include-binary-p options "project search")
             (not (consent--search-binary-file-p file))))))

(defun consent--search-project-files (root options &optional file-limit)
  "Return guarded absolute project files under ROOT."
  (let ((limit (or file-limit
                   (consent--search-limit options "project files")))
        files)
    (when (> limit 0)
      (catch 'done
        (dolist (file (sort (consent--search-project-files-raw root)
                            #'string<))
          (when (consent--search-project-file-allowed-p file root options)
            (push file files)
            (when (>= (length files) limit)
              (throw 'done nil))))))
    (nreverse files)))

(defun consent--project-file-datum (file root)
  "Return a Scheme-readable project file datum for FILE."
  (list
   (consent--search-symbol "project-file")
   (consent--search-field "file" (expand-file-name file))
   (consent--search-field
    "relative-file" (consent--search-relative-file file root))
   (consent--search-field
    "size" (consent--scheme-integer
            (or (consent--search-file-size file) 0)))))

(defun consent--capability-exact-integer (datum description)
  "Return DATUM as a host exact integer for DESCRIPTION."
  (unless (and (consent-number-p datum)
               (eq (consent-number-kind datum) 'integer)
               (eq (consent-number-exactness datum) 'exact))
    (consent--eval-error
     "%s expected an exact integer, got %s"
     description
     (consent-value->external datum)))
  (consent-number-value datum))

(defun consent--capability-string (datum description)
  "Return DATUM as a host string for DESCRIPTION."
  (unless (stringp datum)
    (consent--eval-error
     "%s expected a string, got %s"
     description
     (consent-value->external datum)))
  (substring-no-properties datum))

(defun consent--capability-name-symbol (datum description)
  "Return DATUM as an existing Emacs symbol for DESCRIPTION, or nil."
  (let ((name
         (cond
          ((consent-symbol-p datum)
           (consent-symbol-name datum))
          ((stringp datum)
           datum)
          (t
           (consent--eval-error
            "%s expected a symbol or string, got %s"
            description
            (consent-value->external datum))))))
    (intern-soft name)))

(defun consent--capability-symbol-name (datum description)
  "Return DATUM as a Scheme or Emacs symbol name for DESCRIPTION."
  (cond
   ((consent-symbol-p datum)
    (consent-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)
   (t
    (consent--eval-error
     "%s expected a symbol or string, got %s"
     description
     (consent-value->external datum)))))

(defun consent--capability-direction-name (datum description)
  "Return a supported window split direction name for DATUM."
  (let ((name (consent--capability-symbol-name datum description)))
    (unless (member name '("below" "right"))
      (consent--eval-error
       "%s expected 'below or 'right, got %s"
       description
       (consent-value->external datum)))
    name))

(defun consent--command-whitelist-entry (command)
  "Return the whitelist entry for COMMAND, or nil."
  (seq-find
   (lambda (entry)
     (eq (if (consp entry) (car entry) entry)
         command))
   consent-command-whitelist))

(defun consent--command-whitelist-plist (entry)
  "Return the property list carried by whitelist ENTRY."
  (if (consp entry)
      (cdr entry)
    nil))

(defun consent--command-name (datum)
  "Return command name DATUM as a string."
  (consent--capability-symbol-name datum "command-call! name"))

(defun consent--command-symbol (datum)
  "Return command DATUM as an interned Emacs symbol, or nil."
  (intern-soft (consent--command-name datum)))

(defun consent--command-call-deny (command reason context)
  "Deny COMMAND for REASON through the command-process policy path."
  (consent-policy-deny
   'command-process
   "command-call!"
   `((library . "(emacs command)")
     (capability . "command-call!")
     (command . ,command))
   context
   reason
   'capability-call))

(defun consent--command-argument-value (datum)
  "Convert a Scheme DATUM into a conservative Emacs command argument."
  (cond
   ((eq datum consent-true) t)
   ((eq datum consent-false) nil)
   ((stringp datum) (substring-no-properties datum))
   ((and (consent-number-p datum)
         (eq (consent-number-kind datum) 'integer)
         (eq (consent-number-exactness datum) 'exact))
    (consent-number-value datum))
   ((consent-symbol-p datum)
    (intern (consent-symbol-name datum)))
   ((null datum) nil)
   ((consp datum)
    (mapcar #'consent--command-argument-value datum))
   (t
    (consent--eval-error
     "command-call! unsupported argument: %s"
     (consent-value->external datum)))))

(defun consent--command-minimum-arity (command)
  "Return COMMAND's minimum noninteractive arity, or 0 if unknown."
  (condition-case nil
      (let ((arity (func-arity command)))
        (cond
         ((consp arity) (car arity))
         ((integerp arity) arity)
         (t 0)))
    (error 0)))

(defun consent--handle-entry-for (value kind description)
  "Return private registry entry for handle VALUE of KIND."
  (unless (consent-handle-p value)
    (consent--eval-error
     "%s expected %s handle, got %s"
     description kind (consent-value->external value)))
  (unless (eq (consent-handle-kind value) kind)
    (consent--eval-error
     "%s expected %s handle, got %s handle"
     description kind (consent-handle-kind value)))
  (let ((entry (gethash (consent-handle-id value)
                        consent--handle-registry)))
    (unless (and entry (eq (consent--handle-entry-kind entry) kind))
      (consent--eval-error
       "unknown %s handle: %s"
       kind (consent-handle-id value)))
    entry))

;;;###autoload
(defun consent-capability-handle-known-p (handle)
  "Return non-nil when HANDLE is present in the private registry."
  (and (consent-handle-p handle)
       (gethash (consent-handle-id handle)
                consent--handle-registry)
       t))

(defun consent-capability--entry-live-p (entry)
  "Return non-nil when ENTRY still points at a live host object."
  (and (not (memq (consent--handle-entry-status entry)
                  '(closed stale expired revoked released)))
       (pcase (consent--handle-entry-kind entry)
         ('buffer
          (buffer-live-p (consent--handle-entry-object entry)))
         ('window
          (window-live-p (consent--handle-entry-object entry)))
         ('frame
          (frame-live-p (consent--handle-entry-object entry)))
         ('process
          (consent--process-object-live-p
           (consent--handle-entry-object entry)))
         ('network-stream
          (consent--network-stream-object-live-p
           (consent--handle-entry-object entry)))
         ('file
          (let* ((object (consent--handle-entry-object entry))
                 (operation (plist-get object :operation))
                 (status (plist-get object :status))
                 (path (or (plist-get object :resolved-path)
                           (plist-get object :path))))
            (and (not (memq status '(closed stale expired revoked released)))
                 (or (memq operation '(create write delete metadata))
                     (and path (file-exists-p path))))))
         ('project
          (let ((root (consent--safe-project-root
                       (consent--handle-entry-object entry))))
            (and root
                 (not (file-remote-p root))
                 (file-directory-p root))))
         (_
          t))))

(defun consent-capability--revalidate-entry! (entry)
  "Refresh ENTRY lifecycle status and return ENTRY."
  (let ((live (consent-capability--entry-live-p entry))
        (timestamp (consent--handle-timestamp)))
    (setf (consent--handle-entry-status entry)
          (if live 'live 'stale))
    (setf (consent--handle-entry-last-validated entry) timestamp)
    (when live
      (let* ((kind (consent--handle-entry-kind entry))
             (source (consent--handle-source-for
                      kind
                      (consent--handle-entry-object entry))))
        (setf (consent--handle-entry-source entry) source)
        (setf (consent--handle-entry-durable-reference entry)
              (consent--handle-durable-reference-for kind source))))
    entry))

(defun consent-capability--release-entry! (entry)
  "Mark ENTRY released and return it."
  (let ((timestamp (consent--handle-timestamp)))
    (setf (consent--handle-entry-status entry) 'released)
    (setf (consent--handle-entry-last-validated entry) timestamp)
    (setf (consent--handle-entry-released-at entry) timestamp)
    entry))

(defun consent-capability--handle-id (value description)
  "Return handle id string from VALUE for DESCRIPTION."
  (cond
   ((consent-handle-p value)
    (consent-handle-id value))
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (consent--eval-error
     "%s expected a handle id or handle, got %s"
     description
     (consent-value->external value)))))

(defun consent-capability--handle-entry (value description)
  "Return registry entry named by VALUE, or nil when absent."
  (gethash
   (consent-capability--handle-id value description)
   consent--handle-registry))

(defun consent-capability-handle-metadata (entry)
  "Return ENTRY as an inspectable Scheme-readable handle record."
  (append
   (list
    (consent--handle-symbol "handle")
    (consent--handle-field
     "id" (consent--handle-symbol
           (consent--handle-entry-id entry)))
    (consent--handle-field
     "kind" (consent--handle-symbol
             (consent--handle-entry-kind entry)))
    (consent--handle-field
     "status" (consent--handle-symbol
               (consent--handle-entry-status entry))))
   (when (consent--handle-entry-owner entry)
     (list
      (apply #'consent--handle-field
             "owner"
             (consent--handle-entry-owner entry))))
   (when (consent--handle-entry-created-by entry)
     (list
      (consent--handle-field
       "created-by"
       (consent--handle-entry-created-by entry))))
   (when (consent--handle-entry-created-at entry)
     (list
      (consent--handle-field
       "created-at"
       (consent--handle-entry-created-at entry))))
   (when (consent--handle-entry-last-validated entry)
     (list
      (consent--handle-field
       "last-validated"
       (consent--handle-entry-last-validated entry))))
   (when (consent--handle-entry-source entry)
     (list
      (apply #'consent--handle-field
             "source"
             (consent--handle-entry-source entry))))
   (when (consent--handle-entry-durable-reference entry)
     (list
      (apply #'consent--handle-field
             "durable-reference"
             (consent--handle-entry-durable-reference entry))))
   (when (consent--handle-entry-released-at entry)
     (list
      (consent--handle-field
       "released-at"
       (consent--handle-entry-released-at entry))))))

;;;###autoload
(defun consent-capability-handle-ref (handle-or-id)
  "Return lifecycle metadata for HANDLE-OR-ID, or nil when absent."
  (when-let ((entry (consent-capability--handle-entry
                     handle-or-id "handle-ref")))
    (consent-capability-handle-metadata
     (consent-capability--revalidate-entry! entry))))

;;;###autoload
(defun consent-capability-handle-kind (handle-or-id)
  "Return HANDLE-OR-ID's kind symbol, or nil when it is unknown."
  (cond
   ((consent-handle-p handle-or-id)
    (consent--handle-symbol (consent-handle-kind handle-or-id)))
   ((consent-capability--handle-entry handle-or-id "handle-kind")
    (consent--handle-symbol
     (consent--handle-entry-kind
      (consent-capability--handle-entry handle-or-id "handle-kind"))))
   (t nil)))

;;;###autoload
(defun consent-capability-revalidate-handle (handle-or-id)
  "Revalidate HANDLE-OR-ID and return lifecycle metadata, or nil."
  (when-let ((entry (consent-capability--handle-entry
                     handle-or-id "handle-revalidate")))
    (consent-capability-handle-metadata
     (consent-capability--revalidate-entry! entry))))

;;;###autoload
(defun consent-capability-handle-live-p (handle)
  "Return non-nil when HANDLE names a currently live host object."
  (when-let ((entry (consent-capability--handle-entry
                     handle "handle-live?")))
    (eq (consent--handle-entry-status
         (consent-capability--revalidate-entry! entry))
        'live)))

;;;###autoload
(defun consent-capability-release-handle-datum (handle-or-id)
  "Release HANDLE-OR-ID and return released lifecycle metadata, or nil."
  (let* ((id (consent-capability--handle-id
              handle-or-id "handle-release!"))
         (entry (gethash id consent--handle-registry)))
    (when entry
      (consent-capability--release-entry! entry)
      (remhash id consent--handle-registry)
      (consent-capability-handle-metadata entry))))

;;;###autoload
(defun consent-capability-release-handle (handle)
  "Release HANDLE from the private registry.
Return non-nil when a registry entry was removed."
  (and (consent-capability-release-handle-datum handle) t))

;;;###autoload
(defun consent-capability-release-handles (handles)
  "Release every handle in HANDLES and return the removed count."
  (let ((count 0))
    (dolist (handle handles count)
      (when (consent-capability-release-handle handle)
        (cl-incf count)))))

(defun consent--live-buffer-for-handle (value description)
  "Return live Emacs buffer for handle VALUE."
  (let* ((entry (consent--handle-entry-for value 'buffer description))
         (buffer (consent--handle-entry-object entry)))
    (consent-capability--revalidate-entry! entry)
    (unless (buffer-live-p buffer)
      (consent--eval-error
       "stale buffer handle: %s" (consent-handle-id value)))
    buffer))

(defun consent--live-window-for-handle (value description)
  "Return live Emacs window for handle VALUE."
  (let* ((entry (consent--handle-entry-for value 'window description))
         (window (consent--handle-entry-object entry)))
    (consent-capability--revalidate-entry! entry)
    (unless (window-live-p window)
      (consent--eval-error
       "stale window handle: %s" (consent-handle-id value)))
    window))

(defun consent--live-frame-for-handle (value description)
  "Return live Emacs frame for handle VALUE."
  (let* ((entry (consent--handle-entry-for value 'frame description))
         (frame (consent--handle-entry-object entry)))
    (consent-capability--revalidate-entry! entry)
    (unless (frame-live-p frame)
      (consent--eval-error
       "stale frame handle: %s" (consent-handle-id value)))
    frame))

(defun consent--project-for-handle (value description)
  "Return registered Emacs project for handle VALUE."
  (let ((entry (consent--handle-entry-for value 'project description)))
    (unless (eq (consent--handle-entry-status
                 (consent-capability--revalidate-entry! entry))
                'live)
      (consent--eval-error
       "stale project handle: %s" (consent-handle-id value)))
    (consent--handle-entry-object entry)))

(defun consent--live-process-for-handle (value description)
  "Return live private process object for handle VALUE."
  (let* ((entry (consent--handle-entry-for value 'process description))
         (object (consent--handle-entry-object entry)))
    (consent-capability--revalidate-entry! entry)
    (unless (consent--process-object-live-p object)
      (consent--eval-error
       "stale process handle: %s" (consent-handle-id value)))
    object))

(defun consent--buffer-handle (buffer)
  "Return an opaque handle for BUFFER."
  (consent--register-handle 'buffer buffer))

(defun consent--window-handle (window)
  "Return an opaque handle for WINDOW."
  (consent--register-handle 'window window))

(defun consent--frame-handle (frame)
  "Return an opaque handle for FRAME."
  (consent--register-handle 'frame frame))

(defun consent--project-handle (project)
  "Return an opaque handle for PROJECT."
  (consent--register-handle 'project project))

(defun consent--process-handle (process)
  "Return an opaque handle for PROCESS."
  (consent--register-handle 'process process))

(defun consent--primitive-emacs-current-buffer (arguments context)
  "Primitive emacs-current-buffer."
  (consent--authorize-emacs-capability
   "emacs-current-buffer" arguments context)
  (consent--buffer-handle (current-buffer)))

(defun consent--primitive-buffer-name (arguments context)
  "Primitive buffer-name over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-name" arguments context)
  (buffer-name
   (consent--live-buffer-for-handle (car arguments) "buffer-name")))

(defun consent--primitive-buffer-file-name (arguments context)
  "Primitive buffer-file-name over ARGUMENTS."
  (consent--authorize-emacs-capability
   "buffer-file-name" arguments context)
  (consent--maybe-string
   (buffer-local-value
    'buffer-file-name
    (consent--live-buffer-for-handle
     (car arguments) "buffer-file-name"))))

(defun consent--primitive-buffer-major-mode (arguments context)
  "Primitive buffer-major-mode over ARGUMENTS."
  (consent--authorize-emacs-capability
   "buffer-major-mode" arguments context)
  (consent--scheme-symbol
   (buffer-local-value
    'major-mode
    (consent--live-buffer-for-handle
     (car arguments) "buffer-major-mode"))))

(defun consent--primitive-buffer-point (arguments context)
  "Primitive buffer-point over ARGUMENTS."
  (consent--authorize-emacs-capability
   "buffer-point" arguments context)
  (consent--scheme-integer
   (with-current-buffer
       (consent--live-buffer-for-handle (car arguments) "buffer-point")
     (point))))

(defun consent--primitive-buffer-text (arguments context)
  "Primitive buffer-text over ARGUMENTS."
  (consent--authorize-emacs-capability
   "buffer-text" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-text"))
         (start (consent--capability-exact-integer
                 (cadr arguments) "buffer-text start"))
         (end (consent--capability-exact-integer
               (caddr arguments) "buffer-text end")))
    (with-current-buffer buffer
      (unless (and (<= (point-min) start)
                   (<= start end)
                   (<= end (point-max)))
        (consent--eval-error
         "buffer-text range outside buffer: %d..%d" start end))
      (buffer-substring-no-properties start end))))

(defun consent--check-buffer-range (buffer start end description)
  "Signal unless START and END are a valid range in BUFFER for DESCRIPTION."
  (with-current-buffer buffer
    (unless (and (<= (point-min) start)
                 (<= start end)
                 (<= end (point-max)))
      (consent--eval-error
       "%s range outside buffer: %d..%d" description start end))))

(defun consent--check-buffer-position (buffer position description)
  "Signal unless POSITION is valid in BUFFER for DESCRIPTION."
  (with-current-buffer buffer
    (unless (and (<= (point-min) position)
                 (<= position (point-max)))
      (consent--eval-error
       "%s position outside buffer: %d" description position))))

(defun consent--buffer-target-file (buffer)
  "Return BUFFER's file name, or nil when BUFFER is not file-backed."
  (buffer-local-value 'buffer-file-name buffer))

(defun consent--buffer-target-fields (buffer)
  "Return Scheme-readable audit fields describing BUFFER."
  `((target-buffer . ,(buffer-name buffer))
    (target-file . ,(or (consent--buffer-target-file buffer)
                        consent-false))))

(defun consent--internal-buffer-p (buffer)
  "Return non-nil when BUFFER is an internal or special Emacs buffer."
  (let ((name (buffer-name buffer)))
    (or (string-prefix-p " " name)
        (and (> (length name) 1)
             (eq (aref name 0) ?*)
             (eq (aref name (1- (length name))) ?*)))))

(defun consent--remote-buffer-p (buffer)
  "Return non-nil when BUFFER is backed by a remote file or directory."
  (with-current-buffer buffer
    (or (and buffer-file-name (file-remote-p buffer-file-name))
        (and default-directory (file-remote-p default-directory)))))

(defun consent--check-buffer-edit-target (buffer operation)
  "Signal unless BUFFER is an ordinary local target for OPERATION."
  (cond
   ((minibufferp buffer)
    (consent--eval-error
     "%s cannot edit minibuffer: %s" operation (buffer-name buffer)))
   ((consent--internal-buffer-p buffer)
    (consent--eval-error
     "%s cannot edit internal buffer: %s" operation (buffer-name buffer)))
   ((consent--remote-buffer-p buffer)
    (consent--eval-error
     "%s cannot edit remote buffer: %s" operation (buffer-name buffer)))))

(defun consent--record-buffer-edit-fields
    (buffer start end before-text after-text)
  "Record audit fields for an edit to BUFFER from START to END."
  (consent--add-emacs-capability-result-fields
   (append
    (consent--buffer-target-fields buffer)
    `((region . (,start ,end))
      (before-text . ,before-text)
      (after-text . ,after-text)))))

(defun consent--apply-buffer-edit
    (buffer start end replacement operation)
  "Apply one transactional BUFFER edit for OPERATION.
The edit replaces START..END with REPLACEMENT, records metadata, and
creates undo boundaries around the atomic change group."
  (consent--check-buffer-edit-target buffer operation)
  (consent--check-buffer-range buffer start end operation)
  (let ((before-text
         (with-current-buffer buffer
           (buffer-substring-no-properties start end))))
    (consent--record-buffer-edit-fields
     buffer start end before-text replacement)
    (with-current-buffer buffer
      (undo-boundary)
      (atomic-change-group
        (delete-region start end)
        (goto-char start)
        (insert replacement))
      (undo-boundary))))

(defun consent--primitive-buffer-insert! (arguments context)
  "Primitive buffer-insert! over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-insert!" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-insert!"))
         (position (consent--capability-exact-integer
                    (cadr arguments) "buffer-insert! position"))
         (text (consent--capability-string
                (caddr arguments) "buffer-insert! text")))
    (consent--check-buffer-position buffer position "buffer-insert!")
    (consent--apply-buffer-edit
     buffer position position text "buffer-insert!")
    consent-unspecified))

(defun consent--primitive-buffer-delete! (arguments context)
  "Primitive buffer-delete! over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-delete!" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-delete!"))
         (start (consent--capability-exact-integer
                 (cadr arguments) "buffer-delete! start"))
         (end (consent--capability-exact-integer
               (caddr arguments) "buffer-delete! end")))
    (consent--apply-buffer-edit
     buffer start end "" "buffer-delete!")
    consent-unspecified))

(defun consent--primitive-buffer-replace! (arguments context)
  "Primitive buffer-replace! over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-replace!" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-replace!"))
         (start (consent--capability-exact-integer
                 (cadr arguments) "buffer-replace! start"))
         (end (consent--capability-exact-integer
               (caddr arguments) "buffer-replace! end"))
         (text (consent--capability-string
                (cadddr arguments) "buffer-replace! text")))
    (consent--apply-buffer-edit
     buffer start end text "buffer-replace!")
    consent-unspecified))

(defun consent--primitive-buffer-save! (arguments context)
  "Primitive buffer-save! over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-save!" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-save!"))
         (file (consent--buffer-target-file buffer)))
    (consent--check-buffer-edit-target buffer "buffer-save!")
    (unless file
      (consent--eval-error
       "buffer-save! requires a file-backed buffer: %s"
       (buffer-name buffer)))
    (consent--add-emacs-capability-result-fields
     (append
      (consent--buffer-target-fields buffer)
      `((modified-before-save . ,(with-current-buffer buffer
                                   (buffer-modified-p))))))
    (with-current-buffer buffer
      (save-buffer))
    consent-unspecified))

(defun consent--primitive-buffer-switch! (arguments context)
  "Primitive buffer-switch! over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-switch!" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-switch!"))
         (window (selected-window)))
    (when (minibufferp buffer)
      (consent--eval-error
       "buffer-switch! cannot switch to minibuffer: %s"
       (buffer-name buffer)))
    (consent--add-emacs-capability-result-fields
     (append
      (consent--buffer-target-fields buffer)
      `((target-window . ,(consent--window-handle window))
        (previous-buffer . ,(buffer-name (window-buffer window))))))
    (set-window-buffer window buffer)
    consent-unspecified))

(defun consent--primitive-emacs-buffer-list (arguments context)
  "Primitive emacs-buffer-list."
  (consent--authorize-emacs-capability
   "emacs-buffer-list" arguments context)
  (mapcar #'consent--buffer-handle (buffer-list)))

(defun consent--primitive-emacs-window-list (arguments context)
  "Primitive emacs-window-list."
  (consent--authorize-emacs-capability
   "emacs-window-list" arguments context)
  (mapcar #'consent--window-handle (window-list nil 'no-minibuf)))

(defun consent--primitive-window-frame (arguments context)
  "Primitive window-frame over ARGUMENTS."
  (consent--authorize-emacs-capability "window-frame" arguments context)
  (consent--frame-handle
   (window-frame
    (consent--live-window-for-handle (car arguments) "window-frame"))))

(defun consent--window-target-fields (window)
  "Return Scheme-readable audit fields describing WINDOW."
  `((target-window . ,(consent--window-handle window))
    (target-buffer . ,(buffer-name (window-buffer window)))
    (target-frame . ,(consent--frame-handle (window-frame window)))))

(defun consent--check-window-session-target (window operation)
  "Signal unless WINDOW can be used for OPERATION."
  (when (window-minibuffer-p window)
    (consent--eval-error
     "%s cannot target minibuffer window" operation)))

(defun consent--primitive-window-select! (arguments context)
  "Primitive window-select! over ARGUMENTS."
  (consent--authorize-emacs-capability "window-select!" arguments context)
  (let ((window (consent--live-window-for-handle
                 (car arguments) "window-select!")))
    (consent--check-window-session-target window "window-select!")
    (consent--add-emacs-capability-result-fields
     (append
      (consent--window-target-fields window)
      `((previous-window . ,(consent--window-handle
                             (selected-window))))))
    (select-window window)
    consent-unspecified))

(defun consent--primitive-window-split! (arguments context)
  "Primitive window-split! over ARGUMENTS."
  (consent--authorize-emacs-capability "window-split!" arguments context)
  (let* ((direction
          (consent--capability-direction-name
           (car arguments) "window-split! direction"))
         (side (intern direction))
         (source-window (selected-window)))
    (consent--check-window-session-target source-window "window-split!")
    (let ((new-window (split-window source-window nil side)))
      (consent--add-emacs-capability-result-fields
       `((source-window . ,(consent--window-handle source-window))
         (target-window . ,(consent--window-handle new-window))
         (direction . ,(intern direction))))
      (consent--window-handle new-window))))

(defun consent--primitive-window-delete! (arguments context)
  "Primitive window-delete! over ARGUMENTS."
  (consent--authorize-emacs-capability "window-delete!" arguments context)
  (let ((window (consent--live-window-for-handle
                 (car arguments) "window-delete!")))
    (consent--check-window-session-target window "window-delete!")
    (when (<= (length (window-list (window-frame window) 'no-minibuf)) 1)
      (consent--eval-error
       "window-delete! cannot delete the sole ordinary window"))
    (consent--add-emacs-capability-result-fields
     (consent--window-target-fields window))
    (delete-window window)
    consent-unspecified))

(defun consent--primitive-emacs-current-frame (arguments context)
  "Primitive emacs-current-frame."
  (consent--authorize-emacs-capability
   "emacs-current-frame" arguments context)
  (consent--frame-handle (selected-frame)))

(defun consent--primitive-emacs-frame-list (arguments context)
  "Primitive emacs-frame-list."
  (consent--authorize-emacs-capability
   "emacs-frame-list" arguments context)
  (mapcar #'consent--frame-handle (frame-list)))

(defun consent--primitive-frame-name (arguments context)
  "Primitive frame-name over ARGUMENTS."
  (consent--authorize-emacs-capability "frame-name" arguments context)
  (consent--maybe-string
   (frame-parameter
    (consent--live-frame-for-handle (car arguments) "frame-name")
    'name)))

(defun consent--primitive-emacs-current-project (arguments context)
  "Primitive emacs-current-project."
  (consent--authorize-emacs-capability
   "emacs-current-project" arguments context)
  (let ((project (project-current nil)))
    (if project
        (consent--project-handle project)
      consent-false)))

(defun consent--primitive-project-root (arguments context)
  "Primitive project-root over optional project handle ARGUMENTS."
  (consent--authorize-emacs-capability "project-root" arguments context)
  (let ((project
         (if arguments
             (consent--project-for-handle
              (car arguments) "project-root")
           (project-current nil))))
    (if project
        (file-name-as-directory (expand-file-name (project-root project)))
      consent-false)))

(defun consent--current-project-root-or-error (operation)
  "Return the current project root, or signal for OPERATION."
  (let ((project (project-current nil)))
    (unless project
      (consent--eval-error
       "%s requires a current project" operation))
    (file-name-as-directory (expand-file-name (project-root project)))))

(defun consent--diff-buffer-text (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun consent--diff-file-text (path)
  "Return local file PATH contents as plain text, or an empty string."
  (if (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun consent--diff-buffer-datum (buffer)
  "Return a canonical diff datum for live BUFFER."
  (let ((file (consent--buffer-target-file buffer)))
    (when (and file (file-remote-p file))
      (consent--eval-error
       "buffer-diff cannot inspect remote file: %s" file))
    (let ((old-text (if file (consent--diff-file-text file)
                      (consent--diff-buffer-text buffer)))
          (new-text (consent--diff-buffer-text buffer))
          (old-label (or file (format "buffer:%s" (buffer-name buffer))))
          (new-label (format "buffer:%s" (buffer-name buffer))))
      (consent-diff-from-strings
       'buffer
       old-label
       new-label
       old-text
       new-text))))

(defun consent--diff-file-datum (path)
  "Return a canonical diff datum for local file PATH."
  (let ((expanded (expand-file-name path)))
    (when (file-remote-p expanded)
      (consent--eval-error "file-diff cannot inspect remote file: %s"
                                expanded))
    (let* ((buffer (get-file-buffer expanded))
           (old-text (consent--diff-file-text expanded))
           (new-text (if (and buffer (buffer-live-p buffer))
                         (consent--diff-buffer-text buffer)
                       old-text))
           (new-label (if (and buffer (buffer-live-p buffer))
                          (format "buffer:%s" (buffer-name buffer))
                        expanded)))
      (consent-diff-from-strings
       'file expanded new-label old-text new-text))))

(defun consent--primitive-buffer-diff (arguments context)
  "Primitive buffer-diff over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-diff" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-diff"))
         (diff (consent--diff-buffer-datum buffer)))
    (consent--add-emacs-capability-result-fields
     (append
      (consent--buffer-target-fields buffer)
      `((changed . ,(if (consent-diff-changed-p diff) t nil)))))
    diff))

(defun consent--primitive-file-diff (arguments context)
  "Primitive file-diff over ARGUMENTS."
  (consent--authorize-emacs-capability "file-diff" arguments context)
  (let* ((path (expand-file-name
                (consent--capability-string
                 (car arguments) "file-diff path")))
         (diff (consent--diff-file-datum path)))
    (consent--add-emacs-capability-result-fields
     `((target-file . ,path)
       (changed . ,(if (consent-diff-changed-p diff) t nil))))
    diff))

(defun consent--primitive-project-diff (arguments context)
  "Primitive project-diff over ARGUMENTS."
  (consent--authorize-emacs-capability "project-diff" arguments context)
  (consent--proper-list-elements
   (car arguments) "project-diff options")
  (let ((root (consent--current-project-root-or-error "project-diff"))
        diffs)
    (dolist (buffer (buffer-list))
      (when-let ((file (and (buffer-live-p buffer)
                            (consent--buffer-target-file buffer))))
        (when (and (file-in-directory-p (expand-file-name file) root)
                   (with-current-buffer buffer (buffer-modified-p)))
          (let ((diff (consent--diff-buffer-datum buffer)))
            (when (consent-diff-changed-p diff)
              (push diff diffs))))))
    (setq diffs (nreverse diffs))
    (consent--add-emacs-capability-result-fields
     `((project-root . ,root)
       (result-count . ,(length diffs))))
    diffs))

(defun consent--primitive-vcs-root (arguments context)
  "Primitive vcs-root over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-root" arguments context)
  (let ((datum (consent-vcs-root-datum)))
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)))
    datum))

(defun consent--primitive-vcs-branch (arguments context)
  "Primitive vcs-branch over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-branch" arguments context)
  (let ((datum (consent-vcs-branch-datum)))
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)))
    datum))

(defun consent--primitive-vcs-status (arguments context)
  "Primitive vcs-status over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-status" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-status options")
  (let* ((datum (consent-vcs-status-datum (car arguments)))
         (entries (consent-vcs-field-value datum "entries" nil)))
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (result-count . ,(length entries))))
    datum))

(defun consent--primitive-vcs-diff (arguments context)
  "Primitive vcs-diff over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-diff" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-diff options")
  (let* ((datum (consent-vcs-diff-datum (car arguments)))
         (files (consent-vcs-field-value datum "files" nil)))
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (result-count . ,(length files))))
    datum))

(defun consent--primitive-vcs-recent-commits (arguments context)
  "Primitive vcs-recent-commits over ARGUMENTS."
  (consent--authorize-emacs-capability
   "vcs-recent-commits" arguments context)
  (let* ((count (consent--capability-exact-integer
                 (car arguments) "vcs-recent-commits count"))
         (commits (consent-vcs-recent-commits-datum count)))
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (result-count . ,(length commits))))
    commits))

(defun consent--primitive-vcs-yield (arguments context)
  "Primitive vcs-yield over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-yield" arguments context)
  (consent--add-emacs-capability-result-fields
   `((adapter . emacs-vcs)
     (yielded . t)))
  (consent-agent-io--primitive-yield arguments context))

(defun consent--record-vcs-mutation-result-fields (operation result)
  "Record audit fields for VCS mutation OPERATION returning RESULT."
  (let* ((status (consent-vcs-field-value result "status"))
         (outcome (consent-vcs-field-value result "value"))
         (outcome-status
          (and (consent-vcs--record-p outcome "vcs-outcome")
               (consent-vcs-field-value outcome "status"))))
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-vcs)
       (vcs-operation . ,operation)
       (vcs-result-status . ,status)
       (vcs-outcome . ,(or outcome-status consent-false))))))

(defun consent--primitive-vcs-stage! (arguments context)
  "Primitive vcs-stage! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-stage!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-stage! options")
  (let ((result (consent-vcs-stage-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'stage result)
    result))

(defun consent--primitive-vcs-unstage! (arguments context)
  "Primitive vcs-unstage! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-unstage!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-unstage! options")
  (let ((result (consent-vcs-unstage-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'unstage result)
    result))

(defun consent--primitive-vcs-commit! (arguments context)
  "Primitive vcs-commit! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-commit!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-commit! options")
  (let ((result (consent-vcs-commit-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'commit result)
    result))

(defun consent--primitive-vcs-branch-create! (arguments context)
  "Primitive vcs-branch-create! over ARGUMENTS."
  (consent--authorize-emacs-capability
   "vcs-branch-create!"
   arguments
   context)
  (consent--proper-list-elements
   (car arguments) "vcs-branch-create! options")
  (let ((result (consent-vcs-branch-create-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'branch-create result)
    result))

(defun consent--primitive-vcs-switch! (arguments context)
  "Primitive vcs-switch! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-switch!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-switch! options")
  (let ((result (consent-vcs-switch-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'switch result)
    result))

(defun consent--primitive-vcs-fetch! (arguments context)
  "Primitive vcs-fetch! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-fetch!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-fetch! options")
  (let ((result (consent-vcs-fetch-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'fetch result)
    result))

(defun consent--primitive-vcs-pull! (arguments context)
  "Primitive vcs-pull! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-pull!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-pull! options")
  (let ((result (consent-vcs-pull-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'pull result)
    result))

(defun consent--primitive-vcs-push! (arguments context)
  "Primitive vcs-push! over ARGUMENTS."
  (consent--authorize-emacs-capability "vcs-push!" arguments context)
  (consent--proper-list-elements (car arguments) "vcs-push! options")
  (let ((result (consent-vcs-push-datum (car arguments))))
    (consent--record-vcs-mutation-result-fields 'push result)
    result))

(defun consent--diagnostics-result-count (snapshot)
  "Return the number of diagnostics in SNAPSHOT."
  (length (consent-diagnostics-snapshot-diagnostics snapshot)))

(defun consent--primitive-buffer-diagnostics (arguments context)
  "Primitive buffer-diagnostics over ARGUMENTS."
  (consent--authorize-emacs-capability
   "buffer-diagnostics" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-diagnostics"))
         (snapshot
          (consent-diagnostics-buffer-snapshot buffer context)))
    (consent--add-emacs-capability-result-fields
     (append
      (consent--buffer-target-fields buffer)
      `((result-count . ,(consent--diagnostics-result-count
                          snapshot)))))
    snapshot))

(defun consent--primitive-project-diagnostics (arguments context)
  "Primitive project-diagnostics over ARGUMENTS."
  (consent--authorize-emacs-capability
   "project-diagnostics" arguments context)
  (consent--proper-list-elements
   (car arguments) "project-diagnostics options")
  (let ((snapshot
         (consent-diagnostics-project-snapshot
          (car arguments) context)))
    (consent--add-emacs-capability-result-fields
     `((result-count . ,(consent--diagnostics-result-count snapshot))))
    snapshot))

(defun consent--primitive-diagnostic-at (arguments context)
  "Primitive diagnostic-at over ARGUMENTS."
  (consent--authorize-emacs-capability "diagnostic-at" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "diagnostic-at"))
         (position
          (consent--capability-exact-integer
           (cadr arguments) "diagnostic-at position"))
         (diagnostic
          (consent-diagnostics-at buffer position context)))
    (consent--add-emacs-capability-result-fields
     (append
      (consent--buffer-target-fields buffer)
      `((position . ,position)
        (matched . ,(not (eq diagnostic consent-false))))))
    diagnostic))

(defun consent--primitive-project-compile! (arguments context)
  "Primitive project-compile! over ARGUMENTS."
  (consent--authorize-emacs-capability "project-compile!" arguments context)
  (let ((command (consent--capability-string
                  (car arguments) "project-compile! command"))
        (root (consent--current-project-root-or-error
               "project-compile!")))
    (consent--add-emacs-capability-result-fields
     `((project-root . ,root)
       (command . compile)
       (command-arguments . (,command))))
    (let ((default-directory root))
      (compile command))
    consent-unspecified))

(defun consent--primitive-project-recompile! (arguments context)
  "Primitive project-recompile!."
  (consent--authorize-emacs-capability
   "project-recompile!" arguments context)
  (let ((root (consent--current-project-root-or-error
               "project-recompile!")))
    (consent--add-emacs-capability-result-fields
     `((project-root . ,root)
       (command . recompile)))
    (let ((default-directory root))
      (recompile))
    consent-unspecified))

(defun consent--primitive-buffer-search (arguments context)
  "Primitive buffer-search over ARGUMENTS."
  (consent--authorize-emacs-capability "buffer-search" arguments context)
  (let* ((buffer (consent--live-buffer-for-handle
                  (car arguments) "buffer-search"))
         (pattern (consent--capability-string
                   (cadr arguments) "buffer-search pattern"))
         (options (consent--search-options
                   (caddr arguments) "buffer-search options"))
         (file (consent--buffer-target-file buffer))
         (results
          (consent--search-buffer-results
           buffer pattern options 'buffer file nil)))
    (consent--add-emacs-capability-result-fields
     (append
      (consent--buffer-target-fields buffer)
      `((pattern . ,pattern)
        (result-count . ,(length results)))))
    results))

(defun consent--primitive-project-search (arguments context)
  "Primitive project-search over ARGUMENTS."
  (consent--authorize-emacs-capability "project-search" arguments context)
  (let* ((pattern (consent--capability-string
                   (car arguments) "project-search pattern"))
         (options (consent--search-options
                   (cadr arguments) "project-search options"))
         (limit (consent--search-limit options "project-search"))
         (file-limit
          (consent--search-file-limit options "project-search"))
         (root (consent--search-project-root "project-search"))
         results)
    (catch 'done
      (dolist (file (consent--search-project-files
                     root options file-limit))
        (with-temp-buffer
          (insert-file-contents file)
          (let ((file-results
                 (consent--search-buffer-results
                  (current-buffer) pattern options 'project file root)))
            (dolist (result file-results)
              (push result results)
              (when (>= (length results) limit)
                (throw 'done nil)))))))
    (setq results (nreverse results))
    (consent--add-emacs-capability-result-fields
     `((project-root . ,root)
       (pattern . ,pattern)
       (result-count . ,(length results))))
    results))

(defun consent--primitive-project-files (arguments context)
  "Primitive project-files over ARGUMENTS."
  (consent--authorize-emacs-capability "project-files" arguments context)
  (let* ((options (consent--search-options
                   (car arguments) "project-files options"))
         (root (consent--search-project-root "project-files"))
         (files (consent--search-project-files root options))
         (results
          (mapcar
           (lambda (file)
             (consent--project-file-datum file root))
           files)))
    (consent--add-emacs-capability-result-fields
     `((project-root . ,root)
       (result-count . ,(length results))))
    results))

(defun consent--primitive-search-yield (arguments context)
  "Primitive search-yield over ARGUMENTS."
  (consent--authorize-emacs-capability "search-yield" arguments context)
  (let* ((results
          (consent--proper-list-elements
           (car arguments) "search-yield results"))
         (event
          (list
           (consent--search-symbol "yield")
           (cons (consent--search-symbol "search-results")
                 results))))
    (consent--record-event! context event)
    (consent-audit-record
     'agent-event
     `((category . emacs-search)
       (operation . "search-yield")
       (decision . recorded)
       (record . ,event)
       (result-count . ,(length results))))
    (consent--add-emacs-capability-result-fields
     `((result-count . ,(length results))))
    consent-unspecified))

(defun consent--process-resource-for-handle (handle)
  "Return an authorization resource plist for process HANDLE."
  (let ((object (consent--process-handle-object handle)))
    (list :handle handle
          :command (and object (consent--process-object-command object))
          :arguments (and object
                          (consent--process-object-arguments object)))))

(defun consent--primitive-process-start! (arguments context)
  "Primitive process-start! over ARGUMENTS."
  (let* ((name (consent--capability-string
                (car arguments) "process-start! name"))
         (command (consent--capability-string
                   (cadr arguments) "process-start! command"))
         (process-arguments
          (consent--process-normalized-arguments (caddr arguments)))
         (options (cadddr arguments))
         (cwd (consent--process-cwd options))
         (environment
          (consent--process-normalized-environment options))
         (resource (list :command command
                         :arguments process-arguments
                         :cwd cwd
                         :environment environment
                         :options options))
         (authorization
          (consent-capability-authorize-process
           "process-start!" 'spawn context resource))
         (raw
          (let ((default-directory cwd))
            (funcall consent-process-start-function
                     name command process-arguments options context)))
         (object
          (consent--process-job-object
           raw name command process-arguments options))
         (handle
          (consent--process-register-handle
           object (plist-get authorization :grant))))
    (consent-capability-audit-process-result
     authorization
     `(handle process-job ,(consent-handle-id handle)))
    (consent--add-emacs-capability-result-fields
     `((domain . process)
       (operation . spawn)
       (command . ,command)
       (arguments . ,process-arguments)
       (environment . ,environment)
       (cwd . ,cwd)
       (handle . ,handle)))
    handle))

(defun consent--primitive-emacs-process-list (_arguments context)
  "Primitive emacs-process-list."
  (let ((authorization
         (consent-capability-authorize-process
          "emacs-process-list" 'observe context nil))
        handles)
    (dolist (process (seq-filter #'process-live-p (process-list)))
      (push (consent--process-register-handle
             (consent--process-job-object
              process
              (process-name process)
              (or (car (process-command process)) (process-name process))
              (or (cdr (process-command process)) nil)
              nil)
             (plist-get authorization :grant))
            handles))
    (setq handles (nreverse handles))
    (consent-capability-audit-process-result
     authorization `(handles ,(length handles)))
    handles))

(defun consent--primitive-process-name (arguments context)
  "Primitive process-name over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorization
          (consent-capability-authorize-process
           "process-name" 'observe context
           (consent--process-resource-for-handle handle)))
         (object (consent--live-process-for-handle handle "process-name"))
         (name (consent--process-object-name object)))
    (consent-capability-audit-process-result authorization name)
    name))

(defun consent--primitive-process-status (arguments context)
  "Primitive process-status over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorization
          (consent-capability-authorize-process
           "process-status" 'observe context
           (consent--process-resource-for-handle handle)))
         (object (consent--live-process-for-handle
                  handle "process-status"))
         (status (consent--process-object-status object)))
    (consent-capability-audit-process-result authorization status)
    (consent--scheme-symbol status)))

(defun consent--primitive-process-buffer (arguments context)
  "Primitive process-buffer over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorization
          (consent-capability-authorize-process
           "process-buffer" 'observe context
           (consent--process-resource-for-handle handle)))
         (object (consent--live-process-for-handle
                  handle "process-buffer"))
         (buffer (consent--process-object-buffer object)))
    (consent-capability-audit-process-result
     authorization
     (if buffer (buffer-name buffer) consent-false))
    (if buffer
        (consent--buffer-handle buffer)
      consent-false)))

(defun consent--process-port (handle stream kind operations context)
  "Return process HANDLE STREAM as an Consent Scheme port."
  (let* ((operation (if (eq stream 'stdin) 'input 'output))
         (authorization
          (consent-capability-authorize-process
           (pcase stream
             ('stdin "process-input-port")
             ('stderr "process-error-port")
             (_ "process-output-port"))
           operation
           context
           (consent--process-resource-for-handle handle)))
         (object
          (consent--live-process-for-handle handle "process port"))
         (port
          (if (eq stream 'stdin)
              (consent--make-port
               :medium 'process
               :outputp t
               :textualp t
               :contents "")
            (consent--make-port
             :medium 'process
             :inputp t
             :textualp t
             :source (consent--process-object-output object stream)
             :position 0))))
    (consent-capability-audit-process-result
     authorization `(port ,stream))
    (consent-capability-register-process-port
     port kind authorization handle stream operations)))

(defun consent--primitive-process-output-port (arguments context)
  "Primitive process-output-port over ARGUMENTS."
  (consent--process-port
   (car arguments) 'stdout 'textual-input '(read close) context))

(defun consent--primitive-process-error-port (arguments context)
  "Primitive process-error-port over ARGUMENTS."
  (consent--process-port
   (car arguments) 'stderr 'textual-input '(read close) context))

(defun consent--primitive-process-input-port (arguments context)
  "Primitive process-input-port over ARGUMENTS."
  (consent--process-port
   (car arguments) 'stdin 'textual-output '(write flush close) context))

(defun consent--process-control! (handle operation binding context)
  "Apply process control OPERATION for BINDING to HANDLE."
  (let* ((authorization
          (consent-capability-authorize-process
           binding operation context
           (consent--process-resource-for-handle handle)))
         (object (consent--live-process-for-handle handle binding))
         (process (consent--process-object-process object)))
    (when process
      (pcase operation
        ('interrupt (interrupt-process process))
        ('terminate (delete-process process))))
    (consent-capability-audit-process-result authorization operation)
    consent-unspecified))

(defun consent--primitive-process-interrupt! (arguments context)
  "Primitive process-interrupt! over ARGUMENTS."
  (consent--process-control!
   (car arguments) 'interrupt "process-interrupt!" context))

(defun consent--primitive-process-kill! (arguments context)
  "Primitive process-kill! over ARGUMENTS."
  (consent--process-control!
   (car arguments) 'terminate "process-kill!" context))

(defun consent--compile-normalized-options (options)
  "Validate and return compile OPTIONS."
  (consent--proper-list-elements options "compile options")
  options)

(defun consent--compile-start! (binding command options context)
  "Start authorized compile COMMAND with OPTIONS for BINDING."
  (let* ((options (consent--compile-normalized-options options))
         (cwd (consent--process-cwd options))
         (environment (consent--process-normalized-environment options))
         (resource (list :command command
                         :arguments nil
                         :cwd cwd
                         :environment environment
                         :options options))
         (authorization
          (consent-capability-authorize-process
           binding 'spawn context resource))
         (raw
          (let ((default-directory cwd))
            (funcall consent-compile-start-function
                     command options context)))
         (object
          (let ((object
                 (consent--process-job-object
                  raw "compile" command nil options)))
            (setq object (plist-put object :compile t))
            (setq object (plist-put object :retain-after-exit t))
            (setq object (plist-put object :cwd cwd))
            object))
         (handle
          (consent--process-register-handle
           object (plist-get authorization :grant))))
    (consent-capability-audit-process-result
     authorization
     `(handle process-job ,(consent-handle-id handle)))
    (consent--add-emacs-capability-result-fields
     `((domain . process)
       (operation . spawn)
       (adapter . emacs-compile)
       (command . ,command)
       (environment . ,environment)
       (cwd . ,cwd)
       (handle . ,handle)))
    handle))

(defun consent--primitive-compile-run! (arguments context)
  "Primitive compile-run! over ARGUMENTS."
  (let ((command (consent--capability-string
                  (car arguments) "compile-run! command"))
        (options (cadr arguments)))
    (consent--compile-start!
     "compile-run!" command options context)))

(defun consent--compile-field (name &rest values)
  "Return a Scheme-readable compile field NAME with VALUES."
  (cons (consent--capability-grant-symbol name) values))

(defun consent--compile-exit-status (object)
  "Return compile OBJECT's exit status, or nil when unavailable."
  (or (and (consp object) (plist-get object :exit-status))
      (when-let ((process (consent--process-object-process object)))
        (when (memq (process-status process) '(exit signal))
          (process-exit-status process)))))

(defun consent--compile-status-symbol (object)
  "Return Consent Scheme compile status symbol for OBJECT."
  (let ((status (consent--process-object-status object))
        (exit-status (consent--compile-exit-status object)))
    (cond
     ((memq status '(run open listen connect stop))
      'running)
     ((and (memq status '(exit completed))
           (or (null exit-status) (= exit-status 0)))
      'completed)
     ((memq status '(exit signal failed killed closed deleted stale stopped))
      'failed)
     (t status))))

(defun consent--compile-status-datum (handle object)
  "Return Scheme-readable compile status for HANDLE and OBJECT."
  (let ((exit-status (consent--compile-exit-status object))
        (buffer (consent--process-object-buffer object)))
    `(,(consent--capability-grant-symbol "compile-status")
      ,(consent--compile-field "handle" handle)
      ,(consent--compile-field
        "status"
        (consent--capability-grant-symbol
         (consent--compile-status-symbol object)))
      ,(consent--compile-field
        "process-status"
        (consent--capability-grant-symbol
         (consent--process-object-status object)))
      ,(consent--compile-field
        "exit-status"
        (if exit-status
            (consent--scheme-integer exit-status)
          consent-false))
      ,(consent--compile-field
        "command"
        (or (consent--process-object-command object) consent-false))
      ,(consent--compile-field
        "buffer"
        (if buffer (buffer-name buffer) consent-false)))))

(defun consent--compile-option-integer (options name description)
  "Return compile OPTIONS integer NAME, or nil."
  (when-let ((value (consent--process-option-value options name)))
    (consent--capability-exact-integer value description)))

(defun consent--compile-option-command (options description)
  "Return compile command from OPTIONS, or signal with DESCRIPTION."
  (or (when-let ((command (consent--process-option-value
                          options "command")))
        (consent--capability-string command description))
      (consent--eval-error "%s requires a command option" description)))

(defun consent--compile-output-text (object)
  "Return compile OBJECT stdout or compilation buffer text."
  (consent--process-object-output object 'stdout))

(defun consent--compile-location-type (type)
  "Return Scheme-readable severity symbol for compilation TYPE."
  (consent--capability-grant-symbol
   (cond
    ((eq type 0) "info")
    ((eq type 1) "warning")
    ((eq type 2) "error")
    ((symbolp type) (symbol-name type))
    (t "error"))))

(defun consent--compile-location-file (loc)
  "Return compilation LOC file name, or #f when unavailable."
  (let* ((file-struct
          (and (fboundp 'compilation--loc->file-struct)
               (compilation--loc->file-struct loc)))
         (file-spec
          (and file-struct
               (fboundp 'compilation--file-struct->file-spec)
               (compilation--file-struct->file-spec file-struct)))
         (file (car-safe file-spec)))
    (or file consent-false)))

(defun consent--compile-location-line (loc)
  "Return compilation LOC line as a Scheme integer or #f."
  (let ((line (and (fboundp 'compilation--loc->line)
                   (compilation--loc->line loc))))
    (if line (consent--scheme-integer line) consent-false)))

(defun consent--compile-location-column (loc)
  "Return compilation LOC column as a Scheme integer or #f."
  (let ((column (and (fboundp 'compilation--loc->col)
                     (compilation--loc->col loc))))
    (if column (consent--scheme-integer column) consent-false)))

(defun consent--compile-message-line (position)
  "Return the compilation message line at POSITION."
  (save-excursion
    (goto-char position)
    (buffer-substring-no-properties
     (line-beginning-position)
     (line-end-position))))

(defun consent--compile-error-location-datum (message position)
  "Return MESSAGE at POSITION as a Scheme-readable error location."
  (let ((loc (and (fboundp 'compilation--message->loc)
                  (compilation--message->loc message))))
    `(,(consent--capability-grant-symbol "error-location")
      ,(consent--compile-field
        "file" (if loc
                   (consent--compile-location-file loc)
                 consent-false))
      ,(consent--compile-field
        "line" (if loc
                   (consent--compile-location-line loc)
                 consent-false))
      ,(consent--compile-field
        "column" (if loc
                     (consent--compile-location-column loc)
                   consent-false))
      ,(consent--compile-field
        "type"
        (consent--compile-location-type
         (and (fboundp 'compilation--message->type)
              (compilation--message->type message))))
      ,(consent--compile-field
        "message" (consent--compile-message-line position)))))

(defun consent--compile-error-locations (object)
  "Return parsed compilation error locations for OBJECT."
  (let ((buffer (consent--process-object-buffer object))
        locations
        seen)
    (when (and buffer (fboundp 'compilation--ensure-parse))
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (compilation--ensure-parse (point-max))
            (goto-char (point-min))
            (while (< (point) (point-max))
              (let ((message (get-text-property
                              (point) 'compilation-message))
                    (position (point)))
                (when (and message (not (memq message seen)))
                  (push message seen)
                  (push
                   (consent--compile-error-location-datum
                    message position)
                   locations))
                (goto-char
                 (or (next-single-property-change
                      (point) 'compilation-message nil (point-max))
                     (point-max)))))))))
    (nreverse locations)))

(defun consent--compile-limited-output (text options)
  "Return TEXT limited by compile OUTPUT OPTIONS."
  (let ((limit (consent--compile-option-integer
                options "max-chars" "compile-output max-chars")))
    (if (and limit (> (length text) limit))
        (list (substring text 0 limit) t)
      (list text nil))))

(defun consent--compile-output-datum (handle object options)
  "Return Scheme-readable compile output for HANDLE and OBJECT."
  (let* ((options (consent--compile-normalized-options options))
         (limited (consent--compile-limited-output
                   (consent--compile-output-text object)
                   options))
         (text (car limited))
         (truncated (cadr limited)))
    `(,(consent--capability-grant-symbol "compile-output")
      ,(consent--compile-field "handle" handle)
      ,(consent--compile-field
        "status"
        (consent--capability-grant-symbol
         (consent--compile-status-symbol object)))
      ,(consent--compile-field "text" text)
      ,(consent--compile-field
        "truncated"
        (if truncated consent-true consent-false))
      ,(consent--compile-field
        "error-locations"
        (consent--compile-error-locations object)))))

(defun consent--compile-authorized-object
    (handle binding operation context)
  "Return authorization and compile object for HANDLE."
  (let* ((authorization
          (consent-capability-authorize-process
           binding operation context
           (consent--process-resource-for-handle handle)))
         (object (consent--live-process-for-handle handle binding)))
    (unless (and (consp object) (plist-get object :compile))
      (consent--eval-error "%s expected compile job handle" binding))
    (list authorization object)))

(defun consent--primitive-emacs-compile-project-compile!
    (arguments context)
  "Primitive project-compile! from `(emacs compile)'."
  (let* ((options (consent--compile-normalized-options
                   (car arguments)))
         (command (consent--compile-option-command
                   options "project-compile!"))
         (root (consent--current-project-root-or-error
                "project-compile!")))
    (let ((default-directory root))
      (consent--compile-start!
       "project-compile!" command options context))))

(defun consent--primitive-compile-recompile! (arguments context)
  "Primitive recompile! over ARGUMENTS."
  (let* ((handle (car arguments))
         (object (consent--live-process-for-handle handle "recompile!")))
    (unless (and (consp object) (plist-get object :compile))
      (consent--eval-error "recompile! expected compile job handle"))
    (let ((default-directory
            (or (plist-get object :cwd)
                (file-name-as-directory (expand-file-name default-directory)))))
      (consent--compile-start!
       "recompile!"
       (or (consent--process-object-command object)
           (consent--eval-error "recompile! missing prior command"))
       (or (plist-get object :options) nil)
       context))))

(defun consent--primitive-compile-status (arguments context)
  "Primitive compile-status over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorized
          (consent--compile-authorized-object
           handle "compile-status" 'observe context))
         (authorization (car authorized))
         (object (cadr authorized))
         (datum (consent--compile-status-datum handle object)))
    (consent-capability-audit-process-result authorization datum)
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-compile)
       (operation . status)
       (compile-status . ,(consent--compile-status-symbol object))))
    datum))

(defun consent--primitive-compile-output (arguments context)
  "Primitive compile-output over ARGUMENTS."
  (let* ((handle (car arguments))
         (options (cadr arguments))
         (authorized
          (consent--compile-authorized-object
           handle "compile-output" 'output context))
         (authorization (car authorized))
         (object (cadr authorized))
         (datum (consent--compile-output-datum handle object options)))
    (consent-capability-audit-process-result authorization datum)
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-compile)
       (operation . output)
       (compile-status . ,(consent--compile-status-symbol object))))
    datum))

(defun consent--primitive-compile-yield (arguments context)
  "Primitive compile-yield over ARGUMENTS."
  (let* ((handle (car arguments))
         (authorized
          (consent--compile-authorized-object
           handle "compile-yield" 'output context))
         (authorization (car authorized))
         (object (cadr authorized))
         (datum (consent--compile-output-datum handle object nil)))
    (consent-capability-audit-process-result authorization datum)
    (consent--add-emacs-capability-result-fields
     `((adapter . emacs-compile)
       (operation . yield)
       (compile-status . ,(consent--compile-status-symbol object))))
    (consent-agent-io--primitive-yield (list datum) context)))

(defun consent--primitive-network-http-request (arguments context)
  "Primitive network-http-request over ARGUMENTS."
  (let* ((method (car arguments))
         (url (cadr arguments))
         (headers (caddr arguments))
         (payload (cadddr arguments))
         (options (nth 4 arguments))
         (resource
          (consent--network-resource
           method url headers payload options))
         (authorization
          (consent-capability-authorize-network
           "(emacs network)"
           "network-http-request"
           context
           'request
           resource))
         (response
          (consent--network-normalize-response-datum
           (funcall consent-network-request-function
                    (plist-get authorization :transport-resource)
                    context))))
    (consent--network-check-response-limit! authorization response)
    (consent-capability-audit-network-result authorization response)
    (consent--add-emacs-capability-result-fields
     `((domain . network)
       (operation . request)
       (scheme . ,(plist-get resource :scheme))
       (host . ,(plist-get resource :host))
       (port . ,(plist-get resource :port))
       (method . ,(plist-get resource :method))
       (payload-class . ,(plist-get resource :payload-class))
       (response-size . ,(consent--network-response-body-size response))))
    response))

(defun consent--primitive-network-open-sse-stream (arguments context)
  "Primitive network-open-sse-stream over ARGUMENTS."
  (let* ((url (car arguments))
         (headers (cadr arguments))
         (options (caddr arguments))
         (resource
          (consent--network-resource
           'GET url headers "" options t))
         (authorization
          (consent-capability-authorize-network
           "(emacs network)"
           "network-open-sse-stream"
           context
           'stream
           resource))
         (source
          (funcall consent-network-stream-function
                   (plist-get authorization :transport-resource)
                   context)))
    (unless (stringp source)
      (consent--eval-error
       "network-open-sse-stream adapter must return textual stream contents"))
    (let* ((stream-handle
            (consent--network-register-stream-handle
             (plist-get resource :url)
             source
             authorization))
           (port
            (consent--make-port
             :medium 'network
             :inputp t
             :textualp t
             :source source
             :position 0)))
      (consent-capability-audit-network-result
       authorization
       `(handle network-stream ,(consent-handle-id stream-handle)))
      (consent--add-emacs-capability-result-fields
       `((domain . network)
         (operation . stream)
         (scheme . ,(plist-get resource :scheme))
         (host . ,(plist-get resource :host))
         (port . ,(plist-get resource :port))
         (method . ,(plist-get resource :method))
         (handle . ,stream-handle)))
      (consent-capability-register-network-port
       port 'textual-input authorization stream-handle '(read close)))))

(defun consent--documentation-string (symbol commandp)
  "Return raw documentation string for SYMBOL.
When COMMANDP is non-nil, SYMBOL must name an interactive command."
  (if (and symbol
           (if commandp (commandp symbol) (fboundp symbol)))
      (consent--maybe-string (documentation symbol t))
    consent-false))

(defun consent--primitive-command-doc (arguments context)
  "Primitive command-doc over ARGUMENTS."
  (consent--authorize-emacs-capability "command-doc" arguments context)
  (consent--documentation-string
   (consent--capability-name-symbol (car arguments) "command-doc")
   t))

(defun consent--primitive-command-call! (arguments context)
  "Primitive command-call! over ARGUMENTS."
  (consent--authorize-emacs-capability "command-call!" arguments context)
  (let* ((command (consent--command-symbol (car arguments)))
         (command-name (consent--command-name (car arguments)))
         (entry (and command
                     (consent--command-whitelist-entry command)))
         (plist (consent--command-whitelist-plist entry))
         (scheme-arguments (cdr arguments))
         (emacs-arguments
          (if scheme-arguments
              (mapcar #'consent--command-argument-value scheme-arguments)
            (copy-sequence (plist-get plist :default-arguments))))
         (allow-interactive (plist-get plist :allow-interactive)))
    (unless entry
      (consent--command-call-deny
       command-name "command is not whitelisted" context))
    (unless (and command (commandp command))
      (consent--command-call-deny
       command-name "command is not an interactive command" context))
    (when (and (< (length emacs-arguments)
                  (consent--command-minimum-arity command))
               (not allow-interactive))
      (consent--eval-error
       "interactive prompt is not allowed for command: %s"
       command-name))
    (consent--add-emacs-capability-result-fields
     `((command . ,command)
       (command-arguments . ,emacs-arguments)
       (interactive . ,(if allow-interactive
                           consent-true
                         consent-false))))
    (if (< (length emacs-arguments)
           (consent--command-minimum-arity command))
        (call-interactively command)
      (apply command emacs-arguments))
    consent-unspecified))

(defun consent--primitive-function-doc (arguments context)
  "Primitive function-doc over ARGUMENTS."
  (consent--authorize-emacs-capability "function-doc" arguments context)
  (consent--documentation-string
   (consent--capability-name-symbol (car arguments) "function-doc")
   nil))

(defun consent--primitive-variable-info (arguments context)
  "Primitive variable-info over ARGUMENTS without exposing variable values."
  (consent--authorize-emacs-capability "variable-info" arguments context)
  (let* ((argument (car arguments))
         (name
          (cond
           ((consent-symbol-p argument)
            (consent-symbol-name argument))
           ((stringp argument)
            argument)
           (t
            (consent--eval-error
             "variable-info expected a symbol or string, got %s"
             (consent-value->external argument)))))
         (symbol (intern-soft name))
         (documentation
          (and symbol
               (documentation-property symbol 'variable-documentation t))))
    (list
     (list (consent--intern-symbol "name")
           (consent--intern-symbol name))
     (list (consent--intern-symbol "bound?")
           (consent--scheme-boolean-value
            (and symbol (boundp symbol))))
     (list (consent--intern-symbol "custom?")
           (consent--scheme-boolean-value
            (and symbol (custom-variable-p symbol))))
     (list (consent--intern-symbol "documentation")
           (consent--maybe-string documentation)))))

(provide 'consent-capability)

;;; consent-capability.el ends here
