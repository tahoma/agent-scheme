;;; agent-scheme-base.el --- R7RS base registry and bootstrap metadata  -*- lexical-binding: t; -*-

;;; Commentary:

;; Primitive registry, portable prelude discovery, and primitive manifest
;; metadata for `(scheme base)'.  The registry is loadable without the evaluator
;; backend so tooling can inspect binding metadata independently.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-capability)

(defconst agent-scheme--base-source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Agent Scheme base registry source.")

(defcustom agent-scheme-base-prelude-file nil
  "Optional path to the portable `(scheme base)' prelude source file."
  :type '(choice (const :tag "Use bundled prelude" nil)
                 file)
  :group 'agent-scheme)

(defcustom agent-scheme-base-syntax-file nil
  "Optional path to the portable `(scheme base)' syntax prelude file."
  :type '(choice (const :tag "Use bundled syntax prelude" nil)
                 file)
  :group 'agent-scheme)

(defconst agent-scheme--scheme-base-library-key "(scheme base)"
  "Registry key for the required R7RS `(scheme base)' library.")

(declare-function agent-scheme--eval-define-syntax "agent-scheme-macro")
(declare-function agent-scheme--trampoline "agent-scheme-interpreter")

(defconst agent-scheme--base-primitive-registry
  '(("*" agent-scheme--primitive* 0 nil)
    ("+" agent-scheme--primitive+ 0 nil)
    ("-" agent-scheme--primitive- 1 nil)
    ("/" agent-scheme--primitive/ 1 nil)
    ("<" agent-scheme--primitive< 2 nil)
    ("<=" agent-scheme--primitive<= 2 nil)
    ("=" agent-scheme--primitive= 2 nil)
    (">" agent-scheme--primitive> 2 nil)
    (">=" agent-scheme--primitive>= 2 nil)
    ("apply" agent-scheme--primitive-apply 2 nil)
    ("binary-port?" agent-scheme--primitive-binary-port? 1 1)
    ("boolean=?" agent-scheme--primitive-boolean=? 2 nil)
    ("boolean?" agent-scheme--primitive-boolean? 1 1)
    ("bytevector" agent-scheme--primitive-bytevector 0 nil)
    ("bytevector-append" agent-scheme--primitive-bytevector-append 0 nil)
    ("bytevector-copy" agent-scheme--primitive-bytevector-copy 1 3)
    ("bytevector-copy!" agent-scheme--primitive-bytevector-copy! 3 5)
    ("bytevector-length" agent-scheme--primitive-bytevector-length 1 1)
    ("bytevector-u8-ref" agent-scheme--primitive-bytevector-u8-ref 2 2)
    ("bytevector-u8-set!" agent-scheme--primitive-bytevector-u8-set! 3 3)
    ("bytevector?" agent-scheme--primitive-bytevector? 1 1)
    ("call-with-current-continuation" agent-scheme--primitive-call/cc 1 1)
    ("call-with-port" agent-scheme--primitive-call-with-port 2 2)
    ("call-with-values" agent-scheme--primitive-call-with-values 2 2)
    ("call/cc" agent-scheme--primitive-call/cc 1 1)
    ("car" agent-scheme--primitive-car 1 1)
    ("cdr" agent-scheme--primitive-cdr 1 1)
    ("ceiling" agent-scheme--primitive-ceiling 1 1)
    ("char->integer" agent-scheme--primitive-char->integer 1 1)
    ("char<=?" agent-scheme--primitive-char<=? 2 nil)
    ("char<?" agent-scheme--primitive-char<? 2 nil)
    ("char=?" agent-scheme--primitive-char=? 2 nil)
    ("char>=?" agent-scheme--primitive-char>=? 2 nil)
    ("char>?" agent-scheme--primitive-char>? 2 nil)
    ("char-ready?" agent-scheme--primitive-char-ready? 0 1)
    ("char?" agent-scheme--primitive-char? 1 1)
    ("close-input-port" agent-scheme--primitive-close-input-port 1 1)
    ("close-output-port" agent-scheme--primitive-close-output-port 1 1)
    ("close-port" agent-scheme--primitive-close-port 1 1)
    ("complex?" agent-scheme--primitive-complex? 1 1)
    ("cons" agent-scheme--primitive-cons 2 2)
    ("dynamic-wind" agent-scheme--primitive-dynamic-wind 3 3)
    ("eq?" agent-scheme--primitive-eq? 2 2)
    ("equal?" agent-scheme--primitive-equal? 2 2)
    ("eqv?" agent-scheme--primitive-eqv? 2 2)
    ("eof-object" agent-scheme--primitive-eof-object 0 0)
    ("eof-object?" agent-scheme--primitive-eof-object? 1 1)
    ("error" agent-scheme--primitive-error 1 nil)
    ("error-object-irritants" agent-scheme--primitive-error-object-irritants 1 1)
    ("error-object-message" agent-scheme--primitive-error-object-message 1 1)
    ("error-object?" agent-scheme--primitive-error-object? 1 1)
    ("current-error-port" agent-scheme--primitive-current-error-port 0 0)
    ("current-input-port" agent-scheme--primitive-current-input-port 0 0)
    ("current-output-port" agent-scheme--primitive-current-output-port 0 0)
    ("denominator" agent-scheme--primitive-denominator 1 1)
    ("exact" agent-scheme--primitive-exact 1 1)
    ("exact-integer-sqrt" agent-scheme--primitive-exact-integer-sqrt 1 1)
    ("exact-integer?" agent-scheme--primitive-exact-integer? 1 1)
    ("exact?" agent-scheme--primitive-exact? 1 1)
    ("expt" agent-scheme--primitive-expt 2 2)
    ("features" agent-scheme--primitive-features 0 0)
    ("file-error?" agent-scheme--primitive-file-error? 1 1)
    ("flush-output-port" agent-scheme--primitive-flush-output-port 0 1)
    ("floor" agent-scheme--primitive-floor 1 1)
    ("floor/" agent-scheme--primitive-floor/ 2 2)
    ("floor-quotient" agent-scheme--primitive-floor-quotient 2 2)
    ("floor-remainder" agent-scheme--primitive-floor-remainder 2 2)
    ("gcd" agent-scheme--primitive-gcd 0 nil)
    ("get-output-bytevector" agent-scheme--primitive-get-output-bytevector 1 1)
    ("get-output-string" agent-scheme--primitive-get-output-string 1 1)
    ("inexact" agent-scheme--primitive-inexact 1 1)
    ("inexact?" agent-scheme--primitive-inexact? 1 1)
    ("input-port-open?" agent-scheme--primitive-input-port-open? 1 1)
    ("input-port?" agent-scheme--primitive-input-port? 1 1)
    ("integer->char" agent-scheme--primitive-integer->char 1 1)
    ("integer?" agent-scheme--primitive-integer? 1 1)
    ("lcm" agent-scheme--primitive-lcm 0 nil)
    ("list->string" agent-scheme--primitive-list->string 1 1)
    ("list->vector" agent-scheme--primitive-list->vector 1 1)
    ("list?" agent-scheme--primitive-list? 1 1)
    ("make-bytevector" agent-scheme--primitive-make-bytevector 1 2)
    ("make-parameter" agent-scheme--primitive-make-parameter 1 2)
    ("make-string" agent-scheme--primitive-make-string 1 2)
    ("make-vector" agent-scheme--primitive-make-vector 1 2)
    ("modulo" agent-scheme--primitive-modulo 2 2)
    ("newline" agent-scheme--primitive-newline 0 1)
    ("null?" agent-scheme--primitive-null? 1 1)
    ("number->string" agent-scheme--primitive-number->string 1 2)
    ("number?" agent-scheme--primitive-number? 1 1)
    ("open-input-bytevector" agent-scheme--primitive-open-input-bytevector 1 1)
    ("open-input-string" agent-scheme--primitive-open-input-string 1 1)
    ("open-output-bytevector" agent-scheme--primitive-open-output-bytevector 0 0)
    ("open-output-string" agent-scheme--primitive-open-output-string 0 0)
    ("output-port-open?" agent-scheme--primitive-output-port-open? 1 1)
    ("output-port?" agent-scheme--primitive-output-port? 1 1)
    ("numerator" agent-scheme--primitive-numerator 1 1)
    ("pair?" agent-scheme--primitive-pair? 1 1)
    ("peek-char" agent-scheme--primitive-peek-char 0 1)
    ("peek-u8" agent-scheme--primitive-peek-u8 0 1)
    ("port?" agent-scheme--primitive-port? 1 1)
    ("procedure?" agent-scheme--primitive-procedure? 1 1)
    ("quotient" agent-scheme--primitive-quotient 2 2)
    ("raise" agent-scheme--primitive-raise 1 1)
    ("raise-continuable" agent-scheme--primitive-raise-continuable 1 1)
    ("rational?" agent-scheme--primitive-rational? 1 1)
    ("rationalize" agent-scheme--primitive-rationalize 2 2)
    ("read-bytevector" agent-scheme--primitive-read-bytevector 1 2)
    ("read-bytevector!" agent-scheme--primitive-read-bytevector! 1 4)
    ("read-char" agent-scheme--primitive-read-char 0 1)
    ("read-error?" agent-scheme--primitive-read-error? 1 1)
    ("read-line" agent-scheme--primitive-read-line 0 1)
    ("read-string" agent-scheme--primitive-read-string 1 2)
    ("read-u8" agent-scheme--primitive-read-u8 0 1)
    ("real?" agent-scheme--primitive-real? 1 1)
    ("remainder" agent-scheme--primitive-remainder 2 2)
    ("round" agent-scheme--primitive-round 1 1)
    ("set-car!" agent-scheme--primitive-set-car! 2 2)
    ("set-cdr!" agent-scheme--primitive-set-cdr! 2 2)
    ("string" agent-scheme--primitive-string 0 nil)
    ("string->list" agent-scheme--primitive-string->list 1 3)
    ("string->number" agent-scheme--primitive-string->number 1 2)
    ("string->symbol" agent-scheme--primitive-string->symbol 1 1)
    ("string->utf8" agent-scheme--primitive-string->utf8 1 3)
    ("string->vector" agent-scheme--primitive-string->vector 1 3)
    ("string-append" agent-scheme--primitive-string-append 0 nil)
    ("string-copy" agent-scheme--primitive-string-copy 1 3)
    ("string-copy!" agent-scheme--primitive-string-copy! 3 5)
    ("string-fill!" agent-scheme--primitive-string-fill! 2 4)
    ("string-length" agent-scheme--primitive-string-length 1 1)
    ("string-ref" agent-scheme--primitive-string-ref 2 2)
    ("string-set!" agent-scheme--primitive-string-set! 3 3)
    ("string<=?" agent-scheme--primitive-string<=? 2 nil)
    ("string<?" agent-scheme--primitive-string<? 2 nil)
    ("string=?" agent-scheme--primitive-string=? 2 nil)
    ("string>=?" agent-scheme--primitive-string>=? 2 nil)
    ("string>?" agent-scheme--primitive-string>? 2 nil)
    ("string?" agent-scheme--primitive-string? 1 1)
    ("substring" agent-scheme--primitive-substring 3 3)
    ("symbol->string" agent-scheme--primitive-symbol->string 1 1)
    ("symbol=?" agent-scheme--primitive-symbol=? 2 nil)
    ("symbol?" agent-scheme--primitive-symbol? 1 1)
    ("textual-port?" agent-scheme--primitive-textual-port? 1 1)
    ("truncate" agent-scheme--primitive-truncate 1 1)
    ("truncate/" agent-scheme--primitive-truncate/ 2 2)
    ("truncate-quotient" agent-scheme--primitive-truncate-quotient 2 2)
    ("truncate-remainder" agent-scheme--primitive-truncate-remainder 2 2)
    ("u8-ready?" agent-scheme--primitive-u8-ready? 0 1)
    ("utf8->string" agent-scheme--primitive-utf8->string 1 3)
    ("vector" agent-scheme--primitive-vector 0 nil)
    ("vector->list" agent-scheme--primitive-vector->list 1 3)
    ("vector->string" agent-scheme--primitive-vector->string 1 3)
    ("vector-append" agent-scheme--primitive-vector-append 0 nil)
    ("vector-copy" agent-scheme--primitive-vector-copy 1 3)
    ("vector-copy!" agent-scheme--primitive-vector-copy! 3 5)
    ("vector-fill!" agent-scheme--primitive-vector-fill! 2 4)
    ("vector-length" agent-scheme--primitive-vector-length 1 1)
    ("vector-ref" agent-scheme--primitive-vector-ref 2 2)
    ("vector-set!" agent-scheme--primitive-vector-set! 3 3)
    ("vector?" agent-scheme--primitive-vector? 1 1)
    ("values" agent-scheme--primitive-values 0 nil)
    ("with-exception-handler" agent-scheme--primitive-with-exception-handler 2 2)
    ("write-bytevector" agent-scheme--primitive-write-bytevector 1 4)
    ("write-char" agent-scheme--primitive-write-char 1 2)
    ("write-string" agent-scheme--primitive-write-string 1 4)
    ("write-u8" agent-scheme--primitive-write-u8 1 2))
  "Registry of implemented `(scheme base)' primitive procedures.
Each entry is (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY).")

(defun agent-scheme-base-primitive-names ()
  "Return implemented `(scheme base)' primitive procedure names."
  (mapcar #'car agent-scheme--base-primitive-registry))

(defconst agent-scheme--primitive-mutation-names
  '("bytevector-copy!" "bytevector-u8-set!" "read-bytevector!"
    "set-car!" "set-cdr!" "string-copy!" "string-fill!" "string-set!"
    "vector-copy!" "vector-fill!" "vector-set!")
  "Kernel primitive names that mutate Agent Scheme data.")

(defconst agent-scheme--primitive-port-io-names
  '("binary-port?" "call-with-port" "char-ready?" "close-input-port"
    "close-output-port" "close-port" "eof-object" "eof-object?"
    "file-error?" "flush-output-port" "get-output-bytevector"
    "get-output-string" "input-port-open?" "input-port?" "newline"
    "open-input-bytevector" "open-input-string" "open-output-bytevector"
    "open-output-string" "output-port-open?" "output-port?" "peek-char"
    "peek-u8" "port?" "read-bytevector" "read-char" "read-error?"
    "read-line" "read-string" "read-u8" "textual-port?" "u8-ready?"
    "write-bytevector" "write-char" "write-string" "write-u8")
  "Kernel primitive names that observe or mutate port state.")

(defconst agent-scheme--primitive-control-names
  '("apply" "call-with-current-continuation" "call-with-values" "call/cc"
    "dynamic-wind" "error" "raise" "raise-continuable" "values"
    "with-exception-handler")
  "Kernel primitive names that affect evaluator control flow.")

(defun agent-scheme--primitive-effect-for-name (name)
  "Return the effect tier for primitive NAME."
  (cond
   ((member name agent-scheme--primitive-mutation-names)
    'mutation)
   ((member name agent-scheme--primitive-port-io-names)
    'port-io)
   ((member name agent-scheme--primitive-control-names)
    'control)
   ((equal name "make-parameter")
    'dynamic-state)
   (t
    'pure)))

(defun agent-scheme--primitive-emitter-hook-for-effect (effect)
  "Return a lowering hint symbol for EFFECT."
  (pcase effect
    ('mutation 'runtime-mutation)
    ('port-io 'capability-port)
    ('control 'runtime-control)
    ('dynamic-state 'runtime-parameter)
    ('host-file 'capability-file)
    ('host-process 'capability-process)
    ('host-time 'capability-time)
    ('host-repl 'capability-repl)
    ('eval 'runtime-eval)
    (_ 'inline-or-call)))

(defun agent-scheme--primitive-backend-effect-path-for-effect (effect)
  "Return the shared backend execution path for EFFECT."
  (pcase effect
    ('pure 'direct-runtime)
    ('mutation 'runtime-mutation)
    ('port-io 'runtime-port-check)
    ('control 'runtime-control)
    ('dynamic-state 'runtime-parameter)
    ((or 'host-file 'host-process 'host-time 'host-repl)
     'shared-capability-request)
    (_ 'direct-runtime)))

(defun agent-scheme--primitive-test-categories-for-name (name effect)
  "Return manifest test category symbols for primitive NAME and EFFECT."
  (let (categories)
    (when (string-match-p "bytevector" name)
      (push 'bytevector categories))
    (when (string-match-p "vector" name)
      (push 'vector categories))
    (when (string-match-p "string" name)
      (push 'string categories))
    (when (string-match-p "char" name)
      (push 'character categories))
    (when (string-match-p "symbol" name)
      (push 'symbol categories))
    (when (string-match-p "boolean" name)
      (push 'boolean categories))
    (when (member name
                  '("+" "-" "*" "/" "<" "<=" "=" ">" ">=" "ceiling"
                    "complex?" "denominator" "exact" "exact-integer-sqrt"
                    "exact-integer?" "exact?" "expt" "floor" "floor/"
                    "floor-quotient" "floor-remainder" "gcd" "inexact"
                    "inexact?" "integer?" "lcm" "modulo" "number->string"
                    "number?" "numerator" "quotient" "rational?"
                    "rationalize" "real?" "remainder" "round"
                    "string->number" "truncate" "truncate/"
                    "truncate-quotient" "truncate-remainder"))
      (push 'numeric categories))
    (when (eq effect 'port-io)
      (push 'port categories))
    (when (eq effect 'control)
      (push 'control categories))
    (unless categories
      (push 'base categories))
    (nreverse categories)))

(defun agent-scheme--base-primitive-manifest-spec (entry)
  "Return manifest metadata for base primitive registry ENTRY."
  (let* ((name (nth 0 entry))
         (hook (nth 1 entry))
         (effect (agent-scheme--primitive-effect-for-name name)))
    (list :name name
          :library agent-scheme--scheme-base-library-key
          :minimum-arity (nth 2 entry)
          :maximum-arity (nth 3 entry)
          :source 'kernel
          :effect effect
          :required-capability nil
          :emacs-hook hook
          :portable-hook
          (intern (replace-regexp-in-string
                   "\\`agent-scheme--" "" (symbol-name hook)))
          :backend-effect-path
          (agent-scheme--primitive-backend-effect-path-for-effect effect)
          :emitter-hook
          (agent-scheme--primitive-emitter-hook-for-effect effect)
          :policy-category 'pure-r7rs
          :policy 'allow
          :test-categories
          (agent-scheme--primitive-test-categories-for-name name effect))))

(defun agent-scheme-base-primitive-specs ()
  "Return discoverable metadata for implemented `(scheme base)' primitives."
  (mapcar
   (lambda (spec)
     (list :name (plist-get spec :name)
           :minimum-arity (plist-get spec :minimum-arity)
           :maximum-arity (plist-get spec :maximum-arity)
           :source (plist-get spec :source)
           :effect (plist-get spec :effect)))
   (mapcar #'agent-scheme--base-primitive-manifest-spec
           agent-scheme--base-primitive-registry)))

(defun agent-scheme--base-prelude-file ()
  "Return the portable `(scheme base)' prelude source file path."
  (or agent-scheme-base-prelude-file
      (expand-file-name
       "../scheme/agent-scheme/base-prelude.scm"
       agent-scheme--base-source-directory)))

(defun agent-scheme--base-prelude-source ()
  "Return the portable `(scheme base)' prelude source."
  (with-temp-buffer
    (insert-file-contents (agent-scheme--base-prelude-file))
    (buffer-string)))

(defun agent-scheme--base-prelude-forms ()
  "Return parsed portable prelude definition forms."
  (agent-scheme-read-all (agent-scheme--base-prelude-source)))

(defun agent-scheme--base-syntax-file ()
  "Return the portable `(scheme base)' syntax prelude source file path."
  (or agent-scheme-base-syntax-file
      (expand-file-name
       "../scheme/agent-scheme/base-syntax.scm"
       agent-scheme--base-source-directory)))

(defun agent-scheme--base-syntax-source ()
  "Return the portable `(scheme base)' syntax prelude source."
  (with-temp-buffer
    (insert-file-contents (agent-scheme--base-syntax-file))
    (buffer-string)))

(defun agent-scheme--base-syntax-forms ()
  "Return parsed portable base syntax definition forms."
  (agent-scheme-read-all (agent-scheme--base-syntax-source)))

(defun agent-scheme--formals-arity (formals)
  "Return (MINIMUM-ARITY . MAXIMUM-ARITY) for Scheme FORMALS."
  (cond
   ((agent-scheme-symbol-p formals)
    (cons 0 nil))
   (t
    (let ((cursor formals)
          (minimum 0))
      (while (consp cursor)
        (setq minimum (1+ minimum))
        (setq cursor (cdr cursor)))
      (cond
       ((null cursor)
        (cons minimum minimum))
       ((agent-scheme-symbol-p cursor)
        (cons minimum nil))
       (t
       (agent-scheme--eval-error
        "prelude definition has invalid formals")))))))

(defun agent-scheme--base-body-definition-form-p (form)
  "Return non-nil if FORM is a definition-like body form."
  (and (consp form)
       (member (agent-scheme--symbol-name (car form))
               '("define" "define-values" "define-record-type"))))

(defun agent-scheme--base-body-documentation (body &rest maybe-formals)
  "Return documentation metadata from BODY and optional FORMALS."
  (apply
   #'agent-scheme--documentation-metadata-from-body
   body
   #'agent-scheme--base-body-definition-form-p
   maybe-formals))

(defun agent-scheme--base-documentation-properties (documentation)
  "Return plist fields for optional DOCUMENTATION metadata."
  (when documentation
    (list :documentation documentation)))

(defun agent-scheme--prelude-definition-spec (form)
  "Return metadata for one portable prelude definition FORM."
  (let ((parts (agent-scheme--proper-list-elements
                form "prelude definition")))
    (unless (and (>= (length parts) 3)
                 (agent-scheme--symbol-named-p (car parts) "define"))
      (agent-scheme--eval-error "prelude form must be one definition"))
    (let ((target (cadr parts))
          arity)
      (cond
       ((agent-scheme-symbol-p target)
        (unless (= (length parts) 3)
          (agent-scheme--eval-error
           "prelude variable definition must have one initializer"))
        (let ((initializer (caddr parts)))
          (unless (and (consp initializer)
                       (agent-scheme--symbol-named-p
                        (car initializer) "lambda"))
            (agent-scheme--eval-error
             "prelude variable definition must initialize a lambda"))
          (setq arity (agent-scheme--formals-arity (cadr initializer)))
          (append
           (list :name (agent-scheme-symbol-name target)
                 :minimum-arity (car arity)
                 :maximum-arity (cdr arity)
                 :source 'prelude)
           (agent-scheme--base-documentation-properties
            (agent-scheme--base-body-documentation
             (cddr initializer)
             (cadr initializer))))))
       ((consp target)
        (setq arity (agent-scheme--formals-arity (cdr target)))
        (append
         (list :name (agent-scheme--expect-symbol-name
                      (car target) "prelude function name")
               :minimum-arity (car arity)
               :maximum-arity (cdr arity)
               :source 'prelude)
         (agent-scheme--base-documentation-properties
          (agent-scheme--base-body-documentation
           (cddr parts)
           (cdr target)))))
       (t
        (agent-scheme--eval-error
         "prelude define target must be an identifier or function signature"))))))

(defun agent-scheme-base-prelude-binding-specs ()
  "Return discoverable metadata for portable prelude bindings."
  (mapcar #'agent-scheme--prelude-definition-spec
          (agent-scheme--base-prelude-forms)))

(defun agent-scheme-base-prelude-binding-names ()
  "Return names supplied by the portable `(scheme base)' prelude."
  (mapcar (lambda (spec) (plist-get spec :name))
          (agent-scheme-base-prelude-binding-specs)))

(defun agent-scheme-base-binding-specs ()
  "Return discoverable metadata for kernel and prelude base bindings."
  (append (agent-scheme-base-primitive-specs)
          (agent-scheme-base-prelude-binding-specs)))

(defconst agent-scheme--standard-primitive-manifest-specs
  '((:name "delete-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-delete-file
     :portable-hook primitive-delete-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "file-exists?" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-file-exists?
     :portable-hook primitive-file-exists? :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "call-with-input-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-call-with-input-file
     :portable-hook primitive-call-with-input-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "call-with-output-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-call-with-output-file
     :portable-hook primitive-call-with-output-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-binary-input-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-binary-input-file
     :portable-hook primitive-open-binary-input-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-binary-output-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-binary-output-file
     :portable-hook primitive-open-binary-output-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-input-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-input-file
     :portable-hook primitive-open-input-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "open-output-file" :library "(scheme file)" :minimum-arity 1
     :maximum-arity 1 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-open-output-file
     :portable-hook primitive-open-output-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "with-input-from-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-with-input-from-file
     :portable-hook primitive-with-input-from-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "with-output-to-file" :library "(scheme file)" :minimum-arity 2
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-with-output-to-file
     :portable-hook primitive-with-output-to-file :emitter-hook capability-file
     :policy deny :test-categories (file policy))
    (:name "load" :library "(scheme load)" :minimum-arity 1
     :maximum-arity 2 :source host-capability :effect host-file
     :required-capability file-system :emacs-hook agent-scheme--primitive-load
     :portable-hook primitive-load :emitter-hook capability-file
     :policy deny :test-categories (load file policy))
    (:name "command-line" :library "(scheme process-context)" :minimum-arity 0
     :maximum-arity nil :source host-capability :effect host-process
     :required-capability process-environment :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "emergency-exit" :library "(scheme process-context)" :minimum-arity 0
     :maximum-arity nil :source host-capability :effect host-process
     :required-capability process-environment :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "exit" :library "(scheme process-context)" :minimum-arity 0
     :maximum-arity nil :source host-capability :effect host-process
     :required-capability process-environment :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "get-environment-variable" :library "(scheme process-context)"
     :minimum-arity 0 :maximum-arity nil :source host-capability
     :effect host-process :required-capability process-environment
     :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "get-environment-variables" :library "(scheme process-context)"
     :minimum-arity 0 :maximum-arity nil :source host-capability
     :effect host-process :required-capability process-environment
     :emacs-hook agent-scheme--policy-denied-primitive
     :portable-hook policy-denied-primitive :emitter-hook capability-process
     :policy deny :test-categories (process policy))
    (:name "interaction-environment" :library "(scheme repl)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-repl
     :required-capability repl :emacs-hook agent-scheme--primitive-interaction-environment
     :portable-hook primitive-interaction-environment
     :emitter-hook capability-repl
     :policy session :test-categories (repl policy session))
    (:name "current-jiffy" :library "(scheme time)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-time
     :required-capability clock :emacs-hook agent-scheme--primitive-current-jiffy
     :portable-hook primitive-current-jiffy :emitter-hook capability-time
     :policy grant :test-categories (time policy clock))
    (:name "current-second" :library "(scheme time)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-time
     :required-capability clock :emacs-hook agent-scheme--primitive-current-second
     :portable-hook primitive-current-second :emitter-hook capability-time
     :policy grant :test-categories (time policy clock))
    (:name "jiffies-per-second" :library "(scheme time)" :minimum-arity 0
     :maximum-arity 0 :source host-capability :effect host-time
     :required-capability clock
     :emacs-hook agent-scheme--primitive-jiffies-per-second
     :portable-hook primitive-jiffies-per-second
     :emitter-hook capability-time
     :policy grant :test-categories (time policy clock)))
  "Explicit manifest metadata for host-effecting standard primitives.")

(defun agent-scheme-standard-primitive-binding-specs ()
  "Return manifest metadata for standard-library primitive bindings."
  (mapcar
   (lambda (spec)
     (append spec
             (list :backend-effect-path 'shared-capability-request
                   :policy-category 'standard-host-effect)))
   agent-scheme--standard-primitive-manifest-specs))

(defun agent-scheme--prelude-manifest-spec (spec)
  "Return manifest metadata for portable prelude SPEC."
  (let ((name (plist-get spec :name))
        (effect 'pure))
    (append spec
            (list :library agent-scheme--scheme-base-library-key
                  :effect effect
                  :required-capability nil
                  :emacs-hook nil
                  :portable-hook nil
                  :backend-effect-path 'direct-runtime
                  :emitter-hook 'inline-or-call
                  :policy-category 'pure-r7rs
                  :policy 'allow
                  :test-categories
                  (agent-scheme--primitive-test-categories-for-name
                   name effect)))))

(defun agent-scheme-primitive-manifest-binding-specs ()
  "Return canonical primitive and effect metadata records.
Each record is inspectable data with name, library, arity, source, effect,
capability, interpreter hooks, emitter hint, policy, and test categories."
  (append
   (mapcar #'agent-scheme--base-primitive-manifest-spec
           agent-scheme--base-primitive-registry)
   (mapcar #'agent-scheme--prelude-manifest-spec
           (agent-scheme-base-prelude-binding-specs))
   (agent-scheme-standard-primitive-binding-specs)
   (agent-scheme-emacs-capability-binding-specs)))

(defun agent-scheme--define-primitive
    (environment name function minimum-arity maximum-arity)
  "Register primitive NAME in ENVIRONMENT."
  (agent-scheme--environment-define
   environment
   name
   (agent-scheme--make-primitive-procedure
    name function minimum-arity maximum-arity)))

(defun agent-scheme-make-base-environment ()
  "Return a fresh environment with kernel and prelude `(scheme base)' bindings."
  (let ((environment (agent-scheme-make-empty-environment)))
    (dolist (entry agent-scheme--base-primitive-registry)
      (agent-scheme--define-primitive
       environment
       (nth 0 entry)
       (nth 1 entry)
       (nth 2 entry)
       (nth 3 entry)))
    ;; Derived base procedures are ordinary Scheme definitions evaluated by the
    ;; same trampoline.  This keeps the bootstrap surface inspectable.
    (agent-scheme--trampoline
     (agent-scheme--make-sequence (agent-scheme--base-prelude-forms) t)
     environment
     (agent-scheme--new-eval-context nil))
    environment))

(defun agent-scheme--ensure-base-syntax (context environment)
  "Install base derived syntax into CONTEXT once, capturing ENVIRONMENT."
  (unless (agent-scheme--eval-context-base-syntax-installed context)
    (dolist (form (agent-scheme--base-syntax-forms))
      (agent-scheme--eval-define-syntax
       form
       environment
       context
       (agent-scheme--eval-context-syntax-environment context)))
    (setf (agent-scheme--eval-context-base-syntax-installed context) t)))

(provide 'agent-scheme-base)

;;; agent-scheme-base.el ends here
