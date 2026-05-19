;;; agent-scheme-agent-io.el --- Agent event channel primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent io)' library records structured event-channel procedures as
;; Scheme-readable audit entries.  Session-owned event storage can layer on top
;; of these records later without changing the Scheme surface.

;;; Code:

(require 'agent-scheme-audit)
(require 'agent-scheme-runtime)

(defun agent-scheme-agent-io--record (operation fields)
  "Record OPERATION with FIELDS as an agent event audit entry."
  (agent-scheme-audit-record
   'agent-event
   (append
    `((category . agent-io)
      (operation . ,operation)
      (decision . recorded))
    fields))
  agent-scheme-unspecified)

(defun agent-scheme-agent-io--primitive-yield (arguments _context)
  "Primitive agent-yield over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-yield"
   `((datum . ,(car arguments)))))

(defun agent-scheme-agent-io--primitive-log (arguments _context)
  "Primitive agent-log over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-log"
   `((level . ,(car arguments))
     (message . ,(cadr arguments))
     (fields . ,(cddr arguments)))))

(defun agent-scheme-agent-io--primitive-progress (arguments _context)
  "Primitive agent-progress over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-progress"
   `((phase . ,(car arguments))
     (datum . ,(cadr arguments)))))

(defun agent-scheme-agent-io--primitive-warn (arguments _context)
  "Primitive agent-warn over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-warn"
   `((message . ,(car arguments))
     (fields . ,(cdr arguments)))))

(defun agent-scheme-agent-io--primitive-request (arguments _context)
  "Primitive agent-request over ARGUMENTS."
  (agent-scheme-agent-io--record
   "agent-request"
   `((request . ,(car arguments)))))

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
