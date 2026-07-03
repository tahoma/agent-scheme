;;; consent-reflect.el --- Runtime reflection primitives  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; The `(agent reflect)' library exposes read-only runtime snapshots as
;; Scheme-readable datums.  It reports public context, manifest, event, and
;; audit metadata without returning raw host objects, provider credentials, or
;; implementation hooks.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'consent-audit)
(require 'consent-base)
(require 'consent-capability)
(require 'consent-policy)
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-runtime)

(declare-function consent-macroexpand "consent-macro")
(declare-function consent-macroexpand-1 "consent-macro")
(declare-function consent-macroexpand-library "consent-macro")
(declare-function consent-macro-binding-info "consent-macro")
(declare-function consent-syntax-source "consent-macro")
(declare-function consent--library-binding-kind "consent-library")
(declare-function consent--library-binding-library-key "consent-library")
(declare-function consent--library-binding-name "consent-library")
(declare-function consent--library-exports "consent-library")
(declare-function consent--library-name-key "consent-library")

(defconst consent-reflect--omitted-manifest-fields
  '(:emacs-hook :portable-hook :emitter-hook :test-categories)
  "Primitive manifest fields not exposed through runtime reflection.")

(defun consent-reflect--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((keywordp name)
     (substring (symbol-name name) 1))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-reflect--boolean (value)
  "Return VALUE as a canonical Scheme boolean."
  (if value consent-true consent-false))

(defun consent-reflect--integer (value)
  "Return host integer VALUE as an exact Scheme integer datum."
  (consent--make-canonical-integer value))

(defun consent-reflect--field (name value)
  "Return a Scheme-readable reflection field."
  (list (consent-reflect--symbol name) value))

(defun consent-reflect--datumize (value)
  "Return VALUE as a Scheme-readable datum for reflection."
  (cond
   ((or (eq value consent-true)
        (eq value consent-false)
        (consent-symbol-p value)
        (consent-character-p value)
        (consent-number-p value)
        (consent-bytevector-p value)
        (consent-record-p value)
        (consent-record-type-p value)
        (consent-handle-p value))
    value)
   ((eq value t)
    consent-true)
   ((null value)
    nil)
   ((symbolp value)
    (consent-reflect--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (consent-reflect--integer value))
   ((consp value)
    (cons (consent-reflect--datumize (car value))
          (consent-reflect--datumize (cdr value))))
   ((vectorp value)
    (vconcat (mapcar #'consent-reflect--datumize (append value nil))))
   (t
    "#<host-object>")))

(defun consent-reflect--optional-datumize (value)
  "Return VALUE as a datum, using #f for absent optional fields."
  (if (null value)
      consent-false
    (consent-reflect--datumize value)))

(defun consent-reflect--library-datum (key)
  "Return library KEY as a Scheme-readable library-name datum."
  (if (stringp key)
      (condition-case _
          (consent-read key)
        (error key))
    (consent-reflect--datumize key)))

(defun consent-reflect--manifest-specs ()
  "Return host-capability primitive manifest specs."
  (seq-filter
   (lambda (spec)
     (eq (plist-get spec :source) 'host-capability))
   (consent-primitive-manifest-binding-specs)))

(defun consent-reflect--manifest-spec-field (spec key default)
  "Return SPEC property KEY, using DEFAULT when absent."
  (if (plist-member spec key)
      (plist-get spec key)
    default))

(defun consent-reflect--manifest-record (spec)
  "Return SPEC as a public `host-capability' reflection record."
  (let* ((name (plist-get spec :name))
         (library (plist-get spec :library))
         (fields
          `((library . ,(consent-reflect--library-datum library))
            (name . ,(consent-reflect--symbol name))
            (minimum-arity
             . ,(consent-reflect--datumize
                 (plist-get spec :minimum-arity)))
            (maximum-arity
             . ,(consent-reflect--optional-datumize
                 (plist-get spec :maximum-arity)))
            (source . ,(consent-reflect--datumize
                        (plist-get spec :source)))
            (effect . ,(consent-reflect--datumize
                        (plist-get spec :effect)))
            (required-capability
             . ,(consent-reflect--optional-datumize
                 (consent-reflect--manifest-spec-field
                  spec :required-capability nil)))
            (backend-effect-path
             . ,(consent-reflect--optional-datumize
                 (consent-reflect--manifest-spec-field
                  spec :backend-effect-path nil)))
            (policy-category
             . ,(consent-reflect--optional-datumize
                 (consent-reflect--manifest-spec-field
                  spec :policy-category nil)))
            (policy . ,(consent-reflect--optional-datumize
                        (consent-reflect--manifest-spec-field
                         spec :policy nil)))
            (requires-grant
             . ,(consent-reflect--boolean
                 (consent-reflect--manifest-spec-field
                  spec :requires-grant nil))))))
    (cons (consent-reflect--symbol "host-capability")
          (mapcar (lambda (field)
                    (consent-reflect--field (car field) (cdr field)))
                  fields))))

(defun consent-reflect-current-capabilities ()
  "Return all known host capability metadata records."
  (mapcar #'consent-reflect--manifest-record
          (consent-reflect--manifest-specs)))

(defun consent-reflect--capability-name (symbol-or-name)
  "Return SYMBOL-OR-NAME as a capability name string."
  (cond
   ((consent-symbol-p symbol-or-name)
    (consent-symbol-name symbol-or-name))
   ((symbolp symbol-or-name)
    (symbol-name symbol-or-name))
   ((stringp symbol-or-name)
    symbol-or-name)
   (t
    (consent--eval-error
     "capability-info expects a symbol or string"))))

(defun consent-reflect-capability-info (symbol-or-name)
  "Return metadata for SYMBOL-OR-NAME, or #f when absent."
  (let* ((name (consent-reflect--capability-name symbol-or-name))
         (spec (seq-find
                (lambda (candidate)
                  (equal (plist-get candidate :name) name))
                (consent-reflect--manifest-specs))))
    (if spec
        (consent-reflect--manifest-record spec)
      consent-false)))

(defun consent-reflect--binding-name (symbol-or-name)
  "Return SYMBOL-OR-NAME as a binding name string."
  (cond
   ((consent-symbol-p symbol-or-name)
    (consent-symbol-name symbol-or-name))
   ((symbolp symbol-or-name)
    (symbol-name symbol-or-name))
   ((stringp symbol-or-name)
    symbol-or-name)
   (t nil)))

(defun consent-reflect--manifest-spec-for-name (name)
  "Return primitive manifest metadata for binding NAME, or nil."
  (seq-find
   (lambda (candidate)
     (equal (plist-get candidate :name) name))
   (consent-primitive-manifest-binding-specs)))

(defun consent-reflect--implementation-documentation (spec)
  "Return documentation metadata derived from SPEC's implementation hook."
  (let* ((hook (plist-get spec :emacs-hook))
         (documentation
          (and (symbolp hook)
               (fboundp hook)
               (documentation hook t))))
    (when (and (stringp documentation)
               (> (length documentation) 0))
      (consent--make-documentation-metadata
       (list (cons "documentation" documentation))
       '("implementation-procedure-string")))))

(defun consent-reflect--manifest-documentation (spec)
  "Return manifest or implementation documentation for primitive SPEC."
  (or (plist-get spec :documentation)
      (consent-reflect--implementation-documentation spec)))

(defun consent-reflect--primitive-procedure-spec (value)
  "Return primitive manifest metadata for primitive procedure VALUE."
  (and (consent-primitive-procedure-p value)
       (consent-reflect--manifest-spec-for-name
        (consent-primitive-procedure-name value))))

(defun consent-reflect--procedure-documentation (value)
  "Return documentation metadata attached to callable VALUE, or nil."
  (cond
   ((consent-procedure-p value)
    (consent-procedure-documentation value))
   ((consent-primitive-procedure-p value)
    (let ((spec (consent-reflect--primitive-procedure-spec value)))
      (and spec (consent-reflect--manifest-documentation spec))))
   (t nil)))

(defun consent-reflect--documentation-origin (documentation)
  "Return the Scheme-readable origin for DOCUMENTATION metadata."
  (let ((origins
         (consent--documentation-metadata-origins documentation)))
    (cond
     ((null origins)
      (list (consent-reflect--symbol "signature")))
     ((equal origins '("implementation-procedure-string"))
      (list (consent-reflect--symbol "implementation-procedure")
            (consent-reflect--symbol "string")))
     ((equal origins '("primitive-manifest-string"))
      (list (consent-reflect--symbol "primitive-manifest")
            (consent-reflect--symbol "string")))
     ((equal origins '("primitive-manifest-metadata"))
      (list (consent-reflect--symbol "primitive-manifest")
            (consent-reflect--symbol "metadata")))
     (t
      (cons (consent-reflect--symbol "body-literal")
            (mapcar #'consent-reflect--symbol origins))))))

(defun consent-reflect--documentation-fields (documentation)
  "Return Scheme-readable fields for DOCUMENTATION metadata."
  (mapcar
   (lambda (field)
     (list (consent-reflect--symbol (car field))
           (consent-reflect--datumize (cdr field))))
   (consent--documentation-metadata-fields documentation)))

(defun consent-reflect--documentation-metadata
    (subject documentation &optional spec)
  "Return a Scheme-readable documentation record for SUBJECT."
  (list
   (consent-reflect--symbol "documentation-metadata")
   (consent-reflect--field "subject" subject)
   (consent-reflect--field "kind"
                                (consent-reflect--symbol "procedure"))
   (consent-reflect--field
    "library"
    (if spec
        (consent-reflect--library-datum (plist-get spec :library))
      consent-false))
   (consent-reflect--field
    "source"
    (if spec
        (consent-reflect--datumize (plist-get spec :source))
      consent-false))
   (consent-reflect--field
    "origin"
    (consent-reflect--documentation-origin documentation))
   (consent-reflect--field
    "fields"
    (consent-reflect--documentation-fields documentation))))

(defun consent-reflect-documentation (subject context)
  "Return documentation metadata for SUBJECT, or #f when absent.
SUBJECT may be a binding symbol/name or a procedure value."
  (cond
   ((or (consent-procedure-p subject)
        (consent-primitive-procedure-p subject))
    (let* ((spec (consent-reflect--primitive-procedure-spec subject))
           (documentation
            (consent-reflect--procedure-documentation subject)))
      (if documentation
          (consent-reflect--documentation-metadata
           (list (consent-reflect--symbol "procedure"))
           documentation
           spec)
        consent-false)))
   (t
    (let* ((name (consent-reflect--binding-name subject))
           (environment
            (and context
                 (consent--eval-context-interaction-environment context)))
           (cell (and name
                      environment
                      (consent--environment-cell environment name)))
           (value (and cell (consent--cell-value cell)))
           (spec (consent-reflect--primitive-procedure-spec value))
           (documentation
            (and value
                 (not (consent--undefined-p value))
                 (consent-reflect--procedure-documentation value))))
      (if documentation
          (consent-reflect--documentation-metadata
           (list (consent-reflect--symbol "binding")
                 (consent-reflect--symbol name))
           documentation
           spec)
        consent-false)))))

(defun consent-reflect-current-budget (context)
  "Return the active budget ledger -- counters, limits, and stop reason.
The ledger is the single inspectable budget object: every enforced and reserved
dimension reports its used count and ceiling, and `reason' names the dimension
that stopped the run (or #f while admissible)."
  (list
   (consent-reflect--symbol "budget")
   (consent-reflect--field
    "steps-used"
    (consent-reflect--integer
     (consent--eval-context-steps context)))
   (consent-reflect--field
    "max-steps"
    (consent-reflect--datumize
     (consent--eval-context-maximum-steps context)))
   (consent-reflect--field
    "host-calls"
    (consent-reflect--integer
     (consent--eval-context-host-callbacks context)))
   (consent-reflect--field
    "max-host-calls"
    (consent-reflect--datumize
     (consent--eval-context-maximum-host-callbacks context)))
   (consent-reflect--field
    "events-used"
    (consent-reflect--integer
     (consent--eval-context-event-count context)))
   (consent-reflect--field
    "max-events"
    (consent-reflect--datumize
     (consent--eval-context-maximum-events context)))
   (consent-reflect--field
    "max-event-nodes"
    (consent-reflect--datumize
     (consent--eval-context-maximum-event-nodes context)))
   (consent-reflect--field
    "value-nodes-used"
    (consent-reflect--integer
     (consent--eval-context-value-nodes context)))
   (consent-reflect--field
    "max-value-nodes"
    (consent-reflect--datumize
     (consent--eval-context-maximum-value-nodes context)))
   (consent-reflect--field
    "source-metadata-used"
    (consent-reflect--integer 0))
   (consent-reflect--field
    "max-source-metadata"
    (consent-reflect--datumize
     (consent--eval-context-maximum-source-metadata context)))
   (consent-reflect--field
    "interned-symbols-used"
    (consent-reflect--integer
     (consent--eval-context-interned-symbols context)))
   (consent-reflect--field
    "max-interned-symbols"
    (consent-reflect--datumize
     (consent--eval-context-maximum-interned-symbols context)))
   (consent-reflect--field
    "output-bytes-used"
    (consent-reflect--integer
     (consent--eval-context-output-bytes context)))
   (consent-reflect--field
    "max-output-bytes"
    (consent-reflect--datumize
     (consent--eval-context-maximum-output-bytes context)))
   (consent-reflect--field
    "max-wall-time-ms"
    (consent-reflect--budget-limit-datum
     (consent--eval-context-maximum-wall-time-ms context)))
   (consent-reflect--field
    "reason"
    (consent-reflect--budget-reason-datum
     (consent--eval-context-exhaustion-reason context)))))

(defun consent-reflect--budget-limit-datum (limit)
  "Return LIMIT as a Scheme-readable budget ceiling, or #f when unbounded."
  (if limit (consent-reflect--datumize limit) consent-false))

(defun consent-reflect--budget-reason-datum (reason)
  "Return REASON as a Scheme symbol, or #f when no budget was exhausted."
  (if reason (consent-reflect--symbol reason) consent-false))

(defun consent-reflect--budget-headroom (limit used)
  "Return LIMIT minus USED as an exact integer, or #f when unbounded."
  (if (integerp limit)
      (consent-reflect--integer (- limit used))
    consent-false))

(defun consent-reflect-budget-remaining (context)
  "Return the budget ledger as remaining headroom per enforced dimension.
Each dimension reports LIMIT minus USED; an unbounded dimension reports #f so
callers can distinguish unbounded from exhausted."
  (list
   (consent-reflect--symbol "budget-remaining")
   (consent-reflect--field
    "steps"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-steps context)
     (consent--eval-context-steps context)))
   (consent-reflect--field
    "host-calls"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-host-callbacks context)
     (consent--eval-context-host-callbacks context)))
   (consent-reflect--field
    "events"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-events context)
     (consent--eval-context-event-count context)))
   (consent-reflect--field
    "value-nodes"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-value-nodes context)
     (consent--eval-context-value-nodes context)))
   (consent-reflect--field
    "source-metadata"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-source-metadata context)
     0))
   (consent-reflect--field
    "interned-symbols"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-interned-symbols context)
     (consent--eval-context-interned-symbols context)))
   (consent-reflect--field
    "output-bytes"
    (consent-reflect--budget-headroom
     (consent--eval-context-maximum-output-bytes context)
     (consent--eval-context-output-bytes context)))
   (consent-reflect--field
    "reason"
    (consent-reflect--budget-reason-datum
     (consent--eval-context-exhaustion-reason context)))))

(defun consent-reflect--policy-action-datum (category context)
  "Return CATEGORY's effective policy action in CONTEXT."
  (list (consent-reflect--symbol category)
        (consent-reflect--symbol
         (consent-policy-action-for-category category context))))

(defun consent-reflect-current-policy (context)
  "Return the active policy category table for CONTEXT."
  (let ((overrides
         (mapcar
          (lambda (entry)
            (list (consent-reflect--symbol (car entry))
                  (consent-reflect--datumize (cdr entry))))
          (consent--eval-context-policy-actions context))))
    (list
     (consent-reflect--symbol "policy")
     (consent-reflect--field
      "categories"
      (mapcar
       (lambda (category)
         (consent-reflect--policy-action-datum category context))
       consent-policy-categories))
     (consent-reflect--field "overrides" overrides)
     (consent-reflect--field
      "confirmation"
      (consent-reflect--boolean
       (consent--eval-context-policy-confirmation-function context))))))

(defun consent-reflect-current-imports (context)
  "Return registered library names for CONTEXT."
  (let (keys)
    (maphash
     (lambda (key _library)
       (push key keys))
     (consent--eval-context-libraries context))
    (mapcar #'consent-reflect--library-datum
            (sort keys #'string<))))

(defun consent-reflect--library-binding-datum (binding)
  "Return BINDING as a Scheme-readable library-binding record."
  (let ((library-key (consent--library-binding-library-key binding)))
    (list
     (consent-reflect--symbol "library-binding")
     (consent-reflect--field
      "name"
      (consent-reflect--symbol
       (consent--library-binding-name binding)))
     (consent-reflect--field
      "kind"
      (consent-reflect--symbol
       (consent--library-binding-kind binding)))
     (consent-reflect--field
      "library"
      (consent-reflect--library-datum
       (if (listp library-key)
           (copy-sequence library-key)
         library-key))))))

(defun consent-reflect-library-bindings (library-name context)
  "Return registered exported binding records for LIBRARY-NAME in CONTEXT."
  (let* ((key (consent--library-name-key library-name))
         (library (gethash key (consent--eval-context-libraries context))))
    (unless library
      (consent--eval-error "unknown library: %s" key))
    (mapcar
     #'consent-reflect--library-binding-datum
     (consent--library-exports library))))

(defun consent-reflect-current-session-info (context)
  "Return public session/job identity for CONTEXT."
  (list
   (consent-reflect--symbol "session-info")
   (consent-reflect--field
    "id"
    (if (consent--eval-context-session-id context)
        (consent-reflect--symbol
         (consent--eval-context-session-id context))
      consent-false))
   (consent-reflect--field
    "job"
    (if (consent--eval-context-job-id context)
        (consent-reflect--symbol
         (consent--eval-context-job-id context))
      consent-false))
   (consent-reflect--field
    "events-used"
    (consent-reflect--integer
     (consent--eval-context-event-count context)))))

(defun consent-reflect--record-head-name (datum)
  "Return DATUM record head as a string, or nil."
  (cond
   ((and (consp datum) (consent-symbol-p (car datum)))
    (consent-symbol-name (car datum)))
   ((and (consp datum) (symbolp (car datum)))
    (symbol-name (car datum)))
   (t nil)))

(defun consent-reflect--field-value (datum name)
  "Return field NAME's value from Scheme-readable DATUM."
  (let ((field
         (seq-find
          (lambda (candidate)
            (and (consp candidate)
                 (consent-symbol-p (car candidate))
                 (equal (consent-symbol-name (car candidate)) name)))
          (cdr-safe datum))))
    (and field (cadr field))))

(defun consent-reflect--field-entry (datum name)
  "Return field NAME's entry (head and values) from DATUM, or nil."
  (seq-find
   (lambda (candidate)
     (and (consp candidate)
          (equal (consent-reflect--record-head-name candidate) name)))
   (cdr-safe datum)))

(defun consent--budget-exhausted-condition-p (value)
  "Report whether VALUE is a budget-exhaustion condition or stop receipt.
VALUE may be a condition datum or an evaluation-result error datum, so a caller
can classify a recent error or a nested evaluation's outcome."
  (and (consp value)
       (let ((head (consent-reflect--record-head-name value)))
         (cond
          ((equal head "condition")
           (let ((type (consent-reflect--field-value value "type")))
             (and (consent-symbol-p type)
                  (equal (consent-symbol-name type) "budget-exhausted"))))
          ((equal head "evaluation-result")
           (let ((error-field (consent-reflect--field-entry value "error")))
             (and error-field
                  (let ((condition (consent-reflect--field-value
                                    error-field "condition")))
                    (and (consp condition)
                         (consent--budget-exhausted-condition-p condition))))))
          (t nil)))))

(defun consent-reflect--event-named-p (entry name)
  "Return non-nil when audit ENTRY has event NAME."
  (let ((event (consent-reflect--field-value entry "event")))
    (and (consent-symbol-p event)
         (equal (consent-symbol-name event) name))))

(defun consent-reflect--has-field-p (entry name)
  "Return non-nil when ENTRY contains field NAME."
  (seq-some
   (lambda (candidate)
     (and (consp candidate)
          (consent-symbol-p (car candidate))
          (equal (consent-symbol-name (car candidate)) name)))
   (cdr-safe entry)))

(defun consent-reflect--redact (datum)
  "Redact DATUM at the reflection disclosure boundary."
  (consent-redact datum 'runtime-reflection))

(defun consent-reflect-recent-yields (context)
  "Return recent yield events from CONTEXT in emission order."
  (consent-reflect--redact
   (seq-filter
    (lambda (event)
      (equal (consent-reflect--record-head-name event) "yield"))
    (consent--context-events context))))

(defun consent-reflect-recent-errors (context)
  "Return recent error records from CONTEXT and the audit log."
  (consent-reflect--redact
   (append
    (when (consent--eval-context-current-error context)
      (list (consent--eval-context-current-error context)))
    (seq-filter
     (lambda (entry)
       (consent-reflect--has-field-p entry "error"))
     (consent-audit-recent-entries)))))

(defun consent-reflect-recent-policy-decisions ()
  "Return recent policy-decision audit entries."
  (consent-reflect--redact
   (seq-filter
    (lambda (entry)
      (consent-reflect--event-named-p entry "policy-decision"))
    (consent-audit-recent-entries))))

(defun consent-reflect--primitive-current-capabilities (_arguments _context)
  "Primitive `current-capabilities'."
  (consent-reflect--redact
   (consent-reflect-current-capabilities)))

(defun consent-reflect--primitive-consent-version (_arguments _context)
  "Primitive `consent-version'."
  (consent-version))

(defun consent-reflect--primitive-current-policy (_arguments context)
  "Primitive `current-policy'."
  (consent-reflect--redact
   (consent-reflect-current-policy context)))

(defun consent-reflect--primitive-current-budget (_arguments context)
  "Primitive `current-budget'."
  (consent-reflect--redact
   (consent-reflect-current-budget context)))

(defun consent-reflect--primitive-budget-remaining (_arguments context)
  "Primitive `budget-remaining'."
  (consent-reflect--redact
   (consent-reflect-budget-remaining context)))

(defun consent-reflect--primitive-budget-exhausted-p (arguments _context)
  "Primitive `budget-exhausted?'."
  (consent-reflect--boolean
   (consent--budget-exhausted-condition-p (car arguments))))

(defun consent-reflect--primitive-budget-yield (_arguments context)
  "Primitive `budget-yield': emit the current ledger as a yield event."
  (let ((ledger (consent-reflect-current-budget context)))
    (consent--record-event! context (list (consent--syntax-symbol "yield")
                                          ledger))
    (consent-reflect--redact ledger)))

(defun consent-reflect--primitive-current-imports (_arguments context)
  "Primitive `current-imports'."
  (consent-reflect--redact
   (consent-reflect-current-imports context)))

(defun consent-reflect--primitive-library-bindings (arguments context)
  "Primitive `library-bindings'."
  (consent-reflect--redact
   (consent-reflect-library-bindings (car arguments) context)))

(defun consent-reflect--primitive-current-session-info (_arguments context)
  "Primitive `current-session-info'."
  (consent-reflect--redact
   (consent-reflect-current-session-info context)))

(defun consent-reflect--primitive-recent-yields (_arguments context)
  "Primitive `recent-yields'."
  (consent-reflect-recent-yields context))

(defun consent-reflect--primitive-recent-errors (_arguments context)
  "Primitive `recent-errors'."
  (consent-reflect-recent-errors context))

(defun consent-reflect--primitive-recent-policy-decisions
    (_arguments _context)
  "Primitive `recent-policy-decisions'."
  (consent-reflect-recent-policy-decisions))

(defun consent-reflect--primitive-capability-info (arguments _context)
  "Primitive `capability-info'."
  (consent-reflect--redact
   (consent-reflect-capability-info (car arguments))))

(defun consent-reflect--primitive-documentation (arguments context)
  "Primitive `documentation'."
  (consent-reflect--redact
   (consent-reflect-documentation (car arguments) context)))

(defun consent-reflect--macro-options (arguments)
  "Return optional macro introspection options from ARGUMENTS."
  (and (cdr arguments) (cadr arguments)))

(defun consent-reflect--primitive-macroexpand (arguments context)
  "Primitive `macroexpand'."
  (consent-macroexpand
   (car arguments)
   (consent--eval-context-interaction-environment context)
   (consent-reflect--macro-options arguments)
   context))

(defun consent-reflect--primitive-macroexpand-1 (arguments context)
  "Primitive `macroexpand-1'."
  (consent-macroexpand-1
   (car arguments)
   (consent--eval-context-interaction-environment context)
   (consent-reflect--macro-options arguments)
   context))

(defun consent-reflect--primitive-macroexpand-library (arguments context)
  "Primitive `macroexpand-library'."
  (consent-macroexpand-library
   (car arguments)
   (consent--eval-context-interaction-environment context)
   (consent-reflect--macro-options arguments)
   context))

(defun consent-reflect--primitive-macro-binding-info (arguments context)
  "Primitive `macro-binding-info'."
  (consent-macro-binding-info
   (car arguments)
   (consent--eval-context-interaction-environment context)
   context))

(defun consent-reflect--primitive-syntax-source (arguments _context)
  "Primitive `syntax-source'."
  (consent-syntax-source (car arguments)))

(defun consent-reflect--primitive-macroexpand-yield
    (arguments context)
  "Primitive `macroexpand-yield'."
  (let ((result
         (consent-macroexpand
          (car arguments)
          (consent--eval-context-interaction-environment context)
          (cadr arguments)
          context)))
    (consent--record-event!
     context
     (list (consent-reflect--symbol "macroexpand") result))
    result))

;;;###autoload
(defun consent-reflect-primitive-specs ()
  "Return primitive specs for the `(agent reflect)' library."
  `(("consent-version"
     ,#'consent-reflect--primitive-consent-version 0 0)
    ("current-capabilities"
     ,#'consent-reflect--primitive-current-capabilities 0 0)
    ("current-policy"
     ,#'consent-reflect--primitive-current-policy 0 0)
    ("current-budget"
     ,#'consent-reflect--primitive-current-budget 0 0)
    ("budget-remaining"
     ,#'consent-reflect--primitive-budget-remaining 0 0)
    ("budget-exhausted?"
     ,#'consent-reflect--primitive-budget-exhausted-p 1 1)
    ("budget-yield"
     ,#'consent-reflect--primitive-budget-yield 0 0)
    ("current-imports"
     ,#'consent-reflect--primitive-current-imports 0 0)
    ("library-bindings"
     ,#'consent-reflect--primitive-library-bindings 1 1)
    ("current-session-info"
     ,#'consent-reflect--primitive-current-session-info 0 0)
    ("recent-yields"
     ,#'consent-reflect--primitive-recent-yields 0 0)
    ("recent-errors"
     ,#'consent-reflect--primitive-recent-errors 0 0)
    ("recent-policy-decisions"
     ,#'consent-reflect--primitive-recent-policy-decisions 0 0)
    ("capability-info"
     ,#'consent-reflect--primitive-capability-info 1 1)
    ("documentation"
     ,#'consent-reflect--primitive-documentation 1 1)
    ("macroexpand"
     ,#'consent-reflect--primitive-macroexpand 1 2)
    ("macroexpand-1"
     ,#'consent-reflect--primitive-macroexpand-1 1 2)
    ("macroexpand-library"
     ,#'consent-reflect--primitive-macroexpand-library 1 2)
    ("macro-binding-info"
     ,#'consent-reflect--primitive-macro-binding-info 1 1)
    ("syntax-source"
     ,#'consent-reflect--primitive-syntax-source 1 1)
    ("macroexpand-yield"
     ,#'consent-reflect--primitive-macroexpand-yield 2 2)))

(provide 'consent-reflect)

;;; consent-reflect.el ends here
