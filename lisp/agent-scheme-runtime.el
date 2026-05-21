;;; agent-scheme-runtime.el --- R7RS runtime values and context  -*- lexical-binding: t; -*-

;;; Commentary:

;; Runtime records and per-run context state shared by Agent Scheme frontend
;; passes and interpreter backends.  This module owns value shapes, lexical and
;; syntactic environment frame records, evaluation budget defaults, and context
;; construction; it does not evaluate Scheme expressions.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)

(defcustom agent-scheme-eval-maximum-steps 100000
  "Maximum evaluator steps allowed in one `agent-scheme-eval' run."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-eval-maximum-value-nodes 100000
  "Maximum returned or allocated value nodes allowed during evaluation."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-eval-maximum-host-callbacks 10000
  "Maximum registered primitive callbacks allowed during evaluation."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-eval-maximum-events 1000
  "Maximum Agent Scheme event records allowed in one evaluation."
  :type 'integer
  :group 'agent-scheme)

(defcustom agent-scheme-eval-maximum-event-nodes 100000
  "Maximum reachable value nodes allowed in one Agent Scheme event record."
  :type 'integer
  :group 'agent-scheme)

(define-error 'agent-scheme-eval-error
  "Agent Scheme evaluation error")

(define-error 'agent-scheme-budget-error
  "Agent Scheme evaluation budget exceeded"
  'agent-scheme-eval-error)

(cl-defstruct (agent-scheme-unspecified
               (:constructor agent-scheme--make-unspecified)
               (:copier nil))
  "Scheme unspecified value.")

(defconst agent-scheme-unspecified
  (agent-scheme--make-unspecified)
  "Canonical Agent Scheme unspecified value.")

(cl-defstruct (agent-scheme--undefined
               (:constructor agent-scheme--make-undefined)
               (:copier nil))
  "Internal marker for uninitialized definition locations.")

(defconst agent-scheme--undefined
  (agent-scheme--make-undefined)
  "Internal uninitialized binding marker.")

(cl-defstruct (agent-scheme--cell
               (:constructor agent-scheme--make-cell (value))
               (:copier nil))
  "Mutable location for one Scheme binding."
  value)

(cl-defstruct (agent-scheme--environment
               (:constructor agent-scheme--make-environment
                             (bindings parent imported-bindings))
               (:copier nil))
  "Explicit lexical environment frame.
BINDINGS maps lexical keys to cells.  IMPORTED-BINDINGS records
current-frame names that cannot be redefined or mutated by Scheme
code."
  bindings parent imported-bindings)

(cl-defstruct (agent-scheme--syntax-environment
               (:constructor agent-scheme--make-syntax-environment
                             (bindings parent imported-bindings))
               (:copier nil))
  "Explicit syntactic environment frame."
  bindings parent imported-bindings)

(cl-defstruct (agent-scheme--syntax-context
               (:constructor agent-scheme--make-syntax-context
                             (id value-environment syntax-environment))
               (:copier nil))
  "Hygienic context attached to macro-introduced identifiers.
VALUE-ENVIRONMENT and SYNTAX-ENVIRONMENT are the transformer's
definition environments; free identifiers introduced by the
template resolve there instead of at the macro use site."
  id value-environment syntax-environment)

(cl-defstruct (agent-scheme--identifier
               (:constructor agent-scheme--make-identifier (name context))
               (:copier nil))
  "Macro-expanded identifier with hygienic context."
  name context)

(cl-defstruct (agent-scheme--formals
               (:constructor agent-scheme--make-formals
                             (required rest))
               (:copier nil))
  "Parsed lambda formal parameters."
  required rest)

(cl-defstruct (agent-scheme-procedure
               (:constructor agent-scheme--make-procedure
                             (formals body environment))
               (:copier nil))
  "Scheme procedure value."
  formals body environment)

(cl-defstruct (agent-scheme-primitive-procedure
               (:constructor agent-scheme--make-primitive-procedure
                             (name function minimum-arity maximum-arity))
               (:copier nil))
  "Registered primitive procedure value."
  name function minimum-arity maximum-arity)

(cl-defstruct (agent-scheme-parameter
               (:constructor agent-scheme--make-parameter (value converter))
               (:copier nil))
  "R7RS parameter object.
VALUE is the current value.  CONVERTER is nil or a Scheme procedure applied to
new values before they are installed."
  value converter)

(cl-defstruct (agent-scheme--multiple-values
               (:constructor agent-scheme--make-multiple-values (values))
               (:copier nil))
  "A Scheme multiple-values payload."
  values)

(cl-defstruct (agent-scheme--continuation
               (:constructor agent-scheme--make-continuation
                             (procedure dynamic-winds exception-handlers))
               (:copier nil))
  "A re-enterable continuation captured by call/cc.
PROCEDURE is the evaluator continuation to receive a value, and
DYNAMIC-WINDS and EXCEPTION-HANDLERS are the dynamic state active at
capture time."
  procedure dynamic-winds exception-handlers)

(cl-defstruct (agent-scheme--dynamic-wind-frame
               (:constructor agent-scheme--make-dynamic-wind-frame
                             (before after))
               (:copier nil))
  "One active dynamic-wind frame."
  before after)

(cl-defstruct (agent-scheme-error-object
               (:constructor agent-scheme--make-error-object
                             (message irritants))
               (:copier nil))
  "R7RS error object created by the `error' procedure."
  message irritants)

(cl-defstruct (agent-scheme-eof-object
               (:constructor agent-scheme--make-eof-object)
               (:copier nil))
  "R7RS end-of-file object.")

(defconst agent-scheme-eof-object
  (agent-scheme--make-eof-object)
  "Canonical Agent Scheme end-of-file object.")

(cl-defstruct (agent-scheme--port
               (:constructor agent-scheme--make-port)
               (:copier nil))
  "Agent Scheme port.
MEDIUM separates string, bytevector, host-file, and virtual ports.
INPUTP and OUTPUTP record direction; TEXTUALP and BINARYP record
the datum layer; OPENP tracks whether operations are still valid.
SOURCE and POSITION back input ports, while CONTENTS backs output
ports.  Host-backed ports additionally carry BACKING-DOMAIN,
OPERATIONS, GRANT, LIMITS, HANDLE, STATUS, and PATH as printable
capability metadata; raw host objects stay outside Scheme values."
  medium inputp outputp textualp binaryp (openp t) source (position 0) contents
  backing-domain operations grant limits handle status path counters)

(cl-defstruct (agent-scheme--environment-specifier
               (:constructor agent-scheme--make-environment-specifier
                             (environment syntax-environment immutable))
               (:copier nil))
  "Specifier accepted by the R7RS `(scheme eval)' and `(scheme load)' APIs."
  environment syntax-environment immutable)

(cl-defstruct (agent-scheme--string-output-port
               (:constructor agent-scheme--make-string-output-port
                             (contents))
               (:copier nil))
  "In-memory textual output port used by `(scheme write)'."
  contents)

(cl-defstruct (agent-scheme--sequence
               (:constructor agent-scheme--make-sequence
                             (forms allow-definitions))
               (:copier nil))
  "Internal sequence expression."
  forms allow-definitions)

(cl-defstruct (agent-scheme--bounce
               (:constructor agent-scheme--make-bounce
                             (expression environment &optional
                                         syntax-environment continuation))
               (:copier nil))
  "Trampoline state for evaluating EXPRESSION in ENVIRONMENT."
  expression environment syntax-environment continuation)

(cl-defstruct (agent-scheme--eval-context
               (:constructor agent-scheme--make-eval-context)
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
  session-id
  interaction-environment
  base-syntax-installed
  exception-handlers
  dynamic-winds)

(defconst agent-scheme--missing-cell (make-symbol "agent-scheme-missing-cell")
  "Sentinel used when looking up environment cells.")

(defun agent-scheme--eval-option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun agent-scheme--eval-error (message &rest args)
  "Signal an Agent Scheme evaluation error.
MESSAGE and ARGS are passed to `format'."
  (signal 'agent-scheme-eval-error (list (apply #'format message args))))

(defun agent-scheme--budget-error (message &rest args)
  "Signal an Agent Scheme budget error.
MESSAGE and ARGS are passed to `format'."
  (signal 'agent-scheme-budget-error (list (apply #'format message args))))

(defun agent-scheme--normalize-include-paths (paths directory)
  "Return policy PATHS expanded relative to DIRECTORY."
  (when paths
    (unless (listp paths)
      (agent-scheme--eval-error
       ":include-paths must be a list of file or directory paths"))
    (mapcar
     (lambda (path)
       (unless (stringp path)
         (agent-scheme--eval-error
          ":include-paths entries must be strings"))
       (expand-file-name path directory))
     paths)))

(defun agent-scheme--new-eval-context (options)
  "Return an evaluator context using OPTIONS."
  (let ((maximum-steps
         (cond
          ((plist-member options :max-steps)
           (plist-get options :max-steps))
          ((plist-member options :max-non-tail-steps)
           (plist-get options :max-non-tail-steps))
          (t agent-scheme-eval-maximum-steps)))
        (include-directory
         (file-name-as-directory
          (expand-file-name
           (agent-scheme--eval-option
            options :include-directory default-directory)))))
    (agent-scheme--make-eval-context
     :steps 0
     :maximum-steps maximum-steps
     :maximum-value-nodes
     (agent-scheme--eval-option options :max-value-nodes
                                agent-scheme-eval-maximum-value-nodes)
     :host-callbacks 0
     :maximum-host-callbacks
     (agent-scheme--eval-option options :max-host-callbacks
                                agent-scheme-eval-maximum-host-callbacks)
     :events nil
     :event-count 0
     :maximum-events
     (agent-scheme--eval-option options :max-events
                                agent-scheme-eval-maximum-events)
     :maximum-event-nodes
     (agent-scheme--eval-option options :max-event-nodes
                                agent-scheme-eval-maximum-event-nodes)
     :syntax-environment
     (agent-scheme--make-syntax-environment
      (make-hash-table :test #'equal) nil
      (make-hash-table :test #'equal))
     :libraries (make-hash-table :test #'equal)
     :include-paths
     (agent-scheme--normalize-include-paths
      (agent-scheme--eval-option options :include-paths nil)
      include-directory)
     :include-directory include-directory
     :file-paths
     (agent-scheme--normalize-include-paths
      (agent-scheme--eval-option options :file-paths nil)
      include-directory)
     :policy-actions
     (agent-scheme--eval-option options :policy-actions nil)
     :policy-confirmation-function
     (agent-scheme--eval-option options :policy-confirmation-function nil)
     :capability-grants
     (agent-scheme--eval-option options :capability-grants nil)
     :active-capability-grants nil
     :session-id
     (agent-scheme--eval-option options :session-id nil)
     :base-syntax-installed nil
     :exception-handlers nil
     :dynamic-winds nil)))

(defun agent-scheme-make-empty-environment (&optional parent)
  "Return an empty lexical environment with optional PARENT."
  (agent-scheme--make-environment
   (make-hash-table :test #'equal)
   parent
   (make-hash-table :test #'equal)))

(defun agent-scheme--identifier-datum-p (datum)
  "Return non-nil if DATUM is a Scheme identifier."
  (or (agent-scheme-symbol-p datum)
      (agent-scheme--identifier-p datum)))

(defun agent-scheme--symbol-name (datum)
  "Return DATUM's Scheme identifier name, or nil."
  (cond
   ((agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum))
   ((agent-scheme--identifier-p datum)
    (agent-scheme--identifier-name datum))
   (t nil)))

(defun agent-scheme--symbol-named-p (datum name)
  "Return non-nil if DATUM is a Scheme symbol named NAME."
  (equal (agent-scheme--symbol-name datum) name))

(defun agent-scheme--proper-list-elements (datum description)
  "Return proper list DATUM as an Emacs Lisp list.
Signal an evaluation error naming DESCRIPTION when DATUM is not a
proper list."
  (let ((cursor datum)
        elements)
    (while (consp cursor)
      (push (car cursor) elements)
      (setq cursor (cdr cursor)))
    (when cursor
      (agent-scheme--eval-error "%s must be a proper list" description))
    (nreverse elements)))

(defun agent-scheme--proper-list-elements-maybe (datum)
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

(defun agent-scheme--expect-symbol-name (datum description)
  "Return DATUM's symbol name or signal an error naming DESCRIPTION."
  (or (agent-scheme--symbol-name datum)
      (agent-scheme--eval-error "%s must be an identifier" description)))

(defun agent-scheme--syntax-symbol (name)
  "Return Agent Scheme symbol datum for NAME."
  (agent-scheme--intern-symbol name))

(defun agent-scheme--identifier-key (identifier)
  "Return the lexical binding key for IDENTIFIER."
  (cond
   ((agent-scheme--identifier-p identifier)
    (let ((context (agent-scheme--identifier-context identifier)))
      (if context
          (list :syntax
                (agent-scheme--syntax-context-id context)
                (agent-scheme--identifier-name identifier))
        (agent-scheme--identifier-name identifier))))
   ((agent-scheme-symbol-p identifier)
    (agent-scheme-symbol-name identifier))
   ((stringp identifier)
    identifier)
   (t
    (agent-scheme--eval-error "expected identifier, got %S" identifier))))

(defun agent-scheme--identifier-display-name (identifier)
  "Return IDENTIFIER's user-facing name for diagnostics."
  (or (agent-scheme--symbol-name identifier)
      (if (stringp identifier) identifier (format "%S" identifier))))

(defun agent-scheme--environment-cell (environment name)
  "Return cell for NAME in ENVIRONMENT, or nil if unbound."
  (let ((cursor environment)
        cell)
    (while (and cursor (not cell))
      (let ((candidate
             (gethash name
                      (agent-scheme--environment-bindings cursor)
                      agent-scheme--missing-cell)))
        (unless (eq candidate agent-scheme--missing-cell)
          (setq cell candidate)))
      (setq cursor (agent-scheme--environment-parent cursor)))
    cell))

(defun agent-scheme--environment-cell-imported-p (environment cell)
  "Return non-nil when CELL is an imported binding in ENVIRONMENT."
  (let ((cursor environment)
        imported)
    (while (and cursor (not imported))
      (maphash
       (lambda (name candidate)
         (when (and (eq candidate cell)
                    (gethash name
                             (agent-scheme--environment-imported-bindings
                              cursor)))
           (setq imported t)))
       (agent-scheme--environment-bindings cursor))
      (setq cursor (agent-scheme--environment-parent cursor)))
    imported))

(defun agent-scheme--current-environment-imported-p (environment name)
  "Return non-nil if NAME is imported in ENVIRONMENT's current frame."
  (and (gethash name
                (agent-scheme--environment-imported-bindings environment))
       t))

(defun agent-scheme--environment-cell-for-identifier (environment identifier)
  "Return cell for IDENTIFIER in ENVIRONMENT, or nil if unbound.
Macro-introduced identifiers first try their generated lexical key
at the use site, then fall back to the transformer's definition
environment for free-template-identifier hygiene."
  (cond
   ((agent-scheme--identifier-p identifier)
    (let ((context (agent-scheme--identifier-context identifier)))
      (if context
          (or (agent-scheme--environment-cell
               environment (agent-scheme--identifier-key identifier))
              (let ((definition-environment
                     (agent-scheme--syntax-context-value-environment context)))
                (and definition-environment
                     (agent-scheme--environment-cell
                      definition-environment
                      (agent-scheme--identifier-name identifier)))))
        (agent-scheme--environment-cell
         environment (agent-scheme--identifier-name identifier)))))
   ((agent-scheme-symbol-p identifier)
    (agent-scheme--environment-cell
     environment (agent-scheme-symbol-name identifier)))
   ((stringp identifier)
    (agent-scheme--environment-cell environment identifier))
   (t nil)))

(defun agent-scheme--environment-define (environment name value)
  "Define NAME as VALUE in ENVIRONMENT's current frame."
  (when (agent-scheme--current-environment-imported-p environment name)
    (agent-scheme--eval-error
     "cannot redefine imported binding: %s" name))
  (puthash name
           (agent-scheme--make-cell value)
           (agent-scheme--environment-bindings environment)))

(defun agent-scheme--environment-set-cell (environment name value)
  "Store VALUE in NAME's existing cell in ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell environment name)))
    (unless cell
      (agent-scheme--eval-error "unbound identifier in set!: %s" name))
    (when (agent-scheme--environment-cell-imported-p environment cell)
      (agent-scheme--eval-error
       "cannot mutate imported binding: %s" name))
    (setf (agent-scheme--cell-value cell) value)))

(defun agent-scheme--environment-ref (environment name)
  "Return NAME's value from ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell environment name)))
    (unless cell
      (agent-scheme--eval-error "unbound identifier: %s" name))
    (let ((value (agent-scheme--cell-value cell)))
      (when (agent-scheme--undefined-p value)
        (agent-scheme--eval-error
         "identifier referenced before definition is initialized: %s"
         name))
      value)))

(defun agent-scheme--environment-ref-identifier (environment identifier)
  "Return IDENTIFIER's value from ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell-for-identifier
               environment identifier)))
    (unless cell
      (agent-scheme--eval-error
       "unbound identifier: %s"
       (agent-scheme--identifier-display-name identifier)))
    (let ((value (agent-scheme--cell-value cell)))
      (when (agent-scheme--undefined-p value)
        (agent-scheme--eval-error
         "identifier referenced before definition is initialized: %s"
         (agent-scheme--identifier-display-name identifier)))
      value)))

(defun agent-scheme--environment-set-identifier
    (environment identifier value)
  "Store VALUE in IDENTIFIER's existing cell in ENVIRONMENT."
  (let ((cell (agent-scheme--environment-cell-for-identifier
               environment identifier)))
    (unless cell
      (agent-scheme--eval-error
       "unbound identifier in set!: %s"
       (agent-scheme--identifier-display-name identifier)))
    (when (agent-scheme--environment-cell-imported-p environment cell)
      (agent-scheme--eval-error
       "cannot mutate imported binding: %s"
       (agent-scheme--identifier-display-name identifier)))
    (setf (agent-scheme--cell-value cell) value)))

(defun agent-scheme--ensure-distinct-names (names description)
  "Signal if NAMES contains duplicates for DESCRIPTION."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (name names)
      (when (gethash name seen)
        (agent-scheme--eval-error
         "duplicate identifier in %s: %s" description name))
      (puthash name t seen))))

(defun agent-scheme--note-step (context)
  "Record one evaluator step in CONTEXT."
  (cl-incf (agent-scheme--eval-context-steps context))
  (when (> (agent-scheme--eval-context-steps context)
           (agent-scheme--eval-context-maximum-steps context))
    (agent-scheme--budget-error
     "evaluation step budget exceeded: %d"
     (agent-scheme--eval-context-maximum-steps context))))

(defun agent-scheme--note-host-callback (context primitive)
  "Record one host callback for PRIMITIVE in CONTEXT."
  (cl-incf (agent-scheme--eval-context-host-callbacks context))
  (when (> (agent-scheme--eval-context-host-callbacks context)
           (agent-scheme--eval-context-maximum-host-callbacks context))
    (agent-scheme--budget-error
     "host callback budget exceeded while calling %s"
     (agent-scheme-primitive-procedure-name primitive))))

(defun agent-scheme--value-node-count (value seen)
  "Return an approximate node count for VALUE.
SEEN prevents infinite recursion over cyclic host structures."
  (cond
   ((or (null value)
        (eq value agent-scheme-true)
        (eq value agent-scheme-false)
        (agent-scheme-unspecified-p value)
        (agent-scheme-symbol-p value)
        (agent-scheme--identifier-p value)
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-procedure-p value)
        (agent-scheme-primitive-procedure-p value)
        (agent-scheme--continuation-p value)
        (agent-scheme-error-object-p value)
        (agent-scheme-eof-object-p value)
        (agent-scheme--port-p value)
        (agent-scheme--environment-specifier-p value)
        (agent-scheme--string-output-port-p value)
        (agent-scheme-handle-p value)
        (agent-scheme-record-type-p value))
    1)
   ((agent-scheme-record-p value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (let ((count 1))
        (cl-loop for item across (agent-scheme-record-fields value)
                 do (cl-incf count
                             (agent-scheme--value-node-count item seen)))
        count)))
   ((agent-scheme--multiple-values-p value)
    (1+ (cl-loop for item in (agent-scheme--multiple-values-values value)
                 sum (agent-scheme--value-node-count item seen))))
   ((stringp value)
    (1+ (length value)))
   ((agent-scheme-bytevector-p value)
    (1+ (length (agent-scheme-bytevector-bytes value))))
   ((consp value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (+ 1
         (agent-scheme--value-node-count (car value) seen)
         (agent-scheme--value-node-count (cdr value) seen))))
   ((vectorp value)
    (if (gethash value seen)
        0
      (puthash value t seen)
      (let ((count 1))
        (cl-loop for item across value
                 do (cl-incf count
                             (agent-scheme--value-node-count item seen)))
        count)))
   (t
    (agent-scheme--eval-error "unsupported Scheme value %S" value))))

(defun agent-scheme--check-value-budget (value context)
  "Signal if VALUE exceeds CONTEXT's value budget."
  (let ((count (agent-scheme--value-node-count
                value (make-hash-table :test #'eq))))
    (when (> count (agent-scheme--eval-context-maximum-value-nodes context))
      (agent-scheme--budget-error
       "value node budget exceeded: %d > %d"
       count
       (agent-scheme--eval-context-maximum-value-nodes context))))
  value)

(defun agent-scheme--context-events (context)
  "Return CONTEXT's event records in emission order."
  (reverse (agent-scheme--eval-context-events context)))

(defun agent-scheme--record-event! (context event)
  "Record EVENT in CONTEXT after enforcing event budgets."
  (let* ((node-count
          (agent-scheme--value-node-count
           event (make-hash-table :test #'eq)))
         (maximum-nodes
          (agent-scheme--eval-context-maximum-event-nodes context))
         (maximum-events
          (agent-scheme--eval-context-maximum-events context)))
    (when (and (integerp maximum-nodes)
               (> node-count maximum-nodes))
      (agent-scheme--budget-error
       "event node budget exceeded: %d > %d"
       node-count
       maximum-nodes))
    (when (and (integerp maximum-events)
               (>= (agent-scheme--eval-context-event-count context)
                   maximum-events))
      (agent-scheme--budget-error
       "event count budget exceeded: %d > %d"
       (1+ (agent-scheme--eval-context-event-count context))
       maximum-events))
    (cl-incf (agent-scheme--eval-context-event-count context))
    (push event (agent-scheme--eval-context-events context))
    event))

(defun agent-scheme--values-list (value)
  "Return VALUE as the list delivered to a continuation."
  (if (agent-scheme--multiple-values-p value)
      (agent-scheme--multiple-values-values value)
    (list value)))

(defun agent-scheme--single-value (value description)
  "Return VALUE as one Scheme value or signal an arity error."
  (let ((values (agent-scheme--values-list value)))
    (unless (= (length values) 1)
      (agent-scheme--eval-error
       "%s expected one value, got %d" description (length values)))
    (car values)))

(defun agent-scheme--identity-continuation (value)
  "Return VALUE unchanged as the root evaluator continuation."
  value)

(defun agent-scheme--continue (continuation value)
  "Deliver VALUE to CONTINUATION."
  (funcall continuation value))

(defun agent-scheme--continuation-value (arguments)
  "Return continuation payload represented by ARGUMENTS."
  (if (= (length arguments) 1)
      (car arguments)
    (agent-scheme--make-multiple-values arguments)))

(provide 'agent-scheme-runtime)

;;; agent-scheme-runtime.el ends here
