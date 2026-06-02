;;; agent-scheme-policy.el --- Shared policy decisions  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Policy decisions are category-based and audited as Scheme-readable datums.
;; Host adapters call this module before touching effectful authority.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-runtime)
(require 'agent-scheme-audit)
(require 'agent-scheme-approval)
(require 'agent-scheme-redaction)

(defgroup agent-scheme-policy nil
  "Policy gates for Agent Scheme capabilities."
  :group 'agent-scheme)

(define-error 'agent-scheme-policy-error
  "Agent Scheme policy denied"
  'agent-scheme-eval-error)

(defconst agent-scheme-policy-categories
  '(pure-r7rs
    emacs-read-only
    buffer-edit
    vcs-mutation
    window-session
    command-process
    standard-host-effect
    debugger-recovery
    raw-emacs-lisp
    approval-resolution
    skill-discovery-activation
    project-skill-trust
    skill-resource-read
    skill-script-execution
    skill-export-write
    helper-tracked-write
    helper-skill-candidate-write
    network-access
    remote-provider-routing)
  "Policy categories recognized by Agent Scheme.")

(defun agent-scheme-policy-default-confirmation-function (request)
  "Ask for confirmation for REQUEST when interactive, otherwise deny."
  (and (not noninteractive)
       (yes-or-no-p
        (format "Allow Agent Scheme policy request %s? "
                (agent-scheme-result->external request)))))

(defcustom agent-scheme-policy-category-actions
  '((pure-r7rs . allow)
    (emacs-read-only . allow)
    (buffer-edit . confirm)
    (vcs-mutation . confirm)
    (window-session . confirm)
    (command-process . confirm)
    (standard-host-effect . allow)
    (debugger-recovery . confirm)
    (raw-emacs-lisp . deny)
    (approval-resolution . deny)
    (skill-discovery-activation . confirm)
    (project-skill-trust . deny)
    (skill-resource-read . confirm)
    (skill-script-execution . confirm)
    (skill-export-write . confirm)
    (helper-tracked-write . confirm)
    (helper-skill-candidate-write . confirm)
    (network-access . deny)
    (remote-provider-routing . allow))
  "Alist mapping policy categories to `allow', `deny', or `confirm'."
  :type `(alist :key-type (choice ,@(mapcar (lambda (category)
                                              `(const ,category))
                                            agent-scheme-policy-categories))
                :value-type (choice (const allow)
                                    (const deny)
                                    (const confirm)))
  :group 'agent-scheme-policy)

(defcustom agent-scheme-policy-confirmation-function
  #'agent-scheme-policy-default-confirmation-function
  "Function called with a Scheme-readable request datum for confirmations."
  :type 'function
  :group 'agent-scheme-policy)

(defun agent-scheme-policy--context-policy-actions (context)
  "Return policy action overrides from CONTEXT, if present."
  (and context
       (agent-scheme--eval-context-p context)
       (agent-scheme--eval-context-policy-actions context)))

(defun agent-scheme-policy--context-confirmation-function (context)
  "Return confirmation function override from CONTEXT, if present."
  (and context
       (agent-scheme--eval-context-p context)
       (agent-scheme--eval-context-policy-confirmation-function context)))

(defun agent-scheme-policy-action-for-category (category &optional context)
  "Return the configured action for CATEGORY in optional CONTEXT."
  (or (cdr (assq category
                 (agent-scheme-policy--context-policy-actions context)))
      (cdr (assq category agent-scheme-policy-category-actions))
      'deny))

(defun agent-scheme-policy--confirmation-function (context)
  "Return the active confirmation function for CONTEXT."
  (or (agent-scheme-policy--context-confirmation-function context)
      agent-scheme-policy-confirmation-function))

(defun agent-scheme-policy--decision-fields
    (category operation action decision fields reason)
  "Return audit fields for a policy decision."
  (append
   `((category . ,category)
     (operation . ,operation)
     (action . ,action)
     (decision . ,decision))
   (when reason
     `((reason . ,reason)))
   fields))

(defun agent-scheme-policy--deny
    (category operation action fields context event reason)
  "Audit and signal a denied policy decision."
  (agent-scheme-audit-record
   event
   (agent-scheme-policy--decision-fields
    category operation action 'denied fields reason))
  (signal 'agent-scheme-policy-error
          (list (or reason
                    (format "%s is denied by %s policy"
                            operation category)))))

;;;###autoload
(defun agent-scheme-policy-deny
    (category operation &optional fields context reason event)
  "Audit and signal denied CATEGORY policy for OPERATION."
  (agent-scheme-policy--deny
   category operation 'deny fields context (or event 'policy-decision) reason))

;;;###autoload
(defun agent-scheme-policy-authorize
    (category operation &optional fields context event)
  "Authorize OPERATION in CATEGORY, audit the decision, and return its datum.
FIELDS is an alist of additional Scheme-readable audit details.
CONTEXT may provide per-evaluation policy overrides.  EVENT defaults
to `policy-decision'."
  (let* ((action (agent-scheme-policy-action-for-category category context))
         (audit-event (or event 'policy-decision))
         (confirmation
          (agent-scheme-policy--confirmation-function context)))
    (pcase action
      ('allow
       (agent-scheme-audit-record
        audit-event
        (agent-scheme-policy--decision-fields
         category operation action 'allowed fields nil)))
      ('deny
       (agent-scheme-policy--deny
        category operation action fields context audit-event nil))
      ('confirm
       (let* ((request
               (agent-scheme-audit-entry-datum
                'policy-request
                (agent-scheme-policy--decision-fields
                 category operation action 'requested fields nil)))
              (approval-id
               (agent-scheme-approval-request-from-policy!
                category operation fields request context))
              (confirmed (and confirmation (funcall confirmation request))))
         (if confirmed
             (progn
               (agent-scheme-approval-resolve! approval-id 'approved)
               (agent-scheme-audit-record
                audit-event
                (agent-scheme-policy--decision-fields
                 category operation action 'confirmed fields nil)))
           (agent-scheme-approval-resolve! approval-id 'denied)
           (agent-scheme-policy--deny
            category
            operation
            action
            fields
            context
            audit-event
            "confirmation required"))))
      (_
       (agent-scheme-policy--deny
        category
        operation
        action
        fields
        context
        audit-event
        (format "unknown policy action: %S" action))))))

;;;###autoload
(defun agent-scheme-policy-authorize-skill-activation
    (skill-name source-directory trust-scope &optional context)
  "Authorize activation for SKILL-NAME from SOURCE-DIRECTORY."
  (agent-scheme-policy-authorize
   'skill-discovery-activation
   "activate-skill"
   `((skill-name . ,skill-name)
     (source-directory . ,source-directory)
     (trust-scope . ,trust-scope))
   context
   'skill-activation))

;;;###autoload
(defun agent-scheme-policy-authorize-project-skill-trust
    (project project-directory &optional context)
  "Authorize trust for PROJECT skills in PROJECT-DIRECTORY."
  (agent-scheme-policy-authorize
   'project-skill-trust
   "project-skill-trust"
   `((project . ,project)
     (project-directory . ,project-directory))
   context
   'trust-decision))

;;;###autoload
(defun agent-scheme-policy-authorize-skill-resource-read
    (skill-name resource-path &optional context)
  "Authorize SKILL-NAME reading RESOURCE-PATH."
  (agent-scheme-policy-authorize
   'skill-resource-read
   "skill-resource-read"
   `((skill-name . ,skill-name)
     (resource-path . ,resource-path))
   context
   'skill-resource))

;;;###autoload
(defun agent-scheme-policy-authorize-skill-script-execution
    (skill-name script-path &optional context)
  "Authorize SKILL-NAME executing bundled SCRIPT-PATH."
  (agent-scheme-policy-authorize
   'skill-script-execution
   "skill-script-execution"
   `((skill-name . ,skill-name)
     (script-path . ,script-path))
   context
   'skill-script))

;;;###autoload
(defun agent-scheme-policy-authorize-skill-export-write
    (skill-name export-path &optional context)
  "Authorize SKILL-NAME writing EXPORT-PATH."
  (agent-scheme-policy-authorize
   'skill-export-write
   "skill-export-write"
   `((skill-name . ,skill-name)
     (export-path . ,export-path))
   context
   'skill-export))

;;;###autoload
(defun agent-scheme-policy-authorize-helper-tracked-write
    (library-name target-path &optional context)
  "Authorize helper LIBRARY-NAME writing tracked TARGET-PATH."
  (agent-scheme-policy-authorize
   'helper-tracked-write
   "helper-tracked-write"
   `((library-name . ,library-name)
     (target-path . ,target-path))
   context
   'helper-tracked-write))

;;;###autoload
(defun agent-scheme-policy-authorize-helper-skill-candidate-write
    (candidate-name target-path &optional context)
  "Authorize skill CANDIDATE-NAME writing TARGET-PATH."
  (agent-scheme-policy-authorize
   'helper-skill-candidate-write
   "helper-skill-candidate-write"
   `((candidate-name . ,candidate-name)
     (target-path . ,target-path))
   context
   'helper-skill-candidate-write))

;;;###autoload
(defun agent-scheme-policy-authorize-provider-routing
    (datum provider &optional options context)
  "Authorize routing DATUM to remote PROVIDER and return redacted DATUM.
Local-only context is denied unless OPTIONS contains
`:allow-local-only' with a non-nil value.  Secret-bearing context is
redacted before authorization data is audited or returned."
  (let* ((redacted (agent-scheme-redact datum 'remote-provider))
         (local-only (agent-scheme-redaction-local-only-p datum))
         (allow-local-only (plist-get options :allow-local-only))
         (fields `((provider . ,provider)
                   (payload . ,redacted)
                   (local-only . ,(if local-only
                                      agent-scheme-true
                                    agent-scheme-false)))))
    (if (and local-only (not allow-local-only))
        (agent-scheme-policy-deny
         'remote-provider-routing
         "provider-route"
         fields
         context
         "local-only context requires explicit approval"
         'provider-routing)
      (agent-scheme-policy-authorize
       'remote-provider-routing
       "provider-route"
       (append
        fields
        `((policy . ,(if allow-local-only
                         'local-only-override
                       'remote-provider-redaction))))
       context
       'provider-routing)
      redacted)))

(provide 'agent-scheme-policy)

;;; agent-scheme-policy.el ends here
