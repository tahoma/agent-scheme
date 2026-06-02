;;; consent-result.el --- Stable Consent Scheme result rendering  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Result rendering helpers for Consent Scheme runtime values and
;; Scheme-readable result datums.  This module does not evaluate Scheme
;; expressions; it turns already-produced values into stable external text.

;;; Code:

(require 'consent-reader)
(require 'consent-runtime)

(defun consent--strip-identifiers (value &optional seen)
  "Return VALUE with hygienic identifiers converted to plain symbols."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((consent--identifier-p value)
      (consent--syntax-symbol (consent--identifier-name value)))
     ((consp value)
      (if (gethash value seen)
          value
        (puthash value t seen)
        (cons (consent--strip-identifiers (car value) seen)
              (consent--strip-identifiers (cdr value) seen))))
     ((vectorp value)
      (if (gethash value seen)
          value
        (puthash value t seen)
        (vconcat
         (mapcar
          (lambda (item)
            (consent--strip-identifiers item seen))
          (append value nil)))))
     (t value))))

(defun consent-result->external (result)
  "Return RESULT as a stable Scheme-readable external representation."
  (consent-datum->external result))

(defun consent-value->external (value)
  "Return a stable external representation for evaluated VALUE."
  (cond
   ((consent-unspecified-p value)
    "#<unspecified>")
   ((consent-procedure-p value)
    "#<procedure>")
   ((consent-primitive-procedure-p value)
    (format "#<primitive %s>"
            (consent-primitive-procedure-name value)))
   ((consent--continuation-p value)
    "#<continuation>")
   ((consent-error-object-p value)
    (format "#<error-object %S>"
            (consent-error-object-message value)))
   ((consent-eof-object-p value)
    "#<eof>")
   ((consent--port-p value)
    (format "#<%s-port%s>"
            (symbol-name (consent--port-medium value))
            (if (consent--port-openp value) "" " closed")))
   ((consent--environment-specifier-p value)
    "#<environment>")
   ((consent--multiple-values-p value)
    (consent-datum->external
     (cons (consent--syntax-symbol "values")
           (mapcar #'consent--strip-identifiers
                   (consent--multiple-values-values value)))))
   (t
    (consent-datum->external
     (consent--strip-identifiers value)))))

(provide 'consent-result)

;;; consent-result.el ends here
