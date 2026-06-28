;;; consent-interpreter.el --- R7RS interpreter backend  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Interpreter backend for Consent Scheme.  This module owns evaluation,
;; procedure application, primitive implementations, trampoline execution, and
;; Scheme-readable evaluation result records.  Public orchestration entry points
;; live in `consent-eval'.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-base)
(require 'consent-library)
(require 'consent-macro)
(require 'consent-policy)
(require 'consent-debugger)

(defun consent--dynamic-wind-prefix-before (frame stack)
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

(defun consent--dynamic-wind-common-frame (current target)
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

(defun consent--call-ignoring-values (procedure context description)
  "Call zero-argument PROCEDURE in CONTEXT and discard its values."
  (consent--expect-procedure procedure description)
  (consent--apply-procedure procedure nil context nil)
  consent-unspecified)

(defun consent--call-ignoring-values/k
    (procedure context description continuation)
  "Call zero-argument PROCEDURE and continue with unspecified."
  (consent--expect-procedure procedure description)
  (consent--apply-procedure
   procedure
   nil
   context
   t
   (lambda (_value)
     (consent--continue continuation consent-unspecified))))

(defun consent--switch-dynamic-winds (target context)
  "Run dynamic-wind thunks needed to move CONTEXT to TARGET."
  (let* ((current (consent--eval-context-dynamic-winds context))
         (common (consent--dynamic-wind-common-frame current target))
         (exiting (if common
                      (consent--dynamic-wind-prefix-before common current)
                    current))
         (entering (if common
                       (consent--dynamic-wind-prefix-before common target)
                     target)))
    (dolist (frame exiting)
      (when (eq (car (consent--eval-context-dynamic-winds context)) frame)
        (pop (consent--eval-context-dynamic-winds context)))
      (consent--call-ignoring-values
       (consent--dynamic-wind-frame-after frame)
       context
       "dynamic-wind after"))
    (dolist (frame (reverse entering))
      (consent--call-ignoring-values
       (consent--dynamic-wind-frame-before frame)
       context
       "dynamic-wind before")
      (push frame (consent--eval-context-dynamic-winds context)))
    (setf (consent--eval-context-dynamic-winds context)
          (copy-sequence target))))

(defun consent--expect-identifier-key (datum description)
  "Return DATUM's lexical binding key or signal an error."
  (unless (consent--identifier-datum-p datum)
    (consent--eval-error "%s must be an identifier" description))
  (consent--identifier-key datum))

(defun consent--parse-formals (formals)
  "Parse Scheme FORMALS into an `consent--formals' value."
  (cond
   ((consent-symbol-p formals)
    (consent--make-formals nil (consent--identifier-key formals)))
   ((consent--identifier-p formals)
    (consent--make-formals nil (consent--identifier-key formals)))
   (t
    (let ((cursor formals)
          required
          rest)
      (while (consp cursor)
        (push (consent--expect-identifier-key
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

(defun consent--self-evaluating-p (expression)
  "Return non-nil when EXPRESSION is a self-evaluating datum."
  (or (eq expression consent-true)
      (eq expression consent-false)
      (consent-number-p expression)
      (consent-character-p expression)
      (stringp expression)
      (vectorp expression)
      (consent-bytevector-p expression)))

(defun consent--true-value-p (value)
  "Return non-nil if VALUE counts as true in Scheme."
  (not (eq value consent-false)))

(defun consent--make-lambda-expression (formals body)
  "Construct a lambda expression from FORMALS and BODY."
  (cons (consent--syntax-symbol "lambda")
        (cons formals body)))

(defun consent--parse-definition (form)
  "Parse supported DEFINE FORM.
Return a cons cell (NAME . INITIALIZER-EXPRESSION)."
  (let ((parts (consent--proper-list-elements form "define form")))
    (unless (>= (length parts) 3)
      (consent--eval-error "define requires a target and a value"))
    (let ((target (cadr parts))
          (body (cddr parts)))
      (cond
       ((consent-symbol-p target)
        (unless (= (length body) 1)
          (consent--eval-error
           "variable define requires exactly one expression"))
        (cons (consent--identifier-key target) (car body)))
       ((consent--identifier-p target)
        (unless (= (length body) 1)
          (consent--eval-error
           "variable define requires exactly one expression"))
        (cons (consent--identifier-key target) (car body)))
       ((consp target)
        (let ((name (consent--expect-identifier-key
                     (car target) "function define name")))
          (unless body
            (consent--eval-error "function define requires a body"))
          (cons name
                (consent--make-lambda-expression (cdr target) body))))
       (t
        (consent--eval-error
         "define target must be an identifier or function signature"))))))

(defun consent--body-definition-form-p (form)
  "Return non-nil if FORM is a body definition."
  (or (consent--definition-form-p form)
      (consent--define-values-form-p form)
      (consent--record-definition-form-p form)))

(defun consent--parse-record-definition (form)
  "Parse a R7RS define-record-type FORM into a plist."
  (let ((parts (consent--proper-list-elements
                form "define-record-type form")))
    (unless (>= (length parts) 4)
      (consent--eval-error
       "define-record-type requires name, constructor, predicate, and fields"))
    (let* ((type-name (consent--expect-identifier-key
                       (nth 1 parts) "record type name"))
           (constructor-spec
            (consent--proper-list-elements
             (nth 2 parts) "record constructor"))
           (constructor-name
            (consent--expect-identifier-key
             (car constructor-spec) "record constructor name"))
           (constructor-fields
            (mapcar (lambda (field)
                      (consent--expect-identifier-key
                       field "record constructor field"))
                    (cdr constructor-spec)))
           (predicate-name
            (consent--expect-identifier-key
             (nth 3 parts) "record predicate name"))
           fields accessors mutators)
      (dolist (field-spec (nthcdr 4 parts))
        (let ((field-parts
               (consent--proper-list-elements
                field-spec "record field")))
          (unless (or (= (length field-parts) 2)
                      (= (length field-parts) 3))
            (consent--eval-error
             "record field requires name, accessor, and optional mutator"))
          (let ((field-name (consent--expect-identifier-key
                             (car field-parts) "record field name"))
                (accessor-name (consent--expect-identifier-key
                                (cadr field-parts) "record accessor name"))
                (mutator-name
                 (and (cddr field-parts)
                      (consent--expect-identifier-key
                       (caddr field-parts) "record mutator name"))))
            (push field-name fields)
            (push (cons accessor-name field-name) accessors)
            (when mutator-name
              (push (cons mutator-name field-name) mutators)))))
      (setq fields (nreverse fields)
            accessors (nreverse accessors)
            mutators (nreverse mutators))
      (consent--ensure-distinct-names fields "record fields")
      (consent--ensure-distinct-names
       (append (mapcar #'car accessors) (mapcar #'car mutators))
       "record accessors and mutators")
      (dolist (field constructor-fields)
        (unless (member field fields)
          (consent--eval-error
           "record constructor references unknown field: %s" field)))
      (list :type-name type-name
            :constructor-name constructor-name
            :constructor-fields constructor-fields
            :predicate-name predicate-name
            :fields fields
            :accessors accessors
            :mutators mutators))))

(defun consent--record-definition-bound-names (form)
  "Return names bound by define-record-type FORM."
  (let ((spec (consent--parse-record-definition form)))
    (append
     (list (plist-get spec :type-name)
           (plist-get spec :constructor-name)
           (plist-get spec :predicate-name))
     (mapcar #'car (plist-get spec :accessors))
     (mapcar #'car (plist-get spec :mutators)))))

(defun consent--record-field-index (record-type field)
  "Return FIELD index in RECORD-TYPE."
  (or (cl-position field (consent-record-type-fields record-type)
                   :test #'equal)
      (consent--eval-error
       "record type does not contain field: %s" field)))

(defun consent--expect-record-of-type (value record-type description)
  "Return VALUE as a record of RECORD-TYPE or signal DESCRIPTION."
  (unless (and (consent-record-p value)
               (eq (consent-record-type value) record-type))
    (consent--eval-error "%s expected record" description))
  value)

(defun consent--define-or-set-record-binding (environment name value)
  "Define NAME as VALUE in ENVIRONMENT, or set an existing local cell."
  (let ((cell (gethash name
                       (consent--environment-bindings environment)
                       consent--missing-cell)))
    (if (not (eq cell consent--missing-cell))
        (progn
          (when (consent--current-environment-imported-p
                 environment name)
            (consent--eval-error
             "cannot redefine imported binding: %s" name))
          (setf (consent--cell-value cell) value))
      (consent--environment-define environment name value))))

(defun consent--eval-record-definition (form environment _context)
  "Evaluate a define-record-type FORM in ENVIRONMENT."
  (let* ((spec (consent--parse-record-definition form))
         (type-name (plist-get spec :type-name))
         (fields (plist-get spec :fields))
         (record-type (consent--make-record-type type-name fields))
         (constructor-fields (plist-get spec :constructor-fields))
         (constructor
          (consent--make-primitive-procedure
           (plist-get spec :constructor-name)
           (lambda (arguments context)
             (let ((values (make-vector (length fields)
                                        consent-unspecified)))
               (cl-loop for field in constructor-fields
                        for argument in arguments
                        do (aset values
                                 (consent--record-field-index
                                  record-type field)
                                 argument))
               ;; Charge the record header plus its field slots; the field
               ;; values were charged where they were allocated.
               (consent--charge-value-allocation
                (consent--make-record record-type values)
                (1+ (length values))
                context)))
           (length constructor-fields)
           (length constructor-fields)))
         (predicate
          (consent--make-primitive-procedure
           (plist-get spec :predicate-name)
           (lambda (arguments _context)
             (consent--scheme-boolean
              (and (consent-record-p (car arguments))
                   (eq (consent-record-type (car arguments))
                       record-type))))
           1
           1)))
    (consent--define-or-set-record-binding
     environment type-name record-type)
    (consent--define-or-set-record-binding
     environment (plist-get spec :constructor-name) constructor)
    (consent--define-or-set-record-binding
     environment (plist-get spec :predicate-name) predicate)
    (dolist (accessor (plist-get spec :accessors))
      (let* ((name (car accessor))
             (field (cdr accessor))
             (index (consent--record-field-index record-type field)))
        (consent--define-or-set-record-binding
         environment
         name
         (consent--make-primitive-procedure
          name
          (lambda (arguments _context)
            (aref (consent-record-fields
                   (consent--expect-record-of-type
                    (car arguments) record-type name))
                  index))
          1
          1))))
    (dolist (mutator (plist-get spec :mutators))
      (let* ((name (car mutator))
             (field (cdr mutator))
             (index (consent--record-field-index record-type field)))
        (consent--define-or-set-record-binding
         environment
         name
         (consent--make-primitive-procedure
          name
          (lambda (arguments _context)
            (aset (consent-record-fields
                   (consent--expect-record-of-type
                    (car arguments) record-type name))
                  index
                  (cadr arguments))
            consent-unspecified)
          2
          2))))
    consent-unspecified))

(defun consent--split-body (body)
  "Split BODY into leading definitions and remaining expressions."
  (let ((cursor body)
        definitions)
    (while (and cursor (consent--body-definition-form-p (car cursor)))
      (push (car cursor) definitions)
      (setq cursor (cdr cursor)))
    (unless cursor
      (consent--eval-error "body must contain at least one expression"))
    (cons (nreverse definitions) cursor)))

(defun consent--body-documentation (body &rest maybe-formals)
  "Return documentation metadata from BODY and optional FORMALS."
  (apply
   #'consent--documentation-metadata-from-body
   body
   #'consent--body-definition-form-p
   maybe-formals))

(defun consent--body-documentation-result (body context &rest maybe-formals)
  "Return documentation metadata and rewritten BODY for CONTEXT."
  (apply
   #'consent--documentation-body-result
   body
   #'consent--body-definition-form-p
   (consent--eval-context-docstring-retention-mode context)
   maybe-formals))

(defun consent--prepare-body-environment (body environment context)
  "Return (ENVIRONMENT . EXPRESSIONS) for lambda BODY.
Internal definitions are installed in fresh locations before their
initializers are evaluated."
  (let* ((split (consent--split-body body))
         (definitions (car split))
         (expressions (cdr split)))
    (if (null definitions)
        (cons environment expressions)
      (let ((body-environment (consent-make-empty-environment environment))
            parsed)
        (dolist (definition definitions)
          (cond
           ((consent--definition-form-p definition)
            (let ((parsed-definition
                   (consent--parse-definition definition)))
              (push (cons 'define parsed-definition) parsed)
              ;; Install all internal-definition names before any initializer is
              ;; evaluated so mutually recursive bodies see allocated locations.
              (unless (eq (gethash (car parsed-definition)
                                    (consent--environment-bindings
                                     body-environment)
                                    consent--missing-cell)
                          consent--missing-cell)
                (consent--eval-error
                 "duplicate internal definition: %s"
                 (car parsed-definition)))
              (consent--environment-define
               body-environment (car parsed-definition)
               consent--undefined)))
           ((consent--define-values-form-p definition)
            (push (cons 'define-values
                        (consent--parse-define-values definition))
                  parsed)
            (dolist (name (consent--define-values-bound-names definition))
              (unless (eq (gethash name
                                    (consent--environment-bindings
                                     body-environment)
                                    consent--missing-cell)
                          consent--missing-cell)
                (consent--eval-error
                 "duplicate internal definition: %s" name))
              (consent--environment-define
               body-environment name consent--undefined)))
           ((consent--record-definition-form-p definition)
            (push (cons 'record definition) parsed)
            (dolist (name (consent--record-definition-bound-names
                           definition))
              (unless (eq (gethash name
                                    (consent--environment-bindings
                                     body-environment)
                                    consent--missing-cell)
                          consent--missing-cell)
                (consent--eval-error
                 "duplicate internal definition: %s" name))
              (consent--environment-define
               body-environment name consent--undefined)))))
        (dolist (parsed-definition (nreverse parsed))
          (pcase (car parsed-definition)
            ('define
             (consent--environment-set-cell
              body-environment
              (cadr parsed-definition)
              (consent--eval-expression
               (cddr parsed-definition) body-environment context nil)))
            ('define-values
             (let ((define-values (cdr parsed-definition)))
               (consent--define-values-bind
                (car define-values)
                (consent--values-list
                 (consent--eval-expression
                  (cdr define-values) body-environment context nil))
                body-environment
                context
                "define-values")))
            ('record
             (consent--eval-record-definition
              (cdr parsed-definition) body-environment context))))
        (cons body-environment expressions)))))

(defun consent--eval-definition
    (form environment context &optional continuation)
  "Evaluate top-level definition FORM in ENVIRONMENT."
  (let* ((parsed (consent--parse-definition form))
         (name (car parsed))
         (cell (gethash name
                        (consent--environment-bindings environment)
                        consent--missing-cell))
         (direct-call (null continuation))
         (next (or continuation #'consent--identity-continuation)))
    (let ((state
           (consent--eval-expression
            (cdr parsed)
            environment
            context
            nil
            (lambda (raw-value)
              (let ((value
                     (consent--single-value
                      raw-value "define initializer")))
                (if (not (eq cell consent--missing-cell))
                    (progn
                      (when (consent--current-environment-imported-p
                             environment name)
                        (consent--eval-error
                         "cannot redefine imported binding: %s" name))
                      (setf (consent--cell-value cell) value))
                  (consent--environment-define environment name value))
                (consent--continue next consent-unspecified))))))
      (if direct-call
          (consent--drain-state state context)
        state))))

(defun consent--parse-define-values (form)
  "Parse supported DEFINE-VALUES FORM.
Return a cons cell (FORMALS . INITIALIZER-EXPRESSION)."
  (let ((parts (consent--proper-list-elements form "define-values form")))
    (unless (= (length parts) 3)
      (consent--eval-error
       "define-values requires formals and one expression"))
    (cons (consent--parse-formals (cadr parts))
          (caddr parts))))

(defun consent--define-values-bound-names (form)
  "Return names bound by define-values FORM."
  (consent--formals-names
   (car (consent--parse-define-values form))))

(defun consent--define-values-bind
    (formals values environment context description)
  "Bind FORMALS to VALUES in ENVIRONMENT for DESCRIPTION."
  (let* ((required (consent--formals-required formals))
         (rest (consent--formals-rest formals))
         (required-count (length required))
         (value-count (length values)))
    (cond
     ((and (null rest) (/= value-count required-count))
      (consent--eval-error
       "%s expected %d values, got %d"
       description required-count value-count))
     ((and rest (< value-count required-count))
      (consent--eval-error
       "%s expected at least %d values, got %d"
       description required-count value-count)))
    (let ((remaining values))
      (dolist (name required)
        (consent--define-or-set-record-binding
         environment name (car remaining))
        (setq remaining (cdr remaining)))
      (when rest
        (consent--define-or-set-record-binding
         environment rest (copy-sequence remaining))
        ;; The rest list is freshly copied; charge its pairs as allocation.
        (consent--note-value-allocation context (length remaining))))
    consent-unspecified))

(defun consent--eval-define-values
    (form environment context &optional continuation)
  "Evaluate top-level or body define-values FORM in ENVIRONMENT."
  (let* ((parsed (consent--parse-define-values form))
         (formals (car parsed))
         (initializer (cdr parsed))
         (direct-call (null continuation))
         (next (or continuation #'consent--identity-continuation))
         (state
          (consent--eval-expression
           initializer
           environment
           context
           nil
           (lambda (raw-value)
             (consent--define-values-bind
              formals
              (consent--values-list raw-value)
              environment
              context
              "define-values")
             (consent--continue next consent-unspecified)))))
    (if direct-call
        (consent--drain-state state context)
      state)))

(defun consent--bind-formals (formals arguments closure-environment context)
  "Return a call environment for FORMALS bound to ARGUMENTS."
  (let ((environment (consent-make-empty-environment
                      closure-environment)))
    (consent--bind-formals-in-environment
     formals arguments environment context "procedure")
    environment))

(defun consent--bind-formals-in-environment
    (formals arguments environment context description)
  "Bind FORMALS to ARGUMENTS in ENVIRONMENT for DESCRIPTION."
  (let* ((required (consent--formals-required formals))
         (rest (consent--formals-rest formals))
         (required-count (length required))
         (argument-count (length arguments)))
    (cond
     ((and (null rest) (/= argument-count required-count))
      (consent--eval-error
       "%s expected %d values, got %d"
       description
       required-count argument-count))
     ((and rest (< argument-count required-count))
      (consent--eval-error
       "%s expected at least %d values, got %d"
       description
       required-count argument-count)))
    (let ((remaining arguments))
      (dolist (name required)
        (consent--environment-define environment name (car remaining))
        (setq remaining (cdr remaining)))
      (when rest
        (consent--environment-define
         environment rest (copy-sequence remaining))
        ;; The rest list is freshly copied; charge its pairs as allocation.
        (consent--note-value-allocation context (length remaining)))
      environment)))

(defun consent--formals-names (formals)
  "Return all names bound by FORMALS."
  (if (consent--formals-rest formals)
      (append (consent--formals-required formals)
              (list (consent--formals-rest formals)))
    (consent--formals-required formals)))

(defun consent--arity-match-p (primitive count)
  "Return non-nil if PRIMITIVE accepts COUNT arguments."
  (and (>= count
           (consent-primitive-procedure-minimum-arity primitive))
       (let ((maximum
              (consent-primitive-procedure-maximum-arity primitive)))
         (or (null maximum) (<= count maximum)))))

(defun consent--host-condition->condition (condition)
  "Return elisp CONDITION as a value interpreted handlers can inspect.
The signal becomes an interpreter error object so guard clauses can use
`error-object?' and the message and irritant accessors."
  (consent--make-error-object (error-message-string condition) nil))

(defun consent--apply-host-primitive/k (function arguments context continuation)
  "Invoke host primitive FUNCTION and deliver its budgeted result.
An elisp signal escaping FUNCTION (a primitive argument error, a native
module raise) becomes an interpreted raise that walks the context's
exception handlers, so interpreted guard catches primitive errors the way
it catches interpreted raises.  Budget, cancellation, and interrupt
signals propagate unchanged so enforcement stays uncatchable, and when
the handler stack empties before the signal surfaces it also propagates
unchanged, preserving top-level diagnostics."
  (let ((outcome
         (condition-case condition
             (cons :value (funcall function arguments context))
           ((consent-budget-error consent-cancelled-error
                                  consent-interrupt-error)
            (signal (car condition) (cdr condition)))
           (error
            (if (consent--eval-context-exception-handlers context)
                (cons :condition condition)
              (signal (car condition) (cdr condition)))))))
    (if (eq (car outcome) :condition)
        (consent--primitive-raise/k
         (list (consent--host-condition->condition (cdr outcome)))
         context
         continuation)
      ;; Primitive results are no longer walked: allocating primitives charge
      ;; their own nodes, and an accessor result is a substructure of an
      ;; already-budgeted argument, so it creates nothing to charge.
      (consent--continue continuation (cdr outcome)))))

(defun consent--apply-procedure
    (procedure arguments context _tailp &optional continuation)
  "Apply PROCEDURE to ARGUMENTS.
When CONTINUATION is non-nil, deliver the result to it.  When it is nil, run
any resulting bounce to preserve existing direct-call helper behavior."
  (let ((direct-call (null continuation))
        (next (or continuation #'consent--identity-continuation)))
    (cl-labels
        ((finish (state)
           (if direct-call
               (consent--drain-state state context)
             state)))
      (cond
       ((consent-primitive-procedure-p procedure)
        (unless (consent--arity-match-p procedure (length arguments))
          (let ((maximum
                 (consent-primitive-procedure-maximum-arity procedure)))
            (consent--eval-error
             "primitive %s expected %s arguments, got %d"
             (consent-primitive-procedure-name procedure)
             (if maximum
                 (format "%d..%d"
                         (consent-primitive-procedure-minimum-arity
                          procedure)
                         maximum)
               (format "at least %d"
                       (consent-primitive-procedure-minimum-arity
                        procedure)))
             (length arguments))))
        (consent--note-host-callback context procedure)
        (let ((function (consent-primitive-procedure-function procedure)))
          (finish
           (cond
            ((eq function #'consent--primitive-apply)
             (consent--primitive-apply/k arguments context next))
            ((eq function #'consent--primitive-call-with-values)
             (consent--primitive-call-with-values/k arguments context next))
            ((eq function #'consent--primitive-call-with-port)
             (consent--primitive-call-with-port/k arguments context next))
            ((eq function #'consent--primitive-call-with-input-file)
             (consent--primitive-call-with-input-file/k
              arguments context next))
            ((eq function #'consent--primitive-call-with-output-file)
             (consent--primitive-call-with-output-file/k
              arguments context next))
            ((eq function #'consent--primitive-with-input-from-file)
             (consent--primitive-with-input-from-file/k
              arguments context next))
            ((eq function #'consent--primitive-with-output-to-file)
             (consent--primitive-with-output-to-file/k
              arguments context next))
            ((eq function #'consent--primitive-call/cc)
             (consent--primitive-call/cc/k arguments context next))
            ((eq function #'consent--primitive-dynamic-wind)
             (consent--primitive-dynamic-wind/k arguments context next))
            ((eq function #'consent--primitive-with-exception-handler)
             (consent--primitive-with-exception-handler/k
              arguments context next))
            ((eq function #'consent--primitive-raise-continuable)
             (consent--primitive-raise-continuable/k
              arguments context next))
            ((eq function #'consent--primitive-raise)
             (consent--primitive-raise/k arguments context next))
            ((eq function #'consent--primitive-error)
             (consent--primitive-error/k arguments context next))
            ((eq function #'consent--primitive-eval)
             (consent--primitive-eval/k arguments context next))
            ((eq function #'consent--primitive-load)
             (consent--primitive-load/k arguments context next))
            ((eq function #'consent--primitive-make-parameter)
             (consent--primitive-make-parameter/k arguments context next))
            (t
             ;; The guarded path costs a `condition-case' per call, so
             ;; reserve it for dynamic extents with installed interpreted
             ;; handlers; without them conversion would be a no-op.
             (if (consent--eval-context-exception-handlers context)
                 (consent--apply-host-primitive/k
                  function arguments context next)
               (consent--continue
                next
                (funcall function arguments context))))))))
       ((consent-parameter-p procedure)
        (finish
         (consent--apply-parameter/k procedure arguments context next)))
       ((consent-procedure-p procedure)
        (let* ((call-environment
                (consent--bind-formals
                 (consent-procedure-formals procedure)
                 arguments
                 (consent-procedure-environment procedure)
                 context))
               (body-state
                (consent--prepare-body-environment
                 (consent-procedure-body procedure)
                 call-environment
                 context))
               (body-expression
                (consent--make-sequence (cdr body-state) nil)))
          (finish
           (consent--make-bounce
            body-expression
            (car body-state)
            (consent--eval-context-syntax-environment context)
            next))))
       ((consent--continuation-p procedure)
        (finish
         (consent--invoke-continuation procedure arguments context)))
       (t
        (consent--eval-error
         "attempted to call non-procedure: %s"
         (consent-value->external procedure)))))))

(defun consent--eval-if
    (parts environment context tailp continuation)
  "Evaluate an if expression PARTS in ENVIRONMENT."
  (unless (memq (length parts) '(3 4))
    (consent--eval-error "if requires test, consequent, and optional alternate"))
  (consent--eval-expression
   (cadr parts)
   environment
   context
   nil
   (lambda (test-result)
     (let ((test-value
            (consent--single-value test-result "if test")))
       (cond
        ((consent--true-value-p test-value)
         (if tailp
             (consent--make-bounce
              (caddr parts)
              environment
              (consent--eval-context-syntax-environment context)
              continuation)
           (consent--eval-expression
            (caddr parts) environment context nil continuation)))
        ((= (length parts) 4)
         (if tailp
             (consent--make-bounce
              (cadddr parts)
              environment
              (consent--eval-context-syntax-environment context)
              continuation)
           (consent--eval-expression
            (cadddr parts) environment context nil continuation)))
        (t
         (consent--continue continuation consent-unspecified)))))))

(defun consent--eval-set! (parts environment context continuation)
  "Evaluate a set! expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 3)
    (consent--eval-error "set! requires an identifier and an expression"))
  (let ((target (cadr parts)))
    (consent--eval-expression
     (caddr parts)
     environment
     context
     nil
     (lambda (raw-value)
       (let ((value (consent--single-value raw-value "set! expression")))
         (unless (consent--identifier-datum-p target)
           (consent--eval-error "set! target must be an identifier"))
         (consent--environment-set-identifier environment target value)
         (consent--continue continuation consent-unspecified))))))

(defun consent--eval-quasiquote-list
    (template depth environment context)
  "Evaluate quasiquoted list TEMPLATE at nesting DEPTH."
  (let ((cursor template)
        output)
    (while (consp cursor)
      (let ((element (car cursor)))
        (if (and (= depth 1)
                 (consent--tagged-list-p element "unquote-splicing"))
            (let ((splice
                   (consent--single-value
                    (consent--eval-expression
                     (consent--single-argument-syntax
                      element "unquote-splicing")
                     environment
                     context
                     nil)
                    "unquote-splicing result")))
              (dolist (splice-element
                       (consent--proper-list-elements
                        splice "unquote-splicing result"))
                (push splice-element output)))
          (push (consent--eval-quasiquote-template
                 element depth environment context)
                output)))
      (setq cursor (cdr cursor)))
    (append
     (nreverse output)
     (cond
      ((null cursor) nil)
      ((and (= depth 1)
            (consent--tagged-list-p cursor "unquote"))
       (consent--eval-expression
        (consent--single-argument-syntax cursor "unquote")
        environment
        context
        nil))
      (t
       (consent--eval-quasiquote-template
        cursor depth environment context))))))

(defun consent--eval-quasiquote-template
    (template depth environment context)
  "Evaluate quasiquote TEMPLATE at nesting DEPTH."
  (cond
   ((consent--tagged-list-p template "unquote")
    (let ((operand
           (consent--single-argument-syntax template "unquote")))
      (if (= depth 1)
          (consent--single-value
           (consent--eval-expression operand environment context nil)
           "unquote result")
        (list (car template)
              (consent--eval-quasiquote-template
               operand (1- depth) environment context)))))
   ((consent--tagged-list-p template "unquote-splicing")
    (if (= depth 1)
        (consent--eval-error
         "unquote-splicing is only valid inside a quasiquoted list or vector")
      (let ((operand
             (consent--single-argument-syntax
              template "unquote-splicing")))
        (list (car template)
              (consent--eval-quasiquote-template
               operand (1- depth) environment context)))))
   ((consent--tagged-list-p template "quasiquote")
    (let ((operand
           (consent--single-argument-syntax template "quasiquote")))
      (list (car template)
            (consent--eval-quasiquote-template
             operand (1+ depth) environment context))))
   ((consp template)
    (consent--eval-quasiquote-list
     template depth environment context))
   ((vectorp template)
    (vconcat
     (consent--eval-quasiquote-list
      (append template nil) depth environment context)))
   (t template)))

(defun consent--eval-quasiquote (parts environment context)
  "Evaluate a quasiquote expression PARTS in ENVIRONMENT."
  (unless (= (length parts) 2)
    (consent--eval-error "quasiquote requires exactly one template"))
  (consent--eval-quasiquote-template
   (cadr parts) 1 environment context))

(defun consent--parse-letrec-binding (binding description)
  "Return BINDING as (NAME . INITIALIZER) for DESCRIPTION."
  (let ((parts (consent--proper-list-elements binding description)))
    (unless (= (length parts) 2)
      (consent--eval-error
       "%s binding must contain an identifier and initializer"
       description))
    (cons (consent--expect-identifier-key
           (car parts) description)
          (cadr parts))))

(defun consent--eval-letrec
    (parts environment context tailp sequential &optional continuation)
  "Evaluate letrec or letrec* PARTS in ENVIRONMENT.
When SEQUENTIAL is non-nil, initializer values are installed after
each initializer."
  (unless (>= (length parts) 3)
    (consent--eval-error
     "%s requires bindings and a body"
     (if sequential "letrec*" "letrec")))
  (let* ((description (if sequential "letrec*" "letrec"))
         (bindings
          (mapcar
           (lambda (binding)
             (consent--parse-letrec-binding binding description))
           (consent--proper-list-elements
            (cadr parts) (format "%s binding list" description))))
         (names (mapcar #'car bindings))
         (local-environment
          (consent-make-empty-environment environment)))
    (consent--ensure-distinct-names names description)
    (dolist (name names)
      (consent--environment-define
       local-environment name consent--undefined))
    (if sequential
        (dolist (binding bindings)
           (consent--environment-set-cell
            local-environment
            (car binding)
            (consent--single-value
             (consent--eval-expression
              (cdr binding) local-environment context nil)
             "letrec* initializer")))
      (let (values)
        (dolist (binding bindings)
          (push
           (cons (car binding)
                 (consent--single-value
                  (consent--eval-expression
                   (cdr binding) local-environment context nil)
                  "letrec initializer"))
           values))
        (dolist (binding-value (nreverse values))
          (consent--environment-set-cell
           local-environment
           (car binding-value)
           (cdr binding-value)))))
    (consent--eval-sequence
     (cddr parts)
     local-environment
     context
     tailp
     t
     (or continuation #'consent--identity-continuation))))

(defun consent--parse-mv-binding (binding description)
  "Return BINDING as (FORMALS . INITIALIZER) for DESCRIPTION."
  (let ((parts (consent--proper-list-elements binding description)))
    (unless (= (length parts) 2)
      (consent--eval-error
       "%s binding must contain formals and initializer"
       description))
    (cons (consent--parse-formals (car parts))
          (cadr parts))))

(defun consent--eval-let-values
    (parts environment context tailp sequential &optional continuation)
  "Evaluate let-values or let*-values PARTS in ENVIRONMENT."
  (unless (>= (length parts) 3)
    (consent--eval-error
     "%s requires bindings and a body"
     (if sequential "let*-values" "let-values")))
  (let* ((description (if sequential "let*-values" "let-values"))
         (bindings
          (mapcar
           (lambda (binding)
             (consent--parse-mv-binding binding description))
           (consent--proper-list-elements
            (cadr parts) (format "%s binding list" description))))
         (local-environment
          (consent-make-empty-environment environment)))
    (cl-labels
        ((body ()
           (consent--eval-sequence
            (cddr parts)
            local-environment
            context
            tailp
            t
            (or continuation #'consent--identity-continuation)))
         (step-sequential (remaining)
           (if (null remaining)
               (body)
             (let ((binding (car remaining)))
               (consent--eval-expression
                (cdr binding)
                local-environment
                context
                nil
                (lambda (value)
                  (consent--bind-formals-in-environment
                   (car binding)
                   (consent--values-list value)
                   local-environment
                   context
                   description)
                  (step-sequential (cdr remaining)))))))
         (step-parallel (remaining all-names evaluated)
           (if (null remaining)
               (progn
                 (consent--ensure-distinct-names all-names description)
                 (dolist (binding-values (nreverse evaluated))
                   (consent--bind-formals-in-environment
                    (car binding-values)
                    (cdr binding-values)
                    local-environment
                    context
                    description))
                 (body))
             (let ((binding (car remaining)))
               (consent--eval-expression
                (cdr binding)
                environment
                context
                nil
                (lambda (value)
                  (step-parallel
                   (cdr remaining)
                   (append all-names
                           (consent--formals-names (car binding)))
                   (cons (cons (car binding)
                               (consent--values-list value))
                         evaluated))))))))
      (let* ((direct-call (null continuation))
             (state (if sequential
                        (step-sequential bindings)
                      (step-parallel bindings nil nil))))
        (if direct-call
            (consent--drain-state state context)
          state)))))

(defun consent--eval-arguments
    (operands environment context arguments continuation)
  "Evaluate OPERANDS in order and deliver their single values."
  (if (null operands)
      (consent--continue continuation (nreverse arguments))
    (consent--eval-expression
     (car operands)
     environment
     context
     nil
     (lambda (raw-argument)
       (consent--eval-arguments
        (cdr operands)
        environment
        context
        (cons (consent--single-value raw-argument "procedure argument")
              arguments)
        continuation)))))

(defun consent--eval-combination
    (expression environment context tailp continuation)
  "Evaluate list EXPRESSION in ENVIRONMENT."
  (let ((parts (consent--proper-list-elements expression "expression")))
    (unless parts
      (consent--eval-error "empty list is not an expression"))
    (let ((operator (car parts)))
      (cond
	       ((and (consent--symbol-named-p operator "quote")
	             (consent--special-operator-active-p operator environment))
	        (unless (= (length parts) 2)
	          (consent--eval-error "quote requires exactly one datum"))
	        (consent--continue
                 continuation
                 (consent--charge-literal (cadr parts) context)))
	       ((and (consent--symbol-named-p operator "quasiquote")
	             (consent--special-operator-active-p operator environment))
	        ;; The quasiquote builder assembles its result with host cons/append
	        ;; rather than the charged primitives, so charge the realized result
	        ;; once -- like any other literal -- off the hot primitive path.
	        (consent--continue
                 continuation
                 (consent--charge-literal
	          (consent--eval-quasiquote parts environment context)
	          context)))
	       ((and (consent--symbol-named-p operator "lambda")
	             (consent--special-operator-active-p operator environment))
	        (unless (>= (length parts) 3)
	          (consent--eval-error "lambda requires formals and a body"))
	        (let ((formals (cadr parts))
	              (body (cddr parts)))
                  (let* ((parsed-formals (consent--parse-formals formals))
                         (documentation-result
                          (consent--body-documentation-result
                           body context parsed-formals)))
	            (consent--continue
                     continuation
                     (consent--make-procedure
	              parsed-formals
	              (plist-get documentation-result :body)
	              environment
                      (plist-get documentation-result :metadata))))))
	       ((and (consent--symbol-named-p operator "if")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-if parts environment context tailp continuation))
	       ((and (consent--symbol-named-p operator "set!")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-set! parts environment context continuation))
	       ((and (consent--symbol-named-p operator "let-values")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-let-values
                 parts environment context tailp nil continuation))
	       ((and (consent--symbol-named-p operator "let*-values")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-let-values
                 parts environment context tailp t continuation))
	       ((and (consent--symbol-named-p operator "letrec")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-letrec
                 parts environment context tailp nil continuation))
	       ((and (consent--symbol-named-p operator "letrec*")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-letrec
                 parts environment context tailp t continuation))
       ((and (consent--symbol-named-p operator "define")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-error "define is not valid in expression position"))
       ((and (consent--symbol-named-p operator "define-values")
             (consent--special-operator-active-p operator environment))
        (consent--eval-error
         "define-values is not valid in expression position"))
       ((and (consent--symbol-named-p operator "define-record-type")
             (consent--special-operator-active-p operator environment))
        (consent--eval-error
         "define-record-type is not valid in expression position"))
       ((and (consent--symbol-named-p operator "define-syntax")
             (consent--special-operator-active-p operator environment))
        (consent--eval-error
         "define-syntax is not valid in expression position"))
       ((and (consent--symbol-named-p operator "define-library")
             (consent--special-operator-active-p operator environment))
        (consent--eval-error
         "define-library is not valid in expression position"))
       ((and (consent--symbol-named-p operator "import")
             (consent--special-operator-active-p operator environment))
        (consent--eval-error
         "import is not valid in expression position"))
	       ((and (consent--symbol-named-p operator "begin")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-sequence
                 (cdr parts) environment context tailp nil continuation))
	       ((and (consent--symbol-named-p operator "with-budget")
	             (consent--special-operator-active-p operator environment))
	        (consent--eval-with-budget
                 parts environment context continuation))
	       (t
	        (consent--eval-expression
                 operator
                 environment
                 context
                 nil
                 (lambda (raw-procedure)
                   (let ((procedure
                          (consent--single-value
                           raw-procedure "procedure operator")))
                     (consent--eval-arguments
                      (cdr parts)
                      environment
                      context
                      nil
                      (lambda (arguments)
                        (consent--apply-procedure
                         procedure arguments context tailp continuation)))))))))))

(defun consent--eval-with-budget (parts environment context continuation)
  "Evaluate (with-budget SPEC BODY ...) under a tightened budget.
SPEC evaluates to a (budget ...) datum; for its dynamic extent the active
counter ceilings admit at most the SPEC amount more.  The inherited ceilings
are restored when the body completes.  A non-local exit out of the body leaves
the tightened ceilings in place, which is a conservative, fail-closed outcome
rather than a relaxation.  The body is an implicit `begin'; wrap it in
\(let () ...) for internal definitions."
  (when (< (length parts) 3)
    (consent--eval-error "with-budget requires a budget spec and a body"))
  (consent--eval-expression
   (cadr parts)
   environment
   context
   nil
   (lambda (spec-result)
     (let ((spec (consent--single-value spec-result "with-budget spec"))
           (saved (consent--budget-ceiling-snapshot context)))
       (consent--budget-tighten context spec)
       (consent--eval-sequence
        (cddr parts)
        environment
        context
        nil
        nil
        (lambda (body-result)
          (consent--budget-restore context saved)
          (consent--continue continuation body-result)))))))

(defun consent--eval-expression
    (expression environment context tailp &optional continuation)
  "Evaluate EXPRESSION in ENVIRONMENT under CONTEXT.
When TAILP is non-nil, tail calls may return an
`consent--bounce'."
  (let ((direct-call (null continuation))
        (next (or continuation #'consent--identity-continuation)))
    (consent--note-step context)
    (let ((state
           (cond
            ((consent--sequence-p expression)
             (consent--eval-sequence
              (consent--sequence-forms expression)
              environment
              context
              tailp
              (consent--sequence-allow-definitions expression)
              next))
            ((consent--syntax-scope-p expression)
             (consent--with-syntax-environment
              context
              (consent--syntax-scope-syntax-environment expression)
              (lambda ()
                (consent--eval-sequence
                 (consent--syntax-scope-forms expression)
                 environment
                 context
                 tailp
                 t
                 next))))
            ((consent--self-evaluating-p expression)
             (consent--continue
              next
              (consent--charge-literal expression context)))
            ((consent--identifier-p expression)
             (consent--continue
              next
              (consent--environment-ref-identifier environment expression)))
            ((consent-symbol-p expression)
             (consent--continue
              next
              (consent--environment-ref-identifier environment expression)))
            ((null expression)
             (consent--eval-error "empty list is not an expression"))
            ((consp expression)
             (let ((expanded (consent--expand-expression
                              expression environment context)))
               ;; Expansion is interleaved with evaluation so local syntax forms can
               ;; update CONTEXT before the resulting core expression is evaluated.
               (if (eq expanded expression)
                   (consent--eval-combination
                    expression environment context tailp next)
                 (consent--eval-expression
                  expanded environment context tailp next))))
            (t
             (consent--eval-error
              "unsupported expression datum: %S" expression)))))
      (if direct-call
          (consent--drain-state state context)
        state))))

(defun consent--eval-sequence
    (forms environment context tailp allow-definitions &optional continuation)
  "Evaluate FORMS sequentially in ENVIRONMENT.
TAILP controls the final form.  ALLOW-DEFINITIONS permits
top-level definition forms within the sequence."
  (let ((next (or continuation #'consent--identity-continuation)))
    (cl-labels
        ((after-form (value rest imports-open)
           (if rest
               (step rest imports-open)
             (consent--continue next value)))
         (step (cursor imports-open)
           (if (null cursor)
               (consent--continue next consent-unspecified)
             (let* ((form (car cursor))
                    (rest (cdr cursor))
                    (last-form-p (null rest)))
               (cond
                ((consent--import-form-p form)
                 (unless imports-open
                   (consent--eval-error
                    "import declarations must precede program body forms"))
                 (if allow-definitions
                     (after-form
                      (consent--eval-import form environment context)
                      rest
                      t)
                   (consent--eval-error
                    "import is only allowed at top level or in library bodies")))
                ((consent--define-library-form-p form)
                 (if allow-definitions
                     (after-form
                      (consent--eval-define-library
                       form environment context)
                      rest
                      imports-open)
                   (consent--eval-error
                    "define-library is only allowed at top level")))
                ((consent--syntax-definition-form-p form)
                 (if allow-definitions
                     (after-form
                      (consent--eval-define-syntax
                       form
                       environment
                       context
                       (consent--eval-context-syntax-environment
                        context))
                      rest
                      nil)
                   (consent--eval-error
                    "define-syntax is only allowed before body expressions")))
                ((consent--record-definition-form-p form)
                 (if allow-definitions
                     (after-form
                      (consent--eval-record-definition
                       form environment context)
                      rest
                      nil)
                   (consent--eval-error
                    "define-record-type is only allowed before body expressions")))
                ((consent--define-values-form-p form)
                 (if allow-definitions
                     (consent--eval-define-values
                      form
                      environment
                      context
                      (lambda (value)
                        (after-form value rest nil)))
                   (consent--eval-error
                    "define-values is only allowed before body expressions")))
                ((consent--definition-form-p form)
                 (if allow-definitions
                     (consent--eval-definition
                      form
                      environment
                      context
                      (lambda (value)
                        (after-form value rest nil)))
                   (consent--eval-error
                    "define is only allowed before body expressions")))
                ((and allow-definitions (consent--begin-form-p form))
                 (consent--eval-sequence
                  (cdr (consent--proper-list-elements form "begin form"))
                  environment
                  context
                  (and last-form-p tailp)
                  t
                  (lambda (value)
                    (after-form value rest nil))))
                (last-form-p
                 (if tailp
                     (consent--make-bounce
                      form
                      environment
                      (consent--eval-context-syntax-environment context)
                      next)
                   (consent--eval-expression
                    form environment context nil next)))
                (t
                 (consent--eval-expression
                  form
                  environment
                  context
                  nil
                  (lambda (_value)
                    (step rest nil)))))))))
      (step forms t))))

(defun consent--capture-dynamic-state (context)
  "Return a checkpoint of CONTEXT's dynamic-extent state.
The checkpoint covers the exception-handler stack, `current-error', and
the dynamic-wind stack -- the state CPS primitives mutate and unwind
through their success continuations."
  (list (consent--eval-context-exception-handlers context)
        (consent--eval-context-current-error context)
        (consent--eval-context-dynamic-winds context)))

(defun consent--restore-dynamic-state (context checkpoint)
  "Restore CONTEXT's dynamic-extent state from CHECKPOINT."
  (setf (consent--eval-context-exception-handlers context)
        (nth 0 checkpoint))
  (setf (consent--eval-context-current-error context)
        (nth 1 checkpoint))
  (setf (consent--eval-context-dynamic-winds context)
        (nth 2 checkpoint)))

(defun consent--drain-state (state context)
  "Run trampoline bounces in STATE under CONTEXT.
The CPS primitives restore the exception-handler stack, `current-error',
and the dynamic-wind stack from inside their success continuation, which
never runs when an invoked handler or wind thunk escapes via an Emacs
Lisp `signal' (an unhandled or non-continuable raise, a budget overflow).
Checkpoint that state on entry and restore it should the trampoline
unwind before producing a final value, so the CPS path is unwind-safe
like the direct `unwind-protect' path.  Normal return and
reified-continuation escapes leave the checkpoint untouched, so an
aborting signal cannot leak handler or wind frames into a reused context.
Caught escapes still run `dynamic-wind' after thunks via
`consent--switch-dynamic-winds'; an aborting signal does not."
  (let ((checkpoint (consent--capture-dynamic-state context))
        (completed nil))
    (unwind-protect
        (prog1
            (progn
              (while (consent--bounce-p state)
                (let ((syntax-environment
                       (or (consent--bounce-syntax-environment state)
                           (consent--eval-context-syntax-environment
                            context)))
                      (continuation
                       (or (consent--bounce-continuation state)
                           #'consent--identity-continuation)))
                  ;; A bounce carries the value environment, syntax
                  ;; environment, and evaluator continuation needed for the
                  ;; next tail step.
                  (setq state
                        (consent--with-syntax-environment
                         context
                         syntax-environment
                         (lambda ()
                           (consent--eval-expression
                            (consent--bounce-expression state)
                            (consent--bounce-environment state)
                            context
                            t
                            continuation))))))
              state)
          (setq completed t))
      (unless completed
        (consent--restore-dynamic-state context checkpoint)))))

(defun consent--trampoline (expression environment context)
  "Evaluate EXPRESSION in ENVIRONMENT using CONTEXT's trampoline.
The result needs no final budget walk: every node it reaches was charged at the
allocation that produced it."
  (let ((state
         (consent--make-bounce
          expression
          environment
          (consent--eval-context-syntax-environment context)
          #'consent--identity-continuation)))
    (consent--drain-state state context)))

(defun consent--scheme-boolean (value)
  "Return the canonical Scheme boolean for host truth VALUE."
  (if value consent-true consent-false))

(defun consent--number-from-host (number)
  "Return an Consent Scheme number datum for host NUMBER."
  (cond
   ((integerp number)
    (consent--make-canonical-integer number))
   ((floatp number)
    (consent--make-canonical-decimal number))
   (t
    (consent--eval-error "unsupported host number result: %S" number))))

(defun consent--expect-number (datum description)
  "Return DATUM as a number or signal an error naming DESCRIPTION."
  (unless (consent-number-p datum)
    (consent--eval-error
     "%s expected number, got %s"
     description
     (consent-value->external datum)))
  datum)

(defun consent--number-exact-p (datum)
  "Return non-nil if DATUM is an exact number."
  (and (consent-number-p datum)
       (eq (consent-number-exactness datum) 'exact)))

(defun consent--number-inexact-p (datum)
  "Return non-nil if DATUM is an inexact number."
  (and (consent-number-p datum)
       (eq (consent-number-exactness datum) 'inexact)))

(defun consent--number-nan-p (datum)
  "Return non-nil if DATUM is a NaN value."
  (and (consent-number-p datum)
       (or (and (eq (consent-number-kind datum) 'infnan)
                (eq (consent-number-value datum) '+nan.0))
           (and (eq (consent-number-kind datum) 'complex)
                (or (consent--number-nan-p
                     (car (consent-number-value datum)))
                    (consent--number-nan-p
                     (cdr (consent-number-value datum))))))))

(defun consent--number-infinite-p (datum)
  "Return non-nil if DATUM is an infinity value."
  (and (consent-number-p datum)
       (or (and (eq (consent-number-kind datum) 'infnan)
                (memq (consent-number-value datum) '(+inf.0 -inf.0)))
           (and (eq (consent-number-kind datum) 'complex)
                (or (consent--number-infinite-p
                     (car (consent-number-value datum)))
                    (consent--number-infinite-p
                     (cdr (consent-number-value datum))))))))

(defun consent--number-finite-p (datum)
  "Return non-nil if DATUM is a finite number."
  (and (consent-number-p datum)
       (not (consent--number-nan-p datum))
       (not (consent--number-infinite-p datum))))

(defun consent--number-exact-zero-p (datum)
  "Return non-nil if DATUM is exactly zero."
  (and (consent-number-p datum)
       (consent--number-exact-p datum)
       (consent--number-zero-p datum)))

(defun consent--number-real-p (datum)
  "Return non-nil if DATUM is real-valued."
  (and (consent-number-p datum)
       (or (not (eq (consent-number-kind datum) 'complex))
           (consent--number-exact-zero-p
            (cdr (consent-number-value datum))))))

(defun consent--number-rational-p (datum)
  "Return non-nil if DATUM is rational-valued."
  (and (consent--number-real-p datum)
       (let ((real (if (eq (consent-number-kind datum) 'complex)
                       (car (consent-number-value datum))
                     datum)))
         (not (eq (consent-number-kind real) 'infnan)))))

(defun consent--number-integer-p (datum)
  "Return non-nil if DATUM is integer-valued."
  (and (consent-number-p datum)
       (cond
        ((eq (consent-number-kind datum) 'complex)
         (and (consent--number-exact-zero-p
               (cdr (consent-number-value datum)))
              (consent--number-integer-p
               (car (consent-number-value datum)))))
        ((eq (consent-number-kind datum) 'integer) t)
        ((eq (consent-number-kind datum) 'rational)
         (= (cdr (consent-number-value datum)) 1))
        ((eq (consent-number-kind datum) 'decimal)
         (let ((value (consent-number-value datum)))
           (and (floatp value) (= value (ftruncate value)))))
        (t nil))))

(defun consent--number->rational-pair (datum description)
  "Return exact rational pair for DATUM or signal an error naming DESCRIPTION."
  (setq datum (consent--expect-number datum description))
  (pcase (consent-number-kind datum)
    ('integer (cons (consent-number-value datum) 1))
    ('rational (consent-number-value datum))
    ('complex
     (if (consent--number-exact-zero-p
          (cdr (consent-number-value datum)))
         (consent--number->rational-pair
          (car (consent-number-value datum)) description)
       (consent--eval-error
        "%s expected real number, got %s"
        description
        (consent-value->external datum))))
    (_
     (consent--eval-error
      "%s expected exact rational number, got %s"
      description
      (consent-value->external datum)))))

(defun consent--number->float (datum description)
  "Return DATUM as a host float or signal an error naming DESCRIPTION."
  (setq datum (consent--expect-number datum description))
  (pcase (consent-number-kind datum)
    ('integer (float (consent-number-value datum)))
    ('rational
     (let ((value (consent-number-value datum)))
       (/ (float (car value)) (cdr value))))
    ('decimal (consent-number-value datum))
    ('infnan
     (pcase (consent-number-value datum)
       ('+inf.0 (/ 1.0 0.0))
       ('-inf.0 (/ -1.0 0.0))
       ('+nan.0 (/ 0.0 0.0))))
    ('complex
     (if (consent--number-exact-zero-p
          (cdr (consent-number-value datum)))
         (consent--number->float
          (car (consent-number-value datum)) description)
       (consent--eval-error
        "%s expected real number, got %s"
        description
        (consent-value->external datum))))))

(defun consent--number-from-rational-pair
    (pair &optional exactness)
  "Return number datum for rational PAIR and EXACTNESS."
  (let ((number (consent--make-canonical-rational
                 (car pair) (cdr pair) (or exactness 'exact) 10)))
    (if (eq exactness 'inexact)
        (consent--make-canonical-decimal
         (/ (float (car pair)) (cdr pair)))
      number)))

(defun consent--number-inexact (datum)
  "Return an inexact representation of DATUM."
  (setq datum (consent--expect-number datum "inexact"))
  (pcase (consent-number-kind datum)
    ((or 'decimal 'infnan) datum)
    ('integer
     (consent--make-canonical-decimal
      (float (consent-number-value datum))))
    ('rational
     (let ((value (consent-number-value datum)))
       (consent--make-canonical-decimal
        (/ (float (car value)) (cdr value)))))
    ('complex
     (let ((value (consent-number-value datum)))
       (consent--make-canonical-complex
        (consent--number-inexact (car value))
        (consent--number-inexact (cdr value)))))))

(defun consent--decimal->exact-rational-pair (number)
  "Return an exact rational approximation for decimal NUMBER."
  (let* ((text (number-to-string number))
         (parsed (consent-read (concat "#e" text))))
    (consent--number->rational-pair parsed "exact")))

(defun consent--number-exact (datum)
  "Return an exact representation of DATUM."
  (setq datum (consent--expect-number datum "exact"))
  (pcase (consent-number-kind datum)
    ((or 'integer 'rational) datum)
    ('decimal
     (consent--number-from-rational-pair
      (consent--decimal->exact-rational-pair
       (consent-number-value datum))))
    ('complex
     (let ((value (consent-number-value datum)))
       (consent--make-canonical-complex
        (consent--number-exact (car value))
        (consent--number-exact (cdr value)))))
    ('infnan
     (consent--eval-error
      "exact cannot represent %s"
      (consent-value->external datum)))))

(defun consent--exact-integer->host (datum description)
  "Return DATUM's exact integer value or signal an error naming DESCRIPTION."
  (unless (and (consent-number-p datum)
               (eq (consent-number-kind datum) 'integer)
               (eq (consent-number-exactness datum) 'exact))
    (consent--eval-error
     "%s must be an exact integer, got %s"
     description
     (consent-value->external datum)))
  (consent-number-value datum))

(defun consent--expect-nonnegative-index
    (datum limit description &optional allow-end)
  "Return DATUM as a host index below LIMIT.
When ALLOW-END is non-nil, LIMIT itself is accepted."
  (let ((index (consent--exact-integer->host datum description)))
    (unless (and (<= 0 index)
                 (if allow-end (<= index limit) (< index limit)))
      (consent--eval-error
       "%s index out of range: %d" description index))
    index))

(defun consent--expect-byte (datum description)
  "Return DATUM as a byte or signal an error naming DESCRIPTION."
  (let ((byte (consent--exact-integer->host datum description)))
    (unless (<= 0 byte 255)
      (consent--eval-error "%s must be in byte range: %d" description byte))
    byte))

(defun consent--expect-string (datum description)
  "Return DATUM as a string or signal an error naming DESCRIPTION."
  (unless (stringp datum)
    (consent--eval-error
     "%s must be a string, got %s"
     description
     (consent-value->external datum)))
  datum)

(defun consent--expect-character (datum description)
  "Return DATUM's character code or signal an error naming DESCRIPTION."
  (unless (consent-character-p datum)
    (consent--eval-error
     "%s must be a character, got %s"
     description
     (consent-value->external datum)))
  (consent-character-code datum))

(defun consent--valid-scalar-value-p (code)
  "Return non-nil if CODE is a Unicode scalar value."
  (and (integerp code)
       (<= 0 code #x10ffff)
       (not (<= #xd800 code #xdfff))))

(defun consent--expect-vector (datum description)
  "Return DATUM as a vector or signal an error naming DESCRIPTION."
  (unless (vectorp datum)
    (consent--eval-error
     "%s must be a vector, got %s"
     description
     (consent-value->external datum)))
  datum)

(defun consent--expect-bytevector (datum description)
  "Return DATUM as a bytevector or signal an error naming DESCRIPTION."
  (unless (consent-bytevector-p datum)
    (consent--eval-error
     "%s must be a bytevector, got %s"
     description
     (consent-value->external datum)))
  datum)

(defun consent--expect-procedure (datum description)
  "Return DATUM as a procedure or signal an error naming DESCRIPTION."
  (unless (or (consent-procedure-p datum)
              (consent-primitive-procedure-p datum)
              (consent-parameter-p datum)
              (consent--continuation-p datum))
    (consent--eval-error
     "%s must be a procedure, got %s"
     description
     (consent-value->external datum)))
  datum)

(defun consent--optional-range (arguments offset length description)
  "Return (START . END) parsed from optional range ARGUMENTS.
OFFSET is the index in ARGUMENTS where START would appear.  LENGTH is
the maximum endpoint for DESCRIPTION."
  (let ((optional-count (- (length arguments) offset)))
    (unless (<= 0 optional-count 2)
      (consent--eval-error
       "%s expected at most start and end arguments" description))
    (let ((start (if (>= optional-count 1)
                     (consent--expect-nonnegative-index
                      (nth offset arguments) length description t)
                   0))
          (end (if (>= optional-count 2)
                   (consent--expect-nonnegative-index
                    (nth (1+ offset) arguments) length description t)
                 length)))
      (when (> start end)
        (consent--eval-error
         "%s start index exceeds end index" description))
      (cons start end))))

(defun consent--numeric-arguments (arguments description)
  "Return ARGUMENTS after checking every item is a number for DESCRIPTION."
  (mapcar (lambda (argument)
            (consent--expect-number argument description))
          arguments))

(defun consent--number-complex-p (number)
  "Return non-nil if NUMBER has an explicit complex representation."
  (eq (consent-number-kind number) 'complex))

(defun consent--complex-parts (number)
  "Return NUMBER as a cons of real and imaginary number parts."
  (if (consent--number-complex-p number)
      (consent-number-value number)
    (cons number (consent--make-canonical-integer 0))))

(defun consent--any-inexact-number-p (numbers)
  "Return non-nil if any item in NUMBERS is inexact."
  (cl-some #'consent--number-inexact-p numbers))

(defun consent--any-complex-number-p (numbers)
  "Return non-nil if any item in NUMBERS is explicitly complex."
  (cl-some #'consent--number-complex-p numbers))

(defun consent--binary-rational
    (left right operation description)
  "Apply exact rational OPERATION to LEFT and RIGHT for DESCRIPTION."
  (let* ((left-pair (consent--number->rational-pair left description))
         (right-pair (consent--number->rational-pair right description))
         (left-numerator (car left-pair))
         (left-denominator (cdr left-pair))
         (right-numerator (car right-pair))
         (right-denominator (cdr right-pair)))
    (pcase operation
      ('+
       (consent--number-from-rational-pair
        (cons (+ (* left-numerator right-denominator)
                 (* right-numerator left-denominator))
              (* left-denominator right-denominator))))
      ('-
       (consent--number-from-rational-pair
        (cons (- (* left-numerator right-denominator)
                 (* right-numerator left-denominator))
              (* left-denominator right-denominator))))
      ('*
       (consent--number-from-rational-pair
        (cons (* left-numerator right-numerator)
              (* left-denominator right-denominator))))
      ('/
       (when (zerop right-numerator)
         (consent--eval-error "%s division by zero" description))
       (consent--number-from-rational-pair
        (cons (* left-numerator right-denominator)
              (* left-denominator right-numerator)))))))

(defun consent--special-inexact-binary
    (left right operation description)
  "Handle inexact special values for OPERATION, or return nil."
  (cond
   ((or (consent--number-nan-p left)
        (consent--number-nan-p right))
    (consent--make-canonical-infnan '+nan.0))
   ((or (eq (consent-number-kind left) 'infnan)
        (eq (consent-number-kind right) 'infnan))
    (let ((left-kind (and (eq (consent-number-kind left) 'infnan)
                          (consent-number-value left)))
          (right-kind (and (eq (consent-number-kind right) 'infnan)
                           (consent-number-value right))))
      (pcase operation
        ('+
         (cond
          ((and left-kind right-kind (not (eq left-kind right-kind)))
           (consent--make-canonical-infnan '+nan.0))
          (left-kind left)
          (right-kind right)))
        ('-
         (cond
          ((and left-kind right-kind (eq left-kind right-kind))
           (consent--make-canonical-infnan '+nan.0))
          (left-kind left)
          ((eq right-kind '+inf.0)
           (consent--make-canonical-infnan '-inf.0))
          ((eq right-kind '-inf.0)
           (consent--make-canonical-infnan '+inf.0))))
        (_
         (consent--number-from-host
          (funcall
           (pcase operation
             ('* #'*)
             ('/ #'/))
           (consent--number->float left description)
           (consent--number->float right description)))))))))

(defun consent--binary-real-number
    (left right operation description)
  "Apply real numeric OPERATION to LEFT and RIGHT for DESCRIPTION."
  (or (consent--special-inexact-binary
       left right operation description)
      (if (or (consent--number-inexact-p left)
              (consent--number-inexact-p right))
          (consent--make-canonical-decimal
           (funcall
            (pcase operation
              ('+ #'+)
              ('- #'-)
              ('* #'*)
              ('/ #'/))
            (consent--number->float left description)
            (consent--number->float right description)))
        (consent--binary-rational left right operation description))))

(defun consent--binary-number (left right operation description)
  "Apply numeric OPERATION to LEFT and RIGHT for DESCRIPTION."
  (if (or (consent--number-complex-p left)
          (consent--number-complex-p right))
      (let* ((left-parts (consent--complex-parts left))
             (right-parts (consent--complex-parts right))
             (a (car left-parts))
             (b (cdr left-parts))
             (c (car right-parts))
             (d (cdr right-parts)))
        (pcase operation
          ('+
           (consent--make-canonical-complex
            (consent--binary-number a c '+ description)
            (consent--binary-number b d '+ description)))
          ('-
           (consent--make-canonical-complex
            (consent--binary-number a c '- description)
            (consent--binary-number b d '- description)))
          ('*
           (consent--make-canonical-complex
            (consent--binary-number
             (consent--binary-number a c '* description)
             (consent--binary-number b d '* description)
             '-
             description)
            (consent--binary-number
             (consent--binary-number a d '* description)
             (consent--binary-number b c '* description)
             '+
             description)))
          ('/
           (let ((denominator
                  (consent--binary-number
                   (consent--binary-number c c '* description)
                   (consent--binary-number d d '* description)
                   '+
                   description)))
             (when (consent--number-zero-p denominator)
               (consent--eval-error "%s division by zero" description))
             (consent--make-canonical-complex
              (consent--binary-number
               (consent--binary-number
                (consent--binary-number a c '* description)
                (consent--binary-number b d '* description)
                '+
                description)
               denominator
               '/
               description)
              (consent--binary-number
               (consent--binary-number
                (consent--binary-number b c '* description)
                (consent--binary-number a d '* description)
                '-
                description)
               denominator
               '/
               description))))))
    (consent--binary-real-number left right operation description)))

(defun consent--fold-numbers
    (arguments identity operation description &optional unary-inverse)
  "Fold ARGUMENTS with numeric OPERATION and IDENTITY for DESCRIPTION."
  (let ((numbers (consent--numeric-arguments arguments description)))
    (cond
     ((null numbers) identity)
     ((and unary-inverse (= (length numbers) 1))
      (funcall unary-inverse (car numbers)))
     (t
      (let ((result (car numbers)))
        (dolist (number (cdr numbers))
          (setq result
                (consent--binary-number
                 result number operation description)))
        result)))))

(defun consent--primitive+ (arguments _context)
  "Primitive + over ARGUMENTS."
  (consent--fold-numbers
   arguments (consent--make-canonical-integer 0) '+ "+"))

(defun consent--primitive* (arguments _context)
  "Primitive * over ARGUMENTS."
  (consent--fold-numbers
   arguments (consent--make-canonical-integer 1) '* "*"))

(defun consent--primitive- (arguments _context)
  "Primitive - over ARGUMENTS."
  (consent--fold-numbers
   arguments
   nil
   '-
   "-"
   (lambda (number)
     (consent--binary-number
      (consent--make-canonical-integer 0) number '- "-"))))

(defun consent--primitive/ (arguments _context)
  "Primitive / over ARGUMENTS."
  (consent--fold-numbers
   arguments
   nil
   '/
   "/"
   (lambda (number)
     (consent--binary-number
      (consent--make-canonical-integer 1) number '/ "/"))))

(defun consent--number-real-part-for-ordering (number description)
  "Return real part of NUMBER suitable for ordering predicates."
  (setq number (consent--expect-number number description))
  (if (consent--number-complex-p number)
      (if (consent--number-exact-zero-p
           (cdr (consent-number-value number)))
          (car (consent-number-value number))
        (consent--eval-error
         "%s expected real number, got %s"
         description
         (consent-value->external number)))
    number))

(defun consent--number=2 (left right)
  "Return non-nil if LEFT and RIGHT are numerically equal."
  (cond
   ((or (consent--number-nan-p left)
        (consent--number-nan-p right))
    nil)
   ((or (consent--number-complex-p left)
        (consent--number-complex-p right))
    (let ((left-parts (consent--complex-parts left))
          (right-parts (consent--complex-parts right)))
      (and (consent--number=2 (car left-parts) (car right-parts))
           (consent--number=2 (cdr left-parts) (cdr right-parts)))))
   ((or (eq (consent-number-kind left) 'infnan)
        (eq (consent-number-kind right) 'infnan))
    (and (eq (consent-number-kind left) 'infnan)
         (eq (consent-number-kind right) 'infnan)
         (eq (consent-number-value left)
             (consent-number-value right))))
   ((or (consent--number-inexact-p left)
        (consent--number-inexact-p right))
    (= (consent--number->float left "=")
       (consent--number->float right "=")))
   (t
    (let ((left-pair (consent--number->rational-pair left "="))
          (right-pair (consent--number->rational-pair right "=")))
      (= (* (car left-pair) (cdr right-pair))
         (* (car right-pair) (cdr left-pair)))))))

(defun consent--number-order2 (left right predicate description)
  "Return PREDICATE result for real LEFT and RIGHT."
  (setq left (consent--number-real-part-for-ordering left description))
  (setq right (consent--number-real-part-for-ordering right description))
  (cond
   ((or (consent--number-nan-p left)
        (consent--number-nan-p right))
    nil)
   ((or (consent--number-inexact-p left)
        (consent--number-inexact-p right)
        (eq (consent-number-kind left) 'infnan)
        (eq (consent-number-kind right) 'infnan))
    (let ((left-key (consent--number->float left description))
          (right-key (consent--number->float right description)))
      (funcall predicate left-key right-key)))
   (t
    (let ((left-pair (consent--number->rational-pair left description))
          (right-pair (consent--number->rational-pair right description)))
      (funcall predicate
               (* (car left-pair) (cdr right-pair))
               (* (car right-pair) (cdr left-pair)))))))

(defun consent--primitive-compare (arguments predicate description)
  "Return Scheme boolean for pairwise PREDICATE over ARGUMENTS."
  (let ((numbers (consent--numeric-arguments arguments description))
        (ok t))
    (while (and ok (cdr numbers))
      (setq ok (if (eq predicate #'=)
                   (consent--number=2 (car numbers) (cadr numbers))
                 (consent--number-order2
                  (car numbers) (cadr numbers) predicate description)))
      (setq numbers (cdr numbers)))
    (consent--scheme-boolean ok)))

(defun consent--primitive= (arguments _context)
  "Primitive numeric = over ARGUMENTS."
  (consent--primitive-compare arguments #'= "="))

(defun consent--primitive< (arguments _context)
  "Primitive numeric < over ARGUMENTS."
  (consent--primitive-compare arguments #'< "<"))

(defun consent--primitive> (arguments _context)
  "Primitive numeric > over ARGUMENTS."
  (consent--primitive-compare arguments #'> ">"))

(defun consent--primitive<= (arguments _context)
  "Primitive numeric <= over ARGUMENTS."
  (consent--primitive-compare arguments #'<= "<="))

(defun consent--primitive>= (arguments _context)
  "Primitive numeric >= over ARGUMENTS."
  (consent--primitive-compare arguments #'>= ">="))

(defun consent--primitive-abs (arguments _context)
  "Primitive abs over ARGUMENTS."
  (let ((number (consent--expect-number (car arguments) "abs")))
    (if (consent--number-complex-p number)
        (consent--eval-error
         "abs expected real number, got %s"
         (consent-value->external number))
      (consent--number-abs number))))

(defun consent--primitive-min (arguments _context)
  "Primitive min over ARGUMENTS."
  (let* ((numbers (consent--numeric-arguments arguments "min"))
         (inexact (consent--any-inexact-number-p numbers))
         (best (car numbers)))
    (dolist (number (cdr numbers))
      (when (eq (consent--primitive-compare
                 (list number best) #'< "min")
                consent-true)
        (setq best number)))
    (if inexact (consent--number-inexact best) best)))

(defun consent--primitive-max (arguments _context)
  "Primitive max over ARGUMENTS."
  (let* ((numbers (consent--numeric-arguments arguments "max"))
         (inexact (consent--any-inexact-number-p numbers))
         (best (car numbers)))
    (dolist (number (cdr numbers))
      (when (eq (consent--primitive-compare
                 (list number best) #'> "max")
                consent-true)
        (setq best number)))
    (if inexact (consent--number-inexact best) best)))

(defun consent--primitive-square (arguments _context)
  "Primitive square over ARGUMENTS."
  (let ((number (consent--expect-number (car arguments) "square")))
    (consent--binary-number number number '* "square")))

(defun consent--primitive-zero? (arguments _context)
  "Primitive zero? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-zero-p
    (consent--expect-number (car arguments) "zero?"))))

(defun consent--primitive-positive? (arguments _context)
  "Primitive positive? over ARGUMENTS."
  (consent--primitive-compare
   (list (car arguments) (consent--make-canonical-integer 0))
   #'>
   "positive?"))

(defun consent--primitive-negative? (arguments _context)
  "Primitive negative? over ARGUMENTS."
  (consent--primitive-compare
   (list (car arguments) (consent--make-canonical-integer 0))
   #'<
   "negative?"))

(defun consent--primitive-odd? (arguments _context)
  "Primitive odd? over ARGUMENTS."
  (consent--scheme-boolean
   (cl-oddp (consent--exact-integer->host (car arguments) "odd?"))))

(defun consent--primitive-even? (arguments _context)
  "Primitive even? over ARGUMENTS."
  (consent--scheme-boolean
   (cl-evenp (consent--exact-integer->host (car arguments) "even?"))))

(defun consent--primitive-integer-quotient
    (arguments quotient-function description)
  "Return integer quotient over ARGUMENTS using QUOTIENT-FUNCTION."
  (let ((left (consent--exact-integer->host
               (car arguments) description))
        (right (consent--exact-integer->host
                (cadr arguments) description)))
    (when (zerop right)
      (consent--eval-error "%s division by zero" description))
    (consent--make-canonical-integer
     (funcall quotient-function left right))))

(defun consent--primitive-quotient (arguments _context)
  "Primitive quotient over ARGUMENTS."
  (consent--primitive-integer-quotient
   arguments #'truncate "quotient"))

(defun consent--primitive-floor-quotient (arguments _context)
  "Primitive floor-quotient over ARGUMENTS."
  (consent--primitive-integer-quotient
   arguments #'floor "floor-quotient"))

(defun consent--primitive-truncate-quotient (arguments _context)
  "Primitive truncate-quotient over ARGUMENTS."
  (consent--primitive-integer-quotient
   arguments #'consent--truncate-quotient-value "truncate-quotient"))

(defun consent--truncate-quotient-value (left right)
  "Return integer quotient of LEFT over RIGHT truncated toward zero."
  (let ((quotient (/ (abs left) (abs right))))
    (if (= (cl-signum left) (cl-signum right))
        quotient
      (- quotient))))

(defun consent--modulo-value (left right)
  "Return Scheme modulo for host integers LEFT and RIGHT."
  (let ((remainder (% left right)))
    (if (or (zerop remainder)
            (= (cl-signum remainder) (cl-signum right)))
        remainder
      (+ remainder right))))

(defun consent--primitive-remainder (arguments _context)
  "Primitive remainder over ARGUMENTS."
  (let ((left (consent--exact-integer->host
               (car arguments) "remainder"))
        (right (consent--exact-integer->host
                (cadr arguments) "remainder")))
    (when (zerop right)
      (consent--eval-error "remainder division by zero"))
    (consent--make-canonical-integer
     (consent--truncate-remainder-value left right))))

(defun consent--truncate-remainder-value (left right)
  "Return integer remainder of LEFT over RIGHT truncated toward zero."
  (- left (* right (consent--truncate-quotient-value left right))))

(defun consent--primitive-modulo (arguments _context)
  "Primitive modulo over ARGUMENTS."
  (let ((left (consent--exact-integer->host (car arguments) "modulo"))
        (right (consent--exact-integer->host (cadr arguments) "modulo")))
    (when (zerop right)
      (consent--eval-error "modulo division by zero"))
    (consent--make-canonical-integer
     (consent--modulo-value left right))))

(defun consent--primitive-floor-remainder (arguments context)
  "Primitive floor-remainder over ARGUMENTS."
  (consent--primitive-modulo arguments context))

(defun consent--primitive-truncate-remainder (arguments context)
  "Primitive truncate-remainder over ARGUMENTS."
  (consent--primitive-remainder arguments context))

(defun consent--floor-rational-pair (pair)
  "Return floor of exact rational PAIR."
  (floor (car pair) (cdr pair)))

(defun consent--ceiling-rational-pair (pair)
  "Return ceiling of exact rational PAIR."
  (ceiling (car pair) (cdr pair)))

(defun consent--truncate-rational-pair (pair)
  "Return truncation of exact rational PAIR toward zero."
  (let* ((numerator (car pair))
         (denominator (cdr pair))
         (quotient (/ (abs numerator) denominator)))
    (if (< numerator 0) (- quotient) quotient)))

(defun consent--round-rational-pair (pair)
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

(defun consent--primitive-rounding (arguments function description)
  "Apply unary numeric rounding FUNCTION to ARGUMENTS for DESCRIPTION."
  (let ((number (consent--number-real-part-for-ordering
                 (car arguments) description)))
    (pcase (consent-number-kind number)
      ((or 'integer 'rational)
       (consent--make-canonical-integer
        (funcall function
                 (consent--number->rational-pair number description))))
      ('decimal
       (consent--make-canonical-decimal
        (float (funcall
                function
                (consent--decimal->exact-rational-pair
                 (consent-number-value number))))))
      ('infnan number))))

(defun consent--primitive-floor (arguments _context)
  "Primitive floor over ARGUMENTS."
  (consent--primitive-rounding
   arguments #'consent--floor-rational-pair "floor"))

(defun consent--primitive-ceiling (arguments _context)
  "Primitive ceiling over ARGUMENTS."
  (consent--primitive-rounding
   arguments #'consent--ceiling-rational-pair "ceiling"))

(defun consent--primitive-truncate (arguments _context)
  "Primitive truncate over ARGUMENTS."
  (consent--primitive-rounding
   arguments #'consent--truncate-rational-pair "truncate"))

(defun consent--primitive-round (arguments _context)
  "Primitive round over ARGUMENTS."
  (consent--primitive-rounding
   arguments #'consent--round-rational-pair "round"))

(defun consent--integer-argument (datum description)
  "Return integer value of DATUM or signal an error naming DESCRIPTION."
  (setq datum (consent--expect-number datum description))
  (cond
   ((and (consent--number-exact-p datum)
         (consent--number-integer-p datum))
    (car (consent--number->rational-pair datum description)))
   ((and (consent--number-inexact-p datum)
         (consent--number-integer-p datum))
    (truncate (consent--number->float datum description)))
   (t
    (consent--eval-error
     "%s expected integer, got %s"
     description
     (consent-value->external datum)))))

(defun consent--primitive-gcd (arguments _context)
  "Primitive gcd over ARGUMENTS."
  (let ((numbers (consent--numeric-arguments arguments "gcd"))
        (result 0)
        inexact)
    (dolist (number numbers)
      (setq inexact (or inexact (consent--number-inexact-p number)))
      (setq result
            (consent--integer-gcd
             result
             (consent--integer-argument number "gcd"))))
    (let ((value (consent--make-canonical-integer result)))
      (if inexact (consent--number-inexact value) value))))

(defun consent--primitive-lcm (arguments _context)
  "Primitive lcm over ARGUMENTS."
  (let ((numbers (consent--numeric-arguments arguments "lcm"))
        (result 1)
        inexact)
    (dolist (number numbers)
      (let ((value (abs (consent--integer-argument number "lcm"))))
        (setq inexact (or inexact (consent--number-inexact-p number)))
        (setq result
              (if (or (zerop result) (zerop value))
                  0
                (/ (* result value)
                   (consent--integer-gcd result value))))))
    (let ((value (consent--make-canonical-integer result)))
      (if inexact (consent--number-inexact value) value))))

(defun consent--primitive-numerator (arguments _context)
  "Primitive numerator over ARGUMENTS."
  (let* ((number (consent--expect-number (car arguments) "numerator"))
         (pair (if (consent--number-inexact-p number)
                   (consent--decimal->exact-rational-pair
                    (consent--number->float number "numerator"))
                 (consent--number->rational-pair number "numerator")))
         (value (consent--make-canonical-integer (car pair))))
    (if (consent--number-inexact-p number)
        (consent--number-inexact value)
      value)))

(defun consent--primitive-denominator (arguments _context)
  "Primitive denominator over ARGUMENTS."
  (let* ((number (consent--expect-number (car arguments) "denominator"))
         (pair (if (consent--number-inexact-p number)
                   (consent--decimal->exact-rational-pair
                    (consent--number->float number "denominator"))
                 (consent--number->rational-pair number "denominator")))
         (value (consent--make-canonical-integer (cdr pair))))
    (if (consent--number-inexact-p number)
        (consent--number-inexact value)
      value)))

(defun consent--primitive-exact (arguments _context)
  "Primitive exact over ARGUMENTS."
  (consent--number-exact (car arguments)))

(defun consent--primitive-inexact (arguments _context)
  "Primitive inexact over ARGUMENTS."
  (consent--number-inexact (car arguments)))

(defun consent--primitive-expt (arguments _context)
  "Primitive expt over ARGUMENTS."
  (let ((base (consent--expect-number (car arguments) "expt"))
        (power (consent--expect-number (cadr arguments) "expt")))
    (if (and (consent--number-exact-p base)
             (consent--number-exact-p power)
             (consent--number-integer-p power)
             (not (consent--number-complex-p base)))
        (let* ((base-pair (consent--number->rational-pair base "expt"))
               (exponent (car (consent--number->rational-pair
                               power "expt")))
               (numerator (consent--integer-power
                           (car base-pair) (abs exponent)))
               (denominator (consent--integer-power
                             (cdr base-pair) (abs exponent))))
          (if (>= exponent 0)
              (consent--number-from-rational-pair
               (cons numerator denominator))
            (consent--number-from-rational-pair
             (cons denominator numerator))))
      (consent--make-canonical-decimal
       (expt (consent--number->float base "expt")
             (consent--number->float power "expt"))))))

(defun consent--integer-sqrt (value)
  "Return floor square root of non-negative integer VALUE."
  (let ((low 0)
        (high (1+ value)))
    (while (> (- high low) 1)
      (let ((mid (/ (+ low high) 2)))
        (if (> (* mid mid) value)
            (setq high mid)
          (setq low mid))))
    low))

(defun consent--primitive-exact-integer-sqrt (arguments _context)
  "Primitive exact-integer-sqrt over ARGUMENTS."
  (let ((value (consent--exact-integer->host
                (car arguments) "exact-integer-sqrt")))
    (when (< value 0)
      (consent--eval-error
       "exact-integer-sqrt expected non-negative integer"))
    (let ((root (consent--integer-sqrt value)))
      (consent--make-multiple-values
       (list (consent--make-canonical-integer root)
             (consent--make-canonical-integer
              (- value (* root root))))))))

(defun consent--primitive-floor/ (arguments _context)
  "Primitive floor/ over ARGUMENTS."
  (let ((left (consent--exact-integer->host (car arguments) "floor/"))
        (right (consent--exact-integer->host (cadr arguments) "floor/")))
    (when (zerop right)
      (consent--eval-error "floor/ division by zero"))
    (let* ((quotient (floor left right))
           (remainder (- left (* right quotient))))
      (consent--make-multiple-values
       (list (consent--make-canonical-integer quotient)
             (consent--make-canonical-integer remainder))))))

(defun consent--primitive-truncate/ (arguments _context)
  "Primitive truncate/ over ARGUMENTS."
  (let ((left (consent--exact-integer->host (car arguments) "truncate/"))
        (right (consent--exact-integer->host
                (cadr arguments) "truncate/")))
    (when (zerop right)
      (consent--eval-error "truncate/ division by zero"))
    (let* ((quotient (consent--truncate-quotient-value left right))
           (remainder (- left (* right quotient))))
      (consent--make-multiple-values
       (list (consent--make-canonical-integer quotient)
             (consent--make-canonical-integer remainder))))))

(defun consent--primitive-rationalize (arguments _context)
  "Primitive rationalize over ARGUMENTS."
  (let* ((x (consent--expect-number (car arguments) "rationalize"))
         (y (consent--expect-number (cadr arguments) "rationalize"))
         (inexact (or (consent--number-inexact-p x)
                      (consent--number-inexact-p y)))
         (x-pair (if (consent--number-inexact-p x)
                     (consent--decimal->exact-rational-pair
                      (consent--number->float x "rationalize"))
                   (consent--number->rational-pair x "rationalize")))
         (y-pair (if (consent--number-inexact-p y)
                     (consent--decimal->exact-rational-pair
                      (consent--number->float y "rationalize"))
                   (consent--number->rational-pair y "rationalize")))
         (result
          (consent--rationalize-pair x-pair y-pair)))
    (if inexact
        (consent--number-inexact
         (consent--number-from-rational-pair result))
      (consent--number-from-rational-pair result))))

(defun consent--rational-pair< (left right)
  "Return non-nil if rational pair LEFT is less than RIGHT."
  (< (* (car left) (cdr right))
     (* (car right) (cdr left))))

(defun consent--rational-pair= (left right)
  "Return non-nil if rational pair LEFT equals RIGHT."
  (= (* (car left) (cdr right))
     (* (car right) (cdr left))))

(defun consent--rational-pair-normalize (pair)
  "Normalize rational PAIR."
  (consent--normalize-rational-pair (car pair) (cdr pair)))

(defun consent--rational-pair-negate (pair)
  "Return negated rational PAIR."
  (cons (- (car pair)) (cdr pair)))

(defun consent--rational-pair+ (left right)
  "Return LEFT plus RIGHT as a rational pair."
  (consent--rational-pair-normalize
   (cons (+ (* (car left) (cdr right))
            (* (car right) (cdr left)))
         (* (cdr left) (cdr right)))))

(defun consent--rational-pair- (left right)
  "Return LEFT minus RIGHT as a rational pair."
  (consent--rational-pair+
   left (consent--rational-pair-negate right)))

(defun consent--rational-pair-reciprocal (pair)
  "Return reciprocal of rational PAIR."
  (consent--rational-pair-normalize
   (cons (cdr pair) (car pair))))

(defun consent--rational-pair-integer-p (pair)
  "Return non-nil if rational PAIR is integral."
  (= (cdr pair) 1))

(defun consent--simplest-positive-rational-pair (lower upper)
  "Return simplest rational pair in the positive interval LOWER to UPPER."
  (cond
   ((not (consent--rational-pair<
          (cons 0 1) lower))
    (cons 0 1))
   ((consent--rational-pair-integer-p lower)
    lower)
   (t
    (let ((lower-floor (floor (car lower) (cdr lower)))
          (upper-floor (floor (car upper) (cdr upper))))
      (if (< lower-floor upper-floor)
          (cons (1+ lower-floor) 1)
        (consent--rational-pair+
         (cons lower-floor 1)
         (consent--rational-pair-reciprocal
          (consent--simplest-positive-rational-pair
           (consent--rational-pair-reciprocal
            (consent--rational-pair-
             upper (cons upper-floor 1)))
           (consent--rational-pair-reciprocal
            (consent--rational-pair-
             lower (cons lower-floor 1)))))))))))

(defun consent--simplest-rational-pair (lower upper)
  "Return simplest rational pair in interval LOWER to UPPER."
  (cond
   ((consent--rational-pair< upper lower)
    (consent--eval-error "rationalize tolerance produced empty interval"))
   ((not (consent--rational-pair< (cons 0 1) lower))
    (if (not (consent--rational-pair< upper (cons 0 1)))
        (cons 0 1)
      (consent--rational-pair-negate
       (consent--simplest-positive-rational-pair
        (consent--rational-pair-negate upper)
        (consent--rational-pair-negate lower)))))
   (t
    (consent--simplest-positive-rational-pair lower upper))))

(defun consent--rationalize-pair (x y)
  "Return the simplest rational pair within Y of X."
  (consent--simplest-rational-pair
   (consent--rational-pair- x y)
   (consent--rational-pair+ x y)))

(defun consent--primitive-finite? (arguments _context)
  "Primitive finite? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-finite-p
    (consent--expect-number (car arguments) "finite?"))))

(defun consent--primitive-infinite? (arguments _context)
  "Primitive infinite? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-infinite-p
    (consent--expect-number (car arguments) "infinite?"))))

(defun consent--primitive-nan? (arguments _context)
  "Primitive nan? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-nan-p
    (consent--expect-number (car arguments) "nan?"))))

(defun consent--primitive-inexact-unary
    (arguments function description)
  "Apply real-valued inexact FUNCTION to ARGUMENTS for DESCRIPTION."
  (consent--make-canonical-decimal
   (funcall function
            (consent--number->float (car arguments) description))))

(defun consent--primitive-exp (arguments _context)
  "Primitive exp over ARGUMENTS."
  (consent--primitive-inexact-unary arguments #'exp "exp"))

(defun consent--primitive-log (arguments _context)
  "Primitive log over ARGUMENTS."
  (let ((value (consent--primitive-inexact-unary
                (list (car arguments)) #'log "log")))
    (if (cdr arguments)
        (let ((base (consent--primitive-inexact-unary
                     (list (cadr arguments)) #'log "log")))
          (consent--primitive/
           (list value base) nil))
      value)))

(defun consent--primitive-sin (arguments _context)
  "Primitive sin over ARGUMENTS."
  (consent--primitive-inexact-unary arguments #'sin "sin"))

(defun consent--primitive-cos (arguments _context)
  "Primitive cos over ARGUMENTS."
  (consent--primitive-inexact-unary arguments #'cos "cos"))

(defun consent--primitive-tan (arguments _context)
  "Primitive tan over ARGUMENTS."
  (consent--primitive-inexact-unary arguments #'tan "tan"))

(defun consent--primitive-asin (arguments _context)
  "Primitive asin over ARGUMENTS."
  (consent--primitive-inexact-unary arguments #'asin "asin"))

(defun consent--primitive-acos (arguments _context)
  "Primitive acos over ARGUMENTS."
  (consent--primitive-inexact-unary arguments #'acos "acos"))

(defun consent--primitive-atan (arguments _context)
  "Primitive atan over ARGUMENTS."
  (if (cdr arguments)
      (consent--make-canonical-decimal
       (atan (consent--number->float (car arguments) "atan")
             (consent--number->float (cadr arguments) "atan")))
    (consent--primitive-inexact-unary arguments #'atan "atan")))

(defun consent--primitive-sqrt (arguments _context)
  "Primitive sqrt over ARGUMENTS."
  (let* ((number (consent--expect-number (car arguments) "sqrt"))
         (value (consent--number->float number "sqrt")))
    (if (and (not (consent--number-complex-p number))
             (< value 0.0))
        (consent--make-canonical-complex
         (consent--make-canonical-decimal 0.0)
         (consent--make-canonical-decimal (sqrt (- value))))
      (consent--make-canonical-decimal (sqrt value)))))

(defun consent--apply-parameter/k
    (parameter arguments context continuation)
  "Apply PARAMETER to ARGUMENTS and continue with CONTINUATION."
  (cond
   ((null arguments)
    (consent--continue
     continuation
     (consent-parameter-value parameter)))
   ((cdr arguments)
    (consent--eval-error
     "parameter expected 0..1 arguments, got %d" (length arguments)))
   ((consent-parameter-converter parameter)
    (consent--apply-procedure
     (consent-parameter-converter parameter)
     (list (car arguments))
     context
     nil
     (lambda (converted)
       (setf (consent-parameter-value parameter)
             (consent--single-value converted "parameter converter"))
       (consent--continue continuation consent-unspecified))))
   (t
    (setf (consent-parameter-value parameter) (car arguments))
    (consent--continue continuation consent-unspecified))))

(defun consent--primitive-make-parameter (arguments context)
  "Primitive make-parameter over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-make-parameter/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-make-parameter/k
    (arguments context continuation)
  "CPS primitive make-parameter over ARGUMENTS."
  (let ((initial (car arguments))
        (converter (cadr arguments)))
    (if converter
        (progn
          (unless (or (consent-procedure-p converter)
                      (consent-primitive-procedure-p converter)
                      (consent--continuation-p converter)
                      (consent-parameter-p converter))
            (consent--eval-error
             "make-parameter converter must be a procedure"))
          (consent--apply-procedure
           converter
           (list initial)
           context
           nil
           (lambda (converted)
             (consent--continue
              continuation
              (consent--make-parameter
               (consent--single-value
                converted "make-parameter converter")
               converter)))))
      (consent--continue
       continuation
       (consent--make-parameter initial nil)))))

(defun consent--primitive-make-rectangular (arguments _context)
  "Primitive make-rectangular over ARGUMENTS."
  (consent--make-canonical-complex
   (consent--expect-number (car arguments) "make-rectangular")
   (consent--expect-number (cadr arguments) "make-rectangular")))

(defun consent--primitive-make-polar (arguments _context)
  "Primitive make-polar over ARGUMENTS."
  (let ((magnitude (consent--number->float
                    (car arguments) "make-polar"))
        (angle (consent--number->float
                (cadr arguments) "make-polar")))
    (consent--make-canonical-complex
     (consent--make-canonical-decimal (* magnitude (cos angle)))
     (consent--make-canonical-decimal (* magnitude (sin angle))))))

(defun consent--primitive-real-part (arguments _context)
  "Primitive real-part over ARGUMENTS."
  (let ((number (consent--expect-number (car arguments) "real-part")))
    (if (consent--number-complex-p number)
        (car (consent-number-value number))
      number)))

(defun consent--primitive-imag-part (arguments _context)
  "Primitive imag-part over ARGUMENTS."
  (let ((number (consent--expect-number (car arguments) "imag-part")))
    (if (consent--number-complex-p number)
        (cdr (consent-number-value number))
      (consent--make-canonical-integer 0))))

(defun consent--primitive-magnitude (arguments _context)
  "Primitive magnitude over ARGUMENTS."
  (let ((number (consent--expect-number (car arguments) "magnitude")))
    (if (consent--number-complex-p number)
        (let* ((parts (consent-number-value number))
               (real (consent--number->float (car parts) "magnitude"))
               (imaginary (consent--number->float
                           (cdr parts) "magnitude")))
          (consent--make-canonical-decimal
           (sqrt (+ (* real real) (* imaginary imaginary)))))
      (consent--number-abs number))))

(defun consent--primitive-angle (arguments _context)
  "Primitive angle over ARGUMENTS."
  (let ((number (consent--expect-number (car arguments) "angle")))
    (if (consent--number-complex-p number)
        (let* ((parts (consent-number-value number))
               (real (consent--number->float (car parts) "angle"))
               (imaginary (consent--number->float
                           (cdr parts) "angle")))
          (consent--make-canonical-decimal (atan imaginary real)))
      (if (consent--number-negative-p number)
          (consent--make-canonical-decimal float-pi)
        (consent--make-canonical-decimal 0.0)))))

(defun consent--primitive-cons (arguments context)
  "Primitive cons over ARGUMENTS."
  ;; One fresh pair; its car/cdr were charged where they were allocated.
  ;; Charging `cons' charges every prelude list builder (list, append, reverse,
  ;; map, ...) that conses, with no walk of the growing result.
  (consent--charge-value-allocation
   (cons (car arguments) (cadr arguments))
   1
   context))

(defun consent--primitive-car (arguments _context)
  "Primitive car over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (consent--eval-error
       "car expected pair, got %s" (consent-value->external pair)))
    (car pair)))

(defun consent--primitive-cdr (arguments _context)
  "Primitive cdr over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (consent--eval-error
       "cdr expected pair, got %s" (consent-value->external pair)))
    (cdr pair)))

(defun consent--primitive-list (arguments _context)
  "Primitive list over ARGUMENTS."
  (copy-sequence arguments))

(defun consent--primitive-null? (arguments _context)
  "Primitive null? over ARGUMENTS."
  (if (null (car arguments)) consent-true consent-false))

(defun consent--primitive-pair? (arguments _context)
  "Primitive pair? over ARGUMENTS."
  (if (consp (car arguments)) consent-true consent-false))

(defun consent--primitive-not (arguments _context)
  "Primitive not over ARGUMENTS."
  (if (eq (car arguments) consent-false)
      consent-true
    consent-false))

(defun consent--primitive-boolean? (arguments _context)
  "Primitive boolean? over ARGUMENTS."
  (if (or (eq (car arguments) consent-true)
          (eq (car arguments) consent-false))
      consent-true
    consent-false))

(defun consent--primitive-number? (arguments _context)
  "Primitive number? over ARGUMENTS."
  (if (consent-number-p (car arguments))
      consent-true
    consent-false))

(defun consent--primitive-symbol? (arguments _context)
  "Primitive symbol? over ARGUMENTS."
  (if (consent-symbol-p (car arguments))
      consent-true
    consent-false))

(defun consent--primitive-procedure? (arguments _context)
  "Primitive procedure? over ARGUMENTS."
  (let ((value (car arguments)))
    (if (or (consent-procedure-p value)
            (consent-primitive-procedure-p value)
            (consent-parameter-p value)
            (consent--continuation-p value))
        consent-true
      consent-false)))

(defun consent--proper-list-p (value)
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

(defun consent--primitive-list? (arguments _context)
  "Primitive list? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--proper-list-p (car arguments))))

(defun consent--primitive-length (arguments _context)
  "Primitive length over ARGUMENTS."
  (consent--number-from-host
   (length (consent--proper-list-elements (car arguments) "length"))))

(defun consent--primitive-append (arguments _context)
  "Primitive append over ARGUMENTS."
  (cond
   ((null arguments) nil)
   ((null (cdr arguments)) (car arguments))
   (t
    (let ((prefixes nil)
          (last-tail (car (last arguments))))
      (dolist (list (butlast arguments))
        (push (consent--proper-list-elements list "append argument")
              prefixes))
      (apply #'append (append (nreverse prefixes) (list last-tail)))))))

(defun consent--primitive-reverse (arguments _context)
  "Primitive reverse over ARGUMENTS."
  (reverse (consent--proper-list-elements (car arguments) "reverse")))

(defun consent--primitive-list-tail (arguments _context)
  "Primitive list-tail over ARGUMENTS."
  (let ((cursor (car arguments))
        (index (consent--exact-integer->host
                (cadr arguments) "list-tail")))
    (when (< index 0)
      (consent--eval-error "list-tail index must be non-negative"))
    (dotimes (_ index)
      (unless (consp cursor)
        (consent--eval-error "list-tail index exceeds list length"))
      (setq cursor (cdr cursor)))
    cursor))

(defun consent--primitive-list-ref (arguments _context)
  "Primitive list-ref over ARGUMENTS."
  (let ((tail (consent--primitive-list-tail arguments nil)))
    (unless (consp tail)
      (consent--eval-error "list-ref index exceeds list length"))
    (car tail)))

(defun consent--primitive-list-set! (arguments _context)
  "Primitive list-set! over ARGUMENTS."
  (let ((tail (consent--primitive-list-tail arguments nil)))
    (unless (consp tail)
      (consent--eval-error "list-set! index exceeds list length"))
    (setcar tail (caddr arguments))
    consent-unspecified))

(defun consent--primitive-set-car! (arguments _context)
  "Primitive set-car! over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (consent--eval-error
       "set-car! expected pair, got %s"
       (consent-value->external pair)))
    (setcar pair (cadr arguments))
    consent-unspecified))

(defun consent--primitive-set-cdr! (arguments _context)
  "Primitive set-cdr! over ARGUMENTS."
  (let ((pair (car arguments)))
    (unless (consp pair)
      (consent--eval-error
       "set-cdr! expected pair, got %s"
       (consent-value->external pair)))
    (setcdr pair (cadr arguments))
    consent-unspecified))

(defun consent--primitive-make-list (arguments _context)
  "Primitive make-list over ARGUMENTS."
  (let* ((length (consent--exact-integer->host
                  (car arguments) "make-list"))
         (fill (if (cdr arguments) (cadr arguments) consent-unspecified)))
    (when (< length 0)
      (consent--eval-error "make-list length must be non-negative"))
    (make-list length fill)))

(defun consent--primitive-list-copy (arguments _context)
  "Primitive list-copy over ARGUMENTS."
  (let ((value (car arguments)))
    (if (consent--proper-list-p value)
        (copy-sequence value)
      value)))

(defun consent--eqv-p (left right)
  "Return non-nil if LEFT and RIGHT are eqv? under the current value model."
  (cond
   ((eq left right) t)
   ((and (consent-number-p left) (consent-number-p right))
    (and (eq (consent-number-kind left)
             (consent-number-kind right))
         (eq (consent-number-exactness left)
             (consent-number-exactness right))
         (equal (consent-number-value left)
                (consent-number-value right))))
   ((and (consent-character-p left) (consent-character-p right))
    (= (consent-character-code left)
       (consent-character-code right)))
   ((and (consent-symbol-p left) (consent-symbol-p right))
    (equal (consent-symbol-name left)
           (consent-symbol-name right)))
   (t nil)))

(defun consent--eq-p (left right)
  "Return non-nil if LEFT and RIGHT are eq? under the current value model."
  (or (eq left right)
      (and (or (consent-number-p left)
               (consent-character-p left)
               (consent-symbol-p left))
           (consent--eqv-p left right))))

(defun consent--equal-seen-p (left right seen)
  "Return non-nil when LEFT and RIGHT were already compared in SEEN."
  (memq right (gethash left seen)))

(defun consent--equal-remember (left right seen)
  "Remember that LEFT and RIGHT are being compared in SEEN."
  (puthash left (cons right (gethash left seen)) seen))

(defun consent--equal-p (left right seen)
  "Return non-nil if LEFT and RIGHT are equal?.
SEEN tracks compound value identity pairs already compared."
  (cond
   ((consent--eqv-p left right) t)
   ((and (stringp left) (stringp right))
    (equal left right))
   ((and (consent-bytevector-p left)
         (consent-bytevector-p right))
    (equal (consent-bytevector-bytes left)
           (consent-bytevector-bytes right)))
   ((and (consp left) (consp right))
    (or (consent--equal-seen-p left right seen)
        (progn
          (consent--equal-remember left right seen)
          (and (consent--equal-p (car left) (car right) seen)
               (consent--equal-p (cdr left) (cdr right) seen)))))
   ((and (vectorp left) (vectorp right)
         (= (length left) (length right)))
    (or (consent--equal-seen-p left right seen)
        (progn
          (consent--equal-remember left right seen)
          (let ((index 0)
                (ok t))
            (while (and ok (< index (length left)))
              (setq ok (consent--equal-p
                        (aref left index) (aref right index) seen))
              (cl-incf index))
            ok))))
   (t nil)))

(defun consent--primitive-eq? (arguments _context)
  "Primitive eq? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--eq-p (car arguments) (cadr arguments))))

(defun consent--primitive-eqv? (arguments _context)
  "Primitive eqv? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--eqv-p (car arguments) (cadr arguments))))

(defun consent--primitive-equal? (arguments _context)
  "Primitive equal? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--equal-p
    (car arguments) (cadr arguments) (make-hash-table :test #'eq))))

(defun consent--list-member (object list predicate description)
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
     ((null cursor) consent-false)
     (t
      (consent--eval-error "%s expected a proper list" description)))))

(defun consent--primitive-memq (arguments _context)
  "Primitive memq over ARGUMENTS."
  (consent--list-member
   (car arguments) (cadr arguments) #'consent--eq-p "memq"))

(defun consent--primitive-memv (arguments _context)
  "Primitive memv over ARGUMENTS."
  (consent--list-member
   (car arguments) (cadr arguments) #'consent--eqv-p "memv"))

(defun consent--primitive-member (arguments _context)
  "Primitive member over ARGUMENTS."
  (consent--list-member
   (car arguments)
   (cadr arguments)
   (lambda (left right)
     (consent--equal-p left right (make-hash-table :test #'eq)))
   "member"))

(defun consent--alist-assoc (object alist predicate description)
  "Return association for OBJECT in ALIST using PREDICATE."
  (let ((cursor alist)
        found)
    (while (and (consp cursor) (not found))
      (let ((entry (car cursor)))
        (unless (consp entry)
          (consent--eval-error "%s expected pair entries" description))
        (if (funcall predicate object (car entry))
            (setq found entry)
          (setq cursor (cdr cursor)))))
    (cond
     (found found)
     ((null cursor) consent-false)
     (t
      (consent--eval-error "%s expected a proper alist" description)))))

(defun consent--primitive-assq (arguments _context)
  "Primitive assq over ARGUMENTS."
  (consent--alist-assoc
   (car arguments) (cadr arguments) #'consent--eq-p "assq"))

(defun consent--primitive-assv (arguments _context)
  "Primitive assv over ARGUMENTS."
  (consent--alist-assoc
   (car arguments) (cadr arguments) #'consent--eqv-p "assv"))

(defun consent--primitive-assoc (arguments _context)
  "Primitive assoc over ARGUMENTS."
  (consent--alist-assoc
   (car arguments)
   (cadr arguments)
   (lambda (left right)
     (consent--equal-p left right (make-hash-table :test #'eq)))
   "assoc"))

(defun consent--primitive-caar (arguments _context)
  "Primitive caar over ARGUMENTS."
  (consent--primitive-car
   (list (consent--primitive-car arguments nil)) nil))

(defun consent--primitive-cadr (arguments _context)
  "Primitive cadr over ARGUMENTS."
  (consent--primitive-car
   (list (consent--primitive-cdr arguments nil)) nil))

(defun consent--primitive-cdar (arguments _context)
  "Primitive cdar over ARGUMENTS."
  (consent--primitive-cdr
   (list (consent--primitive-car arguments nil)) nil))

(defun consent--primitive-cddr (arguments _context)
  "Primitive cddr over ARGUMENTS."
  (consent--primitive-cdr
   (list (consent--primitive-cdr arguments nil)) nil))

(defun consent--primitive-boolean=? (arguments _context)
  "Primitive boolean=? over ARGUMENTS."
  (let ((first (car arguments))
        (rest (cdr arguments))
        (ok t))
    (unless (or (eq first consent-true)
                (eq first consent-false))
      (consent--eval-error "boolean=? expected booleans"))
    (while (and ok rest)
      (let ((value (car rest)))
        (unless (or (eq value consent-true)
                    (eq value consent-false))
          (consent--eval-error "boolean=? expected booleans"))
        (setq ok (eq first value)))
      (setq rest (cdr rest)))
    (consent--scheme-boolean ok)))

(defun consent--primitive-complex? (arguments _context)
  "Primitive complex? over ARGUMENTS."
  (consent--scheme-boolean (consent-number-p (car arguments))))

(defun consent--primitive-real? (arguments _context)
  "Primitive real? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-real-p (car arguments))))

(defun consent--primitive-rational? (arguments _context)
  "Primitive rational? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-rational-p (car arguments))))

(defun consent--primitive-integer? (arguments _context)
  "Primitive integer? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-integer-p (car arguments))))

(defun consent--primitive-exact-integer? (arguments _context)
  "Primitive exact-integer? over ARGUMENTS."
  (consent--scheme-boolean
   (and (consent--number-integer-p (car arguments))
        (consent--number-exact-p (car arguments)))))

(defun consent--primitive-exact? (arguments _context)
  "Primitive exact? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-exact-p (car arguments))))

(defun consent--primitive-inexact? (arguments _context)
  "Primitive inexact? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--number-inexact-p (car arguments))))

(defun consent--integer->radix-string (integer radix)
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

(defun consent--number->string (number radix)
  "Return external numeric string for NUMBER in RADIX."
  (pcase (consent-number-kind number)
    ('integer
     (consent--integer->radix-string
      (consent-number-value number) radix))
    ('rational
     (let ((value (consent-number-value number)))
       (concat
        (consent--integer->radix-string (car value) radix)
        "/"
        (consent--integer->radix-string (cdr value) radix))))
    ((or 'decimal 'infnan)
     (unless (= radix 10)
       (consent--eval-error
        "number->string only supports radix 10 for inexact numbers"))
     (consent--number->external number))
    ('complex
     (unless (= radix 10)
       (consent--eval-error
        "number->string only supports radix 10 for complex numbers"))
     (consent--number->external number))))

(defun consent--primitive-number->string (arguments context)
  "Primitive number->string over ARGUMENTS."
  (let ((number (consent--expect-number
                 (car arguments) "number->string"))
        (radix (if (cdr arguments)
                   (consent--exact-integer->host
                    (cadr arguments) "number->string radix")
                 10)))
    (unless (memq radix '(2 8 10 16))
      (consent--eval-error "number->string radix must be 2, 8, 10, or 16"))
    (consent--charge-string-allocation
     (consent--number->string number radix) context)))

(defun consent--primitive-string->number (arguments _context)
  "Primitive string->number over ARGUMENTS."
  (let* ((string (consent--expect-string
                  (car arguments) "string->number"))
         (radix (if (cdr arguments)
                    (consent--exact-integer->host
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
                       (consent--eval-error
                        "string->number radix must be 2, 8, 10, or 16")))
                    string)))
         (value (condition-case nil
                    (consent-read source)
                  (consent-reader-error nil))))
    (if (consent-number-p value)
        value
      consent-false)))

(defun consent--primitive-symbol->string (arguments context)
  "Primitive symbol->string over ARGUMENTS."
  (unless (consent-symbol-p (car arguments))
    (consent--eval-error "symbol->string expected a symbol"))
  (consent--charge-string-allocation
   (copy-sequence (consent-symbol-name (car arguments))) context))

(defun consent--primitive-string->symbol (arguments context)
  "Primitive string->symbol over ARGUMENTS, charging CONTEXT's symbol budget."
  (consent--intern-symbol-budgeted
   (consent--expect-string (car arguments) "string->symbol")
   context))

(defun consent--primitive-symbol=? (arguments _context)
  "Primitive symbol=? over ARGUMENTS."
  (let ((first (car arguments))
        (rest (cdr arguments))
        (ok t))
    (unless (consent-symbol-p first)
      (consent--eval-error "symbol=? expected symbols"))
    (while (and ok rest)
      (let ((value (car rest)))
        (unless (consent-symbol-p value)
          (consent--eval-error "symbol=? expected symbols"))
        (setq ok (equal (consent-symbol-name first)
                        (consent-symbol-name value))))
      (setq rest (cdr rest)))
    (consent--scheme-boolean ok)))

(defun consent--primitive-char? (arguments _context)
  "Primitive char? over ARGUMENTS."
  (consent--scheme-boolean (consent-character-p (car arguments))))

(defun consent--primitive-char->integer (arguments _context)
  "Primitive char->integer over ARGUMENTS."
  (consent--number-from-host
   (consent--expect-character (car arguments) "char->integer")))

(defun consent--primitive-integer->char (arguments _context)
  "Primitive integer->char over ARGUMENTS."
  (let ((code (consent--exact-integer->host
               (car arguments) "integer->char")))
    (unless (consent--valid-scalar-value-p code)
      (consent--eval-error "integer->char expected a scalar value"))
    (consent--make-character code)))

(defun consent--primitive-char-compare (arguments predicate description)
  "Return Scheme boolean for pairwise character PREDICATE over ARGUMENTS."
  (let ((codes (mapcar
                (lambda (argument)
                  (consent--expect-character argument description))
                arguments))
        (ok t))
    (while (and ok (cdr codes))
      (setq ok (funcall predicate (car codes) (cadr codes)))
      (setq codes (cdr codes)))
    (consent--scheme-boolean ok)))

(defun consent--primitive-char=? (arguments _context)
  "Primitive char=? over ARGUMENTS."
  (consent--primitive-char-compare arguments #'= "char=?"))

(defun consent--primitive-char<? (arguments _context)
  "Primitive char<? over ARGUMENTS."
  (consent--primitive-char-compare arguments #'< "char<?"))

(defun consent--primitive-char>? (arguments _context)
  "Primitive char>? over ARGUMENTS."
  (consent--primitive-char-compare arguments #'> "char>?"))

(defun consent--primitive-char<=? (arguments _context)
  "Primitive char<=? over ARGUMENTS."
  (consent--primitive-char-compare arguments #'<= "char<=?"))

(defun consent--primitive-char>=? (arguments _context)
  "Primitive char>=? over ARGUMENTS."
  (consent--primitive-char-compare arguments #'>= "char>=?"))

(defun consent--primitive-char-upcase (arguments _context)
  "Primitive char-upcase over ARGUMENTS."
  (let ((code (consent--expect-character
               (car arguments) "char-upcase")))
    (consent--make-character (upcase code))))

(defun consent--primitive-char-downcase (arguments _context)
  "Primitive char-downcase over ARGUMENTS."
  (let ((code (consent--expect-character
               (car arguments) "char-downcase")))
    (consent--make-character (downcase code))))

(defun consent--primitive-char-foldcase (arguments _context)
  "Primitive char-foldcase over ARGUMENTS."
  (let ((code (consent--expect-character
               (car arguments) "char-foldcase")))
    (consent--make-character (downcase (upcase code)))))

(defun consent--character-matches-p (code regexp)
  "Return non-nil if CODE's string representation matches REGEXP."
  (string-match-p regexp (char-to-string code)))

(defun consent--primitive-char-alphabetic? (arguments _context)
  "Primitive char-alphabetic? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--character-matches-p
    (consent--expect-character (car arguments) "char-alphabetic?")
    "\\`[[:alpha:]]\\'")))

(defun consent--primitive-char-numeric? (arguments _context)
  "Primitive char-numeric? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--character-matches-p
    (consent--expect-character (car arguments) "char-numeric?")
    "\\`[[:digit:]]\\'")))

(defun consent--primitive-char-whitespace? (arguments _context)
  "Primitive char-whitespace? over ARGUMENTS."
  (consent--scheme-boolean
   (consent--character-matches-p
    (consent--expect-character (car arguments) "char-whitespace?")
    "\\`[[:space:]]\\'")))

(defun consent--primitive-char-upper-case? (arguments _context)
  "Primitive char-upper-case? over ARGUMENTS."
  (let ((code (consent--expect-character
               (car arguments) "char-upper-case?")))
    (consent--scheme-boolean
     (and (consent--character-matches-p code "\\`[[:alpha:]]\\'")
          (= code (upcase code))
          (/= code (downcase code))))))

(defun consent--primitive-char-lower-case? (arguments _context)
  "Primitive char-lower-case? over ARGUMENTS."
  (let ((code (consent--expect-character
               (car arguments) "char-lower-case?")))
    (consent--scheme-boolean
     (and (consent--character-matches-p code "\\`[[:alpha:]]\\'")
          (= code (downcase code))
          (/= code (upcase code))))))

(defun consent--primitive-digit-value (arguments _context)
  "Primitive digit-value over ARGUMENTS."
  (let ((code (consent--expect-character (car arguments) "digit-value")))
    (if (and (>= code ?0) (<= code ?9))
        (consent--make-canonical-integer (- code ?0))
      consent-false)))

(defun consent--char-fold-code (value description)
  "Return folded character code for VALUE using DESCRIPTION."
  (downcase
   (upcase
    (consent--expect-character value description))))

(defun consent--primitive-char-ci-compare
    (arguments predicate description)
  "Return Scheme boolean for folded character PREDICATE over ARGUMENTS."
  (consent--primitive-char-compare
   (mapcar
    (lambda (argument)
      (consent--make-character
       (consent--char-fold-code argument description)))
    arguments)
   predicate
   description))

(defun consent--primitive-char-ci=? (arguments _context)
  "Primitive char-ci=? over ARGUMENTS."
  (consent--primitive-char-ci-compare arguments #'= "char-ci=?"))

(defun consent--primitive-char-ci<? (arguments _context)
  "Primitive char-ci<? over ARGUMENTS."
  (consent--primitive-char-ci-compare arguments #'< "char-ci<?"))

(defun consent--primitive-char-ci>? (arguments _context)
  "Primitive char-ci>? over ARGUMENTS."
  (consent--primitive-char-ci-compare arguments #'> "char-ci>?"))

(defun consent--primitive-char-ci<=? (arguments _context)
  "Primitive char-ci<=? over ARGUMENTS."
  (consent--primitive-char-ci-compare arguments #'<= "char-ci<=?"))

(defun consent--primitive-char-ci>=? (arguments _context)
  "Primitive char-ci>=? over ARGUMENTS."
  (consent--primitive-char-ci-compare arguments #'>= "char-ci>=?"))

(defun consent--display-string (value)
  "Return a focused display representation for VALUE."
  (consent-datum->external value 'write t))

(defun consent--expect-port (value description)
  "Return VALUE as an Consent Scheme port for DESCRIPTION."
  (unless (consent--port-p value)
    (consent--eval-error "%s expected a port" description))
  value)

(defun consent--expect-open-port (value description)
  "Return VALUE as an open port for DESCRIPTION."
  (let ((port (consent--expect-port value description)))
    (unless (consent--port-openp port)
      (if (consent--port-backing-domain port)
          (progn
            (consent-capability-audit-port-result
             port 'use "closed port capability handle" t)
            (signal 'consent-capability-grant-error
                    (list "stale port capability handle: closed port")))
        (consent--eval-error "%s expected an open port" description)))
    port))

(defun consent--expect-input-port (value description)
  "Return VALUE as an open input port for DESCRIPTION."
  (let ((port (consent--expect-open-port value description)))
    (unless (consent--port-inputp port)
      (consent--eval-error "%s expected an input port" description))
    port))

(defun consent--expect-output-port (value description)
  "Return VALUE as an open output port for DESCRIPTION."
  (let ((port (consent--expect-open-port value description)))
    (unless (consent--port-outputp port)
      (consent--eval-error "%s expected an output port" description))
    port))

(defun consent--expect-textual-input-port (value description)
  "Return VALUE as an open textual input port for DESCRIPTION."
  (let ((port (consent--expect-input-port value description)))
    (unless (consent--port-textualp port)
      (consent--eval-error "%s expected a textual input port" description))
    port))

(defun consent--expect-textual-output-port (value description)
  "Return VALUE as an open textual output port for DESCRIPTION."
  (let ((port (consent--expect-output-port value description)))
    (unless (consent--port-textualp port)
      (consent--eval-error "%s expected a textual output port" description))
    port))

(defun consent--expect-binary-input-port (value description)
  "Return VALUE as an open binary input port for DESCRIPTION."
  (let ((port (consent--expect-input-port value description)))
    (unless (consent--port-binaryp port)
      (consent--eval-error "%s expected a binary input port" description))
    port))

(defun consent--expect-binary-output-port (value description)
  "Return VALUE as an open binary output port for DESCRIPTION."
  (let ((port (consent--expect-output-port value description)))
    (unless (consent--port-binaryp port)
      (consent--eval-error "%s expected a binary output port" description))
    port))

(defun consent--expect-string-output-port (value description)
  "Return VALUE as an open output string port for DESCRIPTION."
  (let ((port (consent--expect-textual-output-port value description)))
    (unless (eq (consent--port-medium port) 'string)
      (consent--eval-error "%s expected an output string port" description))
    port))

(defun consent--expect-bytevector-output-port (value description)
  "Return VALUE as an open output bytevector port for DESCRIPTION."
  (let ((port (consent--expect-binary-output-port value description)))
    (unless (eq (consent--port-medium port) 'bytevector)
      (consent--eval-error
       "%s expected an output bytevector port" description))
    port))

(defun consent--port-capability-check
    (port context operation)
  "Revalidate PORT for host-backed OPERATION in CONTEXT."
  (consent-capability-revalidate-port-operation
   port context operation))

(defun consent--current-input-port-or-deny (context description)
  "Return CONTEXT's current input port or deny host default access."
  (or (and context (consent--eval-context-current-input-port context))
      (consent--policy-denied description context)))

;; Standard streams (docs/repl-interaction-contract.md, "Stream Separation"): an
;; evaluation may connect its `(current-input-port)', `(current-output-port)', and
;; `(current-error-port)' to the process standard streams.  The standard streams
;; are consented by invocation -- what the caller handed the process -- so the
;; host attaching real stdio also supplies, by default, the device callbacks plus
;; one `port' grant per stream (`(backing stdin)'/`stdout'/`stderr'); the core
;; stays fail-closed and connects a stream only when its device and a matching
;; active grant are both present.  No raw host port is exposed: input is pulled
;; through a reader thunk and output flushed through a writer thunk.  Ambient
;; effects gate separately.  Emacs parity twin of the portable
;; `(consent interpreter)' standard-stream connection.
(defun consent--standard-stream-grant-p (grant backing operation)
  "Report whether GRANT is an active `port' grant for OPERATION backed by BACKING.
BACKING and OPERATION are Emacs symbols (e.g. `stdin'/`read'); grant fields carry
interned Consent symbols, so the comparison is by symbol name."
  (and (consent--capability-grant-datum-p grant)
       (equal (consent--capability-grant-symbol-name
               (consent--capability-grant-field-value grant "domain"))
              "port")
       (consent--capability-grant-active-p grant)
       (seq-some
        (lambda (op)
          (equal (consent--capability-grant-symbol-name op)
                 (symbol-name operation)))
        (consent--capability-grant-field-values grant "operations"))
       (equal (consent--capability-grant-symbol-name
               (consent--capability-scope-value grant "backing"))
              (symbol-name backing))))

(defun consent--find-standard-stream-grant (context backing operation)
  "Return CONTEXT's active `port' grant for OPERATION backed by BACKING, or nil."
  (seq-find (lambda (grant)
              (consent--standard-stream-grant-p grant backing operation))
            (consent--capability-context-grants context)))

;; A program-input port draws characters from a host reader on demand: a
;; zero-argument function returning the next chunk of input as a non-empty
;; string, or nil at end of stream.  The host supplies it (its real stdin read,
;; one line/chunk at a time); genuinely finite in-memory input is wrapped as a
;; one-shot reader by `consent-program-input-from-string'.  Reads refill only as far
;; as the current operation needs, so a `(read-line)' filter over a live or
;; unbounded pipe processes input incrementally instead of draining it all up
;; front.  The reader and an end-of-stream flag ride in the port's mutable
;; counters alist; the growable buffer is the port `source'.  Emacs parity twin
;; of the portable `(consent interpreter)' streaming program-input port.
(defconst consent--program-input-refill-primitive
  (consent--make-primitive-procedure 'program-input-read nil 0 0)
  "Synthetic primitive naming program-input refills for host-callback budgeting.")

(defun consent--program-input-reader-from-options (options)
  "Return the host input reader thunk from OPTIONS' `:program-input-reader', or nil.
Program input is always a reader (a stream); a caller with finite in-memory input
wraps it with `consent-program-input-from-string' rather than passing a raw
string, so the finite case states its no-time-dimension nature explicitly."
  (let ((reader (consent--eval-option options :program-input-reader nil)))
    (and (functionp reader) reader)))

(defun consent--program-input-streaming-p (port)
  "Return non-nil when PORT draws from a host program-input reader."
  (and (consent--port-p port)
       (eq (consent--port-backing-domain port) 'stdio)
       (assq 'program-input-reader (consent--port-counters port))
       t))

(defun consent--program-input-reader-of (port)
  "Return PORT's host input reader function."
  (cdr (assq 'program-input-reader (consent--port-counters port))))

(defun consent--program-input-eof-p (port)
  "Return non-nil when PORT's host reader has reached end of stream."
  (cdr (assq 'program-input-eof (consent--port-counters port))))

(defun consent--program-input-set-eof! (port)
  "Mark PORT's host reader as exhausted so it is not called again."
  (push (cons 'program-input-eof t) (consent--port-counters port)))

(defun consent--program-input-refill! (port context)
  "Pull one more chunk from PORT's host reader onto its buffer.
Return non-nil when characters were appended, nil at end of stream.  Each pull is
charged against the host-callback budget and audited as a port read, so an
unbounded stream stays budget-bounded and fail-closed like every host effect."
  (unless (consent--program-input-eof-p port)
    (consent--note-host-callback context consent--program-input-refill-primitive)
    (let ((chunk (funcall (consent--program-input-reader-of port))))
      (if (and (stringp chunk) (> (length chunk) 0))
          (progn
            (setf (consent--port-source port)
                  (concat (consent--port-source port) chunk))
            (consent-capability-audit-port-result port 'read (length chunk))
            t)
        (progn
          (consent--program-input-set-eof! port)
          nil)))))

(defun consent--program-input-fill-until! (port context done-p)
  "Refill PORT from its host reader until DONE-P holds or the stream ends."
  (while (and (not (funcall done-p))
              (not (consent--program-input-eof-p port)))
    (consent--program-input-refill! port context)))

(defun consent--program-input-line-buffered-p (source position)
  "Return non-nil when SOURCE holds a newline at or after POSITION."
  (and (string-match-p "\n" (substring source (min position (length source))))
       t))

(defun consent--program-input-read-streaming (port context)
  "Read one datum from streaming PORT, refilling until a complete datum is
buffered, then delegating to the validating raise-on-error reader so streaming
`read' shares the single datum path.
Refilling keeps pulling while the buffered prefix is `incomplete' (a valid
partial datum) or `eof' (exhausted without a datum yet), and stops once a
whole `datum' is buffered or the prefix is `invalid';
`consent--program-input-fill-until!' also stops when the host stream ends."
  (consent--program-input-fill-until!
   port context
   (lambda ()
     (memq (consent-recovery-step-status
            (consent-read-recover-from-string-at
             (consent--port-source port)
             (consent--port-position port)))
           '(datum invalid))))
  (let ((result (consent--read-one-from-string-at
                 (consent--port-source port)
                 (consent--port-position port))))
    (setf (consent--port-position port) (cdr result))
    (consent-capability-audit-port-result port 'read 'datum)
    (if (eq (car result) consent--read-eof)
        consent-eof-object
      (car result))))

(defun consent--make-program-input-port (grant reader)
  "Return a capability-gated, refill-on-demand textual input port for GRANT.
The port is backed by the `stdio' domain so every read revalidates GRANT and
audits the operation, and pulls characters from READER on demand rather than
holding a live host port."
  (let* ((grant-id (consent--capability-grant-id grant))
         (limits (consent--port-capability-limits grant))
         (handle-id (consent--port-capability-handle-id))
         (port (consent--make-port
                :medium 'string :inputp t :outputp nil
                :textualp t :binaryp nil :openp t
                :source "" :position 0 :contents nil
                :backing-domain 'stdio :operations '(read close)
                :grant grant-id :limits limits :handle handle-id
                :status 'open :path 'program-input
                :counters (list (cons 'program-input-reader reader)))))
    (consent-audit-record
     'capability-handle
     `((handle . ,(consent--port-capability-datum
                   handle-id 'textual-input 'stdio '(read close)
                   grant-id limits 'open 'program-input))
       (domain . port)
       (kind . textual-input)
       (backing . stdio)
       (operations read close)
       (grant . ,grant-id)
       (status . open)))
    port))

;; The binary peer of the program-input port (#528): a `stdio'-backed binary
;; input port that refills *bytes* on demand from a host byte reader -- a
;; zero-argument function returning the next chunk as a non-empty vector of bytes,
;; or nil at end of stream -- so a byte filter calling `read-u8'/`peek-u8'/
;; `read-bytevector' over a live or unbounded pipe processes input incrementally
;; instead of draining it up front.  The byte reader and an end-of-stream flag
;; ride in the port's counters alist; the growable buffer is the port `source'
;; byte vector.  Byte twin of the textual reader thunk, with a distinct counters
;; key so a binary and a textual stdin port never cross paths.  Emacs parity twin
;; of the portable `(consent interpreter)' streaming binary program-input port.
(defconst consent--program-binary-input-refill-primitive
  (consent--make-primitive-procedure 'program-binary-input-read nil 0 0)
  "Synthetic primitive naming binary program-input refills for budgeting.")

(defun consent--program-binary-input-streaming-p (port)
  "Return non-nil when PORT draws bytes from a host program-input byte reader."
  (and (consent--port-p port)
       (eq (consent--port-backing-domain port) 'stdio)
       (assq 'program-input-byte-reader (consent--port-counters port))
       t))

(defun consent--program-binary-input-reader-of (port)
  "Return PORT's host input byte reader function."
  (cdr (assq 'program-input-byte-reader (consent--port-counters port))))

(defun consent--program-binary-input-eof-p (port)
  "Return non-nil when PORT's host byte reader has reached end of stream."
  (cdr (assq 'program-input-byte-eof (consent--port-counters port))))

(defun consent--program-binary-input-set-eof! (port)
  "Mark PORT's host byte reader as exhausted so it is not called again."
  (push (cons 'program-input-byte-eof t) (consent--port-counters port)))

(defun consent--program-binary-input-refill! (port context)
  "Pull one more chunk from PORT's host byte reader onto its buffer.
Return non-nil when bytes were appended, nil at end of stream.  Each pull is
charged against the host-callback budget and audited as a port read, so an
unbounded byte stream stays budget-bounded and fail-closed like every host effect."
  (unless (consent--program-binary-input-eof-p port)
    (consent--note-host-callback
     context consent--program-binary-input-refill-primitive)
    (let ((chunk (funcall (consent--program-binary-input-reader-of port))))
      (if (and (vectorp chunk) (> (length chunk) 0))
          (progn
            (setf (consent--port-source port)
                  (vconcat (consent--port-source port) chunk))
            (consent-capability-audit-port-result port 'read (length chunk))
            t)
        (progn
          (consent--program-binary-input-set-eof! port)
          nil)))))

(defun consent--program-binary-input-fill-until! (port context done-p)
  "Refill PORT from its host byte reader until DONE-P holds or the stream ends."
  (while (and (not (funcall done-p))
              (not (consent--program-binary-input-eof-p port)))
    (consent--program-binary-input-refill! port context)))

(defun consent--program-binary-input-buffered>= (port amount)
  "Return non-nil when PORT has at least AMOUNT unread bytes buffered."
  (>= (- (length (consent--port-source port))
         (consent--port-position port))
      amount))

(defun consent--make-program-binary-input-port (grant reader)
  "Return a capability-gated, refill-on-demand binary input port for GRANT.
The port is backed by the `stdio' domain so every read revalidates GRANT and
audits the operation, and pulls bytes from READER on demand rather than holding a
live host port.  Binary twin of `consent--make-program-input-port'."
  (let* ((grant-id (consent--capability-grant-id grant))
         (limits (consent--port-capability-limits grant))
         (handle-id (consent--port-capability-handle-id))
         (port (consent--make-port
                :medium 'bytevector :inputp t :outputp nil
                :textualp nil :binaryp t :openp t
                :source [] :position 0 :contents nil
                :backing-domain 'stdio :operations '(read close)
                :grant grant-id :limits limits :handle handle-id
                :status 'open :path 'program-input
                :counters (list (cons 'program-input-byte-reader reader)))))
    (consent-audit-record
     'capability-handle
     `((handle . ,(consent--port-capability-datum
                   handle-id 'binary-input 'stdio '(read close)
                   grant-id limits 'open 'program-input))
       (domain . port)
       (kind . binary-input)
       (backing . stdio)
       (operations read close)
       (grant . ,grant-id)
       (status . open)))
    port))

;; A program-output / program-error port is the write side of the standard
;; streams: a `stdio'-backed port whose textual writes flush through a host writer
;; thunk immediately (see `consent--write-text-to-port'), so program output is
;; never buffered to end of program and a filter streams as it runs.
(defconst consent--program-output-write-primitive
  (consent--make-primitive-procedure 'program-output-write nil 0 0)
  "Synthetic primitive naming program-output writes for host-callback budgeting.")

(defun consent--program-output-streaming-p (port)
  "Report whether PORT flushes through a host program-output writer."
  (and (consent--port-p port)
       (consent--port-outputp port)
       (eq (consent--port-backing-domain port) 'stdio)
       (assq 'program-output-writer (consent--port-counters port))
       t))

(defun consent--program-output-writer-of (port)
  "Return PORT's host output writer function."
  (cdr (assq 'program-output-writer (consent--port-counters port))))

(defun consent--make-program-output-port (grant writer purpose)
  "Return a capability-gated, write-through textual output port for GRANT.
PURPOSE is `program-output' or `program-error'.  The port is backed by the
`stdio' domain so every write revalidates GRANT and audits the operation, and
flushes through WRITER immediately rather than holding a live host port."
  (let* ((grant-id (consent--capability-grant-id grant))
         (limits (consent--port-capability-limits grant))
         (handle-id (consent--port-capability-handle-id))
         (port (consent--make-port
                :medium 'string :inputp nil :outputp t
                :textualp t :binaryp nil :openp t
                :source nil :position 0 :contents ""
                :backing-domain 'stdio :operations '(write flush close)
                :grant grant-id :limits limits :handle handle-id
                :status 'open :path purpose
                :counters (list (cons 'program-output-writer writer)))))
    (consent-audit-record
     'capability-handle
     `((handle . ,(consent--port-capability-datum
                   handle-id 'textual-output 'stdio '(write flush close)
                   grant-id limits 'open purpose))
       (domain . port)
       (kind . textual-output)
       (backing . stdio)
       (operations write flush close)
       (grant . ,grant-id)
       (status . open)))
    port))

;; The binary peer of the program-output / program-error port (#528): a
;; `stdio'-backed binary output port whose byte writes flush through a host byte
;; writer immediately (see `consent--append-bytes-to-port'), so a `write-u8'/
;; `write-bytevector' filter streams as it runs instead of buffering to end of
;; program.  The byte writer receives each flush as a list of byte integers -- the
;; representation `consent--append-bytes-to-port' already accumulates -- under a
;; distinct counters key from the textual writer.
(defconst consent--program-binary-output-write-primitive
  (consent--make-primitive-procedure 'program-binary-output-write nil 0 0)
  "Synthetic primitive naming binary program-output writes for budgeting.")

(defun consent--program-binary-output-streaming-p (port)
  "Report whether PORT flushes through a host program-output byte writer."
  (and (consent--port-p port)
       (consent--port-outputp port)
       (eq (consent--port-backing-domain port) 'stdio)
       (assq 'program-output-byte-writer (consent--port-counters port))
       t))

(defun consent--program-binary-output-writer-of (port)
  "Return PORT's host output byte writer function."
  (cdr (assq 'program-output-byte-writer (consent--port-counters port))))

(defun consent--make-program-binary-output-port (grant writer purpose)
  "Return a capability-gated, write-through binary output port for GRANT.
PURPOSE is `program-output' or `program-error'.  The port is backed by the
`stdio' domain so every write revalidates GRANT and audits the operation, and
flushes bytes through WRITER immediately.  Binary twin of
`consent--make-program-output-port'."
  (let* ((grant-id (consent--capability-grant-id grant))
         (limits (consent--port-capability-limits grant))
         (handle-id (consent--port-capability-handle-id))
         (port (consent--make-port
                :medium 'bytevector :inputp nil :outputp t
                :textualp nil :binaryp t :openp t
                :source nil :position 0 :contents nil
                :backing-domain 'stdio :operations '(write flush close)
                :grant grant-id :limits limits :handle handle-id
                :status 'open :path purpose
                :counters (list (cons 'program-output-byte-writer writer)))))
    (consent-audit-record
     'capability-handle
     `((handle . ,(consent--port-capability-datum
                   handle-id 'binary-output 'stdio '(write flush close)
                   grant-id limits 'open purpose))
       (domain . port)
       (kind . binary-output)
       (backing . stdio)
       (operations write flush close)
       (grant . ,grant-id)
       (status . open)))
    port))

(defun consent--connect-standard-stream!
    (context device backing operation build install)
  "Connect one standard stream when DEVICE and a matching grant are present.
DEVICE is the host reader/writer (or nil); BACKING/OPERATION select the grant;
BUILD makes the port from GRANT; INSTALL stores it on CONTEXT.  Without the grant
the connection is denied and recorded; without the device it is a no-op."
  (when device
    (let ((grant (consent--find-standard-stream-grant context backing operation)))
      (consent-audit-record
       'capability-request
       `((domain . port) (operation . ,operation) (backing . ,backing)))
      (if grant
          (progn
            (consent-audit-record
             'capability-decision
             `((status . approved) (domain . port) (operation . ,operation)
               (backing . ,backing)
               (grant . ,(consent--capability-grant-id grant))))
            (funcall install (funcall build grant)))
        (consent-audit-record
         'capability-decision
         `((status . denied) (domain . port) (operation . ,operation)
           (backing . ,backing)
           (reason . "standard stream requires a matching port grant")))))))

(defun consent--connect-standard-streams! (context options)
  "Connect CONTEXT's current input/output/error ports to the granted standard
streams.  Each stream is wired only when OPTIONS supply its host device (a textual
`:program-input-reader' thunk / `:program-output-writer' / `:program-error-writer',
or the binary `:program-input-byte-reader' / `:program-output-byte-writer' /
`:program-error-byte-writer' peers) AND CONTEXT holds a matching active `port'
grant; absent the grant the stream fails closed, absent the device it is left
untouched.  A stream is textual or binary, not both within a run: the binary
device connects only when the textual device for the same stream is absent, so the
established textual path takes precedence and the binary peer is purely additive.
The standard streams are consented by invocation; ambient effects keep gating."
  (let ((reader (consent--program-input-reader-from-options options))
        (out-writer (consent--eval-option options :program-output-writer nil))
        (err-writer (consent--eval-option options :program-error-writer nil))
        (byte-reader
         (consent--eval-option options :program-input-byte-reader nil))
        (out-byte-writer
         (consent--eval-option options :program-output-byte-writer nil))
        (err-byte-writer
         (consent--eval-option options :program-error-byte-writer nil)))
    (consent--connect-standard-stream!
     context reader 'stdin 'read
     (lambda (grant) (consent--make-program-input-port grant reader))
     (lambda (port)
       (setf (consent--eval-context-current-input-port context) port)))
    (consent--connect-standard-stream!
     context (and (not reader) (functionp byte-reader) byte-reader) 'stdin 'read
     (lambda (grant)
       (consent--make-program-binary-input-port grant byte-reader))
     (lambda (port)
       (setf (consent--eval-context-current-input-port context) port)))
    (consent--connect-standard-stream!
     context (and (functionp out-writer) out-writer) 'stdout 'write
     (lambda (grant)
       (consent--make-program-output-port grant out-writer 'program-output))
     (lambda (port)
       (setf (consent--eval-context-current-output-port context) port)))
    (consent--connect-standard-stream!
     context (and (not (functionp out-writer))
                  (functionp out-byte-writer) out-byte-writer)
     'stdout 'write
     (lambda (grant)
       (consent--make-program-binary-output-port
        grant out-byte-writer 'program-output))
     (lambda (port)
       (setf (consent--eval-context-current-output-port context) port)))
    (consent--connect-standard-stream!
     context (and (functionp err-writer) err-writer) 'stderr 'write
     (lambda (grant)
       (consent--make-program-output-port grant err-writer 'program-error))
     (lambda (port)
       (setf (consent--eval-context-current-error-port context) port)))
    (consent--connect-standard-stream!
     context (and (not (functionp err-writer))
                  (functionp err-byte-writer) err-byte-writer)
     'stderr 'write
     (lambda (grant)
       (consent--make-program-binary-output-port
        grant err-byte-writer 'program-error))
     (lambda (port)
       (setf (consent--eval-context-current-error-port context) port)))))

(defun consent--current-output-port-or-deny (context description)
  "Return CONTEXT's current output port or deny host default access."
  (or (and context (consent--eval-context-current-output-port context))
      (consent--policy-denied description context)))

(defun consent--current-error-port-or-deny (context description)
  "Return CONTEXT's current error port or deny host default access."
  (or (and context (consent--eval-context-current-error-port context))
      (consent--policy-denied description context)))

(defun consent--primitive-current-input-port (_arguments context)
  "Primitive current-input-port."
  (consent--current-input-port-or-deny context "current-input-port"))

(defun consent--primitive-current-output-port (_arguments context)
  "Primitive current-output-port."
  (consent--current-output-port-or-deny context "current-output-port"))

(defun consent--primitive-current-error-port (_arguments context)
  "Primitive current-error-port."
  (consent--current-error-port-or-deny context "current-error-port"))

(defun consent--write-text-to-port (text port description &optional context)
  "Append TEXT to textual output PORT for DESCRIPTION."
  (let ((output (consent--expect-textual-output-port port description)))
    (unless (memq (consent--port-medium output) '(string file process))
      (consent--eval-error
       "%s host textual output ports are not available" description))
    (consent--port-capability-check output context 'write)
    ;; Charge the emitted characters against the output budget before the write
    ;; lands so an unbounded printing loop fails closed without first emitting
    ;; the over-budget bytes.
    (when context
      (consent--note-output context (length text)))
    ;; A streaming stdio output port flushes each write through its host writer
    ;; immediately (so a single-form filter loop streams instead of buffering to
    ;; end of program), charged against the host-callback budget; an ordinary
    ;; in-memory port accumulates its contents as before.
    (if (consent--program-output-streaming-p output)
        (progn
          (when context
            (consent--note-host-callback
             context consent--program-output-write-primitive))
          (funcall (consent--program-output-writer-of output) text))
      (setf (consent--port-contents output)
            (concat (consent--port-contents output) text)))
    (consent-capability-audit-port-result
     output 'write (length text)))
  consent-unspecified)

(defun consent--write-to-output-port
    (value port mode displayp &optional context)
  "Write VALUE to PORT using MODE and display rendering when DISPLAYP is non-nil."
  (consent--write-text-to-port
   (if displayp
       (consent--display-string value)
     (consent-datum->external value mode))
   port
   (if displayp "display" "write")
   context))

(defun consent--primitive-eof-object? (arguments _context)
  "Primitive eof-object? over ARGUMENTS."
  (consent--scheme-boolean (consent-eof-object-p (car arguments))))

(defun consent--primitive-eof-object (_arguments _context)
  "Primitive eof-object."
  consent-eof-object)

(defun consent--primitive-port? (arguments _context)
  "Primitive port? over ARGUMENTS."
  (consent--scheme-boolean (consent--port-p (car arguments))))

(defun consent--primitive-input-port? (arguments _context)
  "Primitive input-port? over ARGUMENTS."
  (consent--scheme-boolean
   (and (consent--port-p (car arguments))
        (consent--port-inputp (car arguments)))))

(defun consent--primitive-output-port? (arguments _context)
  "Primitive output-port? over ARGUMENTS."
  (consent--scheme-boolean
   (and (consent--port-p (car arguments))
        (consent--port-outputp (car arguments)))))

(defun consent--primitive-textual-port? (arguments _context)
  "Primitive textual-port? over ARGUMENTS."
  (consent--scheme-boolean
   (and (consent--port-p (car arguments))
        (consent--port-textualp (car arguments)))))

(defun consent--primitive-binary-port? (arguments _context)
  "Primitive binary-port? over ARGUMENTS."
  (consent--scheme-boolean
   (and (consent--port-p (car arguments))
        (consent--port-binaryp (car arguments)))))

(defun consent--primitive-input-port-open? (arguments _context)
  "Primitive input-port-open? over ARGUMENTS."
  (let ((port (consent--expect-port (car arguments) "input-port-open?")))
    (consent--scheme-boolean
     (and (consent--port-inputp port)
          (consent--port-openp port)))))

(defun consent--primitive-output-port-open? (arguments _context)
  "Primitive output-port-open? over ARGUMENTS."
  (let ((port (consent--expect-port (car arguments) "output-port-open?")))
    (consent--scheme-boolean
     (and (consent--port-outputp port)
          (consent--port-openp port)))))

(defun consent--byte-list->unibyte-string (bytes)
  "Return BYTES as an unibyte string for binary host file output."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dolist (byte bytes)
      (insert (unibyte-string byte)))
    (buffer-string)))

(defun consent--host-file-output-contents (port)
  "Return PORT contents in the host representation for file output."
  (if (consent--port-binaryp port)
      (consent--byte-list->unibyte-string
       (or (consent--port-contents port) nil))
    (or (consent--port-contents port) "")))

(defun consent--flush-file-output-port (port context operation)
  "Write host-backed output PORT contents to its file path for OPERATION."
  (when (and (eq (consent--port-backing-domain port) 'file)
             (consent--port-outputp port))
    (consent--port-capability-check port context operation)
    (condition-case condition
        (progn
          (write-region
           (consent--host-file-output-contents port)
           nil
           (consent--port-path port)
           nil
           'silent)
          (consent-capability-audit-port-result port operation 'flushed))
      (file-error
       (consent-capability-audit-port-result
        port operation (error-message-string condition) t)
       (signal (car condition) (cdr condition))))))

(defun consent--close-port-value (port &optional context)
  "Close PORT and return the unspecified value."
  (when (consent--port-openp port)
    (when (consent--port-backing-domain port)
      (consent--port-capability-check port context 'close))
    (when (and (eq (consent--port-backing-domain port) 'file)
               (consent--port-outputp port))
      (condition-case condition
          (write-region
           (consent--host-file-output-contents port)
           nil
           (consent--port-path port)
           nil
           'silent)
        (file-error
         (consent-capability-audit-port-result
          port 'close (error-message-string condition) t)
         (signal (car condition) (cdr condition)))))
    (setf (consent--port-openp port) nil)
    (setf (consent--port-status port) 'closed)
    (consent-capability-audit-port-result port 'close 'closed))
  consent-unspecified)

(defun consent--primitive-close-port (arguments context)
  "Primitive close-port over ARGUMENTS."
  (consent--close-port-value
   (consent--expect-port (car arguments) "close-port")
   context))

(defun consent--primitive-close-input-port (arguments context)
  "Primitive close-input-port over ARGUMENTS."
  (consent--close-port-value
   (consent--expect-input-port (car arguments) "close-input-port")
   context))

(defun consent--primitive-close-output-port (arguments context)
  "Primitive close-output-port over ARGUMENTS."
  (consent--close-port-value
   (consent--expect-output-port (car arguments) "close-output-port")
   context))

(defun consent--primitive-open-output-string (_arguments _context)
  "Primitive open-output-string."
  (consent--make-port
   :medium 'string
   :outputp t
   :textualp t
   :contents ""))

(defun consent--primitive-open-input-string (arguments _context)
  "Primitive open-input-string over ARGUMENTS."
  (consent--make-port
   :medium 'string
   :inputp t
   :textualp t
   :source (copy-sequence
            (consent--expect-string (car arguments) "open-input-string"))
   :position 0))

(defun consent--primitive-get-output-string (arguments context)
  "Primitive get-output-string over ARGUMENTS."
  (consent--charge-string-allocation
   (copy-sequence
    (consent--port-contents
     (consent--expect-string-output-port
      (car arguments) "get-output-string")))
   context))

(defun consent--primitive-open-output-bytevector (_arguments _context)
  "Primitive open-output-bytevector."
  (consent--make-port
   :medium 'bytevector
   :outputp t
   :binaryp t
   :contents nil))

(defun consent--primitive-open-input-bytevector (arguments _context)
  "Primitive open-input-bytevector over ARGUMENTS."
  (let ((bytevector
         (consent--expect-bytevector
          (car arguments) "open-input-bytevector")))
    (consent--make-port
     :medium 'bytevector
     :inputp t
     :binaryp t
     :source (copy-sequence (consent-bytevector-bytes bytevector))
     :position 0)))

(defun consent--primitive-get-output-bytevector (arguments context)
  "Primitive get-output-bytevector over ARGUMENTS."
  (consent--charge-bytevector-allocation
   (consent--make-bytevector
    (vconcat
     (consent--port-contents
      (consent--expect-bytevector-output-port
       (car arguments) "get-output-bytevector"))))
   context))

(defun consent--primitive-read (arguments context)
  "Primitive read over ARGUMENTS."
  (let ((port (consent--expect-textual-input-port
               (if arguments
                   (car arguments)
                 (consent--current-input-port-or-deny context "read"))
               "read")))
    (consent--port-capability-check port context 'read)
    ;; `read' realizes fresh structure from external input, so charge the parsed
    ;; datum once -- like a literal -- to bound oversized input.
    (if (consent--program-input-streaming-p port)
        (consent--charge-literal
         (consent--program-input-read-streaming port context) context)
      (let ((result
             (consent--read-one-from-string-at
              (consent--port-source port)
              (consent--port-position port))))
        (setf (consent--port-position port) (cdr result))
        (consent-capability-audit-port-result port 'read 'datum)
        (consent--charge-literal
         (if (eq (car result) consent--read-eof)
             consent-eof-object
           (car result))
         context)))))

(defun consent--text-port-next-code
    (port advancep description context)
  "Return next character code from textual input PORT.
Advance when ADVANCEP is non-nil.  Signal errors using DESCRIPTION."
  (let ((input (consent--expect-textual-input-port port description)))
    (unless (memq (consent--port-medium input)
                  '(string file process network))
      (consent--eval-error
       "%s host textual input ports are not available" description))
    (consent--port-capability-check input context 'read)
    (when (consent--program-input-streaming-p input)
      (consent--program-input-fill-until!
       input context
       (lambda ()
         (> (length (consent--port-source input))
            (consent--port-position input)))))
    (let ((position (consent--port-position input))
          (source (consent--port-source input)))
      (if (>= position (length source))
          (prog1 consent-eof-object
            (consent-capability-audit-port-result input 'read 'eof))
        (prog1 (aref source position)
          (when advancep
            (setf (consent--port-position input) (1+ position)))
          (consent-capability-audit-port-result input 'read 1))))))

(defun consent--primitive-read-char (arguments context)
  "Primitive read-char over ARGUMENTS."
  (let ((value (if arguments
                   (consent--text-port-next-code
                    (car arguments) t "read-char" context)
                 (consent--text-port-next-code
                  (consent--current-input-port-or-deny context "read-char")
                  t "read-char" context))))
    (if (consent-eof-object-p value)
        value
      (consent--make-character value))))

(defun consent--primitive-peek-char (arguments context)
  "Primitive peek-char over ARGUMENTS."
  (let ((value (if arguments
                   (consent--text-port-next-code
                    (car arguments) nil "peek-char" context)
                 (consent--text-port-next-code
                  (consent--current-input-port-or-deny context "peek-char")
                  nil "peek-char" context))))
    (if (consent-eof-object-p value)
        value
      (consent--make-character value))))

(defun consent--primitive-char-ready? (arguments _context)
  "Primitive char-ready? over ARGUMENTS."
  (when arguments
    (consent--expect-textual-input-port (car arguments) "char-ready?"))
  consent-true)

(defun consent--primitive-read-string (arguments context)
  "Primitive read-string over ARGUMENTS."
  (let* ((count (consent--exact-integer->host
                 (car arguments) "read-string"))
           (port (if (cdr arguments)
                   (consent--expect-textual-input-port
                    (cadr arguments) "read-string")
                 (consent--current-input-port-or-deny
                  context "read-string"))))
    (when (< count 0)
      (consent--eval-error "read-string count must be non-negative"))
    (cond
     ((null port)
      (if (zerop count) "" consent-eof-object))
     ((not (memq (consent--port-medium port)
                 '(string file process network)))
      (consent--eval-error
       "read-string host textual input ports are not available"))
     (t
      (consent--port-capability-check port context 'read)
      (when (consent--program-input-streaming-p port)
        (consent--program-input-fill-until!
         port context
         (lambda ()
           (>= (- (length (consent--port-source port))
                  (consent--port-position port))
               count))))
      (let* ((source (consent--port-source port))
             (position (consent--port-position port))
             (remaining (- (length source) position))
             (amount (min count remaining)))
        (cond
         ((zerop count) "")
         ((zerop amount) consent-eof-object)
         (t
          (setf (consent--port-position port) (+ position amount))
          (consent-capability-audit-port-result port 'read amount)
          (consent--charge-string-allocation
           (substring source position (+ position amount))
           context))))))))

(defun consent--primitive-read-line (arguments context)
  "Primitive read-line over ARGUMENTS."
  (let ((port (consent--expect-textual-input-port
               (if arguments
                   (car arguments)
                 (consent--current-input-port-or-deny
                  context "read-line"))
               "read-line")))
      (unless (memq (consent--port-medium port)
                    '(string file process network))
        (consent--eval-error
         "read-line host textual input ports are not available"))
      (consent--port-capability-check port context 'read)
      (when (consent--program-input-streaming-p port)
        (consent--program-input-fill-until!
         port context
         (lambda ()
           (consent--program-input-line-buffered-p
            (consent--port-source port)
            (consent--port-position port)))))
      (let* ((source (consent--port-source port))
             (start (consent--port-position port))
             (length (length source))
             (position start))
        (while (and (< position length)
                    (not (memq (aref source position) '(?\n ?\r))))
          (setq position (1+ position)))
        (cond
         ((and (= start position) (>= position length))
          consent-eof-object)
         (t
          (let ((line (substring source start position)))
            (when (< position length)
              (if (and (= (aref source position) ?\r)
                       (< (1+ position) length)
                       (= (aref source (1+ position)) ?\n))
                  (setq position (+ position 2))
                (setq position (1+ position))))
            (setf (consent--port-position port) position)
            (consent-capability-audit-port-result
             port 'read (length line))
            (consent--charge-string-allocation line context)))))))

(defun consent--append-bytes-to-port
    (bytes port description &optional context)
  "Append BYTES to binary output PORT for DESCRIPTION."
  (let ((output (consent--expect-binary-output-port port description)))
    (unless (memq (consent--port-medium output) '(bytevector file))
      (consent--eval-error
       "%s host binary output ports are not available" description))
    (consent--port-capability-check output context 'write)
    ;; A streaming stdio binary port flushes each byte write through its host byte
    ;; writer immediately (so a single-form byte filter streams instead of
    ;; buffering to end of program), charged against the host-callback budget; an
    ;; ordinary in-memory port accumulates its bytes as before.
    (if (consent--program-binary-output-streaming-p output)
        (progn
          (when context
            (consent--note-host-callback
             context consent--program-binary-output-write-primitive))
          (funcall (consent--program-binary-output-writer-of output) bytes))
      (setf (consent--port-contents output)
            (append (consent--port-contents output) bytes)))
    (consent-capability-audit-port-result
     output 'write (length bytes)))
  consent-unspecified)

(defun consent--write-byte-to-port
    (byte port description &optional context)
  "Append BYTE to binary output PORT for DESCRIPTION."
  (consent--append-bytes-to-port
   (list byte) port description context))

(defun consent--primitive-read-u8 (arguments context)
  "Primitive read-u8 over ARGUMENTS."
  (if (null arguments)
      consent-eof-object
    (let ((port (consent--expect-binary-input-port
                 (car arguments) "read-u8")))
      (unless (memq (consent--port-medium port) '(bytevector file))
        (consent--eval-error
         "read-u8 host binary input ports are not available"))
      (consent--port-capability-check port context 'read)
      ;; A streaming stdio binary port refills bytes on demand: pull one chunk
      ;; when no byte is buffered, so a byte filter never drains the pipe up front.
      (when (consent--program-binary-input-streaming-p port)
        (consent--program-binary-input-fill-until!
         port context
         (lambda () (consent--program-binary-input-buffered>= port 1))))
      (let ((source (consent--port-source port))
            (position (consent--port-position port)))
        (if (>= position (length source))
            (prog1 consent-eof-object
              (consent-capability-audit-port-result port 'read 'eof))
          (setf (consent--port-position port) (1+ position))
          (consent-capability-audit-port-result port 'read 1)
          (consent--number-from-host (aref source position)))))))

(defun consent--primitive-peek-u8 (arguments context)
  "Primitive peek-u8 over ARGUMENTS."
  (if (null arguments)
      consent-eof-object
    (let ((port (consent--expect-binary-input-port
                 (car arguments) "peek-u8")))
      (unless (memq (consent--port-medium port) '(bytevector file))
        (consent--eval-error
         "peek-u8 host binary input ports are not available"))
      (consent--port-capability-check port context 'read)
      ;; Peeking refills like `read-u8' but does not advance the cursor.
      (when (consent--program-binary-input-streaming-p port)
        (consent--program-binary-input-fill-until!
         port context
         (lambda () (consent--program-binary-input-buffered>= port 1))))
      (let ((source (consent--port-source port))
            (position (consent--port-position port)))
        (if (>= position (length source))
            (prog1 consent-eof-object
              (consent-capability-audit-port-result port 'read 'eof))
          (consent-capability-audit-port-result port 'read 1)
          (consent--number-from-host (aref source position)))))))

(defun consent--primitive-u8-ready? (arguments _context)
  "Primitive u8-ready? over ARGUMENTS."
  (when arguments
    (consent--expect-binary-input-port (car arguments) "u8-ready?"))
  consent-true)

(defun consent--primitive-read-bytevector (arguments context)
  "Primitive read-bytevector over ARGUMENTS."
  (let* ((count (consent--exact-integer->host
                 (car arguments) "read-bytevector"))
         (port (if (cdr arguments)
                   (consent--expect-binary-input-port
                    (cadr arguments) "read-bytevector")
                 nil)))
    (when (< count 0)
      (consent--eval-error "read-bytevector count must be non-negative"))
    (cond
     ((null port)
      (if (zerop count)
          (consent--make-bytevector [])
        consent-eof-object))
     ((not (memq (consent--port-medium port) '(bytevector file)))
      (consent--eval-error
       "read-bytevector host binary input ports are not available"))
     (t
      (consent--port-capability-check port context 'read)
      ;; A streaming stdio binary port refills until COUNT bytes are buffered or
      ;; the stream ends, so a bounded read pulls only what it needs.
      (when (consent--program-binary-input-streaming-p port)
        (consent--program-binary-input-fill-until!
         port context
         (lambda () (consent--program-binary-input-buffered>= port count))))
      (let* ((source (consent--port-source port))
             (position (consent--port-position port))
             (remaining (- (length source) position))
             (amount (min count remaining)))
        (cond
         ((zerop count)
          (consent--make-bytevector []))
         ((zerop amount)
          consent-eof-object)
         (t
          (setf (consent--port-position port) (+ position amount))
          (consent-capability-audit-port-result port 'read amount)
          (consent--charge-bytevector-allocation
           (consent--make-bytevector
            (cl-subseq source position (+ position amount)))
           context))))))))

(defun consent--primitive-read-bytevector! (arguments context)
  "Primitive read-bytevector! over ARGUMENTS."
  (let* ((target (consent--expect-bytevector
                  (car arguments) "read-bytevector! target"))
         (port (if (cdr arguments)
                   (consent--expect-binary-input-port
                    (cadr arguments) "read-bytevector!")
                 nil))
         (bytes (consent-bytevector-bytes target))
         (start (if (nthcdr 2 arguments)
                    (consent--expect-nonnegative-index
                     (caddr arguments) (length bytes) "read-bytevector!" t)
                  0))
         (end (if (nthcdr 3 arguments)
                  (consent--expect-nonnegative-index
                   (cadddr arguments) (length bytes) "read-bytevector!" t)
                (length bytes))))
    (when (> start end)
      (consent--eval-error "read-bytevector! invalid range"))
    (if (null port)
        consent-eof-object
      (unless (memq (consent--port-medium port) '(bytevector file))
        (consent--eval-error
         "read-bytevector! host binary input ports are not available"))
      (consent--port-capability-check port context 'read)
      ;; A streaming stdio binary port refills until the target range can be
      ;; filled or the stream ends.
      (when (consent--program-binary-input-streaming-p port)
        (consent--program-binary-input-fill-until!
         port context
         (lambda ()
           (consent--program-binary-input-buffered>= port (- end start)))))
      (let* ((source (consent--port-source port))
             (position (consent--port-position port))
             (amount (min (- end start) (- (length source) position))))
        (if (zerop amount)
            consent-eof-object
          (dotimes (offset amount)
            (aset bytes (+ start offset) (aref source (+ position offset))))
          (setf (consent--port-position port) (+ position amount))
          (consent-capability-audit-port-result port 'read amount)
          (consent--number-from-host amount))))))

(defun consent--primitive-write-u8 (arguments context)
  "Primitive write-u8 over ARGUMENTS."
  (when (cdr arguments)
    (consent--write-byte-to-port
     (consent--expect-byte (car arguments) "write-u8")
     (cadr arguments)
     "write-u8"
     context))
  consent-unspecified)

(defun consent--primitive-write-bytevector (arguments context)
  "Primitive write-bytevector over ARGUMENTS."
  (when (cdr arguments)
    (let* ((bytevector (consent--expect-bytevector
                        (car arguments) "write-bytevector"))
           (bytes (consent-bytevector-bytes bytevector))
           (range (consent--optional-range
                   arguments 2 (length bytes) "write-bytevector"))
           (payload nil))
      (cl-loop for index from (car range) below (cdr range)
               do (push (aref bytes index) payload))
      (consent--append-bytes-to-port
       (nreverse payload)
       (cadr arguments)
       "write-bytevector"
       context)))
  consent-unspecified)

(defun consent--primitive-write-char (arguments context)
  "Primitive write-char over ARGUMENTS."
  (when (cdr arguments)
    (consent--write-text-to-port
     (char-to-string
      (consent--expect-character (car arguments) "write-char"))
     (cadr arguments)
     "write-char"
     context))
  consent-unspecified)

(defun consent--primitive-write-string (arguments context)
  "Primitive write-string over ARGUMENTS."
  (let* ((string (consent--expect-string
                  (car arguments) "write-string"))
         (port (if (cdr arguments)
                   (cadr arguments)
                 (consent--current-output-port-or-deny
                  context "write-string")))
         (range (consent--optional-range
                 arguments
                 (if (cdr arguments) 2 1)
                 (length string)
                 "write-string")))
    (consent--write-text-to-port
     (substring string (car range) (cdr range))
     port
     "write-string"
     context))
  consent-unspecified)

(defun consent--primitive-newline (arguments context)
  "Primitive newline over ARGUMENTS."
  (consent--write-text-to-port
   "\n"
   (if arguments
       (car arguments)
     (consent--current-output-port-or-deny context "newline"))
   "newline"
   context)
  consent-unspecified)

(defun consent--primitive-display (arguments context)
  "Primitive display over ARGUMENTS."
  (consent--write-to-output-port
   (car arguments)
   (consent--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (consent--current-output-port-or-deny context "display"))
    "display")
   'write
   t
   context))

(defun consent--primitive-write (arguments context)
  "Primitive write over ARGUMENTS."
  (consent--write-to-output-port
   (car arguments)
   (consent--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (consent--current-output-port-or-deny context "write"))
    "write")
   'write
   nil
   context))

(defun consent--primitive-write-shared (arguments context)
  "Primitive write-shared over ARGUMENTS."
  (consent--write-to-output-port
   (car arguments)
   (consent--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (consent--current-output-port-or-deny context "write-shared"))
    "write-shared")
   'shared
   nil
   context))

(defun consent--primitive-write-simple (arguments context)
  "Primitive write-simple over ARGUMENTS."
  (consent--write-to-output-port
   (car arguments)
   (consent--expect-textual-output-port
    (if (cdr arguments)
        (cadr arguments)
      (consent--current-output-port-or-deny context "write-simple"))
    "write-simple")
   'simple
   nil
   context))

(defun consent--primitive-flush-output-port (arguments context)
  "Primitive flush-output-port over ARGUMENTS."
  (when arguments
    (let ((port (consent--expect-output-port
                 (car arguments) "flush-output-port")))
      (consent--flush-file-output-port port context 'flush)))
  consent-unspecified)

(defun consent--primitive-read-error? (_arguments _context)
  "Primitive read-error?."
  (consent--scheme-boolean nil))

(defun consent--primitive-file-error? (_arguments _context)
  "Primitive file-error?."
  (consent--scheme-boolean nil))

(defun consent--primitive-features (_arguments _context)
  "Primitive features."
  (mapcar
   #'consent--syntax-symbol
   '("r7rs" "ratios" "exact-complex" "ieee-float" "consent")))

(defun consent--policy-denied (description &optional context)
  "Signal a default-denied host policy error for DESCRIPTION."
  (consent-policy-deny
   'standard-host-effect
   description
   nil
   context
   (format "%s requires policy-gated host access" description)))

(defun consent--interaction-session-symbol (session-id)
  "Return SESSION-ID as a Scheme-readable symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p session-id)
     (consent-symbol-name session-id))
    ((symbolp session-id)
     (symbol-name session-id))
    ((stringp session-id)
     session-id)
    (t
     (format "%S" session-id)))))

(defun consent--primitive-interaction-environment (_arguments context)
  "Primitive interaction-environment over _ARGUMENTS."
  (let ((session-id (and context
                         (consent--eval-context-session-id context)))
        (environment (and context
                          (consent--eval-context-interaction-environment
                           context)))
        (syntax-environment
         (and context
              (consent--eval-context-syntax-environment context))))
    (unless (and session-id environment syntax-environment)
      (consent-policy-deny
       'standard-host-effect
       "interaction-environment"
       nil
       context
       "interaction-environment requires an active session"))
    (consent-policy-authorize
     'standard-host-effect
     "interaction-environment"
     `((session . ,(consent--interaction-session-symbol session-id)))
     context)
    (consent--make-environment-specifier
     environment syntax-environment nil)))

(defun consent--time-inexact-number (value description)
  "Return VALUE as an inexact Consent Scheme number for DESCRIPTION."
  (unless (numberp value)
    (consent--eval-error
     "%s host adapter returned non-number: %S" description value))
  (consent--number-from-host (float value)))

(defun consent--time-exact-integer (value description)
  "Return VALUE as an exact Consent Scheme integer for DESCRIPTION."
  (unless (integerp value)
    (consent--eval-error
     "%s host adapter returned non-integer: %S" description value))
  (consent--number-from-host value))

(defun consent--time-positive-exact-integer (value description)
  "Return VALUE as a positive exact Consent Scheme integer for DESCRIPTION."
  (unless (and (integerp value) (> value 0))
    (consent--eval-error
     "%s host adapter returned non-positive integer: %S" description value))
  (consent--number-from-host value))

(defun consent--call-authorized-clock
    (binding context thunk)
  "Authorize clock BINDING, call THUNK, and audit the result."
  (let ((authorization
         (consent-capability-authorize-clock binding context)))
    (condition-case condition
        (let ((value (funcall thunk)))
          (consent-capability-audit-clock-result authorization value)
          value)
      (error
       (consent-capability-audit-clock-result
        authorization (error-message-string condition) t)
       (signal (car condition) (cdr condition))))))

(defun consent--primitive-current-second (_arguments context)
  "Primitive current-second over _ARGUMENTS."
  (consent--call-authorized-clock
   "current-second"
   context
   (lambda ()
     (consent--time-inexact-number
      (funcall consent-time-current-second-function)
      "current-second"))))

(defun consent--primitive-command-line (_arguments context)
  "Primitive command-line over _ARGUMENTS."
  (let ((script-command-line
         (and context (consent--eval-context-command-line context))))
    (if script-command-line
        (copy-sequence script-command-line)
      (consent-capability-authorize-process-environment
       "command-line" context)
      (copy-sequence command-line-args))))

(defun consent--primitive-get-environment-variable (arguments context)
  "Primitive get-environment-variable over ARGUMENTS."
  (consent-capability-authorize-process-environment
   "get-environment-variable" context)
  (let ((value (getenv (consent--expect-string
                        (car arguments) "get-environment-variable"))))
    (if value value consent-false)))

(defun consent--primitive-get-environment-variables (_arguments context)
  "Primitive get-environment-variables over _ARGUMENTS."
  (consent-capability-authorize-process-environment
   "get-environment-variables" context)
  (mapcar
   (lambda (entry)
     (if (string-match "=" entry)
         (cons (substring entry 0 (match-beginning 0))
               (substring entry (match-end 0)))
       (cons entry "")))
   process-environment))

(defun consent--primitive-current-jiffy (_arguments context)
  "Primitive current-jiffy over _ARGUMENTS."
  (consent--call-authorized-clock
   "current-jiffy"
   context
   (lambda ()
     (consent--time-exact-integer
      (funcall consent-time-current-jiffy-function)
      "current-jiffy"))))

(defun consent--primitive-jiffies-per-second (_arguments context)
  "Primitive jiffies-per-second over _ARGUMENTS."
  (consent--call-authorized-clock
   "jiffies-per-second"
   context
   (lambda ()
     (consent--time-positive-exact-integer
      (funcall consent-time-jiffies-per-second-function)
      "jiffies-per-second"))))

(defun consent--resolve-file-policy-path (filename context description)
  "Return a file authorization for FILENAME and DESCRIPTION."
  (consent-capability-authorize-file
   filename
   context
   (pcase description
     ("file-exists?" 'metadata)
     ("delete-file" 'delete)
     ("load" 'load)
     (_ 'read))
   description
   (consent--eval-context-file-paths context)))

(defun consent--read-file-port-source (authorization description filename)
  "Return file contents for AUTHORIZATION or signal for DESCRIPTION."
  (let ((path (plist-get authorization :path)))
    (consent-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (consent-capability-audit-file-result
       authorization
       (format "%s file is not readable" description)
       t)
      (consent--eval-error
       "%s file is not readable: %s" description filename))
    (prog1
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))
      (consent-capability-audit-file-result authorization 'opened))))

(defun consent--read-binary-file-port-source
    (authorization description filename)
  "Return file bytes for AUTHORIZATION or signal for DESCRIPTION."
  (let ((path (plist-get authorization :path)))
    (consent-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (consent-capability-audit-file-result
       authorization
       (format "%s file is not readable" description)
       t)
      (consent--eval-error
       "%s file is not readable: %s" description filename))
    (prog1
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally path)
          (let ((bytes (make-vector (buffer-size) 0)))
            (dotimes (index (buffer-size))
              (aset bytes index (char-after (1+ index))))
            bytes))
      (consent-capability-audit-file-result authorization 'opened))))

(defun consent--primitive-open-input-file (arguments context)
  "Primitive open-input-file over ARGUMENTS."
  (let* ((filename (consent--expect-string
                    (car arguments) "open-input-file"))
         (authorization
          (consent--resolve-file-policy-path
           filename context "open-input-file"))
         (source
          (consent--read-file-port-source
           authorization "open-input-file" filename))
         (port
          (consent--make-port
           :medium 'file
           :inputp t
           :textualp t
           :source source
           :position 0)))
    (consent-capability-register-file-port
     port 'textual-input authorization '(read close))))

(defun consent--primitive-open-binary-input-file (arguments context)
  "Primitive open-binary-input-file over ARGUMENTS."
  (let* ((filename (consent--expect-string
                    (car arguments) "open-binary-input-file"))
         (authorization
          (consent--resolve-file-policy-path
           filename context "open-binary-input-file"))
         (source
          (consent--read-binary-file-port-source
           authorization "open-binary-input-file" filename))
         (port
          (consent--make-port
           :medium 'file
           :inputp t
           :binaryp t
           :source source
           :position 0)))
    (consent-capability-register-file-port
     port 'binary-input authorization '(read close))))

(defun consent--resolve-output-file-policy-path
    (filename context description)
  "Return file authorization for output FILENAME and DESCRIPTION."
  (let* ((path (expand-file-name
                filename
                (consent--eval-context-include-directory context)))
         (operation (if (file-exists-p path) 'write 'create)))
    (consent-capability-authorize-file
     filename
     context
     operation
     description
     (consent--eval-context-file-paths context))))

(defun consent--primitive-open-output-file (arguments context)
  "Primitive open-output-file over ARGUMENTS."
  (let* ((filename (consent--expect-string
                    (car arguments) "open-output-file"))
         (authorization
          (consent--resolve-output-file-policy-path
           filename context "open-output-file"))
         (port
          (consent--make-port
           :medium 'file
           :outputp t
           :textualp t
           :contents "")))
    (consent-capability-revalidate-file-authorization authorization)
    (consent-capability-audit-file-result authorization 'opened)
    (consent-capability-register-file-port
     port 'textual-output authorization '(write flush close))))

(defun consent--primitive-open-binary-output-file (arguments context)
  "Primitive open-binary-output-file over ARGUMENTS."
  (let* ((filename (consent--expect-string
                    (car arguments) "open-binary-output-file"))
         (authorization
          (consent--resolve-output-file-policy-path
           filename context "open-binary-output-file"))
         (port
          (consent--make-port
           :medium 'file
           :outputp t
           :binaryp t
           :contents nil)))
    (consent-capability-revalidate-file-authorization authorization)
    (consent-capability-audit-file-result authorization 'opened)
    (consent-capability-register-file-port
     port 'binary-output authorization '(write flush close))))

(defun consent--primitive-file-exists? (arguments context)
  "Primitive file-exists? over ARGUMENTS."
  (let* ((filename (consent--expect-string
                    (car arguments) "file-exists?"))
         (path (consent--resolve-file-policy-path
                filename context "file-exists?"))
         (exists (progn
                   (consent-capability-revalidate-file-authorization
                    path)
                   (file-exists-p (plist-get path :path)))))
    (consent-capability-audit-file-result path exists)
    (consent--scheme-boolean exists)))

(defun consent--primitive-delete-file (arguments context)
  "Primitive delete-file over ARGUMENTS."
  (let* ((filename (consent--expect-string
                    (car arguments) "delete-file"))
         (authorization
          (consent--resolve-file-policy-path
           filename context "delete-file"))
         (path (plist-get authorization :path)))
    (condition-case condition
        (progn
          (consent-capability-revalidate-file-authorization
           authorization)
          (delete-file path)
          (consent-capability-audit-file-result
           authorization 'deleted)
          consent-unspecified)
      (file-error
       (consent-capability-audit-file-result
        authorization
        (error-message-string condition)
        t)
       (signal (car condition) (cdr condition))))))

(defun consent--primitive-call-with-port (arguments context)
  "Primitive call-with-port over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-call-with-port/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-call-with-port/k
    (arguments context continuation)
  "CPS primitive call-with-port over ARGUMENTS."
  (let ((port (consent--expect-port (car arguments) "call-with-port port"))
        (procedure (consent--expect-procedure
                    (cadr arguments) "call-with-port procedure")))
    (consent--apply-procedure
     procedure
     (list port)
     context
     t
     (lambda (value)
       (consent--close-port-value port context)
       (consent--continue continuation value)))))

(defun consent--primitive-call-with-input-file (arguments context)
  "Primitive call-with-input-file over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-call-with-input-file/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-call-with-input-file/k
    (arguments context continuation)
  "CPS primitive call-with-input-file over ARGUMENTS."
  (let ((port (consent--primitive-open-input-file
               (list (car arguments)) context))
        (procedure (consent--expect-procedure
                    (cadr arguments) "call-with-input-file procedure")))
    (consent--apply-procedure
     procedure
     (list port)
     context
     t
     (lambda (value)
       (consent--close-port-value port context)
       (consent--continue continuation value)))))

(defun consent--primitive-call-with-output-file (arguments context)
  "Primitive call-with-output-file over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-call-with-output-file/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-call-with-output-file/k
    (arguments context continuation)
  "CPS primitive call-with-output-file over ARGUMENTS."
  (let ((port (consent--primitive-open-output-file
               (list (car arguments)) context))
        (procedure (consent--expect-procedure
                    (cadr arguments) "call-with-output-file procedure")))
    (consent--apply-procedure
     procedure
     (list port)
     context
     t
     (lambda (value)
       (consent--close-port-value port context)
       (consent--continue continuation value)))))

(defun consent--primitive-with-input-from-file (arguments context)
  "Primitive with-input-from-file over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-with-input-from-file/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-with-input-from-file/k
    (arguments context continuation)
  "CPS primitive with-input-from-file over ARGUMENTS."
  (let ((port (consent--primitive-open-input-file
               (list (car arguments)) context))
        (procedure (consent--expect-procedure
                    (cadr arguments) "with-input-from-file thunk"))
        (previous (consent--eval-context-current-input-port context)))
    (setf (consent--eval-context-current-input-port context) port)
    (consent--apply-procedure
     procedure
     nil
     context
     t
     (lambda (value)
       (setf (consent--eval-context-current-input-port context) previous)
       (consent--close-port-value port context)
       (consent--continue continuation value)))))

(defun consent--primitive-with-output-to-file (arguments context)
  "Primitive with-output-to-file over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-with-output-to-file/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-with-output-to-file/k
    (arguments context continuation)
  "CPS primitive with-output-to-file over ARGUMENTS."
  (let ((port (consent--primitive-open-output-file
               (list (car arguments)) context))
        (procedure (consent--expect-procedure
                    (cadr arguments) "with-output-to-file thunk"))
        (previous (consent--eval-context-current-output-port context)))
    (setf (consent--eval-context-current-output-port context) port)
    (consent--apply-procedure
     procedure
     nil
     context
     t
     (lambda (value)
       (setf (consent--eval-context-current-output-port context) previous)
       (consent--close-port-value port context)
       (consent--continue continuation value)))))

(defun consent--primitive-environment (arguments context)
  "Primitive environment over ARGUMENTS."
  (let ((environment (consent-make-empty-environment))
        (syntax-environment (consent--make-empty-syntax-environment)))
    (consent--with-syntax-environment
     context
     syntax-environment
     (lambda ()
       (consent--eval-import
        (cons (consent--syntax-symbol "import") arguments)
        environment
        context)))
    (consent--make-environment-specifier
     environment syntax-environment t)))

(defun consent--expect-environment-specifier (value description)
  "Return VALUE as an environment specifier for DESCRIPTION."
  (unless (consent--environment-specifier-p value)
    (consent--eval-error "%s expected an environment specifier" description))
  value)

(defun consent--eval-form-mutates-environment-p (form)
  "Return non-nil if evaluating FORM can install top-level bindings."
  (or (consent--import-form-p form)
      (consent--define-library-form-p form)
      (consent--syntax-definition-form-p form)
      (consent--record-definition-form-p form)
      (consent--define-values-form-p form)
      (consent--definition-form-p form)))

(defun consent--primitive-eval (arguments context)
  "Primitive eval over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-eval/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-eval/k (arguments context continuation)
  "CPS primitive eval over ARGUMENTS."
  (let* ((expression (car arguments))
         (specifier (consent--expect-environment-specifier
                     (cadr arguments) "eval"))
         (environment
          (consent--environment-specifier-environment specifier))
         (syntax-environment
          (consent--environment-specifier-syntax-environment specifier)))
    (when (and (consent--environment-specifier-immutable specifier)
               (consent--eval-form-mutates-environment-p expression))
      (consent--eval-error
       "eval cannot mutate an immutable environment"))
    (consent--with-syntax-environment
     context
     syntax-environment
     (lambda ()
       (if (consent--eval-form-mutates-environment-p expression)
           (consent--eval-sequence
            (list expression) environment context t t continuation)
         (consent--eval-expression
          expression environment context t continuation))))))

(defun consent--read-policy-file-forms (filename context description)
  "Read FILENAME under CONTEXT file policy for DESCRIPTION.
Return (FORMS DIRECTORY AUTHORIZATION)."
  (let* ((authorization
          (consent--resolve-file-policy-path
           filename context description))
         (path (plist-get authorization :path)))
    (consent-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (consent-capability-audit-file-result
       authorization
       (format "%s file is not readable" description)
       t)
      (consent--eval-error
       "%s file is not readable: %s" description filename))
    (let ((source
           (with-temp-buffer
             (insert-file-contents path)
             (buffer-string))))
      (consent-capability-audit-file-result authorization 'read)
      (list (consent-read-all source)
            (file-name-directory path)
            authorization))))

(defun consent--load-target (arguments context)
  "Return (ENVIRONMENT . SYNTAX-ENVIRONMENT) for load ARGUMENTS."
  (if (cdr arguments)
      (let ((specifier (consent--expect-environment-specifier
                        (cadr arguments) "load")))
        (when (consent--environment-specifier-immutable specifier)
          (consent--eval-error
           "load cannot mutate an immutable environment"))
        (cons (consent--environment-specifier-environment specifier)
              (consent--environment-specifier-syntax-environment specifier)))
    (cons (or (consent--eval-context-interaction-environment context)
              (consent-make-base-environment))
          (consent--eval-context-syntax-environment context))))

(defun consent--primitive-load (arguments context)
  "Primitive load over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-load/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-load/k (arguments context continuation)
  "CPS primitive load over ARGUMENTS."
  (let* ((filename (consent--expect-string (car arguments) "load"))
         (read-result
          (consent--read-policy-file-forms filename context "load"))
         (target (consent--load-target arguments context))
         (code-loading
          (consent-capability-authorize-code-loading
           (caddr read-result) context "load")))
    (consent--with-include-directory
     context
     (cadr read-result)
     (lambda ()
       (consent--with-syntax-environment
        context
        (cdr target)
        (lambda ()
          (consent--eval-sequence
           (car read-result)
           (car target)
           context
           t
           t
           (lambda (_value)
             (consent-capability-audit-code-loading-result
              code-loading 'evaluated)
             (consent--continue
              continuation consent-unspecified)))))))))

(defun consent--primitive-string? (arguments _context)
  "Primitive string? over ARGUMENTS."
  (consent--scheme-boolean (stringp (car arguments))))

(defun consent--primitive-make-string (arguments context)
  "Primitive make-string over ARGUMENTS."
  (let* ((length (consent--exact-integer->host
                  (car arguments) "make-string"))
         (fill (if (cdr arguments)
                   (consent--expect-character
                    (cadr arguments) "make-string fill")
                 0)))
    (when (< length 0)
      (consent--eval-error "make-string length must be non-negative"))
    (consent--charge-string-allocation (make-string length fill) context)))

(defun consent--primitive-string (arguments context)
  "Primitive string over ARGUMENTS."
  (consent--charge-string-allocation
   (apply #'string
          (mapcar
           (lambda (argument)
             (consent--expect-character argument "string"))
           arguments))
   context))

(defun consent--primitive-string-length (arguments _context)
  "Primitive string-length over ARGUMENTS."
  (consent--number-from-host
   (length (consent--expect-string
            (car arguments) "string-length"))))

(defun consent--primitive-string-ref (arguments _context)
  "Primitive string-ref over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "string-ref"))
         (index (consent--expect-nonnegative-index
                 (cadr arguments) (length string) "string-ref")))
    (consent--make-character (aref string index))))

(defun consent--primitive-string-set! (arguments _context)
  "Primitive string-set! over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "string-set!"))
         (index (consent--expect-nonnegative-index
                 (cadr arguments) (length string) "string-set!"))
         (code (consent--expect-character
                (caddr arguments) "string-set! value")))
    (aset string index code)
    consent-unspecified))

(defun consent--primitive-substring (arguments context)
  "Primitive substring over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "substring"))
         (start (consent--expect-nonnegative-index
                 (cadr arguments) (length string) "substring" t))
         (end (consent--expect-nonnegative-index
               (caddr arguments) (length string) "substring" t)))
    (when (> start end)
      (consent--eval-error "substring start exceeds end"))
    (consent--charge-string-allocation (substring string start end) context)))

(defun consent--primitive-string-append (arguments context)
  "Primitive string-append over ARGUMENTS."
  (consent--charge-string-allocation
   (mapconcat
    #'identity
    (mapcar
     (lambda (argument)
       (consent--expect-string argument "string-append"))
     arguments)
    "")
   context))

(defun consent--primitive-string->list (arguments context)
  "Primitive string->list over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "string->list"))
         (range (consent--optional-range
                 arguments 1 (length string) "string->list"))
         result)
    (cl-loop for index from (car range) below (cdr range)
             do (push (consent--make-character (aref string index))
                      result))
    (consent--charge-list-allocation (nreverse result) context)))

(defun consent--primitive-list->string (arguments context)
  "Primitive list->string over ARGUMENTS."
  (consent--charge-string-allocation
   (apply #'string
          (mapcar
           (lambda (argument)
             (consent--expect-character argument "list->string"))
           (consent--proper-list-elements
            (car arguments) "list->string")))
   context))

(defun consent--primitive-string->utf8 (arguments context)
  "Primitive string->utf8 over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "string->utf8"))
         (range (consent--optional-range
                 arguments 1 (length string) "string->utf8"))
         (bytes (encode-coding-string
                 (substring string (car range) (cdr range))
                 'utf-8
                 t)))
    (consent--charge-bytevector-allocation
     (consent--make-bytevector
      (vconcat (mapcar #'identity bytes)))
     context)))

(defun consent--primitive-utf8->string (arguments context)
  "Primitive utf8->string over ARGUMENTS."
  (let* ((bytevector (consent--expect-bytevector
                      (car arguments) "utf8->string"))
         (bytes (consent-bytevector-bytes bytevector))
         (range (consent--optional-range
                 arguments 1 (length bytes) "utf8->string"))
         (raw (apply #'unibyte-string
                     (append
                      (cl-subseq bytes (car range) (cdr range))
                      nil))))
    (consent--charge-string-allocation
     (decode-coding-string raw 'utf-8 t) context)))

(defun consent--primitive-string->vector (arguments context)
  "Primitive string->vector over ARGUMENTS."
  (consent--charge-vector-allocation
   (vconcat (consent--primitive-string->list arguments context))
   context))

(defun consent--primitive-vector->string (arguments context)
  "Primitive vector->string over ARGUMENTS."
  (let* ((vector (consent--expect-vector (car arguments) "vector->string"))
         (range (consent--optional-range
                 arguments 1 (length vector) "vector->string"))
         codes)
    (cl-loop for index from (car range) below (cdr range)
             do (push (consent--expect-character
                       (aref vector index) "vector->string")
                      codes))
    (consent--charge-string-allocation
     (apply #'string (nreverse codes)) context)))

(defun consent--primitive-string-copy (arguments context)
  "Primitive string-copy over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "string-copy"))
         (range (consent--optional-range
                 arguments 1 (length string) "string-copy")))
    (consent--charge-string-allocation
     (substring string (car range) (cdr range)) context)))

(defun consent--primitive-string-copy! (arguments _context)
  "Primitive string-copy! over ARGUMENTS."
  (let* ((to (consent--expect-string (car arguments) "string-copy! target"))
         (at (consent--expect-nonnegative-index
              (cadr arguments) (length to) "string-copy!" t))
         (from (consent--expect-string
                (caddr arguments) "string-copy! source"))
         (range (consent--optional-range
                 arguments 3 (length from) "string-copy!"))
         (slice (substring from (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to))
      (consent--eval-error "string-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to (+ at index) (aref slice index)))
    consent-unspecified))

(defun consent--primitive-string-fill! (arguments _context)
  "Primitive string-fill! over ARGUMENTS."
  (let* ((string (consent--expect-string (car arguments) "string-fill!"))
         (fill (consent--expect-character
                (cadr arguments) "string-fill! value"))
         (range (consent--optional-range
                 arguments 2 (length string) "string-fill!")))
    (cl-loop for index from (car range) below (cdr range)
             do (aset string index fill))
    consent-unspecified))

(defun consent--primitive-string-compare (arguments predicate description)
  "Return Scheme boolean for pairwise string PREDICATE over ARGUMENTS."
  (let ((strings (mapcar
                  (lambda (argument)
                    (consent--expect-string argument description))
                  arguments))
        (ok t))
    (while (and ok (cdr strings))
      (setq ok (funcall predicate (car strings) (cadr strings)))
      (setq strings (cdr strings)))
    (consent--scheme-boolean ok)))

(defun consent--primitive-string=? (arguments _context)
  "Primitive string=? over ARGUMENTS."
  (consent--primitive-string-compare arguments #'string= "string=?"))

(defun consent--primitive-string<? (arguments _context)
  "Primitive string<? over ARGUMENTS."
  (consent--primitive-string-compare arguments #'string< "string<?"))

(defun consent--primitive-string>? (arguments _context)
  "Primitive string>? over ARGUMENTS."
  (consent--primitive-string-compare
   arguments (lambda (left right) (string< right left)) "string>?"))

(defun consent--primitive-string<=? (arguments _context)
  "Primitive string<=? over ARGUMENTS."
  (consent--primitive-string-compare
   arguments (lambda (left right) (not (string< right left))) "string<=?"))

(defun consent--primitive-string>=? (arguments _context)
  "Primitive string>=? over ARGUMENTS."
  (consent--primitive-string-compare
   arguments (lambda (left right) (not (string< left right))) "string>=?"))

(defun consent--primitive-string-upcase (arguments _context)
  "Primitive string-upcase over ARGUMENTS."
  (upcase (consent--expect-string (car arguments) "string-upcase")))

(defun consent--primitive-string-downcase (arguments _context)
  "Primitive string-downcase over ARGUMENTS."
  (downcase (consent--expect-string (car arguments) "string-downcase")))

(defun consent--primitive-string-foldcase (arguments _context)
  "Primitive string-foldcase over ARGUMENTS."
  (downcase (upcase (consent--expect-string
                     (car arguments) "string-foldcase"))))

(defun consent--primitive-string-ci-compare
    (arguments predicate description)
  "Return Scheme boolean for folded string PREDICATE over ARGUMENTS."
  (consent--primitive-string-compare
   (mapcar
    (lambda (argument)
      (downcase (upcase (consent--expect-string argument description))))
    arguments)
   predicate
   description))

(defun consent--primitive-string-ci=? (arguments _context)
  "Primitive string-ci=? over ARGUMENTS."
  (consent--primitive-string-ci-compare arguments #'string= "string-ci=?"))

(defun consent--primitive-string-ci<? (arguments _context)
  "Primitive string-ci<? over ARGUMENTS."
  (consent--primitive-string-ci-compare arguments #'string< "string-ci<?"))

(defun consent--primitive-string-ci>? (arguments _context)
  "Primitive string-ci>? over ARGUMENTS."
  (consent--primitive-string-ci-compare
   arguments (lambda (left right) (string< right left)) "string-ci>?"))

(defun consent--primitive-string-ci<=? (arguments _context)
  "Primitive string-ci<=? over ARGUMENTS."
  (consent--primitive-string-ci-compare
   arguments (lambda (left right) (not (string< right left))) "string-ci<=?"))

(defun consent--primitive-string-ci>=? (arguments _context)
  "Primitive string-ci>=? over ARGUMENTS."
  (consent--primitive-string-ci-compare
   arguments (lambda (left right) (not (string< left right))) "string-ci>=?"))

(defun consent--map-over-lists (procedure lists context keep-results)
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
        (consent--eval-error "map expected proper lists"))
       (t
        (let ((value (consent--apply-procedure
                      procedure
                      (mapcar #'car cursors)
                      context
                      nil)))
          (when keep-results
            (push (consent--single-value value "map result")
                  results)))
        (setq cursors (mapcar #'cdr cursors)))))
    (if keep-results
        (nreverse results)
      consent-unspecified)))

(defun consent--primitive-apply (arguments context)
  "Primitive apply over ARGUMENTS."
  (let* ((procedure (consent--expect-procedure
                     (car arguments) "apply procedure"))
         (fixed-arguments (butlast (cdr arguments)))
         (tail (car (last arguments)))
         (tail-arguments
          (consent--proper-list-elements tail "apply final argument")))
    (consent--apply-procedure
     procedure
     (append fixed-arguments tail-arguments)
     context
     nil)))

(defun consent--primitive-apply/k (arguments context continuation)
  "CPS primitive apply over ARGUMENTS."
  (let* ((procedure (consent--expect-procedure
                     (car arguments) "apply procedure"))
         (fixed-arguments (butlast (cdr arguments)))
         (tail (car (last arguments)))
         (tail-arguments
          (consent--proper-list-elements tail "apply final argument")))
    (consent--apply-procedure
     procedure
     (append fixed-arguments tail-arguments)
     context
     t
     continuation)))

(defun consent--primitive-values (arguments context)
  "Primitive values over ARGUMENTS."
  ;; One fresh multiple-values wrapper; the values it carries were charged where
  ;; they were allocated.
  (consent--charge-value-allocation
   (consent--make-multiple-values arguments) 1 context))

(defun consent--primitive-call-with-values (arguments context)
  "Primitive call-with-values over ARGUMENTS."
  (let* ((producer (consent--expect-procedure
                    (car arguments) "call-with-values producer"))
         (consumer (consent--expect-procedure
                    (cadr arguments) "call-with-values consumer"))
         (produced (consent--apply-procedure producer nil context nil)))
    (consent--apply-procedure
     consumer
     (consent--values-list produced)
     context
     nil)))

(defun consent--primitive-call-with-values/k
    (arguments context continuation)
  "CPS primitive call-with-values over ARGUMENTS."
  (let ((producer (consent--expect-procedure
                   (car arguments) "call-with-values producer"))
        (consumer (consent--expect-procedure
                   (cadr arguments) "call-with-values consumer")))
    (consent--apply-procedure
     producer
     nil
     context
     t
     (lambda (produced)
       (consent--apply-procedure
        consumer
        (consent--values-list produced)
        context
        t
        continuation)))))

(defun consent--primitive-call/cc (arguments context)
  "Primitive call-with-current-continuation over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-call/cc/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-call/cc/k (arguments context continuation)
  "CPS primitive call-with-current-continuation over ARGUMENTS."
  (let* ((procedure
          (consent--expect-procedure
           (car arguments)
           "call-with-current-continuation procedure"))
         (captured
          (consent--make-continuation
           continuation
           (copy-sequence
            (consent--eval-context-dynamic-winds context))
           (copy-sequence
            (consent--eval-context-exception-handlers context))
           (consent--eval-context-current-error context))))
    (consent--apply-procedure
     procedure
     (list captured)
     context
     t
     continuation)))

(defun consent--invoke-continuation
    (continuation arguments context)
  "Invoke captured CONTINUATION with ARGUMENTS in CONTEXT."
  (consent--switch-dynamic-winds
   (consent--continuation-dynamic-winds continuation)
   context)
  (setf (consent--eval-context-exception-handlers context)
        (copy-sequence
         (consent--continuation-exception-handlers continuation)))
  (setf (consent--eval-context-current-error context)
        (consent--continuation-current-error continuation))
  (consent--continue
   (consent--continuation-procedure continuation)
   (consent--continuation-value arguments)))

(defun consent--primitive-dynamic-wind (arguments context)
  "Primitive dynamic-wind over ARGUMENTS."
  (consent--drain-state
   (consent--primitive-dynamic-wind/k
    arguments context #'consent--identity-continuation)
   context))

(defun consent--primitive-dynamic-wind/k
    (arguments context continuation)
  "CPS primitive dynamic-wind over ARGUMENTS."
  (let* ((before (consent--expect-procedure
                  (car arguments) "dynamic-wind before"))
         (thunk (consent--expect-procedure
                 (cadr arguments) "dynamic-wind thunk"))
         (after (consent--expect-procedure
                 (caddr arguments) "dynamic-wind after"))
         (frame (consent--make-dynamic-wind-frame before after)))
    (consent--call-ignoring-values/k
     before
     context
     "dynamic-wind before"
     (lambda (_ignored)
       (push frame (consent--eval-context-dynamic-winds context))
       (consent--apply-procedure
        thunk
        nil
        context
        t
        (lambda (result)
          (when (eq (car (consent--eval-context-dynamic-winds context))
                    frame)
            (pop (consent--eval-context-dynamic-winds context)))
          (consent--call-ignoring-values/k
           after
           context
           "dynamic-wind after"
           (lambda (_after-result)
             (consent--continue continuation result)))))))))

(defun consent--current-exception-handler (context)
  "Return CONTEXT's current exception handler, or nil."
  (car (consent--eval-context-exception-handlers context)))

(defun consent--invoke-exception-handler (condition context)
  "Invoke the current exception handler for CONDITION."
  (let* ((handlers (consent--eval-context-exception-handlers context))
         (handler (car handlers))
         (old-error (consent--eval-context-current-error context)))
    (unless handler
      (consent--eval-error
       "unhandled exception: %s"
       (consent-value->external condition)))
    (unwind-protect
        (progn
          (setf (consent--eval-context-current-error context)
                (consent-debugger-exception-datum condition context))
          (setf (consent--eval-context-exception-handlers context)
                (cdr handlers))
          (consent--apply-procedure
           handler
           (list condition)
           context
           nil))
      (setf (consent--eval-context-exception-handlers context)
            handlers)
      (setf (consent--eval-context-current-error context)
            old-error))))

(defun consent--invoke-exception-handler/k
    (condition context continuation)
  "Invoke the current exception handler for CONDITION, then CONTINUATION."
  (let* ((handlers (consent--eval-context-exception-handlers context))
         (handler (car handlers))
         (old-error (consent--eval-context-current-error context)))
    (unless handler
      (consent--eval-error
       "unhandled exception: %s"
       (consent-value->external condition)))
    (setf (consent--eval-context-current-error context)
          (consent-debugger-exception-datum condition context))
    (setf (consent--eval-context-exception-handlers context)
          (cdr handlers))
    (consent--apply-procedure
     handler
     (list condition)
     context
     t
     (lambda (value)
       (setf (consent--eval-context-exception-handlers context)
             handlers)
       (setf (consent--eval-context-current-error context)
             old-error)
       (consent--continue continuation value)))))

(defun consent--primitive-with-exception-handler (arguments context)
  "Primitive with-exception-handler over ARGUMENTS."
  (let ((handler (consent--expect-procedure
                  (car arguments) "with-exception-handler handler"))
        (thunk (consent--expect-procedure
                (cadr arguments) "with-exception-handler thunk"))
        (old-handlers (consent--eval-context-exception-handlers context)))
    (unwind-protect
        (progn
          (setf (consent--eval-context-exception-handlers context)
                (cons handler old-handlers))
          (consent--apply-procedure thunk nil context nil))
      (setf (consent--eval-context-exception-handlers context)
            old-handlers))))

(defun consent--primitive-with-exception-handler/k
    (arguments context continuation)
  "CPS primitive with-exception-handler over ARGUMENTS."
  (let ((handler (consent--expect-procedure
                  (car arguments) "with-exception-handler handler"))
        (thunk (consent--expect-procedure
                (cadr arguments) "with-exception-handler thunk"))
        (old-handlers (consent--eval-context-exception-handlers context)))
    (setf (consent--eval-context-exception-handlers context)
          (cons handler old-handlers))
    (consent--apply-procedure
     thunk
     nil
     context
     t
     (lambda (value)
       (setf (consent--eval-context-exception-handlers context)
             old-handlers)
       (consent--continue continuation value)))))

(defun consent--primitive-raise-continuable (arguments context)
  "Primitive raise-continuable over ARGUMENTS."
  (consent--invoke-exception-handler (car arguments) context))

(defun consent--primitive-raise-continuable/k
    (arguments context continuation)
  "CPS primitive raise-continuable over ARGUMENTS."
  (consent--invoke-exception-handler/k
   (car arguments) context continuation))

(defun consent--primitive-raise (arguments context)
  "Primitive raise over ARGUMENTS."
  (consent--invoke-exception-handler (car arguments) context)
  (consent--eval-error "non-continuable exception handler returned"))

(defun consent--primitive-raise/k (arguments context _continuation)
  "CPS primitive raise over ARGUMENTS."
  (consent--invoke-exception-handler/k
   (car arguments)
   context
   (lambda (_value)
     (consent--eval-error
      "non-continuable exception handler returned"))))

(defun consent--primitive-error (arguments context)
  "Primitive error over ARGUMENTS."
  (let ((message (consent--expect-string (car arguments) "error message"))
        (irritants (cdr arguments)))
    (consent--primitive-raise
     (list (consent--make-error-object message irritants))
     context)))

(defun consent--primitive-error/k (arguments context continuation)
  "CPS primitive error over ARGUMENTS."
  (let ((message (consent--expect-string (car arguments) "error message"))
        (irritants (cdr arguments)))
    (consent--primitive-raise/k
     (list (consent--make-error-object message irritants))
     context
     continuation)))

(defun consent--primitive-error-object? (arguments _context)
  "Primitive error-object? over ARGUMENTS."
  (consent--scheme-boolean
   (consent-error-object-p (car arguments))))

(defun consent--expect-error-object (value description)
  "Return VALUE as an error object for DESCRIPTION."
  (unless (consent-error-object-p value)
    (consent--eval-error
     "%s expected an error object, got %s"
     description
     (consent-value->external value)))
  value)

(defun consent--primitive-error-object-message (arguments _context)
  "Primitive error-object-message over ARGUMENTS."
  (consent-error-object-message
   (consent--expect-error-object
    (car arguments) "error-object-message")))

(defun consent--primitive-error-object-irritants (arguments _context)
  "Primitive error-object-irritants over ARGUMENTS."
  (copy-sequence
   (consent-error-object-irritants
    (consent--expect-error-object
     (car arguments) "error-object-irritants"))))

(defun consent--primitive-map (arguments context)
  "Primitive map over ARGUMENTS."
  (consent--map-over-lists
   (consent--expect-procedure (car arguments) "map procedure")
   (cdr arguments)
   context
   t))

(defun consent--primitive-for-each (arguments context)
  "Primitive for-each over ARGUMENTS."
  (consent--map-over-lists
   (consent--expect-procedure (car arguments) "for-each procedure")
   (cdr arguments)
   context
   nil))

(defun consent--primitive-vector? (arguments _context)
  "Primitive vector? over ARGUMENTS."
  (consent--scheme-boolean (vectorp (car arguments))))

(defun consent--primitive-make-vector (arguments context)
  "Primitive make-vector over ARGUMENTS."
  (let* ((length (consent--exact-integer->host
                  (car arguments) "make-vector"))
         (fill (if (cdr arguments) (cadr arguments) consent-unspecified)))
    (when (< length 0)
      (consent--eval-error "make-vector length must be non-negative"))
    (consent--charge-vector-allocation (make-vector length fill) context)))

(defun consent--primitive-vector (arguments context)
  "Primitive vector over ARGUMENTS."
  (consent--charge-vector-allocation (vconcat arguments) context))

(defun consent--primitive-vector-length (arguments _context)
  "Primitive vector-length over ARGUMENTS."
  (consent--number-from-host
   (length (consent--expect-vector
            (car arguments) "vector-length"))))

(defun consent--primitive-vector-ref (arguments _context)
  "Primitive vector-ref over ARGUMENTS."
  (let* ((vector (consent--expect-vector (car arguments) "vector-ref"))
         (index (consent--expect-nonnegative-index
                 (cadr arguments) (length vector) "vector-ref")))
    (aref vector index)))

(defun consent--primitive-vector-set! (arguments _context)
  "Primitive vector-set! over ARGUMENTS."
  (let* ((vector (consent--expect-vector (car arguments) "vector-set!"))
         (index (consent--expect-nonnegative-index
                 (cadr arguments) (length vector) "vector-set!")))
    (aset vector index (caddr arguments))
    consent-unspecified))

(defun consent--primitive-vector->list (arguments context)
  "Primitive vector->list over ARGUMENTS."
  (let* ((vector (consent--expect-vector (car arguments) "vector->list"))
         (range (consent--optional-range
                 arguments 1 (length vector) "vector->list"))
         result)
    (cl-loop for index from (car range) below (cdr range)
             do (push (aref vector index) result))
    (consent--charge-list-allocation (nreverse result) context)))

(defun consent--primitive-list->vector (arguments context)
  "Primitive list->vector over ARGUMENTS."
  (consent--charge-vector-allocation
   (vconcat (consent--proper-list-elements
             (car arguments) "list->vector"))
   context))

(defun consent--primitive-vector-copy (arguments context)
  "Primitive vector-copy over ARGUMENTS."
  (let* ((vector (consent--expect-vector (car arguments) "vector-copy"))
         (range (consent--optional-range
                 arguments 1 (length vector) "vector-copy")))
    (consent--charge-vector-allocation
     (cl-subseq vector (car range) (cdr range)) context)))

(defun consent--primitive-vector-copy! (arguments _context)
  "Primitive vector-copy! over ARGUMENTS."
  (let* ((to (consent--expect-vector (car arguments) "vector-copy! target"))
         (at (consent--expect-nonnegative-index
              (cadr arguments) (length to) "vector-copy!" t))
         (from (consent--expect-vector
                (caddr arguments) "vector-copy! source"))
         (range (consent--optional-range
                 arguments 3 (length from) "vector-copy!"))
         (slice (cl-subseq from (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to))
      (consent--eval-error "vector-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to (+ at index) (aref slice index)))
    consent-unspecified))

(defun consent--primitive-vector-append (arguments context)
  "Primitive vector-append over ARGUMENTS."
  (consent--charge-vector-allocation
   (apply #'vconcat
          (mapcar
           (lambda (argument)
             (consent--expect-vector argument "vector-append"))
           arguments))
   context))

(defun consent--primitive-vector-fill! (arguments _context)
  "Primitive vector-fill! over ARGUMENTS."
  (let* ((vector (consent--expect-vector (car arguments) "vector-fill!"))
         (fill (cadr arguments))
         (range (consent--optional-range
                 arguments 2 (length vector) "vector-fill!")))
    (cl-loop for index from (car range) below (cdr range)
             do (aset vector index fill))
    consent-unspecified))

(defun consent--primitive-bytevector? (arguments _context)
  "Primitive bytevector? over ARGUMENTS."
  (consent--scheme-boolean
   (consent-bytevector-p (car arguments))))

(defun consent--primitive-make-bytevector (arguments context)
  "Primitive make-bytevector over ARGUMENTS."
  (let* ((length (consent--exact-integer->host
                  (car arguments) "make-bytevector"))
         (fill (if (cdr arguments)
                   (consent--expect-byte
                    (cadr arguments) "make-bytevector fill")
                 0)))
    (when (< length 0)
      (consent--eval-error "make-bytevector length must be non-negative"))
    (consent--charge-bytevector-allocation
     (consent--make-bytevector (make-vector length fill)) context)))

(defun consent--primitive-bytevector (arguments context)
  "Primitive bytevector over ARGUMENTS."
  (consent--charge-bytevector-allocation
   (consent--make-bytevector
    (vconcat
     (mapcar
      (lambda (argument)
        (consent--expect-byte argument "bytevector"))
      arguments)))
   context))

(defun consent--primitive-bytevector-length (arguments _context)
  "Primitive bytevector-length over ARGUMENTS."
  (consent--number-from-host
   (length
    (consent-bytevector-bytes
     (consent--expect-bytevector
      (car arguments) "bytevector-length")))))

(defun consent--primitive-bytevector-u8-ref (arguments _context)
  "Primitive bytevector-u8-ref over ARGUMENTS."
  (let* ((bytevector (consent--expect-bytevector
                      (car arguments) "bytevector-u8-ref"))
         (bytes (consent-bytevector-bytes bytevector))
         (index (consent--expect-nonnegative-index
                 (cadr arguments) (length bytes) "bytevector-u8-ref")))
    (consent--number-from-host (aref bytes index))))

(defun consent--primitive-bytevector-u8-set! (arguments _context)
  "Primitive bytevector-u8-set! over ARGUMENTS."
  (let* ((bytevector (consent--expect-bytevector
                      (car arguments) "bytevector-u8-set!"))
         (bytes (consent-bytevector-bytes bytevector))
         (index (consent--expect-nonnegative-index
                 (cadr arguments) (length bytes) "bytevector-u8-set!")))
    (aset bytes index
          (consent--expect-byte
           (caddr arguments) "bytevector-u8-set! value"))
    consent-unspecified))

(defun consent--primitive-bytevector-copy (arguments context)
  "Primitive bytevector-copy over ARGUMENTS."
  (let* ((bytevector (consent--expect-bytevector
                      (car arguments) "bytevector-copy"))
         (bytes (consent-bytevector-bytes bytevector))
         (range (consent--optional-range
                 arguments 1 (length bytes) "bytevector-copy")))
    (consent--charge-bytevector-allocation
     (consent--make-bytevector
      (cl-subseq bytes (car range) (cdr range)))
     context)))

(defun consent--primitive-bytevector-copy! (arguments _context)
  "Primitive bytevector-copy! over ARGUMENTS."
  (let* ((to (consent--expect-bytevector
              (car arguments) "bytevector-copy! target"))
         (to-bytes (consent-bytevector-bytes to))
         (at (consent--expect-nonnegative-index
              (cadr arguments) (length to-bytes) "bytevector-copy!" t))
         (from (consent--expect-bytevector
                (caddr arguments) "bytevector-copy! source"))
         (from-bytes (consent-bytevector-bytes from))
         (range (consent--optional-range
                 arguments 3 (length from-bytes) "bytevector-copy!"))
         (slice (cl-subseq from-bytes (car range) (cdr range))))
    (when (> (+ at (length slice)) (length to-bytes))
      (consent--eval-error "bytevector-copy! target range exceeds length"))
    (cl-loop for index from 0 below (length slice)
             do (aset to-bytes (+ at index) (aref slice index)))
    consent-unspecified))

(defun consent--primitive-bytevector-append (arguments context)
  "Primitive bytevector-append over ARGUMENTS."
  (consent--charge-bytevector-allocation
   (consent--make-bytevector
    (apply #'vconcat
           (mapcar
            (lambda (argument)
              (consent-bytevector-bytes
               (consent--expect-bytevector argument "bytevector-append")))
            arguments)))
   context))


(defun consent--result-field (name &rest values)
  "Return a Scheme-readable result field named NAME with VALUES."
  (cons (consent--syntax-symbol name) values))

(defun consent--result-symbol (name)
  "Return a Scheme symbol for result NAME."
  (consent--syntax-symbol name))

(defun consent--value->result-datum (value &optional seen)
  "Return VALUE encoded as a Scheme-readable result datum.
Opaque runtime values are represented by tagged data rather than host
objects so result records can be rendered by `consent-datum->external'."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((or (null value)
          (eq value consent-true)
          (eq value consent-false)
          (consent-symbol-p value)
          (consent-character-p value)
          (consent-number-p value)
          (stringp value)
          (consent-bytevector-p value))
      value)
     ((consent--identifier-p value)
      (consent--syntax-symbol
       (consent--identifier-name value)))
     ((consent-unspecified-p value)
      (list (consent--result-symbol "unspecified")))
     ((consent-primitive-procedure-p value)
      (list (consent--result-symbol "procedure")
            (consent--result-field "kind"
                                        (consent--result-symbol "primitive"))
            (consent--result-field
             "name"
             (consent--syntax-symbol
              (consent-primitive-procedure-name value)))))
     ((consent-procedure-p value)
      (list (consent--result-symbol "procedure")
            (consent--result-field "kind"
                                        (consent--result-symbol "compound"))))
     ((consent--continuation-p value)
      (list (consent--result-symbol "procedure")
            (consent--result-field "kind"
                                        (consent--result-symbol "continuation"))))
     ((consent-error-object-p value)
      (list (consent--result-symbol "error-object")
            (consent--result-field
             "message"
             (consent-error-object-message value))
            (consent--result-field
             "irritants"
             (mapcar (lambda (irritant)
                       (consent--value->result-datum irritant seen))
                     (consent-error-object-irritants value)))))
     ((consent-eof-object-p value)
      (list (consent--result-symbol "eof-object")))
     ((consent--port-p value)
      (list (consent--result-symbol "port")
            (consent--result-field
             "medium"
             (consent--result-symbol
              (symbol-name (consent--port-medium value))))
            (consent--result-field
             "open"
             (consent--scheme-boolean
              (consent--port-openp value)))))
     ((consent--environment-specifier-p value)
      (list (consent--result-symbol "environment")))
     ((consent-record-type-p value)
      (list (consent--result-symbol "record-type")
            (consent--result-field
             "name"
             (consent--syntax-symbol
              (consent-record-type-name value)))))
     ((consent-record-p value)
      (list (consent--result-symbol "record")
            (consent--result-field
             "type"
             (consent--syntax-symbol
              (consent-record-type-name
               (consent-record-type value))))))
     ((consp value)
      (if (gethash value seen)
          (list (consent--result-symbol "cycle"))
        (puthash value t seen)
        (cons (consent--value->result-datum (car value) seen)
              (consent--value->result-datum (cdr value) seen))))
     ((vectorp value)
      (if (gethash value seen)
          (vector (consent--result-symbol "cycle"))
        (puthash value t seen)
        (vconcat
         (mapcar
          (lambda (item)
            (consent--value->result-datum item seen))
          (append value nil)))))
     (t
      (list (consent--result-symbol "host-object")
            (consent--result-field "printed" (format "%S" value)))))))

(defun consent--budget-result-field (context)
  "Return the budget field for CONTEXT."
  (consent--result-field
   "budget"
   (consent--result-field
    "steps-used"
    (consent--number-from-host
     (consent--eval-context-steps context)))
   (consent--result-field
    "host-calls"
    (consent--number-from-host
     (consent--eval-context-host-callbacks context)))))

(defun consent--ok-result-datum (value context)
  "Return a stable Scheme-readable successful evaluation result."
  (if (consent--multiple-values-p value)
      (list (consent--result-symbol "evaluation-result")
            (consent--result-field
             "status"
             (consent--result-symbol "values"))
            (consent--result-field
             "values"
             (mapcar #'consent--value->result-datum
                     (consent--multiple-values-values value)))
            (consent--result-field
             "events"
             (consent--context-events context))
            (consent--budget-result-field context))
    (list (consent--result-symbol "evaluation-result")
          (consent--result-field "status"
                                      (consent--result-symbol "ok"))
          (consent--result-field
           "value"
           (consent--value->result-datum value))
          (consent--result-field
           "events"
           (consent--context-events context))
          (consent--budget-result-field context))))

(defun consent--condition-result-datum (condition context)
  "Return a stable Scheme-readable error result for CONDITION.
The `host-condition' field is the host-neutral `error' tag both twins emit: a
host condition object is not portable across Scheme implementations, so the
structured `type' and `reason' inside the condition -- not the host condition
symbol -- carry the classification."
  (let ((debugger-condition
         (consent-debugger-condition-datum condition context)))
    (setf (consent--eval-context-current-error context)
          debugger-condition)
    (list (consent--result-symbol "evaluation-result")
          (consent--result-field "status"
                                      (consent--result-symbol "error"))
          (consent--result-field
           "error"
           (consent--result-field
            "condition"
            debugger-condition)
           (consent--result-field
            "host-condition"
            (consent--syntax-symbol "error"))
           (consent--result-field
            "message"
            (consent--condition-message condition)))
          (consent--result-field
           "events"
           (consent--context-events context))
          (consent--budget-result-field context))))


(provide 'consent-interpreter)

;;; consent-interpreter.el ends here
