;;; consent-models.el --- Model provider routing primitives  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Provider registry and completion routing for `(agent models)'.  This module
;; intentionally ships one effectful transport: local OpenAI-compatible HTTP.
;; Remote providers may be registered and inspected, but completion routing
;; still flows through the remote-provider policy gate and has no live remote
;; adapter here.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-policy)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)

(declare-function consent--source-library-call "consent-library")

(define-error 'consent-models-error
  "Consent Scheme model provider error"
  'consent-eval-error)

(defvar consent-models--providers nil
  "Registered model providers as normalized plists in registration order.")

(defun consent-models--symbol (name)
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

(defun consent-models--boolean (value)
  "Return VALUE as a Scheme boolean."
  (if value consent-true consent-false))

(defun consent-models--field (name &rest values)
  "Return a Scheme-readable field named NAME with VALUES."
  (cons (consent-models--symbol name) values))

(defun consent-models--symbol-name (datum)
  "Return DATUM as a plain symbol/string name, or nil."
  (cond
   ((null datum)
    nil)
   ((consent-symbol-p datum)
    (consent-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)
   (t nil)))

(defun consent-models--expect-name (datum description)
  "Return DATUM as a string name or signal DESCRIPTION."
  (or (consent-models--symbol-name datum)
      (consent--eval-error "%s must be a symbol or string" description)))

(defun consent-models--record-head (datum)
  "Return DATUM's record head name, or nil."
  (and (consp datum)
       (not (and (consp (car datum))
                 (consent-models--symbol-name (caar datum))))
       (consent-models--symbol-name (car datum))))

(defun consent-models--field-pairs (datum)
  "Return field pairs from Scheme-readable DATUM."
  (when (consp datum)
    (let ((fields (if (consent-models--record-head datum)
                      (cdr datum)
                    datum)))
      (seq-filter
       (lambda (field)
         (and (consp field)
              (consent-models--symbol-name (car field))))
       fields))))

(defun consent-models--field-value (datum name &optional default)
  "Return field NAME from DATUM, or DEFAULT."
  (let ((found nil)
        value)
    (dolist (field (consent-models--field-pairs datum))
      (when (equal (consent-models--symbol-name (car field)) name)
        (setq found t)
        (setq value (cadr field))))
    (if found value default)))

(defun consent-models--field-value-any (datum names &optional default)
  "Return the first field in NAMES from DATUM, or DEFAULT."
  (let ((missing (make-symbol "missing"))
        value)
    (catch 'found
      (dolist (name names)
        (setq value
              (consent-models--field-value datum name missing))
        (unless (eq value missing)
          (throw 'found value)))
      default)))

(defun consent-models--proper-list (datum description)
  "Return DATUM as a proper list for DESCRIPTION."
  (consent--proper-list-elements datum description))

(defun consent-models--truthy-p (datum)
  "Return non-nil when DATUM is truthy in Scheme."
  (not (or (null datum) (eq datum consent-false))))

(defun consent-models--names-list (datum description)
  "Return DATUM as a list of string names for DESCRIPTION."
  (mapcar
   (lambda (entry)
     (consent-models--expect-name entry description))
   (consent-models--proper-list datum description)))

(defun consent-models--normalize-model (datum)
  "Return normalized model profile from Scheme DATUM."
  (let* ((id (consent-models--expect-name
              (consent-models--field-value datum "id")
              "model id"))
         (roles (consent-models--names-list
                 (or (consent-models--field-value datum "roles") '())
                 "model roles"))
         (privacy (or (consent-models--symbol-name
                       (consent-models--field-value datum "privacy"))
                      "public"))
         (status (or (consent-models--symbol-name
                      (consent-models--field-value datum "status"))
                     "available")))
    (list :id id
          :roles roles
          :privacy privacy
          :status status
          :raw datum)))

(defun consent-models--normalize-provider (datum)
  "Return normalized provider profile from Scheme DATUM."
  (unless (equal (consent-models--record-head datum) "model-provider")
    (signal 'consent-models-error
            (list "model-provider-register! expects a model-provider datum")))
  (let* ((id (consent-models--expect-name
              (consent-models--field-value datum "id")
              "provider id"))
         (kind (or (consent-models--symbol-name
                    (consent-models--field-value datum "kind"))
                   "local"))
         (transport (or (consent-models--symbol-name
                         (consent-models--field-value datum "transport"))
                        "openai-compatible-http"))
         (endpoint (consent-models--field-value datum "endpoint"))
         (credentials (consent-models--field-value datum "credentials"))
         (available (consent-models--field-value datum "available"
                                                     consent-true))
         (models
          (mapcar
           #'consent-models--normalize-model
           (consent-models--proper-list
            (or (consent-models--field-value datum "models") '())
            "provider models"))))
    (unless (or (not endpoint) (stringp endpoint))
      (consent--eval-error "provider endpoint must be a string"))
    (list :id id
          :kind kind
          :transport transport
          :endpoint endpoint
          :credentials credentials
          :available (consent-models--truthy-p available)
          :models models
          :raw datum)))

;;;###autoload
(defun consent-models-clear! ()
  "Clear registered model providers."
  (setq consent-models--providers nil)
  consent-unspecified)

;;;###autoload
(defun consent-models-register-provider! (datum)
  "Register a model provider from Scheme-readable DATUM."
  (let ((provider (consent-models--normalize-provider datum)))
    (setq consent-models--providers
          (append
           (cl-remove (plist-get provider :id)
                      consent-models--providers
                      :key (lambda (entry) (plist-get entry :id))
                      :test #'equal)
           (list provider)))
    (consent-audit-record
     'model-provider
     `((operation . register)
       (provider . ,(plist-get provider :id))
       (kind . ,(plist-get provider :kind))
       (transport . ,(plist-get provider :transport))))
    (consent-models--provider-datum provider)))

(defun consent-models--model-available-p (model)
  "Return non-nil when MODEL can be selected."
  (member (plist-get model :status) '("available" "ready")))

(defun consent-models--provider-available-p (provider)
  "Return non-nil when PROVIDER can be selected."
  (plist-get provider :available))

(defun consent-models--option-value (options name &optional default)
  "Return model routing option NAME from OPTIONS, or DEFAULT."
  (consent-models--field-value options name default))

(defun consent-models--candidate-provider-id (candidate)
  "Return CANDIDATE provider id."
  (plist-get (plist-get candidate :provider) :id))

(defun consent-models--candidate-model-id (candidate)
  "Return CANDIDATE model id."
  (plist-get (plist-get candidate :model) :id))

(defun consent-models--candidate-kind (candidate)
  "Return CANDIDATE provider kind."
  (plist-get (plist-get candidate :provider) :kind))

(defun consent-models--candidate-score (candidate)
  "Return routing preference score for CANDIDATE."
  (if (equal (consent-models--candidate-kind candidate) "local")
      0
    1))

(defun consent-models--role-candidates (role options)
  "Return provider/model candidates for ROLE and OPTIONS."
  (let ((provider-filter
         (consent-models--symbol-name
          (consent-models--option-value options "provider")))
        candidates)
    (dolist (provider consent-models--providers)
      (when (and (consent-models--provider-available-p provider)
                 (or (not provider-filter)
                     (equal provider-filter (plist-get provider :id))))
        (dolist (model (plist-get provider :models))
          (when (and (consent-models--model-available-p model)
                     (member role (plist-get model :roles)))
            (push (list :provider provider :model model) candidates)))))
    (cl-stable-sort (nreverse candidates) #'<
                    :key #'consent-models--candidate-score)))

(defun consent-models--select (role options)
  "Return the selected provider/model candidate for ROLE and OPTIONS."
  (car (consent-models--role-candidates role options)))

(defun consent-models--decision-datum (role candidate)
  "Return Scheme-readable routing decision for ROLE and CANDIDATE."
  (if candidate
      (let ((provider (plist-get candidate :provider))
            (model (plist-get candidate :model)))
        (append
         (list
          (consent-models--symbol "model-routing-decision")
          (list (consent-models--symbol "status")
                (consent-models--symbol "selected"))
          (list (consent-models--symbol "role")
                (consent-models--symbol role))
          (list (consent-models--symbol "provider")
                (consent-models--symbol (plist-get provider :id)))
          (list (consent-models--symbol "model")
                (consent-models--symbol (plist-get model :id)))
          (list (consent-models--symbol "kind")
                (consent-models--symbol (plist-get provider :kind)))
          (list (consent-models--symbol "transport")
                (consent-models--symbol
                 (plist-get provider :transport))))
         (when-let ((endpoint (plist-get provider :endpoint)))
           (list
            (list (consent-models--symbol "endpoint") endpoint)))))
    (list
     (consent-models--symbol "model-routing-decision")
     (list (consent-models--symbol "status")
           (consent-models--symbol "unavailable"))
     (list (consent-models--symbol "role")
           (consent-models--symbol role))
     (list (consent-models--symbol "reason")
           "no registered provider model supports role"))))

;;;###autoload
(defun consent-models-route (role options &optional _context)
  "Return an inspectable routing decision for ROLE and OPTIONS."
  (let* ((role-name (consent-models--expect-name role "model role"))
         (candidate (consent-models--select role-name options))
         (decision (consent-models--decision-datum role-name candidate)))
    (consent-audit-record
     'model-routing
     `((role . ,role-name)
       (status . ,(if candidate 'selected 'unavailable))
       (provider . ,(and candidate
                         (consent-models--candidate-provider-id
                          candidate)))
       (model . ,(and candidate
                      (consent-models--candidate-model-id candidate)))))
    decision))

(defun consent-models--request-datum
    (role prompt options provider model &optional tools tool-choice)
  "Return Scheme-readable request datum for routing PROMPT."
  (append
   (list
    (consent-models--symbol "model-request")
    (list (consent-models--symbol "role")
          (consent-models--symbol role))
    (list (consent-models--symbol "provider")
          (consent-models--symbol (plist-get provider :id)))
    (list (consent-models--symbol "model")
          (consent-models--symbol (plist-get model :id)))
    (list (consent-models--symbol "prompt") prompt)
    (list (consent-models--symbol "options") options))
   (when tools
     (list (list (consent-models--symbol "tools") tools)))
   (when tool-choice
     (list (list (consent-models--symbol "tool-choice")
                 tool-choice)))))

(defun consent-models--ensure-local-transport (provider)
  "Signal unless PROVIDER can use the local transport."
  (unless (equal (plist-get provider :kind) "local")
    (signal 'consent-models-error
            (list "remote model transport is not configured")))
  (unless (equal (plist-get provider :transport)
                 "openai-compatible-http")
    (signal 'consent-models-error
            (list "unsupported local model transport"
                  (plist-get provider :transport)))))

(defun consent-models--prompt-string (prompt)
  "Return PROMPT as a string or signal."
  (unless (stringp prompt)
    (signal 'consent-models-error
            (list "model-complete prompt must be a string")))
  prompt)

(defun consent-models--remote-provider-p (provider)
  "Return non-nil when PROVIDER is remote."
  (equal (plist-get provider :kind) "remote"))

(defun consent-models--record-p (datum head)
  "Return non-nil when DATUM is a Scheme-readable record named HEAD."
  (equal (consent-models--record-head datum) head))

(defun consent-models--model-tool-p (datum)
  "Return non-nil when DATUM is a canonical model-tool record."
  (consent-models--record-p datum "model-tool"))

(defun consent-models--model-message-p (datum)
  "Return non-nil when DATUM is a canonical model-message record."
  (consent-models--record-p datum "model-message"))

(defun consent-models--normalize-tools (tools)
  "Return normalized canonical TOOLS, or nil when absent."
  (when tools
    (mapcar
     (lambda (tool)
       (unless (consent-models--model-tool-p tool)
         (signal 'consent-models-error
                 (list "tools must contain model-tool datums" tool)))
       tool)
     (consent-models--proper-list tools "tools"))))

(defun consent-models--normalize-tool-choice (tool-choice)
  "Return normalized TOOL-CHOICE datum, or nil when absent."
  (cond
   ((or (null tool-choice) (eq tool-choice consent-false))
    nil)
   ((consent-models--model-tool-p tool-choice)
    tool-choice)
   ((consent-models--symbol-name tool-choice)
    (consent-models--symbol
     (consent-models--symbol-name tool-choice)))
   (t
    (signal 'consent-models-error
            (list "tool-choice must be a symbol, string, or model-tool"
                  tool-choice)))))

(defun consent-models--provider-error-record-p (datum)
  "Return non-nil when DATUM is a `model-provider-error' record."
  (consent-models--record-p datum "model-provider-error"))

(defun consent-models--provider-error-summary (datum)
  "Return DATUM as a concise human-facing transport summary."
  (let ((provider
         (consent-models--symbol-name
          (consent-models--field-value datum "provider")))
        (model
         (consent-models--symbol-name
          (consent-models--field-value datum "model")))
        (transport
         (consent-models--symbol-name
          (consent-models--field-value datum "transport")))
        (reason
         (or (consent-models--field-value datum "reason")
             "transport failed")))
    (format "local model transport failed for provider %s model %s via %s: %s"
            (or provider "unknown-provider")
            (or model "unknown-model")
            (or transport "openai-compatible-http")
            reason)))

(defun consent-models--signal-provider-error-datum
    (request datum &optional message)
  "Audit and signal structured provider DATUM for REQUEST with MESSAGE."
  (let ((reason (or (consent-models--field-value datum "reason")
                    message
                    "transport failed")))
    (consent-audit-record
     'model-provider-error
     `((provider . ,(plist-get (plist-get request :provider) :id))
       (model . ,(plist-get (plist-get request :model) :id))
       (status . unavailable)
       (reason . ,reason)))
    (signal 'consent-models-error
            (list (or message
                      (consent-models--provider-error-summary datum))
                  datum))))

(defun consent-models--condition-provider-error-datum (error)
  "Return the first structured provider-error datum carried by ERROR, or nil."
  (cond
   ((and (consp error)
         (consent-models--provider-error-record-p (cadr error)))
    (cadr error))
   ((and (consp error)
         (consp (cdr error))
         (consent-models--provider-error-record-p (caddr error)))
    (caddr error))
   (t nil)))

(defun consent-models--transport-error-message (error)
  "Return ERROR as a concise string for transport diagnostics."
  (cond
   ((and (consp error) (stringp (cadr error)))
    (cadr error))
   ((stringp error)
    error)
   (t
    (error-message-string error))))

(defun consent-models--signal-provider-error (request error)
  "Map transport ERROR for REQUEST to a structured provider error."
  (if-let ((datum (consent-models--condition-provider-error-datum error)))
      (consent-models--signal-provider-error-datum
       request
       datum
       (if (and (consp error) (stringp (cadr error)))
           (cadr error)
         nil))
    (signal 'consent-models-error
            (list (consent-models--transport-error-message error)))))

(defun consent-models--model-source-datum (model)
  "Return MODEL as a normalized Scheme-readable source-library datum."
  (list
   (consent-models--field "id"
                          (consent-models--symbol (plist-get model :id)))
   (consent-models--field
    "roles"
    (mapcar #'consent-models--symbol (plist-get model :roles)))
   (consent-models--field "privacy"
                          (consent-models--symbol
                           (plist-get model :privacy)))
   (consent-models--field "status"
                          (consent-models--symbol
                           (plist-get model :status)))))

(defun consent-models--provider-source-datum (provider)
  "Return PROVIDER as a normalized Scheme-readable source-library datum."
  (append
   (list
    (consent-models--field "id"
                           (consent-models--symbol
                            (plist-get provider :id)))
    (consent-models--field "kind"
                           (consent-models--symbol
                            (plist-get provider :kind)))
    (consent-models--field "transport"
                           (consent-models--symbol
                            (plist-get provider :transport)))
    (consent-models--field "endpoint"
                           (plist-get provider :endpoint))
    (consent-models--field "available"
                           (consent-models--boolean
                            (plist-get provider :available))))
   (when-let ((credentials (plist-get provider :credentials)))
     (list (consent-models--field "credentials" credentials)))
   (list
    (consent-models--field
     "models"
     (mapcar #'consent-models--model-source-datum
             (plist-get provider :models))))))

(defun consent-models--source-openai-call (name &rest arguments)
  "Call source-backed OpenAI model procedure NAME with ARGUMENTS."
  (require 'consent-library)
  (apply #'consent--source-library-call
         "(agent models openai)" name arguments))

(defun consent-models--source-completion-result-value (request result)
  "Return completion value from source-backed RESULT, or signal its error."
  (unless (consent-models--record-p result "model-completion-result")
    (signal 'consent-models-error
            (list "model transport returned malformed completion result"
                  result)))
  (pcase (consent-models--symbol-name
          (consent-models--field-value result "status"))
    ("ok"
     (consent-models--field-value result "value"))
    ("error"
     (let ((datum (consent-models--field-value result "error"))
           (message (consent-models--field-value result "message")))
       (if (consent-models--provider-error-record-p datum)
           (consent-models--signal-provider-error-datum request datum message)
         (signal 'consent-models-error
                 (list (or message "model transport failed"))))))
    (_
     (signal 'consent-models-error
             (list "model transport returned unknown completion status"
                   result)))))

(defun consent-models--source-transport-options (options tools tool-choice)
  "Return OPTIONS enriched with normalized TOOLS and TOOL-CHOICE."
  (append
   (delq
    nil
    (list
     (when tools
       (consent-models--field "tools" tools))
     (when tool-choice
       (consent-models--field "tool-choice" tool-choice))))
   options))

(defun consent-models--source-single-value (value)
  "Return VALUE unwrapped from a single source-library value wrapper."
  (if (consent--multiple-values-p value)
      (let ((values (consent--multiple-values-values value)))
        (if (= (length values) 1)
            (car values)
          value))
    value))

(defun consent-models--source-openai-compatible-http-complete
    (provider model role prompt options)
  "Complete PROMPT through the source-backed OpenAI-compatible transport."
  (let* ((request
          (list :role (consent-models--symbol-name role)
                :prompt prompt
                :options options
                :provider provider
                :model model))
         (result
          (consent-models--source-openai-call
           "model-openai-compatible-http-completion-result"
           (consent-models--provider-source-datum provider)
           (consent-models--model-source-datum model)
           role
           prompt
           options)))
    (consent-models--source-completion-result-value
     request
     (consent-models--source-single-value result))))

;;;###autoload
(defun consent-models-complete (role prompt options &optional context)
  "Complete PROMPT using a model selected for ROLE and OPTIONS."
  (let* ((role-name (consent-models--expect-name role "model role"))
         (candidate (consent-models--select role-name options)))
    (unless candidate
      (signal 'consent-models-error
              (list "no registered provider model supports role" role-name)))
    (let* ((provider (plist-get candidate :provider))
           (model (plist-get candidate :model))
           (tools
            (consent-models--normalize-tools
             (consent-models--field-value-any
              options '("tools") nil)))
           (tool-choice
            (consent-models--normalize-tool-choice
             (consent-models--field-value-any
              options '("tool-choice" "tool_choice") nil)))
           (transport-options
            (consent-models--source-transport-options
             options tools tool-choice))
           (request-datum
            (consent-models--request-datum
             role-name prompt options provider model tools tool-choice)))
      (when (consent-models--remote-provider-p provider)
        (consent-policy-authorize-provider-routing
         request-datum
         (consent-models--symbol (plist-get provider :id))
         nil
         context)
        (signal 'consent-models-error
                (list "remote model transport is not configured")))
      (consent-models--ensure-local-transport provider)
      (let* ((request (list :role role-name
                            :prompt (consent-models--prompt-string prompt)
                            :options transport-options
                            :tools tools
                            :tool-choice tool-choice
                            :provider provider
                            :model model
                            :request-datum request-datum))
             (completion
              (condition-case error
                  (consent-models--source-openai-compatible-http-complete
                   provider
                   model
                   (consent-models--symbol role-name)
                   (plist-get request :prompt)
                   transport-options)
                (consent-models-error
                 (consent-models--signal-provider-error request error))
                (error
                 (consent-models--signal-provider-error request error)))))
        (unless (or (stringp completion)
                    (consent-models--model-message-p completion))
          (signal 'consent-models-error
                  (list "model transport must return completion text or model-message")))
        (consent-audit-record
         'model-completion
         `((provider . ,(plist-get provider :id))
           (model . ,(plist-get model :id))
           (role . ,role-name)
           (result . ok)))
        completion))))

(defun consent-models--model-datum (model)
  "Return Scheme-readable diagnostic datum for MODEL."
  (list
   (list (consent-models--symbol "model")
         (consent-models--symbol (plist-get model :id)))
   (list (consent-models--symbol "roles")
         (mapcar #'consent-models--symbol
                 (plist-get model :roles)))
   (list (consent-models--symbol "status")
         (consent-models--symbol (plist-get model :status)))
   (list (consent-models--symbol "privacy")
         (consent-models--symbol (plist-get model :privacy)))))

(defun consent-models--provider-datum (provider)
  "Return Scheme-readable diagnostic datum for PROVIDER."
  (append
   (list
    (list (consent-models--symbol "provider")
          (consent-models--symbol (plist-get provider :id)))
    (list (consent-models--symbol "kind")
          (consent-models--symbol (plist-get provider :kind)))
    (list (consent-models--symbol "transport")
          (consent-models--symbol (plist-get provider :transport)))
    (list (consent-models--symbol "available")
          (consent-models--boolean
           (consent-models--provider-available-p provider))))
   (when-let ((endpoint (plist-get provider :endpoint)))
     (list (list (consent-models--symbol "endpoint") endpoint)))
   (when-let ((credentials (plist-get provider :credentials)))
     (list
      (list (consent-models--symbol "credentials")
            (consent-redact credentials 'model-diagnostics))))
   (list
    (list (consent-models--symbol "models")
          (mapcar #'consent-models--model-datum
                  (plist-get provider :models))))))

;;;###autoload
(defun consent-models-diagnostics (&optional _options)
  "Return redacted model provider diagnostics."
  (list
   (consent-models--symbol "model-provider-diagnostics")
   (list
    (consent-models--symbol "providers")
    (mapcar #'consent-models--provider-datum
            consent-models--providers))))

;;;###autoload
(defun consent-models-providers ()
  "Return registered providers as redacted diagnostics."
  (cadr (consent-models-diagnostics)))

(defun consent-models--primitive-register-provider
    (arguments _context)
  "Primitive model-provider-register! over ARGUMENTS."
  (consent-models-register-provider! (car arguments)))

(defun consent-models--primitive-providers (_arguments _context)
  "Primitive model-providers over ARGUMENTS."
  (consent-models-providers))

(defun consent-models--primitive-route (arguments context)
  "Primitive model-route over ARGUMENTS."
  (consent-models-route (car arguments) (cadr arguments) context))

(defun consent-models--primitive-complete (arguments context)
  "Primitive model-complete over ARGUMENTS."
  (consent-models-complete
   (car arguments)
   (cadr arguments)
   (caddr arguments)
   context))

(defun consent-models--primitive-diagnostics
    (arguments _context)
  "Primitive model-provider-diagnostics over ARGUMENTS."
  (consent-models-diagnostics (car arguments)))

;;;###autoload
(defun consent-models-primitive-specs ()
  "Return primitive specs for the `(agent models primitive)' library."
  `(("primitive-model-provider-register!"
     ,#'consent-models--primitive-register-provider 1 1)
    ("primitive-model-providers" ,#'consent-models--primitive-providers 0 0)
    ("primitive-model-route" ,#'consent-models--primitive-route 1 2)
    ("primitive-model-complete" ,#'consent-models--primitive-complete 2 3)
    ("primitive-model-provider-diagnostics"
     ,#'consent-models--primitive-diagnostics 0 1)))

(provide 'consent-models)

;;; consent-models.el ends here
