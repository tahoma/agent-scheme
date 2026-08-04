;;; consent-agent-io.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent io)' library records structured event-channel procedures as
;; per-evaluation result events and Scheme-readable audit entries.

;;; Code:

(require 'consent-audit)
(require 'consent-redaction)
(require 'consent-runtime)

(defun consent-agent-io--field (name &rest values)
  "Return a Scheme-readable event field named NAME with VALUES."
  (cons (consent--syntax-symbol name) values))

(defun consent-agent-io--record (operation event fields context)
  "Record OPERATION EVENT with FIELDS in CONTEXT and the audit log."
  (let ((redacted-event (consent-redact event 'context-event))
        (redacted-fields (consent-redact fields 'context-event)))
    (consent--record-event! context redacted-event)
    (consent-audit-record
     'context-event
     (append
      `((category . agent-io)
        (operation . ,operation)
        (decision . recorded))
      `((record . ,redacted-event))
      redacted-fields)))
  consent-unspecified)

(defun consent-agent-io--primitive-yield (arguments context)
  "Primitive agent-yield over ARGUMENTS."
  (consent-agent-io--record
   "agent-yield"
   (list (consent--syntax-symbol "yield") (car arguments))
   `((datum . ,(car arguments)))
   context))

(defun consent-agent-io--primitive-log (arguments context)
  "Primitive agent-log over ARGUMENTS."
  (consent-agent-io--record
   "agent-log"
   (list (consent--syntax-symbol "log")
         (consent-agent-io--field "level" (car arguments))
         (consent-agent-io--field "message" (cadr arguments))
         (consent-agent-io--field "fields" (cddr arguments)))
   `((level . ,(car arguments))
     (message . ,(cadr arguments))
     (fields . ,(cddr arguments)))
   context))

(defun consent-agent-io--primitive-progress (arguments context)
  "Primitive agent-progress over ARGUMENTS."
  (consent-agent-io--record
   "agent-progress"
   (list (consent--syntax-symbol "progress")
         (consent-agent-io--field "phase" (car arguments))
         (consent-agent-io--field "datum" (cadr arguments)))
   `((phase . ,(car arguments))
     (datum . ,(cadr arguments)))
   context))

(defun consent-agent-io--primitive-warn (arguments context)
  "Primitive agent-warn over ARGUMENTS."
  (consent-agent-io--record
   "agent-warn"
   (list (consent--syntax-symbol "warn")
         (consent-agent-io--field "message" (car arguments))
         (consent-agent-io--field "fields" (cdr arguments)))
   `((message . ,(car arguments))
     (fields . ,(cdr arguments)))
   context))

(defun consent-agent-io--primitive-request (arguments context)
  "Primitive agent-request over ARGUMENTS."
  (consent-agent-io--record
   "agent-request"
   (list (consent--syntax-symbol "request") (car arguments))
   `((request . ,(car arguments)))
   context))

(defconst consent-agent-io--primitive-implementation-table
  `((primitive-agent-yield . ,#'consent-agent-io--primitive-yield)
    (primitive-agent-log . ,#'consent-agent-io--primitive-log)
    (primitive-agent-progress . ,#'consent-agent-io--primitive-progress)
    (primitive-agent-warn . ,#'consent-agent-io--primitive-warn)
    (primitive-agent-request . ,#'consent-agent-io--primitive-request))
  "Provider-owned primitive implementations for `(agent io)'.")

;;;###autoload
(defun consent-agent-io-primitive-implementation (primitive)
  "Return `(agent io)' implementation for PRIMITIVE."
  (consent--primitive-implementation-from-table
   primitive
   consent-agent-io--primitive-implementation-table
   "`(agent io)'"))

(provide 'consent-agent-io)

;;; consent-agent-io.el ends here
