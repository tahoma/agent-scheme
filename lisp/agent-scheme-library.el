;;; agent-scheme-library.el --- R7RS library resolver support  -*- lexical-binding: t; -*-

;;; Commentary:

;; Library records, source-library discovery, import-set resolution, and
;; define-library bootstrap support.  This module is loadable without the
;; evaluator backend; functions that evaluate library bodies use backend hooks
;; supplied by `agent-scheme-eval' after it loads.

;;; Code:

(require 'cl-lib)
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)
(require 'agent-scheme-base)
(require 'agent-scheme-capability)
(require 'agent-scheme-agent-io)
(require 'agent-scheme-approval)
(require 'agent-scheme-memory)
(require 'agent-scheme-redaction)
(require 'agent-scheme-session)
(require 'agent-scheme-policy)

(defconst agent-scheme--library-source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Agent Scheme library source.")

(declare-function agent-scheme--make-empty-syntax-environment "agent-scheme-macro")
(declare-function agent-scheme--policy-denied "agent-scheme-interpreter")
(declare-function agent-scheme--syntax-environment-ref "agent-scheme-macro")
(declare-function agent-scheme--trampoline "agent-scheme-interpreter")
(declare-function agent-scheme--with-syntax-environment "agent-scheme-macro")

(cl-defstruct (agent-scheme--library-binding
               (:constructor agent-scheme--make-library-binding
                             (name kind object library-key))
               (:copier nil))
  "One exported or imported library binding."
  name kind object library-key)

(cl-defstruct (agent-scheme--library
               (:constructor agent-scheme--make-library
                             (name key exports value-environment
                                   syntax-environment))
               (:copier nil))
  "Loaded Scheme library with explicit environments and exports."
  name key exports value-environment syntax-environment)

(defconst agent-scheme--standard-library-keys
  '("(scheme case-lambda)"
    "(scheme char)"
    "(scheme complex)"
    "(scheme cxr)"
    "(scheme eval)"
    "(scheme file)"
    "(scheme inexact)"
    "(scheme lazy)"
    "(scheme load)"
    "(scheme process-context)"
    "(scheme read)"
    "(scheme repl)"
    "(scheme r5rs)"
    "(scheme time)"
    "(scheme write)")
  "Standard R7RS library keys with focused bootstrap support.")

(defconst agent-scheme--agent-library-keys
  '("(agent io)"
    "(agent approval)"
    "(agent capability)"
    "(agent capability primitive)"
    "(agent memory)"
    "(agent redaction)"
    "(agent session)")
  "Agent interaction library keys with focused bootstrap support.")

(defconst agent-scheme--agent-source-library-files
  '(("(agent capability)"
     . "../scheme/agent/capability.sld"))
  "Checked-in portable Agent Scheme libraries loaded as Scheme source.")

;; Bootstrap libraries are registered lazily into the current evaluation
;; context.  The required `(scheme base)' library snapshots the active base
;; environment, while smaller standard libraries are either subsets, primitive
;; wrappers, or source libraries expanded through the same evaluator.

(defconst agent-scheme--standard-source-library-files
  '(("(scheme case-lambda)"
     . "../scheme/standard-library/case-lambda.sld")
    ("(scheme lazy)"
     . "../scheme/standard-library/lazy.sld"))
  "Checked-in portable standard libraries loaded as Scheme source.")

(defun agent-scheme--standard-source-library-file (key)
  "Return the bundled source file path for standard library KEY."
  (let ((relative-file
         (cdr (assoc key agent-scheme--standard-source-library-files))))
    (unless relative-file
      (agent-scheme--eval-error
       "standard source library is not available: %s" key))
    (expand-file-name relative-file agent-scheme--library-source-directory)))

(defun agent-scheme--standard-source-library-source (key)
  "Return the checked-in source for standard library KEY."
  (let ((source-file (agent-scheme--standard-source-library-file key)))
    (unless (file-readable-p source-file)
      (agent-scheme--eval-error
       "standard source library file is not readable: %s" source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (buffer-string))))

(defun agent-scheme--agent-source-library-file (key)
  "Return the bundled source file path for Agent library KEY."
  (let ((relative-file
         (cdr (assoc key agent-scheme--agent-source-library-files))))
    (unless relative-file
      (agent-scheme--eval-error
       "agent source library is not available: %s" key))
    (expand-file-name relative-file agent-scheme--library-source-directory)))

(defun agent-scheme--agent-source-library-source (key)
  "Return the checked-in source for Agent library KEY."
  (let ((source-file (agent-scheme--agent-source-library-file key)))
    (unless (file-readable-p source-file)
      (agent-scheme--eval-error
       "agent source library file is not readable: %s" source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (buffer-string))))

(defun agent-scheme--standard-source-library-form (key)
  "Return the single define-library form read from KEY's source file."
  (let ((forms (agent-scheme-read-all
                (agent-scheme--standard-source-library-source key))))
    (unless (= (length forms) 1)
      (agent-scheme--eval-error
       "standard source library must contain exactly one form: %s" key))
    (let* ((form (car forms))
           (parts (agent-scheme--proper-list-elements
                   form "standard source library")))
      (unless (and (>= (length parts) 2)
                   (agent-scheme--symbol-named-p
                    (car parts) "define-library")
                   (equal (agent-scheme-datum->external
                           (agent-scheme--strip-identifiers (cadr parts)))
                          key))
        (agent-scheme--eval-error
         "standard source library name does not match registry key: %s" key))
      form)))

(defun agent-scheme--standard-source-library-export-names (form)
  "Return external export names declared by source library FORM."
  (let ((parts (agent-scheme--proper-list-elements
                form "standard source library"))
        exports)
    (dolist (declaration (cddr parts))
      (when (agent-scheme--form-named-p declaration "export")
        (setq exports
              (append exports
                      (mapcar
                       #'cdr
                       (agent-scheme--export-specs
                        (cdr (agent-scheme--proper-list-elements
                              declaration "standard source export"))))))))
    exports))

(defun agent-scheme-standard-source-library-specs ()
  "Return metadata for standard libraries loaded from portable source files."
  (mapcar
   (lambda (entry)
     (let* ((key (car entry))
            (form (agent-scheme--standard-source-library-form key)))
       (list :name key
             :exports
             (agent-scheme--standard-source-library-export-names form)
             :source-file
             (agent-scheme--standard-source-library-file key))))
   agent-scheme--standard-source-library-files))

(defun agent-scheme--nonnegative-exact-integer-datum-p (datum)
  "Return non-nil if DATUM is an exact non-negative integer datum."
  (and (agent-scheme-number-p datum)
       (eq (agent-scheme-number-kind datum) 'integer)
       (eq (agent-scheme-number-exactness datum) 'exact)
       (>= (agent-scheme-number-value datum) 0)))

(defun agent-scheme--library-name-p (datum)
  "Return non-nil if DATUM is a valid R7RS library name datum."
  (and (consp datum)
       (let ((parts (agent-scheme--proper-list-elements-maybe datum)))
         (and parts
              (cl-every
               (lambda (part)
                 (or (agent-scheme-symbol-p part)
                     (agent-scheme--nonnegative-exact-integer-datum-p part)))
               parts)))))

(defun agent-scheme--library-name-key (name)
  "Return the registry key for library NAME."
  (unless (agent-scheme--library-name-p name)
    (agent-scheme--eval-error
     "invalid library name: %s" (agent-scheme-value->external name)))
  (agent-scheme-datum->external (agent-scheme--strip-identifiers name)))

(defun agent-scheme--current-environment-cell (environment name)
  "Return NAME's cell in ENVIRONMENT's current frame, or nil."
  (let ((cell (gethash name
                       (agent-scheme--environment-bindings environment)
                       agent-scheme--missing-cell)))
    (unless (eq cell agent-scheme--missing-cell)
      cell)))

(defun agent-scheme--current-syntax-binding (syntax-environment name)
  "Return NAME's binding in SYNTAX-ENVIRONMENT's current frame, or nil."
  (let ((binding (gethash
                  name
                  (agent-scheme--syntax-environment-bindings
                   syntax-environment)
                  agent-scheme--missing-cell)))
    (unless (eq binding agent-scheme--missing-cell)
      binding)))

(defun agent-scheme--form-named-p (form name)
  "Return non-nil when FORM is a list beginning with identifier NAME."
  (and (consp form)
       (agent-scheme--symbol-named-p (car form) name)))

(defun agent-scheme--import-form-p (form)
  "Return non-nil if FORM is an import declaration."
  (agent-scheme--form-named-p form "import"))

(defun agent-scheme--define-library-form-p (form)
  "Return non-nil if FORM is a define-library form."
  (agent-scheme--form-named-p form "define-library"))

(defun agent-scheme--library-binding-with-name (binding name)
  "Return BINDING renamed to local NAME."
  (agent-scheme--make-library-binding
   name
   (agent-scheme--library-binding-kind binding)
   (agent-scheme--library-binding-object binding)
   (agent-scheme--library-binding-library-key binding)))

(defun agent-scheme--same-library-binding-p (left right)
  "Return non-nil if LEFT and RIGHT identify the same imported binding."
  (and (agent-scheme--library-binding-p left)
       (agent-scheme--library-binding-p right)
       (eq (agent-scheme--library-binding-kind left)
           (agent-scheme--library-binding-kind right))
       (eq (agent-scheme--library-binding-object left)
           (agent-scheme--library-binding-object right))))

(defun agent-scheme--snapshot-library-bindings
    (value-environment syntax-environment library-key)
  "Return exported bindings from VALUE-ENVIRONMENT and SYNTAX-ENVIRONMENT."
  (let (exports)
    (maphash
     (lambda (name cell)
       (push (agent-scheme--make-library-binding
              name 'value cell library-key)
             exports))
     (agent-scheme--environment-bindings value-environment))
    (maphash
     (lambda (name transformer)
       (push (agent-scheme--make-library-binding
              name 'syntax transformer library-key)
             exports))
     (agent-scheme--syntax-environment-bindings syntax-environment))
    (nreverse exports)))

(defun agent-scheme--register-scheme-base-library
    (context environment)
  "Register the builtin `(scheme base)' library in CONTEXT."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash agent-scheme--scheme-base-library-key registry)
      (let* ((use-current-environment
              (agent-scheme--environment-cell environment "+"))
             (base-environment
              (if use-current-environment
                  environment
                (agent-scheme-make-base-environment)))
             (base-context
              (if use-current-environment
                  context
                (agent-scheme--new-eval-context nil))))
        (unless use-current-environment
          (agent-scheme--ensure-base-syntax
           base-context base-environment))
        (let* ((syntax-environment
                (agent-scheme--eval-context-syntax-environment
                 base-context))
               (exports
                (agent-scheme--snapshot-library-bindings
                 base-environment
                 syntax-environment
                 agent-scheme--scheme-base-library-key)))
          (puthash
           agent-scheme--scheme-base-library-key
           (agent-scheme--make-library
            (list (agent-scheme--syntax-symbol "scheme")
                  (agent-scheme--syntax-symbol "base"))
            agent-scheme--scheme-base-library-key
            exports
            base-environment
            syntax-environment)
           registry))))))

(defun agent-scheme--register-emacs-capability-library
    (key context)
  "Register an Emacs capability library named by KEY."
  (agent-scheme--register-primitive-library
   key
   (agent-scheme-emacs-capability-primitive-specs key)
   context))

(defun agent-scheme--register-agent-library
    (key context environment)
  "Register Agent interaction library KEY in CONTEXT."
  (pcase key
    ("(agent io)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme-agent-io-primitive-specs)
      context))
    ("(agent approval)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme-approval-primitive-specs)
      context))
    ("(agent capability)"
     (unless (gethash key (agent-scheme--eval-context-libraries context))
       (agent-scheme--register-source-library
        (agent-scheme--agent-source-library-source key) context environment)))
    ("(agent capability primitive)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme-capability-primitive-specs)
      context))
    ("(agent memory)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme-memory-primitive-specs)
      context))
    ("(agent redaction)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme-redaction-primitive-specs)
      context))
    ("(agent session)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme-session-primitive-specs)
      context))
    (_
     (agent-scheme--eval-error "unknown agent library: %s" key))))

(defun agent-scheme--register-source-library
    (source context environment)
  "Evaluate one define-library SOURCE into CONTEXT."
  (let ((forms (agent-scheme-read-all source)))
    (unless (= (length forms) 1)
      (agent-scheme--eval-error
       "source library must contain exactly one form"))
    (agent-scheme--eval-define-library
     (car forms)
     environment
     context)))

(defun agent-scheme--find-library-export (name exports)
  "Return export named NAME from EXPORTS, or nil."
  (cl-find name exports
           :key #'agent-scheme--library-binding-name
           :test #'equal))

(defun agent-scheme--register-subset-library
    (key export-names context environment)
  "Register KEY as a subset of `(scheme base)' EXPORT-NAMES."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (agent-scheme--resolve-library
               (agent-scheme-read agent-scheme--scheme-base-library-key)
               context
               environment))
             (base-exports
              (agent-scheme--library-exports base-library))
             (exports
              (mapcar
               (lambda (name)
                 (or (agent-scheme--find-library-export
                      name base-exports)
                     (agent-scheme--eval-error
                      "standard library binding is not available: %s"
                      name)))
               export-names)))
        (puthash
         key
         (agent-scheme--make-library
          (agent-scheme-read key)
          key
          exports
          (agent-scheme--library-value-environment base-library)
          (agent-scheme--library-syntax-environment base-library))
         registry)))))

(defun agent-scheme--register-primitive-library
    (key primitive-specs context)
  "Register KEY with PRIMITIVE-SPECS.
Each spec has (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY)."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash key registry)
      (let ((value-environment (agent-scheme-make-empty-environment))
            (syntax-environment
             (agent-scheme--make-empty-syntax-environment)))
        (dolist (spec primitive-specs)
          (agent-scheme--define-primitive
           value-environment
           (nth 0 spec)
           (nth 1 spec)
           (nth 2 spec)
           (nth 3 spec)))
        (puthash
         key
         (agent-scheme--make-library
          (agent-scheme-read key)
          key
          (agent-scheme--snapshot-library-bindings
           value-environment syntax-environment key)
          value-environment
          syntax-environment)
         registry)))))

(defun agent-scheme--cxr-primitive (name)
  "Return a primitive procedure implementation for composed accessor NAME."
  (let ((steps (reverse (string-to-list
                         (substring name 1 (1- (length name)))))))
    (lambda (arguments _context)
      (let ((value (car arguments)))
        (dolist (step steps)
          (setq value
                (if (= step ?a)
                    (agent-scheme--primitive-car (list value) nil)
                  (agent-scheme--primitive-cdr (list value) nil))))
        value))))

(defconst agent-scheme--cxr-library-names
  '("caaar" "caadr" "cadar" "caddr"
    "cdaar" "cdadr" "cddar" "cdddr"
    "caaaar" "caaadr" "caadar" "caaddr"
    "cadaar" "cadadr" "caddar" "cadddr"
    "cdaaar" "cdaadr" "cdadar" "cdaddr"
    "cddaar" "cddadr" "cdddar" "cddddr")
  "R7RS `(scheme cxr)' three- and four-level accessors.")

(defun agent-scheme--cxr-primitive-specs ()
  "Return primitive specs for `(scheme cxr)'."
  (mapcar
   (lambda (name)
     (list name (agent-scheme--cxr-primitive name) 1 1))
   agent-scheme--cxr-library-names))

(defun agent-scheme--policy-denied-spec (name)
  "Return a primitive spec for default-denied host effect NAME."
  (list name
        (lambda (_arguments context)
          (agent-scheme--policy-denied name context))
        0
        nil))

(defun agent-scheme--register-r5rs-library (key context environment)
  "Register the practical `(scheme r5rs)' compatibility library KEY."
  (let ((registry (agent-scheme--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (agent-scheme--resolve-library
               (agent-scheme-read agent-scheme--scheme-base-library-key)
               context
               environment))
             (exports (copy-sequence (agent-scheme--library-exports
                                       base-library)))
             (inexact-binding
              (agent-scheme--find-library-export "inexact" exports))
             (exact-binding
              (agent-scheme--find-library-export "exact" exports)))
        (push (agent-scheme--library-binding-with-name
               inexact-binding "exact->inexact")
              exports)
        (push (agent-scheme--library-binding-with-name
               exact-binding "inexact->exact")
              exports)
        (puthash
         key
         (agent-scheme--make-library
          (agent-scheme-read key)
          key
          (nreverse exports)
          (agent-scheme--library-value-environment base-library)
          (agent-scheme--library-syntax-environment base-library))
         registry)))))

(defun agent-scheme--register-standard-library
    (key context environment)
  "Register focused standard library KEY in CONTEXT."
  (pcase key
    ("(scheme case-lambda)"
     (agent-scheme--register-source-library
      (agent-scheme--standard-source-library-source key) context environment))
    ("(scheme char)"
     (agent-scheme--register-primitive-library
      key
      `(("char-alphabetic?" ,#'agent-scheme--primitive-char-alphabetic? 1 1)
        ("char-ci<=?" ,#'agent-scheme--primitive-char-ci<=? 2 nil)
        ("char-ci<?" ,#'agent-scheme--primitive-char-ci<? 2 nil)
        ("char-ci=?" ,#'agent-scheme--primitive-char-ci=? 2 nil)
        ("char-ci>=?" ,#'agent-scheme--primitive-char-ci>=? 2 nil)
        ("char-ci>?" ,#'agent-scheme--primitive-char-ci>? 2 nil)
        ("char-downcase" ,#'agent-scheme--primitive-char-downcase 1 1)
        ("char-foldcase" ,#'agent-scheme--primitive-char-foldcase 1 1)
        ("char-lower-case?" ,#'agent-scheme--primitive-char-lower-case? 1 1)
        ("char-numeric?" ,#'agent-scheme--primitive-char-numeric? 1 1)
        ("char-upcase" ,#'agent-scheme--primitive-char-upcase 1 1)
        ("char-upper-case?" ,#'agent-scheme--primitive-char-upper-case? 1 1)
        ("char-whitespace?" ,#'agent-scheme--primitive-char-whitespace? 1 1)
        ("digit-value" ,#'agent-scheme--primitive-digit-value 1 1)
        ("string-ci<=?" ,#'agent-scheme--primitive-string-ci<=? 2 nil)
        ("string-ci<?" ,#'agent-scheme--primitive-string-ci<? 2 nil)
        ("string-ci=?" ,#'agent-scheme--primitive-string-ci=? 2 nil)
        ("string-ci>=?" ,#'agent-scheme--primitive-string-ci>=? 2 nil)
        ("string-ci>?" ,#'agent-scheme--primitive-string-ci>? 2 nil)
        ("string-downcase" ,#'agent-scheme--primitive-string-downcase 1 1)
        ("string-foldcase" ,#'agent-scheme--primitive-string-foldcase 1 1)
        ("string-upcase" ,#'agent-scheme--primitive-string-upcase 1 1))
      context))
    ("(scheme complex)"
     (agent-scheme--register-primitive-library
      key
      `(("angle" ,#'agent-scheme--primitive-angle 1 1)
        ("imag-part" ,#'agent-scheme--primitive-imag-part 1 1)
        ("magnitude" ,#'agent-scheme--primitive-magnitude 1 1)
        ("make-polar" ,#'agent-scheme--primitive-make-polar 2 2)
        ("make-rectangular" ,#'agent-scheme--primitive-make-rectangular 2 2)
        ("real-part" ,#'agent-scheme--primitive-real-part 1 1))
      context))
    ("(scheme cxr)"
     (agent-scheme--register-primitive-library
      key
      (agent-scheme--cxr-primitive-specs)
      context))
    ("(scheme eval)"
     (agent-scheme--register-primitive-library
      key
      `(("environment" ,#'agent-scheme--primitive-environment 1 nil)
        ("eval" ,#'agent-scheme--primitive-eval 2 2))
      context))
    ("(scheme file)"
     (agent-scheme--register-primitive-library
      key
      `(("call-with-input-file" ,(cadr (agent-scheme--policy-denied-spec
                                        "call-with-input-file")) 2 2)
        ("call-with-output-file" ,(cadr (agent-scheme--policy-denied-spec
                                         "call-with-output-file")) 2 2)
        ("delete-file" ,#'agent-scheme--primitive-delete-file 1 1)
        ("file-exists?" ,#'agent-scheme--primitive-file-exists? 1 1)
        ("open-binary-input-file" ,(cadr (agent-scheme--policy-denied-spec
                                          "open-binary-input-file")) 1 1)
        ("open-binary-output-file" ,(cadr (agent-scheme--policy-denied-spec
                                           "open-binary-output-file")) 1 1)
        ("open-input-file" ,(cadr (agent-scheme--policy-denied-spec
                                   "open-input-file")) 1 1)
        ("open-output-file" ,(cadr (agent-scheme--policy-denied-spec
                                    "open-output-file")) 1 1)
        ("with-input-from-file" ,(cadr (agent-scheme--policy-denied-spec
                                        "with-input-from-file")) 2 2)
        ("with-output-to-file" ,(cadr (agent-scheme--policy-denied-spec
                                       "with-output-to-file")) 2 2))
      context))
    ("(scheme inexact)"
     (agent-scheme--register-primitive-library
      key
      `(("acos" ,#'agent-scheme--primitive-acos 1 1)
        ("asin" ,#'agent-scheme--primitive-asin 1 1)
        ("atan" ,#'agent-scheme--primitive-atan 1 2)
        ("cos" ,#'agent-scheme--primitive-cos 1 1)
        ("exp" ,#'agent-scheme--primitive-exp 1 1)
        ("finite?" ,#'agent-scheme--primitive-finite? 1 1)
        ("infinite?" ,#'agent-scheme--primitive-infinite? 1 1)
        ("log" ,#'agent-scheme--primitive-log 1 2)
        ("nan?" ,#'agent-scheme--primitive-nan? 1 1)
        ("sin" ,#'agent-scheme--primitive-sin 1 1)
        ("sqrt" ,#'agent-scheme--primitive-sqrt 1 1)
        ("tan" ,#'agent-scheme--primitive-tan 1 1))
      context))
    ("(scheme lazy)"
     (agent-scheme--register-source-library
      (agent-scheme--standard-source-library-source key) context environment))
    ("(scheme load)"
     (agent-scheme--register-primitive-library
      key
      `(("load" ,#'agent-scheme--primitive-load 1 2))
      context))
    ("(scheme process-context)"
     (agent-scheme--register-primitive-library
      key
      (mapcar #'agent-scheme--policy-denied-spec
              '("command-line"
                "emergency-exit"
                "exit"
                "get-environment-variable"
                "get-environment-variables"))
      context))
    ("(scheme read)"
     (agent-scheme--register-primitive-library
      key
      `(("read" ,#'agent-scheme--primitive-read 0 1))
      context))
    ("(scheme repl)"
     (agent-scheme--register-primitive-library
      key
      (list (agent-scheme--policy-denied-spec "interaction-environment"))
      context))
    ("(scheme r5rs)"
     (agent-scheme--register-r5rs-library key context environment))
    ("(scheme time)"
     (agent-scheme--register-primitive-library
      key
      (mapcar #'agent-scheme--policy-denied-spec
              '("current-jiffy" "current-second" "jiffies-per-second"))
      context))
    ("(scheme write)"
     (agent-scheme--register-primitive-library
      key
      `(("display" ,#'agent-scheme--primitive-display 1 2)
        ("write" ,#'agent-scheme--primitive-write 1 2)
        ("write-shared" ,#'agent-scheme--primitive-write-shared 1 2)
        ("write-simple" ,#'agent-scheme--primitive-write-simple 1 2))
      context))
    (_
     (agent-scheme--eval-error "unknown standard library: %s" key))))

(defun agent-scheme--library-available-p (name context environment)
  "Return non-nil if NAME can be imported."
  (let ((key (agent-scheme--library-name-key name)))
    (cond
     ((equal key agent-scheme--scheme-base-library-key)
      t)
     ((member key agent-scheme--standard-library-keys)
      t)
     ((member key agent-scheme--agent-library-keys)
      t)
     ((member key (agent-scheme-emacs-capability-library-keys))
      t)
     (t
      (and (gethash key (agent-scheme--eval-context-libraries context))
           t)))))

(defun agent-scheme--resolve-library (name context environment)
  "Return library NAME from CONTEXT, registering builtins when needed."
  (let ((key (agent-scheme--library-name-key name)))
    (cond
     ((equal key agent-scheme--scheme-base-library-key)
      (agent-scheme--register-scheme-base-library context environment))
     ((member key agent-scheme--standard-library-keys)
      (agent-scheme--register-standard-library key context environment))
     ((member key agent-scheme--agent-library-keys)
      (agent-scheme--register-agent-library key context environment))
     ((member key (agent-scheme-emacs-capability-library-keys))
      (agent-scheme--register-emacs-capability-library key context)))
    (or (gethash key (agent-scheme--eval-context-libraries context))
        (agent-scheme--eval-error "unknown library: %s" key))))

(defun agent-scheme--import-binding-local-name (binding)
  "Return BINDING's local import name."
  (agent-scheme--library-binding-name binding))

(defun agent-scheme--find-import-binding (name bindings)
  "Return import binding named NAME from BINDINGS, or nil."
  (cl-find name bindings
           :key #'agent-scheme--import-binding-local-name
           :test #'equal))

(defun agent-scheme--ensure-import-names-present
    (names bindings description)
  "Signal if any NAMES are absent from BINDINGS for DESCRIPTION."
  (dolist (name names)
    (unless (agent-scheme--find-import-binding name bindings)
      (agent-scheme--eval-error
       "%s import name not found: %s" description name))))

(defun agent-scheme--ensure-compatible-import-bindings (bindings)
  "Return BINDINGS after checking for duplicate incompatible names."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (binding bindings)
      (let* ((name (agent-scheme--library-binding-name binding))
             (previous (gethash name seen)))
        (cond
         ((null previous)
          (puthash name binding seen)
          (push binding result))
         ((agent-scheme--same-library-binding-p previous binding))
         (t
          (agent-scheme--eval-error
           "conflicting imports for identifier: %s" name)))))
    (nreverse result)))

(defun agent-scheme--import-modifier-identifiers (forms description)
  "Return FORMS as identifier name strings for DESCRIPTION."
  (mapcar
   (lambda (form)
     (agent-scheme--expect-symbol-name form description))
   forms))

(defun agent-scheme--resolve-import-set
    (import-set context environment)
  "Resolve IMPORT-SET to a list of library bindings."
  (cond
   ((agent-scheme--library-name-p import-set)
    (copy-sequence
     (agent-scheme--library-exports
      (agent-scheme--resolve-library import-set context environment))))
   ((consp import-set)
    (let* ((parts (agent-scheme--proper-list-elements
                   import-set "import set"))
           (operator (car parts)))
      (cond
       ((agent-scheme--symbol-named-p operator "only")
        (unless (>= (length parts) 2)
          (agent-scheme--eval-error "only import set requires an import set"))
        (let* ((bindings
                (agent-scheme--resolve-import-set
                 (cadr parts) context environment))
               (names
                (agent-scheme--import-modifier-identifiers
                 (cddr parts) "only")))
          (agent-scheme--ensure-import-names-present names bindings "only")
          (cl-remove-if-not
           (lambda (binding)
             (member (agent-scheme--library-binding-name binding)
                     names))
           bindings)))
       ((agent-scheme--symbol-named-p operator "except")
        (unless (>= (length parts) 2)
          (agent-scheme--eval-error
           "except import set requires an import set"))
        (let* ((bindings
                (agent-scheme--resolve-import-set
                 (cadr parts) context environment))
               (names
                (agent-scheme--import-modifier-identifiers
                 (cddr parts) "except")))
          (agent-scheme--ensure-import-names-present names bindings "except")
          (cl-remove-if
           (lambda (binding)
             (member (agent-scheme--library-binding-name binding)
                     names))
           bindings)))
       ((agent-scheme--symbol-named-p operator "prefix")
        (unless (= (length parts) 3)
          (agent-scheme--eval-error
           "prefix import set requires an import set and prefix"))
        (let ((prefix
               (agent-scheme--expect-symbol-name
                (caddr parts) "prefix identifier")))
          (mapcar
           (lambda (binding)
             (agent-scheme--library-binding-with-name
              binding
              (concat prefix
                      (agent-scheme--library-binding-name binding))))
           (agent-scheme--resolve-import-set
            (cadr parts) context environment))))
       ((agent-scheme--symbol-named-p operator "rename")
        (unless (>= (length parts) 2)
          (agent-scheme--eval-error
           "rename import set requires an import set"))
        (let* ((bindings
                (agent-scheme--resolve-import-set
                 (cadr parts) context environment))
               (renames
                (mapcar
                 (lambda (rename-form)
                   (let ((rename-parts
                          (agent-scheme--proper-list-elements
                           rename-form "rename pair")))
                     (unless (= (length rename-parts) 2)
                       (agent-scheme--eval-error
                        "rename pair requires old and new identifiers"))
                     (cons
                      (agent-scheme--expect-symbol-name
                       (car rename-parts) "rename old identifier")
                      (agent-scheme--expect-symbol-name
                       (cadr rename-parts) "rename new identifier"))))
                 (cddr parts)))
               (old-names (mapcar #'car renames)))
          (agent-scheme--ensure-import-names-present
           old-names bindings "rename")
          (mapcar
           (lambda (binding)
             (let ((rename
                    (assoc (agent-scheme--library-binding-name binding)
                           renames)))
               (if rename
                   (agent-scheme--library-binding-with-name
                    binding (cdr rename))
                 binding)))
           bindings)))
       (t
        (agent-scheme--eval-error
         "invalid import set: %s"
         (agent-scheme-value->external import-set))))))
   (t
    (agent-scheme--eval-error
     "invalid import set: %s"
     (agent-scheme-value->external import-set)))))

(defun agent-scheme--install-imported-binding
    (binding value-environment syntax-environment)
  "Install one imported BINDING into VALUE-ENVIRONMENT or SYNTAX-ENVIRONMENT."
  (let ((name (agent-scheme--library-binding-name binding))
        (kind (agent-scheme--library-binding-kind binding))
        (object (agent-scheme--library-binding-object binding))
        (library-key (agent-scheme--library-binding-library-key binding)))
    (pcase kind
      ('value
       (let ((existing
              (agent-scheme--current-environment-cell
               value-environment name)))
         (cond
         ((null existing)
           (puthash name object
                    (agent-scheme--environment-bindings value-environment)))
          ((equal library-key agent-scheme--scheme-base-library-key)
           ;; Programs commonly import `(scheme base)' more than once while
           ;; bootstrapping derived libraries.  Reinstalling the same base name
           ;; is benign and keeps later import-set processing simple.
           (puthash name object
                    (agent-scheme--environment-bindings value-environment)))
          ((eq existing object))
          (t
           (agent-scheme--eval-error
            "conflicting import for identifier: %s" name))))
       (puthash name t
                (agent-scheme--environment-imported-bindings
                 value-environment)))
      ('syntax
       (let ((existing
              (agent-scheme--current-syntax-binding
               syntax-environment name)))
         (cond
          ((or (null existing)
               (equal library-key agent-scheme--scheme-base-library-key))
           (puthash name object
                    (agent-scheme--syntax-environment-bindings
                     syntax-environment)))
          ((eq existing object))
          (t
           (agent-scheme--eval-error
            "conflicting syntax import for identifier: %s" name))))
       (puthash name t
                (agent-scheme--syntax-environment-imported-bindings
                 syntax-environment)))
      (_
       (agent-scheme--eval-error
        "unsupported library binding kind: %S" kind)))))

(defun agent-scheme--install-import-set
    (import-set value-environment syntax-environment context)
  "Resolve and install IMPORT-SET."
  (dolist (binding
           (agent-scheme--ensure-compatible-import-bindings
            (agent-scheme--resolve-import-set
             import-set context value-environment)))
    (agent-scheme--install-imported-binding
     binding value-environment syntax-environment)))

(defun agent-scheme--eval-import (form environment context)
  "Evaluate top-level or library import declaration FORM."
  (let ((parts (agent-scheme--proper-list-elements
                form "import declaration")))
    (unless (>= (length parts) 2)
      (agent-scheme--eval-error
       "import requires at least one import set"))
    (dolist (import-set (cdr parts))
      (agent-scheme--install-import-set
       import-set
       environment
       (agent-scheme--eval-context-syntax-environment context)
       context))
    agent-scheme-unspecified))

(defun agent-scheme--export-specs (forms)
  "Return export specs parsed from FORMS as (INTERNAL . EXTERNAL)."
  (let (specs)
    (dolist (form forms)
      (cond
       ((agent-scheme--identifier-datum-p form)
        (let ((name (agent-scheme--expect-symbol-name
                     form "export identifier")))
          (push (cons name name) specs)))
       ((agent-scheme--form-named-p form "rename")
        (let ((parts (agent-scheme--proper-list-elements
                      form "export rename")))
          (unless (= (length parts) 3)
            (agent-scheme--eval-error
             "export rename requires internal and external identifiers"))
          (push
           (cons
            (agent-scheme--expect-symbol-name
             (cadr parts) "export internal identifier")
            (agent-scheme--expect-symbol-name
             (caddr parts) "export external identifier"))
           specs)))
       (t
        (agent-scheme--eval-error
         "invalid export spec: %s"
         (agent-scheme-value->external form)))))
    (nreverse specs)))

(defun agent-scheme--feature-requirement-satisfied-p
    (requirement context environment)
  "Return non-nil when cond-expand REQUIREMENT is satisfied."
  (cond
   ((agent-scheme--identifier-datum-p requirement)
    (equal (agent-scheme--symbol-name requirement) "r7rs"))
   ((consp requirement)
    (let* ((parts (agent-scheme--proper-list-elements
                   requirement "feature requirement"))
           (operator (car parts)))
      (cond
       ((agent-scheme--symbol-named-p operator "library")
        (unless (= (length parts) 2)
          (agent-scheme--eval-error
           "library feature requirement requires one library name"))
        (agent-scheme--library-available-p (cadr parts) context environment))
       ((agent-scheme--symbol-named-p operator "and")
        (cl-every
         (lambda (nested)
           (agent-scheme--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((agent-scheme--symbol-named-p operator "or")
        (cl-some
         (lambda (nested)
           (agent-scheme--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((agent-scheme--symbol-named-p operator "not")
        (unless (= (length parts) 2)
          (agent-scheme--eval-error
           "not feature requirement requires one nested requirement"))
        (not
         (agent-scheme--feature-requirement-satisfied-p
          (cadr parts) context environment)))
       (t nil))))
   (t nil)))

(defun agent-scheme--expand-library-cond-expand
    (clauses context environment)
  "Return library declarations selected from cond-expand CLAUSES."
  (let ((selected nil)
        declarations)
    (dolist (clause clauses)
      (unless selected
        (let ((parts (agent-scheme--proper-list-elements
                      clause "cond-expand clause")))
          (when parts
            (let ((requirement (car parts)))
              (when (or (agent-scheme--symbol-named-p requirement "else")
                        (agent-scheme--feature-requirement-satisfied-p
                         requirement context environment))
                (setq selected t)
                (setq declarations (cdr parts))))))))
    (unless selected
      (agent-scheme--eval-error "unfulfilled library cond-expand"))
    declarations))

(defun agent-scheme--expand-library-declaration
    (declaration context environment)
  "Return DECLARATION after expanding library-level cond-expand."
  (cond
   ((agent-scheme--form-named-p declaration "cond-expand")
    (apply
     #'append
     (mapcar
      (lambda (nested)
        (agent-scheme--expand-library-declaration
         nested context environment))
      (agent-scheme--expand-library-cond-expand
       (cdr (agent-scheme--proper-list-elements
             declaration "library cond-expand"))
       context
       environment))))
   ((agent-scheme--form-named-p declaration "include-library-declarations")
    (agent-scheme--expand-include-library-declarations
     declaration context environment))
   (t
    (list declaration))))

(defun agent-scheme--include-filenames (declaration)
  "Return validated string filenames from include DECLARATION."
  (let* ((parts (agent-scheme--proper-list-elements
                 declaration "include declaration"))
         (operator-name (agent-scheme--symbol-name (car parts))))
    (unless (cdr parts)
      (agent-scheme--eval-error
       "%s requires at least one filename" operator-name))
    (mapcar
     (lambda (filename)
       (unless (stringp filename)
         (agent-scheme--eval-error
          "%s filename must be a string literal" operator-name))
       filename)
     (cdr parts))))

(defun agent-scheme--file-truename-or-expanded (path)
  "Return PATH's truename when possible, otherwise its expanded name."
  (if (file-exists-p path)
      (file-truename path)
    (expand-file-name path)))

(defun agent-scheme--path-policy-allows-file-p (path allowed-paths)
  "Return non-nil if ALLOWED-PATHS allow reading PATH."
  (let ((canonical-path
         (agent-scheme--file-truename-or-expanded path)))
    (cl-some
     (lambda (allowed)
       (let ((canonical-allowed
              (agent-scheme--file-truename-or-expanded allowed)))
         (or (equal canonical-path canonical-allowed)
             (and (file-directory-p canonical-allowed)
                  (file-in-directory-p canonical-path
                                       canonical-allowed)))))
     allowed-paths)))

(defun agent-scheme--include-policy-allows-file-p (path context)
  "Return non-nil if CONTEXT policy allows reading PATH."
  (agent-scheme--path-policy-allows-file-p
   path
   (agent-scheme--eval-context-include-paths context)))

(defun agent-scheme--resolve-include-file (filename context operation)
  "Return policy-checked absolute include path for FILENAME."
  (let* ((operation-symbol
          (pcase operation
            ("include" 'include)
            ("include-ci" 'include-ci)
            ("include-library-declarations" 'library-source)
            (_ (intern operation))))
         (authorization
          (agent-scheme-capability-authorize-file
           filename
           context
           operation-symbol
           operation
           (agent-scheme--eval-context-include-paths context)))
         (path (plist-get authorization :path)))
    (unless (file-readable-p path)
      (agent-scheme-capability-audit-file-result
       authorization
       "include file is not readable"
       t)
      (agent-scheme--eval-error
       "include file is not readable: %s" filename))
    (agent-scheme-capability-audit-file-result authorization 'read)
    path))

(defun agent-scheme--with-include-directory (context directory thunk)
  "Call THUNK while CONTEXT resolves relative includes from DIRECTORY."
  (let ((previous-directory
         (agent-scheme--eval-context-include-directory context)))
    (unwind-protect
        (progn
          (setf (agent-scheme--eval-context-include-directory context)
                (file-name-as-directory directory))
          (funcall thunk))
      (setf (agent-scheme--eval-context-include-directory context)
            previous-directory))))

(defun agent-scheme--read-include-file-forms (filename context fold-case)
  "Read FILENAME into forms after include policy checks.
When FOLD-CASE is non-nil, read as if the file began with
`#!fold-case'.  The return value is (FORMS . DIRECTORY)."
  (let* ((path (agent-scheme--resolve-include-file
                filename context (if fold-case "include-ci" "include")))
         (source
          (with-temp-buffer
            (insert-file-contents path)
            (buffer-string)))
         (forms
          (agent-scheme-read-all
           (if fold-case
               (concat "#!fold-case\n" source)
             source))))
    (cons forms (file-name-directory path))))

(defun agent-scheme--library-include-body-forms
    (declaration context fold-case)
  "Return body forms read by include DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (car (agent-scheme--read-include-file-forms
            filename context fold-case)))
    (agent-scheme--include-filenames declaration))))

(defun agent-scheme--expand-include-library-declarations
    (declaration context environment)
  "Return declarations spliced from include-library-declarations DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (let* ((read-result
              (let ((path
                     (agent-scheme--resolve-include-file
                      filename context "include-library-declarations")))
                (let ((source
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-string))))
                  (cons (agent-scheme-read-all source)
                        (file-name-directory path)))))
             (forms (car read-result))
             (directory (cdr read-result)))
        (agent-scheme--with-include-directory
         context
         directory
         (lambda ()
           (apply
            #'append
            (mapcar
             (lambda (nested)
               (agent-scheme--expand-library-declaration
                nested context environment))
             forms))))))
    (agent-scheme--include-filenames declaration))))

(defun agent-scheme--library-export-binding
    (spec library-key value-environment syntax-environment)
  "Return the library binding described by export SPEC."
  (let* ((internal-name (car spec))
         (external-name (cdr spec))
         (cell
          (agent-scheme--environment-cell value-environment internal-name))
         (syntax-binding
          (agent-scheme--syntax-environment-ref
           syntax-environment internal-name)))
    (cond
     ((and cell syntax-binding)
      (agent-scheme--eval-error
       "export identifier has both value and syntax bindings: %s"
       internal-name))
     (cell
      (agent-scheme--make-library-binding
       external-name 'value cell library-key))
     (syntax-binding
      (agent-scheme--make-library-binding
       external-name 'syntax syntax-binding library-key))
     (t
      (agent-scheme--eval-error
       "exported identifier is not bound: %s" internal-name)))))

(defun agent-scheme--library-exports-from-specs
    (specs library-key value-environment syntax-environment)
  "Return export bindings for SPECS from library environments."
  (agent-scheme--ensure-distinct-names
   (mapcar #'cdr specs)
   "library exports")
  (agent-scheme--ensure-compatible-import-bindings
   (mapcar
    (lambda (spec)
      (agent-scheme--library-export-binding
       spec library-key value-environment syntax-environment))
    specs)))

(defun agent-scheme--eval-library-begin
    (forms value-environment syntax-environment context)
  "Evaluate library body FORMS in explicit library environments."
  (agent-scheme--with-syntax-environment
   context
   syntax-environment
   (lambda ()
     (agent-scheme--trampoline
      (agent-scheme--make-sequence forms t)
      value-environment
      context))))

(defun agent-scheme--eval-define-library (form environment context)
  "Evaluate a top-level R7RS define-library FORM."
  (let* ((parts (agent-scheme--proper-list-elements
                 form "define-library form"))
         (name (cadr parts)))
    (unless (>= (length parts) 2)
      (agent-scheme--eval-error
       "define-library requires a library name"))
    (unless (agent-scheme--library-name-p name)
      (agent-scheme--eval-error
       "invalid library name: %s" (agent-scheme-value->external name)))
    (let* ((library-key (agent-scheme--library-name-key name))
           (value-environment (agent-scheme-make-empty-environment))
           (syntax-environment
            (agent-scheme--make-empty-syntax-environment))
           export-specs)
      (dolist (raw-declaration (cddr parts))
        (dolist (declaration
                 (agent-scheme--expand-library-declaration
                  raw-declaration context environment))
          ;; `cond-expand' and include-library-declarations are flattened
          ;; before this dispatch so only core R7RS library declarations remain.
          (let* ((declaration-parts
                  (agent-scheme--proper-list-elements
                   declaration "library declaration"))
                 (operator (car declaration-parts)))
            (cond
             ((agent-scheme--symbol-named-p operator "export")
              (setq export-specs
                    (append export-specs
                            (agent-scheme--export-specs
                             (cdr declaration-parts)))))
             ((agent-scheme--symbol-named-p operator "import")
              (agent-scheme--with-syntax-environment
               context
               syntax-environment
               (lambda ()
                 (agent-scheme--eval-import
                  declaration value-environment context))))
             ((agent-scheme--symbol-named-p operator "begin")
              (agent-scheme--eval-library-begin
               (cdr declaration-parts)
               value-environment
               syntax-environment
               context))
             ((agent-scheme--symbol-named-p operator "include")
              (agent-scheme--eval-library-begin
               (agent-scheme--library-include-body-forms
                declaration context nil)
               value-environment
               syntax-environment
               context))
             ((agent-scheme--symbol-named-p operator "include-ci")
              (agent-scheme--eval-library-begin
               (agent-scheme--library-include-body-forms
                declaration context t)
               value-environment
               syntax-environment
               context))
             ((agent-scheme--symbol-named-p
               operator "include-library-declarations")
              (agent-scheme--eval-error
               "include-library-declarations must expand before evaluation"))
             (t
              (agent-scheme--eval-error
               "unsupported library declaration: %s"
               (agent-scheme-value->external declaration)))))))
      (puthash
       library-key
       (agent-scheme--make-library
        name
        library-key
        (agent-scheme--library-exports-from-specs
         export-specs library-key value-environment syntax-environment)
        value-environment
        syntax-environment)
       (agent-scheme--eval-context-libraries context))
      agent-scheme-unspecified)))


(provide 'agent-scheme-library)

;;; agent-scheme-library.el ends here
