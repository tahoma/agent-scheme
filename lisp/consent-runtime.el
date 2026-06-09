;;; consent-runtime.el --- R7RS runtime values and context  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Runtime records and per-run context state shared by Consent Scheme frontend
;; passes and interpreter backends.  This module owns value shapes, lexical and
;; syntactic environment frame records, evaluation budget defaults, and context
;; construction; it does not evaluate Scheme expressions.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)

(defcustom consent-eval-maximum-steps 100000
  "Maximum evaluator steps allowed in one `consent-eval' run."
  :type 'integer
  :group 'consent)

(defcustom consent-eval-maximum-value-nodes 100000
  "Maximum returned or allocated value nodes allowed during evaluation."
  :type 'integer
  :group 'consent)

(defcustom consent-eval-maximum-host-callbacks 10000
  "Maximum registered primitive callbacks allowed during evaluation."
  :type 'integer
  :group 'consent)

(defcustom consent-eval-maximum-events 1000
  "Maximum Consent Scheme event records allowed in one evaluation."
  :type 'integer
  :group 'consent)

(defcustom consent-eval-maximum-event-nodes 100000
  "Maximum reachable value nodes allowed in one Consent Scheme event record."
  :type 'integer
  :group 'consent)

(defconst consent--version-source-file
  (expand-file-name
   "../scheme/consent/version.sld"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Canonical Scheme-readable Consent Scheme version source file.")

(defun consent--version-symbol-named-p (value name)
  "Return non-nil when VALUE is an Consent Scheme symbol named NAME."
  (and (consent-symbol-p value)
       (equal (consent-symbol-name value) name)))

(defun consent--version-definition-value (form)
  "Return the quoted version datum from version source FORM."
  (let ((parts (and (consp form) form)))
    (when (and (= (length parts) 3)
               (consent--version-symbol-named-p (car parts) "define")
               (consent--version-symbol-named-p
                (cadr parts) "consent-version-datum"))
      (let ((value-form (caddr parts)))
        (when (and (consp value-form)
                   (= (length value-form) 2)
                   (consent--version-symbol-named-p
                    (car value-form) "quote"))
          (cadr value-form))))))

(defun consent--version-find-definition-value (form)
  "Return the quoted version datum found anywhere under FORM."
  (or (consent--version-definition-value form)
      (when (consp form)
        (catch 'found
          (dolist (element form)
            (let ((datum (consent--version-find-definition-value element)))
              (when datum
                (throw 'found datum))))))))

(defun consent--read-version-datum ()
  "Read and validate the canonical Consent Scheme version datum."
  (let* ((forms (consent-read-all
                 (with-temp-buffer
                   (insert-file-contents consent--version-source-file)
                   (buffer-string))))
         (datum (and (= (length forms) 1)
                     (consent--version-find-definition-value
                      (car forms)))))
    (unless (and (consp datum)
                 (= (length datum) 4)
                 (consent--version-symbol-named-p
                  (car datum) "consent-version")
                 (cl-every
                  (lambda (component)
                    (and (consent-number-p component)
                         (eq (consent-number-kind component) 'integer)
                         (eq (consent-number-exactness component) 'exact)
                         (>= (consent-number-value component) 0)))
                  (cdr datum)))
      (error "Invalid Consent Scheme version source: %s"
             consent--version-source-file))
    datum))

(defconst consent--version-datum
  (consent--read-version-datum)
  "Canonical Consent Scheme version datum.")

(defun consent-version-components ()
  "Return the Consent Scheme version as exact non-negative host integers."
  (mapcar #'consent-number-value (cdr consent--version-datum)))

(defun consent-version ()
  "Return the canonical Scheme-readable Consent Scheme version datum."
  (copy-tree consent--version-datum))

(defun consent-version-string ()
  "Return the Consent Scheme version as a derived presentation string."
  (mapconcat #'number-to-string (consent-version-components) "."))

(define-error 'consent-eval-error
  "Consent Scheme evaluation error")

(define-error 'consent-budget-error
  "Consent Scheme evaluation budget exceeded"
  'consent-eval-error)

(define-error 'consent-cancelled-error
  "Consent Scheme evaluation cancelled"
  'consent-eval-error)

(define-error 'consent-interrupt-error
  "Consent Scheme evaluation interrupted"
  'consent-eval-error)

(cl-defstruct (consent-unspecified
               (:constructor consent--make-unspecified)
               (:copier nil))
  "Scheme unspecified value.")

(defconst consent-unspecified
  (consent--make-unspecified)
  "Canonical Consent Scheme unspecified value.")

(cl-defstruct (consent--undefined
               (:constructor consent--make-undefined)
               (:copier nil))
  "Internal marker for uninitialized definition locations.")

(defconst consent--undefined
  (consent--make-undefined)
  "Internal uninitialized binding marker.")

(cl-defstruct (consent--cell
               (:constructor consent--make-cell (value))
               (:copier nil))
  "Mutable location for one Scheme binding."
  value)

(cl-defstruct (consent--environment
               (:constructor consent--make-environment
                             (bindings parent imported-bindings))
               (:copier nil))
  "Explicit lexical environment frame.
BINDINGS maps lexical keys to cells.  IMPORTED-BINDINGS records
current-frame names that cannot be redefined or mutated by Scheme
code."
  bindings parent imported-bindings)

(cl-defstruct (consent--syntax-environment
               (:constructor consent--make-syntax-environment
                             (bindings parent imported-bindings))
               (:copier nil))
  "Explicit syntactic environment frame."
  bindings parent imported-bindings)

(cl-defstruct (consent--syntax-context
               (:constructor consent--make-syntax-context
                             (id value-environment syntax-environment))
               (:copier nil))
  "Hygienic context attached to macro-introduced identifiers.
VALUE-ENVIRONMENT and SYNTAX-ENVIRONMENT are the transformer's
definition environments; free identifiers introduced by the
template resolve there instead of at the macro use site."
  id value-environment syntax-environment)

(cl-defstruct (consent--identifier
               (:constructor consent--make-identifier (name context))
               (:copier nil))
  "Macro-expanded identifier with hygienic context."
  name context)

(cl-defstruct (consent--formals
               (:constructor consent--make-formals
                             (required rest))
               (:copier nil))
  "Parsed lambda formal parameters."
  required rest)

(cl-defstruct (consent-procedure
               (:constructor consent--make-procedure
                             (formals body environment documentation))
               (:copier nil))
  "Scheme procedure value."
  formals body environment documentation)

(cl-defstruct (consent-primitive-procedure
               (:constructor consent--make-primitive-procedure
                             (name function minimum-arity maximum-arity))
               (:copier nil))
  "Registered primitive procedure value."
  name function minimum-arity maximum-arity)

(cl-defstruct (consent-parameter
               (:constructor consent--make-parameter (value converter))
               (:copier nil))
  "R7RS parameter object.
VALUE is the current value.  CONVERTER is nil or a Scheme procedure applied to
new values before they are installed."
  value converter)

(cl-defstruct (consent--multiple-values
               (:constructor consent--make-multiple-values (values))
               (:copier nil))
  "A Scheme multiple-values payload."
  values)

(cl-defstruct (consent--continuation
               (:constructor consent--make-continuation
                             (procedure dynamic-winds exception-handlers
                              current-error))
               (:copier nil))
  "A re-enterable continuation captured by call/cc.
PROCEDURE is the evaluator continuation to receive a value, and
DYNAMIC-WINDS, EXCEPTION-HANDLERS, and CURRENT-ERROR are the dynamic state
active at capture time."
  procedure dynamic-winds exception-handlers current-error)

(cl-defstruct (consent--dynamic-wind-frame
               (:constructor consent--make-dynamic-wind-frame
                             (before after))
               (:copier nil))
  "One active dynamic-wind frame."
  before after)

(cl-defstruct (consent-error-object
               (:constructor consent--make-error-object
                             (message irritants))
               (:copier nil))
  "R7RS error object created by the `error' procedure."
  message irritants)

(cl-defstruct (consent-eof-object
               (:constructor consent--make-eof-object)
               (:copier nil))
  "R7RS end-of-file object.")

(defconst consent-eof-object
  (consent--make-eof-object)
  "Canonical Consent Scheme end-of-file object.")

(cl-defstruct (consent--port
               (:constructor consent--make-port)
               (:copier nil))
  "Consent Scheme port.
MEDIUM separates string, bytevector, host-file, and virtual ports.
INPUTP and OUTPUTP record direction; TEXTUALP and BINARYP record
the datum layer; OPENP tracks whether operations are still valid.
SOURCE and POSITION back input ports, while CONTENTS backs output
ports.  Host-backed ports additionally carry BACKING-DOMAIN,
OPERATIONS, GRANT, LIMITS, HANDLE, STATUS, and PATH as printable
capability metadata; raw host objects stay outside Scheme values."
  medium inputp outputp textualp binaryp (openp t) source (position 0) contents
  backing-domain operations grant limits handle status path counters)

(cl-defstruct (consent--environment-specifier
               (:constructor consent--make-environment-specifier
                             (environment syntax-environment immutable))
               (:copier nil))
  "Specifier accepted by the R7RS `(scheme eval)' and `(scheme load)' APIs."
  environment syntax-environment immutable)

(cl-defstruct (consent--string-output-port
               (:constructor consent--make-string-output-port
                             (contents))
               (:copier nil))
  "In-memory textual output port used by `(scheme write)'."
  contents)

(cl-defstruct (consent--sequence
               (:constructor consent--make-sequence
                             (forms allow-definitions))
               (:copier nil))
  "Internal sequence expression."
  forms allow-definitions)

(cl-defstruct (consent--bounce
               (:constructor consent--make-bounce
                             (expression environment &optional
                                         syntax-environment continuation))
               (:copier nil))
  "Trampoline state for evaluating EXPRESSION in ENVIRONMENT."
  expression environment syntax-environment continuation)

(cl-defstruct (consent--eval-context
               (:constructor consent--make-eval-context)
               (:copier nil))
  "Mutable state shared by one expansion or evaluation run.
The context owns resource counters, the active syntax environment,
the per-run library registry, include policy, and whether the
base syntax prelude has already been installed."
  steps
  maximum-steps
  maximum-value-nodes
  host-callbacks
  maximum-host-callbacks
  events
  event-count
  maximum-events
  maximum-event-nodes
  event-hook
  syntax-environment
  libraries
  include-paths
  include-directory
  file-paths
  policy-actions
  policy-confirmation-function
  capability-grants
  active-capability-grants
  current-input-port
  current-output-port
  current-error-port
  current-error
  session-id
  request-id
  request
  focus
  region-context
  buffer-context
  project-context
  conversation-summary
  job-id
  cancel-requested
  interrupt-reason
  interaction-environment
  base-syntax-installed
  exception-handlers
  dynamic-winds
  docstring-retention)

(defconst consent--missing-cell (make-symbol "consent-missing-cell")
  "Sentinel used when looking up environment cells.")

(defun consent--eval-option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun consent--eval-error (message &rest args)
  "Signal an Consent Scheme evaluation error.
MESSAGE and ARGS are passed to `format'."
  (signal 'consent-eval-error (list (apply #'format message args))))

(defun consent--budget-error (message &rest args)
  "Signal an Consent Scheme budget error.
MESSAGE and ARGS are passed to `format'."
  (signal 'consent-budget-error (list (apply #'format message args))))

(defun consent--normalize-include-paths (paths directory)
  "Return policy PATHS expanded relative to DIRECTORY."
  (when paths
    (unless (listp paths)
      (consent--eval-error
       ":include-paths must be a list of file or directory paths"))
    (mapcar
     (lambda (path)
       (unless (stringp path)
         (consent--eval-error
          ":include-paths entries must be strings"))
       (expand-file-name path directory))
     paths)))

(defun consent--normalize-docstring-retention (value)
  "Return normalized docstring retention mode for VALUE."
  (cond
   ((eq value t) 'full)
   ((null value) 'none)
   ((memq value '(full simple none)) value)
   (t
    (consent--eval-error
     ":docstring-retention must be `full', `simple', `none', or nil"))))

(defun consent--eval-context-docstring-retention-mode (context)
  "Return CONTEXT docstring retention, defaulting old contexts to `full'."
  (let ((value
         (and context
              (condition-case nil
                  (consent--eval-context-docstring-retention context)
                (args-out-of-range nil)))))
    (if value
        (consent--normalize-docstring-retention value)
      'full)))

(defun consent--new-eval-context (options)
  "Return an evaluator context using OPTIONS."
  (let ((maximum-steps
         (cond
          ((plist-member options :max-steps)
           (plist-get options :max-steps))
          ((plist-member options :max-non-tail-steps)
           (plist-get options :max-non-tail-steps))
          (t consent-eval-maximum-steps)))
        (include-directory
         (file-name-as-directory
          (expand-file-name
           (consent--eval-option
            options :include-directory default-directory)))))
    (consent--make-eval-context
     :steps 0
     :maximum-steps maximum-steps
     :maximum-value-nodes
     (consent--eval-option options :max-value-nodes
                                consent-eval-maximum-value-nodes)
     :host-callbacks 0
     :maximum-host-callbacks
     (consent--eval-option options :max-host-callbacks
                                consent-eval-maximum-host-callbacks)
     :events nil
     :event-count 0
     :maximum-events
     (consent--eval-option options :max-events
                                consent-eval-maximum-events)
     :maximum-event-nodes
     (consent--eval-option options :max-event-nodes
                                consent-eval-maximum-event-nodes)
     :event-hook nil
     :syntax-environment
     (consent--make-syntax-environment
      (make-hash-table :test #'equal) nil
      (make-hash-table :test #'equal))
     :libraries (make-hash-table :test #'equal)
     :include-paths
     (consent--normalize-include-paths
      (consent--eval-option options :include-paths nil)
      include-directory)
     :include-directory include-directory
     :file-paths
     (consent--normalize-include-paths
      (consent--eval-option options :file-paths nil)
      include-directory)
     :docstring-retention
     (consent--normalize-docstring-retention
      (consent--eval-option options :docstring-retention 'full))
     :policy-actions
     (consent--eval-option options :policy-actions nil)
     :policy-confirmation-function
     (consent--eval-option options :policy-confirmation-function nil)
     :capability-grants
     (consent--eval-option options :capability-grants nil)
     :active-capability-grants nil
     :current-error nil
     :session-id
     (consent--eval-option options :session-id nil)
     :request-id
     (consent--eval-option options :request-id nil)
     :request
     (consent--eval-option options :request nil)
     :focus
     (consent--eval-option options :focus nil)
     :region-context
     (consent--eval-option options :region-context nil)
     :buffer-context
     (consent--eval-option options :buffer-context nil)
     :project-context
     (consent--eval-option options :project-context nil)
     :conversation-summary
     (consent--eval-option options :conversation-summary nil)
     :job-id nil
     :cancel-requested nil
     :interrupt-reason nil
     :base-syntax-installed nil
     :exception-handlers nil
     :dynamic-winds nil)))

(defun consent--apply-current-context-options! (context options)
  "Apply current-context OPTIONS to CONTEXT and return CONTEXT."
  (when options
    (when (plist-member options :request-id)
      (setf (consent--eval-context-request-id context)
            (plist-get options :request-id)))
    (when (plist-member options :request)
      (setf (consent--eval-context-request context)
            (plist-get options :request)))
    (when (plist-member options :focus)
      (setf (consent--eval-context-focus context)
            (plist-get options :focus)))
    (when (plist-member options :region-context)
      (setf (consent--eval-context-region-context context)
            (plist-get options :region-context)))
    (when (plist-member options :buffer-context)
      (setf (consent--eval-context-buffer-context context)
            (plist-get options :buffer-context)))
    (when (plist-member options :project-context)
      (setf (consent--eval-context-project-context context)
            (plist-get options :project-context)))
    (when (plist-member options :conversation-summary)
      (setf (consent--eval-context-conversation-summary context)
            (plist-get options :conversation-summary)))
    (when (plist-member options :docstring-retention)
      (condition-case nil
          (setf (consent--eval-context-docstring-retention context)
                (consent--normalize-docstring-retention
                 (plist-get options :docstring-retention)))
        (args-out-of-range nil))))
  context)

(defun consent-make-empty-environment (&optional parent)
  "Return an empty lexical environment with optional PARENT."
  (consent--make-environment
   (make-hash-table :test #'equal)
   parent
   (make-hash-table :test #'equal)))

(defun consent--identifier-datum-p (datum)
  "Return non-nil if DATUM is a Scheme identifier."
  (or (consent-symbol-p datum)
      (consent--identifier-p datum)))

(defun consent--symbol-name (datum)
  "Return DATUM's Scheme identifier name, or nil."
  (cond
   ((consent-symbol-p datum)
    (consent-symbol-name datum))
   ((consent--identifier-p datum)
    (consent--identifier-name datum))
   (t nil)))

(defun consent--symbol-named-p (datum name)
  "Return non-nil if DATUM is a Scheme symbol named NAME."
  (equal (consent--symbol-name datum) name))

(defun consent--proper-list-elements (datum description)
  "Return proper list DATUM as an Emacs Lisp list.
Signal an evaluation error naming DESCRIPTION when DATUM is not a
proper list."
  (let ((cursor datum)
        elements)
    (while (consp cursor)
      (push (car cursor) elements)
      (setq cursor (cdr cursor)))
    (when cursor
      (consent--eval-error "%s must be a proper list" description))
    (nreverse elements)))

(defun consent--proper-list-elements-maybe (datum)
  "Return DATUM as a proper list of elements, or nil if improper."
  (let ((cursor datum)
        elements
        proper)
    (catch 'done
      (while t
        (cond
         ((null cursor)
          (setq proper t)
          (throw 'done nil))
         ((consp cursor)
          (push (car cursor) elements)
          (setq cursor (cdr cursor)))
         (t
          (throw 'done nil)))))
    (and proper (nreverse elements))))

(defun consent--expect-symbol-name (datum description)
  "Return DATUM's symbol name or signal an error naming DESCRIPTION."
  (or (consent--symbol-name datum)
      (consent--eval-error "%s must be an identifier" description)))

(defun consent--syntax-symbol (name)
  "Return Consent Scheme symbol datum for NAME."
  (consent--intern-symbol name))

(defconst consent--documentation-list-field-names
  '("examples" "see-also")
  "Documentation metadata fields whose list values append in source order.")

(defun consent--proper-list-p (datum)
  "Return non-nil when DATUM is a proper Scheme list."
  (let ((cursor datum)
        (proper nil))
    (catch 'done
      (while t
        (cond
         ((null cursor)
          (setq proper t)
          (throw 'done nil))
         ((consp cursor)
          (setq cursor (cdr cursor)))
         (t
          (throw 'done nil)))))
    proper))

(defun consent--documentation-metadata-object-p (value)
  "Return non-nil when VALUE is normalized documentation metadata."
  (and (listp value)
       (plist-get value :consent-documentation-metadata)))

(defun consent--make-documentation-metadata (fields origins)
  "Return normalized documentation metadata with FIELDS and ORIGINS."
  (list :consent-documentation-metadata t
        :fields fields
        :origins origins))

(defun consent--primitive-manifest-documentation (documentation)
  "Return normalized manifest documentation metadata for DOCUMENTATION."
  (consent--make-documentation-metadata
   (list (cons "documentation" documentation))
   '("primitive-manifest-string")))

(defun consent--primitive-manifest-documentation-properties (documentation)
  "Return an optional `:documentation' plist for DOCUMENTATION."
  (when documentation
    (list :documentation
          (consent--primitive-manifest-documentation documentation))))

(defun consent--documentation-metadata-fields (metadata)
  "Return normalized documentation field alist from METADATA."
  (cond
   ((stringp metadata)
    (list (cons "documentation" metadata)))
   ((consent--documentation-metadata-object-p metadata)
    (plist-get metadata :fields))
   (t nil)))

(defun consent--documentation-metadata-origins (metadata)
  "Return normalized documentation origin names from METADATA."
  (cond
   ((stringp metadata)
    '("string"))
   ((consent--documentation-metadata-object-p metadata)
    (plist-get metadata :origins))
   (t nil)))

(defun consent--documentation-add-origin (origins origin)
  "Return ORIGINS with ORIGIN appended once in source order."
  (if (member origin origins)
      origins
    (append origins (list origin))))

(defun consent--documentation-field (fields name)
  "Return the field entry named NAME from FIELDS."
  (assoc name fields))

(defun consent--documentation-set-field (fields name value)
  "Return FIELDS with NAME set to VALUE, preserving field order."
  (if (consent--documentation-field fields name)
      (mapcar
       (lambda (field)
         (if (equal (car field) name)
             (cons name value)
           field))
       fields)
    (append fields (list (cons name value)))))

(defun consent--documentation-add-field (fields name value)
  "Return FIELDS with NAME/VALUE appended."
  (append fields (list (cons name value))))

(defun consent--documentation-formals->datum (formals)
  "Return FORMALS as a Scheme-readable arguments datum."
  (let ((required
         (mapcar #'consent--syntax-symbol
                 (consent--formals-required formals)))
        (rest
         (and (consent--formals-rest formals)
              (consent--syntax-symbol
               (consent--formals-rest formals)))))
    (cond
     ((not rest)
      required)
     ((null required)
      rest)
     (t
      (let ((arguments (copy-sequence required)))
        (setcdr (last arguments) rest)
        arguments)))))

(defun consent--documentation-expect-identifier-key (datum description)
  "Return DATUM's lexical key for documentation metadata."
  (unless (consent--identifier-datum-p datum)
    (consent--eval-error "%s must be an identifier" description))
  (consent--identifier-key datum))

(defun consent--documentation-parse-formals (formals)
  "Parse raw lambda FORMALS for documentation metadata."
  (cond
   ((consent--identifier-datum-p formals)
    (consent--make-formals nil (consent--identifier-key formals)))
   (t
    (let ((cursor formals)
          required
          rest)
      (while (consp cursor)
        (push (consent--documentation-expect-identifier-key
               (car cursor) "lambda formal")
              required)
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor))
       ((consent--identifier-datum-p cursor)
        (setq rest (consent--identifier-key cursor)))
       (t
        (consent--eval-error
         "lambda formals must be an identifier, a proper list, or a dotted list")))
      (setq required (nreverse required))
      (consent--ensure-distinct-names
       (if rest (append required (list rest)) required)
       "lambda formals")
      (consent--make-formals required rest)))))

(defun consent--documentation-metadata-from-formals (formals)
  "Return generated documentation metadata for lambda FORMALS."
  (let ((arguments
         (consent--documentation-formals->datum
          (if (consent--formals-p formals)
              formals
            (consent--documentation-parse-formals formals)))))
    (consent--make-documentation-metadata
     (list (cons "arguments" arguments))
     nil)))

(defun consent--documentation-metadata-fields-present-p (metadata)
  "Return non-nil when METADATA contains at least one field."
  (and metadata
       (consent--documentation-metadata-fields metadata)))

(defun consent--documentation-parameter-names (parameters)
  "Return parameter names in PARAMETERS, or `:malformed' when malformed.
PARAMETERS is valid when it is a proper association list whose keys
are Scheme identifiers and whose keys do not repeat."
  (catch 'malformed
    (unless (consent--proper-list-p parameters)
      (throw 'malformed :malformed))
    (let (names)
      (dolist (entry (consent--proper-list-elements parameters
                                                         "parameters"))
        (unless (consp entry)
          (throw 'malformed :malformed))
        (let ((name (consent--symbol-name (car entry))))
          (unless name
            (throw 'malformed :malformed))
          (when (member name names)
            (throw 'malformed :malformed))
          (push name names)))
      (nreverse names))))

(defun consent--documentation-argument-names (arguments)
  "Return argument names in ARGUMENTS, or `:malformed' when malformed."
  (catch 'malformed
    (cond
     ((consent--identifier-datum-p arguments)
      (list (consent--identifier-key arguments)))
     (t
      (let ((cursor arguments)
            names)
        (while (consp cursor)
          (unless (consent--identifier-datum-p (car cursor))
            (throw 'malformed :malformed))
          (push (consent--identifier-key (car cursor)) names)
          (setq cursor (cdr cursor)))
        (cond
         ((null cursor)
          (nreverse names))
         ((consent--identifier-datum-p cursor)
          (nreverse (cons (consent--identifier-key cursor) names)))
         (t
          (throw 'malformed :malformed))))))))

(defun consent--documentation-parameters-match-arguments-p
    (fields names)
  "Return non-nil when parameter NAMES are present in FIELDS arguments."
  (let ((arguments (consent--documentation-field fields "arguments")))
    (if (not arguments)
        t
      (let ((argument-names
             (consent--documentation-argument-names (cdr arguments))))
        (and (not (eq argument-names :malformed))
             (cl-every (lambda (name) (member name argument-names))
                       names))))))

(defun consent--documentation-merge-parameters (fields value)
  "Return FIELDS merged with parameter metadata VALUE, or nil if malformed."
  (let ((new-names (consent--documentation-parameter-names value))
        (existing (consent--documentation-field fields "parameters")))
    (when (eq new-names :malformed)
      (setq fields nil))
    (when (and fields
               (not (consent--documentation-parameters-match-arguments-p
                     fields new-names)))
      (setq fields nil))
    (when fields
      (let ((existing-value (cdr existing))
            existing-names)
        (when existing
          (setq existing-names
                (consent--documentation-parameter-names existing-value))
          (when (eq existing-names :malformed)
            (setq fields nil)))
        (when fields
          (dolist (name new-names)
            (when (member name existing-names)
              (setq fields nil)))
          (when fields
            (if existing
                (consent--documentation-set-field
                 fields "parameters" (append existing-value value))
              (consent--documentation-add-field
               fields "parameters" value))))))))

(defun consent--documentation-merge-field (fields name value)
  "Return FIELDS merged with NAME/VALUE, or nil if malformed."
  (let ((existing (consent--documentation-field fields name)))
    (cond
     ((equal name "documentation")
      (if (not (stringp value))
          nil
        (if existing
            (if (stringp (cdr existing))
                (consent--documentation-set-field
                 fields name (concat (cdr existing) "\n" value))
              nil)
          (consent--documentation-add-field fields name value))))
     ((equal name "parameters")
      (consent--documentation-merge-parameters fields value))
     ((member name consent--documentation-list-field-names)
      (if (not (consent--proper-list-p value))
          nil
        (if existing
            (if (consent--proper-list-p (cdr existing))
                (consent--documentation-set-field
                 fields name (append (cdr existing) value))
              nil)
          (consent--documentation-add-field fields name value))))
     (existing
      nil)
     (t
      (consent--documentation-add-field fields name value)))))

(defun consent--documentation-merge-fields (fields new-fields)
  "Return FIELDS merged with NEW-FIELDS, or nil when malformed."
  (catch 'malformed
    (let ((merged fields))
      (dolist (field new-fields)
        (setq merged
              (consent--documentation-merge-field
               merged (car field) (cdr field)))
        (unless merged
          (throw 'malformed nil)))
      merged)))

(defun consent--documentation-rich-vector-fields (literal)
  "Return field alist for rich metadata LITERAL, or nil if malformed."
  (catch 'malformed
    (let (fields)
      (dotimes (index (length literal))
        (let* ((entry (aref literal index))
               (name (and (consp entry)
                          (consent--symbol-name (car entry)))))
          (unless name
            (throw 'malformed nil))
          (push (cons name (cdr entry)) fields)))
      (nreverse fields))))

(defun consent--documentation-merge-string-run (metadata strings)
  "Return METADATA merged with adjacent documentation STRINGS."
  (let* ((fields (plist-get metadata :fields))
         (origins (plist-get metadata :origins))
         (documentation (mapconcat #'identity strings "\n"))
         (merged-fields
          (consent--documentation-merge-field
           fields "documentation" documentation)))
    (and merged-fields
         (consent--make-documentation-metadata
          merged-fields
          (consent--documentation-add-origin origins "string")))))

(defun consent--documentation-merge-rich-vector (metadata literal)
  "Return METADATA merged with rich vector LITERAL, or nil when malformed."
  (let* ((fields (plist-get metadata :fields))
         (origins (plist-get metadata :origins))
         (new-fields (consent--documentation-rich-vector-fields literal))
         (merged-fields
          (and new-fields
               (consent--documentation-merge-fields fields new-fields))))
    (and merged-fields
         (consent--make-documentation-metadata
          merged-fields
          (consent--documentation-add-origin origins "vector")))))

(defun consent--documentation-base-metadata (retention maybe-formals)
  "Return generated base metadata for RETENTION and MAYBE-FORMALS."
  (if (and maybe-formals (not (eq retention 'none)))
      (consent--documentation-metadata-from-formals (car maybe-formals))
    (consent--make-documentation-metadata nil nil)))

(defun consent--documentation-body-result
    (body definition-form-predicate retention &rest maybe-formals)
  "Return `(:metadata METADATA :body BODY)' for documentation in BODY.
DEFINITION-FORM-PREDICATE recognizes body-leading internal
definitions.  Metadata literals are recognized only in the
non-final leading metadata prefix after those definitions.  The
returned body removes recognized metadata literals when a
non-metadata expression remains.  RETENTION controls the metadata
fields retained: `full' keeps rich and simple docstrings, `simple'
keeps simple string docstrings and generated argument metadata,
and `none' keeps no body-derived metadata."
  (let* ((retention (consent--normalize-docstring-retention retention))
         (retained-base
          (consent--documentation-base-metadata retention maybe-formals))
         (validation-metadata
          (if maybe-formals
              (consent--documentation-metadata-from-formals
               (car maybe-formals))
            (consent--make-documentation-metadata nil nil)))
         (retained-metadata retained-base)
         (cursor body)
         definitions
         saw-metadata)
    (while (and cursor (funcall definition-form-predicate (car cursor)))
      (push (car cursor) definitions)
      (setq cursor (cdr cursor)))
    (catch 'done
      (while cursor
        (cond
         ((stringp (car cursor))
          (let (strings)
            (while (and cursor (stringp (car cursor)))
              (push (car cursor) strings)
              (setq cursor (cdr cursor)))
            (setq strings (nreverse strings))
            (let ((merged
                   (consent--documentation-merge-string-run
                    validation-metadata strings)))
              (unless merged
                (throw 'done nil))
              (setq validation-metadata merged)
              (when (memq retention '(full simple))
                (setq retained-metadata
                      (consent--documentation-merge-string-run
                       retained-metadata strings)))
              (setq saw-metadata t))))
         ((vectorp (car cursor))
          (let ((merged
                 (consent--documentation-merge-rich-vector
                  validation-metadata (car cursor))))
            (unless merged
              (throw 'done nil))
            (setq validation-metadata merged)
            (when (eq retention 'full)
              (setq retained-metadata merged))
            (setq saw-metadata t
                  cursor (cdr cursor))))
         (t
          (throw 'done nil)))))
    (let* ((has-remaining-expression
            (and cursor
                 (not (funcall definition-form-predicate (car cursor)))))
           (metadata
            (cond
             ((and has-remaining-expression
                   (consent--documentation-metadata-fields-present-p
                    retained-metadata))
              retained-metadata)
             ((consent--documentation-metadata-fields-present-p
               retained-base)
              retained-base)
             (t nil)))
           (rewritten-body
            (if (and has-remaining-expression saw-metadata)
                (append (nreverse definitions) cursor)
              body)))
      (list :metadata metadata :body rewritten-body))))

(defun consent--documentation-metadata-from-body
    (body definition-form-predicate &rest maybe-formals)
  "Return full documentation metadata from BODY, or nil."
  (plist-get
   (apply
    #'consent--documentation-body-result
    body
    definition-form-predicate
    'full
    maybe-formals)
   :metadata))

(defun consent--identifier-key (identifier)
  "Return the lexical binding key for IDENTIFIER."
  (cond
   ((consent--identifier-p identifier)
    (let ((context (consent--identifier-context identifier)))
      (if context
          (list :syntax
                (consent--syntax-context-id context)
                (consent--identifier-name identifier))
        (consent--identifier-name identifier))))
   ((consent-symbol-p identifier)
    (consent-symbol-name identifier))
   ((stringp identifier)
    identifier)
   (t
    (consent--eval-error "expected identifier, got %S" identifier))))

(defun consent--identifier-display-name (identifier)
  "Return IDENTIFIER's user-facing name for diagnostics."
  (or (consent--symbol-name identifier)
      (if (stringp identifier) identifier (format "%S" identifier))))

(defun consent--environment-cell (environment name)
  "Return cell for NAME in ENVIRONMENT, or nil if unbound."
  (let ((cursor environment)
        cell)
    (while (and cursor (not cell))
      (let ((candidate
             (gethash name
                      (consent--environment-bindings cursor)
                      consent--missing-cell)))
        (unless (eq candidate consent--missing-cell)
          (setq cell candidate)))
      (setq cursor (consent--environment-parent cursor)))
    cell))

(defun consent--environment-cell-imported-p (environment cell)
  "Return non-nil when CELL is an imported binding in ENVIRONMENT."
  (let ((cursor environment)
        imported)
    (while (and cursor (not imported))
      (maphash
       (lambda (name candidate)
         (when (and (eq candidate cell)
                    (gethash name
                             (consent--environment-imported-bindings
                              cursor)))
           (setq imported t)))
       (consent--environment-bindings cursor))
      (setq cursor (consent--environment-parent cursor)))
    imported))

(defun consent--current-environment-imported-p (environment name)
  "Return non-nil if NAME is imported in ENVIRONMENT's current frame."
  (and (gethash name
                (consent--environment-imported-bindings environment))
       t))

(defun consent--environment-cell-for-identifier (environment identifier)
  "Return cell for IDENTIFIER in ENVIRONMENT, or nil if unbound.
Macro-introduced identifiers first try their generated lexical key
at the use site, then fall back to the transformer's definition
environment for free-template-identifier hygiene."
  (cond
   ((consent--identifier-p identifier)
    (let ((context (consent--identifier-context identifier)))
      (if context
          (or (consent--environment-cell
               environment (consent--identifier-key identifier))
              (let ((definition-environment
                     (consent--syntax-context-value-environment context)))
                (and definition-environment
                     (consent--environment-cell
                      definition-environment
                      (consent--identifier-name identifier)))))
        (consent--environment-cell
         environment (consent--identifier-name identifier)))))
   ((consent-symbol-p identifier)
    (consent--environment-cell
     environment (consent-symbol-name identifier)))
   ((stringp identifier)
    (consent--environment-cell environment identifier))
   (t nil)))

(defun consent--environment-define (environment name value)
  "Define NAME as VALUE in ENVIRONMENT's current frame."
  (when (consent--current-environment-imported-p environment name)
    (consent--eval-error
     "cannot redefine imported binding: %s" name))
  (puthash name
           (consent--make-cell value)
           (consent--environment-bindings environment)))

(defun consent--environment-set-cell (environment name value)
  "Store VALUE in NAME's existing cell in ENVIRONMENT."
  (let ((cell (consent--environment-cell environment name)))
    (unless cell
      (consent--eval-error "unbound identifier in set!: %s" name))
    (when (consent--environment-cell-imported-p environment cell)
      (consent--eval-error
       "cannot mutate imported binding: %s" name))
    (setf (consent--cell-value cell) value)))

(defun consent--environment-ref (environment name)
  "Return NAME's value from ENVIRONMENT."
  (let ((cell (consent--environment-cell environment name)))
    (unless cell
      (consent--eval-error "unbound identifier: %s" name))
    (let ((value (consent--cell-value cell)))
      (when (consent--undefined-p value)
        (consent--eval-error
         "identifier referenced before definition is initialized: %s"
         name))
      value)))

(defun consent--environment-ref-identifier (environment identifier)
  "Return IDENTIFIER's value from ENVIRONMENT."
  (let ((cell (consent--environment-cell-for-identifier
               environment identifier)))
    (unless cell
      (consent--eval-error
       "unbound identifier: %s"
       (consent--identifier-display-name identifier)))
    (let ((value (consent--cell-value cell)))
      (when (consent--undefined-p value)
        (consent--eval-error
         "identifier referenced before definition is initialized: %s"
         (consent--identifier-display-name identifier)))
      value)))

(defun consent--environment-set-identifier
    (environment identifier value)
  "Store VALUE in IDENTIFIER's existing cell in ENVIRONMENT."
  (let ((cell (consent--environment-cell-for-identifier
               environment identifier)))
    (unless cell
      (consent--eval-error
       "unbound identifier in set!: %s"
       (consent--identifier-display-name identifier)))
    (when (consent--environment-cell-imported-p environment cell)
      (consent--eval-error
       "cannot mutate imported binding: %s"
       (consent--identifier-display-name identifier)))
    (setf (consent--cell-value cell) value)))

(defun consent--ensure-distinct-names (names description)
  "Signal if NAMES contains duplicates for DESCRIPTION."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (name names)
      (when (gethash name seen)
        (consent--eval-error
         "duplicate identifier in %s: %s" description name))
      (puthash name t seen))))

(defun consent--note-step (context)
  "Record one evaluator step in CONTEXT."
  (consent--check-control-request context)
  (cl-incf (consent--eval-context-steps context))
  (when (and (fboundp 'thread-yield)
             (zerop (% (consent--eval-context-steps context) 128)))
    (thread-yield))
  (when (> (consent--eval-context-steps context)
           (consent--eval-context-maximum-steps context))
    (consent--budget-error
     "evaluation step budget exceeded: %d"
     (consent--eval-context-maximum-steps context))))

(defun consent--note-host-callback (context primitive)
  "Record one host callback for PRIMITIVE in CONTEXT."
  (cl-incf (consent--eval-context-host-callbacks context))
  (when (> (consent--eval-context-host-callbacks context)
           (consent--eval-context-maximum-host-callbacks context))
    (consent--budget-error
     "host callback budget exceeded while calling %s"
     (consent-primitive-procedure-name primitive))))

(defun consent--value-node-count (value seen)
  "Return an approximate node count for VALUE.
SEEN prevents infinite recursion over cyclic host structures."
  (cond
   ((or (null value)
        (eq value consent-true)
        (eq value consent-false)
        (consent-unspecified-p value)
        (consent-symbol-p value)
        (consent--identifier-p value)
        (consent-character-p value)
        ;; Raw host numbers reach here legitimately: public accessors such as
        ;; `consent-number-value' unwrap canonical numbers to host numbers, and
        ;; such a value can be an evaluation result.
        (numberp value)
        (consent-number-p value)
        (consent-procedure-p value)
        (consent-primitive-procedure-p value)
        (consent--continuation-p value)
        (consent-error-object-p value)
        (consent-eof-object-p value)
        (consent--port-p value)
        (consent--environment-specifier-p value)
        (consent--string-output-port-p value)
        (consent-handle-p value)
        (consent-record-type-p value))
    1)
   ((consent-record-p value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (let ((count 1))
        (cl-loop for item across (consent-record-fields value)
                 do (cl-incf count
                             (consent--value-node-count item seen)))
        count)))
   ((consent--multiple-values-p value)
    (1+ (cl-loop for item in (consent--multiple-values-values value)
                 sum (consent--value-node-count item seen))))
   ((stringp value)
    (1+ (length value)))
   ((consent-bytevector-p value)
    (1+ (length (consent-bytevector-bytes value))))
   ((consp value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (+ 1
         (consent--value-node-count (car value) seen)
         (consent--value-node-count (cdr value) seen))))
   ((vectorp value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (let ((count 1))
        (cl-loop for item across value
                 do (cl-incf count
                             (consent--value-node-count item seen)))
        count)))
   (t
    (consent--eval-error "unsupported Scheme value %S" value))))

(defun consent--check-value-budget (value context)
  "Signal if VALUE exceeds CONTEXT's value budget."
  (let ((count (consent--value-node-count
                value (make-hash-table :test #'eq))))
    (when (> count (consent--eval-context-maximum-value-nodes context))
      (consent--budget-error
       "value node budget exceeded: %d > %d"
       count
       (consent--eval-context-maximum-value-nodes context))))
  value)

(defun consent--control-reason-string (value)
  "Return VALUE as a short public control-reason string."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (format "%S" value))))

(defun consent--check-control-request (context)
  "Signal any pending cancellation or interrupt request in CONTEXT."
  (when-let ((reason (consent--eval-context-interrupt-reason context)))
    (signal 'consent-interrupt-error
            (list (format "job interrupted: %s"
                          (consent--control-reason-string reason)))))
  (when (consent--eval-context-cancel-requested context)
    (signal 'consent-cancelled-error
            (list (format "job cancelled: %s"
                          (or (consent--eval-context-job-id context)
                              "evaluation"))))))

(defun consent--context-events (context)
  "Return CONTEXT's event records in emission order."
  (reverse (consent--eval-context-events context)))

(defun consent--record-event! (context event)
  "Record EVENT in CONTEXT after enforcing event budgets."
  (let* ((node-count
          (consent--value-node-count
           event (make-hash-table :test #'eq)))
         (maximum-nodes
          (consent--eval-context-maximum-event-nodes context))
         (maximum-events
          (consent--eval-context-maximum-events context)))
    (when (and (integerp maximum-nodes)
               (> node-count maximum-nodes))
      (consent--budget-error
       "event node budget exceeded: %d > %d"
       node-count
       maximum-nodes))
    (when (and (integerp maximum-events)
               (>= (consent--eval-context-event-count context)
                   maximum-events))
      (consent--budget-error
       "event count budget exceeded: %d > %d"
       (1+ (consent--eval-context-event-count context))
       maximum-events))
    (cl-incf (consent--eval-context-event-count context))
    (push event (consent--eval-context-events context))
    (when-let ((hook (consent--eval-context-event-hook context)))
      (funcall hook event context))
    event))

(defun consent--values-list (value)
  "Return VALUE as the list delivered to a continuation."
  (if (consent--multiple-values-p value)
      (consent--multiple-values-values value)
    (list value)))

(defun consent--single-value (value description)
  "Return VALUE as one Scheme value or signal an arity error."
  (let ((values (consent--values-list value)))
    (unless (= (length values) 1)
      (consent--eval-error
       "%s expected one value, got %d" description (length values)))
    (car values)))

(defun consent--identity-continuation (value)
  "Return VALUE unchanged as the root evaluator continuation."
  value)

(defun consent--continue (continuation value)
  "Deliver VALUE to CONTINUATION."
  (funcall continuation value))

(defun consent--continuation-value (arguments)
  "Return continuation payload represented by ARGUMENTS."
  (if (= (length arguments) 1)
      (car arguments)
    (consent--make-multiple-values arguments)))

(provide 'consent-runtime)

;;; consent-runtime.el ends here
