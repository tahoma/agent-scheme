;;; agent-scheme-reflect.el --- Runtime reflection primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `(agent reflect)' library exposes read-only runtime snapshots as
;; Scheme-readable datums.  It reports public context, manifest, event, and
;; audit metadata without returning raw host objects, provider credentials, or
;; implementation hooks.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-base)
(require 'agent-scheme-capability)
(require 'agent-scheme-policy)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-runtime)

(defconst agent-scheme-reflect--omitted-manifest-fields
  '(:emacs-hook :portable-hook :emitter-hook :test-categories)
  "Primitive manifest fields not exposed through runtime reflection.")

(defun agent-scheme-reflect--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((keywordp name)
     (substring (symbol-name name) 1))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-reflect--boolean (value)
  "Return VALUE as a canonical Scheme boolean."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme-reflect--integer (value)
  "Return host integer VALUE as an exact Scheme integer datum."
  (agent-scheme--make-canonical-integer value))

(defun agent-scheme-reflect--field (name value)
  "Return a Scheme-readable reflection field."
  (list (agent-scheme-reflect--symbol name) value))

(defun agent-scheme-reflect--datumize (value)
  "Return VALUE as a Scheme-readable datum for reflection."
  (cond
   ((or (eq value agent-scheme-true)
        (eq value agent-scheme-false)
        (agent-scheme-symbol-p value)
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-bytevector-p value)
        (agent-scheme-record-p value)
        (agent-scheme-record-type-p value)
        (agent-scheme-handle-p value))
    value)
   ((eq value t)
    agent-scheme-true)
   ((null value)
    nil)
   ((symbolp value)
    (agent-scheme-reflect--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (agent-scheme-reflect--integer value))
   ((consp value)
    (cons (agent-scheme-reflect--datumize (car value))
          (agent-scheme-reflect--datumize (cdr value))))
   ((vectorp value)
    (vconcat (mapcar #'agent-scheme-reflect--datumize (append value nil))))
   (t
    "#<host-object>")))

(defun agent-scheme-reflect--optional-datumize (value)
  "Return VALUE as a datum, using #f for absent optional fields."
  (if (null value)
      agent-scheme-false
    (agent-scheme-reflect--datumize value)))

(defun agent-scheme-reflect--library-datum (key)
  "Return library KEY as a Scheme-readable library-name datum."
  (if (stringp key)
      (condition-case _
          (agent-scheme-read key)
        (error key))
    (agent-scheme-reflect--datumize key)))

(defun agent-scheme-reflect--manifest-specs ()
  "Return host-capability primitive manifest specs."
  (seq-filter
   (lambda (spec)
     (eq (plist-get spec :source) 'host-capability))
   (agent-scheme-primitive-manifest-binding-specs)))

(defun agent-scheme-reflect--manifest-spec-field (spec key default)
  "Return SPEC property KEY, using DEFAULT when absent."
  (if (plist-member spec key)
      (plist-get spec key)
    default))

(defun agent-scheme-reflect--manifest-record (spec)
  "Return SPEC as a public `host-capability' reflection record."
  (let* ((name (plist-get spec :name))
         (library (plist-get spec :library))
         (fields
          `((library . ,(agent-scheme-reflect--library-datum library))
            (name . ,(agent-scheme-reflect--symbol name))
            (minimum-arity
             . ,(agent-scheme-reflect--datumize
                 (plist-get spec :minimum-arity)))
            (maximum-arity
             . ,(agent-scheme-reflect--optional-datumize
                 (plist-get spec :maximum-arity)))
            (source . ,(agent-scheme-reflect--datumize
                        (plist-get spec :source)))
            (effect . ,(agent-scheme-reflect--datumize
                        (plist-get spec :effect)))
            (required-capability
             . ,(agent-scheme-reflect--optional-datumize
                 (agent-scheme-reflect--manifest-spec-field
                  spec :required-capability nil)))
            (backend-effect-path
             . ,(agent-scheme-reflect--optional-datumize
                 (agent-scheme-reflect--manifest-spec-field
                  spec :backend-effect-path nil)))
            (policy-category
             . ,(agent-scheme-reflect--optional-datumize
                 (agent-scheme-reflect--manifest-spec-field
                  spec :policy-category nil)))
            (policy . ,(agent-scheme-reflect--optional-datumize
                        (agent-scheme-reflect--manifest-spec-field
                         spec :policy nil)))
            (requires-grant
             . ,(agent-scheme-reflect--boolean
                 (agent-scheme-reflect--manifest-spec-field
                  spec :requires-grant nil))))))
    (cons (agent-scheme-reflect--symbol "host-capability")
          (mapcar (lambda (field)
                    (agent-scheme-reflect--field (car field) (cdr field)))
                  fields))))

(defun agent-scheme-reflect-current-capabilities ()
  "Return all known host capability metadata records."
  (mapcar #'agent-scheme-reflect--manifest-record
          (agent-scheme-reflect--manifest-specs)))

(defun agent-scheme-reflect--capability-name (symbol-or-name)
  "Return SYMBOL-OR-NAME as a capability name string."
  (cond
   ((agent-scheme-symbol-p symbol-or-name)
    (agent-scheme-symbol-name symbol-or-name))
   ((symbolp symbol-or-name)
    (symbol-name symbol-or-name))
   ((stringp symbol-or-name)
    symbol-or-name)
   (t
    (agent-scheme--eval-error
     "capability-info expects a symbol or string"))))

(defun agent-scheme-reflect-capability-info (symbol-or-name)
  "Return metadata for SYMBOL-OR-NAME, or #f when absent."
  (let* ((name (agent-scheme-reflect--capability-name symbol-or-name))
         (spec (seq-find
                (lambda (candidate)
                  (equal (plist-get candidate :name) name))
                (agent-scheme-reflect--manifest-specs))))
    (if spec
        (agent-scheme-reflect--manifest-record spec)
      agent-scheme-false)))

(defun agent-scheme-reflect-current-budget (context)
  "Return the active budget counters and limits for CONTEXT."
  (list
   (agent-scheme-reflect--symbol "budget")
   (agent-scheme-reflect--field
    "steps-used"
    (agent-scheme-reflect--integer
     (agent-scheme--eval-context-steps context)))
   (agent-scheme-reflect--field
    "max-steps"
    (agent-scheme-reflect--datumize
     (agent-scheme--eval-context-maximum-steps context)))
   (agent-scheme-reflect--field
    "host-calls"
    (agent-scheme-reflect--integer
     (agent-scheme--eval-context-host-callbacks context)))
   (agent-scheme-reflect--field
    "max-host-calls"
    (agent-scheme-reflect--datumize
     (agent-scheme--eval-context-maximum-host-callbacks context)))
   (agent-scheme-reflect--field
    "events-used"
    (agent-scheme-reflect--integer
     (agent-scheme--eval-context-event-count context)))
   (agent-scheme-reflect--field
    "max-events"
    (agent-scheme-reflect--datumize
     (agent-scheme--eval-context-maximum-events context)))
   (agent-scheme-reflect--field
    "max-event-nodes"
    (agent-scheme-reflect--datumize
     (agent-scheme--eval-context-maximum-event-nodes context)))
   (agent-scheme-reflect--field
    "max-value-nodes"
    (agent-scheme-reflect--datumize
     (agent-scheme--eval-context-maximum-value-nodes context)))))

(defun agent-scheme-reflect--policy-action-datum (category context)
  "Return CATEGORY's effective policy action in CONTEXT."
  (list (agent-scheme-reflect--symbol category)
        (agent-scheme-reflect--symbol
         (agent-scheme-policy-action-for-category category context))))

(defun agent-scheme-reflect-current-policy (context)
  "Return the active policy category table for CONTEXT."
  (let ((overrides
         (mapcar
          (lambda (entry)
            (list (agent-scheme-reflect--symbol (car entry))
                  (agent-scheme-reflect--datumize (cdr entry))))
          (agent-scheme--eval-context-policy-actions context))))
    (list
     (agent-scheme-reflect--symbol "policy")
     (agent-scheme-reflect--field
      "categories"
      (mapcar
       (lambda (category)
         (agent-scheme-reflect--policy-action-datum category context))
       agent-scheme-policy-categories))
     (agent-scheme-reflect--field "overrides" overrides)
     (agent-scheme-reflect--field
      "confirmation"
      (agent-scheme-reflect--boolean
       (agent-scheme--eval-context-policy-confirmation-function context))))))

(defun agent-scheme-reflect-current-imports (context)
  "Return registered library names for CONTEXT."
  (let (keys)
    (maphash
     (lambda (key _library)
       (push key keys))
     (agent-scheme--eval-context-libraries context))
    (mapcar #'agent-scheme-reflect--library-datum
            (sort keys #'string<))))

(defun agent-scheme-reflect-current-session-info (context)
  "Return public session/job identity for CONTEXT."
  (list
   (agent-scheme-reflect--symbol "session-info")
   (agent-scheme-reflect--field
    "id"
    (if (agent-scheme--eval-context-session-id context)
        (agent-scheme-reflect--symbol
         (agent-scheme--eval-context-session-id context))
      agent-scheme-false))
   (agent-scheme-reflect--field
    "job"
    (if (agent-scheme--eval-context-job-id context)
        (agent-scheme-reflect--symbol
         (agent-scheme--eval-context-job-id context))
      agent-scheme-false))
   (agent-scheme-reflect--field
    "events-used"
    (agent-scheme-reflect--integer
     (agent-scheme--eval-context-event-count context)))))

(defun agent-scheme-reflect--record-head-name (datum)
  "Return DATUM record head as a string, or nil."
  (cond
   ((and (consp datum) (agent-scheme-symbol-p (car datum)))
    (agent-scheme-symbol-name (car datum)))
   ((and (consp datum) (symbolp (car datum)))
    (symbol-name (car datum)))
   (t nil)))

(defun agent-scheme-reflect--field-value (datum name)
  "Return field NAME's value from Scheme-readable DATUM."
  (let ((field
         (seq-find
          (lambda (candidate)
            (and (consp candidate)
                 (agent-scheme-symbol-p (car candidate))
                 (equal (agent-scheme-symbol-name (car candidate)) name)))
          (cdr-safe datum))))
    (and field (cadr field))))

(defun agent-scheme-reflect--event-named-p (entry name)
  "Return non-nil when audit ENTRY has event NAME."
  (let ((event (agent-scheme-reflect--field-value entry "event")))
    (and (agent-scheme-symbol-p event)
         (equal (agent-scheme-symbol-name event) name))))

(defun agent-scheme-reflect--has-field-p (entry name)
  "Return non-nil when ENTRY contains field NAME."
  (seq-some
   (lambda (candidate)
     (and (consp candidate)
          (agent-scheme-symbol-p (car candidate))
          (equal (agent-scheme-symbol-name (car candidate)) name)))
   (cdr-safe entry)))

(defun agent-scheme-reflect--redact (datum)
  "Redact DATUM at the reflection disclosure boundary."
  (agent-scheme-redact datum 'runtime-reflection))

(defun agent-scheme-reflect-recent-yields (context)
  "Return recent yield events from CONTEXT in emission order."
  (agent-scheme-reflect--redact
   (seq-filter
    (lambda (event)
      (equal (agent-scheme-reflect--record-head-name event) "yield"))
    (agent-scheme--context-events context))))

(defun agent-scheme-reflect-recent-errors (context)
  "Return recent error records from CONTEXT and the audit log."
  (agent-scheme-reflect--redact
   (append
    (when (agent-scheme--eval-context-current-error context)
      (list (agent-scheme--eval-context-current-error context)))
    (seq-filter
     (lambda (entry)
       (agent-scheme-reflect--has-field-p entry "error"))
     (agent-scheme-audit-recent-entries)))))

(defun agent-scheme-reflect-recent-policy-decisions ()
  "Return recent policy-decision audit entries."
  (agent-scheme-reflect--redact
   (seq-filter
    (lambda (entry)
      (agent-scheme-reflect--event-named-p entry "policy-decision"))
    (agent-scheme-audit-recent-entries))))

(defun agent-scheme-reflect--primitive-current-capabilities (_arguments _context)
  "Primitive `current-capabilities'."
  (agent-scheme-reflect--redact
   (agent-scheme-reflect-current-capabilities)))

(defun agent-scheme-reflect--primitive-agent-scheme-version (_arguments _context)
  "Primitive `agent-scheme-version'."
  (agent-scheme-version))

(defun agent-scheme-reflect--primitive-current-policy (_arguments context)
  "Primitive `current-policy'."
  (agent-scheme-reflect--redact
   (agent-scheme-reflect-current-policy context)))

(defun agent-scheme-reflect--primitive-current-budget (_arguments context)
  "Primitive `current-budget'."
  (agent-scheme-reflect--redact
   (agent-scheme-reflect-current-budget context)))

(defun agent-scheme-reflect--primitive-current-imports (_arguments context)
  "Primitive `current-imports'."
  (agent-scheme-reflect--redact
   (agent-scheme-reflect-current-imports context)))

(defun agent-scheme-reflect--primitive-current-session-info (_arguments context)
  "Primitive `current-session-info'."
  (agent-scheme-reflect--redact
   (agent-scheme-reflect-current-session-info context)))

(defun agent-scheme-reflect--primitive-recent-yields (_arguments context)
  "Primitive `recent-yields'."
  (agent-scheme-reflect-recent-yields context))

(defun agent-scheme-reflect--primitive-recent-errors (_arguments context)
  "Primitive `recent-errors'."
  (agent-scheme-reflect-recent-errors context))

(defun agent-scheme-reflect--primitive-recent-policy-decisions
    (_arguments _context)
  "Primitive `recent-policy-decisions'."
  (agent-scheme-reflect-recent-policy-decisions))

(defun agent-scheme-reflect--primitive-capability-info (arguments _context)
  "Primitive `capability-info'."
  (agent-scheme-reflect--redact
   (agent-scheme-reflect-capability-info (car arguments))))

;;;###autoload
(defun agent-scheme-reflect-primitive-specs ()
  "Return primitive specs for the `(agent reflect)' library."
  `(("agent-scheme-version"
     ,#'agent-scheme-reflect--primitive-agent-scheme-version 0 0)
    ("current-capabilities"
     ,#'agent-scheme-reflect--primitive-current-capabilities 0 0)
    ("current-policy"
     ,#'agent-scheme-reflect--primitive-current-policy 0 0)
    ("current-budget"
     ,#'agent-scheme-reflect--primitive-current-budget 0 0)
    ("current-imports"
     ,#'agent-scheme-reflect--primitive-current-imports 0 0)
    ("current-session-info"
     ,#'agent-scheme-reflect--primitive-current-session-info 0 0)
    ("recent-yields"
     ,#'agent-scheme-reflect--primitive-recent-yields 0 0)
    ("recent-errors"
     ,#'agent-scheme-reflect--primitive-recent-errors 0 0)
    ("recent-policy-decisions"
     ,#'agent-scheme-reflect--primitive-recent-policy-decisions 0 0)
    ("capability-info"
     ,#'agent-scheme-reflect--primitive-capability-info 1 1)))

(provide 'agent-scheme-reflect)

;;; agent-scheme-reflect.el ends here
