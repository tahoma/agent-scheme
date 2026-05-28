;;; agent-scheme-macro.el --- R7RS syntax-rules expansion  -*- lexical-binding: t; -*-

;;; Commentary:

;; Syntax environments, `syntax-rules' transformers, hygienic template
;; expansion, and recursive macro-expansion entry points.  This module is
;; loadable without the interpreter backend when callers provide their own
;; environments.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-base)
(require 'agent-scheme-library)
(require 'agent-scheme-debugger)

(cl-defstruct (agent-scheme--syntax-transformer
               (:constructor agent-scheme--make-syntax-transformer
                             (ellipsis literals rules value-environment
                                       syntax-environment))
               (:copier nil))
  "A parsed high-level `syntax-rules' transformer."
  ellipsis literals rules value-environment syntax-environment)

(cl-defstruct (agent-scheme--pattern-binding
               (:constructor agent-scheme--make-pattern-binding
                             (depth captures))
               (:copier nil))
  "Nested pattern-variable captures for one macro expansion.
DEPTH is the ellipsis nesting level where the variable is bound.
CAPTURES maps index paths such as (0 2) to matched datums, and
EMPTY-PREFIXES records zero-length repetitions for template
validation."
  depth captures empty-prefixes)

(cl-defstruct (agent-scheme--syntax-scope
               (:constructor agent-scheme--make-syntax-scope
                             (forms syntax-environment))
               (:copier nil))
  "Body forms evaluated under a local syntactic environment."
  forms syntax-environment)

(defun agent-scheme--definition-form-p (form)
  "Return non-nil if FORM is a supported definition form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "define")))

(defun agent-scheme--define-values-form-p (form)
  "Return non-nil if FORM is a supported define-values form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "define-values")))

(defun agent-scheme--begin-form-p (form)
  "Return non-nil if FORM is a begin form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "begin")))

(defun agent-scheme--record-definition-form-p (form)
  "Return non-nil if FORM is a supported define-record-type form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "define-record-type")))

(defun agent-scheme--tagged-list-p (datum tag)
  "Return non-nil if DATUM is a list whose first identifier names TAG."
  (and (consp datum)
       (agent-scheme--symbol-named-p (car datum) tag)))

(defun agent-scheme--single-argument-syntax (form description)
  "Return FORM's single operand or signal an error for DESCRIPTION."
  (let ((parts (agent-scheme--proper-list-elements form description)))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error "%s requires exactly one operand" description))
    (cadr parts)))

(defun agent-scheme--syntax-error-form-p (form)
  "Return non-nil if FORM is a syntax-error form."
  (agent-scheme--tagged-list-p form "syntax-error"))

(defun agent-scheme--syntax-error-message (form)
  "Return the user-facing message for syntax-error FORM."
  (let ((parts (agent-scheme--proper-list-elements form "syntax-error form")))
    (mapconcat #'agent-scheme-value->external (cdr parts) " ")))

(defun agent-scheme--raise-syntax-error (form &optional source-form)
  "Signal a syntax-error FORM, optionally attributed to SOURCE-FORM."
  (let ((message (agent-scheme--syntax-error-message form)))
    (if source-form
        (agent-scheme--eval-error
         "syntax-error while expanding %s: %s"
         (agent-scheme-value->external source-form)
         message)
      (agent-scheme--eval-error "syntax-error: %s" message))))

(defun agent-scheme--make-empty-syntax-environment (&optional parent)
  "Return a fresh empty syntactic environment with optional PARENT."
  (agent-scheme--make-syntax-environment
   (make-hash-table :test #'equal)
   parent
   (make-hash-table :test #'equal)))

(defun agent-scheme--syntax-environment-ref (syntax-environment name)
  "Return syntactic binding NAME in SYNTAX-ENVIRONMENT, or nil."
  (let ((cursor syntax-environment)
        transformer)
    (while (and cursor (not transformer))
      (let ((candidate
             (gethash name
                      (agent-scheme--syntax-environment-bindings cursor)
                      agent-scheme--missing-cell)))
        (unless (eq candidate agent-scheme--missing-cell)
          (setq transformer candidate)))
      (setq cursor (agent-scheme--syntax-environment-parent cursor)))
    transformer))

(defun agent-scheme--syntax-environment-define
    (syntax-environment name transformer)
  "Bind syntactic NAME to TRANSFORMER in SYNTAX-ENVIRONMENT."
  (when (gethash
         name
         (agent-scheme--syntax-environment-imported-bindings
          syntax-environment))
    (agent-scheme--eval-error
     "cannot redefine imported syntax binding: %s" name))
  (puthash name transformer
           (agent-scheme--syntax-environment-bindings syntax-environment)))

(defun agent-scheme--with-syntax-environment
    (context syntax-environment thunk)
  "Call THUNK with CONTEXT using SYNTAX-ENVIRONMENT."
  (let ((old-syntax-environment
         (agent-scheme--eval-context-syntax-environment context)))
    (unwind-protect
        (progn
          (setf (agent-scheme--eval-context-syntax-environment context)
                syntax-environment)
          (funcall thunk))
      (setf (agent-scheme--eval-context-syntax-environment context)
            old-syntax-environment))))

(defun agent-scheme--operator-shadowed-p (operator environment)
  "Return non-nil when OPERATOR is shadowed by a variable binding."
  (and (agent-scheme-symbol-p operator)
       (agent-scheme--environment-cell
        environment (agent-scheme-symbol-name operator))))

(defun agent-scheme--special-operator-active-p (operator environment)
  "Return non-nil if OPERATOR names an active core syntactic keyword."
  (and (agent-scheme--identifier-datum-p operator)
       (or (agent-scheme--identifier-p operator)
           (not (agent-scheme--operator-shadowed-p operator environment)))))

(defun agent-scheme--syntax-binding-for-operator
    (operator environment context)
  "Return macro transformer for OPERATOR in CONTEXT, or nil.
Identifier operators introduced by macros first consult their
definition-time syntax environment.  Plain symbols use the active
syntax environment unless a value binding shadows the syntactic
keyword."
  (let ((name (agent-scheme--symbol-name operator)))
    (when (and name
               (not (agent-scheme--operator-shadowed-p operator environment)))
      (or
       (and (agent-scheme--identifier-p operator)
            (let* ((identifier-context
                    (agent-scheme--identifier-context operator))
                   (definition-syntax-environment
                    (and identifier-context
                         (agent-scheme--syntax-context-syntax-environment
                          identifier-context))))
              (and definition-syntax-environment
                   (agent-scheme--syntax-environment-ref
                    definition-syntax-environment name))))
       (agent-scheme--syntax-environment-ref
        (agent-scheme--eval-context-syntax-environment context)
        name)))))

(defun agent-scheme--ellipsis-identifier-p (datum ellipsis)
  "Return non-nil if DATUM is the active ELLIPSIS identifier."
  (and (agent-scheme--identifier-datum-p datum)
       (equal (agent-scheme--symbol-name datum) ellipsis)))

(defun agent-scheme--syntax-rules-spec-p (form)
  "Return non-nil if FORM is a `syntax-rules' transformer spec."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "syntax-rules")))

(defun agent-scheme--parse-syntax-rule (rule)
  "Return RULE as a parsed (PATTERN . TEMPLATE) pair."
  (let ((parts (agent-scheme--proper-list-elements
                rule "syntax-rules rule")))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "syntax-rules rule must contain a pattern and a template"))
    (let ((pattern (car parts)))
      (unless (and (consp pattern)
                   (agent-scheme--identifier-datum-p (car pattern)))
        (agent-scheme--eval-error
         "syntax-rules pattern must be a list beginning with an identifier"))
      (cons pattern (cadr parts)))))

(defun agent-scheme--parse-syntax-rules
    (form value-environment syntax-environment)
  "Parse FORM as a high-level `syntax-rules' transformer."
  (unless (agent-scheme--syntax-rules-spec-p form)
    (agent-scheme--eval-error
     "transformer spec must be a syntax-rules form"))
  (let* ((parts (agent-scheme--proper-list-elements
                 form "syntax-rules form"))
         (tail (cdr parts))
         (ellipsis "...")
         literal-form
         rule-forms)
    (unless (>= (length tail) 2)
      (agent-scheme--eval-error
       "syntax-rules requires literals and at least one rule"))
    (if (and (agent-scheme--identifier-datum-p (car tail))
             (consp (cdr tail)))
        (progn
          (setq ellipsis
                (agent-scheme--expect-symbol-name
                 (car tail) "syntax-rules ellipsis"))
          (setq literal-form (cadr tail))
          (setq rule-forms (cddr tail)))
      (setq literal-form (car tail))
      (setq rule-forms (cdr tail)))
    (let ((literals
           (mapcar
            (lambda (literal)
              (unless (agent-scheme--identifier-datum-p literal)
                (agent-scheme--eval-error
                 "syntax-rules literal must be an identifier"))
              literal)
            (agent-scheme--proper-list-elements
             literal-form "syntax-rules literal list"))))
      (agent-scheme--make-syntax-transformer
       ellipsis
       literals
       (mapcar #'agent-scheme--parse-syntax-rule rule-forms)
       value-environment
       syntax-environment))))

(defun agent-scheme--syntax-literal-p (identifier literals)
  "Return non-nil if IDENTIFIER is one of LITERALS."
  (member (agent-scheme--symbol-name identifier)
          (mapcar #'agent-scheme--symbol-name literals)))

(defun agent-scheme--path-prefix-p (prefix path)
  "Return non-nil when PREFIX is an initial segment of PATH."
  (and (<= (length prefix) (length path))
       (cl-loop for left in prefix
                for right in path
                always (= left right))))

(defun agent-scheme--ensure-pattern-binding (bindings name depth)
  "Return pattern binding NAME in BINDINGS, creating it at DEPTH."
  (let ((entry (gethash name bindings)))
    (cond
     ((null entry)
      (setq entry
            (agent-scheme--make-pattern-binding
             depth
             (make-hash-table :test #'equal)))
      (puthash name entry bindings))
     ((and (> (hash-table-count
               (agent-scheme--pattern-binding-captures entry))
              0)
           (/= (agent-scheme--pattern-binding-depth entry) depth))
      (agent-scheme--eval-error
       "pattern variable used at inconsistent ellipsis depth: %s"
       name))
     ((< (agent-scheme--pattern-binding-depth entry) depth)
      (setf (agent-scheme--pattern-binding-depth entry) depth)))
    entry))

(defun agent-scheme--syntax-bind-pattern-variable
    (bindings name value path)
  "Bind pattern variable NAME to VALUE at nested ellipsis PATH."
  (let* ((depth (length path))
         (entry (agent-scheme--ensure-pattern-binding bindings name depth))
         (captures (agent-scheme--pattern-binding-captures entry)))
    (unless (eq (gethash path captures agent-scheme--missing-cell)
                agent-scheme--missing-cell)
      (agent-scheme--eval-error
       "duplicate pattern variable: %s" name))
    ;; PATH is the sequence of repetition indexes leading to this capture.
    ;; Template expansion uses the same path to distribute nested ellipses.
    (puthash path value captures))
  t)

(defun agent-scheme--pattern-variable-names (pattern literals ellipsis)
  "Return pattern variable names contained in PATTERN."
  (cond
   ((agent-scheme--identifier-datum-p pattern)
    (let ((name (agent-scheme--symbol-name pattern)))
      (unless (or (equal name "_")
                  (equal name ellipsis)
                  (member name (mapcar #'agent-scheme--symbol-name
                                       literals)))
        (list name))))
   ((consp pattern)
    (let ((elements (agent-scheme--proper-list-elements-maybe pattern)))
      (when elements
        (apply #'append
               (mapcar
                (lambda (element)
                  (agent-scheme--pattern-variable-names
                   element literals ellipsis))
                elements)))))
   ((vectorp pattern)
    (apply #'append
           (mapcar
            (lambda (element)
              (agent-scheme--pattern-variable-names
               element literals ellipsis))
            (append pattern nil))))
   (t nil)))

(defun agent-scheme--bind-empty-repeated-pattern-variables
    (pattern literals ellipsis bindings path)
  "Record empty repeated matches for variables in PATTERN at PATH."
  (dolist (name (agent-scheme--pattern-variable-names
                 pattern literals ellipsis))
    (let ((entry
           (agent-scheme--ensure-pattern-binding
            bindings name (1+ (length path)))))
      (cl-pushnew path
                  (agent-scheme--pattern-binding-empty-prefixes entry)
                  :test #'equal))))

(defun agent-scheme--list-elements-tail (datum)
  "Return (ELEMENTS . TAIL) for possibly improper list DATUM."
  (let ((cursor datum)
        elements)
    (while (consp cursor)
      (push (car cursor) elements)
      (setq cursor (cdr cursor)))
    (cons (nreverse elements) cursor)))

(defun agent-scheme--identifier-syntax-binding-in
    (identifier syntax-environment)
  "Return syntactic binding for IDENTIFIER in SYNTAX-ENVIRONMENT."
  (let ((name (agent-scheme--symbol-name identifier)))
    (and name
         (or
          (and (agent-scheme--identifier-p identifier)
               (let* ((identifier-context
                       (agent-scheme--identifier-context identifier))
                      (definition-syntax-environment
                       (and identifier-context
                            (agent-scheme--syntax-context-syntax-environment
                             identifier-context))))
                 (and definition-syntax-environment
                      (agent-scheme--syntax-environment-ref
                       definition-syntax-environment name))))
          (and syntax-environment
               (agent-scheme--syntax-environment-ref
                syntax-environment name))))))

(defun agent-scheme--identifier-binding-token
    (identifier value-environment syntax-environment)
  "Return lexical binding token for IDENTIFIER."
  (let ((cell (and value-environment
                   (agent-scheme--environment-cell-for-identifier
                    value-environment identifier)))
        (syntax-binding
         (agent-scheme--identifier-syntax-binding-in
          identifier syntax-environment)))
    (cond
     (cell (cons 'value cell))
     (syntax-binding (cons 'syntax syntax-binding))
     (t nil))))

(defun agent-scheme--binding-tokens-equal-p (left right)
  "Return non-nil if lexical binding tokens LEFT and RIGHT are equal."
  (cond
   ((and (null left) (null right)) t)
   ((and left right
         (eq (car left) (car right))
         (eq (cdr left) (cdr right)))
    t)
   (t nil)))

(defun agent-scheme--literal-identifier-match-p
    (pattern input transformer use-environment use-syntax-environment)
  "Return non-nil if literal PATTERN matches INPUT."
  (and (agent-scheme--identifier-datum-p input)
       (equal (agent-scheme--symbol-name pattern)
              (agent-scheme--symbol-name input))
       (agent-scheme--binding-tokens-equal-p
        (agent-scheme--identifier-binding-token
         pattern
         (agent-scheme--syntax-transformer-value-environment transformer)
         (agent-scheme--syntax-transformer-syntax-environment transformer))
        (agent-scheme--identifier-binding-token
         input use-environment use-syntax-environment))))

(defun agent-scheme--find-ellipsis-index (patterns ellipsis)
  "Return index of the first ellipsis in PATTERNS, or nil."
  (let ((index 1)
        found)
    (while (and (null found) (< index (length patterns)))
      (when (agent-scheme--ellipsis-identifier-p (nth index patterns) ellipsis)
        (setq found index))
      (setq index (1+ index)))
    found))

(defun agent-scheme--match-pattern
    (pattern input transformer bindings path use-environment
             use-syntax-environment)
  "Return non-nil if PATTERN matches INPUT at nested ellipsis PATH."
  (let ((literals (agent-scheme--syntax-transformer-literals transformer))
        (ellipsis (agent-scheme--syntax-transformer-ellipsis transformer)))
    (cond
     ((agent-scheme--identifier-datum-p pattern)
      (let ((name (agent-scheme--symbol-name pattern)))
        (cond
         ((and (equal name "_")
               (not (agent-scheme--syntax-literal-p pattern literals)))
          t)
         ((agent-scheme--syntax-literal-p pattern literals)
          (agent-scheme--literal-identifier-match-p
           pattern input transformer use-environment use-syntax-environment))
         ((equal name ellipsis)
          (and (agent-scheme--identifier-datum-p input)
               (equal name (agent-scheme--symbol-name input))))
         (t
          (agent-scheme--syntax-bind-pattern-variable
           bindings name input path)))))
     ((consp pattern)
      (and (consp input)
           (let* ((pattern-list
                   (agent-scheme--list-elements-tail pattern))
                  (input-list
                   (agent-scheme--list-elements-tail input)))
             (agent-scheme--match-pattern-elements
              (car pattern-list)
              (cdr pattern-list)
              (car input-list)
              (cdr input-list)
              transformer
              bindings
              path
              use-environment
              use-syntax-environment))))
     ((vectorp pattern)
      (and (vectorp input)
           (agent-scheme--match-pattern-elements
            (append pattern nil)
            nil
            (append input nil)
            nil
            transformer
            bindings
            path
            use-environment
            use-syntax-environment)))
     (t
      (equal pattern input)))))

(defun agent-scheme--match-fixed-pattern-elements
    (patterns pattern-tail input-elements input-tail transformer bindings path
              use-environment use-syntax-environment)
  "Match fixed PATTERNS and PATTERN-TAIL against input pieces."
  (and (>= (length input-elements) (length patterns))
       (cl-loop for pattern in patterns
                for input in input-elements
                always
                (agent-scheme--match-pattern
                 pattern input transformer bindings path
                 use-environment use-syntax-environment))
       (let ((remaining
              (nthcdr (length patterns) input-elements)))
         (if pattern-tail
             (agent-scheme--match-pattern
              pattern-tail
              (append remaining input-tail)
              transformer
              bindings
              path
              use-environment
              use-syntax-environment)
           (and (null remaining) (null input-tail))))))

(defun agent-scheme--match-pattern-elements
    (patterns pattern-tail input-elements input-tail transformer bindings path
              use-environment use-syntax-environment)
  "Return non-nil if PATTERNS match INPUT-ELEMENTS."
  (let* ((ellipsis (agent-scheme--syntax-transformer-ellipsis transformer))
         (ellipsis-index
          (agent-scheme--find-ellipsis-index patterns ellipsis)))
    (if ellipsis-index
        ;; R7RS ellipses repeat the pattern immediately before the ellipsis.
        ;; Prefix and suffix patterns stay fixed while PATH tracks each repeat.
        (let* ((prefix-count (1- ellipsis-index))
               (suffix (nthcdr (1+ ellipsis-index) patterns))
               (suffix-count (length suffix))
               (repeat-pattern (nth (1- ellipsis-index) patterns))
               (repeat-count (- (length input-elements)
                                prefix-count
                                suffix-count)))
          (and (>= repeat-count 0)
               (cl-loop for pattern in (cl-subseq patterns 0 prefix-count)
                        for input in input-elements
                        always
                        (agent-scheme--match-pattern
                         pattern input transformer bindings path
                         use-environment use-syntax-environment))
               (progn
                 (when (= repeat-count 0)
                   (agent-scheme--bind-empty-repeated-pattern-variables
                    repeat-pattern
                    (agent-scheme--syntax-transformer-literals transformer)
                    ellipsis
                    bindings
                    path))
                 t)
               (cl-loop for input in (cl-subseq
                                      input-elements
                                      prefix-count
                                      (+ prefix-count repeat-count))
                        for index from 0
                        always
                        (agent-scheme--match-pattern
                         repeat-pattern input transformer bindings
                         (append path (list index))
                         use-environment use-syntax-environment))
               (cl-loop for pattern in suffix
                        for input in (if (> suffix-count 0)
                                         (last input-elements suffix-count)
                                       nil)
                        always
                        (agent-scheme--match-pattern
                         pattern input transformer bindings path
                         use-environment use-syntax-environment))
               (if pattern-tail
                   (agent-scheme--match-pattern
                    pattern-tail
                    input-tail
                    transformer
                    bindings
                    path
                    use-environment
                    use-syntax-environment)
                 (null input-tail))))
      (agent-scheme--match-fixed-pattern-elements
       patterns pattern-tail input-elements input-tail transformer bindings path
       use-environment use-syntax-environment))))

(defun agent-scheme--match-syntax-rule
    (rule form transformer bindings use-environment use-syntax-environment)
  "Return non-nil if RULE matches macro use FORM."
  (let* ((pattern-list (agent-scheme--list-elements-tail (car rule)))
         (input-list (agent-scheme--list-elements-tail form))
         (pattern-elements (car pattern-list))
         (input-elements (car input-list)))
    (and pattern-elements
         input-elements
         (null (cdr input-list))
         (agent-scheme--match-pattern-elements
          (cdr pattern-elements)
          (cdr pattern-list)
          (cdr input-elements)
          nil
          transformer
          bindings
          nil
          use-environment
          use-syntax-environment))))

(defun agent-scheme--template-pattern-variable-names
    (template bindings ellipsis)
  "Return pattern variable names referenced in TEMPLATE."
  (cond
   ((agent-scheme--identifier-datum-p template)
    (let ((name (agent-scheme--symbol-name template)))
      (and (not (equal name ellipsis))
           (gethash name bindings)
           (list name))))
   ((consp template)
    (let* ((pieces (agent-scheme--list-elements-tail template))
           (names
            (apply #'append
                   (mapcar
                    (lambda (element)
                      (agent-scheme--template-pattern-variable-names
                       element bindings ellipsis))
                    (car pieces)))))
      (if (cdr pieces)
          (append names
                  (agent-scheme--template-pattern-variable-names
                   (cdr pieces) bindings ellipsis))
        names)))
   ((vectorp template)
    (apply #'append
           (mapcar
            (lambda (element)
              (agent-scheme--template-pattern-variable-names
               element bindings ellipsis))
            (append template nil))))
   (t nil)))

(defun agent-scheme--pattern-binding-repeat-count-at (entry path)
  "Return repetition count for ENTRY one level below PATH, or nil."
  (when (> (agent-scheme--pattern-binding-depth entry) (length path))
    (let ((indices nil))
      (maphash
       (lambda (capture-path _value)
         (when (and (> (length capture-path) (length path))
                    (agent-scheme--path-prefix-p path capture-path))
           (cl-pushnew (nth (length path) capture-path)
                       indices)))
       (agent-scheme--pattern-binding-captures entry))
      (dolist (empty-prefix
               (agent-scheme--pattern-binding-empty-prefixes entry))
        (when (and (> (length empty-prefix) (length path))
                   (agent-scheme--path-prefix-p path empty-prefix))
          (cl-pushnew (nth (length path) empty-prefix) indices)))
      (cond
       (indices
        (1+ (apply #'max indices)))
       ((member path
                (agent-scheme--pattern-binding-empty-prefixes entry))
        0)
       (t nil)))))

(defun agent-scheme--template-repeat-count (template bindings ellipsis path)
  "Return the repetition count required by TEMPLATE at PATH."
  (let ((count nil))
    (dolist (name (agent-scheme--template-pattern-variable-names
                   template bindings ellipsis))
      (let* ((entry (gethash name bindings))
             (entry-count
              (and entry
                   (agent-scheme--pattern-binding-repeat-count-at
                    entry path))))
        (when entry-count
          (cond
           ((null count)
            (setq count entry-count))
           ((/= count entry-count)
            (agent-scheme--eval-error
             "template ellipsis variables have different lengths"))))))
    (or count
        (agent-scheme--eval-error
         "template ellipsis must contain a repeated pattern variable"))))

(defun agent-scheme--pattern-binding-value-at (entry name path)
  "Return captured value for NAME from ENTRY at PATH."
  (let* ((depth (agent-scheme--pattern-binding-depth entry))
         (capture-path
          (if (<= depth (length path))
              (cl-subseq path 0 depth)
            (agent-scheme--eval-error
             "repeated pattern variable used without enough ellipses: %s"
             name)))
         (value
          (gethash capture-path
                   (agent-scheme--pattern-binding-captures entry)
                   agent-scheme--missing-cell)))
    (if (eq value agent-scheme--missing-cell)
        (agent-scheme--eval-error
         "missing pattern variable capture: %s" name)
      value)))

(defun agent-scheme--expand-template
    (template bindings syntax-context ellipsis &optional path ellipsis-literal)
  "Expand TEMPLATE using BINDINGS and SYNTAX-CONTEXT.
PATH identifies the current nested ellipsis position.  Identifiers
not captured by BINDINGS are wrapped in SYNTAX-CONTEXT so their
free bindings resolve in the macro definition environment."
  (setq path (or path nil))
  (cond
   ((agent-scheme--identifier-datum-p template)
    (let* ((name (agent-scheme--symbol-name template))
           (entry (and (not (equal name ellipsis))
                       (gethash name bindings))))
      (cond
       (entry
        (agent-scheme--pattern-binding-value-at entry name path))
       ((and (equal name ellipsis) (not ellipsis-literal))
        (agent-scheme--eval-error "misplaced ellipsis in template"))
       (t
        (agent-scheme--make-identifier name syntax-context)))))
   ((consp template)
    (let* ((pieces (agent-scheme--list-elements-tail template))
           (elements (car pieces))
           (tail (cdr pieces)))
      (if (and (not ellipsis-literal)
               (null tail)
               (= (length elements) 2)
               (agent-scheme--ellipsis-identifier-p (car elements) ellipsis))
          (agent-scheme--expand-template
           (cadr elements) bindings syntax-context ellipsis path t)
        (let ((cursor elements)
              output)
          (while cursor
            (let ((element (car cursor))
                  (next (cadr cursor)))
              (if (and next
                       (not ellipsis-literal)
                       (agent-scheme--ellipsis-identifier-p next ellipsis))
                  (let ((count (agent-scheme--template-repeat-count
                                element bindings ellipsis path))
                        expanded)
                    (dotimes (index count)
                      (push (agent-scheme--expand-template
                             element bindings syntax-context ellipsis
                             (append path (list index)))
                            expanded))
                    (dolist (expanded-element (nreverse expanded))
                      (push expanded-element output))
                    (setq cursor (cddr cursor)))
                (push (agent-scheme--expand-template
                       element bindings syntax-context ellipsis path
                       ellipsis-literal)
                      output)
                (setq cursor (cdr cursor)))))
          (append (nreverse output)
                  (and tail
                       (agent-scheme--expand-template
                        tail bindings syntax-context ellipsis path
                        ellipsis-literal)))))))
   ((vectorp template)
    (vconcat
     (agent-scheme--proper-list-elements
      (agent-scheme--expand-template
       (append template nil)
       bindings syntax-context ellipsis path ellipsis-literal)
      "syntax-rules vector template")))
   (t template)))

(defun agent-scheme--apply-syntax-transformer
    (transformer form environment context)
  "Apply TRANSFORMER to macro use FORM."
  (let ((matched nil)
        result
        (use-syntax-environment
         (agent-scheme--eval-context-syntax-environment context)))
    (dolist (rule (agent-scheme--syntax-transformer-rules transformer))
      (unless matched
        (let ((bindings (make-hash-table :test #'equal)))
          (when (agent-scheme--match-syntax-rule
                 rule form transformer bindings environment
                 use-syntax-environment)
            (setq matched t)
            ;; Each successful expansion gets a fresh context token so
            ;; template-introduced bindings cannot collide with caller names.
            (setq result
                  (agent-scheme--expand-template
                   (cdr rule)
                   bindings
                   (agent-scheme--make-syntax-context
                    (make-symbol "syntax")
                    (agent-scheme--syntax-transformer-value-environment
                     transformer)
                    (agent-scheme--syntax-transformer-syntax-environment
                     transformer))
                   (agent-scheme--syntax-transformer-ellipsis
                    transformer)))))))
    (unless matched
      (agent-scheme--eval-error
       "macro use does not match any syntax-rules pattern: %s"
       (agent-scheme-value->external form)))
    (when (agent-scheme--syntax-error-form-p result)
      (agent-scheme--raise-syntax-error result form))
    result))

(defun agent-scheme--syntax-definition-form-p (form)
  "Return non-nil if FORM is a `define-syntax' form."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) "define-syntax")))

(defun agent-scheme--eval-define-syntax
    (form environment context syntax-environment)
  "Install the syntax definition FORM in SYNTAX-ENVIRONMENT."
  (let ((parts (agent-scheme--proper-list-elements
                form "define-syntax form")))
    (unless (= (length parts) 3)
      (agent-scheme--eval-error
       "define-syntax requires a keyword and transformer spec"))
    (let ((keyword
           (agent-scheme--expect-symbol-name
            (cadr parts) "define-syntax keyword"))
          (transformer
           (agent-scheme--parse-syntax-rules
            (caddr parts)
            environment
            syntax-environment)))
      (agent-scheme--syntax-environment-define
       syntax-environment keyword transformer)
      agent-scheme-unspecified)))

(defun agent-scheme--parse-let-syntax-binding (binding)
  "Return BINDING as (KEYWORD . TRANSFORMER-SPEC)."
  (let ((parts (agent-scheme--proper-list-elements
                binding "syntax binding")))
    (unless (= (length parts) 2)
      (agent-scheme--eval-error
       "syntax binding must contain a keyword and transformer spec"))
    (cons (agent-scheme--expect-symbol-name
           (car parts) "syntax binding keyword")
          (cadr parts))))

(defun agent-scheme--make-local-syntax-scope
    (parts environment context recursive)
  "Return a local syntax scope from let-syntax PARTS.
When RECURSIVE is non-nil, transformer specs see the new bindings."
  (unless (>= (length parts) 3)
    (agent-scheme--eval-error
     "%s requires bindings and a body"
     (if recursive "letrec-syntax" "let-syntax")))
  (let* ((outer-syntax-environment
          (agent-scheme--eval-context-syntax-environment context))
         (local-syntax-environment
          (agent-scheme--make-empty-syntax-environment
           outer-syntax-environment))
         (bindings
          (mapcar #'agent-scheme--parse-let-syntax-binding
                  (agent-scheme--proper-list-elements
                   (cadr parts) "syntax binding list")))
         seen)
    (dolist (binding bindings)
      (let ((keyword (car binding)))
        (when (member keyword seen)
          (agent-scheme--eval-error
           "duplicate syntax binding: %s" keyword))
        (push keyword seen)))
    (dolist (binding bindings)
      (agent-scheme--syntax-environment-define
       local-syntax-environment
       (car binding)
       (agent-scheme--parse-syntax-rules
        (cdr binding)
        environment
        (if recursive
            local-syntax-environment
          outer-syntax-environment))))
    (agent-scheme--make-syntax-scope
     (cddr parts)
     local-syntax-environment)))

(defun agent-scheme--expand-expression (expression environment context)
  "Return one macro expansion step for EXPRESSION."
  (if (not (consp expression))
      expression
    (let* ((parts (agent-scheme--proper-list-elements
                   expression "expression"))
           (operator (car parts)))
      (cond
       ((and (agent-scheme--symbol-named-p operator "syntax-error")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--raise-syntax-error expression))
       ((and (agent-scheme--symbol-named-p operator "let-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--make-local-syntax-scope
         parts environment context nil))
       ((and (agent-scheme--symbol-named-p operator "letrec-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        (agent-scheme--make-local-syntax-scope
         parts environment context t))
       ((agent-scheme--syntax-binding-for-operator
         operator environment context)
        (agent-scheme--apply-syntax-transformer
         (agent-scheme--syntax-binding-for-operator
          operator environment context)
         expression
         environment
         context))
	       (t expression)))))

(defun agent-scheme--expand-definition-form (form environment context)
  "Return macro-expanded variable definition FORM."
  (let* ((parts (agent-scheme--proper-list-elements form "define form"))
         (target (cadr parts)))
    (cond
     ((agent-scheme--identifier-datum-p target)
      (unless (= (length parts) 3)
        (agent-scheme--eval-error
         "define requires an identifier and an expression"))
      (list (car parts)
            target
            (agent-scheme--expand-expression-fully
             (caddr parts) environment context)))
     ((consp target)
      (append
       (list (car parts) target)
       (agent-scheme--expand-sequence-forms
        (cddr parts) environment context t)))
     (t
      (agent-scheme--eval-error
       "define target must be an identifier or function signature")))))

(defun agent-scheme--expand-define-values-form (form environment context)
  "Return macro-expanded define-values FORM."
  (let* ((parts (agent-scheme--proper-list-elements
                 form "define-values form")))
    (unless (= (length parts) 3)
      (agent-scheme--eval-error
       "define-values requires formals and one expression"))
    (list (car parts)
          (cadr parts)
          (agent-scheme--expand-expression-fully
           (caddr parts) environment context))))

(defun agent-scheme--expand-core-combination (expression environment context)
  "Return EXPRESSION with macro expansion recursively applied."
  (let* ((parts (agent-scheme--proper-list-elements expression "expression"))
         (operator (car parts)))
    (cond
     ((or (and (agent-scheme--symbol-named-p operator "quote")
               (agent-scheme--special-operator-active-p operator environment))
          (and (agent-scheme--symbol-named-p operator "quasiquote")
               (agent-scheme--special-operator-active-p operator environment)))
      expression)
     ((and (agent-scheme--symbol-named-p operator "lambda")
           (agent-scheme--special-operator-active-p operator environment))
      (unless (>= (length parts) 3)
        (agent-scheme--eval-error "lambda requires formals and a body"))
      (append (list operator (cadr parts))
              (agent-scheme--expand-sequence-forms
               (cddr parts) environment context t)))
     ((and (agent-scheme--symbol-named-p operator "if")
           (agent-scheme--special-operator-active-p operator environment))
      (unless (memq (length parts) '(3 4))
        (agent-scheme--eval-error
         "if requires test, consequent, and optional alternate"))
      (append
       (list operator
             (agent-scheme--expand-expression-fully
              (cadr parts) environment context)
             (agent-scheme--expand-expression-fully
              (caddr parts) environment context))
       (and (= (length parts) 4)
            (list
             (agent-scheme--expand-expression-fully
              (cadddr parts) environment context)))))
     ((and (agent-scheme--symbol-named-p operator "set!")
           (agent-scheme--special-operator-active-p operator environment))
      (unless (= (length parts) 3)
        (agent-scheme--eval-error
         "set! requires an identifier and an expression"))
     (list operator
            (cadr parts)
            (agent-scheme--expand-expression-fully
             (caddr parts) environment context)))
     ((and (agent-scheme--symbol-named-p operator "parameterize")
           (agent-scheme--special-operator-active-p operator environment))
      (let ((bindings
             (mapcar
              (lambda (binding)
                (let ((binding-parts
                       (agent-scheme--proper-list-elements
                        binding "parameterize binding")))
                  (unless (= (length binding-parts) 2)
                    (agent-scheme--eval-error
                     "parameterize binding must contain a parameter and value"))
                  (list (agent-scheme--expand-expression-fully
                         (car binding-parts) environment context)
                        (agent-scheme--expand-expression-fully
                         (cadr binding-parts) environment context))))
              (agent-scheme--proper-list-elements
               (cadr parts) "parameterize binding list"))))
        (append (list operator bindings)
                (agent-scheme--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (member (agent-scheme--symbol-name operator)
                   '("let-values" "let*-values"))
           (agent-scheme--special-operator-active-p operator environment))
      (let* ((description (agent-scheme--symbol-name operator))
             (bindings
              (mapcar
               (lambda (binding)
                 (let ((binding-parts
                        (agent-scheme--proper-list-elements
                         binding
                         (format "%s binding" description))))
                   (unless (= (length binding-parts) 2)
                     (agent-scheme--eval-error
                      "%s binding must contain formals and initializer"
                      description))
                   (list (car binding-parts)
                         (agent-scheme--expand-expression-fully
                          (cadr binding-parts) environment context))))
               (agent-scheme--proper-list-elements
                (cadr parts) (format "%s binding list" description)))))
        (append (list operator bindings)
                (agent-scheme--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (member (agent-scheme--symbol-name operator) '("letrec" "letrec*"))
           (agent-scheme--special-operator-active-p operator environment))
      (let ((bindings
             (mapcar
              (lambda (binding)
                (let ((binding-parts
                       (agent-scheme--proper-list-elements
                        binding "letrec binding")))
                  (unless (= (length binding-parts) 2)
                    (agent-scheme--eval-error
                     "letrec binding must contain an identifier and initializer"))
                  (list (car binding-parts)
                        (agent-scheme--expand-expression-fully
                         (cadr binding-parts) environment context))))
              (agent-scheme--proper-list-elements
               (cadr parts) "letrec binding list"))))
        (append (list operator bindings)
                (agent-scheme--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (agent-scheme--symbol-named-p operator "begin")
           (agent-scheme--special-operator-active-p operator environment))
      (cons operator
            (agent-scheme--expand-sequence-forms
             (cdr parts) environment context nil)))
     (t
      (mapcar
       (lambda (part)
         (agent-scheme--expand-expression-fully part environment context))
       parts)))))

(defun agent-scheme--expand-expression-fully (expression environment context)
  "Return EXPRESSION after recursive macro expansion."
  (agent-scheme--note-step context)
  (let ((expanded (agent-scheme--expand-expression
                   expression environment context)))
    (cond
     ((not (eq expanded expression))
      (cond
       ((agent-scheme--syntax-scope-p expanded)
        (agent-scheme--with-syntax-environment
         context
         (agent-scheme--syntax-scope-syntax-environment expanded)
         (lambda ()
           (cons (agent-scheme--syntax-symbol "begin")
                 (agent-scheme--expand-sequence-forms
                  (agent-scheme--syntax-scope-forms expanded)
                  environment
                  context
                  t)))))
       (t
        (agent-scheme--expand-expression-fully expanded environment context))))
     ((consp expression)
      (agent-scheme--expand-core-combination expression environment context))
     (t expression))))

(defun agent-scheme--expand-sequence-forms
    (forms environment context allow-definitions)
  "Return FORMS after macro expansion under CONTEXT."
  (let (expanded-forms)
    (dolist (form forms)
      (cond
       ((and allow-definitions
             (agent-scheme--import-form-p form))
        (agent-scheme--eval-import form environment context))
       ((and allow-definitions
             (agent-scheme--define-library-form-p form))
        (agent-scheme--eval-define-library form environment context))
       ((and allow-definitions
             (agent-scheme--syntax-definition-form-p form))
        (agent-scheme--eval-define-syntax
         form
         environment
         context
         (agent-scheme--eval-context-syntax-environment context)))
       ((and allow-definitions
             (agent-scheme--definition-form-p form))
        (push (agent-scheme--expand-definition-form
               form environment context)
              expanded-forms))
       ((and allow-definitions
             (agent-scheme--define-values-form-p form))
        (push (agent-scheme--expand-define-values-form
               form environment context)
              expanded-forms))
       ((and allow-definitions
             (agent-scheme--begin-form-p form))
        (dolist (begin-form
                 (agent-scheme--expand-sequence-forms
                  (cdr (agent-scheme--proper-list-elements form "begin form"))
                  environment
                  context
                  t))
          (push begin-form expanded-forms)))
       (t
        (push (agent-scheme--expand-expression-fully
               form environment context)
              expanded-forms))))
    (nreverse expanded-forms)))

;;;###autoload
(defun agent-scheme-expand (expression &optional environment options)
  "Macro-expand one Agent Scheme EXPRESSION datum."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--expand-expression-fully
     expression eval-environment context)))

;;;###autoload
(defun agent-scheme-expand-source (source &optional environment options)
  "Read SOURCE and return its macro-expanded non-syntax forms."
  (let ((context (agent-scheme--new-eval-context options))
        (eval-environment (or environment
                              (agent-scheme-make-base-environment))))
    (agent-scheme--ensure-base-syntax context eval-environment)
    (agent-scheme--expand-sequence-forms
     (agent-scheme-read-all source options)
     eval-environment
     context
     t)))

(defun agent-scheme--macro-symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme--macro-field (name &rest values)
  "Return a Scheme-readable macro introspection field."
  (cons (agent-scheme--macro-symbol name) values))

(defun agent-scheme--macro-integer (value)
  "Return VALUE as an exact Agent Scheme integer datum."
  (agent-scheme--make-canonical-integer value))

(defun agent-scheme--macro-option-name (datum description)
  "Return DATUM as an option-name string for DESCRIPTION."
  (or (agent-scheme--symbol-name datum)
      (and (symbolp datum) (symbol-name datum))
      (and (stringp datum) datum)
      (agent-scheme--eval-error "%s option name must be a symbol" description)))

(defun agent-scheme--macro-option-integer (datum description)
  "Return DATUM as a host integer for DESCRIPTION."
  (unless (and (agent-scheme-number-p datum)
               (eq (agent-scheme-number-kind datum) 'integer)
               (eq (agent-scheme-number-exactness datum) 'exact))
    (agent-scheme--eval-error "%s option value must be an exact integer"
                              description))
  (agent-scheme-number-value datum))

(defun agent-scheme--macro-option-entry (entry)
  "Return ENTRY as a (NAME . VALUE) option pair."
  (cond
   ((and (consp entry)
         (consp (cdr entry))
         (null (cddr entry)))
    (cons (car entry) (cadr entry)))
   ((consp entry)
    (cons (car entry) (cdr entry)))
   (t
    (agent-scheme--eval-error
     "macroexpand option entry must be a pair"))))

(defun agent-scheme--macro-options-plist (options)
  "Return Emacs option plist parsed from Scheme OPTIONS datum."
  (let (plist)
    (dolist (entry (agent-scheme--proper-list-elements
                    (or options nil) "macroexpand options"))
      (let* ((pair (agent-scheme--macro-option-entry entry))
             (name (agent-scheme--macro-option-name
                    (car pair) "macroexpand"))
             (value (cdr pair)))
        (pcase name
          ("max-steps"
           (setq plist
                 (plist-put plist :max-steps
                            (agent-scheme--macro-option-integer
                             value name))))
          ("max-non-tail-steps"
           (setq plist
                 (plist-put plist :max-non-tail-steps
                            (agent-scheme--macro-option-integer
                             value name))))
          ("max-value-nodes"
           (setq plist
                 (plist-put plist :max-value-nodes
                            (agent-scheme--macro-option-integer
                             value name))))
          ("max-events"
           (setq plist
                 (plist-put plist :max-events
                            (agent-scheme--macro-option-integer
                             value name))))
          ("max-event-nodes"
           (setq plist
                 (plist-put plist :max-event-nodes
                            (agent-scheme--macro-option-integer
                             value name))))
          (_
           (agent-scheme--eval-error
            "unknown macroexpand option: %s" name)))))
    plist))

(defun agent-scheme--macro-introspection-context (context options)
  "Return a child expansion context from CONTEXT and Scheme OPTIONS."
  (let ((child (agent-scheme--new-eval-context
                (agent-scheme--macro-options-plist options))))
    (when context
      (setf (agent-scheme--eval-context-syntax-environment child)
            (agent-scheme--eval-context-syntax-environment context))
      (setf (agent-scheme--eval-context-libraries child)
            (agent-scheme--eval-context-libraries context))
      (setf (agent-scheme--eval-context-interaction-environment child)
            (agent-scheme--eval-context-interaction-environment context))
      (setf (agent-scheme--eval-context-base-syntax-installed child)
            (agent-scheme--eval-context-base-syntax-installed context)))
    child))

(defun agent-scheme--macro-expand-environment (environment context)
  "Return the lexical ENVIRONMENT used for macro introspection."
  (or environment
      (and context
           (agent-scheme--eval-context-interaction-environment context))
      (agent-scheme-make-base-environment)))

(defun agent-scheme--macro-active-name (form environment context)
  "Return the active macro operator name for FORM, or nil."
  (when (consp form)
    (let ((operator (car form)))
      (cond
       ((and (agent-scheme--symbol-named-p operator "let-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        "let-syntax")
       ((and (agent-scheme--symbol-named-p operator "letrec-syntax")
             (agent-scheme--special-operator-active-p operator environment))
        "letrec-syntax")
       ((agent-scheme--syntax-binding-for-operator operator environment context)
        (agent-scheme--symbol-name operator))))))

(defun agent-scheme--macro-step-record (index macro-name input output)
  "Return one Scheme-readable macro expansion step record."
  (list
   (agent-scheme--macro-symbol "step")
   (agent-scheme--macro-field "index" (agent-scheme--macro-integer index))
   (agent-scheme--macro-field "macro" (agent-scheme--macro-symbol macro-name))
   (agent-scheme--macro-field
    "input" (agent-scheme--strip-identifiers input))
   (agent-scheme--macro-field
    "output" (agent-scheme--strip-identifiers output))
   (agent-scheme--macro-field "source" (agent-scheme-datum-source input))))

(defun agent-scheme--macro-visible-expanded (expanded)
  "Return EXPANDED in the readable shape used by expansion records."
  (if (agent-scheme--syntax-scope-p expanded)
      (cons (agent-scheme--macro-symbol "begin")
            (agent-scheme--syntax-scope-forms expanded))
    expanded))

(defun agent-scheme--macro-expand-target-fully
    (target environment context)
  "Fully expand TARGET, preserving local syntax scope when present."
  (if (agent-scheme--syntax-scope-p target)
      (agent-scheme--with-syntax-environment
       context
       (agent-scheme--syntax-scope-syntax-environment target)
       (lambda ()
         (cons (agent-scheme--macro-symbol "begin")
               (agent-scheme--expand-sequence-forms
                (agent-scheme--syntax-scope-forms target)
                environment
                context
                t))))
    (agent-scheme--expand-expression-fully target environment context)))

(defun agent-scheme--macro-trace-top-level
    (form environment context one-step)
  "Return a plist with top-level expansion trace for FORM.
ONE-STEP stops after the first macro expansion."
  (let ((current form)
        (target form)
        steps
        macros
        (index 0)
        continue)
    (setq continue t)
    (while continue
      (agent-scheme--note-step context)
      (let* ((macro-name
              (agent-scheme--macro-active-name current environment context))
             (expanded
              (agent-scheme--expand-expression current environment context))
             (visible-expanded
              (agent-scheme--macro-visible-expanded expanded)))
        (agent-scheme--copy-datum-source visible-expanded current)
        (if (not (eq expanded current))
            (progn
              (setq target expanded)
              (cl-incf index)
              (push (agent-scheme--macro-step-record
                     index
                     (or macro-name "syntax")
                     current
                     visible-expanded)
                    steps)
              (cl-pushnew (or macro-name "syntax") macros :test #'equal)
              (setq current visible-expanded)
              (when (or one-step (agent-scheme--syntax-scope-p expanded))
                (setq continue nil)))
          (setq target current)
          (setq continue nil))))
    (list :expanded current
          :target target
          :steps (nreverse steps)
          :macros (nreverse macros))))

(defun agent-scheme--macro-condition-datum
    (condition context environment)
  "Return CONDITION as a macro-expansion debugger condition datum."
  (agent-scheme-debugger-condition-datum
   condition context 'macro-expansion environment))

(defun agent-scheme--macro-expansion-result
    (status mode original expanded steps macros errors)
  "Build a Scheme-readable macro expansion result datum."
  (list
   (agent-scheme--macro-symbol "macro-expansion")
   (agent-scheme--macro-field "status" (agent-scheme--macro-symbol status))
   (agent-scheme--macro-field "mode" (agent-scheme--macro-symbol mode))
   (agent-scheme--macro-field
    "original" (agent-scheme--strip-identifiers original))
   (agent-scheme--macro-field
    "expanded" (if expanded
                   (agent-scheme--strip-identifiers expanded)
                 agent-scheme-false))
   (agent-scheme--macro-field "steps" steps)
   (agent-scheme--macro-field
    "macros" (mapcar #'agent-scheme--macro-symbol macros))
   (agent-scheme--macro-field "source" (agent-scheme-datum-source original))
   (agent-scheme--macro-field "warnings" nil)
   (agent-scheme--macro-field "errors" errors)))

(defun agent-scheme--macroexpand-result
    (form environment context options mode)
  "Return macro expansion introspection for FORM in MODE."
  (let* ((parent-context (or context (agent-scheme--new-eval-context nil)))
         (child-context
          (agent-scheme--macro-introspection-context parent-context options))
         (eval-environment
          (agent-scheme--macro-expand-environment environment parent-context))
         trace)
    (setf (agent-scheme--eval-context-interaction-environment child-context)
          eval-environment)
    (condition-case condition
        (progn
          (agent-scheme--ensure-base-syntax child-context eval-environment)
          (setq trace
                (agent-scheme--macro-trace-top-level
                 form eval-environment child-context (eq mode 'one-step)))
          (let ((expanded
                 (if (eq mode 'one-step)
                     (plist-get trace :expanded)
                   (agent-scheme--macro-expand-target-fully
                    (plist-get trace :target)
                    eval-environment
                    child-context))))
            (agent-scheme--macro-expansion-result
             'ok
             mode
             form
             expanded
             (plist-get trace :steps)
             (plist-get trace :macros)
             nil)))
      (error
       (agent-scheme--macro-expansion-result
        'error
        mode
        form
        nil
        (and trace (plist-get trace :steps))
        (and trace (plist-get trace :macros))
        (list (agent-scheme--macro-condition-datum
               condition child-context eval-environment)))))))

;;;###autoload
(defun agent-scheme-macroexpand
    (form &optional environment options context)
  "Return a Scheme-readable full macro expansion record for FORM."
  (agent-scheme--macroexpand-result form environment context options 'full))

;;;###autoload
(defun agent-scheme-macroexpand-1
    (form &optional environment options context)
  "Return a Scheme-readable one-step macro expansion record for FORM."
  (agent-scheme--macroexpand-result form environment context options 'one-step))

(defun agent-scheme-macro-binding-info
    (identifier &optional environment context)
  "Return Scheme-readable syntax binding metadata for IDENTIFIER."
  (let* ((name (agent-scheme--expect-symbol-name
                identifier "macro-binding-info identifier"))
         (syntax-environment
          (and context
               (agent-scheme--eval-context-syntax-environment context)))
         (binding
          (and syntax-environment
               (agent-scheme--syntax-environment-ref syntax-environment name))))
    (if binding
        (list
         (agent-scheme--macro-symbol "macro-binding")
         (agent-scheme--macro-field "identifier"
                                    (agent-scheme--macro-symbol name))
         (agent-scheme--macro-field "status"
                                    (agent-scheme--macro-symbol "bound"))
         (agent-scheme--macro-field "kind"
                                    (agent-scheme--macro-symbol "syntax-rules"))
         (agent-scheme--macro-field "library" agent-scheme-false))
      agent-scheme-false)))

(defun agent-scheme-syntax-source (datum)
  "Return source metadata for DATUM, or #f when none is attached."
  (agent-scheme-datum-source datum))

(defun agent-scheme--macro-library-record
    (status library-name macros errors)
  "Build a Scheme-readable macro library introspection record."
  (list
   (agent-scheme--macro-symbol "macro-library")
   (agent-scheme--macro-field "status" (agent-scheme--macro-symbol status))
   (agent-scheme--macro-field
    "library" (agent-scheme--strip-identifiers library-name))
   (agent-scheme--macro-field "macros" macros)
   (agent-scheme--macro-field "warnings" nil)
   (agent-scheme--macro-field "errors" errors)))

(defun agent-scheme-macroexpand-library
    (library-name &optional environment options context)
  "Return syntax export metadata for LIBRARY-NAME."
  (let* ((parent-context (or context (agent-scheme--new-eval-context nil)))
         (child-context
          (agent-scheme--macro-introspection-context parent-context options))
         (eval-environment
          (agent-scheme--macro-expand-environment environment parent-context)))
    (setf (agent-scheme--eval-context-interaction-environment child-context)
          eval-environment)
    (condition-case condition
        (progn
          (agent-scheme--ensure-base-syntax child-context eval-environment)
          (let* ((library
                  (agent-scheme--resolve-library
                   library-name child-context eval-environment))
                 (macros
                  (sort
                   (delq nil
                         (mapcar
                          (lambda (binding)
                            (when (eq (agent-scheme--library-binding-kind
                                       binding)
                                      'syntax)
                              (list
                               (agent-scheme--macro-symbol "macro")
                               (agent-scheme--macro-symbol
                                (agent-scheme--library-binding-name
                                 binding))
                               (agent-scheme--macro-field
                                "kind"
                                (agent-scheme--macro-symbol
                                 "syntax-rules")))))
                          (agent-scheme--library-exports library)))
                   (lambda (left right)
                     (string<
                      (agent-scheme-symbol-name
                       (cadr left))
                      (agent-scheme-symbol-name
                       (cadr right)))))))
            (agent-scheme--macro-library-record
             'ok library-name macros nil)))
      (error
       (agent-scheme--macro-library-record
        'error
        library-name
        nil
        (list (agent-scheme--macro-condition-datum
               condition child-context eval-environment)))))))

(provide 'agent-scheme-macro)

;;; agent-scheme-macro.el ends here
