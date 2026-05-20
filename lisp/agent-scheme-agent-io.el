;;; agent-scheme-agent-io.el --- Agent event channel primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent io)' library records structured event-channel procedures as
;; per-evaluation result events and Scheme-readable audit entries.

;;; Code:

(require 'agent-scheme-audit)
(require 'agent-scheme-redaction)
(require 'agent-scheme-runtime)

(defun agent-scheme-agent-io--field (name &rest values)
  "Return a Scheme-readable event field named NAME with VALUES."
  (cons (agent-scheme--syntax-symbol name) values))

(defun agent-scheme-agent-io--record (operation event fields context)
  "Record OPERATION EVENT with FIELDS in CONTEXT and the audit log."
  (let ((redacted-event (agent-scheme-redact event 'agent-event))
        (redacted-fields (agent-scheme-redact fields 'agent-event)))
    (agent-scheme--record-event! context redacted-event)
    (agent-scheme-audit-record
     'agent-event
     (append
      `((category . agent-io)
        (operation . ,operation)
        (decision . recorded))
      `((record . ,redacted-event))
      redacted-fields)))
  agent-scheme-unspecified)

(defun agent-scheme-agent-io--primitive-yield (arguments context)
  "Primitive agent-yield over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-yield"
   (list (agent-scheme--syntax-symbol "yield") (car arguments))
   `((datum . ,(car arguments)))
   context))

(defun agent-scheme-agent-io--primitive-log (arguments context)
  "Primitive agent-log over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-log"
   (list (agent-scheme--syntax-symbol "log")
         (agent-scheme-agent-io--field "level" (car arguments))
         (agent-scheme-agent-io--field "message" (cadr arguments))
         (agent-scheme-agent-io--field "fields" (cddr arguments)))
   `((level . ,(car arguments))
     (message . ,(cadr arguments))
     (fields . ,(cddr arguments)))
   context))

(defun agent-scheme-agent-io--primitive-progress (arguments context)
  "Primitive agent-progress over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-progress"
   (list (agent-scheme--syntax-symbol "progress")
         (agent-scheme-agent-io--field "phase" (car arguments))
         (agent-scheme-agent-io--field "datum" (cadr arguments)))
   `((phase . ,(car arguments))
     (datum . ,(cadr arguments)))
   context))

(defun agent-scheme-agent-io--primitive-warn (arguments context)
  "Primitive agent-warn over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-warn"
   (list (agent-scheme--syntax-symbol "warn")
         (agent-scheme-agent-io--field "message" (car arguments))
         (agent-scheme-agent-io--field "fields" (cdr arguments)))
   `((message . ,(car arguments))
     (fields . ,(cdr arguments)))
   context))

(defun agent-scheme-agent-io--primitive-request (arguments context)
  "Primitive agent-request over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-request"
   (list (agent-scheme--syntax-symbol "request") (car arguments))
   `((request . ,(car arguments)))
   context))

;;;###autoload
(defun agent-scheme-agent-io-primitive-specs ()
  "Return primitive specs for the `(agent io)' library."
  `(("agent-yield" ,#'agent-scheme-agent-io--primitive-yield 1 1)
    ("agent-log" ,#'agent-scheme-agent-io--primitive-log 2 nil)
    ("agent-progress" ,#'agent-scheme-agent-io--primitive-progress 2 2)
    ("agent-warn" ,#'agent-scheme-agent-io--primitive-warn 1 nil)
    ("agent-request" ,#'agent-scheme-agent-io--primitive-request 1 1)))

(provide 'agent-scheme-agent-io)

;;; agent-scheme-agent-io.el ends here
