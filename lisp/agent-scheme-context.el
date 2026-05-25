;;; agent-scheme-context.el --- Current request and focus context  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent context)' library exposes the current request, editor focus,
;; region, buffer, project, and conversation summary as Scheme-readable datums.
;; Live host objects stay behind opaque handles and read-only observation policy.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-audit)
(require 'agent-scheme-capability)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)
(require 'agent-scheme-runtime)

(defvar-local agent-scheme-context-local-only-reason nil
  "Non-nil reason marking the current buffer as local-only context.")

(defun agent-scheme-context--symbol (name)
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

(defun agent-scheme-context--field (name value)
  "Return a Scheme-readable context field named NAME with VALUE."
  (list (agent-scheme-context--symbol name) value))

(defun agent-scheme-context--integer (value)
  "Return VALUE as an exact integer datum."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme-context--boolean (value)
  "Return VALUE as an Agent Scheme boolean."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme-context--maybe-string (value)
  "Return VALUE as a copied string, or #f when VALUE is nil."
  (if value (substring-no-properties value) agent-scheme-false))

(defun agent-scheme-context--id-value (value)
  "Return VALUE normalized for a public id field."
  (cond
   ((or (agent-scheme-symbol-p value) (not value))
    value)
   ((symbolp value)
    (agent-scheme-context--symbol value))
   ((stringp value)
    (agent-scheme-context--symbol value))
   (t value)))

(defun agent-scheme-context--record-named-p (datum name)
  "Return non-nil when DATUM is a context record named NAME."
  (and (consp datum)
       (agent-scheme-symbol-p (car datum))
       (equal (agent-scheme-symbol-name (car datum)) name)))

(defun agent-scheme-context--request-context (context)
  "Return request context for CONTEXT, or #f when absent."
  (let ((request (agent-scheme--eval-context-request context))
        (request-id (agent-scheme--eval-context-request-id context))
        (session-id (agent-scheme--eval-context-session-id context)))
    (cond
     ((agent-scheme-context--record-named-p request "request-context")
      request)
     ((or request request-id)
      (append
       (list (agent-scheme-context--symbol "request-context"))
       (when request-id
         (list (agent-scheme-context--field
                "request-id"
                (agent-scheme-context--id-value request-id))))
       (when session-id
         (list (agent-scheme-context--field
                "session-id"
                (agent-scheme-context--id-value session-id))))
       (when request
         (list (agent-scheme-context--field "request" request)))))
     (t agent-scheme-false))))

(defun agent-scheme-context-current-request (&optional context)
  "Return the current request context datum, or #f when absent."
  (agent-scheme-context--request-context context))

(defun agent-scheme-context--conversation-summary (context)
  "Return conversation summary context for CONTEXT, or #f when absent."
  (let ((summary (agent-scheme--eval-context-conversation-summary context))
        (session-id (agent-scheme--eval-context-session-id context)))
    (cond
     ((agent-scheme-context--record-named-p summary "conversation-summary")
      summary)
     (summary
      (append
       (list (agent-scheme-context--symbol "conversation-summary"))
       (when session-id
         (list (agent-scheme-context--field
                "session-id"
                (agent-scheme-context--id-value session-id))))
       (list (agent-scheme-context--field "summary" summary))))
     (t agent-scheme-false))))

(defun agent-scheme-context-current-conversation-summary (&optional context)
  "Return the current conversation summary datum, or #f when absent."
  (agent-scheme-context--conversation-summary context))

(defun agent-scheme-context--authorize-read (operation context fields)
  "Authorize read-only OPERATION in CONTEXT with FIELDS."
  (agent-scheme-policy-authorize
   'emacs-read-only operation fields context 'capability-call))

(defun agent-scheme-context--buffer-local-only-reason (buffer)
  "Return local-only reason for BUFFER, or nil."
  (with-current-buffer buffer
    (or agent-scheme-context-local-only-reason
        (and (string-prefix-p " " (buffer-name buffer))
             "private buffer"))))

(defun agent-scheme-context--line-text ()
  "Return the current line text without text properties."
  (buffer-substring-no-properties
   (line-beginning-position)
   (line-end-position)))

(defun agent-scheme-context--buffer-context-record (buffer)
  "Return a Scheme-readable buffer context record for BUFFER."
  (with-current-buffer buffer
    (let* ((handle (agent-scheme--buffer-handle buffer))
           (file buffer-file-name)
           (local-only-reason
            (agent-scheme-context--buffer-local-only-reason buffer)))
      (append
       (list
        (agent-scheme-context--symbol "buffer-context")
        (agent-scheme-context--field "buffer" handle)
        (agent-scheme-context--field "name" (buffer-name buffer))
        (agent-scheme-context--field
         "file"
         (agent-scheme-context--maybe-string
          (and file (expand-file-name file))))
        (agent-scheme-context--field
         "major-mode"
         (agent-scheme-context--symbol major-mode))
        (agent-scheme-context--field
         "point" (agent-scheme-context--integer (point)))
        (agent-scheme-context--field
         "line" (agent-scheme-context--integer (line-number-at-pos (point) t)))
        (agent-scheme-context--field
         "column" (agent-scheme-context--integer (1+ (current-column))))
        (agent-scheme-context--field "line-text"
                                     (agent-scheme-context--line-text))
        (agent-scheme-context--field
         "region-active" (agent-scheme-context--boolean (use-region-p)))
        (agent-scheme-context--field
         "local-only" (agent-scheme-context--boolean local-only-reason)))
       (when local-only-reason
         (list (agent-scheme-context--field
                "local-only-reason" local-only-reason)))))))

(defun agent-scheme-context-current-buffer-context (&optional context)
  "Return the current buffer context datum, or #f when absent."
  (or (and context (agent-scheme--eval-context-buffer-context context))
      (progn
        (agent-scheme-context--authorize-read
         "current-buffer-context"
         context
         `((buffer . ,(buffer-name (current-buffer)))))
        (agent-scheme-context--buffer-context-record (current-buffer)))))

(defun agent-scheme-context--region-context-record (buffer start end)
  "Return a Scheme-readable region context record for BUFFER START END."
  (with-current-buffer buffer
    (let* ((handle (agent-scheme--buffer-handle buffer))
           (file buffer-file-name)
           (local-only-reason
            (agent-scheme-context--buffer-local-only-reason buffer)))
      (append
       (list
        (agent-scheme-context--symbol "region-context")
        (agent-scheme-context--field "buffer" handle)
        (agent-scheme-context--field "name" (buffer-name buffer))
        (agent-scheme-context--field
         "file"
         (agent-scheme-context--maybe-string
          (and file (expand-file-name file))))
        (agent-scheme-context--field
         "range"
         (list
          (agent-scheme-context--field
           "start" (agent-scheme-context--integer start))
          (agent-scheme-context--field
           "end" (agent-scheme-context--integer end))))
        (agent-scheme-context--field
         "lines"
         (list
          (agent-scheme-context--field
           "start" (agent-scheme-context--integer
                    (line-number-at-pos start t)))
          (agent-scheme-context--field
           "end" (agent-scheme-context--integer
                  (line-number-at-pos end t)))))
        (agent-scheme-context--field
         "text" (buffer-substring-no-properties start end))
        (agent-scheme-context--field
         "local-only" (agent-scheme-context--boolean local-only-reason)))
       (when local-only-reason
         (list (agent-scheme-context--field
                "local-only-reason" local-only-reason)))))))

(defun agent-scheme-context-current-region-context (&optional context)
  "Return active region context datum, or #f when no region is active."
  (or (and context (agent-scheme--eval-context-region-context context))
      (if (use-region-p)
          (progn
            (agent-scheme-context--authorize-read
             "current-region-context"
             context
             `((buffer . ,(buffer-name (current-buffer)))
               (region . (,(region-beginning) ,(region-end)))))
            (agent-scheme-context--region-context-record
             (current-buffer)
             (region-beginning)
             (region-end)))
        agent-scheme-false)))

(defun agent-scheme-context--project-context-record (project)
  "Return a Scheme-readable project context record for PROJECT."
  (let* ((root (file-name-as-directory
                (expand-file-name (project-root project))))
         (handle (agent-scheme--project-handle project)))
    (list
     (agent-scheme-context--symbol "project-context")
     (agent-scheme-context--field "project" handle)
     (agent-scheme-context--field "root" root)
     (agent-scheme-context--field
      "name"
      (file-name-nondirectory (directory-file-name root))))))

(defun agent-scheme-context-current-project-context (&optional context)
  "Return current project context datum, or #f when absent."
  (or (and context (agent-scheme--eval-context-project-context context))
      (progn
        (agent-scheme-context--authorize-read
         "current-project-context" context nil)
        (if-let ((project (project-current nil)))
            (agent-scheme-context--project-context-record project)
          agent-scheme-false))))

(defun agent-scheme-context--context-records (context)
  "Return available context records for CONTEXT."
  (seq-remove
   (lambda (record) (eq record agent-scheme-false))
   (list
    (agent-scheme-context-current-request context)
    (agent-scheme-context-current-region-context context)
    (agent-scheme-context-current-buffer-context context)
    (agent-scheme-context-current-project-context context)
    (agent-scheme-context-current-conversation-summary context))))

(defun agent-scheme-context-current-focus (&optional context)
  "Return current focus context datum, or #f when no context is available."
  (or (and context (agent-scheme--eval-context-focus context))
      (let ((records (agent-scheme-context--context-records context)))
        (if records
            (cons (agent-scheme-context--symbol "focus-context") records)
          agent-scheme-false))))

(defun agent-scheme-context--query-name (query)
  "Return QUERY as a context selection name."
  (cond
   ((agent-scheme-symbol-p query)
    (agent-scheme-symbol-name query))
   ((symbolp query)
    (symbol-name query))
   ((stringp query)
    query)
   (t nil)))

(defun agent-scheme-context--select-one (name context)
  "Return context record selected by NAME from CONTEXT."
  (pcase name
    ((or "all" "context")
     (cons (agent-scheme-context--symbol "context")
           (agent-scheme-context--context-records context)))
    ("request" (agent-scheme-context-current-request context))
    ("focus" (agent-scheme-context-current-focus context))
    ("region" (agent-scheme-context-current-region-context context))
    ("buffer" (agent-scheme-context-current-buffer-context context))
    ("project" (agent-scheme-context-current-project-context context))
    ((or "conversation" "conversation-summary")
     (agent-scheme-context-current-conversation-summary context))
    (_ agent-scheme-false)))

(defun agent-scheme-context--select (query context)
  "Return context selected by QUERY from CONTEXT."
  (let ((name (agent-scheme-context--query-name query)))
    (cond
     (name (agent-scheme-context--select-one name context))
     ((consp query)
      (cons
       (agent-scheme-context--symbol "context")
       (seq-remove
        (lambda (record) (eq record agent-scheme-false))
        (mapcar
         (lambda (item)
           (agent-scheme-context--select-one
            (or (agent-scheme-context--query-name item) "")
            context))
         (agent-scheme--proper-list-elements query "context-yield query")))))
     (t agent-scheme-false))))

(defun agent-scheme-context-yield (query context)
  "Yield context matching QUERY through CONTEXT and return the yielded datum."
  (let ((record (agent-scheme-context--select query context)))
    (unless (eq record agent-scheme-false)
      (let ((redacted (agent-scheme-redact record 'agent-context)))
        (agent-scheme--record-event!
         context
         (list (agent-scheme-context--symbol "yield") redacted))
        (agent-scheme-audit-record
         'agent-event
         `((category . agent-context)
           (operation . "context-yield")
           (query . ,query)
           (record . ,redacted)
           (decision . recorded)))))
    record))

(defun agent-scheme-context--primitive-current-request (_arguments context)
  "Primitive current-request."
  (agent-scheme-context-current-request context))

(defun agent-scheme-context--primitive-current-focus (_arguments context)
  "Primitive current-focus."
  (agent-scheme-context-current-focus context))

(defun agent-scheme-context--primitive-current-region-context
    (_arguments context)
  "Primitive current-region-context."
  (agent-scheme-context-current-region-context context))

(defun agent-scheme-context--primitive-current-buffer-context
    (_arguments context)
  "Primitive current-buffer-context."
  (agent-scheme-context-current-buffer-context context))

(defun agent-scheme-context--primitive-current-project-context
    (_arguments context)
  "Primitive current-project-context."
  (agent-scheme-context-current-project-context context))

(defun agent-scheme-context--primitive-current-conversation-summary
    (_arguments context)
  "Primitive current-conversation-summary."
  (agent-scheme-context-current-conversation-summary context))

(defun agent-scheme-context--primitive-context-yield (arguments context)
  "Primitive context-yield over ARGUMENTS."
  (agent-scheme-context-yield (car arguments) context))

;;;###autoload
(defun agent-scheme-context-primitive-specs ()
  "Return primitive specs for the `(agent context)' library."
  `(("current-request" ,#'agent-scheme-context--primitive-current-request 0 0)
    ("current-focus" ,#'agent-scheme-context--primitive-current-focus 0 0)
    ("current-region-context" ,#'agent-scheme-context--primitive-current-region-context 0 0)
    ("current-buffer-context" ,#'agent-scheme-context--primitive-current-buffer-context 0 0)
    ("current-project-context" ,#'agent-scheme-context--primitive-current-project-context 0 0)
    ("current-conversation-summary" ,#'agent-scheme-context--primitive-current-conversation-summary 0 0)
    ("context-yield" ,#'agent-scheme-context--primitive-context-yield 1 1)))

(provide 'agent-scheme-context)

;;; agent-scheme-context.el ends here
