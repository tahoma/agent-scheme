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

(defcustom consent-models-request-timeout-seconds 30
  "Default timeout in seconds for local OpenAI-compatible requests."
  :type 'integer
  :group 'consent)

(defcustom consent-models-transport-retry-count 1
  "Default number of bounded retries for local transport errors."
  :type 'integer
  :group 'consent)

(defconst consent-models--transport-detail-limit 240
  "Maximum diagnostic excerpt length copied into transport failures.")

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

(defun consent-models--integer-datum (value)
  "Return VALUE as a canonical exact integer datum."
  (consent--make-canonical-integer value))

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

(defun consent-models--option-integer (options names default)
  "Return integer option from OPTIONS field NAMES, or DEFAULT."
  (let ((value (consent-models--field-value-any options names nil)))
    (cond
     ((null value) default)
     ((and (consent-number-p value)
           (eq (consent-number-kind value) 'integer))
      (consent-number-value value))
     ((integerp value) value)
     (t default))))

(defun consent-models--bounded-text (text)
  "Return TEXT as a trimmed, redacted diagnostic excerpt."
  (let* ((rendered
          (string-trim
           (if (stringp text)
               text
             (format "%S" text))))
         (redacted
          (consent-redact rendered 'model-diagnostics)))
    (if (> (length redacted) consent-models--transport-detail-limit)
        (concat
         (substring redacted 0 (- consent-models--transport-detail-limit 3))
         "...")
      redacted)))

(defun consent-models--redaction-marker (kind source replacement policy)
  "Return a Scheme-readable redaction marker datum."
  (list
   (consent-models--symbol "redaction")
   (consent-models--field "kind" (consent-models--symbol kind))
   (consent-models--field "source" (consent-models--symbol source))
   (consent-models--field "replacement" replacement)
   (consent-models--field "policy" (consent-models--symbol policy))))

(defun consent-models--endpoint-origin (url)
  "Return URL's origin string, or nil when URL is malformed."
  (when url
    (let* ((parsed (url-generic-parse-url url))
           (scheme (url-type parsed))
           (host (url-host parsed))
           (port (url-port parsed))
           (default-port
            (pcase scheme
              ("http" 80)
              ("https" 443)
              (_ nil))))
      (when (and scheme host)
        (format "%s://%s%s"
                scheme
                host
                (if (and port
                         (not (equal port default-port)))
                    (format ":%s" port)
                  ""))))))

(defun consent-models--request-path (url)
  "Return URL's path component, defaulting to `/'."
  (let ((path (and url (url-filename (url-generic-parse-url url)))))
    (if (and path (> (length path) 0)) path "/")))

(defun consent-models--safe-request-datum (request)
  "Return redacted request metadata for REQUEST."
  (let* ((provider (plist-get request :provider))
         (model (plist-get request :model))
         (url (consent-models--completion-url (plist-get provider :endpoint))))
    (delq
     nil
     (list
      (consent-models--symbol "model-provider-request")
      (consent-models--field "role"
                             (consent-models--symbol
                              (plist-get request :role)))
      (consent-models--field "provider"
                             (consent-models--symbol
                              (plist-get provider :id)))
      (consent-models--field "model"
                             (consent-models--symbol
                              (plist-get model :id)))
      (consent-models--field "kind"
                             (consent-models--symbol
                              (plist-get provider :kind)))
      (consent-models--field "transport"
                             (consent-models--symbol
                              (plist-get provider :transport)))
      (when-let ((origin (consent-models--endpoint-origin url)))
        (consent-models--field "endpoint-origin" origin))
      (consent-models--field "request-path"
                             (consent-models--request-path url))
      (consent-models--field
       "prompt"
       (consent-models--redaction-marker
        'prompt
        'provider-request
        consent-redaction-local-only-replacement
        'local-only))
      (consent-models--field "timeout-seconds"
                             (consent-models--integer-datum
                              (or (plist-get request :timeout-seconds)
                                  consent-models-request-timeout-seconds)))
      (consent-models--field "retry-count"
                             (consent-models--integer-datum
                              (or (plist-get request :retry-count)
                                  consent-models-transport-retry-count)))))))

(defun consent-models--provider-error-record-p (datum)
  "Return non-nil when DATUM is a `model-provider-error' record."
  (consent-models--record-p datum "model-provider-error"))

(defun consent-models--provider-error-datum (request reason &rest fields)
  "Return a structured model-provider-error datum for REQUEST, REASON, and FIELDS."
  (let* ((provider (plist-get request :provider))
         (model (plist-get request :model)))
    (append
     (list
      (consent-models--symbol "model-provider-error")
      (consent-models--field "request"
                             (consent-models--safe-request-datum request))
      (consent-models--field "status"
                             (consent-models--symbol "unavailable"))
      (consent-models--field "provider"
                             (consent-models--symbol
                              (plist-get provider :id)))
      (consent-models--field "model"
                             (consent-models--symbol
                              (plist-get model :id)))
      (consent-models--field "transport"
                             (consent-models--symbol
                              (plist-get provider :transport)))
      (consent-models--field "reason" reason)
      (consent-models--field "retry"
                             (consent-models--symbol
                              "bounded-local-transport-retry"))
      (consent-models--field "task-state"
                             (consent-models--symbol "blocked")))
     (delq nil fields))))

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

(defun consent-models--http-response-data (buffer)
  "Return BUFFER's HTTP status, reason, and body as a plist."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((status-line
             (buffer-substring-no-properties
              (line-beginning-position)
              (line-end-position))))
        (unless (or (search-forward "\r\n\r\n" nil t)
                    (progn
                      (goto-char (point-min))
                      (search-forward "\n\n" nil t)))
          (signal 'consent-models-error
                  (list "local model response had no HTTP body")))
        (let ((status 0)
              (reason ""))
          (when (string-match
                 "\\`HTTP/[0-9.]+[[:space:]]+\\([0-9]+\\)\\(?:[[:space:]]+\\(.*\\)\\)?\\'"
                 status-line)
            (setq status (string-to-number (match-string 1 status-line)))
            (setq reason (or (match-string 2 status-line) "")))
          (list
           :status status
           :reason (string-trim reason)
           :body (buffer-substring-no-properties (point) (point-max))))))))

(defun consent-models--transport-error-message (error)
  "Return ERROR as a concise string for transport diagnostics."
  (cond
   ((and (consp error) (stringp (cadr error)))
    (cadr error))
   ((stringp error)
    error)
   (t
    (error-message-string error))))

(defun consent-models--network-error-datum (request error)
  "Return a structured network failure datum for REQUEST and ERROR."
  (let* ((detail (consent-models--bounded-text
                  (consent-models--transport-error-message error)))
         (timeout-seconds
          (or (plist-get request :timeout-seconds)
              consent-models-request-timeout-seconds))
         (class
          (cond
           ((string-match-p "timed out\\|timeout\\|did not respond" detail)
            "timeout")
           ((string-match-p "refused" detail)
            "connection-refused")
           ((string-match-p "resolve\\|name or service" detail)
            "dns-failure")
           (t
            "request-error")))
         (reason
          (if (string= class "timeout")
              (format "request timed out after %ss" timeout-seconds)
            detail)))
    (consent-models--provider-error-datum
     request
     reason
     (consent-models--field "phase" (consent-models--symbol "network"))
     (consent-models--field
      "network"
      (delq
       nil
       (list
        (consent-models--symbol "network-failure")
        (consent-models--field "class" (consent-models--symbol class))
        (consent-models--field "detail" detail)))))))

(defun consent-models--http-error-datum
    (request status reason-phrase body elapsed-ms)
  "Return a structured HTTP failure datum for REQUEST."
  (let* ((excerpt (consent-models--bounded-text body))
         (reason
          (string-trim
           (format "HTTP %s%s%s"
                   status
                   (if (and reason-phrase
                            (> (length reason-phrase) 0))
                       (format " %s" reason-phrase)
                     "")
                   (if (> (length excerpt) 0)
                       (format ": %s" excerpt)
                     "")))))
    (consent-models--provider-error-datum
     request
     reason
     (consent-models--field "phase" (consent-models--symbol "http"))
     (when elapsed-ms
       (consent-models--field
        "elapsed-ms"
        (consent-models--integer-datum elapsed-ms)))
     (consent-models--field
      "http"
      (delq
       nil
       (list
        (consent-models--symbol "http-failure")
        (consent-models--field
         "status"
         (consent-models--integer-datum status))
        (when (and reason-phrase (> (length reason-phrase) 0))
          (consent-models--field "reason-phrase" reason-phrase))
        (when (> (length excerpt) 0)
          (consent-models--field "body-excerpt" excerpt))))))))

(defun consent-models--decode-error-datum
    (request error body elapsed-ms &optional http-status)
  "Return a structured decode failure datum for REQUEST."
  (let ((detail (consent-models--bounded-text
                 (consent-models--transport-error-message error)))
        (excerpt (consent-models--bounded-text body)))
    (consent-models--provider-error-datum
     request
     (format "response decode failed: %s" detail)
     (consent-models--field "phase" (consent-models--symbol "decode"))
     (when elapsed-ms
       (consent-models--field
        "elapsed-ms"
        (consent-models--integer-datum elapsed-ms)))
     (consent-models--field
      "decode"
      (delq
       nil
       (list
        (consent-models--symbol "decode-failure")
        (when http-status
          (consent-models--field
           "http-status"
           (consent-models--integer-datum http-status)))
        (consent-models--field "detail" detail)
        (when (> (length excerpt) 0)
          (consent-models--field "body-excerpt" excerpt))))))))

(defun consent-models--signal-provider-error (request error)
  "Map transport ERROR for REQUEST to a structured provider error."
  (if-let ((datum (consent-models--condition-provider-error-datum error)))
      (consent-models--signal-provider-error-datum
       request
       datum
       (if (and (consp error) (stringp (cadr error)))
           (cadr error)
         nil))
    (consent-models--signal-provider-error-datum
     request
     (consent-models--network-error-datum request error))))

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
                            :options options
                            :tools tools
                            :tool-choice tool-choice
                            :timeout-seconds
                            (consent-models--option-integer
                             options
                             '("timeout-seconds" "timeout_seconds")
                             consent-models-request-timeout-seconds)
                            :retry-count
                            (consent-models--option-integer
                             options
                             '("retry-count" "retry_count")
                             consent-models-transport-retry-count)
                            :provider provider
                            :model model
                            :request-datum request-datum))
             (completion
              (condition-case error
                  (funcall consent-models-transport-function
                           provider model request context)
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

(defun consent-models--schema-field-p (value)
  "Return non-nil when VALUE is a Scheme-readable field entry."
  (and (consp value)
       (consent-models--symbol-name (car value))))

(defun consent-models--schema-fields-p (value)
  "Return non-nil when VALUE is a list of Scheme-readable fields."
  (and (listp value)
       (not (null value))
       (seq-every-p #'consent-models--schema-field-p value)))

(defun consent-models--json-value (datum)
  "Return DATUM projected into the JSON subset used at the model edge."
  (cond
   ((eq datum consent-false)
    :json-false)
   ((eq datum consent-true)
    t)
   ((consent-number-p datum)
    (consent-number-value datum))
   ((consent-symbol-p datum)
    (consent-symbol-name datum))
   ((symbolp datum)
    (symbol-name datum))
   ((stringp datum)
    datum)
   ((vectorp datum)
    (vconcat (mapcar #'consent-models--json-value (append datum nil))))
   ((consent-models--schema-fields-p datum)
    (mapcar
     (lambda (field)
       (cons (consent-models--expect-name (car field) "schema field")
             (consent-models--json-value
              (if (and (consp (cdr field))
                       (null (cddr field)))
                  (cadr field)
                (cdr field)))))
     datum))
   ((consp datum)
    (vconcat (mapcar #'consent-models--json-value datum)))
   ((null datum)
    [])
   (t datum)))

(defun consent-models--tool-json (tool)
  "Return TOOL as an OpenAI-compatible JSON object."
  (let ((schema (consent-models--field-value tool "schema")))
    (unless (consent-models--record-p schema "openai-tool")
      (signal 'consent-models-error
              (list "model-tool schema must be an openai-tool datum")))
    (consent-models--json-value (cdr schema))))

(defun consent-models--tool-choice-json (tool-choice)
  "Return TOOL-CHOICE projected into OpenAI-compatible JSON."
  (cond
   ((not tool-choice)
    nil)
   ((consent-models--model-tool-p tool-choice)
    (let* ((name (consent-models--field-value tool-choice "name"))
           (name-text (consent-models--expect-name name "tool name")))
      `((type . "function")
        (function . ((name . ,name-text))))))
   (t
    (consent-models--expect-name tool-choice "tool-choice"))))

(defun consent-models--openai-request-data (model request)
  "Return JSON request payload for MODEL and normalized REQUEST."
  (let ((payload
         `((model . ,(plist-get model :id))
           (messages . [((role . "user")
                         (content . ,(plist-get request :prompt)))])
           (stream . :json-false))))
    (when-let ((tools (plist-get request :tools)))
      (setq payload
            (append payload
                    `((tools . ,(vconcat
                                 (mapcar #'consent-models--tool-json
                                         tools)))))))
    (when-let ((tool-choice
                (consent-models--tool-choice-json
                 (plist-get request :tool-choice))))
      (setq payload
            (append payload
                    `((tool_choice . ,tool-choice)))))
    (json-encode payload)))

(defun consent-models--json-object-p (value)
  "Return non-nil when VALUE is a decoded JSON object alist."
  (and (listp value)
       (seq-every-p (lambda (entry)
                      (and (consp entry) (symbolp (car entry))))
                    value)))

(defun consent-models--json->datum (value)
  "Return decoded JSON VALUE as a Scheme-readable datum."
  (cond
   ((eq value :json-false) consent-false)
   ((eq value :json-null) consent-false)
   ((eq value t) consent-true)
   ((stringp value) value)
   ((integerp value) (consent--make-canonical-integer value))
   ((numberp value) value)
   ((vectorp value)
    (mapcar #'consent-models--json->datum (append value nil)))
   ((consent-models--json-object-p value)
    (mapcar
     (lambda (entry)
       (list (consent-models--symbol (symbol-name (car entry)))
             (consent-models--json->datum (cdr entry))))
     value))
   ((listp value)
    (mapcar #'consent-models--json->datum value))
   (t value)))

(defun consent-models--parse-tool-arguments (arguments)
  "Decode OpenAI function ARGUMENTS into a Scheme-readable alist."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (json-false :json-false)
         (json-null :json-null)
         (decoded
          (cond
           ((stringp arguments)
            (if (string-empty-p arguments)
                '()
              (json-read-from-string arguments)))
           ((consent-models--json-object-p arguments)
            arguments)
           (t
            (signal 'consent-models-error
                    (list "OpenAI tool arguments must be a JSON object"))))))
    (unless (or (null decoded)
                (consent-models--json-object-p decoded))
      (signal 'consent-models-error
              (list "OpenAI tool arguments must be a JSON object")))
    (consent-models--json->datum decoded)))

(defun consent-models--parse-tool-call (tool-call)
  "Decode one OpenAI-compatible TOOL-CALL object."
  (let* ((id (alist-get 'id tool-call))
         (function (alist-get 'function tool-call))
         (name (and function (alist-get 'name function)))
         (arguments (and function (alist-get 'arguments function))))
    (unless (stringp name)
      (signal 'consent-models-error
              (list "OpenAI tool call did not contain a function name")))
    (append
     (list
      (consent-models--symbol "tool-call"))
     (when (stringp id)
       (list (list (consent-models--symbol "id") id)))
     (list
      (list (consent-models--symbol "name")
            (consent-models--symbol name))
      (list (consent-models--symbol "arguments")
            (consent-models--parse-tool-arguments arguments))))))

(defun consent-models--parse-openai-response (body)
  "Return completion data from OpenAI-compatible response BODY."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (json-false :json-false)
         (json-null :json-null)
         (data (json-read-from-string body))
         (choice (car (alist-get 'choices data)))
         (message (alist-get 'message choice))
         (content (alist-get 'content message))
         (tool-calls (alist-get 'tool_calls message)))
    (cond
     ((and tool-calls (not (null tool-calls)))
      (list
       (consent-models--symbol "model-message")
       (list (consent-models--symbol "text")
             (if (stringp content) content ""))
       (list (consent-models--symbol "tool-calls")
             (mapcar #'consent-models--parse-tool-call tool-calls))))
     ((stringp content)
      content)
     (t
      (signal 'consent-models-error
              (list "OpenAI-compatible response did not contain text"))))))

(defun consent-models--retrieve-synchronously (url request)
  "Retrieve URL for REQUEST with bounded local retries."
  (let ((attempts (1+ (max 0 (or (plist-get request :retry-count) 0))))
        (timeout (or (plist-get request :timeout-seconds)
                     consent-models-request-timeout-seconds))
        last-error
        buffer)
    (dotimes (_ attempts)
      (unless buffer
        (condition-case error
            (setq buffer
                  (url-retrieve-synchronously url t nil timeout))
          (error
           (setq last-error error)))))
    (or buffer
        (if last-error
            (signal (car last-error) (cdr last-error))
          (signal 'consent-models-error
                  (list "local model endpoint did not respond"))))))

;;;###autoload
(defun consent-models-openai-compatible-http
    (provider model request _context)
  "Complete REQUEST through local OpenAI-compatible HTTP PROVIDER and MODEL."
  (let ((endpoint (plist-get provider :endpoint)))
    (unless (and endpoint (consent-models--local-endpoint-p endpoint))
      (signal 'consent-models-error
              (list "local model endpoint must use a loopback host")))
    (let* ((started (float-time))
           (url (consent-models--completion-url endpoint))
           (url-request-method "POST")
           (url-request-extra-headers
            '(("Content-Type" . "application/json")))
           (url-request-data
            (consent-models--openai-request-data model request))
           (buffer
            (consent-models--retrieve-synchronously
             url
             request)))
      (unwind-protect
          (let* ((response (consent-models--http-response-data buffer))
                 (status (plist-get response :status))
                 (reason-phrase (plist-get response :reason))
                 (body (plist-get response :body))
                 (elapsed-ms
                  (truncate (* 1000.0 (- (float-time) started)))))
            (if (>= status 400)
                (consent-models--signal-provider-error-datum
                 request
                 (consent-models--http-error-datum
                  request status reason-phrase body elapsed-ms))
              (condition-case error
                  (consent-models--parse-openai-response body)
                (consent-models-error
                 (consent-models--signal-provider-error-datum
                  request
                  (consent-models--decode-error-datum
                   request error body elapsed-ms status)))
                (error
                 (consent-models--signal-provider-error-datum
                  request
                  (consent-models--decode-error-datum
                   request error body elapsed-ms status))))))
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
