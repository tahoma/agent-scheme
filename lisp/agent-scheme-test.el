;;; agent-scheme-test.el --- Agent helper self-test primitives  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Primitive bridge for `(agent test)'.  The public test API is implemented in
;; portable Scheme; this module only evaluates declared source-string tests
;; through the normal Agent Scheme evaluator so budgets and sandbox policy stay
;; in force.

;;; Code:

(require 'agent-scheme-runtime)

(declare-function agent-scheme-eval-source-result "agent-scheme-eval")

(defconst agent-scheme-test--option-keys
  '((max-steps . :max-steps)
    (max-non-tail-steps . :max-non-tail-steps)
    (max-value-nodes . :max-value-nodes)
    (max-host-callbacks . :max-host-callbacks)
    (max-events . :max-events)
    (max-event-nodes . :max-event-nodes))
  "Budget options accepted by `(agent test)' source-string execution.")

(defun agent-scheme-test--symbol-name (value)
  "Return VALUE as a Scheme symbol name string, or nil."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun agent-scheme-test--option-key (key)
  "Return the host plist key corresponding to Scheme KEY, or nil."
  (when-let ((name (agent-scheme-test--symbol-name key)))
    (cdr (assq (intern name) agent-scheme-test--option-keys))))

(defun agent-scheme-test--host-integer (value description)
  "Return VALUE as a host integer for DESCRIPTION."
  (cond
   ((integerp value)
    value)
   ((and (agent-scheme-number-p value)
         (eq (agent-scheme-number-kind value) 'integer)
         (eq (agent-scheme-number-exactness value) 'exact))
    (agent-scheme-number-value value))
   (t
    (agent-scheme--eval-error "%s must be an exact integer" description))))

(defun agent-scheme-test--option-value (key value)
  "Return VALUE normalized for budget option KEY."
  (pcase key
    ((or :max-steps
         :max-non-tail-steps
         :max-value-nodes
         :max-host-callbacks
         :max-events
         :max-event-nodes)
     (agent-scheme-test--host-integer value (symbol-name key)))
    (_ value)))

(defun agent-scheme-test--options-plist (options)
  "Return Scheme OPTIONS as a restricted evaluator plist."
  (let (plist)
    (dolist (entry (agent-scheme--proper-list-elements
                    options "agent test options")
                   plist)
      (let* ((elements (agent-scheme--proper-list-elements-maybe entry))
             (key (and elements
                       (= (length elements) 2)
                       (agent-scheme-test--option-key (car elements)))))
        (when key
          (setq plist
                (plist-put plist
                           key
                           (agent-scheme-test--option-value
                            key
                            (cadr elements)))))))))

(defun agent-scheme-test--primitive-eval-source-result
    (arguments _context)
  "Primitive agent-test-eval-source-result over ARGUMENTS."
  (let ((source (car arguments))
        (options (cadr arguments)))
    (unless (stringp source)
      (agent-scheme--eval-error
       "agent-test-eval-source-result source must be a string"))
    (agent-scheme-eval-source-result
     source
     nil
     (agent-scheme-test--options-plist options))))

;;;###autoload
(defun agent-scheme-test-primitive-specs ()
  "Return primitive specs for the `(agent test primitive)' library."
  `(("agent-test-eval-source-result"
     ,#'agent-scheme-test--primitive-eval-source-result
     1
     2)))

(provide 'agent-scheme-test)

;;; agent-scheme-test.el ends here
