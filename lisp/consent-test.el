;;; consent-test.el --- Agent helper self-test primitives  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Primitive bridge for `(agent test)'.  The public test API is implemented in
;; portable Scheme; this module only evaluates declared source-string tests
;; through the normal Consent Scheme evaluator so budgets and sandbox policy stay
;; in force.

;;; Code:

(require 'consent-runtime)

(declare-function consent-eval-source-result "consent-eval")

(defconst consent-test--option-keys
  '((max-steps . :max-steps)
    (max-non-tail-steps . :max-non-tail-steps)
    (max-value-nodes . :max-value-nodes)
    (max-source-metadata . :max-source-metadata)
    (max-interned-symbols . :max-interned-symbols)
    (max-host-callbacks . :max-host-callbacks)
    (max-events . :max-events)
    (max-event-nodes . :max-event-nodes)
    (max-output-bytes . :max-output-bytes)
    (max-wall-time-ms . :max-wall-time-ms))
  "Budget options accepted by `(agent test)' source-string execution.")

(defun consent-test--symbol-name (value)
  "Return VALUE as a Scheme symbol name string, or nil."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun consent-test--option-key (key)
  "Return the host plist key corresponding to Scheme KEY, or nil."
  (when-let ((name (consent-test--symbol-name key)))
    (cdr (assq (intern name) consent-test--option-keys))))

(defun consent-test--host-integer (value description)
  "Return VALUE as a host integer for DESCRIPTION."
  (cond
   ((integerp value)
    value)
   ((and (consent-number-p value)
         (eq (consent-number-kind value) 'integer)
         (eq (consent-number-exactness value) 'exact))
    (consent-number-value value))
   (t
    (consent--eval-error "%s must be an exact integer" description))))

(defun consent-test--option-value (key value)
  "Return VALUE normalized for budget option KEY."
  (pcase key
    ((or :max-steps
         :max-non-tail-steps
         :max-value-nodes
         :max-source-metadata
         :max-interned-symbols
         :max-host-callbacks
         :max-events
         :max-event-nodes
         :max-output-bytes
         :max-wall-time-ms)
     (consent-test--host-integer value (symbol-name key)))
    (_ value)))

(defun consent-test--options-plist (options)
  "Return Scheme OPTIONS as a restricted evaluator plist."
  (let (plist)
    (dolist (entry (consent--proper-list-elements
                    options "agent test options")
                   plist)
      (let* ((elements (consent--proper-list-elements-maybe entry))
             (key (and elements
                       (= (length elements) 2)
                       (consent-test--option-key (car elements)))))
        (when key
          (setq plist
                (plist-put plist
                           key
                           (consent-test--option-value
                            key
                            (cadr elements)))))))))

(defun consent-test--primitive-eval-source-result
    (arguments _context)
  "Primitive agent-test-eval-source-result over ARGUMENTS."
  (let ((source (car arguments))
        (options (cadr arguments)))
    (unless (stringp source)
      (consent--eval-error
       "agent-test-eval-source-result source must be a string"))
    (consent-eval-source-result
     source
     nil
     (consent-test--options-plist options))))

;;;###autoload
(defun consent-test-primitive-specs ()
  "Return primitive specs for the `(agent test primitive)' library."
  `(("agent-test-eval-source-result"
     ,#'consent-test--primitive-eval-source-result
     1
     2)))

(provide 'consent-test)

;;; consent-test.el ends here
