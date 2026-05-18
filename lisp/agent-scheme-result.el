;;; agent-scheme-result.el --- Stable Agent Scheme result rendering  -*- lexical-binding: t; -*-

;;; Commentary:

;; Result rendering helpers for Agent Scheme runtime values and
;; Scheme-readable result datums.  This module does not evaluate Scheme
;; expressions; it turns already-produced values into stable external text.

;;; Code:

(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)

(defun agent-scheme--strip-identifiers (value &optional seen)
  "Return VALUE with hygienic identifiers converted to plain symbols."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((agent-scheme--identifier-p value)
      (agent-scheme--syntax-symbol (agent-scheme--identifier-name value)))
     ((consp value)
      (if (gethash value seen)
          value
        (puthash value t seen)
        (cons (agent-scheme--strip-identifiers (car value) seen)
              (agent-scheme--strip-identifiers (cdr value) seen))))
     ((vectorp value)
      (if (gethash value seen)
          value
        (puthash value t seen)
        (vconcat
         (mapcar
          (lambda (item)
            (agent-scheme--strip-identifiers item seen))
          (append value nil)))))
     (t value))))

(defun agent-scheme-result->external (result)
  "Return RESULT as a stable Scheme-readable external representation."
  (agent-scheme-datum->external result))

(defun agent-scheme-value->external (value)
  "Return a stable external representation for evaluated VALUE."
  (cond
   ((agent-scheme-unspecified-p value)
    "#<unspecified>")
   ((agent-scheme-procedure-p value)
    "#<procedure>")
   ((agent-scheme-primitive-procedure-p value)
    (format "#<primitive %s>"
            (agent-scheme-primitive-procedure-name value)))
   ((agent-scheme--continuation-p value)
    "#<continuation>")
   ((agent-scheme-error-object-p value)
    (format "#<error-object %S>"
            (agent-scheme-error-object-message value)))
   ((agent-scheme-eof-object-p value)
    "#<eof>")
   ((agent-scheme--port-p value)
    (format "#<%s-port%s>"
            (symbol-name (agent-scheme--port-medium value))
            (if (agent-scheme--port-openp value) "" " closed")))
   ((agent-scheme--environment-specifier-p value)
    "#<environment>")
   ((agent-scheme--multiple-values-p value)
    (agent-scheme-datum->external
     (cons (agent-scheme--syntax-symbol "values")
           (mapcar #'agent-scheme--strip-identifiers
                   (agent-scheme--multiple-values-values value)))))
   (t
    (agent-scheme-datum->external
     (agent-scheme--strip-identifiers value)))))

(provide 'agent-scheme-result)

;;; agent-scheme-result.el ends here
