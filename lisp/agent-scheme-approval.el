;;; agent-scheme-approval.el --- Programmable approval requests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent approval)' library stores approval requests as Scheme-readable
;; datums.  Host-side UX and indexes are views over these records; Scheme code
;; can create requests and observe decisions but cannot approve restricted
;; effects unless policy explicitly grants host-side automation.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-audit)
(require 'agent-scheme-runtime)

(declare-function agent-scheme-policy-authorize "agent-scheme-policy")

(define-error 'agent-scheme-approval-error
  "Agent Scheme approval error"
  'agent-scheme-eval-error)

(defgroup agent-scheme-approval nil
  "Programmable approval requests for Agent Scheme."
  :group 'agent-scheme)

(defconst agent-scheme-approval-statuses
  '(pending approved denied canceled)
  "Recognized approval request statuses.")

(defvar agent-scheme--approval-records nil
  "Approval request records in creation order.")

(defvar agent-scheme--approval-next-id 0
  "Next approval request numeric suffix.")

(defvar agent-scheme--approval-current-session nil
  "Dynamically bound session id for approval requests made in a session.")

(defun agent-scheme-approval--symbol (name)
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

(defun agent-scheme-approval--field (name value)
  "Return a Scheme-readable approval field named NAME with VALUE."
  (list (agent-scheme-approval--symbol name) value))

(defun agent-scheme-approval--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (agent-scheme-symbol-p (car field))
       (equal (agent-scheme-symbol-name (car field)) name)))

(defun agent-scheme-approval--record-field (record name)
  "Return field NAME from approval RECORD, or nil."
  (cadr
   (seq-find
    (lambda (field)
      (agent-scheme-approval--field-named-p field name))
    (cdr-safe record))))

(defun agent-scheme-approval--id-name (id)
  "Return ID as a stable string name."
  (cond
   ((agent-scheme-symbol-p id)
    (agent-scheme-symbol-name id))
   ((symbolp id)
    (symbol-name id))
   ((stringp id)
    id)
   (t
    (signal 'agent-scheme-approval-error
            (list "approval id must be a symbol or string")))))

(defun agent-scheme-approval--generated-id ()
  "Return a fresh approval id symbol."
  (agent-scheme-approval--symbol
   (format "a-%d" (cl-incf agent-scheme--approval-next-id))))

(defun agent-scheme-approval--status (status)
  "Return normalized STATUS or signal an approval error."
  (let ((normalized
         (cond
          ((agent-scheme-symbol-p status)
           (intern (agent-scheme-symbol-name status)))
          ((symbolp status)
           status)
          ((stringp status)
           (intern status))
          (t nil))))
    (unless (memq normalized agent-scheme-approval-statuses)
      (signal 'agent-scheme-approval-error
              (list (format "unknown approval status: %S" status))))
    normalized))

(defun agent-scheme-approval--request-fields (datum)
  "Return approval request fields from DATUM."
  (if (and (consp datum)
           (agent-scheme-symbol-p (car datum))
           (equal (agent-scheme-symbol-name (car datum)) "approval-request"))
      (cdr datum)
    nil))

(defun agent-scheme-approval--payload-field (datum name)
  "Return field NAME from approval request DATUM, or nil."
  (cadr
   (seq-find
    (lambda (field)
      (agent-scheme-approval--field-named-p field name))
    (agent-scheme-approval--request-fields datum))))

(defun agent-scheme-approval--session-field ()
  "Return the current session field, or nil outside session evaluation."
  (when agent-scheme--approval-current-session
    (agent-scheme-approval--field
     "session"
     (agent-scheme-approval--symbol agent-scheme--approval-current-session))))

(defun agent-scheme-approval--make-record (datum &optional id status)
  "Return normalized approval request record for DATUM."
  (let ((request-id (or id (agent-scheme-approval--generated-id)))
        (request-status (or status 'pending)))
    (append
     (list
      (agent-scheme-approval--symbol "approval-request")
      (agent-scheme-approval--field "id" request-id)
      (agent-scheme-approval--field
       "policy"
       (or (agent-scheme-approval--payload-field datum "policy")
           (agent-scheme-approval--symbol "manual")))
      (agent-scheme-approval--field
       "effect"
       (or (agent-scheme-approval--payload-field datum "effect")
           datum)))
     (when-let ((operation
                 (agent-scheme-approval--payload-field datum "operation")))
       (list (agent-scheme-approval--field "operation" operation)))
     (when-let ((reason
                 (agent-scheme-approval--payload-field datum "reason")))
       (list (agent-scheme-approval--field "reason" reason)))
     (list
      (agent-scheme-approval--field
       "status"
       (agent-scheme-approval--symbol request-status)))
     (when-let ((session (or (cadr (agent-scheme-approval--session-field))
                             (agent-scheme-approval--payload-field
                              datum "session"))))
       (list
        (agent-scheme-approval--field
         "session"
         (agent-scheme-approval--symbol session)))))))

(defun agent-scheme-approval--record-id-name (record)
  "Return RECORD id as a string."
  (agent-scheme-approval--id-name
   (agent-scheme-approval--record-field record "id")))

(defun agent-scheme-approval--same-id-p (record id)
  "Return non-nil when RECORD has ID."
  (equal (agent-scheme-approval--record-id-name record)
         (agent-scheme-approval--id-name id)))

(defun agent-scheme-approval--record-in-current-session-p (record)
  "Return non-nil when RECORD belongs to the current Scheme session."
  (let ((record-session (agent-scheme-approval--record-field record "session")))
    (if agent-scheme--approval-current-session
        (equal record-session
               (agent-scheme-approval--symbol
                agent-scheme--approval-current-session))
      (not record-session))))

(defun agent-scheme-approval--primitive-record (id operation)
  "Return approval ID record for primitive OPERATION, enforcing ownership."
  (let ((record (or (agent-scheme-approval-ref id)
                    (signal 'agent-scheme-approval-error
                            (list (format "unknown approval id: %s"
                                          (agent-scheme-approval--id-name
                                           id)))))))
    (unless (agent-scheme-approval--record-in-current-session-p record)
      (signal 'agent-scheme-approval-error
              (list (format "%s cannot access approval outside current session"
                            operation))))
    record))

(defun agent-scheme-approval--replace-field (record name value)
  "Return RECORD with field NAME replaced by VALUE."
  (let ((seen nil)
        (name-symbol (agent-scheme-approval--symbol name)))
    (append
     (list (car record))
     (mapcar
      (lambda (field)
        (if (agent-scheme-approval--field-named-p field name)
            (progn
              (setq seen t)
              (list name-symbol value))
          field))
      (cdr record))
     (unless seen
       (list (list name-symbol value))))))

(defun agent-scheme-approval--set-record! (record)
  "Store RECORD, replacing any existing record with the same id."
  (setq agent-scheme--approval-records
        (append
         (seq-remove
          (lambda (candidate)
            (agent-scheme-approval--same-id-p
             candidate
             (agent-scheme-approval--record-field record "id")))
          agent-scheme--approval-records)
         (list record)))
  record)

(defun agent-scheme-approval--audit-request (record)
  "Audit approval request RECORD."
  (agent-scheme-audit-record
   'approval-request
   `((category . agent-approval)
     (operation . ,(or (agent-scheme-approval--record-field
                        record "operation")
                       "approval-request!"))
     (id . ,(agent-scheme-approval--record-field record "id"))
     (policy . ,(agent-scheme-approval--record-field record "policy"))
     (status . ,(agent-scheme-approval--record-field record "status"))
     (record . ,record)))
  record)

(defun agent-scheme-approval--audit-decision (record decision)
  "Audit approval RECORD resolved with DECISION."
  (agent-scheme-audit-record
   'approval-decision
   `((category . agent-approval)
     (operation . "approval-resolve!")
     (id . ,(agent-scheme-approval--record-field record "id"))
     (decision . ,decision)
     (status . ,(agent-scheme-approval--record-field record "status"))
     (record . ,record)))
  record)

;;;###autoload
(defun agent-scheme-approval-request! (datum)
  "Create an approval request from DATUM and return its id."
  (let ((record (agent-scheme-approval--make-record datum)))
    (agent-scheme-approval--set-record! record)
    (agent-scheme-approval--audit-request record)
    (agent-scheme-approval--record-field record "id")))

;;;###autoload
(defun agent-scheme-approval-request-from-policy!
    (category operation _fields request &optional _context)
  "Create an approval record for a policy CATEGORY request.
OPERATION names the gated operation.  REQUEST is the Scheme-readable policy
request passed to confirmation hooks and stored as the proposed effect."
  (agent-scheme-approval-request!
   (append
    (list
     (agent-scheme-approval--symbol "approval-request")
     (agent-scheme-approval--field
      "policy"
      (agent-scheme-approval--symbol category))
     (agent-scheme-approval--field "operation" operation)
     (agent-scheme-approval--field "effect" request)
     (agent-scheme-approval--field
      "reason"
      (format "%s requires approval" operation))))))

;;;###autoload
(defun agent-scheme-approval-ref (id)
  "Return approval request record ID, or nil when unknown."
  (seq-find
   (lambda (record)
     (agent-scheme-approval--same-id-p record id))
   agent-scheme--approval-records))

;;;###autoload
(defun agent-scheme-approval-status (id)
  "Return approval request ID status, or nil when unknown."
  (when-let ((record (agent-scheme-approval-ref id)))
    (agent-scheme-approval--status
     (agent-scheme-approval--record-field record "status"))))

;;;###autoload
(defun agent-scheme-approval-records (&optional session status)
  "Return approval records, optionally filtered by SESSION and STATUS."
  (let ((session-symbol (and session (agent-scheme-approval--symbol session)))
        (status-symbol (and status
                            (agent-scheme-approval--symbol
                             (agent-scheme-approval--status status)))))
    (seq-filter
     (lambda (record)
       (and
        (or (not session-symbol)
            (equal (agent-scheme-approval--record-field record "session")
                   session-symbol))
        (or (not status-symbol)
            (equal (agent-scheme-approval--record-field record "status")
                   status-symbol))))
     agent-scheme--approval-records)))

;;;###autoload
(defun agent-scheme-approval-pending-records (&optional session)
  "Return pending approval records, optionally filtered by SESSION."
  (agent-scheme-approval-records session 'pending))

;;;###autoload
(defun agent-scheme-approval-resolve! (id decision)
  "Resolve approval request ID with DECISION and return the updated record."
  (let* ((normalized-decision (agent-scheme-approval--status decision))
         (record (or (agent-scheme-approval-ref id)
                     (signal 'agent-scheme-approval-error
                             (list (format "unknown approval id: %s"
                                           (agent-scheme-approval--id-name
                                            id)))))))
    (unless (memq normalized-decision '(approved denied))
      (signal 'agent-scheme-approval-error
              (list "approval decisions must be approved or denied")))
    (let ((updated
           (agent-scheme-approval--replace-field
            record
            "status"
            (agent-scheme-approval--symbol normalized-decision))))
      (agent-scheme-approval--set-record! updated)
      (agent-scheme-approval--audit-decision updated normalized-decision)
      updated)))

;;;###autoload
(defun agent-scheme-approval-cancel! (id)
  "Cancel approval request ID and return the updated record."
  (let ((record (or (agent-scheme-approval-ref id)
                    (signal 'agent-scheme-approval-error
                            (list (format "unknown approval id: %s"
                                          (agent-scheme-approval--id-name
                                           id)))))))
    (unless (eq (agent-scheme-approval--status
                 (agent-scheme-approval--record-field record "status"))
                'pending)
      (signal 'agent-scheme-approval-error
              (list "only pending approvals can be canceled")))
    (let ((updated
           (agent-scheme-approval--replace-field
            record
            "status"
            (agent-scheme-approval--symbol "canceled"))))
      (agent-scheme-approval--set-record! updated)
      (agent-scheme-approval--audit-decision updated 'canceled)
      updated)))

;;;###autoload
(defun agent-scheme-approval-yield-pending (context)
  "Yield pending approval records through CONTEXT and return them."
  (let ((records (agent-scheme-approval-pending-records
                  agent-scheme--approval-current-session)))
    (dolist (record records)
      (agent-scheme--record-event!
       context
       (list (agent-scheme-approval--symbol "yield") record)))
    (agent-scheme-audit-record
     'approval-yield
     `((category . agent-approval)
       (operation . "approval-yield-pending")
       (session . ,(and agent-scheme--approval-current-session
                        (agent-scheme-approval--symbol
                         agent-scheme--approval-current-session)))
       (count . ,(length records))
       (decision . completed)))
    records))

;;;###autoload
(defun agent-scheme-approval-clear! ()
  "Clear in-memory approval request records."
  (setq agent-scheme--approval-records nil)
  (setq agent-scheme--approval-next-id 0)
  agent-scheme-unspecified)

(defun agent-scheme-approval--primitive-request (arguments _context)
  "Primitive approval-request! over ARGUMENTS."
  (agent-scheme-approval-request! (car arguments)))

(defun agent-scheme-approval--primitive-status (arguments _context)
  "Primitive approval-status over ARGUMENTS."
  (let* ((record (agent-scheme-approval-ref (car arguments)))
         (status (and record
                      (agent-scheme-approval--record-in-current-session-p
                       record)
                      (agent-scheme-approval--status
                       (agent-scheme-approval--record-field
                        record "status")))))
    (if status
        (agent-scheme-approval--symbol status)
      agent-scheme-false)))

(defun agent-scheme-approval--primitive-cancel (arguments _context)
  "Primitive approval-cancel! over ARGUMENTS."
  (agent-scheme-approval--primitive-record
   (car arguments)
   "approval-cancel!")
  (agent-scheme-approval-cancel! (car arguments)))

(defun agent-scheme-approval--primitive-yield-pending (_arguments context)
  "Primitive approval-yield-pending over ARGUMENTS."
  (agent-scheme-approval-yield-pending context))

(defun agent-scheme-approval--primitive-resolve (arguments context)
  "Primitive approval-resolve! over ARGUMENTS."
  (agent-scheme-approval--primitive-record
   (car arguments)
   "approval-resolve!")
  (agent-scheme-policy-authorize
   'approval-resolution
   "approval-resolve!"
   `((id . ,(car arguments))
     (decision . ,(cadr arguments)))
   context
   'approval-policy)
  (agent-scheme-approval-resolve! (car arguments) (cadr arguments)))

;;;###autoload
(defun agent-scheme-approval-primitive-specs ()
  "Return primitive specs for the `(agent approval)' library."
  `(("approval-request!" ,#'agent-scheme-approval--primitive-request 1 1)
    ("approval-status" ,#'agent-scheme-approval--primitive-status 1 1)
    ("approval-cancel!" ,#'agent-scheme-approval--primitive-cancel 1 1)
    ("approval-yield-pending"
     ,#'agent-scheme-approval--primitive-yield-pending 0 0)
    ("approval-resolve!" ,#'agent-scheme-approval--primitive-resolve 2 2)))

(provide 'agent-scheme-approval)

;;; agent-scheme-approval.el ends here
