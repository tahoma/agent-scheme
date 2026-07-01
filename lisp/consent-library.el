;;; consent-library.el --- R7RS library resolver support  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Library records, source-library discovery, import-set resolution, and
;; define-library bootstrap support.  This module is loadable without the
;; evaluator backend; functions that evaluate library bodies use backend hooks
;; supplied by `consent-eval' after it loads.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-base)
(require 'consent-capability)
(require 'consent-agent-io)
(require 'consent-approval)
(require 'consent-context)
(require 'consent-debugger)
(require 'consent-helper)
(require 'consent-job)
(require 'consent-memory)
(require 'consent-models)
(require 'consent-plan)
(require 'consent-redaction)
(require 'consent-reflect)
(require 'consent-session)
(require 'consent-test)
(require 'consent-transcript)
(require 'consent-policy)

(defconst consent--library-source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Consent Scheme library source.")

(declare-function consent--make-empty-syntax-environment "consent-macro")
(declare-function consent--policy-denied "consent-interpreter")
(declare-function consent--syntax-environment-ref "consent-macro")
(declare-function consent--trampoline "consent-interpreter")
(declare-function consent--with-syntax-environment "consent-macro")

(cl-defstruct (consent--library-binding
               (:constructor consent--make-library-binding
                             (name kind object library-key))
               (:copier nil))
  "One exported or imported library binding."
  name kind object library-key)

(cl-defstruct (consent--library
               (:constructor consent--make-library
                             (name key exports value-environment
                                   syntax-environment))
               (:copier nil))
  "Loaded Scheme library with explicit environments and exports."
  name key exports value-environment syntax-environment)

(defconst consent--standard-library-keys
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

(defconst consent--stdlib-plus-source-library-keys
  '("(srfi manifest)"
    "(scheme comparator)"
    "(consent json)")
  "Optional stdlib-plus library keys backed by source files.")

(defconst consent--stdlib-plus-library-aliases
  '(((:alias . "(srfi 180)")
     (:target . "(consent json)"))
    ((:alias . "(srfi srfi-180)")
     (:target . "(consent json)"))
    ((:alias . "(srfi 128)")
     (:target . "(scheme comparator)"))
    ((:alias . "(consent json read)")
     (:target . "(consent json)")
     (:exports . ("json-number-of-character-limit"
                  "json-nesting-depth-limit"
                  "json-null?"
                  "json-error?"
                  "json-error-reason"
                  "json-fold"
                  "json-generator"
                  "json-read"
                  "json-lines-read"
                  "json-sequence-read"))))
  "Optional stdlib-plus import aliases.")

(defconst consent--stdlib-plus-library-keys
  (append consent--stdlib-plus-source-library-keys
          (mapcar (lambda (alias)
                    (cdr (assq :alias alias)))
                  consent--stdlib-plus-library-aliases))
  "Optional stdlib-plus library keys with focused support.")

(defconst consent--agent-library-keys
  '("(agent io)"
    "(agent approval)"
    "(agent debugger)"
    "(agent helper)"
    "(agent job)"
    "(agent test)"
    "(agent diagnostics)"
    "(agent diff)"
    "(agent vcs)"
    "(agent network)"
    "(agent test primitive)"
    "(agent task)"
    "(agent memory)"
    "(agent plan)"
    "(agent models)"
    "(agent models primitive)"
    "(agent context)"
    "(agent reflect)"
    "(agent redaction)"
    "(agent session)"
    "(agent registry)"
    "(agent proposal)"
    "(agent runner)"
    "(agent reliability)"
    "(agent prompt)"
    "(agent transcript)")
  "Agent interaction library keys with focused bootstrap support.")

(defconst consent--consent-library-keys
  '("(consent capability)"
    "(consent capability primitive)")
  "Consent core library keys.
The capability libraries are first-class consent primitives: a
capability is the encoded act of consent, so it belongs in the consent
core rather than the agent domain it governs.")

(defconst consent--agent-source-library-files
  '(("(consent capability)"
     . "../scheme/consent/capability.sld")
    ("(agent diagnostics)"
     . "../scheme/agent/diagnostics.sld")
    ("(agent diff)"
     . "../scheme/agent/diff.sld")
    ("(agent vcs)"
     . "../scheme/agent/vcs.sld")
    ("(agent network)"
     . "../scheme/agent/network.sld")
    ("(agent models)"
     . "../scheme/agent/models.sld")
    ("(agent registry)"
     . "../scheme/agent/registry.sld")
    ("(agent proposal)"
     . "../scheme/agent/proposal.sld")
    ("(agent runner)"
     . "../scheme/agent/runner.sld")
    ("(agent reliability)"
     . "../scheme/agent/reliability.sld")
    ("(agent prompt)"
     . "../scheme/agent/prompt.sld")
    ("(agent task)"
     . "../scheme/agent/task.sld")
    ("(agent test)"
     . "../scheme/agent/test.sld")
    ("(agent transcript)"
     . "../scheme/agent/transcript.sld"))
  "Checked-in portable Consent Scheme libraries loaded as Scheme source.")

;; Bootstrap libraries are registered lazily into the current evaluation
;; context.  The required `(scheme base)' library snapshots the active base
;; environment, while smaller standard libraries are either subsets, primitive
;; wrappers, or source libraries expanded through the same evaluator.

(defconst consent--standard-source-library-files
  '(("(scheme case-lambda)"
     . "../scheme/standard-library/case-lambda.sld")
    ("(scheme lazy)"
     . "../scheme/standard-library/lazy.sld"))
  "Checked-in portable standard libraries loaded as Scheme source.")

(defconst consent--stdlib-plus-source-library-files
  '(("(srfi manifest)"
     . "../scheme/stdlib-plus/manifest.sld")
    ("(scheme comparator)"
     . "../scheme/stdlib-plus/comparator.sld")
    ("(consent json)"
     . "../scheme/consent/json.sld"))
  "Checked-in optional stdlib-plus libraries loaded as Scheme source.")

(defun consent--standard-source-library-file (key)
  "Return the bundled source file path for standard library KEY."
  (let ((relative-file
         (cdr (assoc key consent--standard-source-library-files))))
    (unless relative-file
      (consent--eval-error
       "standard source library is not available: %s" key))
    (expand-file-name relative-file consent--library-source-directory)))

(defun consent--standard-source-library-source (key)
  "Return the checked-in source for standard library KEY."
  (let ((source-file (consent--standard-source-library-file key)))
    (unless (file-readable-p source-file)
      (consent--eval-error
       "standard source library file is not readable: %s" source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (buffer-string))))

(defun consent--stdlib-plus-source-library-file (key)
  "Return the bundled source file path for stdlib-plus library KEY."
  (let ((relative-file
         (cdr (assoc key consent--stdlib-plus-source-library-files))))
    (unless relative-file
      (consent--eval-error
       "stdlib-plus source library is not available: %s" key))
    (expand-file-name relative-file consent--library-source-directory)))

(defun consent--stdlib-plus-source-library-source (key)
  "Return the checked-in source for stdlib-plus library KEY."
  (let ((source-file (consent--stdlib-plus-source-library-file key)))
    (unless (file-readable-p source-file)
      (consent--eval-error
       "stdlib-plus source library file is not readable: %s" source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (buffer-string))))

(defun consent--agent-source-library-file (key)
  "Return the bundled source file path for Agent library KEY."
  (let ((relative-file
         (cdr (assoc key consent--agent-source-library-files))))
    (unless relative-file
      (consent--eval-error
       "agent source library is not available: %s" key))
    (expand-file-name relative-file consent--library-source-directory)))

(defun consent--agent-source-library-source (key)
  "Return the checked-in source for Agent library KEY."
  (let ((source-file (consent--agent-source-library-file key)))
    (unless (file-readable-p source-file)
      (consent--eval-error
       "agent source library file is not readable: %s" source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (buffer-string))))

(defun consent--standard-source-library-form (key)
  "Return the single define-library form read from KEY's source file."
  (let ((forms (consent-read-all
                (consent--standard-source-library-source key))))
    (unless (= (length forms) 1)
      (consent--eval-error
       "standard source library must contain exactly one form: %s" key))
    (let* ((form (car forms))
           (parts (consent--proper-list-elements
                   form "standard source library")))
      (unless (and (>= (length parts) 2)
                   (consent--symbol-named-p
                    (car parts) "define-library")
                   (equal (consent-datum->external
                           (consent--strip-identifiers (cadr parts)))
                          key))
        (consent--eval-error
         "standard source library name does not match registry key: %s" key))
      form)))

(defun consent--standard-source-library-export-names (form)
  "Return external export names declared by source library FORM."
  (let ((parts (consent--proper-list-elements
                form "standard source library"))
        exports)
    (dolist (declaration (cddr parts))
      (when (consent--form-named-p declaration "export")
        (setq exports
              (append exports
                      (mapcar
                       #'cdr
                       (consent--export-specs
                        (cdr (consent--proper-list-elements
                              declaration "standard source export"))))))))
    exports))

(defun consent-standard-source-library-specs ()
  "Return metadata for standard libraries loaded from portable source files."
  (mapcar
   (lambda (entry)
     (let* ((key (car entry))
            (form (consent--standard-source-library-form key)))
       (list :name key
             :exports
             (consent--standard-source-library-export-names form)
             :source-file
             (consent--standard-source-library-file key))))
   consent--standard-source-library-files))

(defun consent--nonnegative-exact-integer-datum-p (datum)
  "Return non-nil if DATUM is an exact non-negative integer datum."
  (and (consent-number-p datum)
       (eq (consent-number-kind datum) 'integer)
       (eq (consent-number-exactness datum) 'exact)
       (>= (consent-number-value datum) 0)))

(defun consent--library-name-p (datum)
  "Return non-nil if DATUM is a valid R7RS library name datum."
  (and (consp datum)
       (let ((parts (consent--proper-list-elements-maybe datum)))
         (and parts
              (cl-every
               (lambda (part)
                 (or (consent-symbol-p part)
                     (consent--nonnegative-exact-integer-datum-p part)))
               parts)))))

(defun consent--library-name-key (name)
  "Return the registry key for library NAME."
  (unless (consent--library-name-p name)
    (consent--eval-error
     "invalid library name: %s" (consent-value->external name)))
  (consent-datum->external (consent--strip-identifiers name)))

(defun consent--current-environment-cell (environment name)
  "Return NAME's cell in ENVIRONMENT's current frame, or nil."
  (let ((cell (gethash name
                       (consent--environment-bindings environment)
                       consent--missing-cell)))
    (unless (eq cell consent--missing-cell)
      cell)))

(defun consent--current-syntax-binding (syntax-environment name)
  "Return NAME's binding in SYNTAX-ENVIRONMENT's current frame, or nil."
  (let ((binding (gethash
                  name
                  (consent--syntax-environment-bindings
                   syntax-environment)
                  consent--missing-cell)))
    (unless (eq binding consent--missing-cell)
      binding)))

(defun consent--form-named-p (form name)
  "Return non-nil when FORM is a list beginning with identifier NAME."
  (and (consp form)
       (consent--symbol-named-p (car form) name)))

(defun consent--import-form-p (form)
  "Return non-nil if FORM is an import declaration."
  (consent--form-named-p form "import"))

(defun consent--define-library-form-p (form)
  "Return non-nil if FORM is a define-library form."
  (consent--form-named-p form "define-library"))

(defun consent--library-binding-with-name (binding name)
  "Return BINDING renamed to local NAME."
  (consent--make-library-binding
   name
   (consent--library-binding-kind binding)
   (consent--library-binding-object binding)
   (consent--library-binding-library-key binding)))

(defun consent--same-library-binding-p (left right)
  "Return non-nil if LEFT and RIGHT identify the same imported binding."
  (and (consent--library-binding-p left)
       (consent--library-binding-p right)
       (eq (consent--library-binding-kind left)
           (consent--library-binding-kind right))
       (eq (consent--library-binding-object left)
           (consent--library-binding-object right))))

(defun consent--snapshot-library-bindings
    (value-environment syntax-environment library-key)
  "Return exported bindings from VALUE-ENVIRONMENT and SYNTAX-ENVIRONMENT."
  (let (exports)
    (maphash
     (lambda (name cell)
       (push (consent--make-library-binding
              name 'value cell library-key)
             exports))
     (consent--environment-bindings value-environment))
    (maphash
     (lambda (name transformer)
       (push (consent--make-library-binding
              name 'syntax transformer library-key)
             exports))
     (consent--syntax-environment-bindings syntax-environment))
    (nreverse exports)))

(defun consent--register-scheme-base-library
    (context environment)
  "Register the builtin `(scheme base)' library in CONTEXT."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash consent--scheme-base-library-key registry)
      (let* ((use-current-environment
              (consent--environment-cell environment "+"))
             (base-environment
              (if use-current-environment
                  environment
                (consent-make-base-environment)))
             (base-context
              (if use-current-environment
                  context
                (consent--new-eval-context nil))))
        (unless use-current-environment
          (consent--ensure-base-syntax
           base-context base-environment))
        (let* ((syntax-environment
                (consent--eval-context-syntax-environment
                 base-context))
               (exports
                (consent--snapshot-library-bindings
                 base-environment
                 syntax-environment
                 consent--scheme-base-library-key)))
          (puthash
           consent--scheme-base-library-key
           (consent--make-library
            (list (consent--syntax-symbol "scheme")
                  (consent--syntax-symbol "base"))
            consent--scheme-base-library-key
            exports
            base-environment
            syntax-environment)
           registry))))))

(defun consent--register-emacs-capability-library
    (key context)
  "Register an Emacs capability library named by KEY."
  (consent--register-primitive-library
   key
   (consent-emacs-capability-primitive-specs key)
   context))

(defun consent--register-agent-library
    (key context environment)
  "Register Agent interaction library KEY in CONTEXT."
  (pcase key
    ("(agent io)"
     (consent--register-primitive-library
      key
      (consent-agent-io-primitive-specs)
      context))
    ("(agent approval)"
     (consent--register-primitive-library
      key
      (consent-approval-primitive-specs)
      context))
    ("(agent debugger)"
     (consent--register-primitive-library
      key
      (consent-debugger-primitive-specs)
      context))
    ("(agent helper)"
     (consent--register-primitive-library
      key
      (consent-helper-primitive-specs)
      context))
    ("(agent job)"
     (consent--register-primitive-library
      key
      (consent-job-primitive-specs)
      context))
    ("(agent test)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent diagnostics)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent diff)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent vcs)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent network)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent registry)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent proposal)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent runner)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent reliability)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent prompt)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent task)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent test primitive)"
     (consent--register-primitive-library
      key
      (consent-test-primitive-specs)
      context))
    ("(agent memory)"
     (consent--register-primitive-library
      key
      (consent-memory-primitive-specs)
      context))
    ("(agent plan)"
     (consent--register-primitive-library
      key
      (consent-plan-primitive-specs)
      context))
    ("(agent models)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(agent models primitive)"
     (consent--register-primitive-library
      key
      (consent-models-primitive-specs)
      context))
    ("(agent context)"
     (consent--register-primitive-library
      key
      (consent-context-primitive-specs)
      context))
    ("(agent reflect)"
     (consent--register-primitive-library
      key
      (consent-reflect-primitive-specs)
      context))
    ("(agent redaction)"
     (consent--register-primitive-library
      key
      (consent-redaction-primitive-specs)
      context))
    ("(agent session)"
     (consent--register-primitive-library
      key
      (consent-session-primitive-specs)
      context))
    ("(agent transcript)"
     (consent--register-source-library
      (consent--agent-source-library-source key)
      context
      environment))
    (_
     (consent--eval-error "unknown agent library: %s" key))))

(defun consent--register-consent-library
    (key context environment)
  "Register consent core library KEY in CONTEXT."
  (pcase key
    ("(consent capability)"
     (unless (gethash key (consent--eval-context-libraries context))
       (consent--register-source-library
        (consent--agent-source-library-source key) context environment)))
    ("(consent capability primitive)"
     (consent--register-primitive-library
      key
      (consent-capability-primitive-specs)
      context))
    (_
     (consent--eval-error "unknown consent library: %s" key))))

(defun consent--register-source-library
    (source context environment)
  "Evaluate one define-library SOURCE into CONTEXT."
  (let ((max-lisp-eval-depth (max max-lisp-eval-depth 4096))
        (forms (consent-read-all source)))
    (unless (= (length forms) 1)
      (consent--eval-error
       "source library must contain exactly one form"))
    (consent--eval-define-library
     (car forms)
     environment
     context)))

(defun consent--find-library-export (name exports)
  "Return export named NAME from EXPORTS, or nil."
  (cl-find name exports
           :key #'consent--library-binding-name
           :test #'equal))

(defun consent--register-subset-library
    (key export-names context environment)
  "Register KEY as a subset of `(scheme base)' EXPORT-NAMES."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (consent--resolve-library
               (consent-read consent--scheme-base-library-key)
               context
               environment))
             (base-exports
              (consent--library-exports base-library))
             (exports
              (mapcar
               (lambda (name)
                 (or (consent--find-library-export
                      name base-exports)
                     (consent--eval-error
                      "standard library binding is not available: %s"
                      name)))
               export-names)))
        (puthash
         key
         (consent--make-library
          (consent-read key)
          key
          exports
          (consent--library-value-environment base-library)
          (consent--library-syntax-environment base-library))
         registry)))))

(defun consent--register-primitive-library
    (key primitive-specs context)
  "Register KEY with PRIMITIVE-SPECS.
Each spec has (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY)."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash key registry)
      (let ((value-environment (consent-make-empty-environment))
            (syntax-environment
             (consent--make-empty-syntax-environment)))
        (dolist (spec primitive-specs)
          (consent--define-primitive
           value-environment
           (nth 0 spec)
           (nth 1 spec)
           (nth 2 spec)
           (nth 3 spec)))
        (puthash
         key
         (consent--make-library
          (consent-read key)
          key
          (consent--snapshot-library-bindings
           value-environment syntax-environment key)
          value-environment
          syntax-environment)
         registry)))))

(defun consent--cxr-primitive (name)
  "Return a primitive procedure implementation for composed accessor NAME."
  (let ((steps (reverse (string-to-list
                         (substring name 1 (1- (length name)))))))
    (lambda (arguments _context)
      (let ((value (car arguments)))
        (dolist (step steps)
          (setq value
                (if (= step ?a)
                    (consent--primitive-car (list value) nil)
                  (consent--primitive-cdr (list value) nil))))
        value))))

(defconst consent--cxr-library-names
  '("caaar" "caadr" "cadar" "caddr"
    "cdaar" "cdadr" "cddar" "cdddr"
    "caaaar" "caaadr" "caadar" "caaddr"
    "cadaar" "cadadr" "caddar" "cadddr"
    "cdaaar" "cdaadr" "cdadar" "cdaddr"
    "cddaar" "cddadr" "cdddar" "cddddr")
  "R7RS `(scheme cxr)' three- and four-level accessors.")

(defun consent--cxr-primitive-specs ()
  "Return primitive specs for `(scheme cxr)'."
  (mapcar
   (lambda (name)
     (list name (consent--cxr-primitive name) 1 1))
   consent--cxr-library-names))

(defun consent--policy-denied-spec (name)
  "Return a primitive spec for default-denied host effect NAME."
  (list name
        (lambda (_arguments context)
          (consent--policy-denied name context))
        0
        nil))

(defun consent--register-r5rs-library (key context environment)
  "Register the practical `(scheme r5rs)' compatibility library KEY."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (consent--resolve-library
               (consent-read consent--scheme-base-library-key)
               context
               environment))
             (exports (copy-sequence (consent--library-exports
                                       base-library)))
             (inexact-binding
              (consent--find-library-export "inexact" exports))
             (exact-binding
              (consent--find-library-export "exact" exports)))
        (push (consent--library-binding-with-name
               inexact-binding "exact->inexact")
              exports)
        (push (consent--library-binding-with-name
               exact-binding "inexact->exact")
              exports)
        (puthash
         key
         (consent--make-library
          (consent-read key)
          key
          (nreverse exports)
          (consent--library-value-environment base-library)
          (consent--library-syntax-environment base-library))
         registry)))))

(defun consent--register-standard-library
    (key context environment)
  "Register focused standard library KEY in CONTEXT."
  (pcase key
    ("(scheme case-lambda)"
     (consent--register-source-library
      (consent--standard-source-library-source key) context environment))
    ("(scheme char)"
     (consent--register-primitive-library
      key
      `(("char-alphabetic?" ,#'consent--primitive-char-alphabetic? 1 1)
        ("char-ci<=?" ,#'consent--primitive-char-ci<=? 2 nil)
        ("char-ci<?" ,#'consent--primitive-char-ci<? 2 nil)
        ("char-ci=?" ,#'consent--primitive-char-ci=? 2 nil)
        ("char-ci>=?" ,#'consent--primitive-char-ci>=? 2 nil)
        ("char-ci>?" ,#'consent--primitive-char-ci>? 2 nil)
        ("char-downcase" ,#'consent--primitive-char-downcase 1 1)
        ("char-foldcase" ,#'consent--primitive-char-foldcase 1 1)
        ("char-lower-case?" ,#'consent--primitive-char-lower-case? 1 1)
        ("char-numeric?" ,#'consent--primitive-char-numeric? 1 1)
        ("char-upcase" ,#'consent--primitive-char-upcase 1 1)
        ("char-upper-case?" ,#'consent--primitive-char-upper-case? 1 1)
        ("char-whitespace?" ,#'consent--primitive-char-whitespace? 1 1)
        ("digit-value" ,#'consent--primitive-digit-value 1 1)
        ("string-ci<=?" ,#'consent--primitive-string-ci<=? 2 nil)
        ("string-ci<?" ,#'consent--primitive-string-ci<? 2 nil)
        ("string-ci=?" ,#'consent--primitive-string-ci=? 2 nil)
        ("string-ci>=?" ,#'consent--primitive-string-ci>=? 2 nil)
        ("string-ci>?" ,#'consent--primitive-string-ci>? 2 nil)
        ("string-downcase" ,#'consent--primitive-string-downcase 1 1)
        ("string-foldcase" ,#'consent--primitive-string-foldcase 1 1)
        ("string-upcase" ,#'consent--primitive-string-upcase 1 1))
      context))
    ("(scheme complex)"
     (consent--register-primitive-library
      key
      `(("angle" ,#'consent--primitive-angle 1 1)
        ("imag-part" ,#'consent--primitive-imag-part 1 1)
        ("magnitude" ,#'consent--primitive-magnitude 1 1)
        ("make-polar" ,#'consent--primitive-make-polar 2 2)
        ("make-rectangular" ,#'consent--primitive-make-rectangular 2 2)
        ("real-part" ,#'consent--primitive-real-part 1 1))
      context))
    ("(scheme cxr)"
     (consent--register-primitive-library
      key
      (consent--cxr-primitive-specs)
      context))
    ("(scheme eval)"
     (consent--register-primitive-library
      key
      `(("environment" ,#'consent--primitive-environment 1 nil)
        ("eval" ,#'consent--primitive-eval 2 2))
      context))
    ("(scheme file)"
     (consent--register-primitive-library
      key
      `(("call-with-input-file" ,#'consent--primitive-call-with-input-file
         2 2)
        ("call-with-output-file" ,#'consent--primitive-call-with-output-file
         2 2)
        ("delete-file" ,#'consent--primitive-delete-file 1 1)
        ("file-exists?" ,#'consent--primitive-file-exists? 1 1)
        ("open-binary-input-file" ,#'consent--primitive-open-binary-input-file
         1 1)
        ("open-binary-output-file" ,#'consent--primitive-open-binary-output-file
         1 1)
        ("open-input-file" ,#'consent--primitive-open-input-file 1 1)
        ("open-output-file" ,#'consent--primitive-open-output-file 1 1)
        ("with-input-from-file" ,#'consent--primitive-with-input-from-file
         2 2)
        ("with-output-to-file" ,#'consent--primitive-with-output-to-file
         2 2))
      context))
    ("(scheme inexact)"
     (consent--register-primitive-library
      key
      `(("acos" ,#'consent--primitive-acos 1 1)
        ("asin" ,#'consent--primitive-asin 1 1)
        ("atan" ,#'consent--primitive-atan 1 2)
        ("cos" ,#'consent--primitive-cos 1 1)
        ("exp" ,#'consent--primitive-exp 1 1)
        ("finite?" ,#'consent--primitive-finite? 1 1)
        ("infinite?" ,#'consent--primitive-infinite? 1 1)
        ("log" ,#'consent--primitive-log 1 2)
        ("nan?" ,#'consent--primitive-nan? 1 1)
        ("sin" ,#'consent--primitive-sin 1 1)
        ("sqrt" ,#'consent--primitive-sqrt 1 1)
        ("tan" ,#'consent--primitive-tan 1 1))
      context))
    ("(scheme lazy)"
     (consent--register-source-library
      (consent--standard-source-library-source key) context environment))
    ("(scheme load)"
     (consent--register-primitive-library
      key
      `(("load" ,#'consent--primitive-load 1 2))
      context))
    ("(scheme process-context)"
     (consent--register-primitive-library
	      key
	      (append
	       `(("command-line" ,#'consent--primitive-command-line 0 0))
	       (mapcar #'consent--policy-denied-spec
	               '("emergency-exit"
	                 "exit"))
       ;; Environment reads are real, policy-gated primitives: denied unless the
       ;; context carries an active process-environment capability grant.
       `(("get-environment-variable"
          ,#'consent--primitive-get-environment-variable 1 1)
         ("get-environment-variables"
          ,#'consent--primitive-get-environment-variables 0 0)))
      context))
    ("(scheme read)"
     (consent--register-primitive-library
      key
      `(("read" ,#'consent--primitive-read 0 1))
      context))
    ("(scheme repl)"
     (consent--register-primitive-library
      key
      `(("interaction-environment"
         ,#'consent--primitive-interaction-environment 0 0))
      context))
    ("(scheme r5rs)"
     (consent--register-r5rs-library key context environment))
    ("(scheme time)"
     (consent--register-primitive-library
      key
      `(("current-jiffy" ,#'consent--primitive-current-jiffy 0 0)
        ("current-second" ,#'consent--primitive-current-second 0 0)
        ("jiffies-per-second"
         ,#'consent--primitive-jiffies-per-second 0 0))
      context))
    ("(scheme write)"
     (consent--register-primitive-library
      key
      `(("display" ,#'consent--primitive-display 1 2)
        ("write" ,#'consent--primitive-write 1 2)
        ("write-shared" ,#'consent--primitive-write-shared 1 2)
        ("write-simple" ,#'consent--primitive-write-simple 1 2))
      context))
    (_
     (consent--eval-error "unknown standard library: %s" key))))

(defun consent--register-stdlib-plus-library (key context environment)
  "Register optional stdlib-plus library KEY in CONTEXT."
  (let ((alias-spec
         (consent--library-alias-spec key consent--stdlib-plus-library-aliases)))
    (cond
     (alias-spec
      (consent--register-library-alias alias-spec context environment))
     ((assoc key consent--stdlib-plus-source-library-files)
      (unless (gethash key (consent--eval-context-libraries context))
        (consent--register-source-library
         (consent--stdlib-plus-source-library-source key)
         context
         environment)))
     ((member key consent--stdlib-plus-library-keys)
      (consent--eval-error
       "stdlib-plus library has no registration strategy: %s" key))
     (t
      (consent--eval-error "unknown stdlib-plus library: %s" key)))))

(defun consent--filter-library-exports (exports export-names key)
  "Return EXPORTS narrowed to EXPORT-NAMES for alias library KEY."
  (dolist (name export-names)
    (unless (consent--find-library-export name exports)
      (consent--eval-error
       "alias export is not available in %s: %s" key name)))
  (cl-remove-if-not
   (lambda (binding)
     (member (consent--library-binding-name binding) export-names))
   exports))

(defun consent--library-alias-field (spec field)
  "Return FIELD from alias SPEC, or nil when absent."
  (cdr (assq field spec)))

(defun consent--register-library-alias (spec context environment)
  "Register alias SPEC using its target library and optional exports."
  (let* ((key (consent--library-alias-field spec :alias))
         (target-key (consent--library-alias-field spec :target))
         (export-names-entry (assq :exports spec)))
    (unless key
      (consent--eval-error "library alias has no alias name: %S" spec))
    (unless target-key
      (consent--eval-error "library alias has no target: %s" key))
    (unless (gethash key (consent--eval-context-libraries context))
      (let* ((target-library
              (consent--resolve-library
               (consent-read target-key) context environment))
             (target-exports (consent--library-exports target-library)))
      (puthash
       key
       (consent--make-library
        (consent-read key)
        key
        (if export-names-entry
            (consent--filter-library-exports
             target-exports (cdr export-names-entry) key)
          target-exports)
        (consent--library-value-environment target-library)
        (consent--library-syntax-environment target-library))
       (consent--eval-context-libraries context))))))

(defun consent--library-alias-spec (key aliases)
  "Return KEY's alias spec from ALIASES, or nil when KEY is not an alias."
  (cl-find key aliases
           :key (lambda (alias)
                  (consent--library-alias-field alias :alias))
           :test #'equal))

(defun consent--library-available-p (name context _environment)
  "Return non-nil if NAME can be imported."
  (let ((key (consent--library-name-key name)))
    (cond
     ((equal key consent--scheme-base-library-key)
      t)
     ((member key consent--standard-library-keys)
      t)
     ((member key consent--stdlib-plus-library-keys)
      t)
     ((member key consent--agent-library-keys)
      t)
     ((member key consent--consent-library-keys)
      t)
     ((member key (consent-emacs-capability-library-keys))
      t)
     (t
      (and (gethash key (consent--eval-context-libraries context))
           t)))))

(defun consent--resolve-library (name context environment)
  "Return library NAME from CONTEXT, registering builtins when needed."
  (let ((key (consent--library-name-key name)))
    (cond
     ((equal key consent--scheme-base-library-key)
      (consent--register-scheme-base-library context environment))
     ((member key consent--standard-library-keys)
      (consent--register-standard-library key context environment))
     ((member key consent--stdlib-plus-library-keys)
      (consent--register-stdlib-plus-library key context environment))
     ((member key consent--agent-library-keys)
      (consent--register-agent-library key context environment))
     ((member key consent--consent-library-keys)
      (consent--register-consent-library key context environment))
     ((member key (consent-emacs-capability-library-keys))
      (consent--register-emacs-capability-library key context)))
    (or (gethash key (consent--eval-context-libraries context))
        (consent--eval-error "unknown library: %s" key))))

(defun consent--import-binding-local-name (binding)
  "Return BINDING's local import name."
  (consent--library-binding-name binding))

(defun consent--find-import-binding (name bindings)
  "Return import binding named NAME from BINDINGS, or nil."
  (cl-find name bindings
           :key #'consent--import-binding-local-name
           :test #'equal))

(defun consent--ensure-import-names-present
    (names bindings description)
  "Signal if any NAMES are absent from BINDINGS for DESCRIPTION."
  (dolist (name names)
    (unless (consent--find-import-binding name bindings)
      (consent--eval-error
       "%s import name not found: %s" description name))))

(defun consent--ensure-compatible-import-bindings (bindings)
  "Return BINDINGS after checking for duplicate incompatible names."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (binding bindings)
      (let* ((name (consent--library-binding-name binding))
             (previous (gethash name seen)))
        (cond
         ((null previous)
          (puthash name binding seen)
          (push binding result))
         ((consent--same-library-binding-p previous binding))
         (t
          (consent--eval-error
           "conflicting imports for identifier: %s" name)))))
    (nreverse result)))

(defun consent--import-modifier-identifiers (forms description)
  "Return FORMS as identifier name strings for DESCRIPTION."
  (mapcar
   (lambda (form)
     (consent--expect-symbol-name form description))
   forms))

(defun consent--resolve-import-set
    (import-set context environment)
  "Resolve IMPORT-SET to a list of library bindings."
  (cond
   ((consent--library-name-p import-set)
    (copy-sequence
     (consent--library-exports
      (consent--resolve-library import-set context environment))))
   ((consp import-set)
    (let* ((parts (consent--proper-list-elements
                   import-set "import set"))
           (operator (car parts)))
      (cond
       ((consent--symbol-named-p operator "only")
        (unless (>= (length parts) 2)
          (consent--eval-error "only import set requires an import set"))
        (let* ((bindings
                (consent--resolve-import-set
                 (cadr parts) context environment))
               (names
                (consent--import-modifier-identifiers
                 (cddr parts) "only")))
          (consent--ensure-import-names-present names bindings "only")
          (cl-remove-if-not
           (lambda (binding)
             (member (consent--library-binding-name binding)
                     names))
           bindings)))
       ((consent--symbol-named-p operator "except")
        (unless (>= (length parts) 2)
          (consent--eval-error
           "except import set requires an import set"))
        (let* ((bindings
                (consent--resolve-import-set
                 (cadr parts) context environment))
               (names
                (consent--import-modifier-identifiers
                 (cddr parts) "except")))
          (consent--ensure-import-names-present names bindings "except")
          (cl-remove-if
           (lambda (binding)
             (member (consent--library-binding-name binding)
                     names))
           bindings)))
       ((consent--symbol-named-p operator "prefix")
        (unless (= (length parts) 3)
          (consent--eval-error
           "prefix import set requires an import set and prefix"))
        (let ((prefix
               (consent--expect-symbol-name
                (caddr parts) "prefix identifier")))
          (mapcar
           (lambda (binding)
             (consent--library-binding-with-name
              binding
              (concat prefix
                      (consent--library-binding-name binding))))
           (consent--resolve-import-set
            (cadr parts) context environment))))
       ((consent--symbol-named-p operator "rename")
        (unless (>= (length parts) 2)
          (consent--eval-error
           "rename import set requires an import set"))
        (let* ((bindings
                (consent--resolve-import-set
                 (cadr parts) context environment))
               (renames
                (mapcar
                 (lambda (rename-form)
                   (let ((rename-parts
                          (consent--proper-list-elements
                           rename-form "rename pair")))
                     (unless (= (length rename-parts) 2)
                       (consent--eval-error
                        "rename pair requires old and new identifiers"))
                     (cons
                      (consent--expect-symbol-name
                       (car rename-parts) "rename old identifier")
                      (consent--expect-symbol-name
                       (cadr rename-parts) "rename new identifier"))))
                 (cddr parts)))
               (old-names (mapcar #'car renames)))
          (consent--ensure-import-names-present
           old-names bindings "rename")
          (mapcar
           (lambda (binding)
             (let ((rename
                    (assoc (consent--library-binding-name binding)
                           renames)))
               (if rename
                   (consent--library-binding-with-name
                    binding (cdr rename))
                 binding)))
           bindings)))
       (t
        (consent--eval-error
         "invalid import set: %s"
         (consent-value->external import-set))))))
   (t
    (consent--eval-error
     "invalid import set: %s"
     (consent-value->external import-set)))))

(defun consent--install-imported-binding
    (binding value-environment syntax-environment)
  "Install one imported BINDING into VALUE-ENVIRONMENT or SYNTAX-ENVIRONMENT."
  (let ((name (consent--library-binding-name binding))
        (kind (consent--library-binding-kind binding))
        (object (consent--library-binding-object binding))
        (library-key (consent--library-binding-library-key binding)))
    (pcase kind
      ('value
       (let ((existing
              (consent--current-environment-cell
               value-environment name)))
         (cond
         ((null existing)
           (puthash name object
                    (consent--environment-bindings value-environment)))
          ((equal library-key consent--scheme-base-library-key)
           ;; Programs commonly import `(scheme base)' more than once while
           ;; bootstrapping derived libraries.  Reinstalling the same base name
           ;; is benign and keeps later import-set processing simple.
           (puthash name object
                    (consent--environment-bindings value-environment)))
          ((eq existing object))
          (t
           (consent--eval-error
            "conflicting import for identifier: %s" name))))
       (puthash name t
                (consent--environment-imported-bindings
                 value-environment)))
      ('syntax
       (let ((existing
              (consent--current-syntax-binding
               syntax-environment name)))
         (cond
          ((or (null existing)
               (equal library-key consent--scheme-base-library-key))
           (puthash name object
                    (consent--syntax-environment-bindings
                     syntax-environment)))
          ((eq existing object))
          (t
           (consent--eval-error
            "conflicting syntax import for identifier: %s" name))))
       (puthash name t
                (consent--syntax-environment-imported-bindings
                 syntax-environment)))
      (_
       (consent--eval-error
        "unsupported library binding kind: %S" kind)))))

(defun consent--install-import-set
    (import-set value-environment syntax-environment context)
  "Resolve and install IMPORT-SET."
  (dolist (binding
           (consent--ensure-compatible-import-bindings
            (consent--resolve-import-set
             import-set context value-environment)))
    (consent--install-imported-binding
     binding value-environment syntax-environment)))

(defun consent--eval-import (form environment context)
  "Evaluate top-level or library import declaration FORM."
  (let ((parts (consent--proper-list-elements
                form "import declaration")))
    (unless (>= (length parts) 2)
      (consent--eval-error
       "import requires at least one import set"))
    (dolist (import-set (cdr parts))
      (consent--install-import-set
       import-set
       environment
       (consent--eval-context-syntax-environment context)
       context))
    consent-unspecified))

(defun consent--export-specs (forms)
  "Return export specs parsed from FORMS as (INTERNAL . EXTERNAL)."
  (let (specs)
    (dolist (form forms)
      (cond
       ((consent--identifier-datum-p form)
        (let ((name (consent--expect-symbol-name
                     form "export identifier")))
          (push (cons name name) specs)))
       ((consent--form-named-p form "rename")
        (let ((parts (consent--proper-list-elements
                      form "export rename")))
          (unless (= (length parts) 3)
            (consent--eval-error
             "export rename requires internal and external identifiers"))
          (push
           (cons
            (consent--expect-symbol-name
             (cadr parts) "export internal identifier")
            (consent--expect-symbol-name
             (caddr parts) "export external identifier"))
           specs)))
       (t
        (consent--eval-error
         "invalid export spec: %s"
         (consent-value->external form)))))
    (nreverse specs)))

(defun consent--feature-requirement-satisfied-p
    (requirement context environment)
  "Return non-nil when cond-expand REQUIREMENT is satisfied."
  (cond
   ((consent--identifier-datum-p requirement)
    (equal (consent--symbol-name requirement) "r7rs"))
   ((consp requirement)
    (let* ((parts (consent--proper-list-elements
                   requirement "feature requirement"))
           (operator (car parts)))
      (cond
       ((consent--symbol-named-p operator "library")
        (unless (= (length parts) 2)
          (consent--eval-error
           "library feature requirement requires one library name"))
        (consent--library-available-p (cadr parts) context environment))
       ((consent--symbol-named-p operator "and")
        (cl-every
         (lambda (nested)
           (consent--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((consent--symbol-named-p operator "or")
        (cl-some
         (lambda (nested)
           (consent--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((consent--symbol-named-p operator "not")
        (unless (= (length parts) 2)
          (consent--eval-error
           "not feature requirement requires one nested requirement"))
        (not
         (consent--feature-requirement-satisfied-p
          (cadr parts) context environment)))
       (t nil))))
   (t nil)))

(defun consent--expand-library-cond-expand
    (clauses context environment)
  "Return library declarations selected from cond-expand CLAUSES."
  (let ((selected nil)
        declarations)
    (dolist (clause clauses)
      (unless selected
        (let ((parts (consent--proper-list-elements
                      clause "cond-expand clause")))
          (when parts
            (let ((requirement (car parts)))
              (when (or (consent--symbol-named-p requirement "else")
                        (consent--feature-requirement-satisfied-p
                         requirement context environment))
                (setq selected t)
                (setq declarations (cdr parts))))))))
    (unless selected
      (consent--eval-error "unfulfilled library cond-expand"))
    declarations))

(defun consent--expand-library-declaration
    (declaration context environment)
  "Return DECLARATION after expanding library-level cond-expand."
  (cond
   ((consent--form-named-p declaration "cond-expand")
    (apply
     #'append
     (mapcar
      (lambda (nested)
        (consent--expand-library-declaration
         nested context environment))
      (consent--expand-library-cond-expand
       (cdr (consent--proper-list-elements
             declaration "library cond-expand"))
       context
       environment))))
   ((consent--form-named-p declaration "include-library-declarations")
    (consent--expand-include-library-declarations
     declaration context environment))
   (t
    (list declaration))))

(defun consent--include-filenames (declaration)
  "Return validated string filenames from include DECLARATION."
  (let* ((parts (consent--proper-list-elements
                 declaration "include declaration"))
         (operator-name (consent--symbol-name (car parts))))
    (unless (cdr parts)
      (consent--eval-error
       "%s requires at least one filename" operator-name))
    (mapcar
     (lambda (filename)
       (unless (stringp filename)
         (consent--eval-error
          "%s filename must be a string literal" operator-name))
       filename)
     (cdr parts))))

(defun consent--file-truename-or-expanded (path)
  "Return PATH's truename when possible, otherwise its expanded name."
  (if (file-exists-p path)
      (file-truename path)
    (expand-file-name path)))

(defun consent--path-policy-allows-file-p (path allowed-paths)
  "Return non-nil if ALLOWED-PATHS allow reading PATH."
  (let ((canonical-path
         (consent--file-truename-or-expanded path)))
    (cl-some
     (lambda (allowed)
       (let ((canonical-allowed
              (consent--file-truename-or-expanded allowed)))
         (or (equal canonical-path canonical-allowed)
             (and (file-directory-p canonical-allowed)
                  (file-in-directory-p canonical-path
                                       canonical-allowed)))))
     allowed-paths)))

(defun consent--include-policy-allows-file-p (path context)
  "Return non-nil if CONTEXT policy allows reading PATH."
  (consent--path-policy-allows-file-p
   path
   (consent--eval-context-include-paths context)))

(defun consent--resolve-include-file (filename context operation)
  "Return policy-checked absolute include path for FILENAME."
  (let* ((operation-symbol
          (pcase operation
            ("include" 'include)
            ("include-ci" 'include-ci)
            ("include-library-declarations" 'library-source)
            (_ (intern operation))))
         (authorization
          (consent-capability-authorize-file
           filename
           context
           operation-symbol
           operation
         (consent--eval-context-include-paths context)))
         (path (plist-get authorization :path)))
    (consent-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (consent-capability-audit-file-result
       authorization
       "include file is not readable"
       t)
      (consent--eval-error
       "include file is not readable: %s" filename))
    (consent-capability-audit-file-result authorization 'read)
    path))

(defun consent--with-include-directory (context directory thunk)
  "Call THUNK while CONTEXT resolves relative includes from DIRECTORY."
  (let ((previous-directory
         (consent--eval-context-include-directory context)))
    (unwind-protect
        (progn
          (setf (consent--eval-context-include-directory context)
                (file-name-as-directory directory))
          (funcall thunk))
      (setf (consent--eval-context-include-directory context)
            previous-directory))))

(defun consent--read-include-file-forms (filename context fold-case)
  "Read FILENAME into forms after include policy checks.
When FOLD-CASE is non-nil, read as if the file began with
`#!fold-case'.  The return value is (FORMS . DIRECTORY)."
  (let* ((path (consent--resolve-include-file
                filename context (if fold-case "include-ci" "include")))
         (source
          (with-temp-buffer
            (insert-file-contents path)
            (buffer-string)))
         (forms
          (consent-read-all
           (if fold-case
               (concat "#!fold-case\n" source)
             source))))
    (cons forms (file-name-directory path))))

(defun consent--library-include-body-forms
    (declaration context fold-case)
  "Return body forms read by include DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (car (consent--read-include-file-forms
            filename context fold-case)))
    (consent--include-filenames declaration))))

(defun consent--expand-include-library-declarations
    (declaration context environment)
  "Return declarations spliced from include-library-declarations DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (let* ((read-result
              (let ((path
                     (consent--resolve-include-file
                      filename context "include-library-declarations")))
                (let ((source
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-string))))
                  (cons (consent-read-all source)
                        (file-name-directory path)))))
             (forms (car read-result))
             (directory (cdr read-result)))
        (consent--with-include-directory
         context
         directory
         (lambda ()
           (apply
            #'append
            (mapcar
             (lambda (nested)
               (consent--expand-library-declaration
                nested context environment))
             forms))))))
    (consent--include-filenames declaration))))

(defun consent--library-export-binding
    (spec library-key value-environment syntax-environment)
  "Return the library binding described by export SPEC."
  (let* ((internal-name (car spec))
         (external-name (cdr spec))
         (cell
          (consent--environment-cell value-environment internal-name))
         (syntax-binding
          (consent--syntax-environment-ref
           syntax-environment internal-name)))
    (cond
     ((and cell syntax-binding)
      (consent--eval-error
       "export identifier has both value and syntax bindings: %s"
       internal-name))
     (cell
      (consent--make-library-binding
       external-name 'value cell library-key))
     (syntax-binding
      (consent--make-library-binding
       external-name 'syntax syntax-binding library-key))
     (t
      (consent--eval-error
       "exported identifier is not bound: %s" internal-name)))))

(defun consent--library-exports-from-specs
    (specs library-key value-environment syntax-environment)
  "Return export bindings for SPECS from library environments."
  (consent--ensure-distinct-names
   (mapcar #'cdr specs)
   "library exports")
  (consent--ensure-compatible-import-bindings
   (mapcar
    (lambda (spec)
      (consent--library-export-binding
       spec library-key value-environment syntax-environment))
    specs)))

(defun consent--eval-library-begin
    (forms value-environment syntax-environment context)
  "Evaluate library body FORMS in explicit library environments."
  (consent--with-syntax-environment
   context
   syntax-environment
   (lambda ()
     (consent--trampoline
      (consent--make-sequence forms t)
      value-environment
      context))))

(defun consent--eval-define-library (form environment context)
  "Evaluate a top-level R7RS define-library FORM."
  (let* ((parts (consent--proper-list-elements
                 form "define-library form"))
         (name (cadr parts)))
    (unless (>= (length parts) 2)
      (consent--eval-error
       "define-library requires a library name"))
    (unless (consent--library-name-p name)
      (consent--eval-error
       "invalid library name: %s" (consent-value->external name)))
    (let* ((library-key (consent--library-name-key name))
           (value-environment (consent-make-empty-environment))
           (syntax-environment
            (consent--make-empty-syntax-environment))
           export-specs)
      (dolist (raw-declaration (cddr parts))
        (dolist (declaration
                 (consent--expand-library-declaration
                  raw-declaration context environment))
          ;; `cond-expand' and include-library-declarations are flattened
          ;; before this dispatch so only core R7RS library declarations remain.
          (let* ((declaration-parts
                  (consent--proper-list-elements
                   declaration "library declaration"))
                 (operator (car declaration-parts)))
            (cond
             ((consent--symbol-named-p operator "export")
              (setq export-specs
                    (append export-specs
                            (consent--export-specs
                             (cdr declaration-parts)))))
             ((consent--symbol-named-p operator "import")
              (consent--with-syntax-environment
               context
               syntax-environment
               (lambda ()
                 (consent--eval-import
                  declaration value-environment context))))
             ((consent--symbol-named-p operator "begin")
              (consent--eval-library-begin
               (cdr declaration-parts)
               value-environment
               syntax-environment
               context))
             ((consent--symbol-named-p operator "include")
              (consent--eval-library-begin
               (consent--library-include-body-forms
                declaration context nil)
               value-environment
               syntax-environment
               context))
             ((consent--symbol-named-p operator "include-ci")
              (consent--eval-library-begin
               (consent--library-include-body-forms
                declaration context t)
               value-environment
               syntax-environment
               context))
             ((consent--symbol-named-p
               operator "include-library-declarations")
              (consent--eval-error
               "include-library-declarations must expand before evaluation"))
             (t
              (consent--eval-error
               "unsupported library declaration: %s"
               (consent-value->external declaration)))))))
      (puthash
       library-key
       (consent--make-library
        name
        library-key
        (consent--library-exports-from-specs
         export-specs library-key value-environment syntax-environment)
        value-environment
        syntax-environment)
       (consent--eval-context-libraries context))
      consent-unspecified)))


(provide 'consent-library)

;;; consent-library.el ends here
