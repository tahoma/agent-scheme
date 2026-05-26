;;; agent-scheme-repl.el --- Native Agent Scheme REPL session UX  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs-native buffers and commands for working with persistent Agent Scheme
;; sessions.  This module is a host adapter over `agent-scheme-session'; the
;; durable state remains the Scheme-readable session, transcript, event, and
;; audit datums owned by the runtime modules.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'agent-scheme-approval)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)
(require 'agent-scheme-session)
(require 'agent-scheme-transcript)

(defgroup agent-scheme-repl nil
  "Native REPL session UX for Agent Scheme."
  :group 'agent-scheme)

(defcustom agent-scheme-repl-default-named-session-id "repl-main"
  "Default id used when starting a named Agent Scheme REPL session."
  :type 'string
  :group 'agent-scheme-repl)

(defvar agent-scheme-current-session-id nil
  "Current Agent Scheme session id for native REPL commands.")

(defvar agent-scheme-mode-line-string ""
  "Mode-line status string for the current Agent Scheme session.")

(defvar agent-scheme-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c C-c") #'agent-scheme-repl-eval)
    map)
  "Keymap for `agent-scheme-repl-mode'.")

(define-derived-mode agent-scheme-status-mode special-mode "Agent"
  "Major mode for Agent Scheme session status buffers.")

(define-derived-mode agent-scheme-repl-mode special-mode "Agent Scheme"
  "Major mode for Agent Scheme REPL transcript buffers.")

(define-derived-mode agent-scheme-events-mode special-mode "Agent Events"
  "Major mode for Agent Scheme event timeline buffers.")

(define-derived-mode agent-scheme-approvals-mode special-mode "Agent Approvals"
  "Major mode for Agent Scheme approval request buffers.")

(defun agent-scheme-repl--project-root ()
  "Return the current project root, or `default-directory' when absent."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

;;;###autoload
(defun agent-scheme-repl-project-label ()
  "Return a stable display label for the current project session."
  (let* ((root (directory-file-name (agent-scheme-repl--project-root)))
         (name (file-name-nondirectory root))
         (label (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" name)))
    (if (string-empty-p label)
        "project"
      label)))

(defun agent-scheme-repl--project-session-id ()
  "Return the default session id for the current project."
  (concat "project-" (agent-scheme-repl-project-label)))

(defun agent-scheme-repl--symbol-named-p (value name)
  "Return non-nil when VALUE is an Agent Scheme symbol named NAME."
  (and (agent-scheme-symbol-p value)
       (equal (agent-scheme-symbol-name value) name)))

(defun agent-scheme-repl--field-value (datum name)
  "Return field NAME from Scheme-readable DATUM."
  (let ((field
         (seq-find
          (lambda (candidate)
            (and (consp candidate)
                 (agent-scheme-repl--symbol-named-p (car candidate) name)))
          (cdr-safe datum))))
    (cadr field)))

(defun agent-scheme-repl--session-id-from-datum (datum)
  "Return session id string from session DATUM."
  (let ((id (agent-scheme-repl--field-value datum "id")))
    (cond
     ((agent-scheme-symbol-p id)
      (agent-scheme-symbol-name id))
     ((stringp id)
      id)
     ((symbolp id)
      (symbol-name id))
     (t
      (format "%S" id)))))

(defun agent-scheme-repl--known-session-ids ()
  "Return known durable session ids as strings."
  (mapcar #'agent-scheme-repl--session-id-from-datum
          (agent-scheme-session-list)))

(defun agent-scheme-repl--read-session-id (prompt)
  "Read an Agent Scheme session id using PROMPT."
  (or (and agent-scheme-current-session-id
           (not (string-empty-p agent-scheme-current-session-id))
           (completing-read prompt
                            (agent-scheme-repl--known-session-ids)
                            nil t nil nil agent-scheme-current-session-id))
      (completing-read prompt
                       (agent-scheme-repl--known-session-ids)
                       nil t)))

(defun agent-scheme-repl--session (id)
  "Return live session object for ID."
  (agent-scheme-session--require id))

(defun agent-scheme-repl--session-datum (id)
  "Return public Scheme-readable session datum for ID."
  (or (agent-scheme-session-ref id)
      (signal 'agent-scheme-session-error
              (list (format "unknown session: %s" id)))))

(defun agent-scheme-repl--session-label (id)
  "Return native buffer label for session ID."
  (let ((session (agent-scheme-repl--session id)))
    (if (eq (agent-scheme-session-scope session) 'project)
        (let* ((root (agent-scheme-session-project-root session))
               (name (and root
                          (file-name-nondirectory
                           (directory-file-name root)))))
          (if (and name (not (string-empty-p name)))
              (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" name)
            id))
      id)))

(defun agent-scheme-repl--buffer-name (kind id)
  "Return native buffer name for KIND and session ID."
  (let ((label (agent-scheme-repl--session-label id)))
    (pcase kind
      ('status (format "*Agent: %s*" label))
      ('repl (format "*Agent Scheme: %s*" label))
      ('events (format "*Agent Events: %s*" label))
      ('audit (format "*Agent Audit: %s*" label))
      ('approvals (format "*Agent Approvals: %s*" label))
      (_ (format "*Agent %s: %s*" kind label)))))

(defun agent-scheme-repl--insert-datum (datum)
  "Insert DATUM as Scheme-readable text."
  (insert (agent-scheme-result->external datum)))

(defun agent-scheme-repl--render-datums (datums)
  "Insert DATUMS as a Scheme-readable stream."
  (dolist (datum datums)
    (agent-scheme-repl--insert-datum datum)
    (insert "\n\n")))

(defun agent-scheme-repl--render-transcript (events)
  "Insert transcript EVENTS as summaries followed by raw datums."
  (dolist (event events)
    (insert ";; " (agent-scheme-transcript-event-summary event) "\n")
    (agent-scheme-repl--insert-datum event)
    (insert "\n\n")))

(defun agent-scheme-repl--datum-contains-session-p (datum id-symbol)
  "Return non-nil when DATUM contains `(session ID-SYMBOL)'."
  (cond
   ((and (consp datum)
         (agent-scheme-repl--symbol-named-p (car datum) "session")
         (consp (cdr datum))
         (equal (cadr datum) id-symbol))
    t)
   ((consp datum)
    (or (agent-scheme-repl--datum-contains-session-p (car datum) id-symbol)
        (agent-scheme-repl--datum-contains-session-p (cdr datum) id-symbol)))
   ((vectorp datum)
    (seq-some
     (lambda (item)
       (agent-scheme-repl--datum-contains-session-p item id-symbol))
     datum))
   (t nil)))

(defun agent-scheme-repl--audit-entries-for-session (id)
  "Return audit entries associated with session ID in chronological order."
  (let ((id-symbol (agent-scheme-session--symbol id)))
    (nreverse
     (seq-filter
      (lambda (entry)
        (agent-scheme-repl--datum-contains-session-p entry id-symbol))
      (agent-scheme-audit-recent-entries)))))

(defun agent-scheme-repl--request-event-p (entry)
  "Return non-nil when ENTRY represents a pending agent request."
  (let ((record (agent-scheme-repl--field-value entry "record")))
    (and (consp record)
         (agent-scheme-repl--symbol-named-p (car record) "request"))))

(defun agent-scheme-repl--approval-entries-for-session (id)
  "Return approval records for session ID."
  (agent-scheme-approval-records id))

(defun agent-scheme-repl--update-mode-line (id)
  "Update `agent-scheme-mode-line-string' for session ID."
  (let* ((session (agent-scheme-repl--session id))
         (status (agent-scheme-session-status session)))
    (setq agent-scheme-mode-line-string
          (format "Agent[%s:%s]" id status))
    (force-mode-line-update t)))

(defun agent-scheme-repl--install-buffer-mode-line (id)
  "Use the current Agent Scheme session status in this buffer's mode line."
  (setq-local mode-line-format
              (list "%e" mode-line-front-space
                    mode-line-mule-info
                    mode-line-client
                    mode-line-modified
                    mode-line-remote
                    mode-line-frame-identification
                    mode-line-buffer-identification
                    "   "
                    'agent-scheme-mode-line-string
                    "   "
                    mode-line-modes
                    mode-line-misc-info
                    mode-line-end-spaces))
  (agent-scheme-repl--update-mode-line id))

(defun agent-scheme-repl--refresh-buffer (kind id mode render)
  "Refresh session buffer KIND for ID using MODE and RENDER."
  (let ((buffer (get-buffer-create
                 (agent-scheme-repl--buffer-name kind id))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall render)
        (goto-char (point-min))
        (funcall mode)
        (agent-scheme-repl--install-buffer-mode-line id)))
    buffer))

(defun agent-scheme-repl--refresh-status (id)
  "Refresh the conversation/status buffer for session ID."
  (agent-scheme-repl--refresh-buffer
   'status id #'agent-scheme-status-mode
   (lambda ()
     (agent-scheme-repl--insert-datum
      (list (agent-scheme-session--symbol "agent-status")
            (list (agent-scheme-session--symbol "current-session")
                  (agent-scheme-session--symbol id))
            (list (agent-scheme-session--symbol "session")
                  (agent-scheme-repl--session-datum id))))
     (insert "\n"))))

(defun agent-scheme-repl--refresh-transcript (id)
  "Refresh the REPL transcript buffer for session ID."
  (agent-scheme-repl--refresh-buffer
   'repl id #'agent-scheme-repl-mode
   (lambda ()
     (agent-scheme-repl--render-transcript
      (agent-scheme-repl--field-value
       (agent-scheme-repl--session-datum id)
       "transcript")))))

(defun agent-scheme-repl--refresh-events (id)
  "Refresh the event timeline buffer for session ID."
  (agent-scheme-repl--refresh-buffer
   'events id #'agent-scheme-events-mode
   (lambda ()
     (agent-scheme-repl--render-datums
      (agent-scheme-repl--field-value
       (agent-scheme-repl--session-datum id)
       "recent-events")))))

(defun agent-scheme-repl--refresh-audit (id)
  "Refresh the audit buffer for session ID."
  (agent-scheme-repl--refresh-buffer
   'audit id #'special-mode
   (lambda ()
     (agent-scheme-repl--render-datums
      (agent-scheme-repl--audit-entries-for-session id)))))

(defun agent-scheme-repl--refresh-approvals (id)
  "Refresh the approvals buffer for session ID."
  (agent-scheme-repl--refresh-buffer
   'approvals id #'agent-scheme-approvals-mode
   (lambda ()
     (agent-scheme-repl--render-datums
      (agent-scheme-repl--approval-entries-for-session id)))))

;;;###autoload
(defun agent-scheme-refresh-session-buffers (&optional id)
  "Refresh native buffers for session ID.
When ID is nil, use `agent-scheme-current-session-id'.  Return the status
buffer."
  (let ((session-id (or id agent-scheme-current-session-id)))
    (unless session-id
      (signal 'agent-scheme-session-error
              (list "no current Agent Scheme session")))
    (agent-scheme-repl--update-mode-line session-id)
    (let ((status (agent-scheme-repl--refresh-status session-id)))
      (agent-scheme-repl--refresh-transcript session-id)
      (agent-scheme-repl--refresh-events session-id)
      (agent-scheme-repl--refresh-audit session-id)
      (agent-scheme-repl--refresh-approvals session-id)
      status)))

(defun agent-scheme-repl--ensure-session (scope id)
  "Return a durable session id for SCOPE and ID, creating it when needed."
  (let* ((normalized-scope (agent-scheme-session--scope scope))
         (session-id
          (cond
           (id id)
           ((eq normalized-scope 'project)
            (agent-scheme-repl--project-session-id))
           ((eq normalized-scope 'named)
            agent-scheme-repl-default-named-session-id)
           (t
            (agent-scheme-session--generated-id normalized-scope)))))
    (unless (agent-scheme-session-ref session-id)
      (agent-scheme-session-create!
       normalized-scope
       (append
        (list :id session-id)
        (when (eq normalized-scope 'project)
          (list :project-root (agent-scheme-repl--project-root))))))
    session-id))

;;;###autoload
(defun agent-scheme-start-repl (&optional scope id)
  "Start or switch to a native Agent Scheme REPL session.
SCOPE defaults to `project'.  ID defaults to the project session id for project
sessions and `agent-scheme-repl-default-named-session-id' for named sessions.
Return the conversation/status buffer."
  (interactive
   (list
    (intern
     (completing-read "Agent Scheme session scope: "
                      '("project" "named")
                      nil t nil nil "project"))
    nil))
  (let ((session-id (agent-scheme-repl--ensure-session
                     (or scope 'project)
                     id)))
    (setq agent-scheme-current-session-id session-id)
    (let ((buffer (agent-scheme-refresh-session-buffers session-id)))
      (when (called-interactively-p 'interactive)
        (pop-to-buffer buffer))
      buffer)))

;;;###autoload
(defun agent-scheme-switch-session (id)
  "Switch native REPL buffers to session ID and return its status buffer."
  (interactive (list (agent-scheme-repl--read-session-id
                      "Switch to Agent Scheme session: ")))
  (setq agent-scheme-current-session-id id)
  (let ((buffer (agent-scheme-refresh-session-buffers id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun agent-scheme-inspect-session (&optional id)
  "Open the conversation/status buffer for session ID."
  (interactive (list (agent-scheme-repl--read-session-id
                      "Inspect Agent Scheme session: ")))
  (let ((buffer (agent-scheme-refresh-session-buffers
                 (or id agent-scheme-current-session-id))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun agent-scheme-stop-session (&optional id)
  "Retire session ID and refresh native buffers."
  (interactive (list (agent-scheme-repl--read-session-id
                      "Stop Agent Scheme session: ")))
  (let* ((session-id (or id agent-scheme-current-session-id))
         (datum (agent-scheme-session-retire! session-id)))
    (agent-scheme-refresh-session-buffers session-id)
    datum))

;;;###autoload
(defun agent-scheme-repl-eval-source (source &optional id options)
  "Evaluate SOURCE in session ID and refresh native buffers.
When ID is nil, use the current native session, creating the project session if
needed.  OPTIONS are passed to `agent-scheme-session-eval-source'."
  (interactive "sAgent Scheme source: ")
  (unless (or id agent-scheme-current-session-id)
    (agent-scheme-start-repl 'project))
  (let ((session-id (or id agent-scheme-current-session-id)))
    (condition-case condition
        (let ((value (agent-scheme-session-eval-source
                      session-id source options)))
          (agent-scheme-refresh-session-buffers session-id)
          (when (called-interactively-p 'interactive)
            (pop-to-buffer
             (get-buffer (agent-scheme-repl--buffer-name 'repl session-id))))
          value)
      (error
       (agent-scheme-refresh-session-buffers session-id)
       (signal (car condition) (cdr condition))))))

;;;###autoload
(defun agent-scheme-repl-eval (&optional source)
  "Read and evaluate Agent Scheme SOURCE in the current native REPL."
  (interactive)
  (let ((input
         (or source
             (if (use-region-p)
                 (buffer-substring-no-properties
                  (region-beginning)
                  (region-end))
               (read-string "Agent Scheme source: ")))))
    (agent-scheme-repl-eval-source input)))

(defun agent-scheme-repl--open-buffer (kind id)
  "Open native buffer KIND for session ID."
  (let ((buffer (agent-scheme-refresh-session-buffers
                 (or id agent-scheme-current-session-id))))
    (pcase kind
      ('status buffer)
      (_
       (get-buffer
        (agent-scheme-repl--buffer-name
         kind
         (or id agent-scheme-current-session-id)))))))

;;;###autoload
(defun agent-scheme-open-status (&optional id)
  "Open the Agent Scheme conversation/status buffer for session ID."
  (interactive)
  (let ((buffer (agent-scheme-repl--open-buffer 'status id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun agent-scheme-open-repl (&optional id)
  "Open the Agent Scheme REPL transcript buffer for session ID."
  (interactive)
  (let ((buffer (agent-scheme-repl--open-buffer 'repl id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun agent-scheme-open-events (&optional id)
  "Open the Agent Scheme event timeline buffer for session ID."
  (interactive)
  (let ((buffer (agent-scheme-repl--open-buffer 'events id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun agent-scheme-open-audit (&optional id)
  "Open the Agent Scheme audit buffer for session ID."
  (interactive)
  (let ((buffer (agent-scheme-repl--open-buffer 'audit id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun agent-scheme-open-approvals (&optional id)
  "Open the Agent Scheme approvals buffer for session ID."
  (interactive)
  (let ((buffer (agent-scheme-repl--open-buffer 'approvals id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(transient-define-prefix agent-scheme-dispatch ()
  "Agent Scheme native session commands."
  [["Session"
    ("s" "start/switch project" agent-scheme-start-repl)
    ("i" "inspect session" agent-scheme-inspect-session)
    ("x" "stop session" agent-scheme-stop-session)]
   ["Buffers"
    ("a" "status" agent-scheme-open-status)
    ("r" "repl transcript" agent-scheme-open-repl)
    ("e" "events" agent-scheme-open-events)
    ("u" "audit" agent-scheme-open-audit)
    ("p" "approvals" agent-scheme-open-approvals)]
   ["Evaluation"
    ("RET" "eval source" agent-scheme-repl-eval)]])

(define-key global-map (kbd "C-c a") #'agent-scheme-dispatch)

(provide 'agent-scheme-repl)

;;; agent-scheme-repl.el ends here
