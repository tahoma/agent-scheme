;;; consent-repl.el --- Native Consent Scheme REPL session UX  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Emacs-native buffers and commands for working with persistent Consent Scheme
;; sessions.  This module is a host adapter over `consent-session'; the
;; durable state remains the Scheme-readable session, transcript, event, and
;; audit datums owned by the runtime modules.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'consent-approval)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-macro)
(require 'consent-reader)
(require 'consent-result)
(require 'consent-session)
(require 'consent-transcript)

(defgroup consent-repl nil
  "Native REPL session UX for Consent Scheme."
  :group 'consent)

(defcustom consent-repl-default-named-session-id "repl-main"
  "Default id used when starting a named Consent Scheme REPL session."
  :type 'string
  :group 'consent-repl)

;; The native REPL commands and the Scheme `(agent session)' verbs share one
;; default-session pointer: `consent-session-current-id' (defined in the lower
;; `consent-session' layer).  Aliasing keeps the historical command-facing name
;; while a `switch-session'/`set-default-session!' verb run in the REPL changes
;; which session subsequent interactive forms evaluate in.
(defvaralias 'consent-current-session-id 'consent-session-current-id
  "Current Consent Scheme session id for native REPL commands.")

(defvar consent-mode-line-string ""
  "Mode-line status string for the current Consent Scheme session.")

(defvar consent-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c C-c") #'consent-repl-eval)
    map)
  "Keymap for `consent-repl-mode'.")

(define-derived-mode consent-status-mode special-mode "Consent"
  "Major mode for Consent Scheme session status buffers.")

(define-derived-mode consent-repl-mode special-mode "Consent Scheme"
  "Major mode for Consent Scheme REPL transcript buffers.")

(define-derived-mode consent-events-mode special-mode "Consent Events"
  "Major mode for Consent Scheme event timeline buffers.")

(define-derived-mode consent-macroexpand-mode special-mode
  "Consent Macroexpand"
  "Major mode for Consent Scheme macro expansion buffers.")

(define-derived-mode consent-approvals-mode special-mode "Consent Approvals"
  "Major mode for Consent Scheme approval request buffers.")

(defun consent-repl--project-root ()
  "Return the current project root, or `default-directory' when absent."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

;;;###autoload
(defun consent-repl-project-label ()
  "Return a stable display label for the current project session."
  (let* ((root (directory-file-name (consent-repl--project-root)))
         (name (file-name-nondirectory root))
         (label (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" name)))
    (if (string-empty-p label)
        "project"
      label)))

(defun consent-repl--project-session-id ()
  "Return the default session id for the current project."
  (concat "project-" (consent-repl-project-label)))

(defun consent-repl--symbol-named-p (value name)
  "Return non-nil when VALUE is an Consent Scheme symbol named NAME."
  (and (consent-symbol-p value)
       (equal (consent-symbol-name value) name)))

(defun consent-repl--field-value (datum name)
  "Return field NAME from Scheme-readable DATUM."
  (let ((field
         (seq-find
          (lambda (candidate)
            (and (consp candidate)
                 (consent-repl--symbol-named-p (car candidate) name)))
          (cdr-safe datum))))
    (cadr field)))

(defun consent-repl--session-id-from-datum (datum)
  "Return session id string from session DATUM."
  (let ((id (consent-repl--field-value datum "id")))
    (cond
     ((consent-symbol-p id)
      (consent-symbol-name id))
     ((stringp id)
      id)
     ((symbolp id)
      (symbol-name id))
     (t
      (format "%S" id)))))

(defun consent-repl--known-session-ids ()
  "Return known durable session ids as strings."
  (mapcar #'consent-repl--session-id-from-datum
          (consent-session-list)))

(defun consent-repl--read-session-id (prompt)
  "Read an Consent Scheme session id using PROMPT."
  (or (and consent-current-session-id
           (not (string-empty-p consent-current-session-id))
           (completing-read prompt
                            (consent-repl--known-session-ids)
                            nil t nil nil consent-current-session-id))
      (completing-read prompt
                       (consent-repl--known-session-ids)
                       nil t)))

(defun consent-repl--session (id)
  "Return live session object for ID."
  (consent-session--require id))

(defun consent-repl--session-datum (id)
  "Return public Scheme-readable session datum for ID."
  (or (consent-session-ref id)
      (signal 'consent-session-error
              (list (format "unknown session: %s" id)))))

(defun consent-repl--session-label (id)
  "Return native buffer label for session ID."
  (let ((session (consent-repl--session id)))
    (if (eq (consent-session-scope session) 'project)
        (let* ((root (consent-session-project-root session))
               (name (and root
                          (file-name-nondirectory
                           (directory-file-name root)))))
          (if (and name (not (string-empty-p name)))
              (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" name)
            id))
      id)))

(defun consent-repl--buffer-name (kind id)
  "Return native buffer name for KIND and session ID."
  (let ((label (consent-repl--session-label id)))
    (pcase kind
      ('status (format "*Consent: %s*" label))
      ('repl (format "*Consent Scheme: %s*" label))
      ('events (format "*Consent Events: %s*" label))
      ('macroexpand (format "*Consent Macroexpand: %s*" label))
      ('audit (format "*Consent Audit: %s*" label))
      ('approvals (format "*Consent Approvals: %s*" label))
      (_ (format "*Consent %s: %s*" kind label)))))

(defun consent-repl--insert-datum (datum)
  "Insert DATUM as Scheme-readable text."
  (insert (consent-result->external datum)))

(defun consent-repl--render-datums (datums)
  "Insert DATUMS as a Scheme-readable stream."
  (dolist (datum datums)
    (consent-repl--insert-datum datum)
    (insert "\n\n")))

(defun consent-repl--render-section (heading datum)
  "Insert HEADING and DATUM as a Scheme-readable buffer section."
  (insert ";; " heading "\n")
  (consent-repl--insert-datum datum)
  (insert "\n\n"))

(defun consent-repl--render-transcript (events)
  "Insert transcript EVENTS as summaries followed by raw datums."
  (dolist (event events)
    (insert ";; " (consent-transcript-event-summary event) "\n")
    (consent-repl--insert-datum event)
    (insert "\n\n")))

(defun consent-repl--datum-contains-session-p (datum id-symbol)
  "Return non-nil when DATUM contains `(session ID-SYMBOL)'."
  (cond
   ((and (consp datum)
         (consent-repl--symbol-named-p (car datum) "session")
         (consp (cdr datum))
         (equal (cadr datum) id-symbol))
    t)
   ((consp datum)
    (or (consent-repl--datum-contains-session-p (car datum) id-symbol)
        (consent-repl--datum-contains-session-p (cdr datum) id-symbol)))
   ((vectorp datum)
    (seq-some
     (lambda (item)
       (consent-repl--datum-contains-session-p item id-symbol))
     datum))
   (t nil)))

(defun consent-repl--audit-entries-for-session (id)
  "Return audit entries associated with session ID in chronological order."
  (let ((id-symbol (consent-session--symbol id)))
    (nreverse
     (seq-filter
      (lambda (entry)
        (consent-repl--datum-contains-session-p entry id-symbol))
      (consent-audit-recent-entries)))))

(defun consent-repl--request-event-p (entry)
  "Return non-nil when ENTRY represents a pending agent request."
  (let ((record (consent-repl--field-value entry "record")))
    (and (consp record)
         (consent-repl--symbol-named-p (car record) "request"))))

(defun consent-repl--approval-entries-for-session (id)
  "Return approval records for session ID."
  (consent-approval-records id))

(defun consent-repl--update-mode-line (id)
  "Update `consent-mode-line-string' for session ID."
  (let* ((session (consent-repl--session id))
         (status (consent-session-status session)))
    (setq consent-mode-line-string
          (format "Consent[%s:%s]" id status))
    (force-mode-line-update t)))

(defun consent-repl--install-buffer-mode-line (id)
  "Use the current Consent Scheme session status in this buffer's mode line."
  (setq-local mode-line-format
              (list "%e" mode-line-front-space
                    mode-line-mule-info
                    mode-line-client
                    mode-line-modified
                    mode-line-remote
                    mode-line-frame-identification
                    mode-line-buffer-identification
                    "   "
                    'consent-mode-line-string
                    "   "
                    mode-line-modes
                    mode-line-misc-info
                    mode-line-end-spaces))
  (consent-repl--update-mode-line id))

(defun consent-repl--refresh-buffer (kind id mode render)
  "Refresh session buffer KIND for ID using MODE and RENDER."
  (let ((buffer (get-buffer-create
                 (consent-repl--buffer-name kind id))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall render)
        (goto-char (point-min))
        (funcall mode)
        (consent-repl--install-buffer-mode-line id)))
    buffer))

(defun consent-repl--refresh-status (id)
  "Refresh the conversation/status buffer for session ID."
  (consent-repl--refresh-buffer
   'status id #'consent-status-mode
   (lambda ()
     (consent-repl--insert-datum
      (list (consent-session--symbol "agent-status")
            (list (consent-session--symbol "current-session")
                  (consent-session--symbol id))
            (list (consent-session--symbol "session")
                  (consent-repl--session-datum id))))
     (insert "\n"))))

(defun consent-repl--refresh-transcript (id)
  "Refresh the REPL transcript buffer for session ID."
  (consent-repl--refresh-buffer
   'repl id #'consent-repl-mode
   (lambda ()
     (consent-repl--render-transcript
      (consent-repl--field-value
       (consent-repl--session-datum id)
       "transcript")))))

(defun consent-repl--refresh-events (id)
  "Refresh the event timeline buffer for session ID."
  (consent-repl--refresh-buffer
   'events id #'consent-events-mode
   (lambda ()
     (consent-repl--render-datums
      (consent-repl--field-value
       (consent-repl--session-datum id)
       "recent-events")))))

(defun consent-repl--refresh-audit (id)
  "Refresh the audit buffer for session ID."
  (consent-repl--refresh-buffer
   'audit id #'special-mode
   (lambda ()
     (consent-repl--render-datums
      (consent-repl--audit-entries-for-session id)))))

(defun consent-repl--refresh-approvals (id)
  "Refresh the approvals buffer for session ID."
  (consent-repl--refresh-buffer
   'approvals id #'consent-approvals-mode
   (lambda ()
     (consent-repl--render-datums
      (consent-repl--approval-entries-for-session id)))))

(defun consent-repl--read-single-form (source)
  "Read exactly one Consent Scheme form from SOURCE."
  (let ((forms (consent-read-all source)))
    (unless (and (consp forms) (null (cdr forms)))
      (signal 'consent-eval-error
              (list "macroexpand view expects exactly one form")))
    (car forms)))

(defun consent-repl--macroexpand-datum (source id options one-step)
  "Return a macro expansion datum for SOURCE in session ID."
  (let* ((session (consent-repl--session id))
         (form (consent-repl--read-single-form source))
         (environment (consent-session-environment session))
         (context (consent-session-context session)))
    (if one-step
        (consent-macroexpand-1 form environment options context)
      (consent-macroexpand form environment options context))))

(defun consent-repl--refresh-macroexpand
    (id expansion)
  "Refresh the macro expansion comparison buffer for session ID."
  (consent-repl--refresh-buffer
   'macroexpand id #'consent-macroexpand-mode
   (lambda ()
     (consent-repl--render-section
      "Original"
      (consent-repl--field-value expansion "original"))
     (consent-repl--render-section
      "Expanded"
      (consent-repl--field-value expansion "expanded"))
     (consent-repl--render-section
      "Steps"
      (consent-repl--field-value expansion "steps"))
     (consent-repl--render-section "Record" expansion))))

;;;###autoload
(defun consent-refresh-session-buffers (&optional id)
  "Refresh native buffers for session ID.
When ID is nil, use `consent-current-session-id'.  Return the status
buffer."
  (let ((session-id (or id consent-current-session-id)))
    (unless session-id
      (signal 'consent-session-error
              (list "no current Consent Scheme session")))
    (consent-repl--update-mode-line session-id)
    (let ((status (consent-repl--refresh-status session-id)))
      (consent-repl--refresh-transcript session-id)
      (consent-repl--refresh-events session-id)
      (consent-repl--refresh-audit session-id)
      (consent-repl--refresh-approvals session-id)
      status)))

(defun consent-repl--ensure-session (scope id)
  "Return a durable session id for SCOPE and ID, creating it when needed."
  (let* ((normalized-scope (consent-session--scope scope))
         (session-id
          (cond
           (id id)
           ((eq normalized-scope 'project)
            (consent-repl--project-session-id))
           ((eq normalized-scope 'named)
            consent-repl-default-named-session-id)
           (t
            (consent-session--generated-id normalized-scope)))))
    (unless (consent-session-ref session-id)
      (consent-session-create!
       normalized-scope
       (append
        (list :id session-id)
        (when (eq normalized-scope 'project)
          (list :project-root (consent-repl--project-root))))))
    session-id))

;;;###autoload
(defun consent-start-repl (&optional scope id)
  "Start or switch to a native Consent Scheme REPL session.
SCOPE defaults to `project'.  ID defaults to the project session id for project
sessions and `consent-repl-default-named-session-id' for named sessions.
Return the conversation/status buffer."
  (interactive
   (list
    (intern
     (completing-read "Consent Scheme session scope: "
                      '("project" "named")
                      nil t nil nil "project"))
    nil))
  (let ((session-id (consent-repl--ensure-session
                     (or scope 'project)
                     id)))
    (setq consent-current-session-id session-id)
    (let ((buffer (consent-refresh-session-buffers session-id)))
      (when (called-interactively-p 'interactive)
        (pop-to-buffer buffer))
      buffer)))

;;;###autoload
(defun consent-switch-session (id)
  "Switch native REPL buffers to session ID and return its status buffer."
  (interactive (list (consent-repl--read-session-id
                      "Switch to Consent Scheme session: ")))
  (setq consent-current-session-id id)
  (let ((buffer (consent-refresh-session-buffers id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-inspect-session (&optional id)
  "Open the conversation/status buffer for session ID."
  (interactive (list (consent-repl--read-session-id
                      "Inspect Consent Scheme session: ")))
  (let ((buffer (consent-refresh-session-buffers
                 (or id consent-current-session-id))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-stop-session (&optional id)
  "Retire session ID and refresh native buffers."
  (interactive (list (consent-repl--read-session-id
                      "Stop Consent Scheme session: ")))
  (let* ((session-id (or id consent-current-session-id))
         (datum (consent-session-retire! session-id)))
    (consent-refresh-session-buffers session-id)
    datum))

;;;###autoload
(defun consent-repl-eval-source (source &optional id options)
  "Evaluate SOURCE in session ID and refresh native buffers.
When ID is nil, use the current native session, creating the project session if
needed.  OPTIONS are passed to `consent-session-eval-source'."
  (interactive "sConsent Scheme source: ")
  (unless (or id consent-current-session-id)
    (consent-start-repl 'project))
  (let ((session-id (or id consent-current-session-id)))
    (condition-case condition
        (let ((value (consent-session-eval-source
                      session-id source options)))
          (consent-refresh-session-buffers session-id)
          (when (called-interactively-p 'interactive)
            (pop-to-buffer
             (get-buffer (consent-repl--buffer-name 'repl session-id))))
          value)
      (error
       (consent-refresh-session-buffers session-id)
       (signal (car condition) (cdr condition))))))

;;;###autoload
(defun consent-repl-eval (&optional source)
  "Read and evaluate Consent Scheme SOURCE in the current native REPL."
  (interactive)
  (let ((input
         (or source
             (if (use-region-p)
                 (buffer-substring-no-properties
                  (region-beginning)
                  (region-end))
               (read-string "Consent Scheme source: ")))))
    (consent-repl-eval-source input)))

;;;###autoload
(defun consent-repl-macroexpand-source
    (source &optional id options one-step)
  "Open a macro expansion comparison for SOURCE in session ID.
When ONE-STEP is non-nil, show only the first expansion step.  OPTIONS are
passed to the macro expansion introspection primitive."
  (interactive
   (list
    (if (use-region-p)
        (buffer-substring-no-properties
         (region-beginning)
         (region-end))
      (read-string "Consent Scheme macro form: "))
    nil nil current-prefix-arg))
  (unless (or id consent-current-session-id)
    (consent-start-repl 'project))
  (let* ((session-id (or id consent-current-session-id))
         (expansion
          (consent-repl--macroexpand-datum
           source session-id options one-step))
         (buffer
          (consent-repl--refresh-macroexpand session-id expansion)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun consent-repl--open-buffer (kind id)
  "Open native buffer KIND for session ID."
  (let ((buffer (consent-refresh-session-buffers
                 (or id consent-current-session-id))))
    (pcase kind
      ('status buffer)
      (_
       (get-buffer
        (consent-repl--buffer-name
         kind
         (or id consent-current-session-id)))))))

;;;###autoload
(defun consent-open-status (&optional id)
  "Open the Consent Scheme conversation/status buffer for session ID."
  (interactive)
  (let ((buffer (consent-repl--open-buffer 'status id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-open-repl (&optional id)
  "Open the Consent Scheme REPL transcript buffer for session ID."
  (interactive)
  (let ((buffer (consent-repl--open-buffer 'repl id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-open-events (&optional id)
  "Open the Consent Scheme event timeline buffer for session ID."
  (interactive)
  (let ((buffer (consent-repl--open-buffer 'events id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-open-audit (&optional id)
  "Open the Consent Scheme audit buffer for session ID."
  (interactive)
  (let ((buffer (consent-repl--open-buffer 'audit id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun consent-open-approvals (&optional id)
  "Open the Consent Scheme approvals buffer for session ID."
  (interactive)
  (let ((buffer (consent-repl--open-buffer 'approvals id)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(transient-define-prefix consent-dispatch ()
  "Consent Scheme native session commands."
  [["Session"
    ("s" "start/switch project" consent-start-repl)
    ("i" "inspect session" consent-inspect-session)
    ("x" "stop session" consent-stop-session)]
   ["Buffers"
    ("a" "status" consent-open-status)
    ("r" "repl transcript" consent-open-repl)
    ("e" "events" consent-open-events)
    ("u" "audit" consent-open-audit)
    ("p" "approvals" consent-open-approvals)]
   ["Evaluation"
    ("RET" "eval source" consent-repl-eval)
    ("m" "macroexpand" consent-repl-macroexpand-source)]])

;; Per the Emacs key-binding conventions, `C-c LETTER' keys are reserved
;; for users, so this package binds no global dispatch key.  Users opt in
;; with, for example: (keymap-global-set "C-c d" #'consent-dispatch)

(provide 'consent-repl)

;;; consent-repl.el ends here
