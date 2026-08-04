;;; consent-macro.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Syntax environments, `syntax-rules' transformers, hygienic template
;; expansion, and recursive macro-expansion entry points.  This module is
;; loadable without the interpreter backend when callers provide their own
;; environments.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-base)
(require 'consent-library)
(require 'consent-debugger)

(cl-defstruct (consent--syntax-transformer
               (:constructor consent--make-syntax-transformer
                             (ellipsis literals rules value-environment
                                       syntax-environment))
               (:copier nil))
  "A parsed high-level `syntax-rules' transformer."
  ellipsis literals rules value-environment syntax-environment)

(cl-defstruct (consent--pattern-binding
               (:constructor consent--make-pattern-binding
                             (depth captures))
               (:copier nil))
  "Nested pattern-variable captures for one macro expansion.
DEPTH is the ellipsis nesting level where the variable is bound.
CAPTURES maps index paths such as (0 2) to matched datums, and
EMPTY-PREFIXES records zero-length repetitions for template
validation."
  depth captures empty-prefixes)

(cl-defstruct (consent--syntax-scope
               (:constructor consent--make-syntax-scope
                             (forms syntax-environment))
               (:copier nil))
  "Body forms evaluated under a local syntactic environment."
  forms syntax-environment)

(defun consent--definition-form-p (form)
  "Return non-nil if FORM is a supported definition form."
  (and (consp form)
       (consent--symbol-named-p (car form) "define")))

(defun consent--define-values-form-p (form)
  "Return non-nil if FORM is a supported define-values form."
  (and (consp form)
       (consent--symbol-named-p (car form) "define-values")))

(defun consent--begin-form-p (form)
  "Return non-nil if FORM is a begin form."
  (and (consp form)
       (consent--symbol-named-p (car form) "begin")))

(defun consent--record-definition-form-p (form)
  "Return non-nil if FORM is a supported define-record-type form."
  (and (consp form)
       (consent--symbol-named-p (car form) "define-record-type")))

(defun consent--tagged-list-p (datum tag)
  "Return non-nil if DATUM is a list whose first identifier names TAG."
  (and (consp datum)
       (consent--symbol-named-p (car datum) tag)))

(defun consent--single-argument-syntax (form description)
  "Return FORM's single operand or signal an error for DESCRIPTION."
  (let ((parts (consent--proper-list-elements form description)))
    (unless (= (length parts) 2)
      (consent--eval-error "%s requires exactly one operand" description))
    (cadr parts)))

(defun consent--syntax-error-form-p (form)
  "Return non-nil if FORM is a syntax-error form."
  (consent--tagged-list-p form "syntax-error"))

(defun consent--syntax-error-message (form)
  "Return the user-facing message for syntax-error FORM."
  (let ((parts (consent--proper-list-elements form "syntax-error form")))
    (mapconcat #'consent-value->external (cdr parts) " ")))

(defun consent--raise-syntax-error (form &optional source-form)
  "Signal a syntax-error FORM, optionally attributed to SOURCE-FORM."
  (let ((message (consent--syntax-error-message form)))
    (if source-form
        (consent--eval-error
         "syntax-error while expanding %s: %s"
         (consent-value->external source-form)
         message)
      (consent--eval-error "syntax-error: %s" message))))

(defun consent--make-empty-syntax-environment (&optional parent)
  "Return a fresh empty syntactic environment with optional PARENT."
  (consent--make-syntax-environment
   (make-hash-table :test #'equal)
   parent
   (make-hash-table :test #'equal)))

(defun consent--syntax-environment-ref (syntax-environment name)
  "Return syntactic binding NAME in SYNTAX-ENVIRONMENT, or nil."
  (let ((cursor syntax-environment)
        transformer)
    (while (and cursor (not transformer))
      (let ((candidate
             (gethash name
                      (consent--syntax-environment-bindings cursor)
                      consent--missing-cell)))
        (unless (eq candidate consent--missing-cell)
          (setq transformer candidate)))
      (setq cursor (consent--syntax-environment-parent cursor)))
    transformer))

(defun consent--syntax-environment-define
    (syntax-environment name transformer)
  "Bind syntactic NAME to TRANSFORMER in SYNTAX-ENVIRONMENT."
  (when (gethash
         name
         (consent--syntax-environment-imported-bindings
          syntax-environment))
    (consent--eval-error
     "cannot redefine imported syntax binding: %s" name))
  (puthash name transformer
           (consent--syntax-environment-bindings syntax-environment)))

(defun consent--with-syntax-environment
    (context syntax-environment thunk)
  "Call THUNK with CONTEXT using SYNTAX-ENVIRONMENT."
  (let ((old-syntax-environment
         (consent--eval-context-syntax-environment context)))
    (unwind-protect
        (progn
          (setf (consent--eval-context-syntax-environment context)
                syntax-environment)
          (funcall thunk))
      (setf (consent--eval-context-syntax-environment context)
            old-syntax-environment))))

(defun consent--operator-shadowed-p (operator environment)
  "Return non-nil when OPERATOR is shadowed by a variable binding."
  (and (consent-symbol-p operator)
       (consent--environment-cell
        environment (consent-symbol-name operator))))

(defun consent--special-operator-active-p (operator environment)
  "Return non-nil if OPERATOR names an active core syntactic keyword."
  (and (consent--identifier-datum-p operator)
       (or (consent--identifier-p operator)
           (not (consent--operator-shadowed-p operator environment)))))

(defun consent--syntax-binding-for-operator
    (operator environment context)
  "Return macro transformer for OPERATOR in CONTEXT, or nil.
Identifier operators introduced by macros first consult their
definition-time syntax environment.  Plain symbols use the active
syntax environment unless a value binding shadows the syntactic
keyword."
  (let ((name (consent--symbol-name operator)))
    (when (and name
               (not (consent--operator-shadowed-p operator environment)))
      (or
       (and (consent--identifier-p operator)
            (let* ((identifier-context
                    (consent--identifier-context operator))
                   (definition-syntax-environment
                    (and identifier-context
                         (consent--syntax-context-syntax-environment
                          identifier-context))))
              (and definition-syntax-environment
                   (consent--syntax-environment-ref
                    definition-syntax-environment name))))
       (consent--syntax-environment-ref
        (consent--eval-context-syntax-environment context)
        name)))))

(defun consent--ellipsis-identifier-p (datum ellipsis)
  "Return non-nil if DATUM is the active ELLIPSIS identifier."
  (and (consent--identifier-datum-p datum)
       (equal (consent--symbol-name datum) ellipsis)))

(defun consent--syntax-rules-spec-p (form)
  "Return non-nil if FORM is a `syntax-rules' transformer spec."
  (and (consp form)
       (consent--symbol-named-p (car form) "syntax-rules")))

(defun consent--parse-syntax-rule (rule)
  "Return RULE as a parsed (PATTERN . TEMPLATE) pair."
  (let ((parts (consent--proper-list-elements
                rule "syntax-rules rule")))
    (unless (= (length parts) 2)
      (consent--eval-error
       "syntax-rules rule must contain a pattern and a template"))
    (let ((pattern (car parts)))
      (unless (and (consp pattern)
                   (consent--identifier-datum-p (car pattern)))
        (consent--eval-error
         "syntax-rules pattern must be a list beginning with an identifier"))
      (cons pattern (cadr parts)))))

(defun consent--parse-syntax-rules
    (form value-environment syntax-environment)
  "Parse FORM as a high-level `syntax-rules' transformer."
  (unless (consent--syntax-rules-spec-p form)
    (consent--eval-error
     "transformer spec must be a syntax-rules form"))
  (let* ((parts (consent--proper-list-elements
                 form "syntax-rules form"))
         (tail (cdr parts))
         (ellipsis "...")
         literal-form
         rule-forms)
    (unless (>= (length tail) 2)
      (consent--eval-error
       "syntax-rules requires literals and at least one rule"))
    (if (and (consent--identifier-datum-p (car tail))
             (consp (cdr tail)))
        (progn
          (setq ellipsis
                (consent--expect-symbol-name
                 (car tail) "syntax-rules ellipsis"))
          (setq literal-form (cadr tail))
          (setq rule-forms (cddr tail)))
      (setq literal-form (car tail))
      (setq rule-forms (cdr tail)))
    (let ((literals
           (mapcar
            (lambda (literal)
              (unless (consent--identifier-datum-p literal)
                (consent--eval-error
                 "syntax-rules literal must be an identifier"))
              literal)
            (consent--proper-list-elements
             literal-form "syntax-rules literal list"))))
      (consent--make-syntax-transformer
       ellipsis
       literals
       (mapcar #'consent--parse-syntax-rule rule-forms)
       value-environment
       syntax-environment))))

(defun consent--syntax-literal-p (identifier literals)
  "Return non-nil if IDENTIFIER is one of LITERALS."
  (member (consent--symbol-name identifier)
          (mapcar #'consent--symbol-name literals)))

(defun consent--path-prefix-p (prefix path)
  "Return non-nil when PREFIX is an initial segment of PATH."
  (and (<= (length prefix) (length path))
       (cl-loop for left in prefix
                for right in path
                always (= left right))))

(defun consent--ensure-pattern-binding (bindings name depth)
  "Return pattern binding NAME in BINDINGS, creating it at DEPTH."
  (let ((entry (gethash name bindings)))
    (cond
     ((null entry)
      (setq entry
            (consent--make-pattern-binding
             depth
             (make-hash-table :test #'equal)))
      (puthash name entry bindings))
     ((and (> (hash-table-count
               (consent--pattern-binding-captures entry))
              0)
           (/= (consent--pattern-binding-depth entry) depth))
      (consent--eval-error
       "pattern variable used at inconsistent ellipsis depth: %s"
       name))
     ((< (consent--pattern-binding-depth entry) depth)
      (setf (consent--pattern-binding-depth entry) depth)))
    entry))

(defun consent--syntax-bind-pattern-variable
    (bindings name value path)
  "Bind pattern variable NAME to VALUE at nested ellipsis PATH."
  (let* ((depth (length path))
         (entry (consent--ensure-pattern-binding bindings name depth))
         (captures (consent--pattern-binding-captures entry)))
    (unless (eq (gethash path captures consent--missing-cell)
                consent--missing-cell)
      (consent--eval-error
       "duplicate pattern variable: %s" name))
    ;; PATH is the sequence of repetition indexes leading to this capture.
    ;; Template expansion uses the same path to distribute nested ellipses.
    (puthash path value captures))
  t)

(defun consent--pattern-variable-names (pattern literals ellipsis)
  "Return pattern variable names contained in PATTERN."
  (cond
   ((consent--identifier-datum-p pattern)
    (let ((name (consent--symbol-name pattern)))
      (unless (or (equal name "_")
                  (equal name ellipsis)
                  (member name (mapcar #'consent--symbol-name
                                       literals)))
        (list name))))
   ((consp pattern)
    (let ((elements (consent--proper-list-elements-maybe pattern)))
      (when elements
        (apply #'append
               (mapcar
                (lambda (element)
                  (consent--pattern-variable-names
                   element literals ellipsis))
                elements)))))
   ((vectorp pattern)
    (apply #'append
           (mapcar
            (lambda (element)
              (consent--pattern-variable-names
               element literals ellipsis))
            (append pattern nil))))
   (t nil)))

(defun consent--bind-empty-repeated-pattern-variables
    (pattern literals ellipsis bindings path)
  "Record empty repeated matches for variables in PATTERN at PATH."
  (dolist (name (consent--pattern-variable-names
                 pattern literals ellipsis))
    (let ((entry
           (consent--ensure-pattern-binding
            bindings name (1+ (length path)))))
      (cl-pushnew path
                  (consent--pattern-binding-empty-prefixes entry)
                  :test #'equal))))

(defun consent--list-elements-tail (datum)
  "Return (ELEMENTS . TAIL) for possibly improper list DATUM."
  (let ((cursor datum)
        elements)
    (while (consp cursor)
      (push (car cursor) elements)
      (setq cursor (cdr cursor)))
    (cons (nreverse elements) cursor)))

(defun consent--identifier-syntax-binding-in
    (identifier syntax-environment)
  "Return syntactic binding for IDENTIFIER in SYNTAX-ENVIRONMENT."
  (let ((name (consent--symbol-name identifier)))
    (and name
         (or
          (and (consent--identifier-p identifier)
               (let* ((identifier-context
                       (consent--identifier-context identifier))
                      (definition-syntax-environment
                       (and identifier-context
                            (consent--syntax-context-syntax-environment
                             identifier-context))))
                 (and definition-syntax-environment
                      (consent--syntax-environment-ref
                       definition-syntax-environment name))))
          (and syntax-environment
               (consent--syntax-environment-ref
                syntax-environment name))))))

(defun consent--identifier-binding-token
    (identifier value-environment syntax-environment)
  "Return lexical binding token for IDENTIFIER."
  (let ((cell (and value-environment
                   (consent--environment-cell-for-identifier
                    value-environment identifier)))
        (syntax-binding
         (consent--identifier-syntax-binding-in
          identifier syntax-environment)))
    (cond
     (cell (cons 'value cell))
     (syntax-binding (cons 'syntax syntax-binding))
     (t nil))))

(defun consent--binding-tokens-equal-p (left right)
  "Return non-nil if lexical binding tokens LEFT and RIGHT are equal."
  (cond
   ((and (null left) (null right)) t)
   ((and left right
         (eq (car left) (car right))
         (eq (cdr left) (cdr right)))
    t)
   (t nil)))

(defun consent--literal-identifier-match-p
    (pattern input transformer use-environment use-syntax-environment)
  "Return non-nil if literal PATTERN matches INPUT."
  (and (consent--identifier-datum-p input)
       (equal (consent--symbol-name pattern)
              (consent--symbol-name input))
       (consent--binding-tokens-equal-p
        (consent--identifier-binding-token
         pattern
         (consent--syntax-transformer-value-environment transformer)
         (consent--syntax-transformer-syntax-environment transformer))
        (consent--identifier-binding-token
         input use-environment use-syntax-environment))))

(defun consent--find-ellipsis-index (patterns ellipsis)
  "Return index of the first ellipsis in PATTERNS, or nil."
  (let ((index 1)
        found)
    (while (and (null found) (< index (length patterns)))
      (when (consent--ellipsis-identifier-p (nth index patterns) ellipsis)
        (setq found index))
      (setq index (1+ index)))
    found))

(defun consent--match-pattern
    (pattern input transformer bindings path use-environment
             use-syntax-environment)
  "Return non-nil if PATTERN matches INPUT at nested ellipsis PATH."
  (let ((literals (consent--syntax-transformer-literals transformer))
        (ellipsis (consent--syntax-transformer-ellipsis transformer)))
    (cond
     ((consent--identifier-datum-p pattern)
      (let ((name (consent--symbol-name pattern)))
        (cond
         ((and (equal name "_")
               (not (consent--syntax-literal-p pattern literals)))
          t)
         ((consent--syntax-literal-p pattern literals)
          (consent--literal-identifier-match-p
           pattern input transformer use-environment use-syntax-environment))
         ((equal name ellipsis)
          (and (consent--identifier-datum-p input)
               (equal name (consent--symbol-name input))))
         (t
          (consent--syntax-bind-pattern-variable
           bindings name input path)))))
     ((consp pattern)
      ;; A pair pattern can still match the empty list when it is wholly
      ;; collapsible through an ellipsis, e.g. ((name val) ...) against ()
      ;; as in (let () body ...).  `consent--match-pattern-elements' rejects
      ;; pairs that genuinely require elements, so admitting nil input is safe.
      (and (or (consp input) (null input))
           (let* ((pattern-list
                   (consent--list-elements-tail pattern))
                  (input-list
                   (consent--list-elements-tail input)))
             (consent--match-pattern-elements
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
           (consent--match-pattern-elements
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

(defun consent--match-fixed-pattern-elements
    (patterns pattern-tail input-elements input-tail transformer bindings path
              use-environment use-syntax-environment)
  "Match fixed PATTERNS and PATTERN-TAIL against input pieces."
  (and (>= (length input-elements) (length patterns))
       (cl-loop for pattern in patterns
                for input in input-elements
                always
                (consent--match-pattern
                 pattern input transformer bindings path
                 use-environment use-syntax-environment))
       (let ((remaining
              (nthcdr (length patterns) input-elements)))
         (if pattern-tail
             (consent--match-pattern
              pattern-tail
              (append remaining input-tail)
              transformer
              bindings
              path
              use-environment
              use-syntax-environment)
           (and (null remaining) (null input-tail))))))

(defun consent--match-pattern-elements
    (patterns pattern-tail input-elements input-tail transformer bindings path
              use-environment use-syntax-environment)
  "Return non-nil if PATTERNS match INPUT-ELEMENTS."
  (let* ((ellipsis (consent--syntax-transformer-ellipsis transformer))
         (ellipsis-index
          (consent--find-ellipsis-index patterns ellipsis)))
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
                        (consent--match-pattern
                         pattern input transformer bindings path
                         use-environment use-syntax-environment))
               (progn
                 (when (= repeat-count 0)
                   (consent--bind-empty-repeated-pattern-variables
                    repeat-pattern
                    (consent--syntax-transformer-literals transformer)
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
                        (consent--match-pattern
                         repeat-pattern input transformer bindings
                         (append path (list index))
                         use-environment use-syntax-environment))
               (cl-loop for pattern in suffix
                        for input in (if (> suffix-count 0)
                                         (last input-elements suffix-count)
                                       nil)
                        always
                        (consent--match-pattern
                         pattern input transformer bindings path
                         use-environment use-syntax-environment))
               (if pattern-tail
                   (consent--match-pattern
                    pattern-tail
                    input-tail
                    transformer
                    bindings
                    path
                    use-environment
                    use-syntax-environment)
                 (null input-tail))))
      (consent--match-fixed-pattern-elements
       patterns pattern-tail input-elements input-tail transformer bindings
         path
       use-environment use-syntax-environment))))

(defun consent--match-syntax-rule
    (rule form transformer bindings use-environment use-syntax-environment)
  "Return non-nil if RULE matches macro use FORM."
  (let* ((pattern-list (consent--list-elements-tail (car rule)))
         (input-list (consent--list-elements-tail form))
         (pattern-elements (car pattern-list))
         (input-elements (car input-list)))
    (and pattern-elements
         input-elements
         (null (cdr input-list))
         (consent--match-pattern-elements
          (cdr pattern-elements)
          (cdr pattern-list)
          (cdr input-elements)
          nil
          transformer
          bindings
          nil
          use-environment
          use-syntax-environment))))

(defun consent--template-pattern-variable-names
    (template bindings ellipsis)
  "Return pattern variable names referenced in TEMPLATE."
  (cond
   ((consent--identifier-datum-p template)
    (let ((name (consent--symbol-name template)))
      (and (not (equal name ellipsis))
           (gethash name bindings)
           (list name))))
   ((consp template)
    (let* ((pieces (consent--list-elements-tail template))
           (names
            (apply #'append
                   (mapcar
                    (lambda (element)
                      (consent--template-pattern-variable-names
                       element bindings ellipsis))
                    (car pieces)))))
      (if (cdr pieces)
          (append names
                  (consent--template-pattern-variable-names
                   (cdr pieces) bindings ellipsis))
        names)))
   ((vectorp template)
    (apply #'append
           (mapcar
            (lambda (element)
              (consent--template-pattern-variable-names
               element bindings ellipsis))
            (append template nil))))
   (t nil)))

(defun consent--pattern-binding-repeat-count-at (entry path)
  "Return repetition count for ENTRY one level below PATH, or nil."
  (when (> (consent--pattern-binding-depth entry) (length path))
    (let ((indices nil))
      (maphash
       (lambda (capture-path _value)
         (when (and (> (length capture-path) (length path))
                    (consent--path-prefix-p path capture-path))
           (cl-pushnew (nth (length path) capture-path)
                       indices)))
       (consent--pattern-binding-captures entry))
      (dolist (empty-prefix
               (consent--pattern-binding-empty-prefixes entry))
        (when (and (> (length empty-prefix) (length path))
                   (consent--path-prefix-p path empty-prefix))
          (cl-pushnew (nth (length path) empty-prefix) indices)))
      (cond
       (indices
        (1+ (apply #'max indices)))
       ((member path
                (consent--pattern-binding-empty-prefixes entry))
        0)
       (t nil)))))

(defun consent--template-repeat-count (template bindings ellipsis path)
  "Return the repetition count required by TEMPLATE at PATH."
  (let ((count nil))
    (dolist (name (consent--template-pattern-variable-names
                   template bindings ellipsis))
      (let* ((entry (gethash name bindings))
             (entry-count
              (and entry
                   (consent--pattern-binding-repeat-count-at
                    entry path))))
        (when entry-count
          (cond
           ((null count)
            (setq count entry-count))
           ((/= count entry-count)
            (consent--eval-error
             "template ellipsis variables have different lengths"))))))
    (or count
        (consent--eval-error
         "template ellipsis must contain a repeated pattern variable"))))

(defun consent--pattern-binding-value-at (entry name path)
  "Return captured value for NAME from ENTRY at PATH."
  (let* ((depth (consent--pattern-binding-depth entry))
         (capture-path
          (if (<= depth (length path))
              (cl-subseq path 0 depth)
            (consent--eval-error
             "repeated pattern variable used without enough ellipses: %s"
             name)))
         (value
          (gethash capture-path
                   (consent--pattern-binding-captures entry)
                   consent--missing-cell)))
    (if (eq value consent--missing-cell)
        (consent--eval-error
         "missing pattern variable capture: %s" name)
      value)))

(defun consent--expand-template
    (template bindings syntax-context ellipsis &optional path ellipsis-literal)
  "Expand TEMPLATE using BINDINGS and SYNTAX-CONTEXT.
PATH identifies the current nested ellipsis position.  Identifiers
not captured by BINDINGS are wrapped in SYNTAX-CONTEXT so their
free bindings resolve in the macro definition environment."
  (setq path (or path nil))
  (cond
   ((consent--identifier-datum-p template)
    (let* ((name (consent--symbol-name template))
           (entry (and (not (equal name ellipsis))
                       (gethash name bindings))))
      (cond
       (entry
        (consent--pattern-binding-value-at entry name path))
       ((and (equal name ellipsis) (not ellipsis-literal))
        (consent--eval-error "misplaced ellipsis in template"))
       (t
        (consent--make-identifier name syntax-context)))))
   ((consp template)
    (let* ((pieces (consent--list-elements-tail template))
           (elements (car pieces))
           (tail (cdr pieces)))
      (if (and (not ellipsis-literal)
               (null tail)
               (= (length elements) 2)
               (consent--ellipsis-identifier-p (car elements) ellipsis))
          (consent--expand-template
           (cadr elements) bindings syntax-context ellipsis path t)
        (let ((cursor elements)
              output)
          (while cursor
            (let ((element (car cursor))
                  (next (cadr cursor)))
              (if (and next
                       (not ellipsis-literal)
                       (consent--ellipsis-identifier-p next ellipsis))
                  (let ((count (consent--template-repeat-count
                                element bindings ellipsis path))
                        expanded)
                    (dotimes (index count)
                      (push (consent--expand-template
                             element bindings syntax-context ellipsis
                             (append path (list index)))
                            expanded))
                    (dolist (expanded-element (nreverse expanded))
                      (push expanded-element output))
                    (setq cursor (cddr cursor)))
                (push (consent--expand-template
                       element bindings syntax-context ellipsis path
                       ellipsis-literal)
                      output)
                (setq cursor (cdr cursor)))))
          (append (nreverse output)
                  (and tail
                       (consent--expand-template
                        tail bindings syntax-context ellipsis path
                        ellipsis-literal)))))))
   ((vectorp template)
    (vconcat
     (consent--proper-list-elements
      (consent--expand-template
       (append template nil)
       bindings syntax-context ellipsis path ellipsis-literal)
      "syntax-rules vector template")))
   (t template)))

(defun consent--apply-syntax-transformer
    (transformer form environment context)
  "Apply TRANSFORMER to macro use FORM."
  (let ((matched nil)
        result
        (use-syntax-environment
         (consent--eval-context-syntax-environment context)))
    (dolist (rule (consent--syntax-transformer-rules transformer))
      (unless matched
        (let ((bindings (make-hash-table :test #'equal)))
          (when (consent--match-syntax-rule
                 rule form transformer bindings environment
                 use-syntax-environment)
            (setq matched t)
            ;; Each successful expansion gets a fresh context token so
            ;; template-introduced bindings cannot collide with caller names.
            (setq result
                  (consent--expand-template
                   (cdr rule)
                   bindings
                   (consent--make-syntax-context
                    (make-symbol "syntax")
                    (consent--syntax-transformer-value-environment
                     transformer)
                    (consent--syntax-transformer-syntax-environment
                     transformer))
                   (consent--syntax-transformer-ellipsis
                    transformer)))))))
    (unless matched
      (consent--eval-error
       "macro use does not match any syntax-rules pattern: %s"
       (consent-value->external form)))
    (when (consent--syntax-error-form-p result)
      (consent--raise-syntax-error result form))
    result))

(defun consent--syntax-definition-form-p (form)
  "Return non-nil if FORM is a `define-syntax' form."
  (and (consp form)
       (consent--symbol-named-p (car form) "define-syntax")))

(defun consent--eval-define-syntax
    (form environment _context syntax-environment)
  "Install the syntax definition FORM in SYNTAX-ENVIRONMENT."
  (let ((parts (consent--proper-list-elements
                form "define-syntax form")))
    (unless (= (length parts) 3)
      (consent--eval-error
       "define-syntax requires a keyword and transformer spec"))
    (let ((keyword
           (consent--expect-symbol-name
            (cadr parts) "define-syntax keyword"))
          (transformer
           (consent--parse-syntax-rules
            (caddr parts)
            environment
            syntax-environment)))
      (consent--syntax-environment-define
       syntax-environment keyword transformer)
      consent-unspecified)))

(defun consent--parse-let-syntax-binding (binding)
  "Return BINDING as (KEYWORD . TRANSFORMER-SPEC)."
  (let ((parts (consent--proper-list-elements
                binding "syntax binding")))
    (unless (= (length parts) 2)
      (consent--eval-error
       "syntax binding must contain a keyword and transformer spec"))
    (cons (consent--expect-symbol-name
           (car parts) "syntax binding keyword")
          (cadr parts))))

(defun consent--make-local-syntax-scope
    (parts environment context recursive)
  "Return a local syntax scope from let-syntax PARTS.
When RECURSIVE is non-nil, transformer specs see the new bindings."
  (unless (>= (length parts) 3)
    (consent--eval-error
     "%s requires bindings and a body"
     (if recursive "letrec-syntax" "let-syntax")))
  (let* ((outer-syntax-environment
          (consent--eval-context-syntax-environment context))
         (local-syntax-environment
          (consent--make-empty-syntax-environment
           outer-syntax-environment))
         (bindings
          (mapcar #'consent--parse-let-syntax-binding
                  (consent--proper-list-elements
                   (cadr parts) "syntax binding list")))
         seen)
    (dolist (binding bindings)
      (let ((keyword (car binding)))
        (when (member keyword seen)
          (consent--eval-error
           "duplicate syntax binding: %s" keyword))
        (push keyword seen)))
    (dolist (binding bindings)
      (consent--syntax-environment-define
       local-syntax-environment
       (car binding)
       (consent--parse-syntax-rules
        (cdr binding)
        environment
        (if recursive
            local-syntax-environment
          outer-syntax-environment))))
    (consent--make-syntax-scope
     (cddr parts)
     local-syntax-environment)))

(defun consent--expand-expression (expression environment context)
  "Return one macro expansion step for EXPRESSION."
  (if (not (consp expression))
      expression
    (let* ((parts (consent--proper-list-elements
                   expression "expression"))
           (operator (car parts)))
      (cond
       ((and (consent--symbol-named-p operator "syntax-error")
             (consent--special-operator-active-p operator environment))
        (consent--raise-syntax-error expression))
       ((and (consent--symbol-named-p operator "let-syntax")
             (consent--special-operator-active-p operator environment))
        (consent--make-local-syntax-scope
         parts environment context nil))
       ((and (consent--symbol-named-p operator "letrec-syntax")
             (consent--special-operator-active-p operator environment))
        (consent--make-local-syntax-scope
         parts environment context t))
       ((consent--syntax-binding-for-operator
         operator environment context)
        (consent--apply-syntax-transformer
         (consent--syntax-binding-for-operator
          operator environment context)
         expression
         environment
         context))
               (t expression)))))

(defun consent--expand-definition-form (form environment context)
  "Return macro-expanded variable definition FORM."
  (let* ((parts (consent--proper-list-elements form "define form"))
         (target (cadr parts)))
    (cond
     ((consent--identifier-datum-p target)
      (unless (= (length parts) 3)
        (consent--eval-error
         "define requires an identifier and an expression"))
      (list (car parts)
            target
            (consent--expand-expression-fully
             (caddr parts) environment context)))
     ((consp target)
      (append
       (list (car parts) target)
       (consent--expand-sequence-forms
        (cddr parts) environment context t)))
     (t
      (consent--eval-error
       "define target must be an identifier or function signature")))))

(defun consent--expand-define-values-form (form environment context)
  "Return macro-expanded define-values FORM."
  (let* ((parts (consent--proper-list-elements
                 form "define-values form")))
    (unless (= (length parts) 3)
      (consent--eval-error
       "define-values requires formals and one expression"))
    (list (car parts)
          (cadr parts)
          (consent--expand-expression-fully
           (caddr parts) environment context))))

(defun consent--expand-core-combination (expression environment context)
  "Return EXPRESSION with macro expansion recursively applied."
  (let* ((parts (consent--proper-list-elements expression "expression"))
         (operator (car parts)))
    (cond
     ((or (and (consent--symbol-named-p operator "quote")
               (consent--special-operator-active-p operator environment))
          (and (consent--symbol-named-p operator "quasiquote")
               (consent--special-operator-active-p operator environment)))
      expression)
     ((and (consent--symbol-named-p operator "lambda")
           (consent--special-operator-active-p operator environment))
      (unless (>= (length parts) 3)
        (consent--eval-error "lambda requires formals and a body"))
      (append (list operator (cadr parts))
              (consent--expand-sequence-forms
               (cddr parts) environment context t)))
     ((and (consent--symbol-named-p operator "if")
           (consent--special-operator-active-p operator environment))
      (unless (memq (length parts) '(3 4))
        (consent--eval-error
         "if requires test, consequent, and optional alternate"))
      (append
       (list operator
             (consent--expand-expression-fully
              (cadr parts) environment context)
             (consent--expand-expression-fully
              (caddr parts) environment context))
       (and (= (length parts) 4)
            (list
             (consent--expand-expression-fully
              (cadddr parts) environment context)))))
     ((and (consent--symbol-named-p operator "set!")
           (consent--special-operator-active-p operator environment))
      (unless (= (length parts) 3)
        (consent--eval-error
         "set! requires an identifier and an expression"))
     (list operator
            (cadr parts)
            (consent--expand-expression-fully
             (caddr parts) environment context)))
     ((and (consent--symbol-named-p operator "parameterize")
           (consent--special-operator-active-p operator environment))
      (let ((bindings
             (mapcar
              (lambda (binding)
                (let ((binding-parts
                       (consent--proper-list-elements
                        binding "parameterize binding")))
                  (unless (= (length binding-parts) 2)
                    (consent--eval-error
                     "parameterize binding must contain a parameter and\
 value"))
                  (list (consent--expand-expression-fully
                         (car binding-parts) environment context)
                        (consent--expand-expression-fully
                         (cadr binding-parts) environment context))))
              (consent--proper-list-elements
               (cadr parts) "parameterize binding list"))))
        (append (list operator bindings)
                (consent--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (member (consent--symbol-name operator)
                   '("let-values" "let*-values"))
           (consent--special-operator-active-p operator environment))
      (let* ((description (consent--symbol-name operator))
             (bindings
              (mapcar
               (lambda (binding)
                 (let ((binding-parts
                        (consent--proper-list-elements
                         binding
                         (format "%s binding" description))))
                   (unless (= (length binding-parts) 2)
                     (consent--eval-error
                      "%s binding must contain formals and initializer"
                      description))
                   (list (car binding-parts)
                         (consent--expand-expression-fully
                          (cadr binding-parts) environment context))))
               (consent--proper-list-elements
                (cadr parts) (format "%s binding list" description)))))
        (append (list operator bindings)
                (consent--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (member (consent--symbol-name operator) '("letrec" "letrec*"))
           (consent--special-operator-active-p operator environment))
      (let ((bindings
             (mapcar
              (lambda (binding)
                (let ((binding-parts
                       (consent--proper-list-elements
                        binding "letrec binding")))
                  (unless (= (length binding-parts) 2)
                    (consent--eval-error
                     "letrec binding must contain an identifier and\
 initializer"))
                  (list (car binding-parts)
                        (consent--expand-expression-fully
                         (cadr binding-parts) environment context))))
              (consent--proper-list-elements
               (cadr parts) "letrec binding list"))))
        (append (list operator bindings)
                (consent--expand-sequence-forms
                 (cddr parts) environment context t))))
     ((and (consent--symbol-named-p operator "begin")
           (consent--special-operator-active-p operator environment))
      (cons operator
            (consent--expand-sequence-forms
             (cdr parts) environment context nil)))
     (t
      (mapcar
       (lambda (part)
         (consent--expand-expression-fully part environment context))
       parts)))))

(defun consent--expand-expression-fully (expression environment context)
  "Return EXPRESSION after recursive macro expansion."
  (consent--note-step context)
  (let ((expanded (consent--expand-expression
                   expression environment context)))
    (cond
     ((not (eq expanded expression))
      (cond
       ((consent--syntax-scope-p expanded)
        (consent--with-syntax-environment
         context
         (consent--syntax-scope-syntax-environment expanded)
         (lambda ()
           (cons (consent--syntax-symbol "begin")
                 (consent--expand-sequence-forms
                  (consent--syntax-scope-forms expanded)
                  environment
                  context
                  t)))))
       (t
        (consent--expand-expression-fully expanded environment context))))
     ((consp expression)
      (consent--expand-core-combination expression environment context))
     (t expression))))

(defun consent--expand-sequence-forms
    (forms environment context allow-definitions)
  "Return FORMS after macro expansion under CONTEXT."
  (let (expanded-forms)
    (dolist (form forms)
      (cond
       ((and allow-definitions
             (consent--import-form-p form))
        (consent--eval-import form environment context))
       ((and allow-definitions
             (consent--define-library-form-p form))
        (consent--eval-define-library form environment context))
       ((and allow-definitions
             (consent--syntax-definition-form-p form))
        (consent--eval-define-syntax
         form
         environment
         context
         (consent--eval-context-syntax-environment context)))
       ((and allow-definitions
             (consent--definition-form-p form))
        (push (consent--expand-definition-form
               form environment context)
              expanded-forms))
       ((and allow-definitions
             (consent--define-values-form-p form))
        (push (consent--expand-define-values-form
               form environment context)
              expanded-forms))
       ((and allow-definitions
             (consent--begin-form-p form))
        (dolist (begin-form
                 (consent--expand-sequence-forms
                  (cdr (consent--proper-list-elements form "begin form"))
                  environment
                  context
                  t))
          (push begin-form expanded-forms)))
       (t
        (push (consent--expand-expression-fully
               form environment context)
              expanded-forms))))
    (nreverse expanded-forms)))

;;;###autoload
(defun consent-expand (expression &optional environment options)
  "Macro-expand one Consent Scheme EXPRESSION datum."
  (let ((context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment))))
    (consent--ensure-base-syntax context eval-environment)
    (consent--expand-expression-fully
     expression eval-environment context)))

;;;###autoload
(defun consent-expand-source (source &optional environment options)
  "Read SOURCE and return its macro-expanded non-syntax forms."
  (let ((context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment))))
    (consent--ensure-base-syntax context eval-environment)
    (consent--expand-sequence-forms
     (consent-read-all source options)
     eval-environment
     context
     t)))

(defun consent--macro-symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent--macro-field (name &rest values)
  "Return a Scheme-readable macro introspection field."
  (cons (consent--macro-symbol name) values))

(defun consent--macro-integer (value)
  "Return VALUE as an exact Consent Scheme integer datum."
  (consent--make-canonical-integer value))

(defun consent--macro-option-name (datum description)
  "Return DATUM as an option-name string for DESCRIPTION."
  (or (consent--symbol-name datum)
      (and (symbolp datum) (symbol-name datum))
      (and (stringp datum) datum)
      (consent--eval-error "%s option name must be a symbol" description)))

(defun consent--macro-option-integer (datum description)
  "Return DATUM as a host integer for DESCRIPTION."
  (unless (and (consent-number-p datum)
               (eq (consent-number-kind datum) 'integer)
               (eq (consent-number-exactness datum) 'exact))
    (consent--eval-error "%s option value must be an exact integer"
                              description))
  (consent-number-value datum))

(defun consent--macro-option-entry (entry)
  "Return ENTRY as a (NAME . VALUE) option pair."
  (cond
   ((and (consp entry)
         (consp (cdr entry))
         (null (cddr entry)))
    (cons (car entry) (cadr entry)))
   ((consp entry)
    (cons (car entry) (cdr entry)))
   (t
    (consent--eval-error
     "macroexpand option entry must be a pair"))))

(defun consent--macro-options-plist (options)
  "Return Emacs option plist parsed from Scheme OPTIONS datum."
  (let (plist)
    (dolist (entry (consent--proper-list-elements
                    (or options nil) "macroexpand options"))
      (let* ((pair (consent--macro-option-entry entry))
             (name (consent--macro-option-name
                    (car pair) "macroexpand"))
             (value (cdr pair)))
        (pcase name
          ("max-steps"
           (setq plist
                 (plist-put plist :max-steps
                            (consent--macro-option-integer
                             value name))))
          ("max-non-tail-steps"
           (setq plist
                 (plist-put plist :max-non-tail-steps
                            (consent--macro-option-integer
                             value name))))
          ("max-value-nodes"
           (setq plist
                 (plist-put plist :max-value-nodes
                            (consent--macro-option-integer
                             value name))))
          ("max-source-metadata"
           (setq plist
                 (plist-put plist :max-source-metadata
                            (consent--macro-option-integer
                             value name))))
          ("max-events"
           (setq plist
                 (plist-put plist :max-events
                            (consent--macro-option-integer
                             value name))))
          ("max-event-nodes"
           (setq plist
                 (plist-put plist :max-event-nodes
                            (consent--macro-option-integer
                             value name))))
          (_
           (consent--eval-error
            "unknown macroexpand option: %s" name)))))
    plist))

(defun consent--macro-introspection-context (context options)
  "Return a child expansion context from CONTEXT and Scheme OPTIONS."
  (let ((child (consent--new-eval-context
                (consent--macro-options-plist options))))
    (when context
      (setf (consent--eval-context-syntax-environment child)
            (consent--eval-context-syntax-environment context))
      (setf (consent--eval-context-libraries child)
            (consent--eval-context-libraries context))
      (setf (consent--eval-context-interaction-environment child)
            (consent--eval-context-interaction-environment context))
      (setf (consent--eval-context-base-syntax-installed child)
            (consent--eval-context-base-syntax-installed context)))
    child))

(defun consent--macro-expand-environment (environment context)
  "Return the lexical ENVIRONMENT used for macro introspection."
  (or environment
      (and context
           (consent--eval-context-interaction-environment context))
      (consent-make-base-environment)))

(defun consent--macro-active-name (form environment context)
  "Return the active macro operator name for FORM, or nil."
  (when (consp form)
    (let ((operator (car form)))
      (cond
       ((and (consent--symbol-named-p operator "let-syntax")
             (consent--special-operator-active-p operator environment))
        "let-syntax")
       ((and (consent--symbol-named-p operator "letrec-syntax")
             (consent--special-operator-active-p operator environment))
        "letrec-syntax")
       ((consent--syntax-binding-for-operator operator environment context)
        (consent--symbol-name operator))))))

(defun consent--macro-step-record (index macro-name input output)
  "Return one Scheme-readable macro expansion step record."
  (list
   (consent--macro-symbol "step")
   (consent--macro-field "index" (consent--macro-integer index))
   (consent--macro-field "macro" (consent--macro-symbol macro-name))
   (consent--macro-field
    "input" (consent--strip-identifiers input))
   (consent--macro-field
    "output" (consent--strip-identifiers output))
   (consent--macro-field "source" (consent-datum-source input))))

(defun consent--macro-visible-expanded (expanded)
  "Return EXPANDED in the readable shape used by expansion records."
  (if (consent--syntax-scope-p expanded)
      (cons (consent--macro-symbol "begin")
            (consent--syntax-scope-forms expanded))
    expanded))

(defun consent--macro-expand-target-fully
    (target environment context)
  "Fully expand TARGET, preserving local syntax scope when present."
  (if (consent--syntax-scope-p target)
      (consent--with-syntax-environment
       context
       (consent--syntax-scope-syntax-environment target)
       (lambda ()
         (cons (consent--macro-symbol "begin")
               (consent--expand-sequence-forms
                (consent--syntax-scope-forms target)
                environment
                context
                t))))
    (consent--expand-expression-fully target environment context)))

(defun consent--macro-trace-top-level
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
      (consent--note-step context)
      (let* ((macro-name
              (consent--macro-active-name current environment context))
             (expanded
              (consent--expand-expression current environment context))
             (visible-expanded
              (consent--macro-visible-expanded expanded)))
        (consent--copy-datum-source visible-expanded current)
        (if (not (eq expanded current))
            (progn
              (setq target expanded)
              (cl-incf index)
              (push (consent--macro-step-record
                     index
                     (or macro-name "syntax")
                     current
                     visible-expanded)
                    steps)
              (cl-pushnew (or macro-name "syntax") macros :test #'equal)
              (setq current visible-expanded)
              (when (or one-step (consent--syntax-scope-p expanded))
                (setq continue nil)))
          (setq target current)
          (setq continue nil))))
    (list :expanded current
          :target target
          :steps (nreverse steps)
          :macros (nreverse macros))))

(defun consent--macro-condition-datum
    (condition context environment)
  "Return CONDITION as a macro-expansion debugger condition datum."
  (consent-debugger-condition-datum
   condition context 'macro-expansion environment))

(defun consent--macro-expansion-result
    (status mode original expanded steps macros errors)
  "Build a Scheme-readable macro expansion result datum."
  (list
   (consent--macro-symbol "macro-expansion")
   (consent--macro-field "status" (consent--macro-symbol status))
   (consent--macro-field "mode" (consent--macro-symbol mode))
   (consent--macro-field
    "original" (consent--strip-identifiers original))
   (consent--macro-field
    "expanded" (if expanded
                   (consent--strip-identifiers expanded)
                 consent-false))
   (consent--macro-field "steps" steps)
   (consent--macro-field
    "macros" (mapcar #'consent--macro-symbol macros))
   (consent--macro-field "source" (consent-datum-source original))
   (consent--macro-field "warnings" nil)
   (consent--macro-field "errors" errors)))

(defun consent--macroexpand-result
    (form environment context options mode)
  "Return macro expansion introspection for FORM in MODE."
  (let* ((parent-context (or context (consent--new-eval-context nil)))
         (child-context
          (consent--macro-introspection-context parent-context options))
         (eval-environment
          (consent--macro-expand-environment environment parent-context))
         trace)
    (setf (consent--eval-context-interaction-environment child-context)
          eval-environment)
    (condition-case condition
        (progn
          (consent--ensure-base-syntax child-context eval-environment)
          (setq trace
                (consent--macro-trace-top-level
                 form eval-environment child-context (eq mode 'one-step)))
          (let ((expanded
                 (if (eq mode 'one-step)
                     (plist-get trace :expanded)
                   (consent--macro-expand-target-fully
                    (plist-get trace :target)
                    eval-environment
                    child-context))))
            (consent--macro-expansion-result
             'ok
             mode
             form
             expanded
             (plist-get trace :steps)
             (plist-get trace :macros)
             nil)))
      (error
       (consent--macro-expansion-result
        'error
        mode
        form
        nil
        (and trace (plist-get trace :steps))
        (and trace (plist-get trace :macros))
        (list (consent--macro-condition-datum
               condition child-context eval-environment)))))))

;;;###autoload
(defun consent-macroexpand
    (form &optional environment options context)
  "Return a Scheme-readable full macro expansion record for FORM."
  (consent--macroexpand-result form environment context options 'full))

;;;###autoload
(defun consent-macroexpand-1
    (form &optional environment options context)
  "Return a Scheme-readable one-step macro expansion record for FORM."
  (consent--macroexpand-result form environment context options 'one-step))

(defun consent-macro-binding-info
    (identifier &optional _environment context)
  "Return Scheme-readable syntax binding metadata for IDENTIFIER."
  (let* ((name (consent--expect-symbol-name
                identifier "macro-binding-info identifier"))
         (syntax-environment
          (and context
               (consent--eval-context-syntax-environment context)))
         (binding
          (and syntax-environment
               (consent--syntax-environment-ref syntax-environment name))))
    (if binding
        (list
         (consent--macro-symbol "macro-binding")
         (consent--macro-field "identifier"
                                    (consent--macro-symbol name))
         (consent--macro-field "status"
                                    (consent--macro-symbol "bound"))
         (consent--macro-field "kind"
                                    (consent--macro-symbol "syntax-rules"))
         (consent--macro-field "library" consent-false))
      consent-false)))

(defun consent-syntax-source (datum)
  "Return source metadata for DATUM, or #f when none is attached."
  (consent-datum-source datum))

(defun consent--macro-library-record
    (status library-name macros errors)
  "Build a Scheme-readable macro library introspection record."
  (list
   (consent--macro-symbol "macro-library")
   (consent--macro-field "status" (consent--macro-symbol status))
   (consent--macro-field
    "library" (consent--strip-identifiers library-name))
   (consent--macro-field "macros" macros)
   (consent--macro-field "warnings" nil)
   (consent--macro-field "errors" errors)))

(defun consent-macroexpand-library
    (library-name &optional environment options context)
  "Return syntax export metadata for LIBRARY-NAME."
  (let* ((parent-context (or context (consent--new-eval-context nil)))
         (child-context
          (consent--macro-introspection-context parent-context options))
         (eval-environment
          (consent--macro-expand-environment environment parent-context)))
    (setf (consent--eval-context-interaction-environment child-context)
          eval-environment)
    (condition-case condition
        (progn
          (consent--ensure-base-syntax child-context eval-environment)
          (let* ((library
                  (consent--resolve-library
                   library-name child-context eval-environment))
                 (macros
                  (sort
                   (delq nil
                         (mapcar
                          (lambda (binding)
                            (when (eq (consent--library-binding-kind
                                       binding)
                                      'syntax)
                              (list
                               (consent--macro-symbol "macro")
                               (consent--macro-symbol
                                (consent--library-binding-name
                                 binding))
                               (consent--macro-field
                                "kind"
                                (consent--macro-symbol
                                 "syntax-rules")))))
                          (consent--library-exports library)))
                   (lambda (left right)
                     (string<
                      (consent-symbol-name
                       (cadr left))
                      (consent-symbol-name
                       (cadr right)))))))
            (consent--macro-library-record
             'ok library-name macros nil)))
      (error
       (consent--macro-library-record
        'error
        library-name
        nil
        (list (consent--macro-condition-datum
               condition child-context eval-environment)))))))

(provide 'consent-macro)

;;; consent-macro.el ends here
