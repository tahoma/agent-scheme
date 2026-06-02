;;; agent-scheme-models.el --- Model provider routing primitives  -*- lexical-binding: t; -*-
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
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'agent-scheme-audit)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(define-error 'agent-scheme-models-error
  "Agent Scheme model provider error"
  'agent-scheme-eval-error)

(defvar agent-scheme-models--providers nil
  "Registered model providers as normalized plists in registration order.")

(defcustom agent-scheme-models-transport-function
  #'agent-scheme-models-openai-compatible-http
  "Function used to complete local model requests.
The function receives PROVIDER, MODEL, REQUEST, and CONTEXT.  It is
called only after routing has selected a local provider whose
transport is `openai-compatible-http'."
  :type 'function
  :group 'agent-scheme)

(defun agent-scheme-models--symbol (name)
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

(defun agent-scheme-models--boolean (value)
  "Return VALUE as a Scheme boolean."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme-models--symbol-name (datum)
  "Return DATUM as a plain symbol/string name, or nil."
  (cond
   ((null datum)
    nil)
   ((agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)
   (t nil)))

(defun agent-scheme-models--expect-name (datum description)
  "Return DATUM as a string name or signal DESCRIPTION."
  (or (agent-scheme-models--symbol-name datum)
      (agent-scheme--eval-error "%s must be a symbol or string" description)))

(defun agent-scheme-models--record-head (datum)
  "Return DATUM's record head name, or nil."
  (and (consp datum)
       (not (and (consp (car datum))
                 (agent-scheme-models--symbol-name (caar datum))))
       (agent-scheme-models--symbol-name (car datum))))

(defun agent-scheme-models--field-pairs (datum)
  "Return field pairs from Scheme-readable DATUM."
  (when (consp datum)
    (let ((fields (if (agent-scheme-models--record-head datum)
                      (cdr datum)
                    datum)))
      (seq-filter
       (lambda (field)
         (and (consp field)
              (agent-scheme-models--symbol-name (car field))))
       fields))))

(defun agent-scheme-models--field-value (datum name &optional default)
  "Return field NAME from DATUM, or DEFAULT."
  (let ((found nil)
        value)
    (dolist (field (agent-scheme-models--field-pairs datum))
      (when (equal (agent-scheme-models--symbol-name (car field)) name)
        (setq found t)
        (setq value (cadr field))))
    (if found value default)))

(defun agent-scheme-models--proper-list (datum description)
  "Return DATUM as a proper list for DESCRIPTION."
  (agent-scheme--proper-list-elements datum description))

(defun agent-scheme-models--truthy-p (datum)
  "Return non-nil when DATUM is truthy in Scheme."
  (not (or (null datum) (eq datum agent-scheme-false))))

(defun agent-scheme-models--names-list (datum description)
  "Return DATUM as a list of string names for DESCRIPTION."
  (mapcar
   (lambda (entry)
     (agent-scheme-models--expect-name entry description))
   (agent-scheme-models--proper-list datum description)))

(defun agent-scheme-models--normalize-model (datum)
  "Return normalized model profile from Scheme DATUM."
  (let* ((id (agent-scheme-models--expect-name
              (agent-scheme-models--field-value datum "id")
              "model id"))
         (roles (agent-scheme-models--names-list
                 (or (agent-scheme-models--field-value datum "roles") '())
                 "model roles"))
         (privacy (or (agent-scheme-models--symbol-name
                       (agent-scheme-models--field-value datum "privacy"))
                      "public"))
         (status (or (agent-scheme-models--symbol-name
                      (agent-scheme-models--field-value datum "status"))
                     "available")))
    (list :id id
          :roles roles
          :privacy privacy
          :status status
          :raw datum)))

(defun agent-scheme-models--normalize-provider (datum)
  "Return normalized provider profile from Scheme DATUM."
  (unless (equal (agent-scheme-models--record-head datum) "model-provider")
    (signal 'agent-scheme-models-error
            (list "model-provider-register! expects a model-provider datum")))
  (let* ((id (agent-scheme-models--expect-name
              (agent-scheme-models--field-value datum "id")
              "provider id"))
         (kind (or (agent-scheme-models--symbol-name
                    (agent-scheme-models--field-value datum "kind"))
                   "local"))
         (transport (or (agent-scheme-models--symbol-name
                         (agent-scheme-models--field-value datum "transport"))
                        "openai-compatible-http"))
         (endpoint (agent-scheme-models--field-value datum "endpoint"))
         (credentials (agent-scheme-models--field-value datum "credentials"))
         (available (agent-scheme-models--field-value datum "available"
                                                     agent-scheme-true))
         (models
          (mapcar
           #'agent-scheme-models--normalize-model
           (agent-scheme-models--proper-list
            (or (agent-scheme-models--field-value datum "models") '())
            "provider models"))))
    (unless (or (not endpoint) (stringp endpoint))
      (agent-scheme--eval-error "provider endpoint must be a string"))
    (list :id id
          :kind kind
          :transport transport
          :endpoint endpoint
          :credentials credentials
          :available (agent-scheme-models--truthy-p available)
          :models models
          :raw datum)))

;;;###autoload
(defun agent-scheme-models-clear! ()
  "Clear registered model providers."
  (setq agent-scheme-models--providers nil)
  agent-scheme-unspecified)

;;;###autoload
(defun agent-scheme-models-register-provider! (datum)
  "Register a model provider from Scheme-readable DATUM."
  (let ((provider (agent-scheme-models--normalize-provider datum)))
    (setq agent-scheme-models--providers
          (append
           (cl-remove (plist-get provider :id)
                      agent-scheme-models--providers
                      :key (lambda (entry) (plist-get entry :id))
                      :test #'equal)
           (list provider)))
    (agent-scheme-audit-record
     'model-provider
     `((operation . register)
       (provider . ,(plist-get provider :id))
       (kind . ,(plist-get provider :kind))
       (transport . ,(plist-get provider :transport))))
    (agent-scheme-models--provider-datum provider)))

(defun agent-scheme-models--model-available-p (model)
  "Return non-nil when MODEL can be selected."
  (member (plist-get model :status) '("available" "ready")))

(defun agent-scheme-models--provider-available-p (provider)
  "Return non-nil when PROVIDER can be selected."
  (plist-get provider :available))

(defun agent-scheme-models--option-value (options name &optional default)
  "Return model routing option NAME from OPTIONS, or DEFAULT."
  (agent-scheme-models--field-value options name default))

(defun agent-scheme-models--candidate-provider-id (candidate)
  "Return CANDIDATE provider id."
  (plist-get (plist-get candidate :provider) :id))

(defun agent-scheme-models--candidate-model-id (candidate)
  "Return CANDIDATE model id."
  (plist-get (plist-get candidate :model) :id))

(defun agent-scheme-models--candidate-kind (candidate)
  "Return CANDIDATE provider kind."
  (plist-get (plist-get candidate :provider) :kind))

(defun agent-scheme-models--candidate-score (candidate)
  "Return routing preference score for CANDIDATE."
  (if (equal (agent-scheme-models--candidate-kind candidate) "local")
      0
    1))

(defun agent-scheme-models--role-candidates (role options)
  "Return provider/model candidates for ROLE and OPTIONS."
  (let ((provider-filter
         (agent-scheme-models--symbol-name
          (agent-scheme-models--option-value options "provider")))
        candidates)
    (dolist (provider agent-scheme-models--providers)
      (when (and (agent-scheme-models--provider-available-p provider)
                 (or (not provider-filter)
                     (equal provider-filter (plist-get provider :id))))
        (dolist (model (plist-get provider :models))
          (when (and (agent-scheme-models--model-available-p model)
                     (member role (plist-get model :roles)))
            (push (list :provider provider :model model) candidates)))))
    (cl-stable-sort (nreverse candidates) #'<
                    :key #'agent-scheme-models--candidate-score)))

(defun agent-scheme-models--select (role options)
  "Return the selected provider/model candidate for ROLE and OPTIONS."
  (car (agent-scheme-models--role-candidates role options)))

(defun agent-scheme-models--decision-datum (role candidate)
  "Return Scheme-readable routing decision for ROLE and CANDIDATE."
  (if candidate
      (let ((provider (plist-get candidate :provider))
            (model (plist-get candidate :model)))
        (append
         (list
          (agent-scheme-models--symbol "model-routing-decision")
          (list (agent-scheme-models--symbol "status")
                (agent-scheme-models--symbol "selected"))
          (list (agent-scheme-models--symbol "role")
                (agent-scheme-models--symbol role))
          (list (agent-scheme-models--symbol "provider")
                (agent-scheme-models--symbol (plist-get provider :id)))
          (list (agent-scheme-models--symbol "model")
                (agent-scheme-models--symbol (plist-get model :id)))
          (list (agent-scheme-models--symbol "kind")
                (agent-scheme-models--symbol (plist-get provider :kind)))
          (list (agent-scheme-models--symbol "transport")
                (agent-scheme-models--symbol
                 (plist-get provider :transport))))
         (when-let ((endpoint (plist-get provider :endpoint)))
           (list
            (list (agent-scheme-models--symbol "endpoint") endpoint)))))
    (list
     (agent-scheme-models--symbol "model-routing-decision")
     (list (agent-scheme-models--symbol "status")
           (agent-scheme-models--symbol "unavailable"))
     (list (agent-scheme-models--symbol "role")
           (agent-scheme-models--symbol role))
     (list (agent-scheme-models--symbol "reason")
           "no registered provider model supports role"))))

;;;###autoload
(defun agent-scheme-models-route (role options &optional context)
  "Return an inspectable routing decision for ROLE and OPTIONS."
  (let* ((role-name (agent-scheme-models--expect-name role "model role"))
         (candidate (agent-scheme-models--select role-name options))
         (decision (agent-scheme-models--decision-datum role-name candidate)))
    (agent-scheme-audit-record
     'model-routing
     `((role . ,role-name)
       (status . ,(if candidate 'selected 'unavailable))
       (provider . ,(and candidate
                         (agent-scheme-models--candidate-provider-id
                          candidate)))
       (model . ,(and candidate
                      (agent-scheme-models--candidate-model-id candidate)))))
    decision))

(defun agent-scheme-models--request-datum
    (role prompt options provider model)
  "Return Scheme-readable request datum for routing PROMPT."
  (list
   (agent-scheme-models--symbol "model-request")
   (list (agent-scheme-models--symbol "role")
         (agent-scheme-models--symbol role))
   (list (agent-scheme-models--symbol "provider")
         (agent-scheme-models--symbol (plist-get provider :id)))
   (list (agent-scheme-models--symbol "model")
         (agent-scheme-models--symbol (plist-get model :id)))
   (list (agent-scheme-models--symbol "prompt") prompt)
   (list (agent-scheme-models--symbol "options") options)))

(defun agent-scheme-models--ensure-local-transport (provider)
  "Signal unless PROVIDER can use the local transport."
  (unless (equal (plist-get provider :kind) "local")
    (signal 'agent-scheme-models-error
            (list "remote model transport is not configured")))
  (unless (equal (plist-get provider :transport)
                 "openai-compatible-http")
    (signal 'agent-scheme-models-error
            (list "unsupported local model transport"
                  (plist-get provider :transport)))))

(defun agent-scheme-models--prompt-string (prompt)
  "Return PROMPT as a string or signal."
  (unless (stringp prompt)
    (signal 'agent-scheme-models-error
            (list "model-complete prompt must be a string")))
  prompt)

(defun agent-scheme-models--remote-provider-p (provider)
  "Return non-nil when PROVIDER is remote."
  (equal (plist-get provider :kind) "remote"))

;;;###autoload
(defun agent-scheme-models-complete (role prompt options &optional context)
  "Complete PROMPT using a model selected for ROLE and OPTIONS."
  (let* ((role-name (agent-scheme-models--expect-name role "model role"))
         (candidate (agent-scheme-models--select role-name options)))
    (unless candidate
      (signal 'agent-scheme-models-error
              (list "no registered provider model supports role" role-name)))
    (let* ((provider (plist-get candidate :provider))
           (model (plist-get candidate :model))
           (request-datum
            (agent-scheme-models--request-datum
             role-name prompt options provider model)))
      (when (agent-scheme-models--remote-provider-p provider)
        (agent-scheme-policy-authorize-provider-routing
         request-datum
         (agent-scheme-models--symbol (plist-get provider :id))
         nil
         context)
        (signal 'agent-scheme-models-error
                (list "remote model transport is not configured")))
      (agent-scheme-models--ensure-local-transport provider)
      (let* ((request (list :role role-name
                            :prompt (agent-scheme-models--prompt-string prompt)
                            :options options
                            :request-datum request-datum))
             (completion
              (funcall agent-scheme-models-transport-function
                       provider model request context)))
        (unless (stringp completion)
          (signal 'agent-scheme-models-error
                  (list "model transport must return completion text")))
        (agent-scheme-audit-record
         'model-completion
         `((provider . ,(plist-get provider :id))
           (model . ,(plist-get model :id))
           (role . ,role-name)
           (result . ok)))
        completion))))

(defun agent-scheme-models--local-endpoint-p (endpoint)
  "Return non-nil when ENDPOINT targets a loopback host."
  (let* ((parsed (url-generic-parse-url endpoint))
         (scheme (url-type parsed))
         (host (url-host parsed)))
    (and host
         (member scheme '("http" "https"))
         (or (equal host "localhost")
             (equal host "127.0.0.1")
             (string-prefix-p "127." host)
             (equal host "::1")))))

(defun agent-scheme-models--completion-url (endpoint)
  "Return OpenAI-compatible chat completions URL for ENDPOINT."
  (let ((base (string-remove-suffix "/" endpoint)))
    (cond
     ((string-suffix-p "/chat/completions" base)
      base)
     ((string-suffix-p "/v1" base)
      (concat base "/chat/completions"))
     (t
      (concat base "/v1/chat/completions")))))

(defun agent-scheme-models--parse-openai-response (body)
  "Return completion text from OpenAI-compatible response BODY."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (data (json-read-from-string body))
         (choice (car (alist-get 'choices data)))
         (message (alist-get 'message choice))
         (content (alist-get 'content message)))
    (unless (stringp content)
      (signal 'agent-scheme-models-error
              (list "OpenAI-compatible response did not contain text")))
    content))

;;;###autoload
(defun agent-scheme-models-openai-compatible-http
    (provider model request _context)
  "Complete REQUEST through local OpenAI-compatible HTTP PROVIDER and MODEL."
  (let ((endpoint (plist-get provider :endpoint)))
    (unless (and endpoint (agent-scheme-models--local-endpoint-p endpoint))
      (signal 'agent-scheme-models-error
              (list "local model endpoint must use a loopback host")))
    (let* ((url-request-method "POST")
           (url-request-extra-headers
            '(("Content-Type" . "application/json")))
           (url-request-data
            (json-encode
             `((model . ,(plist-get model :id))
               (messages . [((role . "user")
                             (content . ,(plist-get request :prompt)))])
               (stream . :json-false))))
           (buffer
            (url-retrieve-synchronously
             (agent-scheme-models--completion-url endpoint)
             t
             nil
             30)))
      (unless buffer
        (signal 'agent-scheme-models-error
                (list "local model endpoint did not respond")))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (unless (or (search-forward "\r\n\r\n" nil t)
                        (progn
                          (goto-char (point-min))
                          (search-forward "\n\n" nil t)))
              (signal 'agent-scheme-models-error
                      (list "local model response had no HTTP body")))
            (agent-scheme-models--parse-openai-response
             (buffer-substring-no-properties (point) (point-max))))
        (kill-buffer buffer)))))

(defun agent-scheme-models--model-datum (model)
  "Return Scheme-readable diagnostic datum for MODEL."
  (list
   (list (agent-scheme-models--symbol "model")
         (agent-scheme-models--symbol (plist-get model :id)))
   (list (agent-scheme-models--symbol "roles")
         (mapcar #'agent-scheme-models--symbol
                 (plist-get model :roles)))
   (list (agent-scheme-models--symbol "status")
         (agent-scheme-models--symbol (plist-get model :status)))
   (list (agent-scheme-models--symbol "privacy")
         (agent-scheme-models--symbol (plist-get model :privacy)))))

(defun agent-scheme-models--provider-datum (provider)
  "Return Scheme-readable diagnostic datum for PROVIDER."
  (append
   (list
    (list (agent-scheme-models--symbol "provider")
          (agent-scheme-models--symbol (plist-get provider :id)))
    (list (agent-scheme-models--symbol "kind")
          (agent-scheme-models--symbol (plist-get provider :kind)))
    (list (agent-scheme-models--symbol "transport")
          (agent-scheme-models--symbol (plist-get provider :transport)))
    (list (agent-scheme-models--symbol "available")
          (agent-scheme-models--boolean
           (agent-scheme-models--provider-available-p provider))))
   (when-let ((endpoint (plist-get provider :endpoint)))
     (list (list (agent-scheme-models--symbol "endpoint") endpoint)))
   (when-let ((credentials (plist-get provider :credentials)))
     (list
      (list (agent-scheme-models--symbol "credentials")
            (agent-scheme-redact credentials 'model-diagnostics))))
   (list
    (list (agent-scheme-models--symbol "models")
          (mapcar #'agent-scheme-models--model-datum
                  (plist-get provider :models))))))

;;;###autoload
(defun agent-scheme-models-diagnostics (&optional _options)
  "Return redacted model provider diagnostics."
  (list
   (agent-scheme-models--symbol "model-provider-diagnostics")
   (list
    (agent-scheme-models--symbol "providers")
    (mapcar #'agent-scheme-models--provider-datum
            agent-scheme-models--providers))))

;;;###autoload
(defun agent-scheme-models-providers ()
  "Return registered providers as redacted diagnostics."
  (cadr (agent-scheme-models-diagnostics)))

(defun agent-scheme-models--primitive-register-provider
    (arguments _context)
  "Primitive model-provider-register! over ARGUMENTS."
  (agent-scheme-models-register-provider! (car arguments)))

(defun agent-scheme-models--primitive-providers (_arguments _context)
  "Primitive model-providers over ARGUMENTS."
  (agent-scheme-models-providers))

(defun agent-scheme-models--primitive-route (arguments context)
  "Primitive model-route over ARGUMENTS."
  (agent-scheme-models-route (car arguments) (cadr arguments) context))

(defun agent-scheme-models--primitive-complete (arguments context)
  "Primitive model-complete over ARGUMENTS."
  (agent-scheme-models-complete
   (car arguments)
   (cadr arguments)
   (caddr arguments)
   context))

(defun agent-scheme-models--primitive-diagnostics
    (arguments _context)
  "Primitive model-provider-diagnostics over ARGUMENTS."
  (agent-scheme-models-diagnostics (car arguments)))

;;;###autoload
(defun agent-scheme-models-primitive-specs ()
  "Return primitive specs for the `(agent models)' library."
  `(("model-provider-register!"
     ,#'agent-scheme-models--primitive-register-provider 1 1)
    ("model-providers" ,#'agent-scheme-models--primitive-providers 0 0)
    ("model-route" ,#'agent-scheme-models--primitive-route 1 2)
    ("model-complete" ,#'agent-scheme-models--primitive-complete 2 3)
    ("model-provider-diagnostics"
     ,#'agent-scheme-models--primitive-diagnostics 0 1)))

(provide 'agent-scheme-models)

;;; agent-scheme-models.el ends here
