;;; consent-policy.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Policy decisions are category-based and audited as Scheme-readable datums.
;; Host adapters call this module before touching effectful authority.

;;; Code:

(require 'cl-lib)
(require 'consent-runtime)
(require 'consent-audit)
(require 'consent-approval)
(require 'consent-redaction)

(defgroup consent-policy nil
  "Policy gates for Consent Scheme capabilities."
  :group 'consent)

(define-error 'consent-policy-error
  "Consent Scheme policy denied"
  'consent-eval-error)

(defconst consent-policy-categories
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
  "Policy categories recognized by Consent Scheme.")

(defun consent-policy-default-confirmation-function (request)
  "Ask for confirmation for REQUEST when interactive, otherwise deny."
  (and (not noninteractive)
       (yes-or-no-p
        (format "Allow Consent Scheme policy request %s? "
                (consent-result->external request)))))

(defcustom consent-policy-category-actions
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
                                            consent-policy-categories))
                :value-type (choice (const allow)
                                    (const deny)
                                    (const confirm)))
  :group 'consent-policy)

(defcustom consent-policy-confirmation-function
  #'consent-policy-default-confirmation-function
  "Function called with a Scheme-readable request datum for confirmations."
  :type 'function
  :group 'consent-policy)

(defun consent-policy--context-policy-actions (context)
  "Return policy action overrides from CONTEXT, if present."
  (and context
       (consent--eval-context-p context)
       (consent--eval-context-policy-actions context)))

(defun consent-policy--context-confirmation-function (context)
  "Return confirmation function override from CONTEXT, if present."
  (and context
       (consent--eval-context-p context)
       (consent--eval-context-policy-confirmation-function context)))

(defun consent-policy-action-for-category (category &optional context)
  "Return the configured action for CATEGORY in optional CONTEXT."
  (or (cdr (assq category
                 (consent-policy--context-policy-actions context)))
      (cdr (assq category consent-policy-category-actions))
      'deny))

(defun consent-policy--confirmation-function (context)
  "Return the active confirmation function for CONTEXT."
  (or (consent-policy--context-confirmation-function context)
      consent-policy-confirmation-function))

(defun consent-policy--decision-fields
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

(defun consent-policy--deny
    (category operation action fields _context event reason)
  "Audit and signal a denied policy decision."
  (consent-audit-record
   event
   (consent-policy--decision-fields
    category operation action 'denied fields reason))
  (signal 'consent-policy-error
          (list (or reason
                    (format "%s is denied by %s policy"
                            operation category)))))

;;;###autoload
(defun consent-policy-deny
    (category operation &optional fields context reason event)
  "Audit and signal denied CATEGORY policy for OPERATION."
  (consent-policy--deny
   category operation 'deny fields context (or event 'policy-decision) reason))

;;;###autoload
(defun consent-policy-authorize
    (category operation &optional fields context event)
  "Authorize OPERATION in CATEGORY, audit the decision, and return its datum.
FIELDS is an alist of additional Scheme-readable audit details.
CONTEXT may provide per-evaluation policy overrides.  EVENT defaults
to `policy-decision'."
  (let* ((action (consent-policy-action-for-category category context))
         (audit-event (or event 'policy-decision))
         (confirmation
          (consent-policy--confirmation-function context)))
    (pcase action
      ('allow
       (consent-audit-record
        audit-event
        (consent-policy--decision-fields
         category operation action 'allowed fields nil)))
      ('deny
       (consent-policy--deny
        category operation action fields context audit-event nil))
      ('confirm
       (let* ((request
               (consent-audit-entry-datum
                'policy-request
                (consent-policy--decision-fields
                 category operation action 'requested fields nil)))
              (approval-id
               (consent-approval-request-from-policy!
                category operation fields request context))
              (confirmed (and confirmation (funcall confirmation request))))
         (if confirmed
             (progn
               (consent-approval-resolve! approval-id 'approved)
               (consent-audit-record
                audit-event
                (consent-policy--decision-fields
                 category operation action 'confirmed fields nil)))
           (consent-approval-resolve! approval-id 'denied)
           (consent-policy--deny
            category
            operation
            action
            fields
            context
            audit-event
            "confirmation required"))))
      (_
       (consent-policy--deny
        category
        operation
        action
        fields
        context
        audit-event
        (format "unknown policy action: %S" action))))))

;;;###autoload
(defun consent-policy-authorize-skill-activation
    (skill-name source-dir trust-scope &optional context)
  "Authorize activation for SKILL-NAME from SOURCE-DIR."
  (consent-policy-authorize
   'skill-discovery-activation
   "activate-skill"
   `((skill-name . ,skill-name)
     (source-directory . ,source-dir)
     (trust-scope . ,trust-scope))
   context
   'skill-activation))

;;;###autoload
(defun consent-policy-authorize-project-skill-trust
    (project project-directory &optional context)
  "Authorize trust for PROJECT skills in PROJECT-DIRECTORY."
  (consent-policy-authorize
   'project-skill-trust
   "project-skill-trust"
   `((project . ,project)
     (project-directory . ,project-directory))
   context
   'trust-decision))

;;;###autoload
(defun consent-policy-authorize-skill-resource-read
    (skill-name resource-path &optional context)
  "Authorize SKILL-NAME reading RESOURCE-PATH."
  (consent-policy-authorize
   'skill-resource-read
   "skill-resource-read"
   `((skill-name . ,skill-name)
     (resource-path . ,resource-path))
   context
   'skill-resource))

;;;###autoload
(defun consent-policy-authorize-skill-script-execution
    (skill-name script-path &optional context)
  "Authorize SKILL-NAME executing bundled SCRIPT-PATH."
  (consent-policy-authorize
   'skill-script-execution
   "skill-script-execution"
   `((skill-name . ,skill-name)
     (script-path . ,script-path))
   context
   'skill-script))

;;;###autoload
(defun consent-policy-authorize-skill-export-write
    (skill-name export-path &optional context)
  "Authorize SKILL-NAME writing EXPORT-PATH."
  (consent-policy-authorize
   'skill-export-write
   "skill-export-write"
   `((skill-name . ,skill-name)
     (export-path . ,export-path))
   context
   'skill-export))

;;;###autoload
(defun consent-policy-authorize-helper-tracked-write
    (library-name target-path &optional context)
  "Authorize helper LIBRARY-NAME writing tracked TARGET-PATH."
  (consent-policy-authorize
   'helper-tracked-write
   "helper-tracked-write"
   `((library-name . ,library-name)
     (target-path . ,target-path))
   context
   'helper-tracked-write))

;;;###autoload
(defun consent-policy-authorize-helper-skill-candidate-write
    (candidate-name target-path &optional context)
  "Authorize skill CANDIDATE-NAME writing TARGET-PATH."
  (consent-policy-authorize
   'helper-skill-candidate-write
   "helper-skill-candidate-write"
   `((candidate-name . ,candidate-name)
     (target-path . ,target-path))
   context
   'helper-skill-candidate-write))

;;;###autoload
(defun consent-policy-authorize-provider-routing
    (datum provider &optional options context)
  "Authorize routing DATUM to remote PROVIDER and return redacted DATUM.
Local-only context is denied unless OPTIONS contains
`:allow-local-only' with a non-nil value.  Secret-bearing context is
redacted before authorization data is audited or returned."
  (let* ((redacted (consent-redact datum 'remote-provider))
         (local-only (consent-redaction-local-only-p datum))
         (allow-local-only (plist-get options :allow-local-only))
         (fields `((provider . ,provider)
                   (payload . ,redacted)
                   (local-only . ,(if local-only
                                      consent-true
                                    consent-false)))))
    (if (and local-only (not allow-local-only))
        (consent-policy-deny
         'remote-provider-routing
         "provider-route"
         fields
         context
         "local-only context requires explicit approval"
         'provider-routing)
      (consent-policy-authorize
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

(provide 'consent-policy)

;;; consent-policy.el ends here
