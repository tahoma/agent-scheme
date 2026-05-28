;;; agent-scheme-interpreter.el --- R7RS interpreter backend  -*- lexical-binding: t; -*-

;;; Commentary:

;; Interpreter backend for Agent Scheme.  This module owns evaluation,
;; procedure application, primitive implementations, trampoline execution, and
;; Scheme-readable evaluation result records.  Public orchestration entry points
;; live in `agent-scheme-eval'.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-base)
(require 'agent-scheme-library)
(require 'agent-scheme-macro)
(require 'agent-scheme-policy)
(require 'agent-scheme-debugger)

(defun agent-scheme--dynamic-wind-prefix-before (frame stack)
  "Return the prefix of STACK before FRAME, comparing frames with `eq'."
  (let ((cursor stack)
        prefix
        found)
    (while (and cursor (not found))
      (if (eq (car cursor) frame)
          (setq found t)
        (push (car cursor) prefix)
        (setq cursor (cdr cursor))))
    (nreverse prefix)))

(defun agent-scheme--dynamic-wind-common-frame (current target)
  "Return the outermost common frame shared by CURRENT and TARGET."
  (let ((current-outer (reverse current))
        (target-outer (reverse target))
        common)
    (while (and current-outer target-outer
                (eq (car current-outer) (car target-outer)))
      (setq common (car current-outer))
      (setq current-outer (cdr current-outer))
      (setq target-outer (cdr target-outer)))
    common))

(declare-function agent-scheme--apply-procedure "agent-scheme-interpreter")

(defun agent-scheme--call-ignoring-values (procedure context description)
  "Call zero-argument PROCEDURE in CONTEXT and discard its values."
  (agent-scheme--expect-procedure procedure description)
  (agent-scheme--apply-procedure procedure nil context nil)
  agent-scheme-unspecified)

(defun agent-scheme--call-ignoring-values/k
    (procedure context description continuation)
  "Call zero-argument PROCEDURE and continue with unspecified."
  (agent-scheme--expect-procedure procedure description)
  (agent-scheme--apply-procedure
   procedure
   nil
   context
   t
   (lambda (_value)
     (agent-scheme--continue continuation agent-scheme-unspecified))))

(defun agent-scheme--switch-dynamic-winds (target context)
  "Run dynamic-wind thunks needed to move CONTEXT to TARGET."
  (let* ((current (agent-scheme--eval-context-dynamic-winds context))
         (common (agent-scheme--dynamic-wind-common-frame current target))
         (exiting (if common
                      (agent-scheme--dynamic-wind-prefix-before common current)
                    current))
         (entering (if common
                       (agent-scheme--dynamic-wind-prefix-before common target)
                     target)))
    (dolist (frame exiting)
      (when (eq (car (agent-scheme--eval-context-dynamic-winds context)) frame)
        (pop (agent-scheme--eval-context-dynamic-winds context)))
      (agent-scheme--call-ignoring-values
       (agent-scheme--dynamic-wind-frame-after frame)
       context
       "dynamic-wind after"))
    (dolist (frame (reverse entering))
      (agent-scheme--call-ignoring-values
       (agent-scheme--dynamic-wind-frame-before frame)
       context
       "dynamic-wind before")
      (push frame (agent-scheme--eval-context-dynamic-winds context)))
    (setf (agent-scheme--eval-context-dynamic-winds context)
          (copy-sequence target))))

(defun agent-scheme--expect-identifier-key (datum description)
  "Return DATUM's lexical binding key or signal an error."
  (unless (agent-scheme--identifier-datum-p datum)
    (agent-scheme--eval-error "%s must be an identifier" description))
  (agent-scheme--identifier-key datum))

(defun agent-scheme--parse-formals (formals)
  "Parse Scheme FORMALS into an `agent-scheme--formals' value."
  (cond
   ((agent-scheme-symbol-p formals)
    (agent-scheme--make-formals nil (agent-scheme--identifier-key formals)))
   ((agent-scheme--identifier-p formals)
    (agent-scheme--make-formals nil (agent-scheme--identifier-key formals)))
   (t
    (let ((cursor formals)
          required
          rest)
      (while (consp cursor)
        (push (agent-scheme--expect-identifier-key
               (car cursor) "lambda formal")
              required)
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor))
       ((agent-scheme--identifier-datum-p cursor)
        (setq rest (agent-scheme--identifier-key cursor)))
       (t
        (agent-scheme--eval-error
         "lambda formals must be an identifier, a proper list, or a dotted list")))
      (setq required (nreverse required))
      (agent-scheme--ensure-distinct-names
       (if rest (append required (list rest)) required)
       "lambda formals")
      (agent-scheme--make-formals required rest)))))

(defun agent-scheme--self-evaluating-p (expression)
  "Return non-nil when EXPRESSION is a self-evaluating datum."
  (or (eq expression agent-scheme-true)
      (eq expression agent-scheme-false)
      (agent-scheme-number-p expression)
      (agent-scheme-character-p expression)
      (stringp expression)
      (vectorp expression)
      (agent-scheme-bytevector-p expression)))

(defun agent-scheme--true-value-p (value)
  "Return non-nil if VALUE counts as true in Scheme."
  (not (eq value agent-scheme-false)))

(defun agent-scheme--make-lambda-expression (formals body)
  "Construct a lambda expression from FORMALS and BODY."
  (cons (agent-scheme--syntax-symbol "lambda")
        (cons formals body)))

(defun agent-scheme--parse-definition (form)
  "Parse supported DEFINE FORM.
Return a cons cell (NAME . INITIALIZER-EXPRESSION)."
  (let ((parts (agent-scheme--proper-list-elements form "define form")))
    (unless (>= (length parts) 3)
      (agent-scheme--eval-error "define requires a target and a value"))
    (let ((target (cadr parts))
          (body (cddr parts)))
      (cond
       ((agent-scheme-symbol-p target)
        (unless (= (length body) 1)
          (agent-scheme--eval-error
           "variable define requires exactly one expression"))
        (cons (agent-scheme--identifier-key target) (car body)))
       ((agent-scheme--identifier-p target)
        (unless (= (length body) 1)
          (agent-scheme--eval-error
           "variable define requires exactly one expression"))
        (cons (agent-scheme--identifier-key target) (car body)))
       ((consp target)
        (let ((name (agent-scheme--expect-identifier-key
                     (car target) "function define name")))
          (unless body
            (agent-scheme--eval-error "function define requires a body"))
          (cons name
                (agent-scheme--make-lambda-expression (cdr target) body))))
       (t
        (agent-scheme--eval-error
         "define target must be an identifier or function signature"))))))

(defun agent-scheme--body-definition-form-p (form)
  "Return non-nil if FORM is a body definition."
  (or (agent-scheme--definition-form-p form)
      (agent-scheme--define-values-form-p form)
      (agent-scheme--record-definition-form-p form)))

(defun agent-scheme--parse-record-definition (form)
  "Parse a R7RS define-record-type FORM into a plist."
  (let ((parts (agent-scheme--proper-list-elements
                form "define-record-type form")))
    (unless (>= (length parts) 4)
      (agent-scheme--eval-error
       "define-record-type requires name, constructor, predicate, and fields"))
    (let* ((type-name (agent-scheme--expect-identifier-key
                       (nth 1 parts) "record type name"))
           (constructor-spec
            (agent-scheme--proper-list-elements
             (nth 2 parts) "record constructor"))
           (constructor-name
            (agent-scheme--expect-identifier-key
             (car constructor-spec) "record constructor name"))
           (constructor-fields
            (mapcar (lambda (field)
                      (agent-scheme--expect-identifier-key
                       field "record constructor field"))
                    (cdr constructor-spec)))
           (predicate-name
            (agent-scheme--expect-identifier-key
             (nth 3 parts) "record predicate name"))
           fields accessors mutators)
      (dolist (field-spec (nthcdr 4 parts))
        (let ((field-parts
               (agent-scheme--proper-list-elements
                field-spec "record field")))
          (unless (or (= (length field-parts) 2)
                      (= (length field-parts) 3))
            (agent-scheme--eval-error
             "record field requires name, accessor, and optional mutator"))
          (let ((field-name (agent-scheme--expect-identifier-key
                             (car field-parts) "record field name"))
                (accessor-name (agent-scheme--expect-identifier-key
                                (cadr field-parts) "record accessor name"))
                (mutator-name
                 (and (cddr field-parts)
                      (agent-scheme--expect-identifier-key
                       (caddr field-parts) "record mutator name"))))
            (push field-name fields)
            (push (cons accessor-name field-name) accessors)
            (when mutator-name
              (push (cons mutator-name field-name) mutators)))))
      (setq fields (nreverse fields)
            accessors (nreverse accessors)
            mutators (nreverse mutators))
      (agent-scheme--ensure-distinct-names fields "record fields")
      (agent-scheme--ensure-distinct-names
       (append (mapcar #'car accessors) (mapcar #'car mutators))
       "record accessors and mutators")
      (dolist (field constructor-fields)
        (unless (member field fields)
          (agent-scheme--eval-error
           "record constructor references unknown field: %s" field)))
      (list :type-name type-name
            :constructor-name constructor-name
            :constructor-fields constructor-fields
            :predicate-name predicate-name
            :fields fields
            :accessors accessors
            :mutators mutators))))

(defun agent-scheme--record-definition-bound-names (form)
  "Return names bound by define-record-type FORM."
  (let ((spec (agent-scheme--parse-record-definition form)))
    (append
     (list (plist-get spec :type-name)
           (plist-get spec :constructor-name)
           (plist-get spec :predicate-name))
     (mapcar #'car (plist-get spec :accessors))
     (mapcar #'car (plist-get spec :mutators)))))

(defun agent-scheme--record-field-index (record-type field)
  "Return FIELD index in RECORD-TYPE."
  (or (cl-position field (agent-scheme-record-type-fields record-type)
                   :test #'equal)
      (agent-scheme--eval-error
       "record type does not contain field: %s" field)))

(defun agent-scheme--expect-record-of-type (value record-type description)
  "Return VALUE as a record of RECORD-TYPE or signal DESCRIPTION."
  (unless (and (agent-scheme-record-p value)
               (eq (agent-scheme-record-type value) record-type))
    (agent-scheme--eval-error "%s expected record" description))
  value)

(defun agent-scheme--define-or-set-record-binding (environment name value)
  "Define NAME as VALUE in ENVIRONMENT, or set an existing local cell."
  (let ((cell (gethash name
                       (agent-scheme--environment-bindings environment)
                       agent-scheme--missing-cell)))
    (if (not (eq cell agent-scheme--missing-cell))
        (progn
          (when (agent-scheme--current-environment-imported-p
                 environment name)
            (agent-scheme--eval-error
             "cannot redefine imported binding: %s" name))
          (setf (agent-scheme--cell-value cell) value))
      (agent-scheme--environment-define environment name value))))

(defun agent-scheme--eval-record-definition (form environment _context)
  "Evaluate a define-record-type FORM in ENVIRONMENT."
  (let* ((spec (agent-scheme--parse-record-definition form))
         (type-name (plist-get spec :type-name))
         (fields (plist-get spec :fields))
         (record-type (agent-scheme--make-record-type type-name fields))
         (constructor-fields (plist-get spec :constructor-fields))
         (constructor
          (agent-scheme--make-primitive-procedure
           (plist-get spec :constructor-name)
           (lambda (arguments _context)
             (let ((values (make-vector (length fields)
                                        agent-scheme-unspecified)))
               (cl-loop for field in constructor-fields
                        for argument in arguments
                        do (aset values
                                 (agent-scheme--record-field-index
                                  record-type field)
                                 argument))
               (agent-scheme--make-record record-type values)))
           (length constructor-fields)
           (length constructor-fields)))
         (predicate
          (agent-scheme--make-primitive-procedure
           (plist-get spec :predicate-name)
           (lambda (arguments _context)
             (agent-scheme--scheme-boolean
              (and (agent-scheme-record-p (car arguments))
                   (eq (agent-scheme-record-type (car arguments))
                       record-type))))
           1
           1)))
    (agent-scheme--define-or-set-record-binding
     environment type-name record-type)
    (agent-scheme--define-or-set-record-binding
     environment (plist-get spec :constructor-name) constructor)
    (agent-scheme--define-or-set-record-binding
     environment (plist-get spec :predicate-name) predicate)
    (dolist (accessor (plist-get spec :accessors))
      (let* ((name (car accessor))
             (field (cdr accessor))
             (index (agent-scheme--record-field-index record-type field)))
        (agent-scheme--define-or-set-record-binding
         environment
         name
         (agent-scheme--make-primitive-procedure
          name
          (lambda (arguments _context)
            (aref (agent-scheme-record-fields
                   (agent-scheme--expect-record-of-type
                    (car arguments) record-type name))
                  index))
          1
          1))))
    (dolist (mutator (plist-get spec :mutators))
      (let* ((name (car mutator))
             (field (cdr mutator))
             (index (agent-scheme--record-field-index record-type field)))
        (agent-scheme--define-or-set-record-binding
         environment
         name
         (agent-scheme--make-primitive-procedure
          name
          (lambda (arguments _context)
            (aset (agent-scheme-record-fields
                   (agent-scheme--expect-record-of-type
                    (car arguments) record-type name))
                  index
                  (cadr arguments))
            agent-scheme-unspecified)
          2
          2))))
    agent-scheme-unspecified))

(defun agent-scheme--split-body (body)
  "Split BODY into leading definitions and remaining expressions."
  (let ((cursor body)
        definitions)
    (while (and cursor (agent-scheme--body-definition-form-p (car cursor)))
      (push (car cursor) definitions)
      (setq cursor (cdr cursor)))
    (unless cursor
      (agent-scheme--eval-error "body must contain at least one expression"))
    (cons (nreverse definitions) cursor)))

(defun agent-scheme--body-documentation (body &rest maybe-formals)
  "Return documentation metadata from BODY and optional FORMALS."
  (apply
   #'agent-scheme--documentation-metadata-from-body
   body
   #'agent-scheme--body-definition-form-p
   maybe-formals))

(declare-function agent-scheme--eval-expression "agent-scheme-eval")
(declare-function agent-scheme--eval-sequence "agent-scheme-eval")

(defun agent-scheme--prepare-body-environment (body environment context)
  "Return (ENVIRONMENT . EXPRESSIONS) for lambda BODY.
Internal definitions are installed in fresh locations before their
initializers are evaluated."
  (let* ((split (agent-scheme--split-body body))
         (definitions (car split))
         (expressions (cdr split)))
    (if (null definitions)
        (cons environment expressions)
      (let ((body-environment (agent-scheme-make-empty-environment environment))
            parsed)
        (dolist (definition definitions)
          (cond
           ((agent-scheme--definition-form-p definition)
            (let ((parsed-definition
                   (agent-scheme--parse-definition definition)))
              (push (cons 'define parsed-definition) parsed)
              ;; Install all internal-definition names before any initializer is
              ;; evaluated so mutually recursive bodies see allocated locations.
              (unless (eq (gethash (car parsed-definition)
                                    (agent-scheme--environment-bindings
                                     body-environment)
                                    agent-scheme--missing-cell)
                          agent-scheme--missing-cell)
                (agent-scheme--eval-error
                 "duplicate internal definition: %s"
                 (car parsed-definition)))
              (agent-scheme--environment-define
               body-environment (car parsed-definition)
               agent-scheme--undefined)))
           ((agent-scheme--define-values-form-p definition)
            (push (cons 'define-values
                        (agent-scheme--parse-define-values definition))
                  parsed)
            (dolist (name (agent-scheme--define-values-bound-names definition))
              (unless (eq (gethash name
                                    (agent-scheme--environment-bindings
                                     body-environment)
                                    agent-scheme--missing-cell)
                          agent-scheme--missing-cell)
                (agent-scheme--eval-error
                 "duplicate internal definition: %s" name))
              (agent-scheme--environment-define
               body-environment name agent-scheme--undefined)))
           ((agent-scheme--record-definition-form-p definition)
            (push (cons 'record definition) parsed)
            (dolist (name (agent-scheme--record-definition-bound-names
                           definition))
              (unless (eq (gethash name
                                    (agent-scheme--environment-bindings
                                     body-environment)
                                    agent-scheme--missing-cell)
                          agent-scheme--missing-cell)
                (agent-scheme--eval-error
                 "duplicate internal definition: %s" name))
              (agent-scheme--environment-define
               body-environment name agent-scheme--undefined)))))
        (dolist (parsed-definition (nreverse parsed))
          (pcase (car parsed-definition)
            ('define
             (agent-scheme--environment-set-cell
              body-environment
              (cadr parsed-definition)
              (agent-scheme--eval-expression
               (cddr parsed-definition) body-environment context nil)))
            ('define-values
             (let ((define-values (cdr parsed-definition)))
               (agent-scheme--define-values-bind
                (car define-values)
                (agent-scheme--values-list
                 (agent-scheme--eval-expression
                  (cdr define-values) body-environment context nil))
                body-environment
                context
                "define-values")))
            ('record
             (agent-scheme--eval-record-definition
              (cdr parsed-definition) body-environment context))))
        (cons body-environment expressions)))))

(defun agent-scheme--eval-definition
    (form environment context &optional continuation)
  "Evaluate top-level definition FORM in ENVIRONMENT."
  (let* ((parsed (agent-scheme--parse-definition form))
         (name (car parsed))
         (cell (gethash name
                        (agent-scheme--environment-bindings environment)
                        agent-scheme--missing-cell))
         (direct-call (null continuation))
         (next (or continuation #'agent-scheme--identity-continuation)))
    (let ((state
           (agent-scheme--eval-expression
            (cdr parsed)
            environment
            context
            nil
            (lambda (raw-value)
              (let ((value
                     (agent-scheme--single-value
                      raw-value "define initializer")))
                (if (not (eq cell agent-scheme--missing-cell))
                    (progn
                      (when (agent-scheme--current-environment-imported-p
                             environment name)
                        (agent-scheme--eval-error
                         "cannot redefine imported binding: %s" name))
                      (setf (agent-scheme--cell-value cell) value))
                  (agent-scheme--environment-define environment name value))
                (agent-scheme--continue next agent-scheme-unspecified))))))
      (if direct-call
          (agent-scheme--drain-state state context)
        state))))

(defun agent-scheme--parse-define-values (form)
  "Parse supported DEFINE-VALUES FORM.
Return a cons cell (FORMALS . INITIALIZER-EXPRESSION)."
  (let ((parts (agent-scheme--proper-list-elements form "define-values form")))
    (unless (= (length parts) 3)
      (agent-scheme--eval-error
       "define-values requires formals and one expression"))
    (cons (agent-scheme--parse-formals (cadr parts))
          (caddr parts))))

(defun agent-scheme--define-values-bound-names (form)
  "Return names bound by define-values FORM."
  (agent-scheme--formals-names
   (car (agent-scheme--parse-define-values form))))

(defun agent-scheme--define-values-bind
    (formals values environment context description)
  "Bind FORMALS to VALUES in ENVIRONMENT for DESCRIPTION."
  (let* ((required (agent-scheme--formals-required formals))
         (rest (agent-scheme--formals-rest formals))
         (required-count (length required))
         (value-count (length values)))
    (cond
     ((and (null rest) (/= value-count required-count))
      (agent-scheme--eval-error
       "%s expected %d values, got %d"
       description required-count value-count))
     ((and rest (< value-count required-count))
      (agent-scheme--eval-error
       "%s expected at least %d values, got %d"
       description required-count value-count)))
    (let ((remaining values))
      (dolist (name required)
        (agent-scheme--define-or-set-record-binding
         environment name (car remaining))
        (setq remaining (cdr remaining)))
      (when rest
        (agent-scheme--define-or-set-record-binding
         environment rest (copy-sequence remaining))
        (agent-scheme--check-value-budget remaining context)))
    agent-scheme-unspecified))

(defun agent-scheme--eval-define-values
    (form environment context &optional continuation)
  "Evaluate top-level or body define-values FORM in ENVIRONMENT."
  (let* ((parsed (agent-scheme--parse-define-values form))
         (formals (car parsed))
         (initializer (cdr parsed))
         (direct-call (null continuation))
         (next (or continuation #'agent-scheme--identity-continuation))
         (state
          (agent-scheme--eval-expression
           initializer
           environment
           context
           nil
           (lambda (raw-value)
             (agent-scheme--define-values-bind
              formals
              (agent-scheme--values-list raw-value)
              environment
              context
              "define-values")
             (agent-scheme--continue next agent-scheme-unspecified)))))
    (if direct-call
        (agent-scheme--drain-state state context)
      state)))

(defun agent-scheme--bind-formals (formals arguments closure-environment context)
  "Return a call environment for FORMALS bound to ARGUMENTS."
  (let ((environment (agent-scheme-make-empty-environment
                      closure-environment)))
    (agent-scheme--bind-formals-in-environment
     formals arguments environment context "procedure")
    environment))

(defun agent-scheme--bind-formals-in-environment
    (formals arguments environment context description)
  "Bind FORMALS to ARGUMENTS in ENVIRONMENT for DESCRIPTION."
  (let* ((required (agent-scheme--formals-required formals))
         (rest (agent-scheme--formals-rest formals))
         (required-count (length required))
         (argument-count (length arguments)))
    (cond
     ((and (null rest) (/= argument-count required-count))
      (agent-scheme--eval-error
       "%s expected %d values, got %d"
       description
       required-count argument-count))
     ((and rest (< argument-count required-count))
      (agent-scheme--eval-error
       "%s expected at least %d values, got %d"
       description
       required-count argument-count)))
    (let ((remaining arguments))
      (dolist (name required)
        (agent-scheme--environment-define environment name (car remaining))
        (setq remaining (cdr remaining)))
      (when rest
        (agent-scheme--environment-define
         environment rest (copy-sequence remaining))
        (agent-scheme--check-value-budget remaining context))
      environment)))

(defun agent-scheme--formals-names (formals)
  "Return all names bound by FORMALS."
  (if (agent-scheme--formals-rest formals)
      (append (agent-scheme--formals-required formals)
              (list (agent-scheme--formals-rest formals)))
    (agent-scheme--formals-required formals)))

(defun agent-scheme--arity-match-p (primitive count)
  "Return non-nil if PRIMITIVE accepts COUNT arguments."
  (and (>= count
           (agent-scheme-primitive-procedure-minimum-arity primitive))
       (let ((maximum
              (agent-scheme-primitive-procedure-maximum-arity primitive)))
         (or (null maximum) (<= count maximum)))))

(defun agent-scheme--apply-procedure
    (procedure arguments context tailp &optional continuation)
  "Apply PROCEDURE to ARGUMENTS.
When CONTINUATION is non-nil, deliver the result to it.  When it is nil, run
any resulting bounce to preserve existing direct-call helper behavior."
  (let ((direct-call (null continuation))
        (next (or continuation #'agent-scheme--identity-continuation)))
    (cl-labels
        ((finish (state)
           (if direct-call
               (agent-scheme--drain-state state context)
             state)))
      (cond
       ((agent-scheme-primitive-procedure-p procedure)
        (unless (agent-scheme--arity-match-p procedure (length arguments))
          (let ((maximum
                 (agent-scheme-primitive-procedure-maximum-arity procedure)))
            (agent-scheme--eval-error
             "primitive %s expected %s arguments, got %d"
             (agent-scheme-primitive-procedure-name procedure)
             (if maximum
                 (format "%d..%d"
                         (agent-scheme-primitive-procedure-minimum-arity
                          procedure)
                         maximum)
               (format "at least %d"
                       (agent-scheme-primitive-procedure-minimum-arity
                        procedure)))
             (length arguments))))
        (agent-scheme--note-host-callback context procedure)
        (let ((function (agent-scheme-primitive-procedure-function procedure)))
          (finish
           (cond
            ((eq function #'agent-scheme--primitive-apply)
             (agent-scheme--primitive-apply/k arguments context next))
            ((eq function #'agent-scheme--primitive-call-with-values)
             (agent-scheme--primitive-call-with-values/k arguments context next))
            ((eq function #'agent-scheme--primitive-call-with-port)
             (agent-scheme--primitive-call-with-port/k arguments context next))
            ((eq function #'agent-scheme--primitive-call-with-input-file)
             (agent-scheme--primitive-call-with-input-file/k
              arguments context next))
            ((eq function #'agent-scheme--primitive-call-with-output-file)
             (agent-scheme--primitive-call-with-output-file/k
              arguments context next))
            ((eq function #'agent-scheme--primitive-with-input-from-file)
             (agent-scheme--primitive-with-input-from-file/k
              arguments context next))
            ((eq function #'agent-scheme--primitive-with-output-to-file)
             (agent-scheme--primitive-with-output-to-file/k
              arguments context next))
            ((eq function #'agent-scheme--primitive-call/cc)
             (agent-scheme--primitive-call/cc/k arguments context next))
            ((eq function #'agent-scheme--primitive-dynamic-wind)
             (agent-scheme--primitive-dynamic-wind/k arguments context next))
            ((eq function #'agent-scheme--primitive-with-exception-handler)
             (agent-scheme--primitive-with-exception-handler/k
              arguments context next))
            ((eq function #'agent-scheme--primitive-raise-continuable)
             (agent-scheme--primitive-raise-continuable/k
              arguments context next))
            ((eq function #'agent-scheme--primitive-raise)
             (agent-scheme--primitive-raise/k arguments context next))
            ((eq function #'agent-scheme--primitive-error)
             (agent-scheme--primitive-error/k arguments context next))
            ((eq function #'agent-scheme--primitive-eval)
             (agent-scheme--primitive-eval/k arguments context next))
            ((eq function #'agent-scheme--primitive-load)
             (agent-scheme--primitive-load/k arguments context next))
            ((eq function #'agent-scheme--primitive-make-parameter)
             (agent-scheme--primitive-make-parameter/k arguments context next))
            (t
             (agent-scheme--continue
              next
              (agent-scheme--check-value-budget
               (funcall function arguments context)
               context)))))))
       ((agent-scheme-parameter-p procedure)
        (finish
         (agent-scheme--apply-parameter/k procedure arguments context next)))
       ((agent-scheme-procedure-p procedure)
        (let* ((call-environment
                (agent-scheme--bind-formals
                 (agent-scheme-procedure-formals procedure)
                 arguments
                 (agent-scheme-procedure-environment procedure)
                 context))
               (body-state
                (agent-scheme--prepare-body-environment
                 (agent-scheme-procedure-body procedure)
                 call-environment
                 context))
               (body-expression
                (agent-scheme--make-sequence (cdr body-state) nil)))
          (finish
           (agent-scheme--make-bounce
            body-expression
            (car body-state)
            (agent-scheme--eval-context-syntax-environment context)
            next))))
       ((agent-scheme--continuation-p procedure)
        (finish
         (agent-scheme--invoke-continuation procedure arguments context)))
       (t
        (agent-scheme--eval-error
         "attempted to call non-procedure: %s"
         (agent-scheme-value->external procedure)))))))

(defun agent-scheme--eval-if
    (parts environment context tailp continuation)
  "Evaluate an if expression PARTS in ENVIRONMENT."
  (unless (memq (length parts) '(3 4))
    (agent-scheme--eval-error "if requires test, consequent, and optional alternate"))
  (agent-scheme--eval-expression
   (cadr parts)
   environment
   context
   nil
   (lambda (test-result)
     (let ((test-value
            (agent-scheme--single-value test-result "if test")))
       (cond
        ((agent-scheme--true-value-p test-value)
         (if tailp
             (agent-scheme--make-bounce
              (caddr parts)
              environment
              (agent-scheme--eval-context-syntax-environment context)
              continuation)
           (agent-scheme--eval-expression
            (caddr parts) environment context nil continuation)))
        ((= (length parts) 4)
         (if tailp
             (agent-scheme--make-bounce
              (cadddr parts)
              environment
              (agent-scheme--eval-context-syntax-environment context)
              continuation)
           (agent-scheme--eval-expression
            (cadddr parts) environment context nil continuation)))
        (t
         (agent-scheme--continue continuation agent-scheme-unspecified)))))))

(defun agent-scheme--eval-set! (parts environment context continuation)
  "Evaluate a set! expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 3)
    (agent-scheme--eval-error "set! requires an identifier and an expression"))
  (let ((target (cadr parts)))
    (agent-scheme--eval-expression
     (caddr parts)
     environment
     context
     nil
     (lambda (raw-value)
       (let ((value (agent-scheme--single-value raw-value "set! expression")))
         (unless (agent-scheme--identifier-datum-p target)
           (agent-scheme--eval-error "set! target must be an identifier"))
         (agent-scheme--environment-set-identifier environment target value)
         (agent-scheme--continue continuation agent-scheme-unspecified))))))

(defun agent-scheme--eval-quasiquote-list
    (template depth environment context)
  "Evaluate quasiquoted list TEMPLATE at nesting DEPTH."
  (let ((cursor template)
        output)
    (while (consp cursor)
      (let ((element (car cursor)))
        (if (and (= depth 1)
                 (agent-scheme--tagged-list-p element "unquote-splicing"))
            (let ((splice
                   (agent-scheme--single-value
                    (agent-scheme--eval-expression
                     (agent-scheme--single-argument-syntax
                      element "unquote-splicing")
                     environment
                     context
                     nil)
                    "unquote-splicing result")))
              (dolist (splice-element
                       (agent-scheme--proper-list-elements
                        splice "unquote-splicing result"))
                (push splice-element output)))
          (push (agent-scheme--eval-quasiquote-template
                 element depth environment context)
                output)))
      (setq cursor (cdr cursor)))
    (append
     (nreverse output)
     (cond
      ((null cursor) nil)
      ((and (= depth 1)
            (agent-scheme--tagged-list-p cursor "unquote"))
       (agent-scheme--eval-expression
        (agent-scheme--single-argument-syntax cursor "unquote")
        environment
        context
        nil))
      (t
       (agent-scheme--eval-quasiquote-template
        cursor depth environment context))))))

(defun agent-scheme--eval-quasiquote-template
    (template depth environment context)
  "Evaluate quasiquote TEMPLATE at nesting DEPTH."
  (cond
   ((agent-scheme--tagged-list-p template "unquote")
    (let ((operand
           (agent-scheme--single-argument-syntax template "unquote")))
      (if (= depth 1)
          (agent-scheme--single-value
           (agent-scheme--eval-expression operand environment context nil)
           "unquote result")
        (list (car template)
              (agent-scheme--eval-quasiquote-template
               operand (1- depth) environment context)))))
   ((agent-scheme--tagged-list-p template "unquote-splicing")
    (if (= depth 1)
        (agent-scheme--eval-error
         "unquote-splicing is only valid inside a quasiquoted list or vector")
      (let ((operand
             (agent-scheme--single-argument-syntax
              template "unquote-splicing")))
        (list (car template)
              (agent-scheme--eval-quasiquote-template
               operand (1- depth) environment context)))))
   ((agent-scheme--tagged-list-p template "quasiquote")
    (let ((operand
           (agent-scheme--single-argument-syntax template "quasiquote")))
      (list (car template)
            (agent-scheme--eval-quasiquote-template
             operand (1+ depth) environment context))))
   ((consp template)
    (agent-scheme--eval-quasiquote-list
     template depth environment context))
   ((vectorp template)
    (vconcat
     (agent-scheme--eval-quasiquote-list
      (append template nil) depth environment context)))
   (t template)))

(defun agent-scheme--eval-quasiquote (parts environment context)
  "Evaluate a quasiquote expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 2)
    (agent-scheme--eval-error "quasiquote requires exactly one template"))
  (agent-scheme--eval-quasiquote-template
   (cadr parts) 1 environment context))

(defun agent-scheme--parse-letrec-binding (binding description)
  "Return BINDING as (NAME . INITIALIZER) for DESCRIPTION."
  (let ((parts (agent-scheme--proper-list-elements binding description)))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "%s binding must contain an identifier and initializer"
       description))
    (cons (agent-scheme--expect-identifier-key
           (car parts) description)
          (cadr parts))))

(defun agent-scheme--eval-letrec
    (parts environment context tailp sequential &optional continuation)
  "Evaluate letrec or letrec* PARTS in ENVIRONMENT.
When SEQUENTIAL is non-nil, initializer values are installed after
each initializer."
  (unless (>= (length parts) 3)
    (agent-scheme--eval-error
     "%s requires bindings and a body"
     (if sequential "letrec*" "letrec")))
  (let* ((description (if sequential "letrec*" "letrec"))
         (bindings
          (mapcar
           (lambda (binding)
             (agent-scheme--parse-letrec-binding binding description))
           (agent-scheme--proper-list-elements
            (cadr parts) (format "%s binding list" description))))
         (names (mapcar #'car bindings))
         (local-environment
          (agent-scheme-make-empty-environment environment)))
    (agent-scheme--ensure-distinct-names names description)
    (dolist (name names)
      (agent-scheme--environment-define
       local-environment name agent-scheme--undefined))
    (if sequential
        (dolist (binding bindings)
           (agent-scheme--environment-set-cell
            local-environment
            (car binding)
            (agent-scheme--single-value
             (agent-scheme--eval-expression
              (cdr binding) local-environment context nil)
             "letrec* initializer")))
      (let (values)
        (dolist (binding bindings)
          (push
           (cons (car binding)
                 (agent-scheme--single-value
                  (agent-scheme--eval-expression
                   (cdr binding) local-environment context nil)
                  "letrec initializer"))
           values))
        (dolist (binding-value (nreverse values))
          (agent-scheme--environment-set-cell
           local-environment
           (car binding-value)
           (cdr binding-value)))))
    (agent-scheme--eval-sequence
     (cddr parts)
     local-environment
     context
     tailp
     t
     (or continuation #'agent-scheme--identity-continuation))))

(defun agent-scheme--parse-mv-binding (binding description)
  "Return BINDING as (FORMALS . INITIALIZER) for DESCRIPTION."
  (let ((parts (agent-scheme--proper-list-elements binding description)))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "%s binding must contain formals and initializer"
       description))
    (cons (agent-scheme--parse-formals (car parts))
          (cadr parts))))

(defun agent-scheme--eval-let-values
    (parts environment context tailp sequential &optional continuation)
  "Evaluate let-values or let*-values PARTS in ENVIRONMENT."
  (unless (>= (length parts) 3)
    (agent-scheme--eval-error
     "%s requires bindings and a body"
     (if sequential "let*-values" "let-values")))
  (let* ((description (if sequential "let*-values" "let-values"))
         (bindings
          (mapcar
           (lambda (binding)
             (agent-scheme--parse-mv-binding binding description))
           (agent-scheme--proper-list-elements
            (cadr parts) (format "%s binding list" description))))
         (local-environment
          (agent-scheme-make-empty-environment environment)))
    (cl-labels
        ((body ()
           (agent-scheme--eval-sequence
            (cddr parts)
            local-environment
            context
            tailp
            t
            (or continuation #'agent-scheme--identity-continuation)))
         (step-sequential (remaining)
           (if (null remaining)
               (body)
             (let ((binding (car remaining)))
               (agent-scheme--eval-expression
                (cdr binding)
                local-environment
                context
                nil
                (lambda (value)
                  (agent-scheme--bind-formals-in-environment
                   (car binding)
                   (agent-scheme--values-list value)
                   local-environment
                   context
                   description)
                  (step-sequential (cdr remaining)))))))
         (step-parallel (remaining all-names evaluated)
           (if (null remaining)
               (progn
                 (agent-scheme--ensure-distinct-names all-names description)
                 (dolist (binding-values (nreverse evaluated))
                   (agent-scheme--bind-formals-in-environment
                    (car binding-values)
                    (cdr binding-values)
                    local-environment
                    context
                    description))
                 (body))
             (let ((binding (car remaining)))
               (agent-scheme--eval-expression
                (cdr binding)
                environment
                context
                nil
                (lambda (value)
                  (step-parallel
                   (cdr remaining)
                   (append all-names
                           (agent-scheme--formals-names (car binding)))
                   (cons (cons (car binding)
                               (agent-scheme--values-list value))
                         evaluated))))))))
      (let* ((direct-call (null continuation))
             (state (if sequential
                        (step-sequential bindings)
                      (step-parallel bindings nil nil))))
        (if direct-call
            (agent-scheme--drain-state state context)
          state)))))

(defun agent-scheme--eval-arguments
    (operands environment context arguments continuation)
  "Evaluate OPERANDS in order and deliver their single values."
  (if (null operands)
      (agent-scheme--continue continuation (nreverse arguments))
    (agent-scheme--eval-expression
     (car operands)
     environment
     context
     nil
     (lambda (raw-argument)
       (agent-scheme--eval-arguments
        (cdr operands)
        environment
        context
        (cons (agent-scheme--single-value raw-argument "procedure argument")
              arguments)
        continuation)))))

(defun agent-scheme--eval-combination
    (expression environment context tailp continuation)
  "Evaluate list EXPRESSION in ENVIRONMENT."
  (let ((parts (agent-scheme--proper-list-elements expression "expression")))
    (unless parts
      (agent-scheme--eval-error "empty list is not an expression"))
    (let ((operator (car parts)))
      (cond
	       ((and (agent-scheme--symbol-named-p operator "quote")
	             (agent-scheme--special-operator-active-p operator environment))
	        (unless (= (length parts) 2)
	          (agent-scheme--eval-error "quote requires exactly one datum"))
	        (agent-scheme--continue
                 continuation
                 (agent-scheme--check-value-budget (cadr parts) context)))
	       ((and (agent-scheme--symbol-named-p operator "quasiquote")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--continue
                 continuation
                 (agent-scheme--check-value-budget
	          (agent-scheme--eval-quasiquote parts environment context)
	          context)))
	       ((and (agent-scheme--symbol-named-p operator "lambda")
	             (agent-scheme--special-operator-active-p operator environment))
	        (unless (>= (length parts) 3)
	          (agent-scheme--eval-error "lambda requires formals and a body"))
	        (let ((formals (cadr parts))
	              (body (cddr parts)))
	          (agent-scheme--continue
                   continuation
                   (agent-scheme--make-procedure
	            (agent-scheme--parse-formals formals)
	            body
	            environment
                    (agent-scheme--body-documentation body formals)))))
	       ((and (agent-scheme--symbol-named-p operator "if")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-if parts environment context tailp continuation))
	       ((and (agent-scheme--symbol-named-p operator "set!")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-set! parts environment context continuation))
	       ((and (agent-scheme--symbol-named-p operator "let-values")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-let-values
                 parts environment context tailp nil continuation))
	       ((and (agent-scheme--symbol-named-p operator "let*-values")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-let-values
                 parts environment context tailp t continuation))
	       ((and (agent-scheme--symbol-named-p operator "letrec")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-letrec
                 parts environment context tailp nil continuation))
	       ((and (agent-scheme--symbol-named-p operator "letrec*")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-letrec
                 parts environment context tailp t continuation))
       ((and (agent-scheme--symbol-named-p operator "define")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-error "define is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "define-values")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "define-values is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "define-record-type")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "define-record-type is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "define-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "define-syntax is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "define-library")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "define-library is not valid in expression position"))
       ((and (agent-scheme--symbol-named-p operator "import")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--eval-error
         "import is not valid in expression position"))
	       ((and (agent-scheme--symbol-named-p operator "begin")
	             (agent-scheme--special-operator-active-p operator environment))
	        (agent-scheme--eval-sequence
                 (cdr parts) environment context tailp nil continuation))
	       (t
	        (agent-scheme--eval-expression
                 operator
                 environment
                 context
                 nil
                 (lambda (raw-procedure)
                   (let ((procedure
                          (agent-scheme--single-value
                           raw-procedure "procedure operator")))
                     (agent-scheme--eval-arguments
                      (cdr parts)
                      environment
                      context
                      nil
                      (lambda (arguments)
                        (agent-scheme--apply-procedure
                         procedure arguments context tailp continuation)))))))))))

(defun agent-scheme--eval-expression
    (expression environment context tailp &optional continuation)
  "Evaluate EXPRESSION in ENVIRONMENT under CONTEXT.
When TAILP is non-nil, tail calls may return an
`agent-scheme--bounce'."
  (let ((direct-call (null continuation))
        (next (or continuation #'agent-scheme--identity-continuation)))
    (agent-scheme--note-step context)
    (let ((state
           (cond
            ((agent-scheme--sequence-p expression)
             (agent-scheme--eval-sequence
              (agent-scheme--sequence-forms expression)
              environment
              context
              tailp
              (agent-scheme--sequence-allow-definitions expression)
              next))
            ((agent-scheme--syntax-scope-p expression)
             (agent-scheme--with-syntax-environment
              context
              (agent-scheme--syntax-scope-syntax-environment expression)
              (lambda ()
                (agent-scheme--eval-sequence
                 (agent-scheme--syntax-scope-forms expression)
                 environment
                 context
                 tailp
                 t
                 next))))
            ((agent-scheme--self-evaluating-p expression)
             (agent-scheme--continue
              next
              (agent-scheme--check-value-budget expression context)))
            ((agent-scheme--identifier-p expression)
             (agent-scheme--continue
              next
              (agent-scheme--environment-ref-identifier environment expression)))
            ((agent-scheme-symbol-p expression)
             (agent-scheme--continue
              next
              (agent-scheme--environment-ref-identifier environment expression)))
            ((null expression)
             (agent-scheme--eval-error "empty list is not an expression"))
            ((consp expression)
             (let ((expanded (agent-scheme--expand-expression
                              expression environment context)))
               ;; Expansion is interleaved with evaluation so local syntax forms can
               ;; update CONTEXT before the resulting core expression is evaluated.
               (if (eq expanded expression)
                   (agent-scheme--eval-combination
                    expression environment context tailp next)
                 (agent-scheme--eval-expression
                  expanded environment context tailp next))))
            (t
             (agent-scheme--eval-error
              "unsupported expression datum: %S" expression)))))
      (if direct-call
          (agent-scheme--drain-state state context)
        state))))

(defun agent-scheme--eval-sequence
    (forms environment context tailp allow-definitions &optional continuation)
  "Evaluate FORMS sequentially in ENVIRONMENT.
TAILP controls the final form.  ALLOW-DEFINITIONS permits
top-level definition forms within the sequence."
  (let ((next (or continuation #'agent-scheme--identity-continuation)))
    (cl-labels
        ((after-form (value rest imports-open)
           (if rest
               (step rest imports-open)
             (agent-scheme--continue next value)))
         (step (cursor imports-open)
           (if (null cursor)
               (agent-scheme--continue next agent-scheme-unspecified)
             (let* ((form (car cursor))
                    (rest (cdr cursor))
                    (last-form-p (null rest)))
               (cond
                ((agent-scheme--import-form-p form)
                 (unless imports-open
                   (agent-scheme--eval-error
                    "import declarations must precede program body forms"))
                 (if allow-definitions
                     (after-form
                      (agent-scheme--eval-import form environment context)
                      rest
                      t)
                   (agent-scheme--eval-error
                    "import is only allowed at top level or in library bodies")))
                ((agent-scheme--define-library-form-p form)
                 (if allow-definitions
                     (after-form
                      (agent-scheme--eval-define-library
                       form environment context)
                      rest
                      imports-open)
                   (agent-scheme--eval-error
                    "define-library is only allowed at top level")))
                ((agent-scheme--syntax-definition-form-p form)
                 (if allow-definitions
                     (after-form
                      (agent-scheme--eval-define-syntax
                       form
                       environment
                       context
                       (agent-scheme--eval-context-syntax-environment
                        context))
                      rest
                      nil)
                   (agent-scheme--eval-error
                    "define-syntax is only allowed before body expressions")))
                ((agent-scheme--record-definition-form-p form)
                 (if allow-definitions
                     (after-form
                      (agent-scheme--eval-record-definition
                       form environment context)
                      rest
                      nil)
                   (agent-scheme--eval-error
                    "define-record-type is only allowed before body expressions")))
                ((agent-scheme--define-values-form-p form)
                 (if allow-definitions
                     (agent-scheme--eval-define-values
                      form
                      environment
                      context
                      (lambda (value)
                        (after-form value rest nil)))
                   (agent-scheme--eval-error
                    "define-values is only allowed before body expressions")))
                ((agent-scheme--definition-form-p form)
                 (if allow-definitions
                     (agent-scheme--eval-definition
                      form
                      environment
                      context
                      (lambda (value)
                        (after-form value rest nil)))
                   (agent-scheme--eval-error
                    "define is only allowed before body expressions")))
                ((and allow-definitions (agent-scheme--begin-form-p form))
                 (agent-scheme--eval-sequence
                  (cdr (agent-scheme--proper-list-elements form "begin form"))
                  environment
                  context
                  (and last-form-p tailp)
                  t
                  (lambda (value)
                    (after-form value rest nil))))
                (last-form-p
                 (if tailp
                     (agent-scheme--make-bounce
                      form
                      environment
                      (agent-scheme--eval-context-syntax-environment context)
                      next)
                   (agent-scheme--eval-expression
                    form environment context nil next)))
                (t
                 (agent-scheme--eval-expression
                  form
                  environment
                  context
                  nil
                  (lambda (_value)
                    (step rest nil)))))))))
      (step forms t))))

(defun agent-scheme--drain-state (state context)
  "Run trampoline bounces in STATE under CONTEXT."
  (while (agent-scheme--bounce-p state)
    (let ((syntax-environment
           (or (agent-scheme--bounce-syntax-environment state)
               (agent-scheme--eval-context-syntax-environment context)))
          (continuation
           (or (agent-scheme--bounce-continuation state)
               #'agent-scheme--identity-continuation)))
      ;; A bounce carries the value environment, syntax environment, and
      ;; evaluator continuation needed for the next tail step.
      (setq state
            (agent-scheme--with-syntax-environment
             context
             syntax-environment
             (lambda ()
               (agent-scheme--eval-expression
                (agent-scheme--bounce-expression state)
                (agent-scheme--bounce-environment state)
                context
                t
                continuation))))))
  state)

(defun agent-scheme--trampoline (expression environment context)
  "Evaluate EXPRESSION in ENVIRONMENT using CONTEXT's trampoline."
  (let ((state
         (agent-scheme--make-bounce
          expression
          environment
          (agent-scheme--eval-context-syntax-environment context)
          #'agent-scheme--identity-continuation)))
    (setq state (agent-scheme--drain-state state context))
    (agent-scheme--check-value-budget state context)))

(defun agent-scheme--scheme-boolean (value)
  "Return the canonical Scheme boolean for host truth VALUE."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme--number-from-host (number)
  "Return an Agent Scheme number datum for host NUMBER."
  (cond
   ((integerp number)
    (agent-scheme--make-canonical-integer number))
   ((floatp number)
    (agent-scheme--make-canonical-decimal number))
   (t
    (agent-scheme--eval-error "unsupported host number result: %S" number))))

(defun agent-scheme--expect-number (datum description)
  "Return DATUM as a number or signal an error naming DESCRIPTION."
  (unless (agent-scheme-number-p datum)
    (agent-scheme--eval-error
     "%s expected number, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--number-exact-p (datum)
  "Return non-nil if DATUM is an exact number."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-exactness datum) 'exact)))

(defun agent-scheme--number-inexact-p (datum)
  "Return non-nil if DATUM is an inexact number."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-exactness datum) 'inexact)))

(defun agent-scheme--number-nan-p (datum)
  "Return non-nil if DATUM is a NaN value."
  (and (agent-scheme-number-p datum)
       (or (and (eq (agent-scheme-number-kind datum) 'infnan)
                (eq (agent-scheme-number-value datum) '+nan.0))
           (and (eq (agent-scheme-number-kind datum) 'complex)
                (or (agent-scheme--number-nan-p
                     (car (agent-scheme-number-value datum)))
                    (agent-scheme--number-nan-p
                     (cdr (agent-scheme-number-value datum))))))))

(defun agent-scheme--number-infinite-p (datum)
  "Return non-nil if DATUM is an infinity value."
  (and (agent-scheme-number-p datum)
       (or (and (eq (agent-scheme-number-kind datum) 'infnan)
                (memq (agent-scheme-number-value datum) '(+inf.0 -inf.0)))
           (and (eq (agent-scheme-number-kind datum) 'complex)
                (or (agent-scheme--number-infinite-p
                     (car (agent-scheme-number-value datum)))
                    (agent-scheme--number-infinite-p
                     (cdr (agent-scheme-number-value datum))))))))

(defun agent-scheme--number-finite-p (datum)
  "Return non-nil if DATUM is a finite number."
  (and (agent-scheme-number-p datum)
       (not (agent-scheme--number-nan-p datum))
       (not (agent-scheme--number-infinite-p datum))))

(defun agent-scheme--number-exact-zero-p (datum)
  "Return non-nil if DATUM is exactly zero."
  (and (agent-scheme-number-p datum)
       (agent-scheme--number-exact-p datum)
       (agent-scheme--number-zero-p datum)))

(defun agent-scheme--number-real-p (datum)
  "Return non-nil if DATUM is real-valued."
  (and (agent-scheme-number-p datum)
       (or (not (eq (agent-scheme-number-kind datum) 'complex))
           (agent-scheme--number-exact-zero-p
            (cdr (agent-scheme-number-value datum))))))

(defun agent-scheme--number-rational-p (datum)
  "Return non-nil if DATUM is rational-valued."
  (and (agent-scheme--number-real-p datum)
       (let ((real (if (eq (agent-scheme-number-kind datum) 'complex)
                       (car (agent-scheme-number-value datum))
                     datum)))
         (not (eq (agent-scheme-number-kind real) 'infnan)))))

(defun agent-scheme--number-integer-p (datum)
  "Return non-nil if DATUM is integer-valued."
  (and (agent-scheme-number-p datum)
       (cond
        ((eq (agent-scheme-number-kind datum) 'complex)
         (and (agent-scheme--number-exact-zero-p
               (cdr (agent-scheme-number-value datum)))
              (agent-scheme--number-integer-p
               (car (agent-scheme-number-value datum)))))
        ((eq (agent-scheme-number-kind datum) 'integer) t)
        ((eq (agent-scheme-number-kind datum) 'rational)
         (= (cdr (agent-scheme-number-value datum)) 1))
        ((eq (agent-scheme-number-kind datum) 'decimal)
         (let ((value (agent-scheme-number-value datum)))
           (and (floatp value) (= value (ftruncate value)))))
        (t nil))))

(defun agent-scheme--number->rational-pair (datum description)
  "Return exact rational pair for DATUM or signal an error naming DESCRIPTION."
  (setq datum (agent-scheme--expect-number datum description))
  (pcase (agent-scheme-number-kind datum)
    ('integer (cons (agent-scheme-number-value datum) 1))
    ('rational (agent-scheme-number-value datum))
    ('complex
     (if (agent-scheme--number-exact-zero-p
          (cdr (agent-scheme-number-value datum)))
         (agent-scheme--number->rational-pair
          (car (agent-scheme-number-value datum)) description)
       (agent-scheme--eval-error
        "%s expected real number, got %s"
        description
        (agent-scheme-value->external datum))))
    (_
     (agent-scheme--eval-error
      "%s expected exact rational number, got %s"
      description
      (agent-scheme-value->external datum)))))

(defun agent-scheme--number->float (datum description)
  "Return DATUM as a host float or signal an error naming DESCRIPTION."
  (setq datum (agent-scheme--expect-number datum description))
  (pcase (agent-scheme-number-kind datum)
    ('integer (float (agent-scheme-number-value datum)))
    ('rational
     (let ((value (agent-scheme-number-value datum)))
       (/ (float (car value)) (cdr value))))
    ('decimal (agent-scheme-number-value datum))
    ('infnan
     (pcase (agent-scheme-number-value datum)
       ('+inf.0 (/ 1.0 0.0))
       ('-inf.0 (/ -1.0 0.0))
       ('+nan.0 (/ 0.0 0.0))))
    ('complex
     (if (agent-scheme--number-exact-zero-p
          (cdr (agent-scheme-number-value datum)))
         (agent-scheme--number->float
          (car (agent-scheme-number-value datum)) description)
       (agent-scheme--eval-error
        "%s expected real number, got %s"
        description
        (agent-scheme-value->external datum))))))

(defun agent-scheme--number-from-rational-pair
    (pair &optional exactness)
  "Return number datum for rational PAIR and EXACTNESS."
  (let ((number (agent-scheme--make-canonical-rational
                 (car pair) (cdr pair) (or exactness 'exact) 10)))
    (if (eq exactness 'inexact)
        (agent-scheme--make-canonical-decimal
         (/ (float (car pair)) (cdr pair)))
      number)))

(defun agent-scheme--number-inexact (datum)
  "Return an inexact representation of DATUM."
  (setq datum (agent-scheme--expect-number datum "inexact"))
  (pcase (agent-scheme-number-kind datum)
    ((or 'decimal 'infnan) datum)
    ('integer
     (agent-scheme--make-canonical-decimal
      (float (agent-scheme-number-value datum))))
    ('rational
     (let ((value (agent-scheme-number-value datum)))
       (agent-scheme--make-canonical-decimal
        (/ (float (car value)) (cdr value)))))
    ('complex
     (let ((value (agent-scheme-number-value datum)))
       (agent-scheme--make-canonical-complex
        (agent-scheme--number-inexact (car value))
        (agent-scheme--number-inexact (cdr value)))))))

(defun agent-scheme--decimal->exact-rational-pair (number)
  "Return an exact rational approximation for decimal NUMBER."
  (let* ((text (number-to-string number))
         (parsed (agent-scheme-read (concat "#e" text))))
    (agent-scheme--number->rational-pair parsed "exact")))

(defun agent-scheme--number-exact (datum)
  "Return an exact representation of DATUM."
  (setq datum (agent-scheme--expect-number datum "exact"))
  (pcase (agent-scheme-number-kind datum)
    ((or 'integer 'rational) datum)
    ('decimal
     (agent-scheme--number-from-rational-pair
      (agent-scheme--decimal->exact-rational-pair
       (agent-scheme-number-value datum))))
    ('complex
     (let ((value (agent-scheme-number-value datum)))
       (agent-scheme--make-canonical-complex
        (agent-scheme--number-exact (car value))
        (agent-scheme--number-exact (cdr value)))))
    ('infnan
     (agent-scheme--eval-error
      "exact cannot represent %s"
      (agent-scheme-value->external datum)))))

(defun agent-scheme--exact-integer->host (datum description)
  "Return DATUM's exact integer value or signal an error naming DESCRIPTION."
  (unless (and (agent-scheme-number-p datum)
               (eq (agent-scheme-number-kind datum) 'integer)
               (eq (agent-scheme-number-exactness datum) 'exact))
    (agent-scheme--eval-error
     "%s must be an exact integer, got %s"
     description
     (agent-scheme-value->external datum)))
  (agent-scheme-number-value datum))

(defun agent-scheme--expect-nonnegative-index
    (datum limit description &optional allow-end)
  "Return DATUM as a host index below LIMIT.
When ALLOW-END is non-nil, LIMIT itself is accepted."
  (let ((index (agent-scheme--exact-integer->host datum description)))
    (unless (and (<= 0 index)
                 (if allow-end (<= index limit) (< index limit)))
      (agent-scheme--eval-error
       "%s index out of range: %d" description index))
    index))

(defun agent-scheme--expect-byte (datum description)
  "Return DATUM as a byte or signal an error naming DESCRIPTION."
  (let ((byte (agent-scheme--exact-integer->host datum description)))
    (unless (<= 0 byte 255)
      (agent-scheme--eval-error "%s must be in byte range: %d" description byte))
    byte))

(defun agent-scheme--expect-string (datum description)
  "Return DATUM as a string or signal an error naming DESCRIPTION."
  (unless (stringp datum)
    (agent-scheme--eval-error
     "%s must be a string, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--expect-character (datum description)
  "Return DATUM's character code or signal an error naming DESCRIPTION."
  (unless (agent-scheme-character-p datum)
    (agent-scheme--eval-error
     "%s must be a character, got %s"
     description
     (agent-scheme-value->external datum)))
  (agent-scheme-character-code datum))

(defun agent-scheme--valid-scalar-value-p (code)
  "Return non-nil if CODE is a Unicode scalar value."
  (and (integerp code)
       (<= 0 code #x10ffff)
       (not (<= #xd800 code #xdfff))))

(defun agent-scheme--expect-vector (datum description)
  "Return DATUM as a vector or signal an error naming DESCRIPTION."
  (unless (vectorp datum)
    (agent-scheme--eval-error
     "%s must be a vector, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--expect-bytevector (datum description)
  "Return DATUM as a bytevector or signal an error naming DESCRIPTION."
  (unless (agent-scheme-bytevector-p datum)
    (agent-scheme--eval-error
     "%s must be a bytevector, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--expect-procedure (datum description)
  "Return DATUM as a procedure or signal an error naming DESCRIPTION."
  (unless (or (agent-scheme-procedure-p datum)
              (agent-scheme-primitive-procedure-p datum)
              (agent-scheme-parameter-p datum)
              (agent-scheme--continuation-p datum))
    (agent-scheme--eval-error
     "%s must be a procedure, got %s"
     description
     (agent-scheme-value->external datum)))
  datum)

(defun agent-scheme--optional-range (arguments offset length description)
  "Return (START . END) parsed from optional range ARGUMENTS.
OFFSET is the index in ARGUMENTS where START would appear.  LENGTH is
the maximum endpoint for DESCRIPTION."
  (let ((optional-count (- (length arguments) offset)))
    (unless (<= 0 optional-count 2)
      (agent-scheme--eval-error
       "%s expected at most start and end arguments" description))
    (let ((start (if (>= optional-count 1)
                     (agent-scheme--expect-nonnegative-index
                      (nth offset arguments) length description t)
                   0))
          (end (if (>= optional-count 2)
                   (agent-scheme--expect-nonnegative-index
                    (nth (1+ offset) arguments) length description t)
                 length)))
      (when (> start end)
        (agent-scheme--eval-error
         "%s start index exceeds end index" description))
      (cons start end))))

(defun agent-scheme--numeric-arguments (arguments description)
  "Return ARGUMENTS after checking every item is a number for DESCRIPTION."
  (mapcar (lambda (argument)
            (agent-scheme--expect-number argument description))
          arguments))

(defun agent-scheme--number-complex-p (number)
  "Return non-nil if NUMBER has an explicit complex representation."
  (eq (agent-scheme-number-kind number) 'complex))

(defun agent-scheme--complex-parts (number)
  "Return NUMBER as a cons of real and imaginary number parts."
  (if (agent-scheme--number-complex-p number)
      (agent-scheme-number-value number)
    (cons number (agent-scheme--make-canonical-integer 0))))

(defun agent-scheme--any-inexact-number-p (numbers)
  "Return non-nil if any item in NUMBERS is inexact."
  (cl-some #'agent-scheme--number-inexact-p numbers))

(defun agent-scheme--any-complex-number-p (numbers)
  "Return non-nil if any item in NUMBERS is explicitly complex."
  (cl-some #'agent-scheme--number-complex-p numbers))

(defun agent-scheme--binary-rational
    (left right operation description)
  "Apply exact rational OPERATION to LEFT and RIGHT for DESCRIPTION."
  (let* ((left-pair (agent-scheme--number->rational-pair left description))
         (right-pair (agent-scheme--number->rational-pair right description))
         (left-numerator (car left-pair))
         (left-denominator (cdr left-pair))
         (right-numerator (car right-pair))
         (right-denominator (cdr right-pair)))
    (pcase operation
      ('+
       (agent-scheme--number-from-rational-pair
        (cons (+ (* left-numerator right-denominator)
                 (* right-numerator left-denominator))
              (* left-denominator right-denominator))))
      ('-
       (agent-scheme--number-from-rational-pair
        (cons (- (* left-numerator right-denominator)
                 (* right-numerator left-denominator))
              (* left-denominator right-denominator))))
      ('*
       (agent-scheme--number-from-rational-pair
        (cons (* left-numerator right-numerator)
              (* left-denominator right-denominator))))
      ('/
       (when (zerop right-numerator)
         (agent-scheme--eval-error "%s division by zero" description))
       (agent-scheme--number-from-rational-pair
        (cons (* left-numerator right-denominator)
              (* left-denominator right-numerator)))))))

(defun agent-scheme--special-inexact-binary
    (left right operation description)
  "Handle inexact special values for OPERATION, or return nil."
  (cond
   ((or (agent-scheme--number-nan-p left)
        (agent-scheme--number-nan-p right))
    (agent-scheme--make-canonical-infnan '+nan.0))
   ((or (eq (agent-scheme-number-kind left) 'infnan)
        (eq (agent-scheme-number-kind right) 'infnan))
    (let ((left-kind (and (eq (agent-scheme-number-kind left) 'infnan)
                          (agent-scheme-number-value left)))
          (right-kind (and (eq (agent-scheme-number-kind right) 'infnan)
                           (agent-scheme-number-value right))))
      (pcase operation
        ('+
         (cond
          ((and left-kind right-kind (not (eq left-kind right-kind)))
           (agent-scheme--make-canonical-infnan '+nan.0))
          (left-kind left)
          (right-kind right)))
        ('-
         (cond
          ((and left-kind right-kind (eq left-kind right-kind))
           (agent-scheme--make-canonical-infnan '+nan.0))
          (left-kind left)
          ((eq right-kind '+inf.0)
           (agent-scheme--make-canonical-infnan '-inf.0))
          ((eq right-kind '-inf.0)
           (agent-scheme--make-canonical-infnan '+inf.0))))
        (_
         (agent-scheme--number-from-host
          (funcall
           (pcase operation
             ('* #'*)
             ('/ #'/))
           (agent-scheme--number->float left description)
           (agent-scheme--number->float right description)))))))))

(defun agent-scheme--binary-real-number
    (left right operation description)
  "Apply real numeric OPERATION to LEFT and RIGHT for DESCRIPTION."
  (or (agent-scheme--special-inexact-binary
       left right operation description)
      (if (or (agent-scheme--number-inexact-p left)
              (agent-scheme--number-inexact-p right))
          (agent-scheme--make-canonical-decimal
           (funcall
            (pcase operation
              ('+ #'+)
              ('- #'-)
              ('* #'*)
              ('/ #'/))
            (agent-scheme--number->float left description)
            (agent-scheme--number->float right description)))
        (agent-scheme--binary-rational left right operation description))))

(defun agent-scheme--binary-number (left right operation description)
  "Apply numeric OPERATION to LEFT and RIGHT for DESCRIPTION."
  (if (or (agent-scheme--number-complex-p left)
          (agent-scheme--number-complex-p right))
      (let* ((left-parts (agent-scheme--complex-parts left))
             (right-parts (agent-scheme--complex-parts right))
             (a (car left-parts))
             (b (cdr left-parts))
             (c (car right-parts))
             (d (cdr right-parts)))
        (pcase operation
          ('+
           (agent-scheme--make-canonical-complex
            (agent-scheme--binary-number a c '+ description)
            (agent-scheme--binary-number b d '+ description)))
          ('-
           (agent-scheme--make-canonical-complex
            (agent-scheme--binary-number a c '- description)
            (agent-scheme--binary-number b d '- description)))
          ('*
           (agent-scheme--make-canonical-complex
            (agent-scheme--binary-number
             (agent-scheme--binary-number a c '* description)
             (agent-scheme--binary-number b d '* description)
             '-
             description)
            (agent-scheme--binary-number
             (agent-scheme--binary-number a d '* description)
             (agent-scheme--binary-number b c '* description)
             '+
             description)))
          ('/
           (let ((denominator
                  (agent-scheme--binary-number
                   (agent-scheme--binary-number c c '* description)
                   (agent-scheme--binary-number d d '* description)
                   '+
                   description)))
             (when (agent-scheme--number-zero-p denominator)
               (agent-scheme--eval-error "%s division by zero" description))
             (agent-scheme--make-canonical-complex
              (agent-scheme--binary-number
               (agent-scheme--binary-number
                (agent-scheme--binary-number a c '* description)
                (agent-scheme--binary-number b d '* description)
                '+
                description)
               denominator
               '/
               description)
              (agent-scheme--binary-number
               (agent-scheme--binary-number
                (agent-scheme--binary-number b c '* description)
                (agent-scheme--binary-number a d '* description)
                '-
                description)
               denominator
               '/
               description))))))
    (agent-scheme--binary-real-number left right operation description)))

(defun agent-scheme--fold-numbers
    (arguments identity operation description &optional unary-inverse)
  "Fold ARGUMENTS with numeric OPERATION and IDENTITY for DESCRIPTION."
  (let ((numbers (agent-scheme--numeric-arguments arguments description)))
    (cond
     ((null numbers) identity)
     ((and unary-inverse (= (length numbers) 1))
      (funcall unary-inverse (car numbers)))
     (t
      (let ((result (car numbers)))
        (dolist (number (cdr numbers))
          (setq result
                (agent-scheme--binary-number
                 result number operation description)))
        result)))))

(defun agent-scheme--primitive+ (arguments _context)
  "Primitive + over ARGUMENTS."
  (agent-scheme--fold-numbers
   arguments (agent-scheme--make-canonical-integer 0) '+ "+"))

(defun agent-scheme--primitive* (arguments _context)
  "Primitive * over ARGUMENTS."
  (agent-scheme--fold-numbers
   arguments (agent-scheme--make-canonical-integer 1) '* "*"))

(defun agent-scheme--primitive- (arguments _context)
  "Primitive - over ARGUMENTS."
  (agent-scheme--fold-numbers
   arguments
   nil
   '-
   "-"
   (lambda (number)
     (agent-scheme--binary-number
      (agent-scheme--make-canonical-integer 0) number '- "-"))))

(defun agent-scheme--primitive/ (arguments _context)
  "Primitive / over ARGUMENTS."
  (agent-scheme--fold-numbers
   arguments
   nil
   '/
   "/"
   (lambda (number)
     (agent-scheme--binary-number
      (agent-scheme--make-canonical-integer 1) number '/ "/"))))

(defun agent-scheme--number-real-part-for-ordering (number description)
  "Return real part of NUMBER suitable for ordering predicates."
  (setq number (agent-scheme--expect-number number description))
  (if (agent-scheme--number-complex-p number)
      (if (agent-scheme--number-exact-zero-p
           (cdr (agent-scheme-number-value number)))
          (car (agent-scheme-number-value number))
        (agent-scheme--eval-error
         "%s expected real number, got %s"
         description
         (agent-scheme-value->external number)))
    number))

(defun agent-scheme--number=2 (left right)
  "Return non-nil if LEFT and RIGHT are numerically equal."
  (cond
   ((or (agent-scheme--number-nan-p left)
        (agent-scheme--number-nan-p right))
    nil)
   ((or (agent-scheme--number-complex-p left)
        (agent-scheme--number-complex-p right))
    (let ((left-parts (agent-scheme--complex-parts left))
          (right-parts (agent-scheme--complex-parts right)))
      (and (agent-scheme--number=2 (car left-parts) (car right-parts))
           (agent-scheme--number=2 (cdr left-parts) (cdr right-parts)))))
   ((or (eq (agent-scheme-number-kind left) 'infnan)
        (eq (agent-scheme-number-kind right) 'infnan))
    (and (eq (agent-scheme-number-kind left) 'infnan)
         (eq (agent-scheme-number-kind right) 'infnan)
         (eq (agent-scheme-number-value left)
             (agent-scheme-number-value right))))
   ((or (agent-scheme--number-inexact-p left)
        (agent-scheme--number-inexact-p right))
    (= (agent-scheme--number->float left "=")
       (agent-scheme--number->float right "=")))
   (t
    (let ((left-pair (agent-scheme--number->rational-pair left "="))
          (right-pair (agent-scheme--number->rational-pair right "=")))
      (= (* (car left-pair) (cdr right-pair))
         (* (car right-pair) (cdr left-pair)))))))

(defun agent-scheme--number-order2 (left right predicate description)
  "Return PREDICATE result for real LEFT and RIGHT."
  (setq left (agent-scheme--number-real-part-for-ordering left description))
  (setq right (agent-scheme--number-real-part-for-ordering right description))
  (cond
   ((or (agent-scheme--number-nan-p left)
        (agent-scheme--number-nan-p right))
    nil)
   ((or (agent-scheme--number-inexact-p left)
        (agent-scheme--number-inexact-p right)
        (eq (agent-scheme-number-kind left) 'infnan)
        (eq (agent-scheme-number-kind right) 'infnan))
    (let ((left-key (agent-scheme--number->float left description))
          (right-key (agent-scheme--number->float right description)))
      (funcall predicate left-key right-key)))
   (t
    (let ((left-pair (agent-scheme--number->rational-pair left description))
          (right-pair (agent-scheme--number->rational-pair right description)))
      (funcall predicate
               (* (car left-pair) (cdr right-pair))
               (* (car right-pair) (cdr left-pair)))))))

(defun agent-scheme--primitive-compare (arguments predicate description)
  "Return Scheme boolean for pairwise PREDICATE over ARGUMENTS."
  (let ((numbers (agent-scheme--numeric-arguments arguments description))
        (ok t))
    (while (and ok (cdr numbers))
      (setq ok (if (eq predicate #'=)
                   (agent-scheme--number=2 (car numbers) (cadr numbers))
                 (agent-scheme--number-order2
                  (car numbers) (cadr numbers) predicate description)))
      (setq numbers (cdr numbers)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive= (arguments _context)
  "Primitive numeric = over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'= "="))

(defun agent-scheme--primitive< (arguments _context)
  "Primitive numeric < over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'< "<"))

(defun agent-scheme--primitive> (arguments _context)
  "Primitive numeric > over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'> ">"))

(defun agent-scheme--primitive<= (arguments _context)
  "Primitive numeric <= over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'<= "<="))

(defun agent-scheme--primitive>= (arguments _context)
  "Primitive numeric >= over ARGUMENTS."
  (agent-scheme--primitive-compare arguments #'>= ">="))

(defun agent-scheme--primitive-abs (arguments _context)
  "Primitive abs over ARGUMENTS."
  (let ((number (agent-scheme--expect-number (car arguments) "abs")))
    (if (agent-scheme--number-complex-p number)
        (agent-scheme--eval-error
         "abs expected real number, got %s"
         (agent-scheme-value->external number))
      (agent-scheme--number-abs number))))

(defun agent-scheme--primitive-min (arguments _context)
  "Primitive min over ARGUMENTS."
  (let* ((numbers (agent-scheme--numeric-arguments arguments "min"))
         (inexact (agent-scheme--any-inexact-number-p numbers))
         (best (car numbers)))
    (dolist (number (cdr numbers))
      (when (eq (agent-scheme--primitive-compare
                 (list number best) #'< "min")
                agent-scheme-true)
        (setq best number)))
    (if inexact (agent-scheme--number-inexact best) best)))

(defun agent-scheme--primitive-max (arguments _context)
  "Primitive max over ARGUMENTS."
  (let* ((numbers (agent-scheme--numeric-arguments arguments "max"))
         (inexact (agent-scheme--any-inexact-number-p numbers))
         (best (car numbers)))
    (dolist (number (cdr numbers))
      (when (eq (agent-scheme--primitive-compare
                 (list number best) #'> "max")
                agent-scheme-true)
        (setq best number)))
    (if inexact (agent-scheme--number-inexact best) best)))

(defun agent-scheme--primitive-square (arguments _context)
  "Primitive square over ARGUMENTS."
  (let ((number (agent-scheme--expect-number (car arguments) "square")))
    (agent-scheme--binary-number number number '* "square")))

(defun agent-scheme--primitive-zero? (arguments _context)
  "Primitive zero? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-zero-p
    (agent-scheme--expect-number (car arguments) "zero?"))))

(defun agent-scheme--primitive-positive? (arguments _context)
  "Primitive positive? over ARGUMENTS."
  (agent-scheme--primitive-compare
   (list (car arguments) (agent-scheme--make-canonical-integer 0))
   #'>
   "positive?"))

(defun agent-scheme--primitive-negative? (arguments _context)
  "Primitive negative? over ARGUMENTS."
  (agent-scheme--primitive-compare
   (list (car arguments) (agent-scheme--make-canonical-integer 0))
   #'<
   "negative?"))

(defun agent-scheme--primitive-odd? (arguments _context)
  "Primitive odd? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (cl-oddp (agent-scheme--exact-integer->host (car arguments) "odd?"))))

(defun agent-scheme--primitive-even? (arguments _context)
  "Primitive even? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (cl-evenp (agent-scheme--exact-integer->host (car arguments) "even?"))))

(defun agent-scheme--primitive-integer-quotient
    (arguments quotient-function description)
  "Return integer quotient over ARGUMENTS using QUOTIENT-FUNCTION."
  (let ((left (agent-scheme--exact-integer->host
               (car arguments) description))
        (right (agent-scheme--exact-integer->host
                (cadr arguments) description)))
    (when (zerop right)
      (agent-scheme--eval-error "%s division by zero" description))
    (agent-scheme--make-canonical-integer
     (funcall quotient-function left right))))

(defun agent-scheme--primitive-quotient (arguments _context)
  "Primitive quotient over ARGUMENTS."
  (agent-scheme--primitive-integer-quotient
   arguments #'truncate "quotient"))

(defun agent-scheme--primitive-floor-quotient (arguments _context)
  "Primitive floor-quotient over ARGUMENTS."
  (agent-scheme--primitive-integer-quotient
   arguments #'floor "floor-quotient"))

(defun agent-scheme--primitive-truncate-quotient (arguments _context)
  "Primitive truncate-quotient over ARGUMENTS."
  (agent-scheme--primitive-integer-quotient
   arguments #'agent-scheme--truncate-quotient-value "truncate-quotient"))

(defun agent-scheme--truncate-quotient-value (left right)
  "Return integer quotient of LEFT over RIGHT truncated toward zero."
  (let ((quotient (/ (abs left) (abs right))))
    (if (= (cl-signum left) (cl-signum right))
        quotient
      (- quotient))))

(defun agent-scheme--modulo-value (left right)
  "Return Scheme modulo for host integers LEFT and RIGHT."
  (let ((remainder (% left right)))
    (if (or (zerop remainder)
            (= (cl-signum remainder) (cl-signum right)))
        remainder
      (+ remainder right))))

(defun agent-scheme--primitive-remainder (arguments _context)
  "Primitive remainder over ARGUMENTS."
  (let ((left (agent-scheme--exact-integer->host
               (car arguments) "remainder"))
        (right (agent-scheme--exact-integer->host
                (cadr arguments) "remainder")))
    (when (zerop right)
      (agent-scheme--eval-error "remainder division by zero"))
    (agent-scheme--make-canonical-integer
     (agent-scheme--truncate-remainder-value left right))))

(defun agent-scheme--truncate-remainder-value (left right)
  "Return integer remainder of LEFT over RIGHT truncated toward zero."
  (- left (* right (agent-scheme--truncate-quotient-value left right))))

(defun agent-scheme--primitive-modulo (arguments _context)
  "Primitive modulo over ARGUMENTS."
  (let ((left (agent-scheme--exact-integer->host (car arguments) "modulo"))
        (right (agent-scheme--exact-integer->host (cadr arguments) "modulo")))
    (when (zerop right)
      (agent-scheme--eval-error "modulo division by zero"))
    (agent-scheme--make-canonical-integer
     (agent-scheme--modulo-value left right))))

(defun agent-scheme--primitive-floor-remainder (arguments context)
  "Primitive floor-remainder over ARGUMENTS."
  (agent-scheme--primitive-modulo arguments context))

(defun agent-scheme--primitive-truncate-remainder (arguments context)
  "Primitive truncate-remainder over ARGUMENTS."
  (agent-scheme--primitive-remainder arguments context))

(defun agent-scheme--floor-rational-pair (pair)
  "Return floor of exact rational PAIR."
  (floor (car pair) (cdr pair)))

(defun agent-scheme--ceiling-rational-pair (pair)
  "Return ceiling of exact rational PAIR."
  (ceiling (car pair) (cdr pair)))

(defun agent-scheme--truncate-rational-pair (pair)
  "Return truncation of exact rational PAIR toward zero."
  (let* ((numerator (car pair))
         (denominator (cdr pair))
         (quotient (/ (abs numerator) denominator)))
    (if (< numerator 0) (- quotient) quotient)))

(defun agent-scheme--round-rational-pair (pair)
  "Return rounded exact rational PAIR using ties-to-even."
  (let* ((numerator (car pair))
         (denominator (cdr pair))
         (sign (cl-signum numerator))
         (absolute (abs numerator))
         (quotient (/ absolute denominator))
         (remainder (% absolute denominator))
         (twice (* 2 remainder))
         (rounded
          (cond
           ((< twice denominator) quotient)
           ((> twice denominator) (1+ quotient))
           ((cl-evenp quotient) quotient)
           (t (1+ quotient)))))
    (* sign rounded)))

(defun agent-scheme--primitive-rounding (arguments function description)
  "Apply unary numeric rounding FUNCTION to ARGUMENTS for DESCRIPTION."
  (let ((number (agent-scheme--number-real-part-for-ordering
                 (car arguments) description)))
    (pcase (agent-scheme-number-kind number)
      ((or 'integer 'rational)
       (agent-scheme--make-canonical-integer
        (funcall function
                 (agent-scheme--number->rational-pair number description))))
      ('decimal
       (agent-scheme--make-canonical-decimal
        (float (funcall
                function
                (agent-scheme--decimal->exact-rational-pair
                 (agent-scheme-number-value number))))))
      ('infnan number))))

(defun agent-scheme--primitive-floor (arguments _context)
  "Primitive floor over ARGUMENTS."
  (agent-scheme--primitive-rounding
   arguments #'agent-scheme--floor-rational-pair "floor"))

(defun agent-scheme--primitive-ceiling (arguments _context)
  "Primitive ceiling over ARGUMENTS."
  (agent-scheme--primitive-rounding
   arguments #'agent-scheme--ceiling-rational-pair "ceiling"))

(defun agent-scheme--primitive-truncate (arguments _context)
  "Primitive truncate over ARGUMENTS."
  (agent-scheme--primitive-rounding
   arguments #'agent-scheme--truncate-rational-pair "truncate"))

(defun agent-scheme--primitive-round (arguments _context)
  "Primitive round over ARGUMENTS."
  (agent-scheme--primitive-rounding
   arguments #'agent-scheme--round-rational-pair "round"))

(defun agent-scheme--integer-argument (datum description)
  "Return integer value of DATUM or signal an error naming DESCRIPTION."
  (setq datum (agent-scheme--expect-number datum description))
  (cond
   ((and (agent-scheme--number-exact-p datum)
         (agent-scheme--number-integer-p datum))
    (car (agent-scheme--number->rational-pair datum description)))
   ((and (agent-scheme--number-inexact-p datum)
         (agent-scheme--number-integer-p datum))
    (truncate (agent-scheme--number->float datum description)))
   (t
    (agent-scheme--eval-error
     "%s expected integer, got %s"
     description
     (agent-scheme-value->external datum)))))

(defun agent-scheme--primitive-gcd (arguments _context)
  "Primitive gcd over ARGUMENTS."
  (let ((numbers (agent-scheme--numeric-arguments arguments "gcd"))
        (result 0)
        inexact)
    (dolist (number numbers)
      (setq inexact (or inexact (agent-scheme--number-inexact-p number)))
      (setq result
            (agent-scheme--integer-gcd
             result
             (agent-scheme--integer-argument number "gcd"))))
    (let ((value (agent-scheme--make-canonical-integer result)))
      (if inexact (agent-scheme--number-inexact value) value))))

(defun agent-scheme--primitive-lcm (arguments _context)
  "Primitive lcm over ARGUMENTS."
  (let ((numbers (agent-scheme--numeric-arguments arguments "lcm"))
        (result 1)
        inexact)
    (dolist (number numbers)
      (let ((value (abs (agent-scheme--integer-argument number "lcm"))))
        (setq inexact (or inexact (agent-scheme--number-inexact-p number)))
        (setq result
              (if (or (zerop result) (zerop value))
                  0
                (/ (* result value)
                   (agent-scheme--integer-gcd result value))))))
    (let ((value (agent-scheme--make-canonical-integer result)))
      (if inexact (agent-scheme--number-inexact value) value))))

(defun agent-scheme--primitive-numerator (arguments _context)
  "Primitive numerator over ARGUMENTS."
  (let* ((number (agent-scheme--expect-number (car arguments) "numerator"))
         (pair (if (agent-scheme--number-inexact-p number)
                   (agent-scheme--decimal->exact-rational-pair
                    (agent-scheme--number->float number "numerator"))
                 (agent-scheme--number->rational-pair number "numerator")))
         (value (agent-scheme--make-canonical-integer (car pair))))
    (if (agent-scheme--number-inexact-p number)
        (agent-scheme--number-inexact value)
      value)))

(defun agent-scheme--primitive-denominator (arguments _context)
  "Primitive denominator over ARGUMENTS."
  (let* ((number (agent-scheme--expect-number (car arguments) "denominator"))
         (pair (if (agent-scheme--number-inexact-p number)
                   (agent-scheme--decimal->exact-rational-pair
                    (agent-scheme--number->float number "denominator"))
                 (agent-scheme--number->rational-pair number "denominator")))
         (value (agent-scheme--make-canonical-integer (cdr pair))))
    (if (agent-scheme--number-inexact-p number)
        (agent-scheme--number-inexact value)
      value)))

(defun agent-scheme--primitive-exact (arguments _context)
  "Primitive exact over ARGUMENTS."
  (agent-scheme--number-exact (car arguments)))

(defun agent-scheme--primitive-inexact (arguments _context)
  "Primitive inexact over ARGUMENTS."
  (agent-scheme--number-inexact (car arguments)))

(defun agent-scheme--primitive-expt (arguments _context)
  "Primitive expt over ARGUMENTS."
  (let ((base (agent-scheme--expect-number (car arguments) "expt"))
        (power (agent-scheme--expect-number (cadr arguments) "expt")))
    (if (and (agent-scheme--number-exact-p base)
             (agent-scheme--number-exact-p power)
             (agent-scheme--number-integer-p power)
             (not (agent-scheme--number-complex-p base)))
        (let* ((base-pair (agent-scheme--number->rational-pair base "expt"))
               (exponent (car (agent-scheme--number->rational-pair
                               power "expt")))
               (numerator (agent-scheme--integer-power
                           (car base-pair) (abs exponent)))
               (denominator (agent-scheme--integer-power
                             (cdr base-pair) (abs exponent))))
          (if (>= exponent 0)
              (agent-scheme--number-from-rational-pair
               (cons numerator denominator))
            (agent-scheme--number-from-rational-pair
             (cons denominator numerator))))
      (agent-scheme--make-canonical-decimal
       (expt (agent-scheme--number->float base "expt")
             (agent-scheme--number->float power "expt"))))))

(defun agent-scheme--integer-sqrt (value)
  "Return floor square root of non-negative integer VALUE."
  (let ((low 0)
        (high (1+ value)))
    (while (> (- high low) 1)
      (let ((mid (/ (+ low high) 2)))
        (if (> (* mid mid) value)
            (setq high mid)
          (setq low mid))))
    low))

(defun agent-scheme--primitive-exact-integer-sqrt (arguments _context)
  "Primitive exact-integer-sqrt over ARGUMENTS."
  (let ((value (agent-scheme--exact-integer->host
                (car arguments) "exact-integer-sqrt")))
    (when (< value 0)
      (agent-scheme--eval-error
       "exact-integer-sqrt expected non-negative integer"))
    (let ((root (agent-scheme--integer-sqrt value)))
      (agent-scheme--make-multiple-values
       (list (agent-scheme--make-canonical-integer root)
             (agent-scheme--make-canonical-integer
              (- value (* root root))))))))

(defun agent-scheme--primitive-floor/ (arguments _context)
  "Primitive floor/ over ARGUMENTS."
  (let ((left (agent-scheme--exact-integer->host (car arguments) "floor/"))
        (right (agent-scheme--exact-integer->host (cadr arguments) "floor/")))
    (when (zerop right)
      (agent-scheme--eval-error "floor/ division by zero"))
    (let* ((quotient (floor left right))
           (remainder (- left (* right quotient))))
      (agent-scheme--make-multiple-values
       (list (agent-scheme--make-canonical-integer quotient)
             (agent-scheme--make-canonical-integer remainder))))))

(defun agent-scheme--primitive-truncate/ (arguments _context)
  "Primitive truncate/ over ARGUMENTS."
  (let ((left (agent-scheme--exact-integer->host (car arguments) "truncate/"))
        (right (agent-scheme--exact-integer->host
                (cadr arguments) "truncate/")))
    (when (zerop right)
      (agent-scheme--eval-error "truncate/ division by zero"))
    (let* ((quotient (agent-scheme--truncate-quotient-value left right))
           (remainder (- left (* right quotient))))
      (agent-scheme--make-multiple-values
       (list (agent-scheme--make-canonical-integer quotient)
             (agent-scheme--make-canonical-integer remainder))))))

(defun agent-scheme--primitive-rationalize (arguments _context)
  "Primitive rationalize over ARGUMENTS."
  (let* ((x (agent-scheme--expect-number (car arguments) "rationalize"))
         (y (agent-scheme--expect-number (cadr arguments) "rationalize"))
         (inexact (or (agent-scheme--number-inexact-p x)
                      (agent-scheme--number-inexact-p y)))
         (x-pair (if (agent-scheme--number-inexact-p x)
                     (agent-scheme--decimal->exact-rational-pair
                      (agent-scheme--number->float x "rationalize"))
                   (agent-scheme--number->rational-pair x "rationalize")))
         (y-pair (if (agent-scheme--number-inexact-p y)
                     (agent-scheme--decimal->exact-rational-pair
                      (agent-scheme--number->float y "rationalize"))
                   (agent-scheme--number->rational-pair y "rationalize")))
         (result
          (agent-scheme--rationalize-pair x-pair y-pair)))
    (if inexact
        (agent-scheme--number-inexact
         (agent-scheme--number-from-rational-pair result))
      (agent-scheme--number-from-rational-pair result))))

(defun agent-scheme--rational-pair< (left right)
  "Return non-nil if rational pair LEFT is less than RIGHT."
  (< (* (car left) (cdr right))
     (* (car right) (cdr left))))

(defun agent-scheme--rational-pair= (left right)
  "Return non-nil if rational pair LEFT equals RIGHT."
  (= (* (car left) (cdr right))
     (* (car right) (cdr left))))

(defun agent-scheme--rational-pair-normalize (pair)
  "Normalize rational PAIR."
  (agent-scheme--normalize-rational-pair (car pair) (cdr pair)))

(defun agent-scheme--rational-pair-negate (pair)
  "Return negated rational PAIR."
  (cons (- (car pair)) (cdr pair)))

(defun agent-scheme--rational-pair+ (left right)
  "Return LEFT plus RIGHT as a rational pair."
  (agent-scheme--rational-pair-normalize
   (cons (+ (* (car left) (cdr right))
            (* (car right) (cdr left)))
         (* (cdr left) (cdr right)))))

(defun agent-scheme--rational-pair- (left right)
  "Return LEFT minus RIGHT as a rational pair."
  (agent-scheme--rational-pair+
   left (agent-scheme--rational-pair-negate right)))

(defun agent-scheme--rational-pair-reciprocal (pair)
  "Return reciprocal of rational PAIR."
  (agent-scheme--rational-pair-normalize
   (cons (cdr pair) (car pair))))

(defun agent-scheme--rational-pair-integer-p (pair)
  "Return non-nil if rational PAIR is integral."
  (= (cdr pair) 1))

(defun agent-scheme--simplest-positive-rational-pair (lower upper)
  "Return simplest rational pair in the positive interval LOWER to UPPER."
  (cond
   ((not (agent-scheme--rational-pair<
          (cons 0 1) lower))
    (cons 0 1))
   ((agent-scheme--rational-pair-integer-p lower)
    lower)
   (t
    (let ((lower-floor (floor (car lower) (cdr lower)))
          (upper-floor (floor (car upper) (cdr upper))))
      (if (< lower-floor upper-floor)
          (cons (1+ lower-floor) 1)
        (agent-scheme--rational-pair+
         (cons lower-floor 1)
         (agent-scheme--rational-pair-reciprocal
          (agent-scheme--simplest-positive-rational-pair
           (agent-scheme--rational-pair-reciprocal
            (agent-scheme--rational-pair-
             upper (cons upper-floor 1)))
           (agent-scheme--rational-pair-reciprocal
            (agent-scheme--rational-pair-
             lower (cons lower-floor 1)))))))))))

(defun agent-scheme--simplest-rational-pair (lower upper)
  "Return simplest rational pair in interval LOWER to UPPER."
  (cond
   ((agent-scheme--rational-pair< upper lower)
    (agent-scheme--eval-error "rationalize tolerance produced empty interval"))
   ((not (agent-scheme--rational-pair< (cons 0 1) lower))
    (if (not (agent-scheme--rational-pair< upper (cons 0 1)))
        (cons 0 1)
      (agent-scheme--rational-pair-negate
       (agent-scheme--simplest-positive-rational-pair
        (agent-scheme--rational-pair-negate upper)
        (agent-scheme--rational-pair-negate lower)))))
   (t
    (agent-scheme--simplest-positive-rational-pair lower upper))))

(defun agent-scheme--rationalize-pair (x y)
  "Return the simplest rational pair within Y of X."
  (agent-scheme--simplest-rational-pair
   (agent-scheme--rational-pair- x y)
   (agent-scheme--rational-pair+ x y)))

(defun agent-scheme--primitive-finite? (arguments _context)
  "Primitive finite? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-finite-p
    (agent-scheme--expect-number (car arguments) "finite?"))))

(defun agent-scheme--primitive-infinite? (arguments _context)
  "Primitive infinite? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-infinite-p
    (agent-scheme--expect-number (car arguments) "infinite?"))))

(defun agent-scheme--primitive-nan? (arguments _context)
  "Primitive nan? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-nan-p
    (agent-scheme--expect-number (car arguments) "nan?"))))

(defun agent-scheme--primitive-inexact-unary
    (arguments function description)
  "Apply real-valued inexact FUNCTION to ARGUMENTS for DESCRIPTION."
  (agent-scheme--make-canonical-decimal
   (funcall function
            (agent-scheme--number->float (car arguments) description))))

(defun agent-scheme--primitive-exp (arguments _context)
  "Primitive exp over ARGUMENTS."
  (agent-scheme--primitive-inexact-unary arguments #'exp "exp"))

(defun agent-scheme--primitive-log (arguments _context)
  "Primitive log over ARGUMENTS."
  (let ((value (agent-scheme--primitive-inexact-unary
                (list (car arguments)) #'log "log")))
    (if (cdr arguments)
        (let ((base (agent-scheme--primitive-inexact-unary
                     (list (cadr arguments)) #'log "log")))
          (agent-scheme--primitive/
           (list value base) nil))
      value)))

(defun agent-scheme--primitive-sin (arguments _context)
  "Primitive sin over ARGUMENTS."
  (agent-scheme--primitive-inexact-unary arguments #'sin "sin"))

(defun agent-scheme--primitive-cos (arguments _context)
  "Primitive cos over ARGUMENTS."
  (agent-scheme--primitive-inexact-unary arguments #'cos "cos"))

(defun agent-scheme--primitive-tan (arguments _context)
  "Primitive tan over ARGUMENTS."
  (agent-scheme--primitive-inexact-unary arguments #'tan "tan"))

(defun agent-scheme--primitive-asin (arguments _context)
  "Primitive asin over ARGUMENTS."
  (agent-scheme--primitive-inexact-unary arguments #'asin "asin"))

(defun agent-scheme--primitive-acos (arguments _context)
  "Primitive acos over ARGUMENTS."
  (agent-scheme--primitive-inexact-unary arguments #'acos "acos"))

(defun agent-scheme--primitive-atan (arguments _context)
  "Primitive atan over ARGUMENTS."
  (if (cdr arguments)
      (agent-scheme--make-canonical-decimal
       (atan (agent-scheme--number->float (car arguments) "atan")
             (agent-scheme--number->float (cadr arguments) "atan")))
    (agent-scheme--primitive-inexact-unary arguments #'atan "atan")))

(defun agent-scheme--primitive-sqrt (arguments _context)
  "Primitive sqrt over ARGUMENTS."
  (let* ((number (agent-scheme--expect-number (car arguments) "sqrt"))
         (value (agent-scheme--number->float number "sqrt")))
    (if (and (not (agent-scheme--number-complex-p number))
             (< value 0.0))
        (agent-scheme--make-canonical-complex
         (agent-scheme--make-canonical-decimal 0.0)
         (agent-scheme--make-canonical-decimal (sqrt (- value))))
      (agent-scheme--make-canonical-decimal (sqrt value)))))

(defun agent-scheme--apply-parameter/k
    (parameter arguments context continuation)
  "Apply PARAMETER to ARGUMENTS and continue with CONTINUATION."
  (cond
   ((null arguments)
    (agent-scheme--continue
     continuation
     (agent-scheme-parameter-value parameter)))
   ((cdr arguments)
    (agent-scheme--eval-error
     "parameter expected 0..1 arguments, got %d" (length arguments)))
   ((agent-scheme-parameter-converter parameter)
    (agent-scheme--apply-procedure
     (agent-scheme-parameter-converter parameter)
     (list (car arguments))
     context
     nil
     (lambda (converted)
       (setf (agent-scheme-parameter-value parameter)
             (agent-scheme--single-value converted "parameter converter"))
       (agent-scheme--continue continuation agent-scheme-unspecified))))
   (t
    (setf (agent-scheme-parameter-value parameter) (car arguments))
    (agent-scheme--continue continuation agent-scheme-unspecified))))

(defun agent-scheme--primitive-make-parameter (arguments context)
  "Primitive make-parameter over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-make-parameter/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-make-parameter/k
    (arguments context continuation)
  "CPS primitive make-parameter over ARGUMENTS."
  (let ((initial (car arguments))
        (converter (cadr arguments)))
    (if converter
        (progn
          (unless (or (agent-scheme-procedure-p converter)
                      (agent-scheme-primitive-procedure-p converter)
                      (agent-scheme--continuation-p converter)
                      (agent-scheme-parameter-p converter))
            (agent-scheme--eval-error
             "make-parameter converter must be a procedure"))
          (agent-scheme--apply-procedure
           converter
           (list initial)
           context
           nil
           (lambda (converted)
             (agent-scheme--continue
              continuation
              (agent-scheme--make-parameter
               (agent-scheme--single-value
                converted "make-parameter converter")
               converter)))))
      (agent-scheme--continue
       continuation
       (agent-scheme--make-parameter initial nil)))))

(defun agent-scheme--primitive-make-rectangular (arguments _context)
  "Primitive make-rectangular over ARGUMENTS."
  (agent-scheme--make-canonical-complex
   (agent-scheme--expect-number (car arguments) "make-rectangular")
   (agent-scheme--expect-number (cadr arguments) "make-rectangular")))

(defun agent-scheme--primitive-make-polar (arguments _context)
  "Primitive make-polar over ARGUMENTS."
  (let ((magnitude (agent-scheme--number->float
                    (car arguments) "make-polar"))
        (angle (agent-scheme--number->float
                (cadr arguments) "make-polar")))
    (agent-scheme--make-canonical-complex
     (agent-scheme--make-canonical-decimal (* magnitude (cos angle)))
     (agent-scheme--make-canonical-decimal (* magnitude (sin angle))))))

(defun agent-scheme--primitive-real-part (arguments _context)
  "Primitive real-part over ARGUMENTS."
  (let ((number (agent-scheme--expect-number (car arguments) "real-part")))
    (if (agent-scheme--number-complex-p number)
        (car (agent-scheme-number-value number))
      number)))

(defun agent-scheme--primitive-imag-part (arguments _context)
  "Primitive imag-part over ARGUMENTS."
  (let ((number (agent-scheme--expect-number (car arguments) "imag-part")))
    (if (agent-scheme--number-complex-p number)
        (cdr (agent-scheme-number-value number))
      (agent-scheme--make-canonical-integer 0))))

(defun agent-scheme--primitive-magnitude (arguments _context)
  "Primitive magnitude over ARGUMENTS."
  (let ((number (agent-scheme--expect-number (car arguments) "magnitude")))
    (if (agent-scheme--number-complex-p number)
        (let* ((parts (agent-scheme-number-value number))
               (real (agent-scheme--number->float (car parts) "magnitude"))
               (imaginary (agent-scheme--number->float
                           (cdr parts) "magnitude")))
          (agent-scheme--make-canonical-decimal
           (sqrt (+ (* real real) (* imaginary imaginary)))))
      (agent-scheme--number-abs number))))

(defun agent-scheme--primitive-angle (arguments _context)
  "Primitive angle over ARGUMENTS."
  (let ((number (agent-scheme--expect-number (car arguments) "angle")))
    (if (agent-scheme--number-complex-p number)
        (let* ((parts (agent-scheme-number-value number))
               (real (agent-scheme--number->float (car parts) "angle"))
               (imaginary (agent-scheme--number->float
                           (cdr parts) "angle")))
          (agent-scheme--make-canonical-decimal (atan imaginary real)))
      (if (agent-scheme--number-negative-p number)
          (agent-scheme--make-canonical-decimal float-pi)
        (agent-scheme--make-canonical-decimal 0.0)))))

(defun agent-scheme--primitive-cons (arguments _context)
  "Primitive cons over ARGUMENTS."
  (cons (car arguments) (cadr arguments)))

(defun agent-scheme--primitive-car (arguments _context)
  "Primitive car over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "car expected pair, got %s" (agent-scheme-value->external pair)))
    (car pair)))

(defun agent-scheme--primitive-cdr (arguments _context)
  "Primitive cdr over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "cdr expected pair, got %s" (agent-scheme-value->external pair)))
    (cdr pair)))

(defun agent-scheme--primitive-list (arguments _context)
  "Primitive list over ARGUMENTS."
  (copy-sequence arguments))

(defun agent-scheme--primitive-null? (arguments _context)
  "Primitive null? over ARGUMENTS."
  (if (null (car arguments)) agent-scheme-true agent-scheme-false))

(defun agent-scheme--primitive-pair? (arguments _context)
  "Primitive pair? over ARGUMENTS."
  (if (consp (car arguments)) agent-scheme-true agent-scheme-false))

(defun agent-scheme--primitive-not (arguments _context)
  "Primitive not over ARGUMENTS."
  (if (eq (car arguments) agent-scheme-false)
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-boolean? (arguments _context)
  "Primitive boolean? over ARGUMENTS."
  (if (or (eq (car arguments) agent-scheme-true)
          (eq (car arguments) agent-scheme-false))
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-number? (arguments _context)
  "Primitive number? over ARGUMENTS."
  (if (agent-scheme-number-p (car arguments))
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-symbol? (arguments _context)
  "Primitive symbol? over ARGUMENTS."
  (if (agent-scheme-symbol-p (car arguments))
      agent-scheme-true
    agent-scheme-false))

(defun agent-scheme--primitive-procedure? (arguments _context)
  "Primitive procedure? over ARGUMENTS."
  (let ((value (car arguments)))
    (if (or (agent-scheme-procedure-p value)
            (agent-scheme-primitive-procedure-p value)
            (agent-scheme-parameter-p value)
            (agent-scheme--continuation-p value))
        agent-scheme-true
      agent-scheme-false)))

(defun agent-scheme--proper-list-p (value)
  "Return non-nil when VALUE is a proper finite list."
  (let ((seen (make-hash-table :test #'eq))
        (cursor value)
        proper)
    (catch 'done
      (while t
        (cond
         ((null cursor)
          (setq proper t)
          (throw 'done nil))
         ((not (consp cursor))
          (setq proper nil)
          (throw 'done nil))
         ((gethash cursor seen)
          (setq proper nil)
          (throw 'done nil))
         (t
          (puthash cursor t seen)
          (setq cursor (cdr cursor))))))
    proper))

(defun agent-scheme--primitive-list? (arguments _context)
  "Primitive list? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--proper-list-p (car arguments))))

(defun agent-scheme--primitive-length (arguments _context)
  "Primitive length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length (agent-scheme--proper-list-elements (car arguments) "length"))))

(defun agent-scheme--primitive-append (arguments _context)
  "Primitive append over ARGUMENTS."
  (cond
   ((null arguments) nil)
   ((null (cdr arguments)) (car arguments))
   (t
    (let ((prefixes nil)
          (last-tail (car (last arguments))))
      (dolist (list (butlast arguments))
        (push (agent-scheme--proper-list-elements list "append argument")
              prefixes))
      (apply #'append (append (nreverse prefixes) (list last-tail)))))))

(defun agent-scheme--primitive-reverse (arguments _context)
  "Primitive reverse over ARGUMENTS."
  (reverse (agent-scheme--proper-list-elements (car arguments) "reverse")))

(defun agent-scheme--primitive-list-tail (arguments _context)
  "Primitive list-tail over ARGUMENTS."
  (let ((cursor (car arguments))
        (index (agent-scheme--exact-integer->host
                (cadr arguments) "list-tail")))
    (when (< index 0)
      (agent-scheme--eval-error "list-tail index must be non-negative"))
    (dotimes (_ index)
      (unless (consp cursor)
        (agent-scheme--eval-error "list-tail index exceeds list length"))
      (setq cursor (cdr cursor)))
    cursor))

(defun agent-scheme--primitive-list-ref (arguments _context)
  "Primitive list-ref over ARGUMENTS."
  (let ((tail (agent-scheme--primitive-list-tail arguments nil)))
    (unless (consp tail)
      (agent-scheme--eval-error "list-ref index exceeds list length"))
    (car tail)))

(defun agent-scheme--primitive-list-set! (arguments _context)
  "Primitive list-set! over ARGUMENTS."
  (let ((tail (agent-scheme--primitive-list-tail arguments nil)))
    (unless (consp tail)
      (agent-scheme--eval-error "list-set! index exceeds list length"))
    (setcar tail (caddr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-set-car! (arguments _context)
  "Primitive set-car! over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "set-car! expected pair, got %s"
       (agent-scheme-value->external pair)))
    (setcar pair (cadr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-set-cdr! (arguments _context)
  "Primitive set-cdr! over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (agent-scheme--eval-error
       "set-cdr! expected pair, got %s"
       (agent-scheme-value->external pair)))
    (setcdr pair (cadr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-make-list (arguments _context)
  "Primitive make-list over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-list"))
         (fill (if (cdr arguments) (cadr arguments) agent-scheme-unspecified)))
    (when (< length 0)
      (agent-scheme--eval-error "make-list length must be non-negative"))
    (make-list length fill)))

(defun agent-scheme--primitive-list-copy (arguments _context)
  "Primitive list-copy over ARGUMENTS."
  (let ((value (car arguments)))
    (if (agent-scheme--proper-list-p value)
        (copy-sequence value)
      value)))

(defun agent-scheme--eqv-p (left right)
  "Return non-nil if LEFT and RIGHT are eqv? under the current value model."
  (cond
   ((eq left right) t)
   ((and (agent-scheme-number-p left) (agent-scheme-number-p right))
    (and (eq (agent-scheme-number-kind left)
             (agent-scheme-number-kind right))
         (eq (agent-scheme-number-exactness left)
             (agent-scheme-number-exactness right))
         (equal (agent-scheme-number-value left)
                (agent-scheme-number-value right))))
   ((and (agent-scheme-character-p left) (agent-scheme-character-p right))
    (= (agent-scheme-character-code left)
       (agent-scheme-character-code right)))
   ((and (agent-scheme-symbol-p left) (agent-scheme-symbol-p right))
    (equal (agent-scheme-symbol-name left)
           (agent-scheme-symbol-name right)))
   (t nil)))

(defun agent-scheme--eq-p (left right)
  "Return non-nil if LEFT and RIGHT are eq? under the current value model."
  (or (eq left right)
      (and (or (agent-scheme-number-p left)
               (agent-scheme-character-p left)
               (agent-scheme-symbol-p left))
           (agent-scheme--eqv-p left right))))

(defun agent-scheme--equal-seen-p (left right seen)
  "Return non-nil when LEFT and RIGHT were already compared in SEEN."
  (memq right (gethash left seen)))

(defun agent-scheme--equal-remember (left right seen)
  "Remember that LEFT and RIGHT are being compared in SEEN."
  (puthash left (cons right (gethash left seen)) seen))

(defun agent-scheme--equal-p (left right seen)
  "Return non-nil if LEFT and RIGHT are equal?.
SEEN tracks compound value identity pairs already compared."
  (cond
   ((agent-scheme--eqv-p left right) t)
   ((and (stringp left) (stringp right))
    (equal left right))
   ((and (agent-scheme-bytevector-p left)
         (agent-scheme-bytevector-p right))
    (equal (agent-scheme-bytevector-bytes left)
           (agent-scheme-bytevector-bytes right)))
   ((and (consp left) (consp right))
    (or (agent-scheme--equal-seen-p left right seen)
        (progn
          (agent-scheme--equal-remember left right seen)
          (and (agent-scheme--equal-p (car left) (car right) seen)
               (agent-scheme--equal-p (cdr left) (cdr right) seen)))))
   ((and (vectorp left) (vectorp right)
         (= (length left) (length right)))
    (or (agent-scheme--equal-seen-p left right seen)
        (progn
          (agent-scheme--equal-remember left right seen)
          (let ((index 0)
                (ok t))
            (while (and ok (< index (length left)))
              (setq ok (agent-scheme--equal-p
                        (aref left index) (aref right index) seen))
              (cl-incf index))
            ok))))
   (t nil)))

(defun agent-scheme--primitive-eq? (arguments _context)
  "Primitive eq? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--eq-p (car arguments) (cadr arguments))))

(defun agent-scheme--primitive-eqv? (arguments _context)
  "Primitive eqv? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--eqv-p (car arguments) (cadr arguments))))

(defun agent-scheme--primitive-equal? (arguments _context)
  "Primitive equal? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--equal-p
    (car arguments) (cadr arguments) (make-hash-table :test #'eq))))

(defun agent-scheme--list-member (object list predicate description)
  "Return member sublist for OBJECT in LIST using PREDICATE.
DESCRIPTION names the primitive for errors."
  (let ((cursor list)
        found)
    (while (and (consp cursor) (not found))
      (if (funcall predicate object (car cursor))
          (setq found cursor)
        (setq cursor (cdr cursor))))
    (cond
     (found found)
     ((null cursor) agent-scheme-false)
     (t
      (agent-scheme--eval-error "%s expected a proper list" description)))))

(defun agent-scheme--primitive-memq (arguments _context)
  "Primitive memq over ARGUMENTS."
  (agent-scheme--list-member
   (car arguments) (cadr arguments) #'agent-scheme--eq-p "memq"))

(defun agent-scheme--primitive-memv (arguments _context)
  "Primitive memv over ARGUMENTS."
  (agent-scheme--list-member
   (car arguments) (cadr arguments) #'agent-scheme--eqv-p "memv"))

(defun agent-scheme--primitive-member (arguments _context)
  "Primitive member over ARGUMENTS."
  (agent-scheme--list-member
   (car arguments)
   (cadr arguments)
   (lambda (left right)
     (agent-scheme--equal-p left right (make-hash-table :test #'eq)))
   "member"))

(defun agent-scheme--alist-assoc (object alist predicate description)
  "Return association for OBJECT in ALIST using PREDICATE."
  (let ((cursor alist)
        found)
    (while (and (consp cursor) (not found))
      (let ((entry (car cursor)))
        (unless (consp entry)
          (agent-scheme--eval-error "%s expected pair entries" description))
        (if (funcall predicate object (car entry))
            (setq found entry)
          (setq cursor (cdr cursor)))))
    (cond
     (found found)
     ((null cursor) agent-scheme-false)
     (t
      (agent-scheme--eval-error "%s expected a proper alist" description)))))

(defun agent-scheme--primitive-assq (arguments _context)
  "Primitive assq over ARGUMENTS."
  (agent-scheme--alist-assoc
   (car arguments) (cadr arguments) #'agent-scheme--eq-p "assq"))

(defun agent-scheme--primitive-assv (arguments _context)
  "Primitive assv over ARGUMENTS."
  (agent-scheme--alist-assoc
   (car arguments) (cadr arguments) #'agent-scheme--eqv-p "assv"))

(defun agent-scheme--primitive-assoc (arguments _context)
  "Primitive assoc over ARGUMENTS."
  (agent-scheme--alist-assoc
   (car arguments)
   (cadr arguments)
   (lambda (left right)
     (agent-scheme--equal-p left right (make-hash-table :test #'eq)))
   "assoc"))

(defun agent-scheme--primitive-caar (arguments _context)
  "Primitive caar over ARGUMENTS."
  (agent-scheme--primitive-car
   (list (agent-scheme--primitive-car arguments nil)) nil))

(defun agent-scheme--primitive-cadr (arguments _context)
  "Primitive cadr over ARGUMENTS."
  (agent-scheme--primitive-car
   (list (agent-scheme--primitive-cdr arguments nil)) nil))

(defun agent-scheme--primitive-cdar (arguments _context)
  "Primitive cdar over ARGUMENTS."
  (agent-scheme--primitive-cdr
   (list (agent-scheme--primitive-car arguments nil)) nil))

(defun agent-scheme--primitive-cddr (arguments _context)
  "Primitive cddr over ARGUMENTS."
  (agent-scheme--primitive-cdr
   (list (agent-scheme--primitive-cdr arguments nil)) nil))

(defun agent-scheme--primitive-boolean=? (arguments _context)
  "Primitive boolean=? over ARGUMENTS."
  (let ((first (car arguments))
        (rest (cdr arguments))
        (ok t))
    (unless (or (eq first agent-scheme-true)
                (eq first agent-scheme-false))
      (agent-scheme--eval-error "boolean=? expected booleans"))
    (while (and ok rest)
      (let ((value (car rest)))
        (unless (or (eq value agent-scheme-true)
                    (eq value agent-scheme-false))
          (agent-scheme--eval-error "boolean=? expected booleans"))
        (setq ok (eq first value)))
      (setq rest (cdr rest)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-complex? (arguments _context)
  "Primitive complex? over ARGUMENTS."
  (agent-scheme--scheme-boolean (agent-scheme-number-p (car arguments))))

(defun agent-scheme--primitive-real? (arguments _context)
  "Primitive real? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-real-p (car arguments))))

(defun agent-scheme--primitive-rational? (arguments _context)
  "Primitive rational? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-rational-p (car arguments))))

(defun agent-scheme--primitive-integer? (arguments _context)
  "Primitive integer? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-integer-p (car arguments))))

(defun agent-scheme--primitive-exact-integer? (arguments _context)
  "Primitive exact-integer? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme--number-integer-p (car arguments))
        (agent-scheme--number-exact-p (car arguments)))))

(defun agent-scheme--primitive-exact? (arguments _context)
  "Primitive exact? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-exact-p (car arguments))))

(defun agent-scheme--primitive-inexact? (arguments _context)
  "Primitive inexact? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--number-inexact-p (car arguments))))

(defun agent-scheme--integer->radix-string (integer radix)
  "Return INTEGER formatted in RADIX."
  (let ((digits "0123456789abcdef")
        (value (abs integer))
        result)
    (if (zerop value)
        (setq result "0")
      (while (> value 0)
        (push (aref digits (% value radix)) result)
        (setq value (/ value radix)))
      (setq result (apply #'string result)))
    (if (< integer 0)
        (concat "-" result)
      result)))

(defun agent-scheme--number->string (number radix)
  "Return external numeric string for NUMBER in RADIX."
  (pcase (agent-scheme-number-kind number)
    ('integer
     (agent-scheme--integer->radix-string
      (agent-scheme-number-value number) radix))
    ('rational
     (let ((value (agent-scheme-number-value number)))
       (concat
        (agent-scheme--integer->radix-string (car value) radix)
        "/"
        (agent-scheme--integer->radix-string (cdr value) radix))))
    ((or 'decimal 'infnan)
     (unless (= radix 10)
       (agent-scheme--eval-error
        "number->string only supports radix 10 for inexact numbers"))
     (agent-scheme--number->external number))
    ('complex
     (unless (= radix 10)
       (agent-scheme--eval-error
        "number->string only supports radix 10 for complex numbers"))
     (agent-scheme--number->external number))))

(defun agent-scheme--primitive-number->string (arguments _context)
  "Primitive number->string over ARGUMENTS."
  (let ((number (agent-scheme--expect-number
                 (car arguments) "number->string"))
        (radix (if (cdr arguments)
                   (agent-scheme--exact-integer->host
                    (cadr arguments) "number->string radix")
                 10)))
    (unless (memq radix '(2 8 10 16))
      (agent-scheme--eval-error "number->string radix must be 2, 8, 10, or 16"))
    (agent-scheme--number->string number radix)))

(defun agent-scheme--primitive-string->number (arguments _context)
  "Primitive string->number over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string
                  (car arguments) "string->number"))
         (radix (if (cdr arguments)
                    (agent-scheme--exact-integer->host
                     (cadr arguments) "string->number radix")
                  10))
         (source (if (or (not (cdr arguments))
                         (string-match-p "\\`#[bodxei]" (downcase string)))
                     string
                   (concat
                    (pcase radix
                      (2 "#b")
                      (8 "#o")
                      (10 "#d")
                      (16 "#x")
                      (_
                       (agent-scheme--eval-error
                        "string->number radix must be 2, 8, 10, or 16")))
                    string)))
         (value (condition-case nil
                    (agent-scheme-read source)
                  (agent-scheme-reader-error nil))))
    (if (agent-scheme-number-p value)
        value
      agent-scheme-false)))

(defun agent-scheme--primitive-symbol->string (arguments _context)
  "Primitive symbol->string over ARGUMENTS."
  (unless (agent-scheme-symbol-p (car arguments))
    (agent-scheme--eval-error "symbol->string expected a symbol"))
  (copy-sequence (agent-scheme-symbol-name (car arguments))))

(defun agent-scheme--primitive-string->symbol (arguments _context)
  "Primitive string->symbol over ARGUMENTS."
  (agent-scheme--intern-symbol
   (agent-scheme--expect-string (car arguments) "string->symbol")))

(defun agent-scheme--primitive-symbol=? (arguments _context)
  "Primitive symbol=? over ARGUMENTS."
  (let ((first (car arguments))
        (rest (cdr arguments))
        (ok t))
    (unless (agent-scheme-symbol-p first)
      (agent-scheme--eval-error "symbol=? expected symbols"))
    (while (and ok rest)
      (let ((value (car rest)))
        (unless (agent-scheme-symbol-p value)
          (agent-scheme--eval-error "symbol=? expected symbols"))
        (setq ok (equal (agent-scheme-symbol-name first)
                        (agent-scheme-symbol-name value))))
      (setq rest (cdr rest)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-char? (arguments _context)
  "Primitive char? over ARGUMENTS."
  (agent-scheme--scheme-boolean (agent-scheme-character-p (car arguments))))

(defun agent-scheme--primitive-char->integer (arguments _context)
  "Primitive char->integer over ARGUMENTS."
  (agent-scheme--number-from-host
   (agent-scheme--expect-character (car arguments) "char->integer")))

(defun agent-scheme--primitive-integer->char (arguments _context)
  "Primitive integer->char over ARGUMENTS."
  (let ((code (agent-scheme--exact-integer->host
               (car arguments) "integer->char")))
    (unless (agent-scheme--valid-scalar-value-p code)
      (agent-scheme--eval-error "integer->char expected a scalar value"))
    (agent-scheme--make-character code)))

(defun agent-scheme--primitive-char-compare (arguments predicate description)
  "Return Scheme boolean for pairwise character PREDICATE over ARGUMENTS."
  (let ((codes (mapcar
                (lambda (argument)
                  (agent-scheme--expect-character argument description))
                arguments))
        (ok t))
    (while (and ok (cdr codes))
      (setq ok (funcall predicate (car codes) (cadr codes)))
      (setq codes (cdr codes)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-char=? (arguments _context)
  "Primitive char=? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'= "char=?"))

(defun agent-scheme--primitive-char<? (arguments _context)
  "Primitive char<? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'< "char<?"))

(defun agent-scheme--primitive-char>? (arguments _context)
  "Primitive char>? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'> "char>?"))

(defun agent-scheme--primitive-char<=? (arguments _context)
  "Primitive char<=? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'<= "char<=?"))

(defun agent-scheme--primitive-char>=? (arguments _context)
  "Primitive char>=? over ARGUMENTS."
  (agent-scheme--primitive-char-compare arguments #'>= "char>=?"))

(defun agent-scheme--primitive-char-upcase (arguments _context)
  "Primitive char-upcase over ARGUMENTS."
  (let ((code (agent-scheme--expect-character
               (car arguments) "char-upcase")))
    (agent-scheme--make-character (upcase code))))

(defun agent-scheme--primitive-char-downcase (arguments _context)
  "Primitive char-downcase over ARGUMENTS."
  (let ((code (agent-scheme--expect-character
               (car arguments) "char-downcase")))
    (agent-scheme--make-character (downcase code))))

(defun agent-scheme--primitive-char-foldcase (arguments _context)
  "Primitive char-foldcase over ARGUMENTS."
  (let ((code (agent-scheme--expect-character
               (car arguments) "char-foldcase")))
    (agent-scheme--make-character (downcase (upcase code)))))

(defun agent-scheme--character-matches-p (code regexp)
  "Return non-nil if CODE's string representation matches REGEXP."
  (string-match-p regexp (char-to-string code)))

(defun agent-scheme--primitive-char-alphabetic? (arguments _context)
  "Primitive char-alphabetic? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--character-matches-p
    (agent-scheme--expect-character (car arguments) "char-alphabetic?")
    "\\`[[:alpha:]]\\'")))

(defun agent-scheme--primitive-char-numeric? (arguments _context)
  "Primitive char-numeric? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--character-matches-p
    (agent-scheme--expect-character (car arguments) "char-numeric?")
    "\\`[[:digit:]]\\'")))

(defun agent-scheme--primitive-char-whitespace? (arguments _context)
  "Primitive char-whitespace? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme--character-matches-p
    (agent-scheme--expect-character (car arguments) "char-whitespace?")
    "\\`[[:space:]]\\'")))

(defun agent-scheme--primitive-char-upper-case? (arguments _context)
  "Primitive char-upper-case? over ARGUMENTS."
  (let ((code (agent-scheme--expect-character
               (car arguments) "char-upper-case?")))
    (agent-scheme--scheme-boolean
     (and (agent-scheme--character-matches-p code "\\`[[:alpha:]]\\'")
          (= code (upcase code))
          (/= code (downcase code))))))

(defun agent-scheme--primitive-char-lower-case? (arguments _context)
  "Primitive char-lower-case? over ARGUMENTS."
  (let ((code (agent-scheme--expect-character
               (car arguments) "char-lower-case?")))
    (agent-scheme--scheme-boolean
     (and (agent-scheme--character-matches-p code "\\`[[:alpha:]]\\'")
          (= code (downcase code))
          (/= code (upcase code))))))

(defun agent-scheme--primitive-digit-value (arguments _context)
  "Primitive digit-value over ARGUMENTS."
  (let ((code (agent-scheme--expect-character (car arguments) "digit-value")))
    (if (and (>= code ?0) (<= code ?9))
        (agent-scheme--make-canonical-integer (- code ?0))
      agent-scheme-false)))

(defun agent-scheme--char-fold-code (value description)
  "Return folded character code for VALUE using DESCRIPTION."
  (downcase
   (upcase
    (agent-scheme--expect-character value description))))

(defun agent-scheme--primitive-char-ci-compare
    (arguments predicate description)
  "Return Scheme boolean for folded character PREDICATE over ARGUMENTS."
  (agent-scheme--primitive-char-compare
   (mapcar
    (lambda (argument)
      (agent-scheme--make-character
       (agent-scheme--char-fold-code argument description)))
    arguments)
   predicate
   description))

(defun agent-scheme--primitive-char-ci=? (arguments _context)
  "Primitive char-ci=? over ARGUMENTS."
  (agent-scheme--primitive-char-ci-compare arguments #'= "char-ci=?"))

(defun agent-scheme--primitive-char-ci<? (arguments _context)
  "Primitive char-ci<? over ARGUMENTS."
  (agent-scheme--primitive-char-ci-compare arguments #'< "char-ci<?"))

(defun agent-scheme--primitive-char-ci>? (arguments _context)
  "Primitive char-ci>? over ARGUMENTS."
  (agent-scheme--primitive-char-ci-compare arguments #'> "char-ci>?"))

(defun agent-scheme--primitive-char-ci<=? (arguments _context)
  "Primitive char-ci<=? over ARGUMENTS."
  (agent-scheme--primitive-char-ci-compare arguments #'<= "char-ci<=?"))

(defun agent-scheme--primitive-char-ci>=? (arguments _context)
  "Primitive char-ci>=? over ARGUMENTS."
  (agent-scheme--primitive-char-ci-compare arguments #'>= "char-ci>=?"))

(defun agent-scheme--display-string (value)
  "Return a focused display representation for VALUE."
  (agent-scheme-datum->external value 'write t))

(defun agent-scheme--expect-port (value description)
  "Return VALUE as an Agent Scheme port for DESCRIPTION."
  (unless (agent-scheme--port-p value)
    (agent-scheme--eval-error "%s expected a port" description))
  value)

(defun agent-scheme--expect-open-port (value description)
  "Return VALUE as an open port for DESCRIPTION."
  (let ((port (agent-scheme--expect-port value description)))
    (unless (agent-scheme--port-openp port)
      (if (agent-scheme--port-backing-domain port)
          (progn
            (agent-scheme-capability-audit-port-result
             port 'use "closed port capability handle" t)
            (signal 'agent-scheme-capability-grant-error
                    (list "stale port capability handle: closed port")))
        (agent-scheme--eval-error "%s expected an open port" description)))
    port))

(defun agent-scheme--expect-input-port (value description)
  "Return VALUE as an open input port for DESCRIPTION."
  (let ((port (agent-scheme--expect-open-port value description)))
    (unless (agent-scheme--port-inputp port)
      (agent-scheme--eval-error "%s expected an input port" description))
    port))

(defun agent-scheme--expect-output-port (value description)
  "Return VALUE as an open output port for DESCRIPTION."
  (let ((port (agent-scheme--expect-open-port value description)))
    (unless (agent-scheme--port-outputp port)
      (agent-scheme--eval-error "%s expected an output port" description))
    port))

(defun agent-scheme--expect-textual-input-port (value description)
  "Return VALUE as an open textual input port for DESCRIPTION."
  (let ((port (agent-scheme--expect-input-port value description)))
    (unless (agent-scheme--port-textualp port)
      (agent-scheme--eval-error "%s expected a textual input port" description))
    port))

(defun agent-scheme--expect-textual-output-port (value description)
  "Return VALUE as an open textual output port for DESCRIPTION."
  (let ((port (agent-scheme--expect-output-port value description)))
    (unless (agent-scheme--port-textualp port)
      (agent-scheme--eval-error "%s expected a textual output port" description))
    port))

(defun agent-scheme--expect-binary-input-port (value description)
  "Return VALUE as an open binary input port for DESCRIPTION."
  (let ((port (agent-scheme--expect-input-port value description)))
    (unless (agent-scheme--port-binaryp port)
      (agent-scheme--eval-error "%s expected a binary input port" description))
    port))

(defun agent-scheme--expect-binary-output-port (value description)
  "Return VALUE as an open binary output port for DESCRIPTION."
  (let ((port (agent-scheme--expect-output-port value description)))
    (unless (agent-scheme--port-binaryp port)
      (agent-scheme--eval-error "%s expected a binary output port" description))
    port))

(defun agent-scheme--expect-string-output-port (value description)
  "Return VALUE as an open output string port for DESCRIPTION."
  (let ((port (agent-scheme--expect-textual-output-port value description)))
    (unless (eq (agent-scheme--port-medium port) 'string)
      (agent-scheme--eval-error "%s expected an output string port" description))
    port))

(defun agent-scheme--expect-bytevector-output-port (value description)
  "Return VALUE as an open output bytevector port for DESCRIPTION."
  (let ((port (agent-scheme--expect-binary-output-port value description)))
    (unless (eq (agent-scheme--port-medium port) 'bytevector)
      (agent-scheme--eval-error
       "%s expected an output bytevector port" description))
    port))

(defun agent-scheme--port-capability-check
    (port context operation)
  "Revalidate PORT for host-backed OPERATION in CONTEXT."
  (agent-scheme-capability-revalidate-port-operation
   port context operation))

(defun agent-scheme--current-input-port-or-deny (context description)
  "Return CONTEXT's current input port or deny host default access."
  (or (and context (agent-scheme--eval-context-current-input-port context))
      (agent-scheme--policy-denied description context)))

(defun agent-scheme--current-output-port-or-deny (context description)
  "Return CONTEXT's current output port or deny host default access."
  (or (and context (agent-scheme--eval-context-current-output-port context))
      (agent-scheme--policy-denied description context)))

(defun agent-scheme--primitive-current-input-port (_arguments context)
  "Primitive current-input-port."
  (agent-scheme--current-input-port-or-deny context "current-input-port"))

(defun agent-scheme--primitive-current-output-port (_arguments context)
  "Primitive current-output-port."
  (agent-scheme--current-output-port-or-deny context "current-output-port"))

(defun agent-scheme--primitive-current-error-port (_arguments context)
  "Primitive current-error-port."
  (agent-scheme--policy-denied "current-error-port" context))

(defun agent-scheme--write-text-to-port (text port description &optional context)
  "Append TEXT to textual output PORT for DESCRIPTION."
  (let ((output (agent-scheme--expect-textual-output-port port description)))
    (unless (memq (agent-scheme--port-medium output) '(string file process))
      (agent-scheme--eval-error
       "%s host textual output ports are not available" description))
    (agent-scheme--port-capability-check output context 'write)
    (setf (agent-scheme--port-contents output)
          (concat (agent-scheme--port-contents output) text))
    (agent-scheme-capability-audit-port-result
     output 'write (length text)))
  agent-scheme-unspecified)

(defun agent-scheme--write-to-output-port
    (value port mode displayp &optional context)
  "Write VALUE to PORT using MODE and display rendering when DISPLAYP is non-nil."
  (agent-scheme--write-text-to-port
   (if displayp
       (agent-scheme--display-string value)
     (agent-scheme-datum->external value mode))
   port
   (if displayp "display" "write")
   context))

(defun agent-scheme--primitive-eof-object? (arguments _context)
  "Primitive eof-object? over ARGUMENTS."
  (agent-scheme--scheme-boolean (agent-scheme-eof-object-p (car arguments))))

(defun agent-scheme--primitive-eof-object (_arguments _context)
  "Primitive eof-object."
  agent-scheme-eof-object)

(defun agent-scheme--primitive-port? (arguments _context)
  "Primitive port? over ARGUMENTS."
  (agent-scheme--scheme-boolean (agent-scheme--port-p (car arguments))))

(defun agent-scheme--primitive-input-port? (arguments _context)
  "Primitive input-port? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme--port-p (car arguments))
        (agent-scheme--port-inputp (car arguments)))))

(defun agent-scheme--primitive-output-port? (arguments _context)
  "Primitive output-port? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme--port-p (car arguments))
        (agent-scheme--port-outputp (car arguments)))))

(defun agent-scheme--primitive-textual-port? (arguments _context)
  "Primitive textual-port? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme--port-p (car arguments))
        (agent-scheme--port-textualp (car arguments)))))

(defun agent-scheme--primitive-binary-port? (arguments _context)
  "Primitive binary-port? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (and (agent-scheme--port-p (car arguments))
        (agent-scheme--port-binaryp (car arguments)))))

(defun agent-scheme--primitive-input-port-open? (arguments _context)
  "Primitive input-port-open? over ARGUMENTS."
  (let ((port (agent-scheme--expect-port (car arguments) "input-port-open?")))
    (agent-scheme--scheme-boolean
     (and (agent-scheme--port-inputp port)
          (agent-scheme--port-openp port)))))

(defun agent-scheme--primitive-output-port-open? (arguments _context)
  "Primitive output-port-open? over ARGUMENTS."
  (let ((port (agent-scheme--expect-port (car arguments) "output-port-open?")))
    (agent-scheme--scheme-boolean
     (and (agent-scheme--port-outputp port)
          (agent-scheme--port-openp port)))))

(defun agent-scheme--byte-list->unibyte-string (bytes)
  "Return BYTES as an unibyte string for binary host file output."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dolist (byte bytes)
      (insert (unibyte-string byte)))
    (buffer-string)))

(defun agent-scheme--host-file-output-contents (port)
  "Return PORT contents in the host representation for file output."
  (if (agent-scheme--port-binaryp port)
      (agent-scheme--byte-list->unibyte-string
       (or (agent-scheme--port-contents port) nil))
    (or (agent-scheme--port-contents port) "")))

(defun agent-scheme--flush-file-output-port (port context operation)
  "Write host-backed output PORT contents to its file path for OPERATION."
  (when (and (eq (agent-scheme--port-backing-domain port) 'file)
             (agent-scheme--port-outputp port))
    (agent-scheme--port-capability-check port context operation)
    (condition-case condition
        (progn
          (write-region
           (agent-scheme--host-file-output-contents port)
           nil
           (agent-scheme--port-path port)
           nil
           'silent)
          (agent-scheme-capability-audit-port-result port operation 'flushed))
      (file-error
       (agent-scheme-capability-audit-port-result
        port operation (error-message-string condition) t)
       (signal (car condition) (cdr condition))))))

(defun agent-scheme--close-port-value (port &optional context)
  "Close PORT and return the unspecified value."
  (when (agent-scheme--port-openp port)
    (when (agent-scheme--port-backing-domain port)
      (agent-scheme--port-capability-check port context 'close))
    (when (and (eq (agent-scheme--port-backing-domain port) 'file)
               (agent-scheme--port-outputp port))
      (condition-case condition
          (write-region
           (agent-scheme--host-file-output-contents port)
           nil
           (agent-scheme--port-path port)
           nil
           'silent)
        (file-error
         (agent-scheme-capability-audit-port-result
          port 'close (error-message-string condition) t)
         (signal (car condition) (cdr condition)))))
    (setf (agent-scheme--port-openp port) nil)
    (setf (agent-scheme--port-status port) 'closed)
    (agent-scheme-capability-audit-port-result port 'close 'closed))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-close-port (arguments context)
  "Primitive close-port over ARGUMENTS."
  (agent-scheme--close-port-value
   (agent-scheme--expect-port (car arguments) "close-port")
   context))

(defun agent-scheme--primitive-close-input-port (arguments context)
  "Primitive close-input-port over ARGUMENTS."
  (agent-scheme--close-port-value
   (agent-scheme--expect-input-port (car arguments) "close-input-port")
   context))

(defun agent-scheme--primitive-close-output-port (arguments context)
  "Primitive close-output-port over ARGUMENTS."
  (agent-scheme--close-port-value
   (agent-scheme--expect-output-port (car arguments) "close-output-port")
   context))

(defun agent-scheme--primitive-open-output-string (_arguments _context)
  "Primitive open-output-string."
  (agent-scheme--make-port
   :medium 'string
   :outputp t
   :textualp t
   :contents ""))

(defun agent-scheme--primitive-open-input-string (arguments _context)
  "Primitive open-input-string over ARGUMENTS."
  (agent-scheme--make-port
   :medium 'string
   :inputp t
   :textualp t
   :source (copy-sequence
            (agent-scheme--expect-string (car arguments) "open-input-string"))
   :position 0))

(defun agent-scheme--primitive-get-output-string (arguments _context)
  "Primitive get-output-string over ARGUMENTS."
  (copy-sequence
   (agent-scheme--port-contents
    (agent-scheme--expect-string-output-port
     (car arguments) "get-output-string"))))

(defun agent-scheme--primitive-open-output-bytevector (_arguments _context)
  "Primitive open-output-bytevector."
  (agent-scheme--make-port
   :medium 'bytevector
   :outputp t
   :binaryp t
   :contents nil))

(defun agent-scheme--primitive-open-input-bytevector (arguments _context)
  "Primitive open-input-bytevector over ARGUMENTS."
  (let ((bytevector
         (agent-scheme--expect-bytevector
          (car arguments) "open-input-bytevector")))
    (agent-scheme--make-port
     :medium 'bytevector
     :inputp t
     :binaryp t
     :source (copy-sequence (agent-scheme-bytevector-bytes bytevector))
     :position 0)))

(defun agent-scheme--primitive-get-output-bytevector (arguments _context)
  "Primitive get-output-bytevector over ARGUMENTS."
  (agent-scheme--make-bytevector
   (vconcat
    (agent-scheme--port-contents
     (agent-scheme--expect-bytevector-output-port
      (car arguments) "get-output-bytevector")))))

(defun agent-scheme--primitive-read (arguments _context)
  "Primitive read over ARGUMENTS."
  (let* ((port (agent-scheme--expect-textual-input-port
                (if arguments
                    (car arguments)
                  (agent-scheme--current-input-port-or-deny _context "read"))
                "read"))
         (result
          (agent-scheme--read-one-from-string-at
           (agent-scheme--port-source port)
           (agent-scheme--port-position port))))
    (agent-scheme--port-capability-check port _context 'read)
    (setf (agent-scheme--port-position port) (cdr result))
    (agent-scheme-capability-audit-port-result port 'read 'datum)
    (if (eq (car result) agent-scheme--read-eof)
        agent-scheme-eof-object
      (car result))))

(defun agent-scheme--text-port-next-code
    (port advancep description context)
  "Return next character code from textual input PORT.
Advance when ADVANCEP is non-nil.  Signal errors using DESCRIPTION."
  (let ((input (agent-scheme--expect-textual-input-port port description)))
    (unless (memq (agent-scheme--port-medium input)
                  '(string file process network))
      (agent-scheme--eval-error
       "%s host textual input ports are not available" description))
    (agent-scheme--port-capability-check input context 'read)
    (let ((position (agent-scheme--port-position input))
          (source (agent-scheme--port-source input)))
      (if (>= position (length source))
          (prog1 agent-scheme-eof-object
            (agent-scheme-capability-audit-port-result input 'read 'eof))
        (prog1 (aref source position)
          (when advancep
            (setf (agent-scheme--port-position input) (1+ position)))
          (agent-scheme-capability-audit-port-result input 'read 1))))))

(defun agent-scheme--primitive-read-char (arguments context)
  "Primitive read-char over ARGUMENTS."
  (let ((value (if arguments
                   (agent-scheme--text-port-next-code
                    (car arguments) t "read-char" context)
                 (agent-scheme--text-port-next-code
                  (agent-scheme--current-input-port-or-deny context "read-char")
                  t "read-char" context))))
    (if (agent-scheme-eof-object-p value)
        value
      (agent-scheme--make-character value))))

(defun agent-scheme--primitive-peek-char (arguments context)
  "Primitive peek-char over ARGUMENTS."
  (let ((value (if arguments
                   (agent-scheme--text-port-next-code
                    (car arguments) nil "peek-char" context)
                 (agent-scheme--text-port-next-code
                  (agent-scheme--current-input-port-or-deny context "peek-char")
                  nil "peek-char" context))))
    (if (agent-scheme-eof-object-p value)
        value
      (agent-scheme--make-character value))))

(defun agent-scheme--primitive-char-ready? (arguments _context)
  "Primitive char-ready? over ARGUMENTS."
  (when arguments
    (agent-scheme--expect-textual-input-port (car arguments) "char-ready?"))
  agent-scheme-true)

(defun agent-scheme--primitive-read-string (arguments context)
  "Primitive read-string over ARGUMENTS."
  (let* ((count (agent-scheme--exact-integer->host
                 (car arguments) "read-string"))
           (port (if (cdr arguments)
                   (agent-scheme--expect-textual-input-port
                    (cadr arguments) "read-string")
                 (agent-scheme--current-input-port-or-deny
                  context "read-string"))))
    (when (< count 0)
      (agent-scheme--eval-error "read-string count must be non-negative"))
    (cond
     ((null port)
      (if (zerop count) "" agent-scheme-eof-object))
     ((not (memq (agent-scheme--port-medium port)
                 '(string file process network)))
      (agent-scheme--eval-error
       "read-string host textual input ports are not available"))
     (t
      (agent-scheme--port-capability-check port context 'read)
      (let* ((source (agent-scheme--port-source port))
             (position (agent-scheme--port-position port))
             (remaining (- (length source) position))
             (amount (min count remaining)))
        (cond
         ((zerop count) "")
         ((zerop amount) agent-scheme-eof-object)
         (t
          (setf (agent-scheme--port-position port) (+ position amount))
          (agent-scheme-capability-audit-port-result port 'read amount)
          (substring source position (+ position amount)))))))))

(defun agent-scheme--primitive-read-line (arguments context)
  "Primitive read-line over ARGUMENTS."
  (let ((port (agent-scheme--expect-textual-input-port
               (if arguments
                   (car arguments)
                 (agent-scheme--current-input-port-or-deny
                  context "read-line"))
               "read-line")))
      (unless (memq (agent-scheme--port-medium port)
                    '(string file process network))
        (agent-scheme--eval-error
         "read-line host textual input ports are not available"))
      (agent-scheme--port-capability-check port context 'read)
      (let* ((source (agent-scheme--port-source port))
             (start (agent-scheme--port-position port))
             (length (length source))
             (position start))
        (while (and (< position length)
                    (not (memq (aref source position) '(?\n ?\r))))
          (setq position (1+ position)))
        (cond
         ((and (= start position) (>= position length))
          agent-scheme-eof-object)
         (t
          (let ((line (substring source start position)))
            (when (< position length)
              (if (and (= (aref source position) ?\r)
                       (< (1+ position) length)
                       (= (aref source (1+ position)) ?\n))
                  (setq position (+ position 2))
                (setq position (1+ position))))
            (setf (agent-scheme--port-position port) position)
            (agent-scheme-capability-audit-port-result
             port 'read (length line))
            line))))))

(defun agent-scheme--append-bytes-to-port
    (bytes port description &optional context)
  "Append BYTES to binary output PORT for DESCRIPTION."
  (let ((output (agent-scheme--expect-binary-output-port port description)))
    (unless (memq (agent-scheme--port-medium output) '(bytevector file))
      (agent-scheme--eval-error
       "%s host binary output ports are not available" description))
    (agent-scheme--port-capability-check output context 'write)
    (setf (agent-scheme--port-contents output)
          (append (agent-scheme--port-contents output) bytes))
    (agent-scheme-capability-audit-port-result
     output 'write (length bytes)))
  agent-scheme-unspecified)

(defun agent-scheme--write-byte-to-port
    (byte port description &optional context)
  "Append BYTE to binary output PORT for DESCRIPTION."
  (agent-scheme--append-bytes-to-port
   (list byte) port description context))

(defun agent-scheme--primitive-read-u8 (arguments context)
  "Primitive read-u8 over ARGUMENTS."
  (if (null arguments)
      agent-scheme-eof-object
    (let* ((port (agent-scheme--expect-binary-input-port
                  (car arguments) "read-u8"))
           (source (agent-scheme--port-source port))
           (position (agent-scheme--port-position port)))
      (unless (memq (agent-scheme--port-medium port) '(bytevector file))
        (agent-scheme--eval-error
         "read-u8 host binary input ports are not available"))
      (agent-scheme--port-capability-check port context 'read)
      (if (>= position (length source))
          (prog1 agent-scheme-eof-object
            (agent-scheme-capability-audit-port-result port 'read 'eof))
        (setf (agent-scheme--port-position port) (1+ position))
        (agent-scheme-capability-audit-port-result port 'read 1)
        (agent-scheme--number-from-host (aref source position))))))

(defun agent-scheme--primitive-peek-u8 (arguments context)
  "Primitive peek-u8 over ARGUMENTS."
  (if (null arguments)
      agent-scheme-eof-object
    (let* ((port (agent-scheme--expect-binary-input-port
                  (car arguments) "peek-u8"))
           (source (agent-scheme--port-source port))
           (position (agent-scheme--port-position port)))
      (unless (memq (agent-scheme--port-medium port) '(bytevector file))
        (agent-scheme--eval-error
         "peek-u8 host binary input ports are not available"))
      (agent-scheme--port-capability-check port context 'read)
      (if (>= position (length source))
          (prog1 agent-scheme-eof-object
            (agent-scheme-capability-audit-port-result port 'read 'eof))
        (agent-scheme-capability-audit-port-result port 'read 1)
        (agent-scheme--number-from-host (aref source position))))))

(defun agent-scheme--primitive-u8-ready? (arguments _context)
  "Primitive u8-ready? over ARGUMENTS."
  (when arguments
    (agent-scheme--expect-binary-input-port (car arguments) "u8-ready?"))
  agent-scheme-true)

(defun agent-scheme--primitive-read-bytevector (arguments context)
  "Primitive read-bytevector over ARGUMENTS."
  (let* ((count (agent-scheme--exact-integer->host
                 (car arguments) "read-bytevector"))
         (port (if (cdr arguments)
                   (agent-scheme--expect-binary-input-port
                    (cadr arguments) "read-bytevector")
                 nil)))
    (when (< count 0)
      (agent-scheme--eval-error "read-bytevector count must be non-negative"))
    (cond
     ((null port)
      (if (zerop count)
          (agent-scheme--make-bytevector [])
        agent-scheme-eof-object))
     ((not (memq (agent-scheme--port-medium port) '(bytevector file)))
      (agent-scheme--eval-error
       "read-bytevector host binary input ports are not available"))
     (t
      (agent-scheme--port-capability-check port context 'read)
      (let* ((source (agent-scheme--port-source port))
             (position (agent-scheme--port-position port))
             (remaining (- (length source) position))
             (amount (min count remaining)))
        (cond
         ((zerop count)
          (agent-scheme--make-bytevector []))
         ((zerop amount)
          agent-scheme-eof-object)
         (t
          (setf (agent-scheme--port-position port) (+ position amount))
          (agent-scheme-capability-audit-port-result port 'read amount)
          (agent-scheme--make-bytevector
           (cl-subseq source position (+ position amount))))))))))

(defun agent-scheme--primitive-read-bytevector! (arguments context)
  "Primitive read-bytevector! over ARGUMENTS."
  (let* ((target (agent-scheme--expect-bytevector
                  (car arguments) "read-bytevector! target"))
         (port (if (cdr arguments)
                   (agent-scheme--expect-binary-input-port
                    (cadr arguments) "read-bytevector!")
                 nil))
         (bytes (agent-scheme-bytevector-bytes target))
         (start (if (nthcdr 2 arguments)
                    (agent-scheme--expect-nonnegative-index
                     (caddr arguments) (length bytes) "read-bytevector!" t)
                  0))
         (end (if (nthcdr 3 arguments)
                  (agent-scheme--expect-nonnegative-index
                   (cadddr arguments) (length bytes) "read-bytevector!" t)
                (length bytes))))
    (when (> start end)
      (agent-scheme--eval-error "read-bytevector! invalid range"))
    (if (null port)
        agent-scheme-eof-object
      (let* ((source (agent-scheme--port-source port))
             (position (agent-scheme--port-position port))
             (amount (min (- end start) (- (length source) position))))
        (unless (memq (agent-scheme--port-medium port) '(bytevector file))
          (agent-scheme--eval-error
           "read-bytevector! host binary input ports are not available"))
        (agent-scheme--port-capability-check port context 'read)
        (if (zerop amount)
            agent-scheme-eof-object
          (dotimes (offset amount)
            (aset bytes (+ start offset) (aref source (+ position offset))))
          (setf (agent-scheme--port-position port) (+ position amount))
          (agent-scheme-capability-audit-port-result port 'read amount)
          (agent-scheme--number-from-host amount))))))

(defun agent-scheme--primitive-write-u8 (arguments context)
  "Primitive write-u8 over ARGUMENTS."
  (when (cdr arguments)
    (agent-scheme--write-byte-to-port
     (agent-scheme--expect-byte (car arguments) "write-u8")
     (cadr arguments)
     "write-u8"
     context))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-write-bytevector (arguments context)
  "Primitive write-bytevector over ARGUMENTS."
  (when (cdr arguments)
    (let* ((bytevector (agent-scheme--expect-bytevector
                        (car arguments) "write-bytevector"))
           (bytes (agent-scheme-bytevector-bytes bytevector))
           (range (agent-scheme--optional-range
                   arguments 2 (length bytes) "write-bytevector"))
           (payload nil))
      (cl-loop for index from (car range) below (cdr range)
               do (push (aref bytes index) payload))
      (agent-scheme--append-bytes-to-port
       (nreverse payload)
       (cadr arguments)
       "write-bytevector"
       context)))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-write-char (arguments context)
  "Primitive write-char over ARGUMENTS."
  (when (cdr arguments)
    (agent-scheme--write-text-to-port
     (char-to-string
      (agent-scheme--expect-character (car arguments) "write-char"))
     (cadr arguments)
     "write-char"
     context))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-write-string (arguments context)
  "Primitive write-string over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string
                  (car arguments) "write-string"))
         (port (if (cdr arguments)
                   (cadr arguments)
                 (agent-scheme--current-output-port-or-deny
                  context "write-string")))
         (range (agent-scheme--optional-range
                 arguments
                 (if (cdr arguments) 2 1)
                 (length string)
                 "write-string")))
    (agent-scheme--write-text-to-port
     (substring string (car range) (cdr range))
     port
     "write-string"
     context))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-newline (arguments context)
  "Primitive newline over ARGUMENTS."
  (agent-scheme--write-text-to-port
   "\n"
   (if arguments
       (car arguments)
     (agent-scheme--current-output-port-or-deny context "newline"))
   "newline"
   context)
  agent-scheme-unspecified)

(defun agent-scheme--primitive-display (arguments context)
  "Primitive display over ARGUMENTS."
  (agent-scheme--write-to-output-port
   (car arguments)
   (agent-scheme--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (agent-scheme--current-output-port-or-deny context "display"))
    "display")
   'write
   t
   context))

(defun agent-scheme--primitive-write (arguments context)
  "Primitive write over ARGUMENTS."
  (agent-scheme--write-to-output-port
   (car arguments)
   (agent-scheme--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (agent-scheme--current-output-port-or-deny context "write"))
    "write")
   'write
   nil
   context))

(defun agent-scheme--primitive-write-shared (arguments context)
  "Primitive write-shared over ARGUMENTS."
  (agent-scheme--write-to-output-port
   (car arguments)
   (agent-scheme--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (agent-scheme--current-output-port-or-deny context "write-shared"))
    "write-shared")
   'shared
   nil
   context))

(defun agent-scheme--primitive-write-simple (arguments context)
  "Primitive write-simple over ARGUMENTS."
  (agent-scheme--write-to-output-port
   (car arguments)
   (agent-scheme--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (agent-scheme--current-output-port-or-deny context "write-simple"))
    "write-simple")
   'simple
   nil
   context))

(defun agent-scheme--primitive-flush-output-port (arguments context)
  "Primitive flush-output-port over ARGUMENTS."
  (when arguments
    (let ((port (agent-scheme--expect-output-port
                 (car arguments) "flush-output-port")))
      (agent-scheme--flush-file-output-port port context 'flush)))
  agent-scheme-unspecified)

(defun agent-scheme--primitive-read-error? (arguments _context)
  "Primitive read-error? over ARGUMENTS."
  (agent-scheme--scheme-boolean nil))

(defun agent-scheme--primitive-file-error? (arguments _context)
  "Primitive file-error? over ARGUMENTS."
  (agent-scheme--scheme-boolean nil))

(defun agent-scheme--primitive-features (_arguments _context)
  "Primitive features."
  (mapcar
   #'agent-scheme--syntax-symbol
   '("r7rs" "ratios" "exact-complex" "ieee-float" "agent-scheme")))

(defun agent-scheme--policy-denied (description &optional context)
  "Signal a default-denied host policy error for DESCRIPTION."
  (agent-scheme-policy-deny
   'standard-host-effect
   description
   nil
   context
   (format "%s requires policy-gated host access" description)))

(defun agent-scheme--interaction-session-symbol (session-id)
  "Return SESSION-ID as a Scheme-readable symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p session-id)
     (agent-scheme-symbol-name session-id))
    ((symbolp session-id)
     (symbol-name session-id))
    ((stringp session-id)
     session-id)
    (t
     (format "%S" session-id)))))

(defun agent-scheme--primitive-interaction-environment (_arguments context)
  "Primitive interaction-environment over _ARGUMENTS."
  (let ((session-id (and context
                         (agent-scheme--eval-context-session-id context)))
        (environment (and context
                          (agent-scheme--eval-context-interaction-environment
                           context)))
        (syntax-environment
         (and context
              (agent-scheme--eval-context-syntax-environment context))))
    (unless (and session-id environment syntax-environment)
      (agent-scheme-policy-deny
       'standard-host-effect
       "interaction-environment"
       nil
       context
       "interaction-environment requires an active session"))
    (agent-scheme-policy-authorize
     'standard-host-effect
     "interaction-environment"
     `((session . ,(agent-scheme--interaction-session-symbol session-id)))
     context)
    (agent-scheme--make-environment-specifier
     environment syntax-environment nil)))

(defun agent-scheme--time-inexact-number (value description)
  "Return VALUE as an inexact Agent Scheme number for DESCRIPTION."
  (unless (numberp value)
    (agent-scheme--eval-error
     "%s host adapter returned non-number: %S" description value))
  (agent-scheme--number-from-host (float value)))

(defun agent-scheme--time-exact-integer (value description)
  "Return VALUE as an exact Agent Scheme integer for DESCRIPTION."
  (unless (integerp value)
    (agent-scheme--eval-error
     "%s host adapter returned non-integer: %S" description value))
  (agent-scheme--number-from-host value))

(defun agent-scheme--time-positive-exact-integer (value description)
  "Return VALUE as a positive exact Agent Scheme integer for DESCRIPTION."
  (unless (and (integerp value) (> value 0))
    (agent-scheme--eval-error
     "%s host adapter returned non-positive integer: %S" description value))
  (agent-scheme--number-from-host value))

(defun agent-scheme--call-authorized-clock
    (binding context thunk)
  "Authorize clock BINDING, call THUNK, and audit the result."
  (let ((authorization
         (agent-scheme-capability-authorize-clock binding context)))
    (condition-case condition
        (let ((value (funcall thunk)))
          (agent-scheme-capability-audit-clock-result authorization value)
          value)
      (error
       (agent-scheme-capability-audit-clock-result
        authorization (error-message-string condition) t)
       (signal (car condition) (cdr condition))))))

(defun agent-scheme--primitive-current-second (_arguments context)
  "Primitive current-second over _ARGUMENTS."
  (agent-scheme--call-authorized-clock
   "current-second"
   context
   (lambda ()
     (agent-scheme--time-inexact-number
      (funcall agent-scheme-time-current-second-function)
      "current-second"))))

(defun agent-scheme--primitive-current-jiffy (_arguments context)
  "Primitive current-jiffy over _ARGUMENTS."
  (agent-scheme--call-authorized-clock
   "current-jiffy"
   context
   (lambda ()
     (agent-scheme--time-exact-integer
      (funcall agent-scheme-time-current-jiffy-function)
      "current-jiffy"))))

(defun agent-scheme--primitive-jiffies-per-second (_arguments context)
  "Primitive jiffies-per-second over _ARGUMENTS."
  (agent-scheme--call-authorized-clock
   "jiffies-per-second"
   context
   (lambda ()
     (agent-scheme--time-positive-exact-integer
      (funcall agent-scheme-time-jiffies-per-second-function)
      "jiffies-per-second"))))

(defun agent-scheme--resolve-file-policy-path (filename context description)
  "Return a file authorization for FILENAME and DESCRIPTION."
  (agent-scheme-capability-authorize-file
   filename
   context
   (pcase description
     ("file-exists?" 'metadata)
     ("delete-file" 'delete)
     ("load" 'load)
     (_ 'read))
   description
   (agent-scheme--eval-context-file-paths context)))

(defun agent-scheme--read-file-port-source (authorization description filename)
  "Return file contents for AUTHORIZATION or signal for DESCRIPTION."
  (let ((path (plist-get authorization :path)))
    (agent-scheme-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (agent-scheme-capability-audit-file-result
       authorization
       (format "%s file is not readable" description)
       t)
      (agent-scheme--eval-error
       "%s file is not readable: %s" description filename))
    (prog1
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))
      (agent-scheme-capability-audit-file-result authorization 'opened))))

(defun agent-scheme--read-binary-file-port-source
    (authorization description filename)
  "Return file bytes for AUTHORIZATION or signal for DESCRIPTION."
  (let ((path (plist-get authorization :path)))
    (agent-scheme-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (agent-scheme-capability-audit-file-result
       authorization
       (format "%s file is not readable" description)
       t)
      (agent-scheme--eval-error
       "%s file is not readable: %s" description filename))
    (prog1
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally path)
          (let ((bytes (make-vector (buffer-size) 0)))
            (dotimes (index (buffer-size) bytes)
              (aset bytes index (char-after (1+ index))))))
      (agent-scheme-capability-audit-file-result authorization 'opened))))

(defun agent-scheme--primitive-open-input-file (arguments context)
  "Primitive open-input-file over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "open-input-file"))
         (authorization
          (agent-scheme--resolve-file-policy-path
           filename context "open-input-file"))
         (source
          (agent-scheme--read-file-port-source
           authorization "open-input-file" filename))
         (port
          (agent-scheme--make-port
           :medium 'file
           :inputp t
           :textualp t
           :source source
           :position 0)))
    (agent-scheme-capability-register-file-port
     port 'textual-input authorization '(read close))))

(defun agent-scheme--primitive-open-binary-input-file (arguments context)
  "Primitive open-binary-input-file over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "open-binary-input-file"))
         (authorization
          (agent-scheme--resolve-file-policy-path
           filename context "open-binary-input-file"))
         (source
          (agent-scheme--read-binary-file-port-source
           authorization "open-binary-input-file" filename))
         (port
          (agent-scheme--make-port
           :medium 'file
           :inputp t
           :binaryp t
           :source source
           :position 0)))
    (agent-scheme-capability-register-file-port
     port 'binary-input authorization '(read close))))

(defun agent-scheme--resolve-output-file-policy-path
    (filename context description)
  "Return file authorization for output FILENAME and DESCRIPTION."
  (let* ((path (expand-file-name
                filename
                (agent-scheme--eval-context-include-directory context)))
         (operation (if (file-exists-p path) 'write 'create)))
    (agent-scheme-capability-authorize-file
     filename
     context
     operation
     description
     (agent-scheme--eval-context-file-paths context))))

(defun agent-scheme--primitive-open-output-file (arguments context)
  "Primitive open-output-file over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "open-output-file"))
         (authorization
          (agent-scheme--resolve-output-file-policy-path
           filename context "open-output-file"))
         (port
          (agent-scheme--make-port
           :medium 'file
           :outputp t
           :textualp t
           :contents "")))
    (agent-scheme-capability-revalidate-file-authorization authorization)
    (agent-scheme-capability-audit-file-result authorization 'opened)
    (agent-scheme-capability-register-file-port
     port 'textual-output authorization '(write flush close))))

(defun agent-scheme--primitive-open-binary-output-file (arguments context)
  "Primitive open-binary-output-file over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "open-binary-output-file"))
         (authorization
          (agent-scheme--resolve-output-file-policy-path
           filename context "open-binary-output-file"))
         (port
          (agent-scheme--make-port
           :medium 'file
           :outputp t
           :binaryp t
           :contents nil)))
    (agent-scheme-capability-revalidate-file-authorization authorization)
    (agent-scheme-capability-audit-file-result authorization 'opened)
    (agent-scheme-capability-register-file-port
     port 'binary-output authorization '(write flush close))))

(defun agent-scheme--primitive-file-exists? (arguments context)
  "Primitive file-exists? over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "file-exists?"))
         (path (agent-scheme--resolve-file-policy-path
                filename context "file-exists?"))
         (exists (progn
                   (agent-scheme-capability-revalidate-file-authorization
                    path)
                   (file-exists-p (plist-get path :path)))))
    (agent-scheme-capability-audit-file-result path exists)
    (agent-scheme--scheme-boolean exists)))

(defun agent-scheme--primitive-delete-file (arguments context)
  "Primitive delete-file over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string
                    (car arguments) "delete-file"))
         (authorization
          (agent-scheme--resolve-file-policy-path
           filename context "delete-file"))
         (path (plist-get authorization :path)))
    (condition-case condition
        (progn
          (agent-scheme-capability-revalidate-file-authorization
           authorization)
          (delete-file path)
          (agent-scheme-capability-audit-file-result
           authorization 'deleted)
          agent-scheme-unspecified)
      (file-error
       (agent-scheme-capability-audit-file-result
        authorization
        (error-message-string condition)
        t)
       (signal (car condition) (cdr condition))))))

(defun agent-scheme--primitive-call-with-port (arguments context)
  "Primitive call-with-port over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-call-with-port/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-call-with-port/k
    (arguments context continuation)
  "CPS primitive call-with-port over ARGUMENTS."
  (let ((port (agent-scheme--expect-port (car arguments) "call-with-port port"))
        (procedure (agent-scheme--expect-procedure
                    (cadr arguments) "call-with-port procedure")))
    (agent-scheme--apply-procedure
     procedure
     (list port)
     context
     t
     (lambda (value)
       (agent-scheme--close-port-value port context)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-call-with-input-file (arguments context)
  "Primitive call-with-input-file over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-call-with-input-file/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-call-with-input-file/k
    (arguments context continuation)
  "CPS primitive call-with-input-file over ARGUMENTS."
  (let ((port (agent-scheme--primitive-open-input-file
               (list (car arguments)) context))
        (procedure (agent-scheme--expect-procedure
                    (cadr arguments) "call-with-input-file procedure")))
    (agent-scheme--apply-procedure
     procedure
     (list port)
     context
     t
     (lambda (value)
       (agent-scheme--close-port-value port context)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-call-with-output-file (arguments context)
  "Primitive call-with-output-file over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-call-with-output-file/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-call-with-output-file/k
    (arguments context continuation)
  "CPS primitive call-with-output-file over ARGUMENTS."
  (let ((port (agent-scheme--primitive-open-output-file
               (list (car arguments)) context))
        (procedure (agent-scheme--expect-procedure
                    (cadr arguments) "call-with-output-file procedure")))
    (agent-scheme--apply-procedure
     procedure
     (list port)
     context
     t
     (lambda (value)
       (agent-scheme--close-port-value port context)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-with-input-from-file (arguments context)
  "Primitive with-input-from-file over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-with-input-from-file/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-with-input-from-file/k
    (arguments context continuation)
  "CPS primitive with-input-from-file over ARGUMENTS."
  (let ((port (agent-scheme--primitive-open-input-file
               (list (car arguments)) context))
        (procedure (agent-scheme--expect-procedure
                    (cadr arguments) "with-input-from-file thunk"))
        (previous (agent-scheme--eval-context-current-input-port context)))
    (setf (agent-scheme--eval-context-current-input-port context) port)
    (agent-scheme--apply-procedure
     procedure
     nil
     context
     t
     (lambda (value)
       (setf (agent-scheme--eval-context-current-input-port context) previous)
       (agent-scheme--close-port-value port context)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-with-output-to-file (arguments context)
  "Primitive with-output-to-file over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-with-output-to-file/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-with-output-to-file/k
    (arguments context continuation)
  "CPS primitive with-output-to-file over ARGUMENTS."
  (let ((port (agent-scheme--primitive-open-output-file
               (list (car arguments)) context))
        (procedure (agent-scheme--expect-procedure
                    (cadr arguments) "with-output-to-file thunk"))
        (previous (agent-scheme--eval-context-current-output-port context)))
    (setf (agent-scheme--eval-context-current-output-port context) port)
    (agent-scheme--apply-procedure
     procedure
     nil
     context
     t
     (lambda (value)
       (setf (agent-scheme--eval-context-current-output-port context) previous)
       (agent-scheme--close-port-value port context)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-environment (arguments context)
  "Primitive environment over ARGUMENTS."
  (let ((environment (agent-scheme-make-empty-environment))
        (syntax-environment (agent-scheme--make-empty-syntax-environment)))
    (agent-scheme--with-syntax-environment
     context
     syntax-environment
     (lambda ()
       (agent-scheme--eval-import
        (cons (agent-scheme--syntax-symbol "import") arguments)
        environment
        context)))
    (agent-scheme--make-environment-specifier
     environment syntax-environment t)))

(defun agent-scheme--expect-environment-specifier (value description)
  "Return VALUE as an environment specifier for DESCRIPTION."
  (unless (agent-scheme--environment-specifier-p value)
    (agent-scheme--eval-error "%s expected an environment specifier" description))
  value)

(defun agent-scheme--eval-form-mutates-environment-p (form)
  "Return non-nil if evaluating FORM can install top-level bindings."
  (or (agent-scheme--import-form-p form)
      (agent-scheme--define-library-form-p form)
      (agent-scheme--syntax-definition-form-p form)
      (agent-scheme--record-definition-form-p form)
      (agent-scheme--define-values-form-p form)
      (agent-scheme--definition-form-p form)))

(defun agent-scheme--primitive-eval (arguments context)
  "Primitive eval over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-eval/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-eval/k (arguments context continuation)
  "CPS primitive eval over ARGUMENTS."
  (let* ((expression (car arguments))
         (specifier (agent-scheme--expect-environment-specifier
                     (cadr arguments) "eval"))
         (environment
          (agent-scheme--environment-specifier-environment specifier))
         (syntax-environment
          (agent-scheme--environment-specifier-syntax-environment specifier)))
    (when (and (agent-scheme--environment-specifier-immutable specifier)
               (agent-scheme--eval-form-mutates-environment-p expression))
      (agent-scheme--eval-error
       "eval cannot mutate an immutable environment"))
    (agent-scheme--with-syntax-environment
     context
     syntax-environment
     (lambda ()
       (if (agent-scheme--eval-form-mutates-environment-p expression)
           (agent-scheme--eval-sequence
            (list expression) environment context t t continuation)
         (agent-scheme--eval-expression
          expression environment context t continuation))))))

(defun agent-scheme--read-policy-file-forms (filename context description)
  "Read FILENAME under CONTEXT file policy for DESCRIPTION.
Return (FORMS DIRECTORY AUTHORIZATION)."
  (let* ((authorization
          (agent-scheme--resolve-file-policy-path
           filename context description))
         (path (plist-get authorization :path)))
    (agent-scheme-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (agent-scheme-capability-audit-file-result
       authorization
       (format "%s file is not readable" description)
       t)
      (agent-scheme--eval-error
       "%s file is not readable: %s" description filename))
    (let ((source
           (with-temp-buffer
             (insert-file-contents path)
             (buffer-string))))
      (agent-scheme-capability-audit-file-result authorization 'read)
      (list (agent-scheme-read-all source)
            (file-name-directory path)
            authorization))))

(defun agent-scheme--load-target (arguments context)
  "Return (ENVIRONMENT . SYNTAX-ENVIRONMENT) for load ARGUMENTS."
  (if (cdr arguments)
      (let ((specifier (agent-scheme--expect-environment-specifier
                        (cadr arguments) "load")))
        (when (agent-scheme--environment-specifier-immutable specifier)
          (agent-scheme--eval-error
           "load cannot mutate an immutable environment"))
        (cons (agent-scheme--environment-specifier-environment specifier)
              (agent-scheme--environment-specifier-syntax-environment specifier)))
    (cons (or (agent-scheme--eval-context-interaction-environment context)
              (agent-scheme-make-base-environment))
          (agent-scheme--eval-context-syntax-environment context))))

(defun agent-scheme--primitive-load (arguments context)
  "Primitive load over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-load/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-load/k (arguments context continuation)
  "CPS primitive load over ARGUMENTS."
  (let* ((filename (agent-scheme--expect-string (car arguments) "load"))
         (read-result
          (agent-scheme--read-policy-file-forms filename context "load"))
         (target (agent-scheme--load-target arguments context))
         (code-loading
          (agent-scheme-capability-authorize-code-loading
           (caddr read-result) context "load")))
    (agent-scheme--with-include-directory
     context
     (cadr read-result)
     (lambda ()
       (agent-scheme--with-syntax-environment
        context
        (cdr target)
        (lambda ()
          (agent-scheme--eval-sequence
           (car read-result)
           (car target)
           context
           t
           t
           (lambda (_value)
             (agent-scheme-capability-audit-code-loading-result
              code-loading 'evaluated)
             (agent-scheme--continue
              continuation agent-scheme-unspecified)))))))))

(defun agent-scheme--primitive-string? (arguments _context)
  "Primitive string? over ARGUMENTS."
  (agent-scheme--scheme-boolean (stringp (car arguments))))

(defun agent-scheme--primitive-make-string (arguments _context)
  "Primitive make-string over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-string"))
         (fill (if (cdr arguments)
                   (agent-scheme--expect-character
                    (cadr arguments) "make-string fill")
                 0)))
    (when (< length 0)
      (agent-scheme--eval-error "make-string length must be non-negative"))
    (make-string length fill)))

(defun agent-scheme--primitive-string (arguments _context)
  "Primitive string over ARGUMENTS."
  (apply #'string
         (mapcar
          (lambda (argument)
            (agent-scheme--expect-character argument "string"))
          arguments)))

(defun agent-scheme--primitive-string-length (arguments _context)
  "Primitive string-length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length (agent-scheme--expect-string
            (car arguments) "string-length"))))

(defun agent-scheme--primitive-string-ref (arguments _context)
  "Primitive string-ref over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-ref"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length string) "string-ref")))
    (agent-scheme--make-character (aref string index))))

(defun agent-scheme--primitive-string-set! (arguments _context)
  "Primitive string-set! over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-set!"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length string) "string-set!"))
         (code (agent-scheme--expect-character
                (caddr arguments) "string-set! value")))
    (aset string index code)
    agent-scheme-unspecified))

(defun agent-scheme--primitive-substring (arguments _context)
  "Primitive substring over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "substring"))
         (start (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length string) "substring" t))
         (end (agent-scheme--expect-nonnegative-index
               (caddr arguments) (length string) "substring" t)))
    (when (> start end)
      (agent-scheme--eval-error "substring start exceeds end"))
    (substring string start end)))

(defun agent-scheme--primitive-string-append (arguments _context)
  "Primitive string-append over ARGUMENTS."
  (mapconcat
   #'identity
   (mapcar
    (lambda (argument)
      (agent-scheme--expect-string argument "string-append"))
    arguments)
   ""))

(defun agent-scheme--primitive-string->list (arguments _context)
  "Primitive string->list over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string->list"))
         (range (agent-scheme--optional-range
                 arguments 1 (length string) "string->list"))
         result)
    (cl-loop for index from (car range) below (cdr range)
             do (push (agent-scheme--make-character (aref string index))
                      result))
    (nreverse result)))

(defun agent-scheme--primitive-list->string (arguments _context)
  "Primitive list->string over ARGUMENTS."
  (apply #'string
         (mapcar
          (lambda (argument)
            (agent-scheme--expect-character argument "list->string"))
          (agent-scheme--proper-list-elements
           (car arguments) "list->string"))))

(defun agent-scheme--primitive-string->utf8 (arguments _context)
  "Primitive string->utf8 over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string->utf8"))
         (range (agent-scheme--optional-range
                 arguments 1 (length string) "string->utf8"))
         (bytes (encode-coding-string
                 (substring string (car range) (cdr range))
                 'utf-8
                 t)))
    (agent-scheme--make-bytevector
     (vconcat (mapcar #'identity bytes)))))

(defun agent-scheme--primitive-utf8->string (arguments _context)
  "Primitive utf8->string over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "utf8->string"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (range (agent-scheme--optional-range
                 arguments 1 (length bytes) "utf8->string"))
         (raw (apply #'unibyte-string
                     (append
                      (cl-subseq bytes (car range) (cdr range))
                      nil))))
    (decode-coding-string raw 'utf-8 t)))

(defun agent-scheme--primitive-string->vector (arguments _context)
  "Primitive string->vector over ARGUMENTS."
  (vconcat (agent-scheme--primitive-string->list arguments nil)))

(defun agent-scheme--primitive-vector->string (arguments _context)
  "Primitive vector->string over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector->string"))
         (range (agent-scheme--optional-range
                 arguments 1 (length vector) "vector->string"))
         codes)
    (cl-loop for index from (car range) below (cdr range)
             do (push (agent-scheme--expect-character
                       (aref vector index) "vector->string")
                      codes))
    (apply #'string (nreverse codes))))

(defun agent-scheme--primitive-string-copy (arguments _context)
  "Primitive string-copy over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-copy"))
         (range (agent-scheme--optional-range
                 arguments 1 (length string) "string-copy")))
    (substring string (car range) (cdr range))))

(defun agent-scheme--primitive-string-copy! (arguments _context)
  "Primitive string-copy! over ARGUMENTS."
  (let* ((to (agent-scheme--expect-string (car arguments) "string-copy! target"))
         (at (agent-scheme--expect-nonnegative-index
              (cadr arguments) (length to) "string-copy!" t))
         (from (agent-scheme--expect-string
                (caddr arguments) "string-copy! source"))
         (range (agent-scheme--optional-range
                 arguments 3 (length from) "string-copy!"))
         (slice (substring from (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to))
      (agent-scheme--eval-error "string-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to (+ at index) (aref slice index)))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-string-fill! (arguments _context)
  "Primitive string-fill! over ARGUMENTS."
  (let* ((string (agent-scheme--expect-string (car arguments) "string-fill!"))
         (fill (agent-scheme--expect-character
                (cadr arguments) "string-fill! value"))
         (range (agent-scheme--optional-range
                 arguments 2 (length string) "string-fill!")))
    (cl-loop for index from (car range) below (cdr range)
             do (aset string index fill))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-string-compare (arguments predicate description)
  "Return Scheme boolean for pairwise string PREDICATE over ARGUMENTS."
  (let ((strings (mapcar
                  (lambda (argument)
                    (agent-scheme--expect-string argument description))
                  arguments))
        (ok t))
    (while (and ok (cdr strings))
      (setq ok (funcall predicate (car strings) (cadr strings)))
      (setq strings (cdr strings)))
    (agent-scheme--scheme-boolean ok)))

(defun agent-scheme--primitive-string=? (arguments _context)
  "Primitive string=? over ARGUMENTS."
  (agent-scheme--primitive-string-compare arguments #'string= "string=?"))

(defun agent-scheme--primitive-string<? (arguments _context)
  "Primitive string<? over ARGUMENTS."
  (agent-scheme--primitive-string-compare arguments #'string< "string<?"))

(defun agent-scheme--primitive-string>? (arguments _context)
  "Primitive string>? over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   arguments (lambda (left right) (string< right left)) "string>?"))

(defun agent-scheme--primitive-string<=? (arguments _context)
  "Primitive string<=? over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   arguments (lambda (left right) (not (string< right left))) "string<=?"))

(defun agent-scheme--primitive-string>=? (arguments _context)
  "Primitive string>=? over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   arguments (lambda (left right) (not (string< left right))) "string>=?"))

(defun agent-scheme--primitive-string-upcase (arguments _context)
  "Primitive string-upcase over ARGUMENTS."
  (upcase (agent-scheme--expect-string (car arguments) "string-upcase")))

(defun agent-scheme--primitive-string-downcase (arguments _context)
  "Primitive string-downcase over ARGUMENTS."
  (downcase (agent-scheme--expect-string (car arguments) "string-downcase")))

(defun agent-scheme--primitive-string-foldcase (arguments _context)
  "Primitive string-foldcase over ARGUMENTS."
  (downcase (upcase (agent-scheme--expect-string
                     (car arguments) "string-foldcase"))))

(defun agent-scheme--primitive-string-ci-compare
    (arguments predicate description)
  "Return Scheme boolean for folded string PREDICATE over ARGUMENTS."
  (agent-scheme--primitive-string-compare
   (mapcar
    (lambda (argument)
      (downcase (upcase (agent-scheme--expect-string argument description))))
    arguments)
   predicate
   description))

(defun agent-scheme--primitive-string-ci=? (arguments _context)
  "Primitive string-ci=? over ARGUMENTS."
  (agent-scheme--primitive-string-ci-compare arguments #'string= "string-ci=?"))

(defun agent-scheme--primitive-string-ci<? (arguments _context)
  "Primitive string-ci<? over ARGUMENTS."
  (agent-scheme--primitive-string-ci-compare arguments #'string< "string-ci<?"))

(defun agent-scheme--primitive-string-ci>? (arguments _context)
  "Primitive string-ci>? over ARGUMENTS."
  (agent-scheme--primitive-string-ci-compare
   arguments (lambda (left right) (string< right left)) "string-ci>?"))

(defun agent-scheme--primitive-string-ci<=? (arguments _context)
  "Primitive string-ci<=? over ARGUMENTS."
  (agent-scheme--primitive-string-ci-compare
   arguments (lambda (left right) (not (string< right left))) "string-ci<=?"))

(defun agent-scheme--primitive-string-ci>=? (arguments _context)
  "Primitive string-ci>=? over ARGUMENTS."
  (agent-scheme--primitive-string-ci-compare
   arguments (lambda (left right) (not (string< left right))) "string-ci>=?"))

(defun agent-scheme--map-over-lists (procedure lists context keep-results)
  "Map PROCEDURE over LISTS in CONTEXT.
When KEEP-RESULTS is non-nil, return the collected values."
  (let ((cursors lists)
        results
        done)
    (while (not done)
      (cond
       ((cl-some #'null cursors)
        (setq done t))
       ((cl-some (lambda (cursor) (not (consp cursor))) cursors)
        (agent-scheme--eval-error "map expected proper lists"))
       (t
        (let ((value (agent-scheme--apply-procedure
                      procedure
                      (mapcar #'car cursors)
                      context
                      nil)))
          (when keep-results
            (push (agent-scheme--single-value value "map result")
                  results)))
        (setq cursors (mapcar #'cdr cursors)))))
    (if keep-results
        (nreverse results)
      agent-scheme-unspecified)))

(defun agent-scheme--primitive-apply (arguments context)
  "Primitive apply over ARGUMENTS."
  (let* ((procedure (agent-scheme--expect-procedure
                     (car arguments) "apply procedure"))
         (fixed-arguments (butlast (cdr arguments)))
         (tail (car (last arguments)))
         (tail-arguments
          (agent-scheme--proper-list-elements tail "apply final argument")))
    (agent-scheme--apply-procedure
     procedure
     (append fixed-arguments tail-arguments)
     context
     nil)))

(defun agent-scheme--primitive-apply/k (arguments context continuation)
  "CPS primitive apply over ARGUMENTS."
  (let* ((procedure (agent-scheme--expect-procedure
                     (car arguments) "apply procedure"))
         (fixed-arguments (butlast (cdr arguments)))
         (tail (car (last arguments)))
         (tail-arguments
          (agent-scheme--proper-list-elements tail "apply final argument")))
    (agent-scheme--apply-procedure
     procedure
     (append fixed-arguments tail-arguments)
     context
     t
     continuation)))

(defun agent-scheme--primitive-values (arguments _context)
  "Primitive values over ARGUMENTS."
  (agent-scheme--make-multiple-values arguments))

(defun agent-scheme--primitive-call-with-values (arguments context)
  "Primitive call-with-values over ARGUMENTS."
  (let* ((producer (agent-scheme--expect-procedure
                    (car arguments) "call-with-values producer"))
         (consumer (agent-scheme--expect-procedure
                    (cadr arguments) "call-with-values consumer"))
         (produced (agent-scheme--apply-procedure producer nil context nil)))
    (agent-scheme--apply-procedure
     consumer
     (agent-scheme--values-list produced)
     context
     nil)))

(defun agent-scheme--primitive-call-with-values/k
    (arguments context continuation)
  "CPS primitive call-with-values over ARGUMENTS."
  (let ((producer (agent-scheme--expect-procedure
                   (car arguments) "call-with-values producer"))
        (consumer (agent-scheme--expect-procedure
                   (cadr arguments) "call-with-values consumer")))
    (agent-scheme--apply-procedure
     producer
     nil
     context
     t
     (lambda (produced)
       (agent-scheme--apply-procedure
        consumer
        (agent-scheme--values-list produced)
        context
        t
        continuation)))))

(defun agent-scheme--primitive-call/cc (arguments context)
  "Primitive call-with-current-continuation over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-call/cc/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-call/cc/k (arguments context continuation)
  "CPS primitive call-with-current-continuation over ARGUMENTS."
  (let* ((procedure
          (agent-scheme--expect-procedure
           (car arguments)
           "call-with-current-continuation procedure"))
         (captured
          (agent-scheme--make-continuation
           continuation
           (copy-sequence
            (agent-scheme--eval-context-dynamic-winds context))
           (copy-sequence
            (agent-scheme--eval-context-exception-handlers context)))))
    (agent-scheme--apply-procedure
     procedure
     (list captured)
     context
     t
     continuation)))

(defun agent-scheme--invoke-continuation
    (continuation arguments context)
  "Invoke captured CONTINUATION with ARGUMENTS in CONTEXT."
  (agent-scheme--switch-dynamic-winds
   (agent-scheme--continuation-dynamic-winds continuation)
   context)
  (setf (agent-scheme--eval-context-exception-handlers context)
        (copy-sequence
         (agent-scheme--continuation-exception-handlers continuation)))
  (agent-scheme--continue
   (agent-scheme--continuation-procedure continuation)
   (agent-scheme--continuation-value arguments)))

(defun agent-scheme--primitive-dynamic-wind (arguments context)
  "Primitive dynamic-wind over ARGUMENTS."
  (agent-scheme--drain-state
   (agent-scheme--primitive-dynamic-wind/k
    arguments context #'agent-scheme--identity-continuation)
   context))

(defun agent-scheme--primitive-dynamic-wind/k
    (arguments context continuation)
  "CPS primitive dynamic-wind over ARGUMENTS."
  (let* ((before (agent-scheme--expect-procedure
                  (car arguments) "dynamic-wind before"))
         (thunk (agent-scheme--expect-procedure
                 (cadr arguments) "dynamic-wind thunk"))
         (after (agent-scheme--expect-procedure
                 (caddr arguments) "dynamic-wind after"))
         (frame (agent-scheme--make-dynamic-wind-frame before after)))
    (agent-scheme--call-ignoring-values/k
     before
     context
     "dynamic-wind before"
     (lambda (_ignored)
       (push frame (agent-scheme--eval-context-dynamic-winds context))
       (agent-scheme--apply-procedure
        thunk
        nil
        context
        t
        (lambda (result)
          (when (eq (car (agent-scheme--eval-context-dynamic-winds context))
                    frame)
            (pop (agent-scheme--eval-context-dynamic-winds context)))
          (agent-scheme--call-ignoring-values/k
           after
           context
           "dynamic-wind after"
           (lambda (_after-result)
             (agent-scheme--continue continuation result)))))))))

(defun agent-scheme--current-exception-handler (context)
  "Return CONTEXT's current exception handler, or nil."
  (car (agent-scheme--eval-context-exception-handlers context)))

(defun agent-scheme--invoke-exception-handler (condition context)
  "Invoke the current exception handler for CONDITION."
  (let* ((handlers (agent-scheme--eval-context-exception-handlers context))
         (handler (car handlers))
         (old-error (agent-scheme--eval-context-current-error context)))
    (unless handler
      (agent-scheme--eval-error
       "unhandled exception: %s"
       (agent-scheme-value->external condition)))
    (unwind-protect
        (progn
          (setf (agent-scheme--eval-context-current-error context)
                (agent-scheme-debugger-exception-datum condition context))
          (setf (agent-scheme--eval-context-exception-handlers context)
                (cdr handlers))
          (agent-scheme--apply-procedure
           handler
           (list condition)
           context
           nil))
      (setf (agent-scheme--eval-context-exception-handlers context)
            handlers)
      (setf (agent-scheme--eval-context-current-error context)
            old-error))))

(defun agent-scheme--invoke-exception-handler/k
    (condition context continuation)
  "Invoke the current exception handler for CONDITION, then CONTINUATION."
  (let* ((handlers (agent-scheme--eval-context-exception-handlers context))
         (handler (car handlers))
         (old-error (agent-scheme--eval-context-current-error context)))
    (unless handler
      (agent-scheme--eval-error
       "unhandled exception: %s"
       (agent-scheme-value->external condition)))
    (setf (agent-scheme--eval-context-current-error context)
          (agent-scheme-debugger-exception-datum condition context))
    (setf (agent-scheme--eval-context-exception-handlers context)
          (cdr handlers))
    (agent-scheme--apply-procedure
     handler
     (list condition)
     context
     t
     (lambda (value)
       (setf (agent-scheme--eval-context-exception-handlers context)
             handlers)
       (setf (agent-scheme--eval-context-current-error context)
             old-error)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-with-exception-handler (arguments context)
  "Primitive with-exception-handler over ARGUMENTS."
  (let ((handler (agent-scheme--expect-procedure
                  (car arguments) "with-exception-handler handler"))
        (thunk (agent-scheme--expect-procedure
                (cadr arguments) "with-exception-handler thunk"))
        (old-handlers (agent-scheme--eval-context-exception-handlers context)))
    (unwind-protect
        (progn
          (setf (agent-scheme--eval-context-exception-handlers context)
                (cons handler old-handlers))
          (agent-scheme--apply-procedure thunk nil context nil))
      (setf (agent-scheme--eval-context-exception-handlers context)
            old-handlers))))

(defun agent-scheme--primitive-with-exception-handler/k
    (arguments context continuation)
  "CPS primitive with-exception-handler over ARGUMENTS."
  (let ((handler (agent-scheme--expect-procedure
                  (car arguments) "with-exception-handler handler"))
        (thunk (agent-scheme--expect-procedure
                (cadr arguments) "with-exception-handler thunk"))
        (old-handlers (agent-scheme--eval-context-exception-handlers context)))
    (setf (agent-scheme--eval-context-exception-handlers context)
          (cons handler old-handlers))
    (agent-scheme--apply-procedure
     thunk
     nil
     context
     t
     (lambda (value)
       (setf (agent-scheme--eval-context-exception-handlers context)
             old-handlers)
       (agent-scheme--continue continuation value)))))

(defun agent-scheme--primitive-raise-continuable (arguments context)
  "Primitive raise-continuable over ARGUMENTS."
  (agent-scheme--invoke-exception-handler (car arguments) context))

(defun agent-scheme--primitive-raise-continuable/k
    (arguments context continuation)
  "CPS primitive raise-continuable over ARGUMENTS."
  (agent-scheme--invoke-exception-handler/k
   (car arguments) context continuation))

(defun agent-scheme--primitive-raise (arguments context)
  "Primitive raise over ARGUMENTS."
  (agent-scheme--invoke-exception-handler (car arguments) context)
  (agent-scheme--eval-error "non-continuable exception handler returned"))

(defun agent-scheme--primitive-raise/k (arguments context _continuation)
  "CPS primitive raise over ARGUMENTS."
  (agent-scheme--invoke-exception-handler/k
   (car arguments)
   context
   (lambda (_value)
     (agent-scheme--eval-error
      "non-continuable exception handler returned"))))

(defun agent-scheme--primitive-error (arguments context)
  "Primitive error over ARGUMENTS."
  (let ((message (agent-scheme--expect-string (car arguments) "error message"))
        (irritants (cdr arguments)))
    (agent-scheme--primitive-raise
     (list (agent-scheme--make-error-object message irritants))
     context)))

(defun agent-scheme--primitive-error/k (arguments context continuation)
  "CPS primitive error over ARGUMENTS."
  (let ((message (agent-scheme--expect-string (car arguments) "error message"))
        (irritants (cdr arguments)))
    (agent-scheme--primitive-raise/k
     (list (agent-scheme--make-error-object message irritants))
     context
     continuation)))

(defun agent-scheme--primitive-error-object? (arguments _context)
  "Primitive error-object? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme-error-object-p (car arguments))))

(defun agent-scheme--expect-error-object (value description)
  "Return VALUE as an error object for DESCRIPTION."
  (unless (agent-scheme-error-object-p value)
    (agent-scheme--eval-error
     "%s expected an error object, got %s"
     description
     (agent-scheme-value->external value)))
  value)

(defun agent-scheme--primitive-error-object-message (arguments _context)
  "Primitive error-object-message over ARGUMENTS."
  (agent-scheme-error-object-message
   (agent-scheme--expect-error-object
    (car arguments) "error-object-message")))

(defun agent-scheme--primitive-error-object-irritants (arguments _context)
  "Primitive error-object-irritants over ARGUMENTS."
  (copy-sequence
   (agent-scheme-error-object-irritants
    (agent-scheme--expect-error-object
     (car arguments) "error-object-irritants"))))

(defun agent-scheme--primitive-map (arguments context)
  "Primitive map over ARGUMENTS."
  (agent-scheme--map-over-lists
   (agent-scheme--expect-procedure (car arguments) "map procedure")
   (cdr arguments)
   context
   t))

(defun agent-scheme--primitive-for-each (arguments context)
  "Primitive for-each over ARGUMENTS."
  (agent-scheme--map-over-lists
   (agent-scheme--expect-procedure (car arguments) "for-each procedure")
   (cdr arguments)
   context
   nil))

(defun agent-scheme--primitive-vector? (arguments _context)
  "Primitive vector? over ARGUMENTS."
  (agent-scheme--scheme-boolean (vectorp (car arguments))))

(defun agent-scheme--primitive-make-vector (arguments _context)
  "Primitive make-vector over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-vector"))
         (fill (if (cdr arguments) (cadr arguments) agent-scheme-unspecified)))
    (when (< length 0)
      (agent-scheme--eval-error "make-vector length must be non-negative"))
    (make-vector length fill)))

(defun agent-scheme--primitive-vector (arguments _context)
  "Primitive vector over ARGUMENTS."
  (vconcat arguments))

(defun agent-scheme--primitive-vector-length (arguments _context)
  "Primitive vector-length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length (agent-scheme--expect-vector
            (car arguments) "vector-length"))))

(defun agent-scheme--primitive-vector-ref (arguments _context)
  "Primitive vector-ref over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-ref"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length vector) "vector-ref")))
    (aref vector index)))

(defun agent-scheme--primitive-vector-set! (arguments _context)
  "Primitive vector-set! over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-set!"))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length vector) "vector-set!")))
    (aset vector index (caddr arguments))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-vector->list (arguments _context)
  "Primitive vector->list over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector->list"))
         (range (agent-scheme--optional-range
                 arguments 1 (length vector) "vector->list"))
         result)
    (cl-loop for index from (car range) below (cdr range)
             do (push (aref vector index) result))
    (nreverse result)))

(defun agent-scheme--primitive-list->vector (arguments _context)
  "Primitive list->vector over ARGUMENTS."
  (vconcat (agent-scheme--proper-list-elements
            (car arguments) "list->vector")))

(defun agent-scheme--primitive-vector-copy (arguments _context)
  "Primitive vector-copy over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-copy"))
         (range (agent-scheme--optional-range
                 arguments 1 (length vector) "vector-copy")))
    (cl-subseq vector (car range) (cdr range))))

(defun agent-scheme--primitive-vector-copy! (arguments _context)
  "Primitive vector-copy! over ARGUMENTS."
  (let* ((to (agent-scheme--expect-vector (car arguments) "vector-copy! target"))
         (at (agent-scheme--expect-nonnegative-index
              (cadr arguments) (length to) "vector-copy!" t))
         (from (agent-scheme--expect-vector
                (caddr arguments) "vector-copy! source"))
         (range (agent-scheme--optional-range
                 arguments 3 (length from) "vector-copy!"))
         (slice (cl-subseq from (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to))
      (agent-scheme--eval-error "vector-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to (+ at index) (aref slice index)))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-vector-append (arguments _context)
  "Primitive vector-append over ARGUMENTS."
  (apply #'vconcat
         (mapcar
          (lambda (argument)
            (agent-scheme--expect-vector argument "vector-append"))
          arguments)))

(defun agent-scheme--primitive-vector-fill! (arguments _context)
  "Primitive vector-fill! over ARGUMENTS."
  (let* ((vector (agent-scheme--expect-vector (car arguments) "vector-fill!"))
         (fill (cadr arguments))
         (range (agent-scheme--optional-range
                 arguments 2 (length vector) "vector-fill!")))
    (cl-loop for index from (car range) below (cdr range)
             do (aset vector index fill))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-bytevector? (arguments _context)
  "Primitive bytevector? over ARGUMENTS."
  (agent-scheme--scheme-boolean
   (agent-scheme-bytevector-p (car arguments))))

(defun agent-scheme--primitive-make-bytevector (arguments _context)
  "Primitive make-bytevector over ARGUMENTS."
  (let* ((length (agent-scheme--exact-integer->host
                  (car arguments) "make-bytevector"))
         (fill (if (cdr arguments)
                   (agent-scheme--expect-byte
                    (cadr arguments) "make-bytevector fill")
                 0)))
    (when (< length 0)
      (agent-scheme--eval-error "make-bytevector length must be non-negative"))
    (agent-scheme--make-bytevector (make-vector length fill))))

(defun agent-scheme--primitive-bytevector (arguments _context)
  "Primitive bytevector over ARGUMENTS."
  (agent-scheme--make-bytevector
   (vconcat
    (mapcar
     (lambda (argument)
       (agent-scheme--expect-byte argument "bytevector"))
     arguments))))

(defun agent-scheme--primitive-bytevector-length (arguments _context)
  "Primitive bytevector-length over ARGUMENTS."
  (agent-scheme--number-from-host
   (length
    (agent-scheme-bytevector-bytes
     (agent-scheme--expect-bytevector
      (car arguments) "bytevector-length")))))

(defun agent-scheme--primitive-bytevector-u8-ref (arguments _context)
  "Primitive bytevector-u8-ref over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "bytevector-u8-ref"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length bytes) "bytevector-u8-ref")))
    (agent-scheme--number-from-host (aref bytes index))))

(defun agent-scheme--primitive-bytevector-u8-set! (arguments _context)
  "Primitive bytevector-u8-set! over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "bytevector-u8-set!"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (index (agent-scheme--expect-nonnegative-index
                 (cadr arguments) (length bytes) "bytevector-u8-set!")))
    (aset bytes index
          (agent-scheme--expect-byte
           (caddr arguments) "bytevector-u8-set! value"))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-bytevector-copy (arguments _context)
  "Primitive bytevector-copy over ARGUMENTS."
  (let* ((bytevector (agent-scheme--expect-bytevector
                      (car arguments) "bytevector-copy"))
         (bytes (agent-scheme-bytevector-bytes bytevector))
         (range (agent-scheme--optional-range
                 arguments 1 (length bytes) "bytevector-copy")))
    (agent-scheme--make-bytevector
     (cl-subseq bytes (car range) (cdr range)))))

(defun agent-scheme--primitive-bytevector-copy! (arguments _context)
  "Primitive bytevector-copy! over ARGUMENTS."
  (let* ((to (agent-scheme--expect-bytevector
              (car arguments) "bytevector-copy! target"))
         (to-bytes (agent-scheme-bytevector-bytes to))
         (at (agent-scheme--expect-nonnegative-index
              (cadr arguments) (length to-bytes) "bytevector-copy!" t))
         (from (agent-scheme--expect-bytevector
                (caddr arguments) "bytevector-copy! source"))
         (from-bytes (agent-scheme-bytevector-bytes from))
         (range (agent-scheme--optional-range
                 arguments 3 (length from-bytes) "bytevector-copy!"))
         (slice (cl-subseq from-bytes (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to-bytes))
      (agent-scheme--eval-error "bytevector-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to-bytes (+ at index) (aref slice index)))
    agent-scheme-unspecified))

(defun agent-scheme--primitive-bytevector-append (arguments _context)
  "Primitive bytevector-append over ARGUMENTS."
  (agent-scheme--make-bytevector
   (apply #'vconcat
          (mapcar
           (lambda (argument)
             (agent-scheme-bytevector-bytes
              (agent-scheme--expect-bytevector argument "bytevector-append")))
           arguments))))


(defun agent-scheme--result-field (name &rest values)
  "Return a Scheme-readable result field named NAME with VALUES."
  (cons (agent-scheme--syntax-symbol name) values))

(defun agent-scheme--result-symbol (name)
  "Return a Scheme symbol for result NAME."
  (agent-scheme--syntax-symbol name))

(defun agent-scheme--value->result-datum (value &optional seen)
  "Return VALUE encoded as a Scheme-readable result datum.
Opaque runtime values are represented by tagged data rather than host
objects so result records can be rendered by `agent-scheme-datum->external'."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((or (null value)
          (eq value agent-scheme-true)
          (eq value agent-scheme-false)
          (agent-scheme-symbol-p value)
          (agent-scheme-character-p value)
          (agent-scheme-number-p value)
          (stringp value)
          (agent-scheme-bytevector-p value))
      value)
     ((agent-scheme--identifier-p value)
      (agent-scheme--syntax-symbol
       (agent-scheme--identifier-name value)))
     ((agent-scheme-unspecified-p value)
      (list (agent-scheme--result-symbol "unspecified")))
     ((agent-scheme-primitive-procedure-p value)
      (list (agent-scheme--result-symbol "procedure")
            (agent-scheme--result-field "kind"
                                        (agent-scheme--result-symbol "primitive"))
            (agent-scheme--result-field
             "name"
             (agent-scheme--syntax-symbol
              (agent-scheme-primitive-procedure-name value)))))
     ((agent-scheme-procedure-p value)
      (list (agent-scheme--result-symbol "procedure")
            (agent-scheme--result-field "kind"
                                        (agent-scheme--result-symbol "compound"))))
     ((agent-scheme--continuation-p value)
      (list (agent-scheme--result-symbol "procedure")
            (agent-scheme--result-field "kind"
                                        (agent-scheme--result-symbol "continuation"))))
     ((agent-scheme-error-object-p value)
      (list (agent-scheme--result-symbol "error-object")
            (agent-scheme--result-field
             "message"
             (agent-scheme-error-object-message value))
            (agent-scheme--result-field
             "irritants"
             (mapcar (lambda (irritant)
                       (agent-scheme--value->result-datum irritant seen))
                     (agent-scheme-error-object-irritants value)))))
     ((agent-scheme-eof-object-p value)
      (list (agent-scheme--result-symbol "eof-object")))
     ((agent-scheme--port-p value)
      (list (agent-scheme--result-symbol "port")
            (agent-scheme--result-field
             "medium"
             (agent-scheme--result-symbol
              (symbol-name (agent-scheme--port-medium value))))
            (agent-scheme--result-field
             "open"
             (agent-scheme--scheme-boolean
              (agent-scheme--port-openp value)))))
     ((agent-scheme--environment-specifier-p value)
      (list (agent-scheme--result-symbol "environment")))
     ((agent-scheme-record-type-p value)
      (list (agent-scheme--result-symbol "record-type")
            (agent-scheme--result-field
             "name"
             (agent-scheme--syntax-symbol
              (agent-scheme-record-type-name value)))))
     ((agent-scheme-record-p value)
      (list (agent-scheme--result-symbol "record")
            (agent-scheme--result-field
             "type"
             (agent-scheme--syntax-symbol
              (agent-scheme-record-type-name
               (agent-scheme-record-type value))))))
     ((consp value)
      (if (gethash value seen)
          (list (agent-scheme--result-symbol "cycle"))
        (puthash value t seen)
        (cons (agent-scheme--value->result-datum (car value) seen)
              (agent-scheme--value->result-datum (cdr value) seen))))
     ((vectorp value)
      (if (gethash value seen)
          (vector (agent-scheme--result-symbol "cycle"))
        (puthash value t seen)
        (vconcat
         (mapcar
          (lambda (item)
            (agent-scheme--value->result-datum item seen))
          (append value nil)))))
     (t
      (list (agent-scheme--result-symbol "host-object")
            (agent-scheme--result-field "printed" (format "%S" value)))))))

(defun agent-scheme--budget-result-field (context)
  "Return the budget field for CONTEXT."
  (agent-scheme--result-field
   "budget"
   (agent-scheme--result-field
    "steps-used"
    (agent-scheme--number-from-host
     (agent-scheme--eval-context-steps context)))
   (agent-scheme--result-field
    "host-calls"
    (agent-scheme--number-from-host
     (agent-scheme--eval-context-host-callbacks context)))))

(defun agent-scheme--ok-result-datum (value context)
  "Return a stable Scheme-readable successful evaluation result."
  (if (agent-scheme--multiple-values-p value)
      (list (agent-scheme--result-symbol "evaluation-result")
            (agent-scheme--result-field
             "status"
             (agent-scheme--result-symbol "values"))
            (agent-scheme--result-field
             "values"
             (mapcar #'agent-scheme--value->result-datum
                     (agent-scheme--multiple-values-values value)))
            (agent-scheme--result-field
             "events"
             (agent-scheme--context-events context))
            (agent-scheme--budget-result-field context))
    (list (agent-scheme--result-symbol "evaluation-result")
          (agent-scheme--result-field "status"
                                      (agent-scheme--result-symbol "ok"))
          (agent-scheme--result-field
           "value"
           (agent-scheme--value->result-datum value))
          (agent-scheme--result-field
           "events"
           (agent-scheme--context-events context))
          (agent-scheme--budget-result-field context))))

(defun agent-scheme--condition-result-datum (condition context)
  "Return a stable Scheme-readable error result for CONDITION."
  (let ((condition-name (symbol-name (car condition)))
        (debugger-condition
         (agent-scheme-debugger-condition-datum condition context)))
    (setf (agent-scheme--eval-context-current-error context)
          debugger-condition)
    (list (agent-scheme--result-symbol "evaluation-result")
          (agent-scheme--result-field "status"
                                      (agent-scheme--result-symbol "error"))
          (agent-scheme--result-field
           "error"
           (agent-scheme--result-field
            "condition"
            debugger-condition)
           (agent-scheme--result-field
            "host-condition"
            (agent-scheme--syntax-symbol condition-name))
           (agent-scheme--result-field
            "message"
            (error-message-string condition)))
          (agent-scheme--result-field
           "events"
           (agent-scheme--context-events context))
          (agent-scheme--budget-result-field context))))


(provide 'agent-scheme-interpreter)

;;; agent-scheme-interpreter.el ends here
