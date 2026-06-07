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
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'consent-audit)
(require 'consent-policy)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)

(define-error 'consent-models-error
  "Consent Scheme model provider error"
  'consent-eval-error)

(defvar consent-models--providers nil
  "Registered model providers as normalized plists in registration order.")

(defcustom consent-models-transport-function
  #'consent-models-openai-compatible-http
  "Function used to complete local model requests.
The function receives PROVIDER, MODEL, REQUEST, and CONTEXT.  It is
called only after routing has selected a local provider whose
transport is `openai-compatible-http'."
  :type 'function
  :group 'consent)

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
    (role prompt options provider model)
  "Return Scheme-readable request datum for routing PROMPT."
  (list
   (consent-models--symbol "model-request")
   (list (consent-models--symbol "role")
         (consent-models--symbol role))
   (list (consent-models--symbol "provider")
         (consent-models--symbol (plist-get provider :id)))
   (list (consent-models--symbol "model")
         (consent-models--symbol (plist-get model :id)))
   (list (consent-models--symbol "prompt") prompt)
   (list (consent-models--symbol "options") options)))

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
           (request-datum
            (consent-models--request-datum
             role-name prompt options provider model)))
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
                            :options options
                            :request-datum request-datum))
             (completion
              (funcall consent-models-transport-function
                       provider model request context)))
        (unless (stringp completion)
          (signal 'consent-models-error
                  (list "model transport must return completion text")))
        (consent-audit-record
         'model-completion
         `((provider . ,(plist-get provider :id))
           (model . ,(plist-get model :id))
           (role . ,role-name)
           (result . ok)))
        completion))))

(defun consent-models--local-endpoint-p (endpoint)
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

(defun consent-models--completion-url (endpoint)
  "Return OpenAI-compatible chat completions URL for ENDPOINT."
  (let ((base (string-remove-suffix "/" endpoint)))
    (cond
     ((string-suffix-p "/chat/completions" base)
      base)
     ((string-suffix-p "/v1" base)
      (concat base "/chat/completions"))
     (t
      (concat base "/v1/chat/completions")))))

(defun consent-models--parse-openai-response (body)
  "Return completion text from OpenAI-compatible response BODY."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (data (json-read-from-string body))
         (choice (car (alist-get 'choices data)))
         (message (alist-get 'message choice))
         (content (alist-get 'content message)))
    (unless (stringp content)
      (signal 'consent-models-error
              (list "OpenAI-compatible response did not contain text")))
    content))

;;;###autoload
(defun consent-models-openai-compatible-http
    (provider model request _context)
  "Complete REQUEST through local OpenAI-compatible HTTP PROVIDER and MODEL."
  (let ((endpoint (plist-get provider :endpoint)))
    (unless (and endpoint (consent-models--local-endpoint-p endpoint))
      (signal 'consent-models-error
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
             (consent-models--completion-url endpoint)
             t
             nil
             30)))
      (unless buffer
        (signal 'consent-models-error
                (list "local model endpoint did not respond")))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (unless (or (search-forward "\r\n\r\n" nil t)
                        (progn
                          (goto-char (point-min))
                          (search-forward "\n\n" nil t)))
              (signal 'consent-models-error
                      (list "local model response had no HTTP body")))
            (consent-models--parse-openai-response
             (buffer-substring-no-properties (point) (point-max))))
        (kill-buffer buffer)))))

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
  "Return primitive specs for the `(agent models)' library."
  `(("model-provider-register!"
     ,#'consent-models--primitive-register-provider 1 1)
    ("model-providers" ,#'consent-models--primitive-providers 0 0)
    ("model-route" ,#'consent-models--primitive-route 1 2)
    ("model-complete" ,#'consent-models--primitive-complete 2 3)
    ("model-provider-diagnostics"
     ,#'consent-models--primitive-diagnostics 0 1)))

(provide 'consent-models)

;;; consent-models.el ends here
