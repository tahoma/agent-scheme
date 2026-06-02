;;; consent-approval.el --- Programmable approval requests  -*- lexical-binding: t; -*-
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
(require 'consent-audit)
(require 'consent-runtime)

(declare-function consent-policy-authorize "consent-policy")

(define-error 'consent-approval-error
  "Consent Scheme approval error"
  'consent-eval-error)

(defgroup consent-approval nil
  "Programmable approval requests for Consent Scheme."
  :group 'consent)

(defconst consent-approval-statuses
  '(pending approved denied canceled)
  "Recognized approval request statuses.")

(defvar consent--approval-records nil
  "Approval request records in creation order.")

(defvar consent--approval-next-id 0
  "Next approval request numeric suffix.")

(defvar consent--approval-current-session nil
  "Dynamically bound session id for approval requests made in a session.")

(defun consent-approval--symbol (name)
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

(defun consent-approval--field (name value)
  "Return a Scheme-readable approval field named NAME with VALUE."
  (list (consent-approval--symbol name) value))

(defun consent-approval--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (consent-symbol-p (car field))
       (equal (consent-symbol-name (car field)) name)))

(defun consent-approval--record-field (record name)
  "Return field NAME from approval RECORD, or nil."
  (cadr
   (seq-find
    (lambda (field)
      (consent-approval--field-named-p field name))
    (cdr-safe record))))

(defun consent-approval--id-name (id)
  "Return ID as a stable string name."
  (cond
   ((consent-symbol-p id)
    (consent-symbol-name id))
   ((symbolp id)
    (symbol-name id))
   ((stringp id)
    id)
   (t
    (signal 'consent-approval-error
            (list "approval id must be a symbol or string")))))

(defun consent-approval--generated-id ()
  "Return a fresh approval id symbol."
  (consent-approval--symbol
   (format "a-%d" (cl-incf consent--approval-next-id))))

(defun consent-approval--status (status)
  "Return normalized STATUS or signal an approval error."
  (let ((normalized
         (cond
          ((consent-symbol-p status)
           (intern (consent-symbol-name status)))
          ((symbolp status)
           status)
          ((stringp status)
           (intern status))
          (t nil))))
    (unless (memq normalized consent-approval-statuses)
      (signal 'consent-approval-error
              (list (format "unknown approval status: %S" status))))
    normalized))

(defun consent-approval--request-fields (datum)
  "Return approval request fields from DATUM."
  (if (and (consp datum)
           (consent-symbol-p (car datum))
           (equal (consent-symbol-name (car datum)) "approval-request"))
      (cdr datum)
    nil))

(defun consent-approval--payload-field (datum name)
  "Return field NAME from approval request DATUM, or nil."
  (cadr
   (seq-find
    (lambda (field)
      (consent-approval--field-named-p field name))
    (consent-approval--request-fields datum))))

(defun consent-approval--session-field ()
  "Return the current session field, or nil outside session evaluation."
  (when consent--approval-current-session
    (consent-approval--field
     "session"
     (consent-approval--symbol consent--approval-current-session))))

(defun consent-approval--make-record (datum &optional id status)
  "Return normalized approval request record for DATUM."
  (let ((request-id (or id (consent-approval--generated-id)))
        (request-status (or status 'pending)))
    (append
     (list
      (consent-approval--symbol "approval-request")
      (consent-approval--field "id" request-id)
      (consent-approval--field
       "policy"
       (or (consent-approval--payload-field datum "policy")
           (consent-approval--symbol "manual")))
      (consent-approval--field
       "effect"
       (or (consent-approval--payload-field datum "effect")
           datum)))
     (when-let ((operation
                 (consent-approval--payload-field datum "operation")))
       (list (consent-approval--field "operation" operation)))
     (when-let ((reason
                 (consent-approval--payload-field datum "reason")))
       (list (consent-approval--field "reason" reason)))
     (list
      (consent-approval--field
       "status"
       (consent-approval--symbol request-status)))
     (when-let ((session (or (cadr (consent-approval--session-field))
                             (consent-approval--payload-field
                              datum "session"))))
       (list
        (consent-approval--field
         "session"
         (consent-approval--symbol session)))))))

(defun consent-approval--record-id-name (record)
  "Return RECORD id as a string."
  (consent-approval--id-name
   (consent-approval--record-field record "id")))

(defun consent-approval--same-id-p (record id)
  "Return non-nil when RECORD has ID."
  (equal (consent-approval--record-id-name record)
         (consent-approval--id-name id)))

(defun consent-approval--record-in-current-session-p (record)
  "Return non-nil when RECORD belongs to the current Scheme session."
  (let ((record-session (consent-approval--record-field record "session")))
    (if consent--approval-current-session
        (equal record-session
               (consent-approval--symbol
                consent--approval-current-session))
      (not record-session))))

(defun consent-approval--primitive-record (id operation)
  "Return approval ID record for primitive OPERATION, enforcing ownership."
  (let ((record (or (consent-approval-ref id)
                    (signal 'consent-approval-error
                            (list (format "unknown approval id: %s"
                                          (consent-approval--id-name
                                           id)))))))
    (unless (consent-approval--record-in-current-session-p record)
      (signal 'consent-approval-error
              (list (format "%s cannot access approval outside current session"
                            operation))))
    record))

(defun consent-approval--replace-field (record name value)
  "Return RECORD with field NAME replaced by VALUE."
  (let ((seen nil)
        (name-symbol (consent-approval--symbol name)))
    (append
     (list (car record))
     (mapcar
      (lambda (field)
        (if (consent-approval--field-named-p field name)
            (progn
              (setq seen t)
              (list name-symbol value))
          field))
      (cdr record))
     (unless seen
       (list (list name-symbol value))))))

(defun consent-approval--set-record! (record)
  "Store RECORD, replacing any existing record with the same id."
  (setq consent--approval-records
        (append
         (seq-remove
          (lambda (candidate)
            (consent-approval--same-id-p
             candidate
             (consent-approval--record-field record "id")))
          consent--approval-records)
         (list record)))
  record)

(defun consent-approval--audit-request (record)
  "Audit approval request RECORD."
  (consent-audit-record
   'approval-request
   `((category . agent-approval)
     (operation . ,(or (consent-approval--record-field
                        record "operation")
                       "approval-request!"))
     (id . ,(consent-approval--record-field record "id"))
     (policy . ,(consent-approval--record-field record "policy"))
     (status . ,(consent-approval--record-field record "status"))
     (record . ,record)))
  record)

(defun consent-approval--audit-decision (record decision)
  "Audit approval RECORD resolved with DECISION."
  (consent-audit-record
   'approval-decision
   `((category . agent-approval)
     (operation . "approval-resolve!")
     (id . ,(consent-approval--record-field record "id"))
     (decision . ,decision)
     (status . ,(consent-approval--record-field record "status"))
     (record . ,record)))
  record)

;;;###autoload
(defun consent-approval-request! (datum)
  "Create an approval request from DATUM and return its id."
  (let ((record (consent-approval--make-record datum)))
    (consent-approval--set-record! record)
    (consent-approval--audit-request record)
    (consent-approval--record-field record "id")))

;;;###autoload
(defun consent-approval-request-from-policy!
    (category operation _fields request &optional _context)
  "Create an approval record for a policy CATEGORY request.
OPERATION names the gated operation.  REQUEST is the Scheme-readable policy
request passed to confirmation hooks and stored as the proposed effect."
  (consent-approval-request!
   (append
    (list
     (consent-approval--symbol "approval-request")
     (consent-approval--field
      "policy"
      (consent-approval--symbol category))
     (consent-approval--field "operation" operation)
     (consent-approval--field "effect" request)
     (consent-approval--field
      "reason"
      (format "%s requires approval" operation))))))

;;;###autoload
(defun consent-approval-ref (id)
  "Return approval request record ID, or nil when unknown."
  (seq-find
   (lambda (record)
     (consent-approval--same-id-p record id))
   consent--approval-records))

;;;###autoload
(defun consent-approval-status (id)
  "Return approval request ID status, or nil when unknown."
  (when-let ((record (consent-approval-ref id)))
    (consent-approval--status
     (consent-approval--record-field record "status"))))

;;;###autoload
(defun consent-approval-records (&optional session status)
  "Return approval records, optionally filtered by SESSION and STATUS."
  (let ((session-symbol (and session (consent-approval--symbol session)))
        (status-symbol (and status
                            (consent-approval--symbol
                             (consent-approval--status status)))))
    (seq-filter
     (lambda (record)
       (and
        (or (not session-symbol)
            (equal (consent-approval--record-field record "session")
                   session-symbol))
        (or (not status-symbol)
            (equal (consent-approval--record-field record "status")
                   status-symbol))))
     consent--approval-records)))

;;;###autoload
(defun consent-approval-pending-records (&optional session)
  "Return pending approval records, optionally filtered by SESSION."
  (consent-approval-records session 'pending))

;;;###autoload
(defun consent-approval-resolve! (id decision)
  "Resolve approval request ID with DECISION and return the updated record."
  (let* ((normalized-decision (consent-approval--status decision))
         (record (or (consent-approval-ref id)
                     (signal 'consent-approval-error
                             (list (format "unknown approval id: %s"
                                           (consent-approval--id-name
                                            id)))))))
    (unless (memq normalized-decision '(approved denied))
      (signal 'consent-approval-error
              (list "approval decisions must be approved or denied")))
    (let ((updated
           (consent-approval--replace-field
            record
            "status"
            (consent-approval--symbol normalized-decision))))
      (consent-approval--set-record! updated)
      (consent-approval--audit-decision updated normalized-decision)
      updated)))

;;;###autoload
(defun consent-approval-cancel! (id)
  "Cancel approval request ID and return the updated record."
  (let ((record (or (consent-approval-ref id)
                    (signal 'consent-approval-error
                            (list (format "unknown approval id: %s"
                                          (consent-approval--id-name
                                           id)))))))
    (unless (eq (consent-approval--status
                 (consent-approval--record-field record "status"))
                'pending)
      (signal 'consent-approval-error
              (list "only pending approvals can be canceled")))
    (let ((updated
           (consent-approval--replace-field
            record
            "status"
            (consent-approval--symbol "canceled"))))
      (consent-approval--set-record! updated)
      (consent-approval--audit-decision updated 'canceled)
      updated)))

;;;###autoload
(defun consent-approval-yield-pending (context)
  "Yield pending approval records through CONTEXT and return them."
  (let ((records (consent-approval-pending-records
                  consent--approval-current-session)))
    (dolist (record records)
      (consent--record-event!
       context
       (list (consent-approval--symbol "yield") record)))
    (consent-audit-record
     'approval-yield
     `((category . agent-approval)
       (operation . "approval-yield-pending")
       (session . ,(and consent--approval-current-session
                        (consent-approval--symbol
                         consent--approval-current-session)))
       (count . ,(length records))
       (decision . completed)))
    records))

;;;###autoload
(defun consent-approval-clear! ()
  "Clear in-memory approval request records."
  (setq consent--approval-records nil)
  (setq consent--approval-next-id 0)
  consent-unspecified)

(defun consent-approval--primitive-request (arguments _context)
  "Primitive approval-request! over ARGUMENTS."
  (consent-approval-request! (car arguments)))

(defun consent-approval--primitive-status (arguments _context)
  "Primitive approval-status over ARGUMENTS."
  (let* ((record (consent-approval-ref (car arguments)))
         (status (and record
                      (consent-approval--record-in-current-session-p
                       record)
                      (consent-approval--status
                       (consent-approval--record-field
                        record "status")))))
    (if status
        (consent-approval--symbol status)
      consent-false)))

(defun consent-approval--primitive-cancel (arguments _context)
  "Primitive approval-cancel! over ARGUMENTS."
  (consent-approval--primitive-record
   (car arguments)
   "approval-cancel!")
  (consent-approval-cancel! (car arguments)))

(defun consent-approval--primitive-yield-pending (_arguments context)
  "Primitive approval-yield-pending over ARGUMENTS."
  (consent-approval-yield-pending context))

(defun consent-approval--primitive-resolve (arguments context)
  "Primitive approval-resolve! over ARGUMENTS."
  (consent-approval--primitive-record
   (car arguments)
   "approval-resolve!")
  (consent-policy-authorize
   'approval-resolution
   "approval-resolve!"
   `((id . ,(car arguments))
     (decision . ,(cadr arguments)))
   context
   'approval-policy)
  (consent-approval-resolve! (car arguments) (cadr arguments)))

;;;###autoload
(defun consent-approval-primitive-specs ()
  "Return primitive specs for the `(agent approval)' library."
  `(("approval-request!" ,#'consent-approval--primitive-request 1 1)
    ("approval-status" ,#'consent-approval--primitive-status 1 1)
    ("approval-cancel!" ,#'consent-approval--primitive-cancel 1 1)
    ("approval-yield-pending"
     ,#'consent-approval--primitive-yield-pending 0 0)
    ("approval-resolve!" ,#'consent-approval--primitive-resolve 2 2)))

(provide 'consent-approval)

;;; consent-approval.el ends here
