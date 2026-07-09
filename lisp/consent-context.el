;;; consent-context.el --- Current request and focus context  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent context)' library exposes the current request, editor focus,
;; region, buffer, project, and conversation summary as Scheme-readable datums.
;; Live host objects stay behind opaque handles and read-only observation policy.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-capability)
(require 'consent-policy)
(require 'consent-redaction)
(require 'consent-runtime)

(defvar-local consent-context-local-only-reason nil
  "Non-nil reason marking the current buffer as local-only context.")

(defun consent-context--symbol (name)
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

(defun consent-context--field (name value)
  "Return a Scheme-readable context field named NAME with VALUE."
  (list (consent-context--symbol name) value))

(defun consent-context--integer (value)
  "Return VALUE as an exact integer datum."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent-context--boolean (value)
  "Return VALUE as an Consent Scheme boolean."
  (if value consent-true consent-false))

(defun consent-context--maybe-string (value)
  "Return VALUE as a copied string, or #f when VALUE is nil."
  (if value (substring-no-properties value) consent-false))

(defun consent-context--id-value (value)
  "Return VALUE normalized for a public id field."
  (cond
   ((or (consent-symbol-p value) (not value))
    value)
   ((symbolp value)
    (consent-context--symbol value))
   ((stringp value)
    (consent-context--symbol value))
   (t value)))

(defun consent-context--record-named-p (datum name)
  "Return non-nil when DATUM is a context record named NAME."
  (and (consp datum)
       (consent-symbol-p (car datum))
       (equal (consent-symbol-name (car datum)) name)))

(defun consent-context--request-context (context)
  "Return request context for CONTEXT, or #f when absent."
  (let ((request (consent--eval-context-request context))
        (request-id (consent--eval-context-request-id context))
        (session-id (consent--eval-context-session-id context)))
    (cond
     ((consent-context--record-named-p request "request-context")
      request)
     ((or request request-id)
      (append
       (list (consent-context--symbol "request-context"))
       (when request-id
         (list (consent-context--field
                "request-id"
                (consent-context--id-value request-id))))
       (when session-id
         (list (consent-context--field
                "session-id"
                (consent-context--id-value session-id))))
       (when request
         (list (consent-context--field "request" request)))))
     (t consent-false))))

(defun consent-context-current-request (&optional context)
  "Return the current request context datum, or #f when absent."
  (consent-context--request-context context))

(defun consent-context--conversation-summary (context)
  "Return conversation summary context for CONTEXT, or #f when absent."
  (let ((summary (consent--eval-context-conversation-summary context))
        (session-id (consent--eval-context-session-id context)))
    (cond
     ((consent-context--record-named-p summary "conversation-summary")
      summary)
     (summary
      (append
       (list (consent-context--symbol "conversation-summary"))
       (when session-id
         (list (consent-context--field
                "session-id"
                (consent-context--id-value session-id))))
       (list (consent-context--field "summary" summary))))
     (t consent-false))))

(defun consent-context-current-conversation-summary (&optional context)
  "Return the current conversation summary datum, or #f when absent."
  (consent-context--conversation-summary context))

(defun consent-context--authorize-read (operation context fields)
  "Authorize read-only OPERATION in CONTEXT with FIELDS."
  (consent-policy-authorize
   'emacs-read-only operation fields context 'capability-call))

(defun consent-context--buffer-local-only-reason (buffer)
  "Return local-only reason for BUFFER, or nil."
  (with-current-buffer buffer
    (or consent-context-local-only-reason
        (and (string-prefix-p " " (buffer-name buffer))
             "private buffer"))))

(defun consent-context--line-text ()
  "Return the current line text without text properties."
  (buffer-substring-no-properties
   (line-beginning-position)
   (line-end-position)))

(defun consent-context--buffer-context-record (buffer)
  "Return a Scheme-readable buffer context record for BUFFER."
  (with-current-buffer buffer
    (let* ((handle (consent--buffer-handle buffer))
           (file buffer-file-name)
           (local-only-reason
            (consent-context--buffer-local-only-reason buffer)))
      (append
       (list
        (consent-context--symbol "buffer-context")
        (consent-context--field "buffer" handle)
        (consent-context--field "name" (buffer-name buffer))
        (consent-context--field
         "file"
         (consent-context--maybe-string
          (and file (expand-file-name file))))
        (consent-context--field
         "major-mode"
         (consent-context--symbol major-mode))
        (consent-context--field
         "point" (consent-context--integer (point)))
        (consent-context--field
         "line" (consent-context--integer (line-number-at-pos (point) t)))
        (consent-context--field
         "column" (consent-context--integer (1+ (current-column))))
        (consent-context--field "line-text"
                                     (consent-context--line-text))
        (consent-context--field
         "region-active" (consent-context--boolean (use-region-p)))
        (consent-context--field
         "local-only" (consent-context--boolean local-only-reason)))
       (when local-only-reason
         (list (consent-context--field
                "local-only-reason" local-only-reason)))))))

(defun consent-context-current-buffer-context (&optional context)
  "Return the current buffer context datum, or #f when absent."
  (or (and context (consent--eval-context-buffer-context context))
      (progn
        (consent-context--authorize-read
         "current-buffer-context"
         context
         `((buffer . ,(buffer-name (current-buffer)))))
        (consent-context--buffer-context-record (current-buffer)))))

(defun consent-context--region-context-record (buffer start end)
  "Return a Scheme-readable region context record for BUFFER START END."
  (with-current-buffer buffer
    (let* ((handle (consent--buffer-handle buffer))
           (file buffer-file-name)
           (local-only-reason
            (consent-context--buffer-local-only-reason buffer)))
      (append
       (list
        (consent-context--symbol "region-context")
        (consent-context--field "buffer" handle)
        (consent-context--field "name" (buffer-name buffer))
        (consent-context--field
         "file"
         (consent-context--maybe-string
          (and file (expand-file-name file))))
        (consent-context--field
         "range"
         (list
          (consent-context--field
           "start" (consent-context--integer start))
          (consent-context--field
           "end" (consent-context--integer end))))
        (consent-context--field
         "lines"
         (list
          (consent-context--field
           "start" (consent-context--integer
                    (line-number-at-pos start t)))
          (consent-context--field
           "end" (consent-context--integer
                  (line-number-at-pos end t)))))
        (consent-context--field
         "text" (buffer-substring-no-properties start end))
        (consent-context--field
         "local-only" (consent-context--boolean local-only-reason)))
       (when local-only-reason
         (list (consent-context--field
                "local-only-reason" local-only-reason)))))))

(defun consent-context-current-region-context (&optional context)
  "Return active region context datum, or #f when no region is active."
  (or (and context (consent--eval-context-region-context context))
      (if (use-region-p)
          (progn
            (consent-context--authorize-read
             "current-region-context"
             context
             `((buffer . ,(buffer-name (current-buffer)))
               (region . (,(region-beginning) ,(region-end)))))
            (consent-context--region-context-record
             (current-buffer)
             (region-beginning)
             (region-end)))
        consent-false)))

(defun consent-context--project-context-record (project)
  "Return a Scheme-readable project context record for PROJECT."
  (let* ((root (file-name-as-directory
                (expand-file-name (project-root project))))
         (handle (consent--project-handle project)))
    (list
     (consent-context--symbol "project-context")
     (consent-context--field "project" handle)
     (consent-context--field "root" root)
     (consent-context--field
      "name"
      (file-name-nondirectory (directory-file-name root))))))

(defun consent-context-current-project-context (&optional context)
  "Return current project context datum, or #f when absent."
  (or (and context (consent--eval-context-project-context context))
      (progn
        (consent-context--authorize-read
         "current-project-context" context nil)
        (if-let ((project (project-current nil)))
            (consent-context--project-context-record project)
          consent-false))))

(defun consent-context--context-records (context)
  "Return available context records for CONTEXT."
  (seq-remove
   (lambda (record) (eq record consent-false))
   (list
    (consent-context-current-request context)
    (consent-context-current-region-context context)
    (consent-context-current-buffer-context context)
    (consent-context-current-project-context context)
    (consent-context-current-conversation-summary context))))

(defun consent-context-current-focus (&optional context)
  "Return current focus context datum, or #f when no context is available."
  (or (and context (consent--eval-context-focus context))
      (let ((records (consent-context--context-records context)))
        (if records
            (cons (consent-context--symbol "focus-context") records)
          consent-false))))

(defun consent-context--query-name (query)
  "Return QUERY as a context selection name."
  (cond
   ((consent-symbol-p query)
    (consent-symbol-name query))
   ((symbolp query)
    (symbol-name query))
   ((stringp query)
    query)
   (t nil)))

(defun consent-context--select-one (name context)
  "Return context record selected by NAME from CONTEXT."
  (pcase name
    ((or "all" "context")
     (cons (consent-context--symbol "context")
           (consent-context--context-records context)))
    ("request" (consent-context-current-request context))
    ("focus" (consent-context-current-focus context))
    ("region" (consent-context-current-region-context context))
    ("buffer" (consent-context-current-buffer-context context))
    ("project" (consent-context-current-project-context context))
    ((or "conversation" "conversation-summary")
     (consent-context-current-conversation-summary context))
    (_ consent-false)))

(defun consent-context--select (query context)
  "Return context selected by QUERY from CONTEXT."
  (let ((name (consent-context--query-name query)))
    (cond
     (name (consent-context--select-one name context))
     ((consp query)
      (cons
       (consent-context--symbol "context")
       (seq-remove
        (lambda (record) (eq record consent-false))
        (mapcar
         (lambda (item)
           (consent-context--select-one
            (or (consent-context--query-name item) "")
            context))
         (consent--proper-list-elements query "context-yield query")))))
     (t consent-false))))

(defun consent-context-yield (query context)
  "Yield context matching QUERY through CONTEXT and return the yielded datum."
  (let ((record (consent-context--select query context)))
    (unless (eq record consent-false)
      (let ((redacted (consent-redact record 'agent-context)))
        (consent--record-event!
         context
         (list (consent-context--symbol "yield") redacted))
        (consent-audit-record
         'context-event
         `((category . agent-context)
           (operation . "context-yield")
           (query . ,query)
           (record . ,redacted)
           (decision . recorded)))))
    record))

(defun consent-context--primitive-current-request (_arguments context)
  "Primitive current-request."
  (consent-context-current-request context))

(defun consent-context--primitive-current-focus (_arguments context)
  "Primitive current-focus."
  (consent-context-current-focus context))

(defun consent-context--primitive-current-region-context
    (_arguments context)
  "Primitive current-region-context."
  (consent-context-current-region-context context))

(defun consent-context--primitive-current-buffer-context
    (_arguments context)
  "Primitive current-buffer-context."
  (consent-context-current-buffer-context context))

(defun consent-context--primitive-current-project-context
    (_arguments context)
  "Primitive current-project-context."
  (consent-context-current-project-context context))

(defun consent-context--primitive-current-conversation-summary
    (_arguments context)
  "Primitive current-conversation-summary."
  (consent-context-current-conversation-summary context))

(defun consent-context--primitive-context-yield (arguments context)
  "Primitive context-yield over ARGUMENTS."
  (consent-context-yield (car arguments) context))

(defconst consent-context--primitive-implementation-table
  `((primitive-current-request
     . ,#'consent-context--primitive-current-request)
    (primitive-current-focus . ,#'consent-context--primitive-current-focus)
    (primitive-current-region-context
     . ,#'consent-context--primitive-current-region-context)
    (primitive-current-buffer-context
     . ,#'consent-context--primitive-current-buffer-context)
    (primitive-current-project-context
     . ,#'consent-context--primitive-current-project-context)
    (primitive-current-conversation-summary
     . ,#'consent-context--primitive-current-conversation-summary)
    (primitive-context-yield . ,#'consent-context--primitive-context-yield))
  "Provider-owned primitive implementations for `(agent context)'.")

;;;###autoload
(defun consent-context-primitive-implementation (primitive)
  "Return `(agent context)' implementation for PRIMITIVE."
  (consent--primitive-implementation-from-table
   primitive
   consent-context--primitive-implementation-table
   "`(agent context)'"))

(provide 'consent-context)

;;; consent-context.el ends here
