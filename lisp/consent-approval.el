;;; consent-approval.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The source-loaded `(agent approval)' library owns canonical approval request
;; store helpers.  This host adapter keeps current-session ownership checks,
;; policy authorization, audit emission, and native Emacs views.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'consent-audit)
(require 'consent-runtime)

(declare-function consent--source-library-call "consent-library")
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

(defvar consent--approval-store nil
  "Source-backed approval request store.")

(defvar consent--approval-current-session nil
  "Dynamically bound session id for approval requests made in a session.")

(defun consent-approval--source-call (name &rest arguments)
  "Call source-backed approval procedure NAME with ARGUMENTS."
  (unless (fboundp 'consent--source-library-call)
    (require 'consent-library))
  (apply #'consent--source-library-call
         "(agent approval)" name arguments))

(defun consent-approval--store ()
  "Return the source-backed approval store."
  (or consent--approval-store
      (setq consent--approval-store
            (consent-approval--source-call
             "consent-make-approval-store"))))

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

(defun consent-approval--id-symbol (id)
  "Return ID as a source-library approval id symbol."
  (consent-approval--symbol (consent-approval--id-name id)))

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

(defun consent-approval--session-field ()
  "Return the current session field, or nil outside session evaluation."
  (when consent--approval-current-session
    (consent-approval--field
     "session"
     (consent-approval--symbol consent--approval-current-session))))

(defun consent-approval--request-datum (datum)
  "Return DATUM with host current-session ownership attached when present."
  (if-let ((session-field (consent-approval--session-field)))
      (if (consent-approval--request-fields datum)
          (append
           (list (car datum) session-field)
           (cdr datum))
        (list
         (consent-approval--field "effect" datum)
         session-field))
    datum))

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
  (let* ((request (consent-approval--request-datum datum))
         (id
          (consent-approval--source-call
           "approval-store-request!"
           (consent-approval--store)
           request))
         (record (consent-approval-ref id)))
    (consent-approval--audit-request record)
    id))

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
  (let ((record
         (consent-approval--source-call
          "approval-store-ref"
          (consent-approval--store)
          (consent-approval--id-symbol id))))
    (unless (eq record consent-false)
      record)))

;;;###autoload
(defun consent-approval-status (id)
  "Return approval request ID status, or nil when unknown."
  (let ((status
         (consent-approval--source-call
          "approval-store-status"
          (consent-approval--store)
          (consent-approval--id-symbol id))))
    (unless (eq status consent-false)
      (consent-approval--status status))))

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
     (consent-approval--source-call
      "approval-store-records"
      (consent-approval--store)))))

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
           (condition-case err
               (consent-approval--source-call
                "approval-store-resolve!"
                (consent-approval--store)
                (consent-approval--record-field record "id")
                (consent-approval--symbol normalized-decision))
             (consent-eval-error
              (signal 'consent-approval-error (cdr err))))))
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
           (condition-case err
               (consent-approval--source-call
                "approval-store-cancel!"
                (consent-approval--store)
                (consent-approval--record-field record "id"))
             (consent-eval-error
              (signal 'consent-approval-error (cdr err))))))
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
  (setq consent--approval-store nil)
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

(defconst consent-approval--primitive-implementation-table
  `((primitive-approval-request! . ,#'consent-approval--primitive-request)
    (primitive-approval-status . ,#'consent-approval--primitive-status)
    (primitive-approval-cancel! . ,#'consent-approval--primitive-cancel)
    (primitive-approval-yield-pending
     . ,#'consent-approval--primitive-yield-pending)
    (primitive-approval-resolve! . ,#'consent-approval--primitive-resolve))
  "Provider-owned primitive implementations for `(agent approval)'.")

;;;###autoload
(defun consent-approval-primitive-implementation (primitive)
  "Return `(agent approval)' implementation for PRIMITIVE."
  (consent--primitive-implementation-from-table
   primitive
   consent-approval--primitive-implementation-table
   "`(agent approval)'"))

(provide 'consent-approval)

;;; consent-approval.el ends here
